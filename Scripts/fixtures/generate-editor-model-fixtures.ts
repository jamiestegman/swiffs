// Generates golden fixtures for the editor model (`PieceTable`,
// `TextDocument`, `EditStack`) by replaying seeded random operations
// against the upstream @pierre/diffs sources.
//
// Usage:
//   PIERRE_DIR=/path/to/pierre OUT_DIR=Tests/SwiffsEditorTests/Fixtures \
//     bun Scripts/fixtures/generate-editor-model-fixtures.ts
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

const PIERRE_DIR = process.env.PIERRE_DIR!;
const OUT_DIR = process.env.OUT_DIR!;
const editor = join(PIERRE_DIR, 'packages/diffs/src/editor');
const { PieceTable } = await import(join(editor, 'pieceTable.ts'));
const { TextDocument } = await import(join(editor, 'textDocument.ts'));

// Deterministic PRNG (mulberry32).
function rng(seed: number) {
  return () => {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const alphabet = ['a', 'b', ' ', '\n', '\r', '\r\n', 'xy', '😀', 'é', '\t', 'foo', '\n\n', '\r\r\n'];
function randomText(random: () => number, maxPieces: number): string {
  const count = Math.floor(random() * maxPieces);
  let text = '';
  for (let i = 0; i < count; i++) text += alphabet[Math.floor(random() * alphabet.length)];
  return text;
}

function snapshotTable(table: any) {
  const text = table.getText();
  const lines: string[] = [];
  const lineLengths: number[] = [];
  const lineLengthsWithBreak: number[] = [];
  for (let line = 0; line < table.lineCount; line++) {
    lines.push(table.getLineText(line, true));
    lineLengths.push(table.getLineLength(line));
    lineLengthsWithBreak.push(table.getLineLength(line, true));
  }
  const positions: [number, number][] = [];
  for (let offset = 0; offset <= text.length; offset++) {
    const position = table.positionAt(offset);
    positions.push([position.line, position.character]);
  }
  // Raw piece table edits can split surrogate pairs, so text is stored as
  // UTF-16 code units.
  const units = (value: string) => Array.from({ length: value.length }, (_, i) => value.charCodeAt(i));
  return { text: units(text), lineCount: table.lineCount, lines: lines.map(units), lineLengths, lineLengthsWithBreak, positions };
}

// Piece table: random insert/delete/applyEdits sequences.
const pieceTableCases: any[] = [];
for (let seed = 1; seed <= 40; seed++) {
  const random = rng(seed);
  const initial = randomText(random, 12);
  const table = new PieceTable(initial);
  const ops: any[] = [];
  for (let step = 0; step < 25; step++) {
    const length = table.getText().length;
    const kind = random();
    let op: any;
    if (kind < 0.45) {
      op = { type: 'insert', offset: Math.floor(random() * (length + 2)) - 1, text: randomText(random, 4) };
      table.insert(op.text, op.offset);
    } else if (kind < 0.8) {
      op = { type: 'delete', offset: Math.floor(random() * (length + 1)), length: Math.floor(random() * 6) };
      table.delete(op.offset, op.length);
    } else {
      const a = Math.floor(random() * (length + 1));
      const b = Math.floor(random() * (length + 1));
      const start = Math.min(a, b);
      const mid = Math.min(start + Math.floor(random() * 3), length);
      const edits = [
        { start, end: mid, text: randomText(random, 3) },
        { start: Math.min(mid + 1, length), end: Math.min(mid + 1 + Math.floor(random() * 3), length), text: randomText(random, 3) },
      ].filter((edit) => edit.start <= edit.end);
      if (edits.length === 2 && edits[1].start < edits[0].end) edits.pop();
      op = { type: 'applyEdits', edits };
      table.applyEdits(edits);
    }
    op.after = snapshotTable(table);
    ops.push(op);
  }
  pieceTableCases.push({ seed, initial, ops });
}

// Search.
const searchText = 'Foo foo(bar) FOO_baz foo\nfoo.bar = "foo";\r\n  foofoo 😀foo\rend foo';
const searches = [
  { text: 'foo', replaceText: '', caseSensitive: false, wholeWord: false, regex: false },
  { text: 'foo', replaceText: '', caseSensitive: true, wholeWord: false, regex: false },
  { text: 'foo', replaceText: '', caseSensitive: false, wholeWord: true, regex: false },
  { text: 'fo+', replaceText: '', caseSensitive: false, wholeWord: false, regex: true },
  { text: '^foo', replaceText: '', caseSensitive: false, wholeWord: false, regex: true },
  { text: '(?<=\\.)bar', replaceText: '', caseSensitive: false, wholeWord: false, regex: true },
  { text: 'o*', replaceText: '', caseSensitive: false, wholeWord: false, regex: true },
  { text: 'bar)', replaceText: '', caseSensitive: false, wholeWord: false, regex: false },
  { text: 'a\nb', replaceText: '', caseSensitive: false, wholeWord: false, regex: false },
  { text: '[', replaceText: '', caseSensitive: false, wholeWord: false, regex: true },
];
const searchCases = searches.map((params) => ({ params, text: searchText, matches: new PieceTable(searchText).search(params) }));

// Text documents: edits with selections, undo and redo.
const documentCases: any[] = [];
for (let seed = 100; seed < 130; seed++) {
  const random = rng(seed);
  const initial = randomText(random, 10);
  const doc = new TextDocument('file.ts', initial, 'typescript');
  const ops: any[] = [];
  let typingOffset = Math.floor(random() * (initial.length + 1));
  for (let step = 0; step < 30; step++) {
    const kind = random();
    let op: any;
    try {
      if (kind < 0.35) {
        // Typing at a caret (coalescible).
        const text = ['a', 'b', ' ', 'é', '😀'][Math.floor(random() * 5)];
        const position = doc.positionAt(typingOffset);
        const selection = { start: position, end: position, direction: 0 };
        op = { type: 'applyEdits', edits: [{ range: { start: position, end: position }, newText: text }], selectionsBefore: [selection] };
        const change = doc.applyEdits(op.edits, true, op.selectionsBefore);
        op.change = change;
        typingOffset += text.length;
      } else if (kind < 0.5) {
        // Backspace at the caret.
        const end = doc.positionAt(typingOffset);
        const start = doc.positionAt(Math.max(0, typingOffset - 1));
        const selection = { start: end, end, direction: 0 };
        op = { type: 'applyEdits', edits: [{ range: { start, end }, newText: '' }], selectionsBefore: [selection] };
        op.change = doc.applyEdits(op.edits, true, op.selectionsBefore);
        typingOffset = doc.offsetAt(start);
      } else if (kind < 0.7) {
        // Arbitrary replacement, possibly out of range.
        const line = Math.floor(random() * (doc.lineCount + 1)) - (random() < 0.1 ? 1 : 0);
        const character = Math.floor(random() * 6) - (random() < 0.1 ? 1 : 0);
        const endLine = line + Math.floor(random() * 2);
        const endCharacter = Math.floor(random() * 6);
        op = {
          type: 'applyEdits',
          edits: [{ range: { start: { line, character }, end: { line: endLine, character: endCharacter } }, newText: randomText(random, 3) }],
          undoBoundary: random() < 0.2,
        };
        op.change = doc.applyEdits(op.edits, true, undefined, undefined, op.undoBoundary);
        typingOffset = Math.floor(random() * (doc.getText().length + 1));
      } else if (kind < 0.8) {
        op = { type: 'normalizeEol', text: 'a\r\nb\rc\nd' };
        op.result = doc.normalizeEol(op.text);
      } else if (kind < 0.92) {
        op = { type: 'undo' };
        const result = doc.undo();
        op.result = result == null ? null : { change: result[0], selections: result[1] ?? null, selectionEdits: result[3] ?? null };
        typingOffset = Math.floor(random() * (doc.getText().length + 1));
      } else {
        op = { type: 'redo' };
        const result = doc.redo();
        op.result = result == null ? null : { change: result[0], selections: result[1] ?? null, selectionEdits: result[3] ?? null };
        typingOffset = Math.floor(random() * (doc.getText().length + 1));
      }
    } catch (error: any) {
      op = { ...op, error: String(error?.message ?? error) };
    }
    op.after = {
      text: doc.getText(),
      version: doc.version,
      lineCount: doc.lineCount,
      eol: doc.eol,
      canUndo: doc.canUndo,
      canRedo: doc.canRedo,
      undoStack: doc.history.undoStack.map((entry: any) => ({
        forwardEdits: entry.forwardEdits,
        inverseEdits: entry.inverseEdits,
        versionBefore: entry.versionBefore,
        versionAfter: entry.versionAfter,
        coalescingMode: entry.coalescingMode ?? null,
        undoBoundary: entry.undoBoundary ?? null,
      })),
      redoCount: doc.history.redoStack.length,
    };
    ops.push(op);
  }
  documentCases.push({ seed, initial, uri: doc.uri, ops });
}

writeFileSync(join(OUT_DIR, 'editor-model.json'), JSON.stringify({ pieceTableCases, searchCases, documentCases }));
console.log(`pieceTable=${pieceTableCases.length} search=${searchCases.length} documents=${documentCases.length}`);
