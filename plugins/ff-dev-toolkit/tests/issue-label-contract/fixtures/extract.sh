#!/usr/bin/env bash
#
# 契約ブロック抽出（verify.sh と regenerate.sh が共有する唯一の実装）。
#
# 検査側と生成側が別々に抽出を実装すると、両方が同じようにずれたときに気づけない。
# 抽出は 1 箇所に置き、verify.sh 側で「抽出器が本当に動いているか」を対照で確かめる。
#
# 抽出範囲: ```bash フェンス内の、アンカー行から最初の `done` 行まで（両端を含む）。
# 正規化: 両スキルで**意図的に異なる** 2 行をプレースホルダへ潰す。ここを潰さないと
#   候補の系統の違い（create-issue は type / priority、out-of-scope-issue はさらに
#   follow-up）が毎回ドリフトとして報告されてしまう。潰した違い自体は verify.sh が
#   別途「2 系統 / 3 系統」の存在検査で固定するので、検査の穴にはならない。

LABEL_BLOCK_ANCHOR='# 実在するラベル名の一覧。取得できなければラベルなしで進める（起票自体は止めない）。'

extract_label_block() {
  awk -v anchor="$LABEL_BLOCK_ANCHOR" '
    { sub(/\r$/, "") }
    # ```bash / ```sh などのフェンス開閉を追う。フェンス外の散文に同じ行があっても拾わない。
    in_fence == 0 {
      if ($0 ~ /^[[:space:]]*```[[:space:]]*(bash|sh|shell|zsh)[[:space:]]*$/) in_fence = 1
      next
    }
    $0 ~ /^[[:space:]]*```[[:space:]]*$/ { in_fence = 0; capturing = 0; next }
    capturing == 0 {
      if ($0 == anchor) { capturing = 1 } else { next }
    }
    {
      line = $0
      # 意図的に異なる 2 行を正規化する。
      if (line ~ /^# type \/ priority/) line = "#{{CANDIDATE-FAMILIES}}"
      else if (line ~ /^for candidate in /) line = "{{CANDIDATE-LOOP}}"
      print line
      if ($0 == "done") { capturing = 0; done_seen = 1; exit }
    }
    END { if (done_seen != 1) exit 3 }
  ' "$1"
}
