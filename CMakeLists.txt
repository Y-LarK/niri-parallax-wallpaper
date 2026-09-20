# Clavis 原生模块最小构建
#
# 从 Clavis (StatIndet/quickshell) 中提取所需的最小原生模块：
#   Clavis.Niri      —— 视差壁纸读取 niri 状态
#   Clavis.Keyboard  —— 启动器检测修饰键
#
# Clavis 原版 core/CMakeLists.txt 含全局硬依赖（Qt6Keychain / Pipewire / Cava
# 均 REQUIRED），此处完全不涉及。
#
# 源码文件均从 Clavis 原样复制，未作任何修改。
cmake_minimum_required(VERSION 3.21)

project(NiriDesktopShell LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick Network)
find_package(PkgConfig REQUIRED)

qt_standard_project_setup()

# ---------------------------------------------------------------- 核心库
# niri IPC 客户端 / 工作区与窗口模型 / 输出模型 / 桌面文件图标查找
qt_add_library(ClavisNiriCore STATIC)
target_sources(ClavisNiriCore PRIVATE
    niri/niri_types.h
    niri/niri_icon_lookup.h
    niri/niri_icon_lookup.cpp
    niri/niri_ipc_client.h
    niri/niri_ipc_client.cpp
    niri/niri_workspace_deriver.h
    niri/niri_workspace_deriver.cpp
    niri/niri_workspace_model.h
    niri/niri_workspace_model.cpp
    niri/niri_window_model.h
    niri/niri_window_model.cpp
    niri/niri_output_model.h
    niri/niri_output_model.cpp
)
set_target_properties(ClavisNiriCore PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_link_libraries(ClavisNiriCore PRIVATE Qt6::Core Qt6::Network)
target_include_directories(ClavisNiriCore PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/niri)

# ---------------------------------------------------------- QML 模块：Niri
# 对 QML 侧暴露为 `import Clavis.Niri`，提供 Niri 单例
qt_add_library(ClavisNiri SHARED)

qt_add_qml_module(ClavisNiri
    URI Clavis.Niri
    SOURCES
        niri/niri_plugin.h
        niri/niri_plugin.cpp
    OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/qml/Clavis/Niri
)

set_target_properties(ClavisNiri PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/qml/Clavis/Niri
)

target_link_libraries(ClavisNiri PRIVATE
    ClavisNiriCore
    Qt6::Core
    Qt6::Gui
    Qt6::Qml
    Qt6::Network
)

# ------------------------------------------------------ QML 模块：Keyboard
# 全局修饰键检测（启动器用它判断 Ctrl 是否按住以切换模式）。
# 与 Clavis 原版一致，额外需要 xkbcommon 做键名解析。
pkg_check_modules(XkbCommon REQUIRED IMPORTED_TARGET xkbcommon)

qt_add_library(ClavisKeyboard SHARED)

qt_add_qml_module(ClavisKeyboard
    URI Clavis.Keyboard
    SOURCES
        keyboard/shortcut_recorder.h
        keyboard/shortcut_recorder.cpp
    OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/qml/Clavis/Keyboard
)

set_target_properties(ClavisKeyboard PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/qml/Clavis/Keyboard
)

target_include_directories(ClavisKeyboard PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/keyboard)

target_link_libraries(ClavisKeyboard PRIVATE
    Qt6::Quick
    Qt6::Gui
    PkgConfig::XkbCommon
    Qt6::Core
    Qt6::Qml
)
