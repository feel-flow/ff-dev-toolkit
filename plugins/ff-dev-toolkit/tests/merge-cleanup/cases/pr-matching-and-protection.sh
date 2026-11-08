# shellcheck shell=bash
# pipefail-inherited: verify.sh が set -euo pipefail の下で source する
# 項目 40〜42・47: マージ済み PR の照合・保護パターン・復旧コマンドの引用
#
# verify.sh から source される（ok / bad / TMP / TARGET / MOCK / PLUGIN_ROOT / SCRIPT_DIR を共有）。
# 読む順序は verify.sh の一覧が正本で、前の cases の fixture と関数を後ろの cases が使う（Issue `#2697`）。

# ---- 40. (Issue 703) MERGED 一覧側の OID が null の [gone] ブランチ --------------
#
# gh pr list（MERGED 一覧）側だけ headRefOid が null の場合、一覧の行は
# "name<TAB>null" になり、(名前, OID) 照合は必ず外れる。従来はここで
# 「未マージの固有コミットの可能性」と表示していたが、実際に無いのは照合材料で
# あって未マージの証拠ではない（`#570` と同型の誤帰属）。削除しない点は変えず、
# スキップ理由が照合材料の欠落を名指しすることを固定する。

echo ""
echo "== (Issue 703) MERGED 一覧側 OID が null の [gone] ブランチ =="

git switch -q -c 'feature/#50-null-merged-oid' develop
echo nulloid50 > nulloid50.txt
git add nulloid50.txt
git commit -qm "commit on feature/#50-null-merged-oid"
SKIP_SIMPLE_GIT_HOOKS=1 git push -qu origin 'feature/#50-null-merged-oid'
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin --delete 'feature/#50-null-merged-oid'
git switch -q develop

set +e
PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-703.log" 2>&1
EXIT_703=$?
set -e
if [ "$EXIT_703" -eq 2 ] \
  && git show-ref -q "refs/heads/feature/#50-null-merged-oid" \
  && grep -q "feature/#50-null-merged-oid は MERGED PR の head 名として一覧に載っていますが、一覧側の OID が null で照合材料がありません" "$TMP/run-703.log" \
  && grep -qE '^  - feature/#50-null-merged-oid: \[gone\] だが MERGED 一覧側の OID が null で照合材料が無い' "$TMP/run-703.log" \
  && ! grep -q "feature/#50-null-merged-oid はマージ済み PR の head と OID 一致しません" "$TMP/run-703.log"; then
  ok "MERGED 一覧側の OID が null なら、未マージと誤帰属せず照合材料の欠落を名指しする"
else
  bad "null OID の [gone] ブランチのスキップ理由が期待どおりでない (exit=$EXIT_703)"
fi

# 40.2 変異テスト: null 照合を無効化した mutant を実際に走らせ、旧文言（誤帰属）へ
#      退行することを実測する。40.1 の green 条件（新文言あり・旧文言なし）が
#      mutant では両方裏返る = この fixture は mutant を赤にできる、という検出力の証明。
stage_cleanup_mutant "$TMP/mutant-703"
sed "s|%s\\\\tnull|%s\\\\tXnull|" "$TMP/mutant-703/lib/merge-cleanup-local.sh" > "$TMP/mutant-703/lib/merge-cleanup-local.new"
mv "$TMP/mutant-703/lib/merge-cleanup-local.new" "$TMP/mutant-703/lib/merge-cleanup-local.sh"
MUTANT_703="$TMP/mutant-703/merge-cleanup.sh"
if ! cmp -s "$PLUGIN_ROOT/scripts/lib/merge-cleanup-local.sh" "$TMP/mutant-703/lib/merge-cleanup-local.sh"; then
  ok "mutant が生成できた（null 照合の無効化。self-test）"
else
  bad "mutant が原本と同一 — 変異テストは何も検証していない"
fi
set +e
PATH="$MOCK:$PATH" bash "$MUTANT_703" 12 > "$TMP/run-703-mutant.log" 2>&1
EXIT_703M=$?
set -e
if [ "$EXIT_703M" -eq 2 ] \
  && grep -q "feature/#50-null-merged-oid はマージ済み PR の head と OID 一致しません" "$TMP/run-703-mutant.log" \
  && ! grep -q "feature/#50-null-merged-oid は MERGED PR の head 名として一覧に載っていますが" "$TMP/run-703-mutant.log"; then
  ok "mutant（null 照合なし）は旧文言へ退行する = 40.1 の判定が mutant を赤にできる"
else
  bad "mutant の退行が観測できない — 40.1 の検出力は主張できない (exit=$EXIT_703M)"
fi
git branch -q -D 'feature/#50-null-merged-oid'

# ---- 41. (Issue 835) マージ済み PR 照合上限の設定と進捗出力 ----------------------

echo ""
echo "== (Issue 835) マージ済み PR 照合上限と進捗出力 =="

# 41.1 既定は 1000 のまま（後方互換）で、進捗（照合上限と取得件数）が出る。
#      mock は --limit を尊重するため、既定でも全 fixture 件数（< 1000）が返り
#      打ち切りの注記は出ない。
if grep -q "照合上限: 1000 件" "$TMP/run.log" \
  && grep -qE "マージ済み PR 一覧を取得しました: [1-9][0-9]* 件" "$TMP/run.log" \
  && ! grep -q "打ち切っています" "$TMP/run.log"; then
  ok "既定の照合上限は 1000 のままで、取得の進捗が出る（打ち切り注記なし）"
else
  bad "既定の照合上限・進捗出力が期待どおりでない"
fi

# 41.2 上限を下げると gh へ渡り、打ち切りが明示され、上限外の MERGED PR は照合対象から
#      外れる（staging/keep は一覧の後方にあるため候補に載らなくなる）。既定 run では
#      候補に載っている（green pin）ことも併せて固定する。
if grep -qxF 'staging/keep' "$LEFTOVER_CANDIDATES"; then
  ok "既定 run では staging/keep が取り残し候補一覧に載る（green pin）"
else
  bad "既定 run で staging/keep が候補に載っていない — 41.2 の「載らない」は空振りの可能性"
fi
set +e
FF_MERGE_CLEANUP_MERGED_PR_LIMIT=5 \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-limit5.log" 2>&1
EXIT_LIMIT5=$?
set -e
LIMIT5_CANDIDATES="$TMP/run-limit5-candidates.txt"
leftover_candidates "$TMP/run-limit5.log" > "$LIMIT5_CANDIDATES"
if [ "$EXIT_LIMIT5" -eq 2 ] \
  && grep -q "照合上限: 5 件" "$TMP/run-limit5.log" \
  && grep -q "マージ済み PR 一覧を取得しました: 5 件" "$TMP/run-limit5.log" \
  && grep -q "上限 5 件で打ち切っています" "$TMP/run-limit5.log" \
  && ! grep -qxF 'staging/keep' "$LIMIT5_CANDIDATES"; then
  ok "照合上限が gh へ渡り、打ち切りが明示され、上限外の PR は照合対象から外れる"
else
  bad "照合上限の設定が期待どおりでない (exit=$EXIT_LIMIT5)"
fi

# 41.3 不正値は破壊的処理より前に中断する（fail-closed）
set +e
FF_MERGE_CLEANUP_MERGED_PR_LIMIT=abc \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-limit-bad.log" 2>&1
EXIT_LIMIT_BAD=$?
FF_MERGE_CLEANUP_MERGED_PR_LIMIT=0 \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-limit-zero.log" 2>&1
EXIT_LIMIT_ZERO=$?
set -e
if [ "$EXIT_LIMIT_BAD" -eq 1 ] && [ "$EXIT_LIMIT_ZERO" -eq 1 ] \
  && grep -q "FF_MERGE_CLEANUP_MERGED_PR_LIMIT は正の整数で指定してください" "$TMP/run-limit-bad.log" \
  && grep -q "FF_MERGE_CLEANUP_MERGED_PR_LIMIT は正の整数で指定してください" "$TMP/run-limit-zero.log" \
  && ! grep -q "マージ後 Cleanup 結果" "$TMP/run-limit-bad.log"; then
  ok "照合上限の不正値（非数値 / 0）は破壊的処理前に中断する"
else
  bad "照合上限の不正値の扱いが期待どおりでない (abc=$EXIT_LIMIT_BAD, 0=$EXIT_LIMIT_ZERO)"
fi

# ---- 42. (Issue 1056) 保護ブランチパターンの設定可能化 --------------------------

echo ""
echo "== (Issue 1056) 保護ブランチパターンの設定可能化 =="

# 42.1 既定 run（未設定）では release/* は従来どおり保護される（後方互換。項目 5 で
#      remote_has 済み）。加えて skip 報告が「設定保護パターン」であることを名指しし、
#      手動削除コマンドを添える（無言の skip が毎回積み上がる問題への配慮）。
#      ハードコード保護（staging/keep）は従来の「保護ブランチ」表示のまま。
if grep -qF "skip (設定保護パターン 'release/*' に一致): release/1.0" "$TMP/run.log" \
  && grep -qF "git push origin --force-with-lease=refs/heads/release/1.0:" "$TMP/run.log" \
  && grep -qF "FF_MERGE_CLEANUP_PROTECT_BRANCHES" "$TMP/run.log" \
  && grep -qF "skip (保護ブランチ): staging/keep" "$TMP/run.log"; then
  ok "設定保護の skip は削除コマンド付きで報告し、ハードコード保護と書き分ける"
else
  bad "保護 skip の報告が期待どおりでない"
fi

# 42.2 'none' を指定すると release/* の追加保護が外れ、他の全ガードを通過済みの
#      マージ済み release/* が削除される。ハードコードの staging/* は 'none' でも
#      削除されない（最終防壁）。
remote_has 'release/1.0' || bad "fixture 前提が崩れています（42.2 より前に release/1.0 が消えている）"
set +e
FF_MERGE_CLEANUP_PROTECT_BRANCHES=none \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-protect-none.log" 2>&1
EXIT_PROTECT_NONE=$?
set -e
if [ "$EXIT_PROTECT_NONE" -eq 2 ] \
  && ! remote_has 'release/1.0' \
  && remote_has 'staging/keep' \
  && remote_has 'develop' \
  && grep -q "✓ removed: release/1.0" "$TMP/run-protect-none.log" \
  && grep -qF "skip (保護ブランチ): staging/keep" "$TMP/run-protect-none.log"; then
  ok "'none' で release/* の保護が外れて削除され、staging/* は設定でも削除されない"
else
  bad "'none' 指定時の挙動が期待どおりでない (exit=$EXIT_PROTECT_NONE)"
fi

# 42.3 不正な指定（空要素 / 前後空白）は中断する（fail-closed）
set +e
FF_MERGE_CLEANUP_PROTECT_BRANCHES='release/*:' \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-protect-empty.log" 2>&1
EXIT_PROTECT_EMPTY=$?
FF_MERGE_CLEANUP_PROTECT_BRANCHES='release/*: lts/*' \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-protect-space.log" 2>&1
EXIT_PROTECT_SPACE=$?
set -e
if [ "$EXIT_PROTECT_EMPTY" -eq 1 ] && [ "$EXIT_PROTECT_SPACE" -eq 1 ] \
  && grep -q "FF_MERGE_CLEANUP_PROTECT_BRANCHES に空のパターンがあります" "$TMP/run-protect-empty.log" \
  && grep -q "前後の空白があります" "$TMP/run-protect-space.log" \
  && ! grep -q "マージ後 Cleanup 結果" "$TMP/run-protect-empty.log"; then
  ok "保護パターンの不正な指定（空要素 / 前後空白）は中断する"
else
  bad "保護パターンの不正指定の扱いが期待どおりでない (empty=$EXIT_PROTECT_EMPTY, space=$EXIT_PROTECT_SPACE)"
fi

# 42.4 文字クラス glob（release/[[:digit:]]* 等）はクラス内の ':' が区切りと衝突して
#      黙って分断され、エラーにならないまま保護が消える（fail-open）。パース時に
#      検出して中断することを固定する
set +e
FF_MERGE_CLEANUP_PROTECT_BRANCHES='release/[[:digit:]]*' \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-protect-class.log" 2>&1
EXIT_PROTECT_CLASS=$?
set -e
if [ "$EXIT_PROTECT_CLASS" -eq 1 ] \
  && grep -q "文字クラス" "$TMP/run-protect-class.log" \
  && grep -q "プレフィックス glob" "$TMP/run-protect-class.log" \
  && ! grep -q "マージ後 Cleanup 結果" "$TMP/run-protect-class.log"; then
  ok "文字クラスを含む保護パターンは黙って分断せず中断する"
else
  bad "文字クラス入り保護パターンの扱いが期待どおりでない (exit=$EXIT_PROTECT_CLASS)"
fi

# ---- 47. 復旧コマンドのブランチ名・refspec を引用する ---------------------------
#
# 削除しなかった・できなかったブランチには、利用者が貼り付けて実行する復旧コマンドを添える。
# ブランチ名は PR や他人の push から来る値で、git の ref 名は ' ` $ ; ( ) を含められる。
# 案内するコマンドを実際に bash で実行し（git は argv を記録するだけのスタブ）、ブランチ名が
# 1 語のリテラルとして渡り、名前の中のコマンドが実行されない（sentinel が無い）ことを見る。
# 経路は 5 つ: OID 欠損の案内と失敗行（Step 4）/ OID null の [gone] / OID 不一致の [gone]
# （Step 5）/ 設定保護パターンの取り残し / headRefOid 無しの削除失敗行（Step 6）。
# 旧形（ブランチ名を裸または単引用の中へ埋め込む）では、どの経路も argv が名前と一致せず赤。

echo ""
echo "== 47. 復旧コマンドのブランチ名・refspec の引用 =="

# shellcheck disable=SC2016 # $(...) と `...` は名前の一部（展開しない）
F25_TAIL='-'"'"'$(touch${IFS}f25-sent)'"'"'`true`;x'
F25_A="q/f25-a${F25_TAIL}"
F25_B="q/f25-b${F25_TAIL}"
F25_C="q/f25-c${F25_TAIL}"
F25_D="q/f25-d${F25_TAIL}"
F25_E="q/f25-e${F25_TAIL}"
for f25_name in "$F25_A" "$F25_B" "$F25_C" "$F25_D" "$F25_E"; do
  git check-ref-format "refs/heads/$f25_name" || bad "fixture 前提: $f25_name は git の ref 名として不正"
done
f25_commit() { # <ブランチ名> → stdout に OID
  git switch -q -c "$1" develop
  printf '%s\n' "$1" > f25.txt
  git add f25.txt
  git commit -qm "commit for the quoting case"
  git rev-parse HEAD
  git switch -q develop
}
OID_F25_A="$(f25_commit "$F25_A")"
OID_F25_B="$(f25_commit "$F25_B")"
OID_F25_C="$(f25_commit "$F25_C")"
OID_F25_D="$(f25_commit "$F25_D")"
OID_F25_E="$(f25_commit "$F25_E")"
# A: origin にだけ在り、PR の headRefOid が null（Step 4 は削除せず案内する）。MERGED 一覧には無い
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_F25_A:refs/heads/$F25_A"
git branch -q -D "$F25_A"
# B / C: upstream を消した [gone]。B は MERGED 一覧側の OID が null、C は一覧に無い
for f25_name in "$F25_B" "$F25_C"; do
  SKIP_SIMPLE_GIT_HOOKS=1 git push -qu origin "$f25_name"
  SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin --delete "$f25_name"
done
# D: origin の取り残し（MERGED 一覧と (名前, OID) 一致）。設定保護パターンで止める
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_F25_D:refs/heads/$F25_D"
git branch -q -D "$F25_D"
git branch -q -D "$F25_E"
jq --arg b "$F25_B" --arg d "$F25_D" --arg od "$OID_F25_D" --arg e "$F25_E" --arg oe "$OID_F25_E" \
  '. + [{headRefName: $b, headRefOid: null, isCrossRepository: false},
        {headRefName: $d, headRefOid: $od, isCrossRepository: false},
        {headRefName: $e, headRefOid: $oe, isCrossRepository: false}]' \
  "$MOCK/pr_list_merged.json" > "$MOCK/pr_list_merged.f25" && mv "$MOCK/pr_list_merged.f25" "$MOCK/pr_list_merged.json"
for f25_pr in 90:"$F25_A" 91:"$F25_E"; do
  jq -n --arg h "${f25_pr#*:}" '{state: "MERGED", headRefName: $h, headRefOid: null, baseRefName: "develop",
    title: "headRefOid is null (quoting case)", isCrossRepository: false}' > "$MOCK/pr_view_${f25_pr%%:*}.json"
done

set +e
FF_MERGE_CLEANUP_PROTECT_BRANCHES='release/*:q/f25-d*' \
  PATH="$MOCK:$PATH" bash "$TARGET" 90 > "$TMP/run-f25.log" 2>&1
EXIT_F25=$?
# E: Step 6 で削除を試みて失敗させる。取り残しとして拾われないよう run の直前に push する
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_F25_E:refs/heads/$F25_E"
: > "$TMP/f25-push-fail.enabled"
PATH="$MOCK:$PATH" bash "$TARGET" 91 > "$TMP/run-f25e.log" 2>&1
EXIT_F25E=$?
rm -f "$TMP/f25-push-fail.enabled"
set -e

# 案内されたコマンドを、git を argv の記録だけにするスタブの下で実行する
F25_STUB="$TMP/f25-stub"
mkdir -p "$F25_STUB/bin" "$F25_STUB/cwd"
cat > "$F25_STUB/bin/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$F25_ARGV"
STUB
chmod +x "$F25_STUB/bin/git"
# 案内の形は 2 つ: 字下げした行にコマンドだけを置く形（前置きは空）と、失敗の要約行の末尾に
# 「…のコマンド: 」の後ろへ置く形
f25_check() { # <ケース名> <ログ> <行を選ぶ固定文字列> <前置き（空 = 字下げしたコマンドの行）> <期待する argv...>
  local name="$1" log="$2" pick="$3" lead="$4" line="" cmd=""
  shift 4
  if [ -z "$lead" ]; then
    line="$(grep -F -- "$pick" "$log" | grep -E '^ +git ' | head -1 || true)"
    cmd="${line#"${line%%[! ]*}"}"
  else
    line="$(grep -F -- "$pick" "$log" | grep -F -- "$lead" | head -1 || true)"
    cmd="${line#*"$lead"}"
  fi
  if [ -z "$line" ] || [ -z "$cmd" ]; then
    bad "$name: 案内のコマンドがログにありません（前置き: ${lead:-字下げした git の行}）"
    grep -F -- "$pick" "$log" | sed 's/^/    | /' | head -6 >&2 || true
    return
  fi
  rm -f "$F25_STUB/argv" "$F25_STUB/cwd/f25-sent"
  (cd "$F25_STUB/cwd" && F25_ARGV="$F25_STUB/argv" PATH="$F25_STUB/bin:$PATH" bash -c "$cmd") >/dev/null 2>&1 || true
  if [ -e "$F25_STUB/cwd/f25-sent" ]; then
    bad "$name: ブランチ名の中のコマンドが実行されました: ${cmd}"
  elif [ -f "$F25_STUB/argv" ] && cmp -s "$F25_STUB/argv" <(printf '%s\0' "$@"); then
    ok "$name: 案内のコマンドはブランチ名を 1 語のリテラルとして渡す"
  else
    bad "$name: 案内のコマンドの argv がブランチ名と一致しません: ${cmd}"
    printf '    | 実際: %s\n' "$(tr '\000' '|' < "$F25_STUB/argv" 2>/dev/null)" >&2
    printf '    | 期待: %s\n' "$(printf '%s|' "$@")" >&2
  fi
}
f25_check "47.1 OID 欠損の削除案内（Step 4）" "$TMP/run-f25.log" "q/f25-a-" "" \
  push origin "--force-with-lease=refs/heads/$F25_A:$OID_F25_A" ":refs/heads/$F25_A"
f25_check "47.2 OID 欠損の失敗行（Step 8）" "$TMP/run-f25.log" "  - $F25_A: headRefOid を取得できず" "削除のコマンド: " \
  push origin "--force-with-lease=refs/heads/$F25_A:$OID_F25_A" ":refs/heads/$F25_A"
f25_check "47.3 MERGED 一覧側の OID が null の [gone]（Step 5）" "$TMP/run-f25.log" "q/f25-b-" "" \
  branch -D "$F25_B"
f25_check "47.4 OID 不一致の [gone]（Step 5）" "$TMP/run-f25.log" "q/f25-c-" "" \
  branch -D "$F25_C"
f25_check "47.5 設定保護パターンの取り残し（Step 6）" "$TMP/run-f25.log" "q/f25-d-" "" \
  push origin "--force-with-lease=refs/heads/$F25_D:$OID_F25_D" ":refs/heads/$F25_D"
f25_check "47.6 headRefOid 無しの削除失敗行（Step 6 / Step 8）" "$TMP/run-f25e.log" "  - $F25_E: リモート削除失敗" "再試行のコマンド: " \
  push origin "--force-with-lease=refs/heads/$F25_E:$OID_F25_E" ":refs/heads/$F25_E"
if [ "$EXIT_F25" -eq 2 ] && [ "$EXIT_F25E" -eq 2 ]; then
  ok "47.7 引用のケースは削除しなかった項目を PARTIAL（exit 2）として報告する"
else
  bad "47.7 引用のケースの終了コードが期待と違う (exit=$EXIT_F25 / $EXIT_F25E)"
fi
# 後続のケースへ漏らさない（origin・ローカルに残した ref を消す）
for f25_name in "$F25_A" "$F25_D" "$F25_E"; do
  SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin --delete "$f25_name" 2>/dev/null || true
done
for f25_name in "$F25_B" "$F25_C"; do
  git branch -q -D "$f25_name" 2>/dev/null || true
done

# suite-cases-end: pr-matching-and-protection.sh
