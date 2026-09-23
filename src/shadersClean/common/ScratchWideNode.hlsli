#ifndef _SCRATCH_WIDE_NODE_HLSL
#define _SCRATCH_WIDE_NODE_HLSL

#include "gfx10/BoxNode1_0.hlsli"

//=====================================================================================================================
// The structure is 64-byte aligned. Used only for wide internal nodes for now.
struct ScratchWideNode
{
    // children's wide node index for internal nodes
    // leaf scratch index for leaf nodes
    uint4  children0WideNodeIndexOrLeafScratchIndex;
    uint4  children1WideNodeIndexOrLeafScratchIndex;

    // The scratch wide node's bounding box must be updated after merging.
    float3 bbox_min;
    uint   scratchIndex;

    float3 bbox_max;
    // NOTE : "block" means the leader node containing the merged sibling's children.
    uint   packedFlags; // unused [24:31]
                        // offset in the block. [17:19] - for merged node
                        //  If nodes are merged, the offset starts after the leaves merged from previous siblings.
                        //  If this is 0, the node is either the leader child or a zero-leaf box.
                        // num siblings merged into this node [17:19] - for leader node (not used)
                        // leader mask of child nodes [9:16]
                        // whether this node is the leader box node [8] (not used)
                        // number of leaf children [4:7]
                        // number of box children [0:3]
};

#define SCRATCH_WIDE_NODE_CHILDREN0_OR_LEAF_SCRATCH_INDEX_OFFSET 0
#define SCRATCH_WIDE_NODE_CHILDREN1_OR_LEAF_SCRATCH_INDEX_OFFSET 16
#define SCRATCH_WIDE_NODE_BBOX_MIN_OFFSET                        32
#define SCRATCH_WIDE_NODE_SCRATCH_INDEX_OFFSET                   44
#define SCRATCH_WIDE_NODE_BBOX_MAX_OFFSET                        48
#define SCRATCH_WIDE_NODE_FLAGS_OFFSET                           60
#define SCRATCH_WIDE_NODE_SIZE                                   64

//=====================================================================================================================
static uint CalcScratchWideNodeOffset(
    uint baseScratchNodesOffset,
    uint nodeIndex)
{
    return baseScratchNodesOffset + (nodeIndex * SCRATCH_WIDE_NODE_SIZE);
}

//======================================================================================================================
static uint CalculateScratchWideBvhNodesOffset(
    in uint numActivePrims,
    in uint numLeafNodes,
    in uint bvhWideNodesOffset)
{
    uint offset = 0;
    // In case of a BLAS with 1 primitive, the scratch offset for both, bvhNodeData and
    // bvhLeafNodeData are the same. Hence, offset = 0 for such BLASs.
    if (numLeafNodes > 1)
    {
        offset = (numLeafNodes - numActivePrims) * SCRATCH_WIDE_NODE_SIZE;
    }

    return bvhWideNodesOffset + offset;
}

//=====================================================================================================================
static uint PackScratchWideNodeGeometryIndex(
    in uint geometryIndex,
    in uint primIdOffsetTri0)
{
    return geometryIndex | (primIdOffsetTri0 << 24u);
}

//=====================================================================================================================
// Extract node flags from scratch node
static uint ExtractScratchWideNodeBoxFlags(
    in uint packedFlags)
{
    return (packedFlags & 0xff);
}

//=====================================================================================================================
// Extract instance mask from scratch node
static uint ExtractScratchWideNodeInstanceMask(
    in uint packedFlags)
{
    // Note, we store the instance exclusion mask (instead of inclusion) so that we can combine the
    // masks together using a AND operation similar to boxNodeFlags.
    return (~packedFlags >> 8) & 0xff;
}

#if GPURT_BUILD_RTIP3_1
//=====================================================================================================================
// Extract OBB matrix index from scratch node
static uint ExtractScratchWideNodeObbMatrixIdx(
    in uint packedFlags)
{
    return (packedFlags >> 24) & 0xFF;
}
#endif

//=====================================================================================================================
// Extract geometry type from node flags from scratch node
static uint ExtractScratchWideNodeGeometryType(
    in uint packedFlags)
{
    const uint boxNodeFlags = ExtractScratchWideNodeBoxFlags(packedFlags);
    const uint geometryType = ((boxNodeFlags >> BOX_NODE_FLAGS_ONLY_TRIANGLES_SHIFT) & 1) ? 0 : 1;

    return geometryType;
}

#endif // _SCRATCH_WIDE_NODE_HLSL