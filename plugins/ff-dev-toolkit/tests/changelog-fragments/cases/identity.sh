# shellcheck shell=bash
# GNU/BSD stat の identity 契約と、週次 CI が origin/HEAD を用意すること。
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
if [[ -f "$WEEKLY_WF" ]]; then
  if grep -Fq 'git remote set-head origin' "$WEEKLY_WF" \
      && grep -Fq 'git ls-remote --symref origin HEAD' "$WEEKLY_WF" \
      && ! grep -Fq 'git remote set-head origin --force' "$WEEKLY_WF" \
      && ! grep -Fq 'GITHUB_REF_NAME' "$WEEKLY_WF"; then
    ok "週次 CI は remote default branch で origin/HEAD を設定する"
  else
    bad "週次 CI の origin/HEAD 設定が remote default を使わないか --force が残る"
  fi
fi
