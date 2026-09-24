// Generates golden fixtures for `editSessionHunks.ts` (live diff hunks while
// the addition side is edited) from the upstream @pierre/diffs sources.
//
// Usage:
//   PIERRE_DIR=/path/to/pierre OUT_DIR=Tests/SwiffsCoreTests/Fixtures \
//     bun Scripts/fixtures/generate-edit-session-fixtures.ts
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

const PIERRE_DIR = process.env.PIERRE_DIR!;
const OUT_DIR = process.env.OUT_DIR!;
const src = join(PIERRE_DIR, 'packages/diffs/src');
const session = await import(join(src, 'utils/editSessionHunks.ts'));
const { parseDiffFromFile } = await import(join(src, 'utils/parseDiffFromFile.ts'));

function rng(seed: number) {
  return () => {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const pool = ['alpha\n', 'beta\n', 'gamma\n', '\n', '\n', '  indented\n', 'delta\n', 'omega\n', '}\n'];
function randomLines(random: () => number, count: number): string[] {
  return Array.from({ length: count }, () => pool[Math.floor(random() * pool.length)]);
}

const cases: any[] = [];
for (let seed = 1; seed <= 120; seed++) {
  const random = rng(seed);
  const oldLines = randomLines(random, 8 + Math.floor(random() * 30));
  let newLines = [...oldLines];
  for (let i = 0; i < 3; i++) {
    const at = Math.floor(random() * newLines.length);
    const kind = random();
    if (kind < 0.4) newLines.splice(at, 0, ...randomLines(random, 1 + Math.floor(random() * 3)));
    else if (kind < 0.7) newLines.splice(at, 1 + Math.floor(random() * 2));
    else newLines[at] = pool[Math.floor(random() * pool.length)];
  }
  const context = [3, 1, 0][seed % 3];
  const diff = parseDiffFromFile({ name: 'f.txt', contents: oldLines.join('') }, { name: 'f.txt', contents: newLines.join('') }, { context });
  const steps: any[] = [];
  const expanded = new Map([[0, { fromStart: 2, fromEnd: 1 }], [1, { fromStart: 1, fromEnd: 3 }]]);
  for (let step = 0; step < 6; step++) {
    const previous = [...diff.additionLines];
    const kind = random();
    let op: any;
    if (kind < 0.35) {
      // Same-line-count edit (content only).
      const lines = [Math.floor(random() * Math.max(1, previous.length))];
      const edited = [...previous];
      for (const line of lines) if (line < edited.length) edited[line] = ['x' + seed + '\n', 'beta\n', '\n', 'zeta\n'][Math.floor(random() * 4)];
      diff.additionLines = edited;
      const previousMap = new Map(lines.map((line) => [line, previous[line]]));
      op = { type: 'changed', lines, previousAdditionLines: [...previousMap.entries()], additionLines: edited };
      op.result = session.applySessionChangedLines(diff, lines, { context }, previousMap) ?? null;
    } else if (kind < 0.8) {
      // Structural edit: insert or delete lines.
      const edited = [...previous];
      const at = Math.floor(random() * (edited.length + 1));
      if (random() < 0.5) edited.splice(at, 0, ...randomLines(random, 1 + Math.floor(random() * 2)));
      else edited.splice(at, 1);
      if (random() < 0.15) edited.push('');
      diff.additionLines = edited;
      op = { type: 'rebuild', additionLines: edited };
      const previousAt = (index: number) => previous[index];
      try {
        op.result = session.rebuildSessionHunks(diff, { context }, previousAt) ?? null;
      } catch (error: any) {
        op.error = String(error?.message ?? error);
        op.diff = JSON.parse(JSON.stringify(diff));
        steps.push(op);
        break;
      }
      if (op.result) op.remappedExpansion = [...session.remapExpandedHunksForRegionChange(expanded, op.result).entries()];
    } else {
      op = { type: 'divergence', result: session.findDivergenceCore(diff.deletionLines, diff.additionLines) ?? null };
    }
    op.diff = JSON.parse(JSON.stringify(diff));
    steps.push(op);
  }
  let anchors: any = null;
  let rebuiltExpansion: any = null;
  // Finish on a plain copy: in-place session mutations can leave objects
  // shared between hunks that a value-semantics port never observes.
  const snapshot = JSON.parse(JSON.stringify(diff));
  Object.keys(diff).forEach((key) => delete (diff as any)[key]);
  Object.assign(diff, snapshot);
  try {
    anchors = session.captureExpansionAnchors(diff, expanded, 4);
  } catch (error: any) {
    anchors = { error: String(error?.message ?? error) };
  }
  const finished = session.finishEditSessionForDiff(diff, { context });
  if (Array.isArray(anchors)) rebuiltExpansion = [...session.rebuildExpansionFromAnchors(diff, anchors).entries()];
  cases.push({ seed, context, oldContents: oldLines.join(''), newContents: newLines.join(''), steps, anchors, finished, finalDiff: JSON.parse(JSON.stringify(diff)), rebuiltExpansion });
}

writeFileSync(join(OUT_DIR, 'edit-session.json'), JSON.stringify(cases));
console.log(`cases=${cases.length} errors=${cases.filter((c) => c.steps.some((s: any) => s.error)).length}`);
