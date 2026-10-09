// Builds the browser-readable manuals and the download package (maintainers only, needs Node.js):
//   node tools/build_templates.js   (regenerates samples/ and docs/src/templates.md)
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
    { src: "tutorial.md", out: "tutorial.html", nav: "チュートリアル" },
    { src: "manual.md", out: "manual.html", nav: "操作マニュアル" },
    { src: "templates.md", out: "templates.html", nav: "テンプレート解説" },
    { src: "faq.md", out: "faq.html", nav: "Q&A" },
    { src: "powershell.md", out: "powershell.html", nav: "PowerShell版" }
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
:root { --fg: #2f2a33; --muted: #6d6470; --accent: #c2185b; --line: #ead7e2; --bg: #ffffff; --soft: #fdf5f9; --code: #f4eef2; }
* { box-sizing: border-box; }
body { margin: 0; font-family: "Meiryo UI", "Yu Gothic UI", "Segoe UI", sans-serif; font-size: 16px; line-height: 1.75; color: var(--fg); background: var(--soft); }
header { position: sticky; top: 0; z-index: 2; background: linear-gradient(90deg, #f48fb1, #f7b6d2 55%, #b3d9ff); color: #fff; padding: 8px 16px; }
header .title { font-weight: bold; margin-right: 16px; text-shadow: 0 1px 2px rgba(120, 30, 80, .35); }
header nav a { color: #fff; margin-right: 12px; text-decoration: none; font-size: 15px; white-space: nowrap; }
header nav a.current { text-decoration: underline; font-weight: bold; }
main { max-width: 1000px; margin: 0 auto; padding: 16px 24px 48px; background: var(--bg); min-height: 100vh; }
h1, h2, h3 { scroll-margin-top: 64px; }
h1 { font-size: 26px; color: var(--accent); border-bottom: 3px solid var(--line); padding-bottom: 6px; }
h2 { font-size: 22px; margin-top: 36px; border-left: 6px solid #f48fb1; padding-left: 10px; }
h3 { font-size: 18px; margin-top: 26px; color: #8e3b66; }
a { color: #1565c0; }
code { font-family: Consolas, "MS Gothic", monospace; background: var(--code); padding: 1px 5px; border-radius: 4px; font-size: .92em; }
pre { background: #2d2733; color: #ece6f0; padding: 12px 14px; border-radius: 6px; overflow-x: auto; line-height: 1.5; }
pre code { background: none; color: inherit; padding: 0; }
.table-wrap { overflow-x: auto; }
table { border-collapse: collapse; margin: 10px 0; min-width: 60%; }
th, td { border: 1px solid var(--line); padding: 6px 10px; vertical-align: top; text-align: left; }
th { background: #fce4ef; }
tr:nth-child(even) td { background: #fffafd; }
blockquote { margin: 12px 0; padding: 8px 14px; background: #fff8e1; border-left: 4px solid #ffb300; }
hr { border: 0; border-top: 1px dashed var(--line); margin: 28px 0; }
footer { color: var(--muted); font-size: 13px; margin-top: 40px; }
@media print { header { position: static; } main { max-width: none; } }
`;

function page(title, nav, current, body) {
    return "<!DOCTYPE html>\n<html lang=\"ja\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" +
        "<title>" + esc(title) + " - ふじキュン♡のRPAマクロビルダー</title>\n<style>" + CSS + "</style>\n</head>\n<body>\n" +
        '<header><span class="title">ふじキュン♡のRPAマクロビルダー</span><nav>' +
        nav.map(p => '<a href="' + p.out + '"' + (p.out === current ? ' class="current"' : "") + ">" + esc(p.nav) + "</a>").join("") +
        "</nav></header>\n<main>\n" + body + "\n<footer>このページはオフラインで読めます。最新版は GitHub の uchidakoichi/RPA リポジトリにあります。</footer>\n</main>\n</body>\n</html>\n";
}

const built = {};
for (const p of PAGES) {
    const md = fs.readFileSync(path.join(srcDir, p.src), "utf8").replace(/^﻿/, "").replace(/\r\n/g, "\n");
    const ids = new Set();
    const body = convert(md.split("\n"), ids);
    const title = (md.match(/^# +(.*)$/m) || [null, p.nav])[1];
    const html = page(title, PAGES, p.out, body);
    fs.writeFileSync(path.join(outDir, p.out), html, "utf8");
    built[p.out] = { html, ids };
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
const readme = "﻿ふじキュン♡のRPAマクロビルダー　ドキュメントと見本CSV\r\n\r\n" +
    "・docs\\index.html をダブルクリックすると、ブラウザでマニュアルが開きます（ネット接続は不要です）。\r\n" +
    "・samples フォルダには、テンプレートの見本CSV（すべて架空のデータ）が入っています。\r\n" +
    "・ツール本体 fujikyun_rpa_builder.hta はこの zip に入っていません。GitHub の README の手順どおり、Raw 表示したコードをメモ帳に貼り付けて保存してください。\r\n";
const entries = [{ name: TOP + "README.txt", data: Buffer.from(readme, "utf8") }];
for (const p of PAGES) {
    entries.push({ name: TOP + "docs/" + p.out, data: Buffer.from(built[p.out].html, "utf8") });
}
for (const f of fs.readdirSync(path.join(root, "samples")).filter(f => f.endsWith(".csv")).sort()) {
    entries.push({ name: TOP + "samples/" + f, data: fs.readFileSync(path.join(root, "samples", f)) });
}
fs.mkdirSync(path.join(root, "dist"), { recursive: true });
fs.writeFileSync(path.join(root, "dist", "fujikyun_docs_samples.zip"), makeZip(entries));
console.log("built", PAGES.length, "HTML pages and dist/fujikyun_docs_samples.zip (" + entries.length + " files)");
