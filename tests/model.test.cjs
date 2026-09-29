const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const m={}; vm.createContext(m); vm.runInContext(fs.readFileSync('Model.js','utf8'),m);
test('French date hints and explicit no-date phrases',()=>{
  for(const input of ['appel à 17 h','réunion 17:30','demain','sans date','aucune date','no date','dans 2 jours'])
    assert.equal(m.quickAddHasDueHint(input),true,input);
  assert.equal(m.quickAddHasDueHint('acheter du pain'),false);
});
test('malformed pages are rejected, empty pages accepted',()=>{
  for(const input of ['no json','{}','null','{"results":[]}', '{"results":[null],"next_cursor":null}',
    '{"results":[],"next_cursor":22}']) assert.throws(()=>m.parseTaskPage(input));
  assert.equal(m.parseTaskPage('{"results":[],"next_cursor":null}').results.length,0);
});
test('only safe links become anchors and task HTML stays escaped',()=>{
  assert.equal(m.taskContentHtml('<b>x</b>'),'&lt;b&gt;x&lt;/b&gt;');
  assert.equal(m.taskContentHtml('[x](javascript:alert(1))'),'[x](javascript:alert(1))');
  assert.match(m.taskContentHtml('[x](https://example.org/a_(b))'), /href="https:\/\/example.org\/a_\(b\)"/);
});
test('curl config values cannot inject extra configuration lines',()=>{
  assert.equal(m.curlConfigEscape('a"b\\c\nd\r'), 'a\\"b\\\\c\\nd\\r');
});
test('local dates and priority ordering',()=>{
  const today=m.todayIsoDate();
  const a={id:'a',content:'a',priority:1,due:{date:today}};
  const b={id:'b',content:'b',priority:4,due:{date:today}};
  assert.equal(m.sortedTasks([a,b])[0].id,'b');
  assert.equal(m.tasksForView([a,{id:'c'}],'today').length,1);
  assert.equal(m.localDueDateIso(a),today);
});

test('date groups remain contiguous in sorted tasks without changing task identities',()=>{
  const reference='2026-09-29';
  const tasks=[
    {id:'none',content:'none'},
    {id:'future',content:'future',due:{date:'2026-12-15'}},
    {id:'today',content:'today',due:{date:reference}},
    {id:'late',content:'late',due:{date:'2026-09-28'}},
    {id:'tomorrow',content:'tomorrow',due:{date:'2026-09-30'}}
  ];
  const sorted=m.sortedTasks(tasks);
  assert.deepEqual(Array.from(sorted,t=>m.taskDateGroup(t,reference)),
    ['En retard','Aujourd’hui','À venir','À venir','Sans date']);
  assert.deepEqual(Array.from(sorted,t=>t.id),['late','today','tomorrow','future','none']);
  assert.equal(m.taskDateGroup({due:null},reference),'Sans date');
});

test('timed task grouping uses the local date rather than the raw UTC date',()=>{
  const local=new Date(2026,8,29,23,30);
  const task={due:{date:local.toISOString(),datetime:local.toISOString()}};
  assert.equal(m.taskDateGroup(task,'2026-09-29'),'Aujourd’hui');
});

test('a root is followed by all descendants regardless of their dates',()=>{
  const today=m.todayIsoDate();
  const parent={id:'p',content:'Parent',due:{date:today}};
  const child={id:'c',content:'Child',parent_id:'p'};
  const nested={id:'n',content:'Nested',parent_id:'c',due:{date:'2099-01-01'}};
  const other={id:'z',content:'Z',due:{date:today}};
  const rows=m.taskTreeForView([nested,other,child,parent],'today',[]);
  assert.deepEqual(Array.from(rows,t=>t.id),['p','c','n','z']);
  assert.deepEqual(Array.from(rows,t=>t.subtaskDepth),[0,1,2,0]);
  assert.deepEqual(Array.from(rows,t=>t.dateGroup),Array(4).fill('Aujourd’hui'));
  assert.equal(rows[2].due.date,'2099-01-01');
  assert.equal(child.subtaskDepth,undefined);
});

test('children of excluded roots never become standalone matches',()=>{
  const parent={id:'p',content:'Parent',due:{date:'2099-01-01'}};
  const child={id:'c',content:'Child',parent_id:'p',due:{date:m.todayIsoDate()}};
  assert.equal(m.taskTreeForView([parent,child],'today',[]).length,0);
  assert.equal(m.taskTreeForView([parent,child],'undated').length,0);
});

test('missing parents and cyclic data remain visible exactly once',()=>{
  const missing={id:'m',content:'M',parent_id:'absent'};
  const a={id:'a',content:'A',parent:'b'}, b={id:'b',content:'B',parent_id:'a'};
  const rows=m.taskTreeForView([missing,a,b],'all',[]);
  assert.equal(rows.length,3); assert.equal(new Set(Array.from(rows,t=>t.id)).size,3);
  assert.equal(rows[0].id,'m');
});

test('completed subtree removal includes nested descendants but not siblings',()=>{
  const tasks=[{id:'p'},{id:'c',parent_id:'p'},{id:'n',parent_id:'c'},{id:'other'}];
  assert.deepEqual(Array.from(m.taskIdsWithDescendants(tasks,['p'])).sort(),['c','n','p']);
});

test('Upcoming includes exactly the next six calendar days across year boundaries',()=>{
  const dates=['2026-12-28','2026-12-29','2026-12-30','2026-12-31','2027-01-01','2027-01-02','2027-01-03','2027-01-04','2027-01-05'];
  const tasks=dates.map(date=>({id:date,due:{date}})).concat([{id:'undated'}]);
  const result=m.tasksForView(tasks,'upcoming','2026-12-29');
  assert.deepEqual(Array.from(result,t=>t.id),dates.slice(2,8));
});

test('Upcoming uses calendar days across the daylight-saving boundary',()=>{
  const tasks=['2026-03-08','2026-03-13','2026-03-14'].map(date=>({id:date,due:{date}}));
  assert.deepEqual(Array.from(m.tasksForView(tasks,'upcoming','2026-03-07'),t=>t.id),['2026-03-08','2026-03-13']);
});

test('Sans date includes undated roots across all projects with their descendants',()=>{
  const tasks=[
    {id:'inbox',content:'A',project_id:'inbox'},
    {id:'work',content:'B',project_id:'work'},
    {id:'personal',content:'C',project_id:'personal',due:{date:'2099-01-01'}},
    {id:'child',content:'Child',parent_id:'work',due:{date:'2099-01-01'}}
  ];
  assert.deepEqual(Array.from(m.taskTreeForView(tasks,'undated'),t=>t.id),['inbox','work','child']);
});
