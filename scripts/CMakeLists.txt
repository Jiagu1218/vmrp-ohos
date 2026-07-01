# OHOS prebuild entry: drives vmrp + Unicorn cross-compile to libvmrp.so.
# Invoked by build_libvmpp_ohos.bat with -S pointing here.
cmake_minimum_required(VERSION 3.18)

# Unicorn arm-softmmu is TCG software emulation of ARM32; it does NOT depend
# on host ARM32 hardware, so MRP ARM32 code runs on HarmonyOS ARM64.
set(UNICORN_ARCH "arm" CACHE STRING "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(UNICORN_BUILD_SAMPLES OFF CACHE BOOL "" FORCE)
set(UNICORN_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(UNICORN_INSTALL OFF CACHE BOOL "" FORCE)

# Build the shared library target (excludes main.c/e2e_control.c, no SDL).
set(VMRP_BUILD_SHARED ON CACHE BOOL "" FORCE)
set(VMRP_BUILD_SHARED_ONLY ON CACHE BOOL "" FORCE)

project(vmrp_ohos_wrapper C)

if(NOT DEFINED VMRP_SRC_DIR)
    message(FATAL_ERROR "VMRP_SRC_DIR must point to the vmrp source root")
endif()
get_filename_component(VMRP_SRC_DIR "${VMRP_SRC_DIR}" ABSOLUTE)
if(NOT EXISTS "${VMRP_SRC_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "VMRP_SRC_DIR does not look like vmrp source: ${VMRP_SRC_DIR}")
endif()

# --- Inject POSIX tools for Unicorn's qemu/configure on a Windows host ---
# vmrp already does this for Android (if(ANDROID_ABI)); OHOS sets
# CMAKE_SYSTEM_NAME=OHOS so that branch is skipped. Replicate the logic here.
# qemu/configure needs sh/rm/sed/expr/grep/uname/cut/tr.
if(CMAKE_HOST_WIN32)
    set(_OHOS_POSIX_BIN_HINTS)
    foreach(_d
            "$ENV{ProgramFiles}/Git/usr/bin"
            "$ENV{ProgramFiles}/Git/bin"
            "$ENV{ProgramW6432}/Git/usr/bin"
            "$ENV{ProgramW6432}/Git/bin"
            "$ENV{LOCALAPPDATA}/Programs/Git/usr/bin"
            "$ENV{LOCALAPPDATA}/Programs/Git/bin"
            "$ENV{SystemDrive}/msys64/usr/bin"
            "$ENV{SystemDrive}/msys64/bin")
        if(EXISTS "${_d}")
            list(APPEND _OHOS_POSIX_BIN_HINTS "${_d}")
        endif()
    endforeach()

    find_program(_OHOS_GIT_TOOL git)
    if(_OHOS_GIT_TOOL)
        get_filename_component(_git_dir "${_OHOS_GIT_TOOL}" DIRECTORY)
        get_filename_component(_git_root "${_git_dir}" DIRECTORY)
        if(EXISTS "${_git_root}/usr/bin")
            list(APPEND _OHOS_POSIX_BIN_HINTS "${_git_root}/usr/bin")
        endif()
    endif()

    find_program(_OHOS_POSIX_SH sh sh.exe HINTS ${_OHOS_POSIX_BIN_HINTS})
    if(NOT _OHOS_POSIX_SH)
        message(FATAL_ERROR
            "Unicorn's qemu/configure needs a POSIX sh on Windows. "
            "Install Git for Windows or MSYS2 and ensure sh.exe is reachable.")
    endif()
    get_filename_component(_sh_dir "${_OHOS_POSIX_SH}" DIRECTORY)
    file(TO_NATIVE_PATH "${_sh_dir}" _sh_dir_native)
    set(ENV{PATH} "${_sh_dir_native};$ENV{PATH}")
    message(STATUS "[OHOS] POSIX sh for Unicorn configure: ${_OHOS_POSIX_SH}")

    # qemu/configure also calls STRINGS and PKG_CONFIG.
    get_filename_component(_ndk_llvm_bin "${CMAKE_C_COMPILER}" DIRECTORY)
    find_program(_OHOS_STRINGS llvm-strings PATHS "${_ndk_llvm_bin}" NO_DEFAULT_PATH)
    if(NOT _OHOS_STRINGS)
        find_program(_OHOS_STRINGS strings HINTS ${_OHOS_POSIX_BIN_HINTS})
    endif()
    if(_OHOS_STRINGS)
        set(ENV{STRINGS} "${_OHOS_STRINGS}")
    endif()
    set(ENV{PKG_CONFIG} "true")
endif()

# --- Pre-detect host arch correctly and patch Unicorn's broken /dev/null probe ---
# Unicorn's CMakeLists.txt (line ~201) runs `${CC} -dM -E - INPUT_FILE /dev/null`
# to detect the HOST architecture for its TCG JIT backend. On a Windows host
# /dev/null does not exist, so UC_COMPILER_MACRO ends up empty and the arch
# detection fails ("Unknown host compiler"). We patch that line to feed an
# empty string instead of /dev/null, which works on every platform.
set(_UC_CML "${VMRP_SRC_DIR}/third_party/unicorn/CMakeLists.txt")
if(EXISTS "${_UC_CML}")
    file(READ "${_UC_CML}" _uc_cml_text)
    if(_uc_cml_text MATCHES "INPUT_FILE[ \t]+/dev/null")
        string(REPLACE "INPUT_FILE /dev/null"
                       "INPUT_FILE \"\""
                       _uc_cml_text "${_uc_cml_text}")
        file(WRITE "${_UC_CML}" "${_uc_cml_text}")
        message(STATUS "[OHOS] Patched Unicorn /dev/null probe (empty-string input)")
    endif()
endif()

# --- Fix cross-compile target detection in Unicorn's qemu/configure ---
# Unicorn's CMake invokes qemu/configure with  --cc=${CMAKE_C_COMPILER}  (the
# bare OHOS clang path, WITHOUT --target/--sysroot). configure's check_define
# __linux__ then runs the bare clang, which on a Windows host defaults to the
# x86_64-windows target, so __linux__ is NOT defined and configure wrongly
# falls back to targetos=MINGW32 (CONFIG_WIN32=y). That makes osdep.c skip
# <sys/mman.h> and compilation fails on MAP_FAILED/PROT_READ/etc.
#
# Fix: point --cc/--cxx at small sh wrappers that always prepend
# --target=aarch64-linux-ohos --sysroot=..., so check_define __linux__ succeeds
# and configure produces a Linux config (CONFIG_POSIX=y).
if(CMAKE_HOST_WIN32)
    # Where to place helper scripts.
    set(_OHOS_HELP_DIR "${CMAKE_BINARY_DIR}/ohos_helpers")
    file(MAKE_DIRECTORY "${_OHOS_HELP_DIR}")

    # Derive target triple + sysroot from the toolchain. ohos.toolchain.cmake
    # sets OHOS_ARCH (arm64-v8a / x86_64 / armeabi-v7a); map to clang target.
    if(NOT DEFINED OHOS_ARCH)
        set(OHOS_ARCH "arm64-v8a")
    endif()
    if(OHOS_ARCH STREQUAL "arm64-v8a")
        set(_OHOS_TARGET "aarch64-linux-ohos")
    elseif(OHOS_ARCH STREQUAL "x86_64")
        set(_OHOS_TARGET "x86_64-linux-ohos")
    elseif(OHOS_ARCH STREQUAL "armeabi-v7a")
        set(_OHOS_TARGET "arm-linux-ohos")
    else()
        set(_OHOS_TARGET "aarch64-linux-ohos")
    endif()
    set(_OHOS_SYSROOT "${OHOS_SDK_NATIVE}/sysroot")

    # Write POSIX sh wrappers so ANY invocation of the clang gets --target +
    # --sysroot prepended. This makes check_define __linux__ succeed.
    # NOTE: --gcc-toolchain is deliberately omitted: it is a linker option and
    # is unused (and warned about) during compile-only feature probes, and OHOS
    # clang's -Werror=unused-command-line-argument turns that into a hard error
    # that breaks configure's TLS/feature tests. --target + --sysroot suffice
    # for the configure-time compiler checks; real linkage uses CMake's flags.
    # --- sh wrapper for qemu/configure (executed via sh) ---
    set(_OHOS_CC_SHW "${_OHOS_HELP_DIR}/ohos-cc")
    set(_OHOS_CXX_SHW "${_OHOS_HELP_DIR}/ohos-cxx")
    file(WRITE "${_OHOS_CC_SHW}"
"#!/bin/sh\n"
"exec \"${OHOS_SDK_NATIVE}/llvm/bin/clang.exe\" --target=${_OHOS_TARGET} --sysroot=${_OHOS_SYSROOT} -Wno-error=unused-command-line-argument \"$@\"\n")
    file(WRITE "${_OHOS_CXX_SHW}"
"#!/bin/sh\n"
"exec \"${OHOS_SDK_NATIVE}/llvm/bin/clang++.exe\" --target=${_OHOS_TARGET} --sysroot=${_OHOS_SYSROOT} -Wno-error=unused-command-line-argument \"$@\"\n")

    # --- .bat wrapper for direct invocation (cmake execute_process etc.) ---
    set(_OHOS_CC_BAT "${_OHOS_HELP_DIR}/ohos-cc.bat")
    set(_OHOS_CXX_BAT "${_OHOS_HELP_DIR}/ohos-cxx.bat")
    file(TO_NATIVE_PATH "${OHOS_SDK_NATIVE}/llvm/bin/clang.exe" _OHOS_CLANG_NATIVE)
    file(TO_NATIVE_PATH "${OHOS_SDK_NATIVE}/llvm/bin/clang++.exe" _OHOS_CLANGXX_NATIVE)
    file(TO_NATIVE_PATH "${_OHOS_SYSROOT}" _OHOS_SYSROOT_NATIVE)
    file(WRITE "${_OHOS_CC_BAT}"
"@echo off\r\n"
"\"${_OHOS_CLANG_NATIVE}\" --target=${_OHOS_TARGET} --sysroot=\"${_OHOS_SYSROOT_NATIVE}\" -Wno-error=unused-command-line-argument %*\r\n")
    file(WRITE "${_OHOS_CXX_BAT}"
"@echo off\r\n"
"\"${_OHOS_CLANGXX_NATIVE}\" --target=${_OHOS_TARGET} --sysroot=\"${_OHOS_SYSROOT_NATIVE}\" -Wno-error=unused-command-line-argument %*\r\n")

    # Patch Unicorn's CMakeLists so qemu/configure is invoked with --cc pointing
    # at our sh wrapper instead of the bare clang. The wrapper forwards every arg
    # to the real clang with --target/--sysroot added.
    if(EXISTS "${_UC_CML}")
        file(READ "${_UC_CML}" _uc_cml_text2)
        string(FIND "${_uc_cml_text2}" "--cc=" _cc_pos)
        message(STATUS "[OHOS] Unicorn --cc needle at pos ${_cc_pos}; sh-wrapper=${_OHOS_CC_SHW}")
        # The source literally contains:  --cc=${CMAKE_C_COMPILER}
        # Match that exact substring (\${ => literal ${ in the CMake string).
        string(REPLACE "--cc=\${CMAKE_C_COMPILER}"
                       "--cc=${_OHOS_CC_SHW}"
                       _uc_cml_text2 "${_uc_cml_text2}")
        # Also handle previously-patched --cc paths (from a prior ABI).
        # --cc=<anything>/ohos-cc matches any existing wrapper path (x86_64, arm64, etc.)
        # but NOT ${CMAKE_C_COMPILER} (no /ohos-cc), so it's idempotent.
        string(REGEX REPLACE "--cc=[^ \t\r\n]+/ohos-cc"
                             "--cc=${_OHOS_CC_SHW}"
                             _uc_cml_text2 "${_uc_cml_text2}")
        # Also patch the execute_process macro detection to use the .bat wrapper,
        # otherwise the bare clang defaults to x86_64 on Windows host and
        # UNICORN_TARGET_ARCH is set to i386 instead of aarch64.
        string(ASCII 10 _NL)
        string(REPLACE
"        execute_process(COMMAND \${CMAKE_C_COMPILER} -dM -E -${_NL}            INPUT_FILE \"\""
"        execute_process(COMMAND ${_OHOS_CC_BAT} -dM -E -${_NL}            INPUT_FILE \"\""
          _uc_cml_text2 "${_uc_cml_text2}")
        file(WRITE "${_UC_CML}" "${_uc_cml_text2}")
        message(STATUS "[OHOS] Patched Unicorn --cc & macro detection to use target wrapper")
    endif()

    message(STATUS "[OHOS] sh wrapper for configure: ${_OHOS_CC_SHW}")
    message(STATUS "[OHOS] bat wrapper for execute_process: ${_OHOS_CC_BAT}")
endif()

# --- Patch vmrp native_dsm_funcs.c: MAP_32BIT is x86-glibc only, musl lacks it ---
# native_mem_get() uses mmap(... MAP_32BIT) on x86_64 to place the DSM memory in
# the low 32-bit range. OHOS uses musl libc which does NOT define MAP_32BIT, so
# x86_64 emulator builds fail to compile. Replace MAP_32BIT with 0 (plain anon
# mmap); the function already has a malloc() fallback, so correctness is intact
# and only the low-address hint is lost on x86_64. arm64 is unaffected (the
# block is already guarded by #ifdef __x86_64__).
set(_VMRP_DSM "${VMRP_SRC_DIR}/src/native_dsm_funcs.c")
if(EXISTS "${_VMRP_DSM}")
    file(READ "${_VMRP_DSM}" _dsm_text)
    # 只匹配未 patch 的原始代码（MAP_PRIVATE | MAP_ANONYMOUS | MAP_32BIT），
    # 替换注释里不含 MAP_32BIT 字样，保证幂等。
    if(_dsm_text MATCHES "MAP_ANONYMOUS \\| MAP_32BIT")
        string(REPLACE "MAP_ANONYMOUS | MAP_32BIT"
                       "MAP_ANONYMOUS /* x86-glibc only, musl lacks the 32bit flag */"
                       _dsm_text "${_dsm_text}")
        file(WRITE "${_VMRP_DSM}" "${_dsm_text}")
        message(STATUS "[OHOS] Patched MAP_32BIT in native_dsm_funcs.c")
    endif()
endif()

# --- Patch mythroad.c case 800: 修复 gblmt 等游戏传 ARM 地址给 arm_ext_load 的问题 ---
# gblmt 的 cfunction loader 把 ext 数据放在 ARM 内存（arm_alloc 地址，如 0x2C5C44），
# 然后用 ARM 地址调 case 800。但 case 800 的 arm_ext_load 把 input1 当 host 指针读取，
# 读到 host 进程 0x2C5C44 处的全0内存 → ext 入口全0 → 执行跳边界崩溃。
# 修复：检测 input1 是否为 ARM 地址（0x10000~0x1010000），若是则用 arm_ext_ptr 复制到 host。
set(_VMRP_Myth2 "${VMRP_SRC_DIR}/src/mythroad/mythroad.c")
if(EXISTS "${_VMRP_Myth2}")
    file(READ "${_VMRP_Myth2}" _mt2)
    if(NOT _mt2 MATCHES "OHOS_ARM_ADDR_FIX")
        string(REPLACE "ret = arm_ext_load(&native_ext, (const uint8*)input1, (uint32)len, code, &ext_r0);"
                       "/* OHOS_ARM_ADDR_FIX: gblmt 等 loader 把 ext 放在 ARM 内存并用 ARM 地址调\n             * case 800。用 old_ext 把 ARM 地址转成 host 指针，使 arm_ext_load 读到正确数据。 */\n            {\n                extern void* arm_ext_host_ptr(ArmExtModule *m, uint32_t addr);\n                uint32_t _a = (uint32_t)(uintptr_t)input1;\n                void* _hp = arm_ext_host_ptr(old_ext, _a);\n                if (_hp) input1 = (char*)_hp;\n            }\n            ret = arm_ext_load(&native_ext, (const uint8*)input1, (uint32)len, code, &ext_r0);"
                       _mt2 "${_mt2}")
        file(WRITE "${_VMRP_Myth2}" "${_mt2}")
        message(STATUS "[OHOS] Patched case 800 ARM address fix")
    endif()
endif()

# --- Patch arm_ext_executor.c: 加 arm_ext_host_ptr（ARM 地址→host 指针）---
# 供 mythroad.c case 800 修复使用：gblmt loader 用 ARM 地址调 arm_ext_load，
# 需把 ARM 地址转成 host 指针。arm_ext_executor.c 有完整 ArmExtModule 定义。
set(_VMRP_ARMEXT2 "${VMRP_SRC_DIR}/src/arm_ext_executor.c")
if(EXISTS "${_VMRP_ARMEXT2}")
    file(READ "${_VMRP_ARMEXT2}" _aet2)
    if(NOT _aet2 MATCHES "arm_ext_host_ptr")
        string(PREPEND _aet2
"/* OHOS: ARM 地址转 host 指针（供 case 800 修复）。arm_ext_internal.h 有完整定义。 */\n"
"#include \"./include/arm_ext_internal.h\"\n"
"void* arm_ext_host_ptr(ArmExtModule *m, uint32_t addr) {\n"
"    if (!m || !m->mem) return NULL;\n"
"    if (addr < 0x10000u || addr >= 0x1010000u) return NULL;\n"
"    return (void*)((uint8_t*)m->mem + (addr - 0x10000u));\n"
"}\n")
        file(WRITE "${_VMRP_ARMEXT2}" "${_aet2}")
        message(STATUS "[OHOS] Patched arm_ext_host_ptr")
    endif()
endif()

add_subdirectory("${VMRP_SRC_DIR}" "${CMAKE_BINARY_DIR}/vmrp")




