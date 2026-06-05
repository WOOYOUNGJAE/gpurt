#include "../shadersClean/common/ShaderDefs.hlsli"

#define GC_DSTBUFFER
#define GC_DSTMETADATA
#define GC_SCRATCHBUFFER
#include "../shadersClean/build/BuildRootSignature.hlsli"
#include "../shadersClean/build/BuildCommonScratch.hlsli"


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
    const uint numFcWideNodes = ScratchGlobal.Load(ShaderConstants.offsets.fcWideCounter);
    const uint wideNodeIdx = globalIdIn;

    if (wideNodeIdx < numFcWideNodes)
    {
        const uint clusterIdx = ScratchBuffer.Load<uint>(ShaderConstants.offsets.fcWideNodeClusterIndices + wideNodeIdx * sizeof(uint));

        const uint fcRefsBaseOffset = ShaderConstants.offsets.fcWideNodeClusterReferences + wideNodeIdx * sizeof(uint4) * 2;
        uint4 refs0 = ScratchGlobal.Load<uint4>(fcRefsBaseOffset);
        uint4 refs1 = ScratchGlobal.Load<uint4>(fcRefsBaseOffset + sizeof(uint4));

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
            waveBaseInternalIdx = ScratchGlobal.InterlockedAdd(ShaderConstants.offsets.fcInternalNodeAssignmentCounter, numWaveInternals);
        }
        waveBaseInternalIdx = WaveReadLaneFirst(waveBaseInternalIdx);
#endif
        uint internalNodeOutputBaseIdx = IncrementScratchCounter(ShaderConstants.offsets.fcInternalNodeAssignmentCounter, numInternals);
        
        if (intVec0.x)
        {
            ScratchGlobal.Store(ShaderConstants.offsets.fcWideBvhInternalNodeOutputIndices + internalNodeOutputBaseIdx++, refs0.x & 0x7fffffff);
        }
        if (intVec0.y)
        {
            ScratchGlobal.Store(ShaderConstants.offsets.fcWideBvhInternalNodeOutputIndices + internalNodeOutputBaseIdx++, refs0.y & 0x7fffffff);
        }
        if (intVec0.z)
        {            
            ScratchGlobal.Store(ShaderConstants.offsets.fcWideBvhInternalNodeOutputIndices + internalNodeOutputBaseIdx++, refs0.z & 0x7fffffff);
        }
        if (intVec0.w)
        {
            ScratchGlobal.Store(ShaderConstants.offsets.fcWideBvhInternalNodeOutputIndices + internalNodeOutputBaseIdx++, refs0.w & 0x7fffffff);
        }

        if (intVec1.x)
        {
            ScratchGlobal.Store(ShaderConstants.offsets.fcWideBvhInternalNodeOutputIndices + internalNodeOutputBaseIdx++, refs1.x & 0x7fffffff);
        }
        if (intVec1.y)
        {
            ScratchGlobal.Store(ShaderConstants.offsets.fcWideBvhInternalNodeOutputIndices + internalNodeOutputBaseIdx++, refs1.y & 0x7fffffff);
        }
        if (intVec1.z)
        {            
            ScratchGlobal.Store(ShaderConstants.offsets.fcWideBvhInternalNodeOutputIndices + internalNodeOutputBaseIdx++, refs1.z & 0x7fffffff);
        }
        if (intVec1.w)
        {
            ScratchGlobal.Store(ShaderConstants.offsets.fcWideBvhInternalNodeOutputIndices + internalNodeOutputBaseIdx++, refs1.w & 0x7fffffff);
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
            waveBaseLeafIdx = ScratchGlobal.InterlockedAdd(ShaderConstants.offsets.fcPrimNodeAssignmentCounter, numWaveLeafs);
        }
        waveBaseLeafIdx = WaveReadLaneFirst(waveBaseLeafIdx);
#endif
        // Get BaseIndex
        uint leafNodeOutputBaseIdx = IncrementScratchCounter(ShaderConstants.offsets.fcPrimNodeAssignmentCounter, numLeafs);
        
        if (intVec0.x)
        {
            ScratchGlobal.Store(ShaderConstants.offsets.fcWideBvhPrimNodeOutputIndices + leafNodeOutputBaseIdx++, refs0.x & 0x7fffffff);
        }
        if (intVec0.y)
        {
            ScratchGlobal.Store(ShaderConstants.offsets.fcWideBvhPrimNodeOutputIndices + leafNodeOutputBaseIdx++, refs0.y & 0x7fffffff);
        }
        if (intVec0.z)
        {            
            ScratchGlobal.Store(ShaderConstants.offsets.fcWideBvhPrimNodeOutputIndices + leafNodeOutputBaseIdx++, refs0.z & 0x7fffffff);
        }
        if (intVec0.w)
        {
            ScratchGlobal.Store(ShaderConstants.offsets.fcWideBvhPrimNodeOutputIndices + leafNodeOutputBaseIdx++, refs0.w & 0x7fffffff);
        }

        if (intVec1.x)
        {
            ScratchGlobal.Store(ShaderConstants.offsets.fcWideBvhPrimNodeOutputIndices + leafNodeOutputBaseIdx++, refs1.x & 0x7fffffff);
        }
        if (intVec1.y)
        {
            ScratchGlobal.Store(ShaderConstants.offsets.fcWideBvhPrimNodeOutputIndices + leafNodeOutputBaseIdx++, refs1.y & 0x7fffffff);
        }
        if (intVec1.z)
        {            
            ScratchGlobal.Store(ShaderConstants.offsets.fcWideBvhPrimNodeOutputIndices + leafNodeOutputBaseIdx++, refs1.z & 0x7fffffff);
        }
        if (intVec1.w)
        {
            ScratchGlobal.Store(ShaderConstants.offsets.fcWideBvhPrimNodeOutputIndices + leafNodeOutputBaseIdx++, refs1.w & 0x7fffffff);
        }
    }
}

