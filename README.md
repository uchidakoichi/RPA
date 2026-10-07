# 重要
fujikyun_rpa_builder.hta は、自治体セキュリティクラウドのダウンロード機能を使用するとコードが壊れます。
必ずRaw表示したコードをメモ帳などへコピペしてください。

# ふじキュン♡のRPAマクロビルダー

Windows のオフライン環境で動く、1ファイルだけの RPA（パソコン作業の自動化）ツールです。CSV のデータを、Excel・Word・文書起案システム・財務会計システム・グループウェア・福祉・税・住基システムなどへ自動で入力します。

- インストール不要: `fujikyun_rpa_builder.hta` をダブルクリックするだけ
- 外部ソフト不要: Windows 標準の機能（HTA・WScript・PowerShell）だけで動作
- 初心者向け: 67種類のテンプレートと見本CSVを内蔵（Excel・Word・文書起案・財務会計・グループウェア・福祉・国保／介護保険／税務／住民情報／住民基本台帳／収納管理／滞納管理・庶務事務・変数／繰り返し／分岐・文字認識／メール など）

## ダウンロードと起動

1. `fujikyun_rpa_builder.hta` を、ローカルフォルダに置きます。
   自治体セキュリティクラウドのダウンロード機能では**ダウンロードしないでください**。GitHubでRAW表示してコードを丸ごとメモ帳アプリなどに貼り付け後、`fujikyun_rpa_builder.hta`など拡張子をhtaに変更してください。
2. （オプション）ファイルを右クリック →［プロパティ］→ **［許可する］**（ブロックの解除）にチェック →［OK］。
3. ダブルクリックで起動し、**［🩺 環境チェック］** で使える機能を確認します。
4. **［📚 テンプレート］** からお手本マクロを作って、動かしてみましょう。

## 主な機能

コマンドは［追加］の行に7つの分類で並んでいます（全コマンドの説明は [操作マニュアル 5章](docs/src/manual.md#5-コマンド一覧)）。

| 分類 | コマンド |
| --- | --- |
| 入力 | キー送信（KEY）・文字列貼付（TEXT）・CSV列を貼付（CSV）・コピーして変数へ（COPY） |
| 待つ・確かめる | 待機（WAIT）・ウィンドウ出現待ち（WAIT_FOR）・ウィンドウ検知（WINDOW_CHECK）・確認ポイント（CONFIRM） |
| クリック・読み取り | 名前で（CLICK_NAME）・文字で（CLICK_TEXT／OCR）・画像で（CLICK_IMG）・座標で（CLICK_POS）クリック、文字を読み取る（READ_TEXT／OCR） |
| アプリ・画面 | ウィンドウ切替（SWITCH）・アプリ起動（RUN）・画面を撮影して保存（SCREENSHOT）・メール（MAIL：Outlook／SMTP／mailto） |
| 流れ | 繰り返し（LOOP_START）・抜ける／次へ（BREAK／CONTINUE）・もし〜なら／そうでなければ（IF_START／ELSE）・エラー時の処理（TRY_START）・マクロの呼び出し／戻る（CALL_MACRO／RETURN） |
| 変数・データ | 変数に値を入れる・計算（SET_VAR）・文字の加工14種類（STR_OP）・実行中の入力（ASK）・結果に記録（RECORD）・Excelのセルを画面を開かずに読み書き（EXCEL_READ／EXCEL_WRITE） |
| 整理 | グループ（最初の1行だけ／最後の1行だけ も指定可）・コメント |

そのほか:

- 差し込み: `{{氏名}}` `{{1}}` `{{$変数}}` `{{ROW+1}}` `{{WAREKI}}` `{{TODAY}}` など
- 画面操作の記録: ふつうに操作するだけで、クリック・キー・文字入力・ウィンドウ切替をコマンドに変換
- スケジュール: 決まった時刻（毎日・平日・指定日）に自動で実行。Windows のタスクスケジューラにも登録できる
- 変数ウォッチ: 実行中の変数・繰り返しの回数・この行のCSVの値をリアルタイムで表示
- 安全装置: Esc で停止（ふじキュンの画面で押す／どの画面でも約1秒長押し）、ウィンドウ見失い時の自動停止、アラーム、確認ポイント、1件テスト
- 結果の記録: 実行結果CSV、エラー行CSV（直して再実行）、画面の証跡保存
- 編集: ドラッグ＆ドロップ、ブロックの折りたたみ、無効化、元に戻す（30件）、自動保存、マクロの書出・取込

## ドキュメントと見本CSV（zip でまとめてダウンロード）

- **[dist/fujikyun_docs_samples.zip](dist/fujikyun_docs_samples.zip)** に、ブラウザで読めるマニュアル（HTML）と見本CSVをまとめています。
  展開して `docs\index.html` をダブルクリックすると、ネット接続なしでブラウザで読めます。
- GitHub 上で読む場合: [チュートリアル](docs/src/tutorial.md)・[テンプレート解説](docs/src/templates.md)・[操作マニュアル](docs/src/manual.md)・[Q&A](docs/src/faq.md)

## フォルダ構成

| パス | 内容 |
| --- | --- |
| `fujikyun_rpa_builder.hta` | ツール本体（これ1つで動きます） |
| `samples/` | テンプレート用の見本CSV（すべて架空のデータ） |
| `docs/*.html` | ブラウザで読むドキュメント（`docs/src/*.md` から生成） |
| `docs/src/` | ドキュメントの原稿（Markdown） |
| `dist/fujikyun_docs_samples.zip` | ドキュメント（HTML）と見本CSVのまとめ |
| `tools/build_templates.js` | 保守用: HTA 内のテンプレートから `samples/` と `docs/src/templates.md` を再生成（Node.js が必要。利用者には不要） |
| `tools/build_docs.js` | 保守用: `docs/src/*.md` から `docs/*.html` と zip を生成 |
| `tools/test_runner.js` | 保守用: 実行ループ・CSV・保存・変数・繰り返し・分岐などのテスト（Windows を模擬して動かす） |
| `tools/check_templates.js` | 保守用: HTA のスクリプト（ES5）と全テンプレートの検証（コマンドの値・ブロックの対応・差し込み・CSV） |
| `tools/hta_context.js` | 保守用: 上の各ツールが HTA のスクリプトを読み込むための共通部品 |
| `RPA.md` | 要件定義書 |

## ライセンス

[MIT License](LICENSE)。自由に使用・改変・再配布できます（著作権表示とライセンス文を残してください）。本ツールは無保証です。業務システムへ自動入力する前に、必ず少ない件数で動作を確認してください。
