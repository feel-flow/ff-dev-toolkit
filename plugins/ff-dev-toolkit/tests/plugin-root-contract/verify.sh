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
MIN_SKILLS=21

# 実行時ガードを持つ skill の絶対下限。MIN_SKILLS と同じ理由で、母集団から導いた量
# （母集団 - 除外数）を床にしても崩壊を検出できない。値は現時点でガードを持つ skill の
# 実数（母集団のうち GUARD_EXEMPT に載らないもの）。
MIN_GUARD_SKILLS=17

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
  if grep -Fq 'FF_DEV_TOOLKIT_ROOT' "$file" || grep -Fq '${CLAUDE_PLUGIN_ROOT}' "$file"; then
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
    if grep -Fq 'FF_DEV_TOOLKIT_ROOT' "$file" || grep -Fq '${CLAUDE_PLUGIN_ROOT}' "$file"; then
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

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ plugin-root-contract verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ plugin-root-contract verify: 全 ${PASS} 件 pass"
FF_REACHED_END=1
