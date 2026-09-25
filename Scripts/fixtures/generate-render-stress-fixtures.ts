// Generates stress fixtures for SwiffsHighlight's renderDiff/renderFile: the
// highlight samples in every bundled test language, mutated with Unicode,
// line-ending, whitespace and long-line edge cases, rendered by upstream
// `renderDiffWithHighlighter` / `renderFileWithHighlighter` (Oniguruma engine)
// under rotating options. Output uses the same run format as render.json.
//
// Usage:
//   PIERRE_DIR=/path/to/pierre HIGHLIGHT_FIXTURES=Tests/SwiffsHighlightTests/Fixtures \
//     OUT_DIR=Tests/SwiffsHighlightTests/Fixtures \
//     bun Scripts/fixtures/generate-render-stress-fixtures.ts
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const PIERRE_DIR = process.env.PIERRE_DIR!;
const OUT_DIR = process.env.OUT_DIR!;
const HIGHLIGHT_FIXTURES = process.env.HIGHLIGHT_FIXTURES!;
const src = join(PIERRE_DIR, 'packages/diffs/src');
const { getSharedHighlighter } = await import(join(src, 'highlighter/shared_highlighter.ts'));
const { renderDiffWithHighlighter } = await import(join(src, 'utils/renderDiffWithHighlighter.ts'));
const { renderFileWithHighlighter } = await import(join(src, 'utils/renderFileWithHighlighter.ts'));
const { parseDiffFromFile } = await import(join(src, 'utils/parseDiffFromFile.ts'));
const { getFiletypeFromFileName } = await import(join(src, 'utils/getFiletypeFromFileName.ts'));

// Deterministic PRNG (mulberry32).
let seed = 0x5eed1234;
function random(): number {
  seed = (seed + 0x6d2b79f5) | 0;
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
const pick = <T,>(values: readonly T[]): T => values[Math.floor(random() * values.length)];

const samples: { lang: string; code: string }[] = JSON.parse(readFileSync(join(HIGHLIGHT_FIXTURES, 'highlight.json'), 'utf8'))
  .filter((c: any) => c.name !== 'long-line')
  .map((c: any) => ({ lang: c.lang, code: c.code }));

// Unicode-heavy sources in a few languages.
const unicodeTS = [
  '﻿import { a } from "./ä";',
  '// 👩‍👩‍👧‍👦 family, 🇦🇺 flag, 👍🏽 tone, é (e + U+0301), 漢字テスト, עברית, العربية',
  'const greeting = "Grüße 🌍 — こんにちは";',
  'const zw = "a​b‍c";',
  '\tconst tabbed = 1;\t// tab\tinside',
  'function 変数(x: number) { return x * 2; } // 𝔘𝔫𝔦𝔠𝔬𝔡𝔢',
  'const template = `line ${"🚀".repeat(3)} end`;',
  '    ',
  'export const emoji = ["😀", "😃", "😄", "😁"] as const;',
  '',
].join('\n');
const unicodePy = 'def grüß(名前: str) -> str:\n    """Doc 🎉 docstring"""\n    return f"héllo {名前} 👋"\n\n# комментарий\nprint(grüß("世界"))\n';
const unicodeMd = '# Título 🎯\n\nSome **bold** text with `código` and emoji 🧪.\n\n```ts\nconst x = "✓";\n```\n\n- 項目一\n- item two\n';
samples.push({ lang: 'typescript', code: unicodeTS }, { lang: 'python', code: unicodePy }, { lang: 'markdown', code: unicodeMd });

const EXT: Record<string, string> = {
  typescript: 'ts', tsx: 'tsx', javascript: 'js', jsx: 'jsx', python: 'py', swift: 'swift', rust: 'rs', go: 'go',
  ruby: 'rb', c: 'c', cpp: 'cpp', java: 'java', kotlin: 'kt', bash: 'sh', sql: 'sql', diff: 'diff', xml: 'xml',
  php: 'php', scss: 'scss', toml: 'toml', lua: 'lua', vue: 'vue', csharp: 'cs', haskell: 'hs', zig: 'zig',
  graphql: 'graphql', objc: 'm', css: 'css', markdown: 'md', json: 'json', html: 'html', yaml: 'yaml', text: 'txt',
};
const INSERTS = [
  'const 😀 = "emoji 👩‍💻 zwj";',
  '\t\tindented\twith\ttabs',
  'naïve café — “quotes” ‘single’ …',
  '漢字とかなとカタカナ',
  'é combining and ​ zero width',
  '   ',
  '// ' + 'x'.repeat(78),
  'let long = "' + 'abc 🎉 '.repeat(20) + '";',
];

function mutate(code: string): string {
  const lines = code.split('\n');
  const out: string[] = [];
  for (const line of lines) {
    const r = random();
    if (r < 0.08) continue; // delete
    if (r < 0.18) {
      out.push(pick(INSERTS)); // replace
      continue;
    }
    if (r < 0.26) out.push(pick(INSERTS)); // insert before
    if (r < 0.34 && line.length > 0) {
      // edit within the line
      const at = Math.floor(random() * line.length);
      out.push(line.slice(0, at) + pick(['🙂', 'ü', ' ', '\t', 'X', '(', '"']) + line.slice(at));
      continue;
    }
    out.push(line);
  }
  return out.join('\n');
}

function lineEndings(code: string, kind: number): string {
  if (kind === 1) return code.replace(/\n/g, '\r\n');
  if (kind === 2) return code.split('\n').map((l, i) => (i % 3 === 0 ? l + '\r' : l)).join('\n');
  return code;
}

function longLine(length: number): string {
  let s = 'const long = "';
  while (s.length < length - 2) s += 'wörd ';
  return s.slice(0, length - 2) + '";';
}

const configs = [
  { theme: { dark: 'pierre-dark', light: 'pierre-light' }, lineDiffType: 'word-alt', tokenizeMaxLineLength: 1000, maxLineDiffLength: 1000 },
  { theme: 'github-dark', lineDiffType: 'word', tokenizeMaxLineLength: 80, maxLineDiffLength: 1000 },
  { theme: { dark: 'monokai', light: 'pierre-light' }, lineDiffType: 'char', tokenizeMaxLineLength: 1000, maxLineDiffLength: 40 },
  { theme: { dark: 'github-dark', light: 'github-light' }, lineDiffType: 'none', tokenizeMaxLineLength: 1000, maxLineDiffLength: 1000 },
  { theme: 'catppuccin-latte', lineDiffType: 'word-alt', tokenizeMaxLineLength: 120, maxLineDiffLength: 60 },
];

const langs = new Set<string>(samples.map((s) => s.lang).filter((l) => l !== 'text'));
const highlighter = await getSharedHighlighter({
  themes: ['pierre-dark', 'pierre-light', 'github-dark', 'github-light', 'monokai', 'catppuccin-latte'],
  langs: [...langs],
  preferredHighlighter: 'shiki-wasm',
});

// Flattening matches generate-render-fixtures.ts.
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

const diffCases: any[] = [];
const fileCases: any[] = [];
let index = 0;
for (const sample of samples) {
  for (let variant = 0; variant < 2; variant++) {
    const name = `stress/sample${index}.${EXT[sample.lang] ?? 'txt'}`;
    let oldCode = sample.code;
    let newCode = mutate(sample.code);
    if (index % 5 === 0) newCode += '\n' + longLine(1000) + '\n' + longLine(999) + '\n' + longLine(1001);
    const endings = index % 6 === 1 ? 1 : index % 6 === 4 ? 2 : 0;
    oldCode = lineEndings(oldCode, endings);
    newCode = lineEndings(newCode, endings);
    if (index % 4 === 2) newCode = newCode.replace(/\n+$/, ''); // no final newline
    // Plain text sometimes; otherwise override when the extension does not
    // resolve to the sample's language.
    const lang = index % 17 === 7 ? 'text' : getFiletypeFromFileName(name) !== sample.lang ? sample.lang : undefined;
    const config = configs[index % configs.length];
    const oldFile = { name, contents: oldCode, ...(lang ? { lang } : {}) };
    const newFile = { name, contents: newCode, ...(lang ? { lang } : {}) };
    const diff = parseDiffFromFile(oldFile, newFile);
    const options = { theme: config.theme, useTokenTransformer: false, tokenizeMaxLineLength: config.tokenizeMaxLineLength, lineDiffType: config.lineDiffType, maxLineDiffLength: config.maxLineDiffLength };
    const plain = index % 7 === 3 ? { forcePlainText: true, startingLine: 1, totalLines: 12, expandedHunks: true, collapsedContextThreshold: 1 } : undefined;
    const result = renderDiffWithHighlighter(diff, highlighter, options, plain);
    diffCases.push({
      name: `${sample.lang}#${variant}`,
      diff,
      options: config,
      plain: plain ?? null,
      deletionLines: result.code.deletionLines.map(flattenLine),
      additionLines: result.code.additionLines.map(flattenLine),
    });
    if (variant === 0) {
      const fileConfig = configs[(index + 2) % configs.length];
      const file = newFile;
      const rendered = renderFileWithHighlighter(file, highlighter, { theme: fileConfig.theme, tokenizeMaxLineLength: fileConfig.tokenizeMaxLineLength, useTokenTransformer: false });
      fileCases.push({ name: `${sample.lang}`, file, options: fileConfig, lines: rendered.code.map(flattenLine) });
    }
    index++;
  }
}

// ANSI output (terminal logs) as a file.
const ansi = '\x1b[1;31merror\x1b[0m: something \x1b[32mgreen\x1b[0m\n\x1b[4munderline\x1b[24m plain 🚀\n\x1b[38;5;208m256 color\x1b[0m and \x1b[38;2;10;200;30mtruecolor\x1b[0m\n';
for (const theme of [{ dark: 'pierre-dark', light: 'pierre-light' }, 'github-dark']) {
  const file = { name: 'build.log', contents: ansi, lang: 'ansi' };
  const rendered = renderFileWithHighlighter(file, highlighter, { theme, tokenizeMaxLineLength: 1000, useTokenTransformer: false });
  fileCases.push({ name: 'ansi', file, options: { theme, tokenizeMaxLineLength: 1000 }, lines: rendered.code.map(flattenLine) });
}

writeFileSync(join(OUT_DIR, 'render-stress.json'), JSON.stringify({ styles: styleTable.map((k) => JSON.parse(k)), diffCases, fileCases }));
const lineCount = diffCases.reduce((n, c) => n + c.deletionLines.length + c.additionLines.length, 0) + fileCases.reduce((n, c) => n + c.lines.length, 0);
console.log(`diffCases=${diffCases.length} fileCases=${fileCases.length} lines=${lineCount} langs=${langs.size}`);
