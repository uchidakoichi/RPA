// Records what the HTA's own functions return for a set of inputs, so the PowerShell edition can be
// tested against the HTA (maintainers only, needs Node.js):
//   node tools/make_ps_golden.js   ->  ps/tests/golden.json
// The HTA is not the definition of "correct": every expectation here was reviewed, and where the
// HTA cannot give the right answer (JavaScript numbers are exact only to 15 digits) the correct
// value is set in PS_EXPECT below and used by the PowerShell tests instead.
"use strict";
const fs = require("fs");
const path = require("path");
const { loadHta } = require("./hta_context");

// Every "now" inside the HTA is 2026-10-09 14:05:12
const FIXED = new Date(2026, 9, 9, 14, 5, 12).getTime();
class FixedDate extends Date {
    constructor(...a) { if (a.length === 0) { super(FIXED); } else { super(...a); } }
    static now() { return FIXED; }
}
const R = loadHta(undefined, { Date: FixedDate });
const J = v => JSON.stringify(v);
const call = code => { try { return { value: R(code) }; } catch (e) { return { error: true }; } };

const csv = [
    "", "\n", "a,b,c", "a,b\r\nc,d\r\n", "a,b\nc,d\n\n\n", "a\n\nb", "a,", ",", "\"x,y\",z", "\"he said \"\"hi\"\"\",2",
    "12\"モニタ,3", "\"ab\"cd,e", "\"a\"b\"c\",d", "\"multi\nline\",2\r\n3,4", "\"unclosed,a\nb", "a,\"b\r\nc", "\r\r\n", "氏名,番号\r\n見本 太郎,001\r\n",
    "a\rb", "\"\"", "\"\"\"\"", "x,\"\",y"
].map(t => ({ text: t, records: JSON.parse(R(`JSON.stringify(parseCsv(${J(t)}))`)), warnings: R("csvParseWarnings.length") }));

const calc = ["1+2", "2*3+4", "2*(3+4)", "10/4", "10%3", "-10%3", "1.5*2", "１２＋３", "1,200*2", "（1+2）×3", "0.1+0.2", "1/3", "", "1/0", "2*(3", "abc", "1+",
    "100-200", "+5", "--5", "7 / 2", "12÷4", "3％2", "1e3", "99999999*99999999",
    "12345678901234*10", "0.1*3", "1/3*3", "1234567890123456789"].map(e => Object.assign({ expr: e }, call(`calcExpression(${J(e)})`)));

const S = (op, s, a, b) => Object.assign({ op, s, a, b }, call(`strOp(${J(op)}, ${J(s)}, ${J(a)}, ${J(b)})`));
const strop = [
    S("REPLACE", "a-b-c", "-", "/"), S("REPLACE", "abc", "", "x"), S("REGEX_REPLACE", "a  b　 c", "[ 　]+", "_"), S("REGEX_REPLACE", "2026/10/09", "(\\d+)/(\\d+)/(\\d+)", "$3.$2.$1"),
    S("REGEX_EXTRACT", "TEL 03-1234-5678", "0\\d{1,4}-\\d{1,4}-\\d{4}", ""), S("REGEX_EXTRACT", "金額 12,000円", "([0-9,]+)円", "1"), S("REGEX_EXTRACT", "abc", "x", ""),
    S("REGEX_EXTRACT", "abc", "(a)(x)?", "2"), S("REGEX_EXTRACT", "abc", "(a)", "5"),
    S("SUBSTR", "ABCDEFG", "3", "2"), S("SUBSTR", "ABCDEFG", "3", ""), S("SUBSTR", "ABC", "9", "2"), S("SUBSTR", "ABC", "0", "2"), S("SUBSTR", "ABCDEF", "２", "３"),
    S("SPLIT", "山田,太郎", ",", "2"), S("SPLIT", "a/b/c", "/", "3"), S("SPLIT", "a,b", "", "1"), S("SPLIT", "a,b", ",", "5"), S("SPLIT", "a,b", ",", ""),
    S("TRIM", "  　abc　 ", "", ""), S("ZEN2HAN", "１２３ＡＢＣ　！", "", ""), S("HAN2ZEN", "123ABC !", "", ""),
    S("PAD", "123", "7", ""), S("PAD", "123", "5", "x"), S("PAD", "12345", "3", ""),
    S("WAREKI", "2026/10/01", "", ""), S("WAREKI", "20190501", "", ""), S("WAREKI", "2019/04/30", "", ""), S("WAREKI", "1989/01/08", "", ""), S("WAREKI", "1989-1-7", "", ""),
    S("WAREKI", "令和8年10月1日", "", ""), S("WAREKI", "平成元年5月1日", "", ""), S("WAREKI", "２０２６年１０月１日", "", ""), S("WAREKI", "hello", "", ""), S("WAREKI", "2026/02/30", "", ""),
    S("DATE_ADD", "2026/10/01", "14", ""), S("DATE_ADD", "2026/03/01", "-1", ""), S("DATE_ADD", "2024/02/28", "1", ""), S("DATE_ADD", "令和元年5月1日", "0", ""),
    S("COMMA", "1234567", "", ""), S("COMMA", "1234567.891", "", ""), S("COMMA", "１２３４", "", ""), S("COMMA", "999", "", ""),
    S("UNCOMMA", "1,234，567", "", ""), S("LENGTH", "あいう", "", ""), S("LENGTH", "", "", ""), S("UNKNOWN_OP", "keep", "", ""),
    S("WAREKI", "大正15年1月1日", "", ""), S("WAREKI", "1926/12/24", "", ""), S("WAREKI", "1926/12/25", "", ""), S("WAREKI", "1912/07/30", "", ""),
    S("WAREKI", "明治45年7月29日", "", ""), S("WAREKI", "令和8年2月30日", "", ""), S("DATE_ADD", "明治45年7月29日", "1", "")
];

// Numbers are recorded as text (String(n)) so long values survive JSON
const numbers = ["1", " 12 ", "１２", "1,200", "-3.5", "+7", "1.", ".5", "abc", "", "1e3", "１，０００", "007", "123456789012345", "12345678901234567"]
    .map(t => ({ text: t, value: R(`(function (n) { return n === null ? null : String(n); })(toNumberOrNull(${J(t)}))`) }));

const C = (op, left, right) => ({ op, left, right, value: R(`evalCondition({ op: ${J(op)}, left: ${J(left)}, right: ${J(right)} }, null)`) });
const conditions = [
    C("EQ", "10", "10.0"), C("EQ", "abc", "abc"), C("EQ", "abc", "ABC"), C("EQ", "1,000", "１０００"), C("NE", "a", "b"), C("CONTAINS", "hello", "ell"), C("NOT_CONTAINS", "hello", "z"),
    C("EMPTY", "  ", ""), C("EMPTY", "　", ""), C("NOT_EMPTY", "x", ""), C("GT", "100000", "99999"), C("GT", "b", "a"), C("GE", "5", "5"), C("LT", "abc", "abd"),
    C("LE", "2", "10"), C("LE", "2", "1x"), C("REGEX", "R08-0001", "^R\\d{2}-"), C("REGEX", "abc", "^b"), C("EQ", "", ""),
    C("EQ", "12345678901234567", "12345678901234568"), C("EQ", "0012", "12"), C("GT", "12345678901234568", "9"), C("EQ", "１，０００", "1000")
];

const wareki = [[2026, 9, 9], [2019, 4, 1], [2019, 3, 30], [1989, 0, 8], [1989, 0, 7], [1926, 11, 25], [2020, 0, 1],
    [1926, 11, 24], [1926, 0, 1], [1912, 6, 30], [1912, 6, 29], [1868, 0, 1], [1867, 11, 31]]
    .map(([y, m, d]) => ({ y, m: m + 1, d, year: R(`warekiOf(new Date(${y}, ${m}, ${d}))`) }));

// Placeholders with a fixed row, header and variables
const fixture = { header: ["氏名", "金額", "ROW", "DAY "], row: { no: 7, data: ["見本 太郎", "12000", "hdr", "d"] }, vars: { "合計": "1500", "空": "" }, unsafeRow: ["a&b", "plain", "x|y"] };
R(`csvState.header = ${J(fixture.header)}; var __rs = { rows: [${J(fixture.row)}], rowPos: 0, vars: ${J(fixture.vars)} };`);
const placeholders = ["{{1}}", "{{2}}", "{{9}}", "{{氏名}}様", "{{ 氏名 }}", "{{ROW}}", "{{DAY}}", "{{ROW+1}}", "{{row - 2}}", "{{$合計}}", "{{$ 合計 }}", "{{$無い}}", "{{$空}}",
    "{{TODAY}}", "{{TODAY_JP}}", "{{WAREKI}}", "{{WAREKI_YEAR}}", "{{YYYYMMDD}}", "{{NOW}}", "{{TIMESTAMP}}", "{{YEAR}}/{{MONTH}}/{{Day}}", "{{謎}}", "a{{1}}b{{2}}c", "{{}}", "{{{1}}}", "no placeholders"]
    .map(t => ({ text: t, value: R(`expandPlaceholders(${J(t)}, __rs)`) }));
R(`__rs.rows[0].data = ${J(fixture.unsafeRow)}; var __u = [];`);
const unsafe = { text: "cmd /c echo {{1}} {{2}} {{3}}", value: R(`expandPlaceholders("cmd /c echo {{1}} {{2}} {{3}}", __rs, __u)`), count: R("__u.length") };

// Correct values where the HTA (JavaScript doubles) cannot give them; the HTA refuses or compares as text
const PS_EXPECT = [
    [calc, c => c.expr === "99999999*99999999", { value: "9999999800000001" }, "exact product; the HTA refuses numbers beyond 2^53"],
    [calc, c => c.expr === "1234567890123456789", { value: "1234567890123456789" }, "19 digits are exact in decimal"],
    [numbers, c => c.text === "12345678901234567", { value: "12345678901234567" }, "17 digits are exact in decimal; the HTA treats them as text"],
    [conditions, c => c.op === "GT" && c.left === "12345678901234568", { value: true }, "numeric comparison; the HTA compares 17-digit values as text"]
];
for (const [list, match, expect, reason] of PS_EXPECT) {
    const hits = list.filter(match);
    if (hits.length !== 1) { throw new Error("PS_EXPECT matched " + hits.length + " cases: " + reason); }
    hits[0].ps = Object.assign({ reason }, expect);
}

// Labels the HTA gives every template step (the PowerShell edition computes its own and compares)
const templateLabels = JSON.parse(R(`JSON.stringify(TEMPLATES.map(function (t) { return { id: t.id, labels: templateSteps(t).map(function (s) { return s.label; }) }; }))`));
// The PowerShell edition's label icons follow the palette (the HTA's labels kept older icons)
for (const t of templateLabels) {
    const ps = t.labels.map(l => l.replace(/^📝 結果の/, "🧾 結果の").replace(/^📗 (.*) を書く$/, "🖊 $1 を書く"));
    if (ps.some((l, i) => l !== t.labels[i])) { t.ps = ps; }
}

// A macros file through the HTA's normalizeData + serializeData, to compare the PowerShell writer
const macroInput = { version: 27, macros: [
    { id: "a1b2c3d4", name: "見本", targetWindow: "メモ帳", steps: [
        { cmd: "csv", val: "1" }, { cmd: "KEY", val: "{TAB}", label: "自分のラベル" }, { cmd: "OLD_CMD", val: "x,y" },
        { cmd: "GROUP_START", val: "保存", when: "last" }, { cmd: "WINDOW_CHECK", val: "{\"title\":\"エラー\",\"key\":\"{ENTER}\",\"mode\":\"skip\"}", disabled: true },
        { cmd: "GROUP_END", val: "" }, { cmd: "TEXT", val: "改行\r\nと\"引用\"と\\" }, { val: "no cmd" }, { cmd: "GROUP_START", val: "g", when: "sometimes" }, { cmd: "GROUP_END" }] },
    { id: "e5f6a7b8", targetWindow: null, steps: [] }
] };


const out = { generated: "from fujikyun_rpa_builder.hta by tools/make_ps_golden.js", now: "2026-10-09T14:05:12", csv, calc, strop, numbers, conditions, wareki, fixture, placeholders, unsafe, templateLabels, macroInput, macroOutput: R(`appData = normalizeData(${J(macroInput)}); serializeData()`) };
const file = path.join(__dirname, "..", "ps", "tests", "golden.json");
fs.mkdirSync(path.dirname(file), { recursive: true });
fs.writeFileSync(file, JSON.stringify(out, null, 1) + "\n", "utf8");
console.log("wrote", path.relative(process.cwd(), file), "-", csv.length, "csv,", calc.length, "calc,", strop.length, "strop,", conditions.length, "conditions,", placeholders.length, "placeholders");
