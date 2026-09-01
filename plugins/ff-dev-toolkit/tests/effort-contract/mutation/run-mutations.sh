#!/usr/bin/env bash
#
# effort-contract の変異テスト: 各検査が本当に効いているかを実測する。
# 変異 → 赤を確認 → 復元 → 緑を確認（コントロール）。
#
# run-all.sh の既定一覧には載せない — 作業ツリーを一時的に壊すため、他の suite と
# 並行実行すると誤診を招く（CLAUDE.md の並行ビルド禁止と同じ理由）。
#
# 使い方: 作業ツリーが clean な状態で
#   bash plugins/ff-dev-toolkit/tests/effort-contract/mutation/run-mutations.sh
#
# 未コミットの変更があると復元（git checkout --）がそれごと巻き戻すため、冒頭で
# 機械的に拒否する（実測: 未コミット状態で回して偽陽性 8 件を踏んだ）。
#
# ACE カテゴリ本体（docs/08-knowledge/playbook/estimation.md）を対象にする変異は、
# 実ファイルを触らず FF_DOCS_REPO_ROOT で一時 root へ注入する。これは本リポジトリの
# -selftest 群の確立された作法で、(1) 破壊的な復元が要らない、(2) 現状 CI では対象
# 不在で skip されている検査 11・12 を実際に起動できる、の 2 つを同時に満たす。
#
set -uo pipefail
cd "$(cd "$(dirname "$0")/../../../../.." && pwd -P)"

V=plugins/ff-dev-toolkit/tests/effort-contract/verify.sh
CREATE=plugins/ff-dev-toolkit/skills/create-issue/SKILL.md
CLOSE=plugins/ff-dev-toolkit/skills/close-issue/SKILL.md
RETRO=plugins/ff-dev-toolkit/skills/retrospective/SKILL.md
TMPL=plugins/ff-dev-toolkit/docs-template/08-knowledge/PLAYBOOK.md
JUDGE=plugins/ff-dev-toolkit/scripts/check-issue-body-diff.sh
REPORT=plugins/ff-dev-toolkit/scripts/effort-report.sh
MUTDIR=plugins/ff-dev-toolkit/tests/effort-contract/mutation

for _dep in git python3 awk; do
  command -v "$_dep" >/dev/null 2>&1 || { echo "✗ ${_dep} が必要です" >&2; exit 2; }
done

# 未コミットの変更があると復元が巻き戻して偽陽性になる。散文で要求せず機械で止める
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "✗ 作業ツリーに未コミットの変更があります。変異の復元がそれごと巻き戻すため中止します" >&2
  git status --short >&2
  exit 2
fi

# sed -i は BSD と GNU で構文が違う。公開側の Linux CI へ配布される場所なので吸収する
sed_i() { local f="$1"; shift; sed "$@" "$f" > "${f}.mut" && mv "${f}.mut" "$f"; }

DETECTED=0; MISSED=0
run() { bash "$V" >/dev/null 2>&1; echo $?; }

probe() { # <ラベル> <変異対象ファイル（差分発生の確認用。none なら省略）> <復元コマンド…>
  local label="$1" target="$2"; shift 2
  # 変異が実際に効いたかを先に確認する。sed のアンカーがリファクタでずれると、
  # 変異は空振りなのに「見逃し」と報告され、存在しない穴を探しに行かせる偽アラームになる
  if [ "$target" != "none" ] && git diff --quiet -- "$target"; then
    echo "  ⚠️ 変異が適用されていない（アンカー不一致）: ${label}"
    MISSED=$((MISSED + 1))
    eval "$@"
    return
  fi
  local rc; rc="$(run)"
  if [ "$rc" != "0" ]; then echo "  ✅ 検出: ${label}"; DETECTED=$((DETECTED + 1))
  else echo "  ❌ 見逃し: ${label}"; MISSED=$((MISSED + 1)); fi
  eval "$@"
  [ "$(run)" = "0" ] || { echo "  ⚠️ 復元後に緑へ戻らない: ${label}"; MISSED=$((MISSED + 1)); }
}

echo "コントロール（変異なし）:"
[ "$(run)" = "0" ] && echo "  ✅ 緑" || { echo "  ❌ 変異前から赤。中止"; exit 1; }

echo "変異 1: create-issue のフィールド名を改名"
sed_i "$CREATE" -e 's/effort_ai_planned/ai_planned/g'
probe "フィールド名の改名（検査 1）" "$CREATE" "git checkout -- '$CREATE'"

echo "変異 2: close-issue 側だけ閾値を変える"
sed_i "$CLOSE" -e 's/1\.30/1.50/g'
probe "閾値の片側変更（検査 3）" "$CLOSE" "git checkout -- '$CLOSE'"

echo "変異 3: close-issue の fail-open 記述を削除"
sed_i "$CLOSE" -e '/ブロック不在のためスキップ/d'
probe "fail-open 記述の削除（検査 5）" "$CLOSE" "git checkout -- '$CLOSE'"

echo "変異 4: 判定器の marker_sanity から順序判定を外す（最重要）"
python3 "$MUTDIR/mut-marker-order.py"
probe "マーカー順序判定の除去（検査 7-f）" "$JUDGE" "git checkout -- '$JUDGE'"

echo "変異 5: 判定器から baseline の健全性検査を外す"
python3 "$MUTDIR/mut-baseline-guard.py"
probe "baseline 検査の除去（検査 7-h/i）" "$JUDGE" "git checkout -- '$JUDGE'"

echo "変異 6: 集計器の圧縮率を対でなく母集団全体の分母へ戻す"
python3 "$MUTDIR/mut-compression.py"
probe "圧縮率の分母汚染（検査 4）" "$REPORT" "git checkout -- '$REPORT'"

echo "変異 7: 集計器の p90 を単なる最大値へ置き換える"
python3 "$MUTDIR/mut-p90.py"
probe "nearest-rank の退化（検査 4b）" "$REPORT" "git checkout -- '$REPORT'"

echo "変異 8: 集計器の単位検査を緩めて時間単位を受理させる"
python3 "$MUTDIR/mut-unit.py"
probe "単位契約の緩和（検査 2/4）" "$REPORT" "git checkout -- '$REPORT'"

echo "変異 9: 集計器の重複キー検出を外す"
python3 "$MUTDIR/mut-dupkey.py"
probe "重複キーの last-wins 復活（検査 4）" "$REPORT" "git checkout -- '$REPORT'"

echo "変異 10: 配布テンプレ側の estimation 行だけ削除"
sed_i "$TMPL" -e '/^| `estimation`/d'
probe "カテゴリ語彙の片側削除（検査 8）" "$TMPL" "git checkout -- '$TMPL'"

echo "変異 11: create-issue から知見層の参照経路を削除"
sed_i "$CREATE" -e 's/`estimation` カテゴリ/カテゴリ/g'
probe "知見層の参照経路の削除（検査 9）" "$CREATE" "git checkout -- '$CREATE'"

echo "変異 12: retrospective から Kind: keep の帯を削除"
sed_i "$RETRO" -e 's/`Kind: keep`/`Kind: problem`/g'
probe "当たり帯の削除（検査 10）" "$RETRO" "git checkout -- '$RETRO'"

# --- 以下 2 件は実ツリーを触らず一時 root へ注入する（検査 11/12 の実起動） ---
inject_root() { # <estimation.md の中身を作る関数名> → 一時 root のパスを stdout
  local t; t="$(mktemp -d)"
  mkdir -p "$t/docs/08-knowledge/playbook"
  cp docs/08-knowledge/PLAYBOOK.md "$t/docs/08-knowledge/"
  "$1" > "$t/docs/08-knowledge/playbook/estimation.md"
  printf '%s\n' "$t"
}
run_in_root() { FF_DOCS_REPO_ROOT="$1" bash "$V" >/dev/null 2>&1; echo $?; }

probe_root() { # <ラベル> <期待: fail> <root>
  local label="$1" root="$2" rc
  rc="$(run_in_root "$root")"
  if [ "$rc" != "0" ]; then echo "  ✅ 検出: ${label}"; DETECTED=$((DETECTED + 1))
  else echo "  ❌ 見逃し: ${label}"; MISSED=$((MISSED + 1)); fi
  rm -rf "$root"
}

entry_with_pr_ref() {
  printf '# PLAYBOOK — 見積もり (estimation)\n\n## エントリ一覧\n\n'
  printf '<a id="ace-9999-1"></a>\n\n### ACE-9999-1: ダミー\n\n'
  printf '| Category | estimation | Origin | PR #1136 |\n| Date | 2026-09-01 |\n'
  printf '| Helpful | 0 | Harmful | 0 |\n| Status | active |\n\n'
  printf '本文の表にも書ける:\n\n| 条件 | 補正 |\n| ---- | ---- |\n| 注意 | PR #1140 の事例を見よ |\n\n---\n'
}
entries_over_limit() {
  printf '# PLAYBOOK — 見積もり (estimation)\n\n## エントリ一覧\n\n'
  local i=1
  while [ "$i" -le 21 ]; do
    printf '<a id="ace-9999-%d"></a>\n\n### ACE-9999-%d: ダミー\n\n' "$i" "$i"
    printf '| Category | estimation | Origin | PR #1136 |\n| Date | 2026-09-01 |\n'
    printf '| Helpful | 0 | Harmful | 0 |\n| Status | active |\n\n'
    printf 'ゲート新設を伴う見積もりは過小に出る。\n\n---\n\n'
    i=$((i + 1))
  done
}

echo "変異 13: estimation エントリの本文表へ PR 参照を混入（一時 root）"
probe_root "本文表への固有名の混入（検査 11）" "$(inject_root entry_with_pr_ref)"

echo "変異 14: estimation を上限超え（21 件・一時 root）"
probe_root "件数上限の超過（検査 12）" "$(inject_root entries_over_limit)"

echo
echo "----------------------------------------"
echo "  検出: ${DETECTED} / 見逃し: ${MISSED}"
[ "$MISSED" -eq 0 ] || exit 1
