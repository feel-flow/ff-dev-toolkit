#!/usr/bin/env bash
#
# 同梱resourceを使うskillのplugin root固定契約（Issue #838）。
# 読み込み元のrootを実行中の正本にし、消失時に旧版へfallbackしないことを固定する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILLS_DIR="$PLUGIN_ROOT/skills"

[ -d "$SKILLS_DIR" ] || { echo "✗ skillsが見つかりません: $SKILLS_DIR" >&2; exit 1; }

# 検査対象 skill の下限。実体からの導出（固定値を書き写さない）は維持しつつ、
# 名簿そのものが崩れる退行だけを弾くための床。契約を適用する skill を減らす場合は
# ここも同時に下げること（下げずに減らすと赤くなる = 意図の宣言を要求する）。
MIN_SKILLS=14
SCANNED_COUNT=0

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

check_tree() {
  local skills_dir="$1"
  local file name required count=0 tree_fail=0 canonical="" block="" starts ends

  for file in "$skills_dir"/*/SKILL.md; do
    [ -f "$file" ] || continue
    if ! grep -Fq 'FF_DEV_TOOLKIT_ROOT' "$file" &&
       ! grep -Fq '${CLAUDE_PLUGIN_ROOT}' "$file"; then
      continue
    fi
    count=$((count + 1))
    name="$(basename "$(dirname "$file")")"

    starts="$(grep -Fc '<!-- ff-dev-toolkit-plugin-root-contract:start -->' "$file" || true)"
    ends="$(grep -Fc '<!-- ff-dev-toolkit-plugin-root-contract:end -->' "$file" || true)"
    if [ "$starts" -ne 1 ] || [ "$ends" -ne 1 ]; then
      echo "$name: root契約markerはstart/end各1件が必要です" >&2
      tree_fail=1
      continue
    fi

    block="$(sed -n '/<!-- ff-dev-toolkit-plugin-root-contract:start -->/,/<!-- ff-dev-toolkit-plugin-root-contract:end -->/p' "$file")"
    if [ -z "$canonical" ]; then
      canonical="$block"
    elif [ "$block" != "$canonical" ]; then
      echo "$name: root契約blockが他skillと一致しません" >&2
      tree_fail=1
    fi

    for required in \
      'FF_DEV_TOOLKIT_ROOT` を**一度だけ**解決し、実行中は変更しない' \
      '実際に読み込んだこの `SKILL.md` の絶対パス' \
      '`FF_DEV_TOOLKIT_SKILL_FILE` として固定' \
      'skill loaderが返した実値で `FF_DEV_TOOLKIT_SKILL_FILE="<このSKILL.mdの絶対パス>"; export FF_DEV_TOOLKIT_SKILL_FILE` を実行' \
      '読み込んだこの `SKILL.md` のdirectoryを基準にした [plugin root固定契約](../../docs-template/05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite)' \
      'consumerへコピーされた `docs/` や物理CWDを基準に解決しない' \
      'review系resource（`setup-multi-agent.sh` / `multi-agent.sh` / `multi-review.sh`）を直接呼ぶhostだけが、同節のresolver + guard fence全体を読み' \
      'handoff設定・guard・resource呼び出しを同じshell script bodyで実行' \
      'review以外のresourceはこのreview専用guardを実行せず' \
      'cache / marketplace / 旧インストール領域を走査して選ばない' \
      'version sortによる版の選び直しや、sidecarを使った別実体への切替も行わない' \
      '別versionへfallbackせず' \
      'ff-dev-toolkit更新後にこのskillを再呼び出してください'; do
      case "$block" in
        *"$required"*) ;;
        *)
          echo "$name: root契約の必須句がありません: $required" >&2
          tree_fail=1
          ;;
      esac
    done

    # 退行の検出は散文の表層照合であり意味解析ではない。言い換えを網羅はできないので、
    # 実際に起こりうる書き方（探す / 検索する / 列挙して新しい方を使う 等）まで広げる。
    #
    # 否定形の扱い: 日本語の否定は動詞の語幹ごと変わる（選ぶ→選ばない / 使う→使わない）
    # ため、肯定形だけを並べれば単純な否定文は自動的に外れる。行全体を「ない」で弾いては
    # ならない — 「見つからない場合は…列挙して新しい方を使う」のような、否定語を含む
    # **退行そのもの**まで取りこぼす（実測でこの形を見逃した）。除外するのは動詞の直後に
    # 付く文末否定（「選ぶことはしない」等）だけに限る。これを外すと、契約が遵守を述べる
    # 文で赤くなり、常時赤いゲートとして無視されるようになる。
    if grep -Eo '(走査|探索|検索|列挙)し[^。]*(選ぶ|選択する|使う|利用する)[^。]*|(cache|marketplace|旧インストール領域)(から|を)[^。]*(探す|拾う)[^。]*' "$file" \
       | grep -Evq '(ことは|のは|べきでは)?(しない|ない|禁止|避ける)' ; then
      echo "$name: インストール領域を再探索して選ぶ退行があります" >&2
      tree_fail=1
    fi
    if grep -Eo '(fallback|フォールバック)(する|して)[^。]*|(旧|別|他の)(version|バージョン)を(使う|使用する|選ぶ)[^。]*' "$file" \
       | grep -Evq '(ことは|のは|べきでは)?(しない|ない|禁止|避ける)' ; then
      echo "$name: 別versionへfallbackする退行があります" >&2
      tree_fail=1
    fi
  done

  # 名簿の下限。0 件だけを弾く形では、root 変数の参照が 1 つしかない skill が
  # refactor で名簿から静かに落ちても検出できない（14 → 1 まで崩れても緑）。
  # 実体から導出する方針は維持したまま（固定値へ書き写さない）、崩壊だけを弾く。
  if [ "$count" -lt "$MIN_SKILLS" ]; then
    echo "resource参照skillの検査対象が ${count} 件です（下限 ${MIN_SKILLS} 件を下回りました — 導出の空振り、または契約の適用漏れ）" >&2
    return 1
  fi
  SCANNED_COUNT="$count"
  [ "$tree_fail" -eq 0 ]
}

echo "== Plugin root固定契約検査 =="

# 環境ゲートは live 検査より**前**に置く。後ろに置くと、live の契約違反を検出して
# FAIL を立てた後に mktemp 失敗の `exit 0` が最終ゲートを飛び越え、違反が黙殺される
# （実測）。さらに `○ skip` は run-all.sh が行頭で拾う suite 単位のマーカーなので、
# 実際に走った live 検査の結果まで報告から消える（同 run-all.sh 冒頭が禁じる「部分 skip」）。
if _tmp_out="$(mktemp -d 2>&1)" && [ -d "$_tmp_out" ]; then
  TMP="$_tmp_out"
else
  echo "○ skip: 一時ディレクトリを作成できないためスキップ（本 suite の検査は1件も実行されていません）"
  printf '  mktemp: %s\n' "$_tmp_out"
  FF_REACHED_END=1
  exit 0
fi
if ! command -v perl >/dev/null 2>&1; then
  echo "○ skip: perl が無いためスキップ（negative control の変異注入に必要。本 suite の検査は1件も実行されていません）"
  rm -rf "$TMP"
  FF_REACHED_END=1
  exit 0
fi

# 途中死を沈黙させない。`set -u` 等で死んだときトラップ突入時の $? は 0 になるため、
# 終了ステータスを保存し直すだけでは足りない（merge-cleanup/verify.sh の実測コメント参照）。
FF_REACHED_END=0
cleanup() {
  local rc=$?
  trap - EXIT
  rm -rf "$TMP"
  if [ "$rc" -eq 0 ] && [ "${FF_REACHED_END:-0}" -ne 1 ]; then
    echo "✗ plugin-root-contract verify: 最後まで到達せずに終了しました（rc=0 だが中断）" >&2
    exit 1
  fi
  exit "$rc"
}
trap cleanup EXIT

if check_tree "$SKILLS_DIR"; then
  ok "liveのresource参照skillは同一のroot固定・fail-closed契約を持つ"
else
  bad "liveのroot固定契約に違反があります"
fi

make_fixture() {
  local dest="$1"
  mkdir -p "$dest"
  cp -R "$SKILLS_DIR"/. "$dest"/
}

# baseline（緑側）を先に固定する。check_tree は census が 0 件でも非 0 を返すため、
# 「cp -R が落ちた」「glob がずれた」等で空になっても negative control は全て
# 「✓ 拒否する」を出し、何も検出していないまま 全件 pass になりうる。
make_fixture "$TMP/baseline"
if check_tree "$TMP/baseline" >/dev/null 2>&1; then
  ok "positive control: 無変異のfixtureは契約を満たす（negative controlの非0が変異由来だと言える）"
else
  bad "positive control: 無変異のfixtureが落ちました（以降の negative control は根拠になりません）"
fi

make_fixture "$TMP/missing-marker"
perl -0pi -e 's/<!-- ff-dev-toolkit-plugin-root-contract:start -->//' \
  "$TMP/missing-marker/ace-curate/SKILL.md"
if check_tree "$TMP/missing-marker" >/dev/null 2>&1; then
  bad "negative control: 契約marker欠落を見逃しました"
else
  ok "negative control: 契約marker欠落を拒否する"
fi

make_fixture "$TMP/cache-search"
printf '\nrootが見つからない場合はバージョン別ディレクトリを列挙して新しい方を使う。\n' >> "$TMP/cache-search/ace-curate/SKILL.md"
if check_tree "$TMP/cache-search" >/dev/null 2>&1; then
  bad "negative control: cache再探索を見逃しました"
else
  ok "negative control: cache再探索を拒否する"
fi

make_fixture "$TMP/version-fallback"
printf '\n失敗時は直前の旧バージョンを使う。\n' >> "$TMP/version-fallback/ace-curate/SKILL.md"
if check_tree "$TMP/version-fallback" >/dev/null 2>&1; then
  bad "negative control: 別version fallbackを見逃しました"
else
  ok "negative control: 別version fallbackを拒否する"
fi

# 契約の「内容」を見る検出器（必須句・canonical一致）は、marker検査で continue する
# missing-marker fixture には到達しない。個別に固定する（AC「契約欠落・cache再探索・
# 別version fallbackを個別に検出して失敗する」の 1 番目は必須句の検出器が担う）。
make_fixture "$TMP/missing-phrase"
perl -0pi -e 's/実行中は変更しない/実行中に更新してよい/' \
  "$TMP/missing-phrase/ace-curate/SKILL.md"
if check_tree "$TMP/missing-phrase" >/dev/null 2>&1; then
  bad "negative control: 必須句の欠落を見逃しました"
else
  ok "negative control: 契約の必須句が欠けたら拒否する"
fi

# canonical 一致の検出器は「先頭 skill 以外」を変えないと発火しない（先頭が canonical
# の出所になるため）。alphabetical 先頭の ace-curate ではなく merge-cleanup を変異させる。
make_fixture "$TMP/diverged-block"
perl -0pi -e 's/cache \/ marketplace \/ 旧インストール領域を走査して選ばない。/cache や marketplace も参照してよい。/' \
  "$TMP/diverged-block/merge-cleanup/SKILL.md"
if check_tree "$TMP/diverged-block" >/dev/null 2>&1; then
  bad "negative control: 契約blockのskill間diverge を見逃しました"
else
  ok "negative control: 一部skillだけ契約blockが異なれば拒否する"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ plugin-root-contract verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ plugin-root-contract verify: 全 ${PASS} 件 pass"
FF_REACHED_END=1
