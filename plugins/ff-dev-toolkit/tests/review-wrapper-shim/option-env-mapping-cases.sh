#!/usr/bin/env bash
#
# review-wrapper-shim suite の検査ファイル（verify.sh から source される。単独実行不可）。
# 範囲: --reviewers の写像・未対応オプションの拒否と案内・旧ラッパー env（モデル / effort / 既定観点 / SKIP_CODEX_REVIEW）の写像と通知。
# 依存: run_shim / env_log_has / argv_has*。
# source 順は verify.sh の一覧が正本。fixture・関数・変数は同一プロセスで共有され、
# 後続ファイルは先行ファイルが作った fixture を参照するので、順序を入れ替えない。

# --reviewers は multi-agent.sh の --perspective へ写す（複数値は個別フラグへ展開）
run_shim --reviewers code-review,security-analysis
if argv_has_seq "--perspective" "code-review" \
   && argv_has_seq "--perspective" "security-analysis"; then
  ok "--reviewers のカンマ区切りが --perspective へ 1 件ずつ展開される"
else
  bad "--reviewers が --perspective へ展開されていない"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# --reviewers を**他のオプションと併用**する。単体で渡すケースしか見ていないと、
# 引数の並べ直しで後続を壊す実装を素通しする（実測: 初版は IFS=',' + 位置パラメータの
# set -- で後続を連結し、`--timeout 420` を 1 引数へ潰していた。単体テストは緑のまま、
# 実 CLI 実行で「対応しているはずの --timeout が拒否される」形で露見した）。
run_shim --base develop --reviewers code-review,test-analysis --timeout 420
if [ "$RUN_RC" -ne 0 ]; then
  bad "--reviewers を他オプションと併用すると非 0 で終了する (rc=$RUN_RC) — 引数の並べ直しで後続を壊している"
  sed 's/^/    | /' "$WORK/out.log" >&2
else
  ok "--reviewers を他オプションと併用できる"
fi
if argv_has_seq "--timeout" "420" && argv_has_seq "--base" "develop" \
   && argv_has_seq "--perspective" "code-review" \
   && argv_has_seq "--perspective" "test-analysis"; then
  ok "併用時も --base / --timeout / 複数 --perspective がすべて委譲先へ届く"
else
  bad "併用時に一部のオプションが委譲先へ届いていない"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# 受け取れないオプションは黙って捨てない
run_shim --no-such-option foo
if [ "$RUN_RC" -ne 0 ]; then
  ok "未対応オプションを非 0 で拒否する"
else
  bad "未対応オプションが素通りした（指定したつもりのまま既定設定でレビューが走る）"
fi
if grep -q -- "--no-such-option" "$WORK/out.log"; then
  ok "拒否メッセージが該当オプションを名指しする"
else
  bad "拒否メッセージが該当オプションを名指ししていない"
fi
if grep -q -- "対応オプションは --help" "$WORK/out.log"; then
  ok "未対応オプションの案内が、古い固定列挙ではなく --help を正本として指す"
else
  bad "未対応オプションの案内が --help を指していない"
fi

# 拒否メッセージの復旧形に固定の --cli codex-cli を書かない（Issue 1600）。codex 不在の
# --dry-run で外そうとしている当の引数で、案内どおり付けると codex-cli の観点の fallback
# 再割り当てが --cli フィルタに弾かれて「Execution plan is empty」へ戻る。委譲先の
# --set-reviewers を渡した形（--dry-run 警告が以前案内していた操作そのもの）で測る。
run_shim --dry-run --base develop --set-reviewers main=grok-cli
if [ "$RUN_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ] \
  && grep -q -- "'--set-reviewers' を受け付けません" "$WORK/err.log" \
  && grep -q -- 'multi-agent.sh --task review --set-reviewers \.\.\.' "$WORK/err.log" \
  && ! grep -q -- '--task review --cli codex-cli' "$WORK/err.log" \
  && grep -q -- 'codex 不在の --dry-run でプランを見る回は付けない' "$WORK/err.log"; then
  ok "--set-reviewers の拒否メッセージの復旧形が --cli codex-cli を再び付けさせない（付ける条件を別行で案内する）"
else
  bad "--set-reviewers の拒否メッセージが --cli codex-cli 付きの復旧形へ戻す、または拒否していない (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/err.log" >&2
fi

# シム本体が --set-reviewers に触れる行は、必ず「このシムは受け付けない / multi-agent.sh
# を直接呼ぶときだけ」と併記していること。ヘッダー注記と --dry-run 警告の両方に同じ語が
# あり、片方だけ直すと「案内どおり渡すと rc=2」の形が残る（消費側で実測・Issue 1600）。
# 未対応オプション経路の `'${1}' を受け付けません` は実行時に展開されるため静的には
# 一致しない — その経路は上の実行ケースで固定している。
# 併記検査は行単位なので、併記済みの長い 1 行（--dry-run 警告の echo）へ旧文言
# 「--set-reviewers で主を変えられます」を戻す形は素通りする。無条件案内の形そのもの
# （`--set-reviewers で`）を別針で止める。シムから --set-reviewers への言及が全部消えた
# 状態は正当（案内しないのが最も安全）なので、0 行は緑。
_sr_lines="$(grep -n -- '--set-reviewers' "$SHIM" || true)"
_sr_unqualified="$(printf '%s\n' "$_sr_lines" | grep -v '受け付けない\|受け付けません\|直接呼ぶ' || true)"
_sr_recommend="$(grep -n -- '--set-reviewers で' "$SHIM" || true)"
if [ -z "$_sr_unqualified" ] && [ -z "$_sr_recommend" ]; then
  ok "シム本体が --set-reviewers に触れる行はすべて「受け付けない / multi-agent.sh 直接」を併記し、無条件案内の形（--set-reviewers で…）が無い（$(printf '%s' "$_sr_lines" | grep -c '' | tr -d ' ') 行）"
else
  bad "シム本体に --set-reviewers を無条件で案内する行がある（案内どおり渡すと rc=2 で拒まれる）"
  printf '%s\n' "$_sr_unqualified" "$_sr_recommend" | sed '/^$/d; s/^/    | /' >&2
fi

# FF_DEV_TOOLKIT_ROOT の明示指定ミスは resolve_orchestrator が rc=2 と分類する。
# `if ! VAR=$(...)` は `!` の status へ上書きするため、呼び出し側で 1 に潰さないこと。
for _bad_root_arg in "--base develop --dry-run" "--list-reviewers"; do
  set -- $_bad_root_arg
  _bad_root_rc=0
  run_isolated_shim FF_DEV_TOOLKIT_ROOT="$WORK/does-not-exist" \
    bash "$PROJ/scripts/codex-review.sh" "$@" \
    >"$WORK/bad-root.out" 2>&1 </dev/null || _bad_root_rc=$?
  if [ "$_bad_root_rc" -eq 2 ]; then
    ok "不正な FF_DEV_TOOLKIT_ROOT を rc=2 のまま返す (${_bad_root_arg})"
  else
    bad "不正な FF_DEV_TOOLKIT_ROOT の rc=2 が rc=${_bad_root_rc} に潰れた (${_bad_root_arg})"
    sed 's/^/    | /' "$WORK/bad-root.out" >&2
  fi
done

# 旧ラッパーのモデル指定 env は、黙殺でも拒否でもなく**写像 + 通知**にする。
# 黙殺は「指定したつもりの設定が効かないまま走る」ACE-70-2 の形。拒否は安全だが、
# 移行対象の消費リポジトリがいずれもこれを設定していたため、拒否＝移行不能になる
# （件数はこのリポジトリからは検証できないので書かない）。
run_shim CODEX_MODEL=some-model
if [ "$RUN_RC" -eq 0 ]; then
  ok "CODEX_MODEL が設定されていても成功する（拒否ではなく写像する）"
else
  bad "CODEX_MODEL が設定されていると非 0 で落ちる (rc=$RUN_RC) — 移行できない"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi
if env_log_has "MULTI_AGENT_MODEL_CODEX_CLI=some-model"; then
  ok "CODEX_MODEL の値が MULTI_AGENT_MODEL_CODEX_CLI として委譲先へ届く"
else
  bad "CODEX_MODEL が委譲先へ届いていない（写したつもりで export していない）"
  sed 's/^/    | /' "$WORK/env.log" >&2
fi
if grep -q "MULTI_AGENT_MODEL_CODEX_CLI" "$WORK/out.log"; then
  ok "写像した旨が通知される（黙って読み替えない）"
else
  bad "写像が無言で行われた（利用者の指定と実際の設定が食い違っても気づけない）"
fi

# 新旧が同時指定された場合、黙って旧が勝つと移行途中の環境で古い設定が生き残る。
run_shim CODEX_MODEL=old-model MULTI_AGENT_MODEL_CODEX_CLI=new-model
if env_log_has "MULTI_AGENT_MODEL_CODEX_CLI=new-model"; then
  ok "新旧の同時指定では新（MULTI_AGENT_*）が優先される"
else
  bad "新旧の同時指定で旧が勝った（移行途中の環境で古い設定が生き残る）"
  sed 's/^/    | /' "$WORK/env.log" >&2
fi
if grep -q "CODEX_MODEL" "$WORK/out.log"; then
  ok "旧を無視した旨が通知される"
else
  bad "旧を無視したことが通知されない"
fi

# reasoning effort は `Issue #419` の単独入口へ 1:1 で写す。下の env_log_has は写像の
# export 行を外す変異で必ず赤くなるため、通知文だけを見て通す真空 PASS を防ぐ。
run_shim CODEX_REASONING_EFFORT=high
if [ "$RUN_RC" -eq 0 ]; then
  ok "CODEX_REASONING_EFFORT は単独入口へ写せるため成功する"
else
  bad "CODEX_REASONING_EFFORT の写像が非 0 で拒否された (rc=$RUN_RC)"
fi
if env_log_has "MULTI_AGENT_CODEX_REASONING_EFFORT=high"; then
  ok "CODEX_REASONING_EFFORT の値が新しい effort env として委譲先へ届く"
else
  bad "CODEX_REASONING_EFFORT を写したつもりで export していない"
  sed 's/^/    | /' "$WORK/env.log" >&2
fi
if grep -q "MULTI_AGENT_CODEX_REASONING_EFFORT" "$WORK/err.log"; then
  ok "effort を写像した旨が stderr へ通知される"
else
  bad "effort の写像が無言で行われた"
fi

run_shim CODEX_REASONING_EFFORT=low MULTI_AGENT_CODEX_REASONING_EFFORT=xhigh
if env_log_has "MULTI_AGENT_CODEX_REASONING_EFFORT=xhigh"; then
  ok "旧新 effort の同時指定では新しい env が優先される"
else
  bad "旧新 effort の同時指定で旧値が勝った"
fi
if grep -q 'CODEX_REASONING_EFFORT は無視します' "$WORK/err.log"; then
  ok "旧 effort を無視したことが通知される"
else
  bad "旧 effort を無視したことが通知されない"
fi

# 旧ラッパーの既定観点 env。観点名の写像も併せて適用されること。
run_shim CODEX_DEFAULT_REVIEWERS=code-reviewer,comment-analyzer
if [ "$RUN_RC" -eq 0 ]; then
  ok "CODEX_DEFAULT_REVIEWERS が設定されていても成功する"
else
  bad "CODEX_DEFAULT_REVIEWERS で非 0 になった (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi
if argv_has_seq "--perspective" "code-review" \
   && argv_has_seq "--perspective" "comment-analysis"; then
  ok "CODEX_DEFAULT_REVIEWERS が観点名の写像つきで --perspective へ展開される"
else
  bad "CODEX_DEFAULT_REVIEWERS が --perspective へ展開されていない"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# 明示指定は env の既定より強い。逆だと「--reviewers を渡したのに env が勝つ」形になる。
run_shim CODEX_DEFAULT_REVIEWERS=code-reviewer --reviewers test-analysis
if argv_has_seq "--perspective" "test-analysis" \
   && ! argv_has_seq "--perspective" "code-review"; then
  ok "--reviewers の明示指定が CODEX_DEFAULT_REVIEWERS より優先される"
else
  bad "明示した --reviewers より env の既定が勝った"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# SKIP_CODEX_REVIEW=1 は既存の pre-commit 構成が使う実在の逃がし弁。
# 黙って無視すると「skip したはずのレビューが走る」ので、明示的に尊重する。
run_shim SKIP_CODEX_REVIEW=1
if [ "$RUN_RC" -eq 0 ]; then
  ok "SKIP_CODEX_REVIEW=1 は成功終了する"
else
  bad "SKIP_CODEX_REVIEW=1 が非 0 で終了した (rc=$RUN_RC)"
fi
if [ -s "$WORK/argv.log" ]; then
  bad "SKIP_CODEX_REVIEW=1 なのに委譲先が起動された"
  sed 's/^/    | /' "$WORK/argv.log" >&2
else
  ok "SKIP_CODEX_REVIEW=1 なら委譲先を起動しない"
fi

echo "-- setup による配置（冪等性） --"

if [ ! -f "$SETUP" ]; then
  bad "setup-multi-agent.sh が見つからない: $SETUP"
elif ! grep -q "install_review_wrappers" "$SETUP"; then
  bad "setup-multi-agent.sh に配置関数が無い（同梱しても消費プロジェクトへ届かない）"
else
  # 文字列の存在ではなく**実挙動**で見る。setup は末尾で BASH_SOURCE ガードを
  # 掛けているので、source しても main は走らない（依存導入も対話も起きない）。
  # grep で「上書き」「スキップ」という語を探すだけの検査は、語が別文脈で
  # 登場するだけで緑になる — 実際、この suite の初版はそれで真空 PASS した。
  TGT="$WORK/consumer"
  mkdir -p "$TGT"
  run_install() {
    ( set +e
      # shellcheck disable=SC1090
      . "$SETUP" >/dev/null 2>&1
      INSTALL_WRAPPERS_TARGET="$TGT" install_review_wrappers
    ) >"$WORK/install.log" 2>&1
  }

  # 1 回目: 新規配置
  if run_install && [ -f "$TGT/scripts/codex-review.sh" ]; then
    ok "setup: 新規プロジェクトへシムを配置する"
  else
    bad "setup: 新規配置に失敗した"
    sed 's/^/    | /' "$WORK/install.log" >&2
  fi
  if [ -x "$TGT/scripts/codex-review.sh" ]; then
    ok "setup: 配置したシムに実行ビットが立つ"
  else
    bad "setup: 配置したシムに実行ビットが無い"
  fi

  # 2 回目: 同一内容なら何もしない（冪等）
  if run_install && grep -q "スキップ" "$WORK/install.log"; then
    ok "setup: 同一内容の再実行はスキップと報告する"
  else
    bad "setup: 同一内容の再実行がスキップと報告されない"
    sed 's/^/    | /' "$WORK/install.log" >&2
  fi
  if [ ! -e "$TGT/scripts/codex-review.sh.bak" ]; then
    ok "setup: 同一内容なら退避ファイルを作らない"
  else
    bad "setup: 同一内容なのに退避ファイルを作った（毎回 .bak が増える）"
  fi

  # 3 回目: 利用者が手を入れた状態 → 黙って消さず退避してから置き換える
  printf '%s\n' '# ローカル改変' >> "$TGT/scripts/codex-review.sh"
  if run_install && [ -f "$TGT/scripts/codex-review.sh.bak" ] \
     && grep -q "ローカル改変" "$TGT/scripts/codex-review.sh.bak"; then
    ok "setup: 改変された既存ファイルを .bak へ退避してから置き換える"
  else
    bad "setup: 改変された既存ファイルを黙って消した（利用者の編集が失われる）"
    sed 's/^/    | /' "$WORK/install.log" >&2
  fi
  if grep -qE "退避|上書き" "$WORK/install.log"; then
    ok "setup: 上書きしたことを出力に残す"
  else
    bad "setup: 上書きが出力に現れない（静かな破壊）"
  fi
fi

