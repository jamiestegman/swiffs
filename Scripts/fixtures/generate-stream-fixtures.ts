// Generates golden fixtures for the streaming tokenizer by running the
// upstream `ShikiStreamTokenizer` with the options `FileStream` uses.
//
// Usage:
//   SHIKI_MODULES=/path/to/node_modules PIERRE_DIR=/path/to/pierre \
//     OUT_DIR=Tests/SwiffsHighlightTests/Fixtures \
//     bun Scripts/fixtures/generate-stream-fixtures.ts
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const SHIKI_MODULES = process.env.SHIKI_MODULES!;
const PIERRE_DIR = process.env.PIERRE_DIR!;
const OUT_DIR = process.env.OUT_DIR!;
const shiki = await import(join(SHIKI_MODULES, 'shiki/dist/index.mjs'));
const { ShikiStreamTokenizer } = await import(join(PIERRE_DIR, 'packages/diffs/src/shiki-stream/tokenizer.ts'));
const pierreTheme = (name: string) => JSON.parse(readFileSync(join(PIERRE_DIR, 'packages/theme/themes', `${name}.json`), 'utf8'));

const highlighter = await shiki.createHighlighter({
  themes: [pierreTheme('pierre-dark'), pierreTheme('pierre-light'), 'github-dark'],
  langs: ['typescript', 'python', 'markdown', 'html'],
});

const samples: { name: string; lang: string; code: string }[] = [
  {
    name: 'ts-comment',
    lang: 'typescript',
    code: `/**\n * Block comment spanning\n * several lines\n */\nexport function add(a: number, b: number): number {\n  const s = \`template \${a + b}\`;\n  return a + b; // done\n}\n`,
  },
  {
    name: 'py-docstring',
    lang: 'python',
    code: `def f(x):\n    """Multi\n    line docstring"""\n    return x * 2  # twice\n\nprint(f(3))`,
  },
  {
    name: 'markdown-fence',
    lang: 'markdown',
    code: '# Title\n\nSome *text* here.\n\n```ts\nconst x = 1;\n```\n\n- item\n',
  },
  { name: 'html-script', lang: 'html', code: '<div class="a">\n  <script>\n    let y = "<b>";\n  </script>\n</div>\n' },
  { name: 'plain', lang: 'text', code: 'plain text\nwith lines\n' },
  { name: 'unicode', lang: 'typescript', code: 'const s = "héllo 😀";\nconst t = `ü ${s}`;\n' },
];

// Chunks never split a surrogate pair: Swift strings cannot hold lone
// surrogates.
function chunk(code: string, size: number): string[] {
  const chunks: string[] = [];
  let i = 0;
  while (i < code.length) {
    let end = Math.min(i + size, code.length);
    const last = code.charCodeAt(end - 1);
    if (end < code.length && last >= 0xd800 && last <= 0xdbff) end += 1;
    chunks.push(code.slice(i, end));
    i = end;
  }
  return chunks;
}

const themeCases: { name: string; options: any }[] = [
  { name: 'pair', options: { themes: { dark: 'pierre-dark', light: 'pierre-light' }, defaultColor: false, cssVariablePrefix: '--diffs-token-' } },
  { name: 'single', options: { theme: 'github-dark' } },
];

const cases: any[] = [];
for (const sample of samples) {
  for (const size of [1, 5, 17, 1000]) {
    for (const themeCase of themeCases) {
      const tokenizer = new ShikiStreamTokenizer({
        ...themeCase.options,
        lang: sample.lang,
        highlighter,
        tokenizeTimeLimit: 0,
      });
      const chunks = chunk(sample.code, size);
      const steps: any[] = [];
      for (const piece of chunks) {
        const result = await tokenizer.enqueue(piece);
        steps.push({
          chunk: piece,
          recall: result.recall,
          stable: result.stable.map(serialize),
          unstable: result.unstable.map(serialize),
        });
      }
      const closed = tokenizer.close().stable.map(serialize);
      cases.push({ name: `${sample.name}/${size}/${themeCase.name}`, lang: sample.lang, themes: themeCase.name, steps, closed });
    }
  }
}

function serialize(token: any) {
  return {
    content: token.content,
    htmlStyle: token.htmlStyle ?? null,
    color: token.color ?? null,
    fontStyle: token.fontStyle ?? 0,
  };
}

writeFileSync(join(OUT_DIR, 'stream.json'), JSON.stringify(cases));
console.log(`cases=${cases.length}`);
