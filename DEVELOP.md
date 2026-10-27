# ふじキュン♡のおしごとロボット（保守する人向け）

Windows PowerShell 5.1 ＋ Windows Forms で動く本体です。使う人向けの説明は [docs/src/setup.md](../docs/src/setup.md) にあります。

## 方針

| 項目 | 内容 |
| --- | --- |
| 動かすもの | Windows に最初から入っている **Windows PowerShell 5.1**（インストール不要・exe なし） |
| 起動 | `.bat` をダブルクリック → PowerShell 5.1 を STA モードで起動 |
| 画面 | Windows Forms |
| マクロのデータ | `fujikyun_macros.json`（データ版27） |
| メール | Outlook と mailto（SMTP は使わない） |

### 文字コードの決まり

Windows PowerShell 5.1 は、BOM のない .ps1 を ANSI（Shift_JIS）として読みます（[about_Character_Encoding](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_character_encoding?view=powershell-5.1)）。メモ帳に貼り付けて保存すると BOM なしの UTF-8 になるので、.ps1 の中に日本語があると文字化けして動きません。

- **.ps1 と .bat は英数字（ASCII）だけ** で書きます。
- 画面の文字・メッセージなどの日本語は **UTF-8 の JSON** に分け、文字コードを指定して読み込みます。Shift_JIS で保存された JSON は読み込み時に検出します。

## 事前チェック（`check/`）

ふじキュンが動く端末かを調べるツールです。端末の設定は変えません（クリップボードの文字は元に戻し、キーはこのツール自身の入力欄にだけ送ります）。

1. 次の3つのファイルを、同じフォルダに置きます（GitHub の RAW 表示をメモ帳に貼り付けて保存する場合は、ファイル名をこのとおりにします）。
   - `fujikyun_check.bat`
   - `fujikyun_check.ps1`
   - `fujikyun_check_strings.json`（保存するときの文字コードは **UTF-8**）
2. `fujikyun_check.bat` をダブルクリックします。
3. 結果の画面が出ます。同じ内容が `fujikyun_check_result.txt` に保存されます。

`.bat` は `-ExecutionPolicy Bypass` で起動します。この指定はその1回の起動にだけ効き、端末の設定は変えません。なお、グループポリシーで実行ポリシーが決められている端末では、ポリシーの方が優先されます。

## 試す

作成・編集・保存・▶ 実行・⏺ 記録・⏰ 予定・🩺 環境チェック が使えます。実行中は Esc（ほかの画面にいるときは Esc 長押し）か ⏹ で止まります。
「画像でクリック」は最初に使うときだけ、画像照合の部品を準備（コンパイル）するので数秒かかります。名前・画像・文字（OCR）での検索は別のスレッドで動くので、その間も停止できます。

1. 次の5つのファイルを、**同じフォルダ** に置きます（RAW 表示をメモ帳に貼り付けて保存する場合は、JSON を **UTF-8** で保存します）。
   - `fujikyun.bat`
   - `fujikyun.ps1`
   - `fujikyun_ja.json`
   - `fujikyun_commands.json`
   - `fujikyun_templates.json`
2. `fujikyun.bat` をダブルクリックします。

マクロのファイル（`fujikyun_macros.json`）や見本 CSV（`samples\`）、参照画像（`rpa_images\`）は、このフォルダに作られます。

## フォルダ構成

| パス | 内容 |
| --- | --- |
| `fujikyun.bat` | 起動用。PowerShell 5.1 を STA モード・コンソールなしで起動 |
| `fujikyun.ps1` | アプリ本体（1ファイル）。`build/Build-FujiBundle.ps1` が `build/Main.ps1`・`src`・`gui` から作る。**直接編集しない** |
| `build/Main.ps1` | 起動処理（`fujikyun.ps1` のもと） |
| `build/Build-FujiBundle.ps1` | 保守用: `fujikyun.ps1` を作り直す。`src`・`gui` を変えたら実行（テストが古いままを検出） |
| `check/` | 事前チェックツール |
| `src/*.ps1` | 画面のない中核部分（英数字だけ） |
| `gui/*.ps1` | Windows Forms の画面（英数字だけ） |
| `fujikyun_ja.json` | 日本語リソース（メッセージ・画面の文言） |
| `fujikyun_commands.json` | コマンド定義（表示名・説明・入力欄・パレット・キー一覧など） |
| `fujikyun_templates.json` | 内蔵テンプレート（元データ）。直したら `build/Build-FujiTemplateDoc.ps1` で `samples/*.csv` と `docs/src/templates.md` を作り直す（文言は `build/template_doc_ja.json`） |
| `tests/Invoke-FujiTest.ps1` | テスト。Windows では `tests\run_tests.bat`、Mac などでは `pwsh -File tests/Invoke-FujiTest.ps1`。画面のファイルは構文だけ確認 |
| `tests/golden.json` | テストの期待値（入力と正しい出力の組）。移植のときに元の実装から作り、確認済みの値だけを使う。正しい値が元の実装と違うものは `PS_EXPECT` に書く。今後はこのファイルを直接直す |
| `PSScriptAnalyzerSettings.psd1` | 保守用: 静的解析の設定（5.1 と 7 の構文互換を確認） |

### src の中身

| ファイル | 内容 |
| --- | --- |
| `Text.ps1` | 日本語リソースの読み込み（UTF-8 を厳密に読む） |
| `Version.ps1` | アプリのバージョン（出した日付 年.月.日）。タイトルバーと環境チェックに出る。変えた `fujikyun.ps1` を配るたびに上げ、`docs/src/changes.md`（更新履歴）にその版の変更を書く |
| `Log.ps1` | ログのファイル（`fujikyun_logs\fujikyun_log_日付.txt`）への書き込みと、30日より古いものの削除 |
| `Instance.ps1` | 同じフォルダで2つ開かないためのロック（フォルダごとの名前付きミューテックス） |
| `Json.ps1` | JSON の読み書き（5.1 と 7 で同じ結果。決まった書式で書く） |
| `Files.ps1` | 文字コードの判定（CSV）、壊れにくい保存、ファイルのコピー・移動・名前の変更（FILE_OP） |
| `Csv.ps1` | CSV の読み書き |
| `Values.ps1` | 数値（decimal で正確に）・和暦（明治〜令和）・日付・計算・文字加工・条件 |
| `Placeholders.ps1` | 差し込み |
| `Commands.ps1` | コマンドの設定の読み書き・入力チェック・自動ラベル |
| `Data.ps1` | マクロファイルの整形、ブロック構造（グループ・繰り返しなど） |
| `Runner.ps1` | 実行の決まり（行の進め方・グループ・繰り返し・もし〜なら・エラー時の処理・呼び出し・各コマンド・実行結果とエラー行のCSV）。画面や Windows への操作は Io（関数の表）を通すので、偽の Io でテストできる |
| `Schedule.ps1` | 予定の決まり（いつ実行するか・次の予定、トリガー: キーの書き方・新しく届いたファイル・開いたウィンドウ）と、端末ごとの設定ファイル `fujikyun_settings.json` |
| `Recording.ps1` | 記録した操作をコマンドに変える決まり |
| `Vision.ps1` | 画像照合（初回だけコンパイルする小さな C#）と、OCR の結果から文字を探す処理 |
| `Native.ps1` | Windows API の宣言（C# のコンパイルなし）と、ウィンドウ名の照合 |
| `Credential.ps1` | Windows の資格情報マネージャー（汎用資格情報）の読み書き。CredReadW などを Native.ps1 と同じ方法で宣言し、CREDENTIALW をオフセットで読み書きする |
| `Docs.ps1` | アプリから開く説明書（`fujikyun_manual.html`、全ページで1ファイル）の場所探しと、ページと見出し（#page-…/…）へ飛ぶための転送ページ。コマンドごとの説明の位置は `fujikyun_commands.json` の `doc` |
| `Editor.ps1` | 編集の操作（起動時の読み込み・一時ファイル・保存・元に戻す・追加・移動・削除・複製・無効化・折りたたみ・取込・書出・テンプレート・CSV の読み込み）。画面から呼ぶだけで、テストできる |

### gui の中身

| ファイル | 内容 |
| --- | --- |
| `Common.ps1` | フォント・色・ログ・確認や入力の小さなダイアログ |
| `MainForm.ps1` | メイン画面（マクロ・CSV・パレット・ステップ一覧・ログ、キー操作、ドラッグでの並べ替え） |
| `Vision.ps1` | 画像でクリック・文字認識（OCR）・名前でクリック（UI Automation）。重い処理は別の runspace で動かし、クリックは元のスレッドで行う |
| `Uia.ps1` | 欄に入力・欄の値を読む・表を読む（UI Automation。欄は名前・ID・すぐ左か上の見出しで探す）、［🎯 部品を指す］［🔍 見つかるか試す］、部品を囲む赤い枠 |
| `Credential.ps1` | SECRET の［🔑 登録・変更］ダイアログ（パスワードは画面・ログに出さない） |
| `Docs.ps1` | ［📖 説明書］メニュー、F1、各ダイアログの［📖 説明］ボタン |
| `RunUi.ps1` | 実行ボタンなどの部品と、実行の Io の Windows 版（ウィンドウの前面化・キー送信・クリップボード・クリック・撮影・Excel・Outlook） |
| `Schedule.ps1` | ⏰ 予定の一覧・追加、開いている間の時刻確認とトリガー（キー・ファイル・ウィンドウ）の見張り、Windows のタスク登録（ScheduledTasks モジュール）、タスクからの起動（`-AutoRun`） |
| `Recorder.ps1` | ⏺ 記録（初回だけコンパイルする C# が、別の runspace でキー・マウス・前面のウィンドウを読む。この画面の操作は記録しない） |
| `Diagnostics.ps1` | 🩺 環境チェック |
| `StepDialog.ps1` | ステップ編集ダイアログ（`fujikyun_commands.json` の入力欄から組み立てる。マウス位置・範囲・参照画像の取得） |

### Windows（PowerShell 5.1）でテストする

リポジトリをまるごと（`check`・`docs`・`dist` を除く）同じ構成で置いて、`tests\run_tests.bat` を実行します（JSON は UTF-8 で保存）。
