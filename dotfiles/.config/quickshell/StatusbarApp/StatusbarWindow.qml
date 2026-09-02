import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io
import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import qs.CustomTheme

// One bar instance is created per configured monitor (see targetScreens
// below), each as its own PanelWindow. Everything that must be a single
// source of truth across all of them — the settings file, its FileViews, and
// the IPC handlers — lives on this outer Scope instead of on the PanelWindow.
Scope {
    id: statusbarScope

    // --- USER SETTINGS ---
    // One settings file, the usual place for a Linux app's own config:
    //
    //   ~/.config/ml4w-statusbar/config.json
    //
    // It is created (empty) on first start if it does not exist yet, and is
    // seeded from one of its former locations —
    // ~/.config/ml4w-statusbar/statusbar.json, then
    // ~/.config/ml4w/settings/statusbar.json — when one is still around, so an
    // existing setup keeps its flags.
    //
    // The file is merged over the built-in defaults, so a partial or entirely
    // empty file still leaves every value defined — which is what lets the user
    // edit it by hand and only write down what they want to change. Everything
    // the bar writes itself (enabled, alwaysExpanded, autohide) goes into the
    // same file. StatusbarApp/config.json documents these defaults and must be
    // kept in sync with them.
    readonly property var defaultSettings: ({
        "bar":    { "height": 40, "reservedHeight": 72, "enabled": true,
                    "alwaysExpanded": true, "autohide": false, "hideDelay": 400,
                    "monitors": [] },
        "pill":   { "collapsedWidth": 0, "expandedWidth": 680, "radius": 12, "animationDuration": 350 },
        "modules":{ "left": ["terminal", "workspaces"],
                    "center": ["launcher", "clock", "swaync"],
                    "right": ["updates", "battery", "powerprofile", "volume", "systemtray", "logo", "power"] },
        "border": { "width": 2, "colorTop": "", "colorBottom": "" },
        "opacity":{ "collapsed": 0.6, "expanded": 0.8 },
        "clock":  { "format": "HH:mm", "dateFormat": "ddd, dd MMM", "calendarCommand": "" },
        "workspaces": { "count": 5 },
        "systemtray": { "chip": true, "iconSize": 20, "colorize": true }
    })

    property var settings: defaultSettings

    // The settings file has reported back (loaded, or missing and created), so
    // `settings` holds the values from disk rather than the built-in defaults.
    //
    // Each bar instance stays invisible until then, so its layer surface is
    // created once with the values from disk. The file reports asynchronously,
    // so without the gate the bars are mapped from the defaults — autohide off,
    // space reserved — and only correct themselves a moment later. Hyprland
    // does not reliably pick up the exclusive zone dropping back to 0 that soon
    // after the layer surface is created, which would leave an autohiding bar
    // holding a 52px gap open at the top of the screen for the session.
    property bool ready: false

    // Guards the create/migrate pass below so a file that cannot be written
    // (read-only home, no permissions) does not retry on every reload.
    property bool seeded: false

    // The settings file. Changes made by hand are not picked up automatically;
    // trigger a re-read explicitly with
    //   qs ipc call statusbar reload
    // printErrors is off so a missing file does not log an error before it has
    // been created.
    FileView {
        id: settingsFile
        path: Quickshell.env("HOME") + "/.config/ml4w-statusbar/config.json"
        blockLoading: true
        printErrors: false
        // `ready` is set last, after the values are in place: it releases the
        // gate below, and a binding fires the moment it is assigned.
        onLoaded: { statusbarScope.applySettings(); statusbarScope.ready = true }
        onLoadFailed: {
            // First miss: create the file, then come back through reload().
            // Qt.callLater because this can fire while the component is still
            // being built, before seedProc exists.
            if (!statusbarScope.seeded) {
                statusbarScope.seeded = true
                Qt.callLater(function() { seedProc.running = true })
                return
            }
            statusbarScope.applySettings()
            statusbarScope.ready = true
        }
    }

    // Creates ~/.config/ml4w-statusbar/config.json when it is missing — FileView
    // only writes files, it does not create the directory holding them. The
    // file's former locations are migrated when present, so an existing
    // installation keeps its settings: the old name in the same directory is
    // renamed, the shipped ml4w/settings file is copied (that directory is not
    // ours to change). Failing both, an empty document is written for the user
    // to fill in.
    Process {
        id: seedProc
        command: ["bash", "-c",
            'd="$HOME/.config/ml4w-statusbar"; f="$d/config.json";'
            + ' mkdir -p "$d" || exit 1;'
            + ' [ -f "$f" ] && exit 0;'
            + ' [ -f "$d/statusbar.json" ] && exec mv "$d/statusbar.json" "$f";'
            + ' o="$HOME/.config/ml4w/settings/statusbar.json";'
            + ' if [ -f "$o" ]; then cp "$o" "$f";'
            + ' else printf "{\\n}\\n" > "$f"; fi']
        onExited: settingsFile.reload()
    }

    // Force a re-read of the settings file and re-apply it. reload() refreshes
    // the FileView from disk (re-firing onLoaded/onLoadFailed, which re-runs
    // applySettings).
    function reloadSettings(): void {
        settingsFile.reload()
        applySettings()
    }

    // Parse a settings JSON document that may contain a /* ... */ comment block
    // and — being hand-edited — trailing commas before a closing } or ], which
    // strict JSON.parse rejects. Returns the parsed object, or undefined when the
    // text is empty or cannot be parsed even after that cleanup. Never throws.
    function parseSettings(src) {
        if (!src)
            return undefined
        let raw = src.replace(/\/\*[\s\S]*?\*\//g, "")
        if (raw.trim() === "")
            return undefined
        try {
            return JSON.parse(raw)
        } catch (e) {
            try {
                // Tolerate trailing commas: ",}" / ",]" (optional whitespace).
                return JSON.parse(raw.replace(/,(\s*[}\]])/g, "$1"))
            } catch (e2) {
                console.warn("statusbar settings: could not parse the settings"
                    + " file,"
                    + " ignoring it:", e2)
                return undefined
            }
        }
    }

    // Merge one JSON document (given as text) over an already-built settings
    // object, key by key. Empty or unparseable text is ignored so a
    // missing/partial file never clears previously merged values.
    function mergeSettings(merged, src): void {
        let parsed = parseSettings(src)
        if (parsed === undefined)
            return
        for (let group in parsed)
            for (let key in parsed[group])
                if (merged[group] !== undefined)
                    merged[group][key] = parsed[group][key]
    }

    // Rebuild the settings object: the built-in defaults with the settings file
    // merged on top. An explicit text can be passed (e.g. right after a switch
    // writes the file) so the merge does not depend on the FileView buffer having
    // refreshed yet.
    function applySettings(text): void {
        let merged = JSON.parse(JSON.stringify(statusbarScope.defaultSettings))
        mergeSettings(merged, (text !== undefined) ? text : settingsFile.text())
        statusbarScope.settings = merged
    }

    // Persist a bar.<key> boolean into the settings file and return the updated
    // text. A regex replace is used when the key is already present (so the
    // file's formatting/comments are kept); when the key is missing (e.g. a file
    // that did not list it) it falls back to a JSON rewrite of the parsed
    // document. If the file cannot be parsed at all the write is skipped rather
    // than replaced with an empty object, so a malformed hand-edited file is
    // never wiped — its current text is returned unchanged.
    function persistBarFlag(key, on): string {
        let src = settingsFile.text()
        let re = new RegExp('("' + key + '"\\s*:\\s*)(true|false)')
        let updated
        if (re.test(src)) {
            updated = src.replace(re, "$1" + (on ? "true" : "false"))
        } else {
            let obj = statusbarScope.parseSettings(src)
            if (obj === undefined && src && src.trim() !== "") {
                // Unparseable and non-empty: don't destroy the user's file.
                console.warn("statusbar settings: the settings file is not"
                    + " valid"
                    + " JSON; leaving it untouched instead of overwriting.")
                return src
            }
            if (typeof obj !== "object" || obj === null)
                obj = {}
            if (obj.bar === undefined)
                obj.bar = {}
            obj.bar[key] = on
            updated = JSON.stringify(obj, null, 4) + "\n"
        }
        settingsFile.setText(updated)
        return updated
    }

    // Whether the bar is shown. The "enabled" flag in config.json is the
    // single source of truth; it is toggled from the SidebarApp switch and via
    // "qs ipc call statusbar toggle", persisted back to the file, and survives
    // restarts. Kept as a binding so a settings reload updates it for free.
    property bool barEnabled: settings.bar.enabled

    // Persist the enabled state into the settings file and apply it.
    // applySettings re-parses the updated text, which updates
    // settings.bar.enabled and therefore the barEnabled binding above.
    function setEnabled(on: bool): void {
        applySettings(persistBarFlag("enabled", on))
    }

    // When set in config.json the pill never collapses: it stays in its
    // expanded (full-width) state independent of hover or the IPC toggle. This
    // is purely visual — unlike barExpanded it does not grab the keyboard — so
    // the left/right module areas remain permanently visible.
    property bool alwaysExpanded: settings.bar.alwaysExpanded

    // Persist the alwaysExpanded state into the settings file and apply it.
    // Mirrors setEnabled.
    function setAlwaysExpanded(on: bool): void {
        applySettings(persistBarFlag("alwaysExpanded", on))
    }

    // --- AUTOHIDE ---
    // When "autohide" is set in config.json every bar slides up out of its
    // screen and comes back only while the pointer is on it (or in the hot zone
    // at the very top of that screen), while it holds the keyboard for
    // navigation (SUPER + SPACE), and while a tray menu is open. A hiding bar
    // reserves no space, so windows tile up to the screen edge. Toggled from
    // the SidebarApp switch and via "qs ipc call statusbar autohideToggle".
    property bool autohide: settings.bar.autohide

    // Persist the autohide state into the settings file and apply it. Mirrors
    // setEnabled.
    function setAutohide(on: bool): void {
        applySettings(persistBarFlag("autohide", on))
    }

    // --- SHARED UPDATE-CHECK STATE ---
    // Polled once here (rather than once per monitor's UpdatesModule) so N
    // bar instances don't each spawn ml4w-check-system-updates and don't
    // fight over the `qs ipc call updates ...` IpcHandler target — Quickshell
    // only honors the first registration for a given target and warns about
    // the rest. Every monitor's copy of the module just displays this count.
    property int updatesCount: 0

    function refreshUpdates(): void {
        updatesProc.running = false
        updatesProc.running = true
    }

    // Parse the script's JSON output ({"text": "69", ...}); an empty line
    // means zero updates and the script prints nothing.
    Process {
        id: updatesProc
        command: ["bash", "-c",
            Quickshell.env("HOME") + "/.config/ml4w/scripts/ml4w-check-system-updates"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    let raw = this.text.trim()
                    statusbarScope.updatesCount = raw ? parseInt(JSON.parse(raw).text) || 0 : 0
                } catch (e) {
                    statusbarScope.updatesCount = 0
                }
            }
        }
    }

    // Re-check on the same 1800s interval as the Waybar module.
    Timer {
        interval: 1800 * 1000
        running: true
        repeat: true
        onTriggered: statusbarScope.refreshUpdates()
    }

    // Let external scripts drive the module via `qs ipc call updates ...`
    // (ml4w-install-system-updates calls "refresh" after running updates).
    // `reset` clears the count immediately so the module hides itself
    // without waiting for the next poll.
    IpcHandler {
        target: "updates"
        function reset(): void { statusbarScope.updatesCount = 0 }
        function refresh(): void { statusbarScope.refreshUpdates() }
    }

    // --- MONITOR PLACEMENT ---
    // Which monitors get a bar instance, driven by bar.monitors in the settings
    // file:
    //   []                 (default)  -> first monitor only, i.e. the original
    //                                     single-bar behavior from before this
    //                                     setting existed.
    //   ["all"] or ["*"]              -> one bar per connected monitor.
    //   ["DP-1", "DP-2"]              -> an explicit list of monitor names, as
    //                                     reported by `hyprctl monitors`.
    // Falls back to the first monitor when named monitors match nothing
    // currently connected, so a stale/typo'd name never leaves zero bars.
    readonly property var targetScreens: {
        let screens = Quickshell.screens
        let names = statusbarScope.settings.bar.monitors || []
        if (names.length === 0)
            return screens.length > 0 ? [screens[0]] : []
        if (names.indexOf("all") !== -1 || names.indexOf("*") !== -1)
            return screens
        let filtered = screens.filter(s => names.indexOf(s.name) !== -1)
        return filtered.length > 0 ? filtered : (screens.length > 0 ? [screens[0]] : [])
    }

    // --- CROSS-MONITOR IPC ROUTING ---
    // "focus"/"expand"/"collapse" act on a single bar (the one on the currently
    // focused monitor) rather than all of them at once. Each token is bumped
    // here and every bar instance below reacts only when its own monitor is the
    // focused one — the same pattern the overview module uses for its
    // per-monitor focus grab.
    property int focusRequestToken: 0
    property int expandToggleToken: 0
    property int collapseToken: 0

    // --- CALENDAR PANEL ---
    // The calendar panel is drawn inside a bar window, hanging below its clock
    // module (see CalendarPanel.qml). At most one bar shows it at a time: this
    // holds the name of the screen whose bar has it open, or "" when it is
    // closed. Opening it on another monitor therefore closes it here.
    property string calendarScreen: ""

    // The screen the calendar IPC acts on: the focused monitor when it carries
    // a bar, otherwise the first bar's screen.
    function calendarTargetScreen(): string {
        let screens = statusbarScope.targetScreens
        let focused = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
        for (let i = 0; i < screens.length; i++)
            if (screens[i].name === focused)
                return focused
        return screens.length > 0 ? screens[0].name : ""
    }

    // The calendar panel's IPC, kept on the same target and with the same
    // function names it had when the calendar was its own window, so the
    // existing callers keep working: the SUPER + CTRL + C keybinding, the
    // waybar clock's on-click and the ml4w-calendar shell alias. Lives on the
    // Scope so there is one handler no matter how many bars are shown.
    IpcHandler {
        target: "calendar"
        function toggle(): void {
            statusbarScope.calendarScreen = statusbarScope.calendarScreen !== ""
                ? "" : statusbarScope.calendarTargetScreen()
        }
        function open(): void {
            statusbarScope.calendarScreen = statusbarScope.calendarTargetScreen()
        }
        function close(): void { statusbarScope.calendarScreen = "" }
        function isOpen(): bool { return statusbarScope.calendarScreen !== "" }
    }

    IpcHandler {
        target: "statusbar"
        function toggle(): void { statusbarScope.setEnabled(!statusbarScope.settings.bar.enabled) }
        // Named enable/disable rather than show/hide: "show" is a reserved
        // subcommand of "qs ipc" and would never reach the function.
        function enable(): void { statusbarScope.setEnabled(true) }
        function disable(): void { statusbarScope.setEnabled(false) }
        // Persist and apply the alwaysExpanded (permanently expanded) mode,
        // toggled from the SidebarApp switch.
        function alwaysExpand(): void { statusbarScope.setAlwaysExpanded(true) }
        function autoCollapse(): void { statusbarScope.setAlwaysExpanded(false) }
        // Persist and apply the autohide mode, toggled from the SidebarApp
        // switch and from the ml4w-toggle-statusbar-autohide script.
        function autohideOn(): void { statusbarScope.setAutohide(true) }
        function autohideOff(): void { statusbarScope.setAutohide(false) }
        function autohideToggle(): void {
            statusbarScope.setAutohide(!statusbarScope.settings.bar.autohide)
        }
        // Re-read config.json from disk (used by the SidebarApp switch).
        function refresh(): void { statusbarScope.reloadSettings() }
        // Expand the bar on the focused monitor (if needed) and grab the
        // keyboard for navigation. Bound to SUPER + SPACE. Idempotent: when
        // that bar is already expanded it only re-grabs keyboard focus instead
        // of toggling back to collapsed, so the keybinding always lands in
        // keyboard-navigation mode.
        function focus(): void { statusbarScope.focusRequestToken++ }
        // Toggle between collapsed and expanded mode on the focused monitor.
        function expand(): void { statusbarScope.expandToggleToken++ }
        function collapse(): void { statusbarScope.collapseToken++ }
        // Re-read config.json and apply the changes.
        function reload(): void { statusbarScope.reloadSettings() }
    }

    Variants {
        id: barVariants
        model: statusbarScope.targetScreens

        PanelWindow {
            id: root

            required property var modelData
            screen: modelData

            // Used to route the shared focus/expand/collapse IPC tokens above to
            // only the bar on the currently focused monitor.
            readonly property HyprlandMonitor monitor: Hyprland.monitorFor(root.screen)
            property bool monitorIsFocused: Hyprland.focusedMonitor?.id === monitor?.id

            // --- WAYLAND CONFIGURATION ---
            WlrLayershell.layer: WlrLayer.Top
            // Keyboard focus is owned by the HyprlandFocusGrab below (the same primitive
            // the Calendar/Power popups use), not by the layer-shell focus mode. A
            // WlrKeyboardFocus.Exclusive grab held the keyboard until Escape and left
            // running apps dead; OnDemand never grabbed from the keybinding at all. The
            // focus grab gives the bar the keyboard while expanded *and* fires onCleared
            // when the pointer/keyboard goes to another window, which is what hands focus
            // back to the app (and collapses the bar). Leave the layer-shell mode at its
            // default (None) so the two mechanisms don't fight.

            // Grabs the keyboard for this bar while it is expanded so SUPER + SPACE can
            // drive Left/Right/Return navigation, and releases it the moment the user
            // interacts with another window (clicking/entering an app) — which returns
            // the keyboard to that app and collapses the bar.
            //
            // The same grab also backs the calendar panel: it is held on this window (a
            // layer surface), so clicks on the bar and on the panel itself still arrive
            // normally, while a click in another window clears it and closes both.
            HyprlandFocusGrab {
                windows: [root]
                active: root.barExpanded || root.calendarOpen
                onCleared: {
                    root.setCalendarOpen(false)
                    root.barExpanded = false
                }
            }

            // Escape closes the calendar. The pill's own Escape handler only runs while
            // the bar holds keyboard focus for navigation, and the panel can be open
            // without that, so it is handled at window scope as well. Closing the panel
            // takes precedence over collapsing the bar (see keyHandler below).
            Shortcut {
                sequence: "Escape"
                enabled: root.calendarOpen
                onActivated: root.setCalendarOpen(false)
            }

            // Settings are read from the shared Scope above; every bar instance
            // sees the same values.
            property var settings: statusbarScope.settings

            property int barHeight: settings.bar.height
            // Constant vertical space reserved for the bar (windows tile below this).
            property int reservedHeight: settings.bar.reservedHeight
            property bool barEnabled: settings.bar.enabled
            property bool autohide: settings.bar.autohide

            // Hide completely and reserve no space when disabled. `ready` holds
            // each bar back until the settings file has been read (see above).
            //
            // The window also stays mapped while the calendar is open, so the panel
            // remains reachable with the bar switched off — "qs ipc call calendar
            // toggle" is bound to a key and used by the waybar clock, neither of which
            // knows or cares whether this bar is the one on screen. The pill itself is
            // hidden in that case (see below).
            visible: (barEnabled || calendarPanel.showPanel) && statusbarScope.ready
            // Reserve one window gap less than the band: Hyprland adds its own gaps_out
            // below the reserved zone, so windows end up level with the band's bottom
            // edge and the gap below the pill matches the one above it. An autohiding
            // bar reserves nothing: it floats over the windows and slides in on demand.
            readonly property int windowGap: 16
            exclusiveZone: (barEnabled && !autohide) ? reservedHeight - windowGap : 0

            // Keep the pill expanded regardless of hover. Set via the shared
            // focusRequestToken/expandToggleToken IPC routing below, which only
            // reaches the bar on the currently focused monitor.
            property bool barExpanded: false

            property bool alwaysExpanded: settings.bar.alwaysExpanded

            // True while a system-tray context menu is open on this monitor's bar.
            // Kept per-instance (rather than on the shared scope) since each bar
            // has its own SystemTrayModule and the pill should only pin itself
            // expanded on the monitor where the menu is actually showing.
            property bool trayMenuOpen: false

            // Slid into view when autohide is off, while the pointer is held on
            // this bar, while it is expanded for keyboard navigation, and while a
            // tray menu is open (the tray lives in the right area, which the
            // reveal keeps on screen).
            readonly property bool revealed: !autohide || root.pointerHeld
                || root.barExpanded || root.trayMenuOpen || root.calendarOpen

            // The pointer's hover, held for bar.hideDelay ms after it leaves.
            // Without the grace period the bar snaps shut on every momentary gap
            // in the hover: crossing from the hot zone down to the still-sliding
            // pill, slipping between the pill and the screen edge, or brushing
            // past the edge of the pill.
            property bool pointerHeld: false

            Timer {
                id: hideDelay
                interval: root.settings.bar.hideDelay
                onTriggered: root.pointerHeld = false
            }

            HoverHandler {
                id: barHover
                onHoveredChanged: {
                    if (barHover.hovered) {
                        hideDelay.stop()
                        root.pointerHeld = true
                    } else {
                        hideDelay.restart()
                    }
                }
            }

            // Route the shared IPC tokens to this window only when its monitor
            // currently has focus.
            Connections {
                target: statusbarScope
                function onFocusRequestTokenChanged(): void {
                    if (!root.monitorIsFocused)
                        return
                    root.barExpanded = true
                    keyHandler.forceActiveFocus()
                }
                function onExpandToggleTokenChanged(): void {
                    if (root.monitorIsFocused)
                        root.barExpanded = !root.barExpanded
                }
                function onCollapseTokenChanged(): void {
                    if (root.monitorIsFocused)
                        root.barExpanded = false
                }
            }

            // --- MODULE PLACEMENT ---
            // Each module name in the settings file maps to the component placed into
            // the left/center/right groups. Unknown names load nothing.
            Component { id: cTerminal;   TerminalModule {} }
            Component {
                id: cWorkspaces
                WorkspacesModule {
                    minWorkspaces: root.settings.workspaces.count
                }
            }
            Component { id: cLauncher;   LauncherModule {} }
            // Whether the calendar panel is showing on this monitor's bar. The panel
            // is an information layer of the clock module, drawn inside this window
            // (see CalendarPanel.qml), so the bar carries it rather than depending on
            // a separate calendar window. The open/closed state lives on the shared
            // Scope (calendarScreen) so only one bar shows it at a time.
            readonly property bool calendarOpen:
                statusbarScope.calendarScreen !== "" && statusbarScope.calendarScreen === root.screen.name

            // Open or close the calendar on this bar. Closing only clears the shared
            // state while it is this bar's panel that is open, so a focus grab being
            // released here never closes a panel just opened on another monitor.
            function setCalendarOpen(on: bool): void {
                if (on)
                    statusbarScope.calendarScreen = root.screen.name
                else if (root.calendarOpen)
                    statusbarScope.calendarScreen = ""
            }

            // The placed clock module, tracked so the panel can be centered under it.
            property var clockRef: null

            Component {
                id: cClock
                ClockModule {
                    id: clockModule
                    expanded: pill.expanded
                    timeFormat: root.settings.clock.format
                    dateFormat: root.settings.clock.dateFormat
                    calendarCommand: root.settings.clock.calendarCommand
                    onCalendarToggleRequested: root.setCalendarOpen(!root.calendarOpen)
                    Component.onCompleted: root.clockRef = clockModule
                    Component.onDestruction: {
                        if (root.clockRef === clockModule)
                            root.clockRef = null
                    }
                }
            }
            Component { id: cSwaync;     SwayncModule {} }
            Component {
                id: cSystemTray
                SystemTrayModule {
                    chip: root.settings.systemtray.chip
                    iconSize: root.settings.systemtray.iconSize
                    colorize: root.settings.systemtray.colorize
                    // Rebuild keyboard navigation when the tray empties or repopulates
                    // (it collapses out of the layout when it has no items).
                    onCollapsedChanged: Qt.callLater(root.rebuildNavItems)
                    // Surface the open-menu state up to the window so the pill stays
                    // expanded for as long as a tray menu is showing.
                    Binding {
                        target: root
                        property: "trayMenuOpen"
                        value: menuOpen
                    }
                }
            }
            Component { id: cLogo;       Ml4wLogoModule {} }
            Component { id: cPower;      PowerModule {} }
            Component { id: cVolume;     VolumeModule {} }
            Component {
                id: cUpdates
                UpdatesModule {
                    count: statusbarScope.updatesCount
                    // Rebuild the keyboard navigation list when the module hides or
                    // reappears (its collapsed state tracks the available update count).
                    onCollapsedChanged: Qt.callLater(root.rebuildNavItems)
                }
            }
            Component {
                id: cBattery
                BatteryModule {
                    // Rebuild the keyboard navigation list when the module hides or
                    // reappears (it only shows while running on battery power).
                    onCollapsedChanged: Qt.callLater(root.rebuildNavItems)
                }
            }
            Component { id: cPowerProfile; PowerProfileModule {} }

            readonly property var moduleComponents: ({
                "terminal":   cTerminal,
                "workspaces": cWorkspaces,
                "launcher":   cLauncher,
                "clock":      cClock,
                "swaync":     cSwaync,
                "systemtray": cSystemTray,
                "logo":       cLogo,
                "power":      cPower,
                "updates":      cUpdates,
                "volume":       cVolume,
                "battery":      cBattery,
                "powerprofile": cPowerProfile
            })

            // --- KEYBOARD NAVIGATION ---
            // Ordered left-to-right list of the navigable items, rebuilt from the
            // placed modules whenever the layout or the (dynamic) workspace buttons
            // change. The workspace buttons are spliced in at the workspaces module's
            // position; collection modules without a single action (the system tray)
            // are skipped.
            property var navItems: []
            // Index of the keyboard-selected item, or -1 when none is selected.
            property int focusIndex: -1

            // The placed workspaces module, tracked so navItems can be rebuilt when its
            // button list changes (workspaces appear/disappear asynchronously).
            property var workspacesRef: null
            Connections {
                target: root.workspacesRef
                ignoreUnknownSignals: true
                function onNavButtonsChanged(): void { root.rebuildNavItems() }
            }

            function rebuildNavItems(): void {
                let items = []
                let ws = null
                let groups = [leftRepeater, centerRepeater, rightRepeater]
                for (let g = 0; g < groups.length; g++) {
                    let rep = groups[g]
                    for (let i = 0; i < rep.count; i++) {
                        let loader = rep.itemAt(i)
                        let m = loader ? loader.item : null
                        if (!m)
                            continue
                        if (m.collapsed === true)                // hidden (e.g. updates)
                            continue
                        if (m.navButtons !== undefined) {        // workspaces
                            ws = m
                            items = items.concat(m.navButtons)
                        } else if (typeof m.activate === "function") {
                            items.push(m)
                        }
                    }
                }
                root.workspacesRef = ws
                root.navItems = items
            }

            Component.onCompleted: Qt.callLater(rebuildNavItems)
            onSettingsChanged: Qt.callLater(rebuildNavItems)

            // Highlight exactly the item at focusIndex and clear all others. Called
            // both when the selection moves and when navItems changes underneath it.
            function applyFocus(): void {
                let items = root.navItems
                for (let i = 0; i < items.length; i++)
                    items[i].focused = (i === root.focusIndex)
            }

            onFocusIndexChanged: applyFocus()
            onNavItemsChanged: {
                // Keep the selection in range when the workspace count changes.
                if (root.focusIndex >= root.navItems.length)
                    root.focusIndex = root.navItems.length - 1
                applyFocus()
            }

            onBarExpandedChanged: {
                if (barExpanded) {
                    focusIndex = 0
                    keyHandler.forceActiveFocus()
                } else {
                    focusIndex = -1
                }
            }

            function moveFocus(dir: int): void {
                if (!barExpanded)
                    return
                let n = root.navItems.length
                root.focusIndex = (root.focusIndex + dir + n) % n
            }

            // Forward an Up/Down press to the keyboard-selected module if it exposes a
            // step() function (e.g. the volume module), so the arrows adjust it in place
            // without leaving keyboard-navigation mode.
            function stepFocused(dir: int): void {
                if (root.focusIndex < 0 || root.focusIndex >= root.navItems.length)
                    return
                let m = root.navItems[root.focusIndex]
                if (typeof m.step === "function")
                    m.step(dir)
            }

            function activateFocused(): void {
                // Running any module other than the clock (which toggles the panel
                // itself) dismisses the calendar.
                let m = (root.focusIndex >= 0 && root.focusIndex < root.navItems.length)
                    ? root.navItems[root.focusIndex] : null
                if (m && m !== root.clockRef)
                    root.setCalendarOpen(false)
                if (m)
                    m.activate()
                // Collapse so the keyboard is handed back to the (possibly newly
                // launched) application instead of staying captured by the bar.
                root.barExpanded = false
            }

            color: "transparent"

            // Full-width strip anchored to the top of this monitor
            anchors {
                top: true
                left: true
                right: true
            }

            margins {
                top: 0
            }

            // The band the bar itself occupies — what the window used to be as a whole,
            // before it grew to hold the calendar panel.
            readonly property int bandHeight: barHeight + 40

            // Room below the band for the calendar panel, which is drawn inside this
            // window. Like the dock's context menu it is reserved permanently rather
            // than added when the panel opens: resizing a layer surface while the panel
            // is sliding fights the animation. The area stays transparent and
            // click-through (see mask), and the reserved zone is computed from
            // reservedHeight, so the extra height costs nothing.
            readonly property int calendarReserve: calendarPanel.implicitHeight + 40
            implicitHeight: bandHeight + calendarReserve

            // With autohide off the whole band takes pointer input, exactly as
            // before. While autohiding only the pill and a full-width strip at the
            // top of this screen do, so the rest of the band stays click-through
            // and never swallows clicks meant for the windows behind it: hidden the
            // strip is the hot zone that reveals the bar, revealed it bridges the
            // gap above the pill. The strip has to keep taking input after the
            // reveal, or the pointer that triggered it — still at the very top of
            // the screen, and possibly nowhere near the pill horizontally — would
            // land outside the input region and hide the bar right back again.
            readonly property int hotZoneHeight: root.revealed
                ? Math.max(3, Math.round(pill.y))
                : 3

            // Top edge of the pill, clamped to the window: while it is slid out its
            // y is negative, and a region may not start above the window.
            readonly property int pillTop: Math.max(0, Math.round(pill.y))

            // Top edge of the calendar panel, clamped the same way: it slides in from
            // above the window, so its y is negative for part of the animation.
            readonly property int calendarTop: Math.max(0, Math.round(calendarPanel.y))

            // The bar's regions are dropped entirely when the bar is switched off, so a
            // window kept mapped only to show the calendar does not swallow clicks
            // across the top of the screen.
            readonly property bool barTakesInput: root.barEnabled

            mask: Region {
                Region {
                    x: 0
                    y: 0
                    width: (root.autohide || !root.barTakesInput) ? 0 : root.width
                    height: (root.autohide || !root.barTakesInput) ? 0 : root.bandHeight
                }
                // The pill. While it is slid out this shrinks to nothing and the hot
                // zone below covers the sliver left at the screen edge.
                Region {
                    x: Math.round(pill.x)
                    y: root.pillTop
                    width: (root.autohide && root.barTakesInput) ? Math.round(pill.width) : 0
                    height: (root.autohide && root.barTakesInput)
                        ? Math.max(0, Math.round(pill.y + pill.height) - root.pillTop)
                        : 0
                }
                Region {
                    x: 0
                    y: 0
                    width: (root.autohide && root.barTakesInput) ? root.width : 0
                    height: (root.autohide && root.barTakesInput) ? root.hotZoneHeight : 0
                }
                // The calendar panel, so its buttons are clickable while it is showing.
                Region {
                    x: Math.round(calendarPanel.x)
                    y: root.calendarTop
                    width: root.calendarOpen ? Math.round(calendarPanel.width) : 0
                    height: root.calendarOpen
                        ? Math.max(0, Math.round(calendarPanel.y + calendarPanel.height)
                            - root.calendarTop)
                        : 0
                }
            }

            // A click anywhere in this window that is not on the panel or on a module
            // closes the calendar (the focus grab only covers clicks in other windows).
            // Declared before the pill and the panel so both get the click first.
            MouseArea {
                anchors.fill: parent
                enabled: root.calendarOpen
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: root.setCalendarOpen(false)
            }

            // ==========================================
            // CENTERED PILL
            // ==========================================
            Item {
                id: pill
                // Not shown when the bar is switched off and the window is mapped only
                // to carry the calendar panel.
                visible: root.barEnabled
                anchors.horizontalCenter: parent.horizontalCenter
                // Center the pill within the reserved band. The window is taller than
                // the band (to fit the shadow / expanded pill), so offset accordingly.
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: revealedOffset + revealShift

                // Offset that centers the pill within the reserved band; the window
                // is taller than the band (to fit the shadow / expanded pill).
                readonly property real revealedOffset:
                    (root.reservedHeight / 2) - (root.implicitHeight / 2)
                // Offset that leaves only a 3px sliver of the pill at the top of the
                // screen, i.e. slid fully out of view.
                readonly property real hiddenOffset:
                    3 - height - (root.implicitHeight - height) / 2

                // The slide itself is animated as an extra shift rather than the
                // whole offset, so a change of the bar/pill height still repositions
                // the pill instantly instead of sliding it.
                property real revealShift: root.revealed
                    ? 0
                    : (hiddenOffset - revealedOffset)

                Behavior on revealShift {
                    NumberAnimation {
                        duration: root.settings.pill.animationDuration
                        easing.type: Easing.OutQuint
                    }
                }

                // Collapsed = sized to content, Expanded = fixed width.
                // While autohiding, the hover that reveals the bar also expands it:
                // the pointer that triggers the reveal sits in the hot zone at the
                // screen edge, above the pill, so hoverHandler alone would leave the
                // bar slid in but collapsed until the pointer reached the pill itself.
                property bool expanded: hoverHandler.hovered || root.barExpanded
                    || root.alwaysExpanded || root.trayMenuOpen
                    || (root.autohide && root.pointerHeld)
                // 0 in the settings file means "hug the center content".
                property real collapsedWidth: root.settings.pill.collapsedWidth > 0
                    ? root.settings.pill.collapsedWidth
                    : centerArea.implicitWidth + 32

                // Minimum width the content needs so the centered center area never
                // overlaps the left/right areas. The center stays centered, so each
                // side must clear half of it: the bar has to be at least as wide as the
                // center plus twice the wider of the two side areas (whichever side
                // would collide first), plus the 16px edge margins and some breathing
                // room. Computed live so adding workspaces (or any module growing)
                // pushes the bar wider instead of clipping.
                property real contentWidth: centerArea.implicitWidth
                    + 2 * Math.max(leftArea.implicitWidth, rightArea.implicitWidth)
                    + 64
                // expandedWidth from the settings file is treated as a minimum: the
                // pill grows past it when the content needs more room.
                property real expandedWidth: Math.max(
                    root.settings.pill.expandedWidth, contentWidth)

                width: expanded ? expandedWidth : collapsedWidth
                height: expanded ? root.barHeight + 10 : root.barHeight

                Behavior on width {
                    NumberAnimation {
                        duration: root.settings.pill.animationDuration
                        easing.type: Easing.OutQuint
                    }
                }

                Behavior on height {
                    NumberAnimation {
                        duration: root.settings.pill.animationDuration
                        easing.type: Easing.OutQuint
                    }
                }

                HoverHandler {
                    id: hoverHandler
                }

                // Captures arrow keys (navigate), Return (execute) and Escape
                // (collapse) while the bar is in expanded mode.
                FocusScope {
                    id: keyHandler
                    anchors.fill: parent
                    focus: root.barExpanded
                    Keys.onLeftPressed: root.moveFocus(-1)
                    Keys.onRightPressed: root.moveFocus(1)
                    Keys.onUpPressed: root.stepFocused(1)
                    Keys.onDownPressed: root.stepFocused(-1)
                    Keys.onReturnPressed: root.activateFocused()
                    Keys.onEnterPressed: root.activateFocused()
                    Keys.onEscapePressed: {
                        // Close the calendar first; a second Escape collapses the bar.
                        if (root.calendarOpen)
                            root.setCalendarOpen(false)
                        else
                            root.barExpanded = false
                    }
                }

                RectangularShadow {
                    anchors.fill: pillBg
                    radius: pillBg.radius
                    blur: 15
                    color: Qt.rgba(Theme.shadow.r, Theme.shadow.g, Theme.shadow.b, 0.4)
                }

                // Gradient BORDER layer (outer)
                Rectangle {
                    id: pillBg
                    anchors.fill: parent
                    radius: root.settings.pill.radius
                    opacity: pill.expanded
                        ? root.settings.opacity.expanded
                        : root.settings.opacity.collapsed
                    Behavior on opacity {
                        NumberAnimation {
                            duration: root.settings.pill.animationDuration
                            easing.type: Easing.OutQuint
                        }
                    }

                    // Border colors come from the settings file; empty strings fall
                    // back to the dynamic wallpaper theme.
                    gradient: Gradient {
                        orientation: Gradient.Vertical
                        GradientStop {
                            position: 0.0
                            color: root.settings.border.colorTop !== ""
                                ? root.settings.border.colorTop
                                : Theme.primary
                        }
                        GradientStop {
                            position: 1.0
                            color: root.settings.border.colorBottom !== ""
                                ? root.settings.border.colorBottom
                                : Theme.on_primary
                        }
                    }

                    // Actual background fill (inner), inset by the border thickness
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: root.settings.border.width
                        radius: parent.radius - anchors.margins
                        color: Theme.background
                    }
                }

                // ==========================================
                // LEFT AREA (only visible when expanded)
                // ==========================================
                RowLayout {
                    id: leftArea
                    anchors.left: parent.left
                    anchors.leftMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 14

                    opacity: pill.expanded ? 1 : 0
                    visible: opacity > 0
                    enabled: pill.expanded

                    Behavior on opacity {
                        NumberAnimation { duration: 250; easing.type: Easing.OutQuint }
                    }

                    Repeater {
                        id: leftRepeater
                        model: root.settings.modules.left
                        Loader {
                            Layout.alignment: Qt.AlignVCenter
                            sourceComponent: root.moduleComponents[modelData] || null
                            onLoaded: Qt.callLater(root.rebuildNavItems)
                        }
                    }
                }

                // ==========================================
                // CENTER AREA (always visible)
                // ==========================================
                RowLayout {
                    id: centerArea
                    anchors.centerIn: parent
                    spacing: 14

                    Repeater {
                        id: centerRepeater
                        model: root.settings.modules.center
                        Loader {
                            Layout.alignment: Qt.AlignVCenter
                            sourceComponent: root.moduleComponents[modelData] || null
                            onLoaded: Qt.callLater(root.rebuildNavItems)
                        }
                    }
                }

                // ==========================================
                // RIGHT AREA (only visible when expanded)
                // ==========================================
                RowLayout {
                    id: rightArea
                    anchors.right: parent.right
                    anchors.rightMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 14

                    opacity: pill.expanded ? 1 : 0
                    visible: opacity > 0
                    enabled: pill.expanded

                    Behavior on opacity {
                        NumberAnimation { duration: 250; easing.type: Easing.OutQuint }
                    }

                    Repeater {
                        id: rightRepeater
                        model: root.settings.modules.right
                        Loader {
                            Layout.alignment: Qt.AlignVCenter
                            sourceComponent: root.moduleComponents[modelData] || null
                            // Collapse the layout slot when the module marks itself
                            // collapsed (e.g. the updates module with no pending
                            // updates). Reading the plain `collapsed` flag — rather than
                            // the module's effective `visible` — avoids a binding latch
                            // that would pin this Loader hidden once the right area
                            // collapses in the pill's collapsed state.
                            visible: (item && item.collapsed !== undefined) ? !item.collapsed : true
                            onLoaded: Qt.callLater(root.rebuildNavItems)
                        }
                    }
                }
            }

            // ==========================================
            // CALENDAR PANEL
            // ==========================================
            // Declared after the pill so it draws on top of it, hanging below the clock
            // module it belongs to and clamped to stay on screen.
            CalendarPanel {
                id: calendarPanel

                isOpen: root.calendarOpen

                x: {
                    // Centered on the clock when one is placed, on the bar otherwise.
                    // The clock is loaded into a Loader inside the center area, so its
                    // own x is 0 — the Loader holding it is what moves.
                    let holder = root.clockRef ? root.clockRef.parent : null
                    if (!holder)
                        return Math.round((root.width - width) / 2)
                    let center = pill.x + centerArea.x + holder.x + holder.width / 2
                    return Math.round(Math.max(8,
                        Math.min(root.width - width - 8, center - width / 2)))
                }

                // Hangs calendarGap below the bottom of the pill. The card sits
                // cardInset inside the panel (the drop shadow's room), so that inset is
                // taken off the panel's own position.
                readonly property int calendarGap: 26
                openY: Math.round(pill.y + pill.height + calendarGap - cardInset)
            }
        }
    }
}
