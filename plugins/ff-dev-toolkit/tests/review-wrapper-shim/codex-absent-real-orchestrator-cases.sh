#!/usr/bin/env bash
#
# review-wrapper-shim suite の検査ファイル（verify.sh から source される。単独実行不可）。
# 範囲: 実体の multi-agent.sh を toolkit へ置いた codex 不在経路（--cli 除去・pair 主 reviewer の有無・CODEX_REVIEW_CODEX_BIN と委譲先の検出の整合・toolkit 未解決時の降格案内・CLI registry 由来の候補）。
# 依存: run_shim（RUN_SHIM_CWD / RUN_SHIM_TOOLKIT）と ${STUB_CODEX}。REAL_ORCH_* 変数はこのファイル内で作る。
# source 順は verify.sh の一覧が正本。fixture・関数・変数は同一プロセスで共有され、
# 後続ファイルは先行ファイルが作った fixture を参照するので、順序を入れ替えない。

# ── 実オーケストレータでの codex 不在経路の固定 ────────────────────────────────
#
# delegation-basics-cases.sh のケースは stub オーケストレータ（常に rc=0 で "stub orchestrator ran" とだけ返す）を
# 使っているため、委譲先が実際に何本の AI CLI を検出したかには関与しない。**stub は argv の
# 形しか測れない** — 「--cli を外したら本当にプランが出るのか」は委譲先の CLI 検出と
# fallback 再割り当ての実装が決めるので、実体の multi-agent.sh を toolkit へ置いて測る:
#   ・codex だけが不在      → 固定の --cli codex-cli を外して委譲する。--cli は委譲先では
#                            分散モードのフィルタなので、外すと review 既定の pair モードへ
#                            戻る。主 reviewer が設定済みならその CLI が観点すべてを担当し、
#                            未設定なら委譲先が分散プランへ縮退する。どちらも残りの CLI が
#                            観点を引き受けたプランが rc=0 で出る
#   ・codex 不在 + 設定済みの主 reviewer が不在 → pair の主が居ないので rc=1
#                            （`main reviewer '<名前>' is not installed.`）。主 reviewer に
#                            既定値は無いので、この構成は reviewers 設定を fixture に**置いて**
#                            初めて成立する（run_shim は XDG_CONFIG_HOME を空の設定領域へ
#                            向けるため、ホストの ~/.config が漏れて成立することは無い）
#   ・codex 不在 + 主 reviewer 未設定（grok だけ） → `No reviewers configured — falling
#                            back to the distributed plan.` で分散へ縮退し、grok が観点を
#                            引き受けたプランが rc=0 で出る（Issue 1599 で CI が実測した形）
#   ・AI CLI が 1 本も無い → --cli を外しても委譲先の CLI 検出が
#                            `ERROR: No AI CLIs are installed` で止まる（rc=1・プランなし。
#                            新規セットアップ直後・CI の最小イメージで踏む）
# 1 つ目（codex だけ不在）は「codex だけ不在なら他の CLI がある環境でプランを確認できる」
# という受け入れ条件が **fake stub に対してだけ緑だった**経路で、実体では rc=1 でプランが
# 出ていなかった。stub に戻すとこの食い違いが永久に緑になるので、ここは実体を通す。
REAL_ORCH_TOOLKIT="$WORK/toolkit-real-orchestrator"
cp -R "$TOOLKIT" "$REAL_ORCH_TOOLKIT"
cp "$PLUGIN_ROOT/scripts/multi-agent.sh" "$REAL_ORCH_TOOLKIT/scripts/multi-agent.sh"
chmod +x "$REAL_ORCH_TOOLKIT/scripts/multi-agent.sh"
# 主 reviewer の 3 つ目の出所（プロジェクト設定 <cwd の git root>/.claude/agent-config.yaml
# の review.main）を切り離す。run_shim の既定 cwd はこのリポジトリの root なので、ここに
# review.main 付きの agent-config.yaml が置かれた日に「未設定」fixture が pair へ倒れて
# rc=1 になる（Issue 1599 と同じ形の環境依存）。MULTI_AGENT_CONFIG で fixture の config を
# 明示する手は取れない — 明示 config は yq 必須で、PATH を /usr/bin:/bin へ絞るこれらの
# ケースでは「yq is required to read explicit config」の rc=1 になる（実測）。代わりに
# `.claude/` を持たない git fixture repo を cwd にして、プロジェクト設定を「無い」に固定する
# （develop + 差分 1 コミットを持たせ、シムの --base develop の計測と委譲先の base 解決を通す）。
REAL_ORCH_REPO="$WORK/real-orch-repo"
ff_git_fixture_init "$REAL_ORCH_REPO"
git -C "$REAL_ORCH_REPO" checkout -q -b develop
printf 'base\n' > "$REAL_ORCH_REPO/app.txt"
git -C "$REAL_ORCH_REPO" add app.txt
git -C "$REAL_ORCH_REPO" commit -qm base
git -C "$REAL_ORCH_REPO" checkout -q -b feature
printf 'changed\n' >> "$REAL_ORCH_REPO/app.txt"
git -C "$REAL_ORCH_REPO" add app.txt
git -C "$REAL_ORCH_REPO" commit -qm changed
if [ ! -e "$REAL_ORCH_REPO/.claude" ]; then
  ok "fixture: 実オーケストレータ経由のケースの cwd にプロジェクト設定（.claude/）が無い"
else
  bad "fixture: 実オーケストレータ経由のケースの cwd に .claude/ が在る（プロジェクト設定の隔離が成立しない）"
fi
# 主 reviewer 設定済み（main=claude-code）の利用者設定 fixture。claude が居る回は pair
# プラン（rc=0）、grok だけの回は主不在の rc=1 を、同じ設定で測る。
XDG_MAIN_CLAUDE="$WORK/xdg-config-main-claude"
mkdir -p "$XDG_MAIN_CLAUDE/ff-dev-toolkit"
printf '%s\n' 'main=claude-code' 'sub=' > "$XDG_MAIN_CLAUDE/ff-dev-toolkit/reviewers"

# 「プランが出ていない」の針は **行頭アンカー付き**で持つ。委譲先の完了行は行頭の
# `🏁 Dry run complete. No tasks executed.`、シムの警告はインデント付きの案内文なので、
# 無アンカーだと案内文が自分の不在検査を満たして «常に緑» になる（実測: 警告文へ完了行の
# 文言を引用した版で本ケースが 2 件とも赤 → アンカーで解消）。
#
# CLI ゼロ環境は PATH を絞った fixture で再現する（stub CLI を一切置かない。ホストに
# claude/codex/copilot/grok が入っていても /usr/bin:/bin には無い）。
RUN_SHIM_CWD="$REAL_ORCH_REPO" RUN_SHIM_TOOLKIT="$REAL_ORCH_TOOLKIT" \
  run_shim CODEX_REVIEW_CODEX_BIN=/nonexistent/ff-codex-absent PATH=/usr/bin:/bin \
  --base develop --dry-run
unset RUN_SHIM_TOOLKIT
if [ "$RUN_RC" -eq 1 ] \
  && grep -q 'codex CLI（/nonexistent/ff-codex-absent）が PATH にありませんが、--dry-run' "$WORK/err.log" \
  && grep -q 'AI CLI が 1 本も PATH に無い環境では、--cli を外しても委譲先の CLI 検出が「No AI CLIs are installed」で止まります' "$WORK/err.log" \
  && grep -q 'ERROR: No AI CLIs are installed' "$WORK/err.log" \
  && ! grep -q '^🏁 Dry run complete' "$WORK/out.log"; then
  ok "AI CLI ゼロ + --dry-run（実オーケストレータ）: rc=1 で停止し、シムの警告文が実態（プラン非表示）と一致する"
else
  bad "AI CLI ゼロ + --dry-run（実オーケストレータ）: rc / 警告文 / 実際の委譲先エラーのいずれかが実態と食い違う (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi

# codex だけが不在（設定済みの pair 主 reviewer = claude が居る）経路。PATH に claude だけを
# 置き、利用者設定に main=claude-code を置いた fixture で再現する。シムが固定の
# --cli codex-cli を外して委譲するので pair モードへ戻り、主 reviewer が review 観点すべてを
# 担当するプランが出て rc=0 になる。pair で出たことは `Mode: pair` と縮退通知の不在で固定
# する — 主 reviewer の設定を無視して常に分散へ倒れる退行は、プランの有無だけでは緑のまま
# 通る（run_shim の既定は未設定なので、設定を渡さないとこの回も分散になり pair を測れない）。
# 委譲先へ実際に届く CLI 集合を測りたいので、ここも stub オーケストレータではなく
# 実体を通す（stub は常に rc=0 を返すため、プランが出たかどうかを測れない —
# 実体でしか「--cli を外した効果」は観測できない）。
OTHER_CLI_ONLY="$WORK/other-cli-only"
mkdir -p "$OTHER_CLI_ONLY"
printf '%s\n' '#!/usr/bin/env bash' 'echo "stub claude must not be invoked by dry-run" >&2' 'exit 99' \
  > "$OTHER_CLI_ONLY/claude"
chmod +x "$OTHER_CLI_ONLY/claude"
RUN_SHIM_CWD="$REAL_ORCH_REPO" RUN_SHIM_TOOLKIT="$REAL_ORCH_TOOLKIT" \
  run_shim CODEX_REVIEW_CODEX_BIN=/nonexistent/ff-codex-absent "PATH=$OTHER_CLI_ONLY:/usr/bin:/bin" \
    "XDG_CONFIG_HOME=$XDG_MAIN_CLAUDE" \
  --base develop --dry-run
unset RUN_SHIM_TOOLKIT
if [ "$RUN_RC" -eq 0 ] \
  && grep -q 'codex CLI（/nonexistent/ff-codex-absent）が PATH にありませんが、--dry-run' "$WORK/err.log" \
  && grep -q '固定の --cli codex-cli を外して委譲します' "$WORK/err.log" \
  && grep -q 'このシムを --dry-run なしで実行すると、従来どおり codex 不在で rc=4 停止します' "$WORK/err.log" \
  && grep -q '^🏁 Dry run complete' "$WORK/out.log" \
  && grep -q '^   Mode: pair' "$WORK/err.log" \
  && ! grep -q '^ℹ️  No reviewers configured' "$WORK/err.log" \
  && grep -qE '^   claude-code \[' "$WORK/out.log" \
  && ! grep -q '^ERROR: Execution plan is empty' "$WORK/err.log" \
  && ! grep -q 'excluded by --cli filter' "$WORK/err.log"; then
  ok "codex だけ不在（claude あり）+ --dry-run（実オーケストレータ）: rc=0 でプランが出て、シムの警告文が実態（実行は rc=4）と一致する"
else
  bad "codex だけ不在（claude あり）+ --dry-run（実オーケストレータ）: プランが出ていない、rc が 0 でない、または警告文が実態と食い違う (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
  sed 's/^/    err| /' "$WORK/err.log" >&2
fi

# codex 不在 + 設定済みの pair 主 reviewer（claude-code）も不在（grok だけ）の経路。--cli を
# 外しても pair の主が居ないので rc=1 で止まる。「codex 以外が 1 本でもあれば rc=0」という
# 読み方を止める針で、この 1 件が無いと上の claude 入り fixture だけが根拠になり、案内が
# 1 構成にしか当たらない。
# 主 reviewer は fixture の設定ファイルで**明示的に**与える。以前はホストの
# ~/.config/ff-dev-toolkit/reviewers（開発者の main=claude-code）に依存して緑になっており、
# 設定の無い CI では分散縮退 rc=0 で赤だった（Issue 1599）。
MAIN_ABSENT_ONLY="$WORK/main-reviewer-absent"
mkdir -p "$MAIN_ABSENT_ONLY"
printf '%s\n' '#!/usr/bin/env bash' 'echo "stub grok must not be invoked by dry-run" >&2' 'exit 99' \
  > "$MAIN_ABSENT_ONLY/grok"
chmod +x "$MAIN_ABSENT_ONLY/grok"
RUN_SHIM_CWD="$REAL_ORCH_REPO" RUN_SHIM_TOOLKIT="$REAL_ORCH_TOOLKIT" \
  run_shim CODEX_REVIEW_CODEX_BIN=/nonexistent/ff-codex-absent "PATH=$MAIN_ABSENT_ONLY:/usr/bin:/bin" \
    "XDG_CONFIG_HOME=$XDG_MAIN_CLAUDE" \
  --base develop --dry-run
unset RUN_SHIM_TOOLKIT
if [ "$RUN_RC" -eq 1 ] \
  && grep -q 'pair の主 reviewer（MULTI_AGENT_REVIEW_MAIN / プロジェクト設定で指定したもの）が未導入なら' "$WORK/err.log" \
  && grep -q 'MULTI_AGENT_REVIEW_MAIN=<cli> を付けて再実行すると主を変えられます' "$WORK/err.log" \
  && ! grep -q -- '--set-reviewers で主を変えられます' "$WORK/err.log" \
  && grep -q "^ERROR: main reviewer 'claude-code' is not installed" "$WORK/err.log" \
  && ! grep -q '^ℹ️  No reviewers configured' "$WORK/err.log" \
  && ! grep -q '^🏁 Dry run complete' "$WORK/out.log"; then
  ok "codex 不在 + 設定済み pair 主 reviewer 不在（grok だけ）+ --dry-run（実オーケストレータ）: rc=1 で止まり、シムの警告文がその構成を案内している"
else
  bad "codex 不在 + 設定済み pair 主 reviewer 不在（grok だけ）+ --dry-run（実オーケストレータ）: rc / 警告文 / 委譲先のエラーのいずれかが実態と食い違う (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi

# codex 不在 + 主 reviewer **未設定** + grok だけの経路。主 reviewer に既定値は無いので、
# 委譲先は「No reviewers configured — falling back to the distributed plan.」で分散へ縮退し、
# grok が観点を引き受けたプランを rc=0 で出す。設定の無い CI が踏む形そのもので、シムの
# 警告文はこの帰結（rc=0・pair ではないプラン）も案内していなければならない。
# 上のケースと PATH は同じで、違いは reviewers 設定の有無だけ — 2 件の帰結が割れることが
# 「主 reviewer に既定値は無い」の実測になる。
# 委譲先の通知（`ℹ️  No reviewers configured` / `ERROR: main reviewer`）の針は**行頭
# アンカー付き**で持つ。シムの警告文が「No reviewers configured — …」「main reviewer
# '<名前>' is not installed.」を引用しているため、無アンカーの `No reviewers configured` /
# `is not installed` は警告文自身に一致し、設定済み / 未設定の両ケースの否定針が赤になる
# （実測）。ERROR: 側は今の引用形なら `ERROR: main reviewer` でも誤一致しないが、案内文が
# 変わっても崩れないよう行頭で揃える。
RUN_SHIM_CWD="$REAL_ORCH_REPO" RUN_SHIM_TOOLKIT="$REAL_ORCH_TOOLKIT" \
  run_shim CODEX_REVIEW_CODEX_BIN=/nonexistent/ff-codex-absent "PATH=$MAIN_ABSENT_ONLY:/usr/bin:/bin" \
  --base develop --dry-run
unset RUN_SHIM_TOOLKIT
if [ "$RUN_RC" -eq 0 ] \
  && grep -q '主 reviewer が未設定なら、委譲先は「No reviewers configured — falling back to the distributed plan.」で分散プランへ縮退し' "$WORK/err.log" \
  && grep -q '^ℹ️  No reviewers configured — falling back to the distributed plan' "$WORK/err.log" \
  && grep -q '^   Mode: distributed' "$WORK/err.log" \
  && ! grep -q "^ERROR: main reviewer" "$WORK/err.log" \
  && grep -q '^🏁 Dry run complete' "$WORK/out.log" \
  && grep -qE '^   grok-cli \[' "$WORK/out.log"; then
  ok "codex 不在 + 主 reviewer 未設定（grok だけ）+ --dry-run（実オーケストレータ）: 分散へ縮退して rc=0 でプランが出て、シムの警告文がその帰結を案内している"
else
  bad "codex 不在 + 主 reviewer 未設定（grok だけ）+ --dry-run（実オーケストレータ）: rc / 警告文 / 委譲先の縮退通知のいずれかが実態と食い違う (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi

# --exclude-cli codex-cli との併用。ここでは固定の --cli を**落とさない** — 落とすと同じ
# コマンドが codex の導入状況で「委譲先の矛盾エラー」と「プラン表示」に分かれ、利用者から
# 見て意味が環境依存になる。落とす対象を広げる変異（利用者の --exclude-cli まで消す形を
# 含む）はこの 2 本の argv 検査が赤にする。
run_shim CODEX_REVIEW_CODEX_BIN=/nonexistent/ff-codex-absent --base develop --dry-run --exclude-cli codex-cli
if [ "$RUN_RC" -eq 0 ] && argv_has_seq "--cli" "codex-cli" \
  && argv_has_seq "--exclude-cli" "codex-cli" \
  && grep -q '固定の --cli codex-cli は外しません' "$WORK/err.log"; then
  ok "--exclude-cli codex-cli 併用（codex 不在 --dry-run）: 固定の --cli を残して委譲し、矛盾検査へ委ねる"
else
  bad "--exclude-cli codex-cli 併用（codex 不在 --dry-run）で固定の --cli が落ちている、除外指定が消えた、または案内が無い (rc=$RUN_RC)"
  sed 's/^/    argv| /' "$WORK/argv.log" >&2
fi
# codex-cli **以外**の除外と併用した回は、固定の --cli を落としつつ利用者の除外指定は
# そのまま残す。落とす対象を「--cli codex-cli の 1 組」から広げる変異（利用者の
# --exclude-cli まで巻き込む形）は、この 1 件だけが赤にする。
run_shim CODEX_REVIEW_CODEX_BIN=/nonexistent/ff-codex-absent --base develop --dry-run --exclude-cli grok-cli
if [ "$RUN_RC" -eq 0 ] && ! argv_has_seq "--cli" "codex-cli" \
  && argv_has_seq "--exclude-cli" "grok-cli"; then
  ok "codex-cli 以外の --exclude-cli 併用（codex 不在 --dry-run）: 固定の --cli だけが落ち、利用者の除外指定は残る"
else
  bad "codex-cli 以外の --exclude-cli 併用で、固定の --cli が残っている、または利用者の除外指定まで落ちた (rc=$RUN_RC)"
  sed 's/^/    argv| /' "$WORK/argv.log" >&2
fi
# 値が = で繋がる形（--exclude-cli=codex-cli）でも同じ判定になること。片方だけを見ると、
# 判定を 1 つの解釈分岐にだけ足した実装が緑で通る。
run_shim CODEX_REVIEW_CODEX_BIN=/nonexistent/ff-codex-absent --base develop --dry-run --exclude-cli=codex-cli
if [ "$RUN_RC" -eq 0 ] && argv_has_seq "--cli" "codex-cli" \
  && argv_has_seq "--exclude-cli" "codex-cli"; then
  ok "--exclude-cli=codex-cli（= 形）併用でも固定の --cli を残す"
else
  bad "--exclude-cli=codex-cli（= 形）併用で固定の --cli が落ちている (rc=$RUN_RC)"
  sed 's/^/    argv| /' "$WORK/argv.log" >&2
fi
# 実体の委譲先まで通して、帰結が rc=1（矛盾検査）であることを固定する。argv の形だけだと
# 「委譲先が実際に止めるか」は測れない。
RUN_SHIM_TOOLKIT="$REAL_ORCH_TOOLKIT" \
  run_shim CODEX_REVIEW_CODEX_BIN=/nonexistent/ff-codex-absent "PATH=$OTHER_CLI_ONLY:/usr/bin:/bin" \
  --base develop --dry-run --exclude-cli codex-cli
unset RUN_SHIM_TOOLKIT
if [ "$RUN_RC" -eq 1 ] \
  && grep -q -- '--cli and --exclude-cli both name' "$WORK/err.log" \
  && ! grep -q '^🏁 Dry run complete' "$WORK/out.log"; then
  ok "--exclude-cli codex-cli 併用（実オーケストレータ・codex 不在）: 委譲先の矛盾検査で rc=1（codex の有無で意味が変わらない）"
else
  bad "--exclude-cli codex-cli 併用（実オーケストレータ・codex 不在）が矛盾検査で止まっていない (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi

# 通常環境（codex 本人が居る）では挙動・終了コードが変わらないこと。上の stub ベースの
# 検査は「シムが委譲したこと」だけを見ており、委譲先が実際にプランを出すことまでは
# 保証しない。実オーケストレータで確認する。
NORMAL_ENV_STUB="$WORK/normal-env-stub"
mkdir -p "$NORMAL_ENV_STUB"
printf '%s\n' '#!/usr/bin/env bash' 'echo "stub codex must not be invoked by dry-run" >&2' 'exit 99' \
  > "$NORMAL_ENV_STUB/codex"
chmod +x "$NORMAL_ENV_STUB/codex"
RUN_SHIM_TOOLKIT="$REAL_ORCH_TOOLKIT" \
  run_shim "CODEX_REVIEW_CODEX_BIN=$NORMAL_ENV_STUB/codex" "PATH=$NORMAL_ENV_STUB:/usr/bin:/bin" \
  --base develop --dry-run
unset RUN_SHIM_TOOLKIT
if [ "$RUN_RC" -eq 0 ] && grep -q '^🏁 Dry run complete' "$WORK/out.log" \
  && ! grep -q 'WARNING: codex CLI' "$WORK/err.log"; then
  ok "AI CLI が居る通常環境（codex 本人）+ --dry-run（実オーケストレータ）: 従来どおり rc=0 でプランを出す"
else
  bad "通常環境（実オーケストレータ）の --dry-run が rc=0 でプランを出さない、または不要な警告が出た (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi

# 警告が案内する復旧手段（MULTI_AGENT_REVIEW_MAIN）が**このシム経由で実際に効く**こと。
# 上の「設定済み主 reviewer 不在（grok だけ）」fixture に env で主を grok-cli へ差し替えると、
# pair の主が居る形になってプランが rc=0 で出る。案内文が受け付けない --set-reviewers を
# 指していた退行（Issue 1600）は、案内どおりの操作が rc=2 で拒まれる形で現れるので、
# 「案内どおりに動かして復旧する」ところまでを固定する。
RUN_SHIM_CWD="$REAL_ORCH_REPO" RUN_SHIM_TOOLKIT="$REAL_ORCH_TOOLKIT" \
  run_shim CODEX_REVIEW_CODEX_BIN=/nonexistent/ff-codex-absent "PATH=$MAIN_ABSENT_ONLY:/usr/bin:/bin" \
    "XDG_CONFIG_HOME=$XDG_MAIN_CLAUDE" MULTI_AGENT_REVIEW_MAIN=grok-cli \
  --base develop --dry-run
unset RUN_SHIM_TOOLKIT
if [ "$RUN_RC" -eq 0 ] \
  && grep -q '^🏁 Dry run complete' "$WORK/out.log" \
  && grep -q '^   Mode: pair' "$WORK/err.log" \
  && grep -qE '^   grok-cli \[' "$WORK/out.log" \
  && ! grep -q "^ERROR: main reviewer" "$WORK/err.log"; then
  ok "codex 不在 + 主 reviewer 不在の fixture に、警告が案内する MULTI_AGENT_REVIEW_MAIN を付けると主が差し替わり rc=0 でプランが出る（案内どおりの復旧がシム経由で効く）"
else
  bad "警告が案内する MULTI_AGENT_REVIEW_MAIN がシム経由で効いていない（案内どおりに操作しても復旧しない） (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi

# CODEX_REVIEW_CODEX_BIN と委譲先の codex 検出が割れる回。シムの不在判定は env 由来だが、
# 委譲先はこの env を見ずに PATH の codex を独立に検出する。env に存在しない値が入ったまま
# PATH に codex が居ると、シムは「codex 不在」で --cli を外し、委譲先は同じ実行で codex を
# 「導入済み」と検出する（消費側で実測・Issue 1600）。このとき警告文の「外さないと
# Execution plan is empty」は当てはまらないので、判定が env 由来であることと委譲先の
# 検出結果が違うことを NOTE で明示する。NOTE はプランの中身（codex-cli が載るか）を
# 断定しない — pair の主が別 CLI に設定済みなら codex が居ても載らず、主が未導入なら
# プラン自体が出ない。判定そのものは env に残す — 委譲先に揃えると、PATH を絞らずに
# CODEX_REVIEW_CODEX_BIN=/nonexistent で不在を再現している上の stub ベースのケース
# （--base だけの rc=4 / --dry-run の --cli 落とし / --exclude-cli 併用 3 件）と registry
# 案内・--print-toolkit-root のケースが、ホストの codex 有無で結果が変わる形に戻る。
#
# この fixture は reviewers 未設定なので委譲先は分散へ縮退し、codex-cli が観点を引き受ける。
# `--cli codex-cli` が落ちたことは argv では測れない（実オーケストレータは ARGV_LOG を
# 書かないので argv.log は常に空で、否定針は無条件に緑）。落とさなかった回は --cli フィルタ
# で他 CLI の観点が「excluded by --cli filter」と除外されるので、その不在で測る。
RUN_SHIM_CWD="$REAL_ORCH_REPO" RUN_SHIM_TOOLKIT="$REAL_ORCH_TOOLKIT" \
  run_shim CODEX_REVIEW_CODEX_BIN=/nonexistent/ff-codex-absent "PATH=$NORMAL_ENV_STUB:/usr/bin:/bin" \
  --base develop --dry-run
unset RUN_SHIM_TOOLKIT
if [ "$RUN_RC" -eq 0 ] \
  && grep -q 'WARNING: codex CLI（/nonexistent/ff-codex-absent）が PATH にありませんが、--dry-run' "$WORK/err.log" \
  && grep -q 'NOTE: この不在判定は CODEX_REVIEW_CODEX_BIN（/nonexistent/ff-codex-absent）に基づくシム側のものです' "$WORK/err.log" \
  && grep -q '委譲先（multi-agent.sh）はこの env を見ず PATH の codex を独立に検出するため、委譲先から見ると codex は導入済みです' "$WORK/err.log" \
  && ! grep -q 'この回のプランには codex-cli が載ります' "$WORK/err.log" \
  && grep -q '^🏁 Dry run complete' "$WORK/out.log" \
  && grep -q '^   Mode: distributed' "$WORK/err.log" \
  && grep -qE '^   codex-cli \[' "$WORK/out.log" \
  && ! grep -q 'excluded by --cli filter' "$WORK/err.log"; then
  ok "CODEX_REVIEW_CODEX_BIN 不在 + PATH に codex あり + --dry-run（実オーケストレータ）: 判定が env 由来で委譲先は codex を導入済みと見ることを NOTE で明示し、プランの中身は断定しない"
else
  bad "CODEX_REVIEW_CODEX_BIN と委譲先の codex 検出が割れる回で、警告文が食い違いを明示していない、プランの中身を断定している、または --cli が残った (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi
# 同じ食い違いを --dry-run なしで踏むと、NOTE が予告するとおり env の指す実体が無いため
# rc=4 で止まり委譲しない（PATH に codex が居ても救わない）。NOTE は --dry-run 分岐だけの
# ものなので、この経路には出ない。上の「--base だけの rc=4」ケースはホスト PATH で走るため
# codex の無い CI ではこの食い違いを踏まない — PATH に stub codex を置いて固定する。
run_shim CODEX_REVIEW_CODEX_BIN=/nonexistent/ff-codex-absent "PATH=$NORMAL_ENV_STUB:/usr/bin:/bin" \
  --base develop
if [ "$RUN_RC" -eq 4 ] && [ ! -s "$WORK/argv.log" ] \
  && grep -q 'codex CLI（/nonexistent/ff-codex-absent）が PATH に無い' "$WORK/err.log" \
  && ! grep -q 'NOTE: この不在判定は CODEX_REVIEW_CODEX_BIN' "$WORK/err.log"; then
  ok "CODEX_REVIEW_CODEX_BIN 不在 + PATH に codex あり + 実行モード: NOTE の予告どおり rc=4 で止まり委譲しない（NOTE 自体は出ない）"
else
  bad "CODEX_REVIEW_CODEX_BIN 不在 + PATH に codex あり + 実行モードが rc=4 で止まらない、委譲した、または NOTE が出た (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/err.log" >&2
fi
# 割れていない回（PATH にも codex が無い）では NOTE を出さない。常時出すと「env 由来の判定」
# の注記が codex 本当に不在の環境でも付き、上の「外さないとプランが出ない」の説明を
# 自分で打ち消す形になる。
run_shim CODEX_REVIEW_CODEX_BIN=/nonexistent/ff-codex-absent "PATH=$OTHER_CLI_ONLY:/usr/bin:/bin" \
  --base develop --dry-run
if [ "$RUN_RC" -eq 0 ] \
  && grep -q 'WARNING: codex CLI（/nonexistent/ff-codex-absent）が PATH にありませんが、--dry-run' "$WORK/err.log" \
  && ! grep -q 'NOTE: この不在判定は CODEX_REVIEW_CODEX_BIN' "$WORK/err.log"; then
  ok "PATH にも codex が無い回は env 食い違いの NOTE を出さない（本当に不在の環境で説明を打ち消さない）"
else
  bad "PATH にも codex が無い回に env 食い違いの NOTE が出た、または警告自体が消えた (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/err.log" >&2
fi

# toolkit 未解決（sidecar も FF_DEV_TOOLKIT_ROOT も使えない）でも同じ降格案内を出す
RUN_SHIM_TOOLKIT="$WORK/no-such-toolkit" run_shim --base develop
unset RUN_SHIM_TOOLKIT
if [ "$RUN_RC" -ne 0 ] && grep -q 'multi-agent.sh がありません\|multi-agent.sh が見つかりません' "$WORK/err.log" \
  && grep -q 'クロスレビューを実行できないため Claude セルフレビュー' "$WORK/err.log" && [ ! -s "$WORK/argv.log" ]; then
  ok "toolkit 未解決: 従来の ERROR に加えて Claude セルフレビューへの降格案内を出し、非 0 で終わる"
else
  bad "toolkit 未解決: 降格案内が出ない、または委譲された (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi
# この経路の codex は在る（stub が PATH 相当で届いている）。見出しが「Codex 不在」と
# 決め打つと、**codex が入っている環境で codex を疑わせる**ことになり、切り分けを遅らせる
# だけでなく存在しない問題への起票を生む。
if grep -q 'Codex 不在' "$WORK/err.log"; then
  bad "toolkit 未解決の降格案内が原因を「Codex 不在」と誤って名指ししている"
  sed 's/^/    | /' "$WORK/err.log" >&2
else
  ok "toolkit 未解決: 降格案内の見出しが原因（Codex 不在）を誤指名しない"
fi
# 手順 1 は経路ごとに実行可能なものを出す。multi-agent.sh が見つからなかった経路で
# `multi-agent.sh --task review` を案内すると、**見つからなかったファイルの実行**を指示する
# ことになる（1 つの診断ブロックに検証済みの誤りが 2 件入る形）。
if grep -q 'multi-agent.sh --task review' "$WORK/err.log"; then
  bad "toolkit 未解決の案内が multi-agent.sh の実行を指示している（その経路では実行不能）"
  sed 's/^/    | /' "$WORK/err.log" >&2
else
  ok "toolkit 未解決: 実行不能な multi-agent.sh の手順を案内しない"
fi
# 手順 1 は **解決の rc ごと**に分ける。rc=2 は「FF_DEV_TOOLKIT_ROOT が在るのに使えない」で、
# 探索順は環境変数 → cache → サイドカーと**環境変数が最優先**。setup-multi-agent.sh が直すのは
# サイドカー側なので、rc=2 で setup を案内しても不正な環境変数が次回も先に勝ち、同じ rc=2 で
# 止まる。効かない手順を次の一手として渡すのは、この診断ブロックが直している欠陥
# （案内が次の一手にならない）と同じ形になる。上の run は RUN_SHIM_TOOLKIT で使えない root を
# FF_DEV_TOOLKIT_ROOT へ渡しているので rc=2 の経路。
if [ "$RUN_RC" -eq 2 ] && grep -q 'FF_DEV_TOOLKIT_ROOT を修正するか unset する' "$WORK/err.log" \
  && grep -qF "現在値: $WORK/no-such-toolkit" "$WORK/err.log" \
  && ! grep -q 'setup-multi-agent.sh を再実行して toolkit を配置し直す' "$WORK/err.log"; then
  ok "rc=2（FF_DEV_TOOLKIT_ROOT が不正）: 環境変数の修正 / 解除を案内し、効かない setup 再実行は出さない"
else
  bad "rc=2 の案内が環境変数を名指ししない、または効かない setup 再実行を案内している (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/err.log" >&2
fi
# rc=1（どこにも配置されていない）では setup-multi-agent.sh の再実行が唯一効く手順なので、
# 従来どおり案内すること。rc=2 側の針（上）と対で持つことで、「rc を見ずに一律案内へ戻す」
# 変異が必ずどちらかを赤にする。
RUN_SHIM_NO_ROOT=1 run_shim --base develop
unset RUN_SHIM_NO_ROOT
if [ "$RUN_RC" -eq 1 ] && [ ! -s "$WORK/argv.log" ] \
  && grep -q 'クロスレビューを実行できないため Claude セルフレビュー' "$WORK/err.log" \
  && grep -q 'setup-multi-agent.sh を再実行して toolkit を配置し直す' "$WORK/err.log" \
  && ! grep -q 'FF_DEV_TOOLKIT_ROOT を修正するか unset する' "$WORK/err.log"; then
  ok "rc=1（toolkit がどこにも無い）: 従来どおり setup-multi-agent.sh の再実行を案内する"
else
  bad "rc=1 の案内が setup 再実行を出していない、または環境変数の案内へ入れ替わっている (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/err.log" >&2
fi

# 降格案内が挙げる代替 CLI 候補は、委譲先（multi-agent.sh）の CLI registry から引くこと。
# 案内側へ候補名を直書きすると、既定ラインナップが変わっても案内だけが古いまま残り、
# 既定から外れている metered な CLI を勧め続ける（導入先の規約は課金系 reviewer への
# フォールバックを禁じている）。stub には**実体の registry 区間**を載せる — 写しを書くと
# 本体が変わっても stub だけ古いまま緑になる。
REGISTRY_TOOLKIT="$WORK/toolkit-with-registry"
cp -R "$TOOLKIT" "$REGISTRY_TOOLKIT"
_registry_block="$(awk '
  $0 == "# ── All known CLI names ──" { inside = 1 }
  inside { print }
  $0 == "# ── CLI Registry End ──" { exit }
' "$PLUGIN_ROOT/scripts/multi-agent.sh")"
# 抽出の健全性はパラメータ展開で見る（パイプ入力の grep -q は SIGPIPE で判定が反転する）
if [ -z "$_registry_block" ] || [ "${_registry_block#*ALL_CLIS=}" = "$_registry_block" ]; then
  bad "multi-agent.sh から CLI registry 区間を抽出できない（案内の候補導出が空振りする）"
else
  printf '%s\n' "$_registry_block" >> "$REGISTRY_TOOLKIT/scripts/multi-agent.sh"
  RUN_SHIM_TOOLKIT="$REGISTRY_TOOLKIT" \
    run_shim CODEX_REVIEW_CODEX_BIN=/nonexistent/ff-codex-absent --base develop
  unset RUN_SHIM_TOOLKIT
  # 期待値は suite 側で**別実装**（registry parser）から組む。シムと同じ awk を書き写すと、
  # 両方が同じようにずれたときに緑のままになる。
  # shellcheck disable=SC1090,SC1091 # runtime-checked repo-local shared helper
  . "$SCRIPT_DIR/../lib/cli-registry-parser.sh"
  if ! cli_registry_load "$PLUGIN_ROOT/scripts/multi-agent.sh"; then
    bad "multi-agent.sh の registry を静的解析できない（候補の突き合わせが成立しない）: ${CLI_REGISTRY_ERROR}"
  else
    # 照合は**候補行だけ**に閉じる。err.log 全体を見ると、解決ログや別の案内文に同じ名前が
    # 現れただけで「候補に載っている」と読んでしまう。
    _cand_line="$(grep -m1 '別 CLI（' "$WORK/err.log" || true)"
    _cand_missing=""
    _cand_unexpected=""
    _cand_checked=0
    for _cli in $ALL_CLIS; do
      # codex-cli は降格の原因そのもの。候補には出さない
      if [ "$_cli" = "codex-cli" ]; then
        continue
      fi
      if ! cli_registry_lookup get_cli_cost_tier "$_cli"; then
        bad "registry から ${_cli} の cost tier を引けない"
        continue
      fi
      _cand_checked=$((_cand_checked + 1))
      case "$_cand_line" in
        *"$_cli"*) _listed=1 ;;
        *)         _listed=0 ;;
      esac
      if [ "$REPLY" = "metered" ] && [ "$_listed" -eq 1 ]; then
        _cand_unexpected="${_cand_unexpected} ${_cli}"
      fi
      if [ "$REPLY" != "metered" ] && [ "$_listed" -eq 0 ]; then
        _cand_missing="${_cand_missing} ${_cli}"
      fi
    done
    if [ -z "$_cand_line" ]; then
      bad "降格案内に代替 CLI の候補行が無い（registry からの導出が届いていない）"
      sed 's/^/    | /' "$WORK/err.log" >&2
    elif [ "$_cand_checked" -eq 0 ]; then
      bad "候補の突き合わせ対象が 0 件（検査が空振りしている）"
    elif [ -n "$_cand_unexpected" ]; then
      bad "降格案内が metered な CLI を候補に挙げている:${_cand_unexpected}"
      sed 's/^/    | /' "$WORK/err.log" >&2
    elif [ -n "$_cand_missing" ]; then
      bad "降格案内に既定ラインナップの CLI が出ていない:${_cand_missing}（候補が直書きで drift している）"
      sed 's/^/    | /' "$WORK/err.log" >&2
    else
      ok "降格案内の代替 CLI 候補が委譲先の既定選定基準（metered 除外）と一致する（${_cand_checked} 件照合）"
    fi
  fi
fi

run_shim --fresh --base develop
if [ "$RUN_RC" -ne 0 ]; then
  bad "--fresh がシムに拒否された (rc=$RUN_RC) — 未対応オプション扱いになっている"
  sed 's/^/    | /' "$WORK/out.log" >&2
else
  ok "--fresh をシムが受け付ける"
fi
if argv_has --fresh && argv_has_seq "--base" "develop"; then
  ok "--fresh が --base より前でも委譲先へ届く"
else
  bad "--fresh が委譲先へ届いていない（後続フラグと併用できていない）"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

