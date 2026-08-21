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
# 「記録 SHA ≠ 同期内容」の実ミスマッチはオフラインの suite からは観測できない
# （公開 clone と実 sync の実行を要する）ため、機械検査の上限は**手順の文面**の
# 固定である。検査するのは次の 3 層:
#   1. 出現: SHA の記録・if 連結の HEAD 突合・控えた SHA からの採取・detached 退避・
#      同一シェル規定（HEAD からの再導出禁止）・fetch 失敗時の中断が存在する
#   2. 順序: 記録 → 同期実行 → 突合 → commit の行番号が単調増加している
#      （記録を同期の後ろへ動かす退行・突合を commit の後ろへ動かす退行の検出）
#   3. 禁止: ブランチ ref から SHA を採るコマンド置換（develop / origin/develop /
#      refs/heads/develop）が復活していない。commit 行そのものに `develop` を含む
#      SHA 式が無い
# 順序は行番号の単調性のみで、同一フェンス内であること・実行時の競合までは
# 主張しない（実行時の防波堤は手順 4 の if 連結突合）。
#
# skip の鍵は検査対象そのものではなく**リポジトリの同一性**（sync スクリプトの
# 存在。sync-forbidden-patterns と同じ判定軸）: 公開 checkout（スクリプト不在）は
# ○ skip、SSOT なのに SKILL が無い場合は red（fail-closed — 改名・移設で唯一の
# ゲートが黙って skip 化するのを防ぐ）。FF_SYNC_SHA_SKILL で検査対象を差し替え
# られる（変異実測用）が、明示指定が不在の場合は skip ではなく fail。
#
# needle を追加・変更したら、対象行だけを削除・移動する変異を手で当てて red に
# なることを確認する（docs-gates と同じ規則）。外部コマンド・一時領域は不要。
# read-only。bash 3.2 互換。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

SYNC_SCRIPT="$REPO_ROOT/scripts/sync-dev-toolkit-to-public.sh"
DEFAULT_SKILL="$REPO_ROOT/.claude/skills/sync-dev-toolkit/SKILL.md"

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

echo "== sync-dev-toolkit SHA 記録契約 =="

# ── 1. 出現 ──────────────────────────────────────────────────────────────────
contains 'SYNC_SRC_SHA=$(git rev-parse HEAD)' \
  "手順 3 が同期内容の SHA を HEAD から控える"
contains 'if [ -n "${SYNC_SRC_SHA:-}" ] && [ "$(git rev-parse HEAD)" = "$SYNC_SRC_SHA" ]; then' \
  "手順 4 が HEAD の不動と SYNC_SRC_SHA の存在を if 連結で突合する（set -e 非依存）"
contains 'git rev-parse --short "$SYNC_SRC_SHA"' \
  "手順 4 の commit メッセージが控えた SHA から採られる"
contains 'git checkout --detach origin/develop' \
  "他 worktree が develop を保持する場合の退避手順がある"
contains 'ref から SHA を採ると「同期していない SHA を反映済み」と記録し' \
  "退避時に HEAD 基準の記録が必須になる理由が明記されている"
contains 'HEAD から再導出してはならない' \
  "別シェル時は手順 3 からやり直す（再導出の禁止）が明記されている"
contains 'stale な origin/develop で続行しない' \
  "退避経路の fetch 失敗時に中断することが明記されている"

# ── 2. 順序（行番号の単調増加） ──────────────────────────────────────────────
L_RECORD="$(line_of 'SYNC_SRC_SHA=$(git rev-parse HEAD)')"
L_SYNC="$(awk '$0 == "scripts/sync-dev-toolkit-to-public.sh --target \"$PUBLIC\"" { print NR; exit }' "$SKILL")"
L_GUARD="$(line_of 'if [ -n "${SYNC_SRC_SHA:-}" ] && [ "$(git rev-parse HEAD)" = "$SYNC_SRC_SHA" ]; then')"
L_COMMIT="$(line_of 'git -C "$PUBLIC" commit -m "sync: ')"

if [[ -z "${L_RECORD}" || -z "${L_SYNC}" || -z "${L_GUARD}" || -z "${L_COMMIT}" ]]; then
  bad "順序検査のアンカーが欠落（record=${L_RECORD} sync=${L_SYNC} guard=${L_GUARD} commit=${L_COMMIT}）— 空振りは fail-closed"
else
  if [[ "${L_RECORD}" -lt "${L_SYNC}" ]]; then
    ok "順序: SHA の記録が同期実行より前（${L_RECORD} < ${L_SYNC}）"
  else
    bad "順序: SHA の記録が同期実行より後ろにある（${L_RECORD} >= ${L_SYNC}）— 動いた後の SHA を記録する退行"
  fi
  if [[ "${L_SYNC}" -lt "${L_GUARD}" ]]; then
    ok "順序: HEAD 突合が同期実行より後（${L_SYNC} < ${L_GUARD}）"
  else
    bad "順序: HEAD 突合が同期実行より前にある（${L_SYNC} >= ${L_GUARD}）— 競合窓を検査しない退行"
  fi
  if [[ "${L_GUARD}" -lt "${L_COMMIT}" ]]; then
    ok "順序: HEAD 突合が commit より前（${L_GUARD} < ${L_COMMIT}）"
  else
    bad "順序: HEAD 突合が commit より後ろにある（${L_GUARD} >= ${L_COMMIT}）— 突合前に記録が確定する退行"
  fi
fi

# ── 3. 禁止（ブランチ ref からの採取の復活） ────────────────────────────────
# コマンド置換の形に限定する（散文の説明や Common Mistakes 表への記載を誤検出
# しないため。復活が実害になるのはコマンド例の中だけ）。
not_contains '$(git rev-parse --short develop)' \
  "ブランチ ref（develop）から SHA を採るコマンド置換が無い"
not_contains '$(git rev-parse --short origin/develop)' \
  "ブランチ ref（origin/develop）から SHA を採るコマンド置換が無い"
not_contains 'refs/heads/develop' \
  "refs/heads/develop 経由の採取が無い"

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
