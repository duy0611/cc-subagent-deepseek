# mdx: a tiny Markdown-to-HTML converter, specification

Pure ESM JavaScript, Node 24, **no dependencies**. Public API in `src/index.js`:

```js
export function render(markdown, options = {})   // -> string of HTML
// options.toc: boolean, default false: prepend a table of contents
```

CLI: `bin/mdx.js [--toc] [file]` reads the file (or stdin if no file is given), writes the HTML to stdout, and exits 0.
Missing file: write `mdx: cannot read <file>` to stderr and exit 1. Unknown flag: write `mdx: unknown option <flag>` to stderr and exit 2.

## Output format
- Each top-level block renders on its own line(s), and blocks are joined by `\n`. Non-empty output ends with exactly one `\n`.
  Empty or whitespace-only input renders as `""`.
- Input line endings `\r\n` are treated as `\n`. A single trailing newline at the end of the input does not create an extra empty line.

## HTML escaping
In all text (including code), escape `&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`, `"` → `&quot;`. Attribute values are escaped the same way.

## Block elements (checked in this order at the start of each line)
1. **Fenced code**: a line matching ```` ``` ```` optionally followed by a language word (`\w*`) opens a block. It is closed by
   the next line that is exactly ```` ``` ```` (trailing spaces allowed), or by the end of input.
   Output: `<pre><code class="language-LANG">BODY</code></pre>`, with no `class` attribute if there's no language. BODY is the escaped
   lines joined by `\n` plus a trailing `\n`; an empty block has an empty BODY. Content inside is never parsed.
2. **ATX heading**: `#`..`######`, then one space, then text (trailing spaces trimmed). Output: `<hN id="SLUG">INLINE</hN>` (see Slugs).
3. **Horizontal rule**: a line that is exactly `---` (trailing spaces allowed) → `<hr>`.
4. **Blockquote**: consecutive lines starting with `>`. Strip `>` and one optional following space, then parse the stripped
   lines recursively as blocks. Output: `<blockquote>\nINNER\n</blockquote>`, where INNER is the inner blocks joined by `\n`.
5. **Lists**: consecutive lines matching `^( *)(-|\d+\.) (.*)$`. The nesting level is (number of leading spaces) / 2.
   - A list's tag (`ul` for `-`, `ol` for `N.`) is decided by its **first** item. Items at deeper levels form a nested list
     inside the preceding item.
   - Output, one tag per line: `<ul>` / `<li>INLINE</li>` / `</ul>`. An item with a nested list renders as
     `<li>INLINE\n<ul>\n...\n</ul>\n</li>`.
   - A list ends at the first line that isn't a list item (including a blank line).
6. **Paragraph**: anything else. Consecutive non-blank lines are joined with a single space, after trimming each line. A paragraph
   ends at a blank line, or at a line that starts a fenced code block, heading, `---`, `>` or list item.
   Output: `<p>INLINE</p>`.
   Blank lines elsewhere are ignored.

## Inline elements (scanned left to right; the first rule that matches at the current position wins)
1. Code span: `` `text` `` (no backticks inside, non-empty) → `<code>ESCAPED</code>`. Contents are not parsed further.
2. Link: `[text](url)`, where text has no `]` and url has no `)` or whitespace → `<a href="ESCAPED_URL">INLINE(text)</a>`.
3. Strong: `**text**` (shortest match) → `<strong>INLINE(text)</strong>`.
4. Emphasis: `*text*` (no `*` inside, non-empty) → `<em>INLINE(text)</em>`.
5. Otherwise emit the escaped character. Unmatched markers (`*`, `[`, `` ` ``) are literal text.

## Slugs (heading ids)
Lowercase the raw heading text (before inline rendering). Remove every character except `a-z`, `0-9`, space and `-`, then trim.
Replace runs of spaces with `-`, collapse runs of `-`, and strip leading/trailing `-`. If the result is empty, use `section`.
Duplicates within one document get suffixes in order: `intro`, `intro-1`, `intro-2`. A slugger is created per `render()` call.

## Table of contents (`options.toc`)
Collect every `h2` and `h3` in document order (including headings inside blockquotes). If there are none, add nothing.
Otherwise prepend this block before all other blocks:
`<nav class="toc">\nLIST\n</nav>`, where LIST is a `<ul>` of `<li><a href="#SLUG">INLINE</a></li>`. An `h3` nests under the
nearest preceding `h2`, and an `h3` with no preceding `h2` is listed at the top level. The list uses the same one-tag-per-line format.
