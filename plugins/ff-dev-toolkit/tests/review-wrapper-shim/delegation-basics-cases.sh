#!/usr/bin/env bash
#
# review-wrapper-shim suite の検査ファイル（verify.sh から source される。単独実行不可）。
# 範囲: stub オーケストレータでの基本委譲（documented 用法の透過・codex 不在時の降格案内・--dry-run・終了コード表）。
# 依存: 親の stub toolkit（${PROJ} / ${TOOLKIT}）と run_shim / argv_has*。
# source 順は verify.sh の一覧が正本。fixture・関数・変数は同一プロセスで共有され、
# 後続ファイルは先行ファイルが作った fixture を参照するので、順序を入れ替えない。

echo "-- 振る舞い（stub オーケストレータで実測） --"

# 既定の documented 用法が素通しで届くこと
run_shim --base develop
if [ "$RUN_RC" -ne 0 ]; then
  bad "既定用法 (--base develop) が非 0 で終了した (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
else
  ok "既定用法 (--base develop) が成功する"
fi
if argv_has_seq "--task" "review" && argv_has_seq "--cli" "codex-cli"; then
  ok "task=review / cli=codex-cli が委譲先へ届く"
else
  bad "task=review / cli=codex-cli が委譲先へ届いていない"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi
if argv_has_seq "--base" "develop"; then
  ok "--base の値が委譲先へ届く"
else
  bad "--base の値が委譲先へ届いていない"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# codex 不在 → Claude セルフレビューへの降格を名指しし、レビュー未実施として非 0（4）で終わる
# （クラウド開発環境では codex が PATH に無いことがある）。委譲先は起動しない。
# 見出しは**理由に依存しない**文言であること。呼び出しは 2 経路あり、片方（toolkit 未解決）は
# codex とは無関係なので、「Codex 不在のため」と決め打つと原因の誤指名になる（導入先で実測）。
run_shim CODEX_REVIEW_CODEX_BIN=/nonexistent/ff-codex-absent --base develop
if [ "$RUN_RC" -eq 4 ] && grep -q 'クロスレビューを実行できないため Claude セルフレビュー（別コンテキストの reviewer サブエージェント）へ降格' "$WORK/err.log" \
  && grep -q 'codex CLI（/nonexistent/ff-codex-absent）が PATH に無い' "$WORK/err.log" \
  && grep -q 'reviewer サブエージェントを read-only で起動' "$WORK/err.log" \
  && ! grep -q 'クロスレビュー未実施' "$WORK/err.log" \
  && [ ! -s "$WORK/argv.log" ] && [ ! -s "$WORK/stdout.log" ]; then
  ok "codex 不在: Claude セルフレビューへの降格を stderr に明示し、委譲せず rc=4 で終わる"
else
  bad "codex 不在: 降格の明示 / 非委譲 / rc=4 のいずれかが崩れている (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi

# --dry-run は CLI を 1 本も起動しないので、codex 実在検査でシムが握りつぶさず委譲すること
# （rc=4 で止めない）。さらに **固定の --cli codex-cli をこの回だけ外す**ことまで固定する。
# 外さないと、codex-cli の観点の fallback 再割り当てが --cli フィルタに弾かれて実行対象
# 0 件になり、素通りさせた意味がそのまま打ち消される。
#
# 判定は **委譲が現に起きたところ**まで見る。rc=0 と `--dry-run` の 1 行だけだと、stub が
# 無条件に rc=0 を返す以上「シムが rc=4 で止めなかった」ことしか言えず、委譲先を exec せずに
# 自前で rc=0 を返す実装も同じく緑になる。stub の標準出力（委譲先が現に走った印）と、
# 委譲の中核契約（--task review）・利用者が渡した引数（--base develop / --dry-run）が
# 引数列に保たれていること、そして --cli codex-cli が**落ちていること**を揃えて見る。
run_shim CODEX_REVIEW_CODEX_BIN=/nonexistent/ff-codex-absent --base develop --dry-run
if [ "$RUN_RC" -eq 0 ] && grep -q 'stub orchestrator ran' "$WORK/stdout.log" \
  && argv_has_seq "--task" "review" && ! argv_has_seq "--cli" "codex-cli" \
  && argv_has_seq "--base" "develop" && argv_has --dry-run \
  && grep -q 'WARNING: codex CLI（/nonexistent/ff-codex-absent）が PATH にありませんが、--dry-run' "$WORK/err.log" \
  && grep -q '固定の --cli codex-cli を外して委譲します' "$WORK/err.log" \
  && ! grep -q 'へ降格します' "$WORK/err.log"; then
  ok "codex 不在の --dry-run は rc=4 で止めず、固定の --cli codex-cli を外して委譲する（他の引数は保たれる）"
else
  bad "codex 不在の --dry-run がシム側で rc=4 に落ちている、委譲先を起動していない、--cli codex-cli が残っている、または他の委譲引数が欠けた (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
  sed 's/^/    argv| /' "$WORK/argv.log" >&2
fi

# 外す条件は「--dry-run かつ codex 不在」に閉じている。codex が居る --dry-run では固定の
# --cli codex-cli が**残る**こと（このシムが codex 用であることの中核契約）を同じ stub で
# 測る。上のケースだけだと「常に外す」実装も緑になり、シムの位置づけごと壊れる。
run_shim --base develop --dry-run
if [ "$RUN_RC" -eq 0 ] && argv_has_seq "--task" "review" && argv_has_seq "--cli" "codex-cli" \
  && argv_has --dry-run \
  && ! grep -q 'WARNING: codex CLI' "$WORK/err.log"; then
  ok "codex が居る --dry-run では固定の --cli codex-cli が残る（外す条件は codex 不在に閉じている）"
else
  bad "codex が居る --dry-run で --cli codex-cli が落ちている、または不要な警告が出た (rc=$RUN_RC)"
  sed 's/^/    argv| /' "$WORK/argv.log" >&2
fi
# 先頭の終了コード表に 4 が載っていること。載っていないと「その他 = 委譲先の終了コード」が
# 嘘になり、呼び出し側が 4 を委譲先の rc と読む
if grep -qE '^#[[:space:]]+4 = ' "$SHIM"; then
  ok "終了コード表に 4（codex 不在）が載っている"
else
  bad "終了コード表に 4 が無い（「その他 = 委譲先の終了コードをそのまま返す」が嘘になる）"
fi
# codex 不在環境の --dry-run が終了コード表に載っていること。**帰結が 2 通りに分かれる**ので、
# 両方が載っていることを別々に固定する:
#   ・codex だけが不在            → 固定の --cli codex-cli を外して委譲するので rc=0 でプランが出る
#   ・AI CLI が 1 本も PATH に無い → 委譲先の CLI 検出が No AI CLIs are installed で止まり rc=1
# 片方だけを書くと、もう片方を踏んだ利用者が原因を取り違える。さらに、プランが出る側では
# 「出たプラン = このシムを実行したときに走るもの」と読める案内が危険なので（実行は codex 不在で
# rc=4 のまま）、その食い違いが表に書かれていることも固定する。
# 抽出は終了コード表の区間だけに閉じる。ファイル全体を grep すると、下の実行時 WARNING
# （codex 不在時に出す文言）にも同じ語句が現れるため、そちらだけが残っていても
# ヘッダーの記載漏れを見逃す（実測: ヘッダーを旧文言へ戻す変異が緑のまま通った）。
# 照合は case で行う。`printf | grep -q` は grep が先に閉じるので pipefail 下で
# SIGPIPE により rc が反転しうる（このリポジトリの run-all case 10 が禁止している形）。
_exitcode_doc="$(awk '/^#[[:space:]]+終了コード: 0 = /{f=1} f{print} /^#[[:space:]]+\*\*リテラル/{exit}' "$SHIM")"
case "$_exitcode_doc" in
  *'その他 = '*'AI CLI が 1 本も PATH に無い'*'rc=1'*'No AI CLIs are installed'*)
    ok "終了コード表に AI CLI ゼロ時の rc=1（No AI CLIs are installed）が載っている" ;;
  *)
    bad "終了コード表が AI CLI ゼロ時の rc=1 を案内していない" ;;
esac
case "$_exitcode_doc" in
  *'その他 = '*'pair 主 reviewer'*'導入済み'*'rc=0'*'--cli codex-cli'*'外して'*)
    ok "終了コード表に codex 不在 + pair 主 reviewer 導入済み時の rc=0（--cli を外してプランを出す）が載っている" ;;
  *)
    bad "終了コード表が codex 不在 + pair 主 reviewer 導入済み時の rc=0 を案内していない（rc=1 のままの案内は実態と食い違う）" ;;
esac
case "$_exitcode_doc" in
  *'このシムを --dry-run なしで実行したときの'*)
    ok "終了コード表が「出たプラン ≠ このシムの実行結果」を明記している" ;;
  *)
    bad "終了コード表がプランと実行の食い違いを書いていない（プランが出たことを実行可能と読める）" ;;
esac
# rc=0 になるのは「設定済みの主 reviewer が導入済み」か「主 reviewer 未設定（分散へ縮退）」の
# 2 構成。設定済みの主が居ない構成（例: 主=claude-code のまま grok だけ）は rc=1 で別の
# エラーになるので、「codex 以外が 1 本でもあれば rc=0」とも「grok だけなら常に rc=1」とも
# 読める案内にしない（前者の読み方をした利用者は No AI CLIs are installed を探して見つけ
# られず、後者は Issue 1599 で CI が rc=0 を実測した形と食い違う）。
case "$_exitcode_doc" in
  *'pair 主 reviewer も導入されていない'*'main reviewer'*'is not installed'*)
    ok "終了コード表に pair 主 reviewer 不在時の rc=1（main reviewer is not installed）が載っている" ;;
  *)
    bad "終了コード表が pair 主 reviewer 不在時の rc=1 を案内していない（codex 以外が 1 本あれば rc=0 と読める）" ;;
esac
# 主 reviewer 未設定時の分散縮退（rc=0）も表に載っていること。実行時 WARNING 側は下の
# 実オーケストレータ経由のケースが測るが、区間を閉じたこの抽出で見ないと、ヘッダーを
# 「3 通り」へ戻して未設定の行を消す変異が WARNING だけを残して緑のまま通る。
case "$_exitcode_doc" in
  *'主 reviewer が**未設定**'*'rc=0'*'No reviewers configured'*)
    ok "終了コード表に主 reviewer 未設定時の rc=0（分散縮退）が載っている" ;;
  *)
    bad "終了コード表が主 reviewer 未設定時の rc=0（No reviewers configured → 分散縮退）を案内していない" ;;
esac

