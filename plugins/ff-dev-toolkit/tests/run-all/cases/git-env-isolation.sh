# shellcheck shell=bash
# case 56: suite の起動環境を開発者のグローバル／システム git 設定と作者環境変数から隔離する（OBS-508 / ACE-2667-1）
#
# verify.sh から source される（ok / bad / RUNNER / TESTS_DIR を共有）。
#
# 開発者の ~/.gitconfig（user.name / user.email / core.excludesFile 等）・$XDG_CONFIG_HOME/git/ignore・
# 環境変数（GIT_AUTHOR_* / GIT_COMMITTER_* / EMAIL）・OS アカウントからの自動推測が suite の fixture へ
# 漏れると、次が起きる:
#   1. 作者情報を持たない fixture の git commit が手元では緑、WSL・CI でだけ赤になる
#   2. core.excludesFile や既定の $XDG_CONFIG_HOME/git/ignore（*~ を含む等）が git check-ignore へ漏れ、
#      チルダを含むパスの判定（guard-review-in-flight 等）が ignored 扱いになって赤になる
# 逐次（FF_RUN_ALL_JOBS=1）と並列（=2）の両経路で次を測る:
#   56-0   tests/lib/git-isolated.gitconfig が実在し user.useConfigOnly=true と core.excludesFile=/dev/null を持つ（--file で隔離読取）
#   56-pre 隔離無しの素の git に *~ を含む core.excludesFile および $XDG_CONFIG_HOME/git/ignore を渡すと "~/app.txt" が ignored になる
#   56-A   グローバル作者情報 + GIT_AUTHOR_* がある親環境で、作者無し fixture の git commit が赤になる（かつ GIT_CONFIG_NOSYSTEM=1 と元値の退避が届く）
#   56-B   グローバル作者情報も環境変数も無い親環境でも、同じく赤になる
#   56-C   作者情報を明示指定した fixture の git commit は緑になる（過検出でないことの対照）
#   56-D   *~ を含む core.excludesFile および $XDG_CONFIG_HOME/git/ignore を持つ親環境でも、suite 内の git check-ignore へ漏れない
#   56-M1  ff_suite_env_isolate から git 隔離を外した変異版 run-all.sh で、56-A（作者無し commit が緑化）と
#          56-D（core.excludesFile が漏れて赤化）の双方が逐次・並列（2 suite 同時）で検出されることを実測
#   56-M2  隔離ファイルが空（useConfigOnly 無し）では --file 読み戻しが true にならない

echo ""
echo "== case 56: suite の起動環境を開発者の git 設定・作者環境変数から隔離する =="

_gi_cfg="$TESTS_DIR/lib/git-isolated.gitconfig"
if [ -r "$_gi_cfg" ] \
  && [ "$(git config --file "$_gi_cfg" --bool --get user.useConfigOnly 2>/dev/null || true)" = "true" ] \
  && [ "$(git config --file "$_gi_cfg" --get core.excludesFile 2>/dev/null || true)" = "/dev/null" ] \
  && [ "$(git config --file "$_gi_cfg" --get safe.directory 2>/dev/null || true)" = "*" ]; then
  ok "56-0: tests/lib/git-isolated.gitconfig が実在し user.useConfigOnly=true / core.excludesFile=/dev/null / safe.directory=* を持つ"
else
  bad "56-0: tests/lib/git-isolated.gitconfig が無い、または期待設定が読めない: $_gi_cfg"
fi

_gi_dir="$(mktemp -d "${TMPDIR:-/tmp}/ff-git-env-isolation.XXXXXX" 2>&1)" || _gi_dir=""
if [ -z "$_gi_dir" ] || [ ! -d "$_gi_dir" ]; then
  bad "case 56: 一時領域を作れず git 設定隔離を実測できません"
else
  _gi_setup_rc=0
  mkdir -p "$_gi_dir/no-ident" "$_gi_dir/with-ident" "$_gi_dir/check-ignore" "$_gi_dir/pre-repo" "$_gi_dir/xdg/git" || _gi_setup_rc=1
  printf '*~\n' >"$_gi_dir/global.gitignore" || _gi_setup_rc=1
  printf '*~\n' >"$_gi_dir/xdg/git/ignore" || _gi_setup_rc=1
  printf '[user]\n\tname = Global Dev\n\temail = global-dev@example.invalid\n[core]\n\texcludesfile = %s\n' \
    "$_gi_dir/global.gitignore" >"$_gi_dir/global.gitconfig" || _gi_setup_rc=1
  : >"$_gi_dir/empty.gitconfig" || _gi_setup_rc=1

  # 前提確認: 隔離無しの素の git に global.gitconfig（*~ を含む excludesfile）および
  # $XDG_CONFIG_HOME/git/ignore（*~ を含む既定 ignore）を渡すと git check-ignore -q -- "~/app.txt" が
  # どちらも ignored（rc=0）になること（空振り防止）
  _gi_pre_rc=0
  _gi_pre_xdg_rc=0
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
    GIT_CONFIG_GLOBAL="$_gi_dir/global.gitconfig" GIT_CONFIG_NOSYSTEM=1 \
    git -C "$_gi_dir/pre-repo" init -q >/dev/null 2>&1 || _gi_setup_rc=1
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
    GIT_CONFIG_GLOBAL="$_gi_dir/global.gitconfig" GIT_CONFIG_NOSYSTEM=1 \
    git -C "$_gi_dir/pre-repo" check-ignore -q -- "~/app.txt" >/dev/null 2>&1 || _gi_pre_rc=$?
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$_gi_dir/xdg" \
    git -C "$_gi_dir/pre-repo" check-ignore -q -- "~/app.txt" >/dev/null 2>&1 || _gi_pre_xdg_rc=$?
  if [ "$_gi_pre_rc" -eq 0 ] && [ "$_gi_pre_xdg_rc" -eq 0 ]; then
    ok "56-pre: 隔離無しでは core.excludesfile と \$XDG_CONFIG_HOME/git/ignore の *~ が git check-ignore \"~/app.txt\" へ漏れて ignored(rc=0) になる"
  else
    bad "56-pre: 前提不成立（excludesfile rc=${_gi_pre_rc}, xdg rc=${_gi_pre_xdg_rc}。以降の 56-D が空振りする）"
  fi

  # 疑似 suite 1: 作者情報を持たない fixture で素の git commit を呼ぶ（赤になるのが期待）
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'd="$(mktemp -d "${TMPDIR:-/tmp}/gi-noident.XXXXXX")"' \
    'trap '\''rm -rf "$d"'\'' EXIT' \
    'git -C "$d" init -q' \
    'printf "x\n" >"$d/a.txt"' \
    'git -C "$d" add a.txt' \
    'git -C "$d" commit -qm "missing-identity"' \
    'echo "NO-IDENT-COMMITTED"' \
    >"$_gi_dir/no-ident/verify.sh" || _gi_setup_rc=1

  # 疑似 suite 2: コマンド単位で作者情報を明示した fixture の git commit（緑になるのが期待）
  # あわせて GIT_CONFIG_NOSYSTEM=1 と元 GIT_CONFIG_GLOBAL の退避も観測する
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "NOSYS=%s ORIG_SET=%s ORIG_VAL=%s\n" "${GIT_CONFIG_NOSYSTEM-UNSET}" "${FF_ORIG_GIT_CONFIG_GLOBAL_SET-UNSET}" "${FF_ORIG_GIT_CONFIG_GLOBAL-UNSET}"' \
    'd="$(mktemp -d "${TMPDIR:-/tmp}/gi-withident.XXXXXX")"' \
    'trap '\''rm -rf "$d"'\'' EXIT' \
    'git -C "$d" init -q' \
    'printf "x\n" >"$d/a.txt"' \
    'git -C "$d" add a.txt' \
    'git -C "$d" -c user.name="Isolated Author" -c user.email="isolated-author@example.com" commit -qm "with-identity"' \
    'echo "WITH-IDENT-COMMITTED"' \
    >"$_gi_dir/with-ident/verify.sh" || _gi_setup_rc=1

  # 疑似 suite 3: git check-ignore -q -- "~/app.txt" が ignored(rc=0) にならず rc=1 になることを検証
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'd="$(mktemp -d "${TMPDIR:-/tmp}/gi-chkign.XXXXXX")"' \
    'trap '\''rm -rf "$d"'\'' EXIT' \
    'git -C "$d" init -q' \
    'rc=0' \
    'git -C "$d" check-ignore -q -- "~/app.txt" >/dev/null 2>&1 || rc=$?' \
    'if [ "$rc" -ne 1 ]; then echo "LEAKED-EXCLUDESFILE rc=$rc" >&2; exit 1; fi' \
    'echo "NO-EXCLUDESFILE-LEAK"' \
    >"$_gi_dir/check-ignore/verify.sh" || _gi_setup_rc=1

  chmod +x "$_gi_dir/no-ident/verify.sh" "$_gi_dir/with-ident/verify.sh" "$_gi_dir/check-ignore/verify.sh" || _gi_setup_rc=1

  if [ "$_gi_setup_rc" -ne 0 ]; then
    bad "case 56: fixture の準備に失敗しました（以下の検査は何も測っていない）"
  else
    _gi_run_with_global() { # <runner> <jobs> <suite...>
      local _r="$1" _j="$2"; shift 2
      _gi_rc=0
      _gi_out="$(env -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_CHANGED \
        -u FF_ORIG_GIT_CONFIG_SAVED -u FF_ORIG_GIT_CONFIG_GLOBAL_SET -u FF_ORIG_GIT_CONFIG_GLOBAL \
        -u FF_ORIG_GIT_CONFIG_NOSYSTEM_SET -u FF_ORIG_GIT_CONFIG_NOSYSTEM -u GIT_CONFIG_NOSYSTEM \
        -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
        FF_RUN_ALL_JOBS="$_j" FF_GATE_RECORD=0 FF_DEV_TOOLKIT_STATE_DIR="$_gi_dir/state" \
        GIT_CONFIG_GLOBAL="$_gi_dir/global.gitconfig" XDG_CONFIG_HOME="$_gi_dir/xdg" \
        GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0="user.name" GIT_CONFIG_VALUE_0="Env Config Dev" \
        GIT_CONFIG_KEY_1="user.email" GIT_CONFIG_VALUE_1="env-config@example.invalid" \
        GIT_AUTHOR_NAME="Env Dev" GIT_AUTHOR_EMAIL="env-dev@example.invalid" \
        GIT_COMMITTER_NAME="Env Dev" GIT_COMMITTER_EMAIL="env-dev@example.invalid" \
        EMAIL="env-dev@example.invalid" \
        bash "$_r" "$@" 2>&1)" || _gi_rc=$?
    }
    _gi_run_without_global() { # <runner> <jobs> <suite...>
      local _r="$1" _j="$2"; shift 2
      _gi_rc=0
      _gi_out="$(env -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_CHANGED \
        -u FF_ORIG_GIT_CONFIG_SAVED -u FF_ORIG_GIT_CONFIG_GLOBAL_SET -u FF_ORIG_GIT_CONFIG_GLOBAL \
        -u FF_ORIG_GIT_CONFIG_NOSYSTEM_SET -u FF_ORIG_GIT_CONFIG_NOSYSTEM -u GIT_CONFIG_NOSYSTEM \
        -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
        -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL -u EMAIL \
        FF_RUN_ALL_JOBS="$_j" FF_GATE_RECORD=0 FF_DEV_TOOLKIT_STATE_DIR="$_gi_dir/state" \
        GIT_CONFIG_GLOBAL=/dev/null XDG_CONFIG_HOME="$_gi_dir/xdg" \
        bash "$_r" "$@" 2>&1)" || _gi_rc=$?
    }

    for _gi_jobs in 1 2; do
      if [ "$_gi_jobs" = 1 ]; then _gi_path="逐次"; else _gi_path="並列"; fi

      # 56-A: グローバル作者情報 + 環境変数作者情報がある親環境でも、作者無し fixture の commit が赤になる
      #       あわせてランナーが GIT_CONFIG_NOSYSTEM=1 を設定し、起動元の GIT_CONFIG_GLOBAL を退避することも確認
      _gi_run_with_global "$RUNNER" "$_gi_jobs" "$_gi_dir/no-ident/verify.sh" "$_gi_dir/with-ident/verify.sh"
      if [ "$_gi_rc" -ne 0 ] && [[ "$_gi_out" != *NO-IDENT-COMMITTED* ]] && [[ "$_gi_out" == *WITH-IDENT-COMMITTED* ]] \
        && [[ "$_gi_out" == *"NOSYS=1 ORIG_SET=1 ORIG_VAL=$_gi_dir/global.gitconfig"* ]]; then
        ok "56-A (${_gi_path}): グローバル作者情報と作者環境変数があっても、作者無し fixture の git commit が赤になり GIT_CONFIG_NOSYSTEM=1 と元 GIT_CONFIG_GLOBAL 退避が効く"
      else
        bad "56-A (${_gi_path}): 作者無し fixture の commit が止まらない、または隔離 env / 元値退避が期待と違う（rc=${_gi_rc}）"
        printf '%s\n' "$_gi_out" | tail -n 20 | sed 's/^/    | /' >&2
      fi

      # 56-B: グローバル作者情報が無い環境でも、結果が 56-A と同じ（赤、作者あり対照は緑）
      _gi_run_without_global "$RUNNER" "$_gi_jobs" "$_gi_dir/no-ident/verify.sh" "$_gi_dir/with-ident/verify.sh"
      if [ "$_gi_rc" -ne 0 ] && [[ "$_gi_out" != *NO-IDENT-COMMITTED* ]] && [[ "$_gi_out" == *WITH-IDENT-COMMITTED* ]]; then
        ok "56-B (${_gi_path}): グローバル作者情報が無い環境でも、56-A と同じ結果（作者無し赤・作者あり緑）になる"
      else
        bad "56-B (${_gi_path}): 作者情報なし環境の結果が 56-A と一致しない（rc=${_gi_rc}）"
        printf '%s\n' "$_gi_out" | tail -n 20 | sed 's/^/    | /' >&2
      fi

      # 56-C + 56-D: 作者あり fixture と git check-ignore 検査（core.excludesFile と XDG ignore の *~ を持つ親環境）がともに緑
      _gi_run_with_global "$RUNNER" "$_gi_jobs" "$_gi_dir/with-ident/verify.sh" "$_gi_dir/check-ignore/verify.sh"
      if [ "$_gi_rc" -eq 0 ] && [[ "$_gi_out" == *WITH-IDENT-COMMITTED* ]] && [[ "$_gi_out" == *NO-EXCLUDESFILE-LEAK* ]]; then
        ok "56-C/D (${_gi_path}): 作者あり fixture は緑、かつ親の core.excludesFile / \$XDG_CONFIG_HOME/git/ignore(*~) が git check-ignore へ漏れない"
      else
        bad "56-C/D (${_gi_path}): 作者あり fixture または core.excludesFile / XDG ignore 隔離が失敗（rc=${_gi_rc}）"
        printf '%s\n' "$_gi_out" | tail -n 20 | sed 's/^/    | /' >&2
      fi
    done

    # 56-M1: 変異（ff_suite_env_isolate から git 隔離行を外した run-all.sh 写し）
    # 2 suite（no-ident + check-ignore）を同時に渡すことで、JOBS=2 で確実に並列経路を通す。
    # 隔離を外すと、親の global.gitconfig と GIT_AUTHOR_* が suite へ漏れ、
    # (1) 作者無し fixture の commit が緑へ化け、(2) core.excludesfile(*~) が check-ignore へ漏れて赤になる。
    _gi_mut_dir="$_gi_dir/mut-runner"
    mkdir -p "$_gi_mut_dir/lib"
    cp "$_gi_cfg" "$_gi_mut_dir/lib/git-isolated.gitconfig"
    awk '
      /^ff_suite_env_isolate\(\) \{/ { in_fn = 1; print; next }
      in_fn && /^\}/ { in_fn = 0; print; next }
      in_fn && /(GIT_AUTHOR_|GIT_CONFIG|FF_ORIG_GIT_CONFIG_SAVED|FF_ORIG_GIT_CONFIG_GLOBAL|FF_ORIG_GIT_CONFIG_NOSYSTEM|git-isolated\.gitconfig|compgen -v GIT_CONFIG_)/ { next }
      in_fn && /^[[:space:]]*(if \[\[|else|fi|local _v|for _v|case "\$_v"|esac|done)/ { next }
      { print }
    ' "$RUNNER" >"$_gi_mut_dir/run-all.sh"
    if cmp -s "$RUNNER" "$_gi_mut_dir/run-all.sh"; then
      bad "56-M1: git 隔離除去の変異が適用されていない（空振り）"
    else
      for _gi_jobs in 1 2; do
        if [ "$_gi_jobs" = 1 ]; then _gi_path="逐次"; else _gi_path="並列"; fi
        _gi_run_with_global "$_gi_mut_dir/run-all.sh" "$_gi_jobs" "$_gi_dir/no-ident/verify.sh" "$_gi_dir/check-ignore/verify.sh"
        _gi_mut_par_ok=1
        if [ "$_gi_jobs" = 2 ] && [[ "$_gi_out" != *"🧵 並列実行"* ]]; then
          _gi_mut_par_ok=0
        fi
        if [ "$_gi_mut_par_ok" -eq 1 ] && [ "$_gi_rc" -ne 0 ] \
          && [[ "$_gi_out" == *NO-IDENT-COMMITTED* ]] && [[ "$_gi_out" == *LEAKED-EXCLUDESFILE* ]]; then
          ok "56-M1 (${_gi_path}): git 隔離を外す変異で作者無し commit が緑化し、core.excludesfile が漏れて赤になる（56-A / 56-D が検出する）"
        else
          bad "56-M1 (${_gi_path}): 隔離除去の変異を観測できない（rc=${_gi_rc}, par_ok=${_gi_mut_par_ok}）"
          printf '%s\n' "$_gi_out" | tail -n 20 | sed 's/^/    | /' >&2
        fi
      done
    fi

    # 56-M2: 隔離ファイルから user.useConfigOnly を外した空ファイルでは --file 読み戻しが true にならない
    if [ "$(git config --file "$_gi_dir/empty.gitconfig" --bool --get user.useConfigOnly 2>/dev/null || true)" != "true" ]; then
      ok "56-M2: 空の隔離ファイルでは --file 読み戻しの user.useConfigOnly が true にならず 56-0 が検出する"
    else
      bad "56-M2: 空の隔離ファイルでも user.useConfigOnly が true になった（56-0 が空振り）"
    fi
  fi
  rm -rf "$_gi_dir"
fi
# suite-cases-end: git-env-isolation.sh
