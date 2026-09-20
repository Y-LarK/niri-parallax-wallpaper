import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "ParallaxConfig.js" as Config

// 电源菜单 —— 锁屏 / 注销 / 重启 / 关机
//
// 取代原来的 rofi powermenu.sh。危险动作（注销/重启/关机）需要二次确认，
// 锁屏直接执行（与原版一致）。
//
// 触发：IPC `powermenu toggle`
//   QS_CONFIG_PATH=<此目录>/shell.qml qs ipc call powermenu toggle
PanelWindow {
    id: root

    property bool opened: false
    property int selectedIndex: 0
    // 非空表示正在对某个危险动作做二次确认
    property string pendingAction: ""

    readonly property var actions: [
        {
            "id": "lock",
            "label": "锁屏",
            "glyph": "🔒",
            "danger": false
        },
        {
            "id": "logout",
            "label": "注销",
            "glyph": "🚪",
            "danger": true
        },
        {
            "id": "reboot",
            "label": "重启",
            "glyph": "🔄",
            "danger": true
        },
        {
            "id": "shutdown",
            "label": "关机",
            "glyph": "⏻",
            "danger": true
        }
    ]

    // ------------------------------------------------------ 主题配色
    // 与 Launcher 同源：由 matugen 随壁纸生成
    property var themeColors: ({})
    readonly property string colorsPath: (Quickshell.env("HOME") || "") + "/.cache/niri-quickshell/colors.json"

    FileView {
        id: colorsFile

        path: root.colorsPath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.parseColors()
        onLoadFailed: root.themeColors = ({})
        Component.onCompleted: reload()
    }

    function parseColors() {
        try {
            const text = colorsFile.text();
            root.themeColors = text ? JSON.parse(text) : ({});
        } catch (e) {
            root.themeColors = ({});
        }
    }

    function c(name, fallback) {
        const v = root.themeColors[name];
        return (v && String(v).length > 0) ? String(v) : fallback;
    }

    function ca(name, alpha, fallback) {
        const hex = String(root.themeColors[name] || "");
        if (/^#[0-9a-fA-F]{6}$/.test(hex)) {
            return Qt.rgba(parseInt(hex.substr(1, 2), 16) / 255, parseInt(hex.substr(3, 2), 16) / 255,
                           parseInt(hex.substr(5, 2), 16) / 255, alpha);
        }
        return fallback;
    }

    // ------------------------------------------------------------ 尺寸
    readonly property real screenW: root.screen ? root.screen.width : 1920
    readonly property real screenH: root.screen ? root.screen.height : 1200

    // 确认界面比主菜单窄
    readonly property real panelWidth: root.pendingAction === "" ? 512 : 360
    readonly property real panelHeight: 134

    function labelFor(id) {
        for (let i = 0; i < root.actions.length; i++) {
            if (root.actions[i].id === id)
                return root.actions[i].label;
        }
        return "";
    }

    // ------------------------------------------------------------ 窗口
    visible: opened
    color: "transparent"

    WlrLayershell.namespace: "niri-powermenu"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    WlrLayershell.exclusionMode: ExclusionMode.Ignore

    implicitWidth: root.panelWidth
    implicitHeight: root.panelHeight

    anchors.top: true
    anchors.left: true
    margins.top: Math.round((root.screenH - root.panelHeight) * Config.launcherVerticalRatio)
    margins.left: Math.round((root.screenW - root.panelWidth) / 2)

    // ------------------------------------------------------------ 动作
    function open() {
        // 默认停在"锁屏"而不是关机 —— 配合键盘连按也不会误触危险操作
        root.selectedIndex = 0;
        root.pendingAction = "";
        root.opened = true;
        keyCatcher.forceActiveFocus();
    }

    function close() {
        root.opened = false;
        root.pendingAction = "";
    }

    function toggle() {
        root.opened ? root.close() : root.open();
    }

    function moveSelection(delta) {
        const n = root.actions.length;
        root.selectedIndex = Math.max(0, Math.min(n - 1, root.selectedIndex + delta));
    }

    function activateCurrent() {
        // 确认界面：Enter 即执行
        if (root.pendingAction !== "") {
            root.executeAction(root.pendingAction);
            root.close();
            return;
        }

        const action = root.actions[root.selectedIndex];
        if (!action)
            return;

        if (action.danger)
            root.pendingAction = action.id; // 先确认，不立即执行
        else {
            root.executeAction(action.id);
            root.close();
        }
    }

    function executeAction(id) {
        switch (id) {
        case "lock":
            Quickshell.execDetached(["hyprlock"]);
            break;
        case "logout":
            Quickshell.execDetached(["niri", "msg", "action", "quit"]);
            break;
        case "reboot":
            Quickshell.execDetached(["systemctl", "reboot"]);
            break;
        case "shutdown":
            Quickshell.execDetached(["systemctl", "poweroff"]);
            break;
        }
    }

    // ---------------------------------------------------------------- IPC
    IpcHandler {
        target: "powermenu"

        function toggle(): void {
            root.toggle();
        }
        function open(): void {
            root.open();
        }
        function close(): void {
            root.close();
        }
    }

    // ---------------------------------------------------------- 键盘焦点
    Item {
        id: keyCatcher

        anchors.fill: parent
        focus: true

        Keys.onEscapePressed: {
            if (root.pendingAction !== "")
                root.pendingAction = "";
            else
                root.close();
        }
        Keys.onLeftPressed: root.moveSelection(-1)
        Keys.onRightPressed: root.moveSelection(1)
        Keys.onReturnPressed: root.activateCurrent()
        Keys.onEnterPressed: root.activateCurrent()
    }

    // ------------------------------------------------------------ 面板
    Rectangle {
        id: panel

        anchors.fill: parent
        radius: 14
        color: Qt.lighter(root.ca(Config.launcherPanelSurface, Config.launcherPanelOpacity,
                                  Qt.rgba(0.15, 0.15, 0.17, Config.launcherPanelOpacity)),
                          Config.launcherPanelBrightness)
        border.width: 1
        border.color: root.ca("outline", 0.35, Qt.rgba(1, 1, 1, 0.14))

        // ---- 主菜单 ----
        Row {
            anchors.centerIn: parent
            spacing: 6
            visible: root.pendingAction === ""

            Repeater {
                model: root.actions

                delegate: Rectangle {
                    id: cell

                    required property var modelData
                    required property int index

                    readonly property bool selected: cell.index === root.selectedIndex

                    width: 116
                    height: 96
                    radius: 12
                    color: cell.selected ? root.ca("primary", Config.launcherSelectedOpacity,
                                                   Qt.rgba(0.61, 0.8, 0.98,
                                                           Config.launcherSelectedOpacity)) : "transparent"

                    Column {
                        anchors.centerIn: parent
                        spacing: 6

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: cell.modelData.glyph
                            font.pixelSize: 28
                        }

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: cell.modelData.label
                            font.pixelSize: 13
                            color: cell.selected ? root.c("primary", "#ffffff") : root.c("onSurface",
                                                                                         "#cdd6f4")
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        // 与启动器一致的约定：悬停无视觉反馈，单击选中，双击执行
                        onClicked: root.selectedIndex = cell.index
                        onDoubleClicked: {
                            root.selectedIndex = cell.index;
                            root.activateCurrent();
                        }
                    }
                }
            }
        }

        // ---- 二次确认 ----
        Column {
            anchors.centerIn: parent
            spacing: 12
            visible: root.pendingAction !== ""

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "确定要" + root.labelFor(root.pendingAction) + "吗？"
                font.pixelSize: 17
                color: root.c("onSurface", "#cdd6f4")
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Enter 确定 · Esc 取消"
                font.pixelSize: 12
                color: root.ca("onSurfaceVariant", 0.55, Qt.rgba(1, 1, 1, 0.4))
            }
        }
    }
}
