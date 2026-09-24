// Generates golden fixtures for SwiffsCore by running the upstream
// @pierre/diffs TypeScript sources with Bun.
//
// Usage:
//   PIERRE_DIR=/path/to/pierre OUT_DIR=Tests/SwiffsCoreTests/Fixtures \
//     bun Scripts/fixtures/generate-core-fixtures.ts
//
// PIERRE_DIR must be a checkout of github.com/pierrecomputer/pierre with git
// history available (used as a corpus of real-world patches and file pairs)
// and a node_modules containing `diff@9.0.0`.
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const PIERRE_DIR = process.env.PIERRE_DIR!;
const OUT_DIR = process.env.OUT_DIR!;
const src = join(PIERRE_DIR, 'packages/diffs/src');
const { parsePatchFiles } = await import(join(src, 'utils/parsePatchFiles.ts'));
const { parseDiffFromFile } = await import(join(src, 'utils/parseDiffFromFile.ts'));
const { diffChars, diffWordsWithSpace } = await import(join(PIERRE_DIR, 'node_modules/diff/libesm/index.js'));

mkdirSync(OUT_DIR, { recursive: true });

// Patch headers carry commit author identities; replace them with neutral
// placeholders so fixtures do not embed personal information.
function sanitize(text: string): string {
  return text
    .replace(/^From: .*$/gm, 'From: Fixture Author <author@example.invalid>')
    .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, 'author@example.invalid')
    .replace(/\/Users\/[A-Za-z0-9._-]+/g, '/Users/example');
}

function git(...args: string[]): string {
  return sanitize(gitRaw(...args));
}

function gitRaw(...args: string[]): string {
  return execFileSync('git', ['-C', PIERRE_DIR, ...args], {
    encoding: 'utf8',
    maxBuffer: 1 << 30,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
}

// Deterministic PRNG so fixtures are reproducible.
let seed = 1234567;
function rand(): number {
  seed = (seed * 1103515245 + 12345) & 0x7fffffff;
  return seed / 0x7fffffff;
}

// Skip very large commits (generated fixtures, vendored data).
const commits = git('log', '--format=%H', '-n', '120')
  .trim()
  .split('\n')
  .filter((commit) => {
    const files = git('show', '--format=', '--name-only', commit).trim().split('\n');
    return files.length > 0 && files.length <= 25;
  })
  .slice(0, 60);

// ---------------------------------------------------------------------------
// parsePatchFiles fixtures
const patchCases: { name: string; input: string; cacheKeyPrefix?: string }[] = [];
for (const [index, commit] of commits.slice(0, 40).entries()) {
  let patch = git('format-patch', '-1', '--stdout', commit);
  if (patch.length > 150_000) continue;
  patchCases.push({ name: `format-patch-${index}`, input: patch, cacheKeyPrefix: index % 3 === 0 ? `prefix-${index}` : undefined });
}
for (const [index, commit] of commits.slice(40, 50).entries()) {
  const patch = git('diff', '--no-color', '-M', `${commit}~1`, commit);
  if (patch.length > 150_000) continue;
  patchCases.push({ name: `git-diff-${index}`, input: patch });
}
// Multi-commit patch
patchCases.push({
  name: 'multi-commit',
  input: git('format-patch', '-3', '--stdout', commits[5]),
  cacheKeyPrefix: 'multi',
});
// Plain unified diffs (non-git) produced by `diff -u` style headers.
patchCases.push({
  name: 'unified-plain',
  input: `--- a/file.txt\t2024-01-01\n+++ b/file.txt\t2024-01-02\n@@ -1,3 +1,4 @@\n line one\n-line two\n+line 2\n+line 2.5\n line three\n--- old/other.txt\n+++ new/other.txt\n@@ -5,2 +5,2 @@ function foo() {\n-a\n+b\n c\n`,
});
patchCases.push({
  name: 'no-newline-eof',
  input: `diff --git a/a.txt b/a.txt\nindex 1111111..2222222 100644\n--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,2 @@\n one\n-two\n\\ No newline at end of file\n+two!\n\\ No newline at end of file\n`,
});
patchCases.push({
  name: 'quoted-names',
  input: `diff --git "a/sp ace/\\303\\251t\\303\\251.txt" "b/sp ace/\\303\\251t\\303\\251.txt"\nnew file mode 100644\nindex 0000000..e69de29\n--- /dev/null\n+++ "b/sp ace/\\303\\251t\\303\\251.txt"\n@@ -0,0 +1 @@\n+hello\ndiff --git a/old name.txt b/new name.txt\nsimilarity index 100%\nrename from old name.txt\nrename to new name.txt\ndiff --git a/mode.sh b/mode.sh\nold mode 100644\nnew mode 100755\n`,
});
patchCases.push({
  name: 'count-mismatch',
  input: `diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,5 +1,5 @@\n a\n-b\n+B\n c\n`,
});
patchCases.push({
  name: 'stray-lines',
  input: `diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,3 +1,3 @@\n a\ngarbage\n-b\n+B\n c\n`,
});
patchCases.push({
  name: 'version-trailer',
  input: `From 02a2e4e6806f7e8f3adf685fde57cc773196f206 Mon Sep 17 00:00:00 2001\nFrom: "Patch Fixture" <patch.fixture@example.invalid>\nDate: Tue, 5 May 2026 15:45:50 -0600\nSubject: [PATCH] example patch with version trailer\n\n---\n file.txt | 1 +\n 1 file changed, 1 insertion(+)\n\ndiff --git a/file.txt b/file.txt\nindex 626799f..8c1202a 100644\n--- a/file.txt\n+++ b/file.txt\n@@ -1,2 +1,3 @@\n line one\n+line two\n line three\n-- \n2.52.0\n\n`,
});
patchCases.push({ name: 'demo-diff-patch', input: sanitize(readFileSync(join(PIERRE_DIR, 'apps/demo/src/mocks/diff.patch'), 'utf8')) });
patchCases.push({ name: 'test-file-patch', input: sanitize(readFileSync(join(PIERRE_DIR, 'packages/diffs/test/file.patch'), 'utf8')) });

const originalConsoleError = console.error;
console.error = () => {};
const patchFixtures = patchCases.map((c) => ({
  ...c,
  expected: parsePatchFiles(c.input, c.cacheKeyPrefix),
}));
console.error = originalConsoleError;
writeFileSync(join(OUT_DIR, 'parsePatchFiles.json'), JSON.stringify(patchFixtures));

// ---------------------------------------------------------------------------
// parseDiffFromFile fixtures
type FilePair = { name: string; oldFile: any; newFile: any; options?: any };
const filePairs: FilePair[] = [];
let pairCount = 0;
outer: for (const commit of commits) {
  const changed = git('diff', '--name-only', '--diff-filter=M', `${commit}~1`, commit).trim().split('\n').filter(Boolean);
  for (const path of changed) {
    if (!/\.(ts|tsx|css|md|json|js|yml|html)$/.test(path)) continue;
    let oldContents: string, newContents: string;
    try {
      oldContents = git('show', `${commit}~1:${path}`);
      newContents = git('show', `${commit}:${path}`);
    } catch {
      continue;
    }
    if (oldContents.length + newContents.length > 120_000) continue;
    filePairs.push({
      name: `history-${pairCount}`,
      oldFile: { name: path, contents: oldContents, cacheKey: pairCount % 2 === 0 ? `old-${pairCount}` : undefined },
      newFile: { name: path, contents: newContents, cacheKey: pairCount % 2 === 0 ? `new-${pairCount}` : undefined },
      options: pairCount % 5 === 0 ? { context: 2 } : pairCount % 7 === 0 ? { ignoreWhitespace: true } : undefined,
    });
    if (++pairCount >= 45) break outer;
  }
}

// Synthetic mutations for coverage of blank-line realignment etc.
const baseLines = readFileSync(join(PIERRE_DIR, 'packages/diffs/src/utils/iterateOverDiff.ts'), 'utf8').split('\n');
for (let i = 0; i < 25; i++) {
  const lines = baseLines.slice(0, 120 + Math.floor(rand() * 200));
  const mutated = [...lines];
  const edits = 1 + Math.floor(rand() * 12);
  for (let e = 0; e < edits; e++) {
    const at = Math.floor(rand() * mutated.length);
    const kind = rand();
    if (kind < 0.25) mutated.splice(at, 0, '');
    else if (kind < 0.5) mutated.splice(at, 1);
    else if (kind < 0.75) mutated[at] = (mutated[at] ?? '') + ' // edited';
    else mutated.splice(at, 0, '  const inserted = ' + Math.floor(rand() * 1000) + ';', '');
  }
  const trailing = rand() < 0.3 ? '' : '\n';
  filePairs.push({
    name: `synthetic-${i}`,
    oldFile: { name: 'iterateOverDiff.ts', contents: lines.join('\n') + '\n' },
    newFile: { name: i % 4 === 0 ? 'renamed.ts' : 'iterateOverDiff.ts', contents: mutated.join('\n') + trailing },
  });
}
const edgeCases: [string, string | null, string | null][] = [
  ['empty-to-content', '', 'a\nb\n'],
  ['content-to-empty', 'a\nb\n', ''],
  ['no-trailing-newline', 'a\nb', 'a\nc'],
  ['add-trailing-newline', 'a\nb', 'a\nb\n'],
  ['crlf', 'one\r\ntwo\r\nthree\r\n', 'one\r\n2\r\nthree\r\n'],
  ['unicode', 'héllo wörld\n😀 emoji\nsame\n', 'hello world\n😀 emoji!\nsame\n'],
  ['new-file', null, 'brand\nnew\n'],
  ['deleted-file', 'going\naway\n', null],
  ['blank-lines', 'a\n\n\nb\n', 'a\n\n\n\nb\n'],
  ['large-context', Array.from({ length: 50 }, (_, i) => `line ${i}`).join('\n') + '\n', Array.from({ length: 50 }, (_, i) => (i === 25 ? 'changed' : `line ${i}`)).join('\n') + '\n'],
];
for (const [name, oldContents, newContents] of edgeCases) {
  filePairs.push({
    name,
    oldFile: oldContents == null ? null : { name: 'file.txt', contents: oldContents, lang: name === 'unicode' ? 'markdown' : undefined },
    newFile: newContents == null ? null : { name: 'file.txt', contents: newContents },
  });
}
const fileFixtures = filePairs.map((pair) => ({
  ...pair,
  expected: parseDiffFromFile(pair.oldFile, pair.newFile, pair.options),
}));
writeFileSync(join(OUT_DIR, 'parseDiffFromFile.json'), JSON.stringify(fileFixtures));

// ---------------------------------------------------------------------------
// Intra-line diff fixtures (diffWordsWithSpace / diffChars)
const linePairs: [string, string][] = [
  ['const foo = bar(1, 2);', 'const foo = baz(1, 3);'],
  ['hello world', 'hello  there world'],
  ['a\tb c', 'a b\tc'],
  ['naïve café', 'naive cafe'],
  ['😀 smile', '😃 smile'],
  ['', 'something'],
  ['x', ''],
  ['line\r\nbreak', 'line\nbreak'],
];
for (const pair of fileFixtures.slice(0, 20)) {
  const e = pair.expected;
  for (const hunk of e.hunks) {
    for (const content of hunk.hunkContent) {
      if (content.type !== 'change') continue;
      const n = Math.min(content.additions, content.deletions);
      for (let i = 0; i < n; i++) {
        linePairs.push([
          e.deletionLines[content.deletionLineIndex + i].replace(/\r?\n$/, ''),
          e.additionLines[content.additionLineIndex + i].replace(/\r?\n$/, ''),
        ]);
      }
    }
  }
}
const lineDiffFixtures = linePairs.slice(0, 400).map(([a, b]) => ({
  old: a,
  new: b,
  words: diffWordsWithSpace(a, b).map((c: any) => ({ value: c.value, added: c.added, removed: c.removed, count: c.count })),
  chars: diffChars(a, b).map((c: any) => ({ value: c.value, added: c.added, removed: c.removed, count: c.count })),
}));
writeFileSync(join(OUT_DIR, 'lineDiffs.json'), JSON.stringify(lineDiffFixtures));
console.log(`patches=${patchFixtures.length} filePairs=${fileFixtures.length} lineDiffs=${lineDiffFixtures.length}`);
