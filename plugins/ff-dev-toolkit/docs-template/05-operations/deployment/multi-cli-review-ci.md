# Multi-CLI Review CI

> **Parent**: [Multi-CLI Review Orchestration](./multi-cli-review-orchestration.md)

### CI/CD（GitHub Actions）での実行

[ff-dev-toolkit plugin root の固定契約](./multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite)を前提に、公開 mirror のレビュー済み commit を runner temp へ配置する。cache path や未固定の最新版は探索しない。

CLI の認証情報はこの例に含めない。公式手順に従って OIDC または必要最小権限の Secrets を設定し、fork 由来の `pull_request` では job を起動しない。未信頼コードを Secrets 付きで checkout する `pull_request_target` への置換は禁止する。同一repositoryのPRも、protected environmentで承認した信頼できる変更だけを対象にする。この例はGitHub-hosted runnerの送信先をモデルAPIだけへ制限しないため、未信頼コードを認証付きagentへ渡す用途には使わず、network allowlistと短命資格情報を備えた隔離runnerを別途用意する。

```yaml
# .github/workflows/multi-cli-review.yml
name: Multi-CLI Review
on:
  pull_request:
    branches: [develop, main]

permissions:
  contents: read

env:
  # 公開 mirror のレビュー済みcommit SHAへ必ず置換する。
  FF_DEV_TOOLKIT_REF: <REVIEWED_COMMIT_SHA>
  CLAUDE_CODE_VERSION: <PINNED_VERSION>
  CODEX_CLI_VERSION: <PINNED_VERSION>
  GROK_CLI_VERSION: <PINNED_VERSION>
  YQ_VERSION: <PINNED_VERSION>
  YQ_SHA256: <REVIEWED_SHA256>

jobs:
  review:
    # fork PRには認証用Secretsを渡さず、job自体も起動しない。
    if: github.event.pull_request.head.repo.full_name == github.repository
    # protected environment側でrequired reviewerを設定し、認証付き実行を人が承認する。
    environment: ai-review
    runs-on: ubuntu-latest
    steps:
      # GitHub Actions も可変tagではなくレビュー済みcommitへ固定する。
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
        with:
          persist-credentials: false
          fetch-depth: 0
      - name: Verify ff-dev-toolkit commit pin
        run: |
          if ! printf '%s\n' "$FF_DEV_TOOLKIT_REF" | grep -Eq '^[0-9a-f]{40}$'; then
            echo "FF_DEV_TOOLKIT_REF must be an exact 40-character commit SHA." >&2
            exit 2
          fi
      - name: Checkout pinned ff-dev-toolkit source
        uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
        with:
          repository: feel-flow/ff-dev-toolkit
          ref: ${{ env.FF_DEV_TOOLKIT_REF }}
          path: .ff-dev-toolkit-source
          persist-credentials: false
      - name: Fix ff-dev-toolkit root to runner temp
        run: |
          printf 'FF_DEV_TOOLKIT_ROOT=%s\n' "$RUNNER_TEMP/ff-dev-toolkit" >> "$GITHUB_ENV"
          printf 'FF_REVIEW_OUTPUT=%s\n' "$RUNNER_TEMP/ff-review-results" >> "$GITHUB_ENV"
      - name: Place pinned ff-dev-toolkit
        run: |
          checkout_head="$(git -C .ff-dev-toolkit-source rev-parse HEAD)" || exit 2
          if [ "$checkout_head" != "$FF_DEV_TOOLKIT_REF" ]; then
            echo "Checked out ff-dev-toolkit does not match FF_DEV_TOOLKIT_REF." >&2
            exit 2
          fi
          if [ -e "$FF_DEV_TOOLKIT_ROOT" ]; then
            echo "Runner temp target already exists: $FF_DEV_TOOLKIT_ROOT" >&2
            exit 2
          fi
          cp -R .ff-dev-toolkit-source/plugins/ff-dev-toolkit "$FF_DEV_TOOLKIT_ROOT"
      - name: Remove nested toolkit checkout
        # review対象workspaceへ別repositoryを残さず、consumer差分だけを走査させる。
        run: rm -rf -- .ff-dev-toolkit-source
      - name: Install CLI tools
        run: |
          exact_semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?(\+([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?$'
          for value in "$CLAUDE_CODE_VERSION" "$CODEX_CLI_VERSION" \
            "$GROK_CLI_VERSION" "$YQ_VERSION"; do
            if ! printf '%s\n' "$value" | grep -Eq "$exact_semver"; then
              echo "CLI and yq versions must be exact SemVer values: $value" >&2
              exit 2
            fi
          done
          if ! printf '%s\n' "$YQ_SHA256" | grep -Eq '^[0-9a-f]{64}$'; then
            echo "YQ_SHA256 must be an exact reviewed sha256." >&2
            exit 2
          fi
          curl -fsSLo "$RUNNER_TEMP/yq" \
            "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64"
          printf '%s  %s\n' "$YQ_SHA256" "$RUNNER_TEMP/yq" | sha256sum -c -
          chmod 700 "$RUNNER_TEMP/yq"
          case "$("$RUNNER_TEMP/yq" --version)" in
            *github.com/mikefarah/yq*'version v4.'*) ;;
            *) echo "Pinned yq is not Mike Farah yq v4." >&2; exit 2 ;;
          esac
          if [ "$(printf 'version: 2.0\n' | "$RUNNER_TEMP/yq" -r '.version')" != 2.0 ]; then
            echo "Pinned yq failed the config capability probe." >&2
            exit 2
          fi
          echo "$RUNNER_TEMP" >> "$GITHUB_PATH"
          npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"
          npm install -g "@openai/codex@${CODEX_CLI_VERSION}"
          npm install -g "@xai-official/grok@${GROK_CLI_VERSION}"
      - name: Verify pinned ff-dev-toolkit
        run: |
          if [ ! -d "${FF_DEV_TOOLKIT_ROOT}/scripts" ] \
            || [ -L "${FF_DEV_TOOLKIT_ROOT}/scripts" ]; then
            echo "Pinned ff-dev-toolkit scripts directory is invalid." >&2
            exit 2
          fi
          for resource in setup-multi-agent.sh multi-agent.sh multi-review.sh; do
            resource_path="${FF_DEV_TOOLKIT_ROOT}/scripts/${resource}"
            if [ ! -f "$resource_path" ] || [ -L "$resource_path" ] || [ ! -r "$resource_path" ] \
              || [ ! -s "$resource_path" ]; then
              echo "Pinned ff-dev-toolkit resource is invalid: ${resource_path}" >&2
              echo "Re-place the reviewed FF_DEV_TOOLKIT_REF before retrying." >&2
              exit 2
            fi
          done
      - name: Prepare trusted review output
        run: |
          if [ -e "$FF_REVIEW_OUTPUT" ] || [ -L "$FF_REVIEW_OUTPUT" ]; then
            echo "Trusted review output already exists: $FF_REVIEW_OUTPUT" >&2
            exit 2
          fi
          install -d -m 700 "$FF_REVIEW_OUTPUT"
      - name: Make reviewed workspace read-only
        # agentic CLIへ渡すPR checkoutは入力専用にし、toolkit・出力はrunner tempへ分離する。
        run: chmod -R a-w -- "$GITHUB_WORKSPACE"
      - name: Run Multi-CLI Review
        id: multi_cli_review
        # PR headのproject configへreview方針・timeout・出力先を委ねず、pin済み設定を使う。
        env:
          PR_BASE_REF: ${{ github.base_ref }}
        run: |
          env -u GITHUB_TOKEN -u GH_TOKEN \
            FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" \
              --config "${FF_DEV_TOOLKIT_ROOT}/scripts/agent-config.yaml" \
              --output-dir "$FF_REVIEW_OUTPUT" \
              --base "origin/${PR_BASE_REF}" \
              --strategy minimize_cost
      - name: Verify integrated review report
        run: |
          report="${FF_REVIEW_OUTPUT}/integrated-report.md"
          if [ ! -f "$report" ] || [ -L "$report" ] || [ ! -s "$report" ]; then
            echo "Multi-CLI review did not produce a non-empty regular integrated report." >&2
            exit 1
          fi
          if grep -F '<!-- CRITICAL_BLOCK -->' "$report" >/dev/null; then
            echo "Multi-CLI review reported blocking critical findings." >&2
            exit 1
          fi
      - name: Upload results
        # 失敗・timeout回の部分出力こそ原因調査に必要なので、赤いときも回収する。
        # verifyでreview自体がskipされた場合は二次的な「artifact無し」エラーを重ねない。
        if: ${{ always() && steps.multi_cli_review.conclusion != 'skipped' }}
        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4
        with:
          name: review-results
          path: ${{ runner.temp }}/ff-review-results/
          if-no-files-found: error
```
