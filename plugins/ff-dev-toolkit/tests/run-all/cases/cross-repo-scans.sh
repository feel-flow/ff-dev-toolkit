# shellcheck shell=bash
# RUN_OUT / RUN_RC は source 元の verify.sh の expect_* が読む（このファイル単体では未使用に見える）
# shellcheck disable=SC2034
# pipefail-inherited: verify.sh が set -euo pipefail の下で source する
# case 43・45・46・47: 横断走査と変更ベースの部分ゲート
#
# verify.sh から source される（ok / bad / expect_* / run_runner / RUN_OUT / RUN_RC / RUNNER / TESTS_DIR を共有）。
# 読む順序は verify.sh の一覧が正本で、前の cases の fixture と関数を後ろの cases が使う（Issue `#2696`）。

echo ""
echo "== case 43: node --test の reporter 未固定を横断で検出する =="

# `node --test` の既定 reporter は stdout が TTY かどうかで変わり（TTY=spec / pipe=TAP）、
# しかも Node の版で既定が動く。出力を文字列照合する検査はこの差でそのまま壊れ、「手元で
# 緑・CI で赤」と「CI で偽の緑」の両方が成立する。既定が spec の環境では pin を外す変異が
# 緑になるため**振る舞いテストでは回帰ガードを作れない**（ACE-307-2 と同型）。静的に縛る。
# 実装の正本は tests/lib/node-test-reporter.sh。

NT_LIB="$SCRIPT_DIR/../lib/node-test-reporter.sh"
[ -f "$NT_LIB" ] || { echo "✗ run-all verify: node --test reporter ガードが見つかりません: $NT_LIB" >&2; exit 1; }
# 出力タグは契約（docs/04-quality/TESTING.md）が名前で参照する。実装に実在することを
# fail-closed で確かめてから、下のケースがこの名前をアサートする。
NT_TAG='node-test-unpinned'
/usr/bin/grep -qF -- "$NT_TAG" "$NT_LIB" \
  || { echo "✗ run-all verify: タグ「${NT_TAG}」が ${NT_LIB} に見つかりません（契約名と実装が drift）" >&2; exit 1; }
# shellcheck source=../lib/node-test-reporter.sh
. "$NT_LIB"

# 検出器の自己検証。probe は 2 分割で組み立てる — 1 行に直書きすると、本検査がこのファイル
# 自身を違反として拾う（case 11 と同じ理由）。
NT_CMD='node --test'
NT_Q="'"
NT_PROBE_BAD="${NT_CMD} \"\$dir\"/*.test.mjs"
NT_PROBE_PINNED="${NT_CMD} --test-reporter=spec \"\$dir\"/*.test.mjs"
NT_PROBE_ENV="FF_X=1 ${NT_CMD} \"\$dir\"/*.test.mjs"
NT_PROBE_CAPTURE="out=\"\$(${NT_CMD} \"\$dir\"/x.test.mjs)\""
NT_PROBE_CAPTURE_PINNED="out=\"\$(${NT_CMD} --test-reporter=spec \"\$dir\"/x.test.mjs)\""
NT_PROBE_SEMI="cd \"\$dir\" && ${NT_CMD} x.test.mjs"
NT_PROBE_IF="if ${NT_CMD} x.test.mjs; then :; fi"
NT_PROBE_NODEFLAG="node --experimental-test-coverage --test x.test.mjs"
NT_PROBE_NPX="npx ${NT_CMD} x.test.mjs"
NT_PROBE_VAR="\"\$NODE\" --test x.test.mjs"
NT_PROBE_PIN_QUOTED="${NT_CMD} \"--test-reporter=\$R\" x.test.mjs"
NT_PROBE_PIN_IN_COMMENT="${NT_CMD} x.test.mjs  # TODO --test-reporter=spec"
NT_PROBE_PIN_IN_DQ="${NT_CMD} x.test.mjs || echo \"use --test-reporter=spec\""
NT_PROBE_PIN_IN_SQ="${NT_CMD} x.test.mjs || echo ${NT_Q}use --test-reporter=spec${NT_Q}"
NT_PROBE_WORD_HASH="${NT_CMD} \${files[@]#./} --test-reporter=spec"
# パターン部も NT_CMD から組み立てる。${NT_Q} で引用が切れるため、リテラルで書くと
# この行自体が違反として拾われる（自己言及の永久赤）。
NT_PROBE_PATTERN="N=\"\$(grep -cE ${NT_Q}(^|[^a-z])${NT_CMD}( |\$)${NT_Q} \"\$F\" || true)\""
NT_PROBE_QUOTED="echo \"${NT_CMD} を回す\""
NT_PROBE_ECHO="echo ${NT_CMD} \"\$dir\"/*.test.mjs"
NT_PROBE_COMMENT="# ${NT_CMD} \"\$dir\"/*.test.mjs"
NT_PROBE_CONT="${NT_CMD} \\"
NT_PROBE_CONT="${NT_PROBE_CONT}
  --test-reporter=spec \"\$dir\"/*.test.mjs"
# 最終行がバックスラッシュ継続で終わるファイル（END フラッシュの経路）。
NT_PROBE_EOF="${NT_CMD} x.test.mjs \\"

NT_SELFTEST_OK=1
nt_expect() { # $1: probe / $2: hit|nohit / $3: 成立時の名 / $4: 不成立時の名
  if _nt_out="$(printf '%s\n' "$1" | node_test_scan)"; then
    if [ "$2" = "hit" ]; then
      # タグと開始行番号まで固定する（空/非空だけだと、タグ名を変える退行が緑のまま通る）。
      case "$_nt_out" in
        1:"$NT_TAG":*) ok "$3" ;;
        "") bad "$4"; NT_SELFTEST_OK=0 ;;
        *) bad "$4（出力の形が違う: ${_nt_out%%$'\n'*}）"; NT_SELFTEST_OK=0 ;;
      esac
    else
      if [ -z "$_nt_out" ]; then ok "$3"; else bad "$4"; NT_SELFTEST_OK=0; fi
    fi
  else
    bad "node_test_scan を実行できません（$4）"
    NT_SELFTEST_OK=0
  fi
}

nt_expect "$NT_PROBE_BAD" hit \
  "検出器が reporter 未固定の起動を検出できる（self-test）" \
  "検出器が reporter 未固定の起動を検出できない — 横断検査は空振りするため実行しない"
nt_expect "$NT_PROBE_ENV" hit \
  "検出器が環境変数を前置きした起動も検出できる（self-test）" \
  "検出器が環境変数前置きの起動を取りこぼす（実在する唯一の形がこれだった）"
nt_expect "$NT_PROBE_CAPTURE" hit \
  "検出器が出力を捕捉する起動を検出できる（self-test）" \
  "検出器が出力捕捉の起動を取りこぼす — 捕捉こそ stdout が pipe になる形で、この契約が狙う当のハザード"
nt_expect "$NT_PROBE_SEMI" hit \
  "検出器が行の先頭語でない起動を検出できる（self-test）" \
  "検出器が && 連結の右辺を取りこぼす — 局所ガードより検出力が低い"
nt_expect "$NT_PROBE_IF" hit \
  "検出器が if 条件部の起動を検出できる（self-test）" \
  "検出器が制御構文のキーワードで起動を見失う"
nt_expect "$NT_PROBE_NODEFLAG" hit \
  "検出器が node 側フラグを挟んだ起動を検出できる（self-test）" \
  "検出器が --test の隣接を要求している — フラグ 1 つで pin 要求を回避できる"
nt_expect "$NT_PROBE_NPX" hit \
  "検出器がパッケージランナー経由の起動を検出できる（self-test）" \
  "検出器が npx / pnpm exec 経由を取りこぼす"
nt_expect "$NT_PROBE_VAR" hit \
  "検出器が変数で起動する形を検出できる（self-test）" \
  "検出器が変数経由を取りこぼす — 変数 1 つで pin 要求を回避できる"
nt_expect "$NT_PROBE_PIN_IN_COMMENT" hit \
  "検出器がコメント内の pin 言及を pin と数えない（self-test）" \
  "検出器がコメントの言及を pin と誤認する"
nt_expect "$NT_PROBE_PIN_IN_DQ" hit \
  "検出器が二重引用符内の pin 言及を pin と数えない（self-test）" \
  "検出器が文字列内の言及を pin と誤認する"
nt_expect "$NT_PROBE_PIN_IN_SQ" hit \
  "検出器が単一引用符内の pin 言及を pin と数えない（self-test）" \
  "検出器が文字列内の言及を pin と誤認する"
nt_expect "$NT_PROBE_PINNED" nohit \
  "検出器が pin 済みの起動を誤検出しない（self-test）" \
  "検出器が pin 済みを誤検出する — 直しようのない赤になる"
nt_expect "$NT_PROBE_CAPTURE_PINNED" nohit \
  "検出器が捕捉 + pin 済みを誤検出しない（self-test）" \
  "検出器が捕捉の中の pin を見落とす"
nt_expect "$NT_PROBE_PIN_QUOTED" nohit \
  "検出器が引用符で括った pin を誤検出しない（self-test）" \
  "検出器が伏せた版で pin を判定している — 変数を使った正当な pin が直しようのない赤になる"
nt_expect "$NT_PROBE_WORD_HASH" nohit \
  "検出器が語中の # をコメント開始と数えない（self-test）" \
  "検出器が \${files[@]#./} をコメント開始と読み、その後ろの pin を見失う"
nt_expect "$NT_PROBE_PATTERN" nohit \
  "検出器が置換内のパターン文字列を起動と数えない（self-test）" \
  "検出器が grep のパターン文字列を起動として拾う — 検出器自身を縛る検査が永久に赤くなる"
nt_expect "$NT_PROBE_CONT" nohit \
  "検出器がバックスラッシュ行継続をまたいだ pin を認識する（self-test）" \
  "検出器が行継続で pin を見失う — 折り返して書いた起動が直しようのない赤になる"
nt_expect "$NT_PROBE_QUOTED" nohit \
  "検出器が引用符の中の散文を起動と数えない（self-test）" \
  "検出器が散文を起動と数える — 検出器自身やテストの期待値で永久に赤くなる"
nt_expect "$NT_PROBE_ECHO" nohit \
  "検出器がコマンド語が node でない行を起動と数えない（self-test）" \
  "検出器が echo 経由の言及を起動と数える"
nt_expect "$NT_PROBE_COMMENT" nohit \
  "検出器がコメント行を起動と数えない（self-test）" \
  "検出器がコメントを起動と数える"
# 最終行が継続で終わるファイルは END でフラッシュしないと違反が黙って消える。
if _nt_eof="$(printf '%s\n' "$NT_PROBE_EOF" | node_test_scan)"; then
  case "$_nt_eof" in
    *"$NT_TAG"*) ok "検出器が末尾の行継続を END でフラッシュする（self-test）" ;;
    *) bad "検出器が末尾の行継続をフラッシュしない — ファイル末尾の違反が黙って消える"; NT_SELFTEST_OK=0 ;;
  esac
else
  bad "node_test_scan を実行できません（末尾フラッシュ）"; NT_SELFTEST_OK=0
fi

# batch-scan-regressions:start
# Batch controls exercise the real scanners with a fake tracked roster (no live git
# mutation). Successful batches must inspect the same files; failed batches stay red.
batch_scan_regressions() {
  local fx out rc calls fn mode expected
  fx="$(mktemp -d "${TMPDIR:-/tmp}/ff-batch-scan.XXXXXX")" || { bad "batch scan fixture を作れない"; return; }
  local FIXTURE_BATCH_ROOT="$fx" FIXTURE_BATCH_REAL_AWK
  FIXTURE_BATCH_REAL_AWK="$(command -v awk)"
  local FIXTURE_BATCH_AWK_FAIL="" FIXTURE_BATCH_EMPTY_LIST=0
  local FF_NODE_TEST_GIT="$fx/git-stub" FF_EXIT_CODE_GIT="$fx/git-stub"
  local FF_NODE_TEST_AWK="$fx/awk-stub" FF_EXIT_CODE_AWK="$fx/awk-stub"
  export FIXTURE_BATCH_ROOT FIXTURE_BATCH_REAL_AWK FIXTURE_BATCH_AWK_FAIL FIXTURE_BATCH_EMPTY_LIST
  export FF_NODE_TEST_GIT FF_EXIT_CODE_GIT FF_NODE_TEST_AWK FF_EXIT_CODE_AWK
  cat >"$fx/git-stub" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *' rev-parse '*) printf '%s\n' "$FIXTURE_BATCH_ROOT" ;;
  *' ls-files '*)
    [ "$FIXTURE_BATCH_EMPTY_LIST" = 0 ] || exit 0
    while IFS= read -r file; do
      case " $* " in *' -z '*) printf '%s\0' "$file" ;; *) printf '%s\n' "$file" ;; esac
    done <"$FIXTURE_BATCH_ROOT/roster"
    ;;
  *) exit 97 ;;
esac
EOF
  cat >"$fx/awk-stub" <<'EOF'
#!/usr/bin/env bash
n=0
for arg in "$@"; do
  case "$arg" in "$FIXTURE_BATCH_ROOT"/*) n=$((n + 1)) ;; esac
done
printf '%s\n' "$n" >>"$FIXTURE_BATCH_ROOT/calls"
case "$FIXTURE_BATCH_AWK_FAIL" in
  always) exit 23 ;;
  batch) [ "$n" -le 1 ] || exit 23 ;;
esac
exec "$FIXTURE_BATCH_REAL_AWK" "$@"
EOF
  chmod +x "$fx/git-stub" "$fx/awk-stub"
  printf '%s\n' a.sh b.sh SKILL.md >"$fx/roster"
  printf ':\n' >"$fx/a.sh"
  printf ':' >"$fx/b.sh"
  printf '%s\n' '```bash' ':' '```' >"$fx/SKILL.md"
  for fn in node_test_check_tracked exit_code_check_tracked; do
    : >"$fx/calls"
    rc=0; out="$($fn "$fx" 2>"$fx/err")" || rc=$?
    calls="$(cat "$fx/calls")"
    if [ "$fn" = node_test_check_tracked ]; then
      expected='NODE_TEST_RESULT=ok SCANNED=2 HITS=0 ERRORS=0 SKIPPED=0'
      mode=2
    else
      expected='EXIT_CODE_RESULT=ok SCANNED=3 HITS=0 ERRORS=0 SKIPPED=0'
      mode=$'2\n1'
    fi
    if [ "$rc" -eq 0 ] && [ "$out" = "$expected" ] && [ "$calls" = "$mode" ]; then
      ok "$fn: 正常な全対象を種別ごとの一括走査で検証（改行なし最終行も含む）"
    else
      bad "$fn: 一括走査の結果・対象件数・起動数が不正: rc=$rc out=[$out] calls=[$calls]"
    fi
    for FIXTURE_BATCH_AWK_FAIL in batch always; do
      rc=0; out="$($fn "$fx" 2>"$fx/err")" || rc=$?
      if [ "$rc" -ne 0 ] && [[ "$out" == *'_RESULT=error_scan '* ]] && [[ "$out" == *'ERRORS=1 '* ]]; then
        ok "$fn: 走査器エラー（${FIXTURE_BATCH_AWK_FAIL}）を個別再走査後も保持"
      else
        bad "$fn: 走査器エラー（${FIXTURE_BATCH_AWK_FAIL}）が消えた: rc=$rc out=[$out]"
      fi
    done
    FIXTURE_BATCH_AWK_FAIL=""
    FIXTURE_BATCH_EMPTY_LIST=1
    : >"$fx/calls"
    rc=0; out="$($fn "$fx" 2>"$fx/err")" || rc=$?
    if [ "$rc" -ne 0 ] && [[ "$out" == *'_RESULT=error_list '* ]] && [ ! -s "$fx/calls" ]; then
      ok "$fn: 空の tracked 一覧は未走査のまま拒否"
    else
      bad "$fn: 空一覧が緑、または stdin を走査した: rc=$rc out=[$out]"
    fi
    FIXTURE_BATCH_EMPTY_LIST=0
  done

  # A following file must not supply a reporter pin or consume a prior file's rc.
  printf '%s\n' 'node --test x \' >"$fx/a.sh"
  : >"$fx/empty.sh"
  printf '%s' '--test-reporter=spec' >"$fx/b.sh"
  rc=0; out="$(node_test_scan "$fx/a.sh" "$fx/empty.sh" "$fx/b.sh")" || rc=$?
  if [ "$rc" -eq 0 ] && [[ "$out" == '1:node-test-unpinned:'* ]]; then
    ok "Node scan: 空ファイルを挟んでも前ファイルの末尾継続を独立して検査"
  else
    bad "Node scan: 次のファイルの pin が前のファイルの違反を隠した: [$out]"
  fi
  printf '%s\n' 'bash tests/run-all.sh' 'rc=$?' 'echo done' >"$fx/a.sh"
  printf '%s' 'exit $rc' >"$fx/b.sh"
  rc=0; out="$(exit_code_scan "$fx/a.sh" "$fx/empty.sh" "$fx/b.sh")" || rc=$?
  if [ "$rc" -eq 0 ] && [[ "$out" == *'gate-exit-dropped:'* ]]; then
    ok "Exit-code scan: 次のファイルは前ファイルが持ち越した rc を消費しない"
  else
    bad "Exit-code scan: ファイル境界で未伝播の rc が隠れた: [$out]"
  fi
  printf '%s\n' 'bash tests/run-all.sh' 'rc=$?' 'exit $rc' >"$fx/a.sh"
  printf '%s' 'echo done' >"$fx/b.sh"
  rc=0; out="$(exit_code_scan "$fx/a.sh" "$fx/empty.sh" "$fx/b.sh")" || rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    ok "Exit-code scan: 同一ファイル内で伝播した rc は後続ファイルへ持ち越さない"
  else
    bad "Exit-code scan: 伝播済みの状態がファイル境界を越えた: [$out]"
  fi

  # Force each scanner's hit path and preserve the original filename diagnostics.
  for fn in node_test_check_tracked exit_code_check_tracked; do
    if [ "$fn" = node_test_check_tracked ]; then
      printf '%s' 'node --test x' >"$fx/a.sh"
    else
      printf '%s' 'bash tests/run-all.sh; echo done' >"$fx/a.sh"
    fi
    rc=0; out="$($fn "$fx" 2>"$fx/err")" || rc=$?
    if [ "$rc" -ne 0 ] && [[ "$out" == *'_RESULT=hits '* ]] && grep -F 'a.sh:' "$fx/err" >/dev/null; then
      ok "$fn: 一括検出した違反を個別走査で元ファイルへ帰属させる"
    else
      bad "$fn: 違反の終了コードまたはファイル名が消えた: rc=$rc out=[$out]"
    fi
    printf ':\n' >"$fx/a.sh"
    chmod 000 "$fx/a.sh"
    if [ -r "$fx/a.sh" ]; then
      echo "  ○ skip: $fn の未読 probe は chmod 000 でも読める環境のため未実施"
    else
      rc=0; out="$($fn "$fx" 2>"$fx/err")" || rc=$?
      if [ "$rc" -ne 0 ] && [[ "$out" == *'_RESULT=error_scan '* ]] && grep -F 'a.sh (unreadable)' "$fx/err" >/dev/null; then
        ok "$fn: 読めない対象を一括成功へ混ぜない"
      else
        bad "$fn: 読めない対象の検査が成立しない: rc=$rc out=[$out]"
      fi
    fi
    chmod 644 "$fx/a.sh"
    printf '%s\n' missing.sh >"$fx/roster"
    : >"$fx/calls"
    rc=0; out="$($fn "$fx" 2>"$fx/err")" || rc=$?
    if [ "$rc" -eq 0 ] && [[ "$out" == *'_RESULT=ok SCANNED=0 '*'SKIPPED=1' ]] && [ ! -s "$fx/calls" ]; then
      ok "$fn: 実体の無い対象は未走査を報告し、空配列で stdin を読まない"
    else
      bad "$fn: 欠損対象を走査済みとした: rc=$rc out=[$out]"
    fi
    printf '%s\n' a.sh b.sh SKILL.md >"$fx/roster"
  done
  # Reuse every existing scanner probe to compare exact per-file output with the
  # corresponding batch. This includes malformed endings and stateful rc probes.
  local scanner prefix probe part_rc
  local -a probe_files=()
  for mode in node sh md; do
    probe_files=()
    case "$mode" in
      node) scanner=node_test_scan; prefix=NT_PROBE_ ;;
      sh) scanner=exit_code_scan; prefix=EXITCODE_PROBE_ ;;
      md) scanner=exit_code_scan_bash_blocks; prefix=EXITCODE_PROBE_MD_ ;;
    esac
    : >"$fx/single.out"
    rc=0
    while IFS= read -r probe; do
      case "$mode:$probe" in sh:EXITCODE_PROBE_MD_*) continue ;; esac
      printf '%s\n' "${!probe}" >"$fx/$probe"
      probe_files+=("$fx/$probe")
      part_rc=0
      "$scanner" "$fx/$probe" >>"$fx/single.out" || part_rc=$?
      [ "$part_rc" -eq 0 ] || rc=$part_rc
    done < <(compgen -A variable "$prefix")
    if [ "${#probe_files[@]}" -eq 0 ]; then
      bad "$scanner: 既存 probe 集合が空（比較不成立）"
      continue
    fi
    "$scanner" "${probe_files[@]}" >"$fx/batch.out" || rc=$?
    if [ "$rc" -eq 0 ] && cmp -s "$fx/single.out" "$fx/batch.out"; then
      ok "$scanner: 既存 probe ${#probe_files[@]} 件の単独走査と一括走査の出力が一致"
    else
      bad "$scanner: 既存 probe の単独・一括走査が不一致（rc=${rc}）"
    fi
  done
  rm -rf "$fx"
}
batch_scan_regressions
# batch-scan-regressions:end

if [ "$NT_SELFTEST_OK" -eq 1 ]; then
  NT_REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || NT_REPO_ROOT=""
  if [ -z "$NT_REPO_ROOT" ]; then
    bad "リポジトリルートを解決できない（git rev-parse 失敗）— 横断検査を実行できない"
  else
    set +e
    NT_SUMMARY="$(node_test_check_tracked "$NT_REPO_ROOT" 2>/dev/null)"
    set -e
    case "$NT_SUMMARY" in
      NODE_TEST_RESULT=ok\ *)
        NT_SCANNED="$(printf '%s\n' "$NT_SUMMARY" | sed -E 's/.*SCANNED=([0-9]+).*/\1/')"
        # 走査 0 件は「違反 0 件」の根拠にならないし、**下限では対象集合の縮小を捕まえられない**
        # （shebang 判定を落とす変異で 282 → 255 になっても、緩い下限なら通る。実測で生存した）。
        # 対象集合を**独立に数えて一致**を要求する。予測子は tests/shellcheck/verify.sh の
        # SHEBANG_RE と同じ形で、2 つのガードが同じ集合を別定義で持つ drift もここで赤になる。
        NT_EXPECT=0
        while IFS= read -r _nt_f; do
          [ -n "$_nt_f" ] || continue
          [ -f "$NT_REPO_ROOT/$_nt_f" ] || continue
          case "$_nt_f" in
            *.sh) NT_EXPECT=$((NT_EXPECT + 1)); continue ;;
          esac
          _nt_first=""
          IFS= read -r _nt_first < "$NT_REPO_ROOT/$_nt_f" || true
          case "$_nt_first" in
            '#!'*[/\ ]sh|'#!'*[/\ ]sh' '*|'#!'*[/\ ]bash|'#!'*[/\ ]bash' '*|'#!'*[/\ ]dash|'#!'*[/\ ]dash' '*|'#!'*[/\ ]ksh|'#!'*[/\ ]ksh' '*) NT_EXPECT=$((NT_EXPECT + 1)) ;;
          esac
        done < <(git -C "$NT_REPO_ROOT" -c core.quotepath=false ls-files)
        if [ "${NT_SCANNED:-0}" -lt 1 ]; then
          bad "走査対象が 0 件 — 違反 0 件を主張できない"
        elif [ "${NT_SCANNED:-0}" -eq "$NT_EXPECT" ]; then
          ok "tracked shell の node --test はすべて reporter を固定している（${NT_SCANNED} ファイル走査・独立集計と一致）"
        else
          bad "走査対象の件数が独立集計と一致しない（走査 ${NT_SCANNED} / 期待 ${NT_EXPECT}）— 対象集合が黙って縮んでいる"
        fi
        ;;
      NODE_TEST_RESULT=hits\ *)
        bad "reporter を固定しない node --test が混入した"
        node_test_check_tracked "$NT_REPO_ROOT" >/dev/null || true
        ;;
      NODE_TEST_RESULT=error_repo\ *)
        bad "リポジトリルートを解決できない（git rev-parse 失敗）— 横断検査を実行できない"
        ;;
      NODE_TEST_RESULT=error_list\ *)
        bad "検査対象の tracked ファイル一覧を取得できない（git ls-files 失敗/空）— 0 件の主張はできない"
        ;;
      NODE_TEST_RESULT=error_scan\ *)
        bad "走査に失敗したファイルがある — そのファイルの 0 件は主張できない"
        node_test_check_tracked "$NT_REPO_ROOT" >/dev/null || true
        ;;
      *)
        bad "横断検査のサマリーを解釈できない（実際: ${NT_SUMMARY}）"
        ;;
    esac

    # 集約層（scan → all_hits → result=hits → rc=1）と、利用者へ届く stderr を隔離 fixture で
    # 実測する。実リポジトリの ok だけを見る形では、集約を no-op 化する変異が緑のまま通る。
    if ! command -v git >/dev/null 2>&1; then
      echo "  ○ skip: git が無いため横断検査の hits / fail-closed 経路をスキップ（この検査は 1 件も実行していません）"
    else
      _nt_fx="$RUN_WORK/ff-node-test-guard"
      rm -rf "$_nt_fx"; mkdir -p "$_nt_fx"
      printf '%s\n' '#!/usr/bin/env bash' "$NT_PROBE_BAD" > "$_nt_fx/violate.sh"
      _nt_git() { git -c commit.gpgsign=false -c user.email=t@example.invalid -c user.name=T -c init.defaultBranch=main "$@"; }
      _nt_setup=0
      _nt_git -C "$_nt_fx" init -q . >/dev/null 2>&1 || _nt_setup=1
      _nt_git -C "$_nt_fx" add -A >/dev/null 2>&1 || _nt_setup=1
      _nt_git -C "$_nt_fx" commit -qm fixture >/dev/null 2>&1 || _nt_setup=1
      if [ "$_nt_setup" -ne 0 ]; then
        bad "横断検査 hits 経路の git fixture を作れない（検査が成立していない）"
      else
        set +e
        _nt_err="$(node_test_check_tracked "$_nt_fx" 2>&1 >/dev/null)"
        _nt_sum="$(node_test_check_tracked "$_nt_fx" 2>/dev/null)"
        _nt_rc=$?
        set -e
        case "$_nt_sum" in
          NODE_TEST_RESULT=hits\ *) ok "横断検査は違反入り fixture で hits へ倒れる（集約層）" ;;
          *) bad "横断検査が違反を hits にしない（実際: ${_nt_sum}）— 集約を no-op 化する変異が通る" ;;
        esac
        if [ "$_nt_rc" -ne 0 ]; then ok "横断検査は違反ありで非 0 を返す"; else bad "横断検査が違反ありでも 0 を返す"; fi
        for _nt_needle in "$NT_TAG" '--test-reporter=spec' '照合の有無は静的に決められず'; do
          case "$_nt_err" in
            *"$_nt_needle"*) ok "横断検査の stderr が「${_nt_needle}」を含む" ;;
            *) bad "横断検査の stderr から「${_nt_needle}」が消えている（タグだけでは直し方が伝わらない）" ;;
          esac
        done
        # fail-closed の 3 経路。テストシームが用意されているのに使われていないと、
        # 「0 件」を主張できない状態を素通りさせる変異が緑で通る。
        printf '%s\n' '#!/usr/bin/env bash' 'exit 3' > "$_nt_fx/git-stub"
        chmod +x "$_nt_fx/git-stub"
        set +e
        _nt_s1="$(FF_NODE_TEST_GIT="$_nt_fx/git-stub" node_test_check_tracked "$_nt_fx" 2>/dev/null)"
        printf '%s\n' '#!/usr/bin/env bash' 'exit 9' > "$_nt_fx/awk-stub"
        chmod +x "$_nt_fx/awk-stub"
        _nt_s2="$(FF_NODE_TEST_AWK="$_nt_fx/awk-stub" node_test_check_tracked "$_nt_fx" 2>/dev/null)"
        set -e
        case "$_nt_s1" in
          NODE_TEST_RESULT=error_repo\ *) ok "git が使えない回は error_repo（0 件を主張しない）" ;;
          *) bad "git が使えない回に error_repo を返さない（実際: ${_nt_s1}）" ;;
        esac
        case "$_nt_s2" in
          NODE_TEST_RESULT=error_scan\ *) ok "走査器が壊れている回は error_scan（0 件を主張しない）" ;;
          *) bad "走査器が壊れている回に error_scan を返さない（実際: ${_nt_s2}）" ;;
        esac
        # tracked 一覧が空の回。ここを ok へ倒す変異は「走査 0 件なのに違反 0 件」を主張させる
        # 典型的な fail-open で、実測で生存した経路でもある。
        _nt_empty="$_nt_fx/empty"
        mkdir -p "$_nt_empty"
        _nt_git -C "$_nt_empty" init -q . >/dev/null 2>&1 || true
        set +e
        _nt_s3="$(node_test_check_tracked "$_nt_empty" 2>/dev/null)"
        _nt_rc3=$?
        set -e
        case "$_nt_s3" in
          NODE_TEST_RESULT=error_list\ *) ok "tracked 一覧が空の回は error_list（0 件を主張しない）" ;;
          *) bad "tracked 一覧が空の回に error_list を返さない（実際: ${_nt_s3}）— 走査 0 件で緑になる" ;;
        esac
        if [ "$_nt_rc3" -ne 0 ]; then ok "tracked 一覧が空の回は非 0 を返す"; else bad "tracked 一覧が空でも 0 を返す"; fi
      fi
      rm -rf "$_nt_fx"
    fi
  fi
fi

echo ""
echo "== case 45: suite 単位の経過秒 =="

# 45-A: 実行した suite だけが登録順で elapsed-sec に載り、未実行は載せない。
# 秒の値は date +%s の整数差なので、即終了 fixture でも秒境界で 1 になりうる。
# 集合と並びだけを固定し、0 秒前提の完全一致は置かない。
RUN_JOBS=1 run_runner "${MIXED_FIXTURES[@]}"
expect_has '^elapsed-sec: fail=[0-9][0-9]* pass=[0-9][0-9]* skip=[0-9][0-9]*$' \
  "elapsed-sec は実行した suite だけを登録順で出す（未実行は混ぜない）"
expect_lacks 'not-executable=' "実行ビットの無い suite を elapsed-sec に載せない"
expect_lacks 'missing=' "存在しない suite を elapsed-sec に載せない"

# 45-B: 2 秒かかる suite は逐次でも 1 以上。fixture を 2 秒にしてあるのは壁時計の巻き戻しの余裕
# （fixtures/slow-a/verify.sh の冒頭。Issue `#2062`）。判定を「1 以上」から緩めない — 0 を出す退行を
# 捕まえるのはこの下限だけ。
RUN_JOBS=1 run_runner "$FIXTURES/slow-a/verify.sh"
expect_rc 0 "2 秒かかる suite の逐次実行は rc=0"
_el_sec="$(printf '%s\n' "$RUN_OUT" | awk '/^elapsed-sec: / {
  for (i = 2; i <= NF; i++) if ($i ~ /^slow-a=/) { split($i, a, "="); print a[2] }
}')"
if [ -n "$_el_sec" ] && [ "$_el_sec" -ge 1 ] 2>/dev/null; then
  ok "逐次実行の elapsed-sec が slow-a を 1 秒以上で出す（${_el_sec}s）"
else
  bad "逐次実行の elapsed-sec が slow-a を 1 秒以上で出さない（値=${_el_sec:-空}）"
fi
expect_has '^slowest: slow-a=' "1 秒以上の suite がある回は slowest に載せる"

# 45-C: 並列経路でも 2 秒かかる suite を 1 秒以上で出し、4 本すべてが slowest に載る（同時実行数より多い本数）。
RUN_JOBS=2 run_runner \
  "$FIXTURES/slow-a/verify.sh" "$FIXTURES/slow-b/verify.sh" \
  "$FIXTURES/slow-c/verify.sh" "$FIXTURES/slow-d/verify.sh"
expect_rc 0 "並列実行で 4 本すべてが pass なら rc=0（経過秒の計測後も）"
expect_has '^elapsed-sec: slow-a=' "並列経路でも elapsed-sec が出る"
_el_all=1
for _el_name in slow-a slow-b slow-c slow-d; do
  _el_sec="$(printf '%s\n' "$RUN_OUT" | awk -v n="${_el_name}=" '/^elapsed-sec: / {
    for (i = 2; i <= NF; i++) if (index($i, n) == 1) { split($i, a, "="); print a[2] }
  }')"
  if [ -z "$_el_sec" ] || [ "$_el_sec" -lt 1 ] 2>/dev/null; then
    _el_all=0
  fi
done
if [ "$_el_all" -eq 1 ]; then
  ok "並列実行の elapsed-sec が 4 本すべてを 1 秒以上で出す"
else
  bad "並列実行の elapsed-sec が 4 本を 1 秒以上で出さない"
  printf '%s\n' "$RUN_OUT" | awk '/^elapsed-sec:|^slowest:/{print}' | sed 's/^/    | /' >&2
fi
expect_has '^slowest: ' "1 秒以上の suite が複数ある回は slowest 行を出す"
_el_slowest="$(printf '%s\n' "$RUN_OUT" | awk '/^slowest: /{print; exit}')"
_el_slowest_ok=1
for _el_name in slow-a slow-b slow-c slow-d; do
  case "$_el_slowest" in
    *"${_el_name}="*) ;;
    *) _el_slowest_ok=0 ;;
  esac
done
if [ "$_el_slowest_ok" -eq 1 ]; then
  ok "slowest に 2 秒かかる 4 本がすべて載る（上限 8）"
else
  bad "slowest に 4 本が揃っていない: ${_el_slowest}"
fi

# 45-D: 時計が取れない環境では計測行を出さず、終了コードは変えない。
if _el_stub="$(mktemp -d "${TMPDIR:-/tmp}/ff-elapsed-date.XXXXXX" 2>&1)" \
  && [ -d "$_el_stub" ]; then
  printf '%s\n' '#!/bin/sh' 'exit 1' > "$_el_stub/date"
  chmod +x "$_el_stub/date"
  _el_old_path="$PATH"
  PATH="${_el_stub}:${PATH}"
  RUN_JOBS=1 run_runner "$FIXTURES/pass/verify.sh"
  PATH="$_el_old_path"
  expect_rc 0 "時計が取れなくても実行の終了コードは変えない"
  expect_has '^suites: total=1 run=1 passed=1 failed=0 skipped=0 not-run=0$' \
    "時計不能でも既存のサマリー行は出す"
  expect_lacks '^elapsed-sec:' "時計が取れない回は elapsed-sec を出さない"
  expect_lacks '^slowest:' "時計が取れない回は slowest を出さない"
  rm -rf "$_el_stub"
else
  bad "case 45-D: 一時領域を作成できず、時計不能の経路を実測できません: ${_el_stub}"
fi

# 45-E: 計測行は指紋ブロックの外。内側へ移すと「サマリー行が出た ⟹ 指紋照合」の
# 構造的保証に計測の増減が割り込む。
_el_in_block="$(awk '
  /^# >>> ff-summary-head-block/ { grab = 1 }
  /^# <<< ff-summary-head-block/ { grab = 0 }
  grab && /elapsed-sec:|slowest:|ff_emit_elapsed/ { n++ }
  END { print n + 0 }
' "$RUNNER")"
if [ "$_el_in_block" -eq 0 ]; then
  ok "elapsed-sec / slowest / ff_emit_elapsed は ff-summary-head-block の外にある"
else
  bad "計測行または ff_emit_elapsed が指紋ブロックの内側にある（${_el_in_block} 件）"
fi
if [ "$(LC_ALL=C grep -c 'echo "elapsed-sec:' "$RUNNER")" -eq 1 ]; then
  ok "elapsed-sec の echo はランナーに 1 箇所だけある"
else
  bad "elapsed-sec の echo が 1 箇所ではない"
fi

# 45-F: 降順・0 秒除外・上限 8 を壁時計なしの合成入力で実測する。
# 9 件が 1 秒以上 + 0 秒 1 件。上限を外すと 9 件載り、ソートを外すと先頭が a=1、
# 0 秒除外を外すと c=0 が混ざる。
if _el_fx_out="$(env -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL \
  FF_RUN_ALL_ELAPSED_FIXTURE='a=1 b=9 c=0 d=3 e=8 f=2 g=7 h=4 i=6 j=5' \
  FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" bash "$RUNNER" \
  "$FIXTURES/pass/verify.sh" 2>&1)"; then
  _el_fx_rc=0
else
  _el_fx_rc=$?
fi
if [ "$_el_fx_rc" -eq 0 ]; then
  ok "合成 elapsed 入力の実行が rc=0"
else
  bad "合成 elapsed 入力の実行が非 0（rc=${_el_fx_rc}）"
fi
if [ "$(printf '%s\n' "$_el_fx_out" | awk '/^elapsed-sec: /{print; exit}')" = \
  "elapsed-sec: a=1 b=9 c=0 d=3 e=8 f=2 g=7 h=4 i=6 j=5" ]; then
  ok "合成入力の elapsed-sec は渡した順のまま出す"
else
  bad "合成入力の elapsed-sec が渡した順ではない"
  printf '%s\n' "$_el_fx_out" | awk '/^elapsed-sec:|^slowest:/{print}' | sed 's/^/    | /' >&2
fi
if [ "$(printf '%s\n' "$_el_fx_out" | awk '/^slowest: /{print; exit}')" = \
  "slowest: b=9 e=8 g=7 i=6 j=5 h=4 d=3 f=2" ]; then
  ok "slowest は 1 秒以上を降順・最大 8 件・0 秒は載せない（a=1 と c=0 が落ちる）"
else
  bad "slowest の降順・上限 8・0 秒除外が崩れている"
  printf '%s\n' "$_el_fx_out" | awk '/^elapsed-sec:|^slowest:/{print}' | sed 's/^/    | /' >&2
fi

echo ""
echo "== case 46: pipefail 配下の grep -q によるパイプの反転を横断で検出する =="

# `grep -q` は一致した時点で読むのをやめる。上流の printf / echo / cat が書き続けていると
# EPIPE で死に、`set -o pipefail` がその非 0 をパイプライン全体の終了コードにするので、
# **一致が「不一致」へ反転する**（否定形 `if ! … | grep -q` は偽の緑になる）。反転するのは
# payload が大きいときだけなので、小さい fixture を使う振る舞いテストでは回帰ガードを
# 作れない（case 43 と同型）。違反の形そのものを静的に縛る。
# 実装の正本は tests/lib/pipefail-grep-q.sh（禁止・代替・除外マーカーの規約もそこが正本）。
#
# 実行モード: 本 suite（run-all/verify.sh）は `-selftest` 対の片割れではないので、高速モード
# （既定）でも全件モード（FF_RUN_ALL_FULL=1）でも回る。case 43 と同じ扱いにしてある —
# 再混入は「次の誰か」が書いた瞬間に赤くしたいので、既定で回る側に置く。

PG_LIB="$SCRIPT_DIR/../lib/pipefail-grep-q.sh"
[ -f "$PG_LIB" ] || { echo "✗ run-all verify: pipefail/grep -q ガードが見つかりません: $PG_LIB" >&2; exit 1; }
# 出力タグは下のケースがアサートする契約名。実装に実在することを fail-closed で先に確かめる。
PG_TAG='pipefail-grep-q'
/usr/bin/grep -qF -- "$PG_TAG" "$PG_LIB" \
  || { echo "✗ run-all verify: タグ「${PG_TAG}」が ${PG_LIB} に見つかりません（契約名と実装が drift）" >&2; exit 1; }
# shellcheck source=../lib/pipefail-grep-q.sh
. "$PG_LIB"

# probe は部品から組み立てる。1 行に直書きすると、本検査がこのファイル自身を違反として
# 拾う（case 43 / case 11 と同じ理由）。とくにコマンド置換の probe は `$(` の隣接を
# 作らないこと — mask() が二重引用符の中の `$(` を置換として開くため、直書きすると
# 中身が走査対象になって永久に赤くなる。
PG_PF='set -euo pipefail'
PG_Q="'"
PG_PIPE='|'
PG_GQ='grep -q'
PG_DOLLAR='$'
PG_PROBE_BAD="if printf ${PG_Q}%s${PG_Q} \"\$s\" ${PG_PIPE} ${PG_GQ} X; then :; fi"
PG_PROBE_NEG="if ! printf ${PG_Q}%s${PG_Q} \"\$s\" ${PG_PIPE} grep -Eq X; then :; fi"
PG_PROBE_ECHO="echo \"\$s\" ${PG_PIPE} ${PG_GQ} X"
PG_PROBE_CAT="cat \"\$f\" ${PG_PIPE} grep -qF X"
PG_PROBE_FLAG="printf ${PG_Q}%s${PG_Q} \"\$s\" ${PG_PIPE} grep -qE X"
PG_PROBE_LONG="printf ${PG_Q}%s${PG_Q} \"\$s\" ${PG_PIPE} grep --quiet X"
PG_PROBE_MID="printf ${PG_Q}%s${PG_Q} \"\$s\" ${PG_PIPE} sed s/a/b/ ${PG_PIPE} ${PG_GQ} X"
PG_PROBE_SUBST="n=\"${PG_DOLLAR}(printf ${PG_Q}%s${PG_Q} \"\$s\" ${PG_PIPE} ${PG_GQ} X && echo y)\""
PG_PROBE_GREPC="n=\"${PG_DOLLAR}(printf ${PG_Q}%s${PG_Q} \"\$s\" ${PG_PIPE} grep -c X)\""
PG_PROBE_BARE="printf ${PG_Q}%s${PG_Q} \"\$s\" ${PG_PIPE} grep X"
PG_PROBE_HERE="${PG_GQ} X <<<\"\$s\""
PG_PROBE_FILE="${PG_GQ} X \"\$f\""
PG_PROBE_MARKER="printf ${PG_Q}%s${PG_Q} \"\$s\" ${PG_PIPE} ${PG_GQ} X  # pipefail-safe: 定数 1 行"
PG_PROBE_OR="printf ${PG_Q}%s${PG_Q} \"\$s\" ${PG_PIPE}${PG_PIPE} ${PG_GQ} X \"\$f\""
PG_PROBE_DQ="echo \"printf x ${PG_PIPE} ${PG_GQ} y\""
PG_PROBE_SQ="echo ${PG_Q}printf x ${PG_PIPE} ${PG_GQ} y${PG_Q}"
PG_PROBE_COMMENT="# printf x ${PG_PIPE} ${PG_GQ} y"
PG_BS='\'
PG_DQC='"'
# 1) mask() の escape 扱い: `\"` は引用符の終端ではない（hit 側は以前これを引用符の開始と
#    読んで後続の実パイプを伏せていた。nohit 側は逆に文字列の途中で閉じたと読んで拾っていた）。
PG_PROBE_ESCDQ="printf ${PG_DQC}a${PG_BS}${PG_DQC}b${PG_DQC} ${PG_PIPE} ${PG_GQ} x"
PG_PROBE_ESCDQ_OK="echo ${PG_DQC}a${PG_BS}${PG_DQC}b ${PG_PIPE} ${PG_GQ} y${PG_DQC}"
#    引用符の外の escape（`printf a\"b`）も同じ規則。こちらは二重引用符の中とは別の枝なので
#    probe を分ける（片方だけを無効化する変異が緑で通らないように）。
PG_PROBE_ESCBARE="printf a${PG_BS}${PG_DQC}b ${PG_PIPE} ${PG_GQ} x"
# 2) `&` の扱い: リダイレクトの `&` は境界にしない / `|&` はパイプ / 単独 `&` は境界。
PG_PROBE_REDIR="printf ${PG_Q}%s${PG_Q} \"\$s\" 2>&1 ${PG_PIPE} ${PG_GQ} x"
PG_PROBE_PIPEAMP="printf ${PG_Q}%s${PG_Q} \"\$s\" ${PG_PIPE}& ${PG_GQ} x"
PG_PROBE_BG="printf x & ${PG_GQ} y \"\$f\""
# 3) pipefail 設定の認識: 終端が空白でない形（`;` 等）でも拾う / 語の途中一致では拾わない。
PG_PROBE_PFSEMI="set -o pipefail; printf ${PG_Q}%s${PG_Q} \"\$s\" ${PG_PIPE} ${PG_GQ} x"
PG_PROBE_PFWORD="set -o pipefailx; printf ${PG_Q}%s${PG_Q} \"\$s\" ${PG_PIPE} ${PG_GQ} x"
# 4) 除外マーカーは実コメントで始まるものだけ（引用符の中の同文言では除外しない）。
PG_PROBE_MARKER_STR="printf ${PG_Q}%s${PG_Q} ${PG_DQC}# pipefail-safe: x${PG_DQC} ${PG_PIPE} ${PG_GQ} y"
# 5) 行末 `|` / `&&` の改行継続（バックスラッシュ無し）。
PG_PROBE_CONT_A="printf ${PG_Q}%s${PG_Q} \"\$s\" ${PG_PIPE}"
PG_PROBE_CONT_B="  ${PG_GQ} x"
PG_PROBE_CONT_OR_A="printf ${PG_Q}%s${PG_Q} \"\$s\" ${PG_PIPE}${PG_PIPE}"
PG_PROBE_CONT_OR_B="  ${PG_GQ} x \"\$f\""
# 6) コマンド語の前に来る env / sudo プレフィックス（tests/skill-bash-blocks/verify.sh と同じ規約）。
PG_PROBE_SUDO="printf ${PG_Q}%s${PG_Q} \"\$s\" ${PG_PIPE} sudo ${PG_GQ} x"
PG_PROBE_ENV="printf ${PG_Q}%s${PG_Q} \"\$s\" ${PG_PIPE} env ${PG_GQ} x"
PG_PROBE_ENVSRC="env ${PG_PIPE} ${PG_GQ} x"

PG_SELFTEST_OK=1
pg_expect_lines() { # $1: 入力全文（pipefail 行も呼び出し側が含める） / $2: hit|nohit / $3: 期待開始行 / $4: 成立時の名 / $5: 不成立時の名
  if _pg_out="$(printf '%s\n' "$1" | pipefail_grep_q_scan)"; then
    if [ "$2" = "hit" ]; then
      # タグと開始行番号まで固定する（空/非空だけだと、タグ名を変える退行が緑のまま通る）。
      case "$_pg_out" in
        "$3":"$PG_TAG":*) ok "$4" ;;
        "") bad "$5"; PG_SELFTEST_OK=0 ;;
        *) bad "$5（出力の形が違う: ${_pg_out%%$'\n'*}）"; PG_SELFTEST_OK=0 ;;
      esac
    else
      if [ -z "$_pg_out" ]; then ok "$4"; else bad "$5（出力: ${_pg_out%%$'\n'*}）"; PG_SELFTEST_OK=0; fi
    fi
  else
    bad "pipefail_grep_q_scan を実行できません（$5）"
    PG_SELFTEST_OK=0
  fi
}
pg_expect() { # $1: probe（1 行） / $2: hit|nohit / $3: 成立時の名 / $4: 不成立時の名
  # probe の前に pipefail 行を足して食わせる。違反行は 2 行目になる。
  pg_expect_lines "$PG_PF
$1" "$2" 2 "$3" "$4"
}

pg_expect "$PG_PROBE_BAD" hit \
  "検出器が printf を上流にした grep -q を検出できる（self-test）" \
  "検出器が違反の基本形を検出できない — 横断検査は空振りするため実行しない"
pg_expect "$PG_PROBE_NEG" hit \
  "検出器が否定形（偽の緑になる側）を検出できる（self-test）" \
  "検出器が否定形を取りこぼす — 偽の緑をそのまま見逃す、いちばん悪い取りこぼし"
pg_expect "$PG_PROBE_ECHO" hit \
  "検出器が echo を上流にした形も検出できる（self-test）" \
  "検出器が echo 経由を取りこぼす — printf から echo への言い換えが抜け道になる"
pg_expect "$PG_PROBE_CAT" hit \
  "検出器が cat を上流にした形も検出できる（self-test）" \
  "検出器が cat 経由を取りこぼす — printf から cat への言い換えが抜け道になる"
pg_expect "$PG_PROBE_FLAG" hit \
  "検出器がフラグ結合（-qE）の grep を検出できる（self-test）" \
  "検出器が -q の単独表記だけを見ている — フラグを 1 つ束ねるだけで回避できる"
pg_expect "$PG_PROBE_LONG" hit \
  "検出器が長形 --quiet を検出できる（self-test）" \
  "検出器が長形を取りこぼす — --quiet への言い換えが抜け道になる"
pg_expect "$PG_PROBE_MID" hit \
  "検出器が中間フィルタを挟んだ形も検出できる（self-test）" \
  "検出器が直前の 1 区間しか見ていない — sed を 1 つ挟むだけで回避できる（上流は同じく死ぬ）"
pg_expect "$PG_PROBE_SUBST" hit \
  "検出器がコマンド置換の中の違反を検出できる（self-test）" \
  "検出器が置換の中を見ていない — 捕捉して使う形が丸ごと無検査になる"
pg_expect "$PG_PROBE_GREPC" nohit \
  "検出器が grep -c を誤検出しない（self-test）" \
  "検出器が grep -c を拾う — 入力を読み切る形は言い換え先の 1 つで、直しようのない赤になる"
pg_expect "$PG_PROBE_BARE" nohit \
  "検出器が grep 単独を誤検出しない（self-test）" \
  "検出器が grep 単独を拾う — 入力を読み切る形は反転しない"
pg_expect "$PG_PROBE_HERE" nohit \
  "検出器が here-string の grep -q を誤検出しない（self-test）" \
  "検出器が here-string を拾う — 第一の言い換え先が直しようのない赤になる"
pg_expect "$PG_PROBE_FILE" nohit \
  "検出器がファイルを直接渡す grep -q を誤検出しない（self-test）" \
  "検出器がファイル引数の grep -q を拾う — 上流プロセスが無いので反転しない"
pg_expect "$PG_PROBE_MARKER" nohit \
  "検出器が行末マーカーによる除外宣言を尊重する（self-test）" \
  "検出器が pipefail-safe マーカーを無視する — 根拠付きの例外を宣言できない"
pg_expect "$PG_PROBE_OR" nohit \
  "検出器が || をパイプと数えない（self-test）" \
  "検出器が論理和をパイプと読む — 無関係な行が直しようのない赤になる"
pg_expect "$PG_PROBE_DQ" nohit \
  "検出器が二重引用符の中の散文を違反と数えない（self-test）" \
  "検出器が文字列内の言及を拾う — 検出器自身やテストの期待値で永久に赤くなる"
pg_expect "$PG_PROBE_SQ" nohit \
  "検出器が単一引用符の中の散文を違反と数えない（self-test）" \
  "検出器が文字列内の言及を拾う — 検出器自身やテストの期待値で永久に赤くなる"
pg_expect "$PG_PROBE_COMMENT" nohit \
  "検出器がコメント行を違反と数えない（self-test）" \
  "検出器がコメントの言及を拾う — 禁止イディオムを明文化した注記が赤になる"

pg_expect "$PG_PROBE_ESCDQ" hit \
  "検出器が escape された二重引用符を引用符の終端と読まない（self-test）" \
  "検出器が \\\" を引用符の終端と読む — 後続の実パイプを伏せて違反を見逃す"
pg_expect "$PG_PROBE_ESCDQ_OK" nohit \
  "検出器が escape された二重引用符を含む文字列の中の言及を拾わない（self-test）" \
  "検出器が文字列の途中で引用符が閉じたと読む — 散文が直しようのない赤になる"
pg_expect "$PG_PROBE_ESCBARE" hit \
  "検出器が引用符の外の escape された二重引用符で引用符を開かない（self-test）" \
  "検出器が引用符外の \\\" で引用符を開く — 後続の実パイプを伏せて違反を見逃す"
pg_expect "$PG_PROBE_REDIR" hit \
  "検出器がリダイレクトの & を鎖の境界と数えない（self-test）" \
  "検出器が 2>&1 の & で鎖を切る — 上流を見失って実違反を見逃す"
pg_expect "$PG_PROBE_PIPEAMP" hit \
  "検出器が |&（stderr 込みのパイプ）を検出できる（self-test）" \
  "検出器が |& を取りこぼす — | から |& への言い換えが抜け道になる"
pg_expect "$PG_PROBE_BG" nohit \
  "検出器が単独の &（background）を鎖の境界と数える（self-test）" \
  "検出器が background の & でパイプを繋ぐ — 無関係な行が直しようのない赤になる"
pg_expect_lines "$PG_PROBE_PFSEMI" hit 1 \
  "検出器が同一行の set -o pipefail; を pipefail 設定と読む（self-test）" \
  "検出器が空白以外で終わる pipefail 設定を取りこぼす — そのファイルが丸ごと無検査になる"
pg_expect_lines "$PG_PROBE_PFWORD" nohit 1 \
  "検出器が pipefail の語の途中一致を設定と読まない（self-test）" \
  "検出器が pipefailx まで設定と読む — 反転しない形まで禁止してしまう"
pg_expect "$PG_PROBE_MARKER_STR" hit \
  "検出器が引用符の中の pipefail-safe 文言を除外宣言と読まない（self-test）" \
  "検出器が文字列内のマーカーで除外する — 違反行を文字列で包むだけで検査を黙らせられる"
pg_expect_lines "$PG_PF
$PG_PROBE_CONT_A
$PG_PROBE_CONT_B" hit 2 \
  "検出器が行末 | の改行継続を畳み込む（self-test）" \
  "検出器が継続行を別の論理行として見る — 鎖が切れて実違反を見逃す"
pg_expect_lines "$PG_PF
$PG_PROBE_CONT_OR_A
$PG_PROBE_CONT_OR_B" nohit 2 \
  "検出器は行末 || の継続でも鎖を繋がない（self-test）" \
  "検出器が論理和の継続をパイプと読む — 無関係な行が直しようのない赤になる"
pg_expect "$PG_PROBE_SUDO" hit \
  "検出器が sudo プレフィックス付きの grep -q を検出できる（self-test）" \
  "検出器が sudo 経由を取りこぼす — プレフィックスを 1 語足すだけで回避できる"
pg_expect "$PG_PROBE_ENV" hit \
  "検出器が env プレフィックス付きの grep -q を検出できる（self-test）" \
  "検出器が env 経由を取りこぼす — プレフィックスを 1 語足すだけで回避できる"
pg_expect "$PG_PROBE_ENVSRC" nohit \
  "検出器が env そのものを上流コマンドと数えない（self-test）" \
  "検出器が env を printf の仲間と読む — 上流が読み切る形まで赤になる"

# pipefail を設定していないファイルでは反転しないので報告しない。ここを落とすと、
# この検査は「パイプの下流の grep -q 全般」を禁止する別の契約に化ける。
if _pg_nopf="$(printf '%s\n' "$PG_PROBE_BAD" | pipefail_grep_q_scan)"; then
  if [ -z "$_pg_nopf" ]; then
    ok "検出器は pipefail を設定していない入力を報告しない（self-test）"
  else
    bad "検出器が pipefail 未設定でも報告する — 反転しない形まで禁止してしまう"; PG_SELFTEST_OK=0
  fi
else
  bad "pipefail_grep_q_scan を実行できません（pipefail 未設定の入力）"; PG_SELFTEST_OK=0
fi

# 自分では pipefail を張らず source 元から継承するファイル（multi-agent.sh の構成ファイル。
# ADR-075）は、行頭の継承宣言で設定行と同じに扱う。行頭以外（代入の値の中）の同じ文言では
# 設定扱いにしない。
PG_INHERIT_DECL="# pipefail-inherited: self-test"
pg_expect_lines "${PG_INHERIT_DECL}
$PG_PROBE_BAD" hit 2 \
  "検出器が行頭の継承宣言（pipefail-inherited）を設定行と同じに扱う（self-test）" \
  "検出器が継承宣言を読まない — source 元から pipefail を継承するファイルが無検査になる"
pg_expect_lines "x=\"${PG_INHERIT_DECL}\"
$PG_PROBE_BAD" nohit 2 \
  "検出器は行頭以外の継承宣言の文言を設定扱いにしない（self-test）" \
  "検出器が値の中の継承宣言で検査を有効にする — 文字列で包むだけで対象が変わる"

if [ "$PG_SELFTEST_OK" -eq 1 ]; then
  PG_REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || PG_REPO_ROOT=""
  if [ -z "$PG_REPO_ROOT" ]; then
    bad "リポジトリルートを解決できない（git rev-parse 失敗）— 横断検査を実行できない"
  else
    set +e
    PG_SUMMARY="$(pipefail_grep_q_check_tracked "$PG_REPO_ROOT" 2>/dev/null)"
    set -e
    case "$PG_SUMMARY" in
      PIPEFAIL_GREP_Q_RESULT=ok\ *)
        PG_SCANNED="$(printf '%s\n' "$PG_SUMMARY" | sed -E 's/.*SCANNED=([0-9]+).*/\1/')"
        PG_SKIPPED="$(printf '%s\n' "$PG_SUMMARY" | sed -E 's/.*SKIPPED=([0-9]+).*/\1/')"
        # 走査 0 件は「違反 0 件」の根拠にならないし、下限では対象集合の縮小を捕まえられない
        # （case 43 で実測済み）。対象集合を独立に数えて一致を要求する。予測子は
        # tests/shellcheck/verify.sh の SHEBANG_RE と同じ形。
        PG_EXPECT=0
        while IFS= read -r _pg_f; do
          [ -n "$_pg_f" ] || continue
          [ -f "$PG_REPO_ROOT/$_pg_f" ] || continue
          case "$_pg_f" in
            *.sh) PG_EXPECT=$((PG_EXPECT + 1)); continue ;;
          esac
          _pg_first=""
          IFS= read -r _pg_first < "$PG_REPO_ROOT/$_pg_f" || true
          case "$_pg_first" in
            '#!'*[/\ ]sh|'#!'*[/\ ]sh' '*|'#!'*[/\ ]bash|'#!'*[/\ ]bash' '*|'#!'*[/\ ]dash|'#!'*[/\ ]dash' '*|'#!'*[/\ ]ksh|'#!'*[/\ ]ksh' '*) PG_EXPECT=$((PG_EXPECT + 1)) ;;
          esac
        done < <(git -C "$PG_REPO_ROOT" -c core.quotepath=false ls-files)
        if [ "${PG_SCANNED:-0}" -lt 1 ]; then
          bad "走査対象が 0 件 — 違反 0 件を主張できない"
        elif [ "${PG_SKIPPED:-1}" -ne 0 ]; then
          # tracked なのに作業ツリーに実体が無い shell は「走査していない」ので 0 件を主張できない。
          # フル checkout では 0 件が正（sparse checkout など欠損しうる環境でだけ非 0 になる）。
          bad "実体が無く走査できなかった tracked shell がある（SKIPPED=${PG_SKIPPED}）— その分の 0 件は主張できない"
        elif [ "${PG_SCANNED:-0}" -eq "$PG_EXPECT" ]; then
          ok "tracked shell の pipefail 配下に反転する grep -q は無い（${PG_SCANNED} ファイル走査・独立集計と一致・欠損 0 件）"
        else
          bad "走査対象の件数が独立集計と一致しない（走査 ${PG_SCANNED} / 期待 ${PG_EXPECT}）— 対象集合が黙って縮んでいる"
        fi
        ;;
      PIPEFAIL_GREP_Q_RESULT=hits\ *)
        bad "pipefail 配下で反転する grep -q が混入した"
        pipefail_grep_q_check_tracked "$PG_REPO_ROOT" >/dev/null || true
        ;;
      PIPEFAIL_GREP_Q_RESULT=error_repo\ *)
        bad "リポジトリルートを解決できない（git rev-parse 失敗）— 横断検査を実行できない"
        ;;
      PIPEFAIL_GREP_Q_RESULT=error_list\ *)
        bad "検査対象の tracked ファイル一覧を取得できない（git ls-files 失敗/空）— 0 件の主張はできない"
        ;;
      PIPEFAIL_GREP_Q_RESULT=error_scan\ *)
        bad "走査に失敗したファイルがある — そのファイルの 0 件は主張できない"
        pipefail_grep_q_check_tracked "$PG_REPO_ROOT" >/dev/null || true
        ;;
      *)
        bad "横断検査のサマリーを解釈できない（実際: ${PG_SUMMARY}）"
        ;;
    esac

    # 集約層（scan → all_hits → result=hits → rc=1）と、利用者へ届く stderr を隔離 fixture で
    # 実測する。実リポジトリの ok だけを見る形では、集約を no-op 化する変異が緑のまま通る。
    if ! command -v git >/dev/null 2>&1; then
      echo "  ○ skip: git が無いため横断検査の hits / fail-closed 経路をスキップ（この検査は 1 件も実行していません）"
    else
      _pg_fx="$(mktemp -d "${TMPDIR:-/tmp}/ff-pipefail-grep-q-guard.XXXXXX")"
      printf '%s\n' '#!/usr/bin/env bash' "$PG_PF" "$PG_PROBE_BAD" > "$_pg_fx/violate.sh"
      _pg_git() { git -c commit.gpgsign=false -c user.email=t@example.invalid -c user.name=T -c init.defaultBranch=main "$@"; }
      _pg_setup=0
      _pg_git -C "$_pg_fx" init -q . >/dev/null 2>&1 || _pg_setup=1
      _pg_git -C "$_pg_fx" add -A >/dev/null 2>&1 || _pg_setup=1
      _pg_git -C "$_pg_fx" commit -qm fixture >/dev/null 2>&1 || _pg_setup=1
      if [ "$_pg_setup" -ne 0 ]; then
        bad "横断検査 hits 経路の git fixture を作れない（検査が成立していない）"
      else
        set +e
        _pg_err="$(pipefail_grep_q_check_tracked "$_pg_fx" 2>&1 >/dev/null)"
        _pg_sum="$(pipefail_grep_q_check_tracked "$_pg_fx" 2>/dev/null)"
        _pg_rc=$?
        set -e
        case "$_pg_sum" in
          PIPEFAIL_GREP_Q_RESULT=hits\ *) ok "横断検査は違反入り fixture で hits へ倒れる（集約層）" ;;
          *) bad "横断検査が違反を hits にしない（実際: ${_pg_sum}）— 集約を no-op 化する変異が通る" ;;
        esac
        if [ "$_pg_rc" -ne 0 ]; then ok "横断検査は違反ありで非 0 を返す"; else bad "横断検査が違反ありでも 0 を返す"; fi
        # 直し方（代替）と抜け道の封じ（言い換えても同じ）と例外の宣言方法が stderr に残ること。
        # タグだけでは「何をどう書き直せばよいか」が伝わらない（ACE-1076-1）。
        for _pg_needle in "$PG_TAG" 'here-string' 'pipefail-safe' '抜け道にならない'; do
          case "$_pg_err" in
            *"$_pg_needle"*) ok "横断検査の stderr が「${_pg_needle}」を含む" ;;
            *) bad "横断検査の stderr から「${_pg_needle}」が消えている（直し方・例外の宣言方法が伝わらない）" ;;
          esac
        done
        # fail-closed の 3 経路。テストシームが用意されているのに使われていないと、
        # 「0 件」を主張できない状態を素通りさせる変異が緑で通る。
        printf '%s\n' '#!/usr/bin/env bash' 'exit 3' > "$_pg_fx/git-stub"
        chmod +x "$_pg_fx/git-stub"
        set +e
        _pg_s1="$(FF_PIPEFAIL_GREP_Q_GIT="$_pg_fx/git-stub" pipefail_grep_q_check_tracked "$_pg_fx" 2>/dev/null)"
        _pg_rc1=$?
        printf '%s\n' '#!/usr/bin/env bash' 'exit 9' > "$_pg_fx/awk-stub"
        chmod +x "$_pg_fx/awk-stub"
        _pg_s2="$(FF_PIPEFAIL_GREP_Q_AWK="$_pg_fx/awk-stub" pipefail_grep_q_check_tracked "$_pg_fx" 2>/dev/null)"
        _pg_rc2=$?
        set -e
        case "$_pg_s1" in
          PIPEFAIL_GREP_Q_RESULT=error_repo\ *) ok "git が使えない回は error_repo（0 件を主張しない）" ;;
          *) bad "git が使えない回に error_repo を返さない（実際: ${_pg_s1}）" ;;
        esac
        case "$_pg_s2" in
          PIPEFAIL_GREP_Q_RESULT=error_scan\ *) ok "走査器が壊れている回は error_scan（0 件を主張しない）" ;;
          *) bad "走査器が壊れている回に error_scan を返さない（実際: ${_pg_s2}）" ;;
        esac
        # サマリー行だけを見ると、終了コードが 0 へ退行しても緑のまま通る（呼び出し側は rc で
        # 倒れる）。検査不能の 2 経路それぞれで非 0 を明示的にアサートする。
        if [ "$_pg_rc1" -ne 0 ]; then ok "git が使えない回は非 0 を返す"; else bad "git が使えない回に 0 を返す — 検査不能が緑で素通りする"; fi
        if [ "$_pg_rc2" -ne 0 ]; then ok "走査器が壊れている回は非 0 を返す"; else bad "走査器が壊れている回に 0 を返す — 検査不能が緑で素通りする"; fi
        # tracked 一覧が空の回。ここを ok へ倒す変異は「走査 0 件なのに違反 0 件」を主張させる
        # 典型的な fail-open。
        _pg_empty="$_pg_fx/empty"
        mkdir -p "$_pg_empty"
        _pg_git -C "$_pg_empty" init -q . >/dev/null 2>&1 || true
        set +e
        _pg_s3="$(pipefail_grep_q_check_tracked "$_pg_empty" 2>/dev/null)"
        _pg_rc3=$?
        set -e
        case "$_pg_s3" in
          PIPEFAIL_GREP_Q_RESULT=error_list\ *) ok "tracked 一覧が空の回は error_list（0 件を主張しない）" ;;
          *) bad "tracked 一覧が空の回に error_list を返さない（実際: ${_pg_s3}）— 走査 0 件で緑になる" ;;
        esac
        if [ "$_pg_rc3" -ne 0 ]; then ok "tracked 一覧が空の回は非 0 を返す"; else bad "tracked 一覧が空でも 0 を返す"; fi
      fi
      rm -rf "$_pg_fx"
    fi
  fi
fi

# case 47: 変更ベースの部分ゲート（FF_RUN_ALL_CHANGED。ADR-062）。追加時点で本体が 4,000 行を
# 超えていたので cases ファイルへ置いた（ADR-057 決定 2）。
# git が無い環境では全件 skip するので、そのときだけアサーションを要求しない。
if command -v git >/dev/null 2>&1; then
  suite_cases_source "$SCRIPT_DIR/cases" changed-selection.sh
else
  suite_cases_source_setup "$SCRIPT_DIR/cases" changed-selection.sh
fi

# 明示パスでは dirname / basename の意味を維持する（既定一覧の高速化の回帰）。
run_runner "$FIXTURES/pass//verify.sh"
expect_rc 0 "連続スラッシュを含む明示パスも実行できる"
expect_has '^== pass ==$' "明示パスの suite 名は dirname / basename と一致する"
if RUN_OUT="$(cd "$FIXTURES/pass" && env -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL \
  FF_RUN_ALL_JOBS=1 FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" bash "$RUNNER" verify.sh 2>&1)"; then
  RUN_RC=0
else
  RUN_RC=$?
fi
expect_rc 0 "ディレクトリを付けない明示パスも実行できる"
expect_has '^== \. ==$' "ディレクトリを付けない明示パスの suite 名は dot を保つ"

# suite-cases-end: cross-repo-scans.sh
