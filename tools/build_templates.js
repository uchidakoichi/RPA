// Generates samples/*.csv and docs/src/templates.md from the templates and command definitions in
// fujikyun_rpa_builder.hta, so the HTA, the sample CSVs and the docs never drift apart.
// Usage (maintainers only, needs Node.js):  node tools/build_templates.js
"use strict";
const fs = require("fs");
const path = require("path");
const { loadHta } = require("./hta_context");

const root = path.join(__dirname, "..");
const R = loadHta();
const TEMPLATES = JSON.parse(R("JSON.stringify(TEMPLATES)"));
const CATEGORIES = JSON.parse(R("JSON.stringify(TEMPLATE_CATEGORIES)"));
const LEVELS = { 1: "初級", 2: "中級", 3: "上級" };

// Same rules as toCsvField() in the HTA; UTF-8 with BOM + CRLF so Excel opens it cleanly
const csvField = v => (/[",\r\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v);
const samplesDir = path.join(root, "samples");
fs.mkdirSync(samplesDir, { recursive: true });
for (const t of TEMPLATES) {
    const text = t.csv.map(r => r.map(csvField).join(",")).join("\r\n") + "\r\n";
    fs.writeFileSync(path.join(samplesDir, t.csvFile), "﻿" + text, "utf8");
}

const md = s => String(s).replace(/\|/g, "\\|").replace(/\r?\n/g, "⏎");
const PROP_NOTE = s => [s.when === "first" ? "最初の1行だけ" : s.when === "last" ? "最後の1行だけ" : "", s.disabled ? "無効（調整してから有効化）" : ""].filter(Boolean).join("・");
// Command names and the readable form of each setting come from the HTA's COMMAND_DEFS
const cmdTitle = cmd => R(`COMMAND_DEFS[${JSON.stringify(cmd)}].title`);
const stepSetting = s => R(`(function () { var d = COMMAND_DEFS[${JSON.stringify(s[0])}], v = ${JSON.stringify(s[1] == null ? "" : String(s[1]))};
    return d.marker ? "" : d.hideVal ? d.autoLabel(v) : v; })()`);

const out = [];
out.push("# テンプレート解説");
out.push("");
out.push("> このファイルは `node tools/build_templates.js` で HTA 内のテンプレートデータから自動生成しています。直接編集せず、HTA の `TEMPLATES` を直してから再生成してください。");
out.push("");
out.push("ふじキュン♡のRPAマクロビルダーには **" + TEMPLATES.length + " 種類** のテンプレート（お手本マクロ）が入っています。画面上部の **［📚 テンプレート］** から選んで **［✨ 作る］** を押すと、マクロが追加され、見本CSVが `samples` フォルダに用意されて自動で読み込まれます。");
out.push("");
out.push("- 見本CSVの人名・番号・URL・メールアドレスはすべて **架空** です。");
out.push("- 画面のボタン名・ウィンドウ名・TAB の回数は職場のシステムごとに違います。各テンプレートの「準備」「カスタマイズのポイント」を読んで合わせてください。");
out.push("- 基幹系システムや庶務事務システムのテンプレートは、メニュー名・ボタン名・欄の並びを **架空の例** で書いています（自治体ごとに画面が違うため）。最初は確認ポイント（✋）で入力欄を手でクリックする半自動で動き、慣れたら無効化されている座標クリック（CLICK_POS）や読み取りグループを有効化して完全自動にできます。");
out.push("- はじめて動かすときは、実行欄の **開始行・終了行を両方 1** にして 1 件だけ試しましょう。");
out.push("");
out.push("## 一覧");
out.push("");
out.push("| 分類 | テンプレート | レベル | 見本CSV |");
out.push("| --- | --- | --- | --- |");
for (const c of CATEGORIES) {
    for (const t of TEMPLATES.filter(x => x.category === c)) {
        out.push("| " + c + " | [" + t.name + "](#" + t.id + ") | " + LEVELS[t.level] + " | `samples/" + t.csvFile + "` |");
    }
}
out.push("");
for (const c of CATEGORIES) {
    out.push("## " + c);
    out.push("");
    for (const t of TEMPLATES.filter(x => x.category === c)) {
        out.push('<a id="' + t.id + '"></a>');
        out.push("");
        out.push("### " + t.name + "（" + LEVELS[t.level] + "）");
        out.push("");
        out.push(t.summary);
        out.push("");
        out.push("- **こんな時に:** " + t.useCase);
        out.push("- **対象ウィンドウ:** " + (t.targetWindow ? "`" + t.targetWindow + "`" : "なし（マクロの中で RUN・SWITCH して切り替えます）"));
        out.push("- **見本CSV:** `samples/" + t.csvFile + "`（列: " + t.csv[0].map(h => "`" + h + "`").join("・") + "）");
        out.push("");
        out.push("**準備**");
        out.push("");
        t.prepare.forEach(p => out.push("- " + p));
        out.push("");
        out.push("**ステップ**");
        out.push("");
        out.push("| # | コマンド | 設定 | 補足 |");
        out.push("| --- | --- | --- | --- |");
        t.steps.forEach((s, i) => {
            const props = s[2] || {};
            const setting = stepSetting(s);
            out.push("| " + (i + 1) + " | `" + s[0] + "` " + cmdTitle(s[0]) + " | " + (setting === "" ? "" : "`" + md(setting) + "`") + " | " + PROP_NOTE(props) + " |");
        });
        out.push("");
        out.push("**カスタマイズのポイント**");
        out.push("");
        t.customize.forEach(p => out.push("- " + p));
        out.push("");
        out.push("**応用・発見のヒント**");
        out.push("");
        t.ideas.forEach(p => out.push("- " + p));
        out.push("");
        out.push("**見本CSV（先頭3行）**");
        out.push("");
        out.push("| " + t.csv[0].map(md).join(" | ") + " |");
        out.push("| " + t.csv[0].map(() => "---").join(" | ") + " |");
        t.csv.slice(1, 4).forEach(r => out.push("| " + r.map(md).join(" | ") + " |"));
        out.push("");
    }
}
fs.mkdirSync(path.join(root, "docs", "src"), { recursive: true });
fs.writeFileSync(path.join(root, "docs", "src", "templates.md"), out.join("\n"), "utf8");
console.log("generated", TEMPLATES.length, "sample CSVs and docs/src/templates.md");
