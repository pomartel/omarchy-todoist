// Pure data helpers for the Todoist panel: response shaping, sorting, and
// error-message translation. No QML/Qt types here so this stays testable on
// its own — the panel owns everything stateful (curl processes, settings
// file, UI).

function safeTrim(value) {
  return String(value === undefined || value === null ? "" : value).trim()
}

function escapeHtml(value) {
  return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;")
    .replace(/>/g, "&gt;").replace(/"/g, "&quot;")
}

// Render task links as StyledText: Qt's Markdown renderer ignores linkColor.
// Escape all task text and only emit anchors and explicit underlines.
function taskContentHtml(content) {
  var source = String(content || "")
  var result = ""
  var copied = 0
  var pattern = /\[((?:\\.|[^\]\\])+)\]\(/g
  var match
  while ((match = pattern.exec(source)) !== null) {
    var start = pattern.lastIndex
    var end = start
    var depth = 1
    for (; end < source.length && depth > 0; end++) {
      if (source[end] === "\\") { end++; continue }
      if (source[end] === "(") depth++
      if (source[end] === ")") depth--
    }
    if (depth !== 0) continue
    var url = source.slice(start, end - 1).replace(/\\([()\\])/g, "$1")
    if (!/^https?:\/\/[^\s<>]+$/i.test(url)) continue
    var label = match[1].replace(/\\([\[\]\\])/g, "$1")
    result += escapeHtml(source.slice(copied, match.index))
    // StyledText does not decode HTML entities inside href attributes.
    result += '<a href="' + url.replace(/"/g, "%22") + '"><u>' + escapeHtml(label) + '</u></a>'
    copied = end
    pattern.lastIndex = end
  }
  return (result + escapeHtml(source.slice(copied))).replace(/\n/g, "<br>")
}

function pad2(n) {
  return n < 10 ? "0" + n : String(n)
}

// due.date is either a plain "YYYY-MM-DD" or a full ISO timestamp depending
// on whether the task has a time component. The first 10 characters are the
// date either way.
function isoDatePrefix(dateStr) {
  var s = String(dateStr || "")
  return s.length >= 10 ? s.substring(0, 10) : s
}

function todayIsoDate() {
  var now = new Date()
  return now.getFullYear() + "-" + pad2(now.getMonth() + 1) + "-" + pad2(now.getDate())
}

// A timed due date is returned as an ISO timestamp (often UTC), while a
// date-only due date is returned as YYYY-MM-DD. Use the machine's local date
// for timed tasks so the date and time stay in the same timezone.
function localDueDateIso(task) {
  if (!task || !task.due) return ""
  var rawDate = String(task.due.datetime || task.due.date || "")
  if (rawDate.indexOf("T") === -1) return isoDatePrefix(rawDate)
  var dueDate = new Date(rawDate)
  if (isNaN(dueDate.getTime())) return isoDatePrefix(rawDate)
  return dueDate.getFullYear() + "-" + pad2(dueDate.getMonth() + 1)
    + "-" + pad2(dueDate.getDate())
}

var FRENCH_WEEKDAYS = [
  "Dimanche", "Lundi", "Mardi", "Mercredi", "Jeudi", "Vendredi", "Samedi"
]
var FRENCH_MONTHS = [
  "janvier", "février", "mars", "avril", "mai", "juin",
  "juillet", "août", "septembre", "octobre", "novembre", "décembre"
]

function localDateFromIso(dateStr) {
  var s = isoDatePrefix(dateStr)
  var parts = s.split("-")
  if (parts.length !== 3) return null
  return new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
}

function naturalDueDateLabel(dateStr) {
  var dueDate = localDateFromIso(dateStr)
  if (!dueDate || isNaN(dueDate.getTime())) return ""
  var today = localDateFromIso(todayIsoDate())
  var dayCount = Math.round((dueDate.getTime() - today.getTime()) / 86400000)
  if (dayCount === -1) return "Hier"
  if (dayCount === 0) return "Aujourd’hui"
  if (dayCount === 1) return "Demain"
  if (dayCount < 0) return "Il y a " + Math.abs(dayCount) + " jours"
  if (dayCount <= 6) return FRENCH_WEEKDAYS[dueDate.getDay()]
  return "Le " + dueDate.getDate() + " " + FRENCH_MONTHS[dueDate.getMonth()]
    + (dueDate.getFullYear() !== today.getFullYear() ? " " + dueDate.getFullYear() : "")
}

function dueTimeLabel(task) {
  var rawDate = task && task.due ? String(task.due.datetime || task.due.date || "") : ""
  if (rawDate.indexOf("T") === -1) return ""
  // Todoist returns due.datetime as an ISO timestamp (normally UTC). Parse
  // it so the displayed time is converted to the user's local timezone
  // instead of showing the timestamp's raw UTC hour.
  var dueDate = new Date(rawDate)
  if (isNaN(dueDate.getTime())) return ""
  var hour = dueDate.getHours()
  var minute = dueDate.getMinutes()
  return " à " + hour + " h" + (minute !== 0 ? " " + pad2(minute) : "")
}

function taskDueLabel(task) {
  if (!task || !task.due) return ""
  var label = naturalDueDateLabel(localDueDateIso(task))
  return label !== "" ? label + dueTimeLabel(task) : (task.due.string || isoDatePrefix(task.due.date))
}

function taskIsOverdue(task) {
  if (!task || !task.due || !task.due.date) return false
  return localDueDateIso(task) < todayIsoDate()
}

// Sorted task dates make these sections contiguous without adding fake rows
// to the task model (keyboard selection still addresses tasks only).
function taskDateGroup(task, today) {
  var date = localDueDateIso(task)
  if (date === "") return "Sans date"
  var reference = today || todayIsoDate()
  if (date < reference) return "En retard"
  if (date === reference) return "Aujourd’hui"
  return "À venir"
}

// Overdue/due-soonest first, undated tasks last; priority breaks ties within
// the same date, then content for a stable order.
function sortedTasks(tasks) {
  var list = (tasks || []).slice()
  list.sort(function(a, b) {
    var aDue = localDueDateIso(a)
    var bDue = localDueDateIso(b)
    if (aDue !== bDue) {
      if (aDue === "") return 1
      if (bDue === "") return -1
      return aDue < bDue ? -1 : 1
    }

    var aPriority = a && typeof a.priority === "number" ? a.priority : 1
    var bPriority = b && typeof b.priority === "number" ? b.priority : 1
    if (aPriority !== bPriority) return bPriority - aPriority

    var aContent = (a && a.content) || ""
    var bContent = (b && b.content) || ""
    return aContent < bContent ? -1 : (aContent > bContent ? 1 : 0)
  })
  return list
}

// Attach display-only parent context without changing task IDs or due dates.
// Resolve parents from the full snapshot, including parents outside this view.
function withParentContext(tasks, allTasks) {
  var byId = Object.create(null)
  ;(allTasks || []).forEach(function(task) { byId[task.id] = task })
  return (tasks || []).map(function(task) {
    var result = {}
    for (var key in task) result[key] = task[key]
    var parentId = task.parent_id || task.parent || ""
    var parent = byId[parentId]
    result.parentTitle = parent ? parent.content : ""
    result.subtaskDepth = 0
    var seen = Object.create(null)
    seen[task.id] = true
    while (parentId && !seen[parentId]) {
      seen[parentId] = true
      result.subtaskDepth++
      parent = byId[parentId]
      parentId = parent ? (parent.parent_id || parent.parent || "") : ""
    }
    return result
  })
}

// Todoist's natural-language filter uses the account/API timezone, which can
// disagree with the machine timezone used by the panel. Filter these two
// quick views locally so a task stays in the same day as its displayed time.
function tasksForView(tasks, view) {
  if (view !== "today" && view !== "tomorrow") return (tasks || []).slice()
  var today = todayIsoDate()
  var tomorrow = localDateFromIso(today)
  tomorrow.setDate(tomorrow.getDate() + 1)
  var tomorrowIso = tomorrow.getFullYear() + "-" + pad2(tomorrow.getMonth() + 1)
    + "-" + pad2(tomorrow.getDate())
  return (tasks || []).filter(function(task) {
    var dueDate = localDueDateIso(task)
    if (dueDate === "") return false
    return view === "today" ? dueDate <= today : dueDate === tomorrowIso
  })
}

// Heuristic only — Quick Add's own NLP (see /tasks/quick) does the real
// parsing server-side. This just decides whether *we* should tack on
// " today" before sending, so a bare "Buy milk" defaults to due today
// instead of no due date, without stomping on a date the user already typed
// ("tomorrow", "next Monday", "3/5", "at 5pm", a deadline in {}, etc.).
// French date expressions are included so "lavage demain" is sent unchanged
// to Todoist instead of receiving the fallback "today" suffix.
var DUE_HINT_RE = /\b(today|tonight|tomorrow|tmrw|tom|next|mon|tue|wed|thu|fri|sat|sun|monday|tuesday|wednesday|thursday|friday|saturday|sunday|jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|aujourd'hui|aujourd’hui|demain|apres-demain|après-demain|lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche|janvier|fevrier|février|mars|avril|mai|juin|juillet|aout|août|septembre|octobre|novembre|decembre|décembre)\b|\d{1,2}[\/\-]\d{1,2}|\d{1,2}\s*(am|pm)\b|\bat\s+\d|\bin\s+\d+\s*(day|week|hour|min)|(?:^|\s)à\s+\d|\b\d{1,2}(?::[0-5]\d|\s*h(?:\s*[0-5]\d)?)\b|\b(?:sans date|aucune date|no date)\b|\bdans\s+\d+\s*(jour|jours|semaine|semaines|heure|heures|minute|minutes)\b|\{[^}]*\}/i

function quickAddHasDueHint(text) {
  return DUE_HINT_RE.test(text)
}

// Relative time for the header's SYNCED stat. `epochMs` is 0 before the
// first successful fetch ever lands.
function formatRelativeTime(epochMs) {
  if (!epochMs) return "never"
  var deltaSec = Math.max(0, Math.round((Date.now() - epochMs) / 1000))
  if (deltaSec < 45) return "just now"
  var deltaMin = Math.round(deltaSec / 60)
  if (deltaMin < 60) return deltaMin + "m ago"
  var deltaHour = Math.round(deltaMin / 60)
  if (deltaHour < 24) return deltaHour + "h ago"
  var deltaDay = Math.round(deltaHour / 24)
  return deltaDay + "d ago"
}

// curl exits non-zero with an empty stdout body on HTTP errors (-f), so the
// only signal available for a friendly message is the exit code and
// whatever curl printed to stderr.
function errorMessageForExit(exitCode, stderrText) {
  var text = String(stderrText || "")
  if (text.indexOf("401") !== -1 || text.indexOf("403") !== -1)
    return "Todoist rejected the API token — check it in Settings."
  if (text.indexOf("Could not resolve host") !== -1 || text.indexOf("Couldn't connect") !== -1
    || text.indexOf("Failed to connect") !== -1 || text.indexOf("Network is unreachable") !== -1)
    return "Couldn't reach Todoist — check your connection."
  if (exitCode === 28) return "Todoist took too long to respond."
  var firstLine = text.split("\n")[0]
  return "Something went wrong talking to Todoist" + (firstLine !== "" ? (": " + firstLine) : ".")
}

// Validate each page before accepting a snapshot. Missing results must not
// silently replace the user's tasks with an empty list.
function parseTaskPage(text) {
  var parsed
  try { parsed = JSON.parse(text) } catch (e) { throw new Error("Réponse Todoist invalide.") }
  if (!parsed || !Array.isArray(parsed.results)
      || !(parsed.next_cursor === null || (typeof parsed.next_cursor === "string" && parsed.next_cursor !== ""))
      || parsed.results.some(function(task) {
        return !task || typeof task.id !== "string" || task.id === "" || typeof task.content !== "string"
      })) throw new Error("Réponse Todoist invalide.")
  return parsed
}

function curlConfigEscape(value) {
  return String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"')
    .replace(/\r/g, "\\r").replace(/\n/g, "\\n")
}
