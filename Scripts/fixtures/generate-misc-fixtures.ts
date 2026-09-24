// Generates golden fixtures for small SwiffsCore utilities by running the
// upstream @pierre/diffs sources.
//
// Usage:
//   PIERRE_DIR=/path/to/pierre OUT_DIR=Tests/SwiffsCoreTests/Fixtures \
//     bun Scripts/fixtures/generate-misc-fixtures.ts
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

const PIERRE_DIR = process.env.PIERRE_DIR!;
const OUT_DIR = process.env.OUT_DIR!;
const src = join(PIERRE_DIR, 'packages/diffs/src');
const { getFiletypeFromFileName, EXTENSION_TO_FILE_FORMAT } = await import(join(src, 'utils/getFiletypeFromFileName.ts'));

const names = new Set<string>();
for (const key of Object.keys(EXTENSION_TO_FILE_FORMAT)) {
  names.add(key);
  names.add(`file.${key}`);
  names.add(`dir.v2/sub/file.${key}`);
}
for (const extra of [
  'README', 'Makefile', 'Dockerfile', 'a.b.c.d', 'foo.component.ts', 'x.blade.php', 'src/my.file.test.ts',
  '.gitignore', 'noext', 'dir.x/Makefile', 'weird..ts', 'trailing.', 'a/b\\c.d.ts', 'CMakeLists.txt',
  'path/to/CMakeLists.txt', 'archive.tar.gz', 'script.sh', 'UPPER.TS', 'emoji😀.rs',
]) names.add(extra);
const filetypes = [...names].map((name) => [name, getFiletypeFromFileName(name)]);
writeFileSync(join(OUT_DIR, 'misc.json'), JSON.stringify({ filetypes }));
console.log(`filetypes=${filetypes.length}`);
