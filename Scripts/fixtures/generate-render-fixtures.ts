// Generates golden fixtures for SwiffsHighlight's renderDiff/renderFile by
// running upstream `renderDiffWithHighlighter` / `renderFileWithHighlighter`
// (Oniguruma engine) and flattening the HAST lines into styled runs.
//
// Usage:
//   PIERRE_DIR=/path/to/pierre CORE_FIXTURES=Tests/SwiffsCoreTests/Fixtures \
//     OUT_DIR=Tests/SwiffsHighlightTests/Fixtures \
//     bun Scripts/fixtures/generate-render-fixtures.ts
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const PIERRE_DIR = process.env.PIERRE_DIR!;
const OUT_DIR = process.env.OUT_DIR!;
const CORE_FIXTURES = process.env.CORE_FIXTURES!;
const src = join(PIERRE_DIR, 'packages/diffs/src');
const { getSharedHighlighter } = await import(join(src, 'highlighter/shared_highlighter.ts'));
const { renderDiffWithHighlighter } = await import(join(src, 'utils/renderDiffWithHighlighter.ts'));
const { renderFileWithHighlighter } = await import(join(src, 'utils/renderFileWithHighlighter.ts'));
const { getFiletypeFromFileName } = await import(join(src, 'utils/getFiletypeFromFileName.ts'));

const fileCases = JSON.parse(readFileSync(join(CORE_FIXTURES, 'parseDiffFromFile.json'), 'utf8'));
const patchCases = JSON.parse(readFileSync(join(CORE_FIXTURES, 'parsePatchFiles.json'), 'utf8'));

const diffs: any[] = fileCases.slice(0, 24).map((c: any) => c.expected);
for (const c of patchCases.slice(0, 6)) for (const p of c.expected) diffs.push(...p.files.slice(0, 2));

const langs = new Set<string>(['typescript', 'css', 'markdown', 'json', 'tsx', 'yaml', 'html', 'javascript']);
for (const d of diffs) {
  langs.add(getFiletypeFromFileName(d.name));
  if (d.prevName) langs.add(getFiletypeFromFileName(d.prevName));
}
langs.delete('text');
const highlighter = await getSharedHighlighter({
  themes: ['pierre-dark', 'pierre-light', 'github-dark', 'monokai'],
  langs: [...langs],
  preferredHighlighter: 'shiki-wasm',
});

function parseStyle(style: string | undefined) {
  const out = { dark: null as string | null, light: null as string | null, color: null as string | null, fs: [0, 0, 0] };
  if (!style) return out;
  const fsBits = (key: string, value: string) => {
    if (key.endsWith('font-style') && value === 'italic') return 1;
    if (key.endsWith('font-weight') && value === 'bold') return 2;
    if (key.endsWith('text-decoration')) return (value.includes('underline') ? 4 : 0) | (value.includes('line-through') ? 8 : 0);
    return 0;
  };
  for (const part of style.split(';')) {
    const idx = part.indexOf(':');
    if (idx < 0) continue;
    const key = part.slice(0, idx).trim();
    const value = part.slice(idx + 1).trim();
    const v = value === 'inherit' ? null : value;
    if (key === '--diffs-token-dark') out.dark = v;
    else if (key === '--diffs-token-light') out.light = v;
    else if (key === 'color') out.color = v;
    else if (key.startsWith('--diffs-token-dark-')) out.fs[0] |= fsBits(key, value);
    else if (key.startsWith('--diffs-token-light-')) out.fs[1] |= fsBits(key, value);
    else out.fs[2] |= fsBits(key, value);
  }
  return out;
}

// Flattens a HAST line into [text, runs] where each run is
// [utf16Length, styleKey, inDiffSpan].
const styleTable: string[] = [];
const styleIndex = new Map<string, number>();
function internStyle(key: string): number {
  let index = styleIndex.get(key);
  if (index == null) {
    index = styleTable.length;
    styleTable.push(key);
    styleIndex.set(key, index);
  }
  return index;
}

function flattenLine(node: any): [string, any[]] | null {
  if (node == null) return null;
  const runs: any[] = [];
  let text = '';
  function walk(n: any, style: string | undefined, diffSpan: boolean) {
    if (n.type === 'text') {
      if (n.value.length === 0) return;
      const s = parseStyle(style);
      const key = JSON.stringify([s.dark, s.light, s.color, s.fs]);
      const last = runs[runs.length - 1];
      if (last && last[1] === key && last[2] === diffSpan) last[0] += n.value.length;
      else runs.push([n.value.length, key, diffSpan]);
      text += n.value;
      return;
    }
    if (n.type !== 'element') return;
    const props = n.properties ?? {};
    const nextStyle = typeof props.style === 'string' && props.style.length > 0 ? props.style : style;
    const nextDiff = diffSpan || props['data-diff-span'] != null;
    for (const c of n.children ?? []) walk(c, nextStyle, nextDiff);
  }
  walk(node, undefined, false);
  if (text === '\n') return ['', []];
  return [text, runs.map(([length, key, diff]) => [length, internStyle(key), diff ? 1 : 0])];
}

const cases: any[] = [];
const configs = [
  { theme: { dark: 'pierre-dark', light: 'pierre-light' }, lineDiffType: 'word-alt' },
  { theme: 'github-dark', lineDiffType: 'word' },
  { theme: { dark: 'monokai', light: 'pierre-light' }, lineDiffType: 'char' },
  { theme: { dark: 'pierre-dark', light: 'pierre-light' }, lineDiffType: 'none' },
];
for (const [index, diff] of diffs.entries()) {
  const config = configs[index % configs.length];
  const options = { theme: config.theme, useTokenTransformer: false, tokenizeMaxLineLength: 1000, lineDiffType: config.lineDiffType, maxLineDiffLength: 1000 };
  const forcePlain = index % 7 === 3;
  const plain = forcePlain ? { forcePlainText: true, startingLine: 2, totalLines: 30, expandedHunks: true, collapsedContextThreshold: 1 } : undefined;
  const result = renderDiffWithHighlighter(diff, highlighter, options, plain);
  cases.push({
    diffIndex: index,
    options: { theme: config.theme, lineDiffType: config.lineDiffType },
    plain: plain ?? null,
    deletionLines: result.code.deletionLines.map(flattenLine),
    additionLines: result.code.additionLines.map(flattenLine),
  });
}

const fileRenderCases: any[] = [];
for (const [index, c] of fileCases.slice(0, 8).entries()) {
  if (c.newFile == null) continue;
  const theme = index % 2 === 0 ? { dark: 'pierre-dark', light: 'pierre-light' } : 'github-dark';
  const result = renderFileWithHighlighter(c.newFile, highlighter, { theme, tokenizeMaxLineLength: 1000, useTokenTransformer: false });
  fileRenderCases.push({ file: c.newFile, theme, lines: result.code.map(flattenLine) });
}

writeFileSync(join(OUT_DIR, 'render.json'), JSON.stringify({ diffCount: diffs.length, styles: styleTable.map((k) => JSON.parse(k)), cases, fileRenderCases }));
console.log(`diffCases=${cases.length} fileCases=${fileRenderCases.length} langs=${[...langs].join(',')}`);
