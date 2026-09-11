#!/usr/bin/env bash
#
# ff-dev-toolkit prompt fixture regression test runner.
#
# 実行対象の suite を最初の red で止めず全部回し、結果を集約して報告する（Issue #146）。
# 「実行対象」は既定では高速モードの集合（対を持つ selftest を除いた残り。ADR-034）で、
# 登録されている全 suite を回すのは FF_RUN_ALL_FULL=1 のとき。最初の失敗で停止する
# fail-fast だと、1 件のゲート違反が無関係な後続 suite の検出力をまとめて 0 にする。
# 実際に PR #144 の changelog-version red が 2 日間、後続 4 suite（破壊的操作を扱う
# merge-cleanup を含む）の実行を止め、その隙間で別の回帰が隠れていた。fail-fast は
# 「red は即座に直される」前提でのみ成立し、放置された瞬間に fail-silent へ反転する。
#
# suite との契約:
#   - 成功なら exit 0、失敗なら非 0 を返す
#   - 環境の都合で**検証本体をまるごと実行できなかった**場合は exit 0 を返しつつ、
#     行頭が `○ skip` の行を出力する（read-only 環境の merge-cleanup など）。ランナーは
#     これを pass ではなく skip として数え、サマリーで名指しする。マーカー文言は
#     tests/run-all/verify.sh が実在を検査するので、変えると red になる。
#     一部の検査だけを飛ばす「部分 skip」でこのマーカーを出さないこと（1 行でも
#     あると suite 全体が skip 扱いになり、実際に走った検査が報告から消える）。部分
#     skip は1文字以上インデントした `○ skip` を出す。ランナーは検査件数を
#     `checks-skipped` へ別集計し、suite-level の skipped / REQUIRED_SUITES 判定へは混ぜない
#     **suite 全体の skip 経路を新しく足した suite は既定で必須になる**（fail-closed）。
#     `REQUIRED_SUITES` へ 1 行足すか、verify.sh へ `# run-all-required: no — 理由`
#     （理由は必須。無いと赤）を書くまで登録照合が赤になる。導出規則は下の
#     check_suite_registration 直前のコメント「必須名簿の逆向き導出」を参照。
#   - 終了コード: 失敗 or 未実行が 1 件でもあれば 1、それ以外は 0。ただし passed が
#     0 で skipped だけの場合も 1（検証が 1 件も成立していない状態を緑にしない）
#     起動ガード（後述の dirty tree 検査など）で suite を 1 件も実行せずに終わる回も 1
#     を返す（サマリー行は出ない。「非 0 = 失敗」だけを見て緑と誤読しないこと）
#
# 引数に suite のパスを渡すと、既定の一覧ではなくその一覧だけを実行する。
# tests/run-all/verify.sh が疑似 suite を渡して本ランナー自身の挙動を検証するための
# 口で、自己テストは常に明示引数で呼ぶため既定の一覧に自身が居ても再帰しない。
# サマリーの suite 識別子は親ディレクトリ名なので、渡す suite は親ディレクトリ名が
# 互いに一意であること（同名だとどちらが失敗したのか報告から読めない）。
#
# ── 実行モード: 既定は高速モード（ADR-034）──────────────────────────────────
# **引数なしの既定一覧は高速モードで走る。** 高速モードは、suite 名（親ディレクトリ名）が
# `-selftest` で終わり **かつ対になる本体 suite（名前から `-selftest` を落としたディレクトリ
# の verify.sh）が実在する** suite だけを実行対象から除外する。この種の selftest はゲート
# 本体（tests/*/verify.sh）の検出力を変異注入で実測するもので、検査対象を変更しない限り
# 原理的に結果が変わらない。既定を反転した回の実測（所要時間の前後比較）は ADR-034 が指す
# Issue のコメントに残す — ここへ数値を書くと suite の増減で静かに腐る（旧ヘッダーが抱えて
# いた「53.9%」がまさにその形で、現在値との乖離を注記で釈明する状態になっていた）。
# 判定は命名規約と対の実在だけで導出し除外名簿を持たないため、新規 selftest も自動的に
# 対象になる。除外は SKIPPED とは別勘定で、REQUIRED_SUITES の必須 skip 判定には掛からない
# （意図的な除外と環境都合の skip を区別する）。
#
# **全件実行は明示指定する**: FF_RUN_ALL_FULL=1（値が 1 のときだけ有効。`0` と空値は
# 「無効」、それ以外の非空値は解釈できない指定として 1 行警告のうえ全件実行で続行する）。
# リリース前・公開同期前の定期実行点は「週次 CI の成功実績確認 + ローカル run-all green」
# （healthy なら既定/高速で足り、確認できない回は全件で代替。ADR-039 / docs/04-quality/TESTING.md）。
#
# FF_RUN_ALL_FAST は後方互換のために残す。`1` は高速モード（既定と同じなので実質 no-op、
# ただし明示引数への適用だけは下記のとおり変える）、`0` は「明示的に高速モードでない」=
# 全件実行として扱う — 既定反転より前に `export FF_RUN_ALL_FAST=0` で全件実行を意図して
# いた呼び出し側の検出力を、既定の変更で黙って落とさないため（`0` と空値を等価に扱って
# いた ADR-031 決定 3 からの意図的な変更）。`1` / `0` / 空値以外は 1 行警告のうえ全件実行
# （fail-safe 側）。FF_RUN_ALL_FULL=1 と FF_RUN_ALL_FAST=1 の同時指定は矛盾なので 1 行
# 警告し、除外しない側（既定一覧なら全件実行、明示引数なら名指しの全実行）を採る。
#
# 対になる本体 suite を持たない `-selftest` は除外しない（Issue #602 / ADR-031）。根拠は
# 「live な検査だから」ではない — release-required-selftest は隔離 fixture への変異注入だけを
# 行い、ライブリポジトリの状態を見ない（同 suite のヘッダーに明記）。対が無いということは
# **その検査対象を見る suite が他に無い**ということで、除外するとその対象を触った変更が
# 無検査で通る（#602 時点で 3 件: release-required-selftest
# 〔scripts/check-release-required.sh の唯一の検査〕・mcp-state-selftest〔dist_state
# wrapper の byte 一致など〕・adapter-env-isolation-selftest〔consumer 名簿の照合など〕）。
# 除外しなかった件数と suite 名はサマリーへ出す。
#
# 明示引数の実行は「名指ししたものを走らせる」を既定にする（ADR-034 で ADR-031 決定 4 を
# 変更）。既定一覧の高速化と違い、名指しした suite を黙って落とすのは意図と端的に食い違う
# ためで、既定反転後は `bash tests/run-all.sh tests/<名>-selftest/verify.sh` が何も実行しない
# 形になってしまう。ただし **FF_RUN_ALL_FAST=1 を明示したときだけ**は従来どおり明示引数にも
# 除外を適用する — tests/run-all/verify.sh が疑似 suite を明示引数で渡すことが「除外で実行
# 対象が 0 件 → exit 1」の fail-closed 経路を実測する唯一の口だから（既定一覧では本体 suite が
# 必ず残るうえ、selftest だけの木は登録漏れ検査が先に落ちる）。そのとき名指しした suite が
# 除外されたら stderr へ 1 行警告し、矛盾を可視化する。
#
# 残るトレードオフ（意図的な選択）: 対を持つ selftest は既定で除外されるので、その検査対象
# （tests/*/verify.sh・tests/lib/*.sh）を変更した回を既定のまま通すと、ゲートの検出力の退行は
# 全件実行まで検出されない。**既定反転により、このトレードオフは毎回取られることになる。**
# その全件実行は開発元リポジトリの週次 CI（.github/workflows/weekly-run-all.yml、Issue #598 /
# ADR-037。配布物には含まれない）が担保し、リリース前・公開同期前の定期実行点は「週次 CI の
# 成功実績確認 + ローカル run-all green」を要求する（ADR-039。healthy を確認できない回は
# 全件で代替）。`tests/` 等の変更時に高速モードを拒否する
# 安全弁は置かない — 条件分岐を増やさず、挙動を単純に保つ（ADR-034 で再確認した）。
#
# 実行方式のトレードオフ: 各 suite の出力は skip マーカー判定のため command
# substitution で丸ごと受けてから出力する。そのため suite 実行中のリアルタイム進捗は
# 出ず（merge-cleanup は実 git 操作を伴うので体感差がある）、途中で kill された場合は
# 実行中 suite の出力が残らない。stdout/stderr も 1 本に合流する。skip を pass から
# 区別するために意図して受け入れているトレードオフ。
#
# ── 並列実行（Issue #595）────────────────────────────────────────────────────
# suite は既定で並列に走る。**実行対象は変わらない** — 変わるのは起動の順序と同時
# 実行数だけで、「全 suite を必ず実行して結果を集約する」設計（Issue #146）はそのまま。
# 出力は完了順ではなく**登録順**に suite 単位でまとめて出す（逐次実行と同じ並び。
# 完了順にすると同じ suite 一覧でも実行のたびに並びが変わり、前回との差分が読めない）。
#
#   既定の同時実行数: 論理 CPU 数（上限 8）
#   上書き: FF_RUN_ALL_JOBS=<1〜256 の整数>。`1` で逐次実行へ戻る。解釈できない値と
#           上限超過は 1 行警告のうえ既定値で続行する（fail-safe 側）
#   入れ子（外側の run-all.sh から suite として呼ばれた回）は、FF_RUN_ALL_JOBS を
#   明示しない限り逐次で走る — 外側と内側で同時実行数が掛け算になるのを避ける
#
# 上限を 8 に置くのは、実時間の上限を見る suite があるため（multi-agent-timeout の
# 「早く終われば早く返る（< 8 秒）」など）。同時実行数を上げすぎると、その幅を負荷
# 経由で食って «間違った理由で赤い» を作る。数値の実測は Issue #595 のコメントに残す
# — ここへ書くと suite の増減で静かに腐る（ADR-034 のヘッダーが辿った形）。
#
# 並列実行は spool ディレクトリ（mktemp -d）を要求するため、下の read-only 制約から
# 外れる。**制約は逐次実行の経路で維持する** — 一時領域を確保できない環境では 1 行
# 警告して逐次へ退避し、skip も失敗もしない（実行対象と結果は同じで所要時間だけ伸びる）。
# 各 suite の出力はファイルへ落とし、終了コードは本文を書き終えた**後に** rename で
# 置く。「rc ファイルの実在 = その suite の出力が完成している」を親が追加の同期なしに
# 読めるようにするため。rc を残さず子が消えた場合は pass にも fail にも倒さず未実行
# として数える。spool の後片付けに EXIT トラップは置かない（理由は該当箇所のコメント。
# 終了コードの正しさを一時ディレクトリの残骸より優先する）。
#
# ── 起動ガード: dirty tree では既定一覧を走らせない ──────────────────────────
# 引数なしの既定一覧は、作業ツリーに未コミットの変更（未追跡ファイルを含む）があると
# suite を 1 つも実行せずに非 0 で終わる。汚れた木の実行結果は特定のコミットに対する
# 実測ではなく、鮮度記録が `DIRTY=yes` になってマージ直前の照合が「判定不能」に落ちる
# ため、数分〜十数分をかけた実行がまるごと証拠にならないからである。
#
#   オプトアウト: FF_RUN_ALL_ALLOW_DIRTY=1（値が 1 のときだけ有効。`0` と空値は quiet で
#                 無効、それ以外の非空値は 1 行警告のうえガード有効のまま続行する）。
#                 記録は従来どおり `DIRTY=yes` で書かれる = 証拠にはならない。汚れの
#                 確認自体ができずに停止する回（下記）も同じ変数で解除する
#
# 汚れているかを確認できない場合（git が無い / リポジトリの外）も clean と断定せずに
# 停止する（fail-closed）。判定は記録側 scripts/record-gate-head.sh と同じ述語
# （`git status --porcelain` の stdout が非空）で、ずれると「ガードは通ったのに
# DIRTY=yes」が起きる。明示引数の実行と検査専用モード（宣言ダンプ・登録照合のみ）は
# 対象外。詳細は docs/04-quality/TESTING.md。
#
# **この述語を当てるのは起動時の 1 回だけではない**。起動ガードが clean と断定できた回は、
# サマリー出力の直後・鮮度記録を書く前に同じ述語をもう一度当てて、走行中に汚れていれば
# fail-loud する（終了コードは変えない。実装は下方の「走行中に汚れなかったかを終了時に
# 再評価する」節、規約側は docs/04-quality/TESTING.md）。
#
# Keep this read-only friendly: do not create temporary files and avoid here-doc / here-string.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ロケールが POSIX（LANG / LC_ALL / LC_CTYPE 未設定。Claude Code cloud の既定）だと、
# マルチバイト正規表現を持つ suite（docs-gates / docs-gates-runtime ほか）が docs の内容と
# 無関係に赤になる。子 suite へ継承させるため、ここで 1 回だけ UTF-8 ロケールへ固定する
# （既に UTF-8 なら何もしない。無ければ 1 行警告して続行）。lib が無い fixture コピー
# （tests/run-all/verify.sh は本ファイルだけを複製する）では素通しする。
if [ -f "$SCRIPT_DIR/lib/utf8-locale.sh" ]; then
  # shellcheck source=lib/utf8-locale.sh
  . "$SCRIPT_DIR/lib/utf8-locale.sh"
  ff_ensure_utf8_locale
fi

# 入れ子で既定 suite 一覧を走らせると、自己テスト → 本ランナー → 自己テスト … と
# 無限再帰する（merge-cleanup の一時 git リポジトリ生成まで巻き込んで暴走する）。
# 明示引数付きの入れ子だけを許し、引数なしの入れ子は fail-closed で止める。
# 入れ子だったかを export で潰す前に控える。既定の同時実行数の決定（Issue #595）が
# 「外側の run-all.sh から呼ばれた回か」を見るために要る。
if [[ "${FF_RUN_ALL_NESTED:-0}" != "0" ]]; then
  FF_ENTERED_NESTED=1
else
  FF_ENTERED_NESTED=0
fi

if [[ "${FF_RUN_ALL_NESTED:-0}" != "0" && $# -eq 0 ]]; then
  echo "✗ run-all.sh を入れ子で引数なし実行しようとしました（既定 suite 一覧は無限再帰します）" >&2
  echo "  入れ子からは検証したい suite のパスを明示引数で渡してください" >&2
  exit 1
fi
export FF_RUN_ALL_NESTED=1

# ゲート開始時の HEAD を控える。全件実行は長く、その間に commit があると終了時の HEAD は
# 「一度も読んでいないツリー」になる。記録側へ渡して、動いていたら記録させない（Issue #880）。
FF_GATE_START_HEAD="$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || true)"

# 走行中にランナー自身が書き換えられた実行を「緑」として観測させない（Issue #885）。
# bash はスクリプトを一括で読まず**実行しながら読み進める**ため、走行中にファイルが
# 書き換わるとオフセットがずれ、無関係な位置から読み直す。実測（Issue #880 / PR #883）
# では `run-all.sh: line 878: king: command not found` を出し、サマリー行を一切出さない
# まま **exit 0** で終わった — 破棄された実行が「静かに終わった緑」に化ける。
#
# 指紋は外部依存の少ない順に cksum → wc -c で取る。git は worktree の外や未インストール
# 環境で使えず、mtime は stat の方言差（BSD/GNU）を抱える。どちらも標準入力で完結し
# 一時ファイルを作らないので、本ファイル冒頭の read-only 制約を守れる。
#
# **この検査は「最終行まで到達できた場合の保険」**である。走行中の書き換えはプロセス
# 自体を壊すため、多くの場合ここへ到達しない。到達しなかった実行の検出は
# **サマリー行（`suites: total=…`）の不在**で行う（呼び出し側の契約。docs/04-quality/TESTING.md）。
SELF_PATH="$SCRIPT_DIR/$(basename "$0")"
ff_self_fingerprint() { # -> stdout（取得できなければ空 + 非 0）
  if command -v cksum >/dev/null 2>&1; then
    cksum < "$SELF_PATH" 2>/dev/null && return 0
  fi
  wc -c < "$SELF_PATH" 2>/dev/null
}
# 指紋が取れない環境では検査を無効化する（この検査は保険であり、取得不能を赤にすると
# 本来の検証結果が環境事情で潰れる）。ただし無効化したことは黙らせない。
FF_SELF_FINGERPRINT_START="$(ff_self_fingerprint || true)"
if [[ -z "$FF_SELF_FINGERPRINT_START" ]]; then
  echo "⚠️  ランナー自身の指紋を取得できません（${SELF_PATH}）— 走行中の自己書き換え検査は無効です" >&2
fi

# >>> ff-summary-head-block（tests/run-all/verify.sh がこのマーカーで切り出し、
# 指紋照合とサマリー行の出力が同一関数に同居していることを静的に検査する）
# 指紋照合と**サマリー冒頭 3 行の出力**を同じ関数に置く。bash の関数定義は読み込み時に
# 本体ごとパースされるので、suite ループより前に定義したこの関数の中身は走行中の
# 書き換えでは変わらない。結果として **「サマリー行が出た ⟹ 指紋照合を通った」** が
# **構造的に**成り立つ。
#
# 照合を「サマリー出力の直前の行」に置くだけでは、位置による保証にしかならない。
# 読み取りオフセットのずれ先が照合ブロックより後だった場合、照合を経ずにサマリーが
# 出て exit 0 になりうる（レビュー指摘）。呼び出し行ごと飛ばされた場合はサマリー行が
# 出ないので、そちらは読み手側の契約（サマリー行の不在 = 未完了）で受け止める。
#
# `exit` は関数内でもシェル全体を終わらせる。RUN も内側で組み立てて、外へ出す情報を
# この関数だけに閉じる。
ff_emit_summary_head() {
  local _now
  if [[ -n "$FF_SELF_FINGERPRINT_START" ]]; then
    _now="$(ff_self_fingerprint || true)"
    if [[ "$_now" != "$FF_SELF_FINGERPRINT_START" ]]; then
      echo "✗ 実行中にランナー自身が書き換えられました: ${SELF_PATH}" >&2
      echo "  起動時の指紋: ${FF_SELF_FINGERPRINT_START} / 現在: ${_now:-取得不能}" >&2
      echo "  bash は実行しながらスクリプトを読み進めるため、この実行がどのスナップショットに対するものか不明です。" >&2
      echo "  この実行の結果は証拠に使えません。編集を確定させてから最初から回し直してください。" >&2
      exit 1
    fi
  fi
  RUN=$(( ${#PASSED[@]} + ${#FAILED[@]} + ${#SKIPPED[@]} ))
  echo "== summary =="
  echo "suites: total=${#SCRIPTS[@]} run=$RUN passed=${#PASSED[@]} failed=${#FAILED[@]} skipped=${#SKIPPED[@]} not-run=${#NOT_RUN[@]}"
  echo "checks-skipped: total=${CHECKS_SKIPPED_TOTAL} suites=${#CHECKS_SKIPPED[@]}"
}
# <<< ff-summary-head-block

if [[ $# -gt 0 ]]; then
  SCRIPTS=("$@")
  USING_DEFAULT_SCRIPTS=0
else
  USING_DEFAULT_SCRIPTS=1
  SCRIPTS=(
    # 一時ディレクトリも外部コマンドも要らない静的検査を先に置く（安価な順。
    # 全 suite を実行するので、並び順は結果ではなく報告の読みやすさの問題）。
    "$SCRIPT_DIR/skill-frontmatter/verify.sh"
    # 同梱resourceを使う全skillが、読み込み元rootを実行中に固定し、cache再探索や
    # 別version fallbackをしない契約を持つことをlive走査 + negative controlで固定する。
    "$SCRIPT_DIR/plugin-root-contract/verify.sh"
    "$SCRIPT_DIR/skill-bash-blocks/verify.sh"
    # 全プラグイン SKILL.md の references 相対参照（バッククォート単一トークンと
    # Markdown リンクの `references/…` / `../<skill>/…`）の実在・プラグイン内収まりの
    # 検査（Issue #889）。同じ SKILL.md 横断走査なので skill-bash-blocks の直後に置く。
    # 検出力は同 suite 内の fixture（抽出・非検出・変種・解決の 4 系統）で毎回実測する。
    "$SCRIPT_DIR/skill-references-existence/verify.sh"
    # ルート設定で tracked Markdown 全体を lint し、DoD の「markdownlint エラーなし」を
    # 実行可能にする。依存は同梱 MCP の node_modules から借り、直後の selftest が
    # 新規違反を非 0・ファイル名付きで検出することを固定する（Issue #295）。
    "$SCRIPT_DIR/markdownlint/verify.sh"
    "$SCRIPT_DIR/markdownlint-selftest/verify.sh"
    # tracked shell スクリプト全体の静的検査（Issue #530）。Markdown 側の
    # markdownlint と対になる shell 側の lint ゲートなので直後に置く。赤にするのは
    # error 重大度のみ（構文エラーと抑制ディレクティブのパース不能。線引きの根拠は
    # suite のヘッダ）。抑制ディレクティブの構文エラーは「そのファイルの静的検査が
    # 丸ごと止まる」形なので、ゲートが無いと永久に気付けない。検出力は同 suite 内の
    # fixture 2 本（不正ディレクティブ / 正しいディレクティブ + error 未満の指摘）で
    # 常設実測する。shellcheck が PATH に無ければ丸ごと ○ skip（単体で〜14 秒）。
    "$SCRIPT_DIR/shellcheck/verify.sh"
    # case 11（*.sh MBCS）の fail-closed 経路をシームで自動回帰（Issue #312）。
    # skill-bash-blocks の直後: 同欠陥クラスの SKILL.md 側ガードと並べて報告する。
    "$SCRIPT_DIR/mbcs-guard-failclosed/verify.sh"
    "$SCRIPT_DIR/no-hardcoded-model/verify.sh"
    # 上の「外部コマンド不要」の例外で、yq に依存する（agent-config.yaml の構造検査 —
    # 単一ドキュメント性と全 map 横断の重複キー — を削除したミラー 2 suite から引き継いだ）。
    # 読み取り専用の静的検査。yq 不在なら丸ごと ○ skip（REQUIRED_SUITES 掲載）。
    "$SCRIPT_DIR/cli-registry-completeness/verify.sh"
    # 収録スキル数の手入力メタデータ（marketplace.json root/oss・plugin.json）と
    # skills/*/SKILL.md の実数の整合検査（Issue #502）。jq のみに依存する読み取り
    # 専用の静的検査。件数の複製を扱う点で cli-registry-completeness の直後に置く。
    "$SCRIPT_DIR/skill-count-consistency/verify.sh"
    # 上の gate の検出力を mktemp fixture への変異（スキル±1・補助物混入・root/oss
    # 片側更新・内訳合計不一致・抽出空振り）で実測する。一時領域不可なら丸ごと ○ skip。
    "$SCRIPT_DIR/skill-count-consistency-selftest/verify.sh"
    # 全プラグインの description が列挙するスキル名の集合整合（Issue #1004）。
    # 上の suite は ff-dev-toolkit 1 件しか見ないため、他 8 プラグインは
    # 「plugin.json だけ更新して marketplace.json を取り残す」drift が無検査だった
    # （PR #1003 で実際に発生）。jq のみに依存する読み取り専用の静的検査。
    "$SCRIPT_DIR/plugin-description-enumeration/verify.sh"
    # 上の gate の検出力を mktemp fixture への変異（片側だけの更新・両側未更新・
    # プラグイン集合の片側走査・実在しない名前・部分文字列の誤読・source 欠落・
    # 同名エントリの重複・免除と非列挙の名簿の腐り・抽出失敗）で実測する。
    # 一時領域不可なら丸ごと ○ skip。
    "$SCRIPT_DIR/plugin-description-enumeration-selftest/verify.sh"
    # agent-config.yaml の「実際に読まれるキー」の説明が単一正本で、その主張が
    # multi-agent.sh の yq 読み取りと連動し、消費側 4 スキル（multi-* 3 本 +
    # setup-ai-config）が複製ではなく参照 1 行を持つことの静的検査。外部コマンド不要だが、
    # 同じ設定ファイルを扱う cli-registry-completeness の直後に置く。
    "$SCRIPT_DIR/agent-config-doc-sync/verify.sh"
    "$SCRIPT_DIR/ace-curate-commit/verify.sh"
    # 行数バジェット例外の運用 SSOT（PLAYBOOK）と live、README の参照、見本
    # ACE-000-3 の 4 条件を静的に照合する（Issue #351）。外部コマンド・一時領域不要。
    "$SCRIPT_DIR/ace-line-budget-docs/verify.sh"
    # docs-template/scripts/ace/*.ts（SSOT）と repository root scripts/ace/*.ts
    # （実行用 mirror）のファイル集合 + byte-identical、および #318 で統合した
    # entryHeadingSource の既知 consumer が共有 import を使うことを静的に固定する。
    # README は配置文脈に応じた正当な差分があるため対象外（Issue #338）。
    "$SCRIPT_DIR/ace-scripts-mirror/verify.sh"
    # 上の gate を隔離コピーへ 1 byte drift / 片側ファイル / ローカル regex 書き戻しで
    # poison し、検出器自身が red になることを実測する。perl / 一時領域が無い場合だけ
    # suite 全体を ○ skip する（実作業ツリーは変更しない）。
    "$SCRIPT_DIR/ace-scripts-mirror-selftest/verify.sh"
    # 版の一致（旧 changelog-version）と参照境界を 1 本で見る（Issue #800 で統合）。
    # どちらも同じ CHANGELOG を同じ手順で解決し、外部依存を持たず read-only で完走する
    # ため可用性条件が一致する（ACE-927-3: 混ぜてよいのはここが揃うときだけ）。
    "$SCRIPT_DIR/changelog-contract/verify.sh"
    # 上の gate の検出力を fixture への変異注入で実測する（Issue #610）。本体は実
    # CHANGELOG を検査するので、緑のままでは「何を検出できるか」が分からない。
    # perl / 一時領域が無い場合は ○ skip するが、検出力が丸ごと消えるため
    # REQUIRED_SUITES に載せて明示許可を要求する。
    # 検査対象の直後に置くことを優先し、安価な順の例外として扱う。
    "$SCRIPT_DIR/changelog-contract-selftest/verify.sh"
    # Issue 単位の CHANGELOG 断片 schema、materialize の冪等性、2 branch の
    # 無競合直列マージを fixture で実測する（ADR-038 / Issue #764）。
    "$SCRIPT_DIR/changelog-fragments/verify.sh"
    # バージョン区間の CHANGELOG 要約（changelog-digest.sh）の区間・fail-closed・
    # 幅・UTF-8 文字境界・自動解決を隔離 fixture で実測する（Issue #947）。
    "$SCRIPT_DIR/changelog-digest/verify.sh"
    # マーケットプレイス自動更新 hook の発行内容・日次間引き・fail-silent・
    # オプトアウト・hooks.json 登録（async）を stub claude で実測する（Issue #856）。
    "$SCRIPT_DIR/auto-update-hook/verify.sh"
    # 文書 / PLAYBOOK の共有版を、non-fast-forward 後に merged tree から再生成して
    # 収束させる手順と 2 clone 実測（ADR-038 / Issue #764）。
    "$SCRIPT_DIR/shared-version-convergence/verify.sh"
    "$SCRIPT_DIR/docs-gates/verify.sh"
    "$SCRIPT_DIR/out-of-scope-routing/verify.sh"
    # out-of-scope 判定の実挙動検証（Issue #499）: SKILL.md から抽出した行数閾値と
    # prefix 優先順位を参照実装へ流し、判定表・バッチ表の期待ルートと照合する
    # 静的検査。外部コマンド・一時領域不要。契約文言を見る out-of-scope-routing の
    # 直後に置く。
    "$SCRIPT_DIR/out-of-scope-decision/verify.sh"
    # 上 2 gate の検出力を隔離 fixture への変異注入（旧規則の言い換え・矛盾文の
    # 注入・SKILL 本文/コンシューマーからの契約節の個別削除・閾値/優先順位の改変・
    # 抽出契約行の破壊・参照実装への依存注入、の 12 種）で実測する（Issue #499）。
    # perl / 一時領域が無い場合だけ丸ごと ○ skip（実作業ツリーは変更しない）。
    # 検査対象の直後に置くことを優先し、安価な順の例外として扱う。
    "$SCRIPT_DIR/out-of-scope-routing-selftest/verify.sh"
    # /refine-issue の skip 条件契約（Issue #683）: 手順 6・7 を skip してよいのは
    # 「6 観点違反 0 件 かつ SubAgent 論点 0 件」のときだけ、という AND を SKILL.md の
    # 3 箇所（skip 条件・階層化判定の入口・skip 時の報告見出し）で固定する。単一条件へ
    # 戻すと上流ゲートの検出結果が後段へ届かず落ちる。外部コマンド・一時領域不要。
    # 同じ「スキルの契約文言」を扱う out-of-scope 系に続けて置く。
    "$SCRIPT_DIR/refine-issue-skip-contract/verify.sh"
    # removal-sweep の 3 系統走査契約（Issue #991）: 撤去 PR の残存参照走査
    # 3 系統（識別子 / 表示文言 / 構造セレクタ・モック応答）が SKILL.md から
    # 個別に消えないこと、E2E / スナップショット / a11y の名指しと「デプロイ済み
    # 成果物はブランチで検出できない」警告を literal 針で固定する。外部コマンド・
    # 一時領域不要。同じ「スキルの契約文言」を扱う out-of-scope 系に続けて置く。
    "$SCRIPT_DIR/removal-sweep/verify.sh"
    # /retrospective の規定（提案閾値・承認境界・read-only 境界・ask モード・trigger 語）
    # と、ワークフローチェーン記載の相互整合の静的検査（Issue #540）。モノレポでは
    # 7 ファイル / 13 針、公開配置では 6 ファイル / 11 針を見る。上限と 1 行報告の文面は
    # SKILL.md から導出して消費側文書へ伝播しているかを照合する。外部コマンド・一時領域
    # 不要。同じ「スキルの契約文言 × 消費側文書」を扱う out-of-scope 系に続けて置く。
    "$SCRIPT_DIR/retrospective-contract/verify.sh"
    # 上の gate の検出力を隔離 fixture への変異注入（チェーン記載の針それぞれからの
    # コマンド削除・規定マーカーと伝播の契約行削除・上限の片側書き換え・抽出不能化・
    # 上限の併存・絞り込み文の追従漏れ・1 行報告の drift・ゲート自身の針数ガードの
    # 縮み）で実測し、赤化した検査の件数まで照合する。ゲートの
    # 検査総数も縛るので、検査そのものが削除される侵食もここで赤くなる。モノレポでは
    # 公開配置を模した第 2 fixture も回す。perl / 一時領域が無い場合だけ丸ごと ○ skip
    # （実作業ツリーは変更しない）。検査対象の直後に置くことを優先し、安価な順の例外。
    "$SCRIPT_DIR/retrospective-contract-selftest/verify.sh"
    # `retrospective-contract` は prompt 文言だけを固定する。実際の plugin context / Stop hook が
    # 初回に block し、継続中・off・不正入力では fail-open するランタイム契約を fixture
    # で実行する（Issue #583）。直後の selftest は入出力・再入・mode・依存・副作用・
    # SKILL 同期・登録の変異を赤化し、consumer の検査総数も固定する。
    "$SCRIPT_DIR/retrospective-stop-hook/verify.sh"
    "$SCRIPT_DIR/retrospective-stop-hook-selftest/verify.sh"
    # PreToolUse（Bash）の未コミット変更ガード（hooks/guard-checkout-restore.sh、
    # Issue #673）。fixture の git リポジトリ + stdin JSON で発火（dirty への
    # checkout/restore を deny + 代替案内）と非発火（ブランチ切り替え・clean/untracked・
    # --staged 単独・バイパス・fail-open）の両側を固定する。実作業ツリーには触れない。
    "$SCRIPT_DIR/guard-checkout-restore/verify.sh"
    # PreToolUse（Bash）の PR フォローアップ宣言ガード（hooks/guard-pr-followup.sh、
    # Issue #771）。宣言マーカーと Issue 参照の共起判定・no-followup 抜け道・
    # --body-file / heredoc 経由・既知の限界の素通しを stdin JSON fixture で固定する。
    "$SCRIPT_DIR/guard-pr-followup/verify.sh"
    # PreToolUse（Bash）の background cwd ガード（hooks/guard-background-cwd.sh）。
    # モノレポ判定・background 判定・先頭コマンドの絶対 cd 判定の 3 条件と、警告が
    # ブロックでない（systemMessage のみ）ことを stdin JSON fixture で固定する。
    # 絶対化イディオム（コマンド置換・変数展開）を誤警告しない線引きも併せて見る。
    "$SCRIPT_DIR/guard-background-cwd/verify.sh"
    # PreToolUse（Bash）の工数実績 未記入マージガード（hooks/guard-effort-actual.sh）。
    # ff-effort ブロックがあるのに effort_ai_actual が未記入の Issue を閉じる
    # gh pr merge を止める側と、ブロック不在・記入済み・非該当コマンド・gh/jq 不在で
    # 止めない側を stdin JSON fixture + gh スタブで固定する。close-issue 手順 5a の
    # fail-open 契約（ブロック不在は素通し）と矛盾しないことも併せて見る。
    "$SCRIPT_DIR/guard-effort-actual/verify.sh"
    # PreToolUse（Edit/Write/MultiEdit/NotebookEdit/Bash/Agent）のレビュー走行中ロック +
    # 起動時 dirty ガード（hooks/guard-review-in-flight.sh）。ロック生存中の編集・git 書き込みの
    # deny、FF_REVIEW_LOCK_OVERRIDE での解除、ロック不在・stale PID の非 deny、
    # pr-review-toolkit エージェント起動時の dirty 確認（ask）と clean / ignored のみの非発火を
    # stdin JSON fixture で固定する。orchestrator 側のロック 3 経路は
    # multi-agent-revision-guard が実走で見る。
    "$SCRIPT_DIR/guard-review-in-flight/verify.sh"
    # PreToolUse（Bash）の起票ラベル契約ガード（hooks/guard-issue-labels.sh）。
    # 起票スキルを経由しない gh issue create に対し、種別 / 優先度の欠落は抜け道付き
    # deny、follow-up の欠落は systemMessage の案内だけ、という二段を stdin JSON
    # fixture で固定する。ラベル一覧を信用できないとき（照会失敗 / 空 / 上限到達）に
    # 止めないこと、heredoc 本文の素通しと終端行直後の実コマンド検出の対、
    # ラベル名の正本が setup-github-labels の軸別表であることを隔離コピーへの
    # 変異注入で実測する。gh は fixture の stub に解決させ、実リポジトリは照会しない。
    "$SCRIPT_DIR/guard-issue-labels/verify.sh"
    # squash 件名の closing keyword が Refs 運用の Issue を閉じる経路のガード。
    # 検査ロジック（scripts/check-closing-keywords.sh）の振る舞いと、SKILL.md /
    # git-workflow.md 側の規約が drift していないことを併せて見る。外部コマンド
    # 不要・一時ディレクトリ不要なので静的検査群に置く。
    "$SCRIPT_DIR/closing-keyword-guard/verify.sh"
    # close-issue が組み立てる merge コマンドの引用がロケールに依存しないこと。
    # printf %q は現在のロケールで文字境界を解釈するため、非 UTF-8 ロケールでは
    # 日本語の件名・本文が生バイトと $'\NNN' の混在になり、貼って実行する手順が壊れる。
    # SKILL.md から引用関数を抽出して LC_ALL=C で round-trip を実測する。
    # 同じ SKILL.md の同じ窓（マージ直前）を守るので closing-keyword-guard の隣に置く。
    "$SCRIPT_DIR/close-issue-shell-quote/verify.sh"
    # PR トリガーの CI を持たない repo（本リポジトリを含む）で checks を待たず
    # ローカル全件ゲート + 鮮度照合をマージ根拠にする分岐（OBS-070 Count 3 昇格）。
    # close-issue/SKILL.md 手順 7 と git-workflow.md マージ節の 2 文言を節スコープで
    # 固定する。同じ「マージ直前の窓」を守る契約なので close-issue-shell-quote の
    # 隣に置く。外部コマンド・一時領域不要。
    "$SCRIPT_DIR/no-checks-merge-basis-contract/verify.sh"
    # マージ直前の鮮度ゲート（Issue #880）: 「リモート先端 == ゲート実測対象」の照合と、
    # 記録側（scripts/record-gate-head.sh）・本ランナーの配線・SKILL / ワークフロー文書の
    # 文言が drift していないこと。一時領域と git を要するが、closing-keyword-guard と
    # 同じ「マージ直前の窓」を守る契約なので、安価な順より主題の近さを優先して隣に置く。
    "$SCRIPT_DIR/merge-freshness/verify.sh"
    # 工数 KPI の契約（Issue #1136）: ff-effort ブロックのマーカーとフィールド名が
    # 書く側（create-issue）・書き戻す側（close-issue）・読む側（effort-report.sh）で
    # 一致すること、緩めた本文差分の述語がマーカー外の編集を通さないこと、乖離の記録が
    # 3 帯すべてを覆うこと。マージ直前の窓（Issue 本文の書き換え）を守る契約なので
    # merge-freshness の隣に置く。jq と一時領域を要する。
    "$SCRIPT_DIR/effort-contract/verify.sh"
    # Git Workflow の tier 判定（scripts/workflow-tier.sh）の振る舞いと、段の単一正本の
    # 契約（Issue #801）。判定は path 一覧を受ける入口を持つので git の状態を捏造せずに
    # 全ケースを回せる。段数・tier 件数・分布の手書きが無いことは否定の主張なので、
    # 一時コピーへの変異注入で検出力を毎回実測する（一時領域が無い場合はその部分だけ
# 名指しで skip）。ワークフロー文書の契約群（closing-keyword-guard /
    # review-rejection-discipline）と同じ並びに置く。
    "$SCRIPT_DIR/workflow-tier/verify.sh"
    # レビュー指摘を却下するときの検証規律（Issue #655）: review-response-policy の
    # 却下 4 要件（単変数実測・実測範囲のみ記載・指示形禁止・趣旨と実装の分離）と、
    # 実測要求を技術的制約の主張に絞る発動条件を節スコープで、対応フローからの導線と
    # multi-review の委譲行を全文針で静的に固定する。外部コマンド・一時領域不要。
    # 同じくワークフロー文書（docs-template/deployment）の契約文言を固定する
    # closing-keyword-guard の直後に置く。
    "$SCRIPT_DIR/review-rejection-discipline/verify.sh"
    # 起票スキル 2 本（create-issue / out-of-scope-issue）に意図的に複製されている
    # verify-then-skip ラベル契約（body-file + 単純コマンド分割方式。Issue #715）の
    # 散文照合と、起票フェンスが複合構文を含まないことの構造検査、
    # 両者の意図的な非対称（候補の系統・アサイン方針）の固定。jq / gh / yq 不要の静的検査。
    # 検査対象の一方 out-of-scope-issue を共有するので、out-of-scope 系・retrospective 系の
    # 契約検査群に続けて置く。
    "$SCRIPT_DIR/issue-label-contract/verify.sh"
    # 推奨ラベル・セットアップの SSOT（docs-template/scripts/setup-github-labels.sh の
    # LABEL_DEFS）と github-setup.md の表・手動例・setup-github-labels SKILL.md
    # 軸別表の 4 箇所照合 + delete 案内との交差 + 名前の正本との位置比較 +
    # stub gh での振る舞い実測（冪等・fail-closed・部分失敗）。実 CLI・ネットワーク・
    # 課金・一時ファイルを伴わない。ラベル契約つながりで issue-label-contract の直後に置く。
    "$SCRIPT_DIR/github-labels-setup/verify.sh"
    # 起票スキルが参照するラベル名 ⊆ (LABEL_DEFS ∪ GitHub デフォルト allowlist) の
    # 包含照合（Issue #624）。issue-label-contract はスキル間で複製された契約
    # テキストの同期（ラベル付与手順・粒度チェック項目リスト）、
    # github-labels-setup は供給側 4 箇所の同期を見るのに対し、本 suite は
    # 参照側と供給側をまたぐ包含を見る（verify-then-skip の fail-soft により、
    # 供給されない参照は「起票成功のままラベルだけ黙って落ちる」ため）。
    # gh / jq / yq・一時ファイル不要の静的検査。
    "$SCRIPT_DIR/issue-label-supply/verify.sh"
    # create-issue 手順5の ISSUE_TEMPLATE 節 pre-flight（テンプレートの `## ` 見出しを
    # 本文と照合し、無い節を fail-soft で報告する）が実装から消えないことの固定。
    # 手順6ステップ1の実行指示、手順7の完了報告への報告義務、git-workflow.md
    # ステップ1の raw `gh issue create` 前の確認手順も見る。jq / gh 不要の静的検査。
    # ラベル契約つながりで issue-label-supply の直後に置く。
    "$SCRIPT_DIR/create-issue-template-preflight/verify.sh"
    # setup-multi-agent.sh の yq 導入が Mike Farah v4 を明示取得し、非互換 yq
    # （distro パッケージ / Python / v3）を利用可能と誤認しないこと（Issue #271）。
    # install の exit 0 を信用せず post-install で flavor/capability を再検証する。
    # 一時ディレクトリと PATH 上の shim を使うが、ネットワーク・実インストールは伴わない。
    "$SCRIPT_DIR/setup-multi-agent-yq/verify.sh"
    "$SCRIPT_DIR/setup-ai-config/verify.sh"
    "$SCRIPT_DIR/asdd-runtime/verify.sh"
    "$SCRIPT_DIR/assess-impact/verify.sh"
    "$SCRIPT_DIR/validate-docs/verify.sh"
    # /validate-docs §4 のプレースホルダー免除（閉じたフェンス / コメント /
    # インラインコードスパン、閉じ忘れは除外区間にしない）を fixture のトークン
    # 残存数で固定する。LLM を介さない機械照合（Issue #518）。
    "$SCRIPT_DIR/validate-docs-placeholders/verify.sh"
    # 上の gate の検出力を、マスク実装の除外範囲の拡大 / 縮小で実測する。
    # perl 不在または一時領域不可なら丸ごと ○ skip。
    "$SCRIPT_DIR/validate-docs-placeholders-selftest/verify.sh"
    # docs-template 初期セット 20 文書の構造契約（Frontmatter 必須6フィールド +
    # 文末 Changelog + init-docs SKILL ツリーとの集合一致）。/validate-docs の
    # 拡張文書チェックはオプトイン設計なので、テンプレートの Frontmatter 欠落は
    # この gate だけが守る。外部コマンド不要の静的検査（Issue #509）。
    "$SCRIPT_DIR/docs-template-frontmatter/verify.sh"
    # init-docs/SKILL.md 置換ポリシーの「ステップ1で埋まるプレースホルダー一覧」が
    # 同梱テンプレートの実体から乖離していないことを固定する（Issue #1317）。
    "$SCRIPT_DIR/init-docs-placeholder-list/verify.sh"
    # 配布先レイアウトで .github 配下と初期セット 20 文書のリンク・references・inline path
    # が解決し、初期セット内文書が初期セット外へ角括弧リンクを張っていないこと（Issue #1319）、
    # init-docs + ace-setup で露出したテンプレート 8 欠陥が戻らないことを固定する
    # （Issue #981）。Node.js 組み込み API のみを使う静的検査。
    "$SCRIPT_DIR/docs-template-portability/verify.sh"
    # 上の gate の検出力を mktemp fixture への変異（FM 除去・フィールド欠落・
    # 値域外・未閉鎖・ファイル削除・ツリー片側更新・抽出空振り・重複キー（引用符付き
    # キーを含む）・SemVer 先頭ゼロ・status の中間状態・日付プレースホルダー免除の
    # 境界・created/updated の前後関係）で実測する。赤ケースは理由の文言まで照合する
    # （ケース消失の検出は週次 CI での selftest 実行とレビューが担う — Issue #873 で
    # 検査総数ガードは廃止した）。
    # perl 不在または一時領域不可なら丸ごと ○ skip。
    "$SCRIPT_DIR/docs-template-frontmatter-selftest/verify.sh"
    # 対象プロジェクトの docs/ 側 Frontmatter 付与規則の回帰ゲート。MASTER.md の
    # 付与対象 / 付与しない表から両側を導出して集合一致を見る（規則と実体の drift 検出）。
    # docs/ を持たない checkout では丸ごと ○ skip（Issue #513）。
    "$SCRIPT_DIR/docs-frontmatter-repo/verify.sh"
    # 上の gate の検出力を mktemp fixture への変異（FM 除去・値域外・未閉鎖・
    # 実体/規則の片側追加・抽出空振り・除外規則の効き）で実測する（Issue #513）。
    "$SCRIPT_DIR/docs-frontmatter-repo-selftest/verify.sh"
    # frontmatter の version が文書自身の Changelog 節の最大版エントリ（### [x.y.z]）
    # と一致することの検査（Issue #884）。docs-frontmatter-repo は構造（節の有無）
    # まで、roadmap-release-facts は ROADMAP のリリース表専用。**PLAYBOOK.md は
    # 対象外** — ACE 側ゲート（live-ace-gates が回す sync-playbook-frontmatter.ts
    # --check。先頭エントリ一致・最大版なしの別仕様）が検査するため、判定条件の
    # 異なる検査を同一文書へ重ねない。本 suite が埋める
    # のは PLAYBOOK.md 以外の docs 文書。対象は実体から導出（Frontmatter +
    # Changelog 節を持つ docs/**/*.md）。docs/ を持たない checkout では丸ごと ○ skip。
    "$SCRIPT_DIR/docs-version-changelog/verify.sh"
    # 上の gate の検出力を、実 docs/ を写した隔離 fixture への変異（frontmatter のみ
    # bump / エントリのみ追加 / version 欠落・重複・不正形式 / エントリ 0 件 / 不正
    # 見出し / FM 未閉鎖 / 読み取り失敗 / 対象 0 件）と正例（フェンス・コメント内の
    # 偽見出し無視 / 昇順 Changelog / PLAYBOOK 除外）で実測する（Issue #884）。
    "$SCRIPT_DIR/docs-version-changelog-selftest/verify.sh"
    # docs/ に手書きした件数・閾値と実体のドリフト検査。期待値はすべて実体から導出し、
    # 正準表現に 1 件も一致しなければ赤（抽出の空振りを緑にしない。Issue #519）。
    "$SCRIPT_DIR/docs-fact-drift/verify.sh"
    # 上の gate の検出力を、記載側 / 実体側の双方向の変異と対象外範囲（ACE 分割
    # ファイル・Changelog 節）で実測する（Issue #519）。
    "$SCRIPT_DIR/docs-fact-drift-selftest/verify.sh"
    # docs/ のリリース表と CHANGELOG 実体の照合。docs-fact-drift は数値 claim 専用で
    # 版番号を見ないため、版・日付の乖離と「いまここ」を指す現在値マーカー（腐る書き方）
    # をこちらで弾く（Issue #841）。
    "$SCRIPT_DIR/roadmap-release-facts/verify.sh"
    # 上の gate の検出力を、隔離 fixture への変異（日付ズレ・不在版・マーカー混入・
    # 書式変更による抽出空振り・CHANGELOG 欠落）で実測する（Issue #841）。
    "$SCRIPT_DIR/roadmap-release-facts-selftest/verify.sh"
    # docs-template の実行可能フェンスを抽出して fixture 実行する動的検査。
    # 一時作業領域を使うため静的検査の後、ネットワーク検査の前に置く。
    "$SCRIPT_DIR/docs-gates-runtime/verify.sh"
    # アダプタが CLI へ渡す argv の実測。一時ディレクトリと stub CLI を使うが
    # 実 CLI・ネットワーク・課金は伴わない（〜2 秒）。静的検査の後、ネットワーク
    # 検査の前に置く。
    "$SCRIPT_DIR/adapter-model-args/verify.sh"
    # アダプタが渡す sandbox 値が、その CLI が実際に受け付ける値かの契約検査
    # （Issue #403）。同じ argv 実測のクラスなので adapter-model-args の直後。
    # 層 1 は stub CLI のみ。層 2 だけは**実 CLI の `--help`** を読むが、これは
    # clap/yargs のヘルプ生成でローカル完結し、ネットワーク・課金・認証・エージェント
    # 実行のいずれも伴わない（CLI が PATH に無ければその照合だけ ○ skip）。
    # よってネットワーク検査より前のこの位置でよい（〜3 秒）。
    "$SCRIPT_DIR/adapter-sandbox-contract/verify.sh"
    # 同梱レビューラッパー（シム）の契約（Issue #406）: AI CLI を直接起動しない
    # こと（stdin の罠を構造的に持たないこと）と、オプション・env を黙って捨てない
    # こと、setup による配置が冪等であることを固定する。stub オーケストレータのみで
    # 完結し、実 CLI・ネットワーク・課金は伴わない（〜2 秒）。
    "$SCRIPT_DIR/review-wrapper-shim/verify.sh"
    # 主+副レビュワーの解決・保存・縮退。一時ディレクトリと git リポジトリを使うが
    # 実 CLI・ネットワーク・課金は伴わない。設定の保存先は XDG_CONFIG_HOME を
    # 一時ディレクトリへ向けて隔離するので、利用者の実設定には触れない。
    "$SCRIPT_DIR/reviewer-pair/verify.sh"
    # 実行環境分離ライブラリの検出力を、現consumer 9 suiteの名簿照合と隔離copyへの
    # mutation（run_isolated除去 / センチネル部分欠落 / probe内unset / シム素起動）で
    # 常設する（Issue #439）。一時領域のみ使い、実CLI・ネットワーク・課金は伴わない。
    "$SCRIPT_DIR/adapter-env-isolation-selftest/verify.sh"
    # fixture リポジトリの隔離初期化（tests/lib/git-fixture.sh）の回帰（Issue #1348 / #1368）:
    # GIT_DIR export 下や .git 不在の fixture で identity が呼び出し元の .git/config へ
    # 漏れないこと（fail-closed）と、user.name / user.email の設定が隔離ヘルパー
    # 経由であること（直書きは allowlist 以外拒否）。一時領域のみ使い、実 CLI・ネットワーク・課金は伴わない（〜1 秒）。
    "$SCRIPT_DIR/git-fixture-isolation/verify.sh"
    # 公開リポジトリへの実ネットワーク到達を試みる suite（接続不可のみ丸ごと
    # ○ skip、それ以外は fail）。静的検査より後、破壊的操作を伴う
    # merge-cleanup より前に置く。他の suite を network-dependent 化する場合も
    # この位置関係（静的 → ネットワーク → 破壊的操作 → 低速）を保つこと。
    # footer の比較リンクの実タグ追従（Issue #161）と、最新版節の path-like マーカーが
    # compare 範囲で実際に追加・変更されたかの限定検査（Issue #332 / ADR-020）を
    # 1 本にまとめた suite（Issue #1021 で changelog-links + changelog-attribution を統合）。
    # ネットワーク到達の判定は suite 内 1 箇所で、接続不可のみ丸ごと ○ skip。
    "$SCRIPT_DIR/changelog-public-tags/verify.sh"
    # 上の回帰検証（ローカル bare リポジトリ fixture のみ使用、実ネットワークには
    # 触らない）。本体の直後に置く。
    "$SCRIPT_DIR/changelog-public-tags-selftest/verify.sh"
    # 更新通知フック（hooks/check-update.sh）の回帰検証。ローカル bare リポジトリ
    # fixture のみ使用し、実ネットワークには触らない。
    "$SCRIPT_DIR/update-check/verify.sh"
    # GitHub / ローカル登録 / Desktop の3層検査。実ネットワークを使わない。
    "$SCRIPT_DIR/plugin-version-check/verify.sh"
    # スキル実体ドリフト検査（hooks/check-skill-drift.sh、Issue #656）。
    # リポジトリ skills/ とインストール実体の集合差分・ユニーク version 併存・検出不能
    # ・一致時無音（同一 version の cache+marketplace 含む）を fixture で固定し、
    # 差分検出を落とす変異と併存列挙を 1 件に潰す変異の検出力も同じ suite で実測する。
    # 実 ~/.claude には触れない。
    "$SCRIPT_DIR/skill-drift-check/verify.sh"
    # SSOT リポジトリの .claude/settings.json にある hook 起動コマンドのパス解決
    # （Issue #273）。settings.json が無いチェックアウト（公開リポジトリ等）では
    # ○ skip。一時ディレクトリ + stub hook のみ（〜2 秒）。
    "$SCRIPT_DIR/claude-hooks-path/verify.sh"
    # クラウド環境セットアップ: scripts/setup-cloud-env.sh の「導入不能でも
    # exit 0 / 1 行報告 / --dry-run は導入を実行しない」契約、tests/lib/utf8-locale.sh の
    # UTF-8 ロケール固定（run-all.sh / docs-gates / docs-gates-runtime の入口）、
    # scripts/probe-env-capabilities.sh のロケール行。apt-get / npm / curl は stub、gh の
    # 不在は絞った PATH で作る。root scripts/ を持たない配布先 checkout では ○ skip。
    "$SCRIPT_DIR/cloud-env-setup/verify.sh"
    # 公開リポジトリの Dependabot 健全性検知（Issue #472）。依存グラフ無効の再発と
    # 実在しない manifest パスに紐づく幽霊 alert を分けて捕捉する。検知スクリプト／
    # hook が無いチェックアウト（公開リポジトリ等）では ○ skip。gh はスタブへ
    # 差し替えるため実ネットワークには触らない。
    "$SCRIPT_DIR/public-dependabot-health/verify.sh"
    # 公開対象の禁止パターン検査（Issue #476）。同期スクリプトの --check-only
    # を使い、パターン配列は同期スクリプト側のまま再利用する。スクリプトや
    # 公開対象ディレクトリが無い checkout（公開リポジトリ等）では ○ skip。
    "$SCRIPT_DIR/sync-forbidden-patterns/verify.sh"
    # sync-dev-toolkit SKILL の「記録 SHA = 同期内容」契約の静的検査（Issue #634）。
    # skip の鍵は sync スクリプトの存在（sync-forbidden-patterns と同じ判定軸）:
    # 公開 checkout（スクリプト不在）は ○ skip、SSOT なのに SKILL 不在は red。
    # read-only・外部コマンド不要（〜1 秒）。sync 系ゲートの並びに置く。
    "$SCRIPT_DIR/sync-sha-contract/verify.sh"
    # 毎 sync リリース運用ゲート scripts/check-release-required.sh の検出力実測
    # （Issue #552）。live 状態は検査しない — 「実変更 + [Unreleased] 非空 + version
    # 据え置き」は開発中の PR では正常で、live 検査を常時ゲートに入れると通常開発が
    # 恒常的に赤くなる。疑似 SSOT + 疑似公開 clone の fixture のみ使い、実 CLI・
    # ネットワーク・課金は伴わない（〜3 秒）。同じ sync 系スクリプトを扱う
    # sync-forbidden-patterns の直後に置く。スクリプト不在の checkout・jq 不在・
    # 一時領域不可なら丸ごと ○ skip。
    "$SCRIPT_DIR/release-required-selftest/verify.sh"
    # 週次 CI 健全性判定 scripts/check-weekly-run-all-health.sh の挙動検査
    # （Issue #1086 / #1017 統合。ADR-045）。cron 生存と成功実績の分離・既定ブランチ上の
    # workflow_dispatch 成功の受理と非受理の境界・三値の exit 契約・緩和の逃げ道が無いこと
    # （負テスト）を、PATH 差し替えのモック gh で実測する。定期実行点ゲートの入口を守る
    # 検査なので、同じ定期実行点の契約を見る sync-sha-contract / release-required-selftest の
    # 並びに置く。実ネットワーク・実 CLI は伴わない（〜3 秒）。スクリプト不在の checkout・
    # jq 不在・一時領域不可なら丸ごと ○ skip。
    "$SCRIPT_DIR/weekly-health-contract/verify.sh"
    "$SCRIPT_DIR/merge-cleanup/verify.sh"
    # 既存の孤児トランスクリプト sweep（実 ~/.claude は触らず隔離 tmp のみ）。
    # merge-cleanup の Step 5.5 と同じアーカイブ思想の別口。直後に置く。
    "$SCRIPT_DIR/sweep-orphan-transcripts/verify.sh"
    # perspective フィルタの dry-run 契約。stub CLI の存在確認だけで完結し、
    # 実 CLI・ネットワーク・課金を伴わない。
    "$SCRIPT_DIR/multi-agent-plan/verify.sh"
    # 同一入力の成功済み観点を内容hash付きで再利用し、未完了だけを再実行する
    # --resume 契約（Issue #586）。9観点中8成功・1失敗、HEAD/設定/観点定義/集合変更、
    # 破損キャッシュ、統合レポートのreused/executedを逐次stub CLIで実測する。
    "$SCRIPT_DIR/multi-agent-resume/verify.sh"
    # 前回実行の観点ファイルが「今回の結果」として読まれないことの実挙動検査
    # （Issue #537 / #654）。プラン外 × orchestrator 自筆の結果を <cli>/previous/ へ
    # 退避し、利用者の .md・プラン外 CLI・非 .md・サブディレクトリには触れず名指しだけ
    # する、previous/ の symlink は追わずリンクを消す、<cli> が自分以外を指す symlink
    # （出力先の内外どちらでも）なら**何も書かず消さずに**中断する、を stub CLI の
    # 実走で固定する（部分 / 完全 resume の再利用分を自分で退避しないことを含む。
    # 一時 git リポジトリ + stub CLI で 9 回実走、単独で〜30 秒）。
    # resume と同じ「前回実行との関係」を扱うので直後に置く。
    # 環境都合で skip すると退避の検出力が丸ごと消えるため REQUIRED_SUITES に載せる。
    "$SCRIPT_DIR/multi-agent-stale-outputs/verify.sh"
    # 統合レポートの CRITICAL_BLOCK 判定の構造検査（Issue #272）と観点別段階化の
    # 契約検査（Issue #645）。一時 git リポジトリ + stub CLI で orchestrator を
    # ケースごとに実走する（1 ケース数秒）。実 CLI・ネットワーク・課金は伴わない。
    "$SCRIPT_DIR/multi-agent-critical-marker/verify.sh"
    # build_prompt の実行境界（再帰防止ガード）の回帰検査（Issue #263）。一時 git
    # リポジトリ + stub CLI（〜3 秒）。実 CLI・ネットワーク・課金は伴わない。
    "$SCRIPT_DIR/adapter-prompt-guard/verify.sh"
    # diff が実寸の ARG_MAX を超えても 4 アダプタが完走することの実測（Issue #1148 /
    # 公開 feel-flow/ff-dev-toolkit#55）。adapter-prompt-guard の受け渡し形検査は
    # 240KB fixture なので、報告された再現条件（ARG_MAX 超え）自体は跨がない。
    # 一時 git リポジトリ + stub CLI（〜3 秒）。実 CLI・ネットワーク・課金は伴わない。
    "$SCRIPT_DIR/adapter-argv-limit/verify.sh"
    # 呼び出し側のロケールに依存せずプロンプトが valid UTF-8 で CLI へ届くこと、
    # 不正な UTF-8 は CLI 起動前に fail-loud で止まること、再実行案内の引用が
    # ロケール非依存であることの回帰検査。一時 git リポジトリ + stub CLI（〜5 秒）。
    # 実 CLI・ネットワーク・課金は伴わない。
    "$SCRIPT_DIR/adapter-prompt-utf8/verify.sh"
    # auth / billing で落ちた CLI の残タスクを同一実行内でスキップする契約
    # （Issue #1143）。逐次ワーカー経路・--sequential 経路・fail-open の陰性対照を
    # stub CLI の起動回数で実測する。一時 git リポジトリ + stub CLI（〜10 秒）。
    # 実 CLI・ネットワーク・課金は伴わない。
    "$SCRIPT_DIR/multi-agent-skip-poisoned-cli/verify.sh"
    # レビュー本文を含まない捕捉結果の fail-loud 契約（Issue #893）: 受理条件
    # （正は scripts/adapters/adapter-common.sh の review_body_present ヘッダ —
    # ここに列挙を複製しない）の両方向 + アダプタ実走での INCOMPLETE 降格 +
    # 4 アダプタへのゲート常在の静的 pin + build_prompt の集約指示と perspective
    # 出力契約の一本化検査（review 限定）。一時 git リポジトリ + stub CLI
    # （〜3 秒）。実 CLI・ネットワーク・課金は伴わない。
    "$SCRIPT_DIR/review-capture-fail-loud/verify.sh"
    # 受理ゲートと集約 Critical 検出の積集合契約（Issue #908）: 同じ入力表を
    # 両側の公開入口（review_body_present / critical_findings_present — どちらも
    # adapter-common.sh の共有パーサー _ff_severity_scan へ委譲）に流し、
    # 「受理される全形式の Critical 指摘行で検出が発火する」を行ごとに固定 +
    # 委譲の静的 pin。一時領域のみ（〜2 秒）。実 CLI・ネットワーク・課金は伴わない。
    "$SCRIPT_DIR/severity-parser-intersection/verify.sh"
    # レビュー指摘の差分スコープ契約（Issue #556）: 全 review perspective のスコープ
    # 言及 + build_prompt(review) の [OUT-OF-DIFF] ラベル契約。一時 git リポジトリのみ
    # （〜2 秒）。実 CLI・ネットワーク・課金は伴わない。一時領域不可なら丸ごと ○ skip。
    "$SCRIPT_DIR/review-diff-scope/verify.sh"
    # base ブランチ解決の鮮度契約: ローカル base が remote-tracking ref の真の祖先
    # （= pull し忘れ）なら origin 側を採り、一致・先行・分岐ではローカルを維持する。
    # bare origin + clone の一時 git リポジトリのみ（〜2 秒）。実 CLI・ネットワーク・
    # 課金は伴わない。一時領域不可なら丸ごと ○ skip。
    "$SCRIPT_DIR/adapter-base-ref-freshness/verify.sh"
    # レビュー観点テンプレートの重大度スコープ契約（Issue #713 / #714）: 9 観点すべての
    # Severity Classification に「diff が導入または悪化させた」配置規則ブロックが同一
    # 本文で存在すること + test-analysis の Important 限定と Output Template の整合。
    # build_prompt は perspective を 1 本しか読まないため規則は各ファイル持ちで、drift を
    # この suite が縛る。純粋な静的検査で一時領域も git も要らず、skip 経路を持たない。
    "$SCRIPT_DIR/review-severity-scope/verify.sh"
    # レビュー実行中の作業ツリー凍結の契約（Issue #818）: オーケストレータ（親）が
    # 読解中のツリーを書き換えない規定を、git-workflow.md ステップ5 の節スコープと
    # 消費側 2 文書で固定する。機械検査の無いホストのサブエージェント経路では手順書の
    # 文言だけが防御になるため、文言の消失を回帰として扱う。純粋な静的検査で一時領域も
    # git も要らず、skip 経路を持たない（部分 skip をマーカーで出さないため独立 suite）。
    "$SCRIPT_DIR/review-freeze-contract/verify.sh"
    # toolkit 変更 PR でレビュー基盤が旧実装（インストール済み実体から読み込んだ場合）で
    # 動く制約の明示と、worktree 実装への切替オプトを実装しない設計判断
    # （Issue #915 / ADR-043）: multi-review/SKILL.md の制約・担保（変更対象に対応する
    # suite の worktree 実走）の文言針 + ADR-043 決定文との相互照合 + scripts/ に
    # オプトのフラグ（use[-_]worktree[-_]scripts 族）が現れない実体 pin。純粋な静的
    # 検査で一時領域も git も要らず、suite-level の skip 経路を持たない（repository
    # docs/ の無い配布先 checkout では ADR 照合だけをインデント付き部分 skip にする）。
    "$SCRIPT_DIR/review-worktree-scripts-decision/verify.sh"
    # 長時間タスク委譲のこまめコミット契約（Issue #913）: 正本
    # multi-cli-agent-orchestration.md の契約節（こまめ commit + push・フェーズ分割・
    # ストール再開時のコミット確認）を節スコープで固定し、消費側 multi-implement の
    # 参照リンクも見る。文言だけが防御の文書契約なので、消失を回帰として扱う。
    # 純粋な静的検査で一時領域も git も要らず、skip 経路を持たない。
    "$SCRIPT_DIR/long-task-commit-contract/verify.sh"
    # worktree 委譲の依存プリフライト契約（Issue #1444）: 正本
    # multi-cli-agent-orchestration.md の契約節（委譲プロンプトへの常置・コマンドを実値で
    # 書く・対象はゲートを回す委譲すべて・lockfile 変更時の入れ直し）を節スコープで固定し、
    # 消費側 multi-implement / 配布 git-workflow の参照と、貼り付け定型文がコマンドの実値を
    # 保っていること（リンクへ退化していないこと）も見る。文言だけが防御の文書契約。
    # 純粋な静的検査で一時領域も git も要らず、skip 経路を持たない。
    "$SCRIPT_DIR/worktree-preflight-contract/verify.sh"
    # 委譲先の完了後に残る background 子プロセスの回収契約: 正本
    # multi-cli-agent-orchestration.md の契約節（完了報告を受けたら確認・探し方は内容では
    # なく経過時間・待機ループに限定しない・子孫ごと段階的に回収・稼働中の子は落とさない）を
    # 節スコープで固定し、検出コマンドの 4 要素（経過時間 / ps でホスト PID / marker /
    # 自分自身の除外）を個別に見る。どれか 1 つが消えると「動くが効かない」状態になるため。
    # フェンス内のコマンドは bash -n まで掛ける（読者が貼って初めて壊れに気付く形を避ける）。
    # 文言だけが防御の文書契約。純粋な静的検査で一時領域も git も要らず、skip 経路を持たない。
    "$SCRIPT_DIR/background-child-reclaim-contract/verify.sh"
    # flat-rate CLI への観点集中の制御（Issue #251、#783 で free-tier から付替）: プラン警告 + minimize_cost 限定の
    # 同一 CLI 内逐次化 + standard の並列維持 + 途中失敗の継続。一時 git リポジトリ +
    # stub CLI で orchestrator を 4 回実走（単独実測 約 20 秒。詳細は suite README。
    # standard の逐次化変異は期限付きバリアで検出）。実 CLI・ネットワーク・課金は伴わない。
    "$SCRIPT_DIR/multi-agent-serialization/verify.sh"
    # 実行中にレビュー対象（HEAD / ブランチ / 作業ツリー）が動いたときに結果を黙って
    # 返さないこと（公開 Issue #11）。diff の固定と前後のリビジョン検証を、一時 git
    # リポジトリ + stub CLI で実走して確かめる。ミューテーション 5 件つき（詳細は
    # suite README）。実 CLI・ネットワーク・課金は伴わない。
    "$SCRIPT_DIR/multi-agent-revision-guard/verify.sh"
    # リビジョンガードのツリー変化判定パス除外（Issue #747）: FF_MULTI_AGENT_IGNORE_PATHS
    # と既定 .superpowers/** の除外が効くこと・除外の外は従来どおり破棄すること・
    # 空/空白パターンの fail-closed。一時 git リポジトリ + stub CLI で実走し、
    # ミューテーション 2 件つき。実 CLI・ネットワーク・課金は伴わない。
    "$SCRIPT_DIR/multi-agent-ignore-paths/verify.sh"
    # review タスク起動時の「完了まで worktree を触らない」バナー: 並列でも
    # --sequential でもタスク実行前に 1 回だけ・起動時 HEAD の short-sha 付きで
    # stderr へ出ること（stdout には出ないこと）、explore では出ないこと。一時 git
    # リポジトリ + stub CLI で実走し、ミューテーション 1 件つき。実 CLI・ネット
    # ワーク・課金は伴わない。破棄ロジック自体は multi-agent-revision-guard の
    # 担当で、ここでは触れない。
    "$SCRIPT_DIR/multi-agent-review-banner/verify.sh"
    # 同梱 MCP サーバーの実検査 4 本。node_modules が無い環境ではいずれも ○ skip
    # （型検査の 2 本は node が PATH に無い環境でも ○ skip。tsc の shebang が node を
    # 要求するため、環境都合の失敗を型エラーと混ぜないための分岐）。
    # dist-gate（フレッシュビルド比較 + stdio-only 不変条件、〜1 秒）を先に、
    # vitest（実プロセス起動を含む全テスト、〜5 秒）を後に置く — dist が stale
    # なら先に dist-gate が名指しし、vitest の「stale な dist で green」を防ぐ。
    # dist_state / tree_state の共通 fail-closed 実装を mutation で、2 本の dist_state
    # wrapper の byte 一致を静的比較で常設検証する（Issue #386、〜1 秒）。
    "$SCRIPT_DIR/mcp-state-selftest/verify.sh"
    "$SCRIPT_DIR/mcp-dist-gate/verify.sh"
    # 型検査（Issue #360）。vitest も esbuild build も transpile のみで型を見ないため、
    # 型エラーは下の mcp-vitest では検出できない。vitest より前に置くのは
    # mcp-dist-gate → mcp-vitest と同じ理由 — 型が壊れているファイルのテストが偶然
    # 通った状態を「緑」として報告させないため。install 済みで tsc だけ無い場合は
    # fail-closed（単体で〜1 秒）。
    "$SCRIPT_DIR/mcp-typecheck/verify.sh"
    # 上の gate の検出力を隔離クローンへの mutation で実測する（単体で〜5 秒。tsc の
    # lib 解析が cold の初回はさらに伸びる。数字を更新するときは実測してから直すこと）。
    # node_modules は symlink で借りるだけで、実物への書き込みは行わない。検査対象の
    # 直後に置くことを優先し、安価な順の例外として扱う。
    "$SCRIPT_DIR/mcp-typecheck-selftest/verify.sh"
    "$SCRIPT_DIR/mcp-vitest/verify.sh"
    # docs 走査マスクの awk 版（tests/lib/docs-scan.sh）と TS 版（mcp/src/utils.ts）の
    # 出力を共有 fixture で機械照合する（Issue #528）。TS 側は mcp/node_modules の
    # esbuild で一時領域へ束ねて走らせるため、同じ依存を借りる mcp 系の並びに置く。
    # node / node_modules / 一時領域が無ければ ○ skip（単体で〜1 秒）。
    "$SCRIPT_DIR/docs-scan-mirror/verify.sh"
    # docs-template/scripts/ace の型検査（Issue #358）。vitest は esbuild の transpile
    # のみで型を見ないため、型エラーは下の ace-scripts-vitest では検出できない。
    # vitest より前に置くのは mcp-dist-gate → mcp-vitest と同じ理由 — 型が壊れている
    # ファイルのテストが偶然通った状態を「緑」として報告させないため。
    # node_modules 不在なら ○ skip、install 済みで tsc だけ無い場合は fail-closed。
    "$SCRIPT_DIR/ace-scripts-typecheck/verify.sh"
    # 上の gate の検出力を隔離クローンへの mutation で実測する（単体で〜9 秒。tsc の lib
    # 解析が cold の初回はさらに伸びる。数字を更新するときは実測してから直すこと）。
    # node_modules は symlink で借りるだけで、実物への書き込みは行わない。検査対象の
    # 直後に置くことを優先し、安価な順の例外として扱う。
    # skip 条件は上の gate と同じ node_modules 不在に加えて perl 不在・一時領域不可
    # （tsc だけ無い場合はこちらも fail-closed）。
    "$SCRIPT_DIR/ace-scripts-typecheck-selftest/verify.sh"
    # ace-refine 契約のうち、同梱シードの旧形式 0 件は
    # check-entry-format の機械可読 CLI へ委譲する（Issue #336）。
    # mcp/node_modules の esbuild を借りるため、同じ依存を使う typecheck / vitest 群に置く。
    "$SCRIPT_DIR/ace-refine/verify.sh"
    # repository root の live docs/08-knowledge に形式・frontmatter の 2 ゲートを適用する。
    # live docs 不在は適用外として ○ skip、存在するのに依存や入力が欠ける場合は fail-closed。
    # 直後の selftest は隔離 fixture への旧形式 / count drift mutation と不在境界を実測する。
    "$SCRIPT_DIR/live-ace-gates/verify.sh"
    "$SCRIPT_DIR/live-ace-gates-selftest/verify.sh"
    # docs-template/scripts/ace の vitest（Playbook 集計スクリプト群 + refine 候補算出）。
    # vitest 本体は mcp/node_modules を再利用するため mcp 系 suite より後に置く
    # （上の型検査 2 本と ace-refine も同じ node_modules を借りるので、この 4 本が同じ並びに入る）。
    "$SCRIPT_DIR/ace-scripts-vitest/verify.sh"
    # 同梱ゲートの runner 解決層（scripts/ace-run-ts.sh）の挙動検査（Issue #879）。
    # bash と一時領域だけで完結し、npx・ネットワークに依存しない。下の
    # ace-curate-fallback-exec と分けてあるのは、あちらの tsx 取得失敗で丸ごと skip
    # されると「runner が無い環境で fail-closed するか」がその環境でだけ消えるため。
    "$SCRIPT_DIR/ace-run-ts/verify.sh"
    # /ace-curate 4-f の未導入 fallback を、scripts/ace/ を持たない一時プロジェクトで
    # 実際に走らせる挙動検査（Issue #614）。SKILL.md が案内する `npx --yes tsx <同梱パス>`
    # をそのまま使うため tsx の取得（初回のみネットワーク。以降は npm cache）に依存し、
    # 4 回の npx 起動で単体〜20 秒かかる。node / npx / 一時領域が無い、または tsx を
    # 解決できない環境では丸ごと ○ skip する。
    "$SCRIPT_DIR/ace-curate-fallback-exec/verify.sh"
    # 一時 git リポジトリ + stub CLI を使い、打ち切りや猶予期間の実測待ちを含むので
    # 後ろに置く（単体で〜35 秒。数字を更新するときは実測してから直すこと）
    "$SCRIPT_DIR/multi-agent-timeout/verify.sh"
    "$SCRIPT_DIR/run-all/verify.sh"
  )
fi

# ── 環境都合で消えてはいけない suite の名簿 ──────────────────────────────────
# skip 契約（部分 skip 禁止・行頭 ○ skip・ランナーは pass と別に数える）は正しいが、
# **強制する主体が居ない**。このリポジトリに CI は無く、run-all.sh が非 0 になるのは
# 「pass が 0 件」のときだけなので、yq や node_modules が無いマシンでは該当 suite が
# 丸ごと skip され、それでも全体は緑になる（実測。Issue #274 / #372）。
#
# ここは **fail-closed を既定**にする。「環境都合の skip を許容する」という既存の
# 設計思想とは正面から衝突するが、衝突しているのは *許容するかどうか* ではなく
# *誰が許容を宣言するか*。黙って消えるのをやめ、**環境側が明示的に宣言**する形にする。
#
# 回せない環境では、理由を添えて明示的に外す:
#   FF_RUN_ALL_ALLOW_SKIP="markdownlint markdownlint-selftest" bash tests/run-all.sh
#   FF_RUN_ALL_ALLOW_SKIP=all   # 全部許す（旧来の挙動。1 行の警告つき）
# **対の本体 suite を持つ `-selftest` をここへ載せても、既定（高速モード）では
# fail-closed 保護は働かない**（ADR-034）。除外された suite は SKIPPED に現れず、下の
# 必須 skip 判定は SKIPPED だけを走査するため。保護が効くのは全件実行（FF_RUN_ALL_FULL=1）
# のときだけで、既定実行では「除外した selftest のうち何件が必須名簿掲載か」をサマリーが
# 名指しする（意図した除外であることは変わらないが、重みが読めるようにする）。
REQUIRED_SUITES=(
  # 緩めた本文差分述語（チェックボックス + ff-effort ブロックだけを許可）の behavioral
  # 検証を持つ唯一の suite。jq 不在で丸ごと skip されると、安全ゲートが本当に
  # マーカー外の編集を弾くかを誰も見なくなる（Issue #1136）。
  effort-contract
  # root契約のnegative controlは一時領域を使う。skipすると旧版誤選択を拒否する
  # 検出力が丸ごと消えるため、明示許可なしのskipを認めない（Issue #838）。
  plugin-root-contract
  # 一時領域を使わない read-only の静的検査（依存: awk・grep・sed・dirname）で
  # skip 経路を持たないが、references 参照の実在は他のどの suite も見ておらず、
  # 将来 skip 経路が生えても黙って消えてはならない検出力なので名簿に載せて宣言する
  # （Issue #889）。
  skill-references-existence
  # 実行環境分離のselftestは、クリーン環境だと退行してもconsumerが緑になり得る。
  # 一時領域不足で検出力ごと消える場合は明示許可を要求する（Issue #439）。
  adapter-env-isolation-selftest
  # yq（Mike Farah v4）が要る。agent-config.yaml の構造検査（単一ドキュメント性・
  # 全 map 横断の重複キー）と「畳んだ対応表が復活していないこと」を見るのはこの suite
  # だけで、yq 不在で丸ごと skip すると代替する検査が無い（Issue #1227。旧
  # agent-config-mirror の掲載を引き継ぐ）。
  cli-registry-completeness
  # mcp/node_modules が無いと repository Markdown lint の検証イベントが消える（#295）
  markdownlint
  markdownlint-selftest
  # shellcheck（外部バイナリ）が要る。抑制ディレクティブの構文エラーは「そのファイルの
  # 静的検査が静かに止まる」形で、他のどの suite も見ていない。黙って skip すると
  # ゲートを入れた意味が丸ごと消えるので明示許可を要求する（Issue #530）。
  # 未導入環境では FF_RUN_ALL_ALLOW_SKIP=shellcheck が要る（brew/apt で導入可）。
  shellcheck
  # mcp/node_modules が要る。型検査ゲート 2 系統ぶんがここに乗っている（#372）
  mcp-dist-gate
  mcp-vitest
  # node + mcp/node_modules が要る。awk 版 / TS 版のマスクが乖離していないことは
  # 他のどの suite も見ておらず、skip すると「2 回起きた片側ドリフト」の検出力が
  # 丸ごと消える（Issue #528）
  docs-scan-mirror
  mcp-typecheck
  mcp-typecheck-selftest
  ace-scripts-typecheck
  ace-scripts-typecheck-selftest
  ace-refine
  # live docs 不在は正当な適用外なので本体は必須にしない。検出力 selftest は代替がなく、
  # 環境都合で消える場合に明示許可を要求する（Issue #441）。
  live-ace-gates-selftest
  # mktemp fixture が要る。収録スキル数ゲートの検出力 selftest は代替がなく、
  # 一時領域不足で消えると count-rot の検出力喪失が黙って通る（Issue #502）。
  skill-count-consistency-selftest
  # mktemp fixture が要る。列挙型 description の drift ゲートの検出力 selftest は
  # 代替がなく、一時領域不足で消えると「片側だけ更新した description」を緑で通す
  # 退行が黙って戻る（Issue #1004）。
  plugin-description-enumeration-selftest
  ace-scripts-vitest
  # node / npx / tsx 解決（初回はネットワーク）が要る。ace-curate-commit は案内パスの
  # 文字列と同梱スクリプトの実在までは見るが、**そのパスで実際に走って exit 0 になるか**を
  # 確かめるのはこの suite だけ。黙って消えると、スクリプトが壊れて未導入プロジェクトの
  # 必須ゲートが再び到達不能になっても緑のままになる（Issue #614）。
  ace-curate-fallback-exec
  # runner 解決層の検出力には代替が無い。一時領域不足で消えると、workspace 環境の
  # 到達不能・runner 不在の fail-closed・終了コード伝播が丸ごと無検査になる（Issue #879）。
  ace-run-ts
  # ミラー検出器・tree-state helper・runner 自身の検出力にも代替がない。
  ace-scripts-mirror-selftest
  mcp-state-selftest
  run-all
  # 一時領域が無いと、以下が単独で守る実行時契約が丸ごと消える。単体 suite は
  # 環境都合を ○ skip として区別するが、run-all では明示許可なしの skip を通さない
  # （Issue #436 / #440）。「TMPDIR 書込不可でも全体を緑」は目標にしない。
  setup-multi-agent-yq
  docs-gates-runtime
  adapter-model-args
  adapter-sandbox-contract
  # build_prompt の実行境界（再帰防止・staging 出力境界・出力モードの排他）と、
  # レビュー指摘の差分スコープ契約。どちらも他の suite が見ていない実行時契約を
  # 単独で守っており、一時領域が無いと丸ごと消える（Issue #564）。公開 checkout でも
  # 実体は同梱されるため、skip 条件は一時領域の有無だけ = 公開側の
  # FF_RUN_ALL_ALLOW_SKIP 案内に追加は要らない。
  adapter-prompt-guard
  # ARG_MAX 超えの diff でレビューが完走することを見るのはこの suite だけで、
  # 一時領域不足で skip すると「大きい PR ほどレビューされない」退行（公開
  # feel-flow/ff-dev-toolkit#55 の実測形）が黙って戻る。skip 条件は 3 つ — 一時領域の
  # 有無、getconf ARG_MAX が数値を答えるか、その値が fixture 上限（16MB）に収まるか。
  adapter-argv-limit
  # プロンプトのロケール非依存性（非 UTF-8 ロケールでも valid UTF-8 で届く / 不正な
  # バイトは CLI 起動前に止まる）を見るのはこの suite だけで、消えると「日本語
  # Windows の既定環境でレビューが 1 件も出ない」退行が黙って戻る。skip 条件は
  # 一時領域の有無と、UTF-8 妥当性を判定する iconv の有無の 2 つ。
  # iconv 未導入環境では FF_RUN_ALL_ALLOW_SKIP=adapter-prompt-utf8 が要る
  # （glibc / macOS には同梱。最小コンテナでは apk add gnu-libiconv 等で導入可）。
  adapter-prompt-utf8
  # close-issue の merge コマンド生成がロケール非依存であることを見るのはこの suite
  # だけで、消えると「日本語の PR 件名・本文で貼って実行する手順が壊れる」退行が
  # 黙って戻る。skip 条件は一時領域の有無だけ（iconv 不在は該当検査だけを名指しで
  # skip し、round-trip と形の pin は残す）。
  close-issue-shell-quote
  # 「確実に失敗すると分かっている実行に時間を払わない」契約はこの suite だけが
  # 見ており、一時領域不足で skip すると、観点数ぶんの無駄な待ち時間の再発と、
  # スキップを通常の失敗として案内する退行が黙って戻る（Issue #1143）。
  multi-agent-skip-poisoned-cli
  review-diff-scope
  # base 解決が「古くないほうの ref」を採る契約はこの suite だけが見ており、一時領域
  # 不足で消えると、stale なローカル base 経由で他ブランチの差分がレビュー対象へ混入
  # する退行が黙って戻る。skip 条件は一時領域の有無だけ。
  adapter-base-ref-freshness
  # レビュー本文を含まない捕捉結果を complete にしない fail-loud 契約（Issue #893）。
  # 判定関数・4 アダプタのゲート常在・INCOMPLETE 降格はこの suite しか見ておらず、
  # 一時領域が無い環境で mktemp skip すると「空振り結果が完了として並ぶ」退行が
  # 黙って通る。skip 条件は adapter-prompt-guard と同じく一時領域の有無だけ。
  review-capture-fail-loud
  # 受理ゲートと集約 Critical 検出が同一の行分類を参照することの積集合契約
  # （Issue #908）。片側だけが独自実装へ戻る drift はこの suite しか行単位で
  # 見ておらず、一時領域不足で mktemp skip すると「受理される Critical 指摘行を
  # 集約が素通りする」fail-open の再発が黙って通る。
  severity-parser-intersection
  # 一時領域 + git が要る。マージ直前の鮮度ゲートの検出力（不一致で止まる / 一致で
  # 黙る / 判定不能を素通りさせない）を見るのはこの suite だけで、消えるとゲートの
  # 退行が squash merge に畳み込まれる形で表に出る（Issue #880）。
  merge-freshness
  # 手順書の凍結契約は、機械検査の無いサブエージェント経路で唯一の防御（Issue #818）。
  # この suite は静的検査だけで skip 経路を持たないが、掲載は空振りではない —
  # check_suite_registration が名簿の各名の実在を検査するため、この 1 行が
  # ディレクトリ名の改名・削除を今日すでに pin している。加えて将来 skip 経路が
  # 入ったときに「環境都合で契約検査が消えた」を黙って通さない。
  review-freeze-contract
  # toolkit 変更 PR の制約明示と worktree 実行オプト不採用（Issue #915 / ADR-043）も
  # 文言だけが防御（オプト不在の実体 pin を含む）。review-freeze-contract と同じ理由で
  # 名簿に載せ、suite の改名・削除と将来の skip 経路を黙って通さない。
  review-worktree-scripts-decision
  # テンプレート本体の重大度スコープ契約（Issue #713 / #714）も文言だけが防御 —
  # 注入層の [OUT-OF-DIFF] 契約（review-diff-scope）はテンプレートの severity 定義まで
  # 見ない。静的検査で skip 経路を持たないが、review-freeze-contract と同じ理由で
  # 名簿に載せ、suite の改名・削除と将来の skip 経路を黙って通さない。
  review-severity-scope
  # 長時間タスク委譲の「こまめコミット」契約（Issue #913）も文言だけが防御。
  # review-freeze-contract と同じ理由で名簿に載せ、suite の改名・削除と将来の
  # skip 経路を黙って通さない。
  long-task-commit-contract
  # worktree 委譲の依存プリフライト契約（Issue #1444）も文言だけが防御。委譲プロンプトへ
  # 常置する文言が消えると、対策は文書に在るのに委譲先へ届かない状態（OBS-013 が 5 回
  # 再発した状態）へ戻る。同じ理由で名簿に載せ、改名・削除と将来の skip 経路を通さない。
  worktree-preflight-contract
  # 委譲先の完了後に残る background 子プロセスの回収契約も文言だけが防御。検出コマンドが
  # 消えると、エージェントの子プロセスが何時間も走り続ける状態（OBS-112 が 3 回再発した
  # 状態）へ戻る。同じ理由で名簿に載せ、改名・削除と将来の skip 経路を通さない。
  background-child-reclaim-contract
  review-wrapper-shim
  sweep-orphan-transcripts
  multi-agent-timeout
  # 実行中のリビジョン変化を検出する契約は、この suite 以外どこも守っていない。
  multi-agent-revision-guard
  # そのガードのパス除外（FF_MULTI_AGENT_IGNORE_PATHS / 既定 .superpowers/**）の
  # 契約も、この suite 以外どこも守っていない（除外が緩むと監視が黙って縮む側、
  # 効かないと正常な実行が毎回破棄される側の両方）。
  multi-agent-ignore-paths
  # 前回結果の退避契約（Issue #537 / #654）。他の suite は「今回のプランの結果が
  # 揃うか」しか見ないため、退避が丸ごと外れても緑のまま通る。加えて、この suite だけが
  # 「<cli> が外向き symlink のとき外部を消さない・書かない」を実測する（#722 で残りを
  # 塞ぐまでの唯一の実行時検査）。一時領域不足で消える場合は明示許可を要求する。
  multi-agent-stale-outputs
  # out-of-scope 契約ゲート（routing / decision）の検出力 selftest。代替の検査が
  # 無く、perl・一時領域の都合で消える場合は明示許可を要求する（#499）。
  out-of-scope-routing-selftest
  # 公開 CHANGELOG 参照ゲートの検出力 selftest。本体は実 CHANGELOG が clean な限り
  # 緑のままなので、検出パターンが弱っても本体だけでは分からない。perl・一時領域の
  # 都合で消えると「参照検出の退行が黙って通る」状態になる（Issue #610）。
  changelog-contract-selftest
  # 一時領域 + git fixture が無いと、通常 PR が共有 CHANGELOG を編集しないことで
  # 競合を除去する契約と materialize の冪等性が丸ごと未検証になる（Issue #764）。
  changelog-fragments
  # 一時領域 + bare remote + 2 clone が無いと、fresh read だけでは閉じない同時採番を
  # non-fast-forward 後の再生成で収束させる検出力が丸ごと消える（Issue #764）。
  shared-version-convergence
  # /retrospective 契約ゲートの検出力 selftest。代替の検査が無く、perl・一時領域の
  # 都合で消えるとチェーン記載の針と規定マーカーの検出力喪失が黙って通る（#540）。
  retrospective-contract-selftest
  # 自動振り返りのランタイム検出力は mutation self-test 以外に代替がない（#583）。
  retrospective-stop-hook-selftest
  # スキル実体ドリフト検査は、この suite 以外に代替がない。一時領域不足で消えると
  # 未登録スキル / 古い cache 併存の検出が黙って通る（Issue #656）。
  skill-drift-check
  # docs-template 構造契約ゲートの検出力 selftest。代替の検査が無く、perl・
  # 一時領域の都合で消えると Frontmatter 欠落回帰の検出力喪失が黙って通る（#509）。
  docs-template-frontmatter-selftest
  # /validate-docs §4 プレースホルダー免除ゲートの検出力 selftest。代替の検査が
  # 無く、perl・一時領域の都合で消えるとフェンス / コメント境界の退行が黙って通る
  # （#518）。
  validate-docs-placeholders-selftest
  # 自リポジトリ docs/ の Frontmatter 規則ゲートと件数ドリフトゲートの検出力 selftest。
  # 代替の検査が無く、perl・jq・一時領域の都合で消えると「規則と実体の drift を
  # 検出できない状態」が黙って通る（#513 / #519）。
  #
  # **公開 checkout では root に docs/ が無いため両方 ○ skip する。** fixture は
  # 「実リポジトリの docs/ をそのまま写す」設計で、baseline が実体と乖離しないことを
  # 優先している（同梱 fixture にすると baseline 自体が腐る）。したがって公開側では
  # sync-forbidden-patterns / release-required-selftest / weekly-health-contract /
  # docs-version-changelog（とその selftest）、root script を持たない changelog-fragments と
  # 合わせて 8 件の明示許可が要る:
  #   FF_RUN_ALL_FULL=1 FF_RUN_ALL_ALLOW_SKIP="sync-forbidden-patterns release-required-selftest changelog-fragments \
  #     weekly-health-contract docs-frontmatter-repo-selftest docs-fact-drift-selftest \
  #     docs-version-changelog docs-version-changelog-selftest" bash tests/run-all.sh
  # 必須 skip で落ちたときは、この行と同じ内容をランナーが実際の skip 一覧から
  # 組み立てて表示する（下の REQUIRED_SKIPPED の案内）。
  #
  # **既定（高速モード）では docs-frontmatter-repo-selftest / docs-fact-drift-selftest は
  # 除外される**（対の本体 suite が実在するため）。除外は SKIPPED に現れないので明示許可も
  # 要らないが、**検証もされない**。上の 8 件を明示許可で通す形が成立するのは全件実行のとき
  # だけで、既定では組み立てられるのも残り 5 件になる（ADR-034）。
  docs-frontmatter-repo-selftest
  docs-fact-drift-selftest
  # frontmatter version ↔ 自 Changelog 最大版の一致は、PLAYBOOK.md（ACE 側ゲートが
  # 先頭一致の別仕様で検査）以外では他のどのゲートも見ていない（Issue #884）。外部コマンド不要で、
  # skip 経路は「docs/ を持たない checkout」だけ。名簿に載せるのは、SSOT 側で docs/ の
  # パス変更などにより suite が黙って適用外へ落ちる事故を fail-closed にするため。
  # docs/ を持たない公開 checkout では sync-forbidden-patterns と同様に
  # FF_RUN_ALL_ALLOW_SKIP=docs-version-changelog の明示許可が要る
  # （既定実行でも走る本体 suite なので、全件実行に限らない）。
  docs-version-changelog
  # 上の gate の検出力 selftest。fixture は実 docs/ を写す設計（baseline を腐らせない）
  # なので docs-frontmatter-repo-selftest と同様、公開 checkout では ○ skip し
  # 全件実行時に明示許可が要る。既定（高速モード）では対の本体があるため除外される。
  docs-version-changelog-selftest
  # ROADMAP のリリース表ゲートの検出力 selftest（#841）。一時領域が作れないと
  # ○ skip する経路を持ち、本ゲートの検出力を測る手段は他に無い。上の 2 件と違い
  # fixture は自前で組む（実 docs/ を写さない）ので、**公開 checkout でも走る**
  # — 明示許可が要るのは一時領域を作れない環境だけ。
  roadmap-release-facts-selftest
  # 公開対象の禁止パターン検査。同期時以外に発火するゲートが他に無い（#476）。
  # 公開 checkout はスクリプト不在で ○ skip、一時領域不足でも ○ skip する。
  # そちらでは FF_RUN_ALL_ALLOW_SKIP=sync-forbidden-patterns が要る。
  sync-forbidden-patterns
  # 毎 sync リリース運用ゲートの検出力 selftest（#552）。代替の検査が無く、
  # 消えると「リリース漏れ・CHANGELOG 記載漏れを sync 前に止める」検出力の喪失が
  # 黙って通る。公開 checkout は root スクリプト不在で ○ skip するため、そちらでは
  # FF_RUN_ALL_ALLOW_SKIP=release-required-selftest が要る（上の 8 件の列挙参照）。
  release-required-selftest
  # 週次 CI 健全性判定の挙動検査（#1086 / #1017）。定期実行点ゲートが高速モードを
  # 受理してよいかの入口そのもので、判定を緩める変異（既定ブランチ外の受理・cron 異常の
  # 握り潰し・判定不能の healthy への転落）を測る手段は他に無い。公開 checkout は root
  # スクリプト不在で ○ skip するため、そちらでは
  # FF_RUN_ALL_ALLOW_SKIP=weekly-health-contract が要る（上の 8 件の列挙参照）。
  weekly-health-contract
)

# 渡された verify.sh を走査し、1 行 1 suite で `<名前>:<skip>:<yes>:<no>:<bad>` を返す。
#
# `<skip>` は **suite 全体の** skip 経路の有無。ランナーの実行時判定（出力の列 0 に
# `○ skip` が現れた行）と同じ境界を静的側でも取る:
#   - 出力文（`echo` / `printf`）が、**開き引用符の直後**＝出力行の列 0 に `○ skip` を
#     置く形。引用符の種別は問わない（`"○ skip` / `'○ skip` / printf の書式文字列）。
#     ここを二重引用符だけに絞ると、単一引用符や printf で skip を出す suite が導出から
#     落ち、名簿に載っていなくても緑のまま通る（静的側だけが緩い非対称になる）。
#   - heredoc 本文で列 0 から `○ skip` を出す形（引用符を伴わない行頭一致）。
#   - **出力文でない行は拾わない** — アサートや期待値照合の中の `"○ skip"` は skip 経路
#     ではないので、それを材料にすると必須へ誤って引き上げる。
#   - インデント付きの部分 skip（`"  ○ skip`）も拾わない — 部分 skip しか持たない suite を
#     「環境都合で丸ごと消えうる」と誤って必須へ引き上げないため。
#
# `<yes>` / `<no>` は宣言コメントの有無で、両方 1 なら矛盾。`<bad>` は `run-all-required:`
# を名乗りながら理由（yes / no の直後の非空白）を欠く宣言の有無。理由なしの `no` を素通り
# させると、判断の記録なしに必須から外れてしまう。
#
# ファイルごとに awk を起動する形は suite 数ぶんのプロセス生成で実測 3 秒近く伸びた
# （run-all は毎回この照合を通る）。FILENAME を使った 1 パスにまとめる。
suite_declaration_scan() {
  awk '
    function emit() {
      if (name != "") { printf "%s:%d:%d:%d:%d\n", name, skip, yes, no, bad }
    }
    FNR == 1 {
      emit()
      path = FILENAME
      sub(/\/verify\.sh$/, "", path)
      sub(/^.*\//, "", path)
      name = path
      skip = 0; yes = 0; no = 0; bad = 0
    }
    # 宣言は「yes / no + 理由」で 1 つの形。理由を欠く宣言は読み飛ばさず bad で印を付ける。
    /^[[:space:]]*#[[:space:]]*run-all-required:/ {
      decl = $0
      sub(/^[[:space:]]*#[[:space:]]*run-all-required:[[:space:]]*/, "", decl)
      if (decl ~ /^yes[[:space:]]+[^[:space:]]/) { yes = 1 }
      else if (decl ~ /^no[[:space:]]+[^[:space:]]/) { no = 1 }
      else { bad = 1 }
      next
    }
    /^[[:space:]]*#/ { next }
    # heredoc 本文（引用符を伴わず列 0 から始まる skip 行）
    /^○ skip/ { skip = 1; next }
    # 出力文が、開き引用符の直後＝出力行の列 0 に `○ skip` を置く形（引用符種別を問わない）
    /(^|[^[:alnum:]_.-])(echo|printf)([[:space:]]|$)/ {
      if (index($0, "\"○ skip") || index($0, "'\''○ skip")) { skip = 1 }
    }
    END { emit() }
  ' "$@"
}

# ── 既定 suite 一覧の登録漏れ検査 ──────────────────────────────────────────────
# SCRIPTS 配列は手で維持されており、**一覧から 1 行消しても誰も気づかない**。
# 消した suite は走らず、残り全部が緑のまま「All ... passed」を出す。
# 自己テスト（tests/run-all/verify.sh）は擬似 suite を明示引数で渡してランナーの集計を
# 検査する作りなので、既定の配列を一度も読まない — つまり登録の正しさは規律だけで
# 保たれていた。ここで実体（tests/<name>/verify.sh）と突き合わせる。
#
# 走査は tests/ の直下 1 階層だけ。run-all 自身の fixture は tests/run-all/fixtures/
# の下にあり、この深さには現れないので誤検出しない。
#
# ── 必須名簿の逆向き導出 ─────────────────────────────────────────────────────
# 上の 2 つの照合はどちらも「名簿に書かれた名前が実在するか」の向きしか見ない。
# **REQUIRED_SUITES から 1 行消しても、その suite は走り続けるので全体は緑のまま**で、
# 消えたのは「環境都合の skip を赤にする保護」だけ — 最も気づきにくい形で検出力が減る。
# そこで実体側から「必須であるべき suite」を導出し、名簿と双方向で突き合わせる。
#
# 導出規則（実体 = tests/<name>/verify.sh を読む）:
#   必須 = { suite 全体の skip 経路を持つ } ∪ { yes 宣言 } − { no 宣言 }
#
#   - **suite 全体の skip 経路**: 出力文（echo / printf / heredoc 本文）が出力行の列 0 へ
#     `○ skip` を置く形。引用符の種別は問わず、インデント付きの部分 skip とアサート行の
#     文字列は含めない（ランナー自身の集計と同じ境界。詳細は suite_declaration_scan）。
#     suite ごと消えうる = 環境都合で検証が丸ごと落ちうる、が必須判定の既定の材料。
#   - **宣言コメント**: verify.sh の任意のコメント行に置く。**理由は必須**（理由なしの
#     宣言は赤。判断の記録なしに必須から外れる形を残さない）
#       # run-all-required: yes — <理由>   … skip 経路が無くても名簿へ載せる
#       # run-all-required: no  — <理由>   … skip 経路はあるが環境都合の skip を許容する
#     判断そのもの（代替の検査があるか／その skip で何が消えるか）は導出できないので、
#     **判断は suite 側に宣言として置き、名簿はその集約**という関係にする。skip 経路の
#     隣に宣言があるので、skip を足す人・外す人の目に入る位置に判断が残る。
#
# この形は「新しく skip 経路を足した suite は既定で必須」= fail-closed でもある。
# 名簿にも宣言にも無い skip 経路は赤になり、追加者に yes / no の明示を要求する。
check_suite_registration() {
  local disk_names=() registered=() missing=() name script
  for script in "$SCRIPT_DIR"/*/verify.sh; do
    [[ -f "$script" ]] || continue
    disk_names+=("$(basename "$(dirname "$script")")")
  done
  # 既定一覧そのものを読む（別配列に写すと写し忘れで乖離する）。この関数は
  # 既定一覧で走るときにしか呼ばれないので SCRIPTS が既定一覧に等しい。
  for script in "${SCRIPTS[@]}"; do
    registered+=("$(basename "$(dirname "$script")")")
  done
  # 走査が空なら「漏れなし」ではなく「検査が成立していない」
  if [[ "${#disk_names[@]}" -eq 0 ]]; then
    echo "✗ tests/ 直下に verify.sh が 1 件も見つかりません（登録検査が成立していません）" >&2
    return 1
  fi
  local d r found
  for d in "${disk_names[@]}"; do
    found=0
    for r in "${registered[@]}"; do
      [[ "$d" == "$r" ]] && { found=1; break; }
    done
    [[ "$found" -eq 1 ]] || missing+=("$d")
  done
  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "✗ run-all.sh の既定 suite 一覧に未登録の suite があります:" >&2
    printf '    %s\n' "${missing[@]}" >&2
    echo "  tests/<name>/verify.sh を追加したら SCRIPTS 配列にも 1 行足してください。" >&2
    echo "  他の追随先（REQUIRED_SUITES 宣言・docs の suite 数・npm ci 一覧など）は docs/04-quality/TESTING.md §新規 suite 追加の随伴先 を参照してください。" >&2
    return 1
  fi
  # 名簿に実在しない suite 名が残ると、その行は永久に何も守らない（改名・削除に
  # 追従できていない状態）。登録検査のついでに実在を確かめる。
  local req unknown=()
  for req in "${REQUIRED_SUITES[@]}"; do
    found=0
    for d in "${disk_names[@]}"; do
      [[ "$req" == "$d" ]] && { found=1; break; }
    done
    [[ "$found" -eq 1 ]] || unknown+=("$req")
  done
  if [[ "${#unknown[@]}" -gt 0 ]]; then
    echo "✗ REQUIRED_SUITES に実在しない suite 名があります:" >&2
    printf '    %s\n' "${unknown[@]}" >&2
    echo "  改名・削除に追従できていません（その行は何も守っていません）。" >&2
    return 1
  fi
  # ── 逆向き導出: 実体から必須集合を組み立て、名簿と双方向で突き合わせる ──────
  # 走査は awk 1 プロセス。**終了コードを捨てない** — BSD awk は開けないファイルを警告
  # して次へ進み最後に非 0 を返すので、`for entry in $(...)` の形だと 1 本だけ読めない
  # verify.sh がその suite を黙って導出から落とす（名簿にも無ければ緑のまま）。
  local entry sname flags scan_out derived=() conflicts=() dead_optout=() malformed=()
  if ! scan_out="$(suite_declaration_scan "$SCRIPT_DIR"/*/verify.sh)"; then
    echo "✗ verify.sh の走査が失敗しました（読めない verify.sh がある可能性。逆向き照合が成立していません）" >&2
    return 1
  fi
  for entry in $scan_out; do
    sname="${entry%%:*}"
    flags="${entry#*:}"
    case "$flags" in
      *:1)
        # 理由を欠く run-all-required 宣言（yes / no の判定より前に落とす）
        malformed+=("$sname")
        continue
        ;;
    esac
    flags="${flags%:*}"
    case "$flags" in
      *:1:1)
        conflicts+=("$sname")
        ;;
      1:*:0)
        # skip 経路がある（yes 宣言の有無に関わらず必須）
        derived+=("$sname")
        ;;
      1:*:1)
        # skip 経路はあるが no 宣言で明示的に許容されている
        ;;
      0:1:0)
        derived+=("$sname")
        ;;
      0:0:1)
        # skip 経路が無いのに no 宣言だけが残っている = 何も許可していない死んだ宣言。
        # 「その行は何も守っていない」を上の unknown 検査と同じ理由で赤にする。
        dead_optout+=("$sname")
        ;;
    esac
  done
  if [[ "${#malformed[@]}" -gt 0 ]]; then
    echo "✗ 理由の無い run-all-required 宣言があります:" >&2
    printf '    %s\n' "${malformed[@]}" >&2
    echo "  '# run-all-required: yes — 理由' / '# run-all-required: no — 理由' の形で理由を書いてください（理由なしの no は判断の記録なしに必須から外れます）。" >&2
    return 1
  fi
  if [[ "${#conflicts[@]}" -gt 0 ]]; then
    echo "✗ run-all-required の yes / no を同時に宣言している suite があります:" >&2
    printf '    %s\n' "${conflicts[@]}" >&2
    echo "  どちらか一方だけを残してください（必須名簿への昇格判断は 1 つに決まります）。" >&2
    return 1
  fi
  if [[ "${#dead_optout[@]}" -gt 0 ]]; then
    echo "✗ suite 全体の skip 経路が無いのに run-all-required: no が残っています:" >&2
    printf '    %s\n' "${dead_optout[@]}" >&2
    echo "  許可する対象の skip が消えています（その宣言は何も守っていません）。宣言を削除するか、必須なら yes へ変えて REQUIRED_SUITES へ載せてください。" >&2
    return 1
  fi
  # 導出が空なら「必須なし」ではなく「逆向き照合が成立していない」（skip 経路の
  # 検出そのものが壊れた形。走査が空のときと同じ理由で fail-closed にする）。
  if [[ "${#derived[@]}" -eq 0 ]]; then
    echo "✗ 実体から必須 suite を 1 件も導出できませんでした（逆向き照合が成立していません）" >&2
    return 1
  fi
  local unlisted=() unbacked=()
  for d in "${derived[@]}"; do
    found=0
    for req in "${REQUIRED_SUITES[@]}"; do
      [[ "$d" == "$req" ]] && { found=1; break; }
    done
    [[ "$found" -eq 1 ]] || unlisted+=("$d")
  done
  if [[ "${#unlisted[@]}" -gt 0 ]]; then
    echo "✗ REQUIRED_SUITES に載っていない必須 suite があります:" >&2
    printf '    %s\n' "${unlisted[@]}" >&2
    echo "  suite 全体の skip 経路を持つ suite と 'run-all-required: yes' を宣言した suite は必須です。名簿へ 1 行足すか、環境都合の skip を許容するなら verify.sh へ '# run-all-required: no — 理由' を書いてください（yes 宣言側は宣言の削除でも解けます）。" >&2
    echo "  他の追随先（docs の suite 数・npm ci 一覧など）は docs/04-quality/TESTING.md §新規 suite 追加の随伴先 を参照してください。" >&2
    return 1
  fi
  for req in "${REQUIRED_SUITES[@]}"; do
    found=0
    for d in "${derived[@]}"; do
      [[ "$req" == "$d" ]] && { found=1; break; }
    done
    [[ "$found" -eq 1 ]] || unbacked+=("$req")
  done
  if [[ "${#unbacked[@]}" -gt 0 ]]; then
    echo "✗ REQUIRED_SUITES の掲載に実体側の根拠がない suite 名があります:" >&2
    printf '    %s\n' "${unbacked[@]}" >&2
    echo "  suite 全体の skip 経路も yes 宣言も無い（または no 宣言と同居しています）。skip 経路が無いまま名簿へ残すなら verify.sh へ '# run-all-required: yes — 理由' を書いてください。" >&2
    return 1
  fi
  echo "ℹ️  既定 suite 一覧の登録漏れなし（実体 ${#disk_names[@]} 件 / 必須 ${#REQUIRED_SUITES[@]} 件 — 実体からの導出と一致）"
  return 0
}

# --dump-declarations: 実体から読んだ導出材料（`<名前>:<skip>:<yes>:<no>:<bad>`）を
# そのまま出して終わる。tests/run-all/verify.sh は既定一覧の統合検査（case 26）のために
# 実在 suite を写した複製木を作るが、そこで判定述語を書き写すと「述語を変えるときは
# 2 箇所同時」の結合が生まれ、片方だけ直すと複製木の導出集合がずれて原因の読めない赤に
# なる。導出述語の単一定義を保つため、材料はランナー自身に出させる。
if [[ "${FF_RUN_ALL_DUMP_DECLARATIONS:-0}" == "1" ]]; then
  suite_declaration_scan "$SCRIPT_DIR"/*/verify.sh || exit 1
  exit 0
fi

# --check-registration: 登録照合だけを行って終わる。全 suite を走らせずに
# この検査だけを回せるようにしておく（自己テストから安価に叩くため）。
if [[ "${FF_RUN_ALL_CHECK_REGISTRATION:-0}" == "1" ]]; then
  if [[ "$USING_DEFAULT_SCRIPTS" != "1" ]]; then
    echo "✗ FF_RUN_ALL_CHECK_REGISTRATION は既定一覧に対してのみ意味を持ちます（引数なしで実行してください）" >&2
    exit 2
  fi
  check_suite_registration
  exit $?
fi

# ── 作業ツリーの汚れで既定一覧の起動を止める（fail-closed）───────────────────
# 既定一覧の実行は「このコミットを実測した」という記録（scripts/record-gate-head.sh）を
# 残すためのゲートである。未コミットの編集が残った木で回した結果は**どのコミットに対する
# 実測でもない**ので、記録は `DIRTY=yes` で書かれ、マージ直前の鮮度照合は「判定不能」に
# なる。つまり数分〜十数分かけた実行がまるごと証拠にならない。記録側は実行の**後**に
# しか汚れを知らせないため、無駄が確定してから分かる — その無駄を起動時点で止める。
#
# 散文の規定（docs-template の git-workflow「重い検証ゲートは fix commit へ束ねてから
# 1 回だけ回す」「新規ファイルを追加した回は commit してからゲートを回す」）は既に在るが、
# 発動しない規定は無い規定と同じで、規定の追加後も同型の再発が観測台帳に積まれ続けた。
#
# **判定は記録側と同じ述語で行う**（`git status --porcelain` の stdout が非空 = 汚れ。
# 未追跡ファイルも数える）。ガードと記録で述語がずれると「ガードは通ったのに DIRTY=yes」
# という、いちばん避けたい形が残る。stderr を畳み込まないのも記録側と同じ理由で、
# clean な木でも git が警告を出す環境（submodule の rmdir 警告など。いずれも exit 0）を
# 汚れと誤診断させない。
#
# 対象は**引数なしの既定一覧だけ**。明示引数の実行は元から `partial` として記録されて
# 全件緑へ昇格しないうえ、名指しの部分実行はレビュー対応中の正当な用途である
# （tests/run-all/verify.sh が疑似 suite を渡す口もここに含まれる）。
#
# 置き場所は「suite を 1 つも実行せず、記録も書かない」ことが構造的に成り立つ位置 —
# 登録照合より前で、かつ suite を走らせない検査専用モード（宣言ダンプ・登録照合のみ）の
# 早期 exit より後。検査専用モードは実行も記録もしないので、汚れた木で止める理由が無い。
# `FF_GATE_RECORD=0`（記録を止める指定。後述）の回にもこのガードは掛ける — 記録の
# 有無に関わらず、汚れた木での全件実行はレビュー規定違反で証拠にならない。記録を
# 捨てる試し実行は下の `FF_RUN_ALL_ALLOW_DIRTY=1` を明示すること。
#
# このガードが「起動時点で clean だった」と断定できた回だけ 1 を立てる。終了時の再評価
# （後述）はこの旗が立った回にしか意味を持たない — 起動時から汚れていた回（オプトアウト）で
# 「走行中に汚れた」と言うと嘘になる。
STARTED_CLEAN=0
ALLOW_DIRTY=0
case "${FF_RUN_ALL_ALLOW_DIRTY:-}" in
  1) ALLOW_DIRTY=1 ;;
  ""|0) ;;
  *)
    echo "⚠️  FF_RUN_ALL_ALLOW_DIRTY=\"${FF_RUN_ALL_ALLOW_DIRTY}\" は解釈できない値です（オプトアウトになるのは 1 のときだけ）。fail-closed 側のガード有効で続行します" >&2
    ;;
esac

if [[ "$USING_DEFAULT_SCRIPTS" == "1" && "$ALLOW_DIRTY" != "1" ]]; then
  # 汚れの判定は**このランナーが在るリポジトリ**へ掛ける（記録側の基準と同じ。呼び出し元の
  # cwd を基準にすると、別リポジトリから起動した回に無関係な木の状態で自分の実行を止める）。
  DIRTY_RC=0
  DIRTY_OUT="$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null)" || DIRTY_RC=$?
  if [[ "$DIRTY_RC" -ne 0 ]]; then
    # 失敗した回だけ理由を取りにもう一度呼ぶ（成功経路に余計な実行を足さない）。
    DIRTY_ERR="$(git -C "$SCRIPT_DIR" status --porcelain 2>&1 >/dev/null || true)"
    echo "✗ 作業ツリーが clean かどうかを確認できません（git が無い、またはリポジトリの外）" >&2
    [[ -z "$DIRTY_ERR" ]] || printf '%s\n' "$DIRTY_ERR" | sed 's/^/    /' >&2
    echo "  確認できない木での実行は、鮮度記録が何を実測したのかを言えません。clean と断定せずに停止します。" >&2
    echo "  意図した実行なら FF_RUN_ALL_ALLOW_DIRTY=1 を付けて再実行してください（記録は判定不能になります）。" >&2
    exit 1
  fi
  if [[ -n "$DIRTY_OUT" ]]; then
    echo "✗ 未コミットの変更がある作業ツリーでは既定一覧のゲートを実行しません（suite は 1 つも実行していません）" >&2
    # 一覧は先頭 20 行で打ち切る。数百件の未追跡ファイルで案内文が流れると、
    # 「なぜ止まったか」より「何が汚れているか」の羅列だけが残る。
    printf '%s\n' "$DIRTY_OUT" | sed -n '1,20p' | sed 's/^/    /' >&2
    DIRTY_N="$(printf '%s\n' "$DIRTY_OUT" | sed -n '$=')"
    if [[ "${DIRTY_N:-0}" -gt 20 ]]; then
      echo "    … 他 $(( DIRTY_N - 20 )) 件" >&2
    fi
    echo "  汚れた木で測った結果はどのコミットに対する実測でもなく、鮮度記録は DIRTY=yes で書かれます（マージ直前の照合は「判定不能」）。" >&2
    echo "  変更をコミットしてから再実行してください。" >&2
    echo "  記録を捨ててよい試し実行なら FF_RUN_ALL_ALLOW_DIRTY=1 を付けて再実行できます。" >&2
    exit 1
  fi
  STARTED_CLEAN=1
fi

# 既定一覧で走らせるときだけ照合する（明示引数の実行は部分実行が正当な用途）。
if [[ "$USING_DEFAULT_SCRIPTS" == "1" ]]; then
  check_suite_registration || exit 1
fi

# ── 実行モードの解決（既定は高速モード。ADR-034）──────────────────────────────
# `-selftest` サフィックスを持ち、かつ対になる本体 suite が実在する suite を実行対象から
# 除外する（背景・トレードオフはヘッダー参照）。登録漏れ検査（check_suite_registration）は
# 既定一覧そのものへ掛ける必要があるため、この除外は照合の**後**に行う。除外した suite は
# SKIPPED に一切現れないので、REQUIRED_SUITES の必須 skip 判定（SKIPPED だけを走査する）
# とは構造的に競合しない。
FAST_MODE=1
FAST_EXCLUDED=()
FAST_KEPT_SELFTEST=()

# 値の解釈は両変数とも「1 との完全一致でのみ有効」。`0` と空値は **quiet**（警告を出さない）で、
# それ以外の非空値（`true` / `2` など）だけ「利用者の意図と挙動の乖離」として 1 行警告し、
# 挙動を fail-safe 側（全 suite 実行）へ倒す。
#
# ※ **quiet であることと「既定へ落ちる」ことは別軸**。FF_RUN_ALL_FAST=0 は quiet だが全件実行を
#    能動的に選ぶし、FF_RUN_ALL_FULL=0 は quiet で既定（高速モード）のままになる。
#
# 状態は 3 つに分ける。「不正値だから全件へ倒した」を「FF_RUN_ALL_FULL=1 の明示」と同じ変数へ
# 畳むと、矛盾警告が利用者の設定していない `FULL=1` を事実として述べてしまう。
FULL_EXPLICIT=0        # FF_RUN_ALL_FULL=1 の明示。矛盾警告の発火条件にだけ使う
FAST_EXPLICIT=0        # FF_RUN_ALL_FAST=1 の明示。明示引数への除外適用の可否にも使う
FULL_RUN_REQUESTED=0   # 全件実行の要求。入口は上の 2 変数の値ごとに複数ある
case "${FF_RUN_ALL_FULL:-}" in
  1) FULL_EXPLICIT=1; FULL_RUN_REQUESTED=1 ;;
  ""|0) ;;
  *)
    echo "⚠️  FF_RUN_ALL_FULL=\"${FF_RUN_ALL_FULL}\" は解釈できない値です（全件実行になるのは 1 のときだけ）。fail-safe 側の全 suite 実行で続行します" >&2
    FULL_RUN_REQUESTED=1
    ;;
esac

# FF_RUN_ALL_FAST は既定反転（ADR-034）後も後方互換の入口として残す。`0` は「明示的に高速
# モードでない」= 全件実行として扱う（空値と等価に扱わない理由はヘッダー）。
case "${FF_RUN_ALL_FAST:-}" in
  1) FAST_EXPLICIT=1 ;;
  "") ;;
  0) FULL_RUN_REQUESTED=1 ;;
  *)
    echo "⚠️  FF_RUN_ALL_FAST=\"${FF_RUN_ALL_FAST}\" は解釈できない値です（高速モードになるのは 1 のときだけ）。fail-safe 側の全 suite 実行で続行します" >&2
    FULL_RUN_REQUESTED=1
    ;;
esac

# 矛盾する指定は黙って一方を採らない。挙動は fail-safe 側（全 suite 実行）。
# **両方が明示的な `1` のときだけ**鳴らす — 不正値経由で立った全件要求をここで拾うと、
# 利用者が書いていない `FULL=1` を事実として述べる警告になる。
if [[ "$FULL_EXPLICIT" == "1" && "$FAST_EXPLICIT" == "1" ]]; then
  echo "⚠️  FF_RUN_ALL_FULL=1 と FF_RUN_ALL_FAST=1 が同時に指定されています（矛盾）。fail-safe 側の全 suite 実行を採ります" >&2
fi
if [[ "$FULL_RUN_REQUESTED" == "1" ]]; then
  FAST_MODE=0
fi

# 明示引数は「名指ししたものを走らせる」を既定にする（ADR-034）。FF_RUN_ALL_FAST=1 を
# **明示**したときだけ、従来どおり明示引数にも除外を適用する — その口が「除外で実行対象が
# 0 件 → exit 1」の fail-closed 経路を実測する唯一の手段だから（理由はヘッダー）。
if [[ "$USING_DEFAULT_SCRIPTS" != "1" && "$FAST_EXPLICIT" != "1" ]]; then
  FAST_MODE=0
fi

if [[ "$FAST_MODE" == "1" ]]; then
  FAST_KEPT=()
  for script in "${SCRIPTS[@]}"; do
    suite_dir="$(dirname "$script")"
    name="$(basename "$suite_dir")"
    if [[ "$name" == *-selftest ]]; then
      # 対になる本体 suite が実在するときだけ除外する。対が無い `-selftest` は live な
      # 検査を単独で担っており、除外するとその検査対象が無検査で通る（ADR-031）。
      if [[ -f "$(dirname "$suite_dir")/${name%-selftest}/verify.sh" ]]; then
        FAST_EXCLUDED+=("$name")
        continue
      fi
      FAST_KEPT_SELFTEST+=("$name")
    fi
    FAST_KEPT+=("$script")
  done
  # 名指しした suite が黙って消えるのを防ぐ。明示引数への除外適用は FF_RUN_ALL_FAST=1 を
  # 明示したときだけ（ADR-034。理由はヘッダー）なので、ここへ来るのは「除外を要求しつつ
  # 除外対象を名指しした」回に限られる。矛盾はここで 1 行だけ報告する。**0 件判定より前に出す** — 名指しが
  # 全件除外された回はこの警告が最も要る場面なのに、後段へ置くと直前の exit 1 で到達せず、
  # API.md の「名指しした suite が除外されたときは stderr へ 1 行警告する」（この分岐へ
  # 入ったら 0 件判定の有無に関わらず必ず出す契約）
  # を破る。
  if [[ ${#FAST_EXCLUDED[@]} -gt 0 && "$USING_DEFAULT_SCRIPTS" != "1" ]]; then
    echo "⚠️  明示引数で名指しした suite のうち ${#FAST_EXCLUDED[@]} 件を高速モードが除外しました（名指しの意図と矛盾。実行するには FF_RUN_ALL_FAST を外すか、外せない場合は FF_RUN_ALL_FAST=0 か FF_RUN_ALL_FULL=1 を与えてください）: ${FAST_EXCLUDED[*]}" >&2
  fi
  # 除外で実行対象が 0 件になったら成功として扱わない（検査 0 件を緑にしない）
  if [[ ${#FAST_KEPT[@]} -eq 0 ]]; then
    echo "✗ 高速モードの除外で実行対象が 0 件になりました（selftest ${#FAST_EXCLUDED[@]} 件を除外）。検査 0 件を成功として記録しません" >&2
    exit 1
  fi
  SCRIPTS=("${FAST_KEPT[@]}")
  if [[ ${#FAST_EXCLUDED[@]} -gt 0 ]]; then
    echo "⚡ 高速モード: selftest ${#FAST_EXCLUDED[@]} 件を実行対象から除外します（内訳はサマリー。全件実行は FF_RUN_ALL_FULL=1）"
    echo
  fi
fi

# 全件実行であることを肯定的に 1 行で出す。「⚡ が出ていない」ことでしか全件を判別できないと、
# 週次 CI や定期実行点の全件代替（ADR-037 / ADR-039）を実施したという報告が目視頼みになる。
# 明示引数の実行も FAST_MODE=0 だが「全件」ではないので、既定一覧に限って出す。
if [[ "$USING_DEFAULT_SCRIPTS" == "1" && "$FAST_MODE" == "0" ]]; then
  echo "🔎 全件実行: 登録されている ${#SCRIPTS[@]} suite をすべて実行対象にします（高速モードの除外なし）"
  echo
fi

PASSED=()
FAILED=()
SKIPPED=()
NOT_RUN=()
CHECKS_SKIPPED_TOTAL=0
CHECKS_SKIPPED=()

# ── 実行経路の共有部（Issue #595）────────────────────────────────────────────
# 「何を走らせ、どう数えるか」は逐次・並列で 1 か所へ集約する。並列化で変わるのは
# 起動のタイミングだけで、集計・skip 判定・終了コードの意味は同じコードを通す。
# suite 本文は $FF_SUITE_OUTPUT で渡す（引数に載せると skip-large のような 64KB 超の
# 出力を呼び出しのたびに複製することになる）。
FF_SUITE_OUTPUT=""

ff_suite_kind() { # <script> -> run|missing|notexec
  if [[ ! -f "$1" ]]; then
    printf 'missing\n'
  elif [[ ! -x "$1" ]]; then
    printf 'notexec\n'
  else
    printf 'run\n'
  fi
}

ff_consume() { # <name> <kind: run|missing|notexec|gone> <script> <rc>。本文は $FF_SUITE_OUTPUT
  local name="$1" kind="$2" script="$3" suite_rc="$4"
  local checks_skipped

  echo "== $name =="

  # 起動できない suite は「未実行」として記録し、実行は続ける（ここで exit すると
  # 裏口から fail-fast が戻る）。最後に非 0 終了へ寄与させることで fail-closed を保つ。
  if [[ "$kind" == "missing" ]]; then
    echo "✗ verify script is missing: $script" >&2
    NOT_RUN+=("$name (missing)")
    echo
    return 0
  fi
  if [[ "$kind" == "notexec" ]]; then
    echo "✗ verify script is not executable: $script" >&2
    NOT_RUN+=("$name (not executable)")
    echo
    return 0
  fi
  # 並列実行の子が終了コードを残さずに消えた場合（kill -9・OOM など）。pass にも
  # fail にも倒さず「未実行」として数える — 走ったかどうかが分からない実行を
  # 成功側へ寄せないのが本ランナーの fail-closed の要（Issue #146）。
  if [[ "$kind" == "gone" ]]; then
    echo "✗ suite プロセスが終了コードを残さずに消えました: $script" >&2
    NOT_RUN+=("$name (process gone)")
    echo
    return 0
  fi
  # 並列実行の spool を読み出せなかった場合（一時領域の枯渇・削除など）。ここで
  # ランナーごと落とすと**残りの suite が未起動のまま消える** = 裏口からの fail-fast に
  # なるので、当該 suite だけを未実行として記録し、実行は続ける。
  if [[ "$kind" == "unreadable" ]]; then
    echo "✗ suite の出力・終了コードを spool から読み出せませんでした: $script" >&2
    NOT_RUN+=("$name (spool unreadable)")
    echo
    return 0
  fi

  printf '%s\n' "$FF_SUITE_OUTPUT"

  # インデント付き `○ skip` は、suite 内の一部検査だけを環境都合で飛ばしたマーカー。
  # 行頭マーカー（suite 全体の skip）とは別勘定にし、終了コードや REQUIRED_SUITES の
  # fail-closed 判定を変えない。awk は入力を最後まで読むため、大量出力でも grep -q の
  # SIGPIPE 反転を持ち込まない。
  checks_skipped="$(printf '%s\n' "$FF_SUITE_OUTPUT" \
    | awk '/^[[:space:]]+○ skip(:|$)/ { n++ } END { print n + 0 }')"
  if [[ "$checks_skipped" -gt 0 ]]; then
    CHECKS_SKIPPED_TOTAL=$((CHECKS_SKIPPED_TOTAL + checks_skipped))
    CHECKS_SKIPPED+=("${name}=${checks_skipped}")
  fi

  if [[ "$suite_rc" -eq 0 ]]; then
    # 判定はシェル内の文字列マッチで行い、パイプを使わない。`printf | grep -q` だと
    # grep がマッチ時点で終了して上流の printf が SIGPIPE (141) で死に、pipefail の
    # もとでパイプライン全体が失敗扱いになる = マッチが「不一致」へ反転する。出力が
    # パイプ容量（64KB 程度）を超える suite で skip が pass に化ける fail-silent で、
    # 本 Issue が潰そうとしている masking と同じ種類の事故になる。
    # 左辺に改行を前置するのは、1 行目の `○ skip` も行頭マッチさせるため。
    if [[ $'\n'"$FF_SUITE_OUTPUT" == *$'\n○ skip'* ]]; then
      SKIPPED+=("$name")
    else
      PASSED+=("$name")
    fi
  else
    FAILED+=("$name")
  fi
  echo
}

# 逐次実行。一時領域を要求しない経路で、read-only 環境の退避先でもある。
ff_run_sequential() {
  local script name kind suite_rc
  for script in "${SCRIPTS[@]}"; do
    name="$(basename "$(dirname "$script")")"
    kind="$(ff_suite_kind "$script")"
    FF_SUITE_OUTPUT=""
    suite_rc=0
    if [[ "$kind" == "run" ]]; then
      # 出力を変数へ受けるのは skip マーカー判定のため。command substitution は
      # パイプで完結し一時ファイルを作らないので read-only 環境でも動く。判定後に
      # そのまま全量を出力するので、診断情報は失敗時も成功時も欠けない。
      if FF_SUITE_OUTPUT="$(bash "$script" 2>&1)"; then
        suite_rc=0
      else
        suite_rc=$?
      fi
    fi
    ff_consume "$name" "$kind" "$script" "$suite_rc"
  done
}

# 並列実行。${SPOOL}（mktemp -d 済み）を要求する。
ff_run_parallel() {
  local total="${#SCRIPTS[@]}"
  local i next_launch=0 next_print=0 running=0 suite_rc
  # 配列名の DONE / PIDS を避けるのは shellcheck 対策。`DONE[$i]=1` が文頭に来ると
  # `done` キーワードの大文字違い（SC1081）+ `[` の前のスペース欠落（SC1069）と読まれる。
  local -a SUITE_KIND SUITE_PID SUITE_DONE

  for ((i = 0; i < total; i++)); do
    SUITE_KIND[$i]="$(ff_suite_kind "${SCRIPTS[$i]}")"
    SUITE_PID[$i]=0
    SUITE_DONE[$i]=0
  done

  while [[ "$next_print" -lt "$total" ]]; do
    # 空きスロットへ登録順に投入する
    while [[ "$next_launch" -lt "$total" && "$running" -lt "$JOBS" ]]; do
      i="$next_launch"
      next_launch=$((next_launch + 1))
      if [[ "${SUITE_KIND[$i]}" != "run" ]]; then
        SUITE_DONE[$i]=1
        continue
      fi
      # 出力はファイルへ落とし、終了コードは**本文を書き終えた後に** rename で置く。
      # 「rc ファイルの実在 = その suite の出力が完成している」を、親が追加の同期
      # なしに読めるようにするため（部分的に書かれた出力を完成品として読まない）。
      (
        set +e
        bash "${SCRIPTS[$i]}" >"$SPOOL/$i.out" 2>&1
        printf '%s\n' "$?" >"$SPOOL/$i.rc.part"
        mv -f "$SPOOL/$i.rc.part" "$SPOOL/$i.rc"
      ) &
      SUITE_PID[$i]=$!
      running=$((running + 1))
    done

    # 完了を回収してスロットを空ける
    for ((i = next_print; i < next_launch; i++)); do
      [[ "${SUITE_DONE[$i]}" == "0" ]] || continue
      if [[ -f "$SPOOL/$i.rc" ]]; then
        SUITE_DONE[$i]=1
        running=$((running - 1))
        continue
      fi
      # rc を残さず子が消えた実行を「未実行」へ倒す。判定は必ず
      # 「rc 不在 → pid 消滅 → なお rc 不在」の順で行う — 先に pid を見ると、
      # rename 直後に終了した子（正常完了）を gone と取り違える。
      if ! kill -0 "${SUITE_PID[$i]}" 2>/dev/null && [[ ! -f "$SPOOL/$i.rc" ]]; then
        SUITE_KIND[$i]=gone
        SUITE_DONE[$i]=1
        running=$((running - 1))
      fi
    done

    # 出力は完了順ではなく**登録順**に、suite 単位でまとめて出す。完了順に出すと
    # 同じ suite 一覧でも実行のたびに並びが変わり、前回との差分が読めなくなる。
    while [[ "$next_print" -lt "$next_launch" ]] && [[ "${SUITE_DONE[$next_print]}" == "1" ]]; do
      i="$next_print"
      next_print=$((next_print + 1))
      FF_SUITE_OUTPUT=""
      suite_rc=0
      if [[ "${SUITE_KIND[$i]}" == "run" ]]; then
        # 読み出しの失敗で set -e に落ちない。落ちるとサマリーも出ないまま
        # 残りの suite が未起動で消える（ff_consume の unreadable 分岐の理由）。
        if suite_rc="$(cat "$SPOOL/$i.rc" 2>/dev/null)" \
          && FF_SUITE_OUTPUT="$(cat "$SPOOL/$i.out" 2>/dev/null)"; then
          rm -f "$SPOOL/$i.out" "$SPOOL/$i.rc" 2>/dev/null || true
        else
          SUITE_KIND[$i]=unreadable
          suite_rc=0
          FF_SUITE_OUTPUT=""
        fi
      fi
      ff_consume "$(basename "$(dirname "${SCRIPTS[$i]}")")" "${SUITE_KIND[$i]}" "${SCRIPTS[$i]}" "$suite_rc"
    done

    if [[ "$next_print" -lt "$total" ]]; then
      # 投入すべき suite が残っておらず、先頭 suite だけが未完了の局面では、
      # ポーリングではなくその子を直接 wait する。登録順にしか出力できない以上
      # ここで待つのは無駄にならず、**PID 再利用で kill -0 が生き続ける形**も
      # ここで解ける（wait は自分の子でない PID には即座に返るため、戻った時点で
      # rc が無ければ gone と確定してよい）。
      #
      # 残余リスク: 投入待ちが残っている局面（next_launch < total）で子が rc を
      # 残さず死に、かつその PID が別プロセスへ再利用されると、スロットが空かず
      # ポーリングが続く。この場合ランナーはサマリー行を出さないので
      # 「サマリー行が出ていない実行は緑ではない」（docs/04-quality/TESTING.md）で
      # fail-closed に落ちる — 偽の緑にはならない。
      if [[ "$next_launch" -ge "$total" ]] \
        && [[ "${SUITE_DONE[$next_print]}" == "0" ]] \
        && [[ "${SUITE_KIND[$next_print]}" == "run" ]]; then
        wait "${SUITE_PID[$next_print]}" 2>/dev/null || true
        if [[ ! -f "$SPOOL/$next_print.rc" ]]; then
          SUITE_KIND[$next_print]=gone
          SUITE_DONE[$next_print]=1
          running=$((running - 1))
        fi
      else
        sleep "$FF_POLL_INTERVAL"
      fi
    fi
  done

  wait 2>/dev/null || true

  # 正常完了時だけ後片付けする（EXIT トラップを置かない理由は spool 確保側のコメント）。
  if [[ -n "$SPOOL" ]]; then
    rm -rf "$SPOOL"
    SPOOL=""
  fi
}

# ── 同時実行数と実行経路の解決（Issue #595）──────────────────────────────────
FF_POLL_INTERVAL=0.1
if ! sleep "$FF_POLL_INTERVAL" 2>/dev/null; then
  # 小数秒を受けない sleep（POSIX 準拠の実装）では 1 秒刻みへ落とす。刻みが粗いと
  # スロットの再充填が遅れるだけで、結果は変わらない。
  FF_POLL_INTERVAL=1
fi

ff_detect_cpus() {
  local n
  n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  if [[ ! "$n" =~ ^[1-9][0-9]*$ ]]; then
    n="$(sysctl -n hw.ncpu 2>/dev/null || true)"
  fi
  if [[ ! "$n" =~ ^[1-9][0-9]*$ ]]; then
    n=4
  fi
  printf '%s\n' "$n"
}

FF_JOBS_CAP=8
# 明示指定として受け付ける上限。桁数を先に見るのは、正規表現を通る巨大値をそのまま
# 算術比較へ渡すと bash の整数が符号あり 64bit で折り返し、`-gt 1` が偽になって
# **警告なしに逐次へ化ける**ため（同時に、桁数を見ないと 100000 並列の投入も通る）。
FF_JOBS_LIMIT=256
ff_resolve_jobs() {
  local raw cpus
  raw="${FF_RUN_ALL_JOBS:-}"
  if [[ -n "$raw" ]]; then
    if [[ "$raw" =~ ^[1-9][0-9]*$ ]]; then
      if [[ "${#raw}" -le 3 && "$raw" -le "$FF_JOBS_LIMIT" ]]; then
        printf '%s\n' "$raw"
        return 0
      fi
      echo "⚠️  FF_RUN_ALL_JOBS が上限 ${FF_JOBS_LIMIT} を超えています: ${raw} — 既定の同時実行数で続行します" >&2
    else
      echo "⚠️  FF_RUN_ALL_JOBS を解釈できません（1 以上の整数のみ）: ${raw} — 既定の同時実行数で続行します" >&2
    fi
  fi
  # 入れ子の実行（外側の run-all.sh から suite として呼ばれた回）は、明示指定が
  # 無ければ逐次で走らせる。外側の同時実行数と掛け算になり、実時間の上限を見る
  # suite の幅を負荷経由で食うため。
  if [[ "$FF_ENTERED_NESTED" == "1" ]]; then
    printf '1\n'
    return 0
  fi
  cpus="$(ff_detect_cpus)"
  if [[ "$cpus" -gt "$FF_JOBS_CAP" ]]; then
    printf '%s\n' "$FF_JOBS_CAP"
  else
    printf '%s\n' "$cpus"
  fi
}

JOBS="$(ff_resolve_jobs)"

# 並列実行は spool ディレクトリを要求する。確保できない環境では逐次へ退避する
# （skip も失敗もしない。実行対象と結果は同じで、所要時間だけが伸びる）。
SPOOL=""
if [[ "$JOBS" -gt 1 && ${#SCRIPTS[@]} -gt 1 ]]; then
  # spool の後片付けに EXIT トラップは**置かない**。`trap 'rm -rf ...' EXIT` は
  # トラップ最終コマンドの成功が終了ステータスを上書きし、途中死を rc=0 に化けさせる
  # （tests/run-all/verify.sh case 12 が suite 側で実測した形。23 本中 20 本）。rc を
  # 保存する版でも直らない — `set -u` による死ではトラップ突入時の $? が 0 になるため、
  # 保存した「0」で exit してしまう。**ランナーの終了コードを守る方を採る**：後片付けは
  # 正常完了時に明示的に行い、途中で死んだ回は $TMPDIR に ff-run-all-spool.* を
  # 残す（OS の一時領域の掃除に委ねる。名前で識別できる）。
  if SPOOL="$(mktemp -d "${TMPDIR:-/tmp}/ff-run-all-spool.XXXXXX" 2>/dev/null)"; then
    :
  else
    SPOOL=""
    echo "⚠️  一時領域を確保できないため逐次実行へ退避します（実行対象と結果は同じで、所要時間だけが伸びます）" >&2
  fi
fi

if [[ -n "$SPOOL" ]]; then
  echo "🧵 並列実行: 同時実行数 ${JOBS}（逐次に戻すには FF_RUN_ALL_JOBS=1）"
  echo
  ff_run_parallel
else
  ff_run_sequential
fi

# ---- サマリー --------------------------------------------------------------
# 「実行した suite 数」と「失敗/スキップ/未実行の suite 名」を必ず出す。総数と
# 実行数が食い違ったまま success を名乗らないことが、本 Issue の masking 対策の本体。
ff_emit_summary_head
if [[ ${#CHECKS_SKIPPED[@]} -gt 0 ]]; then
  echo "○ checks skipped (suite内の部分skip。suite-level skippedとは別勘定): ${CHECKS_SKIPPED[*]}"
fi

# 高速モードの除外は「何を検証していないか」ごとサマリーへ明示する。除外は total にも
# skipped にも数えない — 環境都合の skip（検証したかったが出来なかった）と、意図的な
# 除外（検証しないと決めた）を混ぜると、必須 skip 判定の意味が壊れるため。
if [[ "$FAST_MODE" == "1" ]]; then
  if [[ ${#FAST_EXCLUDED[@]} -gt 0 ]]; then
    # 除外のうち REQUIRED_SUITES 掲載が何件かを出す。名簿は持たず 2 つの配列の積を取るだけ
    # （導出のみ。ADR-031 の方針）。件数を出さないと、読み手が「環境都合で消えたら赤にすると
    # 宣言した suite」が意図的に落ちていることに気づけない（ADR-034 §影響）。
    _fast_excl_required=0
    for _fe in "${FAST_EXCLUDED[@]}"; do
      for _r in "${REQUIRED_SUITES[@]}"; do
        if [[ "$_fe" == "$_r" ]]; then
          _fast_excl_required=$((_fast_excl_required + 1))
          break
        fi
      done
    done
    echo "⚡ 高速モードで selftest ${#FAST_EXCLUDED[@]} 件を除外した（うち REQUIRED_SUITES 掲載 ${_fast_excl_required} 件 — 既定では必須 skip の fail-closed 保護がこれらへ及ばない。これらが担う検査〔対の本体 suite に対するゲート検出力。対の実在を代理指標にしているため、除外側に live な照合が残ることもある〕は未実施。全件実行は FF_RUN_ALL_FULL=1）: ${FAST_EXCLUDED[*]}"
  else
    echo "⚡ 高速モード: 除外対象の selftest は 0 件だった（除外は行っていない）"
  fi
  # 対を持たない selftest は除外しない。「-selftest なのに走っている」を読み手が
  # 例外や漏れと誤読しないよう、件数と理由を明示する（ADR-031）。
  if [[ ${#FAST_KEPT_SELFTEST[@]} -gt 0 ]]; then
    echo "⚡ 対になる本体 suite を持たない selftest ${#FAST_KEPT_SELFTEST[@]} 件は除外しなかった（その検査対象を見る suite が他に無いため。必須 skip の許可時はこの中に skip も含まれうる）: ${FAST_KEPT_SELFTEST[*]}"
  fi
fi

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo "○ skipped (環境都合で検証本体が未実行): ${SKIPPED[*]}"
fi

# 必須名簿の suite が skip したら失敗として扱う（既定）。環境都合で回せない場合は
# FF_RUN_ALL_ALLOW_SKIP で**明示的に宣言**する。黙って消えることを無くすのが目的で、
# 許容そのものを禁じているわけではない。
REQUIRED_SKIPPED=()
if [[ "$USING_DEFAULT_SCRIPTS" == "1" && ${#SKIPPED[@]} -gt 0 ]]; then
  _allow="${FF_RUN_ALL_ALLOW_SKIP:-}"
  if [[ "$_allow" == "all" ]]; then
    echo "⚠️  FF_RUN_ALL_ALLOW_SKIP=all — 必須 suite の skip を許容しています（検証されていない不変条件があります）" >&2
  else
    # カンマ区切りも受ける
    _allow="${_allow//,/ }"
    for _s in "${SKIPPED[@]}"; do
      for _r in "${REQUIRED_SUITES[@]}"; do
        [[ "$_s" == "$_r" ]] || continue
        _declared=0
        for _a in $_allow; do [[ "$_a" == "$_s" ]] && { _declared=1; break; }; done
        [[ "$_declared" -eq 1 ]] || REQUIRED_SKIPPED+=("$_s")
      done
    done
  fi
fi
if [[ ${#REQUIRED_SKIPPED[@]} -gt 0 ]]; then
  echo "✗ 環境都合で消してはいけない suite が skip しました: ${REQUIRED_SKIPPED[*]}" >&2
  echo "  これらが守る不変条件には代替の検査がありません（必要な実行環境は各 suite のコメントを参照）。" >&2
  echo "  回せない環境なら、理由を承知のうえで明示的に外してください:" >&2
  # 案内は**実行中のモードを保つ形**で出す。高速モードは既定なので前置は要らないが、
  # 全件実行中に前置を落とした案内を出すと、コピペした利用者が気づかないまま既定（高速）へ
  # 落ちる — 既定反転（ADR-034）で前置が要る側が入れ替わった。
  if [[ "$FAST_MODE" == "1" ]]; then
    echo "    FF_RUN_ALL_ALLOW_SKIP=\"${REQUIRED_SKIPPED[*]}\" bash tests/run-all.sh" >&2
  else
    echo "    FF_RUN_ALL_FULL=1 FF_RUN_ALL_ALLOW_SKIP=\"${REQUIRED_SKIPPED[*]}\" bash tests/run-all.sh" >&2
  fi
fi
if [[ ${#NOT_RUN[@]} -gt 0 ]]; then
  echo "✗ not run (suite を起動できなかった): ${NOT_RUN[*]}" >&2
fi
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "✗ failed: ${FAILED[*]}" >&2
fi

# node_modules 不在に起因する必須 skip / FULL での fail は、markdownlint 系 / mcp-* 系 /
# ace-* 系 / docs-scan-mirror / live-ace-gates 系にまたがる（各 suite のコメント参照）。
# 個々の skip/fail 理由を suite ごとに読み解かなくても、原因は
# 「plugins/ff-dev-toolkit/mcp/node_modules の実在」1点に単純化できるため、判定はそこだけを
# 見る（既存の ○ skip 行に埋もれないための可視化。検査の新設ではない）。テスト用の上書きは
# FF_RUN_ALL_MCP_NODE_MODULES（既定は run-all.sh から見た相対パス）。
MCP_NODE_MODULES="${FF_RUN_ALL_MCP_NODE_MODULES:-$SCRIPT_DIR/../mcp/node_modules}"
if [[ ! -d "$MCP_NODE_MODULES" && ( ${#SKIPPED[@]} -gt 0 || ${#FAILED[@]} -gt 0 ) ]]; then
  echo "○ 案内: mcp/node_modules が無いため一部 suite が skip / fail した可能性があります。全件ゲート前に次を実行してください: npm ci --prefix plugins/ff-dev-toolkit/mcp"
fi

# ── 走行中に汚れなかったかを終了時に再評価する（fail-loud。終了コードは変えない）─────
# 起動ガード（上流）が見るのは**起動時点**の汚れだけである。clean で起動した後、走行中
# （数分〜十数分）にレビュー指摘の編集を当てた回は最後まで回りきり、鮮度記録が `DIRTY=yes`
# になって、マージ直前の照合（scripts/check-merge-freshness.sh）が「判定不能」を返して初めて
# 「その実行は証拠にならなかった」と分かる。記録側は実行の後にしか汚れを知らせないので、
# 気づくのはいつも手遅れの側である（OBS-005）。ここで記録を書く**前**に 1 行言い切る。
#
# **終了コードは suite の結果だけで決める**。汚れは検証結果の失敗ではないし、実行結果その
# ものは捨てない（どの suite が緑だったかはサマリーに残る）。記録も従来どおり `DIRTY=yes`
# で書かれ、照合側が判定不能として報告する — 黙って緑にはならない。
#
# 述語は起動ガード・記録側と同じ（`git status --porcelain` の stdout が非空。未追跡も数える）。
# 記録側 scripts/record-gate-head.sh は述語を関数として公開していないので、共有 API を新設
# せずここで最小の再評価に留める（起動ガードの述語も同じ理由でこのファイルに直書きされている）。
#
# 旗が立つのは「起動ガードが clean と断定できた既定一覧の回」だけ。明示引数の実行と
# `FF_RUN_ALL_ALLOW_DIRTY=1` の回は元から証拠にならず、後者で「走行中に汚れた」と言うのは
# 端的に嘘になる。
if [[ "$STARTED_CLEAN" == "1" ]]; then
  END_DIRTY_RC=0
  END_DIRTY_OUT="$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null)" || END_DIRTY_RC=$?
  if [[ "$END_DIRTY_RC" -ne 0 ]]; then
    # 起動時は読めた木が終了時に読めない（リポジトリごと消えた等）。clean と断定できない
    # 以上、無言で済ませない。
    echo "⚠️  終了時に作業ツリーの状態を確認できませんでした（起動時は clean でした）。この実行が鮮度記録の証拠になるかは判定できません。" >&2
  elif [[ -n "$END_DIRTY_OUT" ]]; then
    echo "⚠️  作業ツリーが走行中に汚れたため、この実行は鮮度記録の証拠になりません（鮮度記録が書かれる回は DIRTY=yes になり、マージ直前の照合は「判定不能」になります）" >&2
    # 一覧の打ち切りは起動ガードと同じ 20 行（案内文が羅列で流れないように）。
    printf '%s\n' "$END_DIRTY_OUT" | sed -n '1,20p' | sed 's/^/    /' >&2
    END_DIRTY_N="$(printf '%s\n' "$END_DIRTY_OUT" | sed -n '$=')"
    if [[ "${END_DIRTY_N:-0}" -gt 20 ]]; then
      echo "    … 他 $(( END_DIRTY_N - 20 )) 件" >&2
    fi
    echo "  この実行の結果自体は上のサマリーのとおりです（終了コードは suite の結果だけで決まります）。証拠が要るなら変更をコミットしてから回し直してください。" >&2
  fi
fi

# >>> ff-gate-record-block（tests/merge-freshness/verify.sh がこの関数定義を抽出して
# 隔離環境で実行し、記録が実際に書かれることを実測する。マーカーを消すとその検査が
# 「抽出 0 行」で赤くなる。範囲は**関数定義だけ**にすること — 呼び出し側まで含めると
# 抽出したコードが exit を持ち込む）
#
# 通過した実行が**どのコミットを測ったのか**を記録し、マージ直前の鮮度照合
# （scripts/check-merge-freshness.sh）が「リモート先端 == 実測対象」を機械で言える
# ようにする（Issue #880）。
#
# 明示引数の実行も記録する。ただし**全件緑へ昇格しない形**で記録する — 名指しした
# suite しか回っていない結果が「ゲートが通った」としてマージの根拠になると fail-open
# になるため、緑は `--status partial` として書く（照合側は一致していても「判定不能」
# として報告し、何を検証したのかを `--suites` の中身から名指しする）。
#
# 記録そのものを飛ばしていた頃は、名指し実行しか走らない収束経路（CHANGELOG footer
# 追従など）を通った PR には「最後の全件記録 = 別コミット」だけが残り、鮮度照合が
# 必ず赤くなった。毎回無視するゲートは、そのうち本当の赤も無視される（Issue #892）。
#
# 緑の記録は PASSED > 0 も自分で確かめる（後段の件数ガードは呼び出し位置より下に
# あるので当てにしない）。この帰結として `SUITES=` が空 ⟺ 部分実行ではない、が成り立つ。
#
# **赤い実行も記録する（--status fail）。** 書かずに済ませると、同じコミットで前回
# 通った記録が残り、照合は無出力の exit 0 を返す — 「一度通ったコミット」が「いま
# 通るコミット」に化ける。明示引数の赤も同じ理由で `fail` のまま記録する（`partial`
# へ落とすと、赤い実行が前回の緑を無効化しそこねる）。
#
# `FF_GATE_RECORD=0` は明示引数の経路にも掛ける。記録を止める逃げ道を経路ごとに
# 差別化すると、「どちらの経路なら止まるのか」を読み手が別途覚えることになる。
#
# 記録の失敗は**検証結果の失敗ではない**。1 行警告して終了コードは変えない
# （記録が無ければ照合側が「判定不能」として報告する。黙って緑にはならない）。
ff_record_gate_head() { # <pass|fail>
  local status="$1" recorder mode suites
  if [[ "${FF_GATE_RECORD:-1}" == "0" ]]; then
    echo "○ FF_GATE_RECORD=0 のためゲート実測対象を記録しません（マージ前の鮮度照合は「判定不能」になります）" >&2
    return 0
  fi
  [[ "$status" != "pass" || ${#PASSED[@]} -gt 0 ]] || return 0
  recorder="$SCRIPT_DIR/../scripts/record-gate-head.sh"
  if [[ ! -f "$recorder" ]]; then
    echo "⚠️  記録器が見つかりません: ${recorder}（マージ前の鮮度照合は「判定不能」になります）" >&2
    return 0
  fi
  # 呼び出し側の 2 行（`ff_record_gate_head fail` / `pass`）はバイトのまま固定されて
  # いる（tests/merge-freshness/verify.sh の針）。既定一覧かどうかによる写像はここで行う。
  suites=""
  if [[ "$USING_DEFAULT_SCRIPTS" == "1" ]]; then
    if [[ "$FAST_MODE" == "1" ]]; then mode="fast"; else mode="full"; fi
  else
    mode="explicit"
    if [[ "$status" == "pass" ]]; then
      status="partial"
      # suite 名は**実際に緑で通ったものだけ**を挙げる。skip した suite を混ぜると
      # 「検証済み」の一覧が検証していないものを含む。bash 3.2 では空配列の
      # `${PASSED[*]}` が set -u で unbound になるので件数で囲む（上の PASSED > 0
      # ガードを通っているが、条件の一方が動いたときに黙って壊れないようにする）。
      [[ ${#PASSED[@]} -eq 0 ]] || suites="${PASSED[*]}"
    fi
  fi
  # 記録するのは**このランナーが在るリポジトリ**の HEAD。呼び出し元の cwd を基準に
  # すると、別のリポジトリから起動した回に無関係な HEAD を実測対象として記録する。
  ( cd "$SCRIPT_DIR" && bash "$recorder" \
      --gate "tests/run-all.sh" \
      --status "$status" \
      --mode "$mode" \
      --suites "$suites" \
      --expect-head "${FF_GATE_START_HEAD:-}" \
      --result "passed=${#PASSED[@]} failed=${#FAILED[@]} skipped=${#SKIPPED[@]} not-run=${#NOT_RUN[@]} excluded=${#FAST_EXCLUDED[@]}" ) \
    || echo "⚠️  ゲート実測対象を記録できませんでした（マージ前の鮮度照合は「判定不能」になります）" >&2
}
# <<< ff-gate-record-block

if [[ ${#FAILED[@]} -gt 0 || ${#NOT_RUN[@]} -gt 0 || ${#REQUIRED_SKIPPED[@]} -gt 0 ]]; then
  ff_record_gate_head fail
  exit 1
fi

# ここから下は全て exit 0（唯一の例外は「pass 0 件で skip だけ」= 検証が成立して
# いない場合で、下の PASSED 件数ガードがそれを弾く）。通過した実行が**どのコミットを
# 測ったのか**を記録し、マージ直前の鮮度照合（scripts/check-merge-freshness.sh）が
# 「リモート先端 == 実測対象」を機械で言えるようにする（Issue #880）。
#
# 明示引数の実行も記録するが、`--status partial` として書く（照合側は一致していても
# 判定不能として報告し、全件緑へ昇格しない）。写像は ff_record_gate_head の中。
#
# 記録の失敗は**検証結果の失敗ではない**。1 行警告して終了コードは変えない
# （記録が無ければ照合側が「判定不能」として報告する。黙って緑にはならない）。
ff_record_gate_head pass

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  # skip だけで pass が 0 = 検証が 1 件も成立していない。文言だけ出して 0 で終わると、
  # 終了コードしか見ない CI では「全部通った」と区別が付かないので非 0 で落とす。
  if [[ ${#PASSED[@]} -eq 0 ]]; then
    echo "✗ 検証できた suite がありません（全 ${#SKIPPED[@]} suite が環境都合でスキップ）。書き込み可能な環境で再実行してください" >&2
    exit 1
  fi
  # 高速モードでは「書き込み可能な環境で回す」だけでは全件検証にならない
  # （FF_RUN_ALL_FULL=1 も要る）ので、最終行の案内を分ける。
  if [[ "$FAST_MODE" == "1" ]]; then
    echo "実行した ${#PASSED[@]} suite は全て通過（${#SKIPPED[@]} suite は環境都合でスキップ、selftest ${#FAST_EXCLUDED[@]} 件は高速モードで未実行。全件検証は FF_RUN_ALL_FULL=1 を書き込み可能な環境で行うこと）"
  else
    echo "実行した ${#PASSED[@]} suite は全て通過（${#SKIPPED[@]} suite は環境都合でスキップ。全 suite の検証は書き込み可能な環境で行うこと）"
  fi
  exit 0
fi

# 高速モード（既定）では selftest が未実行なので、全体 pass（All ... passed）を名乗らない。
if [[ "$FAST_MODE" == "1" ]]; then
  echo "実行した ${#PASSED[@]} suite は全て通過（高速モード: selftest ${#FAST_EXCLUDED[@]} 件は未実行。全件検証は FF_RUN_ALL_FULL=1 で行うこと）"
  exit 0
fi

echo "All ff-dev-toolkit fixture checks passed."
exit 0
