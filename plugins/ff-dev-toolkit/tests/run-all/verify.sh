#!/usr/bin/env bash
# 空振り検出: cases の読み込み（tests/lib/suite-cases.sh。Issue `#2696`）は、一覧の source 行を消す・最終行を切る・ファイルを消す・完了印だけの空ファイルにする・入れ子の読み込み行だけを消す・入れ子を空にする各変異が、隔離コピーで rc=1 と狙いの診断になる（2026-11-08 macOS / Bash 3.2 実測）。
# 空振り検出: review-evidenceの合成共有TMPDIRで全15fixture代入の私有root境界と旧名sentinel不変を照合する。旧予測可能名への変異・入力空は赤、代入不在/0件も赤（2026-10-29 macOS実測）。
# 空振り検出: bash-hook-batchの実登録12本は通常rc0。新guard登録だけの削除と子の引数集合0件は、いずれも登録集合assertでrc1になる（2026-10-22 macOS実測、構文rc0。期待リストの厳密一致は維持）。
# 空振り検出: case26の実処理を抽出した対照で、負荷診断と有効宣言1件は成功、有効宣言0件と取得rc7は赤。未filterの反復・0件許容・終了コード消失の変異は全て検出。case47-Jは厳密な起動時負荷prefixだけを除き、他の警告・モード・summaryを維持し、filter除去変異を検出（2026-10-26 macOS実測）。
# 空振り検出: case30の実normalizerは起動時負荷警告・startup-load診断・既知の失敗時負荷案内だけを除き、他の警告とsuite出力・集計を保持する。各filterの独立除去3変異、入力の空集合、処理のno-op化はいずれも合成対照を赤にする（2026-10-28 macOS実測）。
# 空振り検出: case50は起動順をslow-a〜dのprobeログ（最初に起動した2本の集合。並列の回はrendezvousで2本目の開始を待つ）で読み、ログが4本分そろわない回は空として赤にする。記録は不在・空・形式崩れ（崩れた行を読み飛ばすと起動順が変わる形）・ディレクトリ・書けない既存ディレクトリの各入力を当て、既定一覧の経路は隔離した一時リポジトリとそのworktreeで測る。並べ替えを外す・記録なしを後ろへ回す・文字列で比べる・同順位を逆にする・形式の崩れを部分的に使う・空を有効とする・入れ子の除外を外す・記録を書かない・赤の秒数も書く・ディレクトリの中へ書く・stderrへ漏らす・既定の記録名を変える、の各変異を検出した（2026-10-30 macOS実測）。
# 空振り検出: case51は案内行の次の行から再実行コマンドを取り出し、取り出せない回（空）・形が違う回は赤にして実行しない（引数の欠けたコマンドで既定一覧を再帰起動しない。実行時は入れ子の印も付ける）。案内を外す・suite名を渡す・相対パスのまま出す・赤のパスを集めない・上書きで最後の1本だけにする・全件モードの前置を落とす、の各変異を検出した（2026-10-30 macOS実測）。
#
# verify.sh — テストランナー run-all.sh 自身の回帰検証（Issue #146 / 縮小: Issue #1022）
#
# 目的: 「1 つの suite が落ちても後続 suite を実行し、結果を集約して非 0 で終わる」という
# run-all.sh の契約を機械的に固定する。#146 の masking（先頭 suite の red が後続 4 suite の
# 実行を 2 日間止め、その隙間で別の回帰が隠れた）は、ランナーを `bash "$script"` の素直な
# fail-fast ループへ戻せば即座に再発する。
#
# 縮小方針（Issue #1022）: ランナー契約の核心 4 領域 —（1）集計（2）skip 判定（3）fail-closed
# 経路（4）選択モード — へ絞り、同じ検出対象を別 fixture で二重に踏んでいたケースは検出力単位で
# 統合した。ケース番号は履歴の追跡性のため振り直さず欠番のままにしてある（削除ケースと引き継ぎ先の
# 対応は PR #1219（Issue #1022）の本文）。
#
# 検証は fixtures/ の疑似 suite をランナーへ明示引数で渡して行う（一覧と役割は README.md）。高速
# モードの分岐は fixtures/pass の実在と fixtures/orphan の不在が決めるので、orphan/ を作ると
# case 16・26 の前提が崩れる。既定の suite 一覧には本 suite も含まれるが、ここで呼ぶのは常に明示
# 引数付きの実行なので再帰しない（ランナー側の入れ子ガードは case 8 で縛っている）。
#
# 実装メモ（ACE-86-2）: here-string / heredoc は一時ファイルを要求するため使わない。疑似 suite は
# 静的な fixture としてコミットしてあるが、登録漏れ検査だけは一時 tree を必要とする。TMPDIR が
# 使えなければ部分検査にせず、冒頭で suite 全体を明示 skip する。
#
# 変異検出（case 41 / 同梱 MCP 依存の起動ガード）:
#           ガードの発火条件を常に偽へ倒すと 41-A が赤。
#           述語から `mcp/package.json` の実在を落とすと、既定一覧を回す他ケース（26 / 38 /
#           39 / 40）まで巻き添えで赤になる — fixture 複製は mcp を持たないため。この述語が
#           「入れる先がある checkout だけを止める」ための配線であることの実測。
#           オプトアウトの値解釈を「任意の非空値で有効」へ緩めると 41-E が赤。
#           実行後の案内行（○ 案内: 同梱 MCP の依存が揃っていないため）の配線を外すと 41-F と
#           case 37 が赤。判定対象の解決を起動ガード側へ移した変更の回帰はここで観測する。
#           必須 skip の再現コマンドからオプトアウト前置を落とすと 41-G が赤。
#           述語を `.bin/esbuild` の実行可能性へ戻すと 41-M が赤
#           （末尾の案内行の側で同じ退行をすると case 37 の partial-mcp が赤）。
#           判定対象の上書きの告知を落とすと 41-I が赤、無条件化すると 39-A が赤。
#           停止の終了コードを suite 失敗と同じ 1 へ戻すと 41-A / 41-E / 41-H が赤。
#           ガードを登録照合の前・dirty ガードの前へ移すと 41-J / 41-K が赤。
#           発火条件から USING_DEFAULT_SCRIPTS を落とすと case 37 の partial-mcp が赤。
#           （位置と適用範囲は述語より退行しやすいので、全 3 方向を実測で固定してある）
# 空振り検出: case 49 の root 条件が不在・改名・0 件一致なら赤。診断条件を常に偽へ変えた写しでは起動前停止の probe が赤になることを実測する。
# 変異検出（case 48 / asdd-hook-gate の遡り）: ルートで '//' を作る元の形（base="$root"）へ戻した写しを
#           case 48 自身が流し、'//' が xtrace に現れることを確かめる。遡りがルートの '/.asdd' まで
#           届かない回（一時領域が git 管理下・xtrace が取れない）は針が当たらないので赤。
#
# 変異検出（case 45 / suite 単位の経過秒）:
#           elapsed-sec 行を出さなくすると 45-A / 45-B が赤。
#           未実行（missing / not-executable）を elapsed-sec へ混ぜると 45-A が赤。
#           2 秒かかる suite を 0 秒で出すと 45-B / 45-C が赤。
#           合成入力の降順ソートを外す・0 秒を残す・上限 8 を外すと 45-F が赤。
#           計測行の echo または ff_emit_elapsed 呼び出しを ff-summary-head-block の
#           内側へ移すと 45-E が赤。
#           date 不能をテスト失敗へ倒すと 45-D が赤。
#           ff_record_elapsed を no-op にすると 45-A / 45-B / 45-C が赤。
#
# 変異検出（case 50 / 起動順。Issue `#2535`）:
#           LAUNCH_ORDER へ並べ替え結果を入れない（常に登録順）と 50-A / 50-C / 50-I が赤。
#           記録なしの suite を記録ありより後ろへ回すと 50-C が赤。秒を文字列で比べると 50-A、
#           同順位の並びを逆にすると 50-I が赤。記録の形式検査を外して崩れた行を部分的に使うと 50-E、
#           空の記録を有効とすると 50-E2 が赤。入れ子の除外を外すと 50-G が赤。記録を書かないと
#           50-B / 50-D / 50-E が赤。赤の suite の秒数も記録すると 50-K、記録の場所のディレクトリへ
#           書き込むと 50-H2、一時ファイルを作れないエラー文を stderr へ漏らすと 50-H3、既定一覧の
#           記録名を変えると 50-J が赤。
#
# 変異検出（case 51 / 赤の suite の再実行コマンド。Issue `#2533`）:
#           案内を出さないと 51-A / 51-B / 51-C が赤。パスの代わりに suite 名を並べると
#           51-A / 51-B / 51-C が赤（名指し実行が not-run になる）。相対パスを絶対へ直さないと
#           51-C が赤。赤の suite のパスを集めないと 51-A / 51-B / 51-C / 51-E が赤（51-B は形が
#           違うので実行しない）。追記ではなく上書きで最後の 1 本だけにすると 51-E、全件モードの
#           前置を落とすと 51-F が赤。
#
# 変異検出（case 30 / 並列実行の同時実行数。Issue `#2062`）:
#           並列経路の起動直後に `wait $!` を挟んで逐次化すると「並列実行（同時実行数 2）で
#           suite が実際に上限の 2 本まで同時に走り…」が赤（最大同時 1）。同時実行数の上限を
#           外すと同じ検査が赤（最大同時 4）。後半の組の重なりと、空いたスロットへの投入の速さは
#           測らない（所要時間の比較をやめた対価。Issue `#2062`）。
# 空振り検出: case 30 の probe ログが作れない・読めない・開始 / 終了行が本数に揃わない回は、
#           緑へ倒さず赤にする。slow-a〜d の `_log` を空に固定して probe を書かせない
#           （環境変数が届かない形）と、並列・逐次の 2 件が「開始 / 終了 / 最大同時 = 0 0 0」で赤
#           （2026-10-05 WSL 実測）。逐次側の「2 本は重ならない」が probe の数え方の対照。
#
# 変異検出（case 42 / 鮮度バケット）:
#           鮮度マーカーの実体を改名すると suite 冒頭のマーカー契約検査が赤（fixture は照合側
#           しか固定できないので、emit 側の drift はここでしか捕まらない）。
#           行頭アンカーを部分一致へ緩めると stale-indented の回が赤。
#           分類を逐次経路だけに置くと RUN_JOBS=2 の回が赤（既定は並列）。
#           鮮度を skip へ倒すと「非 0 で終わる」「failed からも外さない」が赤。
#           緑 + マーカーの fail-loud を外すと stale-green の回が赤。
#           復旧手段の案内を落とすと 2 件が赤（初版は fixture 自身が同じ文言を出していたため
#           SURVIVED した。fixture からマーカー以外を落として解消してある）。
#           （件数は検査追加で静かに腐るのでケース番号で書く）
#
# 変異検出（case 35 / 終了コード検出器の判定順と引用符結合の終端。本体は cases/exit-code-guard.sh。
#           Issue `#1805`、2026-09-28 実測）:
#           検出器を修正前（develop 42e0d41d）の版へ戻すと「同じ行の上書き → 参照」と
#           「閉じない引用符の後 19 行以下」の 2 針が赤（suite rc=1）。var_event で上書き判定を
#           消費判定より前へ置き自己参照の除外を外すと「自己参照の再代入を同じ行に含む形」が赤。
#           短絡の直後の区間を条件付きと見ない（cond を常に 0）と「false && rc=0 の後の参照」が赤。
#           単位終端の heredoc 再投入を 1 回きりへ戻すと「引用符の再投入で開いた未終端 heredoc」が赤。
#
# 変異検出（case 14b / 空振り検出の宣言の登録照合。Issue `#1665`）:
#           名簿外 suite に宣言を要求する分岐を落とすと 14b-1 / 14b-6 / 14b-7' と case 14 の
#           source 検査が赤。名指しを先頭 1 件で打ち切ると 14b-6' が赤。
#           名簿の実在照合を落とすと 14b-4、宣言済み suite の名簿残留の照合を落とすと
#           14b-3 が赤。本文の無い宣言を probe=1 に数えると case 14 の負の対照
#           （pred-neg-probe-empty）が赤（14b-5 は malformed 経路の名指しを見る）。
#           ヘッダ限定を外す（ファイル全体で宣言を拾う）と 14b-2b と pred-neg-probe-late /
#           pred-neg-probe-heredoc が赤。空名簿で照合を成立させない（unbound で abort）形へ
#           戻すと 14b-6 / 14b-7 が赤。案内から正本のパス / 節名を落とすと 14b-1 が赤。
#
# 空振り検出: 実体の宣言ダンプが 0 件になる（書式が変わって 1 行も拾えない）と 14b-0 と
#           case 26 の「宣言ダンプが N 件の導出材料を返す」が赤になる。run-all.sh の名簿の
#           見出し行（MISS_PROBE_BASELINE=(）や SCRIPTS=( が改稿されて犠牲 suite を合成
#           できない木を与えると 14b-0 が赤になる（以降の 14b は成立しないと明示する）。
#
# 空振り検出: 一括走査だけを exit 23 にした awk を与えると、個別再走査が成功しても error_scan を返す。空 tracked 一覧・未読・対象実体なし・空ファイルを挟む境界も batch controls で固定する。
#
# 空振り検出: case 41 は npm ci 直後の正対照、esbuild が在るまま devDependency 欠落、npm 不在、lock 不在を実測し、後者は suite 未実行かつ rc 3 を要求する。
#
# 変異検出（case 47 の 47-K / 構成ファイルの変更を入口の変更として交差。ADR-075）:
#           ff_changed_select の構成ファイル（scripts/lib/multi-agent-*.sh）→ 入口の交差を外すと
#           47-K の「構成ファイルの変更で入口を参照する suite を選び…」と「入口を参照する suite が
#           実行される」が赤（2026-10-20 実測）。構成ファイルではない lib の変更で選ばれないことが対照。
# 空振り検出: pipefail_grep_q_scan が行頭の継承宣言（# pipefail-inherited:）を読まない写しでは「検出器が継承宣言を読まない」が赤（2026-10-20 実測）。値の中の同じ文言で設定扱いにしないことが対照。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/run-all/verify.sh

# 空振り検出: case35のconsumer集合だけを空にしたケースとcasesファイル全体を空にしたケースは、source後の集合検査だけが赤（77/1、0/1、各rc=1）。case35+同じ親検査の未変異85/0を対照に実測。空白だけの宣言は互換入力としてallowする（2026-10-22）。
# 変異検出（consumer context、2026-10-22）: 実cases sourceから実tracked走査へ渡す7状態の
#   focused対照8/0。復元削除・走査後へ復元移動・export属性復元削除・自己検証前の隔離削除は
#   順に5/1/4/2件赤（各rc=1、bash -n rc=0）。走査後復元は最終状態が一致してもmulti実走査だけ赤。
# 空振り検出: consumer context helper不在・読めない・同名0byte・mode集合0、実tracked入力から危険形を
#   消す各写しは親の集合検査または実走査検査1件で赤（対照8/0、各rc=1、2026-10-22）。
# 空振り検出: case 35 の pipe-and-chain（Issue `#2593`）は、検出の print を外す・pipefail の宣言を無視する・解除を宣言扱いにする・フェンス開始で状態を戻さない・`||` まで対象にする・tail / tee 以外で終わる左辺まで止める・`|&` を background と読む 7 変異が各 rc=1。無変異対照は rc=0（2026-11-04 WSL 実測）
# 空振り検出: case 52 は独立した run-all.sh（4194303:/x/run-all.sh）を与えると rc 2、プロセス一覧の取得失敗は rc 2、並走なしは GUARD_PASSED。ガード内のシェルの exit 2 行だけを外した写しは並走を名指した stderr（4194303:/x/run-all.sh）のあと GUARD_PASSED で rc 0（awk の END exit 2 は残す）。並走を ○ skip や GUARD_PASSED だけにすると 52-A が赤（2026-11-05 実測）。
# 空振り検出: case 53 は suite へ両方を継承する修正前の run-all.sh で 53-B / 53-C / 53-E が逐次・並列とも赤、変異の対象行の不在で 53-M1 / 53-M2 が赤（8 件）。FF_GATE_RECORD_FILE だけを外す版では 53-B が逐次・並列とも赤（FF_GATE_RECORD の継承）。逐次・並列の各呼び出しだけを外した写しは、その経路の suite が親の 2 つの値を受け取る（2026-11-07 WSL 実測）。一時領域・fixture を作れない回と、並列を指定したのに並列経路で走らない回は構造上赤（未実測）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="$TESTS_DIR/run-all.sh"
FIXTURES="$SCRIPT_DIR/fixtures"

# 「対を持たない selftest を除外しなかった」サマリー行の文言は case 26-A と case 27 の 2 箇所が
# アサートする。リテラルを両方へ書き写していたため、実装の文言を変えたときに片方だけ追随し、
# もう片方が «間違った理由で赤い» になった（実測）。文言はここへ 1 度だけ置き、実装側に実在
# することを fail-closed で確かめる。
KEPT_SELFTEST_HEAD='対になる本体 suite を持たない selftest'
KEPT_SELFTEST_TAIL='件は除外しなかった'
for _kept_needle in "$KEPT_SELFTEST_HEAD" "$KEPT_SELFTEST_TAIL"; do
  /usr/bin/grep -qF -- "$_kept_needle" "$RUNNER" \
    || { echo "✗ run-all verify: サマリー文言「${_kept_needle}」が run-all.sh に見つかりません（この検査は空振りします）" >&2; exit 1; }
done

# 鮮度マーカーは「ヘルパ側の emit」と「ランナー側の照合」の 2 箇所に現れる。片方だけを変える
# 変異は、3 suite すべて緑のまま**本番の分類だけが死ぬ**（実測済み）。fixture は照合側しか固定
# できないので、両方に同じリテラルが実在することをここで fail-closed に確かめる。
STALE_MARKER_LITERAL='✗ 鮮度:'
STALE_HELPER="$TESTS_DIR/lib/stale-base.sh"
[ -f "$STALE_HELPER" ] || { echo "✗ run-all verify: 鮮度ヘルパが見つかりません: $STALE_HELPER" >&2; exit 1; }
for _stale_file in "$STALE_HELPER" "$RUNNER"; do
  /usr/bin/grep -qF -- "$STALE_MARKER_LITERAL" "$_stale_file" \
    || { echo "✗ run-all verify: 鮮度マーカー「${STALE_MARKER_LITERAL}」が ${_stale_file} に見つかりません（emit と照合が drift すると分類が無警告で死にます）" >&2; exit 1; }
done

[ -f "$RUNNER" ] || { echo "✗ run-all.sh が見つかりません: $RUNNER" >&2; exit 1; }

# 並走検出（別 worktree の run-all.sh、またはプロセス一覧が取れない回）。走査の前に止める。
# 親の run-all.sh の系譜は除外する。系譜の外の独立した run-all.sh が見える回は rc 2 で、
# 全件ゲートの子として起動していてもこの suite は非 0 になり、ランナーは緑に数えない
# （ランナーの集計は変えない。復帰は並走が終わってから、またはプロセス一覧が取れてから回し直す）。
# 抽出に失敗した回も ○ skip にせず rc 2（判定不能は緑にしない）。
ff_verify_concurrency_guard() {
  local extract others="" rc=0
  extract="$(mktemp "${TMPDIR:-/tmp}/run-all-other-gates.XXXXXX" 2>/dev/null)" || {
    echo "✗ 判定不能: 並走検出の抽出先を作れません（プロセス一覧の判定が成立していない。実行できなかった）" >&2
    exit 2
  }
  if ! awk '
    BEGIN { found = 0 }
    /^# >>> ff-startup-other-gates$/ { grab = 1; next }
    /^# <<< ff-startup-other-gates$/ { if (grab) found = 1; exit }
    grab { print }
    END { if (!found) exit 2 }
  ' "$RUNNER" >"$extract"; then
    rm -f "$extract"
    echo "✗ 判定不能: 並走検出の関数を取り出せません（実行できなかった）" >&2
    exit 2
  fi
  if ! awk 'BEGIN { c = 0 } /^ff_startup_other_gates\(\) \{/ { c++ } END { exit c == 1 ? 0 : 1 }' "$extract"; then
    rm -f "$extract"
    echo "✗ 判定不能: 並走検出の関数が 1 つではありません（実行できなかった）" >&2
    exit 2
  fi
  # shellcheck disable=SC1090
  if ! . "$extract"; then
    rm -f "$extract"
    echo "✗ 判定不能: 並走検出の関数を読み込めません（実行できなかった）" >&2
    exit 2
  fi
  rm -f "$extract"
  others="$(ff_startup_other_gates)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "✗ 判定不能: プロセス一覧を取得できないため並走を判定できません（実行できなかった）" >&2
    if [[ -n "$others" ]]; then
      echo "  取得できた候補:" >&2
      printf '%s\n' "$others" >&2
    fi
    echo "  復帰: プロセス一覧が取れる状態で、この suite を回す" >&2
    exit 2
  fi
  if [[ -n "$others" ]]; then
    echo "✗ 判定不能: 別の全件ゲートが動いています（実行できなかった）。並走:" >&2
    printf '%s\n' "$others" >&2
    echo "  復帰: 並走中の tests/run-all.sh が終わってから、この suite を回す" >&2
    exit 2
  fi
}
ff_verify_concurrency_guard
if [[ "${FF_RUN_ALL_VERIFY_STOP_AFTER_GUARD:-}" == "1" ]]; then
  echo "GUARD_PASSED"
  exit 0
fi

# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_tmp_probe="$(mktemp -d "${TMPDIR:-/tmp}/run-all-preflight.XXXXXX" 2>&1)" && [ -d "$_ff_tmp_probe" ]; then
  RUN_WORK="$_ff_tmp_probe"
else
  echo "○ skip: 一時ディレクトリを作成できないため run-all self-test をスキップ（検査は1件も実行されていません）"
  printf '  mktemp: %s\n' "$_ff_tmp_probe"
  exit 0
fi

# 共有 TMPDIR の予測可能な名前は使わず、全 fixture を私有 root の下へ置く。
# set -u による途中死も成功へ変えない（他 suite と同じ終端契約）。
FF_REACHED_END=0
ff_cleanup() {
  ff_rc=$?
  rm -rf "$RUN_WORK"
  if [ "$FF_REACHED_END" != "1" ] && [ "$ff_rc" -eq 0 ]; then ff_rc=1; fi
  exit "$ff_rc"
}
trap ff_cleanup EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

RUN_OUT=""
RUN_RC=0

# ランナーの記録先を本 suite 専用の使い捨てへ逃がす。run_runner は疑似 suite を**わざと赤くする**
# 呼び出しを含むので、隔離しないと本リポジトリの実測記録が明示引数の赤い実行の記録
# （`STATUS=fail`）で潰れる（マージ直前の鮮度照合が判定不能になる）。末尾で消す。
RUN_GATE_RECORD="$RUN_WORK/ff-run-all-gate-record"
rm -f "$RUN_GATE_RECORD"

# 並走の fixture。本物の run-all.sh は起動しない。ps を差し替え、STOP_AFTER_GUARD で
# ガードの直後に戻す（ガードを外した変異が全件の走査へ進んで再帰しないようにする）。
echo "== case 52: 並走中は走査を始めない（rc 2） =="
_ff_guard_stub="$RUN_WORK/ps-stub"
mkdir -p "$_ff_guard_stub"
_ff_guard_real_ps="$(command -v ps)"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'real_ps="${FF_VERIFY_REAL_PS:?}"'
  printf '%s\n' 'if [ "${1:-}" = "-ww" ] && [ "${2:-}" = "-eo" ]; then'
  printf '%s\n' '  case "${FF_VERIFY_GRAPH:-}" in fail) exit 1 ;; esac'
  printf '%s\n' '  pid="$PPID"'
  printf '%s\n' '  i=0'
  printf '%s\n' '  while [ "$i" -lt 6 ] && [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$pid" != 1 ]; do'
  printf '%s\n' '    printf "%s 1 bash verify.sh\n" "$pid"'
  printf '%s\n' '    pid="$("$real_ps" -o ppid= -p "$pid" 2>/dev/null | tr -d "[:space:]")" || exit 1'
  printf '%s\n' '    i=$((i + 1))'
  printf '%s\n' '  done'
  printf '%s\n' '  if [ "${FF_VERIFY_GRAPH:-}" = "independent" ]; then'
  printf '%s\n' '    printf "%s 1 bash /x/run-all.sh\n" "${FF_VERIFY_SLEEPER_PID:?}"'
  printf '%s\n' '  fi'
  printf '%s\n' '  exit 0'
  printf '%s\n' 'fi'
  printf '%s\n' 'if [ "${1:-}" = "-ww" ] && [ "${2:-}" = "-o" ] && [ "${3:-}" = "args=" ] && [ "${4:-}" = "-p" ]; then'
  printf '%s\n' '  if [ "${5:-}" = "${FF_VERIFY_SLEEPER_PID:-}" ] && [ "${FF_VERIFY_GRAPH:-}" = "independent" ]; then'
  printf '%s\n' '    printf "%s\n" "bash /x/run-all.sh"'
  printf '%s\n' '    exit 0'
  printf '%s\n' '  fi'
  printf '%s\n' '  exit 1'
  printf '%s\n' 'fi'
  printf '%s\n' 'exit 1'
} >"$_ff_guard_stub/ps"
chmod +x "$_ff_guard_stub/ps"
ff_guard_invoke() { # <script> <graph>
  _ff_guard_script="$1"
  _ff_guard_graph="$2"
  _ff_guard_err="$RUN_WORK/guard-err"
  _ff_guard_rc=0
  _ff_guard_out="$(
    FF_RUN_ALL_VERIFY_STOP_AFTER_GUARD=1 \
    FF_VERIFY_GRAPH="$_ff_guard_graph" \
    FF_VERIFY_SLEEPER_PID=4194303 \
    FF_VERIFY_REAL_PS="$_ff_guard_real_ps" \
    PATH="$_ff_guard_stub:$PATH" \
    bash "$_ff_guard_script" 2>"$_ff_guard_err"
  )" || _ff_guard_rc=$?
  _ff_guard_err_text="$(cat "$_ff_guard_err")"
}
ff_guard_invoke "$SCRIPT_DIR/verify.sh" independent
if [ "$_ff_guard_rc" -eq 2 ] \
  && case "$_ff_guard_err_text" in *"4194303:/x/run-all.sh"*) true ;; *) false ;; esac \
  && case "$_ff_guard_out$_ff_guard_err_text" in *GUARD_PASSED*|*'○ skip'*) false ;; *) true ;; esac; then
  ok "52-A: 独立した run-all.sh が見えると走査を始めず rc 2 で並走を名指しする"
else
  bad "52-A: 並走の停止が違う（rc=${_ff_guard_rc}） out=[${_ff_guard_out}] err=[${_ff_guard_err_text}]"
fi
ff_guard_invoke "$SCRIPT_DIR/verify.sh" fail
if [ "$_ff_guard_rc" -eq 2 ] \
  && case "$_ff_guard_err_text" in *"プロセス一覧を取得できない"*) true ;; *) false ;; esac \
  && case "$_ff_guard_out$_ff_guard_err_text" in *GUARD_PASSED*|*'○ skip'*) false ;; *) true ;; esac; then
  ok "52-B: プロセス一覧を取得できない回は rc 2（緑にも skip にもしない）"
else
  bad "52-B: プロセス一覧の失敗が違う（rc=${_ff_guard_rc}） out=[${_ff_guard_out}] err=[${_ff_guard_err_text}]"
fi
ff_guard_invoke "$SCRIPT_DIR/verify.sh" clean
if [ "$_ff_guard_rc" -eq 0 ] && case "$_ff_guard_out" in *GUARD_PASSED*) true ;; *) false ;; esac; then
  ok "52-C: 並走が無いスナップショットはガードを通過する（このあと全検査へ進む）"
else
  bad "52-C: 並走なしでガードが通らない（rc=${_ff_guard_rc}） out=[${_ff_guard_out}] err=[${_ff_guard_err_text}]"
fi
# 変異コピーは dirname から run-all.sh と鮮度ヘルパを探す。一時ディレクトリ直下に置くと
# その探索が /tmp/run-all.sh になり、ガードより前の針で rc 1 になる。実ファイルと同じ
# 相対配置（tests/run-all/verify.sh の隣に run-all.sh）へ置く。
_ff_guard_tree="$RUN_WORK/guard-tree"
mkdir -p "$_ff_guard_tree/run-all" "$_ff_guard_tree/lib"
ln -s "$RUNNER" "$_ff_guard_tree/run-all.sh"
ln -s "$STALE_HELPER" "$_ff_guard_tree/lib/stale-base.sh"
_ff_guard_mut="$_ff_guard_tree/run-all/verify.sh"
awk '
  /^ff_verify_concurrency_guard\(\)/ { in_fn = 1 }
  in_fn && /^}/ { in_fn = 0 }
  in_fn && /^[[:space:]]*exit 2[[:space:]]*$/ { print "  :"; next }
  { print }
' "$SCRIPT_DIR/verify.sh" >"$_ff_guard_mut"
ff_guard_invoke "$_ff_guard_mut" independent
if [ "$_ff_guard_rc" -eq 0 ] \
  && case "$_ff_guard_out" in *GUARD_PASSED*) true ;; *) false ;; esac \
  && case "$_ff_guard_err_text" in *"4194303:/x/run-all.sh"*) true ;; *) false ;; esac; then
  ok "52-D: シェルの exit 2 だけを外すと並走を名指したままガードの後まで進む（その変異は 52-A が赤にする）"
else
  bad "52-D: exit 2 の除去を検出できない（rc=${_ff_guard_rc}） out=[${_ff_guard_out}] err=[${_ff_guard_err_text}]"
fi

# ランナーを引数付きで実行し、出力と終了コードを記録する。
# `out=$(...)` を素で書くと set -e が失敗時点で落とすので if 形式で受ける。
#
# FF_RUN_ALL_FAST と FF_RUN_ALL_FULL は**常に落としてから**呼ぶ。本 suite 自身が高速モードや全件
# 実行の run-all から起動されると外側の値が環境へ漏れて継承され、検査したいモードがその回だけ別
# モードになる（FF_RUN_ALL_FAST の漏れは実測で 5 件壊した）。モードは RUN_FAST=1 / RUN_FULL=1 で
# 明示的に与える。どちらも与えない呼び出しは「明示引数 + 環境変数なし」= 名指しした suite を全部
# 走らせる形（ADR-034）。引数なしの既定一覧が高速モードであることは case 26 が複製木で検査する。
#
# 同時実行数は RUN_JOBS で与える。**既定は 1（逐次）**にする — 並列実行（Issue #595）は起動順と
# スロットの空き方で完了順が変わり、既定のままだとケースごとに再現性の無い実行になる。並列側の
# 契約は case 30 / 32 が RUN_JOBS を明示して測る。
run_runner() {
  # 両方 1 は呼び出し側の意図が不明なので黙って一方を採らない（この suite が最も警戒する形）。
  if [ "${RUN_FAST:-0}" = "1" ] && [ "${RUN_FULL:-0}" = "1" ]; then
    bad "run_runner: RUN_FAST と RUN_FULL の同時指定（呼び出し側の誤り）"
    RUN_OUT=""
    RUN_RC=99
    return 0
  fi
  if [ "${RUN_FAST:-0}" = "1" ]; then
    if RUN_OUT="$(env -u FF_RUN_ALL_FULL FF_RUN_ALL_FAST=1 FF_RUN_ALL_JOBS="${RUN_JOBS:-1}" FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" bash "$RUNNER" "$@" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
  elif [ "${RUN_FULL:-0}" = "1" ]; then
    if RUN_OUT="$(env -u FF_RUN_ALL_FAST FF_RUN_ALL_FULL=1 FF_RUN_ALL_JOBS="${RUN_JOBS:-1}" FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" bash "$RUNNER" "$@" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
  else
    if RUN_OUT="$(env -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL FF_RUN_ALL_JOBS="${RUN_JOBS:-1}" FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" bash "$RUNNER" "$@" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
  fi
}

# 出力に $1（grep BRE）がマッチするかを返す。`grep -q` は使わない: マッチ時点で終了して上流の
# printf を SIGPIPE (141) で殺し、pipefail のもとでマッチが「不一致」へ反転する（出力が 64KB を
# 超えると発生する）。`grep -c` は入力を最後まで読むのでその反転が起きない。マッチ 0 件でも
# 本関数は数値を受け取って比較するだけなので、grep の rc=1 が set -e に触れない。
out_matches() {
  [ "$(printf '%s\n' "$RUN_OUT" | grep -c "$1")" -gt 0 ]
}

expect_has() {
  # $1: grep BRE / $2: 検査名
  if out_matches "$1"; then
    ok "$2"
  else
    bad "$2 — 出力に /$1/ が無い"
  fi
}

expect_lacks() {
  if out_matches "$1"; then
    bad "$2 — 出力に /$1/ がある"
  else
    ok "$2"
  fi
}

# stdout / stderr を**分けて**捕まえた回のための対（RUN_STDOUT / RUN_ERR は分離実行のヘルパーが
# 置く）。統合ストリーム（`2>&1`）だけを見る検査は「警告を stdout へ出す」変異を素通しする —
# 機械が読むサマリー（stdout）へ混ざらないことが要件の出力は、こちらで縛る。
stream_matches() { # $1: grep BRE / $2: 対象ストリームの中身
  [ "$(printf '%s\n' "$2" | grep -c "$1")" -gt 0 ]
}

expect_err_has() {
  if stream_matches "$1" "${RUN_ERR:-}"; then ok "$2"; else bad "$2 — stderr に /$1/ が無い"; fi
}

expect_err_lacks() {
  if stream_matches "$1" "${RUN_ERR:-}"; then bad "$2 — stderr に /$1/ がある"; else ok "$2"; fi
}

expect_stdout_has() {
  if stream_matches "$1" "${RUN_STDOUT:-}"; then ok "$2"; else bad "$2 — stdout に /$1/ が無い"; fi
}

expect_stdout_lacks() {
  if stream_matches "$1" "${RUN_STDOUT:-}"; then bad "$2 — stdout に /$1/ がある"; else ok "$2"; fi
}

dump_out() { printf '%s\n' "$RUN_OUT" | sed 's/^/    | /' >&2; }

# 静的検査の定型（ランナー本体の形を縛る側）。$1: grep -E パターン / $2: 対象 / $3: 成立時の名 /
# $4: 不成立時の名。
expect_src() {
  if grep -qE "$1" "$2"; then ok "$3"; else bad "$4"; fi
}

# case 1 / case 30 が共有する混在一覧（fail 先頭 + pass / skip / 実行不可 / 不在）。
MIXED_FIXTURES=(
  "$FIXTURES/fail/verify.sh"
  "$FIXTURES/pass/verify.sh"
  "$FIXTURES/skip/verify.sh"
  "$FIXTURES/not-executable/verify.sh"
  "$FIXTURES/missing/verify.sh"
)

# 直前の run_runner の終了コードを主張する。$1 は `0` / `nz`（非 0）/ 具体的な数値。
# 失敗時は出力も落とす（旧版はこの 6 行を毎ケース書き写していた）。
expect_rc() {
  _erc_ok=0
  if [ "$1" = "nz" ]; then
    [ "$RUN_RC" -ne 0 ] && _erc_ok=1
  elif [ "$RUN_RC" -eq "$1" ]; then
    _erc_ok=1
  fi
  if [ "$_erc_ok" -eq 1 ]; then
    ok "$2（rc=${RUN_RC}）"
  else
    bad "$2 — rc=${RUN_RC}"
    dump_out
  fi
}

# ── 検査本体（機能別 cases ファイル。Issue `#2696` で分割） ────────────────
#
# 各ファイルは同一プロセスで source され、上の fixture・関数・PASS/FAIL を共有する。
# **この一覧の順序が契約**で、分割前の verify.sh の行の順序そのもの。後ろの cases は前の cases
# が定義した関数と fixture を使う。1 ファイルだけを実行する入口は置かない。
# shellcheck source=../lib/suite-cases.sh
. "$TESTS_DIR/lib/suite-cases.sh"
suite_cases_source "$SCRIPT_DIR/cases" accounting.sh
suite_cases_source "$SCRIPT_DIR/cases" registration.sh
suite_cases_source "$SCRIPT_DIR/cases" reintroduction-guards.sh
suite_cases_source "$SCRIPT_DIR/cases" fast-mode.sh
suite_cases_source "$SCRIPT_DIR/cases" parallel.sh
suite_cases_source "$SCRIPT_DIR/cases" startup-guards.sh
suite_cases_source "$SCRIPT_DIR/cases" cross-repo-scans.sh
suite_cases_source "$SCRIPT_DIR/cases" execution-contracts.sh
# 残りの 4 本は上の cases の中から同じ関数で読む（case 35・47・53）。
suite_cases_assert_all_sourced "$SCRIPT_DIR/cases"

# 集約入口の契約は既存の hook 登録検査と同じ suite で実測する。
if bash "$SCRIPT_DIR/bash-hook-batch.sh"; then
  ok "Bash 集約入口が登録・出力・大入力の契約を保つ"
else
  bad "Bash 集約入口の回帰検証が失敗"
fi

rm -f "$RUN_GATE_RECORD"

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ run-all verify: $FAIL 件失敗" >&2
  exit 1
fi

echo "✓ run-all verify: 全 $PASS 件 pass"
FF_REACHED_END=1
exit 0
