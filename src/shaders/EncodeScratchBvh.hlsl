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
#define USE_LDS_CHILDREN 1
#define NOT_SUPPORTED_IF_ZERO 0
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
// Returns true to enable the legacy leaf compression pass (supports wave64 and larger prim range sizes)
bool EnableLegacyLeafCompressionPass()
{
#if BUILD_PARALLEL
    return EnableLeafCompressionPass();
#else
    return false;
#endif
}

//=====================================================================================================================
// Encodes the sizes of two sets into a switch-case tag for union handling.
// Packs the sizes of two sets into a 6-bit tag: (sizeA << 3) | sizeB.
uint EncodeChildrenSetCounts(const uint setCounts0, const uint setCounts1)
{
    const uint encodedSize = (setCounts0 << 3) | setCounts1;
    return encodedSize;
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
void WriteInstanceNode(
    in AccelStructOffsets offsets,
    in uint               numPrimRefs,
    in ScratchNode        scratchNode,
    in uint               scratchNodeIndex,
    in uint               nodeOffset,
    in uint               parentNodePointer)
{
    const uint instanceIndex = scratchNode.left_or_primIndex_or_instIndex;
    const uint nodePointer = PackNodePointer(NODE_TYPE_USER_NODE_INSTANCE, nodeOffset);
    InstanceDesc instanceDesc = LoadInstanceDesc(instanceIndex, LoadNumPrimAndOffset().primitiveOffset);

    const uint blasRootNodePointer = scratchNode.splitBox_or_nodePointer;
    const uint blasMetadataSize = scratchNode.numPrimitivesAndDoCollapse;
    const uint geometryType = ExtractScratchNodeGeometryType(scratchNode.packedFlags);

    CullIllegalInstances(blasMetadataSize, scratchNode, instanceDesc);

    WriteInstanceNode3_1(instanceDesc,
                         geometryType,
                         instanceIndex,
                         nodePointer,
                         blasRootNodePointer,
                         blasMetadataSize,
                         offsets,
                         parentNodePointer);

    // When rebraiding is disabled the destination index is just the instance index.
    const uint destIndex = (Settings.enableRebraid) ? (scratchNodeIndex - numPrimRefs + 1) : instanceIndex;

    DstBuffer.Store(offsets.primNodePtrs + (destIndex * sizeof(uint)), nodePointer);
}

//=====================================================================================================================
static void WriteLeafNode(
    in uint               scratchNodesScratchOffset,
    in AccelStructOffsets offsets,
    in uint               numPrimRefs,
    in ScratchNode        scratchNode,
    in uint               scratchNodeIdx,
    in uint               primStructIdx,
    in uint               nodeOffset,
    in uint               parentNodePointer)
{
    if (Settings.topLevelBuild)
    {
        Gfx12::WriteInstanceNode(offsets,
                                 numPrimRefs,
                                 scratchNode,
                                 scratchNodeIdx,
                                 nodeOffset,
                                 parentNodePointer);
    }
    else
    {
        bool isTri1Valid = false;
        bool isTri0Opaque = false;
        bool isTri1Opaque = false;
        uint primId0 = 0;
        uint primId1 = 0;
        uint geomId0 = 0;
        uint geomId1 = 0;
        TriangleData tri0 = (TriangleData) 0;
        TriangleData tri1 = (TriangleData) 0;

        const bool isQuadPrim =
            Settings.enableEarlyPairCompression && IsScratchNodeQuadPrimitive(scratchNode);

        if (isQuadPrim)
        {
            isTri1Valid = true;
            isTri0Opaque = IsOpaqueNode(scratchNode.packedFlags);
            isTri1Opaque = isTri0Opaque;
            primId0 = GetScratchNodePrimitiveIndex(scratchNode, 0);
            primId1 = GetScratchNodePrimitiveIndex(scratchNode, 1);
            geomId0 = ExtractScratchNodeGeometryIndex(scratchNode);
            geomId1 = geomId0;
            tri0 = GetScratchNodeQuadVertices(scratchNodesScratchOffset, scratchNodeIdx, 0);
            tri1 = GetScratchNodeQuadVertices(scratchNodesScratchOffset, scratchNodeIdx, 1);
        }
        else if (IsLeafNode(scratchNodeIdx, numPrimRefs) == false)
        {
            uint firstNodeIndex;
            ScratchNode scratchNodeTri0;

            uint secondNodeIndex;
            ScratchNode scratchNodeTri1;

            if (UsePrimIndicesArray())
            {
                firstNodeIndex = GetPrimRefIdx(FetchSortedPrimIndex(ShaderConstants.offsets.primIndicesSorted,
                                                                    scratchNode.sortedPrimIndex),
                                               numPrimRefs);
                scratchNodeTri0 = FetchScratchNode(scratchNodesScratchOffset, firstNodeIndex);

                secondNodeIndex = GetPrimRefIdx(FetchSortedPrimIndex(ShaderConstants.offsets.primIndicesSorted,
                                                                     scratchNode.sortedPrimIndex + 1),
                                                numPrimRefs);
                scratchNodeTri1 = FetchScratchNode(scratchNodesScratchOffset, secondNodeIndex);
            }
            else if (CollapseAnyPairs())
            {
                firstNodeIndex = scratchNode.left_or_primIndex_or_instIndex;
                scratchNodeTri0 = FetchScratchNode(scratchNodesScratchOffset, firstNodeIndex);

                secondNodeIndex = scratchNode.right_or_geometryIndex;
                scratchNodeTri1 = FetchScratchNode(scratchNodesScratchOffset, secondNodeIndex);
            }
            else
            {
                firstNodeIndex = scratchNode.left_or_primIndex_or_instIndex;
                scratchNodeTri0 = FetchScratchNode(scratchNodesScratchOffset, firstNodeIndex);

                secondNodeIndex = scratchNodeTri0.parent;
                scratchNodeTri1 = FetchScratchNode(scratchNodesScratchOffset, secondNodeIndex);
            }

            isTri1Valid = true;
            isTri0Opaque = IsOpaqueNode(scratchNodeTri0.packedFlags);
            isTri1Opaque = IsOpaqueNode(scratchNodeTri1.packedFlags);
            primId0 = scratchNodeTri0.left_or_primIndex_or_instIndex;
            primId1 = scratchNodeTri1.left_or_primIndex_or_instIndex;
            geomId0 = ExtractScratchNodeGeometryIndex(scratchNodeTri0);
            geomId1 = ExtractScratchNodeGeometryIndex(scratchNodeTri1);
            tri0.v0 = scratchNodeTri0.bbox_min_or_v0;
            tri0.v1 = scratchNodeTri0.bbox_max_or_v1;
            tri0.v2 = scratchNodeTri0.sah_or_v2_or_instBasePtr;
            tri1.v0 = scratchNodeTri1.bbox_min_or_v0;
            tri1.v1 = scratchNodeTri1.bbox_max_or_v1;
            tri1.v2 = scratchNodeTri1.sah_or_v2_or_instBasePtr;
        }
        else
        {
            isTri0Opaque = IsOpaqueNode(scratchNode.packedFlags);
            primId0 = scratchNode.left_or_primIndex_or_instIndex;
            geomId0 = ExtractScratchNodeGeometryIndex(scratchNode);
            tri0.v0 = scratchNode.bbox_min_or_v0;
            tri0.v1 = scratchNode.bbox_max_or_v1;
            tri0.v2 = scratchNode.sah_or_v2_or_instBasePtr;
        }

        PrimStruct3_1::WritePairPrimStruct(tri0,
                                           isTri0Opaque,
                                           primId0,
                                           geomId0,
                                           isTri1Valid,
                                           tri1,
                                           isTri1Opaque,
                                           primId1,
                                           geomId1,
                                           nodeOffset);

        DstBuffer.Store(offsets.primNodePtrs + (primStructIdx * sizeof(uint)), nodeOffset);
    }
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
    const bool isLeafNode = IsLeafNode(childScratchNodeIdx, numPrimRefs);

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
static bool TryMergeNodes(
    uint target,
    uint source)
{
    


    return true;
}
#if USE_LDS_CHILDREN
//=====================================================================================================================
static bool MergeBoxNodes(
    LaneGroup                laneGroup,
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
    uint targetLane = firstbitlow(childBoxMask);
    uint numBoxesInTarget  = laneGroup.Broadcast(numBoxesInChild, targetLane);
    uint numLeavesInTarget = laneGroup.Broadcast(numLeavesInChild, targetLane);
    uint mergedCount = numBoxesInTarget + numLeavesInTarget;
    uint remaining = childBoxMask & ~(1u << targetLane);

    // Broadcast is safe beacause all lanes are active
    while (remaining)
    {
        const uint sourceLane = firstbitlow(remaining);
        GPU_ASSERT(targetLane < 8 && sourceLane < 8);

        uint numBoxesInSource  = laneGroup.Broadcast(numBoxesInChild, sourceLane);
        uint numLeavesInSource = laneGroup.Broadcast(numLeavesInChild, sourceLane);
        mergedCount += (numBoxesInSource + numLeavesInSource);
        // Try Merge
        if (mergedCount > 8)
        {
            // Complete current target's merging. re-target to next lane
            targetLane = sourceLane;
            numBoxesInTarget = numBoxesInSource;
            numLeavesInTarget = numLeavesInSource;
            mergedCount = numBoxesInTarget + numLeavesInTarget;
        }
        else
        {
            // Merge success
            // Merge phase 0: Initial Stauts
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
                SetSharedChildren(laneGroup.groupIndex, 0, childNode.children0WideNodeIndexOrLeafScratchIndex.x);
                SetSharedChildren(laneGroup.groupIndex, 1, childNode.children0WideNodeIndexOrLeafScratchIndex.y);
                SetSharedChildren(laneGroup.groupIndex, 2, childNode.children0WideNodeIndexOrLeafScratchIndex.z);
                SetSharedChildren(laneGroup.groupIndex, 3, childNode.children0WideNodeIndexOrLeafScratchIndex.w);
                SetSharedChildren(laneGroup.groupIndex, 4, childNode.children1WideNodeIndexOrLeafScratchIndex.x);
                SetSharedChildren(laneGroup.groupIndex, 5, childNode.children1WideNodeIndexOrLeafScratchIndex.y);
                SetSharedChildren(laneGroup.groupIndex, 6, childNode.children1WideNodeIndexOrLeafScratchIndex.z);
                SetSharedChildren(laneGroup.groupIndex, 7, childNode.children1WideNodeIndexOrLeafScratchIndex.w);

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
                        SetSharedChildren(laneGroup.groupIndex, numSourceChildren + i, childNode.children0WideNodeIndexOrLeafScratchIndex[leafIndex]);
                    }
                    else
                    {
                        SetSharedChildren(laneGroup.groupIndex, numSourceChildren + i, childNode.children1WideNodeIndexOrLeafScratchIndex[leafIndex - 4]);
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
                        childNode.children0WideNodeIndexOrLeafScratchIndex[i] = GetSharedChildren(laneGroup.groupIndex, i - numBoxesInTarget);
                    }
                    else
                    {
                        childNode.children1WideNodeIndexOrLeafScratchIndex[i - 4] = GetSharedChildren(laneGroup.groupIndex, i - numBoxesInTarget);
                    }
                }

                // bounding box
                childNode.bbox_min = bbox_min;
                childNode.bbox_max = bbox_max;

                // child count
                childNode.packedFlags = bitFieldInsert(childNode.packedFlags, 0, 4, numBoxesInTarget + numBoxesInSource);
                childNode.packedFlags = bitFieldInsert(childNode.packedFlags, 4, 4, numLeavesInTarget + numLeavesInSource);
            }
            
            numBoxesInTarget  += numBoxesInSource;
            numLeavesInTarget += numLeavesInSource;
            // Mark source node as a merge candidate. (sourceLane -> 0)
            leaderNodeMask &= ~(1u << sourceLane);

            // Clear SharedChildren
            SetSharedChildren(laneGroup.groupIndex, laneGroup.laneIndex, 0xffffffff);
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
            // Clear Node
            // ScratchWideNode emptyNode;
            // emptyNode.children0WideNodeIndexOrLeafScratchIndex = 0xffffffff.xxxx;
            // emptyNode.children1WideNodeIndexOrLeafScratchIndex = 0xffffffff.xxxx;
            // emptyNode.bbox_min = float3(FLT_MAX, FLT_MAX, FLT_MAX);
            // emptyNode.scratchIndex = INVALID_IDX;
            // emptyNode.bbox_max = float3(-FLT_MAX, -FLT_MAX, -FLT_MAX);
            // emptyNode.packedFlags = 0;
            // WriteScratchWideNode(scratchNodesScratchOffset, childWideScratchIndex, emptyNode);

            // Update Flags - mark as 0 to indicate this is not a leader node.
            // const uint packedFlags = bitFieldInsert(childNode.packedFlags, 8, 1, 0);
            const uint packedFlags = 0;
            WriteScratchWideNodeData(scratchNodesScratchOffset, childWideScratchIndex, SCRATCH_WIDE_NODE_FLAGS_OFFSET, packedFlags);

            // uint4 emptyChildren = 0xffffffff.xxxx;
            // WriteScratchWideNodeData<uint4>(scratchNodesScratchOffset, childWideScratchIndex, SCRATCH_WIDE_NODE_CHILDREN0_OR_LEAF_SCRATCH_INDEX_OFFSET, emptyChildren);
            // WriteScratchWideNodeData<uint4>(scratchNodesScratchOffset, childWideScratchIndex, SCRATCH_WIDE_NODE_CHILDREN1_OR_LEAF_SCRATCH_INDEX_OFFSET, emptyChildren);
        }
    }
    return isMergedLane;
}
#endif
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
        SetSharedChildren(laneGroup.groupIndex, 0, scratchWideNode.children0WideNodeIndexOrLeafScratchIndex.x);
        SetSharedChildren(laneGroup.groupIndex, 1, scratchWideNode.children0WideNodeIndexOrLeafScratchIndex.y);
        SetSharedChildren(laneGroup.groupIndex, 2, scratchWideNode.children0WideNodeIndexOrLeafScratchIndex.z);
        SetSharedChildren(laneGroup.groupIndex, 3, scratchWideNode.children0WideNodeIndexOrLeafScratchIndex.w);

        SetSharedChildren(laneGroup.groupIndex, 4, scratchWideNode.children1WideNodeIndexOrLeafScratchIndex.x);
        SetSharedChildren(laneGroup.groupIndex, 5, scratchWideNode.children1WideNodeIndexOrLeafScratchIndex.y);
        SetSharedChildren(laneGroup.groupIndex, 6, scratchWideNode.children1WideNodeIndexOrLeafScratchIndex.z);
        SetSharedChildren(laneGroup.groupIndex, 7, scratchWideNode.children1WideNodeIndexOrLeafScratchIndex.w);
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
    childWideScratchIndex = GetSharedChildren(laneGroup.groupIndex, laneGroup.laneIndex);
#else
    [unroll]
    for (uint i = 0; i < 8; ++i)
    {
        children8[i] = laneGroup.ReadFirstLane(children8[i]);
    }
    childWideScratchIndex = children8[laneGroup.laneIndex];
#endif

#if MERGE_BOX_NODES_RTIP3_1
    parentWideNodePackedFlags = laneGroup.ReadFirstLane(parentWideNodePackedFlags);
    if (bitFieldExtract(parentWideNodePackedFlags, 8, 1) == 0) { return; } // Early return for merged nodes
#endif

    parentScratchNodeIdx = laneGroup.ReadFirstLane(parentScratchNodeIdx);
    numBoxChildren = laneGroup.ReadFirstLane(numBoxChildren);
    bool isValidChild = (childWideScratchIndex != INVALID_IDX);
    const bool childIsBox = (laneGroup.laneIndex < numBoxChildren) && (childWideScratchIndex != INVALID_IDX);
    const bool childIsLeaf = (laneGroup.laneIndex >= numBoxChildren) && (childWideScratchIndex != INVALID_IDX);
    numLeafChildren = laneGroup.BallotCount(childIsLeaf);

    uint boxOrLeafChildIndex = childIsBox ? laneGroup.laneIndex : laneGroup.laneIndex - numBoxChildren;

    const uint numOrigianlBoxChildren = numBoxChildren;
#if MERGE_BOX_NODES_RTIP3_1
    bool isMerged = MergeBoxNodes(laneGroup, childWideScratchIndex, scratchWideNodesScratchOffset, childIsBox);
    const bool isLeaderBoxChild = childIsBox && !isMerged;
    const bool isMergedBoxChild = childIsBox && isMerged;

    const uint leaderBoxMask = laneGroup.Ballot(isLeaderBoxChild);
    const uint mergedBoxMask = laneGroup.Ballot(isMergedBoxChild);

    const uint numLeaderBoxChildren = countbits(leaderBoxMask);
    const uint numMergedBoxChildren = countbits(mergedBoxMask);

    uint boxChildCompactedIndexInParent = INVALID_IDX;
    if (isLeaderBoxChild)
    {
        boxChildCompactedIndexInParent = laneGroup.ExclusivePrefixSumBool(true);
    }

    // Write leader box mask to parent node
    if (laneGroup.IsFirstLane())
    {
        // ScratchGlobal.InterlockedAdd(ShaderConstants.offsets.scratchWideNodeCounter, numMergedBoxChildren);

        parentWideNodePackedFlags = bitFieldInsert(parentWideNodePackedFlags, 9, 8, leaderBoxMask & bits(8));
        WriteScratchWideNodeData(scratchWideNodesScratchOffset, parentWideScratchNodeIndex, SCRATCH_WIDE_NODE_FLAGS_OFFSET, parentWideNodePackedFlags);
    }

    // numBoxChildren = numLeaderBoxChildren;

#endif // MERGE_BOX_NODES_RTIP3_1

    if (Settings.topLevelBuild == 0)
    {
        const uint numInlinePrimStructs = 0;
        if (laneGroup.IsFirstLane())
        {
            // This code assumes STACK_PTRS_SRC_PTR_OFFSET and STACK_PTRS_DST_PTR_OFFSET are in consecutive
            // DWORDs.
            const uint stackPtrOffset = ShaderConstants.offsets.qbvhGlobalStackPtrs;
            // ScratchGlobal.InterlockedAdd(stackPtrOffset + STACK_PTRS_DST_PTR_OFFSET, numOrigianlBoxChildren + numInlinePrimStructs);
            
            ScratchGlobal.InterlockedAdd(stackPtrOffset + STACK_PTRS_DST_PTR_OFFSET, numLeaderBoxChildren + numInlinePrimStructs, dstStackIdx);
        }
    }

    if (laneGroup.IsFirstLane())
    {
#if MERGE_BOX_NODES_RTIP3_1
        baseDstBoxIdx = dstStackIdx;
#else
        baseDstBoxIdx = childWideScratchIndex;
        dstStackIdx   = childWideScratchIndex;
#endif
        baseBoxNodeOffset = offsets.internalNodes + baseDstBoxIdx * QBVH8::NodeSizeInBytes;
    }
    dstStackIdx       = laneGroup.ReadFirstLane(dstStackIdx);
    baseDstBoxIdx     = laneGroup.ReadFirstLane(baseDstBoxIdx);
    baseBoxNodeOffset = laneGroup.ReadFirstLane(baseBoxNodeOffset);

    if (isValidChild)
    {
        if (isLeaderBoxChild)
        {
            GPU_ASSERT(childWideScratchIndex != INVALID_IDX);
            uint childStackIdx = dstStackIdx + boxChildCompactedIndexInParent;
            // DstIndex and LocalIndex
            uint packedDstNodeIdx = PackStackDstNodeIdx(baseDstBoxIdx + boxChildCompactedIndexInParent, boxChildCompactedIndexInParent);

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
        else if (Settings.topLevelBuild == 0)
        {
            QBVH8::WriteLeafNodeBaseOffset(currNodeOffset, INVALID_NODE);
        }

        QBVH8::WriteOrigin(currNodeOffset, parentBbox.min);

        QBVH8::WritePackedExpChildIdxAndCount(currNodeOffset, exponents, indexInParent, validChildCount);

        // Store the source box bitfield in the upper bits of the OBB DWORD (unused by HW). This is used to construct
        // four filter boxes for instances.
        uint packedFlags = FetchScratchWideNodeData<uint>(scratchWideNodesScratchOffset, parentWideScratchNodeIndex, SCRATCH_WIDE_NODE_FLAGS_OFFSET);
#if MERGE_BOX_NODES_RTIP3_1
        const uint childrenLeaderMask = bitFieldExtract(packedFlags, 9, 8);
        uint leaderMaskAndObbMatrixIndex = INVALID_OBB;
        leaderMaskAndObbMatrixIndex = bitFieldInsert(leaderMaskAndObbMatrixIndex, 7, 8, childrenLeaderMask);
        QBVH8::WriteObbMatrixIndex(currNodeOffset, leaderMaskAndObbMatrixIndex);
#else
        QBVH8::WriteObbMatrixIndex(currNodeOffset, PackObbMatrixIndexBits(INVALID_OBB, packedFlags));
#endif

        if ((Settings.topLevelBuild == false) && (EnableLeafCompressionPass() == false))
        {
            basePrimStructIdx = IncrementAccelStructHeaderField(ACCEL_STRUCT_HEADER_NUM_LEAF_NODES_OFFSET, numLeafChildren);
        }
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

    // if (childIsBox) GPU_ASSERT(!IsLeafNode(childScratchNodeIndex, numPrimRefs)); // all pass
    if (isValidChild)
    {
        // TLAS builds initialize these fields immediately. They should be left 0 for BLAS builds if we are compressing
        // leaf nodes. If we are not compressing, a single triangle primitive structure is produced immediately.
        // Either way the triangle node type field is 0.
        const uint nodeType        = childIsLeaf ? (Settings.topLevelBuild ?
                                                    NODE_TYPE_USER_NODE_INSTANCE : NODE_TYPE_TRIANGLE_0) :
                                                    NODE_TYPE_BOX_QUANTIZED_BVH8;
        const uint primRangeLength = childIsLeaf ? (EnableLeafCompressionPass() ? 0 : 1) :
                                                   (isLeaderBoxChild ? 1 : 0);
        const uint baseNodeOffset  = childIsLeaf ? baseLeafNodeOffset : baseBoxNodeOffset;
        const uint offset          = childIsLeaf ? boxOrLeafChildIndex + numBoxChildren : boxOrLeafChildIndex;
        const uint childNodeOffset = baseNodeOffset + 
                (childIsLeaf ? boxOrLeafChildIndex : boxChildCompactedIndexInParent) * QBVH8::NodeSizeInBytes;

        BoundingBox childBbox;
        childScratchNode = FetchScratchNode(scratchNodesScratchOffset, childScratchNodeIndex);
#if MERGE_BOX_NODES_RTIP3_1
        // Child bounding boxes are updated after merging, so they must be fetched from the scratch wide node rather than the scratch node.
#endif
        childBbox = GetScratchNodeBoundingBoxTS(scratchNodesScratchOffset, childIsLeaf, childScratchNode);
        // uint childPackedFlags = FetchScratchNodeData<uint>(scratchNodesScratchOffset, childScratchNodeIndex, SCRATCH_NODE_FLAGS_OFFSET);
        const uint3 childInfo = ComputePackedChildInfo(childBbox,
                                                       childScratchNode.packedFlags,
                                                       childScratchNodeIndex,
                                                       nodeType,
                                                       primRangeLength,
                                                       rcpExponents,
                                                       parentBbox.min,
                                                       numPrimRefs);
        QBVH8::WritePackedChildInfo(currNodeOffset, offset, childInfo);

        if (isLeaderBoxChild)
        {
            QBVH8::WriteParentPointer(childNodeOffset, currNodePtr);
        }
        else if (childIsLeaf)
        {
            // Process and compress leaf children
            if (EnableLeafCompressionPass() == false)
            {
                // childScratchNode = FetchScratchNode(scratchNodesScratchOffset, childScratchNodeIndex);
                WriteLeafNode(scratchNodesScratchOffset,
                              offsets,
                              numPrimRefs,
                              childScratchNode,
                              childScratchNodeIndex,
                              basePrimStructIdx + boxOrLeafChildIndex,
                              childNodeOffset,
                              currNodePtr);
            }
        }
    }
    else
    {
        QBVH8::WriteInvalidChildInfo(currNodeOffset, laneGroup.laneIndex);
    }
    // TODO : OBB preparation

    uint localPrimCount = 0;
    if (childScratchNodeIndex != INVALID_IDX)
    {
        if (childIsLeaf)
        {
            localPrimCount = FetchScratchNodeNumPrimitives(childScratchNode, IsLeafNode(childScratchNodeIndex, numPrimRefs));
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
    uint numScratchWideNodes
    )
{
    const AccelStructOffsets offsets = ShaderConstants.header.offsets;

    const uint rootNodeIndex = GetBvh2RootNodeIndex();
    const uint scratchNodesScratchOffset     = CalculateBvhNodesOffset(ShaderConstants, numPrimRefs);
    const uint scratchWideNodesScratchOffset = ShaderConstants.offsets.bvhWideNodeData;

    const bool isSinglePrimBvh = (numPrimRefs == 1);

    const ScratchNode rootScratchNode = FetchScratchNode(scratchNodesScratchOffset, rootNodeIndex);
    const uint numActivePrims =
        Settings.topLevelBuild ? numPrimRefs : FetchScratchNodeNumPrimitives(rootScratchNode, isSinglePrimBvh);

    const uint maxNumInternalNodes = GetNumInternalNodeCount(numActivePrims);

    if (globalId == 0)
    {
        const BoundingBox bbox =
            GetScratchNodeBoundingBoxTS(scratchNodesScratchOffset, isSinglePrimBvh, rootScratchNode);

        WriteAccelStructHeaderRootBoundingBox(bbox);

        const uint3 exponents = ComputeCommonExponent(bbox.min, bbox.max, 12);

        // Pre-compute exponent reciprocal
        const float3 rcpExponents = ComputeFastExpReciprocal(exponents, 12);

        if (Settings.topLevelBuild == false)
        {
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

            if (EnableLegacyLeafCompressionPass())
            {
                // Load acceleration structure header
                AccelStructHeader header = DstBuffer.Load<AccelStructHeader>(0);

                header.info2 =
                    bitFieldInsert(header.info2, ACCEL_STRUCT_HEADER_INFO_2_LEGACY_LEAF_COMPRESSION_FLAGS_SHIFT, 1, 1);
                DstBuffer.Store(ACCEL_STRUCT_HEADER_INFO_2_OFFSET, header.info2);
            }

            DstBuffer.Store(ACCEL_STRUCT_HEADER_PACKED_FLAGS_OFFSET, rootScratchNode.packedFlags);
        }

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
            const uint bvhWideNodeSrcIdx = stackEntry.x; // parentWideScratchNodeIndex
            const uint bvhNodeDstIdx = GetStackDstIdx(stackEntry.y);
            const uint indexInParent = GetStackDstIdxInParent(stackEntry.y);
            // if (laneGroup.IsFirstLane()) GPU_ASSERT(globalStackIndex == bvhNodeDstIdx); // passed
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
#if GPURT_BUILD_RTIP3_1

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
#if NOT_SUPPORTED_IF_ZERO
        Gfx12::InitObbRefitStackPtrs();
#endif
    }
    END_TASK(1);
    BEGIN_TASK(RoundUpQuotient(numScratchWideNodes, BUILD_THREADGROUP_SIZE));
    ClearStackPtrs(globalId, numScratchWideNodes, ShaderRootConstants.NumThreads());
    END_TASK(RoundUpQuotient(numScratchWideNodes, BUILD_THREADGROUP_SIZE));

    const uint numThreads = numScratchWideNodes * 8;
    BEGIN_TASK(RoundUpQuotient(numThreads, BUILD_THREADGROUP_SIZE));
    Gfx12::EncodeScratchBvhImpl(globalId, localId, numActivePrims, numScratchWideNodes);
    END_TASK(RoundUpQuotient(numThreads, BUILD_THREADGROUP_SIZE));

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
    }

    END_TASK_NO_WAIT(1);

#endif
}
#endif

#endif
