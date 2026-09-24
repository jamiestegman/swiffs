// Generates golden fixtures for iterateOverDiff and virtual layout helpers by
// running the upstream @pierre/diffs sources. Consumes the diff fixtures
// produced by generate-core-fixtures.ts.
//
// Usage:
//   PIERRE_DIR=/path/to/pierre OUT_DIR=Tests/SwiffsCoreTests/Fixtures \
//     bun Scripts/fixtures/generate-layout-fixtures.ts
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const PIERRE_DIR = process.env.PIERRE_DIR!;
const OUT_DIR = process.env.OUT_DIR!;
const src = join(PIERRE_DIR, 'packages/diffs/src');
const { iterateOverDiff } = await import(join(src, 'utils/iterateOverDiff.ts'));
const { computeEstimatedDiffHeights } = await import(join(src, 'utils/computeEstimatedDiffHeights.ts'));
const { isAdditionLineRenderable, getNearestRenderableAdditionLine } = await import(join(src, 'utils/virtualDiffLayout.ts'));

let seed = 424242;
function rand(): number {
  seed = (seed * 1103515245 + 12345) & 0x7fffffff;
  return seed / 0x7fffffff;
}
function pick<T>(items: T[]): T {
  return items[Math.floor(rand() * items.length)];
}

const fileCases = JSON.parse(readFileSync(join(OUT_DIR, 'parseDiffFromFile.json'), 'utf8'));
const patchCases = JSON.parse(readFileSync(join(OUT_DIR, 'parsePatchFiles.json'), 'utf8'));
const diffs: any[] = fileCases.map((c: any) => c.expected);
for (const c of patchCases.slice(0, 15)) {
  for (const p of c.expected) diffs.push(...p.files.slice(0, 2));
}

type Expanded = { kind: 'none' } | { kind: 'all' } | { kind: 'regions'; regions: [number, { fromStart: number; fromEnd: number }][] };
function toJS(expanded: Expanded) {
  if (expanded.kind === 'none') return undefined;
  if (expanded.kind === 'all') return true;
  return new Map(expanded.regions);
}
function randomExpanded(diff: any): Expanded {
  const r = rand();
  if (r < 0.3) return { kind: 'none' };
  if (r < 0.45) return { kind: 'all' };
  const regions: [number, { fromStart: number; fromEnd: number }][] = [];
  for (let i = 0; i <= diff.hunks.length; i++) {
    if (rand() < 0.5) regions.push([i, { fromStart: Math.floor(rand() * 6), fromEnd: Math.floor(rand() * 6) }]);
  }
  return { kind: 'regions', regions };
}

const iterateCases: any[] = [];
const heightCases: any[] = [];
const renderableCases: any[] = [];
for (const [diffIndex, diff] of diffs.entries()) {
  for (let i = 0; i < 6; i++) {
    const diffStyle = pick(['unified', 'split', 'both']);
    const windowed = rand() < 0.6;
    const startingLine = windowed ? Math.floor(rand() * Math.max(1, diff.unifiedLineCount)) : 0;
    const totalLines = windowed ? 1 + Math.floor(rand() * 40) : undefined;
    const expanded = randomExpanded(diff);
    const collapsedContextThreshold = pick([1, 1, 3, 10]);
    const events: any[] = [];
    let error: string | undefined;
    const stopAfter = rand() < 0.15 ? 1 + Math.floor(rand() * 10) : undefined;
    try {
      iterateOverDiff({
        diff,
        diffStyle,
        startingLine,
        totalLines,
        expandedHunks: toJS(expanded),
        collapsedContextThreshold,
        callback: (p: any) => {
          const line = (l: any) => (l == null ? null : [l.unifiedLineIndex, l.splitLineIndex, l.lineIndex, l.lineNumber, l.noEOFCR]);
          events.push([p.hunkIndex, p.hunk == null ? 0 : 1, p.type, p.collapsedBefore, p.collapsedAfter, line(p.deletionLine), line(p.additionLine)]);
          return stopAfter != null && events.length >= stopAfter;
        },
      });
    } catch (e: any) {
      error = String(e.message);
    }
    iterateCases.push({ diffIndex, diffStyle, startingLine, totalLines: totalLines ?? null, expanded, collapsedContextThreshold, stopAfter: stopAfter ?? null, events, error: error ?? null });
  }
  for (let i = 0; i < 2; i++) {
    const metrics = { hunkLineCount: 50, lineHeight: pick([20, 18]), diffHeaderHeight: 44, spacing: 8, ...(rand() < 0.3 ? { paddingTop: 4, paddingBottom: 2, hunkSeparatorHeight: 30 } : {}) };
    const args = {
      fileDiff: diff,
      metrics,
      disableFileHeader: rand() < 0.3,
      hunkSeparators: pick(['simple', 'metadata', 'line-info', 'line-info-basic', 'custom']),
      expandUnchanged: rand() < 0.2,
      expandedHunks: randomExpanded(diff),
      collapsedContextThreshold: pick([1, 3]),
      canHydratePartialDiff: rand() < 0.5,
    };
    let expected: any = null;
    try {
      expected = computeEstimatedDiffHeights({ ...args, expandedHunks: toJS(args.expandedHunks) });
    } catch (e: any) {
      expected = { error: String(e.message) };
    }
    heightCases.push({ diffIndex, ...args, fileDiff: undefined, expected });
  }
  const expanded = randomExpanded(diff);
  const threshold = pick([1, 3]);
  const maxLine = Math.max(diff.additionLines.length + 2, 5);
  const lines: any[] = [];
  for (let ln = 1; ln <= Math.min(maxLine, 400); ln++) {
    let renderable: any, up: any, down: any;
    try {
      renderable = isAdditionLineRenderable({ fileDiff: diff, lineNumber: ln, expandedHunks: toJS(expanded), collapsedContextThreshold: threshold });
      up = getNearestRenderableAdditionLine({ fileDiff: diff, lineNumber: ln, direction: 'up', expandedHunks: toJS(expanded), collapsedContextThreshold: threshold }) ?? null;
      down = getNearestRenderableAdditionLine({ fileDiff: diff, lineNumber: ln, direction: 'down', expandedHunks: toJS(expanded), collapsedContextThreshold: threshold }) ?? null;
    } catch (e: any) {
      renderable = 'error';
    }
    lines.push([renderable, up, down]);
  }
  renderableCases.push({ diffIndex, expanded, collapsedContextThreshold: threshold, lines });
}

writeFileSync(join(OUT_DIR, 'layout.json'), JSON.stringify({ iterateCases, heightCases, renderableCases }));
console.log(`diffs=${diffs.length} iterate=${iterateCases.length} heights=${heightCases.length}`);
