/**
 * ACE Playbook frontmatter の同期スクリプト（Issue #23 / Issue #76）。
 *
 * 背景:
 *   PLAYBOOK.md の frontmatter `ace_entry_count` は手動更新のため、実際のエントリ
 *   件数とドリフトしやすい（実例: 記録値 123 vs 実数 124）。この乖離は「知見が
 *   何件あるか」という運用指標を静かに壊す。エントリ件数は機械的に数えられるので、
 *   単一の真実源（実際の見出し数）から frontmatter を導出・検証できるようにする。
 *   加えて frontmatter `version` と `## Changelog` 最新版の不一致も、手順漏れで
 *   静かに積み上がる（Issue #76: version 1.60.0 なのに Changelog が 1.59.0 のまま）。
 *
 * 機能:
 *   - `--check`（既定）: 実エントリ数と frontmatter `ace_entry_count` を比較し、
 *     ドリフトがあれば終了コード 1 を返す（CI ゲート）。frontmatter `version` と
 *     `## Changelog` 最新 `### [x.y.z]` の一致も検証する。`## Changelog` セクション
 *     そのものが無い場合もドリフト扱いにする（Issue #615: 以前はスキップしていたため、
 *     セクションごと消せば version 検証が永久に効かなくなる fail-open だった）。加えて
 *     `changeImpact` を検証する（Issue #289: 変更済みなのに未記録、または値が
 *     小文字の low / medium / high 以外ならドリフト扱い。値域は `/validate-docs` の
 *     Frontmatter スキーマと同一。「変更済み」の判定は同スキーマのうち機械判定
 *     できる部分集合 — created ≠ updated、または `## Changelog` に版見出しが
 *     2 件以上 — を実装する）。
 *   - `--write`         : `ace_entry_count` を実数へ、`updated` を当日（または
 *     ACE_UPDATED_DATE）へ更新してファイルへ書き戻す（Changelog 本文は書き換えない）。
 *     変更済みなのに `changeImpact` が欠落している場合は `medium` を自動追記する
 *     （ACE の版上げは常に minor +1 のため）。値域違反（`MEDIUM` 等）は自動修正せず、
 *     書き込み後も報告して終了コード 1 を返す。
 *   - `--bump-version`  : `--write` と併用時、`version`（semver）を **minor +1**
 *     し patch を 0 にする（ACE curate の版上げ方針。patch 上げは使わない）。
 *
 * frontmatter の読み書きは**トップレベルのキーだけ**を対象にする（Issue #615）。
 * インデントを許すと `metadata:` 配下の同名キーをトップレベル記録と誤認し、必須項目が
 * 欠落していても check が通り、`--write` がネスト側を書き換える。トップレベルに同名
 * キーが重複する場合も、YAML の後勝ちと「最初の 1 行だけ差し替え」がずれるため拒否する。
 *
 * 集計は check-category-size.ts と同じロジック（HTML コメント内の追記例やテンプレの
 * プレースホルダ見出しを除外、playbook/ 分割レイアウトも合算）を再利用するため、
 * check ゲートと ACE カウンタが常に一致する。
 *
 * 実行例:
 *   npx --yes tsx docs-template/scripts/ace/sync-playbook-frontmatter.ts docs-template/08-knowledge/PLAYBOOK.md --check
 *   npx --yes tsx docs-template/scripts/ace/sync-playbook-frontmatter.ts docs-template/08-knowledge/PLAYBOOK.md --write
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import {
  analyzePlaybookMarkdown,
  discoverPlaybookSubfiles,
  mergeAnalyses,
  type AnalyzeSuccess,
} from "./check-category-size.js";

const EXIT_OK = 0;
const EXIT_DRIFT = 1;
const EXIT_USAGE_ERROR = 2;

const FRONT_BOUNDARY = "---";
const COUNT_FIELD = "ace_entry_count";
const UPDATED_FIELD = "updated";
const VERSION_FIELD = "version";
const CREATED_FIELD = "created";
const CHANGE_IMPACT_FIELD = "changeImpact";
/**
 * 本スクリプトが読み書きする frontmatter フィールド（`created` は読み取り専用で、
 * 「変更済み文書」の判定にだけ使う）。トップレベルでの重複を拒否する対象でもある
 * （Issue #615）。読むだけのフィールドも重複を拒否するのは、後勝ちで判定が変わる
 * 曖昧な frontmatter をそもそも受け付けないため。
 */
const MANAGED_TOP_LEVEL_FIELDS: readonly string[] = [
  COUNT_FIELD,
  UPDATED_FIELD,
  VERSION_FIELD,
  CREATED_FIELD,
  CHANGE_IMPACT_FIELD,
];
/** `/validate-docs` の Frontmatter スキーマと同じ値域（小文字のみ有効）。 */
const CHANGE_IMPACT_VALUES: ReadonlySet<string> = new Set(["low", "medium", "high"]);
/** `--write` が欠落時に自動追記する値（ACE の版上げは常に minor +1 = medium）。 */
const DEFAULT_CHANGE_IMPACT = "medium";
/** Changelog の版見出しがこの件数以上なら「初版以外のエントリがある」= 変更済みとみなす。 */
const MULTIPLE_CHANGELOG_VERSIONS_MIN = 2;
const ISO_DATE_PATTERN = /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/u;

const FLAG_CHECK = "--check";
const FLAG_WRITE = "--write";
const FLAG_BUMP_VERSION = "--bump-version";
const SUPPORTED_FLAGS = new Set([FLAG_CHECK, FLAG_WRITE, FLAG_BUMP_VERSION]);

// semver (x.y.z) の構成要素数と、split(".") 後の各パートの添字。
const SEMVER_PARTS = 3;
const SEMVER_MAJOR_INDEX = 0;
const SEMVER_MINOR_INDEX = 1;
const SEMVER_PATCH_INDEX = 2;

// replaceTopLevelField の正規表現キャプチャ添字（1=key: 後の空白, 2=値）。
const FIELD_SPACING_GROUP = 1;
const FIELD_VALUE_GROUP = 2;

// YYYY-MM-DD 生成時の 0 埋め桁数と日付パートの添字。
const YEAR_PAD_WIDTH = 4;
const MONTH_DAY_PAD_WIDTH = 2;
const ISO_DATE_PARTS = 3;
const ISO_DATE_YEAR_INDEX = 0;
const ISO_DATE_MONTH_INDEX = 1;
const ISO_DATE_DAY_INDEX = 2;
const JAVASCRIPT_MONTH_OFFSET = 1;

/** `## Changelog` 見出し（ATX）。前後の空白を許容。 */
const CHANGELOG_HEADING_PATTERN = /^##[ \t]+Changelog[ \t]*$/mu;
/** Changelog 内の版見出し `### [x.y.z] - YYYY-MM-DD`（日付は任意）。 */
const CHANGELOG_VERSION_HEADING_PATTERN = /^###[ \t]+\[([0-9]+\.[0-9]+\.[0-9]+)\]/mu;
/**
 * Changelog セクション終端: 次のレベル2見出し（`## ` で始まり `###` ではない行）。
 * セクション外の版見出しを誤認しないために使う。
 */
const NEXT_H2_HEADING_PATTERN = /\n##[ \t]+(?!#)/u;

export type FrontmatterField =
  | typeof COUNT_FIELD
  | typeof UPDATED_FIELD
  | typeof VERSION_FIELD
  | typeof CHANGE_IMPACT_FIELD;

export type FieldChange = Readonly<{
  readonly field: FrontmatterField;
  readonly from: string | null;
  readonly to: string;
}>;

/**
 * `## Changelog` セクション不在をドリフト扱いにしない緩和（Issue #615）。
 * **Changelog を持たない最小 fixture を組むユニットテスト専用**で、CLI からは設定
 * できない。実運用の PLAYBOOK.md は `/ace-setup` が配るテンプレートの時点で
 * `## Changelog` を持つため、不在は「消された」以外の意味を持たない — そこへ
 * CLI フラグを生やすと、fail-open を潰す修正に fail-open の逃げ道を付けることになる。
 */
type AllowMissingChangelogOption = Readonly<{
  readonly allowMissingChangelog?: boolean;
}>;

export type SyncCheckOptions = AllowMissingChangelogOption &
  Readonly<{
    /** check モード（既定）。frontmatter へは書き戻さない。 */
    readonly write?: false;
    /** check モードでは version bump を許可しない。 */
    readonly bumpVersion?: never;
    /** check モードでは updated 日付指定を許可しない。 */
    readonly updatedDate?: never;
  }>;

export type SyncWriteOptions = AllowMissingChangelogOption &
  Readonly<{
    /** write モード。frontmatter へ書き戻す前提の内容を計算する。 */
    readonly write: true;
    /** version を minor +1（patch は 0）するか。 */
    readonly bumpVersion?: boolean;
    /** `updated` に入れる日付（YYYY-MM-DD）。省略時は当日。 */
    readonly updatedDate?: string;
  }>;

export type SyncOptions = SyncCheckOptions | SyncWriteOptions;

export type SyncOk = Readonly<{
  readonly kind: "ok";
  readonly actualCount: number;
  readonly recordedCount: number | null;
  /** 記録値と実数が一致しているか（check モードの合否） */
  readonly inSync: boolean;
  /** frontmatter の version（無ければ null） */
  readonly frontmatterVersion: string | null;
  /**
   * `## Changelog` 内の最新版（最初の `### [x.y.z]`）。
   * セクションが無い / 版見出しが無い場合は null。
   */
  readonly changelogVersion: string | null;
  /**
   * `## Changelog` セクションの状態。`absent`（セクションごと無い）と
   * `empty`（あるが版見出しが無い）は診断文が異なるため呼び出し側で区別する。
   */
  readonly changelogState: "absent" | "empty" | "found";
  /**
   * frontmatter version と Changelog 最新版が一致しているか。
   * Changelog セクションが無い場合も false（Issue #615: セクションを消すだけで
   * version 検証が永久に効かなくなる fail-open を塞ぐ）。ただし
   * `allowMissingChangelog` を渡したテスト fixture では true のまま。
   * Changelog があるのに版見出しが無い / version フィールドが無い場合は false。
   */
  readonly versionChangelogInSync: boolean;
  /** frontmatter トップレベルの changeImpact 生値（無ければ null） */
  readonly changeImpactValue: string | null;
  /**
   * changeImpact がスキーマを満たしているか。変更済み（created ≠ updated、
   * または Changelog に版見出しが 2 件以上）なのに未記録、または値が小文字の
   * low / medium / high 以外なら false。変更済みと判定される根拠が無い文書
   * （初版、created / updated を持たない最小 fixture）では presence を要求しない。
   * 残る死角: created が欠落し Changelog も 1 件以下の文書は「変更済み」を
   * 機械判定できず素通りする — その面は `/validate-docs` 側が捕捉する。
   */
  readonly changeImpactValid: boolean;
  /** 適用（write）または適用予定（check）の frontmatter 変更 */
  readonly changes: readonly FieldChange[];
  /** 更新後の全文（write=false でも「あるべき姿」を返す） */
  readonly content: string;
}>;

export type SyncFailure = Readonly<{
  readonly kind: "error";
  readonly message: string;
}>;

export type SyncResult = SyncOk | SyncFailure;

/** 全文を frontmatter ブロックと本文へ分離する。frontmatter が無ければ null。 */
export function splitFrontmatter(
  content: string,
): { readonly frontmatter: string; readonly rest: string } | null {
  const lines = content.split(/\r?\n/u);
  if (lines[0] !== FRONT_BOUNDARY) return null;
  let i = 1;
  const fmLines: string[] = [];
  while (i < lines.length && lines[i] !== FRONT_BOUNDARY) {
    fmLines.push(lines[i]);
    i++;
  }
  if (i >= lines.length) return null; // 閉じ境界なし
  const rest = lines.slice(i).join("\n"); // 閉じ '---' 行を含む本文側
  return { frontmatter: fmLines.join("\n"), rest };
}

/**
 * frontmatter の**トップレベル** key の生値（クォート除去済み）を取り出す。無ければ null。
 * インデント（`metadata:` 等の配下にネストされたキー）は一切許容しない。ネストされた
 * 同名キーをトップレベル記録と誤認すると、必須項目が欠落したまま check が通る
 * （Issue #615）。本スクリプトの読み取りはすべてこの関数を通す。
 */
export function readTopLevelField(frontmatter: string, key: string): string | null {
  const re = new RegExp(`^${escapeRegExp(key)}:[ \\t]*(.*)$`, "mu");
  const match = frontmatter.match(re);
  if (!match) return null;
  return unquote(match[1].trim());
}

/**
 * frontmatter のトップレベルに key が何回現れるかを数える。
 * YAML は同名キーの後勝ちだが replaceTopLevelField は最初の 1 行だけを差し替えるため、
 * 重複したまま書き込むと「読んだ値」と「書いた行」がずれる。呼び出し側は 2 以上を
 * エラーとして扱う（Issue #615）。
 */
export function countTopLevelFieldOccurrences(frontmatter: string, key: string): number {
  const matches = frontmatter.match(new RegExp(`^${escapeRegExp(key)}:`, "gmu"));
  return matches?.length ?? 0;
}

/**
 * frontmatter のトップレベル afterKey 行の直後へ `key: value` を 1 行追記する。
 * afterKey が見つからなければ null（呼び出し側でエラーとして扱う）。
 */
export function insertFieldAfter(
  frontmatter: string,
  afterKey: string,
  key: string,
  value: string,
): string | null {
  const re = new RegExp(`^${escapeRegExp(afterKey)}:[ \\t]*.*$`, "mu");
  const match = re.exec(frontmatter);
  if (!match || match.index === undefined) return null;
  const lineEnd = match.index + match[0].length;
  return `${frontmatter.slice(0, lineEnd)}\n${key}: ${value}${frontmatter.slice(lineEnd)}`;
}

/**
 * 「変更済み文書」の機械判定（`/validate-docs` スキーマの部分集合）:
 * created ≠ updated（両フィールドが存在する場合）、または Changelog の版見出しが
 * 2 件以上。created が欠落し Changelog も 1 件以下の文書は判定できず false になる
 * （その面は `/validate-docs` 側が捕捉する）。
 */
export function isModifiedDocState(
  created: string | null,
  updated: string | null,
  changelogVersionCount: number,
): boolean {
  if (created !== null && updated !== null && created !== updated) return true;
  return changelogVersionCount >= MULTIPLE_CHANGELOG_VERSIONS_MIN;
}

/**
 * frontmatter の**トップレベル** key の値だけを差し替える。クォートの有無は既存の
 * 形式を踏襲する（コメント・キー順・他フィールドは一切触らない）。
 * ネストされた同名キー（`metadata:` 配下等）は対象にしない — 書き換えてしまうと
 * トップレベルの必須項目が欠けたまま「同期済み」になる（Issue #615）。
 * トップレベルに key が存在しなければ null（呼び出し側でフィールド欠落として扱う）。
 */
export function replaceTopLevelField(
  frontmatter: string,
  key: string,
  newValue: string,
): string | null {
  const re = new RegExp(`^${escapeRegExp(key)}:([ \\t]*)(.*)$`, "mu");
  const match = frontmatter.match(re);
  if (!match) return null;
  const spacing = match[FIELD_SPACING_GROUP] === "" ? " " : match[FIELD_SPACING_GROUP];
  const rendered = renderFieldValue(match[FIELD_VALUE_GROUP].trim(), newValue);
  // 関数リプレーサで $ 等の特殊文字混入を防ぐ。
  return frontmatter.replace(re, () => `${key}:${spacing}${rendered}`);
}

/** semver 文字列の patch を +1 する。x.y.z 以外は null。 */
export function bumpPatch(version: string): string | null {
  const parts = version.split(".");
  if (parts.length !== SEMVER_PARTS) return null;
  if (!parts.every((p) => /^[0-9]+$/u.test(p))) return null;
  const patch = Number.parseInt(parts[SEMVER_PATCH_INDEX], 10) + 1;
  return `${parts[SEMVER_MAJOR_INDEX]}.${parts[SEMVER_MINOR_INDEX]}.${String(patch)}`;
}

/**
 * semver の minor を +1 し patch を 0 にする（ACE curate の版上げ方針）。
 * x.y.z 以外は null。
 */
export function bumpMinor(version: string): string | null {
  const parts = version.split(".");
  if (parts.length !== SEMVER_PARTS) return null;
  if (!parts.every((p) => /^[0-9]+$/u.test(p))) return null;
  const minor = Number.parseInt(parts[SEMVER_MINOR_INDEX], 10) + 1;
  return `${parts[SEMVER_MAJOR_INDEX]}.${String(minor)}.0`;
}

/**
 * 本文から `## Changelog` 直下の最新版（最初の `### [x.y.z]`）を取り出す。
 * - Changelog セクションが無い → `{ kind: "absent" }`（呼び出し側では既定でドリフト。
 *   緩和は computeSync の allowMissingChangelog = テスト fixture 専用オプションのみ）
 * - あるが版見出しが無い → `{ kind: "empty" }`（ドリフト扱い）
 * - 見つかった → `{ kind: "found", version, count }`（count = セクション内の版見出し総数。
 *   2 件以上なら「初版以外のエントリがある」= 変更済み文書の機械判定に使う）
 */
export function extractLatestChangelogVersion(
  content: string,
):
  | { readonly kind: "absent" }
  | { readonly kind: "empty" }
  | { readonly kind: "found"; readonly version: string; readonly count: number } {
  const heading = CHANGELOG_HEADING_PATTERN.exec(content);
  if (!heading || heading.index === undefined) {
    return { kind: "absent" };
  }
  const afterHeading = content.slice(heading.index + heading[0].length);
  // 次の `## ...`（### は含めない）までに限定し、後続セクションの版見出しを拾わない
  const nextH2 = NEXT_H2_HEADING_PATTERN.exec(afterHeading);
  const sectionBody =
    nextH2 && nextH2.index !== undefined ? afterHeading.slice(0, nextH2.index) : afterHeading;
  const versionMatch = CHANGELOG_VERSION_HEADING_PATTERN.exec(sectionBody);
  if (!versionMatch) {
    return { kind: "empty" };
  }
  // グローバルフラグ付きの使い捨て正規表現で総数を数える（lastIndex 汚染を避ける）
  const allHeadings = sectionBody.match(
    new RegExp(CHANGELOG_VERSION_HEADING_PATTERN.source, "gmu"),
  );
  return { kind: "found", version: versionMatch[1], count: allHeadings?.length ?? 1 };
}

/**
 * トップレベルのフィールドが読めなかったときの共通診断。
 * 「frontmatter にありません」だけだと、`metadata:` 配下へネストして書いた人が
 * 「書いてあるのに」と受け取る。本スクリプトが見るのはトップレベルだけである旨を
 * 診断そのものへ入れる（Issue #615）。
 */
function missingTopLevelFieldMessage(field: string): string {
  return `トップレベルの ${field} フィールドが frontmatter にありません（\`metadata:\` 配下等へネストされた同名キーは記録として扱いません）。`;
}

/** トップレベルのフィールドを書き換えられなかったときの共通診断。 */
function unwritableTopLevelFieldMessage(field: string): string {
  return `トップレベルの ${field} フィールドを更新できませんでした（\`metadata:\` 配下等へネストされた同名キーは書き換えません）。`;
}

/** changeImpact 違反時の共通エラーメッセージ（check / write 共用）。 */
export function formatChangeImpactViolation(changeImpactValue: string | null): string {
  if (changeImpactValue === null) {
    return (
      "✗ 変更済み（created ≠ updated、または Changelog に複数版）なのに changeImpact が未記録です。\n" +
      "  frontmatter トップレベルへ `changeImpact: low / medium / high`（小文字）を追記してください" +
      "（ACE の版上げは常に minor +1 のため `medium`。`--write` で自動追記できる。" +
      "/ace-curate 4-c / /ace-refine R3-e 参照）。"
    );
  }
  return (
    `✗ changeImpact="${changeImpactValue}" は無効な値です。` +
    "`low` / `medium` / `high` のいずれか（小文字）へ修正してください。"
  );
}

/**
 * `## Changelog` セクション不在時の共通エラーメッセージ（check / write 共用）。
 * 「版見出しが無い」（= セクションはある）とは診断が別なので文言も分ける。
 */
export function formatChangelogAbsent(frontmatterVersion: string | null): string {
  return (
    "✗ `## Changelog` セクションがありません（version 検証が成立しません）。\n" +
    `  frontmatter version=${String(frontmatterVersion ?? "なし")} の一致相手が無いため、` +
    "`## Changelog` を復元し `### [x.y.z] - YYYY-MM-DD` を記載してください" +
    "（`/ace-curate` の 4-d 参照）。\n" +
    "  受理する見出しは行頭の `## Changelog` のみです（レベル 2・大文字小文字は完全一致。" +
    "`### Changelog` や `## changelog` は認識しません）。"
  );
}

/** version↔Changelog 不一致時の共通エラーメッセージ（check / write 共用）。 */
export function formatVersionChangelogMismatch(
  frontmatterVersion: string | null,
  changelogVersion: string | null,
): string {
  return (
    `✗ frontmatter version と Changelog 最新版が一致しません` +
    `（frontmatter ${String(frontmatterVersion ?? "なし")} ≠ Changelog ${String(changelogVersion ?? "版見出しなし")}）。\n` +
    "  `/ace-curate` の 4-d に従い `## Changelog` へ当該版を追記するか、frontmatter version を直してください。"
  );
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}

function unquote(value: string): string {
  const doubleQuoted = /^"(.*)"$/u.exec(value);
  if (doubleQuoted) return doubleQuoted[1];
  const singleQuoted = /^'(.*)'$/u.exec(value);
  return singleQuoted ? singleQuoted[1].replace(/''/gu, "'") : value;
}

function renderFieldValue(originalValue: string, newValue: string): string {
  if (/^".*"$/u.test(originalValue)) {
    return `"${newValue.replace(/"/gu, '\\"')}"`;
  }
  if (/^'.*'$/u.test(originalValue)) {
    return `'${newValue.replace(/'/gu, "''")}'`;
  }
  return newValue;
}

/** YYYY-MM-DD の当日文字列（UTC 非依存でローカル日付）。 */
function todayIsoDate(): string {
  const now = new Date();
  const yyyy = String(now.getFullYear()).padStart(YEAR_PAD_WIDTH, "0");
  const mm = String(now.getMonth() + JAVASCRIPT_MONTH_OFFSET).padStart(MONTH_DAY_PAD_WIDTH, "0");
  const dd = String(now.getDate()).padStart(MONTH_DAY_PAD_WIDTH, "0");
  return `${yyyy}-${mm}-${dd}`;
}

function isIsoDateString(value: string): boolean {
  if (!ISO_DATE_PATTERN.test(value)) return false;
  const parts = value.split("-");
  if (parts.length !== ISO_DATE_PARTS) return false;
  const year = Number.parseInt(parts[ISO_DATE_YEAR_INDEX], 10);
  const month = Number.parseInt(parts[ISO_DATE_MONTH_INDEX], 10);
  const day = Number.parseInt(parts[ISO_DATE_DAY_INDEX], 10);
  const date = new Date(year, month - JAVASCRIPT_MONTH_OFFSET, day);
  return (
    date.getFullYear() === year &&
    date.getMonth() === month - JAVASCRIPT_MONTH_OFFSET &&
    date.getDate() === day
  );
}

/**
 * countActualEntries の結果。ok を判別子とする discriminated union。
 * 名前付き型にすることで `ok` 判定後の `total` / `message` 参照が型安全に絞れる。
 */
export type CountActualEntriesResult =
  | { readonly ok: true; readonly total: number }
  | { readonly ok: false; readonly message: string };

/**
 * PLAYBOOK 本文 + playbook/ 分割ファイル群から実エントリ数を数える。
 * check-category-size と同一ロジックを再利用し、ゲートとカウンタの二重定義を避ける。
 */
export function countActualEntries(
  mainContent: string,
  subfileContents: readonly string[],
): CountActualEntriesResult {
  const hasSubfiles = subfileContents.length > 0;
  const analyses: AnalyzeSuccess[] = [];

  const mainAnalyzed = analyzePlaybookMarkdown(mainContent, { allowEmpty: hasSubfiles });
  if (mainAnalyzed.kind === "error") {
    return { ok: false, message: mainAnalyzed.message };
  }
  analyses.push(mainAnalyzed);

  for (const sub of subfileContents) {
    const analyzed = analyzePlaybookMarkdown(sub, { allowEmpty: true });
    if (analyzed.kind === "error") {
      return { ok: false, message: analyzed.message };
    }
    analyses.push(analyzed);
  }

  const merged = mergeAnalyses(analyses);
  if (merged.kind === "error") {
    return { ok: false, message: merged.message };
  }
  if (merged.totalEntries === 0) {
    return { ok: false, message: "ACE エントリ見出し（### ACE-数字:）が見つかりません。" };
  }
  return { ok: true, total: merged.totalEntries };
}

/**
 * 純粋関数版の同期ロジック。ファイル I/O をせず、内容と実数から結果を導出する。
 * テストしやすいよう、集計済みの実エントリ数を引数で受け取る。
 * SyncOptions は check/write の discriminated union で、write=false 時に
 * bumpVersion や updatedDate を渡す不正状態を型で禁止する。
 */
export function computeSync(
  content: string,
  actualCount: number,
  options: SyncOptions = {},
): SyncResult {
  const split = splitFrontmatter(content);
  if (!split) {
    return { kind: "error", message: "frontmatter が見つかりません（先頭が '---' で始まる YAML ブロックが必要です）。" };
  }

  // トップレベルの同名キー重複は「読んだ行」と「書いた行」がずれるため先に拒否する。
  for (const key of MANAGED_TOP_LEVEL_FIELDS) {
    const occurrences = countTopLevelFieldOccurrences(split.frontmatter, key);
    if (occurrences > 1) {
      return {
        kind: "error",
        message: `${key} が frontmatter のトップレベルに ${String(occurrences)} 回あります。YAML は後勝ちですが本スクリプトは最初の 1 行を書き換えるため、読み取りと書き込みがずれます。1 つに統合してください。`,
      };
    }
  }

  const recordedRaw = readTopLevelField(split.frontmatter, COUNT_FIELD);
  const recordedCount = recordedRaw !== null && /^[0-9]+$/u.test(recordedRaw) ? Number.parseInt(recordedRaw, 10) : null;
  const inSync = recordedCount === actualCount;

  // Changelog 情報は本文側なので frontmatter 編集の前に一度だけ抽出する
  // （version↔Changelog 一致と「変更済み文書」判定の両方で使う）
  const changelogExtract = extractLatestChangelogVersion(content);
  const changelogVersionCount = changelogExtract.kind === "found" ? changelogExtract.count : 0;

  const changes: FieldChange[] = [];
  let frontmatter = split.frontmatter;

  // 1) ace_entry_count を実数へ
  if (recordedCount !== actualCount) {
    const replaced = replaceTopLevelField(frontmatter, COUNT_FIELD, String(actualCount));
    if (replaced === null) {
      return { kind: "error", message: missingTopLevelFieldMessage(COUNT_FIELD) };
    }
    changes.push({ field: COUNT_FIELD, from: recordedRaw, to: String(actualCount) });
    frontmatter = replaced;
  }

  // 2) updated を当日（または指定日）へ（write 時のみ意味を持つが、あるべき姿として反映）
  if (options.write === true) {
    const targetDate = options.updatedDate ?? todayIsoDate();
    if (!isIsoDateString(targetDate)) {
      return { kind: "error", message: `updatedDate="${targetDate}" は YYYY-MM-DD 形式ではありません。` };
    }
    const currentUpdated = readTopLevelField(frontmatter, UPDATED_FIELD);
    if (currentUpdated === null) {
      return { kind: "error", message: missingTopLevelFieldMessage(UPDATED_FIELD) };
    }
    if (currentUpdated !== targetDate) {
      const replaced = replaceTopLevelField(frontmatter, UPDATED_FIELD, targetDate);
      if (replaced === null) {
        return { kind: "error", message: unwritableTopLevelFieldMessage(UPDATED_FIELD) };
      }
      changes.push({ field: UPDATED_FIELD, from: currentUpdated, to: targetDate });
      frontmatter = replaced;
    }

    // 3) version の minor bump（オプトイン。ACE curate 方針: patch は上げない）
    if (options.bumpVersion === true) {
      const currentVersion = readTopLevelField(frontmatter, VERSION_FIELD);
      if (currentVersion === null) {
        return { kind: "error", message: missingTopLevelFieldMessage(VERSION_FIELD) };
      }
      const bumped = bumpMinor(currentVersion);
      if (bumped === null) {
        return { kind: "error", message: `version="${currentVersion}" は semver (x.y.z) ではないため bump できません。` };
      }
      const replaced = replaceTopLevelField(frontmatter, VERSION_FIELD, bumped);
      if (replaced === null) {
        return { kind: "error", message: unwritableTopLevelFieldMessage(VERSION_FIELD) };
      }
      changes.push({ field: VERSION_FIELD, from: currentVersion, to: bumped });
      frontmatter = replaced;
    }

    // 4) changeImpact の自動追記（欠落時のみ。値域違反は自動修正せず後段の検証で報告する）。
    //    updated を動かした後の frontmatter で「変更済み」を判定するため、
    //    write によって created ≠ updated へ遷移するケースも漏れなく対象になる。
    const createdAfterWrite = readTopLevelField(frontmatter, CREATED_FIELD);
    const updatedAfterWrite = readTopLevelField(frontmatter, UPDATED_FIELD);
    if (
      isModifiedDocState(createdAfterWrite, updatedAfterWrite, changelogVersionCount) &&
      readTopLevelField(frontmatter, CHANGE_IMPACT_FIELD) === null
    ) {
      const inserted = insertFieldAfter(
        frontmatter,
        UPDATED_FIELD,
        CHANGE_IMPACT_FIELD,
        DEFAULT_CHANGE_IMPACT,
      );
      if (inserted === null) {
        return {
          kind: "error",
          message: `${CHANGE_IMPACT_FIELD} を追記できませんでした（トップレベルの ${UPDATED_FIELD} 行が見つかりません）。`,
        };
      }
      changes.push({ field: CHANGE_IMPACT_FIELD, from: null, to: DEFAULT_CHANGE_IMPACT });
      frontmatter = inserted;
    }
  }

  // split.rest は閉じ '---' 行から始まる（splitFrontmatter 参照）ため、
  // 先頭境界 + frontmatter + 本文を素直に再結合すれば元の構造を保てる。
  const rebuilt = `${FRONT_BOUNDARY}\n${frontmatter}\n${split.rest}`;

  // version ↔ Changelog 一致（本文側。write で version を上げても Changelog は自動追記しない）
  const frontmatterVersion = readTopLevelField(frontmatter, VERSION_FIELD);
  let changelogVersion: string | null = null;
  let versionChangelogInSync = true;
  if (changelogExtract.kind === "absent") {
    // Issue #615: セクションごと消せば version 検証が永久に効かなくなるため既定でドリフト。
    // 緩和はテスト fixture 専用のオプションでのみ（CLI からは到達しない）。
    versionChangelogInSync = options.allowMissingChangelog === true;
  } else if (changelogExtract.kind === "empty") {
    versionChangelogInSync = false;
  } else {
    changelogVersion = changelogExtract.version;
    versionChangelogInSync = frontmatterVersion !== null && frontmatterVersion === changelogVersion;
  }

  // changeImpact 検証（Issue #289: 値域は /validate-docs の Frontmatter スキーマと同一、
  // 「変更済み」判定は isModifiedDocState の機械判定可能な部分集合）。
  // write モードで updated を当日へ動かし自動追記も終えた後の frontmatter を見るため、
  // 「これから書き込む姿」が created ≠ updated になるケースも漏れなく検出する。
  const createdValue = readTopLevelField(frontmatter, CREATED_FIELD);
  const updatedValue = readTopLevelField(frontmatter, UPDATED_FIELD);
  const changeImpactValue = readTopLevelField(frontmatter, CHANGE_IMPACT_FIELD);
  const isModifiedDoc = isModifiedDocState(createdValue, updatedValue, changelogVersionCount);
  let changeImpactValid = true;
  if (changeImpactValue !== null) {
    // フィールドが存在するなら、変更済みか否かによらず値域（小文字）を検証する
    changeImpactValid = CHANGE_IMPACT_VALUES.has(changeImpactValue);
  } else if (isModifiedDoc) {
    // 変更済みなのに未記録は違反（write モードでは自動追記済みのため、ここへ来るのは check のみ）
    changeImpactValid = false;
  }

  return {
    kind: "ok",
    actualCount,
    recordedCount,
    inSync,
    frontmatterVersion,
    changelogVersion,
    changelogState: changelogExtract.kind,
    versionChangelogInSync,
    changeImpactValue,
    changeImpactValid,
    changes,
    content: rebuilt,
  };
}

type ParsedCliArgs = Readonly<{
  readonly playbookPath?: string;
  readonly write: boolean;
  readonly bumpVersion: boolean;
  readonly error?: string;
}>;

function parseCliArgs(argv: readonly string[]): ParsedCliArgs {
  const args = argv.slice(2);
  const unknownFlags = args.filter((arg) => arg.startsWith("-") && !SUPPORTED_FLAGS.has(arg));
  if (unknownFlags.length > 0) {
    return { write: false, bumpVersion: false, error: `未知のオプション: ${unknownFlags.join(", ")}` };
  }

  const positional = args.filter((arg) => !arg.startsWith("-") && arg.trim() !== "");
  if (positional.length > 1) {
    return { write: false, bumpVersion: false, error: `PLAYBOOK.md のパスは 1 つだけ指定してください: ${positional.join(", ")}` };
  }

  const flags = new Set(args.filter((arg) => arg.startsWith("-")));
  const write = flags.has(FLAG_WRITE);
  const check = flags.has(FLAG_CHECK);
  const bumpVersion = flags.has(FLAG_BUMP_VERSION);
  if (write && check) {
    return { write, bumpVersion, error: `${FLAG_CHECK} と ${FLAG_WRITE} は同時に指定できません。` };
  }
  if (bumpVersion && !write) {
    return { write, bumpVersion, error: `${FLAG_BUMP_VERSION} は ${FLAG_WRITE} と併用してください（check モードでは version を変更しません）。` };
  }

  const fromEnv = process.env.ACE_PLAYBOOK_PATH;
  const playbookPath = positional[0] ?? (fromEnv && fromEnv.trim() !== "" ? fromEnv : undefined);
  const resolvedPlaybookPath = playbookPath ? path.resolve(playbookPath) : undefined;
  return {
    ...(resolvedPlaybookPath === undefined ? {} : { playbookPath: resolvedPlaybookPath }),
    write,
    bumpVersion,
  };
}

/**
 * PLAYBOOK.md を同ディレクトリの一時ファイル経由で置き換える。書き込み失敗（途中で
 * ディスクが尽きる等）でも原本を欠損させないため、`rename` の原子性に乗せる。
 * 一時ファイルは同一ディレクトリに作る（別 FS を跨ぐと rename が EXDEV で失敗する）。
 * 成功時は null、失敗時は診断メッセージを返す。
 */
function writeFileAtomically(targetPath: string, content: string): string | null {
  const tempPath = `${targetPath}.sync-tmp-${String(process.pid)}`;
  try {
    fs.writeFileSync(tempPath, content, "utf8");
    fs.renameSync(tempPath, targetPath);
    return null;
  } catch (error: unknown) {
    // 失敗経路の残骸を残さない。削除自体の失敗は本来の失敗理由を覆い隠すので握る。
    try {
      fs.rmSync(tempPath, { force: true });
    } catch {
      /* 一時ファイルの後始末失敗は原本の状態に影響しないため報告しない */
    }
    return error instanceof Error ? error.message : String(error);
  }
}

/**
 * version↔Changelog 違反の報告先を状態で振り分ける。`absent`（セクションごと無い）を
 * 「Changelog 版見出しなし」と同じ文言で出すと、消えたセクションの復元という実際の
 * 対処が読み手に伝わらない（Issue #615）。
 */
function reportVersionChangelogViolation(result: SyncOk): void {
  if (result.changelogState === "absent") {
    console.error(formatChangelogAbsent(result.frontmatterVersion));
    return;
  }
  console.error(formatVersionChangelogMismatch(result.frontmatterVersion, result.changelogVersion));
}

/**
 * CLI エントリポイント。`argv` から PLAYBOOK.md のパスと `--check` / `--write` /
 * `--bump-version` を解釈し、未指定時は `ACE_PLAYBOOK_PATH` を参照する。
 * `--write` 時の更新日は `ACE_UPDATED_DATE` があればそれを使い、無ければ当日を使う。
 * 終了コードは 0=成功、1=check ドリフト、2=usage/読み込み/解析エラーを表す。
 */
export function main(argv: readonly string[] = process.argv): number {
  const parsed = parseCliArgs(argv);
  if (parsed.error) {
    console.error(parsed.error);
    return EXIT_USAGE_ERROR;
  }
  if (!parsed.playbookPath) {
    console.error("引数に PLAYBOOK.md のパスを渡すか、ACE_PLAYBOOK_PATH を設定してください。");
    return EXIT_USAGE_ERROR;
  }

  const { playbookPath, write, bumpVersion } = parsed;
  let mainContent: string;
  try {
    mainContent = fs.readFileSync(playbookPath, "utf8");
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`読み込み失敗: ${playbookPath}: ${message}`);
    return EXIT_USAGE_ERROR;
  }

  let subfiles: string[];
  try {
    subfiles = discoverPlaybookSubfiles(playbookPath);
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`読み込み失敗: playbook/ ディレクトリの走査に失敗しました: ${message}`);
    return EXIT_USAGE_ERROR;
  }

  const subfileContents: string[] = [];
  for (const sub of subfiles) {
    try {
      subfileContents.push(fs.readFileSync(sub, "utf8"));
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : String(error);
      console.error(`読み込み失敗: ${sub}: ${message}`);
      return EXIT_USAGE_ERROR;
    }
  }

  const counted = countActualEntries(mainContent, subfileContents);
  if (counted.ok === false) {
    console.error(`${playbookPath}: ${counted.message}`);
    return EXIT_USAGE_ERROR;
  }

  const updatedDate = process.env.ACE_UPDATED_DATE;
  const syncOptions: SyncOptions = write
    ? {
        write: true,
        bumpVersion,
        ...(updatedDate === undefined ? {} : { updatedDate }),
      }
    : {};
  const result = computeSync(mainContent, counted.total, syncOptions);
  if (result.kind === "error") {
    console.error(`${playbookPath}: ${result.message}`);
    return EXIT_USAGE_ERROR;
  }

  console.log(`Playbook: ${playbookPath}`);
  console.log(`実エントリ数: ${String(result.actualCount)} / frontmatter 記録値: ${String(result.recordedCount ?? "なし")}`);
  // 「なし」の理由（セクション不在 / 版見出し不在）を出し分ける。両者は対処が違う。
  const changelogSummary =
    result.changelogVersion ??
    (result.changelogState === "absent"
      ? "なし（## Changelog セクションが無い）"
      : "なし（セクションはあるが版見出しが無い）");
  console.log(
    `version: frontmatter=${String(result.frontmatterVersion ?? "なし")} / Changelog最新=${changelogSummary}`,
  );

  if (!write) {
    // check モード: count / version↔Changelog / changeImpact の三点をゲートする
    let failed = false;
    if (result.inSync) {
      console.log("✓ ace_entry_count は実数と一致しています。");
    } else {
      failed = true;
      console.error(
        `✗ ace_entry_count がドリフトしています（記録 ${String(result.recordedCount ?? "なし")} ≠ 実数 ${String(result.actualCount)}）。\n` +
          "  修正するには --write を付けて再実行してください。",
      );
    }
    if (result.versionChangelogInSync) {
      if (result.changelogVersion !== null) {
        console.log("✓ frontmatter version と Changelog 最新版は一致しています。");
      } else {
        // ここへ来るのは allowMissingChangelog を渡した呼び出しだけ（CLI からは到達しない）。
        // 「一致した」と「そもそも検証していない」を CI ログ上で区別できるようにする。
        console.log("- version↔Changelog: 検証スキップ（allowMissingChangelog）");
      }
    } else {
      failed = true;
      reportVersionChangelogViolation(result);
    }
    if (result.changeImpactValid) {
      if (result.changeImpactValue !== null) {
        console.log("✓ changeImpact は記録済みで、値も小文字の値域内です。");
      } else {
        // スキップを CI ログ上可視にする（ゲートが動かなかったのか通ったのかを区別できるように）
        console.log(
          "- changeImpact: 検証スキップ（変更済みと判定される根拠が無いため presence を要求しない）",
        );
      }
    } else {
      failed = true;
      console.error(formatChangeImpactViolation(result.changeImpactValue));
    }
    return failed ? EXIT_DRIFT : EXIT_OK;
  }

  // write モード: frontmatter のみ書き戻す（Changelog 本文は触らない）。
  // version↔Changelog / changeImpact の違反はここでも報告し、誤って「すべて最新」と出さない。
  if (result.changes.length === 0) {
    if (result.versionChangelogInSync && result.changeImpactValid) {
      console.log("✓ 更新は不要でした（すべて最新です）。");
      return EXIT_OK;
    }
    if (!result.versionChangelogInSync) {
      reportVersionChangelogViolation(result);
    }
    if (!result.changeImpactValid) {
      console.error(formatChangeImpactViolation(result.changeImpactValue));
    }
    return EXIT_DRIFT;
  }

  const writeError = writeFileAtomically(playbookPath, result.content);
  if (writeError !== null) {
    console.error(`書き込み失敗: ${playbookPath}: ${writeError}\n  元ファイルは変更していません。`);
    return EXIT_USAGE_ERROR;
  }

  console.log("✓ frontmatter を更新しました:");
  for (const change of result.changes) {
    console.log(`  - ${change.field}: ${String(change.from ?? "なし")} → ${change.to}`);
  }
  if (bumpVersion) {
    console.log(
      "⚠ version を minor+1 しました。続けて `## Changelog` 先頭に `### [x.y.0]` を追記し、" +
        "`npm run ace:check-playbook-frontmatter` で一致を確認してください。",
    );
  }
  let driftAfterWrite = false;
  if (!result.versionChangelogInSync) {
    reportVersionChangelogViolation(result);
    driftAfterWrite = true;
  }
  if (!result.changeImpactValid) {
    console.error(formatChangeImpactViolation(result.changeImpactValue));
    driftAfterWrite = true;
  }
  return driftAfterWrite ? EXIT_DRIFT : EXIT_OK;
}

/**
 * 現在の ES module が CLI として直接実行されたかを判定する。
 * fileURLToPath で URL エンコードを復元し、部分一致による誤起動を防ぐ。
 */
export function isDirectExecution(moduleUrl: string, argvPath: string | undefined): boolean {
  if (!argvPath) return false;
  return path.resolve(fileURLToPath(moduleUrl)) === path.resolve(argvPath);
}

// 直接実行（tsx 経由の CLI）のときのみ自動実行する。テストから import した
// ときは副作用なく関数だけを取り込めるようにする。
if (isDirectExecution(import.meta.url, process.argv[1])) {
  process.exitCode = main();
}
