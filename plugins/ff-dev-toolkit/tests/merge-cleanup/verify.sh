#!/usr/bin/env bash
# 空振り検出: cases の読み込み（tests/lib/suite-cases.sh。Issue `#2697`）は、一覧の source 行を消す・最終行を切る・ファイルを消す・完了印だけの空ファイルにする各変異が、隔離コピーで rc=1 と狙いの診断になる（2026-11-08 macOS / Bash 3.2 実測）。
#
# merge-cleanup.sh の破壊的経路の回帰テスト。
# 空振り検出: detached linked caller の判定を除いた mutant は独立 fixture の dry-run 検査で赤になる。
# 空振り検出: agent branch専用fixtureが削除処理の欠落・祖先判定欠落・worktree判定欠落・remote判定欠落を赤にする。
# 空振り検出: msys の core.longpaths=true を外した mutant は long-paths.sh の呼び出し記録の照合で赤になる。Windows の実機では、深い node_modules の削除が git の「Filename too long」で失敗して赤になる（2026-10-30 実測、Issue `#2479`）。
# 空振り検出: msys で ignored のリンクを外す工程を除いた mutant は、long-paths.sh の「worktree remove の時点のリンク数」が 1 になって赤になる（リンクを数えられない回は印の行で 0 にならない）。Windows の実機では windows-junctions.sh の outside の回が参照先の keep.txt の消失で、pnpm の回が単独でも「Directory not empty」で赤になる。残ったリンクの確認を除いた mutant は long-paths.sh の hidden-untracked の回が赤にする。ジャンクションを作れない回と、登録の照合が実行前に当たらない回も赤（2026-10-31 実測、Issue `#2557`）。
# 空振り検出: 入口の「ファイルが無い」分岐を外した写しを与えると、「構成ファイルを読めない入口が削除前に止まっていない（mode=missing）」の 1 件だけが赤になる（2026-10-21 実測。成功は残り全部。判定は exit 1 のまま、針「がありません」が外れ、次の分岐の「が 0 バイトです」になる。削除へは進まない）。
# worktree一覧の不在・空・警告とremote照合失敗はfixtureでskip理由と残存を実測する。
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
#  11b. (6.6b / 公開 ff-dev-toolkit#137) その場合、通常実行でも削除前の照合
#       （ls-remote --exit-code）で止まり、削除 push 自体を実行しない（mock git の
#       push 呼び出し記録で見る。消えた ref への削除 push も pre-push を起動するため）
#  11c. (6.6c) 削除前の照合そのものが失敗したら、push せず「消えた」とも推測せず
#       失敗として記録する（fail-closed）
#  12. 対象 PR のリモートブランチが別 OID で存在する場合は、lease 拒否として保護する
#  13. lease 拒否後の ref 再取得に失敗した場合は、失敗として記録し後続 Step を続行する
#      （照合は match で通し、push の lease 拒否から再取得へ落とす。ref は消さない）
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
#  27c. 未変更ファイルの未来 mtime をアーカイブ中の変更と誤認しない
#  28. アーカイブ先を作れないときは中断し、「対象なし」と矛盾する報告をしない
#  29. CLAUDE_CONFIG_DIR 由来の既定パスでも回収できる（実ユーザーが通る経路）
#  30. 削除しなかった dirty worktree のトランスクリプトには触れない
#  31. 削除 push は SKIP_SIMPLE_GIT_HOOKS=1 を付け、env が無いと拒否する
#      pre-push fixture の下でもリモート削除が完了する
#  31b. (公開 ff-dev-toolkit#137) 削除 push は HUSKY=0 も付け、fixture hook の husky
#       runner 判定（`[ "${HUSKY-}" = "0" ]`）が skip 側になる。静的検査も両 env を要求する
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
#  33. (40.x / Issue 703) MERGED 一覧側の OID が null の [gone] ブランチは
#      「未マージの固有コミットの可能性」と誤帰属せず、照合材料が無いことを名指しして
#      スキップする。null 照合を無効化した mutant を実際に走らせ、旧文言へ退行する
#      （= 本 fixture が mutant を赤にできる）ことまで実測する
#  34. (41.x / Issue 835) マージ済み PR 照合上限は FF_MERGE_CLEANUP_MERGED_PR_LIMIT で
#      設定でき、打ち切りの明示と取得の進捗が出る。既定 1000 は後方互換。不正値は
#      破壊的処理前に中断する
#  35. (42.x / Issue 1056) 保護ブランチのうち release/* は
#      FF_MERGE_CLEANUP_PROTECT_BRANCHES で設定可能（既定は従来どおり保護 = 後方互換）。
#      設定保護による skip は削除コマンド付きで報告し、develop/main/master/staging/* は
#      'none' を指定しても削除されない
#  36. (43.x / Issue 914) マージ済みエージェント worktree（(名前, OID) が MERGED head と
#      一致 + claude agent ロック + untracked は .review-results のみ）は unlock + 削除
#      して PARTIAL にしない。条件が 1 つでも欠ければ従来どおり保護する
#  37. (44.x / Issue 758 / 749) 呼び出し元が base でも PR head でもないブランチにいる
#      場合は switch せずに掃除を完遂し、base 保持 worktree は報告のみ（detach しない）。
#      dirty でも中断せず、未実施項目（base 復帰・pull）をサマリーで名指しする
#  38. (45.x) 対象 PR のブランチを保持する linked worktree を cwd にして起動した場合は、
#      破壊的処理の前に中断する。main tree のパスが取れれば再実行コマンドを引用付きで
#      示し（空白を含むパスでも貼って実行できる）、bare リポジトリのようにパスが
#      取れない構成でも素通しせず原因と対処を示す。main tree からの起動は完走する
#  39. (46.x) 破壊的処理を伴わない確認手段（--dry-run / --help）。--dry-run は削除対象を
#      一覧するだけでブランチ・worktree・リモート参照を 1 つも変えず、保護ブランチ・
#      dirty worktree・fail-closed な縮退の判定は通常実行と 1 行も違わない。予告は
#      実行時の削除を 1 つも取りこぼさない — 見送った prune / リモート削除の連鎖
#      （削除 → prune → 新たに [gone] → その worktree）まで予測し、通常実行が削除した
#      ものが全て予告に載っていたことを包含関係で実測する。逆に origin 上の ref を
#      read-only で照合し、OID 不一致（マージ後に再利用）・既に無い head は予告しない。
#      -d 相当の判定基準は「実行時に switch / pull した後の base」で、現在の HEAD では
#      ない。--help は PR 番号として解釈されず（gh を一度も呼ばない）、mktemp と
#      gh / jq の存在確認より前に効く。引数なしは使い方を表示して非 0 で終わる。
#      通常実行の削除と終了コード契約は従来どおり。連鎖予告なし / OID 照合なし /
#      -d の基準を現在 HEAD へ / 依存確認を --help より前へ、の 4 mutant で検出力を実測する
#      (46.9 / 公開 ff-dev-toolkit#137) 通常実行の削除前の照合も dry-run と同じ判定関数を
#      通る — 判定を常時 match にした mutant を通常実行で走らせると、消えた ref へ削除
#      push する（原本はしない）ことで実測する
#  40. (47.x) 復旧コマンドのブランチ名・refspec は 1 語ずつ引用する。' ` $ ; を含む ref 名で、
#      OID 欠損の案内と失敗行 / OID null と OID 不一致の [gone] / 設定保護パターンの取り残し /
#      headRefOid 無しの削除失敗行の 6 か所の案内を git を argv 記録だけにするスタブの下で実行し、
#      名前が 1 語のリテラルで渡り sentinel が作られないことを見る。旧形（名前を裸または単引用の
#      中へ埋め込む）では 6 か所すべてが赤になる（2026-10-28 WSL で実測: 設定保護パターンの裸の行は
#      argv が名前の途中で切れて食い違い、他の 5 か所は案内の行の形ごと見つからない）
#
# あわせて静的検査として、bash 3.2 で変数名にマルチバイト文字が取り込まれる書き方
# （"$VAR" の直後に全角文字を直付けする形）が merge-cleanup.sh と本 suite 自身に無いことを
# 確認する。検出器は共有実装（tests/lib/mbcs-guard.sh）を使い、走査できなかった場合は
# 「違反なし」ではなく失敗として報告する。
#
# 書き込み不可の環境（read-only チェックアウト等）では skip して成功扱いにする。
#
# run-all-required: no — 一時領域が無い環境の skip を許容する（一時領域依存 suite の必須判断で名簿へ載せなかった側。必須へ昇格するなら REQUIRED_SUITES へ移す）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/scripts/merge-cleanup.sh"
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

[ -f "$TARGET" ] || { echo "✗ merge-cleanup.sh が見つかりません: $TARGET" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "✗ jq が必要です" >&2; exit 1; }

# mktemp の stderr を捨てない。捨てると read-only 以外の失敗（TMPDIR が不正な
# パス・quota 超過など）まで「書き込み可能な環境で再実行してください」に誤帰属し、
# 恒常的に壊れた TMPDIR が suite を exit 0 で無効化し続ける。2>&1 で受けると
# 成功時はパス・失敗時は理由が同じ変数に入る。
# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境のためスキップ"
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
# （tests/mbcs-guard-failclosed/）が持つため、ここに自前の probe は置かない。
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

# 検査対象は入口 merge-cleanup.sh、構成ファイル（MC_PARTS）、本 suite の verify.sh と cases/*.sh。suite 自身を外すと、verify.sh を
# 編集した本人が単体実行では自分の違反に気付けず、repo 横断ガード（tests/run-all/verify.sh
# の case 11）まで持ち越される。しかも違反が失敗報告の文言に入った場合は、静的検査を
# すり抜けたまま実行時に `unbound variable` で suite が途中死する。二重に見えるが役割は
# 別で、ここは「書いたその場での即時フィードバック」、case 11 は「再混入の横断防止」。
#
# 本ファイル内のコメント・診断文言そのものが検査対象になる点に注意する（`$VAR` の直後へ
# 全角文字を書かない）。全角文字が続く場合は `${PASS}` のように波括弧で括ること。
# 裸で書くと `PASS（` を参照して suite が途中死する。
mbcs_assert_clean "$TARGET" "merge-cleanup.sh"
mbcs_assert_clean "$SCRIPT_DIR/verify.sh" "本 suite (tests/merge-cleanup/verify.sh)"
_mc_cases=0
for _mc_case in "$SCRIPT_DIR"/cases/*.sh; do
  [ -f "$_mc_case" ] || continue
  _mc_cases=$((_mc_cases + 1))
  mbcs_assert_clean "$_mc_case" "本 suite の cases/${_mc_case##*/}"
done
[ "$_mc_cases" -gt 0 ] || bad "本 suite の cases ファイルが 1 本も見つからない（マルチバイト検査が空振りしている）"
MC_PARTS=(
  "$PLUGIN_ROOT/scripts/lib/shell-quote.sh"
  "$PLUGIN_ROOT/scripts/lib/merge-cleanup-pre.sh"
  "$PLUGIN_ROOT/scripts/lib/merge-cleanup-remote.sh"
  "$PLUGIN_ROOT/scripts/lib/merge-cleanup-local.sh"
)
for _mc_lib in "${MC_PARTS[@]}"; do
  mbcs_assert_clean "$_mc_lib" "構成ファイル ${_mc_lib##*/}"
done

echo "== 静的検査: 入口と構成ファイルは 1200 行以下 =="
for _mc_size in "$TARGET" "${MC_PARTS[@]}"; do
  _mc_n="$(wc -l < "$_mc_size")"
  _mc_n="${_mc_n// /}"
  if [ "$_mc_n" -le 1200 ]; then
    ok "${_mc_size##*/} は 1200 行以下（${_mc_n} 行）"
  else
    bad "${_mc_size##*/} が 1200 行を超えている（${_mc_n} 行）"
  fi
done

# 構成ファイルが読めない入口は、削除へ進む前に exit 1 で止まる（PARTIAL の 2 ではない）。
# 入口だけを別ディレクトリへ置く。lib を置かない / 空 / 末尾を壊す / symlink の 4 通り。
stage_cleanup_mutant() { # <dir>
  mkdir -p "$1/lib"
  cp "$TARGET" "$1/merge-cleanup.sh"
  cp "${MC_PARTS[@]}" "$1/lib/"
}
refuse_cleanup_unreadable() { # <mode> <needle>
  local mode="$1" needle="$2" dir entry rc before
  dir="$(mktemp -d)"
  mkdir -p "$dir/lib" "$dir/repo" "$dir/bin"
  printf '#!/bin/sh\nexit 0\n' > "$dir/bin/gh"
  printf '#!/bin/sh\nexit 0\n' > "$dir/bin/jq"
  chmod +x "$dir/bin/gh" "$dir/bin/jq"
  cp "$TARGET" "$dir/merge-cleanup.sh"
  entry="$dir/merge-cleanup.sh"
  git -C "$dir/repo" init -q
  ff_git_fixture_init "$dir/repo" "Refuse Test" "refuse@example.com" >/dev/null
  printf 'keep\n' > "$dir/repo/keep.txt"
  git -C "$dir/repo" add keep.txt
  git -C "$dir/repo" commit -qm keep
  git -C "$dir/repo" switch -qc keep-me
  before="$(git -C "$dir/repo" rev-parse HEAD)"
  # 先に読む共有 helper は揃え、壊すのは merge-cleanup-pre.sh だけにする（missing は lib を空のまま）
  [ "$mode" = missing ] || cp "$PLUGIN_ROOT/scripts/lib/shell-quote.sh" "$dir/lib/shell-quote.sh"
  case "$mode" in
    missing) ;;
    empty) : > "$dir/lib/merge-cleanup-pre.sh" ;;
    cut)
      cp "$PLUGIN_ROOT/scripts/lib/merge-cleanup-pre.sh" "$dir/lib/merge-cleanup-pre.sh"
      printf '\n# cut\n' >> "$dir/lib/merge-cleanup-pre.sh"
      ;;
    symlink)
      cp "$PLUGIN_ROOT/scripts/lib/merge-cleanup-pre.sh" "$dir/lib/merge-cleanup-pre.real"
      ln -s merge-cleanup-pre.real "$dir/lib/merge-cleanup-pre.sh"
      ;;
    *)
      bad "refuse mode ${mode} は未定義"
      rm -rf "$dir"
      return
      ;;
  esac
  set +e
  ( cd "$dir/repo" && PATH="$dir/bin:$PATH" bash "$entry" 1 >"$dir/out" 2>&1 )
  rc=$?
  set -e
  if [ "$rc" -eq 1 ] \
    && grep -F -q -- "$needle" "$dir/out" \
    && grep -F -q -- "まだ何も削除していません。" "$dir/out" \
    && [ "$(git -C "$dir/repo" rev-parse HEAD)" = "$before" ] \
    && git -C "$dir/repo" show-ref --verify --quiet refs/heads/keep-me; then
    ok "構成ファイルが読めないときは削除前に exit 1（mode=${mode}）"
  else
    bad "構成ファイルを読めない入口が削除前に止まっていない（mode=${mode} rc=${rc}）"
    sed -n '1,20p' "$dir/out" >&2 || true
  fi
  rm -rf "$dir"
}
echo "== 構成ファイルが読めないときは削除前に止まる =="
refuse_cleanup_unreadable missing "がありません"
refuse_cleanup_unreadable empty "が 0 バイトです"
refuse_cleanup_unreadable cut "読み込み完了の印ではありません"
refuse_cleanup_unreadable symlink "が symlink です"

# $1: 検査するファイル。delete_remote_branch_with_lease 内で、
# フラグ付きの git push が 1 行以上あり、フラグの無い git push は
# 関数本文に FF_DELETE_PUSH_SKIP_HOOKS があるときだけ許すなら 0。
# コメント内・XSKIP_ / XHUSKY・=10 / =00 は受理しない。env と git push は同じ行に置くこと。
# HUSKY=0 は husky v9 の runner（`.husky/_/h`）が本体を呼ばずに exit 0 する値
# （公開 ff-dev-toolkit#137。SKIP_SIMPLE_GIT_HOOKS だけでは husky の consumer に効かない）。
delete_push_sets_skip_hooks() {
  awk '
    /^delete_remote_branch_with_lease\(\)/ { in_fn = 1 }
    in_fn { block = block $0 "\n" }
    in_fn && /^}/ { in_fn = 0 }
    END {
      has_opt = (block ~ /FF_DELETE_PUSH_SKIP_HOOKS/)
      n = split(block, lines, "\n")
      for (i = 1; i <= n; i++) {
        line = lines[i]
        if (line !~ /git[[:space:]]+push/) continue
        seen = 1
        sub(/#.*/, "", line)
        flagged = (line ~ /(^|[^=[:alnum:]_])SKIP_SIMPLE_GIT_HOOKS=1[[:space:]]/) && (line ~ /(^|[^=[:alnum:]_])HUSKY=0[[:space:]]/)
        if (flagged) has_flagged = 1
        else if (!has_opt) missing = 1
      }
      if (seen && has_flagged && !missing) exit 0
      exit 1
    }
  ' "$1"
}

echo ""
echo "== 静的検査: 削除 push の SKIP_SIMPLE_GIT_HOOKS / HUSKY =="

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
write_skip_hooks_probe 'LC_ALL=C SKIP_SIMPLE_GIT_HOOKS=1 HUSKY=0 git push --force-with-lease="refs/heads/$branch:$expected" origin ":refs/heads/$branch"'
if delete_push_sets_skip_hooks "$SKIP_HOOKS_PROBE"; then
  ok "検出器が env 付きの git push を誤検出しない（self-test）"
else
  bad "検出器が env 付きの git push を誤検出する"
fi
write_skip_hooks_probe 'git push --no-verify origin ":refs/heads/$branch" # SKIP_SIMPLE_GIT_HOOKS=1 HUSKY=0'
if ! delete_push_sets_skip_hooks "$SKIP_HOOKS_PROBE"; then
  ok "検出器がコメント内の env を受理しない（self-test）"
else
  bad "検出器がコメント内の env を受理する"
fi
write_skip_hooks_probe 'XSKIP_SIMPLE_GIT_HOOKS=1 HUSKY=0 git push origin ":refs/heads/$branch"'
if ! delete_push_sets_skip_hooks "$SKIP_HOOKS_PROBE"; then
  ok "検出器が XSKIP_SIMPLE_GIT_HOOKS=1 を受理しない（self-test）"
else
  bad "検出器が XSKIP_SIMPLE_GIT_HOOKS=1 を受理する"
fi
write_skip_hooks_probe 'SKIP_SIMPLE_GIT_HOOKS=10 HUSKY=0 git push origin ":refs/heads/$branch"'
if ! delete_push_sets_skip_hooks "$SKIP_HOOKS_PROBE"; then
  ok "検出器が SKIP_SIMPLE_GIT_HOOKS=10 を受理しない（self-test）"
else
  bad "検出器が SKIP_SIMPLE_GIT_HOOKS=10 を受理する"
fi
# HUSKY 側の self-test（公開 ff-dev-toolkit#137）。SKIP_SIMPLE_GIT_HOOKS=1 だけの旧形を
# 受理しないこと = husky の consumer でフルゲートが走る形へ戻したら赤になること。
write_skip_hooks_probe 'LC_ALL=C SKIP_SIMPLE_GIT_HOOKS=1 git push --force-with-lease="refs/heads/$branch:$expected" origin ":refs/heads/$branch"'
if ! delete_push_sets_skip_hooks "$SKIP_HOOKS_PROBE"; then
  ok "検出器が HUSKY=0 の無い旧形の git push を検出できる（self-test）"
else
  bad "検出器が HUSKY=0 の無い git push を見逃す"
fi
write_skip_hooks_probe 'SKIP_SIMPLE_GIT_HOOKS=1 XHUSKY=0 git push origin ":refs/heads/$branch"'
if ! delete_push_sets_skip_hooks "$SKIP_HOOKS_PROBE"; then
  ok "検出器が XHUSKY=0 を受理しない（self-test）"
else
  bad "検出器が XHUSKY=0 を受理する"
fi
write_skip_hooks_probe 'SKIP_SIMPLE_GIT_HOOKS=1 HUSKY=00 git push origin ":refs/heads/$branch"'
if ! delete_push_sets_skip_hooks "$SKIP_HOOKS_PROBE"; then
  ok "検出器が HUSKY=00 を受理しない（self-test）"
else
  bad "検出器が HUSKY=00 を受理する"
fi

if delete_push_sets_skip_hooks "$TARGET"; then
  ok "delete_remote_branch_with_lease の git push に SKIP_SIMPLE_GIT_HOOKS=1 と HUSKY=0 がある"
else
  bad "delete_remote_branch_with_lease の git push に SKIP_SIMPLE_GIT_HOOKS=1 / HUSKY=0 が揃っていない"
fi
printf '%s\n' \
  'delete_remote_branch_with_lease() {' \
  '  if [ "${FF_DELETE_PUSH_SKIP_HOOKS-1}" = "1" ]; then' \
  '    LC_ALL=C SKIP_SIMPLE_GIT_HOOKS=1 HUSKY=0 git push origin ":refs/heads/$branch"' \
  '  else' \
  '    git push origin ":refs/heads/$branch"' \
  '  fi' \
  '}' \
  > "$SKIP_HOOKS_PROBE"
if delete_push_sets_skip_hooks "$SKIP_HOOKS_PROBE"; then
  ok "検出器が FF_DELETE_PUSH_SKIP_HOOKS 付きの素の git push を許す（self-test）"
else
  bad "検出器がオプトアウト付きの素の git push を拒否する"
fi
# --no-verify / hooksPath 無効化 / export は契約外。env の command-scoped 代入だけを許す。
if awk '
  /^delete_remote_branch_with_lease\(\)/ { in_fn = 1 }
  in_fn && /^}/ { in_fn = 0 }
  in_fn && /--no-verify|core\.hooksPath|GIT_CONFIG_COUNT|export[[:space:]]+(SKIP_SIMPLE_GIT_HOOKS|HUSKY)/ { bad = 1 }
  END { exit bad ? 1 : 0 }
' "$TARGET"; then
  ok "delete_remote_branch_with_lease に --no-verify / hooksPath 無効化 / export が無い"
else
  bad "delete_remote_branch_with_lease が env 以外の hook 回避を使っている"
fi


echo ""
echo "== 実行: FF_DELETE_PUSH_SKIP_HOOKS =="
HOOK_RT="$TMP/hook-rt"
rm -rf "$HOOK_RT"
mkdir -p "$HOOK_RT/hooks"
git init -q --bare "$HOOK_RT/origin.git"
ff_git_fixture_init "$HOOK_RT/repo"
git -C "$HOOK_RT/repo" config commit.gpgsign false
git -C "$HOOK_RT/repo" config core.hooksPath "$HOOK_RT/hooks"
git -C "$HOOK_RT/repo" checkout -q -b feature
printf 'a\n' >"$HOOK_RT/repo/a.txt"
git -C "$HOOK_RT/repo" add a.txt
git -C "$HOOK_RT/repo" commit -qm a
git -C "$HOOK_RT/repo" remote add origin "$HOOK_RT/origin.git"
git -C "$HOOK_RT/repo" push -q origin feature
HOOK_OID="$(git -C "$HOOK_RT/repo" rev-parse HEAD)"
cat >"$HOOK_RT/hooks/pre-push" <<'HOOK'
#!/bin/sh
if [ "${SKIP_SIMPLE_GIT_HOOKS:-}" = "1" ] && [ "${HUSKY:-}" = "0" ]; then
  printf '%s\n' 'skip=1 husky=skip' >"${HOOK_LOG:?}"
  exit 0
fi
printf '%s\n' 'block=1 husky=run' >"${HOOK_LOG:?}"
exit 1
HOOK
chmod +x "$HOOK_RT/hooks/pre-push"
awk '
  /^delete_remote_branch_with_lease\(\)/ { p = 1 }
  p { print }
  p && /^}/ { exit }
' "$TARGET" >"$HOOK_RT/fn.sh"
run_delete_push() {
  local mode="$1" rc=0
  rm -f "$HOOK_RT/log"
  (
    set +e
    # shellcheck disable=SC1091
    . "$HOOK_RT/fn.sh"
    WORK_TMP="$(mktemp -d)"
    cd "$HOOK_RT/repo" || exit 9
    export HOOK_LOG="$HOOK_RT/log"
    unset SKIP_SIMPLE_GIT_HOOKS HUSKY
    if [ "$mode" = keep ]; then
      export FF_DELETE_PUSH_SKIP_HOOKS=0
    else
      unset FF_DELETE_PUSH_SKIP_HOOKS
    fi
    delete_remote_branch_with_lease feature "$HOOK_OID"
  ) >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}
HOOK_RC="$(run_delete_push skip)"
if [ "$HOOK_RC" = "0" ] && [ "$(cat "$HOOK_RT/log" 2>/dev/null)" = "skip=1 husky=skip" ]; then
  ok "既定の削除 push は SKIP_SIMPLE_GIT_HOOKS=1 と HUSKY=0 で hook 本体を走らせない"
else
  bad "既定の削除 push の hook 観測が違う（rc=${HOOK_RC} log=$(cat "$HOOK_RT/log" 2>/dev/null)）"
fi
git -C "$HOOK_RT/origin.git" update-ref refs/heads/feature "$HOOK_OID"
HOOK_RC="$(run_delete_push keep)"
if [ "$HOOK_RC" != "0" ] && [ "$(cat "$HOOK_RT/log" 2>/dev/null)" = "block=1 husky=run" ]; then
  ok "FF_DELETE_PUSH_SKIP_HOOKS=0 の削除 push は hook を起動する"
else
  bad "オプトアウトの削除 push が hook を起動していない（rc=${HOOK_RC} log=$(cat "$HOOK_RT/log" 2>/dev/null)）"
fi
BAD_ENV_RC=0
BAD_ENV_ERR="$(FF_DELETE_PUSH_SKIP_HOOKS=yes bash "$TARGET" 1 2>&1 >/dev/null)" || BAD_ENV_RC=$?
if [ "$BAD_ENV_RC" -eq 1 ] && printf '%s' "$BAD_ENV_ERR" | awk 'index($0, "FF_DELETE_PUSH_SKIP_HOOKS") { f = 1 } END { exit f ? 0 : 1 }'; then
  ok "FF_DELETE_PUSH_SKIP_HOOKS の不正値は削除の前に rc 1"
else
  bad "不正な FF_DELETE_PUSH_SKIP_HOOKS の扱いが違う（rc=${BAD_ENV_RC}）${BAD_ENV_ERR}"
fi

# ── 検査本体（機能別 cases ファイル。Issue `#2697` で分割） ────────────────
#
# 各ファイルは同一プロセスで source され、上の fixture・関数・PASS/FAIL を共有する。
# **この一覧の順序が契約**で、分割前の verify.sh の行の順序そのもの。後ろの cases は前の cases
# が作った fixture の状態（ブランチ・ログ・mock）を使う。1 ファイルだけを実行する入口は置かない。
# shellcheck source=../lib/suite-cases.sh
. "$SCRIPT_DIR/../lib/suite-cases.sh"
suite_cases_source_setup "$SCRIPT_DIR/cases" fixtures.sh
suite_cases_source "$SCRIPT_DIR/cases" destructive-paths.sh
suite_cases_source "$SCRIPT_DIR/cases" transcripts.sh
suite_cases_source "$SCRIPT_DIR/cases" pr-matching-and-protection.sh
suite_cases_source "$SCRIPT_DIR/cases" agent-worktrees.sh
suite_cases_source "$SCRIPT_DIR/cases" uncommitted-guard.sh
suite_cases_source "$SCRIPT_DIR/cases" cwd-and-dry-run.sh
suite_cases_assert_all_sourced "$SCRIPT_DIR/cases"

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ merge-cleanup verify: $FAIL 件失敗（詳細: 実行ログ抜粋）" >&2
  tail -40 "$TMP/run.log" >&2
  exit 1
fi

# 本体とは別の最小 fixture でも削除・skip を実測する。処理を除いた mutant が
# 赤になることを検証し、候補集合ゼロや名前だけ残った実装を成功へ倒さない。
if bash "$SCRIPT_DIR/agent-branches.sh" "$TARGET"; then
  ok "worktree-agent ブランチの削除条件・dry-run・fail-closed"
else
  bad "worktree-agent ブランチの回帰"
  exit 1
fi
for mutation in missing ancestor worktree remote; do
  AGENT_DIR="$TMP/agent-mutant-${mutation}"
  stage_cleanup_mutant "$AGENT_DIR"
  awk -v mutation="$mutation" '
    /^# agent-branch-cleanup:start/ { inside = 1 }
    inside && mutation == "missing" { if ($0 ~ /^# agent-branch-cleanup:end/) inside = 0; next }
    inside && mutation == "ancestor" && /elif ! git merge-base --is-ancestor/ { print "    elif false; then"; next }
    inside && mutation == "worktree" && /elif grep -qxF "branch refs/ { print "    elif false; then"; next }
    inside && mutation == "remote" && /AGENT_REMOTE_RC=0/ { print "      AGENT_REMOTE_RC=2"; next }
    inside && mutation == "remote" && /git ls-remote --exit-code --heads origin/ { next }
    { print }
    /^# agent-branch-cleanup:end/ { inside = 0 }
  ' "$AGENT_DIR/lib/merge-cleanup-local.sh" > "$AGENT_DIR/lib/merge-cleanup-local.new"
  mv "$AGENT_DIR/lib/merge-cleanup-local.new" "$AGENT_DIR/lib/merge-cleanup-local.sh"
  AGENT_MUTANT="$AGENT_DIR/merge-cleanup.sh"
  if cmp -s "$PLUGIN_ROOT/scripts/lib/merge-cleanup-local.sh" "$AGENT_DIR/lib/merge-cleanup-local.sh"; then
    bad "agent mutant ${mutation} が原本と同一（空振り）"
    exit 1
  fi
  if bash "$SCRIPT_DIR/agent-branches.sh" "$AGENT_MUTANT" > "$TMP/agent-mutant-${mutation}.log" 2>&1; then
    bad "agent mutant ${mutation} が生き残った"
    exit 1
  else
    ok "agent mutant ${mutation} をfixtureが赤にする"
  fi
done

if bash "$SCRIPT_DIR/detached-caller.sh" "$TARGET"; then
  ok "detached linked caller は dry-run・実行・dirty でも両 worktree の HEAD を保つ"
else
  bad "detached linked caller の回帰"
  exit 1
fi
stage_cleanup_mutant "$TMP/detached-mutant"
awk '
  /elif \[ -z "\$CURRENT_BRANCH_BEFORE" \]; then/ { print "elif false; then"; next }
  { print }
' "$TMP/detached-mutant/lib/merge-cleanup-pre.sh" > "$TMP/detached-mutant/lib/merge-cleanup-pre.new"
mv "$TMP/detached-mutant/lib/merge-cleanup-pre.new" "$TMP/detached-mutant/lib/merge-cleanup-pre.sh"
if cmp -s "$PLUGIN_ROOT/scripts/lib/merge-cleanup-pre.sh" "$TMP/detached-mutant/lib/merge-cleanup-pre.sh"; then
  bad "detached caller mutant が原本と同一（空振り）"
  exit 1
fi
if bash "$SCRIPT_DIR/detached-caller.sh" "$TMP/detached-mutant/merge-cleanup.sh" > "$TMP/detached-mutant.log" 2>&1; then
  bad "detached caller の判定欠落を fixture が検出できない"
  exit 1
else
  ok "detached caller の判定を除いた mutant を fixture が赤にする"
fi

# Issue `#2479`: Windows の長いパスの worktree は core.longpaths=true で消し、サマリーに名指しする
if bash "$SCRIPT_DIR/long-paths.sh" "$TARGET"; then
  ok "Windows（msys）は core.longpaths=true で worktree を消して名指しし、他の OS の削除経路は変えない"
else
  bad "長いパスの worktree 削除の回帰"
  exit 1
fi
stage_cleanup_mutant "$TMP/longpaths-mutant"
awk '
  /WT_REMOVE_GIT=\(git -c core\.longpaths=true\)/ { print "    WT_REMOVE_GIT=(git)"; next }
  { print }
' "$TMP/longpaths-mutant/lib/merge-cleanup-local.sh" > "$TMP/longpaths-mutant/lib/merge-cleanup-local.new"
mv "$TMP/longpaths-mutant/lib/merge-cleanup-local.new" "$TMP/longpaths-mutant/lib/merge-cleanup-local.sh"
if cmp -s "$PLUGIN_ROOT/scripts/lib/merge-cleanup-local.sh" "$TMP/longpaths-mutant/lib/merge-cleanup-local.sh"; then
  bad "long paths mutant が原本と同一（空振り）"
  exit 1
fi
if bash "$SCRIPT_DIR/long-paths.sh" "$TMP/longpaths-mutant/merge-cleanup.sh" > "$TMP/longpaths-mutant.log" 2>&1; then
  bad "core.longpaths の欠落を fixture が検出できない"
  exit 1
else
  ok "core.longpaths を外した mutant を fixture が赤にする"
fi

# Issue `#2557`: Windows の git は worktree remove でジャンクションをたどるので、ignored のリンクを先に外す
if bash "$SCRIPT_DIR/windows-junctions.sh" "$TARGET"; then
  ok "Windows のジャンクションの参照先が残り、pnpm と同じ形の worktree が消え、確認後に足したリンクは git が拒否する（他の OS は理由つきの部分 skip）"
else
  bad "Windows のジャンクションを置いた worktree の削除の回帰"
  exit 1
fi
stage_cleanup_mutant "$TMP/junction-mutant"
awk '
  /wt_unlink_ignored_links "\$1" \|\| return 1/ { print "    :"; next }
  { print }
' "$TMP/junction-mutant/lib/merge-cleanup-local.sh" > "$TMP/junction-mutant/lib/merge-cleanup-local.new"
mv "$TMP/junction-mutant/lib/merge-cleanup-local.new" "$TMP/junction-mutant/lib/merge-cleanup-local.sh"
if cmp -s "$PLUGIN_ROOT/scripts/lib/merge-cleanup-local.sh" "$TMP/junction-mutant/lib/merge-cleanup-local.sh"; then
  bad "junction mutant が原本と同一（空振り）"
  exit 1
fi
if bash "$SCRIPT_DIR/long-paths.sh" "$TMP/junction-mutant/merge-cleanup.sh" > "$TMP/junction-mutant.log" 2>&1; then
  bad "リンクを外す工程の欠落を fixture が検出できない"
  exit 1
elif ! grep -qF 'the ignored link was still in the worktree' "$TMP/junction-mutant.log"; then
  bad "リンクを外す工程を除いた mutant は赤だが、針（呼び出し時点のリンク数）以外の理由で落ちた"
  exit 1
else
  ok "リンクを外す工程を除いた mutant を long-paths.sh の呼び出し時点のリンク数が赤にする"
fi
case "${OSTYPE:-}" in
  msys* | cygwin*)
    # 回ごとに確かめる（最初の回の失敗で後の回が走らず、pnpm の回の検出力が隠れないように）
    for junction_case in outside pnpm; do
      if JUNC_CASES="$junction_case" bash "$SCRIPT_DIR/windows-junctions.sh" "$TMP/junction-mutant/merge-cleanup.sh" > "$TMP/junction-mutant-$junction_case.log" 2>&1; then
        bad "リンクを外す工程の欠落を Windows の実物のジャンクション（${junction_case} の回）が検出できない"
        exit 1
      else
        ok "リンクを外す工程を除いた mutant を windows-junctions.sh の ${junction_case} の回が実物のジャンクションで赤にする"
      fi
    done
    ;;
esac
stage_cleanup_mutant "$TMP/stray-mutant"
awk '
  /if \[ -n "\$stray" \]; then/ { print "  if false; then"; next }
  { print }
' "$TMP/stray-mutant/lib/merge-cleanup-local.sh" > "$TMP/stray-mutant/lib/merge-cleanup-local.new"
mv "$TMP/stray-mutant/lib/merge-cleanup-local.new" "$TMP/stray-mutant/lib/merge-cleanup-local.sh"
if cmp -s "$PLUGIN_ROOT/scripts/lib/merge-cleanup-local.sh" "$TMP/stray-mutant/lib/merge-cleanup-local.sh"; then
  bad "stray mutant が原本と同一（空振り）"
  exit 1
fi
if bash "$SCRIPT_DIR/long-paths.sh" "$TMP/stray-mutant/merge-cleanup.sh" > "$TMP/stray-mutant.log" 2>&1; then
  bad "追跡していないリンクが残る回の停止の欠落を fixture が検出できない"
  exit 1
elif ! grep -qF '(stop hidden-untracked)' "$TMP/stray-mutant.log"; then
  bad "残ったリンクの確認を除いた mutant は赤だが、hidden-untracked の回以外の理由で落ちた"
  exit 1
else
  ok "残ったリンクの確認を除いた mutant を long-paths.sh の hidden-untracked の回が赤にする"
fi

echo "✓ merge-cleanup verify: 全 $PASS 件 pass"
FF_REACHED_END=1
