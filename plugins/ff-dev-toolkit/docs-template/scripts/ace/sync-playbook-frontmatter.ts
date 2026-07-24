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
 *     ドリフトがあれば終了コード 1 を返す（CI ゲート）。`## Changelog` がある場合は
 *     frontmatter `version` と最新 `### [x.y.z]` の一致も検証する。
 *   - `--write`         : `ace_entry_count` を実数へ、`updated` を当日（または
 *     ACE_UPDATED_DATE）へ更新してファイルへ書き戻す（Changelog 本文は書き換えない）。
 *   - `--bump-version`  : `--write` と併用時、`version`（semver）を **minor +1**
 *     し patch を 0 にする（ACE curate の版上げ方針。patch 上げは使わない）。
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

// replaceField の正規表現キャプチャ添字（1=インデント, 2=key: 後の空白, 3=値）。
const FIELD_INDENT_GROUP = 1;
const FIELD_SPACING_GROUP = 2;
const FIELD_VALUE_GROUP = 3;

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

export type FrontmatterField = typeof COUNT_FIELD | typeof UPDATED_FIELD | typeof VERSION_FIELD;

export type FieldChange = Readonly<{
  readonly field: FrontmatterField;
  readonly from: string | null;
  readonly to: string;
}>;

export type SyncCheckOptions = Readonly<{
  /** check モード（既定）。frontmatter へは書き戻さない。 */
  readonly write?: false;
  /** check モードでは version bump を許可しない。 */
  readonly bumpVersion?: never;
  /** check モードでは updated 日付指定を許可しない。 */
  readonly updatedDate?: never;
}>;

export type SyncWriteOptions = Readonly<{
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
   * Changelog セクションが無い fixture では null（検証スキップ）。
   */
  readonly changelogVersion: string | null;
  /**
   * frontmatter version と Changelog 最新版が一致しているか。
   * Changelog が無い場合は true（後方互換: 最小 fixture では検証しない）。
   * Changelog があるのに版見出しが無い / version フィールドが無い場合は false。
   */
  readonly versionChangelogInSync: boolean;
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

/** frontmatter から key の生値（クォート除去済み）を取り出す。無ければ null。 */
export function readField(frontmatter: string, key: string): string | null {
  const re = new RegExp(`^(\\s*)${escapeRegExp(key)}:[ \\t]*(.*)$`, "mu");
  const match = frontmatter.match(re);
  if (!match) return null;
  return unquote(match[2].trim());
}

/**
 * frontmatter の key の値だけを差し替える。クォートの有無・インデントは既存の
 * 形式を踏襲する（コメント・キー順・他フィールドは一切触らない）。
 * key が存在しなければ null（呼び出し側でフィールド欠落として扱う）。
 */
export function replaceField(
  frontmatter: string,
  key: string,
  newValue: string,
): string | null {
  const re = new RegExp(`^(\\s*)${escapeRegExp(key)}:([ \\t]*)(.*)$`, "mu");
  const match = frontmatter.match(re);
  if (!match) return null;
  const indent = match[FIELD_INDENT_GROUP];
  const spacing = match[FIELD_SPACING_GROUP] === "" ? " " : match[FIELD_SPACING_GROUP];
  const rendered = renderFieldValue(match[FIELD_VALUE_GROUP].trim(), newValue);
  // 関数リプレーサで $ 等の特殊文字混入を防ぐ。
  return frontmatter.replace(re, () => `${indent}${key}:${spacing}${rendered}`);
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
 * - Changelog セクションが無い → `{ kind: "absent" }`（fixture 後方互換で検証スキップ）
 * - あるが版見出しが無い → `{ kind: "empty" }`（ドリフト扱い）
 * - 見つかった → `{ kind: "found", version }`
 */
export function extractLatestChangelogVersion(
  content: string,
):
  | { readonly kind: "absent" }
  | { readonly kind: "empty" }
  | { readonly kind: "found"; readonly version: string } {
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
  return { kind: "found", version: versionMatch[1] };
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

  const recordedRaw = readField(split.frontmatter, COUNT_FIELD);
  const recordedCount = recordedRaw !== null && /^[0-9]+$/u.test(recordedRaw) ? Number.parseInt(recordedRaw, 10) : null;
  const inSync = recordedCount === actualCount;

  const changes: FieldChange[] = [];
  let frontmatter = split.frontmatter;

  // 1) ace_entry_count を実数へ
  if (recordedCount !== actualCount) {
    const replaced = replaceField(frontmatter, COUNT_FIELD, String(actualCount));
    if (replaced === null) {
      return { kind: "error", message: `${COUNT_FIELD} フィールドが frontmatter にありません。` };
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
    const currentUpdated = readField(frontmatter, UPDATED_FIELD);
    if (currentUpdated === null) {
      return { kind: "error", message: `${UPDATED_FIELD} フィールドが frontmatter にありません。` };
    }
    if (currentUpdated !== targetDate) {
      const replaced = replaceField(frontmatter, UPDATED_FIELD, targetDate);
      if (replaced === null) {
        return { kind: "error", message: `${UPDATED_FIELD} フィールドを更新できませんでした。` };
      }
      changes.push({ field: UPDATED_FIELD, from: currentUpdated, to: targetDate });
      frontmatter = replaced;
    }

    // 3) version の minor bump（オプトイン。ACE curate 方針: patch は上げない）
    if (options.bumpVersion === true) {
      const currentVersion = readField(frontmatter, VERSION_FIELD);
      if (currentVersion === null) {
        return { kind: "error", message: `${VERSION_FIELD} フィールドが frontmatter にありません。` };
      }
      const bumped = bumpMinor(currentVersion);
      if (bumped === null) {
        return { kind: "error", message: `version="${currentVersion}" は semver (x.y.z) ではないため bump できません。` };
      }
      const replaced = replaceField(frontmatter, VERSION_FIELD, bumped);
      if (replaced === null) {
        return { kind: "error", message: `${VERSION_FIELD} フィールドを更新できませんでした。` };
      }
      changes.push({ field: VERSION_FIELD, from: currentVersion, to: bumped });
      frontmatter = replaced;
    }
  }

  // split.rest は閉じ '---' 行から始まる（splitFrontmatter 参照）ため、
  // 先頭境界 + frontmatter + 本文を素直に再結合すれば元の構造を保てる。
  const rebuilt = `${FRONT_BOUNDARY}\n${frontmatter}\n${split.rest}`;

  // version ↔ Changelog 一致（本文側。write で version を上げても Changelog は自動追記しない）
  const frontmatterVersion = readField(frontmatter, VERSION_FIELD);
  const changelogExtract = extractLatestChangelogVersion(content);
  let changelogVersion: string | null = null;
  let versionChangelogInSync = true;
  if (changelogExtract.kind === "absent") {
    // fixture / 旧テンプレ互換: Changelog が無いときは検証スキップ
    versionChangelogInSync = true;
  } else if (changelogExtract.kind === "empty") {
    versionChangelogInSync = false;
  } else {
    changelogVersion = changelogExtract.version;
    versionChangelogInSync = frontmatterVersion !== null && frontmatterVersion === changelogVersion;
  }

  return {
    kind: "ok",
    actualCount,
    recordedCount,
    inSync,
    frontmatterVersion,
    changelogVersion,
    versionChangelogInSync,
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
  return { playbookPath: playbookPath ? path.resolve(playbookPath) : undefined, write, bumpVersion };
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

  const syncOptions: SyncOptions = write
    ? { write: true, bumpVersion, updatedDate: process.env.ACE_UPDATED_DATE }
    : {};
  const result = computeSync(mainContent, counted.total, syncOptions);
  if (result.kind === "error") {
    console.error(`${playbookPath}: ${result.message}`);
    return EXIT_USAGE_ERROR;
  }

  console.log(`Playbook: ${playbookPath}`);
  console.log(`実エントリ数: ${String(result.actualCount)} / frontmatter 記録値: ${String(result.recordedCount ?? "なし")}`);
  console.log(
    `version: frontmatter=${String(result.frontmatterVersion ?? "なし")} / Changelog最新=${String(result.changelogVersion ?? "なし（セクション無し or 空）")}`,
  );

  if (!write) {
    // check モード: count と version↔Changelog の両方をゲートする
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
      }
    } else {
      failed = true;
      console.error(formatVersionChangelogMismatch(result.frontmatterVersion, result.changelogVersion));
    }
    return failed ? EXIT_DRIFT : EXIT_OK;
  }

  // write モード: frontmatter のみ書き戻す（Changelog 本文は触らない）。
  // version↔Changelog 不一致はここでも報告し、誤って「すべて最新」と出さない。
  if (result.changes.length === 0) {
    if (result.versionChangelogInSync) {
      console.log("✓ 更新は不要でした（すべて最新です）。");
      return EXIT_OK;
    }
    console.error(formatVersionChangelogMismatch(result.frontmatterVersion, result.changelogVersion));
    return EXIT_DRIFT;
  }

  try {
    fs.writeFileSync(playbookPath, result.content, "utf8");
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`書き込み失敗: ${playbookPath}: ${message}`);
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
  if (!result.versionChangelogInSync) {
    console.error(formatVersionChangelogMismatch(result.frontmatterVersion, result.changelogVersion));
    return EXIT_DRIFT;
  }
  return EXIT_OK;
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
