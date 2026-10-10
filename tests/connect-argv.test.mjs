// Verifies the argv that Service.connect builds, especially the
// shell-reconnect path where the host name has to survive being embedded in a
// `bash -ic` command string.
//
//   node tests/connect-argv.test.mjs

import { readFileSync } from "node:fs"
import { execFileSync } from "node:child_process"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"

const here = dirname(fileURLToPath(import.meta.url))
const source = readFileSync(join(here, "..", "Model.js"), "utf8")
const body = source.replace(/^\.pragma library\s*/, "")
const Model = new Function(
  `${body}\nreturn { destinationArgs: destinationArgs };`
)()

// qs.Commons.Util.shellQuote, verbatim. Kept in sync by hand because the
// plugin runs it from QML; the point of this test is to pin the behavior it
// relies on.
const shellQuote = v => "'" + String(v ?? "").replace(/'/g, "'\\''") + "'"

// The same construction as Service.connect.
function buildArgv(host, mode) {
  const destination = Model.destinationArgs(host)
  if (mode === "shell-reconnect") {
    const command = "ssh " + destination.map(shellQuote).join(" ")
    return ["omarchy-launch-terminal", "bash", "-ic", command]
  }
  return ["omarchy-launch-terminal", "ssh"].concat(destination)
}

let failures = 0
let checks = 0
function eq(name, actual, expected) {
  checks++
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a === e) return
  failures++
  console.log(`FAIL: ${name}\n  got  ${a}\n  want ${e}`)
}

// ----------------------------------------------------------- ordinary hosts

eq("plain alias",
   buildArgv({ alias: "bastion" }, "shell"),
   ["omarchy-launch-terminal", "ssh", "bastion"])

eq("user@host",
   buildArgv({ alias: "", user: "deploy", host: "gw.lan" }, "shell"),
   ["omarchy-launch-terminal", "ssh", "deploy@gw.lan"])

eq("reconnect alias",
   buildArgv({ alias: "bastion" }, "shell-reconnect"),
   ["omarchy-launch-terminal", "bash", "-ic", "ssh 'bastion'"])

eq("reconnect user@host",
   buildArgv({ alias: "", user: "deploy", host: "gw.lan" }, "shell-reconnect"),
   ["omarchy-launch-terminal", "bash", "-ic", "ssh 'deploy@gw.lan'"])

// ------------------------------------------------------------ hostile hosts
//
// These are the cases that matter: a host name is user input on its way to a
// shell, and the reconnect path is the only place it is embedded in a command
// string rather than passed as an argv element.

const semicolon = buildArgv({ host: "; rm -rf ~" }, "shell")
eq("plain mode keeps metacharacters inert as argv",
   semicolon, ["omarchy-launch-terminal", "ssh", "; rm -rf ~"])

const semiRc = buildArgv({ host: "; rm -rf ~" }, "shell-reconnect")
eq("reconnect mode quotes the semicolon", semiRc[3], "ssh '; rm -rf ~'")

const quoteRc = buildArgv({ host: "a'b" }, "shell-reconnect")
eq("reconnect mode escapes a single quote", quoteRc[3], "ssh 'a'\\''b'")

const substRc = buildArgv({ host: "$(id)" }, "shell-reconnect")
eq("reconnect mode quotes command substitution", substRc[3], "ssh '$(id)'")

const backtickRc = buildArgv({ host: "`id`" }, "shell-reconnect")
eq("reconnect mode quotes backticks", backtickRc[3], "ssh '`id`'")

const newlineRc = buildArgv({ host: "a\nrm -rf ~" }, "shell-reconnect")
eq("reconnect mode survives a newline", newlineRc[3], "ssh 'a\nrm -rf ~'")

// Every reconnect argv must keep ssh as the command and the wrapper's target
// as a single literal word. `split(" ")` would be the wrong test — spaces
// *inside* the quoted literal are supposed to survive — so hand the command
// to a real bash and check what it actually resolves to.
for (const [label, host] of [
  ["semicolon", "; rm -rf ~"],
  ["quote", "a'b"],
  ["dollar", "$(id)"],
  ["space", "two words"],
  ["glob", "*"]
]) {
  const argv = buildArgv({ host }, "shell-reconnect")
  eq(`reconnect argv shape (${label})`, argv.slice(0, 3),
     ["omarchy-launch-terminal", "bash", "-ic"])

  // Echo back what bash thinks the last word is, with a sentinel so an empty
  // or split result is unmistakable.
  const probe = `set -- ${argv[3]}; printf '[%s]' "$2"`
  const resolved = execFileSync("bash", ["-c", probe], { encoding: "utf8" })
  eq(`reconnect target is one literal word (${label})`, resolved, `[${host}]`)
}

console.log("")
console.log(failures === 0
  ? `All ${checks} checks passed`
  : `${failures} of ${checks} checks FAILED`)
process.exit(failures === 0 ? 0 : 1)
