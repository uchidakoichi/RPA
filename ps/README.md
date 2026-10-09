# ふじキュン♡のRPAマクロビルダー PowerShell版（移植中）

HTA 版（`fujikyun_rpa_builder.hta`）を、Windows PowerShell 5.1 ＋ Windows Forms へ移植しています。完成するまで HTA 版はそのまま使えます。

## 方針

| 項目 | 内容 |
| --- | --- |
| 動かすもの | Windows に最初から入っている **Windows PowerShell 5.1**（インストール不要・exe なし） |
| 起動 | `.bat` をダブルクリック → PowerShell 5.1 を STA モードで起動 |
| 画面 | Windows Forms |
| マクロのデータ | HTA 版と同じ `fujikyun_macros.json`（データ版27）をそのまま使う |
| 廃止する機能 | SMTP によるメール送信（Outlook と mailto は残す） |

### 文字コードの決まり

Windows PowerShell 5.1 は、BOM のない .ps1 を ANSI（Shift_JIS）として読みます（[about_Character_Encoding](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_character_encoding?view=powershell-5.1)）。メモ帳に貼り付けて保存すると BOM なしの UTF-8 になるので、.ps1 の中に日本語があると文字化けして動きません。

- **.ps1 と .bat は英数字（ASCII）だけ** で書きます。
- 画面の文字・メッセージなどの日本語は **UTF-8 の JSON** に分け、文字コードを指定して読み込みます。Shift_JIS で保存された JSON は読み込み時に検出します。

## 事前チェック（`check/`）

PowerShell 版が動く端末かを調べるツールです。端末の設定は変えません（クリップボードの文字は元に戻し、キーはこのツール自身の入力欄にだけ送ります）。

1. 次の3つのファイルを、同じフォルダに置きます（GitHub の RAW 表示をメモ帳に貼り付けて保存する場合は、ファイル名をこのとおりにします）。
   - `fujikyun_check.bat`
   - `fujikyun_check.ps1`
   - `fujikyun_check_strings.json`（保存するときの文字コードは **UTF-8**）
2. `fujikyun_check.bat` をダブルクリックします。
3. 結果の画面が出ます。同じ内容が `fujikyun_check_result.txt` に保存されます。

`.bat` は `-ExecutionPolicy Bypass` で起動します。この指定はその1回の起動にだけ効き、端末の設定は変えません。なお、グループポリシーで実行ポリシーが決められている端末では、ポリシーの方が優先されます。

## フォルダ構成（開発中）

| パス | 内容 |
| --- | --- |
| `check/` | 事前チェックツール |
| `src/*.ps1` | 本体のソース（英数字だけ）。いまは画面のない中核部分 |
| `fujikyun_ja.json` | 日本語リソース（メッセージ・表示名の文言） |
| `fujikyun_commands.json` | コマンド定義（表示名・説明・入力欄・パレット・キー一覧など）。HTA 版から一度だけ書き出し、以後はこのファイルが元データ |
| `fujikyun_templates.json` | 内蔵テンプレート。HTA 版がテンプレートの元データのあいだは `node tools/export_ps_templates.js` で書き出す（直接編集しない） |
| `tests/Invoke-FujiTest.ps1` | 中核部分のテスト。Windows では `tests\run_tests.bat`、Mac などでは `pwsh -File ps/tests/Invoke-FujiTest.ps1` |
| `tests/golden.json` | HTA 版の関数が同じ入力に返す値（`node tools/make_ps_golden.js`）。**HTA 版が正しいとは限らない** ので、値は確認済みのもので、HTA 版が正しく出せないものは正しい値を `PS_EXPECT` に書いて PowerShell 版のテストに使う |

### src の中身

| ファイル | 内容 |
| --- | --- |
| `Text.ps1` | 日本語リソースの読み込み（UTF-8 を厳密に読む） |
| `Json.ps1` | JSON の読み書き（5.1 と 7 で同じ結果。HTA 版と同じ書式で書く） |
| `Files.ps1` | 文字コードの判定（CSV）、壊れにくい保存 |
| `Csv.ps1` | CSV の読み書き |
| `Values.ps1` | 数値（decimal で正確に）・和暦（明治〜令和）・日付・計算・文字加工・条件 |
| `Placeholders.ps1` | 差し込み |
| `Commands.ps1` | コマンドの設定の読み書き・入力チェック・自動ラベル |
| `Data.ps1` | マクロファイルの整形、ブロック構造（グループ・繰り返しなど） |

### Windows（PowerShell 5.1）でテストする

次の14ファイルを、同じフォルダ構成で置いて `tests\run_tests.bat` を実行します（JSON は UTF-8 で保存）。

```
ps\fujikyun_ja.json
ps\fujikyun_commands.json
ps\fujikyun_templates.json
ps\src\Text.ps1  Json.ps1  Files.ps1  Csv.ps1  Values.ps1  Placeholders.ps1  Commands.ps1  Data.ps1
ps\tests\Invoke-FujiTest.ps1  golden.json  run_tests.bat
```
