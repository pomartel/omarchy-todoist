const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'), vm=require('node:vm');
const M={};vm.createContext(M);vm.runInContext(fs.readFileSync('Model.js','utf8'),M);
const plain=x=>JSON.parse(JSON.stringify(x));
function task(id,date,parent='',order=-1) {return {id,content:id,parent_id:parent,day_order:order,due:date?{date}:null};}
function apply(tasks,plan) {return tasks.map(t=>({...t,day_order:plan.orders[t.id]??t.day_order}));}
test('manual reorder survives snapshots and moves the whole parent subtree',()=>{
  const today=M.todayIsoDate(), tasks=[task('a',today),task('b',today),task('child',null,'a')];
  const rows=M.taskTreeForView(tasks,'today');
  const plan=M.taskDropPlan(rows,'b','a',false,'today');
  assert.deepEqual(plain(M.taskTreeForView(apply(tasks,plan),'today').map(t=>t.id)),['b','a','child']);
  assert.equal(plan.datePayload,null);
});
test('sibling reorder overrides distinct child dates, without reparenting',()=>{
  const today=M.todayIsoDate(), tasks=[task('a',today),task('x',null,'a'),task('y',today,'a'),task('b',today)];
  const rows=M.taskTreeForView(tasks,'today'),plan=M.taskDropPlan(rows,'x','y',false,'today');
  assert.deepEqual(plain(M.taskTreeForView(apply(tasks,plan),'today').map(t=>t.id)),['a','x','y','b']);
  assert.equal(M.taskDropPlan(rows,'x','b',false,'today'),null);
  assert.equal(M.taskDropPlan(rows,'a','x',false,'today'),null);
});
test('Bientôt cross-section drop changes the date and inserts at the chosen position',()=>{
  const tomorrow=M.tomorrowIsoDate(), later=new Date();later.setDate(later.getDate()+2);
  const date=later.getFullYear()+'-'+M.pad2(later.getMonth()+1)+'-'+M.pad2(later.getDate());
  const rows=M.taskTreeForView([task('a',tomorrow),task('b',date),task('c',date)],'upcoming');
  const plan=M.taskDropPlan(rows,'a','b',true,'upcoming');
  assert.deepEqual(plain(plan.datePayload),{due_date:date});
  assert.deepEqual(plain(plan.orders),{b:0,a:1,c:2});
});
test('overdue tasks can reorder across dates without rescheduling',()=>{
  const rows=M.taskTreeForView([task('a','2020-01-01'),task('b','2020-02-01')],'today');
  const plan=M.taskDropPlan(rows,'b','a',false,'today');
  assert.equal(plan.datePayload,null);
  assert.deepEqual(plain(M.taskTreeForView(apply(rows,plan),'today').map(t=>t.id)),['b','a']);
});
test('undated tasks reorder across projects and no-op drops do nothing',()=>{
  const rows=M.taskTreeForView([{...task('a'),project_id:'one'},{...task('b'),project_id:'two'}],'undated');
  assert.equal(M.taskDropPlan(rows,'a','b',false,'undated'),null);
  const plan=M.taskDropPlan(rows,'a','b',true,'undated');
  assert.deepEqual(plain(plan.orders),{b:0,a:1});
  assert.equal(M.taskDropPlan(rows,'missing','b',true,'undated'),null);
});
test('tab date payloads and per-command sync failures are explicit',()=>{
  assert.deepEqual(plain(M.dragDatePayload('')),{due_string:'no date',due_lang:'en'});
  assert.deepEqual(plain(M.dragDatePayload('2026-10-01')),{due_date:'2026-10-01'});
  assert.equal(M.syncOrderSucceeded('{"sync_status":{"a":"ok"}}','a'),true);
  for(const body of ['{}','invalid','{"sync_status":{"a":{"error":"bad"}}}'])
    assert.equal(M.syncOrderSucceeded(body,'a'),false);
});
