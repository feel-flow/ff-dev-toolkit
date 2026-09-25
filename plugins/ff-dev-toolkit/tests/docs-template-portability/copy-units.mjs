// コピー単位の導出と、コピー後の展開前パス検出（verify.mjs から使う純関数。ファイルシステムには
// 触れない — 配置の展開は呼び出し側が expand として渡す）。
//
// MASTER.md が「初期セット外・必要時にコピー」と案内する文書は、利用者が docs/ へ手でコピーして
// 読む。コピーされるのは MASTER.md の指示 1 つ分なので、リンクが解決するかは「その指示で一緒に
// コピーされる範囲」で決まる。
//   - 単位を定義するのは `###` 見出しに「必要時にコピー」を含む節の箇条（`- ` 始まりの行）だけ。
//     箇条の中で「からコピー」の直前までに並ぶ `${CLAUDE_PLUGIN_ROOT}/docs-template/<path>`
//     （`${FF_DEV_TOOLKIT_ROOT}` も同じ）の集合が 1 単位で、区切りは「からコピー」1 回分
//     （相互にリンクする文書は同じ「からコピー」の前へ並べる）。`<path>` が `/` で終わればディレクトリ
//     で、配下の .md をすべて含む
//   - 節の中の箇条が指示を 1 つも持たない（言い回し違い・トークンの書式違い・折り返し）なら赤。
//     手書きの対象リストを持たない代わりに、節へ足した文書が黙って検査から落ちる経路を塞ぐ
//   - 節の外の行と、節の中でも箇条でない行（段落・引用）は本文として読む。本文の「からコピー」は、
//     既存の単位に含まれない文書なら単一の単位になる
//   - 本文の指示が複数ファイルの単位の一部だけを名指ししたら赤（その 1 行に従うと兄弟へのリンクが
//     切れる）。複数の単位や単位の外にまたがる指示・箇条どうしの重なりも赤
// 「からコピー」を伴わない言及（docs-template/README.md を SSOT として指す箇所）は単位にしない。
// expand は「docs-template 相対パス → 含まれる .md の docs-template 相対パス一覧（不在は null）」。

export const copyTokenPattern = /`\$\{(?:CLAUDE_PLUGIN_ROOT|FF_DEV_TOOLKIT_ROOT)\}\/docs-template\/([^`\s]+)`/g;

export function copyUnitsFromMaster(masterText, expand) {
  const result = { units: [], errors: [], sections: 0 };
  const groups = [];
  let inCopySection = false;
  let inFence = false;
  masterText.split("\n").forEach((line, i) => {
    if (/^\s*```/.test(line)) {
      inFence = !inFence;
      return;
    }
    if (inFence) return;
    const headingMatch = line.match(/^(#{1,6}) (.*)$/);
    if (headingMatch) {
      inCopySection = headingMatch[1].length === 3 && headingMatch[2].includes("必要時にコピー");
      if (inCopySection) result.sections += 1;
      return;
    }
    const where = `MASTER.md L${i + 1}`;
    const isBullet = inCopySection && /^\s*- /.test(line);
    let found = 0;
    for (const segment of line.split("からコピー").slice(0, -1)) {
      const paths = [...segment.matchAll(copyTokenPattern)].map((match) => match[1]);
      if (paths.length === 0) continue;
      found += 1;
      groups.push({ paths, defines: isBullet, where });
    }
    if (isBullet && found === 0) {
      result.errors.push(
        `${where}: 「必要時にコピー」節の箇条からコピーの指示を読み取れない（\`\${CLAUDE_PLUGIN_ROOT}/docs-template/<path>\` と「からコピー」の形で書く）`,
      );
    }
  });
  if (result.sections === 0) {
    result.errors.push("`###` 見出しに「必要時にコピー」を含む節が見つからない");
    return result;
  }
  const expandGroup = (group) => {
    const members = new Set();
    for (const path of group.paths) {
      const files = expand(path);
      if (files === null || files.length === 0) {
        result.errors.push(`${group.where}: コピー元 ${path} が配布物に無い（または .md を含まない）`);
        return null;
      }
      files.forEach((file) => members.add(file));
    }
    return members;
  };
  const owner = new Map();
  for (const group of groups.filter((g) => g.defines)) {
    const members = expandGroup(group);
    if (members === null) continue;
    const unit = { where: group.where, members };
    for (const file of members) {
      if (owner.has(file)) {
        result.errors.push(`${group.where}: ${file} が ${owner.get(file).where} の単位にも含まれる（単位が重なる）`);
      } else {
        owner.set(file, unit);
      }
    }
    result.units.push(unit);
  }
  for (const group of groups.filter((g) => !g.defines)) {
    const members = expandGroup(group);
    if (members === null) continue;
    const owners = new Set([...members].map((file) => owner.get(file)));
    if (owners.size === 1 && !owners.has(undefined)) {
      const [unit] = owners;
      if (unit.members.size !== members.size) {
        const rest = [...unit.members].filter((file) => !members.has(file));
        result.errors.push(`${group.where}: ${unit.where} の単位の一部だけをコピーさせている（${rest.join(", ")} が一緒にコピーされない）`);
      }
      continue;
    }
    if (owners.size === 1) {
      const unit = { where: group.where, members };
      members.forEach((file) => owner.set(file, unit));
      result.units.push(unit);
      continue;
    }
    result.errors.push(`${group.where}: 1 つの指示が複数の単位（または単位の外）にまたがる: ${[...members].join(", ")}`);
  }
  return result;
}

// 「必要時にコピー」の文書の展開前パス検出（行番号付き）。コピー先の消費側に docs-template は
// 無いので、`docs-template/` の形に限らずディレクトリ名 `docs-template` の出現を拾う
// （`find docs-template docs` のような引数の形も解決しない）。次の 3 つは正当として除く:
//   - コピー元の案内 `${CLAUDE_PLUGIN_ROOT}/docs-template` / `${FF_DEV_TOOLKIT_ROOT}/docs-template`
//   - URL の中の docs-template（リモートの絶対参照で、消費側の配置に依らず解決する）
//   - 同じ文書がクローン手順（`git clone https://github.com/feel-flow/<repo>.git`）を案内している
//     リポジトリの、クローン相対パス `../<repo>/docs-template/`（読み手の環境で解決する）
const copyLeak = /(?<!_ROOT\}\/)(?<![\w.-])docs-template(?![\w-])/;
export function copyLeakLines(content) {
  return content
    .split("\n")
    .map((line, i) => [i + 1, line])
    .filter(([, line]) => {
      const stripped = line
        .replace(/https?:\/\/[^\s)>\]]+/g, "")
        .replace(/\.\.\/([\w.-]+)\/docs-template\//g, (whole, repo) =>
          content.includes(`git clone https://github.com/feel-flow/${repo}.git`) ? "" : whole,
        );
      return copyLeak.test(stripped);
    });
}
