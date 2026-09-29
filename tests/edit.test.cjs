const {test}=require('node:test'), assert=require('node:assert/strict');
const fs=require('node:fs'),vm=require('node:vm'),E={};vm.createContext(E);
vm.runInContext(fs.readFileSync('EditParser.js','utf8'),E);
const parse=(text,task={content:'Réviser'},date='')=>JSON.parse(JSON.stringify(E.parse(task,text,date)));
test('French inline dates, time, priority and quoted projects are extracted together',()=>{
  const p=parse('Réviser demain à 17h p1 #"Travail personnel"');
  assert.deepEqual(p.update,{content:'Réviser',due_string:'demain à 17h',due_lang:'fr',priority:4});
  assert.equal(p.projectName,'Travail personnel');
});
test('English dates, recurring expressions, months, and explicit custom dates',()=>{
  for(const due of ['tomorrow at 5pm','next Monday at 09:30','every day at 8am','in 3 days','October 12','2026-10-03']) {
    const p=parse('Réviser '+due);assert.equal(p.update.content,'Réviser');assert.equal(p.update.due_string,due);assert.equal(p.update.due_lang,'en');
  }
  assert.equal(parse('Réviser date:"every last Friday at 2pm"').update.due_string,'every last Friday at 2pm');
});
test('French forms include weekdays, months, recurrence and spaced hours',()=>{
  for(const due of ['vendredi prochain à 17 h 30','tous les jours à 8h','dans 3 jours','12 octobre','après-demain','la semaine prochaine']) {
    const p=parse('Réviser '+due);assert.equal(p.update.content,'Réviser');assert.equal(p.update.due_string,due);assert.equal(p.update.due_lang,'fr');
  }
});
test('time-only edits preserve the existing date and recurring schedule',()=>{
  assert.equal(parse('Réviser à 17h',{content:'Réviser'},'2026-10-04').update.due_string,'2026-10-04 à 17h');
  assert.equal(parse('Réviser at 5pm',{content:'Réviser',due:{is_recurring:true,string:'every day at 9am'}},'2026-10-04').update.due_string,'every day at 5pm');
  assert.equal(parse('Réviser 17:30').update.due_string,'17:30');
});
test('title-only and priority-only edits preserve unspecified metadata',()=>{
  assert.deepEqual(parse('Réviser le rapport').update,{content:'Réviser le rapport'});
  for(let p=1;p<=4;p++) assert.deepEqual(parse('Réviser p'+p).update,{content:'Réviser',priority:5-p});
  assert.deepEqual(parse('Réviser !!2').update,{content:'Réviser',priority:3});
});
test('existing keywords, markdown links, escaped tokens and quoted prose stay literal',()=>{
  assert.deepEqual(parse('Read Tomorrow book p2',{content:'Read Tomorrow book'}).update,{content:'Read Tomorrow book',priority:3});
  for(const text of ['Read "tomorrow" p2','Read [tomorrow](https://example.com/p1) p2','Read https://example.com/p1 p2','Read \\tomorrow p2','Read `tomorrow` p2']) {
    const p=parse(text);assert.equal(p.update.due_string,undefined);assert.equal(p.update.priority,3);
  }
});
test('escaped project spaces, no-date commands and invalid combinations',()=>{
  assert.equal(parse('Réviser #Travail\\ personnel').projectName,'Travail personnel');
  assert.deepEqual(parse('Réviser sans date').update,{content:'Réviser',due_string:'no date',due_lang:'en'});
  for(const text of ['p1 demain','Réviser demain vendredi','Réviser p1 p2','Réviser #A #B','Réviser sans date à 17h']) assert.throws(()=>parse(text));
});
test('projects resolve exactly across all pages and refuse ambiguous matches',()=>{
  assert.equal(E.resolveProject([{id:'1',name:'Travail'}],'travail'),'1');
  assert.throws(()=>E.resolveProject([],'Travail'),/introuvable/);
  assert.throws(()=>E.resolveProject([{id:'1',name:'Travail'},{id:'2',name:'travail'}],'Travail'),/Plusieurs/);
  assert.equal(E.parseProjectPage('{"results":[{"id":"1","name":"Work"}],"next_cursor":null}').results[0].id,'1');
  for(const text of ['{}','broken','{"results":[{"id":"1"}],"next_cursor":null}']) assert.throws(()=>E.parseProjectPage(text));
});
