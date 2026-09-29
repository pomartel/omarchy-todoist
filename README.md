<div align="center">

<img src="assets/todoist-icon.svg" width="72" height="72" alt="">

# Todoist for Omarchy

**A keyboard-first [Todoist](https://www.todoist.com/) bar widget for [Omarchy](https://omarchy.org/).**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2FAryan-Techie%2Fomarchy-todoist%2Fmain%2Fmanifest.json&query=%24.version&label=version&color=informational)](manifest.json)
[![Omarchy plugin](https://img.shields.io/badge/omarchy-plugin-6d4aff)](https://omarchy.org/)
[![Validate](https://github.com/Aryan-Techie/omarchy-todoist/actions/workflows/validate.yml/badge.svg)](https://github.com/Aryan-Techie/omarchy-todoist/actions/workflows/validate.yml)
[![Contributions welcome](https://img.shields.io/badge/contributions-welcome-brightgreen.svg)](CONTRIBUTING.md)

<a href="https://www.producthunt.com/products/todoist-for-omarchy?embed=true&utm_source=badge-featured&utm_medium=badge&utm_campaign=badge-todoist-for-omarchy" target="_blank" rel="noopener noreferrer"><img alt="Todoist for Omarchy - Your Todoist tasks, one keystroke away on Omarchy | Product Hunt" width="250" height="54" src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=1224750&theme=neutral&t=1786952170504"></a>

*Part of the [AROICE](https://aroice.in) family of tools.*

[Features](#features) • [Install](#install) • [Usage](#usage) • [Contributing](#contributing) • [Case Study](https://www.aryantechie.com/work/omarchy-todoist-plugin)

</div>

![Todoist for Omarchy — your Todoist tasks, one keystroke away in Omarchy's top bar](assets/hero-banner.jpg)

The bar shows how many tasks are due today or overdue; click it for a popup
with the full list, a checkbox to complete each task, and a box to quickly
add new ones — all without leaving the keyboard.

📖 Read the [case study](https://www.aryantechie.com/work/omarchy-todoist-plugin)
for the story behind this plugin — why it exists, the keyboard-first design
constraints, and a few things that didn't work the first time.

![Todoist panel showing the Today view, color-coded by priority](preview.png)

## Contents

- [Features](#features)
- [Install](#install)
- [Setup](#setup)
- [Usage](#usage)
  - [Keyboard controls](#keyboard-controls)
- [External dependencies and system-level modifications](#external-dependencies-and-system-level-modifications)
- [State files](#state-files)
- [Uninstalling](#uninstalling)
- [Todoist API](#todoist-api)
- [Contributing](#contributing)
- [Getting help](#getting-help)
- [Changelog](#changelog)
- [License](#license)
- [Author](#author)

## Features

- Bar pill shows a theme-colored Todoist mark, matching the look of the
  built-in Wi-Fi/Bluetooth panels. Hover it for your current task count, or
  turn on **Settings → Bar Count** to show a live Today/Sans date/total count
  right on the icon.
- Panel lists matching tasks, sorted by date group and manual order (then due date and priority), color-coded
  by Todoist priority (**p1 red, p2 yellow, p3 blue, p4 normal**). Tasks are grouped
  under **En retard**, **Aujourd’hui**, **À venir**, and **Sans date**, with
  empty groups omitted. Today rows omit a redundant date label but retain
  any due time. Bientôt shows tomorrow through six days from today
  (excluding today), grouped under Demain and then French weekday headings.
  Only days containing tasks are shown. Rows keep due times but omit repeated
  date labels; subtasks remain under their parent’s day. Secondary text
  and placeholders use a higher-contrast version of the theme foreground.
- Click the circle next to a task to mark it complete. The row is struck
  through immediately and removed after server confirmation and a short delay.
  Failed actions stay visible with an error; edits and deletions wait for confirmation.
- Quick-add box uses Todoist's own Quick Add parser — `p1`–`p4` priority,
  `#Project`, `@label`, and natural-language due dates (`tomorrow at 5pm`,
  `next Monday`) all work exactly like typing into Todoist itself. A bare
  task with no date in it (`Buy milk`) defaults to today in Today and tomorrow in Bientôt; Sans date leaves it undated. Explicit `sans date` is preserved.
- **Aujourd’hui / Bientôt / Sans date** quick-view tabs above the list.
- Drag task text to reorder within a group. Main tasks move with their subtasks;
  subtasks reorder among siblings without changing parents. Manual order is saved
  through Todoist's [day-order API](https://developer.todoist.com/api/v1/).
- Drop on **Aujourd’hui** to schedule today, **Bientôt** for tomorrow, or **Sans date** to
  remove the due date. In Bientôt, drop on another day heading or a main task in
  that section to schedule that day. A date drop updates only the dragged task;
  subtasks still appear under their parent. Dragging near the list edges scrolls;
  **Escape** or dropping outside a destination cancels. Failed saves show an error
  and reload the server state.
- Settings view (gear icon) to paste your API token and manage the above.
- Refreshes immediately whenever you open the popup, and whenever you add,
  complete, edit, or delete a task — not just on a timer. Otherwise polls
  every 2 minutes while the popup's open, or every 20 minutes in the
  background while it's closed (never both at once). Overlapping refresh
  requests are coalesced. All pages are fetched before publishing a snapshot;
  Aujourd’hui, Bientôt, Sans date, and the bar count share those results.
  Sans date shows undated main tasks from every project with their subtasks. Active subtasks are included in views and counts,
  nested compactly beneath their parent, with indentation instead of repeated
  parent names, including undated subtasks and deeper
  descendants. The main task determines the view and date group for its whole
  subtree; any distinct subtask due dates remain visible on the rows. Counts
  include every displayed task and subtask. Stored due dates are unchanged.
- Matches whatever Omarchy theme you're running — the panel pulls its
  colors from the shell's own theme system, so it looks native under light,
  dark, or any custom accent color, with no separate config to keep in sync.

![The panel rendered under several different Omarchy themes, showing it automatically picks up each theme's colors](assets/theme-support.jpeg)

## Install

```
omarchy plugin add https://github.com/aryan-techie/omarchy-todoist.git --enable
```

Add the bar icon (skip this if `--enable` already placed it):

```
omarchy bar put omarchy-todoist --section right
```

## Setup

1. Open the panel (click the bar icon) — with no token saved it opens
   straight to Settings.
2. In Todoist, go to **Settings → Integrations → Developer** and copy your
   personal API token.
3. Paste it into the field and click **Save token**.

That's it — the panel switches to your task list and the bar icon lights up.

The panel drops right below its bar icon (not centered on the bar), at a
fixed size you control — see **Settings → Advanced** below. Content that
doesn't fit scrolls inside the panel instead of resizing it. The bar icon
itself is a fixed-size slot regardless of task count, so the panel's anchor
point never shifts as your count changes.

## Usage

- **Open/close**: click the bar icon or run
  `omarchy-shell shell toggle omarchy-todoist`.
- Click **Aujourd’hui**, **Bientôt**, or **Sans date** to switch views.
- Click a task's circle to mark it complete.
- Inline edits parse added metadata: `Réviser demain à 17h p1 #Travail`,
  `Review next Monday at 5pm p2 #"Work projects"`, or `#Work\ projects`.
  A preview shows recognized fields before Enter saves. Common French/English
  days, relative dates, recurring dates, ISO dates, and times are supported;
  use `date:"every last Friday at 2pm"` for other Todoist date expressions.
  `sans date` / `no date` clears the due date. Time-only edits retain the current
  day (or recurring schedule). Unspecified metadata and existing literal
  keywords stay unchanged; quoted prose and Markdown links remain literal.
  Project names must match exactly (case-insensitive) and uniquely. Moving a
  task to another project makes it a root task there, with its descendants.
  Failed edits restore the draft; if the content saves but the project move
  fails, the error explicitly reports that partial result.
- Task titles render Markdown links. Ctrl-click a link to open it in your
  default browser; a plain click selects the task.
- Type in the box at the top of the list and press Enter (or click **Add**)
  to create a task — see Quick Add syntax above (`p1`, `#Project`, dates).
- The gear icon (or `p`) opens Settings, organized into **Account**,
  **Bar Count**, **General** (Refresh now, Keyboard shortcuts), and
  **Advanced** (popup size) sections.
- Middle-click the bar icon to refresh without opening the panel, or press
  `r` while the panel's open.

### Keyboard controls

The whole panel is operable without a mouse:

| Key | Action |
| --- | --- |
| `Escape` | Back out of Settings to the task list (works from any Settings field too); press again to close the panel. While the Add-a-task box has focus, just leaves the box instead |
| `Tab` / `Shift+Tab` | Cycle Aujourd’hui → Bientôt → Sans date. Inside Settings, instead walks every control in order — token field, Save/Remove token, bar count, and the General/Advanced buttons and steppers — scrolling as needed to keep the focused control in view |
| `a` / `d` / `i` | Jump straight to Aujourd’hui, Bientôt, or Sans date. Inside Settings, `t` opens Todoist in the browser |
| `Ctrl` + `a` / `d` / `i` | For the selected task, set its due date to today, tomorrow, or none |
| `p` | Toggle Settings open/closed |
| `↑`/`↓` or `k`/`j` | Move the selection up/down the task list |
| `Enter` or `e` | Edit the selected task and inline metadata; Enter saves while editing |
| `Space` | Complete the selected task |
| `o` | Open the selected task's page in Todoist, then close the panel |
| `x` | Delete the selected task immediately |
| `q` | Jump into the Add-a-task box |
| `r` | Refresh |
| `?` | Toggle a shortcuts cheat-sheet overlay (also a button in Settings) |

Completing a task strikes it through and dims it for a moment before it
disappears from the list, so the click reads as "done" rather than "vanished."

Typing in the token or quick-add fields temporarily suspends these so normal
typing works. `x` for delete matches
this shell's own convention (see `Ui/PanelKeyCatcher.qml`) rather than the
physical Delete key, which has no printable character for a panel's key
handler to see.

## External dependencies and system-level modifications

This plugin requires `curl` and Python 3. API requests run through
Quickshell's `Process`; `settings.py` uses Python's standard library for
private, atomic settings writes. The token is passed through stdin, never
command arguments. Curl's default configuration file is disabled.
Requests go to `https://api.todoist.com/api/v1/` over HTTPS.

Opening Todoist uses `xdg-open` from Settings or
`omarchy-launch-webapp` for a selected task. The task URL is always launched,
even when Todoist is already open; this may create another webapp window. Ctrl-clicking a task
link opens its HTTP(S) URL with the desktop URL handler. Nothing runs with
elevated privileges, and the plugin does not edit keyboard bindings.

Adding/removing the bar icon only touches your own `~/.config/omarchy/shell.json` bar
layout, the same as any other bar widget you add or remove through
`omarchy bar`.

## State files

- `~/.local/state/omarchy/omarchy-todoist/settings.json` —
  your Todoist API token, quick-view, bar count, and popup size. Created
  at startup inside a mode `700` directory. Each write uses a mode `600`
  temporary file and an atomic replacement; save failures appear in the panel.
  Use **Remove token** in Settings to disconnect immediately, or delete the
  file and restart the shell. Settings changes do not reload from disk live.

## Uninstalling

`omarchy plugin remove omarchy-todoist` removes the plugin
files but does **not** delete the state directory; remove it separately if you
want your token gone too.

## Todoist API

Uses the [Todoist API v1](https://developer.todoist.com/api/v1/):
`GET /tasks` with cursor pagination for one shared active-task snapshot
across every project. Mutations are serialized: `POST
/tasks/quick` (Quick Add, natural-language parsing) for new tasks, `POST
/tasks/{id}` to edit a task's title or due date, `POST /tasks/{id}/close` to complete,
`DELETE /tasks/{id}` to delete. `o` opens
`https://app.todoist.com/app/task/{id}` in your Todoist webapp. The older
REST API v2 was retired by Todoist in February 2026, so this plugin only
supports the current API.

For a credential-free health check, run
`qs ipc -p /usr/share/omarchy/shell call omarchy-todoist status`.
It reports connection presence, loading state, last successful sync, task count,
and whether an error is present; it does not expose the token or task content.

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for the project layout, conventions, and how to test a change locally before opening a PR. This project follows a [Code of Conduct](CODE_OF_CONDUCT.md).

## Getting help

- **Found a bug?** [Open an issue](https://github.com/Aryan-Techie/omarchy-todoist/issues/new/choose) using the bug report template — it'll ask for the couple of details (plugin version, `qs log` output) that make it fixable quickly.
- **Want a feature?** [Open a feature request](https://github.com/Aryan-Techie/omarchy-todoist/issues/new/choose).
- **Found a security issue?** Please don't open a public issue — see [SECURITY.md](SECURITY.md) for how to report it privately.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for what's changed in each version.

## License

MIT — see [LICENSE](LICENSE). The Todoist icon used above is a third-party
asset under a separate license — see [assets/NOTICE.md](assets/NOTICE.md).

## Author

**Aryan Techie** ([Aryan Jangra](https://aryan.aroice.in))

- 🌐 Website: [aryan.aroice.in](https://aryan.aroice.in)
- 📧 Email: [aryan@aroice.in](mailto:aryan@aroice.in)
- 🐙 GitHub: [@Aryan-Techie](https://github.com/Aryan-Techie)
- 🏢 Organization: [AROICE](https://aroice.in)

---

<div align="center">

**Made with ❤️ by [AROICE](https://github.com/AROICE-HQ)**

*Clear tools for a clear mind.*

</div>
