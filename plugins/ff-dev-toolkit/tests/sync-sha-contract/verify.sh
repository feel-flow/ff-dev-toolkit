#!/usr/bin/env bash
#
# sync-dev-toolkit SKILL の手順書契約の静的検査。中核は「記録する SSOT SHA = 同期した
# 内容」（Issue `#634`）で、同じ手順書へ後から入った運用規定 — 並行セッションの実測
# （OBS-014 / OBS-138）、同期サイクルの in-flight 判定（OBS-044 / Issue `#1707`）、Release
# 反映遅れの吸収（OBS-104 / Issue `#1723`）— も同じ針型で固定する。
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
# 変異検出（新設の (6) 群・15 変異すべて赤転、SURVIVED 0 件。2026-09-18 実測）:
# 変異検出: 手順 0a の「準備 PR のゲート実行中は open PR が無くマージも止まる」を削除すると (6) が赤。
# 変異検出: 手順 0a の in-flight 判定の内訳 2 材料（直近 sync commit / footer 追従 PR）の行を削除すると (6) が赤。
# 変異検出: 手順 0a の「偽陽性で毎回止まることはない」の行を削除すると (6) が赤。
# 変異検出: 手順 0a の適用範囲（痕跡が残る前は検出できない）の行を削除すると (6) が赤。
# 変異検出: 手順 0a の「材料が取れなければ値を出さず中断」の行を削除すると (6) が赤。
# 変異検出: 手順 0a の「レビュー走行（25 分規模）の開始前にも行う」を削除すると (6) が赤。
# 変異検出: 手順 0a の IN_FLIGHT=no を含む 3 行のいずれかを削除すると出現数が 3 から外れて (6) が赤。
# 変異検出: 手順 7 の「作成直後の一覧を判定に使わない」を削除すると (6) が赤。
# 変異検出: 手順 7 の「手順 6 の一覧を再利用しない」を削除すると (6) が赤。
# 変異検出: 手順 7 の bash から版違いで再取得を抜ける分岐行を削除すると (6) が赤。
# 変異検出: 手順 7 の上限到達（6 回 ≒ 30 秒）で中断する行を削除すると (6) が赤。
# 変異検出: 手順 7 の過去取りこぼしを待たずに中断する行を削除すると (6) が赤。
# 変異検出: 手順 7 の「既存の回は再取得ループへ入らない」を削除すると (6) が赤。
# 変異検出: 手順 7 の片側空で判定不能として抜ける分岐行を削除すると (6) が赤。
# 変異検出: 手順 7 の「UNVERIFIED=yes は取りこぼし無しへ倒さない」を削除すると (6) が赤。
#
# 手順 0b / 5 / 8 の本体はリリーススクリプト（scripts/release-dev-toolkit.sh。ADR-063）へ移したので、
# 実行面の針（(7)）はスクリプトに当て、SKILL には判断の根拠（散文）の針だけを残す。スクリプトの
# 振る舞い（段の順序・dry-run が書き込まない・再実行で続きから・止まるべき状態・粒度判定・同期提案
# hook の in-flight 抑止）は release-runtime.sh が一時 Git リポジトリで固定する。
# 変異検出（(7) と release-runtime。2026-09-23 実測）:
# 変異検出: スクリプトの ALLOWED_SKIP_PATTERNS 照合（許容表に無い部分 skip で止める行）を削除すると (7) と release-runtime が赤。
# 変異検出: スクリプトの main で stage_gate と stage_sync の行を入れ替えると (7) の順序が赤。
# 変異検出: スクリプトの limited_gate 呼び出し行を削除すると (7) が赤。
# 変異検出: スクリプトの dry-run 分岐（prepare 段の DRY_RUN 判定）を外すと release-runtime（dry-run は書き込まない）が赤。
# 変異検出: スクリプトのゲート緑記録の照合（state_get GATE_OK）を外すと release-runtime（再実行でゲートを回し直さない）が赤。
# 変異検出: hook の in-flight 判定ブロックを削除すると release-runtime（進行中は再確認を出さない）が赤。
# 変異検出（2 巡目のレビュー対応。2026-09-24 実測）:
# 変異検出: preflight の未 push sync commit の push を外すと release-runtime（公開 push の失敗から回復しない）が赤。
# 変異検出: sync 段の GATE_OK 要求を外すと release-runtime（--only sync が gate を素通り）が赤。
# 変異検出: report 段の footer 非 green で止める行を外すと release-runtime が赤。
# 変異検出: 版幅を「修正があれば patch」へ戻すと release-runtime（混在分類が minor にならない）が赤。
# 変異検出: preflight の書きかけ巻き戻しを外すと release-runtime（bump 後 / footer 更新後の失敗から再開できない）が赤。
# 変異検出: in-flight 印の取得（writer）を外すと release-runtime（ゲート走行中に印が見えない）が赤。
# 変異検出: hook の stale 時の粒度判定ガードを外すと release-runtime（stale な drift で日次待ちに倒れる）が赤。
# 変異検出: tag 段の remote main 一致要求を外しても release-runtime は緑（preflight が先に push するため多重防御）。(7) の針が赤。
# 変異検出（3 巡目。破壊的な自動復旧をやめ fail-closed へ。2026-09-24 実測）:
# 変異検出: preflight で acquire_in_flight を復旧の後ろへ動かすと (7) の順序針と release-runtime（live 印 + dirty tree で作業ツリーに触る）が赤。
# 変異検出: 書きかけの一致判定（writing_match）を常に一致へ倒すと release-runtime（利用者の編集・公開側の未追跡を消す）が赤。
# 変異検出: try_reclaim が判定後に token を読み直す形へ戻すと (7) の lib 針が赤（判定と読み直しの割り込みは runtime で決定的に作れないので静的に固定する。release-runtime は判定後の取り直しで rename 回収が失敗することを固定する）。
# 変異検出: gate 段の週次 CI 再評価を記録の照合より後ろへ戻すと release-runtime（healthy でなくなった再実行を全件で回さない）が赤。
# 変異検出: 完走サマリーの要求を外すと release-runtime（空出力・会計行欠落を緑と読む）が赤。
# 変異検出: ローカルタグの commit 照合を外すと release-runtime（古いローカルタグを公開する）が赤。
# 変異検出: tag 段の require_gate_ok を外すと release-runtime（--only tag が gate を素通り）が赤。
# 変異検出（リリース初回実運用の摩擦。2026-09-24 実測）:
# 変異検出: dry-run の prepare で模擬した再判定が OK でないときの停止を外すと release-runtime（dry-run が ATTRIBUTION_DRIFT を予測しない）が赤。
# 変異検出: 停止文の次の一手から --resume-with-edits を外す（旧文面へ戻す）と release-runtime（停止文が再開の設計と噛み合わない）が赤。
# 変異検出: --resume-with-edits の採用で prepare の書き込み先以外の変更を止める行を外すと release-runtime（判別できない状態を採用する）が赤。
# 変異検出: 採用の印（ADOPTED=1）を立てないと release-runtime（直した内容から再開できない）が赤。
# 変異検出: 採用した記録（adopted=1）を自動巻き戻しの対象から外す照合を消すと release-runtime（付けない再実行が直した内容を戻す）が赤。
# 変異検出: dry-run の同期差分を公開側 clone の作業ツリーとの rsync 比較へ戻すと release-runtime（origin/main 基準・内容差分だけ）が赤。
#
# 変異検出（ff-media-toolkit の既定 skip。Issue `#1904`。2026-09-25 実測）:
# 変異検出: 許容表から render-smoke の opt-in 行を消すと (7) の針と release-runtime（render-smoke の skip で止まる）が赤。
# 変異検出: 許容表へ typecheck の環境 skip 行を足すと (7) の禁止針が赤（release-runtime は typecheck skip で止まらなくなり赤）。
# 変異検出: SKIP_HINTS の照合ループを消すと (7) の針と release-runtime（停止文が ff-media.sh setup を名指ししない）が赤。
# 変異検出: 照合の case を外して全ヒントを無条件に足すと release-runtime（codex の未知 skip の停止文に setup が混じる）が赤。
# 変異検出: 許容表へ語尾を変えた typecheck 行（`…行いません（`）を足すとブロック内照合の針が赤（2026-09-25 実測）。
# 変異検出: SKIP_HINTS へ `|` の無い要素を足すと要素形の針が赤。
# 空振り検出: footer 分類器の成功状態照合を削除すると footer-reuse-runtime の empty / identical ケースが赤（2026-09-26 実測 exit 1）。内容証明なしの exit 0 は採用しない。
# 空振り検出: FF_SYNC_SHA_SKILL へ存在しないパスを与えると (対象解決) が赤になる。明示指定の不在を skip へ倒さないため、実測は exit 1（○ skip ではない）。
# 空振り検出: FF_SYNC_SHA_RELEASE_SCRIPT へ存在しないパスを与えると (対象解決) が赤になる（実測 exit 1）。リリーススクリプトを空ファイルへ差し替えると (7) の全針と release-runtime が赤になる。
# 空振り検出: 検査対象を空ファイルへ差し替えると (1〜3 / 5 / 6 の全針) が赤になる。0 件一致を「不足なし」へ倒さないことの実測。
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

# リリーススクリプト（手順 0b / 5 / 8 の本体。ADR-063）の検査対象。FF_SYNC_SHA_RELEASE_SCRIPT で
# 差し替えられる（変異実測用）。SSOT なのに不在・明示指定の不在はいずれも失敗（skip へ倒さない）。
RELEASE_SCRIPT="${FF_SYNC_SHA_RELEASE_SCRIPT:-$REPO_ROOT/scripts/release-dev-toolkit.sh}"
if [[ -n "${FF_SYNC_SHA_RELEASE_SCRIPT:-}" ]]; then
  echo "⚠ FF_SYNC_SHA_RELEASE_SCRIPT でリリーススクリプトの検査対象を差し替えています: $RELEASE_SCRIPT" >&2
fi
if [[ ! -f "$RELEASE_SCRIPT" ]]; then
  echo "✗ 検査対象のリリーススクリプトがありません: $RELEASE_SCRIPT" >&2
  exit 1
fi
POST_MERGE_HOOK="$REPO_ROOT/.claude/hooks/post-merge-dev-toolkit-sync.sh"

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

# リリーススクリプト側の針。対象だけが違う同型の helper。
release_contains() {
  local needle="$1" label="$2" rc=0
  grep -qF -- "$needle" "$RELEASE_SCRIPT" || rc=$?
  case "$rc" in
    0) ok "$label" ;;
    1) bad "${label}（不足: ${needle}）" ;;
    *) bad "${label}（grep が失敗 rc=${rc}）" ;;
  esac
}
release_contains_exactly() {
  local needle="$1" want="$2" label="$3" got
  got="$(grep -cF -- "$needle" "$RELEASE_SCRIPT" || true)"
  if [[ "$got" == "$want" ]]; then
    ok "$label"
  else
    bad "${label}（期待 ${want} 箇所 / 実際 ${got} 箇所: ${needle}）"
  fi
}
release_not_contains() {
  local needle="$1" label="$2" rc=0
  grep -qF -- "$needle" "$RELEASE_SCRIPT" || rc=$?
  case "$rc" in
    0) bad "${label}（禁止パターンが存在: ${needle}）" ;;
    1) ok "$label" ;;
    *) bad "${label}（grep が失敗 rc=${rc}）" ;;
  esac
}
release_line_of() {
  awk -v pat="$1" 'index($0, pat) { print NR; exit }' "$RELEASE_SCRIPT"
}
# 行全体の完全一致（段の呼び出し行のように、部分一致だと定義や説明に吸われる針に使う）
release_exact_line_of() {
  awk -v pat="$1" '$0 == pat { print NR; exit }' "$RELEASE_SCRIPT"
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
# 実行面（コード行）はリリーススクリプトの gate 段が持つ（ADR-063）。SKILL は段を名指しで呼ぶ。
contains 'scripts/release-dev-toolkit.sh --only gate' \
  "手順 0b がリリーススクリプトの gate 段を名指しで呼ぶ（本体の所在）"
release_contains 'capture bash "$HEALTH_SCRIPT"' \
  "gate 段が週次 CI の状態確認を踏む（selftest 層の担保。ADR-039）"
release_contains 'if has_line "$HEALTH_OUT" "HEALTH=healthy"; then' \
  "高速モードへ受理するのは HEALTH=healthy だけ（行単位の完全一致。warming-up / running を成功実績と読まない）"
release_contains '⚠ 週次 CI の成功実績を確認できない（HEALTH が healthy 以外）— この回は全件実行で代替する' \
  "healthy 以外の回に全件代替へ倒すことが明記されている"
release_contains_exactly 'FF_RUN_ALL_FULL=1 bash "$RUN_ALL" >"$gate_out" 2>&1 || gate_rc=$?' 1 \
  "healthy 以外の回の全件代替コマンドが gate 段の 1 箇所にある"
release_contains 'if [[ "$gate_mode" == fast ]]; then' \
  "ローカル実行のモードが週次 CI の状態から導出される"
release_contains 'run-all が失敗した — 同期しない' \
  "run-all が非 0 のとき同期しないことが明記されている"
contains '非 0 なら**同期しない**' \
  "ゲートが非 0 のとき同期しないことが明記されている"
# healthy の回にも CRON_NOTE= を報告する規約。ここが消えると、判定を据え置いた分の
# 可視性が消費側で失われ、実害（20 行に埋もれて 2 週間気づかれない）が戻る。
contains 'CRON_NOTE=` が出ていれば、同期は続行してよいが週次 CI の異常として別途ユーザーへ報告する' \
  "healthy の回でも赤い cron をユーザーへ報告することが明記されている"
contains '同じ 2 点を無条件に回し直す' \
  "収束周回でも週次 CI と run-all を省略しない"
contains 'footer 差分でも省略しない' \
  "収束段落が footer 差分での週次 CI と run-all 省略を禁じている"
release_contains '検査した tree と HEAD の tree が一致しない' \
  "dirty なまま得た green を「HEAD を検査済み」と扱わない"

# 手順 0b の部分 skip 許容条件。散文が `checks-skipped` 非 0 を「未実行の検査がある」と
# 書くだけで**続行するのか中断するのか**を規定せず、判定コード片は GATE_RC しか見て
# いなかった。その状態では散文は実行面で空文になり、実測 3 回とも内訳を個別 suite の
# 再実行で調べ直したうえで「既存実績と同じ内訳」と判断して続行していた（判断の再演）。
# かつ全 suite が対象の 0b では adapter-sandbox-contract の grok enum 非公表が恒久的に
# 残るため `checks-skipped: total=0` は達成不能で、手順 8（対象 2 suite。total=0 が現に
# 成立する）の基準をそのまま持ち込むことはできない。許容表・表で判定する分岐・環境 skip
# を許さない旨の 3 つを固定する（どれが消えても「非 0 を内訳なしで通す」へ戻る）。
# 判定コード片は `bash -e <<'EOF' … EOF` で渡す規約（git-workflow.md）に従って set -e 下で
# 走る。`cmd` の直後に `GATE_RC=$?` と書くと run-all が非 0 で終わった時点でシェルごと落ち、
# 下の中断理由と次の一手が表示されない（緑と赤で出力の質が変わる）。捕捉形を固定する。
# 針はコード行そのものを指す。`|| GATE_RC=$?` だけだと、同じ綴りを含む直上の説明コメントで
# 満たされてしまい、コード側を元の `GATE_RC=$?` へ戻しても緑のまま通る（実測）。
release_contains 'bash "$RUN_ALL" >"$gate_out" 2>&1 || gate_rc=$?' \
  "gate 段が run-all の終了コードを落ちない形（|| gate_rc=\$?）で捕捉する"
release_contains 'ALLOWED_SKIP_PATTERNS=(' \
  "gate 段が続行してよい部分 skip の正本を配列として持つ"
release_contains 'done <<<"$(awk '"'"'/^[[:space:]]+○ skip(:|$)/'"'"' "$gate_out")"' \
  "gate 段が run-all 出力の部分 skip 理由行を走査する（終了コードだけを見て許容表を空文にしない）"
release_contains '許容表に無い部分 skip がある' \
  "許容表に無い部分 skip で中断することが判定コードにある"
contains '**環境 skip は許容しない**' \
  "外部 CLI 不在などの環境 skip を続行させないことが明記されている"
contains '`total=0` を要求しない理由（手順 8 との非対称は意図）' \
  "0b が total=0 を要求しない理由と、手順 8 へ波及させない旨が明記されている"
# 許容表の各要素。1 行消しても配列の形は保たれるため、要素単位でも固定する（消えた要素の
# skip はその場で中断側へ倒れるので安全側だが、「なぜ止まるのか」が手順書から消える）。
release_contains "'検査 B/C は免除（件数ゲートが担保'" \
  "許容表に設計上の免除（plugin-description-enumeration）がある"
release_contains "'estimation カテゴリファイルは未作成'" \
  "許容表にデータ未到来（effort-contract）がある"
release_contains "'enum 照合は対象外（grok-cli は受け付ける値の集合を公表していない）'" \
  "許容表に上流仕様による照合不能（adapter-sandbox-contract）がある"
release_contains "'に対応する compare リンク行が無いためスキップ（公開タグ前の開発周期では正常'" \
  "許容表に同期サイクル内で解消するもの（changelog-public-tags）がある"
# ff-media-toolkit の既定 skip 2 件（Issue `#1904` / ADR-069）。ラッパーが子 runner の出力を写すため、子の suite 単位 skip が
# 親では部分 skip になる。opt-in の render-smoke は構造的 skip として表に載せ、setup 前の typecheck は環境 skip として
# 表に載せず、停止文の次の一手だけを名指しする（SKIP_HINTS）。表へ typecheck を足す退行と、ヒント表ごと消す退行の両方を止める。
release_contains "'FF_MEDIA_RENDER=1 が未設定のため実レンダリングを行いません'" \
  "許容表に明示 opt-in の実レンダリング（ff-media-toolkit render-smoke）がある"
# 配列ブロック（`NAME=(` 〜 行頭 `)`）の中だけを見る。ファイル全体の grep だと、SKIP_HINTS の要素（同じ理由文 + `|`）や
# 語尾を変えた要素（`…行いません（`）で禁止針が外れる
release_block() { awk -v n="$1" '$0 ~ ("^" n "=\\($") {f=1; next} f && /^\)$/ {exit} f' "$RELEASE_SCRIPT"; }
_allowed_block="$(release_block ALLOWED_SKIP_PATTERNS)"
if [[ -z "$_allowed_block" ]]; then
  bad "許容表のブロックを切り出せない（配列の形が変わった）"
elif [[ "$_allowed_block" == *'node_modules が無いため型検査を行いません'* ]]; then
  bad "setup 前の typecheck（環境 skip）が許容表の要素になっている"
else
  ok "setup 前の typecheck（環境 skip）を許容表の要素にしていない（ブロック内照合）"
fi
release_contains 'SKIP_HINTS=(' \
  "許容表に無い skip の理由行ごとに次の一手を名指しするヒント表がある"
release_contains "'node_modules が無いため型検査を行いません|bash plugins/ff-media-toolkit/scripts/ff-media.sh setup" \
  "ヒント表が ff-media の setup 前の typecheck skip に ff-media.sh setup を名指しする"
# ヒント表の要素は `<理由>|<案内>` の形（`|` の無い要素は照合側が飛ばすので、黙って効かない要素を表に残さない）
_hint_elems="$(release_block SKIP_HINTS | grep -E "^[[:space:]]*'" || true)"
_hint_bad="$(printf '%s\n' "$_hint_elems" | grep -vF '|' | grep -c . || true)"
if [[ -z "$_hint_elems" ]]; then
  bad "ヒント表の要素を切り出せない（空か配列の形が変わった）"
elif [[ "$_hint_bad" -ne 0 ]]; then
  bad "ヒント表に \`|\` の無い要素がある（照合されない）: ${_hint_bad} 件"
else
  ok "ヒント表の全要素が <理由>|<案内> の形である"
fi
release_contains 'for _pat in ${SKIP_HINTS[@]+"${SKIP_HINTS[@]}"}; do' \
  "gate 段が未知の skip 行をヒント表と照合する（bash 3.2 の set -u で空表を unbound にしない展開形）"
release_contains '[[ "$_pat" == *"|"* ]] || continue' \
  "gate 段が \`|\` の無いヒント要素を照合せず飛ばす"
# 表・ヒントの理由文は ff-media-toolkit の suite が実際に出す文言の部分文字列でなければ効かない（文言が変わると gate は
# 再び毎回止まる）。実体のソースに同じ部分文字列があることを固定する（実体が無い木では赤 — この suite は SSOT 専用）
for _pair in \
  "render-smoke|FF_MEDIA_RENDER=1 が未設定のため実レンダリングを行いません" \
  "typecheck|node_modules が無いため型検査を行いません"; do
  _src="$REPO_ROOT/plugins/ff-media-toolkit/tests/${_pair%%|*}/verify.sh"
  if [[ -f "$_src" ]] && grep -qF -- "${_pair#*|}" "$_src"; then
    ok "ff-media-toolkit/tests/${_pair%%|*} の実出力に表の理由文がある"
  else
    bad "ff-media-toolkit/tests/${_pair%%|*} の実出力に表の理由文が無い（suite 不在または文言変更）: ${_pair#*|}"
  fi
done
contains '| `ff-media-toolkit/tests/render-smoke`: FF_MEDIA_RENDER=1 が未設定 | 明示 opt-in |' \
  "手順 0b の許容表に render-smoke の opt-in skip の行がある"
contains '`ff-media-toolkit/tests/typecheck` の `node_modules` 不在' \
  "手順 0b が ff-media の setup 前の typecheck を環境 skip（許容しない）として名指ししている"
# 旧方式（ADR-034 決定 2 + Issue #830 の green 再利用機構）の復活禁止。針は散文を
# 誤検出しない最小限の広さにする — 現 SKILL の散文言及は backtick 内の `FULL_GATE_SHA`
# （代入の `=` を含まない）だけで、check-full-gate-reuse への言及は無い（実測）。
not_contains 'FULL_GATE_SHA=' \
  "全件 green SHA をシェル変数へ控える旧方式が復活していない"
not_contains 'check-full-gate-reuse' \
  "廃止した green 再利用判定の呼び出しが復活していない"

# 手順 8 の限定ゲート（2 suite / 4 観点。旧 changelog-links + changelog-attribution は
# changelog-public-tags へ、版の一致と公開参照の境界は changelog-contract へ統合済み）は、footer の release
# コミットを develop へ直 push する**前**に footer 段が回す（ADR-063 で footer PR を廃止）。2 suite の
# 呼び出しが 1 箇所にあり、suite 全体の skip も部分 skip も成功と読まないことを固定する。
release_contains_exactly 'for t in "$PUBLIC_TAGS_VERIFY" "$CONTRACT_VERIFY"; do' 1 \
  "限定ゲートの 2 suite（changelog-public-tags / changelog-contract）が footer 段の 1 箇所にある"
release_contains "'○ skip' \"\$CAP_FILE\"; then" \
  "限定ゲートは skip / 部分 skip / 非 0 を成功と読まない（checks-skipped: total=0 と同じ基準）"
contains '**commit の前に限定ゲート（2 suite / 4 観点）を通す**' \
  "手順 8 が限定ゲートを footer の commit 前に置くと明記している"
contains 'update-dev-toolkit-changelog-footer.sh --public-checkout' \
  "手順 8 の footer writer が実行可能 helper へ一本化されている"
release_contains 'bash "$FOOTER_SCRIPT" --public-checkout "$PUBLIC"' \
  "footer 段が footer helper を呼ぶ（footer を手で書き換えない）"
# 準備と footer 追従は定型 PR を作らず release: の単独コミットを直 push する（ADR-063）。
release_contains 'RELEASE_PREFIX="release: "' \
  "リリーススクリプトの直 push は release: prefix の単独コミットに限る"
release_not_contains 'gh pr create' \
  "リリーススクリプトは PR を作らない"
release_not_contains 'push -f' \
  "リリーススクリプトは force push しない"
release_not_contains '--force' \
  "リリーススクリプトは --force を使わない"
contains '）は作らず、`release: CHANGELOG 比較リンクを vX.Y.Z へ追従` の単独コミット' \
  "手順 8 が footer PR を作らないと明記している"

# ── 2. 順序（行番号の単調増加） ──────────────────────────────────────────────
L_READ="$(line_of 'SYNC_SRC_SHA=$(cat "$(git -C "$PUBLIC" rev-parse --absolute-git-dir)/ff-sync-src-sha"')"
L_SYNC="$(awk '$0 == "scripts/sync-dev-toolkit-to-public.sh --target \"$PUBLIC\"" { print NR; exit }' "$SKILL")"
L_GUARD="$(line_of 'if [ -n "${SYNC_SRC_SHA:-}" ] && [ "$(git rev-parse HEAD)" = "$SYNC_SRC_SHA" ]; then')"
L_COMMIT="$(line_of 'git -C "$PUBLIC" commit -m "sync: ')"
# SKILL 側のゲートのアンカーは手順 0b の段呼び出し（行頭一致。手順 R の散文中の言及に吸われない）
L_GATE="$(awk 'index($0, "scripts/release-dev-toolkit.sh --only gate") == 1 { print NR; exit }' "$SKILL")"

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
# 済んでいる）。手動手順の文書順（手順 0b の段呼び出し < 手順 3 の同期）と、スクリプトの
# 実行順（下の (7)）の両方で固定する。
assert_order "${L_GATE}" "${L_SYNC}" \
  "順序: 定期実行点ゲート（手順 0b）が同期実行（手順 3）より前" \
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

# runtime の終了コードと stderr から「環境都合の未検証」と「退行」を決める規則。本番経路と
# 下の検査が同じ関数を通るようにする — rsync のあるホストでは本番経路が skip 分岐を通らない
# ため、関数を分けると「rc=3 を通常の失敗へ落とす」退行を誰も検出できない。
# stdout: 部分 skip の理由（空なら skip ではない）/ 戻り値: 0=想定内, 1=退行として扱う
classify_src_sha_result() { # $1: runtime の rc / $2: stderr のファイル
  local rc="$1" err="$2"
  [[ "$rc" -eq 0 ]] && return 0
  # rc だけで skip に振り分けない: runtime は set -euo pipefail + trap で内側の rc を
  # そのまま返すので、将来別の検査が 3 で落ちたときに緑の skip へ化ける。
  if [[ "$rc" -eq 3 ]] && grep -q 'rsync がありません' "$err"; then
    printf '%s\n' 'rsync が無いため同期の実挙動（記録と手順 4 の実行）を検証していない — apt 等で rsync を導入して再実行する'
    return 0
  fi
  return 1
}

_src_sha_rc=0
_src_sha_err="$(mktemp "${TMPDIR:-/tmp}/sync-sha-err.XXXXXX")"
bash "$SCRIPT_DIR/src-sha-runtime.sh" "$SYNC_SCRIPT_UNDER_TEST" "$SKILL" 2>"$_src_sha_err" || _src_sha_rc=$?
_src_sha_skip=""
_src_sha_cls=0
_src_sha_skip="$(classify_src_sha_result "$_src_sha_rc" "$_src_sha_err")" || _src_sha_cls=$?
if [[ "$_src_sha_cls" -ne 0 ]]; then
  bad "同期元 SHA の受け渡しの実行契約が壊れている (rc=${_src_sha_rc})"
  sed 's/^/    | /' "$_src_sha_err" >&2
elif [[ -n "$_src_sha_skip" ]]; then
  # インデント付きの ○ skip は run-all が checks-skipped へ別勘定する印。suite 全体の
  # skip とは別で、何を測っていないかが summary に名前で残る（Issue #1427）。
  echo "  ○ skip: ${_src_sha_skip}"
else
  ok "同期元 SHA の記録と手順 4 の実行が、別プロセス・HEAD 移動・記録不在を区別する"
fi
rm -f "$_src_sha_err"

# 振り分けの規則そのものを固定する。rsync のあるホストでは本番経路が skip 分岐を通らない
# ので、ここが無いと「rc=3 を通常の失敗へ落とす」「理由を問わず skip にする」のどちらの
# 退行も検出されないまま緑になる。
_cls_err="$(mktemp "${TMPDIR:-/tmp}/sync-sha-cls.XXXXXX")"
printf 'rsync がありません（同期の実挙動を検証できない）\n' >"$_cls_err"
_cls_out=""; _cls_rc=0
_cls_out="$(classify_src_sha_result 3 "$_cls_err")" || _cls_rc=$?
if [[ "$_cls_rc" -eq 0 && "$_cls_out" == *"rsync が無いため"* ]]; then
  ok "振り分け: 理由が rsync 不在の rc=3 は部分 skip の理由を返す（呼び出し元が ○ skip を出せる）"
else
  bad "振り分け: rsync 不在の rc=3 が部分 skip にならない (rc=${_cls_rc} out=${_cls_out})"
fi
printf '記録された SHA が同期内容と一致しない（退行）\n' >"$_cls_err"
_cls_rc=0
classify_src_sha_result 3 "$_cls_err" >/dev/null || _cls_rc=$?
if [[ "$_cls_rc" -ne 0 ]]; then
  ok "振り分け: 理由の一致しない rc=3 は退行として扱う（環境都合の skip に化けない）"
else
  bad "振り分け: 理由を問わず rc=3 を skip にしている（退行が緑で通る）"
fi
_cls_rc=0
_cls_out="$(classify_src_sha_result 0 "$_cls_err")" || _cls_rc=$?
if [[ "$_cls_rc" -eq 0 && -z "$_cls_out" ]]; then
  ok "振り分け: rc=0 は skip でも失敗でもない"
else
  bad "振り分け: 成功が skip / 失敗に化けている (rc=${_cls_rc} out=${_cls_out})"
fi
rm -f "$_cls_err"

# 環境都合（rsync 不在）と退行を runtime が終了コードで区別し続けること。ここが 1 に
# 戻ると、rsync の無いホストで「実装が壊れている」と読める赤が出る。不在は PATH を
# 絞らずシーム（SYNC_SHA_RSYNC_BIN）で作る — PATH を絞る形は fixture が要る実体の
# 取りこぼしが rsync 不在と区別できない別の失敗に化け、検査が不安定になる。
_no_rsync_err="$(mktemp "${TMPDIR:-/tmp}/sync-sha-norsync.XXXXXX")"
_no_rsync_rc=0
SYNC_SHA_RSYNC_BIN=/nonexistent/ff-rsync-absent \
  bash "$SCRIPT_DIR/src-sha-runtime.sh" "$SYNC_SCRIPT_UNDER_TEST" "$SKILL" \
  >/dev/null 2>"$_no_rsync_err" || _no_rsync_rc=$?
if [[ "$_no_rsync_rc" -eq 3 ]] && grep -q 'rsync がありません' "$_no_rsync_err"; then
  ok "rsync 不在を専用の終了コード 3 と理由の名指しで返す（退行の非 0 と区別でき、部分 skip へ振り分けられる）"
else
  bad "rsync 不在が終了コード 3 + 理由で返らない (rc=${_no_rsync_rc}) — 環境都合と退行が同じ赤に潰れる"
  sed 's/^/    | /' "$_no_rsync_err" >&2
fi
rm -f "$_no_rsync_err"

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

# ── 5. 並行セッションの実測（ソースリポジトリの観測台帳 OBS-014 の昇格 / OBS-138）─
# 手順 0a の静止確認は `gh pr list` の open PR とマージ間隔しか見ず、同じ作業ツリーで
# 動く別セッション（untracked ファイル・別ブランチへの checkout）を検出しない
# （OBS-014）。検出の判定基準（期待値との照合）とフェーズ境界での再測・破棄・中断が
# 骨抜きにされていないかも併せて検出する。手順 4 の統合ブランチ直 push は `-q` を
# 付けると `Everything up-to-date` の無音成功を見逃す（OBS-138）。いずれも文言の
# 消失を検出する針。
contains 'git worktree list --porcelain' \
  "手順 0a が並行セッション実測に git worktree list --porcelain を使う"
contains '期待値は `git branch --show-current` が `develop`、`git worktree list --porcelain` の本ツリー行の `branch` フィールドが develop ブランチを指している、`git status --porcelain --untracked-files=all` が空の 3 点で、いずれかが異なれば検出とみなす' \
  "手順 0a が検出の判定基準（期待値との照合）を明記している"
contains '手順 0b / R / 1〜6 の各手順に入る直前にも `git branch --show-current` と `git worktree list` を再測し、ブランチ・worktree・status のいずれかが着手時と変わっていたら、そのフェーズの結果を破棄して中断し' \
  "手順 0a がフェーズ境界での再測と破棄・中断の対応を明記している"
contains '統合ブランチ（公開側 `main`）への直 push は `-q` を付けず、出力の `-> main` を実測してから次へ進む' \
  "手順 4 の統合ブランチ直 push が -q 不使用と -> main の実測を明記している"
contains 'push 出力に `-> main` が無く `Everything up-to-date` のみのときは、`git rev-parse HEAD` と `git ls-remote origin main` の SHA を照合し' \
  "手順 4 の Everything up-to-date 分岐が SHA 照合による不一致判定を明記している"

# ── 6. 同期サイクルの in-flight 判定（OBS-044 / `#1707`）と Release 反映遅れ（OBS-104 / `#1723`）─
# 手順 0a の静止確認は open PR と直近マージ間隔しか見ないため、別セッションが準備 PR の
# ゲートを回している「もっとも衝突しやすい時間帯」を静止と読む。手順 7 は逆に、手順 6 が
# 作成した直後の Release 一覧を判定に使うと GitHub API の反映遅れで偽の取りこぼしを出す。
# どちらも「手順はあるが前提にしている状態が書かれていない」型で、文言の消失を検出する針。
echo "-- 手順 0a: 同期サイクル in-flight の判定 --"
contains_exactly '準備 PR のゲート実行中は open PR が無くマージも止まる' 1 \
  "手順 0a が open PR / マージ間隔だけでは検出できない時間帯を明記している"
contains_exactly '(a) 公開側の直近 sync commit が `WINDOW_MIN` 以内、(b) footer 追従 PR（`chore/#163-*`）が直近 sync commit より後にマージされている（収束ラウンドが未実施）' 1 \
  "手順 0a の in-flight 判定が直近 sync commit と footer 追従 PR の 2 材料を持つ"
contains_exactly '誰も同期していない状態では直近 sync が `WINDOW_MIN` より古く footer も sync より前になるので、**偽陽性で毎回止まることはない**' 1 \
  "手順 0a の in-flight 判定が偽陽性で毎回止まらないことを明記している"
contains_exactly '別セッションが初回の準備 PR ゲートを回している段階（sync commit も footer PR もまだ無い）は材料が存在せず検出できない' 1 \
  "手順 0a が in-flight 判定の適用範囲（痕跡が残る前は検出できない）を明記している"
contains_exactly '判定材料が 1 つでも取れなければ `NG` を出して中断する。**値を出さないことが契約の実装**' 1 \
  "手順 0a が材料欠落時に値を出さず中断すると明記している（fail-open の閉塞）"
contains_exactly 'IN_FLIGHT=no' 3 \
  "手順 0a の in-flight 判定が機械可読な IN_FLIGHT 値で出る（初期化・出力・判定の 3 箇所）"
contains_exactly 'レビュー走行（クロスモデルレビューは 25 分規模）を始める前にも行う' 1 \
  "手順 0a の静止確認がレビュー走行の開始前にも適用されると明記している"

echo "-- 手順 7: Release 反映遅れの吸収 --"
contains_exactly '**作成直後の一覧を判定に使わない**' 1 \
  "手順 7 が作成直後の Release 一覧を判定に使わないと明記している"
contains_exactly '`$RELS` は手順 6 で取得済みの一覧を**再利用しない**' 1 \
  "手順 7 が手順 6 の一覧を再利用しないと明記している"
contains_exactly 'if [ "$MISSING" != "v$VER" ]; then break; fi' 1 \
  "手順 7 が今回の版以外の混入で再取得ループを抜ける分岐を持つ"
contains_exactly '`$MISSING` が `v$VER` だけのまま上限（6 回 ≒ 30 秒）に達した = **中断してユーザーに報告する**' 1 \
  "手順 7 が再取得の上限到達で中断すると明記している"
contains_exactly '`$MISSING` に今回の版以外が含まれる = 過去の取りこぼし。再取得の収束を待たずに**中断してユーザーに報告する**' 1 \
  "手順 7 が過去の取りこぼしを待たずに中断すると明記している"
contains_exactly '手順 6 が「既存（何もしない）」だった回は `v$VER` が既に一覧へ載っているため `$MISSING` に現れず、再取得ループには入らない' 1 \
  "手順 7 が収束 sync（既存）の回に再取得ループへ入らないと明記している"
contains_exactly 'if [ -z "$TAGS" ] || [ -z "$RELS" ]; then UNVERIFIED=yes; break; fi' 1 \
  "手順 7 が片側空のまま再取得を繰り返さず判定不能として抜ける"
contains_exactly '`UNVERIFIED=yes` で抜けた = 判定不能。取りこぼしの有無を主張せず**中断してユーザーに報告する**' 1 \
  "手順 7 が判定不能を取りこぼし無しへ倒さないと明記している"

# ── 7. リリーススクリプト（手順 0b / 5 / 8 の本体。ADR-063）───────────────────
echo "-- (7) リリーススクリプトの段の順序と同期元 SHA の契約 --"
# 段の実行順（main の呼び出し行）。check → prepare → gate → sync → tag → release → footer → report。
# ゲートより前に同期・タグ・Release が来る並べ替えは、不可逆操作の後で検査する退行になる。
R_CHECK="$(release_exact_line_of 'stage_check')"
R_PREPARE="$(release_exact_line_of '[[ "$NEED_PREPARE" -eq 0 ]] || stage_prepare')"
R_GATE="$(release_exact_line_of '  stage_gate')"
R_SYNC="$(release_exact_line_of '  stage_sync')"
R_TAG="$(release_exact_line_of '  stage_tag')"
R_REL="$(release_exact_line_of '  stage_release')"
R_FOOTER="$(release_exact_line_of '  stage_footer')"
R_REPORT="$(release_exact_line_of 'stage_report')"
assert_order "$R_CHECK" "$R_PREPARE" "順序(7): リリース要否の判定が準備より前" "順序(7): 準備が判定より前にある"
assert_order "$R_PREPARE" "$R_GATE" "順序(7): 準備が定期実行点ゲートより前（ゲートは release コミットを含む HEAD を検査する。ADR-042）" "順序(7): ゲートが準備より前にある — 準備後の HEAD を検査しない退行"
assert_order "$R_GATE" "$R_SYNC" "順序(7): 定期実行点ゲートが同期より前" "順序(7): ゲートが同期より後ろにある — 不可逆操作の後で検査する退行"
assert_order "$R_SYNC" "$R_TAG" "順序(7): 同期がタグより前" "順序(7): タグが同期より前にある"
assert_order "$R_TAG" "$R_REL" "順序(7): タグが Release より前" "順序(7): Release がタグより前にある"
assert_order "$R_REL" "$R_FOOTER" "順序(7): Release が footer 追従より前" "順序(7): footer がタグ / Release より前にある"
assert_order "$R_FOOTER" "$R_REPORT" "順序(7): 健全性判定と footer 検査の報告が最後" "順序(7): report が footer より前にある"
# gate 段の中の順序: 週次 CI の状態確認 → run-all → 部分 skip の許容判定 → 緑の記録。
RG_HEALTH="$(release_exact_line_of '  weekly_health')"
RG_RUNALL="$(release_line_of 'bash "$RUN_ALL" >"$gate_out" 2>&1 || gate_rc=$?')"
RG_SKIP="$(release_line_of '許容表に無い部分 skip がある')"
RG_RECORD="$(release_line_of 'state_set GATE_OK "$head:$gate_mode"')"
assert_order "$RG_HEALTH" "$RG_RUNALL" "順序(7): 週次 CI の状態確認が run-all より前" "順序(7): 状態確認が run-all より後ろ — 中断点が不可逆操作へ近づく退行"
assert_order "$RG_RUNALL" "$RG_SKIP" "順序(7): 部分 skip の許容判定が run-all より後" "順序(7): 許容判定が run-all より前 — 判定材料が無い"
assert_order "$RG_SKIP" "$RG_RECORD" "順序(7): 緑の記録が許容判定より後" "順序(7): 許容判定の前に緑を記録する退行"
release_contains_exactly 'require_gate_ok "' 3 \
  "不可逆段（sync / tag / release）は同じ HEAD で定期実行点ゲートが緑だった記録を要求する（--only で素通りさせない）"
release_contains "summary=\"\$(awk '/^suites: total=[1-9][0-9]* run=[1-9][0-9]* passed=[0-9]+ failed=0( |\$)/'" \
  "gate 段は run-all の完走サマリー（total > 0・failed=0）を要求する（空出力・途中の exit 0 を緑と読まない）"
release_contains '  acquire_in_flight
  resume_partial_write ssot' \
  "preflight は in-flight 印を取ってから書きかけの復旧へ進む（二重起動のプロセスが作業ツリーへ触らない）"
release_contains '[[ -n "$remote_main" && "$remote_main" == "$(git -C "$PUBLIC" rev-parse HEAD)" ]] \' \
  "tag 段は公開側 remote の main がローカル HEAD と一致するときだけタグを打つ（未 push の sync commit へ打たない）"
release_contains '  resume_partial_write public' \
  "preflight が公開側 clone への書きかけ（sync 段）を記録と照合してから進む"
release_not_contains 'reset --hard &&' \
  "公開側 clone を reset --hard で自動復旧しない"
release_not_contains 'clean -fd' \
  "公開側 clone を clean -fd で自動復旧しない"
release_contains 'ff_release_marker_release "$MARKER_DIR" "$MARKER_TOKEN"' \
  "in-flight 印の解放は自分の token と一致するときだけ行う（他の取得者の印を消さない）"
IN_FLIGHT_LIB="$(dirname "$RELEASE_SCRIPT")/lib/release-in-flight-functions.sh"
if [[ -f "$IN_FLIGHT_LIB" ]] && grep -qF -- 'token="$(_ff_marker_info_field "$info" token)"' "$IN_FLIGHT_LIB" \
  && grep -qF -- '[ "$(ff_release_marker_state "$dir" "$info")" = stale ] || return 1' "$IN_FLIGHT_LIB"; then
  ok "in-flight 印の回収 helper は 1 回読んだ info で残骸を判定し、同じ info の token で回収する（読み直さない）"
else
  bad "in-flight 印の回収 helper が判定と回収で info を読み直している、または lib が無い: $IN_FLIGHT_LIB"
fi
release_contains 'ff_release_marker_try_reclaim "$MARKER_DIR"' \
  "残骸の in-flight 印は、判定に使った token で rename（CAS 相当）回収する 1 つの helper を通す"
release_contains 'pub_ahead="$(git -C "$PUBLIC" rev-list --count origin/main..main)"' \
  "preflight が公開側の未 push の commit（前回の push 失敗の残り）を見る"
release_contains 'if [[ "${rec%%:*}" == "$head" && ( "${rec#*:}" == full || "$gate_mode" == fast ) ]]; then' \
  "gate 段は同じ HEAD の成功記録を既存条件で再利用する（footer child は別の内容証明を要求）"
release_contains 'if footer_gate_reusable "$rec" "$head"; then' \
  "public-layout の再利用には footer の内容証明関数を通す"
release_contains "has_line \"\$proof\" 'FULL_GATE_REUSE=CHANGELOG_FOOTER_ONLY' || return 1" \
  "空出力・異なる状態・分類不能を public-layout の再利用へ倒さない"
# sync 段: 同期元 SHA は同期スクリプトの記録から読み、HEAD と突合してから commit する（手順 4 と同じ契約）。
RS_SYNC="$(release_line_of 'bash "$SYNC_SCRIPT" --target "$PUBLIC" || stop')"
RS_READ="$(release_line_of 'src_sha="$(cat "$(git -C "$PUBLIC" rev-parse --absolute-git-dir)/ff-sync-src-sha" 2>/dev/null || true)"')"
RS_GUARD="$(release_line_of 'if [[ -z "$src_sha" || "$(git rev-parse HEAD)" != "$src_sha" ]]; then')"
RS_COMMIT="$(release_line_of 'git -C "$PUBLIC" commit -q -m "sync: ${SSOT_NAME} $(git rev-parse --short "$src_sha") を反映"')"
assert_order "$RS_SYNC" "$RS_READ" "順序(7): 記録の読み取りが本同期より後" "順序(7): 記録を本同期より前に読む — 前回の記録を掴む退行"
assert_order "$RS_READ" "$RS_GUARD" "順序(7): HEAD 突合が記録の読み取りより後" "順序(7): 読む前に判定する退行"
assert_order "$RS_GUARD" "$RS_COMMIT" "順序(7): HEAD 突合が公開側 commit より前" "順序(7): 突合前に記録が確定する退行"
release_contains '[[ "$dry_text" == *"禁止パターン検査: クリア"* ]]' \
  "sync 段は dry-run の成功文字列を要求する（終了コードだけで通さない）"
# tag 段: リモートの実在（ls-remote の exit code）で分岐し、張り直さない。
release_contains 'git -C "$PUBLIC" ls-remote --exit-code --tags origin "refs/tags/v$1"' \
  "tag 段はリモートの実在を ls-remote の exit code で判定する"
release_contains 'is_semver3 "$VER" || stop' \
  "tag 段は vX.Y.Z の完全一致を確かめてからタグを打つ"
# footer 段: 限定ゲートを commit より前に通し、commit の後に push する。
RF_GATE="$(release_line_of 'limited_gate || stop')"
RF_COMMIT="$(release_line_of 'CHANGELOG 比較リンクを v${VER} へ追従" \\')"
assert_order "$RF_GATE" "$RF_COMMIT" "順序(7): footer の限定ゲートが release コミットより前" "順序(7): 限定ゲートの前に commit する退行"
# release 段（手順 7 と同じ吸収）: 今回の版だけが欠けている間は待ち、片側空は判定不能。
release_contains_exactly 'if [[ "$missing" != "v$VER" ]]; then break; fi' 1 \
  "release 段が今回の版以外の混入で再取得ループを抜ける"
release_contains_exactly 'if [[ -z "$tags" || -z "$rels" ]]; then unverified=yes; break; fi' 1 \
  "release 段が片側空のまま再取得を繰り返さず判定不能として抜ける"
release_contains '[[ "$latest" == "v$VER" ]] || stop' \
  "release 段が Latest の位置を直接検証する"

_release_rt_err="$(mktemp "${TMPDIR:-/tmp}/sync-sha-release.XXXXXX")"
_release_rt_rc=0
bash "$SCRIPT_DIR/release-runtime.sh" "$RELEASE_SCRIPT" "$POST_MERGE_HOOK" >"$_release_rt_err" 2>&1 || _release_rt_rc=$?
if [[ "$_release_rt_rc" -eq 0 ]]; then
  ok "リリーススクリプトの振る舞い（段の順序・dry-run・冪等な再開・止まるべき状態・粒度・hook の in-flight 抑止）: $(tail -n 1 "$_release_rt_err")"
else
  bad "リリーススクリプトの振る舞いが壊れている (rc=${_release_rt_rc})"
  sed 's/^/    | /' "$_release_rt_err" >&2
fi
rm -f "$_release_rt_err"

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ sync-sha-contract verify: $FAIL 件失敗 / $PASS 件成功" >&2
  exit 1
fi
echo "✓ sync-sha-contract verify: 全 $PASS 件 pass"
