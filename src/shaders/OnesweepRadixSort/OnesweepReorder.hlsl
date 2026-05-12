#if NO_SHADER_ENTRYPOINT == 0
//=====================================================================================================================
#include "../../shadersClean/build/BuildRootSignature.hlsli"

#include "../../shadersClean/build/BuildCommonScratch.hlsli"

#include "OnesweepCommon.hlsli"
#endif

//=====================================================================================================================
// Macros for LDS offsets and sizes
#define MAX2(a, b) (((a) > (b)) ? (a) : (b))
#define MAX3(a, b, c) (MAX2(MAX2((a), (b)), (c)))

#define LDS_PHASE1_BLOCK_HISTOGRAM_OFFSET (0)
#define LDS_PHASE1_BLOCK_HISTOGRAM_SIZE (BIN_SIZE)
#define LDS_PHASE1_LP_SUM_OFFSET (LDS_PHASE1_BLOCK_HISTOGRAM_SIZE)
#define LDS_PHASE1_LP_SUM_SIZE (BIN_SIZE * REORDER_NUMBER_OF_WARPS)
#define LDS_PHASE1_SIZE (LDS_PHASE1_BLOCK_HISTOGRAM_SIZE + LDS_PHASE1_LP_SUM_SIZE)

#define LDS_PHASE2_ELEMENTS_OFFSET (0)
#define LDS_PHASE2_ELEMENTS_SIZE (RADIX_SORT_BLOCK_SIZE * sizeof(RADIX_SORT_KEY_TYPE) / 2)
#define LDS_PHASE2_SIZE (LDS_PHASE2_ELEMENTS_SIZE)

#define LDS_PHASE3_ELEMENTS_OFFSET (0)
#define LDS_PHASE3_ELEMENTS_SIZE (RADIX_SORT_BLOCK_SIZE * sizeof(RADIX_SORT_VALUE_TYPE) / 2)
#define LDS_PHASE3_BUCKETS_OFFSET (LDS_PHASE3_ELEMENTS_SIZE)
#define LDS_PHASE3_BUCKETS_SIZE (RADIX_SORT_BLOCK_SIZE)
#define LDS_PHASE3_SIZE (LDS_PHASE3_ELEMENTS_SIZE + LDS_PHASE3_BUCKETS_SIZE)

#define LDS_PHASE_MAX_SIZE MAX3(LDS_PHASE1_SIZE, LDS_PHASE2_SIZE, LDS_PHASE3_SIZE)

#if NO_SHADER_ENTRYPOINT == 0
//=====================================================================================================================
// Note: Incompatible with BuildParallel's LDS layout.
groupshared uint32_t pSum[BIN_SIZE];
groupshared uint16_t smem[LDS_PHASE_MAX_SIZE];
#endif

//=====================================================================================================================
// Helper functions for LDS access
uint LoadLDS32(uint offset)
{
    uint lo = (uint)smem[offset + 0];
    uint hi = (uint)smem[offset + 1];

    return lo | (hi << 16);
}

void StoreLDS32(uint offset, uint value)
{
    smem[offset + 0] = (uint16_t)((value >> 0) & 0xFFFF);
    smem[offset + 1] = (uint16_t)((value >> 16) & 0xFFFF);
}

uint64_t LoadLDS64(uint offset)
{
    uint64_t x0 = (uint64_t)smem[offset + 0];
    uint64_t x1 = (uint64_t)smem[offset + 1];
    uint64_t x2 = (uint64_t)smem[offset + 2];
    uint64_t x3 = (uint64_t)smem[offset + 3];

    return
          (x0 << 0)
        | (x1 << 16)
        | (x2 << 32)
        | (x3 << 48);
}

void StoreLDS64(uint offset, uint64_t value)
{
    smem[offset + 0] = (uint16_t)((value >> 0) & 0xFFFF);
    smem[offset + 1] = (uint16_t)((value >> 16) & 0xFFFF);
    smem[offset + 2] = (uint16_t)((value >> 32) & 0xFFFF);
    smem[offset + 3] = (uint16_t)((value >> 48) & 0xFFFF);
}

uint16_t GetLDSPhase1BlockHistogram(uint offset)
{
    return smem[LDS_PHASE1_BLOCK_HISTOGRAM_OFFSET + offset];
}

void SetLDSPhase1BlockHistogram(uint offset, uint16_t value)
{
    smem[LDS_PHASE1_BLOCK_HISTOGRAM_OFFSET + offset] = value;
}

uint16_t GetLDSPhase1LpSum(uint offset)
{
    return smem[LDS_PHASE1_LP_SUM_OFFSET + offset];
}

void SetLDSPhase1LpSum(uint offset, uint16_t value)
{
    smem[LDS_PHASE1_LP_SUM_OFFSET + offset] = value;
}

RADIX_SORT_KEY_TYPE GetLDSPhase2Element(uint offset)
{
#if USE_MORTON_CODE_30
    return LoadLDS32(LDS_PHASE2_ELEMENTS_OFFSET + offset * 2);
#else
    return LoadLDS64(LDS_PHASE2_ELEMENTS_OFFSET + offset * 4);
#endif
}

void SetLDSPhase2Element(uint offset, RADIX_SORT_KEY_TYPE value)
{
#if USE_MORTON_CODE_30
    StoreLDS32(LDS_PHASE2_ELEMENTS_OFFSET + offset * 2, value);
#else
    StoreLDS64(LDS_PHASE2_ELEMENTS_OFFSET + offset * 4, value);
#endif
}

RADIX_SORT_VALUE_TYPE GetLDSPhase3Element(uint offset)
{
    return LoadLDS32(LDS_PHASE3_ELEMENTS_OFFSET + offset * 2);
}

void SetLDSPhase3Element(uint offset, RADIX_SORT_VALUE_TYPE value)
{
    StoreLDS32(LDS_PHASE3_ELEMENTS_OFFSET + offset * 2, value);
}

uint16_t GetLDSPhase3Bucket(uint offset)
{
    return smem[LDS_PHASE3_BUCKETS_OFFSET + offset];
}

void SetLDSPhase3Bucket(uint offset, uint16_t value)
{
    smem[LDS_PHASE3_BUCKETS_OFFSET + offset] = value;
}

//=====================================================================================================================
// Helpers for decoupled look back.
#define DLB_FLAG_NONE 0
#define DLB_FLAG_LOCAL_SUM 1
#define DLB_FLAG_DONE 2
#define DLB_FLAG_ALL 3
#define DLB_VALUE_MASK 0x3FFFFFFF

uint PackPartition(uint value, uint flag)
{
    return (flag << 30) | (value & DLB_VALUE_MASK);
}

uint UnpackValue(uint partition)
{
    return partition & DLB_VALUE_MASK;
}

uint UnpackFlag(uint partition)
{
    return partition >> 30;
}

//=====================================================================================================================
// Main Function Body
void InitOnesweepReorderImpl(
    uint globalId,
    uint numElements,
    uint lookBackOffset)
{
    const uint numberOfBlocks = RoundUpQuotient(numElements, RADIX_SORT_BLOCK_SIZE);

    if (globalId < numberOfBlocks * BIN_SIZE)
    {
        ScratchBuffer.Store<uint>(lookBackOffset + globalId * sizeof(uint), 0);
    }
}

uint16_t ScanExclusiveBlockHistogram(uint16_t prefix, uint start, uint localId, uint nElements)
{
    bool active = localId < nElements;
    uint idx = start + localId;
    uint16_t value = active ? GetLDSPhase1BlockHistogram(idx) : (uint16_t)0;
    uint16_t x = value;

    for (uint offset = 1; offset < nElements; offset <<= 1)
    {
        if (active && offset <= localId)
        {
            x += GetLDSPhase1BlockHistogram(idx - offset);
        }

        GroupMemoryBarrierWithGroupSync();

        if (active)
        {
            SetLDSPhase1BlockHistogram(idx, x);
        }

        GroupMemoryBarrierWithGroupSync();
    }

    uint16_t sum = GetLDSPhase1BlockHistogram(start + nElements - 1);

    GroupMemoryBarrierWithGroupSync();

    if (active)
    {
        SetLDSPhase1BlockHistogram(idx, x + prefix - value);
    }

    GroupMemoryBarrierWithGroupSync();

    return sum;
}

void OnesweepReorderImpl(
    uint localId,
    uint groupId,
    uint numElements,
    uint inputKeysOffset,
    uint outputKeysOffset,
    uint inputValuesOffset,
    uint outputValuesOffset,
    uint gpSumOffset,
    uint lookBackOffset,
    uint iteration)
{
    uint bitLocation = N_RADIX * iteration;
    uint numberOfBlocks = RoundUpQuotient(numElements, RADIX_SORT_BLOCK_SIZE);

    // Early termination
    // Handle mismatch between dispatched threads and active primitives caused by early pair compression. 
    // (Note: Can also be resolved via Indirect Dispatch)
    if(groupId >= numberOfBlocks) return;

    for (uint i = 0; i < BIN_SIZE * REORDER_NUMBER_OF_WARPS; i += REORDER_NUMBER_OF_THREADS_PER_BLOCK) {
        SetLDSPhase1LpSum(i + localId, (uint16_t)0);
    }

    GroupMemoryBarrierWithGroupSync();

    RADIX_SORT_KEY_TYPE keys[REORDER_NUMBER_OF_ITEMS_PER_THREAD];
    uint warpOffsets[REORDER_NUMBER_OF_ITEMS_PER_THREAD];

    uint warp = localId / WARP_SIZE;
    uint lane = localId % WARP_SIZE;

    for (uint i = 0, k = 0; i < REORDER_NUMBER_OF_ITEMS_PER_WARP; i += WARP_SIZE, k++)
    {
        uint itemIndex = groupId * RADIX_SORT_BLOCK_SIZE + warp * REORDER_NUMBER_OF_ITEMS_PER_WARP + i + lane;
        if (itemIndex < numElements)
        {
            keys[k] = ScratchBuffer.Load<RADIX_SORT_KEY_TYPE>(inputKeysOffset + itemIndex * sizeof(RADIX_SORT_KEY_TYPE));
        }
    }

    for (uint i = 0, k = 0; i < REORDER_NUMBER_OF_ITEMS_PER_WARP; i += WARP_SIZE, k++)
    {
        uint itemIndex = groupId * RADIX_SORT_BLOCK_SIZE + warp * REORDER_NUMBER_OF_ITEMS_PER_WARP + i + lane;
        uint bucketIndex = extractDigit(getKeyBits(keys[k]), bitLocation);
        uint64_t broThreads = WaveActiveBallot64(itemIndex < numElements);

        for (uint j = 0; j < N_RADIX; ++j)
        {
            uint64_t bit = (bucketIndex >> j) & 0x1;
            uint64_t difference = (0xFFFFFFFFFFFFFFFF * bit) ^ WaveActiveBallot64(bit != 0);
            broThreads &= ~difference;
        }

        uint64_t lowerMask = (1ull << lane) - 1;
        uint digitCount = (uint)GetLDSPhase1LpSum(bucketIndex * REORDER_NUMBER_OF_WARPS + warp);
        warpOffsets[k] = digitCount + countbits64(broThreads & lowerMask);

        GroupMemoryBarrierWithGroupSync();
        uint low = (uint)broThreads;
        uint high = (uint)(broThreads >> 32);
        uint leaderIdx = (low != 0) ? firstbitlow(low) : firstbitlow(high) + 32;
        if (lane == leaderIdx)
        {
            SetLDSPhase1LpSum(bucketIndex * REORDER_NUMBER_OF_WARPS + warp, (uint16_t)(digitCount + countbits64(broThreads)));
        }

        GroupMemoryBarrierWithGroupSync();
    }

    GroupMemoryBarrierWithGroupSync();

    for (uint bucketIndex = localId; bucketIndex < BIN_SIZE; bucketIndex += REORDER_NUMBER_OF_THREADS_PER_BLOCK)
    {
        uint s = 0;
        for (uint w = 0; w < REORDER_NUMBER_OF_WARPS; w++)
        {
            s += GetLDSPhase1LpSum(bucketIndex * REORDER_NUMBER_OF_WARPS + w);
        }
        SetLDSPhase1BlockHistogram(bucketIndex, (uint16_t)s);
    }

    GroupMemoryBarrierWithGroupSync();

    for (uint i = localId; i < BIN_SIZE; i += REORDER_NUMBER_OF_THREADS_PER_BLOCK)
    {
        uint s = GetLDSPhase1BlockHistogram(i);
        int pIndex = (BIN_SIZE * groupId + i);
        {
            uint partition = PackPartition(s, DLB_FLAG_LOCAL_SUM);
            ScratchBuffer.Store<uint>(lookBackOffset + pIndex * sizeof(uint), partition);
            DeviceMemoryBarrier();
        }

        uint gp = ScratchBuffer.Load<uint>(gpSumOffset + (iteration * BIN_SIZE + i) * sizeof(uint32_t));
        uint p = 0;

        for (int iBlock = (int)groupId - 1; 0 <= iBlock; iBlock--)
        {
            uint lookBackIndex = (BIN_SIZE * iBlock + i);
            uint partition;

            do {
                DeviceMemoryBarrier();
                partition = ScratchBuffer.Load<uint>(lookBackOffset + lookBackIndex * sizeof(uint));
            } while ((UnpackFlag(partition) & DLB_FLAG_ALL) == 0);

            p += UnpackValue(partition);

            if (UnpackFlag(partition) == DLB_FLAG_DONE)
            {
                break;
            }
        }

        uint partition = PackPartition(p + s, DLB_FLAG_DONE);
        ScratchBuffer.Store<uint>(lookBackOffset + pIndex * sizeof(uint), partition);
        DeviceMemoryBarrier();

        pSum[i] = gp + p;
    }

    GroupMemoryBarrierWithGroupSync();

    uint prefix = 0;
    for (uint i = 0; i < BIN_SIZE; i += REORDER_NUMBER_OF_THREADS_PER_BLOCK)
    {
        prefix += ScanExclusiveBlockHistogram((uint16_t)prefix, i, localId, min(REORDER_NUMBER_OF_THREADS_PER_BLOCK, BIN_SIZE));
    }

    for (uint bucketIndex = localId; bucketIndex < BIN_SIZE; bucketIndex += REORDER_NUMBER_OF_THREADS_PER_BLOCK)
    {
        uint s = GetLDSPhase1BlockHistogram(bucketIndex); 
        pSum[bucketIndex] -= s;

        for (uint w = 0; w < REORDER_NUMBER_OF_WARPS; w++)
        {
            int index = bucketIndex * REORDER_NUMBER_OF_WARPS + w;
            uint n = GetLDSPhase1LpSum(index);
            SetLDSPhase1LpSum(index, (uint16_t)s);
            s += n;
        }
    }

    GroupMemoryBarrierWithGroupSync();

    for (uint k = 0; k < REORDER_NUMBER_OF_ITEMS_PER_THREAD; k++)
    {
        uint bucketIndex = extractDigit(getKeyBits(keys[k]), bitLocation);
        warpOffsets[k] += GetLDSPhase1LpSum(bucketIndex * REORDER_NUMBER_OF_WARPS + warp);
    }

    GroupMemoryBarrierWithGroupSync();

    for (uint i = lane, k = 0; i < REORDER_NUMBER_OF_ITEMS_PER_WARP; i += WARP_SIZE, k++) // not 512, REORDER_NUMBER_OF_ITEM_PER_WARP originally
    {
        uint itemIndex = groupId * RADIX_SORT_BLOCK_SIZE + warp * REORDER_NUMBER_OF_ITEMS_PER_WARP + i;
        uint bucketIndex = extractDigit(getKeyBits(keys[k]), bitLocation);
        if (itemIndex < numElements)
        {
            SetLDSPhase2Element(warpOffsets[k], keys[k]);
        }
    }

    GroupMemoryBarrierWithGroupSync();

    for (uint i = localId; i < RADIX_SORT_BLOCK_SIZE; i += REORDER_NUMBER_OF_THREADS_PER_BLOCK)
    {
        uint itemIndex = groupId * RADIX_SORT_BLOCK_SIZE + i;
        if (itemIndex < numElements)
        {
            RADIX_SORT_KEY_TYPE item = GetLDSPhase2Element(i);
            uint bucketIndex = extractDigit(getKeyBits(item), bitLocation);

            uint dstIndex = pSum[bucketIndex] + i;
            ScratchBuffer.Store<RADIX_SORT_KEY_TYPE>(outputKeysOffset + dstIndex * sizeof(RADIX_SORT_KEY_TYPE), item);
        }
    }

    GroupMemoryBarrierWithGroupSync();

    for (uint i = lane, k = 0; i < REORDER_NUMBER_OF_ITEMS_PER_WARP; i += WARP_SIZE, k++)
    {
        uint itemIndex = groupId * RADIX_SORT_BLOCK_SIZE + warp * REORDER_NUMBER_OF_ITEMS_PER_WARP + i;
        uint bucketIndex = extractDigit(getKeyBits(keys[k]), bitLocation);
        if (itemIndex < numElements)
        {
            // Generate values for the first pass (initial primitive indices)
            if (iteration == 0)
            {
                SetLDSPhase3Element(warpOffsets[k], itemIndex);
            }
            else
            {
                SetLDSPhase3Element(warpOffsets[k], ScratchBuffer.Load<uint>(inputValuesOffset + itemIndex * sizeof(uint)));
            }
            SetLDSPhase3Bucket(warpOffsets[k], (uint16_t)bucketIndex);
        }
    }

    GroupMemoryBarrierWithGroupSync();

    for (uint i = localId; i < RADIX_SORT_BLOCK_SIZE; i += REORDER_NUMBER_OF_THREADS_PER_BLOCK)
    {
        uint itemIndex = groupId * RADIX_SORT_BLOCK_SIZE + i;
        if (itemIndex < numElements)
        {
            uint item = GetLDSPhase3Element(i);
            uint bucketIndex = GetLDSPhase3Bucket(i);

            uint dstIndex = pSum[bucketIndex] + i;
            ScratchBuffer.Store<uint>(outputValuesOffset + dstIndex * sizeof(uint), item);
        }
    }
}


#if NO_SHADER_ENTRYPOINT == 0
//=====================================================================================================================
// Main Function : InitOnesweepReorder
// The Kernel initializes look back buffer to zero.
// Number of threads should be look back buffer size (number of thread blocks in reorder kernel * number of bins).
//=====================================================================================================================
[RootSignature(RootSig)]
[numthreads(REORDER_NUMBER_OF_THREADS_PER_BLOCK, 1, 1)]
void InitOnesweepReorder(
    uint globalId: SV_DispatchThreadID)
{
    const uint numPrimitives = FetchTaskCounter(
        ShaderConstants.offsets.encodeTaskCounter + ENCODE_TASK_COUNTER_PRIM_REFS_OFFSET);
    const uint lookBackOffset = ShaderConstants.offsets.prefixSumAtomicFlags;

    InitOnesweepReorderImpl(globalId, numPrimitives, lookBackOffset);
}

//=====================================================================================================================
void SwapUint(
    inout uint x,
    inout uint y)
{
    const uint temp = x;
    x = y;
    y = temp;
}

//=====================================================================================================================
// Main Function : OnesweepReorder
//=====================================================================================================================

[RootSignature(RootSig)]
[numthreads(REORDER_NUMBER_OF_THREADS_PER_BLOCK, 1, 1)]
void OnesweepReorder(
    uint localId: SV_GroupThreadID,
    uint groupId: SV_GroupId)
{
    const uint numPrimitives = FetchTaskCounter(
        ShaderConstants.offsets.encodeTaskCounter + ENCODE_TASK_COUNTER_PRIM_REFS_OFFSET);

    const uint inputKeysOffset = ShaderConstants.offsets.mortonCodes;
    const uint outputKeysOffset = ShaderConstants.offsets.mortonCodesSorted;
    // Passing in 0 for initial primitive indices since we auto-generate them for the first pass
    const uint inputValuesOffset = 0;
    const uint outputValuesOffset = ShaderConstants.offsets.primIndicesSorted;

    const uint scratchKeysOffset = ShaderConstants.offsets.tempKeys;
    const uint scratchValuesOffset = ShaderConstants.offsets.tempVals;

    uint currentFromKeys = inputKeysOffset;
    uint currentFromVals = inputValuesOffset;
    uint currentToKeys = scratchKeysOffset;
    uint currentToVals = scratchValuesOffset;

    const uint iteration = ShaderRootConstants.PassIndex();
    if (iteration > 0)
    {
        currentFromKeys = outputKeysOffset;
        currentFromVals = outputValuesOffset;
    }

    if (iteration % 2 == 1)
    {
        SwapUint(currentFromKeys, currentToKeys);
        SwapUint(currentFromVals, currentToVals);
    }

    const uint gpSumOffset = ShaderConstants.offsets.histogram;
    const uint lookBackOffset = ShaderConstants.offsets.prefixSumAtomicFlags;

    OnesweepReorderImpl(localId,
                        groupId,
                        numPrimitives,
                        currentFromKeys,
                        currentToKeys,
                        currentFromVals,
                        currentToVals,
                        gpSumOffset,
                        lookBackOffset,
                        iteration);
}
#endif