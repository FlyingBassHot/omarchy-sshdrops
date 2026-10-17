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
  // True only between a real save and the chmod that follows it, so a failing
  // file-mode fix is reported for a write we performed and not for a startup
  // pass over a file that may not exist yet.
  property bool verifyFileMode: false
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
    // Keep the library owner-only after every write, not just the first.
    onSaved: Qt.callLater(function() { fileModeProcess.running = true })
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
  //
  // The library names private infrastructure — hostnames, users, ports, and
  // free-text notes — so both the directory and the file are restricted to the
  // owner. A plain `mkdir -p` under a umask of 022 leaves a 0755 directory and
  // an atomic write leaves a 0644 file, which any other local user could read.
  // The directory is tightened before anything is written into it, so there is
  // no window in which the file is both present and reachable by someone else.
  function persist() {
    saving = true
    verifyFileMode = false
    root.lastError = ""
    mkdirProcess.running = true
  }

  // Bring a library written by an earlier version from 0755/0644 up to
  // 0700/0600 even before the next save. Best effort: a path that is already
  // correct is a no-op.
  function hardenPermissions() {
    verifyFileMode = false
    mkdirProcess.running = true
  }

  Process {
    id: mkdirProcess
    command: ["mkdir", "-p", root.stateDir]
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.saving = false
        root.lastError = "Could not create " + root.stateDir
        return
      }
      Qt.callLater(function() { dirModeProcess.running = true })
    }
  }

  Process {
    id: dirModeProcess
    command: ["chmod", "700", root.stateDir]
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        // Without a 0700 directory the library would be readable by every
        // local user, so refuse to write rather than leak it.
        root.saving = false
        root.verifyFileMode = false
        root.lastError = "Could not restrict permissions on " + root.stateDir
        return
      }
      if (root.saving) {
        root.saving = false
        root.verifyFileMode = true
        libraryFile.setText(Model.serializeHosts(root.hosts))
        root.resolveAll()
      } else {
        // Startup hardening: no write is pending, so move on to the file.
        Qt.callLater(function() { fileModeProcess.running = true })
      }
    }
  }

  // An atomic write always lands 0644 under the default umask, so tighten the
  // file after every save as well. A failure here is reported only for a save
  // we just performed; at startup the file may not exist yet.
  Process {
    id: fileModeProcess
    command: ["chmod", "600", root.libraryPath]
    onExited: function(exitCode) {
      if (exitCode === 0 || !root.verifyFileMode) return
      root.verifyFileMode = false
      root.lastError = "Saved, but could not restrict permissions on " + root.libraryPath
    }
  }

  function nextId(hosts) {
    var used = Object.create(null)
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

  // Opening the panel runs `ssh -G` then a batch probe for each host. Bound how
  // many hosts that pass may touch so a hostile or accidentally huge library
  // cannot fork thousands of ssh processes — i.e. turn panel-open into a LAN
  // scan and CPU/memory spike.
  readonly property int autoProbeLimit: 300

  function resolveAll() {
    resolveQueue = []
    resolvingId = ""
    for (var i = 0; i < root.hosts.length && i < root.autoProbeLimit; i++) resolveQueue.push(root.hosts[i].id)
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
    var next = Object.create(null)
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
  // (vim, htop, tmux) all behave.
  //
  // The wrapper keeps the window open when ssh fails. A wrong password, a
  // refused key, or an unreachable host exits ssh in under a second, and a
  // terminal that closes on exit takes the reason with it — all the user sees
  // is a flash. The exit status is checked and the window is held on a
  // keypress so the message stays readable, and a desktop notification is sent
  // so the reason is available even after the window is dismissed.
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
    var label = Model.displayName(host)
    var inner = "ssh " + destination.map(Util.shellQuote).join(" ")

    // The reconnect wrapper is itself a shell command, so the failure handling
    // wraps whichever form is being run rather than duplicating it.
    var run = mode === "shell-reconnect" ? "bash -ic " + Util.shellQuote(inner) : inner

    var script = Model.connectScript(run, label)

    Util.execArgv([
      "setsid", "uwsm-app", "--",
      "xdg-terminal-exec",
      "--app-id=org.omarchy.sshdrops",
      "--title=SSHDrops",
      "-e", "bash", "-c", script
    ])
    return true
  }

  // ------------------------------------------------------ key authentication

  // Key state per host id, filled by a batch-mode probe. BatchMode is what
  // makes this a probe rather than a connection attempt: ssh will not prompt,
  // so it either authenticates with a key or fails immediately without ever
  // asking for a password. Nothing here can block on a human.
  property var keyStates: ({})
  property var probingId: ""
  property var probeQueue: []

  property string keyProbeTimeoutSec: intSetting("keyProbeTimeoutSec", 5, 2, 15)

  // Ask ssh whether a key already works. Runs one host at a time behind a
  // queue so a library of hosts does not open a burst of connections, and the
  // throwaway known_hosts file below means an unknown host is neither trusted
  // nor recorded: the probe stays non-interactive without writing anything to
  // the real ~/.ssh/known_hosts.
  function probeKeys() {
    probeQueue = []
    probingId = ""
    for (var i = 0; i < root.hosts.length && i < root.autoProbeLimit; i++) probeQueue.push(root.hosts[i].id)
    pumpProbeQueue()
  }

  function pumpProbeQueue() {
    if (probeProcess.running || root.probeQueue.length === 0) return
    var id = root.probeQueue.shift()
    var host = hostById(id)
    if (!host) {
      Qt.callLater(root.pumpProbeQueue)
      return
    }
    var destination = Model.destinationArgs(host)
    if (destination.length === 0) {
      Qt.callLater(root.pumpProbeQueue)
      return
    }
    probingId = id
    // BatchMode keeps this a probe: ssh will not prompt, so it either
    // authenticates with a key or fails immediately.
    //
    // ControlPath/ControlMaster are disabled because the probe must prove that
    // a key works on its own. With a multiplexed session already open, ssh
    // would ride the existing master and exit 0, reporting "keyed" for a host
    // that cannot actually authenticate without the session.
    //
    // `-n` never reads stdin, so the probe cannot sit on an inherited pipe
    // nobody will ever close. ConnectTimeout only bounds the TCP connect;
    // ServerAlive bounds the conversation after it, so a host that accepts the
    // connection and then goes quiet cannot stall the queue.
    probeProcess.command = [
      "ssh", "-n",
      "-o", "BatchMode=yes",
      "-o", "ConnectTimeout=" + root.keyProbeTimeoutSec,
      "-o", "ServerAliveInterval=" + root.keyProbeTimeoutSec,
      "-o", "ServerAliveCountMax=1",
      "-o", "ConnectionAttempts=1",
      "-o", "ControlMaster=no",
      "-o", "ControlPath=none",
      // The probe must not write the real known_hosts: silently trusting a
      // first-seen key on every panel open is the TOFU gap we are closing. A
      // throwaway known_hosts keeps the probe non-interactive without
      // persisting trust; the real connect still verifies (and prompts) as
      // normal, so a changed key is still caught at connect time.
      "-o", "StrictHostKeyChecking=no",
      "-o", "UserKnownHostsFile=/dev/null"
    ].concat(destination).concat(["exit"])
    probeProcess.running = true
  }

  Process {
    id: probeProcess
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.probeOutput = text
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.probeError = text
    }

    onExited: function(exitCode) {
      var id = root.probingId
      if (id !== "") {
        var message = String(root.probeError || "") + "\n" + String(root.probeOutput || "")
        var next = Object.create(null)
        for (var key in root.keyStates) next[key] = root.keyStates[key]
        next[id] = Model.keyState(exitCode === 0, message)
        root.keyStates = next
      }
      root.probingId = ""
      root.probeOutput = ""
      root.probeError = ""
      Qt.callLater(root.pumpProbeQueue)
    }
  }

  property string probeOutput: ""
  property string probeError: ""

  function keyStateFor(host) {
    if (!host) return "unknown"
    var state = root.keyStates[host.id]
    return state ? state : "unknown"
  }

  // Deploy this machine's public key to a host.
  //
  // `ssh-copy-id` asks for the password in the terminal the user already has
  // open and never receives it from the plugin, so no password is stored,
  // passed through argv, or held in this process. After it runs once the host
  // authenticates by key and the panel connects with no prompt at all.
  //
  // This is the same one-time setup as running ssh-copy-id by hand; it is in
  // the panel because it is the step that makes "click and you are there"
  // true, and because forgetting it is the reason a click still asks for a
  // password.
  function deployKey(host) {
    if (!Model.isConnectable(host)) return false
    var destination = Model.destinationArgs(host)
    if (destination.length === 0) return false

    var label = Model.displayName(host)
    // copy-id appends to authorized_keys on the far side and is idempotent,
    // so running it twice is safe.
    //
    // No StrictHostKeyChecking here: this runs on an interactive tty, so the
    // host-key prompt is expected and must not be suppressed.
    var script = [
      "sshdrops_copy() { ssh-copy-id -o ConnectTimeout=" + root.keyProbeTimeoutSec + " " +
        destination.map(Util.shellQuote).join(" ") + "; }",
      "sshdrops_copy",
      "sshdrops_rc=$?",
      'if [ "$sshdrops_rc" -ne 0 ]; then',
      "printf '\\n\\033[1;31mkey deploy failed (exit %s)\\033[0m\\n' \"$sshdrops_rc\"",
      "printf '\\nPress Enter to close. '",
      "read -r _",
      "else",
      "printf '\\n\\033[1;32mkey deployed — this host will connect without a password\\033[0m\\n'",
      "printf '\\nPress Enter to close. '",
      "read -r _",
      "fi",
      'exit "$sshdrops_rc"'
    ].join("\n")

    Util.execArgv([
      "setsid", "uwsm-app", "--",
      "xdg-terminal-exec",
      "--app-id=org.omarchy.sshdrops",
      "--title=SSHDrops — deploy key",
      "-e", "bash", "-c", script
    ])
    return true
  }

  // ------------------------------------------------------------------ import

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
    var existing = Object.create(null)
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
    // Fix a 0755 directory / 0644 library left by an earlier version even if
    // the user never saves again.
    root.hardenPermissions()
  }
}
