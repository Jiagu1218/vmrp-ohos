@echo off
REM ===========================================================================
REM  build_libvmpp_ohos.bat [abi]  OR  build_libvmpp_ohos.bat [vmrp_src] [abi]
REM  Prebuild libvmrp.so for the HarmonyOS entry module.
REM
REM  Args:
REM    abi       - arm64-v8a (default, for real devices) or x86_64 (emulator)
REM    vmrp_src  - vmrp source root (default: internal ..\vmrp).
REM                Only pass this explicitly to override; the internal copy
REM                is the project's source of truth.
REM
REM  Output: entry\src\main\cpp\prebuilt\<abi>\libvmrp.so
REM          entry\libs\<abi>\libvmrp.so  (for HAP packaging)
REM
REM  How it works:
REM    - Cross-compile with OHOS NDK ohos.toolchain.cmake
REM    - scripts\CMakeLists.txt drives vmrp's vmrp-shared target
REM      (excludes main.c/e2e_control.c, no VMRP_SDL_AUDIO -> no SDL)
REM    - Unicorn arm-softmmu is TCG software emulation of ARM32; it does NOT
REM      need host ARM32 hardware, so MRP ARM32 code runs on any OHOS ABI.
REM    - The wrapper injects POSIX sh/sed/rm into PATH on a Windows host to
REM      satisfy unicorn's qemu/configure shell dependency
REM ===========================================================================
setlocal enabledelayedexpansion

REM Smart arg parsing: support both `bat <abi>` and `bat <vmrp_src> <abi>`.
REM The internal vmrp/ (sibling of this script's parent) is the source of
REM truth and the default; only an explicit non-ABI first arg overrides it.
set "ABI=arm64-v8a"
set "VMRP_SRC=%~dp0..\vmrp"
if not "%~1"=="" (
    if /I "%~1"=="arm64-v8a" (
        set "ABI=%~1"
    ) else if /I "%~1"=="x86_64" (
        set "ABI=%~1"
    ) else (
        set "VMRP_SRC=%~1"
        if not "%~2"=="" set "ABI=%~2"
    )
)

REM Resolve to absolute path.
pushd "%VMRP_SRC%" 2>nul
if errorlevel 1 (
    echo [ERROR] vmrp source path not found: %VMRP_SRC%
    exit /b 1
)
set "VMRP_SRC=%CD%"
popd

REM --- Locate OHOS NDK ---
if not defined OHOS_SDK_NATIVE (
    if exist "%ProgramFiles%\Huawei\DevEco Studio\sdk\default\openharmony\native" (
        set "OHOS_SDK_NATIVE=%ProgramFiles%\Huawei\DevEco Studio\sdk\default\openharmony\native"
    )
)
if not exist "%OHOS_SDK_NATIVE%\build\cmake\ohos.toolchain.cmake" (
    echo [ERROR] OHOS NDK not found. Set OHOS_SDK_NATIVE to the native SDK dir.
    exit /b 1
)

REM Space-less junction so Unicorn's unquoted --cc=path works.
set "OHOS_NDK_NOSPACE=C:\ohos_ndk"
if not exist "%OHOS_NDK_NOSPACE%\build\cmake\ohos.toolchain.cmake" (
    mklink /J "%OHOS_NDK_NOSPACE%" "%OHOS_SDK_NATIVE%" >nul 2>&1
)
if not exist "%OHOS_NDK_NOSPACE%\build\cmake\ohos.toolchain.cmake" (
    echo [ERROR] Failed to create space-less junction %OHOS_NDK_NOSPACE%
    exit /b 1
)
set "OHOS_SDK_NATIVE=%OHOS_NDK_NOSPACE%"

set "TOOLCHAIN=%OHOS_SDK_NATIVE%\build\cmake\ohos.toolchain.cmake"
set "NDK_CMAKE=%OHOS_SDK_NATIVE%\build-tools\cmake\bin\cmake.exe"
set "NDK_NINJA=%OHOS_SDK_NATIVE%\build-tools\cmake\bin\ninja.exe"
if not exist "%NDK_CMAKE%" set "NDK_CMAKE=cmake"
if not exist "%NDK_NINJA%" (
    echo [ERROR] ninja.exe not found in NDK: %NDK_NINJA%
    exit /b 1
)

set "WRAPPER_DIR=%~dp0."
set "BUILD_DIR=%~dp0..\build-libvmrp-%ABI%"
set "PREBUILT_DIR=%~dp0..\entry\src\main\cpp\prebuilt\%ABI%"
set "LIBS_DIR=%~dp0..\entry\libs\%ABI%"

echo [INFO] ABI              : %ABI%
echo [INFO] OHOS SDK NATIVE  : %OHOS_SDK_NATIVE%
echo [INFO] vmrp source      : %VMRP_SRC%
echo [INFO] build dir        : %BUILD_DIR%

REM --- Init vmrp's unicorn submodule (Unicorn engine source) ---
if not exist "%VMRP_SRC%\third_party\unicorn\CMakeLists.txt" (
    echo [INFO] Initializing unicorn submodule...
    pushd "%VMRP_SRC%"
    git submodule update --init --recursive --depth 1
    popd
)

REM --- Restore patched source files pristine before re-patching ---
REM scripts/CMakeLists.txt patches several files in place during configure;
REM restore all of them to their committed state so no previous residue leaks in.
call :restore_patched

REM --- Configure ---
echo.
echo === Configure ===
"%NDK_CMAKE%" -G Ninja ^
    -DCMAKE_TOOLCHAIN_FILE="%TOOLCHAIN%" ^
    -DOHOS_ARCH=%ABI% ^
    -DOHOS_PLATFORM_LEVEL=26 ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DCMAKE_MAKE_PROGRAM="%NDK_NINJA%" ^
    -DVMRP_SRC_DIR="%VMRP_SRC%" ^
    -S "%WRAPPER_DIR%" ^
    -B "%BUILD_DIR%"
if errorlevel 1 (
    echo [ERROR] CMake configure failed.
    exit /b 1
)

REM --- Build ---
echo.
echo === Build vmrp-shared ===
"%NDK_CMAKE%" --build "%BUILD_DIR%" --target vmrp-shared -j
if errorlevel 1 (
    echo [ERROR] Build failed.
    exit /b 1
)

REM --- Copy products ---
echo.
echo === Install ===
if not exist "%PREBUILT_DIR%" mkdir "%PREBUILT_DIR%"
if not exist "%LIBS_DIR%" mkdir "%LIBS_DIR%"

set "SO_FOUND=0"
if exist "%BUILD_DIR%\libvmrp.so" (
    copy /Y "%BUILD_DIR%\libvmrp.so" "%PREBUILT_DIR%\libvmrp.so" >nul
    copy /Y "%BUILD_DIR%\libvmrp.so" "%LIBS_DIR%\libvmrp.so" >nul
    set "SO_FOUND=1"
)
if "!SO_FOUND!"=="0" if exist "%BUILD_DIR%\vmrp\libvmrp.so" (
    copy /Y "%BUILD_DIR%\vmrp\libvmrp.so" "%PREBUILT_DIR%\libvmrp.so" >nul
    copy /Y "%BUILD_DIR%\vmrp\libvmrp.so" "%LIBS_DIR%\libvmrp.so" >nul
    set "SO_FOUND=1"
)
if "!SO_FOUND!"=="0" (
    echo [ERROR] libvmrp.so not found in %BUILD_DIR%
    exit /b 1
)

REM --- Restore patched sources so the working tree stays clean after a build ---
REM Only on the success path; on failure we leave the patched files in place.
call :restore_patched

echo.
echo [OK] libvmrp.so (%ABI%) built and copied to:
echo     %PREBUILT_DIR%\libvmrp.so
echo     %LIBS_DIR%\libvmrp.so
endlocal
goto :eof

REM ===========================================================================
REM  :restore_patched
REM  Restore the source files that scripts/CMakeLists.txt patches in place
REM  back to their committed (pristine) state. Tolerant: each checkout is
REM  allowed to be a no-op (file clean or git-untracked) via 2>nul.
REM  NOTE: discards uncommitted/unstaged edits to these files only, which by
REM  convention are temporary build-time patches; permanent edits should be
REM  committed. Files NOT patched by the script (e.g. mythroad_mini.c) are
REM  untouched.
REM ===========================================================================
:restore_patched
pushd "%VMRP_SRC%" >nul 2>&1
if errorlevel 1 exit /b 0
git checkout -- third_party\unicorn\CMakeLists.txt >nul 2>&1
git checkout -- src\include\arm_ext_internal.h          >nul 2>&1
git checkout -- src\native_dsm_funcs.c            >nul 2>&1
git checkout -- src\mythroad\mythroad.c           >nul 2>&1
git checkout -- src\mythroad\dsm.c                >nul 2>&1
git checkout -- src\arm_ext_executor.c            >nul 2>&1
git checkout -- src\vmrp_api.c                    >nul 2>&1
git checkout -- src\network.c                     >nul 2>&1
git checkout -- src\arm_ext\aex_exec.c            >nul 2>&1
git checkout -- src\arm_ext\aex_table.c           >nul 2>&1
git checkout -- src\arm_ext\aex_mem.c             >nul 2>&1
popd
exit /b 0
