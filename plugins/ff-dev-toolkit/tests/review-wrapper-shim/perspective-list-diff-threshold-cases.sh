#!/usr/bin/env bash
#
# review-wrapper-shim suite の検査ファイル（verify.sh から source される。単独実行不可）。
# 範囲: 観点の一覧と除外（--list-reviewers / --exclude-reviewers / --exclude-cli）、diff サイズ閾値と timeout の旧 env 写像、--workdir の拒否。
# 依存: run_shim / argv_has* と base-ref-diff-guard-cases.sh の ${DIFF_REPO}（diff 閾値のケースが Git fixture として使う）。
# source 順は verify.sh の一覧が正本。fixture・関数・変数は同一プロセスで共有され、
# 後続ファイルは先行ファイルが作った fixture を参照するので、順序を入れ替えない。

# --- 観点の一覧と除外（消費側ラッパーが持っていた入口） ---

run_shim --list-reviewers
if [ "$RUN_RC" -eq 0 ]; then
  ok "--list-reviewers が成功する"
else
  bad "--list-reviewers が非 0 で終了した (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi
if argv_has "--list-perspectives"; then
  ok "--list-reviewers が委譲先の --list-perspectives へ写される"
else
  bad "--list-reviewers が委譲されていない（シムが独自に一覧を持つとレジストリと乖離する）"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

run_shim --exclude-reviewers code-reviewer,comment-analyzer --dry-run
if argv_has_seq "--exclude-perspective" "code-review" \
   && argv_has_seq "--exclude-perspective" "comment-analysis"; then
  ok "--exclude-reviewers が観点名の写像つきで --exclude-perspective へ展開される"
else
  bad "--exclude-reviewers が展開されていない"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi
run_shim --exclude-reviewers "" --dry-run
if [ "$RUN_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ]; then
  ok "--exclude-reviewers の空値を拒否し、委譲しない"
else
  bad "--exclude-reviewers の空値が rc=$RUN_RC で通った"
fi

# --exclude-cli は観点ではなく CLI 名なので写像は挟まず、委譲先の同名オプションへ
# そのまま渡す（繰り返し可）。ここが落ちると「外したつもりの CLI が毎回走る」に戻る。
run_shim --exclude-cli grok-cli --exclude-cli claude-code --dry-run
if argv_has_seq "--exclude-cli" "grok-cli" && argv_has_seq "--exclude-cli" "claude-code"; then
  ok "--exclude-cli が委譲先へ繰り返しのまま透過する"
else
  bad "--exclude-cli が委譲されていない"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi
run_shim --exclude-cli=grok-cli --dry-run
if argv_has_seq "--exclude-cli" "grok-cli"; then
  ok "--exclude-cli=<name> 形も委譲先へ透過する"
else
  bad "--exclude-cli=<name> が委譲されていない"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi
run_shim --exclude-cli "" --dry-run
if [ "$RUN_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ]; then
  ok "--exclude-cli の空値を拒否し、委譲しない"
else
  bad "--exclude-cli の空値が rc=$RUN_RC で通った"
fi

# --- diff サイズ閾値（消費側の課金の歯止め） ---

# 既定は無効。既定で有効にすると、これまで走っていたレビューが**黙ってスキップされる**
# 側へ倒れる。歯止めは明示的に入れてもらう。
run_shim --base develop --dry-run
if argv_has "--task"; then
  ok "閾値未設定なら従来どおり委譲する（既定で無効）"
else
  bad "閾値未設定なのに委譲されなかった"
fi

# 十分大きい閾値を設定すると、委譲せずスキップし、理由を 1 行出す。
# 公開 checkout には develop が無い。上限側と同じ2コミットの fixture で測り、
# 呼び出し元のブランチ構成・差分量に依存させない（`Issue #1057`）。
RUN_SHIM_CWD="$DIFF_REPO" run_shim CODEX_REVIEW_MIN_LINES=999999 --base HEAD~1 --dry-run
if [ "$RUN_RC" -eq 0 ] && [ ! -s "$WORK/argv.log" ]; then
  ok "diff が閾値未満ならスキップし、委譲しない"
else
  bad "小 diff スキップが働いていない (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi
if grep -q "CODEX_REVIEW_MIN_LINES" "$WORK/err.log"; then
  ok "スキップの理由と閾値を伝える（黙ってスキップしない）"
else
  bad "スキップした事実が伝わらない — 走ったのか飛ばされたのか区別できない"
  sed 's/^/    | /' "$WORK/err.log" >&2
fi

# 非数値を黙って既定へ落とすと、歯止めを設定したつもりで全件走る。
run_shim CODEX_REVIEW_MIN_LINES=abc --base develop --dry-run
if [ "$RUN_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ]; then
  ok "閾値が非数値なら非 0 で拒否し、委譲しない"
else
  bad "非数値の閾値が rc=$RUN_RC で通った（設定したつもりで全件走る）"
fi
run_shim CODEX_REVIEW_MAX_DIFF_BYTES=abc --base develop --dry-run
if [ "$RUN_RC" -eq 2 ]; then
  ok "上限側の閾値も非数値を拒否する"
else
  bad "CODEX_REVIEW_MAX_DIFF_BYTES の非数値が通った (rc=$RUN_RC)"
fi
# 上限を極小にすると、大きすぎる diff としてスキップする。
# 上限超過は**非 0**。0 で返すと呼び出し側から「レビュー成功」と区別できず、
# 最もレビューが要る大きな差分ほどゲートを素通りする。
RUN_SHIM_CWD="$DIFF_REPO" run_shim CODEX_REVIEW_MAX_DIFF_BYTES=1 --base HEAD~1 --dry-run
if [ "$RUN_RC" -eq 3 ] && [ ! -s "$WORK/argv.log" ]; then
  ok "diff が上限を超えたら非 0（3）で終了し、委譲しない"
else
  bad "上限超過が rc=$RUN_RC で終わった（意図的なスキップと区別できない）"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi
if grep -q "CODEX_MAX\|CODEX_REVIEW_MAX_DIFF_BYTES=0" "$WORK/err.log"; then
  ok "上限超過の出力が回避方法を案内する"
else
  bad "上限超過の出力に回避方法が無い"
  sed 's/^/    | /' "$WORK/err.log" >&2
fi
# 小 diff スキップ（0）と終了コードで区別できること。
RUN_SHIM_CWD="$DIFF_REPO" run_shim CODEX_REVIEW_MIN_LINES=999999 --base HEAD~1 --dry-run
if [ "$RUN_RC" -eq 0 ]; then
  ok "小 diff スキップは 0 のまま（上限超過の 3 と区別できる）"
else
  bad "小 diff スキップが 0 で終わらない (rc=$RUN_RC)"
fi

# 旧 env の timeout は新しい入口へ写す。
run_shim CODEX_REVIEW_TIMEOUT_S=321 --base develop --dry-run
if argv_has_seq "--timeout" "321"; then
  ok "CODEX_REVIEW_TIMEOUT_S が --timeout へ写される"
else
  bad "CODEX_REVIEW_TIMEOUT_S が写されていない"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# 明示した --timeout が env に負けると、指定した意味が消える。委譲先は last-wins なので
# 後から足すと env が勝つ（実測: --timeout 999 を渡して 321 秒で走った）。
run_shim CODEX_REVIEW_TIMEOUT_S=321 --base develop --timeout 999 --dry-run
if argv_has_seq "--timeout" "999" && ! argv_has_seq "--timeout" "321"; then
  ok "明示した --timeout が CODEX_REVIEW_TIMEOUT_S より優先される"
else
  bad "env の timeout が明示指定を上書きした"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# 「設定済みだが空」を未設定と同一視すると、歯止めが黙って無効になる。
for _v in CODEX_REVIEW_MIN_LINES CODEX_REVIEW_MAX_DIFF_BYTES; do
  run_shim "${_v}=" --base develop --dry-run
  if [ "$RUN_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ]; then
    ok "${_v} の空値を拒否する（設定したのに効かない、を作らない）"
  else
    bad "${_v} の空値が rc=$RUN_RC で通った（歯止めが黙って無効になる）"
  fi
done

# 一覧は後段（skip / 旧 env / diff 閾値）を通さない。通すと「一覧を見たいだけ」なのに
# --base が無くて落ちたり、閾値次第で一覧が出ないまま成功終了したりする。
run_shim CODEX_REVIEW_MIN_LINES=10 --list-reviewers
if [ "$RUN_RC" -eq 0 ] && argv_has "--list-perspectives"; then
  ok "--list-reviewers は閾値が設定されていても一覧を出す"
else
  bad "--list-reviewers が閾値の経路に巻き込まれた (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi
if argv_has "--dry-run" || argv_has_seq "--base" "develop"; then
  bad "--list-reviewers が一覧以外の引数まで委譲した"
  sed 's/^/    | /' "$WORK/argv.log" >&2
else
  ok "--list-reviewers は一覧のためだけの引数で委譲する"
fi

# 数字だけでも桁があふれると shell の整数比較が壊れる。`[ 30 -lt 999…9 ]` は
# 「integer expression expected」で rc=2 を返し、if の条件としては偽 — つまり歯止めが
# 黙って効かなくなり、レビューが全件走る（実測）。
run_shim CODEX_REVIEW_MIN_LINES=99999999999999999999 --base develop --dry-run
if [ "$RUN_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ]; then
  ok "桁があふれる閾値を拒否する（整数比較が壊れて歯止めが無効になるのを防ぐ）"
else
  bad "桁あふれの閾値が rc=$RUN_RC で通った（歯止めが黙って効かない）"
fi

# "00" を文字列比較で "0" と区別すると、実効値 0 の歯止めが有効化され全件スキップする。
run_shim CODEX_REVIEW_MAX_DIFF_BYTES=00 --base develop --dry-run
if [ "$RUN_RC" -eq 0 ] && [ -s "$WORK/argv.log" ]; then
  ok "先頭ゼロの 0 は「無効」として正規化される（全件スキップにならない）"
else
  bad "CODEX_REVIEW_MAX_DIFF_BYTES=00 で委譲されなかった (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi

# timeout env も「設定済みだが空」を未設定と同一視しない（同じファイル内で扱いを揃える）。
run_shim CODEX_REVIEW_TIMEOUT_S= --base develop --dry-run
if [ "$RUN_RC" -eq 2 ]; then
  ok "CODEX_REVIEW_TIMEOUT_S の空値を拒否する"
else
  bad "CODEX_REVIEW_TIMEOUT_S の空値が rc=$RUN_RC で通った（設定したのに効かない）"
fi

# 測る範囲は委譲先がレビューする範囲と同じであること。BASE...HEAD だけを測ると
# pre-commit（staged 未コミット）で「0 行」と判定してスキップし、レビューされるはずの
# 変更が静かに飛ぶ。振る舞いで作り分けるのが難しいので構造で固定する。
if grep -qF 'git diff --numstat HEAD' "$SHIM"; then
  ok "diff の測定が作業ツリーの変更も含む（委譲先のレビュー範囲と一致）"
else
  bad "diff の測定が BASE...HEAD だけ — pre-commit の staged 変更が 0 行と判定される"
fi
# バイナリは numstat が `-` を出し、加算では 0 に化ける。測れないものを「小さい」と
# 読んでスキップしない。
if grep -qF '_unmeasurable' "$SHIM"; then
  ok "行数で測れない diff（バイナリ）をスキップ判定から除外する"
else
  bad "バイナリ変更が 0 行として扱われ、無言でスキップされる"
fi

# 先頭ゼロの正規化は 10 進で行う。`printf '%d'` は bash が 8 進として解釈するため、
# `010` が 8 になり `008` は invalid number で落ちる（実測）。閾値が 8 進で解釈されると、
# 設定した値と実際に効く値が食い違ったまま気づけない。
# 008 は 8 進として解釈できない値。printf '%d' だと invalid number で落ちる。
RUN_SHIM_CWD="$DIFF_REPO" run_shim CODEX_REVIEW_MIN_LINES=008 --base HEAD~1 --dry-run
if [ "$RUN_RC" -eq 0 ]; then
  ok "先頭ゼロ付きの 008 が数値として扱われる（8 進解釈でエラーにならない）"
else
  bad "008 で非 0 になった (rc=$RUN_RC) — printf '%d' の 8 進解釈"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi
# 正規化の結果は**スキップの通知に出る数値**で確かめる。rc だけを見ると、8 進で
# 解釈されても「落ちなかった」で通ってしまう（初版がそうだった）。
# 十分大きい値にして必ずスキップさせ、通知の数値を照合する。
# 10 進なら 10000000、8 進なら 2097152 になる。
RUN_SHIM_CWD="$DIFF_REPO" run_shim CODEX_REVIEW_MIN_LINES=010000000 --base HEAD~1 --dry-run
if grep -q "CODEX_REVIEW_MIN_LINES=10000000" "$WORK/err.log"; then
  ok "先頭ゼロ付きの値が 10 進として正規化される"
else
  bad "先頭ゼロが 8 進として解釈された（通知の数値が 10 進でない）"
  sed 's/^/    | /' "$WORK/err.log" >&2
fi

# 一覧はレビューを走らせる操作ではないので、逃がし弁や旧 env の判定より前に返す。
run_shim SKIP_CODEX_REVIEW=1 --list-reviewers
if [ "$RUN_RC" -eq 0 ] && argv_has "--list-perspectives"; then
  ok "SKIP_CODEX_REVIEW=1 でも --list-reviewers は一覧を出す"
else
  bad "SKIP_CODEX_REVIEW が --list-reviewers を止めた (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi
run_shim CODEX_DEFAULT_REVIEWERS= --list-reviewers
if [ "$RUN_RC" -eq 0 ] && argv_has "--list-perspectives"; then
  ok "旧 env が空でも --list-reviewers は一覧を出す"
else
  bad "旧 env の検証が --list-reviewers を止めた (rc=$RUN_RC)"
fi

# --workdir は委譲先に対応する概念が無い。黙って無視せず拒否する。
run_shim --workdir /tmp --base develop --dry-run
# この rc=2 の主張は、汎用の「未対応オプション」経路でも満たされる（実測: 専用 case を
# 消しても緑のまま）。専用 case が守っているのは**代替手段の案内**のほうなので、
# ラベルを実際に守っている範囲へ狭める。
if [ "$RUN_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ]; then
  ok "--workdir で委譲しない（汎用の未対応オプション経路でも満たされる）"
else
  bad "--workdir が rc=$RUN_RC で通った"
fi
if grep -q "cd" "$WORK/err.log"; then
  ok "--workdir の拒否メッセージが代替手段を案内する"
else
  bad "--workdir の拒否メッセージに代替手段が無い"
fi
