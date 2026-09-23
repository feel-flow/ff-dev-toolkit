#!/usr/bin/env bash
#
# 工数 KPI レポート — Issue 本文の ff-effort ブロックを集計する。
#
# データの SSOT は GitHub Issue 本文であり、本スクリプトは派生の集計器である。
# 台帳ファイルを持たないのは、Issue との同期問題を新設しないため。
#
# 2 つの KPI は集計方法が非対称で、これ自体が KPI の定義である:
#   圧縮率 … 人間予定と AI 実績が【両方揃った Issue だけ】を対にして合計し、
#            合計してから除算する（対外指標。総量として何人日分を何人日で終えたか）。
#            片側だけ欠けた Issue を分母にだけ入れると、対外指標が静かに過小に出る
#   乖離率 … 件ごとに算出し中央値と p90（精度指標。1 件の大外れで平均を汚さない）
#
# 母集団から外したものは必ず件数で出す。黙って落とすと「一部の Issue だけの値」が
# 全体の値に見える。除外は 5 種を区別する:
#   noblock       … ff-effort ブロックが無い
#   planned_only  … 実績が未記入（PR を伴わずクローズ等）。実績 0 ではない
#   malformed     … 記入されているが読めない（書式ずれ・重複キー・未知の effort_unit）
#   unit_mismatch … 値の単位がブロックの単位宣言と食い違う（下の「単位」）
#   no_human_planned … 実績はあるが人間予定が無く、圧縮率の対を作れない
# 「記入されていない」と「記入されているが読めない」を同じ数字に合流させると、
# 記入ミスが KPI から静かに消える。
#
# 単位: 集計は人時（h）で行う。`- effort_unit: h` 行を持つブロックは値を `N.Nh` で読み、
# その行が無い旧ブロックは値を `N.Nd`（人日）で読んで ×8 で人時へ正規化し、同じ母集団へ
# 入れる（旧ブロックを捨てると較正母集団が消える）。単位宣言と値の単位が食い違うもの
# （`effort_unit: h` なのに `d` 付きの値、宣言が無いのに `h` 付きの値）は黙って混ぜず
# unit_mismatch として件数で出す。乖離率・圧縮率は比なので単位に依らない。
#
# 速度指標（--format kv の wallclock_* / instruction_bytes_* / review_rounds_* /
# gate_minutes_*）は、/close-issue が書き戻す effort_wallclock_actual /
# effort_instruction_bytes / effort_change_class を変更クラス別に集計する。供給源が
# まだ配線されていない指標は `(unavailable)`、配線済みだが該当クラスに実測が無いものは
# `(unmeasured)` を出し、どちらも 0 と区別する。
#
# --issue-metrics N は Issue 本文ではなく、hook が書くリポジトリ外の記録
# （${FF_DEV_TOOLKIT_STATE_DIR:-$HOME/.config/ff-dev-toolkit}/metrics/ の wallclock.tsv /
# instruction-bytes.tsv）から 1 Issue 分の実測を読む（/close-issue の書き戻し元）。記録置き場は
# リポジトリ横断で共有されるので、--repo-dir（既定はカレントのリポジトリ）の行だけを採る。
#
# 抽出に grep を使わない: grep は「不一致=1 / エラー=2」だが、別実装へ差し替えられた
# 環境ではエラーでも 1 を返すことがあり、`rc<=1 なら正常` の判定が fail-open へ反転する。
# awk は不一致でも 0 を返すので、rc!=0 が本物の失敗だけを意味する。
#
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
# 中断コードは本スクリプトの契約の 2（起動の仕方が正しくない）。1 は入力の取得・展開の
# 失敗で、集計へ進んだうえでの失敗を意味するので、ガードの停止とは分ける。

# 閾値の正本は skills/close-issue/SKILL.md（工数実績セクションの規則）。
# ここと skills/retrospective/references/effort.md が複製で、tests/effort-contract が 3 箇所の
# 一致を機械照合する。変えるときは 3 箇所すべてを同時に直すこと。
#
# 2026-09-10 に 3 リポジトリ 78 件で較正した値（旧 0.77 / 1.30 は暫定値）。
# 上限は母集団の p75 = 1.40、下限はその逆数 1/1.40 = 0.71。導出手順は正本側にある。
VARIANCE_LOWER="0.71"
VARIANCE_UPPER="1.40"

# --- 決定木の葉の到達（hooks/decision-tree.sh が Stop で書く leaves.tsv の読み手）-----------
# Issue の集計とは独立した別モード。記録の置き場は Wave 0 の wall-clock / 読み込みバイト記録と
# 同じ ${FF_DEV_TOOLKIT_STATE_DIR:-$HOME/.config/ff-dev-toolkit}/metrics/ で、1 行 1 レコード
# （<ISO 時刻> <epoch> <Issue> <session> <kind> <名> <via> <repo>。書式は hook のヘッダが正本）。
# 「N 日間到達 0 の葉」を列挙する。表記は同じ置き場を読む他の指標と揃える: 記録が無い・
# 読めないは `(unmeasured)`（0 件の到達ではない）、供給源がまだ配線されていない葉（各 hook の
# 発火と doc の葉の参照は v0 では誰も書かない）は `(unavailable)`。どちらも 0 と区別し、葉の
# 列挙に混ぜない。読めない行（フィールド数違い・epoch が整数でない）は黙って落とさず件数で出す。
# 記録置き場はリポジトリ横断で共有されるので、wall-clock の読み手と同じく repo 列が
# --repo-dir（既定はカレントのリポジトリ）と一致する行だけを採る。重複行は集合として畳む。
# 失敗でワークフローを止めないため、このモードは引数の誤り以外 exit 0 で終わる。
report_unreached_leaves() { # $1=days $2=format $3=metrics_dir $4=repo_dir
  local days="$1" format="$2" metrics_dir="$3" repo_dir="$4" script_dir router leaves now cutoff repo
  script_dir="$(CDPATH= cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  router="$script_dir/decision-tree/route.sh"
  leaves="$metrics_dir/leaves.tsv"
  case "$days" in ''|*[!0-9]*|0) echo "--days は正の整数を指定してください: ${days}" >&2; return 2 ;; esac
  [ -f "$router" ] || { echo "決定木のルータがありません: ${router}" >&2; return 1; }
  local tree_leaves
  tree_leaves="$(bash "$router" --leaves 2>/dev/null)" || { echo "決定木の葉を列挙できません（route.sh --leaves が失敗）" >&2; return 1; }
  [ -n "$tree_leaves" ] || { echo "決定木の葉が 0 件です（木データを確認してください）" >&2; return 1; }
  now="$(date -u +%s)"
  cutoff=$((now - days * 86400))
  repo="$(metrics_repo_key "$repo_dir")"

  local source="" records=0 in_window=0 malformed=0
  if [ -z "$repo" ]; then
    source="(unmeasured)"
  elif [ -f "$leaves" ] && [ -r "$leaves" ]; then
    source="$leaves"
  else
    source="(unmeasured)"
  fi

  # 到達した葉（期間内・対象 repo）の集合を「kind:name」の行で作る
  local reached=""
  if [ "$source" = "$leaves" ]; then
    reached="$(awk -F'\t' -v cutoff="$cutoff" -v repo="$repo" '
      NF != 8 || $2 !~ /^[0-9]+$/ { bad++; next }
      $8 != repo { next }
      { total++ }
      $2 + 0 >= cutoff { win++; print $5 ":" $6 }
      END { printf "__records=%d\n__in_window=%d\n__malformed=%d\n", total + 0, win + 0, bad + 0 }
    ' "$leaves")" || { echo "leaves.tsv の走査に失敗しました: ${leaves}" >&2; return 1; }
    records="$(printf '%s\n' "$reached" | awk -F= '/^__records=/ { print $2; exit }')"
    in_window="$(printf '%s\n' "$reached" | awk -F= '/^__in_window=/ { print $2; exit }')"
    malformed="$(printf '%s\n' "$reached" | awk -F= '/^__malformed=/ { print $2; exit }')"
    reached="$(printf '%s\n' "$reached" | awk '!/^__/' | LC_ALL=C sort -u)"
  fi
  local nl='
'
  local reached_set="${nl}${reached}${nl}"
  # 供給源が未配線の葉（decision-tree 以外の hook と doc の葉）は到達 0 ではなく (unavailable) に数える
  local unreached="" unavailable=0 kind name line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    kind="${line%%	*}"; name="$(printf '%s' "$line" | cut -f2)"
    if { [ "$kind" = "hook" ] && [ "$name" != "decision-tree" ]; } || [ "$kind" = "doc" ]; then
      unavailable=$((unavailable + 1)); continue
    fi
    case "$reached_set" in
      *"${nl}${kind}:${name}${nl}"*) ;;
      *) unreached="${unreached}${kind}:${name}${nl}" ;;
    esac
  done <<EOF
$tree_leaves
EOF
  local n_unreached
  n_unreached="$(printf '%s' "$unreached" | awk 'NF { n++ } END { print n + 0 }')"

  if [ "$format" = "kv" ]; then
    echo "leaves_days=${days}"
    echo "metrics_dir=${metrics_dir}"
    echo "repo=${repo:-(unresolved)}"
    echo "leaves_source=${source}"
    echo "leaves_records=${records}"
    echo "leaves_in_window=${in_window}"
    echo "leaves_malformed=${malformed}"
    echo "leaves_unavailable=${unavailable}"
    if [ "$source" = "$leaves" ]; then
      echo "leaves_unreached=${n_unreached}"
      echo "leaves_unreached_list=$(printf '%s' "$unreached" | awk 'NF' | tr '\n' ',' | sed 's/,$//')"
    else
      echo "leaves_unreached=${source}"
      echo "leaves_unreached_list=${source}"
    fi
    return 0
  fi

  printf '# 決定木の葉の到達（直近 %s 日間）\n\n' "$days"
  printf '既知の残差（v0）: 列挙できるのは skill の葉と route だけ。decision-tree 以外の hook と doc の葉は到達の供給源が未配線なので、到達 0 ではなく (unavailable) として件数だけ出す（0 と区別する）\n'
  printf 'repo:           %s\n' "${repo:-(unresolved)}"
  if [ "$source" != "$leaves" ]; then
    printf '記録:           %s（%s が無い・読めない、または repo を引けない）\n' "$source" "$leaves"
    printf '到達 0 の葉:    %s（記録が無いので 0 件とは言えない）\n' "$source"
    printf '供給源が未配線の葉: (unavailable) %s 件（decision-tree 以外の hook と doc。v0 では発火・参照を記録しない）\n' "$unavailable"
    return 0
  fi
  printf '記録:           %s（対象 repo %s 行 / 期間内 %s 行 / 読めない行 %s 行）\n' "$leaves" "$records" "$in_window" "$malformed"
  if [ "$malformed" -gt 0 ]; then
    printf '  ⚠️ 読めない行が %s 行あります（フィールド数 8 でない・epoch が整数でない）。落とした行の葉は到達に数えていません\n' "$malformed"
  fi
  printf '到達 0 の葉:    %s 件\n' "$n_unreached"
  printf '%s' "$unreached" | awk 'NF { print "  - " $0 }'
  printf '供給源が未配線の葉: (unavailable) %s 件（decision-tree 以外の hook と doc。v0 では発火・参照を記録しない）\n' "$unavailable"
  return 0
}

usage() {
  cat >&2 <<'USAGE'
Usage: effort-report.sh [options]

  --input FILE     gh issue list --json number,body の出力（JSON 配列）を読む。
                   省略時は --repo から gh で取得する
  --repo OWNER/REPO  取得元リポジトリ（--input 省略時に必須）
  --state STATE    all | open | closed（既定 all）
  --limit N        取得上限（既定 200）
  --format FORMAT  text（既定・日本語レポート） | kv（key=value の機械可読形式）
  --issue-metrics N  Issue 本文を読まず、hook の記録から Issue N の wall-clock と
                   指示読み込みバイトを kv で出す（記録が無ければ (unmeasured)。常に exit 0）
  --metrics-dir DIR  hook の記録置き場（既定 ${FF_DEV_TOOLKIT_STATE_DIR:-$HOME/.config/ff-dev-toolkit}/metrics）
  --repo-dir DIR   --issue-metrics で絞るリポジトリ（既定はカレントディレクトリのリポジトリ）。
                   記録置き場はリポジトリ横断で共有されるので、別リポジトリの同じ番号を混ぜない
  --unreached-leaves  決定木の葉のうち直近 N 日間に到達 0 の葉を列挙する（Issue の集計は行わない。
                   記録は hooks/decision-tree.sh が Stop で書く leaves.tsv。記録が無ければ (unmeasured)。
                   --metrics-dir / --repo-dir / --format も効く。--issue-metrics とは同時に指定できない。
                   引数の誤り以外は常に exit 0）
  --days N         --unreached-leaves の期間（既定 14）
  -h, --help       この使い方を表示する
USAGE
}

need_value() { # <フラグ名> <残り引数の個数>
  [ "$2" -ge 2 ] || { echo "${1} には値が必要です" >&2; usage; exit 2; }
}

INPUT=""
REPO=""
STATE="all"
LIMIT="200"
FORMAT="text"
ISSUE_METRICS=""
METRICS_DIR="${FF_DEV_TOOLKIT_STATE_DIR:-${HOME:-}/.config/ff-dev-toolkit}/metrics"
REPO_DIR="."
UNREACHED_LEAVES=0
DAYS="14"

while [ $# -gt 0 ]; do
  case "$1" in
    --input)  need_value "$1" $#; INPUT="$2"; shift 2 ;;
    --repo)   need_value "$1" $#; REPO="$2"; shift 2 ;;
    --state)  need_value "$1" $#; STATE="$2"; shift 2 ;;
    --limit)  need_value "$1" $#; LIMIT="$2"; shift 2 ;;
    --format) need_value "$1" $#; FORMAT="$2"; shift 2 ;;
    --issue-metrics) need_value "$1" $#; ISSUE_METRICS="$2"; shift 2 ;;
    --metrics-dir) need_value "$1" $#; METRICS_DIR="$2"; shift 2 ;;
    --repo-dir) need_value "$1" $#; REPO_DIR="$2"; shift 2 ;;
    --unreached-leaves) UNREACHED_LEAVES=1; shift ;;
    --days)   need_value "$1" $#; DAYS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "不明な引数: $1" >&2; usage; exit 2 ;;
  esac
done

case "$FORMAT" in
  text|kv) ;;
  *) echo "--format は text または kv を指定してください: ${FORMAT}" >&2; exit 2 ;;
esac

# --- hook の記録（1 Issue 分の wall-clock / 指示読み込みバイト）----------------
# 書き手は hooks/record-effort-wallclock.sh（wallclock.tsv）と
# hooks/record-instruction-bytes.sh（instruction-bytes.tsv）。どちらも 1 行 1 レコードの
# 追記専用 TSV で、列は次のとおり:
#   wallclock.tsv         issue  event(start|end)  epoch  iso8601  session_id  branch  repo
#   instruction-bytes.tsv issue(番号 or -)  session_id  bytes  epoch  path  repo
# repo は `git rev-parse --path-format=absolute --git-common-dir`（linked worktree 間で共通）。
# 記録置き場はリポジトリ横断で共有されるので、repo 列が対象リポジトリと一致する行だけを採る
# （repo 列の無い行・一致しない行は採らない。別リポジトリの同じ番号の Issue を混ぜない）。
# 読み方:
#   wall-clock … 最初の start から、それ以降の最後の end まで。end は `gh pr merge` の
#                **試行時刻**（PreToolUse で記録するので失敗したマージも残る）で、最後の試行を
#                採る。end が無ければ now まで（/close-issue はマージ直前に呼ぶので、書き戻し
#                時点までの経過になる）。start が無いときは、対象リポジトリのブランチ
#                `<type>/#<n>-<slug>` の reflog の最古エントリを開始とみなす（hook 導入前・
#                変数形のブランチ作成で start を取りこぼした場合の補い。引けなければ unmeasured）
#   読み込みバイト … その Issue の行の合計 + Issue 未確定（`-`）の行のうち、その Issue
#                だけを開始したセッションの行（ブランチを切る前に読んだ指示を落とさない。
#                複数 Issue を開始したセッションの `-` 行はどの Issue にも寄せない）
# 記録が無い・読めない・該当行が無いときは `(unmeasured)` を出す（0 とは区別する）。
# 失敗でワークフローを止めないため、このモードは常に exit 0 で終わる。
metrics_repo_key() { # <dir> → 共通 git dir の絶対パス（引けなければ空）
  command -v git >/dev/null 2>&1 || return 0
  git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true
}

# start の記録が無い Issue の開始時刻を、対象リポジトリのブランチの reflog から補う。
# 該当ブランチ（`<type>/#<n>-…`）の reflog の最古エントリの epoch を返す（無ければ空）。
metrics_reflog_start() { # <repo_dir> <issue>
  local dir="$1" issue="$2" br oldest="" t
  command -v git >/dev/null 2>&1 || return 0
  while IFS= read -r br; do
    [ -n "$br" ] || continue
    t="$(git -C "$dir" reflog show --date=unix --format='%gd' "refs/heads/${br}" -- 2>/dev/null \
      | awk -F '[{}]' 'NF >= 2 && $2 ~ /^[0-9]+$/ { v = $2 } END { if (v != "") print v }')" || t=""
    [ -n "$t" ] || continue
    if [ -z "$oldest" ] || [ "$t" -lt "$oldest" ]; then oldest="$t"; fi
  done <<EOF
$(git -C "$dir" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null \
  | awk -v n="$issue" '$0 ~ ("^[A-Za-z0-9_.-]+/#" n "([-_/].*)?$")')
EOF
  [ -n "$oldest" ] && printf '%s' "$oldest"
  return 0
}

metrics_issue_report() { # <issue> <metrics_dir> <repo_dir>
  local issue="$1" dir="$2" repo_dir="$3" wc_file bytes_file now repo wc_out fb=""
  wc_file="${dir}/wallclock.tsv"
  bytes_file="${dir}/instruction-bytes.tsv"
  now="$(date +%s 2>/dev/null)" || now=""
  repo="$(metrics_repo_key "$repo_dir")"
  printf 'issue=%s\n' "$issue"
  printf 'metrics_dir=%s\n' "$dir"
  printf 'repo=%s\n' "${repo:-(unresolved)}"
  if [ -z "$repo" ] || [ -z "$now" ]; then
    printf 'wallclock_source=(unmeasured)\nwallclock_start=(unmeasured)\nwallclock_end=(unmeasured)\nwallclock_actual_h=(unmeasured)\ninstruction_bytes=(unmeasured)\n'
    return 0
  fi
  local wc_src="/dev/null"
  [ -f "$wc_file" ] && [ -r "$wc_file" ] && wc_src="$wc_file"
  # start 行が無ければ reflog から補う（hook の start が優先。補った値は source=reflog で区別する）
  if ! awk -F '\t' -v want="$issue" -v repo="$repo" \
      '$1 == want && $2 == "start" && $7 == repo { f = 1 } END { exit f ? 0 : 1 }' "$wc_src" 2>/dev/null; then
    fb="$(metrics_reflog_start "$repo_dir" "$issue")"
  fi
  wc_out="$(awk -F '\t' -v want="$issue" -v repo="$repo" -v now="$now" -v fb="$fb" '
    $1 == want && $7 == repo && $2 == "start" && $3 ~ /^[0-9]+$/ {
      if (start == "" || $3 + 0 < start + 0) { start = $3 + 0; start_iso = $4 }
    }
    $1 == want && $7 == repo && $2 == "end" && $3 ~ /^[0-9]+$/ { ends[++ne] = $3 + 0; end_iso[ne] = $4 }
    END {
      src = "hook"
      if (start == "" && fb != "") { start = fb + 0; start_iso = "reflog@" fb; src = "reflog" }
      if (start == "") {
        print "wallclock_source=(unmeasured)"; print "wallclock_start=(unmeasured)"
        print "wallclock_end=(unmeasured)"; print "wallclock_actual_h=(unmeasured)"; exit 0
      }
      # end は gh pr merge の試行時刻。start 以降の最後の試行を採る（失敗した試行の後に
      # 成功した試行があれば、後者で上書きされる）
      end = ""; eiso = ""
      for (i = 1; i <= ne; i++) if (ends[i] >= start && (end == "" || ends[i] > end)) { end = ends[i]; eiso = end_iso[i] }
      if (end == "") { end = now + 0; eiso = "now" }
      printf "wallclock_source=%s\n", src
      printf "wallclock_start=%s\n", start_iso
      printf "wallclock_end=%s\n", eiso
      printf "wallclock_actual_h=%.1f\n", (end - start) / 3600
    }' "$wc_src" 2>/dev/null)" \
    || wc_out="$(printf 'wallclock_source=(unmeasured)\nwallclock_start=(unmeasured)\nwallclock_end=(unmeasured)\nwallclock_actual_h=(unmeasured)')"
  printf '%s\n' "$wc_out"
  if [ -f "$bytes_file" ] && [ -r "$bytes_file" ]; then
    # 1 ファイル目（wallclock.tsv。無ければ /dev/null）でセッションごとの開始 Issue を数え、
    # 2 ファイル目で合算する。1 ファイル目の判定は FILENAME で行う — `FNR == NR` は 1 ファイル目が
    # 空だと 2 ファイル目まで 1 ファイル目扱いになり、バイトの記録が丸ごと読まれない
    awk -F '\t' -v want="$issue" -v repo="$repo" -v first="$wc_src" '
      FILENAME == first {
        if ($2 == "start" && $5 != "" && $7 == repo) {
          if (!(($5 SUBSEP $1) in seen)) { seen[$5, $1] = 1; nissue[$5]++ }
          if ($1 == want) mine[$5] = 1
        }
        next
      }
      $6 != repo { next }
      $3 !~ /^[0-9]+$/ { next }
      $1 == want { total += $3; hit = 1; if ($2 != "") mine_b[$2] = 1; next }
      $1 == "-" { pend[++np] = $3; pend_s[np] = $2 }
      END {
        for (i = 1; i <= np; i++) {
          s = pend_s[i]
          if (s == "") continue
          if ((mine[s] && nissue[s] == 1) || (mine_b[s] && !(s in nissue))) { total += pend[i]; hit = 1 }
        }
        if (hit) printf "instruction_bytes=%d\n", total
        else print "instruction_bytes=(unmeasured)"
      }' "$wc_src" "$bytes_file" 2>/dev/null \
      || printf 'instruction_bytes=(unmeasured)\n'
  else
    printf 'instruction_bytes=(unmeasured)\n'
  fi
  return 0
}

# 記録を読む 2 つのモードは排他（同時指定は出力の形が決まらないので使い方の誤り）
if [ -n "$ISSUE_METRICS" ] && [ "$UNREACHED_LEAVES" -eq 1 ]; then
  echo "--issue-metrics と --unreached-leaves は同時に指定できません" >&2
  usage
  exit 2
fi

if [ -n "$ISSUE_METRICS" ]; then
  case "$ISSUE_METRICS" in
    ''|*[!0-9]*) echo "--issue-metrics には Issue 番号（数字）を指定してください: ${ISSUE_METRICS}" >&2; exit 2 ;;
  esac
  metrics_issue_report "$ISSUE_METRICS" "$METRICS_DIR" "$REPO_DIR"
  exit 0
fi

if [ "$UNREACHED_LEAVES" -eq 1 ]; then
  report_unreached_leaves "$DAYS" "$FORMAT" "$METRICS_DIR" "$REPO_DIR"
  exit $?
fi

# --- 入力の確定 ---------------------------------------------------------
# JSON は一度実体化してから流す。同じ入力を 2 回走査する（本文の展開と、本文が
# 空の Issue も走査対象に数えるための番号一覧）ため、パイプで直結すると 2 度目が
# 読めない。gh の出力は再生できないので、なおさら実体化が要る。
RAW="$(mktemp)"
FLAT="$(mktemp)"
NUMBERS="$(mktemp)"
trap 'rm -f "$RAW" "$FLAT" "$NUMBERS"' EXIT

if [ -n "$INPUT" ]; then
  [ -f "$INPUT" ] || { echo "入力ファイルが見つかりません: ${INPUT}" >&2; exit 1; }
  cat "$INPUT" > "$RAW"
else
  [ -n "$REPO" ] || { echo "--input を省略する場合は --repo が必須です" >&2; usage; exit 2; }
  gh issue list --repo "$REPO" --state "$STATE" --limit "$LIMIT" \
    --json number,body > "$RAW"
fi

# --- JSON → TSV（Issue 番号 + 本文 1 行）--------------------------------
# body キーの欠落を `// ""` で握りつぶさない。--json の指定を誤って body を
# 取り忘れた入力は「全 Issue がブロック不在」という、もっともらしい 0 件レポートに
# 化ける（exit 0 で）。入口で落とす。
if ! jq -e 'type == "array" and (map(has("body")) | all)' "$RAW" >/dev/null 2>&1; then
  echo "入力の形式が不正です: JSON 配列で、各要素が body フィールドを持つ必要があります" >&2
  echo "  gh issue list --json number,body の出力を渡してください（body の取り忘れは、全 Issue がブロック不在という 0 件レポートに化けます）" >&2
  exit 1
fi

jq -r '.[] | .number as $n | ((.body // "") | split("\n")[]) | "\($n)\t\(.)"' \
  "$RAW" > "$FLAT" \
  || { echo "Issue 本文の展開に失敗しました" >&2; exit 1; }

jq -r '.[] | .number' "$RAW" > "$NUMBERS" \
  || { echo "Issue 番号の取得に失敗しました" >&2; exit 1; }

# --- 集計 ---------------------------------------------------------------
awk -v lower="$VARIANCE_LOWER" -v upper="$VARIANCE_UPPER" -v format="$FORMAT" \
    -v limit="$LIMIT" -v from_gh="$([ -n "$INPUT" ] && echo 0 || echo 1)" '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

# 値を人時（h）へ正規化する。unit はブロックの `effort_unit` の値（無ければ空 = 旧ブロック）。
#   `effort_unit: h` のブロック … "3.0h" → 3.0。"3.0d" は単位の食い違いとして -3
#   宣言の無い旧ブロック      … "3.0d" → 24.0（×8）。"3.0h" は単位の食い違いとして -3
# 数値でない・0 以下は書式不正として -2、未記入は -1 を返す。
# 「記入されていない」「読めない」「単位が食い違う」を同じ値へ潰さない。
function as_hours(s, unit,   v) {
  s = trim(s)
  if (s == "" || s == "(未記入)") return -1
  if (s ~ /^[0-9]+(\.[0-9]+)?h$/) {
    if (unit != "h") return -3
    sub(/h$/, "", s); v = s + 0
    return (v <= 0) ? -2 : v
  }
  if (s ~ /^[0-9]+(\.[0-9]+)?d$/) {
    if (unit == "h") return -3
    sub(/d$/, "", s); v = s + 0
    return (v <= 0) ? -2 : v * 8
  }
  return -2
}

# 速度指標の集計: 変更クラスごとの値を tmp へ写して並べ、中央値 / p75 を返す。
# 該当 0 件は "(unmeasured)"（0 と区別する）。fmt は printf 書式。
function class_stat(kind, cls, which, fmt,   i, n, tmp) {
  n = sp_n[kind, cls] + 0
  if (n == 0) return "(unmeasured)"
  for (i = 1; i <= n; i++) tmp[i] = sp_v[kind, cls, i]
  if (which == "median") return sprintf(fmt, median(tmp, n))
  return sprintf(fmt, pctl(tmp, n, 0.75))
}
function sp_add(kind, cls, v) { sp_v[kind, cls, ++sp_n[kind, cls]] = v }

# マーカー形の行か: 前後の空白を除いた行【全体】が 1 個の HTML コメントで、その中身が
# ff-effort に言及しているもの。begin / end の綴りは条件に入れない — 綴りずれこそが
# 検出したい対象で、正しい綴りを要求すると検出力が消える。
function is_marker_shaped(s,   t) {
  t = trim(s)
  if (t !~ /^<!--.*-->$/) return 0
  # 中身に閉じ区切りが残っていたら、その行にはコメントが 2 個以上ある。
  # `.*` は貪欲なので `<!-- 注 --> ff-effort の説明 <!-- /注 -->` のような行も
  # 上の 1 行だけでは通り、コメントの【外】にある散文を疑ってしまう。
  # 「行全体が 1 個の HTML コメント」まで見る。
  t = substr(t, 5, length(t) - 7)   # 前後の <!-- と --> を外した中身
  if (index(t, "-->") > 0) return 0
  return (t ~ /ff-effort/)
}

function sort_asc(arr, n,   i, j, t) {
  for (i = 2; i <= n; i++) { t = arr[i]; j = i - 1
    while (j >= 1 && arr[j] > t) { arr[j+1] = arr[j]; j-- }
    arr[j+1] = t }
}
function median(arr, n) {
  sort_asc(arr, n)
  if (n % 2 == 1) return arr[(n+1)/2]
  return (arr[n/2] + arr[n/2+1]) / 2
}
# nearest-rank 方式（q は 0〜1、補間しない）。小さい N でも定義が一意に定まる。
# p10 / p25 / p75 / p90 はすべてこの 1 つの規則で出す。上の median() だけが偶数件で
# 「上下 2 値の平均」という別の慣習を残しているのは、既存の出力を動かさないため。
# 帯の較正はこれらを並べて読むので、どの値がどの規則で出たのかを説明できないと
# 「どの統計量から帯を引いたか」が後から再現できない。
function pctl(arr, n, q,   idx) {
  sort_asc(arr, n)
  idx = int(q * n)
  if (idx < q * n) idx++
  if (idx < 1) idx = 1
  if (idx > n) idx = n
  return arr[idx]
}

# 1 ファイル目: Issue 番号の一覧（本文が空でも走査対象に数えるため）
FNR == NR { if ($0 != "") { order[++total] = $0 + 0 } ; next }

# 2 ファイル目: 番号 \t 本文 1 行
{
  tab = index($0, "\t")
  if (tab == 0) next
  num = substr($0, 1, tab - 1) + 0
  line = substr($0, tab + 1)
  sub(/\r$/, "", line)

  if (line == "<!-- ff-effort:begin -->") {
    if (hasblock[num]) broken[num] = 1     # 2 組目
    inblock[num] = 1; hasblock[num] = 1; next
  }
  if (line == "<!-- ff-effort:end -->") {
    if (inblock[num] != 1) broken[num] = 1  # begin より前 / 2 組目
    inblock[num] = 0; closed[num] = 1; next
  }

  # マーカーの綴りずれ・字下げ・行末空白を近傍検出する。両側（書く側・読む側）が
  # 完全一致でしか認識しないため、綴りが 1 文字ずれた Issue は永久に静かに落ちる。
  # 「本当は書いてあるのに読めていない」を名指しできるようにする。
  #
  # 判定はマーカー形の行に限る。ff-effort を含む行をすべて疑うと、ブロックの【外】で
  # その語そのものを説明している散文・AC・表まで疑われる。そうなると警告を消す唯一の
  # 手段が「正しい原文からその語を削る」になり、検出器に合わせて本文を劣化させる —
  # 実測でこの誤検出を 3 回連続で受け取った。マーカー形に限れば、綴りずれ・字下げ・
  # 行末空白という本来の検出対象は落ちない（いずれも行全体は HTML コメントのままだから）。
  if (inblock[num] != 1 && is_marker_shaped(line)) suspect[num] = 1

  if (inblock[num] != 1) next

  if (line !~ /^-[ ]*[a-z_]+[ ]*:/) next
  colon = index(line, ":")
  key = substr(line, 1, colon - 1)
  val = substr(line, colon + 1)
  sub(/^-[ ]*/, "", key); key = trim(key)
  val = trim(val)

  # 重複キーは last-wins で黙って上書きしない。close-issue の「1 Issue に複数 PR は
  # 加算する」規則を、既存行の編集ではなく 2 行目の追記で実行されると、合計であるべき
  # 値が最後の 1 件だけになる。書式不正として名指しする。
  if (key == "effort_human_planned") { if (num in hp_raw) broken[num] = 1; hp_raw[num] = val }
  else if (key == "effort_ai_planned") { if (num in ap_raw) broken[num] = 1; ap_raw[num] = val }
  else if (key == "effort_ai_actual")  { if (num in aa_raw) broken[num] = 1; aa_raw[num] = val }
  else if (key == "effort_unit")       { if (num in unit_raw) broken[num] = 1; unit_raw[num] = val }
  # 速度指標のキーは重複しても Issue 全体を malformed にしない（乖離率の母集団を巻き添えに
  # しない）。重複した Issue は速度指標からだけ外す。
  else if (key == "effort_wallclock_actual")  { if (num in wc_raw) sp_dup[num] = 1; wc_raw[num] = val }
  else if (key == "effort_instruction_bytes") { if (num in ib_raw) sp_dup[num] = 1; ib_raw[num] = val }
  else if (key == "effort_change_class")      { if (num in cc_raw) sp_dup[num] = 1; cc_raw[num] = val }
}

END {
  # 未閉鎖ブロック（begin のみ）は、以降の全行をブロック内容として解釈してしまう。
  # 書く側は同じ構成を exit 2 で拒否する。読む側だけ黙って解釈すると、本文由来の
  # 値が KPI に混じる。書く側と処分を揃える。
  for (i = 1; i <= total; i++) {
    n = order[i]
    if (hasblock[n] && !closed[n]) broken[n] = 1
  }

  noblock = 0; planned_only = 0; malformed = 0; no_hp = 0
  unit_mismatch = 0; mismatch_kv = ""; mismatch_txt = ""
  wc_unmeasured = 0; wc_malformed = 0; ib_unmeasured = 0; ib_malformed = 0
  population = 0; suspect_n = 0; suspect_kv = ""; suspect_txt = ""
  hp_total = 0; ap_total = 0; aa_total = 0
  pair_n = 0; pair_denom = 0; vn = 0; out_of_band = 0

  for (i = 1; i <= total; i++) {
    n = order[i]
    # 件数だけの警告は読み手が直す対象を特定できない（実測: 同じ 1 行を 3 回受け取り、
    # 3 回目に全 Issue 本文を総当たりして該当を特定した）。番号を必ず添える。
    # 件数が多くても切り詰めない — 省略した分は「件数だけの警告」に戻り、落ちた Issue が
    # そのまま持ち越される。番号は %d で文字列化する（CONVFMT の既定 %.6g は 7 桁以上の
    # Issue 番号を 1.23457e+06 に化けさせ、名指しが名指しでなくなる）。
    if (suspect[n]) {
      suspect_n++
      ns = sprintf("%d", n)
      suspect_kv = (suspect_kv == "") ? ns : (suspect_kv "," ns)
      suspect_txt = (suspect_txt == "") ? ("#" ns) : (suspect_txt ", #" ns)
    }

    if (!hasblock[n]) { noblock++; continue }
    if (broken[n])    { malformed++; continue }

    # 単位宣言は `h` だけを受ける。未知の宣言（`d` を含む）は旧ブロックとも読めないので
    # 書式不正として落とす（宣言を無視して読むと、宣言した意図と逆の単位で集計される）
    unit = (n in unit_raw) ? unit_raw[n] : ""
    # 空の宣言（`- effort_unit:`）も書式不正（旧ブロックとして読まない。guard-effort-actual と同形）
    if ((n in unit_raw) && unit != "h") { malformed++; continue }

    # 速度指標（乖離率の母集団とは独立に、読めるブロックすべてから拾う）。wall-clock と
    # 読み込みバイトは互いに独立に集計する（片側だけ未計測の Issue で、もう片側を落とさない）
    cls = (n in cc_raw) ? trim(cc_raw[n]) : ""
    if (cls == "docs-only") cls = "docs_only"
    else if (cls != "small" && cls != "other") cls = ""
    if (n in wc_raw) {
      wv = trim(wc_raw[n])
      if (sp_dup[n]) { wc_malformed++ }
      else if (wv == "(unmeasured)" || wv == "(未記入)" || wv == "") { wc_unmeasured++ }
      else if (wv ~ /^[0-9]+(\.[0-9]+)?h$/) {
        sub(/h$/, "", wv)
        sp_add("wc", "all", wv + 0); if (cls != "") sp_add("wc", cls, wv + 0)
      } else { wc_malformed++ }
    }
    if (n in ib_raw) {
      bv = trim(ib_raw[n])
      if (sp_dup[n]) { ib_malformed++ }
      else if (bv == "(unmeasured)" || bv == "(未記入)" || bv == "") { ib_unmeasured++ }
      else if (bv ~ /^[0-9]+$/) { sp_add("ib", "all", bv + 0); if (cls != "") sp_add("ib", cls, bv + 0) }
      else { ib_malformed++ }
    }

    hp = (n in hp_raw) ? as_hours(hp_raw[n], unit) : -1
    ap = (n in ap_raw) ? as_hours(ap_raw[n], unit) : -1
    aa = (n in aa_raw) ? as_hours(aa_raw[n], unit) : -1

    if (hp == -2 || ap == -2 || aa == -2) { malformed++; continue }
    # 単位の食い違いは書式不正の一種だが、旧ブロック（×8 で正規化）の混入事故と区別できる
    # よう別の件数で出し、該当 Issue も名指しする（件数だけの警告は直す対象を特定できない）
    if (hp == -3 || ap == -3 || aa == -3) {
      unit_mismatch++
      ns = sprintf("%d", n)
      mismatch_kv = (mismatch_kv == "") ? ns : (mismatch_kv "," ns)
      mismatch_txt = (mismatch_txt == "") ? ("#" ns) : (mismatch_txt ", #" ns)
      continue
    }

    # 実績なしは「実績 0」ではない。0 と解釈すると圧縮率が発散するため母集団から外す
    if (aa < 0) { planned_only++; continue }

    population++
    aa_total += aa
    if (ap > 0) {
      ap_total += ap
      v = aa / ap
      variances[++vn] = v
      if (v < lower + 0 || v > upper + 0) out_of_band++
    }
    # 圧縮率は対で集計する。片側欠測を分母にだけ入れない
    if (hp > 0) { hp_total += hp; pair_denom += aa; pair_n++ }
    else { no_hp++ }
  }

  compression = (pair_n > 0 && pair_denom > 0) ? hp_total / pair_denom : 0
  vmed = (vn > 0) ? median(variances, vn) : 0
  # 帯の較正は p25〜p75（または p10〜p90）を包む乗法対称帯として引く。中央値と p90
  # だけでは「どこまで広げれば運用上の誤差を帯に入れられるか」が読めない
  vp10 = (vn > 0) ? pctl(variances, vn, 0.10) : 0
  vp25 = (vn > 0) ? pctl(variances, vn, 0.25) : 0
  vp75 = (vn > 0) ? pctl(variances, vn, 0.75) : 0
  vp90 = (vn > 0) ? pctl(variances, vn, 0.90) : 0
  truncated = (from_gh == 1 && total >= limit + 0) ? 1 : 0

  if (format == "kv") {
    printf "issues_scanned=%d\n", total
    printf "excluded_noblock=%d\n", noblock
    printf "excluded_planned_only=%d\n", planned_only
    printf "excluded_malformed=%d\n", malformed
    printf "excluded_unit_mismatch=%d\n", unit_mismatch
    printf "excluded_unit_mismatch_issues=%s\n", mismatch_kv
    printf "excluded_no_human_planned=%d\n", no_hp
    # 以下の合計値の単位（旧ブロックの d は ×8 で正規化済み）
    printf "effort_unit=h\n"
    printf "population=%d\n", population
    printf "compression_pairs=%d\n", pair_n
    printf "human_planned_total=%.1f\n", hp_total
    printf "compression_denominator=%.1f\n", pair_denom
    printf "compression_ratio=%.2f\n", compression
    printf "ai_planned_total=%.1f\n", ap_total
    printf "ai_actual_total=%.1f\n", aa_total
    printf "variance_population=%d\n", vn
    printf "variance_p10=%.2f\n", vp10
    printf "variance_p25=%.2f\n", vp25
    printf "variance_median=%.2f\n", vmed
    printf "variance_p75=%.2f\n", vp75
    printf "variance_p90=%.2f\n", vp90
    printf "variance_out_of_band=%d\n", out_of_band
    printf "suspect_marker=%d\n", suspect_n
    # 0 件でもキーは出す。存在しないキーと空値を消費側に区別させる
    printf "suspect_marker_issues=%s\n", suspect_kv
    printf "limit_reached=%d\n", truncated
    # 速度指標（変更クラス別）。review_rounds / gate_minutes は供給源が未配線なので
    # 常に (unavailable)。配線済みでも該当 0 件のクラスは (unmeasured)
    printf "wallclock_unmeasured=%d\n", wc_unmeasured
    printf "wallclock_malformed=%d\n", wc_malformed
    printf "instruction_bytes_unmeasured=%d\n", ib_unmeasured
    printf "instruction_bytes_malformed=%d\n", ib_malformed
    split("docs_only small other all", classes, " ")
    for (ci = 1; ci <= 4; ci++) {
      c = classes[ci]
      printf "wallclock_population_%s=%d\n", c, sp_n["wc", c] + 0
      printf "instruction_bytes_population_%s=%d\n", c, sp_n["ib", c] + 0
      printf "wallclock_median_h_%s=%s\n", c, class_stat("wc", c, "median", "%.1f")
      printf "wallclock_p75_h_%s=%s\n", c, class_stat("wc", c, "p75", "%.1f")
      printf "instruction_bytes_median_%s=%s\n", c, class_stat("ib", c, "median", "%.0f")
      printf "review_rounds_median_%s=(unavailable)\n", c
      printf "gate_minutes_median_%s=(unavailable)\n", c
    }
    exit 0
  }

  printf "# 工数 KPI レポート\n\n"
  printf "走査した Issue: %d 件\n", total
  printf "集計母集団:     %d 件\n", population
  printf "除外:           ブロック不在 %d 件 / 予定のみ・実績なし %d 件 / 書式不正 %d 件 / 単位の食い違い %d 件\n",
         noblock, planned_only, malformed, unit_mismatch
  if (unit_mismatch > 0)
    printf "  ⚠️ effort_unit の宣言と値の単位が食い違う Issue が %d 件あります: %s（effort_unit: h なら値は N.Nh、宣言が無い旧ブロックなら N.Nd）\n", unit_mismatch, mismatch_txt
  if (suspect_n > 0)
    printf "  ⚠️ ff-effort に似た行があるのにマーカーとして認識されなかった Issue が %d 件あります: %s（綴り・字下げ・行末空白を確認すること）\n", suspect_n, suspect_txt
  if (truncated)
    printf "  ⚠️ 取得件数が --limit（%d）に達しています。母集団が打ち切られている可能性があります\n", limit
  if (total > 0 && (noblock + planned_only + malformed + unit_mismatch) * 2 > total)
    printf "  ⚠️ 除外が過半を占めます。以下の値は一部の Issue だけのものです\n"

  printf "\n## 圧縮率（対外指標・人間予定と AI 実績が揃った対だけを合計してから除算）\n\n"
  printf "対になった Issue: %d 件", pair_n
  if (no_hp > 0) printf "（人間予定が無く対を作れなかった %d 件は除外）", no_hp
  printf "\n"
  printf "人間予定合計:   %.1fh\n", hp_total
  printf "対の AI 実績:   %.1fh\n", pair_denom
  if (compression > 0) printf "圧縮率:         %.2f 倍\n", compression
  else if (population == 0) printf "圧縮率:         算出不能（集計母集団が空）\n"
  else printf "圧縮率:         算出不能（人間予定と AI 実績が揃った Issue がありません）\n"

  printf "\n## 乖離率（精度指標・件ごとに算出）\n\n"
  printf "AI 予定合計:    %.1fh\n", ap_total
  printf "AI 実績合計:    %.1fh（母集団全体）\n", aa_total
  if (vn > 0) {
    printf "p10:            %.2f\n", vp10
    printf "p25:            %.2f\n", vp25
    printf "中央値:         %.2f\n", vmed
    printf "p75:            %.2f\n", vp75
    printf "p90:            %.2f\n", vp90
    printf "閾値外（<%s または >%s）: %d 件 / %d 件\n", lower, upper, out_of_band, vn
  } else {
    printf "算出不能（予定と実績が揃った Issue がありません）\n"
  }

  printf "\n## 速度指標（変更クラス別・/close-issue が書き戻した実測）\n\n"
  printf "wall-clock 未計測 %d 件 / 書式不正 %d 件、指示読み込み 未計測 %d 件 / 書式不正 %d 件（いずれも集計から外す）\n", wc_unmeasured, wc_malformed, ib_unmeasured, ib_malformed
  split("docs_only small other all", classes, " ")
  for (ci = 1; ci <= 4; ci++) {
    c = classes[ci]
    printf "%-10s wall-clock n=%d 中央値 %s h・p75 %s h / 指示読み込み n=%d 中央値 %s B / レビュー巡回 (unavailable) / ゲート分 (unavailable)\n",
      c, sp_n["wc", c] + 0, class_stat("wc", c, "median", "%.1f"), class_stat("wc", c, "p75", "%.1f"),
      sp_n["ib", c] + 0, class_stat("ib", c, "median", "%.0f")
  }
}
' "$NUMBERS" "$FLAT"
