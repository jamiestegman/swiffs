// Generates golden fixtures for the merge conflict utilities
// (`parseMergeConflictDiffFromFile`, `getMergeConflictParseResult`,
// `resolveConflict` and `diffAcceptRejectHunk`) by running the upstream
// @pierre/diffs sources.
//
// Usage:
//   PIERRE_DIR=/path/to/pierre OUT_DIR=Tests/SwiffsCoreTests/Fixtures \
//     bun Scripts/fixtures/generate-merge-conflict-fixtures.ts
import { readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const PIERRE_DIR = process.env.PIERRE_DIR!;
const OUT_DIR = process.env.OUT_DIR!;
const src = join(PIERRE_DIR, 'packages/diffs/src');
const mocks = join(PIERRE_DIR, 'apps/demo/src/mocks');
const { parseMergeConflictDiffFromFile } = await import(join(src, 'utils/parseMergeConflictDiffFromFile.ts'));
const { getMergeConflictParseResult } = await import(join(src, 'utils/getMergeConflictLineTypes.ts'));
const { resolveConflict } = await import(join(src, 'utils/resolveConflict.ts'));
const { diffAcceptRejectHunk } = await import(join(src, 'utils/diffAcceptRejectHunk.ts'));
const { parseDiffFromFile } = await import(join(src, 'utils/parseDiffFromFile.ts'));
const { splitFileContents } = await import(join(src, 'utils/splitFileContents.ts'));

// FNV-1a over UTF-16 code units of the lines joined with U+0000, so large
// line arrays stay out of the fixtures.
function hashLines(lines: string[]): string {
  let hash = 0x811c9dc5;
  for (let i = 0; i < lines.length; i++) {
    const line = i === 0 ? lines[i] : '\u0000' + lines[i];
    for (let j = 0; j < line.length; j++) {
      hash ^= line.charCodeAt(j);
      hash = Math.imul(hash, 0x01000193) >>> 0;
    }
  }
  return `${lines.length}:${hash.toString(16)}`;
}

function digest(diff: any) {
  const { deletionLines, additionLines, ...rest } = diff;
  return { ...rest, deletionLines: hashLines(deletionLines), additionLines: hashLines(additionLines) };
}

// Cuts a conflict file at the first line boundary past `limit` lines that is
// outside of any conflict.
function truncateBalanced(contents: string, limit: number): string {
  const lines = splitFileContents(contents);
  let depth = 0;
  for (let i = 0; i < lines.length; i++) {
    if (/^<{7}/.test(lines[i])) depth++;
    else if (/^>{7}/.test(lines[i])) depth = Math.max(0, depth - 1);
    if (i + 1 >= limit && depth === 0) return lines.slice(0, i + 1).join('');
  }
  return contents;
}

const inputs: { name: string; contents: string }[] = [
  { name: 'fileConflict.ts', contents: readFileSync(join(mocks, 'fileConflict.txt'), 'utf8') },
  { name: 'fileConflictLarge.ts', contents: truncateBalanced(readFileSync(join(mocks, 'fileConflictLarge.txt'), 'utf8'), 2500) },
  {
    name: 'simple.txt',
    contents: 'a\nb\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> branch\nc\nd\n',
  },
  {
    name: 'diff3.txt',
    contents: '1\n2\n3\n<<<<<<< ours\nx\ny\n||||||| base\nbase\n=======\nz\n>>>>>>> theirs\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n<<<<<<< ours\n=======\nadded\n>>>>>>> theirs\n17\n',
  },
  {
    name: 'whole-file.txt',
    contents: '<<<<<<< HEAD\none\ntwo\n=======\nthree\n>>>>>>> other',
  },
  {
    name: 'empty-sides.txt',
    contents: 'top\n<<<<<<< HEAD\n=======\n>>>>>>> other\nbottom\n<<<<<<< HEAD\nonly ours\n=======\n>>>>>>> other\n',
  },
  {
    name: 'adjacent.txt',
    contents: '<<<<<<< a\n1\n=======\n2\n>>>>>>> b\n<<<<<<< a\n3\n=======\n4\n>>>>>>> b\nctx\n<<<<<<< a\n5\n=======\n6\n>>>>>>> b\n',
  },
  {
    name: 'crlf.txt',
    contents: 'a\r\n<<<<<<< HEAD\r\nours\r\n=======\r\ntheirs\r\n>>>>>>> b\r\nz\r\n',
  },
  {
    name: 'nested-and-unclosed.txt',
    contents: 'a\n<<<<<<< outer\n<<<<<<< inner\nx\n=======\ny\n>>>>>>> inner\n=======\nz\n>>>>>>> outer\nb\n<<<<<<< dangling\nq\n',
  },
  {
    name: 'long-markers.txt',
    contents: '<<<<<<<<<< HEAD\nours\n==========\ntheirs\n>>>>>>>>>>\n<<<<<<<no-space\n=======x\n>>>>>>>\n',
  },
  {
    name: 'no-conflicts.txt',
    contents: 'just\nplain\ntext\n',
  },
];

const contextCases: (number | null)[] = [0, 1, 2, 3, 6, 10, null];
const cases: any[] = [];
for (const input of inputs) {
  const lines = splitFileContents(input.contents);
  const lineResult = getMergeConflictParseResult(lines);
  const parses: any[] = [];
  for (const context of contextCases) {
    let result: any;
    try {
      result = parseMergeConflictDiffFromFile(input, context ?? Infinity);
    } catch (error: any) {
      parses.push({ maxContextLines: context, error: String(error?.message ?? error) });
      continue;
    }
    const resolutions: any[] = [];
    const isLarge = input.name === 'fileConflictLarge.ts';
    result.actions.forEach((action: any, index: number) => {
      if (action == null) return;
      if (isLarge && index % 7 !== 0 && index !== result.actions.length - 1) return;
      for (const type of ['current', 'incoming', 'both']) {
        let resolved: any;
        try {
          resolved = digest(resolveConflict(result.fileDiff, action, type));
        } catch (error: any) {
          resolved = { error: String(error?.message ?? error) };
        }
        resolutions.push({ actionIndex: index, type, resolved });
      }
    });
    parses.push({
      maxContextLines: context,
      fileDiff: digest(result.fileDiff),
      currentFile: { ...result.currentFile, contents: hashLines([result.currentFile.contents]) },
      incomingFile: { ...result.incomingFile, contents: hashLines([result.incomingFile.contents]) },
      actions: result.actions.map((action: any) => action ?? null),
      markerRows: result.markerRows,
      resolutions,
    });
  }
  cases.push({ file: input, lineTypes: lineResult.lineTypes, regions: lineResult.regions, parses });
}

// diffAcceptRejectHunk over regular diffs.
const pairs: [string, string, string][] = [
  ['mocks.ts', readFileSync(join(mocks, 'fileOld.txt'), 'utf8'), readFileSync(join(mocks, 'fileNew.txt'), 'utf8')],
  ['small.txt', 'a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn\n', 'a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nM\nn\nextra\n'],
  ['eof.txt', 'one\ntwo', 'one\nthree\n'],
  ['delete-all.txt', 'x\ny\n', ''],
  ['add-all.txt', '', 'x\ny\n'],
];
const acceptReject: any[] = [];
for (const [name, oldContents, newContents] of pairs) {
  const isLarge = name === 'mocks.ts';
  for (const context of isLarge ? [3] : [3, null]) {
    const options = context == null ? undefined : { context };
    const diff = parseDiffFromFile({ name, contents: oldContents, cacheKey: `${name}-old` }, { name, contents: newContents, cacheKey: `${name}-new` }, options);
    const results: any[] = [];
    diff.hunks.forEach((hunk: any, hunkIndex: number) => {
      if (isLarge && hunkIndex % 6 !== 0) return;
      for (const type of ['accept', 'reject', 'both']) {
        const run = (changeIndex: number | null) => {
          try {
            const option = changeIndex == null ? type : { type, changeIndex };
            return digest(diffAcceptRejectHunk(diff, hunkIndex, option));
          } catch (error: any) {
            return { error: String(error?.message ?? error) };
          }
        };
        results.push({ hunkIndex, type, changeIndex: null, resolved: run(null) });
        hunk.hunkContent.forEach((content: any, changeIndex: number) => {
          if (content.type !== 'change') return;
          results.push({ hunkIndex, type, changeIndex, resolved: run(changeIndex) });
        });
      }
    });
    acceptReject.push({ name, oldContents, newContents, context, diff: digest(diff), results });
  }
}

// Sequential resolution through `UnresolvedFile.resolveConflict`, which also
// rebuilds the unresolved file text and shifts the remaining actions.
// `UnresolvedFile.ts` itself does not load outside the browser build, so the
// module-level `rebuildFileAndActions` is extracted into a temporary module
// next to it and driven like `UnresolvedFile.resolveConflict` does.
const unresolvedSource = readFileSync(join(src, 'components/UnresolvedFile.ts'), 'utf8');
const helperSource = unresolvedSource.slice(
  unresolvedSource.indexOf('interface RebuildFileAndActionsProps'),
  unresolvedSource.indexOf('function shouldRenderCode')
);
const helperPath = join(src, 'components/__swiffsRebuildFileAndActions.ts');
writeFileSync(
  helperPath,
  `import type { FileContents, FileDiffMetadata, MergeConflictMarkerRow, MergeConflictRegion, MergeConflictResolution } from '../types';
import { buildMergeConflictMarkerRows, type MergeConflictDiffAction } from '../utils/parseMergeConflictDiffFromFile';
import { splitFileContents } from '../utils/splitFileContents';
type ResolveConflictReturn = { file: FileContents; fileDiff: FileDiffMetadata; actions: (MergeConflictDiffAction | undefined)[]; markerRows: MergeConflictMarkerRow[] };
${helperSource}
export { rebuildFileAndActions };
`
);
let rebuildFileAndActions: any;
try {
  ({ rebuildFileAndActions } = await import(helperPath));
} finally {
  unlinkSync(helperPath);
}

function resolveUnresolved(file: any, fileDiff: any, actions: any[], conflictIndex: number, resolution: string) {
  const action = actions[conflictIndex];
  if (fileDiff == null || action == null) return undefined;
  const newFileDiff = resolveConflict(fileDiff, action, resolution);
  const rebuilt = rebuildFileAndActions({
    fileDiff: newFileDiff,
    previousActions: actions,
    resolvedConflictIndex: conflictIndex,
    previousFile: file,
    resolution,
  });
  return { ...rebuilt, fileDiff: newFileDiff };
}

const sequences: any[] = [];
for (const input of inputs) {
  let parsed: any;
  try {
    parsed = parseMergeConflictDiffFromFile(input);
  } catch {
    continue;
  }
  const count = parsed.actions.length;
  if (count === 0 || input.name === 'fileConflictLarge.ts') continue;
  const orders: number[][] = [[...Array(count).keys()], [...Array(count).keys()].reverse()];
  for (const order of orders) {
    for (const type of ['current', 'incoming', 'both']) {
      const file = { ...input, cacheKey: `${input.name}-key` };
      let state: any = { file, ...parseMergeConflictDiffFromFile(file) };
      const steps: any[] = [];
      for (const conflictIndex of order) {
        const result = resolveUnresolved(state.file, state.fileDiff, state.actions, conflictIndex, type);
        if (result == null) {
          steps.push({ conflictIndex, result: null });
          continue;
        }
        state = result;
        steps.push({
          conflictIndex,
          result: {
            file: result.file,
            fileDiff: digest(result.fileDiff),
            actions: result.actions.map((action: any) => action ?? null),
            markerRows: result.markerRows,
          },
        });
      }
      sequences.push({ file, order, type, steps });
    }
  }
}

writeFileSync(join(OUT_DIR, 'merge-conflicts.json'), JSON.stringify({ cases, acceptReject, sequences }));
console.log(`conflictCases=${cases.length} acceptReject=${acceptReject.length} sequences=${sequences.length}`);
