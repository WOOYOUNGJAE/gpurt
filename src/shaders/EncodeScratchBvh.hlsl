/*
 ***********************************************************************************************************************
 *
 *  Copyright (c) 2023-2025 Advanced Micro Devices, Inc. All Rights Reserved.
 *
 *  Permission is hereby granted, free of charge, to any person obtaining a copy
 *  of this software and associated documentation files (the "Software"), to deal
 *  in the Software without restriction, including without limitation the rights
 *  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 *  copies of the Software, and to permit persons to whom the Software is
 *  furnished to do so, subject to the following conditions:
 *
 *  The above copyright notice and this permission notice shall be included in all
 *  copies or substantial portions of the Software.
 *
 *  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 *  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 *  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 *  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 *  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 *  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 *  SOFTWARE.
 *
 **********************************************************************************************************************/
#ifndef _ENCODE_SCRATCH_BVH_HLSL
#define _ENCODE_SCRATCH_BVH_HLSL
#define USE_LDS_CHILDREN 1 // this is default setting
#define MERGE_CONSIDERING_DOBB 1
#if NO_SHADER_ENTRYPOINT == 0
//=====================================================================================================================
#include "../shadersClean/common/ShaderDefs.hlsli"

#define GC_DSTBUFFER
#define GC_DSTMETADATA
#define GC_SCRATCHBUFFER
#include "../shadersClean/build/BuildRootSignature.hlsli"

#define TASK_COUNTER_BUFFER   ScratchGlobal
#define TASK_COUNTER_OFFSET   (ShaderConstants.offsets.taskLoopCounters + TASK_LOOP_WIDE_BVH_COUNTER_OFFSET)
#define NUM_TASKS_DONE_OFFSET (ShaderConstants.offsets.taskLoopCounters + TASK_LOOP_WIDE_BVH_TASKS_DONE_OFFSET)
#include "TaskMacros.hlsl"

template<typename T>
T LoadInstanceDescBuffer(uint offset)
{
    return InstanceDescBuffer.Load<T>(offset);
}
#include "IndirectArgBufferUtils.hlsl"

#define LANE_GROUP_SIZE 8
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

uint GetSharedChildren(uint laneGroupIndex, uint childIndex)
{
    return SharedMem[laneGroupIndex * LANE_GROUP_SIZE + childIndex];
}
void SetSharedChildren(uint laneGroupIndex, uint childIndex, uint value)
{
    SharedMem[laneGroupIndex * LANE_GROUP_SIZE + childIndex] = value;
}

#include "../shadersClean/build/BuildCommonScratch.hlsli"
#endif

#if GPURT_BUILD_RTIP3_1

#include "EncodeHwBvhCommon3_1.hlsl"
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
// Pack destination node index (128-byte chunk index) and child index in parent (maximum value of 7) into a single
// DWORD in global stack
uint PackStackDstNodeIdx(
    uint dstNodeIdx,
    uint indexInParent)
{
    return (dstNodeIdx << 3) | indexInParent;
}

//=====================================================================================================================
uint GetStackDstIdx(
    uint packedEntry)
{
    return (packedEntry >> 3);
}

//=====================================================================================================================
uint GetStackDstIdxInParent(
    uint packedEntry)
{
    return (packedEntry & bits(3));
}

//=====================================================================================================================
static void WritePackedExpDisableBoxSortChildIdxAndCount(
    in uint  nodeOffset,
    in uint3 exponents,
    in uint  disableBoxSort,
    in uint  indexInParent,
    in uint  validChildCount)
{
    const uint packedData =
        QuantizedBVH8BoxNode::PackExpChildIdxAndCount(exponents, disableBoxSort, indexInParent, validChildCount);

    DstBuffer.Store(nodeOffset + QUANTIZED_BVH8_NODE_OFFSET_EXP_CHILD_IDX_AND_VALID_COUNT, packedData);
}


//=====================================================================================================================
static uint3 ComputePackedChildInfo(
    in BoundingBox   childBounds,
    in uint          childScratchNodePackedFlags,
    in uint          childScratchNodeIdx,
    in uint          nodeType,
    in uint          nodeRangeLength,
    in float3        rcpExponents,
    in float3        origin,
    in uint          numPrimRefs)
{
    const uint instanceMask =
        ExtractScratchNodeInstanceMask(childScratchNodePackedFlags);

    const uint boxNodeFlags =
        ExtractScratchNodeBoxFlags(childScratchNodePackedFlags);

    const uint3 childInfo = QBVH8::ComputePackedChildInfo(childBounds,
                                                          instanceMask,
                                                          boxNodeFlags,
                                                          nodeType,
                                                          nodeRangeLength,
                                                          rcpExponents,
                                                          origin);
    return childInfo;
}

//=====================================================================================================================
// Skip merging if ((non-merged children OBB SA Sum) * obbPenalty) < (merged children OBB SA Sum).
// In the current Greedy Top-Down collapsing algorithm, a box node can have empty
// slots only when all of its children are leaves. Therefore, merging is guaranteed
// to occur only between leaf-only boxes. This function relies on that assumption;
// if the collapsing algorithm changes, this implementation should be revisited accordingly.
static bool ShouldSkipMerge(
    LaneGroup laneGroup,
    in ScratchWideNode childWideNode,
    in uint mergedCount,
    in uint numPrimRefs,
    in uint scratchNodesScratchOffset,
    in uint targetLane,
    in uint sourceLane,
    in uint numLeavesInTarget,
    in uint numLeavesInSource)
{
    if (mergedCount > 8)
    {
        return true;
    }

    bool shouldSkipMerge = false;
#if MERGE_CONSIDERING_DOBB
    const uint numCombinedLeaves = numLeavesInTarget + numLeavesInSource;
    const bool isFromTarget      = laneGroup.laneIndex < numLeavesInTarget;
    const bool isLeafSlot        = laneGroup.laneIndex < numCombinedLeaves;
    const uint broadcastLane     = isFromTarget ? targetLane : sourceLane;

    const uint4 c0 = laneGroup.Broadcast(childWideNode.children0WideNodeIndexOrLeafScratchIndex, broadcastLane);
    const uint4 c1 = laneGroup.Broadcast(childWideNode.children1WideNodeIndexOrLeafScratchIndex, broadcastLane);

    const uint childSlot = isFromTarget ? laneGroup.laneIndex : (laneGroup.laneIndex - numLeavesInTarget);
    const uint leafScratchIndex = (childSlot < 4) ? c0[childSlot] : c1[childSlot - 4u];

    const bool isValidLeaf = leafScratchIndex != 0xffffffff;

    ScratchNode scratchLeaf;
    if (isValidLeaf)
    {
        scratchLeaf = FetchScratchNode(scratchNodesScratchOffset, leafScratchIndex);
    }
    
    const bool isOriginalLeaf = IsLeafNode(leafScratchIndex, numPrimRefs);
    const float leafSA = isValidLeaf ?
            GetScratchNodeSurfaceArea(scratchNodesScratchOffset, leafScratchIndex, scratchLeaf, numPrimRefs) : 0.0f;
    const float leafSaMax = laneGroup.Max(leafSA);
    const float maxLeafLane = laneGroup.GetFirstActiveLaneIndex(leafSA == leafSaMax);

    // Get triangle data
    TriangleData tri0 = (TriangleData)0;
    TriangleData tri1 = (TriangleData)0;
    const bool isQuadPrim =
        Settings.enableEarlyPairCompression && IsScratchNodeQuadPrimitive(scratchLeaf);
    const bool tri1Valid = isQuadPrim || (!isOriginalLeaf && CollapseAnyPairs());
    if (isValidLeaf)
    {
        if (isQuadPrim)
        {
            tri0 = GetScratchNodeQuadVertices(scratchNodesScratchOffset, leafScratchIndex, 0);
            tri1 = GetScratchNodeQuadVertices(scratchNodesScratchOffset, leafScratchIndex, 1);
        }
        else if (isOriginalLeaf == false)
        {
            uint firstNodeIndex;
            ScratchNode scratchNodeTri0;

            uint secondNodeIndex;
            ScratchNode scratchNodeTri1;

            if (UsePrimIndicesArray())
            {
                // Not Support yet
                GPU_ASSERT(false);
            }
            else if (CollapseAnyPairs())
            {
                firstNodeIndex = scratchLeaf.left_or_primIndex_or_instIndex;
                scratchNodeTri0 = FetchScratchNode(scratchNodesScratchOffset, firstNodeIndex);

                secondNodeIndex = scratchLeaf.right_or_geometryIndex;
                scratchNodeTri1 = FetchScratchNode(scratchNodesScratchOffset, secondNodeIndex);
            }
            else
            {
                // Not Support yet
                GPU_ASSERT(false);
                firstNodeIndex = scratchLeaf.left_or_primIndex_or_instIndex;
                scratchNodeTri0 = FetchScratchNode(scratchNodesScratchOffset, firstNodeIndex);

                secondNodeIndex = scratchNodeTri0.parent;
                scratchNodeTri1 = FetchScratchNode(scratchNodesScratchOffset, secondNodeIndex);
            }

            tri0.v0 = scratchNodeTri0.bbox_min_or_v0;
            tri0.v1 = scratchNodeTri0.bbox_max_or_v1;
            tri0.v2 = scratchNodeTri0.sah_or_v2_or_instBasePtr;
            tri1.v0 = scratchNodeTri1.bbox_min_or_v0;
            tri1.v1 = scratchNodeTri1.bbox_max_or_v1;
            tri1.v2 = scratchNodeTri1.sah_or_v2_or_instBasePtr;
        }
        else // single triangle leaf
        {
            tri0.v0 = scratchLeaf.bbox_min_or_v0;
            tri0.v1 = scratchLeaf.bbox_max_or_v1;
            tri0.v2 = scratchLeaf.sah_or_v2_or_instBasePtr;
        }
    }

    // const uint k
    const uint laneObbMatrixIndex = ExtractScratchNodeObbMatrixIdx(scratchLeaf.packedFlags);
    uint obbMatrixIndex = laneGroup.Broadcast(laneObbMatrixIndex, maxLeafLane);
    
    BoundingBox obb = InvalidBoundingBox;
    float mergedSa = 0.0f;
    if (isValidLeaf)
    {
        if (obbMatrixIndex != INVALID_OBB)
        {
            const float3x3 obbMatrix = OBBIndexToMatrix(obbMatrixIndex);
            BoundingBox tri0Obb = ComputeOBBFromTri(tri0.v0, tri0.v1, tri0.v2, obbMatrix);
            obb = CombineAABB(obb, tri0Obb);
            if (tri1Valid)
            {
                BoundingBox tri1Obb = ComputeOBBFromTri(tri1.v0, tri1.v1, tri1.v2, obbMatrix);
                obb = CombineAABB(obb, tri1Obb);
            }
            mergedSa = ComputeBoxSurfaceArea(obb);
        }
        else
        {
            mergedSa = leafSA;
        }
    }
    const float mergedSaSum = laneGroup.Sum(mergedSa);

    float targetSideSa = 0.0f;
    float targetSideSaSum = 0.0f;
    float sourceSideSa = 0.0f;
    float sourceSideSaSum = 0.0f;
    // target side
    {
        const uint laneInTarget = 0;
        obbMatrixIndex = laneGroup.Broadcast(laneObbMatrixIndex, laneInTarget);

        if (isValidLeaf && isFromTarget)
        {
            if (obbMatrixIndex != INVALID_OBB)
            {
                const float3x3 obbMatrix = OBBIndexToMatrix(obbMatrixIndex);
                obb = InvalidBoundingBox;
                BoundingBox tri0Obb = ComputeOBBFromTri(tri0.v0, tri0.v1, tri0.v2, obbMatrix);
                obb = CombineAABB(obb, tri0Obb);
                if (tri1Valid)
                {
                    BoundingBox tri1Obb = ComputeOBBFromTri(tri1.v0, tri1.v1, tri1.v2, obbMatrix);
                    obb = CombineAABB(obb, tri1Obb);
                }
                targetSideSa = ComputeBoxSurfaceArea(obb);
            }
            else
            {
                targetSideSa = leafSA;
            }
        }
        targetSideSaSum = laneGroup.Sum(targetSideSa);
    }

    // source side
    {
        const uint laneInSource = numLeavesInTarget;
        obbMatrixIndex = laneGroup.Broadcast(laneObbMatrixIndex, laneInSource);

        if (isValidLeaf && !isFromTarget)
        {
            if (obbMatrixIndex != INVALID_OBB)
            {
                const float3x3 obbMatrix = OBBIndexToMatrix(obbMatrixIndex);
                obb = InvalidBoundingBox;
                BoundingBox tri0Obb = ComputeOBBFromTri(tri0.v0, tri0.v1, tri0.v2, obbMatrix);
                obb = CombineAABB(obb, tri0Obb);
                if (tri1Valid)
                {
                    BoundingBox tri1Obb = ComputeOBBFromTri(tri1.v0, tri1.v1, tri1.v2, obbMatrix);
                    obb = CombineAABB(obb, tri1Obb);
                }
                sourceSideSa = ComputeBoxSurfaceArea(obb);
            }
            else
            {
                sourceSideSa = leafSA;
            }
        }
        sourceSideSaSum = laneGroup.Sum(sourceSideSa);
    }

    GPU_ASSERT(targetSideSaSum > 0.0f && sourceSideSaSum > 0.0f);
    float unmergedSaSum = targetSideSaSum + sourceSideSaSum;

#if SOGANG_EXPERIMENT
    const float obbPenalty = Settings.experimentFloat0;
    // ScratchGlobal.InterlockedMax(ShaderConstants.offsets.sgDebugCounters, (unmergedSaSum / mergedSaSum));
#else
    const float obbPenalty = 1.67f;
#endif
    // unmerged dobb is better.
    shouldSkipMerge = unmergedSaSum * obbPenalty < mergedSaSum;

#endif // MERGE_CONSIDERING_DOBB
    return shouldSkipMerge;
}

//=====================================================================================================================
// Consecutive greedy merging method from "Memory-Efficient BVH" (HPG 2026)
static bool MergeBoxNodes(
    LaneGroup                laneGroup,
    in    uint               laneGroupIndex,
    in    uint               scratchNodesScratchOffset,
    in    uint               scratchWideNodesScratchOffset,
    in    uint               childWideScratchIndex,
    in    uint               numPrimRefs,
    in    bool               childIsBox)
{
    bool isMergedLane = false;

    // Starts with 11111111. If result of mask is 10010001,
    // that means 0,4,7 are leader nodes, and 1,2,3 are merged into 0, and 5,6 are merged into 4.
    uint leaderNodeMask = bits(8); // 0b11111111
    uint childBoxMask = laneGroup.Ballot(childIsBox);
    ScratchWideNode childNode;
    if (childIsBox)
    {
        childNode = FetchScratchWideNode(scratchWideNodesScratchOffset, childWideScratchIndex);
    }
    else
    {
        childNode.children0WideNodeIndexOrLeafScratchIndex = 0xffffffff.xxxx;
        childNode.children1WideNodeIndexOrLeafScratchIndex = 0xffffffff.xxxx;
        childNode.bbox_min = float3(FLT_MAX, FLT_MAX, FLT_MAX);
        childNode.bbox_max = float3(-FLT_MAX, -FLT_MAX, -FLT_MAX);
    }
    const uint numBoxesInChild  = childIsBox ? bitFieldExtract(childNode.packedFlags, 0, 4) : 0;
    const uint numLeavesInChild = childIsBox ? bitFieldExtract(childNode.packedFlags, 4, 4) : 0;

    // Merge Scratch Wide Node
    uint targetLane = firstbitlow(childBoxMask);
    uint numBoxesInTarget  = laneGroup.Broadcast(numBoxesInChild, targetLane);
    uint numLeavesInTarget = laneGroup.Broadcast(numLeavesInChild, targetLane);
    uint mergedCount = numBoxesInTarget + numLeavesInTarget;
    uint remaining = childBoxMask & ~(1u << targetLane);

    uint numMergedNodesToCurLeader = 0; // for debugging
    // Lanegroup broadcast is safe because all lanes are active
    while (remaining)
    {
        const uint sourceLane = firstbitlow(remaining);
        GPU_ASSERT(targetLane < 8 && sourceLane < 8);

        uint numBoxesInSource  = laneGroup.Broadcast(numBoxesInChild, sourceLane);
        uint numLeavesInSource = laneGroup.Broadcast(numLeavesInChild, sourceLane);
        mergedCount += (numBoxesInSource + numLeavesInSource);

        // bool shouldSkipMerge = ShouldSkipMerge(laneGroup, scratchNodesScratchOffset, targetLane, sourceLane, numLeavesInTarget, numLeavesInSource);
        // Try Merge
        const bool shouldSkipMerge = ShouldSkipMerge(laneGroup,
                                                    childNode,
                                                    mergedCount,
                                                    numPrimRefs,
                                                    scratchNodesScratchOffset,
                                                    targetLane,
                                                    sourceLane,
                                                    numLeavesInTarget,
                                                    numLeavesInSource);
        if (shouldSkipMerge)
        {
            // Complete current target's merging. re-target to next lane
            targetLane = sourceLane;
            numBoxesInTarget = numBoxesInSource;
            numLeavesInTarget = numLeavesInSource;
            mergedCount = numBoxesInTarget + numLeavesInTarget;
#if SOGANG_EXPERIMENT
            if (numMergedNodesToCurLeader > 0)
            {
                const uint sgDebugCountersOffset = ShaderConstants.offsets.sgDebugCounters;
                ScratchGlobal.InterlockedAdd(sgDebugCountersOffset + numMergedNodesToCurLeader * sizeof(uint), 1);
            }
            numMergedNodesToCurLeader = 0;
#endif
        }
        else
        {
            // Merge success
            // Merge phase 0: Initial Status
            // Shared: [-, -, -, -, -, -, -, -]
            // Target: [B, B, B, L, L, -, -, -]
            // Source: [B, B, L, -, -, -, -, -]

            GPU_ASSERT(laneGroup.Ballot(true) == bits(8)); // Ensure all lanes are active and executing the same branch.

            // Update bounding box
            float3 bbox_min = min(laneGroup.Broadcast(childNode.bbox_min, targetLane), laneGroup.Broadcast(childNode.bbox_min, sourceLane));
            float3 bbox_max = max(laneGroup.Broadcast(childNode.bbox_max, targetLane), laneGroup.Broadcast(childNode.bbox_max, sourceLane));

            // Merge phase 1: Copy source children to shared memory.
            // (Shared = SourceBoxes + SourceLeaves)
            // Shared: [B, B, L, -, -, -, -, -]
            // Target: [B, B, B, L, L, -, -, -]
            // Source: [B, B, L, -, -, -, -, -]
            if (laneGroup.laneIndex == sourceLane)
            {
                SetSharedChildren(laneGroupIndex, 0, childNode.children0WideNodeIndexOrLeafScratchIndex.x);
                SetSharedChildren(laneGroupIndex, 1, childNode.children0WideNodeIndexOrLeafScratchIndex.y);
                SetSharedChildren(laneGroupIndex, 2, childNode.children0WideNodeIndexOrLeafScratchIndex.z);
                SetSharedChildren(laneGroupIndex, 3, childNode.children0WideNodeIndexOrLeafScratchIndex.w);
                SetSharedChildren(laneGroupIndex, 4, childNode.children1WideNodeIndexOrLeafScratchIndex.x);
                SetSharedChildren(laneGroupIndex, 5, childNode.children1WideNodeIndexOrLeafScratchIndex.y);
                SetSharedChildren(laneGroupIndex, 6, childNode.children1WideNodeIndexOrLeafScratchIndex.z);
                SetSharedChildren(laneGroupIndex, 7, childNode.children1WideNodeIndexOrLeafScratchIndex.w);

                childNode.packedFlags = bitFieldInsert(childNode.packedFlags, 8, 1, 0);
                isMergedLane = true;
            }
            GroupMemoryBarrier();
            if (laneGroup.laneIndex == targetLane)
            {
            // Merge phase 2: Copy target's leaf children to shared memory after existing leaf children.
            // (Shared = SourceBoxes + SourceLeaves + TargetLeaves)
            // Shared: [B, B, L, L, L, -, -, -]
            // Target: [B, B, B, L, L, -, -, -]
            // Source: [B, B, L, -, -, -, -, -]
                // Append the target node's leaf children after the source node's box children in shared memory.
                for (uint i = 0; i < numLeavesInTarget; ++i)
                {
                    const uint leafIndex = numBoxesInTarget + i;
                    const uint numSourceChildren = numBoxesInSource + numLeavesInSource;
                    if (leafIndex < 4)
                    {
                        SetSharedChildren(laneGroupIndex, numSourceChildren + i, childNode.children0WideNodeIndexOrLeafScratchIndex[leafIndex]);
                    }
                    else
                    {
                        SetSharedChildren(laneGroupIndex, numSourceChildren + i, childNode.children1WideNodeIndexOrLeafScratchIndex[leafIndex - 4]);
                    }
                }
            // Merge phase 3: Copy Shared children back to target's boxes
            // (Target = TargetBoxes + Shared)
            // Shared: [B, B, L, L, L, -, -, -]
            // Target: [B, B, B, B, B, L, L, L]
            // Source: [B, B, L, -, -, -, -, -]
                for (uint i = numBoxesInTarget; i < mergedCount; ++i)
                {
                    if (i < 4)
                    {
                        childNode.children0WideNodeIndexOrLeafScratchIndex[i] = GetSharedChildren(laneGroupIndex, i - numBoxesInTarget);
                    }
                    else
                    {
                        childNode.children1WideNodeIndexOrLeafScratchIndex[i - 4] = GetSharedChildren(laneGroupIndex, i - numBoxesInTarget);
                    }
                }

                // bounding box
                childNode.bbox_min = bbox_min;
                childNode.bbox_max = bbox_max;

                // child count
                childNode.packedFlags = bitFieldInsert(childNode.packedFlags, 0, 4, numBoxesInTarget + numBoxesInSource);
                childNode.packedFlags = bitFieldInsert(childNode.packedFlags, 4, 4, numLeavesInTarget + numLeavesInSource);
#if SOGANG_EXPERIMENT
                numMergedNodesToCurLeader++;
                if (numBoxesInSource > 0)
                {
                    const uint sgDebugCountersOffset = ShaderConstants.offsets.sgDebugCounters;
                    ScratchGlobal.InterlockedAdd(sgDebugCountersOffset + 0, 1);
                }
#endif
            }
            
            numBoxesInTarget  += numBoxesInSource;
            numLeavesInTarget += numLeavesInSource;
            // Mark source node as a merge candidate. (sourceLane -> 0)
            leaderNodeMask &= ~(1u << sourceLane);

            // Clear SharedChildren
            SetSharedChildren(laneGroupIndex, laneGroup.laneIndex, 0xffffffff);
            GroupMemoryBarrier();
        }
        remaining &= ~(1u << sourceLane);
    }
#if SOGANG_EXPERIMENT
    // Flush the last leader group's count, which the loop above never flushes
    // because it only flushes on overflow (re-target), not on normal loop exit.
    if (numMergedNodesToCurLeader > 0)
    {
        const uint sgDebugCountersOffset = ShaderConstants.offsets.sgDebugCounters;
        ScratchGlobal.InterlockedAdd(sgDebugCountersOffset + numMergedNodesToCurLeader * sizeof(uint), 1);
    }
#endif

    // Clear the leaf bit in the mask.
    leaderNodeMask &= childBoxMask;


    // Update leader lane's node info
    // Mark the current lane as an leader node.
    if (childIsBox)
    {
        const bool isLeaderLane = (leaderNodeMask & (1u << laneGroup.laneIndex)) != 0;
        if (isLeaderLane)
        {
            WriteScratchWideNode(scratchWideNodesScratchOffset, childWideScratchIndex, childNode);
        }
        else
        {
            // Update Flags - mark as 0 to indicate this is not a leader node.
            // const uint packedFlags = bitFieldInsert(childNode.packedFlags, 8, 1, 0);
            const uint packedFlags = 0;
            WriteScratchWideNodeData(scratchWideNodesScratchOffset, childWideScratchIndex, SCRATCH_WIDE_NODE_FLAGS_OFFSET, packedFlags);
        }
    }
    return isMergedLane;
}

//=====================================================================================================================
static bool MergeBoxOnlyNodes(
    LaneGroup                laneGroup,
    in    uint               laneGroupIndex,
    in    uint               childWideScratchIndex,
    in    uint               scratchNodesScratchOffset,
    in    bool               childIsBox)
{
    bool isMergedLane = false;

    uint leaderNodeMask = bits(8); // 0b11111111
    uint childBoxMask = laneGroup.Ballot(childIsBox);
    ScratchWideNode childNode;
    if (childIsBox)
    {
        childNode = FetchScratchWideNode(scratchNodesScratchOffset, childWideScratchIndex);
    }
    else
    {
        childNode.children0WideNodeIndexOrLeafScratchIndex = 0xffffffff.xxxx;
        childNode.children1WideNodeIndexOrLeafScratchIndex = 0xffffffff.xxxx;
        childNode.bbox_min = float3(FLT_MAX, FLT_MAX, FLT_MAX);
        childNode.bbox_max = float3(-FLT_MAX, -FLT_MAX, -FLT_MAX);
    }
    const uint numBoxesInChild  = childIsBox ? bitFieldExtract(childNode.packedFlags, 0, 4) : 0;
    const uint numLeavesInChild = childIsBox ? bitFieldExtract(childNode.packedFlags, 4, 4) : 0;

    // Merge Scratch Wide Node
    // uint boxOnlyChildMask = laneGroup.Ballot(childIsBox && (numLeavesInChild == 0));
    uint boxOnlyChildMask = laneGroup.Ballot(childIsBox && (numBoxesInChild > 0));

    uint targetLane = firstbitlow(boxOnlyChildMask);
    uint numBoxesInTarget  = laneGroup.Broadcast(numBoxesInChild, targetLane);
    uint mergedCount = numBoxesInTarget;
    uint remaining = boxOnlyChildMask & ~(1u << targetLane);

    // Broadcast is safe beacause all lanes are active
    while (remaining)
    {
        const uint sourceLane = firstbitlow(remaining);
        GPU_ASSERT(targetLane < 8 && sourceLane < 8);

        uint numBoxesInSource  = laneGroup.Broadcast(numBoxesInChild, sourceLane);
        mergedCount += numBoxesInSource;
        // Try Merge
        if (mergedCount >= 8)
        {
            // Complete current target's merging. re-target to next lane
            targetLane = sourceLane;
            numBoxesInTarget = numBoxesInSource;
            mergedCount = numBoxesInTarget;
        }
        else
        {
            GPU_ASSERT(false);
            GPU_ASSERT(laneGroup.Ballot(true) == bits(8)); // Ensure all lanes are active and executing the same branch.

            // Update bounding box
            float3 bbox_min = min(laneGroup.Broadcast(childNode.bbox_min, targetLane), laneGroup.Broadcast(childNode.bbox_min, sourceLane));
            float3 bbox_max = max(laneGroup.Broadcast(childNode.bbox_max, targetLane), laneGroup.Broadcast(childNode.bbox_max, sourceLane));

            if (laneGroup.laneIndex == sourceLane)
            {
                [unroll]
                for (uint i = 0; i < numBoxesInSource; ++i)
                {
                    if (i < 4)
                    {
                        SetSharedChildren(laneGroupIndex, i, childNode.children0WideNodeIndexOrLeafScratchIndex[i]);
                    }
                    else
                    {
                        SetSharedChildren(laneGroupIndex, i, childNode.children1WideNodeIndexOrLeafScratchIndex[i - 4]);
                    }
                }
                childNode.packedFlags = bitFieldInsert(childNode.packedFlags, 8, 1, 0);
                isMergedLane = true;
            }
            GroupMemoryBarrier();
            if (laneGroup.laneIndex == targetLane)
            {
                for (uint i = numBoxesInTarget; i < mergedCount; ++i)
                {
                    if (i < 4)
                    {
                        childNode.children0WideNodeIndexOrLeafScratchIndex[i] = GetSharedChildren(laneGroupIndex, i);
                    }
                    else
                    {
                        childNode.children1WideNodeIndexOrLeafScratchIndex[i - 4] = GetSharedChildren(laneGroupIndex, i);
                    }
                }

                // bounding box
                childNode.bbox_min = bbox_min;
                childNode.bbox_max = bbox_max;

                // child count
                childNode.packedFlags = bitFieldInsert(childNode.packedFlags, 0, 4, numBoxesInTarget + numBoxesInSource);
            }
            
            numBoxesInTarget  += numBoxesInSource;
            // Mark source node as a merge candidate. (sourceLane -> 0)
            leaderNodeMask &= ~(1u << sourceLane);

            // Clear SharedChildren
            SetSharedChildren(laneGroupIndex, laneGroup.laneIndex, 0xffffffff);
            GroupMemoryBarrier();
        }
        remaining &= ~(1u << sourceLane);
    }


    // Clear the leaf bit in the mask.
    leaderNodeMask &= childBoxMask;

    // If result of mask is 10010001,
    // that means 0,4,7 are leader node, and 1,2,3 are merged into 0, and 5,6 are merged into 4.

    // Update leader lane's node info
    // Mark the current lane as an leader node.
    if (childIsBox)
    {
        const bool isLeaderLane = (leaderNodeMask & (1u << laneGroup.laneIndex)) != 0;
        if (isLeaderLane)
        {
            WriteScratchWideNode(scratchNodesScratchOffset, childWideScratchIndex, childNode);
        }
        else
        {
            // Update Flags - mark as 0 to indicate this is not a leader node.
            // const uint packedFlags = bitFieldInsert(childNode.packedFlags, 8, 1, 0);
            const uint packedFlags = 0;
            WriteScratchWideNodeData(scratchNodesScratchOffset, childWideScratchIndex, SCRATCH_WIDE_NODE_FLAGS_OFFSET, packedFlags);
        }
    }
    return isMergedLane;
}

//=====================================================================================================================
static void EncodeCompressedBoxNode(
    LaneGroup                laneGroup,
    in    uint               rootNodeIndex,
    in    uint               scratchNodesScratchOffset,
    in    uint               scratchWideNodesScratchOffset,
    in    uint               localId,
    in    uint               parentWideScratchNodeIndex,
    in    uint               bvhNodeDstIdx,
    in    uint               currNodePtr,
    in    uint               currNodeOffset,
    in    uint               indexInParent,
    in    AccelStructOffsets offsets,
    in    uint               maxNumChildren,
    in    uint               numPrimRefs,
    in    bool               isRebraidRootNode)
{
    uint baseDstBoxIdx      = 0; // node's first box child's index from total nodes
    uint numLeafChildren    = 0; // num of leaf of parent node
    uint numBoxChildren     = 0; // num of box of parent node
    uint dstStackIdx        = 0;
    uint baseLeafNodeOffset = 0; // node's first leaf child's byte offset
    uint baseBoxNodeOffset  = 0; // node's first box child's byte offset (allBoxOffset + baseDstBoxIdx * sizeof(QBVH8::Node))
    float3 rcpExponents     = 0;
    uint3 exponents;
    BoundingBox parentBbox;
    const uint laneGroupIndex = localId / LANE_GROUP_SIZE; // lane group index within the thread group, not within the wave.

    bool needToLoad = false;
    uint parentScratchNodeIdx = INVALID_IDX;
    uint childWideScratchIndex;
#if USE_LDS_CHILDREN
    // clear shared memory
    [unroll]
    for (uint i = localId; i < MAX_LDS_ELEMENTS_PER_THREADGROUP; i += BUILD_THREADGROUP_SIZE)
    {
        SetSharedMem(i, INVALID_IDX);
    }
    GroupMemoryBarrier();
#else
// USE Reigster children
    uint children8[8] = { INVALID_IDX, INVALID_IDX, INVALID_IDX, INVALID_IDX, INVALID_IDX, INVALID_IDX, INVALID_IDX, INVALID_IDX };
#endif
    uint parentWideNodePackedFlags;
    // Initialization for the first lane
    if (laneGroup.IsFirstLane())
    {
        const ScratchWideNode scratchWideNode = FetchScratchWideNode(scratchWideNodesScratchOffset, parentWideScratchNodeIndex);
        parentScratchNodeIdx = scratchWideNode.scratchIndex;
#if USE_LDS_CHILDREN
        SetSharedChildren(laneGroupIndex, 0, scratchWideNode.children0WideNodeIndexOrLeafScratchIndex.x);
        SetSharedChildren(laneGroupIndex, 1, scratchWideNode.children0WideNodeIndexOrLeafScratchIndex.y);
        SetSharedChildren(laneGroupIndex, 2, scratchWideNode.children0WideNodeIndexOrLeafScratchIndex.z);
        SetSharedChildren(laneGroupIndex, 3, scratchWideNode.children0WideNodeIndexOrLeafScratchIndex.w);

        SetSharedChildren(laneGroupIndex, 4, scratchWideNode.children1WideNodeIndexOrLeafScratchIndex.x);
        SetSharedChildren(laneGroupIndex, 5, scratchWideNode.children1WideNodeIndexOrLeafScratchIndex.y);
        SetSharedChildren(laneGroupIndex, 6, scratchWideNode.children1WideNodeIndexOrLeafScratchIndex.z);
        SetSharedChildren(laneGroupIndex, 7, scratchWideNode.children1WideNodeIndexOrLeafScratchIndex.w);
#else
        children8[0] = scratchWideNode.children0WideNodeIndexOrLeafScratchIndex.x;
        children8[1] = scratchWideNode.children0WideNodeIndexOrLeafScratchIndex.y;
        children8[2] = scratchWideNode.children0WideNodeIndexOrLeafScratchIndex.z;
        children8[3] = scratchWideNode.children0WideNodeIndexOrLeafScratchIndex.w;

        children8[4] = scratchWideNode.children1WideNodeIndexOrLeafScratchIndex.x;
        children8[5] = scratchWideNode.children1WideNodeIndexOrLeafScratchIndex.y;
        children8[6] = scratchWideNode.children1WideNodeIndexOrLeafScratchIndex.z;
        children8[7] = scratchWideNode.children1WideNodeIndexOrLeafScratchIndex.w;
#endif
        parentWideNodePackedFlags = scratchWideNode.packedFlags;
        // GPU_ASSERT(bitFieldExtract(parentWideNodePackedFlags, 8, 1) == 1);
        numBoxChildren = bitFieldExtract(parentWideNodePackedFlags, 0, 4);
        GPU_ASSERT(numBoxChildren <= 8);
    }
#if USE_LDS_CHILDREN
    childWideScratchIndex = GetSharedChildren(laneGroupIndex, laneGroup.laneIndex);
#else
    [unroll]
    for (uint i = 0; i < 8; ++i)
    {
        children8[i] = laneGroup.ReadFirstLane(children8[i]);
    }
    childWideScratchIndex = children8[laneGroup.laneIndex];
#endif
    parentWideNodePackedFlags = laneGroup.ReadFirstLane(parentWideNodePackedFlags);
    if (bitFieldExtract(parentWideNodePackedFlags, 8, 1) == 0) { return; } // Early return for merged nodes

    parentScratchNodeIdx = laneGroup.ReadFirstLane(parentScratchNodeIdx);
    numBoxChildren = laneGroup.ReadFirstLane(numBoxChildren);
    bool isValidChild = (childWideScratchIndex != INVALID_IDX);
    const bool childIsBox = (laneGroup.laneIndex < numBoxChildren) && (childWideScratchIndex != INVALID_IDX);
    const bool childIsLeaf = (laneGroup.laneIndex >= numBoxChildren) && (childWideScratchIndex != INVALID_IDX);
    numLeafChildren = laneGroup.BallotCount(childIsLeaf);

    uint boxOrLeafChildIndex = childIsBox ? laneGroup.laneIndex : laneGroup.laneIndex - numBoxChildren;

    bool isMerged = MergeBoxNodes(laneGroup,
                                  laneGroupIndex,
                                  scratchNodesScratchOffset,
                                  scratchWideNodesScratchOffset,
                                  childWideScratchIndex,
                                  numPrimRefs,
                                  childIsBox);
    const bool isLeaderBoxChild = childIsBox && !isMerged;
    const bool isMergedBoxChild = childIsBox && isMerged;

    const uint leaderBoxMask = laneGroup.Ballot(isLeaderBoxChild);
    const uint mergedBoxMask = laneGroup.Ballot(isMergedBoxChild);

    const uint numLeaderBoxChildren = countbits(leaderBoxMask);
    const uint numMergedBoxChildren = countbits(mergedBoxMask);

    // Write leader box mask to parent node
    if (laneGroup.IsFirstLane())
    {
        parentWideNodePackedFlags = bitFieldInsert(parentWideNodePackedFlags, 9, 8, leaderBoxMask & bits(8));
        WriteScratchWideNodeData(scratchWideNodesScratchOffset, parentWideScratchNodeIndex, SCRATCH_WIDE_NODE_FLAGS_OFFSET, parentWideNodePackedFlags);
    }
#if (MERGE_BOX_NODES_FLAG_RTIP3_1 > 1)
    uint shiftedMask = leaderBoxMask & ((1u << laneGroup.laneIndex) - 1);
    const uint boxChildCompactedIndexInParent = countbits(shiftedMask);
    const uint boxChildIndexInParent = boxChildCompactedIndexInParent;
    const bool pushToStack = isLeaderBoxChild;
#else
    const uint boxChildIndexInParent = laneGroup.laneIndex;
    const bool pushToStack = childIsBox;
#endif // (MERGE_BOX_NODES_FLAG_RTIP3_1 > 1)

    if (laneGroup.IsFirstLane())
    {
        IncrementAccelStructHeaderField(ACCEL_STRUCT_HEADER_NUM_INTERNAL_FP32_NODES_OFFSET, 1);
        const uint numInlinePrimStructs = 0;
        // This code assumes STACK_PTRS_SRC_PTR_OFFSET and STACK_PTRS_DST_PTR_OFFSET are in consecutive
        // DWORDs.
        const uint stackPtrOffset = ShaderConstants.offsets.qbvhGlobalStackPtrs;
#if (MERGE_BOX_NODES_FLAG_RTIP3_1 > 1)
        const uint numBoxchildrenToPush = numLeaderBoxChildren;
#else
        const uint numBoxchildrenToPush = numBoxChildren;
#endif
        ScratchGlobal.InterlockedAdd(stackPtrOffset + STACK_PTRS_DST_PTR_OFFSET, numBoxchildrenToPush + numInlinePrimStructs, dstStackIdx);
    }


    if (laneGroup.IsFirstLane())
    {
        baseDstBoxIdx = dstStackIdx;
        baseBoxNodeOffset = offsets.internalNodes + baseDstBoxIdx * QBVH8::NodeSizeInBytes;
    }
    dstStackIdx       = laneGroup.ReadFirstLane(dstStackIdx);
    baseDstBoxIdx     = laneGroup.ReadFirstLane(baseDstBoxIdx);
    baseBoxNodeOffset = laneGroup.ReadFirstLane(baseBoxNodeOffset);

    if (isValidChild)
    {
        if (pushToStack)
        {
            GPU_ASSERT(childWideScratchIndex != INVALID_IDX);
            uint childStackIdx = dstStackIdx + boxChildIndexInParent;
            // DstIndex and LocalIndex
            uint packedDstNodeIdx = PackStackDstNodeIdx(baseDstBoxIdx + boxChildIndexInParent, boxChildIndexInParent);

            // Regular operation for other threads with isBox set
            ScratchGlobal.Store2(ShaderConstants.offsets.qbvhGlobalStack + (childStackIdx * sizeof(uint2)),
                            uint2(childWideScratchIndex, packedDstNodeIdx));
        }
    }

    // Write Parent Result Node
    uint basePrimStructIdx = 0;
    const uint validChildCount = laneGroup.BallotCount(isValidChild);
    if (laneGroup.IsFirstLane())
    {
        const ScratchNode parentScratchNode = FetchScratchNode(scratchNodesScratchOffset, parentScratchNodeIdx);
        // Fetch bounding box data from the wide node, as merged nodes may have changed
        parentBbox.min = FetchScratchWideNodeData<float3>(scratchWideNodesScratchOffset, parentWideScratchNodeIndex, SCRATCH_WIDE_NODE_BBOX_MIN_OFFSET);
        parentBbox.max = FetchScratchWideNodeData<float3>(scratchWideNodesScratchOffset, parentWideScratchNodeIndex, SCRATCH_WIDE_NODE_BBOX_MAX_OFFSET);

        // The root of the BVH2 treelet contains the combined bounds of the child nodes in the node array. Compute the
        // common exponent from the root node bounds
        exponents = ComputeCommonExponent(parentBbox.min, parentBbox.max, 12);

        // Pre-compute exponent reciprocal
        rcpExponents = ComputeFastExpReciprocal(exponents, 12);

        QBVH8::WriteInternalNodeBaseOffset(currNodeOffset, baseBoxNodeOffset);
        if (EnableWaveLeafCompressionPass() == false)
        {
            QBVH8::WriteLeafNodeBaseOffset(currNodeOffset, baseLeafNodeOffset);
        }
        QBVH8::WriteLeafNodeBaseOffset(currNodeOffset, INVALID_NODE);

        QBVH8::WriteOrigin(currNodeOffset, parentBbox.min);

#if 0
        // The box sort disabled bit indicates that merged-node de-duplication is enabled instead of the default de-duplication method.
        const uint deduplicate = (uint)(numBoxChildren != numLeaderBoxChildren);
        WritePackedExpDisableBoxSortChildIdxAndCount(currNodeOffset, exponents, deduplicate, indexInParent, validChildCount);
#else
        QBVH8::WritePackedExpChildIdxAndCount(currNodeOffset, exponents, indexInParent, validChildCount);
#endif
        // Store the source box bitfield in the upper bits of the OBB DWORD (unused by HW). This is used to construct
        // four filter boxes for instances.
        uint packedFlags = FetchScratchWideNodeData<uint>(scratchWideNodesScratchOffset, parentWideScratchNodeIndex, SCRATCH_WIDE_NODE_FLAGS_OFFSET);
        uint obbMatrixIndex = INVALID_OBB;
#if (MERGE_BOX_NODES_FLAG_RTIP3_1 == 1)
        const uint childrenLeaderMask = bitFieldExtract(packedFlags, 9, 8);
        obbMatrixIndex = bitFieldInsert(obbMatrixIndex, 7, 8, childrenLeaderMask);
#endif
        QBVH8::WriteObbMatrixIndex(currNodeOffset, obbMatrixIndex);
    }

    parentBbox.min    = laneGroup.ReadFirstLane(parentBbox.min);
    parentBbox.max    = laneGroup.ReadFirstLane(parentBbox.max);
    exponents         = laneGroup.ReadFirstLane(exponents);
    rcpExponents      = laneGroup.ReadFirstLane(rcpExponents);
    basePrimStructIdx = laneGroup.ReadFirstLane(basePrimStructIdx);

    ScratchNode childScratchNode;
    uint childScratchNodeIndex = INVALID_IDX;
    if (childIsBox)
    {
        childScratchNodeIndex = FetchScratchWideNodeData<uint>(scratchWideNodesScratchOffset, childWideScratchIndex, SCRATCH_WIDE_NODE_SCRATCH_INDEX_OFFSET);
    }
    else if (childIsLeaf)
    {
        childScratchNodeIndex = childWideScratchIndex;
    }

    if (isValidChild)
    {
        // TLAS builds initialize these fields immediately. They should be left 0 for BLAS builds if we are compressing
        // leaf nodes. If we are not compressing, a single triangle primitive structure is produced immediately.
        // Either way the triangle node type field is 0.
        const uint nodeType        = childIsLeaf ? NODE_TYPE_TRIANGLE_0 : NODE_TYPE_BOX_QUANTIZED_BVH8;
        const uint nodeRangeLength = childIsLeaf ? (EnableLeafCompressionPass() ? 0 : 1) :
#if (MERGE_BOX_NODES_FLAG_RTIP3_1 == 1) //Not hardware format support.
                                                    1;
#elif (MERGE_BOX_NODES_FLAG_RTIP3_1 == 2)
                                                    // During the decode stage of traverse, nodeRangeLength indicates how many
                                                    // internal nodes away the next sibling is from this boxNode. If the right
                                                    // sibling has been merged and invalidated, increment it by 0 so that it
                                                    // points to the same node as the left sibling.
                                                    ((leaderBoxMask & (1u << (laneGroup.laneIndex + 1))) == 0) ? 0 : 1;
#else
                                                    1;
#endif
        const uint baseNodeOffset  = childIsLeaf ? baseLeafNodeOffset : baseBoxNodeOffset;
        const uint offset          = childIsLeaf ? boxOrLeafChildIndex + numBoxChildren : boxOrLeafChildIndex;
        const uint childNodeOffset = baseNodeOffset + 
                (childIsLeaf ? boxOrLeafChildIndex : boxChildIndexInParent) * QBVH8::NodeSizeInBytes;

        BoundingBox childBbox;
        childScratchNode = FetchScratchNode(scratchNodesScratchOffset, childScratchNodeIndex);
        childBbox = GetScratchNodeBoundingBoxTS(scratchNodesScratchOffset, IsLeafNode(childScratchNodeIndex, numPrimRefs), childScratchNode);

        // uint childPackedFlags = FetchScratchNodeData<uint>(scratchNodesScratchOffset, childScratchNodeIndex, SCRATCH_NODE_FLAGS_OFFSET);
        const uint3 childInfo = ComputePackedChildInfo(childBbox,
                                                       childScratchNode.packedFlags,
                                                       childScratchNodeIndex,
                                                       nodeType,
                                                       nodeRangeLength,
                                                       rcpExponents,
                                                       parentBbox.min,
                                                       numPrimRefs);
        QBVH8::WritePackedChildInfo(currNodeOffset, offset, childInfo);

        if (isLeaderBoxChild)
        {
            QBVH8::WriteParentPointer(childNodeOffset, currNodePtr);
        }
    }
    else
    {
        QBVH8::WriteInvalidChildInfo(currNodeOffset, laneGroup.laneIndex);
    }

    // OBB preparation
    if (IsObbEnabled())
    {
        // childScratchNodeIndex
        float aabbSa = 0.0f;
        if (childScratchNodeIndex != INVALID_IDX)
        {
            aabbSa = GetScratchNodeSurfaceArea(
                scratchNodesScratchOffset, childScratchNodeIndex, childScratchNode, numPrimRefs);
        }

        const float aabbSum = laneGroup.Sum(aabbSa);
        const float aabbMax = laneGroup.Max(aabbSa);
        const uint aabbMaxChildIdx = laneGroup.GetFirstActiveLaneIndex(aabbSa == aabbMax);

        uint aabbMaxDstChildIdx = aabbMaxChildIdx;
        uint bestObbMatrixIdx = INVALID_OBB;
        if ((aabbMaxChildIdx == laneGroup.laneIndex) && (childIsLeaf))
        {
            aabbMaxDstChildIdx = isMergedBoxChild ? boxChildIndexInParent : aabbMaxDstChildIdx;
            if (childIsLeaf)
            {
                uint packedFlags = childScratchNode.packedFlags;
                
                bool isCollapse = childScratchNode.numPrimitivesAndDoCollapse & 1;

                if (CollapseAnyPairs())
                {
                    isCollapse = (childScratchNode.numPrimitivesAndDoCollapse >> 1) == 2;
                }

                if (isCollapse)
                {
                    // Triangles in a range are colocated and tend to share a similar orientation, so
                    // choosing one at random from the range is about as effective as choosing one with
                    // a more sophisticated heuristic.
                    //
                    // Pick the first triangle in the range as an approximation.
                    uint triNodeIdx = childScratchNode.left_or_primIndex_or_instIndex;

                    if (UsePrimIndicesArray())
                    {
                        triNodeIdx = GetPrimRefIdx(FetchSortedPrimIndex(ShaderConstants.offsets.primIndicesSorted,
                                                                        childScratchNode.sortedPrimIndex), numPrimRefs);
                    }

                    packedFlags =
                        FetchScratchNodeData<uint>(scratchNodesScratchOffset, triNodeIdx, SCRATCH_NODE_FLAGS_OFFSET);
                }

                bestObbMatrixIdx = ExtractScratchNodeObbMatrixIdx(packedFlags);
            }
        }

        bestObbMatrixIdx = laneGroup.Broadcast(bestObbMatrixIdx, aabbMaxChildIdx);
        aabbMaxDstChildIdx = laneGroup.Broadcast(aabbMaxDstChildIdx, aabbMaxChildIdx);

        if (laneGroup.IsFirstLane())
        {
            if (numBoxChildren == 0)
            {
                uint obbRefitStackIndex = 0;

                ScratchGlobal.InterlockedAdd(
                    ShaderConstants.offsets.obbRefitStackPtrs + STACK_PTRS_OBB_REFIT_BATCH_COUNT, 1, obbRefitStackIndex);

                ScratchGlobal.Store(
                    ShaderConstants.offsets.obbRefitStack + (obbRefitStackIndex * sizeof(uint)), bvhNodeDstIdx);
            }

            // OBB refit flags are packed as follows:
            // b[0:3] : 2's complement of box child count. The maximum value can be 8. That requires 3 bits plus the sign
            //          bit --> 4 bits. The maximum carry bits (for when box count is incremented by refit kernel)
            //          is 1, but we have plenty more room.
            // b[4:15] : 2's complement increment overflow bits.
            // b[16:23]: Child index with maximum AABB surface area for this node.
            // b[24:31]: OBB matrix index of the best leaf node amongst the children. This is precomputed and stored in
            //           scratch node during morton code generation phase to absorb the VGPR impact of that computation.
            const uint encodedBits = (bestObbMatrixIdx << 24u) |
                                     (aabbMaxDstChildIdx  << 16u) |
                                     ((numBoxChildren ^ 0xFu) + 1);

            const uint obbFlagsOffset = ShaderConstants.offsets.qbvhObbFlags + (bvhNodeDstIdx * OBB_TABLE_ENTRY_SIZE);
            ScratchGlobal.Store<uint2>(obbFlagsOffset, uint2(encodedBits, asuint(aabbSum)));
        }
    }

    if (laneGroup.IsFirstLane())
    {
        ScratchGlobal.InterlockedAdd(ShaderConstants.offsets.wideNodeEncodingDoneCounter, 1 + numMergedBoxChildren);
    }
    uint localPrimCount = 0;
    if (childScratchNodeIndex != INVALID_IDX)
    {
        if (childIsLeaf)
        {
            localPrimCount = FetchScratchNodeNumPrimitives(childScratchNode, IsLeafNode(childScratchNodeIndex, numPrimRefs));
        }
    }

    const uint primCount = WaveActiveSum(localPrimCount);

    const uint numEmptySlots = maxNumChildren - (numBoxChildren + numLeafChildren);


    if (EnableWaveLeafCompressionPass() && (numLeafChildren > 0))
    {
        WritePrimCompBatches3_1(laneGroup,
                                rootNodeIndex,
                                scratchNodesScratchOffset,
                                parentScratchNodeIdx,
                                currNodeOffset,
                                numBoxChildren,
                                numLeafChildren,
                                primCount,
                                numPrimRefs,
                                childScratchNodeIndex,
                                boxOrLeafChildIndex,
                                childIsLeaf);
    }

    // Write fat leaf offsets.
    if (IsUpdateAllowed() && (numBoxChildren == 0) && laneGroup.IsFirstLane())
    {
        const uint index = IncrementAccelStructHeaderField(ACCEL_STRUCT_HEADER_NUM_INTERNAL_FP16_NODES_OFFSET, 1);
        const uint baseUpdatePtrOffset = offsets.primNodePtrs + (ShaderConstants.maxNumPrimitives * sizeof(uint));
        DstBuffer.Store(baseUpdatePtrOffset + (index * sizeof(uint)), currNodeOffset);
    }
}

//=====================================================================================================================
// Convert source BVH2 (in scratch memory) into RTIP3.1 compatible hardware format
void EncodeScratchBvhImpl(
    uint globalId,
    uint localId,
    uint numPrimRefs,
    uint numScratchWideNodes)
{
    GPU_ASSERT(EnableWaveLeafCompressionPass());
    const AccelStructOffsets offsets = ShaderConstants.header.offsets;

    const uint rootNodeIndex = GetBvh2RootNodeIndex();
    const uint scratchNodesScratchOffset     = CalculateBvhNodesOffset(ShaderConstants, numPrimRefs);
    const uint scratchWideNodesScratchOffset = ShaderConstants.offsets.bvhWideNodeData;

    const bool isSinglePrimBvh = (numPrimRefs == 1);

    const ScratchNode rootScratchNode = FetchScratchNode(scratchNodesScratchOffset, rootNodeIndex);
    const uint numActivePrims = FetchScratchNodeNumPrimitives(rootScratchNode, isSinglePrimBvh);

    if (IsObbEnabled())
    {
        if (globalId < numScratchWideNodes)
        {
            ScratchGlobal.Store<uint2>(ShaderConstants.offsets.qbvhObbFlags + globalId * OBB_TABLE_ENTRY_SIZE, 0);
        }
    }
    if (globalId == 0)
    {
        const BoundingBox bbox =
            GetScratchNodeBoundingBoxTS(scratchNodesScratchOffset, isSinglePrimBvh, rootScratchNode);

        WriteAccelStructHeaderRootBoundingBox(bbox);

        const uint3 exponents = ComputeCommonExponent(bbox.min, bbox.max, 12);

        // Pre-compute exponent reciprocal
        const float3 rcpExponents = ComputeFastExpReciprocal(exponents, 12);

        // Generate intersectable instance node data in BLAS metadata
        if ((Settings.instanceMode == InstanceMode::Passthrough) || isSinglePrimBvh)
        {
            const uint instanceMask =
                ExtractScratchNodeInstanceMask(rootScratchNode.packedFlags);

            const uint blasRootNodePointer = CreateRootNodePointer3_1();
            WriteInstancePassthrough(blasRootNodePointer,
                                        bbox,
                                        ACCEL_STRUCT_METADATA_INSTANCE_NODE_OFFSET);
        }
        else if (Settings.instanceMode == InstanceMode::FilterNode)
        {
            // Generate filter node data in BLAS metadata
            WriteBlasInstanceFilterNode(scratchNodesScratchOffset,
                                        numPrimRefs,
                                        rootNodeIndex,
                                        bbox.min,
                                        exponents,
                                        rcpExponents);
        }

        DstBuffer.Store(ACCEL_STRUCT_HEADER_PACKED_FLAGS_OFFSET, rootScratchNode.packedFlags);

        // Write parent pointer for root node.
        QBVH8::WriteParentPointer(offsets.internalNodes, INVALID_IDX);
    }

    LaneGroup laneGroup;
    laneGroup.Alloc(8);

    // Each stack item stores data for writes to linear QBVH memory, indexed by stack index
    const uint globalStackIndex = globalId / 8;

    // With early pairing enabled, numPrimRefs represents the active primitive references. However,
    // we need to use the active primitive count to estimate the hardware internal node count.
    bool isGlobalStackEntryDone = (globalStackIndex >= numScratchWideNodes);

    const uint maxNumChildren = 8;
    while (isGlobalStackEntryDone == false)
    {
        uint numWideNodeDone = 0;
        if (WaveIsFirstLane())
        {
            numWideNodeDone = ScratchGlobal.Load(ShaderConstants.offsets.wideNodeEncodingDoneCounter);
        }
        numWideNodeDone = WaveReadLaneFirst(numWideNodeDone);
        if (numWideNodeDone >= numScratchWideNodes)
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
            const uint bvhWideNodeSrcIdx = stackEntry.x; // parentWideScratchNodeIndex
            const uint bvhNodeDstIdx = GetStackDstIdx(stackEntry.y);
            const uint indexInParent = GetStackDstIdxInParent(stackEntry.y);
            const uint currNodeAddr = offsets.internalNodes + (bvhNodeDstIdx * QBVH8::NodeSizeInBytes);
            const uint currNodePtr = CreateBoxNodePointer(currNodeAddr, false);
            
            // Pull up the nodes chosen by SAH to be the new children in BVH8
            EncodeCompressedBoxNode(laneGroup,
                                    rootNodeIndex,
                                    scratchNodesScratchOffset,
                                    scratchWideNodesScratchOffset,
                                    localId,
                                    bvhWideNodeSrcIdx,
                                    bvhNodeDstIdx,
                                    currNodePtr,
                                    currNodeAddr, // currNodeOffset
                                    indexInParent,
                                    offsets,
                                    maxNumChildren,
                                    numPrimRefs,
                                    false);

            isGlobalStackEntryDone = true;
        }
    }
}

} // namespace Gfx12

#endif

#if NO_SHADER_ENTRYPOINT == 0
//=====================================================================================================================
// Main Function : EncodeScratchBvh
//=====================================================================================================================
[RootSignature(RootSig)]
[numthreads(BUILD_THREADGROUP_SIZE, 1, 1)]
void EncodeScratchBvh(
    uint globalIdIn : SV_DispatchThreadID,
    uint groupIdIn  : SV_GroupID,
    uint localIdIn  : SV_GroupThreadID)
{
#if GPURT_BUILD_RTIP3_1 && MERGE_BOX_NODES_FLAG_RTIP3_1
    uint globalId = globalIdIn;
    uint localId  = localIdIn;
    uint groupId  = groupIdIn;

    const uint numScratchWideNodes = ScratchGlobal.Load(ShaderConstants.offsets.scratchWideNodeCounter);
    const uint numActivePrims = ReadAccelStructHeaderField(ACCEL_STRUCT_HEADER_NUM_ACTIVE_PRIMS_OFFSET);

    uint numTasksWait = 0;
    uint waveId       = 0;

    INIT_TASK;

    BEGIN_TASK(1)
    if (globalId == 0)
    {
        const uint rootWideNodeIndex = 0;
        InitStackPtrs(rootWideNodeIndex);
        Gfx12::InitObbRefitStackPtrs();
    }
    END_TASK(1);
    BEGIN_TASK(RoundUpQuotient(numScratchWideNodes, BUILD_THREADGROUP_SIZE));
    ClearStackPtrs(globalId, numScratchWideNodes, ShaderRootConstants.NumThreads());
    END_TASK(RoundUpQuotient(numScratchWideNodes, BUILD_THREADGROUP_SIZE));

    const uint numThreads = numScratchWideNodes * 8;
    BEGIN_TASK(RoundUpQuotient(numThreads, BUILD_THREADGROUP_SIZE));
    Gfx12::EncodeScratchBvhImpl(globalId, localId, numActivePrims, numScratchWideNodes);
    END_TASK(RoundUpQuotient(numThreads, BUILD_THREADGROUP_SIZE));

#if GPURT_ENABLE_GPU_DEBUG
    BEGIN_TASK(1);
    if (globalId == 0)
    {
        const uint numBoxNodes = ScratchGlobal.Load(ShaderConstants.offsets.qbvhGlobalStackPtrs + STACK_PTRS_DST_PTR_OFFSET);
        GPU_DPF("numOriginalBoxNodes: %u, numDstBoxNodes: %u",numScratchWideNodes, numBoxNodes);
    }
    END_TASK(1);
#endif

    BEGIN_TASK(1);
    PostHwBvhBuild(localId, numActivePrims);

    if (globalId == 0)
    {
        if (Gfx12::EnableWaveLeafCompressionPass())
        {
            // The CompressPrims dispatch requires one group per compression batch plus enough groups to process the
            // entire single prims list
            const uint compressBatches =
                RoundUpQuotient(FetchCompressPrimBatchCount(ShaderConstants.offsets.qbvhGlobalStackPtrs),
                                COMPRESSION_BATCHES_PER_GROUP);

            const uint singlePrimCount  = FetchCompressPrimSingleCount(ShaderConstants.offsets.qbvhGlobalStackPtrs);
            const uint singlePrimGroups = RoundUpQuotient(RoundUpQuotient(singlePrimCount, 2), PRIM_COMP_GROUP_SIZE);

            ScratchGlobal.Store(ShaderConstants.offsets.qbvhGlobalStackPtrs + STACK_PTRS_PRIM_COMP_GROUP_COUNT_X,
                                compressBatches + singlePrimGroups);
        }

        if (IsObbEnabled())
        {
            const uint obbRefitBatchCount =
                ScratchGlobal.Load(ShaderConstants.offsets.obbRefitStackPtrs + STACK_PTRS_OBB_REFIT_BATCH_COUNT);

            // Note, a group of 8 lanes works on a single internal node.
            const uint obbRefitGroupCount = RoundUpQuotient(obbRefitBatchCount,
                                                            REFIT_ORIENTED_BOUNDS3_1_THREADGROUP_SIZE / 8u);
            ScratchGlobal.Store(ShaderConstants.offsets.obbRefitStackPtrs + STACK_PTRS_OBB_REFIT_GROUP_COUNT_X,
                                obbRefitGroupCount);

            GPU_DPF("numObbRefitBatches: %u, numObbRefitGroups: %u", obbRefitBatchCount, obbRefitGroupCount);
            
            const float saMergeEfficiencyMax = ScratchGlobal.Load(ShaderConstants.offsets.sgDebugCounters + 0);
            GPU_DPF("saMergeEfficiency * 1,000: %u", uint(saMergeEfficiencyMax * 1000.0f));
        }
    }

#if GPURT_ENABLE_GPU_DEBUG
    END_TASK(1);
#else
    END_TASK_NO_WAIT(1);
#endif

#endif
}
#endif

#undef USE_LDS_CHILDREN
#undef MERGE_CONSIDERING_DOBB
#endif
