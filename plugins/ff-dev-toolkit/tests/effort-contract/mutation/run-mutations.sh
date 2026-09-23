#!/usr/bin/env bash
#
# effort-contract の変異テスト: 各検査が本当に効いているかを実測する。
# 変異 → 赤を確認 → 復元 → 緑を確認（コントロール）。
#
# 対象は判定器・集計器のロジックと、検査 11・12 を実際に起動する一時 root 注入だけに絞る。
# 文書の針（フィールド名・閾値・帯の語）を 1 つ消して赤を見る変異は、grep の針に対しては
# 必ず赤になるので何も測らない（Issue `#1824` で撤去した。retrospective-contract と同じ判断）。
# 変異の番号は撤去前の通し番号のまま（1〜3・10〜12 が欠番）。
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
JUDGE=plugins/ff-dev-toolkit/scripts/check-issue-body-diff.sh
REPORT=plugins/ff-dev-toolkit/scripts/effort-report.sh
WC_HOOK=plugins/ff-dev-toolkit/hooks/record-effort-wallclock.sh
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

echo "変異 7b: 集計器の分位点の切り上げを切り捨てへ戻す"
python3 "$MUTDIR/mut-percentile-floor.py"
probe "分位点の切り捨て化（検査 4b の p25 / p75）" "$REPORT" "git checkout -- '$REPORT'"

echo "変異 7c: 帯の判定を閉区間から開区間へ変える"
python3 "$MUTDIR/mut-band-edge.py"
probe "帯の端の取りこぼし（検査 4e）" "$REPORT" "git checkout -- '$REPORT'"

echo "変異 8: 集計器の単位検査を緩めて宣言の無い旧ブロックの時間単位を受理させる"
python3 "$MUTDIR/mut-unit.py"
probe "単位契約の緩和（検査 4/4f）" "$REPORT" "git checkout -- '$REPORT'"

echo "変異 8b: 旧 d ブロックの ×8 正規化を外す"
python3 "$MUTDIR/mut-unit-normalize.py"
probe "旧ブロックの正規化の欠落（検査 4/4f）" "$REPORT" "git checkout -- '$REPORT'"

echo "変異 8c: effort_unit: h のブロックの d 値を除外せず ×8 で合流させる"
python3 "$MUTDIR/mut-unit-mismatch.py"
probe "単位の食い違いの黙った合流（検査 4f）" "$REPORT" "git checkout -- '$REPORT'"

echo "変異 8d: 未配線の巡回数を (unavailable) でなく 0 で出す"
python3 "$MUTDIR/mut-unavailable.py"
probe "未計測と 0 の合流（検査 4g）" "$REPORT" "git checkout -- '$REPORT'"

echo "変異 8e: --issue-metrics の記録不在を (unmeasured) でなく 0 で出す"
python3 "$MUTDIR/mut-metrics-zero.py"
probe "記録不在の 0 化（検査 13a）" "$REPORT" "git checkout -- '$REPORT'"

echo "変異 8f: wall-clock hook が記録置き場を作れないとき止める"
python3 "$MUTDIR/mut-hook-failsoft.py"
probe "fail-soft の反転（検査 14d）" "$WC_HOOK" "git checkout -- '$WC_HOOK'"

echo "変異 8g: wall-clock の start を repo 列で絞らない"
python3 "$MUTDIR/mut-repo-filter.py"
probe "別リポジトリの同じ番号の混入（検査 13b）" "$REPORT" "git checkout -- '$REPORT'"

echo "変異 8h: バイト集計の 1 ファイル目判定を FNR == NR へ戻す"
python3 "$MUTDIR/mut-fnr.py"
probe "wallclock.tsv 不在でのバイトの読み落とし（検査 13e）" "$REPORT" "git checkout -- '$REPORT'"

echo "変異 8i: 読み込みバイトを wall-clock 実測済みの Issue だけで集計する"
python3 "$MUTDIR/mut-bytes-coupled.py"
probe "片側未計測でのバイトの取りこぼし（検査 4g）" "$REPORT" "git checkout -- '$REPORT'"

echo "変異 8j: start が無いときの reflog からの補いを外す"
python3 "$MUTDIR/mut-reflog-off.py"
probe "reflog fallback の欠落（検査 13f）" "$REPORT" "git checkout -- '$REPORT'"

echo "変異 8k: 空の単位宣言を旧ブロックとして読む"
python3 "$MUTDIR/mut-empty-unit.py"
probe "空の宣言の旧ブロック扱い（検査 4f）" "$REPORT" "git checkout -- '$REPORT'"

echo "変異 8l: Issue 番号抽出の # を任意に戻す"
python3 "$MUTDIR/mut-hash-optional.py"
probe "日付入りブランチの Issue 誤認（検査 14c）" "$WC_HOOK" "git checkout -- '$WC_HOOK'"

echo "変異 9: 集計器の重複キー検出を外す"
python3 "$MUTDIR/mut-dupkey.py"
probe "重複キーの last-wins 復活（検査 4）" "$REPORT" "git checkout -- '$REPORT'"

echo "変異 9b: 集計器の近傍判定をマーカー形の限定から ff-effort を含む全行へ戻す"
python3 "$MUTDIR/mut-suspect-shape.py"
probe "散文の誤検出の復活（検査 4d）" "$REPORT" "git checkout -- '$REPORT'"

echo "変異 9c: 集計器の警告を「件数だけ」へ戻す（名指しを落とす）"
python3 "$MUTDIR/mut-suspect-names.py"
probe "該当 Issue の名指しの消失（検査 4d）" "$REPORT" "git checkout -- '$REPORT'"

echo "変異 9d: 「行全体が 1 個の HTML コメント」の内側ガードを外す"
python3 "$MUTDIR/mut-suspect-multi.py"
probe "1 行 2 コメントの取りこぼし（検査 4d）" "$REPORT" "git checkout -- '$REPORT'"

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
