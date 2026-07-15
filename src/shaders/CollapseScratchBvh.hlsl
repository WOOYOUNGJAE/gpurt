#ifndef _COLLAPSE_SCRATCH_BVH_HLSL
#define _COLLAPSE_SCRATCH_BVH_HLSL

#define DO_NEXT_PHASE 0

#if NO_SHADER_ENTRYPOINT == 0
//=====================================================================================================================
#include "../shadersClean/common/ShaderDefs.hlsli"

#define GC_DSTBUFFER
#define GC_DSTMETADATA
#define GC_SCRATCHBUFFER
#include "../shadersClean/build/BuildRootSignature.hlsli"

#define TASK_COUNTER_BUFFER   ScratchGlobal
#define TASK_COUNTER_OFFSET   (ShaderConstants.offsets.taskLoopCounters + TASK_LOOP_QBVH_COUNTER_OFFSET)
#define NUM_TASKS_DONE_OFFSET (ShaderConstants.offsets.taskLoopCounters + TASK_LOOP_QBVH_TASKS_DONE_OFFSET)
#include "TaskMacros.hlsl"

template<typename T>
T LoadInstanceDescBuffer(uint offset)
{
    return InstanceDescBuffer.Load<T>(offset);
}
#include "IndirectArgBufferUtils.hlsl"

#define MAX_ELEMENTS_PER_THREAD 8
#define MAX_LDS_ELEMENTS_PER_THREADGROUP (MAX_ELEMENTS_PER_THREAD * BUILD_THREADGROUP_SIZE)
groupshared uint SharedMem[MAX_LDS_ELEMENTS_PER_THREADGROUP];
uint GetSharedMem(uint index)
{
    return SharedMem[index];
}
void SetSharedMem(uint index, uint value)
{
    SharedMem[index] = value;
}

#include "../shadersClean/build/BuildCommonScratch.hlsli"
#endif

#if GPURT_BUILD_RTIP3_1

#include "rtip3_1.hlsli"
#include "EncodeHwBvhCommon.hlsl"
#include "QBVH8Common.hlsl"
#include "../shadersClean/common/LaneGroup.hlsli"
#include "PrimitiveStructureEncoder3_1.hlsl"
#include "OrientedBoundingBoxes.hlsl"
#include "../shadersClean/common/ScratchWideNode.hlsli"

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
// Allocation of compressed leaf nodes is deferred to the compression pass. Leaf nodes in the root of a rebraided BLAS
// are an exception. They must be allocated near the beginning of the tree to support rebraid. Some small unused space
// will be left between the end of the compressed data and the next node.
uint GetNumInlinePrimStructs(
    LaneGroup   laneGroup,
    uint        scratchNodesScratchOffset,
    uint        numPrimRefs,
    uint        numLeafChildren,
    uint        childScratchNodeIdx,
    bool        isRebraidRootNode,
    bool        isLeaf)
{
    uint numInlinePrimStructs = 0;

    if (EnableWaveLeafCompressionPass() && (isRebraidRootNode == false))
    {
        numInlinePrimStructs = 0;
    }
    else if (Settings.maxPrimRangeSize <= 2)
    {
        numInlinePrimStructs = numLeafChildren;
    }
    else
    {
        uint numPrimStructs = 0;
        if (isLeaf)
        {
            const uint rangeNumPrims = FetchScratchNodeNumPrimitives(
                scratchNodesScratchOffset, childScratchNodeIdx, IsLeafNode(childScratchNodeIdx, numPrimRefs));

            // Minimum two triangles per prim struct in each range
            numPrimStructs = RoundUpQuotient(rangeNumPrims, 2);
        }
        numInlinePrimStructs = laneGroup.Sum(numPrimStructs);
    }

    return numInlinePrimStructs;
}

//======================================================================================================================
uint ScratchStackPop(
    uint stackIndex)
{
    return ScratchGlobal.Load<uint>(ShaderConstants.offsets.qbvhGlobalStack + (stackIndex * sizeof(uint2)));
}

//=====================================================================================================================
static void PullUpBoxNode(
    LaneGroup                laneGroup,
    in    uint               scratchNodesScratchOffset,
    in    uint               scratchWideNodesScratchOffset,
    in    uint               localId,
    in    uint               parentScratchNodeIdx,
    in    uint               maxNumChildren,
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
    uint boxOrLeafChildIndex;
    uint scratchNodeIdx  = INVALID_IDX; // Start with an invalid index for each thread.
    float scratchNodeArea    = -1.0f;   // Mark area as invalid initially.
    ScratchNode scratchNode;

    // Initialization for the first lane
    if (laneGroup.IsFirstLane())
    {
        scratchNodeIdx = parentScratchNodeIdx;
        needToLoad = true;
    }

    // This bitfield is an array of 2 bit indices indicating which of the first 4 boxes was split to produce a given
    // box. It is initialized to [0, 1, 2, 3] for the first 4 boxes. After the first 4 boxes are generated, each
    // additional box takes the index of the box it was split from.
    uint packedSourceBoxes = 0b11100100;

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

            isLeaf = (IsLeafNode(scratchNodeIdx, numPrimRefs) ||
                      ((Settings.topLevelBuild == false) && isCollapse));
            isBox  = !isLeaf;
            scratchNodeArea = isLeaf ? -1.0f : scratchNode.sah_or_v2_or_instBasePtr.y;

            needToLoad = false;
        }

        numBoxChildren = laneGroup.BallotCount(isBox);

        if ((numBoxChildren == 0) || (firstInvalidLane >= maxNumChildren))
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

            if (laneGroup.laneIndex >= 4)
            {
                const uint sourceBoxIndex = (packedSourceBoxes >> (maxNodeLane * 2)) & 0b11;
                packedSourceBoxes |= sourceBoxIndex << (laneGroup.laneIndex * 2);
            }
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

    uint dstStackIdx = 0;
    numLeafChildren = laneGroup.BallotCount(isLeaf);
    if (Settings.topLevelBuild == 0)
    {
        const uint numInlinePrimStructs = GetNumInlinePrimStructs(laneGroup,
                                                                  scratchNodesScratchOffset,
                                                                  numPrimRefs,
                                                                  numLeafChildren,
                                                                  scratchNodeIdx,
                                                                  false,
                                                                  isLeaf);

        if (laneGroup.IsFirstLane())
        {
            const uint stackPtrOffset = ShaderConstants.offsets.qbvhGlobalStackPtrs;

            ScratchGlobal.InterlockedAdd(stackPtrOffset + STACK_PTRS_SRC_PTR_OFFSET, numBoxChildren, dstStackIdx);
            ScratchGlobal.InterlockedAdd(stackPtrOffset + STACK_PTRS_DST_PTR_OFFSET, numBoxChildren + numInlinePrimStructs, baseDstBoxIdx);

#if DO_NEXT_PHASE
            baseBoxNodeOffset = offsets.internalNodes + (baseDstBoxIdx * QBVH8::NodeSizeInBytes);

            // BLAS leaf nodes are allocated in a unified data section unlike TLAS which requires the instance nodes
            // to be in a separate data section for sideband addressing. See ComputeInstanceSidebandOffset()
            baseLeafNodeOffset = EnableWaveLeafCompressionPass() ?
                0 : (baseBoxNodeOffset + (numBoxChildren * QBVH8::NodeSizeInBytes));
#endif
        }
    }
#if 0 // TLAS merging not supported yet
    else
    {
        if (laneGroup.IsFirstLane())
        {
            // TODO: This atomic increment can be removed if we place fp32 node count and leaf node count
            // adjacent in memory and use a single 64-bit atomic to increment both box and leaf node counts
            IncrementAccelStructHeaderField(ACCEL_STRUCT_HEADER_NUM_INTERNAL_FP32_NODES_OFFSET, 1);

            // This code assumes STACK_PTRS_SRC_PTR_OFFSET and STACK_PTRS_DST_PTR_OFFSET are in consecutive
            // DWORDs.
            const uint stackPtrOffset = ShaderConstants.offsets.qbvhGlobalStackPtrs + STACK_PTRS_SRC_PTR_OFFSET;

            uint baseDstLeafIdx = 0;
            uint64_t returnVal;
            ScratchGlobal.InterlockedAdd(stackPtrOffset, numBoxChildren, baseDstBoxIdx);
            ScratchGlobal.InterlockedAdd(stackPtrOffset + 4, numLeafChildren, baseDstLeafIdx);
            dstStackIdx = baseDstBoxIdx;

            baseBoxNodeOffset = offsets.internalNodes + (baseDstBoxIdx * QBVH8::NodeSizeInBytes);
            baseLeafNodeOffset = offsets.leafNodes + (baseDstLeafIdx * QBVH8::NodeSizeInBytes);
        }
    }
#endif

    baseDstBoxIdx = laneGroup.ReadFirstLane(baseDstBoxIdx);
    dstStackIdx   = laneGroup.ReadFirstLane(dstStackIdx);

    // Write box nodes to the global memory to be process by another thread
    if (isBox)
    {
        uint childStackIdx = dstStackIdx + boxOrLeafChildIndex;

        // Regular operation for other threads with isBox set
        ScratchGlobal.Store<uint>(ShaderConstants.offsets.qbvhGlobalStack + (childStackIdx * sizeof(uint2)), scratchNodeIdx);
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

    ScratchWideNode parentWideNode = (ScratchWideNode)0;
    if (laneGroup.IsFirstLane())
    {
        uint dstNodeIndex = baseDstBoxIdx + boxOrLeafChildIndex;
#if 1
        uint laneChildIndexInParent[8];
        laneChildIndexInParent[0] = laneGroup.Broadcast(childIndexInParent, 0);
        laneChildIndexInParent[1] = laneGroup.Broadcast(childIndexInParent, 1);
        laneChildIndexInParent[2] = laneGroup.Broadcast(childIndexInParent, 2);
        laneChildIndexInParent[3] = laneGroup.Broadcast(childIndexInParent, 3);
        laneChildIndexInParent[4] = laneGroup.Broadcast(childIndexInParent, 4);
        laneChildIndexInParent[5] = laneGroup.Broadcast(childIndexInParent, 5);
        laneChildIndexInParent[6] = laneGroup.Broadcast(childIndexInParent, 6);
        laneChildIndexInParent[7] = laneGroup.Broadcast(childIndexInParent, 7);

        uint sourceLane[8] = { INVALID_IDX, INVALID_IDX, INVALID_IDX, INVALID_IDX, INVALID_IDX, INVALID_IDX, INVALID_IDX, INVALID_IDX };
        [unroll]
        for (uint i = 0; i < 8; ++i)
        {
            uint idx = laneChildIndexInParent[i];
            if (idx < 8) // Only for valid
            {
                sourceLane[idx] = i;
            }
        }

        uint laneData[8];
        laneData[0] = laneGroup.Broadcast(dstNodeIndex, 0);
        laneData[1] = laneGroup.Broadcast(dstNodeIndex, 1);
        laneData[2] = laneGroup.Broadcast(dstNodeIndex, 2);
        laneData[3] = laneGroup.Broadcast(dstNodeIndex, 3);
        laneData[4] = laneGroup.Broadcast(dstNodeIndex, 4);
        laneData[5] = laneGroup.Broadcast(dstNodeIndex, 5);
        laneData[6] = laneGroup.Broadcast(dstNodeIndex, 6);
        laneData[7] = laneGroup.Broadcast(dstNodeIndex, 7);

        parentWideNode.children0.x = (sourceLane[0] == INVALID_IDX) ? INVALID_IDX : laneData[sourceLane[0]];
        parentWideNode.children0.y = (sourceLane[1] == INVALID_IDX) ? INVALID_IDX : laneData[sourceLane[1]];
        parentWideNode.children0.z = (sourceLane[2] == INVALID_IDX) ? INVALID_IDX : laneData[sourceLane[2]];
        parentWideNode.children0.w = (sourceLane[3] == INVALID_IDX) ? INVALID_IDX : laneData[sourceLane[3]];

        parentWideNode.children1.x = (sourceLane[4] == INVALID_IDX) ? INVALID_IDX : laneData[sourceLane[4]];
        parentWideNode.children1.y = (sourceLane[5] == INVALID_IDX) ? INVALID_IDX : laneData[sourceLane[5]];
        parentWideNode.children1.z = (sourceLane[6] == INVALID_IDX) ? INVALID_IDX : laneData[sourceLane[6]];
        parentWideNode.children1.w = (sourceLane[7] == INVALID_IDX) ? INVALID_IDX : laneData[sourceLane[7]];
#else
        // Unsorted
        parentWideNode.children0.x = WaveReadLaneAt(scratchNodeIdx, 0);
        parentWideNode.children0.y = WaveReadLaneAt(scratchNodeIdx, 1);
        parentWideNode.children0.z = WaveReadLaneAt(scratchNodeIdx, 2);
        parentWideNode.children0.w = WaveReadLaneAt(scratchNodeIdx, 3);
        parentWideNode.children1.x = WaveReadLaneAt(scratchNodeIdx, 4);
        parentWideNode.children1.y = WaveReadLaneAt(scratchNodeIdx, 5);
        parentWideNode.children1.z = WaveReadLaneAt(scratchNodeIdx, 6);
        parentWideNode.children1.w = WaveReadLaneAt(scratchNodeIdx, 7);
#endif

        const ScratchNode parentScratchNode = FetchScratchNode(scratchNodesScratchOffset, parentScratchNodeIdx);
        parentWideNode.bbox_min    = parentScratchNode.bbox_min_or_v0;
        parentWideNode.scratchIndex = scratchNodeIdx;
        parentWideNode.bbox_max    = parentScratchNode.bbox_max_or_v1;

        parentWideNode.packedFlags = bitFieldInsert(parentScratchNode.packedFlags, 29, 3, numBoxChildren);

        WriteScratchWideNode(scratchWideNodesScratchOffset, baseDstBoxIdx, parentWideNode);
        ScratchGlobal.InterlockedAdd(ShaderConstants.offsets.scratchWideNodeCounter, 1);
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
        if ((Settings.topLevelBuild == false) && (primCount > 0))
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
    const uint numActivePrims =
        Settings.topLevelBuild ? numPrimRefs : FetchScratchNodeNumPrimitives(rootScratchNode, isSinglePrimBvh);

    const uint maxNumInternalNodes = GetNumInternalNodeCount(numActivePrims);

    LaneGroup laneGroup;
    laneGroup.Alloc(8);

    // Each stack item stores data for writes to linear QBVH memory, indexed by stack index
    const uint globalStackIndex = globalId / 8;

    // With early pairing enabled, numPrimRefs represents the active primitive references. However,
    // we need to use the active primitive count to estimate the hardware internal node count.
    bool isGlobalStackEntryDone = (globalStackIndex >= maxNumInternalNodes);

    const uint maxNumChildren = 8;
    int iteration = 0;
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

        uint stackEntry = 0;
        if (laneGroup.IsFirstLane())
        {
            stackEntry = ScratchStackPop(globalStackIndex);
        }

        stackEntry = laneGroup.ReadFirstLane(stackEntry);

        // If we have a valid node on the stack, process node
        if (stackEntry != INVALID_IDX)
        {
            const uint bvhNodeSrcIdx = stackEntry;

            // Pull up the nodes chosen by SAH to be the new children in BVH8
            PullUpBoxNode(laneGroup,
                          scratchNodesScratchOffset,
                          scratchWideNodesScratchOffset,
                          localId,
                          bvhNodeSrcIdx,
                          maxNumChildren,
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

    if (globalId == 0)
    {
        // Clear Task Buffers
        TASK_COUNTER_BUFFER.Store<uint>(TASK_COUNTER_OFFSET, 0);        
        TASK_COUNTER_BUFFER.Store<uint>(NUM_TASKS_DONE_OFFSET, 0);
    }
#endif
}
#endif

#endif
