const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
function model(name) {
  const context = vm.createContext({});
  vm.runInContext(fs.readFileSync(`omatasks/ui/${name}.js`, 'utf8'), context);
  return context;
}
const edit = model('EditModel'), composer = model('ComposerModel');
const now = new Date(2026, 8, 29, 12);
test('French quick add dates override the view default without duplicating dates', () => {
  for (const date of ['demain à 17h', 'jeudi prochain', 'sans date', 'dans 3 jours', 'tous les jours']) {
    const text = composer.quickText({text: `Réviser ${date}`, description: '', due: 'aujourd’hui'});
    assert.equal(text, `Réviser ${date}`);
  }
  assert.equal(composer.quickText({text:'Réviser',description:'',due:'demain'}), 'Réviser demain');
});
test('French deadline choices resolve calendar dates and reject invalid dates', () => {
  assert.equal(edit.deadlineDate('aujourd’hui', now), '2026-09-29');
  assert.equal(edit.deadlineDate('demain', now), '2026-09-30');
  assert.equal(edit.deadlineDate('la semaine prochaine', now), '2026-10-06');
  assert.throws(() => edit.deadlineDate('2026-02-30', now), /date limite/);
});
test('structured edits preserve recurring dates and other unchanged fields', () => {
  const task = {content:'Réviser',priority:3,project_id:'p',labels:['travail'],due:{string:'chaque lundi',timezone:'America/Montreal'},duration:{amount:30,unit:'minute'}};
  const draft = edit.snapshot(task); draft.text = 'Réviser les notes';
  assert.equal(JSON.stringify(edit.changes(task,draft,now).update), JSON.stringify({content:'Réviser les notes'}));
  draft.due = 'Demain à 17h';
  const due = edit.changes(task,draft,now).update.due;
  assert.equal(due.lang, 'fr'); assert.equal(due.timezone, 'America/Montreal');
  draft.due = ''; assert.equal(edit.changes(task,draft,now).update.due, null);
});
test('location reminders keep the API enum while displaying French', () => {
  assert.equal(edit.reminderText({type:'location',loc_trigger:'on_leave',name:'Maison'}), 'Départ de Maison');
  assert.equal(edit.reminderText({type:'absolute',minute_offset:30}), '30 minutes avant');
});
