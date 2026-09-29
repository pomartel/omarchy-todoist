import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as C
import "omatasks/ui" as Oma
import "omatasks/Model.js" as OmaModel
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "EditParser.js" as EditParser

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
  // "today" | "upcoming" | "undated" — the three quick views.
  property string quickView: "today"
  property bool settingsLoaded: false
  property bool settingsView: true
  // Gives keyboard nav a sensible starting point regardless of how Settings
  // was entered/left (gear click, "p", or the initial open-with-no-token
  // case) — without this, Tab/arrows in a freshly opened Settings would
  // have nothing focused to step from.
  onSettingsViewChanged: {
    cancelTaskDrag()
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

  property string dragTaskId: ""
  property point dragPoint: Qt.point(0, 0)
  property var dragDrop: null
  readonly property bool dragging: dragTaskId !== ""
  onOpenedChanged: if (!opened) cancelTaskDrag()

  property var tasks: []
  readonly property int taskCount: tasks.length
  onTasksChanged: {
    cancelTaskDrag()
    if (root.selectedTaskIndex >= root.tasks.length) root.selectedTaskIndex = root.tasks.length - 1
  }

  // Keyboard cursor over the task list. -1 = nothing selected yet;
  // taskCursorActive gates the row highlight so it only shows up once the
  // user has actually pressed an arrow key, not on every open.
  property int selectedTaskIndex: -1
  property bool taskCursorActive: false

  // Tasks remain struck through while queued/in flight, and briefly after
  // server confirmation. Only confirmed completions enter pendingRemovalIds.
  property var completingTaskIds: []
  property var pendingRemovalIds: []

  // Inline editing follows the task ID across refreshes and sorting.
  property string editingTaskId: ""
  property string editDraft: ""

  property bool helpOpen: false
  property bool composerOpen: false
  property var detailTask: null
  property bool detailEdit: false
  property bool richMetadataReady: false
  property var taskMetadata: ({})
  onEditingTaskIdChanged: {
    if (!editingTaskId) return
    var task = root.allTasks.find(function(t) { return t.id === root.editingTaskId })
    if (task) showTaskDetails(task, true)
  }

  QtObject {
    id: omaService
    readonly property var tasks: root.allTasks
    readonly property var projects: root.allProjects
    readonly property var sections: root.taskMetadata.sections || []
    readonly property var labels: root.taskMetadata.labels || []
    readonly property var collaborators: root.taskMetadata.collaborators || []
    readonly property var reminders: root.taskMetadata.reminders || []
    readonly property var completedInfo: root.taskMetadata.completed_info || []
    readonly property var user: root.taskMetadata.user || ({})
    readonly property var projectMap: OmaModel.byId(projects)
    readonly property var sectionMap: OmaModel.byId(sections)
    readonly property date now: new Date(root.lastSyncedAt || Date.now())
    readonly property bool saving: root.actionBusy || root.actionQueue.length > 0
    readonly property string error: root.actionError
    signal taskAdded()
    signal taskUpdated(string taskId)
    signal taskCompleted(string taskId)
    signal operationFailed(string message)
    function addTask(text, requestId) {
      if (saving || !root.apiToken) return false
      root.enqueueAction("richCreate", "__composer__", { body: {text: text, auto_reminder: true}, requestId: requestId })
      return true
    }
    function updateTask(taskId, commands) {
      if (saving || !root.apiToken || root.taskIsPending(taskId)) return false
      root.enqueueAction("richUpdate", taskId, {commands: commands, sync_token: "*", resource_types: []})
      return true
    }
    function completeTask(task) {
      if (saving || !root.apiToken || root.taskIsPending(task.id)) return false
      root.requestComplete(task.id)
      return true
    }
  }

  // Compatibility with existing quick-add shortcuts: focus opens the composer.
  QtObject {
    id: quickAddField
    property string text: ""
    readonly property bool activeFocus: root.composerOpen
    function forceActiveFocus() { root.openComposer() }
  }

  // Fixed popup size, user-adjustable from Settings → Advanced. Deliberately
  // NOT derived from content (mainColumn.implicitHeight) — letting the
  // window grow/shrink with task count is what was causing content to
  // overflow past the card; a fixed size scrolls instead.
  property int panelWidth: 340
  property int panelHeight: 480

  property bool loading: false
  property string fetchError: ""
  property string projectError: ""
  property string actionError: ""
  property string settingsError: ""
  readonly property string errorText: [settingsError, actionError, fetchError, projectError].filter(function(s) { return s !== "" }).join("\n")
  property int accountGeneration: 0
  property int dataRevision: 0
  property var allTasks: []
  property var allProjects: []
  property real projectsSyncedAt: 0
  property bool projectsLoading: false
  onAllTasksChanged: if (allTasks.length && stateReady) refreshProjects()
  property var pendingTaskIds: []
  property string pendingSettings: ""
  property bool stateReady: false
  // Set when refresh() is called while a fetch is already in flight —
  // listProc's own exit handler starts one more fetch once it sees this,
  // so a triggering action never has its refresh silently dropped.
  property bool refreshPending: false
  // Timestamp of the last fully fetched snapshot; 0 means never synced.
  property real lastSyncedAt: 0

  // ---- Bar count (Settings → Bar Count). A fixed choice independent of
  //      whichever tab the popup itself is showing — "hide" is the shipped
  //      default (icon-only bar pill). Kept separate from `quickView` on
  //      purpose: switching tabs while the popup is open must not change
  //      what the bar badge shows.
  property string barCountMode: "hide"
  property int barCountValue: 0
  property int todayTaskCount: 0
  property int upcomingTaskCount: 0
  property int undatedTaskCount: 0
  property int allTaskCount: 0

  property string tokenDraft: ""
  property string quickAddText: ""
  property bool quickAddSubmitting: false
  property var actionQueue: []
  property bool actionBusy: false

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  // Preserve the theme's foreground hue in both light and dark themes.
  // Size and spacing distinguish secondary text; avoid heavy darkening.
  readonly property color secondaryForeground: Util.alpha(root.contentForeground, 0.85)
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string emptyStateMessage: root.quickView === "undated" ? "Aucune tâche sans date."
    : root.quickView === "upcoming" ? "Rien à faire dans les six prochains jours."
    : "Rien à faire. Tout est en ordre."

  readonly property string barCountModeLabel: root.barCountMode === "today" ? "aujourd’hui"
    : root.barCountMode === "undated" ? "sans date"
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
    initStateProc.running = true
  }

  function loadSettingsFromText(text) {
    if (root.settingsLoaded) return
    var parsed = {}
    try {
      parsed = JSON.parse(text || "{}")
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("settings")
    } catch (e) {
      root.settingsError = "Impossible de lire les réglages Todoist."
      parsed = {}
    }
    if (typeof parsed.apiToken === "string") root.apiToken = Model.safeTrim(parsed.apiToken)
    if (parsed.quickView === "tomorrow") parsed.quickView = "upcoming"
    if (parsed.quickView === "inbox") parsed.quickView = "undated"
    if (parsed.quickView === "all") parsed.quickView = "today"
    if (parsed.barCountMode === "inbox") parsed.barCountMode = "undated"
    if (["today", "upcoming", "undated"].indexOf(parsed.quickView) !== -1) root.quickView = parsed.quickView
    if (typeof parsed.panelWidth === "number") root.panelWidth = Math.max(260, Math.min(700, parsed.panelWidth))
    if (typeof parsed.panelHeight === "number") root.panelHeight = Math.max(240, Math.min(800, parsed.panelHeight))
    if (["hide", "today", "undated", "all"].indexOf(parsed.barCountMode) !== -1) root.barCountMode = parsed.barCountMode
    root.settingsLoaded = true
    root.settingsView = root.apiToken === ""
    if (root.apiToken !== "") refresh()
  }

  function persistSettings() {
    if (!root.settingsLoaded) return
    root.pendingSettings = JSON.stringify({
      apiToken: root.apiToken, quickView: root.quickView,
      panelWidth: root.panelWidth, panelHeight: root.panelHeight,
      barCountMode: root.barCountMode
    }, null, 2) + "\n"
    writePendingSettings()
  }

  function writePendingSettings() {
    if (!root.stateReady || settingsWriteProc.running || root.pendingSettings === "") return
    var text = root.pendingSettings
    root.pendingSettings = ""
    settingsWriteProc.stdinEnabled = true
    settingsWriteProc.running = true
    settingsWriteProc.write(text)
    settingsWriteProc.stdinEnabled = false
  }

  function resetAccount() {
    root.accountGeneration++
    root.dataRevision++
    root.actionQueue = []
    root.pendingTaskIds = []
    root.completingTaskIds = []
    root.pendingRemovalIds = []
    completionRemovalTimer.stop()
    root.allTasks = []
    root.allProjects = []
    root.taskMetadata = ({})
    root.richMetadataReady = false
    root.composerOpen = false
    root.detailTask = null
    root.projectsSyncedAt = 0
    root.projectError = ""
    root.tasks = []
    root.todayTaskCount = 0
    root.upcomingTaskCount = 0
    root.undatedTaskCount = 0
    root.allTaskCount = 0
    root.barCountValue = 0
    root.lastSyncedAt = 0
    root.selectedTaskIndex = -1
    root.taskCursorActive = false
    root.editingTaskId = ""
    root.editDraft = ""
    root.quickAddText = ""
    quickAddField.text = ""
    root.quickAddSubmitting = false
    root.refreshPending = false
    root.fetchError = ""
    root.actionError = ""
    // In-flight processes finish with their original generation and are ignored.
  }

  function saveToken() {
    var value = Model.safeTrim(root.tokenDraft)
    if (value === "" || !root.stateReady || !root.settingsLoaded) return
    if (/[\r\n]/.test(value)) {
      root.settingsError = "Le jeton API doit tenir sur une seule ligne."
      return
    }
    resetAccount()
    root.apiToken = value
    root.tokenDraft = ""
    tokenField.text = ""
    root.settingsView = false
    persistSettings()
    refresh()
  }

  function clearToken() {
    resetAccount()
    root.apiToken = ""
    root.tokenDraft = ""
    tokenField.text = ""
    root.settingsView = true
    persistSettings()
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
  //      conditionally visible controls are filtered in or out here rather
  //      than kept as fixed slots.
  function settingsFocusChain() {
    var chain = [tokenField, saveTokenButton]
    if (root.apiToken !== "") chain.push(removeTokenButton)
    chain.push(barCountHideButton, barCountTodayButton, barCountUndatedButton, barCountAllButton)
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

  // All three views share a single paginated snapshot across every project.
  function selectQuickView(view) {
    if (root.dragging) return
    if (view === root.quickView) return
    root.quickView = view
    root.selectedTaskIndex = -1
    root.taskCursorActive = false
    persistSettings()
    applySnapshot()
    refresh()
  }

  readonly property var quickViewOrder: ["today", "upcoming", "undated"]

  function cycleQuickView(direction) {
    var idx = root.quickViewOrder.indexOf(root.quickView)
    if (idx === -1) idx = 0
    var next = (idx + direction + root.quickViewOrder.length) % root.quickViewOrder.length
    root.selectQuickView(root.quickViewOrder[next])
  }

  // ---- Keyboard cursor: arrows/j/k select, Enter edits, Space completes.
  //      Tab cycles quick views independently of the selected task.
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

  function selectTask(index) {
    if (index < 0 || index >= root.tasks.length) return
    root.selectedTaskIndex = index
    root.taskCursorActive = true
  }

  function activateSelectedTask() {
    if (root.selectedTaskIndex < 0 || root.selectedTaskIndex >= root.tasks.length) return
    var task = root.tasks[root.selectedTaskIndex]
    if (task) root.requestComplete(task.id)
  }

  // ---- Open the selected task on the Todoist website (o). Closes the
  //      panel afterward — attention is going to the browser, not staying
  //      here, matching how launching anything else from a panel dismisses it.
  function openSelectedTaskInBrowser() {
    if (root.selectedTaskIndex < 0 || root.selectedTaskIndex >= root.tasks.length) return
    var task = root.tasks[root.selectedTaskIndex]
    if (!task || !task.id) return
    // Always launch the task URL: focusing an existing webapp does not navigate it.
    openUrlProc.command = ["omarchy-launch-webapp", "https://app.todoist.com/app/task/" + encodeURIComponent(task.id)]
    openUrlProc.running = true
    root.close()
  }

  // ---- Task actions use stable IDs and one serialized request queue.
  function taskIsPending(taskId) {
    return root.pendingTaskIds.indexOf(taskId) !== -1
  }

  function selectedTask() {
    return root.tasks[root.selectedTaskIndex] || null
  }

  function startEditSelectedTask() {
    var task = selectedTask()
    if (!task || taskIsPending(task.id)) return
    root.editDraft = task.content || ""
    root.editingTaskId = task.id
  }

  function cancelEditTask() {
    root.editingTaskId = ""
    root.editDraft = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Secrets go through stdin, never argv. Escape curl configuration syntax.
  function runAuthedCurl(proc, command) {
    proc.stdinEnabled = true
    proc.command = command
    proc.running = true
    proc.write("header = \"Authorization: Bearer " + Model.curlConfigEscape(root.apiToken) + "\"\n")
    proc.stdinEnabled = false
  }

  function openComposer() {
    if (root.dragging || root.actionBusy) return
    root.composerOpen = true
    refreshProjects()
    Qt.callLater(function() {
      taskListView.contentY = Math.max(0, taskListView.contentHeight - taskListView.footerItem.height)
      if (taskListView.footerItem && taskListView.footerItem.composer) taskListView.footerItem.composer.focusInput()
    })
  }

  function showTaskDetails(task, edit) {
    if (!task || root.dragging) return
    root.detailTask = task
    root.detailEdit = edit
    refreshProjects()
    taskDetails.open()
    Qt.callLater(function() { if (detailLoader.item && edit) detailLoader.item.startEditing() })
  }

  function editPlan(task, draft) {
    return EditParser.parse(task, draft, Model.localDueDateIso(task))
  }

  function commitEditTask() {
    var taskId = root.editingTaskId
    var content = Model.safeTrim(root.editDraft)
    if (taskId === "") return
    var task = root.allTasks.filter(function(t) { return t.id === taskId })[0]
    if (!task) { root.actionError = "Cette tâche n’est plus disponible."; return }
    if (content === task.content) { cancelEditTask(); return }
    try {
      var plan = editPlan(task, content)
      root.actionError = ""
      cancelEditTask()
      if (plan.projectName) enqueueAction("smartEdit", taskId, plan, content)
      else enqueueAction("edit", taskId, plan.update, content)
    } catch (e) {
      root.actionError = String(e.message || e)
    }
  }

  function fetchEditProjects(action, cursor) {
    var url = root.apiBase + "/projects?limit=200"
    if (cursor) url += "&cursor=" + encodeURIComponent(cursor)
    runAuthedCurl(actionProc, ["curl", "-q", "-fsS", "--max-time", "10", "-K", "-", url])
  }

  function postEditStage(action, path, payload) {
    runAuthedCurl(actionProc, ["curl", "-q", "-fsS", "--max-time", "10", "-K", "-",
      "-X", "POST", "-H", "Content-Type: application/json", "-d", JSON.stringify(payload),
      root.apiBase + "/tasks/" + encodeURIComponent(action.taskId) + path])
  }

  function advanceEdit(action, stdoutText) {
    if (action.stage === "projects") {
      var page = EditParser.parseProjectPage(stdoutText)
      action.projects = action.projects.concat(page.results)
      if (page.next_cursor !== null) {
        if (action.cursors.indexOf(page.next_cursor) !== -1) throw new Error("Curseur des projets répété.")
        action.cursors.push(page.next_cursor)
        fetchEditProjects(action, page.next_cursor)
        return true
      }
      root.allProjects = action.projects
      root.projectsSyncedAt = Date.now()
      action.projectId = EditParser.resolveProject(action.projects, action.payload.projectName)
      var task = root.allTasks.find(function(t) { return t.id === action.taskId })
      action.moveNeeded = task && String(task.project_id) !== action.projectId
      action.stage = "update"
      postEditStage(action, "", action.payload.update)
      return true
    }
    if (action.stage === "update" && action.moveNeeded) {
      action.stage = "move"
      postEditStage(action, "/move", { project_id: action.projectId })
      return true
    }
    return false
  }

  function setSelectedTaskDue(dueString) {
    var task = selectedTask()
    if (!task) return
    enqueueAction("due", task.id, dueString === null
      ? { due_string: "no date", due_lang: "en" }
      : { due_string: dueString, due_lang: "en" })
  }

  function beginTaskDrag(taskId, point) {
    if (root.actionBusy || root.loading || root.actionQueue.length || root.pendingRemovalIds.length || root.editingTaskId !== "") return
    root.dragTaskId = taskId
    root.selectedTaskIndex = root.tasks.findIndex(function(t) { return t.id === taskId })
    keyCatcher.forceActiveFocus()
    moveTaskDrag(point)
  }

  function moveTaskDrag(point) {
    if (!root.dragging) return
    root.dragPoint = point
    locateTaskDrop()
  }

  function locateTaskDrop() {
    root.dragDrop = null
    var tabs = [todayViewButton, upcomingViewButton, undatedViewButton]
    var dates = [Model.todayIsoDate(), Model.tomorrowIsoDate(), ""]
    for (var i = 0; i < tabs.length; i++) {
      var p = tabs[i].mapFromItem(keyCatcher, root.dragPoint.x, root.dragPoint.y)
      if (p.x >= 0 && p.x < tabs[i].width && p.y >= 0 && p.y < tabs[i].height) {
        root.dragDrop = { tab: i, datePayload: Model.dragDatePayload(dates[i]) }
        return
      }
    }
    var point = taskListView.mapFromItem(keyCatcher, root.dragPoint.x, root.dragPoint.y)
    if (point.x < 0 || point.x >= taskListView.width || point.y < 0 || point.y >= taskListView.height) return
    var y = point.y + taskListView.contentY
    var index = taskListView.indexAt(1, y)
    if (index < 0 && root.tasks.length && y >= taskListView.contentHeight) index = root.tasks.length - 1
    var item = taskListView.itemAtIndex(index)
    if (!item) return
    var target = root.tasks[index]
    var heading = item.startsGroup && y < item.y + item.taskTop
    if (heading && root.quickView === "upcoming") {
      root.dragDrop = { index: index, heading: true, datePayload: Model.dragDatePayload(target.groupDate) }
      return
    }
    // Dropping a main task over a child refers to that whole parent tree.
    var source = root.tasks.find(function(t) { return t.id === root.dragTaskId })
    if (source && !source.subtaskDepth) {
      while (index > 0 && root.tasks[index].subtaskDepth > 0) index--
      target = root.tasks[index]
    }
    item = taskListView.itemAtIndex(index)
    if (!item) return
    var after = y >= item.y + item.taskTop + (item.height - item.taskTop) / 2
    var plan = Model.taskDropPlan(root.tasks, root.dragTaskId, target.id, after, root.quickView)
    if (!plan) return
    var markerIndex = index
    if (after) {
      while (markerIndex + 1 < root.tasks.length && root.tasks[markerIndex + 1].subtaskDepth > target.subtaskDepth) markerIndex++
    }
    root.dragDrop = { index: markerIndex, after: after, plan: plan }
  }

  function cancelTaskDrag() {
    root.dragTaskId = ""
    root.dragDrop = null
  }

  function finishTaskDrag() {
    var id = root.dragTaskId, drop = root.dragDrop
    cancelTaskDrag()
    if (!id || !drop) return
    if (drop.plan) {
      var uuid = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function(c) {
        var n = Math.floor(Math.random() * 16)
        return (c === "x" ? n : (n & 3) | 8).toString(16)
      })
      enqueueAction("reorder", id, {
        datePayload: drop.plan.datePayload,
        commands: [{ type: "item_update_day_orders", uuid: uuid, args: { ids_to_orders: drop.plan.orders } }]
      })
    } else enqueueAction("due", id, drop.datePayload)
  }

  function requestDeleteSelected() {
    var task = selectedTask()
    if (task) enqueueAction("delete", task.id, null)
  }

  function requestComplete(taskId) {
    enqueueAction("complete", taskId, null)
  }

  function quickAddTextForView(content) {
    if (Model.quickAddHasDueHint(content)) return content
    if (root.quickView === "today") return content + " aujourd'hui"
    if (root.quickView === "upcoming") return content + " demain"
    return content
  }

  function submitQuickAdd() {
    var content = Model.safeTrim(root.quickAddText)
    if (content === "" || root.quickAddSubmitting) return
    enqueueAction("create", "", { text: quickAddTextForView(content) }, content)
  }

  function enqueueAction(kind, taskId, payload, draft) {
    if (root.apiToken === "" || (kind !== "create" && (!taskId || taskIsPending(taskId)))) return
    root.actionError = ""
    root.dataRevision++
    if (kind === "create") root.quickAddSubmitting = true
    else root.pendingTaskIds = root.pendingTaskIds.concat([taskId])
    if (kind === "complete") root.completingTaskIds = root.completingTaskIds.concat([taskId])
    root.actionQueue = root.actionQueue.concat([{
      kind: kind, taskId: taskId, payload: payload, draft: draft || "",
      generation: root.accountGeneration
    }])
    processActionQueue()
  }

  function processActionQueue() {
    if (root.actionBusy || root.actionQueue.length === 0) return
    var action = root.actionQueue[0]
    root.actionQueue = root.actionQueue.slice(1)
    root.actionBusy = true
    actionProc.action = action
    if (action.kind === "smartEdit") {
      action.stage = "projects"
      action.projects = []
      action.cursors = []
      fetchEditProjects(action, "")
      return
    }
    var url = root.apiBase + "/tasks/" + encodeURIComponent(action.taskId)
    if (action.kind === "create" || action.kind === "richCreate") url = root.apiBase + "/tasks/quick"
    else if (action.kind === "richUpdate") url = root.apiBase + "/sync"
    else if (action.kind === "complete") url += "/close"
    var payload = action.kind === "richCreate" ? action.payload.body : action.payload
    if (action.kind === "reorder") {
      action.dateStage = !!payload.datePayload
      if (action.dateStage) payload = payload.datePayload
      else { url = root.apiBase + "/sync"; payload = { commands: payload.commands } }
    }
    var command = ["curl", "-q", "-fsS", "--max-time", "10", "-K", "-",
      "-X", action.kind === "delete" ? "DELETE" : "POST"]
    if (action.kind === "richCreate") command = command.concat(["-H", "X-Request-Id: " + action.payload.requestId])
    if (payload !== null) command = command.concat([
      "-H", "Content-Type: application/json", "-d", JSON.stringify(payload)])
    runAuthedCurl(actionProc, command.concat([url]))
  }

  function finishAction(action, exitCode, stderrText, stdoutText) {
    if (action.kind === "richUpdate" && action.generation === root.accountGeneration && exitCode === 0) {
      var statuses = {}
      try { statuses = JSON.parse(stdoutText).sync_status || {} } catch (e) {}
      var failed = action.payload.commands.filter(function(c) { return statuses[c.uuid] !== "ok" })
      if (failed.length) {
        exitCode = -1
        stderrText = (failed.length < action.payload.commands.length ? "Certaines modifications ont été enregistrées. " : "")
          + "Todoist n’a pas confirmé toutes les modifications. Réessayez."
      }
    }
    if (action.kind === "smartEdit" && action.generation === root.accountGeneration && exitCode === 0) {
      try { if (advanceEdit(action, stdoutText)) return }
      catch (e) { exitCode = -1; stderrText = String(e.message || e) }
    }
    if (action.kind === "reorder" && action.generation === root.accountGeneration && exitCode === 0) {
      if (action.dateStage) {
        action.dateStage = false
        runAuthedCurl(actionProc, ["curl", "-q", "-fsS", "--max-time", "10", "-K", "-",
          "-X", "POST", "-H", "Content-Type: application/json", "-d",
          JSON.stringify({ commands: action.payload.commands }), root.apiBase + "/sync"])
        return
      }
      if (!Model.syncOrderSucceeded(stdoutText, action.payload.commands[0].uuid)) {
        exitCode = -1
        stderrText = "Impossible d’enregistrer l’ordre des tâches."
      }
    }
    root.actionBusy = false
    if (action.generation === root.accountGeneration) {
      root.dataRevision++
      if (action.kind === "create") {
        root.quickAddSubmitting = false
        if (exitCode === 0 && Model.safeTrim(root.quickAddText) === action.draft) {
          root.quickAddText = ""
          quickAddField.text = ""
        }
      }
      if (exitCode !== 0) {
        root.actionError = Model.errorMessageForExit(exitCode, stderrText)
        if (action.kind === "smartEdit" && action.stage === "move")
          root.actionError = "Modifications enregistrées, mais le changement de projet a échoué. " + root.actionError
        if ((action.kind === "edit" || action.kind === "smartEdit") && action.draft && root.editingTaskId === "") {
          root.editDraft = action.draft
          root.editingTaskId = action.taskId
        }
      }
      if (action.kind === "complete" && exitCode === 0) {
        // Keep the row until the server confirms AND its feedback has been shown.
        root.pendingRemovalIds = root.pendingRemovalIds.concat([action.taskId])
        completionRemovalTimer.restart()
      } else {
        root.pendingTaskIds = root.pendingTaskIds.filter(function(id) { return id !== action.taskId })
        root.completingTaskIds = root.completingTaskIds.filter(function(id) { return id !== action.taskId })
      }
      if (action.kind === "richCreate" || action.kind === "richUpdate" || action.kind === "complete") {
        if (exitCode !== 0) omaService.operationFailed(root.actionError)
        else if (action.kind === "richCreate") omaService.taskAdded()
        else if (action.kind === "richUpdate") omaService.taskUpdated(action.taskId)
        else omaService.taskCompleted(action.taskId)
        if (action.kind === "richUpdate" || action.kind === "richCreate") {
          root.projectsSyncedAt = 0
          refreshProjects()
        }
      }
      root.refreshPending = true
    }
    processActionQueue()
    if (!root.actionBusy && root.actionQueue.length === 0 && root.pendingRemovalIds.length === 0)
      refresh()
  }

  function flushCompletedRemovals() {
    var ids = Model.taskIdsWithDescendants(root.allTasks, root.pendingRemovalIds)
    root.pendingRemovalIds = []
    root.allTasks = root.allTasks.filter(function(t) { return ids.indexOf(t.id) === -1 })
    root.completingTaskIds = root.completingTaskIds.filter(function(id) { return ids.indexOf(id) === -1 })
    root.pendingTaskIds = root.pendingTaskIds.filter(function(id) { return ids.indexOf(id) === -1 })
    applySnapshot()
    refresh()
  }

  function countForView(view) {
    return view === "today" ? root.todayTaskCount
      : view === "upcoming" ? root.upcomingTaskCount
      : view === "undated" ? root.undatedTaskCount : root.allTaskCount
  }

  function applySnapshot() {
    var selected = selectedTask()
    var views = {
      today: Model.taskTreeForView(root.allTasks, "today"),
      upcoming: Model.taskTreeForView(root.allTasks, "upcoming"),
      undated: Model.taskTreeForView(root.allTasks, "undated"),
      all: Model.taskTreeForView(root.allTasks, "all")
    }
    root.tasks = views[root.quickView] || views.all
    if (root.detailTask) {
      var current = root.allTasks.find(function(t) { return t.id === root.detailTask.id })
      if (current) root.detailTask = current
    }
    root.selectedTaskIndex = selected ? root.tasks.findIndex(function(t) { return t.id === selected.id }) : -1
    root.todayTaskCount = views.today.length
    root.upcomingTaskCount = views.upcoming.length
    root.undatedTaskCount = views.undated.length
    root.allTaskCount = views.all.length
    refreshBarCount()
  }

  function refreshBarCount() {
    root.barCountValue = root.barCountMode === "hide" ? 0 : countForView(root.barCountMode)
  }

  function setBarCountMode(mode) {
    if (mode === root.barCountMode) return
    root.barCountMode = mode
    persistSettings()
    refreshBarCount()
  }

  function refresh() {
    if (root.apiToken === "") return
    if (root.dragging || root.loading || root.actionBusy || root.actionQueue.length > 0 || root.pendingRemovalIds.length > 0) {
      root.refreshPending = true
      return
    }
    root.refreshPending = false
    root.fetchError = ""
    root.loading = true
    listProc.generation = root.accountGeneration
    listProc.revision = root.dataRevision
    listProc.accumulated = []
    listProc.cursors = []
    fetchPage("")
  }

  function fetchPage(cursor) {
    var url = root.apiBase + "/tasks?limit=200"
    if (cursor !== "") url += "&cursor=" + encodeURIComponent(cursor)
    runAuthedCurl(listProc, ["curl", "-q", "-fsS", "--max-time", "10", "-K", "-", url])
  }

  function refreshProjects() {
    if (!root.apiToken || root.projectsLoading || Date.now() - root.projectsSyncedAt < 60000) return
    root.projectError = ""
    root.projectsLoading = true
    projectProc.generation = root.accountGeneration
    projectProc.accumulated = []
    projectProc.cursors = []
    fetchProjectPage("")
  }

  function fetchProjectPage(cursor) {
    runAuthedCurl(projectProc, ["curl", "-q", "-fsS", "--max-time", "10", "-K", "-",
      "-X", "POST", "-H", "Content-Type: application/json", "-d", JSON.stringify({sync_token: "*",
        resource_types: ["projects", "sections", "labels", "user", "collaborators", "reminders", "completed_info"]}), root.apiBase + "/sync"])
  }

  function finishProjects(exitCode, stdoutText, stderrText) {
    if (projectProc.generation !== root.accountGeneration) {
      root.projectsLoading = false
      if (root.apiToken && root.allTasks.length) refreshProjects()
      return
    }
    try {
      if (exitCode !== 0) throw new Error(Model.errorMessageForExit(exitCode, stderrText))
      var data = JSON.parse(stdoutText)
      if (!data || !Array.isArray(data.projects) || !data.user) throw new Error("Réponse Todoist incomplète.")
      root.allProjects = data.projects.filter(function(p) { return !p.is_deleted && !p.is_archived })
      root.taskMetadata = data
      root.richMetadataReady = true
      root.projectsSyncedAt = Date.now()
    } catch (e) { root.projectError = "Projets et options : " + String(e.message || e) }
    root.projectsLoading = false
  }

  function finishFetch(exitCode, stdoutText, stderrText) {
    if (listProc.generation !== root.accountGeneration || listProc.revision !== root.dataRevision) {
      root.loading = false
      if (root.apiToken !== "") refresh()
      return
    }
    try {
      if (exitCode !== 0) throw new Error(Model.errorMessageForExit(exitCode, stderrText))
      var page = Model.parseTaskPage(stdoutText)
      listProc.accumulated = listProc.accumulated.concat(page.results)
      if (page.next_cursor !== null) {
        if (listProc.cursors.indexOf(page.next_cursor) !== -1) throw new Error("Curseur Todoist répété.")
        listProc.cursors = listProc.cursors.concat([page.next_cursor])
        fetchPage(page.next_cursor)
        return
      }
      root.allTasks = listProc.accumulated
      applySnapshot()
      root.lastSyncedAt = Date.now()
    } catch (e) {
      root.fetchError = String(e.message || e)
    }
    root.loading = false
    if (root.refreshPending) refresh()
  }

  Component.onCompleted: ensureStateDir()

  Process {
    id: initStateProc
    command: ["python3", root.pluginDir + "/settings.py", "--init", root.stateDir]
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.settingsError = "Impossible de préparer le dossier privé des réglages."
        return
      }
      root.stateReady = true
      settingsFile.path = root.settingsPath
    }
  }

  Process {
    id: settingsWriteProc
    command: ["python3", root.pluginDir + "/settings.py", "--write", root.stateDir]
    onExited: function(exitCode) {
      root.settingsError = exitCode === 0 ? "" : "Impossible d’enregistrer les réglages Todoist. Réessayez."
      Qt.callLater(root.writePendingSettings)
    }
  }

  Process {
    id: listProc
    property int generation: -1
    property int revision: -1
    property var accumulated: []
    property var cursors: []
    stdout: StdioCollector { id: listOut; waitForEnd: true }
    stderr: StdioCollector { id: listErr; waitForEnd: true }
    onExited: function(exitCode) {
      // Defer until collectors have drained; no new fetch starts while loading.
      Qt.callLater(function() { root.finishFetch(exitCode, listOut.text, listErr.text) })
    }
  }

  Process {
    id: projectProc
    property int generation: -1
    property var accumulated: []
    property var cursors: []
    stdout: StdioCollector { id: projectOut; waitForEnd: true }
    stderr: StdioCollector { id: projectErr; waitForEnd: true }
    onExited: function(exitCode) {
      Qt.callLater(function() { root.finishProjects(exitCode, projectOut.text, projectErr.text) })
    }
  }

  Process {
    id: actionProc
    property var action: ({})
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      var completed = action
      Qt.callLater(function() { root.finishAction(completed, exitCode, actionErr.text, actionOut.text) })
    }
  }

  Process { id: openUrlProc }

  Timer {
    id: completionRemovalTimer
    interval: 700
    repeat: false
    onTriggered: root.flushCompletedRemovals()
  }

  FileView {
    id: settingsFile
    path: ""
    watchChanges: false
    printErrors: false
    onLoaded: if (root.stateReady) root.loadSettingsFromText(text())
    onLoadFailed: {
      if (root.stateReady) root.settingsError = "Impossible de lire les réglages Todoist."
    }
  }

  // One visibility-dependent timer; refresh never overrides its running binding.
  Timer {
    id: refreshTimer
    interval: root.opened ? 2 * 60 * 1000 : 20 * 60 * 1000
    running: root.apiToken !== "" && root.settingsLoaded
    repeat: true
    onTriggered: root.refresh()
  }

  // ---- Settings' keyboard-navigable controls. Plain Button/PanelActionButton
  //      with focusable:true still won't cycle via Tab here: once a button
  //      genuinely holds Qt's activeFocus, PanelKeyCatcher's
  //      Keys.priority: BeforeItem interception stops applying to it (that
  //      mechanism only intercepts for whichever item currently holds
  //      activeFocus — normally keyCatcher itself, never a focused
  //      descendant). Each control has to catch Tab/Backtab itself, same as
  //      tokenField already does, so this wraps that once instead
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

  Timer {
    interval: 30
    repeat: true
    running: root.dragging
    onTriggered: {
      var p = taskListView.mapFromItem(keyCatcher, root.dragPoint.x, root.dragPoint.y)
      if (p.x < 0 || p.x > taskListView.width || p.y < 0 || p.y > taskListView.height) return
      var edge = Style.space(28)
      var delta = p.y < edge ? -Style.space(8) : p.y > taskListView.height - edge ? Style.space(8) : 0
      taskListView.contentY = Math.max(0, Math.min(Math.max(0, taskListView.contentHeight - taskListView.height), taskListView.contentY + delta))
      root.locateTaskDrop()
    }
  }

  component ViewTab: Oma.Action {
    property int tabIndex: -1
    readonly property bool hasCursor: root.dragging && root.dragDrop !== null && root.dragDrop.tab === tabIndex
    Layout.fillWidth: true
    Layout.preferredWidth: 0
    Layout.minimumWidth: 0
    bold: true
  }

  component TaskRow: Oma.TaskRow {
    id: row
    required property int rowIndex
    property bool hasCursor: false
    readonly property real childIndent: Style.space(26)
    objectName: "taskRow_" + task.id
    service: omaService
    view: root.quickView
    selected: hasCursor
    dragging: root.dragTaskId === task.id
    listDragging: root.dragging
    reorderEnabled: !omaService.saving && !root.composerOpen && !taskDetails.visible
    opacity: dragging ? 0.3 : 1
    dueTextOverride: root.quickView === "upcoming" || Model.taskDateGroup(task) === "Aujourd’hui"
      ? Model.dueTimeLabel(task).trim() : Model.taskDueLabel(task)
    onActivated: function(task) { root.selectTask(rowIndex); root.showTaskDetails(task, false) }
    onContextRequested: function(task, x, y) { root.selectTask(rowIndex); root.showTaskDetails(task, false) }
    onSelectionToggled: function(task) { root.selectTask(rowIndex) }
    onDragStarted: function(x, y) { root.beginTaskDrag(task.id, mapToItem(keyCatcher, x, y)) }
    onDragMoved: function(x, y) { root.moveTaskDrag(mapToItem(keyCatcher, x, y)) }
    onDragEnded: root.finishTaskDrag()
    onDragCancelled: root.cancelTaskDrag()
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
    padding: Style.space(12)

    TodoistPanelKeyCatcher {
      id: keyCatcher
      objectName: "keyCatcher"
      anchors.fill: parent
      clip: true
      blocked: tokenField.activeFocus || root.composerOpen || taskDetails.visible || root.helpOpen
      // First Escape backs out of Settings to the task list; a second one
      // (now that settingsView is false) closes the panel.
      onCloseRequested: {
        if (root.dragging) root.cancelTaskDrag()
        else if (root.composerOpen) root.composerOpen = false
        else if (root.settingsView) root.settingsView = false
        else root.close()
      }
      // Tab walks the Settings focus chain while Settings is showing, and
      // cycles the quick-view tabs otherwise.
      onTabRequested: function(direction) {
        if (root.settingsView) root.moveSettingsFocus(direction)
        else root.cycleQuickView(direction)
      }
      onMoveRequested: function(dx, dy) {
        if (root.dragging) return
        if (dx !== 0) {
          if (!root.settingsView) root.cycleQuickView(dx)
          return
        }
        if (dy === 0) return
        if (root.settingsView) root.moveSettingsFocus(dy)
        else root.moveTaskCursor(dy)
      }
      // Enter edits tasks; in Settings it activates the focused control.
      // Text fields keep their own Enter-to-submit behavior via blocked above.
      onReturnRequested: {
        if (root.dragging) return
        if (root.settingsView) root.activateFocusedSettingsControl()
        else root.startEditSelectedTask()
      }
      // Only Space requests activation, so Enter can never complete a task.
      onActivateRequested: {
        if (root.dragging) return
        if (root.settingsView) root.activateFocusedSettingsControl()
        else root.activateSelectedTask()
      }
      // "x" is this shell's established delete shortcut (see
      // Ui/PanelKeyCatcher.qml) — the physical Delete key has no printable
      // event.text so PanelKeyCatcher never sees it as a distinct key.
      onDeleteRequested: {
        if (root.dragging) return
        if (!root.settingsView) root.requestDeleteSelected()
      }
      onTextKey: function(t, modifiers) {
        if (root.dragging) return
        if (t === "?") { root.helpOpen = !root.helpOpen; return }
        if (t === "r" || t === "R") { root.refresh(); return }
        if (t === "p" || t === "P") { root.settingsView = !root.settingsView; return }
        if (root.settingsView) {
          if (t === "t" || t === "T") root.openTodoistWebsite()
          return
        }
        if (t === "q" || t === "Q") { quickAddField.forceActiveFocus(); return }
        if (t === "e" || t === "E") { root.startEditSelectedTask(); return }
        if (t === "o" || t === "O") { root.openSelectedTaskInBrowser(); return }
        var ctrl = (modifiers & Qt.ControlModifier) !== 0
        if (t === "a" || t === "A") {
          if (ctrl) root.setSelectedTaskDue("today")
          else root.selectQuickView("today")
          return
        }
        if (t === "d" || t === "D") {
          if (ctrl) root.setSelectedTaskDue("tomorrow")
          else root.selectQuickView("upcoming")
          return
        }
        if (t === "i" || t === "I") {
          if (ctrl) root.setSelectedTaskDue(null)
          else root.selectQuickView("undated")
          return
        }
      }

      C.Popup {
        id: taskDetails
        objectName: "taskDetailsPopup"
        x: 0; y: 0
        width: parent.width
        height: Math.min(parent.height, Math.max(Style.space(200),
          detailLoader.item ? detailLoader.item.implicitHeight + padding * 2 : Style.space(200)))
        padding: Style.space(16)
        focus: true
        closePolicy: detailLoader.item && (detailLoader.item.editing || detailLoader.item.busy)
          ? C.Popup.NoAutoClose : C.Popup.CloseOnEscape | C.Popup.CloseOnPressOutside
        background: Rectangle { color: Color.popups.background; border.width: 1; border.color: Color.popups.border; radius: Style.cornerRadius }
        onClosed: { root.cancelEditTask(); root.detailTask = null }
        contentItem: Item {
          Text {
            anchors.fill: parent
            visible: !root.richMetadataReady
            text: root.projectError || "Chargement des options…"
            wrapMode: Text.Wrap
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }
          Loader {
            id: detailLoader
            anchors.fill: parent
            active: taskDetails.visible && root.detailTask !== null && root.richMetadataReady
            sourceComponent: Oma.TaskDetails {
              service: omaService
              task: root.detailTask || ({})
              onCloseRequested: taskDetails.close()
              onTaskRequested: function(task) { root.showTaskDetails(task, false) }
              Component.onCompleted: if (root.detailEdit) Qt.callLater(startEditing)
            }
          }
        }
      }

      Rectangle {
        id: dragPreview
        visible: root.dragging
        z: 20
        width: Math.min(Style.space(230), parent.width)
        height: dragCaption.implicitHeight + Style.spacing.sm * 2
        x: Math.max(0, Math.min(parent.width - width, root.dragPoint.x + Style.space(12)))
        y: Math.max(0, Math.min(parent.height - height, root.dragPoint.y + Style.space(18)))
        color: Color.popups.background
        border.color: Color.accent
        border.width: Style.space(1)
        radius: Style.cornerRadius
        Text {
          id: dragCaption
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.spacing.sm
          text: {
            if (!root.dragDrop) return "Choisir une destination"
            var payload = root.dragDrop.plan ? root.dragDrop.plan.datePayload : root.dragDrop.datePayload
            return payload ? (payload.due_date ? Model.naturalDueDateLabel(payload.due_date) : "Sans date") : "Réordonner"
          }
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
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

          // ---- Settings view ---------------------------------------------
          Column {
            id: settingsColumn
            width: parent.width
            visible: root.settingsView
            height: visible ? implicitHeight : 0
            spacing: Style.spacing.md

            Row {
              width: parent.width
              spacing: Style.spacing.sm
              PanelSectionHeader {
                width: parent.width - closeSettingsButton.width - parent.spacing
                anchors.verticalCenter: parent.verticalCenter
                text: "COMPTE"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
              }
              PanelActionButton {
                id: closeSettingsButton
                iconText: "✕"
                tooltipText: "Fermer les réglages (Échap)"
                foreground: root.contentForeground
                onClicked: root.settingsView = false
              }
            }

            Text {
              width: parent.width
              text: "Collez votre jeton API personnel Todoist — Todoist → Réglages → Intégrations → Développeur."
              wrapMode: Text.WordWrap
              color: root.secondaryForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              id: tokenField
              placeholderTextColor: root.secondaryForeground
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
                enabled: root.stateReady && root.settingsLoaded && root.tokenDraft.trim() !== ""
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
              text: "COMPTEUR DE LA BARRE"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
            }

            Text {
              width: parent.width
              text: "Afficher le nombre de tâches sur l’icône de la barre, indépendamment de l’onglet affiché dans la fenêtre."
              wrapMode: Text.WordWrap
              color: root.secondaryForeground
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
                text: "Aujourd’hui"
                selected: root.barCountMode === "today"
                onClicked: root.setBarCountMode("today")
              }

              NavButton {
                id: barCountUndatedButton
                width: barCountRow.cellWidth
                text: "Sans date"
                selected: root.barCountMode === "undated"
                onClicked: root.setBarCountMode("undated")
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
                color: root.secondaryForeground
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

            RowLayout {
              id: quickViewRow
              width: parent.width
              height: Style.space(28)
              spacing: Style.space(4)

              ViewTab {
                id: todayViewButton
                objectName: "todayViewButton"
                tabIndex: 0
                text: "Aujourd’hui"
                tip: root.countForView("today") + " tâches (a)"
                selected: root.quickView === "today" || hasCursor
                onClicked: root.selectQuickView("today")
              }
              ViewTab {
                id: upcomingViewButton
                objectName: "upcomingViewButton"
                tabIndex: 1
                text: "Bientôt"
                tip: "De demain aux six prochains jours (d) · " + root.countForView("upcoming") + " tâches"
                selected: root.quickView === "upcoming" || hasCursor
                onClicked: root.selectQuickView("upcoming")
              }
              ViewTab {
                id: undatedViewButton
                objectName: "undatedViewButton"
                tabIndex: 2
                text: "Sans date"
                tip: "Tâches sans date dans tous les projets (i) · " + root.countForView("undated") + " tâches"
                selected: root.quickView === "undated" || hasCursor
                onClicked: root.selectQuickView("undated")
              }
              Oma.Action {
                id: settingsButton
                objectName: "settingsButton"
                iconName: "settings"
                iconSize: Style.space(17)
                tip: "Réglages (p)"
                onClicked: root.settingsView = true
              }
            }

            PanelSeparator {
              id: taskListSeparator
              foreground: root.contentForeground
            }

            ListView {
              id: taskListView
              objectName: "taskListView"
              width: parent.width
              height: Math.max(0, taskColumn.height - quickViewRow.height - taskListSeparator.implicitHeight
                    - taskColumn.spacing * 2)
              spacing: 0
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              interactive: !root.dragging && contentHeight > height
              model: root.tasks
              currentIndex: root.selectedTaskIndex
              cacheBuffer: Style.space(1000)
              C.ScrollBar.vertical: C.ScrollBar { policy: taskListView.contentHeight > taskListView.height ? C.ScrollBar.AsNeeded : C.ScrollBar.AlwaysOff }
              header: Column {
                width: taskListView.width
                spacing: Style.space(8)
                Text {
                  visible: root.tasks.length === 0
                  width: parent.width
                  text: root.loading ? "Chargement…" : root.emptyStateMessage
                  color: root.secondaryForeground
                  wrapMode: Text.Wrap
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  bottomPadding: Style.space(12)
                }
                Text {
                  visible: root.errorText !== ""
                  width: parent.width
                  text: root.errorText
                  color: Color.urgent
                  wrapMode: Text.Wrap
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  bottomPadding: Style.space(12)
                }
              }
              footer: Column {
                property alias composer: composerLoader.item
                width: taskListView.width - Style.space(4)
                spacing: Style.space(10)
                Oma.Action {
                  visible: !root.composerOpen
                  text: "+   Ajouter une tâche"
                  onClicked: root.openComposer()
                }
                Text {
                  visible: root.composerOpen && !root.richMetadataReady
                  width: parent.width
                  text: root.projectError || "Chargement des options…"
                  wrapMode: Text.Wrap
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                }
                Loader {
                  id: composerLoader
                  width: parent.width
                  active: root.composerOpen && root.richMetadataReady
                  sourceComponent: Oma.Composer {
                    service: omaService
                    initialDue: root.quickView === "today" ? "aujourd’hui" : root.quickView === "upcoming" ? "demain" : ""
                    onFinished: { root.composerOpen = false; keyCatcher.forceActiveFocus() }
                    onCancelled: { root.composerOpen = false; keyCatcher.forceActiveFocus() }
                    Component.onCompleted: Qt.callLater(focusInput)
                  }
                }
              }

              delegate: Item {
                id: delegateItem
                required property var modelData
                required property int index
                readonly property real taskTop: delegateColumn.y + delegateRow.y
                readonly property string dateGroup: modelData.dateGroup
                readonly property bool startsGroup: index === 0
                  || root.tasks[index - 1].dateGroup !== dateGroup
                width: taskListView.width
                height: delegateColumn.y + delegateColumn.implicitHeight

                Rectangle {
                  z: 2
                  width: parent.width
                  height: Style.space(2)
                  color: Color.accent
                  visible: root.dragging && root.dragDrop !== null && root.dragDrop.index === delegateItem.index
                  y: root.dragDrop && root.dragDrop.after ? parent.height - height : delegateItem.taskTop
                }
                Column {
                  id: delegateColumn
                  y: 0
                  width: parent.width
                  spacing: 0
                  Item {
                    width: parent.width
                    visible: delegateItem.startsGroup
                    height: Style.space(40)
                    Oma.Label {
                      anchors.left: parent.left; anchors.right: parent.right
                      anchors.bottom: parent.bottom; anchors.bottomMargin: Style.space(9)
                      text: delegateItem.dateGroup
                      font.bold: true
                      color: text === "En retard" ? "#ef615b" : Color.popups.text
                    }
                    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Color.popups.text; opacity: 0.12 }
                  }

                  TaskRow {
                    id: delegateRow
                    // Each child checkbox starts at its parent's text column.
                    x: (delegateItem.modelData.subtaskDepth || 0) * delegateRow.childIndent
                    width: Math.max(0, parent.width - x - Style.space(4))
                    task: delegateItem.modelData
                    rowIndex: delegateItem.index
                    hasCursor: root.taskCursorActive && delegateItem.index === root.selectedTaskIndex
                  }
                }
              }
            }


          }
        }
      }

      // Shortcuts help, toggled by "?" or the settings' "?" button. Declared
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
                    text: "Tab / Maj+Tab — parcourir Aujourd’hui → Bientôt → Sans date\n"
                      + "a / d / i — accéder à Aujourd’hui / Bientôt / Sans date\n"
                      + "Ctrl+a / Ctrl+d / Ctrl+i (tâche sélectionnée) — échéance aujourd’hui / demain / aucune\n"
                      + "p — afficher/masquer les réglages\n"
                      + "↑/↓ ou k/j — déplacer la sélection\n"
                      + "Glisser une tâche — réordonner ou changer de date sur un onglet / jour\n"
                      + "Échap pendant le glissement — annuler\n"
                      + "Entrée / e — modifier (demain à 17h, p1, #Projet)\n"
                      + "Espace — marquer comme terminée\n"
                      + "o — ouvrir la page de la tâche dans Todoist\n"
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
