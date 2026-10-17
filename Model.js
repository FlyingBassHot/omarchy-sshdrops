.pragma library

// Pure helpers for SSHDrops. No state, no IO — everything here is a function
// of its arguments so the panel can call it freely on every keystroke.

// ---------------------------------------------------------------- host store

// A stored host, normalized into the shape the panel renders. `alias` is the
// only thing that reaches the ssh command line: when it is set we hand ssh the
// alias and let OpenSSH resolve everything else out of the user's own config
// (IdentityFile, ProxyJump, Match). When it is empty we build an explicit
// destination from the fields below.
var MODES = ["shell", "shell-reconnect"]

// Bounds so a hostile or bloated library cannot turn the panel into a memory
// bomb. 1 MiB is far more than a realistic host list needs.
var MAX_LIBRARY_BYTES = 1048576

function emptyHost() {
  return {
    id: "",
    name: "",
    host: "",
    user: "",
    port: "",
    alias: "",
    group: "",
    notes: "",
    mode: ""
  }
}

function trim(value) {
  return String(value === undefined || value === null ? "" : value).trim()
}

// A single-line stored field: strings and finite numbers only, control
// characters stripped. Objects, arrays, booleans, and null collapse to "" so a
// hand-edited library cannot coerce `["a","b"]` into a connectable host (L2),
// and a saved name cannot carry escape sequences into a notification (L1).
function text(value) {
  if (typeof value === "number" && isFinite(value)) return String(value)
  return typeof value === "string" ? value : ""
}

function field(value) {
  return text(value).replace(/[\u0000-\u001F\u007F-\u009F]/g, "").trim()
}

// Coerce anything the editor or an import produced into a stored host. An
// unknown mode is dropped rather than persisted, so a hand-edited library
// cannot smuggle an arbitrary string into the ssh invocation. A wrong-typed
// value becomes empty rather than being stringified into something connectable.
function normalizeHost(raw) {
  raw = raw || {}
  var host = {
    id: field(raw.id),
    name: field(raw.name),
    host: field(raw.host),
    user: field(raw.user),
    port: field(raw.port),
    alias: field(raw.alias),
    group: field(raw.group),
    notes: field(raw.notes),
    mode: ""
  }
  if (MODES.indexOf(text(raw.mode)) !== -1) host.mode = text(raw.mode)
  if (host.port !== "" && !/^\d+$/.test(host.port)) host.port = ""
  return host
}

// The label a host is known by in the panel. The name wins; otherwise fall
// back to the alias; otherwise to the bare hostname. Never empty once
// validated, because a row with no title cannot be picked.
function displayName(host) {
  if (!host) return ""
  if (host.name) return host.name
  if (host.alias) return host.alias
  return host.host
}

// What we actually hand to ssh: the port as `-p <port>` when one is saved,
// then the alias when there is one, otherwise [user@]host. Returns the
// argument vector, never a shell string.
//
// The option comes first because every caller appends something after the
// destination (the probe's remote `exit`, nothing at all otherwise) and ssh
// reads options up to the destination.
//
// A port set in the editor is a deliberate override and is emitted even
// alongside an alias: on the command line `-p` beats the config file's Port,
// which is what a field the user typed should do, and it applies to the final
// destination while IdentityFile, ProxyJump, and Match still come from the
// alias. Entries without a port — which is every imported entry, since an
// import stores nothing but the alias — emit no `-p` at all, so the config
// value is used unchanged.
//
// An alias wins over a hostname because that is the whole point of using one
// — it lets ssh resolve IdentityFile, ProxyJump, and Match rules from the
// user's own config. It also means a host with both filled in connects via
// the alias, which is why the panel shows the exact command and warns when the
// alias is not defined anywhere.
function destinationArgs(host) {
  if (!host) return []
  var destination = ""
  if (host.alias) {
    destination = host.alias
  } else if (host.host) {
    destination = host.user ? host.user + "@" + host.host : host.host
  } else {
    return []
  }

  // A destination that starts with a dash is read by ssh (and by ssh-copy-id,
  // where `--` does not survive getopts) as an OPTION, not a host: a saved
  // `-oProxyCommand=…` becomes arbitrary code execution, executed
  // automatically by the key probe on panel open. This is the single choke
  // point every caller goes through, so refusing here disarms all of them.
  if (String(destination).charAt(0) === "-") return []

  // normalizeHost already drops a port that is not a plain number, but this
  // function is also called on hand-built objects, and a value that reached
  // argv as anything but digits would be an ssh option injection.
  var args = []
  if (host.port && /^\d+$/.test(String(host.port))) args.push("-p", String(host.port))

  // `--` ends option parsing for ssh as defence in depth. It is pushed after
  // the options and immediately before the destination.
  args.push("--", destination)
  return args
}

// The command the panel will run, for display. Mirrors destinationArgs so
// what the user reads is exactly what gets executed.
function connectCommand(host, mode) {
  var args = destinationArgs(host)
  if (args.length === 0) return ""
  // `--` is an argv-safety marker, not part of the command the user reads.
  var shown = []
  for (var i = 0; i < args.length; i++) {
    if (args[i] !== "--") shown.push(args[i])
  }
  var quoted = shown.map(shellQuote).join(" ")
  return mode === "shell-reconnect" ? "bash -ic 'ssh " + quoted + "'" : "ssh " + quoted
}

// Single-quote a value for bash, the same escaping Util.shellQuote applies.
function shellQuote(value) {
  return "'" + String(value === undefined || value === null ? "" : value).replace(/'/g, "'\\''") + "'"
}

// The script handed to `bash -c` in the terminal.
//
// `run` is the ssh invocation, already quoted. On success the terminal closes
// exactly as it would for a plain ssh. On failure it stays open, because ssh
// exits in well under a second for a refused key, a bad password, or an
// unreachable host — and a terminal that closes on exit takes the only
// explanation with it. The user gets the ssh message on screen plus a desktop
// notification, and presses a key to dismiss.
//
// Exit 130 is ssh reporting a Ctrl-C, which is a deliberate disconnect rather
// than a failure, so it closes quietly instead of parking a window.
//
// The name is passed as an argument to the wrapper rather than interpolated,
// so it cannot alter the script.
function connectScript(run, label) {
  const quotedLabel = shellQuote(label + " — ssh failed")
  return [
    // A subshell so the status is captured without letting a `RemoteCommand`
    // or a wrapper `exit` tear down the terminal before the check runs.
    "sshdrops_run() { (" + run + "); }",
    "sshdrops_run",
    "sshdrops_rc=$?",
    // 130 is ssh reporting a deliberate Ctrl-C, not a failure.
    'if [ "$sshdrops_rc" -ne 0 ] && [ "$sshdrops_rc" -ne 130 ]; then',
    "printf '\\n\\033[1;31mssh failed (exit %s)\\033[0m\\n' \"$sshdrops_rc\"",
    "omarchy-notification-send -g '' -u critical " + quotedLabel +
      " \"SSH exited with status $sshdrops_rc\" >/dev/null 2>&1 || true",
    "printf '\\nPress Enter to close. '",
    "read -r _",
    "fi",
    'exit "$sshdrops_rc"',
    ""
  ].join("\n")
}

// A host is connectable when ssh would have something to dial.
function isConnectable(host) {
  if (!host) return false
  return host.alias !== "" || host.host !== ""
}

// Validate the editor form. Returns an array of human-readable problems; an
// empty array means the host can be saved. Runs on a normalized copy so a
// hand-built object with missing keys reads the same as one from the editor.
function validateHost(raw) {
  var host = normalizeHost(raw)
  var problems = []
  if (host.name === "" && host.alias === "" && host.host === "")
    problems.push("Give it a name, an alias, or a hostname")
  if (host.alias === "" && host.host === "") problems.push("Set a hostname or an ssh alias")
  if (host.host !== "" && /\s/.test(host.host)) problems.push("Hostname cannot contain spaces")
  if (host.user !== "" && /\s/.test(host.user)) problems.push("User cannot contain spaces")
  // A leading dash would be read by ssh as an option rather than a host, which
  // turns a saved field into command execution.
  if (host.host !== "" && host.host.charAt(0) === "-") problems.push("Hostname cannot start with a dash")
  if (host.user !== "" && host.user.charAt(0) === "-") problems.push("User cannot start with a dash")
  if (host.alias !== "" && host.alias.charAt(0) === "-") problems.push("Alias cannot start with a dash")
  if (host.alias !== "" && /\s/.test(host.alias)) problems.push("Alias cannot contain spaces")
  // normalizeHost drops a port that is not a plain number, so anything left
  // here is either empty or in range-checkable form.
  if (host.port !== "") {
    var port = Number(host.port)
    if (!isFinite(port) || port < 1 || port > 65535) problems.push("Port must be between 1 and 65535")
  }
  return problems
}

function parseHosts(textInput) {
  var raw = String(textInput || "")
  if (raw.length > MAX_LIBRARY_BYTES)
    return { ok: false, hosts: [], error: "Library is too large" }

  var parsed = null
  try {
    parsed = JSON.parse(raw)
  } catch (e) {
    return { ok: false, hosts: [], error: "Library is not valid JSON" }
  }
  var list = parsed && Array.isArray(parsed.hosts) ? parsed.hosts : null
  if (!list) return { ok: false, hosts: [], error: "Library has no \"hosts\" array" }

  var hosts = []
  // Null prototype: an id of "__proto__" or "constructor" must be an ordinary
  // key, not a write to Object.prototype (L7).
  var seen = Object.create(null)
  for (var i = 0; i < list.length; i++) {
    var host = normalizeHost(list[i])
    if (!isConnectable(host)) continue
    if (host.id === "" || seen[host.id]) host.id = "host-" + i + "-" + displayName(host)
    seen[host.id] = true
    hosts.push(host)
  }
  return { ok: true, hosts: hosts, error: "" }
}

function serializeHosts(hosts) {
  var list = []
  for (var i = 0; i < hosts.length; i++) list.push(normalizeHost(hosts[i]))
  return JSON.stringify({ version: 1, hosts: list }, null, 2) + "\n"
}

// Sort by group, then name. Groups sort by their first appearance in the
// library so the order the user arranged them in survives a reload, and an
// ungrouped host sorts last rather than under an empty heading.
function sortHosts(hosts) {
  var groupOrder = []
  var byGroup = Object.create(null)
  for (var i = 0; i < hosts.length; i++) {
    var key = trim(hosts[i].group) || ""
    if (!(key in byGroup)) {
      byGroup[key] = []
      groupOrder.push(key)
    }
    byGroup[key].push(hosts[i])
  }

  var sorted = []
  for (var g = 0; g < groupOrder.length; g++) {
    var key = groupOrder[g]
    if (key === "") continue
    var bucket = byGroup[key].slice()
    bucket.sort(function (a, b) { return displayName(a).toLowerCase() < displayName(b).toLowerCase() ? -1 : 1 })
    for (var j = 0; j < bucket.length; j++) sorted.push(bucket[j])
  }

  var loose = byGroup[""] || []
  loose.sort(function (a, b) { return displayName(a).toLowerCase() < displayName(b).toLowerCase() ? -1 : 1 })
  for (var k = 0; k < loose.length; k++) sorted.push(loose[k])
  return sorted
}

// ------------------------------------------------------------------- searching

// Subsequence match: every character of `query` appears in `text` in order.
// Returns a score (higher is better) or -1 when the query does not match.
// Consecutive runs and word-boundary hits are rewarded, which is what makes
// "gph" rank "gateway-01" above "gateway-02".
function fuzzyScore(query, text) {
  query = String(query || "").toLowerCase()
  text = String(text || "").toLowerCase()
  if (query === "") return 0
  if (text === "") return -1
  if (text.indexOf(query) !== -1) {
    // A literal substring always outranks a scattered subsequence match.
    return 1000 - text.indexOf(query) * 10 - text.length
  }

  var score = 0
  var textIndex = 0
  var previousMatch = -1
  for (var i = 0; i < query.length; i++) {
    var found = text.indexOf(query.charAt(i), textIndex)
    if (found === -1) return -1
    if (previousMatch !== -1 && found === previousMatch + 1) score += 12
    if (found === 0 || /[^a-z0-9]/.test(text.charAt(found - 1))) score += 8
    score += 2
    score -= Math.min(found - textIndex, 12) * 0.25
    previousMatch = found
    textIndex = found + 1
  }
  return score
}

// Best score across every searchable field of a host. `query` is matched
// against the name, alias, hostname, user, group, and notes together so one
// box finds a host by whatever the user happens to remember.
function hostScore(host, query) {
  if (!host) return -1
  if (query === "") return 0
  var fields = [displayName(host), host.alias, host.host, host.user, host.group, host.notes]
  var best = -1
  for (var i = 0; i < fields.length; i++) {
    var score = fuzzyScore(query, fields[i])
    if (score > best) best = score
  }
  return best
}

// Rank hosts against a query. Live sessions float to the top so a host you are
// already connected to is always the first thing Enter reaches.
function filterHosts(hosts, query, sessions) {
  var q = trim(query).toLowerCase()
  var out = []
  for (var i = 0; i < hosts.length; i++) {
    var host = hosts[i]
    var score = hostScore(host, q)
    if (score < 0) continue
    out.push({
      host: host,
      score: score,
      live: sessions && sessions[host.id] ? true : false,
      sessionCount: sessions && sessions[host.id] ? sessions[host.id] : 0
    })
  }
  out.sort(function (a, b) {
    if (a.live !== b.live) return a.live ? -1 : 1
    if (a.score !== b.score) return b.score - a.score
    var an = displayName(a.host).toLowerCase()
    var bn = displayName(b.host).toLowerCase()
    return an < bn ? -1 : 1
  })
  return out
}

// ------------------------------------------------------------- ssh config read

// Parse the output of `ssh -G <target>` — the effective configuration for one
// destination, with every default and Match rule already applied. We only
// surface the few keys that tell a user what they are about to connect to.
function parseSshConfig(text) {
  var result = {
    ok: false,
    user: "",
    hostname: "",
    port: "",
    proxyJump: "",
    identityFile: "",
    controlPath: "",
    controlMaster: ""
  }
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "") continue
    var space = line.indexOf(" ")
    if (space === -1) continue
    var key = line.slice(0, space).toLowerCase()
    var value = line.slice(space + 1).trim()
    if (value === "none") value = ""
    if (key === "user") result.user = value
    else if (key === "hostname") result.hostname = value
    else if (key === "port") result.port = value
    else if (key === "proxyjump") result.proxyJump = value
    else if (key === "identityfile") result.identityFile = result.identityFile === "" ? value : result.identityFile
    else if (key === "controlpath") result.controlPath = value
    else if (key === "controlmaster") result.controlMaster = value
  }
  result.ok = result.hostname !== "" || result.user !== ""
  return result
}

// Pull the literal `Host` aliases out of an ssh_config file. Wildcards and
// negations are skipped: `Host *` is a defaults block, not a machine, and a
// negated pattern names what a host is *not*.
function parseSshConfigHosts(text) {
  var lines = String(text || "").split("\n")
  var hosts = []
  var inHostBlock = false
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "" || line.charAt(0) === "#") continue
    var space = line.indexOf(" ")
    var tab = line.indexOf("\t")
    if (space === -1 || (tab !== -1 && tab < space)) space = tab
    if (space === -1) continue

    var key = line.slice(0, space).toLowerCase()
    var value = line.slice(space + 1).trim()
    if (key === "host") {
      inHostBlock = true
      var patterns = value.split(/\s+/)
      for (var p = 0; p < patterns.length; p++) {
        var pattern = patterns[p]
        if (pattern === "") continue
        if (pattern.charAt(0) === "!") continue
        if (/[*?]/.test(pattern)) continue
        // Only tokens that are valid ssh destination names. This drops
        // `-oProxyCommand=…`, `'quoted'`, `"dq"`, and `=weird` before an
        // import can turn them into a saved host.
        if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(pattern)) continue
        hosts.push(pattern)
      }
      continue
    }
    if (key === "match") inHostBlock = false
  }

  var seen = Object.create(null)
  var unique = []
  for (var h = 0; h < hosts.length; h++) {
    if (seen[hosts[h]]) continue
    seen[hosts[h]] = true
    unique.push(hosts[h])
  }
  unique.sort()
  return unique
}

// --------------------------------------------------------------- live sessions

// Map a `ps` line to the host it is talking to. `ssh host`, `ssh user@host`,
// `ssh -p 2222 host`, and `ssh -J jump host` all have to land on the same host
// a library entry is keyed by, which is why the destination is resolved by
// position rather than by taking the last word blindly.
function sessionDestination(argsText) {
  var tokens = String(argsText || "").split(/\s+/).filter(function (t) { return t !== "" })
  var valueOpts = "BCDEeFIiJLlmOopQRSW"
  var destination = ""
  var i = 0
  for (; i < tokens.length; i++) {
    var token = tokens[i]
    if (token === "ssh") continue
    if (token === "-o" || token === "-F" || token === "-i" || token === "-J" || token === "-b" || token === "-c" || token === "-D" || token === "-E" || token === "-I" || token === "-L" || token === "-l" || token === "-m" || token === "-O" || token === "-P" || token === "-R" || token === "-S" || token === "-W" || token === "-w") {
      i++
      continue
    }
    if (token.charAt(0) === "-" && token.length > 1) {
      var letters = token.slice(1)
      for (var l = 0; l < letters.length; l++) {
        if (valueOpts.indexOf(letters.charAt(l)) !== -1) {
          if (l === letters.length - 1) i++
          break
        }
      }
      continue
    }
    destination = token
    break
  }
  if (destination === "") return ""
  var at = destination.indexOf("@")
  return at === -1 ? destination : destination.slice(at + 1)
}

// Turn `ps` output into { destination: count }. Only lines that are actually
// ssh sessions count: a ControlMaster's master and its multiplexed children
// both appear, which is exactly what "how many sessions is this host running"
// should mean.
function parseSessions(psText) {
  var counts = Object.create(null)
  var lines = String(psText || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line === "") continue
    var space = line.indexOf(" ")
    if (space === -1) continue
    // ps prints argv as the kernel sees it, so the program shows up as
    // /usr/bin/ssh rather than `ssh`. Matching on a leading "ssh " would miss
    // every session started by absolute path, which is most of them. The
    // basename must be exactly "ssh": `sshd` is the server, not a session.
    var program = line.slice(0, space)
    if (program.slice(program.lastIndexOf("/") + 1) !== "ssh") continue
    var destination = sessionDestination(line.slice(space + 1))
    if (destination === "") continue
    counts[destination] = (counts[destination] || 0) + 1
  }
  return counts
}

// Which hosts in the library have a live session right now. A host matches
// either by its alias or by its bare hostname, because a session started by
// hand with `ssh host` and one started from the panel with `ssh user@host`
// are the same connection to the same machine.
function liveSessionMap(hosts, counts) {
  var map = Object.create(null)
  if (!counts) return map
  for (var i = 0; i < hosts.length; i++) {
    var host = hosts[i]
    var keys = []
    if (host.alias) keys.push(host.alias)
    if (host.host) keys.push(host.host)
    if (host.user && host.host) keys.push(host.user + "@" + host.host)
    for (var k = 0; k < keys.length; k++) {
      var count = counts[keys[k]]
      if (count) {
        map[host.id] = count
        break
      }
    }
  }
  return map
}

// True when a host's ssh alias is not actually defined in the user's ssh
// config.
//
// `ssh -G` falls back to treating an unknown alias as a literal hostname, so
// the tell is that the resolved `hostname` came back unchanged. A real alias
// resolves to an address (or at least something else), and `Could not resolve
// hostname` is what the user would otherwise see as a window that opens and
// closes instantly with no explanation.
function aliasLooksUndefined(host, resolved) {
  if (!host || !host.alias || !resolved) return false
  if (!resolved.ok) return true
  return resolved.hostname === host.alias
}

// --------------------------------------------------------- key authentication

// Key authentication state for a host, derived from a batch-mode probe.
//
// Three outcomes matter, and they call for different actions:
//
//   "keyed"    - a publickey already authenticates. Nothing to do.
//   "password" - the host answered and rejected us, which means it wanted a
//                password. The fix is to deploy a key, not to store one.
//   "unknown"  - the probe could not conclude anything. Nothing is claimed.
//
// ssh exits 255 for a refused key, an unresolvable name, and an unreachable
// host alike, so the message is the only thing that separates them. Only
// "Permission denied" proves the host was reached and turned us away.
function keyState(probeOk, probeMessage) {
  if (probeOk === true) return "keyed"
  var message = String(probeMessage || "").toLowerCase()
  if (message.indexOf("permission denied") !== -1) return "password"
  // The server was reached and turned us away, so a key deploy is the fix even
  // though ssh never got as far as offering to authenticate.
  if (message.indexOf("too many authentication failures") !== -1) return "password"
  if (message.indexOf("could not resolve") !== -1) return "unresolved"
  // A changed key is a real, nameable condition with a real remedy, so it gets
  // its own state instead of being lumped in with "we learned nothing".
  if (message.indexOf("host key verification failed") !== -1) return "hostkey"
  if (message.indexOf("remote host identification has changed") !== -1) return "hostkey"
  if (message.indexOf("connection refused") !== -1) return "refused"
  // Something answered on the port but is not an ssh server, or hung up
  // mid-handshake. Either way the TCP connect succeeded and the service did
  // not, which is a refusal as far as the row is concerned.
  if (message.indexOf("connection closed") !== -1) return "refused"
  if (message.indexOf("kex_exchange_identification") !== -1) return "refused"
  if (message.indexOf("banner exchange") !== -1) return "refused"
  if (message.indexOf("identification string") !== -1) return "refused"
  if (message.indexOf("connection timed out") !== -1) return "unreachable"
  if (message.indexOf("no route to host") !== -1) return "unreachable"
  if (message.indexOf("network is unreachable") !== -1) return "unreachable"
  if (message.indexOf("connection reset") !== -1) return "refused"
  return "unknown"
}

// The one-line explanation shown on a row or in the editor. Only `password`
// has a remedy worth offering; the rest are reported plainly.
function keyStateHint(state) {
  if (state === "keyed") return "Key authentication is already set up"
  if (state === "password") return "Needs a password — deploy your key to connect without one"
  if (state === "unresolved") return "Host name does not resolve"
  if (state === "refused") return "Host refused the connection — check the port"
  // The port is part of the known_hosts key, so the name of the entry to
  // remove has to carry it or the stale one survives.
  if (state === "hostkey") return "Host key changed — remove the old key with ssh-keygen -R [host]:port"
  if (state === "unreachable") return "Host did not answer"
  return ""
}

// ------------------------------------------------------------------ formatting

// The second line under a host: the destination as ssh would read it, plus the
// jump host when there is one. An explicit or resolved port of 22 is left off
// — it is the default and saying so every row just adds noise.
function subtitle(host, resolved) {
  if (!host) return ""

  var port = host.port
  if (port === "" && resolved && resolved.port) port = resolved.port
  if (port === "22") port = ""

  var destination = host.user ? host.user + "@" + (host.host || host.alias) : (host.host || host.alias)
  // A bare IPv6 literal reads as noise without brackets: `root@fe80::1:2222`
  // looks like a hostname with a port, not an address with one. This is
  // display only — the argv keeps the literal unbracketed, which is what ssh
  // wants.
  if (host.host && host.host.indexOf(":") !== -1 && host.host.charAt(0) !== "[")
    destination = (host.user ? host.user + "@[" : "[") + host.host + "]"
  var parts = []
  if (destination !== "") parts.push(port === "" ? destination : destination + ":" + port)

  if (resolved && resolved.proxyJump) parts.push("via " + resolved.proxyJump)
  return parts.join(" · ")
}

// Only the identity file's basename. A full path leaks the user's directory
// layout into a panel that may be on a shared screen, and the leaf name is
// what actually identifies the key.
function identityLabel(path) {
  if (!path) return ""
  var parts = String(path).split("/")
  return parts[parts.length - 1]
}
