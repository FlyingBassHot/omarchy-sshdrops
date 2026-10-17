// Regression tests for the findings in SECURITY-AUDIT.md.
//
// These pin the *security* behaviour of Model.js rather than its UI shape: the
// ssh option-injection guard, the type/control-character hardening of stored
// fields, the import shape check, and the prototype-safety of the id maps.
// Every check here corresponds to a numbered finding, so a regression names
// itself.
//
//   node tests/security.test.mjs
//
// Model.js is written in QML's JavaScript dialect, so the only difference
// needed to run it under Node is the `.pragma library` line — same loader shape
// as tests/model.test.mjs.

import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"

const here = dirname(fileURLToPath(import.meta.url))
const source = readFileSync(join(here, "..", "Model.js"), "utf8")
const body = source.replace(/^\.pragma library\s*/, "")
const exported = [
  "destinationArgs", "connectCommand", "normalizeHost", "validateHost",
  "parseHosts", "parseSshConfigHosts", "liveSessionMap"
]
const Model = new Function(`${body}\nreturn { ${exported.join(", ")} };`)()

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

function print(...args) { console.log(...args) }

// ---------------------------------------------------------------- H1 guard
//
// A destination beginning with `-` is read by ssh as an OPTION. `-oProxyCommand=`
// is arbitrary command execution, and the key probe runs it automatically for
// every saved host the moment the panel opens.

const injected = "-oProxyCommand=id>/tmp/pwn"

eq("H1 leading-dash host is refused", Model.destinationArgs({ host: injected }).length, 0)
eq("H1 leading-dash alias is refused",
   Model.destinationArgs({ alias: injected, host: "1.2.3.4" }).length, 0)
eq("H1 leading-dash user is refused",
   Model.destinationArgs({ user: "-oProxyCommand=id>/tmp/pwn", host: "h" }).length, 0)
eq("H1 bare -- is refused", Model.destinationArgs({ host: "--" }).length, 0)
eq("H1 double-dash option is refused", Model.destinationArgs({ host: "-F/dev/null" }).length, 0)
// The safe shape still works, with `--` immediately before the destination.
eq("H1 normal host gets the -- terminator",
   Model.destinationArgs({ host: "h" }).join(","), "--,h")
eq("H1 port sits before the -- terminator",
   Model.destinationArgs({ host: "h", port: "2222" }).join(","), "-p,2222,--,h")

// ---------------------------------------------------------------- H1 validation

ok("H1 validateHost flags a leading-dash host",
   Model.validateHost({ name: "n", host: injected }).length > 0)
ok("H1 validateHost flags a leading-dash alias",
   Model.validateHost({ name: "n", alias: injected }).length > 0)
ok("H1 validateHost flags a leading-dash user",
   Model.validateHost({ name: "n", host: "h", user: "-oX" }).length > 0)

// A leading dash on the *host* is not an option to ssh when a user is
// prefixed: `root@-oX` is one word that starts with "root@". It is still
// refused by the editor, so a user is told why rather than left to discover it.
eq("safe-but-flagged destination is still one word",
   Model.destinationArgs({ user: "root", host: "-oX" }).join(","), "--,root@-oX")
ok("safe-but-flagged destination is flagged by the editor",
   Model.validateHost({ name: "n", user: "root", host: "-oX" }).length > 0)

// The display string is not the argv: `--` stays out of what the user reads.
eq("connectCommand hides the -- marker",
   Model.connectCommand({ host: "h", port: "2222" }, "shell"), "ssh '-p' '2222' 'h'")
eq("connectCommand is empty for an injected destination",
   Model.connectCommand({ host: injected }, "shell"), "")

// ---------------------------------------------------------------- L2 types
//
// A wrong-typed value must collapse to empty rather than being stringified into
// something connectable.

eq("L2 array host collapses", Model.normalizeHost({ host: ["a", "b"] }).host, "")
eq("L2 array port collapses", Model.normalizeHost({ port: ["2222"] }).port, "")
eq("L2 object name collapses", Model.normalizeHost({ name: {} }).name, "")
eq("L2 boolean host collapses", Model.normalizeHost({ host: true }).host, "")
eq("L2 null host collapses", Model.normalizeHost({ host: null }).host, "")
eq("L2 number port is kept", Model.normalizeHost({ port: 2222 }).port, "2222")
eq("L2 number host is kept", Model.normalizeHost({ host: 1234 }).host, "1234")

// ---------------------------------------------------------------- L1 escapes

eq("L1 escape sequence is stripped from a name",
   Model.normalizeHost({ name: "a\u001b[31mred" }).name, "a[31mred")
eq("L1 newline is stripped from notes",
   Model.normalizeHost({ notes: "a\nb" }).notes, "ab")
eq("L1 NUL is stripped from a host",
   Model.normalizeHost({ host: "a\u0000b" }).host, "ab")
eq("L1 tab is stripped from a user",
   Model.normalizeHost({ user: "a\tb" }).user, "ab")

// ---------------------------------------------------------------- L3 import

eq("L3 import keeps only destination-shaped tokens",
   Model.parseSshConfigHosts("Host -oProxyCommand=x\nHost 'q'\nHost \"d\"\nHost =w\nHost good\n").join(","),
   "good")
ok("L3 import drops a dash-prefixed alias",
   Model.parseSshConfigHosts("Host " + injected + "\n").length === 0)
eq("L3 ordinary aliases still import",
   Model.parseSshConfigHosts("Host bastion\nHost db-01.example.com\nHost v2_host\n").join(","),
   "bastion,db-01.example.com,v2_host")

// ---------------------------------------------------------------- M4 size cap

eq("M4 an oversized library is refused",
   Model.parseHosts('[{"host":"h"}' + " ".repeat(2 * 1024 * 1024)).ok, false)
eq("M4 the refusal names the reason",
   Model.parseHosts('[{"host":"h"}' + " ".repeat(2 * 1024 * 1024)).error, "Library is too large")
ok("M4 a realistic library still loads",
   Model.parseHosts(JSON.stringify({ hosts: [{ host: "h" }] })).ok === true)

// ---------------------------------------------------------------- L7 prototype

const protoLib = JSON.stringify({
  hosts: [
    { id: "__proto__", host: "1.2.3.4" },
    { id: "constructor", host: "1.2.3.5" }
  ]
})
const protoHosts = Model.parseHosts(protoLib).hosts
// SECURITY-FIXES.md §3.2 phrased this as "regenerates the id". With the
// null-prototype `seen` map of §1.6 there is nothing left to regenerate it —
// the hostile id is now an ordinary key rather than a write through
// Object.prototype, which is the property §1.6 is actually protecting. The
// assertions below pin that property.
eq("L7 __proto__ id survives as an ordinary key", protoHosts[0].id, "__proto__")
eq("L7 constructor id survives as an ordinary key", protoHosts[1].id, "constructor")
ok("L7 the hostile id reaches argv only through the -- guard",
   Model.destinationArgs(protoHosts[0]).join(",") === "--,1.2.3.4",
   Model.destinationArgs(protoHosts[0]).join(","))
eq("L7 no prototype pollution from parseHosts", {}.polluted, undefined)
eq("L7 Object.prototype is untouched", Object.prototype.polluted, undefined)

// A live-session map keyed by a hostile host id must be an ordinary key, not a
// write through the prototype.
const sessionMap = Model.liveSessionMap([{ id: "__proto__", host: "h" }], { h: 1 })
eq("L7 liveSessionMap stores a hostile id as a plain key", sessionMap["__proto__"], 1)
eq("L7 liveSessionMap did not touch Object.prototype", ({}).id, undefined)

print("")
print(failures === 0
  ? `All ${checks} checks passed`
  : `${failures} of ${checks} checks FAILED`)
process.exit(failures === 0 ? 0 : 1)