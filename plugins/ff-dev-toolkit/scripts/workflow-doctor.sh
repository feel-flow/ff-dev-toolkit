#!/usr/bin/env bash
# ============================================================================
# workflow-doctor.sh — 導入先の入口規範がスキルの判定順と矛盾していないかを検査する
# ============================================================================
#
# 導入先の 1 つで、`/out-of-scope-issue` の YAGNI ゲートと束ねの設計が
# 導入先の CLAUDE.md（「別 Issue 化を口にした時点で必ず起票」）・グローバル CLAUDE.md（「issue化必須」）・
# Stop hook（deferral 語 → `gh issue create` を要求）に上書きされ、open Issue が 95 件・2 日で 28 件起票まで
# 膨らんだ。スキルは「増やさない」設計なのに入口が「必ず増やす」と書かれている状態は、スキル側からは
# 見えない。本スクリプトはその前提を read-only で検査し、ずれを重大度つきで報告する。
#
# 検査（7 項目。7 は INFO のみ。番号は SKILL.md の表と同じ）:
#   1. 判定順の矛盾   — 入口文書（CLAUDE.md / AGENTS.md / .cursor/ / copilot-instructions / グローバル CLAUDE.md）
#                       に「発見 = 起票」の旧文言が無いこと
#   2. 節の必須語     — CLAUDE.md「## スコープ外の発見」節に YAGNI と bundle が在ること（節が無ければ WARN）
#   3. hook の文言    — settings.json の Stop hook の command 文字列と、それが参照するスクリプトの reminder が
#                       「即起票」だけで YAGNI を持たない形になっていないこと
#   4. 起票の受け皿   — `bundle` ラベルの open Issue が在ること（無ければ統合先が無く新規へ落ちる）
#   5. ラベルの実在   — bundle / epic / follow-up / priority:* が在ること
#   6. 親無し Issue   — open Issue のうち parent が無く epic / bundle でもないものの件数
#   7. 環境変数       — RETROSPECTIVE_FILING（自動起票の既定を利用者が把握しているか）
#
# 4〜6 は gh を使う。`--offline` で飛ばす（結果は SKIP として数え、緑にはしない）。
# `--fix` は持たない（意図的）。CLAUDE.md の節を定型文へ置換する自動修正は、導入先の文脈（節の前後・
# 他節からの参照）を壊しうるので、置換案を FIXTEXT 行で印字し、適用は人が行う。
#
# 使い方:
#   workflow-doctor.sh [--root <dir>] [--global-claude <path>] [--settings <path>]... [--offline] [--repo OWNER/REPO]
#     --root           導入先リポジトリのルート（既定: cwd から git rev-parse --show-toplevel）
#     --global-claude  グローバル CLAUDE.md のパス（既定: $CLAUDE_CONFIG_DIR/CLAUDE.md、無ければ ~/.claude/CLAUDE.md）
#     --settings       Stop hook を読む settings.json（繰り返し可。既定: <root>/.claude/settings.json、<root>/.claude/settings.local.json、$CLAUDE_CONFIG_DIR/settings.json）
#     --offline        gh を使う検査（4〜6）を SKIP にする
#     --repo           gh の対象（既定: origin から解決）
#
# 出力: 1 行 1 所見 `<LEVEL>\t<番号>\t<所見>`（LEVEL は FAIL / WARN / INFO / OK / SKIP）。FIXTEXT 行は置換案。
#       末尾に `SUMMARY fail=<n> warn=<n> skip=<n>`。
# 終了コード: 0 = FAIL 0 件 / 1 = FAIL あり / 2 = 対象を解決できない（検査不成立）
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

set -u
export LC_ALL=C

ROOT=""; GLOBAL_CLAUDE=""; OFFLINE=0; REPO=""; SETTINGS=()
need_value() { # $1 option, $2 remaining argc — 値なしで最終引数のとき `shift 2` が空振りして同じ分岐を回り続ける（レビューで実測）ので、先に止める
  [ "$2" -ge 2 ] || { echo "workflow-doctor: $1 には値が要ります" >&2; exit 2; }
}
while [ $# -gt 0 ]; do
  case "$1" in
    --root) need_value "$1" $#; ROOT="$2"; shift 2 ;;
    --global-claude) need_value "$1" $#; GLOBAL_CLAUDE="$2"; shift 2 ;;
    --settings) need_value "$1" $#; SETTINGS+=("$2"); shift 2 ;;
    --offline) OFFLINE=1; shift ;;
    --repo) need_value "$1" $#; REPO="$2"; shift 2 ;;
    -h|--help) awk 'NR >= 2 && /^# ff-dev-toolkit-script-root-guard:st[a]rt$/ { exit } NR >= 2 { print }' "$0"; exit 0 ;;   # marker 文字列を分割して書く（marker 件数の検査に当てない）
    *) echo "workflow-doctor: 不明な引数: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "workflow-doctor: 導入先のルートを解決できません（--root を指定してください）" >&2
  exit 2
fi
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
[ -n "$GLOBAL_CLAUDE" ] || GLOBAL_CLAUDE="$CONFIG_DIR/CLAUDE.md"
if [ ${#SETTINGS[@]} -eq 0 ]; then
  # 配布文書（ai-tools-integration.md）が settings.local.json への hook 配置も案内しているので既定対象に含める
  SETTINGS=("$ROOT/.claude/settings.json" "$ROOT/.claude/settings.local.json" "$CONFIG_DIR/settings.json")
fi

FAIL=0; WARN=0; SKIP=0
emit() { # level no message
  printf '%s\t%s\t%s\n' "$1" "$2" "$3"
  case "$1" in FAIL) FAIL=$((FAIL + 1)) ;; WARN) WARN=$((WARN + 1)) ;; SKIP) SKIP=$((SKIP + 1)) ;; esac
}

# ---- 1. 判定順の矛盾（旧文言） --------------------------------------------------
# 文字クラスは使わない（BSD grep は C ロケールで多バイトの [^。] を解釈できず一致 0 件 = fail-open。
# 導入先で実測）。固定文字列と .* だけで書く。
OLD_PATTERN='issue化必須|必ず起票|口にした時点で.*起票|即 Issue 起票|即起票'
targets=()
for f in CLAUDE.md AGENTS.md .github/copilot-instructions.md; do
  [ -f "$ROOT/$f" ] && targets+=("$ROOT/$f")
done
if [ -d "$ROOT/.cursor" ]; then
  while IFS= read -r f; do targets+=("$f"); done < <(find "$ROOT/.cursor" -type f \( -name '*.md' -o -name '*.mdc' \) | sort)
fi
[ -f "$GLOBAL_CLAUDE" ] && targets+=("$GLOBAL_CLAUDE")
if [ ${#targets[@]} -eq 0 ]; then
  emit WARN 1 "入口文書が 1 つも無い（CLAUDE.md / AGENTS.md / .cursor/ / copilot-instructions / グローバル CLAUDE.md）"
else
  hits="$(grep -nHE "$OLD_PATTERN" "${targets[@]}" 2>&1)"; rc=$?
  if [ "$rc" -ge 2 ]; then
    emit FAIL 1 "grep が失敗した（rc=${rc}）: $(printf '%s' "$hits" | head -1)"
  elif [ "$rc" -eq 0 ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && emit FAIL 1 "「発見 = 起票」の旧文言: ${line}"
    done <<EOF
$hits
EOF
    printf 'FIXTEXT\t1\t%s\n' "判定順を YAGNI → 同 PR インライン → 既存 bundle へ追記 → bundle 単位で新規 の 4 段へ書き換える（正本: docs-template/05-operations/deployment/git-workflow.md「bundle（子を全件 1 PR で束ねる着手単位）」と out-of-scope-issue §1.2〜§3.1）"
  else
    emit OK 1 "旧文言 0 件（対象 ${#targets[@]} ファイル）"
  fi
fi

# ---- 2. 節の必須語 ---------------------------------------------------------------
if [ -f "$ROOT/CLAUDE.md" ]; then
  section="$(awk '/^## スコープ外の発見/{flag=1; print; next} /^## /{if(flag){exit}} flag{print}' "$ROOT/CLAUDE.md")"
  if [ -z "$section" ]; then
    emit WARN 2 "CLAUDE.md に「## スコープ外の発見」節が無い（判定順を書く場所が無い。4 段の定型文を置く）"
  else
    for word in YAGNI bundle; do
      if grep -q "$word" <<<"$section"; then
        emit OK 2 "「スコープ外の発見」節に ${word} あり"
      else
        emit FAIL 2 "「スコープ外の発見」節に ${word} が無い（判定順が YAGNI 先行・bundle 既定から外れている）"
      fi
    done
  fi
else
  emit WARN 2 "CLAUDE.md が無い（--root の取り違えか、未導入）"
fi

# ---- 3. hook の文言 --------------------------------------------------------------
# inline の command 文字列とスクリプト本文で**同じ判定**を使う（配置方法で結果が変わらないように 1 関数に集約）。
#   0 = 旧文言なし / 1 = 「発見 = 起票」の旧文言があり YAGNI を持たない / 2 = STEP3 が gh issue create で即起票のままで bundle への追記が無い
judge_reminder() { # $1 text
  local t="$1"
  if grep -qE "$OLD_PATTERN" <<<"$t" && ! grep -q 'YAGNI' <<<"$t"; then return 1; fi
  if grep -q 'gh issue create で即起票' <<<"$t" && ! grep -q 'bundle' <<<"$t"; then return 2; fi
  return 0
}
hook_checked=0
for s in "${SETTINGS[@]}"; do
  [ -f "$s" ] || continue
  if ! command -v jq >/dev/null 2>&1; then
    emit SKIP 3 "jq が無いため settings.json（${s}）の Stop hook を読めない"
    continue
  fi
  # jq の失敗（settings.json が壊れている等）を「設定は無い」に畳まない — 旧 reminder が実在しても INFO で通る fail-open になる
  cmds="$(jq -r '.hooks.Stop[]?.hooks[]?.command // empty' "$s" 2>&1)"; jq_rc=$?
  if [ "$jq_rc" -ne 0 ]; then
    emit FAIL 3 "settings.json（${s}）を解釈できない（jq rc=${jq_rc}）: $(printf '%s' "$cmds" | head -1)"
    continue
  fi
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    # inline のコマンド文字列そのものにも同じ判定を当てる（スクリプトを経由しない reminder を取りこぼさない）
    judge_reminder "$cmd"; jr=$?
    if [ "$jr" -ne 0 ]; then
      case "$jr" in
        1) emit FAIL 3 "Stop hook の command 文字列に「発見 = 起票」の旧文言: $(printf '%s' "$cmd" | cut -c1-120)" ;;
        2) emit FAIL 3 "Stop hook の command 文字列が STEP3 = gh issue create で即起票 のまま（既存 bundle への追記が無い）: $(printf '%s' "$cmd" | cut -c1-120)" ;;
      esac
      hook_checked=$((hook_checked + 1))
      continue
    fi
    # command 文字列から実在するパス片を全部拾う（"python3 \"$HOME/.claude/hooks/x.py\"" 形。2 本目以降も見る）
    paths="$(printf '%s' "$cmd" | grep -oE '[^" ]+\.(py|sh|mjs|js)')"
    [ -n "$paths" ] || continue
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      path="${path/\$\{HOME\}/$HOME}"; path="${path/\$HOME/$HOME}"; path="${path/#\~/$HOME}"
      path="${path/\$\{CLAUDE_PROJECT_DIR\}/$ROOT}"; path="${path/\$CLAUDE_PROJECT_DIR/$ROOT}"
      case "$path" in /*) ;; *) path="$ROOT/$path" ;; esac   # 相対パスは --root 基準（起動時 cwd に依存させない）
      hook_checked=$((hook_checked + 1))
      [ -f "$path" ] || { emit SKIP 3 "Stop hook が指すスクリプトを読めない（未検査）: ${path}"; continue; }
      judge_reminder "$(cat "$path")"; jr=$?
      case "$jr" in
        1) emit FAIL 3 "Stop hook の reminder に「発見 = 起票」の旧文言があり YAGNI を持たない: ${path}" ;;
        2) emit FAIL 3 "Stop hook の reminder が STEP3 = gh issue create で即起票 のまま（既存 bundle への追記が無い）: ${path}" ;;
        *) emit OK 3 "Stop hook の reminder に旧文言なし: ${path}" ;;
      esac
    done <<EOF
$paths
EOF
  done <<EOF
$cmds
EOF
done
[ "$hook_checked" -gt 0 ] || emit INFO 3 "Stop hook でスクリプトを参照する設定は無い"

# ---- 4〜6. gh を使う検査 ---------------------------------------------------------
if [ "$OFFLINE" -eq 1 ]; then
  emit SKIP 4 "--offline のため未検査（bundle の open Issue）"
  emit SKIP 5 "--offline のため未検査（ラベルの実在）"
  emit SKIP 6 "--offline のため未検査（親無し Issue）"
elif ! command -v gh >/dev/null 2>&1; then
  emit SKIP 4 "gh が無いため未検査"; emit SKIP 5 "gh が無いため未検査"; emit SKIP 6 "gh が無いため未検査"
else
  if [ -z "$REPO" ]; then
    REPO="$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##')"
  fi
  if [ -z "$REPO" ]; then
    raw_url="$(git -C "$ROOT" remote get-url origin 2>/dev/null || echo '(origin なし)')"
    emit SKIP 4 "対象リポジトリを解決できない（origin=${raw_url}。https://github.com/ と git@github.com: 以外は --repo OWNER/REPO を指定）"; emit SKIP 5 "同左"; emit SKIP 6 "同左"
  else
    labels="$(gh label list --repo "$REPO" --limit 200 --json name --jq '.[].name' 2>/dev/null)"; lrc=$?
    if [ "$lrc" -ne 0 ] || [ -z "$labels" ]; then
      emit SKIP 5 "ラベル一覧を信用できない（取得失敗または空）— 実在を断定しない"
      emit SKIP 4 "ラベル一覧を取れないため bundle の受け皿も未検査"
    else
      for want in bundle epic follow-up; do
        if grep -qxF "$want" <<<"$labels"; then
          emit OK 5 "ラベル ${want} あり"
        else
          emit WARN 5 "ラベル ${want} が無い（/setup-github-labels で整備できる）"
        fi
      done
      # 優先度ラベルは命名がプロジェクト依存（toolkit 既定 priority:* / 導入先の実例 P1-High 等）なので、接頭辞で見る
      if grep -qE '^(priority:|P[0-9]-)' <<<"$labels"; then
        emit OK 5 "優先度ラベルあり（priority:* または P<n>-*）"
      else
        emit WARN 5 "優先度ラベルが無い（priority:* / P<n>-* のどちらも無い。/setup-github-labels で整備できる）"
      fi
      if grep -qxF bundle <<<"$labels"; then
        n="$(gh issue list --repo "$REPO" --state open --label bundle --limit 200 --json number --jq 'length' 2>/dev/null || echo "")"
        if [ -z "$n" ]; then emit SKIP 4 "bundle の open Issue を取得できない"
        elif [ "$n" -eq 0 ]; then emit WARN 4 "open な bundle が 0 件（統合先が無く、発見が新規の単独 Issue へ落ちる）"
        else emit OK 4 "open な bundle ${n} 件"; fi
      else
        emit WARN 4 "bundle ラベルが無いため受け皿を作れない"
      fi
    fi
    # 親無し Issue（epic / bundle 以外で parent が無いもの）
    owner="${REPO%%/*}"; name="${REPO##*/}"
    # `gh issue list --limit` は打ち切りを教えないので、REST をページングして全件を読む（PR は除外）
    nums="$(gh api --paginate "repos/${REPO}/issues?state=open&per_page=100" --jq '.[] | select(.pull_request == null) | select((.labels | map(.name) | index("epic")) == null and (.labels | map(.name) | index("bundle")) == null) | .number' 2>/dev/null)"; nrc=$?
    if [ "$nrc" -ne 0 ]; then
      emit SKIP 6 "open Issue の一覧を取得できない（gh rc=${nrc}）— 親無しの有無を断定しない"
    elif [ -z "$nums" ]; then
      emit INFO 6 "epic / bundle 以外の open Issue は無い"
    else
      # 100 件ずつのバッチで parent を読む（1 クエリに全件を展開するとクエリ長・cost 上限に触れうる）
      orphans=""; grc=0; batch=""; bc=0
      flush_batch() {
        local q='query{ repository(owner:"'"$owner"'",name:"'"$name"'"){'"$batch"' } }' out
        out="$(gh api graphql -f query="$q" --jq '.data.repository | to_entries[] | select(.value.parent == null) | .value.number' 2>/dev/null)" || return 1
        orphans="${orphans}${orphans:+
}${out}"
      }
      for n in $nums; do
        batch="$batch i$n: issue(number:$n){ number parent{ number } }"; bc=$((bc + 1))
        if [ "$bc" -ge 100 ]; then flush_batch || { grc=1; break; }; batch=""; bc=0; fi
      done
      if [ "$grc" -eq 0 ] && [ -n "$batch" ]; then flush_batch || grc=1; fi
      if [ "$grc" -ne 0 ]; then
        emit SKIP 6 "GraphQL で parent を取得できない"
      else
        c="$(printf '%s\n' "$orphans" | grep -c '.' || true)"
        if [ "$c" -gt 0 ]; then
          emit WARN 6 "親無し（parent 無し・epic / bundle でもない）の open Issue が ${c} 件: $(printf '%s' "$orphans" | tr '\n' ' ')"
        else
          emit OK 6 "親無しの open Issue は 0 件"
        fi
      fi
    fi
  fi
fi

# ---- 7. 環境変数 ---------------------------------------------------------------
if [ -n "${RETROSPECTIVE_FILING:-}" ]; then
  emit INFO 7 "RETROSPECTIVE_FILING=${RETROSPECTIVE_FILING}"
else
  emit INFO 7 "RETROSPECTIVE_FILING 未設定（/retrospective の既定は承認を待たずに自動起票。止めるなら ask）"
fi

printf 'SUMMARY fail=%d warn=%d skip=%d\n' "$FAIL" "$WARN" "$SKIP"
[ "$FAIL" -eq 0 ]
