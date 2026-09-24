// Generates golden fixtures for `hydratePartialDiff` from the upstream
// @pierre/diffs sources: file pairs are turned into patches, parsed as
// partial diffs and hydrated with the full files.
//
// Usage:
//   PIERRE_DIR=/path/to/pierre OUT_DIR=Tests/SwiffsCoreTests/Fixtures \
//     bun Scripts/fixtures/generate-hydrate-fixtures.ts
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const PIERRE_DIR = process.env.PIERRE_DIR!;
const OUT_DIR = process.env.OUT_DIR!;
const src = join(PIERRE_DIR, 'packages/diffs/src');
const { hydratePartialDiff } = await import(join(src, 'utils/hydratePartialDiff.ts'));
const { getSingularPatch } = await import(join(src, 'utils/getSingularPatch.ts'));
const { createTwoFilesPatch } = await import('diff');

const pairs = JSON.parse(readFileSync(join(OUT_DIR, 'parseDiffFromFile.json'), 'utf8'));
const cases: any[] = [];
for (const pair of pairs) {
  const { oldFile, newFile } = pair;
  if (oldFile == null || newFile == null || oldFile.contents === newFile.contents) continue;
  // Keep the fixture small; large files add no new code paths.
  if (oldFile.contents.length + newFile.contents.length > 12000) continue;
  for (const context of [3, 1]) {
    const patch = createTwoFilesPatch(oldFile.name, newFile.name, oldFile.contents, newFile.contents, undefined, undefined, { context });
    let partial: any;
    try {
      partial = getSingularPatch(patch);
    } catch {
      continue;
    }
    if (!partial?.isPartial) continue;
    let expected: any;
    try {
      expected = hydratePartialDiff('clone', partial, {
        oldFile: { ...oldFile, cacheKey: 'old-key' },
        newFile: { ...newFile, cacheKey: 'new-key' },
      });
    } catch (error: any) {
      expected = { error: String(error?.message ?? error) };
    }
    cases.push({ name: pair.name, patch, oldFile, newFile, expected });
  }
}
writeFileSync(join(OUT_DIR, 'hydrate.json'), JSON.stringify(cases));
console.log(`cases=${cases.length}`);
