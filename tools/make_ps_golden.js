// Records what the HTA's own functions return for a set of inputs, so the PowerShell edition can be
// tested against the HTA's exact behaviour (maintainers only, needs Node.js):
//   node tools/make_ps_golden.js   ->  ps/tests/golden.json
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
    "100-200", "+5", "--5", "7 / 2", "12÷4", "3％2", "1e3", "99999999*99999999"].map(e => Object.assign({ expr: e }, call(`calcExpression(${J(e)})`)));

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
    S("UNCOMMA", "1,234，567", "", ""), S("LENGTH", "あいう", "", ""), S("LENGTH", "", "", ""), S("UNKNOWN_OP", "keep", "", "")
];

const numbers = ["1", " 12 ", "１２", "1,200", "-3.5", "+7", "1.", ".5", "abc", "", "1e3", "１，０００"].map(t => ({ text: t, value: R(`toNumberOrNull(${J(t)})`) }));

const C = (op, left, right) => ({ op, left, right, value: R(`evalCondition({ op: ${J(op)}, left: ${J(left)}, right: ${J(right)} }, null)`) });
const conditions = [
    C("EQ", "10", "10.0"), C("EQ", "abc", "abc"), C("EQ", "abc", "ABC"), C("EQ", "1,000", "１０００"), C("NE", "a", "b"), C("CONTAINS", "hello", "ell"), C("NOT_CONTAINS", "hello", "z"),
    C("EMPTY", "  ", ""), C("EMPTY", "　", ""), C("NOT_EMPTY", "x", ""), C("GT", "100000", "99999"), C("GT", "b", "a"), C("GE", "5", "5"), C("LT", "abc", "abd"),
    C("LE", "2", "10"), C("LE", "2", "1x"), C("REGEX", "R08-0001", "^R\\d{2}-"), C("REGEX", "abc", "^b"), C("EQ", "", "")
];

const wareki = [[2026, 9, 9], [2019, 4, 1], [2019, 3, 30], [1989, 0, 8], [1989, 0, 7], [1926, 11, 25], [2020, 0, 1]]
    .map(([y, m, d]) => ({ y, m: m + 1, d, year: R(`warekiOf(new Date(${y}, ${m}, ${d}))`) }));

// Placeholders with a fixed row, header and variables
const fixture = { header: ["氏名", "金額", "ROW", "DAY "], row: { no: 7, data: ["見本 太郎", "12000", "hdr", "d"] }, vars: { "合計": "1500", "空": "" }, unsafeRow: ["a&b", "plain", "x|y"] };
R(`csvState.header = ${J(fixture.header)}; var __rs = { rows: [${J(fixture.row)}], rowPos: 0, vars: ${J(fixture.vars)} };`);
const placeholders = ["{{1}}", "{{2}}", "{{9}}", "{{氏名}}様", "{{ 氏名 }}", "{{ROW}}", "{{DAY}}", "{{ROW+1}}", "{{row - 2}}", "{{$合計}}", "{{$ 合計 }}", "{{$無い}}", "{{$空}}",
    "{{TODAY}}", "{{TODAY_JP}}", "{{WAREKI}}", "{{WAREKI_YEAR}}", "{{YYYYMMDD}}", "{{NOW}}", "{{TIMESTAMP}}", "{{YEAR}}/{{MONTH}}/{{Day}}", "{{謎}}", "a{{1}}b{{2}}c", "{{}}", "{{{1}}}", "no placeholders"]
    .map(t => ({ text: t, value: R(`expandPlaceholders(${J(t)}, __rs)`) }));
R(`__rs.rows[0].data = ${J(fixture.unsafeRow)}; var __u = [];`);
const unsafe = { text: "cmd /c echo {{1}} {{2}} {{3}}", value: R(`expandPlaceholders("cmd /c echo {{1}} {{2}} {{3}}", __rs, __u)`), count: R("__u.length") };

const out = { generated: "from fujikyun_rpa_builder.hta by tools/make_ps_golden.js", now: "2026-10-09T14:05:12", csv, calc, strop, numbers, conditions, wareki, fixture, placeholders, unsafe };
const file = path.join(__dirname, "..", "ps", "tests", "golden.json");
fs.mkdirSync(path.dirname(file), { recursive: true });
fs.writeFileSync(file, JSON.stringify(out, null, 1) + "\n", "utf8");
console.log("wrote", path.relative(process.cwd(), file), "-", csv.length, "csv,", calc.length, "calc,", strop.length, "strop,", conditions.length, "conditions,", placeholders.length, "placeholders");
