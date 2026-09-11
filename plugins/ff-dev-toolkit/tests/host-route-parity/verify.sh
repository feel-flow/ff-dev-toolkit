#!/usr/bin/env bash
#
# ホスト経路パリティの回帰検査。
#
# 潰している事故: **規定を 1 ホスト経路だけに書くこと**。このリポジトリの成果物は
# Claude Code / Codex CLI / grok CLI のどれで動かしても同じ機能が成立することを
# 目的にしているが、各ホストの入口は非対称で、1 経路だけに書いた規定は他ホストでは
# 存在しないのと同じになる。実測では、委譲の依存プリフライト契約を常置した回に
# 「Codex 経路は worktree を作らない」という非対称が実装後のレビューで初めて判明し、
# 配置のやり直しになった（観測台帳 OBS-156）。
#
# 正本は開発元リポジトリの docs/06-reference/HOST-PARITY.md が持つ 4 表:
#   hosts        本表が扱うホストと、扱わない理由
#   routes       経路 ID から届け先パスと対象ホストへの対応
#   asymmetries  判明している非対称（一次情報パスと判明した経緯つき）
#   contracts    複数経路へ配ってある契約と、到達すべき経路・経路ごとの正本ファイル・検出語
#
# 件数は書かない。この suite 自身が「手で維持する並行リストの片側だけが動く事故」を
# 潰すためのものなので、ここに件数を直書きすると真っ先に腐る（cli-registry-completeness
# と同じ方針）。
#
# **片方向で足りるかを毎回疑うこと**。宣言から実体への一方向だけだと次が素通りする:
#   - ホスト名を CLI レジストリから消しても、宣言側に残っていれば誰も気付かない
#     → hosts 表と multi-agent.sh の ALL_CLIS を集合一致で見る（両方向）
#   - リポジトリ直下へホスト固有の指示文書を新設しても、宣言に足さなければ通る
#     → 既知のホスト指示文書名を実体から導出し、routes の root-instructions と
#       集合一致で見る（両方向）
#   - repo-local スキルを Claude 側だけに足しても、Codex 側の入口が無いことは
#     どのゲートも見ていなかった（既存の入口検査はスキル名を 1 件ハードコードして
#     いる。2 件目を足しても素通りする）
#     → 2 つの入口ディレクトリを実体から集合一致で見る（両方向）＋ 入口検査
#       スクリプトが参照する名簿とも突き合わせる
#   - 契約が経路のどこかに 1 件でもあれば緑、にすると正本節を消しても同じ経路の
#     別ファイルに残った参照文で通る
#     → contracts 表が経路ごとの「正本ファイル」を持ち、そのファイルでの実在だけを
#       要求する（経路配下の hit を合算しない）
#
# 検出できないこと（原理的な限界。README の「この suite が見ないもの」が正本）:
#   **新しい規定を 1 経路だけに書いた場合は赤にならない**。contracts 表に行が無い
#   ためで、行を足すのは人側の受け持ちである。本 suite が見るのは「配ってあると
#   宣言した契約が、その経路から消えていないか」だけ。
#
# 実体を 1 つも実行しない。Markdown 表の読み取りと grep -F（固定文字列）だけで、
# 正規表現へマルチバイト文字を渡さないのでロケールに依存しない。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/host-route-parity/verify.sh
#
# run-all-required: no — 正本表・repo-local スキル入口・入口検査スクリプトはいずれも
# 開発元リポジトリにしかないため、配布先 checkout では丸ごと適用外になる。開発元では
# repository 直下の docs/ の実在を条件に必ず走り、正本表の欠落は skip ではなく赤にする。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd -P)"
REGISTRY="$REPO_ROOT/docs/06-reference/HOST-PARITY.md"
MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"
REGISTRY_PARSER="$PLUGIN_ROOT/tests/lib/cli-registry-parser.sh"
# 入口検査スクリプトの path はここに直書きしない。asymmetries 表 `skills-discovery`
# 行の一次情報から導出する（下の (4)）。直書きすると、スクリプトを改名した側と表の側の
# 片方だけが動いたときに食い違いが閉じないままになる。

# リポジトリ直下に置かれうるホスト固有の指示文書。実体側の導出キーで、ここに
# 載っているファイルが実在するのに routes の root-instructions へ宣言されて
# いなければ赤になる（= あるホストだけに届く規定を作れる場所が増えたシグナル）。
# 足すときは意図的な編集を強制する形にしておくこと。
#
# ディレクトリ形の候補（Cursor の現行 Project Rules は `.cursor/rules/*.mdc`）も並べる。
# 実在判定は `-e` で行い、ファイルとディレクトリのどちらでも拾う — `-f` だけで見ると
# 現行形の Cursor 規則を新設しても検出されず、legacy の `.cursorrules` しか見られない。
# 現行形と後方互換形の位置づけは docs/MASTER.md と docs/03-implementation/CONVENTIONS.md。
ROOT_INSTRUCTION_CANDIDATES="AGENTS.md CLAUDE.md GEMINI.md GROK.md .cursor/rules .cursorrules .clinerules .github/copilot-instructions.md"

# 配布先 checkout には repository の docs/ が無い。そこは検査対象そのものが存在しない
# 適用外なので suite 全体を skip する（部分 skip にすると pass 0 件の偽 green になる）。
if [ ! -d "$REPO_ROOT/docs" ]; then
  echo "○ skip: repository 直下に docs/ が無いためスキップ（配布先 checkout では正本表・repo-local スキル入口が同梱されず、本 suite の検査は1件も実行されていません）"
  exit 0
fi

# docs/ があるのに正本表が無いのは「消された」であって適用外ではない。fail-closed。
if [ ! -f "$REGISTRY" ]; then
  echo "✗ 正本表が見つかりません: docs/06-reference/HOST-PARITY.md" >&2
  echo "  ホスト間非対称の正本はこの 1 箇所に集約されています。移動したなら本 suite の REGISTRY も直してください" >&2
  exit 1
fi

for path in "$MULTI_AGENT" "$REGISTRY_PARSER"; do
  [ -e "$path" ] || { echo "✗ 対象が見つかりません: $path" >&2; exit 1; }
done

PASS=0
FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }
# 部分 skip は持たない。本 suite の検査対象（正本表 / repo-local スキル入口 / 入口検査スクリプト）はいずれも
# 開発元にしか無く、配布先 checkout では冒頭の docs/ 不在チェックで suite 全体を skip する。
# 開発元で対象が見つからないのは「消された」であって適用外ではないので、skip ではなく赤に倒す。

list_has() { # <空白区切りリスト> <要素>
  case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac
}

# 集合の差分を「どちら側に何が余っているか」まで出す。件数だけでは直す先が読めない。
# process substitution は /dev/fd に依存し read-only sandbox で開けないことがあるため、
# bash 3.2 の membership 比較だけで両方向を走査する。
compare_sets() { # <ラベル> <期待> <実際> <期待側の名前> <実際側の名前>
  local label="$1" expected="$2" actual="$3" ename="$4" aname="$5"
  local item only_e="" only_a=""
  for item in $expected; do
    list_has "$actual" "$item" || only_e="${only_e} ${item}"
  done
  for item in $actual; do
    list_has "$expected" "$item" || only_a="${only_a} ${item}"
  done
  if [ -z "$only_e" ] && [ -z "$only_a" ]; then
    ok "$label"
  else
    bad "$label"
    [ -n "$only_e" ] && echo "      ${ename} にだけある:${only_e}" >&2
    [ -n "$only_a" ] && echo "      ${aname} にだけある:${only_a}" >&2
  fi
  return 0
}

# ── 正本表の読み取り ─────────────────────────────────────────────────────────
#
# sentinel は開始・終了が各1件で正順であることまで見る。重複・欠落・逆順を黙って
# 「0 行」へ畳むと、表を丸ごと消した変更が全 pass のまま緑になる。
parity_block() { # <ブロック名> : 区間内の生の行
  awk -v s="<!-- host-parity:$1:start -->" -v e="<!-- host-parity:$1:end -->" '
    $0 == s { if (inb) bad = 1; inb = 1; ns++; next }
    $0 == e { if (!inb) bad = 1; inb = 0; ne++; next }
    inb { print }
    END { if (ns != 1 || ne != 1 || inb || bad) exit 3 }
  ' "$REGISTRY"
}

# 表の本文行だけを返す（ヘッダー行と区切り行を落とす）。
parity_rows() { # <ブロック名>
  parity_block "$1" | awk '
    substr($0, 1, 1) != "|" { next }
    { body = $0; gsub(/[ \t|:-]/, "", body); if (body == "") next }
    !seen_header { seen_header = 1; next }
    { print }
  '
}

# `exit` で 1 行目だけ読んで抜けない。reader が先に落ちると writer（parity_block の
# awk）が SIGPIPE で死に、`set -euo pipefail` のもとで裸代入ごと rc=141 で落ちる —
# 診断を 1 行も出さない死に方で、count_matching_files で踏んだのと同型。ブロックが
# パイプバッファ（macOS 64KB）を超えたときだけ起きるので、表が育つまで気付けない。
parity_header() { # <ブロック名>
  parity_block "$1" | awk 'substr($0, 1, 1) == "|" && !seen { seen = 1; print }'
}

# `| a | b | c |` の n 番目のセル。前後の空白を落とす。
row_cell() { # <行> <n>
  printf '%s\n' "$1" | awk -F'|' -v n="$2" '
    { c = $(n + 1); gsub(/^[ \t]+/, "", c); gsub(/[ \t]+$/, "", c); print c }
  '
}

row_cell_count() { # <行>
  printf '%s\n' "$1" | awk -F'|' '{ print NF - 2 }'
}

# セル内のバッククォート囲みトークンを 1 行 1 件で返す。
bt_tokens() { # <セル>
  printf '%s\n' "$1" | awk '
    { n = split($0, a, "`"); for (i = 2; i <= n; i += 2) if (a[i] != "") print a[i] }
  '
}

bt_one() { # <セル> : ちょうど1件ならそれを返す。それ以外は非 0
  local toks count
  toks="$(bt_tokens "$1")"
  count="$(printf '%s\n' "$toks" | awk 'NF { n++ } END { print n + 0 }')"
  [ "$count" = "1" ] || return 1
  printf '%s' "$toks"
}

route_paths_of() { # <経路 ID> : その経路の届け先を空白区切りで返す
  local want="$1" rrow rid out=""
  while IFS= read -r rrow; do
    [ -n "$rrow" ] || continue
    rid="$(bt_one "$(row_cell "$rrow" 1)" || true)"
    [ "$rid" = "$want" ] || continue
    out="$(bt_tokens "$(row_cell "$rrow" 2)" | tr '\n' ' ')"
  done <<EOF
$(parity_rows routes)
EOF
  printf '%s' "$out"
}

# 検出語を含むファイル数を数える。
#
# `set -euo pipefail` のもとで `x="$(grep ... | awk ...)"` と書くと、**検出語が
# 1 件も無いとき grep が rc=1 を返して代入ごと失敗し、診断を 1 行も出さないまま
# suite が rc=1 で死ぬ**（変異注入で実測。契約が 1 経路から消えた変異に対し、
# ✗ 行もサマリーも出ずに終わった = 「赤いが理由が読めない」形）。0 件は正常な
# 観測結果なので、grep の rc は 0 / 1 を受理して 2 以上だけを失敗として上へ返す。
count_matching_files() { # <検出語> <パス> : ファイル数を stdout
  local needle="$1" path="$2" out="" rc=0
  if [ -d "$path" ]; then
    out="$(grep -rlIF -- "$needle" "$path" 2>/dev/null)" || rc=$?
  elif [ -f "$path" ]; then
    out="$(grep -lIF -- "$needle" "$path" 2>/dev/null)" || rc=$?
  else
    printf '0\n'
    return 0
  fi
  [ "$rc" -le 1 ] || return 1
  printf '%s\n' "$out" | awk 'NF { n++ } END { print n + 0 }'
}

# asymmetries 表の <ID> 行が挙げる一次情報パスを空白区切りで返す。
# 一次情報列は末尾から 2 列目（最終列は「判明した経緯」）。
asym_sources_of() { # <非対称 ID>
  local want="$1" arow aid n out=""
  while IFS= read -r arow; do
    [ -n "$arow" ] || continue
    aid="$(bt_one "$(row_cell "$arow" 1)" || true)"
    [ "$aid" = "$want" ] || continue
    n="$(row_cell_count "$arow")"
    [ "$n" -ge 2 ] || continue
    out="$(bt_tokens "$(row_cell "$arow" $((n - 1)))" | tr '\n' ' ')"
  done <<EOF
$(parity_rows asymmetries)
EOF
  printf '%s' "$out"
}

# 空白区切りリストの要素数 / n 番目。
count_tokens() { # <空白区切りリスト>
  printf '%s\n' "$1" | awk '{ n += NF } END { print n + 0 }'
}

nth_token() { # <空白区切りリスト> <n>
  printf '%s\n' "$1" | awk -v n="$2" '{ print $n }'
}

route_hosts_of() { # <経路 ID> : その経路の対象ホストを空白区切りで返す
  local want="$1" rrow rid out=""
  while IFS= read -r rrow; do
    [ -n "$rrow" ] || continue
    rid="$(bt_one "$(row_cell "$rrow" 1)" || true)"
    [ "$rid" = "$want" ] || continue
    out="$(bt_tokens "$(row_cell "$rrow" 3)" | tr '\n' ' ')"
  done <<EOF
$(parity_rows routes)
EOF
  printf '%s' "$out"
}

echo "== ホスト経路パリティ（正本: docs/06-reference/HOST-PARITY.md） =="

for block in hosts routes asymmetries contracts; do
  if ! parity_block "$block" >/dev/null; then
    echo "✗ 正本表のブロック '${block}' の sentinel が一意・正順ではありません" >&2
    echo "  期待: host-parity:${block} の start と end が各1件、開始が先" >&2
    exit 1
  fi
done
ok "4 ブロックの sentinel が一意・正順"

# ── (1) hosts 表 と multi-agent.sh の ALL_CLIS ──────────────────────────────
echo
echo "-- ホスト名簿 --"

# shellcheck disable=SC1090,SC1091 # runtime-checked repo-local shared helper
. "$REGISTRY_PARSER"
if ! cli_registry_load "$MULTI_AGENT"; then
  bad "multi-agent.sh の registry を安全に静的解析できません: ${CLI_REGISTRY_ERROR}"
  ALL_CLIS=""
fi

DECLARED_HOSTS=""
TARGET_HOSTS=""
host_rows=0
while IFS= read -r row; do
  [ -n "$row" ] || continue
  host_rows=$((host_rows + 1))
  if ! id="$(bt_one "$(row_cell "$row" 1)")"; then
    bad "hosts 表の 1 列目がバッククォート囲みのホスト名 1 件ではありません: ${row}"
    continue
  fi
  if list_has "$DECLARED_HOSTS" "$id"; then
    bad "hosts 表にホスト名の重複があります: ${id}"
    continue
  fi
  DECLARED_HOSTS="${DECLARED_HOSTS} ${id}"
  target="$(row_cell "$row" 3)"
  reason="$(row_cell "$row" 4)"
  case "$target" in
    yes) TARGET_HOSTS="${TARGET_HOSTS} ${id}" ;;
    no)
      if [ -z "$reason" ] || [ "$reason" = "-" ]; then
        bad "hosts 表の ${id} が対象外なのに理由が空です（対象外は理由を必須にする）"
      fi
      ;;
    *) bad "hosts 表の ${id} の対象列が yes / no ではありません: '${target}'" ;;
  esac
done <<EOF
$(parity_rows hosts)
EOF

if [ "$host_rows" -eq 0 ]; then
  bad "hosts 表が空です — 検査が空振りしています"
fi
if [ -z "${TARGET_HOSTS# }" ]; then
  bad "本表の対象ホストが 1 件もありません — 検査が空振りしています"
else
  ok "対象ホスト:${TARGET_HOSTS}"
fi

if [ -n "$ALL_CLIS" ]; then
  compare_sets "hosts 表のホスト名が multi-agent.sh の ALL_CLIS と一致" \
    "$ALL_CLIS" "$DECLARED_HOSTS" "ALL_CLIS" "hosts 表"
fi

# ── (2) routes 表 ────────────────────────────────────────────────────────────
echo
echo "-- ホスト経路と届け先 --"

ROUTE_IDS=""
route_rows=0
route_path_total=0
while IFS= read -r row; do
  [ -n "$row" ] || continue
  route_rows=$((route_rows + 1))
  if ! rid="$(bt_one "$(row_cell "$row" 1)")"; then
    bad "routes 表の 1 列目がバッククォート囲みの経路名 1 件ではありません: ${row}"
    continue
  fi
  if list_has "$ROUTE_IDS" "$rid"; then
    bad "routes 表に経路名の重複があります: ${rid}"
    continue
  fi
  ROUTE_IDS="${ROUTE_IDS} ${rid}"

  paths="$(bt_tokens "$(row_cell "$row" 2)")"
  if [ -z "$paths" ]; then
    bad "routes 表の ${rid} に届け先パスがありません"
  fi
  for p in $paths; do
    route_path_total=$((route_path_total + 1))
    if [ ! -e "$REPO_ROOT/$p" ]; then
      bad "routes 表の ${rid} が実在しない届け先を指しています: ${p}"
    fi
  done

  hosts="$(bt_tokens "$(row_cell "$row" 3)")"
  if [ -z "$hosts" ]; then
    bad "routes 表の ${rid} に対象ホストがありません"
  fi
  for h in $hosts; do
    list_has "$TARGET_HOSTS" "$h" \
      || bad "routes 表の ${rid} が対象外・未宣言のホストを指しています: ${h}"
  done
done <<EOF
$(parity_rows routes)
EOF

if [ "$route_rows" -eq 0 ]; then
  bad "routes 表が空です — 検査が空振りしています"
elif [ "$route_path_total" -eq 0 ]; then
  bad "routes 表の届け先が 1 件もありません — 検査が空振りしています"
else
  ok "経路 ${route_rows} 件・届け先 ${route_path_total} 件が実在"
fi

# 対象ホストは最低 1 経路から届くこと。届け先の無いホストを表に残すと、
# 「そのホストへは何を書いても届かない」状態が宣言と食い違ったまま通る。
for h in $TARGET_HOSTS; do
  reached=0
  for rid in $ROUTE_IDS; do
    list_has "$(route_hosts_of "$rid")" "$h" && reached=1
  done
  [ "$reached" -eq 1 ] || bad "対象ホスト ${h} へ届く経路が routes 表にありません"
done

# ── (3) リポジトリ直下のホスト指示文書（実体から宣言への逆向き） ─────────────
echo
echo "-- リポジトリ直下の指示文書 --"

ROOT_ACTUAL=""
for cand in $ROOT_INSTRUCTION_CANDIDATES; do
  [ -e "$REPO_ROOT/$cand" ] && ROOT_ACTUAL="${ROOT_ACTUAL} ${cand}"
done
if [ -z "${ROOT_ACTUAL# }" ]; then
  bad "既知のホスト指示文書がリポジトリ直下に 1 件もありません — 導出が空振りしています"
else
  compare_sets "routes の root-instructions がリポジトリ直下の指示文書と一致" \
    "$ROOT_ACTUAL" "$(route_paths_of root-instructions)" "実体" "routes 表"
fi

# ── (4) repo-local スキル入口のパリティ（正本側 と Codex 側） ────────────────
echo
echo "-- repo-local スキル入口 --"

# 届け先は「正本ディレクトリ」「Codex 入口ディレクトリ」の順で宣言する契約。
REPO_LOCAL_PATHS="$(route_paths_of repo-local-skills)"
canon_dir="$(printf '%s\n' "$REPO_LOCAL_PATHS" | awk '{ print $1 }')"
codex_dir="$(printf '%s\n' "$REPO_LOCAL_PATHS" | awk '{ print $2 }')"
if [ -z "$canon_dir" ] || [ -z "$codex_dir" ]; then
  bad "routes 表の repo-local-skills が 2 つの届け先（正本 / Codex 入口）を宣言していません"
elif [ ! -d "$REPO_ROOT/$canon_dir" ] || [ ! -d "$REPO_ROOT/$codex_dir" ]; then
  bad "repo-local スキル入口のディレクトリが実在しません: ${canon_dir} / ${codex_dir}"
else
  canon_names=""
  for d in "$REPO_ROOT/$canon_dir"/*; do
    [ -d "$d" ] || continue
    if [ ! -f "$d/SKILL.md" ]; then
      bad "正本スキルに SKILL.md がありません: ${canon_dir}/$(basename "$d")"
      continue
    fi
    canon_names="${canon_names} $(basename "$d")"
  done
  codex_names=""
  for d in "$REPO_ROOT/$codex_dir"/*; do
    # `-e` はリンク先を追うので、**壊れた symlink はここで落ちる**。落ちると
    # 集合一致にも下の symlink 検査にも現れず、正本を消した / 改名した変更が
    # 緑のまま通る（入口だけが宙に浮く）。`-L` を or で足して列挙に残す。
    [ -e "$d" ] || [ -L "$d" ] || continue
    codex_names="${codex_names} $(basename "$d")"
  done

  if [ -z "${canon_names# }" ]; then
    bad "正本側の repo-local スキルが 1 件もありません — 検査が空振りしています"
  else
    compare_sets "repo-local スキルの集合が正本側と Codex 入口で一致" \
      "$canon_names" "$codex_names" "$canon_dir" "$codex_dir"
  fi

  # Codex 入口は相対 symlink であること。実体コピーは正本の複製になり、黙ってドリフトする。
  for name in $codex_names; do
    link="$REPO_ROOT/$codex_dir/$name"
    expected="../../$canon_dir/$name"
    if [ ! -L "$link" ]; then
      bad "Codex 入口が symlink ではありません: ${codex_dir}/${name}（SKILL.md のコピーは作らない）"
      continue
    fi
    actual="$(readlink "$link")"
    if [ "$actual" != "$expected" ]; then
      bad "Codex 入口の向き先が不正です: ${codex_dir}/${name} は ${actual}（期待: ${expected}）"
      continue
    fi
    if [ ! -f "$link/SKILL.md" ] || [ ! "$link/SKILL.md" -ef "$REPO_ROOT/$canon_dir/$name/SKILL.md" ]; then
      bad "Codex 入口が正本と同一の SKILL.md を参照していません: ${codex_dir}/${name}"
      continue
    fi
    ok "Codex 入口 ${name} が正本への相対 symlink"
  done

  # 入口検査スクリプトが持つ名簿（手で維持している写し）。片側だけ増えると、
  # 2 件目以降のスキルが検査されないまま「入口検査は緑」になる。
  #
  # スクリプトの path は asymmetries 表 `skills-discovery` 行の一次情報から引く
  # （*.sh がちょうど 1 件あることを要求する）。直書きだと、スクリプトを改名した側と
  # 表の側の片方だけが動いたときに食い違いが閉じない。
  #
  # 不在は **skip ではなく赤**。ここへ到達するのは repository 直下に docs/ がある
  # 開発元だけで（配布先 checkout は suite 冒頭で全体 skip する）、開発元で見つから
  # ないのは「改名・移動された」であって適用外ではない。fail-open にすると、2 件目の
  # repo-local スキルを足したときに名簿照合が黙って止まり、本 suite が潰そうとして
  # いる「1 件ハードコードの素通り」がそのまま復活する（変異注入で実測）。
  ENTRYPOINT_CHECKER=""
  checker_rel=""
  checker_count=0
  for src in $(asym_sources_of skills-discovery); do
    case "$src" in
      *.sh) checker_rel="$src"; checker_count=$((checker_count + 1)) ;;
    esac
  done
  if [ "$checker_count" -ne 1 ]; then
    bad "asymmetries 表 skills-discovery の一次情報に入口検査スクリプト（*.sh）がちょうど 1 件ありません（${checker_count} 件）"
  elif [ ! -f "$REPO_ROOT/$checker_rel" ]; then
    bad "入口検査スクリプトが実在しません: ${checker_rel}（asymmetries 表 skills-discovery の一次情報から導出。改名したなら表も直すこと）"
  else
    ENTRYPOINT_CHECKER="$REPO_ROOT/$checker_rel"
    # ここも grep の rc=1（1 件も参照していない）を代入の失敗へ落とさない。
    # 0 件は「名簿が空になった」という観測結果で、集合一致の側が名指しで赤にする。
    checker_raw=""
    checker_rc=0
    checker_raw="$(grep -oE "${canon_dir}/[A-Za-z0-9_.-]+" "$ENTRYPOINT_CHECKER" 2>/dev/null)" || checker_rc=$?
    if [ "$checker_rc" -gt 1 ]; then
      bad "入口検査スクリプトの名簿を読めません（grep が異常終了: rc=${checker_rc}）"
    else
      checker_names="$(printf '%s\n' "$checker_raw" | sed 's|.*/||' | LC_ALL=C sort -u | tr '\n' ' ')"
      compare_sets "入口検査スクリプトの名簿が正本側のスキル集合と一致" \
        "$canon_names" "$checker_names" "$canon_dir" "$(basename "$ENTRYPOINT_CHECKER")"
    fi
  fi
fi

# ── (5) asymmetries 表 ──────────────────────────────────────────────────────
echo
echo "-- 非対称の正本表 --"

header="$(parity_header asymmetries)"
ncell="$(row_cell_count "$header")"
if [ "$ncell" -lt 5 ]; then
  bad "asymmetries 表の列が足りません（ID / 非対称 / ホスト列 / 一次情報 / 判明した経緯）"
else
  header_hosts=""
  i=3
  while [ "$i" -le $((ncell - 2)) ]; do
    hid="$(bt_one "$(row_cell "$header" "$i")" || true)"
    if [ -z "$hid" ]; then
      bad "asymmetries 表のヘッダー ${i} 列目がバッククォート囲みのホスト名ではありません"
    else
      header_hosts="${header_hosts} ${hid}"
    fi
    i=$((i + 1))
  done
  compare_sets "asymmetries 表のホスト列が対象ホストと一致" \
    "$TARGET_HOSTS" "$header_hosts" "hosts 表の対象" "asymmetries ヘッダー"

  ASYM_IDS=""
  asym_rows=0
  source_total=0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    asym_rows=$((asym_rows + 1))
    if [ "$(row_cell_count "$row")" != "$ncell" ]; then
      bad "asymmetries 表の列数がヘッダーと違います: ${row}"
      continue
    fi
    if ! aid="$(bt_one "$(row_cell "$row" 1)")"; then
      bad "asymmetries 表の 1 列目がバッククォート囲みの名前 1 件ではありません: ${row}"
      continue
    fi
    if list_has "$ASYM_IDS" "$aid"; then
      bad "asymmetries 表に名前の重複があります: ${aid}"
      continue
    fi
    ASYM_IDS="${ASYM_IDS} ${aid}"

    # ホスト列の空欄も `-` / `TODO` のようなプレースホルダも許さない。どちらも
    # 「非対称が無い」と読まれる。表自身が「未実測は明記する」を運用ルールにして
    # いるので、`-n` だけの検査では `-` への置換が素通りする（変異注入で実測）。
    i=3
    while [ "$i" -le $((ncell - 2)) ]; do
      cell="$(row_cell "$row" "$i")"
      case "$cell" in
        "")
          bad "asymmetries 表 ${aid} の ${i} 列目が空です（未実測ならその旨を書く）" ;;
        "-"|"--"|"---"|"—"|"–"|"ー"|"−"|"?"|"？"|"N/A"|"n/a"|"NA"|"na"|"TBD"|"tbd"|"TODO"|"todo"|"未定"|"不明")
          bad "asymmetries 表 ${aid} の ${i} 列目がプレースホルダです（'${cell}'）。未実測ならその旨を書く" ;;
      esac
      i=$((i + 1))
    done

    sources="$(bt_tokens "$(row_cell "$row" $((ncell - 1)))")"
    if [ -z "$sources" ]; then
      bad "asymmetries 表 ${aid} に一次情報のパスがありません"
    fi
    for s in $sources; do
      source_total=$((source_total + 1))
      [ -e "$REPO_ROOT/$s" ] \
        || bad "asymmetries 表 ${aid} が実在しない一次情報を指しています: ${s}"
    done

    # 判明した経緯は Issue / PR / ADR / OBS のいずれかの番号を必ず伴う。
    # 根拠の無い行は、次の変更で「まだ本当か」を一から測り直す羽目になる。
    prov="$(row_cell "$row" "$ncell")"
    case "$prov" in
      *"Issue #"[0-9]*|*"PR #"[0-9]*|*"ADR-"[0-9]*|*"OBS-"[0-9]*) ;;
      *) bad "asymmetries 表 ${aid} の経緯に Issue / PR / ADR / OBS の番号がありません: '${prov}'" ;;
    esac
  done <<EOF
$(parity_rows asymmetries)
EOF

  if [ "$asym_rows" -eq 0 ]; then
    bad "asymmetries 表が空です — 検査が空振りしています"
  elif [ "$source_total" -eq 0 ]; then
    bad "asymmetries 表の一次情報が 1 件もありません — 検査が空振りしています"
  else
    ok "非対称 ${asym_rows} 行・一次情報 ${source_total} 件が実在し、経緯つき"
  fi
fi

# ── (6) contracts 表: 宣言した経路から検出語が消えていないか ─────────────────
echo
echo "-- 全ホストへ届ける契約の到達 --"

CONTRACT_IDS=""
contract_rows=0
probe_total=0
while IFS= read -r row; do
  [ -n "$row" ] || continue
  contract_rows=$((contract_rows + 1))
  if ! cid="$(bt_one "$(row_cell "$row" 1)")"; then
    bad "contracts 表の 1 列目がバッククォート囲みの契約名 1 件ではありません: ${row}"
    continue
  fi
  if list_has "$CONTRACT_IDS" "$cid"; then
    bad "contracts 表に契約名の重複があります: ${cid}"
    continue
  fi
  CONTRACT_IDS="${CONTRACT_IDS} ${cid}"

  if ! needle="$(bt_one "$(row_cell "$row" 4)")"; then
    bad "contracts 表 ${cid} の検出語がバッククォート囲み 1 件ではありません"
    continue
  fi
  target_routes="$(bt_tokens "$(row_cell "$row" 2)" | tr '\n' ' ')"
  if [ -z "${target_routes% }" ]; then
    bad "contracts 表 ${cid} に到達すべき経路がありません"
    continue
  fi
  # 正本ファイル列は経路と同じ並びで 1 経路 1 ファイル。件数が食い違ったら、どの
  # 経路にどのファイルが対応するかが決まらないので照合せずに赤にする。
  canon_files="$(bt_tokens "$(row_cell "$row" 3)" | tr '\n' ' ')"
  n_routes="$(count_tokens "$target_routes")"
  n_files="$(count_tokens "$canon_files")"
  if [ "$n_routes" != "$n_files" ]; then
    bad "contracts 表 ${cid} の経路と正本ファイルの件数が違います（経路 ${n_routes} 件 / 正本ファイル ${n_files} 件）"
    continue
  fi

  idx=0
  for rid in $target_routes; do
    idx=$((idx + 1))
    canon="$(nth_token "$canon_files" "$idx")"
    if ! list_has "$ROUTE_IDS" "$rid"; then
      bad "contracts 表 ${cid} が routes 表に無い経路を指しています: ${rid}"
      continue
    fi
    probe_total=$((probe_total + 1))
    # 経路の届け先はそのつど routes 表から引く（経路からパスへの写しを持たない）。
    # 正本ファイルがその届け先の配下にあることまで見る。配下判定を省くと、経路と
    # 正本ファイルの対応がずれた編集（別経路のファイルを書いた）が緑のまま通る。
    under=0
    for rp in $(route_paths_of "$rid"); do
      case "$canon" in
        "$rp"|"$rp"/*) under=1 ;;
      esac
    done
    if [ "$under" -ne 1 ]; then
      bad "contracts 表 ${cid} の正本ファイルが経路 ${rid} の届け先配下にありません: ${canon}"
      continue
    fi
    if [ ! -f "$REPO_ROOT/$canon" ]; then
      bad "contracts 表 ${cid} の正本ファイルが実在しません: ${canon}"
      continue
    fi
    # 経路配下の hit を合算しない。合算すると、正本節を消しても同じ経路の別ファイル
    # に残った参照文で緑になる（実測: deployment-docs の正本節は 1 ファイルの見出し
    # だが、同じ経路の別ファイルに同じ語を含む参照文がある）。逆に全ファイルへ要求
    # する形にもしない — 1 経路が多数のファイルを持つ届け先で無意味に赤くなる。
    if ! found="$(count_matching_files "$needle" "$REPO_ROOT/$canon")"; then
      bad "検出語の探索に失敗しました: ${cid} / ${rid} / ${canon}（grep が異常終了）"
      continue
    fi
    if [ "$found" -gt 0 ]; then
      ok "${cid} が ${rid} の正本 ${canon} に実在"
    else
      bad "${cid} が ${rid} から消えています（検出語「${needle}」が正本ファイル ${canon} にありません）"
    fi
  done
done <<EOF
$(parity_rows contracts)
EOF

if [ "$contract_rows" -eq 0 ]; then
  bad "contracts 表が空です — 検査が空振りしています"
elif [ "$probe_total" -eq 0 ]; then
  bad "契約と経路の照合が 1 件も走っていません — 検査が空振りしています"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ host-route-parity verify: $FAIL 件失敗" >&2
  exit 1
fi
if [ "$PASS" -eq 0 ]; then
  echo "✗ host-route-parity verify: pass が 0 件 — 検査が成立していません" >&2
  exit 1
fi
echo "✓ host-route-parity verify: 全 $PASS 件 pass"
