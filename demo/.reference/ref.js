// Private reference implementation used only to generate the golden fixtures.
const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

function inline(s) {
  let out = "", i = 0, m;
  while (i < s.length) {
    const rest = s.slice(i);
    if ((m = rest.match(/^`([^`]+)`/))) { out += `<code>${esc(m[1])}</code>`; i += m[0].length; continue; }
    if ((m = rest.match(/^\[([^\]]+)\]\(([^)\s]+)\)/))) { out += `<a href="${esc(m[2])}">${inline(m[1])}</a>`; i += m[0].length; continue; }
    if ((m = rest.match(/^\*\*(.+?)\*\*/))) { out += `<strong>${inline(m[1])}</strong>`; i += m[0].length; continue; }
    if ((m = rest.match(/^\*([^*]+)\*/))) { out += `<em>${inline(m[1])}</em>`; i += m[0].length; continue; }
    out += esc(s[i]); i++;
  }
  return out;
}

function makeSlugger() {
  const seen = new Map();
  return (raw) => {
    let s = raw.toLowerCase().replace(/[^a-z0-9 -]/g, "").trim().replace(/ +/g, "-").replace(/-+/g, "-").replace(/^-|-$/g, "");
    if (!s) s = "section";
    const n = seen.get(s) ?? 0; seen.set(s, n + 1);
    return n ? `${s}-${n}` : s;
  };
}

const RE = { fence: /^```(\w*)\s*$/, heading: /^(#{1,6}) (.+?)\s*$/, hr: /^---\s*$/, quote: /^>/, item: /^( *)(-|\d+\.) (.*)$/ };
const startsBlock = (l) => RE.fence.test(l) || RE.heading.test(l) || RE.hr.test(l) || RE.quote.test(l) || /^(-|\d+\.) /.test(l);

function blocks(lines, ctx) {
  const out = []; let i = 0;
  while (i < lines.length) {
    const line = lines[i]; let m;
    if (!line.trim()) { i++; continue; }
    if ((m = line.match(RE.fence))) {
      const body = []; i++;
      while (i < lines.length && !/^```\s*$/.test(lines[i])) body.push(lines[i++]);
      i++;
      const cls = m[1] ? ` class="language-${m[1]}"` : "";
      out.push(`<pre><code${cls}>${body.length ? esc(body.join("\n")) + "\n" : ""}</code></pre>`);
      continue;
    }
    if ((m = line.match(RE.heading))) {
      const lvl = m[1].length, text = m[2], id = ctx.slug(text);
      ctx.headings.push({ lvl, id, html: inline(text) });
      out.push(`<h${lvl} id="${id}">${inline(text)}</h${lvl}>`); i++; continue;
    }
    if (RE.hr.test(line)) { out.push("<hr>"); i++; continue; }
    if (RE.quote.test(line)) {
      const inner = [];
      while (i < lines.length && RE.quote.test(lines[i])) inner.push(lines[i++].replace(/^> ?/, ""));
      out.push(`<blockquote>\n${blocks(inner, ctx).join("\n")}\n</blockquote>`); continue;
    }
    if (/^(-|\d+\.) /.test(line)) {
      const items = [];
      while (i < lines.length && (m = lines[i].match(RE.item))) { items.push({ level: m[1].length / 2, ordered: m[2] !== "-", text: m[3] }); i++; }
      out.push(renderList(items, 0, 0).html); continue;
    }
    const para = [];
    while (i < lines.length && lines[i].trim() && !(para.length && startsBlock(lines[i]))) para.push(lines[i++].trim());
    out.push(`<p>${inline(para.join(" "))}</p>`);
  }
  return out;
}

function renderList(items, idx, level, render = (it) => inline(it.text)) {
  const tag = items[idx].ordered ? "ol" : "ul"; const out = [`<${tag}>`];
  while (idx < items.length && items[idx].level === level) {
    const it = items[idx++]; let li = `<li>${render(it)}`;
    if (idx < items.length && items[idx].level > level) { const r = renderList(items, idx, level + 1, render); li += `\n${r.html}\n`; idx = r.idx; }
    out.push(li + "</li>");
  }
  out.push(`</${tag}>`);
  return { html: out.join("\n"), idx };
}

export function render(md, opts = {}) {
  const ctx = { slug: makeSlugger(), headings: [] };
  const lines = md.replace(/\r\n/g, "\n").split("\n"); if (lines.at(-1) === "") lines.pop();
  const body = blocks(lines, ctx);
  if (opts.toc) {
    const hs = ctx.headings.filter((h) => h.lvl === 2 || h.lvl === 3);
    if (hs.length) {
      let seenH2 = false;
      const items = hs.map((h) => { if (h.lvl === 2) seenH2 = true; return { level: h.lvl === 3 && seenH2 ? 1 : 0, ordered: false, h }; });
      body.unshift(`<nav class="toc">\n${renderList(items, 0, 0, (it) => `<a href="#${it.h.id}">${it.h.html}</a>`).html}\n</nav>`);
    }
  }
  return body.length ? body.join("\n") + "\n" : "";
}
