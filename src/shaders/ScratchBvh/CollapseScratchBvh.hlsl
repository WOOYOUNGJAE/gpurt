#ifndef _COLLAPSE_SCRATCH_BVH_HLSL
#define _COLLAPSE_SCRATCH_BVH_HLSL

#define DO_NEXT_PHASE 0

#if NO_SHADER_ENTRYPOINT == 0
//=====================================================================================================================
#include "../../shadersClean/common/ShaderDefs.hlsli"


#define GC_DSTBUFFER
#define GC_DSTMETADATA
#define GC_SCRATCHBUFFER
#include "../../shadersClean/build/BuildRootSignature.hlsli"

#define TASK_COUNTER_BUFFER   ScratchGlobal
#define TASK_COUNTER_OFFSET   (ShaderConstants.offsets.taskLoopCounters + TASK_LOOP_QBVH_COUNTER_OFFSET)
#define NUM_TASKS_DONE_OFFSET (ShaderConstants.offsets.taskLoopCounters + TASK_LOOP_QBVH_TASKS_DONE_OFFSET)
#include "../TaskMacros.hlsl"

template<typename T>
T LoadInstanceDescBuffer(uint offset)
{
    return InstanceDescBuffer.Load<T>(offset);
}

#define MAX_ELEMENTS_PER_THREAD 8 // 0: for task macro, 
#define MAX_LDS_ELEMENTS_PER_THREADGROUP (MAX_ELEMENTS_PER_THREAD * BUILD_THREADGROUP_SIZE)
// groupshared uint SharedMem[MAX_LDS_ELEMENTS_PER_THREADGROUP];
groupshared uint SharedMem[1];
uint GetSharedMem(uint index)
{
    return SharedMem[index];
}
void SetSharedMem(uint index, uint value)
{
    SharedMem[index] = value;
}

#define LANE_GROUP_SIZE 8
#define NUM_LANE_GROUPS (BUILD_THREADGROUP_SIZE / LANE_GROUP_SIZE)
#define MAX_ELEMENTS_PER_LANE_GROUP 2
struct LaneSharedData
{
    uint childIndexInParent;
    uint data;
};
groupshared LaneSharedData LaneGroupShared[NUM_LANE_GROUPS][LANE_GROUP_SIZE];

#include "../../shadersClean/build/BuildCommonScratch.hlsli"
#endif

#if GPURT_BUILD_RTIP3_1

#include "../EncodeHwBvhCommon.hlsl"
#include "../../shadersClean/common/LaneGroup.hlsli"
#include "../OrientedBoundingBoxes.hlsl"
#include "../../shadersClean/common/ScratchWideNode.hlsli"

namespace Gfx12
{

//=====================================================================================================================
// Returns true to enable a separate leaf compression pass over all children of one internal node.
bool EnableLeafCompressionPass()
{
    return (IsTrianglePrimitiveBuild() || IsCompressedTrianglePrimitiveBuild()) &&
           ((Settings.primCompressionFlags & PrimCompFlags::MultiPrim) ||
            (Settings.maxPrimRangeSize > 2));
}

//=====================================================================================================================
// Returns true to enable the optimized wave parallel compression pass (only supports wave32 and maxPrimRangeSize<=4)
bool EnableWaveLeafCompressionPass()
{
#if BUILD_PARALLEL
    return false;
#else
    return EnableLeafCompressionPass();
#endif
}

//=====================================================================================================================
static void PullUpChildNode(
    LaneGroup                laneGroup,
    in    bool               isRootNode,
    in    uint               scratchNodesScratchOffset,
    in    uint               scratchWideNodesScratchOffset,
    in    uint               localId,
    in    uint               parentScratchNodeIdx,
    in    uint               bvhNodeDstIdx,
    in    uint               numPrimRefs)
{

    uint baseDstBoxIdx      = 0;
    uint numLeafChildren    = 0;
    uint numBoxChildren     = 0;
    uint baseLeafNodeOffset = 0;
    uint baseBoxNodeOffset  = 0;
    float3 rcpExponents     = 0;
    uint3 exponents;
    BoundingBox parentBbox;

    bool isBox      = false;
    bool needToLoad = false;
    bool isLeaf     = false;
    uint boxOrLeafChildIndex = INVALID_IDX;
    uint scratchNodeIdx  = INVALID_IDX; // Start with an invalid index for each thread.
    float scratchNodeArea    = -1.0f;   // Mark area as invalid initially.
    ScratchNode scratchNode;

    // Initialization for the first lane
    if (laneGroup.IsFirstLane())
    {
        scratchNodeIdx = parentScratchNodeIdx;
        needToLoad = true;
    }
    
    while (1)
    {
        const uint firstInvalidLane = laneGroup.GetFirstActiveLaneIndex(scratchNodeIdx == INVALID_IDX);

        // Load node data if needed
        if (needToLoad)
        {
            scratchNode = FetchScratchNode(scratchNodesScratchOffset, scratchNodeIdx);

            bool isCollapse = scratchNode.numPrimitivesAndDoCollapse & 1;

            if (CollapseAnyPairs())
            {
                isCollapse = (scratchNode.numPrimitivesAndDoCollapse >> 1) == 2;
            }

            isLeaf = (IsLeafNode(scratchNodeIdx, numPrimRefs) || isCollapse);
            isBox  = !isLeaf;
            scratchNodeArea = isLeaf ? -1.0f : scratchNode.sah_or_v2_or_instBasePtr.y;

            needToLoad = false;
        }

        numBoxChildren = laneGroup.BallotCount(isBox);

        if ((numBoxChildren == 0) || (firstInvalidLane >= 8))
        {
            // Break the loop if there are no more box nodes needing to be processed,
            // or if there's no remaining space in the structure.
            break;
        }

        const float maxArea      = laneGroup.Max(scratchNodeArea);
        const bool isMaxAreaNode = (scratchNodeArea == maxArea);
        // Get the lane index of the max node
        const uint maxNodeLane   = laneGroup.GetFirstActiveLaneIndex(isMaxAreaNode);

        uint rightNode = INVALID_IDX;

        if (laneGroup.laneIndex == maxNodeLane)
        {
            // Assign left child for next processing
            scratchNodeIdx = scratchNode.left_or_primIndex_or_instIndex;
            rightNode = scratchNode.right_or_geometryIndex;
            needToLoad = true;
        }

        // Distribute the right child to the first thread with an invalid index
        rightNode = laneGroup.Broadcast(rightNode, maxNodeLane);

        if ((laneGroup.laneIndex == firstInvalidLane) && (rightNode != INVALID_IDX))
        {
            // This thread takes the right child
            scratchNodeIdx = rightNode;
            needToLoad = true;
        }
    }
    
    // Calculate exclusive prefix sum to get index (0,1,2... )
    if (isBox)
    {
        boxOrLeafChildIndex = laneGroup.ExclusivePrefixSumBool(true);
    }
    else if (isLeaf)
    {
        boxOrLeafChildIndex = laneGroup.ExclusivePrefixSumBool(true);
    }

    uint dstStackBaseIndex = 0;
    numLeafChildren = laneGroup.BallotCount(isLeaf);
    GPU_ASSERT(numBoxChildren + numLeafChildren > 0 && numBoxChildren + numLeafChildren <= 8);
    if (laneGroup.IsFirstLane())
    {
        const uint stackPtrOffset = ShaderConstants.offsets.qbvhGlobalStackPtrs;
        ScratchGlobal.InterlockedAdd(stackPtrOffset + STACK_PTRS_SRC_PTR_OFFSET, numBoxChildren, dstStackBaseIndex);
    }

    dstStackBaseIndex = laneGroup.ReadFirstLane(dstStackBaseIndex);
    baseDstBoxIdx     = dstStackBaseIndex;

    // Write box nodes to the global memory to be process by another thread
    if (isBox)
    {
        const uint childStackIdx = dstStackBaseIndex + boxOrLeafChildIndex;
        uint dstNodeIdx = baseDstBoxIdx + boxOrLeafChildIndex;

        // Regular operation for other threads with isBox set
        ScratchGlobal.Store2(ShaderConstants.offsets.qbvhGlobalStack + (childStackIdx * sizeof(uint2)),
                             uint2(scratchNodeIdx, dstNodeIdx));
    }
    uint childIndexInParent = INVALID_IDX;
    if (isBox)
    {
        childIndexInParent = boxOrLeafChildIndex;
    }
    else if (isLeaf)
    {
        childIndexInParent = numBoxChildren + boxOrLeafChildIndex;
    }

    // Fill childrenWideNodeIndexOrLeafScratchIndex,
    // with box children first, then leaf children, and invalid entries for others.
    uint laneData = INVALID_IDX;
    if (isBox)
    {
        // dst scratch wide node index
        laneData = baseDstBoxIdx + boxOrLeafChildIndex;
    }
    else if (isLeaf)
    {
        // scratch node index
        laneData = scratchNodeIdx;
    }

    LaneGroupShared[laneGroup.groupIndex][laneGroup.laneIndex].childIndexInParent = childIndexInParent;
    LaneGroupShared[laneGroup.groupIndex][laneGroup.laneIndex].data = laneData;
    GroupMemoryBarrier();
    // Write parent wide node
    if (laneGroup.IsFirstLane())
    {
        ScratchWideNode parentWideNode = (ScratchWideNode)0;
        parentWideNode.children0WideNodeIndexOrLeafScratchIndex = 0xffffffff.xxxx;
        parentWideNode.children1WideNodeIndexOrLeafScratchIndex = 0xffffffff.xxxx;
        
        [unroll]
        for (uint i = 0; i < 8; ++i)
        {
            uint idx = LaneGroupShared[laneGroup.groupIndex][i].childIndexInParent;
            uint val = LaneGroupShared[laneGroup.groupIndex][i].data;

            if (idx != INVALID_IDX)
            {
                GPU_ASSERT(idx < 8);
                if (idx < 4)
                {
                    parentWideNode.children0WideNodeIndexOrLeafScratchIndex[idx] = val;
                }
                else
                {
                    parentWideNode.children1WideNodeIndexOrLeafScratchIndex[idx - 4] = val;
                }
            }
        }

        parentWideNode.bbox_min     = FetchScratchNodeData<float3>(scratchNodesScratchOffset, parentScratchNodeIdx, SCRATCH_NODE_BBOX_MIN_OFFSET);
        parentWideNode.scratchIndex = parentScratchNodeIdx;
        parentWideNode.bbox_max     = FetchScratchNodeData<float3>(scratchNodesScratchOffset, parentScratchNodeIdx, SCRATCH_NODE_BBOX_MAX_OFFSET);

        uint packedFlags = 0;
        packedFlags = bitFieldInsert(packedFlags, 0, 4, numBoxChildren);
        packedFlags = bitFieldInsert(packedFlags, 4, 4, numLeafChildren);
        packedFlags = bitFieldInsert(packedFlags, 8, 1, 1);
        parentWideNode.packedFlags = packedFlags;

        ScratchGlobal.InterlockedAdd(ShaderConstants.offsets.scratchWideNodeCounter, 1);
        WriteScratchWideNode(scratchWideNodesScratchOffset, bvhNodeDstIdx, parentWideNode);
    }

    uint localPrimCount = 0;
    if (scratchNodeIdx != INVALID_IDX)
    {
        if (isBox == false)
        {
            localPrimCount = FetchScratchNodeNumPrimitives(scratchNode, IsLeafNode(scratchNodeIdx, numPrimRefs));
        }
    }

    const uint primCount = WaveActiveSum(localPrimCount);
    if (WaveIsFirstLane())
    {
        if (primCount > 0)
        {
            ScratchGlobal.InterlockedAdd(ShaderConstants.offsets.qbvhGlobalStackPtrs +
                                         NumLeafsDoneOffset(),
                                         primCount);
        }
    }
}

//=====================================================================================================================
// Convert source BVH2 (in scratch memory) into BVH8 (also in scratch memory)
void CollapseScratchBvhImpl(
    uint globalId,
    uint localId,
    uint numPrimRefs)
{
    const uint rootNodeIndex = GetBvh2RootNodeIndex();

    const uint scratchNodesScratchOffset     = CalculateBvhNodesOffset(ShaderConstants, numPrimRefs);
    const uint scratchWideNodesScratchOffset = ShaderConstants.offsets.bvhWideNodeData;

    const bool isSinglePrimBvh = (numPrimRefs == 1);

    const ScratchNode rootScratchNode = FetchScratchNode(scratchNodesScratchOffset, rootNodeIndex);
    const uint numActivePrims = FetchScratchNodeNumPrimitives(rootScratchNode, isSinglePrimBvh);

    const uint maxNumInternalNodes = GetNumInternalNodeCount(numActivePrims);

    LaneGroup laneGroup;
    laneGroup.Alloc(8);

    // Each stack item stores data for writes to linear QBVH memory, indexed by stack index
    const uint globalStackIndex = globalId / 8;

    // With early pairing enabled, numPrimRefs represents the active primitive references. However,
    // we need to use the active primitive count to estimate the hardware internal node count.
    bool isGlobalStackEntryDone = (globalStackIndex >= maxNumInternalNodes);

    while (isGlobalStackEntryDone == false)
    {
        uint numLeafsDone = 0;
        if (WaveIsFirstLane())
        {
            numLeafsDone = ScratchGlobal.Load(ShaderConstants.offsets.qbvhGlobalStackPtrs +
                                              NumLeafsDoneOffset());
        }

        numLeafsDone = WaveReadLaneFirst(numLeafsDone);

        if (numLeafsDone >= numActivePrims)
        {
            break;
        }

        uint2 stackEntry = uint2(0, 0);
        if (laneGroup.IsFirstLane())
        {
            stackEntry = StackPop(globalStackIndex);
        }

        stackEntry = laneGroup.ReadFirstLane(stackEntry);

        // If we have a valid node on the stack, process node
        if (stackEntry.x != INVALID_IDX)
        {
            const uint bvhNodeSrcIdx = stackEntry.x;
            const uint bvhNodeDstIdx = stackEntry.y;

            // Pull up the nodes chosen by SAH to be the new children in BVH8
            PullUpChildNode(laneGroup,
                          (globalStackIndex == 0),
                          scratchNodesScratchOffset,
                          scratchWideNodesScratchOffset,
                          localId,
                          bvhNodeSrcIdx,
                          bvhNodeDstIdx,
                          numPrimRefs);

            isGlobalStackEntryDone = true;
        }
    }
}

} // namespace Gfx12

#endif

#if NO_SHADER_ENTRYPOINT == 0
//=====================================================================================================================
// Main Function : CollapseScratchBvh
//=====================================================================================================================
[RootSignature(RootSig)]
[numthreads(BUILD_THREADGROUP_SIZE, 1, 1)]
void CollapseScratchBvh(
    uint globalIdIn : SV_DispatchThreadID,
    uint localIdIn  : SV_GroupThreadID)
{
#if GPURT_BUILD_RTIP3_1

    uint globalId = globalIdIn;
    uint localId  = localIdIn;

    const uint numActivePrims = ReadAccelStructHeaderField(ACCEL_STRUCT_HEADER_NUM_ACTIVE_PRIMS_OFFSET);
    const uint maxInternalNodeCount = (numActivePrims == 0) ? 0 : GetMaxInternalNodeCount(numActivePrims);

    uint numTasksWait = 0;
    uint waveId       = 0;

    INIT_TASK;
        BEGIN_TASK(1)
        if (globalId == 0)
        {
            InitStackPtrs();
        }
        END_TASK(1);

    BEGIN_TASK(RoundUpQuotient(maxInternalNodeCount, BUILD_THREADGROUP_SIZE));
    ClearStackPtrs(globalId, maxInternalNodeCount, ShaderRootConstants.NumThreads());
    END_TASK(RoundUpQuotient(maxInternalNodeCount, BUILD_THREADGROUP_SIZE));

    const uint numThreads = maxInternalNodeCount * 8;
    
    BEGIN_TASK(RoundUpQuotient(numThreads, BUILD_THREADGROUP_SIZE));
    Gfx12::CollapseScratchBvhImpl(globalId, localId, numActivePrims);
    END_TASK(RoundUpQuotient(numThreads, BUILD_THREADGROUP_SIZE));
#endif
}
#endif

#endif
