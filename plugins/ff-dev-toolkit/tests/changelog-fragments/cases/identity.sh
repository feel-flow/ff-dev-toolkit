# shellcheck shell=bash
# GNU/BSD stat の identity 契約と、週次 CI が origin/HEAD を用意すること（公開側 workflow に
# 同じ対策が入っているかの突き合わせを含む）。
# footer.sh の live 検査より前に読み、stat 順・identity 実行・origin/HEAD 針の退行を先に落とす。

extract_fn_body() { # $1=file $2=function name
  awk -v name="$2" '
    $0 ~ "^" name "\\(\\)" { on=1 }
    on { print }
    on && /^}/ { exit }
  ' "$1"
}

stat_c_before_f() { # $1=file $2=function
  extract_fn_body "$1" "$2" | awk '
    /stat -c/ { if (!c) c=NR }
    /stat -f/ { if (!f) f=NR }
    END { exit (c && f && c < f) ? 0 : 1 }
  '
}

if stat_c_before_f "$TARGET_LIB" read_stat_format; then
  ok "read_stat_format は GNU stat -c を BSD stat -f より先に使う"
else
  bad "read_stat_format の stat 実装順が GNU 非互換"
fi

# 旧形 `stat -f '%d:%i' ... || stat -c` を $(...) で受けると GNU で filesystem 統計が混ざる。
# 現行は format を変数経由で渡すので、このリテラルは残ってはいけない。
if grep -F "stat -f '%d:%i'" "$TARGET_LIB" >/dev/null; then
  bad "read_file_identity が GNU では --file-system になる stat -f '%d:%i' を直書きする"
else
  ok "read_file_identity は GNU stat -f '%d:%i' の直書きを使わない"
fi
if grep -F "stat -f '%Lp'" "$TARGET_LIB" >/dev/null; then
  bad "read_file_mode が GNU では --file-system になる stat -f '%Lp' を直書きする"
else
  ok "read_file_mode は GNU stat -f '%Lp' の直書きを使わない"
fi

cp "$TARGET_LIB" "$TMP/old-identity-lib.sh"
printf '%s\n' "read_file_identity() { stat -f '%d:%i' \"\$1\" 2>/dev/null || stat -c '%d:%i' \"\$1\" 2>/dev/null; }" \
  >> "$TMP/old-identity-lib.sh"
if grep -F "stat -f '%d:%i'" "$TMP/old-identity-lib.sh" >/dev/null \
    && ! grep -F "stat -f '%d:%i'" "$TARGET_LIB" >/dev/null; then
  ok "stat -f 先行パターンの検出針は生産コードの旧形コピーで赤になる"
else
  bad "stat -f 先行パターンの検出針が生産コードの旧形コピーを見逃す"
fi

# shellcheck source=/dev/null
. "$TARGET_LIB"
id_probe="$TMP/identity-probe"
printf 'probe\n' > "$id_probe"
id1="$(read_file_identity "$id_probe")"
fill="$TMP/identity-fill"
dd if=/dev/zero of="$fill" bs=1048576 count=2 2>/dev/null || true
id2="$(read_file_identity "$id_probe")"
rm -f "$fill"
if [[ "$id1" == "$id2" && "$id1" =~ ^[0-9]+:[0-9]+$ ]]; then
  ok "file identity は device:inode で FS 空き容量に依存しない"
else
  bad "file identity が filesystem 統計を混ぜている"
  printf '  id1=%s\n  id2=%s\n' "$id1" "$id2" | sed 's/^/    | /' >&2
fi

mode1="$(read_file_mode "$id_probe")"
if [[ "$mode1" =~ ^[0-7]{3,4}$ ]]; then
  ok "file mode は 8 進数の permission だけを返す"
else
  bad "file mode が filesystem 統計を混ぜている"
  printf '  mode=%s\n' "$mode1" | sed 's/^/    | /' >&2
fi

if stat --version >/dev/null 2>&1; then
  expected_id="$(stat -c '%d:%i' "$id_probe")"
  if [[ "$id1" == "$expected_id" ]]; then
    ok "GNU では identity が stat -c device:inode と一致"
  else
    bad "GNU で identity が stat -c の結果と不一致"
    printf '  id=%s expected=%s\n' "$id1" "$expected_id" | sed 's/^/    | /' >&2
  fi
else
  expected_id="$(stat -f '%d:%i' "$id_probe")"
  if [[ "$id1" == "$expected_id" ]]; then
    ok "BSD では identity が stat -f device:inode と一致"
  else
    bad "BSD で identity が stat -f の結果と不一致"
    printf '  id=%s expected=%s\n' "$id1" "$expected_id" | sed 's/^/    | /' >&2
  fi
fi

write_stat_stub() {
  mkdir -p "$1"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "$1" == "-c" ]]; then' \
    '  [[ "${STAT_C_FAIL:-0}" == 1 ]] && exit 1' \
    '  printf "%s\n" "${STAT_C_OUT:-1:2}"' \
    '  exit 0' \
    'fi' \
    'if [[ "$1" == "-f" ]]; then' \
    '  [[ "${STAT_F_FAIL:-0}" == 1 ]] && exit 1' \
    '  printf "%s\n" "${STAT_F_OUT:-3:4}"' \
    '  exit 0' \
    'fi' \
    'exit 1' \
    > "$1/stat"
  chmod +x "$1/stat"
}

saved_path="$PATH"
STAT_BIN="$TMP/stat-stub"
write_stat_stub "$STAT_BIN"
PATH="$STAT_BIN:$PATH"
export STAT_C_OUT='8:99' STAT_F_OUT='should-not-appear' STAT_C_FAIL=0 STAT_F_FAIL=0
stub_gnu="$(read_file_identity "$id_probe")"
if [[ "$stub_gnu" == "8:99" ]]; then
  ok "stat stub の GNU 成功経路は -c の値だけを使う"
else
  bad "stat stub の GNU 成功経路が -f の値を混ぜる"
  printf '  got=%s\n' "$stub_gnu" | sed 's/^/    | /' >&2
fi
export STAT_C_FAIL=1 STAT_F_FAIL=0 STAT_C_OUT='8:99' STAT_F_OUT='7:77'
stub_bsd="$(read_file_identity "$id_probe")"
if [[ "$stub_bsd" == "7:77" ]]; then
  ok "stat stub の BSD fallback は -c 失敗後に -f を使う"
else
  bad "stat stub の BSD fallback が -f の値を返さない"
  printf '  got=%s\n' "$stub_bsd" | sed 's/^/    | /' >&2
fi
export STAT_C_FAIL=1 STAT_F_FAIL=1
set +e
stub_both="$(read_file_identity "$id_probe" 2>/dev/null)"
stub_both_rc=$?
set -e
if [[ "$stub_both_rc" -ne 0 ]]; then
  ok "stat の両経路失敗は非0で不正 identity を返さない"
else
  bad "stat の両経路失敗を成功扱いする"
  printf '  got=%s rc=%s\n' "$stub_both" "$stub_both_rc" | sed 's/^/    | /' >&2
fi
PATH="$saved_path"
unset STAT_C_OUT STAT_F_OUT STAT_C_FAIL STAT_F_FAIL

if grep -Fq 'if ! default_ref="$(git -C "$REPO_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD)"' \
    "$SCRIPT_DIR/cases/footer.sh"; then
  ok "origin/HEAD 不在を set -e で中断せず診断する"
else
  bad "origin/HEAD 不在が set -e で suite を沈黙終了させる"
fi

WEEKLY_WF="$REPO_ROOT/.github/workflows/weekly-run-all.yml"
# SSOT 側の checkout 直後の段（origin/HEAD の設置など）は、週次と PR トリガー CI が共有する
# ローカル action に置いてある（ADR-062）。本文契約と公開側との突き合わせはその action へ当て、
# 両 workflow が checkout の直後にその action を呼んでいること（配線）を別に確かめる。
SSOT_SETUP="$REPO_ROOT/.github/actions/run-all-setup/action.yml"
PR_WF="$REPO_ROOT/.github/workflows/pr-run-all.yml"
# 公開側 workflow も同じ actions/checkout を使い、同じランナー特性
# （refs/remotes/origin/HEAD を置かない）に晒される。本文契約を SSOT 側にしか掛けないと、
# step 名だけを見る後段の突き合わせでは拾えない片側劣化 — name を保ったまま fetch の
# if ガードを落とす・GITHUB_REF_NAME へ差し替える — が全ゲート緑で通る。両側へ回す。
PUBLIC_WF="$REPO_ROOT/oss/ff-dev-toolkit/.github/workflows/weekly-public-run-all.yml"
if [[ -f "$WEEKLY_WF" ]]; then
  # 共有 action の不在は「本文契約が当たる先が無い」なので名指しで赤にする（無音で抜けない）。
  [[ -f "$SSOT_SETUP" ]] || bad "共有セットアップ action が見つからない（origin/HEAD の本文契約が空振りする）: ${SSOT_SETUP#"$REPO_ROOT"/}"
  # 配線: 両 workflow とも checkout の直後の step が共有 action であること。action だけ正しくても
  # workflow が呼ばなくなれば、ランナー特性の対策は実行されない。
  for _wf in "$WEEKLY_WF" "$PR_WF"; do
    _wf_label="${_wf#"$REPO_ROOT"/}"
    _next_step="$(awk '
      /^      - uses: actions\/checkout@/ { region = 1; next }
      region && /^      - (uses|name): / { print; exit }
    ' "$_wf" 2>/dev/null)"
    if [[ "$_next_step" == '      - uses: ./.github/actions/run-all-setup' ]]; then
      ok "${_wf_label} は checkout の直後に共有セットアップ action を呼ぶ"
    else
      bad "${_wf_label} が checkout の直後に共有セットアップ action を呼んでいない（実際: ${_next_step:-抽出できない}）"
    fi
  done
  for _wf in "$SSOT_SETUP" "$PUBLIC_WF"; do
    # 公開側の不在は後段の突き合わせが名指しで赤にする（ここで重ねて報告しない）。
    [[ -f "$_wf" ]] || continue
    _wf_label="${_wf#"$REPO_ROOT"/}"
    if grep -Fq 'git remote set-head origin' "$_wf" \
        && grep -Fq 'git ls-remote --symref origin HEAD' "$_wf" \
        && ! grep -Fq 'git remote set-head origin --force' "$_wf" \
        && ! grep -Fq 'GITHUB_REF_NAME' "$_wf"; then
      ok "週次 CI（${_wf_label}）は remote default branch で origin/HEAD を設定する"
    else
      bad "週次 CI（${_wf_label}）の origin/HEAD 設定が remote default を使わないか --force が残る"
    fi

    # 判定基準（refs/remotes/origin/<default>）は actions/checkout が checkout した SHA で
    # 置いてくれている。走行中に default branch が進む環境では、ここで**無条件に fetch すると
    # その正しい値を live の先端で上書きしてしまい**、祖先検査が鮮度赤に倒れる。fetch してよいのは
    # 「先行ガードを効かせたい回」— ref が無い（既定ブランチ以外からの dispatch）か、初回試行で
    # ない（Re-run）— だけ。fetch を囲む if ブロックを構造ごと取り出して照合する（全文への存在
    # 確認だと、fetch が条件の外へ出ても、条件が入れ替わっても通ってしまう）。
    fetch_count="$(grep -c 'git fetch origin "+refs/heads/${default_branch}' "$_wf" || true)"
    if [ "$fetch_count" != 1 ]; then
      bad "週次 CI（${_wf_label}）の default branch fetch が 1 箇所ではない（${fetch_count} 箇所。無条件経路が増えると基準が live 先端で上書きされる）"
    else
      fetch_block="$(awk '
        /^[[:space:]]*if / { buf = $0; collecting = 1; next }
        collecting { buf = buf "\n" $0 }
        collecting && /git fetch origin "\+refs\/heads\/\$\{default_branch\}/ { print buf; exit }
      ' "$_wf")"
      if [ -z "$fetch_block" ]; then
        bad "週次 CI（${_wf_label}）の default branch fetch が if ブロックに囲まれていない（走行中に進んだ先端で基準が上書きされる）"
      else
        for _cond in \
          '[ "${GITHUB_RUN_ATTEMPT:-0}" != 1 ]' \
          'git rev-parse --verify --quiet "refs/remotes/origin/${default_branch}^{commit}"'
        do
          if [[ "$fetch_block" == *"$_cond"* ]]; then
            ok "週次 CI（${_wf_label}）の fetch 条件に ${_cond} がある（同じ if ブロック内）"
          else
            bad "週次 CI（${_wf_label}）の fetch 条件から ${_cond} が消えています"
          fi
        done
        # 2 条件は OR。AND に変えると、既定ブランチ以外からの初回 dispatch で ref を作れない。
        if [[ "$fetch_block" == *"||"* ]]; then
          ok "週次 CI（${_wf_label}）の fetch 条件は OR で結ばれている（どちらか一方でも fetch する）"
        else
          bad "週次 CI（${_wf_label}）の fetch 条件が OR ではない（片方しか成立しない回で基準 ref を用意できない）"
        fi
      fi
    fi
  done
fi

# 週次 CI の対策が片側だけに入る非対称の検出。
#
# 公開側 workflow（oss/ff-dev-toolkit/.github/workflows/weekly-public-run-all.yml）は
# 同じ actions/checkout を使うので、**checkout 直後に置いたランナー特性への対策は両側に要る**。
# 実測: origin/HEAD の対策が SSOT 側にだけ入っていた 2 週間、公開側は ace-curate-commit の
# 保護判定 block が origin/HEAD を解決できず全シナリオ落ちていた（SSOT の週次は緑のまま）。
#
# 突き合わせは「checkout step と次の `- uses:` step の間にある run step の name」で行う。
# 全文 grep だと step が別の位置へ移っても通ってしまい、逆に本文の逐語一致を要求すると
# 公開側で正当に異なる部分（timeout-minutes・理由コメントの参照先）で恒常的に赤くなる。
# name の集合なら、将来追加されるランナー特性対策も同じ検査が拾う。
post_checkout_step_names() { # $1=workflow ファイル
  awk '
    /^      - uses: actions\/checkout@/ { region = 1; next }
    region && /^      - uses: / { exit }
    region && index($0, "      - name: ") == 1 { print substr($0, length("      - name: ") + 1) }
  ' "$1"
}
# 共有 action 側の「checkout 直後の段」= 最初の `- uses:` より前の run step（action は checkout の
# 直後に呼ばれることを上の配線検査が確かめている）。
setup_head_step_names() { # $1=action.yml
  awk '
    /^    - uses: / { exit }
    index($0, "    - name: ") == 1 { print substr($0, length("    - name: ") + 1) }
  ' "$1"
}

if [[ ! -f "$WEEKLY_WF" ]]; then
  : # 公開リポジトリのチェックアウトは oss/ も weekly-run-all.yml（同期対象外）も持たない。
    # 両方不在なら突き合わせる相手が無いので従来どおり何も言わない。
elif [[ ! -f "$PUBLIC_WF" ]]; then
  # SSOT 側だけが在る = 公開側 workflow の移動・削除。ここを無音 skip にすると、
  # 消えた対象が**検出器そのもの**である回に非対称が誰にも見えなくなる。
  bad "公開側 workflow が見つからない（移動・削除で非対称の突き合わせが空振りする）: ${PUBLIC_WF#"$REPO_ROOT"/}"
else
  ssot_post_checkout=""
  [[ ! -f "$SSOT_SETUP" ]] || ssot_post_checkout="$(setup_head_step_names "$SSOT_SETUP")"
  public_post_checkout="$(post_checkout_step_names "$PUBLIC_WF")"
  if [[ -z "$ssot_post_checkout" ]]; then
    # 抽出が空振りしたら「差分なし」ではなく検査不能として赤にする（書式変更で
    # 針が何にも当たらなくなった回に、非対称を見逃したまま緑になるのを防ぐ）。
    bad "週次 CI の checkout 直後 step を抽出できない（workflow の書式変更で突き合わせが空振りしている）"
  else
    asymmetric=""
    while IFS= read -r _step_name; do
      [[ -n "$_step_name" ]] || continue
      printf '%s\n' "$public_post_checkout" | grep -Fqx -- "$_step_name" \
        || asymmetric="${asymmetric} ${_step_name};"
    done <<< "$ssot_post_checkout"
    if [[ -z "$asymmetric" ]]; then
      ok "週次 CI の checkout 直後のランナー特性対策が公開側 workflow にも入っている"
    else
      bad "週次 CI の checkout 直後 step が公開側 workflow に無い（片側だけの対策）:${asymmetric}"
    fi

    # 検出力の実測: 公開側のコピーで step 名を改名すると同じ突き合わせが赤くなるか。
    # 非対称が 0 件であることは「検査が効いている」ことを意味しないため毎回測る。
    # 測るのは **SSOT 側の全 step**（head -n 1 の 1 件だけだと、step が増えた日に
    # 残りの検出力が未測定のまま緑になる）。
    mutant_public="$TMP/weekly-public-run-all.mutant.yml"
    while IFS= read -r _ssot_step; do
      [[ -n "$_ssot_step" ]] || continue
      # 置換は awk の完全一致で行う。step 名は `/` を含みうる（origin/HEAD）ので、
      # sed の s/// へ埋めると区切り文字が壊れる（実測: bad flag in substitute command）。
      awk -v target="      - name: ${_ssot_step}" \
        '$0 == target { print $0 " (renamed)"; next } { print }' \
        "$PUBLIC_WF" > "$mutant_public"
      # 変異が 1 行も当たらなかった回に「実測した」と名乗らない。grep が変異と無関係な
      # 理由で外れても ok が出てしまうため、**変異が原本と異なること**を先に確かめる。
      if cmp -s "$PUBLIC_WF" "$mutant_public"; then
        bad "変異注入が空振りした（公開側に当該 step 名の行が無く検出力を測れていない）: ${_ssot_step}"
        continue
      fi
      if printf '%s\n' "$(post_checkout_step_names "$mutant_public")" | grep -Fqx -- "$_ssot_step"; then
        bad "非対称の検出針が公開側 step 名の改名を見逃す（変異注入が赤化しない）: ${_ssot_step}"
      else
        ok "非対称の検出針は公開側 step 名の改名で赤化する（変異注入で実測）: ${_ssot_step}"
      fi
    done <<< "$ssot_post_checkout"

    # step 名の集合比較だけでは「name を保ったまま中身を抜く」劣化を拾えない。その穴は
    # 上の本文契約（両 workflow へ回している）が塞ぐ。ここではその本文契約が公開側に
    # 対しても実際に効いていることを、`git remote set-head` 行を落とした写しで測る
    # （契約を SSOT 側にしか掛けていない実装ではこの変異が緑のまま通る）。
    # 固定文字列なので -F を付ける。正規表現として解釈させると `$` を含む針を足した日に
    # 方言差で黙って空振りする（実測: ugrep は BRE 中の `$default_branch` に一致しない）。
    body_mutant="$TMP/weekly-public-run-all.body-mutant.yml"
    grep -vF 'git remote set-head origin' "$PUBLIC_WF" > "$body_mutant" || true
    if cmp -s "$PUBLIC_WF" "$body_mutant"; then
      bad "本文契約の変異注入が空振りした（公開側に git remote set-head origin の行が無い）"
    elif grep -qF 'git remote set-head origin' "$body_mutant"; then
      bad "本文契約の検出針が公開側の git remote set-head 削除を見逃す（変異注入が赤化しない）"
    else
      ok "本文契約の検出針は公開側の git remote set-head 削除で赤化する（変異注入で実測）"
    fi
  fi
fi
