import Quickshell
import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import qs.CustomTheme

// Shows the number of entries in the clipboard history next to a clipboard
// icon; clicking it opens the ML4W clipboard manager (ml4w-cliphist, the same
// script as SUPER + V and the Waybar module), which is walker or rofi
// depending on the selected launcher.
//
// The count itself is kept on the statusbar Scope (clipboardCount in
// StatusbarWindow.qml) so one watcher/poll and one `clipboard` IpcHandler serve
// every monitor's bar; this module only displays it.
Rectangle {
    id: clipboard

    // Number of entries in the clipboard history of the launcher in use; bound
    // to statusbarScope.clipboardCount by StatusbarWindow.
    property int count: 0
    // Set by the keyboard navigation in StatusbarWindow.
    property bool focused: false

    // Run the module's action (mouse click or keyboard Return).
    function activate(): void {
        Quickshell.execDetached(["bash", "-c",
            Quickshell.env("HOME") + "/.config/ml4w/scripts/ml4w-cliphist"])
    }

    readonly property bool active: mouseArea.containsMouse || clipboard.focused

    // Tight 3px padding each side, like the updates module.
    implicitWidth: row.implicitWidth + 6
    implicitHeight: 30
    radius: 15

    // Same accent-filled highlight as BarButton on hover/selection.
    color: active ? Theme.primary : "transparent"

    Behavior on color {
        ColorAnimation { duration: 500; easing.type: Easing.OutQuint }
    }

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 4

        Image {
            Layout.alignment: Qt.AlignVCenter
            source: "../shared/icons/clipboard.svg"
            sourceSize.width: 18
            sourceSize.height: 18
            width: 18
            height: 18
            fillMode: Image.PreserveAspectFit
            layer.enabled: true
            layer.effect: MultiEffect {
                colorization: 1.0
                colorizationColor: clipboard.active ? Theme.background : Theme.primary
                Behavior on colorizationColor {
                    ColorAnimation { duration: 500; easing.type: Easing.OutQuint }
                }
            }
        }

        Text {
            Layout.alignment: Qt.AlignVCenter
            text: clipboard.count
            color: clipboard.active ? Theme.background : Theme.primary
            font.family: Theme.fontFamily
            font.pixelSize: 14
            font.bold: true
            Behavior on color {
                ColorAnimation { duration: 500; easing.type: Easing.OutQuint }
            }
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: clipboard.activate()
    }
}
