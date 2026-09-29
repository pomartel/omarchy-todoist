const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('Panel.qml', 'utf8');
function harness() {
  const calls = [], later = [];
  const process = () => ({ running: false, command: [], write(value) { this.input = value; calls.push({proc: this, command: [...this.command]}); } });
  const timer = { restart() { this.running = true; }, stop() { this.running = false; } };
  const root = {
    apiToken: 'test-only', apiBase: 'https://example.invalid', accountGeneration: 0, dataRevision: 0,
    allTasks: [], inboxTasks: [], tasks: [], quickView: 'today', selectedTaskIndex: -1,
    editingTaskId: '', editDraft: '', pendingTaskIds: [], completingTaskIds: [], pendingRemovalIds: [],
    actionQueue: [], actionBusy: false, loading: false, refreshPending: false, quickAddSubmitting: false,
    quickAddText: '', fetchError: '', actionError: '', settingsError: '', lastSyncedAt: 0,
    barCountMode: 'all', stateReady: true, settingsLoaded: true, pendingSettings: '',
  };
  const c = { root, Model: {}, Qt: { callLater(fn) { later.push(fn); } },
    keyCatcher: {forceActiveFocus() {}}, quickAddField: {text: ''}, tokenField: {text: ''},
    completionRemovalTimer: timer, listProc: process(), actionProc: process(), settingsWriteProc: process(),
  };
  vm.createContext(c.Model); vm.runInContext(fs.readFileSync('Model.js', 'utf8'), c.Model);
  vm.createContext(c);
  for (const match of source.matchAll(/^  function \w+\([^]*?^  }/gm)) {
    vm.runInContext(match[0], c);
    const name = match[0].match(/function (\w+)/)[1];
    root[name] = c[name];
  }
  function page(results, cursor=null, exit=0) {
    c.listProc.running = false;
    root.finishFetch(exit, JSON.stringify({results, next_cursor: cursor}), exit ? 'HTTP 500' : '');
  }
  function complete(exit=0) {
    c.actionProc.running = false;
    root.finishAction(c.actionProc.action, exit, exit ? 'HTTP 500' : '');
  }
  return {root, c, calls, page, complete};
}
const task = (id, due) => ({id, content: id, due: due ? {date: due} : null});

test('all pages and Inbox are published together, with local counts', () => {
  const {root:r,c,calls,page} = harness();
  const today = c.Model.todayIsoDate();
  r.refresh(); page([task('a', today)], 'opaque cursor');
  assert.equal(r.tasks.length, 0);
  assert.match(calls.at(-1).command.at(-1), /cursor=opaque%20cursor/);
  page([task('b')]);
  assert.equal(r.tasks.length, 0);
  assert.match(calls.at(-1).command.at(-1), /tasks\/filter/);
  page([task('b')]);
  assert.equal(r.tasks[0].id, 'a');
  assert.equal(r.todayTaskCount, 1); assert.equal(r.allTaskCount, 2);
  assert.equal(r.inboxTaskCount, 1); assert.equal(r.barCountValue, 2);
  assert.equal(calls.length, 3);
});

test('failed later page retains prior snapshot and reports failure', () => {
  const {root:r,page} = harness(); r.allTasks=[task('old')]; r.quickView='all'; r.applySnapshot();
  r.refresh(); page([task('new')], 'next'); page([], null, 22);
  assert.equal(r.tasks[0].id, 'old'); assert.notEqual(r.fetchError, '');
  assert.equal(r.loading, false);
});

test('repeated cursors fail without publishing partial results', () => {
  const {root:r,page} = harness(); r.refresh(); page([task('a')], 'same'); page([task('b')], 'same');
  assert.match(r.fetchError, /répété/); assert.equal(r.tasks.length,0);
});

test('changing view during fetch derives the new view from the complete snapshot', () => {
  const {root:r,c,page} = harness(); r.refresh(); r.quickView='inbox';
  page([task('a', c.Model.todayIsoDate()),task('b')]); page([task('b')]);
  assert.equal(r.tasks.length,1); assert.equal(r.tasks[0].id,'b');
});

test('editing follows ID after task reordering', () => {
  const {root:r,c,calls} = harness(); r.allTasks=[task('a'),task('b')]; r.tasks=r.allTasks;
  r.selectedTaskIndex=0; r.startEditSelectedTask(); r.editDraft='edited a';
  r.tasks=[task('b'),task('a')]; r.commitEditTask();
  assert.match(calls[0].command.at(-1), /tasks\/a$/);
  assert.equal(JSON.parse(calls[0].command[calls[0].command.indexOf('-d')+1]).content,'edited a');
  assert.equal(c.actionProc.running,true);
});

test('deletions and edits queue without replacing a running command', () => {
  const {root:r,c,calls,complete} = harness(); r.tasks=[task('a'),task('b')];
  r.selectedTaskIndex=0; r.requestDeleteSelected(); r.selectedTaskIndex=1; r.requestDeleteSelected();
  assert.equal(calls.length,1); assert.equal(r.actionQueue.length,1);
  complete(); assert.equal(calls.length,2); assert.match(calls[1].command.at(-1),/\/b$/);
  assert.equal(r.actionBusy,true); assert.equal(r.tasks.length,2);
});

test('completion waits for server success and animation before reconciliation', () => {
  const {root:r,c,calls,complete} = harness(); r.allTasks=[task('a')]; r.tasks=r.allTasks;
  r.requestComplete('a'); r.refresh();
  assert.equal(calls.length,1); assert.equal(r.pendingRemovalIds.length,0);
  assert.equal(r.completingTaskIds.length,1);
  complete(); assert.equal(calls.length,1); assert.equal(r.tasks.length,1);
  r.flushCompletedRemovals(); assert.equal(r.tasks.length,0); assert.equal(calls.length,2);
});

test('failed mutation error survives refresh and successful reconciliation', () => {
  const {root:r,complete,page} = harness(); r.requestComplete('a'); complete(22);
  const error = r.actionError; assert.notEqual(error,'');
  assert.equal(r.completingTaskIds.length,0); assert.equal(r.pendingRemovalIds.length,0);
  page([]); page([]); assert.equal(r.actionError,error);
});

test('disconnect ignores old responses and drops queued actions and counts', () => {
  const {root:r,c,page,complete,calls} = harness(); r.refresh();
  r.enqueueAction('delete','a',null); r.enqueueAction('delete','b',null);
  r.barCountValue=5; r.clearToken(); page([task('old')]); complete();
  assert.equal(r.tasks.length,0); assert.equal(r.allTasks.length,0);
  assert.equal(r.barCountValue,0); assert.equal(r.actionQueue.length,0);
  assert.equal(calls.filter(x=>x.proc===c.actionProc).length,1);
  assert.equal(r.loading,false);
});

test('mutation invalidates an in-flight snapshot and refresh waits for its queue', () => {
  const {root:r,page,complete,calls} = harness(); r.refresh(); r.requestComplete('a');
  page([task('a')]); assert.equal(r.tasks.length,0); assert.equal(calls.length,2);
  complete(); r.flushCompletedRemovals(); assert.equal(calls.length,3);
});

test('new account rejects old fetch and starts a fresh one', () => {
  const {root:r,page,calls} = harness(); r.refresh(); r.resetAccount(); r.apiToken='new-dummy'; r.refresh();
  page([task('old')]); assert.equal(r.tasks.length,0); assert.equal(calls.length,2);
  page([task('new')]); page([]); assert.equal(r.allTasks[0].id,'new');
});

test('quick add preserves a newer draft while request is pending', () => {
  const {root:r,complete} = harness(); r.quickAddText='first'; r.submitQuickAdd();
  r.quickAddText='second'; complete(); assert.equal(r.quickAddText,'second');
});

test('settings coalesce while a write is pending', () => {
  const {root:r,c,calls} = harness(); r.persistSettings(); r.quickView='inbox'; r.persistSettings();
  assert.equal(calls.length,1); assert.equal(JSON.parse(r.pendingSettings).quickView,'inbox');
  c.settingsWriteProc.running=false; r.writePendingSettings();
  assert.equal(calls.length,2); assert.equal(JSON.parse(c.settingsWriteProc.input).quickView,'inbox');
});

test('rapid edits to different tasks both reach their own IDs', () => {
  const {root:r,calls,complete} = harness(); r.allTasks=[task('a'),task('b')]; r.tasks=r.allTasks;
  r.selectedTaskIndex=0; r.startEditSelectedTask(); r.editDraft='new a'; r.commitEditTask();
  r.selectedTaskIndex=1; r.startEditSelectedTask(); r.editDraft='new b'; r.commitEditTask();
  assert.equal(calls.length,1); complete(); assert.equal(calls.length,2);
  assert.match(calls[0].command.at(-1), /\/a$/); assert.match(calls[1].command.at(-1), /\/b$/);
});

test('an old account completion cannot remove a task from the new account', () => {
  const {root:r,complete} = harness(); r.requestComplete('a'); r.resetAccount();
  r.apiToken='new-dummy'; r.allTasks=[task('a')]; r.tasks=r.allTasks;
  complete(); assert.equal(r.pendingRemovalIds.length,0); assert.equal(r.tasks.length,1);
});

test('French times and no-date requests do not receive an extra default date', () => {
  const {root:r} = harness(); r.quickView='tomorrow';
  for (const text of ['appel à 17 h','réunion 17:30','acheter du pain sans date'])
    assert.equal(r.quickAddTextForView(text), text);
  assert.equal(r.quickAddTextForView('acheter du pain'), 'acheter du pain demain');
});

// Exercise the real key catcher and panel signal handlers together. This catches
// accidental double dispatch (Enter previously also emitted task completion).
function shortcutHarness() {
  const h = harness(), {root:r,c} = h;
  r.settingsView=false;
  r.controller={hide() { r.closed=true; }};
  c.openUrlProc={running:false,command:[]};
  c.blocked=false;
  for (const key of ['Escape','Tab','Backtab','Down','Up','Right','Left','Return','Enter','Space','A','D','I'])
    c.Qt['Key_'+key]=key;
  c.Qt.ControlModifier=1; c.Qt.ShiftModifier=2;
  for (const [signal, handler] of [['returnRequested','onReturnRequested'],['activateRequested','onActivateRequested']]) {
    const match=source.match(new RegExp('      '+handler+': \\{([^]*?)\\n      }'));
    c[signal]=()=>vm.runInContext(match[1],c);
  }
  const text=source.match(/      onTextKey: function\(t, modifiers\) \{([^]*?)\n      }/)[1];
  c.textKey=(t,modifiers)=>{ c.t=t;c.modifiers=modifiers;vm.runInContext("(function() {"+text+"\n})()",c); };
  const catcher=fs.readFileSync('TodoistPanelKeyCatcher.qml','utf8');
  vm.runInContext('function press(event) {'+catcher.match(/Keys.onPressed: function\(event\) \{([^]*)\n  }\n}/)[1]+'\n}',c);
  h.press=(key,text='')=>c.press({key,text,modifiers:0,accepted:false});
  r.allTasks=[task('selected/id')]; r.tasks=r.allTasks; r.selectedTaskIndex=0;
  return h;
}

test('Enter, keypad Enter and e edit without completing or opening a task', () => {
  for (const [key,text] of [['Return',''],['Enter',''],['E','e']]) {
    const {root:r,c,calls,press}=shortcutHarness(); press(key,text);
    assert.equal(r.editingTaskId,'selected/id');
    assert.equal(calls.length,0); assert.equal(c.openUrlProc.running,false);
  }
});

test('o always launches the selected task URL instead of focusing a stale page', () => {
  const {root:r,c,calls,press}=shortcutHarness(); press('O','o');
  assert.deepEqual(Array.from(c.openUrlProc.command),[
    'omarchy-launch-webapp','https://app.todoist.com/app/task/selected%2Fid']);
  assert.equal(c.openUrlProc.running,true); assert.equal(r.closed,true);
  assert.equal(calls.length,0); assert.equal(r.editingTaskId,'');
});

test('Space still completes and blocked fields do not handle task shortcuts', () => {
  const {root:r,c,press}=shortcutHarness(); c.blocked=true; press('Return'); press('O','o');
  assert.equal(r.editingTaskId,''); assert.equal(c.openUrlProc.running,false);
  c.blocked=false; press('Space'); assert.equal(r.completingTaskIds[0],'selected/id');
});

test('Enter in settings activates its control without editing a task', () => {
  const {root:r,press}=shortcutHarness(); r.settingsView=true;
  let activated=0; r.activateFocusedSettingsControl=()=>activated++;
  press('Return'); assert.equal(activated,1); assert.equal(r.editingTaskId,'');
});
