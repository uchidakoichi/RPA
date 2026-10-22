// Builds the browser-readable manuals and the download package (maintainers only, needs Node.js):
//   powershell -File build\Build-FujiTemplateDoc.ps1   (regenerates samples/ and docs/src/templates.md)
//   node tools/build_docs.js        (docs/src/*.md -> docs/*.html, then dist/fujikyun_docs_samples.zip)
// No external packages: a small Markdown converter for the subset the docs use, and a ZIP writer
// on top of Node's zlib, so the result opens offline in any browser on a municipal PC.
"use strict";
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const root = path.join(__dirname, "..");
const srcDir = path.join(root, "docs", "src");
const outDir = path.join(root, "docs");

const PAGES = [
    { src: "index.md", out: "index.html", nav: "目次" },
    { src: "setup.md", out: "setup.html", nav: "準備" },
    { src: "tutorial.md", out: "tutorial.html", nav: "チュートリアル" },
    { src: "manual.md", out: "manual.html", nav: "操作マニュアル" },
    { src: "templates.md", out: "templates.html", nav: "テンプレート解説" },
    { src: "faq.md", out: "faq.html", nav: "Q&A" },
    { src: "changes.md", out: "changes.html", nav: "更新履歴" }
];

// ---------------------------------------------------------------- Markdown -> HTML
const esc = s => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

// Heading ids: same idea as GitHub (lower case, punctuation removed, spaces -> "-"), so "#3-基本の考え方csvの1行1回" works
function slug(text) {
    return text.replace(/<[^>]+>/g, "").toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, "").trim().replace(/\s+/g, "-");
}

function rewriteHref(href) {
    return href
        .replace(/^\.\.\/\.\.\/samples/, "../samples")
        .replace(/^([\w-]+)\.md(#|$)/, "$1.html$2")
        .replace(/^README\.md/, "index.html")
        .replace(/^index\.html/, "index.html");
}

function inline(text) {
    const codes = [];
    let s = text.replace(/`([^`]+)`/g, (m, c) => { codes.push(c); return "\u0000" + (codes.length - 1) + "\u0000"; });
    s = esc(s);
    s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
    s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (m, t, href) => '<a href="' + rewriteHref(href.replace(/&amp;/g, "&")) + '">' + t + "</a>");
    s = s.replace(/\\\|/g, "|");
    return s.replace(/\u0000(\d+)\u0000/g, (m, n) => "<code>" + esc(codes[+n]) + "</code>");
}

const indentOf = line => line.match(/^ */)[0].length;
const LIST_RE = /^( *)([-*]|\d+\.) +(.*)$/;

function dedent(lines) {
    const ind = Math.min(...lines.filter(l => l.trim() !== "").map(indentOf));
    return lines.map(l => l.slice(Math.min(ind, indentOf(l))));
}

function splitRow(line) {
    const cells = [];
    let cur = "";
    const body = line.trim().replace(/^\|/, "").replace(/\|$/, "");
    for (let i = 0; i < body.length; i++) {
        if (body[i] === "\\" && body[i + 1] === "|") { cur += "\\|"; i++; continue; }
        if (body[i] === "|") { cells.push(cur.trim()); cur = ""; continue; }
        cur += body[i];
    }
    cells.push(cur.trim());
    return cells;
}

function convert(lines, ids) {
    const out = [];
    let i = 0;
    while (i < lines.length) {
        const line = lines[i];
        if (line.trim() === "") { i++; continue; }
        if (/^ *```/.test(line)) {
            const buf = [];
            i++;
            while (i < lines.length && !/^ *```/.test(lines[i])) { buf.push(lines[i]); i++; }
            i++;
            out.push("<pre><code>" + esc(dedent(buf.length ? buf : [""]).join("\n")) + "</code></pre>");
            continue;
        }
        if (/^---+\s*$/.test(line)) { out.push("<hr>"); i++; continue; }
        let m = line.match(/^(#{1,6}) +(.*)$/);
        if (m) {
            const html = inline(m[2]);
            let id = slug(m[2]);
            for (let n = 1; ids.has(id); n++) { id = slug(m[2]) + "-" + n; }
            ids.add(id);
            out.push("<h" + m[1].length + ' id="' + esc(id) + '">' + html + "</h" + m[1].length + ">");
            i++;
            continue;
        }
        if (/^<a id="[^"]+"><\/a>$/.test(line.trim())) {
            const id = line.match(/id="([^"]+)"/)[1];
            ids.add(id);
            out.push(line.trim());
            i++;
            continue;
        }
        if (/^> ?/.test(line)) {
            const buf = [];
            while (i < lines.length && /^> ?/.test(lines[i])) { buf.push(lines[i].replace(/^> ?/, "")); i++; }
            out.push("<blockquote>" + convert(buf, ids) + "</blockquote>");
            continue;
        }
        if (/^\|/.test(line.trim()) && i + 1 < lines.length && /^\s*\|[\s:|-]+\|\s*$/.test(lines[i + 1])) {
            const head = splitRow(line);
            i += 2;
            const rows = [];
            while (i < lines.length && /^\s*\|/.test(lines[i])) { rows.push(splitRow(lines[i])); i++; }
            out.push('<div class="table-wrap"><table><thead><tr>' + head.map(c => "<th>" + inline(c) + "</th>").join("") + "</tr></thead><tbody>" +
                rows.map(r => "<tr>" + r.map(c => "<td>" + inline(c) + "</td>").join("") + "</tr>").join("") + "</tbody></table></div>");
            continue;
        }
        m = line.match(LIST_RE);
        if (m) {
            const baseIndent = m[1].length;
            const ordered = /\d/.test(m[2]);
            const items = [];
            const startNo = ordered ? parseInt(m[2], 10) : 1;
            while (i < lines.length) {
                if (lines[i].trim() === "") {
                    // blank lines between items keep the same list going
                    let j = i;
                    while (j < lines.length && lines[j].trim() === "") { j++; }
                    const nm = j < lines.length ? lines[j].match(LIST_RE) : null;
                    if (!nm || nm[1].length !== baseIndent || /\d/.test(nm[2]) !== ordered) { break; }
                    i = j;
                }
                const lm = lines[i].match(LIST_RE);
                if (!lm || lm[1].length !== baseIndent || /\d/.test(lm[2]) !== ordered) { break; }
                const itemLines = [lm[3]];
                i++;
                while (i < lines.length) {
                    if (lines[i].trim() === "") {
                        // a blank line ends the item unless indented content follows
                        let j = i + 1;
                        while (j < lines.length && lines[j].trim() === "") { j++; }
                        if (j < lines.length && indentOf(lines[j]) > baseIndent) { itemLines.push(""); i++; continue; }
                        break;
                    }
                    if (indentOf(lines[i]) <= baseIndent) { break; }
                    itemLines.push(lines[i]);
                    i++;
                }
                const first = itemLines[0];
                const rest = itemLines.slice(1);
                const restHtml = rest.some(l => l.trim() !== "") ? convert(dedent(rest), ids) : "";
                items.push("<li>" + inline(first) + restHtml + "</li>");
            }
            out.push((ordered ? "<ol" + (startNo !== 1 ? ' start="' + startNo + '"' : "") + ">" : "<ul>") + items.join("") + (ordered ? "</ol>" : "</ul>"));
            continue;
        }
        const buf = [];
        while (i < lines.length && lines[i].trim() !== "" && !LIST_RE.test(lines[i]) && !/^(#{1,6} |> |```|\||---)/.test(lines[i].trim())) {
            buf.push(inline(lines[i].trim()));
            i++;
        }
        if (buf.length) {
            out.push("<p>" + buf.join("<br>") + "</p>");
        } else {
            out.push("<p>" + inline(line.trim()) + "</p>");
            i++;
        }
    }
    return out.join("\n");
}

const CSS = `
:root {
  --ink: #2a2530; --muted: #625a6b; --paper: #ffffff; --desk: #eef2f6; --grid: #dbe5ee; --rule: #cfdbe6;
  --kyun: #c8346e; --fuji: #6b5aa6; --fusen: #fff4b8; --fusen-edge: #e9d27a; --link: #2a5db0; --code: #f2f0f6;
  --font: "BIZ UDPGothic", "Yu Gothic UI", "Meiryo UI", "Meiryo", sans-serif;
  --mono: "BIZ UDGothic", Consolas, "MS Gothic", monospace;
}
* { box-sizing: border-box; }
[hidden] { display: none !important; }
html { -webkit-text-size-adjust: 100%; }
body { margin: 0; font-family: var(--font); font-size: 16px; line-height: 1.8; color: var(--ink); background: var(--desk); }
header { position: sticky; top: 0; z-index: 2; background: var(--paper); border-bottom: 1px solid var(--rule); padding: 0 20px; display: flex; flex-wrap: wrap; align-items: flex-end; gap: 4px 20px; }
header .title { font-weight: 700; padding: 10px 0 8px; white-space: nowrap; letter-spacing: .02em; }
header .title b { color: var(--kyun); }
header nav { display: flex; overflow-x: auto; }
header nav a { color: var(--muted); text-decoration: none; font-size: 15px; padding: 10px 12px 8px; white-space: nowrap; border-bottom: 3px solid transparent; }
header nav a:hover { color: var(--ink); border-bottom-color: var(--grid); }
header nav a.current { color: var(--ink); font-weight: 700; border-bottom-color: var(--kyun); }
main { max-width: 980px; margin: 0 auto; padding: 0 32px 56px; background: var(--paper); min-height: 100vh; border-left: 1px solid var(--rule); border-right: 1px solid var(--rule); }
h1, h2, h3 { scroll-margin-top: 72px; line-height: 1.45; }
[id] { scroll-margin-top: 72px; }
h1 { font-size: 32px; font-weight: 700; margin: 0 -32px 28px; padding: 44px 32px 20px; letter-spacing: .03em;
  background-color: #f8fafc;
  background-image: linear-gradient(var(--grid) 1px, transparent 1px), linear-gradient(90deg, var(--grid) 1px, transparent 1px);
  background-size: 16px 16px; background-position: -1px -1px; border-bottom: 4px solid var(--kyun); }
h2 { font-size: 22px; margin: 48px 0 14px; padding-bottom: 6px; border-bottom: 1px solid var(--rule); }
h2::before { content: ""; display: inline-block; width: .62em; height: .62em; margin-right: .45em; background: var(--kyun); vertical-align: .08em; }
h3 { font-size: 18px; margin: 34px 0 10px; color: var(--fuji); }
.page > p, .page > ul, .page > ol, blockquote, .finder { max-width: 46em; }
li { margin: 2px 0; }
a { color: var(--link); text-underline-offset: 3px; }
a:focus-visible, input:focus-visible, select:focus-visible { outline: 3px solid var(--kyun); outline-offset: 2px; }
strong { font-weight: 700; }
code { font-family: var(--mono); background: var(--code); padding: 1px 5px; border-radius: 3px; font-size: .9em; }
pre { background: var(--ink); color: #f1edf4; padding: 14px 16px; border-radius: 4px; overflow-x: auto; line-height: 1.55; }
pre code { background: none; color: inherit; padding: 0; }
.table-wrap { overflow-x: auto; margin: 12px 0; }
table { border-collapse: collapse; min-width: 60%; font-size: 15px; line-height: 1.6; }
th, td { border: 1px solid var(--rule); padding: 7px 11px; vertical-align: top; text-align: left; }
th { background: #f3f6f9; font-weight: 700; white-space: nowrap; }
blockquote { margin: 16px 0; padding: 10px 16px; background: var(--fusen); border-left: 5px solid var(--fusen-edge); box-shadow: 2px 3px 0 rgba(120, 100, 30, .12); }
blockquote p { margin: 4px 0; }
hr { border: 0; border-top: 1px dashed var(--rule); margin: 32px 0; }
.lv { display: inline-block; font-size: 13px; line-height: 1.5; padding: 0 8px; border-radius: 10px; white-space: nowrap; border: 1px solid; }
.lv1 { color: #2f6b3a; border-color: #9cc9a4; background: #f1f8f2; }
.lv2 { color: #7a5200; border-color: #e3c37a; background: #fdf7e8; }
.lv3 { color: #8f2350; border-color: #e3a1bc; background: #fcf0f5; }
.finder { margin: 20px 0 8px; padding: 14px 16px; border: 1px solid var(--rule); border-top: 4px solid var(--fuji); background: #fbfafd; display: flex; flex-wrap: wrap; gap: 8px 12px; align-items: center; }
.finder label { font-weight: 700; }
.finder input, .finder select { font: inherit; font-size: 15px; padding: 6px 10px; border: 1px solid #b9c6d3; border-radius: 3px; background: #fff; color: var(--ink); }
.finder input { flex: 1 1 16em; min-width: 12em; }
.finder .hits { color: var(--muted); font-size: 14px; }
.finder .none { flex-basis: 100%; margin: 0; color: var(--kyun); }
footer { color: var(--muted); font-size: 13px; margin-top: 48px; padding-top: 12px; border-top: 1px solid var(--rule); }
@media (max-width: 640px) { main { padding: 0 16px 40px; } h1 { margin: 0 -16px 24px; padding: 32px 16px 16px; font-size: 26px; } header { padding: 0 12px; } }
@media print { header, .finder { display: none; } main { max-width: none; border: 0; } h1 { background: none; } body { background: #fff; } }
`;

// Templates page: level badges and a search box over the list (each row also matches its section's text)
const FINDER_HTML = '<div class="finder" hidden><label for="tpl-q">やりたいことで探す</label>' +
    '<input id="tpl-q" type="search" placeholder="例: PDF、コピー、メール、Excel 転記" autocomplete="off">' +
    '<select id="tpl-cat" aria-label="分類"><option value="">すべての分類</option></select>' +
    '<span class="hits" id="tpl-hits" aria-live="polite"></span>' +
    '<p class="none" id="tpl-none" hidden>見つかりませんでした。ことばを短くするか、分類を「すべての分類」にしてください。</p></div>';
const FINDER_JS = `<script>
(function () {
  var box = document.querySelector(".finder"), list = document.getElementById("一覧");
  if (!box || !list) { return; }
  var table = list.nextElementSibling.querySelector("tbody"), rows = [].slice.call(table.rows);
  var q = document.getElementById("tpl-q"), cat = document.getElementById("tpl-cat");
  var hits = document.getElementById("tpl-hits"), none = document.getElementById("tpl-none");
  var norm = function (s) { return (s.normalize ? s.normalize("NFKC") : s).toLowerCase(); };
  var seen = {};
  rows.forEach(function (tr) {
    var c = tr.cells[0].textContent, text = tr.textContent, a = tr.querySelector("a");
    var el = a && document.getElementById(a.getAttribute("href").slice(1));
    for (el = el && el.nextElementSibling; el && !(el.tagName === "A" && el.id) && el.tagName !== "H2"; el = el.nextElementSibling) {
      if (el.tagName !== "DIV") { text += " " + el.textContent; }
    }
    tr.dataset.text = norm(text);
    tr.dataset.cat = c;
    if (!seen[c]) { seen[c] = 0; var o = document.createElement("option"); o.value = c; o.textContent = c; cat.appendChild(o); }
    seen[c]++;
  });
  [].forEach.call(cat.options, function (o) { if (o.value) { o.textContent = o.value + "（" + seen[o.value] + "）"; } });
  function update() {
    var words = norm(q.value).split(/\\s+/).filter(Boolean), c = cat.value, n = 0;
    rows.forEach(function (tr) {
      var ok = (!c || tr.dataset.cat === c) && words.every(function (w) { return tr.dataset.text.indexOf(w) >= 0; });
      tr.hidden = !ok;
      if (ok) { n++; }
    });
    hits.textContent = rows.length + "件中 " + n + "件";
    none.hidden = n > 0;
  }
  q.addEventListener("input", update);
  cat.addEventListener("change", update);
  box.hidden = false;
  update();
})();
</script>`;
function decorateTemplates(body) {
    body = body.replace(/<td>(初級|中級|上級)<\/td>/g, (m, lv) => '<td><span class="lv lv' + ({ 初級: 1, 中級: 2, 上級: 3 })[lv] + '">' + lv + "</span></td>");
    return body.replace('<h2 id="一覧">', FINDER_HTML + '\n<h2 id="一覧">') + "\n" + FINDER_JS;
}

// index.html holds all the pages and shows one at a time: a browser may refuse a link from one local
// file (file://) to another ("'file:' URLs are treated as unique security origins"), but a "#" inside
// the same file always works. Links between pages become "#page-manual/<heading>"; with no "#" the
// page shown is body data-page. Without scripts every page shows, one after another.
const NAV_JS = `<script>
(function () {
  var pages = [].slice.call(document.querySelectorAll("section.page"));
  if (!pages.length) { return; }
  var navs = [].slice.call(document.querySelectorAll("header nav a"));
  var home = document.getElementById("page-" + document.body.getAttribute("data-page")) || pages[0];
  var shown = null;
  function find(sec, id) { return sec.querySelector('[id="' + id.replace(/["\\\\]/g, "\\\\$&") + '"]'); }
  function show(sec) {
    pages.forEach(function (s) { s.hidden = s !== sec; });
    navs.forEach(function (a) { a.className = a.getAttribute("href") === "#" + sec.id ? "current" : ""; });
    document.title = sec.getAttribute("data-title") + " - ふじキュン♡のおしごとロボット";
    shown = sec;
  }
  function go() {
    var h = location.hash.slice(1), sec = null, target = null, m, moved;
    try { h = decodeURIComponent(h); } catch (e) { }
    m = /^page-([\\w-]+)(?:\\/(.*))?$/.exec(h);
    if (m) {
      sec = document.getElementById("page-" + m[1]);
      if (sec && m[2]) { target = find(sec, m[2]); }
    } else if (h) {
      sec = shown || home;
      target = find(sec, h);
      if (!target) { pages.some(function (s) { target = find(s, h); if (target) { sec = s; } return !!target; }); }
    }
    if (!sec) { sec = shown || home; }
    moved = sec !== shown;
    show(sec);
    if (target) { target.scrollIntoView(); } else if (moved) { window.scrollTo(0, 0); }
  }
  window.addEventListener("hashchange", go);
  go();
})();
</script>`;

const pageName = out => out.replace(/\.html$/, "");
function page(current, nav, sections) {
    return "<!DOCTYPE html>\n<html lang=\"ja\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" +
        "<title>" + esc(built[current].title) + " - ふじキュン♡のおしごとロボット</title>\n<style>" + CSS + "</style>\n</head>\n<body data-page=\"" + pageName(current) + "\">\n" +
        '<header><span class="title"><b>ふじキュン♡</b>のおしごとロボット</span><nav>' +
        nav.map(p => '<a href="#page-' + pageName(p.out) + '"' + (p.out === current ? ' class="current"' : "") + ">" + esc(p.nav) + "</a>").join("") +
        "</nav></header>\n<main>\n" + sections + "\n<footer>このページはオフラインで読めます。最新版は GitHub の uchidakoichi/RPA リポジトリにあります。</footer>\n</main>\n" + NAV_JS + "\n</body>\n</html>\n";
}

const built = {};
for (const p of PAGES) {
    const md = fs.readFileSync(path.join(srcDir, p.src), "utf8").replace(/^﻿/, "").replace(/\r\n/g, "\n");
    const ids = new Set();
    let body = convert(md.split("\n"), ids);
    if (p.out === "templates.html") { body = decorateTemplates(body); }
    const title = (md.match(/^# +(.*)$/m) || [null, p.nav])[1];
    built[p.out] = { html: body, ids, title };
}

// Every internal link must point at an existing page and heading
const problems = [];
for (const [name, b] of Object.entries(built)) {
    for (const m of b.html.matchAll(/href="([^"]+)"/g)) {
        const href = m[1];
        if (/^https?:/.test(href) || href.startsWith("../samples")) { continue; }
        const [file, hash] = href.split("#");
        const target = file === "" ? name : file;
        if (!built[target]) { problems.push(name + ": missing page " + href); continue; }
        if (hash && !built[target].ids.has(decodeURIComponent(hash))) { problems.push(name + ": missing anchor " + href); }
    }
}
if (problems.length) {
    console.error(problems.join("\n"));
    process.exit(1);
}

// "manual.html#x" -> "#page-manual/x"; "#x" stays (a heading of the same page)
function toInternal(body) {
    return body.replace(/href="([\w-]+\.html)(?:#([^"]*))?"/g, (m, file, hash) => built[file] ? 'href="#page-' + pageName(file) + (hash ? "/" + hash : "") + '"' : m);
}
const sections = PAGES.map(p => '<section class="page" id="page-' + pageName(p.out) + '" data-title="' + esc(built[p.out].title) + '">\n' + toInternal(built[p.out].html) + "\n</section>").join("\n");
// index.html holds every page; the other files only forward to their page in it, so links and
// bookmarks to manual.html#heading (and the app's help buttons) keep working
function forwarder(p) {
    const to = "index.html#page-" + pageName(p.out);
    return "<!DOCTYPE html>\n<html lang=\"ja\">\n<head>\n<meta charset=\"utf-8\">\n<title>" + esc(built[p.out].title) + " - ふじキュン♡のおしごとロボット</title>\n" +
        '<meta http-equiv="refresh" content="0;url=' + to + '">\n' +
        '<script>location.replace("' + to + '" + (location.hash ? "/" + location.hash.slice(1) : ""));</script>\n' +
        '</head>\n<body>\n<p><a href="' + to + '">' + esc(built[p.out].title) + "</a> を開きます。</p>\n</body>\n</html>\n";
}
const files = {};
for (const p of PAGES) {
    files[p.out] = p.out === "index.html" ? page(p.out, PAGES, sections) : forwarder(p);
    fs.writeFileSync(path.join(outDir, p.out), files[p.out], "utf8");
}

// ---------------------------------------------------------------- ZIP (deflate, fixed timestamps)
const CRC_TABLE = (() => {
    const t = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
        let c = n;
        for (let k = 0; k < 8; k++) { c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; }
        t[n] = c >>> 0;
    }
    return t;
})();
function crc32(buf) {
    let c = 0xFFFFFFFF;
    for (const b of buf) { c = CRC_TABLE[(c ^ b) & 0xFF] ^ (c >>> 8); }
    return (c ^ 0xFFFFFFFF) >>> 0;
}
function makeZip(entries) {
    const DOS_TIME = 0, DOS_DATE = ((2026 - 1980) << 9) | (1 << 5) | 1; // 2026-01-01 00:00, so rebuilding does not churn
    const locals = [];
    const centrals = [];
    let offset = 0;
    for (const e of entries) {
        const name = Buffer.from(e.name, "utf8");
        const data = e.data;
        const comp = zlib.deflateRawSync(data, { level: 9 });
        const crc = crc32(data);
        const local = Buffer.alloc(30);
        local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(20, 4); local.writeUInt16LE(0x0800, 6); local.writeUInt16LE(8, 8);
        local.writeUInt16LE(DOS_TIME, 10); local.writeUInt16LE(DOS_DATE, 12); local.writeUInt32LE(crc, 14);
        local.writeUInt32LE(comp.length, 18); local.writeUInt32LE(data.length, 22); local.writeUInt16LE(name.length, 26); local.writeUInt16LE(0, 28);
        locals.push(local, name, comp);
        const central = Buffer.alloc(46);
        central.writeUInt32LE(0x02014b50, 0); central.writeUInt16LE(20, 4); central.writeUInt16LE(20, 6); central.writeUInt16LE(0x0800, 8);
        central.writeUInt16LE(8, 10); central.writeUInt16LE(DOS_TIME, 12); central.writeUInt16LE(DOS_DATE, 14); central.writeUInt32LE(crc, 16);
        central.writeUInt32LE(comp.length, 20); central.writeUInt32LE(data.length, 24); central.writeUInt16LE(name.length, 28);
        central.writeUInt32LE(0, 38); central.writeUInt32LE(offset, 42);
        centrals.push(central, name);
        offset += 30 + name.length + comp.length;
    }
    const centralBuf = Buffer.concat(centrals);
    const end = Buffer.alloc(22);
    end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10);
    end.writeUInt32LE(centralBuf.length, 12); end.writeUInt32LE(offset, 16);
    return Buffer.concat(locals.concat([centralBuf, end]));
}

const TOP = "fujikyun_docs_samples/";
const readme = "﻿ふじキュン♡のおしごとロボット　ドキュメントと見本CSV\r\n\r\n" +
    "・docs\\index.html をダブルクリックすると、ブラウザでマニュアルが開きます（ネット接続は不要です）。\r\n" +
    "・samples フォルダには、テンプレートの見本CSV（すべて架空のデータ）が入っています。\r\n" +
    "・ツール本体（リポジトリ直下の5つのファイル）はこの zip に入っていません。GitHub の README の手順どおり、Raw 表示したコードをメモ帳に貼り付けて保存してください（JSON は UTF-8 で保存）。\r\n";
const entries = [{ name: TOP + "README.txt", data: Buffer.from(readme, "utf8") }];
for (const p of PAGES) {
    entries.push({ name: TOP + "docs/" + p.out, data: Buffer.from(files[p.out], "utf8") });
}
for (const f of fs.readdirSync(path.join(root, "samples")).filter(f => f.endsWith(".csv")).sort()) {
    entries.push({ name: TOP + "samples/" + f, data: fs.readFileSync(path.join(root, "samples", f)) });
}
fs.mkdirSync(path.join(root, "dist"), { recursive: true });
fs.writeFileSync(path.join(root, "dist", "fujikyun_docs_samples.zip"), makeZip(entries));
console.log("built", PAGES.length, "HTML pages and dist/fujikyun_docs_samples.zip (" + entries.length + " files)");
