// Golden tests: test/fixtures/NAME.md renders to NAME.html (or NAME.toc.html with { toc: true }).
// These are the product owner's acceptance tests. Do not edit them or the fixtures.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { render } from "../src/index.js";

const dir = new URL("./fixtures/", import.meta.url);
for (const f of fs.readdirSync(dir).filter((f) => f.endsWith(".md")).sort()) {
  const name = f.replace(/\.md$/, "");
  const toc = name.includes("toc");
  const expected = fs.readFileSync(new URL(`${name}${toc ? ".toc" : ""}.html`, dir), "utf8");
  test(`golden: ${name}`, () => {
    assert.equal(render(fs.readFileSync(new URL(f, dir), "utf8"), { toc }), expected);
  });
}
