// Validates the HTA script and every built-in template (maintainers only, needs Node.js):
//   node tools/check_templates.js
// - the <script> block parses as strict ES5 when acorn is installed (npm i acorn), otherwise as plain JS
// - every template step uses a known command with a value its editor accepts
// - groups are balanced, CSV columns exist, and every {{placeholder}} resolves against the sample CSV
// - every sample CSV survives the HTA's own CSV writer/parser round trip
"use strict";
const assert = require("assert");
const vm = require("vm");
const { htaScript, loadHta } = require("./hta_context");

const script = htaScript();

let es5 = "skipped (npm i acorn to enable)";
try {
    require("acorn").parse(script, { ecmaVersion: 5 });
    es5 = "ok";
} catch (e) {
    if (e.code !== "MODULE_NOT_FOUND") {
        throw new Error("not ES5: " + e.message);
    }
    new vm.Script(script); // at least a syntax check
}

const R = loadHta(script);

const BUILTIN = ["ROW", "TODAY", "TODAY_JP", "WAREKI", "WAREKI_YEAR", "YYYYMMDD", "NOW", "TIMESTAMP", "YEAR", "MONTH", "DAY"];
const count = R("TEMPLATES.length");
const ids = {};
const files = {};
const categories = JSON.parse(R("JSON.stringify(TEMPLATE_CATEGORIES)"));
for (let i = 0; i < count; i++) {
    const t = JSON.parse(R(`JSON.stringify(TEMPLATES[${i}])`));
    const where = t.id || "#" + i;
    for (const k of ["id", "category", "level", "name", "summary", "useCase", "prepare", "customize", "ideas", "csvFile", "csv", "steps"]) {
        assert.ok(t[k] !== undefined && t[k] !== "", where + " missing " + k);
    }
    assert.ok(!ids[t.id], "duplicate id " + t.id);
    ids[t.id] = true;
    assert.ok(!files[t.csvFile], "duplicate csvFile " + t.csvFile);
    files[t.csvFile] = true;
    assert.ok(categories.includes(t.category), where + " unknown category " + t.category);
    const steps = JSON.parse(R(`JSON.stringify(templateSteps(TEMPLATES[${i}]))`));
    const header = t.csv[0];
    const vars = JSON.parse(R(`JSON.stringify(definedVarNames(templateSteps(TEMPLATES[${i}])))`));
    let depth = 0;
    for (const s of steps) {
        assert.ok(R(`!!COMMAND_DEFS[${JSON.stringify(s.cmd)}]`), where + " unknown command " + s.cmd);
        const err = R(`(function(){var d=COMMAND_DEFS[${JSON.stringify(s.cmd)}];return d.validate(d.parse(${JSON.stringify(s.val)}));})()`);
        assert.strictEqual(err, "", `${where} ${s.cmd} "${s.val}": ${err}`);
        assert.ok(s.label, where + " label");
        if (R(`isBlockStart(${JSON.stringify(s.cmd)})`)) { depth++; }
        if (R(`isBlockEnd(${JSON.stringify(s.cmd)})`)) { depth--; }
        assert.ok(depth >= 0, where + " block end without its start");
        if (s.cmd === "CSV") {
            assert.ok(+s.val >= 1 && +s.val <= header.length, `${where} CSV column ${s.val} out of range`);
        }
        for (const m of s.val.match(/\{\{([^{}]+)\}\}/g) || []) {
            const k = m.slice(2, -2).trim();
            const ok = /^\d+$/.test(k) || /^ROW\s*[+-]\s*\d+$/i.test(k) || BUILTIN.includes(k.toUpperCase()) ||
                header.includes(k) || (k.startsWith("$") && vars.includes(k.slice(1).trim()));
            assert.ok(ok, `${where} unresolved placeholder ${m}`);
        }
    }
    assert.strictEqual(depth, 0, where + " unbalanced groups");
    assert.ok(R(`groupsBalanced(templateSteps(TEMPLATES[${i}]))`), where + " block structure (ELSE/CATCH placement, matching ends)");
    const text = R(`templateCsvText(TEMPLATES[${i}])`);
    assert.deepStrictEqual(JSON.parse(R(`JSON.stringify(parseCsv(${JSON.stringify(text)}))`)), t.csv, where + " CSV round trip");
}
console.log(`ES5: ${es5}; ${count} templates in ${categories.length} categories: OK`);
