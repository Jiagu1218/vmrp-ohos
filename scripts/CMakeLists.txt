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
ohos_crlf_to_lf("${VMRP_SRC_DIR}/src/include/arm_ext_internal.h")
ohos_crlf_to_lf("${VMRP_SRC_DIR}/src/arm_ext_executor.c")
ohos_crlf_to_lf("${VMRP_SRC_DIR}/src/arm_ext/aex_exec.c")
ohos_crlf_to_lf("${VMRP_SRC_DIR}/src/arm_ext/aex_table.c")
ohos_crlf_to_lf("${VMRP_SRC_DIR}/src/arm_ext/aex_mem.c")
ohos_crlf_to_lf("${VMRP_SRC_DIR}/src/mythroad/mythroad.c")
ohos_crlf_to_lf("${VMRP_SRC_DIR}/src/mythroad/dsm.c")
ohos_crlf_to_lf("${VMRP_SRC_DIR}/src/vmrp_api.c")
ohos_crlf_to_lf("${VMRP_SRC_DIR}/src/network.c")
ohos_crlf_to_lf("${VMRP_SRC_DIR}/src/native_dsm_funcs.c")

# --- Patch arm_ext_internal.h: 添加 OHOS 需要的额外字段 ---
# 上游重构后的 ArmExtModule 缺少 OHOS 特有字段:
# - motion_acc_addr: T_MOTION_ACC 缓冲区 ARM 地址(12字节三轴加速度)
# - screen_buf_addr/len: platEx(1001) 分配的离屏渲染缓冲(第二内存)
# - iram_addr/len: platEx(1012) 分配的内部 cache
set(_VMRP_INT_H "${VMRP_SRC_DIR}/src/include/arm_ext_internal.h")
if(EXISTS "${_VMRP_INT_H}")
    file(READ "${_VMRP_INT_H}" _inth)
    if(NOT _inth MATCHES "OHOS_MOTION_ACC_FIELD")
        # motion_acc_addr: 插在 screen_h_slot 之后
        string(REPLACE
            "    uint32_t screen_h_slot;\n    uint32_t char_bitmap_addr;"
            "    uint32_t screen_h_slot;\n    /* OHOS_MOTION_ACC_FIELD: T_MOTION_ACC 三轴加速度缓冲\n     * ARM 地址(12 字节: 3×int32 x/y/z)。mr_event(MR_MOTION_EVENT)\n     * 的 param2 携带此地址,ARM 代码通过 32 位虚拟地址读取。 */\n    uint32_t motion_acc_addr;\n    uint32_t char_bitmap_addr;"
            _inth "${_inth}")
        # screen_buf_addr/len: 插在 screen_cap 之后
        string(REPLACE
            "    uint32_t screen_cap;\n    /* ARM 可见 mr_screen_w/h"
            "    uint32_t screen_cap;\n    /* OHOS_PLATEX_SCREEN_BUF: platEx(1001) 分配的离屏渲染缓冲。\n     * 与 screen_addr(主屏幕)不同,这是 guest 通过 platEx(1001) 申请的\n     * 第二内存,用于离屏绘制后再手动拷贝到主屏。 */\n    uint32_t screen_buf_addr;\n    uint32_t screen_buf_len;\n    /* ARM 可见 mr_screen_w/h"
            _inth "${_inth}")
        # iram_addr/len: 插在 exram_len 之后
        string(REPLACE
            "    uint32_t exram_len;\n    uint32_t internal_table_addr;"
            "    uint32_t exram_len;\n    /* OHOS_PLATEX_IRAM: platEx(1012) 分配的内部 cache 缓冲。 */\n    uint32_t iram_addr;\n    uint32_t iram_len;\n    uint32_t internal_table_addr;"
            _inth "${_inth}")
        file(WRITE "${_VMRP_INT_H}" "${_inth}")
        message(STATUS "[OHOS] Patched arm_ext_internal.h: added motion_acc_addr, screen_buf_addr/len, iram_addr/len")
    endif()
endif()

# --- Patch vmrp_api.c: 添加 vmrp_api_motion_power 传感器电源控制 ---
# dsm.c case 4002/4003 通过 extern 调用此函数通知宿主启停传感器。
# vmrp_api.c 属于 :restore_patched,用 CMake patch 保证幂等。
set(_VMRP_API_MOTION "${VMRP_SRC_DIR}/src/vmrp_api.c")
if(EXISTS "${_VMRP_API_MOTION}")
    file(READ "${_VMRP_API_MOTION}" _api_m)
    if(NOT _api_m MATCHES "OHOS_MOTION_POWER")
        string(REPLACE
            "    return event(6, 1, 0);\n#endif\n}"
            "    return event(6, 1, 0);\n#endif\n}\n\n/* OHOS_MOTION_POWER: 传感器电源控制。\n * dsm.c mr_plat(4002/4003) 调用此函数通知宿主启停重力感应传感器。\n * power_cb 由宿主在 vmrp_init 时注册。\n * 未注册时为空操作,不影响非 OHOS 构建。 */\nstatic int (*motion_power_cb)(int on) = NULL;\nVMRP_EXPORT void vmrp_api_motion_power(int on) {\n    if (motion_power_cb) {\n        motion_power_cb(on);\n    }\n}\nVMRP_EXPORT void vmrp_api_set_motion_power_cb(void (*cb)(int on)) {\n    motion_power_cb = (int (*)(int))cb;\n}\n\n/* OHOS_MOTION_EVENT: 投递加速度数据到 DSM 层缓存并\n * 入队 API_CMD_MOTION，由 worker 线程消费时调\n * dsm_dispatch_motion_event() 驱动 mr_event(MR_MOTION_EVENT,mode,arm_addr)。\n * 不依赖 mr_timer()（ARM ext 模式下 timer 不由宿主驱动）。\n * x/y/z 单位 mG,静止平放 z≈1000。 */\nstatic float motion_sensitivity = 1.0f;\nVMRP_EXPORT int vmrp_api_motion_event(int x, int y, int z) {\n    extern void dsm_set_motion_acc(int32 x, int32 y, int32 z);\n    dsm_set_motion_acc((int32)(x * motion_sensitivity),\n                       (int32)(y * motion_sensitivity),\n                       (int32)(z * motion_sensitivity));\n    ApiCommand cmd;\n    memset(&cmd, 0, sizeof(cmd));\n    cmd.type = API_CMD_MOTION;\n    return api_queue_command(cmd);\n}\nVMRP_EXPORT void vmrp_api_set_motion_sensitivity(float s) {\n    motion_sensitivity = s;\n}"
            _api_m "${_api_m}")
        # 子补丁1: ApiCommandType enum 加 API_CMD_MOTION
        string(REPLACE
            "    API_CMD_CANCEL_EDIT\n} ApiCommandType;"
            "    API_CMD_CANCEL_EDIT,\n    API_CMD_MOTION  /* OHOS: 动感芯片事件投递 */\n} ApiCommandType;"
            _api_m "${_api_m}")
        # 子补丁2: worker switch 加 API_CMD_MOTION 分支
        string(REPLACE
            "                case API_CMD_CANCEL_EDIT:\n                    api_apply_cancel_edit_command();\n                    break;"
            "                case API_CMD_CANCEL_EDIT:\n                    api_apply_cancel_edit_command();\n                    break;\n                case API_CMD_MOTION: /* OHOS: 投递动感芯片事件 */\n                    { extern void dsm_dispatch_motion_event(void); dsm_dispatch_motion_event(); }\n                    break;"
            _api_m "${_api_m}")
        file(WRITE "${_VMRP_API_MOTION}" "${_api_m}")
        message(STATUS "[OHOS] Patched vmrp_api motion functions + API_CMD_MOTION (OHOS_MOTION_POWER/EVENT/SENSITIVITY)")
    endif()
endif()

# --- Patch dsm.c: 重力感应(Motion Chip)OHOS 适配 ---
# 上游删除了所有 motion 支持,OHOS 本地功能需要保留:
# - 静态变量: motion_enabled/motion_powered/motion_mode/加速度缓存
# - dsm_set_motion_acc()/dsm_get_motion_acc(): 缓存读写
# - dsm_dispatch_motion_event(): 投递 MR_MOTION_EVENT 到 mr_event
# - mr_plat case 4001~4006: 停止/上电/断电/晃动/倾斜/获取范围
# dsm.c 属于 :restore_patched,用 CMake patch 保证幂等。
set(_VMRP_DSM_MOTION "${VMRP_SRC_DIR}/src/mythroad/dsm.c")
if(EXISTS "${_VMRP_DSM_MOTION}")
    file(READ "${_VMRP_DSM_MOTION}" _dsm_m)
    if(NOT _dsm_m MATCHES "OHOS_MOTION_CHIP")
        # 1) 在 dsmInFuncs 后插入 motion 静态变量
        string(REPLACE
            "static DSM_REQUIRE_FUNCS *dsmInFuncs;\nstatic uint32 dsmStartTime;"
            "static DSM_REQUIRE_FUNCS *dsmInFuncs;\nstatic uint32 dsmStartTime;\n/* OHOS_MOTION_CHIP: 重力感应状态与加速度缓存 */\nstatic int32 motion_enabled = 0;\nstatic int32 motion_powered = 0;\nstatic int32 motion_mode = 0;\nstatic int32 motion_acc_x = 0, motion_acc_y = 0, motion_acc_z = 0;"
            _dsm_m "${_dsm_m}")
        # 2) 在 mr_plat default case 前插入 motion cases
        string(REPLACE
            "        case MR_SET_KEY_END:  // 1214 启用/禁用按键结束事件\n            return MR_SUCCESS;\n        default:"
            "        case MR_SET_KEY_END:  // 1214 启用/禁用按键结束事件\n            return MR_SUCCESS;\n        /* OHOS_MOTION_CHIP: 重力感应 mr_plat 命令 */\n        case 4001:  /* 停止监听 */\n            motion_enabled = 0;\n            return MR_SUCCESS;\n        case 4002:  /* 上电 */\n            motion_powered = 1;\n            { extern void vmrp_api_motion_power(int on); vmrp_api_motion_power(1); }\n            return MR_SUCCESS;\n        case 4003:  /* 断电 */\n            motion_powered = 0; motion_enabled = 0;\n            { extern void vmrp_api_motion_power(int on); vmrp_api_motion_power(0); }\n            return MR_SUCCESS;\n        case 4004:  /* 晃动模式: MR_MOTION_EVENT_SHAKE=0 */\n            motion_enabled = 1; motion_mode = 0;\n            return MR_SUCCESS;\n        case 4005:  /* 倾斜模式: MR_MOTION_EVENT_TILT=1 */\n            motion_enabled = 1; motion_mode = 1;\n            return MR_SUCCESS;\n        case 4006:  /* 获取范围 */\n            return MR_PLAT_VALUE_BASE + 3000;\n        default:"
            _dsm_m "${_dsm_m}")
        # 3) 在文件末尾(dsm_init 之前)插入 motion 函数
        string(REPLACE
            "int32 dsm_init(DSM_REQUIRE_FUNCS *inFuncs) {"
            "/* OHOS_MOTION_CHIP: 加速度缓存读写与事件投递 */\nvoid dsm_set_motion_acc(int32 x, int32 y, int32 z) {\n    motion_acc_x = x; motion_acc_y = y; motion_acc_z = z;\n}\nvoid dsm_get_motion_acc(int32 *x, int32 *y, int32 *z) {\n    if (x) *x = motion_acc_x;\n    if (y) *y = motion_acc_y;\n    if (z) *z = motion_acc_z;\n}\nvoid dsm_dispatch_motion_event(void) {\n    if (!motion_enabled) return;\n    extern uint32 dsm_write_motion_acc_to_arm(void);\n    uint32 arm_addr = dsm_write_motion_acc_to_arm();\n    if (!arm_addr) return;\n    extern int32 mr_event(int16 type, int32 param1, int32 param2);\n    mr_event(MR_MOTION_EVENT, motion_mode, (int32)arm_addr);\n}\n\nint32 dsm_init(DSM_REQUIRE_FUNCS *inFuncs) {"
            _dsm_m "${_dsm_m}")
        file(WRITE "${_VMRP_DSM_MOTION}" "${_dsm_m}")
        message(STATUS "[OHOS] Patched dsm.c motion chip support (OHOS_MOTION_CHIP)")
    endif()
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

# --- Patch aex_table.c: case 38 memset 越界守卫 (OHOS_MEMSET_BOUNDS_GUARD) ---
# 上游重构: arm_ext_executor.c 的 case 38 拆分为 aex_table.c 的 aex_t038()。
# arm_alloc 上游已加 if (len > EXT_MEM_SIZE) return 0 长度守卫,覆盖 uint32
# 溢出路径(EXT 地址空间仅 16MB,heap_top+len <= 32MB 不溢出 uint32),
# 因此 OHOS_ARM_ALLOC_U64 补丁不再需要,已删除。
# case 14 上游已改用 arm_ptr_span + GOT 修复,OHOS_MEMSET_NULL_GUARD 已删除。
# 本补丁仍需保留: arm_alloc 长度守卫不覆盖 heap_top 被踩为异常小值场景
# (0x00333638 + 0xA27B9C = 0xD5B1D4 < mem_end,检查通过但分配越界)。
set(_VMRP_AEX_TABLE1 "${VMRP_SRC_DIR}/src/arm_ext/aex_table.c")
if(EXISTS "${_VMRP_AEX_TABLE1}")
    file(READ "${_VMRP_AEX_TABLE1}" _at1)
    if(NOT _at1 MATCHES "OHOS_MEMSET_BOUNDS_GUARD")
        string(REPLACE
            "                            void *ep = arm_ptr(m, a);\n                            if (ep) memset(ep, 0, want);"
            "                            void *ep = arm_ptr(m, a);\n                            /* OHOS_MEMSET_BOUNDS_GUARD: 二次越界守卫,即使 arm_alloc\n                             * 的长度守卫被绕过(如 heap_top 损坏),也阻止 memset\n                             * 踩出 m->mem 16MB 缓冲。a-EXT_BASE_ADDR+want 必须\n                             * ≤ EXT_MEM_SIZE,否则跳过 memset(与 ep==NULL 同义)。 */\n                            if (ep && (uint64_t)(a - EXT_BASE_ADDR) + (uint64_t)want <= (uint64_t)EXT_MEM_SIZE) {\n                                memset(ep, 0, want);\n                            }"
            _at1 "${_at1}")
        file(WRITE "${_VMRP_AEX_TABLE1}" "${_at1}")
        message(STATUS "[OHOS] Patched case 38 memset bounds guard in aex_table.c (OHOS_MEMSET_BOUNDS_GUARD)")
    endif()
endif()

# --- Patch arm_ext_executor.c: hook_invalid WRITE_UNMAPPED 黑洞 + READ_UNMAPPED graceful exit ---
# v2: WRITE_UNMAPPED 动态 uc_mem_map 64K 黑洞页让写操作真正完成,
# guest 状态一致不会循环崩溃;READ_UNMAPPED 设 PC=STOP 跳过。
# hook_invalid 仍在 arm_ext_executor.c(未拆分到 aex_*.c)。
set(_VMRP_ARMEXT_EXEC "${VMRP_SRC_DIR}/src/arm_ext_executor.c")
if(EXISTS "${_VMRP_ARMEXT_EXEC}")
    file(READ "${_VMRP_ARMEXT_EXEC}" _aee)
    if(NOT _aee MATCHES "OHOS_UNMAPPED_GRACEFUL_EXIT")
        string(REPLACE
            "    dumpREG(uc);\n    return false;\n}"
            "    dumpREG(uc);\n    /* OHOS_UNMAPPED_GRACEFUL_EXIT v2:\n     * WRITE_UNMAPPED: 动态 uc_mem_map 一个 64K 对齐的黑洞页,让写操作真正完成。\n     * 写入黑洞的数据丢弃但 guest 状态一致,不会循环崩溃。\n     * v1 设 PC=STOP 跳过写操作导致状态不一致,下次 timer tick 重试同一崩溃点。\n     * READ_UNMAPPED: 设 PC=STOP + TB flush,读不到数据只能跳过(graceful exit)。\n     * FETCH_UNMAPPED@0 已有类似处理(设 PC/LR 后 return true)。\n     * TB FLUSH: READ_UNMAPPED 后旧 TB 可能引用失效宿主代码,必须刷新。\n     * 黑洞页大小 64K (unicorn 要求 4K 对齐但实际实现需要更大),\n     * 地址对齐到 64K 边界,覆盖同页内后续访问。 */\n    if (type == UC_MEM_WRITE_UNMAPPED) {\n        uint64_t page = address & ~0xFFFFULL;\n        uc_err map_err = uc_mem_map(uc, page, 0x10000, UC_PROT_ALL);\n        if (map_err == UC_ERR_OK) {\n            return true;\n        }\n        uc_ctl_flush_tb(uc);\n        uint32_t _stop = EXT_STOP_ADDR;\n        uc_reg_write(uc, UC_ARM_REG_PC, &_stop);\n        return true;\n    }\n    if (type == UC_MEM_READ_UNMAPPED) {\n        uint32_t _stop = EXT_STOP_ADDR;\n        uc_reg_write(uc, UC_ARM_REG_PC, &_stop);\n        uc_ctl_flush_tb(uc);\n        return true;\n    }\n    return false;\n}"
            _aee "${_aee}")
        file(WRITE "${_VMRP_ARMEXT_EXEC}" "${_aee}")
        message(STATUS "[OHOS] Patched hook_invalid WRITE blackhole + READ graceful exit (OHOS_UNMAPPED_GRACEFUL_EXIT)")
    endif()
endif()

# --- Patch aex_exec.c: run_arm_with_sp UNMAPPED/INSN_INVALID/EXCEPTION 兜底 ---
# 上游重构: run_arm_with_sp 从 arm_ext_executor.c 拆到 aex_exec.c。
# 三类错误均视为干净退出(PC=STOP + TB flush + MR_SUCCESS):
# - WRITE_UNMAPPED: hook_invalid 映射了黑洞页但若仍到此说明映射失败
# - READ_UNMAPPED: hook_invalid 已设 PC=STOP,兜底
# - INSN_INVALID: WRITE_UNMAPPED 后状态损坏可能触发无效指令
# - EXCEPTION: TB cache 损坏,flush 后视为干净退出
# 前置的三个堆数据恢复块(INSN_INVALID/EXCEPTION + pc>=HEAP)仍在 aex_exec.c
# 中且不会被此补丁跳过——它们在错误块之前执行。
set(_VMRP_AEX_EXEC1 "${VMRP_SRC_DIR}/src/arm_ext/aex_exec.c")
if(EXISTS "${_VMRP_AEX_EXEC1}")
    file(READ "${_VMRP_AEX_EXEC1}" _ae1)
    if(NOT _ae1 MATCHES "OHOS_UNMAPPED_GRACEFUL_EXIT")
        string(REPLACE
            "        printf(\"arm_ext_executor: uc_emu_start(0x%X) failed: %u (%s)\\n\", start, err, uc_strerror(err));\n        uint8_t *pc_mem = arm_ptr(m, pc);\n        if (pc_mem) {\n            printf(\"arm_ext_executor: pc bytes @0x%X:\", pc);\n            for (uint32_t i = 0; i < 16; ++i) printf(\" %02X\", pc_mem[i]);\n            printf(\"\\n\");\n        }\n        dump_pc_ring(m);\n        dumpREG(m->uc);\n        return MR_FAILED;"
            "        /* OHOS_UNMAPPED_GRACEFUL_EXIT: 兜底处理。\n         * WRITE_UNMAPPED: hook_invalid 已映射黑洞页,若仍到此说明映射失败,视为干净退出。\n         * READ_UNMAPPED: hook_invalid 已设 PC=STOP,若仍到此同样兜底。\n         * INSN_INVALID: WRITE_UNMAPPED 后 guest 状态损坏可能触发无效指令,同样跳过。\n         * EXCEPTION: TB cache 损坏,flush 后视为干净退出。\n         * 所有路径均设 PC=STOP + TB flush,返回 MR_SUCCESS 让模拟器继续。 */\n        if (err == UC_ERR_READ_UNMAPPED || err == UC_ERR_WRITE_UNMAPPED ||\n            err == UC_ERR_INSN_INVALID || err == UC_ERR_EXCEPTION) {\n            if (err != UC_ERR_INSN_INVALID) {\n                printf(\"arm_ext_executor: unmapped/exception treated as clean exit (err=%u pc=0x%X sp=0x%X)\\n\", err, pc, cur_sp);\n            } else {\n                printf(\"arm_ext_executor: invalid instruction treated as clean exit (pc=0x%X sp=0x%X)\\n\", pc, cur_sp);\n                uint8_t *pc_mem2 = arm_ptr(m, pc);\n                if (pc_mem2) {\n                    printf(\"arm_ext_executor: pc bytes @0x%X:\", pc);\n                    for (uint32_t i = 0; i < 16; ++i) printf(\" %02X\", pc_mem2[i]);\n                    printf(\"\\n\");\n                }\n            }\n            reg_write32(m->uc, UC_ARM_REG_PC, EXT_STOP_ADDR);\n            uc_ctl_flush_tb(m->uc);\n            return MR_SUCCESS;\n        }\n        printf(\"arm_ext_executor: uc_emu_start(0x%X) failed: %u (%s)\\n\", start, err, uc_strerror(err));\n        uint8_t *pc_mem = arm_ptr(m, pc);\n        if (pc_mem) {\n            printf(\"arm_ext_executor: pc bytes @0x%X:\", pc);\n            for (uint32_t i = 0; i < 16; ++i) printf(\" %02X\", pc_mem[i]);\n            printf(\"\\n\");\n        }\n        dump_pc_ring(m);\n        dumpREG(m->uc);\n        return MR_FAILED;"
            _ae1 "${_ae1}")
        file(WRITE "${_VMRP_AEX_EXEC1}" "${_ae1}")
        message(STATUS "[OHOS] Patched run_arm_with_sp error fallback in aex_exec.c (OHOS_UNMAPPED_GRACEFUL_EXIT)")
    endif()
endif()

# --- Patch aex_exec.c: UC_ERR_EXCEPTION 堆数据恢复 ---
# 上游重构: run_arm_with_sp 的三个堆数据恢复路径从 arm_ext_executor.c
# 拆到 aex_exec.c。仅检查 INSN_INVALID,但 EXCEPTION 同样可能导致 PC
# 落在堆上。扩展条件覆盖 EXCEPTION。
set(_VMRP_AEX_EXEC2 "${VMRP_SRC_DIR}/src/arm_ext/aex_exec.c")
if(EXISTS "${_VMRP_AEX_EXEC2}")
    file(READ "${_VMRP_AEX_EXEC2}" _ae2)
    if(NOT _ae2 MATCHES "OHOS_EXCEPTION_HEAP_RECOVERY")
        string(REPLACE
            "err == UC_ERR_INSN_INVALID && pc >="
            "(err == UC_ERR_INSN_INVALID || err == UC_ERR_EXCEPTION) && pc >= /* OHOS_EXCEPTION_HEAP_RECOVERY */"
            _ae2 "${_ae2}")
        file(WRITE "${_VMRP_AEX_EXEC2}" "${_ae2}")
        message(STATUS "[OHOS] Patched UC_ERR_EXCEPTION heap recovery in aex_exec.c (OHOS_EXCEPTION_HEAP_RECOVERY)")
    endif()
endif()

# --- Patch aex_table.c: platEx(1001/1002/1012/1013) 内存扩展接口 ---
# 上游重构: case 38 拆为 aex_t038() 在 aex_table.c,缩进从 switch-case
# 的 12 spaces 变为函数内的 12 spaces(aex_t038 内部缩进与旧 switch 相同)。
# 经核实: aex_table.c 中 MR_MALLOC_SCRRAM 注释块缩进仍为 12 spaces,
# 与旧 arm_ext_executor.c 一致,needle 无需调整。
set(_VMRP_AEX_TABLE2 "${VMRP_SRC_DIR}/src/arm_ext/aex_table.c")
if(EXISTS "${_VMRP_AEX_TABLE2}")
    file(READ "${_VMRP_AEX_TABLE2}" _at2)
    if(NOT _at2 MATCHES "OHOS_PLATEX_MEM_EXT")
        string(REPLACE
            "            /*\n             * MR_MALLOC_SCRRAM/MR_FREE_SCRRAM provide scratch RAM that native"
            "            /* OHOS_PLATEX_MEM_EXT: platEx(1001) 获取屏幕缓冲(第二内存),从 ARM 堆分配\n             * 屏幕大小(SCRW*SCRH*2)的缓冲,guest 代码用返回的 ARM 地址做离屏渲染。\n             * platEx(1002) 释放时清零 addr/len;platEx(1012) 申请内部 cache;\n             * platEx(1013) 释放内部 cache。均与 1014/1015 同模式——ARM 堆分配,\n             * guest 通过写回的 ARM 地址访问,无需 host 指针转换。\n             */\n            if (r0 == 1001) {\n                uint32_t outp = r3, outlenp = arg_read(m, 4);\n                uint32_t want = 0;\n                /* 屏幕缓冲大小: 从 table[92/93] 读 mr_screen_w/h,\n                 * 兜底用 240*320*2=153600 */\n                {\n                    uint32_t sw = 240, sh = 320;\n                    if (m->screen_w_slot) {\n                        void *sp = arm_ptr(m, m->screen_w_slot);\n                        if (sp) memcpy(&sw, sp, 4);\n                    }\n                    if (m->screen_h_slot) {\n                        void *sp = arm_ptr(m, m->screen_h_slot);\n                        if (sp) memcpy(&sh, sp, 4);\n                    }\n                    if (sw < 16 || sw > 1024) sw = 240;\n                    if (sh < 16 || sh > 1024) sh = 320;\n                    want = sw * sh * 2;\n                }\n                uint32_t a = 0;\n                if (want) {\n                    if (m->screen_buf_addr && want <= m->screen_buf_len) {\n                        a = m->screen_buf_addr;\n                    } else {\n                        a = arm_alloc(m, want);\n                        if (a) {\n                            m->screen_buf_addr = a;\n                            m->screen_buf_len = want;\n                            void *ep = arm_ptr(m, a);\n                            if (ep) memset(ep, 0, want);\n                        }\n                    }\n                }\n                if (a) {\n                    if (outp) uc_mem_write(m->uc, outp, &a, 4);\n                    if (outlenp) uc_mem_write(m->uc, outlenp, &want, 4);\n                }\n                ret = a ? MR_SUCCESS : MR_FAILED;\n                goto aex_done;\n            }\n            if (r0 == 1002) {\n                m->screen_buf_addr = 0;\n                m->screen_buf_len = 0;\n                ret = MR_SUCCESS;\n                goto aex_done;\n            }\n            if (r0 == 1012) {\n                uint32_t outp = r3, outlenp = arg_read(m, 4);\n                uint32_t want = (uint32_t)r2;\n                uint32_t a = 0;\n                if (want) {\n                    if (m->iram_addr && want <= m->iram_len) {\n                        a = m->iram_addr;\n                    } else {\n                        a = arm_alloc(m, want);\n                        if (a) {\n                            m->iram_addr = a;\n                            m->iram_len = want;\n                            void *ep = arm_ptr(m, a);\n                            if (ep) memset(ep, 0, want);\n                        }\n                    }\n                }\n                if (a) {\n                    if (outp) uc_mem_write(m->uc, outp, &a, 4);\n                    if (outlenp) uc_mem_write(m->uc, outlenp, &want, 4);\n                }\n                ret = a ? MR_SUCCESS : MR_IGNORE;\n                goto aex_done;\n            }\n            if (r0 == 1013) {\n                m->iram_addr = 0;\n                m->iram_len = 0;\n                ret = MR_SUCCESS;\n                goto aex_done;\n            }\n            /*\n             * MR_MALLOC_SCRRAM/MR_FREE_SCRRAM provide scratch RAM that native"
            _at2 "${_at2}")
        file(WRITE "${_VMRP_AEX_TABLE2}" "${_at2}")
        message(STATUS "[OHOS] Patched platEx(1001/1002/1012/1013) in aex_table.c (OHOS_PLATEX_MEM_EXT)")
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
            "    // mrp_setgcthreshold(vm_state, 0);\n    /* OHOS_GIF_TICK: 推进 GIF 动画帧，\n     * 由 ohos_image_decode.cpp 提供，在 mr_timer 末尾调用确保\n     * 与 mr_screenBuf 写入串行。仅 __OHOS__ 构建生效。 */\n    { extern void ohos_gif_tick(void); ohos_gif_tick(); }\n    /* OHOS_MOTION_DISPATCH: 每个 timer tick 投递加速度数据到 ARM 侧。\n     * dsm_set_motion_acc() 仅写宿主缓存，mr_event(MR_MOTION_EVENT,mode,arm_addr) 才\n     * 触发 MRP 的 dealevent。必须在 worker/timer 线程调用（写 Unicorn 内存\n     * 和调 mr_event 都需要与 Unicorn 串行）。 */\n    { extern void dsm_dispatch_motion_event(void); dsm_dispatch_motion_event(); }\n    return MR_SUCCESS;\n}"
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


