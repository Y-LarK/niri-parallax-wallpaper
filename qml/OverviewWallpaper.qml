import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import "ParallaxConfig.js" as Config
import "FillModes.js" as FillModes

// niri overview（Mod+O）的背景壁纸层
//
// 独立的 layer-shell Background 表面，覆盖在 niri 自己的 backdrop-color 之上。
// 与桌面壁纸层互不影响：
//   - 不跟随工作区滚动或平铺列焦点（与 Clavis 的设计一致）
//   - 有独立的壁纸源、填充模式、转场与视觉效果
//
// 把 overviewEnabled 设为 false 即整体隐藏，overview 会回落到 niri 配置里的
// backdrop-color（你当前是 #1e1e2e）。
Variants {
    id: root

    // 由 WallpaperHost 传入，用于在"跟随桌面壁纸"模式下读取当前壁纸路径
    required property var host

    model: Quickshell.screens

    PanelWindow {
        id: overviewWindow

        required property var modelData

        screen: modelData
        color: "transparent"
        visible: Config.overviewEnabled

        WlrLayershell.layer: WlrLayer.Background
        WlrLayershell.namespace: "niri-parallax-overview"
        WlrLayershell.exclusionMode: ExclusionMode.Ignore

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        // 空 mask：不接收输入，overview 里的鼠标操作不受影响
        mask: Region {
            item: Item {}
        }

        // 壁纸来源：跟随桌面，或用单独指定的一张
        readonly property string targetSource: Config.overviewUseDesktopWallpaper
                                               ? (root.host ? root.host.wallpaperPath : "")
                                               : Config.overviewWallpaperPath

        // 模糊会让边缘变透明，向外扩这么多像素以免露出黑边
        readonly property int blurOverflow: Config.overviewBlurRadius > 0 ? 64 : 0

        readonly property bool needsEffect: Config.overviewBlurRadius > 0
                                            || Config.overviewSaturation !== 1.0
                                            || Config.overviewContrast !== 1.0

        Item {
            anchors.fill: parent
            clip: true

            WallpaperTransitionSurface {
                id: overviewRenderer

                anchors.fill: parent
                anchors.margins: -overviewWindow.blurOverflow
                sourcePath: overviewWindow.targetSource
                imageFillMode: FillModes.fillModeValue(Config.overviewFillMode)
                transitionType: Config.overviewTransitionType
                includedTransitions: [Config.overviewTransitionType]
                transitionDurationMs: Config.transitionDurationMs
                transitionsEnabled: Config.transitionsEnabled

                // 仅在有实际视觉效果时才启用离屏渲染，避免无谓开销
                layer.enabled: overviewWindow.needsEffect
                layer.effect: MultiEffect {
                    blurEnabled: Config.overviewBlurRadius > 0
                    blur: Config.overviewBlurRadius / 100
                    blurMax: 64
                    saturation: Config.overviewSaturation - 1
                    contrast: Config.overviewContrast - 1
                }
            }

            // 调暗遮罩：让 overview 里的窗口更突出
            Rectangle {
                anchors.fill: parent
                color: "#000000"
                opacity: Config.overviewDim
                visible: Config.overviewDim > 0
            }
        }
    }
}
