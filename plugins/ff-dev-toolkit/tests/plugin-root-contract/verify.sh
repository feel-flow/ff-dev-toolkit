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

# ---- node entry 側 plugin rootガード ----------------------------------------
# 共通の shell ガードを挿入できない入口（node entry）。穴の形は同じなので、同じ判定・同じ案内
# 文言を JS で複製し、shell 側と同じ「marker各1件 → canonical一致 → 期待rc → 必須句 → 禁止句 →
# 配置」の順で見る。**案内文言の正本は shell ガード block ただ 1 つ**で、node 側の写しは後半の
# 実走同値照合（同じ fixture で shell と node を走らせ、案内の本文が 1 行も違わないことを assert
# する）が縛る。ソース文字列どうしの比較にしないのは、`${var:-既定}` のような言語ごとの綴りを
# 吸収する正規化規則そのものが第 3 の正本になるためで、consumer が実際に読む出力の側で同値を
# 要求する。

# 実行時ガードの対象外（`entry名|理由`）。黙って母集団から落とさないため理由付きで登録し、
# 報告にも出す。現在は 0 件。
NODE_GUARD_EXEMPT=()

# 中断コード（`entry名|rc`）。node entry は `main()` の異常と判定結果の双方を 1 で返すので、
# ガードの停止を 1 にすると「本来の処理が走って 1 を返した」と区別できない。2 を割り当てて
# 表で固定し、静的検査と実走の両方で照合する。
NODE_EXPECT_RC=(
  "asdd/cli.mjs|2"
  "asdd/work.mjs|2"
)

# 崩壊床（絶対下限）。shell 側（MIN_ROOT_SCRIPTS / MIN_GUARDED_SCRIPTS）と同じ規律で、抽出から
# 導いた量ではなく入力から独立した絶対値を置く。node entry を意図的に減らすときだけ下げる。
MIN_ROOT_NODE_ENTRIES=2
MIN_GUARDED_NODE_ENTRIES=2

node_guard_exempt_reason() {
  local name="$1" entry
  [ "${#NODE_GUARD_EXEMPT[@]}" -gt 0 ] || return 0
  for entry in "${NODE_GUARD_EXEMPT[@]}"; do
    case "$entry" in
      "$name"'|'*) printf '%s' "${entry#*|}"; return 0 ;;
    esac
  done
  return 0
}

node_expect_rc() {
  local name="$1" entry
  for entry in "${NODE_EXPECT_RC[@]}"; do
    case "$entry" in
      "$name"'|'*) printf '%s' "${entry#*|}"; return 0 ;;
    esac
  done
  return 1
}

# 母集団は shell 側と同じく呼び出し側から導く（`${FF_DEV_TOOLKIT_ROOT}/scripts/<path>.mjs`）。
# `scripts/` 直下とは限らないので basename ではなく `scripts/` 以降の相対 path を名前にする。
# 綴りは shell 側と同じく 3 つの root 変数名・修飾付き parameter expansion・brace 無しを拾う。
derive_root_node_entries() {
  { grep -rhoE '\$\{?(FF_DEV_TOOLKIT_ROOT|CLAUDE_PLUGIN_ROOT|GROK_PLUGIN_ROOT)(:[-?+=][^}]*)?\}?/scripts/[A-Za-z0-9_./-]+\.mjs' \
      "$@" 2>/dev/null || true; } \
    | sed 's|.*/scripts/||' | sort -u
}

ROOT_NODE_ENTRY_NAMES="$(derive_root_node_entries "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/docs-template")"

check_node_guards() {
  local scripts_dir="$1"
  local name file reason starts ends block norm required forbidden expect_rc actual_rc
  local guard_start_ln prelude
  local canonical="" population=0 guarded=0 tree_fail=0

  for name in $ROOT_NODE_ENTRY_NAMES; do
    population=$((population + 1))
    reason="$(node_guard_exempt_reason "$name")"
    [ -z "$reason" ] || continue
    file="$scripts_dir/$name"
    if [ ! -f "$file" ]; then
      echo "$name: 固定root経由で呼ばれる同梱node entryが実在しません: $file" >&2
      tree_fail=1
      continue
    fi
    guarded=$((guarded + 1))

    starts="$(grep -Fc '// ff-dev-toolkit-node-root-guard:start' "$file" || true)"
    ends="$(grep -Fc '// ff-dev-toolkit-node-root-guard:end' "$file" || true)"
    if [ "$starts" -ne 1 ] || [ "$ends" -ne 1 ]; then
      echo "$name: node側ガードのmarkerはstart/end各1件が必要です" >&2
      tree_fail=1
      continue
    fi

    block="$(sed -n '\%// ff-dev-toolkit-node-root-guard:start%,\%// ff-dev-toolkit-node-root-guard:end%p' "$file")"
    # 中断コードだけを正規化して canonical 比較する（shell 側と同じ理由。正規化で見えなくなった
    # 数字は下の期待rc表で名指しして別に固定する）。
    norm="$(printf '%s\n' "$block" | sed 's/process\.exit([0-9][0-9]*)/process.exit(<中断コード>)/')"
    if [ -z "$canonical" ]; then
      canonical="$norm"
    elif [ "$norm" != "$canonical" ]; then
      echo "$name: node側ガードが他のnode entryと一致しません" >&2
      tree_fail=1
    fi

    if ! expect_rc="$(node_expect_rc "$name")"; then
      echo "$name: 期待rcがNODE_EXPECT_RCにありません（新しい入口はrc契約も同時に決めること）" >&2
      tree_fail=1
    else
      actual_rc="$(printf '%s\n' "$block" | sed -n 's/^if (!ffGuardAssertPluginRoot(import\.meta\.url)) process\.exit(\([0-9][0-9]*\));$/\1/p' | head -1)"
      if [ "$actual_rc" != "$expect_rc" ]; then
        echo "$name: ガードの中断コードが期待rcと違います（実体 ${actual_rc:-不明} / 期待 ${expect_rc}）" >&2
        tree_fail=1
      fi
    fi

    for required in \
      'if (!ffGuardAssertPluginRoot(import.meta.url)) process.exit(' \
      "for (const name of ['FF_DEV_TOOLKIT_ROOT', 'CLAUDE_PLUGIN_ROOT', 'GROK_PLUGIN_ROOT'])" \
      'ff-dev-toolkit更新後にこのskillを再呼び出してください' \
      'version混在と未リリースWIPの実行になります' \
      'return false;' \
      'if (launchedIsLink) {' \
      'if (!ffGuardLstat(file).isFile()) return ' \
      'launched = process.argv[1] ? ffGuardRealpath(process.argv[1])' \
      'return ffGuardRealpath(ffGuardFromUrl(selfUrl));' \
      "return self !== '' && launched === self;" \
      'dir = ffGuardRealpath(ffGuardDirname(self))' \
      'canonical = ffGuardRealpath(value)' \
      '判定不能は停止に倒します' \
      '別のインストール領域の実体です' \
      '照合対象外'; do
      case "$block" in
        *"$required"*) ;;
        *)
          echo "$name: node側ガードの必須句がありません: $required" >&2
          tree_fail=1
          ;;
      esac
    done

    # 禁止句。root の解決に「候補の走査」が混ざると、防御が防御対象（cache / marketplace /
    # 旧インストール領域を探しに行くこと）を踏む。渡された handoff を canonical 化して自分の
    # 実体位置と比べる以外の探索は静的にも拒否する。provenance 抑止を外部から渡せる形も
    # shell 側と同じ理由で拒否する。
    for forbidden in 'readdirSync' 'opendirSync' 'globSync' 'FF_NODE_ROOT_GUARD_QUIET'; do
      case "$block" in
        *"$forbidden"*)
          echo "$name: node側ガードが候補走査/外部抑止の形を持っています: $forbidden" >&2
          tree_fail=1
          ;;
      esac
    done

    # 直接起動（file 末尾の `main()` 起動）の判定が、ガードと同じ canonical 判定を使うこと。
    # ここだけ素の文字列比較に戻すと、symlink 成分を含む絶対 path から正規の handoff 付きで
    # 起動したときに「ガードは通るのに `main()` が一度も呼ばれない」= 出力なし・exit 0 の
    # 黙った失敗になる（ガードと `main()` で直接起動の基準が割れる）。判定は block の外に
    # あるので、block ではなく file 全体を見る。
    if ! grep -qF 'if (ffGuardIsEntry(import.meta.url)) {' "$file"; then
      echo "$name: 直接起動の判定がガードと同じ ffGuardIsEntry ではありません" >&2
      tree_fail=1
    fi
    if grep -qF 'process.argv[1] === fileURLToPath(import.meta.url)' "$file"; then
      echo "$name: 直接起動の判定に素の文字列比較が残っています（ガードと基準が割れます）" >&2
      tree_fail=1
    fi

    # 配置。ガードより前にあってよいのは shebang / コメント / 空行だけにする。ESM の static
    # import は巻き上げられるので「あらゆる評価より先」は保証できないが（block より下に書いた
    # sibling module の評価は先に起きる。それらの top-level は定義だけで副作用を持たない）、
    # entry 自身の文と `main()` の呼び出しより前であることはここで固定する。
    guard_start_ln="$(grep -n -F '// ff-dev-toolkit-node-root-guard:start' "$file" | head -1 | cut -d: -f1)"
    if [ "$guard_start_ln" -gt 1 ]; then
      prelude="$(sed -n "1,$((guard_start_ln - 1))p" "$file" \
        | grep -Ev '^[[:space:]]*(//|$)|^#!' || true)"
      if [ -n "$prelude" ]; then
        echo "$name: node側ガードより前に実行文があります（起動直後に走る契約が崩れています）" >&2
        tree_fail=1
      fi
    fi
  done

  if [ "$population" -eq 0 ]; then
    echo "固定root経由で呼ばれる同梱node entryの導出が空振りしました" >&2
    return 1
  fi
  if [ "$population" -lt "$MIN_ROOT_NODE_ENTRIES" ]; then
    echo "母集団 ${population} 件が絶対下限 ${MIN_ROOT_NODE_ENTRIES} 件を下回りました — 名簿が縮んでいます（意図的にnode entryを減らしたならMIN_ROOT_NODE_ENTRIESも下げる）" >&2
    return 1
  fi
  if [ "$guarded" -lt "$MIN_GUARDED_NODE_ENTRIES" ]; then
    echo "ガード対象 ${guarded} 件が絶対下限 ${MIN_GUARDED_NODE_ENTRIES} 件を下回りました — NODE_GUARD_EXEMPT が広がりすぎているか名簿が縮んでいます" >&2
    return 1
  fi
  NODE_SCANNED_COUNT="$guarded"
  [ "$tree_fail" -eq 0 ]
}

echo ""
echo "== node entry側 plugin rootガード検査 =="
NODE_SCANNED_COUNT=0
if check_node_guards "$PLUGIN_ROOT/scripts"; then
  ok "固定root経由で呼ばれる同梱node entryは同一のroot照合ガードを冒頭に持つ（検査対象 ${NODE_SCANNED_COUNT} entry）"
else
  bad "liveのnode entry側ガードに違反があります"
fi
if [ "${#NODE_GUARD_EXEMPT[@]}" -eq 0 ]; then
  echo "  - node entry側ガード対象外 allowlist: 0 件"
else
  echo "  - node entry側ガード対象外 allowlist: ${#NODE_GUARD_EXEMPT[@]} 件"
  printf '      %s\n' "${NODE_GUARD_EXEMPT[@]}"
fi

# census の抽出そのものの negative control（shell 側と同型）。修飾付き parameter expansion と
# brace 無し、および `scripts/` 直下でない相対 path を拾えなくなったら赤にする。
mkdir -p "$TMP/node-census-fixture"
{
  printf 'node "${FF_DEV_TOOLKIT_ROOT:?プラグインルートを先に解決すること}/scripts/zz/qualified.mjs"\n'
  printf 'node "${FF_DEV_TOOLKIT_ROOT:-/fallback}/scripts/zz/default.mjs"\n'
  printf 'node "$FF_DEV_TOOLKIT_ROOT/scripts/zz/unbraced.mjs" --flag\n'
  printf 'node "${CLAUDE_PLUGIN_ROOT}/scripts/zz/claude.mjs"\n'
  printf 'node "${GROK_PLUGIN_ROOT}/scripts/zz/grok.mjs"\n'
} > "$TMP/node-census-fixture/sample.md"
node_census_out="$(derive_root_node_entries "$TMP/node-census-fixture" | tr '\n' ' ')"
node_census_missing=""
for name in zz/qualified.mjs zz/default.mjs zz/unbraced.mjs zz/claude.mjs zz/grok.mjs; do
  case " $node_census_out " in
    *" $name "*) ;;
    *) node_census_missing="${node_census_missing} ${name}" ;;
  esac
done
if [ -n "$node_census_missing" ]; then
  bad "census(node): 修飾付き/brace無し/入れ子pathのroot参照を取りこぼしました:${node_census_missing}"
else
  ok "census(node): \${VAR:?…} / \${VAR:-…} / \$VAR / 3つのroot変数名と入れ子pathから入口を導出する"
fi

# live の名簿に 2 resource が入っていること（回帰ピン）。
node_census_live_missing=""
for name in asdd/cli.mjs asdd/work.mjs; do
  case " $(printf '%s ' $ROOT_NODE_ENTRY_NAMES) " in
    *" $name "*) ;;
    *) node_census_live_missing="${node_census_live_missing} ${name}" ;;
  esac
done
if [ -n "$node_census_live_missing" ]; then
  bad "census(node): liveのnode entryが名簿にありません:${node_census_live_missing}"
else
  ok "census(node): liveのnode entry 2 件が母集団に入る（母集団 $(printf '%s\n' $ROOT_NODE_ENTRY_NAMES | wc -l | tr -d ' ') 件）"
fi

# 崩壊床の実測。呼び出し側から名簿が丸ごと消える／1 件へ縮む変異で、同じ live tree を見たまま
# 赤になること。床を抽出から導いた量に置くと、この 2 つは部分集合を自分自身と比べるだけになって
# 検出できない。
mkdir -p "$TMP/node-census-empty"
printf '%s\n' 'node entry を呼ばない散文だけの tree' > "$TMP/node-census-empty/sample.md"
if ( ROOT_NODE_ENTRY_NAMES="$(derive_root_node_entries "$TMP/node-census-empty")"
     check_node_guards "$PLUGIN_ROOT/scripts" >/dev/null 2>&1 ); then
  bad "崩壊床(node): 名簿が丸ごと空になっても緑のまま通りました"
else
  ok "崩壊床(node): 呼び出し側から名簿が消えると母集団0で赤になる"
fi
mkdir -p "$TMP/node-census-shrunk"
printf 'node "${FF_DEV_TOOLKIT_ROOT}/scripts/asdd/cli.mjs" --check\n' > "$TMP/node-census-shrunk/sample.md"
if ( ROOT_NODE_ENTRY_NAMES="$(derive_root_node_entries "$TMP/node-census-shrunk")"
     check_node_guards "$PLUGIN_ROOT/scripts" >/dev/null 2>&1 ); then
  bad "崩壊床(node): 名簿が 1 件へ縮んでも緑のまま通りました（MIN_ROOT_NODE_ENTRIES が効いていません）"
else
  ok "崩壊床(node): 名簿が 1 件へ縮むと絶対下限 ${MIN_ROOT_NODE_ENTRIES} 件で赤になる"
fi

make_node_fixture() {
  local dest="$1" name
  mkdir -p "$dest"
  for name in $ROOT_NODE_ENTRY_NAMES; do
    [ -f "$PLUGIN_ROOT/scripts/$name" ] || continue
    mkdir -p "$dest/$(dirname "$name")"
    cp "$PLUGIN_ROOT/scripts/$name" "$dest/$name"
  done
}

node_mutate_all() {
  # $1: fixture dir / $2: perl script。全 entry へ同じ変異を当て、適用件数を stdout へ返す。
  # 1 本だけ変異させると canonical 一致の検出器が先に赤くなり、赤の出所を区別できない。
  local dest="$1" program="$2" file rel total=0 applied=0
  for file in "$dest"/*/*.mjs; do
    [ -f "$file" ] || continue
    grep -Fq '// ff-dev-toolkit-node-root-guard:start' "$file" || continue
    total=$((total + 1))
    perl -0pi -e "$program" "$file"
    rel="${file#"$dest"/}"
    cmp -s "$TMP/node-baseline/$rel" "$file" || applied=$((applied + 1))
  done
  printf '%s %s' "$total" "$applied"
}

make_node_fixture "$TMP/node-baseline"
if check_node_guards "$TMP/node-baseline" >/dev/null 2>&1; then
  ok "positive control(node): 無変異のfixtureはガード契約を満たす（以降の非0が変異由来だと言える）"
else
  bad "positive control(node): 無変異のfixtureが落ちました（以降の negative control は根拠になりません）"
fi

make_node_fixture "$TMP/node-missing-marker"
perl -0pi -e 's{// ff-dev-toolkit-node-root-guard:start\n}{}' "$TMP/node-missing-marker/asdd/cli.mjs"
if cmp -s "$TMP/node-baseline/asdd/cli.mjs" "$TMP/node-missing-marker/asdd/cli.mjs"; then
  bad "negative control(node): marker削除の変異が適用されませんでした（検査結果は根拠になりません）"
elif check_node_guards "$TMP/node-missing-marker" >/dev/null 2>&1; then
  bad "negative control(node): node側ガードのmarker欠落を見逃しました"
else
  ok "negative control(node): node側ガードのmarker欠落を拒否する"
fi

# 呼び出し行だけを消す変異（関数定義は残るので marker も canonical も一致したまま）。
make_node_fixture "$TMP/node-uncalled-guard"
perl -0pi -e 's{^if \(!ffGuardAssertPluginRoot\(import\.meta\.url\)\) process\.exit\([0-9]+\);\n}{}m' \
  "$TMP/node-uncalled-guard/asdd/cli.mjs"
if cmp -s "$TMP/node-baseline/asdd/cli.mjs" "$TMP/node-uncalled-guard/asdd/cli.mjs"; then
  bad "negative control(node): 呼び出し行削除の変異が適用されませんでした（検査結果は根拠になりません）"
elif check_node_guards "$TMP/node-uncalled-guard" >/dev/null 2>&1; then
  bad "negative control(node): 定義だけ残してガードを呼ばない退行を見逃しました"
else
  ok "negative control(node): ガードを呼ばない退行を拒否する"
fi

# 一斉弱体化（shell 側と同型）。停止を落として続行させる形。canonical は一致したままなので、
# 赤は必須句検査だけに由来する。
make_node_fixture "$TMP/node-weakened-all"
read -r node_weak_total node_weak_applied <<EOF
$(node_mutate_all "$TMP/node-weakened-all" 's{^if \(!ffGuardAssertPluginRoot\(import\.meta\.url\)\) process\.exit\([0-9]+\);$}{ffGuardAssertPluginRoot(import.meta.url);}m')
EOF
if [ "$node_weak_total" -eq 0 ] || [ "$node_weak_applied" -ne "$node_weak_total" ]; then
  bad "negative control(node): 一斉弱体化の変異が全entryへ適用されませんでした（${node_weak_applied}/${node_weak_total}）"
elif check_node_guards "$TMP/node-weakened-all" >/dev/null 2>&1; then
  bad "negative control(node): 全entryを同じ弱体形へ揃えた退行を見逃しました"
else
  ok "negative control(node): 全entryを同じ弱体形へ揃えても（canonical一致のまま）必須句検査が拒否する（${node_weak_applied} entry）"
fi

# 判定の穴を塞ぐ必須句が一斉に落ちても赤になること（canonical 一致のまま必須句だけが欠ける）。
# symlink 拒否 / manifest の fail-closed / 「library として import されたときは走らない」判定は、
# どれも 1 行の書き換えで静かに戻せる形なので個別に固定する。
for _ncase in \
  'symlink拒否|if \(launchedIsLink\) \{|if (false) {' \
  'manifestのfail-closed|ffGuardLstat\(file\)\.isFile\(\)|true' \
  'entry判定|launched = process\.argv\[1\] \? ffGuardRealpath\(process\.argv\[1\]\)|launched = process.argv[1] ? String(process.argv[1])' \
  'selfのcanonical化|ffGuardRealpath\(ffGuardFromUrl\(selfUrl\)\)|ffGuardFromUrl(selfUrl)'; do
  _nlabel="${_ncase%%|*}"
  _nrest="${_ncase#*|}"
  _nfrom="${_nrest%%|*}"
  _nto="${_nrest#*|}"
  make_node_fixture "$TMP/node-weak-$_nlabel"
  read -r _nw_total _nw_applied <<EOF
$(FF_FROM="$_nfrom" FF_TO="$_nto" node_mutate_all "$TMP/node-weak-$_nlabel" 's/$ENV{FF_FROM}/$ENV{FF_TO}/')
EOF
  if [ "$_nw_total" -eq 0 ] || [ "$_nw_applied" -ne "$_nw_total" ]; then
    bad "negative control(node ${_nlabel}): 変異が全entryへ適用されませんでした（${_nw_applied}/${_nw_total}）"
  elif check_node_guards "$TMP/node-weak-$_nlabel" >/dev/null 2>&1; then
    bad "negative control(node ${_nlabel}): 全entryから同時に落としても見逃しました"
  else
    ok "negative control(node): ${_nlabel}を全entryから同時に落としても拒否する（${_nw_applied} entry）"
  fi
done

# 直接起動の判定だけを素の文字列比較へ戻す変異。ガード block は無傷（canonical 一致も必須句も
# 通る）なので、file 末尾の判定を見る検査だけが検出できる。この形は「ガードは通るのに `main()`
# が呼ばれない」= 出力なし・exit 0 の黙った失敗になる。
make_node_fixture "$TMP/node-raw-entry-compare"
read -r node_raw_total node_raw_applied <<EOF
$(node_mutate_all "$TMP/node-raw-entry-compare" 's!^if \(ffGuardIsEntry\(import\.meta\.url\)\) \{$!if (process.argv[1] === fileURLToPath(import.meta.url)) {!m')
EOF
if [ "$node_raw_total" -eq 0 ] || [ "$node_raw_applied" -ne "$node_raw_total" ]; then
  bad "negative control(node): 直接起動の判定の差し替えが全entryへ適用されませんでした（${node_raw_applied}/${node_raw_total}）"
elif check_node_guards "$TMP/node-raw-entry-compare" >/dev/null 2>&1; then
  bad "negative control(node): 直接起動の判定だけを素の文字列比較へ戻した退行を見逃しました"
else
  ok "negative control(node): 直接起動の判定を素の文字列比較へ戻せば（ガードは無傷でも）拒否する（${node_raw_applied} entry）"
fi

# 候補走査を足す変異。root の解決へ探索が混ざると防御が防御対象を踏む。
make_node_fixture "$TMP/node-scanning-guard"
read -r node_scan_total node_scan_applied <<EOF
$(node_mutate_all "$TMP/node-scanning-guard" 's{^  const version = ffGuardManifestField}{  const candidate = readdirSync(root).sort().pop();\n  const version = ffGuardManifestField}m')
EOF
if [ "$node_scan_total" -eq 0 ] || [ "$node_scan_applied" -ne "$node_scan_total" ]; then
  bad "negative control(node): 候補走査の追加が全entryへ適用されませんでした（${node_scan_applied}/${node_scan_total}）"
elif check_node_guards "$TMP/node-scanning-guard" >/dev/null 2>&1; then
  bad "negative control(node): rootの解決へ候補走査を足したのを見逃しました"
else
  ok "negative control(node): rootの解決に候補走査（readdirSync + 並べ替え）を足せば拒否する（${node_scan_applied} entry）"
fi

# 中断コードの誤番号。canonical 比較は `process.exit(N)` を正規化するので、期待rc表だけが検出できる。
make_node_fixture "$TMP/node-wrong-rc"
perl -0pi -e 's{^if \(!ffGuardAssertPluginRoot\(import\.meta\.url\)\) process\.exit\(2\);$}{if (!ffGuardAssertPluginRoot(import.meta.url)) process.exit(1);}m' \
  "$TMP/node-wrong-rc/asdd/cli.mjs"
if cmp -s "$TMP/node-baseline/asdd/cli.mjs" "$TMP/node-wrong-rc/asdd/cli.mjs"; then
  bad "negative control(node): 中断コード差し替えの変異が適用されませんでした（検査結果は根拠になりません）"
elif check_node_guards "$TMP/node-wrong-rc" >/dev/null 2>&1; then
  bad "negative control(node): 既存rc契約と衝突する中断コードを見逃しました"
else
  ok "negative control(node): 期待rc表と違う中断コードを拒否する"
fi

# canonical 一致の検出器は先頭以外を変えないと発火しない（名簿は sort 済みなので work.mjs を変異させる）。
make_node_fixture "$TMP/node-diverged-guard"
perl -0pi -e 's/version混在と未リリースWIPの実行になります。/更新が間に合わないときは新しい方を使ってよい。/' \
  "$TMP/node-diverged-guard/asdd/work.mjs"
if cmp -s "$TMP/node-baseline/asdd/work.mjs" "$TMP/node-diverged-guard/asdd/work.mjs"; then
  bad "negative control(node): 案内文の変異が適用されませんでした（検査結果は根拠になりません）"
elif check_node_guards "$TMP/node-diverged-guard" >/dev/null 2>&1; then
  bad "negative control(node): node entry間でガードがdivergeした状態を見逃しました"
else
  ok "negative control(node): 一部entryだけガードが異なれば拒否する"
fi

# 配置の negative control。ガードの前に実行文を差し込む。
make_node_fixture "$TMP/node-late-guard"
perl -0pi -e 's{^// ff-dev-toolkit-node-root-guard:start$}{const launchedFrom = process.cwd();\n// ff-dev-toolkit-node-root-guard:start}m' \
  "$TMP/node-late-guard/asdd/cli.mjs"
if cmp -s "$TMP/node-baseline/asdd/cli.mjs" "$TMP/node-late-guard/asdd/cli.mjs"; then
  bad "negative control(node): ガード前への実行文挿入が適用されませんでした（検査結果は根拠になりません）"
elif check_node_guards "$TMP/node-late-guard" >/dev/null 2>&1; then
  bad "negative control(node): ガードより前の実行文を見逃しました"
else
  ok "negative control(node): ガードより前に実行文があれば拒否する"
fi

# 名簿にあるのに実体が無い（入口を消した / 改名した）場合に fail-closed であること、および
# 理由付き allowlist での除外が実際に効くこと。
make_node_fixture "$TMP/node-missing-entry"
rm -f "$TMP/node-missing-entry/asdd/cli.mjs"
if check_node_guards "$TMP/node-missing-entry" >/dev/null 2>&1; then
  bad "negative control(node): 固定root経由で呼ばれるnode entryの消失を見逃しました"
else
  ok "negative control(node): 名簿にある同梱node entryが実在しなければ拒否する"
fi
if (
  NODE_GUARD_EXEMPT+=("asdd/cli.mjs|negative control fixture（liveの判断ではない）")
  MIN_GUARDED_NODE_ENTRIES=$((MIN_GUARDED_NODE_ENTRIES - 1))
  check_node_guards "$TMP/node-missing-entry" >/dev/null 2>&1
); then
  ok "allowlist(node): 理由付きで登録したentryはガード対象外になり緑を保つ"
else
  bad "allowlist(node): 理由付き登録が効かず赤のままです"
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
#
# node entry（`node "${ROOT}/scripts/asdd/<名>.mjs"`）を母集団へ入れた分も含む実数。床を据え置くと
# ちょうどその差だけ余裕が生まれ、node 起動が丸ごと検出対象から落ちても床を通過する（下の
# negative control が、検出外の綴りへ書き換えた live の写しで赤になることを実測する）。
MIN_HANDOFF_LAUNCHES=108

handoff_launch_files() { # <tree root> → 対象 .md を列挙
  find "$1/skills" -name SKILL.md -type f 2>/dev/null
  find "$1/docs-template" -name '*.md' -type f 2>/dev/null
}

check_exec_handoff() {
  local list="$1" file names hits line body fail=0 launches=0
  # 起動トークンの綴り。`bash`/`sh` を挟む形と挟まない形、固定root経由のpathを受けた変数経由の
  # 起動（`names`）をまとめる。`assign` は handoff 代入で、**起動トークンの直前に並ぶ**ことを
  # 求めるために前置する。
  # node entry（`node "${ROOT}/scripts/asdd/<名>.mjs"`）も同じ層の実行部である。shell script だけを
  # 見ると、ガードを入れた入口の半分が handoff 要求の外に残り、「本文が落ちたときに素通しになる」
  # 経路がそのまま残る。path は `scripts/` 直下とは限らないので `/` を含める。
  local root_vars='FF_DEV_TOOLKIT_ROOT|CLAUDE_PLUGIN_ROOT|GROK_PLUGIN_ROOT'
  local root_expr='\$\{?('"$root_vars"')[^}]*\}?/scripts/([A-Za-z0-9_.-]+\.sh|[A-Za-z0-9_./-]+\.mjs)'
  # 代入は「値が何であれ付いていればよい」では足りない。`FF_DEV_TOOLKIT_ROOT="/stale/root" node
  # "${FF_DEV_TOOLKIT_ROOT}/scripts/asdd/cli.mjs"` は行としては代入付きだが、実行するのは現在の
  # root・子へ渡すのは別の root になり、ガードが毎回 exit 2 で止まる（= skill が動かない）退行が
  # 緑のまま通る。許可する形は**起動パスと同じ root 変数を参照する代入**だけにする。変数経由の
  # 起動（`bash "${JUDGE}"`。行に root 変数が現れない）でも、RHS が 3 つの root 変数のいずれかの
  # 参照であることは求める。
  local assign_any='FF_DEV_TOOLKIT_ROOT="\$\{?('"$root_vars"')(:[-?+=][^}]*)?\}?"[[:space:]]+'
  local var anchored_base=""
  for var in FF_DEV_TOOLKIT_ROOT CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT; do
    anchored_base="${anchored_base:+${anchored_base}|}"'FF_DEV_TOOLKIT_ROOT="\$\{?'"$var"'(:[-?+=][^}]*)?\}?"[[:space:]]+((bash|sh|node)[[:space:]]+)?"?\$\{?'"$var"'[^}]*\}?/scripts/([A-Za-z0-9_.-]+\.sh|[A-Za-z0-9_./-]+\.mjs)'
  done
  local launch_re="" anchored_re="" n_launch="" n_anchor=""
  while IFS= read -r file; do
    [ -f "$file" ] || continue
    names="$(grep -Eo '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*="?\$\{?(FF_DEV_TOOLKIT_ROOT|CLAUDE_PLUGIN_ROOT|GROK_PLUGIN_ROOT)[^}]*\}?/scripts/[A-Za-z0-9_.-]+\.sh"?$' "$file" \
      | sed 's/=.*//' | tr -d ' ' | sort -u | tr '\n' '|' | sed 's/|$//')" || names=""
    : > "$TMP/handoff-hits"
    grep -nE '(bash|sh|node)[[:space:]]+"?\$\{?(FF_DEV_TOOLKIT_ROOT|CLAUDE_PLUGIN_ROOT|GROK_PLUGIN_ROOT)[^}]*\}?/scripts/([A-Za-z0-9_.-]+\.sh|[A-Za-z0-9_./-]+\.mjs)' \
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
    launch_re="((bash|sh|node)[[:space:]]+)?\"?${root_expr}"
    anchored_re="$anchored_base"
    if [ -n "$names" ]; then
      launch_re="${launch_re}|(bash|sh)[[:space:]]+\"\\\$\\{?($names)\\}?\""
      anchored_re="${anchored_re}|${assign_any}(bash|sh)[[:space:]]+\"\\\$\\{?($names)\\}?\""
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
# handoff の値を stale な root literal へ差し替える変異。行としては「代入付きの起動」なので、
# 代入の有無だけを見る判定では緑のまま通る。実行するのは現在の root・子へ渡すのは別の root に
# なるので、ガードが毎回 exit 2 で止まる（= skill がまったく動かない）。
cp "$PLUGIN_ROOT/skills/merge-cleanup/SKILL.md" "$TMP/handoff-fixture/a.md"
cp "$PLUGIN_ROOT/skills/close-issue/SKILL.md" "$TMP/handoff-fixture/b.md"
perl -0pi -e 's/^FF_DEV_TOOLKIT_ROOT="\$\{FF_DEV_TOOLKIT_ROOT\}" bash "\$\{FF_DEV_TOOLKIT_ROOT\}\/scripts\/merge-cleanup\.sh"/FF_DEV_TOOLKIT_ROOT="\/stale\/root" bash "\${FF_DEV_TOOLKIT_ROOT}\/scripts\/merge-cleanup.sh"/m' \
  "$TMP/handoff-fixture/a.md"
if cmp -s "$PLUGIN_ROOT/skills/merge-cleanup/SKILL.md" "$TMP/handoff-fixture/a.md"; then
  bad "negative control: handoffのstale root差し替えが適用されませんでした（検査結果は根拠になりません）"
elif ( MIN_HANDOFF_LAUNCHES=1; check_exec_handoff "$TMP/handoff-fixture-list" >/dev/null 2>&1 ); then
  bad "negative control: 起動パスと違うrootを渡す代入を見逃しました"
else
  ok "negative control: handoffのRHSが起動パスと同じroot参照でなければ（literalなら）拒否する"
fi

# 崩壊床の negative control。node 起動を「検出外の綴り」（`node -- "${ROOT}/scripts/…"`）へ
# 書き換えると、その行は母集団からも検査からも同時に落ちる。床が live の実数ぴったりに置かれて
# いる限り、この取りこぼしは床割れとして赤になる（床に余裕があると黙って通過する）。
mkdir -p "$TMP/handoff-floor-fixture"
handoff_floor_n=0
while IFS= read -r handoff_src; do
  handoff_floor_n=$((handoff_floor_n + 1))
  cp "$handoff_src" "$TMP/handoff-floor-fixture/$(printf '%04d' "$handoff_floor_n").md"
done < "$TMP/handoff-live-list"
find "$TMP/handoff-floor-fixture" -name '*.md' -type f | sort > "$TMP/handoff-floor-list"
if check_exec_handoff "$TMP/handoff-floor-list" >/dev/null 2>&1; then
  ok "positive control: liveの写し（${handoff_floor_n} file）は床 ${MIN_HANDOFF_LAUNCHES} 行をそのまま通る"
else
  bad "positive control: liveの写しが床を通りませんでした（以降の床の negative control は根拠になりません）"
fi
handoff_node_before="$(cat "$TMP/handoff-floor-fixture"/*.md | { grep -cE 'node "\$\{(FF_DEV_TOOLKIT_ROOT|CLAUDE_PLUGIN_ROOT|GROK_PLUGIN_ROOT)' || true; })"
perl -0pi -e 's/\bnode "\$\{(FF_DEV_TOOLKIT_ROOT|CLAUDE_PLUGIN_ROOT|GROK_PLUGIN_ROOT)/node -- "\${$1/g' \
  "$TMP/handoff-floor-fixture"/*.md
handoff_node_after="$(cat "$TMP/handoff-floor-fixture"/*.md | { grep -cE 'node -- "\$\{(FF_DEV_TOOLKIT_ROOT|CLAUDE_PLUGIN_ROOT|GROK_PLUGIN_ROOT)' || true; })"
if [ "$handoff_node_before" -eq 0 ] || [ "$handoff_node_after" -ne "$handoff_node_before" ]; then
  bad "negative control: 検出外の綴りへの書き換えが適用されませんでした（${handoff_node_after}/${handoff_node_before} 行）"
elif ( check_exec_handoff "$TMP/handoff-floor-list" >/dev/null 2>&1 ); then
  bad "negative control: node起動 ${handoff_node_before} 行が検出対象から落ちても床を通過しました（床に余裕があります）"
else
  ok "negative control: node起動 ${handoff_node_before} 行を検出外の綴り（node -- …）へ変えると床割れで赤になる"
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
  # node entry と、それが import する sibling module（top-level は定義だけで副作用を持たない）。
  # entry だけを複製すると module 解決に失敗し、ガードではなく loader のエラーで止まって
  # 「停止した」が偽の positive になる。
  for name in $ROOT_NODE_ENTRY_NAMES; do
    [ -f "$PLUGIN_ROOT/scripts/$name" ] || continue
    mkdir -p "$dest/scripts/$(dirname "$name")"
    cp "$PLUGIN_ROOT/scripts/$name" "$dest/scripts/$name"
    cp "$PLUGIN_ROOT/scripts/$(dirname "$name")"/*.mjs "$dest/scripts/$(dirname "$name")/"
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


# ---- node entry 側ガードの実走と、shell 側との案内文言の同値照合 ------------
# 静的検査だけでは「書いてあるが効かない」を排除できない。shell 側と同じ fixture で node entry を
# 直接起動し、案内付きで非 0 停止すること・別インストール領域の完全な候補があっても切り替えない
# ことを実測する。実走は本来の処理へ到達しても破壊的にならない引数（`--help` / 未知引数）で行う。
#
# 併せて、**案内文言の正本が shell ガード block ただ 1 つ**であることをここで担保する。同じ
# handoff・同じ fixture で shell script と node entry を走らせ、実体 path の 1 行だけを伏せて
# 本文を cmp する。ソース文字列どうしの比較にしないのは、`${var:-既定}` のような言語ごとの綴りを
# 吸収する正規化規則そのものが第 3 の正本になるためで、consumer が実際に読む出力の側で縛る。
NODE_PROBE_ARG='--ff-guard-probe'
NODE_REACHED_NEEDLE="ASDD: Unknown argument: ${NODE_PROBE_ARG}"
# canonical 化した綴り。provenance の期待値（実体 path の完全一致）を組み立てるのに使う。
# 起動そのものは canonical でなくてよい — entry 判定は `process.argv[1]` と `import.meta.url` の
# **両方**を canonical 化して比べるので、symlink 成分を含む綴りで起動しても `main()` へ到達する。
# その形は下の「symlink 成分を含む綴りで起動」ケースが実測する（判定が片側だけ canonical、または
# 素の文字列比較へ戻ると、ガードは通るのに `main()` が呼ばれず出力なし・exit 0 になる）。
# handoff の値は素の path のまま渡し、ガード側が canonical 化して一致させることを併せて示す。
SOURCE_ROOT_CANONICAL="$(cd -P "$SOURCE_ROOT" && pwd -P)"
# 起動パスに symlink 成分を持たせるための綴り（macOS の `/var/folders/…` → `/private/var/…` と
# 同じ形）。最終成分は実体の file のままなので、symlink 起動の拒否とは別の経路を測る。
ln -s "$SOURCE_ROOT_CANONICAL" "$RUN_ROOT/source-link"

# 「別インストール領域の実体が走ってしまった」ことを検出する印（node 側）。走らなければ作られない。
NODE_CACHE_MARKER="$RUN_ROOT/cache-node-ran"
mkdir -p "$CACHE_ROOT/scripts/asdd"
{
  printf '%s\n' '#!/usr/bin/env node'
  printf '%s\n' "import fs from 'node:fs';"
  printf '%s\n' "fs.writeFileSync('$NODE_CACHE_MARKER', 'ran');"
} >"$CACHE_ROOT/scripts/asdd/cli.mjs"

# 全 node entry を同じ形で実走する。1 本だけの実走では、残る入口の rc 契約と衝突する誤番号や、
# 複製のずれで「案内が出ない 1 本」が残っていても見えない。
node_run_fail=0
node_run_count=0
for name in $ROOT_NODE_ENTRY_NAMES; do
  [ -f "$SOURCE_ROOT/scripts/$name" ] || continue
  expect_rc="$(node_expect_rc "$name")" || expect_rc=""
  if [ -z "$expect_rc" ]; then
    bad "実走(node): $name の期待rcがNODE_EXPECT_RCにありません"
    node_run_fail=1
    continue
  fi
  rc=0
  ( env HOME="$RUN_ROOT/cache-home" FF_DEV_TOOLKIT_ROOT="$INSTALLED_ROOT" \
      node "$SOURCE_ROOT_CANONICAL/scripts/$name" --help ) \
    >"$RUN_ROOT/node-all-$(basename "$name").log" 2>&1 </dev/null || rc=$?
  node_run_count=$((node_run_count + 1))
  if [ "$rc" -ne "$expect_rc" ]; then
    bad "実走(node): $name — exit ${rc}、期待 ${expect_rc}"
    sed -n '1,10p' "$RUN_ROOT/node-all-$(basename "$name").log" >&2 || true
    node_run_fail=1
  elif ! grep -qF 'ff-dev-toolkit更新後にこのskillを再呼び出してください' "$RUN_ROOT/node-all-$(basename "$name").log"; then
    bad "実走(node): $name — 期待した案内がありません"
    sed -n '1,10p' "$RUN_ROOT/node-all-$(basename "$name").log" >&2 || true
    node_run_fail=1
  fi
done
if [ "$node_run_count" -lt "$MIN_GUARDED_NODE_ENTRIES" ]; then
  bad "実走(node): 対象 ${node_run_count} 件が絶対下限 ${MIN_GUARDED_NODE_ENTRIES} 件を下回りました"
elif [ "$node_run_fail" -eq 0 ]; then
  ok "全 ${node_run_count} 本のnode entryが消えたrootで期待rcと案内つきに停止する（rcはNODE_EXPECT_RCの表）"
fi

run_script_guard_exec "node: 消えたrootをFF_DEV_TOOLKIT_ROOTが指したまま別実体を直接起動すると停止" \
  2 'plugin rootが消えています' "$RUN_ROOT/node-vanished-fixed.log" \
  env HOME="$RUN_ROOT/cache-home" FF_DEV_TOOLKIT_ROOT="$INSTALLED_ROOT" \
  node "$SOURCE_ROOT_CANONICAL/scripts/asdd/cli.mjs" --help
run_script_guard_exec "node: 同じ停止の案内にfallback禁止の理由（version混在・未リリースWIP）が入る" \
  2 'version混在と未リリースWIPの実行になります' "$RUN_ROOT/node-vanished-reason.log" \
  env HOME="$RUN_ROOT/cache-home" FF_DEV_TOOLKIT_ROOT="$INSTALLED_ROOT" \
  node "$SOURCE_ROOT_CANONICAL/scripts/asdd/work.mjs" --help
run_script_guard_exec "node: 消えたrootをCLAUDE_PLUGIN_ROOTが指す場合も停止" \
  2 'plugin rootが消えています' "$RUN_ROOT/node-vanished-host.log" \
  env HOME="$RUN_ROOT/cache-home" CLAUDE_PLUGIN_ROOT="$INSTALLED_ROOT" \
  node "$SOURCE_ROOT_CANONICAL/scripts/asdd/cli.mjs" --help
run_script_guard_exec "node: 実在する別インストール領域を指すhandoffも停止" \
  2 '別のインストール領域の実体です' "$RUN_ROOT/node-other-install.log" \
  env HOME="$RUN_ROOT/cache-home" CLAUDE_PLUGIN_ROOT="$CACHE_ROOT" \
  node "$SOURCE_ROOT_CANONICAL/scripts/asdd/cli.mjs" --help
if [ -e "$NODE_CACHE_MARKER" ]; then
  bad "node: 停止したはずの経路でcacheの別実体が実行されました"
else
  ok "node: 停止時にcache/marketplaceの完全な候補へ切り替えていない（候補を走査しない）"
fi
run_script_guard_exec "node: manifestを読めない実在rootは素通しせず停止する（fail-closed）" \
  2 '誰のrootか判定できません' "$RUN_ROOT/node-partial-install.log" \
  env HOME="$RUN_ROOT/cache-home" FF_DEV_TOOLKIT_ROOT="$BROKEN_ROOT" \
  node "$SOURCE_ROOT_CANONICAL/scripts/asdd/cli.mjs" --help
run_script_guard_exec "node: 入れ子のnameが先にある実在rootも別plugin扱いせず停止する" \
  2 '別のインストール領域の実体です' "$RUN_ROOT/node-nested-name-install.log" \
  env HOME="$RUN_ROOT/cache-home" FF_DEV_TOOLKIT_ROOT="$NESTED_SELF_ROOT" \
  node "$SOURCE_ROOT_CANONICAL/scripts/asdd/cli.mjs" --help

# 期待 root の内側に置いた symlink から、別 checkout の実体を実行する形。ESM loader は実体まで
# 解決してから読むので、`import.meta.url` だけを見ると handoff は一致してしまう。
mkdir -p "$RUN_ROOT/symlink-install/ff-dev-toolkit/scripts/asdd"
ln -s "$SOURCE_ROOT/scripts/asdd/cli.mjs" "$RUN_ROOT/symlink-install/ff-dev-toolkit/scripts/asdd/cli.mjs"
run_script_guard_exec "node: 期待root内のsymlinkから別checkoutの実体を実行する形も停止" \
  2 '起動したスクリプトがsymlinkです' "$RUN_ROOT/node-symlink-self.log" \
  env HOME="$RUN_ROOT/cache-home" FF_DEV_TOOLKIT_ROOT="$RUN_ROOT/symlink-install/ff-dev-toolkit" \
  node "$RUN_ROOT/symlink-install/ff-dev-toolkit/scripts/asdd/cli.mjs" --help

# `--preserve-symlinks-main` は main module の symlink を解決せず、`import.meta.url` に起動した
# 綴りをそのまま残す。entry 判定の片側（`process.argv[1]`）だけを canonical 化していると、この
# 起動が「不一致 = library として import された」と誤認され、ガードが丸ごと素通りする（host が
# NODE_OPTIONS を渡すだけで停止を外せる）。同じ symlink 起動が、このオプション下でも拒否される
# ことを実測する。
#
# このオプション下では sibling module の解決も symlink 側の directory で行われるため、entry だけを
# symlink した fixture では loader のエラーで止まり、ガードへ到達しない（= 停止の理由が測れない）。
# 同じ directory に sibling の実体を置いて、ガードが走る形にする。
PRESERVE_LINK_ROOT="$RUN_ROOT/preserve-symlinks-install/ff-dev-toolkit"
mkdir -p "$PRESERVE_LINK_ROOT/scripts/asdd"
cp "$SOURCE_ROOT/scripts/asdd/"*.mjs "$PRESERVE_LINK_ROOT/scripts/asdd/"
rm -f "$PRESERVE_LINK_ROOT/scripts/asdd/cli.mjs"
ln -s "$SOURCE_ROOT_CANONICAL/scripts/asdd/cli.mjs" "$PRESERVE_LINK_ROOT/scripts/asdd/cli.mjs"
run_script_guard_exec "node: --preserve-symlinks-main 下でもガードを迂回できない" \
  2 '起動したスクリプトがsymlinkです' "$RUN_ROOT/node-preserve-symlinks.log" \
  env HOME="$RUN_ROOT/cache-home" NODE_OPTIONS=--preserve-symlinks-main \
  FF_DEV_TOOLKIT_ROOT="$PRESERVE_LINK_ROOT" \
  node "$PRESERVE_LINK_ROOT/scripts/asdd/cli.mjs" --help

# 「止めない」側。未知引数は本来の処理（引数検査）へ到達した印で、filesystem には触れない。
run_script_guard_exec "node: 正規のhandoff（同じ実体）は止めない" \
  1 "$NODE_REACHED_NEEDLE" "$RUN_ROOT/node-valid-handoff.log" \
  env FF_DEV_TOOLKIT_ROOT="$SOURCE_ROOT" node "$SOURCE_ROOT_CANONICAL/scripts/asdd/cli.mjs" "$NODE_PROBE_ARG"
# symlink 成分を含む綴りのまま（canonical 化せずに）起動する形。ガードと `main()` の直接起動判定が
# 同じ canonical 判定でないと、ガードは通るのに `main()` が一度も呼ばれず、出力なし・exit 0 の
# 黙った失敗になる。到達の印（引数検査のエラー）が出ることで、両者の基準が揃っていることを測る。
run_script_guard_exec "node: symlink成分を含む綴りで起動してもmain()へ到達する" \
  1 "$NODE_REACHED_NEEDLE" "$RUN_ROOT/node-noncanonical-launch.log" \
  env FF_DEV_TOOLKIT_ROOT="$SOURCE_ROOT" node "$RUN_ROOT/source-link/scripts/asdd/cli.mjs" "$NODE_PROBE_ARG"
run_script_guard_exec "node: --preserve-symlinks-main 下でも正規の起動は止めない" \
  1 "$NODE_REACHED_NEEDLE" "$RUN_ROOT/node-preserve-symlinks-ok.log" \
  env NODE_OPTIONS=--preserve-symlinks-main FF_DEV_TOOLKIT_ROOT="$SOURCE_ROOT" \
  node "$SOURCE_ROOT_CANONICAL/scripts/asdd/cli.mjs" "$NODE_PROBE_ARG"
run_script_guard_exec "node: handoffがscripts/を直接指す綴りでも止めない" \
  1 "$NODE_REACHED_NEEDLE" "$RUN_ROOT/node-scripts-spelling.log" \
  env FF_DEV_TOOLKIT_ROOT="$SOURCE_ROOT/scripts" node "$SOURCE_ROOT_CANONICAL/scripts/asdd/work.mjs" "$NODE_PROBE_ARG"
run_script_guard_exec "node: handoffなしの直接起動も止めない" \
  1 "$NODE_REACHED_NEEDLE" "$RUN_ROOT/node-no-handoff.log" \
  env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT \
  node "$SOURCE_ROOT_CANONICAL/scripts/asdd/cli.mjs" "$NODE_PROBE_ARG"
run_script_guard_exec "node: 別pluginのhandoffでは止めない（照合対象外）" \
  1 "$NODE_REACHED_NEEDLE" "$RUN_ROOT/node-other-plugin.log" \
  env CLAUDE_PLUGIN_ROOT="$OTHER_ROOT" node "$SOURCE_ROOT_CANONICAL/scripts/asdd/cli.mjs" "$NODE_PROBE_ARG"
if grep -qF '照合対象外: CLAUDE_PLUGIN_ROOT=別plugin(another-plugin)' "$RUN_ROOT/node-other-plugin.log"; then
  ok "node: provenanceが照合を飛ばしたhandoffと理由を1行に含める"
else
  bad "node: provenanceが照合を飛ばしたhandoffを報告していません"
  sed -n '1,5p' "$RUN_ROOT/node-other-plugin.log" >&2 || true
fi
run_script_guard_exec "node: 入れ子のnameが自分の名前でもtop-levelが別名なら別plugin扱い（止めない）" \
  1 "$NODE_REACHED_NEEDLE" "$RUN_ROOT/node-nested-name-other.log" \
  env CLAUDE_PLUGIN_ROOT="$NESTED_OTHER_ROOT" node "$SOURCE_ROOT_CANONICAL/scripts/asdd/cli.mjs" "$NODE_PROBE_ARG"

# library として import された経路では走らない（`work.mjs` の関数は tests から直接 import される）。
# ここを止めると shell 側の「bash で起動したときだけ効く」より広い範囲を殺す。
printf '%s\n' "import { workStatus } from '$SOURCE_ROOT_CANONICAL/scripts/asdd/work.mjs';" \
  'process.stdout.write(typeof workStatus === "function" ? "IMPORT-OK\n" : "IMPORT-NG\n");' \
  >"$RUN_ROOT/import-probe.mjs"
run_script_guard_exec "node: library として import された経路ではガードを走らせない" \
  0 'IMPORT-OK' "$RUN_ROOT/node-import-probe.log" \
  env HOME="$RUN_ROOT/cache-home" FF_DEV_TOOLKIT_ROOT="$INSTALLED_ROOT" \
  node "$RUN_ROOT/import-probe.mjs"

# provenance の完全一致（node 側）。実体 path と manifest version の 1 行が、ちょうど 1 件出ること。
if [ -n "${PLUGIN_VERSION:-}" ]; then
  ( env FF_DEV_TOOLKIT_ROOT="$SOURCE_ROOT" node "$SOURCE_ROOT_CANONICAL/scripts/asdd/cli.mjs" "$NODE_PROBE_ARG" ) \
    >"$RUN_ROOT/node-provenance.log" 2>&1 </dev/null || true
  NODE_PROVENANCE_EXPECTED="ℹ️  ff-dev-toolkit ${PLUGIN_VERSION} — 実行実体: ${SOURCE_ROOT_CANONICAL}/scripts/asdd/cli.mjs（handoff: FF_DEV_TOOLKIT_ROOT）"
  node_provenance_hits="$(grep -cFx "$NODE_PROVENANCE_EXPECTED" "$RUN_ROOT/node-provenance.log" || true)"
  if [ "$node_provenance_hits" -eq 1 ]; then
    ok "node: 起動時のprovenanceが manifest version + 実体絶対path + handoff名 の完全な1行として出る"
  else
    bad "node: provenanceの完全一致が ${node_provenance_hits} 件（期待 1 件）"
    printf '    期待: %s\n' "$NODE_PROVENANCE_EXPECTED" >&2
    sed -n '1,5p' "$RUN_ROOT/node-provenance.log" >&2 || true
  fi
else
  bad "node: provenance検査: plugin manifestからversionを読めませんでした（検査は成立していない）"
fi

# 案内文言の同値照合。shell 側ガードと node 側ガードを同じ handoff で走らせ、実体 path の 1 行
# だけを伏せて本文を突き合わせる。ここが緑である限り、文言の正本は shell ガード block 1 つで済む。
normalize_guard_message() { # <log> → 実体pathの行を伏せた本文を stdout へ
  sed 's|^   起動したスクリプト: .*|   起動したスクリプト: <SELF>|' "$1"
}
compare_guard_message() { # <label> <shell log> <node log>
  local label="$1" shell_log="$2" node_log="$3"
  normalize_guard_message "$shell_log" >"${shell_log}.norm"
  normalize_guard_message "$node_log" >"${node_log}.norm"
  if [ ! -s "${shell_log}.norm" ]; then
    bad "案内文言の同値照合(${label}): shell 側の出力が空です（照合は成立していない）"
    return 0
  fi
  if cmp -s "${shell_log}.norm" "${node_log}.norm"; then
    ok "案内文言がshell側ガードと1行も違わない: ${label}"
  else
    bad "案内文言がshell側ガードと食い違います: ${label}"
    diff "${shell_log}.norm" "${node_log}.norm" >&2 || true
  fi
}

( env HOME="$RUN_ROOT/cache-home" FF_DEV_TOOLKIT_ROOT="$INSTALLED_ROOT" \
    bash "$SOURCE_ROOT/scripts/merge-cleanup.sh" --help ) \
  >"$RUN_ROOT/parity-shell-vanished.log" 2>&1 </dev/null || true
compare_guard_message "rootが消えている" \
  "$RUN_ROOT/parity-shell-vanished.log" "$RUN_ROOT/node-vanished-fixed.log"

( env HOME="$RUN_ROOT/cache-home" CLAUDE_PLUGIN_ROOT="$CACHE_ROOT" \
    bash "$SOURCE_ROOT/scripts/merge-cleanup.sh" --help ) \
  >"$RUN_ROOT/parity-shell-other.log" 2>&1 </dev/null || true
compare_guard_message "別インストール領域を指している" \
  "$RUN_ROOT/parity-shell-other.log" "$RUN_ROOT/node-other-install.log"

( env HOME="$RUN_ROOT/cache-home" FF_DEV_TOOLKIT_ROOT="$BROKEN_ROOT" \
    bash "$SOURCE_ROOT/scripts/merge-cleanup.sh" --help ) \
  >"$RUN_ROOT/parity-shell-partial.log" 2>&1 </dev/null || true
compare_guard_message "manifestを読めない（判定不能）" \
  "$RUN_ROOT/parity-shell-partial.log" "$RUN_ROOT/node-partial-install.log"

( env HOME="$RUN_ROOT/cache-home" FF_DEV_TOOLKIT_ROOT="$RUN_ROOT/symlink-install/ff-dev-toolkit" \
    bash "$RUN_ROOT/symlink-install/ff-dev-toolkit/scripts/merge-cleanup.sh" --help ) \
  >"$RUN_ROOT/parity-shell-symlink.log" 2>&1 </dev/null || true
compare_guard_message "起動した綴りがsymlink" \
  "$RUN_ROOT/parity-shell-symlink.log" "$RUN_ROOT/node-symlink-self.log"

# 同値照合そのものの negative control。node 側の案内を 1 語変えた複製では照合が赤になること
# （= 上の 4 件が文言を測っていること）を実測する。
NODE_PARITY_MUTANT="$RUN_ROOT/parity-mutant/plugins/ff-dev-toolkit"
make_run_fixture "$NODE_PARITY_MUTANT"
perl -0pi -e 's/version混在と未リリースWIPの実行になります。/更新が間に合わないときは新しい方を使ってよい。/' \
  "$NODE_PARITY_MUTANT/scripts/asdd/cli.mjs"
if cmp -s "$SOURCE_ROOT/scripts/asdd/cli.mjs" "$NODE_PARITY_MUTANT/scripts/asdd/cli.mjs"; then
  bad "negative control(node): 案内文言の変異が適用されませんでした（同値照合は根拠になりません）"
else
  ( env HOME="$RUN_ROOT/cache-home" FF_DEV_TOOLKIT_ROOT="$INSTALLED_ROOT" \
      node "$NODE_PARITY_MUTANT/scripts/asdd/cli.mjs" --help ) \
    >"$RUN_ROOT/parity-node-mutant.log" 2>&1 </dev/null || true
  normalize_guard_message "$RUN_ROOT/parity-shell-vanished.log" >"$RUN_ROOT/parity-shell-vanished.log.norm"
  normalize_guard_message "$RUN_ROOT/parity-node-mutant.log" >"$RUN_ROOT/parity-node-mutant.log.norm"
  if cmp -s "$RUN_ROOT/parity-shell-vanished.log.norm" "$RUN_ROOT/parity-node-mutant.log.norm"; then
    bad "negative control(node): 案内文言を変えても同値照合が通りました（照合は何も測っていません）"
  else
    ok "negative control(node): node側の案内文言を1語変えるとshell側との同値照合が赤になる"
  fi
fi

# 実走ケースの negative control。ガードの呼び出し行を落とした複製では、同じ起動が案内付きの
# 停止にならないこと（= 上のケースがガードを測っていること）を実測する。「案内が出ない」だけでは
# 別の初期エラーでも positive になるので、後続処理へ到達した印と終了コードも併せて確認する。
NODE_MUTANT_ROOT="$RUN_ROOT/node-mutant-checkout/plugins/ff-dev-toolkit"
make_run_fixture "$NODE_MUTANT_ROOT"
perl -0pi -e 's{^if \(!ffGuardAssertPluginRoot\(import\.meta\.url\)\) process\.exit\([0-9]+\);\n}{}m' \
  "$NODE_MUTANT_ROOT/scripts/asdd/cli.mjs"
if cmp -s "$SOURCE_ROOT/scripts/asdd/cli.mjs" "$NODE_MUTANT_ROOT/scripts/asdd/cli.mjs"; then
  bad "negative control(node): 実走用の呼び出し行削除が適用されませんでした（実走ケースは根拠になりません）"
else
  node_mutant_rc=0
  NODE_MUTANT_ROOT_CANONICAL="$(cd -P "$NODE_MUTANT_ROOT" && pwd -P)"
  ( env HOME="$RUN_ROOT/cache-home" FF_DEV_TOOLKIT_ROOT="$INSTALLED_ROOT" \
      node "$NODE_MUTANT_ROOT_CANONICAL/scripts/asdd/cli.mjs" "$NODE_PROBE_ARG" ) \
    >"$RUN_ROOT/node-mutant.log" 2>&1 </dev/null || node_mutant_rc=$?
  if grep -qF 'ff-dev-toolkit更新後にこのskillを再呼び出してください' "$RUN_ROOT/node-mutant.log"; then
    bad "negative control(node): ガードを外しても停止の案内が出ました（実走ケースはガードを測っていません）"
  elif [ "$node_mutant_rc" -ne 1 ] || ! grep -qF "$NODE_REACHED_NEEDLE" "$RUN_ROOT/node-mutant.log"; then
    bad "negative control(node): ガードを外した起動が後続処理へ到達していません（rc=${node_mutant_rc}。別の初期エラーで止まった可能性）"
    sed -n '1,10p' "$RUN_ROOT/node-mutant.log" >&2 || true
  else
    ok "negative control(node): ガードを外すと同じ起動が案内なしで後続処理（引数検査）まで進む（実走ケースの検出力の裏取り）"
  fi
fi
echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ plugin-root-contract verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ plugin-root-contract verify: 全 ${PASS} 件 pass"
FF_REACHED_END=1
