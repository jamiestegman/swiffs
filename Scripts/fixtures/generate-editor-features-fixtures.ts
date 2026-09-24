// Generates golden fixtures for editor keymaps (`command.ts`), comment
// toggling (`languages.ts`), incremental tokenization (`tokenizer.ts`) and
// bracket matching (`matchBrackets.ts`) from the upstream sources.
//
// Usage:
//   SHIKI_MODULES=/path/to/node_modules PIERRE_DIR=/path/to/pierre \
//     OUT_DIR=Tests/SwiffsEditorTests/Fixtures \
//     bun Scripts/fixtures/generate-editor-features-fixtures.ts
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const SHIKI_MODULES = process.env.SHIKI_MODULES!;
const PIERRE_DIR = process.env.PIERRE_DIR!;
const OUT_DIR = process.env.OUT_DIR!;
const editor = join(PIERRE_DIR, 'packages/diffs/src/editor');

// Minimal browser stubs for the tokenizer constructor and its background
// scheduling (never run here).
(globalThis as any).window = {
  matchMedia: () => ({ matches: true, addEventListener() {}, removeEventListener() {} }),
};
(globalThis as any).postMessage = () => {};

const shiki = await import(join(SHIKI_MODULES, 'shiki/dist/index.mjs'));
const { resolveEditorCommandFromKeyboardEvent, resolveFindAgainShortcut } = await import(join(editor, 'command.ts'));
const { resolveCommentConfig, resolveLineCommentEdits, resolveBlockCommentEdits } = await import(join(editor, 'languages.ts'));
const { TextDocument } = await import(join(editor, 'textDocument.ts'));
const { EditorTokenizer } = await import(join(editor, 'tokenizer.ts'));
const { findBracketMatchRanges } = await import(join(editor, 'matchBrackets.ts'));

// Commands.
const keyEvents: any[] = [];
const keys = [
  ['z', 'KeyZ'], ['y', 'KeyY'], ['a', 'KeyA'], ['d', 'KeyD'], ['f', 'KeyF'], ['k', 'KeyK'], ['p', 'KeyP'], ['g', 'KeyG'],
  ['/', 'Slash'], ['[', 'BracketLeft'], [']', 'BracketRight'], ['Tab', 'Tab'], ['Enter', 'Enter'], ['Escape', 'Escape'],
  ['ArrowUp', 'ArrowUp'], ['ArrowDown', 'ArrowDown'], ['Home', 'Home'], ['End', 'End'], ['Z', 'KeyZ'], ['å', 'KeyA'],
  ['÷', 'Slash'], [' ', 'Space'], ['1', 'Digit1'],
];
for (const [key, code] of keys) {
  for (let mask = 0; mask < 16; mask++) {
    const event = { key, code, altKey: !!(mask & 1), ctrlKey: !!(mask & 2), metaKey: !!(mask & 4), shiftKey: !!(mask & 8) };
    keyEvents.push({
      event,
      mac: resolveEditorCommandFromKeyboardEvent(event, undefined, true) ?? null,
      custom: resolveEditorCommandFromKeyboardEvent(event, [{ bindings: { 'cmdOrCtrl+k': 'toggleComment', 'alt+z': 'undo' } }], true) ?? null,
      findAgain: resolveFindAgainShortcut(event, true) ?? null,
    });
  }
}

// Comments.
const commentDocs = [
  ['typescript', 'const a = 1;\n  // already\n  // commented\n\nfunction f() {\n    return 2;\n}\n'],
  ['python', 'def f():\n    # note\n    return 1\n'],
  ['html', '<div>\n  <p>hi</p>\n</div>\n'],
  ['css', '.a { color: red; }\n/* block */\n'],
  ['typescript', 'x /* c */ y\n  /*  spaced  */\n'],
];
const commentCases: any[] = [];
for (const [lang, text] of commentDocs) {
  const doc = new TextDocument('f', text, lang);
  const config = resolveCommentConfig(lang);
  const selectionSets = [
    [{ start: { line: 0, character: 0 }, end: { line: 0, character: 0 }, direction: 0 }],
    [{ start: { line: 1, character: 2 }, end: { line: 2, character: 3 }, direction: 1 }],
    [{ start: { line: 0, character: 0 }, end: { line: doc.lineCount - 1, character: 0 }, direction: 1 }],
    [{ start: { line: 1, character: 0 }, end: { line: 1, character: 0 }, direction: 0 }, { start: { line: 3, character: 0 }, end: { line: 4, character: 1 }, direction: -1 }],
    [{ start: { line: 0, character: 2 }, end: { line: 0, character: 6 }, direction: 1 }],
    [{ start: { line: 1, character: 2 }, end: { line: 1, character: 13 }, direction: 1 }],
  ];
  for (const selections of selectionSets) {
    if (selections.some((selection) => selection.end.line >= doc.lineCount)) continue;
    const token = config.lineComment;
    commentCases.push({
      lang,
      text,
      selections,
      config: { lineComment: config.lineComment, blockComment: config.blockComment },
      lineEdits: token == null ? null : resolveLineCommentEdits(doc, selections, token),
      blockEdits: resolveBlockCommentEdits(doc, selections, config.blockComment) ?? null,
      blockLinewise: resolveBlockCommentEdits(doc, selections, config.blockComment, true) ?? null,
    });
  }
}

// Tokenizer and bracket matching.
const pierreTheme = (name: string) => JSON.parse(readFileSync(join(PIERRE_DIR, 'packages/theme/themes', `${name}.json`), 'utf8'));
const highlighter = await shiki.createHighlighter({
  themes: [pierreTheme('pierre-dark'), pierreTheme('pierre-light')],
  langs: ['typescript', 'python'],
});
const tokenizerDocs = [
  ['typescript', 'const s = "a(b";\nfunction f(x: number) {\n  /* ( */ return [x, {y: (1)}];\n}\nconst t = `${f(1)}`;\n'],
  ['python', 'def f(a):\n    """doc (\n    more"""\n    return [a, (1, 2)]\n'],
];
const edits = [
  { range: { start: { line: 0, character: 0 }, end: { line: 0, character: 0 } }, newText: '/*' },
  { range: { start: { line: 1, character: 0 }, end: { line: 1, character: 0 } }, newText: 'x\ny\n' },
  { range: { start: { line: 0, character: 0 }, end: { line: 2, character: 0 } }, newText: '' },
  { range: { start: { line: 1, character: 3 }, end: { line: 1, character: 5 } }, newText: '"' },
];
const tokenizerCases: any[] = [];
for (const [lang, text] of tokenizerDocs) {
  for (const renderRange of [undefined, { startingLine: 1, totalLines: 2, bufferBefore: 0, bufferAfter: 0 }]) {
    const doc = new TextDocument('f', text, lang);
    const deferred: any[] = [];
    const tokenizer = new EditorTokenizer({
      highlighter,
      textDocument: doc,
      codeOptions: { theme: 'pierre-dark', tokenizeMaxLineLength: 1000 },
      setStyle: () => {},
      onDeferTokenize: (lines: Map<number, any>) => deferred.push([...lines.entries()]),
    });
    const steps: any[] = [];
    const lineCount = doc.lineCount;
    const initial = tokenizer.tokenize({
      changes: [], startLine: 0, startCharacter: 0, endCharacter: 0, endLine: lineCount - 1, endedAtDocumentEnd: false,
      previousLineCount: lineCount, lineCount, lineDelta: 0, changedLineRanges: [[0, lineCount - 1]],
      changedLineChanges: [[0, lineCount - 1, 0, 0, 0, false]],
    }, renderRange);
    steps.push({ edit: null, text: doc.getText(), dirty: [...initial.entries()] });
    for (const edit of edits) {
      deferred.length = 0;
      let change;
      try {
        change = doc.applyEdits([edit]);
      } catch {
        continue;
      }
      const dirty = tokenizer.tokenize(change, renderRange);
      const brackets: any[] = [];
      for (let line = 0; line < doc.lineCount; line++) {
        const length = doc.getLineLength(line);
        for (let character = 0; character <= length; character++) {
          const match = findBracketMatchRanges(doc, tokenizer, { line, character });
          if (match) brackets.push([line, character, match]);
        }
      }
      const ignored = Array.from({ length: doc.lineCount }, (_, line) => tokenizer.getStringCommentRegexpRangesInLine(line));
      steps.push({ edit, text: doc.getText(), dirty: [...dirty.entries()], deferred: deferred.map((d) => d), brackets, ignored });
    }
    tokenizer.cleanUp();
    tokenizerCases.push({ lang, text, renderRange: renderRange ?? null, steps });
  }
}

writeFileSync(join(OUT_DIR, 'editor-features.json'), JSON.stringify({ keyEvents, commentCases, tokenizerCases }));
console.log(`keys=${keyEvents.length} comments=${commentCases.length} tokenizer=${tokenizerCases.length}`);
