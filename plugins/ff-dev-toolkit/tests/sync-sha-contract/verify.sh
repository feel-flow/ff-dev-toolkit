#!/usr/bin/env bash
#
# sync-dev-toolkit SKILL の「記録する SSOT SHA = 同期した内容」契約の静的検査
# （Issue #634）。
#
# 守っている事故: 手順 4 の commit メッセージ SHA をブランチ ref
# （`git rev-parse --short develop`）から採ると、同期実行後に並行セッションの
# マージで develop が進んだ場合に「同期していない SHA を反映済み」と記録する。
# drift 検知（check-dev-toolkit-sync-drift.sh / check-release-required.sh）は
# この SHA を同期基点に使うため、取り残しが DRIFT_COUNT=0 のまま隠れる
# （fail-open。PR #622 のマージ後同期で実測 — detached HEAD 7c805a6 で同期中に
# 並行マージで develop ref が 87da5c8 へ進み、commit メッセージだけが 87a5... 系の
# 未同期 SHA になった）。
#
# 同期元 SHA の受け渡しはシェル変数ではなくファイル（Issue #895）。同期スクリプトが
# 「実際に展開した内容の SHA」を target の git ディレクトリ配下 `ff-sync-src-sha` へ
# 書き、手順 4 がそれを読む。手順 3 と手順 4 が別プロセスでも値が生存するので、
# 「別シェルになったら手順 3 からやり直す」（＝直前の成功が残した差分に当たって
# 必ず失敗する）という詰みが消える。不変条件（記録 SHA == 同期内容）は維持する。
#
# 検査するのは次の 4 層:
#   1. 出現（手順書）: 記録の読み取り・if 連結の HEAD 突合・読んだ SHA からの採取・
#      記録不在時の中断・detached 退避・HEAD からの再導出禁止・fetch 失敗時の中断
#   2. 順序（手順書）: 同期実行 → 記録の読み取り → 突合 → commit の行番号が単調増加
#      （読み取りを同期の前へ動かす退行・突合を commit の後ろへ動かす退行の検出）
#   3. 禁止: ブランチ ref から SHA を採るコマンド置換（develop / origin/develop /
#      refs/heads/develop）が復活していない。手順 3 でシェル変数へ HEAD を控える
#      旧方式が復活していない。commit 行そのものに `develop` を含む SHA 式が無い
#   4. 出現・順序（同期スクリプト）: 同期する SHA を展開の前に固定し、記録は
#      ミラー書き込みの前に消してミラー成功の後に書く
# 順序は行番号の単調性のみで、同一フェンス内であること・実行時の競合までは
# 主張しない（実行時の防波堤は手順 4 の if 連結突合）。
#
# 「記録 SHA ≠ 同期内容」の実ミスマッチは静的検査では観測できないので、実 Git
# fixture の runtime（src-sha-runtime.sh）が記録の実挙動と手順 4 ブロックの実行を
# 受け持つ。静的検査は文面の固定、runtime は挙動の固定という分担。
#
# skip の鍵は検査対象そのものではなく**リポジトリの同一性**（sync スクリプトの
# 存在。sync-forbidden-patterns と同じ判定軸）: 公開 checkout（スクリプト不在）は
# ○ skip、SSOT なのに SKILL が無い場合は red（fail-closed — 改名・移設で唯一の
# ゲートが黙って skip 化するのを防ぐ）。FF_SYNC_SHA_SKILL で検査対象を差し替え
# られる（変異実測用）が、明示指定が不在の場合は skip ではなく fail。
#
# needle を追加・変更したら、対象行だけを削除・移動する変異を手で当てて red に
# なることを確認する（docs-gates と同じ規則）。手順書の針型検査は read-only。
# 全件 green 再利用判定だけは、一時 Git リポジトリで実挙動も固定する。bash 3.2 互換。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

SYNC_SCRIPT="$REPO_ROOT/scripts/sync-dev-toolkit-to-public.sh"
DEFAULT_SKILL="$REPO_ROOT/.claude/skills/sync-dev-toolkit/SKILL.md"
FULL_GATE_REUSE_SCRIPT="$REPO_ROOT/scripts/check-full-gate-reuse.sh"

if [[ -n "${FF_SYNC_SHA_SKILL:-}" ]]; then
  SKILL="$FF_SYNC_SHA_SKILL"
  echo "⚠ FF_SYNC_SHA_SKILL で検査対象を差し替えています: $SKILL" >&2
  if [[ ! -f "$SKILL" ]]; then
    echo "✗ FF_SYNC_SHA_SKILL に指定されたファイルがありません（明示指定の不在は skip ではなく失敗）: $SKILL" >&2
    exit 1
  fi
else
  SKILL="$DEFAULT_SKILL"
  if [[ ! -f "$SYNC_SCRIPT" ]]; then
    echo "○ skip: $SYNC_SCRIPT が無いためスキップ（SSOT 専用の検査。公開 checkout では対象外）"
    exit 0
  fi
  if [[ ! -f "$SKILL" ]]; then
    echo "✗ SSOT checkout（sync スクリプトあり）なのに SKILL がありません: $SKILL" >&2
    echo "  改名・移設した場合は本 suite のパスも更新すること（黙って skip 化させない）" >&2
    exit 1
  fi
fi

# 同期スクリプト側の検査対象。既定は上で解決した実体と同じで、FF_SYNC_SHA_SCRIPT で
# 差し替えられる（変異実測用）。SKILL 側と同じく、明示指定の不在は skip ではなく失敗。
SYNC_SCRIPT_UNDER_TEST="${FF_SYNC_SHA_SCRIPT:-$SYNC_SCRIPT}"
if [[ -n "${FF_SYNC_SHA_SCRIPT:-}" ]]; then
  echo "⚠ FF_SYNC_SHA_SCRIPT で同期スクリプトの検査対象を差し替えています: $SYNC_SCRIPT_UNDER_TEST" >&2
fi
if [[ ! -f "$SYNC_SCRIPT_UNDER_TEST" ]]; then
  echo "✗ 検査対象の同期スクリプトがありません: $SYNC_SCRIPT_UNDER_TEST" >&2
  exit 1
fi

# 実行検査数の侵食ガード（TESTING.md の EXPECTED_CHECKS 方針）。針を 1 本消しても
# 残りが緑のまま「全 N 件 pass」で通るため、総数を別途固定する。検査を増減したときの
# 更新箇所は 2 つ: ok / bad を増減させた箇所と、この宣言。
# 公開 checkout では上の skip 経路が 1 件も検査せずに exit 0 するため、ここには
# 到達しない（配置による期待値の分岐は不要）。
EXPECTED_CHECKS=43

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

contains() {
  local needle="$1" label="$2" rc=0
  grep -qF -- "$needle" "$SKILL" || rc=$?
  case "$rc" in
    0) ok "$label" ;;
    1) bad "${label}（不足: ${needle}）" ;;
    *) bad "${label}（grep が失敗 rc=${rc}）" ;;
  esac
}

# 出現「回数」まで固定する。同じ文字列が複数の分岐に現れる針は、片方が消えても
# もう片方に一致して緑のままになり、識別力を失う（Issue #830 レビュー）。
contains_exactly() {
  local needle="$1" want="$2" label="$3" got
  got="$(grep -cF -- "$needle" "$SKILL" || true)"
  if [[ "$got" == "$want" ]]; then
    ok "$label"
  else
    bad "${label}（期待 ${want} 箇所 / 実際 ${got} 箇所: ${needle}）"
  fi
}

not_contains() {
  local needle="$1" label="$2" rc=0
  grep -qF -- "$needle" "$SKILL" || rc=$?
  case "$rc" in
    0) bad "${label}（禁止パターンが存在: ${needle}）" ;;
    1) ok "$label" ;;
    *) bad "${label}（grep が失敗 rc=${rc}）" ;;
  esac
}

# needle を含む最初の行番号を返す（無ければ空）。awk はファイルを直接読むので
# head 経由の SIGPIPE 反転が起きない。
line_of() {
  awk -v pat="$1" 'index($0, pat) { print NR; exit }' "$SKILL"
}

# 同期スクリプト側の針。SKILL 用の contains / line_of と同型で、対象だけが違う。
script_contains() {
  local needle="$1" label="$2" rc=0
  grep -qF -- "$needle" "$SYNC_SCRIPT_UNDER_TEST" || rc=$?
  case "$rc" in
    0) ok "$label" ;;
    1) bad "${label}（不足: ${needle}）" ;;
    *) bad "${label}（grep が失敗 rc=${rc}）" ;;
  esac
}

script_line_of() {
  awk -v pat="$1" 'index($0, pat) { print NR; exit }' "$SYNC_SCRIPT_UNDER_TEST"
}

# 行番号の単調性を 1 件の検査として報告する。アンカーが引けない場合は fail-closed。
assert_order() {
  local before="$1" after="$2" ok_msg="$3" bad_msg="$4"
  if [[ -z "$before" || -z "$after" ]]; then
    bad "順序検査のアンカーが欠落（before=${before:-<不在>} after=${after:-<不在>}）— 空振りは fail-closed: ${ok_msg}"
  elif [[ "$before" -lt "$after" ]]; then
    ok "${ok_msg}（${before} < ${after}）"
  else
    bad "${bad_msg}（${before} >= ${after}）"
  fi
}

echo "== sync-dev-toolkit SHA 記録契約 =="

# ── 1. 出現 ──────────────────────────────────────────────────────────────────
contains '`ff-sync-src-sha` へ書き出す' \
  "手順 3 が、同期スクリプトの記録先（公開側 clone の .git 配下）を明示している"
contains 'SYNC_SRC_SHA=$(cat "$(git -C "$PUBLIC" rev-parse --absolute-git-dir)/ff-sync-src-sha" 2>/dev/null || true)' \
  "手順 4 が同期元 SHA を記録ファイルから読む（シェル変数を跨がせない）"
contains '記録の不在を「一致」と扱わない' \
  "記録が無いときに中断することが明記されている（不在を一致にしない）"
contains 'if [ -n "${SYNC_SRC_SHA:-}" ] && [ "$(git rev-parse HEAD)" = "$SYNC_SRC_SHA" ]; then' \
  "手順 4 が HEAD の不動と SYNC_SRC_SHA の存在を if 連結で突合する（set -e 非依存）"
contains 'git rev-parse --short "$SYNC_SRC_SHA"' \
  "手順 4 の commit メッセージが控えた SHA から採られる"
contains 'git checkout --detach origin/develop' \
  "他 worktree が develop を保持する場合の退避手順がある"
contains 'ref から SHA を採ると「同期していない SHA を反映済み」と記録し' \
  "退避時に HEAD 基準の記録が必須になる理由が明記されている"
contains 'HEAD から再導出してはならない' \
  "記録が無いときに HEAD から再導出することが禁じられている"
contains 'stale な origin/develop で続行しない' \
  "退避経路の fetch 失敗時に中断することが明記されている"

# 全件実行ゲート（ADR-034 決定 2）。既定が高速モードになったため、素の run-all.sh は
# REQUIRED_SUITES 掲載を含む selftest 群を除外して **exit 0** で返す。除外は SKIPPED に
# 現れないので必須 skip の fail-closed にも掛からず、「検査が実行されないまま緑」がそのまま
# 不可逆な公開同期へ接続する。週次 CI が無い本リポジトリではこの手順が定期実行点そのもの
# なので、手順から消えたら赤くする（機械強制ではなく手順の固定が、静的検査の上限）。
contains_exactly 'FF_RUN_ALL_FULL=1 bash plugins/ff-dev-toolkit/tests/run-all.sh' 2 \
  "手順 0 が全件実行のゲートを踏む — 初回ブロックと fail-closed 分岐の 2 箇所（ADR-034 決定 2）"
contains '非 0 なら**同期しない**' \
  "全件ゲートが非 0 のとき同期しないことが明記されている"
contains 'FULL_GATE_SHA=$(git rev-parse HEAD)' \
  "全件 green の実測 SHA を次の収束周回へ控える"
contains 'scripts/check-full-gate-reuse.sh --green-sha "$FULL_GATE_SHA"' \
  "収束周回で全件 green SHA と HEAD の tree 差分を機械判定する"
contains 'FULL_GATE_REUSE=CHANGELOG_FOOTER_ONLY' \
  "footer-only 判定だけを限定ゲートへ接続する"
# 省略が起きる分岐そのものと、fail-closed の受け皿を針で固定する。件数ガードは「書かれた
# 検査の削除」しか捕まえないので、書かれていない検査には保護が及ばない（Issue #830 レビュー）。
contains '0:*FULL_GATE_REUSE=IDENTICAL*)' \
  "tree 同一の受理条件が分岐として明示されている"
contains '他差分・dirty・非祖先・判定不能・未知の出力はすべて全件へ倒す（fail-closed）' \
  "未知・判定不能をすべて全件へ倒す受け皿がある"
contains 'HEAD から「直前の値」を再導出してはならない' \
  "全件 green SHA を HEAD から再導出する操作を禁じている"
contains '検査した tree と HEAD の tree が一致しないため green を記録しない' \
  "dirty なまま得た green を SHA として記録しない"

# 限定ゲートの 4 suite 呼び出しは **2 箇所**にある — 手順 0 の CHANGELOG_FOOTER_ONLY 分岐と、
# 手順 8 の footer ブランチ先端での実行（Issue #892）。件数まで固定するのは、
#   (a) 手順 8 のブロックを丸ごと削除する退行を捕まえるため。単なる `contains` では
#       手順 0 の側に一致して緑のままになり、「削除しても全 suite が緑」という
#       検出力ゼロの状態が残る（本 PR のレビュー指摘 W1）
#   (b) 片方だけ suite を足し引きする退行を捕まえるため。両者は同じ 4 suite でなければ、
#       footer PR の先端と回し直しとで別のものを検査することになる
# needle に行末の継続（バックスラッシュ）を含めるのは、散文中の同名の言及を数えないため
# （`changelog-links/verify.sh` は手順 8 の再実行の説明にも出る）。`contains_exactly` は
# `grep -cF` で**行数**を数えるので、1 行に 2 回現れる needle には使えない。
contains_exactly 'plugins/ff-dev-toolkit/tests/changelog-links/verify.sh \' 2 \
  "限定ゲートの CHANGELOG リンク検査が手順 0 と手順 8 の 2 箇所にある"
contains_exactly 'plugins/ff-dev-toolkit/tests/changelog-attribution/verify.sh \' 2 \
  "限定ゲートの CHANGELOG 帰属検査が手順 0 と手順 8 の 2 箇所にある"
contains_exactly 'plugins/ff-dev-toolkit/tests/changelog-version/verify.sh \' 2 \
  "限定ゲートの CHANGELOG version 検査が手順 0 と手順 8 の 2 箇所にある"
contains_exactly 'plugins/ff-dev-toolkit/tests/changelog-public-references/verify.sh 2>&1)" \' 2 \
  "限定ゲートの公開 CHANGELOG SSOT 参照検査が手順 0 と手順 8 の 2 箇所にある"
# skip / 未実行を成功と読まない要求も両方に要る。4 suite だけを走らせる分岐で
# `changelog-links` / `changelog-attribution` が無言の no-op になると代替物が何も残らない。
contains_exactly "grep -F -- 'failed=0 skipped=0 not-run=0' >/dev/null; then" 2 \
  "限定ゲートは skip / 未実行を成功と読まない — 手順 0 と手順 8 の 2 箇所"

# 手順 8 が「記録の COMMIT= を footer ブランチの先端にする」ことをブロックの中で読み戻す。
# 目的そのものを確かめずに終わると、先端を動かす操作（develop 追従・fix commit）を
# 挟んだ回に記録が先端でなくなり、マージ直前の照合が exit 1 でそこを初めて知る。
contains 'check-merge-freshness.sh --print-record' \
  "手順 8 が記録の COMMIT= を読み戻して先端と突合する"
contains '先端を動かしたなら限定ゲートを回し直すこと' \
  "読み戻しが失敗したときの次の一手が示されている"
contains '限定ゲートは、develop 追従を含むすべての push の後に回す' \
  "限定ゲートを先端が確定した後に回すことが明記されている（順序が記録を無効化しうる）"

# ── 2. 順序（行番号の単調増加） ──────────────────────────────────────────────
L_READ="$(line_of 'SYNC_SRC_SHA=$(cat "$(git -C "$PUBLIC" rev-parse --absolute-git-dir)/ff-sync-src-sha"')"
L_SYNC="$(awk '$0 == "scripts/sync-dev-toolkit-to-public.sh --target \"$PUBLIC\"" { print NR; exit }' "$SKILL")"
L_GUARD="$(line_of 'if [ -n "${SYNC_SRC_SHA:-}" ] && [ "$(git rev-parse HEAD)" = "$SYNC_SRC_SHA" ]; then')"
L_COMMIT="$(line_of 'git -C "$PUBLIC" commit -m "sync: ')"
L_FULLGATE="$(line_of 'FF_RUN_ALL_FULL=1 bash plugins/ff-dev-toolkit/tests/run-all.sh')"

# 記録の読み取りが同期実行より前にあると、前回の同期が残した記録を掴む（今回の
# 同期内容とは無関係な SHA を「反映済み」と記録する退行）。
assert_order "${L_SYNC}" "${L_READ}" \
  "順序: 記録の読み取りが同期実行より後" \
  "順序: 記録の読み取りが同期実行より前にある — 前回の記録を掴む退行"
assert_order "${L_READ}" "${L_GUARD}" \
  "順序: HEAD 突合が記録の読み取りより後" \
  "順序: HEAD 突合が記録の読み取りより前にある — 読む前に判定する退行"
assert_order "${L_GUARD}" "${L_COMMIT}" \
  "順序: HEAD 突合が commit より前" \
  "順序: HEAD 突合が commit より後ろにある — 突合前に記録が確定する退行"
# 全件ゲートは同期実行より前になければ意味がない（同期後に回しても不可逆操作は済んでいる）。
assert_order "${L_FULLGATE}" "${L_SYNC}" \
  "順序: 全件実行ゲートが同期実行より前" \
  "順序: 全件実行ゲートが同期実行より後ろにある — 不可逆操作の後で検査する退行"

# ── 3. 禁止（ブランチ ref からの採取の復活） ────────────────────────────────
# コマンド置換の形に限定する（散文の説明や Common Mistakes 表への記載を誤検出
# しないため。復活が実害になるのはコマンド例の中だけ）。
not_contains '$(git rev-parse --short develop)' \
  "ブランチ ref（develop）から SHA を採るコマンド置換が無い"
not_contains '$(git rev-parse --short origin/develop)' \
  "ブランチ ref（origin/develop）から SHA を採るコマンド置換が無い"
not_contains 'refs/heads/develop' \
  "refs/heads/develop 経由の採取が無い"
# 旧方式（手順 3 でシェル変数へ HEAD を控える）の復活。値がシェルを跨いで生存
# しないため、手順が別プロセスへ割れた瞬間に「記録あり」の経路ごと消える。
not_contains 'SYNC_SRC_SHA=$(git rev-parse HEAD)' \
  "同期元 SHA をシェル変数へ HEAD から控える旧方式が復活していない"

# ── 4. 同期スクリプト側（記録の生成契約） ────────────────────────────────────
# 記録するのは「実際に展開した内容の SHA」。HEAD は同期中にも動きうるので、
# 展開を HEAD で行って記録を後から rev-parse すると両者がずれる（#634 の再発）。
script_contains 'SRC_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"' \
  "同期スクリプトが同期対象の SHA を一度だけ固定する"
script_contains 'rm -f "$SRC_SHA_RECORD"' \
  "ミラー書き込みの前に古い記録を消す（中断した同期の記録を残さない）"
script_contains 'printf '"'"'%s\n'"'"' "$SRC_SHA" > "$SRC_SHA_RECORD"' \
  "ミラー成功後に同期元 SHA を記録する"

L_SRC_CAPTURE="$(script_line_of 'SRC_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"')"
L_ARCHIVE="$(script_line_of 'git -C "$ROOT" archive "$SRC_SHA"')"
L_RM="$(script_line_of 'rm -f "$SRC_SHA_RECORD"')"
L_RSYNC="$(script_line_of 'run_rsync "${RSYNC_FLAGS[@]}" --itemize-changes')"
# アンカーに `\n` を含めないこと — awk の -v 代入はエスケープを解釈するため、
# `'%s\n'` を含む needle は実改行へ化けて必ず空振りする（この suite で実測）。
L_WRITE="$(script_line_of '"$SRC_SHA" > "$SRC_SHA_RECORD"')"

assert_order "${L_SRC_CAPTURE}" "${L_ARCHIVE}" \
  "順序: 同期スクリプトが SHA を固定してから staging を展開する" \
  "順序: staging の展開が SHA の固定より前にある — 記録 SHA と同期内容がずれる退行"
assert_order "${L_RM}" "${L_RSYNC}" \
  "順序: 古い記録の削除がミラー書き込みより前" \
  "順序: 古い記録の削除がミラー書き込みより後ろにある — 中断時に古い記録が残る退行"
assert_order "${L_RSYNC}" "${L_WRITE}" \
  "順序: 記録の書き込みがミラー成功より後" \
  "順序: 記録の書き込みがミラー成功より前にある — 失敗した同期を「同期済み」にする退行"

if bash "$SCRIPT_DIR/src-sha-runtime.sh" "$SYNC_SCRIPT_UNDER_TEST" "$SKILL"; then
  ok "同期元 SHA の記録と手順 4 の実行が、別プロセス・HEAD 移動・記録不在を区別する"
else
  bad "同期元 SHA の受け渡しの実行契約が壊れている"
fi

if bash "$SCRIPT_DIR/reuse-runtime.sh" "$FULL_GATE_REUSE_SCRIPT"; then
  ok "全件成功の再利用判定が同一 tree / footer-only / fail-closed を区別する"
else
  bad "全件成功の再利用判定の実行契約が壊れている"
fi

# commit 行そのものに develop を含む SHA 式が無いこと（変数化などの迂回の検出）。
if [[ -n "${L_COMMIT}" ]]; then
  COMMIT_LINE="$(awk -v n="${L_COMMIT}" 'NR == n { print; exit }' "$SKILL")"
  case "$COMMIT_LINE" in
    *develop*) bad "commit 行に develop を含む式が混入している: $COMMIT_LINE" ;;
    *'"$SYNC_SRC_SHA"'*) ok "commit 行の SHA 式が \$SYNC_SRC_SHA のみ" ;;
    *) bad "commit 行に \$SYNC_SRC_SHA が見当たらない: $COMMIT_LINE" ;;
  esac
fi

echo
# 検査総数の侵食ガード。全検査成功ラン（FAIL=0）に限って完全一致を要求する — 行番号を
# 引けない失敗経路は後続の case 検査を飛ばすため、そのランはこのガード無しですでに赤い。
if [[ "$FAIL" -eq 0 && "$PASS" -ne "$EXPECTED_CHECKS" ]]; then
  echo "✗ sync-sha-contract verify: 実行検査数が ${PASS} 件（期待 ${EXPECTED_CHECKS} 件）— 検査が黙って増減している（増減時は EXPECTED_CHECKS も更新すること）" >&2
  exit 1
fi

if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ sync-sha-contract verify: $FAIL 件失敗 / $PASS 件成功" >&2
  exit 1
fi
echo "✓ sync-sha-contract verify: 全 $PASS 件 pass（検査総数ガード ${EXPECTED_CHECKS} 件と一致）"
