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
test('local dates, priority ordering and top-level filtering',()=>{
  const today=m.todayIsoDate();
  const a={id:'a',content:'a',priority:1,due:{date:today}};
  const b={id:'b',content:'b',priority:4,due:{date:today}};
  assert.equal(m.sortedTasks([a,b])[0].id,'b');
  assert.equal(m.tasksForView([a,{id:'c'}],'today').length,1);
  assert.equal(m.topLevelTasks([a,{id:'c',parent_id:'a'}]).length,1);
  assert.equal(m.localDueDateIso(a),today);
});
