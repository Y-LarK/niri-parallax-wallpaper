//@ pragma IconTheme Papirus-Dark
// Quickshell 配置入口
//
// 当前提供两件事：
//   1. 视差壁纸 —— Background 层，随 niri 工作区/列焦点平移（WallpaperHost）
//   2. 应用启动器 —— Overlay 层，默认隐藏，由 IPC 唤起（Launcher）
//
// 关于首行的 IconTheme pragma：
// 系统默认的 Adwaita 图标主题不含 KDE 系应用图标（help-browser、systemsettings、
// kmenuedit 等），且实测连 iconPath 的 fallback 都取不到图标，最终落到
// IconImageProvider::missingPixmap 的紫黑棋盘格占位图。
// Papirus 覆盖面最广，故显式指定主题。想换主题只改这一行。
import QtQuick
import Quickshell

ShellRoot {
    WallpaperHost {}

    // 启动器：默认隐藏，靠 IPC 唤起
    //   QS_CONFIG_PATH=<此文件路径> qs ipc call launcher toggle
    Launcher {}

    // 电源菜单：锁屏 / 注销 / 重启 / 关机
    //   QS_CONFIG_PATH=<此文件路径> qs ipc call powermenu toggle
    PowerMenu {}
}
