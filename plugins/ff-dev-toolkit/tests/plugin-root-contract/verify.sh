#!/usr/bin/env bash
#
# 同梱resourceを使うskillのplugin root固定契約（Issue #838）。
# 読み込み元のrootを実行中の正本にし、消失時に旧版へfallbackしないことを固定する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILLS_DIR="$PLUGIN_ROOT/skills"

[ -d "$SKILLS_DIR" ] || { echo "✗ skillsが見つかりません: $SKILLS_DIR" >&2; exit 1; }

# 契約対象外とする skill の明示 allowlist（`skill名|理由` の形式）。母集団から黙って
# 外れる形を作らないため、除外は必ず理由付きでここへ書き、報告にも出す（Issue #860）。
# 空でよい。
CONTRACT_EXEMPT=()

# 実行時rootガード（Issue #861）の対象外にする skill（`skill名|理由` の形式）。
# review系resource（`setup-multi-agent.sh` / `multi-agent.sh` / `multi-review.sh`）を
# 直接呼ぶhostは、正本のresolver + guard fence全体を同じshell script bodyで実行する。
# 軽量ガードは `FF_DEV_TOOLKIT_ROOT` が**既に解決済み**であることを前提に body 冒頭で
# 走るので、rootをこれから解決するresolverの前に置くと、正規のhandoffでも status 2 で
# 止まってresource呼び出しへ到達できない。除外は黙って落とさず理由付きでここへ書き、
# 報告にも出す。
GUARD_EXEMPT=(
  "multi-review|正本のresolver + guard fenceが同じ停止（status 2）を担う"
  "multi-explore|正本のresolver + guard fenceが同じ停止（status 2）を担う"
  "multi-implement|正本のresolver + guard fenceが同じ停止（status 2）を担う"
  "setup-ai-config|review系の setup-multi-agent.sh を直接呼ぶ側で、rootは同節のresolverが解決する"
)

# 崩壊床（絶対下限）。母集団は「入力側の名簿の本数」なので、同じ入力から導いた量
# （root 変数の件数など）を床にしても部分集合を自分自身と比べるだけで崩壊を検出できない
# （実測: skills を 1 件へ削った tree が緑のまま通った）。名簿が丸ごと縮む変異を赤に
# するには、入力から独立した絶対値が要る。値は現時点で契約 fence を持つ skill の実数。
# fence 付き skill を減らす変更（skill の統合・撤去）は、意図的ならこの値も同時に下げる。
MIN_SKILLS=23

# 実行時ガードを持つ skill の絶対下限。MIN_SKILLS と同じ理由で、母集団から導いた量
# （母集団 - 除外数）を床にしても崩壊を検出できない。値は現時点でガードを持つ skill の
# 実数（母集団のうち GUARD_EXEMPT に載らないもの）。
MIN_GUARD_SKILLS=19

SCANNED_COUNT=0

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

exempt_reason() {
  local name="$1" entry
  [ "${#CONTRACT_EXEMPT[@]}" -gt 0 ] || return 0
  for entry in "${CONTRACT_EXEMPT[@]}"; do
    case "$entry" in
      "$name"'|'*) printf '%s' "${entry#*|}"; return 0 ;;
    esac
  done
  return 0
}

guard_exempt_reason() {
  local name="$1" entry
  [ "${#GUARD_EXEMPT[@]}" -gt 0 ] || return 0
  for entry in "${GUARD_EXEMPT[@]}"; do
    case "$entry" in
      "$name"'|'*) printf '%s' "${entry#*|}"; return 0 ;;
    esac
  done
  return 0
}

# 母集団の導出キー。root 変数の出現だけを見ると、同梱 resource を**別の綴りで**参照する
# skill が構造的に不可視になる（Issue #860。実測: harness-review は `references/` を
# 相対パスで、create-issue / assess-impact は `docs-template/` を散文で参照していながら
# 母集団に入っていなかった）。skill directory が持つ同梱物と、SKILL.md 本文の同梱
# resource 参照の双方から導出する。`scripts/` のように消費プロジェクト側の path とも
# 読める綴りは過剰に拾いうるが、過剰包含は allowlist で理由付きに落とせるのに対し、
# 過小包含は本 Issue の欠陥そのもの（黙って対象外になる）なので、広く取る。
uses_bundled_resource() {
  local file="$1" dir sub
  dir="$(dirname "$file")"
  for sub in references fixtures scripts assets templates; do
    if [ -d "$dir/$sub" ]; then
      return 0
    fi
  done
  if grep -Fq 'FF_DEV_TOOLKIT_ROOT' "$file" || grep -Fq '${CLAUDE_PLUGIN_ROOT}' "$file" \
    || grep -Fq '${GROK_PLUGIN_ROOT}' "$file"; then
    return 0
  fi
  # 直前の文字クラスから `/` を外す。`/` を境界から除くと、sibling skill の同梱物を
  # `../harness-review/references/foo.md` と参照する形が構造的に不可視になる（Issue #860
  # のレビュー実測）。`skills/` は skill 自身の同梱物を絶対綴りで名指す形（実測:
  # out-of-scope-issue は `skills/out-of-scope-issue/SKILL.md`、pre-commit-check は
  # `skills/validate-docs/SKILL.md` を参照していながら母集団外だった）。
  if grep -Eq '(^|[^A-Za-z0-9_.-])(references|fixtures|docs-template|scripts|skills)/' "$file"; then
    return 0
  fi
  if grep -Fq '../../' "$file"; then
    return 0
  fi
  return 1
}

check_tree() {
  local skills_dir="$1"
  local file name required count=0 root_count=0 exempt_count=0 population=0
  local tree_fail=0 canonical="" block="" starts ends reason
  local guard_canonical="" gblock="" gstarts gends guard_count=0
  local guard_reason contract_end_ln guard_start_ln guard_end_ln first_bash_ln
  local placement_ok between

  for file in "$skills_dir"/*/SKILL.md; do
    [ -f "$file" ] || continue
    name="$(basename "$(dirname "$file")")"
    # 旧導出キー（root 変数）の件数を独立に数える。新導出はこれを包含するはずなので、
    # 下回ったら「拡張した導出が旧キーを取りこぼした」ことになり赤にする。
    if grep -Fq 'FF_DEV_TOOLKIT_ROOT' "$file" || grep -Fq '${CLAUDE_PLUGIN_ROOT}' "$file" \
    || grep -Fq '${GROK_PLUGIN_ROOT}' "$file"; then
      root_count=$((root_count + 1))
    fi
    uses_bundled_resource "$file" || continue
    population=$((population + 1))
    reason="$(exempt_reason "$name")"
    if [ -n "$reason" ]; then
      exempt_count=$((exempt_count + 1))
      continue
    fi
    count=$((count + 1))

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
      'grok CLIでは、Bash tool 環境の `${GROK_PLUGIN_ROOT}` があればそれを使う' \
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

    # 実行時rootガード（Issue #861）。契約 fence が散文で述べる fail-closed 停止を、
    # 契約 fence 直後の専用markerで囲んだ実行可能な複製として固定する。契約blockと
    # 同じ「marker各1件 → canonical一致 → 必須句」の順で見る（検出器は増やさず、
    # 同じ機構を対象だけ変えて再利用する）。
    guard_reason="$(guard_exempt_reason "$name")"
    if [ -n "$guard_reason" ]; then
      :
    else
      guard_count=$((guard_count + 1))
      {
        gstarts="$(grep -Fc '<!-- ff-dev-toolkit-plugin-root-guard:start -->' "$file" || true)"
        gends="$(grep -Fc '<!-- ff-dev-toolkit-plugin-root-guard:end -->' "$file" || true)"
        if [ "$gstarts" -ne 1 ] || [ "$gends" -ne 1 ]; then
          echo "$name: 実行時rootガードのmarkerはstart/end各1件が必要です" >&2
          tree_fail=1
        else
          gblock="$(sed -n '/<!-- ff-dev-toolkit-plugin-root-guard:start -->/,/<!-- ff-dev-toolkit-plugin-root-guard:end -->/p' "$file")"
          if [ -z "$guard_canonical" ]; then
            guard_canonical="$gblock"
          elif [ "$gblock" != "$guard_canonical" ]; then
            echo "$name: 実行時rootガードが他skillと一致しません" >&2
            tree_fail=1
          fi
          # `; then` と `exit 2` を必須句にすることで、`set -e` を仮定する
          # `|| { …; false; }` 形への弱体化（後続コマンドが走ってしまう形）が赤くなる。
          for required in \
            'if [ -z "${FF_DEV_TOOLKIT_ROOT:-}" ] || [ ! -d "${FF_DEV_TOOLKIT_ROOT}" ]; then' \
            'ff-dev-toolkit更新後にこのskillを再呼び出してください' \
            'exit 2'; do
            case "$gblock" in
              *"$required"*) ;;
              *)
                echo "$name: 実行時rootガードの必須句がありません: $required" >&2
                tree_fail=1
                ;;
            esac
          done

          # 配置の検査。marker の中身しか見ないと、ガードを resource 呼出の**後ろ**へ
          # 移しても緑のままで、「呼び出し本文の冒頭で走る」という契約が固定できない
          # （Codex レビュー実測）。契約 fence の直後（間は空行のみ）にあり、かつ
          # ファイル最初の bash fence がガード block の内側であることを見る。
          contract_end_ln="$(grep -n -F '<!-- ff-dev-toolkit-plugin-root-contract:end -->' "$file" | head -1 | cut -d: -f1)"
          guard_start_ln="$(grep -n -F '<!-- ff-dev-toolkit-plugin-root-guard:start -->' "$file" | head -1 | cut -d: -f1)"
          guard_end_ln="$(grep -n -F '<!-- ff-dev-toolkit-plugin-root-guard:end -->' "$file" | head -1 | cut -d: -f1)"
          first_bash_ln="$(grep -n '^```bash' "$file" | head -1 | cut -d: -f1)"
          placement_ok=1
          if [ -z "$contract_end_ln" ] || [ "$guard_start_ln" -le "$contract_end_ln" ]; then
            placement_ok=0
          elif [ "$guard_start_ln" -gt $((contract_end_ln + 1)) ]; then
            # パイプで受けると grep -q の早期終了が pipefail を踏むので変数へ取る。
            between="$(sed -n "$((contract_end_ln + 1)),$((guard_start_ln - 1))p" "$file")"
            case "$between" in
              *[![:space:]]*) placement_ok=0 ;;
            esac
          fi
          if [ "$placement_ok" -ne 1 ]; then
            echo "$name: 実行時rootガードが契約fenceの直後にありません" >&2
            tree_fail=1
          fi
          if [ -z "$first_bash_ln" ] \
            || [ "$first_bash_ln" -lt "$guard_start_ln" ] \
            || [ "$first_bash_ln" -gt "$guard_end_ln" ]; then
            echo "$name: 実行時rootガードより前にbash fenceがあります（resource呼出の後ろへ移していませんか）" >&2
            tree_fail=1
          fi
        fi
      }
    fi

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

  # 名簿の下限（fail-closed）は 2 本立て。
  #   (a) 0 件検査: 導出の空振り（fixture が空・glob のずれ）と root 変数の消失。
  #   (b) 絶対下限 MIN_SKILLS: 名簿そのものが縮む崩壊。root_count は母集団の部分集合
  #       （root 変数を持つ file は無条件で母集団に入る）なので `population -lt root_count`
  #       は到達不能であり、崩壊床にはならない。入力から独立した絶対値で床を張る。
  if [ "$population" -eq 0 ] || [ "$root_count" -eq 0 ]; then
    echo "resource参照skillの導出が空振りしました（母集団 ${population} 件 / root変数 ${root_count} 件）" >&2
    return 1
  fi
  if [ "$population" -lt "$MIN_SKILLS" ]; then
    echo "母集団 ${population} 件が絶対下限 ${MIN_SKILLS} 件を下回りました — 名簿が縮んでいます（意図的にskillを減らしたならMIN_SKILLSも下げる）" >&2
    return 1
  fi
  if [ "$count" -eq 0 ]; then
    echo "契約検査の対象が 0 件です（母集団 ${population} 件が allowlist で ${exempt_count} 件除外され全滅しました）" >&2
    return 1
  fi
  if [ "$guard_count" -lt "$MIN_GUARD_SKILLS" ]; then
    echo "実行時ガードの対象 ${guard_count} 件が絶対下限 ${MIN_GUARD_SKILLS} 件を下回りました — GUARD_EXEMPT が広がりすぎているか名簿が縮んでいます" >&2
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
  ok "liveのresource参照skillは同一のroot固定・fail-closed契約を持つ（検査対象 ${SCANNED_COUNT} skill）"
else
  bad "liveのroot固定契約に違反があります"
fi

# allowlist の項目は必ず報告に出す（黙って母集団から外れる形を作らないため）。
if [ "${#CONTRACT_EXEMPT[@]}" -eq 0 ]; then
  echo "  - 契約対象外 allowlist: 0 件"
else
  echo "  - 契約対象外 allowlist: ${#CONTRACT_EXEMPT[@]} 件"
  printf '      %s\n' "${CONTRACT_EXEMPT[@]}"
fi
echo "  - 実行時rootガード対象外 allowlist: ${#GUARD_EXEMPT[@]} 件"
printf '      %s\n' "${GUARD_EXEMPT[@]}"

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

# 実行時rootガードの negative control（Issue #861）。契約 fence の散文だけが残って
# 実行時の停止が消える形（削除 / `set -e` 依存への弱体化）を個別に赤にする。
# 変異が no-op だと control は「✓ 拒否する」を出したまま何も検出しないので、
# baseline との差分で適用を先に確かめる（TESTING.md「変異注入の適用確認」）。
make_fixture "$TMP/missing-guard"
perl -0pi -e 's/<!-- ff-dev-toolkit-plugin-root-guard:start -->.*?<!-- ff-dev-toolkit-plugin-root-guard:end -->\n//s' \
  "$TMP/missing-guard/ace-curate/SKILL.md"
if cmp -s "$TMP/baseline/ace-curate/SKILL.md" "$TMP/missing-guard/ace-curate/SKILL.md"; then
  bad "negative control: ガード削除の変異が適用されませんでした（検査結果は根拠になりません）"
elif check_tree "$TMP/missing-guard" >/dev/null 2>&1; then
  bad "negative control: 実行時rootガードの削除を見逃しました"
else
  ok "negative control: 実行時rootガードの削除を拒否する"
fi

# `|| { …; false; }` 形への弱体化。`set -e` の無いshellでは停止せず後続コマンドが走る。
#
# 変異は**非exemptの全skillへ同じ形で**当てる。1 skill だけ弱体化すると canonical 一致
# の検出器が先に赤くなるため、赤の出所が「必須句検査」なのか「他skillとの不一致」なのか
# 区別できず、必須句検査そのものの検出力を測れない（Codex レビュー実測）。全skillを同じ
# 弱体形へ揃えれば canonical は一致したままなので、赤は必須句検査だけに由来する。
make_fixture "$TMP/weakened-guard"
weakened_total=0
weakened_applied=0
for _wfile in "$TMP/weakened-guard"/*/SKILL.md; do
  [ -f "$_wfile" ] || continue
  _wname="$(basename "$(dirname "$_wfile")")"
  [ -z "$(guard_exempt_reason "$_wname")" ] || continue
  grep -Fq '<!-- ff-dev-toolkit-plugin-root-guard:start -->' "$_wfile" || continue
  weakened_total=$((weakened_total + 1))
  perl -0pi -e 's/if \[ -z "\$\{FF_DEV_TOOLKIT_ROOT:-\}" \] \|\| \[ ! -d "\$\{FF_DEV_TOOLKIT_ROOT\}" \]; then/[ -n "\${FF_DEV_TOOLKIT_ROOT:-}" ] \&\& [ -d "\${FF_DEV_TOOLKIT_ROOT}" ] || {/' "$_wfile"
  perl -0pi -e 's/^  exit 2$/  false/m' "$_wfile"
  perl -0pi -e 's/^fi$/}/m' "$_wfile"
  cmp -s "$TMP/baseline/$_wname/SKILL.md" "$_wfile" || weakened_applied=$((weakened_applied + 1))
done
if [ "$weakened_total" -eq 0 ] || [ "$weakened_applied" -ne "$weakened_total" ]; then
  bad "negative control: ガード弱体化の変異が全skillへ適用されませんでした（${weakened_applied}/${weakened_total}。検査結果は根拠になりません）"
elif check_tree "$TMP/weakened-guard" >/dev/null 2>&1; then
  bad "negative control: ガードの set -e 依存形への弱体化を見逃しました"
else
  ok "negative control: 全skillを同じ弱体形へ揃えても（canonical一致のまま）必須句検査が拒否する（${weakened_applied} skill）"
fi

# 拡張後の母集団の negative control（Issue #860）。同梱 resource を相対パスで参照し
# root 変数を使わない新規 skill が、契約を持たないまま母集団から漏れないことを固定する。
# 旧導出（root 変数の出現）ではこの形が構造的に不可視だった。
#
# fixture は **自ディレクトリに resource を持たず**、sibling skill の同梱 resource を
# 相対参照する形にする。自ディレクトリに `references/` を作ると directory 検査だけで
# 母集団へ入ってしまい、本文参照の導出（`/` を境界として扱えているか）を素通りする
# ため、`../harness-review/references/` の綴りを取りこぼす欠陥を検出できなかった。
make_fixture "$TMP/relative-resource-skill"
mkdir -p "$TMP/relative-resource-skill/zz-relative-resource"
printf -- '---\nname: zz-relative-resource\ndescription: negative control fixture\n---\n\n# zz-relative-resource\n\n`../harness-review/references/review-criteria.md` を読んで判断する。\n' \
  > "$TMP/relative-resource-skill/zz-relative-resource/SKILL.md"
if check_tree "$TMP/relative-resource-skill" >/dev/null 2>&1; then
  bad "negative control: 相対パスで同梱resourceを参照する契約なしskillを見逃しました"
else
  ok "negative control: root変数を使わず同梱resourceを参照するskillも母集団に入れて拒否する"
fi

# 上と同じ fixture を明示 allowlist へ理由付きで登録すれば緑になる（除外の逃し口が
# 実際に効くこと = 「黙って外れる」代わりに「宣言して外す」が成立することの固定）。
# CONTRACT_EXEMPT への追加が live 検査へ漏れないよう subshell で評価する。
if (
  CONTRACT_EXEMPT+=("zz-relative-resource|negative control fixture（liveのskillではない）")
  check_tree "$TMP/relative-resource-skill" >/dev/null 2>&1
); then
  ok "allowlist: 理由付きで登録したskillは契約対象外になり緑を保つ"
else
  bad "allowlist: 理由付き登録が効かず赤のままです"
fi

# ---- script 側 plugin root ガード ------------------------------------------
# skill 本文の契約 fence は、ホストが実行部だけを解決済み絶対 path として注入し契約節が
# 本文から落ちた経路では手元に無い（防御が守ろうとしている失敗と、防御が失われる条件が
# 同じ）。同じ停止を entry script 自身へ byte 一致で複製し、ここで固定する。skill 側の
# 検査と同じ「marker各1件 → canonical一致 → 必須句 → 配置」の順で見る。

# 実行時ガードの対象外（`script名|理由`）。黙って母集団から落とさないため理由付きで
# 登録し、報告にも出す。現在は 0 件。唯一の除外だった `ace-run-ts.sh`（PATHが壊れた環境でも
# 動くことを設計条件に外部コマンドを避ける）は、共通ガード側を bash 組み込みだけで書き直した
# ことで除外が要らなくなった。allowlist は「黙って母集団から落ちる形」を避けるための宣言で
# あって、穴を塞がずに済ませる根拠ではない。
SCRIPT_GUARD_EXEMPT=()

# provenance（起動時の実体path + version 1行）を抑止してよい script（`script名|理由`）。
# 出力そのものが契約になっているscript（成功時は無出力・stderrは異常時だけ）では情報行が
# 契約違反になる。抑止の実体はガード block 内の basename allowlist で、外部の環境変数からは
# 抑止できない（外から渡せると allowlist が実効的な制約にならない）。ここは「その allowlist と
# 一致しているか」を照合し、理由を報告に出すための表。
SCRIPT_PROVENANCE_QUIET=(
  "check-merge-freshness.sh|exit 0 は無出力が契約（一致を「何も言わない」で表す）"
  "check-plugin-versions.sh|出力はJSON/集計行で、stderrは異常時だけという前提を呼び出し側が持つ"
)

provenance_quiet_reason() {
  local name="$1" entry
  [ "${#SCRIPT_PROVENANCE_QUIET[@]}" -gt 0 ] || return 0
  for entry in "${SCRIPT_PROVENANCE_QUIET[@]}"; do
    case "$entry" in
      "$name"'|'*) printf '%s' "${entry#*|}"; return 0 ;;
    esac
  done
  return 0
}

# 根 root 消失時の期待終了コード（`script名|rc`）。中断コードは script ごとに違う（2 に別の
# 意味 — PARTIAL・判定不能・判定結果 — を割り当てている script があり、そこでガードの停止を
# 2 で返すと「実行された」と誤読される）。suite が任意の数字へ正規化するだけだと、既存の rc
# 契約と衝突する誤番号を検出できないので、期待値をここで名指しし、静的検査と実走の両方で使う。
SCRIPT_EXPECT_RC=(
  "ace-run-ts.sh|2"
  "check-closing-keywords.sh|2"
  "check-issue-body-diff.sh|2"
  "check-merge-freshness.sh|3"
  "check-plugin-versions.sh|1"
  "check-version-claims.sh|2"
  "effort-report.sh|2"
  "merge-cleanup.sh|1"
  "multi-agent.sh|2"
  "multi-review.sh|2"
  "setup-multi-agent.sh|2"
  "sweep-orphan-transcripts.sh|2"
  "update-version-claim.sh|2"
  "workflow-tier.sh|64"
)

script_expect_rc() {
  local name="$1" entry
  for entry in "${SCRIPT_EXPECT_RC[@]}"; do
    case "$entry" in
      "$name"'|'*) printf '%s' "${entry#*|}"; return 0 ;;
    esac
  done
  return 1
}

# 崩壊床（絶対下限）。母集団（固定root経由で呼ばれる同梱shell script）とガード対象の
# 実数で置く。入力から導いた量（母集団 - 除外数）を床にしても、名簿が丸ごと縮む変異は
# 部分集合を自分自身と比べるだけになって検出できない。script を減らす変更は、意図的なら
# この値も同時に下げる。
#
# 12 → 14 は「抽出ロジックを直したら増えた」数である。旧抽出は `${VAR}` の綴りしか拾えず、
# `${VAR:?…}` のような修飾付き parameter expansion で呼ばれる 2 本（Issue 本文差分の判定器と
# 工数集計器）が構造的に母集団の外にあった。床を「同じ抽出から導いた 12」に置いていたため、
# 漏れは部分集合を自分自身と比べるだけになって検出できなかった。
MIN_ROOT_SCRIPTS=14
MIN_GUARDED_SCRIPTS=14

script_guard_exempt_reason() {
  local name="$1" entry
  [ "${#SCRIPT_GUARD_EXEMPT[@]}" -gt 0 ] || return 0
  for entry in "${SCRIPT_GUARD_EXEMPT[@]}"; do
    case "$entry" in
      "$name"'|'*) printf '%s' "${entry#*|}"; return 0 ;;
    esac
  done
  return 0
}

# 母集団は「scripts/ 配下の .sh 全部」ではなく「`${FF_DEV_TOOLKIT_ROOT}/scripts/<名>` として
# 呼ばれている入口」から導く。ガードが要るのは host が直接起動する入口で、source される
# lib や adapter まで広げると対象がぼやける。呼び出し側（skill / docs-template）の実体から
# 導出するので、固定root経由の新しい入口は名簿へ自動的に入る。
#
# 綴りは `${VAR}` だけではない。`${VAR:?案内}` / `${VAR:-既定}` のような**修飾付き
# parameter expansion** と、brace 無しの `$VAR` も同じ入口である。旧抽出はこれらを取りこぼし、
# 取りこぼした 2 本はガードを持たないまま母集団の外にいた。root 変数名も 3 つすべてを見る。
derive_root_scripts() {
  { grep -rhoE '\$\{?(FF_DEV_TOOLKIT_ROOT|CLAUDE_PLUGIN_ROOT|GROK_PLUGIN_ROOT)(:[-?+=][^}]*)?\}?/scripts/[A-Za-z0-9_.-]+\.sh' \
      "$@" 2>/dev/null || true; } \
    | sed 's|.*/||' | sort -u
}

ROOT_SCRIPT_NAMES="$(derive_root_scripts "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/docs-template")"

# ガード block 内の provenance 抑止 allowlist（`<名>|<名>) quiet=1 ;;` の 1 行）を読む。
# 抑止の宣言はこの 1 行が正本で、外部の環境変数では抑止できない。
quiet_allowlist_names() { # <script file>
  sed -n 's/^[[:space:]]*\([A-Za-z0-9_.|-]*\)) quiet=1 ;;$/\1/p' "$1" \
    | tr '|' '\n' | sed '/^$/d' | sort -u
}

check_script_guards() {
  local scripts_dir="$1"
  local name file reason starts ends block norm required forbidden expect_rc actual_rc
  local guard_start_ln prelude quiet_reason quiet_names
  local canonical="" population=0 guarded=0 exempt=0 tree_fail=0

  for name in $ROOT_SCRIPT_NAMES; do
    population=$((population + 1))
    reason="$(script_guard_exempt_reason "$name")"
    if [ -n "$reason" ]; then
      exempt=$((exempt + 1))
      continue
    fi
    file="$scripts_dir/$name"
    if [ ! -f "$file" ]; then
      echo "$name: 固定root経由で呼ばれる同梱scriptが実在しません: $file" >&2
      tree_fail=1
      continue
    fi
    guarded=$((guarded + 1))

    starts="$(grep -Fc '# ff-dev-toolkit-script-root-guard:start' "$file" || true)"
    ends="$(grep -Fc '# ff-dev-toolkit-script-root-guard:end' "$file" || true)"
    if [ "$starts" -ne 1 ] || [ "$ends" -ne 1 ]; then
      echo "$name: script側ガードのmarkerはstart/end各1件が必要です" >&2
      tree_fail=1
      continue
    fi

    block="$(sed -n '/# ff-dev-toolkit-script-root-guard:start/,/# ff-dev-toolkit-script-root-guard:end/p' "$file")"
    # 中断コードだけは script ごとに違う（2 に別の意味 — PARTIAL・判定不能・判定結果 —
    # を割り当てている script があり、そこでガードの停止を 2 で返すと「実行された」と
    # 誤読される）。比較の前にその 1 語だけを正規化し、残りの差分は canonical 一致で拒否する。
    # 正規化で見えなくなった数字は、下の期待rc表で名指しして別に固定する。
    norm="$(printf '%s\n' "$block" | sed 's/|| exit [0-9][0-9]*$/|| exit <中断コード>/')"
    if [ -z "$canonical" ]; then
      canonical="$norm"
    elif [ "$norm" != "$canonical" ]; then
      echo "$name: script側ガードが他のscriptと一致しません" >&2
      tree_fail=1
    fi

    # 期待rc表との照合。正規化した 1 語を、script ごとの契約として固定し直す。
    if ! expect_rc="$(script_expect_rc "$name")"; then
      echo "$name: 期待rcがSCRIPT_EXPECT_RCにありません（新しい入口はrc契約も同時に決めること）" >&2
      tree_fail=1
    else
      actual_rc="$(printf '%s\n' "$block" | sed -n 's/^ff_assert_script_plugin_root "${BASH_SOURCE\[0\]}" || exit \([0-9][0-9]*\)$/\1/p' | head -1)"
      if [ "$actual_rc" != "$expect_rc" ]; then
        echo "$name: ガードの中断コードが期待rcと違います（実体 ${actual_rc:-不明} / 期待 ${expect_rc}）" >&2
        tree_fail=1
      fi
    fi

    for required in \
      'ff_assert_script_plugin_root "${BASH_SOURCE[0]}" || exit' \
      'for var in FF_DEV_TOOLKIT_ROOT CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT; do' \
      'ff-dev-toolkit更新後にこのskillを再呼び出してください' \
      'version混在と未リリースWIPの実行になります' \
      'return 1' \
      'if [ -L "$self" ]; then' \
      '[ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1' \
      'dir="$(CDPATH= cd -P -- "$dir" 2>/dev/null && pwd -P)"' \
      'root="$(CDPATH= cd -P -- "${dir}/.." 2>/dev/null && pwd -P)"' \
      'canonical="$(CDPATH= cd -P -- "$value" 2>/dev/null && pwd -P)"' \
      '判定不能は停止に倒します' \
      'case "${self##*/}" in' \
      '照合対象外'; do
      case "$block" in
        *"$required"*) ;;
        *)
          echo "$name: script側ガードの必須句がありません: $required" >&2
          tree_fail=1
          ;;
      esac
    done

    # 禁止句。provenance の抑止を外部から渡せる形（環境変数の読み取り）へ戻すと、
    # allowlist が実効的な制約でなくなる — allowlist 外の script でも抑止できてしまう。
    for forbidden in 'FF_SCRIPT_ROOT_GUARD_QUIET'; do
      case "$block" in
        *"$forbidden"*)
          echo "$name: provenance抑止を外部から渡せる形に戻しています: $forbidden" >&2
          tree_fail=1
          ;;
      esac
    done

    # 配置も見る。marker の中身だけを照合すると、ガードを破壊的処理の**後ろ**へ移しても
    # 緑のままになり、「起動直後に走る」という契約が固定できない（skill 側と同じ穴）。
    # ガードより前にあってよいのは shebang / コメント / 空行 / `set` 行だけにする。
    guard_start_ln="$(grep -n -F '# ff-dev-toolkit-script-root-guard:start' "$file" | head -1 | cut -d: -f1)"
    if [ "$guard_start_ln" -gt 1 ]; then
      # パイプの早期終了が pipefail を踏むので、判定は変数へ取ってから行う。
      prelude="$(sed -n "1,$((guard_start_ln - 1))p" "$file" \
        | grep -Ev '^[[:space:]]*(#|$)|^set([[:space:]]|$)' || true)"
      if [ -n "$prelude" ]; then
        echo "$name: script側ガードより前に実行文があります（起動直後に走る契約が崩れています）" >&2
        tree_fail=1
      fi
    fi

    # provenance 抑止は allowlist と一致していること。ガード block 内の basename 列挙が正本で、
    # この suite の表はその写しである。片方だけが動く形（黙って抑止する / 理由だけ残る）を赤にする。
    quiet_reason="$(provenance_quiet_reason "$name")"
    quiet_names="$(quiet_allowlist_names "$file" | tr '\n' ' ')"
    case " $quiet_names " in
      *" $name "*)
        if [ -z "$quiet_reason" ]; then
          echo "$name: ガード内allowlistでprovenanceを抑止していますがSCRIPT_PROVENANCE_QUIETに理由がありません" >&2
          tree_fail=1
        fi
        ;;
      *)
        if [ -n "$quiet_reason" ]; then
          echo "$name: SCRIPT_PROVENANCE_QUIETに登録されていますがガード内allowlistに載っていません" >&2
          tree_fail=1
        fi
        ;;
    esac
  done

  if [ "$population" -eq 0 ]; then
    echo "固定root経由で呼ばれる同梱scriptの導出が空振りしました" >&2
    return 1
  fi
  if [ "$population" -lt "$MIN_ROOT_SCRIPTS" ]; then
    echo "母集団 ${population} 件が絶対下限 ${MIN_ROOT_SCRIPTS} 件を下回りました — 名簿が縮んでいます（意図的にscriptを減らしたならMIN_ROOT_SCRIPTSも下げる）" >&2
    return 1
  fi
  if [ "$guarded" -lt "$MIN_GUARDED_SCRIPTS" ]; then
    echo "ガード対象 ${guarded} 件が絶対下限 ${MIN_GUARDED_SCRIPTS} 件を下回りました — SCRIPT_GUARD_EXEMPT が広がりすぎているか名簿が縮んでいます" >&2
    return 1
  fi
  SCRIPT_SCANNED_COUNT="$guarded"
  [ "$tree_fail" -eq 0 ]
}

echo ""
echo "== script側 plugin rootガード検査 =="
SCRIPT_SCANNED_COUNT=0
if check_script_guards "$PLUGIN_ROOT/scripts"; then
  ok "固定root経由で呼ばれる同梱scriptは同一のroot照合ガードを起動直後に持つ（検査対象 ${SCRIPT_SCANNED_COUNT} script）"
else
  bad "liveのscript側ガードに違反があります"
fi
if [ "${#SCRIPT_GUARD_EXEMPT[@]}" -eq 0 ]; then
  echo "  - script側ガード対象外 allowlist: 0 件"
else
  echo "  - script側ガード対象外 allowlist: ${#SCRIPT_GUARD_EXEMPT[@]} 件"
  printf '      %s\n' "${SCRIPT_GUARD_EXEMPT[@]}"
fi
echo "  - provenance抑止 allowlist: ${#SCRIPT_PROVENANCE_QUIET[@]} 件"
printf '      %s\n' "${SCRIPT_PROVENANCE_QUIET[@]}"

# census の抽出そのものの negative control。修飾付き parameter expansion（`${VAR:?…}` /
# `${VAR:-…}`）と brace 無しの `$VAR` を拾えなくなったら赤にする。旧抽出はこの形を取りこぼし、
# 取りこぼした入口は「母集団に居ないので検査されない」= 黙って対象外になっていた。
mkdir -p "$TMP/census-fixture"
{
  printf 'bash "${FF_DEV_TOOLKIT_ROOT:?プラグインルートを先に解決すること}/scripts/zz-qualified.sh"\n'
  printf 'bash "${FF_DEV_TOOLKIT_ROOT:-/fallback}/scripts/zz-default.sh"\n'
  printf '"$FF_DEV_TOOLKIT_ROOT/scripts/zz-unbraced.sh" --flag\n'
  printf 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/zz-claude.sh"\n'
  printf 'bash "${GROK_PLUGIN_ROOT}/scripts/zz-grok.sh"\n'
} > "$TMP/census-fixture/sample.md"
census_out="$(derive_root_scripts "$TMP/census-fixture" | tr '\n' ' ')"
census_missing=""
for name in zz-qualified.sh zz-default.sh zz-unbraced.sh zz-claude.sh zz-grok.sh; do
  case " $census_out " in
    *" $name "*) ;;
    *) census_missing="${census_missing} ${name}" ;;
  esac
done
if [ -n "$census_missing" ]; then
  bad "census: 修飾付き/brace無しのroot参照を取りこぼしました:${census_missing}"
else
  ok "census: \${VAR:?…} / \${VAR:-…} / \$VAR / 3つのroot変数名すべてから入口を導出する"
fi
# live の名簿に、修飾付き綴りでしか呼ばれない入口が実際に入っていること（回帰ピン）。
census_live_missing=""
for name in check-issue-body-diff.sh effort-report.sh; do
  case " $(printf '%s ' $ROOT_SCRIPT_NAMES) " in
    *" $name "*) ;;
    *) census_live_missing="${census_live_missing} ${name}" ;;
  esac
done
if [ -n "$census_live_missing" ]; then
  bad "census: 修飾付き綴りでのみ呼ばれるliveの入口が名簿にありません:${census_live_missing}"
else
  ok "census: 修飾付き綴りでのみ呼ばれるliveの入口も名簿に入る（母集団 $(printf '%s\n' $ROOT_SCRIPT_NAMES | wc -l | tr -d ' ') 件）"
fi

make_scripts_fixture() {
  local dest="$1" name
  mkdir -p "$dest"
  for name in $ROOT_SCRIPT_NAMES; do
    [ -f "$PLUGIN_ROOT/scripts/$name" ] || continue
    cp "$PLUGIN_ROOT/scripts/$name" "$dest/$name"
  done
}

make_scripts_fixture "$TMP/scripts-baseline"
if check_script_guards "$TMP/scripts-baseline" >/dev/null 2>&1; then
  ok "positive control: 無変異のscript fixtureはガード契約を満たす（以降の非0が変異由来だと言える）"
else
  bad "positive control: 無変異のscript fixtureが落ちました（以降の negative control は根拠になりません）"
fi

make_scripts_fixture "$TMP/scripts-missing-marker"
perl -0pi -e 's/# ff-dev-toolkit-script-root-guard:start\n//' \
  "$TMP/scripts-missing-marker/merge-cleanup.sh"
if cmp -s "$TMP/scripts-baseline/merge-cleanup.sh" "$TMP/scripts-missing-marker/merge-cleanup.sh"; then
  bad "negative control: marker削除の変異が適用されませんでした（検査結果は根拠になりません）"
elif check_script_guards "$TMP/scripts-missing-marker" >/dev/null 2>&1; then
  bad "negative control: script側ガードのmarker欠落を見逃しました"
else
  ok "negative control: script側ガードのmarker欠落を拒否する"
fi

# 呼び出し行だけを消す変異。関数定義が残るので marker も canonical も一致したままで、
# 必須句検査だけが赤にできる形。ガードが「定義されているが走らない」退行にあたる。
make_scripts_fixture "$TMP/scripts-uncalled-guard"
perl -0pi -e 's/^ff_assert_script_plugin_root "\$\{BASH_SOURCE\[0\]\}" \|\| exit [0-9]+\n//m' \
  "$TMP/scripts-uncalled-guard/merge-cleanup.sh"
if cmp -s "$TMP/scripts-baseline/merge-cleanup.sh" "$TMP/scripts-uncalled-guard/merge-cleanup.sh"; then
  bad "negative control: 呼び出し行削除の変異が適用されませんでした（検査結果は根拠になりません）"
elif check_script_guards "$TMP/scripts-uncalled-guard" >/dev/null 2>&1; then
  bad "negative control: 定義だけ残してガードを呼ばない退行を見逃しました"
else
  ok "negative control: ガードを呼ばない退行を拒否する"
fi

# 一斉弱体化の control（skill 側と同型）。1 本だけ変異させると canonical 一致の検出器が先に
# 赤くなり、赤の出所が「必須句検査」なのか「他scriptとの不一致」なのか区別できない。全 script を
# 同じ弱い形へ揃えれば canonical は一致したままなので、赤は必須句検査だけに由来する。
# 形は「停止を落として続行させる」= `|| exit N` を外す（ガードは走るが結果を無視する）。
make_scripts_fixture "$TMP/scripts-weakened-all"
weakened_total=0
weakened_applied=0
for _sfile in "$TMP/scripts-weakened-all"/*.sh; do
  [ -f "$_sfile" ] || continue
  _sname="$(basename "$_sfile")"
  grep -Fq '# ff-dev-toolkit-script-root-guard:start' "$_sfile" || continue
  weakened_total=$((weakened_total + 1))
  perl -0pi -e 's/^ff_assert_script_plugin_root "\$\{BASH_SOURCE\[0\]\}" \|\| exit [0-9]+$/ff_assert_script_plugin_root "\${BASH_SOURCE[0]}" || true/m' "$_sfile"
  cmp -s "$TMP/scripts-baseline/$_sname" "$_sfile" || weakened_applied=$((weakened_applied + 1))
done
if [ "$weakened_total" -eq 0 ] || [ "$weakened_applied" -ne "$weakened_total" ]; then
  bad "negative control: 一斉弱体化の変異が全scriptへ適用されませんでした（${weakened_applied}/${weakened_total}。検査結果は根拠になりません）"
elif check_script_guards "$TMP/scripts-weakened-all" >/dev/null 2>&1; then
  bad "negative control: 全scriptを同じ弱体形へ揃えた退行を見逃しました"
else
  ok "negative control: 全scriptを同じ弱体形へ揃えても（canonical一致のまま）必須句検査が拒否する（${weakened_applied} script）"
fi

# 判定の穴を塞ぐ必須句が、一斉に落ちても赤になること（canonical 一致のまま必須句だけが欠ける）。
# symlink 拒否 / manifest の fail-closed / 外部envによる抑止の禁止は、どれも 1 行消すだけで
# 静かに戻せる形なので、個別に固定する。
for _case in \
  'symlink拒否|if \[ -L "\$self" \]; then|if [ -L "$self" ] \&\& false; then' \
  'CDPATHの無効化|CDPATH= cd -P -- "\$dir"|cd -P -- "$dir"' \
  'manifestのfail-closed|\[ ! -L "\$file" \] \&\& |'; do
  _label="${_case%%|*}"
  _rest="${_case#*|}"
  _from="${_rest%%|*}"
  _to="${_rest#*|}"
  make_scripts_fixture "$TMP/scripts-weak-$_label"
  _w_total=0
  _w_applied=0
  for _sfile in "$TMP/scripts-weak-$_label"/*.sh; do
    [ -f "$_sfile" ] || continue
    _sname="$(basename "$_sfile")"
    grep -Fq '# ff-dev-toolkit-script-root-guard:start' "$_sfile" || continue
    _w_total=$((_w_total + 1))
    FF_FROM="$_from" FF_TO="$_to" perl -0pi -e 's/$ENV{FF_FROM}/$ENV{FF_TO}/' "$_sfile"
    cmp -s "$TMP/scripts-baseline/$_sname" "$_sfile" || _w_applied=$((_w_applied + 1))
  done
  if [ "$_w_total" -eq 0 ] || [ "$_w_applied" -ne "$_w_total" ]; then
    bad "negative control(${_label}): 変異が全scriptへ適用されませんでした（${_w_applied}/${_w_total}）"
  elif check_script_guards "$TMP/scripts-weak-$_label" >/dev/null 2>&1; then
    bad "negative control(${_label}): 全scriptから同時に落としても見逃しました"
  else
    ok "negative control: ${_label}を全scriptから同時に落としても拒否する（${_w_applied} script）"
  fi
done

# 中断コードの誤番号。canonical 比較は `|| exit N` の 1 語を正規化するので、ここは期待rc表
# だけが検出できる。既存の rc 契約と衝突する番号（merge-cleanup の 2 = PARTIAL）を当てる。
make_scripts_fixture "$TMP/scripts-wrong-rc"
perl -0pi -e 's/^ff_assert_script_plugin_root "\$\{BASH_SOURCE\[0\]\}" \|\| exit 1$/ff_assert_script_plugin_root "\${BASH_SOURCE[0]}" || exit 2/m' \
  "$TMP/scripts-wrong-rc/merge-cleanup.sh"
if cmp -s "$TMP/scripts-baseline/merge-cleanup.sh" "$TMP/scripts-wrong-rc/merge-cleanup.sh"; then
  bad "negative control: 中断コード差し替えの変異が適用されませんでした（検査結果は根拠になりません）"
elif check_script_guards "$TMP/scripts-wrong-rc" >/dev/null 2>&1; then
  bad "negative control: 既存rc契約と衝突する中断コードを見逃しました"
else
  ok "negative control: 期待rc表と違う中断コードを拒否する"
fi

# canonical 一致の検出器は先頭以外を変えないと発火しない（先頭が canonical の出所）。
# 名簿は sort 済みなので、先頭ではない merge-cleanup.sh を変異させる。
make_scripts_fixture "$TMP/scripts-diverged-guard"
perl -0pi -e 's/version混在と未リリースWIPの実行になります。/更新が間に合わないときは新しい方を使ってよい。/' \
  "$TMP/scripts-diverged-guard/merge-cleanup.sh"
if cmp -s "$TMP/scripts-baseline/merge-cleanup.sh" "$TMP/scripts-diverged-guard/merge-cleanup.sh"; then
  bad "negative control: 案内文の変異が適用されませんでした（検査結果は根拠になりません）"
elif check_script_guards "$TMP/scripts-diverged-guard" >/dev/null 2>&1; then
  bad "negative control: script間でガードがdivergeした状態を見逃しました"
else
  ok "negative control: 一部scriptだけガードが異なれば拒否する"
fi

# 配置の negative control。ガードの前に実行文を差し込む（= resource を触る処理の後ろへ
# 移した形）。marker も canonical も必須句も無傷なので、配置検査だけが赤になる。
make_scripts_fixture "$TMP/scripts-late-guard"
perl -0pi -e 's/^# ff-dev-toolkit-script-root-guard:start$/REPO_ROOT="$(git rev-parse --show-toplevel)"\n# ff-dev-toolkit-script-root-guard:start/m' \
  "$TMP/scripts-late-guard/merge-cleanup.sh"
if cmp -s "$TMP/scripts-baseline/merge-cleanup.sh" "$TMP/scripts-late-guard/merge-cleanup.sh"; then
  bad "negative control: ガード前への実行文挿入が適用されませんでした（検査結果は根拠になりません）"
elif check_script_guards "$TMP/scripts-late-guard" >/dev/null 2>&1; then
  bad "negative control: ガードより前の実行文を見逃しました"
else
  ok "negative control: ガードより前に実行文があれば拒否する"
fi

# 名簿にあるのに実体が無い（入口を消した / 改名した）場合に fail-closed であること、
# および理由付き allowlist での除外が実際に効くこと。
make_scripts_fixture "$TMP/scripts-missing-entry"
rm -f "$TMP/scripts-missing-entry/merge-cleanup.sh"
if check_script_guards "$TMP/scripts-missing-entry" >/dev/null 2>&1; then
  bad "negative control: 固定root経由で呼ばれるscriptの消失を見逃しました"
else
  ok "negative control: 名簿にある同梱scriptが実在しなければ拒否する"
fi
if (
  SCRIPT_GUARD_EXEMPT+=("merge-cleanup.sh|negative control fixture（liveの判断ではない）")
  MIN_GUARDED_SCRIPTS=$((MIN_GUARDED_SCRIPTS - 1))
  check_script_guards "$TMP/scripts-missing-entry" >/dev/null 2>&1
); then
  ok "allowlist: 理由付きで登録したscriptはガード対象外になり緑を保つ"
else
  bad "allowlist: 理由付き登録が効かず赤のままです"
fi

# provenance 抑止の negative control。ガード内 allowlist を広げても suite の表が追従して
# いなければ赤にする（黙って抑止が広がる形）。1 本だけ広げると canonical 一致が先に赤くなる
# ので、全 script へ同じ形で当てる。
make_scripts_fixture "$TMP/scripts-silent-quiet"
quiet_total=0
quiet_applied=0
for _sfile in "$TMP/scripts-silent-quiet"/*.sh; do
  [ -f "$_sfile" ] || continue
  _sname="$(basename "$_sfile")"
  grep -Fq '# ff-dev-toolkit-script-root-guard:start' "$_sfile" || continue
  quiet_total=$((quiet_total + 1))
  perl -0pi -e 's/^(\s*)check-merge-freshness\.sh\|check-plugin-versions\.sh\) quiet=1 ;;$/$1check-merge-freshness.sh|check-plugin-versions.sh|merge-cleanup.sh) quiet=1 ;;/m' "$_sfile"
  cmp -s "$TMP/scripts-baseline/$_sname" "$_sfile" || quiet_applied=$((quiet_applied + 1))
done
if [ "$quiet_total" -eq 0 ] || [ "$quiet_applied" -ne "$quiet_total" ]; then
  bad "negative control: provenance抑止の拡大が全scriptへ適用されませんでした（${quiet_applied}/${quiet_total}）"
elif check_script_guards "$TMP/scripts-silent-quiet" >/dev/null 2>&1; then
  bad "negative control: 理由なしの provenance 抑止を見逃しました"
else
  ok "negative control: SCRIPT_PROVENANCE_QUIETに無いscriptの抑止を拒否する（${quiet_applied} script）"
fi

# 外部から渡せる形（環境変数の読み取り）へ戻す変異。禁止句検査だけが赤にできる。
make_scripts_fixture "$TMP/scripts-env-quiet"
env_quiet_total=0
env_quiet_applied=0
for _sfile in "$TMP/scripts-env-quiet"/*.sh; do
  [ -f "$_sfile" ] || continue
  _sname="$(basename "$_sfile")"
  grep -Fq '# ff-dev-toolkit-script-root-guard:start' "$_sfile" || continue
  env_quiet_total=$((env_quiet_total + 1))
  perl -0pi -e 's/^  if \[ "\$quiet" -ne 1 \]; then$/  if [ "\${FF_SCRIPT_ROOT_GUARD_QUIET:-0}" != 1 ] \&\& [ "\$quiet" -ne 1 ]; then/m' "$_sfile"
  cmp -s "$TMP/scripts-baseline/$_sname" "$_sfile" || env_quiet_applied=$((env_quiet_applied + 1))
done
if [ "$env_quiet_total" -eq 0 ] || [ "$env_quiet_applied" -ne "$env_quiet_total" ]; then
  bad "negative control: 外部env抑止への差し戻しが全scriptへ適用されませんでした（${env_quiet_applied}/${env_quiet_total}）"
elif check_script_guards "$TMP/scripts-env-quiet" >/dev/null 2>&1; then
  bad "negative control: provenance抑止を外部envから渡せる形に戻したのを見逃しました"
else
  ok "negative control: 外部envでprovenanceを抑止できる形を拒否する（${env_quiet_applied} script）"
fi

# ---- 固定root経由の実行部が同じ行でhandoffを渡すこと ------------------------
# host は plugin root を Bash tool の環境へ export せず、実行部テキストへ解決済みの絶対 path を
# 差し込むだけである。handoff を運ぶのが skill 本文の resolver / fence だけだと、「本文が劣化して
# 届かなかった」ちょうどそのときに handoff も消え、script 側ガードは比較対象なしで素通しになる
# （実測: 事故の形では `handoff: なし・直接起動` のまま本来の処理へ進んだ）。実行部と同じ 1 行へ
# 代入を載せておけば、実行するスクリプトの path だけを別領域へ書き換える操作が、その行の中の
# 不一致として検出できる。
#
# 母集団は「固定root経由で同梱scriptを起動している行」。直接起動（`bash "${ROOT}/scripts/x.sh"`）
# と、同じファイルで固定root経由のpathを受けた変数経由の起動（`bash "${JUDGE}"`）の両方を見る。
# 起動しない行（`[[ -x "${ROOT}/scripts/x.sh" ]]` のような存在確認や散文）は対象にしない —
# ガードが走らない行に handoff を求めても意味が無く、常時赤いゲートになる。
#
# 床は live の実数ぴったりに置く（MIN_SKILLS / MIN_GUARD_SKILLS / MIN_ROOT_SCRIPTS /
# MIN_GUARDED_SCRIPTS と同じ規律）。母集団と検査は同じ grep を共有しているので、1 行でも
# 余裕があると、起動行を grep が拾えない綴り（`bash -- "${ROOT}/scripts/x.sh"` / `exec bash …`）
# への書き換えが**母集団と検査の両方から同時に落ち**、床を通過したまま黙って handoff 要求を
# 逃れられる。実行部を意図的に減らすときだけこの値を下げる。
MIN_HANDOFF_LAUNCHES=101

handoff_launch_files() { # <tree root> → 対象 .md を列挙
  find "$1/skills" -name SKILL.md -type f 2>/dev/null
  find "$1/docs-template" -name '*.md' -type f 2>/dev/null
}

check_exec_handoff() {
  local list="$1" file names hits line body fail=0 launches=0
  # 起動トークンの綴り。`bash`/`sh` を挟む形と挟まない形、固定root経由のpathを受けた変数経由の
  # 起動（`names`）をまとめる。`assign` は handoff 代入で、**起動トークンの直前に並ぶ**ことを
  # 求めるために前置する。
  local root_expr='\$\{?(FF_DEV_TOOLKIT_ROOT|CLAUDE_PLUGIN_ROOT|GROK_PLUGIN_ROOT)[^}]*\}?/scripts/[A-Za-z0-9_.-]+\.sh'
  local assign='FF_DEV_TOOLKIT_ROOT="[^"]*"[[:space:]]+'
  local launch_re="" anchored_re="" n_launch="" n_anchor=""
  while IFS= read -r file; do
    [ -f "$file" ] || continue
    names="$(grep -Eo '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*="?\$\{?(FF_DEV_TOOLKIT_ROOT|CLAUDE_PLUGIN_ROOT|GROK_PLUGIN_ROOT)[^}]*\}?/scripts/[A-Za-z0-9_.-]+\.sh"?$' "$file" \
      | sed 's/=.*//' | tr -d ' ' | sort -u | tr '\n' '|' | sed 's/|$//')" || names=""
    : > "$TMP/handoff-hits"
    grep -nE '(bash|sh)[[:space:]]+"?\$\{?(FF_DEV_TOOLKIT_ROOT|CLAUDE_PLUGIN_ROOT|GROK_PLUGIN_ROOT)[^}]*\}?/scripts/[A-Za-z0-9_.-]+\.sh' \
      "$file" >> "$TMP/handoff-hits" || true
    # 直接起動（`bash` を挟まない形）。handoff 代入を前置した形もここで拾えないと、
    # 「直したら検出対象から外れる」= 母集団が縮む検査になる。
    grep -nE '(^|[;&|][[:space:]]*)[[:space:]]*([A-Za-z_][A-Za-z0-9_]*="[^"]*"[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]"]*[[:space:]]+)*"\$\{?(FF_DEV_TOOLKIT_ROOT|CLAUDE_PLUGIN_ROOT|GROK_PLUGIN_ROOT)\}?/scripts/[A-Za-z0-9_.-]+\.sh"' \
      "$file" >> "$TMP/handoff-hits" || true
    if [ -n "$names" ]; then
      grep -nE "(bash|sh)[[:space:]]+\"\\\$\\{?($names)\\}?\"" "$file" >> "$TMP/handoff-hits" || true
    fi
    # 充足判定は「行のどこかに代入がある」ではなく「**起動トークンの直前に**代入が並ぶ」で見る。
    # 行全体への部分一致だと、同じ行のコメントや 2 つ目のコマンドに代入があるだけで緑になり、
    # 実際に起動している側は素の `bash "${ROOT}/scripts/x.sh"` のまま通せる（実測: 代入を行末
    # コメントへ退避させた変異が旧判定では緑だった）。1 行に起動が複数あってもよいので、
    # 「起動トークンの総数」と「直前に代入が並ぶ起動の総数」が一致することを要求する。
    launch_re="((bash|sh)[[:space:]]+)?\"?${root_expr}"
    anchored_re="${assign}((bash|sh)[[:space:]]+)?\"?${root_expr}"
    if [ -n "$names" ]; then
      launch_re="${launch_re}|(bash|sh)[[:space:]]+\"\\\$\\{?($names)\\}?\""
      anchored_re="${anchored_re}|${assign}(bash|sh)[[:space:]]+\"\\\$\\{?($names)\\}?\""
    fi
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      launches=$((launches + 1))
      # grep -n の `行番号:` を落とす（数字と `:` は起動トークンにも代入にも当たらないが、
      # 報告の読みやすさと計数の素直さのため本文だけを見る）。
      body="${line#*:}"
      n_launch="$(printf '%s\n' "$body" | { grep -oE "$launch_re" || true; } | wc -l | tr -d ' ')"
      n_anchor="$(printf '%s\n' "$body" | { grep -oE "$anchored_re" || true; } | wc -l | tr -d ' ')"
      if [ "$n_launch" -eq 0 ] || [ "$n_anchor" -ne "$n_launch" ]; then
        echo "${file}: 固定root経由の実行部が起動トークンの直前でhandoffを渡していません（起動 ${n_launch} 件 / 代入付き ${n_anchor} 件）: ${line}" >&2
        fail=1
      fi
    done < "$TMP/handoff-hits"
  done < "$list"
  if [ "$launches" -lt "$MIN_HANDOFF_LAUNCHES" ]; then
    echo "固定root経由の実行部 ${launches} 行が絶対下限 ${MIN_HANDOFF_LAUNCHES} 行を下回りました — 名簿が縮んでいます" >&2
    return 1
  fi
  HANDOFF_LAUNCH_COUNT="$launches"
  [ "$fail" -eq 0 ]
}

echo ""
echo "== 固定root経由の実行部のhandoff検査 =="
HANDOFF_LAUNCH_COUNT=0
handoff_launch_files "$PLUGIN_ROOT" | sort > "$TMP/handoff-live-list"
if check_exec_handoff "$TMP/handoff-live-list"; then
  ok "固定root経由で同梱scriptを起動する実行部は同じ行でhandoffを渡す（${HANDOFF_LAUNCH_COUNT} 行）"
else
  bad "handoffを運ばない実行部があります"
fi

# negative control。1 行から handoff 代入を落とすと赤になること。母集団の下限は fixture では
# 成立しないので、subshell で下げてから当てる（live の床は上のまま）。
mkdir -p "$TMP/handoff-fixture"
cp "$PLUGIN_ROOT/skills/merge-cleanup/SKILL.md" "$TMP/handoff-fixture/a.md"
cp "$PLUGIN_ROOT/skills/close-issue/SKILL.md" "$TMP/handoff-fixture/b.md"
find "$TMP/handoff-fixture" -name '*.md' -type f | sort > "$TMP/handoff-fixture-list"
if ( MIN_HANDOFF_LAUNCHES=1; check_exec_handoff "$TMP/handoff-fixture-list" >/dev/null 2>&1 ); then
  ok "positive control: 無変異のhandoff fixtureは検査を通る"
else
  bad "positive control: 無変異のhandoff fixtureが落ちました（以降の negative control は根拠になりません）"
fi
perl -0pi -e 's/^FF_DEV_TOOLKIT_ROOT="\$\{FF_DEV_TOOLKIT_ROOT\}" bash "\$\{FF_DEV_TOOLKIT_ROOT\}\/scripts\/merge-cleanup\.sh"/bash "\${FF_DEV_TOOLKIT_ROOT}\/scripts\/merge-cleanup.sh"/m' \
  "$TMP/handoff-fixture/a.md"
if cmp -s "$PLUGIN_ROOT/skills/merge-cleanup/SKILL.md" "$TMP/handoff-fixture/a.md"; then
  bad "negative control: handoff削除の変異が適用されませんでした（検査結果は根拠になりません）"
elif ( MIN_HANDOFF_LAUNCHES=1; check_exec_handoff "$TMP/handoff-fixture-list" >/dev/null 2>&1 ); then
  bad "negative control: handoffを落とした実行部を見逃しました"
else
  ok "negative control: 実行部からhandoff代入を落とせば拒否する"
fi
# 変数経由の起動（`bash \"\${JUDGE}\"`）からも落とせば赤になること。
cp "$PLUGIN_ROOT/skills/merge-cleanup/SKILL.md" "$TMP/handoff-fixture/a.md"
perl -0pi -e 's/FF_DEV_TOOLKIT_ROOT="\$\{FF_DEV_TOOLKIT_ROOT\}" bash "\$JUDGE"/bash "\$JUDGE"/' \
  "$TMP/handoff-fixture/b.md"
if cmp -s "$PLUGIN_ROOT/skills/close-issue/SKILL.md" "$TMP/handoff-fixture/b.md"; then
  bad "negative control: 変数経由のhandoff削除が適用されませんでした（検査結果は根拠になりません）"
elif ( MIN_HANDOFF_LAUNCHES=1; check_exec_handoff "$TMP/handoff-fixture-list" >/dev/null 2>&1 ); then
  bad "negative control: 変数経由の起動からhandoffを落としたのを見逃しました"
else
  ok "negative control: 固定root経由のpathを受けた変数での起動もhandoffを要求する"
fi
# 代入を同じ行のコメントへ退避させる変異。行全体への部分一致では「行のどこかに代入がある」
# ため緑のままになり、起動している側が素の `bash "${ROOT}/scripts/…"` でも通ってしまう。
cp "$PLUGIN_ROOT/skills/merge-cleanup/SKILL.md" "$TMP/handoff-fixture/a.md"
cp "$PLUGIN_ROOT/skills/close-issue/SKILL.md" "$TMP/handoff-fixture/b.md"
perl -0pi -e 's/^FF_DEV_TOOLKIT_ROOT="\$\{FF_DEV_TOOLKIT_ROOT\}" bash "\$\{FF_DEV_TOOLKIT_ROOT\}\/scripts\/merge-cleanup\.sh"(.*)$/bash "\${FF_DEV_TOOLKIT_ROOT}\/scripts\/merge-cleanup.sh"$1  # FF_DEV_TOOLKIT_ROOT="\${FF_DEV_TOOLKIT_ROOT}" を同じ行へ載せること/m' \
  "$TMP/handoff-fixture/a.md"
if cmp -s "$PLUGIN_ROOT/skills/merge-cleanup/SKILL.md" "$TMP/handoff-fixture/a.md"; then
  bad "negative control: 代入のコメント退避が適用されませんでした（検査結果は根拠になりません）"
elif ( MIN_HANDOFF_LAUNCHES=1; check_exec_handoff "$TMP/handoff-fixture-list" >/dev/null 2>&1 ); then
  bad "negative control: 代入を同じ行のコメントへ移した実行部を見逃しました"
else
  ok "negative control: 代入が起動トークンの直前に無ければ（同じ行のコメントにあっても）拒否する"
fi

# ---- ガードの実走（fixture 実行） ------------------------------------------
# 静的検査だけでは「書いてあるが効かない」を排除できない。plugin root が消えた状態で
# 同梱scriptを直接起動し、案内付きで非0停止すること・別インストール領域の完全な候補が
# あっても切り替えないことを実測する。
#
# 実走は必ず `--help`（+ stdin を閉じる）で起動する。ガードが壊れて素通しになったときに
# 本来の破壊的処理が走らないようにするため — この suite 自身が「ガードが効かない前提」で
# 書かれていなければならない。
RUN_ROOT="$TMP/script-guard-run"
make_run_fixture() {
  local dest="$1" name
  mkdir -p "$dest/scripts" "$dest/.claude-plugin"
  cp "$PLUGIN_ROOT/.claude-plugin/plugin.json" "$dest/.claude-plugin/plugin.json"
  for name in $ROOT_SCRIPT_NAMES; do
    [ -f "$PLUGIN_ROOT/scripts/$name" ] || continue
    cp "$PLUGIN_ROOT/scripts/$name" "$dest/scripts/$name"
  done
}

INSTALLED_ROOT="$RUN_ROOT/host-install/ff-dev-toolkit"
SOURCE_ROOT="$RUN_ROOT/source-checkout/plugins/ff-dev-toolkit"
CACHE_ROOT="$RUN_ROOT/cache-home/.claude/plugins/cache/marketplace/ff-dev-toolkit/9.9.9"
OTHER_ROOT="$RUN_ROOT/other-plugin"
BROKEN_ROOT="$RUN_ROOT/partial-install/ff-dev-toolkit"
NESTED_SELF_ROOT="$RUN_ROOT/nested-name-install/ff-dev-toolkit"
NESTED_OTHER_ROOT="$RUN_ROOT/nested-name-other"
CDPATH_DECOY="$RUN_ROOT/cdpath-decoy"
make_run_fixture "$INSTALLED_ROOT"
make_run_fixture "$SOURCE_ROOT"
make_run_fixture "$CACHE_ROOT"
make_run_fixture "$BROKEN_ROOT"
make_run_fixture "$NESTED_SELF_ROOT"
# 更新中の部分的な消失。directory は残ったまま manifest だけが読めない状態。
rm -f "$BROKEN_ROOT/.claude-plugin/plugin.json"
mkdir -p "$OTHER_ROOT/.claude-plugin"
printf '%s\n' '{' '  "name": "another-plugin",' '  "version": "1.0.0"' '}' \
  >"$OTHER_ROOT/.claude-plugin/plugin.json"
# manifest の `name` を「最初に現れる name 行」で読むと、`author` が top-level `name` より前に
# ある manifest で `author.name` を掴む。同じ ff-dev-toolkit の**別インストール領域**を
# 「別plugin」と誤読して照合ごと飛ばす形（fail-open）と、その逆（別 plugin の入れ子 name を
# 自分のものと読んで正規の他plugin呼び出しを止める形）の両方を fixture で固定する。
printf '%s\n' '{' '  "author": {' '    "name": "FeelFlow Inc.",' '    "url": "https://example.com"' '  },' \
  '  "name": "ff-dev-toolkit",' '  "version": "9.9.9"' '}' \
  >"$NESTED_SELF_ROOT/.claude-plugin/plugin.json"
mkdir -p "$NESTED_OTHER_ROOT/.claude-plugin"
printf '%s\n' '{' '  "author": {' '    "name": "ff-dev-toolkit"' '  },' \
  '  "name": "another-plugin",' '  "version": "1.0.0"' '}' \
  >"$NESTED_OTHER_ROOT/.claude-plugin/plugin.json"
# CDPATH の decoy。`scripts` という同名 subdirectory を持たせると、`cd -P -- scripts` が
# ここへ移動し、移動先を stdout へ出す（= 相対起動で自分の位置を取り違える）。
mkdir -p "$CDPATH_DECOY/scripts"
# 「別インストール領域の実体が走ってしまった」ことを検出する印。走らなければ作られない。
CACHE_MARKER="$RUN_ROOT/cache-ran"
printf '%s\n' '#!/usr/bin/env bash' "touch \"$CACHE_MARKER\"" \
  >"$CACHE_ROOT/scripts/merge-cleanup.sh"
# host が名指しした root ごと消す（2026-09-10 に起きた形）。
rm -rf "$INSTALLED_ROOT"

run_script_guard_exec() {
  # $1: label / $2: 期待 exit / $3: 期待する出力の針 / $4: log / 以降: 実行コマンド
  local label="$1" expect="$2" needle="$3" log="$4" rc=0
  shift 4
  ( "$@" ) >"$log" 2>&1 </dev/null || rc=$?
  if [ "$rc" -ne "$expect" ]; then
    bad "$label — exit ${rc}、期待 ${expect}"
    sed -n '1,20p' "$log" >&2 || true
    return 0
  fi
  if ! grep -qF "$needle" "$log"; then
    bad "$label — 期待した案内がありません: $needle"
    sed -n '1,20p' "$log" >&2 || true
    return 0
  fi
  ok "$label (exit $rc)"
}

# 全対象を同じ形で実走する。1〜2 本だけの実走では、残る対象の rc 契約と衝突する誤番号や、
# 複製のずれで「案内が出ない 1 本」が残っていても見えない。
run_all_fail=0
run_all_count=0
for name in $ROOT_SCRIPT_NAMES; do
  [ -f "$SOURCE_ROOT/scripts/$name" ] || continue
  expect_rc="$(script_expect_rc "$name")" || expect_rc=""
  if [ -z "$expect_rc" ]; then
    bad "実走: $name の期待rcがSCRIPT_EXPECT_RCにありません"
    run_all_fail=1
    continue
  fi
  rc=0
  ( env HOME="$RUN_ROOT/cache-home" FF_DEV_TOOLKIT_ROOT="$INSTALLED_ROOT" \
      bash "$SOURCE_ROOT/scripts/$name" --help ) >"$RUN_ROOT/all-$name.log" 2>&1 </dev/null || rc=$?
  run_all_count=$((run_all_count + 1))
  if [ "$rc" -ne "$expect_rc" ]; then
    bad "実走: $name — exit ${rc}、期待 ${expect_rc}"
    sed -n '1,10p' "$RUN_ROOT/all-$name.log" >&2 || true
    run_all_fail=1
  elif ! grep -qF 'ff-dev-toolkit更新後にこのskillを再呼び出してください' "$RUN_ROOT/all-$name.log"; then
    bad "実走: $name — 期待した案内がありません"
    sed -n '1,10p' "$RUN_ROOT/all-$name.log" >&2 || true
    run_all_fail=1
  fi
done
if [ "$run_all_count" -lt "$MIN_GUARDED_SCRIPTS" ]; then
  bad "実走: 対象 ${run_all_count} 件が絶対下限 ${MIN_GUARDED_SCRIPTS} 件を下回りました"
elif [ "$run_all_fail" -eq 0 ]; then
  ok "全 ${run_all_count} 本が消えたrootで期待rcと案内つきに停止する（rcはSCRIPT_EXPECT_RCの表）"
fi

run_script_guard_exec "消えたrootをFF_DEV_TOOLKIT_ROOTが指したまま別実体を直接起動すると停止" \
  1 'ff-dev-toolkit更新後にこのskillを再呼び出してください' "$RUN_ROOT/vanished-fixed.log" \
  env HOME="$RUN_ROOT/cache-home" FF_DEV_TOOLKIT_ROOT="$INSTALLED_ROOT" \
  bash "$SOURCE_ROOT/scripts/merge-cleanup.sh" --help
run_script_guard_exec "同じ停止の案内にfallback禁止の理由（version混在・未リリースWIP）が入る" \
  1 'version混在と未リリースWIPの実行になります' "$RUN_ROOT/vanished-fixed-reason.log" \
  env HOME="$RUN_ROOT/cache-home" FF_DEV_TOOLKIT_ROOT="$INSTALLED_ROOT" \
  bash "$SOURCE_ROOT/scripts/merge-cleanup.sh" --help
run_script_guard_exec "消えたrootをCLAUDE_PLUGIN_ROOTが指す場合も停止" \
  1 'plugin rootが消えています' "$RUN_ROOT/vanished-host.log" \
  env HOME="$RUN_ROOT/cache-home" CLAUDE_PLUGIN_ROOT="$INSTALLED_ROOT" \
  bash "$SOURCE_ROOT/scripts/merge-cleanup.sh" --help
run_script_guard_exec "実在する別インストール領域を指すhandoffも停止" \
  1 '別のインストール領域の実体です' "$RUN_ROOT/other-install.log" \
  env HOME="$RUN_ROOT/cache-home" CLAUDE_PLUGIN_ROOT="$CACHE_ROOT" \
  bash "$SOURCE_ROOT/scripts/merge-cleanup.sh" --help
if [ -e "$CACHE_MARKER" ]; then
  bad "停止したはずの経路でcacheの別実体が実行されました"
else
  ok "停止時にcache/marketplaceの完全な候補へ切り替えていない（候補を走査しない）"
fi

# 部分劣化した install（directory は残り manifest だけ読めない）。判定材料が壊れた領域の
# 内側にあるので「別 plugin だから対象外」とは言えない。判定不能は停止へ倒す。
run_script_guard_exec "manifestを読めない実在rootは素通しせず停止する（fail-closed）" \
  1 '誰のrootか判定できません' "$RUN_ROOT/partial-install.log" \
  env HOME="$RUN_ROOT/cache-home" FF_DEV_TOOLKIT_ROOT="$BROKEN_ROOT" \
  bash "$SOURCE_ROOT/scripts/merge-cleanup.sh" --help
# manifest が symlink・非通常ファイルでも同じ（「読めて別名だと確認できた」以外は停止）。
mkdir -p "$RUN_ROOT/symlink-manifest/ff-dev-toolkit/.claude-plugin"
ln -s "$OTHER_ROOT/.claude-plugin/plugin.json" \
  "$RUN_ROOT/symlink-manifest/ff-dev-toolkit/.claude-plugin/plugin.json"
run_script_guard_exec "manifestがsymlinkのrootも別pluginとみなさず停止する" \
  1 '誰のrootか判定できません' "$RUN_ROOT/symlink-manifest.log" \
  env HOME="$RUN_ROOT/cache-home" FF_DEV_TOOLKIT_ROOT="$RUN_ROOT/symlink-manifest/ff-dev-toolkit" \
  bash "$SOURCE_ROOT/scripts/merge-cleanup.sh" --help

# 期待 root の内側に置いた symlink から、別 checkout の実体を実行する形。親 directory しか
# canonical 化しないと handoff は一致してしまい、「実体位置と handoff の照合」が成立しない。
mkdir -p "$RUN_ROOT/symlink-install/ff-dev-toolkit/scripts" "$RUN_ROOT/symlink-install/ff-dev-toolkit/.claude-plugin"
cp "$PLUGIN_ROOT/.claude-plugin/plugin.json" "$RUN_ROOT/symlink-install/ff-dev-toolkit/.claude-plugin/plugin.json"
ln -s "$SOURCE_ROOT/scripts/merge-cleanup.sh" "$RUN_ROOT/symlink-install/ff-dev-toolkit/scripts/merge-cleanup.sh"
run_script_guard_exec "期待root内のsymlinkから別checkoutの実体を実行する形も停止" \
  1 '起動したスクリプトがsymlinkです' "$RUN_ROOT/symlink-self.log" \
  env HOME="$RUN_ROOT/cache-home" FF_DEV_TOOLKIT_ROOT="$RUN_ROOT/symlink-install/ff-dev-toolkit" \
  bash "$RUN_ROOT/symlink-install/ff-dev-toolkit/scripts/merge-cleanup.sh" --help

# 入れ子の `name` を先に持つ manifest。top-level は `ff-dev-toolkit` なので、これは
# 「別 plugin」ではなく**別インストール領域の同じ plugin** であり、停止でなければならない。
# 旧実装は `author.name` を掴んで「照合対象外: 別plugin(FeelFlow Inc.)」とし、そのまま
# 後続処理へ進んでいた（1 巡目で fail-closed にした経路が別の入口から素通しに戻っていた形）。
run_script_guard_exec "入れ子のnameが先にある実在rootも別plugin扱いせず停止する" \
  1 '別のインストール領域の実体です' "$RUN_ROOT/nested-name-install.log" \
  env HOME="$RUN_ROOT/cache-home" FF_DEV_TOOLKIT_ROOT="$NESTED_SELF_ROOT" \
  bash "$SOURCE_ROOT/scripts/merge-cleanup.sh" --help

# 「止めない」側は前提コマンドを持たない入口で測る。merge-cleanup.sh の `mktemp -d` /
# `command -v gh` / `command -v jq` は引数検査より**前**にあり、いずれも別文言の die（exit 1）に
# なるので、`gh` / `jq` が無い runner ではガードと無関係に赤くなる。`workflow-tier.sh --list-rules`
# は外部コマンドを要求せず、stdout の判定規則と exit 0 で「本来の処理へ到達した」ことを示す。
run_script_guard_exec "正規のhandoff（同じ実体）は止めない" \
  0 'RULE=1|full|' "$RUN_ROOT/valid-handoff.log" \
  env FF_DEV_TOOLKIT_ROOT="$SOURCE_ROOT" bash "$SOURCE_ROOT/scripts/workflow-tier.sh" --list-rules
# `scripts/` を直接指す綴りも正規に受理されている（templates/codex-review.sh が両方を受ける）。
run_script_guard_exec "handoffがscripts/を直接指す綴りでも止めない" \
  0 'RULE=1|full|' "$RUN_ROOT/scripts-spelling.log" \
  env FF_DEV_TOOLKIT_ROOT="$SOURCE_ROOT/scripts" bash "$SOURCE_ROOT/scripts/workflow-tier.sh" --list-rules
run_script_guard_exec "handoffなしの直接起動も止めない" \
  0 'RULE=1|full|' "$RUN_ROOT/no-handoff.log" \
  env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT \
  bash "$SOURCE_ROOT/scripts/workflow-tier.sh" --list-rules
run_script_guard_exec "別pluginのhandoffでは止めない（照合対象外）" \
  0 'RULE=1|full|' "$RUN_ROOT/other-plugin.log" \
  env CLAUDE_PLUGIN_ROOT="$OTHER_ROOT" bash "$SOURCE_ROOT/scripts/workflow-tier.sh" --list-rules
# 入れ子の `name` が `ff-dev-toolkit` でも、top-level が別名なら別 plugin である（逆向きの穴）。
run_script_guard_exec "入れ子のnameが自分の名前でもtop-levelが別名なら別plugin扱い（止めない）" \
  0 'RULE=1|full|' "$RUN_ROOT/nested-name-other.log" \
  env CLAUDE_PLUGIN_ROOT="$NESTED_OTHER_ROOT" bash "$SOURCE_ROOT/scripts/workflow-tier.sh" --list-rules
if grep -qF '照合対象外: CLAUDE_PLUGIN_ROOT=別plugin(another-plugin)' "$RUN_ROOT/nested-name-other.log"; then
  ok "入れ子のnameではなくtop-levelのnameを別plugin判定に使う"
else
  bad "別plugin判定が入れ子のnameを読んでいます"
  sed -n '1,5p' "$RUN_ROOT/nested-name-other.log" >&2 || true
fi

# CDPATH が export された環境での相対起動。`cd -P -- "$dir"` は CDPATH を見て別 directory へ
# 移動し、移動先を stdout へ出すため、正規の handoff 付きでも「自分のplugin rootを解決できません」
# で止まっていた。明文で「止めない」と約束している端末・テスト・CI の直接起動そのものである。
run_script_guard_exec "CDPATHがexportされていても正規の相対起動は止めない" \
  0 'RULE=1|full|' "$RUN_ROOT/cdpath-relative.log" \
  bash -c 'cd "$1" || exit 9; CDPATH="$2" FF_DEV_TOOLKIT_ROOT="$1" bash scripts/workflow-tier.sh --list-rules' \
  _ "$SOURCE_ROOT" "$CDPATH_DECOY"
# 上のケースが CDPATH の無効化を測っていることの裏取り。`CDPATH= ` を外した複製では同じ起動が
# 通らないこと（= ケースが検出力を持つこと）を実測する。
CDPATH_MUTANT_ROOT="$RUN_ROOT/cdpath-mutant/plugins/ff-dev-toolkit"
make_run_fixture "$CDPATH_MUTANT_ROOT"
perl -0pi -e 's/CDPATH= cd -P -- /cd -P -- /g' "$CDPATH_MUTANT_ROOT/scripts/workflow-tier.sh"
if cmp -s "$SOURCE_ROOT/scripts/workflow-tier.sh" "$CDPATH_MUTANT_ROOT/scripts/workflow-tier.sh"; then
  bad "negative control: CDPATH無効化の除去が適用されませんでした（CDPATHケースは根拠になりません）"
else
  cdpath_mutant_rc=0
  ( cd "$CDPATH_MUTANT_ROOT" && CDPATH="$CDPATH_DECOY" FF_DEV_TOOLKIT_ROOT="$CDPATH_MUTANT_ROOT" \
      bash scripts/workflow-tier.sh --list-rules ) \
    >"$RUN_ROOT/cdpath-mutant.log" 2>&1 </dev/null || cdpath_mutant_rc=$?
  if [ "$cdpath_mutant_rc" -eq 0 ] && grep -qF 'RULE=1|full|' "$RUN_ROOT/cdpath-mutant.log"; then
    bad "negative control: CDPATH無効化を外しても同じ相対起動が通りました（CDPATHケースは何も測っていません）"
  else
    ok "negative control: CDPATH無効化を外すと同じ相対起動が本来の処理へ到達しない（CDPATHケースの検出力の裏取り）"
  fi
fi
# 照合を飛ばした handoff は「なし・直接起動」にしない。渡っていた事実を消すと診断価値を
# 損ない、事実とも食い違う。
if grep -qF '照合対象外: CLAUDE_PLUGIN_ROOT=別plugin(another-plugin)' "$RUN_ROOT/other-plugin.log"; then
  ok "provenanceが照合を飛ばしたhandoffと理由を1行に含める"
else
  bad "provenanceが照合を飛ばしたhandoffを報告していません"
  sed -n '1,5p' "$RUN_ROOT/other-plugin.log" >&2 || true
fi

# provenance の完全一致。部分一致だと version も実体 path も「1 行である」ことも検証していない
# （旧実装の針は plugin version の先頭桁に依存していて、1.0.0 で偽赤になる形だった）。
PLUGIN_VERSION="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$PLUGIN_ROOT/.claude-plugin/plugin.json" | head -1)"
if [ -z "$PLUGIN_VERSION" ]; then
  bad "provenance検査: plugin manifestからversionを読めませんでした（検査は成立していない）"
else
  ( env FF_DEV_TOOLKIT_ROOT="$SOURCE_ROOT" bash "$SOURCE_ROOT/scripts/merge-cleanup.sh" ) \
    >"$RUN_ROOT/provenance.log" 2>&1 </dev/null || true
  # provenance は実体位置（`cd -P` + `pwd -P`）を出すので、期待値も同じ正規化を通す。
  # mktemp -d は macOS では symlink を含む path を返すため、素の $SOURCE_ROOT とは一致しない。
  SOURCE_ROOT_REAL="$(cd -P "$SOURCE_ROOT" && pwd -P)"
  PROVENANCE_EXPECTED="ℹ️  ff-dev-toolkit ${PLUGIN_VERSION} — 実行実体: ${SOURCE_ROOT_REAL}/scripts/merge-cleanup.sh（handoff: FF_DEV_TOOLKIT_ROOT）"
  provenance_hits="$(grep -cFx "$PROVENANCE_EXPECTED" "$RUN_ROOT/provenance.log" || true)"
  if [ "$provenance_hits" -eq 1 ]; then
    ok "起動時のprovenanceが manifest version + 実体絶対path + handoff名 の完全な1行として出る"
  else
    bad "provenanceの完全一致が ${provenance_hits} 件（期待 1 件）"
    printf '    期待: %s\n' "$PROVENANCE_EXPECTED" >&2
    sed -n '1,5p' "$RUN_ROOT/provenance.log" >&2 || true
  fi
fi

# provenance を抑止している script でも、停止と案内は同じであること（抑止できるのは
# 情報行だけで、判定は抑止できない）。
run_script_guard_exec "provenance抑止側のscriptも消えたrootで停止する" \
  3 'ff-dev-toolkit更新後にこのskillを再呼び出してください' "$RUN_ROOT/quiet-stop.log" \
  env FF_DEV_TOOLKIT_ROOT="$INSTALLED_ROOT" \
  bash "$SOURCE_ROOT/scripts/check-merge-freshness.sh" --print-record
if grep -q 'ℹ️' "$RUN_ROOT/quiet-stop.log"; then
  bad "provenance抑止を宣言したscriptが情報行を出しました"
else
  ok "provenance抑止の宣言は情報行だけを止める（停止の案内は出る）"
fi

# 抑止は script 内部の allowlist に閉じている。外部から環境変数を渡しても抑止できない
# （渡せると、allowlist 外の script でも抑止できて allowlist が実効的な制約にならない）。
( env FF_SCRIPT_ROOT_GUARD_QUIET=1 FF_DEV_TOOLKIT_ROOT="$SOURCE_ROOT" \
    bash "$SOURCE_ROOT/scripts/merge-cleanup.sh" ) >"$RUN_ROOT/env-quiet.log" 2>&1 </dev/null || true
if grep -qF '実行実体: ' "$RUN_ROOT/env-quiet.log"; then
  ok "外部からの環境変数ではprovenanceを抑止できない（allowlistがscript内部に閉じている）"
else
  bad "外部の環境変数でprovenanceが抑止されました（allowlistが実効的な制約になっていません）"
fi

# 実走ケースの negative control。ガードの呼び出し行を落とした複製では、同じ起動が
# 案内付きの停止にならないこと（= 上のケースがガードを測っていること）を実測する。
# 「案内が出ない」だけでは別の初期エラーでも positive になるので、後続処理へ到達した印
# （`--list-rules` の stdout 契約）と、その終了コードも併せて確認する。到達の印にも
# `gh` / `jq` を要求しない入口を使う（要求する入口だと、前提の無い runner で「到達していない」
# と出て negative control 側が偽赤になる）。
MUTANT_ROOT="$RUN_ROOT/mutant-checkout/plugins/ff-dev-toolkit"
make_run_fixture "$MUTANT_ROOT"
perl -0pi -e 's/^ff_assert_script_plugin_root "\$\{BASH_SOURCE\[0\]\}" \|\| exit [0-9]+\n//m' \
  "$MUTANT_ROOT/scripts/workflow-tier.sh"
if cmp -s "$SOURCE_ROOT/scripts/workflow-tier.sh" "$MUTANT_ROOT/scripts/workflow-tier.sh"; then
  bad "negative control: 実走用の呼び出し行削除が適用されませんでした（実走ケースは根拠になりません）"
else
  mutant_rc=0
  ( env HOME="$RUN_ROOT/cache-home" FF_DEV_TOOLKIT_ROOT="$INSTALLED_ROOT" \
      bash "$MUTANT_ROOT/scripts/workflow-tier.sh" --list-rules ) \
    >"$RUN_ROOT/mutant.log" 2>&1 </dev/null || mutant_rc=$?
  if grep -qF 'ff-dev-toolkit更新後にこのskillを再呼び出してください' "$RUN_ROOT/mutant.log"; then
    bad "negative control: ガードを外しても停止の案内が出ました（実走ケースはガードを測っていません）"
  elif [ "$mutant_rc" -ne 0 ] || ! grep -qF 'RULE=1|full|' "$RUN_ROOT/mutant.log"; then
    bad "negative control: ガードを外した起動が後続処理へ到達していません（rc=${mutant_rc}。別の初期エラーで止まった可能性）"
    sed -n '1,10p' "$RUN_ROOT/mutant.log" >&2 || true
  else
    ok "negative control: ガードを外すと同じ起動が案内なしで後続処理（判定規則の出力）まで進む（実走ケースの検出力の裏取り）"
  fi
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ plugin-root-contract verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ plugin-root-contract verify: 全 ${PASS} 件 pass"
FF_REACHED_END=1
