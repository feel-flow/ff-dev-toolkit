// MASTER.md参照: マジックナンバー禁止。意味と単位をコメントで明示。

/**
 * 抜粋生成時の前後文字数（chars）
 * ユースケース: ドキュメント検索結果 excerpt。
 * 範囲: 40〜200 推奨。可変要件が出れば環境変数化。
 */
export const EXCERPT_PADDING_CHARS = 80 as const;

/**
 * 「メッセージが 1 件も届かないまま transport エラーが続いた」と判定する閾値
 * （成功メッセージを挟まない連続 transport エラー回数）
 * ユースケース: この回数連続でエラーが起きたら致命的として exit する (Issue #218)。
 * 判定の意味論と採用根拠の正本は src/index.ts の installTransportDiagnostics の
 * CONSECUTIVE FAILURES コメントを参照。
 * 20 の桁感: 健全なホストの破損バーストは 1 フレーム分（実測 1〜2 行）+
 * 直後の成功リセットで収まるため、その 1 桁以上上を境界とする。
 */
export const MAX_CONSECUTIVE_TRANSPORT_ERRORS = 20 as const;

/** Specステータス列挙 */
export const SPEC_STATUS = [
  "draft",
  "review",
  "approved",
  "implementing",
  "done",
  "deprecated"
] as const;
export type SpecStatus = typeof SPEC_STATUS[number];
