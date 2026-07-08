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

    # --- Logical refs written into Unicorn's CMakeLists.txt ---
    # Inject a *literal* ${CMAKE_BINARY_DIR}/... (backslash escapes $) so the
    # patch resolves per build dir and never leaks an absolute path. Real paths
    # above (_OHOS_CC_SHW/_OHOS_CC_BAT) are only used to create wrappers here.
    set(_OHOS_CC_REF    "\${CMAKE_BINARY_DIR}/ohos_helpers/ohos-cc")
    set(_OHOS_CCBAT_REF "\${CMAKE_BINARY_DIR}/ohos_helpers/ohos-cc.bat")

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
                       "--cc=${_OHOS_CC_REF}"
                       _uc_cml_text2 "${_uc_cml_text2}")
        # Also handle previously-patched --cc paths (from a prior ABI). Matches
        # any residue (older absolute path or ${CMAKE_BINARY_DIR}/... token).
        string(REGEX REPLACE "--cc=[^ \t\r\n]+/ohos-cc"
                             "--cc=${_OHOS_CC_REF}"
                             _uc_cml_text2 "${_uc_cml_text2}")
        # Also patch the execute_process macro detection to use the .bat wrapper,
        # otherwise the bare clang defaults to x86_64 on Windows host and
        # UNICORN_TARGET_ARCH is set to i386 instead of aarch64.
        string(ASCII 10 _NL)
        string(REPLACE
"        execute_process(COMMAND \${CMAKE_C_COMPILER} -dM -E -${_NL}            INPUT_FILE \"\""
"        execute_process(COMMAND ${_OHOS_CCBAT_REF} -dM -E -${_NL}            INPUT_FILE \"\""
          _uc_cml_text2 "${_uc_cml_text2}")
        # REGEX fallback mirroring the --cc fallback: rewrite any stale wrapper
        # path so UNICORN_TARGET_ARCH detection isn't left on the previous ABI.
        string(REGEX REPLACE "execute_process\\(COMMAND [^ \t\r\n]+/ohos-cc\\.bat"
                             "execute_process(COMMAND ${_OHOS_CCBAT_REF}"
                             _uc_cml_text2 "${_uc_cml_text2}")
        file(WRITE "${_UC_CML}" "${_uc_cml_text2}")
        message(STATUS "[OHOS] Patched Unicorn --cc & macro detection to use target wrapper")
    endif()

    message(STATUS "[OHOS] sh wrapper for configure: ${_OHOS_CC_SHW}")
    message(STATUS "[OHOS] bat wrapper for execute_process: ${_OHOS_CC_BAT}")
endif()

# --- Normalize line endings: Git core.autocrlf=true on Windows produces CRLF,
# but CMake string(REPLACE) patterns use \n (LF). Without normalization,
# multi-line patterns never match and patches silently fail (file is written
# back unchanged, but "Patched" message still prints due to idempotent check
# seeing the marker is absent). Fix: strip \r before any patching.
function(ohos_crlf_to_lf FILEPATH)
    if(EXISTS "${FILEPATH}")
        file(READ "${FILEPATH}" _raw)
        string(REPLACE "\r\n" "\n" _fixed "${_raw}")
        if(NOT _raw STREQUAL _fixed)
            file(WRITE "${FILEPATH}" "${_fixed}")
            message(STATUS "[OHOS] Normalized CRLF->LF: ${FILEPATH}")
        endif()
    endif()
endfunction()
ohos_crlf_to_lf("${VMRP_SRC_DIR}/src/arm_ext_executor.c")
ohos_crlf_to_lf("${VMRP_SRC_DIR}/src/mythroad/mythroad.c")
ohos_crlf_to_lf("${VMRP_SRC_DIR}/src/vmrp_api.c")
ohos_crlf_to_lf("${VMRP_SRC_DIR}/src/network.c")
ohos_crlf_to_lf("${VMRP_SRC_DIR}/src/native_dsm_funcs.c")

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

# --- Patch arm_ext_executor.c: T_MOTION_ACC 缓冲区 + arm_ext_write_motion_acc ---
# 在 Unicorn 虚拟内存中分配 12 字节给三轴加速度数据(x/y/z int32)，
# 并导出 arm_ext_write_motion_acc() 供 mythroad.c 将宿主缓存的加速度
# 写入 ARM 可见地址。MRP 应用的 dealevent 通过 mr_event param2 读取
# 该地址，在 Unicorn 模拟环境中 ARM 代码只能访问 32 位虚拟地址，
# 不能解引用宿主 64 位 &motion_acc 指针（截断后 SIGBUS）。
#
# 分两步：
# 1) 在 table[91] 分配后插入 motion_acc_addr = arm_alloc(m, 12)
# 2) 在文件末尾（arm_ext_unload 之前）追加 arm_ext_write_motion_acc 函数
set(_VMRP_ARMEXT3 "${VMRP_SRC_DIR}/src/arm_ext_executor.c")
if(EXISTS "${_VMRP_ARMEXT3}")
    file(READ "${_VMRP_ARMEXT3}" _aet3)
    if(NOT _aet3 MATCHES "arm_ext_write_motion_acc")
        # Step 1: 在 write_table_entry(m, 91, ...) 之后分配 motion_acc_addr
        string(REPLACE
            "    write_table_entry(m, 91, alloc_u32_slot(m, m->screen_addr));\n"
            "    write_table_entry(m, 91, alloc_u32_slot(m, m->screen_addr));\n    /* OHOS_MOTION_ACC: T_MOTION_ACC 缓冲区（12 字节: 3×int32 x/y/z）。\n     * ARM 代码通过 mr_event(MR_MOTION_EVENT, mode, addr) param2 读取。\n     * 必须在 Unicorn 虚拟内存中分配，ARM 无法访问宿主 64 位地址。 */\n    m->motion_acc_addr = arm_alloc(m, 12);\n"
            _aet3 "${_aet3}")
        # Step 2: 在 arm_ext_unload 之前追加 arm_ext_write_motion_acc
        string(REPLACE
            "void arm_ext_unload(ArmExtModule *m) {"
            "/* OHOS_MOTION_ACC: 将三轴加速度(mG)写入 Unicorn 虚拟内存中的 T_MOTION_ACC 缓冲区，\n * 返回 ARM 可见的 32 位地址；MRP 代码通过 mr_event param2 读取该地址。\n * 必须在 worker 线程（与 Unicorn 串行）调用。 */\nuint32_t arm_ext_write_motion_acc(ArmExtModule *m, int32 x, int32 y, int32 z) {\n    if (!m || !m->motion_acc_addr) return 0;\n    int32 data[3] = {x, y, z};\n    void *dst = arm_ptr(m, m->motion_acc_addr);\n    if (!dst) return 0;\n    memcpy(dst, data, sizeof(data));\n    return m->motion_acc_addr;\n}\n\nvoid arm_ext_unload(ArmExtModule *m) {"
            _aet3 "${_aet3}")
        file(WRITE "${_VMRP_ARMEXT3}" "${_aet3}")
        message(STATUS "[OHOS] Patched arm_ext_write_motion_acc + motion_acc_addr allocation")
    endif()
endif()

# --- Patch mythroad.c: dsm_write_motion_acc_to_arm ---
# 桥接函数：从 dsm.c 读取缓存的加速度数据，调用 arm_ext_write_motion_acc
# 写入 Unicorn 内存，返回 ARM 可见 32 位地址。dsm_dispatch_motion_event()
# 用此地址作为 mr_event param2，替代截断的宿主 64 位 &motion_acc。
set(_VMRP_MOTION "${VMRP_SRC_DIR}/src/mythroad/mythroad.c")
if(EXISTS "${_VMRP_MOTION}")
    file(READ "${_VMRP_MOTION}" _motion)
    if(NOT _motion MATCHES "OHOS_MOTION_ACC_BRIDGE")
        string(REPLACE
            "int32 mr_event(int16 type, int32 param1, int32 param2) {"
            "/* OHOS_MOTION_ACC_BRIDGE: 将 DSM 层缓存的加速度数据写入 Unicorn ARM 内存，\n * 返回 ARM 可见的 32 位地址作为 mr_event param2 使用。\n * 在 Unicorn 模拟环境中，ARM 代码只能通过 32 位虚拟地址\n * 访问 T_MOTION_ACC，不能解引用宿主 64 位指针。 */\nextern void dsm_get_motion_acc(int32 *x, int32 *y, int32 *z);\nuint32 dsm_write_motion_acc_to_arm(void) {\n    if (!native_ext) return 0;\n    int32 x = 0, y = 0, z = 0;\n    dsm_get_motion_acc(&x, &y, &z);\n    return arm_ext_write_motion_acc(native_ext, x, y, z);\n}\n\nint32 mr_event(int16 type, int32 param1, int32 param2) {"
            _motion "${_motion}")
        file(WRITE "${_VMRP_MOTION}" "${_motion}")
        message(STATUS "[OHOS] Patched dsm_write_motion_acc_to_arm bridge")
    endif()
endif()

# --- Patch mythroad.c: dofile 后显式调用 _mr_entry 入口（恢复 b82dd68 修复）---
# 恢复 b82dd68 的修复（上游升级 d367585 时丢失）。幂等标记 OHOS_ENTRY_CALL。
set(_VMRP_MRENTRY "${VMRP_SRC_DIR}/src/mythroad/mythroad.c")
if(EXISTS "${_VMRP_MRENTRY}")
    file(READ "${_VMRP_MRENTRY}" _mrentry)
    if(NOT _mrentry MATCHES "OHOS_ENTRY_CALL")
        set(_MRENTRY_ANCHOR "    MRDBGPRINTF(\"After app init, memory left:%d\", LG_mem_left);")
        set(_MRENTRY_BLOCK
"    /* OHOS_ENTRY_CALL: dofile 后显式调用 _mr_entry 指向的入口函数（如 _dsm）。 */\n"
"    mrp_getglobal(vm_state, \"_mr_entry\");\n"
"    if (mrp_isstring(vm_state, -1)) {\n"
"        const char *entry_name = mrp_tostring(vm_state, -1);\n"
"        if (entry_name && *entry_name) {\n"
"            mrp_getglobal(vm_state, entry_name);\n"
"            if (mrp_isfunction(vm_state, -1)) {\n"
"                fprintf(stderr, \"[_mr_intra_start] calling entry '%s'\\n\", entry_name); fflush(stderr);\n"
"                _mr_pcall(0, 0);\n"
"                mrp_pop(vm_state, 1);\n"
"            } else {\n"
"                mrp_pop(vm_state, 1);\n"
"            }\n"
"        }\n"
"    }\n"
"    mrp_pop(vm_state, 1);\n"
"\n")
        string(FIND "${_mrentry}" "${_MRENTRY_ANCHOR}" _anchor_pos)
        if(_anchor_pos EQUAL -1)
            message(FATAL_ERROR "[OHOS] _mr_entry patch anchor not found in mythroad.c")
        endif()
        string(REPLACE "${_MRENTRY_ANCHOR}" "${_MRENTRY_BLOCK}${_MRENTRY_ANCHOR}" _mrentry "${_mrentry}")
        file(WRITE "${_VMRP_MRENTRY}" "${_mrentry}")
        message(STATUS "[OHOS] Patched _mr_entry call after dofile (gblmt start fix)")
    endif()
endif()

# --- Patch network.c: 阻塞式 connect() 加超时，避免断网卡死 worker 线程 ---
# my_connectSync() 用阻塞 connect() 无超时。async worker 模型下网络调用跑在
# worker 线程，宿主机断网时（模拟器内路由仍在，SYN 被静默丢弃，不像桌面拔网线
# 会快速返回 ENETUNREACH）connect 会卡在 SYN 重传上数十秒~分钟级，卡死整个
# worker（mr_timer 停摆 -> 游戏卡死无法操作）。
# 修复：用「设非阻塞 -> connect -> select 等可写(3s 超时) -> 恢复阻塞 -> SO_ERROR」
# 模式，超时则返回失败，让游戏继续运行。仅改 POSIX 路径。
# 超时取 3s：gblmt 连国内云服务器正常 RTT 数十 ms，3s 足够覆盖网络抖动，断网时
# 3s 后失败，体验可接受（远好于卡死数十秒）。
# 为避免在 CMake 字符串里嵌入大段 C 代码的转义问题，新函数体写到生成文件，
# 原函数替换为 #include 引用。
set(_VMRP_NET "${VMRP_SRC_DIR}/src/network.c")
if(EXISTS "${_VMRP_NET}")
    file(READ "${_VMRP_NET}" _net_text)
    if(NOT _net_text MATCHES "OHOS_CONNECT_TIMEOUT")
        # 1) 加 fcntl.h include（POSIX 路径需要）
        if(NOT _net_text MATCHES "#include <fcntl.h>")
            string(REPLACE "#include <pthread.h>" "#include <pthread.h>\n#include <fcntl.h>" _net_text "${_net_text}")
        endif()
        # 2) 生成新的 my_connectSync 函数体到 build 目录
        set(_NET_INC "${CMAKE_BINARY_DIR}/ohos_connect_timeout.inc")
        file(WRITE "${_NET_INC}"
"/* OHOS_CONNECT_TIMEOUT: generated by scripts/CMakeLists.txt */\n"
"static int32 my_connectSync(SOCKET_T s, int32 ip, uint16 port) {\n"
"    struct sockaddr_in clientService;\n"
"    clientService.sin_family = AF_INET;\n"
"    clientService.sin_port = htons(port);\n"
"    clientService.sin_addr.s_addr = htonl(ip);\n"
"    printf(\"my_connect('%s', %d)\\n\", inet_ntoa(clientService.sin_addr), port);\n"
"#ifndef _MSC_VER\n"
"    int flags = fcntl(s, F_GETFL, 0);\n"
"    if (flags < 0) { printf(\"my_connect fcntl get fail\\n\"); return MR_FAILED; }\n"
"    if (fcntl(s, F_SETFL, flags | O_NONBLOCK) < 0) { printf(\"my_connect fcntl set fail\\n\"); return MR_FAILED; }\n"
"    int cret = connect(s, (struct sockaddr*)&clientService, sizeof(clientService));\n"
"    if (cret == 0) { fcntl(s, F_SETFL, flags); printf(\"my_connect(0x%X) suc\\n\", ip); return MR_SUCCESS; }\n"
"    if (errno != EINPROGRESS) { fcntl(s, F_SETFL, flags); printf(\"my_connect(0x%X) fail errno=%d\\n\", ip, errno); return MR_FAILED; }\n"
"    fd_set writefds; FD_ZERO(&writefds); FD_SET(s, &writefds);\n"
"    struct timeval cto = { .tv_sec = 3, .tv_usec = 0 };\n"
"    int sret = select(s + 1, NULL, &writefds, NULL, &cto);\n"
"    fcntl(s, F_SETFL, flags);\n"
"    if (sret <= 0) { printf(\"my_connect(0x%X) timeout/fail\\n\", ip); return MR_FAILED; }\n"
"    int soerr = 0; socklen_t sl = sizeof(soerr);\n"
"    if (getsockopt(s, SOL_SOCKET, SO_ERROR, &soerr, &sl) < 0 || soerr != 0) { printf(\"my_connect(0x%X) soerr=%d\\n\", ip, soerr); return MR_FAILED; }\n"
"    printf(\"my_connect(0x%X) suc\\n\", ip);\n"
"    return MR_SUCCESS;\n"
"#else\n"
"    if (connect(s, (struct sockaddr*)&clientService, sizeof(clientService)) != 0) { printf(\"my_connect(0x%X) fail\\n\", ip); return MR_FAILED; }\n"
"    printf(\"my_connect(0x%X) suc\\n\", ip);\n"
"    return MR_SUCCESS;\n"
"#endif\n"
"}\n")
        # 3) 把原函数体替换为 #include 引用（绝对路径，避免相对路径找不到）。
        string(REGEX REPLACE
"static int32 my_connectSync\\(SOCKET_T s, int32 ip, uint16 port\\) \\{[^}]*\\{[^}]*\\}[^}]*\\}"
"#include \"${_NET_INC}\""
            _net_text "${_net_text}")
        file(WRITE "${_VMRP_NET}" "${_net_text}")
        message(STATUS "[OHOS] Patched my_connectSync -> 3s timeout (via ${_NET_INC})")
    endif()
endif()

# --- Patch arm_ext_executor.c: arm_alloc 64 位边界检查 + case38 memset 越界守卫 ---
# 崩溃现场(cppcrash SIGSEGV SEGV_ACCERR@0x5cf5052000):arm_alloc 返回 0xA45E38,
# want=0xA27B9C(~10.6MB),m->mem 仅 16MB,memset 从 offset 0xA35E38 写 0xA27B9C
# 字节,结尾 0x146D9D4 越过 16MB(0x1000000)踩出缓冲 → SIGSEGV。
# arm_alloc 的 uint32 边界检查 heap_top+len>=mem_end 理论上应拦截,但崩溃
# 显示 heap_top 被损坏(转储=0x00333638 而非预期值),导致检查通过并返回越界地址。
# 修复:
# 1) arm_alloc 改用 uint64 算术做边界检查,即使 heap_top 被篡改为异常小值,
#    大额 len 也不会因 uint32 溢出而通过检查。
# 2) case 38 memset 前加二次越界守卫:a-EXT_BASE_ADDR+want ≤ EXT_MEM_SIZE,
#    即使 arm_alloc 逻辑被绕过(如 heap_top 损坏),也能阻止 memset 踩出缓冲。
set(_VMRP_ARMEXT4 "${VMRP_SRC_DIR}/src/arm_ext_executor.c")
if(EXISTS "${_VMRP_ARMEXT4}")
    file(READ "${_VMRP_ARMEXT4}" _aet4)
    if(NOT _aet4 MATCHES "OHOS_ARM_ALLOC_U64")
        # Patch 1: arm_alloc 保留区跨越判断改用 64 位算术
        string(REPLACE
            "    if (m->heap_top < reserved_hi && m->heap_top + len > reserved_lo) {"
            "    /* OHOS_ARM_ALLOC_U64: 用 64 位算术做保留区跨越判断,防止 uint32 溢出\n     * 导致 heap_top+len 回绕为小值误判为未跨越(崩溃转储 heap_top=0x00333638,\n     * want=0xA27B9C,加法溢出跳过保留区,arm_alloc 返回越界地址)。 */\n    if (m->heap_top < reserved_hi && (uint64_t)m->heap_top + (uint64_t)len > (uint64_t)reserved_lo) {"
            _aet4 "${_aet4}")
        # Patch 2: arm_alloc 边界检查改用 64 位算术
        string(REPLACE
            "    if (m->heap_top + len >= mem_end) return 0;"
            "    /* OHOS_ARM_ALLOC_U64: 64 位算术边界检查,heap_top+len 溢出 uint32\n     * 时仍能正确判定越界(0x00333638+0xA27B9C=0xD5B1D4<mem_end 通过检查,\n     * 但分配地址 0xA45E38+0xA27B9C=0x146D9D4>16MB,memset 越界)。 */\n    if ((uint64_t)m->heap_top + (uint64_t)len >= (uint64_t)mem_end) return 0;"
            _aet4 "${_aet4}")
        file(WRITE "${_VMRP_ARMEXT4}" "${_aet4}")
        message(STATUS "[OHOS] Patched arm_alloc 64-bit boundary checks (OHOS_ARM_ALLOC_U64)")
    endif()
    # Re-read for second patch (file was just written above, or already has OHOS_ARM_ALLOC_U64)
    file(READ "${_VMRP_ARMEXT4}" _aet4b)
    if(NOT _aet4b MATCHES "OHOS_MEMSET_BOUNDS_GUARD")
        # Patch 3: case 38 memset 前加二次越界守卫
        string(REPLACE
            "                            void *ep = arm_ptr(m, a);\n                            if (ep) memset(ep, 0, want);"
            "                            void *ep = arm_ptr(m, a);\n                            /* OHOS_MEMSET_BOUNDS_GUARD: 二次越界守卫,即使 arm_alloc\n                             * 的 64 位检查被绕过(如 heap_top 损坏),也阻止 memset\n                             * 踩出 m->mem 16MB 缓冲。a-EXT_BASE_ADDR+want 必须\n                             * ≤ EXT_MEM_SIZE,否则跳过 memset(与 ep==NULL 同义)。 */\n                            if (ep && (uint64_t)(a - EXT_BASE_ADDR) + (uint64_t)want <= (uint64_t)EXT_MEM_SIZE) {\n                                memset(ep, 0, want);\n                            }"
            _aet4b "${_aet4b}")
        file(WRITE "${_VMRP_ARMEXT4}" "${_aet4b}")
        message(STATUS "[OHOS] Patched case 38 memset bounds guard (OHOS_MEMSET_BOUNDS_GUARD)")
    endif()
    # Re-read for third patch (case 14 memset NULL guard)
    file(READ "${_VMRP_ARMEXT4}" _aet4c)
    if(NOT _aet4c MATCHES "OHOS_MEMSET_NULL_GUARD")
        # Patch 4: case 14 memset/memcpy NULL 指针守卫
        # cppcrash 转储: SIGSEGV(SEGV_MAPERR)@0x0, x0=NULL, x2=4
        # 调用栈: memset+52 ← case 14 ← helper_uc_tracecode ← guest ARM
        # 根因: guest 代码调用 table[14](memset2) 传入无效 ARM 地址,
        # arm_ptr 返回 NULL, memset(0x0, 0, 4) 触发 NULL 解引用。
        # GOT 修复中的 memcpy(arm_ptr(m, addr), ...) 也有同样风险。
        # 修复: case 14 开头解析 arm_ptr(m, r0), 若为 NULL 则跳过 memset
        # 和 GOT 修复,只设 ret=r0 (与真机行为一致:无效地址返回原值,不清零)。
        string(REPLACE
            "        case 14:
            memset(arm_ptr(m, r0), (int)r1, r2);
            /* memset 后修复 GOT 中的 bridge 指针 */
            if (m->got_snapshot_base) {
                uint32_t got_base = m->got_snapshot_base;
                uint32_t set_end = r0 + r2;
                for (uint32_t i = 0; i < EXT_TABLE_COUNT; i++) {
                    uint32_t addr = got_base + i * 4;
                    if (m->got_snapshot[i] >= EXT_TABLE_ADDR &&
                        m->got_snapshot[i] < EXT_TABLE_ADDR + EXT_TABLE_COUNT * 4 &&
                        addr >= r0 && addr + 4 <= set_end &&
                        !arm_ext_should_skip_got_snapshot_restore(m, addr) &&
                        !app_should_protect_got_addr(m, addr)) {
                        memcpy(arm_ptr(m, addr), &m->got_snapshot[i], 4);
                    }
                }
            }
            ret = r0; break;"
            "        case 14: {
            /* OHOS_MEMSET_NULL_GUARD: case 14 (table[14]=memset2) 的
             * arm_ptr(m, r0) 可能返回 NULL(guest 传入无效 ARM 地址),
             * 直接 memset(NULL,...) 触发 SIGSEGV。先解析指针,为 NULL
             * 则跳过 memset 和 GOT 修复。cppcrash: x0=0, x2=4。 */
            void *_c14_dst = arm_ptr(m, r0);
            if (_c14_dst) {
                memset(_c14_dst, (int)r1, r2);
                /* memset 后修复 GOT 中的 bridge 指针 */
                if (m->got_snapshot_base) {
                    uint32_t got_base = m->got_snapshot_base;
                    uint32_t set_end = r0 + r2;
                    for (uint32_t i = 0; i < EXT_TABLE_COUNT; i++) {
                        uint32_t addr = got_base + i * 4;
                        if (m->got_snapshot[i] >= EXT_TABLE_ADDR &&
                            m->got_snapshot[i] < EXT_TABLE_ADDR + EXT_TABLE_COUNT * 4 &&
                            addr >= r0 && addr + 4 <= set_end &&
                            !arm_ext_should_skip_got_snapshot_restore(m, addr) &&
                            !app_should_protect_got_addr(m, addr)) {
                            void *_got_slot = arm_ptr(m, addr);
                            if (_got_slot) memcpy(_got_slot, &m->got_snapshot[i], 4);
                        }
                    }
                }
            }
            ret = r0; } break;"
            _aet4c "${_aet4c}")
        file(WRITE "${_VMRP_ARMEXT4}" "${_aet4c}")
        message(STATUS "[OHOS] Patched case 14 memset NULL guard (OHOS_MEMSET_NULL_GUARD)")
    endif()
endif()

# --- Patch arm_ext_executor.c: case 120 DrawBitmap NULL 指针防护 ---
# 已被上游 17c152f 的 arm_ext_draw_bitmap_from_guest() 替代:
# 上游对 case 120 改用 arm_ext_draw_bitmap_from_guest(m, r0, ...),内部逐像素
# 校验源地址范围(含 app_live_blocks 边界),跳过越界像素,远超我们简单的 NULL guard。
# 此 patch 块保留为注释,不做任何替换(锚点文本也已不存在)。
# set(_VMRP_ARMEXT5 "${VMRP_SRC_DIR}/src/arm_ext_executor.c")
# if(EXISTS "${_VMRP_ARMEXT5}")
#     file(READ "${_VMRP_ARMEXT5}" _aet5)
#     if(NOT _aet5 MATCHES "OHOS_DRAWBITMAP_NULL_GUARD")
#         ... (removed, superseded by upstream)
#     endif()
# endif()

# --- Patch arm_ext_executor.c: UC_MEM_READ/WRITE_UNMAPPED 优雅恢复 ---
# 花屏+卡死根因: guest ARM 代码用被位图像素覆写的 mr_bitmapSt 指针
# (0xF81FF81F,RGB565 白色像素模式)做内存访问,触发 UC_MEM_READ_UNMAPPED。
# hook_invalid 返回 false → uc_emu_start 报错 UC_ERR_READ_UNMAPPED →
# run_arm_with_sp 无恢复路径 → 返回 MR_FAILED → timer 回调每次都失败 →
# 游戏逻辑永久停摆 → 画面卡死。
# 修复: hook_invalid 对 READ/WRITE_UNMAPPED 打印诊断后设 PC=EXT_STOP_ADDR
# 并返回 true,让 uc_emu_start 正常结束;同时 run_arm_with_sp 把
# UC_ERR_READ_UNMAPPED/WRITE_UNMAPPED 视为干净退出(MR_SUCCESS),因为
# 损坏的 ARM 指针不应杀死整个模拟器,timer 下次触发时游戏可能已恢复。
set(_VMRP_ARMEXT6 "${VMRP_SRC_DIR}/src/arm_ext_executor.c")
if(EXISTS "${_VMRP_ARMEXT6}")
    file(READ "${_VMRP_ARMEXT6}" _aet6)
    if(NOT _aet6 MATCHES "OHOS_UNMAPPED_GRACEFUL_EXIT")
        # Patch 1: hook_invalid — READ/WRITE_UNMAPPED 设 PC=STOP, 返回 true
        string(REPLACE
            "    dumpREG(uc);\n    return false;\n}"
            "    dumpREG(uc);\n    /* OHOS_UNMAPPED_GRACEFUL_EXIT: READ/WRITE_UNMAPPED\n     * 时设 PC=EXT_STOP_ADDR 并返回 true,让 uc_emu_start 正常结束(until\n     * address 到达),而非返回 false 导致 uc_emu_start 报 UC_ERR_READ_UNMAPPED\n     * → run_arm_with_sp 返回 MR_FAILED → timer 循环永久死亡 → 画面卡死。\n     * FETCH_UNMAPPED@0 已有类似处理(设 PC/LR 后 return true)。\n     * 花屏场景: guest 用被像素覆写的位图指针(如 0xF81FF81F)做访问,\n     * 跳过本次操作让游戏继续运行,比彻底杀死模拟器更安全。 */\n    if (type == UC_MEM_READ_UNMAPPED || type == UC_MEM_WRITE_UNMAPPED) {\n        uint32_t _stop = EXT_STOP_ADDR;\n        uc_reg_write(uc, UC_ARM_REG_PC, &_stop);\n        return true;\n    }\n    return false;\n}"
            _aet6 "${_aet6}")
        # Patch 2: run_arm_with_sp — UC_ERR_READ/WRITE_UNMAPPED 视为干净退出
        string(REPLACE
            "        printf(\"arm_ext_executor: uc_emu_start(0x%X) failed: %u (%s)\\n\", start, err, uc_strerror(err));\n        uint8_t *pc_mem = arm_ptr(m, pc);\n        if (pc_mem) {\n            printf(\"arm_ext_executor: pc bytes @0x%X:\", pc);\n            for (uint32_t i = 0; i < 16; ++i) printf(\" %02X\", pc_mem[i]);\n            printf(\"\\n\");\n        }\n        dump_pc_ring(m);\n        dumpREG(m->uc);\n        return MR_FAILED;"
            "        /* OHOS_UNMAPPED_GRACEFUL_EXIT: UC_ERR_READ/WRITE_UNMAPPED 时\n         * hook_invalid 已将 PC 设为 EXT_STOP_ADDR,但若 hook 返回 false\n         * (或其他路径)uc_emu_start 仍报错,这里作为兜底把其视为干净退出。\n         * 损坏的 ARM 位图指针不应杀死整个模拟器;timer 下次触发时\n         * 游戏逻辑可能已恢复。花屏是内存覆写的症状,跳过比卡死好。 */\n        if (err == UC_ERR_READ_UNMAPPED || err == UC_ERR_WRITE_UNMAPPED) {\n            if (getenv(\"VMRP_ARM_EXT_TRACE\")) {\n                printf(\"arm_ext_executor: unmapped access treated as clean exit (err=%u pc=0x%X sp=0x%X)\\n\", err, pc, cur_sp);\n            }\n            reg_write32(m->uc, UC_ARM_REG_PC, EXT_STOP_ADDR);\n            return MR_SUCCESS;\n        }\n        printf(\"arm_ext_executor: uc_emu_start(0x%X) failed: %u (%s)\\n\", start, err, uc_strerror(err));\n        uint8_t *pc_mem = arm_ptr(m, pc);\n        if (pc_mem) {\n            printf(\"arm_ext_executor: pc bytes @0x%X:\", pc);\n            for (uint32_t i = 0; i < 16; ++i) printf(\" %02X\", pc_mem[i]);\n            printf(\"\\n\");\n        }\n        dump_pc_ring(m);\n        dumpREG(m->uc);\n        return MR_FAILED;"
            _aet6 "${_aet6}")
        file(WRITE "${_VMRP_ARMEXT6}" "${_aet6}")
        message(STATUS "[OHOS] Patched UC_MEM_READ/WRITE_UNMAPPED graceful exit (OHOS_UNMAPPED_GRACEFUL_EXIT)")
    endif()
endif()

# --- Patch arm_ext_executor.c: UC_ERR_EXCEPTION 堆数据恢复 ---
# run_arm_with_sp 中的堆数据恢复路径(三个 if (err == UC_ERR_INSN_INVALID && pc >= ...))
# 仅检查 INSN_INVALID,但 pending_intr_no 产生的 UC_ERR_EXCEPTION 同样可能
# 导致 PC 落在堆上。例如: timer 回调中 guest 执行 SVC → pending_intr_no
# 被设置 → err 被人为改为 UC_ERR_EXCEPTION → Thumb 重试因 PC 在堆区
# (非代码段)跳过 → 三个堆数据恢复块因 err!=INSN_INVALID 全部跳过 →
# sp_diff 也太远 → 打印错误日志返回 MR_FAILED → timer 死亡。
# 修复: 将三个 err==UC_ERR_INSN_INVALID 条件扩展为同时覆盖 EXCEPTION。
set(_VMRP_ARMEXT7 "${VMRP_SRC_DIR}/src/arm_ext_executor.c")
if(EXISTS "${_VMRP_ARMEXT7}")
    file(READ "${_VMRP_ARMEXT7}" _aet7)
    if(NOT _aet7 MATCHES "OHOS_EXCEPTION_HEAP_RECOVERY")
        string(REPLACE
            "err == UC_ERR_INSN_INVALID && pc >="
            "(err == UC_ERR_INSN_INVALID || err == UC_ERR_EXCEPTION) && pc >= /* OHOS_EXCEPTION_HEAP_RECOVERY */"
            _aet7 "${_aet7}")
        file(WRITE "${_VMRP_ARMEXT7}" "${_aet7}")
        message(STATUS "[OHOS] Patched UC_ERR_EXCEPTION heap recovery (OHOS_EXCEPTION_HEAP_RECOVERY)")
    endif()
endif()

# --- Patch arm_ext_executor.c: platEx(1001/1002/1012/1013) 内存扩展接口 ---
# SkyEngine 内存扩展接口: 1001=获取屏幕缓冲 1002=释放屏幕缓冲
# 1012=申请内部RAM 1013=释放内部RAM。1014/1015 已在源码中实现。
# 1001/1002/1012/1013 需要从 ARM 堆分配,使 guest 代码能用 ARM 地址访问。
# 不实现时 dsm.c 返回 MR_IGNORE,mythroad.c 走第一内存(mr_malloc)路径。
# 实现后 MR_SECOND_BUF 路径可用,减少第一内存压力。
set(_VMRP_ARMEXT8 "${VMRP_SRC_DIR}/src/arm_ext_executor.c")
if(EXISTS "${_VMRP_ARMEXT8}")
    file(READ "${_VMRP_ARMEXT8}" _aet8)
    if(NOT _aet8 MATCHES "OHOS_PLATEX_MEM_EXT")
        string(REPLACE
            "            /*\n             * MR_MALLOC_SCRRAM/MR_FREE_SCRRAM provide scratch RAM that native"
            "            /* OHOS_PLATEX_MEM_EXT: platEx(1001) 获取屏幕缓冲(第二内存),从 ARM 堆分配\n             * 屏幕大小(SCRW*SCRH*2)的缓冲,guest 代码用返回的 ARM 地址做离屏渲染。\n             * platEx(1002) 释放时清零 addr/len;platEx(1012) 申请内部 cache;\n             * platEx(1013) 释放内部 cache。均与 1014/1015 同模式——ARM 堆分配,\n             * guest 通过写回的 ARM 地址访问,无需 host 指针转换。\n             */\n            if (r0 == 1001) {\n                uint32_t outp = r3, outlenp = arg_read(m, 4);\n                uint32_t want = 0;\n                /* 屏幕缓冲大小: 从 table[92/93] 读 mr_screen_w/h,\n                 * 兜底用 240*320*2=153600 */\n                {\n                    uint32_t sw = 240, sh = 320;\n                    if (m->screen_w_slot) {\n                        void *sp = arm_ptr(m, m->screen_w_slot);\n                        if (sp) memcpy(&sw, sp, 4);\n                    }\n                    if (m->screen_h_slot) {\n                        void *sp = arm_ptr(m, m->screen_h_slot);\n                        if (sp) memcpy(&sh, sp, 4);\n                    }\n                    if (sw < 16 || sw > 1024) sw = 240;\n                    if (sh < 16 || sh > 1024) sh = 320;\n                    want = sw * sh * 2;\n                }\n                uint32_t a = 0;\n                if (want) {\n                    if (m->screen_buf_addr && want <= m->screen_buf_len) {\n                        a = m->screen_buf_addr;\n                    } else {\n                        a = arm_alloc(m, want);\n                        if (a) {\n                            m->screen_buf_addr = a;\n                            m->screen_buf_len = want;\n                            void *ep = arm_ptr(m, a);\n                            if (ep) memset(ep, 0, want);\n                        }\n                    }\n                }\n                if (a) {\n                    if (outp) uc_mem_write(m->uc, outp, &a, 4);\n                    if (outlenp) uc_mem_write(m->uc, outlenp, &want, 4);\n                }\n                ret = a ? MR_SUCCESS : MR_FAILED;\n                break;\n            }\n            if (r0 == 1002) {\n                m->screen_buf_addr = 0;\n                m->screen_buf_len = 0;\n                ret = MR_SUCCESS;\n                break;\n            }\n            if (r0 == 1012) {\n                uint32_t outp = r3, outlenp = arg_read(m, 4);\n                uint32_t want = (uint32_t)r2;\n                uint32_t a = 0;\n                if (want) {\n                    if (m->iram_addr && want <= m->iram_len) {\n                        a = m->iram_addr;\n                    } else {\n                        a = arm_alloc(m, want);\n                        if (a) {\n                            m->iram_addr = a;\n                            m->iram_len = want;\n                            void *ep = arm_ptr(m, a);\n                            if (ep) memset(ep, 0, want);\n                        }\n                    }\n                }\n                if (a) {\n                    if (outp) uc_mem_write(m->uc, outp, &a, 4);\n                    if (outlenp) uc_mem_write(m->uc, outlenp, &want, 4);\n                }\n                ret = a ? MR_SUCCESS : MR_IGNORE;\n                break;\n            }\n            if (r0 == 1013) {\n                m->iram_addr = 0;\n                m->iram_len = 0;\n                ret = MR_SUCCESS;\n                break;\n            }\n            /*\n             * MR_MALLOC_SCRRAM/MR_FREE_SCRRAM provide scratch RAM that native"
            _aet8 "${_aet8}")
        file(WRITE "${_VMRP_ARMEXT8}" "${_aet8}")
        message(STATUS "[OHOS] Patched platEx(1001/1002/1012/1013) memory ext (OHOS_PLATEX_MEM_EXT)")
    endif()
endif()

# --- Patch arm_ext_executor.c: arm_ext_call_dispatch 中 mr_timerStart 不覆盖 ARM 侧已设的 timer ---
# 问题：arm_ext_call_dispatch 的 post-dispatch 逻辑在 wrapper queue 还有节点时
# 无条件调 mr_timerStart(timer_interval=50),覆盖了 ARM 代码在 dispatch 期间
# 通过 table[31] 设的 mr_timerStart(T)。例如 MRP 设 timerStart(1000) 表示
# 1秒后触发,但 50ms 覆盖后每 50ms 触发一次,1分钟计时只需约 3 秒完成。
# arm_ext_call 中所有 mr_timerStart(50) 都有 !m->host_timer_pending 前置条件,
# 但 arm_ext_call_dispatch 中的两处缺少此检查。
# 修复：在 mr_timerStart 之前检查 sync_timer_state_from_arm 后的 host_timer_pending,
# 如果 ARM 侧已通过 table[31] 设了自己的 timer(host_timer_pending==1),不覆盖。
set(_VMRP_ARMEXT9 "${VMRP_SRC_DIR}/src/arm_ext_executor.c")
if(EXISTS "${_VMRP_ARMEXT9}")
    file(READ "${_VMRP_ARMEXT9}" _aet9)
    if(NOT _aet9 MATCHES "OHOS_TIMER_NO_OVERRIDE")
        # 修复第一处: wrapper_timer_owner + queue_live 路径
        string(REPLACE
            "        if (queue_live) {\n            mr_timer_state = 1;\n            m->host_timer_pending = 1;\n            internal_slot_write(m, m->mr_timer_state_slot, 1);\n            /* ARM 侧可能未调用 table[31] timerStart 重新注册 SDL 定时器，\n             * 需要宿主主动启动一次以保证下一个 tick 到达 */\n            mr_timerStart((uint16)timer_interval);"
            "        if (queue_live) {\n            /* OHOS_TIMER_NO_OVERRIDE: sync_timer_state_from_arm 后 host_timer_pending==1\n             * 说明 ARM 代码已通过 table[31] 设了自己的 timer interval(如 1000ms),\n             * 此时 mr_timerStart(50) 会覆盖 api_timer_due_ms 导致定时器过快。\n             * 只在 ARM 侧未设 timer 时补启 50ms tick 驱动 wrapper queue。 */\n            int _arm_set_timer = m->host_timer_pending;\n            mr_timer_state = 1;\n            m->host_timer_pending = 1;\n            internal_slot_write(m, m->mr_timer_state_slot, 1);\n            if (!_arm_set_timer) {\n                mr_timerStart((uint16)timer_interval);\n            }"
            _aet9 "${_aet9}")
        # 修复第二处: chain_walker_owner + tc_after 路径
        string(REPLACE
            "        if (tc_after) {\n            mr_timer_state = 1;\n            m->host_timer_pending = 1;\n            internal_slot_write(m, m->mr_timer_state_slot, 1);\n            mr_timerStart((uint16)timer_interval);"
            "        if (tc_after) {\n            int _arm_set_timer_cw = m->host_timer_pending; /* OHOS_TIMER_NO_OVERRIDE */\n            mr_timer_state = 1;\n            m->host_timer_pending = 1;\n            internal_slot_write(m, m->mr_timer_state_slot, 1);\n            if (!_arm_set_timer_cw) {\n                mr_timerStart((uint16)timer_interval);\n            }"
            _aet9 "${_aet9}")
        file(WRITE "${_VMRP_ARMEXT9}" "${_aet9}")
        message(STATUS "[OHOS] Patched arm_ext_call_dispatch mr_timerStart no-override (OHOS_TIMER_NO_OVERRIDE)")
    endif()
endif()

# --- Patch mythroad.c: mr_timer 末尾调用 ohos_gif_tick() 推进 GIF 动画帧 ---
# 3011 创建的 GIF 动画需要定时器驱动逐帧绘制。ohos_gif_tick() 遍历
# 活动动画并将下一帧 RGB565 像素写入 mr_screenBuf。必须在 vmrp worker/
# timer 线程上下文调用（与 mr_screenBuf 写入串行）。
# mythroad.c 属于 :restore_patched 列表，用 CMake patch 保证幂等。
set(_VMRP_GIFTICK "${VMRP_SRC_DIR}/src/mythroad/mythroad.c")
if(EXISTS "${_VMRP_GIFTICK}")
    file(READ "${_VMRP_GIFTICK}" _gt)
    if(NOT _gt MATCHES "OHOS_GIF_TICK")
        string(REPLACE
            "    // mrp_setgcthreshold(vm_state, 0);\n    return MR_SUCCESS;\n}"
            "    // mrp_setgcthreshold(vm_state, 0);\n    /* OHOS_GIF_TICK: 推进 GIF 动画帧，\n     * 由 ohos_image_decode.cpp 提供，在 mr_timer 末尾调用确保\n     * 与 mr_screenBuf 写入串行。仅 __OHOS__ 构建生效。 */\n    { extern void ohos_gif_tick(void); ohos_gif_tick(); }\n    return MR_SUCCESS;\n}"
            _gt "${_gt}")
        file(WRITE "${_VMRP_GIFTICK}" "${_gt}")
        message(STATUS "[OHOS] Patched mr_timer ohos_gif_tick (OHOS_GIF_TICK)")
    endif()
endif()

add_subdirectory("${VMRP_SRC_DIR}" "${CMAKE_BINARY_DIR}/vmrp")

# --- OHOS 图片解码：注入 ohos_image_decode.c 到 vmrp-shared ---
# 源文件在 vmrp 树外的 ohos_src/ 目录，不污染上游源码。
# 仅 OHOS 构建（CMAKE_SYSTEM_NAME=OHOS）时编译，定义 __OHOS__ 宏
# 使 dsm.c 中的 case 3001/3002/3009/3010 生效。
# 链接鸿蒙原生 Image C API: libimage_source.so + libpixelmap.so
if(CMAKE_SYSTEM_NAME STREQUAL "OHOS" AND TARGET vmrp-shared)
    set(_OHOS_IMG_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../ohos_src/ohos_image_decode.cpp")
    if(EXISTS "${_OHOS_IMG_SRC}")
        target_sources(vmrp-shared PRIVATE "${_OHOS_IMG_SRC}")
        target_compile_definitions(vmrp-shared PRIVATE __OHOS__)
        # OHOS SDK sysroot 已通过 toolchain 设置，头文件路径自动解析
        # multimedia/image_framework 在 sysroot/usr/include 下
        # vmrp/CMakeLists.txt 使用 plain signature 的 target_link_libraries，
        # 此处也必须用 plain signature，不能混用 PRIVATE/PUBLIC 关键字。
        target_link_libraries(vmrp-shared image_source pixelmap)
        message(STATUS "[OHOS] Injected ohos_image_decode.c + libimage_source/libpixelmap")
    else()
        message(WARNING "[OHOS] ohos_image_decode.c not found at ${_OHOS_IMG_SRC}")
    endif()
endif()


