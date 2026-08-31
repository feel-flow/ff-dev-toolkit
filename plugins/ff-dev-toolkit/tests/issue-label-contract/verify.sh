#!/usr/bin/env bash
#
# 起票・refine スキル間で複製されている契約の同期検査。2 系統を扱う:
#   A. 起票スキル 2 本（create-issue / out-of-scope-issue）のラベル付与契約
#      （verify-then-skip）の同期（Issue #292 / #297 / #715）… 検査 1〜7
#   B. create-issue 手順 4 の粒度チェック項目リストと、refine-issue がそれを
#      写した派生対応表の同期（Issue #591）… 検査 10（番号は導入時のまま）
#
# `create-issue`（着手前の起票ゲート）と `out-of-scope-issue`（スコープ外発見の
# follow-up 起票）は、どちらも「実在するラベルだけを付ける」同じ手順を持つ。
# 存在しないラベル名を渡すと `gh issue create` 自体が失敗するため、ラベル名を
# 直書きで固定できず、`gh label list` での実在確認 → 存在するものだけ付与 →
# 省略分は理由付きで報告、という手順が両者に要る。
#
# 手順の形は Issue #715 で「単一の複合 bash ブロック」から「body-file + 単純コマンド
# 分割」へ改めた。本文は Write ツールで一時ファイルへ書いて `--body-file` で渡し、
# `gh label list` を単独実行してエージェントが出力を読んで実在照合し、`gh issue create`
# へ `--label` を直書きして単独実行する。シェル変数で状態をコマンド間に運ばないため、
# 旧方式を支えた装置（heredoc 組み立て・空ガード・bash 3.2 の空配列トリック・
# SIGPIPE 回避の照合ループ・fail-soft 分岐群）は存在せず、worktree 隔離セッションの
# 複合コマンド拒否ガードとも衝突しない。
#
# なぜ共有ファイルに切り出さず複製するのか: 照合と報告の判定規則は起票コマンドの
# 直前で読まれる必要がある。参照ファイルへ分断すると、エージェントが参照先を読まずに
# 実在確認ごと飛ばす経路ができる（progressive disclosure は「読まれないことがある」を
# 前提にした仕組みで、必須手順の置き場所ではない）。そこでドリフト対策は「共有」では
# なく「照合」で行う。
#
# 検査の層:
#   1. 起票手順の形（検査 1）… 3 つの構造検査で worktree ガード拒否の再発
#      （Issue #715 の受け入れ条件）を塞ぐ。(a) `gh label list` / `gh issue create` を
#      含む bash フェンスを**全数**走査し、複合構文（if / for / while / until / case /
#      heredoc / 関数定義）に加えて論理連結（&& / ||）・パイプ・コマンド区切り（;）・
#      コマンド置換（$( / バッククォート）・サブシェルを赤にする（引用符内の文字は
#      対象外 — `--jq '.[].name'` 等を誤検出しない）。(b) `$expected_repo` を参照する
#      フェンスは同じフェンス内で宣言していること（フェンスは別シェルで走るため、
#      後続フェンスからの参照は空になる）。(c) 起票フェンスに `--repo` / `--label` /
#      `--body-file` が同居していること（散文の存在確認だけでは別の場所に散っても
#      緑になる）。あわせて旧 1 ブロック方式の装置が復元されていないことを見る。
#   2. fixtures/shared-fragments.txt … 複製された散文・表・コマンド行を行単位で
#      照合する。既定は**行全体の完全一致**（部分一致だと片側の行末に文を継ぎ足す
#      ドリフトが素通りする）。両ファイルで前後が意図的に違う箇所だけ `~ ` で
#      部分一致にする。
#
# 旧方式にあった gh stub での behavioral 実測は撤去した。ラベル照合の判断が bash から
# エージェント側へ移り、実行して検証できる bash ロジックそのものが存在しなくなった
# ため（実行対象の無い stub 実測は空検査になる）。代替の検出力は上の構造検査（1）と
# 散文契約（2）が持つ: 成功条件（終了コード 0 + Issue URL）と照会失敗時の fail-soft
# 続行規則は fragment として両ファイルに固定される。
#
# 検出範囲の限界（過大に主張しない）:
#   系統 A（ラベル契約）が赤くするのは fixtures に載せた契約テキストを片方だけ
#   書き換えた／削除した場合である。fixtures に載っていない複製文が片方だけ変わっても
#   検出しない。
#   系統 B（項目リスト）が赤くするのは、create-issue 手順 4 の**項目名の集合**と
#   refine-issue の対応表の**左列の集合**が食い違った場合、およびどちらかの抽出が
#   0 件になった場合である（fail-closed）。右列の文言・対応表の行順・refine 自身の
#   6 観点の項目名は見ない。期待値は両ファイルの実体から導出するので、テスト側に
#   項目数を書かない（書くと項目を増やすたびにここも直す必要が生まれ、忘れれば
#   検査対象の増減が緑のまま通る）。
#   SKILL.md 側の「片方だけ直すと red になる」という注記も、この範囲に限定して書くこと。
#
# 一時ディレクトリも jq / gh / yq も要らない純粋なファイル検査なので、書き込み不可の
# 環境でも完走する。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/issue-label-contract/verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
FRAGMENTS="$FIXTURES_DIR/shared-fragments.txt"

CREATE_ISSUE="$PLUGIN_ROOT/skills/create-issue/SKILL.md"
OUT_OF_SCOPE="$PLUGIN_ROOT/skills/out-of-scope-issue/SKILL.md"
# 2 つの役割を持つ: (1) `gh label create` 検出器の生きた対照（refine-issue は
# needs-spec を実際に作る）、(2) 検査 10 の同期対象そのもの（手順 4 の対応表）。
REFINE_ISSUE="$PLUGIN_ROOT/skills/refine-issue/SKILL.md"

# fixtures の検査対象行数。契約を増減したときは必ずここも直す。固定しないと、
# 抽出が壊れて 0 行になっても「全 fragment 一致」で緑になる。
EXPECTED_SHARED_FRAGMENTS=36

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

rel() { printf '%s' "${1#"$REPO_ROOT"/}"; }

echo "== 起票スキルのラベル契約 + create-issue↔refine-issue 項目リストの同期検査 =="

for file in "$CREATE_ISSUE" "$OUT_OF_SCOPE" "$REFINE_ISSUE" "$FRAGMENTS"; do
  [ -s "$file" ] || { echo "✗ 必須ファイルが無いか空です: $file" >&2; exit 1; }
done

# ---- 照合プリミティブ ---------------------------------------------------------
# ファイルを直接読む固定文字列検索。パイプ入力ではないので `grep -q` を使ってよい
# （上流 producer が居らず SIGPIPE で反転しない）。
has_line()      { grep -qxF -- "$2" "$1"; }  # 行全体の完全一致
has_substring() { grep -qF  -- "$2" "$1"; }  # 部分一致（`~ ` 指定の fragment 専用）

contains() {
  local file="$1" needle="$2" label="$3"
  if has_substring "$file" "$needle"; then ok "$label"; else bad "${label}（不足: ${needle}）"; fi
}

# 旧 1 ブロック方式の装置が復元されていないことの検査（負の主張）。
lacks() {
  local file="$1" needle="$2" label="$3"
  if has_substring "$file" "$needle"; then bad "${label}（旧装置が残存/復元: ${needle}）"; else ok "$label"; fi
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

# 指定した文字列を含む**最初の** bash フェンスを取り出す。
extract_fence_containing() {
  awk -v needle="$2" '
    { sub(/\r$/, "") }
    in_f == 0 { if ($0 ~ /^[[:space:]]*```[[:space:]]*(bash|sh|shell|zsh)[[:space:]]*$/) { in_f = 1; buf = ""; hit = 0 }; next }
    /^[[:space:]]*```[[:space:]]*$/ { if (hit) { printf "%s", buf; exit } ; in_f = 0; next }
    { buf = buf $0 "\n"; if (index($0, needle)) hit = 1 }
  ' "$1"
}

# needle を含む bash フェンスの**全数**が単純コマンドだけで構成されていることを見る
# （Issue #715 の受け入れ条件）。最初の 1 フェンスだけを見る方式では、同じ needle を
# 含む 2 つ目のフェンスが複合化しても素通りする。複合構文（if / for / while / until /
# case）・ヒアドキュメント・関数定義に加え、論理連結（&& / ||）・パイプ・コマンド
# 区切り（;）・コマンド置換（$( とバッククォート）・サブシェルも、worktree 隔離
# セッションの複合コマンド拒否ガードに衝突しうるため赤にする。演算子の判定は引用符
# （' / "）内の文字列を除去してから行い、`--jq '.[].name'` のような引数内の記号を
# 誤検出しない。フェンス件数も期待値で固定する（0 件へ退化したら赤 — 検査対象の
# 消失を「違反ゼロ」と報告しない）。
# シェルの単一引用で書けるよう、引用符の正規表現は文字コードから動的に組み立てる。
SIMPLE_FENCE_SCAN='
  function strip_quotes(s,    t, q, dq) {
    t = s
    q = sprintf("%c", 39); dq = sprintf("%c", 34)
    gsub(q "[^" q "]*" q, "", t)
    gsub(dq "[^" dq "]*" dq, "", t)
    return t
  }
  function check(line, ln,    work) {
    if (line ~ /^[[:space:]]*#/) return
    if (line ~ /^[[:space:]]*(if|for|while|until|case)([[:space:](]|$)/) { print "  " ln " 行目: 複合構文 → " line; return }
    if (line ~ /\(\)[[:space:]]*\{/) { print "  " ln " 行目: 関数定義 → " line; return }
    work = strip_quotes(line)
    if (index(work, "<<")) { print "  " ln " 行目: heredoc → " line; return }
    if (index(work, "&&") || index(work, "||")) { print "  " ln " 行目: 論理連結 → " line; return }
    if (index(work, ";")) { print "  " ln " 行目: コマンド区切り → " line; return }
    if (index(work, "$(") || index(work, sprintf("%c", 96))) { print "  " ln " 行目: コマンド置換 → " line; return }
    if (work ~ /^[[:space:]]*\(/) { print "  " ln " 行目: サブシェル → " line; return }
    if (index(work, "|")) { print "  " ln " 行目: パイプ → " line; return }
  }
  { sub(/\r$/, "") }
  in_f == 0 { if ($0 ~ /^[[:space:]]*```[[:space:]]*(bash|sh|shell|zsh)[[:space:]]*$/) { in_f = 1; n = 0; hit = 0; start = FNR }; next }
  /^[[:space:]]*```[[:space:]]*$/ {
    if (hit) { fences++; for (i = 1; i <= n; i++) check(buf[i], start + i) }
    in_f = 0; next
  }
  { buf[++n] = $0; if (index($0, needle)) hit = 1 }
  END { if (fences + 0 != expected + 0) print "  needle を含む bash フェンスが " fences + 0 " 件（期待 " expected " 件）— 検査対象が黙って増減している" }
'
all_needle_fences_simple() {
  local file="$1" needle="$2" expected="$3" label="$4" out
  out="$(awk -v needle="$needle" -v expected="$expected" "$SIMPLE_FENCE_SCAN" "$file")"
  if [ -z "$out" ]; then ok "$label"; else bad "${label}（単純コマンドの契約に違反）"; printf '%s\n' "$out" >&2; fi
}

# `$expected_repo` を参照する bash フェンスは、**同じフェンス内で** `expected_repo=` を
# 宣言していること。フェンスは呼び出しごとに別のシェルで走るため、前のフェンスの
# 宣言に依存した参照は実行時に空へ展開し、--repo の値が壊れた gh 呼び出しになる
# （本リファクタが潰した「ブロック間でシェル変数を運ぶ」失敗クラスの再発形）。
DECLARE_SCAN='
  { sub(/\r$/, "") }
  in_f == 0 { if ($0 ~ /^[[:space:]]*```[[:space:]]*(bash|sh|shell|zsh)[[:space:]]*$/) { in_f = 1; uses = 0; decl = 0; start = FNR }; next }
  /^[[:space:]]*```[[:space:]]*$/ { if (uses && !decl) print start; in_f = 0; next }
  {
    if (index($0, "$expected_repo")) uses = 1
    if ($0 ~ /^[[:space:]]*expected_repo=/) decl = 1
  }
'
fences_using_repo_declare_it() {
  local file="$1" label="$2" violations
  violations="$(awk "$DECLARE_SCAN" "$file")"
  if [ -z "$violations" ]; then ok "$label"
  else bad "${label}（宣言なしで \$expected_repo を参照するフェンス開始行: ${violations//$'\n'/, }）"; fi
}

# 起票フェンス（gh issue create を含むフェンス）に --repo / --label / --body-file が
# 同居していること。散文 fragment の存在確認だけでは、これらが別々の場所（例示・
# 別コマンド）に散っても緑になるため、同一フェンス内での同居を構造で固定する。
create_fence_bundles_flags() {
  local file="$1" label="$2" body missing=""
  body="$(extract_fence_containing "$file" 'gh issue create')"
  if [ -z "$body" ]; then
    bad "${label}（gh issue create を含む bash フェンスが見つからない）"
    return
  fi
  case "$body" in *'--repo "$expected_repo"'*) ;; *) missing="$missing --repo" ;; esac
  case "$body" in *'--label "'*) ;; *) missing="$missing --label" ;; esac
  case "$body" in *'--body-file "'*) ;; *) missing="$missing --body-file" ;; esac
  if [ -z "$missing" ]; then ok "$label"; else bad "${label}（起票フェンスに欠落:${missing}）"; fi
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
# 契約行を一括改稿しても対照が空振りしない。
SELF_INDENTED="$(awk '!/^;;/ && /^[[:space:]]+[^[:space:]]/ { print; exit }' "$FRAGMENTS")"
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

# フェンス抽出器の対照。needle を含む bash フェンスが無いファイルからは何も採れないこと。
if [ -n "$(extract_fence_containing "$REFINE_ISSUE" 'gh label list --repo "$expected_repo" --limit 200')" ]; then
  bad "自己検証: needle を含むフェンスの無いファイルから抽出できてしまった"
else
  ok "自己検証: needle を含むフェンスの無いファイルからは抽出しない"
fi

# 単純フェンス検出器の正の対照。out-of-scope-issue §3.5 のフェンスは `||` 連結と
# リダイレクトを含む生きた複合行を持つので、これを名指しで検出できなければ
# 検出器は常に「違反ゼロ」を返している。
if [ -n "$(awk -v needle='gh pr diff --name-only' -v expected=1 "$SIMPLE_FENCE_SCAN" "$OUT_OF_SCOPE")" ]; then
  ok "自己検証: 複合行を含む生きたフェンス（§3.5）を検出できる（正の対照）"
else
  bad "自己検証: 複合行を含むフェンスを検出できない — 単純フェンス検出器が壊れている"
fi

# 宣言同居検出器の対照。宣言なしで \$expected_repo を参照するフェンス（probe）を
# 赤にでき、宣言付きの probe を赤にしないこと。probe はパイプで渡し一時ファイルを
# 作らない。
DECLARE_PROBE_BAD="$(printf '%s\n' '```bash' 'gh issue list --repo "$expected_repo"' '```' | awk "$DECLARE_SCAN")"
DECLARE_PROBE_GOOD="$(printf '%s\n' '```bash' 'expected_repo="OWNER/REPO"' 'gh issue list --repo "$expected_repo"' '```' | awk "$DECLARE_SCAN")"
if [ -n "$DECLARE_PROBE_BAD" ]; then
  ok "自己検証: 宣言なしの \$expected_repo 参照フェンスを検出できる（正の対照）"
else
  bad "自己検証: 宣言なし参照を検出できない — 宣言同居検出器が壊れている"
fi
if [ -z "$DECLARE_PROBE_GOOD" ]; then
  ok "自己検証: 宣言付きフェンスを誤検出しない（負の対照）"
else
  bad "自己検証: 宣言付きフェンスを誤検出した"
fi

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "✗ issue-label-contract verify: 検出器の自己検証に失敗（本検査は実行しない）" >&2
  exit 1
fi

# ---- 1. 起票手順の形（Issue #715: body-file + 単純コマンド分割） -----------------
# 実在確認と起票の各 bash フェンスが単純コマンドだけで構成されていること。
# needle を含むフェンスを全数走査し、件数も固定する。
all_needle_fences_simple "$CREATE_ISSUE" 'gh label list --repo "$expected_repo" --limit 200' 1 \
  "create-issue: ラベル実在確認のフェンス（全数）が単純コマンドのみ"
all_needle_fences_simple "$CREATE_ISSUE" 'gh issue create' 1 \
  "create-issue: 起票のフェンス（全数）が単純コマンドのみ"
all_needle_fences_simple "$OUT_OF_SCOPE" 'gh label list --repo "$expected_repo" --limit 200' 1 \
  "out-of-scope-issue: ラベル実在確認のフェンス（全数）が単純コマンドのみ"
all_needle_fences_simple "$OUT_OF_SCOPE" 'gh issue create' 1 \
  "out-of-scope-issue: 起票のフェンス（全数）が単純コマンドのみ"

# $expected_repo を参照する全フェンスが同一フェンス内で宣言している（別シェルで走る
# 後続フェンスからの参照 = 空展開の再発防止）。
fences_using_repo_declare_it "$CREATE_ISSUE" "create-issue: \$expected_repo は参照フェンス内で宣言されている"
fences_using_repo_declare_it "$OUT_OF_SCOPE" "out-of-scope-issue: \$expected_repo は参照フェンス内で宣言されている"

# 起票フェンスに --repo / --label / --body-file が同居している（散文照合の補完）。
create_fence_bundles_flags "$CREATE_ISSUE" "create-issue: 起票フェンスに --repo / --label / --body-file が同居"
create_fence_bundles_flags "$OUT_OF_SCOPE" "out-of-scope-issue: 起票フェンスに --repo / --label / --body-file が同居"

# 旧 1 ブロック方式の装置が復元されていないこと。これらはシェル変数で状態を
# コマンド間に運ぶ設計（= 単一の複合ブロックを要求する設計）の指紋であり、
# 1 つでも戻れば worktree ガード拒否（Issue #715 の起点）が再発する。
for target in "$CREATE_ISSUE" "$OUT_OF_SCOPE"; do
  name="$(basename "$(dirname "$target")")"
  lacks "$target" 'label_args' "${name}: label_args（配列組み立て）が無い"
  lacks "$target" 'for candidate in ' "${name}: 照合の for ループが無い"
  lacks "$target" 'issue_body' "${name}: issue_body（heredoc 組み立て）が無い"
  lacks "$target" 'LABEL_LOOKUP_FAILED' "${name}: 状態出力プロトコルが無い"
  lacks "$target" 'までを 1 つの bash ブロックで' "${name}: 単一ブロック要求の宣言が無い"
done

# ---- 2. 散文契約の照合（既定は行全体一致、`~ ` は部分一致） ----------------------
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

# ---- 3. create-issue 固有 ------------------------------------------------------
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

# 2 系統（type / priority）であって follow-up は付けない、という create-issue 側の境界。
# 契約 fragment はこの違いを持てない（両ファイルに同一で在ることを見る仕組みのため）
# ので、意図的な差分はここで実体として固定する。
# needle は必ずシングルクォートで書く。ダブルクォートだと needle 内のバックティックが
# コマンド置換され、検査スクリプトが検査対象のコマンド（`gh issue create` 等）を
# 実際に実行してしまう。契約テキストはバッククォートを多く含むので現実的な事故。
contains "$CREATE_ISSUE" '照合する候補は手順 5 で決めた type / priority の 2 系統' "候補は type / priority の 2 系統"
contains "$CREATE_ISSUE" '`follow-up` 系のラベルは付けない' "着手前起票は follow-up を付けない"

# ---- 4. out-of-scope-issue 固有 ------------------------------------------------
contains "$OUT_OF_SCOPE" '照合する候補は §3.2 で決めた type / priority / follow-up の 3 系統' "候補は type / priority / follow-up の 3 系統"

# ---- 5. 意図的な非対称の固定（アサイン） ----------------------------------------
# create-issue は着手前の起票ゲートなので同梱 Git Workflow に従い @me を付ける。
# out-of-scope-issue の起票は backlog 化であって着手ではないのでアサインしない。
# 「揃えよう」としてどちらかを崩す変更を検出する。
has_argument_line "$CREATE_ISSUE" "$ASSIGNEE_PATTERN" "着手前起票はアサインを既定にする（引数行として存在）"
lacks_argument_line "$OUT_OF_SCOPE" "$ASSIGNEE_PATTERN" "follow-up 起票はアサインを既定にしない"
contains "$CREATE_ISSUE" "この非対称は意図的で" "アサインの非対称が意図的だと本文に明記されている"
contains "$OUT_OF_SCOPE" "アサインについて本スキルは中立" "follow-up 側のアサイン中立方針が残っている"

# ---- 6. ラベル作成はしない（両スキル共通） --------------------------------------
# 起票ゲートが消費プロジェクトのラベル体系を増やすと分類が場当たりに膨らむ。
# `refine-issue` の `needs-spec`（`gh label create --force`）とは役割が違う。
# 検出器が空振りしていないことを、実際に作る refine-issue を対照にして確かめる。
has_argument_line "$REFINE_ISSUE" "$LABEL_CREATE_PATTERN" "自己検証: gh label create の実行行を検出できる（refine-issue が対照）"
lacks_argument_line "$CREATE_ISSUE" "$LABEL_CREATE_PATTERN" "create-issue はラベルを作成しない"
lacks_argument_line "$OUT_OF_SCOPE" "$LABEL_CREATE_PATTERN" "out-of-scope-issue はラベルを作成しない"

# ---- 7. 手順番号の整合 ----------------------------------------------------------
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


# ---- 10. create-issue 手順 4 の項目リスト ↔ refine-issue の派生対応表（Issue #591） ----
# PR #588 で create-issue 手順 4 を 6 → 7 項目にしたとき、その項目構成を写している
# refine-issue の記述が古いまま残り、当時の 76 suite のどれも検出しなかった
# （レビューで人手検出）。同型のドリフトは ACE-36-1 が既に記録した再発である。
#
# 対策は「共有」ではなく「照合」— 本 suite 冒頭の方針と同じ。refine-issue は
# create-issue 手順 4 の項目名を左列に持つ対応表を明示的に複製し、その複製が実体と
# 一致していることをここで機械照合する。
#
# 検査対象は**左列の集合と、その一意性だけ**。見ないものと、その理由:
#   - 右列の文言 … 右列は refine 側が「どう引き継いだか」を述べる表現であって、正規
#     ソース側の項目名の集合とは別物なので本検査の対象にならない。右列と refine 自身の
#     観点名の整合（右列だけが古くなる型）は別 Issue #736 で扱う
#   - 行順 … 対応は名前で取る。並びはドリフトではない
#   - refine 自身の観点リストの項目名 … refine 側の再編は refine の自由で、create 側の
#     項目増減で赤くしてはいけない（AC4）
# 期待値は両ファイルの実体から導出し、項目数はテスト側に置かない。

MAPPING_ANCHOR='#### `/create-issue` 手順 4 との対応'

# `### 4.` 節の `- [ ] **項目名**` を採る。フェンス内（改善案の例示）は除外する。
extract_create_check_items() {
  awk '
    { sub(/\r$/, "") }
    /^```/ { fence = 1 - fence; next }
    fence { next }
    /^### / { insec = ($0 ~ /^### 4\./) ? 1 : 0; next }
    insec && /^- \[ \] \*\*/ {
      s = $0
      sub(/^- \[ \] \*\*/, "", s)
      i = index(s, "**")
      if (i > 1) print substr(s, 1, i - 1)
    }
  '
}

# 対応表の左列を採る。アンカー見出しから次の見出しまでに限定するので、refine 自身の
# 6 観点チェックリスト（同じ `- [ ] **名前**` 形）は構造的に入り込まない。
extract_refine_mapping_keys() {
  awk -v anchor="$MAPPING_ANCHOR" '
    { sub(/\r$/, "") }
    index($0, anchor) == 1 { insec = 1; seen = 0; next }
    insec && /^#/ { insec = 0 }
    insec && /^\|/ {
      s = $0
      sub(/^\|[ \t]*/, "", s)
      i = index(s, "|")
      if (i == 0) next
      cell = substr(s, 1, i - 1)
      sub(/[ \t]+$/, "", cell)
      if (cell ~ /^:?-+:?$/) next   # 区切り行
      seen++
      if (seen == 1) next           # ヘッダ行
      if (cell != "") print cell
    }
  '
}

# 集合演算。`comm` + プロセス置換は `/dev/fd` の無い環境で $TMPDIR へ FIFO を作る。
# 本 suite は「一時ファイルを一切作らない」前提なので（比較に diff を使わないのと
# 同じ理由。上の compare_block を参照）、2 集合を区切り行で連結した 1 本の
# ストリームを awk で読む。区切りは検査対象の文書に現れない ASCII 文字列。
SET_SEP='__FF_SET_SEPARATOR__'
# $1 にあって $2 に無い行
set_difference() {
  printf '%s\n%s\n%s\n' "$2" "$SET_SEP" "$1" | awk -v sep="$SET_SEP" '
    $0 == sep { second = 1; next }
    !second { have[$0] = 1; next }
    $0 != "" && !($0 in have) { print }
  '
}
# $1 と $2 の両方にある行
set_intersection() {
  printf '%s\n%s\n%s\n' "$2" "$SET_SEP" "$1" | awk -v sep="$SET_SEP" '
    $0 == sep { second = 1; next }
    !second { have[$0] = 1; next }
    $0 != "" && ($0 in have) { print }
  '
}

# 2 つの本文（文字列）を受け、不一致の診断行を返す。一致なら無出力。
# 一時ファイルを作らないという本 suite の前提を守るため、入力はすべて文字列で渡す。

# 同一行が 2 回以上現れる項目を「名前 (N 回)」で返す。入力はソート済みを想定。
duplicate_entries() {
  printf '%s\n' "$1" | awk 'NF { c[$0]++ } END { for (k in c) if (c[k] > 1) print k " (" c[k] " 回)" }' | LC_ALL=C sort
}

mapping_diagnosis() {
  local items keys only_create only_refine dup_items dup_keys
  items="$(printf '%s\n' "$1" | extract_create_check_items | LC_ALL=C sort)"
  keys="$(printf '%s\n' "$2" | extract_refine_mapping_keys | LC_ALL=C sort)"
  # fail-closed: 抽出が 0 件になったら「差分なし」ではなく検査対象の消失として扱う。
  if [ -z "$items" ]; then
    printf '%s\n' "create-issue 手順 4 の粒度チェック項目を 1 件も抽出できない（見出し「### 4.」または「- [ ] **項目名**」の形が変わった）"
    return 0
  fi
  if [ -z "$keys" ]; then
    printf '%s\n' "refine-issue の対応表から左列を 1 件も抽出できない（見出し「${MAPPING_ANCHOR}」または表そのものが消えた）"
    return 0
  fi
  # 集合比較の前に一意性を見る。同じ項目名が 2 行あると集合としては一致したまま
  # なので、集合比較だけでは「項目 A を 2 回対応づけ、項目 B を落とした」形の
  # 片方（重複側）が素通りする。左列と create 側のそれぞれで独立に診断する。
  dup_items="$(duplicate_entries "$items")"
  dup_keys="$(duplicate_entries "$keys")"
  [ -z "$dup_items" ] || { printf '%s\n' "$dup_items" | sed 's/^/create-issue 手順 4 に重複する項目名: /' || true; }
  [ -z "$dup_keys" ]  || { printf '%s\n' "$dup_keys"  | sed 's/^/対応表の左列に重複する項目名: /' || true; }
  only_create="$(set_difference "$items" "$keys")"
  only_refine="$(set_difference "$keys" "$items")"
  [ -z "$only_create" ] || { printf '%s\n' "$only_create" | sed 's/^/対応表に無い create-issue の項目: /' || true; }
  [ -z "$only_refine" ] || { printf '%s\n' "$only_refine" | sed 's/^/create-issue に無い対応表の左列: /' || true; }
}

MAPPING_CASES=0
mapping_ok()  { MAPPING_CASES=$((MAPPING_CASES + 1)); ok  "$1"; }
mapping_bad() {
  MAPPING_CASES=$((MAPPING_CASES + 1)); bad "$1"
  [ -z "${2:-}" ] || { printf '%s\n' "$2" | sed 's/^/    | /' >&2 || true; }
}

CREATE_TEXT="$(cat "$CREATE_ISSUE")"
REFINE_TEXT="$(cat "$REFINE_ISSUE")"
FIRST_ITEM="$(printf '%s\n' "$CREATE_TEXT" | extract_create_check_items | awk 'NR == 1')"
LAST_ITEM="$(printf '%s\n' "$CREATE_TEXT" | extract_create_check_items | awk 'END { print }')"
NEW_ITEM="変異試験用の追加項目"
BOGUS_KEY="変異試験用の余分な左列"

# 10-1. 正: 実体同士が一致している（AC「両者一致なら pass」）
#
# 以降の緑 pin は「無出力であること」ではなく「この baseline から診断が増えも減りも
# しないこと」で判定する。実体を対照にしたまま無出力を要求すると、本物のドリフトが
# 起きた瞬間に緑 pin まで «過剰検出» と名乗って赤くなり、本当の原因（10-1）が
# ノイズに埋もれる。赤の変異試験は baseline に依存しない名指しで判定する。
BASELINE_DIAG="$(mapping_diagnosis "$CREATE_TEXT" "$REFINE_TEXT")"
mapping_diag="$BASELINE_DIAG"
if [ -z "$mapping_diag" ]; then
  mapping_ok "create-issue 手順 4 の項目集合と refine-issue の対応表の左列が一致"
else
  mapping_bad "create-issue 手順 4 の項目集合と refine-issue の対応表の左列が食い違う" "$mapping_diag"
fi

if [ -z "$FIRST_ITEM" ] || [ -z "$LAST_ITEM" ]; then
  echo "✗ 変異試験の素材（手順 4 の項目名）を実体から採れない。以降の検査は実行しない" >&2
  exit 1
fi

# 10-2. 変異: 対応表の左列を 1 件改名する
mut_rename="$(printf '%s\n' "$REFINE_TEXT" | awk -v old="| $FIRST_ITEM |" -v new="| ${FIRST_ITEM}-改名 |" '
  { if (index($0, old) == 1) $0 = new substr($0, length(old) + 1); print }')"
mapping_diag="$(mapping_diagnosis "$CREATE_TEXT" "$mut_rename")"
if [ "$mut_rename" = "$REFINE_TEXT" ]; then
  mapping_bad "変異（左列の改名）: 変異が当たっていない（対応表の行形が変わった疑い）"
elif [ -z "$mapping_diag" ]; then
  mapping_bad "変異（左列の改名）: 改名しても緑のまま（検出力なし）"
else
  case "$mapping_diag" in
    *"対応表に無い create-issue の項目: $FIRST_ITEM"*)
      mapping_ok "変異（左列の改名）: 赤になり、対応が失われた項目名を名指しする" ;;
    *)
      mapping_bad "変異（左列の改名）: 赤にはなるが項目名を名指ししない" "$mapping_diag" ;;
  esac
fi

# 10-3. 変異: 対応表から 1 行削除する（create 側の項目が未対応で残る形）
mut_drop="$(printf '%s\n' "$REFINE_TEXT" | awk -v old="| $FIRST_ITEM |" '{ if (index($0, old) == 1) next; print }')"
mapping_diag="$(mapping_diagnosis "$CREATE_TEXT" "$mut_drop")"
if [ "$mut_drop" = "$REFINE_TEXT" ]; then
  mapping_bad "変異（行の削除）: 変異が当たっていない"
else
  case "$mapping_diag" in
    *"対応表に無い create-issue の項目: $FIRST_ITEM"*)
      mapping_ok "変異（行の削除）: 赤になり、未対応になった項目名を名指しする" ;;
    *)
      mapping_bad "変異（行の削除）: 未対応の項目を名指ししない" "$mapping_diag" ;;
  esac
fi

# 10-4. 変異: create 側に無い左列を対応表へ足す（幽霊の項目を主張する形）
mut_extra="$(printf '%s\n' "$REFINE_TEXT" | awk -v old="| $FIRST_ITEM |" -v add="| $BOGUS_KEY | 観点「変異」 |" '
  { print; if (index($0, old) == 1) print add }')"
mapping_diag="$(mapping_diagnosis "$CREATE_TEXT" "$mut_extra")"
if [ "$mut_extra" = "$REFINE_TEXT" ]; then
  mapping_bad "変異（余分な左列）: 変異が当たっていない"
else
  case "$mapping_diag" in
    *"create-issue に無い対応表の左列: $BOGUS_KEY"*)
      mapping_ok "変異（余分な左列）: 赤になり、実体に無い左列を名指しする" ;;
    *)
      mapping_bad "変異（余分な左列）: 実体に無い左列を名指ししない" "$mapping_diag" ;;
  esac
fi

# 10-5. 変異: create 側に項目を足し、対応表は据え置く（PR #588 の退行そのもの）
mut_create_grow="$(printf '%s\n' "$CREATE_TEXT" | awk -v last="- [ ] **$LAST_ITEM**" -v add="- [ ] **$NEW_ITEM**: 変異試験" '
  { print; if (index($0, last) == 1) print add }')"
mapping_diag="$(mapping_diagnosis "$mut_create_grow" "$REFINE_TEXT")"
if [ "$mut_create_grow" = "$CREATE_TEXT" ]; then
  mapping_bad "変異（create 側の項目追加）: 変異が当たっていない"
else
  case "$mapping_diag" in
    *"対応表に無い create-issue の項目: $NEW_ITEM"*)
      mapping_ok "変異（create 側の項目追加・対応表据え置き）: 赤になり、追随漏れの項目名を名指しする" ;;
    *)
      mapping_bad "変異（create 側の項目追加・対応表据え置き）: PR #588 と同型の退行を検出しない" "$mapping_diag" ;;
  esac
fi

# 10-6. fail-closed: 対応表そのものが消える（検査対象の消失を緑と報告しない）
mut_no_table="$(printf '%s\n' "$REFINE_TEXT" | awk -v anchor="$MAPPING_ANCHOR" '
  index($0, anchor) == 1 { skipping = 1; next }
  skipping && /^#/ { skipping = 0 }
  skipping { next }
  { print }')"
mapping_diag="$(mapping_diagnosis "$CREATE_TEXT" "$mut_no_table")"
if [ "$mut_no_table" = "$REFINE_TEXT" ]; then
  mapping_bad "fail-closed（対応表の消失）: 変異が当たっていない"
else
  case "$mapping_diag" in
    *"refine-issue の対応表から左列を 1 件も抽出できない"*)
      mapping_ok "fail-closed（対応表の消失）: 抽出 0 件を差分なしと報告せず赤にする" ;;
    *)
      mapping_bad "fail-closed（対応表の消失）: 抽出 0 件が緑または別の理由で赤になっている" "$mapping_diag" ;;
  esac
fi

# 10-7. fail-closed: create 側の抽出が壊れる（見出しの改名）
mut_create_broken="$(printf '%s\n' "$CREATE_TEXT" | awk '{ if ($0 ~ /^### 4\./) sub(/^### 4\./, "### 手順4"); print }')"
mapping_diag="$(mapping_diagnosis "$mut_create_broken" "$REFINE_TEXT")"
if [ "$mut_create_broken" = "$CREATE_TEXT" ]; then
  mapping_bad "fail-closed（create 側の抽出破壊）: 変異が当たっていない"
else
  case "$mapping_diag" in
    *"create-issue 手順 4 の粒度チェック項目を 1 件も抽出できない"*)
      mapping_ok "fail-closed（create 側の抽出破壊）: 抽出 0 件を差分なしと報告せず赤にする" ;;
    *)
      mapping_bad "fail-closed（create 側の抽出破壊）: 抽出 0 件が緑または別の理由で赤になっている" "$mapping_diag" ;;
  esac
fi

# 10-8. 緑 pin: 装飾だけの変化（セルの余白・右列の文言）は赤にしない。
# 異常系だけで固めると「変化があれば理由を問わず赤」でも全部通る（ACE-725-1）。
mut_cosmetic="$(printf '%s\n' "$REFINE_TEXT" | awk -v anchor="$MAPPING_ANCHOR" '
  { sub(/\r$/, "") }
  index($0, anchor) == 1 { insec = 1; seen = 0; print; next }
  insec && /^#/ { insec = 0 }
  insec && /^\|/ {
    s = $0
    sub(/^\|[ \t]*/, "", s)
    i = index(s, "|")
    if (i > 0) {
      cell = substr(s, 1, i - 1)
      sub(/[ \t]+$/, "", cell)
      if (cell !~ /^:?-+:?$/) {
        seen++
        if (seen > 1) {
          rest = substr(s, i + 1)
          sub(/[ \t]*\|[ \t]*$/, "", rest)
          sub(/^[ \t]+/, "", rest)
          print "|   " cell "   |   " rest "（右列の文言を書き換えた）   |"
          next
        }
      }
    }
    print
    next
  }
  { print }')"
mapping_diag="$(mapping_diagnosis "$CREATE_TEXT" "$mut_cosmetic")"
if [ "$mut_cosmetic" = "$REFINE_TEXT" ]; then
  mapping_bad "緑 pin（装飾のみ）: 変異が当たっていない（緑が空振りで得られている）"
elif [ "$mapping_diag" = "$BASELINE_DIAG" ]; then
  mapping_ok "緑 pin（装飾のみ）: セルの余白と右列の文言を変えても判定が変わらない"
else
  mapping_bad "緑 pin（装飾のみ）: 左列が変わっていないのに判定が変わる（過剰検出）" "$mapping_diag"
fi

# 10-9. 緑 pin: 行順の入れ替えは赤にしない（対応は名前で取る、順序では取らない）
mut_reorder="$(printf '%s\n' "$REFINE_TEXT" | awk -v anchor="$MAPPING_ANCHOR" '
  function flush(   k) { for (k = n; k >= 1; k--) print rows[k]; n = 0 }
  { sub(/\r$/, "") }
  index($0, anchor) == 1 { insec = 1; seen = 0; n = 0; print; next }
  insec && /^#/ { if (n) flush(); insec = 0; print; next }
  insec && /^\|/ {
    s = $0
    sub(/^\|[ \t]*/, "", s)
    i = index(s, "|")
    if (i == 0) { print; next }
    cell = substr(s, 1, i - 1)
    sub(/[ \t]+$/, "", cell)
    if (cell ~ /^:?-+:?$/) { print; next }
    seen++
    if (seen == 1) { print; next }
    rows[++n] = $0
    next
  }
  insec && n > 0 { flush(); print; next }
  { print }
  END { if (n) flush() }')"
mapping_diag="$(mapping_diagnosis "$CREATE_TEXT" "$mut_reorder")"
if [ "$mut_reorder" = "$REFINE_TEXT" ]; then
  mapping_bad "緑 pin（行順の入れ替え）: 変異が当たっていない（緑が空振りで得られている）"
elif [ "$mapping_diag" = "$BASELINE_DIAG" ]; then
  mapping_ok "緑 pin（行順の入れ替え）: 行の並びを変えても判定が変わらない"
else
  mapping_bad "緑 pin（行順の入れ替え）: 順序に依存して判定が変わっている" "$mapping_diag"
fi

# 10-10. AC4 の緑 pin: create 側の項目数が変わっても、対応表が追随していれば緑。
# refine 自身の「6 観点」表記には一切触れずに成立することを同時に確かめる。
mut_refine_grow="$(printf '%s\n' "$REFINE_TEXT" | awk -v old="| $FIRST_ITEM |" -v add="| $NEW_ITEM | 非継承 |" '
  { print; if (index($0, old) == 1) print add }')"
mapping_diag="$(mapping_diagnosis "$mut_create_grow" "$mut_refine_grow")"
if [ "$mut_refine_grow" = "$REFINE_TEXT" ] || [ "$mut_create_grow" = "$CREATE_TEXT" ]; then
  mapping_bad "緑 pin（項目追加に対応表が追随）: 変異が当たっていない"
elif [ "$mapping_diag" = "$BASELINE_DIAG" ]; then
  mapping_ok "緑 pin（項目追加に対応表が追随）: 項目数が増えても両者が揃っていれば判定が変わらない"
else
  mapping_bad "緑 pin（項目追加に対応表が追随）: 揃えて足したのに判定が変わる" "$mapping_diag"
fi

# 10-11. AC4: 上の緑は refine 自身の観点リストを 1 件も変えずに得られている。
#
# 「6 観点」というリテラルで見てはいけない。(a) 本 suite が自ら禁じた項目数の
# ハードコードになり、(b) 上の変異は対応表へ 1 行足すだけなのでその文字列に構造上
# 触れ得ず、検査が常に真を返す（発火し得ない偽の変異検査）。refine 自身の観点
# リストを実体から抽出し、変異の前後で不変であることを見る。
own_before="$(printf '%s\n' "$REFINE_TEXT" | extract_create_check_items)"
own_after="$(printf '%s\n' "$mut_refine_grow" | extract_create_check_items)"
if [ -z "$own_before" ]; then
  mapping_bad "AC4: refine 自身の観点リストを実体から抽出できない（不変の主張ができない）"
elif [ "$own_before" = "$own_after" ]; then
  mapping_ok "AC4: 上の緑は refine 自身の観点リスト（実体抽出）を 1 件も変えずに成立している"
else
  mapping_bad "AC4: refine 自身の観点リストが変異で変化しており、緑 pin の主張が成立しない"
fi

# 10-12. AC4: 対応表の左列に refine 固有の観点名が混ざっていない（検査対象の分離）。
# refine 固有 = refine 手順 4 の項目 − create 手順 4 の項目。実体から導出する。
refine_own_items="$(printf '%s\n' "$REFINE_TEXT" | extract_create_check_items | LC_ALL=C sort)"
create_items_sorted="$(printf '%s\n' "$CREATE_TEXT" | extract_create_check_items | LC_ALL=C sort)"
refine_only="$(set_difference "$refine_own_items" "$create_items_sorted")"
mapping_keys_sorted="$(printf '%s\n' "$REFINE_TEXT" | extract_refine_mapping_keys | LC_ALL=C sort)"
leaked="$(set_intersection "$refine_only" "$mapping_keys_sorted")"
# 交差が空でも、片側が空なら「混ざっていない」は主張できない（本ケース自身が
# 「検査対象の消失を緑と報告しない」を主題にしているので、両側の非空を要求する）。
if [ -z "$refine_only" ] || [ -z "$mapping_keys_sorted" ]; then
  mapping_bad "AC4: refine 固有の観点または対応表の左列を実体から導出できない（対照が空で分離を主張できない）"
elif [ -z "$leaked" ]; then
  mapping_ok "AC4: refine 固有の観点は対応表の左列に混ざらない（refine 自身の観点リストは検査対象外）"
else
  mapping_bad "AC4: refine 固有の観点が対応表の左列に混ざっている" "$leaked"
fi

# 10-13. 10-12 の negative control。左列を 1 件 refine 固有の観点名へ差し替えると
# 混入検出が赤くなること（10-12 が常に真を返していないことの実測）。
refine_only_first="$(printf '%s\n' "$refine_only" | awk 'NR == 1')"
mut_leak="$(printf '%s\n' "$REFINE_TEXT" | awk -v old="| $FIRST_ITEM |" -v new="| $refine_only_first |" '
  { if (index($0, old) == 1) $0 = new substr($0, length(old) + 1); print }')"
leak_keys="$(printf '%s\n' "$mut_leak" | extract_refine_mapping_keys | LC_ALL=C sort)"
leaked_mut="$(set_intersection "$refine_only" "$leak_keys")"
if [ -z "$refine_only_first" ] || [ "$mut_leak" = "$REFINE_TEXT" ]; then
  mapping_bad "negative control（refine 固有の観点を左列へ混入）: 変異が当たっていない"
elif [ -n "$leaked_mut" ]; then
  mapping_ok "negative control（refine 固有の観点を左列へ混入）: 混入検出が赤になる"
else
  mapping_bad "negative control（refine 固有の観点を左列へ混入）: 混入しても検出しない（10-12 が常に真）"
fi

# 10-14. 一意性の緑 pin: 実体には重複した項目名が無い。
dup_live="$(duplicate_entries "$create_items_sorted")
$(duplicate_entries "$mapping_keys_sorted")"
if [ -z "$(printf '%s' "$dup_live" | tr -d '[:space:]')" ]; then
  mapping_ok "一意性: create-issue の項目名にも対応表の左列にも重複が無い"
else
  mapping_bad "一意性: 重複した項目名がある" "$dup_live"
fi

# 10-15. 変異: 対応表の左列を 1 件重複させる。集合としては一致したままなので、
# 一意性の診断が無いとこの形は素通りする（「項目 A を 2 回対応づけ、B を落とす」
# 型の片割れ）。集合差の診断が出ないことも同時に固定する。
mut_dup="$(printf '%s\n' "$REFINE_TEXT" | awk -v old="| $FIRST_ITEM |" '
  { print; if (index($0, old) == 1) print $0 }')"
# 判定は baseline との差分で見る（他の緑 pin と同じ理由。実体が既に食い違っている
# ときに、その既存の診断行を「重複が集合差として出た」と誤読して赤くしないため）。
mapping_diag="$(mapping_diagnosis "$CREATE_TEXT" "$mut_dup")"
mapping_added="$(set_difference "$mapping_diag" "$BASELINE_DIAG")"
if [ "$mut_dup" = "$REFINE_TEXT" ]; then
  mapping_bad "変異（左列の重複）: 変異が当たっていない"
else
  case "$mapping_added" in
    *"対応表に無い create-issue の項目"*|*"create-issue に無い対応表の左列"*)
      mapping_bad "変異（左列の重複）: 集合差として報告されている（一意性の検査になっていない）" "$mapping_added" ;;
    *"対応表の左列に重複する項目名: $FIRST_ITEM (2 回)"*)
      mapping_ok "変異（左列の重複）: 集合は一致したままでも一意性だけで赤になり、重複した項目名を名指しする" ;;
    *)
      mapping_bad "変異（左列の重複）: 重複を検出しない（集合比較だけでは素通りする形）" "$mapping_added" ;;
  esac
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ issue-label-contract verify: $FAIL 件失敗 / $PASS 件成功" >&2
  exit 1
fi
echo "✓ issue-label-contract verify: 全 $PASS 件 pass"
