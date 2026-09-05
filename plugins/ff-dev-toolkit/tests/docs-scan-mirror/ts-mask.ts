/**
 * docs-scan-mirror の TS 側ドライバ（docs 走査マスクの awk 版 / TS 版ミラー）。
 *
 * 引数のファイルを **同梱 MCP の実消費者と同じ経路**で読み、既定では
 * maskClosedSpans の結果を stdout へ出す。verify.sh がこの出力と awk 版
 * （tests/lib/docs-scan.sh の ff_docs_mask_spans）の出力をバイト比較する。
 *
 * 第 2 引数に `changelog` を渡すと maskNonGlossaryLines（GLOSSARY.md の実消費者。
 * maskClosedSpans に加えて `## Changelog` 見出し以降を空行化する）を使う。
 * awk 側の対応物は ff_docs_mask_changelog（`## Changelog` 見出し判定の空白
 * クラス・空白数が awk 版と TS 版で割れていた欠陥〔2026-09 実測〕を、両者を
 * 照合するこの 2 モード目で固定した）。
 *
 * mode は `spans` / `changelog` の 2 値のみ。未知の値（typo）を既定へ倒すと
 * 「別モードを検査したつもりで spans を 2 回照合していた」空振りが緑で通りうる
 * ため、fail-closed（exit 2）にする。
 *
 * 実消費者（buildGlossary / maskNonGlossaryLines）は本文を `split(/\r?\n/)` で
 * 行へ割るので、ここも同じ分割にする。末尾の改行 1 つだけを先に落とすのは、
 * awk（RS="\n"）が「最後の改行の後ろ」を 1 行として数えないため — 落とさないと
 * 行数が必ず 1 つずれ、全 fixture が「差分あり」になって照合が意味を失う。
 * 正規化はこの 2 つ（末尾改行 1 つ / CR は verify.sh 側で落とす）だけに限る。
 */
import { readFileSync } from 'node:fs';
import { maskClosedSpans, maskNonGlossaryLines } from '../../mcp/src/utils.js';

const target = process.argv[2];
const mode = process.argv[3] ?? 'spans';
if (!target) {
  process.stderr.write('usage: ts-mask <file> [spans|changelog]\n');
  process.exit(2);
}
if (mode !== 'spans' && mode !== 'changelog') {
  process.stderr.write(`ts-mask: unknown mode ${JSON.stringify(mode)} (expected spans|changelog)\n`);
  process.exit(2);
}
const raw = readFileSync(target, 'utf8');
const body = raw.replace(/\r?\n$/, '');
const lines = body.split(/\r?\n/);
const masked = mode === 'changelog' ? maskNonGlossaryLines(lines) : maskClosedSpans(lines);
process.stdout.write(masked.join('\n') + '\n');
