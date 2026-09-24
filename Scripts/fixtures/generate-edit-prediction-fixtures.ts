// Generates golden fixtures for `editor/editPrediction.ts` (edit history
// capture, prediction requests and path patterns) from the upstream sources.
//
// Usage:
//   PIERRE_DIR=/path/to/pierre OUT_DIR=Tests/SwiffsEditorTests/Fixtures \
//     bun Scripts/fixtures/generate-edit-prediction-fixtures.ts
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

const PIERRE_DIR = process.env.PIERRE_DIR!;
const OUT_DIR = process.env.OUT_DIR!;
const editor = join(PIERRE_DIR, 'packages/diffs/src/editor');
const { TextDocument } = await import(join(editor, 'textDocument.ts'));
const { getTextDocumentChangeTransaction } = await import(join(editor, 'textDocumentChangeTransaction.ts'));
const P = await import(join(editor, 'editPrediction.ts'));

function rng(seed: number) {
  return () => {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const lines = ['function add(a, b) {', '  return a + b;', '}', '', 'const x = add(1, 2);', 'console.log(x);', '// é 😀 comment', '\tindented', 'x'.repeat(120)];
const cases: any[] = [];
for (let seed = 1; seed <= 80; seed++) {
  const random = rng(seed);
  const eol = random() < 0.2 ? '\r\n' : '\n';
  const count = 3 + Math.floor(random() * 60);
  const text = Array.from({ length: count }, () => lines[Math.floor(random() * lines.length)]).join(eol) + eol;
  const doc = new TextDocument('file.ts', text, 'typescript');
  let history: any[] = [];
  let at = 1000;
  const steps: any[] = [];
  for (let step = 0; step < 12; step++) {
    const line = Math.floor(random() * doc.lineCount);
    const character = Math.floor(random() * (doc.getLineLength(line) + 1));
    const kind = random();
    const endLine = Math.min(doc.lineCount - 1, line + (kind < 0.2 ? 1 : 0));
    const endCharacter = kind < 0.5 ? character : Math.min(doc.getLineLength(endLine), character + 3);
    const newText = ['a', 'xy', '', eol, 'new line' + eol, '😀'][Math.floor(random() * 6)];
    const edit = { range: { start: { line, character }, end: { line: endLine, character: endCharacter } }, newText };
    at += random() < 0.7 ? 200 : 1500;
    const source = random() < 0.2 ? 'prediction' : 'user';
    let change;
    try {
      change = doc.applyEdits([edit]);
    } catch {
      continue;
    }
    if (change === undefined) continue;
    history = P.recordEditPrediction(history, 'src/file.ts', doc, getTextDocumentChangeTransaction(change), source, at);
    const cursor = doc.offsetAt({ line, character });
    const request = P.buildEditPredictionRequest('src/file.ts', doc, cursor, history, (l: number) => l % 7 !== 3) ?? null;
    steps.push({ edit, source, at, cursor, history: history.map(({ path, hunk, start, end, at, source }: any) => ({ path, hunk, start, end, at, source })), request });
  }
  cases.push({ seed, text, steps });
}

const patterns = ['**/*.ts', 'src/*.ts', 'src/**', '*.md', 'src/?ile.ts', 'src\\\\file.ts', 'a.b', '**/test/**/*.spec.ts'];
const paths = ['src/file.ts', 'file.ts', 'src/deep/file.ts', 'README.md', 'src/pile.ts', 'axb', 'a.b', 'pkg/test/x/y.spec.ts'];
const patternCases = patterns.flatMap((pattern) => paths.map((path) => ({ pattern, path, match: P.matchesEditPredictionPattern(path, pattern) })));

writeFileSync(join(OUT_DIR, 'edit-prediction.json'), JSON.stringify({ cases, patternCases }));
console.log(`cases=${cases.length} patterns=${patternCases.length}`);
