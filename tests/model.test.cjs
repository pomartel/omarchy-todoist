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

test('subtask context resolves absent-view parents and nested ancestors without mutating tasks',()=>{
  const parent={id:'p',content:'Parent'};
  const child={id:'c',content:'Child',parent_id:'p'};
  const grandchild={id:'g',content:'Grandchild',parent_id:'c'};
  const result=m.withParentContext([child,grandchild],[parent,child,grandchild]);
  assert.equal(result[0].parentTitle,'Parent'); assert.equal(result[0].subtaskDepth,1);
  assert.equal(result[1].parentTitle,'Child'); assert.equal(result[1].subtaskDepth,2);
  assert.equal(child.subtaskDepth,undefined); assert.equal(result[0].id,'c');
});

test('missing parents and cyclic parent data remain safe to display',()=>{
  const missing={id:'m',parent_id:'absent'};
  const a={id:'a',content:'A',parent:'b'}, b={id:'b',content:'B',parent_id:'a'};
  const result=m.withParentContext([missing,a,b],[a,b]);
  assert.equal(result[0].subtaskDepth,1); assert.equal(result[0].parentTitle,'');
  assert.equal(result[1].subtaskDepth,1); assert.equal(result[2].subtaskDepth,1);
});
