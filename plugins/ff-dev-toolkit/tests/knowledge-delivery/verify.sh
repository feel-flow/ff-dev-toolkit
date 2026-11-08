#!/usr/bin/env bash
# 知見の反映モード（ADR-083・Issue `#2690`）: マージごと（既定）と「まとめて」の書き込み先・flush・
# /knowledge-lookup の未反映表示を、bare の origin と clone で実際に動かして確かめる。
# 空振り検出: 設定の不在は K2（マージごとの出力が変わらない）、空の設定は K1 で per-merge として実測する。未知キー・重複・default と同名の staging・key=value でない行は K1 が rc 2 を要求し、staging が無い（K3）・先行された（K5）・衝突した（K9/K10）・送信範囲に余計なコミットがある（K8）・lookup の追跡 ref が無い/古い（K14 stale）・設定が不正（K14 bad）の各入力で、緑へ倒れずに名指しで止まる（または未確認と書く）ことを実測する
# 空振り検出: staging に知見の置き場以外の変更がある（K18）・知見コミットが置き場の外を含む（K19）入力で、target / flush / push が checkout も送信もせずに止まることを実測する。detached HEAD から始めた回（K17）は元の sha へ戻る
# 空振り検出: 置き場の中のシンボリックリンク（K20）・共通の祖先が複数（K21）・merge が知見の変更を置き場の外へ運ぶ（K22。事前の検査は通り、実際のツリーの検査だけが止める）入力で止まることを実測する
# 空振り検出: lookup は default の追跡 ref だけが古い（K33）・共通の祖先が 2 つ（K34）・staging のコミットが base の
# 祖先でない（K35。flush の PR が squash で入った回）入力で、反映済みの知見を未反映と言い切らないことを実測する
# 変異検出（2026-11-08 に macOS の bash 3.2 で実測。変異なしは 79 件緑。変異は 1 件ずつ複製へ当て、39 種すべて赤）:
#   lookup が default の追跡 ref の古さを見ない（K33）/ 共通の祖先を 1 つだけ使う（K34）/ default の先端と同じ
#   本文を未反映に数える（K35）/ 追記 0 件の push で元へ戻らない（K25）/ 古い git を版で名指ししない（K27）/ 反映の設定ファイルを範囲外に
#   しない（K28）/ lookup が手元のツリー・default の先端と比べる、作業ツリーに設定の無い枝で引かない（K29・K29b）/
#   claim の基準を起点に固定しない（K16b）/ --base-commit が祖先を確かめない（K16c）/ pr が fetch せずに設定を
#   読む（K32）/ 以下は 1 巡目までの変異:
#   通常ファイル以外を見ない（K20）/ 共通の祖先が複数でも止まらない（K21）/ target の起点・flush の merge の
#   ツリー検査の除去（K22。K22 を足す前は事前の検査と重複して生き残った）/
#   detached から始めた回に元の sha へ戻らない（K17）/ target・flush・push の置き場の範囲検査の除去（K18・K19）/
#   staging でなく default へ push（K3 ほか）/ マージごとの push・add・pr の batch ガード除去（K6）/ target が常に
#   default を起点にする（K3b・K4）/ flush を squash にする（K7）/ flush の送信範囲検査の除去（K8。条件は親の照合と
#   「staging から届かないコミット」の 2 節で冗長に守っているので、片方だけを外す変異は生き残る）/ target 再入・add の
#   staging 先行検査の除去（K5）/ lookup の更新判定・追跡 ref の古さ判定・設定不正の通知の除去（K14）/ マージごとでも
#   staging を読む（K2b）/ 未知キー・default と同名の staging の受理（K1）/ flush・target の衝突で merge を中断しない
#   （K9・K10）/ 警告閾値の無効化（K13）/ probe が batch を見ない（K4）/ batch push の送信範囲検査の除去（K3b）/ push の
#   後に戻らない・記録を消さない（K3）/ 未コミットの変更を見ない（K12）/ マージごとの target が staging の残りを
#   知らせない（K15）
# 途中の失敗で残りのケースを黙って飛ばさないよう -e を付けない（各ケースは check で数える）
set -uo pipefail
HERE="$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN="$(CDPATH='' cd -P -- "$HERE/../.." && pwd -P)"
# shellcheck source=../lib/git-fixture.sh
. "$PLUGIN/tests/lib/git-fixture.sh"
FIN="$PLUGIN/scripts/finish.sh"
LK="$PLUGIN/scripts/knowledge-lookup.sh"
KD_LIB="$PLUGIN/scripts/lib/knowledge-delivery-functions.sh"
for file in "$FIN" "$LK" "$KD_LIB" "$PLUGIN/scripts/lib/finish-knowledge-batch-functions.sh" "$PLUGIN/scripts/lib/knowledge-lookup-unreflected.sh"; do
  if [ ! -f "$file" ] || [ ! -s "$file" ] || [ ! -r "$file" ]; then
    printf '✗ knowledge-delivery: 対象を読めません: %s\n' "$file" >&2; exit 1
  fi
done
command -v git >/dev/null 2>&1 || { printf '✗ knowledge-delivery: git がありません\n' >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/knowledge-delivery-test.XXXXXX")"
# 途中死（set -u による死を含む）を rc=0 で終わらせない。素の `trap 'rm -rf …' EXIT` はトラップの最終
# コマンドの成功で終了ステータスを上書きするので、末尾へ到達した回だけ本来の rc で終わる。
FINISHED=0
cleanup() {
  local rc=$?
  rm -rf -- "$TMP"
  if [ "$FINISHED" -ne 1 ]; then
    printf '✗ knowledge-delivery: suite が途中で終了しました（rc=%s）\n' "$rc" >&2
    exit 1
  fi
  exit "$rc"
}
trap cleanup EXIT
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
: >"$GIT_CONFIG_GLOBAL"
# gh は呼ばれても失敗する stub（保護判定は unknown・PR は記録だけ）。ネットワークへ出ない
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
if [ "${1:-}" = pr ] && [ "${2:-}" = create ]; then
  printf '%s\n' "$*" >>"${KD_GH_LOG:?}"
  echo "https://example.com/pull/1"
  exit 0
fi
exit 1
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" KD_GH_LOG="$TMP/gh.log"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '✗ %s\n' "$1"; }
check() { if eval "$1"; then ok "$2"; else bad "$2"; [ -z "${3:-}" ] || cat "$3" >&2 || true; fi; }
kc() { FF_DEV_TOOLKIT_ROOT="$PLUGIN" bash "$FIN" knowledge-commit "$@"; }
lk() { FF_DEV_TOOLKIT_ROOT="$PLUGIN" bash "$LK" "$@"; }
run() { # <出力の置き場> <コマンド...> → RC へ終了コード
  local out="$1"; shift
  RC=0; "$@" >"$out.out" 2>"$out.err" || RC=$?
}

ENTRY_OBS() { printf '\n### %s: %s\n| Kind | problem |\n| Count | 1 |\n| Last | 2026-11-07 |\n| Status | active |\n| Issue | なし |\n\n---\n' "$1" "$2"; }

# 世界を作る: origin（bare, develop）と seed / a / b の clone。<設定の本文 or 空>
new_world() {
  local conf="${1:-}" w
  W="$TMP/w$((++WORLD))"; w="$W"
  mkdir -p "$w"
  git init -q --bare "$w/origin.git"
  ff_git_fixture_init "$w/seed" "KD Test" "kd-test@example.com" >/dev/null
  (
    cd "$w/seed"
    git switch -q -c develop
    mkdir -p docs/08-knowledge/playbook
    printf '# 観測台帳\n\n## エントリ一覧\n' >docs/08-knowledge/OBSERVATIONS.md
    ENTRY_OBS OBS-001 '共有の落とし穴' >>docs/08-knowledge/OBSERVATIONS.md
    printf '# PLAYBOOK\n\n## エントリ一覧\n' >docs/08-knowledge/PLAYBOOK.md
    printf '# testing\n\n### ACE-1-1: 共有の手順\n| Category | testing |\n| Status | active |\n| Helpful | 0 |\n\n---\n' >docs/08-knowledge/playbook/testing.md
    [ -z "$conf" ] || printf '%s\n' "$conf" >docs/08-knowledge/knowledge-delivery.conf
    echo app >app.txt
    git add -A && git commit -qm init
    git remote add origin "$w/origin.git"
    git push -q origin develop
  )
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/develop
  git -C "$w/seed" fetch -q origin && git -C "$w/seed" remote set-head origin develop >/dev/null
  git -C "$w/seed" branch -q --set-upstream-to=origin/develop develop
  for c in a b; do
    git clone -q "$w/origin.git" "$w/$c"
    ff_git_fixture_init "$w/$c" "KD Test" "kd-test@example.com" >/dev/null
  done
}
WORLD=0
advance_develop() { # <ファイル> <本文> — seed から develop を進める
  ( cd "$W/seed" && git pull -q origin develop && printf '%s\n' "$2" >>"$1" && git add -A && git commit -qm "feat: advance" && git push -q origin develop )
}
write_obs() { # <clone> <ID> <title> — target 済みの clone へ観測を書いて add / commit
  ( cd "$W/$1" && ENTRY_OBS "$2" "$3" >>docs/08-knowledge/OBSERVATIONS.md \
    && kc add --source obs --id "$2" --summary "$3" -- docs/08-knowledge/OBSERVATIONS.md >/dev/null 2>&1 \
    && kc commit >/dev/null 2>&1 )
}
origin_sha() { git -C "$W/origin.git" rev-parse --verify --quiet "refs/heads/$1" || true; }
set_count() { # <ID> <n> — 作業ツリーの台帳で、その ID のエントリの Count 行だけを書き換える
  awk -v id="$1" -v n="$2" '
    /^### / { inside = (index($0, "### " id ":") == 1) }
    inside && /^\| Count \|/ && !done { print "| Count | " n " |"; done = 1; next }
    { print }' docs/08-knowledge/OBSERVATIONS.md >"$TMP/obs.new" && mv "$TMP/obs.new" docs/08-knowledge/OBSERVATIONS.md
}

# ── K1: 設定の解釈（lib を直接 source） ───────────────────────────────────────
(
  # shellcheck source=../../scripts/lib/knowledge-delivery-functions.sh
  . "$KD_LIB"
  p() { ff_kd_reset; ff_kd_parse "$1" test develop 2>/dev/null; }
  r=0; p $'mode=batch' || r=$?; [ "$r" -eq 0 ] && [ "$KD_MODE" = batch ] && [ "$KD_STAGING" = knowledge/staging ] && [ "$KD_WARN_DAYS" = 7 ] && echo ok1
  r=0; p $'# c\n\n  mode = per-merge  \r\nstaging_branch=kb/pending\nwarn_after_days=14' || r=$?; [ "$r" -eq 0 ] && [ "$KD_MODE" = per-merge ] && [ "$KD_STAGING" = kb/pending ] && [ "$KD_WARN_DAYS" = 14 ] && echo ok2
  r=0; p '' || r=$?; [ "$r" -eq 0 ] && [ "$KD_MODE" = per-merge ] && echo ok3
  for bad_conf in 'mode=bogus' 'color=red' $'mode=batch\nmode=batch' 'staging_branch=develop' 'staging_branch=chore/ace-from-pr-1' \
    'staging_branch=knowledge' 'staging_branch=knowledge/flush-x' 'staging_branch=bad..name' 'staging_branch=x/ace-from-pr-2' \
    'warn_after_days=0' 'warn_after_days=abc' 'just a line'; do
    r=0; p "$bad_conf" || r=$?; [ "$r" -eq 2 ] || echo "accepted:$bad_conf"
  done
) >"$TMP/k1.out" 2>&1 || true
check 'grep -qx ok1 "$TMP/k1.out" && grep -qx ok2 "$TMP/k1.out" && grep -qx ok3 "$TMP/k1.out"' "K1: 正しい設定（既定値・空白・CRLF・注釈・空）を読む" "$TMP/k1.out"
check '! grep -q "^accepted:" "$TMP/k1.out"' "K1: 不正な mode・未知キー・重複・default と同名・知見/flush ブランチと重なる名前・不正な ref 名・範囲外の日数・key=value でない行を rc 2 で拒否する" "$TMP/k1.out"

# ── K2: 設定なし（マージごと）は何も変えない ─────────────────────────────────
new_world ""
cd "$W/a"
run "$TMP/k2t" kc target
check '[ "$RC" -eq 0 ] && grep -qx "KNOWLEDGE_DELIVERY=per-merge" "$TMP/k2t.out" && grep -qx "KNOWLEDGE_TARGET=develop" "$TMP/k2t.out" && [ "$(git branch --show-current)" = develop ]' \
  "K2: 設定なしの target はマージごとを出し、HEAD を動かさない" "$TMP/k2t.err"
run "$TMP/k2p" kc probe
check '[ "$RC" -eq 0 ] && grep -q "^protection=" "$TMP/k2p.out" && ! grep -q "KNOWLEDGE_DELIVERY\|protection=batch" "$TMP/k2p.out" && [ "$(git branch --show-current)" = develop ]' \
  "K2: 設定なしの probe は従来の保護判定だけを出す（batch の行を出さない）" "$TMP/k2p.err"
write_obs a OBS-002 'マージごとの観測'
run "$TMP/k2push" kc push
check '[ "$RC" -eq 0 ] && grep -qx "KNOWLEDGE_PUSH=ok" "$TMP/k2push.out" && [ "$(origin_sha develop)" = "$(git rev-parse HEAD)" ] && [ -z "$(origin_sha knowledge/staging)" ]' \
  "K2: 設定なしの push は従来どおり develop へ届き、staging を作らない" "$TMP/k2push.err"
run "$TMP/k2s" kc status
check '[ "$RC" -eq 0 ] && [ "$(cat "$TMP/k2s.out")" = "KNOWLEDGE_PENDING=0" ]' "K2: 設定なしの status の出力は従来の 1 行のまま" "$TMP/k2s.out"
lk --offline 共有 >"$TMP/k2l.out" 2>&1 || true
check '! grep -q "未反映\|unreflected" "$TMP/k2l.out" && grep -q "^RECORD ace=ACE-1-1 obs=OBS-001$" "$TMP/k2l.out"' \
  "K2: 設定なしの lookup は未反映の節・列を出さない（RECORD は従来の形）" "$TMP/k2l.out"

# K2b: 設定ファイルがあっても mode=per-merge なら同じ（staging に何があっても書き込み先は develop）
new_world $'mode=per-merge\nstaging_branch=kb/pending'
cd "$W/a"
run "$TMP/k2bt" kc target
lk --offline 共有 >"$TMP/k2bl.out" 2>&1 || true
check '[ "$RC" -eq 0 ] && grep -qx "KNOWLEDGE_DELIVERY=per-merge" "$TMP/k2bt.out" && [ "$(git branch --show-current)" = develop ] && ! grep -q "未反映\|unreflected" "$TMP/k2bl.out"' \
  "K2b: mode=per-merge を明示した設定は target・lookup とも設定なしと同じに振る舞う" "$TMP/k2bt.err"

# ── K3〜K7: まとめるモード ───────────────────────────────────────────────────
new_world "mode=batch"
D0="$(origin_sha develop)"
cd "$W/a"
run "$TMP/k3t" kc target
STATE_A="$(git rev-parse --absolute-git-dir)/ff-knowledge-target"
check '[ "$RC" -eq 0 ] && grep -qx "KNOWLEDGE_DELIVERY=batch" "$TMP/k3t.out" && grep -qx "KNOWLEDGE_TARGET=knowledge/staging" "$TMP/k3t.out" && [ -z "$(git branch --show-current)" ] && [ "$(git rev-parse HEAD)" = "$D0" ] && [ -f "$STATE_A" ]' \
  "K3: staging が無いときの target は origin/develop の先端へ detached で移り、記録を残す" "$TMP/k3t.err"
run "$TMP/k3s" kc status
check 'grep -qx "KNOWLEDGE_DELIVERY=batch" "$TMP/k3s.out" && grep -qx "KNOWLEDGE_RESTORE=develop" "$TMP/k3s.out"' "K3: 書き込み中の status は書き込み先と戻り先を出す" "$TMP/k3s.out"
write_obs a OBS-002 'A の観測'
run "$TMP/k3push" kc push
check '[ "$RC" -eq 0 ] && grep -qx "KNOWLEDGE_PUSH=ok" "$TMP/k3push.out" && grep -qx "KNOWLEDGE_UNREFLECTED=1" "$TMP/k3push.out" && [ -n "$(origin_sha knowledge/staging)" ] && [ "$(origin_sha develop)" = "$D0" ]' \
  "K3: push は staging を作って知見を送り、develop を進めない" "$TMP/k3push.err"
check '[ "$(git branch --show-current)" = develop ] && [ ! -e "$STATE_A" ]' "K3: push の後は元のブランチへ戻り、記録を消す"
# K3b: 起点の上にコミットが 2 つあれば送らない（無関係なコミットを staging へ載せない）
run "$TMP/k3bt" kc target
S_BEFORE="$(origin_sha knowledge/staging)"
echo extra >>app.txt && git -c core.hooksPath=/dev/null commit -qam "feat: 無関係なコミット"
write_obs a OBS-005 'A の 2 件目'
run "$TMP/k3b" kc push
check '[ "$RC" -eq 2 ] && grep -qx "KNOWLEDGE_PUSH=scope-mismatch" "$TMP/k3b.out" && [ "$(origin_sha knowledge/staging)" = "$S_BEFORE" ]' \
  "K3b: 起点の上が知見コミット 1 つでなければ push は送らない（scope-mismatch）" "$TMP/k3b.err"
kc discard >/dev/null 2>&1; git switch -q -f develop

advance_develop app.txt 'feature 1'
cd "$W/b" && git pull -q origin develop
run "$TMP/k4p" kc probe
check '[ "$RC" -eq 0 ] && grep -q "^protection=batch " "$TMP/k4p.out" && [ -z "$(git branch --show-current)" ] && [ "$(git rev-parse HEAD^1)" = "$(origin_sha knowledge/staging)" ] && [ "$(git rev-parse HEAD^2)" = "$(origin_sha develop)" ]' \
  "K4: develop が進んでいれば probe は staging に develop を取り込んだ merge を起点にする（protection=batch）" "$TMP/k4p.err"
check 'grep -q "^### OBS-002: A の観測" docs/08-knowledge/OBSERVATIONS.md && grep -qx "feature 1" app.txt' \
  "K4: 起点のツリーは未反映の知見（OBS-002）と最新の develop の両方を含む（照合・採番はこのツリーで行う）"
write_obs b OBS-003 'B の観測'
run "$TMP/k4push" kc push
PUSHED_B="$(sed -n 's/^KNOWLEDGE_PUSHED_SHA=//p' "$TMP/k4push.out")"
check '[ "$RC" -eq 0 ] && [ -n "$PUSHED_B" ] && [ "$(origin_sha knowledge/staging)" = "$PUSHED_B" ] && git -C "$W/origin.git" merge-base --is-ancestor "$(git -C "$W/a" rev-parse origin/knowledge/staging)" knowledge/staging && ! git -C "$W/origin.git" merge-base --is-ancestor "$PUSHED_B" develop' \
  "K4: 2 人目の push は staging を fast-forward で進める（develop へは届かない）" "$TMP/k4push.err"

# K5: 並行（同じ staging の先端から 2 セッション）
cd "$W/a" && git pull -q origin develop
run "$TMP/k5ta" kc target
cd "$W/b" && git pull -q origin develop
run "$TMP/k5tb" kc target
write_obs a OBS-004 'A の 2 件目'
( cd "$W/a" && kc push >/dev/null 2>&1 )
S_AFTER_A="$(origin_sha knowledge/staging)"
cd "$W/b"
run "$TMP/k5re" kc target
check '[ "$RC" -eq 1 ] && grep -qx "KNOWLEDGE_TARGET_FRESH=stale" "$TMP/k5re.out"' "K5: 書き込み中に staging が先行されたら target（再入）は止まる" "$TMP/k5re.err"
ENTRY_OBS OBS-004 'B が同じ番号で書いた観測' >>docs/08-knowledge/OBSERVATIONS.md
run "$TMP/k5add" kc add --source obs --id OBS-004 --summary dup -- docs/08-knowledge/OBSERVATIONS.md
check '[ "$RC" -eq 1 ] && grep -q "先行している" "$TMP/k5add.err" && [ -z "$(git diff --cached --name-only)" ]' \
  "K5: 先行された後の add は stage せずに止まる（古いツリーで採番した OBS-004 を送らない）" "$TMP/k5add.err"
git -c core.hooksPath=/dev/null commit -qm "knowledge: OBS-004 dup" -- docs/08-knowledge/OBSERVATIONS.md
run "$TMP/k5push" kc push
check '[ "$RC" -ne 0 ] && [ "$(origin_sha knowledge/staging)" = "$S_AFTER_A" ]' "K5: 先行された staging への push は拒否され、staging は A の先端のまま" "$TMP/k5push.err"
# 拒否の案内を印字どおりに流す（パッチへ退避 → reset --soft → restore → discard → 戻り先 → target → 採番し直し）
START5="$(sed -n 's/^start=//p' "$(git rev-parse --absolute-git-dir)/ff-knowledge-target")"
check 'grep -qF "git restore --source=$START5 --staged --worktree -- docs/08-knowledge/OBSERVATIONS.md" "$TMP/k5push.err" && grep -qF "git reset -q --soft $START5" "$TMP/k5push.err" && grep -qF "→ git switch develop →" "$TMP/k5push.err"' \
  "K5: 拒否の案内は、変更したパスだけを名指しした実行できる手順になっている" "$TMP/k5push.err"
REDO=1
git diff "$START5" -- docs/08-knowledge/OBSERVATIONS.md >"$TMP/k5.patch" || REDO=0
git reset -q --soft "$START5" || REDO=0
git restore --source="$START5" --staged --worktree -- docs/08-knowledge/OBSERVATIONS.md || REDO=0
kc discard >/dev/null 2>&1 || REDO=0
git switch -q develop || REDO=0
run "$TMP/k5redo" kc target
check '[ "$REDO" -eq 1 ] && [ "$RC" -eq 0 ] && grep -q "^### OBS-004: A の 2 件目" docs/08-knowledge/OBSERVATIONS.md && [ -s "$TMP/k5.patch" ]' \
  "K5: 案内どおりに退避して戻ると、target は A の追記を含む起点へ移り直せる" "$TMP/k5redo.err"
write_obs b OBS-005 'B の観測（取り込んだ後のツリーで採番し直した）'
run "$TMP/k5redopush" kc push
check '[ "$RC" -eq 0 ] && git -C "$W/origin.git" merge-base --is-ancestor "$S_AFTER_A" knowledge/staging && [ "$(git branch --show-current)" = develop ]' \
  "K5: 採番し直した追記は staging へ fast-forward で届き、元のブランチへ戻る" "$TMP/k5redopush.err"

# K6: まとめるモードで base へ直接書かない
cd "$W/a" && git switch -q develop 2>/dev/null; git pull -q origin develop
ENTRY_OBS OBS-009 '直接書こうとした観測' >>docs/08-knowledge/OBSERVATIONS.md
run "$TMP/k6add" kc add --source obs --id OBS-009 --summary x -- docs/08-knowledge/OBSERVATIONS.md
check '[ "$RC" -eq 1 ] && grep -q "まとめるモード" "$TMP/k6add.err" && [ -z "$(git diff --cached --name-only)" ]' \
  "K6: まとめるモードで target を通さない add は develop の上で止まる" "$TMP/k6add.err"
git -c core.hooksPath=/dev/null commit -qm "knowledge: OBS-009 x" -- docs/08-knowledge/OBSERVATIONS.md
D_BEFORE="$(origin_sha develop)"
run "$TMP/k6push" kc push
check '[ "$RC" -eq 1 ] && grep -q "まとめるモード" "$TMP/k6push.err" && [ "$(origin_sha develop)" = "$D_BEFORE" ]' \
  "K6: まとめるモードで develop への知見の直接 push を拒否する" "$TMP/k6push.err"
run "$TMP/k6pr" kc pr --branch chore/ace-from-pr-9 --title "knowledge: x"
check '[ "$RC" -eq 1 ] && grep -q "まとめるモード" "$TMP/k6pr.err" && [ -z "$(origin_sha chore/ace-from-pr-9)" ]' \
  "K6: まとめるモードで知見 PR を作らない" "$TMP/k6pr.err"
git reset -q --hard origin/develop

# K7: flush
run "$TMP/k7d" kc flush --dry-run
check '[ "$RC" -eq 0 ] && grep -qx "KNOWLEDGE_FLUSH=dry-run" "$TMP/k7d.out" && grep -qx "KNOWLEDGE_FLUSH_PENDING=4" "$TMP/k7d.out" && grep -q "変更するパス: docs/08-knowledge/OBSERVATIONS.md" "$TMP/k7d.out"' \
  "K7: flush --dry-run は未反映のコミット数（merge を除く 4）と変更するパスを出す" "$TMP/k7d.err"
D_PRE="$(origin_sha develop)"; S_PRE="$(origin_sha knowledge/staging)"
run "$TMP/k7f" kc flush
D_POST="$(origin_sha develop)"
check '[ "$RC" -eq 0 ] && grep -qx "KNOWLEDGE_FLUSH=ok" "$TMP/k7f.out" && [ "$(git -C "$W/origin.git" rev-parse "$D_POST^1")" = "$D_PRE" ] && [ "$(git -C "$W/origin.git" rev-parse "$D_POST^2")" = "$S_PRE" ]' \
  "K7: flush は develop へ merge commit 1 つ（親 = 旧 develop と staging の先端）を送る" "$TMP/k7f.err"
check 'git -C "$W/origin.git" merge-base --is-ancestor knowledge/staging develop && [ "$(git branch --show-current)" = develop ]' \
  "K7: flush の後、staging は develop の祖先になり、元のブランチへ戻る"
run "$TMP/k7again" kc flush
check '[ "$RC" -eq 0 ] && grep -qx "KNOWLEDGE_FLUSH=nothing" "$TMP/k7again.out" && [ "$(origin_sha develop)" = "$D_POST" ]' "K7: 未反映が無ければ flush は何もしない" "$TMP/k7again.err"
git pull -q origin develop
run "$TMP/k7t" kc target
check '[ "$RC" -eq 0 ] && [ "$(git rev-parse HEAD)" = "$D_POST" ] && grep -qx "KNOWLEDGE_UNREFLECTED=0" "$TMP/k7t.out"' \
  "K7: flush の後の target は develop の先端を起点にする（staging へは fast-forward で続く）" "$TMP/k7t.err"
write_obs a OBS-010 'flush 後の観測'
run "$TMP/k7push" kc push
check '[ "$RC" -eq 0 ] && git -C "$W/origin.git" merge-base --is-ancestor "$S_PRE" knowledge/staging' "K7: flush の後の push も force なしで staging を進める" "$TMP/k7push.err"

# ── K8: flush は作業ツリーにも hook にも触れない（merge-tree と commit-tree で作る） ─────
cd "$W/b" && git switch -q develop 2>/dev/null; git pull -q origin develop
mkdir -p "$TMP/hooks-extra"
for h in pre-commit commit-msg pre-merge-commit post-merge post-commit post-checkout; do
  printf '#!/bin/sh\necho %s >>"%s"\n' "$h" "$TMP/k8-hooks-ran" >"$TMP/hooks-extra/$h"
  chmod +x "$TMP/hooks-extra/$h"
done
git config core.hooksPath "$TMP/hooks-extra"
B_HEAD="$(git rev-parse HEAD)"
run "$TMP/k8" kc flush
git config --unset core.hooksPath
check '[ "$RC" -eq 0 ] && grep -qx "KNOWLEDGE_FLUSH=ok" "$TMP/k8.out" && [ ! -e "$TMP/k8-hooks-ran" ] && [ "$(git rev-parse HEAD)" = "$B_HEAD" ] && [ "$(git branch --show-current)" = develop ]' \
  "K8: flush は hook を 1 つも起動せず、HEAD も作業ツリーも動かさずに base へ送る" "$TMP/k8.err"

# ── K9 / K10: 衝突 ───────────────────────────────────────────────────────────
# staging 側: 正規の経路で OBS-001 の Count を 2 へ（未反映のまま残す）
cd "$W/a" && git switch -q develop 2>/dev/null; git pull -q origin develop
run "$TMP/k9prep" kc target
set_count OBS-001 2
kc add --source obs --id OBS-001 --summary "+1" -- docs/08-knowledge/OBSERVATIONS.md >/dev/null 2>&1 && kc commit >/dev/null 2>&1 && kc push >"$TMP/k9prep.push" 2>&1
check 'grep -qx "KNOWLEDGE_PUSH=ok" "$TMP/k9prep.push"' "K9: 準備（staging 側で OBS-001 の Count を更新）" "$TMP/k9prep.push"
# base 側: 同じ行を知見の経路を通さずに変える（/ace-refine や手作業の変更に相当）
cd "$W/seed" && git pull -q origin develop
set_count OBS-001 5
git commit -qam "docs: base 側で台帳を直接変える" && git push -q origin develop
cd "$W/b" && git switch -q develop 2>/dev/null; git pull -q origin develop
D_PRE="$(origin_sha develop)"
run "$TMP/k9" kc flush
check '[ "$RC" -eq 1 ] && grep -qx "KNOWLEDGE_FLUSH=conflict" "$TMP/k9.out" && [ "$(origin_sha develop)" = "$D_PRE" ] && [ "$(git branch --show-current)" = develop ] && [ ! -e "$(git rev-parse --absolute-git-dir)/MERGE_HEAD" ]' \
  "K9: base 側と staging 側で知見ファイルが衝突したら flush は送らずに止まり、merge を中断して元へ戻る" "$TMP/k9.err"
run "$TMP/k10" kc target
check '[ "$RC" -eq 1 ] && grep -qx "KNOWLEDGE_TARGET=conflict" "$TMP/k10.out" && [ "$(git branch --show-current)" = develop ] && [ ! -e "$(git rev-parse --absolute-git-dir)/ff-knowledge-target" ]' \
  "K10: 起点の merge が衝突したら target は止まり、元のブランチへ戻って記録を残さない" "$TMP/k10.err"

# ── K11: flush --pr ──────────────────────────────────────────────────────────
new_world "mode=batch"
cd "$W/a"; kc target >/dev/null 2>&1; write_obs a OBS-002 'PR 経路の観測'; kc push >/dev/null 2>&1
D_PRE="$(origin_sha develop)"
run "$TMP/k11bad" kc flush --branch topic/x
check '[ "$RC" -eq 2 ]' "K11: flush --branch は knowledge/flush- で始まらない名前を拒否する" "$TMP/k11bad.err"
: >"$KD_GH_LOG"
run "$TMP/k11" kc flush --pr --type chore
FB="$(sed -n 's/^KNOWLEDGE_FLUSH_BRANCH=//p' "$TMP/k11.out")"
check '[ "$RC" -eq 0 ] && grep -qx "KNOWLEDGE_FLUSH=pr" "$TMP/k11.out" && case "$FB" in knowledge/flush-?*) true ;; *) false ;; esac && [ -n "$(origin_sha "$FB")" ] && [ "$(origin_sha develop)" = "$D_PRE" ] && grep -q -- "--base develop --head $FB --title chore: " "$KD_GH_LOG"' \
  "K11: flush --pr は使い捨ての knowledge/flush-* から PR を作り、develop へは直接送らない" "$TMP/k11.err"
check '[ "$(git -C "$W/origin.git" rev-parse "$FB^2")" = "$(origin_sha knowledge/staging)" ]' "K11: PR のブランチは staging を取り込む merge commit（staging 自体を PR の head にしない）"

# ── K12: target の前提崩れ ──────────────────────────────────────────────────
cd "$W/b"
echo dirty >>app.txt
run "$TMP/k12dirty" kc target
check '[ "$RC" -eq 1 ] && [ "$(git branch --show-current)" = develop ]' "K12: 未コミットの変更があれば target は移らない" "$TMP/k12dirty.err"
git checkout -q -- app.txt
git switch -q -c chore/ace-from-pr-5
run "$TMP/k12kb" kc target
check '[ "$RC" -eq 2 ] && [ "$(git branch --show-current)" = chore/ace-from-pr-5 ]' "K12: 既存の知見ブランチの上では target しない" "$TMP/k12kb.err"
git switch -q develop

# ── K13: 警告の閾値 ─────────────────────────────────────────────────────────
new_world $'mode=batch\nwarn_after_days=2'
cd "$W/a"; kc target >/dev/null 2>&1
ENTRY_OBS OBS-002 '古い観測' >>docs/08-knowledge/OBSERVATIONS.md
kc add --source obs --id OBS-002 --summary old -- docs/08-knowledge/OBSERVATIONS.md >/dev/null 2>&1
OLD="$(( $(date +%s) - 5 * 86400 ))"
GIT_COMMITTER_DATE="@$OLD +0000" GIT_AUTHOR_DATE="@$OLD +0000" kc commit >/dev/null 2>&1
kc push >/dev/null 2>&1
cd "$W/b"
run "$TMP/k13" kc target
check '[ "$RC" -eq 0 ] && grep -qx "KNOWLEDGE_UNREFLECTED_DAYS=5" "$TMP/k13.out" && grep -q "溜まっています" "$TMP/k13.err"' \
  "K13: 未反映の最古が warn_after_days 以上なら target が flush を促す" "$TMP/k13.err"
kc discard >/dev/null 2>&1; git switch -q develop

# ── K14: lookup の未反映表示 ─────────────────────────────────────────────────
new_world "mode=batch"
cd "$W/a"; kc target >/dev/null 2>&1
sed 's/^| Count | 1 |$/| Count | 2 |/' docs/08-knowledge/OBSERVATIONS.md >"$TMP/obs.new" && mv "$TMP/obs.new" docs/08-knowledge/OBSERVATIONS.md
ENTRY_OBS OBS-002 '共有の新しい観測' >>docs/08-knowledge/OBSERVATIONS.md
printf '\n### ACE-2-1: 共有の新しい手順\n| Category | testing |\n| Status | active |\n| Helpful | 0 |\n\n---\n' >>docs/08-knowledge/playbook/testing.md
kc add --source obs --id OBS-002 --summary x -- docs/08-knowledge/OBSERVATIONS.md docs/08-knowledge/playbook/testing.md >/dev/null 2>&1
kc commit >/dev/null 2>&1; kc push >/dev/null 2>&1
cd "$W/b"
lk 共有 >"$TMP/k14stale.out" 2>&1 || true
check 'grep -q "unreflected=0 件（未確認: 手元の追跡 ref が remote と違う" "$TMP/k14stale.out" && grep -q "unreflected_state=stale" "$TMP/k14stale.out"' \
  "K14: 追跡 ref を取得していなければ未反映を 0 件と言い切らず、未確認と書く" "$TMP/k14stale.out"
git fetch -q origin
lk 共有 >"$TMP/k14.out" 2>&1 || true
check 'grep -q "^RECORD ace=ACE-1-1 obs=OBS-001 unreflected=ACE-2-1,OBS-001,OBS-002$" "$TMP/k14.out" && grep -q "未反映=新規" "$TMP/k14.out" && grep -q "Count=2 Last=2026-11-07 未反映=更新" "$TMP/k14.out"' \
  "K14: 未反映の新規（ACE-2-1・OBS-002）と更新（OBS-001 の Count）を返す" "$TMP/k14.out"
lk --offline --format tsv 共有 >"$TMP/k14tsv.out" 2>&1 || true
check 'awk -F "\t" "\$1 == \"obs\" && \$2 == \"OBS-002\" && \$3 == \"unreflected\" { f = 1 } END { exit f ? 0 : 1 }" "$TMP/k14tsv.out" && grep -q "unreflected=ACE-2-1,OBS-001,OBS-002（未確認: --offline" "$TMP/k14tsv.out"' \
  "K14: TSV は状態列 unreflected で返し、--offline は remote と照合していないと書く" "$TMP/k14tsv.out"
lk 誰も書いていない語 >"$TMP/k14none.out" 2>&1 || true
check 'grep -q " unreflected=0 件$" "$TMP/k14none.out"' "K14: 一致が無ければ未反映 0 件" "$TMP/k14none.out"
printf 'mode=batch\nbogus=1\n' >docs/08-knowledge/knowledge-delivery.conf
git -c core.hooksPath=/dev/null commit -qam "chore: 壊れた設定" >/dev/null && git push -q origin develop && git fetch -q origin
RC=0; lk --offline 共有 >"$TMP/k14bad.out" 2>&1 || RC=$?
check '[ "$RC" -eq 0 ] && grep -q "unreflected=読み取り失敗（反映の設定が不正" "$TMP/k14bad.out"' "K14: 設定が壊れていても lookup は止めず、未反映を読めないと書く" "$TMP/k14bad.out"

# ── K15: マージごとへ戻した後も staging の残りを知らせ、flush で排出できる ─────
new_world "mode=batch"
cd "$W/a"; kc target >/dev/null 2>&1; write_obs a OBS-002 '戻す前の観測'; kc push >/dev/null 2>&1
( cd "$W/seed" && git pull -q origin develop && printf 'mode=per-merge\n' >docs/08-knowledge/knowledge-delivery.conf && git commit -qam "chore: マージごとへ戻す" && git push -q origin develop )
cd "$W/b" && git pull -q origin develop && git fetch -q origin
run "$TMP/k15t" kc target
check '[ "$RC" -eq 0 ] && grep -qx "KNOWLEDGE_DELIVERY=per-merge" "$TMP/k15t.out" && grep -q "未反映の知見が 1 コミット残っています" "$TMP/k15t.err"' \
  "K15: マージごとへ戻しても staging に未反映が残っていれば target が知らせる" "$TMP/k15t.err"
run "$TMP/k15f" kc flush
check '[ "$RC" -eq 0 ] && grep -qx "KNOWLEDGE_FLUSH=ok" "$TMP/k15f.out" && git -C "$W/origin.git" merge-base --is-ancestor knowledge/staging develop' \
  "K15: 設定がマージごとでも flush で staging の残りを base へ排出できる" "$TMP/k15f.err"

# ── K16: ACE の経路（--ace-playbook と .version-claims）をまとめるモードで通す ─────
new_world "mode=batch"
(
  cd "$W/seed" && git pull -q origin develop
  cat >docs/08-knowledge/PLAYBOOK.md <<'BOOK'
---
title: ACE Playbook
version: 1.0.0
status: draft
owner: fixture
created: 2026-11-01
updated: 2026-11-01
changeImpact: medium
ace_entry_count: 1
---

# ACE Playbook

## エントリ一覧

### ACE-1-1: 共有の索引エントリ

| Category | testing |
| Helpful | 0 |
| Status | active |

---

## Changelog

### [1.0.0] - 2026-11-01

#### 追加

- ACE-1-1: seed
BOOK
  mkdir -p .version-claims/docs/08-knowledge
  printf '# Version claim fixture\n' >.version-claims/README.md
  git add -A && git commit -qm "docs: playbook frontmatter" && git push -q origin develop
  FF_DEV_TOOLKIT_ROOT="$PLUGIN" bash "$PLUGIN/scripts/update-version-claim.sh" --base origin/develop --document docs/08-knowledge/PLAYBOOK.md >/dev/null 2>&1
  git add -A && git commit -qm "chore: claim seed" && git push -q origin develop
) >"$TMP/k16seed.log" 2>&1
bump_playbook() { # <新しい版> <Helpful>
  sed -e "s/^version: .*/version: $1/" -e "s/^| Helpful | [0-9]* |/| Helpful | $2 |/" docs/08-knowledge/PLAYBOOK.md >"$TMP/book.new" \
    && mv "$TMP/book.new" docs/08-knowledge/PLAYBOOK.md
}
cd "$W/a" && git pull -q origin develop
kc target >/dev/null 2>&1
bump_playbook 1.1.0 1
run "$TMP/k16a" kc add --ace-playbook docs/08-knowledge/PLAYBOOK.md --source ace --id ACE-1-1 --summary "Helpful +1"
check '[ "$RC" -eq 0 ] && grep -q "CLAIM_UPDATED=.version-claims/docs/08-knowledge/PLAYBOOK.md.claim" "$TMP/k16a.out"' \
  "K16: まとめるモードの add --ace-playbook は claim を再生成して検証を通す（起点 = develop の先端）" "$TMP/k16a.err"
kc commit >/dev/null 2>&1; run "$TMP/k16apush" kc push
git -C "$W/origin.git" show knowledge/staging --name-only --format= >"$TMP/k16apush.files" 2>&1 || true
check '[ "$RC" -eq 0 ] && grep -qx ".version-claims/docs/08-knowledge/PLAYBOOK.md.claim" "$TMP/k16apush.files"' \
  "K16: PLAYBOOK と claim が同じ知見コミットで staging へ届く" "$TMP/k16apush.err"
advance_develop app.txt 'feature k16'
cd "$W/b" && git pull -q origin develop
kc target >/dev/null 2>&1
check 'grep -q "^version: 1.1.0" docs/08-knowledge/PLAYBOOK.md && [ -n "$(git rev-parse -q --verify HEAD^2)" ]' "K16: 2 人目の起点（merge）は 1 人目の版を含む"
# K16b: 起点を決めた後に develop が進んでも、claim は起点を決めた時点の develop を基準に作って検証する
advance_develop app.txt 'feature k16b'
bump_playbook 1.2.0 2
run "$TMP/k16b" kc add --ace-playbook docs/08-knowledge/PLAYBOOK.md --source ace --id ACE-1-1 --summary "Helpful +1"
check '[ "$RC" -eq 0 ] && grep -q "CLAIM_UPDATED=" "$TMP/k16b.out"' \
  "K16b: 起点が merge で、その後に develop が進んでも add --ace-playbook の claim 検証が通る" "$TMP/k16b.err"
kc commit >/dev/null 2>&1; kc push >/dev/null 2>&1
D_PRE_FLUSH="$(origin_sha develop)"
run "$TMP/k16f" kc flush
FLUSH_SHA="$(sed -n 's/^KNOWLEDGE_FLUSHED_SHA=//p' "$TMP/k16f.out")"
# flush の merge commit そのものを、flush 前の develop を基準に検証する（差分の無い develop で回すと空振りする）
RC2=0
( cd "$W/seed" && git fetch -q origin && git switch -q --detach "$FLUSH_SHA" \
  && FF_DEV_TOOLKIT_ROOT="$PLUGIN" bash "$PLUGIN/scripts/check-version-claims.sh" --base-commit "$D_PRE_FLUSH" ) >"$TMP/k16claims.out" 2>&1 || RC2=$?
git -C "$W/origin.git" show "${FLUSH_SHA:-none}:docs/08-knowledge/PLAYBOOK.md" >"$TMP/k16book" 2>&1 || true
check '[ "$RC" -eq 0 ] && [ -n "$FLUSH_SHA" ] && grep -q "^version: 1.2.0" "$TMP/k16book" && [ "$RC2" -eq 0 ] && grep -q "一致しています" "$TMP/k16claims.out"' \
  "K16: flush の merge commit は 2 人分の版を持ち、flush 前の develop を基準にした version claim の照合が通る" "$TMP/k16claims.out"
# K16c: --base-commit は HEAD の祖先でない commit を基準にしない（判定不能で止まる）
RC2=0
( cd "$W/seed" && ORPHAN="$(git commit-tree "HEAD^{tree}" -m orphan)" \
  && FF_DEV_TOOLKIT_ROOT="$PLUGIN" bash "$PLUGIN/scripts/check-version-claims.sh" --base-commit "$ORPHAN" ) >"$TMP/k16c.out" 2>&1 || RC2=$?
check '[ "$RC2" -eq 2 ] && grep -q "祖先ではありません" "$TMP/k16c.out"' "K16c: check-version-claims --base-commit は HEAD の祖先でない commit を基準にせず止まる" "$TMP/k16c.out"
( cd "$W/seed" && git switch -q develop )

# ── K17: detached HEAD から始めた回は元の sha へ戻る ─────────────────────────
new_world "mode=batch"
cd "$W/a" && git switch -q --detach origin/develop
ORIG="$(git rev-parse HEAD)"
kc target >/dev/null 2>&1; write_obs a OBS-002 'detached からの観測'
run "$TMP/k17push" kc push
check '[ "$RC" -eq 0 ] && [ -z "$(git branch --show-current)" ] && [ "$(git rev-parse HEAD)" = "$ORIG" ] && grep -qx "KNOWLEDGE_RESTORE=$ORIG" "$TMP/k17push.out"' \
  "K17: detached HEAD から始めた push は、元の sha へ戻る（未反映の知見を載せた HEAD に残らない）" "$TMP/k17push.err"
( cd "$W/b" && kc target >/dev/null 2>&1 && set_count OBS-001 3 && kc add --source obs --id OBS-001 --summary "+1" -- docs/08-knowledge/OBSERVATIONS.md >/dev/null 2>&1 && kc commit >/dev/null 2>&1 && kc push >/dev/null 2>&1 )
( cd "$W/seed" && git pull -q origin develop && set_count OBS-001 9 && git commit -qam "docs: base 側の台帳変更" && git push -q origin develop )
cd "$W/a" && git fetch -q origin && git switch -q --detach origin/develop
ORIG="$(git rev-parse HEAD)"
run "$TMP/k17c" kc target
check '[ "$RC" -eq 1 ] && grep -qx "KNOWLEDGE_TARGET=conflict" "$TMP/k17c.out" && [ "$(git rev-parse HEAD)" = "$ORIG" ] && [ -z "$(git branch --show-current)" ]' \
  "K17: detached HEAD から始めた target が衝突で止まったら、元の sha へ戻る" "$TMP/k17c.err"
run "$TMP/k17f" kc flush
check '[ "$RC" -eq 1 ] && [ "$(git rev-parse HEAD)" = "$ORIG" ]' "K17: detached HEAD から始めた flush が止まったら、元の sha へ戻る" "$TMP/k17f.err"

# ── K18 / K19: staging に載せてよいのは知見の置き場だけ ─────────────────────
new_world "mode=batch"
cd "$W/a"; kc target >/dev/null 2>&1; write_obs a OBS-002 '正規の観測'; kc push >/dev/null 2>&1
( cd "$W/seed" && git fetch -q origin && git switch -q --detach origin/knowledge/staging && mkdir -p .githooks \
  && printf '#!/bin/sh\necho pwned\n' >.githooks/pre-commit && git add -A && git -c core.hooksPath=/dev/null commit -qm "chore: 知見以外" \
  && git push -q origin HEAD:knowledge/staging && git switch -q develop )
D_PRE="$(origin_sha develop)"
cd "$W/b" && git fetch -q origin
run "$TMP/k18t" kc target
check '[ "$RC" -eq 1 ] && grep -qx "KNOWLEDGE_TARGET=outside-knowledge" "$TMP/k18t.out" && grep -q ".githooks/pre-commit" "$TMP/k18t.err" && [ "$(git branch --show-current)" = develop ] && [ ! -e .githooks/pre-commit ]' \
  "K18: staging に知見の置き場以外の変更があれば、target は checkout せずに止まる" "$TMP/k18t.err"
run "$TMP/k18d" kc flush --dry-run
run "$TMP/k18f" kc flush
check '[ "$RC" -eq 1 ] && grep -qx "KNOWLEDGE_FLUSH=outside-knowledge" "$TMP/k18f.out" && grep -qx "KNOWLEDGE_FLUSH=outside-knowledge" "$TMP/k18d.out" && [ "$(origin_sha develop)" = "$D_PRE" ]' \
  "K18: 同じ staging の flush（--dry-run を含む）は base へ運ばずに止まる" "$TMP/k18f.err"
new_world "mode=batch"
cd "$W/a"; kc target >/dev/null 2>&1
echo changed >>app.txt; ENTRY_OBS OBS-002 'ついでの変更' >>docs/08-knowledge/OBSERVATIONS.md
kc add --source obs --id OBS-002 --summary x -- docs/08-knowledge/OBSERVATIONS.md app.txt >/dev/null 2>&1; kc commit >/dev/null 2>&1
run "$TMP/k19" kc push
check '[ "$RC" -eq 2 ] && grep -qx "KNOWLEDGE_PUSH=outside-knowledge" "$TMP/k19.out" && [ -z "$(origin_sha knowledge/staging)" ]' \
  "K19: 知見の置き場以外を含む知見コミットは staging へ送らない" "$TMP/k19.err"
kc discard >/dev/null 2>&1; git switch -q -f develop

# ── K20: 置き場の中でも通常ファイル以外（シンボリックリンク）は載せない ──────────
new_world "mode=batch"
cd "$W/a"; kc target >/dev/null 2>&1; write_obs a OBS-002 '正規の観測'; kc push >/dev/null 2>&1
( cd "$W/seed" && git fetch -q origin && git switch -q --detach origin/knowledge/staging \
  && ln -s ../../app.txt docs/08-knowledge/link.md && git add -A && git -c core.hooksPath=/dev/null commit -qm "knowledge: リンク" \
  && git push -q origin HEAD:knowledge/staging && git switch -q develop )
cd "$W/b" && git fetch -q origin
run "$TMP/k20t" kc target
run "$TMP/k20f" kc flush
check '[ "$RC" -eq 1 ] && grep -qx "KNOWLEDGE_FLUSH=outside-knowledge" "$TMP/k20f.out" && grep -q "mode 120000" "$TMP/k20t.err" && grep -qx "KNOWLEDGE_TARGET=outside-knowledge" "$TMP/k20t.out" && [ "$(git branch --show-current)" = develop ]' \
  "K20: 置き場の中のシンボリックリンクも範囲外として target / flush が止まる" "$TMP/k20t.err"

# ── K21: develop と staging の共通の祖先が複数ある（criss-cross）と判定不能として止まる ─────
new_world "mode=batch"
(
  cd "$W/seed" && git pull -q origin develop
  D0="$(git rev-parse HEAD)"
  git switch -q --detach "$D0" && ENTRY_OBS OBS-002 'criss-cross' >>docs/08-knowledge/OBSERVATIONS.md \
    && git -c core.hooksPath=/dev/null commit -qam "knowledge: OBS-002" && S1="$(git rev-parse HEAD)"
  git switch -q develop && echo d1 >>app.txt && git commit -qam "feat: d1" && D1="$(git rev-parse HEAD)"
  git switch -q --detach "$S1" && git merge -q --no-ff -m "Merge d1 into staging" "$D1" && git push -q origin HEAD:refs/heads/knowledge/staging
  git switch -q develop && git merge -q --no-ff -m "Merge s1 into develop" "$S1" && git push -q origin develop
) >"$TMP/k21seed.log" 2>&1
cd "$W/b" && git pull -q origin develop && git fetch -q origin
run "$TMP/k21t" kc target
T_RC="$RC"
kc discard >/dev/null 2>&1; git switch -q develop 2>/dev/null
run "$TMP/k21f" kc flush
check '[ "$T_RC" -eq 0 ] && grep -qx "KNOWLEDGE_DELIVERY=batch" "$TMP/k21t.out" && [ "$RC" -eq 0 ] && grep -qx "KNOWLEDGE_FLUSH=ok" "$TMP/k21f.out" && git -C "$W/origin.git" merge-base --is-ancestor knowledge/staging develop' \
  "K21: 共通の祖先が複数ある（criss-cross）ときも、git が作るツリーを検査して target / flush が通る" "$TMP/k21t.err"

# ── K22: merge が知見の変更を置き場の外へ運ぶ（develop 側が台帳を rename）と止まる ─────
# staging 側の差分（置き場の中）だけを見る事前の検査は通るが、rename 検出が更新を置き場の外のファイルへ
# 運ぶので、実際に作ったツリーの検査（target の起点 / flush の merge）だけがこの形を止められる
new_world "mode=batch"
cd "$W/a"; kc target >/dev/null 2>&1; set_count OBS-001 2
kc add --source obs --id OBS-001 --summary "+1" -- docs/08-knowledge/OBSERVATIONS.md >/dev/null 2>&1; kc commit >/dev/null 2>&1; kc push >/dev/null 2>&1
( cd "$W/seed" && git pull -q origin develop && mkdir -p docs/ledger && git mv docs/08-knowledge/OBSERVATIONS.md docs/ledger/OBSERVATIONS.md \
  && git commit -qm "docs: 台帳を移す" && git push -q origin develop ) >"$TMP/k22seed.log" 2>&1
D_PRE="$(origin_sha develop)"
cd "$W/b" && git pull -q origin develop && git fetch -q origin
run "$TMP/k22t" kc target
T_RC="$RC"
run "$TMP/k22f" kc flush
check '[ "$T_RC" -eq 1 ] && grep -qx "KNOWLEDGE_TARGET=outside-knowledge" "$TMP/k22t.out" && [ "$RC" -eq 1 ] && grep -qx "KNOWLEDGE_FLUSH=outside-knowledge" "$TMP/k22f.out" && grep -q "docs/ledger/OBSERVATIONS.md" "$TMP/k22f.err" && [ "$(origin_sha develop)" = "$D_PRE" ] && [ "$(git branch --show-current)" = develop ] && [ ! -e "$(git rev-parse --absolute-git-dir)/ff-knowledge-target" ]' \
  "K22: merge が知見の変更を置き場の外へ運ぶと、target / flush は実際のツリーの検査で止まる" "$TMP/k22f.err"

# ── K23: 書き込み中（起点が merge）に別のセッションが flush しても、その後の target / flush が通る ─────
# flush（develop = merge(D1, S1)）と書き込み（staging = merge(S1, D1) の上の知見）が重なると、共通の祖先が
# S1 と D1 の 2 つになる（criss-cross）。合わせたツリーで検査するので、これで詰まらない
new_world "mode=batch"
cd "$W/a"; kc target >/dev/null 2>&1; write_obs a OBS-002 'A の観測'; kc push >/dev/null 2>&1
advance_develop app.txt 'k23 d1'
cd "$W/b" && git pull -q origin develop
run "$TMP/k23bt" kc target
B_MERGE_START=0; [ -n "$(git rev-parse -q --verify HEAD^2)" ] && B_MERGE_START=1
( cd "$W/a" && git pull -q origin develop && kc flush >"$TMP/k23af.out" 2>&1 )
cd "$W/b"; write_obs b OBS-003 'B が書き込み中に flush された観測'
run "$TMP/k23bpush" kc push
B_PUSH_RC="$RC"
cd "$W/a" && git pull -q origin develop
run "$TMP/k23at" kc target
T_RC="$RC"
kc discard >/dev/null 2>&1; git switch -q develop 2>/dev/null
run "$TMP/k23af2" kc flush
git -C "$W/origin.git" show develop:docs/08-knowledge/OBSERVATIONS.md >"$TMP/k23obs" 2>&1 || true
check '[ "$B_MERGE_START" -eq 1 ] && grep -qx "KNOWLEDGE_FLUSH=ok" "$TMP/k23af.out" && [ "$B_PUSH_RC" -eq 0 ] && [ "$T_RC" -eq 0 ] && [ "$RC" -eq 0 ] && grep -qx "KNOWLEDGE_FLUSH=ok" "$TMP/k23af2.out" && grep -q "^### OBS-003:" "$TMP/k23obs" && git -C "$W/origin.git" merge-base --is-ancestor knowledge/staging develop' \
  "K23: 書き込み中に flush が入っても、その後の push・target・flush が通り、知見は base へ届く" "$TMP/k23at.err"

# ── K24 / K25: target の再入（probe の後）と、追記 0 件の push ─────────────────
new_world "mode=batch"
cd "$W/a"
run "$TMP/k24p" kc probe
START24="$(sed -n 's/^KNOWLEDGE_START=//p' "$TMP/k24p.out")"
printf '\n### ACE-2-1: 共有の新しい手順\n| Category | testing |\n| Status | active |\n| Helpful | 0 |\n\n---\n' >>docs/08-knowledge/playbook/testing.md
kc add --source ace --id ACE-2-1 --summary "手順" -- docs/08-knowledge/playbook/testing.md >/dev/null 2>&1
run "$TMP/k24re" kc target
check '[ "$RC" -eq 0 ] && grep -qx "KNOWLEDGE_TARGET_FRESH=ok" "$TMP/k24re.out" && grep -qx "KNOWLEDGE_START=$START24" "$TMP/k24re.out" && [ "$(git rev-parse HEAD)" = "$START24" ] && [ -n "$(git diff --cached --name-only)" ]' \
  "K24: probe の後の target（再入）は移らず、ACE の stage を残したまま KNOWLEDGE_TARGET_FRESH=ok を返す" "$TMP/k24re.err"
ENTRY_OBS OBS-002 '再入の後の観測' >>docs/08-knowledge/OBSERVATIONS.md
kc add --source obs --id OBS-002 --summary "観測" -- docs/08-knowledge/OBSERVATIONS.md >/dev/null 2>&1; kc commit >/dev/null 2>&1
run "$TMP/k24push" kc push
git -C "$W/origin.git" log -1 --format=%s knowledge/staging >"$TMP/k24subject" 2>&1 || true
check '[ "$RC" -eq 0 ] && grep -q "ACE-2-1 / OBS-002" "$TMP/k24subject"' "K24: ACE と観測は 1 コミットに畳まれて staging へ届く" "$TMP/k24push.err"
S24="$(origin_sha knowledge/staging)"
kc target >/dev/null 2>&1
run "$TMP/k25" kc push
check '[ "$RC" -eq 0 ] && grep -qx "KNOWLEDGE_PUSH=nothing" "$TMP/k25.out" && [ "$(git branch --show-current)" = develop ] && [ ! -e "$(git rev-parse --absolute-git-dir)/ff-knowledge-target" ] && [ "$(origin_sha knowledge/staging)" = "$S24" ]' \
  "K25: 追記が 0 件の回の push は何も送らず、元のブランチへ戻って記録を消す" "$TMP/k25.err"

# ── K26: 閾値（既定 7 日）に達していなければ警告しない ─────────────────────────
new_world "mode=batch"
cd "$W/a"; kc target >/dev/null 2>&1
ENTRY_OBS OBS-002 '5 日前の観測' >>docs/08-knowledge/OBSERVATIONS.md
kc add --source obs --id OBS-002 --summary old -- docs/08-knowledge/OBSERVATIONS.md >/dev/null 2>&1
OLD="$(( $(date +%s) - 5 * 86400 ))"
GIT_COMMITTER_DATE="@$OLD +0000" GIT_AUTHOR_DATE="@$OLD +0000" kc commit >/dev/null 2>&1
kc push >/dev/null 2>&1
cd "$W/b"
run "$TMP/k26" kc target
check '[ "$RC" -eq 0 ] && grep -qx "KNOWLEDGE_UNREFLECTED_DAYS=5" "$TMP/k26.out" && ! grep -q "溜まっています" "$TMP/k26.err"' \
  "K26: 未反映の最古が既定の閾値（7 日）未満なら警告しない" "$TMP/k26.err"
kc discard >/dev/null 2>&1; git switch -q develop

# ── K27: merge-tree --write-tree を使えない git では、版を名指しして止まる ─────────
new_world "mode=batch"
cd "$W/a"; kc target >/dev/null 2>&1; write_obs a OBS-002 'A の観測'; kc push >/dev/null 2>&1
advance_develop app.txt 'k27'
REAL_GIT="$(command -v git)"
mkdir -p "$TMP/oldgit"
printf '#!/bin/sh\nif [ "$1" = merge-tree ]; then echo "error: unknown option write-tree" >&2; exit 129; fi\nexec "%s" "$@"\n' "$REAL_GIT" >"$TMP/oldgit/git"
chmod +x "$TMP/oldgit/git"
cd "$W/b" && git pull -q origin develop
B_HEAD="$(git rev-parse HEAD)"
RC=0; PATH="$TMP/oldgit:$PATH" FF_DEV_TOOLKIT_ROOT="$PLUGIN" bash "$FIN" knowledge-commit target >"$TMP/k27.out" 2>"$TMP/k27.err" || RC=$?
check '[ "$RC" -eq 2 ] && grep -qx "KNOWLEDGE_TARGET=merge-failed" "$TMP/k27.out" && grep -q "2.38" "$TMP/k27.err" && [ "$(git rev-parse HEAD)" = "$B_HEAD" ] && [ "$(git branch --show-current)" = develop ]' \
  "K27: merge-tree --write-tree を使えない git では、起点へ移らずに版を名指しして止まる" "$TMP/k27.err"

# ── K28: 反映の設定ファイル自身は staging に載せない ────────────────────────────
new_world "mode=batch"
cd "$W/a"; kc target >/dev/null 2>&1; write_obs a OBS-002 'A の観測'; kc push >/dev/null 2>&1
( cd "$W/seed" && git fetch -q origin && git switch -q --detach origin/knowledge/staging \
  && printf 'warn_after_days=30\n' >>docs/08-knowledge/knowledge-delivery.conf && git -c core.hooksPath=/dev/null commit -qam "knowledge: 設定" \
  && git push -q origin HEAD:knowledge/staging && git switch -q develop )
cd "$W/b" && git fetch -q origin
run "$TMP/k28" kc target
check '[ "$RC" -eq 1 ] && grep -qx "KNOWLEDGE_TARGET=outside-knowledge" "$TMP/k28.out" && grep -q "knowledge-delivery.conf" "$TMP/k28.err"' \
  "K28: staging で反映の設定を書き換えた変更は、置き場の中でも範囲外として止まる" "$TMP/k28.err"

# ── K29: lookup は staging 側で変わったものだけを未反映と呼び、作業ツリーに設定が無い枝でも引く ─────
new_world ""
( cd "$W/b" && git switch -q -c feature/old )
( cd "$W/seed" && git pull -q origin develop && printf 'mode=batch\n' >docs/08-knowledge/knowledge-delivery.conf && git add -A && git commit -qm "chore: batch" && git push -q origin develop )
cd "$W/a" && git pull -q origin develop
kc target >/dev/null 2>&1; write_obs a OBS-002 '共有の新しい観測'; kc push >/dev/null 2>&1
( cd "$W/seed" && git pull -q origin develop && set_count OBS-001 5 && git commit -qam "docs: base 側だけの Count 変更" && git push -q origin develop )
cd "$W/b" && git fetch -q origin
lk 共有 >"$TMP/k29.out" 2>&1 || true
check '[ ! -e docs/08-knowledge/knowledge-delivery.conf ] && grep -q "^RECORD ace=ACE-1-1 obs=OBS-001 unreflected=OBS-002$" "$TMP/k29.out"' \
  "K29: 作業ツリーに設定が無い枝でも未反映を引き、base 側だけで変わった OBS-001 は未反映に数えない" "$TMP/k29.out"
git switch -q develop && git pull -q origin develop
lk 共有 >"$TMP/k29b.out" 2>&1 || true
check 'grep -q "^| Count | 5 |" docs/08-knowledge/OBSERVATIONS.md && grep -q "^RECORD ace=ACE-1-1 obs=OBS-001 unreflected=OBS-002$" "$TMP/k29b.out"' \
  "K29: 手元が base 側の変更（Count 5）を持っていても、staging が変えていない OBS-001 を未反映=更新と呼ばない" "$TMP/k29b.out"

# ── K33: lookup は default の追跡 ref の古さも見る（別のセッションの flush の後） ─────────────
new_world "mode=batch"
cd "$W/a"; kc target >/dev/null 2>&1; write_obs a OBS-002 '共有の観測 K33'; kc push >/dev/null 2>&1
cd "$W/b" && git fetch -q origin
( cd "$W/a" && kc flush >"$TMP/k33f.out" 2>&1 )
lk 共有 >"$TMP/k33.out" 2>&1 || true
check 'grep -qx "KNOWLEDGE_FLUSH=ok" "$TMP/k33f.out" && grep -q " unreflected=OBS-002（未確認: 手元の追跡 ref が remote と違う（develop）" "$TMP/k33.out" && grep -q "unreflected_state=stale" "$TMP/k33.out"' \
  "K33: staging は新しく default だけが古い（flush 済み）とき、反映済みの OBS-002 を未反映と言い切らず未確認と書く" "$TMP/k33.out"
git fetch -q origin
lk 共有 >"$TMP/k33b.out" 2>&1 || true
check 'grep -q " unreflected=0 件$" "$TMP/k33b.out"' "K33: default を取得した後は、反映済みの OBS-002 を未反映に数えない" "$TMP/k33b.out"

# ── K34: 共通の祖先が複数（flush と書き込みの criss-cross）でも、staging が変えていない知見を未反映と呼ばない ─────
# develop = merge(D1, S1)（A の flush）と staging = merge(D1, S1)' + OBS-003（B の書き込み）の共通の祖先は D1 と
# S1 の 2 つ。その後 base 側だけで OBS-002 の Count を変えるので、D1 だけと比べると OBS-002 を「新規」と誤る
new_world "mode=batch"
cd "$W/a"; kc target >/dev/null 2>&1; write_obs a OBS-002 '共有の観測 K34'; kc push >/dev/null 2>&1
advance_develop app.txt 'k34 d1'
cd "$W/b" && git pull -q origin develop && kc target >/dev/null 2>&1
( cd "$W/a" && git pull -q origin develop && kc flush >"$TMP/k34f.out" 2>&1 )
cd "$W/b"; write_obs b OBS-003 '共有の観測 K34 B'; kc push >/dev/null 2>&1
( cd "$W/seed" && git pull -q origin develop && set_count OBS-002 7 && git commit -qam "docs: base 側だけの Count 変更" && git push -q origin develop )
cd "$W/b" && git pull -q origin develop && git fetch -q origin
K34_BASES="$(git merge-base --all origin/develop origin/knowledge/staging | awk 'END { print NR }')"
lk 共有 >"$TMP/k34.out" 2>&1 || true
check '[ "$K34_BASES" -eq 2 ] && grep -q " unreflected=OBS-003$" "$TMP/k34.out"' \
  "K34: 共通の祖先が 2 つでも、未反映は B の OBS-003 だけで、staging が変えていない OBS-002 を返さない" "$TMP/k34.out"

# ── K35: flush の PR が squash で入った（staging のコミットが base の祖先にならない）回も、反映済みと扱う ─────
new_world "mode=batch"
cd "$W/a"; kc target >/dev/null 2>&1; write_obs a OBS-002 '共有の観測 K35'; kc push >/dev/null 2>&1
( cd "$W/seed" && git pull -q origin develop && git fetch -q origin \
  && git checkout -q origin/knowledge/staging -- docs/08-knowledge/OBSERVATIONS.md \
  && git -c core.hooksPath=/dev/null commit -qm "knowledge: squash で入った flush" && git push -q origin develop )
cd "$W/b" && git pull -q origin develop && git fetch -q origin
lk 共有 >"$TMP/k35.out" 2>&1 || true
check '! git merge-base --is-ancestor origin/knowledge/staging origin/develop && grep -q " unreflected=0 件$" "$TMP/k35.out"' \
  "K35: base の先端に同じ本文がある OBS-002 は、staging のコミットが base の祖先でなくても未反映に数えない" "$TMP/k35.out"

# ── K32: pr は fetch した後の設定で止める（手元の追跡 ref が古いまま batch に切り替わった回） ─────
new_world ""
cd "$W/a" && git switch -q -c chore/ace-from-pr-1
ENTRY_OBS OBS-002 'PR 経路の観測' >>docs/08-knowledge/OBSERVATIONS.md
git -c core.hooksPath=/dev/null commit -qam "knowledge: OBS-002"
( cd "$W/seed" && git pull -q origin develop && printf 'mode=batch\n' >docs/08-knowledge/knowledge-delivery.conf && git add -A && git commit -qm "chore: batch" && git push -q origin develop )
: >"$KD_GH_LOG"
run "$TMP/k32" kc pr --branch chore/ace-from-pr-1 --title "knowledge: OBS-002"
check '[ "$RC" -eq 1 ] && grep -q "まとめるモード" "$TMP/k32.err" && [ -z "$(origin_sha chore/ace-from-pr-1)" ] && [ ! -s "$KD_GH_LOG" ]' \
  "K32: 追跡 ref が古くても、pr は fetch した後の設定（batch）を読んで知見 PR を作らない" "$TMP/k32.err"

# ── K30 / K31: 保護による拒否と、壊れた書き込み先の記録 ─────────────────────────
new_world "mode=batch"
cd "$W/a"; kc target >/dev/null 2>&1; write_obs a OBS-002 'A の観測'; kc push >/dev/null 2>&1
printf '#!/bin/sh\nwhile read old new ref; do\n  if [ "$ref" = refs/heads/develop ]; then echo "GH006: Protected branch update failed for refs/heads/develop." >&2; exit 1; fi\ndone\nexit 0\n' >"$W/origin.git/hooks/pre-receive"
chmod +x "$W/origin.git/hooks/pre-receive"
D_PRE="$(origin_sha develop)"
cd "$W/b"
run "$TMP/k30" kc flush
check '[ "$RC" -eq 3 ] && grep -qx "KNOWLEDGE_FLUSH=protected" "$TMP/k30.out" && grep -q "flush --pr" "$TMP/k30.err" && [ "$(origin_sha develop)" = "$D_PRE" ] && [ "$(git branch --show-current)" = develop ]' \
  "K30: base が保護されていれば flush は exit 3 で止まり、--pr を案内する" "$TMP/k30.err"
rm -f "$W/origin.git/hooks/pre-receive"
printf 'mode=batch\nbogus=1\n' >"$(git rev-parse --absolute-git-dir)/ff-knowledge-target"
run "$TMP/k31t" kc target
T_RC="$RC"
run "$TMP/k31s" kc status
check '[ "$T_RC" -eq 2 ] && [ "$RC" -eq 2 ] && [ "$(git branch --show-current)" = develop ]' \
  "K31: 書き込み先の記録が壊れていれば、target と status は判定不能で止まる" "$TMP/k31t.err"
rm -f "$(git rev-parse --absolute-git-dir)/ff-knowledge-target"

FINISHED=1
printf '\n結果: pass=%s fail=%s\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then printf '❌ knowledge-delivery: %s 件失敗\n' "$FAIL"; exit 1; fi
printf '✅ knowledge-delivery: all checks passed\n'
