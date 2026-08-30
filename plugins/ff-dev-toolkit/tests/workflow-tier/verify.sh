#!/usr/bin/env bash
#
# Git Workflow の tier 判定と、段の単一正本の契約検査（Issue #801）。
#
# 背景: ワークフローの段は 4 つの文書へ写されており、それぞれ違う段数を書いていた
# （TASKS が正本と名指ししていた MASTER が 9・DEPLOYMENT が 10・配布 git-workflow が
# 11・TASKS 自身が実質 9。MASTER 自身は DEPLOYMENT へ委譲していたので、正本ポインタが
# 1 段ずれていた）。
# 写しは独立に腐るので、段は 1 箇所（DEPLOYMENT.md §主要ステップ）だけが持ち、
# 残りは参照する形へ寄せた。あわせて「変更規模に関わらず全段を同じ重さで通す」運用を
# tier（フル / 軽量 / 標準）へ分け、判定を scripts/workflow-tier.sh へ機械化した。
#
# 本 suite が固定するもの:
#   A. 判定の振る舞い（受け入れ条件そのもの）。評価順・fail-closed・上書き・入力経路
#   B. 文書とスクリプトの対応。tier の値と順序が表と一致し、参照側が段を持たないこと
#   C. 段数・tier 件数・分布の割合を**本文へ手書きしていない**こと
#
# C は否定の主張なので、走査が空振りして緑になる形（対象を取り違える・正規表現が
# 何にも当たらない）を潰す必要がある。実 tree を走査して 0 件であることに加え、
# **一時コピーへ違反を注入して同じ走査が赤くなること**を毎回測る。注入が検出できない
# 回は、実 tree の 0 件も「検出力の無い 0 件」なので赤にする。
#
# B は**節スコープ**で照合する（§主要ステップ 見出しから次の同レベル見出しまでを行ベースで
# 切り出す）。文書全体を grep すると Changelog に残った古い表で通り、読者が実際に読む節から
# tier 表が消えても緑になる。C は逆に**ファイル全体**を走査する — 段数の手書きは節の外
# （概要・クイックスタート・表）にこそ現れるため。数値は装飾（`**10**` / `` `10` ``）を
# 許して拾う（docs-fact-drift が Issue #529 で踏んだ穴をこちらで開け直さない）。
#
# 配置差: 公開リポジトリもモノレポと同じ `plugins/ff-dev-toolkit/` 構造を保つ（実測）。
# 違うのは**リポジトリ側の `docs/` を持たない**ことだけなので、配布物とスキルは常に
# 検査し、`docs/` は存在するときだけ検査して件数ガードを切り替える。
# 走査対象は `plugins/ff-dev-toolkit/` を文字列で組み立てず、**suite 自身の位置から
# 解決した PLUGIN_ROOT** を起点にする（配置の前提をコメントの主張ではなく実行時の
# 解決へ寄せる。FF_DOCS_REPO_ROOT で repo 側を差し替えても配布物側は実体を見る）。
#
# 依存は POSIX ユーティリティ + `mktemp` + `git`。一時領域が使えない場合は、それを要する
# 検査（C の変異注入 / D の実 git 差分 / `--paths-from <file>`）だけを名指しで skip し、
# **全件実行（FF_RUN_ALL_FULL=1）では skip を許さず赤にする**。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
# 公開リポジトリもモノレポと同じ `plugins/ff-dev-toolkit/` 構造を保つので、`../..` は
# どちらの配置でもリポジトリルートになる。ROOT の用途は**リポジトリ側 docs/ の有無判定**
# だけで、配布物・スキルは PLUGIN_ROOT から解決する。
DEFAULT_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
ROOT="${FF_DOCS_REPO_ROOT:-$DEFAULT_ROOT}"

TIER_SH="$PLUGIN_ROOT/scripts/workflow-tier.sh"

# 走査本文の切り出しは**共有実装**を使う（自前に書き直すと、片方だけ直る drift が
# そのまま検出漏れになる — docs-scan-mirror が常設ゲートで見ている型）。
# `ff_docs_claim_body` は Frontmatter と `## Changelog` 節を落とし、フェンスの中身は残す。
# Changelog を除くのが要点で、そこは**その時点の事実の記録**（「段数の記載を 88→89 に
# 更新した」等）であり、現在の実体と一致する必要がない。
# shellcheck source=../lib/docs-scan.sh
. "$TESTS_DIR/lib/docs-scan.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# 一時領域の獲得。mktemp の stderr は捨てない — 捨てると read-only 以外の失敗
# （TMPDIR が不正・quota 超過）まで「書き込み可能な環境で再実行してください」へ
# 誤帰属し、壊れた TMPDIR が検出力の実測を静かに無効化し続ける（run-all case 15）。
# stderr は stdout へ畳んで受ける。`{ VAR=$(...) ; } 2>&1` は代入がサブシェルで消える。
TMP_BASE="${TMPDIR:-/tmp}"
TMP_FAIL_REASON=""
make_tmpdir() { # $1=接頭辞。成功なら path を stdout へ、失敗なら空 + TMP_FAIL_REASON
  local out rc
  out="$(mktemp -d "${TMP_BASE%/}/$1.XXXXXX" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && [ -d "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  TMP_FAIL_REASON="mktemp rc=${rc}: ${out:-理由なし} / TMPDIR=${TMP_BASE}"
  return 1
}

# 一時領域が無いときの扱い。**全件実行（FF_RUN_ALL_FULL=1）では skip を許さない。**
# 全件実行は週次 CI と、定期実行点で healthy を確認できない回の代替経路（ADR-037 /
# ADR-039）なので、そこで検出力の実測を
# 飛ばすと「登録 suite は緑」のまま否定契約の破損を出荷できてしまう。
tmp_unavailable() { # $1=飛ばす検査の名前 $2=飛ばした結果どうなるか
  if [ "${FF_RUN_ALL_FULL:-0}" = "1" ]; then
    bad "一時領域が使えないため $1 を実行できません（全件実行では skip を許容しません。$2。${TMP_FAIL_REASON}）"
  else
    echo "  ○ skip: 一時領域が使えないため $1 を実行していません（$2。${TMP_FAIL_REASON}）"
  fi
}

if [ ! -f "$TIER_SH" ]; then
  echo "✗ 判定スクリプトがありません: $TIER_SH" >&2
  exit 1
fi

# ---- A. 判定の振る舞い --------------------------------------------------------
# 判定器は path 一覧を受ける形（暫定判定の入口）を持つので、git の状態を捏造せずに
# 全ケースを回せる。確定判定（引数なし）との違いは入力の出所だけで、分類は同じ関数。
echo "== A. tier 判定の振る舞い =="

tier_of() { # 出力から WORKFLOW_TIER の値だけを取り出す
  bash "$TIER_SH" "$@" 2>/dev/null | sed -n 's/^WORKFLOW_TIER=//p'
}

expect_tier() { # $1=期待 tier $2=説明 $3...=引数
  local want="$1" label="$2"; shift 2
  local got rc out
  # 分類値だけを見て rc を捨てると、「light を出しつつ exit 2 で終わる」退行を見逃す。
  out="$(bash "$TIER_SH" "$@" 2>/dev/null)"; rc=$?
  got="$(printf '%s\n' "$out" | sed -n 's/^WORKFLOW_TIER=//p')"
  if [ "$got" != "$want" ]; then
    bad "$label → 期待 $want / 実際 ${got:-（出力なし）}"
  elif [ "$rc" -ne 0 ]; then
    bad "$label → $want だが終了コードが 0 ではありません（rc=${rc}）"
  else
    ok "$label → $want"
  fi
}

# AC-1: docs-template を含む差分は、`.md` のみでも規則の順序で full が勝つ
expect_tier full "配布物の .md のみ（順序で full が light に勝つ）" \
  "plugins/ff-dev-toolkit/docs-template/MASTER.md" "README.md"
expect_tier full "plugin.json を含む" "plugins/ff-dev-toolkit/.claude-plugin/plugin.json"
expect_tier full "package.json を含む" "package.json" "src/index.ts"
# AC-2: .md のみ
expect_tier light ".md のみ" "docs/MASTER.md" "README.md"
# AC-3: 実装ファイルを含む
expect_tier standard "実装ファイルを含む" "plugins/ff-dev-toolkit/skills/spec-driven/SKILL.md" "scripts/x.sh"
expect_tier standard ".md 以外が 1 件でも混じれば standard" "docs/MASTER.md" "tests/x/verify.sh"

# fail-closed: 判定材料が 0 件でも light へは倒さない
_empty="$(printf '' | bash "$TIER_SH" --paths-from - 2>/dev/null | sed -n 's/^WORKFLOW_TIER=//p')"
if [ "$_empty" = "standard" ]; then
  ok "入力が 0 件のとき standard（空差分を軽量と読み替えない）"
else
  bad "入力が 0 件のとき standard になりません（実際: ${_empty:-（出力なし）}）"
fi

# 入力経路が変わっても分類は同じ（stdin 経由）
_stdin="$(printf '%s\n' "docs/A.md" "docs/B.md" | bash "$TIER_SH" --paths-from - 2>/dev/null | sed -n 's/^WORKFLOW_TIER=//p')"
if [ "$_stdin" = "light" ]; then
  ok "stdin 経由でも同じ分類（--paths-from -）"
else
  bad "stdin 経由の分類が args と一致しません（実際: ${_stdin:-（出力なし）}）"
fi

# 解決できない base は「軽い側」ではなく検査不能（exit 2）
_out="$(bash "$TIER_SH" --base ff/no-such-ref-for-test 2>/dev/null)"; _rc=$?
case "$_out" in
  *"WORKFLOW_TIER=unknown"*)
    if [ "$_rc" -ne 2 ]; then
      bad "解決できない base の終了コードが 2 ではありません（rc=${_rc}）"
    # 内容まで見る。`rev-parse --verify` のガードを外しても `git diff` 側の失敗で
    # 同じ unknown + exit 2 になるため、理由を照合しないと「base 解決のガード」を
    # 固定したことにならない。
    elif case "$_out" in *"SKIP_REASON=base ref を解決できません"*) true ;; *) false ;; esac; then
      ok "解決できない base は unknown + exit 2 + base 解決の理由（判定不能を分類結果に化けさせない）"
    else
      bad "unknown にはなるが理由が base 解決ではありません（ガードの所在が固定できていない）: ${_out}"
    fi
    ;;
  *) bad "解決できない base で unknown を返しません（出力: ${_out:-空}）" ;;
esac

# 不明なオプションは使い方の誤りとして止まる（黙って標準へ倒れない）
bash "$TIER_SH" --no-such-flag >/dev/null 2>&1; _rc=$?
if [ "$_rc" -eq 64 ]; then
  ok "不明なオプションは exit 64（誤用を分類結果に化けさせない）"
else
  bad "不明なオプションが exit 64 になりません（rc=${_rc}）"
fi

# full パターンは差し替えられる（導入先プロジェクトは配布物の場所が違う）
_ov="$(WORKFLOW_TIER_FULL_PATTERNS='(^|/)dist/' bash "$TIER_SH" "dist/app.js" 2>/dev/null | sed -n 's/^WORKFLOW_TIER=//p')"
_ov2="$(WORKFLOW_TIER_FULL_PATTERNS='(^|/)dist/' bash "$TIER_SH" "plugins/ff-dev-toolkit/docs-template/MASTER.md" 2>/dev/null | sed -n 's/^WORKFLOW_TIER=//p')"
if [ "$_ov" = "full" ] && [ "$_ov2" = "light" ]; then
  ok "WORKFLOW_TIER_FULL_PATTERNS が既定を置き換える（追加ではなく置換）"
else
  bad "full パターンの上書きが効いていません（dist=${_ov:-なし} / docs-template=${_ov2:-なし}）"
fi

# 壊れた上書きパターンは「一致なし」ではなく検査不能。`grep -E` は不正な ERE で rc=2 に
# なるが、判定側は `grep | head -1` で使うためパイプの rc は head のものになり、一致 0 件と
# 区別が付かない。検証を外すと配布物の変更が light で通る（実測で確認した fail-open）。
# どちらも「未閉じ」で、GNU / BSD / ugrep のいずれでも rc=2 になる形にする。
# 先頭の `*` は POSIX ERE で未定義動作（リテラル扱いの実装がある）ため使わない。
for _bad in '(^|/)docs-template/[' '(unclosed'; do
  _bad_out="$(WORKFLOW_TIER_FULL_PATTERNS="$_bad" bash "$TIER_SH" "plugins/ff-dev-toolkit/docs-template/MASTER.md" 2>/dev/null)"
  _bad_rc=$?
  case "$_bad_out" in
    *"WORKFLOW_TIER=unknown"*)
      if [ "$_bad_rc" -eq 2 ]; then
        ok "不正な full パターン（${_bad}）は unknown + exit 2"
      else
        bad "不正な full パターン（${_bad}）の終了コードが 2 ではありません（rc=${_bad_rc}）"
      fi
      ;;
    *) bad "不正な full パターン（${_bad}）が分類結果へ化けています: ${_bad_out:-空}" ;;
  esac
done

# 空（空白・改行だけ）の上書きは「full に当たる path が 1 件も無い」状態を黙って作る
for _empty_pat in '   ' '
'; do
  _ep_out="$(WORKFLOW_TIER_FULL_PATTERNS="$_empty_pat" bash "$TIER_SH" "docs/a.md" 2>/dev/null)"
  _ep_rc=$?
  case "$_ep_out" in
    *"WORKFLOW_TIER=unknown"*)
      if [ "$_ep_rc" -eq 2 ]; then
        ok "空の full パターンは unknown + exit 2（全変更を軽い側へ倒さない）"
      else
        bad "空の full パターンの終了コードが 2 ではありません（rc=${_ep_rc}）"
      fi
      ;;
    *) bad "空の full パターンが分類結果へ化けています: ${_ep_out:-空}" ;;
  esac
done

# rename ですり抜けないこと: 判定は移動元 path も見る（ACE-460-1 と同型の実バグ）
_mv="$(bash "$TIER_SH" "b.md" "plugins/ff-dev-toolkit/docs-template/a.md" 2>/dev/null | sed -n 's/^WORKFLOW_TIER=//p')"
if [ "$_mv" = "full" ]; then
  ok "配布物からの移動は移動元 path で full（--no-renames が前提）"
else
  bad "移動元 path を見ていません（実際: ${_mv:-なし}）"
fi
# コメント行に当たらない形で**起動行だけ**を見る。本スクリプトは説明コメントと
# SKIP_REASON にも `--no-renames` を含むので、素朴な固定文字列検査は「実コマンドから
# 消してもコメントが残れば緑」になる（= 宣言している事故を検出できない）。
# 振る舞い側の実測は D で行う（引数経路は git diff を通らないので A では測れない）。
if grep -qE '^[[:space:]]*[^#[:space:]].*PATHS="\$\(git .*diff --no-renames --name-only' "$TIER_SH"; then
  ok "確定判定の git diff 起動行に --no-renames がある"
else
  bad "git diff の起動行に --no-renames がありません（rename 検出で移動元 path が消え、配布物の移動が light へ化ける）"
fi

# `--paths-from <file>`（SOURCE=file）経路。stdin だけを通していると file 分岐が
# 一度も実行されない。読めないファイル・引数との併用も併せて固定する。
_pf_dir="$(make_tmpdir wt-pf)"
if [ -z "$_pf_dir" ]; then
  tmp_unavailable "--paths-from <file> 経路の検査" "file 分岐と読み取り失敗が未実測"
else
  _pf="$_pf_dir/paths.txt"
  printf '%s\n' "docs/a.md" "docs/b.md" > "$_pf"
  _pf_out="$(bash "$TIER_SH" --paths-from "$_pf" 2>/dev/null)"
  _pf_tier="$(printf '%s\n' "$_pf_out" | sed -n 's/^WORKFLOW_TIER=//p')"
  _pf_src="$(printf '%s\n' "$_pf_out" | sed -n 's/^SOURCE=//p')"
  if [ "$_pf_tier" = "light" ] && [ "$_pf_src" = "file" ]; then
    ok "--paths-from <file> が light を返し SOURCE=file を名乗る"
  else
    bad "--paths-from <file> の結果が想定外です（tier=${_pf_tier:-なし} / SOURCE=${_pf_src:-なし}）"
  fi
  # 読めないファイルは「0 件 = standard」ではなく検査不能
  chmod 000 "$_pf" 2>/dev/null
  _pf_deny_out="$(bash "$TIER_SH" --paths-from "$_pf" 2>/dev/null)"; _pf_deny_rc=$?
  chmod 644 "$_pf" 2>/dev/null
  case "$_pf_deny_out" in
    *"WORKFLOW_TIER=unknown"*)
      if [ "$_pf_deny_rc" -eq 2 ]; then
        ok "読み取り不能な path 一覧は unknown + exit 2（空入力の standard に化けない）"
      else
        bad "読み取り不能な path 一覧の終了コードが 2 ではありません（rc=${_pf_deny_rc}）"
      fi
      ;;
    *)
      # root 実行では chmod 000 でも読めるため、その場合だけ名指しで skip する
      echo "  ○ skip: chmod 000 のファイルが読めたため読み取り失敗の経路を実測していません（root 実行と思われます）"
      ;;
  esac
  # 判定材料の出所は 1 つに保つ（誤用は黙って一方を捨てない）
  bash "$TIER_SH" --paths-from "$_pf" "docs/a.md" >/dev/null 2>&1
  if [ $? -eq 64 ]; then
    ok "--paths-from と path 引数の併用は exit 64"
  else
    bad "--paths-from と path 引数の併用が止まりません"
  fi
  bash "$TIER_SH" --base develop "docs/a.md" >/dev/null 2>&1
  if [ $? -eq 64 ]; then
    ok "--base と path 引数の併用は exit 64（--base を黙って捨てない）"
  else
    bad "--base と path 引数の併用が止まりません（暫定判定で base を渡した誤解が残る）"
  fi
  rm -rf "$_pf_dir"
fi

# stdin 経路の SOURCE も名乗りを見る（分類値だけでは消費側の分岐が壊れても気づけない）
_src_stdin="$(printf '%s\n' "docs/a.md" | bash "$TIER_SH" --paths-from - 2>/dev/null | sed -n 's/^SOURCE=//p')"
if [ "$_src_stdin" = "stdin" ]; then
  ok "stdin 経路は SOURCE=stdin を名乗る"
else
  bad "stdin 経路の SOURCE が想定外です（${_src_stdin:-なし}）"
fi

# 出力プロトコルそのものの検査。分類値だけを見ていると、消費側が読む補助フィールド
# （SOURCE / CHANGED / MATCHED / SKIP_REASON）が壊れても緑のままになる。
_p_full="$(bash "$TIER_SH" "plugins/ff-dev-toolkit/docs-template/MASTER.md" "README.md" 2>/dev/null)"
_p_src="$(printf '%s\n' "$_p_full" | sed -n 's/^SOURCE=//p')"
_p_cnt="$(printf '%s\n' "$_p_full" | sed -n 's/^CHANGED=//p')"
_p_mat="$(printf '%s\n' "$_p_full" | sed -n 's/^MATCHED=//p')"
if [ "$_p_src" = "args" ] && [ "$_p_cnt" = "2" ]; then
  ok "full の出力に SOURCE=args と CHANGED=2 がある"
else
  bad "full の補助フィールドが壊れています（SOURCE=${_p_src:-なし} / CHANGED=${_p_cnt:-なし}）"
fi
case "$_p_mat" in
  *docs-template/MASTER.md) ok "MATCHED が full を決めた実際の path を指す" ;;
  *) bad "MATCHED が一致した path になっていません（${_p_mat:-なし}）" ;;
esac
_p_light="$(bash "$TIER_SH" "docs/a.md" 2>/dev/null)"
_p_light_mat="$(printf '%s\n' "$_p_light" | sed -n 's/^MATCHED=//p')"
if [ -n "$_p_light_mat" ]; then
  bad "full 以外でも MATCHED を出しています（full の判定 path という意味が消える）"
else
  ok "MATCHED は full のときだけ出る"
fi
_p_unk="$(bash "$TIER_SH" --base ff/no-such-ref-for-test 2>/dev/null)"
_p_unk_skip="$(printf '%s\n' "$_p_unk" | sed -n 's/^SKIP_REASON=//p')"
_p_unk_reason="$(printf '%s\n' "$_p_unk" | sed -n 's/^REASON=//p')"
if [ -n "$_p_unk_skip" ] && [ -z "$_p_unk_reason" ]; then
  ok "unknown は SKIP_REASON だけを出す（成功時フィールドと混ざらない）"
else
  bad "unknown の出力に成功時フィールドが混ざっています: ${_p_unk:-空}"
fi
# 空行は件数に数えない
_p_blank="$(printf '%s\n' "docs/a.md" "" "  " "docs/b.md" | bash "$TIER_SH" --paths-from - 2>/dev/null | sed -n 's/^CHANGED=//p')"
if [ "$_p_blank" = "2" ]; then
  ok "空行・空白行を CHANGED に数えない"
else
  bad "空行を件数に数えています（CHANGED=${_p_blank:-なし}、期待 2）"
fi

# ---- B. 文書とスクリプトの対応 ------------------------------------------------
echo "== B. tier 表とスクリプトの対応 =="

# 正本節（### 主要ステップ 〜 次の同レベル見出しの手前）だけを切り出す。
# 文書全体を grep すると、**Changelog に残った古い表**や別節の記述で照合が通り、
# 読者が実際に読む節から tier 表が消えても緑になる（節スコープにしない検査の穴）。
section_of() { # $1=文書パス
  awk '/^### 主要ステップ$/ { f = 1; next } f && /^### / { exit } f' "$1"
}

B_START=$((PASS + FAIL))
RULES="$(bash "$TIER_SH" --list-rules 2>/dev/null | sed -n 's/^RULE=//p')"
if [ -z "$RULES" ]; then
  bad "--list-rules が規則を出力しません（以降の照合が空振りするため fail-closed）"
  RULE_IDS=""
else
  RULE_IDS="$(printf '%s\n' "$RULES" | cut -d'|' -f2)"
  ok "--list-rules が規則を出力する（$(printf '%s' "$RULE_IDS" | tr '\n' ' ')）"
fi

# tier の機械値 → 文書表記の対応表。**スクリプトが tier を増やしたらここで赤くなる**
# （対応の無い tier は下のループが「未定義」で弾く）。
label_of() {
  case "$1" in
    full)     echo "**フル**" ;;
    light)    echo "**軽量**" ;;
    standard) echo "**標準**" ;;
    *)        echo "" ;;
  esac
}

SSOT_DOCS="$PLUGIN_ROOT/docs-template/05-operations/DEPLOYMENT.md"
REF_DOCS="$PLUGIN_ROOT/docs-template/MASTER.md
$PLUGIN_ROOT/docs-template/05-operations/deployment/git-workflow.md"
# モード判定は**検査対象ファイルそのものとは別の述語**（docs/ ディレクトリの存在）で行う。
# `docs/MASTER.md` の存在を条件にすると、そのファイルが消えたときに REPO_MODE が 0 へ
# 落ち、検査対象からも件数ガードからも同時に外れて「消せば検査ごと消える」単一障害点に
# なる（他の 6 ファイルはどれが消えても赤くなるのに、そこだけ非対称）。
REPO_MODE=0
if [ -d "$ROOT/docs" ]; then
  REPO_MODE=1
  SSOT_DOCS="$SSOT_DOCS
$ROOT/docs/05-operations/DEPLOYMENT.md"
  REF_DOCS="$REF_DOCS
$ROOT/docs/MASTER.md
$ROOT/docs/07-project-management/TASKS.md"
fi

if [ "$REPO_MODE" -eq 1 ]; then
  for _req in "$ROOT/docs/MASTER.md" "$ROOT/docs/05-operations/DEPLOYMENT.md" "$ROOT/docs/07-project-management/TASKS.md"; do
    if [ -f "$_req" ]; then
      ok "リポジトリ側の検査対象が実在する: ${_req#"$ROOT"/}"
    else
      bad "リポジトリ側の検査対象がありません: ${_req#"$ROOT"/}（docs/ があるのに欠けている = 移動か消失）"
    fi
  done
fi

WT_OLD_IFS="$IFS"
IFS='
'
for doc in $SSOT_DOCS; do
  IFS="$WT_OLD_IFS"
  name="$(basename "$(dirname "$doc")")/$(basename "$doc")"
  if [ ! -f "$doc" ]; then
    bad "正本文書がありません: $doc"
    IFS='
'
    continue
  fi
  sec="$(section_of "$doc")"
  if [ -z "$sec" ]; then
    bad "$name: §主要ステップ 節を切り出せません（見出しが変わったか節が消えています）"
    IFS='
'
    continue
  fi
  # 段の正本宣言。**節の中**にあることを見る（別節や Changelog の記述で通さない）
  if case "$sec" in *"本節がワークフローの段の正本である"*) true ;; *) false ;; esac; then
    ok "$name: §主要ステップ 節が段の正本を宣言している"
  else
    bad "$name: §主要ステップ 節に正本の宣言がありません（参照側が何を指せばよいか決まらない）"
  fi
  # tier 行が規則と同じ順序で並んでいること
  order_ok=1; missing=""
  prev_line=0
  for tier in $RULE_IDS; do
    IFS="$WT_OLD_IFS"
    lbl="$(label_of "$tier")"
    if [ -z "$lbl" ]; then
      bad "$name: tier '$tier' に対応する文書表記が本 suite に未定義（スクリプトが tier を増やしたら表と suite を同時に更新する）"
      order_ok=0
      IFS='
'
      continue
    fi
    # `**フル**` の `*` は BRE の繰り返し演算子として解釈され、行頭 `|` の直後だと
    # 「operand が無い」で grep が落ちる（落ちても空文字が返るだけなので、
    # エスケープを忘れると「表に無い」と誤報したまま緑にならない形で気づく）。
    lbl_esc="$(printf '%s' "$lbl" | sed 's/\*/\\*/g')"
    rows="$(printf '%s\n' "$sec" | grep -n "^| ${lbl_esc} |")"
    ln="$(printf '%s\n' "$rows" | head -1 | cut -d':' -f1)"
    if [ "$(printf '%s\n' "$rows" | grep -c '^[0-9]')" -gt 1 ]; then
      bad "$name: tier 表に ${tier} の行が複数あります（どれが規則か決まらない）"
      order_ok=0
    fi
    if [ -z "$ln" ]; then
      missing="${missing}${tier} "
      order_ok=0
    elif [ "$ln" -le "$prev_line" ]; then
      order_ok=0
      bad "$name: tier 表の並びが規則の評価順と違います（${tier} が前の行より上にある）"
    else
      prev_line="$ln"
    fi
    IFS='
'
  done
  IFS="$WT_OLD_IFS"
  if [ -z "$RULE_IDS" ]; then
    : # 規則を導出できていない（上で bad 済み）。ここで ok を出すと空振りが緑になる
  elif [ -n "$missing" ]; then
    bad "$name: tier 表に無い tier があります: ${missing}"
  elif [ "$order_ok" -eq 1 ]; then
    ok "$name: tier 表が規則と同じ値・同じ評価順で並んでいる"
  fi
  IFS='
'
done
IFS="$WT_OLD_IFS"

IFS='
'
for doc in $REF_DOCS; do
  IFS="$WT_OLD_IFS"
  name="$(basename "$(dirname "$doc")")/$(basename "$doc")"
  if [ ! -f "$doc" ]; then
    bad "参照側の文書がありません: $doc"
    IFS='
'
    continue
  fi
  if grep -q "§主要ステップ" "$doc"; then
    ok "$name: 段の正本（§主要ステップ）を参照している"
  else
    bad "$name: §主要ステップ への参照がありません（段を自前で持つと写しが復活する）"
  fi
  if grep -q "^### 主要ステップ" "$doc"; then
    bad "$name: 参照側が §主要ステップ 見出しを自前で持っています（正本が 2 つになる）"
  else
    ok "$name: §主要ステップ 見出しを自前で持たない"
  fi
  # 見出し名を変えて段を写す形も見る。番号付きリストの項目に**チェーン固有の目印**が
  # 何件並ぶかで判定する（一般の番号付きリストを巻き込まないよう、目印を含む行だけを
  # 数える。実測では現状の参照側 4 文書はいずれも 1 件以下）。
  copied="$(grep -cE "^[0-9]+\. .*(/merge-cleanup|/ace-curate|/close-issue|/retrospective|squash|Draft PR)" "$doc")"
  if [ "$copied" -ge 3 ]; then
    bad "$name: 段のチェーンが番号付きリストで写されています（目印 ${copied} 件。見出し名を変えても正本は 2 つになる）"
  else
    ok "$name: 段のチェーンを番号付きリストで写していない（目印 ${copied} 件）"
  fi
  IFS='
'
done
IFS="$WT_OLD_IFS"

# spec-driven のモード判定が tier へ接続されていること（自己申告の廃止）
SPEC_SKILL="$PLUGIN_ROOT/skills/spec-driven/SKILL.md"
if [ -f "$SPEC_SKILL" ]; then
  if grep -q "workflow-tier.sh" "$SPEC_SKILL"; then
    ok "spec-driven: モード判定が workflow-tier.sh を参照している"
  else
    bad "spec-driven: workflow-tier.sh への参照がありません（モード判定が自己申告へ戻る）"
  fi
  if grep -q "「軽量モード」を宣言する" "$SPEC_SKILL"; then
    bad "spec-driven: 自己申告でモードを宣言する記述が残っています"
  else
    ok "spec-driven: 自己申告でモードを宣言する記述が無い"
  fi
  # tier 値の写像そのものを照合する。文字列プロキシ（「workflow-tier.sh」への言及）だけだと、
  # スクリプトが tier を増減したときに SKILL 側が黙って追従漏れし、**全件が標準モードへ
  # 倒れて AC の効果が消えるのに緑**になる。判定不能（unknown）の扱いも同じ理由で見る。
  _spec_missing=""
  WT_SPEC_IFS="$IFS"
  IFS='
'
  for tier in $RULE_IDS unknown; do
    IFS="$WT_SPEC_IFS"
    grep -q -- "$tier" "$SPEC_SKILL" || _spec_missing="${_spec_missing}${tier} "
    IFS='
'
  done
  IFS="$WT_SPEC_IFS"
  if [ -z "$RULE_IDS" ]; then
    : # 規則を導出できていない（上で bad 済み）
  elif [ -z "$_spec_missing" ]; then
    ok "spec-driven: 全 tier 値と unknown の扱いが書かれている"
  else
    bad "spec-driven: 扱いが書かれていない tier があります: ${_spec_missing}（追従漏れは全件標準モードへ倒れる）"
  fi
else
  bad "spec-driven の SKILL.md がありません: $SPEC_SKILL"
fi

# B が実際に何件の検査を回したかを、モード変数から導出した期待値で固定する。
# 下限（PASS>0）だけだとループ本体の検査が消えても緑のままになる（#540 で
# 「検査総数アサートが侵食対策の要」と結論済みのパターン）。
B_SSOT=1; B_REF=2
if [ "$REPO_MODE" -eq 1 ]; then B_SSOT=2; B_REF=4; fi
B_EXPECT=$((1 + REPO_MODE * 3 + B_SSOT * 2 + B_REF * 3 + 3))
B_ACTUAL=$(( (PASS + FAIL) - B_START ))
if [ "$B_ACTUAL" -eq "$B_EXPECT" ]; then
  ok "B の検査件数が期待どおり（${B_ACTUAL} 件。検査そのものの削除を検出する）"
else
  bad "B の検査件数が ${B_ACTUAL} 件です（期待 ${B_EXPECT}）。検査が削られたか、追加時に期待値を更新していません"
fi

# ---- C. 手書きの段数・件数・割合が無いこと ------------------------------------
echo "== C. 段数・tier 件数・分布の手書きが無いこと =="

# 数値の装飾（`**10**` / `` `10` ``）を許して拾う。全角空白・`_` は入れない
# （LC_ALL=C 下でのブラケット式の多バイト分解と、別概念の巻き込みを避けるため）。
# 全角数字・漢数字は**選択（`|`）で並べる**。ブラケット式へ多バイト文字を書くと
# LC_ALL=C 下でバイト単位に分解される（run-all case 11 の MBCS ガードが見ている壊れ方で、
# docs-fact-drift のヘッダも同じ理由で全角空白を排している）。
ZEN='(０|１|２|３|４|５|６|７|８|９)'
KAN='(一|二|三|四|五|六|七|八|九|十)'
NUM="([*\`]*([0-9]+|${ZEN}+|${KAN}+)[*\`]*)"
# 禁止する形。「ステップ7」のような**段の ID** は許し、「10 ステップ」のような
# **段数の主張**だけを弾く（ID は 100 箇所以上から参照されており、正本の一元化とは別物）。
#
# 単位語に `段` を含めるのが要点。本 PR の文書は段の単位語として `段` を一貫して使うので
# （「段の正本」「段の一覧」）、最も自然な書き方「全 10 段」が対象外だと実害が大きい。
# 数値後置（「ステップ数は 10」）と助詞入り（「tier は 3 つ」「3 種類の tier」）も、
# 前置形だけを弾くと素通りする。割合は `%` に加えて「N 割」も見る。
FORBIDDEN_ERE="${NUM} ?(ステップ|段階|段)"
FORBIDDEN_ERE="${FORBIDDEN_ERE}|(ステップ|段階|段)数は ?${NUM}"
FORBIDDEN_ERE="${FORBIDDEN_ERE}|${NUM} ?(つの |種類の )?tier|tier ?(は )?${NUM} ?(つ|個|種類)"
FORBIDDEN_ERE="${FORBIDDEN_ERE}|${NUM} ?割[^合]"

# 走査対象。ワークフローの段を書く文書に限る（カバレッジ目標などの % を巻き込まない）。
scan_targets() { # $1=プラグインルート $2=リポジトリルート
  local pr="$1" rr="$2"
  echo "$pr/docs-template/05-operations/DEPLOYMENT.md"
  echo "$pr/docs-template/MASTER.md"
  echo "$pr/docs-template/05-operations/deployment/git-workflow.md"
  # workflow-principles.md は §主要ステップ を参照しないが、TodoWrite テンプレートとして
  # チェーンを列挙するため段数の手書きが最も入りやすい。参照契約（B）の対象外・
  # 段数走査（C）の対象、という非対称は意図的。
  echo "$pr/docs-template/05-operations/deployment/workflow-principles.md"
  echo "$pr/skills/spec-driven/SKILL.md"
  # リポジトリ側の docs/ はモノレポにしか無い（公開リポジトリは配らない）
  if [ -f "$rr/docs/MASTER.md" ]; then
    echo "$rr/docs/05-operations/DEPLOYMENT.md"
    echo "$rr/docs/MASTER.md"
    echo "$rr/docs/07-project-management/TASKS.md"
  fi
}

# 走査本体。違反行と、末尾に走査ファイル数（__SCANNED__=N）を stdout へ出す。
scan_forbidden() { # $1=プラグインルート $2=リポジトリルート
  local f n=0
  local old_ifs="$IFS"
  IFS='
'
  for f in $(scan_targets "$1" "$2"); do
    IFS="$old_ifs"
    [ -f "$f" ] || continue
    n=$((n + 1))
    # 行番号は本文（Changelog を落とした後）基準になるため出さない。報告は一致行そのもの
    # ＋ファイル名で足りる（docs-fact-drift も同じ扱い）。
    ff_docs_claim_body "$f" | grep -E "$FORBIDDEN_ERE" | sed "s|^|${f}: |"
    # 分布の割合は **tier 表の行**と `tier` の語を含む行だけを見る。`標準` `軽量` のような
    # 一般語で絞ると「標準モードのテストカバレッジ目標は 80% 以上」まで拾って誤検知になる
    # （実測で確認した。逆変異でこの緩さ側も固定する）。
    ff_docs_claim_body "$f" | grep -E "^\| \*\*(フル|軽量|標準)\*\*|tier" | grep -E "${NUM} ?%" | sed "s|^|${f}: (割合) |"
    IFS='
'
  done
  IFS="$old_ifs"
  echo "__SCANNED__=$n"
}

REAL_OUT="$(scan_forbidden "$PLUGIN_ROOT" "$ROOT")"
REAL_SCANNED="$(printf '%s\n' "$REAL_OUT" | sed -n 's/^__SCANNED__=//p')"
# `|| true` で grep の rc を潰すと、grep が壊れた回も「違反 0 件」として緑になる。
# rc=1（一致なし）だけを許し、rc>=2 は検査不能として赤にする。
REAL_HITS="$(printf '%s\n' "$REAL_OUT" | grep -v '^__SCANNED__=' | grep -v '^$')"
REAL_HITS_RC=$?
if [ "$REAL_HITS_RC" -gt 1 ]; then
  bad "走査結果の整形に失敗しました（grep rc=${REAL_HITS_RC}）。違反 0 件と区別が付きません"
fi

EXPECT_SCANNED=5
[ "$REPO_MODE" -eq 1 ] && EXPECT_SCANNED=8
if [ "${REAL_SCANNED:-0}" -eq "$EXPECT_SCANNED" ]; then
  ok "走査対象が ${EXPECT_SCANNED} ファイル（対象の取り違え・消失で空振りしていない）"
else
  bad "走査対象が ${REAL_SCANNED:-0} ファイルです（期待 ${EXPECT_SCANNED}。対象の場所が変わったか消えています）"
fi

# 違反があれば、検出力の実測を待たずにここで赤にする（見つかった以上、走査は効いている）。
if [ -n "$REAL_HITS" ]; then
  bad "段数・tier 件数・分布の手書きが残っています:"
  printf '%s\n' "$REAL_HITS" | sed 's/^/      /' >&2
fi
# 「0 件」の側は**検出力を測れた回だけ** pass にする。変異注入を飛ばした回の 0 件は
# 「検出力の無い 0 件」であり、ヘッダの宣言どおり緑にしてはいけない。判定は下の
# 変異ブロックの後で行う（C_MEASURED を見る）。
C_MEASURED=0

# 検出力の実測: 一時コピーへ違反を注入し、同じ走査が赤くなることを確かめる。
# ここが緑にならない回は、上の「0 件」に意味が無い。
MUT_ROOT="$(make_tmpdir wt-mut)"
if [ -z "$MUT_ROOT" ]; then
  tmp_unavailable "C の変異注入" "実 tree の 0 件は検出力未実測"
else
  # 偽のプラグインルート。repo 側の docs/ は置かないので、走査対象は配布物 + スキルの
  # 4 件になる（実 tree の 7 件とは別勘定で構わない — ここで測るのは走査の検出力）。
  MUT_PLUGIN="$MUT_ROOT/plugins/ff-dev-toolkit"
  MUT_DOC="$MUT_PLUGIN/docs-template/05-operations/DEPLOYMENT.md"
  mkdir -p "$MUT_PLUGIN/docs-template/05-operations/deployment" \
           "$MUT_PLUGIN/skills/spec-driven"
  cp "$PLUGIN_ROOT/docs-template/05-operations/DEPLOYMENT.md" "$MUT_DOC"
  cp "$PLUGIN_ROOT/docs-template/MASTER.md" "$MUT_PLUGIN/docs-template/MASTER.md"
  cp "$PLUGIN_ROOT/docs-template/05-operations/deployment/git-workflow.md" \
     "$MUT_PLUGIN/docs-template/05-operations/deployment/git-workflow.md"
  cp "$PLUGIN_ROOT/docs-template/05-operations/deployment/workflow-principles.md" \
     "$MUT_PLUGIN/docs-template/05-operations/deployment/workflow-principles.md"
  cp "$PLUGIN_ROOT/skills/spec-driven/SKILL.md" "$MUT_PLUGIN/skills/spec-driven/SKILL.md"

  _mut_scanned="$(scan_forbidden "$MUT_PLUGIN" "$MUT_ROOT" | sed -n 's/^__SCANNED__=//p')"
  if [ "${_mut_scanned:-0}" -eq 5 ]; then
    ok "変異 fixture の走査対象が 5 ファイル（cp の失敗で検出力の実測が縮んでいない）"
  else
    bad "変異 fixture の走査対象が ${_mut_scanned:-0} ファイルです（期待 5。cp が失敗しています）"
  fi

  # 注入は `## Changelog` の**手前**へ入れる。末尾追記だと走査本文（claim_body）の外に
  # 落ちて、検出できないのが正しい挙動になってしまい、検出力を測れない。
  inject_before_changelog() { # $1=注入する行
    awk -v line="$1" '
      !done && /^## Changelog$/ { print line; print ""; done = 1 }
      { print }
    ' "$PLUGIN_ROOT/docs-template/05-operations/DEPLOYMENT.md" > "$MUT_DOC"
  }

  mutate_and_expect_red() { # $1=注入する行 $2=説明
    inject_before_changelog "$1"
    local hits
    hits="$(scan_forbidden "$MUT_PLUGIN" "$MUT_ROOT" | grep -v '^__SCANNED__=' | grep -v '^$' || true)"
    if [ -n "$hits" ]; then
      ok "変異を検出: $2"
    else
      bad "変異を検出できません: $2（走査が空振りしているため、実 tree の 0 件も無意味）"
    fi
  }

  mutate_and_expect_red '### 主要ステップ（10 ステップ）' '段数の手書き（10 ステップ）'
  mutate_and_expect_red '主要ステップ（**11**ステップ）' '装飾された段数（**11**ステップ）'
  mutate_and_expect_red '変更規模で 3 tier に分ける。' 'tier 件数の手書き（3 tier）'
  mutate_and_expect_red 'レビュー深度は 3 段階で判定する。' '段階数の手書き（3 段階）'
  mutate_and_expect_red '| **フル** | 実測分布 36% |' 'tier 分布の割合（36%）'
  mutate_and_expect_red '全 10 段を通す。' '段を単位語にした段数（10 段）'
  mutate_and_expect_red 'ステップ数は 10 である。' '数値後置の段数（ステップ数は 10）'
  mutate_and_expect_red 'ワークフローは１０ステップである。' '全角数字の段数（１０ステップ）'
  mutate_and_expect_red '三段階のレビュー深度。' '漢数字の段階数（三段階）'
  mutate_and_expect_red 'tier は 3 つある。' '助詞を挟んだ tier 件数（tier は 3 つ）'
  mutate_and_expect_red 'フル tier の実測分布は約 4 割である。' '％以外の割合表現（4 割）'

  # 逆変異: 段の **ID**（ステップ7 / ステップ 10）は許すこと。ここが赤くなる規則は
  # 100 箇所以上の正当な参照を巻き込むので、緩さの側も固定する。
  # 逆変異: 許すべき形。段の **ID**（100 箇所超から参照される）と、tier と無関係な
  # 割合（カバレッジ目標）を巻き込まないことを固定する。ここが赤くなる規則は、
  # 正当な記述を潰して運用を止める。
  inject_before_changelog 'ステップ7 と ステップ 10 は段の ID である。標準モードのテストカバレッジ目標は 80% 以上とする。軽量な運用でも達成率 100% を目指す。'
  _id_hits="$(scan_forbidden "$MUT_PLUGIN" "$MUT_ROOT" | grep -v '^__SCANNED__=' | grep -v '^$' || true)"
  if [ -z "$_id_hits" ]; then
    ok "段の ID と tier 無関係の割合（カバレッジ目標）は違反にしない"
  else
    bad "許すべき記述を違反として拾っています（正当な参照・別概念の割合を巻き込む）:"
    printf '%s\n' "$_id_hits" | sed 's/^/      /' >&2
  fi

  C_MEASURED=1
  rm -rf "$MUT_ROOT"
fi

if [ -n "$REAL_HITS" ]; then
  : # 上で報告済み
elif [ "$C_MEASURED" -eq 1 ]; then
  ok "段数・tier 件数・分布の手書きが無い（同じ走査が変異を検出することを実測済み）"
else
  bad "段数・tier 件数・分布の手書きは 0 件ですが、走査の検出力を実測できていません（変異注入を実行できなかった回の 0 件は根拠になりません）"
fi

# ---- D. 確定判定（実 git 差分）------------------------------------------------
# A は path 一覧を渡す暫定判定の入口しか通らない。**拘束力を持つのは引数なしの確定判定**
# なので、実際の git リポジトリを組んで `git diff --no-renames --name-only <base>...HEAD`
# の経路を通す。`--no-renames` の有無は文字列検査では守れない（コメントを残したまま
# 実コマンドから消せる）ので、フラグを外した複製を同じ入力で走らせて**分類が変わること**
# を測る。変わらなければ、そのフラグは何も守っていない。
echo "== D. 確定判定（実 git 差分）=="

if ! command -v git >/dev/null 2>&1; then
  echo "  ○ skip: git が無いため確定判定の経路を実行していません"
else
  GIT_ROOT="$(make_tmpdir wt-git)"
  if [ -z "$GIT_ROOT" ]; then
    tmp_unavailable "D の実 git 差分検査" "確定判定の経路は未実測"
  else
    # 変数へ畳んで展開すると TMPDIR に空白があるだけで D 節が不可解に赤くなる。関数で受ける。
    GITC() { git -C "$GIT_ROOT" -c user.name=wt -c user.email=wt@example.invalid -c commit.gpgsign=false "$@"; }
    _git_ready=1
    GITC init -q >/dev/null 2>&1 || _git_ready=0
    if [ "$_git_ready" -eq 1 ]; then
      mkdir -p "$GIT_ROOT/docs-template/x" "$GIT_ROOT/src"
      printf 'hello\n' > "$GIT_ROOT/docs-template/x/a.md"
      printf 'readme\n' > "$GIT_ROOT/README.md"
      printf 'export const a = 1;\n' > "$GIT_ROOT/src/app.ts"
      GITC add -A >/dev/null 2>&1
      GITC commit -qm init >/dev/null 2>&1 || _git_ready=0
    fi
    BASE_SHA=""
    [ "$_git_ready" -eq 1 ] && BASE_SHA="$(GITC rev-parse HEAD 2>/dev/null)"
    if [ -z "$BASE_SHA" ]; then
      bad "検査用の git リポジトリを用意できませんでした（確定判定の経路が未実測になります）"
    else
      confirmed_tier() { # $1=スクリプト（本体 or 変異体）
        ( cd "$GIT_ROOT" && bash "$1" --base "$BASE_SHA" 2>/dev/null ) | sed -n 's/^WORKFLOW_TIER=//p'
      }
      reset_case() {
        GITC checkout -q -B probe "$BASE_SHA" >/dev/null 2>&1
      }

      # 1) 配布物からの移動（rename）。移動後の path だけを見ると .md のみ = light に化ける
      reset_case
      GITC mv docs-template/x/a.md moved.md >/dev/null 2>&1
      GITC commit -qm "move out of docs-template" >/dev/null 2>&1
      _t="$(confirmed_tier "$TIER_SH")"
      if [ "$_t" = "full" ]; then
        ok "確定判定: 配布物からの移動は full"
      else
        bad "確定判定: 配布物からの移動が full になりません（実際: ${_t:-なし}）"
      fi

      # 1b) 同じ入力に対し、--no-renames を外した複製は light へ落ちること（= フラグの効力）
      MUTANT="$GIT_ROOT/mutant-workflow-tier.sh"
      sed 's/--no-renames //g' "$TIER_SH" > "$MUTANT"
      _tm="$(confirmed_tier "$MUTANT")"
      if [ "$_tm" = "light" ]; then
        ok "--no-renames を外すと同じ移動が light へ落ちる（フラグが実際に守っている）"
      else
        bad "--no-renames を外しても分類が変わりません（実際: ${_tm:-なし}）。フラグの検査が無意味になっています"
      fi

      # 2) 配布物の削除
      reset_case
      GITC rm -q docs-template/x/a.md >/dev/null 2>&1
      GITC commit -qm "delete distributed file" >/dev/null 2>&1
      _t="$(confirmed_tier "$TIER_SH")"
      if [ "$_t" = "full" ]; then
        ok "確定判定: 配布物の削除は full"
      else
        bad "確定判定: 配布物の削除が full になりません（実際: ${_t:-なし}）"
      fi

      # 3) .md のみの変更
      reset_case
      printf 'readme updated\n' > "$GIT_ROOT/README.md"
      GITC commit -qam "docs only" >/dev/null 2>&1
      _t="$(confirmed_tier "$TIER_SH")"
      if [ "$_t" = "light" ]; then
        ok "確定判定: .md のみの変更は light"
      else
        bad "確定判定: .md のみの変更が light になりません（実際: ${_t:-なし}）"
      fi

      # 4) 実装変更
      reset_case
      printf 'export const a = 2;\n' > "$GIT_ROOT/src/app.ts"
      GITC commit -qam "impl only" >/dev/null 2>&1
      _t="$(confirmed_tier "$TIER_SH")"
      if [ "$_t" = "standard" ]; then
        ok "確定判定: 実装変更は standard"
      else
        bad "確定判定: 実装変更が standard になりません（実際: ${_t:-なし}）"
      fi

      # 4b) 非 ASCII を含む配布物 path。既定の core.quotepath=true では
      #     `"docs-template/\346\227\245.md"` の形で C クォートされ、前後の `"` で
      #     規則 1 にも規則 2 にも当たらなくなる（= full が standard へ落ちる）。
      reset_case
      mkdir -p "$GIT_ROOT/docs-template/x"
      printf 'hi\n' > "$GIT_ROOT/docs-template/x/日本語.md"
      GITC add -A >/dev/null 2>&1
      GITC commit -qm "non-ascii distributed file" >/dev/null 2>&1
      _t="$(confirmed_tier "$TIER_SH")"
      if [ "$_t" = "full" ]; then
        ok "確定判定: 非 ASCII 名の配布物も full（core.quotepath=false が効いている）"
      else
        bad "確定判定: 非 ASCII 名の配布物が full になりません（実際: ${_t:-なし}）。core.quotepath を確認してください"
      fi

      # 4c) base は env（WORKFLOW_TIER_BASE）でも与えられる
      _t="$( ( cd "$GIT_ROOT" && WORKFLOW_TIER_BASE="$BASE_SHA" bash "$TIER_SH" 2>/dev/null ) | sed -n 's/^WORKFLOW_TIER=//p' )"
      if [ "$_t" = "full" ]; then
        ok "確定判定: WORKFLOW_TIER_BASE でも base を与えられる"
      else
        bad "確定判定: WORKFLOW_TIER_BASE が効いていません（実際: ${_t:-なし}）"
      fi

      # 5) 差分が空（base == HEAD）でも軽い側へ倒さない
      reset_case
      _t="$(confirmed_tier "$TIER_SH")"
      if [ "$_t" = "standard" ]; then
        ok "確定判定: 差分が空でも standard（fail-closed）"
      else
        bad "確定判定: 差分が空のとき standard になりません（実際: ${_t:-なし}）"
      fi
    fi
    rm -rf "$GIT_ROOT"
  fi
fi

echo ""
echo "結果: pass=${PASS} fail=${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
if [ "$PASS" -eq 0 ]; then
  echo "✗ 検査が 1 件も成立していません" >&2
  exit 1
fi
echo "✅ workflow-tier: all checks passed"
