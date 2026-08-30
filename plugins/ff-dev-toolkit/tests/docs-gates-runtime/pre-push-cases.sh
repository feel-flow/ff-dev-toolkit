#!/usr/bin/env bash
#
# multi-cli-review の pre-push 例を、固定 plugin root の sidecar と resource を含む
# 独立 fixture で実行する。親 verify.sh の一時領域・判定関数を利用する。

pre_push_case_inputs_valid() {
  local report_fixture="$1" root_mode="$2" shell_mode="$3" target_resource="$4"
  case "$shell_mode" in
    bash|sh-e) ;;
    *) return 2 ;;
  esac
  case "$root_mode" in
    valid|missing-sidecar|empty-sidecar|unterminated-sidecar|relative-sidecar|\
    missing-resource|empty-resource|nonexec-resource|directory-resource|\
    dangling-resource|symlink-resource|symlink-sidecar|symlink-scripts|\
    missing-manifest|wrong-manifest|symlink-manifest|tracked-sidecar|space-sidecar) ;;
    *) return 2 ;;
  esac
  case "$target_resource" in
    setup-multi-agent.sh|multi-agent.sh|multi-review.sh) ;;
    *) return 2 ;;
  esac
  case "$report_fixture" in
    __EMPTY__|__MISSING__|__STALE_ONLY__|__GREP_ERROR__|__MKTEMP_ERROR__) ;;
    *) [ -f "$report_fixture" ] && [ ! -L "$report_fixture" ] || return 2 ;;
  esac
}

run_pre_push_case() {
  local label="$1" runner_rc="$2" report_fixture="$3" expected="$4"
  local root_mode="${5:-valid}"
  local shell_mode="${6:-bash}"
  local target_resource="${7:-multi-review.sh}"
  local case_dir output sentinel output_dir_sentinel report_mode case_path resource_file rc=0

  if ! pre_push_case_inputs_valid "$report_fixture" "$root_mode" "$shell_mode" "$target_resource"; then
    bad "$label — pre-push fixture引数が契約外"
    return
  fi

  PRE_PUSH_CASE=$((PRE_PUSH_CASE + 1))
  case_dir="$TMP_ROOT/pre-push-$PRE_PUSH_CASE"
  output="$case_dir/output.txt"
  sentinel="$case_dir/review-ran"
  output_dir_sentinel="$case_dir/review-output-dir"
  mkdir -p "$case_dir/scripts" "$case_dir/.review-results" "$case_dir/.claude-plugin"
  printf '%s\n' '{' '  "name": "ff-dev-toolkit",' '  "version": "fixture"' '}' \
    >"$case_dir/.claude-plugin/plugin.json"
  git -C "$case_dir" init -q

  # stub 自身が実行時に読む式なので、生成側では意図的に展開しない。
  # 今回渡された --output-dir にだけレポートを生成し、固定pathの前回成果物を
  # pre-push例が誤読できないことも検査する。
  # shellcheck disable=SC2016
  for resource_file in setup-multi-agent.sh multi-agent.sh multi-review.sh; do
    if [ "$resource_file" = multi-review.sh ]; then
      printf '%s\n' \
        '#!/usr/bin/env bash' \
        'touch "$FF_STUB_SENTINEL"' \
        'output_dir=""' \
        'while [ "$#" -gt 0 ]; do' \
        '  case "$1" in' \
        '    --output-dir) output_dir="$2"; shift 2 ;;' \
        '    *) shift ;;' \
        '  esac' \
        'done' \
        'printf "%s\n" "$output_dir" >"$FF_STUB_OUTPUT_DIR_SENTINEL"' \
        'if [ "${FF_STUB_REVIEW_RC:-0}" -ne 0 ]; then exit "$FF_STUB_REVIEW_RC"; fi' \
        'case "${FF_STUB_REPORT_MODE:-copy}" in' \
        '  copy)' \
        '    mkdir -p "$output_dir"' \
        '    cp "$FF_STUB_REPORT_FIXTURE" "$output_dir/integrated-report.md"' \
        '    ;;' \
        '  empty) mkdir -p "$output_dir"; : >"$output_dir/integrated-report.md" ;;' \
        '  directory) mkdir -p "$output_dir/integrated-report.md" ;;' \
        '  missing) : ;;' \
        '  *) exit 2 ;;' \
        'esac' \
        'exit 0' > "$case_dir/scripts/$resource_file"
    else
      printf '%s\n' '#!/usr/bin/env bash' 'exit "${FF_STUB_REVIEW_RC:-0}"' \
        > "$case_dir/scripts/$resource_file"
    fi
    chmod +x "$case_dir/scripts/$resource_file"
  done
  case "$root_mode" in
    valid) printf '%s\n' "$case_dir/scripts" > "$case_dir/scripts/.ff-dev-toolkit-root" ;;
    missing-sidecar) ;;
    empty-sidecar) : > "$case_dir/scripts/.ff-dev-toolkit-root" ;;
    unterminated-sidecar) printf '%s' "$case_dir/scripts" > "$case_dir/scripts/.ff-dev-toolkit-root" ;;
    relative-sidecar)
      mkdir -p "$case_dir/relative"
      cp -R "$case_dir/scripts" "$case_dir/relative/scripts"
      printf '%s\n' 'relative/scripts' > "$case_dir/scripts/.ff-dev-toolkit-root"
      ;;
    missing-resource)
      printf '%s\n' "$case_dir/scripts" > "$case_dir/scripts/.ff-dev-toolkit-root"
      mv "$case_dir/scripts/$target_resource" "$case_dir/scripts/$target_resource.absent"
      ;;
    empty-resource)
      printf '%s\n' "$case_dir/scripts" > "$case_dir/scripts/.ff-dev-toolkit-root"
      : > "$case_dir/scripts/$target_resource"
      chmod +x "$case_dir/scripts/$target_resource"
      ;;
    nonexec-resource)
      printf '%s\n' "$case_dir/scripts" > "$case_dir/scripts/.ff-dev-toolkit-root"
      chmod -x "$case_dir/scripts/$target_resource"
      ;;
    directory-resource)
      printf '%s\n' "$case_dir/scripts" > "$case_dir/scripts/.ff-dev-toolkit-root"
      mv "$case_dir/scripts/$target_resource" "$case_dir/scripts/$target_resource.file"
      mkdir "$case_dir/scripts/$target_resource"
      ;;
    dangling-resource)
      printf '%s\n' "$case_dir/scripts" > "$case_dir/scripts/.ff-dev-toolkit-root"
      mv "$case_dir/scripts/$target_resource" "$case_dir/scripts/$target_resource.file"
      ln -s "$case_dir/scripts/not-found.sh" "$case_dir/scripts/$target_resource"
      ;;
    symlink-resource)
      printf '%s\n' "$case_dir/scripts" > "$case_dir/scripts/.ff-dev-toolkit-root"
      mv "$case_dir/scripts/$target_resource" "$case_dir/scripts/$target_resource.file"
      ln -s "$case_dir/scripts/$target_resource.file" "$case_dir/scripts/$target_resource"
      ;;
    symlink-sidecar)
      printf '%s\n' "$case_dir/scripts" > "$case_dir/sidecar-target"
      ln -s "$case_dir/sidecar-target" "$case_dir/scripts/.ff-dev-toolkit-root"
      ;;
    symlink-scripts)
      mv "$case_dir/scripts" "$case_dir/scripts-real"
      ln -s "$case_dir/scripts-real" "$case_dir/scripts"
      printf '%s\n' "$case_dir/scripts" > "$case_dir/scripts-real/.ff-dev-toolkit-root"
      ;;
    missing-manifest)
      printf '%s\n' "$case_dir/scripts" > "$case_dir/scripts/.ff-dev-toolkit-root"
      rm "$case_dir/.claude-plugin/plugin.json"
      ;;
    wrong-manifest)
      printf '%s\n' "$case_dir/scripts" > "$case_dir/scripts/.ff-dev-toolkit-root"
      printf '%s\n' '{' '  "name": "another-plugin"' '}' \
        >"$case_dir/.claude-plugin/plugin.json"
      ;;
    symlink-manifest)
      printf '%s\n' "$case_dir/scripts" > "$case_dir/scripts/.ff-dev-toolkit-root"
      mv "$case_dir/.claude-plugin/plugin.json" "$case_dir/manifest-real.json"
      ln -s "$case_dir/manifest-real.json" "$case_dir/.claude-plugin/plugin.json"
      ;;
    tracked-sidecar)
      printf '%s\n' "$case_dir/scripts" > "$case_dir/scripts/.ff-dev-toolkit-root"
      git -C "$case_dir" add scripts/.ff-dev-toolkit-root
      ;;
    space-sidecar)
      mkdir -p "$case_dir/toolkit root"
      cp -R "$case_dir/scripts" "$case_dir/toolkit root/scripts"
      cp -R "$case_dir/.claude-plugin" "$case_dir/toolkit root/.claude-plugin"
      printf '%s\n' "$case_dir/toolkit root/scripts" \
        > "$case_dir/scripts/.ff-dev-toolkit-root"
      ;;
    *) bad "未知のpre-push root fixture: $root_mode"; return ;;
  esac

  report_mode=copy
  case_path="$PATH"
  case "$report_fixture" in
    __EMPTY__)
      report_mode=empty
      ;;
    __MISSING__)
      report_mode=missing
      ;;
    __STALE_ONLY__)
      cp "$FIXTURES/pre-push/normal-report.md" \
        "$case_dir/.review-results/integrated-report.md"
      report_mode=missing
      ;;
    __GREP_ERROR__)
      report_mode=directory
      ;;
    __MKTEMP_ERROR__)
      mkdir -p "$case_dir/bin"
      printf '%s\n' '#!/bin/sh' 'exit 1' >"$case_dir/bin/mktemp"
      chmod +x "$case_dir/bin/mktemp"
      case_path="$case_dir/bin:$PATH"
      ;;
  esac

  if [ "$shell_mode" = sh-e ]; then
    (cd "$case_dir" && FF_STUB_REVIEW_RC="$runner_rc" FF_STUB_SENTINEL="$sentinel" \
      FF_STUB_REPORT_MODE="$report_mode" FF_STUB_REPORT_FIXTURE="$report_fixture" \
      FF_STUB_OUTPUT_DIR_SENTINEL="$output_dir_sentinel" \
      PATH="$case_path" \
      sh -e "$PRE_PUSH_SCRIPT" >"$output" 2>&1) || rc=$?
  else
    (cd "$case_dir" && FF_STUB_REVIEW_RC="$runner_rc" FF_STUB_SENTINEL="$sentinel" \
      FF_STUB_REPORT_MODE="$report_mode" FF_STUB_REPORT_FIXTURE="$report_fixture" \
      FF_STUB_OUTPUT_DIR_SENTINEL="$output_dir_sentinel" \
      PATH="$case_path" \
      bash "$PRE_PUSH_SCRIPT" >"$output" 2>&1) || rc=$?
  fi

  if [ "$rc" -eq "$expected" ]; then
    if [ "$expected" -eq 0 ] && [ ! -e "$sentinel" ]; then
      bad "$label — 正常系でreview起動sentinelへ到達しない"
    elif [ "$expected" -eq 0 ] && { \
      [ ! -s "$output_dir_sentinel" ] \
        || [ ! -e "$(sed -n '1p' "$output_dir_sentinel")" ] \
        || ! grep -qF "$(sed -n '1p' "$output_dir_sentinel")" "$output";
    }; then
      bad "$label — 成功時の出力先を案内・保全していない"
    elif [ "$expected" -eq 1 ] && [ -s "$output_dir_sentinel" ] \
      && { ! grep -qF "$(sed -n '1p' "$output_dir_sentinel")" "$output" \
        || [ ! -e "$(sed -n '1p' "$output_dir_sentinel")" ]; }; then
      bad "$label — 失敗時の出力先を案内・保全していない"
    elif [ "$expected" -eq 1 ] && [ ! -s "$output_dir_sentinel" ] \
      && [ -e "$sentinel" ]; then
      bad "$label — 出力先作成失敗後にreviewを起動した"
    elif [ "$expected" -eq 2 ] && { \
      ! grep -qF 'setup-multi-agent.shを再実行してください' "$output" \
      || [ -e "$sentinel" ];
    }; then
      bad "$label — exit 2 だが再セットアップ案内が無い、またはreviewを起動した"
    elif [ "$root_mode" = relative-sidecar ] \
      && ! grep -qF '固定rootを解決できません' "$output"; then
      bad "$label — 相対path専用の固定root診断へ到達していない"
    else
      ok "$label (exit $rc)"
    fi
  else
    bad "$label — exit ${rc}、期待 ${expected}"
    sed 's/^/      | /' "$output" >&2
  fi
}

run_pre_push_cases() {
  local PRE_PUSH_CASE=0
  local resource mode

  echo
  echo "== multi-cli-review pre-push 例の fixture 実行 =="
  if pre_push_case_inputs_valid "$FIXTURES/pre-push/normal-report.md" valid bash multi-review.sh; then
    ok "pre-push fixture APIは正しいenumと通常ファイルを受理"
  else
    bad "pre-push fixture APIが正常な入力を拒否"
  fi
  if ! pre_push_case_inputs_valid "$FIXTURES/pre-push/normal-report.md" valid typo multi-review.sh \
    && ! pre_push_case_inputs_valid "$FIXTURES/pre-push/normal-report.md" typo bash multi-review.sh \
    && ! pre_push_case_inputs_valid "$FIXTURES/pre-push/normal-report.md" valid bash typo.sh \
    && ! pre_push_case_inputs_valid "$FIXTURES/pre-push/missing.md" valid bash multi-review.sh; then
    ok "pre-push fixture APIは未知enum・不存在fixtureを実行前に拒否"
  else
    bad "pre-push fixture APIが未知enumまたは不存在fixtureを受理"
  fi
  run_pre_push_case "正常なレビュー実行 + 統合レポート" 0 \
    "$FIXTURES/pre-push/normal-report.md" 0
  run_pre_push_case "Huskyのerrexit環境でも正常レポートを通す" 0 \
    "$FIXTURES/pre-push/normal-report.md" 0 valid sh-e
  run_pre_push_case "レビュースクリプト非 0 はブロック" 7 \
    "$FIXTURES/pre-push/normal-report.md" 1
  run_pre_push_case "Huskyのerrexit環境でもreview非0をブロック" 7 \
    "$FIXTURES/pre-push/normal-report.md" 1 valid sh-e
  run_pre_push_case "空の統合レポートはブロック" 0 __EMPTY__ 1
  run_pre_push_case "前回の固定pathレポートだけでは今回成功にしない" 0 __STALE_ONLY__ 1
  run_pre_push_case "統合レポートのgrep異常を指摘なしとして通さない" 0 __GREP_ERROR__ 1
  run_pre_push_case "Huskyのerrexit環境でもgrep異常をブロック" 0 __GREP_ERROR__ 1 valid sh-e
  run_pre_push_case "一時出力先作成失敗はreviewを起動せずブロック" 0 __MKTEMP_ERROR__ 1
  run_pre_push_case "INCOMPLETE を含む統合レポートはブロック" 0 \
    "$FIXTURES/pre-push/incomplete-report.md" 1
  run_pre_push_case "Huskyのerrexit環境でもINCOMPLETEをブロック" 0 \
    "$FIXTURES/pre-push/incomplete-report.md" 1 valid sh-e
  run_pre_push_case "CRITICAL_BLOCK マーカーを含む統合レポートはブロック" 0 \
    "$FIXTURES/pre-push/critical-report.md" 1
  run_pre_push_case "Huskyのerrexit環境でもCRITICAL_BLOCKをブロック" 0 \
    "$FIXTURES/pre-push/critical-report.md" 1 valid sh-e
  # 判定はマーカー**全文**の固定文字列一致（Issue #645 の観点別段階化の前提）。
  # 本文中の裸の CRITICAL_BLOCK 言及や CRITICAL_NONBLOCK 注記で部分一致誤発火すると、
  # 非ブロック観点だけの実行でもゲートが再発火し段階化が無効になる。
  run_pre_push_case "裸の CRITICAL_BLOCK 言及 + 非ブロック注記のみはブロックしない" 0 \
    "$FIXTURES/pre-push/mention-only-report.md" 0
  run_pre_push_case "sidecar欠落はレビューを起動せず案内付きで拒否" 0 \
    "$FIXTURES/pre-push/normal-report.md" 2 missing-sidecar
  run_pre_push_case "Huskyのerrexit環境でもsidecar欠落をstatus 2で拒否" 0 \
    "$FIXTURES/pre-push/normal-report.md" 2 missing-sidecar sh-e
  run_pre_push_case "空sidecarはレビューを起動せず案内付きで拒否" 0 \
    "$FIXTURES/pre-push/normal-report.md" 2 empty-sidecar
  run_pre_push_case "改行終端のないsidecarは部分値を使わず拒否" 0 \
    "$FIXTURES/pre-push/normal-report.md" 2 unterminated-sidecar
  run_pre_push_case "相対path sidecarは案内付きで拒否" 0 \
    "$FIXTURES/pre-push/normal-report.md" 2 relative-sidecar
  for resource in setup-multi-agent.sh multi-agent.sh multi-review.sh; do
    for mode in missing empty directory dangling symlink; do
      run_pre_push_case "${resource}の${mode} fixtureはreviewを起動せず拒否" 0 \
        "$FIXTURES/pre-push/normal-report.md" 2 "${mode}-resource" bash "$resource"
    done
    run_pre_push_case "${resource}は非実行でもbash入口でreviewを続行" 0 \
      "$FIXTURES/pre-push/normal-report.md" 0 nonexec-resource bash "$resource"
  done
  run_pre_push_case "Huskyのerrexit環境でもresource欠落をstatus 2で拒否" 0 \
    "$FIXTURES/pre-push/normal-report.md" 2 missing-resource sh-e multi-review.sh
  run_pre_push_case "sidecar symlinkはreviewを起動せず拒否" 0 \
    "$FIXTURES/pre-push/normal-report.md" 2 symlink-sidecar
  run_pre_push_case "scripts directory symlinkはreviewを起動せず拒否" 0 \
    "$FIXTURES/pre-push/normal-report.md" 2 symlink-scripts
  for mode in missing wrong symlink; do
    run_pre_push_case "${mode} plugin manifestはreviewを起動せず拒否" 0 \
      "$FIXTURES/pre-push/normal-report.md" 2 "${mode}-manifest"
  done
  run_pre_push_case "Git管理下のsidecarはreviewを起動せず拒否" 0 \
    "$FIXTURES/pre-push/normal-report.md" 2 tracked-sidecar
  run_pre_push_case "空白を含む絶対sidecar pathはreviewを起動" 0 \
    "$FIXTURES/pre-push/normal-report.md" 0 space-sidecar
}
