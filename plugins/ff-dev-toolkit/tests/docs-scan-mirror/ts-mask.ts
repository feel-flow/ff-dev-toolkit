/**
 * docs-scan-mirror の TS 側ドライバ（Issue #528）。
 *
 * 引数のファイルを **同梱 MCP の実消費者と同じ経路**で読み、maskClosedSpans の
 * 結果を stdout へ出す。verify.sh がこの出力と awk 版（tests/lib/docs-scan.sh の
 * ff_docs_mask_spans）の出力をバイト比較する。
 *
 * 実消費者（buildGlossary / maskNonGlossaryLines）は本文を `split(/\r?\n/)` で
 * 行へ割るので、ここも同じ分割にする。末尾の改行 1 つだけを先に落とすのは、
 * awk（RS="\n"）が「最後の改行の後ろ」を 1 行として数えないため — 落とさないと
 * 行数が必ず 1 つずれ、全 fixture が「差分あり」になって照合が意味を失う。
 * 正規化はこの 2 つ（末尾改行 1 つ / CR は verify.sh 側で落とす）だけに限る。
 */
import { readFileSync } from 'node:fs';
import { maskClosedSpans } from '../../mcp/src/utils.js';

const target = process.argv[2];
if (!target) {
  process.stderr.write('usage: ts-mask <file>\n');
  process.exit(2);
}
const raw = readFileSync(target, 'utf8');
const body = raw.replace(/\r?\n$/, '');
const masked = maskClosedSpans(body.split(/\r?\n/));
process.stdout.write(masked.join('\n') + '\n');
