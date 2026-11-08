#!/usr/bin/env bash
# source 専用。全件ゲートの markdownlint suite（tests/markdownlint/verify.sh）と、
# knowledge-commit.sh の commit 前検査が、同じ設定ファイル・同じ実行ファイルで判定するための
# 置き場の定義（Issue `#2671`）。規則そのものはリポジトリ直下の .markdownlint.json だけが持ち、
# ここへ写さない。

# ff_markdownlint_locate <repo_root> — ff_mdl_config / ff_mdl_modules / ff_mdl_bin を設定する
ff_markdownlint_locate() {
  ff_mdl_config="$1/.markdownlint.json"
  ff_mdl_modules="$1/plugins/ff-dev-toolkit/mcp/node_modules"
  ff_mdl_bin="$ff_mdl_modules/.bin/markdownlint-cli2"
}

# ff_markdownlint_gate_present <repo_root> — 全件ゲートで markdownlint を回すリポジトリか
# （このプラグインのソースリポジトリ）。suite とルートの設定の両方を持つことで判定する。導入先は
# どちらも持たない。公開リポジトリは同期で suite を受け取るが設定を受け取らず、全件ゲートでも
# markdownlint を回さないので、どちらも commit 前検査の対象外になる。
ff_markdownlint_gate_present() {
  ff_markdownlint_locate "$1"
  [[ -f "$1/plugins/ff-dev-toolkit/tests/markdownlint/verify.sh" && -f "$ff_mdl_config" ]]
}

# ff_markdownlint_check_paths <repo_root> <リポジトリ相対パス>...
# 渡したパスのうち *.md だけを、全件ゲートと同じ設定・同じ実行ファイルで検査する。
#   0  違反なし（*.md が無い回と、全件ゲートで markdownlint を回さないリポジトリでは何も実行せず 0）
#   1  違反あり（markdownlint の `ファイル:行[:列] 規則` の行を stderr へ）
#   2  未検査（実行ファイルが無い・検査の結果として読めない。理由と復帰手段を stderr へ。
#      違反なしとも違反ありとも扱わない）
# パスは `:` を前置して渡す（markdownlint-cli2 は引数を glob として読むので、`[` などを含む
# 名前が 0 件一致のまま緑になりうる）。それでも検査した件数（`Linting: N file(s)`）を照合する。
# rc 1 は違反のほかに node がモジュールを読めない回（npm ci の途中で止まった・node が古い）にも
# 返るので、検査した件数が揃い、違反の件数（`Summary: N issue(s)`）が 1 以上のときだけ違反と読む。
ff_markdownlint_check_paths() {
  local repo="$1"; shift
  local -a targets=() args=()
  local p out rc=0 linted issues shown recover
  for p in "$@"; do
    case "$p" in *.md) targets+=("$p") ;; esac
  done
  [[ ${#targets[@]} -gt 0 ]] || return 0
  ff_markdownlint_gate_present "$repo" || return 0
  recover="markdownlint-cli2 が求める版の node を PATH に入れ、npm ci --prefix ${ff_mdl_modules%/node_modules} で入れ直してから再実行する"
  if [[ ! -x "$ff_mdl_bin" ]]; then
    echo "✗ markdownlint 未検査: 全件ゲートと同じ実行ファイル ${ff_mdl_bin} がありません — ${recover}" >&2
    return 2
  fi
  for p in "${targets[@]}"; do args+=(":$p"); done
  out="$(cd "$repo" && "$ff_mdl_bin" --config "$ff_mdl_config" "${args[@]}" 2>&1)" || rc=$?
  out="${out//$'\r'/}"
  linted="$(printf '%s\n' "$out" | sed -n 's/^Linting: \([0-9][0-9]*\) files\{0,1\}$/\1/p')"
  issues="$(printf '%s\n' "$out" | sed -n 's/^Summary: \([0-9][0-9]*\) issues\{0,1\} in .*/\1/p')"
  if [[ "$rc" -eq 0 && "$linted" == "${#targets[@]}" ]]; then
    return 0
  fi
  if [[ "$rc" -eq 1 && "$linted" == "${#targets[@]}" && "${issues:-0}" -gt 0 ]]; then
    shown="$(printf '%s\n' "$out" | grep -vE '^(markdownlint-cli2 v|Finding: |Linting: |Summary: )')" || shown=""
    echo "✗ markdownlint の違反（全件ゲートと同じ設定 ${ff_mdl_config}）:" >&2
    printf '%s\n' "${shown:-$out}" >&2
    return 1
  fi
  echo "✗ markdownlint 未検査: 検査の結果として読めません（rc=${rc}・渡した ${#targets[@]} 件のうち検査した件数 ${linted:-読めない}・違反 ${issues:-読めない} 件）— ${recover}。markdownlint-cli2 の出力:" >&2
  printf '%s\n' "$out" >&2
  return 2
}
