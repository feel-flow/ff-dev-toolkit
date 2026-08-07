#!/usr/bin/env bash
#
# 起票スキル 2 本のラベル付与契約（verify-then-skip）の同期検査（Issue #292）。
#
# `create-issue`（着手前の起票ゲート）と `out-of-scope-issue`（スコープ外発見の
# follow-up 起票）は、どちらも「実在するラベルだけを付ける」同じ手順を持つ。
# 存在しないラベル名を渡すと `gh issue create` 自体が失敗するため、ラベル名を
# 直書きで固定できず、`gh label list` での実在確認 → 存在するものだけ付与 →
# 省略分は理由付きで報告、という手順が両者に要る。
#
# なぜ共有ファイルに切り出さず複製するのか: 手順の途中で組み立てた `label_args` を
# `gh issue create` がそのまま消費する。参照ファイルへ分断すると、エージェントが
# 参照先を読まずにラベル手順ごと飛ばす経路ができる（progressive disclosure は
# 「読まれないことがある」を前提にした仕組みで、必須手順の置き場所ではない）。
# そこでドリフト対策は「共有」ではなく「照合」で行う。
#
# 検査は 2 層:
#   1. fixtures/label-block.txt … bash の実行部分を**連続した行列**として固定する。
#      行の存在だけを見る方式では then/else の入れ替え（実在するラベルを skip し、
#      存在しないラベルを gh へ渡す = 契約の意味的反転）が素通りするため、順序と
#      隣接まで比較する。両スキルで意図的に異なる 2 行（候補の系統）はプレース
#      ホルダへ正規化し、その違い自体は下の個別検査で固定する。
#   2. fixtures/shared-fragments.txt … 順序を固定する意味がない散文・表を行単位で
#      照合する。既定は**行全体の完全一致**（部分一致だと片側の行末に文を継ぎ足す
#      ドリフトが素通りする）。文の長さが意図的に違う箇所だけ `~ ` で部分一致にする。
#
# 検出範囲の限界（過大に主張しない）: 本 suite が赤くするのは fixtures に載せた
# 契約テキストを片方だけ書き換えた／削除した場合である。fixtures に載っていない
# 複製文が片方だけ変わっても検出しない。SKILL.md 側の「片方だけ直すと red になる」
# という注記も、この範囲に限定して書くこと。
#
# 一時ディレクトリも jq / gh / yq も要らない純粋なファイル検査なので、書き込み不可の
# 環境でも完走する。契約を意図的に変えるときは fixtures/regenerate.sh を使う。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/issue-label-contract/verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
FRAGMENTS="$FIXTURES_DIR/shared-fragments.txt"
LABEL_BLOCK="$FIXTURES_DIR/label-block.txt"

CREATE_ISSUE="$PLUGIN_ROOT/skills/create-issue/SKILL.md"
OUT_OF_SCOPE="$PLUGIN_ROOT/skills/out-of-scope-issue/SKILL.md"
# `gh label create` 検出器の生きた対照。refine-issue は needs-spec を実際に作る。
REFINE_ISSUE="$PLUGIN_ROOT/skills/refine-issue/SKILL.md"

# fixtures の実行対象行数。契約を増減したときは必ずここも直す。固定しないと、
# 抽出が壊れて 0 行になっても「全 fragment 一致」で緑になる。
EXPECTED_SHARED_FRAGMENTS=23
EXPECTED_BLOCK_LINES=32

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

rel() { printf '%s' "${1#"$REPO_ROOT"/}"; }

echo "== 起票スキルのラベル契約（verify-then-skip）同期検査 =="

for file in "$CREATE_ISSUE" "$OUT_OF_SCOPE" "$REFINE_ISSUE" "$FRAGMENTS" "$LABEL_BLOCK" "$FIXTURES_DIR/extract.sh"; do
  [ -s "$file" ] || { echo "✗ 必須ファイルが無いか空です: $file" >&2; exit 1; }
done

# 抽出は検査側と生成側で 1 実装を共有する（別実装だと両方が同じようにずれても気づけない）。
# shellcheck source=./fixtures/extract.sh
. "$FIXTURES_DIR/extract.sh"

# ---- 照合プリミティブ ---------------------------------------------------------
# ファイルを直接読む固定文字列検索。パイプ入力ではないので `grep -q` を使ってよい
# （上流 producer が居らず SIGPIPE で反転しない）。
has_line()      { grep -qxF -- "$2" "$1"; }  # 行全体の完全一致
has_substring() { grep -qF  -- "$2" "$1"; }  # 部分一致（`~ ` 指定の fragment 専用）

contains() {
  local file="$1" needle="$2" label="$3"
  if has_substring "$file" "$needle"; then ok "$label"; else bad "${label}（不足: ${needle}）"; fi
}

# 行頭（インデント可）から始まる引数行・コマンド行だけを見る検査群。
# 素の部分文字列検索では散文中の言及（「`--assignee @me` へ戻さないこと」等）まで
# 拾ってしまい、**ルールを書き残すほどテストが赤くなる**。逆に「在ること」を主張する
# 側も、散文の引用で充足してしまうと何も見ていないのと同じになる。両方向とも行に
# 束縛する（out-of-scope-routing の no_assignee_argument と同じ理由）。
argument_lines() { awk -v pat="$2" '$0 ~ pat { print NR }' "$1"; }

ASSIGNEE_PATTERN='^[[:space:]]*--assignee([[:space:]]|=)|[[:space:]]--assignee([[:space:]]|=)|[[:space:]]-a[[:space:]]'
LABEL_CREATE_PATTERN='^[[:space:]]*gh label create([[:space:]]|$)'

has_argument_line() {
  local file="$1" pat="$2" label="$3"
  if [ -n "$(argument_lines "$file" "$pat")" ]; then ok "$label"
  else bad "${label}（該当する引数行・コマンド行が無い）"; fi
}
lacks_argument_line() {
  local file="$1" pat="$2" label="$3" violations
  violations="$(argument_lines "$file" "$pat")"
  if [ -n "$violations" ]; then bad "${label}（該当行: ${violations//$'\n'/, }）"; else ok "$label"; fi
}

# ```bash フェンス内の `gh issue <verb>` を 1 論理コマンドへ畳み、そのコマンド自身が
# 必要な引数を持つかを見る。ファイル全体を部分文字列で探す方式では、`gh label list`
# 側の `--repo` や、方針を説明する散文の引用で充足してしまう。
#
# 行継続（末尾 `\`）の有無に関わらず拾う。継続行がある形だけを対象にすると、
# `\` を外して 1 行に畳むだけで**検査対象が 0 件**になり、違反ゼロとして緑になる。
# そのため期待件数も渡して固定する（0 件になったら赤）。
#
# assignee_mode: yes = そのコマンドが --assignee を持つこと / no = 持たないこと
gh_issue_commands_bound() {
  local file="$1" verb="$2" expected="$3" assignee_mode="$4" label="$5" out
  out="$(awk -v verb="$verb" -v expected="$expected" -v mode="$assignee_mode" '
    function check(c, ln) {
      n++
      if (index(c, "--repo \"$expected_repo\"") == 0) print "  " ln " 行目: --repo \"$expected_repo\" が無い"
      has_a = (index(c, "--assignee") > 0 || match(c, /(^|[[:space:]])-a([[:space:]]|$)/) > 0)
      if (mode == "yes" && !has_a) print "  " ln " 行目: --assignee が無い"
      if (mode == "no"  &&  has_a) print "  " ln " 行目: --assignee があってはならない"
    }
    { sub(/\r$/, "") }
    in_fence == 0 { if ($0 ~ /^[[:space:]]*```[[:space:]]*(bash|sh|shell|zsh)[[:space:]]*$/) in_fence = 1; next }
    $0 ~ /^[[:space:]]*```[[:space:]]*$/ {
      if (collecting) { check(cmd, start); collecting = 0 }
      in_fence = 0; next
    }
    collecting == 1 {
      cmd = cmd " " $0
      if ($0 !~ /\\[[:space:]]*$/) { check(cmd, start); collecting = 0 }
      next
    }
    # コマンド位置のものだけを拾う。行頭（インデント可）か `$(` の直後に限る。
    # 単なる部分文字列で拾うと、`echo "gh issue create が …"` のような**エラー
    # メッセージ内の言及**まで 1 件として数え、件数固定が誤って赤くなる
    # （負の主張と同じで、コマンドを話題にするほど検査が壊れる形）。
    $0 ~ ("^[[:space:]]*gh issue " verb "([[:space:]]|$)") ||
    $0 ~ ("[$][(][[:space:]]*gh issue " verb "([[:space:]]|$)") {
      cmd = $0; start = FNR
      if ($0 ~ /\\[[:space:]]*$/) collecting = 1; else check(cmd, start)
    }
    END {
      if (collecting) check(cmd, start)
      if (n != expected + 0) print "  実行される gh issue " verb " が " n " 件（期待 " expected " 件）— 検査対象が黙って増減している"
    }
  ' "$file")"
  if [ -z "$out" ]; then ok "$label"; else bad "$label"; printf '%s\n' "$out" >&2; fi
}

# ラベル決定（for ループ）と `gh issue create` が**同じ** ```bash フェンスに居ること。
# 散文で「1 つのブロックで」と書いてあっても、実際に分割されていれば意味がない。
# 分割すると label_args が次のシェルへ渡らず、`${label_args[@]+...}` が空へ展開して
# 「ラベル 0 個で起票成功」が無言で起きる。
label_loop_and_create_same_fence() {
  local file="$1" label="$2"
  if awk '
    { sub(/\r$/, "") }
    /^[[:space:]]*```[[:space:]]*(bash|sh|shell|zsh)[[:space:]]*$/ { in_f = 1; loop = 0; create = 0; next }
    in_f && /^[[:space:]]*```[[:space:]]*$/ { if (loop && create) found = 1; in_f = 0; next }
    in_f {
      if (index($0, "for candidate in ")) loop = 1
      if (index($0, "gh issue create")) create = 1
    }
    END { exit !found }
  ' "$file"; then
    ok "$label"
  else
    bad "${label}（ラベル決定ループと gh issue create が別フェンスに分かれている）"
  fi
}

# frontmatter の description 行だけを取り出す（本文中の同名語で充足させない）。
description_line() {
  awk '{ sub(/\r$/, "") } /^---$/ { n++; next } n == 1 && /^description:/ { print; exit } n == 2 { exit }' "$1"
}

# ---- 自己検証（検出器が本当に見ているかを先に確かめる） -------------------------
# 正の主張の検査は、検出器が常に真を返していても緑になる。正・負・変異の 3 方向で縛る。
# 正の対照は**契約テキストの外**から採る。契約行を対照に使うと、本物のドリフトが
# 自己検証を先に赤くして「検出器が壊れた」と誤報告し、本検査の結果が消える。
SELF_POSITIVE='name: create-issue'
SELF_NEGATIVE='__FRAGMENT_THAT_MUST_NOT_EXIST_9f3a__'

if has_line "$CREATE_ISSUE" "$SELF_POSITIVE"; then
  ok "自己検証: 実在する行を検出できる（正の対照・契約外の frontmatter）"
else
  bad "自己検証: 実在する行を検出できない — 検出器が壊れている"
fi
if has_line "$CREATE_ISSUE" "$SELF_NEGATIVE"; then
  bad "自己検証: 実在しない行を検出した — 検出器が常に真を返している"
else
  ok "自己検証: 実在しない行を検出しない（負の対照）"
fi

# 変異対照は「実際に起こりうる劣化」を突く。空白差を吸収する実装（trim してから
# 比較する等）へ静かに退化したときに赤くなるよう、インデントを剥いだ契約行が
# **行全体一致では見つからない**ことを確かめる。fixture から機械的に導出するので、
# 変数名を一括改名しても対照が空振りしない。
SELF_INDENTED="$(awk '/^[[:space:]]+[[]/ { print; exit }' "$LABEL_BLOCK")"
if [ -z "$SELF_INDENTED" ]; then
  bad "自己検証: 変異対照の素材（インデント付き契約行）を fixture から採れない"
else
  SELF_DEDENTED="${SELF_INDENTED#"${SELF_INDENTED%%[![:space:]]*}"}"
  if has_line "$CREATE_ISSUE" "$SELF_DEDENTED"; then
    bad "自己検証: インデントを剥いだ契約行が一致した — 行全体一致で見ていない"
  else
    ok "自己検証: インデントを剥いだ契約行は一致しない（空白差を吸収していない）"
  fi
fi

# 抽出器の対照。アンカーを持たないファイルからは 1 行も採れないこと。
if extract_label_block "$REFINE_ISSUE" >/dev/null 2>&1; then
  bad "自己検証: アンカーの無いファイルから契約ブロックを抽出できてしまった"
else
  ok "自己検証: アンカーの無いファイルからは契約ブロックを抽出しない"
fi

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "✗ issue-label-contract verify: 検出器の自己検証に失敗（本検査は実行しない）" >&2
  exit 1
fi

# ---- 1. 契約ブロックの連続比較（順序・隣接まで） --------------------------------
block_lines="$(awk 'END { print NR }' "$LABEL_BLOCK")"
if [ "$block_lines" -eq "$EXPECTED_BLOCK_LINES" ]; then
  ok "契約ブロックが ${EXPECTED_BLOCK_LINES} 行（増減時は EXPECTED_BLOCK_LINES も更新すること）"
else
  bad "契約ブロックが ${block_lines} 行（期待 ${EXPECTED_BLOCK_LINES} 行）— fixture が黙って縮んでいる"
fi

# 比較に `diff` は使わない。BSD diff は標準入力側を一時ファイルへ写すため、
# 書き込み不可の環境では `Operation not permitted` で落ちる（「read-only でも完走」
# という本 suite の前提と食い違う）。awk で行番号付きの突き合わせを自前で行う。
compare_block() {
  local file="$1" name="$2" actual mismatch
  if ! actual="$(extract_label_block "$file")"; then
    bad "${name}: 契約ブロックを抽出できない（アンカー行または閉じの done が無い）"
    return
  fi
  mismatch="$(printf '%s\n' "$actual" | awk '
    NR == FNR { want[FNR] = $0; want_n = FNR; next }
    { got[FNR] = $0; got_n = FNR }
    END {
      n = (want_n > got_n) ? want_n : got_n
      for (i = 1; i <= n; i++) {
        if (i > want_n)      { print i ": 正本に無い行 → " got[i]; continue }
        if (i > got_n)       { print i ": 行が欠落 ← " want[i]; continue }
        if (want[i] != got[i]) {
          print i ": 不一致"
          print "      正本: " want[i]
          print "      実際: " got[i]
        }
      }
    }
  ' "$LABEL_BLOCK" -)"
  if [ -z "$mismatch" ]; then
    ok "${name}: 契約ブロックが正本と完全一致（順序・隣接・インデント込み）"
  else
    bad "${name}: 契約ブロックが正本と不一致"
    printf '%s\n' "$mismatch" | sed 's/^/    | /' >&2
  fi
}
compare_block "$CREATE_ISSUE" "create-issue"
compare_block "$OUT_OF_SCOPE" "out-of-scope-issue"

# ---- 2. 契約ブロックが bash として構文的に妥当か --------------------------------
# 行を比較しても、フェンス内の `done` が消えるような構文破壊は検出できない。
# 抽出したブロックはプレースホルダを含むので、正規化前の実体を各ファイルから読む。
syntax_check_block() {
  local file="$1" name="$2" body
  body="$(awk '
    { sub(/\r$/, "") }
    in_fence == 0 { if ($0 ~ /^[[:space:]]*```[[:space:]]*(bash|sh|shell|zsh)[[:space:]]*$/) in_fence = 1; next }
    $0 ~ /^[[:space:]]*```[[:space:]]*$/ { in_fence = 0; capturing = 0; next }
    capturing == 0 { if (index($0, "label_lookup_failed=0")) capturing = 1; else next }
    { print; if ($0 == "done") exit }
  ' "$file")"
  if [ -z "$body" ]; then
    bad "${name}: 構文検査用のブロックを取り出せない"
    return
  fi
  # `available_labels` は if 内で代入されるので、-n（構文のみ）では実行しない。
  if printf '%s\n' "$body" | bash -n 2>/dev/null; then
    ok "${name}: 契約ブロックが bash として構文的に妥当（bash -n）"
  else
    bad "${name}: 契約ブロックが bash -n を通らない（done の欠落など構文破壊）"
  fi
}
syntax_check_block "$CREATE_ISSUE" "create-issue"
syntax_check_block "$OUT_OF_SCOPE" "out-of-scope-issue"

# ---- 3. 散文契約の照合（既定は行全体一致、`~ ` は部分一致） ----------------------
fragment_count=0
missing_create=0
missing_scope=0
while IFS= read -r fragment || [ -n "$fragment" ]; do
  case "$fragment" in
    ';;'*|'') continue ;;
  esac
  mode=line
  case "$fragment" in
    '~ '*) mode=substring; fragment="${fragment#~ }" ;;
  esac
  fragment_count=$((fragment_count + 1))
  for target in "$CREATE_ISSUE" "$OUT_OF_SCOPE"; do
    if [ "$mode" = line ]; then
      has_line "$target" "$fragment" && continue
    else
      has_substring "$target" "$fragment" && continue
    fi
    if [ "$target" = "$CREATE_ISSUE" ]; then
      missing_create=$((missing_create + 1))
      echo "  ✗ create-issue に契約行がありません（${mode}）: $fragment" >&2
    else
      missing_scope=$((missing_scope + 1))
      echo "  ✗ out-of-scope-issue に契約行がありません（${mode}）: $fragment" >&2
    fi
  done
done < "$FRAGMENTS"

if [ "$fragment_count" -eq "$EXPECTED_SHARED_FRAGMENTS" ]; then
  ok "散文契約の検査対象が ${EXPECTED_SHARED_FRAGMENTS} 行（増減時は EXPECTED_SHARED_FRAGMENTS も更新すること）"
else
  bad "散文契約の検査対象が ${fragment_count} 行（期待 ${EXPECTED_SHARED_FRAGMENTS} 行）— fixture かパーサーが黙って縮んでいる"
fi

if [ "$fragment_count" -gt 0 ] && [ "$missing_create" -eq 0 ]; then
  ok "create-issue が散文契約 全 ${fragment_count} 行を保持"
elif [ "$missing_create" -gt 0 ]; then
  FAIL=$((FAIL + 1))
  echo "  ✗ create-issue に ${missing_create} 行の欠落（$(rel "$FRAGMENTS") と突き合わせること）" >&2
fi
if [ "$fragment_count" -gt 0 ] && [ "$missing_scope" -eq 0 ]; then
  ok "out-of-scope-issue が散文契約 全 ${fragment_count} 行を保持"
elif [ "$missing_scope" -gt 0 ]; then
  FAIL=$((FAIL + 1))
  echo "  ✗ out-of-scope-issue に ${missing_scope} 行の欠落（$(rel "$FRAGMENTS") と突き合わせること）" >&2
fi

# ---- 4. create-issue 固有 ------------------------------------------------------
# Issue #292 原因1: description に発動トリガーが無いと、消費プロジェクトの
# Git Workflow が規定する `gh issue create` の直接実行へ流れ、スキル自体が
# 呼ばれない。本文中の同名語で充足しないよう description 行だけを見る。
CI_DESCRIPTION="$(description_line "$CREATE_ISSUE")"
description_has() {
  local needle="$1" label="$2"
  case "$CI_DESCRIPTION" in
    *"$needle"*) ok "$label" ;;
    *) bad "${label}（description に不足: ${needle}）" ;;
  esac
}
if [ -z "$CI_DESCRIPTION" ]; then
  bad "create-issue の frontmatter から description 行を取り出せない"
else
  description_has "Use when creating a new GitHub Issue" "description が発動条件から始まる"
  description_has "「Issue 作って」" "description に日本語の起票トリガーがある"
  description_has "create an issue" "description に英語の起票トリガーがある"
  description_has "refine-issue" "description が事後 refine との棲み分けを示す"
  description_has "out-of-scope-issue" "description が follow-up 起票との棲み分けを示す"
fi

# Issue #292 AC3: ヒアリング必須のままだと自律フローから構造的にスキップされる。
contains "$CREATE_ISSUE" "#### 非対話モード" "非対話モードの分岐がある"
contains "$CREATE_ISSUE" "受け入れ条件（AC）とストーリー要素の中身は推測で埋めない" "非対話でも AC とストーリーは推測しない"
contains "$CREATE_ISSUE" "推定した項目とその根拠は手順 7 の完了報告に 1 行で残す" "推定は黙って行わず報告する"

# 省略ラベルの報告は verify-then-skip の後半。これが落ちると「黙って落とす」に戻る。
contains "$CREATE_ISSUE" "省略したラベル名と理由を手順 7 の完了報告に含める" "省略ラベルの報告義務が手順に残っている"
contains "$CREATE_ISSUE" "**省略したラベル名 + 理由**" "完了報告の項目に省略ラベルが含まれる"

# 起票コマンドの束縛。暗黙の GH_REPO / cwd 任せにしない。
contains "$CREATE_ISSUE" 'expected_repo="OWNER/REPO"' "対象リポジトリを明示的に固定"
# 実行される gh コマンドを 1 件ずつ検査する。件数も固定して、行継続を畳むだけで
# 検査対象が 0 件になる（= 違反ゼロで緑）空振りを防ぐ。
gh_issue_commands_bound "$CREATE_ISSUE" create 1 yes "create-issue の gh issue create が --repo と --assignee を持つ"
gh_issue_commands_bound "$OUT_OF_SCOPE" create 1 no  "out-of-scope-issue の gh issue create が --repo を持ち --assignee を持たない"
gh_issue_commands_bound "$OUT_OF_SCOPE" list   1 no  "out-of-scope-issue の gh issue list が --repo を持つ"

# ラベル決定と起票が同じシェルで走ること。分割すると label_args が失われ、
# `${label_args[@]+...}` が空へ展開して「ラベル 0 個で起票成功」が静かに起きる。
# 散文の宣言だけでは実体の分割を検出できないので、フェンス構造でも見る。
label_loop_and_create_same_fence "$CREATE_ISSUE" "ラベル決定ループと起票が同一の bash フェンス"
# needle は必ずシングルクォートで書く。ダブルクォートだと needle 内のバックティックが
# コマンド置換され、検査スクリプトが検査対象のコマンド（`gh issue create` 等）を
# 実際に実行してしまう。契約テキストはバッククォートを多く含むので現実的な事故。
contains "$CREATE_ISSUE" 'ラベルの実在確認から `gh issue create` までを 1 つの bash ブロックで' "単一ブロックであることが本文にも書かれている"
# 終了コード 0 + 空 URL を成功として通すと、Issue が実在しない状態と区別できない。
contains "$CREATE_ISSUE" 'if [[ -z "$issue_url" ]]; then' "起票後に Issue URL の非空を確認する"
contains "$CREATE_ISSUE" 'printf '"'"'LABEL_LOOKUP_FAILED=%s\n'"'"'' "照会状態を出力して報告へ渡す"
contains "$CREATE_ISSUE" '手順 6 のブロックが出力した行をそのまま読む' "報告は記憶ではなく出力を写す"

# 2 系統（type / priority）であって follow-up は付けない、という create-issue 側の境界。
# 契約ブロック側ではプレースホルダへ正規化した違いを、ここで実体として固定する。
contains "$CREATE_ISSUE" 'for candidate in "$type_label" "$priority_label"; do' "候補は type / priority の 2 系統"
contains "$CREATE_ISSUE" '`follow-up` 系のラベルは付けない' "着手前起票は follow-up を付けない"

# ---- 5. out-of-scope-issue 固有 ------------------------------------------------
contains "$OUT_OF_SCOPE" 'for candidate in "$type_label" "$priority_label" "$followup_label"; do' "候補は type / priority / follow-up の 3 系統"
# Issue #297: 実在確認と起票が別フェンスに分かれていると、フェンスごとに別シェルで
# 実行された時点で label_args が失われ、「ラベル 0 個で起票成功」が無言で起きる。
# create-issue と同じ単一フェンス構造を out-of-scope-issue にも要求する。
label_loop_and_create_same_fence "$OUT_OF_SCOPE" "ラベル決定ループと起票が同一の bash フェンス（out-of-scope-issue）"
contains "$OUT_OF_SCOPE" 'ラベルの実在確認から `gh issue create` までを 1 つの bash ブロックで' "単一ブロックであることが本文にも書かれている（out-of-scope-issue）"
contains "$OUT_OF_SCOPE" 'if [[ -z "$issue_url" ]]; then' "起票後に Issue URL の非空を確認する（out-of-scope-issue）"
contains "$OUT_OF_SCOPE" 'printf '"'"'LABEL_LOOKUP_FAILED=%s\n'"'"'' "照会状態を出力して報告へ渡す（out-of-scope-issue）"
contains "$OUT_OF_SCOPE" 'ブロックが出力した行をそのまま読む' "報告は記憶ではなく出力を写す（out-of-scope-issue）"

# ---- 6. 意図的な非対称の固定（アサイン） ----------------------------------------
# create-issue は着手前の起票ゲートなので同梱 Git Workflow に従い @me を付ける。
# out-of-scope-issue の起票は backlog 化であって着手ではないのでアサインしない。
# 「揃えよう」としてどちらかを崩す変更を検出する。
has_argument_line "$CREATE_ISSUE" "$ASSIGNEE_PATTERN" "着手前起票はアサインを既定にする（引数行として存在）"
lacks_argument_line "$OUT_OF_SCOPE" "$ASSIGNEE_PATTERN" "follow-up 起票はアサインを既定にしない"
contains "$CREATE_ISSUE" "この非対称は意図的で" "アサインの非対称が意図的だと本文に明記されている"
contains "$OUT_OF_SCOPE" "アサインについて本スキルは中立" "follow-up 側のアサイン中立方針が残っている"

# ---- 7. ラベル作成はしない（両スキル共通） --------------------------------------
# 起票ゲートが消費プロジェクトのラベル体系を増やすと分類が場当たりに膨らむ。
# `refine-issue` の `needs-spec`（`gh label create --force`）とは役割が違う。
# 検出器が空振りしていないことを、実際に作る refine-issue を対照にして確かめる。
has_argument_line "$REFINE_ISSUE" "$LABEL_CREATE_PATTERN" "自己検証: gh label create の実行行を検出できる（refine-issue が対照）"
lacks_argument_line "$CREATE_ISSUE" "$LABEL_CREATE_PATTERN" "create-issue はラベルを作成しない"
lacks_argument_line "$OUT_OF_SCOPE" "$LABEL_CREATE_PATTERN" "out-of-scope-issue はラベルを作成しない"

# ---- 8. 手順番号の整合 ----------------------------------------------------------
# 手順を挿入したときに本文中の「手順 N」参照が置き去りになると、エージェントは
# 存在しない節へ飛ぶ。見出しに存在しない番号を参照していないかを機械で見る。
missing_steps="$(
  awk '
    /^### [0-9]+\./ { n = $2; sub(/\./, "", n); headings[n] = 1; next }
    { line = $0
      while (match(line, /手順 ?[0-9]+/)) {
        ref = substr(line, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", ref)
        refs[ref] = refs[ref] " " NR
        line = substr(line, RSTART + RLENGTH)
      }
    }
    END { for (r in refs) if (!(r in headings)) print r ":" refs[r] }
  ' "$CREATE_ISSUE"
)"
if [ -z "$missing_steps" ]; then
  ok "本文の「手順 N」参照がすべて実在する見出しを指す"
else
  bad "存在しない手順番号への参照がある（番号:行）: ${missing_steps//$'\n'/, }"
fi

# ---- 9. 手順を実際に走らせる（Issue #292 の受け入れ条件そのもの） -----------------
# 静的検査は「手順にそう書いてある」までしか言えない。ラベルが実際に付くか、
# 照会が失敗したとき起票が続くか、省略理由が正しく分岐するかは走らせないと分からない。
# create-issue 手順 6 のブロックを stub `gh` の下で実行して振る舞いを実測する。
#
# 安全弁: stub が PATH の先頭に来ていることを確認してからでないと実行しない。
# 取り違えると**本物の Issue を作ってしまう**ので、疑わしければ実行せず赤にする。
STUB_DIR="$FIXTURES_DIR/gh-stub"

# 実行対象は create-issue 最初の ```bash フェンス（＝手順 6 の統合ブロック）。
extract_first_bash_fence() {
  awk '
    { sub(/\r$/, "") }
    started == 0 { if ($0 ~ /^[[:space:]]*```[[:space:]]*bash[[:space:]]*$/) { started = 1 } ; next }
    /^[[:space:]]*```[[:space:]]*$/ { exit }
    { print }
  ' "$1"
}

# 指定した文字列を含む**最初の** bash フェンスを取り出す（Issue #297）。
# out-of-scope-issue の統合ブロックはファイル先頭のフェンスではない（§3.1 の
# 検索ブロックが先にある）ため、needle を含むフェンスで特定する。フェンス言語は
# label_loop_and_create_same_fence と同じ集合を許容する（非対称だと、フェンスを
# ```sh へ変えたとき構造検査と behavioral 検査が食い違った赤になり誤誘導する）。
extract_fence_containing() {
  awk -v needle="$2" '
    { sub(/\r$/, "") }
    in_f == 0 { if ($0 ~ /^[[:space:]]*```[[:space:]]*(bash|sh|shell|zsh)[[:space:]]*$/) { in_f = 1; buf = ""; hit = 0 }; next }
    /^[[:space:]]*```[[:space:]]*$/ { if (hit) { printf "%s", buf; exit } ; in_f = 0; next }
    { buf = buf $0 "\n"; if (index($0, needle)) hit = 1 }
  ' "$1"
}

# out-of-scope-issue の統合ブロックを一意に特定する needle。素の `gh issue create` だと
# 将来 §3.1 のコメントに同語が言及された時点で誤ったフェンスを先頭ヒットで掴む。
SCOPE_FENCE_NEEDLE='issue_url="$(gh issue create'

run_block() {
  # $1: GH_STUB_MODE / $2: type_label / $3: priority_label / $4: merge_stderr(yes|no)
  # プレースホルダを差し替えて標準入力から実行する。**一時ファイルを一切作らない**
  # （作業ツリーへ書くと read-only 環境で落ち、かつリポジトリを汚す）。
  local merged="${4:-no}"
  if [ "$merged" = yes ]; then
    extract_first_bash_fence "$CREATE_ISSUE" \
      | sed -e 's|^expected_repo=.*|expected_repo="stub-owner/stub-repo"|' \
            -e "s|^type_label=.*|type_label=\"$2\"|" \
            -e "s|^priority_label=.*|priority_label=\"$3\"|" \
            -e 's|^issue_body=.*|issue_body="stub body"|' \
      | PATH="$STUB_DIR:$PATH" GH_STUB_MODE="$1" bash -euo pipefail -s 2>&1
  else
    extract_first_bash_fence "$CREATE_ISSUE" \
      | sed -e 's|^expected_repo=.*|expected_repo="stub-owner/stub-repo"|' \
            -e "s|^type_label=.*|type_label=\"$2\"|" \
            -e "s|^priority_label=.*|priority_label=\"$3\"|" \
            -e 's|^issue_body=.*|issue_body="stub body"|' \
      | PATH="$STUB_DIR:$PATH" GH_STUB_MODE="$1" bash -euo pipefail -s 2>/dev/null
  fi
}

run_scope_block() {
  # $1: GH_STUB_MODE / $2: type_label / $3: priority_label / $4: followup_label /
  # $5: merge_stderr(yes|no)
  # out-of-scope-issue の統合ブロック（Issue #297）を実行する。issue_body の heredoc は
  # **実行時に bash が一時ファイルを要求する**ため、read-only 環境では
  # `cannot create temp file for here document` で必ず落ちる。「一時ファイルを
  # 一切作らない」という本 suite の前提を守るため、heredoc の代入全体を
  # `issue_body="stub body"` へ置き換えてから実行する。
  local merged="${5:-no}"
  if [ "$merged" = yes ]; then
    extract_fence_containing "$OUT_OF_SCOPE" "$SCOPE_FENCE_NEEDLE" \
      | sed -e 's|^expected_repo=.*|expected_repo="stub-owner/stub-repo"|' \
            -e "s|^type_label=.*|type_label=\"$2\"|" \
            -e "s|^priority_label=.*|priority_label=\"$3\"|" \
            -e "s|^followup_label=.*|followup_label=\"$4\"|" \
            -e '/^issue_body="\$(cat/,/^)"$/c\
issue_body="stub body"' \
      | PATH="$STUB_DIR:$PATH" GH_STUB_MODE="$1" bash -euo pipefail -s 2>&1
  else
    extract_fence_containing "$OUT_OF_SCOPE" "$SCOPE_FENCE_NEEDLE" \
      | sed -e 's|^expected_repo=.*|expected_repo="stub-owner/stub-repo"|' \
            -e "s|^type_label=.*|type_label=\"$2\"|" \
            -e "s|^priority_label=.*|priority_label=\"$3\"|" \
            -e "s|^followup_label=.*|followup_label=\"$4\"|" \
            -e '/^issue_body="\$(cat/,/^)"$/c\
issue_body="stub body"' \
      | PATH="$STUB_DIR:$PATH" GH_STUB_MODE="$1" bash -euo pipefail -s 2>/dev/null
  fi
}

behavioral_case() {
  # $1: モード / $2: type / $3: priority / $4: 期待する出力の部分列 / $5: 検査名
  # 出力は `|` 区切りへ畳んで部分列で照合するので、**行の順序も契約に含む**。
  # 報告（手順 7）はこの出力を読む前提なので、並びが変われば読み手の手順も変わる。
  local out
  if ! out="$(run_block "$1" "$2" "$3")"; then
    bad "${5}（ブロックが非 0 で終了した）"
    return
  fi
  case "$(printf '%s' "$out" | tr '\n' '|')" in
    *"$4"*) ok "$5" ;;
    *) bad "${5}（期待: ${4} / 実際: $(printf '%s' "$out" | tr '\n' '|')）" ;;
  esac
}

scope_behavioral_case() {
  # $1: モード / $2: type / $3: priority / $4: follow-up / $5: 期待する出力の部分列 /
  # $6: 検査名。behavioral_case と同じく出力を `|` 区切りへ畳んで部分列で照合する
  # （行の順序も契約に含む — §3.6 の報告はこの出力を読む前提のため）。
  local out diag
  if ! out="$(run_scope_block "$1" "$2" "$3" "$4")"; then
    # 理由（sed がスクリプトを壊した / ガード発火 / stub 未解決）が出ないと
    # 赤くなったときに調査の起点が無い。merged で撮り直して末尾を添える。
    diag="$(run_scope_block "$1" "$2" "$3" "$4" yes || true)"
    bad "${6}（ブロックが非 0 で終了した: $(printf '%s' "$diag" | tail -3 | tr '\n' '|')）"
    return
  fi
  case "$(printf '%s' "$out" | tr '\n' '|')" in
    *"$5"*) ok "$6" ;;
    *) bad "${6}（期待: ${5} / 実際: $(printf '%s' "$out" | tr '\n' '|')）" ;;
  esac
}

block_body="$(extract_first_bash_fence "$CREATE_ISSUE")"
resolved_gh="$(PATH="$STUB_DIR:$PATH" command -v gh || true)"
if [ ! -x "$STUB_DIR/gh" ]; then
  bad "behavioral 検査: stub gh が実行可能でない（$STUB_DIR/gh）"
elif [ "$resolved_gh" != "$STUB_DIR/gh" ]; then
  bad "behavioral 検査: gh が stub に解決されない（${resolved_gh}）— 実 gh を叩く危険があるので実行しない"
elif [ -z "$block_body" ]; then
  bad "behavioral 検査: create-issue の bash フェンスを取り出せない"
else
  ok "behavioral 検査: gh が stub に解決される（実 API を叩かない）"

  # AC1: 実在するラベルは付与され、gh の argv に載る。期待部分列を ISSUE_URL 行から
  # 始めることで「状態出力は起票成功後」という順序契約も同時に固定する
  # （ISSUE_URL は URL ガード通過後にしか出ない — 状態行を前置する変異で赤になる）。
  behavioral_case normal enhancement priority:high \
    'ISSUE_URL=https://github.com/stub-owner/stub-repo/issues/1|LABEL_LOOKUP_FAILED=0|APPLIED_LABEL=enhancement|APPLIED_LABEL=priority:high' \
    "AC1: 実在する種別・優先度ラベルが付与された状態で起票される"

  # AC2: 不在の候補は起票を止めず、名前と理由が出力に残る
  behavioral_case normal enhancement priority:nonexistent \
    'LABEL_LOOKUP_FAILED=0|APPLIED_LABEL=enhancement|SKIPPED_LABEL=priority:nonexistent' \
    "AC2: 不在ラベルは起票を止めず、省略理由が「不在」として出る"

  # AC2: 照会そのものの失敗は「不在」と区別される（重複ラベルを生やさない側へ倒す）
  behavioral_case fail enhancement priority:high \
    'LABEL_LOOKUP_FAILED=1|SKIPPED_LABEL=enhancement|SKIPPED_LABEL=priority:high' \
    "AC2: 照会失敗はラベル無しで起票を続け、「不在」と区別して報告される"

  # 終了コード 0 でも信用できない 2 経路が「照会失敗」へ倒れる
  behavioral_case empty enhancement priority:high 'LABEL_LOOKUP_FAILED=1' \
    "空の一覧を「不在」と誤断定しない"
  behavioral_case truncated enhancement priority:high 'LABEL_LOOKUP_FAILED=1' \
    "取得上限に達した一覧を「不在」と誤断定しない"

  # 系統が無い場合は候補ごと読み飛ばし、起票は成功する
  behavioral_case normal '' '' \
    'ISSUE_URL=https://github.com/stub-owner/stub-repo/issues/1|LABEL_LOOKUP_FAILED=0' \
    "候補が空文字なら照合せず読み飛ばす"
  # 部分列照合は「不在」を主張できないので、ラベル状態行が出ないことは別に見る
  nolabel_out="$(run_block normal '' '' || true)"
  case "$(printf '%s' "$nolabel_out" | tr '\n' '|')" in
    *APPLIED_LABEL=*|*SKIPPED_LABEL=*) bad "候補が無いのにラベル状態行が出ている" ;;
    *) ok "候補が無ければラベル状態行を出さない" ;;
  esac

  # 終了コード 0 + 空 URL を成功として通さない
  if run_block emptyurl enhancement priority:high >/dev/null 2>&1; then
    bad "URL を返さない起票を成功として扱っている（Issue が実在しない状態と区別できない）"
  else
    ok "URL を返さない起票は失敗として扱う"
  fi
  # 失敗経路で状態出力が残らないこと。exit code だけ見る検査では、printf 群を
  # URL ガードの前へ移す変異（起票失敗でも APPLIED_LABEL= が残り、実在しない
  # Issue のラベル付き成功報告が書ける）が緑のまま通る。
  emptyurl_out="$(run_block emptyurl enhancement priority:high yes || true)"
  case "$(printf '%s' "$emptyurl_out" | tr '\n' '|')" in
    *ISSUE_URL=*|*APPLIED_LABEL=*|*SKIPPED_LABEL=*)
      bad "起票失敗後に状態出力が残る（付いていないラベルが報告の材料になる）" ;;
    *'Issue URL を返しませんでした'*)
      ok "起票失敗は状態出力を残さず、ガードの診断だけを出す" ;;
    *)
      bad "起票失敗時にガードの診断が出ていない（別の理由で落ちた可能性）" ;;
  esac

  # 起票コマンド自体の非 0 終了も成功として通さない（|| true 等で握りつぶす退行の固定）
  if run_block createfail enhancement priority:high >/dev/null 2>&1; then
    bad "起票コマンドの非 0 終了を成功として扱っている"
  else
    ok "起票コマンドの非 0 終了は失敗として扱う"
  fi
  createfail_out="$(run_block createfail enhancement priority:high yes || true)"
  case "$(printf '%s' "$createfail_out" | tr '\n' '|')" in
    *ISSUE_URL=*|*APPLIED_LABEL=*|*SKIPPED_LABEL=*)
      bad "起票コマンド失敗後に成功形式の状態出力が残る" ;;
    *) ok "起票コマンド失敗後に状態出力を残さない" ;;
  esac

  # 実際に gh へ渡った argv を見る。出力の APPLIED_LABEL= だけを見ると、報告用の
  # 文字列を作っただけでコマンドには渡っていない、という食い違いを見逃す。
  # stub は argv を stderr へ書くので merged で受け、**GH_ISSUE_ARGV 行だけに絞って**
  # 照合する。合流ストリーム全体を glob で見ると `*` が行をまたぎ、argv にラベルが
  # 無くても後続の状態出力行で充足してしまう（変異試験で実証済みの偽陽性経路）。
  argv_out="$(run_block normal enhancement priority:high yes | sed -n '/^GH_ISSUE_ARGV: /p' || true)"
  case "$argv_out" in
    *'--label enhancement --label priority:high'*)
      ok "付与ラベルが報告用の文字列だけでなく gh の argv に載っている" ;;
    *)
      bad "gh へ渡った argv にラベルが載っていない（報告と実際の乖離）" ;;
  esac

  # ---- Issue #297: out-of-scope-issue の統合ブロック（§3.3）も実測する ----------
  # 契約ブロック（実在確認〜for ループ）は create-issue と共有だが、宣言・起票・
  # 状態出力の結合部はファイル固有にある。分割時代はここが別シェルに分かれ、
  # 「ラベル 0 個で起票成功」が無言で起きていた。fail-soft の分岐自体は共有ブロック内
  # だが、その結果 `label_lookup_failed` を消費するのは結合部なので、照会失敗系も
  # ここで実測する（結合部だけを fail-closed へ反転する変異は共有部の照合では捕まらない）。
  scope_body="$(extract_fence_containing "$OUT_OF_SCOPE" "$SCOPE_FENCE_NEEDLE")"
  if [ -z "$scope_body" ]; then
    bad "behavioral 検査: out-of-scope-issue の統合ブロックを取り出せない"
  else
    # AC1: 実在する type / priority / follow-up の 3 系統が付与され、出力に現れる。
    # ISSUE_URL 行から始めて「状態出力は起票成功後」の順序契約も固定する。
    scope_behavioral_case normal bug priority:high follow-up \
      'ISSUE_URL=https://github.com/stub-owner/stub-repo/issues/1|LABEL_LOOKUP_FAILED=0|APPLIED_LABEL=bug|APPLIED_LABEL=priority:high|APPLIED_LABEL=follow-up' \
      "out-of-scope: 実在する 3 系統が付与された状態で起票され、出力に現れる"

    # AC2: 不在の候補は起票を止めず、名前と理由が出力に残る
    scope_behavioral_case normal bug priority:nonexistent follow-up \
      'LABEL_LOOKUP_FAILED=0|APPLIED_LABEL=bug|APPLIED_LABEL=follow-up|SKIPPED_LABEL=priority:nonexistent' \
      "out-of-scope: 不在ラベルは起票を止めず、省略理由が「不在」として出る"

    # 照会失敗はラベル無しで起票を**続ける**（fail-soft）。結合部が
    # label_lookup_failed に条件づけられて起票を止める変異で赤になる。
    scope_behavioral_case fail bug priority:high follow-up \
      'LABEL_LOOKUP_FAILED=1|SKIPPED_LABEL=bug|SKIPPED_LABEL=priority:high|SKIPPED_LABEL=follow-up' \
      "out-of-scope: 照会失敗はラベル無しで起票を続け、「不在」と区別して報告される"
    scope_behavioral_case empty bug priority:high follow-up 'LABEL_LOOKUP_FAILED=1' \
      "out-of-scope: 空の一覧を「不在」と誤断定しない"
    scope_behavioral_case truncated bug priority:high follow-up 'LABEL_LOOKUP_FAILED=1' \
      "out-of-scope: 取得上限に達した一覧を「不在」と誤断定しない"

    # 終了コード 0 + 空 URL を成功として通さない
    if run_scope_block emptyurl bug priority:high follow-up >/dev/null 2>&1; then
      bad "out-of-scope: URL を返さない起票を成功として扱っている（Issue が実在しない状態と区別できない）"
    else
      ok "out-of-scope: URL を返さない起票は失敗として扱う"
    fi
    scope_emptyurl_out="$(run_scope_block emptyurl bug priority:high follow-up yes || true)"
    case "$(printf '%s' "$scope_emptyurl_out" | tr '\n' '|')" in
      *ISSUE_URL=*|*APPLIED_LABEL=*|*SKIPPED_LABEL=*)
        bad "out-of-scope: 起票失敗後に状態出力が残る（付いていないラベルが報告の材料になる）" ;;
      *'Issue URL を返しませんでした'*)
        ok "out-of-scope: 起票失敗は状態出力を残さず、ガードの診断だけを出す" ;;
      *)
        bad "out-of-scope: 起票失敗時にガードの診断が出ていない（別の理由で落ちた可能性）" ;;
    esac

    # 起票コマンド自体の非 0 終了も成功として通さない
    if run_scope_block createfail bug priority:high follow-up >/dev/null 2>&1; then
      bad "out-of-scope: 起票コマンドの非 0 終了を成功として扱っている"
    else
      ok "out-of-scope: 起票コマンドの非 0 終了は失敗として扱う"
    fi
    scope_createfail_out="$(run_scope_block createfail bug priority:high follow-up yes || true)"
    case "$(printf '%s' "$scope_createfail_out" | tr '\n' '|')" in
      *ISSUE_URL=*|*APPLIED_LABEL=*|*SKIPPED_LABEL=*)
        bad "out-of-scope: 起票コマンド失敗後に成功形式の状態出力が残る" ;;
      *) ok "out-of-scope: 起票コマンド失敗後に状態出力を残さない" ;;
    esac

    # 実際に gh へ渡った argv を見る。GH_ISSUE_ARGV 行だけに絞る理由は
    # create-issue 側の argv 検査と同じ（行またぎ glob の偽陽性防止）。
    scope_argv="$(run_scope_block normal bug priority:high follow-up yes | sed -n '/^GH_ISSUE_ARGV: /p' || true)"
    case "$scope_argv" in
      *'--label bug --label priority:high --label follow-up'*)
        ok "out-of-scope: 付与ラベルが gh の argv に載っている" ;;
      *)
        bad "out-of-scope: gh へ渡った argv にラベルが載っていない（報告と実際の乖離）" ;;
    esac
  fi
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ issue-label-contract verify: $FAIL 件失敗 / $PASS 件成功" >&2
  exit 1
fi
echo "✓ issue-label-contract verify: 全 $PASS 件 pass"
