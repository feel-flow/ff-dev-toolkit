# shellcheck shell=bash
#
# base 先行ガードの fetch 失敗が原因を捨てない形であることを、3 箇所すべてで固定する。
#
# 対象は 3 スキルの 3 フェンス（retrospective 1 / ace-curate 1 / ace-refine 1。ace-refine の R3 開始前
# ガードは承認前の照合フェンスを再実行する形に畳んだ。retrospective と ace-curate のフェンスは
# 条件付き reference — references/ledger.md / references/curate.md — にある）。どれも同じ
# 停止条件・同じ復帰手順を案内するので、片側だけが原因を落とす形へ戻ると「同じ経路なのに
# 停止の報告だけ内容が違う」非対称が復活する。1 箇所だけ旧形（`>/dev/null 2>&1` で stderr を
# 捨てる）へ戻す変異でここが赤くなる。
#
# 検査は「フェンスから抽出した fetch 分岐が正規形と一致すること」。停止メッセージの理由文は
# スキルごとに違って良い（確定する値が version / 判定 / 記録内容と異なる）ので、`（…）` の
# 中身だけを `<REASON>` へ正規化してから突き合わせる。正規形は
# fixtures/base-guard-fetch-normal.txt が持つ（検査側に二重定義を置かない）。
#
# 呼び出し元（verify.sh）の ok / bad / PASS / FAIL を使う。単体では実行しない。

BASE_GUARD_NORMAL="$(cat "$SCRIPT_DIR/fixtures/base-guard-fetch-normal.txt")"$'\n'
BASE_GUARD_EXPECTED_FENCES=3
base_guard_found=0

# $1=SKILL.md の絶対パス / $2=報告用のスキル名
check_base_guard_fetch() {
  local file="$1" skill="$2"
  local -a lines
  local i j n ln block occurrence=0

  if [[ ! -f "$file" ]]; then
    bad "${skill}: SKILL.md が見つかりません（base 先行ガードを 1 件も検査していません）"
    return
  fi

  # bash 3.2（macOS 既定）には mapfile が無い。読み込みは while read で行う。
  lines=()
  while IFS= read -r ln || [[ -n "$ln" ]]; do lines+=("$ln"); done < "$file"
  n=${#lines[@]}
  for ((i = 0; i < n; i++)); do
    [[ "${lines[i]}" == 'if ! '*'git fetch origin "+refs/heads/'* ]] || continue
    occurrence=$((occurrence + 1))
    base_guard_found=$((base_guard_found + 1))
    block=""
    for ((j = i; j < n; j++)); do
      ln="${lines[j]}"
      # 理由文はスキルごとに異なる。`（…）` の中身だけを伏せて形だけを比べる。
      if [[ "$ln" == '  echo "origin/${default_branch} を取得できません（'* ]]; then
        ln='  echo "origin/${default_branch} を取得できません（<REASON>）'"${ln#*）}"
      fi
      block+="$ln"$'\n'
      if [[ "${lines[j]}" == "fi" ]]; then break; fi
    done
    if [[ "$block" == "$BASE_GUARD_NORMAL" ]]; then
      ok "${skill} のフェンス ${occurrence}: fetch 失敗が git の原因を停止メッセージへ載せる"
    else
      bad "${skill} のフェンス ${occurrence}: fetch 分岐が正規形と一致しません（stderr を捨てる旧形へ戻っている可能性）"
      printf '    実際:\n%s\n' "$block" >&2
    fi
    i=$j
  done
}

echo "== base 先行ガードの fetch 失敗診断（3 箇所の正規形） =="
check_base_guard_fetch "$PLUGIN_ROOT/skills/retrospective/references/ledger.md" "retrospective"
check_base_guard_fetch "$ACE_CURATE" "ace-curate"
check_base_guard_fetch "$ACE_REFINE" "ace-refine"

if [[ "$base_guard_found" -eq "$BASE_GUARD_EXPECTED_FENCES" ]]; then
  ok "base 先行ガードのフェンスが ${BASE_GUARD_EXPECTED_FENCES} 箇所（増減時はこの case の期待値も更新すること）"
else
  bad "base 先行ガードのフェンスが ${BASE_GUARD_EXPECTED_FENCES} 箇所（実際: ${base_guard_found} 箇所 — フェンスの削除、または追加時の期待値未更新）"
fi

echo "== base 先行ガードの fetch 失敗診断（正規形の実行時の挙動） =="
#
# 上の一致検査はフェンスの文字列しか見ない。原因が実際に停止メッセージへ渡るか / 資格情報が
# 伏せられるか / 成功時に無出力かは、正規形をそのまま走らせて固定する。ネットワークへは出ない
# （127.0.0.1:1 は接続拒否で即座に失敗する。認証プロンプトは GIT_TERMINAL_PROMPT=0 で抑止）。

base_guard_script="$TMP/base-guard-fence.sh"
{
  echo 'default_branch=main'
  printf '%s' "${BASE_GUARD_NORMAL//<REASON>/接続・認証・remote 設定のいずれか}"
} > "$base_guard_script"

# 資格情報付き URL を stderr へ出す git。実 git は版・経路によっては URL の userinfo を自分で
# 落とすため、伏せ字そのものを測るにはこの stub が要る（伏せ字は「落とさない版・経路」に備えた
# 防御なので、実 git が落とす版で測ると検査が素通りする）。
base_guard_stub_bin="$TMP/base-guard-bin"
mkdir -p "$base_guard_stub_bin"
cat > "$base_guard_stub_bin/git" <<'STUB'
#!/usr/bin/env bash
printf "fatal: unable to access '%s': Failed to connect\n" "${FF_BASE_GUARD_STUB_URL}" >&2
exit 128
STUB
chmod +x "$base_guard_stub_bin/git"

# $1=origin へ設定する URL / $2 に stub を渡すと上の stub git で走らせる。
# 結果は base_guard_rc / base_guard_out / base_guard_err へ置く。
run_base_guard_fence() {
  local url="$1" mode="${2-}" repo="$TMP/base-guard-repo"
  rm -rf "$repo"
  ff_git_fixture_init "$repo" || return 1
  git -C "$repo" remote add origin "$url"
  set +e
  (
    cd "$repo" || exit 1
    export GIT_TERMINAL_PROMPT=0
    if [[ "$mode" == "stub" ]]; then
      export PATH="$base_guard_stub_bin:$PATH" FF_BASE_GUARD_STUB_URL="$url"
    fi
    bash "$base_guard_script"
  ) > "$TMP/base-guard.out" 2> "$TMP/base-guard.err"
  base_guard_rc=$?
  set -e
  base_guard_out="$(cat "$TMP/base-guard.out")"
  base_guard_err="$(cat "$TMP/base-guard.err")"
}

# (a) 失敗系: git の原因が停止メッセージへ載る。`2>&1 >/dev/null` を旧形 `>/dev/null 2>&1` へ
#     戻すと _fetch_err が空になり、原因の代わりに既定文が出てここが赤くなる。
run_base_guard_fence 'https://127.0.0.1:1/nope.git'
if [[ "$base_guard_rc" -eq 1 ]]; then ok "失敗系: フェンスが rc=1 で停止"; else bad "失敗系: rc=1 で停止しない（実際: ${base_guard_rc}）"; fi
if [[ "$base_guard_err" == *"取得できません"* ]]; then ok "失敗系: 停止メッセージを stderr へ出す"; else bad "失敗系: 停止メッセージが stderr に無い"; fi
if [[ "$base_guard_err" == *"127.0.0.1"* ]]; then ok "失敗系: git の原因が停止メッセージへ載る"; else bad "失敗系: git の原因が落ちている（stderr を捨てる旧形の可能性）"; printf '    実際: %s\n' "$base_guard_err" >&2; fi
if [[ "$base_guard_err" != *"原因は出力されませんでした"* ]]; then ok "失敗系: 原因が空の既定文へ落ちない"; else bad "失敗系: 原因が空で既定文へ落ちた"; fi

# (b) 伏せ字: userinfo に生の `@` を含む資格情報でも残余を出さない。sed 式を旧形
#     `[^/@[:space:]]+@` へ戻すと最初の `@` までしか伏せず、後半（SECRETTAIL）が残って赤くなる。
run_base_guard_fence 'https://alice:SECRET_TOKEN@127.0.0.1:1/nope.git' stub
if [[ "$base_guard_err" == *"://***@127.0.0.1"* ]]; then ok "伏せ字: 単純な userinfo を伏せる"; else bad "伏せ字: 単純な userinfo が伏せられない"; printf '    実際: %s\n' "$base_guard_err" >&2; fi
if [[ "$base_guard_err" != *"SECRET_TOKEN"* ]]; then ok "伏せ字: 資格情報を停止メッセージへ出さない"; else bad "伏せ字: 資格情報が停止メッセージへ漏れる"; fi

run_base_guard_fence 'https://alice:p@ss-SECRETTAIL@127.0.0.1:1/nope.git' stub
if [[ "$base_guard_err" == *"://***@127.0.0.1"* ]]; then ok "伏せ字: userinfo 内の生 @ を跨いで最後の @ まで伏せる"; else bad "伏せ字: 生 @ を含む userinfo で host 直前まで伏せられない"; printf '    実際: %s\n' "$base_guard_err" >&2; fi
if [[ "$base_guard_err" != *"SECRETTAIL"* ]]; then ok "伏せ字: 生 @ の後半が残らない"; else bad "伏せ字: 生 @ の後半が残る（最初の @ までしか伏せない旧式の可能性）"; printf '    実際: %s\n' "$base_guard_err" >&2; fi

# (c) 成功系: 取得できたときは何も出さない（stdout へ紛れ込ませない / 警告を垂れ流さない）。
base_guard_seed="$TMP/base-guard-seed"
base_guard_bare="$TMP/base-guard-origin.git"
rm -rf "$base_guard_seed" "$base_guard_bare"
ff_git_fixture_init "$base_guard_seed"
printf '%s\n' 'seed' > "$base_guard_seed/README.md"
git -C "$base_guard_seed" add -A && git -C "$base_guard_seed" commit -qm seed
git -C "$base_guard_seed" branch -M main
git clone -q --bare "$base_guard_seed" "$base_guard_bare"
run_base_guard_fence "$base_guard_bare"
if [[ "$base_guard_rc" -eq 0 ]]; then ok "成功系: 取得できたら rc=0 で継続"; else bad "成功系: rc=0 で継続しない（実際: ${base_guard_rc}）"; printf '    実際: %s\n' "$base_guard_err" >&2; fi
if [[ -z "$base_guard_out" && -z "$base_guard_err" ]]; then ok "成功系: stdout / stderr とも無出力"; else bad "成功系: 出力が漏れる"; printf '    stdout: %s\n    stderr: %s\n' "$base_guard_out" "$base_guard_err" >&2; fi
