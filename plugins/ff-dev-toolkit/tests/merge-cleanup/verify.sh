#!/usr/bin/env bash
#
# merge-cleanup.sh の破壊的経路の回帰テスト。
#
# 一時 git リポジトリ（bare origin + clone）と mock gh で以下を検証する:
#   1. 対象 PR のリモートブランチが削除される（OID 一致）
#   2. 取り残し: (名前, OID) 一致のマージ済みブランチは削除される
#   3. 取り残し: 名前一致でも OID 不一致（マージ後 push あり）は削除されない
#   3b. (6.22) その OID 不一致の取り残しは、削除が lease に拒まれる前に**取り残し
#       候補一覧そのものへ載らない**（事前照合の検出力。項目 3 だけでは、照合を
#       名前一致へ退化させても lease 拒否が同じ「削除されない」観測を作る）
#   3c. (6.23) 名前と OID を別々のマージ済み PR から借りたブランチも候補にならない
#       （照合が (名前, OID) の**ペア**であり、名前の集合 × OID の集合の独立照合へ
#       退化していないこと。3b の入力では両者を区別できない）
#   4. 取り残し: open PR の head として再利用中は削除されない
#   5. 取り残し: 保護ブランチ（release/*）は照合一致でも削除されない
#   6. dirty worktree 付き [gone] ブランチは保護され、終了コードが 2（PARTIAL）になる
#   7. 未マージの固有コミットを持つ [gone] ブランチ（手動リモート削除由来）は -D されない
#   8. 対象 PR が MERGED でない場合、破壊的処理の前に exit 1 で中断する
#   9. base を保持する別 worktree が dirty なら変更せず exit 1 で中断する
#  10. base を保持する別 worktree が clean なら、worktree と ignored file を残したまま
#      detached へ退避し、呼び出し元が最新 base ブランチへ復帰する
#  11. 対象 PR のリモートブランチが既に無い場合は、lease 拒否と誤判定しない
#  12. 対象 PR のリモートブランチが別 OID で存在する場合は、lease 拒否として保護する
#  13. lease 拒否後の ref 再取得に失敗した場合は、失敗として記録し後続 Step を続行する
#      （このケースの対象 ref は origin に無いため、非削除の検証は項目 14 が担う）
#  14. lease 拒否後の ref が期待 OID のままなら、原因不明として記録し後続 Step を続行する
#  15. ref 再取得が成功し stderr に警告だけ出ても、空の stdout を存在と誤判定しない
#  15b. Step 4 の削除失敗を Step 6 の取り残し掃除が再試行して成功した場合、
#       サマリーの「対象 PR のリモートブランチ」が失敗のまま矛盾しない
#  15c. Step 4 の削除失敗の間にリモートが別 OID へ進んだ場合、Step 6 の再試行は
#       (名前, OID) 照合で弾かれ、更新済みブランチを削除しない
#  15d. Step 4 の失敗後、Step 6 の再試行時点で ref が消えていた場合も、
#       サマリーを失敗のまま残さない（already removed として反映する）
#  15e. Step 6 の再試行も失敗した場合、Step 4 と同一文言の失敗項目を 2 行並べない
#  15f. 削除反映の fetch --prune が失敗しても中断せず、失敗として記録して続行する
#  15g. (6.16) headRefOid が null で返り、取り残し一覧側の OID も null な PR では、
#       lease のアンカーが無いことを名指ししてリモート削除をスキップし（削除は
#       行わない）、PARTIAL で後続 Step を続行する
#  15h. (6.17) headRefOid は null だが取り残し一覧側の OID は正常な PR（混在ケース）
#       では、Step 6 が (名前, OID) 照合で実際に削除し、サマリーを
#       deleted_by_leftover_retry へ更新して「削除未実施」の虚偽行を出さない
#  15i. (6.18) 同じ混在ケースで Step 6 の削除が lease 拒否になった場合、削除しない
#       のは保護なので失敗として数えず、スキップした削除候補として列挙する
#  15j. (6.19) 同じ混在ケースで Step 6 の削除が一般エラーで失敗した場合、失敗行を
#       1 行に束ね（Step 4 スキップ + Step 6 失敗）、二重計上せず ref を残す
#  15k. (6.20) 同じ混在ケースで Step 6 の削除時点に ref が消えていた場合、
#       already_missing_at_leftover_retry へ更新し失敗として数えない
#  15l. (6.21) headRefOid が null で origin に ref も無い場合、実在確認（ls-remote
#       --exit-code）で already_missing と判定し、解消しない PARTIAL を出さない
#
# 上の番号（`15b` / `15g` のような枝番）は本一覧の通し番号で、実行部のインライン
# コメントは `<Step>.<連番>`（`6.11` / `6.16`）を使う別系列である。新しいケースを
# 足すときは、上のように括弧で対応するインライン番号を添えること。
#  16. 削除した worktree のトランスクリプトを、cwd 照合のうえ tar.gz へ回収する
#  17. cwd がこの worktree を指さないものは、名前が一致しても触らない
#  18. cwd を記録した jsonl が無いものは、名前が worktree 由来でも回収しない
#  19. ディレクトリを辿れない場合、読めた分だけで一致と判定せず保護する
#  19b. ファイル単位で読めない場合も同様に保護する（find は成功し grep が失敗する経路）
#  19c. jsonl はあるが cwd を含まない場合は、走査エラーと区別してスキップ扱いにする
#  20. projects 外への symlink は辿らない（リンク先には cwd 一致の中身を置いて検証）
#  21. worktree 外の cwd を併せ持つ履歴も、worktree を指す cwd があれば回収する
#  22. 2 つ目の命名規則（'.'/'_' 保持）のディレクトリも候補に入る
#  23. 保護したものは失敗（PARTIAL）と分けて列挙する
#  24. 無効化の環境変数を尊重し、不正値は黙って無効化せず PARTIAL で報告する
#  25. アーカイブに失敗したら元ディレクトリは残し、書きかけの成果物は残さない
#  26. tar が exit 0 でも中身を検証できなければ元ディレクトリを消さない
#  27. 同名のアーカイブが既にある場合、上書きせず別名で作る（リンク切れの symlink も含む）
#  27b. アーカイブ中に元が変更されたら削除しない（追記分の消失を防ぐ）
#  28. アーカイブ先を作れないときは中断し、「対象なし」と矛盾する報告をしない
#  29. CLAUDE_CONFIG_DIR 由来の既定パスでも回収できる（実ユーザーが通る経路）
#  30. 削除しなかった dirty worktree のトランスクリプトには触れない
#  31. 削除 push は SKIP_SIMPLE_GIT_HOOKS=1 を付け、env が無いと拒否する
#      pre-push fixture の下でもリモート削除が完了する
#  32. 未コミット変更ガードのパス除外（FF_MERGE_CLEANUP_IGNORE_PATHS）
#      32.1  除外パスだけが dirty なら Step 1 を通過し、無視した変更を件数と一覧で
#            報告する（パターンは複数指定し、2 要素目も効くことを見る）
#      32.2  除外外の dirty が 1 つでもあれば中断し、中断一覧に除外済みのパスを混ぜない
#      32.3  空要素を含む指定は「ガード無効化」として中断する（空パターンは全体を除外する）
#      32.3b 前後に空白の付いたパターンは何にも一致しないので中断する
#      32.4  先頭 ':' の pathspec magic 直書きは空パターンとして中断する
#      32.4b 中間位置の magic は中断せずリテラル扱いになり、前後の実パターンだけが効く
#      32.4c 全パスに一致するパターンは、ガードが無効化される事実をログへ残す
#      32.5  除外を適用した git status の失敗を「変更なし」とみなさず中断する
#      32.5b 報告用（肯定形 pathspec）の status だけが失敗する経路でも中断する
#      32.5c 除外未設定の素の status が失敗する経路でも中断する（既定運用の経路）
#      32.6  未設定なら現行どおり dirty で中断する
#      32.7  base を保持する別 worktree の dirty が除外パスだけなら、退避して続行し、
#            無視した変更を報告する
#      32.7b base 所有 worktree の除外外 dirty は、除外指定があっても中断する
#      32.7c base 所有 worktree の status が exit 0 でも stderr に警告を出せば中断する
#      32.8  worktree 削除（Step 5）は除外指定の対象外で、dirty な worktree を保護する
#      32.9  一致 0 件のときは「0 件」の空報告ではなく、一致が無い事実を出して中断する
#      32.10 空文字列の指定は未設定と同じ扱いで、空パターンの die にはしない
#      32.11 除外したパスが実際に cleanup を妨げる場合は、git 自身の判定
#            （pull --ff-only の拒否）で中断する（Step 1 を緩めてよい根拠の実測）
#      32.12 作業ブランチ上に除外対象の変更を残したまま実行しても、base への切り替えが
#            変更を持ち越して完走する（実運用の中心経路）
#      32.5e stderr の無い status 失敗でも「詳細不明」の診断を出して中断する
#      32.7d base 所有 worktree のガード status だけが失敗する経路は Step 3 で中断する
#      なお guarded_status の正の :(top) pathspec は、現行 git（2.49 実測）では
#      外しても挙動が変わらないため本 suite では回帰検出できない。古いバージョン差に
#      対する防御として実装側コメントに理由を残してある（テスト不在 = 不要ではない）。
#
# あわせて静的検査として、bash 3.2 で変数名にマルチバイト文字が取り込まれる書き方
# （"$VAR" の直後に全角文字を直付けする形）が merge-cleanup.sh と本 suite 自身に無いことを
# 確認する。検出器は共有実装（tests/lib/mbcs-guard.sh）を使い、走査できなかった場合は
# 「違反なし」ではなく失敗として報告する。
#
# 書き込み不可の環境（read-only チェックアウト等）では skip して成功扱いにする。
#
# 末尾で検査総数（EXPECTED_PASS）を固定する。ケースが黙って消える形は個々のアサート
# では検出できないため、件数そのものを契約として置く。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/scripts/merge-cleanup.sh"

[ -f "$TARGET" ] || { echo "✗ merge-cleanup.sh が見つかりません: $TARGET" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "✗ jq が必要です" >&2; exit 1; }

# mktemp の stderr を捨てない。捨てると read-only 以外の失敗（TMPDIR が不正な
# パス・quota 超過など）まで「書き込み可能な環境で再実行してください」に誤帰属し、
# 恒常的に壊れた TMPDIR が suite を exit 0 で無効化し続ける。2>&1 で受けると
# 成功時はパス・失敗時は理由が同じ変数に入る。
if _ff_mktemp_out="$(mktemp -d 2>&1)"; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  FF_REACHED_END=1
  exit 0
fi
# 途中死を沈黙させない。`set -u` 等で死んだとき、トラップ突入時の $? は **0** になるため、
# 終了ステータスを保存し直すだけでは足りない（実測）。「rc=0 なのに最後まで到達して
# いない」を中断として扱う。明示的な非 0 終了はそのまま通す。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ merge-cleanup: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

# トランスクリプト回収の格納先を temp へ固定する。全実行の前に export するので、
# どのケースでも実際の ~/.claude/projects には触れない。
export FF_MERGE_CLEANUP_PROJECTS_DIR="$TMP/projects"
export FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR="$TMP/archives"
mkdir -p "$FF_MERGE_CLEANUP_PROJECTS_DIR"

PASS=0
FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# ---- 静的検査: $VAR 直後のマルチバイト文字 -------------------------------------
#
# macOS 標準の bash 3.2 は $VAR の直後に続くマルチバイト文字を変数名の一部として
# 取り込む。日本語メッセージで "$name" の直後へ全角括弧を直付けすると `name（` を参照することになり、
# set -u 下では `unbound variable` で異常終了する。**これが起きるのは失敗を報告
# しようとした瞬間だけ**なので、正常系が緑のあいだは誰も気付かない。
#
# LC_ALL=C では [:print:] も [:space:] も ASCII しか含まないため、
# 「印字可能でも空白でもないバイト」= マルチバイトの先頭バイトを拾える。
#
# 検出器は共有実装 tests/lib/mbcs-guard.sh の mbcs_scan を使う（repo 横断ガード
# tests/run-all/verify.sh case 11 と同じ実体）。論理行へ畳んでから走査するので、
# バックスラッシュ行継続をまたぐ隣接も拾える。検出器そのものの回帰は専用 suite
# （tests/mbcs-guard-failclosed/）が持つため、ここに自前の probe は置かない
# ——「この suite が検出器を呼んでいる」配線は末尾の EXPECTED_PASS が固定する。
# shellcheck source=../lib/mbcs-guard.sh
. "$SCRIPT_DIR/../lib/mbcs-guard.sh"

echo "== 静的検査: マルチバイト直付けの変数展開 =="

mbcs_assert_clean() {
  # $1: 検査するファイル / $2: 報告に使う表示名
  #
  # 走査の失敗（awk 非 0 = 読めない・実行できない）を「違反なし」へ倒さない。
  # 握り潰すと検査が黙って無効化され、緑のまま何も見ていない状態になる。
  local file="$1" label="$2" hits rc
  if [ ! -f "$file" ]; then
    bad "${label} を検査できない（ファイルが見つからない: ${file}）"
    return
  fi
  set +e
  hits="$(mbcs_scan "$file" 2>/dev/null)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    bad "${label} を走査できない（awk rc=${rc}）— このファイルの「違反 0 件」は主張できない"
    return
  fi
  if [ -z "$hits" ]; then
    ok "${label} に \$VAR 直付けのマルチバイト展開が無い"
  else
    bad "${label} に \$VAR 直付けのマルチバイト展開がある（\${VAR} 形式にすること）"
    printf '%s\n' "$hits" | sed 's/^/     /' >&2 || true
  fi
}

# 検査対象は merge-cleanup.sh と本 suite 自身の 2 つ。suite 自身を外すと、verify.sh を
# 編集した本人が単体実行では自分の違反に気付けず、repo 横断ガード（tests/run-all/verify.sh
# の case 11）まで持ち越される。しかも違反が失敗報告の文言に入った場合は、静的検査を
# すり抜けたまま実行時に `unbound variable` で suite が途中死する。二重に見えるが役割は
# 別で、ここは「書いたその場での即時フィードバック」、case 11 は「再混入の横断防止」。
#
# 本ファイル内のコメント・診断文言そのものが検査対象になる点に注意する（`$VAR` の直後へ
# 全角文字を書かない）。書き分けの実例は末尾の検査総数の診断で、`${EXPECTED_PASS}` /
# `${PASS}` と波括弧で括ってある。裸で書くと `PASS（` を参照して suite が途中死する。
mbcs_assert_clean "$TARGET" "merge-cleanup.sh"
mbcs_assert_clean "$SCRIPT_DIR/verify.sh" "本 suite (tests/merge-cleanup/verify.sh)"

# $1: 検査するファイル。delete_remote_branch_with_lease 内の git push が
# すべて「同一物理行の prefix 代入 SKIP_SIMPLE_GIT_HOOKS=1」なら 0。
# コメント内・XSKIP_・=10 は受理しない。env と git push は同じ行に置くこと。
delete_push_sets_skip_hooks() {
  awk '
    /^delete_remote_branch_with_lease\(\)/ { in_fn = 1 }
    in_fn && /^}/ { in_fn = 0 }
    in_fn && /git[[:space:]]+push/ {
      seen = 1
      line = $0
      sub(/#.*/, "", line)
      if (line !~ /(^|[^=[:alnum:]_])SKIP_SIMPLE_GIT_HOOKS=1[[:space:]]/) missing = 1
    }
    END { if (seen && !missing) exit 0; exit 1 }
  ' "$1"
}

echo ""
echo "== 静的検査: 削除 push の SKIP_SIMPLE_GIT_HOOKS =="

SKIP_HOOKS_PROBE="$TMP/skip-hooks-probe.sh"
write_skip_hooks_probe() {
  printf '%s\n' \
    'delete_remote_branch_with_lease() {' \
    "  $1" \
    '}' \
    > "$SKIP_HOOKS_PROBE"
}

write_skip_hooks_probe 'git push --force-with-lease="refs/heads/$branch:$expected" origin ":refs/heads/$branch"'
if ! delete_push_sets_skip_hooks "$SKIP_HOOKS_PROBE"; then
  ok "検出器が env 無しの git push を検出できる（self-test）"
else
  bad "検出器が env 無しの git push を見逃す — 以降の静的検査は信用しないこと"
fi
write_skip_hooks_probe 'LC_ALL=C SKIP_SIMPLE_GIT_HOOKS=1 git push --force-with-lease="refs/heads/$branch:$expected" origin ":refs/heads/$branch"'
if delete_push_sets_skip_hooks "$SKIP_HOOKS_PROBE"; then
  ok "検出器が env 付きの git push を誤検出しない（self-test）"
else
  bad "検出器が env 付きの git push を誤検出する"
fi
write_skip_hooks_probe 'git push --no-verify origin ":refs/heads/$branch" # SKIP_SIMPLE_GIT_HOOKS=1'
if ! delete_push_sets_skip_hooks "$SKIP_HOOKS_PROBE"; then
  ok "検出器がコメント内の SKIP_SIMPLE_GIT_HOOKS=1 を受理しない（self-test）"
else
  bad "検出器がコメント内の SKIP_SIMPLE_GIT_HOOKS=1 を受理する"
fi
write_skip_hooks_probe 'XSKIP_SIMPLE_GIT_HOOKS=1 git push origin ":refs/heads/$branch"'
if ! delete_push_sets_skip_hooks "$SKIP_HOOKS_PROBE"; then
  ok "検出器が XSKIP_SIMPLE_GIT_HOOKS=1 を受理しない（self-test）"
else
  bad "検出器が XSKIP_SIMPLE_GIT_HOOKS=1 を受理する"
fi
write_skip_hooks_probe 'SKIP_SIMPLE_GIT_HOOKS=10 git push origin ":refs/heads/$branch"'
if ! delete_push_sets_skip_hooks "$SKIP_HOOKS_PROBE"; then
  ok "検出器が SKIP_SIMPLE_GIT_HOOKS=10 を受理しない（self-test）"
else
  bad "検出器が SKIP_SIMPLE_GIT_HOOKS=10 を受理する"
fi

if delete_push_sets_skip_hooks "$TARGET"; then
  ok "delete_remote_branch_with_lease の git push に SKIP_SIMPLE_GIT_HOOKS=1 がある"
else
  bad "delete_remote_branch_with_lease の git push に SKIP_SIMPLE_GIT_HOOKS=1 が無い"
fi
# --no-verify / hooksPath 無効化 / export は契約外。env の command-scoped 代入だけを許す。
if awk '
  /^delete_remote_branch_with_lease\(\)/ { in_fn = 1 }
  in_fn && /^}/ { in_fn = 0 }
  in_fn && /--no-verify|core\.hooksPath|GIT_CONFIG_COUNT|export[[:space:]]+SKIP_SIMPLE_GIT_HOOKS/ { bad = 1 }
  END { exit bad ? 1 : 0 }
' "$TARGET"; then
  ok "delete_remote_branch_with_lease に --no-verify / hooksPath 無効化 / export が無い"
else
  bad "delete_remote_branch_with_lease が env 以外の hook 回避を使っている"
fi


# ---- fixture: bare origin + clone --------------------------------------------

git init --bare -q "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/work"
cd "$TMP/work"
git config user.email "test@example.com"
git config user.name "merge-cleanup-test"
git config commit.gpgsign false

git switch -q -c develop
echo base > README.md
git add README.md
git commit -qm "init"
git push -qu origin develop

new_branch_with_commit() {
  # $1: branch name / $2: file marker。作成後 develop に戻り、コミット OID を出力する
  git switch -q -c "$1" develop
  echo "$2" > "$2.txt"
  git add "$2.txt"
  git commit -qm "commit on $1"
  git rev-parse HEAD
  git push -qu origin "$1"
  git switch -q develop
}

OID_TARGET="$(new_branch_with_commit 'feature/#10-target' target)"
OID_EXACT="$(new_branch_with_commit 'feature/#1-merged-exact' exact)"
OID_OPEN="$(new_branch_with_commit 'feature/#3-open-reuse' openreuse)"
OID_RELEASE="$(new_branch_with_commit 'release/1.0' release)"

# lease 拒否後の再取得で「期待 OID のまま存在」を再現する branch。
OID_SAME="$(git rev-parse develop)"
git branch 'feature/#15-same-oid' "$OID_SAME"
git push -qu origin 'feature/#15-same-oid'
git branch -q -D 'feature/#15-same-oid'

# Step 4 の削除が失敗し、Step 6 の取り残し掃除が同じ branch を再試行するケース。
# origin へは 6.11 の直前に push する（それ以前の run が取り残しとして拾わないように）。
# mock のフラグはリセットしないので one-shot。同じ PR 番号を 2 回走らせる検証は足せない。
git switch -q -c 'feature/#17-retry-succeeds' develop
echo retry17 > retry17.txt
git add retry17.txt
git commit -qm "commit on feature/#17-retry-succeeds"
OID_RETRY17="$(git rev-parse HEAD)"
git switch -q develop
git branch -q -D 'feature/#17-retry-succeeds'

# Step 4 の削除失敗中にリモートが別 OID へ進むケース（15c）。
# origin へは 15c の直前に push する。OID_CHANGED18B は mock git が横から push する。
git switch -q -c 'feature/#18-changed-before-retry' develop
echo changed18 > changed18.txt
git add changed18.txt
git commit -qm "commit on feature/#18-changed-before-retry"
OID_CHANGED18="$(git rev-parse HEAD)"
echo changed18-more > changed18b.txt
git add changed18b.txt
git commit -qm "push that lands while step 4 is failing"
OID_CHANGED18B="$(git rev-parse HEAD)"
git switch -q develop
git branch -q -D 'feature/#18-changed-before-retry'

# Step 6 の再試行時点で ref が消えているケース（15d）。
git switch -q -c 'feature/#20-vanished-before-retry' develop
echo vanished20 > vanished20.txt
git add vanished20.txt
git commit -qm "commit on feature/#20-vanished-before-retry"
OID_VANISHED20="$(git rev-parse HEAD)"
git switch -q develop
git branch -q -D 'feature/#20-vanished-before-retry'

# run 14（Step 4 が rc=1）で Step 6 が削除に成功する取り残し。対象 PR 以外の成功が
# 対象 PR のサマリーを書き換えないこと・再試行されない対象が failed のまま残ることを見る。
git switch -q -c 'feature/#23-leftover-for-14' develop
echo leftover23 > leftover23.txt
git add leftover23.txt
git commit -qm "commit on feature/#23-leftover-for-14"
OID_LEFTOVER23="$(git rev-parse HEAD)"
git switch -q develop
git branch -q -D 'feature/#23-leftover-for-14'

# Step 6 の再試行も失敗するケース（15e）。origin へは 6.14 の直前に push する。
git switch -q -c 'feature/#22-retry-fails' develop
echo retryfail22 > retryfail22.txt
git add retryfail22.txt
git commit -qm "commit on feature/#22-retry-fails"
OID_RETRYFAIL22="$(git rev-parse HEAD)"
git switch -q develop
git branch -q -D 'feature/#22-retry-fails'

# 削除反映の fetch --prune が失敗するケース（15f）。origin へは 6.15 の直前に push する。
git switch -q -c 'feature/#21-prune-fails' develop
echo prunefail21 > prunefail21.txt
git add prunefail21.txt
git commit -qm "commit on feature/#21-prune-fails"
OID_PRUNEFAIL21="$(git rev-parse HEAD)"
git switch -q develop
git branch -q -D 'feature/#21-prune-fails'

# headRefOid が null で返るケース（6.16）。origin へは 6.16 の直前に push する。
git switch -q -c 'feature/#41-null-oid' develop
echo nulloid41 > nulloid41.txt
git add nulloid41.txt
git commit -qm "commit on feature/#41-null-oid"
OID_NULLOID41="$(git rev-parse HEAD)"
git switch -q develop
git branch -q -D 'feature/#41-null-oid'

# 混在ケース（6.17）: gh pr view は null だが、取り残し一覧側の OID は正常。
# Step 6 が (名前, OID) 照合で実際に削除できる構成にする。
git switch -q -c 'feature/#42-null-oid-mixed' develop
echo nulloid42 > nulloid42.txt
git add nulloid42.txt
git commit -qm "commit on feature/#42-null-oid-mixed"
OID_NULLOID42="$(git rev-parse HEAD)"
git switch -q develop
git branch -q -D 'feature/#42-null-oid-mixed'

# 混在ケースで lease 拒否になる系（6.18）: 一覧との照合後に別 push が着地する。
# OID_NULLOID43B は mock git が削除 push の最中に横から push する。
git switch -q -c 'feature/#43-null-oid-lease' develop
echo nulloid43 > nulloid43.txt
git add nulloid43.txt
git commit -qm "commit on feature/#43-null-oid-lease"
OID_NULLOID43="$(git rev-parse HEAD)"
echo nulloid43-more > nulloid43b.txt
git add nulloid43b.txt
git commit -qm "push that lands after the leftover match"
OID_NULLOID43B="$(git rev-parse HEAD)"
git switch -q develop
git branch -q -D 'feature/#43-null-oid-lease'

# 混在ケースで Step 6 の削除が一般エラーになる系（6.19）。
git switch -q -c 'feature/#44-null-oid-failure' develop
echo nulloid44 > nulloid44.txt
git add nulloid44.txt
git commit -qm "commit on feature/#44-null-oid-failure"
OID_NULLOID44="$(git rev-parse HEAD)"
git switch -q develop
git branch -q -D 'feature/#44-null-oid-failure'

# 混在ケースで Step 6 の削除時点に ref が消えている系（6.20）。
git switch -q -c 'feature/#45-null-oid-vanished' develop
echo nulloid45 > nulloid45.txt
git add nulloid45.txt
git commit -qm "commit on feature/#45-null-oid-vanished"
OID_NULLOID45="$(git rev-parse HEAD)"
git switch -q develop
git branch -q -D 'feature/#45-null-oid-vanished'

# headRefOid が null で、かつ origin に ref が既に無い系（6.21）。
# origin へは一度も push しない（GitHub の merge 時削除などで消えている状態）。
git switch -q -c 'feature/#46-null-oid-gone' develop
echo nulloid46 > nulloid46.txt
git add nulloid46.txt
git commit -qm "commit on feature/#46-null-oid-gone"
OID_NULLOID46="$(git rev-parse HEAD)"
git switch -q develop
git branch -q -D 'feature/#46-null-oid-gone'

# 名前再利用ケース: マージ済み PR の head OID の後に、さらに push が積まれている
git switch -q -c 'feature/#2-reused' develop
echo reused-merged > reused.txt
git add reused.txt
git commit -qm "merged head of reused"
OID_REUSED_MERGED="$(git rev-parse HEAD)"
echo reused-extra > reused2.txt
git add reused2.txt
git commit -qm "new work pushed after merge"
git push -qu origin 'feature/#2-reused'
git switch -q develop

# クロスペアケース（6.23）: 名前と OID を**別々の**マージ済み PR から借りると
# 一致してしまう構成。origin に残るのは feature/#47-crosspair（現 OID は
# OID_CROSSPAIR_NOW）で、マージ済み一覧には
#   PR A = (feature/#47-crosspair, OID_CROSSPAIR_MERGED)  … 名前は一致するが OID は古い
#   PR B = (feature/#48-crosspair-other, OID_CROSSPAIR_NOW) … OID は一致するが名前が違う
# の 2 件が載る。ペアで照合する現行実装ではどちらとも一致しないが、名前の集合と
# OID の集合を独立に照合する退化では「名前も OID もどれかの head と一致する」ため
# 通ってしまう。feature/#48-crosspair-other は origin へ push しない（OID の供給元
# としてだけ存在させ、削除対象を feature/#47-crosspair 1 本に保つ）。
git switch -q -c 'feature/#47-crosspair' develop
echo crosspair47 > crosspair47.txt
git add crosspair47.txt
git commit -qm "merged head of crosspair"
OID_CROSSPAIR_MERGED="$(git rev-parse HEAD)"
echo crosspair47-extra > crosspair47b.txt
git add crosspair47b.txt
git commit -qm "new work pushed after merge"
OID_CROSSPAIR_NOW="$(git rev-parse HEAD)"
git push -qu origin 'feature/#47-crosspair'
git switch -q develop

# 取り残し系はローカルブランチを消してリモートだけ残す（過去のマージ漏れを再現）
git branch -q -D 'feature/#1-merged-exact' 'feature/#2-reused' 'feature/#3-open-reuse' \
  'release/1.0' 'feature/#47-crosspair'

# dirty worktree 付き [gone] ブランチ: リモートを先に消して prune 対象にする
git worktree add -q "$TMP/wt-dirty" 'feature/#10-target' 2>/dev/null || \
  git worktree add -q "$TMP/wt-dirty" 'feature/#10-target'
echo work-in-progress > "$TMP/wt-dirty/wip.txt"

# 未マージの固有コミットを持つ [gone] ブランチ: リモートを手動削除して再現。
# mock の merged list に載せないため、-D エスカレーションのゲートで保護されるべき
git switch -q -c 'feature/#5-unmerged' develop
echo unmerged-work > unmerged.txt
git add unmerged.txt
git commit -qm "unmerged unique commit"
git push -qu origin 'feature/#5-unmerged'
git push -q origin --delete 'feature/#5-unmerged'
git switch -q develop

# ---- トランスクリプト回収の fixture -------------------------------------------

add_clean_gone_worktree() {
  # $1: branch / $2: worktree path
  # develop と同じ HEAD（= git branch -d だけで消せる）の [gone] ブランチと
  # clean な worktree を用意し、-D エスカレーションの経路と独立させる。
  git branch -q "$1" develop
  # hook 導入後も fixture 組み立てが止まらないよう、セットアップ push だけ
  # --no-verify する。cleanup 本体の削除経路は env で抜ける契約を別途検証する。
  git push -q --no-verify -u origin "$1"
  git worktree add -q "$2" "$1"
  git push -q --no-verify origin --delete "$1"
}

transcript_name_of() {
  # $1: 実在するディレクトリ。Claude Code がセッショントランスクリプトに使う
  # 名前（symlink 解決済み絶対パスの英数字以外を '-' に潰したもの）を返す。
  # macOS の $TMPDIR は /var -> /private/var の symlink 配下なので、
  # 解決前のパスから作ると実装と一致しない。
  ( cd "$1" && pwd -P ) | sed 's/[^a-zA-Z0-9]/-/g'
}

make_transcript_dir() {
  # $1: ディレクトリ名 / $2: jsonl に記録する cwd（空なら jsonl を作らない）
  local dir="$FF_MERGE_CLEANUP_PROJECTS_DIR/$1"
  mkdir -p "$dir"
  if [ -n "$2" ]; then
    printf '{"type":"user","cwd":"%s","message":"hello"}\n' "$2" > "$dir/session.jsonl"
  else
    # 本体の 30 日クリーンアップで jsonl だけ消え、subagents/ が残った状態
    mkdir -p "$dir/subagents"
    echo leftover > "$dir/subagents/leftover.txt"
  fi
}

# cwd 一致 → アーカイブされる
add_clean_gone_worktree 'feature/#20-wt-match' "$TMP/wt-20"
NAME_MATCH="$(transcript_name_of "$TMP/wt-20")"
make_transcript_dir "$NAME_MATCH" "$(cd "$TMP/wt-20" && pwd -P)"

# cwd が別プロジェクトを指す → 触らない
add_clean_gone_worktree 'feature/#21-wt-mismatch' "$TMP/wt-21"
NAME_MISMATCH="$(transcript_name_of "$TMP/wt-21")"
make_transcript_dir "$NAME_MISMATCH" "/somewhere/else/project"

# jsonl が無く、名前から worktree 由来と判別できる → アーカイブされる
mkdir -p "$TMP/worktrees"
add_clean_gone_worktree 'feature/#22-wt-nojsonl' "$TMP/worktrees/wt-22"
NAME_NOJSONL="$(transcript_name_of "$TMP/worktrees/wt-22")"
make_transcript_dir "$NAME_NOJSONL" ""

# jsonl はあるが cwd を 1 つも含まない → 触らない。
# プラグインが書く付随データ（skill-injections.jsonl 等）の常態がこれで、
# 「jsonl が 1 つも無い」ケースとは別の経路を通る（grep が一致 0 件で終わる）
add_clean_gone_worktree 'feature/#39-wt-nocwd' "$TMP/wt-39"
NAME_NOCWD="$(transcript_name_of "$TMP/wt-39")"
mkdir -p "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_NOCWD/vercel-plugin"
printf '{"timestamp":"t","event":"skill","injectedSkills":[]}\n' \
  > "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_NOCWD/vercel-plugin/skill-injections.jsonl"

# jsonl も worktree 由来の手掛かりも無い → 触らない
add_clean_gone_worktree 'feature/#23-wt-opaque' "$TMP/wt-23"
NAME_OPAQUE="$(transcript_name_of "$TMP/wt-23")"
make_transcript_dir "$NAME_OPAQUE" ""

# 削除されない dirty worktree の分は、cwd が一致していても最後まで残ること
NAME_DIRTY="$(transcript_name_of "$TMP/wt-dirty")"
make_transcript_dir "$NAME_DIRTY" "$(cd "$TMP/wt-dirty" && pwd -P)"

# 候補名が projects 外への symlink → 辿らない（パストラバーサル防止）。
# リンク先には「ガードが無ければ確実に回収されてしまう」内容（cwd 一致の jsonl）を
# 置く。ここを空にすると、後段の所有者確認で弾かれるだけの fixture になり、
# ガードを両方外しても緑のままになる。
add_clean_gone_worktree 'feature/#24-wt-symlink' "$TMP/wt-24"
NAME_SYMLINK="$(transcript_name_of "$TMP/wt-24")"
mkdir -p "$TMP/outside-transcripts"
echo keep-me > "$TMP/outside-transcripts/keep.txt"
printf '{"type":"user","cwd":"%s","message":"hello"}\n' "$(cd "$TMP/wt-24" && pwd -P)" \
  > "$TMP/outside-transcripts/session.jsonl"
ln -s "$TMP/outside-transcripts" "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_SYMLINK"

# セッションが途中で親リポジトリへ移動した履歴。worktree を指す cwd が 1 つでも
# あれば回収する（全 cwd の一致を要求すると正当なものを取りこぼす）
add_clean_gone_worktree 'feature/#28-wt-multicwd' "$TMP/wt-28"
NAME_MULTICWD="$(transcript_name_of "$TMP/wt-28")"
make_transcript_dir "$NAME_MULTICWD" "$(cd "$TMP/wt-28" && pwd -P)"
printf '{"type":"user","cwd":"%s","message":"moved"}\n' "$(cd "$TMP/work" && pwd -P)" \
  >> "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_MULTICWD/session.jsonl"

# 2 つ目の命名規則（'.' と '_' を保持）だけが存在するケース。$TMPDIR は
# 'tmp.XXXX' を含むので 2 つの規則は必ず別名になり、A 側の名前は存在しない
add_clean_gone_worktree 'feature/#29-wt-variant-b' "$TMP/wt-29"
NAME_VARIANT_B="$( (cd "$TMP/wt-29" && pwd -P) | sed 's/[^a-zA-Z0-9._]/-/g' )"
NAME_VARIANT_A="$(transcript_name_of "$TMP/wt-29")"
if [ "$NAME_VARIANT_B" = "$NAME_VARIANT_A" ]; then
  echo "  ✗ fixture 前提が崩れています（2 つの命名規則が同一）" >&2
  FAIL=$((FAIL + 1))
fi
make_transcript_dir "$NAME_VARIANT_B" "$(cd "$TMP/wt-29" && pwd -P)"

# 一部の jsonl が読めないケース。読めた分だけで「一致」と判定してはいけない
add_clean_gone_worktree 'feature/#30-wt-scanerr' "$TMP/wt-30"
NAME_SCANERR="$(transcript_name_of "$TMP/wt-30")"
make_transcript_dir "$NAME_SCANERR" "$(cd "$TMP/wt-30" && pwd -P)"
mkdir -p "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_SCANERR/locked"
printf '{"type":"user","cwd":"/somewhere/else"}\n' \
  > "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_SCANERR/locked/hidden.jsonl"
chmod 000 "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_SCANERR/locked"

# 同じ「読めない」でも、ディレクトリを辿れない場合（find が失敗する）と
# ファイルを読めない場合（find は成功し grep が失敗する）は別経路になる。
# 片方だけを fixture にすると、もう片方の検出を外しても緑のままになる。
add_clean_gone_worktree 'feature/#38-wt-unreadable' "$TMP/wt-38"
NAME_UNREADABLE="$(transcript_name_of "$TMP/wt-38")"
make_transcript_dir "$NAME_UNREADABLE" "$(cd "$TMP/wt-38" && pwd -P)"
printf '{"type":"user","cwd":"/somewhere/else"}\n' \
  > "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_UNREADABLE/unreadable.jsonl"
chmod 000 "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_UNREADABLE/unreadable.jsonl"

# ---- mock gh ------------------------------------------------------------------

MOCK="$TMP/mock-bin"
mkdir -p "$MOCK"

cat > "$MOCK/pr_view_10.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#10-target",
  "headRefOid": "$OID_TARGET",
  "baseRefName": "develop",
  "title": "test target PR",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_list_merged.json" <<JSON
[
  {"headRefName": "feature/#10-target", "headRefOid": "$OID_TARGET", "isCrossRepository": false},
  {"headRefName": "feature/#1-merged-exact", "headRefOid": "$OID_EXACT", "isCrossRepository": false},
  {"headRefName": "feature/#2-reused", "headRefOid": "$OID_REUSED_MERGED", "isCrossRepository": false},
  {"headRefName": "feature/#3-open-reuse", "headRefOid": "$OID_OPEN", "isCrossRepository": false},
  {"headRefName": "release/1.0", "headRefOid": "$OID_RELEASE", "isCrossRepository": false},
  {"headRefName": "feature/#17-retry-succeeds", "headRefOid": "$OID_RETRY17", "isCrossRepository": false},
  {"headRefName": "feature/#18-changed-before-retry", "headRefOid": "$OID_CHANGED18", "isCrossRepository": false},
  {"headRefName": "feature/#20-vanished-before-retry", "headRefOid": "$OID_VANISHED20", "isCrossRepository": false},
  {"headRefName": "feature/#21-prune-fails", "headRefOid": "$OID_PRUNEFAIL21", "isCrossRepository": false},
  {"headRefName": "feature/#22-retry-fails", "headRefOid": "$OID_RETRYFAIL22", "isCrossRepository": false},
  {"headRefName": "feature/#23-leftover-for-14", "headRefOid": "$OID_LEFTOVER23", "isCrossRepository": false},
  {"headRefName": "feature/#41-null-oid", "headRefOid": null, "isCrossRepository": false},
  {"headRefName": "feature/#42-null-oid-mixed", "headRefOid": "$OID_NULLOID42", "isCrossRepository": false},
  {"headRefName": "feature/#43-null-oid-lease", "headRefOid": "$OID_NULLOID43", "isCrossRepository": false},
  {"headRefName": "feature/#44-null-oid-failure", "headRefOid": "$OID_NULLOID44", "isCrossRepository": false},
  {"headRefName": "feature/#45-null-oid-vanished", "headRefOid": "$OID_NULLOID45", "isCrossRepository": false},
  {"headRefName": "feature/#46-null-oid-gone", "headRefOid": "$OID_NULLOID46", "isCrossRepository": false},
  {"headRefName": "feature/#47-crosspair", "headRefOid": "$OID_CROSSPAIR_MERGED", "isCrossRepository": false},
  {"headRefName": "feature/#48-crosspair-other", "headRefOid": "$OID_CROSSPAIR_NOW", "isCrossRepository": false}
]
JSON

cat > "$MOCK/pr_list_open.json" <<JSON
[
  {"headRefName": "feature/#3-open-reuse"}
]
JSON

cat > "$MOCK/pr_view_99.json" <<JSON
{
  "state": "OPEN",
  "headRefName": "feature/#99-open",
  "headRefOid": "0000000000000000000000000000000000000000",
  "baseRefName": "develop",
  "title": "still open PR",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_11.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#10-target",
  "headRefOid": "$OID_TARGET",
  "baseRefName": "develop",
  "title": "dirty base owner guard",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_12.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#12-already-removed",
  "headRefOid": "$OID_TARGET",
  "baseRefName": "develop",
  "title": "already removed remote",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_13.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#2-reused",
  "headRefOid": "$OID_REUSED_MERGED",
  "baseRefName": "develop",
  "title": "remote updated after merge",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_14.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#14-recheck-fails",
  "headRefOid": "$OID_TARGET",
  "baseRefName": "develop",
  "title": "remote re-check failure",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_15.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#15-same-oid",
  "headRefOid": "$OID_SAME",
  "baseRefName": "develop",
  "title": "same oid after lease rejection",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_16.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#16-warning-missing",
  "headRefOid": "$OID_TARGET",
  "baseRefName": "develop",
  "title": "missing ref with stderr warning",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_17.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#17-retry-succeeds",
  "headRefOid": "$OID_RETRY17",
  "baseRefName": "develop",
  "title": "step 4 failure retried by step 6",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_18.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#18-changed-before-retry",
  "headRefOid": "$OID_CHANGED18",
  "baseRefName": "develop",
  "title": "remote advanced while step 4 was failing",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_20.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#20-vanished-before-retry",
  "headRefOid": "$OID_VANISHED20",
  "baseRefName": "develop",
  "title": "ref vanished before the step 6 retry",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_21.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#21-prune-fails",
  "headRefOid": "$OID_PRUNEFAIL21",
  "baseRefName": "develop",
  "title": "post-delete fetch --prune fails",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_22.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#22-retry-fails",
  "headRefOid": "$OID_RETRYFAIL22",
  "baseRefName": "develop",
  "title": "step 6 retry fails as well",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_41.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#41-null-oid",
  "headRefOid": null,
  "baseRefName": "develop",
  "title": "headRefOid is null",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_42.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#42-null-oid-mixed",
  "headRefOid": null,
  "baseRefName": "develop",
  "title": "headRefOid is null but the merged list has it",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_43.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#43-null-oid-lease",
  "headRefOid": null,
  "baseRefName": "develop",
  "title": "headRefOid is null and the leftover deletion is lease-rejected",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_44.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#44-null-oid-failure",
  "headRefOid": null,
  "baseRefName": "develop",
  "title": "headRefOid is null and the leftover deletion fails outright",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_45.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#45-null-oid-vanished",
  "headRefOid": null,
  "baseRefName": "develop",
  "title": "headRefOid is null and the ref vanishes before the leftover deletion",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_46.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#46-null-oid-gone",
  "headRefOid": null,
  "baseRefName": "develop",
  "title": "headRefOid is null and the remote ref is already gone",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/gh" <<SH
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  "pr view 10 --json"*)   cat "$MOCK/pr_view_10.json" ;;
  "pr view 11 --json"*)   cat "$MOCK/pr_view_11.json" ;;
  "pr view 12 --json"*)   cat "$MOCK/pr_view_12.json" ;;
  "pr view 13 --json"*)   cat "$MOCK/pr_view_13.json" ;;
  "pr view 14 --json"*)   cat "$MOCK/pr_view_14.json" ;;
  "pr view 15 --json"*)   cat "$MOCK/pr_view_15.json" ;;
  "pr view 16 --json"*)   cat "$MOCK/pr_view_16.json" ;;
  "pr view 17 --json"*)   cat "$MOCK/pr_view_17.json" ;;
  "pr view 18 --json"*)   cat "$MOCK/pr_view_18.json" ;;
  "pr view 20 --json"*)   cat "$MOCK/pr_view_20.json" ;;
  "pr view 21 --json"*)   cat "$MOCK/pr_view_21.json" ;;
  "pr view 22 --json"*)   cat "$MOCK/pr_view_22.json" ;;
  "pr view 41 --json"*)   cat "$MOCK/pr_view_41.json" ;;
  "pr view 42 --json"*)   cat "$MOCK/pr_view_42.json" ;;
  "pr view 43 --json"*)   cat "$MOCK/pr_view_43.json" ;;
  "pr view 44 --json"*)   cat "$MOCK/pr_view_44.json" ;;
  "pr view 45 --json"*)   cat "$MOCK/pr_view_45.json" ;;
  "pr view 46 --json"*)   cat "$MOCK/pr_view_46.json" ;;
  "pr view 99 --json"*)   cat "$MOCK/pr_view_99.json" ;;
  *"--state merged"*)     cat "$MOCK/pr_list_merged.json" ;;
  *"--state open"*)       cat "$MOCK/pr_list_open.json" ;;
  *) echo "mock gh: unexpected args: \$args" >&2; exit 1 ;;
esac
SH
chmod +x "$MOCK/gh"

REAL_GIT="$(command -v git)"
cat > "$MOCK/git" <<SH
#!/usr/bin/env bash
if [ "\$*" = "ls-remote --heads origin refs/heads/feature/#14-recheck-fails" ]; then
  echo "simulated remote re-check failure" >&2
  exit 1
fi
if [[ "\$*" == push\ --force-with-lease=refs/heads/feature/\#15-same-oid:* ]]; then
  echo "simulated stale info for same OID" >&2
  exit 1
fi
if [[ "\$*" == push\ --force-with-lease=refs/heads/feature/\#16-warning-missing:* ]]; then
  echo "simulated stale info for missing ref" >&2
  exit 1
fi
# 15f: 削除反映の fetch --prune を失敗させる（Step 3 の 1 回目は通す）。
# 有効化フラグは 6.15 の直前に作り、直後に消すので他 run へ漏れない。
if [ -f "$TMP/prune21.enabled" ] && [ "\$*" = "fetch --prune origin" ]; then
  if [ -f "$TMP/prune21.first" ]; then
    echo "simulated fetch --prune failure" >&2
    exit 1
  fi
  : > "$TMP/prune21.first"
fi
# 15e: Step 4 も Step 6 の再試行も失敗する（リモートは期待 OID のまま残る）。
if [[ "\$*" == push\ --force-with-lease=refs/heads/feature/\#22-retry-fails:* ]]; then
  # 出力を一切出さずに失敗する（last_push_error が空になる経路のフォールバック検証）
  exit 1
fi
# 15j: 混在ケースで Step 6 の削除 push が一般エラーで失敗する（stale info ではない）。
if [[ "\$*" == push\ --force-with-lease=refs/heads/feature/\#44-null-oid-failure:* ]]; then
  echo "simulated transport failure for the leftover deletion" >&2
  exit 1
fi
# 15k: 混在ケースで、Step 6 の削除 push の時点には ref が消えている。
if [[ "\$*" == push\ --force-with-lease=refs/heads/feature/\#45-null-oid-vanished:* ]]; then
  SKIP_SIMPLE_GIT_HOOKS=1 "$REAL_GIT" push -q origin \
    --delete 'feature/#45-null-oid-vanished'
  echo "error: unable to delete 'feature/#45-null-oid-vanished': remote ref does not exist" >&2
  exit 1
fi
# 15i: 混在ケースで Step 6 の削除 push が lease 拒否になる。照合（ls-remote）の後に
# 別の push が着地した状況を再現する。再取得は素通りさせるので rc=3 へ落ちる。
if [[ "\$*" == push\ --force-with-lease=refs/heads/feature/\#43-null-oid-lease:* ]]; then
  SKIP_SIMPLE_GIT_HOOKS=1 "$REAL_GIT" push -q --force origin \
    "$OID_NULLOID43B:refs/heads/feature/#43-null-oid-lease"
  echo "stale info: simulated push landed after the leftover match" >&2
  exit 1
fi
# 15c: Step 4 の削除 push が失敗する間に、別の push がリモートへ着地する。
# stale info ではない一般的な失敗なので、再取得を経ずに rc=1 へ落ちる経路も兼ねる。
if [[ "\$*" == push\ --force-with-lease=refs/heads/feature/\#18-changed-before-retry:* ]]; then
  SKIP_SIMPLE_GIT_HOOKS=1 "$REAL_GIT" push -q --force origin \
    "$OID_CHANGED18B:refs/heads/feature/#18-changed-before-retry"
  echo "simulated transport failure while another push landed" >&2
  exit 1
fi
# 15d: Step 4 は一般的な失敗で rc=1。Step 6 の再試行時点では ref が消えている
# （Step 6 の ls-remote には映っていたが、削除 push までの間に外部が消した）。
if [[ "\$*" == push\ --force-with-lease=refs/heads/feature/\#20-vanished-before-retry:* ]]; then
  if [ ! -f "$TMP/vanished20.attempted" ]; then
    : > "$TMP/vanished20.attempted"
    echo "simulated transport failure" >&2
    exit 1
  fi
  SKIP_SIMPLE_GIT_HOOKS=1 "$REAL_GIT" push -q origin \
    --delete 'feature/#20-vanished-before-retry'
  echo "error: unable to delete 'feature/#20-vanished-before-retry': remote ref does not exist" >&2
  exit 1
fi
if [[ "\$*" == push\ --force-with-lease=refs/heads/feature/\#17-retry-succeeds:* ]] \
  && [ ! -f "$TMP/retry17.attempted" ]; then
  : > "$TMP/retry17.attempted"
  echo "simulated stale info for first attempt" >&2
  exit 1
fi
if [ "\$*" = "ls-remote --heads origin refs/heads/feature/#16-warning-missing" ]; then
  echo "simulated non-fatal warning" >&2
  FF_REACHED_END=1
  exit 0
fi
# 32.5 系: status の故障注入。ガード側（除外を適用した status。pathspec に :(top) を
# 含む）・報告側（肯定形。:(glob,top) で始まる）・素の status（除外未設定の既定経路）を
# 別フラグに分ける。1 つのフラグで前方一致させると、Step 1 のガード側が先に落ちて
# 報告側の失敗経路へ一度も到達しない。フラグは各ケースの直前に作り直後に消すので、
# 他の run には漏れない。-C 付き（base 所有 worktree 経路）も同じ判定に乗る。
if [ -f "$TMP/statusfail-guard.enabled" ] && [[ "\$*" == *status\ --porcelain\ --\ :\(top\)* ]]; then
  echo "simulated git status failure" >&2
  exit 1
fi
if [ -f "$TMP/statusfail-ignored.enabled" ] && [[ "\$*" == *status\ --porcelain\ --\ :\(glob,top\)* ]]; then
  echo "simulated git status failure (ignored list)" >&2
  exit 1
fi
if [ -f "$TMP/statusfail-plain.enabled" ] && [[ "\$*" == *status\ --porcelain ]]; then
  echo "simulated git status failure (plain)" >&2
  exit 1
fi
# 32.5e: stderr へ何も出さずに失敗する（詳細不明メッセージの分岐を通す）
if [ -f "$TMP/statusfail-silent.enabled" ] && [[ "\$*" == *status\ --porcelain ]]; then
  exit 1
fi
# 32.7d: base 所有 worktree（-C <実パス>）のガード status だけを失敗させる。
# Step 1 は -C "" で呼ぶため \$2 が空になり一致しない（Step 1 を先に落とすと
# Step 3 の失敗経路へ一度も到達しない）。
if [ -f "$TMP/statusfail-basewt.enabled" ] && [[ "\$*" == -C\ /* ]] \
  && [[ "\$*" == *status\ --porcelain\ --\ :\(top\)* ]]; then
  echo "simulated git status failure (base worktree)" >&2
  exit 1
fi
# 32.7c: base 所有 worktree の status を「exit 0 + stderr に警告」にする。
# 走査が不完全なまま通ってしまう形（Permission denied 等）の再現。
if [ -f "$TMP/statuswarn-basewt.enabled" ] && [[ "\$*" == -C\ * ]] \
  && [[ "\$*" == *status\ --porcelain* ]]; then
  echo "warning: could not open directory 'videos/': Permission denied" >&2
  exec "$REAL_GIT" "\$@"
fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$MOCK/git"

REAL_TAR="$(command -v tar)"
cat > "$MOCK/tar" <<SH
#!/usr/bin/env bash
if [ -n "\${MOCK_TAR_FAIL:-}" ] && [ "\$1" = "-czf" ]; then
  # 中途半端な成果物を残して失敗する状況を再現する（-czf の次が出力先）
  : > "\$2" 2>/dev/null || true
  echo "simulated tar failure" >&2
  exit 1
fi
if [ -n "\${MOCK_TAR_APPEND:-}" ] && [ "\$1" = "-czf" ]; then
  # アーカイブを作った直後に、生きたセッションが元へ書き足した状況を再現する
  # （引数は -czf <出力> -C <projects> ./<名前>）
  "$REAL_TAR" "\$@" || exit \$?
  printf '%s\n' '{"appended":true}' >> "\$4/\$5/session.jsonl" 2>/dev/null || true
  FF_REACHED_END=1
  exit 0
fi
if [ -n "\${MOCK_TAR_CORRUPT:-}" ] && [ "\$1" = "-czf" ]; then
  # 成功を名乗りながら読めない成果物を残す。終了コードだけを信じると、
  # 中身が失われたまま元ディレクトリが消える
  : > "\$2" 2>/dev/null || true
  FF_REACHED_END=1
  exit 0
fi
exec "$REAL_TAR" "\$@"
SH
chmod +x "$MOCK/tar"

REAL_DATE="$(command -v date)"
cat > "$MOCK/date" <<SH
#!/usr/bin/env bash
if [ -n "\${MOCK_FIXED_STAMP:-}" ] && [ "\$1" = "+%Y%m%d-%H%M%S" ]; then
  # アーカイブ名の衝突を再現するため、タイムスタンプを固定する
  printf '%s\n' "\$MOCK_FIXED_STAMP"
  FF_REACHED_END=1
  exit 0
fi
exec "$REAL_DATE" "\$@"
SH
chmod +x "$MOCK/date"

REAL_DU="$(command -v du)"
cat > "$MOCK/du" <<SH
#!/usr/bin/env bash
if [ -n "\${MOCK_DU_FAIL:-}" ]; then
  echo "simulated du failure" >&2
  exit 1
fi
exec "$REAL_DU" "\$@"
SH
chmod +x "$MOCK/du"

# ---- 実行 ----------------------------------------------------------------------

echo "== merge-cleanup 破壊的経路テスト =="

remote_has() { git ls-remote --heads origin "refs/heads/$1" | grep . >/dev/null; }

# simple-git-hooks 相当の pre-push: SKIP_SIMPLE_GIT_HOOKS=1 のときだけ通す。
# fixture 組み立て（setup 中の git push --delete）が終わったあとで入れる。
# worktree からもメイン .git/hooks を共有するので、呼び出し元 worktree でも効く。
git branch -q 'feature/#31-hook-probe' develop
git push -q origin 'feature/#31-hook-probe'
# 相対パスだと呼び出し元 worktree へ移ったあと -x 判定が外れる
HOOK_PATH="$TMP/work/.git/hooks/pre-push"
HOOK_LOG="$TMP/pre-push-hook.log"
: > "$HOOK_LOG"
cat > "$HOOK_PATH" <<HOOK
#!/bin/sh
if [ "\${SKIP_SIMPLE_GIT_HOOKS:-}" = "1" ]; then
  printf 'skip=1\n' >> "$HOOK_LOG"
  exit 0
fi
printf 'block\n' >> "$HOOK_LOG"
echo "pre-push gate ran (SKIP_SIMPLE_GIT_HOOKS is not 1)" >&2
exit 1
HOOK
chmod +x "$HOOK_PATH"

set +e
env -u SKIP_SIMPLE_GIT_HOOKS git push -q origin --delete 'feature/#31-hook-probe' >/dev/null 2>&1
HOOK_BLOCK_RC=$?
set -e
if [ "$HOOK_BLOCK_RC" -ne 0 ] && remote_has 'feature/#31-hook-probe'; then
  ok "fixture hook は SKIP_SIMPLE_GIT_HOOKS 無しの削除 push を拒否する（self-test）"
else
  bad "fixture hook が削除 push を拒否しない — 以降の削除成功はゲート回避の証拠にならない"
fi
# 取り残し照合の mock に載せないので Step 6 は触らない。リモートに残してよい。

# 呼び出し元を detached worktree に移し、元 clone が develop を保持する競合を再現する。
# ignored file は clean 判定に出ないが、退避のために worktree ごと消してはならない。
BASE_OWNER="$(git rev-parse --show-toplevel)"
CALLER="$TMP/wt-caller"
printf '%s\n' '.cleanup-owner-preserved' >> "$BASE_OWNER/.git/info/exclude"
echo preserve-me > "$BASE_OWNER/.cleanup-owner-preserved"
git worktree add -q --detach "$CALLER" develop
cd "$CALLER"

# merge-cleanup はこちらの worktree から走る。hook 共有をここで実測する。
set +e
env -u SKIP_SIMPLE_GIT_HOOKS git push -q origin --delete 'feature/#31-hook-probe' >/dev/null 2>&1
HOOK_WT_RC=$?
set -e
if [ "$HOOK_WT_RC" -ne 0 ] && remote_has 'feature/#31-hook-probe'; then
  ok "呼び出し元 worktree からも fixture hook が削除 push を拒否する（self-test）"
else
  bad "呼び出し元 worktree で fixture hook が効いていない"
fi
: > "$HOOK_LOG"

# 未マージ PR: 破壊的処理の前に exit 1 で中断し、リモートに手を付けないこと
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 99 > "$TMP/run-99.log" 2>&1
EXIT_99=$?
set -e
if [ "$EXIT_99" -eq 1 ] && remote_has 'feature/#1-merged-exact'; then
  ok "未マージ PR は破壊的処理前に exit 1 で中断"
else
  bad "未マージ PR の中断が期待どおりでない (exit=$EXIT_99)"
fi

# dirty な base 所有 worktree は detach せず、リモート削除前に停止すること
echo work-in-progress > "$BASE_OWNER/base-owner-dirty.txt"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 11 > "$TMP/run-11.log" 2>&1
EXIT_11=$?
set -e
if [ "$EXIT_11" -eq 1 ] \
  && [ "$(git -C "$BASE_OWNER" branch --show-current)" = "develop" ] \
  && [ -z "$(git branch --show-current)" ] \
  && remote_has 'feature/#10-target' \
  && grep -q "base ブランチの退避と cleanup を中断" "$TMP/run-11.log"; then
  ok "dirty な base 所有 worktree を変更せず、破壊的処理前に exit 1 で中断"
else
  bad "dirty な base 所有 worktree の保護が期待どおりでない (exit=$EXIT_11)"
fi
rm -f "$BASE_OWNER/base-owner-dirty.txt"

set +e
PATH="$MOCK:$PATH" bash "$TARGET" 10 > "$TMP/run.log" 2>&1
EXIT_CODE=$?
set -e

# 1. 対象 PR のリモートブランチが削除される
if remote_has 'feature/#10-target'; then
  bad "対象 PR のリモートブランチが削除されていない (feature/#10-target)"
else
  ok "対象 PR のリモートブランチを削除 (feature/#10-target)"
fi

# 2. (名前, OID) 一致の取り残しは削除される
if remote_has 'feature/#1-merged-exact'; then
  bad "OID 一致の取り残しが削除されていない (feature/#1-merged-exact)"
else
  ok "OID 一致の取り残しを削除 (feature/#1-merged-exact)"
fi

# 31. hook が実際に走り、SKIP_SIMPLE_GIT_HOOKS=1 を見て skip したことをログで見る。
# --no-verify / hooksPath 無効化だと skip=1 は増えない（hook 自体が起動しない）。
HOOK_SKIPS="$(grep -c '^skip=1$' "$HOOK_LOG" 2>/dev/null || true)"
HOOK_BLOCKS="$(grep -c '^block$' "$HOOK_LOG" 2>/dev/null || true)"
if [ "${HOOK_SKIPS:-0}" -ge 2 ] && [ "${HOOK_BLOCKS:-0}" -eq 0 ]; then
  ok "削除 push で fixture hook が SKIP_SIMPLE_GIT_HOOKS=1 を見て skip した"
else
  bad "fixture hook の skip ログが期待どおりでない (skip=${HOOK_SKIPS:-0} block=${HOOK_BLOCKS:-0})"
fi

# 3. OID 不一致（マージ後 push あり）は削除されない
if remote_has 'feature/#2-reused'; then
  ok "OID 不一致の再利用ブランチを保護 (feature/#2-reused)"
else
  bad "マージ後 push のあるブランチが誤削除された (feature/#2-reused)"
fi

# 6.22 OID 不一致の取り残しは、削除が拒否されるより前に**取り残し候補一覧そのもの
#      から除外される**。
#
#      直前の項目 3（remote_has）だけでは、Step 6 の事前照合を「名前一致のみ」へ
#      退化させても検出できない: 削除 push が --force-with-lease（アンカーは
#      MERGED 一覧側の OID）に拒まれ、結局「削除されない」という同じ観測へ落ちる
#      ためで、二重の防御のうち外側（事前照合）が消えた事実が内側に吸われる。
#      そこで候補一覧を直接読み、事前照合の段階で除外されていることを固定する。
#
#      この退化を赤にできる検査は従来 6.12（Step 4 の失敗中に別 OID へ進んだ
#      ブランチ）だけで、そちらは再試行経路のシナリオに従属している。基本の
#      取り残し経路（本ケース）では lease 拒否に吸収されて緑のままだった。
#      シナリオ従属の検査は差し替えれば消えるため、照合そのものを主題にした
#      検査をここへ独立に置く。
leftover_candidates() {
  # $1: 実行ログ。Step 6 が出す取り残し候補一覧のブランチ名だけを 1 行 1 件で返す。
  # 一覧は見出しの直後に "  - <branch>" が並び、空行で終わる。
  awk '
    /^🧹 リモート取り残しのマージ済みブランチを検出しました:$/ { in_list = 1; next }
    in_list && /^  - / { sub(/^  - /, ""); print; next }
    in_list { exit }
  ' "$1"
}

# 一覧はファイルへ落として grep する。パイプで grep -q へ渡すと、一致で早期終了した
# grep が上流へ SIGPIPE を返し、pipefail 下ではその 141 が条件式の値になって
# 「一致したのに偽」という反転を起こす。
LEFTOVER_CANDIDATES="$TMP/run-leftover-candidates.txt"
leftover_candidates "$TMP/run.log" > "$LEFTOVER_CANDIDATES"

# 先に「一覧を読み出せている」ことを固定する（green pin）。見出しの文言が変わって
# awk が何も拾わなくなると、後続の「載っていない」は空振りで緑になるため。
if grep -qxF 'feature/#1-merged-exact' "$LEFTOVER_CANDIDATES"; then
  ok "取り残し候補一覧を読み出せる（(名前, OID) 一致の feature/#1-merged-exact が載る）"
else
  bad "取り残し候補一覧を読み出せない — 以降の「載っていない」主張は空振りの可能性がある"
  { grep -n 'リモート取り残し' "$TMP/run.log" | tail -5 | sed 's/^/     /' >&2 || true; }
fi

if grep -qxF 'feature/#2-reused' "$LEFTOVER_CANDIDATES"; then
  bad "OID 不一致の再利用ブランチが取り残し候補一覧に載っている（事前照合が名前一致へ退化）"
  { tail -20 "$LEFTOVER_CANDIDATES" | sed 's/^/     /' >&2 || true; }
else
  ok "OID 不一致の再利用ブランチは取り残し候補一覧に載らない (feature/#2-reused)"
fi

# 同じことを削除側からも見る。事前照合で除外されていれば削除は試みられないので、
# lease 拒否のスキップ記録（= 内側の防御が働いた痕跡）もサマリーの列挙も残らない。
# 特定の文言（"lease 拒否): <branch>"）ではなく実行ログ全体での言及 0 件で見るのは、
# 診断文言が変わったときに検査が黙って通る形を避けるため。正しい実行では Step 6 が
# この branch に一切触れないので、この run のログには 1 度も名前が出ない（実測値）。
if grep -qF 'feature/#2-reused' "$TMP/run.log"; then
  bad "OID 不一致の再利用ブランチが Step 6 の処理対象になっている（事前照合を通過している）"
  { grep -n -F 'feature/#2-reused' "$TMP/run.log" | tail -5 | sed 's/^/     /' >&2 || true; }
else
  ok "OID 不一致の再利用ブランチは実行ログに一度も現れない（削除自体を試みていない）"
fi

# 6.23 照合は (名前, OID) の**ペア**で行う。名前の集合と OID の集合を独立に見る形
#      （名前がどれかの head と一致し、かつ OID がどれかの head と一致すれば通す）は、
#      6.22 の入力では区別が付かない — feature/#2-reused の現 OID はどのマージ済み
#      head でもないため、集合独立でも一致しないからだ。区別できるのは、名前と OID を
#      別々の PR から借りられる入力だけ。feature/#47-crosspair は名前が PR A と、
#      現 OID が PR B と一致するが、そのどちらのペアとも一致しない。
#      集合独立の退化では削除まで到達する（lease のアンカーがリモートの現 OID に
#      なるため lease でも止まらない）ので、リモートの残存も併せて固定する。
if grep -qxF 'feature/#47-crosspair' "$LEFTOVER_CANDIDATES"; then
  bad "クロスペアのブランチが取り残し候補一覧に載っている（名前と OID を独立に照合している）"
  { tail -20 "$LEFTOVER_CANDIDATES" | sed 's/^/     /' >&2 || true; }
else
  ok "名前と OID を別 PR から借りたブランチは取り残し候補一覧に載らない (feature/#47-crosspair)"
fi

if grep -qF 'feature/#47-crosspair' "$TMP/run.log"; then
  bad "クロスペアのブランチが Step 6 の処理対象になっている（ペア照合が集合照合へ退化）"
  { grep -n -F 'feature/#47-crosspair' "$TMP/run.log" | tail -5 | sed 's/^/     /' >&2 || true; }
else
  ok "クロスペアのブランチは実行ログに一度も現れない (feature/#47-crosspair)"
fi

if remote_has 'feature/#47-crosspair'; then
  ok "クロスペアのブランチを保護 (feature/#47-crosspair)"
else
  bad "名前と OID が別 PR 由来のブランチが誤削除された (feature/#47-crosspair)"
fi

# 4. open PR の head は削除されない
if remote_has 'feature/#3-open-reuse'; then
  ok "open PR の head を保護 (feature/#3-open-reuse)"
else
  bad "open PR の head が誤削除された (feature/#3-open-reuse)"
fi

# 5. 保護ブランチは削除されない
if remote_has 'release/1.0'; then
  ok "保護ブランチを保護 (release/1.0)"
else
  bad "保護ブランチが誤削除された (release/1.0)"
fi

# 5.5 未マージの固有コミットを持つ [gone] ブランチは -D されない
if git show-ref -q "refs/heads/feature/#5-unmerged"; then
  ok "未マージ [gone] ブランチを保護 (feature/#5-unmerged)"
else
  bad "未マージの固有コミットを持つ [gone] ブランチが誤削除された (feature/#5-unmerged)"
fi

# 6. dirty worktree と対応ブランチが残っている + PARTIAL 終了
if [ -f "$TMP/wt-dirty/wip.txt" ] && git show-ref -q "refs/heads/feature/#10-target"; then
  ok "dirty worktree と対応 [gone] ブランチを保護"
else
  bad "dirty worktree または対応ブランチが失われた"
fi

if [ "$EXIT_CODE" -eq 2 ]; then
  ok "部分失敗（dirty worktree）で終了コード 2 (PARTIAL)"
else
  bad "終了コードが 2 ではない: $EXIT_CODE"
fi

# 6.5 clean な base 所有 worktree は detached へ退避し、呼び出し元が base へ復帰する。
# ignored file と worktree 自体は残す。
if [ "$(git branch --show-current)" = "develop" ] \
  && [ -z "$(git -C "$BASE_OWNER" branch --show-current)" ] \
  && [ -f "$BASE_OWNER/.cleanup-owner-preserved" ] \
  && git worktree list --porcelain | grep -F "worktree $BASE_OWNER" >/dev/null; then
  ok "clean な base 所有 worktree と ignored file を保ち、呼び出し元を develop へ復帰"
else
  bad "clean な base 所有 worktree の退避または呼び出し元の develop 復帰に失敗"
fi

# 6.6 リモート ref が既に無い場合、`stale info` を lease 拒否と誤表示しない。
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-12.log" 2>&1
EXIT_12=$?
set -e
if [ "$EXIT_12" -eq 2 ] \
  && grep -q "リモートブランチは既に削除されていました" "$TMP/run-12.log" \
  && ! grep -q "マージ後に更新されています" "$TMP/run-12.log"; then
  ok "削除済みリモート branch を already removed と判定"
else
  bad "削除済みリモート branch の判定が期待どおりでない (exit=$EXIT_12)"
fi

# 6.7 ref が別 OID で存在する真の競合は、従来どおり lease 拒否で保護する。
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 13 > "$TMP/run-13.log" 2>&1
EXIT_13=$?
set -e
if [ "$EXIT_13" -eq 2 ] \
  && remote_has 'feature/#2-reused' \
  && grep -q "マージ後に更新されています" "$TMP/run-13.log"; then
  ok "別 OID で存在するリモート branch を lease 拒否として保護"
else
  bad "別 OID リモート branch の lease 保護が期待どおりでない (exit=$EXIT_13)"
fi

# 6.8 ref 再取得が失敗した場合は「削除済み」と推測しない。削除はしないが、
#     Step 6 の取り残し掃除と同じく「失敗として記録して続行」に揃える（PARTIAL）。
# 後続 Step が「見出しに到達した」だけでなく実際に仕事をしたことを見るため、
# この run で消えるはずの [gone] ローカルブランチを仕込む（develop 相当なので
# 完全マージ済み = Step 5 の通常削除の対象）。
git branch 'feature/#19-gone-after-fail' develop
SKIP_SIMPLE_GIT_HOOKS=1 git push -qu origin 'feature/#19-gone-after-fail'
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin --delete 'feature/#19-gone-after-fail'
# Step 6 が削除に成功する取り残しも同時に置く（対象 PR 以外の成功の影響を見る）
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_LEFTOVER23:refs/heads/feature/#23-leftover-for-14"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 14 > "$TMP/run-14.log" 2>&1
EXIT_14=$?
set -e
if [ "$EXIT_14" -eq 2 ] \
  && grep -q "remote re-check failed" "$TMP/run-14.log" \
  && grep -q "simulated remote re-check failure" "$TMP/run-14.log" \
  && grep -q "feature/#14-recheck-fails: リモート削除失敗" "$TMP/run-14.log" \
  && grep -q "結果: PARTIAL" "$TMP/run-14.log"; then
  ok "lease 拒否後の ref 再取得失敗を失敗として記録し PARTIAL で報告"
else
  bad "ref 再取得失敗の報告が期待どおりでない (exit=$EXIT_14)"
fi

# 6.8d 再試行されない対象 PR は failed のまま残る。かつ同じ run で別ブランチの削除が
#      成功しても、対象 PR のサマリー行は書き換わらない（更新条件の 2 つのガード）。
if grep -q "リモートブランチ (feature/#14-recheck-fails): failed" "$TMP/run-14.log" \
  && grep -q "✓ removed: feature/#23-leftover-for-14" "$TMP/run-14.log"; then
  ok "他ブランチの削除成功が対象 PR の failed を書き換えない"
else
  bad "対象 PR のサマリー値が他ブランチの結果に引きずられている"
fi

# 6.8b 上記の失敗で cleanup 全体を落とさない（後続 Step が実行される）。
if grep -q "=== リモート取り残し検証 ===" "$TMP/run-14.log" \
  && grep -q "=== 最終状態 ===" "$TMP/run-14.log"; then
  ok "Step 4 の削除失敗後も Step 6 / Step 7 が実行される"
else
  bad "Step 4 の削除失敗で後続 Step が実行されていない"
fi

# 6.8c 見出しへの到達だけでなく、Step 5 が実際に [gone] ブランチを消したことを見る。
if ! git show-ref --verify --quiet 'refs/heads/feature/#19-gone-after-fail'; then
  ok "Step 4 の削除失敗後も Step 5 が [gone] ローカルブランチを実際に削除する"
else
  bad "Step 4 の削除失敗で [gone] ローカルブランチの削除が行われていない"
fi

# 6.9 ref が期待 OID のまま存在する場合は、競合 push と断定せず原因不明として
#     記録する。削除しない点は従来どおりで、報告だけ PARTIAL 続行へ揃える。
# 続行にしたことで、削除に失敗した対象自身のローカル資産まで掃除してしまわないこと
# を見る。この run はリモート ref が期待 OID のまま残るので [gone] にならない。
git branch 'feature/#15-same-oid' "$OID_SAME" 2>/dev/null || true
git branch --set-upstream-to=origin/'feature/#15-same-oid' 'feature/#15-same-oid' >/dev/null 2>&1
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 15 > "$TMP/run-15.log" 2>&1
EXIT_15=$?
set -e
if [ "$EXIT_15" -eq 2 ] \
  && remote_has 'feature/#15-same-oid' \
  && grep -q "remote re-check returned the expected OID" "$TMP/run-15.log" \
  && grep -q "feature/#15-same-oid: リモート削除失敗" "$TMP/run-15.log" \
  && ! grep -q "マージ後に更新されています" "$TMP/run-15.log"; then
  ok "期待 OID のまま残る ref を原因不明として記録し、削除せず PARTIAL で報告"
else
  bad "期待 OID のまま残る ref の判定が期待どおりでない (exit=$EXIT_15)"
fi

# 6.9b リモート ref が残っている対象のローカルブランチを、続行のついでに消さない。
if git show-ref --verify --quiet 'refs/heads/feature/#15-same-oid'; then
  ok "削除に失敗し ref が残る対象のローカルブランチを掃除しない"
else
  bad "ref が残っているのに対象のローカルブランチが削除された"
fi

# 6.10 stdout が空なら、成功時の stderr 警告を ref 存在と誤読しない。
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 16 > "$TMP/run-16.log" 2>&1
EXIT_16=$?
set -e
if [ "$EXIT_16" -eq 2 ] \
  && grep -q "リモートブランチは既に削除されていました" "$TMP/run-16.log" \
  && ! grep -q "マージ後に更新されています" "$TMP/run-16.log"; then
  ok "成功時 stderr 警告を ref 存在と誤読せず already removed と判定"
else
  bad "成功時 stderr 警告の分離が期待どおりでない (exit=$EXIT_16)"
fi

# 6.11 Step 4 が削除に失敗しても、Step 6 の取り残し掃除が同じ branch を再試行する。
#      成功した場合にサマリーが「失敗」のまま残ると実態と食い違うため、結果を更新する。
#      ここで初めて origin へ push する（先行 run が取り残しとして拾わないように）。
# この時点では fixture の pre-push hook が入っているため、削除 push と同じ env を付ける
# 遅延 push が load-bearing（先行 run の取り残し掃除に拾われないため）。
# 既に origin へ出ていたら前提が崩れているので fail-loud にする。
remote_has 'feature/#17-retry-succeeds' && bad "fixture 前提が崩れています（6.11 より前に feature/#17-retry-succeeds が origin へ出ている）"
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_RETRY17:refs/heads/feature/#17-retry-succeeds"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 17 > "$TMP/run-17.log" 2>&1
EXIT_17=$?
set -e
if [ "$EXIT_17" -eq 2 ] \
  && ! remote_has 'feature/#17-retry-succeeds' \
  && grep -q "deleted_by_leftover_retry" "$TMP/run-17.log" \
  && grep -q "✓ removed: feature/#17-retry-succeeds" "$TMP/run-17.log" \
  && grep -q "feature/#17-retry-succeeds: リモート削除失敗" "$TMP/run-17.log" \
  && ! grep -q "リモートブランチ (feature/#17-retry-succeeds): failed" "$TMP/run-17.log"; then
  ok "Step 6 の再試行で削除できた場合、対象 PR の結果を失敗のまま残さない"
else
  bad "Step 6 再試行後のサマリーが期待どおりでない (exit=$EXIT_17)"
fi

# 6.12 Step 4 の削除が失敗している間にリモートが別 OID へ進んだ場合、Step 6 の
#      再試行は (名前, OID) 照合で弾かれる。更新済みブランチを消してはならない。
# 遅延 push が load-bearing（先行 run の取り残し掃除に拾われないため）。
# 既に origin へ出ていたら前提が崩れているので fail-loud にする。
remote_has 'feature/#18-changed-before-retry' && bad "fixture 前提が崩れています（6.12 より前に feature/#18-changed-before-retry が origin へ出ている）"
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_CHANGED18:refs/heads/feature/#18-changed-before-retry"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 18 > "$TMP/run-18.log" 2>&1
EXIT_18=$?
set -e
CHANGED18_NOW="$(git ls-remote --heads origin 'refs/heads/feature/#18-changed-before-retry' | awk '{print $1}')"
if [ "$EXIT_18" -eq 2 ] \
  && [ "$CHANGED18_NOW" = "$OID_CHANGED18B" ] \
  && grep -q "feature/#18-changed-before-retry: リモート削除失敗" "$TMP/run-18.log" \
  && ! grep -qE '^  - feature/#18-changed-before-retry$' "$TMP/run-18.log" \
  && ! grep -q "deleted_by_leftover_retry" "$TMP/run-18.log"; then
  ok "Step 4 失敗中に別 OID へ進んだブランチを Step 6 の再試行が削除しない"
else
  bad "別 OID へ進んだブランチの再試行保護が期待どおりでない (exit=$EXIT_18)"
fi

# 6.13 Step 6 の再試行時点で ref が消えていた場合も、サマリーを失敗のまま残さない。
#      削除したのは自分ではないので deleted ではなく already removed として扱う。
# 遅延 push が load-bearing（先行 run の取り残し掃除に拾われないため）。
# 既に origin へ出ていたら前提が崩れているので fail-loud にする。
remote_has 'feature/#20-vanished-before-retry' && bad "fixture 前提が崩れています（6.13 より前に feature/#20-vanished-before-retry が origin へ出ている）"
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_VANISHED20:refs/heads/feature/#20-vanished-before-retry"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 20 > "$TMP/run-20.log" 2>&1
EXIT_20=$?
set -e
if [ "$EXIT_20" -eq 2 ] \
  && ! remote_has 'feature/#20-vanished-before-retry' \
  && grep -q "already_missing_at_leftover_retry" "$TMP/run-20.log" \
  && grep -q "feature/#20-vanished-before-retry: リモート削除失敗" "$TMP/run-20.log" \
  && ! grep -q "リモートブランチ (feature/#20-vanished-before-retry): failed" "$TMP/run-20.log"; then
  ok "Step 6 の再試行時点で ref が消えていた場合もサマリーを失敗のまま残さない"
else
  bad "ref 消失時の再試行後サマリーが期待どおりでない (exit=$EXIT_20)"
fi

# 6.14 恒久的な失敗（ブランチ保護・権限など）では、対象 PR の head は必ず Step 6 の
#      (名前, OID) 照合に一致して再試行される。同一文言の失敗項目を 2 行並べない。
remote_has 'feature/#22-retry-fails' && bad "fixture 前提が崩れています（6.14 より前に feature/#22-retry-fails が origin へ出ている）"
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_RETRYFAIL22:refs/heads/feature/#22-retry-fails"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 22 > "$TMP/run-22.log" 2>&1
EXIT_22=$?
set -e
# 失敗項目は Step 4 と Step 6 で 2 行出るのが正しい（実際に 2 回失敗している）。
# 禁じたいのは「バイト単位で同一の行が並ぶ」こと。行数と重複数の両方を見る。
FAIL_LINES_22="$(grep -cE '^  - feature/#22-retry-fails: リモート削除失敗' "$TMP/run-22.log" || true)"
DUP_LINES_22="$(grep -E '^  - feature/#22-retry-fails: リモート削除失敗' "$TMP/run-22.log" \
  | sort | uniq -d | grep -c . || true)"
if [ "$EXIT_22" -eq 2 ] \
  && remote_has 'feature/#22-retry-fails' \
  && [ "$FAIL_LINES_22" -eq 2 ] \
  && [ "$DUP_LINES_22" -eq 0 ] \
  && grep -q "feature/#22-retry-fails: リモート削除失敗（Step 6 の再試行も失敗" "$TMP/run-22.log" \
  && grep -q "詳細不明" "$TMP/run-22.log"; then
  ok "再試行も失敗した場合に失敗項目を重複させず、原因が空でも詳細不明で埋める"
else
  bad "再試行も失敗した場合の失敗項目が期待どおりでない (exit=$EXIT_22, 行数=$FAIL_LINES_22, 重複=$DUP_LINES_22)"
fi

# 6.15 削除反映の fetch --prune が失敗しても中断しない。ここで die すると、
#      リモート削除の失敗で掃除全体を止めないという契約が 2 行先で破れる。
remote_has 'feature/#21-prune-fails' && bad "fixture 前提が崩れています（6.15 より前に feature/#21-prune-fails が origin へ出ている）"
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_PRUNEFAIL21:refs/heads/feature/#21-prune-fails"
# 見出し到達だけでなく実効を見る。Step 3 の prune の時点で既に [gone] になる
# ローカルブランチを置き、削除反映 prune が飛んでも Step 5 が消すことを確かめる。
git branch 'feature/#24-gone-before-prune' develop
SKIP_SIMPLE_GIT_HOOKS=1 git push -qu origin 'feature/#24-gone-before-prune'
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin --delete 'feature/#24-gone-before-prune'
: > "$TMP/prune21.enabled"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 21 > "$TMP/run-21.log" 2>&1
EXIT_21=$?
set -e
rm -f "$TMP/prune21.enabled" "$TMP/prune21.first"
if [ "$EXIT_21" -eq 2 ] \
  && grep -q "=== 最終状態 ===" "$TMP/run-21.log" \
  && grep -q "削除反映の fetch --prune" "$TMP/run-21.log" \
  && grep -qE '^  - .*fetch --prune' "$TMP/run-21.log"; then
  ok "削除反映の fetch --prune 失敗で中断せず、失敗として記録して続行する"
else
  bad "fetch --prune 失敗時の扱いが期待どおりでない (exit=$EXIT_21)"
fi

# 6.15b prune 失敗後も Step 5 が実際に [gone] ブランチを消す（見出し到達だけでなく）。
if ! git show-ref --verify --quiet 'refs/heads/feature/#24-gone-before-prune'; then
  ok "削除反映 prune が失敗しても Step 5 が [gone] ブランチを実際に削除する"
else
  bad "削除反映 prune 失敗後に Step 5 の削除が行われていない"
fi

# 6.16 headRefOid が null で返る PR。lease のアンカーが無いので削除は行わず、
#      「headRefOid を取得できない」ことを名指しする（push のエラーを「権限 /
#      ネットワーク / ブランチ保護ルール」へ誤帰属させない）。Step 6 の取り残し
#      掃除も、一覧側の OID が null なら (名前, OID) 照合に一致せず削除しない。
# 遅延 push が load-bearing（先行 run の取り残し掃除に拾われないため）。
remote_has 'feature/#41-null-oid' && bad "fixture 前提が崩れています（6.16 より前に feature/#41-null-oid が origin へ出ている）"
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_NULLOID41:refs/heads/feature/#41-null-oid"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 41 > "$TMP/run-41.log" 2>&1
EXIT_41=$?
set -e
NULLOID41_NOW="$(git ls-remote --heads origin 'refs/heads/feature/#41-null-oid' | awk '{print $1}')"
if [ "$EXIT_41" -eq 2 ] \
  && [ "$NULLOID41_NOW" = "$OID_NULLOID41" ] \
  && grep -q "headRefOid を取得できませんでした" "$TMP/run-41.log" \
  && grep -q "リモートブランチ (feature/#41-null-oid): skipped_oid_unavailable" "$TMP/run-41.log" \
  && grep -qE '^  - feature/#41-null-oid: headRefOid を取得できず' "$TMP/run-41.log" \
  && ! grep -q "権限 / ネットワーク / ブランチ保護ルールを確認" "$TMP/run-41.log" \
  && grep -q "=== 最終状態 ===" "$TMP/run-41.log"; then
  ok "headRefOid が null なら削除せず、原因を名指しして PARTIAL で続行する"
else
  bad "headRefOid が null のときの扱いが期待どおりでない (exit=$EXIT_41)"
fi

# 6.17 混在ケース: gh pr view は headRefOid=null だが、取り残し一覧側の OID は正常。
#      Step 6 は照合済み OID をアンカーに実際に削除できるので、サマリーを
#      deleted_by_leftover_retry へ更新し、「リモート削除未実施」の虚偽行を出さない。
#      Step 4 は削除を試みてすらいないため、この経路は失敗として数えない（補足行）。
# 遅延 push が load-bearing（先行 run の取り残し掃除に拾われないため）。
remote_has 'feature/#42-null-oid-mixed' && bad "fixture 前提が崩れています（6.17 より前に feature/#42-null-oid-mixed が origin へ出ている）"
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_NULLOID42:refs/heads/feature/#42-null-oid-mixed"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 42 > "$TMP/run-42.log" 2>&1
EXIT_42=$?
set -e
# この run には別件（feature/#22-retry-fails の恒久的な削除失敗）が必ず混ざるため
# 終了コードは 2 になる。見たいのは「#42 が失敗として数えられていないこと」なので、
# 全体の PARTIAL ではなく #42 の行だけを見る。
if ! remote_has 'feature/#42-null-oid-mixed' \
  && grep -q "✓ removed: feature/#42-null-oid-mixed" "$TMP/run-42.log" \
  && grep -q "リモートブランチ (feature/#42-null-oid-mixed): deleted_by_leftover_retry" "$TMP/run-42.log" \
  && grep -q "補足（手当て不要）" "$TMP/run-42.log" \
  && grep -qE '^  - feature/#42-null-oid-mixed: headRefOid は gh pr view から取得できなかったが、取り残し検証の \(名前, OID\) 照合で削除済み' "$TMP/run-42.log" \
  && ! grep -q "feature/#42-null-oid-mixed: headRefOid を取得できずリモート削除未実施" "$TMP/run-42.log" \
  && ! grep -qE '^  - feature/#42-null-oid-mixed: リモート削除' "$TMP/run-42.log"; then
  ok "headRefOid が view だけ null の混在ケースは Step 6 が削除し、失敗行を残さない"
else
  bad "混在ケース（view=null / list=正常 OID）の扱いが期待どおりでない (exit=$EXIT_42)"
fi

# 6.18 混在ケースで Step 6 の削除が lease 拒否になった場合。削除しないのは
#      「マージ後 push があったので保護した」という正常系（Step 4 の
#      skipped_lease_rejected と同格）なので、失敗として数えない。
# 遅延 push が load-bearing（先行 run の取り残し掃除に拾われないため）。
remote_has 'feature/#43-null-oid-lease' && bad "fixture 前提が崩れています（6.18 より前に feature/#43-null-oid-lease が origin へ出ている）"
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_NULLOID43:refs/heads/feature/#43-null-oid-lease"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 43 > "$TMP/run-43.log" 2>&1
EXIT_43=$?
set -e
NULLOID43_NOW="$(git ls-remote --heads origin 'refs/heads/feature/#43-null-oid-lease' | awk '{print $1}')"
if [ "$NULLOID43_NOW" = "$OID_NULLOID43B" ] \
  && grep -q "skip (照合後に push あり・lease 拒否): feature/#43-null-oid-lease" "$TMP/run-43.log" \
  && grep -q "リモートブランチ (feature/#43-null-oid-lease): skipped_lease_rejected_at_leftover_retry" "$TMP/run-43.log" \
  && grep -qE '^  - feature/#43-null-oid-lease: 照合後に push あり' "$TMP/run-43.log" \
  && ! grep -q "feature/#43-null-oid-lease: headRefOid を取得できずリモート削除未実施" "$TMP/run-43.log" \
  && ! grep -qE '^  - feature/#43-null-oid-lease: リモート削除' "$TMP/run-43.log"; then
  ok "混在ケースの lease 拒否は保護として扱い、削除未実施の失敗行を残さない"
else
  bad "混在ケースの lease 拒否の扱いが期待どおりでない (exit=$EXIT_43)"
fi

# 6.19 混在ケースで Step 6 の削除が一般エラーで失敗した場合。Step 4 は削除を試みて
#      いないので「未実施」と「削除失敗」を 2 行並べず、1 行に束ねる。
# 遅延 push が load-bearing（先行 run の取り残し掃除に拾われないため）。
remote_has 'feature/#44-null-oid-failure' && bad "fixture 前提が崩れています（6.19 より前に feature/#44-null-oid-failure が origin へ出ている）"
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_NULLOID44:refs/heads/feature/#44-null-oid-failure"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 44 > "$TMP/run-44.log" 2>&1
EXIT_44=$?
set -e
FAIL_LINES_44="$(grep -cE '^  - feature/#44-null-oid-failure:' "$TMP/run-44.log" || true)"
if [ "$EXIT_44" -eq 2 ] \
  && remote_has 'feature/#44-null-oid-failure' \
  && [ "$FAIL_LINES_44" -eq 1 ] \
  && grep -q "feature/#44-null-oid-failure: リモート削除失敗（headRefOid が無く Step 4 はスキップ" "$TMP/run-44.log" \
  && grep -q -- "--force-with-lease=refs/heads/feature/#44-null-oid-failure:$OID_NULLOID44" "$TMP/run-44.log" \
  && ! grep -q "feature/#44-null-oid-failure: headRefOid を取得できずリモート削除未実施" "$TMP/run-44.log"; then
  ok "混在ケースの一般エラーは 1 行に束ね、二重計上せず ref を残す"
else
  bad "混在ケースの一般エラーの扱いが期待どおりでない (exit=$EXIT_44, 行数=$FAIL_LINES_44)"
fi

# 6.20 混在ケースで、Step 6 の削除 push の時点には ref が消えていた場合。
#      消したのは自分ではないので already 扱いにし、失敗としては数えない。
remote_has 'feature/#45-null-oid-vanished' && bad "fixture 前提が崩れています（6.20 より前に feature/#45-null-oid-vanished が origin へ出ている）"
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_NULLOID45:refs/heads/feature/#45-null-oid-vanished"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 45 > "$TMP/run-45.log" 2>&1
EXIT_45=$?
set -e
if ! remote_has 'feature/#45-null-oid-vanished' \
  && grep -q "already removed: feature/#45-null-oid-vanished" "$TMP/run-45.log" \
  && grep -q "リモートブランチ (feature/#45-null-oid-vanished): already_missing_at_leftover_retry" "$TMP/run-45.log" \
  && grep -qE '^  - feature/#45-null-oid-vanished: headRefOid は gh pr view から取得できなかったが、取り残し検証の時点で既に削除済み' "$TMP/run-45.log" \
  && ! grep -qE '^  - feature/#45-null-oid-vanished: (headRefOid を取得できず|リモート削除失敗)' "$TMP/run-45.log"; then
  ok "混在ケースで再試行時点に ref が消えていたら already 扱いにし、失敗に数えない"
else
  bad "混在ケースの ref 消失時の扱いが期待どおりでない (exit=$EXIT_45)"
fi

# 6.21 headRefOid が null で、origin にも ref が無い場合。削除すべきものが無いので
#      失敗として積まない（積むと何度実行しても解消しない PARTIAL になる）。
remote_has 'feature/#46-null-oid-gone' && bad "fixture 前提が崩れています（6.21 の対象が origin へ出ている）"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 46 > "$TMP/run-46.log" 2>&1
EXIT_46=$?
set -e
if grep -q "リモートブランチ (feature/#46-null-oid-gone): already_missing" "$TMP/run-46.log" \
  && grep -q "origin に feature/#46-null-oid-gone は既にありません" "$TMP/run-46.log" \
  && grep -qE '^  - feature/#46-null-oid-gone: headRefOid は gh pr view から取得できなかったが、origin 上の ref は既に存在しない' "$TMP/run-46.log" \
  && ! grep -q "feature/#46-null-oid-gone: headRefOid を取得できずリモート削除未実施" "$TMP/run-46.log" \
  && ! grep -qE '^  - feature/#46-null-oid-gone:.*リモート削除未実施' "$TMP/run-46.log"; then
  ok "headRefOid が null でも ref が既に無ければ already_missing とし、失敗に数えない"
else
  bad "ref 不在時の headRefOid 欠落の扱いが期待どおりでない (exit=$EXIT_46)"
fi

# 7. サマリーに失敗項目が列挙されている（状態がサマリーまで届く）
if grep -q "worktree に未コミット変更あり" "$TMP/run.log"; then
  ok "失敗項目がサマリーに列挙される"
else
  bad "失敗項目がサマリーに出ていない"
fi

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
  && grep -q "トランスクリプト回収: jsonl 走査エラーで保護 ($NAME_SCANERR)" "$TMP/run.log"; then
  ok "jsonl を読み切れない場合は、一致する cwd が見えていても保護して PARTIAL"
else
  bad "jsonl 走査エラー時の保護が期待どおりでない ($NAME_SCANERR)"
fi
chmod 755 "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_SCANERR/locked" 2>/dev/null || true

# 12.8 ファイル単位で読めない場合も同様に保護する（find は成功し grep が失敗する経路）
if [ -d "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_UNREADABLE" ] \
  && [ -z "$(archive_of "$NAME_UNREADABLE")" ] \
  && grep -q "トランスクリプト回収: jsonl 走査エラーで保護 ($NAME_UNREADABLE)" "$TMP/run.log"; then
  ok "読めない jsonl が混ざっている場合も、見えた分だけで判定せず保護"
else
  bad "読めない jsonl の保護が期待どおりでない ($NAME_UNREADABLE)"
fi
chmod 644 "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_UNREADABLE/unreadable.jsonl" 2>/dev/null || true

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


# ---- 32. 未コミット変更ガードのパス除外（FF_MERGE_CLEANUP_IGNORE_PATHS）--------
#
# 常駐ツールが同じパスを書き続けるリポジトリでは作業ツリーが dirty なのが定常状態で、
# Step 1 のガードが「異常の検出」ではなく「必ず発火する障害」になる（公開 Issue #14）。
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

# 32.12 実運用の中心経路: 作業ブランチ上に除外対象の変更を残したまま cleanup を実行し、
#       base への switch が変更を持ち越して完走する（切り替えが除外対象の変更を
#       消したり、予期せず止めたりしないこと）
git -C "$CALLER" switch -q -c work-branch-41 develop
make_ignorable_dirt "$CALLER"
set +e
FF_MERGE_CLEANUP_IGNORE_PATHS="$IGNORE_BOTH" \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-ignore-frombranch.log" 2>&1
EXIT_IGNORE_FROMBRANCH=$?
set -e
if exit_is_complete "$EXIT_IGNORE_FROMBRANCH" \
  && grep -q "マージ後 Cleanup 結果" "$TMP/run-ignore-frombranch.log" \
  && [ "$(git -C "$CALLER" branch --show-current)" = "develop" ] \
  && grep -q "resident tool wrote this" "$CALLER/videos/tracked/spec.md" \
  && [ -f "$CALLER/videos/slug-new/spec.md" ]; then
  ok "作業ブランチからの実行でも base へ切り替えて完走し、除外対象の変更を保持する"
else
  bad "作業ブランチからの実行が期待どおりでない (exit=$EXIT_IGNORE_FROMBRANCH)"
fi
clear_ignorable_dirt "$CALLER"
git -C "$CALLER" branch -q -D work-branch-41

# 32.11 「除外したパスが本当に cleanup を妨げるなら git 自身が失敗して中断する」という、
#       Step 1 を緩めてよい根拠そのものを実測する。除外パス内の追跡ファイルが
#       base 側でも進んでいれば pull --ff-only が拒否し、cleanup は中断する
git clone -q "$TMP/origin.git" "$TMP/pusher"
git -C "$TMP/pusher" config user.email "test@example.com"
git -C "$TMP/pusher" config user.name "merge-cleanup-test"
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

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ merge-cleanup verify: $FAIL 件失敗（詳細: 実行ログ抜粋）" >&2
  tail -40 "$TMP/run.log" >&2
  exit 1
fi

# 検査総数の固定。ケースが黙って消える / 条件分岐で実行されなくなる形は、
# 個々のアサートでは検出できない（誰も落ちないまま緑になる）。件数を変えたときは
# 意図的な変更としてこの値を更新すること。全ケースは無条件に実行されるため、
# 環境によって増減しない（書き込み不可環境は冒頭で skip して exit 0 になる）。
#
# 直近の変更で 91 → 97。内訳は +6（項目 3b = 6.22: 取り残し候補一覧の読み出しを固定
# する green pin 1 件 + 事前照合の検出力 2 件 / 項目 3c = 6.23: ペア照合が集合独立照合
# へ退化していないことの 3 件）。その前は 92 → 91 と**減って**おり、内訳は
# +1（静的検査の対象へ verify.sh 自身を追加）/ -2（自前の検出器 self-test probe 2 件を
# 廃止し、共有実装 tests/lib/mbcs-guard.sh の専用 suite tests/mbcs-guard-failclosed/ へ
# 寄せた）。「黙って消えた」ではないことを残すために内訳を書く — 減少はここに理由が
# 無ければ疑うべき兆候である。
EXPECTED_PASS=97
if [ "$PASS" -ne "$EXPECTED_PASS" ]; then
  echo "✗ merge-cleanup verify: 検査総数が想定と違います（期待 ${EXPECTED_PASS} / 実際 ${PASS}）" >&2
  echo "  ケースを増減したなら EXPECTED_PASS を更新すること。減っている場合は、" >&2
  echo "  ケースが黙って実行されなくなっていないかを先に確認すること。" >&2
  exit 1
fi
echo "✓ merge-cleanup verify: 全 $PASS 件 pass（検査総数の固定値と一致）"
FF_REACHED_END=1
