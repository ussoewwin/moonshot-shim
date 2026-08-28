#!/usr/bin/env node
// set-reasoning.mjs — AutoClaw のカスタムモデル (provider=custom) の `reasoning` を
// true に設定する。UI に reasoning 設定が無いため、設定ファイルを直接書き換える。
//
// 真のソース (source of truth) は settings.json の models.catalog。
// openclaw.json / openclaw.runtime.json はそこから生成される派生物なので、両方書く。
//
// 【重要】AutoClaw を終了してから実行するのが確実。実行後に AutoClaw を再起動する。
//
// 使い方:
//   node set-reasoning.mjs             # 実際に書き換える
//   node set-reasoning.mjs --dry-run   # 変更内容のプレビューのみ

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const dryRun = process.argv.includes('--dry-run');
const profile = process.env.USERPROFILE || os.homedir();

// 対象: [表示名, 絶対パス, 種別]
const targets = [
  ['settings.json',         path.join(profile, 'AppData', 'Roaming', 'autoclaw', 'settings.json'), 'settings'],
  ['openclaw.json',         path.join(profile, '.openclaw-autoclaw', 'openclaw.json'),               'providers'],
  ['openclaw.runtime.json', path.join(profile, '.openclaw-autoclaw', 'openclaw.runtime.json'),       'providers'],
];

function readRaw(file) {
  const raw = fs.readFileSync(file);
  const bom = raw[0] === 0xef && raw[1] === 0xbb && raw[2] === 0xbf;
  let text = raw.toString('utf8');
  if (bom) text = text.slice(1);
  const crlf = text.includes('\r\n');
  return { text, bom, crlf };
}

function writeRaw(file, text, bom, crlf) {
  let out = text;
  if (crlf) out = out.replace(/\n/g, '\r\n');
  if (bom) out = '\ufeff' + out;
  fs.writeFileSync(file, out, 'utf8');
}

let total = 0;
for (const [label, file, kind] of targets) {
  if (!fs.existsSync(file)) { console.log(`skip (not found): ${file}`); continue; }
  const { text, bom, crlf } = readRaw(file);
  let json;
  try { json = JSON.parse(text); }
  catch (e) { console.error(`parse error: ${file}: ${e.message}`); continue; }

  let changed = 0;
  if (kind === 'settings') {
    // settings.json: models.catalog の provider === 'custom' を対象
    for (const entry of json?.models?.catalog || []) {
      if (entry.provider === 'custom' && entry.reasoning === false) {
        entry.reasoning = true;
        changed++;
        console.log(`  custom/${entry.model}: reasoning false -> true`);
      }
    }
  } else {
    // openclaw.json / runtime.json: models.providers の custom__* を対象
    for (const [pid, prov] of Object.entries(json?.models?.providers || {})) {
      if (!pid.startsWith('custom__')) continue;
      for (const model of prov?.models || []) {
        if (model.reasoning === false) {
          model.reasoning = true;
          changed++;
          console.log(`  ${pid.slice(0, 12)}/${model.id}: reasoning false -> true`);
        }
      }
    }
  }

  if (changed > 0) {
    total += changed;
    if (!dryRun) writeRaw(file, JSON.stringify(json, null, 2) + '\n', bom, crlf);
    console.log(`${dryRun ? '[dry-run] ' : ''}${changed} updated in ${label}`);
  } else {
    console.log(`no change needed: ${label}`);
  }
}
console.log(`done: ${total} place(s)${dryRun ? ' (dry-run, not written)' : ''}`);
