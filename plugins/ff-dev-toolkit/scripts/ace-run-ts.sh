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
