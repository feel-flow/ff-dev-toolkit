# モデル選択

multi-review の本線（`../SKILL.md`）から、モデルを明示指定するときだけ読む。コマンドの引数は本線の手順 2 と同じものを渡す。

**ラッパーはモデルを選ばない。** どのモデルを使うかは各 CLI 自身の設定に委譲する — `~/.codex/config.toml`、Claude Code のモデル設定、Copilot の `auto` など。ラッパー側に既定のモデル slug を持たせると、その値の SSOT がユーザーの CLI 設定と2重化して必ず古くなり、しかもフラグを無条件に渡す実装だとユーザー設定を黙って上書きする（実害の記録は ACE-70-2 にある）。

明示的に指定したい場合だけ環境変数を使う。**未設定ならフラグ自体が渡らない**ので、指定しない限り CLI 側の設定がそのまま効く。

| 環境変数 | 渡されるフラグ | 対象 |
|---|---|---|
| `MULTI_AGENT_CLAUDE_EFFORT` | `--effort` | Claude の effort を単発指定。空文字・不正値は拒否、未指定なら継承・実値未確認 |
| `MULTI_AGENT_MODEL_CLAUDE_CODE` | `--model` | Claude Code。`opus` / `sonnet` / `haiku` / `fable` は**最新版を指すエイリアス**なので、slug 直書きより腐りにくい |
| `MULTI_AGENT_CODEX_PROFILE` | `-p` | **Codex の推奨経路**。`~/.codex/<name>.config.toml` を base 設定に重ねる |
| `MULTI_AGENT_MODEL_CODEX_CLI` | `-m` | Codex のモデルを単発で指定。`MULTI_AGENT_CODEX_PROFILE` とは併用不可 |
| `MULTI_AGENT_CODEX_REASONING_EFFORT` | `-c model_reasoning_effort=<value>` | Codex の effort だけを単発指定。`none` / `minimal` / `low` / `medium` / `high` / `xhigh` / `max` / `ultra`。プロファイル併用時はこの値が明示上書きする |
| `MULTI_AGENT_MODEL_COPILOT_CLI` | `--model` | Copilot。`auto` で Copilot 側の自動選択 |
| `MULTI_AGENT_MODEL_GROK_CLI` | `-m` | Grok |
| `MULTI_AGENT_GROK_READONLY_PROFILE` | `--sandbox <name>`（read-only スロット = review / explore / implement `--inline-output` のみ。通常の implement の `workspace` には効かない） | Grok。`~/.grok/sandbox.toml` のカスタムプロファイル名。docker.sock が symlink の macOS で組み込み `read-only` が起動拒否されるときの差し替え。`workspace` / `devbox` / `strict` / `off` / `none` は拒否、実行後に `read_write_paths` が作業ツリー（祖先・配下含む）を含まないことを検証。ランタイムソケットの遮断は失う（実測。dispatch 前に通知） |

```bash
# Codex を専用プロファイルでレビューさせる（推奨）
#   事前に ~/.codex/review.config.toml へ model と model_reasoning_effort を書いておく
MULTI_AGENT_CODEX_PROFILE=review \
  FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --route <REVIEW_ROUTE の値>
```

Codex は `-m`（単発 slug）より **`--profile` が推奨**。プロファイルはモデルと `model_reasoning_effort` を1つのファイルで束ねられるため、「古いモデル + 新しい reasoning effort」という誰も意図していない組み合わせを避けられる。

ただしその利点が成立するのは `-p` 単独のときだけ。`-m` を併用すると **`-m` のモデルがプロファイルのモデルに勝ち、reasoning effort だけプロファイル由来**になる（codex 0.144.5 で実測）。まさに避けたかった組み合わせなので、**両方を設定した場合はアダプタが実行前に非 0 で落とす**。

プロファイルファイルを作らず effort だけ一時変更する場合は `MULTI_AGENT_CODEX_REASONING_EFFORT=high` のように指定する。プロファイルとの併用も許可され、その場合は `-c` の effort がプロファイル値を上書きする。アダプタは argv と `Reasoning effort: ... profile value is overridden` のログを出すため、どちらが効いたかを判別できる。不正値は CLI 起動前に拒否する。

> **プロファイル名は実行前に検証される。** codex 自身は存在しないプロファイル名を**エラーにせず、base config のまま完走する**（0.144.5 で実測）。そのままだと名前を打ち間違えたとき「専用プロファイルでレビューさせたつもり」が成立してしまい、成果物からもログからも判別できない。そこでアダプタは `-p` を渡す前に `${CODEX_HOME:-~/.codex}/<name>.config.toml` の存在を確認し、無ければ CLI を起動せずに落とす。**これは意図した fail-loud であってバグではない。**

各アダプタは起動時に、実際に渡すモデル引数を stderr のバナーへ出す（`Model args: ...`、渡さない場合は `(なし — CLI 自身の設定へ委譲)`）。委譲した以上「実際にどのモデルが使われたか」はラッパーには断定できないので、報告するのは**渡した引数だけ**で実使用モデルは名乗らない。それでも、env 名の打ち間違いや未 export は `(なし)` として即座に見えるので、設定したつもりで効いていない事故に気づける。

なお、ラッパーが具体的なモデル slug を持ち込んでいないことは `tests/no-hardcoded-model/verify.sh` が、環境変数が実際に CLI の argv へ届くことは `tests/adapter-model-args/verify.sh` が機械的に検査している。
