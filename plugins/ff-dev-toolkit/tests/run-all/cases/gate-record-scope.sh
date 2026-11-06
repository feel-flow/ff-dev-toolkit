# shellcheck shell=bash
# case 53: ゲートの記録の制御（FF_GATE_RECORD_FILE / FF_GATE_RECORD）は親の最終記録だけに使い、suite へ継承しない（OBS-414）
#
# verify.sh から source される（ok / bad / RUNNER / TESTS_DIR を共有）。本体が 4,000 行を超えているため
# cases ファイルへ置いた（ADR-057 決定 2）。
#
# 親が FF_GATE_RECORD_FILE を受けたまま suite を起動すると、別 checkout の fixture が記録器を
# --record なしで呼んだときに自分の git dir ではなく親の指定先へ書く（tests/finish の GR0〜GR2 が
# 偽赤になった）。FF_GATE_RECORD=0 を継承すると、suite が入れ子で回すランナーの記録まで止まる。
# 逐次（FF_RUN_ALL_JOBS=1）と並列（=2）の両経路で、次を測る:
#   53-B suite の環境に FF_GATE_RECORD_FILE も FF_GATE_RECORD も無い（空文字と未設定を区別する）
#   53-C suite が --record なしで呼んだ記録は、その fixture の git dir の既定の記録先へ書かれる
#   53-D suite が内部で明示した FF_GATE_RECORD_FILE はそのまま効く
#   53-E fixture が記録した直後、親の指定先はまだ存在しない（suite 内で親の指定先へ書いていない）。
#        走行後の親の指定先には親の最終記録がある（隔離を本体側まで広げると書かれない）
# 親の記録は 1 スロットの上書きで最後に書かれるので、走行後の内容だけでは途中の上書きを観測できない。
# そのため 53-E の前半は、疑似 suite が記録した直後の状態を控えさせて測る。
#
# 変異検出: 逐次・並列の各起動箇所から ff_suite_env_isolate の呼び出しだけを外した写しを、それぞれの
# 経路で回すと、suite が親の 2 つの値を受け取り、fixture の記録は親の指定先へ行く（53-M1 / 53-M2 が
# 53-B / 53-C / 53-E の検出を確かめる）。針の行が不在・重複・改名なら変異を当てずに赤にする（空振りを
# 緑と読まない）。

echo ""
echo "== case 53: 親の記録の制御（FF_GATE_RECORD_FILE / FF_GATE_RECORD）を suite へ継承しない =="

_gs_dir="$(mktemp -d "${TMPDIR:-/tmp}/ff-gate-record-scope.XXXXXX" 2>&1)" || _gs_dir=""
if [ -z "$_gs_dir" ] || [ ! -d "$_gs_dir" ]; then
  bad "case 53: 一時領域を作れず記録先の継承を実測できません"
else
  # 外側から GIT_DIR 系が export されていても、fixture の git 操作を外側のリポジトリへ向けない
  _gs_git() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
    git -c commit.gpgsign=false -c user.email=t@example.invalid -c user.name=T -c init.defaultBranch=main "$@"; }
  _gs_recorder="$TESTS_DIR/../scripts/record-gate-head.sh"
  # 記録先は git に問わずパスから組み立てる（rm -f の対象を一時領域の中に限る）
  _gs_fx_rec="$_gs_dir/repo/.git/ff-dev-toolkit/gate-record"
  _gs_setup_rc=0
  mkdir -p "$_gs_dir/repo" "$_gs_dir/gs-default" "$_gs_dir/gs-explicit" || _gs_setup_rc=1
  _gs_git init -q "$_gs_dir/repo" >/dev/null 2>&1 || _gs_setup_rc=1
  printf 'fixture\n' >"$_gs_dir/repo/a.txt" || _gs_setup_rc=1
  _gs_git -C "$_gs_dir/repo" add a.txt >/dev/null 2>&1 || _gs_setup_rc=1
  _gs_git -C "$_gs_dir/repo" commit -qm fixture >/dev/null 2>&1 || _gs_setup_rc=1
  [ -d "$_gs_dir/repo/.git" ] || _gs_setup_rc=1
  [ -f "$_gs_recorder" ] || _gs_setup_rc=1

  # suite 1: 受け取った 2 つの値を控え、--record なしで fixture の記録を書き、直後の親の指定先の有無を控える
  cat >"$_gs_dir/gs-default/verify.sh" <<'SH' || _gs_setup_rc=1
#!/usr/bin/env bash
set -euo pipefail
printf 'file=%s record=%s\n' "${FF_GATE_RECORD_FILE-UNSET}" "${FF_GATE_RECORD-UNSET}" >"$GS_PROBE"
cd "$GS_REPO"
bash "$GS_RECORDER" --gate fixture-default --status pass --mode full >/dev/null
if [ -e "$GS_PARENT_RECORD" ]; then echo present >"$GS_MIDRUN"; else echo absent >"$GS_MIDRUN"; fi
echo "GS-DEFAULT-EXECUTED"
SH
  # suite 2: 内部で明示した記録先へ fixture の記録を書く
  cat >"$_gs_dir/gs-explicit/verify.sh" <<'SH' || _gs_setup_rc=1
#!/usr/bin/env bash
set -euo pipefail
cd "$GS_REPO"
FF_GATE_RECORD_FILE="$GS_EXPLICIT" bash "$GS_RECORDER" --gate fixture-explicit --status pass --mode full >/dev/null
echo "GS-EXPLICIT-EXECUTED"
SH
  chmod +x "$_gs_dir/gs-default/verify.sh" "$_gs_dir/gs-explicit/verify.sh" || _gs_setup_rc=1

  if [ "$_gs_setup_rc" -ne 0 ]; then
    bad "case 53: fixture（一時 git リポジトリ・疑似 suite・記録器）を用意できません（以下の検査は何も測っていない）"
  else
    # <runner> <jobs>。親には FF_GATE_RECORD_FILE=$_gs_dir/parent-record と FF_GATE_RECORD=1 を渡す
    # （外から渡った FF_GATE_RECORD=0 で親の記録が止まる回を作らない）。結果は _gs_out / _gs_rc / _gs_probe / _gs_midrun
    _gs_run() {
      rm -f "$_gs_dir/parent-record" "$_gs_dir/explicit-record" "$_gs_dir/probe" "$_gs_dir/midrun" "$_gs_fx_rec"
      _gs_rc=0
      _gs_out="$(env -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
        FF_RUN_ALL_JOBS="$2" GS_PROBE="$_gs_dir/probe" GS_MIDRUN="$_gs_dir/midrun" GS_REPO="$_gs_dir/repo" \
        GS_RECORDER="$_gs_recorder" GS_EXPLICIT="$_gs_dir/explicit-record" GS_PARENT_RECORD="$_gs_dir/parent-record" \
        FF_GATE_RECORD=1 FF_GATE_RECORD_FILE="$_gs_dir/parent-record" \
        bash "$1" "$_gs_dir/gs-default/verify.sh" "$_gs_dir/gs-explicit/verify.sh" 2>&1)" || _gs_rc=$?
      _gs_probe="$(cat "$_gs_dir/probe" 2>/dev/null)" || _gs_probe="(probe 不在)"
      _gs_midrun="$(cat "$_gs_dir/midrun" 2>/dev/null)" || _gs_midrun="(probe 不在)"
    }

    for _gs_jobs in 1 2; do
      if [ "$_gs_jobs" = 1 ]; then _gs_path="逐次"; else _gs_path="並列"; fi
      _gs_run "$RUNNER" "$_gs_jobs"
      # 経路の取り違え（並列のつもりで逐次を測る）を緑と読まない
      case "$_gs_jobs:$_gs_out" in
        1:*"🧵 並列実行"*) bad "53-0 (${_gs_path}): 逐次を指定したのに並列経路で走った" ;;
        2:*"🧵 並列実行"*) ok "53-0 (${_gs_path}): 並列経路で走った" ;;
        2:*) bad "53-0 (${_gs_path}): 並列を指定したのに並列経路で走っていない（経路を測れていない）" ;;
        *) ok "53-0 (${_gs_path}): 逐次経路で走った" ;;
      esac
      if [ "$_gs_rc" -eq 0 ] && [[ "$_gs_out" == *GS-DEFAULT-EXECUTED* && "$_gs_out" == *GS-EXPLICIT-EXECUTED* ]]; then
        ok "53-A (${_gs_path}): 2 つの疑似 suite が緑で走った"
      else
        bad "53-A (${_gs_path}): 疑似 suite が走っていない（rc=${_gs_rc}）: ${_gs_out}"
      fi
      if [ "$_gs_probe" = "file=UNSET record=UNSET" ]; then
        ok "53-B (${_gs_path}): suite の環境に親の FF_GATE_RECORD_FILE / FF_GATE_RECORD が無い"
      else
        bad "53-B (${_gs_path}): suite が親の値を受け取った: ${_gs_probe}"
      fi
      if [ -f "$_gs_fx_rec" ] && grep -qx 'GATE=fixture-default' "$_gs_fx_rec"; then
        ok "53-C (${_gs_path}): --record なしの fixture の記録は fixture の git dir の既定の記録先へ書かれた"
      else
        bad "53-C (${_gs_path}): fixture の既定の記録先に記録が無い: ${_gs_fx_rec}"
      fi
      if [ -f "$_gs_dir/explicit-record" ] && grep -qx 'GATE=fixture-explicit' "$_gs_dir/explicit-record"; then
        ok "53-D (${_gs_path}): suite が内部で明示した FF_GATE_RECORD_FILE はそのまま効く"
      else
        bad "53-D (${_gs_path}): suite の明示指定が効いていない"
      fi
      if [ "$_gs_midrun" = "absent" ] && [ -f "$_gs_dir/parent-record" ] \
        && grep -qx 'GATE=tests/run-all.sh' "$_gs_dir/parent-record"; then
        ok "53-E (${_gs_path}): suite は親の指定先へ書かず、親の指定先には親の最終記録が書かれた"
      else
        bad "53-E (${_gs_path}): 親の指定先の扱いが違う（fixture の記録直後: ${_gs_midrun}）: $(cat "$_gs_dir/parent-record" 2>/dev/null || echo '(走行後に不在)')"
      fi
    done

    # 変異: 各起動箇所の呼び出しだけを外した写しで、その経路の suite が親の値を受け取ること。
    # 写しは記録器を持たない場所に置くので親の最終記録は書かれない（ここで測るのは継承だけ）。
    # 変異の対象となるシェル変数式を展開せず照合する。
    # shellcheck disable=SC2016
    _gs_seq_needle='      if FF_SUITE_OUTPUT="$(ff_suite_env_isolate; bash "$script" 2>&1)"; then'
    _gs_par_needle='        ff_suite_env_isolate'
    for _gs_mut in seq par; do
      if [ "$_gs_mut" = seq ]; then
        _gs_needle="$_gs_seq_needle"; _gs_jobs=1; _gs_label="53-M1 (逐次)"
      else
        _gs_needle="$_gs_par_needle"; _gs_jobs=2; _gs_label="53-M2 (並列)"
      fi
      # grep が失敗して空を返す回も「1 件ではない」として赤へ倒す（数値比較だと偽へ倒れて先へ進む）
      if [ "$(grep -cFx -- "$_gs_needle" "$RUNNER" 2>/dev/null)" != 1 ]; then
        bad "${_gs_label}: 変異の対象行が不在・重複・改名（空振り）: ${RUNNER} の行「${_gs_needle}」"
        continue
      fi
      mkdir -p "$_gs_dir/mut-$_gs_mut" || { bad "${_gs_label}: 変異の写しの置き場を作れない"; continue; }
      awk -v needle="$_gs_needle" -v mut="$_gs_mut" '
        $0 == needle {
          if (mut == "seq") { sub(/ff_suite_env_isolate; /, "") } else { $0 = "        :" }
        }
        { print }
      ' "$RUNNER" >"$_gs_dir/mut-$_gs_mut/run-all.sh" || { bad "${_gs_label}: 変異の写しを作れない"; continue; }
      if cmp -s "$RUNNER" "$_gs_dir/mut-$_gs_mut/run-all.sh"; then
        bad "${_gs_label}: 変異が適用されていない"
        continue
      fi
      _gs_run "$_gs_dir/mut-$_gs_mut/run-all.sh" "$_gs_jobs"
      # 53-B（継承）に加えて、53-C（fixture の既定の記録先に無い）と 53-E の前半（記録直後に親の指定先が
      # 在る）も変異で赤になることを確かめる。後者は、疑似 suite の控えが記録より前へずれて「修正前でも
      # 緑」へ戻った回を検出するため
      if [ "$_gs_probe" = "file=$_gs_dir/parent-record record=1" ] && [ "$_gs_midrun" = "present" ] \
        && [ ! -f "$_gs_fx_rec" ]; then
        ok "${_gs_label}: 呼び出しを外すと suite が親の値を受け取り、fixture の記録は親の指定先へ行く（53-B / 53-C / 53-E が検出する）"
      else
        bad "${_gs_label}: 呼び出しを外しても変異が観測されない（53-B / 53-C / 53-E の検出力）: probe=${_gs_probe} midrun=${_gs_midrun} fixture-record=$([ -f "$_gs_fx_rec" ] && echo present || echo absent)"
      fi
    done
  fi
  rm -rf "$_gs_dir"
fi
