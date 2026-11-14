#!/usr/bin/env bash
# 空振り検出: 台帳の不在・見出しの ID 書式の変更・全件のメタ不正・同じ ID の重複・適用前エントリ 0 件・閾値の正本の欠落と重複・Issue 一覧の 0 行と上限到達・一部だけ未確認の一覧は R3 / R3b / R4 / R7 / R8 / C3 / C4 が rc=2 または `未確認` / `partial` を要求する。隔離コピーへの 29 変異（空振りの側: 全件メタ不正でも続行・閾値を導出できない回に 3 へ倒す・適用前 0 件を通す・上限到達と 0 行の一覧を ok と読む・フェンス内の記入例を数える・一覧なしを「候補なし」と書く・一部未確認を ok と書く・同じ ID の重複を通す・月の日数を検査しない。検出したい状態の側: 行の消失を見ない・足された行の種類を見ない・stale の境界を「以上」にする・Issue 列の埋まった active を黙って落とす／統合へ入れる／上書きを通す・Kind の違う組を出す／統合の Kind を照合しない・重みを log(N/df) へ戻す・閾値到達の件数を数えない・Count の数値検査を外す・統合元を 1 件目しか合算しない・名指しを前方一致で通す・セルを足したメタ行を正規化する・problem の mitigated を通す・メモだけの追記を通す・統合先でないエントリの Last の変更を通す・過去の整理をまたぐ連鎖を通す・過去の統合先の印を出さない）は各 rc=1、正常対照 164 件成功（2026-11-13 macOS /bin/bash 3.2 実測。gawk 5.4.1 でも 164 件成功）。見出しの階層ごと変わった台帳（全エントリが `####`）と、本文の閉じていないコードフェンスは knowledge-lookup.sh の既存の読み出しがエントリを認識できず、report は rc=0 のまま件数が減る — 本 suite の対象外（check は自前の認識で、エントリ 0 件を rc=2 にする）。
#
# scripts/observation-refine.sh（観測台帳の定期整理: 候補の算出と適用後の照合）の振る舞い検査（Issue `#2523`）。
#
# スキル observation-refine は dry-run → 承認 → 適用の 3 段で台帳の閾値未達エントリを整理する。
# 機械が受け持つのは 2 つで、どちらも動かさないと測れない:
#   report … 規則で決まる候補（stale・母集団・閾値到達）と、類似の信号（紐付け・統合）を出す。
#            台帳は書き換えない
#   check  … 適用が履歴を消していないこと（足されたのは状態移行の観測メモだけ・変わったのは
#            メタ行だけ・Count の合算が合っている）を適用前後の台帳から照合する
# 本 suite は合成の台帳 fixture（実在する導入先の台帳は写さない — 公開同期の対象に置くため）で
# 両方を実際に走らせ、節ごとの候補・SUMMARY 行・NG 行・終了コードを照合する。
#
# 検査:
#   D1.  knowledge-lookup.sh --ledger-dump が全エントリ（archived を含む）を 10 列で出し、フェンス内の
#        記入例を数えない。台帳が無い回は rc=2
#   R1.  既定の dry-run: 5 節の候補と SUMMARY 行（件数まで）。active なのに Issue 列が埋まっているエントリの名指し。stale は「日数を超え」の境界
#        （180 日ちょうどは対象外・181 日は対象）と Count の上限、archived の除外、閾値到達の振り分け
#   R2.  --stale-max-count / --stale-days で stale の基準が変わる
#   R3.  Issue 一覧: 渡さない・上限到達・0 行はいずれも `未確認`（候補なしへ倒さない）。書式不正は rc=2
#   R4.  針が当たらない入力: 台帳の不在・見出し書式の変更・全件のメタ不正は rc=2。一部のメタ不正は
#        候補から外して名指しする
#   R5.  read-only: dry-run の前後で台帳のバイトと fixture のファイル数が変わらない
#   R6.  引数エラーは rc=64、基準日を読めない回は rc=2
#   R7.  昇格閾値は /retrospective の SKILL.md から導出し、導出できない（0 種類・2 種類）回は rc=2
#   R8.  統合の母集団（active × promoted は出す・archived / Issue 列の埋まった active / Kind の違う組は出さない）、
#        2 件だけの台帳・エントリ 0 件の台帳、メタ不正の名指し、同じ ID の重複（rc=2）
#   R3b. Issue 一覧が複数ある回の帰属と partial、--top / --max-pairs / 最小スコアの効き
#   C1.  4 種の操作を正しく当てた台帳は rc=0。CHECK 行の件数と、閾値到達の THRESHOLD 行
#   C2.  違反 16 形はそれぞれ rc=1 で、理由を名指す NG 行が出る
#   C4.  複数の統合元・統合先自身の First / Last が残る向き・既定以外の台帳パスは rc=0。Kind の書き換え・
#        値域外の Status・統合の連鎖（過去の整理をまたぐものを含む）・既存の Issue 参照の上書きなど 18 形は rc=1
#   C3.  適用前の不在・エントリ 0 件は rc=2。無変更は rc=0
#   S1.  スキル本文の既定値・起動行・状態移行の書き出しが、スクリプトの実体と一致する
#
# 依存: bash・awk・mktemp・cksum・find。通信しない（gh を呼ばない）。fixture の置き場は読み取り境界の
# ff_knowledge_job_directory で作る（台帳の読み出しが境界の検査を通る場所である必要がある）。作れない
# 環境では skip せず赤で終わる。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TARGET="${PLUGIN_ROOT}/scripts/observation-refine.sh"
LOOKUP_TARGET="${PLUGIN_ROOT}/scripts/knowledge-lookup.sh"
SKILL="${PLUGIN_ROOT}/skills/observation-refine/SKILL.md"
APPLY_DOC="${PLUGIN_ROOT}/skills/observation-refine/references/apply.md"
LEDGER_DOC="${PLUGIN_ROOT}/skills/retrospective/references/ledger.md"
CHECK_AWK="${PLUGIN_ROOT}/scripts/lib/observation-refine-check.awk"

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

echo "== observation-refine: 候補の算出と適用後の照合 =="

for f in "${TARGET}" "${LOOKUP_TARGET}" "${SKILL}" "${APPLY_DOC}" "${LEDGER_DOC}" "${CHECK_AWK}"; do
  if [[ ! -f "${f}" ]]; then
    bad "対象が見つかりません: ${f}"
    echo "✗ observation-refine verify: 1 件失敗 / 0 件成功" >&2
    exit 1
  fi
done

if ! TMP="$(bash -c '. "$1"; ff_knowledge_job_directory observation-refine-suite' _ "${PLUGIN_ROOT}/scripts/lib/knowledge-read-boundary.sh")" || [[ ! -d "${TMP}" ]]; then
  bad "fixture の置き場を作れません（上の knowledge-read: 行が理由。検査は 1 件も実行されていません）"
  echo "✗ observation-refine verify: 1 件失敗 / 0 件成功" >&2
  exit 1
fi
FINISHED=0
cleanup() {
  local rc=$?
  rm -rf "${TMP}"
  if [[ "${FINISHED}" -ne 1 ]]; then
    echo "✗ observation-refine verify: suite が途中で終了しました（rc=${rc}）" >&2
    exit 1
  fi
  exit "${rc}"
}
trap cleanup EXIT
finish() { FINISHED=1; exit "$1"; }

# plugin root の handoff を継承したまま作業ツリーの実体を叩くと、script 側の root ガードが
# 「別の実体」として止める。検査対象は作業ツリーの実体なので handoff を外して呼ぶ。
ISOLATE=(env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT -u FF_DEV_TOOLKIT_SKILL_FILE)
OUT="${TMP}/out"; ERR="${TMP}/err"; RC=0
run() { RC=0; "${ISOLATE[@]}" bash "${TARGET}" "$@" >"${OUT}" 2>"${ERR}" || RC=$?; }
run_at() { local script="$1"; shift; RC=0; "${ISOLATE[@]}" bash "${script}" "$@" >"${OUT}" 2>"${ERR}" || RC=$?; }

expect_rc() { # <label> <expected>
  if [[ "${RC}" -eq "$2" ]]; then ok "$1（rc=$2）"; else bad "$1: rc=${RC}（期待 $2）$(head -n 3 "${ERR}" | tr '\n' ' ')"; fi
}
expect_line() { # <label> <file> <行全体>
  if grep -qxF -- "$3" "$2"; then ok "$1"; else bad "$1: 行が無い — $3"; fi
}
expect_has() { # <label> <file> <部分文字列>
  if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1: 見つからない — $3"; fi
}
expect_not() { # <label> <file> <部分文字列>
  if grep -qF -- "$3" "$2"; then bad "$1: 出てはいけない — $3"; else ok "$1"; fi
}
# 節（`-- (N) ` の見出しから次の `-- (` の手前まで）を切り出す
section() { # <N> <file> → stdout
  awk -v n="$1" 'index($0, "-- (" n ") ") == 1 { p = 1; print; next } p && index($0, "-- (") == 1 { exit } p' "$2"
}

# ── fixture: 合成の台帳（15 件 + フェンス内の記入例 1 件）─────────────────────
ROOT="${TMP}/repo"
mkdir -p "${ROOT}/docs/08-knowledge"
LEDGER="${ROOT}/docs/08-knowledge/OBSERVATIONS.md"
cat >"${LEDGER}" <<'LEDGER_EOF'
# 振り返り観測台帳（fixture）

## エントリ形式

```markdown
<a id="obs-XXX"></a>

### OBS-XXX: [記入例。フェンスの中なのでエントリに数えない]

| Kind | problem | Count | 1 |
| First | 2026-01-01 | Last | 2026-01-01 |
| Status | active | Issue | なし |

- 2026-01-01: 記入例（初回）

---
```

## エントリ一覧

<a id="obs-001"></a>

### OBS-001: alpha-widget の再読込を忘れると zeta-cache が古い値を返す → 起動前に reload-widget を実行せよ

| Kind | problem | Count | 1 |
| First | 2026-01-10 | Last | 2026-01-10 |
| Status | active | Issue | なし |

alpha-widget は設定の変更を自動で拾わない。

- 2026-01-10: zeta-cache の古い値で 1 回やり直した（初回）

---

<a id="obs-002"></a>

### OBS-002: beta-runner の既定タイムアウトは kappa-suite に足りない → 長い走行は時間を明示せよ

| Kind | problem | Count | 2 |
| First | 2025-12-20 | Last | 2026-01-10 |
| Status | active | Issue | なし |

beta-runner は既定の時間で打ち切る。

- 2025-12-20: kappa-suite が打ち切られた（初回）
- 2026-01-10: 同じ打ち切りを踏んだ

---

<a id="obs-003"></a>

### OBS-003: gamma-linter の警告を放置すると theta-build が遅くなる → 警告は同じ回で直せ

| Kind | problem | Count | 1 |
| First | 2026-05-17 | Last | 2026-05-17 |
| Status | active | Issue | なし |

gamma-linter の警告は積もると解析時間を伸ばす。

- 2026-05-17: theta-build が倍の時間になった（初回）

---

<a id="obs-004"></a>

### OBS-004: delta-export の出力先を確かめないと iota-report が上書きされる → 出力先を先に表示せよ

| Kind | problem | Count | 1 |
| First | 2026-05-16 | Last | 2026-05-16 |
| Status | active | Issue | なし |

delta-export は既定の出力先へ黙って書く。

- 2026-05-16: iota-report を 1 回失った（初回）

---

<a id="obs-005"></a>

### OBS-005: lambda-checklist を着手前に読むと epsilon-setup の漏れが出ない

| Kind | keep | Count | 1 |
| First | 2026-11-01 | Last | 2026-11-01 |
| Status | active | Issue | なし |

lambda-checklist は着手前の確認項目を並べている。

- 2026-11-01: epsilon-setup を漏れなく終えた（初回）

---

<a id="obs-006"></a>

### OBS-006: mu-template から始めると upsilon-review の指摘が減る

| Kind | keep | Count | 3 |
| First | 2026-10-01 | Last | 2026-11-02 |
| Status | active | Issue | なし |

mu-template は必須の節を最初から持っている。

- 2026-10-01: upsilon-review の指摘が 0 件だった（初回）
- 2026-10-15: 同じく 0 件
- 2026-11-02: 同じく 0 件

---

<a id="obs-007"></a>

### OBS-007: nu-parser は空行で phi-token を落とす → 入力の空行を先に除け

| Kind | problem | Count | 4 |
| First | 2026-08-01 | Last | 2026-10-30 |
| Status | promoted | Issue | feel-flow/ff-dev-toolkit#12 |

nu-parser は空行を区切りとして読む。

- 2026-08-01: phi-token が欠けた（初回）
- 2026-09-01: 同じ欠落
- 2026-10-01: 同じ欠落
- 2026-10-30: 同じ欠落

---

<a id="obs-008"></a>

### OBS-008: xi-deploy の前に chi-snapshot を取らないと戻せない → 反映の前に必ず取れ

| Kind | problem | Count | 2 |
| First | 2026-07-01 | Last | 2026-08-20 |
| Status | mitigated | Issue | skill:demo-skill |

xi-deploy は戻す手段を自分では持たない。

- 2026-07-01: 戻せずに作り直した（初回）
- 2026-08-20: chi-snapshot を取り忘れた

---

<a id="obs-009"></a>

### OBS-009: review-output-dir の private-mode 検査で legacy-results が残ると orbit-launcher が起動前に中断する

| Kind | problem | Count | 2 |
| First | 2026-09-01 | Last | 2026-10-20 |
| Status | active | Issue | なし |

orbit-launcher は legacy-results の private-mode を起動前に検査する。

- 2026-09-01: 起動前に中断した（初回）
- 2026-10-20: 同じ中断

---

<a id="obs-010"></a>

### OBS-010: orbit-launcher は legacy-results の private-mode 検査で止まり review-output-dir を変えても中断する

| Kind | problem | Count | 1 |
| First | 2026-08-15 | Last | 2026-11-05 |
| Status | active | Issue | なし |

review-output-dir を移しても legacy-results の検査は残る。

- 2026-11-05: 出力先を変えても中断した（初回）

---

<a id="obs-011"></a>

### OBS-011: quartz-indexer の rebuild-shard が stale-manifest を読み nebula-export が空になる

| Kind | problem | Count | 1 |
| First | 2026-11-03 | Last | 2026-11-03 |
| Status | active | Issue | なし |

rebuild-shard は stale-manifest の有無を確かめない。

- 2026-11-03: nebula-export が空のまま配られた（初回）

---

<a id="obs-012"></a>

### OBS-012: omicron-sync を二重に起動すると psi-lock が残る → 起動の前に psi-lock を確かめよ

| Kind | problem | Count | 1 |
| First | 2025-06-01 | Last | 2025-06-01 |
| Status | archived | Issue | なし |

omicron-sync は psi-lock を自分で片付けない。

- 2025-06-01: psi-lock が残って止まった（初回）
- 2026-01-05: 状態移行（再発ではない）。archived（Last から 218 日再発なし）

---

<a id="obs-013"></a>

### OBS-013: 全件ゲートを部分再検証と並走させると走行結果が無効になる

| Kind | problem | Count | 1 |
| First | 2026-11-06 | Last | 2026-11-06 |
| Status | active | Issue | なし |

並走の途中で作業ツリーが変わる。

- 2026-11-06: 走行結果を捨てた（初回）

---

<a id="obs-014"></a>

### OBS-014: 全件ゲートと部分再検証を同じ場所で並走させると走行結果がやり直しになる

| Kind | problem | Count | 1 |
| First | 2026-11-07 | Last | 2026-11-07 |
| Status | active | Issue | なし |

並走の片方が書き込むと他方の前提が崩れる。

- 2026-11-07: 走行結果をやり直した（初回）

---

<a id="obs-015"></a>

### OBS-015: rho-migrate を途中で止めると pi-schema が半端に残る → 完了を確かめてから次へ進め

| Kind | problem | Count | 1 |
| First | 2026-11-08 | Last | 2026-11-08 |
| Status | active | Issue | feel-flow/ff-dev-toolkit#43 |

rho-migrate は中断の後始末をしない。

- 2026-11-08: pi-schema を手で戻した（初回）

---
LEDGER_EOF

ISSUES="${TMP}/issues-public.tsv"
printf '%s\t%s\t%s\n' \
  12 OPEN "fix: nu-parser の空行の扱い" \
  40 CLOSED "fix: quartz-indexer の rebuild-shard が stale-manifest を読んで nebula-export が空になる" \
  41 OPEN "docs: sigma-readme の導入手順を更新" \
  42 OPEN "feat: omega-panel へ絞り込みを追加" \
  43 CLOSED "chore: tau-lint の設定を整理" >"${ISSUES}"
TODAY=2026-11-13

# ── D1: --ledger-dump ───────────────────────────────────────────────────────
run_at "${LOOKUP_TARGET}" --ledger-dump --root "${ROOT}"
expect_rc "D1: --ledger-dump が台帳を出す" 0
expect_line "D1: SUMMARY 行（件数はフェンス内の記入例を数えない 15）" "${OUT}" "SUMMARY ledger=docs/08-knowledge/OBSERVATIONS.md entries=15 state=ok"
dump_shape="$(awk -F '\t' '/^SUMMARY /{ next } { rows++; if (NF != 10) badcols++; if ($1 == "OBS-012" && $2 == "archived") arch++; if ($1 == "OBS-XXX") ex++ } END { printf "%d %d %d %d", rows, badcols + 0, arch + 0, ex + 0 }' "${OUT}")"
if [[ "${dump_shape}" == "15 0 1 0" ]]; then ok "D1: 15 行・全行 10 列・archived を含む・記入例を含まない"; else bad "D1: 出力の形が期待と違う（rows badcols archived example = ${dump_shape}）"; fi
dump_row="$(awk -F '\t' '$1 == "OBS-007" { printf "%s|%s|%s|%s|%s|%s|%s", $2, $3, $4, $5, $6, $7, $8 }' "${OUT}")"
if [[ "${dump_row}" == "promoted|problem|4|2026-08-01|2026-10-30|feel-flow/ff-dev-toolkit#12|docs/08-knowledge/OBSERVATIONS.md#obs-007" ]]; then ok "D1: メタ 6 欄と location の列位置"; else bad "D1: OBS-007 の列が期待と違う — ${dump_row}"; fi
EMPTY_ROOT="${TMP}/empty-root"; mkdir -p "${EMPTY_ROOT}"
run_at "${LOOKUP_TARGET}" --ledger-dump --root "${EMPTY_ROOT}"
expect_rc "D1: 台帳が無い root は判定不能" 2

# ── R1: 既定の dry-run ──────────────────────────────────────────────────────
ledger_sum_before="$(cksum <"${LEDGER}")"
files_before="$(find "${ROOT}" -type f | awk 'END { print NR }')"
run report --root "${ROOT}" --today "${TODAY}" --issues "feel-flow/ff-dev-toolkit=${ISSUES}"
expect_rc "R1: 既定の dry-run" 0
expect_line "R1: 対象の内訳" "${OUT}" "対象: 15 件（active 12 / promoted 1 / mitigated 1 / archived 1）"
expect_line "R1: 基準の表示（閾値は retrospective から導出した 3）" "${OUT}" "基準日: 2026-11-13 / stale = Last から 180 日を超え、かつ Count が 1 以下 / 昇格閾値 = 累計 3 回"
expect_line "R1: SUMMARY 行" "${OUT}" "SUMMARY entries=15 active=12 link_population=11 link_candidates=1 merge_pairs=2 merge_reach_threshold=1 stale=2 keep_population=1 threshold_unlinked=1 meta_invalid=0 active_linked=1 issues=ok today=2026-11-13 stale_days=180 stale_max_count=1 threshold=3"
section 1 "${OUT}" >"${TMP}/s1"; section 2 "${OUT}" >"${TMP}/s2"; section 3 "${OUT}" >"${TMP}/s3"; section 4 "${OUT}" >"${TMP}/s4"; section 5 "${OUT}" >"${TMP}/s5"
expect_line "R1 (1): 照合先の件数" "${TMP}/s1" "照合先: feel-flow/ff-dev-toolkit = 5 件（open 3 / closed 2）"
expect_has "R1 (1): OBS-011 に同じ事象の Issue が候補として出る" "${TMP}/s1" "feel-flow/ff-dev-toolkit#40(closed)"
expect_not "R1 (1): 無関係な Issue は候補に出ない" "${TMP}/s1" "feel-flow/ff-dev-toolkit#41"
expect_line "R1 (1): 候補に出なかった件数を「確認ではない」と明示する" "${TMP}/s1" "類似の候補なし: 10 件（機械の信号に出ないだけで、対応 Issue が無いことの確認ではない）"
expect_line "R1 (1): 候補に出なかったエントリを ID で名指しする" "${TMP}/s1" "      OBS-001 OBS-002 OBS-003 OBS-004 OBS-005 OBS-006 OBS-009 OBS-010 OBS-013 OBS-014"
expect_line "R1: active なのに Issue 列が埋まっているエントリを別に名指しする" "${OUT}" "-- 状態と Issue 列が食い違うエントリ: 1 件（active なのに Issue 列がある。どの母集団にも入れていない。/retrospective の状態移行で Status を直す）--"
expect_has "R1: 食い違うエントリの ID と Issue 列" "${OUT}" "Kind=problem Count=1 Last=2026-11-08 Issue=feel-flow/ff-dev-toolkit#43"
expect_not "R1 (1): 食い違うエントリは紐付けの母集団に入らない" "${TMP}/s1" "OBS-015"
expect_has "R1 (2): 同じ主張の組（ASCII の語）と合算での閾値到達" "${TMP}/s2" "合算 Count=3（採れば合算で昇格閾値に到達）"
if grep -qE '^OBS-009 × OBS-010  ' "${TMP}/s2"; then ok "R1 (2): OBS-009 × OBS-010"; else bad "R1 (2): OBS-009 × OBS-010 が組に出ない"; fi
if grep -qE '^OBS-013 × OBS-014  ' "${TMP}/s2"; then ok "R1 (2): 日本語だけで共通する組（OBS-013 × OBS-014）"; else bad "R1 (2): OBS-013 × OBS-014 が組に出ない"; fi
expect_line "R1 (3): 見出しの件数" "${TMP}/s3" "-- (3) stale の archive: 2 件 --"
expect_has "R1 (3): 307 日前の Count 1" "${TMP}/s3" "Last=2026-01-10（307 日前）"
expect_has "R1 (3): 181 日前は対象" "${TMP}/s3" "Last=2026-05-16（181 日前）"
expect_not "R1 (3): Count 2 は既定の対象外" "${TMP}/s3" "OBS-002"
expect_not "R1 (3): 180 日ちょうどは「超え」ていない" "${TMP}/s3" "OBS-003"
expect_has "R1 (4): 閾値未達の Keep" "${TMP}/s4" "OBS-005"
expect_not "R1 (4): 閾値到達の Keep は定着判定の母集団に入れない" "${TMP}/s4" "OBS-006"
expect_has "R1 (5): 閾値到達・未リンクは昇格判定へ" "${TMP}/s5" "OBS-006"
expect_not "R1: archived のエントリはどの節にも出ない" "${OUT}" "OBS-012"
expect_not "R1: promoted のエントリは母集団に入らない" "${TMP}/s1" "OBS-007"
# R5: read-only
if [[ "$(cksum <"${LEDGER}")" == "${ledger_sum_before}" ]] && [[ "$(find "${ROOT}" -type f | awk 'END { print NR }')" == "${files_before}" ]]; then
  ok "R5: dry-run は台帳を書き換えず、対象リポジトリにファイルを作らない"
else
  bad "R5: dry-run の前後で台帳またはファイル数が変わった"
fi

# ── R2: stale の基準は設定値 ────────────────────────────────────────────────
run report --root "${ROOT}" --today "${TODAY}" --stale-max-count 2
expect_rc "R2: --stale-max-count 2" 0
section 3 "${OUT}" >"${TMP}/s3"
expect_line "R2: Count 2 まで広げると 3 件" "${TMP}/s3" "-- (3) stale の archive: 3 件 --"
expect_has "R2: Count 2 のエントリが入る" "${TMP}/s3" "OBS-002"
run report --root "${ROOT}" --today "${TODAY}" --stale-days 179
section 3 "${OUT}" >"${TMP}/s3"
expect_has "R2: --stale-days 179 で 180 日前が対象に入る" "${TMP}/s3" "OBS-003"
run report --root "${ROOT}" --today "${TODAY}" --stale-days 400
section 3 "${OUT}" >"${TMP}/s3"
expect_line "R2: --stale-days 400 は 0 件" "${TMP}/s3" "-- (3) stale の archive: 0 件 --"

# ── R3: Issue 一覧の不足は「未確認」 ─────────────────────────────────────────
run report --root "${ROOT}" --today "${TODAY}"
expect_rc "R3: Issue 一覧なし" 0
expect_line "R3: 渡さない回は未確認と書く" "${OUT}" "照合: 未確認（Issue 一覧が渡されていない。--issues owner/repo=<一覧ファイル> を付けて取り直す）"
expect_has "R3: SUMMARY は候補 0" "${OUT}" "link_population=11 link_candidates=0 "
expect_has "R3: SUMMARY は issues=none" "${OUT}" " active_linked=1 issues=none today="
expect_not "R3: 一覧が無い回に「候補なし」と断定しない" "${OUT}" "類似の候補なし"
run report --root "${ROOT}" --today "${TODAY}" --issues "feel-flow/ff-dev-toolkit=${ISSUES}" --issues-limit 5
expect_rc "R3: 上限到達" 0
expect_line "R3: 上限に達した一覧は未確認" "${OUT}" "照合先: feel-flow/ff-dev-toolkit = 未確認（一覧が上限 5 件に達している（打ち切りの可能性））"
expect_has "R3: 上限到達は issues=unverified" "${OUT}" " issues=unverified "
: >"${TMP}/issues-empty.tsv"
run report --root "${ROOT}" --today "${TODAY}" --issues "feel-flow/ff-dev-toolkit=${TMP}/issues-empty.tsv"
expect_line "R3: 0 行の一覧は未確認" "${OUT}" "照合先: feel-flow/ff-dev-toolkit = 未確認（一覧が 0 行（取得失敗と区別できない））"
printf '%s\n' "40 CLOSED 区切りがタブではない" >"${TMP}/issues-bad.tsv"
run report --root "${ROOT}" --today "${TODAY}" --issues "feel-flow/ff-dev-toolkit=${TMP}/issues-bad.tsv"
expect_rc "R3: 書式不正の一覧は判定不能" 2
run report --root "${ROOT}" --today "${TODAY}" --issues "feel-flow/ff-dev-toolkit=${TMP}/no-such-file.tsv"
expect_rc "R3: 読めない一覧は判定不能" 2

# ── R3b: Issue 一覧が複数ある回と、絞り込みの引数 ─────────────────────────────
OTHER_ISSUES="${TMP}/issues-other.tsv"
printf '%s\t%s\t%s\n' \
  7 OPEN "docs: zeta-notes の索引を整理" \
  8 CLOSED "fix: eta-loader の再試行を 1 回にする" >"${OTHER_ISSUES}"
run report --root "${ROOT}" --today "${TODAY}" --issues "feel-flow/ff-dev-toolkit=${ISSUES}" --issues "feel-flow/ai-spec-driven-development=${OTHER_ISSUES}"
expect_rc "R3b: 一覧 2 本（どちらも照合できる）" 0
section 1 "${OUT}" >"${TMP}/s1"
expect_line "R3b: 2 本目の照合先の件数" "${TMP}/s1" "照合先: feel-flow/ai-spec-driven-development = 2 件（open 1 / closed 1）"
expect_has "R3b: 候補は 1 本目のリポジトリの Issue として出る（一覧の取り違えが無い）" "${TMP}/s1" "feel-flow/ff-dev-toolkit#40(closed)"
expect_not "R3b: 2 本目のリポジトリの番号で出ない" "${TMP}/s1" "feel-flow/ai-spec-driven-development#40"
expect_has "R3b: 全部照合できた回は issues=ok" "${OUT}" " issues=ok today="
run report --root "${ROOT}" --today "${TODAY}" --issues "feel-flow/ff-dev-toolkit=${ISSUES}" --issues "feel-flow/ai-spec-driven-development=${TMP}/issues-empty.tsv"
expect_rc "R3b: 一覧 2 本（片方が 0 行）" 0
expect_has "R3b: 一部だけ未確認の回は issues=partial（ok と書かない）" "${OUT}" " issues=partial today="
expect_line "R3b: 未確認の照合先を名指す" "${OUT}" "照合先: feel-flow/ai-spec-driven-development = 未確認（一覧が 0 行（取得失敗と区別できない））"

TOP_ISSUES="${TMP}/issues-top.tsv"
{ cat "${ISSUES}"; printf '%s\t%s\t%s\n' 44 OPEN "fix: quartz-indexer の rebuild-shard が stale-manifest を読む前に nebula-export を止める"; } >"${TOP_ISSUES}"
run report --root "${ROOT}" --today "${TODAY}" --issues "feel-flow/ff-dev-toolkit=${TOP_ISSUES}"
section 1 "${OUT}" >"${TMP}/s1"
top_default="$(grep -c '^      類似 ' "${TMP}/s1" || true)"
run report --root "${ROOT}" --today "${TODAY}" --issues "feel-flow/ff-dev-toolkit=${TOP_ISSUES}" --top 1
section 1 "${OUT}" >"${TMP}/s1"
top_one="$(grep -c '^      類似 ' "${TMP}/s1" || true)"
if [[ "${top_default}" -eq 2 && "${top_one}" -eq 1 ]]; then ok "R3b: --top 1 で 1 エントリの候補が 2 件から 1 件へ減る"; else bad "R3b: --top の効きが違う（既定 ${top_default} 件 / --top 1 で ${top_one} 件。期待 2 / 1）"; fi
expect_line "R3b: 隠した候補の件数を名指す" "${TMP}/s1" "      ほか 1 件（--top で増やせる）"
run report --root "${ROOT}" --today "${TODAY}" --issues "feel-flow/ff-dev-toolkit=${TOP_ISSUES}" --min-link-score 0.99
expect_has "R3b: --min-link-score を上げると候補が消える" "${OUT}" " link_candidates=0 "
run report --root "${ROOT}" --today "${TODAY}" --max-pairs 0
expect_line "R3b: --max-pairs 0 は組を表示せず、全数と打ち切りを名指す" "${OUT}" "-- (2) 統合（同じ主張の疑い）: 2 組（上位 0 組を表示。--max-pairs で増やせる） --"
expect_has "R3b: 閾値到達の件数は表示の上限と無関係に全数" "${OUT}" " merge_pairs=2 merge_reach_threshold=1 "
run report --root "${ROOT}" --today "${TODAY}" --min-merge-score 0.99
expect_has "R3b: --min-merge-score を上げると組が消える" "${OUT}" " merge_pairs=0 merge_reach_threshold=0 "

# ── R4: 針が当たらない入力 ──────────────────────────────────────────────────
run report --root "${EMPTY_ROOT}" --today "${TODAY}"
expect_rc "R4: 台帳の不在は判定不能" 2
mkdir -p "${TMP}/heading/docs/08-knowledge" "${TMP}/allbad/docs/08-knowledge" "${TMP}/onebad/docs/08-knowledge"
sed 's/^### OBS-/### OBS /' "${LEDGER}" >"${TMP}/heading/docs/08-knowledge/OBSERVATIONS.md"
run report --root "${TMP}/heading" --today "${TODAY}"
expect_rc "R4: 見出し書式が変わった台帳は判定不能（0 件の緑にしない）" 2
sed 's/^| Kind | \([a-z]*\) | Count | [0-9]* |$/| Kind | \1 | Count | many |/' "${LEDGER}" >"${TMP}/allbad/docs/08-knowledge/OBSERVATIONS.md"
run report --root "${TMP}/allbad" --today "${TODAY}"
expect_rc "R4: 全件のメタ行を読めない台帳は判定不能" 2
awk '/^### OBS-004:/ { hit = 1 } hit && /^\| First \|/ { print "| First | 2026-05-16 | Last | 5 月 16 日 |"; hit = 0; next } { print }' "${LEDGER}" >"${TMP}/onebad/docs/08-knowledge/OBSERVATIONS.md"
run report --root "${TMP}/onebad" --today "${TODAY}"
expect_rc "R4: 一部のメタ不正は続行" 0
expect_line "R4: 読めないエントリを名指しで外す" "${OUT}" "-- メタ行を読めないエントリ: 1 件（候補から外した。先に書式を直す）--"
expect_has "R4: SUMMARY に meta_invalid=1・stale は 1 件へ減る" "${OUT}" " stale=1 keep_population=1 threshold_unlinked=1 meta_invalid=1 "

# ── R6: 引数エラーと基準日 ──────────────────────────────────────────────────
run
expect_rc "R6: サブコマンドなし" 64
run report --root "${ROOT}" --no-such-option
expect_rc "R6: 未知のオプション" 64
run report --root "${ROOT}" --stale-days many
expect_rc "R6: 数値でない --stale-days" 64
run report --root "${ROOT}" --issues "feel-flow-ff-dev-toolkit=${ISSUES}"
expect_rc "R6: owner/repo の形でない --issues" 64
run report --root "${ROOT}" --today 11/13
expect_rc "R6: 形式の違う基準日は判定不能" 2
run report --root "${ROOT}" --today 2026-13-40
expect_rc "R6: 暦に無い基準日は判定不能" 2
run report --root "${ROOT}" --today 2026-02-31
expect_rc "R6: 月の日数を超える基準日（2 月 31 日）は判定不能（別の日へずらして読まない）" 2

# ── R7: 昇格閾値の導出（隔離コピーで正本を変える）────────────────────────────
COPY="${TMP}/plugin-copy"
mkdir -p "${COPY}/scripts" "${COPY}/skills/retrospective" "${COPY}/.claude-plugin"
cp "${PLUGIN_ROOT}/scripts/observation-refine.sh" "${PLUGIN_ROOT}/scripts/knowledge-lookup.sh" "${COPY}/scripts/"
cp -R "${PLUGIN_ROOT}/scripts/lib" "${COPY}/scripts/lib"
cp "${PLUGIN_ROOT}/.claude-plugin/plugin.json" "${COPY}/.claude-plugin/plugin.json"
cp "${PLUGIN_ROOT}/skills/retrospective/SKILL.md" "${COPY}/skills/retrospective/SKILL.md"
run_at "${COPY}/scripts/observation-refine.sh" report --root "${ROOT}" --today "${TODAY}"
expect_rc "R7: 隔離コピーの正常対照" 0
expect_has "R7: 正常対照は閾値 3 を導出する" "${OUT}" " threshold=3"
sed 's/累計 3 回/累計 三 回/' "${PLUGIN_ROOT}/skills/retrospective/SKILL.md" >"${COPY}/skills/retrospective/SKILL.md"
if grep -qF '累計 3 回' "${COPY}/skills/retrospective/SKILL.md"; then bad "R7: 変異（閾値の表記を消す）が当たっていない"; else
  run_at "${COPY}/scripts/observation-refine.sh" report --root "${ROOT}" --today "${TODAY}"
  expect_rc "R7: 閾値の表記が無い正本では判定不能（既定値へ倒さない）" 2
fi
{ cat "${PLUGIN_ROOT}/skills/retrospective/SKILL.md"; printf '%s\n' "別の節では累計 5 回と書いてある。"; } >"${COPY}/skills/retrospective/SKILL.md"
run_at "${COPY}/scripts/observation-refine.sh" report --root "${ROOT}" --today "${TODAY}"
expect_rc "R7: 閾値が 2 種類ある正本では判定不能" 2
rm -f "${COPY}/skills/retrospective/SKILL.md"
run_at "${COPY}/scripts/observation-refine.sh" check --before "${LEDGER}" --after "${LEDGER}"
expect_rc "R7: 正本が無い回は check も判定不能" 2

# ── C: 適用後の照合 ─────────────────────────────────────────────────────────
# 適用の道具: エントリごとにメタの値を差し替え、観測メモの末尾へ行を足す（apply.md の書式）。
# set / note は `ID<US>キー<US>値` を RS（0x1e）で並べた文字列で渡す。
cat >"${TMP}/apply.awk" <<'APPLY_EOF'
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
BEGIN {
  n = split(sets, items, "\036")
  for (i = 1; i <= n; i++) { if (items[i] == "") continue; split(items[i], p, "\037"); SET[p[1], p[2]] = p[3] }
  n = split(notes, items, "\036")
  for (i = 1; i <= n; i++) { if (items[i] == "") continue; split(items[i], p, "\037"); NOTE[p[1]] = NOTE[p[1]] p[2] "\n" }
}
/^[ \t]*```/ { infence = !infence }
!infence && /^### OBS-/ { id = $2; sub(/:$/, "", id) }
!infence && id != "" && /^\| / {
  nf = split($0, f, "|")
  k1 = trim(f[2]); v1 = trim(f[3]); k2 = trim(f[4]); v2 = trim(f[5])
  if ((id, k1) in SET) v1 = SET[id, k1]
  if ((id, k2) in SET) v2 = SET[id, k2]
  print "| " k1 " | " v1 " | " k2 " | " v2 " |"
  prevmemo = 0
  next
}
!infence && id != "" && $0 == "" && prevmemo && (id in NOTE) { printf "%s", NOTE[id]; delete NOTE[id] }
{ prevmemo = (!infence && id != "" && $0 ~ /^- [0-9]/); print }
APPLY_EOF
US="$(printf '\037')"; RS_CH="$(printf '\036')"
apply() { # <in> <out> <sets> <notes>
  awk -v sets="$3" -v notes="$4" -f "${TMP}/apply.awk" "$1" >"$2"
}
N="- 2026-11-13: 状態移行（再発ではない）。"
GOOD_SETS="OBS-001${US}Status${US}archived${RS_CH}OBS-011${US}Status${US}promoted${RS_CH}OBS-011${US}Issue${US}feel-flow/ff-dev-toolkit#40${RS_CH}OBS-005${US}Status${US}mitigated${RS_CH}OBS-005${US}Issue${US}skill:demo-skill${RS_CH}OBS-010${US}Status${US}archived${RS_CH}OBS-010${US}Issue${US}doc:docs/08-knowledge/OBSERVATIONS.md#obs-009${RS_CH}OBS-009${US}Count${US}3${RS_CH}OBS-009${US}First${US}2026-08-15${RS_CH}OBS-009${US}Last${US}2026-11-05"
GOOD_NOTES="OBS-001${US}${N}archived（Last から 307 日再発なし。基準は 180 日・Count 1 以下）（/observation-refine）${RS_CH}OBS-011${US}${N}既存 Issue feel-flow/ff-dev-toolkit#40（closed）へ紐付けた。一致の根拠: 同じ rebuild-shard の事象（/observation-refine）${RS_CH}OBS-005${US}${N}定着済み: skill:demo-skill の着手前の節が同じ手順を規定している（/observation-refine）${RS_CH}OBS-010${US}${N}OBS-009 へ統合した（Count 1 は統合先へ合算済み）（/observation-refine）${RS_CH}OBS-009${US}${N}OBS-010（Count 1）を統合し Count 2 → 3。同じ主張と判定した理由: 取る対処が同じ（/observation-refine）"
AFTER="${TMP}/after-good.md"
apply "${LEDGER}" "${AFTER}" "${GOOD_SETS}" "${GOOD_NOTES}"
if cmp -s "${LEDGER}" "${AFTER}"; then bad "C: 適用の道具が台帳を変えていない（以降の検査は成立しない）"; fi

run check --before "${LEDGER}" --after "${AFTER}"
expect_rc "C1: 4 種の操作を正しく当てた台帳" 0
expect_line "C1: CHECK 行の件数" "${OUT}" "CHECK entries=15 changed=5 promoted=1 mitigated=1 archived_stale=1 merged=1 threshold_unlinked=2 violations=0"
expect_line "C1: 統合の合算で閾値に届いたエントリを昇格判定へ渡す" "${OUT}" "THRESHOLD OBS-009 Count=3（未リンクの active。/retrospective の昇格判定へ渡す）"
expect_has "C1: 元から閾値に届いていたエントリも列挙する" "${OUT}" "THRESHOLD OBS-006 Count=3"
expect_not "C1: 違反の行は出ない" "${OUT}" "NG "

violation() { # <label> <after file> <NG 行に含まれる理由>
  run check --before "${LEDGER}" --after "$2"
  if [[ "${RC}" -ne 1 ]]; then bad "$1: rc=${RC}（期待 1）$(head -n 2 "${ERR}" | tr '\n' ' ')"; return 0; fi
  if cmp -s "$2" "${AFTER}"; then bad "$1: 変異が当たっていない（正しい適用と同じ内容）"; return 0; fi
  # NG 行の中に理由が在るかを awk 1 回で見る（パイプの下流へ早期終了する grep を置かない）
  if awk -v needle="$3" 'index($0, "NG ") == 1 && index($0, needle) > 0 { found = 1 } END { exit found ? 0 : 1 }' "${OUT}"; then
    ok "$1（rc=1）"
  else
    bad "$1: NG 行に理由が無い — $3 / 実際: $(awk 'index($0, "NG ") == 1 && n < 2 { printf "%s ", $0; n++ }' "${OUT}")"
  fi
}
V="${TMP}/v.md"
grep -vF '2025-12-20: kappa-suite が打ち切られた（初回）' "${AFTER}" >"${V}"
violation "C2-a: 既存の観測メモを消した" "${V}" "適用後に見つからない"
sed 's/^alpha-widget は設定の変更を自動で拾わない。$/alpha-widget は設定を拾う。/' "${AFTER}" >"${V}"
violation "C2-b: 本文を書き換えた" "${V}" "適用後に見つからない"
awk '/^<a id="obs-003"><\/a>$/ { skip = 1 } skip && /^---$/ { skip = 0; getline; next } !skip' "${AFTER}" >"${V}"
violation "C2-c: エントリを丸ごと消した" "${V}" "適用後に見つからない"
apply "${LEDGER}" "${V}" "OBS-001${US}Status${US}archived" ""
violation "C2-d: 状態を変えたのに観測メモを足していない" "${V}" "状態移行の観測メモが足されていない"
apply "${LEDGER}" "${V}" "OBS-011${US}Status${US}promoted" "OBS-011${US}${N}既存 Issue へ紐付けた"
violation "C2-e: promoted なのに Issue 列が空" "${V}" "promoted の Issue 列に owner/repo#N が無い"
apply "${LEDGER}" "${V}" "OBS-005${US}Status${US}mitigated${RS_CH}OBS-005${US}Issue${US}定着済み" "OBS-005${US}${N}定着済み"
violation "C2-f: mitigated なのに所在が無い" "${V}" "mitigated の Issue 列に対策の所在"
apply "${LEDGER}" "${V}" "OBS-002${US}Count${US}3" ""
violation "C2-g: 統合先でないエントリの Count を変えた" "${V}" "Count が変わっている"
apply "${LEDGER}" "${V}" "$(printf '%s' "${GOOD_SETS}" | sed "s/OBS-009${US}Count${US}3/OBS-009${US}Count${US}2/")" "${GOOD_NOTES}"
violation "C2-h: 統合先の Count を合算していない" "${V}" "統合先の Count が合算と一致しない"
apply "${LEDGER}" "${V}" "$(printf '%s' "${GOOD_SETS}" | sed "s/OBS-009${US}First${US}2026-08-15/OBS-009${US}First${US}2026-09-01/")" "${GOOD_NOTES}"
violation "C2-i: 統合先の First を最小へ寄せていない" "${V}" "統合先の First が最小と一致しない"
apply "${LEDGER}" "${V}" "OBS-010${US}Status${US}archived${RS_CH}OBS-010${US}Issue${US}doc:docs/08-knowledge/OBSERVATIONS.md#obs-099" "OBS-010${US}${N}OBS-099 へ統合した"
violation "C2-j: 統合先が台帳に無い" "${V}" "統合先 OBS-099 が台帳に無い"
apply "${LEDGER}" "${V}" "${GOOD_SETS}" "$(printf '%s' "${GOOD_NOTES}" | sed 's/OBS-010（Count 1）を統合し/別のエントリを統合し/')"
violation "C2-k: 統合先の観測メモが統合元を名指していない" "${V}" "この統合元を名指す状態移行の観測メモが無い"
apply "${LEDGER}" "${V}" "" "OBS-002${US}- 2026-11-13: 同じ打ち切りを踏んだ"
violation "C2-l: 再発の観測メモを足した（整理の操作ではない）" "${V}" "足された行が状態移行の観測メモではない"
apply "${LEDGER}" "${V}" "OBS-007${US}Status${US}archived" "OBS-007${US}${N}archived"
violation "C2-m: active 以外からの移行" "${V}" "整理が扱う移行は active からだけ"
apply "${LEDGER}" "${V}" "OBS-001${US}Status${US}archived${RS_CH}OBS-001${US}Issue${US}feel-flow/ff-dev-toolkit#40" "OBS-001${US}${N}archived"
violation "C2-n: archived で Issue 列を統合先以外へ変えた" "${V}" "archived で Issue 列を変えられるのは統合元だけ"
apply "${LEDGER}" "${V}" "OBS-002${US}Issue${US}feel-flow/ff-dev-toolkit#40" "OBS-002${US}${N}紐付けた"
violation "C2-o: Status を変えずに Issue 列だけ変えた" "${V}" "のまま Issue 列だけが変わっている"
apply "${LEDGER}" "${V}" "OBS-005${US}Status${US}archived${RS_CH}OBS-005${US}Issue${US}doc:docs/08-knowledge/OBSERVATIONS.md#obs-001${RS_CH}OBS-001${US}Count${US}2${RS_CH}OBS-001${US}Last${US}2026-11-01" "OBS-005${US}${N}OBS-001 へ統合した${RS_CH}OBS-001${US}${N}OBS-005（Count 1）を統合し Count 1 → 2"
violation "C2-p: Kind の違うエントリを統合した" "${V}" "の Kind が違う"

# ── C4: 統合の合算の向きと、既存の参照・値域を守る照合 ────────────────────────
PTR="doc:docs/08-knowledge/OBSERVATIONS.md#obs"
# 複数の統合元を 1 つの統合先へ畳む（OBS-010・OBS-011 → OBS-009）。Count は 2 + 1 + 1
MULTI_SETS="OBS-010${US}Status${US}archived${RS_CH}OBS-010${US}Issue${US}${PTR}-009${RS_CH}OBS-011${US}Status${US}archived${RS_CH}OBS-011${US}Issue${US}${PTR}-009${RS_CH}OBS-009${US}First${US}2026-08-15${RS_CH}OBS-009${US}Last${US}2026-11-05"
MULTI_NOTES="OBS-010${US}${N}OBS-009 へ統合した${RS_CH}OBS-011${US}${N}OBS-009 へ統合した${RS_CH}OBS-009${US}${N}OBS-010（Count 1）と OBS-011（Count 1）を統合し Count 2 → 4"
apply "${LEDGER}" "${V}" "${MULTI_SETS}${RS_CH}OBS-009${US}Count${US}4" "${MULTI_NOTES}"
run check --before "${LEDGER}" --after "${V}"
expect_rc "C4: 2 つの統合元を 1 つの統合先へ畳んだ台帳" 0
expect_has "C4: 統合元 2 件を数える" "${OUT}" " merged=2 "
apply "${LEDGER}" "${V}" "${MULTI_SETS}${RS_CH}OBS-009${US}Count${US}3" "${MULTI_NOTES}"
violation "C4-a: 2 件目の統合元の Count を合算していない" "${V}" "統合先の Count が合算と一致しない（期待 4 / 実際 3"
# 統合先自身の First が最小のまま残る向き（OBS-014 → OBS-013。First は 013 の値、Last は 014 の値）
OWN_SETS="OBS-014${US}Status${US}archived${RS_CH}OBS-014${US}Issue${US}${PTR}-013${RS_CH}OBS-013${US}Count${US}2"
OWN_NOTES="OBS-014${US}${N}OBS-013 へ統合した${RS_CH}OBS-013${US}${N}OBS-014（Count 1）を統合し Count 1 → 2"
apply "${LEDGER}" "${V}" "${OWN_SETS}${RS_CH}OBS-013${US}Last${US}2026-11-07" "${OWN_NOTES}"
run check --before "${LEDGER}" --after "${V}"
expect_rc "C4: 統合先自身の First が最小で、Last だけ統合元の値へ進む台帳" 0
apply "${LEDGER}" "${V}" "${OWN_SETS}${RS_CH}OBS-013${US}Last${US}2026-11-07${RS_CH}OBS-013${US}First${US}2026-11-07" "${OWN_NOTES}"
violation "C4-b: 統合先自身の First（最小）を統合元の値で上書きした" "${V}" "統合先の First が最小と一致しない（期待 2026-11-06 / 実際 2026-11-07）"
apply "${LEDGER}" "${V}" "${OWN_SETS}" "${OWN_NOTES}"
violation "C4-c: 統合先の Last を最大へ進めていない" "${V}" "統合先の Last が最大と一致しない（期待 2026-11-07 / 実際 2026-11-06）"
apply "${LEDGER}" "${V}" "OBS-001${US}Status${US}archived${RS_CH}OBS-001${US}Last${US}2026-11-13" "OBS-001${US}${N}archived"
violation "C4-d: archive と同時に Last を適用日へ書き換えた" "${V}" "Last が変わっている（2026-01-10 → 2026-11-13）"
apply "${LEDGER}" "${V}" "OBS-001${US}Status${US}archived${RS_CH}OBS-001${US}First${US}2026-01-01" "OBS-001${US}${N}archived"
violation "C4-e: 統合先でないエントリの First を変えた" "${V}" "First が変わっている（2026-01-10 → 2026-01-01）"
apply "${LEDGER}" "${V}" "OBS-005${US}Kind${US}problem" ""
violation "C4-f: Kind を書き換えた（書き換えたエントリを名指す）" "${V}" "NG OBS-005: 適用前の"
apply "${LEDGER}" "${V}" "OBS-001${US}Status${US}resolved" "OBS-001${US}${N}解決した"
violation "C4-g: 値域外の Status へ移した" "${V}" "移行先の Status が値域外（resolved）"
apply "${LEDGER}" "${V}" "OBS-010${US}Status${US}archived${RS_CH}OBS-010${US}Issue${US}${PTR}-009${RS_CH}OBS-009${US}Status${US}archived${RS_CH}OBS-009${US}Issue${US}${PTR}-002${RS_CH}OBS-002${US}Count${US}4${RS_CH}OBS-002${US}Last${US}2026-10-20" "OBS-010${US}${N}OBS-009 へ統合した${RS_CH}OBS-009${US}${N}OBS-002 へ統合した${RS_CH}OBS-002${US}${N}OBS-009（Count 2）を統合し Count 2 → 4"
violation "C4-h: 統合先を別の統合の統合元にした（連鎖）" "${V}" "統合先 OBS-009 が archived"
apply "${LEDGER}" "${V}" "OBS-005${US}Status${US}mitigated${RS_CH}OBS-005${US}Issue${US}${PTR}-006" "OBS-005${US}${N}定着済み"
violation "C4-i: mitigated の所在に台帳自身のエントリを書いた" "${V}" "mitigated の所在に台帳自身のエントリを書いている"
apply "${LEDGER}" "${V}" "OBS-011${US}Status${US}promoted${RS_CH}OBS-011${US}Issue${US}40 番" "OBS-011${US}${N}紐付けた"
violation "C4-j: promoted の Issue 列がリポジトリ修飾の無い番号" "${V}" "promoted の Issue 列に owner/repo#N が無い（40 番）"
apply "${LEDGER}" "${V}" "OBS-015${US}Status${US}promoted${RS_CH}OBS-015${US}Issue${US}feel-flow/ff-dev-toolkit#40" "OBS-015${US}${N}紐付けた"
violation "C4-k: Issue 列が埋まった active の参照を上書きした" "${V}" "Issue 列が埋まった active は整理の対象外（既存の参照 feel-flow/ff-dev-toolkit#43 を上書きしない"
apply "${LEDGER}" "${V}" "$(printf '%s' "${GOOD_SETS}" | sed "s/OBS-009${US}Count${US}3/OBS-009${US}Count${US}3x/")" "${GOOD_NOTES}"
violation "C4-l: 統合先の Count に数字で始まる不正な値を書いた" "${V}" "Count が 1 以上の整数ではない（3x）"
apply "${LEDGER}" "${V}" "OBS-001${US}Status${US}mitigated${RS_CH}OBS-001${US}Issue${US}skill:demo-skill" "OBS-001${US}${N}定着済み"
violation "C4-m: problem を mitigated にした" "${V}" "整理が mitigated にするのは Kind が keep のエントリだけ（problem"
apply "${LEDGER}" "${V}" "" "OBS-002${US}${N}archived"
violation "C4-n: 状態移行の観測メモだけを足した" "${V}" "メタ行が何も変わっていない"
awk '/^### OBS-001:/ { hit = 1 } hit && /^\| Status \|/ { print "| Status | active | Issue | なし | 余分 | 書き足した本文 |"; hit = 0; next } { print }' "${LEDGER}" >"${V}"
violation "C4-o: メタ行へ余分なセルを書き足した" "${V}" "メタ行が適用後に見つからない"
apply "${LEDGER}" "${V}" "${GOOD_SETS}" "$(printf '%s' "${GOOD_NOTES}" | sed 's/OBS-010（Count 1）を統合し/OBS-0100（Count 1）を統合し/')"
violation "C4-p: 統合先の観測メモが、統合元の ID を前方一致で含むだけ（OBS-0100）" "${V}" "この統合元を名指す状態移行の観測メモが無い"
# 既定以外の台帳パス: ポインタはそのパスで書き、--ledger-rel で渡す
CUSTOM_SETS="$(printf '%s' "${GOOD_SETS}" | sed 's#doc:docs/08-knowledge/OBSERVATIONS.md#doc:knowledge/LEDGER.md#')"
apply "${LEDGER}" "${V}" "${CUSTOM_SETS}" "${GOOD_NOTES}"
run check --before "${LEDGER}" --after "${V}" --ledger-rel knowledge/LEDGER.md
expect_rc "C4: 既定以外の台帳パスのポインタは --ledger-rel を渡せば通る" 0
violation "C4-q: 既定以外のパスのポインタを --ledger-rel なしで照合した" "${V}" "archived で Issue 列を変えられるのは統合元だけ"
awk '{ printf "%s\r\n", $0 }' "${AFTER}" >"${TMP}/after-crlf.md"
run check --before "${LEDGER}" --after "${TMP}/after-crlf.md"
expect_rc "C4: 改行が CRLF になっただけの差は違反にしない（両側の CR を落として比べる）" 0
{ cat "${LEDGER}"; awk '/^### OBS-001:/ { p = 1 } p { print } p && /^---$/ { exit }' "${LEDGER}"; } >"${TMP}/dup-before.md"
run check --before "${TMP}/dup-before.md" --after "${TMP}/dup-before.md"
expect_rc "C4: 適用前に同じ ID の見出しが複数ある台帳は判定不能" 2
# 過去の整理をまたぐ連鎖: 前回 OBS-010 → OBS-009 を統合済みの台帳で、今回 OBS-009 を promoted の OBS-007 へ統合する
PRIOR="${TMP}/prior-before.md"
apply "${LEDGER}" "${PRIOR}" "OBS-010${US}Status${US}archived${RS_CH}OBS-010${US}Issue${US}${PTR}-009${RS_CH}OBS-009${US}Count${US}3${RS_CH}OBS-009${US}First${US}2026-08-15${RS_CH}OBS-009${US}Last${US}2026-11-05" "OBS-010${US}${N}OBS-009 へ統合した${RS_CH}OBS-009${US}${N}OBS-010（Count 1）を統合し Count 2 → 3"
run check --before "${LEDGER}" --after "${PRIOR}"
expect_rc "C4: 前回の整理（OBS-010 → OBS-009）そのものは違反なし" 0
apply "${PRIOR}" "${V}" "OBS-009${US}Status${US}archived${RS_CH}OBS-009${US}Issue${US}${PTR}-007${RS_CH}OBS-007${US}Count${US}7${RS_CH}OBS-007${US}Last${US}2026-11-05" "OBS-009${US}${N}OBS-007 へ統合した${RS_CH}OBS-007${US}${N}OBS-009（Count 3）を統合し Count 4 → 7"
run check --before "${PRIOR}" --after "${V}"
if [[ "${RC}" -eq 1 ]] && grep -qxF "NG OBS-009: 既存の統合元 OBS-010 が指す統合先が archived になった（連鎖。過去の統合先は統合元にしない）" "${OUT}"; then
  ok "C4-r: 過去の統合先を今回の統合元にする連鎖（OBS-010 → OBS-009 → OBS-007）は違反（rc=1）"
else
  bad "C4-r: 過去の整理をまたぐ連鎖を通した（rc=${RC}）— $(awk 'index($0, "NG ") == 1 || index($0, "CHECK ") == 1 { printf "%s ", $0 }' "${OUT}")"
fi

run check --before "${LEDGER}" --after "${LEDGER}"
expect_rc "C3: 無変更は違反なし" 0
expect_has "C3: 無変更は changed=0" "${OUT}" "CHECK entries=15 changed=0 "
run check --before "${TMP}/no-such-ledger.md" --after "${AFTER}"
expect_rc "C3: 適用前の台帳が無い回は判定不能" 2
run check --before "${TMP}/heading/docs/08-knowledge/OBSERVATIONS.md" --after "${AFTER}"
expect_rc "C3: 適用前にエントリを認識できない回は判定不能（違反 0 件の緑にしない）" 2
run check --before "${LEDGER}"
expect_rc "C3: --after が無い" 64

# ── R8: 統合の母集団・小さい台帳・メタ不正の名指し ────────────────────────────
variant() { # <名前> <sets> → 変えた台帳を持つ root のパスを VROOT へ入れる
  VROOT="${TMP}/variant-$1"
  mkdir -p "${VROOT}/docs/08-knowledge"
  apply "${LEDGER}" "${VROOT}/docs/08-knowledge/OBSERVATIONS.md" "$2" ""
}
pair_line='^OBS-009 × OBS-010  '
variant promoted "OBS-009${US}Status${US}promoted${RS_CH}OBS-009${US}Issue${US}feel-flow/ff-dev-toolkit#12"
run report --root "${VROOT}" --today "${TODAY}"
section 2 "${OUT}" >"${TMP}/s2"
if grep -qE "${pair_line}" "${TMP}/s2"; then ok "R8: active × promoted の組は統合の候補に出る（残す側は promoted）"; else bad "R8: active × promoted の組が出ない"; fi
expect_has "R8: 組の行に Status と Kind を出す" "${TMP}/s2" "OBS-009 [promoted problem Count=2 Last=2026-10-20]"
expect_not "R8: 片方が promoted の組に「閾値に到達」の予告を付けない" "${TMP}/s2" "合算 Count=3（採れば合算で昇格閾値に到達）"
variant archived "OBS-010${US}Status${US}archived"
run report --root "${VROOT}" --today "${TODAY}"
section 2 "${OUT}" >"${TMP}/s2"
if grep -qE "${pair_line}" "${TMP}/s2"; then bad "R8: archived のエントリが統合の組に出ている"; else ok "R8: archived のエントリは統合の組に出ない"; fi
expect_has "R8: archived を外した分だけ組が減る" "${OUT}" " merge_pairs=1 merge_reach_threshold=0 "
variant linked "OBS-010${US}Issue${US}feel-flow/ff-dev-toolkit#41"
run report --root "${VROOT}" --today "${TODAY}"
section 2 "${OUT}" >"${TMP}/s2"
if grep -qE "${pair_line}" "${TMP}/s2"; then bad "R8: Issue 列の埋まった active が統合の組に出ている（採ると既存の参照が上書きされる）"; else ok "R8: Issue 列の埋まった active は統合の組に出ない"; fi
expect_has "R8: Issue 列の埋まった active は別の節で 2 件" "${OUT}" " active_linked=2 "
variant kind "OBS-010${US}Kind${US}keep"
run report --root "${VROOT}" --today "${TODAY}"
section 2 "${OUT}" >"${TMP}/s2"
if grep -qE "${pair_line}" "${TMP}/s2"; then bad "R8: Kind の違う組（problem × keep）が統合の候補に出ている"; else ok "R8: Kind の違う組は統合の候補に出ない"; fi

variant priortarget "OBS-012${US}Issue${US}doc:docs/08-knowledge/OBSERVATIONS.md#obs-013"
run report --root "${VROOT}" --today "${TODAY}"
section 2 "${OUT}" >"${TMP}/s2"
expect_has "R8: 過去の整理で統合先になったエントリに印を付ける（統合元にすると連鎖になる）" "${TMP}/s2" "OBS-013 [active problem Count=1 Last=2026-11-06 過去の統合先]"
expect_has "R8: 印が付くのは統合先になったエントリだけ" "${TMP}/s2" "OBS-014 [active problem Count=1 Last=2026-11-07]"

variant noissue "OBS-003${US}Issue${US}"
run report --root "${VROOT}" --today "${TODAY}"
expect_rc "R8: Issue 列が空のエントリがある台帳は続行" 0
expect_has "R8: Issue 列が空のエントリを ID で名指す" "${OUT}" "OBS-003  gamma-linter"
expect_has "R8: 理由は Issue 列が空" "${OUT}" "Issue 列が空（未リンクは「なし」と書く）"
expect_has "R8: Issue 列が空のエントリは母集団に入れない" "${OUT}" " link_population=10 "
variant nofirst "OBS-004${US}First${US}5/16"
run report --root "${VROOT}" --today "${TODAY}"
expect_has "R8: First を読めないエントリを理由つきで外す" "${OUT}" "First を読めない（5/16）"
variant badstatus "OBS-002${US}Status${US}resolved"
run report --root "${VROOT}" --today "${TODAY}"
expect_has "R8: 値域外の Status を理由つきで外す" "${OUT}" "Status を読めない（resolved）"
expect_has "R8: 値域外の Status のエントリを ID で名指す" "${OUT}" "OBS-002  beta-runner"
variant badkind "OBS-005${US}Kind${US}Keep"
run report --root "${VROOT}" --today "${TODAY}"
expect_has "R8: 値域外の Kind を理由つきで外す（母集団から黙って落とさない）" "${OUT}" "Kind を読めない（Keep）"
expect_has "R8: Kind を読めない Keep は定着判定の母集団に入れない" "${OUT}" " keep_population=0 "

mkdir -p "${TMP}/dup/docs/08-knowledge" "${TMP}/tiny/docs/08-knowledge" "${TMP}/none/docs/08-knowledge"
cp "${TMP}/dup-before.md" "${TMP}/dup/docs/08-knowledge/OBSERVATIONS.md"
run report --root "${TMP}/dup" --today "${TODAY}"
expect_rc "R8: 同じ ID の見出しが複数ある台帳は判定不能（check が照合できない台帳で候補を出さない）" 2
# 非 archived が 2 件だけで、主張が同じ台帳。共有語がすべての文書に現れる
cat >"${TMP}/tiny/docs/08-knowledge/OBSERVATIONS.md" <<'TINY_EOF'
# 振り返り観測台帳（fixture・2 件）

## エントリ一覧

### OBS-001: alpha-widget の再読込を忘れると zeta-cache が古い値を返す

| Kind | problem | Count | 1 |
| First | 2026-11-01 | Last | 2026-11-01 |
| Status | active | Issue | なし |

- 2026-11-01: 1 回やり直した（初回）

---

### OBS-002: alpha-widget の再読込を忘れると zeta-cache が古い値を返す

| Kind | problem | Count | 1 |
| First | 2026-11-02 | Last | 2026-11-02 |
| Status | active | Issue | なし |

- 2026-11-02: もう 1 回やり直した（初回）

---
TINY_EOF
run report --root "${TMP}/tiny" --today "${TODAY}"
expect_rc "R8: 同じ主張 2 件だけの台帳でも候補を算出できる（重みが 0 にならない）" 0
section 2 "${OUT}" >"${TMP}/s2"
if grep -qE '^OBS-001 × OBS-002  類似 1\.00  ' "${TMP}/s2"; then ok "R8: 同文の 2 件は類似 1.00 の組として出る"; else bad "R8: 同文の 2 件が組に出ない — $(head -n 2 "${TMP}/s2" | tr '\n' ' ')$(head -n 2 "${ERR}" | tr '\n' ' ')"; fi
cat >"${TMP}/none/docs/08-knowledge/OBSERVATIONS.md" <<'NONE_EOF'
# 振り返り観測台帳（fixture・0 件）

## エントリ形式

```markdown
### OBS-XXX: [記入例]
```

## エントリ一覧
NONE_EOF
run report --root "${TMP}/none" --today "${TODAY}"
expect_rc "R8: 作成直後でエントリが無い台帳は整理対象なし" 0
expect_line "R8: エントリ 0 件を名指す" "${OUT}" "（整理対象なし: 台帳はあるがエントリが無い）"
expect_has "R8: エントリ 0 件の SUMMARY" "${OUT}" "SUMMARY entries=0 active=0 "

# ── S1: スキル本文とスクリプトの実体の一致 ──────────────────────────────────
script_defaults="$(sed -n 's/^  local root="" ledger="" today="" stale_days=\([0-9][0-9]*\) stale_max=\([0-9][0-9]*\) .*$/\1 \2/p' "${TARGET}")"
if [[ "${script_defaults}" =~ ^[0-9]+\ [0-9]+$ ]]; then
  sd="${script_defaults% *}"; sm="${script_defaults#* }"
  needle="stale の基準は既定で「\`Last\` から ${sd} 日を超え、かつ \`Count\` が ${sm} 以下」"
  n="$(grep -cF -- "${needle}" "${SKILL}" || true)"
  if [[ "${n}" -eq 1 ]]; then ok "S1: スキル本文の stale の既定（${sd} 日・Count ${sm}）がスクリプトの既定と一致"; else bad "S1: スキル本文に stale の既定（${sd} 日・Count ${sm}）の行が ${n} 行（期待 1）"; fi
  n="$(grep -cF -- "stale の基準（既定は \`Last\` から ${sd} 日を超えて \`Count\` が ${sm} 以下）の正本も同スキル" "${LEDGER_DOC}" || true)"
  if [[ "${n}" -eq 1 ]]; then ok "S1: retrospective の ledger.md が同じ既定で本スキルを指す"; else bad "S1: ledger.md の「台帳の掃除」が本スキルと既定値を指す行が ${n} 行（期待 1）"; fi
else
  bad "S1: スクリプトから stale の既定を導出できない（run_report の local 行の書式変更）"
fi
n="$(grep -cF -- '取得できなかったリポジトリを `--issues` から省かない' "${SKILL}" || true)"
if [[ "${n}" -eq 1 ]]; then ok "S1: スキル本文が、取得に失敗したリポジトリも空の一覧で渡すと規定している（省くと issues=ok になる）"; else bad "S1: 取得に失敗したリポジトリを省かない規定の行が ${n} 行（期待 1）"; fi
for sub in report check; do
  n="$(grep -cF -- "FF_DEV_TOOLKIT_ROOT=\"\${FF_DEV_TOOLKIT_ROOT}\" bash \"\${FF_DEV_TOOLKIT_ROOT}/scripts/observation-refine.sh\" ${sub} " "${SKILL}" || true)"
  if [[ "${n}" -eq 1 ]]; then ok "S1: スキル本文が ${sub} を handoff 付きの 1 行で呼ぶ"; else bad "S1: スキル本文の ${sub} の起動行が ${n} 行（期待 1）"; fi
done
prefix='状態移行（再発ではない）'
for f in "${CHECK_AWK}" "${APPLY_DOC}" "${PLUGIN_ROOT}/skills/retrospective/references/promotion.md"; do
  if grep -qF -- "${prefix}" "${f}"; then ok "S1: 状態移行の書き出しが在る — ${f#"${PLUGIN_ROOT}"/}"; else bad "S1: 状態移行の書き出しが無い — ${f#"${PLUGIN_ROOT}"/}"; fi
done
n="$(grep -cF -- '- YYYY-MM-DD: 状態移行（再発ではない）。' "${APPLY_DOC}" || true)"
if [[ "${n}" -ge 5 ]]; then ok "S1: apply.md の全操作の書式が照合の書き出しで始まる（${n} 行）"; else bad "S1: apply.md の書式行が ${n} 行（期待 5 以上: 書き出しの定義 + 紐付け・統合先・統合元・archive・定着）"; fi

echo
if [[ "${FAIL}" -gt 0 ]]; then
  echo "✗ observation-refine verify: ${FAIL} 件失敗 / ${PASS} 件成功" >&2
  finish 1
fi
echo "✓ observation-refine verify: ${PASS} 件成功"
finish 0
