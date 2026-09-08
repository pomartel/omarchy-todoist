import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Todoist task list popup. Owns every bit of state BarWidget.qml reads back
// (apiToken, taskCount) plus the curl processes that talk to the Todoist API
// (https://developer.todoist.com/api/v1/) and the local settings file that
// holds the personal API token.
Panel {
  id: root
  moduleName: "omarchy-todoist"
  ipcTarget: "omarchy-todoist"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string apiBase: "https://api.todoist.com/api/v1"
  readonly property string homeDir: Quickshell.env("HOME")
  readonly property string pluginDir: homeDir + "/.config/omarchy/plugins/omarchy-todoist"
  readonly property string stateDir: homeDir + "/.local/state/omarchy/omarchy-todoist"
  readonly property string settingsPath: stateDir + "/settings.json"

  property string apiToken: ""
  property string filterQuery: "today | overdue"
  // "today" | "tomorrow" | "inbox" | "all" | "custom" — the four tabs plus whatever the
  // free-form filter field in Settings last applied.
  property string quickView: "today"
  property bool settingsLoaded: false
  property bool settingsView: true
  // Gives keyboard nav a sensible starting point regardless of how Settings
  // was entered/left (gear click, "p", or the initial open-with-no-token
  // case) — without this, Tab/arrows in a freshly opened Settings would
  // have nothing focused to step from.
  onSettingsViewChanged: {
    if (!root.opened) return
    Qt.callLater(function() {
      if (!root.opened) return
      if (root.settingsView) {
        // Always start scrolled to the top — the Flickable is shared with
        // the task list, so a deep scroll position from a long task list
        // would otherwise carry over and land Settings mid-scroll.
        scroll.contentY = 0
        if (tokenField) tokenField.forceActiveFocus()
      } else {
        keyCatcher.forceActiveFocus()
      }
    })
  }

  property var tasks: []
  readonly property int taskCount: tasks.length
  onTasksChanged: {
    if (root.selectedTaskIndex >= root.tasks.length) root.selectedTaskIndex = root.tasks.length - 1
  }

  // Keyboard cursor over the task list. -1 = nothing selected yet;
  // taskCursorActive gates the row highlight so it only shows up once the
  // user has actually pressed an arrow key, not on every open.
  property int selectedTaskIndex: -1
  property bool taskCursorActive: false

  // Tasks mid-completion: closed on the server already, but kept in the
  // list (struck through, dimmed) for a moment so the click reads as
  // "done", not "vanished".
  property var completingTaskIds: []
  property var pendingRemovalIds: []

  // Inline content editing. -1 = no row being edited.
  property int editingTaskIndex: -1
  property string editDraft: ""

  // Enter fires both returnRequested (open in browser) and activateRequested
  // (complete) back-to-back — this suppresses the completion half of that so
  // Enter only opens the browser; Space still completes on its own.
  property bool suppressNextActivate: false

  property bool helpOpen: false

  // Fixed popup size, user-adjustable from Settings → Advanced. Deliberately
  // NOT derived from content (mainColumn.implicitHeight) — letting the
  // window grow/shrink with task count is what was causing content to
  // overflow past the card; a fixed size scrolls instead.
  property int panelWidth: 340
  property int panelHeight: 480

  property bool loading: false
  property string errorText: ""
  // Set when refresh() is called while a fetch is already in flight —
  // listProc's own exit handler starts one more fetch once it sees this,
  // so a triggering action never has its refresh silently dropped.
  property bool refreshPending: false
  // 0 = never synced. Set from listProc's own success path (not from
  // refresh() itself, which fires before the request completes) so the
  // header's SYNCED stat always reflects a real, landed response.
  property real lastSyncedAt: 0

  // ---- Bar count (Settings → Bar Count). A fixed choice independent of
  //      whichever tab the popup itself is showing — "hide" is the shipped
  //      default (icon-only bar pill). Kept separate from `quickView` on
  //      purpose: switching tabs while the popup is open must not change
  //      what the bar badge shows.
  property string barCountMode: "hide"
  property int barCountValue: 0
  property int todayTaskCount: 0
  property int tomorrowTaskCount: 0
  property int inboxTaskCount: 0
  property int allTaskCount: 0

  property string tokenDraft: ""
  property string quickAddText: ""
  property bool quickAddSubmitting: false
  property var actionQueue: []

  // ---- Keyboard shortcut (Settings → Keyboard shortcut). Empty means no
  //      shortcut has been wired into ~/.config/hypr/bindings.lua yet.
  property string keybindCombo: ""
  property bool recordingKeybind: false
  property string pendingKeybindCombo: ""
  property string keybindRecordError: ""
  property string keybindApplyStatus: ""
  property string keybindApplyError: ""

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string emptyStateMessage: root.quickView === "inbox" ? "Inbox est vide."
    : root.quickView === "tomorrow" ? "Rien à faire demain."
    : root.quickView === "all" ? "Aucune tâche pour le moment."
    : root.quickView === "custom" ? "Aucune tâche ne correspond à ce filtre."
    : "Rien à faire. Tout est en ordre."

  readonly property string barCountModeLabel: root.barCountMode === "today" ? "aujourd’hui"
    : root.barCountMode === "inbox" ? "dans Inbox"
    : root.barCountMode === "all" ? "au total"
    : ""

  // ---- Lifecycle. Matches the clock/weather contract: open() refreshes
  //      before showing so the list is never more than one popup-open stale.
  function open() {
    if (root.apiToken !== "") refresh()
    root.controller.show()
    // Only steal focus into a text field when Settings needs the token
    // typed immediately. Otherwise leave focus on keyCatcher (its own
    // default via KeyboardPanel's focusTarget) so arrows/Tab/r/q work the
    // instant the panel opens, instead of being swallowed by quickAddField.
    if (root.settingsView) Qt.callLater(function() {
      if (root.opened && root.settingsView) tokenField.forceActiveFocus()
    })
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // ---- Settings persistence. A local state file, not shell.json — the
  //      token is a secret, not bar layout, so it never round-trips through
  //      the shared config the bar writes.
  function ensureStateDir() {
    mkdirProc.running = true
  }

  function loadSettingsFromText(text) {
    var parsed = {}
    try { parsed = JSON.parse(text || "{}") } catch (e) { parsed = {} }
    if (typeof parsed.apiToken === "string") root.apiToken = parsed.apiToken
    if (typeof parsed.filter === "string") root.filterQuery = Model.sanitizeFilter(parsed.filter)
    if (typeof parsed.quickView === "string" && ["today", "tomorrow", "inbox", "all", "custom"].indexOf(parsed.quickView) !== -1)
      root.quickView = parsed.quickView
    if (typeof parsed.keybind === "string") root.keybindCombo = parsed.keybind
    if (typeof parsed.panelWidth === "number") root.panelWidth = Math.max(260, Math.min(700, parsed.panelWidth))
    if (typeof parsed.panelHeight === "number") root.panelHeight = Math.max(240, Math.min(800, parsed.panelHeight))
    if (typeof parsed.barCountMode === "string" && ["hide", "today", "inbox", "all"].indexOf(parsed.barCountMode) !== -1)
      root.barCountMode = parsed.barCountMode
    root.settingsLoaded = true
    root.settingsView = root.apiToken === ""
    if (root.apiToken !== "") { refresh(); refreshBarCount() }
  }

  function persistSettings() {
    settingsFile.setText(JSON.stringify({
      apiToken: root.apiToken,
      filter: root.filterQuery,
      quickView: root.quickView,
      keybind: root.keybindCombo,
      panelWidth: root.panelWidth,
      panelHeight: root.panelHeight,
      barCountMode: root.barCountMode
    }, null, 2) + "\n")
    // The token is a secret; keep the file readable only by the user. A
    // short defer gives the atomic write below somewhere to land first.
    Qt.callLater(function() { chmodProc.running = true })
  }

  function saveToken() {
    var value = Model.safeTrim(root.tokenDraft)
    if (value === "") return
    root.apiToken = value
    root.tokenDraft = ""
    tokenField.text = ""
    root.errorText = ""
    root.settingsView = false
    persistSettings()
    refresh()
  }

  function clearToken() {
    root.apiToken = ""
    root.tasks = []
    root.errorText = ""
    root.settingsView = true
    persistSettings()
  }

  function applyFilter(value) {
    var next = Model.sanitizeFilter(value)
    filterField.text = next
    root.quickView = "custom"
    if (next === root.filterQuery) { persistSettings(); refresh(); return }
    root.filterQuery = next
    persistSettings()
    refresh()
  }

  // ---- Popup size (Settings → Advanced).
  function setPanelWidth(width) {
    root.panelWidth = Math.max(260, Math.min(700, width))
    persistSettings()
  }

  function setPanelHeight(height) {
    root.panelHeight = Math.max(240, Math.min(800, height))
    persistSettings()
  }

  // ---- Settings keyboard navigation. An explicit ordered chain (not
  //      native Tab-focus-traversal — PanelKeyCatcher intercepts Tab itself
  //      via Keys.priority: BeforeItem, so relying on Qt's own chain would
  //      never see it) that Tab/Shift+Tab and Up/Down both walk while
  //      Settings is open. Conditionally-visible controls (Remove token,
  //      the keybind recorder's two different button sets) are filtered in
  //      or out here rather than kept as fixed slots.
  function settingsFocusChain() {
    var chain = [tokenField, saveTokenButton]
    if (root.apiToken !== "") chain.push(removeTokenButton)
    chain.push(filterField, filterApplyButton)
    chain.push(barCountHideButton, barCountTodayButton, barCountInboxButton, barCountAllButton)
    if (root.recordingKeybind) {
      chain.push(applyKeybindButton, cancelKeybindButton)
    } else {
      chain.push(keybindDefaultButton, recordCustomButton)
      if (root.keybindCombo !== "") chain.push(removeKeybindButton)
    }
    // openTodoistButton is deliberately not part of the chain — it launches
    // an external browser, which can steal window focus from the panel
    // mid-navigation. Still reachable by mouse or the "t" shortcut.
    chain.push(refreshNowButton, keyboardShortcutsButton)
    chain.push(widthMinusButton, widthPlusButton, heightMinusButton, heightPlusButton)
    // A disabled item silently rejects forceActiveFocus() in Qt Quick —
    // Tab has to skip past it rather than try to land there and fail.
    return chain.filter(function(item) { return item && item.enabled !== false })
  }

  function moveSettingsFocus(direction) {
    var chain = root.settingsFocusChain()
    if (chain.length === 0) return
    var currentIndex = -1
    for (var i = 0; i < chain.length; i++) {
      if (chain[i] && chain[i].activeFocus) { currentIndex = i; break }
    }
    var next = currentIndex === -1 ? 0 : (currentIndex + direction + chain.length) % chain.length
    if (chain[next]) {
      chain[next].forceActiveFocus()
      Qt.callLater(function() { root.ensureSettingsControlVisible(chain[next]) })
    }
  }

  // Settings shares one Flickable with the task list, so a control the
  // chain just focused can easily land outside the currently-scrolled
  // region — scroll just enough to bring it fully into view either way.
  function ensureSettingsControlVisible(item) {
    if (!item) return
    var pos = item.mapToItem(mainColumn, 0, 0)
    var itemTop = pos.y
    var itemBottom = pos.y + item.height
    if (itemTop < scroll.contentY) {
      scroll.contentY = Math.max(0, itemTop - Style.spacing.sm)
    } else if (itemBottom > scroll.contentY + scroll.height) {
      scroll.contentY = itemBottom - scroll.height + Style.spacing.sm
    }
  }

  function openTodoistWebsite() {
    openUrlProc.command = ["xdg-open", "https://app.todoist.com/app/today"]
    openUrlProc.running = true
  }

  function activateFocusedSettingsControl() {
    var chain = root.settingsFocusChain()
    for (var i = 0; i < chain.length; i++) {
      var item = chain[i]
      if (item && item.activeFocus && typeof item.clicked === "function") {
        item.clicked()
        return
      }
    }
  }

  // ---- Quick views. Today/tomorrow fetch all active tasks and are filtered
  //      locally so their dates use the machine timezone. Inbox and custom
  //      keep using Todoist's filter endpoint; all hits plain /tasks.
  function selectQuickView(view) {
    if (view === root.quickView) return
    root.quickView = view
    root.selectedTaskIndex = -1
    root.taskCursorActive = false
    persistSettings()
    refresh()
  }

  readonly property var quickViewOrder: ["today", "tomorrow", "inbox", "all"]

  function cycleQuickView(direction) {
    var idx = root.quickViewOrder.indexOf(root.quickView)
    if (idx === -1) idx = 0
    var next = (idx + direction + root.quickViewOrder.length) % root.quickViewOrder.length
    root.selectQuickView(root.quickViewOrder[next])
  }

  // ---- Keyboard cursor over the task list (arrow keys / j·k, Enter/Space
  //      to complete). Independent of the Tab-driven quick-view cycling and
  //      of the keyboard-shortcut recorder above.
  function moveTaskCursor(delta) {
    if (root.tasks.length === 0) return
    root.taskCursorActive = true
    var next = root.selectedTaskIndex + delta
    if (next < 0) next = 0
    if (next > root.tasks.length - 1) next = root.tasks.length - 1
    root.selectedTaskIndex = next
    Qt.callLater(function() {
      if (taskListView.count > 0) taskListView.positionViewAtIndex(root.selectedTaskIndex, ListView.Contain)
    })
  }

  function activateSelectedTask() {
    if (root.selectedTaskIndex < 0 || root.selectedTaskIndex >= root.tasks.length) return
    var task = root.tasks[root.selectedTaskIndex]
    if (task) root.requestComplete(task.id)
  }

  // ---- Open the selected task on the Todoist website (Enter). Closes the
  //      panel afterward — attention is going to the browser, not staying
  //      here, matching how launching anything else from a panel dismisses it.
  function openSelectedTaskInBrowser() {
    if (root.selectedTaskIndex < 0 || root.selectedTaskIndex >= root.tasks.length) return
    var task = root.tasks[root.selectedTaskIndex]
    if (!task || !task.id) return
    openUrlProc.command = ["omarchy-launch-or-focus-webapp", "brave-app.todoist", "https://app.todoist.com/app/task/" + encodeURIComponent(task.id)]
    openUrlProc.running = true
    root.close()
  }

  // ---- Inline content edit (e).
  function startEditSelectedTask() {
    if (root.selectedTaskIndex < 0 || root.selectedTaskIndex >= root.tasks.length) return
    var task = root.tasks[root.selectedTaskIndex]
    if (!task || root.completingTaskIds.indexOf(task.id) !== -1) return
    root.editDraft = task.content || ""
    root.editingTaskIndex = root.selectedTaskIndex
  }

  function cancelEditTask() {
    root.editingTaskIndex = -1
    root.editDraft = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // ---- Runs a curl Process with the Todoist Authorization header. The
  //      token is deliberately never placed in `command` — argv is visible
  //      to every local user via /proc or `ps`, so the header is instead
  //      handed to curl over its own stdin as a "-K -" config line (curl's
  //      documented way to keep a secret out of the process list); `command`
  //      itself must include "-K", "-" wherever the header would have gone.
  function runAuthedCurl(proc, command) {
    proc.stdinEnabled = true
    proc.command = command
    proc.running = true
    proc.write("header = \"Authorization: Bearer " + root.apiToken + "\"\n")
    proc.stdinEnabled = false
  }

  function commitEditTask() {
    var index = root.editingTaskIndex
    root.editingTaskIndex = -1
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    if (index < 0 || index >= root.tasks.length) { root.editDraft = ""; return }
    var task = root.tasks[index]
    var newContent = Model.safeTrim(root.editDraft)
    root.editDraft = ""
    if (!task || newContent === "" || newContent === task.content) return

    var updated = {}
    for (var key in task) updated[key] = task[key]
    updated.content = newContent
    var nextTasks = root.tasks.slice()
    nextTasks[index] = updated
    root.tasks = nextTasks

    runAuthedCurl(editProc, ["curl", "-fsS", "--max-time", "10", "-K", "-", "-X", "POST",
      "-H", "Content-Type: application/json",
      "-d", JSON.stringify({ content: newContent }),
      root.apiBase + "/tasks/" + encodeURIComponent(task.id)])
  }

  // ---- Quick due-date actions for the selected task (a/d/i). Without a
  //      selected task these keys keep their quick-view behavior below.
  function selectedTask() {
    if (root.selectedTaskIndex < 0 || root.selectedTaskIndex >= root.tasks.length) return null
    return root.tasks[root.selectedTaskIndex]
  }

  function setSelectedTaskDue(dueString) {
    var task = root.selectedTask()
    if (!task || !task.id || dueProc.running) return

    var payload = dueString === null
      ? { due_string: "no date" }
      : { due_string: dueString, due_lang: "fr" }
    runAuthedCurl(dueProc, ["curl", "-fsS", "--max-time", "10", "-K", "-", "-X", "POST",
      "-H", "Content-Type: application/json",
      "-d", JSON.stringify(payload),
      root.apiBase + "/tasks/" + encodeURIComponent(task.id)])
  }

  // ---- Delete the selected task (via "x"). -----------------------------
  function requestDeleteSelected() {
    if (root.selectedTaskIndex < 0 || root.selectedTaskIndex >= root.tasks.length) return
    var task = root.tasks[root.selectedTaskIndex]
    if (!task) return
    root.tasks = root.tasks.filter(function(t) { return !t || t.id !== task.id })
    runAuthedCurl(deleteProc, ["curl", "-fsS", "--max-time", "10", "-K", "-", "-X", "DELETE",
      root.apiBase + "/tasks/" + encodeURIComponent(task.id)])
  }

  // ---- Task list. Every mutating action (add/complete/edit/delete/view
  //      switch) and both poll timers funnel through this one function, so
  //      "avoid duplicate requests" only has to be solved once: if a fetch
  //      is already in flight, don't start a second curl process — just
  //      remember that a fresh one is wanted and let listProc's own exit
  //      handler fire it once the in-flight one finishes. That's how an
  //      "immediate" refresh stays immediate without ever running two list
  //      fetches at the same time.
  // Shared by refresh() (the popup's own list) and refreshBarCount() (the
  // bar badge's independent count) — same three endpoints either way.
  function urlForView(view) {
    if (view === "all" || view === "today" || view === "tomorrow")
      return root.apiBase + "/tasks"
    var query = view === "inbox" ? "#Inbox & no due date"
      : view === "tomorrow" ? "tomorrow"
      : view === "custom" ? root.filterQuery
      : "today | overdue"
    return root.apiBase + "/tasks/filter?query=" + encodeURIComponent(query) + "&lang=fr"
  }

  function refresh() {
    if (root.apiToken === "") {
      root.settingsView = true
      return
    }
    if (listProc.running) { root.refreshPending = true; return }
    root.refreshPending = false
    root.loading = true
    root.errorText = ""

    runAuthedCurl(listProc, ["curl", "-fsS", "--max-time", "10", "-K", "-", root.urlForView(root.quickView)])
    root.refreshViewCounts()
    // A fetch just actually started — push both poll timers' next tick out
    // from here rather than from whenever the panel happened to open, so a
    // background/interval tick can't land moments after a refresh some
    // other action already triggered.
    openRefreshTimer.restart()
    backgroundRefreshTimer.restart()
  }

  function countForView(view) {
    return view === "today" ? root.todayTaskCount
      : view === "tomorrow" ? root.tomorrowTaskCount
      : view === "inbox" ? root.inboxTaskCount
      : root.allTaskCount
  }

  function refreshViewCounts() {
    if (root.apiToken === "") return
    if (!todayCountProc.running)
      runAuthedCurl(todayCountProc, ["curl", "-fsS", "--max-time", "10", "-K", "-", root.urlForView("today")])
    if (!tomorrowCountProc.running)
      runAuthedCurl(tomorrowCountProc, ["curl", "-fsS", "--max-time", "10", "-K", "-", root.urlForView("tomorrow")])
    if (!inboxCountProc.running)
      runAuthedCurl(inboxCountProc, ["curl", "-fsS", "--max-time", "10", "-K", "-", root.urlForView("inbox")])
    if (!allCountProc.running)
      runAuthedCurl(allCountProc, ["curl", "-fsS", "--max-time", "10", "-K", "-", root.urlForView("all")])
  }

  // ---- Bar count (Settings → Bar Count). Independent of whichever tab the
  //      popup itself is showing. Skips the request entirely when the
  //      chosen mode happens to match the popup's current tab — reuses
  //      root.taskCount instead of duplicating the fetch.
  function refreshBarCount() {
    if (root.barCountMode === "hide" || root.apiToken === "") return
    if (root.barCountMode === root.quickView) {
      root.barCountValue = root.taskCount
      return
    }
    if (barCountProc.running) return
    runAuthedCurl(barCountProc, ["curl", "-fsS", "--max-time", "10", "-K", "-", root.urlForView(root.barCountMode)])
  }

  function setBarCountMode(mode) {
    if (mode === root.barCountMode) return
    root.barCountMode = mode
    persistSettings()
    root.refreshBarCount()
  }

  // ---- Quick add. Uses Todoist's own Quick Add parser (/tasks/quick) so
  //      "p1"/"p2"/"p3"/"p4", "#Project", "@label", and natural-language
  //      due dates work exactly like typing into Todoist itself. A bare task
  //      inherits Auj/Demain, while other views leave it without a due date.
  function quickAddTextForView(content) {
    if (Model.quickAddHasDueHint(content)) return content
    if (root.quickView === "today") return content + " aujourd'hui"
    if (root.quickView === "tomorrow") return content + " demain"
    return content
  }

  function submitQuickAdd() {
    var content = Model.safeTrim(root.quickAddText)
    if (content === "" || root.quickAddSubmitting || root.apiToken === "") return
    var text = root.quickAddTextForView(content)
    root.quickAddSubmitting = true
    root.errorText = ""
    runAuthedCurl(createProc, ["curl", "-fsS", "--max-time", "10", "-K", "-", "-X", "POST",
      "-H", "Content-Type: application/json",
      "-d", JSON.stringify({ text: text }),
      root.apiBase + "/tasks/quick"])
  }

  // ---- Complete task. Marked "completing" (struck through, dimmed) right
  //      away for feedback, then actually removed from the list a moment
  //      later — the API call itself fires immediately, only the row's
  //      disappearance is delayed.
  function requestComplete(taskId) {
    if (taskId === "" || root.completingTaskIds.indexOf(taskId) !== -1) return
    root.completingTaskIds = root.completingTaskIds.concat([taskId])
    root.pendingRemovalIds.push(taskId)
    root.actionQueue.push(taskId)
    processActionQueue()
    completionRemovalTimer.restart()
  }

  // Undoes the optimistic "completing" state for one task without touching
  // any other task mid-completion — used when the close call itself fails,
  // so a failed complete doesn't still get silently removed 700ms later by
  // flushCompletedRemovals()'s own blind removal-by-id.
  function undoCompleting(taskId) {
    root.completingTaskIds = root.completingTaskIds.filter(function(id) { return id !== taskId })
    root.pendingRemovalIds = root.pendingRemovalIds.filter(function(id) { return id !== taskId })
  }

  function flushCompletedRemovals() {
    var ids = root.pendingRemovalIds
    root.pendingRemovalIds = []
    root.tasks = root.tasks.filter(function(t) { return !t || ids.indexOf(t.id) === -1 })
    root.completingTaskIds = root.completingTaskIds.filter(function(id) { return ids.indexOf(id) === -1 })
    // Refresh now, once the strike-through/dim animation has actually
    // settled — not from actionProc's own success handler directly, which
    // could arrive before the 700ms delay above and have this task's row
    // vanish outright (a full list replacement) instead of visibly
    // completing first.
    root.refresh()
  }

  function processActionQueue() {
    if (actionProc.running || root.actionQueue.length === 0) return
    var taskId = root.actionQueue.shift()
    actionProc.pendingTaskId = taskId
    runAuthedCurl(actionProc, ["curl", "-fsS", "--max-time", "10", "-K", "-", "-X", "POST",
      root.apiBase + "/tasks/" + encodeURIComponent(taskId) + "/close"])
  }

  // ---- Keyboard shortcut recording. Mirrors a stripped-down Hyprland key
  //      combo into "MOD + MOD + KEY" form; set-keybind.sh does the actual
  //      ~/.config/hypr/bindings.lua edit (backup + reload + auto-rollback).
  function isBareModifier(key) {
    return key === Qt.Key_Super_L || key === Qt.Key_Super_R || key === Qt.Key_Meta
      || key === Qt.Key_Control || key === Qt.Key_Shift || key === Qt.Key_Alt || key === Qt.Key_AltGr
  }

  function hyprKeyName(key) {
    if (key >= Qt.Key_A && key <= Qt.Key_Z) return String.fromCharCode(key)
    if (key >= Qt.Key_0 && key <= Qt.Key_9) return String.fromCharCode(key)
    if (key >= Qt.Key_F1 && key <= Qt.Key_F12) return "F" + (key - Qt.Key_F1 + 1)
    var names = {}
    names[Qt.Key_Space] = "SPACE"
    names[Qt.Key_Return] = "RETURN"
    names[Qt.Key_Enter] = "RETURN"
    names[Qt.Key_Tab] = "TAB"
    names[Qt.Key_Backspace] = "BACKSPACE"
    names[Qt.Key_Comma] = "comma"
    names[Qt.Key_Period] = "period"
    names[Qt.Key_Minus] = "minus"
    names[Qt.Key_Equal] = "equal"
    names[Qt.Key_Slash] = "slash"
    return names[key] || ""
  }

  function startRecordingKeybind() {
    root.recordingKeybind = true
    root.pendingKeybindCombo = ""
    root.keybindRecordError = ""
    root.keybindApplyStatus = ""
  }

  function cancelRecordingKeybind() {
    root.recordingKeybind = false
    root.pendingKeybindCombo = ""
    root.keybindRecordError = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function handleKeybindRecordKey(event) {
    if (event.key === Qt.Key_Escape && event.modifiers === Qt.NoModifier) {
      root.cancelRecordingKeybind()
      event.accepted = true
      return
    }
    if (root.isBareModifier(event.key)) { event.accepted = true; return }

    var mods = []
    if (event.modifiers & Qt.MetaModifier) mods.push("SUPER")
    if (event.modifiers & Qt.ControlModifier) mods.push("CTRL")
    if (event.modifiers & Qt.AltModifier) mods.push("ALT")
    if (event.modifiers & Qt.ShiftModifier) mods.push("SHIFT")

    var keyStr = root.hyprKeyName(event.key)
    if (keyStr === "") {
      root.keybindRecordError = "Touche non prise en charge — essayez une lettre, un chiffre, une touche F ou un signe de ponctuation."
      event.accepted = true
      return
    }
    if (mods.length === 0) {
      root.keybindRecordError = "Ajoutez une touche modificatrice (Super/Ctrl/Alt/Shift) — une touche seule perturberait la saisie partout."
      event.accepted = true
      return
    }

    root.keybindRecordError = ""
    root.pendingKeybindCombo = mods.join(" + ") + " + " + keyStr
    event.accepted = true
  }

  function applyKeybindCombo(combo) {
    if (combo === "" || root.keybindApplyStatus === "applying") return
    root.keybindApplyStatus = "applying"
    root.keybindApplyError = ""
    keybindProc.pendingApply = combo
    keybindProc.command = ["bash", root.pluginDir + "/set-keybind.sh", combo]
    keybindProc.running = true
  }

  function removeKeybindCombo() {
    if (root.keybindCombo === "" || root.keybindApplyStatus === "applying") return
    root.keybindApplyStatus = "applying"
    root.keybindApplyError = ""
    keybindProc.pendingApply = ""
    keybindProc.command = ["bash", root.pluginDir + "/set-keybind.sh", "__REMOVE__"]
    keybindProc.running = true
  }

  Component.onCompleted: {
    ensureStateDir()
    Qt.callLater(function() { settingsFile.reload() })
  }

  // ---- Processes -----------------------------------------------------

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.stateDir]
  }

  Process {
    id: chmodProc
    command: ["chmod", "600", root.settingsPath]
  }

  Process {
    id: listProc
    stdout: StdioCollector {
      id: listOut
      waitForEnd: true
      onStreamFinished: {
        root.loading = false
        var raw = String(text || "").trim()
        if (raw === "") return
        try {
          var parsed = JSON.parse(raw)
          var results = (parsed && parsed.results) ? parsed.results : []
          root.tasks = Model.sortedTasks(Model.tasksForView(
            Model.topLevelTasks(results), root.quickView))
          root.errorText = ""
          root.lastSyncedAt = Date.now()
          // Keeps the bar badge's "same tab" fast path maximally fresh
          // without waiting for the next poll tick.
          root.refreshBarCount()
        } catch (e) {
          root.errorText = "Impossible de lire la réponse de Todoist."
        }
      }
    }
    stderr: StdioCollector {
      id: listErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.loading = false
      if (exitCode !== 0) root.errorText = Model.errorMessageForExit(exitCode, listErr.text)
      if (root.refreshPending) Qt.callLater(root.refresh)
    }
  }

  // Independent background count for the bar badge (Settings → Bar Count).
  // Best-effort: a failed fetch here just keeps the last known value — this
  // is a bar-pill nicety, not core functionality the way the popup's own
  // task list is, so it doesn't surface an error anywhere.
  Process {
    id: barCountProc
    stdout: StdioCollector {
      id: barCountOut
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw === "") return
        try {
          var parsed = JSON.parse(raw)
          var results = (parsed && parsed.results) ? parsed.results : []
          root.barCountValue = Model.tasksForView(
            Model.topLevelTasks(results), root.barCountMode).length
        } catch (e) {
          // Keep the last known value.
        }
      }
    }
    stderr: StdioCollector {
      id: barCountErr
      waitForEnd: true
    }
  }

  function applyViewCount(view, raw) {
    try {
      var parsed = JSON.parse(String(raw || "").trim())
      var results = (parsed && parsed.results) ? parsed.results : []
      var count = Model.tasksForView(Model.topLevelTasks(results), view).length
      if (view === "today") root.todayTaskCount = count
      else if (view === "tomorrow") root.tomorrowTaskCount = count
      else if (view === "inbox") root.inboxTaskCount = count
      else root.allTaskCount = count
    } catch (e) {
      // Keep the last known count when a background count request fails.
    }
  }

  Process {
    id: todayCountProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyViewCount("today", text)
    }
  }

  Process {
    id: tomorrowCountProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyViewCount("tomorrow", text)
    }
  }

  Process {
    id: inboxCountProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyViewCount("inbox", text)
    }
  }

  Process {
    id: allCountProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyViewCount("all", text)
    }
  }

  Process {
    id: createProc
    stderr: StdioCollector {
      id: createErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.quickAddSubmitting = false
      if (exitCode === 0) {
        root.quickAddText = ""
        quickAddField.text = ""
        root.refresh()
      } else {
        root.errorText = Model.errorMessageForExit(exitCode, createErr.text)
      }
    }
  }

  Process {
    id: actionProc
    // Which task this run is closing — lets the failure path undo the
    // optimistic strike-through for exactly that task, not whichever one
    // happens to be at the front of a since-mutated queue/list.
    property string pendingTaskId: ""
    stderr: StdioCollector {
      id: actionErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.errorText = Model.errorMessageForExit(exitCode, actionErr.text)
        // The close didn't actually happen — don't let it still get
        // removed 700ms later as if it had. Refresh right away too, since
        // there's no completion animation to protect on a failure.
        root.undoCompleting(actionProc.pendingTaskId)
        root.refresh()
      }
      // On success, flushCompletedRemovals() (fired by the existing 700ms
      // timer) is what triggers the refresh — see its own comment for why.
      Qt.callLater(root.processActionQueue)
    }
  }

  Process {
    id: deleteProc
    stderr: StdioCollector {
      id: deleteErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.errorText = Model.errorMessageForExit(exitCode, deleteErr.text)
      // Delete's optimistic removal is immediate and permanent (no delayed
      // animation like complete has), so refreshing right away either way
      // is safe — reconciles a failed delete's local removal on failure,
      // confirms server-truth on success.
      root.refresh()
    }
  }

  Process {
    id: editProc
    stderr: StdioCollector {
      id: editErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.errorText = Model.errorMessageForExit(exitCode, editErr.text)
      root.refresh()
    }
  }

  Process {
    id: dueProc
    stderr: StdioCollector {
      id: dueErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.errorText = Model.errorMessageForExit(exitCode, dueErr.text)
      root.refresh()
    }
  }

  Process {
    id: openUrlProc
  }

  Timer {
    id: completionRemovalTimer
    interval: 700
    repeat: false
    onTriggered: root.flushCompletedRemovals()
  }

  Process {
    id: keybindProc
    property string pendingApply: ""
    stderr: StdioCollector {
      id: keybindErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.keybindCombo = keybindProc.pendingApply
        root.keybindApplyStatus = ""
        root.keybindApplyError = ""
        root.recordingKeybind = false
        root.pendingKeybindCombo = ""
        persistSettings()
      } else {
        root.keybindApplyStatus = "error"
        root.keybindApplyError = (keybindErr.text || "").trim() || "Impossible d’appliquer le raccourci."
      }
    }
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadSettingsFromText(text())
    onLoadFailed: root.loadSettingsFromText("")
  }

  // Two polling timers, mutually exclusive by `root.opened` so they never
  // both drive a refresh at once (they used to overlap: the 15-minute one
  // ran unconditionally, the 5-minute one only gated on `opened` — meaning
  // while the panel was open, both were live and could each independently
  // trigger a fetch). Background poll keeps the bar's count fresh — and
  // fresh only, no urgency — while the panel's closed and nobody's looking
  // at the list; open poll is the only one that matters while someone
  // actually has the panel up, so it's the only one that gets tightened.
  // Neither is "aggressive" — every actual refresh (add/complete/edit/
  // delete/view-switch) already happens immediately via refresh() itself;
  // these two only cover the gaps between user actions.
  Timer {
    id: backgroundRefreshTimer
    interval: 20 * 60 * 1000
    running: !root.opened && root.apiToken !== ""
    repeat: true
    onTriggered: { root.refresh(); root.refreshBarCount() }
  }

  Timer {
    id: openRefreshTimer
    interval: 2 * 60 * 1000
    running: root.opened && root.apiToken !== ""
    repeat: true
    onTriggered: { root.refresh(); root.refreshBarCount() }
  }

  // ---- Settings' keyboard-navigable controls. Plain Button/PanelActionButton
  //      with focusable:true still won't cycle via Tab here: once a button
  //      genuinely holds Qt's activeFocus, PanelKeyCatcher's
  //      Keys.priority: BeforeItem interception stops applying to it (that
  //      mechanism only intercepts for whichever item currently holds
  //      activeFocus — normally keyCatcher itself, never a focused
  //      descendant). Each control has to catch Tab/Backtab itself, same as
  //      tokenField/filterField already do, so this wraps that once instead
  //      of repeating it on every button.
  component NavButton: Button {
    focusable: true
    activeFocusOnTab: false
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Tab) { root.moveSettingsFocus(1); event.accepted = true }
      else if (event.key === Qt.Key_Backtab) { root.moveSettingsFocus(-1); event.accepted = true }
    }
  }

  component NavActionButton: PanelActionButton {
    focusable: true
    activeFocusOnTab: false
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Tab) { root.moveSettingsFocus(1); event.accepted = true }
      else if (event.key === Qt.Key_Backtab) { root.moveSettingsFocus(-1); event.accepted = true }
    }
  }

  // ---- One task row: complete button + content + due label. ----------
  component TaskRow: Item {
    id: row
    required property var task
    // Not named "index" — a delegate instantiating this component also
    // needs its own ListView-injected "required property int index", and
    // QML won't let two same-named required properties coexist between a
    // component and the instance declaring it (matches the built-in
    // bluetooth panel's DeviceRow/rowIndex convention).
    required property int rowIndex
    property bool hasCursor: false

    readonly property bool overdue: Model.taskIsOverdue(task)
    readonly property string dueLabel: Model.taskDueLabel(task)
    readonly property bool completing: task ? root.completingTaskIds.indexOf(task.id) !== -1 : false
    readonly property bool editing: root.editingTaskIndex === rowIndex
    // Todoist priority colors (API priority 4 = p1, the most urgent, down
    // to 1 = p4/no priority). Fixed, theme-independent hex — these carry a
    // specific meaning ("this is p1") the same way in every theme, unlike
    // an accent color that's meant to shift with the user's theme.
    readonly property color textColor: {
      if (!task) return root.contentForeground
      if (task.priority === 4) return "#eb5757"
      if (task.priority === 3) return "#f2b84b"
      if (task.priority === 2) return "#4a90d2"
      return root.contentForeground
    }

    // editField.text isn't kept bound to root.editDraft once the user has
    // typed in it once (assigning to a QML property severs a declarative
    // binding on it) — re-sync explicitly whenever this row starts editing.
    onEditingChanged: {
      if (editing) {
        editField.text = root.editDraft
        Qt.callLater(function() {
          if (row.editing) { editField.forceActiveFocus(); editField.selectAll() }
        })
      }
    }

    height: Math.max(checkBtn.height, textColumn.implicitHeight) + Style.spacing.sm * 2

    Rectangle {
      anchors.fill: parent
      anchors.margins: -Style.spacing.xs
      radius: Style.cornerRadius
      visible: row.hasCursor
      color: Style.hoverFillFor(root.contentForeground, Color.accent)
    }

    PanelActionButton {
      id: checkBtn
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.topMargin: Style.spacing.sm
      iconText: row.completing ? "●" : "○"
      tooltipText: "Marquer comme terminée (Espace)"
      foreground: row.textColor
      enabled: !row.completing
      onClicked: root.requestComplete(row.task ? row.task.id : "")
    }

    Column {
      id: textColumn
      anchors.left: checkBtn.right
      anchors.leftMargin: Style.spacing.sm
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: Style.spacing.sm
      spacing: 2

      Text {
        visible: !row.editing
        height: visible ? implicitHeight : 0
        width: parent.width
        text: row.task ? row.task.content : ""
        opacity: row.completing ? 0.5 : 1.0
        font.strikeout: row.completing
        color: row.textColor
        wrapMode: Text.WordWrap
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.body
      }

      TextField {
        id: editField
        visible: row.editing
        height: visible ? implicitHeight : 0
        width: parent.width
        onTextChanged: if (row.editing) root.editDraft = text
        onAccepted: root.commitEditTask()
        Keys.onEscapePressed: root.cancelEditTask()
      }

      Text {
        visible: row.dueLabel !== "" && !row.editing
        height: visible ? implicitHeight : 0
        width: parent.width
        text: row.dueLabel
        color: row.overdue ? Color.urgent : Qt.darker(root.contentForeground, 1.5)
        wrapMode: Text.WordWrap
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // ---- Chrome ----------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    // Drops right below the bar icon, not centered on the whole bar.
    centerOnBar: false
    focusTarget: keyCatcher
    // Fixed size (Settings → Advanced), not derived from mainColumn's
    // implicitHeight — content that doesn't fit scrolls inside the
    // Flickable below rather than resizing the window around it.
    contentWidth: panel.fittedContentWidth(root.panelWidth)
    contentHeight: panel.fittedContentHeight(root.panelHeight)
    // KeyboardPanel's own default (popup-padding, 14px) reads as cramped
    // right next to a bordered control like the quick-add field — its own
    // border sitting close to the card's border reads tighter than the same
    // gap next to plain text. A bit more room on all four sides fixes it.
    padding: Style.space(20)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      clip: true
      blocked: tokenField.activeFocus || filterField.activeFocus || quickAddField.activeFocus || root.recordingKeybind || root.editingTaskIndex !== -1 || root.helpOpen
      // First Escape backs out of Settings to the task list; a second one
      // (now that settingsView is false) closes the panel.
      onCloseRequested: {
        if (root.settingsView) root.settingsView = false
        else root.close()
      }
      // Tab walks the Settings focus chain while Settings is showing, and
      // cycles the quick-view tabs otherwise.
      onTabRequested: function(direction) {
        if (root.settingsView) root.moveSettingsFocus(direction)
        else root.cycleQuickView(direction)
      }
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          if (!root.settingsView) root.cycleQuickView(dx)
          return
        }
        if (dy === 0) return
        if (root.settingsView) root.moveSettingsFocus(dy)
        else root.moveTaskCursor(dy)
      }
      // Enter fires returnRequested then activateRequested, back to back,
      // for the same keypress — returnRequested opens the task in the
      // browser and flags suppressNextActivate so the activateRequested
      // that immediately follows doesn't also complete it. Space fires only
      // activateRequested, so it still completes on its own.
      onReturnRequested: {
        if (root.settingsView) return
        root.suppressNextActivate = true
        root.openSelectedTaskInBrowser()
      }
      // PanelKeyCatcher intercepts Enter/Space before a focused Button ever
      // sees them (Keys.priority: BeforeItem consumes the event first), so
      // Settings has to explicitly re-trigger whichever control has focus.
      // TextFields aren't handled here — they're covered by the `blocked`
      // guard above instead, which lets Enter reach their own onAccepted.
      onActivateRequested: {
        if (root.suppressNextActivate) { root.suppressNextActivate = false; return }
        if (root.settingsView) { root.activateFocusedSettingsControl(); return }
        root.activateSelectedTask()
      }
      // "x" is this shell's established delete shortcut (see
      // Ui/PanelKeyCatcher.qml) — the physical Delete key has no printable
      // event.text so PanelKeyCatcher never sees it as a distinct key.
      onDeleteRequested: {
        if (!root.settingsView) root.requestDeleteSelected()
      }
      onTextKey: function(t) {
        if (t === "?") { root.helpOpen = !root.helpOpen; return }
        if (t === "r" || t === "R") { root.refresh(); return }
        if (t === "p" || t === "P") { root.settingsView = !root.settingsView; return }
        if (root.settingsView) {
          if (t === "t" || t === "T") root.openTodoistWebsite()
          return
        }
        if (t === "q" || t === "Q") { quickAddField.forceActiveFocus(); return }
        if (t === "e" || t === "E") { root.startEditSelectedTask(); return }
        if (t === "a" || t === "A") {
          if (root.selectedTask()) root.setSelectedTaskDue("today")
          else root.selectQuickView("today")
          return
        }
        if (t === "d" || t === "D") {
          if (root.selectedTask()) root.setSelectedTaskDue("tomorrow")
          else root.selectQuickView("tomorrow")
          return
        }
        if (t === "i" || t === "I") {
          if (root.selectedTask()) root.setSelectedTaskDue(null)
          else root.selectQuickView("inbox")
          return
        }
        if (t === "t" || t === "T") root.selectQuickView("all")
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: mainColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: mainColumn
          width: parent.width
          // Matches the Wi-Fi panel's own flat top-level rhythm (Style
          // .space(12) for every section gap, not the smaller semantic
          // "lg" token) — that panel's spacing was the reference point for
          // fixing this one's cramped feel.
          spacing: Style.space(12)

          // ---- Header ---------------------------------------------------
          // Height comes from titleRow alone (not a Math.max of both
          // children) and actionsRow centers on that sibling directly,
          // rather than on the parent's own height — sizing a parent from a
          // child while anchoring that child back to the parent's center is
          // a classic Qt Quick binding-loop trap.
          Item {
            width: parent.width
            height: titleRow.implicitHeight

            // Icon beside the title, matching the Wi-Fi panel's own header.
            Row {
              id: titleRow
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.right: actionsRow.left
              anchors.rightMargin: Style.spacing.sm
              // Matches the Wi-Fi panel's own icon-to-title gap
              // (heroIcon → heroLabels leftMargin) literally — Style
              // .spacing.xs (3px) read as barely any margin at all next to
              // the now-bigger 24px icon.
              spacing: Style.space(14)

              TodoistIcon {
                id: headerIcon
                iconSize: Style.font.display
                color: root.contentForeground
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                width: titleRow.width - headerIcon.width - titleRow.spacing

                Text {
                  text: "Todoist"
                  font.bold: true
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.title
                  color: root.contentForeground
                }

              }
            }

            Row {
              id: actionsRow
              anchors.right: parent.right
              anchors.verticalCenter: titleRow.verticalCenter
              spacing: Style.spacing.sm

              PanelActionButton {
                iconText: root.settingsView ? "✕" : "󰒓"
                tooltipText: root.settingsView ? "Fermer les réglages (Échap)" : "Réglages (p)"
                foreground: root.contentForeground
                onClicked: root.settingsView = !root.settingsView
              }
            }
          }

          PanelSeparator {
            foreground: root.contentForeground
          }

          // ---- Settings view ---------------------------------------------
          Column {
            id: settingsColumn
            width: parent.width
            visible: root.settingsView
            height: visible ? implicitHeight : 0
            spacing: Style.spacing.md

            PanelSectionHeader {
              text: "COMPTE"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
            }

            Text {
              width: parent.width
              text: "Collez votre jeton API personnel Todoist — Todoist → Réglages → Intégrations → Développeur."
              wrapMode: Text.WordWrap
              color: Qt.darker(root.contentForeground, 1.3)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              id: tokenField
              width: parent.width
              password: true
              activeFocusOnTab: false
              placeholderText: root.apiToken !== "" ? "Jeton enregistré — collez-en un nouveau pour le remplacer" : "Jeton API"
              text: root.tokenDraft
              onTextChanged: root.tokenDraft = text
              onAccepted: root.saveToken()
              // Tab/Backtab need the raw Keys.onPressed form, not the
              // Keys.onTabPressed/onBacktabPressed convenience handlers —
              // Qt Quick's TextInput has its own special native handling for
              // the Tab key that runs ahead of those convenience signals, so
              // they never actually fire here. Escape works fine as a
              // convenience handler (same gap quickAddField had: this field
              // having focus blocks PanelKeyCatcher, so Escape needs its own
              // handler here rather than falling through to onCloseRequested).
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Tab) { root.moveSettingsFocus(1); event.accepted = true }
                else if (event.key === Qt.Key_Backtab) { root.moveSettingsFocus(-1); event.accepted = true }
              }
              Keys.onEscapePressed: root.settingsView = false
            }

            Row {
              spacing: Style.spacing.sm

              NavButton {
                id: saveTokenButton
                text: "Enregistrer le jeton"
                enabled: root.tokenDraft.trim() !== ""
                onClicked: root.saveToken()
              }

              NavButton {
                id: removeTokenButton
                text: "Supprimer le jeton"
                visible: root.apiToken !== ""
                onClicked: root.clearToken()
              }
            }

            PanelSeparator {
              foreground: root.contentForeground
            }

            PanelSectionHeader {
              text: "FILTRE PAR DÉFAUT"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
            }

            Text {
              width: parent.width
              text: "Syntaxe des filtres Todoist (ex. « today | overdue », « #Work & !subtask ») — utilisée comme vue « personnalisée »."
              wrapMode: Text.WordWrap
              color: Qt.darker(root.contentForeground, 1.3)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Row {
              width: parent.width
              spacing: Style.spacing.sm

              TextField {
                id: filterField
                width: parent.width - filterApplyButton.width - Style.spacing.sm
                activeFocusOnTab: false
                text: root.filterQuery
                onAccepted: root.applyFilter(text)
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Tab) { root.moveSettingsFocus(1); event.accepted = true }
                  else if (event.key === Qt.Key_Backtab) { root.moveSettingsFocus(-1); event.accepted = true }
                }
                Keys.onEscapePressed: root.settingsView = false
              }

              NavButton {
                id: filterApplyButton
                text: "Appliquer"
                onClicked: root.applyFilter(filterField.text)
              }
            }

            PanelSeparator {
              foreground: root.contentForeground
            }

            PanelSectionHeader {
              text: "COMPTEUR DE LA BARRE"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
            }

            Text {
              width: parent.width
              text: "Afficher le nombre de tâches sur l’icône de la barre, indépendamment de l’onglet affiché dans la fenêtre."
              wrapMode: Text.WordWrap
              color: Qt.darker(root.contentForeground, 1.3)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            // Explicit even cellWidth (not natural button width) — a plain
            // Row of 4 labeled buttons has already overflowed this panel at
            // narrow widths once before (General/Advanced, v1.10); this is
            // the same fixed-cell technique the Wi-Fi panel's own DNS
            // Provider pill row uses to guarantee it never does.
            Row {
              id: barCountRow
              width: parent.width
              clip: true
              spacing: Style.spacing.sm

              readonly property real cellWidth: (width - spacing * 3) / 4

              NavButton {
                id: barCountHideButton
                width: barCountRow.cellWidth
                text: "Masquer"
                selected: root.barCountMode === "hide"
                onClicked: root.setBarCountMode("hide")
              }

              NavButton {
                id: barCountTodayButton
                width: barCountRow.cellWidth
                text: "Auj"
                selected: root.barCountMode === "today"
                onClicked: root.setBarCountMode("today")
              }

              NavButton {
                id: barCountInboxButton
                width: barCountRow.cellWidth
                text: "Inbox"
                selected: root.barCountMode === "inbox"
                onClicked: root.setBarCountMode("inbox")
              }

              NavButton {
                id: barCountAllButton
                width: barCountRow.cellWidth
                text: "Tout"
                selected: root.barCountMode === "all"
                onClicked: root.setBarCountMode("all")
              }
            }

            PanelSeparator {
              foreground: root.contentForeground
            }

            Column {
              width: parent.width
              spacing: Style.spacing.sm

              PanelSectionHeader {
                text: "RACCOURCI CLAVIER"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
              }

              Text {
                width: parent.width
                text: root.keybindCombo !== "" ? ("Actuel : " + root.keybindCombo) : "Aucun raccourci défini."
                color: Qt.darker(root.contentForeground, 1.3)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Row {
                visible: !root.recordingKeybind
                spacing: Style.spacing.sm

                NavButton {
                  id: keybindDefaultButton
                  text: "Ctrl+Super+Y"
                  selected: root.keybindCombo === "CTRL + SUPER + Y"
                  enabled: root.keybindApplyStatus !== "applying" && root.keybindCombo !== "CTRL + SUPER + Y"
                  onClicked: root.applyKeybindCombo("CTRL + SUPER + Y")
                }

                NavButton {
                  id: recordCustomButton
                  text: "Enregistrer un raccourci…"
                  enabled: root.keybindApplyStatus !== "applying"
                  onClicked: root.startRecordingKeybind()
                }

                NavButton {
                  id: removeKeybindButton
                  text: "Supprimer"
                  visible: root.keybindCombo !== ""
                  enabled: root.keybindApplyStatus !== "applying"
                  onClicked: root.removeKeybindCombo()
                }
              }

              Column {
                visible: root.recordingKeybind
                width: parent.width
                spacing: Style.spacing.xs

                Rectangle {
                  width: parent.width
                  height: Style.spacing.controlHeight + Style.spacing.sm * 2
                  radius: Style.cornerRadius
                  color: Style.hoverFillFor(root.contentForeground, Color.accent)
                  border.width: 1
                  border.color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.4)

                  Text {
                    anchors.centerIn: parent
                    text: root.pendingKeybindCombo !== "" ? root.pendingKeybindCombo : "Appuyez sur un raccourci…"
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                  }

                  Item {
                    id: keybindRecorder
                    anchors.fill: parent
                    focus: root.recordingKeybind
                    Keys.onPressed: function(event) { root.handleKeybindRecordKey(event) }
                  }
                }

                Text {
                  width: parent.width
                  text: root.keybindRecordError !== "" ? root.keybindRecordError : "Maintenez les touches modificatrices et appuyez sur une touche. Échap annule."
                  color: root.keybindRecordError !== "" ? Color.urgent : Qt.darker(root.contentForeground, 1.4)
                  wrapMode: Text.WordWrap
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }

                Row {
                  spacing: Style.spacing.sm

                  NavButton {
                    id: applyKeybindButton
                    text: "Appliquer"
                    enabled: root.pendingKeybindCombo !== "" && root.keybindApplyStatus !== "applying"
                    onClicked: root.applyKeybindCombo(root.pendingKeybindCombo)
                  }

                  NavButton {
                    id: cancelKeybindButton
                    text: "Annuler"
                    onClicked: root.cancelRecordingKeybind()
                  }
                }
              }

              Text {
                visible: root.keybindApplyStatus === "error"
                width: parent.width
                text: root.keybindApplyError
                color: Color.urgent
                wrapMode: Text.WordWrap
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                width: parent.width
                text: "S’applique immédiatement en modifiant ~/.config/hypr/bindings.lua (sauvegarde préalable) et en rechargeant Hyprland. Toute erreur annule automatiquement la modification."
                color: Qt.darker(root.contentForeground, 1.5)
                wrapMode: Text.WordWrap
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }

            PanelSeparator {
              foreground: root.contentForeground
            }

            Column {
              width: parent.width
              spacing: Style.spacing.sm

              PanelSectionHeader {
                text: "GÉNÉRAL"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
              }

              Column {
                width: parent.width
                spacing: Style.spacing.xs

                NavButton {
                  id: refreshNowButton
                  width: parent.width
                  leftAlign: true
                  bordered: true
                  text: root.loading ? "Actualisation…" : "Actualiser maintenant (r)"
                  enabled: root.apiToken !== "" && !root.loading
                  onClicked: root.refresh()
                }

                NavButton {
                  id: openTodoistButton
                  width: parent.width
                  leftAlign: true
                  bordered: true
                  text: "Ouvrir Todoist (t)"
                  onClicked: root.openTodoistWebsite()
                }

                NavButton {
                  id: keyboardShortcutsButton
                  width: parent.width
                  leftAlign: true
                  bordered: true
                  text: "Raccourcis clavier (?)"
                  onClicked: root.helpOpen = true
                }
              }
            }

            PanelSeparator {
              foreground: root.contentForeground
            }

            Column {
              width: parent.width
              spacing: Style.spacing.sm

              PanelSectionHeader {
                text: "AVANCÉ"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
              }

              Text {
                width: parent.width
                text: "Taille de la fenêtre — fixe quel que soit le nombre de tâches ; le contenu défile au lieu de redimensionner le panneau."
                wrapMode: Text.WordWrap
                color: Qt.darker(root.contentForeground, 1.3)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Column {
                width: parent.width
                spacing: Style.spacing.xs

                Item {
                  width: parent.width
                  height: Math.max(widthLabelText.implicitHeight, widthButtonsRow.implicitHeight) + Style.spacing.sm * 2

                  BorderSurface {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: "transparent"
                    borderSpec: Border.controlSpec("normal", root.contentForeground, Color.accent)
                  }

                  Text {
                    id: widthLabelText
                    text: "Largeur  " + root.panelWidth + " px"
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    anchors.left: parent.left
                    anchors.leftMargin: Style.spacing.sm
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Row {
                    id: widthButtonsRow
                    spacing: Style.spacing.xs
                    anchors.right: parent.right
                    anchors.rightMargin: Style.spacing.sm
                    anchors.verticalCenter: parent.verticalCenter

                    NavActionButton {
                      id: widthMinusButton
                      iconText: "−"
                      foreground: root.contentForeground
                      onClicked: root.setPanelWidth(root.panelWidth - 20)
                    }

                    NavActionButton {
                      id: widthPlusButton
                      iconText: "+"
                      foreground: root.contentForeground
                      onClicked: root.setPanelWidth(root.panelWidth + 20)
                    }
                  }
                }

                Item {
                  width: parent.width
                  height: Math.max(heightLabelText.implicitHeight, heightButtonsRow.implicitHeight) + Style.spacing.sm * 2

                  BorderSurface {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: "transparent"
                    borderSpec: Border.controlSpec("normal", root.contentForeground, Color.accent)
                  }

                  Text {
                    id: heightLabelText
                    text: "Hauteur  " + root.panelHeight + " px"
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    anchors.left: parent.left
                    anchors.leftMargin: Style.spacing.sm
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Row {
                    id: heightButtonsRow
                    spacing: Style.spacing.xs
                    anchors.right: parent.right
                    anchors.rightMargin: Style.spacing.sm
                    anchors.verticalCenter: parent.verticalCenter

                    NavActionButton {
                      id: heightMinusButton
                      iconText: "−"
                      foreground: root.contentForeground
                      onClicked: root.setPanelHeight(root.panelHeight - 20)
                    }

                    NavActionButton {
                      id: heightPlusButton
                      iconText: "+"
                      foreground: root.contentForeground
                      onClicked: root.setPanelHeight(root.panelHeight + 20)
                    }
                  }
                }
              }
            }
          }

          // ---- Task list view ---------------------------------------------
            Column {
              id: taskColumn
              width: parent.width
              visible: !root.settingsView
              height: visible ? scroll.height : 0
              spacing: Style.spacing.md

            Row {
              id: quickAddRow
              width: parent.width
              clip: true
              spacing: Style.spacing.sm

              TextField {
                id: quickAddField
                width: parent.width
                enabled: root.apiToken !== ""
                font.pixelSize: Style.font.caption
                placeholderText: "Ajouter une tâche… (p1, #Projet, demain à 17 h)"
                text: root.quickAddText
                onTextChanged: root.quickAddText = text
                onAccepted: root.submitQuickAdd()
                // Escape here just leaves the field (back to normal keyboard
                // nav) rather than falling through to the panel's own
                // Escape, which would otherwise do nothing while blocked.
                Keys.onEscapePressed: keyCatcher.forceActiveFocus()
              }
            }

            // Equal-width view buttons keep the tabs aligned with the
            // full-width quick-add field above. Tab/Shift+Tab still cycles
            // views through PanelKeyCatcher rather than Qt focus traversal.
            Row {
              id: quickViewRow
              width: parent.width
              visible: root.apiToken !== ""
              height: visible ? implicitHeight : 0
              clip: true
              spacing: Style.spacing.xs
              readonly property real cellWidth: (width - spacing * 3) / 4

              Button {
                width: quickViewRow.cellWidth
                text: "Auj (" + root.countForView("today") + ")"
                selected: root.quickView === "today"
                bordered: true
                focusable: false
                fontSize: Style.font.caption
                onClicked: root.selectQuickView("today")
              }
              Button {
                width: quickViewRow.cellWidth
                text: "Demain (" + root.countForView("tomorrow") + ")"
                selected: root.quickView === "tomorrow"
                bordered: true
                focusable: false
                fontSize: Style.font.caption
                onClicked: root.selectQuickView("tomorrow")
              }
              Button {
                width: quickViewRow.cellWidth
                text: "Inbox (" + root.countForView("inbox") + ")"
                selected: root.quickView === "inbox"
                bordered: true
                focusable: false
                fontSize: Style.font.caption
                onClicked: root.selectQuickView("inbox")
              }
              Button {
                width: quickViewRow.cellWidth
                text: "Tout (" + root.countForView("all") + ")"
                selected: root.quickView === "all"
                bordered: true
                focusable: false
                fontSize: Style.font.caption
                onClicked: root.selectQuickView("all")
              }
            }

            PanelSeparator {
              id: taskListSeparator
              foreground: root.contentForeground
            }

            ListView {
              id: taskListView
              width: parent.width
              height: root.tasks.length > 0
                ? Math.max(0, taskColumn.height - quickAddRow.implicitHeight
                    - quickViewRow.implicitHeight - taskListSeparator.implicitHeight
                    - taskColumn.spacing * 3)
                : 0
              spacing: Style.spacing.sm
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              interactive: contentHeight > height
              model: root.tasks
              currentIndex: root.selectedTaskIndex

              delegate: Item {
                id: delegateItem
                required property var modelData
                required property int index
                width: taskListView.width
                height: delegateColumn.implicitHeight

                Column {
                  id: delegateColumn
                  width: parent.width
                  spacing: Style.spacing.sm

                  TaskRow {
                    id: delegateRow
                    width: parent.width
                    task: delegateItem.modelData
                    rowIndex: delegateItem.index
                    hasCursor: root.taskCursorActive && delegateItem.index === root.selectedTaskIndex
                  }
                }
              }
            }

            Text {
              // Only shown for the initial fetch on an empty list — a
              // background/periodic refresh of an already-populated list
              // stays quiet rather than growing the panel with a redundant
              // "Loading…" row underneath tasks that are already showing.
              visible: root.loading && root.tasks.length === 0
              height: visible ? implicitHeight : 0
              width: parent.width
              text: "Chargement…"
              color: Qt.darker(root.contentForeground, 1.3)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              visible: !root.loading && root.tasks.length === 0 && root.errorText === "" && root.apiToken !== ""
              height: visible ? implicitHeight : 0
              width: parent.width
              text: root.emptyStateMessage
              color: Qt.darker(root.contentForeground, 1.3)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              visible: root.errorText !== ""
              height: visible ? implicitHeight : 0
              width: parent.width
              text: root.errorText
              color: Color.urgent
              wrapMode: Text.WordWrap
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }
      }

      // Shortcuts help, toggled by "?" or the header's "?" button. Declared
      // last so it paints above everything else.
      Item {
        id: helpOverlay
        anchors.fill: parent
        visible: root.helpOpen

        Rectangle {
          anchors.fill: parent
          color: Util.alpha(Color.background, 0.75)

          MouseArea {
            anchors.fill: parent
            onClicked: root.helpOpen = false
          }

          BorderSurface {
            id: helpCard
            anchors.centerIn: parent
            // Content insets (border + padding) aren't applied to children
            // automatically — they're exposed as contentXInset properties
            // that have to be applied by hand, same as Ui/ConfirmDialog.qml
            // does. Skipping that the first time round is what pushed text
            // right up against (and past) the border.
            width: Math.min(parent.width - Style.space(24), Style.space(340))
            height: Math.min(parent.height - Style.space(24),
              helpCard.contentTopInset + helpCard.contentBottomInset + helpColumn.implicitHeight + Style.space(8))
            color: Color.popups.background
            borderSpec: Border.flat(Color.accent, Style.normalBorderWidth)
            radius: Style.cornerRadius
            padding: Style.space(16)

            MouseArea {
              anchors.fill: parent
              onClicked: {}
            }

            Item {
              anchors.fill: parent
              anchors.topMargin: helpCard.contentTopInset
              anchors.rightMargin: helpCard.contentRightInset
              anchors.bottomMargin: helpCard.contentBottomInset
              anchors.leftMargin: helpCard.contentLeftInset

              Flickable {
                anchors.fill: parent
                contentWidth: width
                contentHeight: helpColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height

                Column {
                  id: helpColumn
                  width: parent.width
                  spacing: Style.spacing.sm

                  Text {
                    text: "Raccourcis clavier"
                    font.bold: true
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.title
                  }

                  Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    text: "Tab / Maj+Tab — parcourir Auj → Demain → Inbox → Tout\n"
                      + "a / d / i / t — accéder à Auj / Demain / Inbox / Tout\n"
                      + "a / d / i (tâche sélectionnée) — échéance aujourd’hui / demain / aucune\n"
                      + "p — afficher/masquer les réglages\n"
                      + "↑/↓ ou k/j — déplacer la sélection\n"
                      + "Entrée — ouvrir la tâche dans Todoist\n"
                      + "Espace — marquer comme terminée\n"
                      + "e — modifier le titre\n"
                      + "x — supprimer la tâche\n"
                      + "q — accéder à Ajouter une tâche\n"
                      + "r — actualiser\n"
                      + "Échap — revenir / fermer\n"
                      + "? — afficher/masquer cette aide\n"
                      + "Dans les réglages, t ouvre Todoist dans le navigateur"
                  }
                }
              }
            }
          }

          Item {
            anchors.fill: parent
            focus: root.helpOpen
            Keys.onEscapePressed: root.helpOpen = false
            Keys.onPressed: function(event) {
              if (event.text === "?") { root.helpOpen = false; event.accepted = true }
            }
          }
        }
      }
    }
  }
}
