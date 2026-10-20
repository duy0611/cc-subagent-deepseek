// CLI acceptance tests (product owner). Do not edit.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";

const cli = new URL("../bin/mdx.js", import.meta.url).pathname;
const run = (args, input) => spawnSync(process.execPath, [cli, ...args], { input, encoding: "utf8" });

test("cli: stdin to stdout", () => {
  const r = run([], "# Hi\n");
  assert.equal(r.status, 0);
  assert.equal(r.stdout, '<h1 id="hi">Hi</h1>\n');
});
test("cli: file argument with --toc", () => {
  const r = run(["--toc", new URL("./fixtures/11-toc.md", import.meta.url).pathname]);
  assert.equal(r.status, 0);
  assert.match(r.stdout, /^<nav class="toc">/);
});
test("cli: missing file", () => {
  const r = run(["/nonexistent.md"]);
  assert.equal(r.status, 1);
  assert.equal(r.stderr.trim(), "mdx: cannot read /nonexistent.md");
});
test("cli: unknown option", () => {
  const r = run(["--bogus"]);
  assert.equal(r.status, 2);
  assert.equal(r.stderr.trim(), "mdx: unknown option --bogus");
});
