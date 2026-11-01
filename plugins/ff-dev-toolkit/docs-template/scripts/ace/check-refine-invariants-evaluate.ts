/**
 * Behavior-preserving split of check-refine-invariants.ts (ADR-080).
 * evaluateRefineInvariants calls facade helpers only from inside the function.
 */
import { isListedInPatterns } from "./ace-refine-report";
import {
  type EntryBlock,
  INDEX_ROW_PATTERN,
  archivedProvenance,
  compactProvenance,
  compactStatusMatches,
  extractComparableBody,
  extractMetaFields,
  firstBlock,
  headingCount,
  isArchivedMergedIntoHref,
  isLiveMergedIntoHref,
  isVariantBCompact,
  mergedIntoHref,
  mergedIntoTarget,
  parseChangelogOperations,
  parseIntegerField,
  resolveMergeSurvivor,
} from "./check-refine-invariants";

export function evaluateRefineInvariants(input: {
  readonly playbookContent: string;
  /**
   * 操作の走査元。省略時は playbookContent。
   * 分割レイアウトでは `playbook/CHANGELOG.md` の内容を渡し、索引行の検査は playbookContent のまま行う。
   */
  readonly changelogContent?: string;
  readonly liveBlocks: readonly EntryBlock[];
  readonly archiveBlocks: readonly EntryBlock[];
  readonly patternsContent: string | null;
}): string[] {
  const ops = parseChangelogOperations(input.changelogContent ?? input.playbookContent);
  const liveIds = new Set(input.liveBlocks.map((b) => b.id));
  const archiveIds = new Set(input.archiveBlocks.map((b) => b.id));
  const mergedSources = new Set(ops.mergedPairs.map((p) => p.source));
  const mergedTargets = new Set(ops.mergedPairs.map((p) => p.target));
  const archivedIdSet = new Set(ops.archivedIds);
  const violations: string[] = [];
  /** 最終統合先の正本ブロック。R3-a で後日アーカイブされた survivor は archive 側が正本になる。 */
  const survivorBlockOf = (survivor: string): EntryBlock | undefined =>
    archivedIdSet.has(survivor)
      ? firstBlock(input.archiveBlocks, survivor)
      : firstBlock(input.liveBlocks, survivor);

  for (const id of ops.compactedIds) {
    if (!archiveIds.has(id)) {
      violations.push(`compact ${id}: Changelog に記載されているが archive に見出しが無い`);
      continue;
    }
    if (headingCount(input.archiveBlocks, id) !== 1) {
      violations.push(
        `compact ${id}: archive 見出しが ${String(headingCount(input.archiveBlocks, id))} 件（一意でない）`,
      );
    }
    const archived = firstBlock(input.archiveBlocks, id);
    if (archived && compactProvenance(archived.text) === null) {
      violations.push(`compact ${id}: archive に Compacted: provenance が無い`);
    }
    if (mergedSources.has(id)) {
      if (liveIds.has(id)) {
        violations.push(`compact ${id}: 後続 merge の統合元なのに live に残っている`);
      }
      continue;
    }
    if (!liveIds.has(id)) {
      // 後日 R3-a でアーカイブされた compact 済みエントリは live に無いのが正常な着地。
      // 解除するのは **live 存続要求だけ**で、archive 一意性・Archived provenance・索引撤去は
      // 下の archive ループが検証する。記録なき消失は従来どおり違反（Issue `#1028`）。
      if (!archivedIdSet.has(id)) {
        violations.push(`compact ${id}: Changelog に記載されているが live に見出しが無い`);
      }
      continue;
    }
    if (headingCount(input.liveBlocks, id) !== 1) {
      violations.push(
        `compact ${id}: live 見出しが ${String(headingCount(input.liveBlocks, id))} 件（一意でない）`,
      );
    }
    const live = firstBlock(input.liveBlocks, id);
    if (!live || !archived) continue;
    const liveMeta = extractMetaFields(live.text);
    const archiveMeta = extractMetaFields(archived.text);
    for (const field of ["Category", "Origin", "Date", "Status"] as const) {
      const matches =
        field === "Status"
          ? compactStatusMatches(liveMeta.Status, archiveMeta.Status)
          : liveMeta[field] === archiveMeta[field];
      if (!matches) {
        violations.push(
          `compact ${id}: ${field} が一致しない（live=${liveMeta[field] ?? "∅"} / archive=${archiveMeta[field] ?? "∅"}）`,
        );
      }
    }
    for (const field of ["Helpful", "Harmful"] as const) {
      const liveValue = parseIntegerField(liveMeta[field]);
      const archiveValue = parseIntegerField(archiveMeta[field]);
      if (liveValue === null || archiveValue === null) {
        violations.push(
          `compact ${id}: ${field} が数値として読めない（live=${liveMeta[field] ?? "∅"} / archive=${archiveMeta[field] ?? "∅"}）`,
        );
      } else if (liveValue < archiveValue) {
        violations.push(
          `compact ${id}: ${field} が archive より減っている（live=${String(liveValue)} / archive=${String(archiveValue)}）`,
        );
      }
    }
    if (isVariantBCompact(archived.text) && !mergedTargets.has(id)) {
      const liveBody = extractComparableBody(live.text);
      const archiveBody = extractComparableBody(archived.text);
      if (liveBody !== archiveBody) {
        violations.push(
          `compact ${id}: 第 2 変種なのに provenance・メタ表を除く本文が live と archive で一致しない`,
        );
      }
    }
  }

  for (const id of ops.archivedIds) {
    if (mergedSources.has(id)) {
      // 統合元は `> Merged into:` + `Status: merged` で終端しており、archive 済みでもある。
      // そこへ `- Archived:` を重ねると終端状態が二重になり、どちらの契約で読むかが決まらない。
      violations.push(
        `archive ${id}: 統合元が Archived としても記録されている（merged と archived は両立しない終端状態）`,
      );
      continue;
    }
    const archiveCount = headingCount(input.archiveBlocks, id);
    if (archiveCount === 0) {
      violations.push(`archive ${id}: Changelog に記載されているが archive に見出しが無い`);
      continue;
    }
    if (archiveCount !== 1) {
      violations.push(
        `archive ${id}: archive 見出しが ${String(archiveCount)} 件（一意でない）`,
      );
    }
    const archived = firstBlock(input.archiveBlocks, id);
    if (archived && archivedProvenance(archived.text) === null) {
      violations.push(`archive ${id}: archive に Archived: provenance が無い`);
    }
    if (liveIds.has(id)) {
      violations.push(`archive ${id}: Archived と記録されているのに live に残っている`);
    }
    if (INDEX_ROW_PATTERN(id).test(input.playbookContent)) {
      violations.push(`archive ${id}: Archived と記録されているのに PLAYBOOK 索引テーブルに残っている`);
    }
  }

  for (const line of ops.malformedArchived) {
    violations.push(
      `archive 行の ID 列が途中で切れている（区切りは , か 、 で、理由は ID 列の後ろの括弧書きに置く）: ${line}`,
    );
  }

  for (const line of ops.malformedPromoted) {
    violations.push(
      `promote 行の ID 列が途中で切れている（区切りは , か 、 で、理由は ID 列の後ろの括弧書きに置く）: ${line}`,
    );
  }

  for (const line of ops.malformedMerged) {
    violations.push(`merge 行が解析できない: ${line}`);
  }

  for (const line of ops.malformedCompacted) {
    violations.push(
      `compact 行の ID 列が読めない（区切りは , か 、 で、注記は括弧書きに置く。括弧の閉じ忘れ・余りと、散文に裸で書いた ID は部分採用しない）: ${line}`,
    );
  }

  for (const line of ops.malformedParenthesisKind) {
    violations.push(
      `Changelog 行の括弧の対応種が食い違っている（開きと閉じを （…） か (…) のどちらかで揃える）: ${line}`,
    );
  }

  for (const line of ops.malformedParentheticalIds) {
    violations.push(
      `Changelog 行が操作を宣言しているのに ID が括弧の中の列挙にしかない（操作対象の ID は括弧の外に書く。括弧書きは理由・注記のためのもの）: ${line}`,
    );
  }

  const helpfulBySurvivor = new Map<string, number>();
  const harmfulBySurvivor = new Map<string, number>();

  for (const pair of ops.mergedPairs) {
    const { source, target } = pair;
    if (liveIds.has(source)) {
      violations.push(`merge ${source} → ${target}: 統合元が live に残っている`);
    }
    if (INDEX_ROW_PATTERN(source).test(input.playbookContent)) {
      violations.push(`merge ${source} → ${target}: 統合元が PLAYBOOK 索引テーブルに残っている`);
    }
    const sourceCount = headingCount(input.archiveBlocks, source);
    if (sourceCount === 0) {
      violations.push(`merge ${source} → ${target}: 統合元が archive に無い`);
      continue;
    }
    if (sourceCount !== 1) {
      violations.push(
        `merge ${source} → ${target}: 統合元の archive 見出しが ${String(sourceCount)} 件（一意でない）`,
      );
    }
    const archivedSource = firstBlock(input.archiveBlocks, source);
    if (!archivedSource) continue;
    const sourceMeta = extractMetaFields(archivedSource.text);
    if (sourceMeta.Status !== "merged") {
      violations.push(
        `merge ${source} → ${target}: archive の Status が merged ではない（${sourceMeta.Status ?? "∅"}）`,
      );
    }
    const pointer = mergedIntoTarget(archivedSource.text);
    if (pointer !== target) {
      violations.push(
        `merge ${source} → ${target}: Merged into のリンク先が ${pointer ?? "∅"}`,
      );
    }
    const href = mergedIntoHref(archivedSource.text);
    if (archivedIdSet.has(target)) {
      // 統合先が後日アーカイブされた chain。着地が archive へ移った以上、ポインタも
      // archive 内の実ブロックへ解決しなければ chain が切れる（Issue `#1028`）。
      const archivedTarget = firstBlock(input.archiveBlocks, target);
      if (
        href === null ||
        archivedTarget === undefined ||
        !isArchivedMergedIntoHref(href, target, archivedSource.filePath, archivedTarget.filePath)
      ) {
        violations.push(
          `merge ${source} → ${target}: 統合先が archive 済みなのに Merged into の href が archive の ${target}（${archivedTarget?.filePath ?? "不在"}）へ解決しない（${href ?? "∅"}）`,
        );
      }
    } else if (href === null || !isLiveMergedIntoHref(href, target)) {
      violations.push(
        `merge ${source} → ${target}: Merged into の href が live の ${target} を指していない（${href ?? "∅"}）`,
      );
    }
    const survivor = resolveMergeSurvivor(target, ops.mergedPairs);
    if (survivor === null) {
      violations.push(`merge ${source} → ${target}: Merged into が循環している`);
      continue;
    }
    // 統合元自身のカウンターが読めるかは survivor がどこに居るかと無関係なので、
    // 分岐より先に確かめる（archive 済み survivor の経路で素通りさせない）。
    const sourceHelpful = parseIntegerField(sourceMeta.Helpful);
    const sourceHarmful = parseIntegerField(sourceMeta.Harmful);
    if (sourceHelpful === null || sourceHarmful === null) {
      violations.push(
        `merge ${source} → ${target}: archive の Helpful/Harmful が数値として読めない（Helpful=${sourceMeta.Helpful ?? "∅"} / Harmful=${sourceMeta.Harmful ?? "∅"}）`,
      );
      // 合算だけを見送り、統合先の構造検査（存在・一意・Status）は続行する。
    }
    // 最終統合先（survivor）は R3-a で後日アーカイブされることがある。その場合の正本は
    // archive 側のブロックで、live 固有の検査（見出し一意 / Status=active）だけが対象外になる。
    // **カウンター合算の下限は survivor がどちらに居ても検証する** — ここを飛ばすと、
    // 統合の根拠だったカウンターが archive で 0 に落ちていても緑で通る（Issue `#1028`）。
    const survivorArchived = archivedIdSet.has(survivor);
    const survivorBlock = survivorBlockOf(survivor);
    if (!survivorBlock) {
      violations.push(
        survivorArchived
          ? `merge ${source} → ${target}: 統合先（最終 ${survivor}）が Archived と記録されているのに archive に無い`
          : `merge ${source} → ${target}: 統合先（最終 ${survivor}）が live に無い`,
      );
      continue;
    }
    const targetMeta = extractMetaFields(survivorBlock.text);
    if (!survivorArchived && headingCount(input.liveBlocks, survivor) !== 1) {
      violations.push(
        `merge ${source} → ${target}: 統合先 ${survivor} の live 見出しが ${String(headingCount(input.liveBlocks, survivor))} 件（一意でない）`,
      );
    }
    // R3-a は verbatim 保全なので Status は archive でも active のまま残る。
    // 所在によらず active を要求する（merged / deprecated は統合先として成立しない）。
    if (targetMeta.Status !== "active") {
      violations.push(
        survivorArchived
          ? `merge ${source} → ${target}: 統合先 ${survivor} の archive Status が active ではない（${targetMeta.Status ?? "∅"}）`
          : `merge ${source} → ${target}: 統合先 ${survivor} の live Status が active ではない（${targetMeta.Status ?? "∅"}）`,
      );
    }
    if (sourceHelpful === null || sourceHarmful === null) continue;
    helpfulBySurvivor.set(
      survivor,
      (helpfulBySurvivor.get(survivor) ?? 0) + sourceHelpful,
    );
    harmfulBySurvivor.set(
      survivor,
      (harmfulBySurvivor.get(survivor) ?? 0) + sourceHarmful,
    );
    const targetHelpful = parseIntegerField(targetMeta.Helpful);
    const targetHarmful = parseIntegerField(targetMeta.Harmful);
    if (targetHelpful === null || targetHelpful < sourceHelpful) {
      violations.push(
        `merge ${source} → ${target}: Helpful 合算下限を満たさない（統合先=${targetMeta.Helpful ?? "∅"} / source=${String(sourceHelpful)}）`,
      );
    }
    if (targetHarmful === null || targetHarmful < sourceHarmful) {
      violations.push(
        `merge ${source} → ${target}: Harmful 合算下限を満たさない（統合先=${targetMeta.Harmful ?? "∅"} / source=${String(sourceHarmful)}）`,
      );
    }
  }

  for (const [survivor, required] of helpfulBySurvivor) {
    const block = survivorBlockOf(survivor);
    if (!block) continue;
    const helpful = parseIntegerField(extractMetaFields(block.text).Helpful);
    if (helpful !== null && helpful < required) {
      violations.push(
        `merge 先 ${survivor}: Helpful が統合元合計 ${String(required)} を下回る（現在値=${String(helpful)}）`,
      );
    }
  }
  for (const [survivor, required] of harmfulBySurvivor) {
    const block = survivorBlockOf(survivor);
    if (!block) continue;
    const harmful = parseIntegerField(extractMetaFields(block.text).Harmful);
    if (harmful !== null && harmful < required) {
      violations.push(
        `merge 先 ${survivor}: Harmful が統合元合計 ${String(required)} を下回る（現在値=${String(harmful)}）`,
      );
    }
  }

  for (const id of ops.promotedIds) {
    if (input.patternsContent === null) {
      violations.push(`promote ${id}: PATTERNS.md が無く収載（本文 + 出典リンク）を検証できない`);
      continue;
    }
    if (!isListedInPatterns(input.patternsContent, id)) {
      violations.push(
        `promote ${id}: PATTERNS.md に「パターン本文 + 出典リンク」の組が無い（Changelog 内の ID 言及だけでは収載と見なさない）`,
      );
    }
  }

  return violations;
}
