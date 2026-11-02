import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const source = readFileSync(new URL("../../ki_optimizer_module/webroot/app.js", import.meta.url), "utf8");

// app.js touches the DOM at load time, so only the pure helpers are evaluated.
function loadFunction(name) {
  const match = source.match(new RegExp(`^function ${name}\\(.*?^}`, "ms"));
  assert.ok(match, `${name} not found in app.js`);
  return vm.runInNewContext(`(${match[0]})`);
}

const shellQuote = loadFunction("shellQuote");
const escapeHtml = loadFunction("escapeHtml");

test("shellQuote hands hostile values to the shell literally", () => {
  for (const value of ["com.game", "x$(id)", "a'b", "`id`", "a b;c", "'", ""]) {
    const output = execFileSync("sh", ["-c", `printf %s ${shellQuote(value)}`], { encoding: "utf8" });
    assert.equal(output, value);
  }
});

test("escapeHtml neutralizes markup", () => {
  assert.equal(escapeHtml(`<img src="x">&`), "&lt;img src=&quot;x&quot;&gt;&amp;");
});
