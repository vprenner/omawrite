import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Dialogs as Dialogs
import QtQuick.Layouts
import QtQuick.Window
import "EditorMutations.js" as EditorMutations

ApplicationWindow {
    id: win
    readonly property var workspace: typeof session !== "undefined" ? session : null
    readonly property var documentBackend: workspace ? workspace.activeDocument : backend
    property bool switchingTabs: false
    readonly property bool tabActionsEnabled: !unsavedChangesDialog.visible
        && !saveFileDialog.visible && !openFileDialog.visible && !externalChangeDialog.visible
    width: 1280
    height: 820
    minimumWidth: 720
    minimumHeight: 520
    visible: true
    title: (win.documentBackend.modified ? "* " : "") + win.documentBackend.fileName + " - OmawriteV"

    readonly property bool darkMode: win.documentBackend.darkMode
    readonly property color pageColor: win.documentBackend.themeBackground
    readonly property color textColor: win.documentBackend.themeForeground
    readonly property color mutedColor: darkMode ? "#909191" : "#aeb1b5"
    readonly property color selectionFill: win.documentBackend.themeSelection
    readonly property color selectionTextColor: win.documentBackend.themeSelectionForeground
    // The desktop's text size knob (GNOME's text-scaling-factor, which
    // `omarchy display text size` drives) anchored so its 12px default leaves
    // the app at the sizes it was designed around, times the user's own
    // text size set with Ctrl+= / Ctrl+- / Ctrl+wheel.
    readonly property real textScale: win.documentBackend.textScale
    readonly property int editorFontPixelSize: scaledSize(20)
    readonly property int footerHeight: scaledSize(32)
    // Never wider than the Flickable's viewport, whatever the floor asks for:
    // a tiling compositor can resize the window below its minimum width.
    readonly property int editorWidth: documentBackend.widthMode === "full"
        ? Math.max(0, width - 48)
        : Math.min(Math.round(writerFontMetrics.averageCharacterWidth
                             * ({narrow: 50, medium: 65, wide: 90}[documentBackend.widthMode] || 65)),
                   Math.max(360, width - Math.round(writerFontMetrics.averageCharacterWidth * 20)),
                   Math.max(0, width - 48))
    property bool closeConfirmed: false
    property bool searchOpen: false
    property bool searchUpdating: false
    property var searchMatches: []
    property int searchMatchIndex: -1
    property url pendingOpenUrl
    property string pendingAction: ""
    property bool replaceOpen: false
    property bool awaitingPendingSave: false

    Material.theme: darkMode ? Material.Dark : Material.Light
    Material.accent: win.documentBackend.themeAccent
    color: pageColor

    onClosing: function(close) {
        if (workspace) {
            workspace.saveViewState(editor.cursorPosition, editorFlick.contentY);
            close.accepted = workspace.saveSession();
            return;
        }
        if (closeConfirmed || !win.documentBackend.modified)
            return;

        close.accepted = false;
        pendingAction = "close";
        if (!unsavedChangesDialog.opened)
            unsavedChangesDialog.open();
    }

    function requestOpen(url) {
        if (workspace) {
            workspace.openFile(url);
            return;
        }
        if (!win.documentBackend.modified) {
            win.documentBackend.open(url);
            return;
        }
        pendingOpenUrl = url;
        pendingAction = "open";
        unsavedChangesDialog.open();
    }

    function completePendingAction() {
        var action = pendingAction;
        pendingAction = "";
        if (action === "close") {
            closeConfirmed = true;
            close();
        } else if (action === "closeTab") {
            workspace.closeTab(workspace.currentIndex);
        } else if (action === "open") {
            win.documentBackend.open(pendingOpenUrl);
        }
    }

    function requestCloseTab(index) {
        workspace.selectTab(index);
        if (!documentBackend.modified) {
            workspace.closeTab(index);
            return;
        }
        pendingAction = "closeTab";
        unsavedChangesDialog.open();
    }

    Connections {
        target: win.workspace
        function onActiveDocumentAboutToChange() {
            win.switchingTabs = true;
            win.workspace.saveViewState(editor.cursorPosition, editorFlick.contentY);
            win.closeSearch();
            externalChangeDialog.close();
            fontPicker.close();
        }
        function onActiveDocumentChanged() {
            win.documentBackend.activateDocument(editor.textDocument);
            var state = win.workspace.viewState();
            editor.cursorPosition = Math.min(editor.length, state.cursor || 0);
            editorFlick.contentY = Math.max(0, Math.min(state.scroll || 0,
                editorFlick.contentHeight - editorFlick.height));
            win.switchingTabs = false;
            editor.forceActiveFocus();
        }
    }

    FontMetrics {
        id: writerFontMetrics
        font.family: win.documentBackend.editorFont
        font.pixelSize: win.editorFontPixelSize
    }

    // Every hardcoded size in the interface is expressed at text scale 1.
    function scaledSize(pixels) {
        return Math.max(1, Math.round(pixels * win.textScale));
    }

    function toggleFullScreen() {
        win.visibility = win.visibility === Window.FullScreen
            ? Window.Windowed
            : Window.FullScreen;
    }

    // Only the search field and the next and previous controls select a
    // match. When the document changes underneath, the matches follow along
    // without taking the writer's caret.
    function updateSearch(selectMatch) {
        searchDelay.stop();
        var previous = searchMatchIndex >= 0 ? searchMatches[searchMatchIndex] : 0;
        searchMatches = win.documentBackend.searchMatches(searchField.text);
        searchMatchIndex = selectMatch ? (searchMatches.length > 0 ? 0 : -1)
                                       : matchAtOrAfter(previous);
        showSearchMatch(selectMatch);
    }

    function matchAtOrAfter(position) {
        for (var i = 0; i < searchMatches.length; ++i) {
            if (searchMatches[i] >= position)
                return i;
        }
        return searchMatches.length > 0 ? 0 : -1;
    }

    function showSearchMatch(selectMatch) {
        var start = searchMatchIndex >= 0 ? searchMatches[searchMatchIndex] : -1;
        searchUpdating = true;
        win.documentBackend.setSearchHighlight(searchField.text, start);
        if (selectMatch && start >= 0) {
            editor.select(start, start + searchField.text.length);
            editorFlick.ensureCursorVisible();
        }
        searchUpdating = false;
    }

    // Typing in the search field waits for a pause before searching, so
    // anything that acts on the matches catches up with the field first.
    function flushSearch() {
        if (searchDelay.running)
            updateSearch(true);
    }

    function moveSearch(direction) {
        // A pending search lands on its first match, which is where the
        // writer meant to go, rather than one past it.
        if (searchDelay.running) {
            updateSearch(true);
            return;
        }
        if (searchMatches.length === 0)
            return;
        searchMatchIndex = (searchMatchIndex + direction + searchMatches.length)
                           % searchMatches.length;
        showSearchMatch(true);
    }

    // The matches stop following the field and the text while the bar is
    // closed, and a search still waiting for a pause is dropped on closing,
    // so opening the bar searches again for what the field holds.
    function openSearch(withReplace) {
        searchOpen = true;
        if (withReplace)
            replaceOpen = true;
        searchField.forceActiveFocus();
        searchField.selectAll();
        // A search still waiting in an open bar lands on its first match.
        updateSearch(searchDelay.running);
    }

    function closeSearch() {
        searchDelay.stop();
        // Hand focus to the editor before hiding the bar. Hiding the field
        // that holds focus leaves the input method with nothing focused for
        // a moment, and fcitx5 can then miss the next Ctrl+F.
        Qt.inputMethod.reset();
        editor.forceActiveFocus();
        searchOpen = false;
        searchUpdating = true;
        win.documentBackend.setSearchHighlight("", -1);
        editor.deselect();
        searchUpdating = false;
        replaceOpen = false;
    }

    // Restyling a large document for each letter typed makes typing a word
    // stall, so the search waits until the typing pauses.
    Timer {
        id: searchDelay
        interval: 150
        onTriggered: win.updateSearch(true)
    }

    Shortcut {
        sequence: "Ctrl+S"
        onActivated: win.documentBackend.save()
    }

    Shortcut {
        sequence: "Ctrl+H"
        onActivated: win.openSearch(true)
    }

    Shortcut {
        sequence: "Ctrl+B"
        context: Qt.WindowShortcut
        onActivated: editor.wrapSelection("**")
    }

    Shortcut {
        sequence: "Ctrl+I"
        context: Qt.WindowShortcut
        onActivated: editor.wrapSelection("*")
    }

    Shortcut {
        sequence: "Ctrl+Shift+X"
        context: Qt.WindowShortcut
        onActivated: editor.wrapSelection("~~")
    }

    Shortcut {
        sequence: "Ctrl+K"
        context: Qt.WindowShortcut
        onActivated: editor.insertLink()
    }

    Shortcut {
        sequences: ["Ctrl+?", "Ctrl+/", "F1"]
        onActivated: shortcutsDialog.open()
    }

    Shortcut {
        // Ctrl++ is a different shortcut to Qt, not a shifted Ctrl+=, and it is
        // the only one a layout that puts + on its own key can reach.
        sequences: ["Ctrl+=", "Ctrl++"]
        onActivated: win.documentBackend.increaseTextSize()
    }

    Shortcut {
        sequence: "Ctrl+-"
        onActivated: win.documentBackend.decreaseTextSize()
    }

    Shortcut {
        sequence: "Ctrl+0"
        onActivated: win.documentBackend.resetTextSize()
    }

    Shortcut {
        sequence: "Ctrl+O"
        onActivated: win.documentBackend.openDialog()
    }

    Shortcut {
        sequence: "Ctrl+T"
        enabled: win.workspace !== null && win.tabActionsEnabled
        onActivated: win.workspace.newTab()
    }

    Shortcut {
        sequence: "Ctrl+W"
        enabled: win.workspace !== null && win.tabActionsEnabled
        onActivated: win.requestCloseTab(win.workspace.currentIndex)
    }

    Shortcut {
        sequences: ["Ctrl+Tab", "Ctrl+PageDown"]
        enabled: win.workspace !== null && win.tabActionsEnabled
        onActivated: win.workspace.selectTab((win.workspace.currentIndex + 1) % win.workspace.tabs.length)
    }

    Shortcut {
        sequences: ["Ctrl+Shift+Tab", "Ctrl+PageUp"]
        enabled: win.workspace !== null && win.tabActionsEnabled
        onActivated: win.workspace.selectTab((win.workspace.currentIndex + win.workspace.tabs.length - 1) % win.workspace.tabs.length)
    }

    Shortcut {
        sequence: "Ctrl+N"
        onActivated: win.documentBackend.newWindow()
    }

    Shortcut {
        sequence: "Ctrl+Shift+S"
        onActivated: win.documentBackend.saveAsDialog()
    }

    Shortcut {
        sequence: "Ctrl+P"
        onActivated: win.documentBackend.printDocument()
    }

    Shortcut {
        sequence: "Ctrl+Shift+C"
        onActivated: win.documentBackend.copyAsHtml()
    }

    Shortcut {
        sequences: ["Meta+F", "F11"]
        onActivated: toggleFullScreen()
    }

    Shortcut {
        sequence: "Ctrl+Z"
        context: Qt.WindowShortcut
        onActivated: editor.undo()
    }

    Shortcut {
        sequences: ["Ctrl+Shift+Z", "Ctrl+Y"]
        context: Qt.WindowShortcut
        onActivated: editor.redo()
    }

    Shortcut {
        sequence: "Ctrl+F"
        onActivated: win.openSearch(false)
    }

    Shortcut {
        sequence: "Ctrl+G"
        enabled: win.searchOpen
        onActivated: win.moveSearch(1)
    }

    Connections {
        target: win.documentBackend

        function onOpenDialogRequested() {
            openFileDialog.open();
        }

        function onSaveDialogRequested(suggestedUrl) {
            saveFileDialog.selectedFile = suggestedUrl;
            saveFileDialog.open();
        }

        function onSaveSucceeded() {
            // Only a save the writer chose in the prompt carries out the
            // pending close or open, never an auto-save that lands meanwhile.
            const confirmed = win.awaitingPendingSave;
            win.awaitingPendingSave = false;
            if (confirmed && win.pendingAction !== "")
                win.completePendingAction();
        }

        function onSaveFailed() {
            // A failed save leaves the document as it was, so the close or
            // open it was for is off; a later save must not carry it out.
            win.awaitingPendingSave = false;
            win.pendingAction = "";
        }

        function onExternalChangeDetected(deleted, locallyModified) {
            externalChangeDialog.deleted = deleted;
            externalChangeDialog.locallyModified = locallyModified;
            externalChangeDialog.open();
        }
    }

    Dialogs.FileDialog {
        id: openFileDialog
        title: "Open File"
        fileMode: win.workspace ? Dialogs.FileDialog.OpenFiles : Dialogs.FileDialog.OpenFile
        nameFilters: ["Markdown files (*.md *.markdown)", "All files (*)"]
        onAccepted: {
            if (win.workspace) {
                for (var i = 0; i < selectedFiles.length; ++i)
                    win.workspace.openFile(selectedFiles[i]);
            } else {
                win.requestOpen(selectedFile);
            }
        }
    }

    Dialogs.FileDialog {
        id: saveFileDialog
        title: "Save File"
        fileMode: Dialogs.FileDialog.SaveFile
        nameFilters: ["Markdown files (*.md *.markdown)", "All files (*)"]
        onAccepted: win.documentBackend.saveAs(selectedFile)
        onRejected: {
            win.awaitingPendingSave = false;
            win.pendingAction = "";
        }
    }

    UnsavedChangesDialog {
        id: unsavedChangesDialog
        objectName: "unsavedChangesDialog"
        fileName: win.documentBackend.fileName
        darkMode: win.darkMode
        textScale: win.textScale
        textColor: win.textColor
        strongTextColor: win.textColor
        activeButtonColor: win.documentBackend.themeAccent
        containerWidth: win.width
        containerHeight: win.height

        // Discard must still mean discard, so nothing is auto-saved while
        // the writer decides.
        onAboutToShow: win.documentBackend.holdAutoSave(true)
        onClosed: win.documentBackend.holdAutoSave(false)

        onDiscardRequested: {
            win.documentBackend.discardRecovery();
            win.completePendingAction();
        }

        onSaveRequested: {
            win.awaitingPendingSave = true;
            win.documentBackend.save();
        }
        onCancelRequested: win.pendingAction = ""
    }

    ExternalChangeDialog {
        id: externalChangeDialog
        darkMode: win.darkMode
        textScale: win.textScale
        textColor: win.textColor
        strongTextColor: win.textColor
        activeButtonColor: win.documentBackend.themeAccent
        containerWidth: win.width
        containerHeight: win.height

        onKeepRequested: win.documentBackend.keepExternalVersion()
        onReloadRequested: win.documentBackend.reloadFromDisk()
    }

    ShortcutsDialog {
        id: shortcutsDialog
        darkMode: win.darkMode
        textScale: win.textScale
        textColor: win.textColor
        activeButtonColor: win.documentBackend.themeAccent
        containerWidth: win.width
        containerHeight: win.height
    }

    header: ToolBar {
        objectName: "tabStrip"
        enabled: win.tabActionsEnabled
        visible: win.workspace !== null
        height: visible ? win.scaledSize(40) : 0
        background: Rectangle { color: win.pageColor }
        RowLayout {
            anchors.fill: parent
            spacing: 0
            ScrollView {
                id: tabScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: tabRow.width
                contentHeight: height
                ScrollBar.vertical.policy: ScrollBar.AlwaysOff
                ScrollBar.horizontal.policy: ScrollBar.AsNeeded
                function revealCurrent() {
                    var tab = tabRepeater.itemAt(win.workspace.currentIndex);
                    if (!tab) return;
                    if (tab.x < contentItem.contentX) contentItem.contentX = tab.x;
                    else if (tab.x + tab.width > contentItem.contentX + availableWidth)
                        contentItem.contentX = tab.x + tab.width - availableWidth;
                }
                Connections {
                    target: win.workspace
                    function onActiveDocumentChanged() { Qt.callLater(tabScroll.revealCurrent); }
                }
                Row {
                    id: tabRow
                    Repeater {
                        id: tabRepeater
                        model: win.workspace ? win.workspace.tabs : []
                        delegate: Rectangle {
                            required property int index
                            required property var modelData
                            width: win.scaledSize(190)
                            height: win.scaledSize(40)
                            color: index === win.workspace.currentIndex
                                ? Qt.rgba(win.textColor.r, win.textColor.g, win.textColor.b, 0.09)
                                : "transparent"
                            Button {
                                anchors.fill: parent
                                anchors.rightMargin: win.scaledSize(32)
                                flat: true
                                text: (modelData.modified ? "• " : "")
                                    + (modelData.externalChange ? "! " : "") + modelData.name
                                contentItem: Label {
                                    text: parent.text
                                    textFormat: Text.PlainText
                                    color: win.textColor
                                    elide: Text.ElideMiddle
                                    verticalAlignment: Text.AlignVCenter
                                    font.pixelSize: win.scaledSize(12)
                                }
                                ToolTip.visible: hovered
                                ToolTip.text: modelData.path || "Unsaved draft"
                                onClicked: win.workspace.selectTab(index)
                            }
                            ToolButton {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                width: win.scaledSize(32)
                                text: "×"
                                font.pixelSize: win.scaledSize(18)
                                Accessible.name: "Close " + modelData.name
                                onClicked: win.requestCloseTab(index)
                            }
                        }
                    }
                }
            }
            ToolButton {
                objectName: "newTabButton"
                text: "+"
                Accessible.name: "New tab"
                ToolTip.visible: hovered
                ToolTip.text: "New tab (Ctrl+T)"
                onClicked: win.workspace.newTab()
            }
        }
    }

    Item {
        anchors.fill: parent

        Flickable {
            id: editorFlick
            objectName: "editorScroll"
            anchors.fill: parent
            anchors.leftMargin: 24
            anchors.rightMargin: 24
            // Inset the scrolling area by the footer strip at both ends, so
            // scrolled text never runs under the footer buttons, status, or
            // word count, and stops just as far short of the top edge.
            anchors.topMargin: win.footerHeight
            anchors.bottomMargin: win.footerHeight
            clip: true
            contentWidth: width
            contentHeight: Math.max(height, editor.y + editor.implicitHeight + 220)
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {
                policy: ScrollBar.AsNeeded
                // Wheel scrolling moves contentY directly rather than
                // flicking the Flickable, so the bar has to be told about
                // that activity; linger briefly after the last event.
                active: hovered || pressed || wheelScroll.running || scrollLinger.running
            }

            // Also lingers after paging through the document from the
            // keyboard, so the bar shows where the jump landed. Writing past
            // the bottom edge scrolls too, but leaves the bar hidden.
            Timer {
                id: scrollLinger
                objectName: "scrollLinger"
                interval: 600
            }

            // Flickable turns a wheel notch into a flick sized by the small
            // application font, which crawls next to a browser. Reproduce
            // Chromium's wheel physics instead (cc::ScrollOffsetAnimationCurve):
            // each notch moves 3 lines of 40px towards a running target, the
            // animation gets shorter as the outstanding distance grows, and a
            // notch landing mid-animation carries the current velocity into
            // the new curve, so sustained spinning keeps picking up speed.
            readonly property real wheelStep: win.scaledSize(120)

            FrameAnimation {
                id: wheelScroll
                running: false

                property real startY: 0
                property real targetY: 0
                property real duration: 0.2
                // Cubic bezier easing; ease-in-out (0.42, 0, 0.58, 1) for a
                // fresh scroll, with y1 tilted on retarget so the curve's
                // initial slope matches the velocity it inherits.
                property real cx1: 0.42
                property real cy1: 0
                readonly property real cx2: 0.58
                readonly property real cy2: 1

                onTriggered: {
                    var x = elapsedTime / duration;
                    if (x >= 1) {
                        editorFlick.contentY = editorFlick.snapToPixel(targetY);
                        stop();
                        return;
                    }
                    editorFlick.contentY = editorFlick.snapToPixel(
                        startY + (targetY - startY) * curveY(solveCurve(x)));
                }

                function begin(from, to, dur, slope) {
                    startY = from;
                    targetY = to;
                    duration = dur;
                    cx1 = 0.42;
                    cy1 = 0.42 * Math.max(-1000, Math.min(1000, slope));
                    restart();
                }

                function retarget(newTarget) {
                    var s = solveCurve(Math.min(1, elapsedTime / duration));
                    var pos = startY + (targetY - startY) * curveY(s);
                    var delta = newTarget - pos;
                    if (Math.abs(delta) < 0.5) {
                        editorFlick.contentY = newTarget;
                        stop();
                        return;
                    }

                    var velocity = curveDY(s) / Math.max(1e-6, curveDX(s))
                        * (targetY - startY) / duration;
                    var dur = editorFlick.wheelDuration(delta);
                    // When already moving faster than the eased curve would,
                    // bound the duration by the time to target at the current
                    // velocity; the 2.5x covers the ease-out tail.
                    if (velocity !== 0 && delta / velocity > 0)
                        dur = Math.min(dur, delta / velocity * 2.5);
                    begin(pos, newTarget, dur, velocity * dur / delta);
                }

                // Cubic bezier through (0,0), (cx1,cy1), (cx2,cy2), (1,1),
                // evaluated by Newton-solving the curve parameter from x.
                function curveX(s) { return 3 * s * (1 - s) * ((1 - s) * cx1 + s * cx2) + s * s * s; }
                function curveY(s) { return 3 * s * (1 - s) * ((1 - s) * cy1 + s * cy2) + s * s * s; }
                function curveDX(s) { return 3 * (1 - s) * (1 - s) * cx1 + 6 * (1 - s) * s * (cx2 - cx1) + 3 * s * s * (1 - cx2); }
                function curveDY(s) { return 3 * (1 - s) * (1 - s) * cy1 + 6 * (1 - s) * s * (cy2 - cy1) + 3 * s * s * (1 - cy2); }

                function solveCurve(x) {
                    var s = x;
                    for (var i = 0; i < 8; ++i) {
                        var error = curveX(s) - x;
                        if (Math.abs(error) < 0.001)
                            break;
                        var d = curveDX(s);
                        if (Math.abs(d) < 1e-6)
                            break;
                        s = Math.max(0, Math.min(1, s - error / d));
                    }
                    return s;
                }
            }

            WheelHandler {
                // Wayland compositors route every pointer's scroll through
                // one seat device that Qt classifies as a touchpad, so the
                // device type cannot tell a mouse wheel from two-finger
                // scrolling. Distinguish by event shape instead: discrete
                // wheel notches arrive with only angleDelta set, while
                // finger scrolling carries pixel-precise pixelDelta.
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: function(wheel) {
                    if (wheel.modifiers & Qt.ControlModifier) {
                        editorFlick.zoomByWheel(wheel);
                        wheel.accepted = true;
                        return;
                    }

                    scrollLinger.restart();
                    if (wheel.pixelDelta.y !== 0)
                        editorFlick.scrollTo(editorFlick.clampContentY(editorFlick.contentY - wheel.pixelDelta.y));
                    else
                        editorFlick.scrollByWheel(wheel);
                    wheel.accepted = true;
                }
            }

            onMovementStarted: wheelScroll.stop()
            onContentYChanged: editor.hoveredLinkUrl = ""

            // Ctrl+wheel changes the text size, as it does in a browser. A
            // wheel notch is a whole step, but a touchpad trickles in pixels,
            // so bank the fractions and step once a whole one is scrolled.
            property real zoomNotches: 0

            function zoomByWheel(wheel) {
                // Finger scrolling synthesizes an angleDelta too, so pixelDelta
                // is the one to test first, as in onWheel.
                var notches = wheel.pixelDelta.y !== 0
                    ? wheel.pixelDelta.y / 50
                    : wheel.angleDelta.y / 120;
                if (zoomNotches * notches < 0)
                    zoomNotches = 0;

                zoomNotches += notches;
                while (zoomNotches >= 1) {
                    win.documentBackend.increaseTextSize();
                    zoomNotches -= 1;
                }
                while (zoomNotches <= -1) {
                    win.documentBackend.decreaseTextSize();
                    zoomNotches += 1;
                }
            }

            function scrollByWheel(wheel) {
                // High-resolution wheels report fractional notches; feed
                // those through the same animated path, like Chromium does
                // for every wheel-source event.
                var notches = wheel.angleDelta.y / 120;
                if (notches === 0)
                    return;

                if (wheelScroll.running) {
                    wheelScroll.retarget(clampContentY(wheelScroll.targetY - notches * wheelStep));
                    return;
                }

                var target = clampContentY(contentY - notches * wheelStep);
                if (target !== contentY)
                    wheelScroll.begin(contentY, target, wheelDuration(target - contentY), 0);
            }

            // Chromium's inverse-delta duration: 200ms for a single notch,
            // ramping down to 100ms once 480px are outstanding.
            function wheelDuration(delta) {
                var pixels = Math.abs(delta) / win.textScale;
                return Math.max(6, Math.min(12, 14 - pixels / 60)) / 60;
            }

            function clampContentY(y) {
                return Math.max(0, Math.min(Math.max(0, contentHeight - height), y));
            }

            // Whole device pixels keep natively hinted glyphs from
            // re-rasterizing mid-animation, which reads as shimmer.
            function snapToPixel(y) {
                return Math.round(y * Screen.devicePixelRatio) / Screen.devicePixelRatio;
            }

            // Jump to a position, abandoning any wheel animation still running.
            function scrollTo(y) {
                wheelScroll.stop();
                contentY = snapToPixel(y);
            }

            // Keep the editing caret within the viewport so writing past the
            // bottom edge scrolls the page along with the text.
            function ensureCursorVisible() {
                var margin = win.editorFontPixelSize * 2;
                var cursorTop = editor.y + editor.cursorRectangle.y;
                var cursorBottom = cursorTop + editor.cursorRectangle.height;
                var maxContentY = Math.max(0, contentHeight - height);

                if (cursorBottom + margin > contentY + height)
                    scrollTo(Math.min(maxContentY, cursorBottom + margin - height));
                else if (cursorTop - margin < contentY)
                    scrollTo(Math.max(0, cursorTop - margin));
            }

            TextEdit {
                id: editor
                objectName: "sourceEditor"
                x: Math.round((editorFlick.width - width) / 2)
                // The resting position counts from the window's top edge, so
                // take back the top inset the Flickable already adds.
                y: Math.max(0, Math.max(42, Math.round(win.height * 0.05)) - win.footerHeight)
                width: win.editorWidth
                height: Math.max(editorFlick.height - y - 96, implicitHeight + 20)
                text: ""
                textFormat: TextEdit.PlainText
                wrapMode: TextEdit.Wrap
                selectByMouse: true
                persistentSelection: true
                activeFocusOnPress: true
                color: win.textColor
                selectedTextColor: win.selectionTextColor
                selectionColor: win.selectionFill
                font.family: win.documentBackend.editorFont
                font.pixelSize: win.editorFontPixelSize
                font.weight: Font.Normal
                // Native rendering hints glyphs to the pixel grid, which is
                // crispest at whole scale factors but misplaces and unevenly
                // rasterizes glyphs at fractional ones (and goes stale when
                // the compositor delivers the fractional scale after the
                // first frame). Fall back to Qt's scalable renderer there.
                renderType: Screen.devicePixelRatio % 1 === 0 ? TextEdit.NativeRendering : TextEdit.QtRendering
                cursorDelegate: Rectangle {
                    width: 1
                    color: win.textColor
                }
                onCursorRectangleChanged: editorFlick.ensureCursorVisible()
                onCursorPositionChanged: win.documentBackend.setCaretPosition(cursorPosition)
                onFontChanged: win.documentBackend.documentFontChanged()

                // One edit command, so a single undo takes the change back.
                function replaceText(start, end, replacement) {
                    win.documentBackend.replaceRange(start, end, replacement);
                }

                function replaceSelectionWith(replacement) {
                    EditorMutations.replaceRange(editor, selectionStart, selectionEnd, replacement);
                }

                function wrapSelection(marker) {
                    forceActiveFocus();
                    EditorMutations.toggleWrap(editor, marker,
                                               win.documentBackend.emphasisSpanAt(cursorPosition, marker));
                }

                function insertLink() {
                    forceActiveFocus();
                    var start = selectionStart;
                    var end = selectionEnd;
                    var selected = text.slice(start, end);
                    var url = win.documentBackend.clipboardUrl();
                    var label = selected.length > 0 ? selected : "link text";
                    var markdown = markdownLink(label, url.length > 0 ? url : "https://");
                    var labelLength = escapeMarkdownLinkText(label).length;
                    if (selected.length === 0) {
                        EditorMutations.replaceRange(editor, start, end, markdown,
                                                     1, 1 + labelLength);
                    } else if (url.length === 0) {
                        EditorMutations.replaceRange(editor, start, end, markdown,
                                                     labelLength + 3,
                                                     markdown.length - 1);
                    } else {
                        EditorMutations.replaceRange(editor, start, end, markdown);
                    }
                }

                function smartReturn(softBreak) {
                    if (softBreak) {
                        replaceSelectionWith("\n");
                        return;
                    }
                    var lineStart = text.lastIndexOf("\n", cursorPosition - 1) + 1;
                    var line = text.slice(lineStart, cursorPosition);
                    if (win.documentBackend.insideFence(cursorPosition)) {
                        replaceSelectionWith("\n");
                        return;
                    }
                    var match = line.match(/^(\s*)([-+*]|\d+[.)]|>+)\s+(.*)$/);
                    if (match) {
                        if (match[3].length === 0) {
                            EditorMutations.replaceRange(editor, lineStart,
                                                         cursorPosition, "\n");
                        } else {
                            var marker = match[2];
                            if (/^\d/.test(marker))
                                marker = (parseInt(marker) + 1) + marker.slice(-1);
                            replaceSelectionWith("\n" + match[1] + marker + " ");
                        }
                        return;
                    }
                    // A new paragraph stands apart from the one above it by a
                    // blank line, which is the second break here. A line that
                    // is already blank has nothing to stand apart from, so
                    // that break would only be a gap nobody asked for.
                    // The break lands on what the selection leaves behind, which
                    // is not the caret's line when it was dragged right to left.
                    var start = selectionStart;
                    var end = selectionEnd;
                    var head = text.slice(text.lastIndexOf("\n", start - 1) + 1, start);
                    var lineEnd = text.indexOf("\n", end);
                    var rest = lineEnd < 0 ? text.slice(end)
                                           : text.slice(end, lineEnd);
                    if (/^\s*$/.test(head) && /^\s*$/.test(rest)) {
                        replaceSelectionWith("\n");
                        return;
                    }
                    replaceSelectionWith("\n\n");
                }

                // Tab nests the list items the caret or selection touches four
                // spaces deeper, and Shift+Tab lifts them back out by the same
                // step. Lines that are neither items, their indented
                // continuations, nor blank, and code fences, leave Tab alone.
                function indentListItems(outdent) {
                    // "* * *" and "- - -" are rules, not items.
                    var listItem = function(line) {
                        return /^[ \t]*(?:[-+*]|\d+[.)])[ \t]/.test(line)
                            && !/^ {0,3}([-*])([ \t]*\1){2,}[ \t]*$/.test(line);
                    };
                    // A tab runs to the next four-column stop.
                    var columns = function(line) {
                        return line.match(/^[ \t]*/)[0].split("").reduce(function(column, c) {
                            return c === "\t" ? column + 4 - column % 4 : column + 1;
                        }, 0);
                    };

                    // A selection that ends at the start of a line leaves it be.
                    // lastIndexOf would read -1 as 0, a newline right there.
                    var start = selectionStart > 0 ? text.lastIndexOf("\n", selectionStart - 1) + 1 : 0;
                    var end = text.indexOf("\n", Math.max(start, selectionEnd - 1));
                    if (end < 0)
                        end = text.length;
                    var lines = text.slice(start, end).split("\n");
                    // The selection starts at an item and holds only lines that
                    // belong to one: other items, blanks, and indented lines.
                    // A fence indented under an item moves along with it whole;
                    // a selection that starts or ends inside code would split it.
                    var filled = lines.filter(function(line) { return /\S/.test(line); });
                    if (!listItem(filled[0] || "")
                        || filled.some(function(line) { return /^\S/.test(line) && !listItem(line); })
                        || win.documentBackend.insideFence(start)
                        || win.documentBackend.insideFence(end))
                        return false;

                    // Every line moves by the same step, so the nesting within
                    // the selection is kept. Four spaces nest under any marker
                    // up to "99.", and Shift+Tab lifts no further than the
                    // shallowest line can go.
                    var step = outdent ? -Math.min.apply(null, [4].concat(filled.map(columns))) : 4;
                    if (step === 0)
                        return true;
                    var moved = lines.map(function(line) {
                        var lead = line.match(/^[ \t]*/)[0];
                        return /\S/.test(line)
                            ? " ".repeat(columns(line) + step) + line.slice(lead.length)
                            : line;
                    });
                    var nested = moved.join("\n");
                    var from = Math.max(start, selectionStart + moved[0].length - lines[0].length);
                    // Neither end of the selection leaves its line, even when
                    // the indent it sat in is gone.
                    var lastStart = start + nested.length - moved[moved.length - 1].length;
                    var to = Math.max(from, lastStart, selectionEnd + nested.length - (end - start));
                    var forward = cursorPosition === selectionEnd;
                    replaceText(start, end, nested);
                    select(forward ? from : to, forward ? to : from);
                    return true;
                }

                function escapeMarkdownLinkText(linkText) {
                    return linkText.replace(/\\/g, "\\\\")
                                   .replace(/\[/g, "\\[")
                                   .replace(/\]/g, "\\]");
                }

                function escapeMarkdownLinkDestination(linkUrl) {
                    return linkUrl.replace(/\\/g, "\\\\")
                                  .replace(/\(/g, "\\(")
                                  .replace(/\)/g, "\\)");
                }

                function markdownLink(label, url) {
                    return "[" + escapeMarkdownLinkText(label) + "]("
                        + escapeMarkdownLinkDestination(url) + ")";
                }

                function pasteClipboardUrlAsMarkdownLink() {
                    var start = selectionStart;
                    var end = selectionEnd;
                    if (start === end)
                        return false;

                    var url = win.documentBackend.clipboardUrl();
                    if (url === "")
                        return false;

                    var selected = text.slice(start, end);
                    var leading = selected.match(/^\s*/)[0];
                    var trailing = selected.match(/\s*$/)[0];
                    var linkText = selected.slice(leading.length,
                                                  selected.length - trailing.length);
                    if (linkText === "")
                        return false;

                    replaceSelectionWith(leading + markdownLink(linkText, url) + trailing);
                    return true;
                }

                function pasteClipboardAsPlainText() {
                    var pastedText = win.documentBackend.clipboardText();
                    if (pastedText.length > 0)
                        replaceSelectionWith(pastedText);
                }

                function moveCursorVisibly(direction) {
                    if (selectionStart !== selectionEnd) {
                        cursorPosition = direction > 0 ? selectionEnd : selectionStart;
                        return;
                    }

                    var pos = win.documentBackend.cursorPositionStep(cursorPosition, direction);
                    cursorPosition = Math.max(0, Math.min(length, pos));
                }

                function movePage(direction, extendSelection) {
                    var pageStep = Math.max(win.editorFontPixelSize,
                                            editorFlick.height - win.editorFontPixelSize * 2);
                    var rect = cursorRectangle;
                    var targetY = rect.y + rect.height / 2 + direction * pageStep;
                    var target = positionAt(rect.x, Math.max(0, targetY));
                    if (extendSelection)
                        moveCursorSelection(target, TextEdit.SelectCharacters);
                    else
                        cursorPosition = target;
                }

                function deleteParagraphBreakBehindCursor() {
                    if (selectionStart !== selectionEnd || cursorPosition < 2)
                        return false;

                    // getText reads just the two characters, where text would
                    // copy the whole document on every Backspace.
                    if (getText(cursorPosition - 2, cursorPosition) !== "\n\n")
                        return false;

                    var start = cursorPosition - 2;
                    var lineEnd = text.indexOf("\n", cursorPosition);
                    var line = lineEnd < 0 ? text.slice(cursorPosition)
                                           : text.slice(cursorPosition, lineEnd);
                    // Something on the caret's line and the pair above it is a
                    // paragraph break and nothing else, either the one Return
                    // wrote to end a paragraph or the one the writer is now
                    // closing to join what it separates. Both breaks go.
                    if (/^\s*$/.test(line)) {
                        // On a blank line Return writes a single break, so up
                        // here the pair may be that break and one that was
                        // already in the document. Above a blank line Return
                        // writes a single break too, and so wrote neither of
                        // these.
                        var above = text.slice(text.lastIndexOf("\n", start - 1) + 1, start);
                        if (/^\s*$/.test(above))
                            return false;
                        // Past that the two Returns leave the same text and the
                        // same caret, and no reading of either says which was
                        // pressed. What decides instead is that the gap is left
                        // standing: both breaks go only while a blank line of
                        // it survives them. The end of the document below the
                        // caret leaves it none...
                        if (lineEnd < 0)
                            return false;
                        // ...and so does the next paragraph, which the pair
                        // would otherwise be pulled up against.
                        var belowEnd = text.indexOf("\n", lineEnd + 1);
                        var below = belowEnd < 0 ? text.slice(lineEnd + 1)
                                                 : text.slice(lineEnd + 1, belowEnd);
                        if (!/^\s*$/.test(below))
                            return false;
                    }

                    remove(start, cursorPosition);
                    cursorPosition = start;
                    return true;
                }

                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event) {
                    var pasteKey = (event.key === Qt.Key_V)
                        && (event.modifiers & Qt.ControlModifier)
                        && !(event.modifiers & (Qt.AltModifier | Qt.MetaModifier | Qt.ShiftModifier));
                    var shiftInsert = (event.key === Qt.Key_Insert)
                        && (event.modifiers & Qt.ShiftModifier)
                        && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier));
                    if (pasteKey || shiftInsert) {
                        if (!pasteClipboardUrlAsMarkdownLink())
                            pasteClipboardAsPlainText();
                        event.accepted = true;
                        return;
                    }

                    var pageKey = event.key === Qt.Key_PageDown || event.key === Qt.Key_PageUp;
                    var documentEdgeKey = (event.key === Qt.Key_Home || event.key === Qt.Key_End)
                        && (event.modifiers & Qt.ControlModifier);
                    if (pageKey || documentEdgeKey)
                        scrollLinger.restart();

                    var returnKey = event.key === Qt.Key_Return || event.key === Qt.Key_Enter;
                    var commandModifier = event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier);
                    if (returnKey && !commandModifier) {
                        smartReturn(event.modifiers & Qt.ShiftModifier);
                        event.accepted = true;
                    } else if (!commandModifier && event.key === Qt.Key_Backspace
                               && deleteParagraphBreakBehindCursor()) {
                        event.accepted = true;
                    } else if (!commandModifier && !(event.modifiers & Qt.ShiftModifier)
                               && event.key === Qt.Key_Right) {
                        moveCursorVisibly(1);
                        event.accepted = true;
                    } else if (!commandModifier && !(event.modifiers & Qt.ShiftModifier)
                               && event.key === Qt.Key_Left) {
                        moveCursorVisibly(-1);
                        event.accepted = true;
                    } else if (!commandModifier
                               && (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab)
                               && indentListItems(event.key === Qt.Key_Backtab
                                                  || (event.modifiers & Qt.ShiftModifier))) {
                        event.accepted = true;
                    } else if (!commandModifier
                               && (event.key === Qt.Key_PageDown || event.key === Qt.Key_PageUp)) {
                        movePage(event.key === Qt.Key_PageDown ? 1 : -1,
                                 event.modifiers & Qt.ShiftModifier);
                        event.accepted = true;
                    }
                }

                onTextChanged: {
                    hoveredLinkUrl = "";
                    if (win.searchUpdating || win.switchingTabs)
                        return;
                    var contentChanged = win.documentBackend.editorTextChanged();
                    if (win.searchOpen && contentChanged)
                        win.updateSearch(false);
                }

                Text {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    text: "# Start writing"
                    visible: editor.length === 0 && !editor.activeFocus
                    color: win.mutedColor
                    font.family: editor.font.family
                    font.pixelSize: editor.font.pixelSize
                    font.weight: editor.font.weight
                }

                property string hoveredLinkUrl: ""
                property real linkHoverX: 0
                property real linkHoverY: 0

                // positionAt() snaps to the nearest caret, even past the end of a
                // line, so only count a character the pointer is inside: the one
                // on either side of that caret, whichever way the text runs.
                function linkUrlUnder(x, y) {
                    var caret = positionAt(x, y);
                    for (var position = Math.max(0, caret - 1);
                         position <= caret && position < length; ++position) {
                        var box = positionToRectangle(position);
                        var next = positionToRectangle(position + 1);
                        // A hidden marker has no width; only a line's last
                        // character needs an estimate.
                        var edge = next.y === box.y
                            ? next.x : box.x + writerFontMetrics.averageCharacterWidth;
                        if (y >= box.y && y < box.y + box.height
                                && x >= Math.min(box.x, edge) && x < Math.max(box.x, edge))
                            return win.documentBackend.linkUrlAt(position);
                    }
                    return "";
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton
                    hoverEnabled: true
                    cursorShape: Qt.IBeamCursor
                    onPositionChanged: (mouse) => {
                        editor.linkHoverX = mouse.x;
                        editor.linkHoverY = mouse.y;
                        editor.hoveredLinkUrl = editor.linkUrlUnder(mouse.x, mouse.y);
                    }
                    onExited: editor.hoveredLinkUrl = ""
                }

                ToolTip {
                    visible: editor.hoveredLinkUrl.length > 0
                    x: editor.linkHoverX + 12
                    y: editor.linkHoverY + 20
                    contentItem: Label {
                        objectName: "linkTooltipText"
                        // A destination is document text; AutoText would render
                        // one that looks like HTML instead of showing it.
                        textFormat: Text.PlainText
                        text: editor.hoveredLinkUrl
                        font.family: win.documentBackend.editorFont
                        font.pixelSize: win.scaledSize(12)
                        elide: Text.ElideMiddle
                    }
                    width: Math.min(implicitWidth, win.width - 32)
                }

                Component.onCompleted: {
                    if (win.workspace) {
                        win.documentBackend.activateDocument(textDocument);
                        var state = win.workspace.viewState();
                        cursorPosition = Math.min(length, state.cursor || 0);
                        Qt.callLater(function() { editorFlick.contentY = state.scroll || 0; });
                    } else {
                        win.documentBackend.attachDocument(textDocument);
                    }
                    forceActiveFocus();
                }
            }
        }

        Row {
            id: footerStatus
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.leftMargin: 12
            anchors.bottomMargin: 10
            spacing: 12
            opacity: 0.55

            FooterIconButton {
                objectName: "saveButton"
                iconName: "save"
                iconColor: win.mutedColor
                tooltip: "Save"
                onClicked: win.documentBackend.save()
            }

            FooterIconButton {
                objectName: "openButton"
                iconName: "open"
                iconColor: win.mutedColor
                tooltip: "Open"
                onClicked: win.documentBackend.openDialog()
            }

            FooterIconButton {
                id: fontButton
                objectName: "fontButton"
                iconName: "font"
                iconColor: win.mutedColor
                tooltip: "Font"
                onClicked: fontPicker.opened ? fontPicker.close() : fontPicker.open()
            }

            Button {
                id: writingButton
                objectName: "writingSettingsButton"
                text: "Aa ⋮"
                flat: true
                height: win.scaledSize(20)
                font.pixelSize: win.scaledSize(12)
                Accessible.name: "Writing settings"
                ToolTip.visible: hovered
                ToolTip.text: "Text width, size and autosave"
                onClicked: writingSettings.opened ? writingSettings.close() : writingSettings.open()
            }

            Label {
                text: win.documentBackend.status
                color: win.mutedColor
                font.family: "IBM Plex Mono"
                font.pixelSize: win.scaledSize(11)
                visible: text !== ""
                elide: Text.ElideRight
                width: Math.min(360, win.width / 3)
                height: win.scaledSize(16)
                verticalAlignment: Text.AlignVCenter
            }
        }

        Popup {
            id: writingSettings
            objectName: "writingSettings"
            parent: writingButton
            x: Math.min(0, win.width - writingButton.mapToItem(win.contentItem, 0, 0).x - width - 12)
            y: -height - 10
            width: Math.min(win.scaledSize(340), win.width - 24)
            padding: 16
            background: Rectangle {
                color: win.darkMode ? "#29282c" : "#fafafa"
                border.color: win.darkMode ? "#4b494f" : "#d0d0d0"
                radius: 6
            }
            implicitHeight: Math.min(settingsColumn.implicitHeight + topPadding + bottomPadding,
                                     win.height - 70)
            contentItem: ScrollView {
                id: settingsScroll
                clip: true
                contentWidth: availableWidth
                contentHeight: settingsColumn.implicitHeight
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                ColumnLayout {
                    id: settingsColumn
                    width: settingsScroll.availableWidth
                    spacing: 12
                    Label { text: "Text width"; color: win.textColor }
                    ComboBox {
                        objectName: "widthSelector"
                        Layout.fillWidth: true
                        model: ["Narrow", "Medium", "Wide", "Full width"]
                        currentIndex: ["narrow", "medium", "wide", "full"].indexOf(win.documentBackend.widthMode)
                        onActivated: win.documentBackend.widthMode = ["narrow", "medium", "wide", "full"][currentIndex]
                    }
                    Label { text: "Font size"; color: win.textColor }
                    RowLayout {
                        Button {
                            Layout.preferredWidth: win.scaledSize(48)
                            Layout.minimumWidth: 0
                            text: "−"
                            Accessible.name: "Decrease font size"
                            onClicked: win.documentBackend.decreaseTextSize()
                        }
                        Button {
                            objectName: "fontSizeReset"
                            Layout.fillWidth: true
                            text: Math.round(win.documentBackend.textZoom * 100) + "%"
                            Accessible.name: "Reset font size"
                            onClicked: win.documentBackend.resetTextSize()
                        }
                        Button {
                            Layout.preferredWidth: win.scaledSize(48)
                            Layout.minimumWidth: 0
                            text: "+"
                            Accessible.name: "Increase font size"
                            onClicked: win.documentBackend.increaseTextSize()
                        }
                    }
                    Switch {
                        objectName: "autoSaveSwitch"
                        text: "Autosave named files"
                        checked: win.documentBackend.autoSaveEnabled
                        onToggled: win.documentBackend.autoSaveEnabled = checked
                    }
                    Label {
                        Layout.fillWidth: true
                        text: "Unsaved tabs are kept for the next launch."
                        wrapMode: Text.WordWrap
                        font.pixelSize: win.scaledSize(12)
                        color: win.mutedColor
                    }
                }
            }
            onClosed: editor.forceActiveFocus()
        }

        FontPicker {
            id: fontPicker
            objectName: "fontPicker"
            // Parented to its button, so a press on the button is not a press
            // outside that closes it only for the click to open it again.
            parent: fontButton
            x: -8
            y: -height - 10
            width: win.scaledSize(320)
            maximumHeight: Math.min(win.scaledSize(440), win.height - 80)
            fonts: win.documentBackend.availableFonts
            currentFont: win.documentBackend.editorFont
            defaultFont: "IBM Plex Mono"
            darkMode: win.darkMode
            textScale: win.textScale
            textColor: win.textColor
            mutedColor: win.mutedColor
            highlightColor: win.documentBackend.themeAccent
            onFontChosen: function(family) { win.documentBackend.editorFont = family; }
            onClosed: editor.forceActiveFocus()
        }

        Label {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: 12
            anchors.bottomMargin: 10
            text: win.documentBackend.wordCount + (win.documentBackend.wordCount === 1 ? " Word" : " Words")
            color: win.mutedColor
            opacity: 0.75
            font.family: "IBM Plex Mono"
            font.pixelSize: win.scaledSize(11)
        }


        Pane {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: 12
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            height: win.scaledSize(win.replaceOpen ? 104 : 56)
            visible: win.searchOpen
            z: 10
            leftPadding: 16
            rightPadding: 8
            topPadding: 0
            bottomPadding: 0
            Material.elevation: 8
            // Reaches here from either field or the buttons beside them.
            Keys.onEscapePressed: function(event) {
                win.closeSearch();
                event.accepted = true;
            }

            background: Rectangle {
                radius: 9
                color: win.darkMode ? "#22221f" : "#fffef2"
            }

            RowLayout {
                anchors.fill: parent
                spacing: 8

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    TextInput {
                        id: searchField
                        objectName: "searchField"
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        height: win.replaceOpen ? parent.height / 2 : parent.height
                        verticalAlignment: TextInput.AlignVCenter
                        selectByMouse: true
                        activeFocusOnTab: true
                        color: win.textColor
                        selectionColor: win.selectionFill
                        selectedTextColor: win.selectionTextColor
                        font.pixelSize: win.scaledSize(17)
                        clip: true
                        onTextChanged: searchDelay.restart()
                        Keys.onReturnPressed: function(event) {
                            win.moveSearch((event.modifiers & Qt.ShiftModifier) ? -1 : 1);
                            event.accepted = true;
                        }
                    }

                    TextInput {
                        id: replaceField
                        objectName: "replaceField"
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: parent.height / 2
                        visible: win.replaceOpen
                        verticalAlignment: TextInput.AlignVCenter
                        selectByMouse: true
                        activeFocusOnTab: true
                        clip: true
                        color: win.textColor
                        selectionColor: win.selectionFill
                        selectedTextColor: win.selectionTextColor
                        font.pixelSize: win.scaledSize(17)
                        Keys.onReturnPressed: replaceCurrentButton.clicked()
                    }

                    Label {
                        anchors.verticalCenter: replaceField.verticalCenter
                        text: "Replace with"
                        visible: win.replaceOpen && replaceField.text.length === 0
                        color: win.mutedColor
                        font.pixelSize: win.scaledSize(17)
                    }

                    Label {
                        anchors.verticalCenter: searchField.verticalCenter
                        text: "Find"
                        visible: searchField.text.length === 0
                        color: win.mutedColor
                        font.pixelSize: win.scaledSize(17)
                    }
                }

                Label {
                    Layout.preferredWidth: win.scaledSize(58)
                    Layout.fillHeight: true
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: win.searchMatches.length === 0
                        ? "0/0"
                        : (win.searchMatchIndex + 1) + "/" + win.searchMatches.length
                    color: win.darkMode ? win.textColor : "#62635f"
                    font.pixelSize: win.scaledSize(16)
                }

                Button {
                    id: replaceCurrentButton
                    objectName: "replaceButton"
                    visible: win.replaceOpen
                    text: "Replace"
                    onClicked: {
                        win.flushSearch();
                        if (win.searchMatchIndex < 0) return;
                        var start = win.searchMatches[win.searchMatchIndex];
                        var replacement = replaceField.text;
                        EditorMutations.replaceRange(editor, start,
                                                     start + searchField.text.length,
                                                     replacement);
                        // Carry on past what was just written, so a replacement
                        // the query also matches is not found again.
                        win.searchMatches = win.documentBackend.searchMatches(searchField.text);
                        win.searchMatchIndex = win.matchAtOrAfter(start + replacement.length);
                        win.showSearchMatch(true);
                    }
                }

                Button {
                    objectName: "replaceAllButton"
                    visible: win.replaceOpen
                    text: "All"
                    onClicked: {
                        win.flushSearch();
                        var query = searchField.text;
                        var matches = win.searchMatches;
                        if (query.length === 0 || matches.length === 0) return;
                        // One replacement over the span of every match, so a
                        // single undo takes them all back.
                        var first = matches[0];
                        var replaced = "";
                        var position = first;
                        for (var i = 0; i < matches.length; ++i) {
                            replaced += editor.text.slice(position, matches[i]) + replaceField.text;
                            position = matches[i] + query.length;
                        }
                        EditorMutations.replaceRange(editor, first, position, replaced);
                        win.updateSearch(false);
                    }
                }

                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 34
                    color: win.darkMode ? "#6f6f62" : "#d5d56e"
                }

                SearchIconButton {
                    iconName: "up"
                    iconColor: win.darkMode ? win.textColor : "#62635f"
                    onClicked: win.moveSearch(-1)
                }

                SearchIconButton {
                    iconName: "down"
                    iconColor: win.darkMode ? win.textColor : "#62635f"
                    onClicked: win.moveSearch(1)
                }

                SearchIconButton {
                    iconName: "close"
                    iconColor: win.darkMode ? win.textColor : "#62635f"
                    onClicked: win.closeSearch()
                }
            }
        }
    }

    Component.onCompleted: {
        var geometry = win.documentBackend.windowGeometry();
        if (geometry.x >= 0) x = geometry.x;
        if (geometry.y >= 0) y = geometry.y;
        width = geometry.width;
        height = geometry.height;
        if (geometry.maximized) showMaximized();
    }

    Component.onDestruction: win.documentBackend.saveWindowGeometry(x, y, width, height, visibility === Window.Maximized)

}
