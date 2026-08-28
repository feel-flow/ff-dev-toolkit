#!/usr/bin/env bash
#
# docs/ 各文書の frontmatter `version` と、文書自身の `## Changelog` 節にある
# 版エントリ（`### [x.y.z]`）の**最大版**が一致することの検査（Issue #884）。
#
# 背景（2 つの別事象）:
#   1. frontmatter 先行 bump: ROADMAP.md が frontmatter だけ 2.2.0 へ bump され、
#      対応する Changelog エントリを持たないまま先頭が [2.1.20] に留まっていた
#      （発見は #882 作業中。エントリは #884 で遡及補記済み）
#   2. 逆方向の乖離: エントリだけを積んで frontmatter を bump し忘れる編集。
#      Issue #884 本文が「またはその逆の」として名指しする、同じ規約の対になる破り方
#
# 既存ゲートの分担（重複実装を作らないための線引き）:
#   - docs-frontmatter-repo: Frontmatter の構造（version の SemVer 形式・
#     `## Changelog` 節の有無）まで。version とエントリの対応は見ない
#   - live-ace-gates: **PLAYBOOK.md はこちらの担当**。scripts/ace/
#     sync-playbook-frontmatter.ts --check（extractLatestChangelogVersion）が
#     frontmatter version ↔ Changelog の対応を常時検査するため、本 suite は
#     PLAYBOOK.md を対象外にする。ACE 側は**先頭エントリ一致・最大版なしの
#     別仕様**であり「同じ不変条件」ではないが、同一文書へ判定条件の異なる
#     検査を重ねると片方だけ通る状態が生まれるため重ねない
#     （ace-scripts-mirror の二重実装回避と同じ動機）
#   - roadmap-release-facts: ROADMAP のリリース表とプラグイン CHANGELOG の照合専用
#   - changelog-version: plugin.json とプラグイン CHANGELOG 先頭のみ（docs/ を読まない）
#   本 suite が埋めるのは「PLAYBOOK.md 以外の docs 文書の version ↔ 自 Changelog」。
#
# 比較は**最大版**にする（先頭エントリではなく）。Changelog の並び順は文書規約に
# 依存し、同梱テンプレート（docs-template/03-implementation/DECISION_TREE.md 等）は
# 昇順で積む。先頭一致だと昇順文書が「並び順」という別の理由で赤になる。最大版
# 一致は並び順に依存せず、frontmatter 先行 bump（fm > 全エントリ）も逆方向
# （最大エントリ > fm）も 1 比較で検出する。なお過去版の欠番（[2.2.0] のような
# 中間エントリの欠落）は検出できず、版番号は patch / minor を正当に飛ばし得るため
# 機械判定もできない。欠番の補記は人手の遡及対応とする。
#
# 対象の導出（手書きリストを持たない。skill-count-consistency と同じ方針）:
#   docs/**/*.md のうち「先頭行が ---（Frontmatter を持つ）かつマスク後本文に
#   `## Changelog` 節を持つ」文書を実体から導出する。先頭行を読めない
#   docs/**/*.md は「Frontmatter なし」と区別できないため、対象外にせず
#   fail-closed で赤に数える。Frontmatter を持たない文書
#   （docs/08-knowledge/playbook/ の分割ファイル・archive、deployment/ 配下の
#   手順書など）は比較対象の version 自体が無いので対象外 — 「どの文書が
#   Frontmatter を持つべきか」は MASTER.md の規則から docs-frontmatter-repo が
#   検査しており、本 suite はパス除外リストを持たずに済む。唯一の名指し除外は
#   上記の PLAYBOOK.md（所有ゲートが別に在るため。パス除外ではなく所有権の委譲）。
#   docs-template/ は走査しない — 同梱テンプレートの DECISION_TREE.md が Changelog
#   節内に運用説明の小見出し（`### 更新ルール`）を正当に置いており、下の「解析
#   できない ### 見出し」検査と両立しない（形式検査は docs-template-frontmatter が
#   担当。version ↔ Changelog の対応はテンプレート側では未検査のまま）。
#
# fail-closed:
#   - 対象を 1 件も導出できなければ赤（抽出の空振りを緑にしない）
#   - 対象なのに、version 行が欠落 / 重複 / 不正形式・Changelog 節の版エントリが
#     0 件・版エントリとして解析できない `### ` 見出しがある・Frontmatter が
#     閉じていない・先頭行を読めない、はいずれも赤（検証できない状態を緑にしない）
#
# `## Changelog` と `### [x.y.z]` の検出はマスク後の行で行う（フェンス / コメント内の
# 例示を本物と数えない。tests/lib/docs-scan.sh の共有実装）。
#
# docs/ を持たないチェックアウト（公開リポジトリ側など）では行頭 `○ skip` + exit 0。
# FF_DOCS_REPO_ROOT で対象リポジトリのルートを差し替えられる（selftest 用）。
#
# read-only 環境で動かせるよう一時ファイルを作らない（here-doc / here-string も
# 使わない — bash が一時ファイルを作るため）。bash 3.2 互換。
# パイプ入力への grep -q は使わない（SIGPIPE 事故防止。run-all case 10）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# リポジトリルートの導出は兄弟 docs 系 suite（docs-frontmatter-repo /
# docs-fact-drift / roadmap-release-facts）と同一の方式に揃える。実在する配置は:
#   - SSOT モノレポ / 公開リポジトリ: どちらも plugins/ff-dev-toolkit/tests/<suite>/
#     のパス構造を保つ（公開同期はパス構造を保持する — sync スクリプトの実装が正本）
#     ため、固定段数 4 つ上がリポジトリルート
#   - インストール済みキャッシュ（~/.claude/plugins/cache/... 配下）: git も docs/ も
#     無く、下の docs/ 不在分岐が理由付き ○ skip で受ける（ハードエラーにしない）
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
ROOT="${FF_DOCS_REPO_ROOT:-$DEFAULT_ROOT}"

# shellcheck source=../lib/docs-scan.sh
. "$SCRIPT_DIR/../lib/docs-scan.sh"

DOCS_ROOT="$ROOT/docs"

if [ ! -d "$DOCS_ROOT" ]; then
  echo "○ skip: $DOCS_ROOT が無いためスキップ（本 suite の検査は1件も実行されていません。docs/ を持つリポジトリで実行してください）"
  exit 0
fi

PASS=0
FAIL=0
TARGETS=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

echo "== frontmatter version と Changelog 内の最大版エントリの一致 =="

# find の失敗をプロセス置換で握りつぶさない — 先に終了状態付きで取得する
# （pipefail が効くので find / sort の失敗はここで suite ごと非 0 になる）。
FILES="$(find "$DOCS_ROOT" -name '*.md' -type f | LC_ALL=C sort)"

while IFS= read -r f; do
  [ -n "$f" ] || continue
  rel="${f#"$DOCS_ROOT"/}"

  # PLAYBOOK.md は live-ace-gates（sync-playbook-frontmatter.ts --check の
  # versionChangelogInSync）が所有する。二重実装にしない（ヘッダ参照）。
  [ "$rel" = "08-knowledge/PLAYBOOK.md" ] && continue

  # 先頭行の読み取り失敗は「Frontmatter なし」と区別する（無言スキップにしない）
  if ! first_line="$(head -n 1 "$f" 2>/dev/null)"; then
    TARGETS=$((TARGETS + 1))
    bad "$rel: 先頭行を読み取れません（読み取り失敗を対象外と混同しないため fail-closed）"
    continue
  fi

  # Frontmatter を持たない文書は対象外（比較する version が無い。ヘッダ参照）
  [ "$first_line" = "---" ] || continue

  # 閉じ行は共有 helper で求める（閉じ行と推定した範囲が YAML らしい行だけで
  # 構成されることまで検証する。「最初の ^---$」だけを採ると、本文に水平線 ---
  # を持つ文書で閉じ欠落が隠れる fail-open になる。実装と規則は
  # tests/lib/docs-scan.sh の ff_docs_fm_close_line）。
  # 閉じが無い / 壊れている場合は fm_end 空のまま全行を走査し、Changelog 節が
  # あれば赤にする（検証不能を緑にしない）。
  fm_state="$(ff_docs_fm_close_line "$f")"
  fm_end=""
  fm_broken=""
  case "$fm_state" in
    none) continue ;;                       # 先頭行検査の後なので通常到達しない
    unclosed) fm_broken="unclosed" ;;
    malformed:*) fm_broken="malformed" ;;
    *[!0-9]*|"")
      # 既知トークンでも行番号でもない値は helper との契約破れ（fail-closed）
      TARGETS=$((TARGETS + 1))
      bad "$rel: Frontmatter 閉じ判定が想定外の値を返しました（${fm_state:-空}）"
      continue
      ;;
    *) fm_end="$fm_state" ;;
  esac

  # マスク後の行から 1 パスで取る: `## Changelog` の件数 / 節内 `### ` 見出しの
  # うち版エントリとして解析できた数・できなかった数 / 解析できた中の最大版。
  # 下流 awk は exit しない（上流 ff_docs_mask_spans の SIGPIPE を避ける）。
  # 節の終端は次のレベル 2 見出し（Changelog は文末規約だが、後続節が
  # 増えた場合に別節の見出しを拾わないため）。
  # 版エントリは `### [x.y.z]` の直後が行末か空白のもののみ（`]garbage` は不正）。
  # SemVer は各要素の先頭ゼロを認めない（`01.0.0` は不正見出し。docs-frontmatter-repo
  # と同じ規則）。
  info="$(ff_docs_mask_spans "$f" | awk -v fe="${fm_end:-0}" '
    # 各要素を awk の数値（IEEE 754 double）として比較する。整数が正確に表せる
    # のは 2^53（約 9.0e15 = 15 桁）までで、これが比較可能域の契約。エントリの
    # 正規表現は桁数を制限しないため 16 桁以上の要素は理論上正確比較できないが、
    # 実用上の版番号（数桁）から 10 桁以上離れており、桁上限の追加検査はしない。
    function vcmp(a, b,   A, B, i, ai, bi) {
      split(a, A, "."); split(b, B, ".")
      for (i = 1; i <= 3; i++) {
        ai = A[i] + 0; bi = B[i] + 0
        if (ai > bi) return 1
        if (ai < bi) return -1
      }
      return 0
    }
    NR <= fe { next }
    /^## Changelog$/ { ncl++; if (!cl) { cl = 1; next } }
    cl && !done && /^## / { done = 1 }
    cl && !done && /^### / {
      if ($0 ~ /^### \[(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\]( .*)?$/) {
        v = $0
        sub(/^### \[/, "", v)
        sub(/\].*$/, "", v)
        if (maxv == "" || vcmp(v, maxv) > 0) maxv = v
      } else {
        ninv++
      }
    }
    END {
      printf "%d %s %d\n", ncl + 0, (maxv == "" ? "-" : maxv), ninv + 0
    }
  ')"
  # フィールドはすべて空白を含まない制御下のトークン（件数・版・数値）。
  # here-string で read すると一時ファイルが要るため、set -- で分解する。
  # shellcheck disable=SC2086 # info は意図的に語分割する
  set -- $info
  changelog_n="$1"
  max_ver="$2"
  invalid_n="$3"

  [ "$changelog_n" -gt 0 ] || continue
  TARGETS=$((TARGETS + 1))

  if [ -z "$fm_end" ]; then
    if [ "$fm_broken" = "malformed" ]; then
      bad "$rel: Frontmatter の閉じ行と推定した --- までに本文らしい行が混在しています（本文の水平線を閉じ行と誤認しない fail-closed。閉じ行の欠落が疑われます）"
    else
      bad "$rel: Frontmatter が閉じていません（version を検証できないため fail-closed）"
    fi
    continue
  fi

  if [ "$changelog_n" -ne 1 ]; then
    bad "$rel: ## Changelog 節が ${changelog_n} 件あります（複数節を集約せず、文書構造の不正として fail-closed）"
    continue
  fi

  # version 行を欠落 / 重複 / 不正形式 / 有効値に分類する（先勝ちで 1 本に縮約すると
  # 重複・不正の併記が「宣言と実効値の食い違い」のまま緑になる。より広い引用符
  # 変種の重複検出は docs-frontmatter-repo の担当で、ここは version キーのみ見る）
  fm_ver="$(awk -v fe="$fm_end" '
    NR >= 2 && NR < fe && /^["\047]?version["\047]?[ \t]*:/ {
      n++
      if ($0 ~ /^version: "(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"$/ && v == "") {
        line = $0
        sub(/^version: "/, "", line)
        sub(/"$/, "", line)
        v = line
      }
    }
    END {
      if (n == 0) print "missing"
      else if (n > 1) print "duplicate"
      else if (v == "") print "malformed"
      else print v
    }
  ' "$f")"
  case "$fm_ver" in
    missing)
      bad "$rel: frontmatter に version 行がありません（fail-closed）"
      continue
      ;;
    duplicate)
      bad "$rel: frontmatter に version 行が複数あります（実効値がパーサ依存になるため fail-closed）"
      continue
      ;;
    malformed)
      bad "$rel: frontmatter の version が \"x.y.z\" 形式（先頭ゼロ不可）ではありません（fail-closed）"
      continue
      ;;
  esac

  if [ "$invalid_n" -gt 0 ]; then
    bad "$rel: ## Changelog 節に版エントリ（### [x.y.z]）として解析できない ### 見出しが ${invalid_n} 件あります（未検査のまま緑にしない）"
    continue
  fi
  if [ "$max_ver" = "-" ]; then
    bad "$rel: ## Changelog 節に版エントリ（### [x.y.z]）が 1 件もありません（fail-closed）"
    continue
  fi
  if [ "$fm_ver" = "$max_ver" ]; then
    ok "$rel: version $fm_ver == Changelog 最大版 [$max_ver]"
  else
    bad "$rel: frontmatter version=$fm_ver が Changelog 内の最大版 [$max_ver] と一致しません（frontmatter だけ bump したか、エントリだけ追加した乖離）"
  fi
done < <(printf '%s\n' "$FILES")

echo ""
if [ "$TARGETS" -eq 0 ]; then
  echo "✗ 対象文書（Frontmatter + ## Changelog 節を持つ docs/**/*.md）を 1 件も導出できません（抽出の空振りを緑にしない）" >&2
  exit 1
fi
echo "結果: 対象 ${TARGETS} 件 / pass=${PASS} fail=${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
echo "✅ docs-version-changelog: all checks passed"
