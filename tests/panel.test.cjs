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
    allTasks: [], tasks: [], quickView: 'today', selectedTaskIndex: -1,
    editingTaskId: '', editDraft: '', pendingTaskIds: [], completingTaskIds: [], pendingRemovalIds: [],
    actionQueue: [], actionBusy: false, loading: false, refreshPending: false, quickAddSubmitting: false,
    quickAddText: '', fetchError: '', actionError: '', settingsError: '', lastSyncedAt: 0,
    barCountMode: 'all', stateReady: true, settingsLoaded: true, pendingSettings: '',
  };
  const c = { root, Model: {}, EditParser: {}, Qt: { callLater(fn) { later.push(fn); } },
    keyCatcher: {forceActiveFocus() {}}, quickAddField: {text: ''}, tokenField: {text: ''},
    completionRemovalTimer: timer, listProc: process(), actionProc: process(), settingsWriteProc: process(),
  };
  vm.createContext(c.Model); vm.runInContext(fs.readFileSync('Model.js', 'utf8'), c.Model);
  vm.createContext(c.EditParser); vm.runInContext(fs.readFileSync('EditParser.js', 'utf8'), c.EditParser);
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

test('one paginated snapshot supplies all views and counts', () => {
  const {root:r,c,calls,page} = harness();
  const today = c.Model.todayIsoDate();
  r.refresh(); page([task('a', today)], 'opaque cursor');
  assert.equal(r.tasks.length, 0);
  assert.match(calls.at(-1).command.at(-1), /cursor=opaque%20cursor/);
  page([task('b')]);
  assert.equal(r.tasks[0].id, 'a');
  assert.equal(r.todayTaskCount, 1); assert.equal(r.allTaskCount, 2);
  assert.equal(r.undatedTaskCount, 1); assert.equal(r.barCountValue, 2);
  assert.equal(calls.length, 2);
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
  const {root:r,c,page} = harness(); r.refresh(); r.quickView='undated';
  page([task('a', c.Model.todayIsoDate()),task('b')]);
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
  page([]); assert.equal(r.actionError,error);
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
  page([task('new')]); assert.equal(r.allTasks[0].id,'new');
});

test('quick add preserves a newer draft while request is pending', () => {
  const {root:r,complete} = harness(); r.quickAddText='first'; r.submitQuickAdd();
  r.quickAddText='second'; complete(); assert.equal(r.quickAddText,'second');
});

test('settings coalesce while a write is pending', () => {
  const {root:r,c,calls} = harness(); r.persistSettings(); r.quickView='undated'; r.persistSettings();
  assert.equal(calls.length,1); assert.equal(JSON.parse(r.pendingSettings).quickView,'undated');
  c.settingsWriteProc.running=false; r.writePendingSettings();
  assert.equal(calls.length,2); assert.equal(JSON.parse(c.settingsWriteProc.input).quickView,'undated');
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
  const {root:r} = harness(); r.quickView='upcoming';
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
    c[signal]=()=>vm.runInContext("(function() {"+match[1]+"\n})()",c);
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

test('undated subtasks follow the main task in Today and remain individually editable',()=>{
  const {root:r,c,page,calls}=harness();
  const parent=task('parent',c.Model.todayIsoDate());
  const child={...task('child'),parent_id:'parent'};
  r.refresh(); page([child,parent]);
  assert.deepEqual(Array.from(r.tasks,t=>t.id),['parent','child']);
  assert.equal(r.tasks[1].parentTitle,'parent'); assert.equal(r.todayTaskCount,2);
  assert.equal(r.allTaskCount,2); assert.equal(r.barCountValue,2);
  assert.equal(r.undatedTaskCount,0);
  r.selectedTaskIndex=1; r.startEditSelectedTask(); r.editDraft='Edited child'; r.commitEditTask();
  assert.match(calls.at(-1).command.at(-1), /\/tasks\/child$/);
});

test('Sans date and Upcoming include the whole subtree when the root matches',()=>{
  const {root:r,c,page}=harness();
  const tomorrow=c.Model.localDateFromIso(c.Model.todayIsoDate()); tomorrow.setDate(tomorrow.getDate()+1);
  const date=tomorrow.getFullYear()+'-'+c.Model.pad2(tomorrow.getMonth()+1)+'-'+c.Model.pad2(tomorrow.getDate());
  const parent=task('parent',date);
  const child={...task('child'),parent_id:'parent'};
  const inbox=task('undated'); const nested={...task('nested',date),parent_id:'undated'};
  r.refresh(); page([parent,child,inbox,nested]);
  assert.equal(r.upcomingTaskCount,2); assert.equal(r.undatedTaskCount,2);
  r.quickView='upcoming'; r.applySnapshot();
  assert.deepEqual(Array.from(r.tasks,t=>t.id),['parent','child']);
  r.quickView='undated'; r.applySnapshot();
  assert.deepEqual(Array.from(r.tasks,t=>t.id),['undated','nested']);
  assert.equal(r.tasks[1].dateGroup,'Sans date');
});

test('completing a main task removes its entire cached subtree together',()=>{
  const {root:r,complete}=harness(); r.quickView='all';
  r.allTasks=[task('parent'),{...task('child'),parent_id:'parent'},task('other')]; r.applySnapshot();
  r.requestComplete('parent'); complete(); r.flushCompletedRemovals();
  assert.deepEqual(Array.from(r.tasks,t=>t.id),['other']);
  assert.equal(r.allTaskCount,1);
});

test('saved Tomorrow selection migrates to Upcoming',()=>{
  const {root:r}=harness(); r.settingsLoaded=false; r.apiToken='';
  r.loadSettingsFromText('{"quickView":"tomorrow"}');
  assert.equal(r.quickView,'upcoming');
});

test('d opens Upcoming while Ctrl+d continues to set tomorrow',()=>{
  const {root:r,c,press}=shortcutHarness();
  r.selectQuickView=view=>{ r.quickView=view; };
  press('D','d'); assert.equal(r.quickView,'upcoming');
  let due=''; r.setSelectedTaskDue=value=>{due=value;};
  c.press({key:'D',text:'d',modifiers:c.Qt.ControlModifier,accepted:false});
  assert.equal(due,'tomorrow');
});

test('saved Inbox and All selections migrate to available views',()=>{
  for (const [oldView,newView] of [['inbox','undated'],['all','today']]) {
    const {root:r}=harness(); r.settingsLoaded=false; r.apiToken='';
    r.loadSettingsFromText(JSON.stringify({quickView:oldView,barCountMode:'inbox'}));
    assert.equal(r.quickView,newView); assert.equal(r.barCountMode,'undated');
  }
});

test('cross-day reorder waits for the date request before syncing order', () => {
  const {root:r,c,calls}=harness();
  const payload={datePayload:{due_date:'2026-10-01'},commands:[{type:'item_update_day_orders',uuid:'u',args:{ids_to_orders:{a:0,b:1}}}]};
  r.enqueueAction('reorder','a',payload);
  assert.match(calls[0].command.at(-1),/\/tasks\/a$/);
  assert.deepEqual(JSON.parse(calls[0].command.at(-2)),payload.datePayload);
  const action=c.actionProc.action;
  r.finishAction(action,0,'','{}');
  assert.match(calls[1].command.at(-1),/\/sync$/);
  assert.equal(r.actionBusy,true);
  r.finishAction(action,0,'','{"sync_status":{"u":"ok"}}');
  assert.equal(r.actionBusy,false);
  assert.equal(r.actionError,'');
  assert.equal(r.pendingTaskIds.length,0);
});

test('failed date request never submits the subsequent reorder',()=>{
  const {root:r,c,calls}=harness();
  r.enqueueAction('reorder','a',{datePayload:{due_date:'2026-10-01'},commands:[{uuid:'u'}]});
  r.finishAction(c.actionProc.action,22,'HTTP 500','');
  assert.equal(calls.some(call=>call.command.at(-1).endsWith('/sync')),false);
  assert.notEqual(r.actionError,'');
});

test('sync errors in HTTP 200 responses are reported and refresh the snapshot',()=>{
  const {root:r,c}=harness();
  r.enqueueAction('reorder','a',{datePayload:null,commands:[{uuid:'u'}]});
  r.finishAction(c.actionProc.action,0,'','{"sync_status":{"u":{"error":"invalid"}}}');
  assert.notEqual(r.actionError,'');assert.equal(r.pendingTaskIds.length,0);assert.equal(r.loading,true);
});

test('inline edit parses dates and priority on the existing task endpoint',()=>{
  const {root:r,calls}=harness();r.allTasks=[task('a')];r.tasks=r.allTasks;r.selectedTaskIndex=0;
  r.startEditSelectedTask();r.editDraft='a demain à 17h p1';r.commitEditTask();
  const command=calls[0].command,payload=JSON.parse(command[command.indexOf('-d')+1]);
  assert.match(command.at(-1),/\/tasks\/a$/);
  assert.equal(payload.content,'a');assert.equal(payload.priority,4);assert.equal(payload.due_string,'demain à 17h');
  assert.equal(command.includes('/tasks/quick'),false);
});
test('project edit reads all project pages before updating and moving the same ID',()=>{
  const {root:r,c,calls}=harness();r.allTasks=[{...task('a'),project_id:'old'}];r.tasks=r.allTasks;r.selectedTaskIndex=0;
  r.startEditSelectedTask();r.editDraft='a p2 #Work';r.commitEditTask();
  const action=c.actionProc.action;
  assert.match(calls[0].command.at(-1),/\/projects\?limit=200$/);
  r.finishAction(action,0,'',JSON.stringify({results:[{id:'other',name:'Other'}],next_cursor:'page 2'}));
  assert.match(calls[1].command.at(-1),/cursor=page%202/);
  r.finishAction(action,0,'',JSON.stringify({results:[{id:'new',name:'Work'}],next_cursor:null}));
  assert.match(calls[2].command.at(-1),/\/tasks\/a$/);
  r.finishAction(action,0,'','{}');
  assert.match(calls[3].command.at(-1),/\/tasks\/a\/move$/);
  assert.deepEqual(JSON.parse(calls[3].command.at(-2)),{project_id:'new'});
  r.finishAction(action,0,'','{}');assert.equal(r.actionBusy,false);assert.equal(r.actionError,'');
});
test('unknown project leaves the task unchanged and restores the edit draft',()=>{
  const {root:r,c,calls}=harness();r.allTasks=[task('a')];r.tasks=r.allTasks;r.selectedTaskIndex=0;
  r.startEditSelectedTask();r.editDraft='a demain #Missing';r.commitEditTask();
  r.finishAction(c.actionProc.action,0,'',JSON.stringify({results:[],next_cursor:null}));
  assert.equal(calls.some(x=>x.command.includes('POST')),false);
  assert.equal(r.editingTaskId,'a');assert.equal(r.editDraft,'a demain #Missing');assert.match(r.actionError,/introuvable/);
});
test('invalid inline syntax stays in the editor and failed API edits restore drafts',()=>{
  const {root:r,c,calls}=harness();r.allTasks=[task('a')];r.tasks=r.allTasks;r.selectedTaskIndex=0;
  r.startEditSelectedTask();r.editDraft='p1 demain';r.commitEditTask();
  assert.equal(calls.length,0);assert.equal(r.editingTaskId,'a');
  r.editDraft='a demain';r.commitEditTask();r.finishAction(c.actionProc.action,22,'HTTP 400','');
  assert.equal(r.editingTaskId,'a');assert.equal(r.editDraft,'a demain');
});
test('failed update stops the project move, and failed move reports partial success',()=>{
  for(const stage of ['update','move']) {
    const {root:r,c,calls}=harness();r.allTasks=[task('a')];r.tasks=r.allTasks;r.selectedTaskIndex=0;
    r.startEditSelectedTask();r.editDraft='a #Work';r.commitEditTask();const action=c.actionProc.action;
    r.finishAction(action,0,'',JSON.stringify({results:[{id:'new',name:'Work'}],next_cursor:null}));
    if(stage==='move') r.finishAction(action,0,'','{}');
    r.finishAction(action,22,'HTTP 500','');
    assert.equal(r.editDraft,'a #Work');
    if(stage==='update') assert.equal(calls.some(x=>x.command.at(-1).endsWith('/move')),false);
    else assert.match(r.actionError,/Modifications enregistrées/);
  }
});
test('changing accounts during project lookup prevents further edit stages',()=>{
  const {root:r,c,calls}=harness();r.allTasks=[task('a')];r.tasks=r.allTasks;r.selectedTaskIndex=0;
  r.startEditSelectedTask();r.editDraft='a #Work';r.commitEditTask();const action=c.actionProc.action;
  r.resetAccount();r.apiToken='new-dummy';
  r.finishAction(action,0,'',JSON.stringify({results:[{id:'new',name:'Work'}],next_cursor:null}));
  assert.equal(calls.some(x=>x.command.includes('POST')),false);
});
