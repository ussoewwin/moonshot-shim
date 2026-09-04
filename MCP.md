# img-mcp — 画像認識 MCP サーバー

AutoGLM 画像認識（スキル: `autoglm-image-recognition`）を **MCP ツール化**したローカルサーバー。Windows コンソールの cp932 エンコーディング問題を構造的に回避している（スクリプト側 UTF-8 強制 + Node ラッパー）。

```
AutoClaw (MCP client)
   └─▶ http://127.0.0.1:19690/mcp   (Streamable HTTP, JSON-RPC 2.0)
          └─▶ node img-mcp-server.mjs
                 ├─ upload_image     → autoglm-file-upload/upload-mix.py   → OSS 公開 URL
                 └─ recognize_image  → autoglm-image-recognition/image-recognition.py
                                          (local_path 指定時は自動アップロードしてから認識)
```

## ツール

| ツール | 入力 | 出力 |
|---|---|---|
| `upload_image` | `path`（ローカル絶対パス） | `{ url }` — AutoGLM OSS の公開 URL |
| `recognize_image` | `image_url` または `local_path`、`prompt`（任意） | 認識結果テキスト（`data.text`） |

- `recognize_image` に `local_path` を渡すと **自動で upload → 認識**まで一気に実行する
- `prompt` 例: 「スクリーンショットの全テキストを列挙」「モデルIDとBaseURLを1行で」

## 起動・自動起動

- ランチャー: `start-img-mcp.cmd`（`start-img-mcp.ps1` が自動再起動ループ付きで node を管理）
- ログオン自動起動: `start-shim-hidden.vbs` に配線済み（shell:startup にショートカットがあればログオン時に起動）
- ポート: **19690**（`IMG_MCP_PORT` で変更可）
- ヘルスチェック: `GET http://127.0.0.1:19690/healthz` → `{"status":"ok","tools":["upload_image","recognize_image"]}`
- ログ: `img-mcp-wrapper.log`（wrapper）/ server 自体は stdout にログ

## AutoClaw への登録

`openclaw.json` / `openclaw.runtime.json` の `mcp.servers` に登録済み:

```json
"autoglm-img": {
  "type": "streamable-http",
  "url": "http://127.0.0.1:19690/mcp",
  "enabled": true
}
```

AutoClaw 再起動後、エージェントから `recognize_image` / `upload_image` ツールが使えるようになる。

## 実装メモ（今後の追記ルール）

- 本サーバーは既存スキルの Python スクリプト（UTF-8 強制済み）を呼ぶだけ。**新しい画像系ツールはこのセクションに追記していく**
- スクリプト側の cp932 ガード（`sys.stdout.reconfigure(encoding="utf-8")`）は 2026-09-04 に `image-recognition.py` / 3 つの `upload-mix.py` に埋め込み済み。新規スクリプト追加時も同じガードを冒頭に入れること
- `usage.prompt_tokens_details` が空のリレー（OpenCode Go）経由でも認識機能には影響なし
- 通信はローカルバインドのみ（`127.0.0.1`）。認証は未実装（同一マシン内想定）。外部公開する場合は `SHIM_SECRET` 相当の認証を先に追加すること

## 変更履歴

- 2026-09-04: 初版作成。upload_image / recognize_image の 2 ツール。AutoClaw に `autoglm-img` として登録。
