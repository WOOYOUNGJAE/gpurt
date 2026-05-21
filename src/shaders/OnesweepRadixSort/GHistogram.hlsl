
#if NO_SHADER_ENTRYPOINT == 0
//=====================================================================================================================
#include "../../shadersClean/build/BuildRootSignature.hlsli"

#include "../../shadersClean/build/BuildCommonScratch.hlsli"

#include "OnesweepCommon.hlsli"

//=====================================================================================================================
// Note: Incompatible with BuildParallel's LDS layout.
groupshared uint localCounters[N_ITERATION][BIN_SIZE];
groupshared uint iBlock;
#endif

void InitGHistogramImpl(
    uint globalId,
    uint numHistogramElements,
    uint counterOffset,
    uint gpSumOffset
)
{
    if (globalId == 0)
    {
        ScratchBuffer.Store<uint>(counterOffset, 0);
    }

    if (globalId < numHistogramElements)
    {
        ScratchBuffer.Store<uint>(gpSumOffset + globalId * sizeof(uint), 0);
    }
}

uint ScanExclusiveLocalCounters(uint prefix, uint iteration, uint start, uint localId, uint nElements)
{
    bool active = localId < nElements;
    uint idx = start + localId;
    uint value = active ? localCounters[iteration][idx] : 0;
    uint x = value;

    for (uint offset = 1; offset < nElements; offset <<= 1)
    {
        if (active && offset <= localId)
        {
            x += localCounters[iteration][idx - offset];
        }

        GroupMemoryBarrierWithGroupSync();

        if (active)
        {
            localCounters[iteration][idx] = x;
        }

        GroupMemoryBarrierWithGroupSync();
    }

    uint sum = localCounters[iteration][start + nElements - 1];

    GroupMemoryBarrierWithGroupSync();

    if (active)
    {
        localCounters[iteration][idx] = x + prefix - value;
    }

    GroupMemoryBarrierWithGroupSync();

    return sum;
}


void GHistogramImpl(
    uint localId,
    uint numElements,
    uint inputKeysOffset,
    uint counterOffset,
    uint gpSumOffset
)
{
    for (uint i = 0; i < N_ITERATION; i++)
    {
        for (uint j = localId; j < BIN_SIZE; j += GHISTOGRAM_THREADS_PER_BLOCK)
        {
            localCounters[i][j] = 0;
        }
    }
    uint numberOfBlocks = RoundUpQuotient(numElements, GHISTOGRAM_ITEMS_PER_BLOCK);

    for (;;)
    {
        if (localId == 0)
        {
            ScratchBuffer.InterlockedAdd(counterOffset, 1, iBlock);
        }
        GroupMemoryBarrierWithGroupSync();

        if (numberOfBlocks <= iBlock)
            break;

        for (uint j = 0; j < GHISTOGRAM_ITEMS_PER_THREAD; j++)
        {
            uint itemIndex = iBlock * GHISTOGRAM_ITEMS_PER_BLOCK + localId * GHISTOGRAM_ITEMS_PER_THREAD + j;
            if (itemIndex < numElements)
            {
                RADIX_SORT_KEY_TYPE item = ScratchBuffer.Load<RADIX_SORT_KEY_TYPE>(inputKeysOffset + itemIndex * sizeof(RADIX_SORT_KEY_TYPE));
                for (uint i = 0; i < N_ITERATION; i++)
                {
                    uint bitLocation = i * N_RADIX;
                    uint bits = extractDigit(getKeyBits(item), bitLocation);
                    InterlockedAdd(localCounters[i][bits], 1);
                }
            }
        }

        GroupMemoryBarrierWithGroupSync();
    }

    for (uint i = 0; i < N_ITERATION; i++)
    {
        uint prefix = 0;
        for (uint j = 0; j < BIN_SIZE; j += GHISTOGRAM_THREADS_PER_BLOCK)
        {
            prefix += ScanExclusiveLocalCounters(prefix, i, j, localId, min(GHISTOGRAM_THREADS_PER_BLOCK, BIN_SIZE));
        }
    }

    for (uint i = 0; i < N_ITERATION; i++)
    {
        for (uint j = localId; j < BIN_SIZE; j += GHISTOGRAM_THREADS_PER_BLOCK)
        {
            ScratchBuffer.InterlockedAdd(gpSumOffset + (BIN_SIZE * i + j) * sizeof(uint), localCounters[i][j]);
        }
    }
}

#if NO_SHADER_ENTRYPOINT == 0
//=====================================================================================================================
// Main Function : InitGHistogram
// The kernel initializes counter and gpSum buffer to zero.
// Number of threads should be histogram size (N_ITERATION * BIN_SIZE)
//=====================================================================================================================
[RootSignature(RootSig)]
[numthreads(GHISTOGRAM_THREADS_PER_BLOCK, 1, 1)]
void InitGHistogram(
    uint globalId : SV_DispatchThreadID)
{
    const uint nIteration = Settings.useMortonCode30 ? 32 / N_RADIX : 64 / N_RADIX;
    const uint numHistogramElements = nIteration * BIN_SIZE;
    
    const uint counterOffset = ShaderConstants.offsets.histogramTaskCounter;
    const uint gpSumOffset = ShaderConstants.offsets.histogram;

    InitGHistogramImpl(globalId, numHistogramElements, counterOffset, gpSumOffset);
}

//=====================================================================================================================
// Main Function : GHistogram
// The kernel computes global histogram of input morton codes.
//=====================================================================================================================
[RootSignature(RootSig)]
[numthreads(GHISTOGRAM_THREADS_PER_BLOCK, 1, 1)]
void GHistogram(
    uint localId : SV_GroupThreadID)
{
    const uint numPrimitives = FetchTaskCounter(
        ShaderConstants.offsets.encodeTaskCounter + ENCODE_TASK_COUNTER_PRIM_REFS_OFFSET);
    const uint inputKeysOffset = ShaderConstants.offsets.mortonCodes;
    const uint counterOffset = ShaderConstants.offsets.histogramTaskCounter;
    const uint gpSumOffset = ShaderConstants.offsets.histogram;

    GHistogramImpl(localId, numPrimitives, inputKeysOffset, counterOffset, gpSumOffset);
}

#endif