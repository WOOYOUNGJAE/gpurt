#include "../shadersClean/common/ShaderDefs.hlsli"

#define GC_DSTBUFFER
#define GC_DSTMETADATA
#define GC_SCRATCHBUFFER
#include "../shadersClean/build/BuildRootSignature.hlsli"
#include "../shadersClean/build/BuildCommonScratch.hlsli"

#include "rtip3_1.hlsli"
#include "EncodeHwBvhCommon.hlsl"
#include "QBVH8Common.hlsl"
#include "../shadersClean/common/LaneGroup.hlsli"
// #include "PrimitiveStructureEncoder3_1.hlsl"
#include "OrientedBoundingBoxes.hlsl"

#define TLAS_BUILD_SUPPORT 0

//=====================================================================================================================
// Returns true to enable a separate leaf compression pass over all children of one internal node.
bool EnableLeafCompressionPass()
{
    return (IsTrianglePrimitiveBuild() || IsCompressedTrianglePrimitiveBuild()) &&
           ((Settings.primCompressionFlags & PrimCompFlags::MultiPrim) ||
            (Settings.maxPrimRangeSize > 2));
}

//=====================================================================================================================
// Create a Primitive Structure containing a single triangle pair
// NOTE: This function is used by the Trivial Builder, so it cannot use scratch memory or LDS.
static void WritePairPrimStruct(
    TriangleData tri0,
    bool         tri0Opaque,
    uint         tri0PrimitiveIndex,
    uint         tri0GeometryIndex,
    bool         isTri1Valid,
    TriangleData tri1,
    bool         tri1Opaque,
    uint         tri1PrimitiveIndex,
    uint         tri1GeometryIndex,
    uint         nodeOffset)
{
    uint d[PRIMITIVE_STRUCT_SIZE_IN_DW];

    for (uint i = 0; i < PRIMITIVE_STRUCT_SIZE_IN_DW; ++i)
    {
        d[i] = 0;
    }

    const uint indexSectionMidpoint = ComputeIndexSectionMidpoint(1, 31, 31);

    if (Settings.geometryType == GEOMETRY_TYPE_AABBS)
    {
        // HW would detect "malformed_vtx" based on index and payloadlength
        // Since procedural node index are 0xF
        // here we manually pack payloadLength to be 1 (payloadLengthMinusOne = 0)
        // in order to prevent HW decode proceduralNodes as "malformed_vtx"
        //
        // i.e., procedural node needs to be packed as:
        // payloadXLengthMinusOne = 0;      // decode as 1
        // payloadYLengthMinusOne = 0;      // decode as 1
        // payloadZLengthMinusOne = 0;      // decode as 1
        // trailingZeroLength     = 0;

        d[0] = PackMetadataHeaderBitsLo(0, 0, 0, 0, 15, 15, 0, false);
        d[1] = PackMetadataHeaderBitsHi(31, 31, indexSectionMidpoint);

        // tri0 v0 is encoded as float3(0, 0, 0) to report invalid triangle vertices as origin.

        // AABB min/max are written to unused section of the primitive packet.
        d[5]  = asuint(tri0.v0.x);
        d[6]  = asuint(tri0.v0.y);
        d[7]  = asuint(tri0.v0.z);
        d[8]  = asuint(tri0.v1.x);
        d[9]  = asuint(tri0.v1.y);
        d[10] = asuint(tri0.v1.z);

        // Geometry IDs
        d[28] = bitFieldInsert(d[28], 7, 25, tri0GeometryIndex);
        d[29] = bitFieldInsert(0,     0,  5, tri0GeometryIndex >> 25);

        // Index section midpoint

        // Primitive IDs
        d[29] = bitFieldInsert(d[29], 5, 27, tri0PrimitiveIndex);
        d[30] = bitFieldInsert(d[30], 0,  4, tri0PrimitiveIndex >> 27);

        // Triangle descriptor
        uint triDesc = 1 << TRI_DESC_PRIM_RANGE_STOP_BIT_SHIFT;
        // Mark this node as procedural by setting triangle 0 indices to 0xff, 0xff, x
        PackedTriDescSetTriangle(0, 0xff, 0xff, 0xff, (uint) tri0Opaque, triDesc);
        // Encode triangle 1 as degenerate triangle at vertex0.
        PackedTriDescSetTriangle(1, 0, 0, 0, 0, triDesc);

        d[31] = bitFieldInsert(d[31], 3, 29, triDesc);
    }
    else
    {
        // Store full vertex with no compression
        //
        // Each vertex is stored as 3 DW (32bit) without prefix
        //
        // Header ----------- 52 bits
        // Vertex Data ------ 576 bits (96 * 3 * 2)
        // ----- Unused ----- 245 bits
        // geometryId1Payload 30 bits
        // geometryIdAnchor-- 30 bits
        //------------------- indexSectionMidpoint
        // primIdAnchor ----- 31 bits
        // primId1Payload---- 31 bits
        // triDesc----------- 29 bits
        //------------------- 1024 bits
        d[0] = PackMetadataHeaderBitsLo(31, 31, 31, 0, 15, 15, 0, false);

        d[1] = PackMetadataHeaderBitsHi(31, 31, indexSectionMidpoint);

        uint triDesc = 1 << TRI_DESC_PRIM_RANGE_STOP_BIT_SHIFT;

        // tri0 v0
        d[1] = bitFieldInsert(d[1], 20, 12, asuint(tri0.v0.x));
        d[2] = bitFieldInsert(0,     0, 20, asuint(tri0.v0.x) >> 12);
        d[2] = bitFieldInsert(d[2], 20, 12, asuint(tri0.v0.y));
        d[3] = bitFieldInsert(0,     0, 20, asuint(tri0.v0.y) >> 12);
        d[3] = bitFieldInsert(d[3], 20, 12, asuint(tri0.v0.z));
        d[4] = bitFieldInsert(0,     0, 20, asuint(tri0.v0.z) >> 12);
        // tri0 v1
        d[4] = bitFieldInsert(d[4], 20, 12, asuint(tri0.v1.x));
        d[5] = bitFieldInsert(0,     0, 20, asuint(tri0.v1.x) >> 12);
        d[5] = bitFieldInsert(d[5], 20, 12, asuint(tri0.v1.y));
        d[6] = bitFieldInsert(0,     0, 20, asuint(tri0.v1.y) >> 12);
        d[6] = bitFieldInsert(d[6], 20, 12, asuint(tri0.v1.z));
        d[7] = bitFieldInsert(0,     0, 20, asuint(tri0.v1.z) >> 12);

        // tri0 v2
        d[7]  = bitFieldInsert(d[7], 20, 12, asuint(tri0.v2.x));
        d[8]  = bitFieldInsert(0,     0, 20, asuint(tri0.v2.x) >> 12);
        d[8]  = bitFieldInsert(d[8], 20, 12, asuint(tri0.v2.y));
        d[9]  = bitFieldInsert(0,     0, 20, asuint(tri0.v2.y) >> 12);
        d[9]  = bitFieldInsert(d[9], 20, 12, asuint(tri0.v2.z));
        d[10] = bitFieldInsert(0,     0, 20, asuint(tri0.v2.z) >> 12);

        PackedTriDescSetTriangle(0, 0, 1, 2, (uint) tri0Opaque, triDesc);

        if (isTri1Valid)
        {
            // tri1 v0
            d[10] = bitFieldInsert(d[10], 20, 12, asuint(tri1.v0.x));
            d[11] = bitFieldInsert(0,      0, 20, asuint(tri1.v0.x) >> 12);
            d[11] = bitFieldInsert(d[11], 20, 12, asuint(tri1.v0.y));
            d[12] = bitFieldInsert(0,      0, 20, asuint(tri1.v0.y) >> 12);
            d[12] = bitFieldInsert(d[12], 20, 12, asuint(tri1.v0.z));
            d[13] = bitFieldInsert(0,      0, 20, asuint(tri1.v0.z) >> 12);
            // tri1 v1
            d[13] = bitFieldInsert(d[13], 20, 12, asuint(tri1.v1.x));
            d[14] = bitFieldInsert(0,      0, 20, asuint(tri1.v1.x) >> 12);
            d[14] = bitFieldInsert(d[14], 20, 12, asuint(tri1.v1.y));
            d[15] = bitFieldInsert(0,      0, 20, asuint(tri1.v1.y) >> 12);
            d[15] = bitFieldInsert(d[15], 20, 12, asuint(tri1.v1.z));
            d[16] = bitFieldInsert(0,      0, 20, asuint(tri1.v1.z) >> 12);
            // tri1 v2
            d[16] = bitFieldInsert(d[16], 20, 12, asuint(tri1.v2.x));
            d[17] = bitFieldInsert(0,      0, 20, asuint(tri1.v2.x) >> 12);
            d[17] = bitFieldInsert(d[17], 20, 12, asuint(tri1.v2.y));
            d[18] = bitFieldInsert(0,      0, 20, asuint(tri1.v2.y) >> 12);
            d[18] = bitFieldInsert(d[18], 20, 12, asuint(tri1.v2.z));
            d[19] = bitFieldInsert(0,      0, 20, asuint(tri1.v2.z) >> 12);

            PackedTriDescSetTriangle(1, 3, 4, 5, (uint) tri1Opaque, triDesc);

            // Geometry IDs
            d[27] = bitFieldInsert(0, 9, 23, tri1GeometryIndex);
            d[28] = bitFieldInsert(0, 0,  7, tri1GeometryIndex >> 23);

            // Primitive IDs
            d[30] = bitFieldInsert(0, 4, 28, tri1PrimitiveIndex);
            d[31] = bitFieldInsert(0, 0,  3, tri1PrimitiveIndex >> 28);
        }
        else
        {
            // Set tri1 to invalid
            PackedTriDescSetInvalidTriangle(1, triDesc);
        }

        // Geometry IDs
        d[28] = bitFieldInsert(d[28], 7, 25, tri0GeometryIndex);
        d[29] = bitFieldInsert(0,     0,  5, tri0GeometryIndex >> 25);

        // Index section midpoint

        // Primitive IDs
        d[29] = bitFieldInsert(d[29], 5, 27, tri0PrimitiveIndex);
        d[30] = bitFieldInsert(d[30], 0,  4, tri0PrimitiveIndex >> 27);

        // Triangle descriptor
        d[31] = bitFieldInsert(d[31], 3, 29, triDesc);
    }

    [unroll]
    for (uint i = 0; i < PRIMITIVE_STRUCT_SIZE_IN_DW; i += 4)
    {
        DstBuffer.Store4(nodeOffset + (i*4), uint4(d[i], d[i+1], d[i+2], d[i+3]));
    }
}


//=====================================================================================================================
// Main Function : WriteFusedCollapsedWideBvh
//=====================================================================================================================
[RootSignature(RootSig)]
[numthreads(BUILD_THREADGROUP_SIZE, 1, 1)]
void WriteFusedCollapsedWideBvh(
    uint globalIdIn : SV_DispatchThreadID,
    uint groupIdIn  : SV_GroupID,
    uint localIdIn  : SV_GroupThreadID)
{
    const uint numFcWideNodes = ScratchBuffer.Load(ShaderConstants.offsets.fcWideCounter);
    const uint globalId = globalIdIn;

    LaneGroup laneGroup;
    laneGroup.Alloc(8);

    const AccelStructOffsets offsets = ShaderConstants.header.offsets;
    const uint rootNodeIndex = GetBvh2RootNodeIndex();
    const uint numPrimRefs = ReadAccelStructHeaderField(ACCEL_STRUCT_HEADER_NUM_ACTIVE_PRIMS_OFFSET);
    const bool isSinglePrimBvh = (numPrimRefs == 1);
    const uint scratchNodesScratchOffset = CalculateBvhNodesOffset(ShaderConstants, numPrimRefs);
    const ScratchNode rootScratchNode = FetchScratchNode(scratchNodesScratchOffset, rootNodeIndex);
    const uint numActivePrims =
#if TLAS_BUILD_SUPPORT
        Settings.topLevelBuild ? numPrimRefs : 
#endif
        FetchScratchNodeNumPrimitives(rootScratchNode, isSinglePrimBvh);

    if (globalId == 0)
    {
        const BoundingBox bbox =
            GetScratchNodeBoundingBoxTS(scratchNodesScratchOffset, isSinglePrimBvh, rootScratchNode);

        WriteAccelStructHeaderRootBoundingBox(bbox);

        const uint3 exponents = ComputeCommonExponent(bbox.min, bbox.max, 12);

        // Pre-compute exponent reciprocal
        const float3 rcpExponents = ComputeFastExpReciprocal(exponents, 12);

#if TLAS_BUILD_SUPPORT
        if (Settings.topLevelBuild == false)
#endif
        {
            GPU_ASSERT(Settings.instanceMode == InstanceMode::Passthrough);
            // Generate intersectable instance node data in BLAS metadata
            const uint instanceMask =
                ExtractScratchNodeInstanceMask(rootScratchNode.packedFlags);

            WriteInstancePassthrough(CreateRootNodePointer(),
                                    bbox,
                                    ACCEL_STRUCT_METADATA_INSTANCE_NODE_OFFSET);

            DstBuffer.Store(ACCEL_STRUCT_HEADER_PACKED_FLAGS_OFFSET, rootScratchNode.packedFlags);
        }

        // Write parent pointer for root node.
        QBVH8::WriteParentPointer(offsets.internalNodes, INVALID_IDX);
    }
    if (globalId == 0)
    {
        GPU_DPF("numFcWideNodes: %d", numFcWideNodes);
    }
    bool laneGroupActive = (globalId < numFcWideNodes);
    uint laneActiveMask = laneGroup.Ballot(laneGroupActive);
    while (laneActiveMask)
    {
        uint curLane = firstbitlow(laneActiveMask);
        uint curTargetWideNodeIdx = laneGroup.Broadcast(globalId, curLane);
        GPU_ASSERT(curTargetWideNodeIdx < numFcWideNodes);

        uint clusterIdx;
        BoundingBox curNodeBbox;
        uint4 children0;
        uint4 children1;
        uint curNodeDstOffset;
        uint baseChildBoxNodeOffset;
        uint baseChildLeafNodeOffset;
        float3 exponents;
        float3 rcpExponents;
        if (laneGroup.IsFirstLane())
        {
            clusterIdx = ScratchBuffer.Load<uint>(ShaderConstants.offsets.fcWideNodeClusterIndices + curTargetWideNodeIdx * sizeof(uint)) & 0x7fffffff;
            ScratchNode curScratchNode = FetchScratchNode(scratchNodesScratchOffset, clusterIdx);
            curNodeBbox = GetScratchNodeBoundingBoxTS(scratchNodesScratchOffset, false, curScratchNode);
            uint curNodePackedIdx = ScratchBuffer.Load<uint>(ShaderConstants.offsets.fcWideBvhBoxNodeMappingIndices + (clusterIdx & 0x7fffffff) * sizeof(uint));
            uint curNodeDstIdx = curTargetWideNodeIdx == 0 ? 0 : curNodePackedIdx >> 3;
            curNodeDstOffset = offsets.internalNodes + curNodeDstIdx * QBVH8::NodeSizeInBytes;
            QBVH8::WriteOrigin(curNodeDstOffset, curNodeBbox.min);
            QBVH8::WriteObbMatrixIndex(curNodeDstOffset, INVALID_OBB);

            // The root of the BVH2 treelet contains the combined bounds of the child nodes in the node array. Compute the
            // common exponent from the root node bounds
            exponents = ComputeCommonExponent(curNodeBbox.min, curNodeBbox.max, 12);
            // Pre-compute exponent reciprocal
            rcpExponents = ComputeFastExpReciprocal(exponents, 12);


            uint fcRefsBaseOffset = ShaderConstants.offsets.fcWideNodeClusterReferences + curTargetWideNodeIdx * sizeof(uint4) * 2;
            children0 = ScratchBuffer.Load<uint4>(fcRefsBaseOffset);
            children1 = ScratchBuffer.Load<uint4>(fcRefsBaseOffset + sizeof(uint4));
            uint numValidChildren = (children0.x != INVALID_IDX) + (children0.y != INVALID_IDX) + (children0.z != INVALID_IDX) + (children0.w != INVALID_IDX) +
                                    (children1.x != INVALID_IDX) + (children1.y != INVALID_IDX) + (children1.z != INVALID_IDX) + (children1.w != INVALID_IDX);
            GPU_ASSERT(numValidChildren > 0);
            uint indexInParent = curNodePackedIdx & bits(3);
            QBVH8::WritePackedExpChildIdxAndCount(curNodeDstOffset, exponents, indexInParent, numValidChildren);

            baseChildBoxNodeOffset = ScratchBuffer.Load<uint>(ShaderConstants.offsets.fcWideBvhBaseBoxNodeOffsets + curTargetWideNodeIdx * sizeof(uint));
            if (globalId == 0)
            {
                GPU_DPF("curTargetWideNodeIdx: %u, baseChildBoxNodeOffset: %u", curTargetWideNodeIdx, baseChildBoxNodeOffset);
                // GPU_ASSERT(baseChildBoxNodeOffset == 1);
            }
            baseChildBoxNodeOffset = offsets.internalNodes + baseChildBoxNodeOffset * QBVH8::NodeSizeInBytes;
            baseChildLeafNodeOffset = ScratchBuffer.Load<uint>(ShaderConstants.offsets.fcWideBvhBaseLeafNodeOffsets + curTargetWideNodeIdx * sizeof(uint));
            baseChildLeafNodeOffset = offsets.leafNodes + baseChildLeafNodeOffset * QBVH8::NodeSizeInBytes;

            QBVH8::WriteInternalNodeBaseOffset(curNodeDstOffset, baseChildBoxNodeOffset);
            QBVH8::WriteLeafNodeBaseOffset(curNodeDstOffset, baseChildLeafNodeOffset); // Only for EnableWaveLeafCompressionPass() == false
        }
        children0 = laneGroup.ReadFirstLane(children0);
        children1 = laneGroup.ReadFirstLane(children1);
        uint curLaneChild = (laneGroup.laneIndex < 4) ? children0[laneGroup.laneIndex] : children1[laneGroup.laneIndex - 4];

        clusterIdx = laneGroup.ReadFirstLane(clusterIdx);
        curNodeBbox.min = laneGroup.ReadFirstLane(curNodeBbox.min);
        curNodeBbox.max = laneGroup.ReadFirstLane(curNodeBbox.max);
        curNodeDstOffset = laneGroup.ReadFirstLane(curNodeDstOffset);
        baseChildBoxNodeOffset = laneGroup.ReadFirstLane(baseChildBoxNodeOffset);
        baseChildLeafNodeOffset = laneGroup.ReadFirstLane(baseChildLeafNodeOffset);
        rcpExponents = laneGroup.ReadFirstLane(rcpExponents);

        
        uint indexInParent; // child index whithin the common parent node
        bool isBox = false;
        bool isLeaf = false;
        uint childMappingIdx;
        if (curLaneChild != INVALID_IDX)
        {
            const uint childScratchNodeIdx = curLaneChild & 0x7fffffff;
            isLeaf = (curLaneChild >> 31) ^ 1;
            isBox = !isLeaf;
            if (isBox)
            {
                childMappingIdx = ScratchBuffer.Load<uint>(ShaderConstants.offsets.fcWideBvhBoxNodeMappingIndices + childScratchNodeIdx * sizeof(uint));
            }
            else if (isLeaf)
            {
                childMappingIdx = ScratchBuffer.Load<uint>(ShaderConstants.offsets.fcWideBvhLeafNodeMappingIndices + childScratchNodeIdx * sizeof(uint));
            }
            indexInParent = childMappingIdx & bits(3);
            

            const ScratchNode childScratchNode = FetchScratchNode(scratchNodesScratchOffset, childScratchNodeIdx);
            // If leaf, msb is 0
            const BoundingBox childBbox = GetScratchNodeBoundingBoxTS(scratchNodesScratchOffset, isLeaf, childScratchNode);
            const uint instanceMask =
                ExtractScratchNodeInstanceMask(childScratchNode.packedFlags);

            const uint boxNodeFlags =
                ExtractScratchNodeBoxFlags(childScratchNode.packedFlags);

            const uint nodeType = isLeaf ? NODE_TYPE_TRIANGLE_0 : NODE_TYPE_BOX_QUANTIZED_BVH8;
            const uint nodeRangeLength = isLeaf ? (EnableLeafCompressionPass() ? 0 : 1) : 1;

            const uint3 quantizedChildInfo = QBVH8::ComputePackedChildInfo(childBbox,
                                                                           instanceMask,
                                                                           boxNodeFlags,
                                                                           nodeType,
                                                                           nodeRangeLength,
                                                                           rcpExponents,
                                                                           curNodeBbox.min);

            const uint numBoxChildren = laneGroup.BallotCount(isBox);
            const uint indexInParentFinal = isLeaf ? numBoxChildren + indexInParent : indexInParent;
            QBVH8::WritePackedChildInfo(curNodeDstOffset, indexInParentFinal, quantizedChildInfo);

            const uint curNodePtr = CreateBoxNodePointer(curNodeDstOffset, false);
            const uint baseChildNodeOffset = isLeaf ? baseChildLeafNodeOffset : baseChildBoxNodeOffset;
            const uint childNodeOffset = baseChildNodeOffset + (indexInParent * QBVH8::NodeSizeInBytes);

            if (!isLeaf)
            {
                // const uint childNodeIdx = ScratchBuffer.Load<uint>(ShaderConstants.offsets.fcWideBvhBoxNodeMappingIndices + (childScratchNodeIdx & 0x7fffffff) * sizeof(uint));
                QBVH8::WriteParentPointer(childNodeOffset, curNodePtr);
            }
            else //isLeaf
            {
                // Process and compress leaf children
                if (EnableLeafCompressionPass() == false)
                {
                    // WriteLeafNode(scratchNodesScratchOffset,
                    //               offsets,
                    //               numPrimRefs,
                    //               childScratchNode,
                    //               childScratchNodeIdx,
                    //               BASEPRIMSTRUCTIDX + localChildIndex,
                    //               childNodeOffset,
                    //               curNodePtr);
                    
                    ScratchNode scratchNode = childScratchNode;
                    uint scratchNodeIdx = childScratchNodeIdx;
                    uint nodeOffset = childNodeOffset;
                    // ---------
#if TLAS_BUILD_SUPPORT
                    if (Settings.topLevelBuild)
                    {
                        // TODO : Not Support for TLAS build
                    }
                    else
#endif
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
                            GPU_DPF("isQuadPrim");
                            isTri1Valid = true;
                            isTri0Opaque = (scratchNode.packedFlags);
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
                                // GPU_DPF("CollapseAnyPairs"); // maybe always?
                                firstNodeIndex = scratchNode.left_or_primIndex_or_instIndex;
                                scratchNodeTri0 = FetchScratchNode(scratchNodesScratchOffset, firstNodeIndex);

                                secondNodeIndex = scratchNode.right_or_geometryIndex;
                                scratchNodeTri1 = FetchScratchNode(scratchNodesScratchOffset, secondNodeIndex);
                            }
                            else
                            {
                                GPU_DPF("!UsePrimIndicesArray && !CollapseAnyPairs");
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
                            GPU_DPF("!isQuadPrim && IsLeafNode");
                            isTri0Opaque = IsOpaqueNode(scratchNode.packedFlags);
                            primId0 = scratchNode.left_or_primIndex_or_instIndex;
                            geomId0 = ExtractScratchNodeGeometryIndex(scratchNode);
                            tri0.v0 = scratchNode.bbox_min_or_v0;
                            tri0.v1 = scratchNode.bbox_max_or_v1;
                            tri0.v2 = scratchNode.sah_or_v2_or_instBasePtr;
                        }

                        WritePairPrimStruct(tri0,
                                            isTri0Opaque,
                                            primId0,
                                            geomId0,
                                            isTri1Valid,
                                            tri1,
                                            isTri1Opaque,
                                            primId1,
                                            geomId1,
                                            nodeOffset);


                        const uint childNodeDstIdx = childMappingIdx >> 3;
                        // Store the location of the primitive node for this leaf.
                        DstBuffer.Store(offsets.primNodePtrs + (childNodeDstIdx * sizeof(uint)), nodeOffset);
                    }
                }
            }
        }
        else
        {
            QBVH8::WriteInvalidChildInfo(curNodeDstOffset, laneGroup.laneIndex);
        }
        
        laneActiveMask = laneActiveMask & (laneActiveMask - 1);
        break;
    }


    // uint wideNodeIdx = globalIdIn;
    // if (wideNodeIdx < numFcWideNodes)
    // {
    //     const AccelStructOffsets offsets = ShaderConstants.header.offsets;
    //     const uint rootNodeIndex = GetBvh2RootNodeIndex();
    //     const uint numPrimRefs = ReadAccelStructHeaderField(ACCEL_STRUCT_HEADER_NUM_ACTIVE_PRIMS_OFFSET); // prim with morton code
    //     const bool isSinglePrimBvh = (numPrimRefs == 1);
    //     const uint scratchNodesScratchOffset = CalculateBvhNodesOffset(ShaderConstants, numPrimRefs);
    //     const ScratchNode rootScratchNode = FetchScratchNode(scratchNodesScratchOffset, rootNodeIndex);
    //     const uint numActivePrims =
    //         Settings.topLevelBuild ? numPrimRefs : FetchScratchNodeNumPrimitives(rootScratchNode, isSinglePrimBvh);

    //     if (globalId == 0)
    //     {
    //         const BoundingBox bbox =
    //             GetScratchNodeBoundingBoxTS(scratchNodesScratchOffset, isSinglePrimBvh, rootScratchNode);

    //         WriteAccelStructHeaderRootBoundingBox(bbox);

    //         const uint3 exponents = ComputeCommonExponent(bbox.min, bbox.max, 12);

    //         // Pre-compute exponent reciprocal
    //         const float3 rcpExponents = ComputeFastExpReciprocal(exponents, 12);

    //         if (Settings.topLevelBuild == false)
    //         {
    //             GPU_ASSERT(Settings.instanceMode == InstanceMode::Passthrough);
    //             // Generate intersectable instance node data in BLAS metadata
    //             const uint instanceMask =
    //                 ExtractScratchNodeInstanceMask(rootScratchNode.packedFlags);

    //             WriteInstancePassthrough(CreateRootNodePointer(),
    //                                     bbox,
    //                                     ACCEL_STRUCT_METADATA_INSTANCE_NODE_OFFSET);

    //             DstBuffer.Store(ACCEL_STRUCT_HEADER_PACKED_FLAGS_OFFSET, rootScratchNode.packedFlags);
    //         }

    //         // Write parent pointer for root node.
    //         QBVH8::WriteParentPointer(offsets.internalNodes, INVALID_IDX);
    //     }


    //     const uint clusterIdx = ScratchBuffer.Load<uint>(ShaderConstants.offsets.fcWideNodeClusterIndices + wideNodeIdx * sizeof(uint)) & 0x7fffffff;

    //     const ScratchNode curScratchNode = FetchScratchNode(scratchNodesScratchOffset, clusterIdx);
    //     BoundingBox curNodeBbox = GetScratchNodeBoundingBoxTS(scratchNodesScratchOffset, false, curScratchNode);

    //     const uint fcRefsBaseOffset = ShaderConstants.offsets.fcWideNodeClusterReferences + wideNodeIdx * sizeof(uint4) * 2;
    //     uint4 children0 = ScratchBuffer.Load<uint4>(fcRefsBaseOffset);
    //     for (uint i = 0; i < 4; i++)
    //     {
    //         if (children0[i] != INVALID_IDX)
    //         {
    //             const ScratchNode childScratchNode = FetchScratchNode(scratchNodesScratchOffset, children0[i]);
    //             // If leaf, msb is 0
    //             const BoundingBox childBbox = GetScratchNodeBoundingBoxTS(scratchNodesScratchOffset, (children0[i] >> 31) ^ 1, childScratchNode);


    //         }
    //     }

    //     uint4 children1 = ScratchBuffer.Load<uint4>(fcRefsBaseOffset + sizeof(uint4));

    //     // The root of the BVH2 treelet contains the combined bounds of the child nodes in the node array. Compute the
    //     // common exponent from the root node bounds
    //     exponents = ComputeCommonExponent(curNodeBbox.min, curNodeBbox.max, 12);

    //     // Pre-compute exponent reciprocal
    //     rcpExponents = ComputeFastExpReciprocal(exponents, 12);
        
    //     const uint baseChildBoxNodeOffset = ScratchBuffer.Load<uint>(ShaderConstants.offsets.fcWideBvhBaseBoxNodeOffsets + wideNodeIdx * sizeof(uint));

    //     const uint3 childInfo = ComputePackedChildInfo(scratchNodesScratchOffset,
    //                                                    scratchNode,
    //                                                    scratchNodeIdx,
    //                                                    nodeType,
    //                                                    primRangeLength,
    //                                                    rcpExponents,
    //                                                    curNodeBbox.min,
    //                                                    numPrimRefs);

    //     const uint dstIdx = ScratchBuffer.Load<uint>(ShaderConstants.offsets.fcWideBvhBoxNodeMappingIndices + clusterIdx * sizeof(uint));
    // }
}

#undef TLAS_BUILD_SUPPORT