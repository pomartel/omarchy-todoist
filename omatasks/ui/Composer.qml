import QtQuick
import QtQuick.Controls as C
import QtQuick.Layouts
import qs.Commons
import qs.Ui as UI
import "../Model.js" as Model
import "ComposerModel.js" as Draft
import "EditModel.js" as Edit
import "../../EditParser.js" as Inline

ColumnLayout {
    id: root
    objectName: "taskComposer"
    required property var service
    property var editingTask: null
    property var originalTask: null
    property var pendingCommands: []
    property var commandCache: ({})
    property var removedReminders: []
    property string replacingReminder: ""
    property string duration: "0"
    property string durationUnit: "minute"
    readonly property bool editing: editingTask !== null
    readonly property var existingReminders: editing ? service.reminders.filter(function(r) { return String(r.item_id) === String(editingTask.id) && removedReminders.indexOf(String(r.id)) < 0; }) : []
    property string initialProjectId: ""
    property string initialDue: ""
    property var project: service.projectMap[initialProjectId] || null
    property var section: null
    property var taskLabels: []
    property int priority: 0
    property string due: initialDue
    property string deadline: ""
    property string reminder: ""
    property var assignee: null
    property bool descriptionVisible: false
    property string requestId: ""
    property string sentText: ""
    property bool submitting: false
    property string message: ""
    property alias text: input.text
    property string pickerKind: ""
    property var activeToken: null
    property bool editingToken: false
    property int choiceIndex: 0
    readonly property var choices: Draft.choices(pickerKind, activeToken ? activeToken.query : search.text, service, project)
    readonly property var inbox: service.projects.find(function(p) { return p.inbox_project; }) || null
    readonly property string projectName: inlineEdit && inlineEdit.projectName ? inlineEdit.projectName : project ? project.name : "Boîte de réception"
    readonly property var inlineEdit: {
        if (!editing || !originalTask) return null;
        try { return Inline.parse(originalTask, input.text, Model.dueDay(originalTask)); } catch (e) { return null; }
    }
    readonly property var typedDate: editing ? null : Draft.dateToken(input.text)
    readonly property string shownDate: inlineEdit && inlineEdit.update.due_string !== undefined ? (inlineEdit.update.due_string === "no date" ? "Sans date" : inlineEdit.update.due_string) : typedDate ? typedDate.value : due
    signal finished()
    signal cancelled()
    spacing: Style.space(10)
    Component.onCompleted: if (editing) loadTask()

    function loadTask() {
        originalTask = JSON.parse(JSON.stringify(editingTask));
        var data = Edit.snapshot(originalTask);
        input.text = data.text; description.text = data.description; descriptionVisible = true;
        project = service.projectMap[data.projectId] || {id: data.projectId, name: "Projet"};
        section = service.sectionMap[data.sectionId] || null;
        taskLabels = data.labels; priority = data.priority; due = data.due; deadline = data.deadline;
        duration = String(data.duration); durationUnit = data.durationUnit;
        var person = Model.byId(service.collaborators)[data.assigneeId];
        assignee = data.assigneeId ? {id: data.assigneeId, name: person ? person.full_name || person.name : "Responsable"} : null;
    }
    function submitEdit() {
        var change;
        try {
            var parsed = Inline.parse(originalTask, input.text, Model.dueDay(originalTask));
            var draft = {text: parsed.update.content, description: description.text, projectId: String((project || {}).id || ""), sectionId: String((section || {}).id || ""), labels: taskLabels, priority: priority || 4, due: due, deadline: deadline, assigneeId: String((assignee || {}).id || ""), duration: duration, durationUnit: durationUnit};
            if (parsed.update.priority !== undefined) draft.priority = 5 - parsed.update.priority;
            if (parsed.update.due_string !== undefined) draft.due = parsed.update.due_string === "no date" ? "" : parsed.update.due_string;
            if (parsed.projectName) { draft.projectId = Inline.resolveProject(service.projects, parsed.projectName); if (draft.projectId !== originalTask.project_id) draft.sectionId = ""; }
            change = Edit.changes(originalTask, draft, service.now);
            if (change.update.due && parsed.update.due_lang) change.update.due.lang = parsed.update.due_lang;
        } catch (e) { message = e.message; return; }
        var specs = [], id = String(originalTask.id);
        if (change.move) specs.push({type: "item_move", args: Object.assign({id: id}, change.move)});
        if (Object.keys(change.update).length) specs.push({type: "item_update", args: Object.assign({id: id}, change.update)});
        removedReminders.forEach(function(r) { specs.push({type: "reminder_delete", args: {id: r}}); });
        if (reminder) specs.push({type: "reminder_add", args: Edit.reminderArgs(reminder, id)});
        if (!specs.length) { finished(); return; }
        var signature = JSON.stringify(specs);
        pendingCommands = specs.map(function(spec) {
            var key = JSON.stringify(spec);
            if (!root.commandCache[key]) {
                var command = Object.assign({uuid: Model.uuid()}, spec);
                if (spec.type === "reminder_add") command.temp_id = Model.uuid();
                root.commandCache[key] = command;
            }
            return root.commandCache[key];
        });
        sentText = signature; message = "";
        submitting = service.updateTask(id, pendingCommands);
        if (!submitting) message = service.error || "Attendez la fin de l’opération en cours.";
    }

    function focusInput() { input.forceActiveFocus(); }
    function reset() {
        input.text = ""; description.text = ""; descriptionVisible = false;
        project = service.projectMap[initialProjectId] || null; section = null; taskLabels = [];
        priority = 0; due = initialDue; deadline = ""; reminder = ""; assignee = null;
        pickerKind = ""; activeToken = null; requestId = ""; message = "";
    }
    function closePicker() { pickerKind = ""; activeToken = null; }
    function openPicker(kind) {
        if (pickerKind === kind && !activeToken) { closePicker(); focusInput(); return; }
        activeToken = null; search.text = ""; pickerKind = kind; choiceIndex = 0;
        Qt.callLater(function() { search.forceActiveFocus(); });
    }
    function updateToken() {
        if (editing || editingToken || !input.activeFocus) return;
        var priorityToken = /(^|\s)p([1-4])\s$/i.exec(input.text.slice(0, input.cursorPosition));
        if (priorityToken) {
            editingToken = true; priority = Number(priorityToken[2]);
            input.remove(priorityToken.index + priorityToken[1].length, input.cursorPosition);
            closePicker(); editingToken = false; return;
        }
        var token = Draft.tokenAt(input.text, input.cursorPosition);
        if (token) { activeToken = token; pickerKind = token.kind; choiceIndex = 0; }
        else if (activeToken) closePicker();
    }
    function setDate(value) {
        editingToken = true;
        if (typedDate) input.remove(typedDate.start, typedDate.end);
        due = value;
        editingToken = false;
    }
    function choose(row) {
        if (!row) return;
        var kind = pickerKind, token = activeToken;
        if (kind === "project") { project = row.value; section = null; assignee = null; }
        if (kind === "section") section = row.value;
        if (kind === "label" && taskLabels.indexOf(row.value) < 0) taskLabels = taskLabels.concat([row.value]);
        if (kind === "priority") priority = row.value;
        if (kind === "due") setDate(row.value);
        if (kind === "deadline") deadline = row.value;
        if (kind === "reminder") {
            if (replacingReminder && removedReminders.indexOf(replacingReminder) < 0) removedReminders = removedReminders.concat([replacingReminder]);
            replacingReminder = ""; reminder = row.value;
        }
        if (kind === "assignee") assignee = row.value;
        editingToken = true;
        if (token) { input.remove(token.start, token.end); input.cursorPosition = token.start; }
        closePicker(); focusInput(); editingToken = false;
    }
    function moveChoice(step) {
        if (!choices.length) return;
        choiceIndex = (choiceIndex + step + choices.length) % choices.length;
        suggestions.positionViewAtIndex(choiceIndex, ListView.Contain);
    }
    function handleKey(event) {
        if (pickerKind) {
            if (event.key === Qt.Key_Escape) { closePicker(); focusInput(); event.accepted = true; }
            else if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) { moveChoice(event.key === Qt.Key_Down ? 1 : -1); event.accepted = true; }
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Tab) { choose(choices[choiceIndex]); event.accepted = true; }
        } else if (event.key === Qt.Key_Escape) { cancelled(); event.accepted = true; }
        else if (event.key === Qt.Key_Down && input.activeFocus) { descriptionVisible = true; description.forceActiveFocus(); event.accepted = true; }
    }
    function submit() {
        if (!input.text.trim() || submitting) return;
        if (editing) { submitEdit(); return; }
        var text = Draft.quickText({text: input.text, description: description.text, project: project,
            section: section, labels: taskLabels, priority: priority, due: due,
            deadline: deadline, reminder: reminder, assignee: assignee});
        if (sentText !== text || !requestId) requestId = Model.uuid();
        sentText = text; message = "";
        submitting = service.addTask(text, requestId);
        if (!submitting) message = service.error || "Attendez la fin de l’opération en cours.";
    }

    C.TextField {
        id: input
        objectName: "taskName"
        Layout.fillWidth: true
        implicitHeight: Style.space(30)
        padding: 0; color: Color.popups.text
        font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true
        placeholderText: "Nom de la tâche"; placeholderTextColor: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.4)
        selectionColor: Color.accent; selectedTextColor: Color.popups.background
        background: Item {}
        enabled: !root.submitting
        onTextEdited: root.updateToken()
        onCursorPositionChanged: root.updateToken()
        onAccepted: if (!root.pickerKind) root.submit()
        Keys.onPressed: event => root.handleKey(event)
    }
    C.ScrollView {
        Layout.fillWidth: true
        Layout.preferredHeight: Math.min(Style.space(90), Math.max(Style.space(28), description.implicitHeight))
        visible: root.descriptionVisible || description.text !== ""
        clip: true
        contentWidth: availableWidth
        C.ScrollBar.horizontal.policy: C.ScrollBar.AlwaysOff
        C.TextArea {
            id: description
            width: parent.width
            objectName: "taskDescription"
            padding: 0; wrapMode: TextEdit.Wrap
            color: Color.popups.text
            font.family: Style.font.family; font.pixelSize: Style.font.bodySmall
            placeholderText: "Description"; placeholderTextColor: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.4)
            background: Item {}
            enabled: !root.submitting
            Keys.onPressed: function(event) {
                root.handleKey(event);
                if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) { root.submit(); event.accepted = true; }
            }
        }
    }
    Action { visible: !root.descriptionVisible; text: "Description"; implicitHeight: Style.space(22); onClicked: { root.descriptionVisible = true; description.forceActiveFocus(); } }

    Flow {
        Layout.fillWidth: true
        spacing: Style.space(6)
        enabled: !root.submitting
        Chip { text: root.shownDate || "Date"; iconName: "today"; removable: root.shownDate !== ""; maximumWidth: Math.min(root.width, Style.space(230)); onClicked: root.openPicker("due"); onRemoved: root.setDate("") }
        Chip { text: root.inlineEdit && root.inlineEdit.update.priority !== undefined ? "P" + (5 - root.inlineEdit.update.priority) : root.priority ? "P" + root.priority : "Priorité"; iconName: "flag"; foreground: root.priority > 0 && root.priority < 4 ? ["#ef615b", "#e49b40", "#5295e4"][root.priority - 1] : Color.popups.text; removable: root.priority > 0; onClicked: root.openPicker("priority"); onRemoved: root.priority = 0 }
        Chip { visible: root.deadline !== ""; text: root.deadline; iconName: "upcoming"; removable: true; onClicked: root.openPicker("deadline"); onRemoved: root.deadline = "" }
        Chip { visible: root.reminder !== ""; text: root.reminder; iconName: "bell"; removable: true; onClicked: root.openPicker("reminder"); onRemoved: root.reminder = "" }
        Chip { visible: root.section !== null; text: root.section ? "/ " + root.section.name : ""; removable: true; maximumWidth: root.width; onClicked: root.openPicker("section"); onRemoved: root.section = null }
        Chip { visible: root.assignee !== null; text: root.assignee ? "+ " + root.assignee.name : ""; removable: true; maximumWidth: root.width; onClicked: root.openPicker("assignee"); onRemoved: root.assignee = null }
        Repeater {
            model: root.taskLabels
            Chip { required property string modelData; text: modelData; iconName: "label"; removable: true; maximumWidth: root.width; onClicked: root.openPicker("label"); onRemoved: root.taskLabels = root.taskLabels.filter(function(l) { return l !== modelData; }) }
        }
        Action { iconName: "label"; tip: "Étiquettes (@)"; onClicked: root.openPicker("label") }
        Action { iconName: "more"; tip: "Autres options"; selected: more.visible; onClicked: more.visible = !more.visible }
    }
    Flow {
        id: more
        visible: false
        Layout.fillWidth: true; spacing: Style.space(6)
        Action { text: "Rappel"; iconName: "bell"; onClicked: { more.visible = false; root.replacingReminder = ""; root.openPicker("reminder"); } }
        Action { text: "Date limite"; iconName: "upcoming"; onClicked: { more.visible = false; root.openPicker("deadline"); } }
        Action { text: "Section"; enabled: root.project !== null; onClicked: { more.visible = false; root.openPicker("section"); } }
        Action { text: "Responsable"; enabled: root.project !== null && root.project.is_shared === true; onClicked: { more.visible = false; root.openPicker("assignee"); } }
    }
    ColumnLayout {
        visible: root.editing
        Layout.fillWidth: true
        spacing: Style.space(8)
        RowLayout {
            Layout.fillWidth: true
            Label { text: "Durée"; Layout.fillWidth: true }
            UI.TextField { objectName: "taskDuration"; Layout.preferredWidth: Style.space(60); text: root.duration; validator: IntValidator { bottom: 0; top: 100000 } onTextEdited: root.duration = text; enabled: !root.submitting }
            UI.Dropdown { Layout.preferredWidth: Style.space(95); showLabel: false; value: root.durationUnit; options: [{value: "minute", label: "Minutes"}, {value: "day", label: "Jours"}]; onChanged: function(value) { root.durationUnit = value; } enabled: !root.submitting }
        }
        Label { text: "0 = aucune durée"; opacity: 0.45; font.pixelSize: Style.font.caption }
        Repeater {
            model: root.existingReminders
            Chip { required property var modelData; text: Edit.reminderText(modelData); iconName: "bell"; maximumWidth: root.width; removable: !modelData.notify_uid || String(modelData.notify_uid) === String(root.service.user.id); enabled: !root.submitting; onClicked: if (removable) { root.replacingReminder = String(modelData.id); root.openPicker("reminder"); } onRemoved: root.removedReminders = root.removedReminders.concat([String(modelData.id)]) }
        }
    }

    Rectangle {
        id: picker
        visible: root.pickerKind !== ""
        Layout.fillWidth: true
        implicitHeight: pickerBody.implicitHeight + Style.space(16)
        radius: Style.cornerRadius; color: Color.popups.background; border.color: Color.popups.border; border.width: 1
        ColumnLayout {
            id: pickerBody
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: Style.space(8)
            spacing: Style.space(6)
            RowLayout {
                Layout.fillWidth: true
                Label { Layout.fillWidth: true; text: ({project: "Projet", label: "Étiquettes", section: "Section", priority: "Priorité", due: "Date", deadline: "Date limite", reminder: "Rappel", assignee: "Responsable"})[root.pickerKind] || ""; font.bold: true; font.pixelSize: Style.font.bodySmall }
                Action { iconName: "close"; iconSize: Style.space(12); tip: "Fermer le sélecteur"; onClicked: { root.closePicker(); root.focusInput(); } }
            }
            UI.TextField {
                id: search
                objectName: "pickerSearch"
                visible: !root.activeToken
                Layout.fillWidth: true
                placeholderText: root.editing && root.pickerKind === "deadline" ? "AAAA-MM-JJ" : ["due", "deadline", "reminder"].indexOf(root.pickerKind) >= 0 ? "p. ex. demain à 16h" : "Rechercher…"
                onTextEdited: root.choiceIndex = 0
                Keys.onPressed: event => root.handleKey(event)
            }
            ListView {
                id: suggestions
                objectName: "suggestions"
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(Style.space(160), contentHeight)
                clip: true; boundsBehavior: Flickable.StopAtBounds
                model: root.choices
                C.ScrollBar.vertical: C.ScrollBar {}
                delegate: C.AbstractButton {
                    id: option
                    required property var modelData
                    required property int index
                    width: suggestions.width; height: Style.space(32)
                    hoverEnabled: true
                    padding: Style.space(6)
                    contentItem: RowLayout {
                        spacing: Style.space(8)
                        ViewIcon { visible: !!option.modelData.icon; name: option.modelData.icon || ""; color: option.modelData.color || Color.popups.text }
                        Label { visible: !!option.modelData.prefix; text: option.modelData.prefix || ""; opacity: 0.6 }
                        Label { Layout.fillWidth: true; text: option.modelData.label; font.pixelSize: Style.font.bodySmall }
                        Label { Layout.maximumWidth: parent.width * 0.35; text: option.modelData.detail || ""; opacity: 0.4; font.pixelSize: Style.font.caption }
                    }
                    background: Rectangle { radius: Style.cornerRadius; color: option.hovered || root.choiceIndex === option.index ? Style.hoverFillFor(Color.popups.text, Color.accent) : "transparent" }
                    onClicked: root.choose(modelData)
                }
            }
            Label { visible: root.choices.length === 0; Layout.fillWidth: true; text: root.pickerKind === "section" && !root.project ? "Choisissez d’abord un projet." : root.pickerKind === "assignee" && (!root.project || !root.project.is_shared) ? "Choisissez d’abord un projet partagé." : "Aucun résultat"; opacity: 0.5; wrapMode: Text.WordWrap }
            Label { visible: root.pickerKind === "reminder"; Layout.fillWidth: true; text: "Les rappels avant une tâche nécessitent une heure. Leur disponibilité dépend de votre forfait Todoist."; font.pixelSize: Style.font.caption; opacity: 0.5; wrapMode: Text.WordWrap; elide: Text.ElideNone }
        }
    }
    Rectangle { Layout.fillWidth: true; height: 1; color: Color.popups.text; opacity: 0.12 }
    RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(4)
        Action { Layout.fillWidth: true; Layout.minimumWidth: 0; maximumWidth: root.width; leftAligned: true; text: (root.project && !root.project.inbox_project ? "# " : "") + root.projectName + " ▾"; iconName: !root.project || root.project.inbox_project ? "inbox" : ""; tip: "Projet (#)"; enabled: !root.submitting; onClicked: root.openPicker("project") }
        Action { text: "Annuler"; enabled: !root.submitting; onClicked: { root.reset(); root.cancelled(); } }
        Action { text: root.submitting ? (root.editing ? "Enregistrement…" : "Ajout…") : root.editing ? "Enregistrer" : "Ajouter une tâche"; selected: true; enabled: !root.service.saving && input.text.trim().length > 0; onClicked: root.submit() }
    }
    Label { Layout.fillWidth: true; visible: text !== ""; text: root.message; wrapMode: Text.WordWrap; elide: Text.ElideNone; color: Color.urgent }
    Connections {
        target: root.service
        function onTaskAdded() { if (root.submitting) { root.submitting = false; root.reset(); root.finished(); } }
        function onTaskUpdated(taskId) { if (root.editing && root.submitting && String(root.editingTask.id) === taskId) { root.submitting = false; root.finished(); } }
        function onOperationFailed(message) { if (root.submitting) { root.submitting = false; root.message = message; root.focusInput(); } }
    }
}
