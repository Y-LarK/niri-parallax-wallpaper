import QtQuick
import Quickshell
import Quickshell.Io
import Clavis.Niri
import "ParallaxConfig.js" as Config

// 顶层宿主：持有跨屏幕共享状态，为每个屏幕派生一个壁纸窗口。
Item {
    id: hostRoot

    // 当前壁纸路径。初值来自配置，可通过下面的 IPC 更换。
    // 所有屏幕共享同一个值。
    property string wallpaperPath: Config.wallpaperPath

    // 焦点平铺列记忆，按 workspaceId 索引，多个屏幕共享同一份。
    // 作用是：浮窗获得焦点时壁纸不乱跳，且切回工作区能恢复到原来的列。
    property var columnMemory: ({})

    // Niri 状态版本号：任一 niri 信号触发即自增，驱动所有壁纸窗口重算几何。
    property int niriRevision: 0

    Connections {
        target: Niri

        function onWorkspacesChanged() {
            hostRoot.niriRevision += 1;
        }
        function onWindowsChanged() {
            hostRoot.niriRevision += 1;
        }
        function onOutputsChanged() {
            hostRoot.niriRevision += 1;
        }
    }

    Variants {
        model: Quickshell.screens

        WallpaperWindow {
            required property var modelData
            host: hostRoot
            screen: modelData
        }
    }

    // niri overview（Mod+O）的背景层。不参与视差，独立于桌面壁纸。
    OverviewWallpaper {
        host: hostRoot
    }

    // ------------------------------------------------------------------ IPC
    // 调用方式（二选一）：
    //   qs -p ~/Workspace/niri-parallax-wallpaper/qml/shell.qml ipc call wallpaper set /path/img.jpg
    //   export QS_CONFIG_PATH=~/Workspace/niri-parallax-wallpaper/qml/shell.qml
    //   qs ipc call wallpaper set /path/img.jpg
    IpcHandler {
        target: "wallpaper"

        // 设置新壁纸，触发转场动画
        function set(path: string): void {
            hostRoot.wallpaperPath = path;
        }

        // 读回当前壁纸路径
        function get(): string {
            return hostRoot.wallpaperPath;
        }
    }
}
