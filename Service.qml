import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// The state behind the panel: the saved-host library on disk, the live SSH
// sessions on this machine, and the connect action.
//
// Everything that touches the outside world goes through Process with an argv
// array. A host name is user input that ends up on a command line, so it is
// never interpolated into a shell string — `ssh` is exec'd directly and a name
// like `; rm -rf ~` is just an invalid hostname.
Item {
  id: root
  property var settings: ({})

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy/sshdrops"
  readonly property string libraryPath: stateDir + "/hosts.json"
  readonly property string sshConfigPath: home + "/.ssh/config"

  property var hosts: []
  property var sessions: ({})
  property var resolved: ({})
  property bool loading: false
  property bool saving: false
  property string lastError: ""
  property bool libraryMissing: false

  readonly property bool importEnabled: setting("importTildeSshConfig", true) === true
  readonly property int sessionPollSec: intSetting("sessionPollSec", 15, 5, 300)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, minimum, maximum) {
    var value = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(value)) value = fallback
    return Math.max(minimum, Math.min(maximum, value))
  }

  // The mode a given host connects with: its own override, else the widget
  // default from shell.json.
  function modeFor(host) {
    if (host && host.mode && Model.MODES.indexOf(host.mode) !== -1) return host.mode
    var fallback = String(setting("connectMode", "shell"))
    return Model.MODES.indexOf(fallback) === -1 ? "shell" : fallback
  }

  // ------------------------------------------------------------------ library

  FileView {
    id: libraryFile
    path: root.libraryPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: root.load()
    onLoaded: root.applyLibrary(text())
    onLoadFailed: root.applyLibrary("")
  }

  function load() {
    if (saving) return
    loading = true
    // Force a re-read: FileView caches, and a library we just wrote would
    // otherwise come straight back from the cache instead of the disk.
    libraryFile.reload()
    if (!libraryFile.text()) applyLibrary(libraryFile.text())
  }

  function applyLibrary(content) {
    loading = false
    if (String(content || "").trim() === "") {
      root.hosts = []
      root.libraryMissing = true
      root.lastError = ""
      return
    }
    root.libraryMissing = false
    var parsed = Model.parseHosts(content)
    if (!parsed.ok) {
      // A library we cannot read must not be overwritten by the next save.
      // Surface it and leave the in-memory list alone.
      root.lastError = parsed.error
      return
    }
    root.lastError = ""
    root.hosts = Model.sortHosts(parsed.hosts)
    root.resolveAll()
  }

  // Write the library atomically. Creating the state directory first is the
  // only reason this touches the filesystem outside the plugin's own paths.
  function persist() {
    saving = true
    root.lastError = ""
    mkdirProcess.command = ["mkdir", "-p", root.stateDir]
    mkdirProcess.running = true
  }

  Process {
    id: mkdirProcess
    running: false
    onExited: function(exitCode) {
      root.saving = false
      if (exitCode !== 0) {
        root.lastError = "Could not create " + root.stateDir
        return
      }
      libraryFile.setText(Model.serializeHosts(root.hosts))
      root.resolveAll()
    }
  }

  function nextId(hosts) {
    var used = {}
    for (var i = 0; i < hosts.length; i++) used[hosts[i].id] = true
    var n = 1
    while (used["host-" + n]) n++
    return "host-" + n
  }

  function saveHost(host) {
    var normalized = Model.normalizeHost(host)
    if (!Model.isConnectable(normalized)) {
      root.lastError = "Set a hostname or an ssh alias before saving"
      return false
    }
    var problems = Model.validateHost(normalized)
    if (problems.length > 0) {
      root.lastError = problems[0]
      return false
    }

    var next = root.hosts.slice()
    var index = -1
    for (var i = 0; i < next.length; i++) {
      if (next[i].id === normalized.id) { index = i; break }
    }
    if (index === -1) {
      normalized.id = root.nextId(next)
      next.push(normalized)
    } else {
      next[index] = normalized
    }
    root.hosts = Model.sortHosts(next)
    persist()
    return true
  }

  function deleteHost(id) {
    var next = []
    for (var i = 0; i < root.hosts.length; i++) {
      if (root.hosts[i].id !== id) next.push(root.hosts[i])
    }
    if (next.length === root.hosts.length) return false
    root.hosts = next
    persist()
    return true
  }

  // Replace the library with the given hosts, used by the ssh_config import.
  function replaceHosts(hosts) {
    root.hosts = Model.sortHosts(hosts)
    persist()
  }

  // -------------------------------------------------------------- resolution

  // `ssh -G` answers "what would ssh actually do for this destination" without
  // connecting, which is how a row can show the jump host and port that live
  // in the user's own config rather than only the fields typed into the form.
  //
  // One process per host is a burst, so they run one at a time behind a queue
  // and the results fill in as they land.
  property var resolveQueue: []
  property string resolvingId: ""

  function resolveAll() {
    resolveQueue = []
    resolvingId = ""
    for (var i = 0; i < root.hosts.length; i++) resolveQueue.push(root.hosts[i].id)
    pumpResolveQueue()
  }

  function pumpResolveQueue() {
    if (resolveProcess.running || root.resolveQueue.length === 0) return
    var id = root.resolveQueue.shift()
    var host = hostById(id)
    if (!host) {
      Qt.callLater(root.pumpResolveQueue)
      return
    }
    var destination = Model.destinationArgs(host)
    if (destination.length === 0) {
      Qt.callLater(root.pumpResolveQueue)
      return
    }
    resolvingId = id
    resolveProcess.command = ["ssh", "-G"].concat(destination)
    resolveProcess.running = true
  }

  function hostById(id) {
    for (var i = 0; i < root.hosts.length; i++) {
      if (root.hosts[i].id === id) return root.hosts[i]
    }
    return null
  }

  Process {
    id: resolveProcess
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyResolved(text)
    }

    onExited: function() {
      root.resolvingId = ""
      Qt.callLater(root.pumpResolveQueue)
    }
  }

  function applyResolved(output) {
    var id = root.resolvingId
    if (id === "") return
    var parsed = Model.parseSshConfig(output)
    var next = {}
    for (var key in root.resolved) next[key] = root.resolved[key]
    if (parsed.ok) next[id] = parsed
    else delete next[id]
    resolved = next
  }

  // ----------------------------------------------------------------- sessions

  // Which saved hosts have a live ssh process right now. `ps` is the only
  // thing consulted: it needs no key material, opens no connection, and cannot
  // tell a server anything about the machine.
  Timer {
    id: sessionTimer
    interval: root.sessionPollSec * 1000
    repeat: true
    running: true
    triggeredOnStart: false
    onTriggered: root.refreshSessions()
  }

  Process {
    id: sessionProcess
    running: false
    command: ["ps", "-eo", "args"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySessions(text)
    }
  }

  function applySessions(output) {
    sessions = Model.liveSessionMap(root.hosts, Model.parseSessions(output))
  }

  function refreshSessions() {
    if (sessionProcess.running) return
    sessionProcess.running = true
  }

  readonly property int liveCount: {
    var count = 0
    for (var key in sessions) count++
    return count
  }

  // ------------------------------------------------------------------ connect

  // Open a terminal running ssh to this host.
  //
  // The launch goes through `xdg-terminal-exec ... -e bash -c '<script>'`
  // rather than passing the command as bare argv. That is the form Omarchy's
  // own terminal launchers use (see omarchy-launch-floating-terminal-with-
  // presentation), and it is required: `xdg-terminal-exec` only treats its
  // trailing arguments as a command when `-e` is present. Without `-e` the
  // terminal takes them as filenames to open, so ssh never runs and the new
  // window comes up empty — or, worse, reuses a tty that an existing terminal
  // is still drawing on and scrambles that window's display.
  //
  // `bash -c` then runs the command with a real PATH and a controlling tty, so
  // the password prompt, the host-key prompt, and a full-screen remote program
  // (vim, htop, tmux) all behave. Passwords are never collected, stored, or
  // passed by this plugin — ssh prompts for them in the new terminal, exactly
  // as it does on the command line, and key-based auth keeps working because
  // ssh still reads the user's own ssh config and agent.
  //
  // The host name is single-quote escaped with Util.shellQuote, so a name that
  // contains shell metacharacters lands as one literal argument.
  //
  // `shell-reconnect` runs the ssh command under `bash -ic` instead: Omarchy's
  // reconnecting `ssh()` is a bash function defined in the interactive rc
  // chain and invisible to a plain exec, so `-i` is what pulls that rc in and
  // `-c` keeps the terminal from dropping into a prompt. The wrapper then
  // disarms the terminal modes a dropped session leaves armed and retries.
  function connect(host) {
    if (!Model.isConnectable(host)) {
      root.lastError = "That host has no hostname or alias"
      return false
    }

    var destination = Model.destinationArgs(host)
    if (destination.length === 0) {
      root.lastError = "That host has no hostname or alias"
      return false
    }

    var mode = root.modeFor(host)
    // Model.connectCommand is the same helper the editor renders above the
    // form, so the command the user reads is the one that runs.
    var script = mode === "shell-reconnect"
      ? "bash -ic " + Util.shellQuote("ssh " + destination.map(Util.shellQuote).join(" "))
      : "ssh " + destination.map(Util.shellQuote).join(" ")

    Util.execArgv([
      "setsid", "uwsm-app", "--",
      "xdg-terminal-exec",
      "--app-id=org.omarchy.sshdrops",
      "--title=SSHDrops",
      "-e", "bash", "-c", script
    ])
    return true
  }

  // ------------------------------------------------------------------- import

  property var importCandidates: []
  property bool importing: false

  function importFromSshConfig() {
    if (importProcess.running) return
    importing = true
    // `ssh -G` cannot list aliases; reading the file is the only way. Missing
    // file is an ordinary state, not an error worth a dialog.
    importProcess.command = ["bash", "-c", "exec \"$@\"", "bash", "cat", root.sshConfigPath]
    importProcess.running = true
  }

  Process {
    id: importProcess
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyImport(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
    }

    onExited: function(exitCode) {
      root.importing = false
      if (exitCode !== 0) root.lastError = "Could not read " + root.sshConfigPath
    }
  }

  function applyImport(output) {
    var aliases = Model.parseSshConfigHosts(output)
    var existing = {}
    for (var i = 0; i < root.hosts.length; i++) existing[root.hosts[i].alias] = true

    var candidates = []
    for (var a = 0; a < aliases.length; a++) {
      if (existing[aliases[a]]) continue
      candidates.push({ alias: aliases[a] })
    }
    root.importCandidates = candidates
    if (candidates.length === 0) root.lastError = "No new Host aliases in " + root.sshConfigPath
  }

  // Imported hosts store nothing but the alias. OpenSSH resolves the rest from
  // the user's own config at connect time, so an import can never drift out of
  // sync with the IdentityFile or ProxyJump they actually use.
  function commitImport() {
    var next = root.hosts.slice()
    var added = 0
    for (var i = 0; i < root.importCandidates.length; i++) {
      var alias = root.importCandidates[i].alias
      var host = Model.normalizeHost({ alias: alias, name: alias })
      host.id = root.nextId(next)
      next.push(host)
      added++
    }
    root.importCandidates = []
    if (added === 0) return
    root.hosts = Model.sortHosts(next)
    persist()
  }

  Component.onCompleted: {
    root.load()
    root.refreshSessions()
  }
}
