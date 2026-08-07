#!/usr/bin/env bash
#
# 推奨ラベル・セットアップの契約検査（Issue #298）。
#
# `docs-template/scripts/setup-github-labels.sh` はラベル定義の正本（SSOT）を
# `LABEL_DEFS` ブロックに持ち、`docs-template/05-operations/deployment/github-setup.md`
# は同じ定義を「カスタムラベル（追加が必要）」表と手動セットアップ例の 2 箇所に
# 人間向けの写しとして持つ。写しは共有できない（文書は表、スクリプトはデータ行と
# 形が違う）ので、ドリフト対策は照合で行う: 3 箇所の name / color / description が
# 一致しなければ red にする。
#
# あわせて振る舞いも実測する。静的な照合は「定義がそう書いてある」までしか言えず、
#   - 不足分だけが作成され、既存ラベルに一切触れないこと（冪等）
#   - 照会を信用できないとき（失敗・空・上限到達）に 1 件も作成せず非 0 で
#     終了すること（fail-closed。「存在しない」と誤断定して作成に進まない）
# は実行しないと分からない。`gh` の stub の下でスクリプトを走らせて確かめる。
# 安全弁: `gh` が stub に解決されることを確認してからでないと実行しない
# （取り違えると本物のリポジトリにラベルを作ってしまう）。
#
# 一時ファイルは作らないので、書き込み不可の環境でも完走する。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/github-labels-setup/verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETUP_SCRIPT="$PLUGIN_ROOT/docs-template/scripts/setup-github-labels.sh"
GITHUB_SETUP="$PLUGIN_ROOT/docs-template/05-operations/deployment/github-setup.md"
SKILL="$PLUGIN_ROOT/skills/setup-github-labels/SKILL.md"
STUB_DIR="$SCRIPT_DIR/fixtures/gh-stub"

# 定義の件数。増減したときは必ずここも直す。固定しないと、抽出が壊れて 0 件に
# なっても「全定義一致」で緑になる。
EXPECTED_LABEL_COUNT=5

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

echo "== 推奨ラベル・セットアップの契約検査（SSOT 照合 + 振る舞い実測） =="

for file in "$SETUP_SCRIPT" "$GITHUB_SETUP" "$SKILL" "$STUB_DIR/gh"; do
  [ -s "$file" ] || { echo "✗ 必須ファイルが無いか空です: $file" >&2; exit 1; }
done

if syntax_err="$(bash -n "$SETUP_SCRIPT" 2>&1)"; then
  ok "setup-github-labels.sh が bash として構文的に妥当（bash -n）"
else
  bad "setup-github-labels.sh が bash -n を通らない"
  printf '%s\n' "$syntax_err" | sed 's/^/    | /' >&2
fi

# ---- 抽出器 3 種 ---------------------------------------------------------------
# いずれも `name|color|description`（color は # なし 6 桁 hex）へ正規化して出力する。

# スクリプトの LABEL_DEFS ブロック（SSOT）。sentinel の間の定義行だけを読む。
extract_script_defs() {
  awk '
    /^# LABEL_DEFS_BEGIN$/ { on = 1; next }
    /^# LABEL_DEFS_END$/   { on = 0 }
    on {
      line = $0
      sub(/^LABEL_DEFS='\''/, "", line)
      sub(/'\''$/, "", line)
      if (line ~ /^[a-z][a-z-]*\|[0-9A-Fa-f]{6}\|/) print line
    }
  ' "$1"
}

# github-setup.md の「カスタムラベル（追加が必要）」表。デフォルトラベル表と
# 区別するため、見出しから次の見出しまでの区間だけを読む。
extract_table_defs() {
  awk -F'|' '
    /^#### カスタムラベル/ { on = 1; next }
    on && /^#/ { on = 0 }
    on && $0 ~ /^\|[[:space:]]*`/ {
      name = $2; desc = $3; color = $4
      gsub(/[[:space:]`]/, "", name)
      gsub(/^[[:space:]]+/, "", desc); gsub(/[[:space:]]+$/, "", desc)
      gsub(/[[:space:]#]/, "", color)
      print name "|" color "|" desc
    }
  ' "$1"
}

# github-setup.md の手動セットアップ例（`gh label create ...` 行）。
extract_manual_defs() {
  awk '
    /^gh label create "/ {
      name = ""; desc = ""
      line = $0
      if (match(line, /create "[^"]+"/)) name = substr(line, RSTART + 8, RLENGTH - 9)
      if (match(line, /--description "[^"]+"/)) desc = substr(line, RSTART + 15, RLENGTH - 16)
      next_needs_color = 1
      # color は行継続（\）の次行にある形と同一行の形の両方を許す
      if (match(line, /--color "[^"]+"/)) {
        color = substr(line, RSTART + 9, RLENGTH - 10)
        print name "|" color "|" desc
        next_needs_color = 0
      }
      next
    }
    next_needs_color && match($0, /--color "[^"]+"/) {
      color = substr($0, RSTART + 9, RLENGTH - 10)
      print name "|" color "|" desc
      next_needs_color = 0
    }
  ' "$1"
}

# ---- 自己検証（抽出器が本当に見ているかを先に確かめる） -------------------------
# 負の対照: sentinel / 見出しを持たないファイルからは 1 行も採れないこと。
if [ -n "$(extract_script_defs "$GITHUB_SETUP")" ]; then
  bad "自己検証: sentinel の無いファイルから SSOT を抽出できてしまった"
else
  ok "自己検証: sentinel の無いファイルからは SSOT を抽出しない"
fi
if [ -n "$(extract_table_defs "$SETUP_SCRIPT")" ]; then
  bad "自己検証: 見出しの無いファイルから表を抽出できてしまった"
else
  ok "自己検証: 見出しの無いファイルからは表を抽出しない"
fi
# スクリプト内の `gh label create "$name"` はインデント付きコマンドであり、
# 行頭マッチの手動例抽出器には引っかからないこと（負の対照）。
if [ -n "$(extract_manual_defs "$SETUP_SCRIPT")" ]; then
  bad "自己検証: 手動例の無いファイルから gh label create 定義を抽出できてしまった"
else
  ok "自己検証: 手動例の無いファイルからは gh label create 定義を抽出しない"
fi

# 比較器の対照: 1 行違いを本当に検出できること（常に「一致」を返す退化の検出）。
compare_defs() { # $1: 正本 / $2: 対象 → 差分行を出力（空なら一致）
  printf '%s\n' "$1" | sort | awk '
    NR == FNR { want[$0] = 1; next }
    !($0 in want) { print "正本に無い: " $0 }
    { got[$0] = 1 }
    END { for (w in want) if (!(w in got)) print "対象に無い: " w }
  ' - <(printf '%s\n' "$2" | sort)
}
if [ -n "$(compare_defs "a|111111|x" "a|222222|x")" ]; then
  ok "自己検証: 比較器が 1 行の差分を検出できる"
else
  bad "自己検証: 比較器が差分を検出できない — 常に一致を返している"
fi

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "✗ github-labels-setup verify: 検出器の自己検証に失敗（本検査は実行しない）" >&2
  exit 1
fi

# ---- 1. SSOT の 3 箇所照合 ------------------------------------------------------
script_defs="$(extract_script_defs "$SETUP_SCRIPT")"
table_defs="$(extract_table_defs "$GITHUB_SETUP")"
manual_defs="$(extract_manual_defs "$GITHUB_SETUP")"

count_of() { [ -z "$1" ] && echo 0 || printf '%s\n' "$1" | wc -l | tr -d '[:space:]'; }

for pair in "SSOT（スクリプト）:$(count_of "$script_defs")" \
            "推奨ラベル表:$(count_of "$table_defs")" \
            "手動セットアップ例:$(count_of "$manual_defs")"; do
  name="${pair%%:*}"; count="${pair##*:}"
  if [ "$count" -eq "$EXPECTED_LABEL_COUNT" ]; then
    ok "${name} の定義が ${EXPECTED_LABEL_COUNT} 件（増減時は EXPECTED_LABEL_COUNT も更新すること）"
  else
    bad "${name} の定義が ${count} 件（期待 ${EXPECTED_LABEL_COUNT} 件）— 抽出が壊れているか定義が黙って増減している"
  fi
done

check_sync() { # $1: 対象名 / $2: 対象 defs
  local diff
  diff="$(compare_defs "$script_defs" "$2")"
  if [ -z "$diff" ]; then
    ok "${1} が SSOT と一致（name / color / description）"
  else
    bad "${1} が SSOT と不一致"
    printf '%s\n' "$diff" | sed 's/^/    | /' >&2
  fi
}
check_sync "github-setup.md の推奨ラベル表" "$table_defs"
check_sync "github-setup.md の手動セットアップ例" "$manual_defs"

# ---- 2. スクリプトの静的契約 ----------------------------------------------------
# 既存ラベルへ触れないこと: --force（不在時 create / 既存時 update の両対応）と
# `gh label edit` をコマンド行に持たない。散文・コメントでの言及（「--force は
# 使わない」等）は違反ではないので、コメント行を除いた行だけを見る。
force_violations="$(awk '
  /^[[:space:]]*#/ { next }
  /gh label create/ && /--force/ { print NR }
  /^[[:space:]]*gh label edit([[:space:]]|$)/ { print NR }
  /[[:space:]]gh label edit([[:space:]]|$)/ { print NR }
' "$SETUP_SCRIPT")"
if [ -z "$force_violations" ]; then
  ok "スクリプトは既存ラベルを変更しない（--force / gh label edit をコマンド行に持たない）"
else
  bad "既存ラベルを変更しうるコマンド行がある（行: ${force_violations//$'\n'/, }）"
fi

# fail-closed の宣言が実体として残っていること（--limit 明示・照会失敗/空/上限の 3 分岐）。
contains() {
  local label="$1" needle="$2"
  if grep -qF -- "$needle" "$SETUP_SCRIPT"; then ok "$label"; else bad "${label}（不足: ${needle}）"; fi
}
contains "ラベル一覧の取得が --limit を明示する" 'gh label list --repo "$repo" --limit "$label_limit"'
contains "照会失敗で作成せず終了する" '実在を確認できないため作成しません'
contains "空の一覧を「不在」と誤断定しない" '取得が機能しなかった場合と区別できないため作成しません'
contains "上限到達を「不在」と誤断定しない" '不在を確認できないため作成しません'

# ---- 3. SKILL.md の発動トリガーと導線 -------------------------------------------
description_line="$(awk '{ sub(/\r$/, "") } /^---$/ { n++; next } n == 1 && /^description:/ { print; exit } n == 2 { exit }' "$SKILL")"
description_has() {
  local needle="$1" label="$2"
  case "$description_line" in
    *"$needle"*) ok "$label" ;;
    *) bad "${label}（description に不足: ${needle}）" ;;
  esac
}
if [ -z "$description_line" ]; then
  bad "setup-github-labels の frontmatter から description 行を取り出せない"
else
  description_has "Use when setting up recommended GitHub labels" "description が発動条件から始まる"
  description_has "「ラベルを整備して」" "description に日本語のトリガーがある"
  description_has "set up labels" "description に英語のトリガーがある"
  description_has "create-issue" "description が付与側（create-issue）との棲み分けを示す"
fi
skill_contains() {
  local label="$1" needle="$2"
  if grep -qF -- "$needle" "$SKILL"; then ok "$label"; else bad "${label}（不足: ${needle}）"; fi
}
skill_contains "SKILL.md が同梱スクリプトを実行する" 'docs-template/scripts/setup-github-labels.sh'
skill_contains "SKILL.md が報告を出力の写しに限定する" 'そのまま読んで'

# create-issue の完了報告に整備側への案内導線があること（Issue #298 AC4）。
# 「不在」のときだけ案内し「照会失敗」では案内しない、という条件付きの導線なので、
# 条件の核になる文言まで含めて固定する。
CREATE_ISSUE="$PLUGIN_ROOT/skills/create-issue/SKILL.md"
if grep -qF -- '省略理由が「不在」のラベルがある場合は、`/setup-github-labels`' "$CREATE_ISSUE"; then
  ok "create-issue の完了報告が「不在」時に /setup-github-labels を案内する"
else
  bad "create-issue の完了報告に /setup-github-labels への案内が無い"
fi
if grep -qF -- '「照会失敗」のときは添えない' "$CREATE_ISSUE"; then
  ok "create-issue の案内は「照会失敗」時には出さない（誤断定の再発防止）"
else
  bad "create-issue の案内に「照会失敗では出さない」条件が無い"
fi

# github-setup.md の自動セットアップ手順が、配布実体への入手経路を示していること
# （`./scripts/setup-github-labels.sh` の参照だけでは、スクリプトがどこから来るのか
# 消費プロジェクトには分からない — Issue #298 の「壊れた参照」の再発防止）。
if grep -qF -- 'docs-template/scripts/setup-github-labels.sh' "$GITHUB_SETUP"; then
  ok "github-setup.md がスクリプトの入手経路（配布実体のパス）を示す"
else
  bad "github-setup.md が配布実体のパスを示していない（./scripts/ 参照だけでは入手経路が無い）"
fi

# ---- 4. 振る舞いの実測（stub gh の下で実行） ------------------------------------
resolved_gh="$(PATH="$STUB_DIR:$PATH" command -v gh || true)"
if [ ! -x "$STUB_DIR/gh" ]; then
  bad "behavioral 検査: stub gh が実行可能でない（$STUB_DIR/gh）"
elif [ "$resolved_gh" != "$STUB_DIR/gh" ]; then
  bad "behavioral 検査: gh が stub に解決されない（$resolved_gh）— 実リポジトリへラベルを作る危険があるので実行しない"
else
  ok "behavioral 検査: gh が stub に解決される（実 API を叩かない）"

  run_script() { # $1: GH_STUB_MODE / $2...: スクリプト引数。stdout/stderr を合流して返す（argv は stderr に出る）
    local mode="$1"; shift
    PATH="$STUB_DIR:$PATH" GH_STUB_MODE="$mode" bash "$SETUP_SCRIPT" "$@" 2>&1
  }
  run_repo() { run_script "$1" --repo "stub-owner/stub-repo"; } # 既定形（--repo 明示）

  expect_success() { # $1: モード / $2: 期待する部分列（| 区切りへ畳んだ出力に対する） / $3: 検査名
    local out
    if ! out="$(run_repo "$1")"; then
      bad "${3}（非 0 で終了した）"
      return
    fi
    case "$(printf '%s' "$out" | tr '\n' '|')" in
      *"$2"*) ok "$3" ;;
      *) bad "${3}（期待: ${2} / 実際: $(printf '%s' "$out" | tr '\n' '|')）" ;;
    esac
  }

  # 非 0 終了・label create ゼロ・期待する診断文言、の 3 点で fail-closed を固定する。
  # 文言まで見るのは、空一覧と上限到達の診断が入れ替わる変異（原因の取り違え）を
  # 検出するため — SKILL.md の完了報告は原因の書き分けをこの文言に依存している。
  expect_failclosed() { # $1: モード / $2: 期待する診断の部分文字列 / $3: 検査名
    local out rc=0
    out="$(run_repo "$1")" || rc=$?
    if [ "$rc" -eq 0 ]; then
      bad "${3}（成功として終了した）"
      return
    fi
    case "$out" in
      *GH_LABEL_CREATE_ARGV*) bad "${3}（照会を信用できないのに label create が実行された）"; return ;;
    esac
    case "$out" in
      *"$2"*) ok "$3" ;;
      *) bad "${3}（診断文言が期待と違う。期待: ${2} / 実際: $(printf '%s' "$out" | tr '\n' '|')）" ;;
    esac
  }

  # 不足分だけが作成され、作成が argv に載る（報告用の文字列だけではない）。
  # stub の一覧には near-miss（majority / patch-release / urgently）が混ざっており、
  # membership 判定が部分一致へ退化すると CREATED から major / patch / urgent が
  # 消えてここが赤くなる。
  expect_success normal 'CREATED=major minor patch hotfix urgent' \
    "不足しているカスタムラベル 5 件がすべて作成される（near-miss 既存名に部分一致しない）"
  out_normal="$(run_repo normal)" || true
  case "$out_normal" in
    *'GH_LABEL_CREATE_ARGV: label create major --repo stub-owner/stub-repo'*'--color D93F0B'*)
      ok "作成が報告用の文字列だけでなく gh の argv に載っている（--repo / --color 込み）" ;;
    *) bad "gh へ渡った argv に作成内容が載っていない（報告と実際の乖離）" ;;
  esac

  # 報告行は標準出力に出ること（SKILL.md の完了報告はこの行のパースに依存する。
  # 合流キャプチャだけだと printf が stderr へ移る変異が素通りする）
  out_stdout="$(PATH="$STUB_DIR:$PATH" GH_STUB_MODE=normal bash "$SETUP_SCRIPT" --repo "stub-owner/stub-repo" 2>/dev/null)" || true
  case "$(printf '%s' "$out_stdout" | tr '\n' '|')" in
    *'CREATED=major minor patch hotfix urgent'*) ok "CREATED= の報告行が標準出力側に出る" ;;
    *) bad "CREATED= の報告行が標準出力に無い（stderr へ逃げると完了報告が読めない）" ;;
  esac

  # 一部だけ既存: 既存はスキップされ、作成コマンドの対象にならない。終了コードも見る
  rc_partial=0
  out_partial="$(run_repo partial)" || rc_partial=$?
  if [ "$rc_partial" -ne 0 ]; then
    bad "一部既存の整備が非 0 で終了した"
  fi
  case "$(printf '%s' "$out_partial" | tr '\n' '|')" in
    *'CREATED=patch hotfix urgent'*'SKIPPED_EXISTING=major minor'*)
      ok "既存ラベルはスキップされ、不足分だけが作成される" ;;
    *) bad "既存/不足の振り分けが期待と違う（実際: $(printf '%s' "$out_partial" | tr '\n' '|')）" ;;
  esac
  case "$out_partial" in
    *'GH_LABEL_CREATE_ARGV: label create major'*|*'GH_LABEL_CREATE_ARGV: label create minor'*)
      bad "既存ラベルに対して label create が実行された（既存へ触れない契約に違反）" ;;
    *) ok "既存ラベルへは label create を実行しない" ;;
  esac

  # 大文字小文字違いの既存（Major / MINOR）: GitHub のラベル名一意制約は
  # case-insensitive なので、作りにいくと already exists で毎回失敗し冪等が破れる。
  # 既存側（スキップ）へ倒れることを固定する
  out_cv="$(run_repo casevariant)" || { bad "case 違い既存で非 0 終了した（冪等でない）"; out_cv=""; }
  if [ -n "$out_cv" ]; then
    case "$(printf '%s' "$out_cv" | tr '\n' '|')" in
      *'CREATED=patch hotfix urgent'*'SKIPPED_EXISTING=major minor'*)
        ok "大文字小文字違いの既存ラベルはスキップへ倒れる（case-insensitive 照合）" ;;
      *) bad "case 違い既存の振り分けが期待と違う（実際: $(printf '%s' "$out_cv" | tr '\n' '|')）" ;;
    esac
  fi

  # 全部既存: 何も作成せず成功（冪等）。全件スキップの報告内容まで固定する
  out_all="$(run_repo allexist)" || { bad "全ラベル既存で非 0 終了した（冪等でない）"; out_all=""; }
  if [ -n "$out_all" ]; then
    case "$out_all" in
      *GH_LABEL_CREATE_ARGV*) bad "全ラベル既存なのに label create が実行された" ;;
      *) ok "全ラベル既存なら 1 件も作成せず成功する（冪等）" ;;
    esac
    case "$(printf '%s' "$out_all" | tr '\n' '|')" in
      *'CREATED=|'*'SKIPPED_EXISTING=major minor patch hotfix urgent'*)
        ok "全件スキップが報告に列挙される（CREATED は空）" ;;
      *) bad "全件スキップの報告内容が期待と違う（実際: $(printf '%s' "$out_all" | tr '\n' '|')）" ;;
    esac
  fi

  # --repo 省略時はカレントリポジトリ（gh repo view）で確定する経路が生きていること
  out_norepo="$(run_script normal)" || { bad "--repo 省略時に非 0 終了した"; out_norepo=""; }
  if [ -n "$out_norepo" ]; then
    case "$(printf '%s' "$out_norepo" | tr '\n' '|')" in
      *'REPO=stub-owner/stub-repo'*) ok "--repo 省略時は gh repo view で対象を確定する" ;;
      *) bad "--repo 省略時の対象確定が期待と違う（実際: $(printf '%s' "$out_norepo" | tr '\n' '|')）" ;;
    esac
  fi

  # 対象リポジトリを確定できなければ作成に進まない
  rc_nrv=0
  out_nrv="$(run_script norepoview)" || rc_nrv=$?
  if [ "$rc_nrv" -eq 0 ]; then
    bad "gh repo view が失敗しても成功として終了した"
  else
    case "$out_nrv" in
      *GH_LABEL_CREATE_ARGV*) bad "対象リポジトリ未確定のまま label create が実行された" ;;
      *) ok "対象リポジトリを確定できなければ 1 件も作成せず非 0 で終了する" ;;
    esac
  fi

  # 引数の fail-closed: 未知の余剰引数・値なし --repo は書き込みに進まず拒否する
  rc_extra=0
  out_extra="$(run_script normal --repo "stub-owner/stub-repo" --dry-run)" || rc_extra=$?
  if [ "$rc_extra" -ne 0 ] && [[ "$out_extra" != *GH_LABEL_CREATE_ARGV* ]]; then
    ok "未知の余剰引数（--dry-run 等）は黙って無視せず拒否する"
  else
    bad "未知の余剰引数が黙殺された（dry-run したつもりの本番書き込みを許す）"
  fi
  rc_noval=0
  out_noval="$(run_script normal --repo)" || rc_noval=$?
  if [ "$rc_noval" -ne 0 ] && [[ "$out_noval" != *GH_LABEL_CREATE_ARGV* ]]; then
    ok "値の無い --repo は拒否する"
  else
    bad "値の無い --repo が拒否されない"
  fi

  # 照会を信用できない 3 経路はすべて fail-closed（作成ゼロ + 非 0 + 原因どおりの診断）
  expect_failclosed fail "取得できませんでした" "照会失敗では 1 件も作成せず非 0 で終了する（fail-closed）"
  expect_failclosed empty "空でした" "空の一覧では 1 件も作成せず非 0 で終了する"
  expect_failclosed truncated "取得上限" "取得上限に達した一覧では 1 件も作成せず非 0 で終了する"

  # 作成失敗は握り潰さない
  out_cf=""
  rc_cf=0
  out_cf="$(run_repo createfail)" || rc_cf=$?
  if [ "$rc_cf" -ne 0 ]; then
    case "$(printf '%s' "$out_cf" | tr '\n' '|')" in
      *'FAILED=major minor patch hotfix urgent'*) ok "作成失敗は FAILED= に列挙され非 0 で終了する" ;;
      *) bad "作成失敗が FAILED= に載っていない（実際: $(printf '%s' "$out_cf" | tr '\n' '|')）" ;;
    esac
  else
    bad "label create が失敗しても成功として終了した（silent failure）"
  fi
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ github-labels-setup verify: $FAIL 件失敗 / $PASS 件成功" >&2
  exit 1
fi
echo "✓ github-labels-setup verify: 全 $PASS 件 pass"
