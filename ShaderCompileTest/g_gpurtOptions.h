/* Copyright (c) 2026 Advanced Micro Devices, Inc. All rights reserved. */
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//
// WARNING!  WARNING!  WARNING!  WARNING!  WARNING!  WARNING!  WARNING!  WARNING!  WARNING!  WARNING!  WARNING!
//
// This code has been generated automatically. Do not hand-modify this code.
//
// When changes are needed, modify the tools generating this module in the tools directory OR
// the options.yaml file.
//
// WARNING!  WARNING!  WARNING!  WARNING!  WARNING!  WARNING!  WARNING! WARNING!  WARNING!  WARNING!  WARNING!
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// Auto-generated tables for options.

#ifndef _GPURT_GENERATED_OPTIONS_H
#define _GPURT_GENERATED_OPTIONS_H

#ifdef __cplusplus
namespace GpuRt
{
#endif

typedef uint32_t uint32;

#define DUMMY_OPTION_FUNC(value) { return value; }

#ifdef __cplusplus
#define GPURT_OPTION_DECL extern
#else // __cplusplus
#define GPURT_OPTION_DECL [noinline]
#endif

// Controls how candidate primitives are handled in the continuations (CPS) software Traversal loop.
enum class CpsCandidatePrimitiveMode : uint32
{
    // Suspend a lane upon candidate hits and wait for other lanes to end the Traversal loop.
    // This is the default. Other modes are experimental and might not be implemented on all RtIps.
    SuspendLane = 0x55210FD1,
    // When finding the first candidate, record it and ignore it for the time being. At the end of the
    // Traversal loop, process pending candidates. When finding the second candidate, immediately break
    // out of the loop to first process the first one.
    // Implementation status:
    // * RtIp 1.1: Not supported, SuspendLane is always used.
    // * RtIp 2.0: DeferFirst is supported, but only for triangle primitives.
    // if GPURT_BUILD_RTIP3_1
    // * RtIp 3.1: DeferFirst is fully supported.
    // endif
    // ------------------------------------------------------------------------------------------------------------------
    // This is the definition of the single options struct.
    // An option is represented by a sequence entry whose name is the name of the option, and it is itself
    // a sequence with entries:
    // - Type: the type of the field.
    // - Default (optional): the default value of the field.
    DeferFirst = 0xF89889EF,
};

constexpr uint32 ThreadTraceEnabledOptionNameHash = 2695640079;
constexpr uint32 ThreadTraceEnabledOptionDefault = 0;
GPURT_OPTION_DECL uint32 _AmdGetSetting_2695640079() DUMMY_OPTION_FUNC(0)
constexpr uint32 DynamicVgprsEnabledOptionNameHash = 1010531845;
constexpr uint32 DynamicVgprsEnabledOptionDefault = ~0u;
GPURT_OPTION_DECL uint32 _AmdGetSetting_1010531845() DUMMY_OPTION_FUNC(~0u)
constexpr uint32 CpsCandidatePrimitiveModeOptionNameHash = 213143806;
constexpr CpsCandidatePrimitiveMode CpsCandidatePrimitiveModeOptionDefault = CpsCandidatePrimitiveMode::SuspendLane;
GPURT_OPTION_DECL CpsCandidatePrimitiveMode _AmdGetSetting_213143806() DUMMY_OPTION_FUNC(CpsCandidatePrimitiveMode::SuspendLane)
constexpr uint32 PersistentLaunchEnabledOptionNameHash = 2294258792;
constexpr uint32 PersistentLaunchEnabledOptionDefault = 0;
GPURT_OPTION_DECL uint32 _AmdGetSetting_2294258792() DUMMY_OPTION_FUNC(0)
constexpr uint32 RayFlagsOverrideForceEnableMaskOptionNameHash = 2669256054;
constexpr uint32 RayFlagsOverrideForceEnableMaskOptionDefault = 0;
GPURT_OPTION_DECL uint32 _AmdGetSetting_2669256054() DUMMY_OPTION_FUNC(0)
constexpr uint32 RayFlagsOverrideForceDisableMaskOptionNameHash = 4111448703;
constexpr uint32 RayFlagsOverrideForceDisableMaskOptionDefault = 0;
GPURT_OPTION_DECL uint32 _AmdGetSetting_4111448703() DUMMY_OPTION_FUNC(0)
constexpr uint32 RtDispatchRaysThreadGroupSizeOptionNameHash = 1986654042;
constexpr uint32 RtDispatchRaysThreadGroupSizeOptionDefault = 32;
GPURT_OPTION_DECL uint32 _AmdGetSetting_1986654042() DUMMY_OPTION_FUNC(32)

#ifdef __cplusplus
struct Option {
  uint32 nameHash;
  uint64_t value;
};

constexpr Option OptionDefaults[] = {
    { ThreadTraceEnabledOptionNameHash, static_cast<uint64_t>(ThreadTraceEnabledOptionDefault) },
    { DynamicVgprsEnabledOptionNameHash, static_cast<uint64_t>(DynamicVgprsEnabledOptionDefault) },
    { CpsCandidatePrimitiveModeOptionNameHash, static_cast<uint64_t>(CpsCandidatePrimitiveModeOptionDefault) },
    { PersistentLaunchEnabledOptionNameHash, static_cast<uint64_t>(PersistentLaunchEnabledOptionDefault) },
    { RayFlagsOverrideForceEnableMaskOptionNameHash, static_cast<uint64_t>(RayFlagsOverrideForceEnableMaskOptionDefault) },
    { RayFlagsOverrideForceDisableMaskOptionNameHash, static_cast<uint64_t>(RayFlagsOverrideForceDisableMaskOptionDefault) },
    { RtDispatchRaysThreadGroupSizeOptionNameHash, static_cast<uint64_t>(RtDispatchRaysThreadGroupSizeOptionDefault) },

};
#endif


class Options
{
    static uint32 getThreadTraceEnabled() { return _AmdGetSetting_2695640079(); }
    // Whether dynamic Vgprs are enabled in a continuations-compiled shader.
    // Has no meaning in non-continuations shaders.
    // This option is owned by pipeline compilers.
    static uint32 getDynamicVgprsEnabled() { return _AmdGetSetting_1010531845(); }
    static CpsCandidatePrimitiveMode getCpsCandidatePrimitiveMode() { return _AmdGetSetting_213143806(); }
    static uint32 getPersistentLaunchEnabled() { return _AmdGetSetting_2294258792(); }
    // The incoming TraceRay ray flags are ORed with this mask before use, allowing to force-enable specific flags.
    // In case of conflicting bits with the disable mask, the enable mask wins, as it is applied after the disable mask.
    // Only supported with continuations.
    static uint32 getRayFlagsOverrideForceEnableMask() { return _AmdGetSetting_2669256054(); }
    // The incoming TraceRay ray flags are ANDed with the bitwise inverse of this mask before use, allowing to force-disable specific flags.
    // Only supported with continuations.
    static uint32 getRayFlagsOverrideForceDisableMask() { return _AmdGetSetting_4111448703(); }
    // Thread Group size to use when calling DispatchRays
    static uint32 getRtDispatchRaysThreadGroupSize() { return _AmdGetSetting_1986654042(); }

};

#ifdef __cplusplus
} // namespace GpuRt
#endif

#endif
