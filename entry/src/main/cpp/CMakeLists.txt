# HarmonyOS entry native 模块 CMakeLists.txt
# 构建 libentry.so（NAPI 桥接层），链接预构建的 libvmrp.so + 鸿蒙系统库。
cmake_minimum_required(VERSION 3.5.0)
project(vmrp_entry)

set(CMAKE_CXX_STANDARD 17)

# vmrp_api.h 头文件
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/include)

add_library(vmrp_entry SHARED
    vmrp_napi.cpp
    vmrp_engine.cpp
    vmrp_renderer.cpp
    vmrp_audio.cpp
)
# 输出名为 libentry.so：XComponent(libraryname:'entry') 按 libentry.so 加载。
# nm_modname 也必须是 "entry"（见 vmrp_napi.cpp 的 napi_module），二者一致。
set_target_properties(vmrp_entry PROPERTIES OUTPUT_NAME "entry")

# 预构建的 libvmrp.so（含 Unicorn arm-softmmu 软件模拟 ARM32）。
# 按 ohos.toolchain.cmake 设置的 OHOS_ARCH 选择对应 ABI 的预构建产物。
# 鸿蒙真机用 arm64-v8a，模拟器用 x86_64，两者都已由预构建脚本生成。
if(NOT DEFINED OHOS_ARCH)
    set(OHOS_ARCH "arm64-v8a")
endif()
add_library(vmrp_prebuilt SHARED IMPORTED)
set_target_properties(vmrp_prebuilt PROPERTIES
    IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/${OHOS_ARCH}/libvmrp.so
)

# 鸿蒙系统库：
#   libace_napi.z.so      - NAPI 运行时
#   libace_ndk.z.so       - XComponent
#   libhilog_ndk.z.so     - 日志
#   libEGL.so/libGLESv3.so- 图形（sysroot 提供）
#   libohaudio.so         - OHAudio（renderer/builder，pull 模型音频）
target_link_libraries(vmrp_entry PUBLIC
    vmrp_prebuilt
    libace_napi.z.so
    libace_ndk.z.so
    libhilog_ndk.z.so
    EGL
    GLESv3
    libohaudio.so
    libnative_window.so
)
