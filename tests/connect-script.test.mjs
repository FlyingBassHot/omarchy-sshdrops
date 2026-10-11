// Exercises Model.connectScript against a real bash.
//
// The wrapper decides whether a terminal stays open after a failed ssh, so
// "does this script parse and behave" is not something a string comparison can
// answer. These run it for real.
//
//   node tests/connect-script.test.mjs

import { readFileSync } from "node:fs"
import { execFileSync, spawn } from "node:child_process"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"

const here = dirname(fileURLToPath(import.meta.url))
const source = readFileSync(join(here, "..", "Model.js"), "utf8")
const body = source.replace(/^\.pragma library\s*/, "")
const Model = new Function(`${body}\nreturn { connectScript: connectScript };`)()

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

// Run a generated script under bash, feeding it `input` on stdin. Returns
// { code, out }.
function run(script, input = "") {
  try {
    const out = execFileSync("bash", ["-c", script], {
      encoding: "utf8",
      input,
      timeout: 8000,
      env: { ...process.env, PATH: process.env.PATH }
    })
    return { code: 0, out }
  } catch (e) {
    return { code: e.status ?? -1, out: `${e.stdout ?? ""}` }
  }
}

// ------------------------------------------------------------------ success

// A successful ssh closes the window immediately: no message, no keypress
// wait. Input is supplied anyway — if the script waited, the leftover would
// show up as a hang rather than a clean exit.
const ok = run(Model.connectScript("true", "Host"))
eq("success exits 0", ok.code, 0)
eq("success prints nothing extra", ok.out.trim(), "")

// ------------------------------------------------------------------ failure

// A failed ssh must hold the window and say why.
const bad = run(Model.connectScript("exit 255", "Web"), "\n")
eq("failure propagates the exit code", bad.code, 255)
eq("failure reports the exit code", /ssh failed \(exit 255\)/.test(bad.out), true)
eq("failure waits for a keypress", /Press Enter to close/.test(bad.out), true)

// The wait is real: with stdin held open and nothing written to it, the
// script waits instead of exiting. execFileSync always closes stdin, which
// would make `read` return immediately and prove nothing, so this one uses
// spawn with the pipe left open.
function runHoldingStdin(script, timeoutMs) {
  return new Promise(resolve => {
    const child = spawn("bash", ["-c", script], { stdio: ["pipe", "pipe", "pipe"] })
    let out = ""
    child.stdout.on("data", d => { out += d })
    const timer = setTimeout(() => {
      child.kill("SIGKILL")
      resolve({ code: 124, out, timedOut: true })
    }, timeoutMs)
    child.on("close", code => { clearTimeout(timer); resolve({ code, out, timedOut: false }) })
  })
}

const blocked = await runHoldingStdin(Model.connectScript("exit 255", "Web"), 2500)
eq("failure blocks without a keypress", blocked.code, 124)
eq("failure still reported while blocked", /ssh failed \(exit 255\)/.test(blocked.out), true)

// ------------------------------------------------------------- exit 130

// Ctrl-C is a deliberate disconnect, not a failure. It must not park a window
// the user then has to dismiss.
const interrupted = run(Model.connectScript("exit 130", "Web"), "")
eq("Ctrl-C exits immediately", interrupted.code, 130)
eq("Ctrl-C prints no failure", interrupted.out.trim(), "")

// --------------------------------------------------------- other failures

for (const code of [1, 2, 6, 255]) {
  const r = run(Model.connectScript(`exit ${code}`, "Web"), "\n")
  eq(`exit ${code} is treated as a failure`, /ssh failed/.test(r.out), true)
  eq(`exit ${code} propagates`, r.code, code)
}

// ------------------------------------------------- the real ssh exit code

// 255 is what ssh uses for its own transport and auth failures, which is the
// case this wrapper exists for.
const sshLike = run(
  Model.connectScript("bash -c 'echo \"Permission denied, please try again.\"; exit 255'", "Aliyun"),
  "\n"
)
eq("ssh-style failure keeps its message", /Permission denied/.test(sshLike.out), true)
eq("ssh-style failure is held open", /Press Enter to close/.test(sshLike.out), true)

// ------------------------------------------------------ hostile host names

// The label reaches a command line inside the notification call, so it has to
// stay inert.
for (const label of ["'; touch /tmp/opencode/pwned; '", "$(id)", "back`tick`"]) {
  const r = run(Model.connectScript("exit 255", label), "\n")
  eq(`hostile label stays inert (${label})`, r.code, 255)
}

console.log("")
console.log(failures === 0
  ? `All ${checks} checks passed`
  : `${failures} of ${checks} checks FAILED`)
process.exit(failures === 0 ? 0 : 1)
