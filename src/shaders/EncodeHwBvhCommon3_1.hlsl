#ifndef _ENCODE_HW_BVH_COMMON_3_1_HLSL
#define _ENCODE_HW_BVH_COMMON_3_1_HLSL

#include "rtip3_1.hlsli"
#include "EncodeHwBvhCommon.hlsl"
#include "QBVH8Common.hlsl"
#include "../shadersClean/common/LaneGroup.hlsli"
#include "PrimitiveStructureEncoder3_1.hlsl"
#include "OrientedBoundingBoxes.hlsl"

namespace Gfx12
{

//======================================================================================================================
void InitObbRefitStackPtrs()
{
    if (IsObbEnabled())
    {
        ObbRefitStackPtrs obbRefitStackPtrs = (ObbRefitStackPtrs)0;
        obbRefitStackPtrs.groupCountY = 1;
        obbRefitStackPtrs.groupCountZ = 1;

        ScratchGlobal.Store<ObbRefitStackPtrs>(ShaderConstants.offsets.obbRefitStackPtrs, obbRefitStackPtrs);
    }
}

//=====================================================================================================================
static uint GetNodeArrayBaseInLds(
    in uint localId, in uint maxNumChildren)
{
    return (localId * maxNumChildren);
}

//=====================================================================================================================
// Insert candidaate child in node array
static void InsertChildInNodeArray(
    in uint           baseLdsOffset,
    in uint           baseScratchNodesOffset,
    in uint           numPrimRefs,
    in uint           childScratchNodeIdx,
    inout_param(uint) nextLeafIdx,
    inout_param(uint) nextBoxIdx)
{
    uint childSlotIdx = 0;

    if (IsLeafOrIsCollapsed(childScratchNodeIdx, baseScratchNodesOffset, numPrimRefs))
    {
        childSlotIdx = --nextLeafIdx;
    }
    else
    {
        childSlotIdx = nextBoxIdx++;
    }

    SharedMem[baseLdsOffset + childSlotIdx] = childScratchNodeIdx;
}

//=====================================================================================================================
// Build child node array from BVH2 treelet root by using surface area heuristics
static void BuildChildNodeArray(
    in    uint                    localId,
    in    uint                    baseScratchNodesOffset,
    in    uint                    numPrimRefs,
    in    uint                    subtreeRootScratchNodeIdx,
    in    uint                    maxNumChildren,
    out_param(uint)               numBoxChildren,
    out_param(uint)               numLeafChildren)
{
    const uint baseLdsOffset  = GetNodeArrayBaseInLds(localId, maxNumChildren);

    const ScratchNode subtreeRootScratchNode = FetchScratchNode(baseScratchNodesOffset, subtreeRootScratchNodeIdx);

    uint nextBoxIdx = 0;
    uint nextLeafIdx = maxNumChildren;

    if (IsLeafOrIsCollapsed(subtreeRootScratchNodeIdx, baseScratchNodesOffset, numPrimRefs))
    {
        InsertChildInNodeArray(baseLdsOffset,
                               baseScratchNodesOffset,
                               numPrimRefs,
                               subtreeRootScratchNodeIdx,
                               nextLeafIdx,
                               nextBoxIdx);
    }
    else
    {
        // Insert left child into node array
        InsertChildInNodeArray(baseLdsOffset,
                               baseScratchNodesOffset,
                               numPrimRefs,
                               subtreeRootScratchNode.left_or_primIndex_or_instIndex,
                               nextLeafIdx,
                               nextBoxIdx);

        // Insert right child into node array
        InsertChildInNodeArray(baseLdsOffset,
                               baseScratchNodesOffset,
                               numPrimRefs,
                               subtreeRootScratchNode.right_or_geometryIndex,
                               nextLeafIdx,
                               nextBoxIdx);
    }

    // The following loop places box nodes at the front of the node array while all leaf children are placed
    // starting from the back of the node array with empty nodes in the middle. The two arrays are tracked
    // via two pointers, nextBoxIdx and nextLeafIdx
    //
    // [Box, Box, ..................., Leaf, Leaf]
    //           ^                   ^
    //       nextBoxIdx         nextLeafIdx
    //
    uint validChildCount = nextBoxIdx + (maxNumChildren - nextLeafIdx);

    // Cached candidate node data (left and right child indices)
    uint2 cachedCandidateData = uint2(0, 0);

    while (validChildCount < maxNumChildren)
    {
        float surfaceAreaMax = 0.0;
        uint candidateSlotIdx = INVALID_IDX;

        // Pick the largest surface area node from current node array of internal nodes.
        for (uint j = 0; j < nextBoxIdx; j++)
        {
            const uint candidateNodeIdx = SharedMem[baseLdsOffset + j];

            const ScratchNode candidateNode = FetchScratchNode(baseScratchNodesOffset, candidateNodeIdx);

            const float surfaceArea = candidateNode.sah_or_v2_or_instBasePtr.y;

            // Pick the node with larger surface area. If the nodes have identical surface area, pick the
            // last node for opening.
            if (surfaceArea >= surfaceAreaMax)
            {
                surfaceAreaMax = surfaceArea;
                candidateSlotIdx = j;

                cachedCandidateData.x = candidateNode.left_or_primIndex_or_instIndex;
                cachedCandidateData.y = candidateNode.right_or_geometryIndex;
            }
        }

        // If there are no valid nodes to open, exit loop
        if (candidateSlotIdx == INVALID_IDX)
        {
            break;
        }

        // Swap in the last box node in candidate slot and free last slot for opening. Below, C represents
        // candidate box node with the largest surface area.
        //
        // [B, C, B..................., L, L]
        //         ^                   ^
        //      nextBoxIdx         nextLeafIdx
        //
        // Last box node in node array gets swapped with candidate node and the box node pointer moves back
        // to allow insertion at the end of the list
        //
        // [B, B, C..................., L, L]
        //      ^                      ^
        //   nextBoxIdx            nextLeafIdx
        //
        nextBoxIdx--;
        SharedMem[baseLdsOffset + candidateSlotIdx] = SharedMem[baseLdsOffset + nextBoxIdx];

        InsertChildInNodeArray(
            baseLdsOffset, baseScratchNodesOffset, numPrimRefs,
            cachedCandidateData.x, nextLeafIdx, nextBoxIdx);

        InsertChildInNodeArray(
            baseLdsOffset, baseScratchNodesOffset, numPrimRefs,
            cachedCandidateData.y, nextLeafIdx, nextBoxIdx);

        // Update valid child count
        validChildCount = nextBoxIdx + (maxNumChildren - nextLeafIdx);
    }

    // Assign box and leaf node count in node array to output variables
    numBoxChildren  = nextBoxIdx;
    numLeafChildren = maxNumChildren - nextLeafIdx;

    // Shift leaf nodes left to cover up empty spaces if any in the child node array
    if (nextBoxIdx != nextLeafIdx)
    {
        for (uint i = 0; i < numLeafChildren; ++i)
        {
            SharedMem[baseLdsOffset + nextBoxIdx + i] = SharedMem[baseLdsOffset + nextLeafIdx + i];
        }
    }
}

//=====================================================================================================================
// Write intersectable instance node as a filter node with 4 distinct child bounds sharing the same root node.
// This function prebuilds the filter node and stores it in the BLAS metadata. It is copied directly to the TLAS when
// an instance is not rebraided.
static void WriteBlasInstanceFilterNode(
    in uint   scratchNodesScratchOffset,
    in uint   numPrimRefs,
    in uint   rootNodeIndex,
    in float3 origin,
    in uint3  exponents,
    in float3 rcpExponents)
{
    // For single primitive case, skip building node array and just push the lone leaf node to
    // the child node array
    uint numBoxChildren  = 0;
    uint numLeafChildren = 0;

    // For filter nodes, we just build 4 bounding boxes from the root node
    const uint baseLdsOffset = GetNodeArrayBaseInLds(0, 4);
    BuildChildNodeArray(0,
                        scratchNodesScratchOffset,
                        numPrimRefs,
                        rootNodeIndex,
                        4,
                        numBoxChildren,
                        numLeafChildren);

    // The root of the BVH2 treelet contains the combined bounds of the child nodes in the node array.
    // Compute the common exponent from the root node bounds
    const uint validChildCount = numBoxChildren + numLeafChildren;

    // Origin
    const uint baseOffset = ACCEL_STRUCT_METADATA_INSTANCE_NODE_OFFSET;
    DstMetadata.Store3(baseOffset, asuint(origin));

    // Packed exponents, valid child count and child index in parent node
    const uint packedExpChildIdxAndCount =
        QuantizedBVH8BoxNode::PackExpChildIdxAndCount(exponents, 0, 0, 4);

    DstMetadata.Store(baseOffset + QUANTIZED_BVH4_NODE_OFFSET_EXP_CHILD_IDX_AND_VALID_COUNT,
                      packedExpChildIdxAndCount);

    for (uint i = 0; i < validChildCount; ++i)
    {
        const uint childScratchNodeIdx = SharedMem[baseLdsOffset + i];

        const ScratchNode childScratchNode =
            FetchScratchNode(scratchNodesScratchOffset, childScratchNodeIdx);

        const bool isLeafNode = IsLeafNode(childScratchNodeIdx, numPrimRefs);

        const BoundingBox childBounds =
            GetScratchNodeBoundingBoxTS(scratchNodesScratchOffset, isLeafNode, childScratchNode);

        const UintBoundingBox quantBounds = ComputeQuantizedBounds(childBounds, origin, rcpExponents, 12);

        const uint3 childInfo = GetInstanceChildInfo(i, CreateRootNodePointer3_1(), quantBounds.min, quantBounds.max);

        DstMetadata.Store3(baseOffset + GetBvh4ChildInfoOffset(i), childInfo);
    }

    // Encode remaining child slots as invalid
    for (uint i = validChildCount; i < 4; ++i)
    {
        const uint3 childInfo = GetInstanceChildInfo(i, CreateRootNodePointer3_1(), 0xFFFFFFFF.xxx, 0.xxx);
        DstMetadata.Store3(baseOffset + GetBvh4ChildInfoOffset(i), childInfo);
    }
}

//=====================================================================================================================
// Write the child scratch indices for processing in the primitive compression pass
static void WritePrimCompBatches3_1(
    LaneGroup   laneGroup,
    uint        rootNodeIndex,
    uint        scratchNodesScratchOffset,
    uint        parentScratchNodeIndex,
    uint        currNodeAddr,
    uint        numBoxChildren,
    uint        numLeafChildren,
    uint        numChildPrims,
    uint        numPrimRefs,
    uint        nodeIndex,
    uint        childIdx,
    bool        isLeaf)
{
    uint offset = CalcScratchNodeOffset(scratchNodesScratchOffset, parentScratchNodeIndex);

    if (laneGroup.IsFirstLane())
    {
        // numPrimRefs represents the number of active triangles in the AS and not the number of
        // primitive (leaf) references in the BVH2. In case of a primitive range that spans all triangles
        // in the AS, numPrimRefs is > 1. The code here assumes that in that scenario, a true BVH2 with N
        // leaf references still exists. The assert below when triggered indicates that this assumption has changed.
        if (numPrimRefs == 1)
        {
           GPU_ASSERT(numChildPrims == 1);
           GPU_ASSERT(rootNodeIndex == nodeIndex);
        }

        // For single primitive AS there is no parent scratch node to use, hence we always queue the root scratch node
        // itself to the compression stack and handle it in the compression pass
        if (numPrimRefs == 1)
        {
            // Add single triangles at the end of the buffer
            ScratchGlobal.Store(ShaderConstants.offsets.qbvhGlobalStackPtrs + STACK_PTRS_PRIM_COMP_SINGLE_COUNT, 1);
            const uint primCompBatchOffset = ShaderConstants.offsets.primCompNodeIndicesEnd - sizeof(uint);
            ScratchGlobal.Store(primCompBatchOffset, rootNodeIndex);
        }
        else
        {
            // Pack numBoxChildren and numLeafChildren bits in the 128-byte aligned currNodeAddr
            // numBoxChildren    :  3 // Maximum value is 7 since we only queue internal nodes with at least one leaf node
            // numLeafChildren   :  4 // Maximum valid is 8 as an BVH8 internal node can have maximum of 8 leaf children
            // currentNodeOffset : 25 // 128-byte aligned node offset. Lower 7 bits are guaranteed to be 0
            //
            const uint packedParentInfo = PackCompBatchParentInfo(currNodeAddr, numBoxChildren, numLeafChildren);

            // Store packedParentInfo followed by leaf node indices in parent scratch node
            ScratchGlobal.Store(offset, packedParentInfo);

            const uint stackPtrOffset = numChildPrims > 1 ? STACK_PTRS_PRIM_COMP_BATCH_COUNT : STACK_PTRS_PRIM_COMP_SINGLE_COUNT;
            uint stackIndex;
            ScratchGlobal.InterlockedAdd(ShaderConstants.offsets.qbvhGlobalStackPtrs + stackPtrOffset, 1, stackIndex);

            const uint primCompBatchOffset = (numChildPrims > 1) ?
                      ShaderConstants.offsets.primCompNodeIndices + (stackIndex * sizeof(uint)) :
                      ShaderConstants.offsets.primCompNodeIndicesEnd - ((stackIndex + 1) * sizeof(uint));

            ScratchGlobal.Store(primCompBatchOffset, parentScratchNodeIndex);
        }
    }

    if ((numPrimRefs != 1) && isLeaf)
    {
        offset += sizeof(uint) * (childIdx + 1);
        ScratchGlobal.Store(offset, nodeIndex);
    }
}

}

#endif // _ENCODE_HW_BVH_COMMON_3_1_HLSL