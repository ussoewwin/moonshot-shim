# Cursor × Kimi K2.6 — Tailscale Funnel (固定 URL) 完全ガイド

Cursor IDE から Moonshot の `kimi-k2.6` (Thinking モデル) を **ツール呼び出し付き** で使えるようにするため、**Tailscale Funnel** を使って固定 URL で公開する方法の完全ガイド。

作成日: 2026-04-26
作業フォルダ: `<repo-path>\`

姉妹編:
- `CURSOR_KIMI_K26_FIX.md` — Cloudflare Tunnel (quick tunnel, 従来方式) 版
- `KIMI_K26_CACHE_GUIDE.md` — プロンプトキャッシュ運用ガイド

---

## 目次

1. [症状](#1-症状)
2. [根本原因](#2-根本原因)
3. [影響範囲](#3-影響範囲)
4. [採用した対策の全体像](#4-採用した対策の全体像)
5. [構成図](#5-構成図)
6. [作成・配置したファイル一覧](#6-作成配置したファイル一覧)
7. [初回セットアップ手順](#7-初回セットアップ手順)
8. [自動化 — PC 再起動後も完全自動](#8-自動化--pc-再起動後も完全自動)
9. [Cursor 側の設定](#9-cursor-側の設定)
10. [動作検証](#10-動作検証)
11. [運用上の注意点](#11-運用上の注意点)
12. [既知の制限と将来の改善余地](#12-既知の制限と将来の改善余地)
13. [完全自動再現プレイブック (無人実行向け)](#13-完全自動再現プレイブック-無人実行向け)

---

## 1. 症状

Cursor の Settings → Models で Override OpenAI Base URL に Moonshot を指定し、`kimi-k2.6` を Custom Model として登録して Agent モードで会話すると、ツールが呼ばれた直後 (codebase_search / read_file / edit_file 等の戻りがある次のターン) で必ず以下のエラーが返り、エージェントが停止します。

```
API Error: 400 thinking is enabled but reasoning_content is missing
in assistant tool call message at index N
```

ツールを使わない単純な一問一答チャットでは発生せず、Agent モードでツールを 1 回でも呼ぶと次ターンで死にます。

## 2. 根本原因

Moonshot の Thinking 系モデル (Kimi K2.6 / DeepSeek-R1 等) は、OpenAI 標準スキーマに無い独自必須フィールド `reasoning_content` を会話履歴に要求します。

具体的には次の検証を Moonshot 側がリクエスト受信時に行います。

> `messages[]` 中の `role: "assistant"` メッセージに `tool_calls` が含まれている場合、同じメッセージに **非空文字列の `reasoning_content`** が必ず存在しなければならない。無い / 空文字列 / 別型なら 400。

OpenAI の Chat Completions API には `reasoning_content` フィールドが存在しないため、OpenAI 互換クライアント (Cursor / openclaude / Cline 等) は標準的にこのフィールドを履歴に保持・echo back しません。結果、

- ターン 1: ユーザー質問 → モデルがツール呼び出しを返す (この時 `reasoning_content` も付いて返る)
- クライアント: ツール実行 → 結果を含む新しい messages 配列を組み立てる → ここで `reasoning_content` が落ちる
- ターン 2: クライアントがその messages を Moonshot に送る → 400

という経路で必ず止まります。さらに、Moonshot の検証は **フィールドの存在チェックのみ** で中身の妥当性は検証していないという仕様の甘さがあり、これが今回の対策が成立する伏線になっております。

## 3. 影響範囲

| ツール | 対応状況 |
| --- | --- |
| Cursor IDE | クローズドソース。本体に手を入れられない。**本ドキュメントの対策が必要**。 |
| openclaude | GitHub HEAD で `preserveReasoningContent: true` 処理を実装済。npm 公開版にはまだ降りていない場合は別途対応 (姉妹編 `OPENCLAUDE_KIMI_K26_REASONING_PATCH.md` 参照)。 |
| Cline | 同症状。プラグイン側のアップデート待ち。 |
| Google Antigravity | 同症状。本体に手を入れられない。 |
| 自前 OpenAI 互換クライアント | 自分で `reasoning_content` の保持処理を書けば解決可能。 |

DeepSeek-R1 でも `reasoning_content` 必須仕様は同じなので、本ドキュメントの対策はそのまま転用可能 (転送先 URL を `https://api.deepseek.com/v1` に変えるだけ)。

## 4. 採用した対策の全体像

Cursor 本体に手を入れられない以上、**外側にプロキシを置いて欠落フィールドを注入する** 以外に道はありません。本構成では以下を採用しました。

1. **ローカル shim (Node.js)**
   - `127.0.0.1:8787` で listen
   - 受け取った messages 配列を走査し、欠落している `reasoning_content` に placeholder `" "` (半角スペース 1 文字) を注入してから Moonshot に転送
   - レスポンス (SSE 含む) は素通し
   - 認証ヘッダーは透過

2. **Tailscale Funnel (固定 URL)**
   - Cursor の Override OpenAI Base URL は **Cursor のクラウドサーバー経由で叩かれる** 設計のため、`127.0.0.1` 等の private IP は SSRF 防御で機械的にブロックされる (`ssrf_blocked: connection to private IP is blocked`)
   - そのため shim を外向けに公開する必要がある
   - **Tailscale Funnel** を使用し、`https://<machine>.<tail-XXXX>.ts.net/` の **固定 HTTPS URL** を払い出す
   - `--bg` フラグで設定を `tailscaled` Windows サービスに登録。ウィンドウを保持する必要なし
   - PC 再起動後も Tailscale サービスが自動的に Funnel を復元するため、URL は変わらない

placeholder が `" "` (半角スペース) で通る理由は §2 末尾の「Moonshot は中身を検証していない」性質によります。これが将来 Moonshot 側で厳格化されると本対策は機能しなくなり、本物の thinking テキストを保持・echo back する方式に切り替えが必要になります。

## 5. 構成図

```
┌─────────────────┐
│  Cursor (UI)    │  ローカル PC 上
│  Agent モード   │
│  kimi-k2.6 選択 │
└────────┬────────┘
         │ HTTPS (Override OpenAI Base URL の値)
         ▼
┌──────────────────────────┐
│  Cursor のクラウドサーバー │  リクエスト中継・ログ・課金等
│  (SSRF 防御で 127.0.0.1 不可) │
└────────┬─────────────────┘
         │ HTTPS to https://<your-funnel-domain>/v1/...
         ▼
┌──────────────────────────────┐
│  Tailscale Funnel edge       │  HTTPS 終端
│  (<your-funnel-domain>)│
└────────┬─────────────────────┘
         │ 暗号化トンネル (WireGuard over UDP)
         ▼
┌──────────────────────────────────────┐
│  tailscaled (Windows サービス)        │
│  → http://127.0.0.1:8787 に転送       │
└────────┬─────────────────────────────┘
         │ HTTP (loopback)
         ▼
┌──────────────────────────────────────────────┐
│  moonshot-shim (Node.js, server.js)          │
│  - messages を JSON parse                    │
│  - assistant && tool_calls && !rc            │
│      → reasoning_content = " " を注入        │
│  - Authorization 透過                        │
│  - Content-Length 再計算                     │
│  - SSE/通常レスポンスは素通し pipe            │
└────────┬─────────────────────────────────────┘
         │ HTTPS to https://api.moonshot.ai/v1/...
         ▼
┌─────────────────────────────────┐
│  Moonshot Kimi K2.6 API         │
│  (本来の宛先)                   │
└─────────────────────────────────┘
```

## 6. 作成・配置したファイル一覧

すべて `<repo-path>\` 配下。

| パス | 種別 | 役割 |
| --- | --- | --- |
| `package.json` | 設定 | 依存宣言 (`undici` のみ)。`type: module` で ESM。 |
| `package-lock.json` | 自動生成 | npm のロックファイル。 |
| `node_modules/` | 自動生成 | `npm install` で展開された依存。 |
| `server.js` | 本体 (約 200 行) | shim 本体。HTTP サーバー、patcher、proxy ロジックを内包。 |
| `README.md` | ドキュメント | 単体としての使い方。 |
| `test-echo.mjs` | テスト | ローカル echo サーバーを立てて patcher の動作を回帰検証する単体テスト。 |
| `CURSOR_KIMI_K26_FIX.md` | ドキュメント | Cloudflare Tunnel 方式の姉妹編。 |
| `CURSOR_KIMI_K26_TAILSCALE.md` | ドキュメント | **本ファイル**。Tailscale Funnel 方式の総括。 |
| `start-tailscale.cmd` | ランチャー | shim 起動 + tailscale funnel --bg 登録。一発実行型。 |
| `start-tailscale-hidden.vbs` | ランチャー | `start-tailscale.cmd` を完全に隠して (ウィンドウ 0 個) 起動する VBScript。 |

### 6.1 server.js の主要ロジック (要点抜粋)

```javascript
function patchMessagesForMoonshot(body) {
  if (!body || !Array.isArray(body.messages)) return 0;
  let patched = 0;
  for (const msg of body.messages) {
    if (!msg || msg.role !== 'assistant') continue;
    if (!Array.isArray(msg.tool_calls) || msg.tool_calls.length === 0) continue;
    const rc = msg.reasoning_content;
    if (typeof rc !== 'string' || rc.trim() === '') {
      msg.reasoning_content = ' ';   // ← Moonshot を満たす最小値
      patched++;
    }
  }
  return patched;
}
```

- 介入は **assistant かつ tool_calls 持ちかつ rc 空** の場合のみ
- 介入内容は **冪等で決定的** (同じ入力 → 同じ出力)
- 既に正しい `reasoning_content` がある場合は触らない (将来 Cursor 側が対応した場合の互換性)

### 6.2 環境変数

| 変数 | 既定値 | 用途 |
| --- | --- | --- |
| `SHIM_PORT` | `8787` | shim の listen ポート |
| `SHIM_HOST` | `127.0.0.1` | shim の listen アドレス |
| `SHIM_TARGET` | `https://api.moonshot.ai/v1` | 転送先。DeepSeek 等への転用も可能 |
| `SHIM_DEBUG` | (未設定) | `1` で詳細ログ |

## 7. 初回セットアップ手順

### 7.1 前提

- Tailscale アカウントを持っていること (無料プランで可)。https://login.tailscale.com/
- Tailscale Windows クライアントをインストール済みであること
- `<repo-path>\` に `server.js` と依存 (`npm install` 済み) が配置済みであること

### 7.2 手順

```powershell
# (1) Tailscale Funnel を有効化 (初回のみ、Tailscale 管理コンソールで)
#     https://login.tailscale.com/admin/settings/features
#     「Funnel」を ON にする

# (2) ローカルで shim が動くことを確認
cd <repo-path>
node server.js
# → listening on http://127.0.0.1:8787 と表示されたら Ctrl+C で停止

# (3) Tailscale Funnel を手動でテスト (成功すれば以後不要)
& "C:\Program Files\Tailscale\tailscale.exe" funnel --bg 8787
# → Available on the internet: https://<your-funnel-domain>/ と表示される

# (4) 公開 URL で healthz を確認
Invoke-RestMethod 'https://<your-funnel-domain>/healthz' -TimeoutSec 5
# → pid, uptimeSec, target, reasoningPatcher が返れば OK

# (5) テスト完了後、funnel を一旦リセット
& "C:\Program Files\Tailscale\tailscale.exe" funnel reset
```

## 8. 自動化 — PC 再起動後も完全自動

PC のログイン時に **shim の起動 + Tailscale Funnel の登録** を完全自動化します。手動操作、ウィンドウ保持は一切不要です。

### 8.1 自動化の全体像

| レイヤー | ファイル | 役割 |
| --- | --- | --- |
| スタートアップ登録 | `shell:startup` 内の `.lnk` ショートカット | Windows ログイン時に自動起動 |
| 非表示ランチャー | `start-tailscale-hidden.vbs` | VBScript で `start-tailscale.cmd` を hidden 実行 |
| 実処理 | `start-tailscale.cmd` | shim 起動 + funnel --bg 登録 + exit |

### 8.2 スタートアップに登録する方法

```powershell
$shell = New-Object -ComObject WScript.Shell
$startup = $shell.SpecialFolders("Startup")
$shortcut = $shell.CreateShortcut("$startup\Start-MoonshotShim-Tailscale-Hidden.lnk")
$shortcut.TargetPath = "<repo-path>\start-tailscale-hidden.vbs"
$shortcut.WorkingDirectory = "<repo-path>"
$shortcut.WindowStyle = 7  # Minimized
$shortcut.Save()
```

### 8.3 各ファイルの中身

**start-tailscale-hidden.vbs** (VBS 非表示ランチャー)

```vbs
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run Chr(34) & "<repo-path>\start-tailscale.cmd" & Chr(34), 0, False
Set WshShell = Nothing
```

- `Chr(34)` = ダブルクォート。パス内のスペース対策
- `0` = hidden ウィンドウ
- `False` = 完了を待たずに fire-and-forget

**start-tailscale.cmd** (実処理。一発実行型)

```batch
@echo off
setlocal
cd /d "%~dp0"

REM [1/3] shim 起動 (既に 8787 が LISTEN ならスキップ)
powershell -NoProfile -ExecutionPolicy Bypass -Command "if (Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue) { Write-Host '[1/3] shim already running' -ForegroundColor Yellow } else { Start-Process -FilePath 'node' -ArgumentList 'server.js' -WorkingDirectory '%~dp0' -WindowStyle Hidden; Write-Host '[1/3] shim launched' -ForegroundColor Green }"

REM [2/3] /healthz 応答待ち (最大 5 秒)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ok=$false; for($i=0;$i-lt10;$i++){Start-Sleep -Milliseconds 500; try{ $r=Invoke-RestMethod 'http://127.0.0.1:8787/healthz' -TimeoutSec 2; Write-Host ('[2/3] healthz OK pid={0}' -f $r.pid) -ForegroundColor Green; $ok=$true; break }catch{} }; if(-not $ok){ Write-Host '[2/3] healthz FAIL' -ForegroundColor Red; exit 1 }"
if errorlevel 1 exit /b 1

REM [3/3] tailscale funnel --bg 8787 (tailscaled 準備待ちを含め最大 60 秒)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ts='C:\Program Files\Tailscale\tailscale.exe'; $ok=$false; for($i=0;$i-lt30;$i++){ try{ & $ts funnel --bg 8787 2>$null | Out-Null; $r=Invoke-RestMethod 'https://<your-funnel-domain>/healthz' -TimeoutSec 4; Write-Host ('[3/3] public OK pid={0}' -f $r.pid) -ForegroundColor Green; $ok=$true; break }catch{ Start-Sleep -Seconds 2 } }; if(-not $ok){ Write-Host '[3/3] FAIL' -ForegroundColor Red; exit 1 }"

endlocal
exit /b 0
```

### 8.4 自動化後の状態

PC 再起動後、ユーザーがログインしてから約 20〜30 秒で以下が成立します。

| 確認項目 | 状態 |
| --- | --- |
| shim (node.exe) | バックグラウンドプロセスとして常駐 |
| ローカル healthz | `http://127.0.0.1:8787/healthz` で OK |
| 公開 healthz | `https://<your-funnel-domain>/healthz` で OK |
| 可視ウィンドウ | **0 個** (cmd / wscript / tailscale 全て hidden) |
| Funnel 設定 | `tailscaled` サービスが永続保持。再起動後も自動復元 |

タスクマネージャー → **詳細** タブ → `node.exe` の Command line に `server.js` を含むものが shim です。

## 9. Cursor 側の設定

一度だけ以下を設定してください。

### 9.1 Override OpenAI Base URL

```
https://<your-funnel-domain>/v1
```

Cursor → Settings → Models → 「Override OpenAI Base URL」に上記を貼り付け。

### 9.2 API Key

Moonshot の API Key をそのまま入力。

### 9.3 Custom Model

- Model Name: `kimi-k2.6`
- モデル設定で context length は `256000` (256K) を推奨

### 9.4 Verify

「Verify」ボタンを押して接続確認。成功すれば即座に Agent モードで使えます。

## 10. 動作検証

### 10.1 基本チェック

PowerShell で以下を実行:

```powershell
# ローカル
Invoke-RestMethod 'http://127.0.0.1:8787/healthz' -TimeoutSec 2

# 公開 URL (Tailscale Funnel 経由)
Invoke-RestMethod 'https://<your-funnel-domain>/healthz' -TimeoutSec 5
```

両方とも `pid`, `uptimeSec`, `target`, `reasoningPatcher` が返れば OK。

### 10.2 Cursor での実践検証

1. Cursor を開く
2. Agent モードで `kimi-k2.6` を選択
3. 「`package.json` の中身を読んで version を教えて」と依頼 (ツール呼び出しが発生)
4. ツール結果を踏まえた次ターンが **400 エラーなし** で回答生成されることを確認

## 11. 運用上の注意点

### 11.1 長時間思考時の接続安定化対策 (Network Error 防止)

Moonshot の Kimi K2.6 は複雑な推論で **60〜150 秒以上** 応答を返さないことがあります。この間、Cursor のクラウドバックエンドや中間プロキシが「無音 SSE ストリーム」をアイドルタイムアウトで切断し、`Network Error` が発生する場合があります。shim 側で実装した多層対策は以下の通りです。

| レイヤ | 対策 | 既定値 | 対象 |
|---|---|---|---|
| HTTP (SSE) | **SSE keepalive コメント** (`: keepalive\n\n`) を下流に送出 | **15 秒** | Cursor クラウド・中間プロキシのアイドル切断 |
| HTTP (Header) | `X-Accel-Buffering: no` + `Cache-Control: no-cache, no-transform` | 常時付与 | nginx/CDN/エッジのバッファリング抑制 |
| TCP | **TCP keep-alive** (`setKeepAlive(true, 15s)` + `setNoDelay(true)`) | **15 秒** | NAT/CGNAT/家庭・企業 FW の無音 TCP セッション切断 |
| Node.js | `requestTimeout=0` / `keepAliveTimeout=600s` / `timeout=0` | — | shim 自身の既定タイムアウトによる誤切断防止 |
| 上流 | 自動リトライ (`ECONNRESET`/`ETIMEDOUT`/`UND_ERR_SOCKET`) | 3 回 | Moonshot との瞬断回復 |

環境変数で後から調整可能です。

```powershell
# SSE keepalive 間隔をさらに短縮 (例: 10 秒)
$env:SHIM_KEEPALIVE_MS="10000"

# TCP keep-alive 間隔を変更 (例: 10 秒)
$env:SHIM_TCP_KEEPALIVE_MS="10000"
```

**制限事項 (shim 側では対処不可)**

- **Cursor クライアント自身の SSE 受信タイムアウト値**は Cursor 側の実装で、shim からは書き換えられません。上記対策は「そのタイムアウトに引っかからないようにする」総当たりです。
- **Moonshot 上流の 60〜150 秒沈黙**は Moonshot 側の思考時間仕様で、shim から短縮することはできません。

次回 `Network Error` が発生した際は、`moonshot-shim.log` の該当時刻に `keepalive=N` が付いていれば「keepalive を送ってもなお Cursor 側で切られた」と確定し、Cursor 側固有の問題に絞り込めます。

### 11.2 URL は固定

Tailscale Funnel の URL (`https://<your-funnel-domain>/`) は **変更されません**。PC 再起動後も同じ URL でアクセスできます。Cursor 側の設定変更は不要です。

### 11.3 Tailscale サービスが停止した場合

`tailscaled` Windows サービスが停止すると Funnel も途絶えます。通常は自動起動・自動復元されますが、まれに手動再起動が必要な場合:

```powershell
Restart-Service tailscaled
# その後 30 秒ほど待つと Funnel も復元される
```

### 11.4 shim ログ

```powershell
Get-Content "<repo-path>\moonshot-shim.log" -Tail 20
```

### 11.5 Funnel 状態確認

```powershell
& "C:\Program Files\Tailscale\tailscale.exe" funnel status
```

### 11.6 Funnel を完全に停止したい場合

```powershell
& "C:\Program Files\Tailscale\tailscale.exe" funnel reset
```

## 12. 既知の制限と将来の改善余地

| 項目 | 現状 | 将来 |
| --- | --- | --- |
| placeholder `" "` | Moonshot が中身を検証していないため通る。厳格化されると破綻 | Cursor 側が `reasoning_content` を正式サポートすれば shim 不要 |
| 外部公開 | Tailscale Funnel 経由で自宅 PC の 8787 が外向きに見える | 実質 Tailscale 信頼区内のみなので、ゼロトラスト的には安全 |
| shim 常駐 | node.exe がバックグラウンドで常駐 (約 48 MB) | Windows サービス化すればタスクマネージャーからも消せる |

## 13. 完全自動再現プレイブック (無人実行向け)

以下は、人的判断やコンテキスト理解を必要とせず、コマンドやファイル操作の羅列だけで再現できる手順を記述したものです。できるだけ前提知識を減らし、コピペブロックと判定条件で構成しています。

### 13-1. 事前条件チェック

以下を順に実行し、各ステップで停止条件に該当したらその直前まで戻る。

```powershell
# A. Tailscale インストール確認
Test-Path "C:\Program Files\Tailscale\tailscale.exe"
# 停止条件: False → Tailscale Windows クライアントを https://tailscale.com/download/windows からインストールして再開

# B. shim ファイル存在確認
Test-Path "<repo-path>\server.js"
# 停止条件: False → 姉妹編 CURSOR_KIMI_K26_FIX.md の「6. 作成・配置したファイル一覧」に従い server.js を配置

# C. node_modules 存在確認
Test-Path "<repo-path>\node_modules\undici\package.json"
# 停止条件: False → cd <repo-path> && npm install

# D. Tailscale Funnel 有効化確認 (管理コンソール)
# https://login.tailscale.com/admin/settings/features
# Funnel が ON になっていることを確認
```

### 13-2. 初回手動テスト

```powershell
cd "<repo-path>"

# 手動で shim 起動 → Ctrl+C で停止 (listening 確認のみ)
node server.js
# 停止条件: "listening on http://127.0.0.1:8787" が表示されない → 環境変数 SHIM_PORT 衝突の可能性。netstat で確認

# Tailscale Funnel テスト
& "C:\Program Files\Tailscale\tailscale.exe" funnel --bg 8787

# 公開 healthz 確認
$r = Invoke-RestMethod 'https://<your-funnel-domain>/healthz' -TimeoutSec 5
# 停止条件: $r.reasoningPatcher -ne "enabled" → funnel が 8787 以外に向いているか、shim が起動していない

# テスト完了後リセット
& "C:\Program Files\Tailscale\tailscale.exe" funnel reset
```

### 13-3. 自動化ファイル作成

#### start-tailscale.cmd

ファイルパス: `<repo-path>\start-tailscale.cmd`

内容 (全文):

```batch
@echo off
setlocal
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -Command "if (Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue) { Write-Host '[1/3] shim already running' -ForegroundColor Yellow } else { Start-Process -FilePath 'node' -ArgumentList 'server.js' -WorkingDirectory '%~dp0' -WindowStyle Hidden; Write-Host '[1/3] shim launched' -ForegroundColor Green }"

powershell -NoProfile -ExecutionPolicy Bypass -Command "$ok=$false; for($i=0;$i-lt10;$i++){Start-Sleep -Milliseconds 500; try{ $r=Invoke-RestMethod 'http://127.0.0.1:8787/healthz' -TimeoutSec 2; Write-Host ('[2/3] healthz OK pid={0}' -f $r.pid) -ForegroundColor Green; $ok=$true; break }catch{} }; if(-not $ok){ Write-Host '[2/3] healthz FAIL' -ForegroundColor Red; exit 1 }"
if errorlevel 1 exit /b 1

powershell -NoProfile -ExecutionPolicy Bypass -Command "$ts='C:\Program Files\Tailscale\tailscale.exe'; $ok=$false; for($i=0;$i-lt30;$i++){ try{ & $ts funnel --bg 8787 2>$null | Out-Null; $r=Invoke-RestMethod 'https://<your-funnel-domain>/healthz' -TimeoutSec 4; Write-Host ('[3/3] public OK pid={0}' -f $r.pid) -ForegroundColor Green; $ok=$true; break }catch{ Start-Sleep -Seconds 2 } }; if(-not $ok){ Write-Host '[3/3] FAIL' -ForegroundColor Red; exit 1 }"

endlocal
exit /b 0
```

#### start-tailscale-hidden.vbs

ファイルパス: `<repo-path>\start-tailscale-hidden.vbs`

内容 (全文):

```vbs
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run Chr(34) & "<repo-path>\start-tailscale.cmd" & Chr(34), 0, False
Set WshShell = Nothing
```

#### スタートアップ ショートカット (.lnk)

以下の PowerShell を実行:

```powershell
$shell = New-Object -ComObject WScript.Shell
$startup = $shell.SpecialFolders("Startup")
$shortcut = $shell.CreateShortcut("$startup\Start-MoonshotShim-Tailscale-Hidden.lnk")
$shortcut.TargetPath = "<repo-path>\start-tailscale-hidden.vbs"
$shortcut.WorkingDirectory = "<repo-path>"
$shortcut.WindowStyle = 7
$shortcut.Save()
```

**判定条件**: `$startup` フォルダに `Start-MoonshotShim-Tailscale-Hidden.lnk` が存在すること。

### 13-4. 自動化後の動作確認

PC を再起動 (またはログオフ→ログオン) してから 30 秒待ち、以下を実行:

```powershell
# 公開 URL で healthz 確認
$r = Invoke-RestMethod 'https://<your-funnel-domain>/healthz' -TimeoutSec 5
# 判定条件: $r.reasoningPatcher -eq "enabled" かつ $r.pid -gt 0

# タスクマネージャー詳細タブで node.exe の CommandLine に server.js が含まれることを確認 (手動)
```

### 13-5. Cursor 設定 (ユーザー自身が実施)

本ドキュメントの対象外。ユーザーが手動で行う:

```
Override OpenAI Base URL: https://<your-funnel-domain>/v1
```

---

**本ドキュメントの対象外の操作:**
- Cursor の `settings.json` や model list の変更
- API Key の設定
- Tailscale 管理コンソールでの Funnel 有効化 (初回のみ)
