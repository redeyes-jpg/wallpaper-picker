pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

Item {
    id: root

    property var shell: null
    property var manifest: null
    property bool opened: false

    // Change this if your wallpapers live somewhere other than ~/Pictures.
    // Set recursive to true to also pick up images in subfolders.
    property string picturesDir: "$HOME/Pictures"
    property bool recursive: false

    property int columns: 5
    property int gridSpacing: 14
    property int hoveredIndex: -1
    property bool loading: false
    property string statusText: ""
    property bool showSettings: false

    // Rotation state, mirrored from ~/.config/omarchy/wallpicker.json.
    property bool rotationEnabled: false
    property int rotationIntervalMin: 30
    property bool rotationRandom: true

    // Typed keybind entry state. pendingEntries tracks a combo that was
    // committed while we check it against `hyprctl binds -j` for conflicts.
    property var pendingConfigKey: ""
    property var pendingCombo: ""
    property var pendingField: null
    property string takenByDesc: ""
    property bool takenPopupVisible: false

    readonly property color bg: "#0a0a0a"
    readonly property color fg: "#efe6d2"
    readonly property color muted: "#8c8274"
    readonly property color subtle: "#5c564c"
    readonly property color accent: "#efe6d2"
    readonly property color fieldBg: "#141410"
    readonly property color fieldBorder: "#2a2820"

    readonly property string cliPath: Qt.resolvedUrl("wallpicker-cli").toString().replace(/^file:\/\//, "")
    readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/wallpicker.json"

    ListModel {
        id: imageModel
    }

    // Sequential config writes through one process so a config file can never
    // be produced by two writers racing each other (wallarchy pattern).
    property var commandQueue: []

    function enqueueCommand(args) {
        commandQueue.push(args);
        drainCommandQueue();
    }

    function drainCommandQueue() {
        if (configProcess.running)
            return;
        if (commandQueue.length === 0)
            return;
        var args = commandQueue.shift();
        configProcess.command = [root.cliPath].concat(args);
        configProcess.running = true;
    }

    function extensionFilter() {
        // find -iname is case-insensitive per pattern, so list each once.
        var exts = ["png", "jpg", "jpeg", "webp", "bmp", "gif", "tiff"];
        var parts = [];
        for (var i = 0; i < exts.length; i++)
            parts.push("-iname '*." + exts[i] + "'");
        return parts.join(" -o ");
    }

    function reload() {
        root.loading = true;
        root.statusText = "";
        imageModel.clear();
        listProc.command = ["bash", "-c", "dir=\"" + root.picturesDir + "\"; " + "depth=" + (root.recursive ? "99" : "1") + "; " + "find \"$dir\" -maxdepth \"$depth\" -type f \\( " + extensionFilter() + " \\) 2>/dev/null | sort"];
        listProc.running = true;
    }

    function baseName(path) {
        var parts = path.split("/");
        return parts[parts.length - 1];
    }

    function setWallpaper(path) {
        root.statusText = "Applying " + baseName(path) + "…";
        // Omarchy's own CLI is what actually owns the background symlink +
        // swaybg reload. Shelling that out ourselves (as the first version
        // of this plugin did) fought the CLI over that state and silently
        // no-opped on current Omarchy releases. Let the CLI do it.
        Util.execDetached("omarchy theme bg set " + Util.shellQuote(path));
    }

    // ------------------------------------------------------ rotation

    function toggleRotation() {
        root.setConfig("rotationEnabled", !root.rotationEnabled ? "true" : "false");
    }

    function setConfig(key, value) {
        root.enqueueCommand(["config", "set", key, value]);
    }

    function cycleInterval() {
        root.rotationIntervalMin = Model.nextInterval(root.rotationIntervalMin);
        root.setConfig("rotationIntervalMin", String(root.rotationIntervalMin));
    }

    function toggleRotationMode() {
        root.rotationRandom = !root.rotationRandom;
        root.setConfig("rotationRandom", root.rotationRandom ? "true" : "false");
    }

    function rotateNow() {
        root.statusText = "Applying next wallpaper…";
        root.enqueueCommand(["next"]);
    }

    function applyFolder() {
        root.picturesDir = folderField.text.trim();
        root.setConfig("picturesDir", root.picturesDir);
        root.setConfig("recursive", root.recursive ? "true" : "false");
        root.reload();
    }

    // ------------------------------------------------------ rotation helpers

    function rotationIntervalLabel() {
        if (root.rotationIntervalMin <= 0)
            return "Off";
        return Model.intervalLabel(root.rotationIntervalMin);
    }

    function rotationDescription() {
        if (root.rotationEnabled && root.rotationIntervalMin > 0)
            return "Rotation is active — wallpaper changes every " + Model.intervalLabel(root.rotationIntervalMin).toLowerCase() + ", picking " + (root.rotationRandom ? "at random" : "in order") + ".";
        if (root.rotationIntervalMin > 0)
            return "Rotation is off. Start it to change the wallpaper every " + Model.intervalLabel(root.rotationIntervalMin).toLowerCase() + ".";
        return "Rotation interval is set to Off.";
    }

    // ------------------------------------------------------ keybinds (typed)

    // Normalize a typed combo like "SUPER+W", "super + w", "ctrl shift w"
    // into canonical "SUPER + W". Returns "" if the text isn't a usable combo.
    function normalizeCombo(raw) {
        var t = (raw || "").trim();
        if (t === "")
            return "";
        var parts = t.toUpperCase().split(/[\s+,.]+/).filter(function (p) {
            return p.length > 0;
        });
        if (parts.length < 2)
            return "";
        var key = root.normalizeKeyToken(parts[parts.length - 1]);
        if (key === "")
            return "";
        var mods = [];
        for (var i = 0; i < parts.length - 1; i++) {
            var m = root.normalizeModToken(parts[i]);
            if (m === "")
                return "";
            if (mods.indexOf(m) < 0)
                mods.push(m);
        }
        if (mods.length === 0)
            return ""; // bare key would break typing globally
        var order = ["SUPER", "SHIFT", "CTRL", "ALT"];
        var out = [];
        for (var j = 0; j < order.length; j++)
            if (mods.indexOf(order[j]) >= 0)
                out.push(order[j]);
        out.push(key);
        return out.join(" + ");
    }

    function normalizeModToken(tok) {
        switch (tok) {
        case "SUPER":
        case "WIN":
        case "META":
        case "WINDOWS":
        case "MOD4":
        case "SUPER_L":
        case "SUPER_R":
            return "SUPER";
        case "SHIFT":
        case "SHIFT_L":
        case "SHIFT_R":
            return "SHIFT";
        case "CTRL":
        case "CONTROL":
        case "CTRL_L":
        case "CTRL_R":
            return "CTRL";
        case "ALT":
        case "ALT_L":
        case "ALT_R":
        case "MOD1":
            return "ALT";
        }
        return "";
    }

    function normalizeKeyToken(tok) {
        if (tok.length === 1 && tok >= "A" && tok <= "Z")
            return tok;
        if (tok.length === 1 && tok >= "0" && tok <= "9")
            return tok;
        if (tok.length >= 2 && tok.charAt(0) === "F" && !isNaN(Number(tok.substring(1))) && Number(tok.substring(1)) >= 1 && Number(tok.substring(1)) <= 12)
            return tok;
        var names = {
            SPACE: "SPACE",
            RETURN: "RETURN",
            ENTER: "RETURN",
            ESC: "ESC",
            ESCAPE: "ESC",
            TAB: "TAB",
            BACKSPACE: "BACKSPACE",
            DELETE: "DELETE",
            INSERT: "INSERT",
            HOME: "HOME",
            END: "END",
            PAGEUP: "PAGEUP",
            PAGEDOWN: "PAGEDOWN",
            LEFT: "LEFT",
            RIGHT: "RIGHT",
            UP: "UP",
            DOWN: "DOWN",
            COMMA: "comma",
            PERIOD: "period",
            MINUS: "minus",
            EQUAL: "equal",
            SLASH: "slash",
            BACKSLASH: "backslash",
            SEMICOLON: "semicolon",
            APOSTROPHE: "apostrophe",
            BRACKETLEFT: "bracketleft",
            BRACKETRIGHT: "bracketright",
            GRAVE: "grave",
            QUOTELEFT: "grave"
        };
        if (tok in names)
            return names[tok];
        return "";
    }

    // X11 modifier mask bits as reported by hyprctl binds -j (modmask field).
    function comboModmask(combo) {
        var mask = 0;
        if (combo.indexOf("SHIFT") >= 0)
            mask |= 1;
        if (combo.indexOf("CTRL") >= 0)
            mask |= 4;
        if (combo.indexOf("ALT") >= 0)
            mask |= 8;
        if (combo.indexOf("SUPER") >= 0)
            mask |= 64;
        return mask;
    }

    function comboKeyName(combo) {
        var parts = combo.split(" + ");
        return parts[parts.length - 1];
    }

    // wallpicker's own binds (emitted by wallpicker-cli) — replacing those
    // silently is fine, so the conflict popup only fires for OTHER apps.
    function isWallpickerBind(desc) {
        return desc === "Wallpaper picker" || desc === "Toggle wallpaper rotation" || desc === "Rotate wallpaper now";
    }

    // The o.bind() description this plugin emits for a given config key, used
    // both by the conflict check (own binds replace silently) and by the
    // post-apply verification against hyprctl binds -j.
    function descForConfigKey(configKey) {
        if (configKey === "keybindToggleRotation")
            return "Toggle wallpaper rotation";
        if (configKey === "keybindRotateNow")
            return "Rotate wallpaper now";
        return "Wallpaper picker"; // keybindOpen
    }

    // Called when a keybind field is committed (Enter or focus lost).
    function commitKeybind(configKey, field) {
        var combo = root.normalizeCombo(field.text);
        var prev = root.configData && root.configData[configKey] ? root.configData[configKey] : "";
        if (combo === "") {
            if (field.text.trim() !== "")
                root.statusText = "Invalid combo — type e.g. SUPER + W";
            field.text = prev; // revert invalid input
            return;
        }
        if (combo === prev) {
            field.text = prev; // normalize display, nothing to write
            return;
        }
        root.pendingConfigKey = configKey;
        root.pendingCombo = combo;
        root.pendingField = field;
        bindsProc.command = ["hyprctl", "binds", "-j"];
        bindsProc.running = true;
    }

    function applyPendingKeybind() {
        if (root.pendingConfigKey === "" || root.pendingCombo === "")
            return;
        root.statusText = "";
        // Stage what was written so the post-apply recheck knows what to look
        // for in the lua file and in hyprctl binds -j.
        root.keybindVerifyCombo = root.pendingCombo;
        root.keybindVerifyDesc = root.descForConfigKey(root.pendingConfigKey);
        root.keybindVerifyKey = root.comboKeyName(root.pendingCombo).toUpperCase();
        root.keybindVerifyMask = root.comboModmask(root.pendingCombo);
        root.keybindVerifyPending = true;
        root.setConfig(root.pendingConfigKey, root.pendingCombo);
        root.enqueueCommand(["keybinds", "apply"]);
        if (root.pendingField)
            root.pendingField.text = root.pendingCombo; // show normalized form
        root.pendingConfigKey = "";
        root.pendingCombo = "";
        root.pendingField = null;
        root.takenPopupVisible = false;
    }

    // Rechecks that the binding was actually written to the generated lua and
    // registered with Hyprland before we confirm "Applied" to the user.
    function runKeybindVerify() {
        var combo = root.keybindVerifyCombo;
        var desc = root.keybindVerifyDesc;
        var key = root.keybindVerifyKey;
        var mask = root.keybindVerifyMask;
        var qcombo = combo.replace(/'/g, "'\\''");
        var script = "lua=\"$HOME/.config/hypr/wallpicker.lua\"; " + "if ! grep -Fq '" + qcombo + "' \"$lua\"; then echo MISSING_LUA; exit 1; fi; " + "if ! hyprctl binds -j | jq -e '[.[] | select((.submap // \"\") == \"\" and .key == \"" + key + "\" and .modmask == " + mask + " and .description == \"" + desc + "\")] | length > 0' >/dev/null 2>&1; then echo NOT_BOUND; exit 2; fi; " + "echo APPLIED";
        verifyProc.command = ["bash", "-c", script];
        verifyProc.running = true;
    }

    function cancelPendingKeybind() {
        var prev = root.configData && root.configData[root.pendingConfigKey] ? root.configData[root.pendingConfigKey] : "";
        if (root.pendingField)
            root.pendingField.text = prev;
        root.pendingConfigKey = "";
        root.pendingCombo = "";
        root.pendingField = null;
        root.takenPopupVisible = false;
    }

    property var configData: null

    // Keybind apply verification state — set when "keybinds apply" is queued,
    // consumed in configProcess.onExited once that exact command finished, then
    // runKeybindVerify() rechecks the lua file + live Hyprland binds before we
    // report "Applied: <combo>".
    property bool keybindVerifyPending: false
    property string keybindVerifyCombo: ""
    property string keybindVerifyDesc: ""
    property string keybindVerifyKey: ""
    property int keybindVerifyMask: 0

    // ------------------------------------------------------ open/close

    function open(payloadJson) {
        root.opened = true;
        root.reload();
        Qt.callLater(function () {
            keyCatcher.forceActiveFocus();
        });
    }

    function close() {
        root.opened = false;
    }

    function dismiss() {
        root.opened = false;
        if (root.shell && typeof root.shell.hide === "function")
            root.shell.hide((root.manifest && root.manifest.id) || "wallpicker.grid");
    }

    function toggle() {
        if (root.opened)
            root.dismiss();
        else
            root.open("{}");
    }

    IpcHandler {
        target: "wallpicker"
        function toggle(): string {
            root.toggle();
            return "ok";
        }
        function open(): string {
            root.open("{}");
            return "ok";
        }
        function close(): string {
            root.dismiss();
            return "ok";
        }
        function status(): string {
            return root.opened ? "open" : "closed";
        }
        function toggleRotation(): string {
            root.toggleRotation();
            return "ok";
        }
        function cycleNow(): string {
            root.rotateNow();
            return "ok";
        }
        function setInterval(minutes: string): string {
            var n = Number(minutes);
            if (!isFinite(n))
                return "err";
            root.rotationIntervalMin = Math.round(n);
            root.setConfig("rotationIntervalMin", String(root.rotationIntervalMin));
            return "ok";
        }
        function rotationStatus(): string {
            if (root.rotationEnabled && root.rotationIntervalMin > 0)
                return "active:" + root.rotationIntervalMin;
            return "inactive";
        }
    }

    Process {
        id: listProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var lines = text.split("\n").filter(function (l) {
                    return l.length > 0;
                });
                for (var i = 0; i < lines.length; i++)
                    imageModel.append({
                        path: lines[i]
                    });
                root.loading = false;
                if (lines.length === 0)
                    root.statusText = "No images found in " + root.picturesDir;
            }
        }
    }

    Process {
        id: configProcess
        command: []
        stdout: StdioCollector {
            waitForEnd: true
        }
        onExited: function (code) {
            if (code !== 0)
                root.statusText = "Command failed";
            // Only verify right after the "keybinds apply" command itself ran
            // (config set / next / etc. must not consume the verify flag).
            if (root.keybindVerifyPending && configProcess.command.join(" ") === root.cliPath + " keybinds apply") {
                root.keybindVerifyPending = false;
                if (code === 0)
                    root.runKeybindVerify();
                else
                    root.statusText = "Apply failed — wallpicker-cli exited " + code;
            }
            root.drainCommandQueue();
        }
    }

    // Queries hyprctl binds -j so a typed keybind can be checked for
    // conflicts with existing global binds before it is written.
Process {
        id: bindsProc
        command: []
        stdout: StdioCollector {
            id: bindsStdout
            waitForEnd: true
        }
        onExited: function (code) {
            if (root.pendingConfigKey === "")
                return;
            if (code !== 0) {
                root.applyPendingKeybind();
                return;
            }
            var output = bindsStdout.text;
            var entries = Model.parseJson(output, [], 16777216);
            var combo = root.pendingCombo;
            var key = root.comboKeyName(combo).toUpperCase();
            var mask = root.comboModmask(combo);
            for (var i = 0; i < entries.length; i++) {
                var e = entries[i];
                if ((e.submap || "") !== "")
                    continue; // only global binds collide with ours
                if (!e.key)
                    continue;
                if (e.key.toUpperCase() !== key || e.modmask !== mask)
                    continue;
                if (root.isWallpickerBind(e.description))
                    continue; // our own bind — replace silently
                root.takenByDesc = e.description || "another action";
                root.takenPopupVisible = true;
                return;
            }
            root.applyPendingKeybind();
        }
    }

    // Verifies a just-applied keybind against the generated lua file and the
    // live Hyprland bind table, and reports "Applied: <combo>" only then.
    Process {
        id: verifyProc
        command: []
        stdout: StdioCollector {
            waitForEnd: true
        }
        onExited: function (code) {
            if (root.keybindVerifyCombo === "")
                return;
            var out = String(text).trim();
            if (code === 0 && out === "APPLIED") {
                root.statusText = "Applied: " + root.keybindVerifyCombo;
                root.appliedTimer.restart();
            } else if (out === "MISSING_LUA") {
                root.statusText = "Apply failed — binding not found in wallpicker.lua";
            } else if (out === "NOT_BOUND") {
                root.statusText = "Apply failed — Hyprland did not register the bind";
            } else {
                root.statusText = "Apply failed — verification exited " + code;
            }
            root.keybindVerifyCombo = "";
            root.keybindVerifyDesc = "";
            root.keybindVerifyKey = "";
            root.keybindVerifyMask = 0;
        }
    }

    // Clears the "Applied: ..." confirmation after a moment so the status area
    // doesn't stay stale; reopening the window also resets it (reload()).
    Timer {
        id: appliedTimer
        interval: 8000
        repeat: false
        onTriggered: {
            if (root.statusText.indexOf("Applied:") === 0)
                root.statusText = "";
        }
    }

    FileView {
        path: root.configPath
        watchChanges: true
        printErrors: false
        onLoaded: root.applyConfig(text())
        onFileChanged: reload()
        onLoadFailed: root.applyConfig("{}")
    }

    function applyConfig(raw) {
        var config = Model.parseJson(raw, {}, 65536);
        root.configData = config;
        root.picturesDir = (config.picturesDir || root.picturesDir).replace(/^\~\//, Quickshell.env("HOME") + "/");
        root.recursive = Model.asBool(config.recursive, root.recursive);
        root.rotationEnabled = Model.asBool(config.rotationEnabled, root.rotationEnabled);
        root.rotationIntervalMin = Model.asInt(config.rotationIntervalMin, root.rotationIntervalMin);
        root.rotationRandom = Model.asBool(config.rotationRandom, root.rotationRandom);
    }

    FloatingWindow {
        id: panel
        visible: root.opened
        title: "Wallpaper Picker"
        color: "#0a0a0a"
        implicitWidth: 1100
        implicitHeight: 720
        minimumSize: Qt.size(640, 480)
        onVisibleChanged: {
            if (!visible && root.opened)
                root.dismiss();
        }

        Item {
            id: keyCatcher
            anchors.fill: parent
            focus: true
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function (event) {
                if (event.key === Qt.Key_Escape) {
                    if (root.showSettings) {
                        root.showSettings = false;
                        event.accepted = true;
                    } else {
                        root.dismiss();
                        event.accepted = true;
                    }
                }
            }

            Rectangle {
                anchors.fill: parent
                color: root.bg
            }

            // ================================================= header
            Item {
                id: header
                width: parent.width
                height: 52
                anchors.top: parent.top

                Text {
                    text: root.showSettings ? "SETTINGS" : "WALLPAPERS"
                    color: root.muted
                    font.pixelSize: 11
                    font.letterSpacing: 3
                    font.weight: Font.Medium
                    anchors.left: parent.left
                    anchors.leftMargin: 28
                    anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                    text: root.loading ? "loading…" : (imageModel.count + " images")
                    color: root.subtle
                    font.pixelSize: 11
                    font.letterSpacing: 1
                    anchors.left: parent.left
                    anchors.leftMargin: 130
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !root.showSettings
                }

                Row {
                    anchors.right: parent.right
                    anchors.rightMargin: 24
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8

                    ToolBtn {
                        visible: root.showSettings
                        iconText: "\uDB80\uDF0D" // md-keyboard_backspace (back)
                        tooltip: "Back to wallpapers"
                        onClicked: {
                            root.showSettings = false;
                        }
                    }

                    ToolBtn {
                        visible: !root.showSettings
                        iconText: "\uEAF8" // cod-gear (settings)
                        tooltip: "Settings"
                        onClicked: {
                            root.showSettings = true;
                        }
                    }
                }
            }

            // ================================================= status
            Text {
                id: statusLabel
                visible: root.statusText.length > 0
                text: root.statusText
                color: root.muted
                font.pixelSize: 12
                anchors.top: header.bottom
                anchors.left: parent.left
                anchors.leftMargin: 28
            }

            // ================================================= grid tab
            Item {
                id: gridTab
                visible: !root.showSettings
                anchors.top: header.bottom
                anchors.bottom: footer.top
                anchors.left: parent.left
                anchors.right: parent.right

                GridView {
                    id: grid
                    anchors.fill: parent
                    anchors.margins: 28
                    // GridView fits N columns by floor(width / cellWidth), so
                    // cellWidth must be <= width/columns or it silently rounds
                    // down to one fewer column. Math.floor guards the edge case
                    // where floating-point rounding makes it land a hair over.
                    cellWidth: Math.floor(width / root.columns)
                    cellHeight: Math.floor((cellWidth - root.gridSpacing) * 9 / 16) + root.gridSpacing
                    model: imageModel
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    delegate: Item {
                        id: cell
                        required property string path
                        required property int index
                        width: grid.cellWidth - root.gridSpacing
                        height: grid.cellHeight - root.gridSpacing

                        Rectangle {
                            anchors.fill: parent
                            radius: root.hoveredIndex === cell.index ? 0 : 10
                            color: "#141410"
                            border.width: root.hoveredIndex === cell.index ? 2 : 0
                            border.color: root.accent
                            clip: true

                            Image {
                                id: thumb
                                anchors.fill: parent
                                anchors.margins: root.hoveredIndex === cell.index ? 2 : 0
                                source: "file://" + cell.path
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: true
                                smooth: true

                                Rectangle {
                                    visible: thumb.status !== Image.Ready
                                    anchors.fill: parent
                                    color: "#1b1b16"

                                    Text {
                                        anchors.centerIn: parent
                                        text: thumb.status === Image.Error ? "✕" : "…"
                                        color: root.subtle
                                        font.pixelSize: 20
                                    }
                                }
                            }

                            Rectangle {
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                height: 26
                                visible: root.hoveredIndex === cell.index
                                gradient: Gradient {
                                    GradientStop {
                                        position: 0.0
                                        color: "#00000000"
                                    }
                                    GradientStop {
                                        position: 1.0
                                        color: "#c0000000"
                                    }
                                }

                                Text {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    anchors.margins: 6
                                    elide: Text.ElideMiddle
                                    text: root.baseName(cell.path)
                                    color: root.fg
                                    font.pixelSize: 11
                                }
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: root.hoveredIndex = cell.index
                            onExited: if (root.hoveredIndex === cell.index)
                                root.hoveredIndex = -1
                            onClicked: root.setWallpaper(cell.path)
                        }
                    }
                }
            }

            // ================================================= settings tab
            Item {
                id: settingsTab
                visible: root.showSettings
                anchors.top: header.bottom
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right

                Flickable {
                    anchors.fill: parent
                    anchors.margins: 28
                    contentWidth: width
                    contentHeight: settingsCol.height
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    Column {
                        id: settingsCol
                        width: parent.width
                        spacing: 28

                        // --- WALLPAPER FOLDER ---
                        Column {
                            width: parent.width
                            spacing: 8

                            Text {
                                text: "WALLPAPER FOLDER"
                                color: root.subtle
                                font.pixelSize: 10
                                font.letterSpacing: 2
                                font.weight: Font.Medium
                            }

                            Row {
                                width: parent.width
                                height: 40
                                spacing: 8

                                TextField {
                                    id: folderField
                                    width: parent.width - applyFolderBtn.width - parent.spacing
                                    height: parent.height
                                    color: root.fg
                                    placeholderText: "Path to wallpaper folder"
                                    placeholderTextColor: root.subtle
                                    text: root.picturesDir
                                    selectByMouse: true
                                    background: Rectangle {
                                        radius: 8
                                        color: root.fieldBg
                                        border.width: 1
                                        border.color: folderField.activeFocus ? root.accent : root.fieldBorder
                                    }
                                }

                                ToolBtn {
                                    id: applyFolderBtn
                                    width: 110
                                    height: parent.height
                                    text: "Apply"
                                    onClicked: root.applyFolder()
                                }
                            }

                            Row {
                                width: parent.width
                                height: 36
                                spacing: 10

                                ToggleSwitch {
                                    id: recursiveToggle
                                    checked: root.recursive
                                    onToggled: {
                                        root.recursive = !recursiveToggle.checked;
                                        root.setConfig("recursive", root.recursive ? "true" : "false");
                                        root.reload();
                                    }
                                }

                                Text {
                                    text: "Include subfolders"
                                    color: root.muted
                                    font.pixelSize: 12
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }

                        // --- KEYBINDS ---
                        Column {
                            width: parent.width
                            spacing: 8

                            Text {
                                text: "KEYBINDS"
                                color: root.subtle
                                font.pixelSize: 10
                                font.letterSpacing: 2
                                font.weight: Font.Medium
                            }

                            Text {
                                text: "Type a combo like SUPER + W, then press Enter or Apply. Taken combos ask before replacing."
                                color: root.subtle
                                font.pixelSize: 10
                                wrapMode: Text.Wrap
                                width: parent.width
                            }

                            KeybindField {
                                label: "Open wallpaper picker"
                                configKey: "keybindOpen"
                                value: root.configData && root.configData.keybindOpen ? root.configData.keybindOpen : ""
                            }

                            KeybindField {
                                label: "Toggle rotation"
                                configKey: "keybindToggleRotation"
                                value: root.configData && root.configData.keybindToggleRotation ? root.configData.keybindToggleRotation : ""
                            }

                            KeybindField {
                                label: "Rotate wallpaper now"
                                configKey: "keybindRotateNow"
                                value: root.configData && root.configData.keybindRotateNow ? root.configData.keybindRotateNow : ""
                            }
                        }

                        // --- ROTATION ---
                        Column {
                            width: parent.width
                            spacing: 10

                            Text {
                                text: "ROTATION"
                                color: root.subtle
                                font.pixelSize: 10
                                font.letterSpacing: 2
                                font.weight: Font.Medium
                            }

                            Row {
                                width: parent.width
                                height: 40
                                spacing: 8

                                ToolBtn {
                                    id: rotationToggleBtn
                                    width: 130
                                    height: parent.height
                                    text: root.rotationEnabled && root.rotationIntervalMin > 0 ? "Stop" : "Start"
                                    iconText: root.rotationEnabled && root.rotationIntervalMin > 0 ? "\uF04D" : "\uEAD3" // fa-stop / cod-debug_start
                                    highlighted: root.rotationEnabled && root.rotationIntervalMin > 0
                                    onClicked: root.toggleRotation()
                                }

                                ToolBtn {
                                    width: 130
                                    height: parent.height
                                    text: root.rotationIntervalLabel()
                                    iconText: "\uF01E" // fa-repeat (interval)
                                    tooltip: "Rotate every…"
                                    onClicked: root.cycleInterval()
                                }

                                ToolBtn {
                                    width: 150
                                    height: parent.height
                                    text: root.rotationRandom ? "Random" : "Sequential"
                                    iconText: root.rotationRandom ? "\uF074" : "\uF0CA"
                                    tooltip: "Change rotation order"
                                    onClicked: root.toggleRotationMode()
                                }

                                ToolBtn {
                                    width: 150
                                    height: parent.height
                                    text: "Rotate now"
                                    iconText: "\uF04E" // fa-forward (rotate now)
                                    onClicked: root.rotateNow()
                                }
                            }

                            Text {
                                text: root.rotationDescription()
                                color: root.subtle
                                font.pixelSize: 11
                                wrapMode: Text.WordWrap
                                width: parent.width
                            }
                        }
                    }
                }
            }

            // ================================================= footer
            Item {
                id: footer
                width: parent.width
                height: 56
                anchors.bottom: parent.bottom

                Rectangle {
                    anchors.fill: parent
                    color: "#0d0d0b"
                    border.width: 1
                    border.color: "#1c1a14"
                }

                // Rotation controls — mirrored on the settings tab above.
                Row {
                    visible: !root.showSettings
                    anchors.left: parent.left
                    anchors.leftMargin: 24
                    anchors.verticalCenter: parent.verticalCenter
                    height: parent.height
                    spacing: 8

                    ToolBtn {
                        width: 44
                        height: 40
                        anchors.verticalCenter: parent.verticalCenter
                        iconText: root.rotationEnabled && root.rotationIntervalMin > 0 ? "\uF04D" : "\uEAD3"
                        tooltip: (root.rotationEnabled && root.rotationIntervalMin > 0 ? "Stop" : "Start") + " rotation"
                        highlighted: root.rotationEnabled && root.rotationIntervalMin > 0
                        onClicked: root.toggleRotation()
                    }

                    ToolBtn {
                        width: 84
                        height: 40
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.rotationIntervalMin > 0 ? Model.intervalLabel(root.rotationIntervalMin) : "Off"
                        iconText: "\uF01E"
                        tooltip: "Rotate every…"
                        onClicked: root.cycleInterval()
                    }

                    ToolBtn {
                        width: 120
                        height: 40
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.rotationRandom ? "Random" : "Sequential"
                        iconText: root.rotationRandom ? "\uF074" : "\uF0CA"
                        tooltip: "Change rotation order"
                        onClicked: root.toggleRotationMode()
                    }

                    ToolBtn {
                        width: 44
                        height: 40
                        anchors.verticalCenter: parent.verticalCenter
                        iconText: "\uF04E"
                        tooltip: "Rotate now"
                        onClicked: root.rotateNow()
                    }
                }

                Text {
                    visible: root.showSettings
                    text: "Rotation changes are saved immediately."
                    color: root.subtle
                    font.pixelSize: 11
                    anchors.centerIn: parent
                }
            }

            // --- Conflict popup ---
            Rectangle {
                anchors.fill: parent
                visible: root.takenPopupVisible
                color: "#99000000"
                z: 50
                MouseArea {
                    anchors.fill: parent
                }

                Rectangle {
                    width: 420
                    radius: 12
                    color: root.fieldBg
                    border.width: 1
                    border.color: root.fieldBorder
                    anchors.centerIn: parent

                    Column {
                        anchors.fill: parent
                        anchors.margins: 28
                        spacing: 20

                        Text {
                            text: "Keybind already in use"
                            color: root.fg
                            font.pixelSize: 15
                            font.weight: Font.Medium
                        }

                        Text {
                            text: "\"" + root.takenByDesc + "\" already uses " + root.pendingCombo + ". Replace it?"
                            color: root.muted
                            font.pixelSize: 13
                            wrapMode: Text.Wrap
                            width: parent.width
                        }

                        Row {
                            anchors.right: parent.right
                            spacing: 10

                            ToolBtn {
                                text: "Cancel"
                                onClicked: root.cancelPendingKeybind()
                            }

                            ToolBtn {
                                text: "Replace"
                                highlighted: true
                                onClicked: root.applyPendingKeybind()
                            }
                        }
                    }
                }
            }
        }
    }

    // ============================================= components

    component ToolBtn: Item {
        id: btn
        property string text: ""
        property string iconText: ""
        property string tooltip: ""
        property bool highlighted: false
        signal clicked
        implicitWidth: Math.max(44, (text.length > 0 ? 16 + text.length * 8 : 0) + (iconText.length > 0 ? 20 : 0))
        height: 40
        width: implicitWidth

        Rectangle {
            id: btnBg
            anchors.fill: parent
            radius: 8
            color: btn.highlighted ? root.accent : (btnArea.containsMouse ? "#232018" : root.fieldBg)
            border.width: 1
            border.color: btn.highlighted ? root.accent : (btnArea.containsMouse ? root.muted : root.fieldBorder)
        }

        Row {
            anchors.centerIn: parent
            spacing: 6

            Text {
                visible: btn.iconText.length > 0
                text: btn.iconText
                color: btn.highlighted ? root.bg : root.fg
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: 14
            }

            Text {
                visible: btn.text.length > 0
                text: btn.text
                color: btn.highlighted ? root.bg : root.fg
                font.pixelSize: 12
                font.weight: Font.Medium
            }
        }

        MouseArea {
            id: btnArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                    btn.clicked();
                }
        }

        ToolTip.visible: btnArea.containsMouse && !btnArea.pressed && btn.tooltip.length > 0
        ToolTip.text: btn.tooltip
        ToolTip.delay: 600
    }

    component KeybindField: Item {
        id: kfield
        property string label: ""
        property string configKey: ""
        property string value: ""
        width: parent.width
        height: 44
        onValueChanged: {
            if (!kfieldInput.activeFocus)
                kfieldInput.text = kfield.value || "";
        }

        Rectangle {
            anchors.fill: parent
            radius: 8
            color: kfieldInput.activeFocus ? "#232018" : (kfArea.containsMouse ? "#1a1813" : root.fieldBg)
            border.width: 1
            border.color: kfieldInput.activeFocus ? root.accent : root.fieldBorder
        }

        Text {
            text: kfield.label
            color: root.fg
            font.pixelSize: 12
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
        }

        // Focus helper — declared FIRST so it sits BELOW the Row.
        // Clicks on label/padding focus the field; clicks on field/button
        // go to the Row (painted on top) naturally.
        MouseArea {
            id: kfArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: kfieldInput.forceActiveFocus()
            preventStealing: true
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            TextField {
                id: kfieldInput
                width: 200
                placeholderText: "None"
                placeholderTextColor: root.subtle
                color: root.fg
                font.pixelSize: 12
                font.family: "monospace"
                horizontalAlignment: TextInput.AlignRight
                background: Rectangle {
                    radius: 6
                    color: root.fieldBg
                    border.width: 1
                    border.color: kfieldInput.activeFocus ? root.accent : root.fieldBorder
                }
                onAccepted: root.commitKeybind(kfield.configKey, kfieldInput)
                Component.onCompleted: kfieldInput.text = kfield.value || ""
            }

            ToolBtn {
                id: kfieldApply
                width: 68
                height: kfieldInput.height
                text: "Apply"
                tooltip: "Write this keybind to Hyprland"
                onClicked: root.commitKeybind(kfield.configKey, kfieldInput)
            }
        }
    }
}
