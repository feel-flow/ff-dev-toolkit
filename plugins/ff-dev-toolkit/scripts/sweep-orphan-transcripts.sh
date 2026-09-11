#!/usr/bin/env bash
# sweep-orphan-transcripts.sh — 既存の孤児 Claude Code トランスクリプトを回収する
#
# Issue #280 / 公開 feel-flow/ff-dev-toolkit#8 の残課題。
# /merge-cleanup Step 5.5 は「今回削除した worktree の分」だけを回収する。
# 本スクリプトは <config>/projects/ 全体を走査し、jsonl の cwd がすべて
# 現存しないディレクトリだけを候補にする（証拠が無いものは触らない）。
#
# 保護の多層化（feel-flow/ff-dev-toolkit#13）: cwd 判定の前に、
#  (1) ディレクトリ名が現存パスへ解決できる（プロジェクトのルートが生存）
#  (2) 空でない memory/ が同居する（次回セッションが読む永続資産）
# のいずれかに当たれば触らない。ルート起動→worktree 作業→worktree 削除で
# cwd が全滅しても名前は生き続ける乖離から memory/ を守る。
#
# 既定は dry-run（一覧と見込み容量のみ）。破壊は --apply を明示したときだけ。
#
# 使い方:
#   bash scripts/sweep-orphan-transcripts.sh              # dry-run
#   bash scripts/sweep-orphan-transcripts.sh --apply      # アーカイブ + 元削除
#   bash scripts/sweep-orphan-transcripts.sh --help
#
# 環境変数:
#   CLAUDE_CONFIG_DIR                 既定 ~/.claude
#   FF_SWEEP_PROJECTS_DIR             projects の上書き
#   FF_SWEEP_ARCHIVE_DIR              アーカイブ先（既定 <config>/transcript-archives）
#
# 終了コード:
#   0  成功（dry-run / 回収完了 / 候補 0）
#   1  失敗（走査エラー・アーカイブ失敗など 1 件以上）
#   2  用法エラー
#
# bash 3.2 互換（macOS 標準 /bin/bash）。

set -euo pipefail

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

MODE="dry-run"
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) MODE="apply"; shift ;;
    --dry-run) MODE="dry-run"; shift ;;
    -h|--help)
      sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1（--apply / --dry-run / --help のみ）" >&2
      exit 2
      ;;
  esac
done

resolve_dir() {
  ( cd "$1" 2>/dev/null && pwd -P ) || return 1
}

# $1: 候補ディレクトリ
# 戻り値:
#   0 = 孤児（cwd は 1 件以上あり、いずれも現存しない）
#   2 = cwd を記録した jsonl が無い（触らない）
#   3 = 現存する cwd がある（稼働中の可能性 → 触らない）
#   4 = 走査エラー（触らない + 失敗報告）
collect_cwds() {
  local dir="$1"
  local scan_err="$WORK_TMP/scan_err"
  local values="" line="" value=""

  : > "$scan_err"
  : > "$WORK_TMP/cwds"
  values="$( { find "$dir" -type f -name '*.jsonl' -exec grep -oh '"cwd":"[^"]*"' {} + | sort -u ; } 2>"$scan_err" )" || true
  if [ -s "$scan_err" ]; then
    return 4
  fi
  [ -n "$values" ] || return 2

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    value="${line#\"cwd\":\"}"
    value="${value%\"}"
    [ -n "$value" ] || continue
    printf '%s\n' "$value" >> "$WORK_TMP/cwds"
  done <<< "$values"

  [ -s "$WORK_TMP/cwds" ] || return 2

  while IFS= read -r value; do
    [ -n "$value" ] || continue
    # 存在するディレクトリが 1 つでもあれば live
    if [ -d "$value" ]; then
      return 3
    fi
  done < "$WORK_TMP/cwds"

  return 0
}

# name_resolves_to_live: プロジェクトディレクトリ名（cwd の絶対パスを / → - で
# エンコードしたもの）を、実ファイルシステムを辿って現存パスへ解決できるか判定する。
#
# なぜ「名前をパスへ戻して現存確認」が正当なのか（PR #279 / ACE-279-1 との関係）:
#   #279 は「候補名は削除対象パスから機械的に導出したものなので、名前へのパターン
#   照合は入力の言い換えにすぎず対象の同一性を確認していない」として、削除の根拠を
#   名前に置く経路を全廃した。本関数はその逆で、削除ではなく保護の根拠として名前を
#   使い、しかも照合先は名前パターンではなく実ファイルシステム（対象から独立した外部
#   世界）である。名前が指すパスが今この瞬間に現存するかは、対象が記録した情報ではなく
#   OS へ問い合わせて初めて分かる事実であり、入力の再表示ではない。
#
# エンコードは非可逆（/ . - がいずれも - になり得る）なので tr '-' '/' では戻せない。
# しかも実測では 1 通りに定まらない — ドット始まりディレクトリ `.claude` は環境/時期で
# `-.claude`（ドット保持）と `--claude`（ドットも - 化）の両方が現れる。そこで「エンコード
# を逆算」せず、**先頭 `-` を `/` 起点にし、残り文字列を `-` 境界で最長優先に区切りながら、
# その prefix が指す実ディレクトリを直接 -d で確かめて降りる**。実ディレクトリに当たった
# パスだけが前進なので、判定材料は常に実ファイルシステム。子名にハイフンが含まれても
# 境界の取り方（最長→短）で取りこぼさない。行き止まりはバックトラックする。
#
# 子ディレクトリの列挙はしない（意図的）。~/.claude 配下には T/（4000+ エントリ）のような
# 極端に広い階層が実在し、階層ごとに全子を列挙して再エンコード照合すると非解決名で
# 事実上ハングする（実測）。rest から候補パスを構成して直接 stat する方式は、階層あたりの
# 分岐が「境界数 × ドット綴り 2」に限られ、広い階層でも一定時間で終わる。
#
# 既知の制約: セグメント内部のドット（`Finder.app` → `Finder-app`）は復元しない。
# ドット補完はセグメント先頭（`.claude` 等、ドット始まりディレクトリ）に限る。内部ドットの
# プロジェクトは名前解決では守れないが、これは fail-closed 側（memory ガード / 従来 cwd
# 判定へ委譲）に倒れるだけで、削除方向の誤りにはならない。実データでも稀。
#
# 例: -ROOT-x-ai-feel-chatbot は ROOT/x/ai/feel/chatbot（非現存・素朴分割）ではなく
#     ROOT/x/ai-feel-chatbot（現存・子名にハイフン）へ解決される（ROOT は絶対パス起点）。
#
# 三値判定（fail-closed の要）: 破壊的ツールなので「解決できない」と「判定できなかった」を
# 分ける。予算超過は「判定不能」であって「非現存の証拠」ではない。
#   0 = 現存パスへ解決できた（保護）
#   1 = 解決できない（従来 cwd 判定へ委ねる）
#   2 = 判定不能（予算超過）→ 呼び出し側で保護 + 報告（削除経路へ落とさない）
#
# 探索の総ステップ予算。深く分岐の多い非解決名でバックトラックが膨らんでも必ず停止する
# よう上限を設ける。超過は 1（非解決）ではなく 2（判定不能）で返し fail-closed 側（保護）へ
# 倒す。実在プロジェクト名は浅く各階層で一意に近いので正常系は遠く及ばない。
# テストが極小値を注入して予算切れ経路を検証できるよう env 上書きを許す（既定 4000）。
NAME_RESOLVE_BUDGET="${NAME_RESOLVE_BUDGET:-4000}"

# $1: プロジェクトディレクトリ名（basename）
# 戻り値: 0 = 解決（保護）/ 1 = 非解決（従来判定へ）/ 2 = 判定不能（保護 + 報告）
name_resolves_to_live() {
  local name="$1"
  # 絶対パス起点（先頭 -）のみ対象。相対名は解決不能扱い。
  # 先頭 - を除いた残りが空（name が "-" 単体）も対象外: ルート / への解決は
  # 「対象の同一性」を何も確認しないので生存とみなさない（少なくとも 1 セグメント
  # を実ディレクトリとして辿れたときだけ保護する）。
  case "$name" in
    -?*) ;;
    *) return 1 ;;
  esac
  NAME_RESOLVE_STEPS=0
  _name_resolve_rec "/" "${name#-}"
}

# _name_resolve_rec: base（確定済み実パス）配下で、rest の先頭を '-' 境界で最長優先に
# 区切りながら、その prefix が指す実ディレクトリへ直接降りる（子は列挙しない）。
# ドット始まりディレクトリ（`.claude` が `-.claude` とも `--claude` とも綴られる実測差）に
# 対応するため、各セグメント候補を「そのまま」と「先頭にドットを補う」の 2 通りで試す。
# rest は非空で呼ばれる。1 セグメント以上辿れたときだけ成功する。
# 戻り値: 0 = 解決 / 1 = 非解決 / 2 = 判定不能（予算超過が探索中に起きた）
# $1: 確定済み実パス（"/" または末尾スラッシュ無しの絶対パス）
# $2: 残りエンコード文字列（先頭に区切り無し。空でない）
_name_resolve_rec() {
  local base="$1" rest="$2"
  # rest が '-' で始まる = 直前の境界が '--'（元パスのドット始まりディレクトリを
  # ドットごと - 化した綴り）。先頭 '-' を剥がし、次のセグメントは「ドット始まり必須」
  # として解決する。これで `--claude` → `.claude` を辿れる。
  local force_dot=0
  if [ "${rest#-}" != "$rest" ]; then
    rest="${rest#-}"
    force_dot=1
  fi
  [ -n "$rest" ] || return 1
  local n="${#rest}" k seg nextrest trypath cand rc saw_undecided=0
  for (( k=n; k>=1; k-- )); do
    # 予算切れは「判定不能(2)」で返す。非解決(1)ではないので削除経路へ落とさない。
    NAME_RESOLVE_STEPS=$((NAME_RESOLVE_STEPS + 1))
    if [ "$NAME_RESOLVE_STEPS" -gt "$NAME_RESOLVE_BUDGET" ]; then
      return 2
    fi
    if [ "$k" -eq "$n" ]; then
      seg="${rest:0:k}"; nextrest=""
    else
      # 境界文字は '-' でなければならない
      if [ "${rest:k:1}" != "-" ]; then
        continue
      fi
      seg="${rest:0:k}"; nextrest="${rest:k+1}"
    fi
    # seg の綴りは 2 系統だけ:
    #  - force_dot=0（区切りが単一 '-'）: セグメントはそのまま。ドット始まりディレクトリ
    #    `.claude` は `-.claude` と綴られ、境界後の seg が既に ".claude"（ドット込み）に
    #    なるので bare で解ける。ここで無条件に ".$seg" を試すと、通常名 plain が隠し
    #    ディレクトリ .plain へ誤解決する過剰保護（真の孤児が消えない）を生むので試さない。
    #  - force_dot=1（区切りが '--'）: ドット始まり確定。".$seg" だけを試す（`--claude`→.claude）。
    if [ "$force_dot" -eq 1 ]; then
      cand=".$seg"
    else
      cand="$seg"
    fi
    # ".<空>" = "." / ".." は自己参照・親参照でループの元。1 セグメント以上前進を要求。
    case "$cand" in ''|.|..) continue ;; esac
    if [ "$base" = "/" ]; then
      trypath="/$cand"
    else
      trypath="$base/$cand"
    fi
    # symlink は辿らない（実体のみ）。外部脱出とループを防ぐ。
    if [ -d "$trypath" ] && [ ! -L "$trypath" ]; then
      if [ -z "$nextrest" ]; then
        return 0
      fi
      _name_resolve_rec "$trypath" "$nextrest"; rc=$?
      if [ "$rc" -eq 0 ]; then
        return 0
      elif [ "$rc" -eq 2 ]; then
        saw_undecided=1   # この枝は判定不能。他枝で解決できなければ 2 を返す。
      fi
    fi
  done
  [ "$saw_undecided" -eq 1 ] && return 2
  return 1
}

# has_nonempty_memory: 候補配下に空でない memory/ があるか。
# 名前解決が失敗しても、保護すべき資産（次回セッションが読む永続メモリ）そのものを
# 直接見て守るための安価なガード。memory/ 配下の任意の深さに 1 つでも非ディレクトリ
# 実体（ファイル・symlink 等）があれば「空でない」。
# 三値（collect_cwds の走査エラー扱いに揃える）:
#   0 = 空でない memory/ あり（保護）
#   1 = memory/ が無い or 空（従来判定へ委ねる）
#   2 = memory/ はあるが走査に失敗（判定不能）→ 呼び出し側で保護 + 報告
# $1: 候補の実パス
has_nonempty_memory() {
  local dir="$1"
  [ -d "$dir/memory" ] || return 1
  # find の失敗（権限等）を「memory 無し」に握り潰すと、守るべき資産を守れないまま
  # 削除経路へ落ちうる（silent fail-open）。stderr の有無で「空」と「読めない」を分け、
  # 読めないときは 2 を返して保護側へ倒す（collect_cwds と同じ思想）。
  local found="" merr="$WORK_TMP/memory_scan_err"
  : > "$merr"
  found="$(find "$dir/memory" -mindepth 1 ! -type d -print -quit 2>"$merr")" || true
  if [ -s "$merr" ]; then
    return 2
  fi
  [ -n "$found" ]
}

dir_kb() {
  local kb=""
  kb="$(du -sk "$1" 2>/dev/null | awk 'NR == 1 { print $1 }')" || kb=""
  if [ -z "$kb" ]; then
    echo 0
  else
    echo "$kb"
  fi
}

archive_and_remove() {
  # $1: CAND_NAME  $2: CAND_PATH  $3: CAND_REAL  $4: PROJECTS_REAL  $5: ARCHIVE_DIR
  local CAND_NAME="$1" CAND_PATH="$2" CAND_REAL="$3" PROJECTS_REAL="$4" ARCHIVE_DIR="$5"
  local CAND_KB ARCHIVE_STAMP ARCHIVE_FILE ARCHIVE_SEQ ARCHIVE_TMP
  local ARCHIVE_LIST ARCHIVE_ERR ARCHIVE_VERIFY TAR_OUT ARCHIVE_FAIL DIFF_RC
  local SRC_ENTRIES ARC_ENTRIES RECHECK_REAL ARCHIVE_KB

  CAND_KB="$(dir_kb "$CAND_REAL")"

  ARCHIVE_STAMP="$(date +%Y%m%d-%H%M%S)"
  ARCHIVE_FILE="$ARCHIVE_DIR/$CAND_NAME-$ARCHIVE_STAMP.tar.gz"
  ARCHIVE_SEQ=1
  while [ -e "$ARCHIVE_FILE" ] || [ -L "$ARCHIVE_FILE" ]; do
    ARCHIVE_FILE="$ARCHIVE_DIR/$CAND_NAME-$ARCHIVE_STAMP-$ARCHIVE_SEQ.tar.gz"
    ARCHIVE_SEQ=$((ARCHIVE_SEQ + 1))
  done

  ARCHIVE_TMP=""
  if ! ARCHIVE_TMP="$(mktemp "$ARCHIVE_DIR/.sweep-orphan-archive-XXXXXX")"; then
    echo "  ❌ 作業ファイルを作成できません: $CAND_NAME" >&2
    return 1
  fi
  ARCHIVE_LIST="$WORK_TMP/archive_list"
  ARCHIVE_ERR="$WORK_TMP/archive_error"
  ARCHIVE_VERIFY=""
  TAR_OUT=""
  ARCHIVE_FAIL=""

  if ! TAR_OUT="$(tar -czf "$ARCHIVE_TMP" -C "$PROJECTS_REAL" "./$CAND_NAME" 2>&1)"; then
    ARCHIVE_FAIL="tar が失敗しました"
  elif ! tar -tzf "$ARCHIVE_TMP" > "$ARCHIVE_LIST" 2>"$ARCHIVE_ERR"; then
    TAR_OUT="$(cat "$ARCHIVE_ERR")"
    ARCHIVE_FAIL="アーカイブを読み直せませんでした"
  else
    SRC_ENTRIES=""
    SRC_ENTRIES="$(find "$CAND_REAL" ! -type d 2>/dev/null | wc -l | tr -d ' ')" || SRC_ENTRIES=""
    ARC_ENTRIES="$(grep -cv '/$' "$ARCHIVE_LIST" || true)"
    if [ -z "$SRC_ENTRIES" ] || [ "$SRC_ENTRIES" != "$ARC_ENTRIES" ]; then
      TAR_OUT="元 ${SRC_ENTRIES:-?} 件 / アーカイブ ${ARC_ENTRIES} 件"
      ARCHIVE_FAIL="アーカイブの件数が元と一致しません"
    elif ! ARCHIVE_VERIFY="$(mktemp -d "$WORK_TMP/archive-verify-XXXXXX")"; then
      TAR_OUT="検証用ディレクトリを作成できません"
      ARCHIVE_FAIL="アーカイブと元を比較できませんでした"
    elif ! tar -xzf "$ARCHIVE_TMP" -C "$ARCHIVE_VERIFY" > /dev/null 2> "$ARCHIVE_ERR"; then
      TAR_OUT="$(cat "$ARCHIVE_ERR")"
      ARCHIVE_FAIL="アーカイブを検証用に展開できませんでした"
    else
      # marker との mtime 比較は、時計補正や時刻分解能の境界で未変更ファイルを
      # 誤検出し、同一 mtime の追記を見逃しうる。作成済みアーカイブを展開して
      # バイト列を直接比較し、tar 実行後の追加・削除・内容変更を判定する。
      DIFF_RC=0
      diff -r --no-dereference "$CAND_REAL" "$ARCHIVE_VERIFY/$CAND_NAME" > "$ARCHIVE_ERR" 2>&1 || DIFF_RC=$?
      if [ "$DIFF_RC" -eq 1 ]; then
        TAR_OUT="$(cat "$ARCHIVE_ERR")"
        ARCHIVE_FAIL="アーカイブ中に元が変更されました"
      elif [ "$DIFF_RC" -ne 0 ]; then
        TAR_OUT="$(cat "$ARCHIVE_ERR")"
        ARCHIVE_FAIL="アーカイブと元を比較できませんでした"
      fi
    fi
  fi

  if [ -n "$ARCHIVE_FAIL" ]; then
    echo "  ❌ ${ARCHIVE_FAIL}。元は残します: $CAND_NAME" >&2
    printf '%s\n' "$TAR_OUT" | sed 's/^/     /' >&2 || true
    rm -f "$ARCHIVE_TMP" || true
    return 1
  fi

  if ! mv "$ARCHIVE_TMP" "$ARCHIVE_FILE"; then
    echo "  ❌ アーカイブの確定に失敗。元は残します: $CAND_NAME" >&2
    rm -f "$ARCHIVE_TMP" || true
    return 1
  fi

  RECHECK_REAL=""
  if [ -L "$CAND_PATH" ] \
    || ! RECHECK_REAL="$(resolve_dir "$CAND_PATH")" \
    || [ "$RECHECK_REAL" != "$CAND_REAL" ] \
    || [ "$(dirname "$RECHECK_REAL")" != "$PROJECTS_REAL" ]; then
    echo "  ⚠️ 削除直前の再確認に失敗したため元は残します: $CAND_NAME" >&2
    echo "     アーカイブは作成済み: $ARCHIVE_FILE" >&2
    return 1
  fi

  if ! rm -rf "$CAND_REAL"; then
    echo "  ❌ アーカイブ後の削除に失敗（二重残存）: $CAND_REAL" >&2
    return 1
  fi

  ARCHIVE_KB="$(dir_kb "$ARCHIVE_FILE")"
  echo "  ✓ archived: $CAND_NAME (${CAND_KB} KB → ${ARCHIVE_KB} KB)"
  ARCHIVED_KB=$((ARCHIVED_KB + CAND_KB))
  ARCHIVE_OUT_KB=$((ARCHIVE_OUT_KB + ARCHIVE_KB))
  ARCHIVED_COUNT=$((ARCHIVED_COUNT + 1))
  return 0
}

WORK_TMP=""
WORK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/sweep-orphan-XXXXXX")" || {
  echo "ERROR: 一時ディレクトリを作成できません" >&2
  exit 1
}
trap 'rm -rf "$WORK_TMP"' EXIT

CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"
PROJECTS_DIR="${FF_SWEEP_PROJECTS_DIR:-$CLAUDE_HOME/projects}"
ARCHIVE_DIR="${FF_SWEEP_ARCHIVE_DIR:-$CLAUDE_HOME/transcript-archives}"

PROJECTS_REAL=""
if ! PROJECTS_REAL="$(resolve_dir "$PROJECTS_DIR")"; then
  echo "ERROR: projects ディレクトリを解決できません: $PROJECTS_DIR" >&2
  exit 1
fi

echo "🗂 孤児トランスクリプト sweep"
echo "   mode: $MODE"
echo "   projects: $PROJECTS_REAL"
echo "   archive: $ARCHIVE_DIR"
echo ""

ORPHAN_COUNT=0
ORPHAN_KB=0
SKIP_LIVE=0
SKIP_NO_CWD=0
SKIP_SYMLINK=0
SKIP_PATH=0
SKIP_NAME_ALIVE=0
SKIP_MEMORY=0
FAIL_COUNT=0
ARCHIVED_COUNT=0
ARCHIVED_KB=0
ARCHIVE_OUT_KB=0
ARCHIVE_DIR_READY=0

# projects 直下だけ（サブディレクトリの再帰は projects の構造上不要）
# bash 3.2: mapfile 無し。nullglob 相当は手動。
shopt -s nullglob
for CAND_PATH in "$PROJECTS_DIR"/*; do
  CAND_NAME="$(basename "$CAND_PATH")"
  case "$CAND_NAME" in
    ''|.|..) continue ;;
  esac

  if [ ! -d "$CAND_PATH" ]; then
    continue
  fi

  if [ -L "$CAND_PATH" ]; then
    SKIP_SYMLINK=$((SKIP_SYMLINK + 1))
    continue
  fi

  CAND_REAL=""
  if ! CAND_REAL="$(resolve_dir "$CAND_PATH")" \
    || [ "$(dirname "$CAND_REAL")" != "$PROJECTS_REAL" ]; then
    SKIP_PATH=$((SKIP_PATH + 1))
    echo "  ○ projects 直下へ解決されないためスキップ: $CAND_NAME"
    continue
  fi

  # Issue #13: cwd 判定より前に、保護を強める 2 つのガードを OR で入れる（どちらか一方
  # でも当たれば保護）。いずれも fail-closed 側で、cwd が「孤児」と言っても上書きして守る。
  # 各ガードは三値: 0=保護 / 1=従来判定へ委ねる / 2=判定不能（保護 + FAIL 計上して報告）。
  # 「解決できない(1)」と「判定できなかった(2)」を分け、破壊的ツールとして 2 は削除経路へ
  # 落とさず必ず保護する。
  # (1) ディレクトリ名が現存パスへ解決できる = そのプロジェクトのルートは生存中。
  #     worktree から起動して worktree を消すと cwd は全滅するが名前は生き続ける乖離を捕まえる。
  NAME_VERDICT=0
  name_resolves_to_live "$CAND_NAME" || NAME_VERDICT=$?
  if [ "$NAME_VERDICT" -eq 0 ]; then
    SKIP_NAME_ALIVE=$((SKIP_NAME_ALIVE + 1))
    continue
  elif [ "$NAME_VERDICT" -eq 2 ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "  ⚠️ 名前解決が判定不能（予算超過/走査エラー）のため保護: $CAND_NAME" >&2
    continue
  fi
  # (2) 空でない memory/ が同居する = 次回セッションが読む永続資産がある。
  #     名前解決が失敗しても、守るべき資産そのものを直接見て守る最後の砦。
  MEM_VERDICT=0
  has_nonempty_memory "$CAND_REAL" || MEM_VERDICT=$?
  if [ "$MEM_VERDICT" -eq 0 ]; then
    SKIP_MEMORY=$((SKIP_MEMORY + 1))
    continue
  elif [ "$MEM_VERDICT" -eq 2 ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "  ⚠️ memory/ の走査が判定不能（読み取り不可）のため保護: $CAND_NAME" >&2
    continue
  fi

  VERDICT=0
  collect_cwds "$CAND_REAL" || VERDICT=$?
  case "$VERDICT" in
    0)
      KB="$(dir_kb "$CAND_REAL")"
      ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
      ORPHAN_KB=$((ORPHAN_KB + KB))
      SAMPLE="$(head -3 "$WORK_TMP/cwds" | tr '\n' ' ')"
      if [ "$MODE" = "dry-run" ]; then
        echo "  · orphan (${KB} KB): $CAND_NAME"
        echo "      cwd 例: $SAMPLE"
      else
        if [ "$ARCHIVE_DIR_READY" != "1" ]; then
          if ! mkdir -p "$ARCHIVE_DIR" 2>/dev/null; then
            echo "ERROR: アーカイブ先を作成できません: $ARCHIVE_DIR" >&2
            exit 1
          fi
          ARCHIVE_DIR_READY=1
        fi
        echo "  → 回収: $CAND_NAME (${KB} KB)"
        if ! archive_and_remove "$CAND_NAME" "$CAND_PATH" "$CAND_REAL" "$PROJECTS_REAL" "$ARCHIVE_DIR"; then
          FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
      fi
      ;;
    2)
      SKIP_NO_CWD=$((SKIP_NO_CWD + 1))
      ;;
    3)
      SKIP_LIVE=$((SKIP_LIVE + 1))
      ;;
    4)
      FAIL_COUNT=$((FAIL_COUNT + 1))
      echo "  ⚠️ jsonl 走査エラーのため保護: $CAND_NAME" >&2
      ;;
    *)
      FAIL_COUNT=$((FAIL_COUNT + 1))
      echo "  ⚠️ 想定外の判定 ($VERDICT): $CAND_NAME" >&2
      ;;
  esac
done
shopt -u nullglob

echo ""
echo "=== サマリー ==="
echo "mode: $MODE"
echo "孤児候補: ${ORPHAN_COUNT} 件 / ${ORPHAN_KB} KB"
echo "スキップ live(cwd 現存): ${SKIP_LIVE}"
echo "スキップ 名前生存(名前→現存パス): ${SKIP_NAME_ALIVE}"
echo "スキップ memory 保護(空でない memory/): ${SKIP_MEMORY}"
echo "スキップ cwd 無し: ${SKIP_NO_CWD}"
echo "スキップ symlink: ${SKIP_SYMLINK}"
echo "スキップ path 保護: ${SKIP_PATH}"
echo "失敗: ${FAIL_COUNT}"
# スキップ理由は上から順（symlink/path → 名前生存 → memory → cwd）に先勝ちで数える。
# 名前が現存パスへ解決される稼働中プロジェクトは「名前生存」に入り、cwd 現存判定
# （live）まで到達しないため、live は「名前非解決 かつ memory 無し かつ cwd 現存」の残余。
echo "（スキップ理由は先勝ち。名前生存/memory は cwd 判定より前に評価される）"
if [ "$MODE" = "apply" ]; then
  echo "アーカイブ回収: ${ARCHIVED_COUNT} 件 / 元 ${ARCHIVED_KB} KB → 書庫 ${ARCHIVE_OUT_KB} KB"
else
  echo "（dry-run のため削除していません。回収するには --apply を付けて再実行）"
fi

# subagents 方針の短い注記（Issue #281）
echo ""
echo "注: 孤児と判定したプロジェクトディレクトリ全体（配下の subagents/ を含む）を回収します。"
echo "    稼働中プロジェクト内の subagents/ だけを年齢で消すことはしません（所有証拠が無いため）。"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
