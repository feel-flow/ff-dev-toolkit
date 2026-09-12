#!/usr/bin/env bash
# リポジトリ正本 docs/04-quality/TESTING.md に掛かる docs-gates 側の検出器を、隔離した
# 偽リポジトリ root で実測する層。verify.sh から source し run_repo_testing_gate_cases で実行する。
#
# なぜ必要か: docs-gates は「正本 TESTING.md に規定が在ること」を検査するが、その検査自体が
# docs-gates/verify.sh から消えても誰も気付かない（静的 suite は自分の不在を測れない）。
# 本層は正本を変異させて **docs-gates が赤になること** を要求するので、docs-gates 側の
# 検出ブロックが消えたり skip へ退行したりすると本 suite が赤になる。
#
# 差し替え口の作り方: docs-gates の REPO_TESTING は $PLUGIN_ROOT/../../docs/04-quality/TESTING.md
# 固定で、環境変数の口が無い。そこで偽 root の下に plugin root を組み直し、正本 docs/ だけを
# 複製して変異させる。実リポジトリの正本には一切触れない。

# 偽リポジトリ root を組む。docs-gates が repo root から読むのは docs/ と AGENTS.md、
# それに plugins/ff-dev-toolkit だけ（AGENTS.md の参照先も plugins/ 配下を指す）。
#
# 実測した 2 つの落とし穴（どちらも「偽 root を組んだのに実物が読まれて全ケースが緑」になる）:
#   1. plugin root 自体を実 plugin root への symlink にしない。docs-gates の REPO_TESTING は
#      `"$PLUGIN_ROOT/../../docs/..."` の**文字列連結**で、`..` を解決するのはカーネル = 物理解決
#      （bash の `cd` の論理解決とは別）。plugin root が symlink だと `..` が実リポジトリ側へ抜け、
#      変異させた偽の正本ではなく実物が読まれる。
#   2. 走査対象のディレクトリを symlink で借りない。BSD grep の `-R` は末尾スラッシュの無い
#      symlink 引数を辿らず、ヒット 0 件を返す（`$DOCS` = `$PLUGIN_ROOT/docs-template`）。
# そこで plugin root とその配下は実体で複製し、走査されない mcp/（node_modules 込みで 109MB）
# だけを symlink で借りる。
_repo_testing_build_fake_root() {
  local case_root="$1" real_repo_root="$2" entry name

  mkdir -p "$case_root/plugins/ff-dev-toolkit"
  for entry in "$PLUGIN_ROOT"/* "$PLUGIN_ROOT"/.[!.]*; do
    [ -e "$entry" ] || continue
    name="${entry##*/}"
    case "$name" in
      mcp) ln -s "$entry" "$case_root/plugins/ff-dev-toolkit/$name" ;;
      *)   cp -R "$entry" "$case_root/plugins/ff-dev-toolkit/$name" ;;
    esac
  done
  cp -R "$real_repo_root/docs" "$case_root/docs"
  cp "$real_repo_root/AGENTS.md" "$case_root/AGENTS.md"
}

# $1 変異名 / $2 ラベル / $3 期待する検出メッセージ（空なら「変異なしで緑」を期待する control）
run_repo_testing_gate_mutation() {
  local mutation="$1" label="$2" expected="$3"
  local case_root log testing rc=0

  case_root="$TMP_ROOT/repo-testing-${mutation}"
  log="$TMP_ROOT/repo-testing-${mutation}.log"
  mkdir -p "$case_root"
  _repo_testing_build_fake_root "$case_root" "$REPO_TESTING_REAL_ROOT"
  testing="$case_root/docs/04-quality/TESTING.md"

  # 変異は「要求 1 点につき 1 つ」。bullet 行を 1 本だけ落とす / 見出しを 1 つだけ改名する。
  case "$mutation" in
    control) : ;;
    drop-granularity)
      _repo_testing_drop_bullet "$testing" '変異は検査 1 つにつき 1 つの粒度で並べる' ;;
    drop-one-command)
      _repo_testing_drop_bullet "$testing" '退避 → 変異 → suite 実行 → 復元を 1 コマンドにまとめる' ;;
    drop-todo)
      _repo_testing_drop_bullet "$testing" '赤転しなかった変異は、そのまま検査追加の TODO にする' ;;
    drop-writeback)
      _repo_testing_drop_bullet "$testing" '結果は当該 suite 自身の `verify.sh` ヘッダの「変異検出:」節へ書き戻す' ;;
    rename-heading)
      _repo_testing_rewrite "$testing" '
        $0 == "### 新規検査を書いた直後の変異注入バッテリー" { print "### 変異注入のやり方"; next }
        { print }
      '
      ;;
    missing-testing)
      # 正本のファイル名が変わった状況。`-f` だけで括られた検査は丸ごと skip して緑になる。
      mv "$testing" "$case_root/docs/04-quality/TESTING-renamed.md"
      ;;
    *)
      bad "未知の repo TESTING gate mutation: $mutation"
      return 0
      ;;
  esac

  bash "$case_root/plugins/ff-dev-toolkit/tests/docs-gates/verify.sh" >"$log" 2>&1 || rc=$?

  if [ -z "$expected" ]; then
    if [ "$rc" -eq 0 ]; then
      ok "$label"
    else
      bad "$label — 無変異の偽 root を docs-gates が拒否 (rc=${rc})"
      sed -n '1,160p' "$log" >&2 || true
    fi
    return 0
  fi

  if [ "$rc" -ne 0 ] && grep -qF "$expected" "$log"; then
    ok "$label"
  else
    bad "$label — 期待した検出器で拒否されない (rc=${rc}, expected=${expected})"
    sed -n '1,160p' "$log" >&2 || true
  fi
}

# 指定した固有語を含む bullet 行を 1 本だけ落とす（他の要求は残す）。
# 落ちなかった場合は「変異が当たっていないのに緑」を読む事故になるため fail-closed。
_repo_testing_drop_bullet() {
  local file="$1" needle="$2" before after
  before="$(grep -cF "$needle" "$file" || true)"
  if [ "$before" -ne 1 ]; then
    bad "変異の前提が崩れています: '${needle}' が ${before} 行（期待 1 行）: $file"
    return 0
  fi
  grep -vF "$needle" "$file" >"$file.tmp"
  mv "$file.tmp" "$file"
  after="$(grep -cF "$needle" "$file" || true)"
  [ "$after" -eq 0 ] || bad "変異が適用されていません: '${needle}' が残存: $file"
}

_repo_testing_rewrite() {
  local file="$1" program="$2"
  awk "$program" "$file" >"$file.tmp"
  mv "$file.tmp" "$file"
}

run_repo_testing_gate_cases() {
  REPO_TESTING_REAL_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

  echo
  echo "== リポジトリ正本 TESTING.md ゲートの mutation 検査 =="
  if [ ! -f "$REPO_TESTING_REAL_ROOT/docs/04-quality/TESTING.md" ]; then
    ok "リポジトリ正本 TESTING.md ゲートの mutation 検査は適用外（正本 docs/ を持たない checkout。公開ミラー等）"
    return 0
  fi

  run_repo_testing_gate_mutation control \
    "positive control: 無変異の偽リポジトリ root は docs-gates を通過" \
    ""
  run_repo_testing_gate_mutation drop-granularity \
    "変異の粒度（検査 1 つにつき 1 つ）の要求が消える退行を拒否する" \
    "「変異は検査 1 つにつき 1 つの粒度で並べる」を述べた bullet 行がありません"
  run_repo_testing_gate_mutation drop-one-command \
    "退避 → 変異 → suite 実行 → 復元の一体化の要求が消える退行を拒否する" \
    "「退避 → 変異 → suite 実行 → 復元を 1 コマンドにまとめる」を述べた bullet 行がありません"
  run_repo_testing_gate_mutation drop-todo \
    "赤転しなかった変異を TODO にする要求が消える退行を拒否する" \
    "「赤転しなかった変異は検査追加の TODO にする」を述べた bullet 行がありません"
  run_repo_testing_gate_mutation drop-writeback \
    "verify.sh ヘッダ「変異検出:」節への書き戻しの要求が消える退行を拒否する" \
    "「結果を当該 suite の verify.sh ヘッダ「変異検出:」節へ書き戻す」を述べた bullet 行がありません"
  run_repo_testing_gate_mutation rename-heading \
    "節の改名で検査が空振りする退行を拒否する" \
    "「新規検査を書いた直後の変異注入バッテリー」節が見つかりません"
  run_repo_testing_gate_mutation missing-testing \
    "正本 TESTING.md の不在（改名）で検査群が丸ごと skip される fail-open を拒否する" \
    "リポジトリ正本が見つかりません"
}
