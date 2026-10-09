// Copies the built-in templates from the HTA into ps/fujikyun_templates.json for the PowerShell
// edition (maintainers only, needs Node.js; the HTA stays the templates' source while both editions
// are kept):  node tools/export_ps_templates.js
"use strict";
const fs = require("fs");
const path = require("path");
const { loadHta } = require("./hta_context");

const R = loadHta();
const templates = JSON.parse(R("JSON.stringify(TEMPLATES)"));
const categories = JSON.parse(R("JSON.stringify(TEMPLATE_CATEGORIES)"));
// The PowerShell edition has no SMTP: drop the server settings from MAIL steps
const SMTP_KEYS = ["server", "port", "from", "ssl"];
for (const t of templates) {
    for (const s of t.steps) {
        if (s[0] === "MAIL") {
            const v = JSON.parse(s[1]);
            SMTP_KEYS.forEach(k => delete v[k]);
            s[1] = JSON.stringify(v);
        }
    }
}
// Texts that mention SMTP: the PowerShell edition sends with Outlook or the mail app only
const TEXT_FIXES = [["（または送り方を SMTP に変える）", "（または送り方をメールアプリ（mailto）に変える）"]];
for (const t of templates) {
    for (const key of ["summary", "useCase", "prepare", "customize", "ideas"]) {
        const fix = s => TEXT_FIXES.reduce((acc, f) => acc.split(f[0]).join(f[1]), s);
        if (Array.isArray(t[key])) { t[key] = t[key].map(fix); } else if (typeof t[key] === "string") { t[key] = fix(t[key]); }
    }
}
const left = JSON.stringify(templates).match(/SMTP/g);
if (left) { throw new Error("templates still mention SMTP: add a fix to TEXT_FIXES"); }
const out = { _about: "PowerShell 版の内蔵テンプレート。HTA 版から tools/export_ps_templates.js で書き出したもの（直接編集しない）", categories, templates };
const file = path.join(__dirname, "..", "ps", "fujikyun_templates.json");
fs.writeFileSync(file, JSON.stringify(out, null, 1) + "\n", "utf8");
console.log("wrote", path.relative(process.cwd(), file), "-", templates.length, "templates");
