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
ohos_crlf_to_lf("${VMRP_SRC_DIR}/src/mythroad/src/lib/mr_strlib.c")

# --- Patch arm_ext_internal.h: 添加 OHOS 需要的额外字段 ---
# 上游 651e421 已添加 motion_acc_addr(与上游 mr_motion_input 共用),不再注入。
# OHOS 特有字段:
# - screen_buf_addr/len: platEx(1001) 分配的离屏渲染缓冲(第二内存)
# - iram_addr/len: platEx(1012) 分配的内部 cache
set(_VMRP_INT_H "${VMRP_SRC_DIR}/src/include/arm_ext_internal.h")
if(EXISTS "${_VMRP_INT_H}")
    file(READ "${_VMRP_INT_H}" _inth)
    if(NOT _inth MATCHES "OHOS_PLATEX_SCREEN_BUF")
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
        message(STATUS "[OHOS] Patched arm_ext_internal.h: added screen_buf_addr/len, iram_addr/len")
    endif()
endif()

# --- Patch vmrp_api.c: 添加 vmrp_api_start_dsmB/C/ex 外部移植接口 ---
# 上游 651e421/4fbb0b4 已实现 motion/shake(vmrp_api_motion/take_shake 等),
# OHOS 不再注入 motion/shake 代码。仅保留上游没有的 dsmB/C/ex 热启动接口。
set(_VMRP_API_MOTION "${VMRP_SRC_DIR}/src/vmrp_api.c")
if(EXISTS "${_VMRP_API_MOTION}")
    file(READ "${_VMRP_API_MOTION}" _api_m)
    if(NOT _api_m MATCHES "OHOS_DSM_BC_EX")
        # OHOS_DSM_BC_EX — vmrp_api_start_dsmB/C/ex 导出
        # 锚点: vmrp_api_take_shake 函数末尾(上游 4fbb0b4 新增,稳定存在)
        string(REPLACE
            "VMRP_EXPORT int vmrp_api_take_shake(void) {\n#if VMRP_API_ASYNC_RUNNER\n    api_lock();\n#endif\n    int req = shake_request;\n    shake_request = 0;\n#if VMRP_API_ASYNC_RUNNER\n    api_unlock();\n#endif\n    return req;\n}"
            "VMRP_EXPORT int vmrp_api_take_shake(void) {\n#if VMRP_API_ASYNC_RUNNER\n    api_lock();\n#endif\n    int req = shake_request;\n    shake_request = 0;\n#if VMRP_API_ASYNC_RUNNER\n    api_unlock();\n#endif\n    return req;\n}\n\n/* OHOS_DSM_BC_EX: 外部移植接口 vmrp_api_start_dsmB/C/ex。\n * 宿主通过这些函数以简化参数启动 MRP 应用:\n *   vmrp_api_start_dsmB(entry)   — entry 含 *A/%QQ.mrp 前缀\n *   vmrp_api_start_dsmC(entry)   — 同 dsmB(引擎已初始化)\n *   vmrp_api_start_dsm_ex(path, entry) — 显式 path+entry\n * 内部调 mythroad 层实现,需在引擎运行中调用(热切换)。\n */\nVMRP_EXPORT int vmrp_api_start_dsmB(const char *entry) {\n    if (!api_running || vmrp_is_exited()) return -1;\n    extern int32 mr_start_dsmB(const char *entry);\n    return mr_start_dsmB(entry);\n}\nVMRP_EXPORT int vmrp_api_start_dsmC(const char *entry) {\n    if (!api_running || vmrp_is_exited()) return -1;\n    extern int32 mr_start_dsmC(const char *entry);\n    return mr_start_dsmC(entry);\n}\nVMRP_EXPORT int vmrp_api_start_dsm_ex(const char *path, const char *entry) {\n    if (!api_running || vmrp_is_exited()) return -1;\n    extern int32 mr_start_dsm_ex(const char *path, const char *entry);\n    return mr_start_dsm_ex(path, entry);\n}"
            _api_m "${_api_m}")
        file(WRITE "${_VMRP_API_MOTION}" "${_api_m}")
        message(STATUS "[OHOS] Patched vmrp_api dsmB/C/ex functions (OHOS_DSM_BC_EX)")
    endif()
endif()

# --- Patch dsm.c: 重力感应(Motion Chip) ---
# 上游 651e421 已实现完整的动感芯片支持(dsmMotion* + case 4001-4006 +
# dsm_motion_listening_mode),OHOS 不再注入 motion 代码。

# --- Patch vmrp native_dsm_funcs.c: MAP_32BIT is x86-glibc only, musl lacks it ---
# native_mem_get() uses mmap(... MAP_32BIT) on x86_64 to place the DSM memory in
# the low 32-bit range. OHOS uses musl libc which does NOT define MAP_32BIT, so
# x86_64 emulator builds fail to compile. Replace MAP_32BIT with 0 (plain anon
# mmap); the function already has a malloc() fallback, so correctness is intact
# and only the low-address hint is lost on x86_64. arm64 is unaffected (the
# block is already guarded by #ifdef __x86_64__).
#
# 上游 4fbb0b4 已重构 native_startShake/stopShake 为调 guiStartShake/guiStopShake
# (轮询模型,嵌入端经 vmrp_api_take_shake 取走请求),OHOS 不再注入 shake 转发代码。
set(_VMRP_DSM "${VMRP_SRC_DIR}/src/native_dsm_funcs.c")
if(EXISTS "${_VMRP_DSM}")
    file(READ "${_VMRP_DSM}" _dsm_text)
    set(_dsm_patched FALSE)
    # 子补丁1: MAP_32BIT → 0
    if(_dsm_text MATCHES "MAP_ANONYMOUS \\| MAP_32BIT")
        string(REPLACE "MAP_ANONYMOUS | MAP_32BIT"
                       "MAP_ANONYMOUS /* x86-glibc only, musl lacks the 32bit flag */"
                       _dsm_text "${_dsm_text}")
        set(_dsm_patched TRUE)
    endif()
    if(_dsm_patched)
        file(WRITE "${_VMRP_DSM}" "${_dsm_text}")
        message(STATUS "[OHOS] Patched native_dsm_funcs.c (MAP_32BIT)")
    endif()
    # 子补丁3: OHOS_MEDIA_CTRL — NativeAudioState 扩展 + pause/resume/seek/position/duration
    if(NOT _dsm_text MATCHES "OHOS_MEDIA_CTRL")
        # 3a) NativeAudioState 加 pcm_total_len/paused/midi_total_samples/midi_rendered_samples
        string(REPLACE
            "    uint8 *pcm;\n    uint32 pcm_len;\n    uint32 pcm_pos;\n    int loop;\n    MidiEvent midi_events"
            "    uint8 *pcm;\n    uint32 pcm_len;\n    uint32 pcm_total_len;  /* OHOS_MEDIA_CTRL: PCM 总字节长度,loop 时 pcm_len==pcm_total_len,非 loop 播完后 pcm_len=0 */\n    uint32 pcm_pos;\n    int loop;\n    int paused;               /* OHOS_MEDIA_CTRL: 暂停标记,render 时跳过输出 */\n    uint32 midi_total_samples;   /* OHOS_MEDIA_CTRL: MIDI 总采样数=loop_ticks*samples_per_tick */\n    uint32 midi_rendered_samples;/* OHOS_MEDIA_CTRL: MIDI 已渲染采样数 */\n    MidiEvent midi_events"
            _dsm_text "${_dsm_text}")
        # 3b) native_audio_clear_locked 重置新字段
        string(REPLACE
            "    s->pcm_len = 0;\n    s->pcm_pos = 0;\n    s->midi_event_count"
            "    s->pcm_len = 0;\n    s->pcm_total_len = 0;  /* OHOS_MEDIA_CTRL */\n    s->pcm_pos = 0;\n    s->paused = 0;               /* OHOS_MEDIA_CTRL */\n    s->midi_total_samples = 0;   /* OHOS_MEDIA_CTRL */\n    s->midi_rendered_samples = 0;/* OHOS_MEDIA_CTRL */\n    s->midi_event_count"
            _dsm_text "${_dsm_text}")
        # 3c) native_audio_render_bytes: paused 时跳过渲染 + MIDI 计 rendered_samples
        string(REPLACE
            "    if (!stream || len <= 0) return 0;\n    memset(stream, 0, (size_t)len);\n\n    int frames"
            "    if (!stream || len <= 0) return 0;\n    memset(stream, 0, (size_t)len);\n\n    if (s->paused) return 0;  /* OHOS_MEDIA_CTRL: 暂停时不渲染,保持静音 */\n\n    int frames"
            _dsm_text "${_dsm_text}")
        string(REPLACE
            "        midi_render(s, (int16_t *)stream, frames);\n    }\n\n    return source"
            "        midi_render(s, (int16_t *)stream, frames);\n        s->midi_rendered_samples += (uint32)frames;  /* OHOS_MEDIA_CTRL */\n    }\n\n    return source"
            _dsm_text "${_dsm_text}")
        # 3d) native_audio_take_pcm: 设置 pcm_total_len
        string(REPLACE
            "    native_audio.pcm = pcm;\n    native_audio.pcm_len = pcm_len;\n    native_audio.pcm_pos = 0;"
            "    native_audio.pcm = pcm;\n    native_audio.pcm_len = pcm_len;\n    native_audio.pcm_total_len = pcm_len;  /* OHOS_MEDIA_CTRL */\n    native_audio.pcm_pos = 0;"
            _dsm_text "${_dsm_text}")
        # 3e) native_audio_play_midi: 计算 midi_total_samples + 重置 rendered
        string(REPLACE
            "        native_audio.loop = loop ? 1 : 0;\n        midi_reset_playback(&native_audio);\n        native_audio.source = AUDIO_SOURCE_MIDI;"
            "        native_audio.loop = loop ? 1 : 0;\n        native_audio.midi_total_samples = native_audio.midi_loop_ticks * native_audio.midi_samples_per_tick;  /* OHOS_MEDIA_CTRL */\n        native_audio.midi_rendered_samples = 0;  /* OHOS_MEDIA_CTRL */\n        midi_reset_playback(&native_audio);\n        native_audio.source = AUDIO_SOURCE_MIDI;"
            _dsm_text "${_dsm_text}")
        # 3f) 在 native_audio_stop 后插入 pause/resume/seek/position/duration
        string(REPLACE
            "void native_audio_stop(void) {\n    native_audio_lock();\n    native_audio_clear_locked(&native_audio);\n    native_audio_unlock();\n}"
            "void native_audio_stop(void) {\n    native_audio_lock();\n    native_audio_clear_locked(&native_audio);\n    native_audio_unlock();\n}\n\n/* OHOS_MEDIA_CTRL: 媒体播放控制(PAUSE/RESUME/SEEK/POSITION/DURATION) */\nvoid native_audio_pause(void) {\n    native_audio_lock();\n    if (native_audio.source != AUDIO_SOURCE_NONE) {\n        native_audio.paused = 1;\n    }\n    native_audio_unlock();\n}\nvoid native_audio_resume(void) {\n    native_audio_lock();\n    native_audio.paused = 0;\n    native_audio_unlock();\n}\nint native_audio_seek(int ms) {\n    native_audio_lock();\n    if (native_audio.source == AUDIO_SOURCE_PCM && native_audio.pcm_total_len > 0) {\n        uint32 byte_pos = (uint32)((int64_t)ms * AUDIO_SAMPLE_RATE * AUDIO_CHANNELS * sizeof(int16_t) / 1000);\n        if (byte_pos > native_audio.pcm_total_len) byte_pos = native_audio.pcm_total_len;\n        native_audio.pcm_pos = byte_pos;\n        native_audio_unlock();\n        return MR_SUCCESS;\n    } else if (native_audio.source == AUDIO_SOURCE_MIDI && native_audio.midi_total_samples > 0) {\n        uint32 target_sample = (uint32)((int64_t)ms * AUDIO_SAMPLE_RATE / 1000);\n        if (target_sample > native_audio.midi_total_samples) target_sample = native_audio.midi_total_samples;\n        uint32 target_tick = target_sample / (native_audio.midi_samples_per_tick > 0 ? native_audio.midi_samples_per_tick : 1);\n        native_audio.midi_tick = target_tick;\n        native_audio.midi_sample_in_tick = target_sample % (native_audio.midi_samples_per_tick > 0 ? native_audio.midi_samples_per_tick : 1);\n        native_audio.midi_event_pos = 0;\n        while (native_audio.midi_event_pos < native_audio.midi_event_count &&\n               native_audio.midi_events[native_audio.midi_event_pos].tick <= native_audio.midi_tick) {\n            midi_apply_event(&native_audio, &native_audio.midi_events[native_audio.midi_event_pos]);\n            native_audio.midi_event_pos++;\n        }\n        native_audio.midi_rendered_samples = target_sample;\n        native_audio_unlock();\n        return MR_SUCCESS;\n    }\n    native_audio_unlock();\n    return MR_FAILED;\n}\nint native_audio_position(void) {\n    native_audio_lock();\n    int pos_ms = 0;\n    if (native_audio.source == AUDIO_SOURCE_PCM && native_audio.pcm_total_len > 0) {\n        pos_ms = (int)((int64_t)native_audio.pcm_pos * 1000 / (AUDIO_SAMPLE_RATE * AUDIO_CHANNELS * sizeof(int16_t)));\n    } else if (native_audio.source == AUDIO_SOURCE_MIDI && native_audio.midi_samples_per_tick > 0) {\n        pos_ms = (int)((int64_t)native_audio.midi_rendered_samples * 1000 / AUDIO_SAMPLE_RATE);\n    }\n    native_audio_unlock();\n    return pos_ms;\n}\nint native_audio_duration(void) {\n    native_audio_lock();\n    int dur_ms = 0;\n    if (native_audio.source == AUDIO_SOURCE_PCM && native_audio.pcm_total_len > 0) {\n        dur_ms = (int)((int64_t)native_audio.pcm_total_len * 1000 / (AUDIO_SAMPLE_RATE * AUDIO_CHANNELS * sizeof(int16_t)));\n    } else if (native_audio.source == AUDIO_SOURCE_MIDI && native_audio.midi_total_samples > 0) {\n        dur_ms = (int)((int64_t)native_audio.midi_total_samples * 1000 / AUDIO_SAMPLE_RATE);\n    }\n    native_audio_unlock();\n    return dur_ms;\n}"
            _dsm_text "${_dsm_text}")
        set(_dsm_patched TRUE)
    endif()
    if(_dsm_patched)
        file(WRITE "${_VMRP_DSM}" "${_dsm_text}")
        message(STATUS "[OHOS] Patched native_dsm_funcs.c (MAP_32BIT + OHOS_MEDIA_CTRL)")
    endif()
endif()

# --- Patch vmrp_api.c: 导出 vmrp_api_media_pause/resume/seek/position/duration ---
# vmrp_api.c 属于 :restore_patched,用 CMake patch 保证幂等。
# 宿主(OHOS vmrp_engine.cpp)通过 dlsym 解析这些符号实现媒体控制。
# pause/resume 带回调: dsm.c 调 vmrp_api_media_pause 时通知宿主暂停 OHAudio renderer,
# 调 vmrp_api_media_resume 时通知宿主恢复,避免 renderer 空转拉流。
set(_VMRP_API "${VMRP_SRC_DIR}/src/vmrp_api.c")
if(EXISTS "${_VMRP_API}")
    file(READ "${_VMRP_API}" _api_text)
    if(NOT _api_text MATCHES "OHOS_MEDIA_API")
        string(REPLACE
            "VMRP_EXPORT void vmrp_api_audio_stop(void) {\n    native_audio_stop();\n}"
            "VMRP_EXPORT void vmrp_api_audio_stop(void) {\n    native_audio_stop();\n}\n\n/* OHOS_MEDIA_API: 媒体播放控制(PAUSE/RESUME/SEEK/POSITION/DURATION)。\n * 宿主通过这些符号实现 MRP 音频的暂停/恢复/跳转/进度/总时长查询。\n * pause/resume 通知宿主停启 OHAudio renderer,避免拉流空转。 */\nstatic void (*media_pause_cb)(void) = NULL;\nstatic void (*media_resume_cb)(void) = NULL;\nVMRP_EXPORT void vmrp_api_set_media_cb(void (*pause_cb)(void), void (*resume_cb)(void)) {\n    media_pause_cb = pause_cb;\n    media_resume_cb = resume_cb;\n}\nVMRP_EXPORT void vmrp_api_media_pause(void) {\n    native_audio_pause();\n    if (media_pause_cb) media_pause_cb();\n}\nVMRP_EXPORT void vmrp_api_media_resume(void) {\n    native_audio_resume();\n    if (media_resume_cb) media_resume_cb();\n}\nVMRP_EXPORT int vmrp_api_media_seek(int ms) {\n    return native_audio_seek(ms);\n}\nVMRP_EXPORT int vmrp_api_media_position(void) {\n    return native_audio_position();\n}\nVMRP_EXPORT int vmrp_api_media_duration(void) {\n    return native_audio_duration();\n}\n\n/* OHOS_VOLUME_API: 音量控制。MRP 调 mr_plat(1302,level) 时触发,\n * 宿主通过回调调 OH_AudioRenderer_SetVolume。level 通常 0~10。 */\nstatic void (*volume_cb)(int) = NULL;\nVMRP_EXPORT void vmrp_api_set_volume_cb(void (*cb)(int)) {\n    volume_cb = cb;\n}\nVMRP_EXPORT void vmrp_api_set_volume(int level) {\n    if (volume_cb) volume_cb(level);\n}"
            _api_text "${_api_text}")
        file(WRITE "${_VMRP_API}" "${_api_text}")
        message(STATUS "[OHOS] Patched vmrp_api.c (OHOS_MEDIA_API)")
    endif()
endif()

# --- Patch vmrp_api.h + native_dsm_funcs.h: 声明 media 控制函数 ---
# 两个头文件都属于 :restore_patched,用 CMake patch 保证幂等。
set(_VMRP_API_H "${VMRP_SRC_DIR}/src/include/vmrp_api.h")
if(EXISTS "${_VMRP_API_H}")
    file(READ "${_VMRP_API_H}" _api_h_text)
    if(NOT _api_h_text MATCHES "OHOS_MEDIA_DECL")
        string(REPLACE
            "VMRP_EXPORT void vmrp_api_audio_stop(void);"
            "VMRP_EXPORT void vmrp_api_audio_stop(void);\n\n/* OHOS_MEDIA_DECL: 媒体播放控制(PAUSE/RESUME/SEEK/POSITION/DURATION)。\n * vmrp_api_media_seek: 跳转到 ms 位置,返回 MR_SUCCESS/MR_FAILED。\n * vmrp_api_media_position: 当前播放位置(ms)。\n * vmrp_api_media_duration: 总时长(ms),未知返回0。\n * vmrp_api_set_media_cb: 注册暂停/恢复回调,宿主收到回调时停启 OHAudio renderer。 */\nVMRP_EXPORT void vmrp_api_media_pause(void);\nVMRP_EXPORT void vmrp_api_media_resume(void);\nVMRP_EXPORT int vmrp_api_media_seek(int ms);\nVMRP_EXPORT int vmrp_api_media_position(void);\nVMRP_EXPORT int vmrp_api_media_duration(void);\nVMRP_EXPORT void vmrp_api_set_media_cb(void (*pause_cb)(void), void (*resume_cb)(void));\n\n/* OHOS_VOLUME_DECL: 音量控制。vmrp_api_set_volume: MRP 调 mr_plat(1302,level)\n * 时触发,level 通常 0~10。宿主收到回调时调 OH_AudioRenderer_SetVolume。 */\nVMRP_EXPORT void vmrp_api_set_volume(int level);\nVMRP_EXPORT void vmrp_api_set_volume_cb(void (*cb)(int level));"
            _api_h_text "${_api_h_text}")
        file(WRITE "${_VMRP_API_H}" "${_api_h_text}")
        message(STATUS "[OHOS] Patched vmrp_api.h (OHOS_MEDIA_DECL)")
    endif()
endif()
set(_VMRP_NDF_H "${VMRP_SRC_DIR}/src/include/native_dsm_funcs.h")
if(EXISTS "${_VMRP_NDF_H}")
    file(READ "${_VMRP_NDF_H}" _ndf_h_text)
    if(NOT _ndf_h_text MATCHES "OHOS_MEDIA_DECL")
        string(REPLACE
            "void native_audio_stop(void);"
            "void native_audio_stop(void);\n/* OHOS_MEDIA_DECL */\nvoid native_audio_pause(void);\nvoid native_audio_resume(void);\nint native_audio_seek(int ms);\nint native_audio_position(void);\nint native_audio_duration(void);"
            _ndf_h_text "${_ndf_h_text}")
        file(WRITE "${_VMRP_NDF_H}" "${_ndf_h_text}")
        message(STATUS "[OHOS] Patched native_dsm_funcs.h (OHOS_MEDIA_DECL)")
    endif()
endif()

# --- Patch dsm.c: OHOS_DSM_MEDIA — 修复 PAUSE/STOP/RESUME + 实现 SETPOS/GET_TOTAL_TIME/GET_CURTIME ---
# 上游 PAUSE 和 STOP 实现相同(都调 mr_stopSound 清空 PCM),导致 PAUSE 后无法 RESUME。
# 修复:
# - DsmMediaDevice 加 duration_ms/pause_pos_ms 跟踪媒体位置
# - PAUSE: 记当前位置→pause_pos_ms, 调 vmrp_api_media_pause 暂停渲染(不清 PCM)
# - STOP: 调 mr_stopSound 清 PCM + 重置位置
# - RESUME: 从 pause_pos_ms 恢复, 调 vmrp_api_media_resume
# - 210 SETPOS: vmrp_api_media_seek(ms)
# - 212 GET_TOTAL_TIME: vmrp_api_media_duration()
# - 213 GET_CURTIME(s): vmrp_api_media_position() / 1000
# - 215 GET_CURTIME(ms): vmrp_api_media_position()
set(_VMRP_DSM_MEDIA "${VMRP_SRC_DIR}/src/mythroad/dsm.c")
if(EXISTS "${_VMRP_DSM_MEDIA}")
    file(READ "${_VMRP_DSM_MEDIA}" _dsm_media)
    if(NOT _dsm_media MATCHES "OHOS_DSM_MEDIA")
        # 1) DsmMediaDevice 加 duration_ms + pause_pos_ms
        string(REPLACE
            "    int owns_data;\n} DsmMediaDevice;"
            "    int owns_data;\n    int32 duration_ms;     /* OHOS_DSM_MEDIA: 总时长(ms) */\n    int32 pause_pos_ms;   /* OHOS_DSM_MEDIA: PAUSE 时保存的位置(ms) */\n} DsmMediaDevice;"
            _dsm_media "${_dsm_media}")
        # 2) dsm_media_play: 播放时记录 duration_ms
        string(REPLACE
            "    if (ret == MR_SUCCESS) {\n        media->status = MR_MEDIA_PLAYING;\n    }\n    return ret;\n}"
            "    if (ret == MR_SUCCESS) {\n        media->status = MR_MEDIA_PLAYING;\n        /* OHOS_DSM_MEDIA: 播放成功后查询总时长缓存到 duration_ms */\n        extern int vmrp_api_media_duration(void);\n        media->duration_ms = vmrp_api_media_duration();\n        media->pause_pos_ms = 0;\n    }\n    return ret;\n}"
            _dsm_media "${_dsm_media}")
        # 3) PAUSE: 记位置+暂停渲染(不清 PCM)
        string(REPLACE
            "        case MR_MEDIA_PAUSE_REQ:\n        case MR_MEDIA_STOP_REQ:\n            mr_stopSound(dsm_media_to_sound_type(device));\n            media->status = MR_MEDIA_LOADED;\n            return MR_SUCCESS;\n        case MR_MEDIA_RESUME_REQ:\n            return dsm_media_play(media, input, input_len);"
            "        case MR_MEDIA_PAUSE_REQ: {  /* OHOS_DSM_MEDIA: PAUSE 保存位置,暂停渲染,不清 PCM */\n            extern int vmrp_api_media_position(void);\n            extern void vmrp_api_media_pause(void);\n            media->pause_pos_ms = vmrp_api_media_position();\n            vmrp_api_media_pause();\n            media->status = MR_MEDIA_PAUSED;\n            return MR_SUCCESS;\n        }\n        case MR_MEDIA_STOP_REQ:  /* OHOS_DSM_MEDIA: STOP 清 PCM+重置位置 */\n            mr_stopSound(dsm_media_to_sound_type(device));\n            media->pause_pos_ms = 0;\n            media->duration_ms = 0;\n            media->status = MR_MEDIA_LOADED;\n            return MR_SUCCESS;\n        case MR_MEDIA_RESUME_REQ: {  /* OHOS_DSM_MEDIA: RESUME 从暂停位置恢复 */\n            extern void vmrp_api_media_resume(void);\n            extern int vmrp_api_media_seek(int ms);\n            if (media->status == MR_MEDIA_PAUSED && media->pause_pos_ms > 0) {\n                vmrp_api_media_resume();\n                vmrp_api_media_seek(media->pause_pos_ms);\n            } else {\n                vmrp_api_media_resume();\n            }\n            media->status = MR_MEDIA_PLAYING;\n            return MR_SUCCESS;\n        }"
            _dsm_media "${_dsm_media}")
        # 4) 实现 210/212/213/215 (替换整块桩代码)
        string(REPLACE
            "        case MR_MEDIA_SETPOS:\n        case MR_MEDIA_GETTIME:\n        case MR_MEDIA_GET_TOTAL_TIME:\n        case MR_MEDIA_GET_CURTIME:\n        case MR_MEDIA_GET_CURTIME_MSEC: {\n            static T_MEDIA_TIME media_time;\n            media_time.pos = 0;\n            if (output && output_len) {\n                *output = (uint8 *)&media_time;\n                *output_len = sizeof(media_time);\n            }\n            return MR_SUCCESS;\n        }"
            "        case MR_MEDIA_SETPOS: {  /* OHOS_DSM_MEDIA: 210 seek 到指定 ms 位置 */\n            extern int vmrp_api_media_seek(int ms);\n            int32 pos_ms = 0;\n            if (input && input_len >= 4) memcpy2(&pos_ms, input, 4);\n            vmrp_api_media_seek(pos_ms);\n            return MR_SUCCESS;\n        }\n        case MR_MEDIA_GETTIME: {  /* OHOS_DSM_MEDIA: 211 兼容,返回秒 */\n            static T_MEDIA_TIME media_time;\n            extern int vmrp_api_media_position(void);\n            media_time.pos = vmrp_api_media_position() / 1000;\n            if (output && output_len) {\n                *output = (uint8 *)&media_time;\n                *output_len = sizeof(media_time);\n            }\n            return MR_SUCCESS;\n        }\n        case MR_MEDIA_GET_TOTAL_TIME: {  /* OHOS_DSM_MEDIA: 212 返回总时长(秒) */\n            static T_MEDIA_TIME media_time;\n            extern int vmrp_api_media_duration(void);\n            media_time.pos = vmrp_api_media_duration() / 1000;\n            if (output && output_len) {\n                *output = (uint8 *)&media_time;\n                *output_len = sizeof(media_time);\n            }\n            return MR_SUCCESS;\n        }\n        case MR_MEDIA_GET_CURTIME: {  /* OHOS_DSM_MEDIA: 213 返回当前播放位置(秒) */\n            static T_MEDIA_TIME media_time;\n            extern int vmrp_api_media_position(void);\n            media_time.pos = vmrp_api_media_position() / 1000;\n            if (output && output_len) {\n                *output = (uint8 *)&media_time;\n                *output_len = sizeof(media_time);\n            }\n            return MR_SUCCESS;\n        }\n        case MR_MEDIA_GET_CURTIME_MSEC: {  /* OHOS_DSM_MEDIA: 215 返回当前播放位置(毫秒) */\n            static T_MEDIA_TIME media_time;\n            extern int vmrp_api_media_position(void);\n            media_time.pos = vmrp_api_media_position();\n            if (output && output_len) {\n                *output = (uint8 *)&media_time;\n                *output_len = sizeof(media_time);\n            }\n            return MR_SUCCESS;\n        }"
            _dsm_media "${_dsm_media}")
        file(WRITE "${_VMRP_DSM_MEDIA}" "${_dsm_media}")
        message(STATUS "[OHOS] Patched dsm.c media control (OHOS_DSM_MEDIA)")
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

# --- Patch arm_ext_executor.c: T_MOTION_ACC 缓冲区 ---
# 上游 651e421 已实现 arm_ext_host_motion_acc_slot() + motion_acc_addr 字段,
# OHOS 不再注入 motion acc 分配/写入代码。

# --- Patch mythroad.c: dsm_write_motion_acc_to_arm ---
# 上游 651e421 已实现 mr_motion_input()(内部调 arm_ext_host_motion_acc_slot),
# OHOS 不再注入 motion acc 桥接函数。

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

# --- network.c connect 超时补丁已移除 ---
# 上游 ac82d17 重构了 network.c，内置了 connect 超时处理（非阻塞+select），
# 原来的 OHOS_CONNECT_TIMEOUT 正则补丁不再匹配上游函数结构。

# --- Patch aex_table.c: case 38 memset 越界守卫 (OHOS_MEMSET_BOUNDS_GUARD) ---
# 已移除: 上游重构 aex_t038 时移除了 void *ep = arm_ptr(m, a); if (ep) memset(ep,0,want);
# 代码段(改用 arm_ext_scrram_acquire 独立映射),补丁锚点不存在,string(REPLACE) 静默失败。
# 上游 arm_alloc 已有长度守卫(if len > EXT_MEM_SIZE return 0),SCRRAM 独立映射也
# 不再走 arm_alloc,原 memset 越界场景已不存在,无需此补丁。

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
# 上游 5664626 重构了 SCRRAM 处理(独立映射到 0x50000000),锚点改为新注释。
set(_VMRP_AEX_TABLE2 "${VMRP_SRC_DIR}/src/arm_ext/aex_table.c")
if(EXISTS "${_VMRP_AEX_TABLE2}")
    file(READ "${_VMRP_AEX_TABLE2}" _at2)
    if(NOT _at2 MATCHES "OHOS_PLATEX_MEM_EXT")
        string(REPLACE
            "            /* SCRRAM is a separate platform allocation, not an LG_mem/bump"
            "            /* OHOS_PLATEX_MEM_EXT: platEx(1001) 获取屏幕缓冲(第二内存),从 ARM 堆分配\n             * 屏幕大小(SCRW*SCRH*2)的缓冲,guest 代码用返回的 ARM 地址做离屏渲染。\n             * platEx(1002) 释放时清零 addr/len;platEx(1012) 申请内部 cache;\n             * platEx(1013) 释放内部 cache。均与 1014/1015 同模式——ARM 堆分配,\n             * guest 通过写回的 ARM 地址访问,无需 host 指针转换。\n             */\n            if (r0 == 1001) {\n                uint32_t outp = r3, outlenp = arg_read(m, 4);\n                uint32_t want = 0;\n                /* 屏幕缓冲大小: 从 table[92/93] 读 mr_screen_w/h,\n                 * 兜底用 240*320*2=153600 */\n                {\n                    uint32_t sw = 240, sh = 320;\n                    if (m->screen_w_slot) {\n                        void *sp = arm_ptr(m, m->screen_w_slot);\n                        if (sp) memcpy(&sw, sp, 4);\n                    }\n                    if (m->screen_h_slot) {\n                        void *sp = arm_ptr(m, m->screen_h_slot);\n                        if (sp) memcpy(&sh, sp, 4);\n                    }\n                    if (sw < 16 || sw > 1024) sw = 240;\n                    if (sh < 16 || sh > 1024) sh = 320;\n                    want = sw * sh * 2;\n                }\n                uint32_t a = 0;\n                if (want) {\n                    if (m->screen_buf_addr && want <= m->screen_buf_len) {\n                        a = m->screen_buf_addr;\n                    } else {\n                        a = arm_alloc(m, want);\n                        if (a) {\n                            m->screen_buf_addr = a;\n                            m->screen_buf_len = want;\n                            void *ep = arm_ptr(m, a);\n                            if (ep) memset(ep, 0, want);\n                        }\n                    }\n                }\n                if (a) {\n                    if (outp) uc_mem_write(m->uc, outp, &a, 4);\n                    if (outlenp) uc_mem_write(m->uc, outlenp, &want, 4);\n                }\n                ret = a ? MR_SUCCESS : MR_FAILED;\n                goto aex_done;\n            }\n            if (r0 == 1002) {\n                m->screen_buf_addr = 0;\n                m->screen_buf_len = 0;\n                ret = MR_SUCCESS;\n                goto aex_done;\n            }\n            if (r0 == 1012) {\n                uint32_t outp = r3, outlenp = arg_read(m, 4);\n                uint32_t want = (uint32_t)r2;\n                uint32_t a = 0;\n                if (want) {\n                    if (m->iram_addr && want <= m->iram_len) {\n                        a = m->iram_addr;\n                    } else {\n                        a = arm_alloc(m, want);\n                        if (a) {\n                            m->iram_addr = a;\n                            m->iram_len = want;\n                            void *ep = arm_ptr(m, a);\n                            if (ep) memset(ep, 0, want);\n                        }\n                    }\n                }\n                if (a) {\n                    if (outp) uc_mem_write(m->uc, outp, &a, 4);\n                    if (outlenp) uc_mem_write(m->uc, outlenp, &want, 4);\n                }\n                ret = a ? MR_SUCCESS : MR_IGNORE;\n                goto aex_done;\n            }\n            if (r0 == 1013) {\n                m->iram_addr = 0;\n                m->iram_len = 0;\n                ret = MR_SUCCESS;\n                goto aex_done;\n            }\n            /* SCRRAM is a separate platform allocation, not an LG_mem/bump"
            _at2 "${_at2}")
        file(WRITE "${_VMRP_AEX_TABLE2}" "${_at2}")
        message(STATUS "[OHOS] Patched platEx(1001/1002/1012/1013) in aex_table.c (OHOS_PLATEX_MEM_EXT)")
    endif()
endif()

# --- Patch arm_ext_executor.c: arm_ext_call_dispatch 中 mr_timerStart 不覆盖 ARM 侧已设的 timer ---
# 已移除: 上游重构了 arm_ext_call_dispatch,新增 arm_ext_call_primary_compact_dispatch
# 路径并统一了 host_timer_pending 门控。旧补丁锚点(if (queue_live) / if (tc_after))
# 已不存在,string(REPLACE) 静默失败,补丁无任何效果。上游已正确处理 ARM 侧 timer
# 不被 50ms 覆盖的问题,无需此补丁。

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

# --- Patch mythroad.c: mr_start_dsmB / mr_start_dsmC / mr_start_dsm_ex ---
# 三个外部移植接口: mr_start_dsmB(entry) 以 entry 为 filename 启动,
# mr_start_dsmC(entry) 同 dsmB 但冷启动时先 dsm_init,
# mr_start_dsm_ex(path, entry) 显式 path+entry。
# 均为 mr_start_dsm 的薄封装,解析 entry 中的 */% 前缀后调 _mr_intra_start。
set(_VMRP_DSMBC "${VMRP_SRC_DIR}/src/mythroad/mythroad.c")
if(EXISTS "${_VMRP_DSMBC}")
    file(READ "${_VMRP_DSMBC}" _dsm_bc)
    if(NOT _dsm_bc MATCHES "OHOS_DSM_BC_EX")
        string(REPLACE
            "int32 mr_stop_ex(int16 freemem) {"
            "/* OHOS_DSM_BC_EX: 外部移植接口 mr_start_dsmB/C/ex\n * (SkyEngine API 参考手册 / 外部移植接口)\n *\n * mr_start_dsmB(const char *entry):\n *   直接启动 mrp 文件,entry 含启动标志(*A=固化应用,%QQ.mrp=根目录mrp)。\n *   等价 mr_start_dsm(entry, NULL, NULL),ext 默认 MR_START_FILE。\n *\n * mr_start_dsmC(const char *entry):\n *   同 dsmB,但冷启动时先 dsm_init 初始化引擎再启动。\n *   用于宿主首次启动虚拟机的场景。\n *\n * mr_start_dsm_ex(const char *path, const char *entry):\n *   显式 path(=filename) + entry 入口标志。\n *   等价 mr_start_dsm(path, NULL, entry)。\n */\nint32 mr_start_dsmB(const char *entry) {\n    if (!entry) entry = \"*A\";\n    return mr_start_dsm((char *)entry, NULL, NULL);\n}\n\nint32 mr_start_dsmC(const char *entry) {\n    /* dsmC 与 dsmB 等效,因为 OHOS 宿主总是先调 vmrp_api_init\n     * (内部 dsm_init)再调 start。dsm_init 重复调用是安全的\n     * (dsm.c: 仅赋值 dsmInFuncs + 重置状态)。 */\n    return mr_start_dsmB(entry);\n}\n\nint32 mr_start_dsm_ex(const char *path, const char *entry) {\n    return mr_start_dsm((char *)path, NULL, (char *)entry);\n}\n\nint32 mr_stop_ex(int16 freemem) {"
            _dsm_bc "${_dsm_bc}")
        file(WRITE "${_VMRP_DSMBC}" "${_dsm_bc}")
        message(STATUS "[OHOS] Patched mr_start_dsmB/C/ex in mythroad.c (OHOS_DSM_BC_EX)")
    endif()
endif()

# --- Patch dsm.c: OHOS_SET_VOL — mr_plat(MR_SET_VOL=1302) 音量控制 ---
# MRP 应用调 mr_plat(1302, level) 设置音量,level 通常 0~10(0=静音,10=最大)。
# 上游无实现(fall through → MR_IGNORE)。修复:存储 level 并通知宿主调
# OH_AudioRenderer_SetVolume。不在此做软件缩放,避免与 OHAudio renderer 音量双算。
set(_VMRP_DSM_VOL "${VMRP_SRC_DIR}/src/mythroad/dsm.c")
if(EXISTS "${_VMRP_DSM_VOL}")
    file(READ "${_VMRP_DSM_VOL}" _dsm_vol)
    if(NOT _dsm_vol MATCHES "OHOS_SET_VOL")
        # 锚点: 动感芯片 case 4006 之后、default 之前插入 MR_SET_VOL。
        # 上游在 MR_SET_KEY_END 和 default 之间新增了 case 4001~4006(动感芯片),
        # 旧锚点(MR_SET_KEY_END ... default)失效,改用 4006 作为锚点。
        string(REPLACE
            "        case 4006:  // 量程查询:返回 A(>1000),上送分量范围 ±(A-1000)\n            return 1000 + DSM_MOTION_ACC_MAX;\n        default:"
            "        case 4006:  // 量程查询:返回 A(>1000),上送分量范围 ±(A-1000)\n            return 1000 + DSM_MOTION_ACC_MAX;\n        case MR_SET_VOL: {  /* OHOS_SET_VOL: 1302 音量控制, param=0~10 */\n            extern void vmrp_api_set_volume(int level);\n            vmrp_api_set_volume(param);\n            return MR_SUCCESS;\n        }\n        default:"
            _dsm_vol "${_dsm_vol}")
        file(WRITE "${_VMRP_DSM_VOL}" "${_dsm_vol}")
        message(STATUS "[OHOS] Patched dsm.c MR_SET_VOL (OHOS_SET_VOL)")
    endif()
endif()

# --- Patch mythroad.c: _mr_intra_start 空入口 fallback ---
# 注意: 上游 2832b0e 已完整修复 cookie 子mrp启动/退出/页面恢复。
# 移除 OHOS_CASE800_DIAG（空入口fallback）和 OHOS_HANDOFF_FIX（table[138]回读+STOP不回读）。
# 上游通过 table[138] 128字节二进制缓冲 + dsm_work_path 重置 + pack 路径还原解决。
# 保留的 OHOS 独有补丁: OHOS_SUBV_ARM_PTR + OHOS_SUBV_GETNATEXT。

# --- Patch mythroad.c: arm_ext_get_native_ext_impl getter (OHOS_SUBV_ARM_PTR) ---
# native_ext 是 static 变量,arm_ext_executor.c 无法直接 extern。
# 在 native_ext_reset() 之后插入 getter,供 mr_subv_to_arm_ptr 使用。
set(_VMRP_NATEXT_GET "${VMRP_SRC_DIR}/src/mythroad/mythroad.c")
if(EXISTS "${_VMRP_NATEXT_GET}")
    file(READ "${_VMRP_NATEXT_GET}" _neg)
    if(NOT _neg MATCHES "OHOS_SUBV_GETNATEXT")
        string(REPLACE
            "    native_resumeApp_function = 0;\n}\n\nstatic int32 native_ext_event"
            "    native_resumeApp_function = 0;\n}\n\n/* OHOS_SUBV_GETNATEXT: 返回当前 native_ext 指针,供 mr_subv_to_arm_ptr 使用。 */\nvoid* arm_ext_get_native_ext_impl(void) { return (void*)native_ext; }\n\nstatic int32 native_ext_event"
            _neg "${_neg}")
        file(WRITE "${_VMRP_NATEXT_GET}" "${_neg}")
        message(STATUS "[OHOS] Patched mythroad.c native_ext getter (OHOS_SUBV_GETNATEXT)")
    endif()
endif()

# --- Patch mythroad.c: RESTART场景保留ARM ext内存(OHOS_PRESERVE_EXT) ---
# 上游 2832b0e 已修复 cookie 返回页面问题(table[138] 128B + sync_start_parameter +
# pack path 还原 + dsm_work_path 重置)。移除实验性 PRESERVE_EXT 补丁。

# --- Patch arm_ext_executor.c: arm_ext_pack_host_path accessor (OHOS_PRESERVE_EXT) ---
# 上游已覆盖,移除。

# --- Patch mr_strlib.c: string.subV 返回 ARM 可见地址（修复 64 位指针截断）---
# OHOS_SUBV_ARM_PTR: string.subV 把 Lua 字符串的 C 指针返回给 Lua 层，Lua 层再通过
# string.pack("iii", 5001, ptr, len) 把 ptr 打包传给 ARM ext(arm_ext_call code=1)。
# 真机 32 位：ptr 是有效的 ARM 地址。OHOS 64 位：ptr 是 64 位宿主地址，截断为 32 位后
# ARM ext(Unicorn)无法通过它访问字符串内容 → cookie 收不到 _mr_param → 页面不恢复。
# 修复：str_subV 调用弱符号 mr_subv_to_arm_ptr(str, len)，把字符串拷贝到 Unicorn ARM
# 内存并返回 32 位 ARM 地址。弱符号未定义时回退原始行为（兼容非 ARM ext 模式）。
set(_VMRP_STRLIB "${VMRP_SRC_DIR}/src/mythroad/src/lib/mr_strlib.c")
if(EXISTS "${_VMRP_STRLIB}")
    file(READ "${_VMRP_STRLIB}" _sl)
    if(NOT _sl MATCHES "OHOS_SUBV_ARM_PTR")
        string(REPLACE
            "static int str_subV (mrp_State *L) {\n  size_t l_sz;\n  int32 l;\n  char * p = (char*)mr_L_checklstring(L, 1, &l_sz);\n  l = (int32)l_sz;\n  mrp_pushnumber(L, (mrp_Number)p);\n  mrp_pushnumber(L, (mrp_Number)l);\n  return 2;\n}"
            "/* OHOS_SUBV_ARM_PTR: 弱符号,由 arm_ext_executor.c 实现。\n * 把字符串拷贝到 Unicorn ARM 内存,返回 32 位 ARM 地址。\n * 未定义时回退原始行为(返回宿主指针,仅 32 位平台有效)。 */\n__attribute__((weak)) uint32 mr_subv_to_arm_ptr(const char *str, int32 len);\nstatic int str_subV (mrp_State *L) {\n  size_t l_sz;\n  int32 l;\n  char * p = (char*)mr_L_checklstring(L, 1, &l_sz);\n  l = (int32)l_sz;\n  if (mr_subv_to_arm_ptr) {\n      uint32 arm_ptr = mr_subv_to_arm_ptr(p, l);\n      if (arm_ptr) {\n          mrp_pushnumber(L, (mrp_Number)arm_ptr);\n          mrp_pushnumber(L, (mrp_Number)l);\n          return 2;\n      }\n  }\n  mrp_pushnumber(L, (mrp_Number)p);\n  mrp_pushnumber(L, (mrp_Number)l);\n  return 2;\n}"
            _sl "${_sl}")
        file(WRITE "${_VMRP_STRLIB}" "${_sl}")
        message(STATUS "[OHOS] Patched mr_strlib.c str_subV ARM ptr (OHOS_SUBV_ARM_PTR)")
    endif()
endif()

# --- Patch arm_ext_executor.c: 实现 mr_subv_to_arm_ptr ---
# 把宿主字符串拷贝到 Unicorn ARM 内存,返回 32 位 ARM 地址。
# ARM ext 通过 arm_ext_call(code=1) 收到的 buffer 中的 ptr 字段即可正确访问字符串。
set(_VMRP_ARMEXT_SUBV "${VMRP_SRC_DIR}/src/arm_ext_executor.c")
if(EXISTS "${_VMRP_ARMEXT_SUBV}")
    file(READ "${_VMRP_ARMEXT_SUBV}" _aesubv)
    if(NOT _aesubv MATCHES "OHOS_SUBV_ARM_PTR")
        string(REPLACE
            "void arm_ext_unload(ArmExtModule *m) {"
            "/* OHOS_SUBV_ARM_PTR: 把宿主字符串拷贝到当前 native_ext 的 Unicorn ARM 内存,\n * 返回 32 位 ARM 地址。供 string.subV 使用:Lua 层拿到 ARM 地址后通过\n * string.pack 打包传给 ARM ext,ARM ext 能正确访问字符串内容。\n * 拷贝到 origin_mem 池(与 ext 的 mr_malloc 同池),ext 的 mrc_init 后即可释放。 */\nuint32 mr_subv_to_arm_ptr(const char *str, int32 len) {\n    extern void* arm_ext_get_native_ext_impl(void);\n    ArmExtModule *ext = (ArmExtModule *)arm_ext_get_native_ext_impl();\n    if (!ext || !str || len <= 0) return 0;\n    uint32_t arm_addr = arm_alloc(ext, (uint32_t)(len + 1));\n    if (!arm_addr) return 0;\n    char *dst = (char *)arm_ptr(ext, arm_addr);\n    if (!dst) return 0;\n    memcpy(dst, str, len);\n    dst[len] = 0;\n    return arm_addr;\n}\n\nvoid arm_ext_unload(ArmExtModule *m) {"
            _aesubv "${_aesubv}")
        file(WRITE "${_VMRP_ARMEXT_SUBV}" "${_aesubv}")
        message(STATUS "[OHOS] Patched arm_ext_executor.c mr_subv_to_arm_ptr impl (OHOS_SUBV_ARM_PTR)")
    endif()
endif()

# --- Patch arm_ext_executor.c: table[138]回读 + STOP不回读 ---
# 上游 2832b0e 已通过 arm_ext_sync_start_parameter_slot + alloc_start_parameter_table_slot
# + mr_reset_dsm_work_path 完整覆盖。移除 OHOS_HANDOFF_FIX。

# --- Patch network.c: select 超时 50ms→5ms + printf→VMRP_NET_LOG (OHOS_NET_SPEEDUP) ---
# 下载热路径优化:
# 1) checkReadable/checkWritable 的 select 超时从 50ms 降到 5ms。
#    有数据时 select 立即返回,无数据时从等满 50ms 降到 5ms,减少空等。
# 2) my_send/my_recv 高频 printf 替换为 VMRP_NET_LOG 宏(默认不输出,
#    仅设了 VMRP_NETWORK_LOG/VMRP_LOG 环境变量时才打日志)。
#    去掉每次 recv 往返 3+ 行 printf 的 I/O 开销。
set(_VMRP_NET "${VMRP_SRC_DIR}/src/network.c")
if(EXISTS "${_VMRP_NET}")
    file(READ "${_VMRP_NET}" _net)
    if(NOT _net MATCHES "OHOS_NET_SPEEDUP")
        # 1) checkReadable: 50ms → 5ms
        string(REPLACE
            "    struct timeval timeout = {\n        .tv_sec = 0,\n        .tv_usec = 1000 * 50  // 50ms\n    };\n\n    SOCKET_T max_sd = socket;\n    int ret = select(max_sd + 1, &readfds, NULL, NULL, &timeout);"
            "    /* OHOS_NET_SPEEDUP: select 超时 50ms→5ms,减少无数据时的空等开销。 */\n    struct timeval timeout = {\n        .tv_sec = 0,\n        .tv_usec = 1000 * 5  // 5ms\n    };\n\n    SOCKET_T max_sd = socket;\n    int ret = select(max_sd + 1, &readfds, NULL, NULL, &timeout);"
            _net "${_net}")
        # 2) checkWritable: 50ms → 5ms
        string(REPLACE
            "    struct timeval timeout = {\n        .tv_sec = 0,\n        .tv_usec = 1000 * 50  // 50ms\n    };\n\n    SOCKET_T max_sd = socket;\n    int ret = select(max_sd + 1, NULL, &writefds, NULL, &timeout);"
            "    /* OHOS_NET_SPEEDUP: select 超时 50ms→5ms,减少不可写时的空等开销。 */\n    struct timeval timeout = {\n        .tv_sec = 0,\n        .tv_usec = 1000 * 5  // 5ms\n    };\n\n    SOCKET_T max_sd = socket;\n    int ret = select(max_sd + 1, NULL, &writefds, NULL, &timeout);"
            _net "${_net}")
        # 3) my_send: printf → VMRP_NET_LOG
        string(REPLACE
            "    printf(\"my_send(s:%d, fd:%d, len:%d): sent=%d, errno=%d\\n\", s, (int)data->s, len, ret, errno);\n    printf(\"[my_send] data: %s\\n\", buf);"
            "    VMRP_NET_LOG(\"my_send(s:%d, fd:%d, len:%d): sent=%d, errno=%d\\n\", s, (int)data->s, len, ret, errno);\n    VMRP_NET_LOG(\"[my_send] data: %s\\n\", buf);"
            _net "${_net}")
        # 4) my_recv: printf → VMRP_NET_LOG (checkReadable 行)
        string(REPLACE
            "    printf(\"my_recv(s:%d, fd:%d, len:%d): checkReadable=%d\\n\", s, (int)data->s, len, ret);"
            "    VMRP_NET_LOG(\"my_recv(s:%d, fd:%d, len:%d): checkReadable=%d\\n\", s, (int)data->s, len, ret);"
            _net "${_net}")
        # 5) my_recv: printf → VMRP_NET_LOG (recv 结果行)
        string(REPLACE
            "    printf(\"my_recv(s:%d): recv=%d, errno=%d\\n\", s, ret, errno);"
            "    VMRP_NET_LOG(\"my_recv(s:%d): recv=%d, errno=%d\\n\", s, ret, errno);"
            _net "${_net}")
        # 6) my_recv: printf → VMRP_NET_LOG (data preview 行)
        string(REPLACE
            "        printf(\"my_recv data: [%s]\\n\", preview);"
            "        VMRP_NET_LOG(\"my_recv data: [%s]\\n\", preview);"
            _net "${_net}")
        # 7) OHOS_NET_NULLGUARD: 所有 socket 函数在 uIntMap_search 后加 NULL 检查。
        # 游戏可能传入已关闭/无效的 socket id, uIntMap_search 返回 NULL 时
        # 直接 obj->data 解引用 → SIGSEGV。string(REPLACE) 默认替换所有匹配。
        string(REPLACE
            "    uIntMap* obj = uIntMap_search(&sockets, (uint32_t)s);\n    mSocket* data = (mSocket*)obj->data;"
            "    uIntMap* obj = uIntMap_search(&sockets, (uint32_t)s);\n    if (!obj) return MR_FAILED; /* OHOS_NET_NULLGUARD */\n    mSocket* data = (mSocket*)obj->data;"
            _net "${_net}")
        # my_getSocketState 用了变量名 p 而非 data,单独处理
        string(REPLACE
            "    uIntMap* obj = uIntMap_search(&sockets, (uint32_t)s);\n    mSocket* p = ((mSocket*)obj->data);"
            "    uIntMap* obj = uIntMap_search(&sockets, (uint32_t)s);\n    if (!obj) return MR_FAILED; /* OHOS_NET_NULLGUARD */\n    mSocket* p = ((mSocket*)obj->data);"
            _net "${_net}")
        file(WRITE "${_VMRP_NET}" "${_net}")
        message(STATUS "[OHOS] Patched network.c select 5ms + printf→VMRP_NET_LOG + NULL guard (OHOS_NET_SPEEDUP)")
    endif()
endif()

# --- Patch vmrp_api.c: async worker timer 停止时保持心跳 (OHOS_WORKER_HEARTBEAT) ---
# 已移除: op6120 卡死的根因是 origin_mem_len 过大(用户设 16MB 内存 → clamp 8MB),
# 导致 ARM 代码 exRam 预算计算溢出。设置里选 1MB 内存即可正常,不需要此补丁。

# --- Patch arm_ext_executor.c: origin_mem_len 固定 1MB (OHOS_HEAP_FIX) ---
# 已移除: 用户在设置里选 1MB 内存即可。origin_mem_len = vmrp_memory_bytes(1) = 1MB,
# 跟真机标准一致。不需要强制覆盖。

# --- Diagnostic patches removed (OHOS_CODE2_HELPER / OHOS_TIMER_PATH) ---

# 已移除: Pattern D 会把 op6120 等游戏从能工作的 native_ext_void_event(2) 路径
# 推到 arm_ext_call_dispatch 路径,但该路径的 queue liveness 检查对 op6120 的
# timer 结构不兼容(队列在 socket 等待期间空 → host timer 不重 arm → 卡死)。
# 上游也无 Pattern D,op6120 在上游走 code=2 正常工作,故此处保持不补丁。

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


