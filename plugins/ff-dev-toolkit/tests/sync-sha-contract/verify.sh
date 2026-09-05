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
# 同期元 SHA の受け渡しと footer-only 判定器だけは、一時 Git リポジトリで実挙動も
# 固定する。bash 3.2 互換。
#
# run-all-required: no — 同期スクリプトを持たない公開 checkout での skip は正当な適用外（SSOT 専用の検査）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

SYNC_SCRIPT="$REPO_ROOT/scripts/sync-dev-toolkit-to-public.sh"
DEFAULT_SKILL="$REPO_ROOT/.claude/skills/sync-dev-toolkit/SKILL.md"
# 同期手順からは ADR-039 で退役したが、changelog-fragments（cases/footer.sh）が
# footer-only PR の判定器として現役利用するため、スクリプトと挙動検査は残す
# （整理は epic #857 の棚卸し #873 で扱う）。
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

# 定期実行点ゲート（要求内容は ADR-039 が ADR-034 決定 2 の「全件ゲート充足」を置換。
# 位置は ADR-042 が 1 点目を「タグ / Release の作成前」へ縮小）。既定が高速
# モードのため、対を持つ selftest（REQUIRED_SUITES 掲載を含む）は既定実行では走らない。
# その検出力の担保は週次 CI（weekly-run-all）で、手順 0b は (1) 週次 CI の状態を
# check-weekly-run-all-health.sh で機械確認して HEALTH=healthy だけを高速モードへ受理し、
# (2) healthy 以外の回は FF_RUN_ALL_FULL=1 の全件実行で代替したうえで、HEAD への
# run-all green を要求する。どちらかが手順から消えると、selftest 層の担保を欠いたまま
# （または HEAD を一度も検査しないまま）不可逆な公開同期へ接続する。手順から消えたら
# 赤くする（機械強制ではなく手順の固定が、静的検査の上限。NG 文言と exit の対までは
# 単行 grep で固定できない — 「NG を出して続行する」変異は静的検査の上限の外）。
# 針はコマンド形の行全体に固定する — 裸のスクリプト名だと、散文の言及が 1 行増えた
# 時点で contains も line_of の順序アンカーも散文側に吸われて空振りする（レビュー W2）。
contains 'HEALTH_OUT="$(bash scripts/check-weekly-run-all-health.sh 2>&1)" || true' \
  "手順 0b が週次 CI の状態確認を踏む（selftest 層の担保。ADR-039）"
contains 'if [[ $'"'"'\n'"'"'"$HEALTH_OUT"$'"'"'\n'"'"' == *$'"'"'\n'"'"'"HEALTH=healthy"$'"'"'\n'"'"'* ]]; then' \
  "高速モードへ受理するのは HEALTH=healthy だけ（warming-up / running を成功実績と読まない）"
contains '⚠ 週次 CI の成功実績を確認できない（HEALTH が healthy 以外）— この回は全件実行で代替する' \
  "healthy 以外の回に全件代替へ倒すことが明記されている"
contains_exactly 'FF_RUN_ALL_FULL=1 bash plugins/ff-dev-toolkit/tests/run-all.sh' 1 \
  "healthy 以外の回の全件代替コマンドが手順 0b の 1 箇所にある"
contains 'if [ "$GATE_MODE" = fast ]; then' \
  "ローカル実行のモードが週次 CI の状態から導出される"
contains 'NG: run-all が失敗 — 同期しない' \
  "run-all が非 0 のとき同期しないことが明記されている"
contains '非 0 なら**同期しない**' \
  "ゲートが非 0 のとき同期しないことが明記されている"
contains '同じ 2 点を無条件に回し直す' \
  "収束周回でもゲートを省略しない（旧 green 再利用機構の復活を防ぐ）"
contains 'footer 差分でも省略しない' \
  "収束段落が footer 差分でのゲート省略を禁じている（旧 3 suite 充足への書き戻し検出。レビュー W1）"
contains '検査した tree と HEAD の tree が一致しない' \
  "dirty なまま得た green を「HEAD を検査済み」と扱わない"
# 旧方式（ADR-034 決定 2 + Issue #830 の green 再利用機構）の復活禁止。針は散文を
# 誤検出しない最小限の広さにする — 現 SKILL の散文言及は backtick 内の `FULL_GATE_SHA`
# （代入の `=` を含まない）だけで、check-full-gate-reuse への言及は無い（実測）。
not_contains 'FULL_GATE_SHA=' \
  "全件 green SHA をシェル変数へ控える旧方式が復活していない"
not_contains 'check-full-gate-reuse' \
  "廃止した green 再利用判定の呼び出しが復活していない"

# 限定ゲートの suite 呼び出し（2 suite / 4 観点。Issue #800 で changelog-contract へ、
# Issue #1021 で changelog-links + changelog-attribution が changelog-public-tags へ統合）は
# 手順 8 の footer ブランチ先端での実行（Issue #892）**1 箇所だけ**にある（旧方式の
# 手順 0 CHANGELOG_FOOTER_ONLY 分岐は ADR-039 で廃止。2 箇所へ戻る退行も、片方だけ
# suite を足し引きする退行も、件数固定で捕まえる）。
# needle に行末の継続（バックスラッシュ）を含めるのは、散文中の同名の言及を数えないため
# （`changelog-public-tags/verify.sh` は手順 8 の再実行の説明にも出る）。`contains_exactly` は
# `grep -cF` で**行数**を数えるので、1 行に 2 回現れる needle には使えない。
contains_exactly 'plugins/ff-dev-toolkit/tests/changelog-public-tags/verify.sh \' 1 \
  "限定ゲートの CHANGELOG 公開タグ検査（リンク追従 + 版節の帰属）が手順 8 の 1 箇所にある"
# 版の一致と公開参照の境界は Issue #800 で changelog-contract へ統合した（1 本で両方を見る）。
contains_exactly 'plugins/ff-dev-toolkit/tests/changelog-contract/verify.sh 2>&1)" \' 1 \
  "限定ゲートの CHANGELOG 契約検査（版の一致 + 公開参照の境界）が手順 8 の 1 箇所にある"
# skip / 未実行を成功と読まない要求。2 suite だけを走らせる限定ゲートで
# `changelog-public-tags` が無言の no-op になると代替物が何も残らない。
contains_exactly "grep -F -- 'failed=0 skipped=0 not-run=0' >/dev/null &&" 1 \
  "限定ゲートは skip / 未実行を成功と読まない — 手順 8 の 1 箇所"
# suite 単位の skipped=0 だけでは、changelog-public-tags の帰属検査が
# インデント付き部分 skip のまま「2 suite とも緑」に見える（Issue #1021 で
# compare リンク不在 / mktemp 不可が suite 全体 skip から部分 skip へ降格した）。
contains_exactly "grep -F -- 'checks-skipped: total=0' >/dev/null; then" 1 \
  "限定ゲートは suite 内の部分 skip も成功と読まない — 手順 8 の 1 箇所"

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
L_CIHEALTH="$(line_of 'HEALTH_OUT="$(bash scripts/check-weekly-run-all-health.sh 2>&1)" || true')"
L_GATE="$(line_of 'if [ "$GATE_MODE" = fast ]; then')"

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
# 定期実行点ゲートは同期実行より前になければ意味がない（同期後に回しても不可逆操作は
# 済んでいる）。週次 CI 生存確認 → run-all の並びも固定する（生存確認を後置すると、
# run-all green の後に「担保なし」が判明する形になり、中断点が不可逆操作へ近づく）。
assert_order "${L_CIHEALTH}" "${L_GATE}" \
  "順序: 週次 CI の生存確認が run-all より前" \
  "順序: 週次 CI の生存確認が run-all より後ろにある — 中断点が不可逆操作へ近づく退行"
assert_order "${L_GATE}" "${L_SYNC}" \
  "順序: 定期実行点ゲートが同期実行より前" \
  "順序: 定期実行点ゲートが同期実行より後ろにある — 不可逆操作の後で検査する退行"
# リリース準備（手順 R）の判定は定期実行点ゲート（手順 0b）の**前**に置く（ADR-042）。
# R の判定材料は手順 0a が揃えた作業ツリーと公開側 clone の履歴 / タグで、**ゲート結果には
# 依存しない**。後ろに置くと RELEASE_REQUIRED の回だけ「捨てられる 1 回目」が生まれる
# （OBS-015 で 5 回実測）。ADR-042 は定期実行点「リリース準備の前」の範囲を bump / 版節
# 昇格から外し、タグ / Release の前へ縮小した。
# このアサートが守るのは「R が 0b より前」だけで、後ろへ戻る退行は削った 1 回を復活させる。
# 縮小後の 1 点目そのもの（タグ = 手順 5 / Release = 手順 6 が 0b より後）に**アンカーは
# 無い** — 上の L_GATE < L_SYNC が固定するのは同期実行（手順 3）までで、タグ / Release が
# 0b より後にあることは現状では文書順序の帰結にすぎない。この穴は本アサートの反転が作った
# ものではなく（反転前の L_GATE < L_RELEASE も固定していない）、埋めるかどうかは epic #857
# の「検査の新設・拡張は原則行わない」との衝突判断を要する。この判断は Issue #1102 で
# **見送りを決定済み**（棚卸しで closed / not planned）— #857 の再開基準は確率ではなく
# 実発生を見る設計で、タグ節 / Release 節がゲートより前へ移動した退行は一度も起きて
# いないため。再開基準は「タグ節または Release 節が手順 0b より前へ移動する変更が
# 実際に発生したとき」で、そのとき本アンカーを足す。
# 針は行全体のコマンド形に固定し、出現 1 回を件数でも縛る — line_of は先頭一致なので、
# 反転後は「前方の散文へアンカーが吸われる」空振りが fail-open 側（R が前に見える）へ倒れる
# 向きになった（反転前は fail-closed 側だった）。
contains_exactly 'scripts/check-release-required.sh --public "$PUBLIC" --fetch' 1 \
  "手順 R の判定コマンドが 1 箇所だけにある（順序アンカーの一意性。反転で空振りが fail-open 側へ倒れるため）"
L_RELEASE="$(line_of 'scripts/check-release-required.sh --public "$PUBLIC" --fetch')"
assert_order "${L_RELEASE}" "${L_GATE}" \
  "順序: リリース準備の判定（手順 R）が定期実行点ゲートより前（ADR-042）" \
  "順序: リリース準備の判定がゲートより後ろにある — リリースが必要な回に全件ゲートを 2 回払う退行"
# 反転前は「R がゲートより後」で、ゲートが手順 0（0a の直後）にあったため「R が develop
# 最新化より後」が**推移的に**固定されていた。反転でその辺が誰にも固定されなくなるので、
# 明示アンカーで戻す（ADR-042 決定 2 が「前提は 0a が単独で満たす」を load-bearing にした）。
# 針は完全一致にする — `git pull --ff-only origin develop` は手順 R のコメント内にも散文で
# 出るため、部分一致だと 0a のコマンド行が消えた回にアンカーが R 自身の中へ吸われて無言で
# 非識別になる（L_SYNC と同じ形）。
L_DEVELOP_SYNC="$(awk '$0 == "git pull --ff-only origin develop" { print NR; exit }' "$SKILL")"
assert_order "${L_DEVELOP_SYNC}" "${L_RELEASE}" \
  "順序: リリース準備の判定（手順 R）が develop 最新化（手順 0a）より後" \
  "順序: 手順 R が develop 最新化より前にある — 判定材料（HEAD = develop 最新・clean）の前提が崩れる退行"

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
  ok "footer-only 判定器（changelog-fragments が使用）が同一 tree / footer-only / fail-closed を区別する"
else
  bad "footer-only 判定器の実行契約が壊れている"
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
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ sync-sha-contract verify: $FAIL 件失敗 / $PASS 件成功" >&2
  exit 1
fi
echo "✓ sync-sha-contract verify: 全 $PASS 件 pass"
