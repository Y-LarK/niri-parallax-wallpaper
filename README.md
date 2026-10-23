# niri-parallax-wallpaper

[niri](https://github.com/YaLTeR/niri) 的桌面壳层：视差壁纸 + 启动器 + 电源菜单，同进程运行，基于 [Quickshell](https://quickshell.org/) 与 Qt 6 / QML / 原生 C++ 模块。

## 来源与许可

本项目从 [StatIndet/quickshell](https://github.com/StatIndet/quickshell)提取移植而来：

- `niri/`、`keyboard/` 目录下的 C++ 源码原样取自上游（Clavis.Niri / Clavis.Keyboard 两个 QML 模块）；
- `qml/` 下的壁纸视差实现移植自上游，启动器与电源菜单为参照上游重写的独立实现；
- `CMakeLists.txt` 为本项目的最小化构建（上游的 QtKeychain / Pipewire / Cava 硬依赖全部去除，只保留 Qt6 + xkbcommon）。

依据上游的 GPL-3.0 许可，本项目同样以 **GPL-3.0** 发布，见 [LICENSE](LICENSE)。

## 功能

**视差壁纸**

- 横向视差跟随平铺列焦点（自适应列数跨度：第一列对齐图片最左端，最后一列对齐最右端），纵向跟随工作区可开关
- 焦点列记忆：浮窗获得焦点时壁纸不乱跳，切回工作区恢复原位
- 图片宽高比与屏幕相差 ≤5% 时判定为「为这块屏准备」，视差自动禁用、完整铺满
- 4 种填充模式（Fill / Fit / Stretch / panorama 全景）与 6 种 ShaderEffect 转场
  （fade / wipe / disc / stripes / iris bloom / portal），可随机抽取或指定
- niri overview（Mod+O）背景层：独立壁纸、模糊、调暗、饱和度均可配

**启动器**

- 应用模糊搜索（显示名子序列匹配 + 辅助字段精确匹配）
- 输入 `/w` / `壁纸` / `wallpaper` 进入壁纸选择模式：缩略图网格挑选，回车换壁纸
- 列表 / 图标墙双视图（Ctrl+G 切换，本次运行期间保持）
- 网址直开与网页搜索（Google / Bing / Baidu / DuckDuckGo 等，见 `SearchEngines.js`）

**电源菜单**

- Quickshell 实现，替代 rofi（锁定 / 注销 / 重启 / 关机等）

## 依赖

| 组件         | 说明                                                   |
| ------------ | ------------------------------------------------------ |
| niri         | 合成器，壁纸几何与 IPC 依赖其事件流                    |
| Quickshell   | 已在 v0.3.1 验证；源码构建（提供 `quickshell` 二进制） |
| Qt 6         | Core / Gui / Qml / Quick / Network                     |
| xkbcommon    | pkg-config 可发现（键盘模块键名解析用）                |
| CMake ≥ 3.21 | 支持 C++20 的编译器                                    |

## 构建与启动

```bash
# 1. 构建原生 QML 模块（产物在 build/qml/Clavis/ 下）
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build

# 2. 启动（QML_IMPORT_PATH 指向构建产物的 qml 目录）
QML_IMPORT_PATH="$PWD/build/qml" quickshell -p "$PWD/qml/shell.qml"
```

日常使用建议以 systemd 用户服务常驻（`WantedBy=niri.service`，`Restart=on-failure`），
`ExecStart` 即上面第 2 步的命令。

## 配置

所有可调项集中在 [`qml/ParallaxConfig.js`](qml/ParallaxConfig.js)，每项都有注释说明取舍：
壁纸路径、视差开关与放大倍率、填充模式、转场类型与时长、overview 背景、
启动器面板尺寸 / 配色 / 动画 / 圆角、搜索引擎等。改动后重启实例生效
（Quickshell 的热重载只覆盖 `.qml`，`.js` 配置不在其列）。

## Shaders（换图转场）

`qml/shaders/` 下每个转场是成对的两份文件：`wp_<名称>.frag` 为 GLSL 源码，
`wp_<名称>.frag.qsb` 为 Qt Shader Tools 的编译产物（QML 侧加载的是后者）。
修改源码后用 `qsb` 重新生成，例如：

```bash
qsb --glsl 100es,120 --hlsl 50 --msl 12 -o wp_fade.frag.qsb wp_fade.frag
```

`qsb` 由 `qt6-qtshadertools` 包提供。

## IPC

```bash
export QS_CONFIG_PATH="$PWD/qml/shell.qml"

quickshell ipc call wallpaper set /path/to/image.jpg   # 换壁纸（带转场）
quickshell ipc call wallpaper get                       # 读回当前壁纸路径
quickshell ipc call launcher toggle                     # 开关启动器
```

## 致谢

- [StatIndet/quickshell](https://github.com/StatIndet/quickshell) —— 本项目的上游，原生模块与壁纸实现均源于此
- [niri](https://github.com/YaLTeR/niri) · [Quickshell](https://quickshell.org/)

## License

[GPL-3.0](LICENSE)
