// Generates golden fixtures for the editor selection logic
// (`editor/selection.ts`) by running seeded random operations against the
// upstream @pierre/diffs sources.
//
// Usage:
//   PIERRE_DIR=/path/to/pierre OUT_DIR=Tests/SwiffsEditorTests/Fixtures \
//     bun Scripts/fixtures/generate-editor-selection-fixtures.ts
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

const PIERRE_DIR = process.env.PIERRE_DIR!;
const OUT_DIR = process.env.OUT_DIR!;
const editor = join(PIERRE_DIR, 'packages/diffs/src/editor');
const { TextDocument } = await import(join(editor, 'textDocument.ts'));
const S = await import(join(editor, 'selection.ts'));

function rng(seed: number) {
  return () => {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const lines = [
  '',
  'const value = 42;',
  '  indented(line) {',
  '\tconst tab = "x";',
  '    four_spaces + more',
  'émoji 😀 and 👍🏽 skin',
  'foo foo_bar foo.baz',
  '    ',
  'a',
  'é combining',
  '  }',
];
function randomDocument(random: () => number): string {
  const count = 1 + Math.floor(random() * 6);
  const eol = random() < 0.2 ? '\r\n' : '\n';
  const parts: string[] = [];
  for (let i = 0; i < count; i++) parts.push(lines[Math.floor(random() * lines.length)]);
  return parts.join(eol) + (random() < 0.5 ? eol : '');
}

function randomPosition(random: () => number, doc: any) {
  const line = Math.floor(random() * doc.lineCount);
  const length = doc.getLineLength(line);
  return { line, character: Math.floor(random() * (length + 1)) };
}

function randomSelections(random: () => number, doc: any) {
  const count = 1 + Math.floor(random() * 3);
  const selections = [];
  for (let i = 0; i < count; i++) {
    const a = randomPosition(random, doc);
    const collapsed = random() < 0.5;
    const b = collapsed ? a : randomPosition(random, doc);
    const order = S.comparePosition(a, b);
    const start = order <= 0 ? a : b;
    const end = order <= 0 ? b : a;
    const direction = order === 0 ? 0 : random() < 0.5 ? 1 : -1;
    selections.push({ start, end, direction });
  }
  return selections;
}

// Soft lines: wrap every 8 UTF-16 units.
function softLineOffsets(doc: any) {
  return (line: number) => {
    const length = doc.getLineLength(line);
    if (length <= 8) return undefined;
    const offsets = [];
    for (let i = 0; i < length; i += 8) offsets.push(i);
    offsets.push(length);
    return offsets;
  };
}

const moves = ['textStart', 'start', 'end', 'up', 'down', 'left', 'right'];
const operations = [
  'move', 'shift', 'typeChar', 'typeNewline', 'replace', 'autoSurround', 'transpose', 'deleteHardLineForward',
  'deleteSoftLineBackward', 'deleteWordBackward', 'deleteBackward', 'deleteForward', 'indent', 'outdent',
  'merge', 'extend', 'lineBlocks', 'findNextMatch', 'selectionText', 'clipboardTexts', 'cut', 'expandWord',
  'remap', 'boundary', 'snap', 'undo',
];

const cases: any[] = [];
for (let seed = 1; seed <= 400; seed++) {
  const random = rng(seed);
  const text = randomDocument(random);
  const doc = new TextDocument('file.ts', text);
  const selections = randomSelections(random, doc);
  const op = operations[seed % operations.length];
  const annotations = [{ lineNumber: 1 + Math.floor(random() * doc.lineCount), metadata: 'a' }, { lineNumber: doc.lineCount, metadata: 'b' }];
  const testCase: any = { seed, text, op, selections, annotations };
  const wrap = random() < 0.5;
  testCase.wrap = wrap;
  const moveOptions = wrap ? { getSoftLineOffsets: softLineOffsets(doc) } : {};
  const recordEdit = (result: any) => {
    testCase.result = {
      nextSelections: result.nextSelections,
      text: doc.getText(),
      startLine: result.change?.startLine ?? null,
      lineDelta: result.change?.lineDelta ?? null,
      undoSelectionsAfter: doc.history.undoStack.at(-1)?.selectionsAfter ?? null,
      lineAnnotationsAfter: doc.history.undoStack.at(-1)?.lineAnnotationsAfter?.map((a: any) => a.lineNumber) ?? null,
    };
  };
  try {
    switch (op) {
      case 'move': {
        const move = moves[Math.floor(random() * moves.length)];
        testCase.move = move;
        testCase.result = S.mapCursorMove(doc, selections, move, moveOptions);
        break;
      }
      case 'shift': {
        const move = moves[Math.floor(random() * moves.length)];
        testCase.move = move;
        testCase.result = S.mapSelectionShift(doc, selections, move, moveOptions);
        break;
      }
      case 'typeChar':
      case 'typeNewline': {
        const primary = selections[selections.length - 1];
        const typed = op === 'typeChar' ? ['x', '😀', '(', ' '][Math.floor(random() * 4)] : '\n';
        testCase.typed = typed;
        const edit = { start: doc.offsetAt(primary.start), end: doc.offsetAt(primary.end), text: typed };
        recordEdit(S.applyTextChangeToSelections(doc, selections, edit, annotations, 2));
        break;
      }
      case 'replace': {
        const texts = selections.map((_: any, i: number) => ['', 'R', 'long text', '\n'][(i + seed) % 4]);
        testCase.texts = texts;
        recordEdit(S.applyTextReplaceToSelections(doc, selections, texts, annotations));
        break;
      }
      case 'autoSurround': {
        const char = ['(', '"', '[', 'x'][seed % 4];
        testCase.char = char;
        testCase.result = S.getAutoSurroundReplacementTexts(doc, selections, char, 'default') ?? null;
        break;
      }
      case 'transpose':
        recordEdit(S.applyTransposeToSelections(doc, selections, annotations));
        break;
      case 'deleteHardLineForward':
        recordEdit(S.applyDeleteHardLineForwardToSelections(doc, selections, annotations));
        break;
      case 'deleteSoftLineBackward':
        recordEdit(S.applyDeleteSoftLineBackwardToSelections(doc, selections, (_line: number, character: number) => Math.floor(character / 8) * 8, annotations));
        break;
      case 'deleteWordBackward':
        recordEdit(S.applyDeleteWordBackwardToSelections(doc, selections, annotations));
        break;
      case 'deleteBackward':
      case 'deleteForward':
        recordEdit(S.applyDeleteCharacterToSelections(doc, selections, op === 'deleteForward', annotations, 4));
        break;
      case 'indent':
      case 'outdent': {
        const [edits, next] = S.resolveIndentEdits(doc, selections[0], 4, op === 'outdent');
        testCase.result = { edits, next };
        break;
      }
      case 'merge':
        testCase.result = S.mergeOverlappingSelections(selections);
        break;
      case 'extend': {
        const target = randomSelections(random, doc)[0];
        testCase.target = target;
        testCase.result = S.extendSelections(selections, target);
        break;
      }
      case 'lineBlocks':
        testCase.result = S.getSelectedLineBlocks(selections);
        break;
      case 'findNextMatch':
        testCase.result = S.findNextMatch(doc, selections) ?? null;
        break;
      case 'selectionText':
        testCase.result = S.getSelectionText(doc, selections);
        break;
      case 'clipboardTexts':
        testCase.result = S.getSelectionClipboardTexts(doc, selections);
        break;
      case 'cut':
        testCase.result = S.resolveSelectionCut(doc, selections);
        break;
      case 'expandWord':
        testCase.result = S.expandCollapsedSelectionToWord(doc, { ...selections[0], end: selections[0].start, direction: 0 });
        break;
      case 'remap': {
        const edits = [{ start: 0, end: Math.min(2, doc.getText().length), text: 'ab😀' }];
        const offsets = selections.map((s: any) => [doc.offsetAt(s.start), doc.offsetAt(s.end)]);
        doc.applyResolvedEdits(edits, false);
        testCase.edits = edits;
        testCase.result = S.remapSelectionsAfterEdits(doc, selections, offsets, edits);
        break;
      }
      case 'boundary':
        testCase.result = [S.getDocumentBoundarySelection(doc, false), S.getDocumentBoundarySelection(doc, true, true), S.getDocumentFullSelection(doc)];
        break;
      case 'snap': {
        const line = doc.getLineText(selections[0].start.line);
        testCase.result = Array.from({ length: line.length + 2 }, (_, i) => S.snapCharacterToGraphemeBoundary(line, i));
        break;
      }
      case 'undo': {
        const primary = selections[selections.length - 1];
        S.applyTextChangeToSelections(doc, selections, { start: doc.offsetAt(primary.start), end: doc.offsetAt(primary.end), text: 'q' });
        S.applyDeleteCharacterToSelections(doc, S.mapCursorMove(doc, selections, 'end'), false);
        const undone = doc.undo();
        testCase.result = { text: doc.getText(), selections: undone?.[1] ?? null };
        break;
      }
    }
  } catch (error: any) {
    testCase.error = String(error?.message ?? error);
  }
  cases.push(testCase);
}

writeFileSync(join(OUT_DIR, 'editor-selection.json'), JSON.stringify(cases));
console.log(`cases=${cases.length} errors=${cases.filter((c) => c.error).length}`);
