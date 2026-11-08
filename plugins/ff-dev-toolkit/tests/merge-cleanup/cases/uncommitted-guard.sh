# shellcheck shell=bash
# pipefail-inherited: verify.sh が set -euo pipefail の下で source する
# 項目 32: 未コミット変更ガードのパス除外
#
# verify.sh から source される（ok / bad / TMP / TARGET / MOCK / PLUGIN_ROOT / SCRIPT_DIR を共有）。
# 読む順序は verify.sh の一覧が正本で、前の cases の fixture と関数を後ろの cases が使う（Issue `#2697`）。

# ---- 32. 未コミット変更ガードのパス除外（FF_MERGE_CLEANUP_IGNORE_PATHS）--------
#
# 常駐ツールが同じパスを書き続けるリポジトリでは作業ツリーが dirty なのが定常状態で、
# Step 1 のガードが「異常の検出」ではなく「必ず発火する障害」になる（公開 Issue `#14`）。
# ここまでの run により、呼び出し元は ${CALLER}（develop 保持）、${BASE_OWNER} は detached。
#
# 本セクションは終端に置く。32.8 は dirty な worktree（wt-40）と
# feature/#40-wt-ignored-dirty を意図的に残し、32.11 は origin/develop を
# ローカルより進めたまま終わるため、後続セクションを足すならその前に置くこと。
# 32.12（完走を期待する）は同じ理由で 32.11 より前に置いてある。

echo ""
echo "== 未コミット変更ガードのパス除外 =="

# 常駐ツールが書く追跡ファイルを 1 つ用意する（未追跡ディレクトリだけの fixture だと、
# 追跡ファイル側の除外が壊れても緑のままになる）。
# fixture の push は pre-push hook 契約の検証対象ではないので --no-verify で通す。
mkdir -p "$CALLER/videos/tracked"
echo baseline > "$CALLER/videos/tracked/spec.md"
git -C "$CALLER" add videos/tracked/spec.md
git -C "$CALLER" commit -qm "add resident-tool tracked file"
git -C "$CALLER" push -q --no-verify origin develop

make_ignorable_dirt() {
  # $1: worktree path。除外対象（videos/ と .cache/ 配下）だけの dirty を作る。
  # 追跡ファイルの変更と未追跡ディレクトリの両方を含める（報告された実データと同じ形）。
  # SKILL.md が主用例として挙げる複数パターン指定を実行させるため、2 つ目の
  # ディレクトリも汚す（単一パターンだけだと 2 要素目の取りこぼしを検出できない）。
  echo "resident tool wrote this" >> "$1/videos/tracked/spec.md"
  mkdir -p "$1/videos/slug-new"
  echo generated > "$1/videos/slug-new/spec.md"
  mkdir -p "$1/.cache/run"
  echo cached > "$1/.cache/run/state.json"
}

clear_ignorable_dirt() {
  # $1: worktree path。後続ケースは「dirt が消えている」ことを前提に組むので、
  # 失敗を握りつぶさない（黙って前提が崩れると、除外パス内の dirt では緑のまま進む）
  git -C "$1" checkout -- videos/tracked/spec.md
  rm -rf "$1/videos/slug-new" "$1/.cache"
}

IGNORE_BOTH='videos/**:.cache/**'

exit_is_complete() {
  # $1: 終了コード。0（完全成功）と 2（PARTIAL）だけを「Step 1 を通過して完走した」
  # とみなす。`-ne 1` だと 127（コマンド不在）等まで成功に見える
  [ "$1" -eq 0 ] || [ "$1" -eq 2 ]
}

# self-test: fixture が「ガードが無ければ確実に中断する」内容になっていること。
# ここが clean だと、以降の「通過した」は除外が効いた証拠にならない。
make_ignorable_dirt "$CALLER"
if [ -n "$(git -C "$CALLER" status --porcelain)" ]; then
  ok "fixture が dirty である（self-test）"
else
  bad "fixture が dirty でない — 以降のパス除外の検証は無意味"
fi

# 32.6 未設定なら現行どおり中断する（除外機能の追加で既定挙動が変わらないこと）
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-ignore-unset.log" 2>&1
EXIT_IGNORE_UNSET=$?
set -e
if [ "$EXIT_IGNORE_UNSET" -eq 1 ] \
  && grep -q "未コミットの変更があります" "$TMP/run-ignore-unset.log"; then
  ok "FF_MERGE_CLEANUP_IGNORE_PATHS 未設定なら現行どおり dirty で中断する"
else
  bad "未設定時の挙動が変わっている (exit=$EXIT_IGNORE_UNSET)"
fi

# 32.10 空文字列は「未設定」と同じ扱い（32.3 の「空パターンは die」と衝突しない）。
#       .claude/settings.json の env へ書く運用では値を空にする書き方が実際に起こる
set +e
FF_MERGE_CLEANUP_IGNORE_PATHS='' \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-ignore-emptyvar.log" 2>&1
EXIT_IGNORE_EMPTYVAR=$?
set -e
if [ "$EXIT_IGNORE_EMPTYVAR" -eq 1 ] \
  && grep -q "未コミットの変更があります" "$TMP/run-ignore-emptyvar.log" \
  && ! grep -q "空のパターン" "$TMP/run-ignore-emptyvar.log"; then
  ok "空文字列の指定は未設定と同じ扱いで、空パターンの die にはしない"
else
  bad "空文字列指定の扱いが期待どおりでない (exit=$EXIT_IGNORE_EMPTYVAR)"
fi

# 32.1 除外パスだけが dirty なら Step 1 を通過し、無視した変更を件数と一覧で報告する。
#      パターンは 2 つ指定し、両方が効くこと（2 要素目を取りこぼさないこと）を見る
set +e
FF_MERGE_CLEANUP_IGNORE_PATHS="$IGNORE_BOTH" \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-ignore-all.log" 2>&1
EXIT_IGNORE_ALL=$?
set -e
if exit_is_complete "$EXIT_IGNORE_ALL" \
  && grep -q "マージ後 Cleanup 結果" "$TMP/run-ignore-all.log" \
  && grep -q "ガード対象外として無視した未コミット変更: 3 件" "$TMP/run-ignore-all.log" \
  && grep -q "videos/tracked/spec.md" "$TMP/run-ignore-all.log" \
  && grep -q "videos/slug-new/" "$TMP/run-ignore-all.log" \
  && grep -q "\.cache/" "$TMP/run-ignore-all.log"; then
  ok "複数パターンの除外パスだけが dirty なら Step 1 を通過し、無視した変更を列挙する"
else
  bad "除外パスだけの dirty で cleanup が完走しない (exit=$EXIT_IGNORE_ALL)"
fi

# 32.2 除外外の dirty が 1 つでもあれば従来どおり中断し、対象外のパスだけを列挙する。
#      中断メッセージは「設定できます」ではなく「一致していません」に切り替わること
echo resident-config > "$CALLER/pipeline.config.slideshow.json"
set +e
FF_MERGE_CLEANUP_IGNORE_PATHS="$IGNORE_BOTH" \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-ignore-partial.log" 2>&1
EXIT_IGNORE_PARTIAL=$?
set -e
if [ "$EXIT_IGNORE_PARTIAL" -eq 1 ] \
  && grep -q "未コミットの変更があります" "$TMP/run-ignore-partial.log" \
  && grep -q "pipeline.config.slideshow.json" "$TMP/run-ignore-partial.log" \
  && grep -q "上の変更はこの指定に一致していません" "$TMP/run-ignore-partial.log" \
  && ! grep -qE '^[ MARCDU?]{2} videos/' "$TMP/run-ignore-partial.log"; then
  ok "除外外の dirty があれば中断し、中断一覧に除外済みのパスを混ぜない"
else
  bad "部分一致時の中断が期待どおりでない (exit=$EXIT_IGNORE_PARTIAL)"
fi
rm -f "$CALLER/pipeline.config.slideshow.json"

# 32.9 指定はあるが 1 件も一致しない場合、黙って従来どおり中断せず、
#      一致が無い事実を出す（設定ミスが「何も変わらない」に見えるのを防ぐ）
set +e
FF_MERGE_CLEANUP_IGNORE_PATHS='no-such-dir/**' \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-ignore-nomatch.log" 2>&1
EXIT_IGNORE_NOMATCH=$?
set -e
if [ "$EXIT_IGNORE_NOMATCH" -eq 1 ] \
  && grep -q "一致する未コミット変更はありません" "$TMP/run-ignore-nomatch.log" \
  && ! grep -q "ガード対象外として無視した未コミット変更" "$TMP/run-ignore-nomatch.log" \
  && grep -q "未コミットの変更があります" "$TMP/run-ignore-nomatch.log"; then
  ok "一致 0 件のときは「0 件」の空報告ではなく、一致が無い事実を出して中断する"
else
  bad "一致 0 件時の扱いが期待どおりでない (exit=$EXIT_IGNORE_NOMATCH)"
fi

# 32.3 空要素はガードを無効化する（空パターンは pathspec 全体を除外する）。
#      「無効化する指定」として中断すること。dirty のまま素通りさせない
set +e
FF_MERGE_CLEANUP_IGNORE_PATHS='videos/**:' \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-ignore-empty.log" 2>&1
EXIT_IGNORE_EMPTY=$?
set -e
if [ "$EXIT_IGNORE_EMPTY" -eq 1 ] \
  && grep -q "空のパターン" "$TMP/run-ignore-empty.log" \
  && ! grep -q "マージ後 Cleanup 結果" "$TMP/run-ignore-empty.log"; then
  ok "空要素を含む指定は「ガード無効化」として中断する"
else
  bad "空要素の扱いが期待どおりでない (exit=$EXIT_IGNORE_EMPTY)"
fi

# 32.3b 前後に空白の付いたパターンは何にも一致しない。空パターンと同じく明示的に弾く
set +e
FF_MERGE_CLEANUP_IGNORE_PATHS='videos/**: .cache/**' \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-ignore-space.log" 2>&1
EXIT_IGNORE_SPACE=$?
set -e
if [ "$EXIT_IGNORE_SPACE" -eq 1 ] \
  && grep -q "前後の空白があります" "$TMP/run-ignore-space.log" \
  && ! grep -q "マージ後 Cleanup 結果" "$TMP/run-ignore-space.log"; then
  ok "前後に空白の付いたパターンは中断する"
else
  bad "空白付きパターンの扱いが期待どおりでない (exit=$EXIT_IGNORE_SPACE)"
fi

# 32.4 先頭 ':' を持つ pathspec magic の直書きは、空要素として中断する。
#      「magic を検出したから」ではないので、die の理由が空パターンであることまで見る
set +e
FF_MERGE_CLEANUP_IGNORE_PATHS=':(exclude)videos' \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-ignore-magic.log" 2>&1
EXIT_IGNORE_MAGIC=$?
set -e
if [ "$EXIT_IGNORE_MAGIC" -eq 1 ] \
  && grep -q "空のパターンがあります" "$TMP/run-ignore-magic.log" \
  && ! grep -q "マージ後 Cleanup 結果" "$TMP/run-ignore-magic.log"; then
  ok "先頭 ':' の pathspec magic 直書きは空パターンとして中断する"
else
  bad "pathspec magic 直書きの扱いが期待どおりでない (exit=$EXIT_IGNORE_MAGIC)"
fi

# 32.4b 中間位置の magic は空要素を作らないため中断せず、リテラルとして扱われる
#       （= 何にも一致しない）。文書が主張する境界を実挙動で固定する
set +e
FF_MERGE_CLEANUP_IGNORE_PATHS='videos/**:(exclude)tmp:.cache/**' \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-ignore-midmagic.log" 2>&1
EXIT_IGNORE_MIDMAGIC=$?
set -e
if exit_is_complete "$EXIT_IGNORE_MIDMAGIC" \
  && ! grep -q "空のパターンがあります" "$TMP/run-ignore-midmagic.log" \
  && grep -q "ガード対象外として無視した未コミット変更: 3 件" "$TMP/run-ignore-midmagic.log"; then
  ok "中間位置の magic は中断せずリテラル扱いになる（前後の実パターンだけが効く）"
else
  bad "中間位置 magic の扱いが期待どおりでない (exit=$EXIT_IGNORE_MIDMAGIC)"
fi

# 32.4c 全パスに一致するパターンはガードを事実上無効化する。中断はしないが、
#       その事実を実行ログへ残す（黙って無効化しない）
set +e
FF_MERGE_CLEANUP_IGNORE_PATHS='**' \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-ignore-catchall.log" 2>&1
EXIT_IGNORE_CATCHALL=$?
set -e
if exit_is_complete "$EXIT_IGNORE_CATCHALL" \
  && grep -q "未コミット変更ガードを事実上無効化します" "$TMP/run-ignore-catchall.log"; then
  ok "全パスに一致するパターンは、無効化される事実をログへ残す"
else
  bad "全一致パターンの扱いが期待どおりでない (exit=$EXIT_IGNORE_CATCHALL)"
fi

# 32.5 除外を適用した git status が失敗したら「変更なし」とみなさず中断する。
#      ここが fail-open だと、dirty な作業ツリーでガードが素通りする
: > "$TMP/statusfail-guard.enabled"
set +e
FF_MERGE_CLEANUP_IGNORE_PATHS='videos/**' \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-ignore-statusfail.log" 2>&1
EXIT_IGNORE_STATUSFAIL=$?
set -e
rm -f "$TMP/statusfail-guard.enabled"
if [ "$EXIT_IGNORE_STATUSFAIL" -eq 1 ] \
  && grep -q "未コミット変更の確認に失敗" "$TMP/run-ignore-statusfail.log" \
  && ! grep -q "マージ後 Cleanup 結果" "$TMP/run-ignore-statusfail.log"; then
  ok "除外を適用した git status の失敗を「変更なし」とみなさない"
else
  bad "git status 失敗時の扱いが期待どおりでない (exit=$EXIT_IGNORE_STATUSFAIL)"
fi

# 32.5b 報告用（肯定形 pathspec）の status だけが失敗する経路。ガード側は成功するので、
#       ここを別に落とさないと一覧取得の die へ一度も到達しない
: > "$TMP/statusfail-ignored.enabled"
set +e
FF_MERGE_CLEANUP_IGNORE_PATHS='videos/**' \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-ignore-listfail.log" 2>&1
EXIT_IGNORE_LISTFAIL=$?
set -e
rm -f "$TMP/statusfail-ignored.enabled"
if [ "$EXIT_IGNORE_LISTFAIL" -eq 1 ] \
  && grep -q "一覧取得に失敗" "$TMP/run-ignore-listfail.log" \
  && ! grep -q "マージ後 Cleanup 結果" "$TMP/run-ignore-listfail.log"; then
  ok "無視した変更の一覧取得だけが失敗した場合も中断する"
else
  bad "一覧取得失敗時の扱いが期待どおりでない (exit=$EXIT_IGNORE_LISTFAIL)"
fi

# 32.5c 除外「未設定」の素の status が失敗する経路。既定運用がこちらなので、
#       pathspec 付きだけを落としていると本命の回帰を取り逃がす
: > "$TMP/statusfail-plain.enabled"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-ignore-plainfail.log" 2>&1
EXIT_IGNORE_PLAINFAIL=$?
set -e
rm -f "$TMP/statusfail-plain.enabled"
if [ "$EXIT_IGNORE_PLAINFAIL" -eq 1 ] \
  && grep -q "未コミット変更の確認に失敗" "$TMP/run-ignore-plainfail.log" \
  && ! grep -q "マージ後 Cleanup 結果" "$TMP/run-ignore-plainfail.log"; then
  ok "除外未設定でも git status の失敗を「変更なし」とみなさない"
else
  bad "未設定時の status 失敗の扱いが期待どおりでない (exit=$EXIT_IGNORE_PLAINFAIL)"
fi

# 32.5e stderr へ何も出さずに status が失敗した場合、理由なしで終了せず
#       「詳細不明」の診断を出して中断する（guard_status_error_text の fallback）
: > "$TMP/statusfail-silent.enabled"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-ignore-silentfail.log" 2>&1
EXIT_IGNORE_SILENTFAIL=$?
set -e
rm -f "$TMP/statusfail-silent.enabled"
if [ "$EXIT_IGNORE_SILENTFAIL" -eq 1 ] \
  && grep -q "未コミット変更の確認に失敗しました" "$TMP/run-ignore-silentfail.log" \
  && grep -q "詳細不明" "$TMP/run-ignore-silentfail.log" \
  && ! grep -q "マージ後 Cleanup 結果" "$TMP/run-ignore-silentfail.log"; then
  ok "stderr の無い status 失敗でも、詳細不明の診断を出して中断する"
else
  bad "無言の status 失敗の扱いが期待どおりでない (exit=$EXIT_IGNORE_SILENTFAIL)"
fi

clear_ignorable_dirt "$CALLER"

# 32.7 base を保持する別 worktree の dirty が除外パスだけなら、退避して続行する。
#      Step 1 だけを緩めて Step 3 を据え置くと、除外を設定したユーザーが別の
#      dirty ガードで止まり「効いていない」と読める（緩和指定の一貫性。
#      Step 5 だけは通すとファイルが実際に消えるため意図的に対象外のまま）
git -C "$CALLER" switch -q --detach
git -C "$BASE_OWNER" switch -q develop
git -C "$BASE_OWNER" pull -q --ff-only origin develop
make_ignorable_dirt "$BASE_OWNER"
set +e
FF_MERGE_CLEANUP_IGNORE_PATHS="$IGNORE_BOTH" \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-ignore-baseowner.log" 2>&1
EXIT_IGNORE_BASEOWNER=$?
set -e
if exit_is_complete "$EXIT_IGNORE_BASEOWNER" \
  && grep -q "マージ後 Cleanup 結果" "$TMP/run-ignore-baseowner.log" \
  && grep -q "ガード対象外として無視した未コミット変更: 3 件.*$BASE_OWNER" "$TMP/run-ignore-baseowner.log" \
  && [ -z "$(git -C "$BASE_OWNER" branch --show-current)" ] \
  && [ -f "$BASE_OWNER/videos/slug-new/spec.md" ] \
  && [ "$(git -C "$CALLER" branch --show-current)" = "develop" ]; then
  ok "base 所有 worktree の dirty が除外パスだけなら退避して続行し、無視した変更を報告する"
else
  bad "base 所有 worktree の除外が期待どおりでない (exit=$EXIT_IGNORE_BASEOWNER)"
fi
clear_ignorable_dirt "$BASE_OWNER"

# 32.7b base 所有 worktree に除外外の dirty があれば、除外指定があっても中断する。
#       32.7 だけだと「Step 3 の status が常に空を返す」退行を検出できない
git -C "$CALLER" switch -q --detach
git -C "$BASE_OWNER" switch -q develop
make_ignorable_dirt "$BASE_OWNER"
echo resident-config > "$BASE_OWNER/pipeline.config.slideshow.json"
set +e
FF_MERGE_CLEANUP_IGNORE_PATHS="$IGNORE_BOTH" \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-ignore-basepartial.log" 2>&1
EXIT_IGNORE_BASEPARTIAL=$?
set -e
if [ "$EXIT_IGNORE_BASEPARTIAL" -eq 1 ] \
  && grep -q "base ブランチの退避と cleanup を中断" "$TMP/run-ignore-basepartial.log" \
  && grep -q "pipeline.config.slideshow.json" "$TMP/run-ignore-basepartial.log" \
  && [ "$(git -C "$BASE_OWNER" branch --show-current)" = "develop" ] \
  && [ -f "$BASE_OWNER/videos/slug-new/spec.md" ]; then
  ok "base 所有 worktree の除外外 dirty は、除外指定があっても中断する"
else
  bad "base 所有 worktree の部分一致が期待どおりでない (exit=$EXIT_IGNORE_BASEPARTIAL)"
fi
rm -f "$BASE_OWNER/pipeline.config.slideshow.json"

# 32.7c base 所有 worktree の status が exit 0 でも stderr に警告を出したら中断する。
#       旧実装は 2>&1 で警告を status 出力へ混ぜて中断していた（fail-closed）。
#       stderr を分離した結果その判定が消えると、走査が不完全なまま detach へ進む
: > "$TMP/statuswarn-basewt.enabled"
set +e
FF_MERGE_CLEANUP_IGNORE_PATHS="$IGNORE_BOTH" \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-ignore-basewarn.log" 2>&1
EXIT_IGNORE_BASEWARN=$?
set -e
rm -f "$TMP/statuswarn-basewt.enabled"
# mock の警告は Step 1（-C ""）にも当たる。Step 1 は警告を出して続行し、
# Step 3 で中断した、と両方の証跡で特定する（exit 1 だけだと「Step 1 が
# 警告で die する退行」でも緑になり、Step 3 の中断を検証したことにならない）
if [ "$EXIT_IGNORE_BASEWARN" -eq 1 ] \
  && grep -q "⚠️ git status が警告を出しました" "$TMP/run-ignore-basewarn.log" \
  && grep -q "を保持する worktree の status が警告を出しました" "$TMP/run-ignore-basewarn.log" \
  && grep -q "作業ツリーを完全に走査できていない可能性" "$TMP/run-ignore-basewarn.log" \
  && [ "$(git -C "$BASE_OWNER" branch --show-current)" = "develop" ]; then
  ok "base 所有 worktree の status が警告を出したら、exit 0 でも中断する（Step 1 は続行）"
else
  bad "base 所有 worktree の警告時の扱いが期待どおりでない (exit=$EXIT_IGNORE_BASEWARN)"
fi
clear_ignorable_dirt "$BASE_OWNER"

# 32.7d base 所有 worktree のガード status だけが失敗する経路。Step 1 は -C "" で
#       呼ぶため素通りし、Step 3 の die に直接到達する（32.5 系は Step 1 が先に
#       落ちるため、この die は一度も実行されない）
: > "$TMP/statusfail-basewt.enabled"
set +e
FF_MERGE_CLEANUP_IGNORE_PATHS="$IGNORE_BOTH" \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-ignore-basefail.log" 2>&1
EXIT_IGNORE_BASEFAIL=$?
set -e
rm -f "$TMP/statusfail-basewt.enabled"
if [ "$EXIT_IGNORE_BASEFAIL" -eq 1 ] \
  && grep -q "を保持する worktree の状態取得に失敗しました" "$TMP/run-ignore-basefail.log" \
  && ! grep -q "マージ後 Cleanup 結果" "$TMP/run-ignore-basefail.log" \
  && [ "$(git -C "$BASE_OWNER" branch --show-current)" = "develop" ]; then
  ok "base 所有 worktree の status 失敗は Step 3 で中断し、detach しない"
else
  bad "base 所有 worktree の status 失敗の扱いが期待どおりでない (exit=$EXIT_IGNORE_BASEFAIL)"
fi

# 呼び出し元を develop へ戻す（32.7 系で detach したまま 32.8 へ進むと、
# 失敗の理由が「除外が壊れた」なのか「前提が崩れた」なのか読めなくなる）
git -C "$BASE_OWNER" switch -q --detach
git -C "$CALLER" switch -q develop
if [ "$(git -C "$CALLER" branch --show-current)" = "develop" ] \
  && [ -z "$(git -C "$BASE_OWNER" branch --show-current)" ]; then
  ok "32.8 の前提（呼び出し元が develop 保持・base 所有は detached）が成立している"
else
  bad "32.8 の前提が崩れている — 以降の判定は信用しないこと"
fi

# 32.8 worktree 削除（Step 5）は除外指定の対象外。削除はファイルを実際に失うため、
#      同じ環境変数で緩めない
add_clean_gone_worktree 'feature/#40-wt-ignored-dirty' "$TMP/wt-40"
mkdir -p "$TMP/wt-40/videos/slug-x"
echo resident > "$TMP/wt-40/videos/slug-x/spec.md"
# 呼び出し元も除外パスだけで dirty にする。ここを clean にすると、環境変数が
# まったく効いていない実装でもこのケースが緑になり、境界の証拠にならない
make_ignorable_dirt "$CALLER"
set +e
FF_MERGE_CLEANUP_IGNORE_PATHS="$IGNORE_BOTH" \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-ignore-wt.log" 2>&1
EXIT_IGNORE_WT=$?
set -e
if [ "$EXIT_IGNORE_WT" -eq 2 ] \
  && [ -d "$TMP/wt-40" ] \
  && git show-ref -q "refs/heads/feature/#40-wt-ignored-dirty" \
  && grep -q "feature/#40-wt-ignored-dirty: worktree に未コミット変更あり" "$TMP/run-ignore-wt.log"; then
  ok "worktree 削除は除外指定の対象外で、dirty な worktree を保護する"
else
  bad "worktree 削除が除外指定で緩んでいる (exit=$EXIT_IGNORE_WT)"
fi
clear_ignorable_dirt "$CALLER"

# 32.12 作業ブランチ上に除外対象の変更を残したまま cleanup を実行するケース。
#       Issue `#758` / `#749` 以降、base でも PR head でもないブランチは**切り替えずに**
#       掃除だけ完走する（他セッションの作業ブランチを勝手に switch しない契約）。
#       除外対象の変更が消えたり、実行が予期せず止まったりしないことは従来どおり見る。
git -C "$CALLER" switch -q -c work-branch-41 develop
make_ignorable_dirt "$CALLER"
set +e
FF_MERGE_CLEANUP_IGNORE_PATHS="$IGNORE_BOTH" \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-ignore-frombranch.log" 2>&1
EXIT_IGNORE_FROMBRANCH=$?
set -e
if exit_is_complete "$EXIT_IGNORE_FROMBRANCH" \
  && grep -q "マージ後 Cleanup 結果" "$TMP/run-ignore-frombranch.log" \
  && grep -q "HEAD を変更しないため" "$TMP/run-ignore-frombranch.log" \
  && [ "$(git -C "$CALLER" branch --show-current)" = "work-branch-41" ] \
  && grep -q "resident tool wrote this" "$CALLER/videos/tracked/spec.md" \
  && [ -f "$CALLER/videos/slug-new/spec.md" ]; then
  ok "作業ブランチからの実行では switch せずに完走し、除外対象の変更を保持する"
else
  bad "作業ブランチからの実行が期待どおりでない (exit=$EXIT_IGNORE_FROMBRANCH)"
fi
clear_ignorable_dirt "$CALLER"
git -C "$CALLER" switch -q develop
git -C "$CALLER" branch -q -D work-branch-41

# 32.11 「除外したパスが本当に cleanup を妨げるなら git 自身が失敗して中断する」という、
#       Step 1 を緩めてよい根拠そのものを実測する。除外パス内の追跡ファイルが
#       base 側でも進んでいれば pull --ff-only が拒否し、cleanup は中断する
git clone -q "$TMP/origin.git" "$TMP/pusher"
ff_git_fixture_init "$TMP/pusher" "merge-cleanup-test" "test@example.com"
git -C "$TMP/pusher" config commit.gpgsign false
git -C "$TMP/pusher" switch -q develop
echo "upstream edit" >> "$TMP/pusher/videos/tracked/spec.md"
git -C "$TMP/pusher" commit -qam "upstream change to the ignored path"
git -C "$TMP/pusher" push -q --no-verify origin develop
echo "local edit" >> "$CALLER/videos/tracked/spec.md"
set +e
FF_MERGE_CLEANUP_IGNORE_PATHS="$IGNORE_BOTH" \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-ignore-pullblock.log" 2>&1
EXIT_IGNORE_PULLBLOCK=$?
set -e
if [ "$EXIT_IGNORE_PULLBLOCK" -eq 1 ] \
  && grep -q "ガード対象外として無視した未コミット変更" "$TMP/run-ignore-pullblock.log" \
  && grep -q "git pull --ff-only が失敗しました" "$TMP/run-ignore-pullblock.log" \
  && ! grep -q "マージ後 Cleanup 結果" "$TMP/run-ignore-pullblock.log" \
  && [ -n "$(git -C "$CALLER" status --porcelain -- videos/tracked/spec.md)" ]; then
  ok "除外したパスが実際に cleanup を妨げる場合は、git 自身の判定で中断する"
else
  bad "除外パスが妨げになる場合の中断が期待どおりでない (exit=$EXIT_IGNORE_PULLBLOCK)"
fi
git -C "$CALLER" checkout -- videos/tracked/spec.md

# suite-cases-end: uncommitted-guard.sh
