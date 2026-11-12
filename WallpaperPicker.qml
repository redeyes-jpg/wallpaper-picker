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

    property string picturesDir: "$HOME/Pictures"
    property bool recursive: false

    property int columns: 5
    property int gridSpacing: 14
    property string hoveredPath: ""
    property bool loading: false
    property bool wallhavenLoading: false
    property string statusText: ""
    property bool showSettings: false

    property bool rotationEnabled: false
    property int rotationIntervalMin: 30
    property bool rotationRandom: true

    property bool showWallhaven: false
    property int wallhavenPage: 1
    property bool wallhavenEnd: false
    property int wallhavenTotal: 0
    property string wallhavenQuery: ""
    property string wallhavenCategories: "111"
    property string wallhavenPurity: "100"
    property string wallhavenSorting: "date_added"
    property string wallhavenRatios: ""
    property string wallhavenAtleast: ""

    property bool previewVisible: false
    property string previewImageSource: ""
    property string previewLabel: ""
    property string previewWallhavenId: ""
    property bool previewCloseAfterDownload: false

    property int wallhavenRequestSerial: 0
    property int wallhavenActiveRequest: 0
    property bool wallhavenRestartPending: false

    property var pendingConfigKey: ""
    property var pendingCombo: ""
    property var pendingField: null
    property string takenByDesc: ""
    property bool takenPopupVisible: false

    property bool selectionMode: false
    property var selectedPaths: []
    property int selectionAnchor: -1
    property bool deleteConfirmVisible: false
    property var pendingDeletePaths: []
    property string currentBackground: ""

    // Collections
    property string localTabMode: ""
    property var collectionsList: []
    property bool collectionsLoading: false
    property bool addCollectionPopupVisible: false
    property string addCollectionTarget: ""
    property var addCollectionPopupPaths: []
    property string deleteCollectionName: ""
    property bool deleteCollectionConfirmVisible: false
    property string collectionOp: ""
    property string collectionOpName: ""
    property var collectionOpPaths: []
    property bool pendingAddAfterCreate: false
    // Collection names whose section is expanded (built-in Omarchy section starts open).
    property var expandedCollections: ({ "Omarchy Themes": true })
    // Right-click context menu
    property bool contextMenuVisible: false
    property real contextMenuX: 0
    property real contextMenuY: 0
    property string contextMenuPath: ""
    property string contextMenuCollection: ""

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

    ListModel {
        id: wallhavenModel
        onCountChanged: Qt.callLater(root.maybeLoadMoreWallhaven)
    }

    property var commandQueue: []

    function enqueueCommand(args) {
        commandQueue.push(args)
        drainCommandQueue()
    }

    function drainCommandQueue() {
        if (configProcess.running)
            return
        if (commandQueue.length === 0)
            return
        var args = commandQueue.shift()
        configProcess.command = [root.cliPath].concat(args)
        configProcess.running = true
    }

    function reload() {
        root.loading = true
        root.statusText = ""
        imageModel.clear()
        listProc.command = [root.cliPath, "list"]
        listProc.running = true
    }

    // Kick off background thumbnail generation; re-lists when finished.
    function warmThumbnails() {
        if (warmThumbsProc.running)
            return
        warmThumbsProc.command = [root.cliPath, "thumbs"]
        warmThumbsProc.running = true
    }

    // Re-read the folder without the warming side-effects (used after thumbs land).
    function relist() {
        root.loading = true
        imageModel.clear()
        listProc.command = [root.cliPath, "list"]
        listProc.running = true
    }

    function baseName(path) {
        var parts = String(path || "").split("/")
        return parts[parts.length - 1]
    }

    function imagePath(path) {
        var value = String(path || "")
        if (value.indexOf("http://") === 0 || value.indexOf("https://") === 0 || value.indexOf("file:") === 0)
            return value
        return "file://" + value
    }

    function setWallpaper(path) {
        root.statusText = "Applying " + root.baseName(path) + "…"
        Util.execDetached("omarchy theme bg set " + Util.shellQuote(path))
        root.currentBgRefreshTimer.restart()
    }

    function applyWallhaven(id) {
        if (!id)
            return
        root.statusText = "Downloading Wallhaven wallpaper…"
        wallhavenApplyProc.command = [root.cliPath, "wallhaven", "apply", id]
        wallhavenApplyProc.running = true
    }

    function openPreview(cell) {
        root.previewImageSource = cell.hasOwnProperty("fullPath") && cell.fullPath ? cell.fullPath : cell.path
        root.previewLabel = cell.label || ""
        root.previewWallhavenId = cell.wallhavenId || ""
        root.previewVisible = true
    }

    function closePreview() {
        root.previewVisible = false
    }

    function isSelected(path) {
        return root.selectedPaths.indexOf(path) !== -1
    }

    function enterSelectionMode() {
        root.selectionMode = true
        root.selectedPaths = []
        root.selectionAnchor = -1
    }

    function cancelSelection() {
        root.selectionMode = false
        root.selectedPaths = []
        root.selectionAnchor = -1
    }

    function toggleSelected(path, index, modifiers) {
        var paths = root.selectedPaths.slice()
        if ((modifiers & Qt.ShiftModifier) && root.selectionAnchor >= 0 && root.selectionAnchor !== index) {
            var start = Math.min(root.selectionAnchor, index)
            var end = Math.max(root.selectionAnchor, index)
            for (var i = start; i <= end; i++) {
                var item = imageModel.get(i)
                if (item && paths.indexOf(item.path) === -1)
                    paths.push(item.path)
            }
        } else {
            var pos = paths.indexOf(path)
            if (pos === -1)
                paths.push(path)
            else
                paths.splice(pos, 1)
            root.selectionAnchor = index
        }
        root.selectedPaths = paths
    }

    // ---------------------------------------------------------------- collections

    function loadCollections() {
        root.collectionsLoading = true
        collectionsListProc.command = [root.cliPath, "collections", "list"]
        collectionsListProc.running = true
    }

    function parseCollections(data) {
        root.collectionsLoading = false
        var list = (data instanceof Array) ? data : []
        // Keep the built-in Omarchy Themes collection at the top.
        var reordered = []
        for (var i = 0; i < list.length; i++) {
            if (list[i].id === "omarchy")
                reordered.push(list[i])
        }
        for (var j = 0; j < list.length; j++) {
            if (list[j].id !== "omarchy")
                reordered.push(list[j])
        }
        root.collectionsList = reordered
    }

    // Normalized grid entries for a named collection (JS array model for GridView).
    function gridEntriesFor(collectionName) {
        for (var i = 0; i < root.collectionsList.length; i++) {
            var c = root.collectionsList[i]
            if (c.name === collectionName) {
                var out = []
                var paths = c.paths instanceof Array ? c.paths : []
                for (var j = 0; j < paths.length; j++) {
                    var e = paths[j]
                    out.push({
                        path: String(e.path || ""),
                        thumb: String(e.thumb || ""),
                        fullPath: "",
                        wallhavenId: "",
                        label: "",
                        color: "",
                        collectionName: collectionName
                    })
                }
                return out
            }
        }
        return []
    }

    function collectionCount(name) {
        var entries = root.gridEntriesFor(name)
        return entries.length
    }

    function isCollectionExpanded(name) {
        return root.expandedCollections[String(name)] === true
    }

    function toggleCollectionExpanded(name) {
        var key = String(name)
        var next = {}
        for (var k in root.expandedCollections) {
            if (Object.prototype.hasOwnProperty.call(root.expandedCollections, k))
                next[k] = root.expandedCollections[k]
        }
        if (next[key])
            delete next[key]
        else
            next[key] = true
        root.expandedCollections = next
    }

    // Whether the "Collections" tab has any user-created collections.
    function hasUserCollections() {
        for (var i = 0; i < root.collectionsList.length; i++) {
            if (root.collectionsList[i].id !== "omarchy")
                return true
        }
        return false
    }

    // Switch the local wallpapers area between "all" and "collections".
    function showLocalTab(mode) {
        root.showWallhaven = false
        root.showSettings = false
        root.closeCellContextMenu()
        root.cancelSelection()
        root.localTabMode = (mode === "collections") ? "collections" : ""
        if (root.localTabMode === "collections") {
            root.loadCollections()
        } else {
            root.reload()
        }
    }

    function createCollection(name) {
        var trimmed = String(name || "").trim()
        if (!trimmed)
            return
        for (var i = 0; i < root.collectionsList.length; i++) {
            if (root.collectionsList[i].name === trimmed) {
                root.statusText = "A collection named \"" + trimmed + "\" already exists"
                return
            }
        }
        root.collectionOp = "create"
        root.collectionOpName = trimmed
        root.collectionOpPaths = []
        root.statusText = "Creating collection…"
        collectionOpProc.command = [root.cliPath, "collections", "create", trimmed]
        collectionOpProc.running = true
    }

    // Create a collection and add the given paths to it (used by "New collection" in the popup).
    function createCollectionAndAdd(name, paths) {
        var trimmed = String(name || "").trim()
        if (!trimmed)
            return
        for (var i = 0; i < root.collectionsList.length; i++) {
            if (root.collectionsList[i].name === trimmed) {
                root.statusText = "A collection named \"" + trimmed + "\" already exists"
                return
            }
        }
        root.collectionOp = "create"
        root.collectionOpName = trimmed
        root.collectionOpPaths = (paths instanceof Array) ? paths.slice() : []
        root.pendingAddAfterCreate = true
        root.closeAddCollectionPopup()
        root.statusText = "Creating collection…"
        collectionOpProc.command = [root.cliPath, "collections", "create", trimmed]
        collectionOpProc.running = true
    }

    function addToCollection(name, paths) {
        var target = String(name || "")
        if (!target || !paths || paths.length === 0) {
            root.closeAddCollectionPopup()
            return
        }
        root.collectionOp = "add"
        root.collectionOpName = target
        root.collectionOpPaths = paths.slice()
        root.statusText = "Adding " + paths.length + " to " + target + "…"
        collectionOpProc.command = [root.cliPath, "collections", "add", target].concat(paths)
        collectionOpProc.running = true
    }

    function removeFromCollection(name, paths) {
        if (!name || !paths || paths.length === 0)
            return
        root.collectionOp = "remove"
        root.collectionOpName = name
        root.collectionOpPaths = paths.slice()
        root.statusText = "Removing " + paths.length + " from " + name + "…"
        collectionOpProc.command = [root.cliPath, "collections", "remove", name].concat(paths)
        collectionOpProc.running = true
    }

    function deleteCollection(name) {
        var target = String(name || "")
        if (!target)
            return
        if (target === "Omarchy Themes") {
            root.statusText = "The Omarchy Themes collection is built-in and cannot be deleted"
            return
        }
        root.deleteCollectionName = target
        root.deleteCollectionConfirmVisible = true
    }

    function confirmDeleteCollection() {
        var name = root.deleteCollectionName
        root.deleteCollectionConfirmVisible = false
        root.deleteCollectionName = ""
        if (!name)
            return
        root.collectionOp = "delete"
        root.collectionOpName = name
        root.collectionOpPaths = []
        root.statusText = "Deleting collection…"
        collectionOpProc.command = [root.cliPath, "collections", "delete", name]
        collectionOpProc.running = true
    }

    function cancelDeleteCollection() {
        root.deleteCollectionConfirmVisible = false
        root.deleteCollectionName = ""
    }

    // Popup: add wallpaper(s) to an existing collection.
    function openAddCollectionPopup(path) {
        root.addCollectionTarget = String(path || "")
        root.addCollectionPopupPaths = []
        root.addCollectionPopupVisible = true
        root.loadCollections()
    }

    function openAddCollectionPopupForPaths(paths) {
        if (!paths || paths.length === 0)
            return
        root.addCollectionTarget = ""
        root.addCollectionPopupPaths = paths.slice()
        root.addCollectionPopupVisible = true
        root.loadCollections()
    }

    function closeAddCollectionPopup() {
        root.addCollectionPopupVisible = false
        root.addCollectionPopupPaths = []
        root.addCollectionTarget = ""
    }

    // Add the popup's pending paths (bulk or single).
    function addPopupPathsToCollection(name) {
        var paths = root.addCollectionPopupPaths
        if (paths.length === 0 && root.addCollectionTarget)
            paths = [root.addCollectionTarget]
        root.addToCollection(name, paths)
    }

    function popupPathCount() {
        var n = root.addCollectionPopupPaths.length
        if (n === 0 && root.addCollectionTarget)
            n = 1
        return n
    }

    // Right-click context menu on a wallpaper cell.
    function openCellContextMenu(cell, localX, localY) {
        root.contextMenuPath = cell.path
        root.contextMenuCollection = cell.collectionName || ""
        // Position roughly under the cursor; clamped by the menu when shown.
        var mapPoint = cell.mapToItem(panel.contentItem ? panel.contentItem : root, localX, localY)
        root.contextMenuX = mapPoint.x
        root.contextMenuY = mapPoint.y
        root.contextMenuVisible = true
    }

    function closeCellContextMenu() {
        root.contextMenuVisible = false
    }

    // Menu order must match the Repeater model above: Preview, Apply, Add/Remove, Trash.
    function activateContextMenuOption(index) {
        var path = root.contextMenuPath
        var collection = root.contextMenuCollection
        root.closeCellContextMenu()
        if (!path)
            return
        if (index === 0) {
            root.openPreview({ path: path, fullPath: "", label: "", wallhavenId: "" })
        } else if (index === 1) {
            root.setWallpaper(path)
        } else if (index === 2) {
            if (collection !== "")
                root.removeFromCollection(collection, [path])
            else
                root.openAddCollectionPopup(path)
        } else if (index === 3) {
            root.requestRemove([path])
        }
    }

    function requestRemove(paths) {
        if (!paths || paths.length === 0)
            return
        root.pendingDeletePaths = paths.slice()
        root.deleteConfirmVisible = true
    }

    function cancelRemove() {
        root.deleteConfirmVisible = false
        root.pendingDeletePaths = []
    }

    function confirmRemove() {
        var paths = root.pendingDeletePaths.slice()
        if (paths.length === 0) {
            root.cancelRemove()
            return
        }
        root.deleteConfirmVisible = false
        root.statusText = "Moving " + paths.length + " wallpaper(s) to Trash…"
        removeProc.command = [root.cliPath, "remove"].concat(paths)
        removeProc.running = true
    }

    function removePathsFromModel(paths) {
        for (var i = imageModel.count - 1; i >= 0; i--) {
            if (paths.indexOf(imageModel.get(i).path) !== -1)
                imageModel.remove(i)
        }
    }

    function refreshCurrentBackground() {
        if (currentBgProc.running)
            return
        currentBgProc.command = ["readlink", "-f", Quickshell.env("HOME") + "/.local/state/omarchy/current/background"]
        currentBgProc.running = true
    }

    function downloadWallhaven(id, closeAfter) {
        if (!id)
            return
        root.previewCloseAfterDownload = !!closeAfter
        root.statusText = "Downloading Wallhaven wallpaper…"
        wallhavenDownloadProc.command = [root.cliPath, "wallhaven", "fetch", id]
        wallhavenDownloadProc.running = true
    }

    function toggleRotation() {
        root.setConfig("rotationEnabled", root.rotationEnabled ? "false" : "true")
    }

    function setConfig(key, value) {
        root.enqueueCommand(["config", "set", key, value])
    }

    function setWallhavenConfig(key, value) {
        root.enqueueCommand(["wallhaven", "config", "set", key, value])
    }

    function cycleInterval() {
        root.rotationIntervalMin = Model.nextInterval(root.rotationIntervalMin)
        root.setConfig("rotationIntervalMin", String(root.rotationIntervalMin))
    }

    function toggleRotationMode() {
        root.rotationRandom = !root.rotationRandom
        root.setConfig("rotationRandom", root.rotationRandom ? "true" : "false")
    }

    function rotateNow() {
        root.statusText = "Applying next wallpaper…"
        root.enqueueCommand(["next"])
    }

    function applyFolder() {
        root.picturesDir = folderField.text.trim()
        root.setConfig("picturesDir", root.picturesDir)
        root.setConfig("recursive", root.recursive ? "true" : "false")
        root.reload()
    }

    function rotationIntervalLabel() {
        if (root.rotationIntervalMin <= 0)
            return "Off"
        return Model.intervalLabel(root.rotationIntervalMin)
    }

    function rotationDescription() {
        if (root.rotationEnabled && root.rotationIntervalMin > 0)
            return "Rotation is active — wallpaper changes every " + Model.intervalLabel(root.rotationIntervalMin).toLowerCase() + ", picking " + (root.rotationRandom ? "at random" : "in order") + "."
        if (root.rotationIntervalMin > 0)
            return "Rotation is off. Start it to change the wallpaper every " + Model.intervalLabel(root.rotationIntervalMin).toLowerCase() + "."
        return "Rotation interval is set to Off."
    }

    function categoriesValue(value) {
        var number = parseInt(value, 10)
        if (!isFinite(number) || number < 0 || number > 7)
            return "111"
        return String(number)
    }

    function purityValue(value) {
        return ["100", "010", "001"].indexOf(value) >= 0 ? value : "100"
    }

    function sortingValue(value) {
        var options = ["relevance", "random", "date_added", "views", "favorites", "toplist"]
        return options.indexOf(value) >= 0 ? value : "date_added"
    }

    function ratiosValue(value) {
        var options = ["", "16x9", "16x10", "21x9", "32x9", "4x3", "5x4", "3x2"]
        return options.indexOf(value) >= 0 ? value : ""
    }

    function resolutionValue(value) {
        var options = ["", "1920x1080", "2560x1440", "3840x2160", "5120x2880", "2560x1080", "3440x1440", "5120x2160"]
        return options.indexOf(value) >= 0 ? value : ""
    }

    function purityLabel() {
        if (root.wallhavenPurity === "010")
            return "Sketchy"
        if (root.wallhavenPurity === "001")
            return "NSFW"
        return "SFW"
    }

    function sortingLabel() {
        var labels = {
            relevance: "Relevance",
            random: "Random",
            date_added: "Date",
            views: "Views",
            favorites: "Favs",
            toplist: "Toplist"
        }
        return labels[root.wallhavenSorting] || "Relevance"
    }

    function resolutionLabel() {
        return root.wallhavenAtleast || "Any"
    }

    function ratioLabel() {
        return root.wallhavenRatios || "Any"
    }

    function resetWallhaven() {
        root.wallhavenRequestSerial += 1
        root.wallhavenPage = 1
        wallhavenModel.clear()
        root.wallhavenTotal = 0
        root.wallhavenEnd = false
        root.wallhavenLoading = true
        if (wallhavenProc.running) {
            // Let onExited restart cleanly; killing the process would otherwise
            // report a bogus "Wallhaven request failed".
            root.wallhavenRestartPending = true
            wallhavenProc.running = false
            return
        }
        root.loadWallhaven()
    }

    function resetWallhavenFilters() {
        wallhavenSearchField.text = ""
        root.wallhavenQuery = ""
        root.wallhavenRatios = ""
        root.wallhavenAtleast = ""
        root.setWallhavenConfig("ratios", "")
        root.setWallhavenConfig("atleast", "")
        root.resetWallhaven()
    }

    function loadWallhaven() {
        if (wallhavenProc.running)
            return
        root.wallhavenRequestSerial += 1
        root.wallhavenActiveRequest = root.wallhavenRequestSerial
        root.wallhavenLoading = true
        root.statusText = "Loading Wallhaven…"
        var args = [root.cliPath, "wallhaven", root.wallhavenQuery ? "search" : "photos"]
        if (root.wallhavenQuery)
            args.push(root.wallhavenQuery)
        args.push(String(root.wallhavenPage), root.wallhavenCategories, root.wallhavenPurity, root.wallhavenSorting, root.wallhavenRatios, root.wallhavenAtleast)
        wallhavenProc.command = args
        wallhavenProc.running = true
    }

    function loadMoreWallhaven() {
        if (root.wallhavenLoading || root.wallhavenEnd || wallhavenProc.running)
            return
        root.wallhavenPage += 1
        root.wallhavenLoading = true
        var args = [root.cliPath, "wallhaven", root.wallhavenQuery ? "search" : "photos"]
        if (root.wallhavenQuery)
            args.push(root.wallhavenQuery)
        args.push(String(root.wallhavenPage), root.wallhavenCategories, root.wallhavenPurity, root.wallhavenSorting, root.wallhavenRatios, root.wallhavenAtleast)
        wallhavenProc.command = args
        wallhavenProc.running = true
    }

    function maybeLoadMoreWallhaven() {
        if (!root.showWallhaven || root.wallhavenLoading || root.wallhavenEnd)
            return
        if (wallhavenProc.running)
            return
        // Use the model size instead of grid.contentHeight: contentHeight can be
        // stale right after appending a page and would trigger runaway loading.
        var rows = Math.ceil(wallhavenModel.count / Math.max(1, root.columns))
        var expectedHeight = rows * grid.cellHeight
        if (grid.contentY + grid.height >= expectedHeight - 200)
            root.loadMoreWallhaven()
    }

    function toggleCategory(bit) {
        var current = parseInt(root.wallhavenCategories, 10)
        var next = current ^ bit
        if (next === 0)
            next = 7
        root.wallhavenCategories = String(next)
        root.setWallhavenConfig("categories", root.wallhavenCategories)
        root.resetWallhaven()
    }

    function cyclePurity() {
        var options = ["100", "010", "001"]
        var index = options.indexOf(root.wallhavenPurity)
        root.wallhavenPurity = options[(index + 1) % options.length]
        root.setWallhavenConfig("purity", root.wallhavenPurity)
        root.resetWallhaven()
    }

    function cycleSorting() {
        var options = ["date_added", "random", "views", "favorites", "toplist", "relevance"]
        var index = options.indexOf(root.wallhavenSorting)
        root.wallhavenSorting = options[(index + 1) % options.length]
        root.setWallhavenConfig("sorting", root.wallhavenSorting)
        root.resetWallhaven()
    }

    function cycleRatios() {
        var options = ["", "16x9", "16x10", "21x9", "32x9", "4x3", "5x4", "3x2"]
        var index = options.indexOf(root.wallhavenRatios)
        root.wallhavenRatios = options[(index + 1) % options.length]
        root.setWallhavenConfig("ratios", root.wallhavenRatios)
        root.resetWallhaven()
    }

    function hasWallhavenTag(name) {
        return root.wallhavenQuery.split(/\s+/).indexOf(name) >= 0
    }

    function toggleWallhavenTag(name) {
        var parts = root.wallhavenQuery.split(/\s+/).filter(function(p) { return p.length > 0 && p !== name })
        if (!root.hasWallhavenTag(name)) parts.push(name)
        var q = parts.join(" ")
        wallhavenSearchField.text = q
        root.wallhavenQuery = q
        root.resetWallhaven()
    }

    function cycleResolution() {
        var options = ["", "1920x1080", "2560x1440", "3840x2160", "5120x2880", "2560x1080", "3440x1440", "5120x2160"]
        var index = options.indexOf(root.wallhavenAtleast)
        root.wallhavenAtleast = options[(index + 1) % options.length]
        root.setWallhavenConfig("atleast", root.wallhavenAtleast)
        root.resetWallhaven()
    }

    function normalizeCombo(raw) {
        var t = String(raw || "").trim()
        if (t === "")
            return ""
        var parts = t.toUpperCase().split(/[\s+,.]+/).filter(function (part) {
            return part.length > 0
        })
        if (parts.length < 2)
            return ""
        var key = root.normalizeKeyToken(parts[parts.length - 1])
        if (key === "")
            return ""
        var mods = []
        for (var i = 0; i < parts.length - 1; i++) {
            var modifier = root.normalizeModToken(parts[i])
            if (modifier === "")
                return ""
            if (mods.indexOf(modifier) < 0)
                mods.push(modifier)
        }
        if (mods.length === 0)
            return ""
        var order = ["SUPER", "SHIFT", "CTRL", "ALT"]
        var out = []
        for (var j = 0; j < order.length; j++)
            if (mods.indexOf(order[j]) >= 0)
                out.push(order[j])
        out.push(key)
        return out.join(" + ")
    }

    function normalizeModToken(token) {
        switch (token) {
        case "SUPER":
        case "WIN":
        case "META":
        case "WINDOWS":
        case "MOD4":
        case "SUPER_L":
        case "SUPER_R":
            return "SUPER"
        case "SHIFT":
        case "SHIFT_L":
        case "SHIFT_R":
            return "SHIFT"
        case "CTRL":
        case "CONTROL":
        case "CTRL_L":
        case "CTRL_R":
            return "CTRL"
        case "ALT":
        case "ALT_L":
        case "ALT_R":
        case "MOD1":
            return "ALT"
        }
        return ""
    }

    function normalizeKeyToken(token) {
        if (token.length === 1 && token >= "A" && token <= "Z")
            return token
        if (token.length === 1 && token >= "0" && token <= "9")
            return token
        if (token.length >= 2 && token.charAt(0) === "F" && !isNaN(Number(token.substring(1))) && Number(token.substring(1)) >= 1 && Number(token.substring(1)) <= 12)
            return token
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
        }
        if (token in names)
            return names[token]
        return ""
    }

    function comboModmask(combo) {
        var mask = 0
        if (combo.indexOf("SHIFT") >= 0)
            mask |= 1
        if (combo.indexOf("CTRL") >= 0)
            mask |= 4
        if (combo.indexOf("ALT") >= 0)
            mask |= 8
        if (combo.indexOf("SUPER") >= 0)
            mask |= 64
        return mask
    }

    function comboKeyName(combo) {
        var parts = combo.split(" + ")
        return parts[parts.length - 1]
    }

    function isWallpickerBind(description) {
        return description === "Wallpaper picker" || description === "Toggle wallpaper rotation" || description === "Rotate wallpaper now"
    }

    function descForConfigKey(configKey) {
        if (configKey === "keybindToggleRotation")
            return "Toggle wallpaper rotation"
        if (configKey === "keybindRotateNow")
            return "Rotate wallpaper now"
        return "Wallpaper picker"
    }

    function commitKeybind(configKey, field) {
        var combo = root.normalizeCombo(field.text)
        var previous = root.configData && root.configData[configKey] ? root.configData[configKey] : ""
        if (combo === "") {
            if (field.text.trim() !== "")
                root.statusText = "Invalid combo — type e.g. SUPER + W"
            field.text = previous
            return
        }
        if (combo === previous) {
            field.text = previous
            return
        }
        root.pendingConfigKey = configKey
        root.pendingCombo = combo
        root.pendingField = field
        bindsProc.command = ["hyprctl", "binds", "-j"]
        bindsProc.running = true
    }

    function applyPendingKeybind() {
        if (root.pendingConfigKey === "" || root.pendingCombo === "")
            return
        root.statusText = ""
        root.keybindVerifyCombo = root.pendingCombo
        root.keybindVerifyDesc = root.descForConfigKey(root.pendingConfigKey)
        root.keybindVerifyKey = root.comboKeyName(root.pendingCombo).toUpperCase()
        root.keybindVerifyMask = root.comboModmask(root.pendingCombo)
        root.keybindVerifyPending = true
        root.setConfig(root.pendingConfigKey, root.pendingCombo)
        root.enqueueCommand(["keybinds", "apply"])
        if (root.pendingField)
            root.pendingField.text = root.pendingCombo
        root.pendingConfigKey = ""
        root.pendingCombo = ""
        root.pendingField = null
        root.takenPopupVisible = false
    }

    function runKeybindVerify() {
        var combo = root.keybindVerifyCombo
        var description = root.keybindVerifyDesc
        var key = root.keybindVerifyKey
        var mask = root.keybindVerifyMask
        var quotedCombo = combo.replace(/'/g, "'\\''")
        var script = "lua=\"$HOME/.config/hypr/wallpicker.lua\"; " +
            "if ! grep -Fq '" + quotedCombo + "' \"$lua\"; then echo MISSING_LUA; exit 1; fi; " +
            "if ! hyprctl binds -j | jq -e '[.[] | select((.submap // \"\") == \"\" and .key == \"" + key + "\" and .modmask == " + mask + " and .description == \"" + description + "\")] | length > 0' >/dev/null 2>&1; then echo NOT_BOUND; exit 2; fi; " +
            "echo APPLIED"
        verifyProc.command = ["bash", "-c", script]
        verifyProc.running = true
    }

    function cancelPendingKeybind() {
        var previous = root.configData && root.configData[root.pendingConfigKey] ? root.configData[root.pendingConfigKey] : ""
        if (root.pendingField)
            root.pendingField.text = previous
        root.pendingConfigKey = ""
        root.pendingCombo = ""
        root.pendingField = null
        root.takenPopupVisible = false
    }

    property var configData: null
    property bool keybindVerifyPending: false
    property string keybindVerifyCombo: ""
    property string keybindVerifyDesc: ""
    property string keybindVerifyKey: ""
    property int keybindVerifyMask: 0

    function open(payloadJson) {
        root.opened = true
        root.previewVisible = false
        root.localTabMode = ""
        root.cancelSelection()
        root.cancelRemove()
        root.refreshCurrentBackground()
        root.reload()
        Qt.callLater(function () {
            keyCatcher.forceActiveFocus()
        })
    }

    function close() {
        root.opened = false
    }

    function dismiss() {
        root.opened = false
        root.contextMenuVisible = false
        if (root.shell && typeof root.shell.hide === "function")
            root.shell.hide((root.manifest && root.manifest.id) || "wallpicker.grid")
    }

    function toggle() {
        if (root.opened)
            root.dismiss()
        else
            root.open("{}")
    }

    IpcHandler {
        target: "wallpicker"

        function toggle(): string {
            root.toggle()
            return "ok"
        }

        function open(): string {
            root.open("{}")
            return "ok"
        }

        function close(): string {
            root.dismiss()
            return "ok"
        }

        function status(): string {
            return root.opened ? "open" : "closed"
        }

        function toggleRotation(): string {
            root.toggleRotation()
            return "ok"
        }

        function cycleNow(): string {
            root.rotateNow()
            return "ok"
        }

        function setInterval(minutes: string): string {
            var value = Number(minutes)
            if (!isFinite(value))
                return "err"
            root.rotationIntervalMin = Math.round(value)
            root.setConfig("rotationIntervalMin", String(root.rotationIntervalMin))
            return "ok"
        }

        function rotationStatus(): string {
            if (root.rotationEnabled && root.rotationIntervalMin > 0)
                return "active:" + root.rotationIntervalMin
            return "inactive"
        }
    }

    Process {
        id: listProc
        command: []
        stdout: StdioCollector {
            id: listStdout
            waitForEnd: true
        }
        onExited: function (code) {
            root.loading = false
            if (code !== 0) {
                root.statusText = "Failed to read wallpaper folder"
                return
            }
            var items = Model.parseJson(listStdout.text, [], 16777216)
            if (!(items instanceof Array)) {
                root.statusText = "Invalid wallpaper list"
                return
            }
            for (var i = 0; i < items.length; i++) {
                var entry = items[i]
                var p = (entry && typeof entry === "object") ? (entry.path || "") : String(entry)
                var t = (entry && typeof entry === "object") ? (entry.thumb || "") : ""
                imageModel.append({
                    path: String(p),
                    thumb: String(t),
                    fullPath: "",
                    wallhavenId: "",
                    label: "",
                    color: ""
                })
            }
            if (items.length === 0)
                root.statusText = "No images found in " + root.picturesDir
            else
                root.warmThumbnails()
        }
    }

    // Generate any missing cached thumbnails in the background, then re-list
    // so the grid can switch to the (much cheaper) cached versions.
    Process {
        id: warmThumbsProc
        command: []
        stdout: StdioCollector {
            id: warmThumbsStdout
            waitForEnd: true
        }
        onExited: function (code) {
            // Relist once only if new thumbnails appeared; the second pass
            // sees queued == 0 and stops, so this cannot loop forever.
            if (code !== 0)
                return
            var payload = Model.parseJson(warmThumbsStdout.text, {}, 1048576)
            if (payload && Number(payload.queued) > 0)
                root.relist()
        }
    }

    Process {
        id: collectionsListProc
        command: []
        stdout: StdioCollector {
            id: collectionsListStdout
            waitForEnd: true
        }
        onExited: function (code) {
            if (code !== 0) {
                root.collectionsLoading = false
                root.collectionsList = []
                return
            }
            var data = Model.parseJson(collectionsListStdout.text, [], 16777216)
            root.parseCollections(data)
        }
    }

    Process {
        id: collectionOpProc
        command: []
        stdout: StdioCollector {
            id: collectionOpStdout
            waitForEnd: true
        }
        onExited: function (code) {
            var op = root.collectionOp
            var name = root.collectionOpName
            var paths = root.collectionOpPaths
            var doAddAfter = root.pendingAddAfterCreate
            root.collectionOp = ""
            root.collectionOpName = ""
            root.collectionOpPaths = []
            root.pendingAddAfterCreate = false

            if (!op)
                return
            var payload = Model.parseJson(collectionOpStdout.text, {}, 1048576)
            if (code !== 0) {
                var msg = String(collectionOpStdout.text).trim()
                root.statusText = "Collection operation failed" + (msg ? ": " + msg : "")
                return
            }

            // create-then-add: finish the add now that the collection exists.
            if (op === "create" && doAddAfter && paths && paths.length > 0) {
                root.collectionOp = "add"
                root.collectionOpName = name
                root.collectionOpPaths = paths
                root.closeAddCollectionPopup()
                root.statusText = "Adding " + paths.length + " to " + name + "…"
                collectionOpProc.command = [root.cliPath, "collections", "add", name].concat(paths)
                collectionOpProc.running = true
                return
            }

            if (op === "create") {
                root.statusText = "Created collection \"" + name + "\""
                root.loadCollections()
            } else if (op === "add") {
                var added = (payload && payload.added !== undefined) ? payload.added : (paths ? paths.length : 0)
                root.statusText = added > 0 ? "Added " + added + " to " + name : "Already in " + name
                root.closeAddCollectionPopup()
                root.loadCollections()
            } else if (op === "remove") {
                var removed = (payload && payload.removed !== undefined) ? payload.removed : 0
                root.statusText = "Removed " + removed + " from " + name
                root.loadCollections()
            } else if (op === "delete") {
                root.statusText = "Deleted collection \"" + name + "\""
                root.loadCollections()
            }
        }
    }

    Process {
        id: removeProc
        command: []
        stdout: StdioCollector {
            id: removeStdout
            waitForEnd: true
        }
        onExited: function (code) {
            var payload = Model.parseJson(removeStdout.text, {}, 1048576)
            var removed = payload && payload.removed instanceof Array ? payload.removed : []
            var failed = payload && payload.failed instanceof Array ? payload.failed : []
            if (removed.length > 0)
                root.removePathsFromModel(removed)
            if (root.previewVisible && removed.indexOf(root.previewImageSource) !== -1)
                root.previewVisible = false
            root.hoveredPath = ""
            var removedCurrent = removed.indexOf(root.currentBackground) !== -1
            root.cancelSelection()
            root.pendingDeletePaths = []
            if (code !== 0 && removed.length === 0 && failed.length === 0) {
                root.statusText = "Failed to move wallpapers to Trash"
            } else if (failed.length > 0) {
                root.statusText = failed.length + " wallpaper(s) could not be moved to Trash"
            } else if (removedCurrent) {
                root.statusText = "Removed the current wallpaper — pick a new one"
            } else if (removed.length > 0) {
                root.statusText = removed.length + " wallpaper(s) moved to Trash"
            }
            if (imageModel.count === 0 && removed.length > 0)
                root.statusText = "No images left in " + root.picturesDir
            if (removedCurrent)
                root.currentBackground = ""
            // Collection membership was pruned by the CLI — refresh sections.
            if (removed.length > 0 && root.localTabMode === "collections")
                root.loadCollections()
        }
    }

    Process {
        id: currentBgProc
        command: []
        stdout: StdioCollector {
            id: currentBgStdout
            waitForEnd: true
        }
        onExited: function (code) {
            var value = String(currentBgStdout.text).trim()
            root.currentBackground = code === 0 ? value : ""
        }
    }

    Process {
        id: wallhavenProc
        command: []
        stdout: StdioCollector {
            id: wallhavenStdout
            waitForEnd: true
        }
        onExited: function (code) {
            if (root.wallhavenActiveRequest !== root.wallhavenRequestSerial) {
                if (root.wallhavenRestartPending) {
                    root.wallhavenRestartPending = false
                    if (root.showWallhaven)
                        root.loadWallhaven()
                }
                return
            }
            root.wallhavenLoading = false
            if (code !== 0) {
                root.statusText = "Wallhaven request failed"
                return
            }
            var payload = Model.parseJson(wallhavenStdout.text, {}, 16777216)
            var rows = Model.photoRows(payload)
            var total = payload && payload.meta && payload.meta.total !== undefined ? Number(payload.meta.total) : 0
            if (!isFinite(total))
                total = 0
            if (root.wallhavenPage === 1)
                wallhavenModel.clear()
            for (var i = 0; i < rows.length; i++) {
                var row = rows[i]
                wallhavenModel.append({
                    path: row.thumb,
                    fullPath: row.full,
                    wallhavenId: row.wallhavenId,
                    label: row.label,
                    color: row.color
                })
            }
            root.wallhavenTotal = total
            if (rows.length === 0) {
                root.wallhavenEnd = true
                if (wallhavenModel.count === 0)
                    root.statusText = "No results found"
            } else {
                root.wallhavenEnd = rows.length < 24 || (total > 0 && wallhavenModel.count >= total)
                if (total > 0)
                    root.statusText = wallhavenModel.count + " of " + total + " Wallhaven results"
                else
                    root.statusText = wallhavenModel.count + " Wallhaven results"
            }
        }
    }

    Process {
        id: wallhavenApplyProc
        command: []
        stdout: StdioCollector {
            id: wallhavenApplyStdout
            waitForEnd: true
        }
        onExited: function (code) {
            if (code === 0) {
                root.statusText = "Wallhaven wallpaper applied"
                root.currentBgRefreshTimer.restart()
            } else {
                var message = String(wallhavenApplyStdout.text).trim()
                root.statusText = message || "Failed to apply Wallhaven wallpaper"
            }
        }
    }

    Process {
        id: wallhavenDownloadProc
        command: []
        stdout: StdioCollector {
            id: wallhavenDownloadStdout
            waitForEnd: true
        }
        onExited: function (code) {
            if (code === 0) {
                var result = String(wallhavenDownloadStdout.text).trim()
                root.statusText = result || "Wallpaper downloaded"
                if (root.previewCloseAfterDownload) {
                    root.previewCloseAfterDownload = false
                    root.previewVisible = false
                }
                root.reload()
            } else {
                var message = String(wallhavenDownloadStdout.text).trim()
                root.statusText = message || "Failed to download wallpaper"
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
                root.statusText = "Command failed"
            if (root.keybindVerifyPending && configProcess.command.join(" ") === root.cliPath + " keybinds apply") {
                root.keybindVerifyPending = false
                if (code === 0)
                    root.runKeybindVerify()
                else
                    root.statusText = "Apply failed — wallpicker-cli exited " + code
            }
            root.drainCommandQueue()
        }
    }

    Process {
        id: bindsProc
        command: []
        stdout: StdioCollector {
            id: bindsStdout
            waitForEnd: true
        }
        onExited: function (code) {
            if (root.pendingConfigKey === "")
                return
            if (code !== 0) {
                root.applyPendingKeybind()
                return
            }
            var entries = Model.parseJson(bindsStdout.text, [], 16777216)
            var combo = root.pendingCombo
            var key = root.comboKeyName(combo).toUpperCase()
            var mask = root.comboModmask(combo)
            for (var i = 0; i < entries.length; i++) {
                var entry = entries[i]
                if ((entry.submap || "") !== "")
                    continue
                if (!entry.key)
                    continue
                if (entry.key.toUpperCase() !== key || entry.modmask !== mask)
                    continue
                if (root.isWallpickerBind(entry.description))
                    continue
                root.takenByDesc = entry.description || "another action"
                root.takenPopupVisible = true
                return
            }
            root.applyPendingKeybind()
        }
    }

    Process {
        id: verifyProc
        command: []
        stdout: StdioCollector {
            waitForEnd: true
        }
        onExited: function (code) {
            if (root.keybindVerifyCombo === "")
                return
            var output = String(text).trim()
            if (code === 0 && output === "APPLIED") {
                root.statusText = "Applied: " + root.keybindVerifyCombo
                root.appliedTimer.restart()
            } else if (output === "MISSING_LUA") {
                root.statusText = "Apply failed — binding not found in wallpicker.lua"
            } else if (output === "NOT_BOUND") {
                root.statusText = "Apply failed — Hyprland did not register the bind"
            } else {
                root.statusText = "Apply failed — verification exited " + code
            }
            root.keybindVerifyCombo = ""
            root.keybindVerifyDesc = ""
            root.keybindVerifyKey = ""
            root.keybindVerifyMask = 0
        }
    }

    Timer {
        id: appliedTimer
        interval: 8000
        repeat: false
        onTriggered: {
            if (root.statusText.indexOf("Applied:") === 0)
                root.statusText = ""
        }
    }

    Timer {
        id: currentBgRefreshTimer
        interval: 500
        repeat: false
        onTriggered: root.refreshCurrentBackground()
    }

    FileView {
        id: configFile
        path: root.configPath
        watchChanges: true
        printErrors: false
        onLoaded: root.applyConfig(text())
        onFileChanged: configFile.reload()
        onLoadFailed: root.applyConfig("{}")
    }

    function applyConfig(raw) {
        var config = Model.parseJson(raw, {}, 65536)
        root.configData = config
        root.picturesDir = (config.picturesDir || root.picturesDir).replace(/^\~\//, Quickshell.env("HOME") + "/")
        root.recursive = Model.asBool(config.recursive, root.recursive)
        root.columns = Math.max(2, Math.min(12, Model.asInt(config.columns, root.columns)))
        root.rotationEnabled = Model.asBool(config.rotationEnabled, root.rotationEnabled)
        root.rotationIntervalMin = Model.asInt(config.rotationIntervalMin, root.rotationIntervalMin)
        root.rotationRandom = Model.asBool(config.rotationRandom, root.rotationRandom)
        var wallhaven = config.wallhaven || {}
        root.wallhavenCategories = root.categoriesValue(wallhaven.categories || root.wallhavenCategories)
        root.wallhavenPurity = root.purityValue(wallhaven.purity || root.wallhavenPurity)
        root.wallhavenSorting = root.sortingValue(wallhaven.sorting || root.wallhavenSorting)
        root.wallhavenRatios = root.ratiosValue(wallhaven.ratios !== undefined ? wallhaven.ratios : root.wallhavenRatios)
        root.wallhavenAtleast = root.resolutionValue(wallhaven.atleast !== undefined ? wallhaven.atleast : root.wallhavenAtleast)
    }

    FloatingWindow {
        id: panel
        visible: root.opened
        title: "Wallpaper Picker"
        color: root.bg
        implicitWidth: 1100
        implicitHeight: 720
        minimumSize: Qt.size(640, 480)
        onVisibleChanged: {
            if (!visible && root.opened)
                root.dismiss()
        }

        Item {
            id: keyCatcher
            anchors.fill: parent
            focus: true
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function (event) {
                if (event.key === Qt.Key_Escape) {
                    if (root.addCollectionPopupVisible) {
                        root.closeAddCollectionPopup()
                        event.accepted = true
                    } else if (root.deleteCollectionConfirmVisible) {
                        root.cancelDeleteCollection()
                        event.accepted = true
                    } else if (root.deleteConfirmVisible) {
                        root.cancelRemove()
                        event.accepted = true
                    } else if (root.previewVisible) {
                        root.previewVisible = false
                        event.accepted = true
                    } else if (root.selectionMode) {
                        root.cancelSelection()
                        event.accepted = true
                    } else if (root.showSettings) {
                        root.showSettings = false
                        event.accepted = true
                    } else {
                        root.dismiss()
                        event.accepted = true
                    }
                } else if (event.key === Qt.Key_Delete && root.selectionMode && !root.deleteConfirmVisible && root.selectedPaths.length > 0) {
                    root.requestRemove(root.selectedPaths)
                    event.accepted = true
                }
            }

            Rectangle {
                anchors.fill: parent
                color: root.bg
            }

            Item {
                id: header
                width: parent.width
                height: 52
                anchors.top: parent.top

                Text {
                    id: headerTitle
                    text: root.showSettings ? "SETTINGS" : (root.showWallhaven ? "WALLHAVEN" : "WALLPAPERS")
                    color: root.muted
                    font.pixelSize: 11
                    font.letterSpacing: 3
                    font.weight: Font.Medium
                    anchors.left: parent.left
                    anchors.leftMargin: 28
                    anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                    text: (root.loading || root.wallhavenLoading) ? "loading…" : ((root.showWallhaven ? wallhavenModel.count : imageModel.count) + " images")
                    color: root.subtle
                    font.pixelSize: 11
                    font.letterSpacing: 1
                    anchors.left: headerTitle.right
                    anchors.leftMargin: 12
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
                        iconText: "\uDB80\uDF0D"
                        tooltip: "Back to wallpapers"
                        onClicked: root.showSettings = false
                    }

                    ToolBtn {
                        visible: !root.showSettings
                        iconText: "\uEAF8"
                        tooltip: "Settings"
                        onClicked: {
                            root.showSettings = true
                            root.cancelSelection()
                        }
                    }
                }
            }

            Item {
                id: tabs
                width: parent.width
                height: 40
                anchors.top: header.bottom

                ToolBtn {
                    id: tabWallpapersBtn
                    width: 120
                    height: 32
                    text: "WALLPAPERS"
                    tooltip: "Local wallpapers"
                    highlighted: !root.showWallhaven
                    anchors.left: parent.left
                    anchors.leftMargin: 28
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: {
                        root.showWallhaven = false
                        root.showSettings = false
                        root.cancelSelection()
                        root.wallhavenPage = 1
                        wallhavenModel.clear()
                        root.wallhavenEnd = false
                        // Keep the current local sub-tab (All / Collections).
                        if (root.localTabMode === "collections")
                            root.loadCollections()
                        else
                            root.reload()
                    }
                }

                ToolBtn {
                    id: tabWallhavenBtn
                    width: 120
                    height: 32
                    text: "WALLHAVEN"
                    tooltip: "Wallhaven API wallpapers"
                    highlighted: root.showWallhaven
                    anchors.left: tabWallpapersBtn.right
                    anchors.leftMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: {
                        root.showWallhaven = true
                        root.showSettings = false
                        root.closeCellContextMenu()
                        root.cancelSelection()
                        root.resetWallhaven()
                    }
                }

                // Sub-tabs for the local wallpapers area: All / Collections.
                Item {
                    id: localSubTabs
                    visible: !root.showWallhaven && !root.showSettings
                    anchors.left: tabWallhavenBtn.right
                    anchors.leftMargin: 24
                    anchors.verticalCenter: parent.verticalCenter
                    height: 32

                    ToolBtn {
                        id: subTabAll
                        anchors.left: parent.left
                        anchors.leftMargin: 16
                        anchors.verticalCenter: parent.verticalCenter
                        width: 72
                        height: 26
                        text: "All"
                        tooltip: "Every wallpaper in the folder"
                        highlighted: root.localTabMode !== "collections"
                        onClicked: root.showLocalTab("")
                    }

                    ToolBtn {
                        id: subTabCollections
                        anchors.left: subTabAll.right
                        anchors.leftMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        width: 110
                        height: 26
                        text: "Collections"
                        tooltip: "Your wallpaper collections"
                        highlighted: root.localTabMode === "collections"
                        onClicked: root.showLocalTab("collections")
                    }
                }
            }

            Item {
                id: wallhavenFilters
                visible: root.showWallhaven && !root.showSettings
                width: parent.width
                height: 88
                anchors.top: tabs.bottom

                Row {
                    id: filtersRow
                    anchors.left: parent.left
                    anchors.leftMargin: 28
                    anchors.top: parent.top
                    anchors.topMargin: 8
                    height: 32
                    spacing: 6

                    TextField {
                        id: wallhavenSearchField
                        width: 190
                        height: 32
                        placeholderText: "Search Wallhaven…"
                        placeholderTextColor: root.subtle
                        color: root.fg
                        font.pixelSize: 12
                        selectByMouse: true
                        background: Rectangle {
                            radius: 6
                            color: root.fieldBg
                            border.width: 1
                            border.color: wallhavenSearchField.activeFocus ? root.accent : root.fieldBorder
                        }
                        onAccepted: {
                            root.wallhavenQuery = text.trim()
                            root.resetWallhaven()
                        }
                    }

                    Row {
                        spacing: 6

                        ToolBtn {
                            text: "General"
                            width: 70
                            height: 32
                            highlighted: (parseInt(root.wallhavenCategories, 10) & 4) !== 0
                            onClicked: root.toggleCategory(4)
                        }

                        ToolBtn {
                            text: "Anime"
                            width: 70
                            height: 32
                            highlighted: (parseInt(root.wallhavenCategories, 10) & 2) !== 0
                            onClicked: root.toggleCategory(2)
                        }

                        ToolBtn {
                            text: "People"
                            width: 70
                            height: 32
                            highlighted: (parseInt(root.wallhavenCategories, 10) & 1) !== 0
                            onClicked: root.toggleCategory(1)
                        }
                    }

                    ToolBtn {
                        width: 80
                        height: 32
                        text: root.purityLabel()
                        tooltip: "Purity"
                        onClicked: root.cyclePurity()
                    }

                    ToolBtn {
                        id: sortBtn
                        width: 100
                        height: 32
                        text: root.sortingLabel()
                        tooltip: "Sort by"
                        onClicked: root.cycleSorting()
                    }

                    ToolBtn {
                        id: randomSortBtn
                        width: 66
                        height: 32
                        text: "Random"
                        tooltip: "Sort: Random"
                        highlighted: root.wallhavenSorting === "random"
                        visible: true
                        onClicked: {
                            root.wallhavenSorting = "random"
                            root.setWallhavenConfig("sorting", "random")
                            root.resetWallhaven()
                        }
                    }

                    ToolBtn {
                        id: toplistSortBtn
                        width: 72
                        height: 32
                        text: "Toplist"
                        tooltip: "Sort: Toplist"
                        highlighted: root.wallhavenSorting === "toplist"
                        visible: true
                        onClicked: {
                            root.wallhavenSorting = "toplist"
                            root.setWallhavenConfig("sorting", "toplist")
                            root.resetWallhaven()
                        }
                    }

                    ToolBtn {
                        id: ratioBtn
                        width: 60
                        height: 32
                        text: root.ratioLabel()
                        tooltip: "Aspect ratio"
                        onClicked: root.cycleRatios()
                    }

                    ToolBtn {
                        width: 96
                        height: 32
                        text: root.resolutionLabel()
                        tooltip: "Minimum resolution"
                        onClicked: root.cycleResolution()
                    }

                    ToolBtn {
                        width: 60
                        height: 32
                        text: "Reset"
                        tooltip: "Clear search, aspect ratio and resolution"
                        onClicked: root.resetWallhavenFilters()
                    }
                }

                Row {
                    id: tagChipsRow
                    anchors.left: parent.left
                    anchors.leftMargin: 28
                    anchors.top: filtersRow.bottom
                    anchors.topMargin: 8
                    height: 32
                    spacing: 6

                    ToolBtn { text: "landscape"; width: 65; height: 32; highlighted: root.hasWallhavenTag("landscape"); tooltip: "Filter by: landscape"; onClicked: root.toggleWallhavenTag("landscape") }
                    ToolBtn { text: "nature"; width: 65; height: 32; highlighted: root.hasWallhavenTag("nature"); tooltip: "Filter by: nature"; onClicked: root.toggleWallhavenTag("nature") }
                    ToolBtn { text: "anime"; width: 65; height: 32; highlighted: root.hasWallhavenTag("anime"); tooltip: "Filter by: anime"; onClicked: root.toggleWallhavenTag("anime") }
                    ToolBtn { text: "minimal"; width: 65; height: 32; highlighted: root.hasWallhavenTag("minimal"); tooltip: "Filter by: minimal"; onClicked: root.toggleWallhavenTag("minimal") }
                    ToolBtn { text: "dark"; width: 65; height: 32; highlighted: root.hasWallhavenTag("dark"); tooltip: "Filter by: dark"; onClicked: root.toggleWallhavenTag("dark") }
                    ToolBtn { text: "cyberpunk"; width: 65; height: 32; highlighted: root.hasWallhavenTag("cyberpunk"); tooltip: "Filter by: cyberpunk"; onClicked: root.toggleWallhavenTag("cyberpunk") }
                    ToolBtn { text: "4k"; width: 65; height: 32; highlighted: root.hasWallhavenTag("4k"); tooltip: "Filter by: 4k"; onClicked: root.toggleWallhavenTag("4k") }
                    ToolBtn { text: "space"; width: 65; height: 32; highlighted: root.hasWallhavenTag("space"); tooltip: "Filter by: space"; onClicked: root.toggleWallhavenTag("space") }
                }
            }

            Item {
                id: collectionsBar
                visible: root.localTabMode === "collections" && !root.showSettings && !root.showWallhaven
                width: parent.width
                height: 44
                anchors.top: tabs.bottom

                Row {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: 28
                    anchors.rightMargin: 28
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 10

                    Text {
                        text: "NEW COLLECTION"
                        color: root.subtle
                        font.pixelSize: 10
                        font.letterSpacing: 2
                        font.weight: Font.Medium
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    TextField {
                        id: newCollectionField
                        width: 200
                        height: 32
                        placeholderText: "Name"
                        placeholderTextColor: root.subtle
                        color: root.fg
                        font.pixelSize: 12
                        anchors.verticalCenter: parent.verticalCenter
                        background: Rectangle {
                            radius: 6
                            color: root.fieldBg
                            border.width: 1
                            border.color: newCollectionField.activeFocus ? root.accent : root.fieldBorder
                        }
                        onAccepted: {
                            root.createCollection(newCollectionField.text)
                            newCollectionField.text = ""
                        }
                    }

                    ToolBtn {
                        width: 84
                        height: 32
                        text: "Create"
                        iconText: "\uF067"
                        tooltip: "Create a new collection"
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: {
                            root.createCollection(newCollectionField.text)
                            newCollectionField.text = ""
                        }
                    }

                    ToolBtn {
                        width: 96
                        height: 32
                        text: "Refresh"
                        iconText: "\uF2F1"
                        tooltip: "Re-scan collections"
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: root.loadCollections()
                    }

                    Text {
                        visible: root.collectionsLoading
                        text: "loading…"
                        color: root.muted
                        font.pixelSize: 12
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }

            Text {
                id: statusLabel
                visible: root.statusText.length > 0
                text: root.statusText
                color: root.muted
                font.pixelSize: 12
                height: 22
                anchors.top: tabs.bottom
                anchors.topMargin: wallhavenFilters.visible ? wallhavenFilters.height : (collectionsBar.visible ? collectionsBar.height : 0)
                anchors.left: parent.left
                anchors.leftMargin: 28
            }

            Item {
                id: gridTab
                visible: !root.showSettings && (root.showWallhaven || root.localTabMode !== "collections")
                anchors.top: tabs.bottom
                anchors.topMargin: (wallhavenFilters.visible ? wallhavenFilters.height : (collectionsBar.visible ? collectionsBar.height : 0)) + (statusLabel.visible ? statusLabel.height : 0)
                anchors.bottom: footer.top
                anchors.left: parent.left
                anchors.right: parent.right

                GridView {
                    id: grid
                    anchors.fill: parent
                    anchors.margins: 28
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    cacheBuffer: 1000
                    displayMarginBeginning: 500
                    displayMarginEnd: 500
                    cellWidth: Math.floor(width / root.columns)
                    cellHeight: Math.floor((cellWidth - root.gridSpacing) * 9 / 16) + root.gridSpacing
                    model: root.showWallhaven ? wallhavenModel : imageModel

                    onContentYChanged: root.maybeLoadMoreWallhaven()
                    onWidthChanged: Qt.callLater(root.maybeLoadMoreWallhaven)
                    onHeightChanged: Qt.callLater(root.maybeLoadMoreWallhaven)

                    delegate: WallpaperCell {
                        // GridView injects path, fullPath, wallhavenId, label, color, thumb, index
                        cellWidth: grid.cellWidth
                        cellHeight: grid.cellHeight
                    }
                }

                MouseArea {
                    z: 1
                    anchors.fill: grid
                    propagateComposedEvents: true
                    onWheel: function (wheel) {
                        if (wheel.modifiers & Qt.ControlModifier) {
                            wheel.accepted = true
                            var delta = wheel.angleDelta.y > 0 ? -1 : 1
                            var newColumns = Math.max(2, Math.min(12, root.columns + delta))
                            if (newColumns !== root.columns) {
                                root.setConfig("columns", String(newColumns))
                                root.statusText = "Columns: " + newColumns
                                // Re-clamp contentY after layout adjusts originY
                                Qt.callLater(function() {
                                    var minY = grid.originY
                                    var maxY = Math.max(minY, grid.originY + grid.contentHeight - grid.height)
                                    grid.contentY = Math.max(minY, Math.min(maxY, grid.contentY))
                                })
                            }
                        } else {
                            // Clamp to originY-based range (originY shifts during relayout)
                            var step = wheel.angleDelta.y / 120 * 48
                            var newY = grid.contentY - step
                            var minY = grid.originY
                            var maxY = Math.max(minY, grid.originY + grid.contentHeight - grid.height)
                            grid.contentY = Math.max(minY, Math.min(maxY, newY))
                        }
                    }
                }
            }

            Item {
                id: collectionsTab
                visible: !root.showSettings && !root.showWallhaven && root.localTabMode === "collections"
                anchors.top: tabs.bottom
                anchors.topMargin: (collectionsBar.visible ? collectionsBar.height : 0) + (statusLabel.visible ? statusLabel.height : 0)
                anchors.bottom: footer.top
                anchors.left: parent.left
                anchors.right: parent.right

                Flickable {
                    id: collectionsFlick
                    anchors.fill: parent
                    anchors.margins: 28
                    clip: true
                    contentWidth: width
                    contentHeight: collectionsCol.height
                    boundsBehavior: Flickable.StopAtBounds

                    Column {
                        id: collectionsCol
                        width: parent.width
                        spacing: 14

                        Text {
                            visible: root.collectionsLoading && root.collectionsList.length === 0
                            text: "Loading collections…"
                            color: root.muted
                            font.pixelSize: 13
                            anchors.horizontalCenter: parent.horizontalCenter
                        }

                        Text {
                            visible: !root.collectionsLoading && !root.hasUserCollections()
                            text: "Only the built-in Omarchy Themes collection — create your own above, or right-click a wallpaper in All to file it away."
                            color: root.subtle
                            font.pixelSize: 11
                            width: parent.width
                            wrapMode: Text.Wrap
                            horizontalAlignment: Text.AlignHCenter
                        }

                        Repeater {
                            model: root.collectionsList

                            delegate: Rectangle {
                                id: colSection
                                required property var modelData
                                width: parent.width
                                // Grid width is deterministic: section width minus grid margins.
                                readonly property int colGridW: parent.width - 24
                                readonly property int colCellW: Math.floor(colGridW / Math.max(1, root.columns))
                                readonly property int colCellH: Math.floor((colCellW - root.gridSpacing) * 9 / 16) + root.gridSpacing
                                readonly property int colCount: root.collectionCount(modelData.name)
                                readonly property int colRows: Math.ceil(colCount / Math.max(1, root.columns))
                                readonly property int colBodyH: colCount === 0 ? 34 : colRows * colCellH
                                property bool colExpanded: root.isCollectionExpanded(colSection.colName)
                                property string colName: modelData.name
                                property string colId: modelData.id

                                height: colHeader.height + (colExpanded ? colBodyH + 24 : 0)
                                radius: 12
                                color: "#0e0e0b"
                                border.width: 1
                                border.color: "#1c1a14"
                                clip: true

                                Rectangle {
                                    id: colHeader
                                    width: parent.width
                                    height: 48
                                    anchors.top: parent.top
                                    color: "#12120d"

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.toggleCollectionExpanded(colSection.colName)
                                    }

                                    Text {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 16
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: colSection.colExpanded ? "▾" : "▸"
                                        color: root.muted
                                        font.pixelSize: 14
                                    }

                                    Text {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 40
                                        anchors.top: parent.top
                                        anchors.topMargin: 10
                                        text: modelData.name
                                        color: root.fg
                                        font.pixelSize: 14
                                        font.weight: Font.Medium
                                        elide: Text.ElideRight
                                        width: Math.max(0, parent.width - 120)
                                    }

                                    Text {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 40
                                        anchors.top: parent.top
                                        anchors.topMargin: 29
                                        text: colSection.colCount + " wallpaper(s)" + (modelData.id === "omarchy" ? "  •  built-in" : "")
                                        color: root.subtle
                                        font.pixelSize: 10
                                    }

                                    Row {
                                        anchors.right: parent.right
                                        anchors.rightMargin: 12
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 6

                                        ToolBtn {
                                            width: 40
                                            height: 28
                                            iconText: "\uF1F8"
                                            tooltip: "Delete collection"
                                            visible: modelData.id !== "omarchy"
                                            onClicked: root.deleteCollection(modelData.name)
                                        }
                                    }
                                }

                                Item {
                                    id: colGridArea
                                    width: parent.width
                                    height: colSection.colBodyH + 24
                                    anchors.top: colHeader.bottom
                                    visible: colSection.colExpanded

                                    GridView {
                                        id: colGrid
                                        anchors.fill: parent
                                        anchors.margins: 12
                                        clip: true
                                        interactive: false
                                        cellWidth: colSection.colCellW
                                        cellHeight: colSection.colCellH
                                        model: root.gridEntriesFor(colSection.colName)

                                        delegate: WallpaperCell {
                                            cellWidth: colGrid.cellWidth
                                            cellHeight: colGrid.cellHeight
                                            collectionName: colSection.colName
                                        }
                                    }

                                    Text {
                                        visible: colSection.colCount === 0
                                        anchors.centerIn: parent
                                        text: "Empty collection — right-click a wallpaper in All to add one."
                                        color: root.subtle
                                        font.pixelSize: 11
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Item {
                id: settingsTab
                visible: root.showSettings
                anchors.top: tabs.bottom
                anchors.bottom: footer.top
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
                                        root.recursive = recursiveToggle.checked
                                        root.setConfig("recursive", root.recursive ? "true" : "false")
                                        root.reload()
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
                                    width: 130
                                    height: parent.height
                                    text: root.rotationEnabled && root.rotationIntervalMin > 0 ? "Stop" : "Start"
                                    iconText: root.rotationEnabled && root.rotationIntervalMin > 0 ? "\uF04D" : "\uEAD3"
                                    highlighted: root.rotationEnabled && root.rotationIntervalMin > 0
                                    onClicked: root.toggleRotation()
                                }

                                ToolBtn {
                                    width: 130
                                    height: parent.height
                                    text: root.rotationIntervalLabel()
                                    iconText: "\uF01E"
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
                                    iconText: "\uF04E"
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

                Row {
                    visible: !root.showSettings && !root.showWallhaven
                    anchors.right: parent.right
                    anchors.rightMargin: 24
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8

                    ToolBtn {
                        visible: !root.selectionMode && root.localTabMode !== "collections"
                        width: 92
                        height: 40
                        text: "Select"
                        iconText: "\uF0C8"
                        tooltip: "Select multiple wallpapers"
                        onClicked: root.enterSelectionMode()
                    }

                    Text {
                        visible: root.selectionMode
                        text: root.selectedPaths.length + " selected"
                        color: root.muted
                        font.pixelSize: 12
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    ToolBtn {
                        visible: root.selectionMode
                        width: 84
                        height: 40
                        text: "Delete"
                        iconText: "\uF1F8"
                        tooltip: "Move selected wallpapers to Trash"
                        enabled: root.selectedPaths.length > 0
                        opacity: enabled ? 1 : 0.4
                        onClicked: root.requestRemove(root.selectedPaths)
                    }

                    ToolBtn {
                        visible: root.selectionMode
                        width: 132
                        height: 40
                        text: "Add to Collection"
                        iconText: "\uF550"
                        tooltip: "Add selected wallpapers to a collection"
                        enabled: root.selectedPaths.length > 0
                        opacity: enabled ? 1 : 0.4
                        onClicked: root.openAddCollectionPopupForPaths(root.selectedPaths)
                    }

                    ToolBtn {
                        visible: root.selectionMode
                        width: 84
                        height: 40
                        text: "Cancel"
                        tooltip: "Exit selection mode"
                        onClicked: root.cancelSelection()
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

            Rectangle {
                anchors.fill: parent
                visible: root.deleteConfirmVisible
                color: "#99000000"
                z: 70

                MouseArea {
                    anchors.fill: parent
                    onWheel: function (wheel) {
                        wheel.accepted = true
                    }
                    onClicked: root.cancelRemove()
                }

                Rectangle {
                    width: 460
                    height: deleteColumn.implicitHeight + 56
                    radius: 12
                    color: root.fieldBg
                    border.width: 1
                    border.color: root.fieldBorder
                    anchors.centerIn: parent

                    MouseArea {
                        anchors.fill: parent
                        onWheel: function (wheel) {
                            wheel.accepted = true
                        }
                    }

                    Column {
                        id: deleteColumn
                        anchors.fill: parent
                        anchors.margins: 28
                        spacing: 18

                        Text {
                            text: root.pendingDeletePaths.length === 1
                                ? "Move to Trash?"
                                : "Move " + root.pendingDeletePaths.length + " wallpapers to Trash?"
                            color: root.fg
                            font.pixelSize: 15
                            font.weight: Font.Medium
                        }

                        Text {
                            text: root.pendingDeletePaths.length === 1
                                ? "This wallpaper will be moved to the system Trash."
                                : "These wallpapers will be moved to the system Trash."
                            color: root.muted
                            font.pixelSize: 13
                            wrapMode: Text.Wrap
                            width: parent.width
                        }

                        Text {
                            visible: root.currentBackground !== "" && root.pendingDeletePaths.indexOf(root.currentBackground) !== -1
                            text: "The wallpaper currently applied is included — your background may not survive a restart."
                            color: root.accent
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                            width: parent.width
                        }

                        Row {
                            anchors.right: parent.right
                            spacing: 10

                            ToolBtn {
                                text: "Cancel"
                                onClicked: root.cancelRemove()
                            }

                            ToolBtn {
                                text: "Move to Trash"
                                highlighted: true
                                onClicked: root.confirmRemove()
                            }
                        }
                    }
                }
            }

             Rectangle {
                anchors.fill: parent
                visible: root.addCollectionPopupVisible
                color: "#99000000"
                z: 70

                MouseArea {
                    anchors.fill: parent
                    onWheel: function (wheel) { wheel.accepted = true }
                    onClicked: root.closeAddCollectionPopup()
                }

                Rectangle {
                    width: 420
                    height: addCard.implicitHeight + 56
                    radius: 12
                    color: root.fieldBg
                    border.width: 1
                    border.color: root.fieldBorder
                    anchors.centerIn: parent

                    MouseArea {
                        anchors.fill: parent
                        onWheel: function (wheel) { wheel.accepted = true }
                    }

                    Column {
                        id: addCard
                        anchors.fill: parent
                        anchors.margins: 24
                        spacing: 14

                        Text {
                            text: "Add to Collection"
                            color: root.fg
                            font.pixelSize: 15
                            font.weight: Font.Medium
                        }

                        Text {
                            text: root.popupPathCount() + " wallpaper" + (root.popupPathCount() === 1 ? "" : "s")
                            color: root.muted
                            font.pixelSize: 12
                        }

                        // Existing collections to add to.
                        Text {
                            text: "EXISTING"
                            color: root.subtle
                            font.pixelSize: 10
                            font.letterSpacing: 2
                            font.weight: Font.Medium
                        }

                        Flickable {
                            width: parent.width
                            height: Math.min(240, addList.height)
                            contentHeight: addList.height
                            boundsBehavior: Flickable.StopAtBounds
                            clip: true

                            Column {
                                id: addList
                                width: parent.width
                                spacing: 6

                                Repeater {
                                    id: addListRepeater
                                    model: (root.collectionsList || []).filter(function (c) { return c.id !== "omarchy" })

                                    delegate: Rectangle {
                                        required property var modelData
                                        width: parent.width
                                        height: 36
                                        radius: 6
                                        color: addArea.containsMouse ? "#232018" : "#100f0c"
                                        border.width: 1
                                        border.color: addArea.containsMouse ? root.muted : root.fieldBorder

                                        Text {
                                            anchors.left: parent.left
                                            anchors.leftMargin: 12
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: modelData.name
                                            color: root.fg
                                            font.pixelSize: 12
                                            elide: Text.ElideRight
                                            width: parent.width - 80
                                        }

                                        Text {
                                            anchors.right: parent.right
                                            anchors.rightMargin: 12
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: (modelData.paths ? modelData.paths.length : 0) + ""
                                            color: root.subtle
                                            font.pixelSize: 11
                                        }

                                        MouseArea {
                                            id: addArea
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.addPopupPathsToCollection(modelData.name)
                                        }
                                    }
                                }

                                Text {
                                    width: parent.width
                                    text: addListRepeater.count === 0 ? "No user collections yet — create one below." : ""
                                    color: root.subtle
                                    font.pixelSize: 11
                                }
                            }
                        }

                        // New collection.
                        Text {
                            text: "NEW COLLECTION"
                            color: root.subtle
                            font.pixelSize: 10
                            font.letterSpacing: 2
                            font.weight: Font.Medium
                        }

                        Row {
                            width: parent.width
                            spacing: 8

                            TextField {
                                id: newColInPopup
                                width: parent.width - 120
                                height: 34
                                placeholderText: "Name"
                                placeholderTextColor: root.subtle
                                color: root.fg
                                font.pixelSize: 12
                                background: Rectangle {
                                    radius: 6
                                    color: root.fieldBg
                                    border.width: 1
                                    border.color: newColInPopup.activeFocus ? root.accent : root.fieldBorder
                                }
                                onAccepted: {
                                    root.createCollectionAndAdd(newColInPopup.text,
                                        (root.addCollectionPopupPaths.length > 0 ? root.addCollectionPopupPaths : [root.addCollectionTarget]))
                                    newColInPopup.text = ""
                                }
                            }

                            ToolBtn {
                                width: 110
                                height: 34
                                text: "Create"
                                iconText: "\uF067"
                                onClicked: {
                                    root.createCollectionAndAdd(newColInPopup.text,
                                        (root.addCollectionPopupPaths.length > 0 ? root.addCollectionPopupPaths : [root.addCollectionTarget]))
                                    newColInPopup.text = ""
                                }
                            }
                        }

                        Row {
                            anchors.right: parent.right
                            spacing: 10

                            ToolBtn {
                                text: "Cancel"
                                onClicked: root.closeAddCollectionPopup()
                            }
                        }
                    }
                }
            }

            Rectangle {
                anchors.fill: parent
                visible: root.deleteCollectionConfirmVisible
                color: "#99000000"
                z: 70

                MouseArea {
                    anchors.fill: parent
                    onWheel: function (wheel) { wheel.accepted = true }
                    onClicked: root.cancelDeleteCollection()
                }

                Rectangle {
                    width: 420
                    height: 168
                    radius: 12
                    color: root.fieldBg
                    border.width: 1
                    border.color: root.fieldBorder
                    anchors.centerIn: parent

                    MouseArea {
                        anchors.fill: parent
                        onWheel: function (wheel) { wheel.accepted = true }
                    }

                    Column {
                        anchors.fill: parent
                        anchors.margins: 28
                        spacing: 18

                        Text {
                            text: "Delete Collection?"
                            color: root.fg
                            font.pixelSize: 15
                            font.weight: Font.Medium
                        }

                        Text {
                            text: "This removes the \"" + root.deleteCollectionName + "\" collection. The wallpapers themselves are NOT deleted — they stay in your folder."
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
                                onClicked: root.cancelDeleteCollection()
                            }

                            ToolBtn {
                                text: "Delete Collection"
                                highlighted: true
                                onClicked: root.confirmDeleteCollection()
                            }
                        }
                    }
                }
            }

            // Right-click context menu for a wallpaper cell.
            Item {
                id: cellContextMenu
                anchors.fill: parent
                visible: root.contextMenuVisible
                z: 55

                // Click-away shield: swallows clicks behind the menu.
                MouseArea {
                    anchors.fill: parent
                    onWheel: function (wheel) { wheel.accepted = true }
                    onClicked: root.closeCellContextMenu()
                }

                Rectangle {
                    id: menuCard
                    width: Math.min(220, parent.width - 24)
                    height: menuCol.implicitHeight + 12
                    x: Math.max(12, Math.min(root.contextMenuX, parent.width - width - 12))
                    y: Math.max(12, Math.min(root.contextMenuY, parent.height - height - 12))
                    radius: 8
                    color: "#15150f"
                    border.width: 1
                    border.color: root.fieldBorder

                    Column {
                        id: menuCol
                        anchors.fill: parent
                        anchors.margins: 6
                        spacing: 2

                        Repeater {
                            model: [
                                { label: "Preview", icon: "\uF06E" },
                                { label: "Apply wallpaper", icon: "\uF04B" },
                                { label: root.contextMenuCollection !== "" ? "Remove from \"" + root.contextMenuCollection + "\"" : "Add to collection…", icon: "\uF550" },
                                { label: "Move to Trash", icon: "\uF1F8", danger: true }
                            ]

                            delegate: Rectangle {
                                required property var modelData
                                required property int index
                                width: menuCol.width
                                height: 32
                                radius: 6
                                color: optArea.containsMouse ? "#232018" : "transparent"

                                Text {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 8
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 16
                                    text: modelData.icon
                                    color: modelData.danger ? "#c96a5a" : root.muted
                                    font.family: "JetBrainsMono Nerd Font"
                                    font.pixelSize: 11
                                }

                                Text {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 30
                                    anchors.right: parent.right
                                    anchors.rightMargin: 8
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.label
                                    color: modelData.danger ? "#e08a7a" : root.fg
                                    font.pixelSize: 12
                                    elide: Text.ElideRight
                                }

                                MouseArea {
                                    id: optArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.activateContextMenuOption(index)
                                }
                            }
                        }
                    }
                }
            }

            Rectangle {
                anchors.fill: parent
                visible: root.previewVisible
                color: "#cc000000"
                z: 60

                MouseArea {
                    anchors.fill: parent
                    onWheel: function (wheel) {
                        wheel.accepted = true
                    }
                    onClicked: root.previewVisible = false
                }

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 32
                    radius: 12
                    color: root.bg
                    border.width: 1
                    border.color: root.fieldBorder

                    MouseArea {
                        anchors.fill: parent
                        onWheel: function (wheel) {
                            wheel.accepted = true
                        }
                    }

                    ToolBtn {
                        width: 34
                        height: 34
                        text: "\u2715"
                        tooltip: "Close preview"
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.topMargin: 12
                        anchors.rightMargin: 12
                        onClicked: root.previewVisible = false
                    }

                    Image {
                        id: previewImage
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.bottom: previewFooter.top
                        anchors.margins: 20
                        source: root.previewImageSource ? root.imagePath(root.previewImageSource) : ""
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        smooth: true

                        Rectangle {
                            visible: previewImage.status !== Image.Ready
                            anchors.fill: parent
                            color: root.fieldBg
                            radius: 8

                            Text {
                                anchors.centerIn: parent
                                text: previewImage.status === Image.Error ? "Could not load preview" : "Loading preview…"
                                color: root.subtle
                                font.pixelSize: 13
                            }
                        }
                    }

                    Item {
                        id: previewFooter
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 64

                        Rectangle {
                            anchors.fill: parent
                            radius: 12
                            color: root.fieldBg

                            Row {
                                id: previewFooterButtons
                                anchors.right: parent.right
                                anchors.rightMargin: 20
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 10

                                ToolBtn {
                                    width: 92
                                    height: 34
                                    text: "Delete"
                                    iconText: "\uF1F8"
                                    tooltip: "Move to Trash"
                                    visible: root.previewWallhavenId === ""
                                    onClicked: root.requestRemove([root.previewImageSource])
                                }

                                ToolBtn {
                                    width: 84
                                    height: 34
                                    text: "Apply"
                                    tooltip: root.previewWallhavenId ? "Download and set as wallpaper" : "Set as wallpaper"
                                    onClicked: {
                                        root.previewCloseAfterDownload = false
                                        if (root.previewWallhavenId)
                                            root.applyWallhaven(root.previewWallhavenId)
                                        else
                                            root.setWallpaper(root.previewImageSource)
                                        root.previewVisible = false
                                    }
                                }

                                ToolBtn {
                                    width: 96
                                    height: 34
                                    text: "Download"
                                    tooltip: "Download to pictures directory (no apply) — closes preview"
                                    visible: root.previewWallhavenId !== ""
                                    onClicked: root.downloadWallhaven(root.previewWallhavenId, true)
                                }
                            }

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 24
                                anchors.right: previewFooterButtons.left
                                anchors.rightMargin: 16
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideMiddle
                                text: root.previewLabel || "Wallpaper preview"
                                color: root.muted
                                font.pixelSize: 12
                            }
                        }
                    }
                }
            }
        }
    }

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
            onClicked: btn.clicked()
        }

        ToolTip.visible: btnArea.containsMouse && !btnArea.pressed && btn.tooltip.length > 0
        ToolTip.text: btn.tooltip
        ToolTip.delay: 600
    }

    // Reusable wallpaper thumbnail cell — used by the main grid and per-collection grids.
    // `cellWidth`/`cellHeight` are the GridView cell metrics (spacing included).
    component WallpaperCell: Item {
        id: wpCell
        required property string path
        required property string fullPath
        required property string wallhavenId
        required property string label
        required property string color
        property string thumb: ""
        property string collectionName: ""
        required property int index
        property int cellWidth: 200
        property int cellHeight: 130

        readonly property bool cellSelected: root.isSelected(wpCell.path)
        readonly property bool cellHighlighted: root.hoveredPath === wpCell.path || cellSelected

        width: parent ? (wpCell.cellWidth - root.gridSpacing) : wpCell.cellWidth
        height: parent ? (wpCell.cellHeight - root.gridSpacing) : wpCell.cellHeight

        // Where to show the thumbnail: cached thumb if it exists, else full image.
        function displaySource() {
            if (wpCell.thumb && wpCell.thumb.indexOf("file://") !== 0 && wpCell.thumb.indexOf("/") === 0)
                return "file://" + wpCell.thumb
            return root.imagePath(wpCell.path)
        }

        Rectangle {
            anchors.fill: parent
            radius: wpCell.cellHighlighted ? 0 : 10
            color: root.fieldBg
            border.width: wpCell.cellHighlighted ? 2 : 0
            border.color: root.accent
            clip: true

            Image {
                id: thumbImage
                anchors.fill: parent
                anchors.margins: wpCell.cellHighlighted ? 2 : 0
                source: wpCell.displaySource()
                sourceSize.width: width
                sourceSize.height: height
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: true
                smooth: true

                Rectangle {
                    visible: thumbImage.status !== Image.Ready
                    anchors.fill: parent
                    color: "#1b1b16"

                    Text {
                        anchors.centerIn: parent
                        text: thumbImage.status === Image.Error ? "×" : "…"
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
                visible: wpCell.cellHighlighted
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "#00000000" }
                    GradientStop { position: 1.0; color: "#c0000000" }
                }

                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: 6
                    anchors.rightMargin: wpCell.wallhavenId === "" && root.hoveredPath === wpCell.path && !root.selectionMode ? 40 : 6
                    elide: Text.ElideMiddle
                    text: wpCell.label || root.baseName(wpCell.path)
                    color: root.fg
                    font.pixelSize: 11
                }
            }
        }

        Rectangle {
            visible: wpCell.cellSelected
            width: 24
            height: 24
            radius: 12
            color: root.accent
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.margins: 8

            Text {
                anchors.centerIn: parent
                text: "\uF00C"
                color: root.bg
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: 12
            }
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onEntered: root.hoveredPath = wpCell.path
            onExited: {
                if (root.hoveredPath === wpCell.path)
                    root.hoveredPath = ""
            }
            onClicked: function (mouse) {
                // Right-click is handled in onPressed — never treat it as a preview click.
                if (mouse.button !== Qt.LeftButton)
                    return
                // Collection sections are read-only grids: a click always previews.
                if (root.selectionMode && wpCell.collectionName === "")
                    root.toggleSelected(wpCell.path, wpCell.index, mouse.modifiers)
                else
                    root.openPreview(wpCell)
            }
            onPressed: function (mouse) {
                // Right-click on a wallpaper opens its context menu.
                if (mouse.button === Qt.RightButton && wpCell.wallhavenId === "") {
                    root.openCellContextMenu(wpCell, mouse.x, mouse.y)
                    mouse.accepted = true
                }
            }

            Row {
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 10
                spacing: 6
                visible: root.hoveredPath === wpCell.path && !root.selectionMode

                ToolBtn {
                    width: 52
                    height: 24
                    text: "Apply"
                    tooltip: wpCell.wallhavenId ? "Apply this wallpaper" : "Set as wallpaper"
                    onClicked: {
                        if (wpCell.wallhavenId)
                            root.applyWallhaven(wpCell.wallhavenId)
                        else
                            root.setWallpaper(wpCell.path)
                    }
                }

                ToolBtn {
                    width: 78
                    height: 24
                    text: "Download"
                    tooltip: "Download to pictures directory (no apply)"
                    visible: wpCell.wallhavenId !== ""
                    onClicked: root.downloadWallhaven(wpCell.wallhavenId, false)
                }
            }

            ToolBtn {
                width: 26
                height: 26
                iconText: "\uF1F8"
                tooltip: "Move to Trash"
                visible: wpCell.wallhavenId === "" && root.hoveredPath === wpCell.path && !root.selectionMode
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 8
                onClicked: root.requestRemove([wpCell.path])
            }

        }
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
                kfieldInput.text = kfield.value || ""
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
