#include "../shadersClean/common/ShaderDefs.hlsli"

#define GC_DSTBUFFER
#define GC_DSTMETADATA
#define GC_SCRATCHBUFFER
#include "../shadersClean/build/BuildRootSignature.hlsli"
#include "../shadersClean/build/BuildCommonScratch.hlsli"

inline uint PackBoxNodeMappingIndexBits(uint mappingIndex, uint childIndexInParent)
{
    return ((mappingIndex << 3) | (childIndexInParent & bits(3)));
}

//=====================================================================================================================
// Main Function : AssignFusedCollapsedIndices
//=====================================================================================================================
[RootSignature(RootSig)]
[numthreads(BUILD_THREADGROUP_SIZE, 1, 1)]
void AssignFusedCollapsedIndices(
    uint globalIdIn : SV_DispatchThreadID,
    uint groupIdIn  : SV_GroupID,
    uint localIdIn  : SV_GroupThreadID)
{
    const uint numFcWideNodes = ScratchBuffer.Load(ShaderConstants.offsets.fcWideCounter);
    const uint wideNodeIdx = globalIdIn;

    if (globalIdIn == 0)
    {
        GPU_DPF("numFcWideNodes: %d", numFcWideNodes);
    }

    if (wideNodeIdx < numFcWideNodes)
    {
        const uint fcRefsBaseOffset = ShaderConstants.offsets.fcWideNodeClusterReferences + wideNodeIdx * sizeof(uint4) * 2;
        uint4 refs0 = ScratchBuffer.Load<uint4>(fcRefsBaseOffset);
        uint4 refs1 = ScratchBuffer.Load<uint4>(fcRefsBaseOffset + sizeof(uint4));

        // 1. Count Active refs
        // 1.1 Count active internal node count ( != 0xffffffff && msb is 1)
        uint4 intVec0 = (refs0 >> 31) & (refs0 != 0xffffffff);    
        uint4 intVec1 = (refs1 >> 31) & (refs1 != 0xffffffff);
        uint numInternals = (intVec0.x + intVec0.y + intVec0.z + intVec0.w) + 
            (intVec1.x + intVec1.y + intVec1.z + intVec1.w);

#if 0   // TODO: It may be more efficient to perform the atomic operation at the wave level.
        uint numWaveInternals = WaveActiveSum(numInternals);
        uint waveBaseInternalIdx = 0;
        if (WaveIsFirstLane())
        {
            waveBaseInternalIdx = ScratchBuffer.InterlockedAdd(ShaderConstants.offsets.fcBoxNodeAssignmentCounter, numWaveInternals);
        }
        waveBaseInternalIdx = WaveReadLaneFirst(waveBaseInternalIdx);
#endif
        uint internalNodeOutputBaseIdx;
        if (wideNodeIdx == 0)
        {
            internalNodeOutputBaseIdx = 1; // 0 is for root node
        }
        else
        {
            ScratchBuffer.InterlockedAdd(ShaderConstants.offsets.fcBoxNodeAssignmentCounter, numInternals, internalNodeOutputBaseIdx);
        }
        // if (globalIdIn == 0 || globalIdIn == 1 || internalNodeOutputBaseIdx < 3)
        // {
        //     GPU_DPF("globalIdIn: %d, internalNodeOutputBaseIdx: %d", globalIdIn, internalNodeOutputBaseIdx);
        // }
        ScratchBuffer.Store(ShaderConstants.offsets.fcWideBvhBaseBoxNodeOffsets + wideNodeIdx * sizeof(uint), internalNodeOutputBaseIdx);
        
        
        // if ((refs0.x & bit(31)) && (refs0.x & 0x7fffffff) < 10)
        // {
        //     GPU_DPF("ref0: %08x", refs0.x);
        // }
        // if ((refs0.y & bit(31)) && (refs0.y & 0x7fffffff) < 10)
        // {
        //     GPU_DPF("ref0: %08x", refs0.y);
        // }
        // if ((refs0.z & bit(31)) && (refs0.z & 0x7fffffff) < 10)
        // {
        //     GPU_DPF("ref0: %08x", refs0.z);
        // }
        // if ((refs0.w & bit(31)) && (refs0.w & 0x7fffffff) < 10)
        // {
        //     GPU_DPF("ref0: %08x", refs0.w);
        // }
        // if ((refs1.x & bit(31)) && (refs1.x & 0x7fffffff) < 10)
        // {
        //     GPU_DPF("ref1: %08x", refs1.x);
        // }
        // if ((refs1.y & bit(31)) && (refs1.y & 0x7fffffff) < 10)
        // {
        //     GPU_DPF("ref1: %08x", refs1.y);
        // }
        // if ((refs1.z & bit(31)) && (refs1.z & 0x7fffffff) < 10)
        // {
        //     GPU_DPF("ref1: %08x", refs1.z);
        // }
        // if ((refs1.w & bit(31)) && (refs1.w & 0x7fffffff) < 10)
        // {
        //     GPU_DPF("ref1: %08x", refs1.w);
        // }
        

        
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


#if 0   // TODO: It may be more efficient to perform the atomic operation at the wave level.
        uint numWaveLeafs = WaveActiveSum(numLeafs);
        uint waveBaseLeafIdx = 0;
        if (WaveIsFirstLane())
        {
            waveBaseLeafIdx = ScratchBuffer.InterlockedAdd(ShaderConstants.offsets.fcLeafNodeAssignmentCounter, numWaveLeafs);
        }
        waveBaseLeafIdx = WaveReadLaneFirst(waveBaseLeafIdx);
#endif
        // Get BaseIndex
        uint leafNodeOutputBaseIdx;
        if (wideNodeIdx == 0)
        {
            leafNodeOutputBaseIdx = 0;
        }
        else
        {
            ScratchBuffer.InterlockedAdd(ShaderConstants.offsets.fcLeafNodeAssignmentCounter, numLeafs, leafNodeOutputBaseIdx);
        }
        ScratchBuffer.Store(ShaderConstants.offsets.fcWideBvhBaseLeafNodeOffsets + wideNodeIdx * sizeof(uint), leafNodeOutputBaseIdx);

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
}

