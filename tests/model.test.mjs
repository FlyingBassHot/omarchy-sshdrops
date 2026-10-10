// Unit tests for Model.js.
//
// Model.js is written in QML's JavaScript dialect, so the only difference
// needed to run it under Node is the `.pragma library` line and a print()
// shim. The wrapper below does both without touching the file itself, which
// keeps the plugin loadable by Quickshell and testable by a plain `node`.
//
//   node tests/model.test.mjs
//
// It runs against the same file the panel imports, so a regression here is a
// regression in the plugin.

import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"

const here = dirname(fileURLToPath(import.meta.url))
const source = readFileSync(join(here, "..", "Model.js"), "utf8")

// QML exposes top-level declarations as properties of the imported namespace.
// Rebuild that shape: evaluate the body, then collect every declaration.
const body = source.replace(/^\.pragma library\s*/, "")
const exported = [
  "MODES", "emptyHost", "trim", "normalizeHost", "displayName", "destinationArgs",
  "isConnectable", "validateHost", "parseHosts", "serializeHosts", "sortHosts",
  "fuzzyScore", "hostScore", "filterHosts", "parseSshConfig", "parseSshConfigHosts",
  "sessionDestination", "parseSessions", "liveSessionMap", "subtitle", "identityLabel"
]
const factory = new Function(
  `${body}\nreturn { ${exported.join(", ")} };`
)
const Model = factory()

globalThis.print = (...args) => console.log(...args)

// ---------------------------------------------------------------------------

let failures = 0
let checks = 0

function ok(name, condition, detail) {
  checks++
  if (condition) return
  failures++
  print("FAIL: " + name + (detail === undefined ? "" : ("  -> " + detail)))
}

function eq(name, actual, expected) {
  ok(name, actual === expected, `got ${JSON.stringify(actual)} want ${JSON.stringify(expected)}`)
}

// ---------------------------------------------------------------- host store

eq("displayName prefers name", Model.displayName({ name: "Prod", alias: "p", host: "h" }), "Prod")
eq("displayName falls back to alias", Model.displayName({ name: "", alias: "p", host: "h" }), "p")
eq("displayName falls back to host", Model.displayName({ name: "", alias: "", host: "h" }), "h")

eq("alias wins over host",
   Model.destinationArgs({ alias: "jump", user: "root", host: "1.2.3.4", port: "22" }).join(","), "jump")
eq("user@host without alias",
   Model.destinationArgs({ alias: "", user: "root", host: "1.2.3.4", port: "2222" }).join(","), "root@1.2.3.4")
eq("bare host",
   Model.destinationArgs({ alias: "", user: "", host: "example.com", port: "" }).join(","), "example.com")

eq("empty host not connectable", Model.isConnectable({ alias: "", host: "" }), false)
eq("alias-only is connectable", Model.isConnectable({ alias: "a", host: "" }), true)

// A host name is user input that reaches a command line. It must survive
// normalizeHost untouched, so the shell-quoting layer stays the only thing
// standing between it and a shell.
eq("shell metacharacters survive normalization",
   Model.normalizeHost({ name: "x", host: "; rm -rf ~", id: "h1" }).host, "; rm -rf ~")
eq("single quote survives normalization",
   Model.normalizeHost({ host: "a'b" }).host, "a'b")
eq("command substitution survives normalization",
   Model.normalizeHost({ host: "$(id)" }).host, "$(id)")

eq("bogus mode is dropped", Model.normalizeHost({ host: "h", mode: "sudo rm" }).mode, "")
eq("known mode is kept", Model.normalizeHost({ host: "h", mode: "shell-reconnect" }).mode, "shell-reconnect")
eq("non-numeric port is dropped", Model.normalizeHost({ host: "h", port: "abc" }).port, "")
eq("numeric port is kept", Model.normalizeHost({ host: "h", port: "2222" }).port, "2222")

eq("validate rejects empty", Model.validateHost({ name: "", alias: "", host: "" }).length > 0, true)
eq("validate accepts alias only", Model.validateHost({ name: "n", alias: "a", host: "" }).length, 0)
eq("validate rejects spaced host", Model.validateHost({ name: "n", host: "a b" }).length > 0, true)
eq("validate rejects out-of-range port",
   Model.validateHost({ name: "n", host: "h", port: "70000" }).length > 0, true)
eq("validate rejects spaced user", Model.validateHost({ name: "n", host: "h", user: "a b" }).length > 0, true)

// ------------------------------------------------------------------- library

const lib = Model.parseHosts(JSON.stringify({
  version: 1,
  hosts: [
    { id: "a", name: "Web", alias: "web", group: "prod" },
    { id: "b", name: "Db", host: "db.local", user: "postgres" },
    { id: "", name: "NoId", host: "x.com" },
    { id: "c", name: "Broken", host: "" }
  ]
}))
eq("library parses", lib.ok, true)
eq("unconnectable entries are dropped", lib.hosts.length, 3)
eq("missing id is synthesized", lib.hosts.filter(h => h.id === "").length, 0)

const bad = Model.parseHosts("{not json")
eq("bad JSON reports failure", bad.ok, false)
eq("bad JSON has no hosts", bad.hosts.length, 0)
eq("missing hosts array reports failure", Model.parseHosts(JSON.stringify({ version: 1 })).ok, false)

eq("serialize round-trips",
   Model.parseHosts(Model.serializeHosts(lib.hosts)).hosts.length, 3)

eq("sort puts groups before ungrouped",
   Model.sortHosts([
     { id: "1", name: "zeta", group: "" },
     { id: "2", name: "alpha", group: "prod" },
     { id: "3", name: "beta", group: "prod" },
     { id: "4", name: "solo", group: "lab" }
   ]).map(h => h.name).join(","),
   "alpha,beta,solo,zeta")

// ------------------------------------------------------------------- fuzzy

eq("fuzzy rejects non-match", Model.fuzzyScore("zzz", "alpha"), -1)
ok("fuzzy accepts subsequence", Model.fuzzyScore("ap", "alpha") > 0)
eq("fuzzy is case-insensitive", Model.fuzzyScore("AL", "alpha") > 0, true)
ok("substring beats scattered", Model.fuzzyScore("alph", "alpha") > Model.fuzzyScore("aph", "alpha"))

const hosts = [
  { id: "1", name: "gateway-01" },
  { id: "2", name: "gateway-02" },
  { id: "3", name: "database", host: "db.internal", group: "prod" },
  { id: "4", name: "web", host: "web.example.com" }
]
eq("filter by name", Model.filterHosts(hosts, "gate", {}).length, 2)
eq("filter by host", Model.filterHosts(hosts, "internal", {}).length, 1)
eq("filter by group", Model.filterHosts(hosts, "prod", {}).length, 1)
eq("filter no match", Model.filterHosts(hosts, "qqqq", {}).length, 0)
eq("empty query returns all", Model.filterHosts(hosts, "", {}).length, 4)

// Live sessions float to the top so Enter reaches something already connected.
const ranked = Model.filterHosts(hosts, "", { "4": 1 })
eq("live host ranks first", ranked[0].host.id, "4")
eq("live count is reported", ranked[0].sessionCount, 1)

// ------------------------------------------------------------ ssh -G output

const resolved = Model.parseSshConfig([
  "user deploy",
  "hostname 10.0.0.5",
  "port 2222",
  "proxyjump bastion",
  "identityfile ~/.ssh/id_ed25519",
  "identityfile ~/.ssh/id_rsa",
  "controlmaster auto",
  "controlpath /tmp/ssh-%C"
].join("\n"))
eq("ssh -G user", resolved.user, "deploy")
eq("ssh -G hostname", resolved.hostname, "10.0.0.5")
eq("ssh -G port", resolved.port, "2222")
eq("ssh -G proxyjump", resolved.proxyJump, "bastion")
eq("ssh -G takes first identity", resolved.identityFile, "~/.ssh/id_ed25519")
eq("ssh -G controlmaster", resolved.controlMaster, "auto")
eq("ssh -G ok", resolved.ok, true)

const noneResolved = Model.parseSshConfig("proxyjump none\nhostname h\n")
eq("'none' means unset", noneResolved.proxyJump, "")
eq("ssh -G tolerates malformed lines", Model.parseSshConfig("hostname\n").ok, false)

// ---------------------------------------------------------- ssh_config hosts

const configText = [
  "# comment",
  "Host bastion jump",
  "  HostName 10.0.0.1",
  "  User root",
  "",
  "Host web-*",
  "  HostName 10.0.0.2",
  "",
  "Host *",
  "  ServerAliveInterval 60",
  "",
  "Match host secret",
  "  User root",
  ""
].join("\n")
const aliases = Model.parseSshConfigHosts(configText)
eq("literal aliases found", aliases.join(","), "bastion,jump")
eq("wildcards excluded", aliases.indexOf("web-*"), -1)
eq("catch-all excluded", aliases.indexOf("*"), -1)
eq("dedup applied", Model.parseSshConfigHosts("Host a\nHost a\n").length, 1)

// ----------------------------------------------------------------- sessions

const ps = [
  "bash",
  "ssh gateway-01",
  "ssh -p 2222 root@db.internal",
  "ssh -J bastion -i /home/u/.ssh/id jump",
  "ssh -o BatchMode=yes web.example.com",
  "ssh user@",
  "/usr/bin/ssh -p 22 gateway-02",
  "/usr/bin/sshd: /usr/sbin/sshd -D",
  "grep ssh something",
  "ssh-add -D"
].join("\n")
const counts = Model.parseSessions(ps)
eq("bare host detected", counts["gateway-01"], 1)
eq("user@host detected", counts["db.internal"], 1)
eq("proxyjump host detected", counts["jump"], 1)
eq("option value skipped", counts["web.example.com"], 1)
eq("absolute path detected", counts["gateway-02"], 1)
eq("sshd is not a session", counts["/usr/sbin/sshd"], undefined)
eq("ssh-add is not a session", counts["-D"], undefined)
eq("malformed destination ignored", Model.parseSessions("ssh user@").ssh, undefined)

const liveMap = Model.liveSessionMap(
  [{ id: "a", alias: "jump", host: "10.0.0.1" }, { id: "b", alias: "quiet", host: "10.0.0.2" }],
  { jump: 2 }
)
eq("alias match", liveMap["a"], 2)
eq("offline host absent", liveMap["b"], undefined)
eq("match by bare hostname",
   Model.liveSessionMap([{ id: "h", alias: "", host: "gateway-01" }], { "gateway-01": 1 }).h, 1)

// --------------------------------------------------------------- formatting

eq("subtitle shows user and host",
   Model.subtitle({ user: "root", host: "h", alias: "", port: "22" }, null), "root@h")
eq("subtitle hides default port",
   Model.subtitle({ user: "", host: "h", alias: "", port: "" }, { port: "22" }), "h")
eq("subtitle shows non-default port",
   Model.subtitle({ user: "", host: "h", alias: "", port: "" }, { port: "2222" }), "h:2222")
eq("subtitle shows jump",
   Model.subtitle({ user: "root", host: "h", alias: "", port: "" }, { port: "22", proxyJump: "bastion" }),
   "root@h · via bastion")

eq("identity label is basename only",
   Model.identityLabel("/home/someone/.ssh/id_ed25519"), "id_ed25519")

print("")
print(failures === 0
  ? `All ${checks} checks passed`
  : `${failures} of ${checks} checks FAILED`)
process.exit(failures === 0 ? 0 : 1)
