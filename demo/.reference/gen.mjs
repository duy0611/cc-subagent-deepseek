import { render } from "./ref.js";
import fs from "node:fs";
const dir = process.argv[2];
for (const f of fs.readdirSync(dir).filter((f) => f.endsWith(".md")).sort()) {
  const toc = f.includes("toc");
  fs.writeFileSync(`${dir}/${f.replace(/\.md$/, toc ? ".toc.html" : ".html")}`, render(fs.readFileSync(`${dir}/${f}`, "utf8"), { toc }));
}
