#!/usr/bin/env bash
#
# review-wrapper-shim suite の検査ファイル（verify.sh から source される。単独実行不可）。
# 範囲: 旧観点名の互換（写像表 6 件の逐一検査・通知先・レジストリ整合）、env 経由の観点リスト、pnpm の `--` 透過、`--opt=value` 形式、--help の出力、配置の原子性（構造固定）。
# 依存: run_shim / run_isolated_shim と install-cases.sh の ${FAKE} / ${PLACED}。
# source 順は verify.sh の一覧が正本。fixture・関数・変数は同一プロセスで共有され、
# 後続ファイルは先行ファイルが作った fixture を参照するので、順序を入れ替えない。

echo "-- 旧観点名の互換 --"

run_shim --reviewers code-reviewer,silent-failure-hunter,type-design-analyzer
if argv_has_seq "--perspective" "code-review" \
   && argv_has_seq "--perspective" "error-handler-hunt" \
   && argv_has_seq "--perspective" "type-design-analysis"; then
  ok "旧観点名が現行の perspective 名へ写される"
else
  bad "旧観点名が写されていない（対応表を示しながら実際には拒否される形になる）"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi
if grep -q "旧観点名" "$WORK/out.log"; then
  ok "読み替えたことを通知する（黙って別の観点で走らない）"
else
  bad "読み替えを黙って行っている"
fi

# 写像表の 6 件を**1 件ずつ**検査する。まとめて 3 件だけ渡す上の検査は、写像表から
# 残り 3 件を削っても緑のまま通る（実測: comment-analyzer / pr-test-analyzer /
# code-simplifier はテストが 1 件も触れていなかった）。6 観点を使う消費リポジトリの
# 移行はこの 3 件に依存するので、削除・打ち間違いが即赤くなる形にする。
ALIAS_ITERATIONS=0
while IFS='|' read -r _old _new; do
  [ -n "$_old" ] || continue
  run_shim --reviewers "$_old"
  if [ "$RUN_RC" -ne 0 ]; then
    bad "旧観点名 '${_old}' で非 0 になった (rc=$RUN_RC)"
    sed 's/^/    | /' "$WORK/out.log" >&2
  elif argv_has_seq "--perspective" "$_new"; then
    ok "旧観点名 '${_old}' → '${_new}' が写される"
  else
    bad "旧観点名 '${_old}' が '${_new}' へ写されていない"
    sed 's/^/    | /' "$WORK/argv.log" >&2
  fi
  ALIAS_ITERATIONS=$((ALIAS_ITERATIONS + 1))
done <<'ALIASES'
code-reviewer|code-review
silent-failure-hunter|error-handler-hunt
type-design-analyzer|type-design-analysis
comment-analyzer|comment-analysis
pr-test-analyzer|test-analysis
code-simplifier|code-simplification
ALIASES

# ループが途中で終わっても PASS が減るだけで FAIL は 0 のまま — 「全 N 件 pass」と
# 緑で表示される（このスイートが塞いでいる fail-open を、検査側で再現してしまう形）。
# 現実的な中断経路は stdin の食い合いで、まさにこのスイートが存在する理由。
# run_shim 側で </dev/null を閉じたうえで、回った件数そのものを固定する。
if [ "$ALIAS_ITERATIONS" -eq 6 ]; then
  ok "写像表の 6 件すべてを回した（件数ガード）"
else
  bad "写像の検査が ${ALIAS_ITERATIONS} 件しか回っていない（6 件のはず）"
fi

# 現行の perspective 名はそのまま通ること（写像表が現行名まで書き換えないこと）
run_shim --reviewers comment-analysis,test-analysis,code-simplification
if argv_has_seq "--perspective" "comment-analysis" \
   && argv_has_seq "--perspective" "test-analysis" \
   && argv_has_seq "--perspective" "code-simplification"; then
  ok "現行の perspective 名はそのまま委譲される"
else
  bad "現行の perspective 名が書き換えられている"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# 通知は stderr へ出すこと。pre-commit や npm script で stdout だけ捨てる構成でも
# 「読み替えが起きた」ことが残る必要がある。
run_shim CODEX_MODEL=some-model
if grep -q "MULTI_AGENT_MODEL_CODEX_CLI" "$WORK/err.log"; then
  ok "写像の通知が stderr へ出る"
else
  bad "写像の通知が stderr に無い（stdout を捨てる構成で通知が消える）"
  sed 's/^/    | /' "$WORK/stdout.log" >&2
fi

# 委譲先が実際に読む env 名は、レジストリ（get_cli_model_env_vars）が宣言している。
# シムはその名前を**文字列として持つ 4 つ目のコピー**なので、レジストリ側で改名すると
# シムだけが古い名前を export し、全レビューが黙って既定モデルで走る（ACE-70-2 の形）。
# 名前が食い違ったら赤くする。
# 抽出は関数本体へ限定する。`codex-cli)   echo "..."` は multi-agent.sh に 8 行あり、
# ファイル全体を舐めると別の case（CLI 名や adapter パス）を拾う。実際、初版は
# `echo "codex"` を拾い、シムに "codex" が含まれるので**素通しで緑**になっていた
# ——この検査自身が fail-open だった。
REGISTERED="$(awk '/^get_cli_model_env_vars\(\)/ { inf = 1 }
                   inf && /codex-cli\)/ { sub(/.*echo "/, ""); sub(/".*/, ""); print; exit }' \
  "$PLUGIN_ROOT/scripts/multi-agent.sh")"
# 抽出が壊れたことを「一致した」と読まないよう、形も確かめる。
case "$REGISTERED" in
  *MULTI_AGENT_*) ;;
  *) REGISTERED="" ;;
esac
if [ -z "$REGISTERED" ]; then
  bad "レジストリから codex-cli のモデル env 名を取得できなかった（この検査が成立していない）"
else
  _missing=""
  for _v in $REGISTERED; do
    grep -q "$_v" "$SHIM" || _missing="${_missing} ${_v}"
  done
  if [ -z "$_missing" ]; then
    ok "シムが参照する env 名がレジストリの宣言（${REGISTERED}）と一致する"
  else
    bad "レジストリが宣言する env 名をシムが参照していない:${_missing}"
  fi
fi

# 写像経路で委譲先を実際に起動すること。env だけを書いて exec を外す変異も落とす。
run_shim CODEX_REASONING_EFFORT=high
if [ -s "$WORK/argv.log" ] && env_log_has "MULTI_AGENT_CODEX_REASONING_EFFORT=high"; then
  ok "CODEX_REASONING_EFFORT の写像後に委譲先を起動する"
else
  bad "CODEX_REASONING_EFFORT の写像後に委譲が成立していない"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# モデルとプロファイルはアダプタ側で排他。プロファイルへ移行済みの環境に旧
# CODEX_MODEL が残っていると、シムがモデルを写した結果アダプタが非 0 で落ちる。
# **最も正しく移行した人だけが壊れる**形なので、プロファイルも「新しい設定」として扱う。
run_shim CODEX_MODEL=old-model MULTI_AGENT_CODEX_PROFILE=review
if env_log_has "MULTI_AGENT_MODEL_CODEX_CLI=old-model"; then
  bad "プロファイル設定済みなのに CODEX_MODEL を写した（アダプタの排他検査で落ちる）"
  sed 's/^/    | /' "$WORK/env.log" >&2
else
  ok "MULTI_AGENT_CODEX_PROFILE 設定時は CODEX_MODEL を写さない"
fi
if grep -q "MULTI_AGENT_CODEX_PROFILE" "$WORK/err.log"; then
  ok "無視した理由（プロファイルが優先）を通知する"
else
  bad "プロファイル優先で無視したことが通知されない"
fi

# env 経由の不正なリスト。コマンドライン側 (--reviewers) だけ検証して env を素通しすると、
# 既定の観点セットが黙って走って課金される。
for _bad in "" "code-review," ",code-review" "code-review,,test-analysis"; do
  run_shim "CODEX_DEFAULT_REVIEWERS=${_bad}"
  if [ "$RUN_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ]; then
    ok "CODEX_DEFAULT_REVIEWERS='${_bad}' を拒否し、委譲しない"
  else
    bad "CODEX_DEFAULT_REVIEWERS='${_bad}' が rc=$RUN_RC で通った（既定の観点が黙って走る）"
    sed 's/^/    | /' "$WORK/out.log" >&2
  fi
done
if grep -q "CODEX_DEFAULT_REVIEWERS" "$WORK/err.log"; then
  ok "拒否メッセージが env 名を名指しする（どちらの入口が不正か分かる）"
else
  bad "拒否メッセージが env 名を名指ししていない"
fi

# `a, b, c` 形式。除去しないと 2 件目以降が写像表を通らず、**通知も出ないまま**
# 存在しない観点として委譲され、オーケストレータ側で全滅する。
run_shim "CODEX_DEFAULT_REVIEWERS=code-reviewer, comment-analyzer"
if argv_has_seq "--perspective" "code-review" \
   && argv_has_seq "--perspective" "comment-analysis"; then
  ok "空白入りのリストでも全要素が写像される"
else
  bad "空白入りのリストで一部の要素が写像されていない"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi
run_shim --reviewers "code-reviewer, pr-test-analyzer"
if argv_has_seq "--perspective" "code-review" \
   && argv_has_seq "--perspective" "test-analysis"; then
  ok "--reviewers 側でも空白入りのリストが写像される"
else
  bad "--reviewers の空白入りリストで一部の要素が写像されていない"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# pnpm は版によって `pnpm run x -- --opt` の `--` をスクリプトへ**透過する**
# （実測: pnpm 9.15.9 で argv[1] が '--'。npm は除去する）。各リポジトリの手順書は
# `pnpm code-review:codex -- --base develop` の形なので、先頭 `--` を拒否すると
# **文書どおりのコマンドが動かない**。`--` は利用者が渡した引数ではなくパッケージ
# マネージャが挟むものなので、拒否の対象として不適切。
run_shim -- --base develop --dry-run
if [ "$RUN_RC" -eq 0 ] && argv_has_seq "--base" "develop"; then
  ok "先頭の '--' を読み飛ばして後続を解釈する（pnpm の透過に対応）"
else
  bad "先頭の '--' で失敗した (rc=$RUN_RC) — pnpm 経由の文書化コマンドが動かない"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi

# `--` の位置は pnpm の版や呼び出し方で変わりうる。途中でも読み飛ばす。
run_shim --base develop -- --dry-run
if [ "$RUN_RC" -eq 0 ] && argv_has_seq "--base" "develop"; then
  ok "途中の '--' も読み飛ばす"
else
  bad "途中の '--' で失敗した (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi

# GNU 慣用の `--opt=value` 形式。旧ラッパーが受けていたので手順書やスクリプトに残りうる。
run_shim --base=develop --dry-run
if [ "$RUN_RC" -eq 0 ] && argv_has_seq "--base" "develop"; then
  ok "--base=develop 形式が空白区切りと同じ結果になる"
else
  bad "--base=develop 形式が拒否された (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi
run_shim --reviewers=code-reviewer,comment-analyzer --dry-run
if argv_has_seq "--perspective" "code-review" \
   && argv_has_seq "--perspective" "comment-analysis"; then
  ok "--reviewers=a,b 形式が写像つきで展開される"
else
  bad "--reviewers=a,b 形式が展開されていない"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi
run_shim --timeout=300 --dry-run
if argv_has_seq "--timeout" "300"; then
  ok "--timeout=300 形式が委譲される"
else
  bad "--timeout=300 形式が委譲されていない"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# 値が空の `--opt=` は、黙って既定へ落とさず拒否する（空白区切り側と同じ扱い）。
for _empty in "--base=" "--timeout="; do
  run_shim "$_empty" --dry-run
  if [ "$RUN_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ]; then
    ok "'${_empty}'（値が空）を拒否し、委譲しない"
  else
    bad "'${_empty}' が rc=$RUN_RC で通った（黙って既定へ落ちる）"
    sed 's/^/    | /' "$WORK/out.log" >&2
  fi
done

# usage() の heredoc は ${SCRIPT_NAME} を展開するため**非クォート**（<<USAGE）。
# そこへバッククォートを書くとコマンド置換として実行され、`--help` が
# `command not found` を吐きながら該当語をヘルプ本文から落とす（実測で踏んだ）。
# 静かに壊れるので、出力そのものを検査する。
run_shim --help
if [ "$RUN_RC" -eq 0 ]; then
  ok "--help が成功する"
else
  bad "--help が非 0 で終了した (rc=$RUN_RC)"
fi
if grep -q "command not found" "$WORK/out.log"; then
  bad "--help がコマンド置換を実行している（usage の heredoc が非クォート）"
  grep "command not found" "$WORK/out.log" | sed 's/^/    | /' >&2
else
  ok "--help がコマンド置換を実行しない"
fi
# ヘルプに書いた語が実際に出ていること（置換で消えると空白だけが残る）
for _word in "--base" "--staged" "--reviewers" "--exclude-reviewers" "--exclude-cli" "--list-reviewers" "--print-toolkit-root" "--timeout" "--dry-run" "--fresh" "opt=value"; do
  if grep -q -- "$_word" "$WORK/out.log"; then
    ok "--help に '${_word}' が出る"
  else
    bad "--help から '${_word}' が消えている"
  fi
done

# 配置は原子的であること。cp で dest を直接上書きすると、書き込み途中で失敗したときに
# 壊れたラッパーが残る。同一ディレクトリの一時ファイルへ書いてから mv すれば、
# rename(2) が原子的なので dest は「前の内容」か「新しい内容」しか取らない。
#
# 部分書き込み（ディスク満杯・中断）を再現するのは現実的でないため、ここは**構造で
# 固定する**: dest を直接 cp する形へ戻す変更を赤にする。振る舞いで測れていない旨を
# 明示しておく（測っていない検出力を主張しない）。
_setup_src="$PLUGIN_ROOT/scripts/setup-multi-agent.sh"

# 走査は install_review_wrappers の関数本体へ限定する。ファイル全体を舐めると、
# (1) 既に原子的な別経路（yq は呼び出し元が一時パスを渡している）の cp を拾って誤検出し、
# (2) **コメントの散文が needle に一致して素通しになる**（実測: 原子化を丸ごと戻しても
#     「以前は mv "$tmp" "$dest" だったが…」というコメントを残すだけで緑になった）。
_install_body="$(awk '/^install_review_wrappers\(\)/ { inf = 1 }
                      inf { print }
                      inf && /^}$/ { exit }' "$_setup_src")"
# 抽出が**途中で切れた**ことを「本体を読んだ」と誤認しない。awk は行頭 } で打ち切るので、
# 関数内に heredoc 等で行頭 } があると数行で終わる（実測: 4 行で打ち切られ、変異が素通りした）。
# 空でないことに加えて、関数の末尾まで到達した証拠（最後の成功メッセージ）を要求する。
case "$_install_body" in
  *'codex-review.sh を配置しました'*) _body_ok=1 ;;
  *) _body_ok=0 ;;
esac
if [ -z "$_install_body" ] || [ "$_body_ok" -ne 1 ]; then
  bad "install_review_wrappers の本体を最後まで抽出できなかった（この検査が成立していない）"
  _install_body=""
fi

if [ -n "$_install_body" ]; then
  case "$_install_body" in
    *'mv "$tmp" "$dest"'*)
      ok "配置が一時ファイル + mv（原子的）になっている" ;;
    *)
      bad "配置が原子的でない — dest を直接上書きすると、失敗時に壊れたラッパーが残る" ;;
  esac
fi
if [ -n "$_install_body" ]; then
  case "$_install_body" in
    *'mv "$sidecar_tmp" "$sidecar"'*)
      ok "sidecar も一時ファイル + mv（原子的）になっている" ;;
    *)
      bad "sidecar が原子的に更新されない — 途中書き込みを resolver が読みうる" ;;
  esac
  if printf '%s\n' "$_install_body" | awk '/>[[:space:]]*"\$sidecar"/ { found = 1 } END { exit(found ? 0 : 1) }'; then
    bad "install_review_wrappers が sidecar を直接上書きしている"
  else
    ok "install_review_wrappers に空白変種を含め sidecar を直接上書きする経路が無い"
  fi
fi
# 照合は case で行う。`printf | grep -q` は grep が先に閉じるので pipefail 下で
# SIGPIPE により rc が反転しうる（このリポジトリの run-all case 10 が禁止している形）。
if [ -n "$_install_body" ]; then
  case "$_install_body" in
    *'cp "$src" "$dest"'*)
      bad "install_review_wrappers が dest を直接 cp している" ;;
    *)
      ok "install_review_wrappers に dest を直接 cp する経路が無い" ;;
  esac
fi
# 失敗時に「既存ファイルは無傷」と伝えること。伝えないと、利用者は退避先を探すか
# 再実行するかを判断できない。
#
# 件数はリテラルで固定しない。`-ge 3` のような直書きは (1) 失敗経路を 1 本増やしても
# 気づかず（実測: 通知の無い 4 本目を足しても緑）、(2) grep -c がコメントまで数えるため
# 実装から通知を消してコメントに同じ文言を書くだけで通った（実測: chmod を `|| true` へ
# 変えても緑）。**tmp 導入後の失敗経路（return 1）の数から導出**して照合する。
if [ -n "$_install_body" ]; then
  # 要求は「全経路が『変更していません』と言うこと」ではない。mv の後に失敗する経路では
  # ラッパーは既に置かれているので、その文言は**嘘になる**（実際そう書きかけて赤くなった）。
  # 正しい要求は「どの失敗経路も、終わった時点の状態を利用者へ伝えること」。
  # return 1 の直前 3 行以内に print_info があるかで判定する。
  _bare="$(printf '%s\n' "$_install_body" | awk '
    /local tmp=/ { started = 1 }
    started {
      if ($0 ~ /^ *return 1$/) {
        if (p1 !~ /print_info/ && p2 !~ /print_info/ && p3 !~ /print_info/) bare++
        total++
      }
      p3 = p2; p2 = p1; p1 = $0
    }
    END { printf "%d %d", total, bare }')"
  _total="${_bare%% *}"
  _bare_n="${_bare##* }"
  if [ "${_total:-0}" -lt 3 ]; then
    bad "tmp 導入後の失敗経路を ${_total} 本しか見つけられなかった（この検査が成立していない）"
  elif [ "${_bare_n:-1}" -eq 0 ]; then
    ok "配置の失敗経路すべて（${_total} 本）が終了時の状態を利用者へ伝える"
  else
    bad "失敗経路 ${_total} 本のうち ${_bare_n} 本が状態を伝えずに return している"
  fi
fi

