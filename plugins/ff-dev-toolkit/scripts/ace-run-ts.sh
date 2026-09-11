#!/usr/bin/env bash
#
# ace-run-ts.sh — 同梱 ACE ゲート（TypeScript）を、環境にある JavaScript runner で実行する
#
# 背景（Issue #879）: /ace-curate の手順 4-f は未導入プロジェクト向けに
# `npx --yes tsx <同梱パス>` を案内していたが、root package に tsx binary が無い
# workspace 環境で `tsx: command not found` が 3 回連続で観測された（CHEQIT）。
# workspace package 側の tsx を package manager 経由で呼ぶと同じ 3 ゲートが通った。
# Issue #614 / PR #689 は**同梱スクリプトへのパス**到達性を直したが、**runner 自体**の
# 到達性は残っていた。
#
# 規約: 候補を順に **実際に起動して** 使えることを確かめ、最初に通ったものを使う。
# 「存在しそう」で選ばない（`command -v` は shim の存在しか言わず、CHEQIT の失敗は
# まさに shim があって起動できない形だった）。
#
# 起動確認に**フラグを使わない**（Issue #932）。`<候補> --version` の形は、外側の
# ラッパーがそのフラグを自分で消費しうるため、内側の tsx へ一切届かないことがある。
# 実測（yarn 1.22.22）: `yarn exec tsx --version` は **yarn 自身の** version を出して
# exit 0 で終わり、続く `yarn exec tsx <script>` は `Couldn't find the binary tsx` で
# 失敗した。フラグ probe はこれを「使える候補」と誤判定し、ACE の必須 3 ゲートが
# まとめて到達不能になる（#879 で塞いだ症状が別経路で再発した）。
# 代わりに**本番と同じ `<候補> <script.ts>` の形**で同梱 probe スクリプトを渡し、
# それが実際に走った証拠を確認する。フラグ転送の方言に依存しない。証拠には
# **実行時に渡す使い捨てトークン**を使う（固定文字列だと、渡したファイルの内容を
# 表示するだけの候補が「実行できた」ことになり、ゲートを実行しないまま緑になる）。
#
#   1. FF_ACE_TS_RUNNER（明示指定の逃げ道。空白区切りの複数語を受ける。
#      `pnpm --filter <pkg> exec tsx` のような形を書けることを優先した帰結として、
#      **runner の実行ファイルパスに空白は書けない**〔語分割される〕。その場合は
#      PATH へ通すか symlink を張る。曖昧に推測せず、起動できなければ exit 3 で止める）
#   2. PATH 上の tsx
#   3. cwd から git root まで遡って見つかる node_modules/.bin/tsx
#      （workspace root で hoist された場合ここで拾う）
#   4. workspace を解決する package manager の exec（pnpm / yarn）
#      （workspace package 側にだけ tsx がある場合の経路。pnpm exec は cwd から
#        最も近い node_modules/.bin を見るので、対象 package 内で呼べば届く。
#        npm exec はここに置かない — 実体は npx と同じくレジストリ取得へ落ちるので、
#        「ローカルにある物を使う」段と混ぜると解決順の意味が壊れる）
#   5. npx --yes tsx（ネットワークから取得。従来の案内）
#
# どれも使えなければ **fail-closed**（exit 3）。手作業照合や別 plugin version への
# fallback は行わない — 「ゲートを飛ばして先へ進む」経路を作らないことが本 Issue の主眼。
#
# runner / 検証スクリプトの非ゼロ終了は**そのまま伝播する**（成功へ変換しない）。
#
# 使い方:
#   bash ace-run-ts.sh <script.ts> [args...]
#   FF_ACE_TS_RUNNER="pnpm --filter @acme/docs exec tsx" bash ace-run-ts.sh <script.ts> ...
#
# 終了コード: 0 = 成功 / 2 = 使い方の誤り・同梱ファイルの破損 / 3 = runner 不在（fail-closed）
#             それ以外 = 検証スクリプト自身の終了コード（そのまま伝播）

set -uo pipefail

# ff-dev-toolkit-script-root-guard:start
# plugin root 固定ガード（script 側）。同じ停止を skill 本文の契約節も述べているが、
# ホストが実行部だけを解決済み絶対 path として注入し契約節が本文から落ちた経路では、
# 散文のガードはちょうどそのとき手元に無い（防御が守ろうとしている失敗と、防御が
# 失われる条件が同じ）。実行部と同じファイルへ置くことで、契約を読んでいない consumer
# でも止まる。**候補は探しに行かない** — cache / marketplace / 旧インストール領域の
# 走査も version 名の並べ替えによる選び直しもしない。それが本ガードの防ごうとしている
# 失敗そのもので、探索を足すと防御が防御対象を踏む。渡された handoff を canonical 化
# して自分の実体位置と比べるだけにする。handoff が 1 つも無い直接起動（端末・テスト・
# CI の pin 実行）は止めない — 比較対象が無い状態を不一致とみなすと、正規の直接起動が
# 全部止まる。
#
# 到達性は呼び出し側とセットで成り立つ。host は plugin root を Bash tool の環境へ
# export せず、実行部テキストへ解決済みの値を差し込むだけなので、handoff を運ぶのが
# skill 本文の resolver だけだと「本文が落ちた」ちょうどそのときに handoff も消え、
# ガードは比較対象なしで素通しになる。そこで固定 root 経由の実行部は
# `FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/<名>"`
# の形にして handoff を**同じ 1 行へ**載せる。実行するスクリプトの path だけを別領域へ
# 書き換える事故は、この 1 行の中の不一致として検出できる。
#
# 判定不能は素通しではなく停止に倒す（fail-closed）。更新中の部分的な消失では、
# 判定材料（別 plugin かどうかを言う manifest）そのものが壊れた領域の内側にある。
#
# 外部コマンドを使わない。PATH が壊れた環境はこのガードが最後の砦になる場面そのもので、
# dirname / grep / sed に依存すると「自分の位置を判定できないまま素通し」になる。
# その代わり builtin 側の環境依存を自分で閉じる: path の canonical 化はすべて
# `CDPATH= cd -P --` で行う。`cd` は CDPATH が効くと**別のdirectoryへ移動したうえで
# 移動先を stdout へ出す**ので、export された CDPATH に同名の subdirectory があると
# 相対起動（`bash scripts/<名>`）で自分の位置を取り違え、コマンド置換も 2 行になる。
# 「止めない」と明文で約束している端末・テスト・CI の直接起動が、正規の handoff 付き
# でも止まっていた。各 script の複製は byte 一致で、tests/plugin-root-contract が固定する。
ff_script_root_guard_manifest_field() { # <plugin.json> <キー> → 値をstdoutへ / 読めなければ非0
  # JSON を「文字列の外 / 中」に分けて走査し、**root object 直下（ネスト深さ 1）のキー**
  # だけを返す。行単位に最初の `"<キー>"` を拾う形だと、`author` のような入れ子 object が
  # top-level の `name` より前にある manifest で `author.name` を掴み、別 plugin と誤読して
  # 照合ごと飛ばす（= fail-open）。同じ判定を docs-template の resolver fence の awk も
  # 「`{` 直後の name marker」として要求しており、厳しさを揃える。fence と違って version も
  # 読むので「最初のキー」ではなく「深さ 1 のキー」に寄せる。
  local file="$1" key="$2" line="" rest="" seg="" tmp="" acc=""
  local depth=0 instr=0 expect=0 last="" bs=0
  # symlink・非通常ファイル・読めないものは「確認できない」に倒す（除外の根拠にしない）。
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    rest="$line"
    while [ -n "$rest" ]; do
      if [ "$instr" -eq 1 ]; then
        case "$rest" in
          *'"'*) seg="${rest%%'"'*}"; rest="${rest#*'"'}" ;;
          *) acc="${acc}${rest}"; rest=""; continue ;;
        esac
        # 直前が奇数個の backslash なら、その `"` は escape されていて文字列は続く。
        tmp="$seg"; bs=0
        while [ "${tmp%\\}" != "$tmp" ]; do bs=$((bs + 1)); tmp="${tmp%\\}"; done
        acc="${acc}${seg}"
        if [ $((bs % 2)) -eq 1 ]; then acc="${acc}\""; continue; fi
        instr=0
        if [ "$expect" -eq 1 ]; then printf '%s' "$acc"; return 0; fi
        last="$acc"; acc=""
        continue
      fi
      case "$rest" in
        *'"'*) seg="${rest%%'"'*}"; rest="${rest#*'"'}"; instr=1; acc="" ;;
        *) seg="$rest"; rest="" ;;
      esac
      # 深さは文字列の外に出た構造文字だけで数える（値の中の括弧に釣られない）。
      tmp="$seg"
      while [ "${tmp#*'{'}" != "$tmp" ]; do depth=$((depth + 1)); tmp="${tmp#*'{'}"; done
      tmp="$seg"
      while [ "${tmp#*'['}" != "$tmp" ]; do depth=$((depth + 1)); tmp="${tmp#*'['}"; done
      tmp="$seg"
      while [ "${tmp#*'}'}" != "$tmp" ]; do depth=$((depth - 1)); tmp="${tmp#*'}'}"; done
      tmp="$seg"
      while [ "${tmp#*']'}" != "$tmp" ]; do depth=$((depth - 1)); tmp="${tmp#*']'}"; done
      case "$seg" in
        *:*) if [ "$depth" -eq 1 ] && [ -n "$last" ] && [ "$last" = "$key" ]; then expect=1; fi ;;
      esac
      # 値が object / array なら、次に閉じる文字列はその中身であって値ではない。
      case "$seg" in
        *'{'*|*'['*|*,*) expect=0 ;;
      esac
      last=""
    done
  done < "$file"
  return 1
}
ff_assert_script_plugin_root() {
  local self="${1:-}" dir="" root="" var="" value="" canonical="" used="" skipped="" other="" version="" quiet=0
  [ -n "$self" ] || { echo "❌ 起動したスクリプトの実体位置を取得できません" >&2; return 1; }
  case "$self" in */*) dir="${self%/*}" ;; *) dir="." ;; esac
  dir="$(CDPATH= cd -P -- "$dir" 2>/dev/null && pwd -P)" || dir=""
  [ -n "$dir" ] || { echo "❌ 起動したスクリプトのdirectoryを解決できません: ${self}" >&2; return 1; }
  root="$(CDPATH= cd -P -- "${dir}/.." 2>/dev/null && pwd -P)" || root=""
  [ -n "$root" ] || { echo "❌ 自分のplugin rootを解決できません: ${dir}" >&2; return 1; }
  self="${dir}/${self##*/}"
  # スクリプト自身がsymlinkなら止める。親directoryしかcanonical化しないと、期待root内の
  # symlinkから別checkoutの実体を実行でき、「実体位置とhandoffの照合」の前提が崩れる。
  if [ -L "$self" ]; then
    {
      echo "❌ ff-dev-toolkit更新後にこのskillを再呼び出してください（起動したスクリプトがsymlinkです）"
      echo "   起動したスクリプト: ${self}"
      echo "   symlinkは期待rootの内側から別領域の実体を指せるため、実体位置の照合が成立しません。"
      echo "   別のインストール領域へ切り替えて実行しないこと — version混在と未リリースWIPの実行になります。"
      echo "   cacheや別checkoutを探さず、実体のパスで起動してください。"
    } >&2
    return 1
  fi
  for var in FF_DEV_TOOLKIT_ROOT CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT; do
    eval "value=\${${var}:-}"
    [ -n "$value" ] || continue
    canonical="$(CDPATH= cd -P -- "$value" 2>/dev/null && pwd -P)" || canonical=""
    # 正規形は plugin root だが、scripts/ を直接指す綴りも正規に受理されている
    # （templates/codex-review.sh の canonical_toolkit_root が両方を受ける）。同じ実体を
    # 指している限り一致として扱う。
    if [ -n "$canonical" ] && { [ "$canonical" = "$root" ] || [ "$canonical" = "$dir" ]; }; then
      [ -n "$used" ] || used="$var"
      continue
    fi
    # 実在する別 plugin の root は我々への handoff ではない（別 plugin 経由の正規呼び出し
    # まで殺さない）。ただし除外できるのは「manifestが通常ファイルとして読めて、名前が別だと
    # 確認できた」ときだけにする。消えているroot も、読めないmanifest も、誰のものか判定
    # できない点は同じ。
    other=""
    if [ -n "$canonical" ]; then
      other="$(ff_script_root_guard_manifest_field "${canonical}/.claude-plugin/plugin.json" name)" || other=""
    fi
    if [ -n "$other" ] && [ "$other" != "ff-dev-toolkit" ]; then
      skipped="${skipped:+${skipped} }${var}=別plugin(${other})"
      continue
    fi
    {
      echo "❌ ff-dev-toolkit更新後にこのskillを再呼び出してください（plugin rootが固定値と一致しません）"
      echo "   起動したスクリプト: ${self}"
      echo "   このスクリプトのplugin root: ${root}"
      echo "   hostが渡したroot（${var}）: ${value}"
      if [ -z "$canonical" ]; then
        echo "   不一致の内容: 指しているdirectoryが実在しません（plugin rootが消えています）"
      elif [ -z "$other" ]; then
        echo "   不一致の内容: 指す先のplugin manifestを読めず、誰のrootか判定できません（判定不能は停止に倒します）"
      else
        echo "   不一致の内容: このスクリプトは別のインストール領域の実体です"
      fi
      echo "   別のインストール領域へ切り替えて実行しないこと — version混在と未リリースWIPの実行になります。"
      echo "   cacheや別checkoutを探さず、pluginを再導入してからskillを呼び直してください。"
    } >&2
    return 1
  done
  # provenance（実体 path と version の 1 行）は「想定外の場所から起動された」ことを
  # agent にもログを読む人にも見せて診断コストを下げる。照合を飛ばした handoff も理由付きで
  # 出す — 渡っていた事実を「なし・直接起動」と報告すると、診断価値を損ない事実とも食い違う。
  # 出力そのものが契約になっている script（成功時は無出力・stderr を混ぜない等）では情報行が
  # 契約違反になるので、その basename だけを**この block 内の allowlist**で抑止する。
  # 外から env で抑止できる形にすると allowlist が実効的な制約にならないので、環境変数では
  # 抑止できない。抑止できるのは provenance だけで、停止の判定と案内は抑止できない。
  case "${self##*/}" in
    check-merge-freshness.sh|check-plugin-versions.sh) quiet=1 ;;
  esac
  if [ "$quiet" -ne 1 ]; then
    version="$(ff_script_root_guard_manifest_field "${root}/.claude-plugin/plugin.json" version)" || version=""
    echo "ℹ️  ff-dev-toolkit ${version:-version不明} — 実行実体: ${self}（handoff: ${used:-なし・直接起動}${skipped:+ / 照合対象外: ${skipped}}）" >&2
  fi
  return 0
}
ff_assert_script_plugin_root "${BASH_SOURCE[0]}" || exit 2
# ff-dev-toolkit-script-root-guard:end
# 中断コードは本スクリプトの契約の 2（使い方の誤り・同梱ファイルの破損）。ガードの停止は
# 「起動の仕方が正しくない」側で、3（runner 不在の fail-closed）とも検証スクリプト自身の
# 終了コードの伝播とも混ざらない。

if [[ $# -lt 1 ]]; then
  echo "usage: ace-run-ts.sh <script.ts> [args...]" >&2
  exit 2
fi

TS_SCRIPT="$1"
shift

if [[ ! -r "$TS_SCRIPT" ]]; then
  echo "✗ 同梱スクリプトを読み取れません: ${TS_SCRIPT}" >&2
  echo "  ff-dev-toolkit の更新後にこのスキルを再呼び出ししてください。" >&2
  exit 2
fi

# 候補を「起動できるか」で判定する。判定は**本番と同じ起動形**（`<候補> <script.ts>`）で
# 行い、フラグは一切足さない（理由は冒頭の規約。Issue #932）。
# 候補は配列で持ち、空白を含むパスでも語分割しない。
#
# probe スクリプトは本スクリプトの隣に置く。パスの導出に `dirname` を使わない —
# PATH が壊れた環境（本スクリプトが最後の砦になる場面そのもの）では外部コマンドが
# 解決できない（下の node_modules 探索が同じ理由で `dirname` を避けているのと同様）。
#
# パイプ起動（`bash < ace-run-ts.sh`）では BASH_SOURCE が空になる。そのとき cwd 相対で
# 探すと、**呼び出し元のディレクトリにある同名ファイル**を probe として実行してしまう。
# 起動形が特定できないときは探さずに止める。
_self="${BASH_SOURCE[0]:-}"
if [[ -z "$_self" ]]; then
  echo "✗ 本スクリプト自身の位置を特定できません（パイプ経由で起動されています）" >&2
  echo "  ファイルパスを指定して起動してください（例: bash <plugin>/scripts/ace-run-ts.sh <script.ts>）。" >&2
  exit 2
fi
[[ "$_self" == */* ]] || _self="./$_self"
# 相対パスのまま候補へ渡してはならない。cwd を移して子プロセスを起動するラッパーでは
# probe を読めず、**実際には動く候補が黙って落ちて次の候補へ倒れる**（誤診の種）。
[[ "$_self" == /* ]] || _self="${PWD}/${_self#./}"
PROBE_TS="${_self%/*}/ace-run-ts-probe.ts"
PROBE_SENTINEL="ACE_RUN_TS_PROBE_OK"
# sentinel を探すだけでは足りない。sentinel は probe の**ソースに平文で含まれる**ので、
# 「渡されたファイルの内容を表示するだけ」の候補（`cat` のような形）や、help / エラー文へ
# sentinel を含む候補が通ってしまう（クロスモデルレビュー指摘。今回塞ぐ偽陽性の別経路で、
# しかもこちらは**ゲートを実行しないまま exit 0** になるため質が悪い）。
# そこでソースに存在しない使い捨てトークンを環境変数で渡し、probe が**実行時に読んで
# 出力した**ことを確認する。これを通れるのは TypeScript を実際に実行できた候補だけになる。
# トークンは bash 組み込みだけで作る（PATH が壊れた環境でも作れる必要がある）。
PROBE_TOKEN="${RANDOM}-${RANDOM}-$$-${RANDOM}"

# probe スクリプトが無いのは「runner 不在」ではなく**インストールの破損**である。
# 区別せずに探索へ入ると全候補が落ちて「runner が見つかりません」と報告し、
# 実際には runner があるのに利用者を tsx の導入へ誘導してしまう（誤診の固定化）。
# `-s` も見る: 部分同期・中断したダウンロードで 0 バイトになった probe は `-r` を通過し、
# 何も出力しないまま全候補を落とす — つまり上に書いた誤診そのものへ戻る。
if [[ ! -r "$PROBE_TS" || ! -s "$PROBE_TS" ]]; then
  echo "✗ runner 判定用の probe スクリプトを読み取れません（または空です）: ${PROBE_TS}" >&2
  echo "  ff-dev-toolkit のインストールが壊れています（runner の不在ではありません）。" >&2
  echo "  ace-run-ts.sh は同じディレクトリの ace-run-ts-probe.ts を必要とします。" >&2
  echo "  symlink 経由で起動している場合は、symlink ではなく実体のパスで起動してください（隣の probe を解決できません）。" >&2
  echo "  それ以外の場合は再インストール後に再実行してください。" >&2
  exit 2
fi

# 候補ごとの失敗理由を残す。捕った出力を捨てると、明示指定の失敗時に「語分割」の固定文
# だけが出て実際の原因（binary 不在・権限・引数転送の形）が消える（レビュー指摘）。
# 「起動できなかった」と「起動したが証拠を出さなかった」を出し分けるのが要点で、
# 後者は probe 側の破損や出力を書き換えるラッパーを示す。
PROBE_TRIED=()
_probe() { # <argv...> -> 0 なら使える
  local _out _rc=0 _label="$*"
  # stdin は必ず閉じる。probe は「フラグの表示」ではなく**スクリプトの実行**なので、
  # stdin を読む候補に当たると何も出力せず無期限に待ち、外からハングと区別できない
  # （このリポジトリが codex で焼かれた形。CLAUDE.md に「`</dev/null` を必ず付ける」と
  # 成文化されている）。**末尾の本番起動には付けない** — ゲート側の stdin を奪わない。
  # stderr は判定に混ぜない（診断メッセージへ sentinel を含める候補を弾く。JS しか
  # 実行できない runner の構文エラーは問題の行を丸ごとエコーするため、混ぜると
  # ソース中の sentinel が「実行の証拠」に化ける）。
  _out="$(ACE_RUN_TS_PROBE_TOKEN="$PROBE_TOKEN" "$@" "$PROBE_TS" </dev/null 2>/dev/null)" || _rc=$?
  # Windows 由来の CR を落としてから行一致させる（行末の差で「実行できたのに不採用」に
  # ならないようにする）。
  _out="${_out//$'\r'/}"
  # 終了コードだけでは足りない。ラッパーが自分の応答（help / version など）を出して
  # exit 0 で終わる形を弾くため、**probe が実際に走った証拠**を要求する。
  # 部分一致ではなく**独立した 1 行**として一致することを求める — 他の出力の一部に
  # 紛れ込んだ文字列を証拠として数えない。
  if [[ $'\n'"$_out"$'\n' == *$'\n'"${PROBE_SENTINEL}:${PROBE_TOKEN}"$'\n'* ]]; then
    return 0
  fi
  if [[ "$_rc" -ne 0 ]]; then
    PROBE_TRIED+=("${_label}: 起動できません（rc=${_rc}）")
  else
    PROBE_TRIED+=("${_label}: 起動しましたが実行の証拠を出しません（TypeScript を実行できない、出力を書き換える、または probe が壊れている）")
  fi
  return 1
}

RUNNER=()

# 1. 明示指定。空白区切りの複数語を受ける（`pnpm --filter <pkg> exec tsx` の形）。
#    word splitting はここでだけ意図的に使う。
if [[ -n "${FF_ACE_TS_RUNNER:-}" ]]; then
  # 語分割はするが**パス名展開はしない**（set -f）。`pnpm --filter '@scope/*' exec tsx`
  # のような値が cwd のファイル名へ展開されると、意図と違う runner が黙って起動する。
  set -f
  # shellcheck disable=SC2206  # 複数語の runner 指定を語分割するのが仕様
  _explicit=(${FF_ACE_TS_RUNNER})
  set +f
  if [[ ${#_explicit[@]} -gt 0 ]] && _probe "${_explicit[@]}"; then
    RUNNER=("${_explicit[@]}")
  else
    echo "✗ FF_ACE_TS_RUNNER で指定された runner を起動できません: ${FF_ACE_TS_RUNNER}" >&2
    echo "  値は空白で語分割されます。実行ファイルのパスに空白がある場合は指定できません（PATH へ通すか symlink を張ってください）。" >&2
    for _t in ${PROBE_TRIED[@]+"${PROBE_TRIED[@]}"}; do
      echo "  判定: ${_t}" >&2
    done
    # 実際の原因（binary 不在・権限・引数転送の形）は判定時に stderr へ出ている。
    # 判定では stderr を混ぜられないので、失敗した時だけ**診断のために再実行**して見せる。
    echo "  指定した runner の出力（診断のため再実行）:" >&2
    ACE_RUN_TS_PROBE_TOKEN="$PROBE_TOKEN" "${_explicit[@]}" "$PROBE_TS" </dev/null >&2 2>&1 || true
    exit 3
  fi
fi

# 2. PATH 上の tsx
if [[ ${#RUNNER[@]} -eq 0 ]] && _probe tsx; then
  RUNNER=(tsx)
fi

# 3. cwd から上へ node_modules/.bin/tsx を探す。git root（無ければ / ）で打ち切る。
if [[ ${#RUNNER[@]} -eq 0 ]]; then
  _stop="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  _dir="$PWD"
  # 親へ遡るのに `dirname` を使わない。PATH が壊れた環境（本スクリプトが最後の
  # 砦になる場面そのもの）では外部コマンドが解決できず、空文字を返して**無限ループ
  # する**（実測: PATH=/nonexistent で 2 分以上ハング）。シェル内の展開だけで進める。
  while :; do
    if [[ -x "${_dir}/node_modules/.bin/tsx" ]] && _probe "${_dir}/node_modules/.bin/tsx"; then
      RUNNER=("${_dir}/node_modules/.bin/tsx")
      break
    fi
    [[ -n "$_stop" && "$_dir" == "$_stop" ]] && break
    [[ -z "$_dir" || "$_dir" == "/" ]] && break
    _dir="${_dir%/*}"
    [[ -n "$_dir" ]] || _dir="/"
  done
fi

# 4. lockfile から package manager を選び、その exec 経由で解決させる。
#    workspace package 側にだけ tsx がある場合の経路（Issue #879 の実測ケース）。
if [[ ${#RUNNER[@]} -eq 0 ]]; then
  for _cand in "pnpm exec tsx" "yarn exec tsx"; do
    set -f
    # shellcheck disable=SC2206  # 固定の候補文字列を語分割する
    _argv=(${_cand})
    set +f
    if _probe "${_argv[@]}"; then
      RUNNER=("${_argv[@]}")
      break
    fi
  done
fi

# 5. 従来の案内（ネットワークから取得）
if [[ ${#RUNNER[@]} -eq 0 ]] && _probe npx --yes tsx; then
  RUNNER=(npx --yes tsx)
fi

if [[ ${#RUNNER[@]} -eq 0 ]]; then
  echo "✗ TypeScript を実行できる runner が見つかりません（ACE の必須ゲートを実行できません）" >&2
  echo "  探索した順序: FF_ACE_TS_RUNNER / PATH の tsx / node_modules/.bin/tsx（上位ディレクトリ含む） / pnpm・yarn の exec / npx --yes tsx" >&2
  # 候補ごとの判定結果を出す。「起動できない」だけが並ぶなら runner の導入が必要、
  # 「起動したが証拠を出さない」が並ぶなら probe 側の破損を疑うべき、と切り分けられる。
  for _t in ${PROBE_TRIED[@]+"${PROBE_TRIED[@]}"}; do
    echo "  判定: ${_t}" >&2
  done
  echo "  次のいずれかを行ってから再実行してください:" >&2
  echo "    - tsx を入れる: npm i -D tsx（対象 package で。workspace なら pnpm add -D tsx --filter <pkg>）" >&2
  echo "    - すでに入っている runner を明示する: FF_ACE_TS_RUNNER=\"pnpm --filter <pkg> exec tsx\"" >&2
  echo "  手作業での照合や、別 version の plugin へのフォールバックで代替しないこと（ゲートが成立しません）。" >&2
  exit 3
fi

echo "ace-run-ts: runner=${RUNNER[*]}" >&2
# 検証スクリプトの終了コードをそのまま返す（成功へ変換しない）。
"${RUNNER[@]}" "$TS_SCRIPT" "$@"
