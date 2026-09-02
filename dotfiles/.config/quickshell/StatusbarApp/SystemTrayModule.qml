import Quickshell
import Quickshell.Services.SystemTray
import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import qs.CustomTheme

// System tray (StatusNotifierItem hosts).
Rectangle {
    id: tray

    // Draws the chip (the rounded plate behind the icons). Supplied from
    // config.json.
    //
    // Tray icons are handed over by the applications themselves — either as a
    // themed icon name or as a raw pixmap over D-Bus — so the bar cannot
    // recolor them and no icon theme covers all of them. Most are drawn for a
    // dark panel and become unreadable once matugen flips the pill background
    // to a light palette. The chip restores the dark substrate they expect,
    // under every icon, whatever its source.
    property bool chip: true

    // Edge length of the icon drawn inside each 30px round hover target. Fed
    // from config.json ("systemtray": { "iconSize": ... }).
    property int iconSize: 20

    // Flatten every tray icon to a single flat glyph in the bar's accent color
    // (background color while hovered), so the tray matches the bar's own
    // modules. Several common tray clients — nm-applet, firewall-applet — only
    // publish a dark monochrome symbol that is nearly invisible on the dark
    // bar; this makes them read at a glance. Set "systemtray": { "colorize":
    // false } in config.json to render apps' real (multi-color) icons
    // as-is instead.
    property bool colorize: true

    // True while the chip is actually painted (light palette). The icons and
    // the hover circle then switch to the chip's contrasting color, since the
    // accent they use otherwise is the chip's own color.
    readonly property bool onChip: chip && Theme.isLight

    // Padding between the icon row and the chip edge. Held at the same value in
    // both palettes — the plate is only painted in light mode, but reserving
    // its space in dark mode too keeps the tray (and everything left of it in
    // the right area) from shifting when the theme flips. Kept at 0 when the
    // chip is off so the tray occupies the same space as any other module.
    readonly property real padH: chip ? 8 : 0
    readonly property real padV: chip ? 3 : 0

    // Collapse the slot when there are no tray items, so the right Repeater
    // hides this Loader and the RowLayout doesn't reserve spacing around an
    // empty, zero-width module (which otherwise leaves a doubled gap next to
    // its neighbours).
    readonly property bool collapsed: SystemTray.items.values.length === 0

    // True while any tray context menu is open. The bar pins itself expanded
    // while this is set: the tray lives in the right area, which is only
    // visible/enabled when the pill is expanded, so without this the popup's
    // anchor item would vanish (pointer leaves the bar -> hover lost ->
    // collapse) and the menu would be dismissed the instant it opened.
    property int openMenuCount: 0
    readonly property bool menuOpen: openMenuCount > 0

    implicitWidth: items.implicitWidth + 2 * padH
    implicitHeight: items.implicitHeight + 2 * padV
    radius: height / 2

    // The plate is painted in the highlight color, and only in a light palette:
    // that is the one case where the icons need a dark substrate under them. A
    // dark palette already provides it, so the chip stays out of the way there
    // rather than boxing in icons that read fine as they are.
    color: onChip ? Theme.primary : "transparent"

    Behavior on color {
        ColorAnimation { duration: 200 }
    }

    RowLayout {
        id: items
        anchors.centerIn: parent
        // The 30px hover targets already pad each icon, so the row itself only
        // needs a small gap between them.
        spacing: 4

        Repeater {
            model: SystemTray.items

            delegate: Rectangle {
                id: trayItem
                required property var modelData

                implicitWidth: 30
                implicitHeight: 30
                radius: 15
                Layout.alignment: Qt.AlignVCenter

                readonly property bool active: mouseArea.containsMouse

                // Same accent-filled circle the other bar modules show on hover
                // (inverted on the chip, which is itself accent-colored).
                color: active
                    ? (tray.onChip ? Theme.on_primary : Theme.primary)
                    : "transparent"
                Behavior on color {
                    ColorAnimation { duration: 500; easing.type: Easing.OutQuint }
                }

                Image {
                    anchors.centerIn: parent
                    source: trayItem.modelData.icon
                    width: tray.iconSize
                    height: tray.iconSize
                    sourceSize.width: tray.iconSize
                    sourceSize.height: tray.iconSize
                    fillMode: Image.PreserveAspectFit
                    layer.enabled: tray.colorize
                    layer.effect: MultiEffect {
                        // Flatten the icon to a single flat accent-colored glyph.
                        // brightness raises every non-transparent pixel toward white
                        // first, so dark monochrome symbols (nm-applet,
                        // firewall-applet) end up as bright as the solid ones rather
                        // than a dim tinted shape; colorization then recolors the
                        // whole thing to the bar's accent, following the icon's
                        // alpha edges. On the chip the roles swap, so the glyph
                        // contrasts with the plate.
                        brightness: 0.5
                        colorization: 1.0
                        colorizationColor: tray.onChip
                            ? (trayItem.active ? Theme.primary : Theme.on_primary)
                            : (trayItem.active ? Theme.background : Theme.primary)
                        Behavior on colorizationColor {
                            ColorAnimation { duration: 500; easing.type: Easing.OutQuint }
                        }
                    }
                }

                MouseArea {
                    id: mouseArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: (mouse) => {
                        if (mouse.button === Qt.LeftButton && !trayItem.modelData.onlyMenu) {
                            trayItem.modelData.activate()
                        } else if (trayItem.modelData.hasMenu) {
                            trayMenu.open()
                        }
                    }
                }

                QsMenuAnchor {
                    id: trayMenu
                    menu: trayItem.modelData.menu
                    anchor.item: trayItem
                    anchor.edges: Edges.Bottom
                    anchor.gravity: Edges.Bottom

                    // Keep the bar expanded for as long as the menu is open so
                    // the anchor item (and this popup) survive the pointer
                    // leaving the bar surface.
                    onOpened: tray.openMenuCount++
                    onClosed: tray.openMenuCount--
                }
            }
        }
    }
}
