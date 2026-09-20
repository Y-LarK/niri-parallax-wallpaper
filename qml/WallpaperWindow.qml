import QtQuick
import Quickshell
import Quickshell.Wayland
import Clavis.Niri
import "WallpaperMath.js" as WallpaperMath
import "ParallaxConfig.js" as Config
import "FillModes.js" as FillModes

// 单个屏幕的壁纸层。
//
// 原理：把画布按 preferredScale 等比放大到比屏幕大，溢出的部分就是可平移余量；
// 然后按 niri 的工作区索引（纵向）和平铺列焦点名次（横向）算出 0~1 的 progress，
// 乘上溢出量得到负向偏移，把画布挪到对应位置，外层 clip 负责裁切。
PanelWindow {
    id: win

    required property var host

    // ---------------------------------------------------------- niri 状态
    property var outputWorkspaces: []
    property var activeWorkspace: ({})
    property var horizontalColumns: []
    property int focusedColumn: 0

    // 读取 host 的版本号以建立绑定；niri 状态一变即重算
    readonly property int niriRevision: host ? host.niriRevision : 0
    onNiriRevisionChanged: win.refreshNiriState()

    // ---------------------------------------------------------- 视差几何
    // 「大小合适」：图片宽高比与屏幕接近时，这张图就是为当前屏幕准备的，
    // 直接铺满即可 —— 再靠平移去找画面只会把边缘裁掉。此时视差一律不生效。
    readonly property bool aspectFits: WallpaperMath.aspectMatchesScreen(width, height,
                                                                         renderer.imagePixelWidth,
                                                                         renderer.imagePixelHeight,
                                                                         Config.aspectMatchTolerance)

    // 用户开了视差、且这张图确实需要视差时才真正启用
    readonly property bool parallaxRequested: (Config.verticalEnabled
                                               || Config.horizontalEnabled) && !aspectFits

    // 全景：配置选了 panorama、图片确实比屏幕宽、且没被判为「大小合适」
    readonly property bool panoramaRequested: Config.fillMode === "panorama" && !aspectFits
    readonly property var panoramaCanvas: WallpaperMath.panoramaGeometry(width, height,
                                                                         renderer.imagePixelWidth,
                                                                         renderer.imagePixelHeight,
                                                                         panoramaRequested)
    readonly property bool panoramaActive: panoramaCanvas.active

    // 视差画布：全景激活时它退化为不放大（避免两套几何叠加）
    readonly property var parallaxCanvas: WallpaperMath.parallaxCanvasGeometry(width, height,
                                                                               Config.preferredScale,
                                                                               parallaxRequested
                                                                               && !panoramaActive,
                                                                               Config.verticalEnabled)

    // 统一成 {canvasWidth, canvasHeight, overflowX, overflowY} 的形状
    readonly property var canvas: panoramaActive ? ({
        canvasWidth: panoramaCanvas.canvasWidth,
        canvasHeight: panoramaCanvas.canvasHeight,
        overflowX: panoramaCanvas.overflowX,
        overflowY: panoramaCanvas.overflowY
    }) : ({
        canvasWidth: parallaxCanvas.scaledWidth,
        canvasHeight: parallaxCanvas.scaledHeight,
        overflowX: parallaxCanvas.overflowX,
        overflowY: parallaxCanvas.overflowY
    })

    readonly property real overflowX: canvas.overflowX
    readonly property real overflowY: canvas.overflowY

    // 全景激活时画布已是图片自然比例，强制 Crop；否则用配置的填充模式
    readonly property int effectiveFillMode: panoramaActive ? 2 // Image.PreserveAspectCrop
                                                           : FillModes.fillModeValue(Config.fillMode)

    // 纵向进度：活动工作区在工作区列表中的位置比例
    readonly property real verticalProgress: Config.verticalEnabled ? WallpaperMath.workspaceProgress(
                                                                          outputWorkspaces) : 0.5

    // 横向进度：焦点平铺列在所有列中的名次比例（用名次而非列号，避免空列号造成跳变）
    readonly property real horizontalProgress: Config.horizontalEnabled ? WallpaperMath.focusedColumnProgress(
                                                                             horizontalColumns, focusedColumn,
                                                                             Config.minColumnSpan) : 0.5

    readonly property real offsetX: WallpaperMath.wallpaperPosition(overflowX, horizontalProgress)
    readonly property real offsetY: WallpaperMath.wallpaperPosition(overflowY, verticalProgress)

    // 这两个是唯一被动画驱动的屏幕变换量
    property real animatedOffsetX: offsetX
    property real animatedOffsetY: offsetY

    Behavior on animatedOffsetX {
        NumberAnimation {
            duration: Config.animationDuration
            easing.type: Config.animationEasing
        }
    }

    Behavior on animatedOffsetY {
        NumberAnimation {
            duration: Config.animationDuration
            easing.type: Config.animationEasing
        }
    }

    // ---------------------------------------------------------------- 窗口
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Background
    WlrLayershell.namespace: "niri-parallax-wallpaper"
    WlrLayershell.exclusionMode: ExclusionMode.Ignore

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    // 空 mask：不接收任何输入事件，鼠标可直接穿透到桌面
    mask: Region {
        item: Item {}
    }

    // 从 niri 拉取本屏幕的工作区与窗口状态
    function refreshNiriState() {
        win.outputWorkspaces = Niri.workspacesForOutput(win.screen.name);
        win.activeWorkspace = Niri.activeWorkspaceForOutput(win.screen.name);

        const workspaceId = win.activeWorkspace && win.activeWorkspace.id ? win.activeWorkspace.id : 0;
        const windows = workspaceId ? Niri.windowsForWorkspace(workspaceId) : [];
        win.horizontalColumns = WallpaperMath.horizontalColumns(windows);
        win.focusedColumn = win.resolveColumn(win.activeWorkspace, win.horizontalColumns);
    }

    // 解析当前应跟随的平铺列：优先用记忆，其次用活动窗口，最后取最近的列
    function resolveColumn(workspace, columns) {
        const remembered = WallpaperMath.rememberFocusedHorizontalColumn(win.host.columnMemory,
                                                                        Niri.focusedWindow);
        if (remembered !== win.host.columnMemory)
            win.host.columnMemory = remembered;

        const workspaceId = workspace && workspace.id ? workspace.id : 0;
        if (!workspaceId || !columns || columns.length === 0)
            return 0;

        const workspaceKey = String(workspaceId);
        let preferred = Number(win.host.columnMemory[workspaceKey]);
        if (!isFinite(preferred) || preferred <= 0) {
            const activeWindow = Niri.windowById(workspace.activeWindowId || 0);
            if (WallpaperMath.isHorizontalTiledWindow(activeWindow))
                preferred = Number(activeWindow.layoutColumn);
        }
        return WallpaperMath.nearestHorizontalColumn(columns, preferred);
    }

    Component.onCompleted: win.refreshNiriState()

    // ---------------------------------------------------------------- 渲染
    Item {
        anchors.fill: parent
        clip: true

        Item {
            x: win.animatedOffsetX
            y: win.animatedOffsetY
            width: Math.max(1, win.canvas.canvasWidth)
            height: Math.max(1, win.canvas.canvasHeight)

            // 转场层内部用双 viewport 交替，换图时播 ShaderEffect 过渡。
            // 它自己处理图片解码与就绪判定，视差只负责给它一个带偏移的画布。
            WallpaperTransitionSurface {
                id: renderer

                anchors.fill: parent
                sourcePath: win.host ? win.host.wallpaperPath : ""
                imageFillMode: win.effectiveFillMode
                // 传纯配置值而非 panoramaRequested：后者含 aspectFits，而 aspectFits
                // 依赖本组件产出的 imagePixelWidth，传进来会形成闭环。
                panoramaEnabled: Config.fillMode === "panorama"
                // 解码尺寸上限取屏幕尺寸（同 Clavis 原版），不能用画布尺寸 —— 画布宽度
                // 本身就是由图片比例推出来的，拿它当上限会形成循环。
                textureWidth: Math.min(Math.max(1, Math.round(win.width)), 8192)
                textureHeight: Math.min(Math.max(1, Math.round(win.height)), 8192)
                transitionType: Config.transitionType
                includedTransitions: Config.includedTransitions
                transitionDurationMs: Config.transitionDurationMs
                transitionsEnabled: Config.transitionsEnabled
            }
        }
    }

}
