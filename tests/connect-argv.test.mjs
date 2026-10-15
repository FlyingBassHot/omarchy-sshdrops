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
  const quoted = destination.map(shellQuote).join(" ")
  const script = mode === "shell-reconnect"
    ? "bash -ic " + shellQuote("ssh " + quoted)
    : "ssh " + quoted
  return [
    "setsid", "uwsm-app", "--",
    "xdg-terminal-exec",
    "--app-id=org.omarchy.sshdrops",
    "--title=SSHDrops",
    "-e", "bash", "-c", script
  ]
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

const plain = buildArgv({ alias: "bastion" }, "shell")
eq("launcher prefix is stable",
   plain.slice(0, 3), ["setsid", "uwsm-app", "--"])
// Without this `-e`, xdg-terminal-exec hands the trailing arguments to the
// terminal as filenames instead of a command: no ssh, an empty window, or a
// reused tty that scrambles an existing terminal's display.
eq("-e is present", plain.includes("-e"), true)
eq("command runs under bash -c", plain.slice(-3, -1), ["bash", "-c"])
eq("plain alias", plain[plain.length - 1], "ssh 'bastion'")

eq("user@host",
   buildArgv({ alias: "", user: "deploy", host: "gw.lan" }, "shell").pop(),
   "ssh 'deploy@gw.lan'")

// The saved port has to reach the terminal, not just the panel row, and it has
// to land before the destination where ssh still reads options.
eq("port reaches the command",
   buildArgv({ alias: "", user: "root", host: "10.100.210.88", port: "39600" }, "shell").pop(),
   "ssh '-p' '39600' 'root@10.100.210.88'")
eq("port with an alias overrides the config",
   buildArgv({ alias: "newapi", port: "39600" }, "shell").pop(),
   "ssh '-p' '39600' 'newapi'")
eq("no port means no -p",
   buildArgv({ alias: "bastion" }, "shell").pop(), "ssh 'bastion'")

eq("reconnect keeps the port",
   buildArgv({ alias: "", user: "root", host: "10.100.210.88", port: "39600" }, "shell-reconnect").pop(),
   "bash -ic 'ssh '\\''-p'\\'' '\\''39600'\\'' '\\''root@10.100.210.88'\\'''")

eq("reconnect alias",
   buildArgv({ alias: "bastion" }, "shell-reconnect").pop(),
   "bash -ic 'ssh '\\''bastion'\\'''")

eq("reconnect user@host",
   buildArgv({ alias: "", user: "deploy", host: "gw.lan" }, "shell-reconnect").pop(),
   "bash -ic 'ssh '\\''deploy@gw.lan'\\'''")

// ------------------------------------------------------------ hostile hosts
//
// These are the cases that matter: a host name is user input on its way to a
// shell, and the script handed to `bash -c` is the one place it is embedded
// in a string rather than passed as an argv element.

eq("plain mode quotes the semicolon",
   buildArgv({ host: "; rm -rf ~" }, "shell").pop(), "ssh '; rm -rf ~'")

eq("plain mode escapes a single quote",
   buildArgv({ host: "a'b" }, "shell").pop(), "ssh 'a'\\''b'")

eq("plain mode quotes command substitution",
   buildArgv({ host: "$(id)" }, "shell").pop(), "ssh '$(id)'")

eq("plain mode quotes backticks",
   buildArgv({ host: "`id`" }, "shell").pop(), "ssh '`id`'")

// Every connect must keep the launcher prefix intact and end with exactly one
// command for bash to run.
for (const [label, target, port] of [
  ["semicolon", "; rm -rf ~"],
  ["quote", "a'b"],
  ["dollar", "$(id)"],
  ["space", "two words"],
  ["glob", "*"],
  ["newline", "a\nrm -rf ~"],
  ["newline with port", "a\nrm -rf ~", "2222"],
  ["metacharacters with port", "; rm -rf ~", "2222"]
]) {
  for (const mode of ["shell", "shell-reconnect"]) {
    const argv = buildArgv({ host: target, port: port || "" }, mode)
    eq(`launcher prefix (${label}/${mode})`, argv.slice(0, 3),
       ["setsid", "uwsm-app", "--"])
    eq(`-e present (${label}/${mode})`, argv.includes("-e"), true)
    eq(`runs via bash -c (${label}/${mode})`, argv.slice(-3, -1), ["bash", "-c"])

    // Ask a real bash to expand the script into argv and report every word
    // separated by a sentinel, so an embedded newline cannot split a result
    // in half and hide a failure. For the reconnect mode the wrapper is
    // stripped first, since the inner ssh is what must survive intact.
    const script = argv[argv.length - 1]
    const inner = mode === "shell-reconnect"
      ? execFileSync("bash", ["-c", `printf '%s\\x01' ${script.replace(/^bash -ic /, "")}`], { encoding: "utf8" })
      : script
    const probe = `set -- ${inner}; for a in "$@"; do printf '%s\\x01' "$a"; done`
    const words = execFileSync("bash", ["-c", probe], { encoding: "utf8" })
      .split("\x01").filter(w => w !== "")

    eq(`no shell metacharacters execute (${label}/${mode})`, words[0], "ssh")
    // With a port the argv is `-p <port> <destination>`; without one it is
    // just the destination. Either way nothing after ssh may execute.
    eq(`target is one literal word (${label}/${mode})`, words.length, port ? 4 : 2)
    if (port) {
      eq(`port option kept (${label}/${mode})`, words[1], "-p")
      eq(`port value kept (${label}/${mode})`, words[2], port)
      eq(`target survives intact (${label}/${mode})`, words[3], target)
    } else {
      eq(`target survives intact (${label}/${mode})`, words[1], target)
    }
  }
}

console.log("")
console.log(failures === 0
  ? `All ${checks} checks passed`
  : `${failures} of ${checks} checks FAILED`)
process.exit(failures === 0 ? 0 : 1)
