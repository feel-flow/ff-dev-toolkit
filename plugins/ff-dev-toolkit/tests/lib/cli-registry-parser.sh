#!/usr/bin/env bash
#
# multi-agent.sh の CLI registry を実行せずに読み取る共有 helper。
# Bash 3.2 互換のため associative array は使わず、検証済み TSV を保持する。
# 呼び出し元は set -euo pipefail 下を想定する。

CLI_REGISTRY_DATA=""
CLI_REGISTRY_ERROR=""
ALL_CLIS=""

cli_registry_load() { # <multi-agent.sh>
  local source_file="$1" parsed first_line prefix
  CLI_REGISTRY_DATA=""
  CLI_REGISTRY_ERROR=""
  ALL_CLIS=""

  if [ ! -f "$source_file" ]; then
    CLI_REGISTRY_ERROR="対象ファイルが見つかりません: ${source_file}"
    return 1
  fi

  # shell source を eval/source しない。sentinel 間を完全な制限文法として解析し、
  # ALL_CLIS と単純 lookup の case arm だけを TSV データへ変換する。
  # 許可されない行は境界内のどこにあっても拒否し、ファイル全体を追加走査して
  # registry symbol の境界外再定義も拒否する。
  if ! parsed="$(LC_ALL=C awk '
    function add_error(message, line_number, source_line) {
      error_count++
      if (line_number > 0) {
        errors[error_count] = "line " line_number ": " message ": " source_line
      } else {
        errors[error_count] = message
      }
    }

    function is_safe_token(value) {
      return value ~ /^[a-z0-9]+(-[a-z0-9]+)*$/
    }

    function is_safe_token_list(value) {
      return value ~ /^[a-z0-9]+(-[a-z0-9]+)*( [a-z0-9]+(-[a-z0-9]+)*)*$/
    }

    # 行頭だけを見ると `if ...; then ALL_CLIS=...` や
    # `true; get_cli_command() { ...; }` が実行時だけ正本を上書きする。
    # 識別子境界を保ったまま行全体を検索し、複合 command 内の定義も拒否する。
    # 引用符や eval 内の同形も fail-closed で拒否する（registry symbol を文字列として
    # 定義形のまま置く用途はこの production script には無い）。
    #
    # 代入形（`NAME=` / `NAME+=` / `NAME[i]=`）だけを列挙すると、`=` を使わずに変数へ
    # 書き込む形 — `printf -v ALL_CLIS`、`read -r ALL_CLIS`、`(( ALL_CLIS = ... ))`、
    # `unset ALL_CLIS`、`declare -n ALL_CLIS` — が素通りする。列挙は必ず取りこぼす。
    # そこで判定を反転し、**裸の識別子として現れたら書き込みとみなす**。
    # 値を読むときは必ず `$ALL_CLIS` / `${ALL_CLIS}` になるので、境界外の正当な参照は
    # すべて `$` か `{` を伴う。裸で書けるのは書き込み側だけ、という shell の性質を使う。
    #
    # 制約: 境界外で `ALL_CLIS` を裸で書けるのは行全体コメントの中だけ（下の走査が
    # コメント行を除外する）。行末コメントで裸の名前に言及すると red になるので、
    # そこでは `$ALL_CLIS` と書くか言い換えること。
    function is_all_clis_write(source_line) {
      return source_line ~ /(^|[^A-Za-z0-9_${])ALL_CLIS([^A-Za-z0-9_]|$)/
    }

    # `get_cli_*` の定義が境界外に現れたら、名前を返す（無ければ空文字）。
    # required の名前だけを照合すると、`get_cli_region() { ... }` のような**新しい**
    # registry 関数を sentinel 後に足したときに見逃す。接頭辞で拾って allowlist で許す。
    function registry_function_defined(source_line,   matched, name) {
      if (match(source_line, /(^|[^A-Za-z0-9_])get_cli_[a-z0-9_]+[[:space:]]*\(\)/)) {
        matched = substr(source_line, RSTART, RLENGTH)
      } else if (match(source_line, /(^|[^A-Za-z0-9_])function[[:space:]]+get_cli_[a-z0-9_]+/)) {
        matched = substr(source_line, RSTART, RLENGTH)
      } else {
        return ""
      }

      if (!match(matched, /get_cli_[a-z0-9_]+/)) return ""
      name = substr(matched, RSTART, RLENGTH)
      return name
    }

    function validate_value(function_name, arm, value, line_number, source_line, expected) {
      if (arm == "*") {
        expected = (function_name == "get_cli_cost_tier" ? "unknown" : "")
        if (value != expected) {
          add_error(function_name " の default 値が想定外（期待: \"" expected "\"）", line_number, source_line)
        }
        return
      }

      if (function_name == "get_cli_adapter") {
        expected = "${SCRIPT_DIR}/adapters/" arm "-adapter.sh"
        if (value != expected) {
          add_error(function_name " の値が固定 adapter path 形式でない", line_number, source_line)
        }
        return
      }

      if (function_name == "get_cli_model_env_vars") {
        if (value !~ /^[A-Z][A-Z0-9_]*( [A-Z][A-Z0-9_]*)*$/) {
          add_error(function_name " の値が環境変数名リストでない", line_number, source_line)
        }
        return
      }

      if (function_name ~ /^get_cli_perspectives_/) {
        if (!is_safe_token_list(value)) {
          add_error(function_name " の値が安全 token list でない", line_number, source_line)
        }
        return
      }

      if (!is_safe_token(value)) {
        add_error(function_name " の値が安全 token でない", line_number, source_line)
      }
    }

    BEGIN {
      start_sentinel = "# ── All known CLI names ──"
      end_sentinel = "# ── CLI Registry End ──"

      required["get_cli_command"] = 1
      required["get_cli_adapter"] = 1
      required["get_cli_perspectives_review"] = 1
      required["get_cli_perspectives_explore"] = 1
      required["get_cli_perspectives_implement"] = 1
      required["get_cli_fallback"] = 1
      required["get_cli_cost_tier"] = 1
      required["get_cli_model_env_vars"] = 1

      # 境界外に置いてよい `get_cli_*`。get_cli_perspectives は $TASK_TYPE で分岐する
      # ディスパッチャで、固定値を返す case lookup の文法に収まらない。ここを増やす
      # ときは「実行時の入力で戻り値が変わるか」を基準にすること。
      allowed_outside["get_cli_perspectives"] = 1
    }

    {
      source[NR] = $0
      if ($0 == start_sentinel) {
        start_count++
        if (!start_line) start_line = NR
      }
      if ($0 == end_sentinel) {
        end_count++
        if (!end_line) end_line = NR
      }
    }

    END {
      if (start_count != 1 || end_count != 1) {
        add_error("multi-agent.sh のレジストリ境界が一意ではありません（開始=" (start_count + 0) "件 / 終了=" (end_count + 0) "件）", 0, "")
      } else if (start_line >= end_line) {
        add_error("multi-agent.sh のレジストリ境界が正順ではありません（開始行=" start_line " / 終了行=" end_line "）", 0, "")
      } else {
        state = "top"
        current_function = ""

        for (line_number = start_line + 1; line_number < end_line; line_number++) {
          line = source[line_number]

          if (line ~ /^[[:space:]]*($|#)/) continue

          if (state == "top") {
            if (line ~ /^ALL_CLIS="[^"]*"$/) {
              all_clis_count++
              all_clis = line
              sub(/^ALL_CLIS="/, "", all_clis)
              sub(/"$/, "", all_clis)

              if (!is_safe_token_list(all_clis)) {
                add_error("ALL_CLIS は安全 token の単一 ASCII space 区切りでなければなりません", line_number, line)
              } else {
                cli_count = split(all_clis, cli_parts, " ")
                for (cli_index = 1; cli_index <= cli_count; cli_index++) {
                  if (seen_cli[cli_parts[cli_index]]) {
                    add_error("ALL_CLIS に重複 token がある: " cli_parts[cli_index], line_number, line)
                  }
                  seen_cli[cli_parts[cli_index]] = 1
                }
              }
              continue
            }

            if (line ~ /^get_cli_[a-z0-9_]+\(\)[[:space:]]+\{$/) {
              current_function = line
              sub(/\(\).*/, "", current_function)
              if (!(current_function in required)) {
                add_error("許可されていない registry 関数", line_number, line)
              }
              function_count[current_function]++
              state = "case"
              continue
            }

            add_error("許可されていないトップレベル行", line_number, line)
            continue
          }

          if (state == "case") {
            if (line == "  case \"$1\" in") {
              state = "arms"
            } else {
              add_error("関数先頭は `case \"$1\" in` でなければなりません", line_number, line)
            }
            continue
          }

          if (state == "arms") {
            if (line == "  esac") {
              state = "close"
              continue
            }

            if (line !~ /^[[:space:]]+([a-z0-9]+(-[a-z0-9]+)*|\*)\)[[:space:]]+echo[[:space:]]+"[^"]*"[[:space:]]+;;([[:space:]]+#.*)?$/) {
              add_error("case arm は `<token>) echo \"固定値\" ;;` 形式でなければなりません", line_number, line)
              continue
            }

            arm = line
            sub(/^[[:space:]]+/, "", arm)
            sub(/\).*/, "", arm)

            value = line
            sub(/^[[:space:]]+[^)]*\)[[:space:]]+echo[[:space:]]+"/, "", value)
            sub(/"[[:space:]]+;;([[:space:]]+#.*)?$/, "", value)

            arm_key = current_function SUBSEP arm
            if (seen_arm[arm_key]) {
              add_error(current_function " に重複 arm がある: " arm, line_number, line)
            }
            seen_arm[arm_key] = 1

            if (arm == "*") {
              default_count[current_function]++
              saw_default[current_function] = 1
            } else if (saw_default[current_function]) {
              add_error(current_function " の default arm より後に通常 arm があります", line_number, line)
            }

            record_count++
            records[record_count] = current_function "\t" arm "\t" value
            validate_value(current_function, arm, value, line_number, line)
            continue
          }

          if (state == "close") {
            if (line == "}") {
              state = "top"
              current_function = ""
            } else {
              add_error("case の後は `}` だけで関数を閉じなければなりません", line_number, line)
            }
            continue
          }
        }

        if (state != "top") {
          add_error("終了 sentinel までに registry 関数が閉じていません", end_line, source[end_line])
        }

        if (all_clis_count != 1) {
          add_error("ALL_CLIS 定義は registry 内にちょうど 1 件必要です（実際=" (all_clis_count + 0) "件）", 0, "")
        }

        for (function_name in required) {
          if (function_count[function_name] != 1) {
            add_error(function_name " の定義はちょうど 1 件必要です（実際=" (function_count[function_name] + 0) "件）", 0, "")
          }
          if (default_count[function_name] != 1) {
            add_error(function_name " の default arm はちょうど 1 件必要です（実際=" (default_count[function_name] + 0) "件）", 0, "")
          }
        }

        # 境界内が正しくても、後続の代入・関数定義は shell 実行時に正本を上書きする。
        # ファイル全体を走査し、registry symbol の定義を境界内の一意なものに限定する。
        #
        # 走査の前に 2 つ正規化する:
        #  - 行全体コメントは除外する。実行されないので回避経路にならない一方、
        #    `# 正本は get_cli_command()` のような散文が誤検出されると、何も再定義して
        #    いないのに「再定義できません」と出て診断が嘘になる
        #  - 行継続（末尾 `\`）を論理行へ畳む。`get_cli_\` 改行 `command() {` は
        #    物理行単位の検査をすり抜けるが、shell には 1 つの定義として届く
        for (line_number = 1; line_number <= NR; line_number++) {
          if (line_number > start_line && line_number < end_line) continue
          if (source[line_number] ~ /^[[:space:]]*#/) continue

          line = source[line_number]
          logical_start = line_number
          while (line ~ /\\$/ && line_number < NR) {
            sub(/\\$/, "", line)
            line_number++
            line = line source[line_number]
          }

          if (is_all_clis_write(line)) {
            add_error("ALL_CLIS を registry 境界外で書き換えられません", logical_start, line)
          }

          defined_name = registry_function_defined(line)
          if (defined_name != "" && !(defined_name in allowed_outside)) {
            add_error(defined_name " を registry 境界外で定義できません", logical_start, line)
          }
        }
      }

      if (error_count > 0) {
        for (error_index = 1; error_index <= error_count; error_index++) print errors[error_index]
        exit 1
      }

      print "@all\t" all_clis
      for (record_index = 1; record_index <= record_count; record_index++) print records[record_index]
    }
  ' "$source_file" 2>&1)"; then
    CLI_REGISTRY_ERROR="$parsed"
    return 1
  fi

  first_line="${parsed%%$'\n'*}"
  prefix="@all"$'\t'
  # shellcheck disable=SC2034 # sourced helper: caller reads ALL_CLIS
  case "$first_line" in
    "$prefix"*) ALL_CLIS="${first_line#"$prefix"}" ;;
    *)
      # awk の警告は stderr に出るが 2>&1 で $parsed の先頭へ混ざる。行き止まりの
      # 「ALL_CLIS がありません」だけを出すと、実際の原因（awk 実装差・locale 警告）が
      # 見えないので、受け取った出力そのものを添える。
      CLI_REGISTRY_ERROR="内部エラー: parser 出力に ALL_CLIS がありません。実際の出力:
${parsed}"
      return 1
      ;;
  esac

  CLI_REGISTRY_DATA="$parsed"
  return 0
}

cli_registry_lookup() { # <lookup関数名> <CLI> — REPLY / CLI_REGISTRY_ERROR
  local function_name="$1" cli="$2" output
  REPLY=""
  CLI_REGISTRY_ERROR=""

  if ! output="$(printf '%s\n' "$CLI_REGISTRY_DATA" | LC_ALL=C awk -F '\t' \
    -v function_name="$function_name" -v cli="$cli" '
      $1 == function_name && $2 == cli {
        found++
        value = substr($0, length($1) + length($2) + 3)
      }
      $1 == function_name && $2 == "*" {
        default_found++
        default_value = substr($0, length($1) + length($2) + 3)
      }
      END {
        if (found == 1) {
          print value
          exit 0
        }
        if (found == 0 && default_found == 1) {
          print default_value
          exit 0
        }
        exit 1
      }
    ')"; then
    CLI_REGISTRY_ERROR="${function_name} に ${cli} の静的 case arm がありません"
    return 1
  fi

  REPLY="$output"
  return 0
}

cli_registry_arms() { # <lookup関数名> — REPLY（source 順の空白区切り）
  local function_name="$1" output
  REPLY=""
  CLI_REGISTRY_ERROR=""

  if ! output="$(printf '%s\n' "$CLI_REGISTRY_DATA" | LC_ALL=C awk -F '\t' \
    -v function_name="$function_name" '
      $1 == function_name && $2 != "*" {
        if (result != "") result = result " "
        result = result $2
      }
      END { print result }
    ')"; then
    # shellcheck disable=SC2034 # sourced helper: caller reads CLI_REGISTRY_ERROR
    CLI_REGISTRY_ERROR="${function_name} の arm 集合を取得できません"
    return 1
  fi

  REPLY="$output"
  return 0
}
