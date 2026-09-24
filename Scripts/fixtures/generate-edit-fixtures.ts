// Generates golden fixtures for `trimPatchContext` and the hunk update helpers
// in `updateDiffHunks.ts` by running the upstream @pierre/diffs sources.
//
// Usage:
//   PIERRE_DIR=/path/to/pierre OUT_DIR=Tests/SwiffsCoreTests/Fixtures \
//     bun Scripts/fixtures/generate-edit-fixtures.ts
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const PIERRE_DIR = process.env.PIERRE_DIR!;
const OUT_DIR = process.env.OUT_DIR!;
const src = join(PIERRE_DIR, 'packages/diffs/src');
const { trimPatchContext } = await import(join(src, 'utils/trimPatchContext.ts'));
const { parseDiffFromFile } = await import(join(src, 'utils/parseDiffFromFile.ts'));
const update = await import(join(src, 'utils/updateDiffHunks.ts'));

// trimPatchContext
const buildContext = (count: number, label: string): string[] =>
  Array.from({ length: count }, (_, index) => ` ${label}-${index + 1}`);
const syntheticPatch = [
  'diff --git a/file.txt b/file.txt',
  '--- a/file.txt',
  '+++ b/file.txt',
  '@@ -1,82 +1,84 @@',
  ...buildContext(40, 'h1-before'),
  '-old-1',
  '-old-2',
  '+new-1',
  '+new-2',
  '+new-3',
  '+new-4',
  ...buildContext(40, 'h1-after'),
  '@@ -200,118 +200,117 @@',
  ...buildContext(40, 'h2-before'),
  '+only-add',
  ...buildContext(36, 'h2-middle'),
  '-old-3',
  '-old-4',
  ...buildContext(40, 'h2-after'),
].join('\n');
const patches: [string, string][] = [
  ['synthetic', syntheticPatch],
  ['synthetic-newline', syntheticPatch + '\n'],
  ['synthetic-crlf', syntheticPatch.replaceAll('\n', '\r\n') + '\r\n'],
  ['trim.patch', readFileSync(join(PIERRE_DIR, 'packages/diffs/test/trim.patch'), 'utf8')],
  ['no-newline', '--- a/x\n+++ b/x\n@@ -1,3 +1,3 @@\n a\n-b\n+c\n d\n\\ No newline at end of file\n'],
  ['metadata-only', 'just some text\nwithout hunks\n'],
  ['bad-header', '--- a/x\n+++ b/x\n@@ -a,1 +1 @@\n a\n'],
];
const trims: any[] = [];
for (const [name, patch] of patches) {
  for (const contextSize of [0, 1, 3, 10]) {
    trims.push({ name, patch, contextSize, expected: trimPatchContext(patch, contextSize) });
  }
}

// updateDiffHunks / recomputeDiffHunksForEdit
function numbered(count: number, label = 'line'): string {
  return Array.from({ length: count }, (_, index) => `${label} ${index + 1}\n`).join('');
}
const base = numbered(60);
const changed = base.replace('line 10\n', 'line ten\n').replace('line 40\n', 'line forty\n');
interface Edit {
  name: string;
  apply(lines: string[]): { lines: string[]; changed: number[] };
}
const edits: Edit[] = [
  { name: 'none', apply: (lines) => ({ lines, changed: [] }) },
  {
    name: 'modify-in-hunk',
    apply: (lines) => {
      const next = [...lines];
      next[9] = 'line TEN edited\n';
      return { lines: next, changed: [9] };
    },
  },
  {
    name: 'modify-context-in-hunk',
    apply: (lines) => {
      const next = [...lines];
      next[11] = 'line 12 edited\n';
      return { lines: next, changed: [11] };
    },
  },
  {
    name: 'modify-outside-hunks',
    apply: (lines) => {
      const next = [...lines];
      next[25] = 'line 26 edited\n';
      return { lines: next, changed: [25] };
    },
  },
  {
    name: 'restore-line',
    apply: (lines) => {
      const next = [...lines];
      next[9] = 'line 10\n';
      return { lines: next, changed: [9] };
    },
  },
  {
    name: 'two-hunks',
    apply: (lines) => {
      const next = [...lines];
      next[9] = 'x\n';
      next[39] = 'y\n';
      return { lines: next, changed: [39, 9] };
    },
  },
  {
    name: 'insert-line',
    apply: (lines) => {
      const next = [...lines];
      next.splice(10, 0, 'inserted\n');
      return { lines: next, changed: [10] };
    },
  },
  {
    name: 'delete-line',
    apply: (lines) => {
      const next = [...lines];
      next.splice(10, 1);
      return { lines: next, changed: [10] };
    },
  },
  {
    name: 'remove-last-newline',
    apply: (lines) => {
      const next = [...lines];
      if (next.length === 0) return { lines: next, changed: [] };
      next[next.length - 1] = next[next.length - 1].replace('\n', '');
      return { lines: next, changed: [next.length - 1] };
    },
  },
  {
    name: 'out-of-range',
    apply: (lines) => ({ lines, changed: [500] }),
  },
  { name: 'clear-document', apply: () => ({ lines: [], changed: [0] }) },
  {
    name: 'blank-lines',
    apply: (lines) => ({ lines: ['\n', '\n', ''], changed: [0, 1, 2] }),
  },
  {
    name: 'trailing-editor-blank',
    apply: (lines) => ({ lines: [...lines.slice(0, 50), ''], changed: [50] }),
  },
];
const pairs: [string, string, string][] = [
  ['numbered', base, changed],
  ['tail-change', base, base.replace('line 60\n', 'line sixty\n')],
  ['no-trailing-newline', base.slice(0, -1), changed.slice(0, -1)],
  ['blank-sentinel-collision', ' \n  \n   \n', ''],
];
const updates: any[] = [];
for (const [name, oldContents, newContents] of pairs) {
  for (const context of [3, 1]) {
    for (const edit of edits) {
      const diff = parseDiffFromFile({ name, contents: oldContents }, { name, contents: newContents }, { context });
      const { lines, changed: changedLines } = edit.apply(diff.additionLines);
      // Edits past the end of short files leave holes in the array.
      if (Array.from(lines).some((line) => line == null)) continue;
      const forUpdate = structuredClone(diff);
      forUpdate.additionLines = lines;
      update.updateDiffHunks(forUpdate, changedLines, { context });
      const forEdit = structuredClone(diff);
      forEdit.additionLines = lines;
      const recomputed = update.recomputeDiffHunksForEdit(forEdit, { context });
      updates.push({
        name: `${name}/${edit.name}`,
        oldContents,
        newContents,
        context,
        additionLines: lines,
        changed: changedLines,
        updated: forUpdate,
        recomputedForEdit: { ...forEdit, ...recomputed },
      });
    }
  }
}

writeFileSync(join(OUT_DIR, 'edit.json'), JSON.stringify({ trims, updates }));
console.log(`trims=${trims.length} updates=${updates.length}`);
