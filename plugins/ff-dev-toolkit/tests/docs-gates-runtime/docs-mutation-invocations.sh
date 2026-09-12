#!/usr/bin/env bash
# Issue #1011: docs gate の positive control と mutation 一覧。
# verify.sh から source し、run_docs_gate_mutation を使って実行する。

run_docs_gate_mutations() {
  local positive_root="$TMP_ROOT/docs-mutation-positive"
  local positive_log="$TMP_ROOT/docs-mutation-positive.log" positive_rc=0

  echo
  echo "== consumer review entrypoint の mutation 検査 =="
  cp -R "$DOCS" "$positive_root"
  FF_DOCS_GATE_DOCS="$positive_root" \
    bash "$PLUGIN_ROOT/tests/docs-gates/verify.sh" >"$positive_log" 2>&1 || positive_rc=$?
  if [ "$positive_rc" -eq 0 ]; then
    ok "positive control: 無変異のdocsコピーは静的gateを通過"
  else
    bad "positive control: 無変異のdocsコピーを静的gateが拒否 (rc=${positive_rc})"
    sed -n '1,160p' "$positive_log" >&2 || true
  fi

  run_docs_gate_mutation consumer-inline \
    "inline codeのconsumer-local setup入口を拒否する" \
    "未配置の consumer-local review 入口"
  run_docs_gate_mutation consumer-zsh \
    "zsh経由のconsumer-local multi-agent入口を拒否する" \
    "未配置の consumer-local review 入口"
  run_docs_gate_mutation consumer-continuation \
    "改行付きconsumer-local multi-review入口を拒否する" \
    "未配置の consumer-local review 入口"
  run_docs_gate_mutation consumer-shell-option \
    "shell option付きconsumer-local multi-review入口を拒否する" \
    "未配置の consumer-local review 入口"
  run_docs_gate_mutation consumer-multiline-options \
    "複数段のshell option付きconsumer-local入口を拒否する" \
    "未配置の consumer-local review 入口"
  run_docs_gate_mutation consumer-inline-direct \
    "inline codeの直接consumer-local multi-agent入口を拒否する" \
    "未配置の consumer-local review 入口"
  run_docs_gate_mutation consumer-bullet-direct \
    "箇条書きのconsumer-local入口を拒否する" \
    "未配置の consumer-local review 入口"
  run_docs_gate_mutation consumer-ordered-direct \
    "番号付き箇条書きのconsumer-local入口を拒否する" \
    "未配置の consumer-local review 入口"
  run_docs_gate_mutation consumer-normalized-dot \
    "scripts/./形式のconsumer-local入口を拒否する" \
    "未配置の consumer-local review 入口"
  run_docs_gate_mutation consumer-normalized-slash \
    "wrapper経由のscripts//形式consumer-local入口を拒否する" \
    "未配置の consumer-local review 入口"
  run_docs_gate_mutation consumer-command-wrapper \
    "command経由のconsumer-local multi-review入口を拒否する" \
    "未配置の consumer-local review 入口"
  run_docs_gate_mutation consumer-exec-wrapper \
    "exec経由のconsumer-local multi-agent入口を拒否する" \
    "未配置の consumer-local review 入口"
  run_docs_gate_mutation consumer-env-wrapper \
    "env経由のconsumer-local setup入口を拒否する" \
    "未配置の consumer-local review 入口"
  run_docs_gate_mutation consumer-absolute-shell \
    "絶対pathのshell経由consumer-local入口を拒否する" \
    "未配置の consumer-local review 入口"
  run_docs_gate_mutation consumer-source \
    "source経由のconsumer-local multi-agent入口を拒否する" \
    "未配置の consumer-local review 入口"
  run_docs_gate_mutation consumer-dot-source \
    "dot source経由のconsumer-local setup入口を拒否する" \
    "未配置の consumer-local review 入口"
  run_docs_gate_mutation consumer-test-probe \
    "test probeのconsumer-local multi-review入口を拒否する" \
    "未配置の consumer-local review 入口"
  run_docs_gate_mutation deleg-link-moved-out-of-section \
    "並列委譲手順から委譲の待機・回収規定のリンクを外し同一文書内の別節へ移す退行を拒否する" \
    "git-workflow.md の並列委譲手順から子側（foreground 待機）の正本節へ到達できる —"
  run_docs_gate_mutation deleg-timeout-value-dropped \
    "並列委譲手順からタイムアウトの実値が消える退行を拒否する" \
    "git-workflow.md の並列委譲手順がタイムアウトの実値を持つ"
  run_docs_gate_mutation late-prerequisite \
    "最初の実行例より後ろにあるplugin root前提を拒否する" \
    "最初の実行例より前に有効な plugin root 前提"
  run_docs_gate_mutation root-command-disappears \
    "文書単位で正準commandが消える退行を拒否する" \
    "実行例を載せる文書集合が期待値と不一致"
  run_docs_gate_mutation unguarded-direct \
    "対話用の直接実行例からroot guardが消える退行を拒否する" \
    "guardなしのplugin root直接実行例"
  run_docs_gate_mutation unguarded-env-direct \
    "env wrapper付き直接実行例からroot guardが消える退行を拒否する" \
    "guardなしのplugin root直接実行例"
  run_docs_gate_mutation unguarded-sh-direct \
    "sh経由のguardなしplugin root入口を拒否する" \
    "guardなしのplugin root直接実行例"
  run_docs_gate_mutation unguarded-bare-direct \
    "launcher無しのguardなしplugin root入口を拒否する" \
    "guardなしのplugin root直接実行例"
  run_docs_gate_mutation unguarded-if-direct \
    "if条件内のguardなしplugin root入口を拒否する" \
    "guardなしのplugin root直接実行例"
  run_docs_gate_mutation unguarded-run-direct \
    "generic YAML run内のguardなしplugin root入口を拒否する" \
    "guardなしのplugin root直接実行例"
  run_docs_gate_mutation consumer-guard-missing \
    "対話用の直接実行例からconsumer root guardが消える退行を拒否する" \
    "guardなしのplugin root直接実行例"
  run_docs_gate_mutation ci-checkout-path-drift \
    "CI checkout先と配置元のpath driftを拒否する" \
    "CI例のpin配置または全resource検証が不完全"
  run_docs_gate_mutation ci-checkout-ref-drift \
    "CI checkoutがreview済みrefから外れる退行を拒否する" \
    "CI例のpin配置または全resource検証が不完全"
  run_docs_gate_mutation ci-fork-gate-missing \
    "fork PRを認証付きreview jobから除外する条件の消失を拒否する" \
    "CI例のpin配置または全resource検証が不完全"
  run_docs_gate_mutation ci-trigger-target \
    "CI triggerがpull_request_targetへ移る退行を拒否する" \
    "YAML階層が不正"
  run_docs_gate_mutation ci-fork-gate-moved \
    "fork除外条件がjob階層から移る退行を拒否する" \
    "YAML階層が不正"
  run_docs_gate_mutation ci-upload-condition-moved \
    "artifact回収条件がreview stepへ移る退行を拒否する" \
    "YAML階層が不正"
  run_docs_gate_mutation ci-action-unpinned \
    "CI Actionが可変tagへ戻る退行を拒否する" \
    "CI例のActionsまたはCLI version pinが不完全"
  run_docs_gate_mutation ci-cli-unpinned \
    "CI CLI installからversion pinが消える退行を拒否する" \
    "CI例のActionsまたはCLI version pinが不完全"
  run_docs_gate_mutation ci-runtime-pin-guard-missing \
    "CI runtimeの40文字SHA検証が緩む退行を拒否する" \
    "CI例のpin配置または全resource検証が不完全"
  run_docs_gate_mutation ci-checkout-head-check-missing \
    "CI checkout実体と指定pinの照合が消える退行を拒否する" \
    "CI例のpin配置または全resource検証が不完全"
  run_docs_gate_mutation ci-resource-symlink-guard-missing \
    "CI resourceのsymlink拒否が消える退行を拒否する" \
    "CI例のpin配置または全resource検証が不完全"
  run_docs_gate_mutation ci-verify-continue-on-error \
    "CI Verifyの失敗継続を拒否する" \
    "CI例のpin配置または全resource検証が不完全"
  run_docs_gate_mutation ci-review-always \
    "CI reviewのalways実行を拒否する" \
    "YAML階層が不正"
  run_docs_gate_mutation ci-top-env-runner-context \
    "workflow-level envのrunner context再混入を拒否する" \
    "CI例のpin配置または全resource検証が不完全"
  run_docs_gate_mutation ci-report-verification-missing \
    "CI統合レポート検証stepの消失を拒否する" \
    "CI例のpin配置または全resource検証が不完全"
  run_docs_gate_mutation unquoted-root \
    "引用符だけを外したplugin root commandを拒否する" \
    "引用付き正準形ではない"
  run_docs_gate_mutation alternate-root \
    "一部文書だけCLAUDE_PLUGIN_ROOTへ置換する退行を拒否する" \
    "引用付き正準形ではない"
  run_docs_gate_mutation aliased-root-command \
    "別名変数経由でreview resourceを呼ぶ退行を拒否する" \
    "引用付き正準形ではない"
  run_docs_gate_mutation bullet-alternate-root \
    "箇条書き内の別root直接入口を拒否する" \
    "引用付き正準形ではない"
  run_docs_gate_mutation multiline-root \
    "plugin root commandを未引用の次行へ逃がす退行を拒否する" \
    "review resource command を複数行に分割している"
  run_docs_gate_mutation option-unquoted-root \
    "shell option後の未引用plugin root commandを拒否する" \
    "引用付き正準形ではない"
  run_docs_gate_mutation direct-alternate-root \
    "shellを介さない別rootのreview resource commandを拒否する" \
    "引用付き正準形ではない"
  run_docs_gate_mutation quoted-direct-alternate-root \
    "引用付き別rootの直接review resource commandを拒否する" \
    "引用付き正準形ではない"
  run_docs_gate_mutation quoted-absolute-cache \
    "引用付きversioned cache絶対pathの直接実行を拒否する" \
    "引用付き正準形ではない"
  run_docs_gate_mutation command-alternate-root \
    "command経由の別root review resourceを拒否する" \
    "引用付き正準形ではない"
  run_docs_gate_mutation test-alternate-root \
    "test probe経由の別root review resourceを拒否する" \
    "引用付き正準形ではない"
  run_docs_gate_mutation same-line-alternate-root \
    "同一行後方の正準commandで別root入口を隠せない" \
    "引用付き正準形ではない"
  run_docs_gate_mutation comment-covered-alternate-root \
    "コメント中の正準commandで別root入口を隠せない" \
    "引用付き正準形ではない"
  run_docs_gate_mutation fake-prerequisite \
    "anchorだけの偽文書をplugin root前提として受理しない" \
    "最初の実行例より前に有効な plugin root 前提"
  run_docs_gate_mutation inline-prerequisite \
    "inline code内だけのplugin root前提linkを受理しない" \
    "最初の実行例より前に有効な plugin root 前提"
  run_docs_gate_mutation tilde-prerequisite \
    "tilde fence内だけのplugin root前提linkを受理しない" \
    "最初の実行例より前に有効な plugin root 前提"
  run_docs_gate_mutation bare-parenthesis-prerequisite \
    "裸の括弧pathをクリック可能なMarkdown linkとして受理しない" \
    "最初の実行例より前に有効な plugin root 前提"
}
