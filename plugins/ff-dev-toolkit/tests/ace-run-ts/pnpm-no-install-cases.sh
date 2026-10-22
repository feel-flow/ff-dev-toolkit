#!/usr/bin/env bash
# verify.sh から source する。実 pnpm の exec 前依存確認を、隔離 PATH 内で模す。
# probe だけ抑止しても、本番 exec で再び install する退行を別々に検出する。

_write_pnpm_no_install_shim() { # <出力> <既存 runner double> <mkdir の実体> <available|missing|record>
  local out="$1" delegate="$2" mkdir_abs="$3" mode="$4"
  {
    printf '#!/bin/bash\n'
    printf 'phase=gate\n'
    printf 'for arg in "$@"; do case "${arg##*/}" in %s) phase=probe ;; esac; done\n' "${PROBE_BASE}"
    printf 'printf "PNPM_NO_INSTALL phase=%%s verify=%%s cwd=%%s\\n" "${phase}" "${pnpm_config_verify_deps_before_run:-unset}" "${PWD}" >> %q\n' "${SHIM_LOG}"
    printf 'if [ %q != record ] && [ "${pnpm_config_verify_deps_before_run:-install}" != false ]; then\n' "${mode}"
    printf '  %q -p "${PWD}/node_modules"\n' "${mkdir_abs}"
    printf '  printf "importers: { .: {} }\\n" > "${PWD}/pnpm-lock.yaml"\n'
    printf '  printf "{}\\n" > "${PWD}/node_modules/.pnpm-workspace-state-v1.json"\n'
    printf 'fi\n'
    [ "${mode}" != missing ] || printf 'exit 1\n'
    printf 'exec %q "$@"\n' "${delegate}"
  } > "${out}"
  chmod +x "${out}"
}

_pnpm_no_install_cases() {
  local fixture="${SANDBOX}/pnpm automatic" mkdir_abs delegate selected_bin missing_bin fallback_bin explicit_bin
  local selected missing fallback explicit caller_delegate line
  # 親から install が指定されていても、自動 pnpm だけが false を受ける。
  # local + export はこのケース群の外へ設定を漏らさない。
  local pnpm_config_verify_deps_before_run=install
  export pnpm_config_verify_deps_before_run
  mkdir_abs="$(command -v mkdir || true)"
  if [ ! -x "${mkdir_abs}" ]; then
    bad "暗黙 install double 用の mkdir を解決できません"
    return 1
  fi
  mkdir -p "${fixture}"
  delegate="${fixture}/pnpm-delegate"
  _write_shim "${delegate}" pnpm 2

  echo
  echo "== 自動 pnpm の依存確認は probe・本番とも install しない =="
  selected="${fixture}/selected workspace"
  mkdir -p "${selected}/packages/docs"
  selected="${selected}/packages/docs"
  selected_bin="$(_bin_with)"
  _write_pnpm_no_install_shim "${selected_bin}/pnpm" "${delegate}" "${mkdir_abs}" available
  _run "${selected}" "${selected_bin}" "${STUB_TS}" "arg with space" plain
  case "${RES_RC}:${RES_OUT}" in
    0:*'runner=pnpm exec tsx'*'RAN pnpm argc=3'*) ok "自動 pnpm の表示名と最終実行を保つ" ;;
    *) bad "自動 pnpm の選択・最終実行が成立しない（rc=${RES_RC} / ${RES_OUT}）" ;;
  esac
  for line in "phase=probe verify=false cwd=${selected}" "phase=gate verify=false cwd=${selected}"; do
    if grep -Fqx -- "PNPM_NO_INSTALL ${line}" "${SHIM_LOG}"; then
      ok "自動 pnpm の実呼び出しで設定と cwd を確認する: ${line}"
    else
      bad "自動 pnpm の対象呼び出しが無いか設定・cwd が違う: ${line}（$(cat "${SHIM_LOG}")）"
    fi
  done
  if [ ! -e "${selected}/pnpm-lock.yaml" ] && [ ! -e "${selected}/node_modules" ]; then
    ok "probe と本番のどちらも空 lockfile・管理用 node_modules を作らない"
  else
    bad "自動 pnpm の probe または本番が暗黙 install の成果物を残した"
  fi
  case "${RES_OUT}" in
    *"ARG[${STUB_TS}]"*'ARG[arg with space]'*'ARG[plain]'*) ok "自動 pnpm へ空白パス・空白引数を単一引数のまま渡す" ;;
    *) bad "自動 pnpm の引数境界が壊れた（${RES_OUT}）" ;;
  esac
  RUN_FAKE_RC=7
  _run "${selected}" "${selected_bin}" "${STUB_TS}"
  if [ "${RES_RC}" -eq 7 ] && [ ! -e "${selected}/pnpm-lock.yaml" ] && [ ! -e "${selected}/node_modules" ]; then
    ok "自動 pnpm の最終ゲート失敗もそのまま返し、暗黙 install しない"
  else
    bad "自動 pnpm の終了コード伝播または失敗時の抑止が壊れた（rc=${RES_RC}）"
  fi

  missing="${fixture}/missing"
  mkdir -p "${missing}"
  missing_bin="$(_bin_with)"
  _write_pnpm_no_install_shim "${missing_bin}/pnpm" "${delegate}" "${mkdir_abs}" missing
  _run "${missing}" "${missing_bin}" "${STUB_TS}"
  case "${RES_RC}:${RES_OUT}" in
    3:*'FF_ACE_TS_RUNNER='*) ok "全候補が使えないときは rc=3 で明示 runner の復旧方法を案内する" ;;
    *) bad "候補全滅の停止・復旧案内が壊れた（rc=${RES_RC} / ${RES_OUT}）" ;;
  esac
  if grep -Fqx -- "PNPM_NO_INSTALL phase=probe verify=false cwd=${missing}" "${SHIM_LOG}" \
    && [ ! -e "${missing}/pnpm-lock.yaml" ] && [ ! -e "${missing}/node_modules" ]; then
    ok "不採用の pnpm probe にも針が当たり、呼び出し元へ成果物を残さない"
  else
    bad "不採用 pnpm の probe が未実行、または暗黙 install した（$(cat "${SHIM_LOG}")）"
  fi

  fallback="${fixture}/fallback"
  mkdir -p "${fallback}"
  fallback_bin="$(_bin_with)"
  _write_pnpm_no_install_shim "${fallback_bin}/pnpm" "${delegate}" "${mkdir_abs}" missing
  caller_delegate="${fixture}/yarn-delegate"
  _write_shim "${caller_delegate}" yarn 2
  {
    printf '#!/bin/bash\n'
    printf 'printf "INHERITED_VERIFY:%%s\\n" "${pnpm_config_verify_deps_before_run:-unset}"\n'
    printf 'exec %q "$@"\n' "${caller_delegate}"
  } > "${fallback_bin}/yarn"
  chmod +x "${fallback_bin}/yarn"
  _run "${fallback}" "${fallback_bin}" "${STUB_TS}"
  case "${RES_RC}:${RES_OUT}" in
    0:*'runner=yarn exec tsx'*'INHERITED_VERIFY:install'*) ok "pnpm 不採用後の yarn には元の環境を渡す" ;;
    *) bad "pnpm の抑止設定が次候補へ漏れた（rc=${RES_RC} / ${RES_OUT}）" ;;
  esac

  explicit="${fixture}/explicit"
  mkdir -p "${explicit}"
  explicit_bin="$(_bin_with)"
  _write_pnpm_no_install_shim "${explicit_bin}/pnpm" "${delegate}" "${mkdir_abs}" record
  RUN_RUNNER='pnpm --filter @fixture/docs exec tsx'
  _run "${explicit}" "${explicit_bin}" "${STUB_TS}"
  if [ "${RES_RC}" -eq 0 ] \
    && grep -Fqx -- "PNPM_NO_INSTALL phase=probe verify=install cwd=${explicit}" "${SHIM_LOG}" \
    && grep -Fqx -- "PNPM_NO_INSTALL phase=gate verify=install cwd=${explicit}" "${SHIM_LOG}"; then
    ok "明示 pnpm runner の probe・本番へ自動候補の設定を持ち込まない"
  else
    bad "明示 pnpm runner の環境を変えた（rc=${RES_RC} / $(cat "${SHIM_LOG}")）"
  fi

  unset pnpm_config_verify_deps_before_run
  _run "${selected}" "${selected_bin}" "${STUB_TS}"
  if [ "${RES_RC}" -eq 0 ] \
    && grep -Fqx -- "PNPM_NO_INSTALL phase=probe verify=false cwd=${selected}" "${SHIM_LOG}" \
    && grep -Fqx -- "PNPM_NO_INSTALL phase=gate verify=false cwd=${selected}" "${SHIM_LOG}" \
    && [ ! -e "${selected}/pnpm-lock.yaml" ] && [ ! -e "${selected}/node_modules" ]; then
    ok "設定未指定でも自動 pnpm の両段で設定・cwd・成果物の不在を確認する"
  else
    bad "未指定環境の自動 pnpm に副作用または設定漏れがある（rc=${RES_RC}）"
  fi
}

_pnpm_no_install_cases
