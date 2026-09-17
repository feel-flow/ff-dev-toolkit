# shellcheck shell=bash
#
# check-version-claims.sh の base 先行照合が fetch 失敗の原因を捨てないことを固定する。
#
# 3 スキルの base 先行ガード 4 フェンスは「stderr をコマンド置換で受け、資格情報部を伏せて
# 停止メッセージへ載せる」正規形へ揃えた（cases/base-guard-fetch-stderr.sh）が、同型の
# `git fetch … >/dev/null 2>&1 || { …; return 2; }` が本スクリプトの非 CI 分岐にも残っていた
# （Issue `#1717`）。「最新化できません」だけを見せられた実行者が、認証・通信・remote 設定の
# 切り分けを一からやり直す形をなくす。
#
# 正規形（fixtures/base-guard-fetch-normal.txt）からの意図的な差分は 3 点: `git -C "$root"` /
# `return 2`（exit 2 は plugin-root-contract と本 suite の rc=2 分類が固定している）/ 既存の
# 停止文 prefix `✗ origin/<default> を最新化できません`。stderr の受け方と伏せ字の sed 式は同じ
# なので、そこだけを文字列で固定し、原因の到達と伏せ字は実行して測る。
#
# 呼び出し元（verify.sh）の ok / bad / contains / not_contains / TMP / SCRIPT_DIR /
# CLAIM_VALIDATOR / NORMAL_BARE / FETCH_FAIL_WORK を使う。単体では実行しない。

echo "== check-version-claims.sh の fetch 失敗診断（原因の到達と伏せ字） =="

# (1) 静的形: stderr だけを受ける捕捉・伏せ字・旧形の不在。旧形へ戻す変異でここが赤になる。
contains "$CLAIM_VALIDATOR" 'fetch origin "+refs/heads/${default_branch}:refs/remotes/origin/${default_branch}" 2>&1 >/dev/null)"' "validator は fetch の stderr をコマンド置換で受ける（stdout は捨てる）"
contains "$CLAIM_VALIDATOR" "s#(://)[^/[:space:]]*@#\\1***@#g" "validator は URL の userinfo を最後の @ まで伏せる"
not_contains "$CLAIM_VALIDATOR" 'refs/remotes/origin/${default_branch}" >/dev/null 2>&1' "validator に stderr を捨てる旧形の fetch が残っていない"

# (2) 失敗系: 到達できない remote（FETCH_FAIL_WORK の origin は $TMP/missing-origin.git）で
#     git の原因が停止メッセージへ載る。`2>&1 >/dev/null` を旧形 `>/dev/null 2>&1` へ戻すと
#     fetch_err が空になり、原因の代わりに既定文が出てここが赤くなる。
set +e
validator_fetch_out="$("$CLAIM_VALIDATOR" --root "$FETCH_FAIL_WORK" 2>&1)"
validator_fetch_rc=$?
set -e
if [[ "$validator_fetch_rc" -eq 2 ]]; then ok "失敗系: validator が rc=2 で停止（検査不能の分類を維持）"; else bad "失敗系: rc=2 で停止しない（実際: ${validator_fetch_rc}）"; fi
if [[ "$validator_fetch_out" == *"を最新化できません"* ]]; then ok "失敗系: 既存の停止文 prefix を保つ"; else bad "失敗系: 停止文が変わった"; printf '    実際: %s\n' "$validator_fetch_out" >&2; fi
if [[ "$validator_fetch_out" == *"missing-origin.git"* ]]; then ok "失敗系: git の原因（到達できない remote のパス）が停止メッセージへ載る"; else bad "失敗系: git の原因が落ちている（stderr を捨てる旧形の可能性）"; printf '    実際: %s\n' "$validator_fetch_out" >&2; fi
if [[ "$validator_fetch_out" != *"原因は出力されませんでした"* ]]; then ok "失敗系: 原因が空の既定文へ落ちない"; else bad "失敗系: 原因が空で既定文へ落ちた"; fi

# (3) 伏せ字: 実 git は版・経路によって URL の userinfo を自分で落とすため、資格情報付き URL を
#     stderr へ出す stub git（fixtures/bin/git の FAKE_CLAIM_GIT_FAIL_FETCH）で伏せ字そのものを
#     測る。sed 式を旧形 `[^/@[:space:]]+@` へ戻すと最初の @ までしか伏せず SECRETTAIL が残って
#     赤くなる。stub を外す（FAKE_CLAIM_GIT_FAIL_FETCH 未設定）と実 git の到達失敗になり
#     `://***@` が現れず同じく赤 — 空振りを緑へ倒さない。
validator_mask_work="$TMP/fetch-mask-work"
validator_mask_bin="$TMP/fetch-mask-bin"
rm -rf "$validator_mask_work" "$validator_mask_bin"
git clone -q "$NORMAL_BARE" "$validator_mask_work"
mkdir -p "$validator_mask_bin"
cp "$SCRIPT_DIR/fixtures/bin/git" "$validator_mask_bin/git"; chmod +x "$validator_mask_bin/git"
# 実 git は PATH 前置より前にここで解決する（同じ prefix 内で `$(command -v git)` すると、
# コマンド hash が外れた回に stub 自身へ解決して exec が自己再帰する）。
validator_mask_real_git="$(command -v git)"
set +e
validator_mask_out="$(PATH="$validator_mask_bin:$PATH" FAKE_CLAIM_GIT_FAIL_FETCH=1 FAKE_CLAIM_GIT_FETCH_URL='https://alice:p@ss-SECRETTAIL@127.0.0.1:1/nope.git' FAKE_CLAIM_REAL_GIT="$validator_mask_real_git" "$CLAIM_VALIDATOR" --root "$validator_mask_work" 2>&1)"
validator_mask_rc=$?
set -e
if [[ "$validator_mask_rc" -eq 2 ]]; then ok "伏せ字: stub の fetch 失敗でも rc=2"; else bad "伏せ字: rc=2 で停止しない（実際: ${validator_mask_rc}）"; printf '    実際: %s\n' "$validator_mask_out" >&2; fi
if [[ "$validator_mask_out" == *"://***@127.0.0.1"* ]]; then ok "伏せ字: userinfo 内の生 @ を跨いで最後の @ まで伏せる"; else bad "伏せ字: host 直前まで伏せられない（stub 不達か sed 式の後退）"; printf '    実際: %s\n' "$validator_mask_out" >&2; fi
if [[ "$validator_mask_out" != *"SECRETTAIL"* ]]; then ok "伏せ字: 資格情報を停止メッセージへ出さない"; else bad "伏せ字: 資格情報が停止メッセージへ漏れる"; printf '    実際: %s\n' "$validator_mask_out" >&2; fi

# (4) 成功系: fetch できたときは新しい出力を増やさない。validator は script-root guard の
#     provenance 行（`ℹ️ …`。basename の allowlist 外なので env では抑止できない）を常に 1 行出す
#     ため、それを除いた stderr が空であることを測る。grep -v は「該当なし」の rc=1 だけを空へ
#     落とし、rc≥2 は判定不能として赤にする。
validator_ok_work="$TMP/fetch-ok-work"
rm -rf "$validator_ok_work"
git clone -q "$NORMAL_BARE" "$validator_ok_work"
set +e
"$CLAIM_VALIDATOR" --root "$validator_ok_work" > "$TMP/fetch-ok.out" 2> "$TMP/fetch-ok.err"
validator_ok_rc=$?
set -e
validator_ok_leak_rc=0
validator_ok_leak="$(grep -v '^ℹ' "$TMP/fetch-ok.err")" || validator_ok_leak_rc=$?
if [[ "$validator_ok_rc" -eq 0 ]]; then ok "成功系: fetch できたら rc=0 で継続"; else bad "成功系: rc=0 で継続しない（実際: ${validator_ok_rc}）"; cat "$TMP/fetch-ok.err" >&2; fi
if [[ "$validator_ok_leak_rc" -ge 2 ]]; then
  bad "成功系: stderr を読めない（判定不能 rc=${validator_ok_leak_rc}）"
elif [[ -z "$validator_ok_leak" ]]; then
  ok "成功系: provenance 行以外を stderr へ出さない"
else
  bad "成功系: stderr に出力が漏れる"; printf '    stderr: %s\n' "$validator_ok_leak" >&2
fi
