# 準備とHTA版からの移行

ふじキュン♡のRPAマクロビルダーは、**PowerShell 版** が本体です。以前の HTA 版（`fujikyun_rpa_builder.hta`）は開発を終了しました。どちらも同じマクロ・同じコマンド・同じテンプレートで動き、HTA 版のマクロのファイル（`fujikyun_macros.json`）もそのまま使えます。

## HTA 版とくらべると

| | HTA 版 | PowerShell 版 |
| --- | --- | --- |
| 動かすもの | mshta.exe（古い Internet Explorer の部品） | Windows に最初から入っている **Windows PowerShell 5.1** |
| 画面 | HTML（Trident） | Windows Forms |
| ファイル | 1つ | 5つ |
| メール | Outlook・SMTP・mailto | Outlook・mailto（**SMTP は廃止**） |
| これから | **開発終了**（最終版はタグ `hta-final`） | 機能追加・不具合修正はこちらだけ |

HTA（mshta.exe）は、Microsoft がすでに開発を終えた Internet Explorer の部品で動いていて、組織のセキュリティ方針で止められることが増えています。PowerShell 版は、その古い部品や VBScript 流の書き方を使わずに作り直したものです。HTA 版の開発は終了しました。これから使い始める場合も、いま HTA 版を使っている場合も、PowerShell 版を使ってください。

## 準備

1. 次の5つのファイルを、**同じフォルダ** に置きます。
   - `fujikyun.bat`
   - `fujikyun.ps1`
   - `fujikyun_ja.json`
   - `fujikyun_commands.json`
   - `fujikyun_templates.json`

   GitHub の RAW 表示をメモ帳に貼り付けて保存する場合は、ファイル名をこのとおりにし、**JSON は文字コード「UTF-8」で保存** します（`ps` フォルダの中にあります）。
2. `fujikyun.bat` をダブルクリックします。
3. **［🩺 環境チェック］** で、この端末で使える機能を確認します。
4. **［📚 テンプレート］** からお手本マクロを作って、動かしてみましょう。

マクロのファイル（`fujikyun_macros.json`）・見本CSV（`samples`）・参照画像（`rpa_images`）・証跡（`evidence`）・書き出したマクロ（`macro_export`）・予定（`fujikyun_settings.json`）は、このフォルダに作られます。HTA 版で作ったマクロを使うときは、HTA 版の `fujikyun_macros.json` をこのフォルダにコピーします。

### 起動のしくみ

`fujikyun.bat` は、PowerShell 5.1 を STA モード（Windows Forms に必要）・コンソールなしで起動します。`-ExecutionPolicy Bypass` の指定はその1回の起動にだけ効き、端末の設定は変えません。グループポリシーで実行ポリシーが決められている端末では、ポリシーの方が優先されます。

## HTA 版から移るとき

1. PowerShell 版の5つのファイルを置いたフォルダに、HTA 版のフォルダから次をコピーします（あるものだけ）。
   - `fujikyun_macros.json`（マクロ）・`fujikyun_settings.json`（予定）
   - `rpa_images`（画像でクリックの画像）・`samples`（見本CSV）
2. `fujikyun.bat` で起動し、マクロが見えることを確かめます。
3. **［⏰ 予定］で［🗓 Windowsに登録］済みの予定があれば**、その予定で［登録を解除］→［🗓 Windowsに登録］をし直します。HTA 版で登録したタスクは HTA 版を起動するので、そのままでは HTA 版が動きます（［登録を解除］で HTA 版のタスクも消えます）。
4. メールのブロックで送り方を **SMTP** にしていたものは、編集して Outlook かメールアプリ（mailto）に変えます（そのままだと、その行で止まります）。
5. 動作を確かめたら、HTA 版のフォルダは使わないようにします。

## HTA 版との違い

使い方は [操作マニュアル](manual.md) のとおりで、HTA 版と同じです。違うのは次の点です。

- **メールの SMTP 送信はありません。** Outlook か、メールアプリ（mailto）を使います。テンプレートのメールも Outlook／mailto で動きます。
- **実行の止め方**：Esc か ⏹。ほかの画面が前にあるときは **Esc を1秒ほど長押し** します。
- **画像でクリック・⏺ 記録** は、最初に使うときだけ準備（小さな C# のコンパイル）に数秒かかります。
- 名前・画像・文字（OCR）での検索は別のスレッドで動くので、検索中も画面が固まらず、停止できます。
- **⏰ 予定の Windows 登録** は、Windows のタスク スケジューラに「`fujikyun.ps1` を `-AutoRun <予定のID>` で起動する」タスクを作ります。タスクの名前は `FujikyunRPA_PS_` で始まります。
- 実行結果CSV・エラー行CSVで、ツールが付け足す列（記録した値・備考・エラー内容）が `=` などで始まるときは、Excel で数式として動かないよう先頭に `'` を付けます（元データの列はそのまま）。
- EXCEL_WRITE で、差し込みで入った値が `=` などで始まるときは文字として書きます。ステップに直接書いた数式（`=SUM(A1:A3)` など）は数式のままです。Excel のブックはマクロを無効にして開きます。

## 困ったとき

| こんなとき | どうする |
| --- | --- |
| ボタンなどが `gui.schedule` のような英字の名前で表示される | `fujikyun_ja.json` が古いままです。`fujikyun.ps1` と同じ版の `fujikyun_ja.json` に置き換えてください（起動時にもお知らせが出ます） |
| 起動すると「起動できなかったキュン」と出る | メッセージの内容を確認します。JSON を UTF-8 以外（Shift_JIS など）で保存すると読み込めません |
| 画面が出ない・すぐ消える | ［🩺 環境チェック］を開けない場合は、`fujikyun.bat` を右クリック→［編集］で中身を確認し、PowerShell が組織の設定で止められていないか情報担当に確認します |
| 起動に時間がかかる | ログの「⏱ 起動にかかった時間」の内訳を見ます |
| 予定が動かない | PC がスリープ・画面ロック中でないか、ログインしたままか、［⏰ 予定］で「✅ 有効」になっているかを確認します |

そのほかは [Q&A](faq.md) も参考にしてください（HTA 版向けの項目もあります）。

## 保守する人向け

ソースは `ps` フォルダにあり、`.ps1` は英数字（ASCII）だけで書いています。Windows PowerShell 5.1 は BOM のない `.ps1` を Shift_JIS として読むためで、日本語の文言はすべて UTF-8 の `fujikyun_ja.json` に分けています。

- `fujikyun.ps1` は `ps/build/Build-FujiBundle.ps1` が `ps/build/Main.ps1`・`ps/src`・`ps/gui` から作る1ファイルです（直接編集しない）。
- テスト：`ps/tests/Invoke-FujiTest.ps1`（Windows では `ps\tests\run_tests.bat`）。画面に依存しない部分（編集・実行の決まり・CSV・計算・和暦・予定・記録の変換・画像照合・OCR 結果の処理など）を、偽の画面操作で確かめます。
- 詳しくは [`ps/README.md`](https://github.com/uchidakoichi/RPA/blob/master/ps/README.md) を見てください。
