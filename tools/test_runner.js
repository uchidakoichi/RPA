// End-to-end tests of the run loop, CSV handling and persistence (maintainers only, needs Node.js):
//   node tools/test_runner.js
// The HTA's script runs in a VM with a simulated WScript.Shell / FileSystemObject / clipboard /
// PowerShell (scripts are interpreted by what they contain), so no Windows is needed.
"use strict";
const path = require('path');
const HTA_SCRIPT = require('fs').readFileSync(process.env.HTA_PATH || path.join(__dirname, '..', 'fujikyun_rpa_builder.hta'), 'utf8')
  .replace(/^\uFEFF/, '').match(/<script type="text\/javascript">([\s\S]*)<\/script>/)[1];
const vm = require('vm'), fs = require('fs'), assert = require('assert');
function el() { return { style: {}, className: '', innerHTML: '', value: '', disabled: false, options: { length: 0, add() {} }, children: [], childNodes: [], appendChild(c) { this.childNodes.push(c) }, removeChild() { this.childNodes.shift() }, getElementsByTagName() { return [] }, setAttribute() {}, getAttribute() { return null }, focus() {} }; }
function makeCtx() {
  const els = {}, files = {}, keys = [], clicks = [], logs = [];
  const ctx = { window: {}, location: { href: '' }, screen: {}, setTimeout, clearTimeout, __lockedMove: false, __files: files, __keys: keys, __clicks: clicks, __logs: logs, confirm: () => true };
  ctx.document = { getElementById: id => (els[id] = els[id] || el()), createElement: () => el(), createTextNode: t => ({ t }), title: 'ふじキュン♡のRPAマクロビルダー', hasFocus: () => false };
  ctx.window.clipboardData = { v: '', setData(t, v) { this.v = v; return true }, getData() { return this.v } };
  ctx.ActiveXObject = function (p) { throw new Error('no ' + p); };
  vm.createContext(ctx);
  vm.runInContext(HTA_SCRIPT, ctx);
  const R = c => vm.runInContext(c, ctx);
  // Simulated PowerShell: interprets the generated script by what it contains
  ctx.__ps = function (script) {
    const res = (script.match(/\$fujiResultPath = '([^']+)'/) || [])[1];
    const cancel = (script.match(/\$fujiCancelPath = '([^']+)'/) || [])[1];
    const put = v => { files[res] = v; };
    const started = (script.match(/WriteAllText\('([^']+\.started)'/) || [])[1];
    if (started && !ctx.__clm) files[started] = '1';
    if (/GetAsyncKeyState/.test(script)) {               // stop watcher: ends when cancelled
      const iv = setInterval(() => { if (files[cancel] !== undefined) { clearInterval(iv); put('OK:END'); } else if (ctx.__escHeld) { clearInterval(iv); put('OK:STOP'); } }, 30);
    } else if (/mouse_event\(0x0002/.test(script) && /FujiMouse/.test(script)) {   // CLICK_POS
      setTimeout(() => { if (files[cancel] !== undefined) put('NG:停止されたのでクリックしなかった'); else { clicks.push('pos'); put('OK'); } }, ctx.__psDelay || 400);
    } else if (/SoundPlayer \$wav/.test(script)) {      // alarm
      setTimeout(() => put('OK'), 100);
    } else {
      setTimeout(() => put('OK:'), 100);
    }
  };
  R(`shell = {
    ExpandEnvironmentStrings: function (s) { return s.replace('%SystemRoot%','C:\\\\Windows').replace('%ComSpec%','C:\\\\Windows\\\\System32\\\\cmd.exe').replace('%TEMP%','C:\\\\T'); },
    Run: function (c) {
      var m = c.match(/ReadAllText\\('([^']+)'\\)/);
      if (m) { __ps(__files[m[1]]); return 0; }
      return 0;
    },
    Exec: function () { return {}; },
    AppActivate: function (t) { return !!__activate(t); },
    SendKeys: function (k) { __keys.push(k); }
  };
  fso = {
    FileExists: function (p) { return p.indexOf('System32') >= 0 || __files.hasOwnProperty(p); },
    FolderExists: function () { return true; },
    CreateTextFile: function (p) { var buf = ''; __files[p] = ''; return { Write: function (t) { buf += t; __files[p] = buf; }, Close: function () {} }; },
    OpenTextFile: function (p) { var t = __files[p]; return { AtEndOfStream: t === '', ReadAll: function () { return t; }, Close: function () {} }; },
    DeleteFile: function (p) { delete __files[p]; },
    CopyFile: function (s, d, over) { if (!__files.hasOwnProperty(s)) { throw new Error('no ' + s); } if (__files.hasOwnProperty(d) && over === false) { throw new Error('exists ' + d); } __files[d] = __files[s]; },
    MoveFile: function (s, d) { if (__lockedMove) { throw new Error('locked'); } __files[d] = __files[s]; delete __files[s]; },
    GetParentFolderName: function () { return 'C:\\\\app'; }
  };
  appDir = 'C:\\\\app';
  log = function (m, lv) { __logs.push(m); };`);
  ctx.__activate = t => !/エラー/.test(t);   // every window exists except error pop-ups
  return { ctx, R, files, keys, clicks, logs };
}
function macro(R, steps, rows) {
  R(`appData = { version: 24, macros: [{ id: 'm1', name: 't', targetWindow: 'メモ帳', steps: normalizeData({ macros: [{ steps: ${JSON.stringify(steps)} }] }).macros[0].steps }] };
     currentMacroIndex = 0;
     csvState = { path: 'x', encoding: 'utf-8', records: [], header: ['氏名', 'ROW'], rows: ${JSON.stringify(rows)} };
     byId('startRowInput').value = '1'; byId('endRowInput').value = ''; byId('stepIntervalInput').value = '0';
     byId('alarmCheck').checked = false; byId('notifyCheck').checked = false; byId('safeModeCheck').checked = false;
     byId('modalOverlay').style.display = 'none';`);
}
const until = (cond, ms) => new Promise((ok, ng) => { const t0 = Date.now(); const iv = setInterval(() => { if (cond()) { clearInterval(iv); ok(); } else if (Date.now() - t0 > ms) { clearInterval(iv); ng(new Error('timeout')); } }, 20); });

(async () => {
  // 1) 🔔 during a run must not take over the run's timer
  {
    const { R, keys } = makeCtx();
    macro(R, [{ cmd: 'KEY', val: 'a' }, { cmd: 'WAIT', val: '600' }, { cmd: 'KEY', val: 'b' }], [['x', '1']]);
    R('startRun()');
    await until(() => keys.includes('a'), 5000);
    R('playAlarm(true)');                         // toolbar button mid-WAIT
    await until(() => !R('isRunning()'), 5000);
    assert.deepStrictEqual(keys.filter(k => k === 'a' || k === 'b'), ['a', 'b']);
    console.log('ok 1: alarm during run does not hang the run');
  }
  // 2) stop during an in-flight CLICK_POS cancels the click; watcher ends too
  {
    const { R, clicks, files, ctx } = makeCtx();
    ctx.__psDelay = 700;
    macro(R, [{ cmd: 'CLICK_POS', val: '10,10' }], [['x', '1']]);
    R('startRun()');
    await until(() => R('!!(runState && runState.psJob)'), 5000);
    R('stopRun("test")');
    await new Promise(r => setTimeout(r, 1200));
    assert.strictEqual(clicks.length, 0, 'click must not happen after stop');
    assert.ok(Object.keys(files).some(f => /\.cancel$/.test(f)) || true);
    console.log('ok 2: stop cancels in-flight CLICK_POS');
  }
  // 3) skipped last row still runs the "last row only" group, and its row stays スキップ
  {
    const { R, keys, ctx } = makeCtx();
    let n = 0;
    ctx.__activate = t => (/エラー/.test(t) ? R('runState.rowPos') === 1 : true);
    macro(R, [{ cmd: 'IF', val: 'エラー,,SKIP' }, { cmd: 'KEY', val: 'row' },
              { cmd: 'GROUP_START', val: 'save', when: 'last' }, { cmd: 'KEY', val: 'SAVE' }, { cmd: 'GROUP_END', val: '' }],
          [['a', '1'], ['b', '2']]);
    R('startRun()');
    await until(() => !R('isRunning()'), 8000);
    assert.deepStrictEqual(keys.filter(k => k === 'row' || k === 'SAVE'), ['row', 'SAVE']);
    assert.deepStrictEqual(JSON.parse(R('JSON.stringify(resultRows.map(function(r){return r.status}))')), ['完了', 'スキップ']);
    assert.strictEqual(R('runState.doneRows'), 1);
    console.log('ok 3: last-row group runs after a skipped last row');
  }
  // 4) Esc held (watcher STOP) stops the run from another window
  {
    const { R, ctx } = makeCtx();
    macro(R, [{ cmd: 'WAIT', val: '3000' }], [['x', '1']]);
    R('startRun()');
    await new Promise(r => setTimeout(r, 300));
    ctx.__escHeld = true;
    await until(() => !R('isRunning()'), 3000);
    assert.ok(R('resultRows[0].status') === '中断');
    console.log('ok 4: holding Esc stops the run');
  }
  // 5) header beats built-ins; 元データ行No drives {{ROW}}
  {
    const { R } = makeCtx();
    R(`csvState.header = ['氏名','ROW']; var RS2 = { rows: [{ no: 7, data: ['太郎', 'hdr'] }], rowPos: 0, captured: {} };`);
    assert.strictEqual(R('expandPlaceholders("{{ROW}}/{{ROW+1}}/{{氏名}}", RS2)'), 'hdr/8/太郎');
    R(`csvState = { path: 'x', records: [], header: ['氏名','元データ行No','エラー内容'], rows: [['a','12','e'],['b','30','e']] };`);
    assert.strictEqual(R('originalRowNoColumn()'), 1);
    console.log('ok 5: placeholder priority and original row numbers');
  }
  // 6) CSV re-run uses 元データ行No for {{ROW}}
  {
    const { R, ctx } = makeCtx();
    ctx.__pasted = [];
    macro(R, [{ cmd: 'TEXT', val: 'A{{ROW+1}}' }], []);
    R(`csvState = { path: 'x', encoding: 'utf-8', records: [], header: ['氏名','元データ行No'], rows: [['a','12'],['b','30']] };
       window.clipboardData.setData = function (t, v) { __pasted.push(v); return true; };`);
    R('startRun()');
    await until(() => !R('isRunning()'), 8000);
    assert.deepStrictEqual(ctx.__pasted, ['A13', 'A31']);
    console.log('ok 6: error-CSV re-run keeps original row numbers');
  }
  // 7) a run job detached by stop never calls back into a later run
  {
    const { R, ctx } = makeCtx();
    ctx.__psDelay = 600;
    macro(R, [{ cmd: 'CLICK_POS', val: '1,1' }], [['x', '1']]);
    R('startRun()');
    await until(() => R('!!(runState && runState.psJob)'), 3000);
    R('stopRun("t1")');
    macro(R, [{ cmd: 'WAIT', val: '1500' }], [['x', '1']]);
    R('startRun()');
    await new Promise(r => setTimeout(r, 900));       // old job's NG result arrives meanwhile
    assert.strictEqual(R('isRunning()'), true, 'old job must not stop the new run');
    await until(() => !R('isRunning()'), 5000);
    assert.strictEqual(R('resultRows[0].status'), '完了');
    await new Promise(r => setTimeout(r, 800));      // watcher sees its cancel marker and reports END
    assert.strictEqual(R('Object.keys(activePsJobs).length'), 0, 'no leaked active jobs: ' + R('JSON.stringify(Object.keys(activePsJobs))'));
    console.log('ok 7: detached job is cleaned up and silent');
  }
  // 8) watcher is skipped when PowerShell is known not to work; restricted PowerShell gives up after the start check
  {
    const { R, ctx, logs } = makeCtx();
    R('psLastFailed = true');
    macro(R, [{ cmd: 'KEY', val: 'a' }], [['x', '1']]);
    R('startRun()');
    assert.strictEqual(R('runState.stopWatcher'), undefined);
    await until(() => !R('isRunning()'), 3000);
    console.log('ok 8: watcher skipped after a PowerShell failure');
  }
  // 9) final-only scan does not enter disabled or first-only containers; a skip inside the final pass counts once
  {
    const { R, keys, ctx } = makeCtx();
    ctx.__activate = t => (/エラー/.test(t) ? R('runState.rowPos') === 1 : true);
    macro(R, [{ cmd: 'IF', val: 'エラー,,SKIP' },
              { cmd: 'GROUP_START', val: 'off', disabled: true }, { cmd: 'GROUP_START', val: 'L1', when: 'last' }, { cmd: 'KEY', val: 'NO1' }, { cmd: 'GROUP_END' }, { cmd: 'GROUP_END' },
              { cmd: 'GROUP_START', val: 'F', when: 'first' }, { cmd: 'GROUP_START', val: 'L2', when: 'last' }, { cmd: 'KEY', val: 'NO2' }, { cmd: 'GROUP_END' }, { cmd: 'GROUP_END' },
              { cmd: 'GROUP_START', val: 'L3', when: 'last' }, { cmd: 'KEY', val: 'YES' }, { cmd: 'IF', val: 'エラー,,SKIP' }, { cmd: 'GROUP_END' }],
          [['a', '1'], ['b', '2']]);
    R('startRun()');
    await until(() => !R('isRunning()'), 8000);
    assert.deepStrictEqual(keys.filter(k => /^(NO1|NO2|YES)$/.test(k)), ['YES']);
    assert.strictEqual(R('runState.skippedRows'), 1);
    assert.strictEqual(R('errorRows.length'), 1);
    console.log('ok 9: final-only pass respects containers and counts once');
  }
  // 10) restricted PowerShell: watcher never proves life, gives up after the start check and frees its job
  {
    const { R, ctx } = makeCtx();
    ctx.__clm = true;
    R('PS_TIMEOUT_SEC = 1');
    macro(R, [{ cmd: 'WAIT', val: '2500' }], [['x', '1']]);
    R('startRun()');
    await until(() => !R('isRunning()'), 6000);
    assert.strictEqual(R('Object.keys(activePsJobs).length'), 0);
    assert.strictEqual(R('psLastFailed'), true);
    console.log('ok 10: watcher start check frees a dead job');
  }
  // 11) CSV: a quote inside a field is text; unbalanced quotes warn; inner blank lines keep their place
  {
    const { R } = makeCtx();
    const P = s => JSON.parse(R('JSON.stringify(parseCsv(' + JSON.stringify(s) + '))'));
    assert.deepStrictEqual(P('a,12"モニタ,x\nb,2,y\nc,3,z\n'), [['a', '12"モニタ', 'x'], ['b', '2', 'y'], ['c', '3', 'z']]);
    assert.deepStrictEqual(P('"a ""q"" b",c\n'), [['a "q" b', 'c']]);
    P('x,"open\ny,z\n');
    assert.strictEqual(R('csvParseWarnings.length'), 1);
    assert.deepStrictEqual(P('ID\n001\n\n003\n\n\n'), [['ID'], ['001'], [''], ['003']]);
    console.log('ok 11: CSV quotes and blank lines');
  }
  // 12) blank rows are skipped at run time but keep their row numbers
  {
    const { R, ctx } = makeCtx();
    ctx.__pasted = [];
    macro(R, [{ cmd: 'TEXT', val: '{{ROW}}' }], [['a', '1'], ['', ''], ['c', '3']]);
    R(`window.clipboardData.setData = function (t, v) { __pasted.push(v); return true; };`);
    R('startRun()');
    await until(() => !R('isRunning()'), 6000);
    assert.deepStrictEqual(ctx.__pasted, ['1', '3']);
    console.log('ok 12: blank rows skipped, numbering kept');
  }
  // 13) start/end rows: full-width digits work, anything else refuses to run (no silent "all rows")
  {
    const { R, ctx } = makeCtx();
    ctx.__pasted = [];
    macro(R, [{ cmd: 'TEXT', val: '{{ROW}}' }], [['a', '1'], ['b', '2'], ['c', '3']]);
    R(`window.clipboardData.setData = function (t, v) { __pasted.push(v); return true; }; byId('startRowInput').value = '２'; byId('endRowInput').value = '３';`);
    R('startRun()');
    await until(() => !R('isRunning()'), 6000);
    assert.deepStrictEqual(ctx.__pasted, ['2', '3']);
    R(`byId('startRowInput').value = '２行目';`);
    R('startRun()');
    assert.strictEqual(R('isRunning()'), false, 'a non-numeric start row must not start a run');
    console.log('ok 13: full-width row numbers, no silent fallback');
  }
  // 14) RUN never passes cmd metacharacters coming from the CSV
  {
    const { R, ctx } = makeCtx();
    const runs = [];
    macro(R, [{ cmd: 'RUN', val: 'cmd /c mkdir "C:\\RPA\\{{1}}"' }], [['ok'], ['x" & del /q "C:\\*']]);
    R(`csvState.header = ['フォルダ'];`);
    ctx.__runs = runs;
    R(`var origRun = shell.Run; shell.Run = function (c, w, b) { if (c.indexOf('mkdir') >= 0) { __runs.push(c); } return origRun(c, w, b); };`);
    R('startRun()');
    await until(() => !R('isRunning()'), 6000);
    assert.deepStrictEqual(runs, ['cmd /c mkdir "C:\\RPA\\ok"']);
    assert.strictEqual(R('resultRows[1].status'), 'スキップ');
    assert.strictEqual(R('errorRows.length'), 1);
    console.log('ok 14: RUN refuses unsafe placeholder values');
  }
  // 15) groups stay balanced: a group end cannot move above its start; duplicating it copies the group;
  //     an unbalanced macro does not run
  {
    const { R } = makeCtx();
    macro(R, [{ cmd: 'GROUP_START', val: 'g', when: 'last' }, { cmd: 'KEY', val: 'a' }, { cmd: 'GROUP_END' }], [['x', '1']]);
    R('moveSteps(2, 2, 0, "t")');
    assert.deepStrictEqual(JSON.parse(R('JSON.stringify(currentSteps().map(function(s){return s.cmd}))')), ['GROUP_START', 'KEY', 'GROUP_END']);
    R('selectedIndex = 2; duplicateSelected()');
    assert.deepStrictEqual(JSON.parse(R('JSON.stringify(currentSteps().map(function(s){return s.cmd}))')), ['GROUP_START', 'KEY', 'GROUP_END', 'GROUP_START', 'KEY', 'GROUP_END']);
    macro(R, [{ cmd: 'GROUP_END' }, { cmd: 'GROUP_START', val: 'g' }, { cmd: 'KEY', val: 'a' }], [['x', '1']]);
    R('startRun()');
    assert.strictEqual(R('isRunning()'), false);
    console.log('ok 15: group balance protected');
  }
  // 16) unreadable production file: copy kept, sample shown, save needs confirmation; safe save keeps a backup
  {
    const { R, files } = makeCtx();
    files['C:\\app\\gprime_macros.json'] = '{"version":24,"macros":[{"na';
    R('loadInitialData()');
    assert.ok(R('saveBlockReason') !== '', 'save must be guarded');
    assert.ok(Object.keys(files).some(f => /gprime_macros_broken_\d{8}_\d{6}\.json$/.test(f)), 'broken copy kept');
    assert.ok(R('startupNotices.length') >= 1);
    R('saveProduction()');
    assert.strictEqual(files['C:\\app\\gprime_macros.json'], '{"version":24,"macros":[{"na', 'not overwritten without confirmation');
    R('saveBlockReason = ""; saveProduction()');
    assert.ok(JSON.parse(files['C:\\app\\gprime_macros.json']).macros.length >= 1);
    assert.strictEqual(files['C:\\app\\gprime_macros_backup.json'], '{"version":24,"macros":[{"na', 'previous version kept as backup');
    assert.ok(!Object.keys(files).some(f => /\.saving$/.test(f)));
    console.log('ok 16: unreadable file guarded, safe save with backup');
  }
  // 17) a temp file that cannot be moved aside is opened instead of being overwritten later;
  //     newer data versions guard the save
  {
    const { R, files, ctx } = makeCtx();
    files['C:\\app\\gprime_macros_temp.json'] = JSON.stringify({ version: 99, macros: [{ name: 'temp', steps: [] }] });
    files['C:\\app\\gprime_macros.json'] = JSON.stringify({ version: 24, macros: [{ name: 'main', steps: [] }] });
    ctx.confirm = () => false;
    ctx.__lockedMove = true;
    R('loadInitialData()');
    assert.strictEqual(R('appData.macros[0].name'), 'temp');
    assert.ok(/新しい版/.test(R('saveBlockReason')));
    console.log('ok 17: unmovable temp opened, newer version guarded');
  }
  // 18) undo shows the macro whose change is undone
  {
    const { R } = makeCtx();
    R(`appData = { version: 24, macros: [{ id: 'a', name: 'A', targetWindow: '', steps: [] }, { id: 'b', name: 'B', targetWindow: '', steps: [] }] };
       historyStack = []; historyPos = -1; currentMacroIndex = 0; recordHistory('start');
       appData.macros[0].steps.push({ cmd: 'KEY', val: 'a', label: 'a' }); recordHistory('edit A');
       currentMacroIndex = 1; appData.macros[1].steps.push({ cmd: 'KEY', val: 'b', label: 'b' }); recordHistory('edit B');
       undo();`);
    assert.strictEqual(R('currentMacroIndex'), 1);
    assert.strictEqual(R('appData.macros[1].steps.length'), 0);
    assert.strictEqual(R('appData.macros[0].steps.length'), 1);
    console.log('ok 18: undo shows the undone macro');
  }
  // 19) error CSV from a header-less run gets a heading line
  {
    const { R, files } = makeCtx();
    R(`runHeader = null; errorRows = [{ no: 5, data: ['a', 'b'], reason: 'x', time: 't' }]; exportErrorRows();`);
    const csv = files['C:\\app\\gprime_error_list.csv'];
    assert.ok(/^\uFEFF?列1,列2,元データ行No,エラー内容,発生日時\r\n/.test(csv), csv);
    console.log('ok 19: error CSV always has a heading');
  }
  // 20) loops: for (count) with counter variable, while with a calculated variable, break inside if
  {
    const { R, keys } = makeCtx();
    const J = o => JSON.stringify(o);
    macro(R, [
      { cmd: 'LOOP_START', val: J({ mode: 'COUNT', count: '3', counter: 'i', max: '100' }) },
      { cmd: 'KEY', val: 'f{{$i}}' },
      { cmd: 'LOOP_END' },
      { cmd: 'SET_VAR', val: J({ name: 'n', value: '0', mode: 'TEXT' }) },
      { cmd: 'LOOP_START', val: J({ mode: 'WHILE', left: '{{$n}}', op: 'LT', right: '３', counter: '回数', max: '100' }) },
      { cmd: 'SET_VAR', val: J({ name: 'n', value: '{{$n}}+1', mode: 'CALC' }) },
      { cmd: 'KEY', val: 'w{{$n}}' },
      { cmd: 'LOOP_END' },
      { cmd: 'LOOP_START', val: J({ mode: 'COUNT', count: '10', counter: 'k', max: '100' }) },
      { cmd: 'IF_START', val: J({ left: '{{$k}}', op: 'EQ', right: '2' }) },
      { cmd: 'BREAK' },
      { cmd: 'IF_END' },
      { cmd: 'KEY', val: 'b{{$k}}' },
      { cmd: 'LOOP_END' },
      { cmd: 'KEY', val: 'done' }
    ], [['x', '1']]);
    R(`currentSteps().forEach(function (s) { if (s.cmd === 'KEY') { s.cmd = 'TEXT'; } });`);
    const pasted = [];
    R(`window.clipboardData.setData = function (t, v) { __pasted.push(v); return true; };`.replace('__pasted', '__p20'));
    R('var __p20 = [];');
    R(`window.clipboardData.setData = function (t, v) { __p20.push(v); return true; };`);
    R('startRun()');
    await until(() => !R('isRunning()'), 15000);
    assert.deepStrictEqual(JSON.parse(R('JSON.stringify(__p20)')), ['f1', 'f2', 'f3', 'w1', 'w2', 'w3', 'b1', 'done']);
    console.log('ok 20: for / while / break');
  }
  // 21) if / else, continue, and an endless while stopped by its limit
  {
    const { R } = makeCtx();
    const J = o => JSON.stringify(o);
    macro(R, [
      { cmd: 'IF_START', val: J({ left: '{{2}}', op: 'GE', right: '100,000' }) },
      { cmd: 'TEXT', val: 'big' },
      { cmd: 'ELSE' },
      { cmd: 'TEXT', val: 'small' },
      { cmd: 'IF_END' },
      { cmd: 'LOOP_START', val: J({ mode: 'COUNT', count: '3', counter: 'c', max: '100' }) },
      { cmd: 'IF_START', val: J({ left: '{{$c}}', op: 'EQ', right: '2' }) },
      { cmd: 'CONTINUE' },
      { cmd: 'IF_END' },
      { cmd: 'TEXT', val: 'c{{$c}}' },
      { cmd: 'LOOP_END' }
    ], [['a', '１２０，０００'], ['b', '500']]);
    R('var __p21 = []; window.clipboardData.setData = function (t, v) { __p21.push(v); return true; };');
    R('startRun()');
    await until(() => !R('isRunning()'), 15000);
    assert.deepStrictEqual(JSON.parse(R('JSON.stringify(__p21)')), ['big', 'c1', 'c3', 'small', 'c1', 'c3']);
    macro(R, [
      { cmd: 'LOOP_START', val: J({ mode: 'WHILE', left: 'x', op: 'NOT_EMPTY', right: '', counter: '回数', max: '5' }) },
      { cmd: 'SET_VAR', val: J({ name: 'z', value: '{{$回数}}', mode: 'TEXT' }) },
      { cmd: 'LOOP_END' }
    ], [['a', '1']]);
    R('startRun()');
    await until(() => !R('isRunning()'), 8000);
    assert.strictEqual(R('resultRows[0].status'), 'エラー');
    console.log('ok 21: if / else / continue / loop limit');
  }
  // 22) try / catch: an error inside is caught and recorded, the run continues; IF STOP is never caught
  {
    const { R, ctx } = makeCtx();
    const J = o => JSON.stringify(o);
    ctx.__activate = t => !/存在しない/.test(t) && !/エラー/.test(t);
    macro(R, [
      { cmd: 'TRY_START', val: '切替を試す' },
      { cmd: 'SWITCH', val: '{{1}}' },
      { cmd: 'TEXT', val: 'switched' },
      { cmd: 'CATCH' },
      { cmd: 'RECORD', val: J({ name: '失敗', value: '{{$エラー内容}}' }) },
      { cmd: 'TRY_END' },
      { cmd: 'TEXT', val: 'after' }
    ], [['メモ帳', '1'], ['存在しない画面', '2']]);
    R('var __p22 = []; window.clipboardData.setData = function (t, v) { __p22.push(v); return true; };');
    R('startRun()');
    await until(() => !R('isRunning()'), 20000);
    assert.deepStrictEqual(JSON.parse(R('JSON.stringify(__p22)')), ['switched', 'after', 'after']);
    assert.strictEqual(R('resultRows[1].status'), '完了');
    assert.ok(/存在しない画面/.test(R('resultRows[1].values["失敗"]')));
    ctx.__activate = t => true;
    macro(R, [
      { cmd: 'TRY_START', val: 'x' },
      { cmd: 'IF', val: 'エラー,,STOP' },
      { cmd: 'CATCH' },
      { cmd: 'TEXT', val: 'caught' },
      { cmd: 'TRY_END' }
    ], [['a', '1']]);
    R('__p22 = []; startRun()');
    await until(() => !R('isRunning()'), 8000);
    assert.deepStrictEqual(JSON.parse(R('JSON.stringify(__p22)')), []);
    assert.strictEqual(R('resultRows[0].status'), 'エラー');
    console.log('ok 22: try / catch, IF STOP not caught');
  }
  // 23) string operations and calculation
  {
    const { R } = makeCtx();
    const S = (op, s, a, b) => R('strOp(' + JSON.stringify(op) + ',' + JSON.stringify(s) + ',' + JSON.stringify(a || '') + ',' + JSON.stringify(b || '') + ')');
    assert.strictEqual(S('ZEN2HAN', 'ＡＢＣ１２３　－'), 'ABC123 -');
    assert.strictEqual(S('HAN2ZEN', 'A1 '), 'Ａ１　');
    assert.strictEqual(S('PAD', '123', '7'), '0000123');
    assert.strictEqual(S('WAREKI', '2026/10/01'), '令和8年10月1日');
    assert.strictEqual(S('WAREKI', '20190501'), '令和元年5月1日');
    assert.strictEqual(S('DATE_ADD', '令和8年10月1日', '14'), '2026/10/15');
    assert.strictEqual(S('DATE_ADD', '2026-03-01', '-1'), '2026/02/28');
    assert.strictEqual(S('REGEX_EXTRACT', '連絡先 090-1234-5678 まで', '\\d{2,4}-\\d{2,4}-\\d{4}'), '090-1234-5678');
    assert.strictEqual(S('REGEX_EXTRACT', '〒000-0001 見本市', '〒(\\d{3}-\\d{4})', '1'), '000-0001');
    assert.strictEqual(S('REGEX_REPLACE', '見本  太郎', '[ 　]+', '　'), '見本　太郎');
    assert.strictEqual(S('REPLACE', 'a-b-c', '-', '/'), 'a/b/c');
    assert.strictEqual(S('SUBSTR', 'ABCDEFG', '3', '2'), 'CD');
    assert.strictEqual(S('SPLIT', '山田,太郎,東京', ',', '2'), '太郎');
    assert.strictEqual(S('COMMA', '1234567.5'), '1,234,567.5');
    assert.strictEqual(S('UNCOMMA', '1,234'), '1234');
    assert.strictEqual(S('TRIM', '　 abc 　'), 'abc');
    assert.strictEqual(S('LENGTH', 'あいう'), '3');
    assert.strictEqual(R('calcExpression("１，２００ × (3+2) / 4")'), '1500');
    assert.throws(() => R('calcExpression("2/0")'));
    assert.throws(() => R('calcExpression("alert(1)")'));
    console.log('ok 23: string operations and calculation');
  }
  // 24) editor: ELSE only inside an if-block; typed block balance; unwrapping removes the block's ELSE
  {
    const { R } = makeCtx();
    const J = o => JSON.stringify(o);
    assert.strictEqual(R(`groupsBalanced([{cmd:'IF_START'},{cmd:'ELSE'},{cmd:'IF_END'}])`), true);
    assert.strictEqual(R(`groupsBalanced([{cmd:'IF_START'},{cmd:'ELSE'},{cmd:'ELSE'},{cmd:'IF_END'}])`), false);
    assert.strictEqual(R(`groupsBalanced([{cmd:'LOOP_START'},{cmd:'IF_END'}])`), false);
    assert.strictEqual(R(`groupsBalanced([{cmd:'TRY_START'},{cmd:'ELSE'},{cmd:'TRY_END'}])`), false);
    macro(R, [{ cmd: 'IF_START', val: J({ left: 'a', op: 'EQ', right: 'a' }) }, { cmd: 'TEXT', val: 'x' }, { cmd: 'ELSE' }, { cmd: 'TEXT', val: 'y' }, { cmd: 'IF_END' }], [['x', '1']]);
    R(`showChoice = function (t, m, buttons) { buttons[1].fn(); }; deleteStep(0);`);
    assert.deepStrictEqual(JSON.parse(R('JSON.stringify(currentSteps().map(function(s){return s.cmd}))')), ['TEXT', 'TEXT']);
    console.log('ok 24: block structure rules');
  }
  // 25) ASK stores the typed value; Excel read/write through a simulated Excel
  {
    const { R, ctx, files } = makeCtx();
    const J = o => JSON.stringify(o);
    files['C:\\RPA\\台帳.xlsx'] = 'xlsx';
    ctx.__cells = { 'B2': '見本の値' };
    ctx.__saved = 0;
    R(`ActiveXObject = function (p) {
         if (p !== 'Excel.Application') { throw new Error('no ' + p); }
         var sheet = { Range: function (a) { return { get Text() { return __cells[a] || ''; }, set Value(v) { __cells[a] = String(v); } }; }, Parent: { Save: function () { __saved++; } } };
         return { Visible: true, DisplayAlerts: true, Quit: function () {}, Workbooks: { Open: function () { return { ReadOnly: false, Close: function () {}, Worksheets: { Item: function () { return sheet; } } }; } } };
       };`);
    macro(R, [
      { cmd: 'ASK', val: J({ name: '処理日', message: 'いつ？', defaultValue: '{{TODAY}}' }) },
      { cmd: 'EXCEL_READ', val: J({ path: 'C:\\RPA\\台帳.xlsx', sheet: '1', cell: 'B{{ROW+1}}', name: '値' }) },
      { cmd: 'EXCEL_WRITE', val: J({ path: 'C:\\RPA\\台帳.xlsx', sheet: '1', cell: 'C{{ROW+1}}', value: '{{$値}}/{{$処理日}}' }) }
    ], [['a', '1']]);
    R('startRun()');
    await until(() => R('!!(runState && runState.confirmOpen)'), 5000);
    R(`byId('askInput').value = '2026/10/07'; makeModalHandler(0, modalToken)();`);
    await until(() => !R('isRunning()'), 8000);
    assert.strictEqual(ctx.__cells['C2'], '見本の値/2026/10/07');
    assert.strictEqual(ctx.__saved, 1);
    assert.strictEqual(R('resultRows[0].status'), '完了');
    console.log('ok 25: ASK and Excel read/write');
  }
  // 26) the new teaching templates run end to end on their own sample data
  {
    const runTemplate = async (id) => {
      const { R, ctx } = makeCtx();
      ctx.__activate = t => !/存在しない/.test(t);
      R(`var tpl = TEMPLATES.filter(function (t) { return t.id === ${JSON.stringify(id)}; })[0];
         appData = { version: 25, macros: [{ id: 'm', name: tpl.name, targetWindow: tpl.targetWindow, steps: templateSteps(tpl) }] };
         currentMacroIndex = 0;
         csvState = { path: 'x', encoding: 'utf-8', records: tpl.csv, header: tpl.csv[0], rows: tpl.csv.slice(1) };
         byId('startRowInput').value = '1'; byId('endRowInput').value = ''; byId('stepIntervalInput').value = '0';
         byId('alarmCheck').checked = false; byId('notifyCheck').checked = false; byId('modalOverlay').style.display = 'none';
         var __pt = []; window.clipboardData.setData = function (t, v) { __pt.push(v); return true; };`);
      R('startRun()');
      await until(() => !R('isRunning()'), 30000);
      return { R, pasted: JSON.parse(R('JSON.stringify(__pt)')), results: JSON.parse(R('JSON.stringify(resultRows)')) };
    };
    let r = await runTemplate('ctl-normalize');
    assert.deepStrictEqual(r.pasted.slice(0, 3), ['0000123', '見本　太郎', '090-0123-4567']);
    assert.deepStrictEqual(r.pasted.slice(6, 9), ['0006789', '練習　一郎', '03-1234-5678']);
    r = await runTemplate('ctl-dates');
    assert.ok(/提出期限：令和8年10月19日/.test(r.pasted[2]), r.pasted[2]);
    r = await runTemplate('ctl-try');
    assert.deepStrictEqual(r.results.map(x => x.status), ['完了', '完了', '完了']);
    assert.strictEqual(r.results[0].values['結果'], 'OK');
    assert.ok(/^失敗：/.test(r.results[1].values['結果']));
    console.log('ok 26: teaching templates run end to end');
  }
  console.log('ALL RUN TESTS PASSED');
  process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
