#!/usr/bin/env bash
# adapter-common.sh の構成ファイル: 成果物の書き出し・ホスト委譲・timeout reason・EXIT trap・プロンプトファイル。
#
# scripts/adapters/adapter-common.sh が source されたときに 1 回だけ source する
# （直接実行しない）。読み込む順・読めないときの停止は入口の
# ADAPTER_COMMON_PARTS が正本。本文は分割前の adapter-common.sh の連続した行そのままで、
# トップレベルの初期化（readonly・trap）も分割前と同じ順に走る。
# ここへ set / trap / source を足さない（本文に元からある trap は分割前のまま）。
# 末尾の _ac_part_loaded の行は読み込み完了の印。bash 3.2 互換。分割の判断は ADR-075。
# pipefail-inherited: 呼び出し元の adapter が set -euo pipefail の下で adapter-common.sh を source する
# Write review output with a standard header
# Usage: write_output "output.md" "Claude Code" "code-review" "review content..." [status]
# status: complete (default) | incomplete — recorded in the header so a consumer
# can tell a finished result from one salvaged off a failed run.
#
# rc は「所定のパスに完成した成果物が置けたか」だけを表す（0 = 置けた / 非 0 = 置けて
# いない）。旧実装は関数の最後の command が `echo` だったため、`cat > "$output_file"`
# が Permission denied / ENOSPC で失敗しても rc=0 を返し、しかも「✅ saved」と名乗って
# いた（実測: 書き込み不可の出力先で rc=0・ファイル不在・`✅ Review saved` の 3 つが
# 同時に出る）。呼び出し側は全員 `set -e` 下にいるので、rc へ載せれば失敗はその場で
# 止まる。
#
# 書き込みは同じディレクトリの一時ファイルへ行い、**完成を確かめてから** rename で
# 所定のパスへ移す。直接書くと、ENOSPC が本文の途中で起きた回に切り詰められた
# 成果物が所定のパスに残る — orchestrator の検査は `-f`（`No output file`）なので
# それを通過し、`✅ Done` → resume キャッシュ → 統合レポートへ INCOMPLETE の印
# なしで連結される。rename は同一ディレクトリ内なので原子的で、失敗した回は所定の
# パスに**何も置かない**（既存の成果物があればそれも壊さない）。
#
# 完成の確認はバイト数で行う。書く内容は変数に確定しているので、同じ変数から数えた
# 期待バイト数と一致すれば全量が届いている。`printf` の rc だけに頼らないのは、
# RLIMIT_FSIZE / ENOSPC の短絡書き込みが実装によっては「短い write の成功」として
# 返りうるため — 「rc は 0 だが本文が切れている」形をここで落とす。
write_output() {
  local output_file="$1"
  local cli_name="$2"
  local perspective_name="$3"
  local content="$4"
  local status="${5:-complete}"

  local task_type="${TASK_TYPE:-review}"
  # bash 3.2 compatible capitalization (no ${var^} operator)
  local task_label
  task_label="$(echo "$task_type" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"

  local dir
  dir="$(dirname "$output_file")"
  if ! mkdir -p "$dir"; then
    echo "ERROR: cannot create the output directory: ${dir}" >&2
    return 1
  fi

  # 宛先がディレクトリだと下の `mv` は一時ファイルを**その中へ**移して 0 を返す。
  # 所定のパスには通常ファイルが無いのに rc=0 +「saved」が出る形で、この関数が
  # 塞ごうとしている主症状そのものになる。publish 後の `-f` 検査（下）でも捕まるが、
  # 早期に名指しで落とすほうが読み手の手数が少ない。
  if [ -d "$output_file" ]; then
    echo "ERROR: the ${task_type} result cannot be written to ${output_file} — a directory already occupies that path." >&2
    echo "       Remove it or choose another output path; re-running as-is will fail identically." >&2
    return 1
  fi

  # 一時ファイルは成果物と同じディレクトリに置く（rename が同一ファイルシステム内で
  # 完結する条件）。名前を `.` 始まりにするのは、orchestrator 側の stale 成果物退避が
  # `<cli>/*.md` を走査するため — 中断で取り残された断片をその glob に拾わせない。
  #
  # 名前は mktemp があればそれで作る。pid 由来の固定名は予測可能で、先に置かれた
  # symlink を `>` が追跡して**指し先を truncate する**余地を残すため（atomic publish
  # の前提もそこで崩れる）。
  local base tmp
  base="$(basename "$output_file")"
  tmp="$(mktemp "${dir}/.${base}.partial.XXXXXX" 2>/dev/null)" || tmp=""
  if [ -z "$tmp" ]; then
    # mktemp が使えない環境（TMPDIR の破損・mktemp 自体の不在）でも成果物は書けな
    # ければならない — fail_cli_task の INCOMPLETE 成果物はまさにその状況を記録する
    # ためのもので、ここが mktemp に依存すると「一時ファイルを作れなかった」という
    # 失敗だけが手ぶらで終わる（その経路は multi-agent-timeout の tmpdir ケースが
    # 実走で押さえている）。パスは 1 プロセス 1 成果物に閉じるので pid で衝突しない。
    tmp="${dir}/.${base}.partial.$$"
    # 固定名へ落ちた回だけは、その名前が symlink / 非通常ファイルでないことを自分で
    # 確かめる。確かめずに `>` で書くと、先置きされた symlink の指し先を truncate する。
    if [ -L "$tmp" ] || { [ -e "$tmp" ] && [ ! -f "$tmp" ]; }; then
      echo "ERROR: refusing to stage the ${task_type} result through ${tmp}" >&2
      echo "       (mktemp is unavailable here, and that fixed-name temp path is a symlink or a non-regular file)." >&2
      echo "       Remove it and re-run; writing through it would truncate whatever it points at." >&2
      return 1
    fi
  fi

  local generated
  generated="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  # ヘッダー + 空行 + 本文 + 末尾改行。旧実装の heredoc と 1 バイトも変えないため、
  # 本文の末尾改行を落とすコマンド置換を挟まず、リテラルの複数行文字列で組む。
  local document="<!-- Multi-CLI ${task_label} Result -->
<!-- CLI: ${cli_name} -->
<!-- Perspective: ${perspective_name} -->
<!-- Task Type: ${task_type} -->
<!-- Status: ${status} -->
<!-- Generated: ${generated} -->

${content}"

  local write_rc=0
  # 書き込みは subshell の中でやり、その stdout を /dev/null へ倒す。上限・容量に
  # 当たって失敗した printf は、**書けなかった分をシェルの stdout バッファへ残したまま**
  # 返る回があり（bash 3.2 / RLIMIT_FSIZE で実測）、次に来るコマンド置換がそれを
  # 取り込んで「期待バイト数」の値そのものが本文の断片で汚れる。捨て先を固定して
  # 関数の外へも下の計測へも漏らさない（stderr はそのまま通す — シェル自身が言う
  # 失敗理由が唯一の一次情報になる）。
  ( printf '%s\n' "$document" > "$tmp" ) >/dev/null || write_rc=$?

  local expected actual
  expected="$(printf '%s\n' "$document" | wc -c | tr -d '[:space:]')"
  actual="$(wc -c < "$tmp" 2>/dev/null | tr -d '[:space:]')" || actual=""

  # 一時ファイルを作れなかった回（書き込み不可のディレクトリ・read-only mount）は
  # write_rc が非 0 で、actual は空になる。全量書けなかった回（ENOSPC・上限）は
  # バイト数が合わない。どちらも成果物は所定のパスへ出さず、断片も残さない。
  if [ "$write_rc" -ne 0 ] || [ -z "$actual" ] || [ "$actual" != "$expected" ]; then
    rm -f "$tmp" 2>/dev/null || true
    echo "ERROR: the ${task_type} result could not be written to ${output_file}" >&2
    echo "       (wrote ${actual:-0} of ${expected} bytes, status ${write_rc})." >&2
    echo "       The new result was NOT published to that path; whatever was already there is untouched." >&2
    echo "       Check free space, the directory's permissions and whether the mount is read-only: ${dir}" >&2
    return 1
  fi

  if ! mv "$tmp" "$output_file"; then
    rm -f "$tmp" 2>/dev/null || true
    echo "ERROR: the ${task_type} result was written but could not be moved into place: ${output_file}" >&2
    echo "       The new result was NOT published to that path; whatever was already there is untouched." >&2
    echo "       Check the directory's permissions and whether the mount is read-only: ${dir}" >&2
    return 1
  fi

  # publish 後の砦。`mv` の rc=0 は「所定のパスに通常ファイルが在る」を意味しない
  # （宛先がディレクトリなら一時ファイルはその**中**へ入る）。上の早期検査を素通りする
  # 形が生えても、成功と名乗る前にここで rc へ載せる。
  if [ ! -f "$output_file" ]; then
    if [ -d "$output_file" ]; then
      rm -f "${output_file}/${tmp##*/}" 2>/dev/null || true
    fi
    echo "ERROR: the ${task_type} result is not at ${output_file} after publishing it (no regular file at that path)." >&2
    echo "       Nothing usable was left there; check what occupies that path." >&2
    return 1
  fi

  if [[ "$status" == "complete" ]]; then
    echo "✅ ${task_label} saved: ${output_file}" >&2
  else
    echo "⚠️  Incomplete ${task_type} saved: ${output_file}" >&2
  fi
}

# 成果物を書けなかったときの終了。
#
# ここから fail_cli_task / fail_orchestrator_error へは行かない — どちらも失敗の記録を
# write_output で**書く**ので、書けないことが原因の失敗をそこへ流すと同じ失敗を踏み直す
# だけになる。成果物は残せないので、残せるのは stderr の 1 ブロックと終了コードだけ。
#
# 終了コードは ORCHESTRATOR_ERROR_EXIT_CODE（125）。CLI は完走しており、壊れているのは
# こちらが選んだ出力先なので、CLI 側の失敗（auth / billing / crash）と同じ番号へ混ぜない。
# orchestrator から見た分類の移動はこの 1 点:
#   旧: アダプタ rc=0 / 成果物なし → `No output file`（成功と名乗ったのに何も無い、の意）
#   新: アダプタ rc=125            → `Orchestrator-side failure`（出力先が書けない、の意）
# `No output file` は「rc=0 なのに成果物が無い」ための最後の砦として残す（write_output
# 経由ではもう到達しないが、別経路の退行を捕まえる位置は空けておく）。
fail_output_write() { # <perspective_name> <output_file>
  local perspective_name="$1" output_file="$2"
  echo "ERROR: ${CLI_NAME} finished its ${TASK_TYPE:-review} of ${perspective_name}, but the result could not be written to ${output_file} (see the error above)." >&2
  echo "       No artifact was left there, so this task is reported as failed — the CLI is not at fault, and re-running it without fixing the output path will fail identically." >&2
  exit "$ORCHESTRATOR_ERROR_EXIT_CODE"
}

# 委譲経路の「書けたが読み戻しが一致しない」。fail_output_write と分けるのは、壊れている
# 対象は同じ出力先でも**残っている状態が違う**ため（無い vs 在るが違う）。上書きしない
# ことを明言するのは、次の一手が「その成果物を見に行く」だから。
fail_output_readback() { # <perspective_name> <output_file> <response_file>
  local perspective_name="$1" output_file="$2" response_file="$3" state
  # 読み戻しが一致しない理由は 1 つではない。**いま何が在るか**を見てから名乗る —
  # 「在るが内容が違う」と決め打つと、publish 後に成果物が消えた / ディレクトリへ
  # 置き換わった / 読めなくなった回に嘘をつく（次の一手が「そのファイルを見る」に
  # なるのに、見るものが無い）。分類（この関数へ来たこと = publish 後の検証に失敗した）は
  # 同じで、違うのは残っている状態のほうである。
  if [ ! -e "$output_file" ]; then
    state="the artifact is GONE — something removed it after it was published"
  elif [ -d "$output_file" ]; then
    state="a DIRECTORY now occupies that path — something replaced the artifact after it was published"
  elif [ ! -f "$output_file" ]; then
    state="that path is no longer a regular file — something replaced the artifact after it was published"
  elif [ ! -r "$output_file" ]; then
    state="the artifact is there but NOT READABLE — its permissions changed after it was published"
  elif [ ! -s "$output_file" ]; then
    state="the artifact is there but EMPTY — something truncated it after it was published"
  else
    state="the artifact IS there — it is its content that disagrees (a partial write, a second writer, or a header-format mismatch)"
  fi
  echo "ERROR: ${CLI_NAME} finished its ${TASK_TYPE:-review} of ${perspective_name}, and ${output_file} was published, but reading it back does not give the response that was adopted." >&2
  echo "       ${state}." >&2
  echo "       This is not a write failure: the write itself succeeded, so look at that path and at whatever else writes there — not at free space or permissions at write time." >&2
  echo "       Neither the artifact nor the host's response was overwritten or removed by this failure, so whatever is left is the evidence. The response is at: ${response_file}" >&2
  exit "$ORCHESTRATOR_ERROR_EXIT_CODE"
}

# ── ホスト委譲 ──
#
# 背景: claude-code レーンは `claude` CLI を**別プロセス**として起動するため、その CLI が
# ログインしているアカウントの利用枠が尽きると、ホスト側のセッションが別アカウントで
# 動き続けていてもこのレーンだけ走らない。`claude auth` には呼び出し単位のアカウント
# 選択が無く（実測 / claude 2.1.263）、logout → login はグローバルな切り替えなので
# 「このレビューだけ別アカウント」ができない。CLI 側では解決できない。
#
# 形: CLI を起動せず、プロンプトと書き戻し先をホストへ返す。ホストは自分のセッション内
# サブエージェントでそれを実行し、結果を所定のパス（<output-dir>/<cli>/<perspective>.md）
# へ書く。**同じコマンドをもう一度実行する**と、その書き戻しが「このプロンプトへの応答」
# として受理され、正規ヘッダー付きの成果物へ正規化される。プラン構築・プロンプト生成・
# 統合レポート生成は従来どおりで、変わるのは実行主体だけ。
#
# 受理の条件は「**同じプロンプト**に対する応答であること」— handoff 時にプロンプト本文の
# digest を記録し、受理時に再計算して突き合わせる。diff の digest ではなくプロンプト全体を
# 見るのは、観点ファイル・base・description・固定 diff の変化を 1 つの条件で捕まえるため
# （個別に条件を足す形は、足し忘れた 1 つが「別の入力への応答を今回の結果として採用する」
# 静かな誤りになる）。一致しない応答は**捨てず**に名前を変えて残し、handoff をやり直す。
#
# 委譲はホスト自身のレーン 1 本だけ（claude-code / codex-cli / grok-cli。オーケストレータ側で
# 束縛し、アダプタは ADAPTER_SUPPORTS_DELEGATION で opt-in する）。他モデルのレーンを同じ経路へ
# 流すとモデル独立性が黙って失われる — 「別モデルのクロスレビュー」
# という本ツールの目的そのものを裏切る。

# プロンプト本文の digest。git は本ツールの前提（diff を取るのに要る）で、
# `git hash-object --stdin` はリポジトリ外でも動く（実測）。
# stderr は捨てない — この失敗は委譲そのものを中断させるので、git 自身が言う理由
# （GIT_DIR の破損・binary 不在・object db の権限）が唯一の手掛かりになる。
delegation_digest() { # stdin → digest（失敗時は理由を stderr へ出して rc=1）
  local out rc=0
  out="$(git hash-object --stdin 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    printf 'delegation_digest: git hash-object failed: %s\n' "$out" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

# `key=value` 形式の request ファイルから 1 キーを読む。値に `=` を含んでよいよう
# 最初の `=` だけで切る。存在しないキー・読めないファイルは rc=1。
delegation_request_field() { # <file> <key>
  local file="$1" key="$2" line
  [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "${key}="*) printf '%s\n' "${line#*=}"; return 0 ;;
    esac
  done < "$file"
  return 1
}

# ホストが write_output と同じヘッダーごと貼った場合に、ヘッダーを 1 つだけ剥がす。
# 剥がすのは**先頭が `<!-- Multi-CLI ... Result -->` のときだけ** — レビュー本文が
# 先頭で別のコメントを書いている場合まで削ると本文を改変することになる。
# 先頭に無いヘッダーは剥がさず、そのまま本文に残す（残ったことは呼び出し側の
# delegation_body_carries_result_header が拒否の根拠に使う）。
delegation_strip_result_header() { # <file> → 本文を stdout へ
  awk '
    NR == 1 && $0 ~ /^<!-- Multi-CLI .* Result -->$/ { stripping = 1; next }
    stripping && /^<!-- .* -->$/ { next }
    stripping && /^$/ { stripping = 0; next }
    { stripping = 0; print }
  ' "$1"
}

# 完成していないと**自分で名乗っている**応答を検出する。ファイル全体を見る。
#
# 先頭 1 段落だけを見る形にしてはいけない: この経路が受け取るのは外部（ホスト）が
# 書いたファイルで、ヘッダーが 1 行目にある保証が無い。実在の反例が本ツール自身の
# 生成物にある — mark_outputs_discarded は `> DISCARDED — ...` バナー + 空行を
# **前置**してから元のヘッダーを続けるので、1 段落で打ち切ると `Status: discarded`
# を一度も見ないまま通過し、レビュー本文（重大度行は原文のまま残る）が
# `Status: complete` として書き直される。この関数が塞ぐと宣言しているのは
# まさにその格上げ経路なので、走査範囲を本文全体にする。
delegation_response_declares_incomplete() { # <file>
  awk '
    /^<!-- Status: (incomplete|discarded) -->$/ { found = 1 }
    /^> DISCARDED —/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$1"
}

# ヘッダー剥がしの後にまだ `<!-- Multi-CLI ... Result -->` が残っている本文は受理
# しない。残っている = ヘッダーが 1 行目に無かった（前置きが付いている / 複数の結果を
# 連結した）ということで、そのまま write_output へ渡すと**入れ子のヘッダー**を持つ
# 成果物ができる。外側は complete を名乗り、内側は別の status を名乗りうる。
delegation_body_carries_result_header() { # <body>
  printf '%s\n' "$1" | awk '
    /^<!-- Multi-CLI .* Result -->$/ { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

# 受理しなかった応答の退避先。秒精度の時刻だけだと同一秒の 2 回目が 1 回目を mv で
# 上書きする（「捨てない」という契約が静かに破れる）ので pid と連番を足す。
delegation_setaside_path() { # <dir> <perspective> <kind> → 未使用のパス
  local dir="$1" persp="$2" kind="$3" stamp base n=0 candidate
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  base="${dir}/${persp}.response.${kind}.${stamp}.$$"
  candidate="${base}.md"
  while [ -e "$candidate" ]; do
    n=$((n + 1))
    candidate="${base}-${n}.md"
  done
  printf '%s\n' "$candidate"
}

# 受理しなかった応答を退避する。mv の rc は捨てない — 4 つある拒否分岐のうち 2 つで
# 握り潰していたため、退避に失敗した回は「kept at: <adoption slot>」と案内しつつ実体は
# 次の round trip の mv で上書きされて消えていた（「捨てない」契約と正面から矛盾する）。
delegation_set_aside_response() { # <dir> <perspective> <kind> <response-file> <lane> <理由>
  local dir="$1" persp="$2" kind="$3" response_file="$4" lane="$5" reason="$6" target
  target="$(delegation_setaside_path "$dir" "$persp" "$kind")"
  if ! mv "$response_file" "$target"; then
    echo "ERROR: the delegated response could not be set aside and is still in the adoption slot: ${response_file}" >&2
    echo "       Move it somewhere safe by hand before re-running — the next round trip overwrites that path." >&2
    return 1
  fi
  echo "⚠️  ${lane}/${persp}: ${reason}" >&2
  echo "    kept at: ${target}" >&2
  return 0
}

# write_output が実際に成果物を書けたかを、書いたファイル自身で確かめる。
#
# write_output 自身が書き込み失敗を rc へ載せるようになった今も、この検査は残す。
# 見ているものが違うからで、こちらは「**受理した本文が、ヘッダーを剥がすと同じ本文
# として読み戻せるか**」— 書き込みの成否ではなくヘッダー書式とその除去（
# delegation_strip_result_header）が互いの逆であることを、委譲経路のラウンドトリップで
# 確かめる。ここが崩れると、次回の受理判定が本文を別物として扱う。
# 委譲経路だけがこの検査を持つのは、ここだけが検査の直後に**ホストの唯一の写しを
# 消す**ため（書き込みが成立していない状態でそれをやると復旧手段が無くなる）。
#
# 検査は「先頭行がヘッダーか」では足りない。ヘッダーまで書けて本文の途中で失敗した
# 部分書き込みも、既存ファイルが残ったまま上書きに失敗した回も、先頭行だけなら通る。
# 受理した本文と**書けた本文が同一であること**まで確かめる（比較はコマンド置換同士
# なので、両辺とも末尾改行が同じ扱いになる）。
delegation_output_written() { # <output-file> <受理した本文>
  local file="$1" expected="$2" written
  [ -f "$file" ] && [ -s "$file" ] || return 1
  # 判定はフラグへ入れて END で 1 回だけ決める。`NR == 1 { exit 0 }` の形は使えない —
  # awk の exit は END を**実行してから**終わるので、END 側の exit が最終ステータスを
  # 上書きする（実測: 常に偽へ倒れて受理が全滅した）。
  awk 'NR == 1 { ok = ($0 ~ /^<!-- Multi-CLI .* Result -->$/); exit } END { exit ok ? 0 : 1 }' "$file" || return 1
  written="$(delegation_strip_result_header "$file")" || return 1
  [ "$written" = "$expected" ]
}

# ── ホスト委譲の分岐（委譲対応アダプタ共通。Issue `#2118`）──
#
# CLI を 1 つも起動しない経路。プロンプト構築とツール許可の決定までは起動経路と共通で、
# 実行だけをホストへ返す。呼び出し側は "🔍 Running" の進捗表示より**前**に呼ぶ —
# 起動していないのに起動したと名乗るログを残さないため。DELEGATE_DIR が空なら何もせず返る。
# 委譲した回はこの関数の中で exit する（受理 0 / 委譲待ち DELEGATION_PENDING_EXIT_CODE /
# 出力先の失敗は fail_output_*）。
run_host_delegation_or_continue() { # <lane-id> <cli-display-name> <perspective> <prompt> <allowed-tools>
  [[ -n "${DELEGATE_DIR:-}" ]] || return 0
  local delegate_rc=0
  delegate_task "$1" "$2" "$3" "$4" "$5" || delegate_rc=$?
  case "$delegate_rc" in
    0) exit 0 ;;
    "$DELEGATION_PENDING_EXIT_CODE") exit "$DELEGATION_PENDING_EXIT_CODE" ;;
    # 壊れているのは委譲の受け渡しではなく成果物の出力先。汎用の orchestrator エラーへ
    # 流すと、壊れている対象を名指しせず、書けない先へ INCOMPLETE 成果物を書きに行く。
    "$DELEGATION_OUTPUT_WRITE_EXIT_CODE")
      fail_output_write "$3" "$OUTPUT_FILE"
      ;;
    # 書けたが読み戻しが一致しない。122 と分けるのは「無い」と「在るが違う」で次の一手が変わるため。
    "$DELEGATION_OUTPUT_READBACK_EXIT_CODE")
      fail_output_readback "$3" "$OUTPUT_FILE" "${DELEGATE_DIR}/${3}.response.md"
      ;;
    *)
      fail_orchestrator_error "$3" \
        "cannot hand the ${TASK_TYPE:-review} to the host through ${DELEGATE_DIR} (see the error above)."
      ;;
  esac
}

# 委譲経路（--delegate-dir）は CLI を起動しないので、導入検査を飛ばしてよいかを引数から判定する。
# 導入検査を引数解析より前に置くアダプタ（codex / grok）用。
adapter_args_request_delegation() { # "$@"
  local a
  for a in "$@"; do
    [[ "$a" == "--delegate-dir" || "$a" == --delegate-dir=* ]] && return 0
  done
  return 1
}

delegate_task() { # <lane-id> <cli-display-name> <perspective> <prompt> <allowed-tools>
  # lane-id はオーケストレータが使う識別子（claude-code）、cli-display-name は成果物
  # ヘッダーへ載る表示名（Claude Code）。委譲経路の成果物が CLI 起動経路のそれと
  # 1 バイトも変わらないよう、write_output へ渡すのは後者にする。
  local lane="$1" cli_name="$2" persp="$3" prompt="$4" allowed="$5"
  local dir="$DELEGATE_DIR"
  local prompt_file="${dir}/${persp}.prompt.md"
  local request_file="${dir}/${persp}.request"
  local response_file="${dir}/${persp}.response.md"
  local digest recorded superseded body body_rc
  # 直前の handoff の状態は、応答処理より**前**に 1 回だけ読む。応答があってもなくても
  # 下の handoff 更新でこの値が要るため。
  local prev_digest prev_superseded consumed=0

  if ! mkdir -p "$dir"; then
    echo "ERROR: cannot create the delegation dir: ${dir}" >&2
    return 1
  fi
  digest="$(printf '%s\n' "$prompt" | delegation_digest)" || digest=""
  if [ -z "$digest" ]; then
    echo "ERROR: cannot digest the delegated prompt (see the error above)." >&2
    return 1
  fi

  prev_digest="$(delegation_request_field "$request_file" prompt-digest)" || prev_digest=""
  prev_superseded="$(delegation_request_field "$request_file" superseded)" || prev_superseded=""

  # ── ホストの応答があれば受理を試みる ──
  # どの分岐へ落ちても「未応答だった handoff を 1 つ消費した」ことは変わらないので、
  # 曖昧さの印はここで解消する（consumed）。解消しないと、拒否のたびに印が残り続けて
  # 正当な応答まで拒否し続ける。
  if [ -f "$response_file" ]; then
    consumed=1
    recorded="$prev_digest"
    superseded="$prev_superseded"
    if [ "$recorded" != "$digest" ]; then
      # 入力が変わっている（diff が動いた・観点が変わった等）。前回のプロンプトへの
      # 応答を今回の結果として採用しない。捨てもしない — ホストが払った実行の
      # 成果物なので、名前を変えて残し、パスを名指しする。
      delegation_set_aside_response "$dir" "$persp" stale "$response_file" "$lane" \
        "the delegated response was written for a different input; not adopting it." || return 1
    elif [ "$superseded" = "1" ]; then
      # digest は一致しているが、**その応答がどちらの handoff に対するものかを決められない**。
      # 前の handoff が未応答のまま入力が変わって新しい handoff を出した回があると、
      # 遅れて届いた旧入力への応答が新しい digest と突き合わされて通ってしまう（digest は
      # 「今のプロンプト」と「最後に出した handoff」しか比べていない）。曖昧さを検出した
      # 時点で 1 度だけ拒否し、handoff を出し直して対応を 1 対 1 へ戻す。
      delegation_set_aside_response "$dir" "$persp" ambiguous "$response_file" "$lane" \
        "the input changed while an earlier handoff was still outstanding, so this response cannot be attributed to one prompt; not adopting it." || return 1
    elif delegation_response_declares_incomplete "$response_file"; then
      delegation_set_aside_response "$dir" "$persp" rejected "$response_file" "$lane" \
        "the delegated response declares itself incomplete/discarded; not adopting it." || return 1
    else
      body_rc=0
      body="$(delegation_strip_result_header "$response_file")" || body_rc=$?
      if [ "$body_rc" -ne 0 ]; then
        # 「読めなかった」を「空だった」と報告しない（critical_findings_present が
        # 同じ種類の失敗を判定不能として分けているのと同じ理由）。ホストへ「結果が
        # 空だった」と伝えると、ディスク上に無事にある成果物を作り直しに行く。
        delegation_set_aside_response "$dir" "$persp" unreadable "$response_file" "$lane" \
          "the delegated response could not be read (its content is intact on disk; this is a read failure, not an empty result); not adopting it." || return 1
      elif [ -z "$body" ]; then
        delegation_set_aside_response "$dir" "$persp" rejected "$response_file" "$lane" \
          "the delegated response is empty; not adopting it." || return 1
      elif delegation_body_carries_result_header "$body"; then
        delegation_set_aside_response "$dir" "$persp" rejected "$response_file" "$lane" \
          "the delegated response still carries a result header after the leading one was stripped (a preamble before the header, or several results concatenated); not adopting it." || return 1
      elif [ "${TASK_TYPE:-review}" = "review" ] && ! review_body_present "$body" "${lane}/${persp}"; then
        # アダプタが CLI の出力へ掛けているのと**同じ**受理ゲート。委譲経路だけ
        # 緩めると、前置きだけの応答が「レビュー完了」として統合レポートへ載る。
        delegation_set_aside_response "$dir" "$persp" rejected "$response_file" "$lane" \
          "the delegated response $(review_body_refusal_clause) — refusing it as a review result." || return 1
      else
        # 書き込みの成否は write_output の rc が答える（ENOSPC / read-only / 権限変更）。
        # `set -e` 下なので受け止めないと素の 1 で落ち、下の案内（ホストの応答がどこに
        # 残っているか）が出ないまま終わる。
        #
        # 返す番号は専用のもの。素の 1 だと呼び出し側が「ホストへ渡せなかった」側の
        # 失敗として扱い、壊れている対象（出力先）を名指ししないうえ、その記録をまた
        # write_output で書きに行く。
        if ! write_output "$OUTPUT_FILE" "$cli_name" "$persp" "$body"; then
          echo "ERROR: ${lane}/${persp}: the adopted result could not be written to ${OUTPUT_FILE} (see the error above)." >&2
          echo "       The host's response was NOT removed and is still at: ${response_file}" >&2
          echo "       Fix the output path (space, permissions, mount) and re-run the same command." >&2
          return "$DELEGATION_OUTPUT_WRITE_EXIT_CODE"
        fi
        # ヘッダーを剥がすと受理した本文へ戻ることまで、書いたファイル自身で確かめて
        # から応答を消す（delegation_output_written のヘッダー参照）。
        if ! delegation_output_written "$OUTPUT_FILE" "$body"; then
          # 素の 1 を返さない（汎用の orchestrator 失敗へ落ちると、内容が違うと分かった
          # ばかりの成果物を INCOMPLETE で上書きして証拠を消す）。呼び出し側は専用の
          # 分類（fail_output_readback）へ分岐する。応答ファイルのパスは呼び出し側が
          # 同じ規則（<delegate-dir>/<観点>.response.md）で導けるので、値は渡さない
          # （渡すと同じ事実の出所が 2 つになり、片方だけが腐る）。
          return "$DELEGATION_OUTPUT_READBACK_EXIT_CODE"
        fi
        # 受理した応答は消費する。残すと、次回同じ digest のまま再実行したときに
        # 「ホストが今回書いたもの」と区別できない滞留物になる。
        rm -f "$response_file" "$request_file" "$prompt_file" 2>/dev/null || true
        echo "🤝 Adopted the host-executed ${TASK_TYPE:-review} for ${lane}/${persp}." >&2
        return 0
      fi
    fi
  fi

  # ── handoff を出す（実行はしない） ──
  # 直前の handoff が未応答のまま入力が変わっていたら、その事実を request へ残す。
  # 次に届く応答がどちらの handoff に対するものか決められない、という印で、上の受理側が
  # これを見て 1 回だけ拒否する。
  #
  # 印は**応答を 1 つ消費するまで持ち越す**。「入力が変わったか」だけで立て直すと、
  # 応答が届かないまま同じ入力で再実行した回に prev_digest == digest となって 0 へ戻り、
  # そのあと届いた旧入力への応答が受理される（実測経路: A → B で 1 が立つ → 未応答のまま
  # B で再実行して 0 へ戻る → A の応答が B の結果として通る）。
  superseded=0
  if [ "$consumed" -eq 1 ]; then
    # 応答を 1 つ受け取った（受理・退避のいずれでも）。未応答の handoff は清算された。
    superseded=0
  elif [ -n "$prev_digest" ] && [ "$prev_digest" != "$digest" ]; then
    superseded=1
  elif [ "$prev_superseded" = "1" ]; then
    superseded=1
  fi
  if ! printf '%s\n' "$prompt" > "$prompt_file"; then
    echo "ERROR: cannot write the delegated prompt: ${prompt_file}" >&2
    return 1
  fi
  if ! {
    printf 'cli=%s\n' "$lane"
    printf 'cli-name=%s\n' "$cli_name"
    printf 'perspective=%s\n' "$persp"
    printf 'task-type=%s\n' "${TASK_TYPE:-review}"
    printf 'timeout=%s\n' "${TIMEOUT:-}"
    printf 'allowed-tools=%s\n' "$allowed"
    printf 'prompt-file=%s\n' "$prompt_file"
    printf 'output-file=%s\n' "$OUTPUT_FILE"
    printf 'prompt-digest=%s\n' "$digest"
    printf 'superseded=%s\n' "$superseded"
  } > "$request_file"; then
    echo "ERROR: cannot write the delegation request: ${request_file}" >&2
    return 1
  fi
  echo "🤝 Delegated to the host (no CLI started): ${lane}/${persp}" >&2
  echo "   prompt: ${prompt_file}" >&2
  echo "   write the result to: ${OUTPUT_FILE}" >&2
  if [ "$superseded" = "1" ]; then
    echo "   note: the input changed while the previous handoff was outstanding — a response to that" >&2
    echo "         older prompt will be refused once, so run THIS prompt file." >&2
  fi
  return "$DELEGATION_PENDING_EXIT_CODE"
}

# ── Timeout Wrapper ──

# Exit status meaning "the wall-clock limit fired", matching timeout(1)'s 124.
readonly TIMEOUT_EXIT_CODE=124
# 128+SIGKILL: the command was SIGKILLed without our deadline having fired.
readonly SIGKILL_EXIT_CODE=137
# This wrapper itself could not run the command (temp file unavailable, etc).
# Distinct from any status the command could return, so an orchestrator fault is
# never filed against the CLI.
readonly ORCHESTRATOR_ERROR_EXIT_CODE=125
# ホストへ委譲したタスクが「まだ結果を受け取っていない」ことを表す終了コード
# 124 / 125 / 137 と同じく、CLI 自身が返しうる値と衝突しない位置に
# 置く必要がある — 失敗として集計されると、走らせていないタスクにクラッシュの調査
# 案内が付く。委譲経路では CLI プロセスを 1 つも起動しないので、この値が CLI 由来で
# 返ることは無い。
readonly DELEGATION_PENDING_EXIT_CODE=123
# 委譲経路で「ホストの応答は受理できたが、成果物を所定のパスへ書けなかった」ことを
# 表す戻り値。素の 1 で返すと呼び出し側は fail_orchestrator_error（→ fail_cli_task →
# write_output）へ落ちる: 書けないことが原因の失敗を**同じ書き込みで記録しに行く**うえ、
# 壊れている対象（出力先）ではなく「ホストへ渡せなかった」という誤った理由が成果物へ
# 残る。番号を分けて fail_output_write へ分岐させる。124 / 125 / 137 / 123 と同じく
# CLI 自身が返しうる値とは衝突しない位置に置く（委譲経路では CLI を 1 つも起動しない）。
readonly DELEGATION_OUTPUT_WRITE_EXIT_CODE=122
# 委譲経路で「成果物は所定のパスへ書けたが、読み戻した内容が受理した応答と一致しない」
# ことを表す戻り値。書き込み失敗（122）とは**調査の向きが逆**で、122 は「そこに何も残って
# いない」（空き容量・権限・マウントを見る）、こちらは「在るが中身が違う」（別の書き手・
# 部分書き込み・ヘッダー書式の食い違いを見る）。素の 1 で返すと汎用の orchestrator 失敗へ
# 落ち、fail_cli_task 経由で write_output を踏み直して**内容が違うと分かったばかりの成果物を
# INCOMPLETE で上書きする** — 食い違いの証拠をその場で消す。122 の文言（「そこに成果物は
# 残らなかった」）へ寄せることもしない: 事実と食い違ううえ、次の一手が変わる。
# 124 / 125 / 137 / 123 / 122 と同じく CLI 自身が返しうる値とは衝突しない位置に置く。
readonly DELEGATION_OUTPUT_READBACK_EXIT_CODE=121
# Seconds between the deadline's SIGTERM and the SIGKILL that follows it.
# Overridable so the regression suite can exercise the escalation quickly.
TIMEOUT_KILL_GRACE="${FF_TIMEOUT_KILL_GRACE:-10}"
readonly TIMEOUT_KILL_GRACE

# ── Out-of-band Failure Reason ──
# An exit status is a single channel, and 124/125 are only *conventionally* free:
# a CLI that exits 124 or 125 on its own would be filed as "the deadline fired" or
# "the orchestrator broke" and handed the matching wrong remedy. run_with_timeout
# knows which it was (it holds the marker), so it records the reason here and
# callers read it instead of inferring from the number.
#
# Why a file and not a variable: run_with_timeout runs inside `result=$(...)`, and
# anything it assigns dies with that subshell. `$$` stays the invoking shell's pid
# in a subshell, so both sides derive the same path with no argument to thread
# through — and separate adapter processes get separate files.
timeout_reason_file() {
  # Test seam (Issue `#266`): pin the marker path so write-failure / residue tests
  # do not depend on TMPDIR layout. Production callers leave this unset.
  if [[ -n "${FF_TIMEOUT_REASON_FILE:-}" ]]; then
    printf '%s\n' "$FF_TIMEOUT_REASON_FILE"
    return 0
  fi
  printf '%s\n' "${TMPDIR:-/tmp}/ff-run-with-timeout-reason.$$"
}

# ── Reason-File Exclusive Write ──
#
# 理由ファイルの名前は「コマンド置換のサブシェルを跨いで両側が同じパスを導ける」ことが
# 要件なので、引数を通さずに導ける ${TMPDIR:-/tmp} と自分の pid から作るしかない = 名前は
# 推測できる。TMPDIR を設定していないホストでは共有 sticky /tmp に落ちるため、他ユーザーが
# 先に実体を置ける。素の `>` は先に在るシンボリックリンクを追って**リンク先を truncate**
# する（無関係のファイルが空になる）。
#
# 方針は「既存の実体には一切書かない」。掴んでよいのは**自分が同じ実行の中で作った通常
# ファイル**だけで、それも一度消してから作り直す。判定は次の順で、1 つでも外れたら書かずに
# rc1 を返す（呼び出し側は従来どおり「記録できなかった」警告へ落ちる）:
#
#   1. シンボリックリンク（リンク先が何であれ）→ 掴まない。**排他生成より前**に見る。
#      bash の noclobber は stat した先が通常ファイルのときだけ O_EXCL を付けるので、
#      リンク先が /dev/null なら警告ゼロで成功し（理由がデバイスへ消える）、FIFO なら
#      open がブロックして返らない（同居ユーザーがレビュー実行をハングさせられる）。
#      「noclobber がリンクを弾く」は成り立たない。
#   2. 通常ファイル以外の実体（ディレクトリ / FIFO / デバイス等）→ 掴まない。
#   3. 他人所有、またはハードリンク数が 1 でない通常ファイル → 掴まない。リンク数 1 を
#      要求するのは、victim へのハードリンクを先に置かれると `-L` は false・`-f` は true
#      で、そのまま書けば victim を上書きするため。リンク数が取れないホストでも掴まない。
#   4. 残った「自分所有・リンク数 1 の通常ファイル」= 同一実行内の再記録（run_with_timeout
#      が起動時に書いた command を、アダプタが sandbox-refused などで上書きする経路）。
#      ここを拒むと理由が呼び出し側へ届かなくなるので、`rm -f` してから作り直す。
#
# 最後の生成と書き込みは同じサブシェルの `set -C` 下で 1 操作にする（下見と書き込みを
# 分けると、その間にリンクへ差し替えられる TOCTOU が残る）。
#
# 既知の限界: 4 の `rm -f` と生成の間のマイクロ秒の窓でシンボリックリンク → FIFO を
# 差し込まれると、noclobber がリンクを追って open でブロックしうる。窓を完全に閉じるには
# O_NOFOLLOW|O_EXCL を直に呼ぶ必要があり、シェルからは届かないので対策は入れていない。
#
# orchestrator（multi-agent.sh）も同じ形の理由ファイルを持つので、この関数を共有する
# — 2 本目の実装を書き写すと、片方だけ直った状態へ静かにずれる。
_ff_reason_link_count() { # $1: パス / stdout: ハードリンク数（取れなければ rc1）
  local n
  # GNU stat は -c %h、BSD（macOS）stat は -f %l。「片方は必ずエラーになる」は成り立たない:
  # GNU の -f は --file-system であって書式指定ではないので、-f %l は %l を実在しない
  # FILE オペランドとして扱いながら、$1 のファイルシステム情報を stdout へ出す。旧形は
  # `$(stat -f … || stat -c …)` とコマンドを繋いでいたため両者の出力が混ざって非数値になり、
  # Linux では常にリンク数が取れなくなった（Issue `#1806` — 上書きが必ず拒否され、失敗理由が
  # run_with_timeout の初期値のまま固定された）。
  #
  # 効いているのは順序より先に「何を `||` で繋ぐか」である。繋ぐ対象をコマンドではなく
  # 代入そのものにすると、失敗した側の stdout は次の代入に上書きされて決して残らない
  # （両方失敗すれば return 1）。この形なら順序を入れ替えても値は壊れない（実測）。
  # そのうえで GNU 形を先に置くのは、GNU の -f が rc=0 で返る場合への備え — 全オペランドが
  # 実在すると --file-system は成功終了するので（ACE-1047-1）、BSD 形が先だと `||` 自体が
  # 発火せずファイルシステム統計がそのまま n に残る。書式に見える引数と同名のファイルが
  # cwd に在る回がこれに当たる。
  # BSD stat に -c は無く、未知オプションは rc≠0 かつ stdout 空で返るので、GNU 形を先に
  # 試しても BSD 側は汚れない（実測済み）。
  n="$(stat -c %h "$1" 2>/dev/null)" || n="$(stat -f %l "$1" 2>/dev/null)" || return 1
  case "$n" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$n"
}

# 既存の実体を掴んではいけない理由を 1 行で返す（掴んでよければ rc1・出力なし）。
# write_reason_file の下見と、fail_cli_task の「この回の記録は拒否されたか」の再判定が
# 同じ条件を読む — 2 か所に書き写すと、片方だけ締めた状態へ静かにずれる（Issue `#1816`）。
_ff_reason_refusal() { # $1: パス / stdout: 拒否理由（rc0 = 拒否する, rc1 = 掴んでよい）
  local f="$1" links
  if [[ -L "$f" ]]; then
    printf '%s' "a symlink is already there, and writing would act on its target instead."
    return 0
  fi
  [[ -e "$f" ]] || return 1
  if [[ ! -f "$f" ]]; then
    printf '%s' "something that is not a regular file is already there."
    return 0
  fi
  if [[ ! -O "$f" ]]; then
    printf '%s' "the file there is owned by someone else."
    return 0
  fi
  # リンク数が取れないことと「リンクが複数ある」ことは別の原因なので書き分ける。取れない
  # 原因はたいてい道具の側（stat が PATH に無い・壊れている）で、ファイルのリンク数を
  # 断定すると利用者は自分のファイルを疑い、次の一手（stat の確認）へ辿り着けない。
  if ! links="$(_ff_reason_link_count "$f")"; then
    printf '%s' "could not determine how many hard links the file there has (is a working \`stat\` on PATH?), so writing could overwrite another name for it."
    return 0
  fi
  if [[ "$links" != "1" ]]; then
    printf '%s' "the file there has ${links} hard links, so writing could overwrite another name for it."
    return 0
  fi
  return 1
}

write_reason_file() { # $1: パス / $2: 書く内容 -- rc0 = 書けた, rc1 = 書かなかった
  local f="$1" content="$2" refusal
  if refusal="$(_ff_reason_refusal "$f")"; then
    echo "WARNING: refusing to write the failure reason at ${f}: ${refusal}" >&2
    if [[ -L "$f" ]]; then
      echo "         Remove it by hand if it is yours; otherwise point TMPDIR at a directory only you can write." >&2
    fi
    return 1
  fi
  if [[ -e "$f" ]]; then
    if ! rm -f "$f" 2>/dev/null; then
      echo "WARNING: refusing to write the failure reason at ${f}: the stale file from this run could not be removed." >&2
      return 1
    fi
  fi
  # 生成と書き込みを 1 操作にする。`rm` と生成の間に差し込まれた回はここで失敗する。
  # サブシェルに閉じ、呼び出し側の noclobber 設定を変えない。
  if ! ( set -C; printf '%s' "$content" > "$f" ) 2>/dev/null; then
    echo "WARNING: refusing to write the failure reason at ${f}: it could not be created exclusively." >&2
    return 1
  fi
  return 0
}

# rc の契約: 本関数は常に 0 を返す（記録できなかった回も含む）。呼び出し側に
# 「記録できたか」を判定させないための既定で、記録に失敗しても残るのは run_with_timeout が
# 起動時に書いた command であり、分類は exit status ベースの文言へ縮退する。
# したがって `record_timeout_reason X || fallback` は書かないこと — その `||` は発火しない。
#
# run_with_timeout 自身が書くのは timeout | orchestrator-error | command の 3 値。
# アダプタが上書きで書く値（sandbox-refused | empty-output | missing-review-body）と、
# fail_cli_task が missing-review-body を種別で細分した値（missing-review-body-prose |
# review-body-unparsed）も
# ここを通る。許可値の検証はこの入口に一箇所で集約する — 文字列は疑似 Union であり、
# 任意文字列を受けると typo した理由が describe_cli_failure / fail_cli_task の
# case をすべて素通りして既定文言（「status 1 で落ちた」）へ黙って化ける。
# 理由コードの許可値。記録の入口（record_timeout_reason）と、自分が書いたとは限らない
# 実体の中身を成果物へ写すかの判定（fail_cli_task の注記）が同じ集合を読む。
_ff_reason_is_known() { # $1: 値 -- rc0 = 許可値
  case "$1" in
    timeout|orchestrator-error|command|sandbox-refused|empty-output|missing-review-body|missing-review-body-prose|review-body-unparsed) return 0 ;;
  esac
  return 1
}

record_timeout_reason() {
  local reason="$1" f
  if ! _ff_reason_is_known "$reason"; then
    # 呼び出し側（アダプタ）のバグ。記録せず名指しして続行する。このとき残るのは
    # 「記録なし」ではなく、run_with_timeout が起動時に記録した command（CLI 自身
    # の終了）— typo した理由よりは正確な既定で、分類は exit status ベースの文言に
    # なる。
    echo "WARNING: record_timeout_reason called with unknown reason '${reason}' (adapter bug); not recording it. Failure classification falls back to the exit status." >&2
    return 0
  fi
  f="$(timeout_reason_file)"
  # 書けなくても呼び出し側の失敗処理は続ける（従来どおり）。ただし黙ると
  # empty-output が status 1 へ化けたり stale な timeout 案内の種になるので、
  # 失敗時は stderr へ 1 行だけ警告する（Issue `#266`）。
  # 掴んではいけない実体（リンク・他人所有・ハードリンク）は write_reason_file が
  # 弾く。弾いた回は書かずに同じ警告へ落ちる — 他人のファイルへ書くより、理由を
  # 運べない方が軽い。
  if ! write_reason_file "$f" "$reason"; then
    echo "WARNING: could not record timeout reason '${reason}' at ${f}; failure classification may fall back to the exit status only." >&2
    # rc では運べない契約（上記）なので、記録の失敗は fail_cli_task へグローバルで運ぶ。
    # 同じシェルで呼ぶアダプタ本文の記録（empty-output 等）はこれで届く。
    # run_with_timeout 内の記録は `$(...)` のサブシェルで失われるため、fail_cli_task は
    # 実体の再判定（reason_record_may_be_stale）も併せて見る（Issue `#1816`）
    _FF_REASON_RECORD_FAILED=1
  fi
}

# この回の失敗理由の記録が拒否された（= 読み戻す値が古い段階の値のまま残っている）
# 可能性があれば rc0。条件は 2 つ:
#   1. 同じシェルの record_timeout_reason が書けなかった（_FF_REASON_RECORD_FAILED）
#   2. 理由ファイルの実体が今も上書きを拒まれる形をしている（_ff_reason_refusal）—
#      run_with_timeout がサブシェルで timeout を記録しようとして拒まれた回は 1 が
#      届かないが、拒否の原因（stat が無い・ハードリンク・他人所有）は実体側に残る
# 正常な回は run_with_timeout 自身が作った「自分所有・リンク数 1」のファイルなので、
# どちらも成り立たず注記は付かない（狼少年にしない）。
_FF_REASON_RECORD_FAILED=""
reason_record_may_be_stale() {
  [[ -n "${_FF_REASON_RECORD_FAILED}" ]] && return 0
  _ff_reason_refusal "$(timeout_reason_file)" >/dev/null
}

# Echoes the recorded reason, or "" when it could not be recorded (a broken TMPDIR
# takes the file with it). An empty reason means "fall back to reading the status".
read_timeout_reason() {
  local f
  f="$(timeout_reason_file)"
  # 書く側がリンクを掴まない以上、リンクが在る回の中身は自分が書いたものではない。
  # 読めば他人の内容を「今回の理由」として名乗ることになるので読まない（警告は
  # 書く側が既に出している）。
  if [[ -L "$f" ]]; then
    return 0
  fi
  [[ -f "$f" ]] || return 0
  cat "$f" 2>/dev/null || true
}

# 理由ファイルの後始末。共有 sticky /tmp では他人が置いた実体を消せない（rm が失敗する）。
# 黙って通すと「掃除したつもり」のまま stale な実体が残り、次に同じパスを引いた実行が
# 記録を拒む理由になるので、失敗は 1 行残す。prepare_reason_file と同じく orchestrator
# （multi-agent.sh）とも共有する — 2 経路の一時ファイルは同じ形なので、後始末も同じ形にする。
# 同じパスの警告は 1 プロセス 1 回だけにする。後始末は 1 実行の中で何度も走る
# （orchestrator の current_review_series_id は呼ばれるたびに掃除する）ので、毎回
# 出すとレポートの CLI stderr 節が同じ 2 行で埋まる。
_FF_REASON_RM_WARNED=""
clear_reason_file() { # $1: パス（空なら何もしない）
  local f="$1" seen
  [[ -n "$f" ]] || return 0
  if ! rm -f "$f" 2>/dev/null; then
    seen=$'\n'"${_FF_REASON_RM_WARNED}"$'\n'
    if [[ "$seen" != *$'\n'"$f"$'\n'* ]]; then
      echo "WARNING: could not remove the failure reason marker: ${f}" >&2
      echo "         Remove it by hand, or the next run there refuses to record its reason." >&2
      _FF_REASON_RM_WARNED="${_FF_REASON_RM_WARNED}${_FF_REASON_RM_WARNED:+$'\n'}${f}"
    fi
  fi
  return 0
}

clear_timeout_reason() {
  clear_reason_file "$(timeout_reason_file)"
}

# 成功パスでは fail_cli_task が呼ばれないため、run_with_timeout が書いた
# "command" マーカーが ${TMPDIR}/ff-run-with-timeout-reason.$$ に残る（Issue `#266`）。
# プロセス終了時に必ず掃除し、stale 読み取りの種を残さない。fail_cli_task 内の
# clear と二重になっても rm -f なので害はない。アダプタが source するたびに
# trap を積み重ねないよう一度だけ仕掛ける。
# プロンプト一時ファイル（diff 込みで数百 KB になりうる）の失敗経路の掃除もここで
# 行う。fail_cli_task は内部で exit するため、アダプタ本文の成功パスに置いた
# `rm -f "$prompt_file"` には失敗時に到達しない — trap でなければ、タイムアウト・
# 認証エラー・CLI クラッシュのたびに残留する（Codex クロスモデルレビュー指摘）。
# アダプタは materialize_prompt_file の戻り値を _FF_PROMPT_FILE へも代入すること
# （関数は $( ) で呼ばれるため、関数内で設定したグローバルは親に残らない）。
_ff_adapter_exit_cleanup() {
  clear_timeout_reason
  if [[ -n "${_FF_PROMPT_FILE:-}" ]]; then
    rm -f "$_FF_PROMPT_FILE" 2>/dev/null || true
  fi
}
# EXIT trap は untrapped なシグナル死（Ctrl-C の INT / orchestrator からの TERM）
# では走らない。プロンプトファイルは 1 タスクあたり数百 KB になりうるので、
# シグナルでも掃除してから慣例の終了コード（128+signum）で終える。ここからの
# exit は EXIT trap を再度発火させるが、掃除は rm -f の冪等なので二重実行は無害。
if [[ -z "${_FF_TIMEOUT_REASON_EXIT_TRAP:-}" ]]; then
  _FF_TIMEOUT_REASON_EXIT_TRAP=1
  trap '_ff_adapter_exit_cleanup' EXIT
  trap '_ff_adapter_exit_cleanup; exit 130' INT
  trap '_ff_adapter_exit_cleanup; exit 143' TERM
  trap '_ff_adapter_exit_cleanup; exit 129' HUP
fi

# ── Prompt Encoding Guard ──
#
# プロンプトを CLI へ渡す直前に「バイト列として valid UTF-8 か」を検査する。
# codex-cli は stdin が不正な UTF-8 だと
#   Failed to read prompt from stdin: input is not valid UTF-8 (invalid byte at offset N)
# で**プロンプト全体**を拒否する。観点ごとに同じ description を載せるので、壊れた
# バイトが 1 つ混ざるだけで全観点が incomplete になり、レビュー結果は 1 件も出ない。
# 検査が無いと、その原因（呼び出し側のロケール）はエラー文からは辿れない。
#
# 混入経路として実測されているのは、非 UTF-8 ロケール（Windows / Git Bash の
# codepage 932、LANG 未設定の C ロケール）で `printf '%q'` を通った日本語テキストが
# 生バイトと $'\NNN' の混在になる形（orchestrator 側は shell_quote で塞いだ）。
# ただし --description は呼び出し元のスクリプトが作る任意のテキストで、混入経路を
# こちらで数え上げることはできない。だから「送る前に見る」ことをここで固定する。
#
# 検査器が無い環境では**黙って通さず**、検査していないことを 1 行残す。
assert_prompt_utf8() { # $1: プロンプトファイル / rc0 = valid（または検査不能）
  local f="$1" err="" sink="" rc=0
  if ! command -v iconv >/dev/null 2>&1; then
    echo "WARNING: iconv not found — the prompt was NOT checked for valid UTF-8." >&2
    echo "         A CLI that requires UTF-8 input may reject it as a whole." >&2
    return 0
  fi
  # -f/-t を明示するので変換自体はロケール非依存。LC_ALL=C は iconv 自身の
  # メッセージを環境ごとに揺らさないため。
  #
  # 変換結果は捨てるが、捨てる先を /dev/null にはしない。BSD iconv（macOS）は
  # stdout が /dev/null だと errno が上書きされ、stderr が原因と無関係な
  # "iconv(): Inappropriate ioctl for device" になる（実測）だけでなく、macOS 26 では
  # **valid な UTF-8 でも rc=1 を返す**（多バイト文字が出力の 1024 バイト境界を
  # またぐ入力で再現。バイト位置依存なので同じ内容でもパス長で緑・赤が入れ替わる。
  # 2026-09 実測）。通常ファイルへ向けると判定も診断も本来のものになる（不正バイトは
  # "Illegal byte sequence"、GNU iconv では位置まで残る）。
  # 一時ファイルが取れない環境では診断行を諦めて判定だけ行うが、そのときも
  # /dev/null へは向けず、プロセス置換のパイプへ捨てる（パイプ宛てなら rc は正しい）。
  sink="$(mktemp 2>/dev/null)" || sink=""
  if [[ -n "$sink" ]]; then
    err="$(LC_ALL=C iconv -f UTF-8 -t UTF-8 <"$f" 2>&1 >"$sink")" || rc=$?
    rm -f "$sink"
  else
    LC_ALL=C iconv -f UTF-8 -t UTF-8 <"$f" 2>/dev/null > >(cat 1>/dev/null) || rc=$?
  fi
  if [[ "$rc" -eq 0 ]]; then
    return 0
  fi
  echo "ERROR: the assembled prompt is not valid UTF-8 — refusing to send it to the CLI." >&2
  [[ -n "$err" ]] && echo "       ${err}" >&2
  echo "       Sending it would make the CLI reject the whole prompt (codex-cli:" >&2
  echo "       \"input is not valid UTF-8\"), so every perspective would end with no review." >&2
  echo "       Most likely cause: this shell runs under a non-UTF-8 locale, so text that" >&2
  echo "       passed through a locale-sensitive quoting step became a mix of raw bytes" >&2
  echo "       and \$'\\\\NNN' escapes." >&2
  echo "       Re-run from a UTF-8 shell:" >&2
  echo "         Windows / Git Bash: chcp 65001 && export LANG=C.UTF-8 LC_ALL=C.UTF-8" >&2
  echo "         POSIX:              export LC_ALL=C.UTF-8   (or en_US.UTF-8)" >&2
  echo "       Also check the text passed via --description: it must be valid UTF-8." >&2
  return 1
}

# プロンプト本文を一時ファイルへ実体化し、そのパスを echo する（失敗時は非 0）。
# 全アダプタ共通の受け渡し口。プロンプト（diff 込みで数百 KB になりうる）を argv に
# 乗せると Windows / Git Bash の CreateProcess 上限（約 32KB）で exit 126 になる
# （Issue `#712`。codex-cli / copilot-cli で同一 stderr を実測）。macOS / Linux も
# ARG_MAX が大きいだけで上限自体はあるため、経路ごと argv から外す。
# 呼び出し側は戻り値を _FF_PROMPT_FILE へも代入し（EXIT trap の掃除対象になる。
# 本関数は $( ) で呼ばれるため関数内でグローバルを設定しても親に残らない）、
# 成功パスでは使用後すみやかに rm -f すること（失敗パスは fail_cli_task が exit
# するため本文の rm に到達しない — trap が唯一の掃除経路になる）。
materialize_prompt_file() {
  local content="$1" f
  # mktemp の stderr を捨てない — read-only TMPDIR / 不在ディレクトリ / ENOSPC を
  # 区別できる唯一の診断がそこにある（捨てると全部「check TMPDIR」に潰れる）。
  # 2>&1 合流のため、成功でも -f で実在を確かめてから使う（成功 + stderr 警告の
  # 環境で変数へ警告文が混入する形への防御）。
  if ! f="$(mktemp 2>&1)" || [ ! -f "$f" ]; then
    printf 'materialize_prompt_file: mktemp failed: %s\n' "$f" >&2
    return 1
  fi
  # 末尾に改行を 1 つ付ける。stdin の末尾へ別テキストを連結する型の CLI で、
  # diff の最終行と後続テキストが同一行へ癒着するのを防ぐ（連結しない CLI には無害）。
  if ! printf '%s\n' "$content" >"$f"; then
    rm -f "$f"
    return 1
  fi
  # 検査は「書いたバイト列そのもの」に対して行う。組み立て途中の変数ではなく、
  # CLI の stdin になるファイルを見ることで、経路のどこで壊れても捕まる。
  if ! assert_prompt_utf8 "$f"; then
    rm -f "$f"
    return 1
  fi
  printf '%s\n' "$f"
}
_ac_part_loaded="adapter-common-output.sh"
