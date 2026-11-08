# shellcheck shell=bash
# pipefail-inherited: verify.sh が set -euo pipefail の下で source する
# トランスクリプト回収（Step 5.5）
#
# verify.sh から source される（ok / bad / TMP / TARGET / MOCK / PLUGIN_ROOT / SCRIPT_DIR を共有）。
# 読む順序は verify.sh の一覧が正本で、前の cases の fixture と関数を後ろの cases が使う（Issue `#2697`）。

# ---- トランスクリプト回収（Step 5.5） ------------------------------------------

archive_of() {
  # $1: トランスクリプトディレクトリ名。対応する tar.gz のパスを stdout へ返す。
  # 見つからないのは正常系（保護されたケース）なので、非ゼロで落とさない。
  ls "$FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR/$1"-*.tar.gz 2>/dev/null | head -1 || true
}

# 8. cwd 照合が一致したトランスクリプトは中身ごとアーカイブされ、元は消える
ARCHIVE_MATCH="$(archive_of "$NAME_MATCH")"
# grep -q はパイプ入力だと早期終了で tar 側を落とすため、いったんファイルへ落とす
ARCHIVE_LIST="$TMP/archive-list.txt"
: > "$ARCHIVE_LIST"
if [ -n "$ARCHIVE_MATCH" ]; then
  tar -tzf "$ARCHIVE_MATCH" > "$ARCHIVE_LIST" 2>/dev/null || true
fi
if [ ! -d "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_MATCH" ] \
  && [ -n "$ARCHIVE_MATCH" ] \
  && grep -q 'session\.jsonl' "$ARCHIVE_LIST"; then
  ok "cwd 一致のトランスクリプトを中身ごと tar.gz 化して元を削除"
else
  bad "cwd 一致のトランスクリプトのアーカイブが期待どおりでない ($NAME_MATCH)"
fi

# 9. cwd がこの worktree を指さないものは、名前が一致しても触らない。
#    ただし異常ではないので PARTIAL には数えない
if [ -f "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_MISMATCH/session.jsonl" ] \
  && [ -z "$(archive_of "$NAME_MISMATCH")" ] \
  && grep -q -- "$NAME_MISMATCH: cwd がこの worktree を指していない" "$TMP/run.log" \
  && ! grep -q "トランスクリプト回収: cwd" "$TMP/run.log"; then
  ok "cwd が別を指すものを保護し、失敗ではなくスキップとして報告"
else
  bad "cwd 不一致のトランスクリプトの保護が期待どおりでない ($NAME_MISMATCH)"
fi

# 10. cwd を記録した jsonl が無いものは、名前がどう見えても回収しない
if [ -d "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_NOJSONL" ] \
  && [ -z "$(archive_of "$NAME_NOJSONL")" ] \
  && grep -q -- "$NAME_NOJSONL: cwd を記録した jsonl が無く所有者を確認できない" "$TMP/run.log"; then
  ok "cwd を記録した jsonl が無いものは、名前が worktree 由来でも回収しない"
else
  bad "jsonl 無しケースの保護が期待どおりでない ($NAME_NOJSONL)"
fi

# 10.5 jsonl はあるが cwd を含まないものも残す。失敗ではなくスキップとして扱う
#      （これを部分失敗に数えると、この系統のディレクトリがあるだけで毎回 PARTIAL になる）
if [ -f "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_NOCWD/vercel-plugin/skill-injections.jsonl" ] \
  && [ -z "$(archive_of "$NAME_NOCWD")" ] \
  && grep -q -- "$NAME_NOCWD: cwd を記録した jsonl が無く所有者を確認できない" "$TMP/run.log" \
  && ! grep -q "トランスクリプト回収: jsonl 走査エラーで保護 ($NAME_NOCWD)" "$TMP/run.log"; then
  ok "jsonl はあるが cwd を含まないものを、走査エラーと区別してスキップ扱いにする"
else
  bad "cwd を含まない jsonl の扱いが期待どおりでない ($NAME_NOCWD)"
fi

# 11. 名前からも判別できないものも同じ経路で残る
if [ -f "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_OPAQUE/subagents/leftover.txt" ] \
  && [ -z "$(archive_of "$NAME_OPAQUE")" ]; then
  ok "cwd の証拠が無いものを保護"
else
  bad "照合根拠なしケースの保護が期待どおりでない ($NAME_OPAQUE)"
fi

# 12. projects 外へ解決される symlink は辿らない。
#     リンク先には cwd 一致の jsonl を置いてあるので、ガードが無ければ確実に
#     回収されてしまう構成になっている
#     結果（リンク先が無事）だけを見ると、後段のアーカイブ件数照合が偶然止めた
#     場合も緑になるため、どのガードで止めたのかまで固定する。なお containment
#     ガード単独は、静的なファイル配置では -L に先回りされて到達しないので、
#     ここでは -L が働いたことを直接押さえる。
if [ -f "$TMP/outside-transcripts/keep.txt" ] \
  && [ -f "$TMP/outside-transcripts/session.jsonl" ] \
  && [ -L "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_SYMLINK" ] \
  && [ -z "$(archive_of "$NAME_SYMLINK")" ] \
  && grep -q "シンボリックリンクのため辿りません" "$TMP/run.log"; then
  ok "projects 外を指す symlink を辿らず、cwd 一致の中身ごとリンク先を保護"
else
  bad "symlink のパストラバーサル防止が期待どおりでない ($NAME_SYMLINK)"
fi

# 12.5 セッションが親リポジトリへ移動した履歴も回収する（cwd の存在判定）
if [ ! -d "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_MULTICWD" ] \
  && [ -n "$(archive_of "$NAME_MULTICWD")" ]; then
  ok "worktree 外の cwd を併せ持つ履歴も、worktree を指す cwd があれば回収"
else
  bad "複数 cwd を持つトランスクリプトの回収が期待どおりでない ($NAME_MULTICWD)"
fi

# 12.6 2 つ目の命名規則で作られたディレクトリも候補に入る
if [ ! -d "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_VARIANT_B" ] \
  && [ -n "$(archive_of "$NAME_VARIANT_B")" ]; then
  ok "'.'/'_' を保持する命名規則のディレクトリも候補として回収"
else
  bad "2 つ目の命名規則が候補になっていない ($NAME_VARIANT_B)"
fi

# 12.7 一部の jsonl が読めない場合、読めた分だけで一致と判定しない
if [ -d "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_SCANERR" ] \
  && [ -z "$(archive_of "$NAME_SCANERR")" ] \
  && [ -f "$TMP/mock-find-failed" ] \
  && grep -q "トランスクリプト回収: jsonl 走査エラーで保護 ($NAME_SCANERR)" "$TMP/run.log"; then
  ok "find 失敗をuid非依存で注入し、一致する cwd が見えていても保護して PARTIAL"
else
  bad "find 失敗fixtureの保護が期待どおりでない ($NAME_SCANERR)"
fi

# 12.8 ファイル単位で読めない場合も同様に保護する（find は成功し grep が失敗する経路）
if [ -d "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_UNREADABLE" ] \
  && [ -z "$(archive_of "$NAME_UNREADABLE")" ] \
  && [ -f "$TMP/mock-grep-failed" ] \
  && grep -q "トランスクリプト回収: jsonl 走査エラーで保護 ($NAME_UNREADABLE)" "$TMP/run.log"; then
  ok "grep 失敗をuid非依存で注入し、見えた分だけで判定せず保護"
else
  bad "grep 失敗fixtureの保護が期待どおりでない ($NAME_UNREADABLE)"
fi

# 13. サマリーに回収件数と容量が出る
if grep -qE "アーカイブした worktree トランスクリプト: 3 件 / 元 [1-9][0-9]* KB → アーカイブ [1-9][0-9]* KB" "$TMP/run.log"; then
  ok "サマリーにアーカイブ件数と、元サイズ→アーカイブサイズを表示"
else
  bad "サマリーのアーカイブ件数・容量が期待どおりでない"
fi

# 13.5 保護したものは PARTIAL とは別枠で列挙される
if grep -q "所有者を確認できず残したトランスクリプト:" "$TMP/run.log"; then
  ok "保護したトランスクリプトを失敗項目と分けて列挙"
else
  bad "保護したトランスクリプトの列挙が無い"
fi

# 14. FF_MERGE_CLEANUP_TRANSCRIPTS=off なら worktree を消しても回収しない
add_clean_gone_worktree 'feature/#25-wt-off' "$TMP/wt-25"
NAME_OFF="$(transcript_name_of "$TMP/wt-25")"
make_transcript_dir "$NAME_OFF" "$(cd "$TMP/wt-25" && pwd -P)"
set +e
FF_MERGE_CLEANUP_TRANSCRIPTS=off PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-off.log" 2>&1
set -e
if [ -f "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_OFF/session.jsonl" ] \
  && [ -z "$(archive_of "$NAME_OFF")" ] \
  && ! [ -d "$TMP/wt-25" ] \
  && grep -q "無効（FF_MERGE_CLEANUP_TRANSCRIPTS=off）" "$TMP/run-off.log"; then
  ok "off 指定でトランスクリプトを回収せず、サマリーに無効と表示"
else
  bad "off 指定時の挙動が期待どおりでない ($NAME_OFF)"
fi

# 15. 値が不正なら黙って無効化せず fail-loud にする
add_clean_gone_worktree 'feature/#26-wt-bogus' "$TMP/wt-26"
NAME_BOGUS="$(transcript_name_of "$TMP/wt-26")"
make_transcript_dir "$NAME_BOGUS" "$(cd "$TMP/wt-26" && pwd -P)"
set +e
FF_MERGE_CLEANUP_TRANSCRIPTS=bogus PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-bogus.log" 2>&1
EXIT_BOGUS=$?
set -e
if [ "$EXIT_BOGUS" -eq 2 ] \
  && [ -f "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_BOGUS/session.jsonl" ] \
  && grep -q "トランスクリプト回収: FF_MERGE_CLEANUP_TRANSCRIPTS の値が不正" "$TMP/run-bogus.log"; then
  ok "環境変数の値が不正なら回収せず PARTIAL で報告"
else
  bad "不正な環境変数値の扱いが期待どおりでない (exit=$EXIT_BOGUS)"
fi

# 16. アーカイブに失敗したら元ディレクトリを残し、書きかけの成果物も残さない
add_clean_gone_worktree 'feature/#27-wt-tarfail' "$TMP/wt-27"
NAME_TARFAIL="$(transcript_name_of "$TMP/wt-27")"
make_transcript_dir "$NAME_TARFAIL" "$(cd "$TMP/wt-27" && pwd -P)"
set +e
MOCK_TAR_FAIL=1 PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-tarfail.log" 2>&1
EXIT_TARFAIL=$?
set -e
if [ "$EXIT_TARFAIL" -eq 2 ] \
  && [ -f "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_TARFAIL/session.jsonl" ] \
  && [ -z "$(archive_of "$NAME_TARFAIL")" ] \
  && [ -z "$(ls "$FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR"/.merge-cleanup-archive-* 2>/dev/null || true)" ] \
  && grep -q "tar が失敗しました。元ディレクトリは残します" "$TMP/run-tarfail.log"; then
  ok "アーカイブ失敗時は元ディレクトリを残し、書きかけの成果物も残さない"
else
  bad "アーカイブ失敗時の挙動が期待どおりでない (exit=$EXIT_TARFAIL)"
fi

# 16.5 tar が成功を名乗っても、読み直せないアーカイブを根拠に元を消さない
add_clean_gone_worktree 'feature/#31-wt-corrupt' "$TMP/wt-31"
NAME_CORRUPT="$(transcript_name_of "$TMP/wt-31")"
make_transcript_dir "$NAME_CORRUPT" "$(cd "$TMP/wt-31" && pwd -P)"
set +e
MOCK_TAR_CORRUPT=1 PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-corrupt.log" 2>&1
EXIT_CORRUPT=$?
set -e
if [ "$EXIT_CORRUPT" -eq 2 ] \
  && [ -f "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_CORRUPT/session.jsonl" ] \
  && [ -z "$(archive_of "$NAME_CORRUPT")" ] \
  && grep -q "元ディレクトリは残します" "$TMP/run-corrupt.log" \
  && ! grep -q "対象のトランスクリプトはありませんでした" "$TMP/run-corrupt.log"; then
  ok "tar が exit 0 でも中身を検証できなければ元ディレクトリを消さない"
else
  bad "壊れたアーカイブの検出が期待どおりでない (exit=$EXIT_CORRUPT)"
fi

# 16.6 既存のアーカイブを黙って上書きしない
add_clean_gone_worktree 'feature/#32-wt-collide' "$TMP/wt-32"
NAME_COLLIDE="$(transcript_name_of "$TMP/wt-32")"
make_transcript_dir "$NAME_COLLIDE" "$(cd "$TMP/wt-32" && pwd -P)"
mkdir -p "$FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR"
# 実時刻に頼ると「たまたま同じ秒に実行された場合だけ衝突する」テストになり、
# ほぼ常に衝突しないまま緑になる。タイムスタンプを固定して必ず衝突させる。
COLLIDE_STAMP="19990101-000000"
COLLIDE_EXISTING="$FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR/$NAME_COLLIDE-$COLLIDE_STAMP.tar.gz"
echo "precious-existing-archive" > "$COLLIDE_EXISTING"
set +e
MOCK_FIXED_STAMP="$COLLIDE_STAMP" PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-collide.log" 2>&1
set -e
COLLIDE_COUNT="$(ls "$FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR/$NAME_COLLIDE"-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
if [ -f "$COLLIDE_EXISTING" ] \
  && grep -q "precious-existing-archive" "$COLLIDE_EXISTING" \
  && [ "$COLLIDE_COUNT" -ge 2 ]; then
  ok "同名のアーカイブが既にある場合、上書きせず別名で作る"
else
  bad "既存アーカイブの上書き回避が期待どおりでない (count=$COLLIDE_COUNT)"
fi

# 16.65 アーカイブ中に元へ書き足されたら、その分を失うので削除しない。
#       件数照合だけでは「既存ファイルへの追記」を検出できない
add_clean_gone_worktree 'feature/#36-wt-append' "$TMP/wt-36"
NAME_APPEND="$(transcript_name_of "$TMP/wt-36")"
make_transcript_dir "$NAME_APPEND" "$(cd "$TMP/wt-36" && pwd -P)"
set +e
MOCK_TAR_APPEND=1 PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-append.log" 2>&1
EXIT_APPEND=$?
set -e
if [ "$EXIT_APPEND" -eq 2 ] \
  && [ -f "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_APPEND/session.jsonl" ] \
  && [ -z "$(archive_of "$NAME_APPEND")" ] \
  && grep -q "アーカイブ中に元が変更されました" "$TMP/run-append.log"; then
  ok "アーカイブ中に元が変更されたら削除しない（追記分の消失を防ぐ）"
else
  bad "アーカイブ中の変更検出が期待どおりでない (exit=$EXIT_APPEND)"
fi

# 16.655 内容が変わっていない未来 mtime は、アーカイブ中の変更ではない。
# marker との時刻比較へ戻ると必ず誤検出する、Issue `#1050` の決定的な回帰 fixture。
add_clean_gone_worktree 'feature/#40-wt-future-mtime' "$TMP/wt-40"
NAME_FUTURE_MTIME="$(transcript_name_of "$TMP/wt-40")"
make_transcript_dir "$NAME_FUTURE_MTIME" "$(cd "$TMP/wt-40" && pwd -P)"
touch -t 203701010000 "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_FUTURE_MTIME/session.jsonl"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-future-mtime.log" 2>&1
EXIT_FUTURE_MTIME=$?
set -e
if { [ "$EXIT_FUTURE_MTIME" -eq 0 ] || [ "$EXIT_FUTURE_MTIME" -eq 2 ]; } \
  && [ ! -d "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_FUTURE_MTIME" ] \
  && [ -n "$(archive_of "$NAME_FUTURE_MTIME")" ] \
  && ! grep -q "アーカイブ中に元が変更されました.*$NAME_FUTURE_MTIME" "$TMP/run-future-mtime.log"; then
  ok "未変更の未来 mtime をアーカイブ中の変更と誤認しない"
else
  bad "未来 mtime の扱いが期待どおりでない (exit=$EXIT_FUTURE_MTIME)"
fi

# 16.66 アーカイブ名の位置に壊れた symlink があっても、辿らず上書きもしない
add_clean_gone_worktree 'feature/#37-wt-brokenlink' "$TMP/wt-37"
NAME_BROKEN="$(transcript_name_of "$TMP/wt-37")"
make_transcript_dir "$NAME_BROKEN" "$(cd "$TMP/wt-37" && pwd -P)"
mkdir -p "$FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR"
BROKEN_STAMP="19990202-000000"
BROKEN_LINK="$FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR/$NAME_BROKEN-$BROKEN_STAMP.tar.gz"
ln -s "$TMP/no-such-target" "$BROKEN_LINK"
set +e
MOCK_FIXED_STAMP="$BROKEN_STAMP" PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-broken.log" 2>&1
set -e
if [ -L "$BROKEN_LINK" ] \
  && [ ! -e "$TMP/no-such-target" ] \
  && [ -f "$FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR/$NAME_BROKEN-$BROKEN_STAMP-1.tar.gz" ]; then
  ok "壊れた symlink を上書き先とみなさず、別名でアーカイブする"
else
  bad "壊れた symlink の扱いが期待どおりでない ($NAME_BROKEN)"
fi

# 16.7 アーカイブ先を作れないときは Step を中断し、「対象なし」と誤報しない
add_clean_gone_worktree 'feature/#33-wt-nodir' "$TMP/wt-33"
NAME_NODIR="$(transcript_name_of "$TMP/wt-33")"
make_transcript_dir "$NAME_NODIR" "$(cd "$TMP/wt-33" && pwd -P)"
echo "not a directory" > "$TMP/blocking-file"
set +e
FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR="$TMP/blocking-file/archives" \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-nodir.log" 2>&1
EXIT_NODIR=$?
set -e
if [ "$EXIT_NODIR" -eq 2 ] \
  && [ -f "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_NODIR/session.jsonl" ] \
  && grep -q "アーカイブ先を作成できません" "$TMP/run-nodir.log" \
  && grep -q "worktree トランスクリプトの回収: 中断（アーカイブ先を作成できない" "$TMP/run-nodir.log" \
  && ! grep -q "対象のトランスクリプトはありませんでした" "$TMP/run-nodir.log"; then
  ok "アーカイブ先を作れないときは中断し、「対象なし」と矛盾する報告をしない"
else
  bad "アーカイブ先作成失敗時の挙動が期待どおりでない (exit=$EXIT_NODIR)"
fi

# 16.75 容量計測に失敗しても、回収そのものは止めない。
#       pipefail + errexit の下では、代入内のパイプ失敗が Step 全体を落としうる
add_clean_gone_worktree 'feature/#35-wt-dufail' "$TMP/wt-35"
NAME_DUFAIL="$(transcript_name_of "$TMP/wt-35")"
make_transcript_dir "$NAME_DUFAIL" "$(cd "$TMP/wt-35" && pwd -P)"
set +e
MOCK_DU_FAIL=1 PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-dufail.log" 2>&1
set -e
if [ ! -d "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_DUFAIL" ] \
  && [ -n "$(archive_of "$NAME_DUFAIL")" ] \
  && grep -q "容量を計測できませんでした" "$TMP/run-dufail.log" \
  && grep -q "マージ後 Cleanup 結果" "$TMP/run-dufail.log"; then
  ok "容量計測に失敗しても回収を続行し、サマリーまで到達する"
else
  bad "du 失敗時の挙動が期待どおりでない ($NAME_DUFAIL)"
fi

# 16.8 本番の設定パス（CLAUDE_CONFIG_DIR 由来）でも動く。
#      テストが常に FF_* で上書きしていると、実ユーザーが通る唯一の経路が
#      一度も実行されないまま緑になる
add_clean_gone_worktree 'feature/#34-wt-realconf' "$TMP/wt-34"
CONFIG_HOME="$TMP/claude-config"
mkdir -p "$CONFIG_HOME/projects"
NAME_REALCONF="$(transcript_name_of "$TMP/wt-34")"
mkdir -p "$CONFIG_HOME/projects/$NAME_REALCONF"
printf '{"type":"user","cwd":"%s"}\n' "$(cd "$TMP/wt-34" && pwd -P)" \
  > "$CONFIG_HOME/projects/$NAME_REALCONF/session.jsonl"
set +e
env -u FF_MERGE_CLEANUP_PROJECTS_DIR -u FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR \
  CLAUDE_CONFIG_DIR="$CONFIG_HOME" PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-realconf.log" 2>&1
set -e
if [ ! -d "$CONFIG_HOME/projects/$NAME_REALCONF" ] \
  && [ -n "$(ls "$CONFIG_HOME/transcript-archives/$NAME_REALCONF"-*.tar.gz 2>/dev/null || true)" ]; then
  ok "CLAUDE_CONFIG_DIR 由来の既定パス（projects / transcript-archives）で回収できる"
else
  bad "既定の設定パス導出が期待どおりでない ($NAME_REALCONF)"
fi

# 17. dirty worktree は削除されないので、そのトランスクリプトにも触らない
if [ -f "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_DIRTY/session.jsonl" ] \
  && [ -z "$(archive_of "$NAME_DIRTY")" ]; then
  ok "削除されなかった dirty worktree のトランスクリプトには触れない"
else
  bad "dirty worktree のトランスクリプトが処理された"
fi


# suite-cases-end: transcripts.sh
