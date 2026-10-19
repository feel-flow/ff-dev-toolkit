#!/usr/bin/env bash
#
# scripts/knowledge-lookup.sh（ACE Playbook と観測台帳の統合読み出し器）の振る舞い検査（Issue `#1778`）。
#
# 観測台帳は書き込み専用の store になっていて、実装中に引く経路も、振り返りが promoted × open を
# 突き合わせる経路も無かった。読み側を配線するスクリプトを足したが、**状態による切り分け**
# （promoted / mitigated を「未対策」として返さない）と**針が当たらない入力の既定**（store 不在・
# 読めない・見出し書式の変更・配置の曖昧さ）は、動かさないと測れない。本 suite は隔離 fixture で
# 実際に走らせ、出力のグループ分け・RECORD 行・終了コードを照合する。
#
# 検査:
#   K1.  両 store が在るとき、ACE は active / deprecated に、台帳は active / promoted / mitigated に
#        分かれて出る（見出しの下に居るエントリが状態と一致する。promoted / mitigated が
#        「未対策」グループへ混ざらない）
#   K2.  archived（台帳）と archive/（ACE）は既定で出ず、--include-archived で出る
#   K3.  RECORD 行がヒット ID を両 store ぶん列挙する（記録の契約への転記形）
#   K4.  0 件ヒットは rc=0 で RECORD に `0 件`
#   K5.  Playbook だけ不在 → rc=0 / RECORD ace=`Playbook なし`。台帳だけ不在 → rc=0 / obs=`台帳なし`
#   K6.  両 store 不在 → rc=2（「検索を実施した」と記録できる対象が無い）
#   K7.  台帳の見出し書式が変わって 1 件も認識できない → 0 件ヒットの緑にせず `読み取り失敗`
#   K8.  台帳が在るのに読めない → `読み取り失敗`（未導入へ吸収しない）。root 実行時は skip
#   K9.  既定パスに無く root 配下に 1 件だけ在る store は探索で採る。2 件在れば曖昧として採らない
#   K10. --all は AND、既定は OR
#   K11. --format tsv は 1 行 1 エントリで store / id / status / meta / title / location の 6 列
#   K12. キーワード無し → rc=1（usage）
#   K13. --promoted-open: gh の open 一覧に在る Issue を持つ promoted だけを列挙し、無いものは
#        出さない。gh が失敗した repo の参照は隠さず `未確認` として列挙する
#   K14. --promoted-open --offline: 全 promoted が `未確認` として出る（隠さない）
#   K15. --promoted-open で台帳不在 → rc=2
#   K17. コードフェンス内の記入例（テンプレートの `### OBS-XXX:` / `### ACE-XXX:`）を実エントリとして
#        返さない。テンプレート直後の空 store は 0 件 / empty、記入例だけ残して実見出しを壊した台帳は
#        rc=2（記入例で認識件数を作らない）
#   K19. 注記付きの複数 Issue は参照だけで state を引き、注記・非 Issue 参照・修飾なしを保持し、表示注記は判定に使わない
#   K18. live エントリが無い Playbook（全件 archive 済み）でも --include-archived で archive を返す
#   K20. playbook/ のサブディレクトリにあるエントリも返す（件数ゲートと同じ走査範囲。Issue `#2082`）。
#        退避先 _archive/（入れ子を含む）と . 始まりのディレクトリは既定で辿らず、退避先は --include-archived で出る
#   K16. gh が stdin を読み切ってもエントリが欠けない（read ループは fd 3・gh は `</dev/null` の
#        二重防御。片方だけ外しても欠けないため単独の変異では赤にならず、両方外すと赤になる）
#   K21. awk / tr / sed の起動回数がエントリ数に比例しない（4 件と 40 件の台帳で同じ回数。キーワード
#        検索と --promoted-open の両方）。Windows の Git Bash ではプロセス起動 1 回が 0.1 秒を超え、
#        エントリごとの起動は約 350 件の台帳の --promoted-open を 6 分超にしていた
#   K22. 記録済み配置（AGENTS.md のリンク先・docs/MASTER.md の記載ファイル相対リンク）が指す
#        docs-template/08-knowledge/PLAYBOOK.md を ok として検索し、--resolve-playbook も同じ配置を返す（Issue `#2142`）
#   K23. ACE_PLAYBOOK_PATH の Playbook を採る。実在しない値は読み取り失敗（探索で上書きしない）、
#        --playbook が優先、空白だけの値は未設定と同じ
#   K24. 記録も環境変数も無い回は docs-template/ を探索で採らない。記録が plugin 同梱テンプレート
#        （.claude-plugin/plugin.json を持つ dir 直下の docs-template/）を指しても採らない
#   K25. 記録済み配置が 2 件なら曖昧（rc=2 / STATE=ambiguous）。既定パスを含むなら既定パスを採る。
#        既定パスに実体があるのに記録がそれを含まなければ、記録が 1 件でも曖昧
#   K26. /ace-curate・/ace-refine が knowledge-lookup.sh --resolve-playbook を呼び、検索と解決が同じ配置を返す
#   K27. 記録段は root の外・ファイル自体の symlink・node_modules/・絶対パスの記載を候補に数えない
#   K29. ファイル名だけの ACE_PLAYBOOK_PATH でも playbook/ のカテゴリファイルを引き、非 ASCII を含む記録パスを切らない
#   K28. --resolve-playbook の出力契約（unreadable の PATH、相対指定の REL、root 内外は実体で判定、
#        symlink ファイルは実体が root 内のときだけ REL、キーワード拒否）
#
# 空振り検出: 参照抽出を 0 件一致へ変える／判定を表示注記へ戻す／doc: の無照会を外す各変異で K19 が赤（rc=1）、前後の正常対照は46件成功（2026-10-05実測）。参照の不検出・注記の誤読・非 Issue の誤照会を緑にしない。
# 空振り検出: knowledge-lookup.sh の find を -maxdepth 1 へ戻す変異で K20 のサブディレクトリ検出が赤、prune から _archive を外す変異で K20 の既定除外が赤（2026-10-08 実測）。
# 空振り検出: 両 store を置かない root を与えると K6 が rc=2 を要求し、台帳の見出しを `### OBS 001 …`（コロン無し）へ変えると K7 が `読み取り失敗` を要求する（2026-09-19 実測。スクリプト側の noentry 判定を `empty` へ倒す変異で K7 が赤、両不在の rc=2 を rc=0 へ倒す変異で K6 が赤）。
# 空振り検出: K21 は変更前の実装（エントリごとに meta_of の `$(printf | tr | awk)` を起動）へ戻すと 2 件赤（promoted-open 4 件 74 回 / 40 件 650 回、検索 84 回 / 660 回）、annotate_refs の空白除去だけを要素ごとの sed へ戻す変異でも 2 件赤（15 回 / 69 回）。shim が 1 回も呼ばれない回は「測れていない」として赤にする（2026-10-16 Git Bash 実測）。
# 空振り検出: promoted の closed 説明を旧「対策済みまたは再発」へ戻す／mitigated の未解消再発確認を旧説明へ戻すと各 rc=1、正常対照は38件pass（2026-09-28実測）。状態名の接頭辞だけが残っても意味の欠落を緑にしない。
# 空振り検出: resolve_playbook へ 1 件ずつ当てた 9 変異 — 記録段の削除・記録段で docs-template を一律除外・plugin 同梱テンプレートの除外を外す・曖昧時に先頭を採る・既定パス優先を外す・env 段の削除・env の空白判定を外す・旧 resolve_store へ戻す・記載ファイル相対の解決を外す — がすべて K22〜K26 のいずれかで赤（1〜12 件）、正常対照は 69 件成功（2026-10-18 実測）。
# 空振り検出: レビュー対応後の 7 変異 — 記録段の symlink 除外・root 前置照合・node_modules 除外を外す、記録 1 件で実在する既定パスを置き換える、--resolve-playbook の絶対パス実体化を外す、symlink ファイルの実体確認を外す — がそれぞれ K25 / K27 / K28 で赤（1〜2 件）、正常対照は 82 件成功（2026-10-18 実測）。awk が読める記載ファイルで失敗する分岐（読み取り失敗の rc=2）は再現手段が無く未検査。
# 空振り検出: 検索・解決の前に ACE_INDEX を実体化する処理を外すと K28 が 4 件赤、非 ASCII まで含める 2 本目のトークン抽出を外すと K29 が赤（rc=2 / absent）、正常対照は 84 件成功（2026-10-18 実測）。
#
# 変異検出（2026-09-19 実測。変異は 1 件ずつ当て、前後で対照を取る）:
#           emit_obs の archived 除外を外すと 2 件赤（K2 と K11 の行数）。emit_obs の Status 抽出を
#           空へ倒す（全件 unknown）と 11 件赤（K1 の台帳 3 針・K2・K11・K13・K14・K16）。両不在の
#           exit 2 を exit 0 へ倒すと 2 件赤（K6・K7 の唯一 store）。noentry を empty へ倒すと K7 が
#           2 件赤。曖昧時に先頭候補を採る形へ変えると K9 の 2 件目が赤。RECORD 行の ID 連結を
#           落とすと 2 件赤（K3・K5）。
#           extract_entries のフェンス判定を無効化する（フェンス行を検出しない正規表現へ変える）と
#           K17 が 2 件赤（テンプレートの記入例が実エントリとして返り、実見出しを壊した台帳が rc=0 になる。
#           2026-09-19 のクロスモデルレビューで codex-cli / grok-cli が独立に再現した欠陥の回帰）。
#           2026-10-16 の再実測（annotate_refs の process substitution を無くし、gh が emit_obs の
#           read ループと同じシェルで起動されるようになった後）: gh の `</dev/null` と emit_obs の
#           fd 3 を両方外すと K16 が赤（stub がエントリ一覧の残りを読み切る）。片方だけ外す変異は
#           それぞれ緑（もう片方の防御が効く）。それ以前は stub が読むのが annotate_refs 内側の
#           process substitution だったため、両方外しても K16 は緑だった。
#
# 依存: bash・awk・find・mktemp。gh は PATH 先頭の stub で差し替える（実 gh は呼ばない）。
# 一時領域を作れない環境では suite 全体を ○ skip する。
# run-all-required: yes — 台帳の読み側（状態切り分け・不在時の既定・promoted 突き合わせ）を見る唯一の層で、一時領域不足で skip すると「promoted を未対策として返す」退行が黙って戻る

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TARGET="${PLUGIN_ROOT}/scripts/knowledge-lookup.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

echo "== knowledge-lookup: 状態切り分けと針が当たらない入力の既定 =="

if [[ ! -f "${TARGET}" ]]; then
  bad "対象スクリプトが見つかりません: ${TARGET}"
  echo "✗ knowledge-lookup verify: 1 件失敗 / 0 件成功" >&2
  exit 1
fi
if ! TMP="$(mktemp -d "${TMPDIR:-/tmp}/knowledge-lookup-suite.XXXXXX" 2>&1)" || [[ ! -d "${TMP}" ]]; then
  echo "○ skip: 一時ディレクトリを作成できないため knowledge-lookup を実行できません（検査は 1 件も実行されていません）"
  printf '  mktemp: %s\n' "${TMP}"
  exit 0
fi
FINISHED=0
cleanup() {
  local rc=$?
  chmod -R u+rw "${TMP}" 2>/dev/null || true
  rm -rf "${TMP}"
  if [[ "${FINISHED}" -ne 1 ]]; then
    echo "✗ knowledge-lookup verify: suite が途中で終了しました（rc=${rc}）" >&2
    exit 1
  fi
  exit "${rc}"
}
trap cleanup EXIT
finish() { FINISHED=1; exit "$1"; }

# ── fixture ─────────────────────────────────────────────────────────────────
# Playbook: 索引 + playbook/coding.md（active 1・deprecated 1）+ playbook/archive/coding.md（1）
# 台帳: active 1・promoted 2（open / closed）・promoted 1（別 repo・gh 失敗）・mitigated 1・archived 1
make_playbook() { # <root>
  local root="$1"
  mkdir -p "${root}/docs/08-knowledge/playbook/archive"
  cat >"${root}/docs/08-knowledge/PLAYBOOK.md" <<'EOF'
# ACE Playbook

## エントリ一覧

| ID | 主張 | Category | 場所 |
| --- | --- | --- | --- |
| ACE-10-1 | hydration race は e2e で待機を足す | coding | [playbook/coding.md#ace-10-1](./playbook/coding.md#ace-10-1) |
| ACE-10-2 | 旧: hydration は sleep で待つ | coding | [playbook/coding.md#ace-10-2](./playbook/coding.md#ace-10-2) |
EOF
  cat >"${root}/docs/08-knowledge/playbook/coding.md" <<'EOF'
# PLAYBOOK — coding

## エントリ一覧

<a id="ace-10-1"></a>

### ACE-10-1: hydration race は e2e で待機を足す

| Category | coding | Origin | PR-10 |
| Date | 2026-09-01 |
| Helpful | 4 | Harmful | 0 |
| Status | active |

client:load の Island は hydration 前にクリックが落ちる。e2e では明示の待機を足す。

---

<a id="ace-10-2"></a>

### ACE-10-2: 旧: hydration は sleep で待つ

| Category | coding | Origin | PR-10 |
| Date | 2026-08-01 |
| Helpful | 0 | Harmful | 2 |
| Status | deprecated |

固定 sleep は環境差で落ちる。ACE-10-1 に置き換えた。

---
EOF
  cat >"${root}/docs/08-knowledge/playbook/archive/coding.md" <<'EOF'
# archive

<a id="ace-3-1"></a>

### ACE-3-1: hydration の古い回避策（stale）

| Category | coding | Origin | PR-3 |
| Date | 2026-06-01 |
| Helpful | 0 | Harmful | 0 |
| Status | active |

参考のみ。

---
EOF
}
make_ledger() { # <root> [相対パス]
  local root="$1" rel="${2:-docs/08-knowledge/OBSERVATIONS.md}"
  mkdir -p "${root}/$(dirname "${rel}")"
  cat >"${root}/${rel}" <<'EOF'
# 振り返り観測台帳

## エントリ形式

（省略）

## エントリ一覧

<a id="obs-001"></a>

### OBS-001: e2e が負荷で落ちる → hydration 待機を疑え

| Kind | problem | Count | 2 |
| First | 2026-09-11 | Last | 2026-09-18 |
| Status | active | Issue | なし |

同じ e2e が負荷で落ちる。hydration race を先に疑う。

- 2026-09-11: 初回
- 2026-09-18: 再発

---

<a id="obs-002"></a>

### OBS-002: allowlist の skip-review は毎回外れる → 既定へ入れよ

| Kind | problem | Count | 10 |
| First | 2026-08-01 | Last | 2026-09-18 |
| Status | promoted | Issue | feel-flow/ff-dev-toolkit#1846 / feel-flow/ff-dev-toolkit#1700 |

hydration とは無関係だが allowlist の話。

- 2026-09-18: 10 回目

---

<a id="obs-003"></a>

### OBS-003: 閉じた対策の再発 hydration

| Kind | problem | Count | 3 |
| First | 2026-08-01 | Last | 2026-09-01 |
| Status | promoted | Issue | feel-flow/ff-dev-toolkit#1500 |

対策 Issue は閉じている。

- 2026-09-01: 3 回目

---

<a id="obs-004"></a>

### OBS-004: 別 repo に昇格した hydration の観測

| Kind | problem | Count | 3 |
| First | 2026-08-01 | Last | 2026-09-01 |
| Status | promoted | Issue | feel-flow/ai-spec-driven-development#42 |

昇格先の repo は gh が失敗する。

- 2026-09-01: 3 回目

---

<a id="obs-005"></a>

### OBS-005: hydration の対策はスキルに定義済み

| Kind | keep | Count | 3 |
| First | 2026-08-01 | Last | 2026-09-01 |
| Status | mitigated | Issue | skill:multi-review / doc:docs/x.md#anchor |

対策済み。

- 2026-09-01: 3 回目

---

<a id="obs-006"></a>

### OBS-006: 休眠中の hydration 観測

| Kind | problem | Count | 1 |
| First | 2026-01-01 | Last | 2026-01-01 |
| Status | archived | Issue | なし |

休眠。

- 2026-01-01: 初回

---
EOF
}

# gh stub: `gh issue list --repo feel-flow/ff-dev-toolkit …` は open 番号 1846 / 1700 を返す。feel-flow/ai-spec-driven-development は失敗する。
# stdin を読み切る（K16: 呼び出し元の while read を壊さないことの実測）。
make_gh_stub() { # <bindir> <mode: normal|readstdin>
  local bin="$1" mode="$2"
  mkdir -p "${bin}"
  cat >"${bin}/gh" <<EOF
#!/usr/bin/env bash
mode="${mode}"
if [ "\${mode}" = "readstdin" ]; then cat >/dev/null; fi
repo=""
while [ \$# -gt 0 ]; do
  case "\$1" in --repo) repo="\$2"; shift 2 ;; *) shift ;; esac
done
case "\${repo}" in
  feel-flow/ff-dev-toolkit) printf '%s\n' 1846 1700; exit 0 ;;
  *) echo "gh: could not resolve to a Repository" >&2; exit 1 ;;
esac
EOF
  chmod +x "${bin}/gh"
}

# plugin root の handoff（FF_DEV_TOOLKIT_ROOT 等）を継承したまま作業ツリーの実体を叩くと、
# 対象スクリプトの root ガードが「handoff と実体位置の不一致」で rc=3 を返し、全ケースが赤になる
# （grok-cli のレビューで実測: 継承ありで 30 件失敗 / env -u で 35 件成功）。workflow-doctor 等の
# suite と同じく handoff を落として起動する。
# ACE_PLAYBOOK_PATH も落とす — 外の環境に設定があると、全ケースの Playbook がそれに置き換わる。
LOOKUP=(env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT -u FF_DEV_TOOLKIT_SKILL_FILE -u ACE_PLAYBOOK_PATH bash "${TARGET}")
run_lookup() { # <root> <args...> → OUT / RC（stdout+stderr を OUT へ）
  local root="$1"; shift
  set +e
  OUT="$("${LOOKUP[@]}" --root "${root}" "$@" 2>&1)"
  RC=$?
  set -e
}
out_has() { [[ "$(printf '%s\n' "${OUT}" | grep -cF -- "$1")" -gt 0 ]]; }
# グループ見出し `-- <label> --` の直後から次の `--` / `==` / 空行までに ID が居るか
id_under_group() { # <group label 部分文字列> <ID>
  printf '%s\n' "${OUT}" | awk -v g="$1" -v id="$2" '
    /^-- / { ingrp = (index($0, g) > 0) ; next }
    /^== / || /^$/ { ingrp = 0 }
    ingrp && index($0, id "  ") == 1 { found = 1 }
    END { exit found ? 0 : 1 }'
}

# ── K1 / K2 / K3: 両 store ───────────────────────────────────────────────────
ROOT1="${TMP}/both"; make_playbook "${ROOT1}"; make_ledger "${ROOT1}"
run_lookup "${ROOT1}" --offline hydration
if [[ "${RC}" -eq 0 ]]; then ok "K1: 両 store で rc=0"; else bad "K1: rc=${RC}（期待 0）"; printf '%s\n' "${OUT}" | sed 's/^/    | /' >&2; fi
if id_under_group "有効（active）" "ACE-10-1"; then ok "K1: ACE active が有効グループに出る"; else bad "K1: ACE-10-1 が有効グループに無い"; fi
if id_under_group "非推奨（deprecated" "ACE-10-2"; then ok "K1: ACE deprecated が非推奨グループに出る"; else bad "K1: ACE-10-2 が非推奨グループに無い"; fi
if id_under_group "未対策（active" "OBS-001"; then ok "K1: 台帳 active が未対策グループに出る"; else bad "K1: OBS-001 が未対策グループに無い"; fi
if id_under_group "対策 Issue あり（promoted。Issue 列の state を見る: open = 対応中 / closed = 完了照合前または対策後の再発（最新メモで区別））" "OBS-003"; then ok "K1: 台帳 promoted が対策 Issue ありグループに出る"; else bad "K1: OBS-003 が promoted グループに無い"; fi
if id_under_group "対策済み（mitigated。元 Issue と所在は Issue 列。最新メモの未解消再発も確認する）" "OBS-005"; then ok "K1: 台帳 mitigated が対策済みグループに出る"; else bad "K1: OBS-005 が mitigated グループに無い"; fi
if id_under_group "未対策（active" "OBS-003" || id_under_group "未対策（active" "OBS-005"; then
  bad "K1: promoted / mitigated が未対策グループへ混ざっている"
else
  ok "K1: promoted / mitigated は未対策グループへ混ざらない"
fi
if out_has "skill:multi-review / doc:docs/x.md#anchor"; then ok "K1: mitigated の対策の所在（skill: / doc:）がそのまま出る"; else bad "K1: mitigated の所在が出ない"; fi
if out_has "OBS-006"; then bad "K2: archived が既定で出ている"; else ok "K2: archived は既定で出ない"; fi
if out_has "ACE-3-1"; then bad "K2: archive/ 配下が既定で出ている"; else ok "K2: archive/ 配下は既定で出ない"; fi
if out_has "RECORD ace=ACE-10-1,ACE-10-2 obs=OBS-001,OBS-002,OBS-003,OBS-004,OBS-005"; then
  ok "K3: RECORD 行がヒット ID を両 store ぶん列挙する"
else
  bad "K3: RECORD 行が期待形でない"; printf '%s\n' "${OUT}" | grep -F 'RECORD' | sed 's/^/    | /' >&2 || true
fi

run_lookup "${ROOT1}" --offline --include-archived hydration
if id_under_group "休眠（archived" "OBS-006"; then ok "K2: --include-archived で台帳 archived が休眠グループに出る"; else bad "K2: --include-archived でも OBS-006 が出ない"; fi
if id_under_group "アーカイブ（playbook/archive" "ACE-3-1"; then ok "K2: --include-archived で archive/ がアーカイブグループに出る"; else bad "K2: --include-archived でも ACE-3-1 が出ない"; fi

# ── K4: 0 件 ─────────────────────────────────────────────────────────────────
run_lookup "${ROOT1}" --offline zzz-no-such-word
if [[ "${RC}" -eq 0 ]] && out_has "RECORD ace=0 件 obs=0 件"; then ok "K4: 0 件ヒットは rc=0 / RECORD 0 件"; else bad "K4: rc=${RC} / RECORD が 0 件でない"; fi

# ── K5 / K6: 片方不在・両方不在 ───────────────────────────────────────────────
ROOT2="${TMP}/ledger-only"; make_ledger "${ROOT2}"
run_lookup "${ROOT2}" --offline hydration
if [[ "${RC}" -eq 0 ]] && out_has "RECORD ace=Playbook なし obs=OBS-001"; then ok "K5: Playbook だけ不在は rc=0 / RECORD ace=Playbook なし"; else bad "K5: Playbook 不在の扱い（rc=${RC}）"; printf '%s\n' "${OUT}" | grep -F 'RECORD' | sed 's/^/    | /' >&2 || true; fi
ROOT3="${TMP}/playbook-only"; make_playbook "${ROOT3}"
run_lookup "${ROOT3}" --offline hydration
if [[ "${RC}" -eq 0 ]] && out_has "obs=台帳なし"; then ok "K5: 台帳だけ不在は rc=0 / RECORD obs=台帳なし"; else bad "K5: 台帳不在の扱い（rc=${RC}）"; fi
ROOT4="${TMP}/none"; mkdir -p "${ROOT4}"
run_lookup "${ROOT4}" --offline hydration
if [[ "${RC}" -eq 2 ]] && out_has "検索不成立"; then ok "K6: 両 store 不在は rc=2（検索不成立）"; else bad "K6: 両不在で rc=${RC}（期待 2）"; fi

# ── K7: 見出し書式の変更 ──────────────────────────────────────────────────────
ROOT5="${TMP}/heading-changed"; make_playbook "${ROOT5}"; make_ledger "${ROOT5}"
sed -i.bak 's/^### OBS-\([0-9]*\): /### OBS \1 /' "${ROOT5}/docs/08-knowledge/OBSERVATIONS.md" && rm -f "${ROOT5}/docs/08-knowledge/OBSERVATIONS.md.bak"
run_lookup "${ROOT5}" --offline hydration
if [[ "${RC}" -eq 0 ]] && out_has "obs=読み取り失敗（エントリ見出しを認識できない"; then
  ok "K7: 見出し書式の変更は 0 件ではなく読み取り失敗"
else
  bad "K7: 見出し書式の変更が読み取り失敗にならない（rc=${RC}）"; printf '%s\n' "${OUT}" | grep -F 'RECORD' | sed 's/^/    | /' >&2 || true
fi
# 台帳だけの root で見出しが壊れていれば、検索できる store が無いので rc=2
ROOT5b="${TMP}/heading-changed-only"; make_ledger "${ROOT5b}"
sed -i.bak 's/^### OBS-\([0-9]*\): /### OBS \1 /' "${ROOT5b}/docs/08-knowledge/OBSERVATIONS.md" && rm -f "${ROOT5b}/docs/08-knowledge/OBSERVATIONS.md.bak"
run_lookup "${ROOT5b}" --offline hydration
if [[ "${RC}" -eq 2 ]]; then ok "K7: 唯一の store の見出しが壊れていれば rc=2"; else bad "K7: 唯一の store が壊れていても rc=${RC}"; fi

# ── K8: 読めない台帳 ──────────────────────────────────────────────────────────
if [[ "$(id -u)" -eq 0 ]]; then
  echo "  ○ K8 skip: root 実行では読めないファイルを作れない"
else
  ROOT6="${TMP}/unreadable"; make_playbook "${ROOT6}"; make_ledger "${ROOT6}"
  chmod 000 "${ROOT6}/docs/08-knowledge/OBSERVATIONS.md"
  run_lookup "${ROOT6}" --offline hydration
  chmod 644 "${ROOT6}/docs/08-knowledge/OBSERVATIONS.md"
  if [[ "${RC}" -eq 0 ]] && out_has "obs=読み取り失敗（ファイルを読めない）"; then ok "K8: 読めない台帳は読み取り失敗（未導入へ吸収しない）"; else bad "K8: 読めない台帳の扱い（rc=${RC}）"; fi
fi

# ── K9: 実配置の探索 ──────────────────────────────────────────────────────────
ROOT7="${TMP}/nondefault"; make_ledger "${ROOT7}" "docs/playbooks/OBSERVATIONS.md"
run_lookup "${ROOT7}" --offline hydration
if [[ "${RC}" -eq 0 ]] && out_has "docs/playbooks/OBSERVATIONS.md#obs-001"; then ok "K9: 既定パスに無い台帳を root 配下の 1 件から採る"; else bad "K9: 非既定配置の台帳を採れない（rc=${RC}）"; fi
ROOT8="${TMP}/ambiguous"; make_ledger "${ROOT8}" "docs/a/OBSERVATIONS.md"; make_ledger "${ROOT8}" "docs/b/OBSERVATIONS.md"; make_playbook "${ROOT8}"
run_lookup "${ROOT8}" --offline hydration
if [[ "${RC}" -eq 0 ]] && out_has "obs=読み取り失敗（配置が曖昧" && ! out_has "docs/a/OBSERVATIONS.md#obs-001"; then
  ok "K9: 候補が 2 件なら曖昧として採らない"
else
  bad "K9: 曖昧な配置で先頭候補を採っている、または報告形が違う（rc=${RC}）"
fi

# ── K10: AND / OR ────────────────────────────────────────────────────────────
run_lookup "${ROOT1}" --offline hydration allowlist
if out_has "OBS-002" && out_has "OBS-001"; then ok "K10: 既定は OR"; else bad "K10: OR で両方出ない"; fi
run_lookup "${ROOT1}" --offline --all hydration allowlist
if out_has "OBS-002" && ! out_has "OBS-001"; then ok "K10: --all は AND"; else bad "K10: --all が AND になっていない"; fi

# ── K11: tsv ─────────────────────────────────────────────────────────────────
run_lookup "${ROOT1}" --offline --format tsv hydration
tsv_bad="$(printf '%s\n' "${OUT}" | awk -F '\t' '/^(ace|obs)\t/ { if (NF != 6) c++ } END { print c + 0 }')"
tsv_rows="$(printf '%s\n' "${OUT}" | awk -F '\t' '/^(ace|obs)\t/ { c++ } END { print c + 0 }')"
if [[ "${tsv_bad}" -eq 0 && "${tsv_rows}" -eq 7 ]]; then ok "K11: tsv は 6 列 × 7 行（ACE 2 + 台帳 5）"; else bad "K11: tsv の列数不一致 ${tsv_bad} 行 / 行数 ${tsv_rows}（期待 7）"; fi

# ── K12: usage ───────────────────────────────────────────────────────────────
run_lookup "${ROOT1}" --offline
if [[ "${RC}" -eq 1 ]]; then ok "K12: キーワード無しは rc=1"; else bad "K12: キーワード無しで rc=${RC}"; fi

# ── K13 / K16: promoted-open（gh stub） ──────────────────────────────────────
STUB_BIN="${TMP}/bin-normal"; make_gh_stub "${STUB_BIN}" normal
set +e
OUT="$(PATH="${STUB_BIN}:${PATH}" "${LOOKUP[@]}" --root "${ROOT1}" --promoted-open 2>&1)"; RC=$?
set -e
if [[ "${RC}" -eq 0 ]]; then ok "K13: --promoted-open rc=0"; else bad "K13: rc=${RC}"; printf '%s\n' "${OUT}" | sed 's/^/    | /' >&2; fi
if out_has "OBS-002" && out_has "feel-flow/ff-dev-toolkit#1846(open)"; then ok "K13: open の昇格先を持つ promoted が出る"; else bad "K13: OBS-002 が出ない"; fi
if out_has "OBS-003"; then bad "K13: closed だけの promoted が出ている"; else ok "K13: closed だけの promoted は出ない"; fi
if out_has "OBS-004" && out_has "feel-flow/ai-spec-driven-development#42(未確認)"; then ok "K13: gh が失敗した repo の参照は 未確認 として隠さない"; else bad "K13: 未確認の参照が隠れた"; fi
if out_has "SUMMARY promoted=3 open_or_unresolved=2 unresolved=1"; then ok "K13: SUMMARY の件数が一致"; else bad "K13: SUMMARY 不一致"; printf '%s\n' "${OUT}" | grep -F 'SUMMARY' | sed 's/^/    | /' >&2 || true; fi
if out_has "OBS-001" || out_has "OBS-005"; then bad "K13: promoted 以外が混ざっている"; else ok "K13: promoted 以外は出ない"; fi

STUB_BIN2="${TMP}/bin-readstdin"; make_gh_stub "${STUB_BIN2}" readstdin
set +e
OUT="$(PATH="${STUB_BIN2}:${PATH}" "${LOOKUP[@]}" --root "${ROOT1}" --promoted-open 2>&1)"; RC=$?
set -e
if out_has "SUMMARY promoted=3 open_or_unresolved=2 unresolved=1" && out_has "OBS-004"; then
  ok "K16: gh が stdin を読み切ってもエントリが欠けない"
else
  bad "K16: gh の stdin 消費でエントリが欠けた"; printf '%s\n' "${OUT}" | grep -F 'SUMMARY' | sed 's/^/    | /' >&2 || true
fi

# ── K14 / K15 ────────────────────────────────────────────────────────────────
run_lookup "${ROOT1}" --promoted-open --offline
if [[ "${RC}" -eq 0 ]] && out_has "SUMMARY promoted=3 open_or_unresolved=3 unresolved=3 offline=1"; then ok "K14: --offline は全 promoted を 未確認 として出す"; else bad "K14: --offline の扱い（rc=${RC}）"; printf '%s\n' "${OUT}" | grep -F 'SUMMARY' | sed 's/^/    | /' >&2 || true; fi
run_lookup "${ROOT3}" --promoted-open --offline
if [[ "${RC}" -eq 2 ]]; then ok "K15: 台帳不在の --promoted-open は rc=2"; else bad "K15: 台帳不在で rc=${RC}"; fi

# ── K17: フェンス内の記入例を実エントリとして返さない ─────────────────────────
# 同梱テンプレートそのもの（エントリ 0 件・「エントリ形式」節にフェンス入りの記入例）と、
# 記入例だけ残して実見出しを壊した台帳の 2 fixture。
TEMPLATE_DIR="${PLUGIN_ROOT}/docs-template/08-knowledge"
if [[ -f "${TEMPLATE_DIR}/OBSERVATIONS.md" && -f "${TEMPLATE_DIR}/PLAYBOOK.md" ]]; then
  ROOT9="${TMP}/template-only"; mkdir -p "${ROOT9}/docs/08-knowledge"
  cp "${TEMPLATE_DIR}/OBSERVATIONS.md" "${TEMPLATE_DIR}/PLAYBOOK.md" "${ROOT9}/docs/08-knowledge/"
  run_lookup "${ROOT9}" --offline タイトル 主張 problem
  if [[ "${RC}" -eq 0 ]] && ! out_has "OBS-XXX" && ! out_has "ACE-XXX" && out_has "obs_state=empty" && out_has "RECORD ace=0 件 obs=0 件"; then
    ok "K17: テンプレート直後の空 store では記入例（OBS-XXX / ACE-XXX）を返さず 0 件 / empty"
  else
    bad "K17: テンプレートのフェンス内記入例を実エントリとして返している（rc=${RC}）"; printf '%s\n' "${OUT}" | grep -E 'XXX|RECORD|SUMMARY' | sed 's/^/    | /' >&2 || true
  fi
else
  bad "K17: 同梱テンプレート（docs-template/08-knowledge）が見つかりません"
fi
ROOT10="${TMP}/fenced-sample-broken"; make_ledger "${ROOT10}"
sed -i.bak 's/^### OBS-\([0-9]*\): /### OBS \1 /' "${ROOT10}/docs/08-knowledge/OBSERVATIONS.md" && rm -f "${ROOT10}/docs/08-knowledge/OBSERVATIONS.md.bak"
cat >>"${ROOT10}/docs/08-knowledge/OBSERVATIONS.md" <<'EOF'

## 記入例（テンプレートの写し）

```markdown
### OBS-XXX: [検索可能な主張 1 文のタイトル]

| Kind | problem または keep | Count | 1 |
| Status | active | Issue | なし |
```
EOF
run_lookup "${ROOT10}" --offline hydration
if [[ "${RC}" -eq 2 ]] && ! out_has "OBS-XXX"; then
  ok "K17: 記入例だけ残して実見出しを壊した台帳は、記入例で認識件数を作らず rc=2"
else
  bad "K17: フェンス内の記入例が実見出しの破損を覆い隠している（rc=${RC}）"
fi

# ── K18: live が空でも archive は引ける ─────────────────────────────────────
ROOT11="${TMP}/archive-only"; make_playbook "${ROOT11}"
: >"${ROOT11}/docs/08-knowledge/playbook/coding.md"; printf '%s\n' '# PLAYBOOK — coding' '' '## エントリ一覧' >"${ROOT11}/docs/08-knowledge/playbook/coding.md"
run_lookup "${ROOT11}" --offline --include-archived hydration
if [[ "${RC}" -eq 0 ]] && id_under_group "アーカイブ（playbook/archive" "ACE-3-1" && out_has "ace_state=empty"; then
  ok "K18: live エントリが無い Playbook でも --include-archived で archive を返す"
else
  bad "K18: live が空だと archive が出ない（rc=${RC}）"; printf '%s\n' "${OUT}" | grep -E 'ACE-|RECORD|SUMMARY' | sed 's/^/    | /' >&2 || true
fi

# ── K19: 注記付き参照（注記を表示に残して state を引く） ─────────────────────────────────────────
ROOT12="${TMP}/annotated-refs"; mkdir -p "${ROOT12}/docs/08-knowledge"
unqualified_ref="$(printf '#%s' 7)"
note_open_ref="$(printf '#%s(open)' 2)"
note_unresolved_ref="$(printf '#%s(未確認)' 3)"
cat >"${ROOT12}/docs/08-knowledge/OBSERVATIONS.md" <<EOF
# 振り返り観測台帳

## エントリ一覧

### OBS-101: annotated references

| Status | promoted | Issue | feel-flow/ff-dev-toolkit#1（closed）/ feel-flow/ff-dev-toolkit#2(open) / Other.Owner/re_po.name#3（説明） |

### OBS-102: non-issue references

| Status | promoted | Issue | skill:close-issue / doc:docs/06-reference/DECISIONS.md#2026-10-05 / なし |

### OBS-103: unqualified reference

| Status | promoted | Issue | ${unqualified_ref} |

### OBS-104: stale annotation

| Status | promoted | Issue | feel-flow/ff-dev-toolkit#1(open) |

### OBS-105: state-like notes

| Status | promoted | Issue | feel-flow/ff-dev-toolkit#1（旧メモ: ${note_open_ref}、${note_unresolved_ref}） |

### OBS-106: annotated unqualified reference

| Status | promoted | Issue | ${unqualified_ref}（注記） |

### OBS-107: unqualified reference with old state

| Status | promoted | Issue | ${unqualified_ref}(open) |
EOF
STUB_BIN3="${TMP}/bin-annotated"; mkdir -p "${STUB_BIN3}"
GH_REPO_LOG="${TMP}/annotated-gh-repos"
cat >"${STUB_BIN3}/gh" <<'EOF'
#!/usr/bin/env bash
repo=""
while [ $# -gt 0 ]; do
  case "$1" in --repo) repo="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s\n' "${repo}" >>"${GH_REPO_LOG}"
case "${repo}" in
  feel-flow/ff-dev-toolkit) printf '%s\n' 2 ;;
  Other.Owner/re_po.name) printf '%s\n' 3 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${STUB_BIN3}/gh"
set +e
OUT="$(GH_REPO_LOG="${GH_REPO_LOG}" PATH="${STUB_BIN3}:${PATH}" "${LOOKUP[@]}" --root "${ROOT12}" --promoted-open 2>&1)"; RC=$?
set -e
if [[ "${RC}" -eq 0 ]] && out_has 'feel-flow/ff-dev-toolkit#1(closed)（closed）/ feel-flow/ff-dev-toolkit#2(open)(open)' && out_has 'Other.Owner/re_po.name#3(open)（説明）'; then
  ok "K19: 各参照の state を解決し、注記と区切りを保持する"
else
  bad "K19: 注記付きの複数参照を解決できない（rc=${RC}）"
fi
if [[ -f "${GH_REPO_LOG}" ]] && [[ "$(cat "${GH_REPO_LOG}")" = "$(printf '%s\n' feel-flow/ff-dev-toolkit Other.Owner/re_po.name)" ]]; then
  ok "K19: gh には抽出した repo だけを渡し、repo ごとに 1 回取得する"
else
  bad "K19: gh の repo が壊れている、余分な呼び出しがある、または呼ばれていない"
fi
if out_has 'OBS-103' && out_has "${unqualified_ref}(未確認: リポジトリ修飾なし)"; then
  ok "K19: #N だけの参照は修飾なしの未確認を保持する"
else
  bad "K19: 修飾なしの参照が隠れた、または解決された"
fi
if out_has 'OBS-104'; then bad "K19: 古い (open) 注記を現在の open state と誤認している"; else ok "K19: closed の参照に古い (open) 注記があっても列挙しない"; fi
if out_has 'OBS-105'; then bad "K19: 注記中の別番号の open / 未確認を現在の state と誤認している"; else ok "K19: 注記中の別番号の state は判定に使わない"; fi
if out_has 'OBS-106' && out_has 'OBS-107'; then ok "K19: 注記付きの修飾なし参照も未確認として列挙する"; else bad "K19: 注記付きの修飾なし参照が隠れた"; fi
if out_has 'SUMMARY promoted=7 open_or_unresolved=4 unresolved=3'; then ok "K19: SUMMARY は表示注記に左右されず取得した state を数える"; else bad "K19: SUMMARY が注記の state に左右されている"; fi
set +e
OUT="$(GH_REPO_LOG="${GH_REPO_LOG}" PATH="${STUB_BIN3}:${PATH}" "${LOOKUP[@]}" --root "${ROOT12}" --format tsv references 2>&1)"; RC=$?
set -e
if [[ "${RC}" -eq 0 ]] && out_has 'Issue=skill:close-issue / doc:docs/06-reference/DECISIONS.md#2026-10-05 / なし' && [[ "$(cat "${GH_REPO_LOG}")" = "$(printf '%s\n' feel-flow/ff-dev-toolkit Other.Owner/re_po.name feel-flow/ff-dev-toolkit Other.Owner/re_po.name)" ]]; then
  ok "K19: skill: / doc: / なしは state を付けずそのまま表示する"
else
  bad "K19: 非 Issue 参照の表示が変わった（rc=${RC}）"
fi

# ── K20: サブディレクトリのエントリと _archive/ ─────────────────────────────────
ROOT13="${TMP}/subdirs"; make_playbook "${ROOT13}"
mkdir -p "${ROOT13}/docs/08-knowledge/playbook/process/_archive" "${ROOT13}/docs/08-knowledge/playbook/_archive" "${ROOT13}/docs/08-knowledge/playbook/.obsidian"
for spec in "process/review.md:20-1:hydration のレビュー観点" "_archive/old.md:21-1:hydration の退避済み" ".obsidian/x.md:22-1:hydration の設定メモ" "process/_archive/old.md:23-1:hydration の入れ子の退避済み"; do
  rel="${spec%%:*}"; rest="${spec#*:}"; id="${rest%%:*}"; title="${rest#*:}"
  {
    echo "# sub"; echo ""; echo "### ACE-${id}: ${title}"; echo ""
    echo "| Category | process |"; echo "| Status | active |"; echo ""; echo "---"
  } >"${ROOT13}/docs/08-knowledge/playbook/${rel}"
done
run_lookup "${ROOT13}" --offline hydration
if [[ "${RC}" -eq 0 ]] && out_has "ACE-20-1"; then
  ok "K20: playbook/ のサブディレクトリのエントリを返す"
else
  bad "K20: サブディレクトリのエントリが出ない（rc=${RC}）"
fi
if out_has "ACE-21-1" || out_has "ACE-22-1" || out_has "ACE-23-1"; then
  bad "K20: _archive/（入れ子を含む）か . 始まりのディレクトリが既定で出ている"
else
  ok "K20: _archive/（入れ子を含む）と . 始まりのディレクトリは既定で辿らない"
fi
run_lookup "${ROOT13}" --offline --include-archived hydration
if id_under_group "アーカイブ（playbook/archive" "ACE-21-1" && id_under_group "アーカイブ（playbook/archive" "ACE-23-1"; then
  ok "K20: --include-archived で _archive/ と入れ子の退避先もアーカイブグループに出る"
else
  bad "K20: --include-archived でも _archive/ の ACE-21-1 か入れ子の ACE-23-1 が出ない"
fi
if out_has "ACE-22-1"; then
  bad "K20: --include-archived で . 始まりのディレクトリまで出ている"
else
  ok "K20: --include-archived でも . 始まりのディレクトリは辿らない"
fi

# ── K21: 外部プロセスの起動回数がエントリ数に比例しない ─────────────────────────
# Windows の Git Bash（MSYS）ではプロセス起動 1 回が 0.1 秒を超え、エントリごとに awk / tr / sed を
# 起動する形は約 350 件の台帳で 6 分を超えた。awk / tr / sed を数える shim を PATH 先頭に置き、
# エントリ 4 件と 40 件の台帳で起動回数が同じであることを見る（キーワード検索と --promoted-open の両方。
# promoted / mitigated の Issue 列の解決を通すため gh も stub にする）。
make_scale_ledger() { # <root> <件数>
  local root="$1" n="$2" i=0 st=""
  mkdir -p "${root}/docs/08-knowledge"
  {
    printf '%s\n' "# 振り返り観測台帳" "" "## エントリ一覧" ""
    while [[ "${i}" -lt "${n}" ]]; do
      i=$((i + 1))
      case $((i % 4)) in 0) st="promoted" ;; 1) st="mitigated" ;; 2) st="active" ;; *) st="archived" ;; esac
      printf '### OBS-%03d: scale hydration %s\n\n| Kind | problem | Count | 1 |\n| First | 2026-09-01 | Last | 2026-09-02 |\n| Status | %s | Issue | feel-flow/ff-dev-toolkit#1846 / feel-flow/ff-dev-toolkit#%s（注記） / skill:x |\n\nbody\n\n---\n\n' "${i}" "${i}" "${st}" "${i}"
    done
  } >"${root}/docs/08-knowledge/OBSERVATIONS.md"
}
SPAWN_BIN="${TMP}/bin-spawn"; mkdir -p "${SPAWN_BIN}"
make_gh_stub "${SPAWN_BIN}" normal
for tool in awk tr sed; do
  real="$(command -v "${tool}")"
  cat >"${SPAWN_BIN}/${tool}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "${tool}" >>"\${KL_SPAWN_LOG}"
exec "${real}" "\$@"
EOF
  chmod +x "${SPAWN_BIN}/${tool}"
done
spawn_count() { # <root> <args...> → SPAWN_N（awk / tr / sed の起動回数）/ RC
  local root="$1" log="${TMP}/spawn.log"; shift
  : >"${log}"
  set +e
  OUT="$(KL_SPAWN_LOG="${log}" PATH="${SPAWN_BIN}:${PATH}" "${LOOKUP[@]}" --root "${root}" "$@" 2>&1)"; RC=$?
  set -e
  SPAWN_N="$(wc -l <"${log}" | tr -d ' ')"
}
ROOT14="${TMP}/scale-small"; make_scale_ledger "${ROOT14}" 4
ROOT15="${TMP}/scale-large"; make_scale_ledger "${ROOT15}" 40
for mode in promoted-open search; do
  if [[ "${mode}" = "promoted-open" ]]; then set -- --promoted-open; else set -- --include-archived hydration; fi
  spawn_count "${ROOT14}" "$@"; small_n="${SPAWN_N}"; small_rc="${RC}"
  spawn_count "${ROOT15}" "$@"; large_n="${SPAWN_N}"; large_rc="${RC}"
  if [[ "${small_rc}" -ne 0 || "${large_rc}" -ne 0 ]]; then
    bad "K21 (${mode}): 実行に失敗（rc=${small_rc} / ${large_rc}）"; printf '%s\n' "${OUT}" | tail -n 5 | sed 's/^/    | /' >&2
  elif [[ "${small_n}" -eq 0 ]]; then
    # shim を 1 回も通らないなら数えられていない（PATH 経由で起動していない等）。緑にしない。
    bad "K21 (${mode}): awk / tr / sed の shim が 1 回も呼ばれていない（起動回数を測れていない）"
  elif [[ "${small_n}" -eq "${large_n}" ]]; then
    ok "K21 (${mode}): awk / tr / sed の起動回数がエントリ数に比例しない（4 件 / 40 件ともに ${small_n} 回）"
  else
    bad "K21 (${mode}): 起動回数がエントリ数で変わる（4 件 ${small_n} 回 / 40 件 ${large_n} 回）"
  fi
done
set --

# ── K22〜K25: ACE Playbook の配置解決（resolve_playbook。Issue `#2142`） ────────────────
# 優先順 --playbook → ACE_PLAYBOOK_PATH → 記録済み配置 → 既定パス → 探索。テンプレ配布リポジトリ
# （実体が docs-template/08-knowledge/ に在る）で「Playbook なし」と報告していた欠陥の回帰を見る。
make_template_playbook() { # <root> — Playbook の実体を docs-template/08-knowledge/ へ置く
  local root="$1"
  make_playbook "${root}"
  mkdir -p "${root}/docs-template"
  mv "${root}/docs/08-knowledge" "${root}/docs-template/08-knowledge"
}
run_resolve() { # <root> [args...] → OUT / RC（stdout だけ。KEY=VALUE の 4 行）
  local root="$1"; shift
  set +e
  OUT="$("${LOOKUP[@]}" --root "${root}" --resolve-playbook "$@" 2>/dev/null)"
  RC=$?
  set -e
}
run_with_env() { # <ACE_PLAYBOOK_PATH> <root> <args...> → OUT / RC
  local envp="$1" root="$2"; shift 2
  set +e
  OUT="$(env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT -u FF_DEV_TOOLKIT_SKILL_FILE ACE_PLAYBOOK_PATH="${envp}" bash "${TARGET}" --root "${root}" "$@" 2>&1)"
  RC=$?
  set -e
}
kv() { printf '%s\n' "${OUT}" | awk -v k="$1=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }'; }

# K22: 記録済み配置（AGENTS.md のリンク先）から docs-template/ 配下の実体を採る（AC1）
ROOT22="${TMP}/template-recorded"; make_template_playbook "${ROOT22}"; make_ledger "${ROOT22}"
printf '%s\n' '採番ルールの SSOT は [PLAYBOOK.md §エントリID規則](docs-template/08-knowledge/PLAYBOOK.md#エントリid規則)。' >"${ROOT22}/AGENTS.md"
run_lookup "${ROOT22}" --offline hydration
if [[ "${RC}" -eq 0 ]] && out_has "== ACE Playbook（docs-template/08-knowledge/PLAYBOOK.md） ==" && out_has "ace_state=ok" \
  && out_has "ACE-10-1" && ! out_has "Playbook なし"; then
  ok "K22: 記録済み配置の docs-template/08-knowledge/PLAYBOOK.md を ok として検索する"
else
  bad "K22: 記録済み配置の Playbook を引けない（rc=${RC}）"; printf '%s\n' "${OUT}" | grep -E '^(== ACE|RECORD|SUMMARY)' | sed 's/^/    | /' >&2 || true
fi
run_resolve "${ROOT22}"
if [[ "${RC}" -eq 0 ]] && [[ "$(kv ACE_PLAYBOOK_STATE)" = "ok" ]] && [[ "$(kv ACE_PLAYBOOK_SOURCE)" = "recorded:AGENTS.md" ]] \
  && [[ "$(kv ACE_PLAYBOOK_REL)" = "docs-template/08-knowledge/PLAYBOOK.md" ]]; then
  ok "K22: --resolve-playbook は recorded:AGENTS.md と root 相対パスを返す"
else
  bad "K22: --resolve-playbook の出力が違う（rc=${RC}）"; printf '%s\n' "${OUT}" | sed 's/^/    | /' >&2
fi
# 記録は記載ファイルのディレクトリ相対でも解く（docs/MASTER.md の `./…`）
ROOT22m="${TMP}/template-recorded-master"; make_template_playbook "${ROOT22m}"; mkdir -p "${ROOT22m}/docs"
printf '%s\n' '- [PLAYBOOK.md](../docs-template/08-knowledge/PLAYBOOK.md) - ACE 知見' >"${ROOT22m}/docs/MASTER.md"
run_resolve "${ROOT22m}"
if [[ "${RC}" -eq 0 ]] && [[ "$(kv ACE_PLAYBOOK_SOURCE)" = "recorded:docs/MASTER.md" ]] && [[ "$(kv ACE_PLAYBOOK_REL)" = "docs-template/08-knowledge/PLAYBOOK.md" ]]; then
  ok "K22: docs/MASTER.md の記載ファイル相対リンクを解く"
else
  bad "K22: 記載ファイル相対の記録を解けない（rc=${RC}）"; printf '%s\n' "${OUT}" | sed 's/^/    | /' >&2
fi

# K23: ACE_PLAYBOOK_PATH（AC1 の環境変数側）と、明示の優先・読めない指定の扱い
ROOT23="${TMP}/template-env"; make_template_playbook "${ROOT23}"; make_ledger "${ROOT23}"
run_with_env "${ROOT23}/docs-template/08-knowledge/PLAYBOOK.md" "${ROOT23}" --offline hydration
if [[ "${RC}" -eq 0 ]] && out_has "ace_state=ok" && out_has "ACE-10-1"; then ok "K23: ACE_PLAYBOOK_PATH の Playbook を ok として検索する"; else bad "K23: ACE_PLAYBOOK_PATH が効かない（rc=${RC}）"; fi
run_with_env "${ROOT23}/docs-template/08-knowledge/PLAYBOOK.md" "${ROOT23}" --resolve-playbook
if [[ "${RC}" -eq 0 ]] && [[ "$(kv ACE_PLAYBOOK_SOURCE)" = "env" ]]; then ok "K23: --resolve-playbook は SOURCE=env"; else bad "K23: env の SOURCE が違う（rc=${RC}）"; fi
run_with_env "${ROOT23}/no-such/PLAYBOOK.md" "${ROOT23}" --offline hydration
if [[ "${RC}" -eq 0 ]] && out_has "ace=読み取り失敗（ファイルを読めない）"; then ok "K23: 実在しない ACE_PLAYBOOK_PATH は読み取り失敗（探索で上書きしない）"; else bad "K23: 実在しない ACE_PLAYBOOK_PATH の扱い（rc=${RC}）"; fi
run_with_env "${ROOT23}/no-such/PLAYBOOK.md" "${ROOT23}" --resolve-playbook --playbook "${ROOT23}/docs-template/08-knowledge/PLAYBOOK.md"
if [[ "${RC}" -eq 0 ]] && [[ "$(kv ACE_PLAYBOOK_SOURCE)" = "explicit" ]]; then ok "K23: --playbook は ACE_PLAYBOOK_PATH より優先"; else bad "K23: --playbook が優先されない（rc=${RC}）"; fi
run_with_env "   " "${ROOT22}" --resolve-playbook
if [[ "${RC}" -eq 0 ]] && [[ "$(kv ACE_PLAYBOOK_SOURCE)" = "recorded:AGENTS.md" ]]; then ok "K23: 空白だけの ACE_PLAYBOOK_PATH は未設定と同じ"; else bad "K23: 空白だけの ACE_PLAYBOOK_PATH を値として扱った（rc=${RC}）"; fi

# K24: 記録も環境変数も無い回は従来どおり探索し、docs-template/ の配布テンプレートを採らない（AC2）
ROOT24="${TMP}/template-unrecorded"; make_template_playbook "${ROOT24}"; make_ledger "${ROOT24}"
run_lookup "${ROOT24}" --offline hydration
if [[ "${RC}" -eq 0 ]] && out_has "ace=Playbook なし" && ! out_has "ACE-10-1"; then ok "K24: 記録なしの docs-template/ 配下は探索で採らない"; else bad "K24: 記録なしで docs-template/ を採った（rc=${RC}）"; fi
# plugin 同梱の配布テンプレート（.claude-plugin/plugin.json を持つ dir 直下の docs-template/）は記録されていても採らない
ROOT24p="${TMP}/bundled-template"; make_playbook "${ROOT24p}"; make_ledger "${ROOT24p}"
make_template_playbook "${TMP}/bundled-src"; mkdir -p "${ROOT24p}/plugins/kit/.claude-plugin"
printf '{"name":"kit"}\n' >"${ROOT24p}/plugins/kit/.claude-plugin/plugin.json"
mv "${TMP}/bundled-src/docs-template" "${ROOT24p}/plugins/kit/docs-template"
printf '%s\n' '雛形は `plugins/kit/docs-template/08-knowledge/PLAYBOOK.md`。' >"${ROOT24p}/AGENTS.md"
run_resolve "${ROOT24p}"
if [[ "${RC}" -eq 0 ]] && [[ "$(kv ACE_PLAYBOOK_SOURCE)" = "default" ]] && [[ "$(kv ACE_PLAYBOOK_REL)" = "docs/08-knowledge/PLAYBOOK.md" ]]; then
  ok "K24: 記録が plugin 同梱テンプレートを指しても既定パスの実体を採る"
else
  bad "K24: plugin 同梱テンプレートを記録として採った（rc=${RC}）"; printf '%s\n' "${OUT}" | sed 's/^/    | /' >&2
fi

# K25: 記録の矛盾は曖昧（推測で選ばない）。既定パスが候補に含まれるなら既定パスを採る
ROOT25="${TMP}/recorded-conflict"; make_template_playbook "${ROOT25}"; make_ledger "${ROOT25}"
mkdir -p "${ROOT25}/docs/old"; cp "${ROOT25}/docs-template/08-knowledge/PLAYBOOK.md" "${ROOT25}/docs/old/PLAYBOOK.md"
printf '%s\n' '`docs-template/08-knowledge/PLAYBOOK.md`' >"${ROOT25}/AGENTS.md"
printf '%s\n' '`docs/old/PLAYBOOK.md`' >"${ROOT25}/CLAUDE.md"
run_lookup "${ROOT25}" --offline hydration
if [[ "${RC}" -eq 0 ]] && out_has "ace=読み取り失敗（配置が曖昧" && ! out_has "ACE-10-1"; then ok "K25: 記録済み配置が 2 件なら曖昧として採らない"; else bad "K25: 矛盾した記録から 1 つを選んだ（rc=${RC}）"; fi
run_resolve "${ROOT25}"
if [[ "${RC}" -eq 2 ]] && [[ "$(kv ACE_PLAYBOOK_STATE)" = "ambiguous" ]] && [[ -z "$(kv ACE_PLAYBOOK)" ]]; then ok "K25: --resolve-playbook は rc=2 / STATE=ambiguous"; else bad "K25: 曖昧時の --resolve-playbook（rc=${RC}）"; fi
ROOT25d="${TMP}/recorded-default-and-stub"; make_playbook "${ROOT25d}"; make_ledger "${ROOT25d}"
printf '%s\n' '# moved' >"${ROOT25d}/docs/PLAYBOOK.md"
printf '%s\n' '- [PLAYBOOK.md](./08-knowledge/PLAYBOOK.md)（旧 `docs/PLAYBOOK.md` はリダイレクト）' >"${ROOT25d}/docs/MASTER.md"
run_resolve "${ROOT25d}"
if [[ "${RC}" -eq 0 ]] && [[ "$(kv ACE_PLAYBOOK_REL)" = "docs/08-knowledge/PLAYBOOK.md" ]]; then ok "K25: 既定パスを含む複数の記録は既定パスを採る（旧配置の注記で退行しない）"; else bad "K25: 既定パスを含む記録で既定を採らない（rc=${RC}）"; fi

# 既定パスに実体があるのに記録がそれを含まない → 記録が 1 件でも 2 件でも曖昧（既定パスを黙って置き換えない）
ROOT25e="${TMP}/recorded-conflict-with-default"; make_template_playbook "${ROOT25e}"; make_playbook "${ROOT25e}"; make_ledger "${ROOT25e}"
mkdir -p "${ROOT25e}/docs/old"; printf '%s\n' '# moved' >"${ROOT25e}/docs/old/PLAYBOOK.md"
printf '%s\n' '`docs-template/08-knowledge/PLAYBOOK.md`' >"${ROOT25e}/AGENTS.md"
printf '%s\n' '`docs/old/PLAYBOOK.md`' >"${ROOT25e}/CLAUDE.md"
run_resolve "${ROOT25e}"
if [[ "${RC}" -eq 2 ]] && [[ "$(kv ACE_PLAYBOOK_STATE)" = "ambiguous" ]]; then ok "K25: 既定パスが実在し記録 2 件がそれを含まなければ曖昧"; else bad "K25: 既定パスが実在する記録の矛盾で 1 つを選んだ（rc=${RC}）"; fi
rm -f "${ROOT25e}/AGENTS.md"
run_resolve "${ROOT25e}"
if [[ "${RC}" -eq 2 ]] && [[ "$(kv ACE_PLAYBOOK_STATE)" = "ambiguous" ]]; then ok "K25: 既定パスが実在し記録 1 件がスタブを指すなら曖昧（スタブへ切り替えない）"; else bad "K25: 1 件の記録で実在する既定パスを置き換えた（rc=${RC} / $(kv ACE_PLAYBOOK_REL)）"; fi

# K27: 記録段の除外（root の外・ファイル自体の symlink・node_modules/・絶対パス）
ROOT27="${TMP}/recorded-excluded"; make_ledger "${ROOT27}"
make_template_playbook "${TMP}/outside-src"; mkdir -p "${TMP}/outside"; cp "${TMP}/outside-src/docs-template/08-knowledge/PLAYBOOK.md" "${TMP}/outside/PLAYBOOK.md"
mkdir -p "${ROOT27}/docs/kb" "${ROOT27}/node_modules/x" "${ROOT27}/docs/abs"
cp "${TMP}/outside/PLAYBOOK.md" "${ROOT27}/docs/abs/PLAYBOOK.md"
ln -s "${TMP}/outside/PLAYBOOK.md" "${ROOT27}/docs/kb/PLAYBOOK.md"
cp "${TMP}/outside/PLAYBOOK.md" "${ROOT27}/node_modules/x/PLAYBOOK.md"
for rec in '../outside/PLAYBOOK.md' 'docs/kb/PLAYBOOK.md' 'node_modules/x/PLAYBOOK.md' "${ROOT27}/docs/abs/PLAYBOOK.md"; do
  printf '`%s`\n' "${rec}" >"${ROOT27}/AGENTS.md"
  run_resolve "${ROOT27}"
  # 記録として採らないことを見る（docs/abs/ の実体は探索段が拾ってよい）
  case "$(kv ACE_PLAYBOOK_SOURCE)" in
    recorded:*) bad "K27: 記録 ${rec} を採った（rc=${RC} / $(kv ACE_PLAYBOOK_SOURCE)）" ;;
    *) ok "K27: 記録 ${rec##*/../} は候補に数えない（SOURCE=$(kv ACE_PLAYBOOK_SOURCE)）" ;;
  esac
done

# K28: --resolve-playbook の出力契約（unreadable の PATH・相対指定の REL・root 内外の判定・symlink・キーワード拒否）
run_with_env "${ROOT23}/no-such/PLAYBOOK.md" "${ROOT23}" --resolve-playbook
if [[ "${RC}" -eq 2 ]] && [[ "$(kv ACE_PLAYBOOK_STATE)" = "unreadable" ]] && [[ "$(kv ACE_PLAYBOOK)" = "${ROOT23}/no-such/PLAYBOOK.md" ]] && [[ -z "$(kv ACE_PLAYBOOK_REL)" ]]; then
  ok "K28: 読めない指定は rc=2 / STATE=unreadable で、名指しされたパスを出し REL は空"
else
  bad "K28: unreadable の出力契約（rc=${RC}）"; printf '%s\n' "${OUT}" | sed 's/^/    | /' >&2
fi
set +e
OUT="$(cd "${ROOT23}" && "${LOOKUP[@]}" --root "${ROOT23}" --resolve-playbook --playbook docs-template/08-knowledge/PLAYBOOK.md 2>/dev/null)"; RC=$?
set -e
if [[ "${RC}" -eq 0 ]] && [[ "$(kv ACE_PLAYBOOK_REL)" = "docs-template/08-knowledge/PLAYBOOK.md" ]]; then ok "K28: cwd 相対の --playbook も root 相対の REL を返す"; else bad "K28: 相対指定の REL（rc=${RC} / $(kv ACE_PLAYBOOK_REL)）"; fi
run_with_env "${ROOT27}/../outside/PLAYBOOK.md" "${ROOT27}" --resolve-playbook
if [[ "${RC}" -eq 0 ]] && [[ -z "$(kv ACE_PLAYBOOK_REL)" ]]; then ok "K28: root/../ 経由で外へ出る絶対パスは REL を出さない"; else bad "K28: root の外を REL として返した（$(kv ACE_PLAYBOOK_REL)）"; fi
run_with_env "${ROOT27}/docs/kb/PLAYBOOK.md" "${ROOT27}" --resolve-playbook
if [[ "${RC}" -eq 0 ]] && [[ -z "$(kv ACE_PLAYBOOK_REL)" ]]; then ok "K28: root の外を指す symlink ファイルは REL を出さない"; else bad "K28: 外を指す symlink を REL として返した（$(kv ACE_PLAYBOOK_REL)）"; fi
mkdir -p "${ROOT27}/docs/real"; cp "${TMP}/outside/PLAYBOOK.md" "${ROOT27}/docs/real/PLAYBOOK.md"; ln -s ../real/PLAYBOOK.md "${ROOT27}/docs/kb/IN.md"
run_with_env "${ROOT27}/docs/kb/IN.md" "${ROOT27}" --resolve-playbook
if [[ "${RC}" -eq 0 ]] && [[ "$(kv ACE_PLAYBOOK_REL)" = "docs/kb/IN.md" ]]; then ok "K28: root 内を指す symlink ファイルは REL を出す"; else bad "K28: root 内の symlink の REL（$(kv ACE_PLAYBOOK_REL)）"; fi
ln -s "${ROOT23}" "${TMP}/alias-root"
run_with_env "${TMP}/alias-root/docs-template/08-knowledge/PLAYBOOK.md" "${ROOT23}" --resolve-playbook
if [[ "${RC}" -eq 0 ]] && [[ "$(kv ACE_PLAYBOOK_REL)" = "docs-template/08-knowledge/PLAYBOOK.md" ]]; then ok "K28: symlink 経由の表記でも root 内の絶対パスは REL を出す"; else bad "K28: 表記差で root 内を外扱いした（$(kv ACE_PLAYBOOK_REL)）"; fi
run_lookup "${ROOT1}" --resolve-playbook hydration
if [[ "${RC}" -eq 1 ]]; then ok "K28: --resolve-playbook はキーワードを取らない（rc=1）"; else bad "K28: --resolve-playbook がキーワードを受け付けた（rc=${RC}）"; fi

# K29: ファイル名だけの指定でもカテゴリファイルを引く／非 ASCII を含む記録パスを途中で切らない
set +e
OUT="$(cd "${ROOT23}/docs-template/08-knowledge" && env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT -u FF_DEV_TOOLKIT_SKILL_FILE ACE_PLAYBOOK_PATH=PLAYBOOK.md bash "${TARGET}" --root "${ROOT23}" --offline hydration 2>&1)"; RC=$?
set -e
if [[ "${RC}" -eq 0 ]] && out_has "ACE-10-1" && out_has "== ACE Playbook（docs-template/08-knowledge/PLAYBOOK.md） =="; then
  ok "K29: ACE_PLAYBOOK_PATH=PLAYBOOK.md（ファイル名だけ）でも playbook/ のエントリを引く"
else
  bad "K29: ファイル名だけの指定でカテゴリファイルを引けない（rc=${RC}）"; printf '%s\n' "${OUT}" | grep -E '^(== ACE|RECORD)' | sed 's/^/    | /' >&2 || true
fi
ROOT29="${TMP}/recorded-non-ascii"; make_playbook "${TMP}/non-ascii-src"; mkdir -p "${ROOT29}/docs-template"
mv "${TMP}/non-ascii-src/docs/08-knowledge" "${ROOT29}/docs-template/知見"
printf '%s\n' 'SSOT は [PLAYBOOK](docs-template/知見/PLAYBOOK.md#id)（`docs-template/知見/PLAYBOOK.md`）。' >"${ROOT29}/AGENTS.md"
run_resolve "${ROOT29}"
if [[ "${RC}" -eq 0 ]] && [[ "$(kv ACE_PLAYBOOK_REL)" = "docs-template/知見/PLAYBOOK.md" ]] && [[ "$(kv ACE_PLAYBOOK_SOURCE)" = "recorded:AGENTS.md" ]]; then
  ok "K29: 非 ASCII を含む記録パスを途中で切らずに採る"
else
  bad "K29: 非 ASCII を含む記録パスを採れない（rc=${RC} / $(kv ACE_PLAYBOOK_STATE) / $(kv ACE_PLAYBOOK_REL)）"
fi

# K26: /ace-curate・/ace-refine が同じ resolver を呼び、検索と解決が同じ配置を返す（AC3）
for f in skills/ace-curate/SKILL.md skills/ace-refine/SKILL.md; do
  if grep -qF -- 'bash "${FF_DEV_TOOLKIT_ROOT}/scripts/knowledge-lookup.sh" --resolve-playbook' "${PLUGIN_ROOT}/${f}"; then
    ok "K26: ${f} は knowledge-lookup.sh --resolve-playbook で配置を解決する"
  else
    bad "K26: ${f} が共通 resolver（knowledge-lookup.sh --resolve-playbook）を呼んでいない"
  fi
done
if grep -qF -- '--resolve-playbook' "${PLUGIN_ROOT}/skills/ace-curate/references/curate.md"; then ok "K26: curate.md「配置先の解決」は共通 resolver を正本にする"; else bad "K26: curate.md が共通 resolver を参照していない"; fi
same_n=0
for r in "${ROOT22}" "${ROOT22m}" "${ROOT24p}" "${ROOT25d}" "${ROOT1}"; do
  run_resolve "${r}"; rel="$(kv ACE_PLAYBOOK_REL)"
  run_lookup "${r}" --offline zzz-no-such-word
  if [[ -n "${rel}" ]] && out_has "== ACE Playbook（${rel}） =="; then same_n=$((same_n + 1)); else bad "K26: ${r##*/} で検索と --resolve-playbook の配置が食い違う（resolve=${rel:-空}）"; fi
done
if [[ "${same_n}" -eq 5 ]]; then ok "K26: 5 fixture すべてで検索と --resolve-playbook が同じ配置を返す"; fi

echo ""
if [[ "${FAIL}" -eq 0 ]]; then
  echo "✓ knowledge-lookup verify: ${PASS} 件成功"
  finish 0
fi
echo "✗ knowledge-lookup verify: ${FAIL} 件失敗 / ${PASS} 件成功" >&2
finish 1
