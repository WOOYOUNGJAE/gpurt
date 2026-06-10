#include "../shadersClean/common/ShaderDefs.hlsli"

#define GC_DSTBUFFER
#define GC_DSTMETADATA
#define GC_SCRATCHBUFFER
#include "../shadersClean/build/BuildRootSignature.hlsli"
#include "../shadersClean/common/Common.hlsli"

inline uint PackBoxNodeMappingIndexBits(uint mappingIndex, uint childIndexInParent)
{
    return ((mappingIndex << 3) | (childIndexInParent & bits(3)));
}

//=====================================================================================================================
// Main Function : FusedCollapsingTaskShader
//=====================================================================================================================
[RootSignature(RootSig)]
[numthreads(1, 1, 1)]
void FusedCollapsingTaskShader(
    uint globalIdIn : SV_DispatchThreadID)
{
    uint numFcWideNodes = ScratchBuffer.Load(ShaderConstants.offsets.fcWideCounter);
    GPU_DPF("numFcWideNodes (from scratch): %d", numFcWideNodes);

    uint3 indirectArgs = uint3(RoundUpQuotient(numFcWideNodes, BUILD_THREADGROUP_SIZE), 1, 1);
    ScratchGlobal.Store<uint3>(ShaderConstants.offsets.encodeTaskCounter + ENCODE_TASK_COUNTER_INDIRECT_ARGS, indirectArgs);

    const uint fcRefsBaseOffset = ShaderConstants.offsets.fcWideNodeClusterReferences;
    uint4 refs0 = ScratchBuffer.Load<uint4>(fcRefsBaseOffset);
    uint4 refs1 = ScratchBuffer.Load<uint4>(fcRefsBaseOffset + sizeof(uint4));

    // 1. Count Active refs
    // 1.1 Count active internal node count ( != 0xffffffff && msb is 1)
    uint4 intVec0 = (refs0 >> 31) & (refs0 != 0xffffffff);    
    uint4 intVec1 = (refs1 >> 31) & (refs1 != 0xffffffff);
    uint numInternals = (intVec0.x + intVec0.y + intVec0.z + intVec0.w) + 
        (intVec1.x + intVec1.y + intVec1.z + intVec1.w);

    uint internalNodeOutputBaseIdx;
    ScratchBuffer.InterlockedAdd(ShaderConstants.offsets.fcBoxNodeAssignmentCounter, numInternals, internalNodeOutputBaseIdx);
    uint indexInParent = 0;
    if (intVec0.x)
    {
        ScratchBuffer.Store(ShaderConstants.offsets.fcWideBvhBoxNodeMappingIndices + (refs0.x & 0x7fffffff) * sizeof(uint), PackBoxNodeMappingIndexBits(internalNodeOutputBaseIdx++, indexInParent++));
    }
    if (intVec0.y)
    {
        ScratchBuffer.Store(ShaderConstants.offsets.fcWideBvhBoxNodeMappingIndices + (refs0.y & 0x7fffffff) * sizeof(uint), PackBoxNodeMappingIndexBits(internalNodeOutputBaseIdx++, indexInParent++));
    }
    if (intVec0.z)
    {            
        ScratchBuffer.Store(ShaderConstants.offsets.fcWideBvhBoxNodeMappingIndices + (refs0.z & 0x7fffffff) * sizeof(uint), PackBoxNodeMappingIndexBits(internalNodeOutputBaseIdx++, indexInParent++));
    }
    if (intVec0.w)
    {
        ScratchBuffer.Store(ShaderConstants.offsets.fcWideBvhBoxNodeMappingIndices + (refs0.w & 0x7fffffff) * sizeof(uint), PackBoxNodeMappingIndexBits(internalNodeOutputBaseIdx++, indexInParent++));
    }

    if (intVec1.x)
    {
        ScratchBuffer.Store(ShaderConstants.offsets.fcWideBvhBoxNodeMappingIndices + (refs1.x & 0x7fffffff) * sizeof(uint), PackBoxNodeMappingIndexBits(internalNodeOutputBaseIdx++, indexInParent++));
    }
    if (intVec1.y)
    {
        ScratchBuffer.Store(ShaderConstants.offsets.fcWideBvhBoxNodeMappingIndices + (refs1.y & 0x7fffffff) * sizeof(uint), PackBoxNodeMappingIndexBits(internalNodeOutputBaseIdx++, indexInParent++));
    }
    if (intVec1.z)
    {            
        ScratchBuffer.Store(ShaderConstants.offsets.fcWideBvhBoxNodeMappingIndices + (refs1.z & 0x7fffffff) * sizeof(uint), PackBoxNodeMappingIndexBits(internalNodeOutputBaseIdx++, indexInParent++));
    }
    if (intVec1.w)
    {
        ScratchBuffer.Store(ShaderConstants.offsets.fcWideBvhBoxNodeMappingIndices + (refs1.w & 0x7fffffff) * sizeof(uint), PackBoxNodeMappingIndexBits(internalNodeOutputBaseIdx++, indexInParent++));
    }

    // 1.2 Count active leaf node count ( != 0xffffffff && msb is 0)
    intVec0 = ((refs0 >> 31) ^ 1) & (refs0 != 0xffffffff);
    intVec1 = ((refs1 >> 31) ^ 1) & (refs1 != 0xffffffff);
    uint numLeafs = (intVec0.x + intVec0.y + intVec0.z + intVec0.w) + 
        (intVec1.x + intVec1.y + intVec1.z + intVec1.w);

    uint leafNodeOutputBaseIdx;
    ScratchBuffer.InterlockedAdd(ShaderConstants.offsets.fcLeafNodeAssignmentCounter, numLeafs, leafNodeOutputBaseIdx);
    ScratchBuffer.Store(ShaderConstants.offsets.fcWideBvhBaseLeafNodeOffsets, leafNodeOutputBaseIdx);
    indexInParent = 0;
    if (intVec0.x)
    {
        ScratchBuffer.Store(ShaderConstants.offsets.fcWideBvhLeafNodeMappingIndices + (refs0.x & 0x7fffffff) * sizeof(uint), PackBoxNodeMappingIndexBits(leafNodeOutputBaseIdx++, indexInParent++));
    }
    if (intVec0.y)
    {
        ScratchBuffer.Store(ShaderConstants.offsets.fcWideBvhLeafNodeMappingIndices + (refs0.y & 0x7fffffff) * sizeof(uint), PackBoxNodeMappingIndexBits(leafNodeOutputBaseIdx++, indexInParent++));
    }
    if (intVec0.z)
    {            
        ScratchBuffer.Store(ShaderConstants.offsets.fcWideBvhLeafNodeMappingIndices + (refs0.z & 0x7fffffff) * sizeof(uint), PackBoxNodeMappingIndexBits(leafNodeOutputBaseIdx++, indexInParent++));
    }
    if (intVec0.w)
    {
        ScratchBuffer.Store(ShaderConstants.offsets.fcWideBvhLeafNodeMappingIndices + (refs0.w & 0x7fffffff) * sizeof(uint), PackBoxNodeMappingIndexBits(leafNodeOutputBaseIdx++, indexInParent++));
    }

    if (intVec1.x)
    {
        ScratchBuffer.Store(ShaderConstants.offsets.fcWideBvhLeafNodeMappingIndices + (refs1.x & 0x7fffffff) * sizeof(uint), PackBoxNodeMappingIndexBits(leafNodeOutputBaseIdx++, indexInParent++));
    }
    if (intVec1.y)
    {
        ScratchBuffer.Store(ShaderConstants.offsets.fcWideBvhLeafNodeMappingIndices + (refs1.y & 0x7fffffff) * sizeof(uint), PackBoxNodeMappingIndexBits(leafNodeOutputBaseIdx++, indexInParent++));
    }
    if (intVec1.z)
    {            
        ScratchBuffer.Store(ShaderConstants.offsets.fcWideBvhLeafNodeMappingIndices + (refs1.z & 0x7fffffff) * sizeof(uint), PackBoxNodeMappingIndexBits(leafNodeOutputBaseIdx++, indexInParent++));
    }
    if (intVec1.w)
    {
        ScratchBuffer.Store(ShaderConstants.offsets.fcWideBvhLeafNodeMappingIndices + (refs1.w & 0x7fffffff) * sizeof(uint), PackBoxNodeMappingIndexBits(leafNodeOutputBaseIdx++, indexInParent++));
    }
}