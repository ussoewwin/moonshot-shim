# Cursor で Kimi K2.6 をエージェントとして使う

Cursor IDE から Moonshot の `kimi-k2.6` (Thinking モデル) を **ツール呼び出し付き** で使えるようにするまでの完全ガイド。

作成日: 2026-04-25
作業フォルダ: `<repo-path>\`

---

## 目次

1. [症状](#1-症状)
2. [根本原因](#2-根本原因)
3. [影響範囲](#3-影響範囲)
4. [採用した対策の全体像](#4-採用した対策の全体像)
5. [構成図](#5-構成図)
6. [作成・配置したファイル一覧](#6-作成配置したファイル一覧)
7. [起動手順](#7-起動手順)
8. [Cursor 側の設定](#8-cursor-側の設定)
9. [動作検証](#9-動作検証)
10. [運用上の注意点](#10-運用上の注意点)
11. [キャッシュ最適化のコツ](#11-キャッシュ最適化のコツ)
12. [既知の制限と将来の改善余地](#12-既知の制限と将来の改善余地)

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
| openclaude | GitHub HEAD (commit `44f9cac`) で `preserveReasoningContent: true` 処理を実装済。npm 公開版 v0.6.0 にはまだ降りていないため、本作業中に `dist/cli.mjs` を手で差し替え済 (別途対応)。 |
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

2. **Cloudflare Tunnel (cloudflared)**
   - Cursor の Override OpenAI Base URL は **Cursor のクラウドサーバー経由で叩かれる** 設計のため、`127.0.0.1` 等の private IP は SSRF 防御で機械的にブロックされる (`ssrf_blocked: connection to private IP is blocked`)
   - そのため shim を一時的に外向けに公開する必要がある
   - cloudflared の **quick tunnel** を使用し、`https://*.trycloudflare.com` の HTTPS URL を払い出してもらう
   - ローカル環境が UDP/443 をブロックしていたため、`--protocol http2` で TCP/443 にフォールバック

placeholder が `" "` (半角スペース) で通る理由は §2 末尾の「Moonshot は中身を検証していない」性質によります。これが将来 Moonshot 側で厳格化されると本対策は機能しなくなり、本物の thinking テキストを保持・echo back する方式 (openclaude HEAD と同じ) に切り替えが必要になります。

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
         │ HTTPS to https://<random>.trycloudflare.com/v1/...
         ▼
┌──────────────────────────────┐
│  Cloudflare の edge          │  HTTP/2 で接続
│  (trycloudflare.com)         │
└────────┬─────────────────────┘
         │ Tunnel (cloudflared プロセスが outbound で接続維持)
         ▼
┌──────────────────────────────────────┐
│  cloudflared.exe (ローカル PC 上)    │  PID xxxx
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
| `cloudflared.exe` | バイナリ (約 65 MB) | Cloudflare Tunnel クライアント。GitHub Releases から DL。 |
| `CURSOR_KIMI_K26_FIX.md` | ドキュメント | **本ファイル**。総括。 |

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
| `SHIM_KEEPALIVE_MS` | `15000` | SSE keepalive コメント送出間隔 (ミリ秒) |
| `SHIM_TCP_KEEPALIVE_MS` | `15000` | TCP keep-alive プローブ間隔 (ミリ秒) |
| `SHIM_UPSTREAM_RETRIES` | `2` | 上流エラー時の自動リトライ回数 |
| `SHIM_RETRY_BASE_MS` | `250` | 自動リトライの基本待機時間 (ミリ秒) |

## 7. 起動手順

PowerShell を 2 枚開きます。

### 7.1 ターミナル 1: shim 起動

```powershell
cd <repo-path>
node server.js
```

期待ログ:

```
2026-04-25T... moonshot-shim listening on http://127.0.0.1:8787 pid=...
2026-04-25T... forwarding to https://api.moonshot.ai/v1
2026-04-25T... log file: <repo-path>\moonshot-shim.log
2026-04-25T... reasoning_content patcher: enabled (assistant.tool_calls -> placeholder " ")
2026-04-25T... SSE keepalive: 15000ms  TCP keepalive: 15000ms
2026-04-25T... healthz: GET http://127.0.0.1:8787/healthz
2026-04-25T... point your client "Override OpenAI Base URL" at http://127.0.0.1:8787/v1
```

### 7.2 ターミナル 2: cloudflared 起動

```powershell
cd <repo-path>
.\cloudflared.exe tunnel --no-autoupdate --protocol http2 --url http://127.0.0.1:8787
```

注意点:
- `--protocol http2` は **必須**。既定の QUIC (UDP/443) は環境によって通らないため、TCP/443 にフォールバック。
- 本環境では QUIC で `failed to serve tunnel connection` を連発するため http2 強制。

期待ログ:

```
... INF Requesting new quick Tunnel on trycloudflare.com...
... INF |  Your quick Tunnel has been created! Visit it at:
... INF |  https://<random-words>.trycloudflare.com
... INF Registered tunnel connection ... protocol=http2
```

`https://...trycloudflare.com` の URL を控える。**この URL は cloudflared を再起動するたびに変わります**。

## 8. Cursor 側の設定

1. Cursor を起動 → 右上ギアアイコン → **Settings**
2. 左メニュー **Models**
3. **API Keys** セクション
   - **OpenAI API Key** に Moonshot のキー (`sk-...`) を貼る
4. **Override OpenAI Base URL** を ON にし、cloudflared が払い出した URL に `/v1` を付けたものを入力
   ```
   https://<random-words>.trycloudflare.com/v1
   ```
5. **+ Add Model** で `kimi-k2.6` (Moonshot のモデル ID) を追加
6. メイン画面の Composer / Agent 入力欄でモデルセレクタから `kimi-k2.6` を選択
7. 適当な質問 (例: 「このリポジトリをよく理解してくれ」) を投げる
8. ツール実行が走り、エラーなくレスポンスが返れば成功

## 9. 動作検証

### 9.1 単体テスト (Moonshot に到達する前に検証)

`test-echo.mjs` を実行すると、ローカルに echo サーバーを立てて shim 経由でリクエストを通し、`reasoning_content` が注入されたかを検証します。

```powershell
cd <repo-path>
node test-echo.mjs
```

期待出力 (末尾):

```
=== reasoning_content injected: PASS ===
```

### 9.2 結合テスト (Tunnel 経由で Moonshot に到達するか)

cloudflared の URL に対して認証なしで叩き、401 が返れば経路は通っている。

```powershell
Invoke-WebRequest -Uri "https://<random-words>.trycloudflare.com/v1/models" -Method GET -UseBasicParsing
```

`HTTP 401` が出れば全経路 OK (Moonshot まで到達して認証拒否されただけ)。

### 9.3 Cursor からの実機テスト

Agent モードで以下のような **必ずツールを呼ぶ** 質問を投げる。

- 「このリポジトリの構造を要約してください」 (codebase_search)
- 「`server.js` を読んでください」 (read_file)
- 「`launch_utils.py` を 5 行追加してください」 (edit_file)

ツール実行後の次ターンでもエラーなくレスポンスが返れば完全成功。

## 10. 運用上の注意点

### 10.1 起動順序

`shim` → `cloudflared` の順で起動する (cloudflared は起動時に転送先がリッスンしていなくても問題ないが、リクエストが先に来た場合 502 が返る)。停止は逆順 (`cloudflared` → `shim`) が安全。

### 10.2 quick tunnel URL は揮発性

cloudflared を再起動するたびに URL が変わります。再起動のたびに Cursor 設定の Override Base URL を貼り直す手間が発生します。これが煩わしい場合の解決策は §12.1 を参照。

### 10.3 セキュリティ

- cloudflared 経由で外部に shim が公開されますが、shim は `Authorization` ヘッダーをそのまま Moonshot に転送する設計です。**有効な Moonshot キーを持たない第三者からのアクセスは Moonshot 側で 401 で弾かれます**。
- ただし shim 自身のリソース (CPU / 帯域) は無認証で消費されるため、もし大量アクセスを受けると DoS になり得ます。気になる場合は shim に共有秘密ヘッダー検証を追加 (§12.3)。
- tunnel URL は十分長くて推測困難ですが、URL を SNS 等に貼ると拾われます。**URL は外に出さない**。

### 10.4 本対策が効かなくなる条件

- Moonshot が `reasoning_content` の中身を厳格検証する仕様変更を入れた場合
- Cursor 本体が `reasoning_content` をネイティブサポートし、shim が不要になった場合 (これは喜ばしい)
- cloudflared / trycloudflare.com の無料 tunnel サービスが終了 / 仕様変更された場合 (ngrok 等の代替あり)

### 10.5 長時間思考時の接続安定化対策

`server.js` (shim) は Cloudflare / Tailscale 両方式で共通のため、以下の対策が **Cloudflare 使用時にも有効**です。

- **SSE keepalive コメント** (`: keepalive\n\n`) を 15 秒間隔で下流に送出
- **TCP keep-alive** (`setKeepAlive(true, 15s)`) を SSE ソケットに設定
- **HTTP ヘッダー** `X-Accel-Buffering: no` + `Cache-Control: no-cache, no-transform` を付与
- **Node.js タイムアウト解除** (`requestTimeout=0` / `keepAliveTimeout=600s` 等)
- **上流自動リトライ** (`ECONNRESET` / `ETIMEDOUT` 等、3 回)

Cloudflare のエッジは元々長時間 SSE に対して寛容なため、これらの対策の効果は Tailscale 側でより顕在化しますが、コード自体は Cloudflare 使用時も同様に動作しています。環境変数 `SHIM_KEEPALIVE_MS` / `SHIM_TCP_KEEPALIVE_MS` で後から調整可能。

Cursor クライアント自身の SSE 受信タイムアウト値は shim から変更できません。詳細は Tailscale 版ドキュメント §11.1 を参照。

## 11. キャッシュ最適化のコツ

Moonshot の prompt cache 価格は:

- Cache HIT: $0.16 / 1M tokens
- Cache MISS: $0.95 / 1M tokens
- 出力: $4.00 / 1M tokens (どちらの場合も)

差は約 6 倍。中規模 (100k context) で 10 ターン会話する典型ケースでは、

- **同じスレッドで継続**: 約 $0.27
- **毎ターン新スレッド**: 約 $1.04

と **約 4 倍** の差が出ます。

### 効率を最大化する 3 動作

1. **重い context は最初に一度だけロード**
   - 「このリポジトリ全体を理解して、構造を要約してください」を初手で投げる
   - 1 回目: 全 MISS で $0.10 前後
   - 以降: ほぼ全 HIT で $0.02/ターン前後

2. **同じスレッドで畳み掛ける**
   - 関連質問はすべて同じ Agent スレッドに継ぎ足す
   - `+ New Agent` を押した瞬間に過去のキャッシュは無効化扱い

3. **論理的に区切れたら要約して新スレッドへ**
   - 前スレッドで「ここまでの調査結果と未解決事項を箇条書きで」と言わせる
   - その箇条書きだけを新スレッドに貼る → 新スレッドの初回 MISS が 100k → 5k に縮む

### 注意

- Moonshot の prompt cache TTL は業界相場で 15 分〜1 時間。**集中的に短時間で進めた方が安い**。
- 1 スレッド = 1 モデルで固定 (途中でモデル切替するとキャッシュキーが変わる)。
- shim の placeholder は **必ず固定値 `" "`** で運用 (毎回ランダムにすると全 MISS)。現実装は固定なので問題なし。
- Cursor 本体のアップデート直後はシステムプロンプトが変わってキャッシュが全 MISS になる場合あり。

## 12. 既知の制限と将来の改善余地

### 12.1 quick tunnel URL の揮発性 → Named Tunnel 化

Cloudflare アカウント (無料) を作成し、Named Tunnel を構成すれば、`https://kimi.your-domain.com` のような **固定 URL** にできます。手順:

1. Cloudflare アカウント作成
2. ドメインを Cloudflare に移管 or サブドメイン委任
3. `cloudflared tunnel login` (ブラウザで認証)
4. `cloudflared tunnel create kimi-shim`
5. `~/.cloudflared/config.yml` に hostname と service を記述
6. `cloudflared tunnel run kimi-shim` で常駐

### 12.2 PC 起動時の自動起動

タスクスケジューラに以下 2 つを「ログオン時に実行」で登録:

- `node <repo-path>\server.js`
- `<repo-path>\cloudflared.exe tunnel --no-autoupdate --protocol http2 --url http://127.0.0.1:8787`

ただし quick tunnel の URL が起動毎に変わるので、Named Tunnel 化 (§12.1) と組み合わせるのが実用的。

### 12.3 共有秘密ヘッダー検証の追加

shim を強化したい場合、`server.js` の handler 冒頭に追加:

```javascript
const SHIM_SECRET = process.env.SHIM_SECRET;
if (SHIM_SECRET) {
  const got = req.headers['x-shim-secret'];
  if (got !== SHIM_SECRET) {
    res.writeHead(403, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: { message: 'shim: forbidden', type: 'shim_auth' }}));
    return;
  }
}
```

ただし Cursor からは任意のリクエストヘッダーを付けられないため、URL パラメータで認証する形に変える必要があり、Cursor 側との相性問題が残ります。実用上は §10.3 の「URL を外に出さない」運用で十分。

### 12.4 thinking 本物保持版への切替

Moonshot が将来 placeholder を弾くようになった場合、shim はそれ単体では対処できません。理由は、Cursor がレスポンスストリームから返ってきた `reasoning_content` を保持しないため、shim 側にも本物の thinking が残らないからです。

その場合の選択肢:

- shim 側でレスポンス SSE を読み取り、`reasoning_content` をローカル DB に保存。次のリクエスト時に `tool_call_id` をキーに引き出して挿入する → 実装可能だが大掛かり。
- Cursor が公式に対応してくれるのを待つ。
- openclaude のように、本体に手を入れられるツールに乗り換える。

### 12.5 DeepSeek-R1 への転用

`SHIM_TARGET` を変えるだけで DeepSeek-R1 にも転用可能:

```powershell
$env:SHIM_TARGET = "https://api.deepseek.com/v1"
node server.js
```

Cursor 側のモデル名は `deepseek-reasoner` 等に変更。

---

## 付録 A: トラブルシューティング

| 症状 | 原因 | 対処 |
| --- | --- | --- |
| Cursor 側で `ssrf_blocked` | shim を直接指定している (cloudflared 未経由) | cloudflared を起動して trycloudflare URL を Cursor に設定 |
| cloudflared が `failed to serve tunnel connection` を連発 | UDP/443 がブロックされている | `--protocol http2` を付けて起動 |
| shim ログに patched=0 が並ぶがエラーなし | 単純な一問一答チャットでツールが呼ばれていない | 想定通り。問題なし |
| Cursor 側で 401 | API Key の値が誤り or 期限切れ | Moonshot 側で再発行 |
| Cursor 側で 502 | shim が落ちている | ターミナル 1 を再起動 |
| Cursor 側で `connection refused` | cloudflared が落ちている | ターミナル 2 を再起動し、新 URL を Cursor に再設定 |
| 反応が極端に遅い | quick tunnel の uptime 保証なし、混雑 | URL 再払い出し or Named Tunnel 化 |
| Cursor 側で `Network Error` (長時間思考時) | Moonshot の思考時間 (60〜150 秒) が Cursor クラウド側のタイムアウトを超えた | shim の SSE keepalive / TCP keep-alive が自動対応。ログで `keepalive=N` があれば Cursor 側固有問題。Tailscale 版へ移行を推奨 |

## 13. 完全自動再現プレイブック (無人実行向け)

以下は、人的判断やコンテキスト理解を必要とせず、コマンドやファイル操作の羅列だけで再現できる手順を記述したものです。できるだけ前提知識を減らし、コピペブロックと判定条件で構成しています。

### 13-1. 事前条件チェック

以下を順に実行し、各ステップで停止条件に該当したらその直前まで戻る。

```powershell
# A. Node.js インストール確認 (Cursor 同梱の node.exe でも可)
(Test-Path "C:\Program Files\nodejs\node.exe") -or (Get-Command node -ErrorAction SilentlyContinue)
# 停止条件: False → Node.js を https://nodejs.org/ からインストール

# B. shim ファイル存在確認
Test-Path "<repo-path>\server.js"
# 停止条件: False → 下記 §13-2 の server.js を作成

# C. node_modules 存在確認
Test-Path "<repo-path>\node_modules\undici\package.json"
# 停止条件: False → cd <repo-path> && npm install

# D. cloudflared バイナリ存在確認
Test-Path "<repo-path>\cloudflared.exe"
# 停止条件: False → https://github.com/cloudflare/cloudflared/releases から cloudflared-windows-amd64.exe をダウンロードし、上記パスにリネームして配置
```

### 13-2. server.js の配置 (初回のみ)

以下の内容を `<repo-path>\server.js` に書き込む。ファイルが既に存在する場合は本ステップをスキップしてよい。

```javascript
// moonshot-shim/server.js
//
// Local HTTP proxy that sits between an OpenAI-compatible client (Cursor,
// Cline, etc.) and Moonshot's Kimi API. Its sole purpose is to satisfy
// Moonshot's "thinking model" validation rule:
//
//   400: thinking is enabled but reasoning_content is missing
//        in assistant tool call message at index N
//
// Moonshot's K2.6 (and other reasoning models) require that *every*
// assistant message in the conversation history that carries `tool_calls`
// also carries a non-empty string `reasoning_content`. Standard OpenAI
// SDK / OpenAI-compatible clients drop that field, so multi-turn tool
// conversations break.
//
// The patcher below walks `messages` and injects `reasoning_content: " "`
// into every offending assistant message. The Moonshot API only checks
// for the field's presence and non-emptiness; the placeholder value is
// accepted.
//
// Everything else (auth header, model id, streaming SSE, /v1/models,
// errors) is forwarded verbatim.
//
// --- Resilience features (added 2026-04-25) ------------------------------
//   * Persistent log file:  ./moonshot-shim.log  (append, rotated at start
//     when previous file > 5 MB)
//   * uncaughtException / unhandledRejection are CAUGHT and logged.
//     The process keeps running. (Previous version exited on EPIPE etc.)
//   * Per-minute summary line (req / err / patched / upstream-status mix).
//   * /healthz endpoint for external liveness checks.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { request } from 'undici';

const PORT = parseInt(process.env.SHIM_PORT || '8787', 10);
const HOST = process.env.SHIM_HOST || '127.0.0.1';
const TARGET = (process.env.SHIM_TARGET || 'https://api.moonshot.ai/v1').replace(/\/+$/, '');
const DEBUG = process.env.SHIM_DEBUG === '1';
const PLACEHOLDER = ' ';
const UPSTREAM_RETRIES = Math.max(0, parseInt(process.env.SHIM_UPSTREAM_RETRIES || '2', 10));
const RETRY_BASE_MS = Math.max(50, parseInt(process.env.SHIM_RETRY_BASE_MS || '250', 10));
const KEEPALIVE_INTERVAL_MS = Math.max(0, parseInt(process.env.SHIM_KEEPALIVE_MS || '15000', 10));
const TCP_KEEPALIVE_MS = Math.max(0, parseInt(process.env.SHIM_TCP_KEEPALIVE_MS || '15000', 10));

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const LOG_PATH = process.env.SHIM_LOG || path.join(__dirname, 'moonshot-shim.log');
const LOG_MAX_BYTES = 5 * 1024 * 1024;

function rotateIfBig() {
  try {
    const st = fs.statSync(LOG_PATH);
    if (st.size > LOG_MAX_BYTES) {
      const rotated = LOG_PATH + '.1';
      try { fs.unlinkSync(rotated); } catch {}
      fs.renameSync(LOG_PATH, rotated);
    }
  } catch {}
}
rotateIfBig();

const logStream = fs.createWriteStream(LOG_PATH, { flags: 'a' });
logStream.on('error', (err) => {
  console.error(new Date().toISOString(), 'LOG STREAM ERROR', err.message);
});

function ts() { return new Date().toISOString(); }

function log(...args) {
  const line = `${ts()} ${args.map((a) => (typeof a === 'string' ? a : JSON.stringify(a))).join(' ')}\n`;
  process.stdout.write(line);
  try { logStream.write(line); } catch {}
}

function dlog(...args) { if (DEBUG) log('[debug]', ...args); }

const stats = { req: 0, err: 0, patched: 0, byStatus: Object.create(null), windowStart: Date.now() };
function bumpStatus(code) {
  const k = String(code);
  stats.byStatus[k] = (stats.byStatus[k] || 0) + 1;
}
setInterval(() => {
  const elapsed = ((Date.now() - stats.windowStart) / 1000).toFixed(0);
  const statusStr = Object.entries(stats.byStatus).sort((a, b) => Number(a[0]) - Number(b[0])).map(([k, v]) => `${k}=${v}`).join(',') || '-';
  log(`[summary] window=${elapsed}s req=${stats.req} err=${stats.err} patched=${stats.patched} statuses=${statusStr}`);
  stats.req = 0; stats.err = 0; stats.patched = 0; stats.byStatus = Object.create(null); stats.windowStart = Date.now();
}, 60_000).unref();

function patchMessagesForMoonshot(body) {
  if (!body || !Array.isArray(body.messages)) return 0;
  let patched = 0;
  for (const msg of body.messages) {
    if (!msg || msg.role !== 'assistant') continue;
    if (!Array.isArray(msg.tool_calls) || msg.tool_calls.length === 0) continue;
    const rc = msg.reasoning_content;
    if (typeof rc !== 'string' || rc.trim() === '') {
      msg.reasoning_content = PLACEHOLDER;
      patched++;
    }
  }
  return patched;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

const HOP_BY_HOP = new Set(['connection','keep-alive','proxy-authenticate','proxy-authorization','te','trailers','transfer-encoding','upgrade','host','content-length']);
function copyHeaders(src) {
  const out = {};
  for (const [k, v] of Object.entries(src)) {
    if (HOP_BY_HOP.has(k.toLowerCase())) continue;
    out[k] = v;
  }
  return out;
}

function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }

function isRetryableUpstreamError(err) {
  if (!err) return false;
  const code = String(err.code || '');
  const msg = String(err.message || '');
  if (code === 'ECONNRESET' || code === 'ETIMEDOUT') return true;
  if (msg.includes('ECONNRESET') || msg.includes('ETIMEDOUT')) return true;
  if (msg.includes('UND_ERR_SOCKET') || msg.includes('UND_ERR_CONNECT_TIMEOUT') || msg.includes('UND_ERR_HEADERS_TIMEOUT')) return true;
  return false;
}

async function requestWithRetry(url, options, reqMeta) {
  let attempt = 0;
  while (true) {
    try {
      return await request(url, options);
    } catch (err) {
      const canRetry = isRetryableUpstreamError(err) && attempt < UPSTREAM_RETRIES;
      if (!canRetry) throw err;
      const waitMs = RETRY_BASE_MS * (attempt + 1);
      log('UPSTREAM RETRY', `attempt=${attempt + 1}/${UPSTREAM_RETRIES}`, reqMeta, String(err.code || ''), err.message, `wait=${waitMs}ms`);
      await sleep(waitMs);
      attempt++;
    }
  }
}

function safeWrite(res, chunk) {
  if (!res || res.destroyed || res.writableEnded) return false;
  try { return res.write(chunk); } catch (err) { log('RES WRITE ERROR', err.message); return false; }
}

function safeEnd(res) {
  if (!res || res.destroyed || res.writableEnded) return;
  try { res.end(); } catch (err) { log('RES END ERROR', err.message); }
}

const server = http.createServer(async (req, res) => {
  const started = Date.now();
  stats.req++;
  res.on('error', (err) => { log('RES ERROR', err.code || '', err.message); });
  req.on('error', (err) => { log('REQ ERROR', err.code || '', err.message); });

  let url;
  try {
    url = new URL(req.url, `http://${req.headers.host || HOST + ':' + PORT}`);
  } catch (e) {
    safeWrite(res, '');
    res.writeHead(400, { 'content-type': 'text/plain' });
    safeEnd(res);
    return;
  }

  if (url.pathname === '/healthz' || url.pathname === '/_shim/healthz') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, uptimeSec: Math.round(process.uptime()), target: TARGET, pid: process.pid }));
    return;
  }

  let upstreamPath = url.pathname;
  if (upstreamPath.startsWith('/v1/')) upstreamPath = upstreamPath.slice(3);
  else if (upstreamPath === '/v1') upstreamPath = '';
  const upstreamUrl = TARGET + upstreamPath + url.search;

  let raw;
  try { raw = await readBody(req); } catch (err) {
    stats.err++;
    log('REQ READ ERROR', err.message);
    try { res.writeHead(400, { 'content-type': 'text/plain' }); res.end('shim: failed to read request body: ' + err.message); } catch {}
    return;
  }

  let bodyToSend = raw.length > 0 ? raw : undefined;
  let patchInfo = '';
  if (req.method === 'POST' && raw.length > 0) {
    let json = null;
    try { json = JSON.parse(raw.toString('utf8')); } catch {}
    if (json && Array.isArray(json.messages)) {
      const n = patchMessagesForMoonshot(json);
      stats.patched += n;
      try { bodyToSend = Buffer.from(JSON.stringify(json), 'utf8'); } catch (err) { log('JSON STRINGIFY ERROR', err.message); bodyToSend = raw; }
      patchInfo = ` model=${json.model || '?'} msgs=${json.messages.length} patched=${n} stream=${!!json.stream}`;
      if (DEBUG && n > 0) dlog(`patched ${n} assistant.tool_calls message(s)`);
    }
  }

  const upstreamHeaders = copyHeaders(req.headers);
  if (bodyToSend) upstreamHeaders['content-length'] = String(bodyToSend.length);

  let upstream;
  try {
    upstream = await requestWithRetry(upstreamUrl, { method: req.method, headers: upstreamHeaders, body: bodyToSend, maxRedirections: 0 }, `${req.method} ${upstreamUrl}`);
  } catch (err) {
    stats.err++;
    bumpStatus(502);
    log('UPSTREAM ERROR', req.method, upstreamUrl, err.message);
    try { res.writeHead(502, { 'content-type': 'application/json' }); res.end(JSON.stringify({ error: { message: 'shim: upstream connect error: ' + err.message, type: 'shim_upstream_error' } })); } catch {}
    return;
  }

  bumpStatus(upstream.statusCode);
  const respHeaders = copyHeaders(upstream.headers);
  const ct = String(upstream.headers['content-type'] || '');
  const isSSE = ct.includes('text/event-stream');
  if (isSSE) {
    respHeaders['x-accel-buffering'] = 'no';
    respHeaders['cache-control'] = 'no-cache, no-transform';
  }
  try { res.writeHead(upstream.statusCode, respHeaders); } catch (err) {
    log('RES WRITEHEAD ERROR', err.message);
    try { upstream.body.destroy(); } catch {}
    return;
  }

  if (isSSE && TCP_KEEPALIVE_MS > 0) {
    try {
      const sock = res.socket || req.socket;
      if (sock && typeof sock.setKeepAlive === 'function') {
        sock.setKeepAlive(true, TCP_KEEPALIVE_MS);
        if (typeof sock.setNoDelay === 'function') sock.setNoDelay(true);
      }
    } catch (err) { log('TCP KEEPALIVE SET ERROR', err.message); }
  }

  let lastWriteAt = Date.now();
  let keepAliveTimer = null;
  let keepAliveCount = 0;
  function stopKeepAlive() { if (keepAliveTimer) { clearInterval(keepAliveTimer); keepAliveTimer = null; } }

  if (isSSE && KEEPALIVE_INTERVAL_MS > 0) {
    const tick = Math.max(1000, Math.floor(KEEPALIVE_INTERVAL_MS / 2));
    keepAliveTimer = setInterval(() => {
      if (!res || res.destroyed || res.writableEnded) { stopKeepAlive(); return; }
      if (Date.now() - lastWriteAt >= KEEPALIVE_INTERVAL_MS) {
        if (safeWrite(res, ': keepalive\n\n')) { lastWriteAt = Date.now(); keepAliveCount++; }
      }
    }, tick);
    keepAliveTimer.unref();
  }

  upstream.body.on('data', (c) => { if (safeWrite(res, c)) lastWriteAt = Date.now(); });
  upstream.body.on('end', () => {
    stopKeepAlive(); safeEnd(res);
    const ms = Date.now() - started;
    const ka = isSSE && keepAliveCount > 0 ? ` keepalive=${keepAliveCount}` : '';
    log(`${req.method} ${url.pathname} -> ${upstream.statusCode} ${ms}ms${patchInfo}${ka}`);
  });
  upstream.body.on('error', (err) => { stats.err++; stopKeepAlive(); log('UPSTREAM BODY ERROR', err.message); safeEnd(res); });
  req.on('close', () => { stopKeepAlive(); if (!res.writableEnded) { try { upstream.body.destroy(); } catch {} } });
});

server.on('clientError', (err, socket) => { log('CLIENT ERROR', err.code || '', err.message); try { socket.destroy(); } catch {} });
server.on('error', (err) => { log('SERVER ERROR', err.code || '', err.message); });

process.on('uncaughtException', (err) => { log('UNCAUGHT EXCEPTION', err && err.stack ? err.stack : String(err)); });
process.on('unhandledRejection', (reason) => { const s = reason && reason.stack ? reason.stack : String(reason); log('UNHANDLED REJECTION', s); });

server.requestTimeout = 0;
server.keepAliveTimeout = 600_000;
server.headersTimeout = 605_000;
server.timeout = 0;

server.listen(PORT, HOST, () => {
  log(`moonshot-shim listening on http://${HOST}:${PORT} pid=${process.pid}`);
  log(`forwarding to ${TARGET}`);
  log(`log file: ${LOG_PATH}`);
  log('reasoning_content patcher: enabled (assistant.tool_calls -> placeholder " ")');
  log(`SSE keepalive: ${KEEPALIVE_INTERVAL_MS}ms  TCP keepalive: ${TCP_KEEPALIVE_MS}ms`);
  log('healthz: GET http://' + HOST + ':' + PORT + '/healthz');
  log('point your client "Override OpenAI Base URL" at http://' + HOST + ':' + PORT + '/v1');
  if (DEBUG) log('debug mode ON (SHIM_DEBUG=1)');
});

function shutdown(sig) {
  log(`received ${sig}, shutting down`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 2000).unref();
}
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
```

**判定条件**: 上記内容が `<repo-path>\server.js` に書き込まれていること。ファイルサイズは約 480 行以上。

### 13-3. 依存インストール

```powershell
cd "<repo-path>"
npm install
```

**判定条件**: `node_modules\undici\package.json` が存在すること。

### 13-4. 初回手動テスト

```powershell
cd "<repo-path>"

# (A) shim 単体テスト
Start-Process -FilePath "node" -ArgumentList "server.js" -WorkingDirectory "<repo-path>" -WindowStyle Hidden
Start-Sleep -Seconds 2
$r = Invoke-RestMethod 'http://127.0.0.1:8787/healthz' -TimeoutSec 2
# 停止条件: $r.ok -ne $true → server.js の内容確認

# (B) cloudflared テスト (ターミナルを別途開き、以下を実行)
# cd "<repo-path>"
# .\cloudflared.exe tunnel --url http://127.0.0.1:8787 --protocol http2
# → https://<random>.trycloudflare.com が表示されたら Ctrl+C で停止
```

### 13-5. 自動化ファイル作成

#### start-all.cmd

ファイルパス: `<repo-path>\start-all.cmd`

内容 (全文):

```batch
@echo off
REM Launch moonshot-shim + cloudflared quick tunnel for Cursor
setlocal
cd /d "%~dp0"

REM Start shim hidden
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'node' -ArgumentList 'server.js' -WorkingDirectory '%~dp0' -WindowStyle Hidden"

REM Wait for shim
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ok=$false; for($i=0;$i-lt10;$i++){Start-Sleep -Milliseconds 500; try{ $r=Invoke-RestMethod 'http://127.0.0.1:8787/healthz' -TimeoutSec 2; Write-Host ('shim OK pid={0}' -f $r.pid) -ForegroundColor Green; $ok=$true; break }catch{} }; if(-not $ok){ Write-Host 'shim FAIL' -ForegroundColor Red; exit 1 }"
if errorlevel 1 exit /b 1

REM Start cloudflared quick tunnel
echo.
echo === Cloudflare Quick Tunnel ===
echo URL will appear below. Copy it to Cursor -> Override OpenAI Base URL
echo.
.\cloudflared.exe tunnel --url http://127.0.0.1:8787 --protocol http2

endlocal
```

**判定条件**: 上記内容が正確に書き込まれていること。

### 13-6. Cursor Skill 作成 (オプション・推奨)

ファイルパス: `D:\.cursor\skills\start-moonshot-shim\SKILL.md`

内容 (全文):

```markdown
---
name: start-moonshot-shim
description: Launch the local moonshot-shim and cloudflared quick tunnel so Cursor can talk to Moonshot's kimi-k2.6 thinking model. Use when the user asks to start, restart, relaunch, or bring up the moonshot shim, the quick tunnel, or the Cursor Kimi access path. Also triggers on Japanese phrasings such as "shim を起動して", "kimi を起動して", "cloudflared 起動", "PC 再起動したから shim 動かして".
---

# Start Moonshot Shim + Cloudflare Quick Tunnel

## Purpose

Bring up the two background services required for Cursor to use Moonshot's `kimi-k2.6` model:

1. **moonshot-shim** — local Node proxy on `127.0.0.1:8787`
2. **cloudflared quick tunnel** — exposes the shim via a temporary public HTTPS URL

## How to run

Execute the launcher batch:

```
"<repo-path>\start-all.cmd"
```

This opens a console window showing the trycloudflare URL. The user must copy that URL into Cursor themselves.

## What to tell the user

After the tunnel URL appears (e.g. `https://abc123.trycloudflare.com`), tell them:

```
Cursor -> Override OpenAI Base URL: <paste-url>/v1
```

The user handles clicking Verify manually.

## Absolute stop rules

- Do NOT modify Cursor settings.json, model list, API key, or Override URL. The user reserved that step.
- Do NOT start a second cloudflared if one is already running.
- Do NOT kill an already-running shim unless the user explicitly asks.
```

**判定条件**: `D:\.cursor\skills\start-moonshot-shim\SKILL.md` が存在すること。

### 13-7. 動作確認フロー

1. `start-all.cmd` をダブルクリックまたは PowerShell で実行
2. 表示された `https://*.trycloudflare.com` URL をコピー
3. Cursor → Settings → Models → Override OpenAI Base URL に `<URL>/v1` を貼り付け
4. Verify をクリック
5. Agent モードでツール呼び出しを伴うタスクを投入し、400 エラーが出ないことを確認

**判定条件**: `API Error: 400 thinking is enabled but reasoning_content is missing` が出ないこと。

### 13-8. PC 再起動後の手順

Cloudflare quick tunnel の URL は **毎回変わる** ため、PC 再起動後は以下が必要:

1. `start-all.cmd` を再度実行
2. 新しい URL を Cursor に貼り付け (§13-7 と同じ)

これを自動化するには Tailscale Funnel 方式 (`CURSOR_KIMI_K26_TAILSCALE.md`) への移行を推奨。

---

## 付録 B: 関連リンク

- Moonshot Kimi K2.6 pricing: <https://platform.kimi.ai/docs/pricing/chat-k26>
- openclaude (npm): <https://www.npmjs.com/package/@gitlawb/openclaude>
- openclaude (GitHub): <https://github.com/gitlawb/openclaude>
- Cloudflare Tunnel docs: <https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/>
- LiteLLM (代替プロキシ): <https://github.com/BerriAI/litellm>
