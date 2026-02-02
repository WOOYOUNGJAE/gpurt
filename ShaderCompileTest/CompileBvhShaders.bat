@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

set "CONFIG_FILE=config.txt"

if not exist "%CONFIG_FILE%" (
    echo [ERROR] %CONFIG_FILE% 파일을 찾을 수 없습니다.
    pause
    exit /b
)

echo [INFO] 설정을 불러오는 중...

REM =================================================================================
REM 1. 설정값 읽기 (DXC_PATH, SRC_DIR, OUT_DIR)
REM =================================================================================
for /f "usebackq tokens=*" %%L in ("%CONFIG_FILE%") do (
    set "LINE=%%L"
    if not "!LINE!"=="" if /i not "!LINE:~0,3!"=="REM" (
        echo !LINE! | findstr /b /i "DXC_PATH SRC_DIR OUT_DIR" >nul
        if !errorlevel! equ 0 (
            for /f "tokens=1* delims==" %%A in ("!LINE!") do (
                set "KEY=%%A"
                set "VAL=%%B"
                set "KEY=!KEY: =!"
                if /i "!KEY!"=="DXC_PATH" ( for %%I in ("!VAL!") do set "DXC_PATH=%%~fI" )
                if /i "!KEY!"=="SRC_DIR"  ( for %%I in ("!VAL!") do set "SRC_DIR=%%~fI" )
                if /i "!KEY!"=="OUT_DIR"  ( for %%I in ("!VAL!") do set "OUT_DIR=%%~fI" )
            )
        )
    )
)

if not exist "%DXC_PATH%" ( echo [ERROR] DXC를 찾을 수 없습니다: %DXC_PATH% & pause & exit /b )
if not exist "%SRC_DIR%" ( echo [ERROR] 소스 폴더를 찾을 수 없습니다: %SRC_DIR% & pause & exit /b )
if not defined OUT_DIR ( set "OUT_DIR=.\output" )
if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"

echo   - DXC   : %DXC_PATH%
echo   - SOURCE: %SRC_DIR%
echo   - OUTPUT: %OUT_DIR%

REM =================================================================================
REM 2. 공통 컴파일 옵션
REM =================================================================================
set "FLAGS=-spirv -fspv-target-env="vulkan1.1" -Vd -O3 -fcgl -fvk-use-scalar-layout"
set "WARNINGS=-Wall -Wextra -Wno-ignored-attributes -Wno-unused-variable -Wno-unused-function -Wno-unused-parameter -Wno-sometimes-uninitialized -Wno-conversion"
set "TYPES=-enable-16bit-types -T cs_6_2 -HV 2021"
set "COMMON_DEFINES=-DAMD_VULKAN -DAMD_VULKAN_DXC -DAMD_VULKAN_SPV -DGPURT_BVH_BUILD_SHADER=1 -DGPURT_BUILD_RTIP3=1 -DNOMINMAX -DWIN32_LEAN_AND_MEAN -DGPURT_BUILD_RTIP3_1=1 -DGPURT_DEVELOPER=1 -DGPURT_CLIENT_API_VULKAN=1 -DGPURT_BUILD_CONTINUATION=1 -DGPURT_CLIENT_INTERFACE_MAJOR_VERSION=56 -DPAL_CLIENT_INTERFACE_MAJOR_VERSION=924 -DLLPC_CLIENT_INTERFACE_MAJOR_VERSION=76 -DLITTLEENDIAN_CPU -DLLPC_BUILD_HAWK_POINT1=1 -DLLPC_BUILD_HAWK_POINT2=1 -DLLPC_BUILD_STRIX1=1 -DLLPC_BUILD_STRIX_HALO=1 -DLLPC_BUILD_NAVI48=1 -DUSE_HW_INTRINSIC=1 -DGPURT_RTIP_LEVEL=0 -DGPURT_RTIP_LEGACY_LEVEL=30"
set "INCLUDES=-I "%SRC_DIR%" -I "%~dp0.""

echo.
echo [INFO] 컴파일 시작...

REM =================================================================================
REM 3. 셰이더 목록 순환 컴파일
REM =================================================================================
for /f "usebackq tokens=*" %%L in ("%CONFIG_FILE%") do (
    set "LINE=%%L"
    if not "!LINE!"=="" if /i not "!LINE:~0,3!"=="REM" (

        set "IS_CONFIG=0"
        echo !LINE! | findstr /b /i "DXC_PATH SRC_DIR OUT_DIR" >nul
        if !errorlevel! equ 0 set "IS_CONFIG=1"

        if "!IS_CONFIG!"=="0" (

            for /f "tokens=1*" %%A in ("!LINE!") do (
                set "RAW_NAME=%%A"
                set "EXTRA_DEFS=%%B"

                REM ===== [추가된 부분 시작] =====
                REM RAW_NAME = BuildParallel:BuildBvh
                REM FNAME    = BuildParallel
                REM ENTRY    = BuildBvh
                echo !RAW_NAME! | find ":" >nul
                if errorlevel 1 (
                    set "FNAME=!RAW_NAME!"
                    set "ENTRY=!RAW_NAME!"
                ) else (
                    for /f "tokens=1,2 delims=:" %%S in ("!RAW_NAME!") do (
                        set "FNAME=%%S"
                        set "ENTRY=%%T"
                    )
                )
                REM ===== [추가된 부분 끝] =====

                set "ADD_D="
                if not "!EXTRA_DEFS!"=="" (
                    set "ADD_D=-D !EXTRA_DEFS: = -D !"
                )

                echo --------------------------------------------------------
                echo [Compiling] !FNAME!.hlsl (entry: !ENTRY!)
                if not "!EXTRA_DEFS!"=="" echo [Defines] !EXTRA_DEFS!

                "%DXC_PATH%" %FLAGS% %INCLUDES% %WARNINGS% %TYPES% %COMMON_DEFINES% !ADD_D! ^
                    -E !ENTRY! "%SRC_DIR%\!FNAME!.hlsl" ^
                    -Fo "%OUT_DIR%\!FNAME!.spv"

                if !errorlevel! neq 0 (
                    echo [ERROR] !FNAME! 컴파일 실패
                ) else (
                    echo [SUCCESS] !FNAME!.spv 생성 완료
                )
            )
        )
    )
)

echo.
echo ========================================================
echo 모든 작업이 완료되었습니다.
echo ========================================================
pause
