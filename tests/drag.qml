import QtQuick
import QtTest
import Quickshell
import qs.Commons
import "plugin" as Plugin
import "plugin/Model.js" as Model

ShellRoot {
  FloatingWindow {
    id: window
    visible: true
    implicitWidth: 400
    implicitHeight: 560
    color: Color.popups.background
    Plugin.Panel { id: panel; anchors.fill: parent; anchors.margins: 20 }
  }
  TestCase {
    name: "TodoistDrag"
    when: window.visible
    function cleanupTestCase() {
      console.log("DRAG UI RESULTS", qtest_results.passCount, "passed", qtest_results.failCount, "failed")
      Qt.callLater(Qt.quit)
    }
    function init() {
      panel.cancelTaskDrag(); panel.actionBusy = false; panel.actionQueue = []; panel.pendingTaskIds = []
      panel.captured = []; panel.loading = false; panel.apiToken = "synthetic"; panel.settingsView = false
      panel.quickView = "today"; panel.controller.show()
      panel.allTasks = Array.from({length: 25}, function(_, i) {
        return {id: String(i), content: "Synthetic task " + i, day_order: i, due: {date: Model.todayIsoDate()}}
      })
      panel.applySnapshot()
      findChild(panel, "taskListView").positionViewAtBeginning()
      wait(150)
    }
    function pointer(id) { return findChild(panel, "taskPointer_" + id) }
    function start(id) {
      var item = pointer(id); verify(item !== null)
      mousePress(item, 60, 10); mouseMove(item, 60, 32, 30)
      verify(panel.dragging)
      return item
    }
    function move(item, target, x, y) {
      var p = item.mapFromItem(target, x, y)
      mouseMove(item, p.x, p.y, 30)
      return p
    }
    function payload() {
      var command = panel.captured[0]
      return JSON.parse(command[command.indexOf("-d") + 1])
    }
    function test_hover_alignment_and_cursor() {
      var row = findChild(panel, "taskRow_0")
      var highlight = findChild(panel, "taskHighlight_0")
      var content = findChild(panel, "taskContent_0")
      panel.taskCursorActive = false
      mouseMove(row, 65, row.height / 2)
      tryCompare(highlight, "visible", true)
      compare(pointer("0").cursorShape, Qt.ArrowCursor)
      verify(Math.abs(content.y + content.height / 2 - row.height / 2) < 0.5)
      compare(highlight.height, row.height)
      grabImage(window.contentItem).save("/tmp/todoist-task-hover.png")
      mouseMove(window.contentItem, 1, 1)
      tryCompare(highlight, "visible", false)
      var item = start("0")
      compare(item.cursorShape, Qt.ClosedHandCursor)
      panel.cancelTaskDrag()
      mouseRelease(item, 60, 32)
    }
    function test_reorder() {
      var item = start("2"), p = move(item, pointer("0"), 60, 2)
      verify(panel.dragDrop !== null); verify(panel.dragDrop.plan !== undefined)
      grabImage(window.contentItem).save("/tmp/todoist-drag-reorder.png")
      mouseRelease(item, p.x, p.y)
      compare(panel.dragging, false); compare(panel.captured.length, 1)
      compare(payload().commands[0].type, "item_update_day_orders")
      compare(payload().commands[0].args.ids_to_orders["2"], 0)
      compare(panel.completingTaskIds.length, 0)
    }
    function test_tabs_data() { return [
      {tag: "today", name: "todayViewButton", date: Model.todayIsoDate()},
      {tag: "tomorrow", name: "upcomingViewButton", date: Model.tomorrowIsoDate()},
      {tag: "undated", name: "undatedViewButton", date: ""}
    ] }
    function test_tabs(data) {
      var item = start("1"), tab = findChild(panel, data.name), p = move(item, tab, tab.width / 2, tab.height / 2)
      verify(panel.dragDrop !== null); verify(tab.hasCursor)
      mouseRelease(item, p.x, p.y)
      compare(panel.captured.length, 1)
      if (data.date) compare(payload().due_date, data.date)
      else compare(payload().due_string, "no date")
      compare(panel.quickView, "today")
    }
    function test_escape_and_outside() {
      var item = start("1")
      findChild(panel, "keyCatcher").forceActiveFocus()
      keyClick(Qt.Key_Escape); compare(panel.dragging, false)
      mouseRelease(item, 60, 32); compare(panel.captured.length, 0)
      item = start("1")
      var p = move(item, window.contentItem, 1, 1)
      compare(panel.dragDrop, null)
      mouseRelease(item, p.x, p.y); compare(panel.captured.length, 0)
    }
    function test_autoscroll() {
      var item = start("1"), list = findChild(panel, "taskListView")
      var p = move(item, list, 60, list.height - 3)
      tryVerify(function() { return list.contentY > 250 }, 3000)
      verify(panel.dragging)
      p = move(item, window.contentItem, 1, 1)
      mouseRelease(item, p.x, p.y); compare(panel.captured.length, 0)
    }
    function test_upcoming_row() {
      var date = new Date(); date.setDate(date.getDate() + 2)
      var iso = date.getFullYear() + "-" + Model.pad2(date.getMonth()+1) + "-" + Model.pad2(date.getDate())
      panel.allTasks = [{id:"a",content:"Tomorrow",due:{date:Model.tomorrowIsoDate()}}, {id:"b",content:"Later",due:{date:iso}}]
      panel.quickView = "upcoming"; panel.applySnapshot(); wait(100)
      var item = start("a"), p = move(item, pointer("b"), 60, 20)
      verify(panel.dragDrop.plan !== undefined)
      compare(panel.dragDrop.plan.datePayload.due_date, iso)
      mouseRelease(item, p.x, p.y)
      compare(payload().due_date, iso)
    }
    function test_subtasks_stay_with_parent() {
      panel.allTasks = [{id:"a",content:"Parent",due:{date:Model.todayIsoDate()}},
        {id:"x",content:"First child",parent_id:"a",day_order:0},
        {id:"y",content:"Second child",parent_id:"a",day_order:1},
        {id:"b",content:"Another parent",due:{date:Model.todayIsoDate()}}]
      panel.applySnapshot(); wait(100)
      var item = start("y"), p = move(item, pointer("x"), 60, 1)
      verify(panel.dragDrop.plan !== undefined)
      compare(panel.dragDrop.plan.orders.y, 0)
      p = move(item, pointer("b"), 60, 1)
      compare(panel.dragDrop, null)
      mouseRelease(item, p.x, p.y)
      compare(panel.captured.length, 0)
    }
    function test_upcoming_heading() {
      var date = new Date(); date.setDate(date.getDate() + 2)
      var iso = date.getFullYear() + "-" + Model.pad2(date.getMonth()+1) + "-" + Model.pad2(date.getDate())
      panel.allTasks = [{id:"a",content:"Tomorrow",due:{date:Model.tomorrowIsoDate()}}, {id:"b",content:"Later",due:{date:iso}}]
      panel.quickView = "upcoming"; panel.applySnapshot(); wait(100)
      var item = start("a"), list = findChild(panel, "taskListView"), target = list.itemAtIndex(1)
      var p = move(item, target, 60, 5)
      verify(panel.dragDrop.heading)
      mouseRelease(item, p.x, p.y)
      compare(payload().due_date, iso)
    }
  }
}
