#ifndef _MERGE_SCRATCH_NODES_HLSL
#define _MERGE_SCRATCH_NODES_HLSL


uint GetSharedChildren(uint laneGroupIndex, uint childIndex);
void SetSharedChildren(uint laneGroupIndex, uint childIndex, uint value);

#ifndef MERGE_CONSIDERING_DOBB
#define MERGE_CONSIDERING_DOBB 0
#endif

#include "../../shadersClean/common/LaneGroup.hlsli"
#include "../../shadersClean/common/ScratchWideNode.hlsli"
#include "../../shadersClean/common/ObbCommon.hlsli"
#include "../../shadersClean/build/BuildCommonScratch.hlsli"
#include "../EncodeHwBvhCommon3_1.hlsl"

//=====================================================================================================================
static bool ShouldCompleteMerge(
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

    bool shouldCompleteMerge = false;
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
    shouldCompleteMerge = unmergedSaSum * obbPenalty < mergedSaSum;

#endif // MERGE_CONSIDERING_DOBB
    return shouldCompleteMerge;
}

//=====================================================================================================================
// Consecutive greedy merging method from "Memory-Efficient BVH" (HPG 2026)
// This function is no longer used; MergeLeafOnlyBoxNodes() is the default.
// Fast top-down greedy collapsing guarantees that only leaf-only boxes are merged.
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

        // Try Merge
        const bool shouldCompleteMerge = ShouldCompleteMerge(laneGroup,
                                                    childNode,
                                                    mergedCount,
                                                    numPrimRefs,
                                                    scratchNodesScratchOffset,
                                                    targetLane,
                                                    sourceLane,
                                                    numLeavesInTarget,
                                                    numLeavesInSource);
        if (shouldCompleteMerge)
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
            if (numBoxesInTarget > 0 || numBoxesInSource > 0)
            {
                GPU_DPF("MergeBoxNodes: Merging target lane %u (boxes=%u, leaves=%u) with source lane %u (boxes=%u, leaves=%u), mergedCount=%u\n",
                    targetLane, numBoxesInTarget, numLeavesInTarget,
                    sourceLane, numBoxesInSource, numLeavesInSource,
                    mergedCount);
            }
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
            // packedFlags from merged child are no longer used.
            const uint packedFlags = 0;
            WriteScratchWideNodeData(scratchWideNodesScratchOffset, childWideScratchIndex, SCRATCH_WIDE_NODE_FLAGS_OFFSET, packedFlags);
        }
    }
    return isMergedLane;
}

//=====================================================================================================================
// Consecutive greedy merging method from "Memory-Efficient BVH" (HPG 2026)
// Fast top-down greedy collapsing guarantees that only leaf-only boxes are merged.
static bool MergeLeafOnlyBoxNodes(
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
    const uint numChildrenInChild = childIsBox ? bitFieldExtract(childNode.packedFlags, 4, 4) : 0;

    // Merge Scratch Wide Node
    uint targetLane = firstbitlow(childBoxMask);
    uint numBoxesInTarget  = laneGroup.Broadcast(numBoxesInChild, targetLane);
    uint numLeavesInTarget = laneGroup.Broadcast(numLeavesInChild, targetLane);
    uint mergedCount = numBoxesInTarget + numLeavesInTarget;
    uint remaining = childBoxMask & ~(1u << targetLane);

    uint numMergedNodesToCurLeader = 0; // for debugging
    // Lanegroup broadcasting is safe because all lanes are active
    while (remaining)
    {
        const uint sourceLane = firstbitlow(remaining);
        GPU_ASSERT(targetLane < 8 && sourceLane < 8);

        uint numBoxesInSource  = laneGroup.Broadcast(numBoxesInChild, sourceLane);
        uint numLeavesInSource = laneGroup.Broadcast(numLeavesInChild, sourceLane);
        mergedCount += (numBoxesInSource + numLeavesInSource);

        // Try Merge
        const bool shouldCompleteMerge = ShouldCompleteMerge(laneGroup,
                                                            childNode,
                                                            mergedCount,
                                                            numPrimRefs,
                                                            scratchNodesScratchOffset,
                                                            targetLane,
                                                            sourceLane,
                                                            numLeavesInTarget,
                                                            numLeavesInSource);
        if (shouldCompleteMerge)
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
            // num boxes in child should be 0
            GPU_ASSERT(numBoxesInTarget == 0 && numBoxesInSource == 0);
            // Merge success
            GPU_ASSERT(laneGroup.Ballot(true) == bits(8)); // Ensure all lanes are active and executing the same branch.

            // Update bounding box
            float3 bbox_min = min(laneGroup.Broadcast(childNode.bbox_min, targetLane), laneGroup.Broadcast(childNode.bbox_min, sourceLane));
            float3 bbox_max = max(laneGroup.Broadcast(childNode.bbox_max, targetLane), laneGroup.Broadcast(childNode.bbox_max, sourceLane));

            if (laneGroup.laneIndex == sourceLane)
            {
                [unroll]
                for (uint i = 0; i < numLeavesInSource; ++i)
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

                childNode.packedFlags = bitFieldInsert(childNode.packedFlags, 4, 4, 0);
                childNode.packedFlags = bitFieldInsert(childNode.packedFlags, 8, 1, 0);
                childNode.packedFlags = bitFieldInsert(childNode.packedFlags, 17, 3, numLeavesInTarget);
                isMergedLane = true;
            }
            GroupMemoryBarrier();
            if (laneGroup.laneIndex == targetLane)
            {
                for (uint i = numLeavesInTarget; i < mergedCount; ++i)
                {
                    const uint sharedOffset = i - numLeavesInTarget;
                    if (i < 4)
                    {
                        childNode.children0WideNodeIndexOrLeafScratchIndex[i] = GetSharedChildren(laneGroupIndex, sharedOffset);
                    }
                    else
                    {
                        childNode.children1WideNodeIndexOrLeafScratchIndex[i - 4] = GetSharedChildren(laneGroupIndex, sharedOffset);
                    }
                }

                // bounding box
                childNode.bbox_min = bbox_min;
                childNode.bbox_max = bbox_max;

                // child count
                childNode.packedFlags = bitFieldInsert(childNode.packedFlags, 4, 4, numLeavesInTarget + numLeavesInSource);
                const uint numMergedNodesToTarget = bitFieldExtract(childNode.packedFlags, 17, 3);
                childNode.packedFlags = bitFieldInsert(childNode.packedFlags, 17, 3, numMergedNodesToTarget + 1);
#if SOGANG_EXPERIMENT
                numMergedNodesToCurLeader++;
#endif
            }
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
            WriteScratchWideNodeData(scratchWideNodesScratchOffset, childWideScratchIndex, SCRATCH_WIDE_NODE_FLAGS_OFFSET, childNode.packedFlags);
        }
    }
    return isMergedLane;
}

#endif // _MERGE_SCRATCH_NODES_HLSL