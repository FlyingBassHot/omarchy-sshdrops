import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// SSHDrops: a bar button that opens a panel of saved SSH hosts. Type to
// filter, Enter to connect, e to edit, a to add, x to delete.
Panel {
  id: root
  moduleName: "io.github.flyingbasshot.sshdrops"
  ipcTarget: "io.github.flyingbasshot.sshdrops"
  // This plugin declares its own handler below so it can expose read-only
  // introspection calls alongside the lifecycle ones; the base class would
  // otherwise claim the same target first.
  manageIpc: false

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool showLabel: setting("showLabel", true) !== false

  // Three views share one panel. Only one is ever visible, and the list is
  // the resting state so closing the editor always lands somewhere useful.
  property string view: "list"
  property string query: ""
  property int cursorIndex: 0
  property var editing: Model.emptyHost()
  property string deleteTargetId: ""
  property bool importOpen: false

  readonly property var results: Model.filterHosts(service.hosts, query, service.sessions)
  readonly property var selected: results.length > 0
    ? results[Math.max(0, Math.min(cursorIndex, results.length - 1))].host
    : null
  readonly property bool editorBlocked: view === "editor" || deleteTargetId !== "" || importOpen

  // Key state for the host being edited. An unsaved new host has no probe yet,
  // so the section stays quiet until one is saved.
  readonly property string editorKeyState: editing.id === "" ? "" : (service.keyStates[editing.id] || "")
  readonly property bool editorNeedsKey: editorKeyState === "password"
  readonly property string editorKeyHint: {
    if (editorKeyState === "") return "Save this host to check whether it accepts your key."
    var hint = Model.keyStateHint(editorKeyState)
    return hint === "" ? "" : hint + "."
  }

  function clampCursor() {
    if (results.length === 0) {
      cursorIndex = 0
      return
    }
    cursorIndex = Math.max(0, Math.min(cursorIndex, results.length - 1))
  }

  function moveCursor(delta) {
    if (results.length === 0) return
    cursorIndex = (cursorIndex + delta + results.length) % results.length
  }

  function connectSelected() {
    if (!selected) return
    service.connect(selected)
    root.close()
  }

  function openEditor(host) {
    root.editing = host ? Model.normalizeHost(host) : Model.emptyHost()
    root.view = "editor"
  }

  function closeEditor() {
    root.editing = Model.emptyHost()
    root.view = "list"
    root.clampCursor()
  }

  function saveEditor() {
    if (!service.saveHost(root.editing)) return
    root.closeEditor()
  }

  function requestDelete(host) {
    if (!host) return
    root.deleteTargetId = host.id
  }

  function confirmDelete() {
    service.deleteHost(root.deleteTargetId)
    root.deleteTargetId = ""
    root.clampCursor()
  }

  function cancelDelete() {
    root.deleteTargetId = ""
  }

  function deletingHost() {
    if (root.deleteTargetId === "") return null
    return service.hostById(root.deleteTargetId)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    // Sessions go stale while the panel is closed, and so does the resolved
    // config when the user edits ~/.ssh/config in another window. The key
    // check opens a real connection per host, so it only runs when the panel
    // is actually being looked at rather than on the poll timer.
    service.refreshSessions()
    service.resolveAll()
    service.probeKeys()
    clampCursor()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  onResultsChanged: clampCursor()

  Service {
    id: service
    settings: root.settings
  }

  Connections {
    target: service
    function onLastErrorChanged() { if (service.lastError !== "") root.clampCursor() }
  }

  // Replaces the base handler wholesale (see manageIpc above), so the
  // lifecycle calls the bar and the shell rely on are all here.
  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { service.refreshSessions(); return "ok" }
    function checkKeys(): string { service.probeKeys(); return "ok" }
    function keyStates(): string { return JSON.stringify(service.keyStates) }
    function deployKey(id: string): string { return JSON.stringify(service.deployKey(service.hostById(id))) }
    function hosts(): string { return JSON.stringify(service.hosts) }
    function sessions(): string { return JSON.stringify(service.sessions) }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    fixedWidth: vertical ? -1 : content.implicitWidth + Style.space(16)
    // The visible content is the Row below, not WidgetButton's own text
    // label. Without this the base class treats the button as empty and
    // hides it: `visible: hasVisualContent` where the default is
    // `text !== ""`.
    hasVisualContent: true
    tooltipText: service.hosts.length > 0
      ? "SSHDrops · " + service.hosts.length + (service.hosts.length === 1 ? " host" : " hosts")
        + (service.liveCount > 0 ? " · " + service.liveCount + " live" : "")
      : "SSHDrops · no hosts saved yet"
    active: service.liveCount > 0
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton || buttonCode === Qt.MiddleButton) service.refreshSessions()
      else root.toggle()
    }

    Row {
      id: content
      anchors.centerIn: parent
      spacing: Style.space(5)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "󰣀"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }

      Text {
        visible: root.showLabel && !(bar ? bar.vertical : false) && service.hosts.length > 0
        anchors.verticalCenter: parent.verticalCenter
        text: service.hosts.length + (service.liveCount > 0 ? "·" + service.liveCount : "")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(body.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editorBlocked

      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.connectSelected()
      onCloseRequested: {
        if (root.view !== "list") root.closeEditor()
        else if (root.importOpen) root.importOpen = false
        else root.close()
      }
      onDeleteRequested: if (root.selected && root.view === "list") root.requestDelete(root.selected)
      onTabRequested: function(direction) { root.switchPanel(direction) }

      onTextKey: function(text) {
        var key = text.toLowerCase()
        if (root.importOpen) {
          if (key === "i") { service.commitImport(); root.importOpen = false }
          return
        }
        if (root.view !== "list") return
        if (key === "a") root.openEditor(null)
        else if (key === "e") root.openEditor(root.selected)
        else if (key === "r") service.refreshSessions()
        else if (key === "i" && service.importEnabled) {
          service.importFromSshConfig()
          root.importOpen = true
        }
        else if (key === "k" && root.selected && (service.keyStates[root.selected.id] || "") === "password")
          service.deployKey(root.selected)
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: body.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: body.implicitHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: body
          width: flick.width
          spacing: Style.space(10)

          PanelHero {
            width: parent.width
            title: "SSHDrops"
            meta: service.hosts.length === 0
              ? "No hosts saved yet"
              : service.hosts.length + (service.hosts.length === 1 ? " host" : " hosts")
                + (service.liveCount > 0 ? " · " + service.liveCount + " live" : "")
            detail: root.view === "editor" ? "Editing" : (root.deleteTargetId !== "" ? "Confirm delete" : "")
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: "󰣀"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // ------------------------------------------------------------- list

          Column {
            visible: root.view === "list"
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: search
              width: parent.width
              foreground: root.foreground
              placeholderText: service.hosts.length > 0
                ? "Filter hosts…"
                : "Press A to add your first host"
              text: root.query
              verticalPadding: Style.space(4)
              onTextChanged: {
                root.query = text
                root.cursorIndex = 0
              }
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Down) {
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
              }
            }

            Text {
              visible: service.lastError !== ""
              width: parent.width
              text: service.lastError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              visible: root.query !== "" && root.results.length === 0
              width: parent.width
              text: "No host matches \"" + root.query + "\""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.results

                HostRow {
                  required property var modelData
                  required property int index
                  width: parent.width
                  host: modelData.host
                  live: modelData.live
                  sessionCount: modelData.sessionCount
                  resolvedInfo: service.resolved[modelData.host.id] || null
                  keyState: service.keyStates[modelData.host.id] || ""
                  selected: root.cursorIndex === index
                  rowColor: root.foreground
                  onActivated: {
                    root.cursorIndex = index
                    root.connectSelected()
                  }
                  onEditRequested: {
                    root.cursorIndex = index
                    root.openEditor(modelData.host)
                  }
                  onDeleteRequested: {
                    root.cursorIndex = index
                    root.requestDelete(modelData.host)
                  }
                  onDeployKeyRequested: {
                    root.cursorIndex = index
                    service.deployKey(modelData.host)
                    root.close()
                  }
                }
              }
            }

            Text {
              visible: service.hosts.length > 0 && root.query === ""
              width: parent.width
              text: "↑↓ move · Enter connect · E edit · A add · X delete · R refresh"
                + (service.importEnabled ? " · I import" : "")
                + " · K deploy key"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              horizontalAlignment: Text.AlignHCenter
            }
          }

          // ----------------------------------------------------------- import

          Column {
            visible: root.importOpen
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "IMPORT FROM ~/.ssh/config"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              text: service.importing
                ? "Reading…"
                : (service.importCandidates.length === 0
                    ? "No new Host aliases found. Press Escape to close."
                    : service.importCandidates.length + " new alias"
                      + (service.importCandidates.length === 1 ? "" : "es")
                      + " found. Imported hosts keep only the alias, so OpenSSH still applies your IdentityFile, ProxyJump, and Match rules.")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Column {
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: service.importCandidates

                delegate: Text {
                  required property var modelData
                  width: parent.width
                  text: "  " + modelData.alias
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
              }
            }

            Text {
              visible: service.importCandidates.length > 0
              width: parent.width
              text: "Press I to import them"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }
          }

          // ----------------------------------------------------------- editor

          Column {
            visible: root.view === "editor"
            width: parent.width
            spacing: Style.space(8)

            Text {
              width: parent.width
              text: root.editing.id === "" ? "New host" : "Editing " + Model.displayName(root.editing)
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              elide: Text.ElideRight
            }

            // The exact command that will run, kept in sync with
            // Service.connect by sharing Model.connectCommand. Showing it is
            // what makes an alias silently overriding a hostname visible
            // instead of something the user discovers as a window that closes
            // instantly.
            Rectangle {
              width: parent.width
              height: commandText.implicitHeight + Style.space(12)
              radius: Style.cornerRadius
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
              border.width: 1
              border.color: root.dim

              Text {
                id: commandText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Style.space(6)
                textFormat: Text.PlainText
                text: root.editing.alias !== "" || root.editing.host !== ""
                  ? "Will run:  " + Model.connectCommand(root.editing, service.modeFor(root.editing))
                  : "Fill in a hostname or an ssh alias to connect"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            // Filling both fields is how the plugin ended up ignoring a
            // perfectly good hostname. Say which one wins, and offer the fix.
            Rectangle {
              visible: root.editing.alias !== "" && root.editing.host !== ""
              width: parent.width
              height: conflictBody.implicitHeight + Style.space(16)
              radius: Style.cornerRadius
              color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.10)
              border.width: 1
              border.color: root.urgent

              Column {
                id: conflictBody
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Style.space(8)
                spacing: Style.space(6)

                Text {
                  width: parent.width
                  text: "Both an alias and a hostname are set. The alias wins, and ssh will look up \"" + root.editing.alias + "\" in ~/.ssh/config."
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }

                Text {
                  width: parent.width
                  text: Model.aliasLooksUndefined(root.editing, service.resolved[root.editing.id])
                    ? "\"" + root.editing.alias + "\" is not defined in ~/.ssh/config, so ssh will treat it as a hostname and fail to resolve it. Clear the alias to use " + (root.editing.host || "the hostname") + " instead."
                    : "Leave it only if that alias is really what you want to connect through."
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }

                Button {
                  width: implicitWidth
                  height: Style.spacing.controlHeight
                  text: "Clear the alias, use " + (root.editing.host || "the hostname")
                  foreground: root.foreground
                  onClicked: {
                    var next = Model.normalizeHost(root.editing)
                    next.alias = ""
                    root.editing = next
                  }
                }
              }
            }

            // Key authentication is the answer to "stop asking me for a
            // password", and the fix is one click rather than a stored
            // secret. The password itself is typed by the user into
            // ssh-copy-id's prompt in a real terminal and never passes
            // through this plugin.
            Rectangle {
              visible: root.editing.aliasMissing === false && Model.isConnectable(root.editing)
              width: parent.width
              height: keyBody.implicitHeight + Style.space(16)
              radius: Style.cornerRadius
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
              border.width: 1
              border.color: root.dim

              Column {
                id: keyBody
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Style.space(8)
                spacing: Style.space(6)

                Text {
                  width: parent.width
                  text: root.editorKeyHint
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }

                Button {
                  width: implicitWidth
                  height: Style.spacing.controlHeight
                  visible: root.editorNeedsKey
                  text: "Deploy my SSH key"
                  tooltipText: "Runs ssh-copy-id. You type the password once, in a terminal. Nothing is stored."
                  foreground: root.foreground
                  onClicked: { service.deployKey(root.editing); root.close() }
                }
              }
            }

            EditorField {
              width: parent.width
              label: "Name"
              placeholder: "Optional label shown in the panel"
              value: root.editing.name
              textColor: root.foreground
              onEdited: function(value) {
                var next = Model.normalizeHost(root.editing)
                next.name = value
                root.editing = next
              }
            }

            EditorField {
              width: parent.width
              label: "SSH alias — optional, only if ~/.ssh/config defines it"
              placeholder: "Leave empty unless you have a Host alias"
              value: root.editing.alias
              textColor: root.foreground
              onEdited: function(value) {
                var next = Model.normalizeHost(root.editing)
                next.alias = value
                root.editing = next
              }
            }

            EditorField {
              width: parent.width
              label: "Hostname"
              placeholder: "example.com"
              value: root.editing.host
              textColor: root.foreground
              onEdited: function(value) {
                var next = Model.normalizeHost(root.editing)
                next.host = value
                root.editing = next
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              EditorField {
                width: (parent.width - Style.space(8)) * 0.6
                label: "User"
                placeholder: "root"
                value: root.editing.user
                textColor: root.foreground
                onEdited: function(value) {
                  var next = Model.normalizeHost(root.editing)
                  next.user = value
                  root.editing = next
                }
              }

              EditorField {
                width: (parent.width - Style.space(8)) * 0.4
                label: "Port"
                placeholder: "22"
                value: root.editing.port
                textColor: root.foreground
                onEdited: function(value) {
                  var next = Model.normalizeHost(root.editing)
                  next.port = value
                  root.editing = next
                }
              }
            }

            EditorField {
              width: parent.width
              label: "Group"
              placeholder: "Optional, used for sorting"
              value: root.editing.group
              textColor: root.foreground
              onEdited: function(value) {
                var next = Model.normalizeHost(root.editing)
                next.group = value
                root.editing = next
              }
            }

            EditorField {
              width: parent.width
              label: "Notes"
              placeholder: "Optional, searchable"
              value: root.editing.notes
              textColor: root.foreground
              onEdited: function(value) {
                var next = Model.normalizeHost(root.editing)
                next.notes = value
                root.editing = next
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                width: (parent.width - Style.space(16)) / 3
                height: Style.spacing.controlHeight
                text: "Save"
                foreground: root.foreground
                onClicked: root.saveEditor()
              }

              Button {
                width: (parent.width - Style.space(16)) / 3
                height: Style.spacing.controlHeight
                text: "Cancel"
                foreground: root.dim
                onClicked: root.closeEditor()
              }

              Button {
                width: (parent.width - Style.space(16)) / 3
                height: Style.spacing.controlHeight
                text: "Reconnect"
                tooltipText: service.modeFor(root.editing) === "shell-reconnect"
                  ? "Connects through Omarchy's reconnecting ssh() wrapper"
                  : "Connects with ssh directly"
                foreground: root.dim
                enabled: Model.isConnectable(root.editing)
                onClicked: { service.connect(root.editing); root.close() }
              }
            }

            Text {
              visible: service.lastError !== ""
              width: parent.width
              text: service.lastError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          // ------------------------------------------------------------ delete

          Column {
            visible: root.deleteTargetId !== ""
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "REMOVE HOST"
              foreground: root.urgent
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              text: root.deletingHost() ? Model.displayName(root.deletingHost()) : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: "This only removes the entry from your library. It never touches ~/.ssh/config, and it cannot kill a session you already have open."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                width: (parent.width - Style.space(8)) / 2
                height: Style.spacing.controlHeight
                text: "Remove"
                foreground: root.urgent
                onClicked: root.confirmDelete()
              }

              Button {
                width: (parent.width - Style.space(8)) / 2
                height: Style.spacing.controlHeight
                text: "Keep"
                foreground: root.dim
                onClicked: root.cancelDelete()
              }
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------------ rows

  component HostRow: CursorSurface {
    id: hostRow
    signal activated()
    signal editRequested()
    signal deleteRequested()
    signal deployKeyRequested()

    required property var host
    property bool live: false
    property int sessionCount: 0
    property var resolvedInfo: null
    property string keyState: ""
    property bool selected: false
    property color rowColor: Color.foreground

    readonly property string subtitleText: Model.subtitle(host, resolvedInfo)
    readonly property string sessionLabel: live ? sessionCount + "▸" : ""
    // An alias that ssh does not resolve would otherwise open a terminal that
    // exits instantly with "Could not resolve hostname", which reads as the
    // plugin being broken. Say so on the row instead.
    readonly property bool aliasMissing: Model.aliasLooksUndefined(host, resolvedInfo)
    readonly property bool needsKey: keyState === "password" && !aliasMissing

    hasCursor: selected
    current: selected
    foreground: rowColor
    fill: Qt.rgba(rowColor.r, rowColor.g, rowColor.b, 0.08)
    currentFill: Style.selectedFillFor(rowColor, Color.accent)

    implicitHeight: row.implicitHeight + Style.spacing.xxl

    function activate() { hostRow.activated() }
    function edit() { hostRow.editRequested() }
    function remove() { hostRow.deleteRequested() }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: hostRow.activate()
      onDoubleClicked: hostRow.edit()
    }

    RowLayout {
      id: row
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      // A live session is the one piece of state worth coloring: it is the
      // difference between "saved" and "you are already there".
      Rectangle {
        Layout.alignment: Qt.AlignVCenter
        width: Style.space(6)
        height: width
        radius: width / 2
        color: hostRow.live ? root.foreground : "transparent"
        border.width: hostRow.live ? 0 : 1
        border.color: root.dim

        SequentialAnimation on opacity {
          running: hostRow.live
          NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
          NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutQuad }
          loops: Animation.Infinite
        }
        onOpacityChanged: if (!hostRow.live) opacity = 1.0
      }

      // One flat row, not a RowLayout nested in a ColumnLayout. Nesting two
      // fill-width layouts here left the host name squeezed to zero width
      // whenever the group tag appeared. A single row with an explicit
      // spacer gives the name exactly the space the tags do not use.
      Item {
        Layout.fillWidth: true
        Layout.fillHeight: true
        implicitHeight: nameText.implicitHeight + Style.space(1) + subtitleText.implicitHeight

        Text {
          id: nameText
          anchors.left: parent.left
          anchors.right: trailing.left
          anchors.rightMargin: Style.space(6)
          anchors.top: parent.top
          textFormat: Text.PlainText
          text: Model.displayName(hostRow.host)
          color: hostRow.rowColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: hostRow.live
          elide: Text.ElideRight
        }

        Row {
          id: trailing
          anchors.right: parent.right
          anchors.top: parent.top
          spacing: Style.space(6)

          Text {
            visible: hostRow.host.group !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: hostRow.host.group
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: hostRow.sessionLabel !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: hostRow.sessionLabel
            color: hostRow.rowColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        Text {
          id: subtitleText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: nameText.bottom
          anchors.topMargin: Style.space(1)
          visible: text !== ""
          textFormat: Text.PlainText
          // When both fields are set and the alias resolves to nothing, the
          // user is one click from a connection that cannot work. Name the
          // fix rather than leaving them to work out which field won.
          text: hostRow.aliasMissing
            ? "\"" + hostRow.host.alias + "\" is not in ~/.ssh/config — connecting would fail. Edit to clear it."
            : hostRow.subtitleText
          color: hostRow.aliasMissing ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        Layout.alignment: Qt.AlignVCenter
        visible: hostRow.needsKey
        iconText: "󰌆"
        tooltipText: "Deploy your SSH key so this host connects without a password"
        foreground: hostRow.rowColor
        onClicked: hostRow.deployKeyRequested()
      }

      PanelActionButton {
        Layout.alignment: Qt.AlignVCenter
        iconText: "󰅐"
        tooltipText: "Edit · E"
        foreground: hostRow.rowColor
        onClicked: hostRow.edit()
      }

      PanelActionButton {
        Layout.alignment: Qt.AlignVCenter
        iconText: "󰅃"
        tooltipText: "Remove · X"
        foreground: hostRow.rowColor
        onClicked: hostRow.remove()
      }
    }
  }

  component EditorField: Column {
    id: field
    signal edited(string value)

    property string label: ""
    property string placeholder: ""
    property string value: ""
    property color textColor: Color.foreground

    spacing: Style.space(3)

    Text {
      text: field.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    TextField {
      width: parent.width
      foreground: field.textColor
      placeholderText: field.placeholder
      text: field.value
      verticalPadding: Style.space(4)
      onTextChanged: field.edited(text)
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.saveEditor()
          event.accepted = true
        }
      }
    }
  }
}
