.pragma library

// 视差壁纸配置
// 改完此文件后重启视差层生效（quickshell -p <此目录>/shell.qml）

// ---------------------------------------------------------------- 壁纸
// 绝对路径，单张图片
var wallpaperPath = "/home/ylk/Pictures/wallpapers/29CFD092017091EF98BD16CA3C9B18F2.png"

// ------------------------------------------------------------ 视差开关
// 纵向：跟随 niri 工作区上下滚动。已关闭 —— 纵向位移在日常使用里收益很小，
// 却要把画布上下放大、白白裁掉图片边缘（详见下方 preferredScale 的说明）。
var verticalEnabled = false
var horizontalEnabled = true // 横向：跟随平铺列焦点左右移动

// 「大小合适」判定：图片宽高比与屏幕相差在这个比例以内时，认为这张图就是为
// 当前屏幕准备的 —— 直接铺满即可，横纵视差一律不生效。靠平移去「找画面」
// 只会让边缘被裁掉，反而损失内容。
//   0.05 = 5%： 1920×1200 (1.60) 对 1.60 的屏 → 不动，完整铺满
//               3840×2160 (1.78) 差 11%       → 启用视差
var aspectMatchTolerance = 0.05

// ---------------------------------------------------------------- 几何
// 画布放大倍率。1.0 表示不放大（无位移余量），建议 1.05 ~ 1.35。
// 越大可平移的幅度越大，但图片被裁掉的部分也越多。
// 只作用于横向：verticalEnabled 为 false 时纵向不放大，图片上下完整显示，
// 不做换不来位移的无谓裁切。
var preferredScale = 1.1

// 横向位移跨度是自适应的：第一列对齐图片最左端，最后一列对齐最右端，
// 于是无论当前工作区开了几列，切到最后一列都能把整张图走完。
// （这里原先有个 tiledColumnSpan = 6 的固定值，列数少于它时永远走不满 ——
//   例如只开 3 列最多只能移到 40%，图片右半边永远看不到，已于 2026-09-16 移除。）

// 跨度下限，按「相当于几列」计。跨度取 max(实际列数, 此值)：
// 列太少时步长会很大（2 列就是「最左一步跨到最右」），用下限压一压；
// 列数达到此值后即可走完整张图。
//   4 → 2 列走 1/3，3 列走 2/3，4 列及以上走完
//   2 → 等于不设下限，列少时步长最大
var minColumnSpan = 4

// 填充模式：
//   "Fill"     —— 铺满屏幕并裁切多余部分（默认）
//   "Fit"      —— 完整显示整张图，可能留黑边
//   "Stretch"  —— 拉伸变形以铺满屏幕
//   "panorama" —— 仅当图片比屏幕更宽时生效：画布按图片原比例展开，
//                 横向可平移的幅度远大于 Fill，且不做放大裁切。
//                 注意：panorama 激活时 preferredScale 不再起作用。
var fillMode = "panorama"

// ---------------------------------------------------------------- 动画
var animationDuration = 400 // 毫秒

// 缓动曲线：QML Easing.Type 枚举数值（.js 中无法 import QtQuick，故写数值）
// 0=Linear 1=InQuad 2=OutQuad 3=InOutQuad 4=InCubic 5=OutCubic 6=InOutCubic
var animationEasing = 5 // OutCubic

// ------------------------------------------------------------ 换图转场
// "random" —— 每次从 includedTransitions 里随机挑一种（推荐）
// "none"   —— 不做转场，直接切换
// 也可写死一种：fade / wipe / disc / stripes / iris bloom / pixelate / portal
var transitionType = "random"

// random 模式下参与抽取的效果池
var includedTransitions = ["fade", "wipe", "disc", "stripes", "iris bloom", "pixelate", "portal"]

// 转场时长（毫秒）
var transitionDurationMs = 1000

// 总开关，false 时等价于 transitionType = "none"
var transitionsEnabled = true

// ------------------------------------------------------ niri overview 背景
// overview（Mod+O）是独立的 layer-shell 表面，不参与视差（与 Clavis 设计一致）。
// 它覆盖在 niri 自己的 backdrop-color 之上；设为 false 则回落到 niri 的纯色背景。

var overviewEnabled = true

// true  = 直接跟随桌面壁纸（换图时 overview 也跟着换）
// false = 使用下面的 overviewWallpaperPath 单独指定一张
var overviewUseDesktopWallpaper = true

// 独立壁纸路径（仅当 overviewUseDesktopWallpaper 为 false 时生效）
var overviewWallpaperPath = ""

// overview 的填充模式（取值同上面的 fillMode，但 "panorama" 在 overview 里无意义，
// 因为 overview 不跟随工作区/列焦点，会退化为静态 Fill）
var overviewFillMode = "Fill"

// 背景模糊半径，0 = 不模糊。建议 0 ~ 64，值越大越糊（性能开销也越大）
var overviewBlurRadius = 0

// 调暗程度，0 = 不调暗，1 = 全黑。用于让 overview 里的窗口更突出
var overviewDim = 0.35

// 饱和度与对比度，1.0 = 保持原样
var overviewSaturation = 1.0
var overviewContrast = 1.0

// overview 换图时的转场类型（写死一种，不用 random 以免和桌面转场混淆）
var overviewTransitionType = "fade"

// ---------------------------------------------------------------- 启动器
// 视图样式："list"（列表）或 "grid"（图标墙）。
// 运行时可用 Ctrl+G 临时切换，这里的值只决定每次打开时的默认样式。
var launcherViewStyle = "grid"

// 面板尺寸上限（实际还会受屏幕尺寸约束）
var launcherListWidth = 640
var launcherGridWidth = 920
var launcherMaxHeight = 560

// 面板不透明度：1 = 完全不透明，越小越透。
//
// **这一项与 niri 侧的模糊是一对，必须同进同退。** 依赖
// ~/.config/niri/config.kdl 里 namespace 为 niri-launcher 的 layer-rule
// （2026-09-20 重新开启，xray false）。没有模糊兜底时，半透明会让面板底下的内容
// （终端文字之类）直接渗上来、跟图标文字叠在一起，观感非常脏 —— 那正是
// 2026-09-15 ~ 2026-09-20 期间这一项被压到 0.9 的原因。
// 关掉那条 layer-rule 就必须把这里调回 0.9，反之才能往下调。
// 参考：kitty 的 background_opacity 是 0.75（那边一直有模糊兜底）。
//
// 面板背景用哪个色源，取 colors.json 里的 Material 角色名。关键取舍：
//   surface* 族（surfaceContainerLow / surfaceContainer / surfaceContainerHigh /
//              surfaceContainerHighest / surfaceBright）
//        —— Material You 的 dark scheme 里是**固定中性灰，不随壁纸变化**
//   primary / primaryContainer / secondary / tertiary
//        —— 会跟着壁纸走
// 想要面板带壁纸色调，必须用后者。用 surface* 会得到一块跟壁纸毫无关系的死灰，
// 贴在深色/彩色壁纸上会显得脏。
var launcherPanelSurface = "primaryContainer"
var launcherPanelOpacity = 0.62

// 明暗系数：>1 提亮，<1 压暗，=1 原色（QML 侧由 Launcher.tone() 分派到
// Qt.lighter / Qt.darker）。
// 注意：压暗会把颜色的浓艳感放大（深色底 + 深蓝 = 「正蓝」），怕蓝太正就往亮调。
var launcherPanelBrightness = 1.45

// 饱和度缩放：1 = 原样，<1 更灰。提亮能冲淡色相，这一项进一步抹掉「蓝」。
// 0.4 → 0.7（2026-09-20）：原先压到 0.4 是配合 0.9 的不透明度把面板「做平」，
// 免得色块感过重；开了模糊之后这个补偿不再需要，放回来让面板重新带上壁纸色。
var launcherPanelSaturation = 0.7

// 输入框背景。用同一色源、再亮一档来跟面板拉开层次。
// 饱和度比面板略低：输入框面积小，色度一高就会跳出来抢视线。
var launcherInputSurface = "primaryContainer"
var launcherInputOpacity = 0.5
var launcherInputBrightness = 1.9
var launcherInputSaturation = 0.55

// 选中项的背景高亮：用主题的 primary（亮色）配这个不透明度。
// 越小越浅、越透；调大到 0.5 以上会接近实色。
var launcherSelectedOpacity = 0.22

// 垂直位置：按"剩余空间"的比例计算，不受面板高度影响。
//   0    = 贴顶
//   0.35 = 略偏上（默认，阅读重心偏上更舒服）
//   0.5  = 正中
//   1    = 贴底
var launcherVerticalRatio = 0.35

// 图标墙的单元格参数
var launcherCellWidth = 148
var launcherCellHeight = 134
var launcherIconSize = 56
var launcherCellGap = 8
var launcherLabelFontSize = 14

// ------------------------------------------------------------ 启动器外观
// 圆角半径。原先这四个值是散在 Launcher.qml 里的硬编码 14/12/10/8，收拢到这里
// 便于整体调整。数值呈阶梯而非等比：外层大内层小，视觉重量才平衡。
var launcherPanelRadius = 16
var launcherInputRadius = 11
var launcherCellRadius = 12
var launcherRowRadius = 9

// ------------------------------------------------------ 启动器开关动画
// 打开/关闭时的动画：整体缩放 + 淡入淡出 + 轻微纵向位移。
// 面板自身的尺寸**不做动画** —— 窗口尺寸每帧变化会让 GridView 重算 cellWidth
// 并重排全部 delegate，掉帧明显（同样的理由见 Launcher.qml 里对面板宽度的说明）。
// 这里只动画内容，窗口大小恒定。
//
// 但「窗口大小恒定」也带来一个副作用：niri 的 background-effect 模糊的是 layer
// surface 的**整个矩形**，并不跟随面板的 alpha。于是退场时面板已经淡出，那块模糊
// 矩形却还在，会露出一层"毛玻璃"，直到 surface 被 unmount 才消失。
// 退场比入场更短、且用 InCubic 让不透明度尽量撑到最后再快速归零，就是为了把这层
// 残留压到察觉不到（2026-09-20 实测：170ms 的 OutCubic 退场时肉眼明显可见）。
var launcherAnimDurationMs = 170 // 入场：OutCubic，快进慢停
var launcherCloseDurationMs = 110 // 退场：InCubic，慢起快走（见上）
var launcherAnimScale = 0.96 // 起始缩放，1 = 不做缩放
var launcherAnimOffsetY = -10 // 起始纵向偏移，负值 = 从上方落下

// ---------------------------------------------------------- 启动器投影
// 用 QtQuick.Effects 的 RectangularShadow，让面板从壁纸上「浮起来」。
// 关掉能省一次覆盖整个面板区域的模糊，低配机器上值得关。
var launcherShadowEnabled = true
var launcherShadowBlur = 28
var launcherShadowOpacity = 0.5
var launcherShadowOffsetY = 8

// 列表视图选中项左侧的强调条宽度（px）。0 = 不显示。
// 网格视图没有对应的东西（那边靠图标放大表示选中），故只在列表里出现。
var launcherAccentBarWidth = 3

// ------------------------------------------------------------ 壁纸选择
// 在启动器搜索框里输入下列任一关键词（不区分大小写，需完全匹配），
// 结果列表即变为壁纸缩略图墙：单击选中、双击应用并关闭启动器。
// 目录固定为 ~/Pictures/wallpapers —— 与 ~/.local/bin/set-wallpaper 的
// WALLPAPER_DIR 是同一处约定，不在别处再定义第二遍。
// 缩略图只显示图、不显示文件名，所以格子比应用图标格大。
var launcherWallpaperKeywords = ["壁纸", "/w", "wallpaper"]
var launcherWallpaperCellWidth = 248
var launcherWallpaperCellHeight = 156

// 网页搜索用的引擎（见 SearchEngines.js 的 engines 表）
// 可选：google / bing / baidu / duckduckgo / sogou / brave / startpage / ecosia
var launcherSearchEngine = "google"

// 输入像 URL 时，是否在结果里追加"打开该网址"条目
var launcherEnableUrlOpen = true

