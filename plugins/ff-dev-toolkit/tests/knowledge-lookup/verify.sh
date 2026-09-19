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
#   K18. live エントリが無い Playbook（全件 archive 済み）でも --include-archived で archive を返す
#   K16. gh が stdin を読み切ってもエントリが欠けない（read ループは fd 3・gh は `</dev/null` の
#        二重防御。片方を外しても欠けないため変異では赤にならない — 契約の固定であって検出力の
#        主張ではない）
#
# 空振り検出: 両 store を置かない root を与えると K6 が rc=2 を要求し、台帳の見出しを `### OBS 001 …`（コロン無し）へ変えると K7 が `読み取り失敗` を要求する（2026-09-19 実測。スクリプト側の noentry 判定を `empty` へ倒す変異で K7 が赤、両不在の rc=2 を rc=0 へ倒す変異で K6 が赤）。
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
#           赤転しなかった変異: gh の `</dev/null` を外す / read ループを fd 3 から stdin へ戻す
#           （単独でも両方でも K16 は緑 — stub が読むのは annotate_refs 内側の process substitution
#           で、外側のエントリ一覧ではない。防御として残すが検出力は主張しない）。
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
LOOKUP=(env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT -u FF_DEV_TOOLKIT_SKILL_FILE bash "${TARGET}")
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
if id_under_group "対策 Issue あり（promoted" "OBS-003"; then ok "K1: 台帳 promoted が対策 Issue ありグループに出る"; else bad "K1: OBS-003 が promoted グループに無い"; fi
if id_under_group "対策済み（mitigated" "OBS-005"; then ok "K1: 台帳 mitigated が対策済みグループに出る"; else bad "K1: OBS-005 が mitigated グループに無い"; fi
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

echo ""
if [[ "${FAIL}" -eq 0 ]]; then
  echo "✓ knowledge-lookup verify: ${PASS} 件成功"
  finish 0
fi
echo "✗ knowledge-lookup verify: ${FAIL} 件失敗 / ${PASS} 件成功" >&2
finish 1
