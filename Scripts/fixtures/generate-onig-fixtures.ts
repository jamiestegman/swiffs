// Records every Oniguruma scanner call Shiki (vscode-oniguruma, WASM) makes
// while tokenizing the highlight and render-stress samples: the scanner's
// patterns, the string, start position, options and the match. The Swift
// scanner replays the calls and must return the same matches, so changes to
// the regex layer are checked against the engine upstream actually runs.
//
// Captures of zero length are recorded as empty regardless of offset:
// unmatched groups report engine-specific sentinel offsets, and
// vscode-textmate ignores zero-length captures.
//
// Usage:
//   SHIKI_MODULES=/path/to/node_modules HIGHLIGHT_FIXTURES=Tests/SwiffsHighlightTests/Fixtures \
//     OUT_DIR=Tests/SwiffsHighlightTests/Fixtures bun Scripts/fixtures/generate-onig-fixtures.ts
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const SHIKI_MODULES = process.env.SHIKI_MODULES!;
const HIGHLIGHT_FIXTURES = process.env.HIGHLIGHT_FIXTURES!;
const OUT_DIR = process.env.OUT_DIR!;
const shiki = await import(join(SHIKI_MODULES, 'shiki/dist/index.mjs'));
const { createOnigurumaEngine } = await import(join(SHIKI_MODULES, '@shikijs/engine-oniguruma/dist/index.mjs'));

const scanners: string[][] = [];
const scannerIds = new Map<string, number>();
const strings: string[] = [];
const stringIds = new Map<string, number>();
// [scanner, string, start, options, index, ...captures as start,end or -1,-1]
const calls: number[][] = [];

function intern<T>(table: T[], ids: Map<string, number>, key: string, value: T): number {
  let id = ids.get(key);
  if (id == null) {
    id = table.length;
    table.push(value);
    ids.set(key, id);
  }
  return id;
}

const base = await createOnigurumaEngine(import(join(SHIKI_MODULES, 'shiki/dist/wasm.mjs')));
const engine = {
  createScanner(patterns: any[]) {
    const sources = patterns.map((p) => (typeof p === 'string' ? p : p.source));
    const scanner = base.createScanner(patterns);
    const scannerId = intern(scanners, scannerIds, sources.join('\u0000'), sources);
    return {
      findNextMatchSync(string: any, start: number, options: number) {
        const result = scanner.findNextMatchSync(string, start, options);
        const content: string = typeof string === 'string' ? string : string.content;
        const stringId = intern(strings, stringIds, content, content);
        const call = [scannerId, stringId, start, typeof options === 'number' ? options : 0];
        if (result == null) {
          call.push(-1);
        } else {
          call.push(result.index);
          for (const capture of result.captureIndices) {
            if (capture.end - capture.start === 0) call.push(-1, -1);
            else call.push(capture.start, capture.end);
          }
        }
        calls.push(call);
        return result;
      },
      dispose() {
        scanner.dispose?.();
      },
    };
  },
  createString(s: string) {
    return base.createString(s);
  },
};

const samples: { lang: string; code: string }[] = JSON.parse(readFileSync(join(HIGHLIGHT_FIXTURES, 'highlight.json'), 'utf8'))
  .map((c: any) => ({ lang: c.lang, code: c.code }));
const stress = JSON.parse(readFileSync(join(HIGHLIGHT_FIXTURES, 'render-stress.json'), 'utf8'));
for (const c of stress.fileCases) {
  if (c.file.lang === 'ansi' || c.file.lang === 'text') continue;
  samples.push({ lang: c.file.lang ?? c.name, code: c.file.contents });
}
// Long lines (at least 1000 UTF-8 bytes) take the per-pattern cached search
// path; many tokens per line exercise the cache across calls.
const repeat = (piece: string, bytes: number) => {
  let out = '';
  while (Buffer.byteLength(out) < bytes) out += piece;
  return out;
};
samples.push(
  { lang: 'javascript', code: repeat('function a(b,c){return b+c*2}var x="str",y=/re[gx]+/g,z={k:1,"q":[1,2,3]};if(x&&y){z.k++}', 3000) + '\n' },
  { lang: 'json', code: '{' + repeat('"key_ü": {"n": 1.5e3, "s": "value 🚀", "a": [true, null, false]}, ', 2500) + '"end": 0}\n' },
  { lang: 'markdown', code: repeat('Some **bold** and _italic_ text with `code`, a [link](https://example.com) and emoji 🎉 漢字. ', 4000) + '\n' },
  { lang: 'css', code: repeat('.a>b:hover{color:#fff;margin:0 auto;content:"→"}@media(max-width:600px){.c{display:none}}', 2000) + '\n' },
  { lang: 'python', code: 'x = [' + repeat('f"{v!r} café", 0x1F, lambda y: y * 2, ', 1500) + ']\n' },
  { lang: 'tsx', code: repeat('<Item key={i} label="é" onClick={() => set(i)}>{items[i] as string}</Item>', 2000) + '\n' },
);

const langs = [...new Set(samples.map((s) => s.lang).filter((l) => l !== 'text'))];
const highlighter = await shiki.createHighlighter({ themes: ['github-dark'], langs, engine });
for (const sample of samples) {
  if (sample.lang === 'text') continue;
  highlighter.codeToTokensBase(sample.code, { lang: sample.lang, theme: 'github-dark' });
}

writeFileSync(join(OUT_DIR, 'onig.json'), JSON.stringify({ scanners, strings, calls }));
console.log(`scanners=${scanners.length} strings=${strings.length} calls=${calls.length} langs=${langs.length}`);
