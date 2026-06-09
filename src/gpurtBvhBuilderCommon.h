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
#pragma once

#include <cstdint>

#if GPURT_DEVELOPER
#if defined(__GNUC__)
#define RGP_PUSH_MARKER(format, ...) PushRGPMarker(format, ##__VA_ARGS__)
#else
#define RGP_PUSH_MARKER(format, ...) PushRGPMarker(format, __VA_ARGS__)
#endif
#define RGP_POP_MARKER() PopRGPMarker()
#else
#define RGP_PUSH_MARKER(format, ...) (static_cast<void>(0))
#define RGP_POP_MARKER() (static_cast<void>(0))
#endif
namespace GpuRt
{

enum class BuildPhaseFlags : uint32_t
{
    Rebraid                       = 1 << 0,
    // Unused1                    = 1 << 1,
    EncodeHwBvh                   = 1 << 2,
    GenerateMortonCodes           = 1 << 3,
    MergeSort                     = 1 << 4,
    RadixSort                     = 1 << 5,
    // Unused6                    = 1 << 6,
    BuildPLOC                     = 1 << 7,
    BuildFusedCollapsingWideBvh   = 1 << 8,
    PairCompression               = 1 << 9,
#if GPURT_BUILD_RTIP3_1
    CompressPrims                 = 1 << 10,
    RefitOrientedBounds           = 1 << 11,
#endif
    SeparateEmitPostBuildInfoPass = 1 << 12,
    BuildParallel                 = 1 << 13,
    BuildFastAgglomerativeLbvh    = 1 << 15,
    EncodeQuadPrimitives          = 1 << 16,
    BuildHPLOC                    = 1 << 17,
    EncodePrimitives              = 1 << 18,
    BuildDumpEvents               = 1 << 19,
#if GPURT_BUILD_RTIP3_1
    RefitInstanceBounds           = 1 << 21,
#endif
};

enum class DetailedBuildPhaseFlags : uint64_t
{
    Rebraid                       = 1LLU << 0,
    // Unused1                    = 1LLU << 1,
    EncodeHwBvh                   = 1LLU << 2,
    GenerateMortonCodes           = 1LLU << 3,
    MergeSort                     = 1LLU << 4,
    RadixSort                     = 1LLU << 5,
    // Unused6                    = 1LLU << 6,
    BuildPLOC                     = 1LLU << 7,
    BuildFusedCollapsingWideBvh   = 1LLU << 8,
    PairCompression               = 1LLU << 9,
#if GPURT_BUILD_RTIP3_1
    CompressPrims                 = 1LLU << 10,
    RefitOrientedBounds           = 1LLU << 11,
#endif
    SeparateEmitPostBuildInfoPass = 1LLU << 12,
    BuildParallel                 = 1LLU << 13,
    BuildFastAgglomerativeLbvh    = 1LLU << 15,
    EncodeQuadPrimitives          = 1LLU << 16,
    BuildHPLOC                    = 1LLU << 17,
    EncodePrimitives              = 1LLU << 18,
    BuildDumpEvents               = 1LLU << 19,
#if GPURT_BUILD_RTIP3_1
    RefitInstanceBounds           = 1LLU << 21,
#endif
    // Detailed Phases Below
    EncodeInstances               = 1LLU << 22,
    MergeSortLocal                = 1LLU << 23,
    MergeSortGlobalIteration      = 1LLU << 24,
    MergeSortCopyLastLevel        = 1LLU << 25,
    UpdateQBVH                    = 1LLU << 26,
    UpdateParallel                = 1LLU << 27,
    EncodeUpdate                  = 1LLU << 28,
    BitHistogram                  = 1LLU << 29,
    ScatterKeysAndValues          = 1LLU << 30,
#if GPURT_BUILD_RTIP3_1
    BuildTrivialBvh               = 1LLU << 31,
#endif
    ScanExclusiveAddOneLevel      = 1LLU << 32,
    ScanExclusiveAddPartial       = 1LLU << 33,
    ScanExclusiveDistributeSums   = 1LLU << 34,
    ScanExclusiveAddDLB           = 1LLU << 35,
    ScanExclusiveAddDLBInit       = 1LLU << 36,
    ScanExclusiveAddDLBScan       = 1LLU << 37,
};

constexpr size_t MaxBuildPhaseNameLength = 256;

static const char* BuildPhaseName(BuildPhaseFlags phase)
{
    switch (phase)
    {
    case GpuRt::BuildPhaseFlags::Rebraid:
        return "Rebraid";
    case GpuRt::BuildPhaseFlags::EncodeHwBvh:
        return "EncodeHwBvh";
    case GpuRt::BuildPhaseFlags::GenerateMortonCodes:
        return "GenerateMortonCodes";
    case GpuRt::BuildPhaseFlags::MergeSort:
        return "MergeSort";
    case GpuRt::BuildPhaseFlags::RadixSort:
        return "RadixSort";
    case GpuRt::BuildPhaseFlags::BuildPLOC:
        return "BuildPLOC";
    case GpuRt::BuildPhaseFlags::BuildFusedCollapsingWideBvh:
        return "BuildFusedCollapsingWideBvh";
    case GpuRt::BuildPhaseFlags::PairCompression:
        return "PairCompression";
#if GPURT_BUILD_RTIP3_1
    case GpuRt::BuildPhaseFlags::CompressPrims:
        return "CompressPrims";
    case GpuRt::BuildPhaseFlags::RefitOrientedBounds:
        return "RefitOrientedBounds";
#endif
    case GpuRt::BuildPhaseFlags::SeparateEmitPostBuildInfoPass:
        return "SeparateEmitPostBuildInfoPass";
    case GpuRt::BuildPhaseFlags::BuildParallel:
        return "BuildParallel";
    case GpuRt::BuildPhaseFlags::BuildFastAgglomerativeLbvh:
        return "BuildFastAgglomerativeLbvh";
    case GpuRt::BuildPhaseFlags::EncodeQuadPrimitives:
        return "EncodeQuadPrimitives";
    case GpuRt::BuildPhaseFlags::BuildHPLOC:
        return "BuildHPLOC";
    case GpuRt::BuildPhaseFlags::EncodePrimitives:
        return "EncodePrimitives";
    case GpuRt::BuildPhaseFlags::BuildDumpEvents:
        return "BuildDumpEvents";
    }
    return "";
}

static const char* DetailedBuildPhaseName(DetailedBuildPhaseFlags phase)
{
    switch (phase)
    {
    case GpuRt::DetailedBuildPhaseFlags::Rebraid:
        return "Rebraid";
    case GpuRt::DetailedBuildPhaseFlags::EncodeHwBvh:
        return "EncodeHwBvh";
    case GpuRt::DetailedBuildPhaseFlags::GenerateMortonCodes:
        return "GenerateMortonCodes";
    case GpuRt::DetailedBuildPhaseFlags::MergeSort:
        return "MergeSort";
    case GpuRt::DetailedBuildPhaseFlags::RadixSort:
        return "RadixSort";
    case GpuRt::DetailedBuildPhaseFlags::BuildPLOC:
        return "BuildPLOC";
    case GpuRt::DetailedBuildPhaseFlags::BuildFusedCollapsingWideBvh:
        return "BuildFusedCollapsingWideBvh";
    case GpuRt::DetailedBuildPhaseFlags::PairCompression:
        return "PairCompression";
#if GPURT_BUILD_RTIP3_1
    case GpuRt::DetailedBuildPhaseFlags::CompressPrims:
        return "CompressPrims";
    case GpuRt::DetailedBuildPhaseFlags::RefitOrientedBounds:
        return "RefitOrientedBounds";
#endif
    case GpuRt::DetailedBuildPhaseFlags::SeparateEmitPostBuildInfoPass:
        return "SeparateEmitPostBuildInfoPass";
    case GpuRt::DetailedBuildPhaseFlags::BuildParallel:
        return "BuildParallel";
    case GpuRt::DetailedBuildPhaseFlags::BuildFastAgglomerativeLbvh:
        return "BuildFastAgglomerativeLbvh";
    case GpuRt::DetailedBuildPhaseFlags::EncodeQuadPrimitives:
        return "EncodeQuadPrimitives";
    case GpuRt::DetailedBuildPhaseFlags::BuildHPLOC:
        return "BuildHPLOC";
    case GpuRt::DetailedBuildPhaseFlags::EncodePrimitives:
        return "EncodePrimitives";
    case GpuRt::DetailedBuildPhaseFlags::BuildDumpEvents:
        return "BuildDumpEvents";
    case GpuRt::DetailedBuildPhaseFlags::EncodeInstances:
        return "EncodeInstances";
    case GpuRt::DetailedBuildPhaseFlags::MergeSortLocal:
        return "MergeSortLocal";
    case GpuRt::DetailedBuildPhaseFlags::MergeSortGlobalIteration:
        return "MergeSortGlobalIteration";
    case GpuRt::DetailedBuildPhaseFlags::MergeSortCopyLastLevel:
        return "MergeSortCopyLastLevel";
    case GpuRt::DetailedBuildPhaseFlags::UpdateQBVH:
        return "UpdateQBVH";
    case GpuRt::DetailedBuildPhaseFlags::UpdateParallel:
        return "UpdateParallel";
    case GpuRt::DetailedBuildPhaseFlags::EncodeUpdate:
        return "EncodeUpdate";
    case GpuRt::DetailedBuildPhaseFlags::BitHistogram:
        return "BitHistogram";
    case GpuRt::DetailedBuildPhaseFlags::ScatterKeysAndValues:
        return "ScatterKeysAndValues";
#if GPURT_BUILD_RTIP3_1
    case GpuRt::DetailedBuildPhaseFlags::BuildTrivialBvh:
        return "BuildTrivialBvh";
#endif
    case GpuRt::DetailedBuildPhaseFlags::ScanExclusiveAddOneLevel:
        return "ScanExclusiveAddOneLevel";
    case GpuRt::DetailedBuildPhaseFlags::ScanExclusiveAddPartial:
        return "ScanExclusiveAddPartial";
    case GpuRt::DetailedBuildPhaseFlags::ScanExclusiveDistributeSums:
        return "ScanExclusiveDistributeSums";
    case GpuRt::DetailedBuildPhaseFlags::ScanExclusiveAddDLB:
        return "ScanExclusiveAddDLB";
    case GpuRt::DetailedBuildPhaseFlags::ScanExclusiveAddDLBInit:
        return "ScanExclusiveAddDLBInit";
    case GpuRt::DetailedBuildPhaseFlags::ScanExclusiveAddDLBScan:
        return "ScanExclusiveAddDLBScan";
    }
    return "";
}


constexpr BuildPhaseFlags& operator|=(BuildPhaseFlags& a, BuildPhaseFlags b) noexcept
{
    a = static_cast<BuildPhaseFlags>(static_cast<uint32_t>(a) | static_cast<uint32_t>(b));
    return a;
}

} // namespace GpuRt
