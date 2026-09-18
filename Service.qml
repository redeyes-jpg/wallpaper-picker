import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Headless rotation timer + .desktop + keybind management.
//
// Follows the wallarchy pattern: the config file is the input, the CLI is the
// output, and the rotation stamp is written atomically by the CLI so other
// surfaces (and shell restarts) can reschedule correctly.
Item {
    id: root

    property var shell: null
    property var manifest: null

    readonly property string cliPath: Qt.resolvedUrl("wallpicker-cli").toString().replace(/^file:\/\//, "")
    readonly property string desktopTemplate: Qt.resolvedUrl("wallpicker.desktop").toString().replace(/^file:\/\//, "")
    readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/wallpicker.json"
    readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/wallpicker/rotation.json"

    property int rotateMinutes: 0
    property bool rotationEnabled: false
    property double lastRotatedMs: 0
    property bool configLoaded: false
    property bool stateLoaded: false

    readonly property double intervalMs: rotateMinutes > 0 ? rotateMinutes * 60000 : 0
    readonly property double dueAtMs: lastRotatedMs > 0 && intervalMs > 0 ? lastRotatedMs + intervalMs : 0

    function applyConfig(raw) {
        var config = Model.parseJson(raw, {}, 65536);
        rotateMinutes = Model.asInt(config.rotationIntervalMin, 0);
        var enabled = Model.asBool(config.rotationEnabled, false);
        if (configLoaded && (enabled !== rotationEnabled))
            notify(enabled ? "Wallpaper rotation started" : "Wallpaper rotation stopped", enabled ? "Every " + Model.intervalLabel(rotateMinutes) : "");
        rotationEnabled = enabled;
        configLoaded = true;
        reschedule();
    }

    function applyState(raw) {
        var state = Model.parseJson(raw, {}, 65536);
        var stamp = Number(state.lastRotatedMs);
        lastRotatedMs = isFinite(stamp) && stamp > 0 ? stamp : 0;
        stateLoaded = true;
        reschedule();
    }

    // A single timer that is always re-armed to the *remaining* time rather than
    // a fresh full interval. Without this, restarting the shell (or saving a
    // plugin file, which hot-reloads it) would silently postpone every rotation.
    function reschedule() {
        if (!configLoaded || !stateLoaded)
            return;
        if (intervalMs <= 0) {
            rotateTimer.stop();
            return;
        }

        var now = Date.now();
        if (lastRotatedMs <= 0 || lastRotatedMs > now) {
            // No stamp yet, or a clock that moved backwards: start the clock now
            // instead of firing immediately and surprising the user.
            stamp(now);
            return;
        }

        var remaining = dueAtMs - now;
        if (remaining <= 0) {
            rotate();
            return;
        }

        rotateTimer.stop();
        // QML's int interval tops out around 24 days; clamp so a long interval
        // wraps into a negative value instead of never firing.
        rotateTimer.interval = Math.min(remaining, 2073600000);
        rotateTimer.start();
    }

    function rotate() {
        if (rotateProcess.running)
            return;
        rotateProcess.command = [root.cliPath, "next"];
        rotateProcess.running = true;
    }

    function stamp(whenMs) {
        stampProcess.command = ["sh", "-c",
            'mkdir -p "$(dirname "$1")" && if [ -f "$1" ]; then jq --argjson t "$2" \'.lastRotatedMs = $t\' "$1" > "$1.tmp" && mv -f "$1.tmp" "$1"; else printf \'{"lastRotatedMs": %s}\\n\' "$2" > "$1"; fi',
            "sh", root.statePath, String(Math.round(whenMs))];
        stampProcess.running = true;
    }

    function setInterval(minutes) {
        var n = Model.asInt(minutes, 0);
        if (n < 0)
            n = 0;
        configProcess.command = [root.cliPath, "config", "set", "rotationIntervalMin", String(n)];
        configProcess.running = true;
    }

    function notify(headline, body) {
        notifyProcess.command = ["omarchy", "notification", "send",
            "--app-name", "wallpicker", "-g", "\u25A6",
            headline, body];
        notifyProcess.running = true;
    }

    FileView {
        path: root.configPath
        watchChanges: true
        printErrors: false
        onLoaded: root.applyConfig(text())
        onFileChanged: reload()
        onLoadFailed: root.applyConfig("{}")
    }

    FileView {
        path: root.statePath
        watchChanges: true
        printErrors: false
        onLoaded: root.applyState(text())
        onFileChanged: reload()
        onLoadFailed: root.applyState("{}")
    }

    Timer {
        id: rotateTimer
        repeat: false
        onTriggered: root.rotate()
    }

    Process {
        id: rotateProcess
        command: []
        stdout: StdioCollector {
            waitForEnd: true
        }
        // Stamp on both success and failure. A failed rotate should wait out the
        // next full interval, not retry in a tight loop.
        onExited: root.stamp(Date.now())
    }

    Process {
        id: stampProcess
        command: []
    }

    Process {
        id: configProcess
        command: []
        stdout: StdioCollector {
            waitForEnd: true
        }
        onExited: function (code) {
            if (code !== 0) {
                notify("Wallpaper rotation", "Failed to update rotation settings");
            }
        }
    }

    Process {
        id: notifyProcess
        command: []
    }

    // ------------------------------------------------------------ lifecycle

    // The shell assigns manifest after createObject() has already run
    // Component.onCompleted, and a binding on it has not re-evaluated by the
    // time this fires, so the paths are built here rather than bound.
    onManifestChanged: {
        if (installed || root.desktopTemplate.length === 0)
            return;
        installed = true;
        Quickshell.execDetached(["sh", "-c", installScript, "sh", root.desktopTemplate]);
    }

    readonly property string installScript: '[ -f "$1" ] || exit 0\n' + 'dest="$HOME/.local/share/applications/wallpicker.desktop"\n' + 'if [ -e "$dest" ] && ! grep -q "X-Wallpicker-Managed=true" "$dest"; then exit 0; fi\n' + 'mkdir -p "$(dirname "$dest")" || exit 0\n' + 'tmp="$dest.wallpicker.new"\n' + 'sed "s|@ICON@|preferences-desktop-wallpaper|" "$1" > "$tmp" || exit 0\n' + 'if cmp -s "$tmp" "$dest"; then rm -f "$tmp"; else mv -f "$tmp" "$dest"; fi\n'

    readonly property string removeScript: 'dest="$HOME/.local/share/applications/wallpicker.desktop"\n' + 'grep -q "X-Wallpicker-Managed=true" "$dest" 2>/dev/null && rm -f "$dest"\n'

    property bool installed: false

    // Reached on disable and on remove alike: omarchy-plugin-remove disables
    // first, so the service is torn down while the entry is still ours.
    Component.onDestruction: {
        if (!installed)
            return;
        Quickshell.execDetached(["sh", "-c", removeScript, "sh"]);
    }
}
