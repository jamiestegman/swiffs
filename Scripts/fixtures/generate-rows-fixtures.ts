// Generates golden fixtures for SwiffsCore's buildDiffRows by driving the
// upstream DiffHunksRenderer.processDiffResult with stub highlight results and
// flattening the gutter/content HAST columns.
//
// Usage:
//   PIERRE_DIR=/path/to/pierre OUT_DIR=Tests/SwiffsCoreTests/Fixtures \
//     bun Scripts/fixtures/generate-rows-fixtures.ts
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const PIERRE_DIR = process.env.PIERRE_DIR!;
const OUT_DIR = process.env.OUT_DIR!;
const src = join(PIERRE_DIR, 'packages/diffs/src');
const { DiffHunksRenderer } = await import(join(src, 'renderers/DiffHunksRenderer.ts'));

const fileCases = JSON.parse(readFileSync(join(OUT_DIR, 'parseDiffFromFile.json'), 'utf8'));
const patchCases = JSON.parse(readFileSync(join(OUT_DIR, 'parsePatchFiles.json'), 'utf8'));
const diffs: any[] = fileCases.map((c: any) => c.expected);
for (const c of patchCases.slice(0, 15)) for (const p of c.expected) diffs.push(...p.files.slice(0, 2));

let seed = 99;
function rand(): number {
  seed = (seed * 1103515245 + 12345) & 0x7fffffff;
  return seed / 0x7fffffff;
}
function pick<T>(items: T[]): T {
  return items[Math.floor(rand() * items.length)];
}

function fakeLine(side: string, index: number) {
  return { type: 'element', tagName: 'div', properties: { 'data-fake': `${side}${index}` }, children: [] };
}

function flattenColumn(gutter: any[] | undefined, content: any[] | undefined) {
  if (gutter == null || content == null) return null;
  if (gutter.length !== content.length) throw new Error(`gutter/content mismatch ${gutter.length} ${content.length}`);
  const out: any[] = [];
  for (let i = 0; i < content.length; i++) {
    const c = content[i];
    const g = gutter[i];
    const p = c.properties ?? {};
    const gp = g.properties ?? {};
    if (p['data-fake'] != null) {
      out.push(['line', p['data-fake'], gp['data-column-number'], gp['data-line-type'], gp['data-line-index']]);
    } else if (p['data-line-annotation'] != null) {
      const slots = (c.children?.[0]?.children ?? []).map((s: any) => s.properties.name);
      out.push(['ann', p['data-line-annotation'], slots, gp['data-line-type'] ?? null]);
    } else if (p['data-separator'] != null) {
      const texts: string[] = [];
      const walk = (n: any) => {
        if (n.type === 'text') texts.push(n.value);
        for (const child of n.children ?? []) walk(child);
      };
      walk(c);
      const text = texts.length > 0 ? texts[0] : null;
      out.push(['sep', p['data-separator'], p['data-expand-index'] ?? null, p['data-separator-first'] != null, p['data-separator-last'] != null, text]);
    } else if (p['data-no-newline'] != null) {
      out.push(['nonl', p['data-line-type']]);
    } else if (p['data-content-buffer'] != null) {
      const last = out[out.length - 1];
      if (last && last[0] === 'buf') last[1] += p['data-buffer-size'];
      else out.push(['buf', p['data-buffer-size']]);
    } else {
      out.push(['unknown', JSON.stringify(p)]);
    }
  }
  return out;
}

const cases: any[] = [];
for (const [diffIndex, diff] of diffs.entries()) {
  for (let variant = 0; variant < 3; variant++) {
    const diffStyle = pick(['split', 'unified']);
    const hunkSeparators = pick(['line-info', 'line-info', 'line-info-basic', 'metadata', 'simple']);
    const expandUnchanged = rand() < 0.15;
    const collapsedContextThreshold = pick([1, 3]);
    const expansionLineCount = pick([100, 5]);
    const canLoadDiffFiles = rand() < 0.3;
    const expanded: [number, { fromStart: number; fromEnd: number }][] = [];
    for (let h = 0; h <= diff.hunks.length; h++) {
      if (rand() < 0.3) expanded.push([h, { fromStart: Math.floor(rand() * 8), fromEnd: Math.floor(rand() * 8) }]);
    }
    const annotations: any[] = [];
    if (rand() < 0.5) annotations.push({ side: 'additions', lineNumber: 0 });
    for (let a = 0; a < 6; a++) {
      const side = pick(['additions', 'deletions']);
      const max = side === 'additions' ? diff.additionLines.length : diff.deletionLines.length;
      if (max > 0) annotations.push({ side, lineNumber: 1 + Math.floor(rand() * max) });
    }
    const renderer = new DiffHunksRenderer({
      theme: { dark: 'pierre-dark', light: 'pierre-light' },
      diffStyle,
      hunkSeparators,
      expandUnchanged,
      collapsedContextThreshold,
      expansionLineCount,
      loadDiffFiles: canLoadDiffFiles ? async () => ({}) : undefined,
      disableFileHeader: true,
    });
    renderer.setLineAnnotations(annotations);
    for (const [h, region] of expanded) renderer.getExpandedHunksMap().set(h, region);
    const code = {
      deletionLines: diff.deletionLines.map((_: any, i: number) => fakeLine('d', i)),
      additionLines: diff.additionLines.map((_: any, i: number) => fakeLine('a', i)),
    };
    let result: any;
    let error: string | null = null;
    try {
      result = renderer.processDiffResult(diff, { startingLine: 0, totalLines: Infinity, bufferBefore: 0, bufferAfter: 0 }, { code, themeStyles: '', baseThemeType: undefined });
    } catch (e: any) {
      error = String(e.message);
    }
    cases.push({
      diffIndex,
      options: { diffStyle, hunkSeparators, expandUnchanged, collapsedContextThreshold, expansionLineCount, canLoadDiffFiles },
      expanded,
      annotations,
      error,
      unified: error ? null : flattenColumn(result.unifiedGutterAST, result.unifiedContentAST),
      deletions: error ? null : flattenColumn(result.deletionsGutterAST, result.deletionsContentAST),
      additions: error ? null : flattenColumn(result.additionsGutterAST, result.additionsContentAST),
      hunkData: error ? null : result.hunkData,
      totalLines: error ? null : result.totalLines,
      rowCount: error ? null : result.rowCount,
    });
  }
}
writeFileSync(join(OUT_DIR, 'rows.json'), JSON.stringify(cases));
console.log(`rowCases=${cases.length}`);
