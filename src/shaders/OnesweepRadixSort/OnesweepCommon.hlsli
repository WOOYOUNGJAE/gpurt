
#ifndef _ONESWEEP_COMMON_HLSLI
#define _ONESWEEP_COMMON_HLSLI

// =====================================================================================================================
// Configs
// Note: These configurations should be managed with gpurtInternal.h::GetOnesweepRadixSortConfig().
#define N_RADIX (8)
#define BIN_SIZE (1 << N_RADIX)
#define RADIX_MASK ((1 << N_RADIX) - 1)

#if USE_MORTON_CODE_30
    typedef uint RADIX_SORT_KEY_TYPE;
#else // USE_MORTON_CODE_60
    typedef uint64_t RADIX_SORT_KEY_TYPE;
#endif // end of USE_MORTON_CODE_30
typedef uint RADIX_SORT_VALUE_TYPE;
#define N_ITERATION (sizeof(RADIX_SORT_KEY_TYPE) * 8 / N_RADIX)

#define WARP_SIZE (64)

#define GHISTOGRAM_ITEMS_PER_BLOCK (2048)
#define GHISTOGRAM_THREADS_PER_BLOCK (256)
#define GHISTOGRAM_ITEMS_PER_THREAD (GHISTOGRAM_ITEMS_PER_BLOCK / GHISTOGRAM_THREADS_PER_BLOCK)

#define RADIX_SORT_BLOCK_SIZE (4096)

#define REORDER_NUMBER_OF_THREADS_PER_BLOCK (256)
#define REORDER_NUMBER_OF_WARPS (REORDER_NUMBER_OF_THREADS_PER_BLOCK / WARP_SIZE)
#define REORDER_NUMBER_OF_ITEMS_PER_WARP (RADIX_SORT_BLOCK_SIZE / REORDER_NUMBER_OF_WARPS)
#define REORDER_NUMBER_OF_ITEMS_PER_THREAD (REORDER_NUMBER_OF_ITEMS_PER_WARP / WARP_SIZE)

// =====================================================================================================================
// Helpers
#if DESCENDING_ORDER
#define ORDER_MASK_32 (0xFFFFFFFF)
#define ORDER_MASK_64 (0xFFFFFFFFFFFFFFFFllu)
#else
#define ORDER_MASK_32 (0u)
#define ORDER_MASK_64 (0llu)
#endif

inline uint getKeyBits(uint x)
{
    return x ^ ORDER_MASK_32;
}

inline uint64_t getKeyBits(uint64_t x)
{ 
    return x ^ ORDER_MASK_64;
}

inline uint extractDigit(uint x, uint bitLocation)
{
    return (x >> bitLocation) & RADIX_MASK;
}

inline uint extractDigit(uint64_t x, uint bitLocation) 
{ 
    return (uint) ((x >> bitLocation) & (uint64_t) RADIX_MASK);
}

#endif //_ONESWEEP_COMMON_HLSLI