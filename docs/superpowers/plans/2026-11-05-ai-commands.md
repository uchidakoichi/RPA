# AI コマンド（AIに選んでもらう・AIに抜き出してもらう） Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ふじキュンにコマンド2つ（`AI_CHOOSE`・`AI_EXTRACT`）を足す。AI は、共有ドライブに1つ置いたものを `%LOCALAPPDATA%` に写し、再生中だけ llama-server を動かして使う。

**Architecture:** 新しい純粋な関数（問いの組み立て・確率の読み取り・判定・確認用の一覧・`ai.json`）を `src/Ai.ps1` に置く。2つのコマンドは `src/Runner.ps1` の分岐から呼び、AI への問い合わせは新しい Io の口（`AiChat`・`AiPick`）を通す。これでテストでは偽物の Io を使える。写す・起動する・止める（Windows のプロセスと HTTP）は `gui/AiServer.ps1`、画面は `gui/Ai.ps1` に置く。

**Tech Stack:** Windows PowerShell 5.1、Windows Forms、llama.cpp b12063 x64（`llama-server.exe`）、Qwen3.5-2B Q4_K_M。

**Spec:** `docs/superpowers/specs/2026-11-05-ai-commands-design.md`

## Global Constraints

- `.ps1` は ASCII・CRLF。日本語の文言は `fujikyun_ja.json`（`Get-FujiText` のキー）と `fujikyun_commands.json`・`fujikyun_templates.json` にだけ書く。
- 外部の部品は足さない（llama.cpp とモデルのほかには何も使わない）。
- `src` と `gui` を直したら `powershell -NoProfile -File build\Build-FujiBundle.ps1` で `fujikyun.ps1` を作り直す（テストが一致を確かめる）。
- テストは `ssh win11vm 'powershell -NoProfile -ExecutionPolicy Bypass -File \\Mac\Home\Developer\RPAhta\RPA\tests\Invoke-FujiTest.ps1'` で通す（Mac に pwsh は無い）。
- llama-server の設定: `-c 4096 -t 8 --cache-ram 0 -ctxcp 4 -np 1 --no-repack --jinja`、`--host 127.0.0.1`。
- 写し先: `%LOCALAPPDATA%\fujikyun\ai\`。写す前の C: の空き: 2GB 以上。起動前の空きメモリ: 1GB 以上。`/health` を待つのは最大60秒。1回の問い合わせの時間切れは60秒。
- `AI_CHOOSE`: 選択肢 2〜10、しきい値の初期値 0.5、`low` の初期値 `REVIEW`、`unknown` の初期値 `不明`、確率の変数 `{{$<name>_確率}}`（小数2桁）、記号の確率の合計が 0.5 未満ならしきい値未満と同じ扱い、`src` は3000字で切る。
- `AI_EXTRACT`: 項目 1〜10、1項目 `maxLength 100`、`max_tokens` は項目の数 × 60（最大600）、`strict` の初期値 `ON`。
- 確認用の一覧: `fujikyun_logs\ai_review_YYYY-MM-DD.csv`（UTF-8 BOM 付き）。読ませた文は先頭100字だけ残す。ログ（実行記録）には読ませた文を残さない。
- 番号: `commandsVersion` 2→3、`textVersion` 12→13、`src/Version.ps1` の版を作業した日の日付に上げる。
- 新しい機能にはチュートリアルとテンプレートを同じ PR で付ける。

## Review Focus

1. **選択肢の書き方の揺れ**（`値：説明` の全角コロン、前後の空白、空行、同じ値が2つ）→ 半角コロンと同じに読み、空行は無視する。同じ値が2つあるときは保存の前に止める。Task 2 にテスト。
2. **読ませる文が空**（変数が空、空白だけ）→ AI に問い合わせない。`AI_CHOOSE` は `unknown` を入れて確認用の一覧に理由 `読ませる文が空` を書く。`AI_EXTRACT` は全項目を空にする。Task 3 にテスト。
3. **共有ドライブにつながらない**（ネットワークが切れている）が、C: の写しはある → 写しで動かし、ログに注意を1行出す。止めない。Task 4 にテスト。
4. **記号の前の空白や小文字**（トークンが ` A`・`a`）→ 同じ記号として足し合わせる。Task 1 にテスト。
5. **抜き出した値に改行・引用符・カンマ**が入る → 変数にはそのまま入れる。確認用の一覧の CSV は崩れない。Task 1 にテスト。

---

### Task 1: AI の純粋な関数（`src/Ai.ps1`）

**Files:**
- Create: `src/Ai.ps1`
- Modify: `tests/Invoke-FujiTest.ps1`（`# ---- AI` の節を「commands and templates」の前に足す）

**Interfaces:**
- Produces:
  - `Read-FujiAiOption -Text <string>` → `List[hashtable]`。1件は `@{ Value; Note }`。区切りは `:` か `：` の最初の1つ。空行は読み飛ばす。
  - `Read-FujiAiItem -Text <string>` → `List[hashtable]`。1件は `@{ Name; Note }`。書き方は同じ。
  - `New-FujiAiChooseBody -Question <string> -Options <list> -Source <string>` → hashtable。中身は `messages`（system・user）・`max_tokens 1`・`temperature 0`・`logprobs $true`・`top_logprobs 20`・`chat_template_kwargs @{ enable_thinking = $false }` と、`Truncated`（bool。3000字で切ったか）。`Truncated` は送る前に外す。
  - `Read-FujiAiChoice -Response <object> -Options <list>` → `@{ Value; P; Covered; Probs }`。`Probs` は `[ordered]` で、値→確率。読み方は `tools/llm-bench/Invoke-LlmDecide.ps1` と同じだが、トークンは Trim し大文字にしてから記号と比べる。
  - `New-FujiAiExtractBody -Items <list> -Note <string> -Source <string>` → hashtable（`response_format` の json_schema、`max_tokens = [Math]::Min(600, 60 * 項目数)`）。
  - `Test-FujiAiInSource -Value <string> -Source <string>` → bool。どちらも NFKC にし、空白を除いて比べる。値が空なら `$true`。
  - `Add-FujiAiReviewRow -Directory <string> -Now <datetime> -Row <IDictionary>` → 書いたファイルのパス。ファイルが無ければ見出しと BOM を付けて作り、あれば足す。CSV の書き出しは既存の `ConvertTo-FujiCsvLine` を使う（`src/Csv.ps1`。無ければ同じ規則で書く）。列のキーは time, macro, step, row, command, name, source, answer, p, probs, reason。`source` は先頭100字。
  - `Read-FujiAiManifest -Path <string>` → `@{ AiVersion; Model; Files; ServerArgs }`。読めなければ throw。
  - `Test-FujiAiCopyNeeded -Shared <hashtable> -Local <hashtable|$null> -LocalDir <string>` → `'none' | 'copy'`。写しが無い、`aiVersion` が違う、モデルの大きさが違う、のどれかなら `'copy'`。
- Consumes: `ConvertFrom-FujiJson`・`Read-FujiUtf8File`（`src/Json.ps1`・`src/Files.ps1`）。

- [ ] **Step 1: Write the failing tests**（`tests/Invoke-FujiTest.ps1` の AI の節）

```powershell
$o = Read-FujiAiOption -Text "住民票`nごみ：収集日・粗大ごみ`n`n その他 "
Assert-Equal @('住民票','ごみ','その他') @($o | ForEach-Object { $_.Value }) 'ai: options, full-width colon, blank line, spaces'
Assert-Equal '収集日・粗大ごみ' $o[1].Note 'ai: option note'
$b = New-FujiAiChooseBody -Question 'どの担当か' -Options $o -Source ('あ' * 3100)
Assert-True ($b.messages[0].content.Contains("A: 住民票") -and $b.messages[0].content.Contains("B: ごみ（収集日・粗大ごみ）")) 'ai: choose prompt letters'
Assert-Equal 3000 $b.messages[1].content.Length 'ai: source cut at 3000'
Assert-True $b.Truncated 'ai: cut is reported'
$resp = '{"choices":[{"logprobs":{"content":[{"top_logprobs":[{"token":" A","logprob":-0.5},{"token":"b","logprob":-1.2},{"token":"x","logprob":-3}]}]}}]}' | ConvertFrom-Json
$c = Read-FujiAiChoice -Response $resp -Options $o
Assert-Equal '住民票' $c.Value 'ai: choice with a space before the letter'
Assert-True ([Math]::Abs($c.P - (0.6065 / (0.6065 + 0.3012))) -lt 0.001) 'ai: probability shared among options (lower case b counted)'
Assert-True ($c.Covered -lt 1 -and $c.Covered -gt 0.9) 'ai: covered mass'
Assert-True (Test-FujiAiInSource -Value '中村 さくら' -Source '氏名: 中村　さくら') 'ai: in source, spaces and width'
Assert-True (-not (Test-FujiAiInSource -Value '中村花子' -Source '氏名: 中村さくら')) 'ai: not in source'
# review CSV: BOM, header once, a value with comma, quote and newline stays in one cell
$p1 = Add-FujiAiReviewRow -Directory $work -Now ([datetime]'2026-11-10 09:00') -Row ([ordered]@{ time='09:00'; macro='m'; step=3; row=1; command='AI_EXTRACT'; name='氏名'; source="a,b`n""c"""; answer=''; p=''; probs=''; reason='文に無い値' })
[void](Add-FujiAiReviewRow -Directory $work -Now ([datetime]'2026-11-10 09:05') -Row ([ordered]@{ time='09:05'; macro='m'; step=3; row=2; command='AI_CHOOSE'; name='担当'; source='x'; answer='不明'; p='0.33'; probs='住民票=0.33;ごみ=0.30'; reason='しきい値未満' }))
$rows = Read-FujiCsvText (Read-FujiUtf8File -Path $p1)   # the app's own CSV reader
Assert-Equal 3 $rows.Count 'ai: review csv header + 2 rows'
Assert-Equal "a,b`n""c""" $rows[1][6] 'ai: review csv keeps comma, quote, newline'
Assert-Equal 'none' (Test-FujiAiCopyNeeded -Shared @{ AiVersion=1; Model='m.gguf'; Files=@{ 'm.gguf'=@{ size=5 } } } -Local @{ AiVersion=1; Model='m.gguf' } -LocalDir $fakeDirWith5ByteModel) 'ai: same version, same size'
Assert-Equal 'copy' (Test-FujiAiCopyNeeded -Shared @{ AiVersion=2; Model='m.gguf'; Files=@{ 'm.gguf'=@{ size=5 } } } -Local @{ AiVersion=1; Model='m.gguf' } -LocalDir $fakeDirWith5ByteModel) 'ai: new version'
Assert-Equal 'copy' (Test-FujiAiCopyNeeded -Shared @{ AiVersion=1; Model='m.gguf'; Files=@{ 'm.gguf'=@{ size=5 } } } -Local $null -LocalDir $work) 'ai: no copy yet'
```

（`$work`・`$fakeDirWith5ByteModel` は、この節の始めに一時フォルダとして作り、終わりで消す。CSV の読み取り関数は `src/Csv.ps1` の実際の名前に合わせる。）

- [ ] **Step 2: Run the tests and see them fail** — 上のテストのコマンドを実行する。`The term 'Read-FujiAiOption' is not recognized` で FAIL になる。
- [ ] **Step 3: Implement the functions in `src/Ai.ps1`** — 上の署名どおりに作る。system の文は `fujikyun_ja.json` のキー `ai.choosePrompt`（`{0}` に問い、`{1}` に選択肢の行）と `ai.extractPrompt`（`{0}` に項目の行、`{1}` に足す指示）から作る。文はスペックの 4.1・4.2 のとおり。説明つきの選択肢は `A: 値（説明）` と書く。
- [ ] **Step 4: Run the tests and see them pass** — `Invoke-FujiTest.ps1` の最後に `failures: 0` と出れば PASS。
- [ ] **Step 5: Build and commit** — `build\Build-FujiBundle.ps1` を実行してから、`git add src/Ai.ps1 tests/Invoke-FujiTest.ps1 fujikyun_ja.json fujikyun.ps1` とし、`feat(ai): prompt building, probability reading, review list, manifest` でコミットする。

### Task 2: コマンドの定義・入力のチェック・手順の表示

**Files:**
- Modify: `fujikyun_commands.json`（`commands` に `AI_CHOOSE`・`AI_EXTRACT`、`palette` に分類 `ai`、`commandsVersion` 3）
- Modify: `src/Commands.ps1`（`Test-FujiStepSetting`・`Get-FujiStepLabel`）
- Modify: `fujikyun_ja.json`（文言、`textVersion` 13）
- Test: `tests/Invoke-FujiTest.ps1`

**Interfaces:**
- Consumes: `Read-FujiAiOption`・`Read-FujiAiItem`（Task 1）
- Produces:
  - `AI_CHOOSE` の欄 id: `name`, `src`, `question`, `options`（type `textarea`）, `threshold`, `low`（select: `REVIEW`・`ASK`・`STOP`・`USE`）, `unknown`。`definesVar: name`。
  - `AI_EXTRACT` の欄 id: `src`, `items`（textarea）, `note`, `strict`（select: `ON`・`OFF`）。項目の変数名を変数として示す（項目ごとの変数を、編集画面の「使える変数」に出す。今の `definesVar` が1つの名前しか持てないなら、`Commands.ps1` に `Get-FujiStepDefinedVar -Step` を足し、`AI_EXTRACT` では項目名の一覧を返す）。
  - 形式は `"format": "json"`。`defaultVal` には欄の初期値を入れる（スペックの表の値）。

- [ ] **Step 1: Write the failing tests**

```powershell
Assert-True ($null -ne (Get-FujiCommandDef 'AI_CHOOSE')) 'ai: AI_CHOOSE defined'
Assert-True ($null -ne (Get-FujiCommandDef 'AI_EXTRACT')) 'ai: AI_EXTRACT defined'
$ok = @{ name='担当'; src='{{$文}}'; question='どの担当か'; options="住民票`nごみ"; threshold='0.5'; low='REVIEW'; unknown='不明' }
Assert-Equal '' (Test-FujiStepSetting -Cmd 'AI_CHOOSE' -Settings $ok) 'ai: valid choose'
Assert-True ((Test-FujiStepSetting -Cmd 'AI_CHOOSE' -Settings ($ok + @{}) ) -eq '') 'ai: copy still valid'
foreach ($bad in @(@{ options='住民票' }, @{ options=((1..11) -join "`n") }, @{ options="住民票`n住民票：重複" }, @{ threshold='1.5' }, @{ threshold='x' }, @{ name='' })) {
    $s = @{}; foreach ($k in $ok.Keys) { $s[$k] = $ok[$k] }; foreach ($k in $bad.Keys) { $s[$k] = $bad[$k] }
    Assert-True ((Test-FujiStepSetting -Cmd 'AI_CHOOSE' -Settings $s) -ne '') ('ai: choose rejects ' + (($bad.Keys | ForEach-Object { $_ + '=' + $bad[$_] }) -join ','))
}
Assert-Equal '' (Test-FujiStepSetting -Cmd 'AI_EXTRACT' -Settings @{ src='{{$文}}'; items="氏名: 申請者`n電話番号"; note=''; strict='ON' }) 'ai: valid extract'
Assert-True ((Test-FujiStepSetting -Cmd 'AI_EXTRACT' -Settings @{ src='x'; items=''; note=''; strict='ON' }) -ne '') 'ai: extract needs an item'
Assert-Equal @('氏名','電話番号') @(Get-FujiStepDefinedVar -Step @{ cmd='AI_EXTRACT'; val='{"src":"x","items":"氏名: 申請者\n電話番号","note":"","strict":"ON"}' }) 'ai: extract defines one variable per item'
Assert-True ((Get-FujiStepLabel -Step @{ cmd='AI_CHOOSE'; val=(ConvertTo-FujiJson $ok -Indent 0) }) -like '*担当*') 'ai: step label names the variable'
```

（`Test-FujiStepSetting`・`Get-FujiStepLabel` の実際の引数名は `src/Commands.ps1` に合わせる。）

- [ ] **Step 2: Run and see them fail** — `ai: AI_CHOOSE defined` が出れば FAIL。
- [ ] **Step 3: Add the definitions and checks** — 文言はすべて `fujikyun_ja.json` に置く（`commands.json` の `title`・`help`・欄の `label` は今のコマンドと同じ書き方。help の文体は「〜キュン」）。エラーの文は、何が悪いかと直し方を書く（例: 「選択肢は2〜10個にしてね（いま11個）」）。
- [ ] **Step 4: Run and see them pass**（「every text the scripts ask for exists」の節も通ること）
- [ ] **Step 5: Build and commit** — `feat(ai): AI_CHOOSE and AI_EXTRACT definitions and checks`

### Task 3: 再生（`src/Runner.ps1` と Io の口）

**Files:**
- Modify: `src/Runner.ps1`（`Invoke-FujiRunCommand` の分岐に2つ足し、本体は `Invoke-FujiAiChoose`・`Invoke-FujiAiExtract`。Io の説明のコメント（21行目あたり）に `AiChat {Body}`・`AiPick {Caption; Message; Options; Initial}` を足す）
- Modify: `tests/Invoke-FujiTest.ps1`（「runner (fake Io)」の節）

**Interfaces:**
- Consumes: Task 1 の関数全部。
- Produces:
  - `$Run.Io.AiChat` : `param([hashtable]$Body)` → llama-server の応答（`ConvertFrom-Json` したもの）。失敗は throw（その文がエラーの理由になる）。
  - `$Run.Io.AiPick` : `param($Caption, $Message, $Options, $Initial)` → `@{ Choice = 'continue'|'stop'; Value }`。呼ぶのは `Invoke-FujiRunAttended` の中から（人が使った時間に数える）。
  - 確認用の一覧は `Add-FujiAiReviewRow -Directory $Run.Directory -Now (& $Run.Io.Now)`。
  - ログ: `run.aiChoose`（変数・値・確率・ms）、`run.aiExtract`（項目の数・入った数・ms）、`run.aiReview`（理由）、`run.aiCut`（3000字で切った）。

- [ ] **Step 1: Write the failing tests**（今ある偽物の Io の作り方に合わせ、`AiChat` は決まった応答を返し、呼ばれた Body を記録する）

  - `ai run: choose above threshold` — 応答は A=0.8・B=0.2。`Vars['担当'] -eq '住民票'` かつ `Vars['担当_確率'] -eq '0.80'` で、確認用の一覧は作られない。
  - `ai run: choose below threshold REVIEW` — A=0.4・B=0.35・C=0.25。`Vars['担当'] -eq '不明'`、確認用の一覧に1行（reason `しきい値未満`）、再生は続く。
  - `ai run: choose ASK` — `AiPick` は `@{ Choice='continue'; Value='ごみ' }` を返す。`Vars['担当'] -eq 'ごみ'` で、`AiPick` の Initial が `住民票`。
  - `ai run: choose STOP` — 手順はエラー（`Action` が error）。`TRY_START` の中なら受け止められる。
  - `ai run: choose USE` — しきい値未満でも `住民票` が入る。
  - `ai run: letters not answered` — 応答のトークンが全部 `x`。しきい値未満と同じ扱い（reason `記号で答えなかった`）。
  - `ai run: empty source` — `src` の変数が空。`AiChat` は呼ばれず、`不明` が入り、reason は `読ませる文が空`（Review Focus 2）。
  - `ai run: extract strict` — 応答 content が `{"氏名":"中村花子","電話番号":"0466-12-3456"}`、元の文は `中村さくら 0466-12-3456`。`Vars['氏名'] -eq ''`、`Vars['電話番号'] -eq '0466-12-3456'`、一覧に1行（reason `文に無い値`）。
  - `ai run: extract strict OFF` — 同じ応答で `Vars['氏名'] -eq '中村花子'`。
  - `ai run: extract broken JSON` — content が `{"氏名":` のとき、手順はエラーになり、文言は `run.aiBadAnswer`。
  - `ai run: AiChat throws` — 手順はエラーになり、文言に throw の文が入る。
  - `ai run: log has no source text` — ログの全行に、元の文（`中村さくら`）が入っていない。

- [ ] **Step 2: Run and see them fail**
- [ ] **Step 3: Implement** — 選ぶほうは `New-FujiAiChooseBody` → `AiChat` → `Read-FujiAiChoice` の順に呼ぶ。`Covered -lt 0.5` か `P -lt threshold` なら、`low` の4通りに分ける。抜き出しは `New-FujiAiExtractBody` → `AiChat` とし、応答の `choices[0].message.content` を `ConvertFrom-Json` する（失敗したら `run.aiBadAnswer`）。項目ごとに Trim して `strict` で判定する。どちらも、変数を入れたあとに `& $Run.Io.Watch` を呼ぶ（SET_VAR と同じ）。
- [ ] **Step 4: Run and see them pass**
- [ ] **Step 5: Build and commit** — `feat(ai): run AI_CHOOSE and AI_EXTRACT through Io.AiChat`

### Task 4: 写す・起動する・止める（`gui/AiServer.ps1`）と RunUi への接続

**Files:**
- Create: `gui/AiServer.ps1`
- Modify: `gui/RunUi.ps1`（Io に `AiChat`・`AiPick` を足し、`EndRun` で `Stop-FujiAiServer`）
- Modify: `gui/MainForm.ps1`（起動時に `Clear-FujiAiLeftover`、閉じるときに `Stop-FujiAiServer`）
- Modify: `src/Schedule.ps1`（`Read-FujiSetting` が `ai` を読む。今の `alerts` と同じ書き方。中身は `@{ folder = '<共有の AI フォルダ>' }`）
- Create: `tests/ai/Invoke-FujiAiVmTest.ps1`（VM で本物を使う確認。モデルは `C:\llm\qwen3.5-2b-q4_k_m.gguf`、llama は `C:\llm\bin-x64`、共有の代わりに一時フォルダ）

**Interfaces:**
- Consumes: `Read-FujiAiManifest`・`Test-FujiAiCopyNeeded`（Task 1）
- Produces:
  - `Get-FujiAiLocalDir` → `Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'fujikyun\ai'`
  - `Copy-FujiAiLocal -SharedDir <string> -Progress <scriptblock {param($Done,$Total)}> -Cancel <scriptblock -> bool>` → `'copied' | 'canceled'`。1MB ずつ `*.part` に写し、終わったら SHA-256 を `ai.json` と照らす。合えば名前を変え、最後に `ai.json` を写す。合わなければ `*.part` を消して throw。始める前に C: の空きを確かめ、2GB 未満なら throw。
  - `Start-FujiAiServer -LocalDir <string> -LogDir <string>` → `@{ Process; Port }`。空きメモリが 1GB 未満なら throw。ポートは `System.Net.Sockets.TcpListener` を 127.0.0.1:0 で開いて受け取る。stderr は `llama-server_YYYY-MM-DD.log` に出す（古いものは `Initialize-FujiLogFile` が消す対象に入れる。消す対象を名前で決めているなら、この名前を足し、log file の節にテストを1つ足す）。`llama-server.pid` を書く。`/health` を最大60秒待つ。
  - `Invoke-FujiAiChat -Server <hashtable> -Body <hashtable>` → 応答。`Invoke-WebRequest -TimeoutSec 60`、UTF-8 で送る（`Invoke-LlmBench2.ps1` と同じ）。
  - `Stop-FujiAiServer`（何度呼んでもよい）・`Clear-FujiAiLeftover -LogDir`（pid のプロセス名が `llama-server` のときだけ止める）
  - `Resolve-FujiAiReady -Settings -Ui` → 使える写しのフォルダ。共有の置き場所が未設定なら、`Ui` でフォルダを選ばせて設定を保存する。共有につながらないが写しがある場合は、写しを返してログに `ai.sharedOffline` を出す（Review Focus 3）。写す必要があれば、Task 5 の窓で写す。
  - RunUi の `AiChat` は、初めて呼ばれたときに `Resolve-FujiAiReady` と `Start-FujiAiServer` を行い、2回目からは同じサーバーを使う。

- [ ] **Step 1: Write the VM test** `tests/ai/Invoke-FujiAiVmTest.ps1`（`src` と `gui/AiServer.ps1` を dot-source し、次を確かめて `OK`/`NG` を1行ずつ出す）
  - 共有の代わりの一時フォルダ（`llama-x64` は `C:\llm\bin-x64` を写したもの、モデル、`ai.json`）から写すと `'copied'` になり、写しの SHA-256 が合う。
  - もう一度呼ぶと `Test-FujiAiCopyNeeded` が `'none'` になる。`aiVersion` を上げると `'copy'` になる。
  - 写している途中に `Cancel` が真を返すと `'canceled'` になり、`*.part` が残らない。
  - 起動して `/health` が200を返し、`AI_CHOOSE` の Body（Task 1）で選択肢の確率が返る。止めるとプロセスが無くなり、`llama-server.pid` も無くなる。
  - pid ファイルを残したままプロセスを起動しておき、`Clear-FujiAiLeftover` で止まる。
  - 共有の置き場所を無いパスにしても、写しがあれば `Resolve-FujiAiReady` が写しを返す。
  - 空きメモリの下限を 1TB にすると（テスト用の引数 `-MinFreeMb`）、起動せず throw する。
- [ ] **Step 2: Run on the VM and see it fail** — `ssh win11vm 'powershell -NoProfile -ExecutionPolicy Bypass -File \\Mac\Home\Developer\RPAhta\RPA\tests\ai\Invoke-FujiAiVmTest.ps1'` を実行する。関数が無いので NG になる。
- [ ] **Step 3: Implement `gui/AiServer.ps1` and connect RunUi / MainForm / settings**
- [ ] **Step 4: Run the VM test and `Invoke-FujiTest.ps1`; all OK, failures 0**
- [ ] **Step 5: Build and commit** — `feat(ai): copy to LOCALAPPDATA, start and stop llama-server`

### Task 5: 画面（設定の AI の欄・写す窓・人に選んでもらう窓・環境チェック）

**Files:**
- Create: `gui/Ai.ps1`
- Modify: `gui/MainForm.ps1`（メニューに「AI の設定」）、`gui/Diagnostics.ps1`（`Get-FujiDiagnostic` に AI の行）、`gui/RunUi.ps1`（`AiPick` に `Show-FujiRunAiPick`）、`fujikyun_ja.json`

**Interfaces:**
- Consumes: Task 4 の関数。
- Produces:
  - `Show-FujiAiSettingDialog -Settings -Directory`。置き場所（フォルダを選ぶ）と状態（共有の版・写しの版・SHA-256）を出し、ボタンは「今すぐ写す」「写しを消す」「試しに聞く」。試しに聞くは、起動・選ぶ1問・停止を通して秒数を出す。SHA-256 もここで照らす。
  - `Show-FujiAiCopyDialog -SharedDir` → `'copied' | 'canceled'`。進み具合（MB・%）と「やめる」を出す。
  - `Show-FujiRunAiPick -Caption -Message -Options -Initial`。問い、読ませた文の先頭500字、選択肢と各確率を出し、「これにする」「止める」で答える。
  - 環境チェックの AI の行: 置き場所、写しの版、空きメモリ、AVX2（`IsProcessorFeaturePresent(40)`）、C: の空き。
- [ ] **Step 1: Add a VM screen script** `tests/ai/Show-FujiAiScreens.ps1`（3つの窓を順に開いて、`vmrun.sh --shot` で撮れるように数秒ずつ出す）
- [ ] **Step 2: Implement `gui/Ai.ps1` and the hooks**
- [ ] **Step 3: Check on the VM** — `~/Developer/RPAhta/vm-setup/vmrun.sh tests/ai/Show-FujiAiScreens.ps1` を実行し、`vmrun.sh --shot` で撮る。文字が切れない・重ならないこと（表示倍率150%でも）を目で確かめる。`Invoke-FujiTest.ps1` も failures 0 で通す。
- [ ] **Step 4: Build and commit** — `feat(ai): AI settings, copy and pick windows, diagnostics row`

### Task 6: 共有ドライブに置く道具（`tools/ai-setup/`）

**Files:**
- Create: `tools/ai-setup/ai-setup.bat`・`tools/ai-setup/ai-setup.ps1`
- 部品: ブランチ `ai-parts` に置き、master には入れない。中身は `tools/ai-setup/parts/` に、llama の部品（`origin/llm-pc-test` の `llama_x64_*.txt` と同じもの、zip の SHA-256 は `4e3766c32a517cdd66ea28f57c862d6b83582ba5d1354f9db585b34f7ad8cf62`）とモデルの部品 `qwen35_q4_01..19.txt`（`origin/llm-model-qwen35` と同じもの）。

**Interfaces:**
- Produces: `ai-setup.ps1 -Target <共有の AI フォルダ>`（引数が無ければフォルダを選ぶ窓を出す）。部品を1つずつ戻して SHA-256 を照らし（`llm-speed.ps1` の部品ごとの照らし方と同じ）、`llama-x64\`・`qwen35-q4.gguf` と `ai.json`（`aiVersion` 1、ファイルごとの size と sha256、serverArgs）を作る。合わない部品は `paste these again: …` で示す。

- [ ] **Step 1: Write `ai-setup.ps1` and run it on the VM** — 部品は Mac の `~/Developer/RPAhta/vm-setup/llm/qwen35-parts` と llama の部品を使い、出力先は `C:\llm\ai-share-test`。部品を1つ壊すと名前が出ること、全部そろえば `ai.json` ができ、Task 4 の `Copy-FujiAiLocal` がその共有フォルダから写せることを確かめる。
- [ ] **Step 2: Commit the tool on the feature branch, and push the parts branch `ai-parts` separately**（部品は約1.8GB。2回に分けて push する）

### Task 7: テンプレート・説明書・版

**Files:**
- Modify: `fujikyun_templates.json`（テンプレート2つ）、`build/template_doc_ja.json`（あれば）、`docs/src/manual.md`・`faq.md`・`changes.md`・`tutorial.md`・`templates.md`・`setup.md`、`fujikyun_manual.html`（今の作り方で作り直す）、`src/Version.ps1`
- Test: `tests/Invoke-FujiTest.ps1`（「commands and templates」の節が新しいテンプレートも読む）

- [ ] **Step 1: Add the templates**
  - 「思わぬ画面が出たら AI に判断させる」: `READ_TEXT`（前面のウィンドウ）→ `AI_CHOOSE`（画面の判断の6つの選択肢。文は `decide.json` の judge と同じ意味のもの、`low` は `ASK`）→ `IF` で値ごとに分ける。
  - 「問い合わせを担当ごとに仕分ける」: CSV の行ごとに `AI_CHOOSE`（`cases.json` の6つの担当）→ `RECORD`。
- [ ] **Step 2: Docs**
  - setup: `ai-setup.bat` で共有ドライブに置く手順、各自が置き場所を選ぶ手順、写すのに約1分半かかること。
  - manual: 2つのコマンドの欄、確認用の一覧の場所と中身（読ませた文の先頭100字が残ること、消す期間）。
  - tutorial: 「AIに選んでもらう」の1章。
  - faq: 「AI が `不明` ばかり返す」「起動しない（メモリ・置き場所）」「写すのに時間がかかる」。
  - changes: 新しい版の項。
  - 問い合わせを勧める文は書かない（memory: docs-no-it-contact）。
- [ ] **Step 3: Versions** — `textVersion` 13・`commandsVersion` 3 を確かめ（Task 2）、`src/Version.ps1` の版を上げる。
- [ ] **Step 4: Full check** — `Invoke-FujiTest.ps1` が failures 0、`tests/ai/Invoke-FujiAiVmTest.ps1` が全部 OK。VM で、テンプレート2つを本物の llama-server で最後まで流す（`vmrun.sh` で fujikyun を起動し、テンプレートのマクロを再生して画面を撮る）。
- [ ] **Step 5: Build, commit, push, PR, merge**（`gh pr merge --merge`）
