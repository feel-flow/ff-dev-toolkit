#!/usr/bin/env bash
#
# 決定木 v0（scripts/decision-tree/tree.tsv + route.sh、hooks/decision-tree.sh、
# scripts/effort-report.sh --unreached-leaves）の到達性と契約検査。
#
# 固定するもの:
#   A. 静的検査（実 tree）: route.sh --check が緑（各ノードに問い + 閉じた答え + none、葉は実在する
#      skills/<名>/SKILL.md / hooks/<名>.sh / doc、深さ ≤ 4、葉 ≤ 50、木に載っていないスキル・hook
#      無し）。葉の内訳がスキル実体・hooks.json の登録と一致する。hooks.json の UserPromptSubmit /
#      Stop へ配線され、既存の retrospective hook が外れていない
#   B. 検出力（合成 plugin root への変異注入）: 実在しない葉 / 到達不能ノード / 木に載っていない
#      スキル・hook / 未登録の hook（command 欄の無い登録を含む）/ 深さ 5 / none の欠落 / 葉 51 / doc の見出しの降格・不在 / criteria fixture
#      の option 不一致 / 循環 / 書式違反、のそれぞれで --check が赤になる
#   C. 空振り: 木データの不在・空・コメントだけ・区切りの書式変更・母集団（skills / hooks.json）が
#      空、のいずれも緑へ倒さない
#   D. ルータの規則（FF_JEV_MODE=off / 未設定）: docs のみ → fast、10 行以下 → fast、契約 path →
#      full、実装 → full、0 件 → none。未設定と off の出力がバイト同一で、どちらも jev-decide.sh
#      を呼ばない。判定不能（--lines 非整数・読めない一覧・木の不在・未知の FF_JEV_MODE）は
#      DT_ROUTE=none を出して exit 2。契約 path（docs-template / CLAUDE.md / AGENTS.md / skills 配下の
#      references / tree.tsv / Jev fixture / HOST-PARITY）は 1 行でも full。差分モードは git fixture で
#      fast / full に加え、untracked の行数加算・バイナリ差分の行数 `-`・共通祖先なしの exit 2 を実測
#   E. FF_JEV_MODE=on: 偽 jev-decide.sh で exit 0（採用）/ 10（閾値未満 → none）/ 11（失敗 → none）/
#      12（名簿外 → 規則）/ 2（入力不正 → exit 2）と、state に変更ファイル一覧と Issue 本文が載り
#      criteria が root.json であることを固定。実物の jev-decide.sh は FF_JEV_ENABLED 無しで
#      通信せず none（jev-fallback:disabled）へ落ち、名簿に無ければ規則へ落ちる
#   F. hook: UserPromptSubmit は stdout 無出力で根の答えをセッション記録へ置き、Stop は到達した葉
#      （根の答え・transcript の Skill 起動のうち葉に当たるもの・自身）を Issue 番号と repo
#      （git-common-dir）付きで leaves.tsv（8 列）へ追記し、同じ葉は 1 セッション 1 行。Skill 起動は
#      Skill ツールの tool_use とスラッシュコマンドの 2 形だけを採り、本文の文字列では採らない。
#      痕跡の無い transcript・記録先が書けない・repo を引けない・session_id が不正・無効化 env・
#      対象外イベントは止めずに無出力（fail-soft は stderr の (unmeasured) で区別）。
#      ASDD ゲートの早期終了経路でも stdin を読み切る
#   G. 読み手（effort-report.sh --unreached-leaves）: 記録が無い・読めない・repo を引けないは
#      (unmeasured)、供給源が未配線の葉（decision-tree 以外の hook と doc）は (unavailable)、repo 列が
#      --repo-dir と一致する行だけを採り、期間内に到達した葉は列挙から外れ、期間外の記録は数えず、
#      読めない行は件数で出す。--metrics-dir は env と同じ置き場を指し、--issue-metrics とは排他
#   H. 根の答えを読む側（scripts/review-route.sh = multi-review のレーン構成）: fast → 親の直読 +
#      Codex 1 レーン / full → 5 レーン / none → ホスト判定、完了報告の 1 行は DT_REASON の写像
#      （例「経路: fast（根拠: docs のみ / 12 行）」）。根の DT_* 行をバイト同一で通し（判定を
#      再実装しない）、根が判定不能（exit 2）の回・根（ルータ）が無い配置でも none を出して exit 2 を返す
#
# 変異検出: 実測は本 suite の B 節がそのまま持つ（合成 root への注入で毎回測る。B1〜B14 の 14 変異）。
# 空振り検出: 木データを空ファイルにすると (C2) が赤になる（--check は exit 2 を返し、suite は「rc 2 でない」を赤にする。2026-09-23 実測）。
# 空振り検出: 木データの区切りをタブから `,` へ変えると (C4) が赤になる（正規化が BAD 行を出し --check が exit 1。2026-09-23 実測）。
# 空振り検出: 合成 root の skills/ を空にすると (C5) が「母集団が空」で赤になる（2026-09-23 実測）。
# 空振り検出: 記録 leaves.tsv が無い置き場を読み手に渡すと (G1 / G2) が (unmeasured) を要求して赤になる（0 件の到達へ倒さない。2026-09-23 実測）。
#
# 依存: bash 3.2+、jq、git、awk、mktemp。jq / git / 一時領域が無ければ suite 全体を `○ skip`。
# run-all-required: no — jq / git / 一時領域の無い環境の skip を許容する（静的検査は route.sh --check
# が単体でも回せ、hook の契約は同型の hook suite と同じ判断で名簿へ載せない）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
ROUTER="$PLUGIN_ROOT/scripts/decision-tree/route.sh"
TREE="$PLUGIN_ROOT/scripts/decision-tree/tree.tsv"
HOOK="$PLUGIN_ROOT/hooks/decision-tree.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
REPORT="$PLUGIN_ROOT/scripts/effort-report.sh"
QFILE="$PLUGIN_ROOT/scripts/jev/questions/root.json"
PRINCIPLES="$PLUGIN_ROOT/docs-template/05-operations/deployment/workflow-principles.md"
# shellcheck source=../lib/asdd-gate-drain.sh
. "$SCRIPT_DIR/../lib/asdd-gate-drain.sh"
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

for f in "$ROUTER" "$TREE" "$HOOK" "$HOOKS_JSON" "$REPORT" "$QFILE" "$PRINCIPLES"; do
  [ -f "$f" ] || { echo "✗ 実体がありません: $f" >&2; exit 1; }
done
if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が見つからないためスキップ（decision-tree は未検査のままです）"
  exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  echo "○ skip: git が見つからないためスキップ（decision-tree は未検査のままです）"
  exit 0
fi
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-decision-tree.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TEST_TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できないため decision-tree を実行できません（検査は 1 件も実行されていません）"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi
REACHED_END=0
cleanup() {
  local rc=$?
  chmod -R u+rwx "$TEST_TMP" 2>/dev/null || true
  rm -rf "$TEST_TMP"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    echo "✗ decision-tree: 最後まで到達しませんでした" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

OUT=""
ERR=""
RC=0
# ルータ起動。Jev 系の env をすべて外し（実網へ出さない）、引数の NAME=VALUE を足す。
run_router() { # [NAME=VALUE ...] -- <route.sh の引数...>
  local envs=()
  while [ $# -gt 0 ]; do
    case "$1" in --) shift; break ;; esac
    envs+=("$1"); shift
  done
  RC=0
  if [ ${#envs[@]} -gt 0 ]; then
    OUT="$(env -u FF_JEV_MODE -u FF_JEV_POINTS -u FF_JEV_ENABLED -u TYPESAFE_API_KEY -u TYPESAFE_API_KEY_FILE -u WORKFLOW_TIER_BASE "${envs[@]}" bash "$ROUTER" "$@" 2>"$TEST_TMP/router.err")" || RC=$?
  else
    OUT="$(env -u FF_JEV_MODE -u FF_JEV_POINTS -u FF_JEV_ENABLED -u TYPESAFE_API_KEY -u TYPESAFE_API_KEY_FILE -u WORKFLOW_TIER_BASE bash "$ROUTER" "$@" 2>"$TEST_TMP/router.err")" || RC=$?
  fi
  ERR="$(cat "$TEST_TMP/router.err" 2>/dev/null || true)"
}
kv() { printf '%s\n' "$OUT" | awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }'; }
assert_route() { # <label> <route> <reason-prefix> <source>
  local label="$1" route="$2" reason="$3" source="$4" got_reason
  got_reason="$(kv DT_REASON)"
  if [ "$RC" -eq 0 ] && [ "$(kv DT_ROUTE)" = "$route" ] && [ "$(kv DT_SOURCE)" = "$source" ] \
    && case "$got_reason" in "$reason"*) true ;; *) false ;; esac; then
    ok "$label"
  else
    bad "$label: rc=$RC route=[$(kv DT_ROUTE)] reason=[$got_reason] source=[$(kv DT_SOURCE)]"
  fi
}
run_check() { # <tree> <plugin-root>
  RC=0
  OUT="$(bash "$ROUTER" --check --tree "$1" --plugin-root "$2" 2>"$TEST_TMP/check.err")" || RC=$?
  ERR="$(cat "$TEST_TMP/check.err" 2>/dev/null || true)"
}
assert_check_red() { # <label> <診断の部分文字列>
  if [ "$RC" -eq 1 ] && [ "${ERR#*"$2"}" != "$ERR" ]; then ok "$1"; else bad "$1: rc=$RC err=[$ERR]"; fi
}

# ============================================================================
echo "decision-tree A: 実 tree の静的検査"
run_check "$TREE" "$PLUGIN_ROOT"
if [ "$RC" -eq 0 ] && [ "${OUT#*"route --check:"}" != "$OUT" ]; then
  ok "A1 route.sh --check が緑（${OUT#✓ route --check: }）"
else
  bad "A1 route.sh --check が緑でない: rc=$RC out=[$OUT] err=[$ERR]"
fi

LEAVES="$(bash "$ROUTER" --leaves 2>/dev/null)" || LEAVES=""
n_leaves="$(printf '%s\n' "$LEAVES" | awk 'NF { n++ } END { print n + 0 }')"
n_skill_leaves="$(printf '%s\n' "$LEAVES" | awk -F'\t' '$1 == "skill" { n++ } END { print n + 0 }')"
n_hook_leaves="$(printf '%s\n' "$LEAVES" | awk -F'\t' '$1 == "hook" { n++ } END { print n + 0 }')"
n_doc_leaves="$(printf '%s\n' "$LEAVES" | awk -F'\t' '$1 == "doc" { n++ } END { print n + 0 }')"
n_skills_actual="$(find "$PLUGIN_ROOT/skills" -mindepth 2 -maxdepth 2 -name SKILL.md -type f | wc -l | tr -d ' ')"
n_hooks_actual="$(grep -oE 'hooks/[A-Za-z0-9_.-]+\.sh' "$HOOKS_JSON" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
if [ "$n_leaves" -gt 0 ] && [ "$n_leaves" -le 50 ]; then ok "A2 葉 ${n_leaves} 件（上限 50）"; else bad "A2 葉の件数が範囲外: ${n_leaves}"; fi
if [ "$n_skill_leaves" -eq "$n_skills_actual" ] && [ "$n_skill_leaves" -gt 0 ]; then ok "A3 skill の葉 ${n_skill_leaves} 件 = skills/*/SKILL.md の実体数"; else bad "A3 skill の葉 ${n_skill_leaves} 件 ≠ 実体 ${n_skills_actual} 件"; fi
if [ "$n_hook_leaves" -eq "$n_hooks_actual" ] && [ "$n_hook_leaves" -gt 0 ]; then ok "A4 hook の葉 ${n_hook_leaves} 件 = hooks.json の登録実体数"; else bad "A4 hook の葉 ${n_hook_leaves} 件 ≠ 登録 ${n_hooks_actual} 件"; fi
if [ "$n_doc_leaves" -eq 1 ]; then ok "A5 「熟慮へ」の doc の葉が 1 件"; else bad "A5 doc の葉が 1 件ではない: ${n_doc_leaves}"; fi
if grep -F '熟慮を起こすトリガ（索引）' "$PRINCIPLES" >/dev/null && grep -F 'decision-tree' "$PRINCIPLES" >/dev/null; then
  ok "A6 原則 4 のトリガ索引が実在し、決定木の「熟慮へ」葉からの参照が原則 4 側にある"
else
  bad "A6 原則 4 のトリガ索引か決定木への言及が workflow-principles.md にありません"
fi
if [ "$(jq -r '.hooks.UserPromptSubmit[]?.hooks[]? | select(.command | test("hooks/decision-tree\\.sh")) | .timeout' "$HOOKS_JSON")" = "5" ] \
  && [ "$(jq -r '.hooks.Stop[]?.hooks[]? | select(.command | test("hooks/decision-tree\\.sh")) | .timeout' "$HOOKS_JSON")" = "5" ]; then
  ok "A7 hooks.json の UserPromptSubmit / Stop に decision-tree.sh が timeout 5 で配線されている"
else
  bad "A7 hooks.json の配線が期待と違います"
fi
if jq -e '.hooks.UserPromptSubmit[]?.hooks[]? | select(.command | test("retrospective-context\\.sh"))' "$HOOKS_JSON" >/dev/null \
  && jq -e '.hooks.Stop[]?.hooks[]? | select(.command | test("retrospective-stop\\.sh"))' "$HOOKS_JSON" >/dev/null; then
  ok "A8 既存の retrospective-context / retrospective-stop の配線が残っている（既存 hook を外していない）"
else
  bad "A8 既存の retrospective hook の配線が消えています"
fi
[ -x "$HOOK" ] && ok "A9 hooks/decision-tree.sh に実行権限がある" || bad "A9 hooks/decision-tree.sh に実行権限が無い"
[ -x "$ROUTER" ] && ok "A10 route.sh に実行権限がある" || bad "A10 route.sh に実行権限が無い"
if [ "$(jq -r '.root.criteria | keys | join(" ")' "$QFILE")" = "fast full" ] && [ "$(jq -r '.root.type' "$QFILE")" = "choice" ]; then
  ok "A11 root の criteria fixture は choice 型で option が fast / full"
else
  bad "A11 root の criteria fixture が期待と違います"
fi

# ============================================================================
echo "decision-tree B: 検出力（合成 plugin root への変異注入）"
FIX="$TEST_TMP/fixroot"
make_fixture_root() { # <dir>
  local d="$1"
  rm -rf "$d"
  mkdir -p "$d/skills/alpha" "$d/skills/beta" "$d/hooks" "$d/docs-template" "$d/scripts/jev/questions"
  printf '%s\n' '---' 'name: alpha' 'description: fixture' '---' > "$d/skills/alpha/SKILL.md"
  printf '%s\n' '---' 'name: beta' 'description: fixture' '---' > "$d/skills/beta/SKILL.md"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$d/hooks/h1.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$d/hooks/h2.sh"
  printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash \"${CLAUDE_PLUGIN_ROOT}/hooks/h1.sh\""},{"type":"command","command":"bash \"${CLAUDE_PLUGIN_ROOT}/hooks/h2.sh\""}]}]}}' > "$d/hooks/hooks.json"
  printf '%s\n' '# doc' '' '## 見出し' 'body' > "$d/docs-template/x.md"
  printf '%s\n' '{"root":{"type":"choice","instructions":{"question":"q"},"criteria":{"fast":"f","full":"g"}}}' > "$d/scripts/jev/questions/root.json"
}
write_tree() { # <file>
  printf 'node\troot\tchoice\tQ\n'
  printf 'rule\troot\tdocs-glob\t*.md\n'
  printf 'rule\troot\tcontract-path\t*/hooks/hooks.json\n'
  printf 'rule\troot\tfast-max-lines\t10\n'
  printf 'answer\troot\tfast\tnode:fast\n'
  printf 'answer\troot\tfull\tnode:full\n'
  printf 'answer\troot\tnone\tnone\n'
  printf 'node\tfast\tselect\tQ\n'
  printf 'answer\tfast\ta\tskill:alpha\n'
  printf 'answer\tfast\thook\tnode:hk\n'
  printf 'answer\tfast\tnone\tnone\n'
  printf 'node\tfull\tselect\tQ\n'
  printf 'answer\tfull\tb\tskill:beta\n'
  printf 'answer\tfull\td\tdoc:docs-template/x.md#見出し\n'
  printf 'answer\tfull\thook\tnode:hk\n'
  printf 'answer\tfull\tnone\tnone\n'
  printf 'node\thk\tselect\tQ\n'
  printf 'answer\thk\tone\thook:h1\n'
  printf 'answer\thk\ttwo\thook:h2\n'
  printf 'answer\thk\tnone\tnone\n'
}
make_fixture_root "$FIX"
BASE_TREE="$TEST_TMP/base.tsv"
write_tree > "$BASE_TREE"
run_check "$BASE_TREE" "$FIX"
[ "$RC" -eq 0 ] && ok "B0 合成 root + 基準 tree は緑" || bad "B0 基準 tree が緑でない: rc=$RC err=[$ERR]"

mut() { # <name> → $TEST_TMP/<name>.tsv に基準をコピーしてパスを返す
  cp "$BASE_TREE" "$TEST_TMP/$1.tsv"; printf '%s\n' "$TEST_TMP/$1.tsv"
}
T="$(mut b1)"; printf 'answer\tfast\tz\tskill:gamma\n' >> "$T"; run_check "$T" "$FIX"; assert_check_red "B1 実在しないスキルの葉" "実在しない葉（skill）"
T="$(mut b2)"; printf 'node\tlost\tselect\tQ\nanswer\tlost\tx\tskill:alpha\nanswer\tlost\tnone\tnone\n' >> "$T"; run_check "$T" "$FIX"; assert_check_red "B2 到達不能なノード" "root から到達できません"
make_fixture_root "$FIX"; mkdir -p "$FIX/skills/gamma"; printf '%s\n' '---' 'name: gamma' '---' > "$FIX/skills/gamma/SKILL.md"
run_check "$BASE_TREE" "$FIX"; assert_check_red "B3 木に載っていないスキル" "木に載っていないスキル: gamma"
make_fixture_root "$FIX"; printf '%s\n' '#!/usr/bin/env bash' > "$FIX/hooks/h3.sh"
printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash \"${CLAUDE_PLUGIN_ROOT}/hooks/h1.sh\""},{"type":"command","command":"bash \"${CLAUDE_PLUGIN_ROOT}/hooks/h2.sh\""},{"type":"command","command":"bash \"${CLAUDE_PLUGIN_ROOT}/hooks/h3.sh\""}]}]}}' > "$FIX/hooks/hooks.json"
run_check "$BASE_TREE" "$FIX"; assert_check_red "B4 木に載っていない hook（hooks.json に登録あり）" "木に載っていない hook: hooks/h3.sh"
make_fixture_root "$FIX"; printf '%s\n' '#!/usr/bin/env bash' > "$FIX/hooks/h3.sh"
T="$(mut b5)"; printf 'answer\thk\tthree\thook:h3\n' >> "$T"; run_check "$T" "$FIX"; assert_check_red "B5 hooks.json に登録されていない hook の葉" "登録されていない葉（hook）"
make_fixture_root "$FIX"
T="$(mut b6)"; sed -i.bak 's/^answer\thk\tone\thook:h1$/answer\thk\tone\tnode:deep1/' "$T"; printf 'node\tdeep1\tselect\tQ\nanswer\tdeep1\tgo\tnode:deep2\nanswer\tdeep1\tnone\tnone\nnode\tdeep2\tselect\tQ\nanswer\tdeep2\tgo\thook:h1\nanswer\tdeep2\tnone\tnone\n' >> "$T"
run_check "$T" "$FIX"; assert_check_red "B6 深さ 5 の葉（root/f/hk/deep1/deep2/h1）" "深さ 5"
T="$(mut b7)"; sed -i.bak '/^answer\tfull\tnone\tnone$/d' "$T"; run_check "$T" "$FIX"; assert_check_red "B7 none の無いノード" "none がちょうど 1 本ではありません"
T="$(mut b8)"; i=1; while [ "$i" -le 51 ]; do mkdir -p "$FIX/skills/s$i"; printf '%s\n' '---' "name: s$i" '---' > "$FIX/skills/s$i/SKILL.md"; printf 'answer\tfull\ts%s\tskill:s%s\n' "$i" "$i" >> "$T"; i=$((i + 1)); done
run_check "$T" "$FIX"; assert_check_red "B8 葉が 51 件以上" "上限 50 を超えています"
make_fixture_root "$FIX"
printf '%s\n' '# doc' 'no heading' > "$FIX/docs-template/x.md"; run_check "$BASE_TREE" "$FIX"; assert_check_red "B9 doc の葉の見出しが本文に無い" "本文にありません"
make_fixture_root "$FIX"
printf '%s\n' '{"root":{"type":"choice","instructions":{"question":"q"},"criteria":{"fast":"f","full":"g","slow":"s"}}}' > "$FIX/scripts/jev/questions/root.json"
run_check "$BASE_TREE" "$FIX"; assert_check_red "B10 criteria fixture の option が root の答えと不一致" "fixture の option が一致しません"
make_fixture_root "$FIX"
T="$(mut b11)"; sed -i.bak 's/^answer\thk\tone\thook:h1$/answer\thk\tone\tnode:fast/' "$T"; run_check "$T" "$FIX"; assert_check_red "B11 循環（hk → fast → hk）" "循環があります"
T="$(mut b12)"; sed -i.bak 's/^node\troot\tchoice\tQ$/node\troot\tselect\tQ/' "$T"; run_check "$T" "$FIX"; assert_check_red "B12 root が choice でない" "root の kind は choice"
T="$(mut b13)"; sed -i.bak '/^rule\troot\tfast-max-lines\t10$/d' "$T"; run_check "$T" "$FIX"; assert_check_red "B13 choice node の rule（fast-max-lines）欠落" "rule fast-max-lines がありません"
T="$(mut b14)"; printf 'answer\tfast\tbad\tnone\n' >> "$T"; run_check "$T" "$FIX"; assert_check_red "B14 none 以外の答えが none へ落ちている" "none へ落ちています"
T="$(mut b15)"; printf 'rule\troot\tfast-max-lines\t100000\n' >> "$T"; run_check "$T" "$FIX"; assert_check_red "B15 同じ (node, key) の rule の重複（前置きで判定を緩める形）" "重複しています"
T="$(mut b16)"; printf 'rule\troot\tbogus\t1\n' >> "$T"; run_check "$T" "$FIX"; assert_check_red "B16 未知の rule キー" "未知のキー"
T="$(mut b17)"; sed -i.bak 's/^answer\troot\tfast\tnode:fast$/answer\troot\tfast\tnode:full/' "$T"; run_check "$T" "$FIX"; assert_check_red "B17 root の fast が node:fast 以外を指す" "node:fast を指さなければ"
T="$(mut b18)"; sed -i.bak 's/^answer\troot\tfull\tnode:full$/answer\troot\tfull\tnode:fast/' "$T"; run_check "$T" "$FIX"; assert_check_red "B18 root の full が node:full 以外を指す" "node:full を指さなければ"
T="$(mut b19)"; printf 'answer\troot\tslow\tskill:alpha\n' >> "$T"; run_check "$T" "$FIX"; assert_check_red "B19 root の答えが fast / full / none 以外を含む" "3 つに限ります"
make_fixture_root "$FIX"
# hooks.json の description にだけ h2 のパスを残し command から消す（全文 grep なら緑になる形）
printf '%s\n' '{"description":"hooks/h2.sh is mentioned here only","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash \"${CLAUDE_PLUGIN_ROOT}/hooks/h1.sh\""}]}]}}' > "$FIX/hooks/hooks.json"
run_check "$BASE_TREE" "$FIX"; assert_check_red "B20 description にだけ残った hook パスは登録と見なさない（command 欄から抽出）" "command に登録されていない葉（hook）"
make_fixture_root "$FIX"
printf '%s\n' '# doc' '' '見出し' 'body' > "$FIX/docs-template/x.md"; run_check "$BASE_TREE" "$FIX"; assert_check_red "B21 doc の葉の見出しが本文へ降格（同語は残る）すると赤" "Markdown 見出し行として"
make_fixture_root "$FIX"

# ============================================================================
echo "decision-tree C: 空振り（針が当たらない入力）"
run_check "$TEST_TMP/nope.tsv" "$FIX"
[ "$RC" -eq 2 ] && ok "C1 木データ不在は exit 2（緑にしない）" || bad "C1 木データ不在: rc=$RC err=[$ERR]"
: > "$TEST_TMP/empty.tsv"; run_check "$TEST_TMP/empty.tsv" "$FIX"
[ "$RC" -eq 2 ] && ok "C2 空の木データは exit 2" || bad "C2 空の木データ: rc=$RC err=[$ERR]"
printf '# only comments\n\n' > "$TEST_TMP/comments.tsv"; run_check "$TEST_TMP/comments.tsv" "$FIX"
[ "$RC" -eq 2 ] && ok "C3 コメントだけの木データは exit 2" || bad "C3 コメントだけ: rc=$RC err=[$ERR]"
tr '\t' ',' < "$BASE_TREE" > "$TEST_TMP/comma.tsv"; run_check "$TEST_TMP/comma.tsv" "$FIX"; assert_check_red "C4 区切りの書式変更（タブ → カンマ）は赤" "フィールド数が 4 ではありません"
make_fixture_root "$FIX"; rm -rf "$FIX/skills"; mkdir -p "$FIX/skills"
run_check "$BASE_TREE" "$FIX"; assert_check_red "C5 skills/ が空（母集団が空）は赤" "母集団が空"
make_fixture_root "$FIX"; printf '%s\n' '{"hooks":{}}' > "$FIX/hooks/hooks.json"
run_check "$BASE_TREE" "$FIX"; assert_check_red "C6 hooks.json に登録が無い（母集団が空）は赤" "母集団が空"
make_fixture_root "$FIX"
RC=0; OUT="$(bash "$ROUTER" --leaves --tree "$TEST_TMP/nope.tsv" 2>/dev/null)" || RC=$?
[ "$RC" -eq 2 ] && [ -z "$OUT" ] && ok "C7 --leaves も木データ不在は exit 2 で空を返さない" || bad "C7 --leaves 木データ不在: rc=$RC out=[$OUT]"

# ============================================================================
echo "decision-tree D: ルータの規則（FF_JEV_MODE=off / 未設定）"
run_router -- --files docs/a.md README.md; assert_route "D1 docs のみは fast（docs-only）" fast docs-only rules
run_router -- --files plugins/x.sh --lines 10; assert_route "D2 10 行以下は fast（small-diff）" fast small-diff rules
run_router -- --files plugins/x.sh --lines 11; assert_route "D3 11 行は full（implementation）" full implementation rules
run_router -- --files docs/a.md plugins/ff-dev-toolkit/hooks/hooks.json --lines 1; assert_route "D4 契約 path（hooks.json）は 1 行でも full" full contract-change rules
run_router -- --files plugins/ff-dev-toolkit/skills/ace-curate/SKILL.md; assert_route "D5 SKILL.md は契約扱いで full" full contract-change rules
# 契約 path の網羅（1 行変更でも full）。fast に倒れてはいけない path をレビューで実測した順に固定する
run_router -- --files plugins/ff-dev-toolkit/docs-template/05-operations/deployment/git-workflow.md --lines 1; assert_route "D5a docs-template の 1 行変更は full（配布物）" full contract-change rules
run_router -- --files CLAUDE.md --lines 1; assert_route "D5b CLAUDE.md の 1 行変更は full（入口）" full contract-change rules
run_router -- --files AGENTS.md --lines 1; assert_route "D5c AGENTS.md の 1 行変更は full（入口）" full contract-change rules
run_router -- --files plugins/ff-dev-toolkit/skills/close-issue/references/x.md --lines 1; assert_route "D5d skills/<名>/references の 1 行変更は full（SKILL.md 以外も）" full contract-change rules
run_router -- --files plugins/ff-dev-toolkit/scripts/decision-tree/tree.tsv --lines 3; assert_route "D5e tree.tsv の 3 行変更は full（木データ自身）" full contract-change rules
run_router -- --files plugins/ff-dev-toolkit/scripts/jev/questions/root.json --lines 1; assert_route "D5f Jev criteria fixture の 1 行変更は full" full contract-change rules
run_router -- --files docs/06-reference/HOST-PARITY.md --lines 1; assert_route "D5g HOST-PARITY.md の 1 行変更は full" full contract-change rules
run_router -- --files docs/a.md plugins/x.sh; assert_route "D6 行数不明で docs 以外を含めば full" full implementation rules
run_router -- --files-from /dev/null; assert_route "D7 0 件は none（no-files）" none no-files none
[ "$(kv DT_TARGET)" = "none" ] && ok "D8 none の行き先は none" || bad "D8 none の行き先: $(kv DT_TARGET)"
run_router -- --files docs/a.md; [ "$(kv DT_TARGET)" = "node:fast" ] && ok "D9 fast の行き先は node:fast" || bad "D9 fast の行き先: $(kv DT_TARGET)"
run_router -- --files plugins/x.sh --lines abc
[ "$RC" -eq 2 ] && [ "$(kv DT_ROUTE)" = "none" ] && case "$(kv DT_REASON)" in error:*) true ;; *) false ;; esac && ok "D10 --lines 非整数は none + exit 2（error: 理由付き）" || bad "D10 --lines 非整数: rc=$RC out=[$OUT]"
run_router -- --files-from "$TEST_TMP/nope.txt"
[ "$RC" -eq 2 ] && [ "$(kv DT_ROUTE)" = "none" ] && ok "D11 読めない一覧は none + exit 2" || bad "D11 読めない一覧: rc=$RC out=[$OUT]"
run_router -- --files docs/a.md --tree "$TEST_TMP/nope.tsv"
[ "$RC" -eq 2 ] && [ "$(kv DT_ROUTE)" = "none" ] && ok "D12 木データ不在は none + exit 2（DT_ROUTE 行は出す）" || bad "D12 木データ不在: rc=$RC out=[$OUT]"
run_router FF_JEV_MODE=maybe -- --files docs/a.md
[ "$RC" -eq 2 ] && [ "$(kv DT_ROUTE)" = "none" ] && ok "D13 未知の FF_JEV_MODE は none + exit 2（off へ倒さない）" || bad "D13 未知の FF_JEV_MODE: rc=$RC out=[$OUT]"
run_router -- --files docs/a.md --lines 5 --frobnicate
[ "$RC" -eq 64 ] && ok "D14 未知の引数は exit 64" || bad "D14 未知の引数: rc=$RC"

# off / 未設定は jev-decide を呼ばない（偽 jev-decide がマーカーを書く）
STUB="$TEST_TMP/jev-stub.sh"
MARK="$TEST_TMP/jev-called"
write_stub() { # <rc> [answer]
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$@" > "%s"\n' "$MARK"
    printf 'for a in "$@"; do if [ -n "${prev:-}" ]; then cp "$a" "%s"; prev=""; fi; [ "$a" = "--state-file" ] && prev=1; done\n' "$TEST_TMP/jev-state"
    case "$1" in
      0) printf 'echo JEV_DECISION=adopt; echo JEV_REASON=confident; echo "ANSWER=root|choice|%s|1.0"; exit 0\n' "${2:-fast}" ;;
      10) printf 'echo JEV_DECISION=fallback; echo JEV_REASON=low-confidence; echo "ANSWER=root|choice|fast|0.5"; exit 10\n' ;;
      11) printf 'echo JEV_DECISION=fallback; echo JEV_REASON=disabled; exit 11\n' ;;
      12) printf 'echo JEV_DECISION=off; echo JEV_REASON=point-not-listed; exit 12\n' ;;
      *) printf 'echo JEV_DECISION=error; exit %s\n' "$1" ;;
    esac
  } > "$STUB"
  chmod +x "$STUB"
}
write_stub 0
rm -f "$MARK"
run_router -- --files plugins/x.sh --lines 50 --jev-decide "$STUB"; UNSET_OUT="$OUT"; UNSET_RC=$RC
[ ! -e "$MARK" ] && ok "D15 FF_JEV_MODE 未設定は jev-decide を呼ばない" || bad "D15 未設定なのに jev-decide が呼ばれた"
run_router FF_JEV_MODE=off -- --files plugins/x.sh --lines 50 --jev-decide "$STUB"
[ ! -e "$MARK" ] && ok "D16 FF_JEV_MODE=off も jev-decide を呼ばない" || bad "D16 off なのに jev-decide が呼ばれた"
[ "$OUT" = "$UNSET_OUT" ] && [ "$RC" -eq "$UNSET_RC" ] && ok "D17 未設定と off の出力がバイト同一（規則だけで決まる）" || bad "D17 未設定と off の出力が違う: [$UNSET_OUT] vs [$OUT]"

# 差分モード（git fixture）
GITFIX="$TEST_TMP/repo"
ff_git_fixture_init "$GITFIX" >/dev/null
( cd "$GITFIX" && git checkout -q -b main && mkdir -p docs && printf 'a\n' > docs/a.md && printf 'x\n' > x.sh && git add . && git commit -q -m init \
  && git checkout -q -b 'feature/#4321-probe' && printf 'a\nb\n' > docs/a.md && git commit -q -am docs ) || bad "git fixture の構築に失敗"
RC=0; OUT="$(cd "$GITFIX" && env -u FF_JEV_MODE -u FF_JEV_POINTS -u FF_JEV_ENABLED -u TYPESAFE_API_KEY -u TYPESAFE_API_KEY_FILE WORKFLOW_TIER_BASE=main bash "$ROUTER" 2>/dev/null)" || RC=$?
assert_route "D18 差分モード: docs だけの commit は fast（docs-only）" fast docs-only rules
[ "$(kv DT_FILES)" = "1" ] && [ "$(kv DT_LINES)" = "1" ] && ok "D19 差分モードの件数・行数（1 ファイル / 1 行）" || bad "D19 差分モードの件数・行数: files=$(kv DT_FILES) lines=$(kv DT_LINES)"
printf 'y\n' >> "$GITFIX/x.sh"
RC=0; OUT="$(cd "$GITFIX" && env -u FF_JEV_MODE -u FF_JEV_POINTS -u FF_JEV_ENABLED -u TYPESAFE_API_KEY -u TYPESAFE_API_KEY_FILE WORKFLOW_TIER_BASE=main bash "$ROUTER" 2>/dev/null)" || RC=$?
assert_route "D20 差分モード: 未コミットの .sh 変更（2 行）を含めば small-diff で fast" fast small-diff rules
( cd "$GITFIX" && git checkout -q -- x.sh )
RC=0; OUT="$(cd "$GITFIX" && env -u FF_JEV_MODE -u FF_JEV_POINTS -u FF_JEV_ENABLED -u TYPESAFE_API_KEY -u TYPESAFE_API_KEY_FILE bash "$ROUTER" --base nonexistent-ref 2>/dev/null)" || RC=$?
[ "$RC" -eq 2 ] && [ "$(kv DT_ROUTE)" = "none" ] && ok "D21 差分モード: base ref を解決できなければ none + exit 2" || bad "D21 base 不明: rc=$RC out=[$OUT]"
RC=0; OUT="$(cd "$TEST_TMP" && env -u FF_JEV_MODE bash "$ROUTER" 2>/dev/null)" || RC=$?
[ "$RC" -eq 2 ] && [ "$(kv DT_ROUTE)" = "none" ] && ok "D22 差分モード: git リポジトリの外は none + exit 2" || bad "D22 git 外: rc=$RC out=[$OUT]"
# レビューで再現した fail-open 3 形（untracked / バイナリ / 共通祖先なし）
awk 'BEGIN { for (i = 1; i <= 500; i++) print "line " i }' > "$GITFIX/new.sh"
RC=0; OUT="$(cd "$GITFIX" && env -u FF_JEV_MODE -u FF_JEV_POINTS -u FF_JEV_ENABLED WORKFLOW_TIER_BASE=main bash "$ROUTER" 2>/dev/null)" || RC=$?
assert_route "D23 差分モード: untracked の 500 行 .sh は行数に加算されて full（小差分へ倒れない）" full implementation rules
[ "$(kv DT_LINES)" -ge 500 ] 2>/dev/null && ok "D24 untracked の行数が DT_LINES に載る（$(kv DT_LINES) 行）" || bad "D24 DT_LINES=$(kv DT_LINES)"
rm -f "$GITFIX/new.sh"
printf '\000\001\002binary\000' > "$GITFIX/blob.bin"
( cd "$GITFIX" && git add blob.bin && git commit -q -m bin )
RC=0; OUT="$(cd "$GITFIX" && env -u FF_JEV_MODE -u FF_JEV_POINTS -u FF_JEV_ENABLED WORKFLOW_TIER_BASE=main bash "$ROUTER" 2>/dev/null)" || RC=$?
assert_route "D25 差分モード: バイナリの変更を含むと行数は - になり small-diff に当たらず full" full implementation rules
[ "$(kv DT_LINES)" = "-" ] && ok "D26 バイナリ差分で DT_LINES=-（0 に丸めない）" || bad "D26 DT_LINES=$(kv DT_LINES)"
( cd "$GITFIX" && git reset -q --hard HEAD~1 )
ORPHAN="$TEST_TMP/orphan"
ff_git_fixture_init "$ORPHAN" >/dev/null
( cd "$ORPHAN" && git checkout -q -b main && printf 'a\n' > docs/a.md 2>/dev/null || { mkdir -p docs && printf 'a\n' > docs/a.md; } && git add . && git commit -q -m init \
  && git checkout -q --orphan 'feature/#9-orphan' && git rm -rq --cached . && printf 'x\n' > docs/a.md && awk 'BEGIN { for (i = 1; i <= 300; i++) print i }' > big.py && git add . && git commit -q -m orphan ) || bad "orphan fixture の構築に失敗"
RC=0; OUT="$(cd "$ORPHAN" && env -u FF_JEV_MODE -u FF_JEV_POINTS -u FF_JEV_ENABLED WORKFLOW_TIER_BASE=main bash "$ROUTER" 2>/dev/null)" || RC=$?
[ "$RC" -eq 2 ] && [ "$(kv DT_ROUTE)" = "none" ] && ok "D27 差分モード: base と共通祖先が無ければ none + exit 2（docs-only へ倒れない）" || bad "D27 orphan: rc=$RC out=[$OUT]"

# ============================================================================
echo "decision-tree E: FF_JEV_MODE=on（二段構え）"
printf 'Issue body probe text\n' > "$TEST_TMP/issue.md"
write_stub 0 fast; rm -f "$MARK"
run_router FF_JEV_MODE=on -- --files plugins/x.sh plugins/y.sh --lines 50 --issue-body "$TEST_TMP/issue.md" --jev-decide "$STUB"
assert_route "E1 exit 0（confidence ≥ 閾値）は Jev の答えを採用（fast / jev-adopt / source=jev）" fast jev-adopt jev
if [ -f "$MARK" ] && [ "$(awk 'NR == 1' "$MARK")" = "route" ] && grep -F "questions/root.json" "$MARK" >/dev/null; then
  ok "E2 判定点 route で criteria fixture root.json を渡している"
else
  bad "E2 jev-decide の引数が期待と違う: $(tr '\n' ' ' < "$MARK" 2>/dev/null)"
fi
if [ -f "$TEST_TMP/jev-state" ] && grep -F "plugins/y.sh" "$TEST_TMP/jev-state" >/dev/null && grep -F "Issue body probe text" "$TEST_TMP/jev-state" >/dev/null && grep -F "Changed lines (added + deleted): 50" "$TEST_TMP/jev-state" >/dev/null; then
  ok "E3 state に変更ファイル一覧・行数・Issue 本文が載る"
else
  bad "E3 state の内容が期待と違う: $(cat "$TEST_TMP/jev-state" 2>/dev/null | tr '\n' ' ')"
fi
write_stub 10
run_router FF_JEV_MODE=on -- --files plugins/x.sh --lines 50 --jev-decide "$STUB"
assert_route "E4 exit 10（閾値未満）は none（jev-low-confidence）— 規則へ落とさずホスト判定へ" none jev-low-confidence jev
write_stub 11
run_router FF_JEV_MODE=on -- --files plugins/x.sh --lines 50 --jev-decide "$STUB"
assert_route "E5 exit 11（Jev の失敗）は none（jev-fallback:disabled。種別を保持）" none "jev-fallback:disabled" jev
write_stub 12
run_router FF_JEV_MODE=on -- --files plugins/x.sh --lines 50 --jev-decide "$STUB"
assert_route "E6 exit 12（判定点が名簿に無い）は off と同じ規則判定（full / implementation / rules）" full implementation rules
write_stub 2
run_router FF_JEV_MODE=on -- --files plugins/x.sh --lines 50 --jev-decide "$STUB"
[ "$RC" -eq 2 ] && [ "$(kv DT_ROUTE)" = "none" ] && ok "E7 exit 2（入力不正）は none + exit 2 で止める（従来経路へ黙って落とさない）" || bad "E7 入力不正: rc=$RC out=[$OUT]"
write_stub 0 slow
run_router FF_JEV_MODE=on -- --files plugins/x.sh --lines 50 --jev-decide "$STUB"
assert_route "E8 採用でも答えが root の集合に無ければ none（jev-unknown-answer）" none "jev-unknown-answer:slow" jev
run_router FF_JEV_MODE=on -- --files-from /dev/null --jev-decide "$STUB"; rm -f "$MARK"
assert_route "E9 on でも 0 件は Jev を呼ばず none（no-files）" none no-files none
# 実物の jev-decide.sh（FF_JEV_ENABLED を外すので通信しない）
run_router FF_JEV_MODE=on FF_JEV_POINTS=route FF_JEV_DECISION_LOG="$TEST_TMP/jev-log.jsonl" -- --files plugins/x.sh --lines 50
assert_route "E10 実物 jev-decide: on + 名簿に route + FF_JEV_ENABLED 無しは none（jev-fallback:disabled）" none "jev-fallback:disabled" jev
[ -f "$TEST_TMP/jev-log.jsonl" ] && grep -F '"point":"route"' "$TEST_TMP/jev-log.jsonl" >/dev/null && ok "E11 実物 jev-decide の記録に判定点 route の fallback 行が残る" || bad "E11 jev-decide の記録が無い"
run_router FF_JEV_MODE=on FF_JEV_DECISION_LOG="$TEST_TMP/jev-log2.jsonl" -- --files plugins/x.sh --lines 50
assert_route "E12 実物 jev-decide: on でも既定の名簿（novelty retro）に route が無ければ規則へ" full implementation rules
[ ! -e "$TEST_TMP/jev-log2.jsonl" ] && ok "E13 名簿外の判定点は記録も書かない" || bad "E13 名簿外なのに記録が書かれた"

# ============================================================================
echo "decision-tree F: hook（UserPromptSubmit / Stop）"
STATE="$TEST_TMP/state"
run_hook() { # <json> [NAME=VALUE ...]
  local json="$1"; shift
  RC=0
  OUT="$(printf '%s' "$json" | env -u FF_JEV_MODE -u FF_JEV_POINTS -u FF_JEV_ENABLED -u FF_DEV_TOOLKIT_SKIP_DECISION_TREE FF_DEV_TOOLKIT_STATE_DIR="$STATE" WORKFLOW_TIER_BASE=main "$@" bash "$HOOK" 2>"$TEST_TMP/hook.err")" || RC=$?
  ERR="$(cat "$TEST_TMP/hook.err" 2>/dev/null || true)"
}
json_ups() { jq -nc --arg sid "$1" --arg cwd "$2" '{hook_event_name: "UserPromptSubmit", session_id: $sid, cwd: $cwd, prompt: "x"}'; }
json_stop() { jq -nc --arg sid "$1" --arg cwd "$2" --arg t "$3" '{hook_event_name: "Stop", session_id: $sid, cwd: $cwd, transcript_path: $t, stop_hook_active: false}'; }
TRANSCRIPT="$TEST_TMP/transcript.jsonl"
printf '%s\n' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Skill","input":{"skill":"ff-dev-toolkit:pre-commit-check","args":""}}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Skill","input":{"skill":"pr-review-toolkit:review-pr"}}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t3","name":"Skill","input":{"skill":"close-issue","args":"4321"}}]}}' \
  '{"type":"user","message":{"content":"<command-name>/ff-dev-toolkit:ace-refine</command-name>"}}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"the reviewed file contains the literal string \"skill\":\"merge-cleanup\" and \"skill\":\"ff-dev-toolkit:retrospective\" in prose"}]}}' \
  > "$TRANSCRIPT"
GITFIX_REPO="$(git -C "$GITFIX" rev-parse --path-format=absolute --git-common-dir)"
rm -rf "$STATE"
run_hook "$(json_ups s1 "$GITFIX")"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$(awk -F'\t' 'NR == 1 { print $3 }' "$STATE/metrics/sessions/s1.route" 2>/dev/null)" = "fast" ]; then
  ok "F1 UserPromptSubmit は stdout 無出力で根の答え（fast）をセッション記録へ置く"
else
  bad "F1 UserPromptSubmit: rc=$RC out=[$OUT] err=[$ERR] route=[$(cat "$STATE/metrics/sessions/s1.route" 2>/dev/null)]"
fi
run_hook "$(json_stop s1 "$GITFIX" "$TRANSCRIPT")"
LEAVES_TSV="$STATE/metrics/leaves.tsv"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -f "$LEAVES_TSV" ] \
  && awk -F'\t' '$3 == "4321" && $4 == "s1" && $5 == "route" && $6 == "fast" && $7 == "root" { f = 1 } END { exit !f }' "$LEAVES_TSV" \
  && awk -F'\t' '$3 == "4321" && $5 == "skill" && $6 == "pre-commit-check" && $7 == "transcript" { f = 1 } END { exit !f }' "$LEAVES_TSV" \
  && awk -F'\t' '$3 == "4321" && $5 == "skill" && $6 == "close-issue" { f = 1 } END { exit !f }' "$LEAVES_TSV" \
  && awk -F'\t' '$5 == "hook" && $6 == "decision-tree" && $7 == "self" { f = 1 } END { exit !f }' "$LEAVES_TSV"; then
  ok "F2 Stop は根の答え・transcript の Skill 起動・自身を Issue 番号 4321 付きで leaves.tsv へ追記する"
else
  bad "F2 Stop の記録: rc=$RC out=[$OUT] err=[$ERR] leaves=[$(cat "$LEAVES_TSV" 2>/dev/null | tr '\n' '|')]"
fi
if ! grep -F 'review-pr' "$LEAVES_TSV" >/dev/null; then ok "F3 葉でないスキル（別プラグインの review-pr）は記録しない"; else bad "F3 葉でないスキルが記録された"; fi
awk -F'\t' 'NF != 8 { bad = 1 } $2 !~ /^[0-9]+$/ { bad = 1 } END { exit bad }' "$LEAVES_TSV" && ok "F4 leaves.tsv は 8 フィールド・epoch 整数の 1 行 1 レコード" || bad "F4 leaves.tsv の書式が崩れている"
awk -F'\t' -v r="$GITFIX_REPO" '$8 != r { bad = 1 } END { exit bad }' "$LEAVES_TSV" && ok "F4a 8 列目の repo が cwd の git-common-dir（wall-clock 記録と同じ列）" || bad "F4a repo 列: $(cut -f8 "$LEAVES_TSV" | sort -u | tr '\n' ' ')"
awk -F'\t' '$5 == "skill" && $6 == "ace-refine" && $7 == "transcript" { f = 1 } END { exit !f }' "$LEAVES_TSV" && ok "F4b スラッシュコマンド形（<command-name>/ff-dev-toolkit:ace-refine</command-name>）の起動も記録する" || bad "F4b スラッシュコマンド形が記録されていない"
if ! grep -F 'merge-cleanup' "$LEAVES_TSV" >/dev/null && ! grep -F 'retrospective' "$LEAVES_TSV" >/dev/null; then
  ok "F4c 本文に \"skill\":\"…\" の文字列があるだけ（tool_use でもコマンドでもない）では記録しない"
else
  bad "F4c 本文の文字列から偽の到達が記録された: $(grep -F -e merge-cleanup -e retrospective "$LEAVES_TSV" | tr '\n' '|')"
fi
n_before="$(wc -l < "$LEAVES_TSV" | tr -d ' ')"
run_hook "$(json_stop s1 "$GITFIX" "$TRANSCRIPT")"
n_after="$(wc -l < "$LEAVES_TSV" | tr -d ' ')"
[ "$RC" -eq 0 ] && [ "$n_before" = "$n_after" ] && ok "F5 同じセッションの 2 回目の Stop は同じ葉を追記しない（${n_before} 行のまま）" || bad "F5 2 回目の Stop: rc=$RC before=$n_before after=$n_after"
run_hook "$(json_stop s2 "$GITFIX" "$TRANSCRIPT")"
n_s2="$(awk -F'\t' '$4 == "s2" { n++ } END { print n + 0 }' "$LEAVES_TSV")"
[ "$RC" -eq 0 ] && [ "$n_s2" -ge 3 ] && ok "F6 別セッションは別に記録される（s2: ${n_s2} 行。根の答えは UserPromptSubmit が無いので無し）" || bad "F6 別セッション: rc=$RC n=$n_s2"
awk -F'\t' '$4 == "s2" && $5 == "route" { f = 1 } END { exit f }' "$LEAVES_TSV" && ok "F7 根の答えの記録が無いセッションは route 行を作らない" || bad "F7 根の答え無しで route 行が出た"
# Issue 番号が取れないブランチ
( cd "$GITFIX" && git checkout -q -b nonumber )
run_hook "$(json_stop s3 "$GITFIX" "$TRANSCRIPT")"
awk -F'\t' '$4 == "s3" && $3 == "-" { f = 1 } END { exit !f }' "$LEAVES_TSV" && ok "F8 ブランチに Issue 番号が無ければ Issue 列は -" || bad "F8 Issue 番号無し: $(awk -F'\t' '$4 == "s3"' "$LEAVES_TSV" | head -1)"
( cd "$GITFIX" && git checkout -q 'feature/#4321-probe' )
# fail-soft
STATE_SAVE="$STATE"; STATE="$TEST_TMP/state-file"; : > "$STATE"
run_hook "$(json_stop s4 "$GITFIX" "$TRANSCRIPT")"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "${ERR#*"(unmeasured)"}" != "$ERR" ] && ok "F9 記録先が作れない（通常ファイル）ときは止めず無出力、stderr に (unmeasured)" || bad "F9 fail-soft: rc=$RC out=[$OUT] err=[$ERR]"
STATE="$STATE_SAVE"
run_hook "$(json_stop s5 "$GITFIX" "$TEST_TMP/no-transcript.jsonl")"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "${ERR#*"(unmeasured)"}" != "$ERR" ] && awk -F'\t' '$4 == "s5" && $6 == "decision-tree" { f = 1 } END { exit !f }' "$LEAVES_TSV" \
  && ok "F10 transcript が読めなければ Skill の葉だけ (unmeasured) にして自身は記録する" || bad "F10 transcript 不在: rc=$RC err=[$ERR]"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"no skills were used; the word \"skill\":\"close-issue\" appears only here"}]}}' > "$TEST_TMP/no-evidence.jsonl"
run_hook "$(json_stop s5b "$GITFIX" "$TEST_TMP/no-evidence.jsonl")"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "${ERR#*"(unmeasured)"}" != "$ERR" ] && ! awk -F'\t' '$4 == "s5b" && $5 == "skill" { f = 1 } END { exit !f }' "$LEAVES_TSV"; then
  ok "F10a Skill 起動の痕跡（tool_use / コマンド）が無い transcript は skill の葉を 0 件として記録せず (unmeasured)"
else
  bad "F10a 痕跡なし: rc=$RC err=[$ERR] rows=$(awk -F'\t' '$4 == "s5b"' "$LEAVES_TSV" | tr '\n' '|')"
fi
run_hook "$(json_stop s5c "$TEST_TMP" "$TRANSCRIPT")"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "${ERR#*"(unmeasured)"}" != "$ERR" ] && ! awk -F'\t' '$4 == "s5c" { f = 1 } END { exit !f }' "$LEAVES_TSV" \
  && ok "F10b cwd が git リポジトリでなく repo を引けなければ何も記録せず (unmeasured)" || bad "F10b repo 不明: rc=$RC err=[$ERR]"
run_hook "$(json_stop '../s6' "$GITFIX" "$TRANSCRIPT")"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "${ERR#*"(unmeasured)"}" != "$ERR" ] && [ ! -e "$STATE/metrics/sessions/../s6.seen" ] && ok "F11 session_id にパス区切りがあれば記録せず (unmeasured)" || bad "F11 不正 session_id: rc=$RC err=[$ERR]"
n_before="$(wc -l < "$LEAVES_TSV" | tr -d ' ')"
run_hook "$(json_stop s7 "$GITFIX" "$TRANSCRIPT")" FF_DEV_TOOLKIT_SKIP_DECISION_TREE=1
n_after="$(wc -l < "$LEAVES_TSV" | tr -d ' ')"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$n_before" = "$n_after" ] && ok "F12 FF_DEV_TOOLKIT_SKIP_DECISION_TREE=1 は何も記録しない" || bad "F12 skip env: rc=$RC before=$n_before after=$n_after"
run_hook "$(jq -nc '{hook_event_name: "PreToolUse", session_id: "s8", tool_name: "Bash", tool_input: {command: "echo"}}')"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -e "$STATE/metrics/sessions/s8.seen" ] && ok "F13 対象外のイベントは無出力で何もしない" || bad "F13 対象外イベント: rc=$RC out=[$OUT]"
run_hook '{"hook_event_name":"Stop","session_id":"s9"'
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "F14 壊れた JSON 入力は止めず無出力（fail-open）" || bad "F14 壊れた JSON: rc=$RC out=[$OUT]"
# ASDD ゲートの早期終了経路でも stdin を読み切る
ASDD_ON="$TEST_TMP/asdd-on"; ASDD_OFF="$TEST_TMP/asdd-off"; mkdir -p "$ASDD_ON" "$ASDD_OFF"
ff_asdd_fixture "$ASDD_ON" true; ff_asdd_fixture "$ASDD_OFF" false
ASDD_PAYLOAD="$(ff_asdd_big_payload '{"hook_event_name":"Stop","session_id":"drain","cwd":"/tmp"}')"
ff_asdd_drain_probe "$HOOK" "$ASDD_PAYLOAD" "$ASDD_ON" PATH=/nonexistent
[ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ] && ok "F15 .asdd 設定あり + node 不在（ゲート停止）でも stdin を読み切って無出力 exit 0" || bad "F15 drain（node 不在）: rc=$FF_ASDD_DRAIN_RC out=[$FF_ASDD_DRAIN_OUT]"
if command -v node >/dev/null 2>&1; then
  ff_asdd_drain_probe "$HOOK" "$ASDD_PAYLOAD" "$ASDD_OFF"
  [ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ] && ok "F16 features.hooks=false でも stdin を読み切って無出力 exit 0" || bad "F16 drain（feature 無効）: rc=$FF_ASDD_DRAIN_RC out=[$FF_ASDD_DRAIN_OUT]"
else
  echo "  ○ skip: node が無いため features.hooks=false 経路は未検査"
fi

# ============================================================================
echo "decision-tree G: 読み手（effort-report.sh --unreached-leaves）"
run_report() { # [NAME=VALUE ...] -- <args>
  local envs=()
  while [ $# -gt 0 ]; do case "$1" in --) shift; break ;; esac; envs+=("$1"); shift; done
  RC=0
  if [ ${#envs[@]} -gt 0 ]; then OUT="$(env "${envs[@]}" bash "$REPORT" "$@" 2>"$TEST_TMP/report.err")" || RC=$?
  else OUT="$(bash "$REPORT" "$@" 2>"$TEST_TMP/report.err")" || RC=$?; fi
  ERR="$(cat "$TEST_TMP/report.err" 2>/dev/null || true)"
}
run_report FF_DEV_TOOLKIT_STATE_DIR="$TEST_TMP/no-such-state" -- --unreached-leaves
[ "$RC" -eq 0 ] && [ "${OUT#*"(unmeasured)"}" != "$OUT" ] && ok "G1 記録の不在は (unmeasured)（到達 0 件とは言わない）" || bad "G1 記録不在: rc=$RC out=[$OUT] err=[$ERR]"
run_report FF_DEV_TOOLKIT_STATE_DIR="$TEST_TMP/no-such-state" -- --unreached-leaves --format kv
[ "$RC" -eq 0 ] && [ "$(kv leaves_unreached)" = "(unmeasured)" ] && ok "G2 kv でも leaves_unreached=(unmeasured)" || bad "G2 kv 記録不在: rc=$RC out=[$OUT]"
REC="$TEST_TMP/rec"; mkdir -p "$REC/metrics"
now="$(date -u +%s)"; old=$((now - 30 * 86400))
# 8 列目は repo（git-common-dir）。対象 repo は GITFIX で、別 repo の行（/elsewhere/.git）は混ぜない
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "2026-09-23T00:00:00Z" "$now" 1838 sA skill pre-commit-check transcript "$GITFIX_REPO" \
  "2026-08-24T00:00:00Z" "$old" 1700 sB skill close-issue transcript "$GITFIX_REPO" \
  "2026-09-23T00:00:00Z" "$now" 1838 sA route fast root "$GITFIX_REPO" \
  "2026-09-23T00:00:00Z" "$now" 1838 sZ skill merge-cleanup transcript "/elsewhere/.git" \
  > "$REC/metrics/leaves.tsv"
printf 'broken line\n' >> "$REC/metrics/leaves.tsv"
# 読み手の既定 repo はカレントディレクトリなので、run_report は --repo-dir で対象 repo を固定する
run_report_repo() { run_report "$@" --repo-dir "$GITFIX"; }
run_report_repo FF_DEV_TOOLKIT_STATE_DIR="$REC" -- --unreached-leaves --days 7 --format kv
if [ "$RC" -eq 0 ] && [ "$(kv leaves_records)" = "3" ] && [ "$(kv leaves_in_window)" = "2" ] && [ "$(kv leaves_malformed)" = "1" ]; then
  ok "G3 記録 3 行 / 期間内 2 行 / 読めない行 1 行を件数で出す"
else
  bad "G3 件数: rc=$RC out=[$OUT] err=[$ERR]"
fi
LIST="$(kv leaves_unreached_list)"
if [ "${LIST#*"skill:pre-commit-check"}" = "$LIST" ] && [ "${LIST#*"skill:close-issue"}" != "$LIST" ] && [ "${LIST#*"skill:ace-curate"}" != "$LIST" ]; then
  ok "G4 期間内に到達した葉は列挙から外れ、期間外（30 日前）の到達は数えない"
else
  bad "G4 列挙: [$LIST]"
fi
[ "$(kv leaves_unavailable)" -gt 0 ] && [ "${LIST#*"hook:guard-"}" = "$LIST" ] && [ "${LIST#*"doc:"}" = "$LIST" ] && ok "G5 供給源が未配線の hook / doc の葉は到達 0 に数えず (unavailable) 件数で出す" || bad "G5 hook の葉の扱い: unavailable=$(kv leaves_unavailable) list=[$LIST]"
[ "${LIST#*"skill:merge-cleanup"}" != "$LIST" ] && [ "$(kv repo)" = "$GITFIX_REPO" ] && ok "G5a 別 repo の到達行は採らない（merge-cleanup は対象 repo では到達 0 のまま）" || bad "G5a repo で絞れていない: repo=$(kv repo) list=[$LIST]"
run_report_repo FF_DEV_TOOLKIT_STATE_DIR="$REC" -- --unreached-leaves --days 7
[ "$RC" -eq 0 ] && [ "${OUT#*"読めない行が 1 行"}" != "$OUT" ] && [ "${OUT#*"- skill:close-issue"}" != "$OUT" ] && [ "${OUT#*"既知の残差"}" != "$OUT" ] && ok "G6 text 形式でも読めない行の警告・到達 0 の葉の列挙・既知の残差のヘッダが出る" || bad "G6 text: rc=$RC out=[$OUT]"
run_report_repo FF_DEV_TOOLKIT_STATE_DIR="$REC" -- --unreached-leaves --days 0
[ "$RC" -eq 2 ] && ok "G7 --days 0 は exit 2" || bad "G7 --days 0: rc=$RC"
if [ "$(id -u)" != "0" ]; then
  chmod 000 "$REC/metrics/leaves.tsv"
  run_report_repo FF_DEV_TOOLKIT_STATE_DIR="$REC" -- --unreached-leaves --format kv
  chmod 644 "$REC/metrics/leaves.tsv"
  [ "$RC" -eq 0 ] && [ "$(kv leaves_source)" = "(unmeasured)" ] && [ "$(kv leaves_unreached)" = "(unmeasured)" ] && ok "G8 記録があるのに読めなくても (unmeasured)（0 件の到達にしない）" || bad "G8 読めない記録: rc=$RC out=[$OUT]"
else
  echo "  ○ skip: root 実行のため読み取り不可の記録は作れず G8 は未検査"
fi
run_report_repo -- --unreached-leaves --metrics-dir "$REC/metrics" --days 7 --format kv
[ "$RC" -eq 0 ] && [ "$(kv leaves_records)" = "3" ] && [ "$(kv metrics_dir)" = "$REC/metrics" ] && ok "G9 --metrics-dir で記録の置き場を指定できる（env と同じ読み方）" || bad "G9 --metrics-dir: rc=$RC out=[$OUT]"
run_report FF_DEV_TOOLKIT_STATE_DIR="$REC" -- --unreached-leaves --repo-dir "$TEST_TMP" --format kv
[ "$RC" -eq 0 ] && [ "$(kv repo)" = "(unresolved)" ] && [ "$(kv leaves_unreached)" = "(unmeasured)" ] && ok "G10 --repo-dir が git リポジトリでなければ repo=(unresolved) で (unmeasured)" || bad "G10 repo 不明: rc=$RC out=[$OUT]"
run_report FF_DEV_TOOLKIT_STATE_DIR="$REC" -- --unreached-leaves --issue-metrics 1 --repo-dir "$GITFIX"
[ "$RC" -eq 2 ] && ok "G11 --issue-metrics と --unreached-leaves の同時指定は exit 2" || bad "G11 同時指定: rc=$RC"

# --- H. レビュー経路（scripts/review-route.sh）: 根の答えをレーン構成と完了報告の 1 行へ写す ---
REVIEW_ROUTE_SH="$PLUGIN_ROOT/scripts/review-route.sh"
run_review_route() { # <review-route.sh の引数...>
  RC=0
  OUT="$(env -u FF_JEV_MODE -u FF_JEV_POINTS -u FF_JEV_ENABLED -u TYPESAFE_API_KEY -u TYPESAFE_API_KEY_FILE \
    -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT \
    bash "$REVIEW_ROUTE_SH" "$@" 2>"$TEST_TMP/review-route.err")" || RC=$?
}
assert_review_route() { # <label> <rc> <route> <lanes> <report line>
  if [ "$RC" -eq "$2" ] && [ "$(kv REVIEW_ROUTE)" = "$3" ] && [ "$(kv REVIEW_LANES)" = "$4" ] \
    && [ "$(kv REVIEW_REPORT_LINE)" = "$5" ]; then
    ok "$1"
  else
    bad "$1: rc=$RC route=[$(kv REVIEW_ROUTE)] lanes=[$(kv REVIEW_LANES)] line=[$(kv REVIEW_REPORT_LINE)]"
  fi
}
run_review_route --files docs/a.md docs/b.md --lines 12
assert_review_route "H1 docs のみ → fast（親の直読 + Codex 1 レーン）で、報告行に根拠と行数が出る" \
  0 fast "parent-read+codex:1" "経路: fast（根拠: docs のみ / 12 行）"
run_review_route --files plugins/ff-dev-toolkit/scripts/x.sh --lines 4
assert_review_route "H2 10 行以下の実装 → fast（小さい差分）" \
  0 fast "parent-read+codex:1" "経路: fast（根拠: 小さい差分 / 4 行）"
run_review_route --files plugins/ff-dev-toolkit/scripts/x.sh --lines 40
assert_review_route "H3 実装変更 → full（Codex 1 + Claude 4 観点の 5 レーン）" \
  0 full "codex:1+claude:4" "経路: full（根拠: 実装変更 / 40 行）"
run_review_route --files plugins/ff-dev-toolkit/hooks/hooks.json
assert_review_route "H4 契約 path → full。行数が無い回は「行数不明」" \
  0 full "codex:1+claude:4" "経路: full（根拠: 契約 path plugins/ff-dev-toolkit/hooks/hooks.json / 行数不明）"
: > "$TEST_TMP/empty-files.txt"
run_review_route --files-from "$TEST_TMP/empty-files.txt"
assert_review_route "H5 変更 0 件 → none（ホスト判定）" \
  0 none "host" "経路: none（根拠: 変更 0 件 / 行数不明）"
run_review_route --files x.sh --lines abc
assert_review_route "H6 根が判定不能（exit 2）でも none を出して exit 2（fast / full へ黙って倒さない）" \
  2 none "host" "経路: none（根拠: 判定不能（--lines が整数ではありません: abc） / 行数不明）"
run_review_route --files docs/a.md --lines 3
H_WRAPPED="$(printf '%s\n' "$OUT" | grep '^DT_' || true)"
run_router -- --files docs/a.md --lines 3
if [ -n "$H_WRAPPED" ] && [ "$H_WRAPPED" = "$OUT" ]; then
  ok "H7 根の DT_* 行をバイト同一で通す（経路の判定を再実装しない）"
else
  bad "H7 根の出力と食い違う: wrapped=[$H_WRAPPED] root=[$OUT]"
fi
run_review_route --no-such-flag
[ "$RC" -eq 64 ] && [ -z "$(kv REVIEW_ROUTE)" ] && ok "H8 使い方の誤りは exit 64 で経路を出さない" || bad "H8 使い方の誤り: rc=$RC out=[$OUT]"
# ルータ（決定木の根）が無い配置: 判定不能として none を出して exit 2（ヘッダの契約。黙って止まらない）
H_NOROUTER="$TEST_TMP/h-norouter"
mkdir -p "$H_NOROUTER/scripts" "$H_NOROUTER/.claude-plugin"
cp "$REVIEW_ROUTE_SH" "$H_NOROUTER/scripts/"
cp "$PLUGIN_ROOT/.claude-plugin/plugin.json" "$H_NOROUTER/.claude-plugin/"
RC=0
OUT="$(env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT bash "$H_NOROUTER/scripts/review-route.sh" --files docs/a.md 2>/dev/null)" || RC=$?
assert_review_route "H9 決定木のルータが無い配置でも none / host と判定不能の報告行を出して exit 2" \
  2 none "host" "経路: none（根拠: 判定不能（決定木のルータがありません） / 行数不明）"

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ decision-tree verify: $FAIL 件失敗（$PASS 件 pass）" >&2
  REACHED_END=1
  exit 1
fi
REACHED_END=1
echo "✓ decision-tree verify: 全 $PASS 件 pass"
