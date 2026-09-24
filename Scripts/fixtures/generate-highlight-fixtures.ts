// Generates golden tokenization fixtures for SwiffsHighlight by running Shiki
// 4.4.1 (the version @pierre/diffs uses) with both the Oniguruma (WASM) and
// JavaScript regex engines.
//
// Usage:
//   SHIKI_MODULES=/path/to/node_modules PIERRE_DIR=/path/to/pierre \
//     OUT_DIR=Tests/SwiffsHighlightTests/Fixtures \
//     bun Scripts/fixtures/generate-highlight-fixtures.ts
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const SHIKI_MODULES = process.env.SHIKI_MODULES!;
const PIERRE_DIR = process.env.PIERRE_DIR!;
const OUT_DIR = process.env.OUT_DIR!;
const shiki = await import(join(SHIKI_MODULES, 'shiki/dist/index.mjs'));
const pierreTheme = (name: string) => JSON.parse(readFileSync(join(PIERRE_DIR, 'packages/theme/themes', `${name}.json`), 'utf8'));

const THEMES = ['pierre-dark', 'pierre-light', 'github-dark', 'github-light', 'one-dark-pro', 'dracula', 'catppuccin-latte', 'min-light', 'nord', 'monokai'];
const themeObjects = THEMES.map((t) => (t.startsWith('pierre-') ? pierreTheme(t) : t));

const snippets: Record<string, string> = {
  python: `import os\n\n@dataclass\nclass Foo(Base):\n    """Docstring with 'quotes'."""\n    def bar(self, x: int = 3) -> str:\n        return f"{x!r} and {self.y:>10}"  # comment\n\nif __name__ == "__main__":\n    print(r"raw\\n", b'bytes', 0x1F, 1_000.5e-3)\n`,
  swift: `import Foundation\n\n/// Doc comment\n@MainActor\nfinal class Foo<T: Hashable>: Bar, @unchecked Sendable {\n    private var value: [String: Int] = [:]\n    func run(_ x: inout Int) async throws -> Int? {\n        let s = "interp \\(x + 1)"\n        #if DEBUG\n        print(s)\n        #endif\n        return x > 0 ? x : nil\n    }\n}\n`,
  rust: `use std::collections::HashMap;\n\n#[derive(Debug, Clone)]\npub struct Point<'a> { x: i32, name: &'a str }\n\nimpl<'a> Point<'a> {\n    pub fn new(x: i32) -> Self {\n        let r = r#"raw "string""#;\n        println!("{} {:?}", x, r);\n        Self { x, name: "p" }\n    }\n}\n// comment\nfn main() { let v: Vec<u8> = vec![1, 2, 3]; }\n`,
  go: `package main\n\nimport (\n\t"fmt"\n)\n\ntype Server struct {\n\tAddr string \`json:"addr"\`\n}\n\nfunc (s *Server) Run(ctx context.Context) error {\n\tgo func() { fmt.Println("hi", 42) }()\n\treturn nil // done\n}\n`,
  ruby: `# frozen_string_literal: true\nmodule Foo\n  class Bar < Base\n    attr_reader :name\n    def initialize(name = "x")\n      @name = name\n      puts "Hello #{name}" if name =~ /\\w+/\n    end\n  end\nend\n`,
  c: `#include <stdio.h>\n#define MAX(a, b) ((a) > (b) ? (a) : (b))\n\nstatic int count = 0;\n\nint main(int argc, char **argv) {\n    /* block comment */\n    printf("%d\\n", MAX(argc, 3));\n    return 0;\n}\n`,
  cpp: `#include <vector>\ntemplate <typename T>\nclass Stack {\npublic:\n    void push(const T& v) { data_.push_back(v); }\n    auto size() const noexcept -> std::size_t { return data_.size(); }\nprivate:\n    std::vector<T> data_;\n};\n`,
  java: `package com.example;\n\nimport java.util.List;\n\n@Service\npublic class Foo implements Bar {\n    private final List<String> items = List.of("a", "b");\n    @Override\n    public int size() { return items.size(); } // size\n}\n`,
  kotlin: `data class User(val name: String, var age: Int = 0)\n\nfun main() {\n    val users = listOf(User("a"), User("b", 3))\n    users.filter { it.age > 1 }.forEach { println("\${it.name}") }\n}\n`,
  bash: `#!/usr/bin/env bash\nset -euo pipefail\n\nfor f in "$@"; do\n  if [[ -f "$f" ]]; then\n    echo "file: \${f##*/}" | tr a-z A-Z\n  fi\ndone\nexport PATH="$HOME/bin:$PATH" # comment\n`,
  sql: `SELECT u.id, COUNT(*) AS total\nFROM users u\nLEFT JOIN orders o ON o.user_id = u.id\nWHERE u.created_at > '2024-01-01' -- recent\nGROUP BY u.id\nHAVING COUNT(*) > 3;\n`,
  diff: `diff --git a/a.txt b/a.txt\nindex 123..456 100644\n--- a/a.txt\n+++ b/a.txt\n@@ -1,3 +1,3 @@ context\n line\n-old\n+new\n`,
  xml: `<?xml version="1.0" encoding="UTF-8"?>\n<!-- comment -->\n<root xmlns:x="urn:x">\n  <x:item id="1" enabled='true'>Text &amp; more</x:item>\n  <![CDATA[ raw <data> ]]>\n</root>\n`,
  php: `<?php\nnamespace App;\n\nclass Foo {\n    public function __construct(private string $name) {}\n    public function greet(): string {\n        return "Hello {$this->name}";\n    }\n}\n`,
  scss: `$primary: #333;\n@mixin flex($dir: row) { display: flex; flex-direction: $dir; }\n.card {\n  &:hover { color: darken($primary, 10%); }\n  .title { @include flex(column); }\n}\n`,
  yaml: `name: CI\non:\n  push:\n    branches: [main]\njobs:\n  build:\n    runs-on: ubuntu-latest # comment\n    steps:\n      - uses: actions/checkout@v4\n      - run: echo "hi" && exit 0\n`,
  toml: `[package]\nname = "swiffs"\nversion = "0.1.0"\n\n[dependencies]\nserde = { version = "1", features = ["derive"] }\n# comment\n`,
  dockerfile: `FROM node:20-alpine AS build\nWORKDIR /app\nCOPY package.json ./\nRUN npm ci && npm run build\nENV NODE_ENV=production\nCMD ["node", "dist/index.js"]\n`,
  makefile: `CC ?= clang\nSRCS := $(wildcard src/*.c)\n\n.PHONY: all\nall: $(SRCS:.c=.o)\n\t$(CC) -o app $^ # link\n`,
  lua: `local M = {}\nfunction M.greet(name)\n  -- comment\n  return string.format("Hello %s", name or "world")\nend\nreturn M\n`,
  jsx: `export function App({ items }) {\n  return (\n    <ul className="list">\n      {items.map((i) => <li key={i.id}>{i.name}</li>)}\n    </ul>\n  );\n}\n`,
  vue: `<template>\n  <div :class="{ active }" @click="toggle">{{ label }}</div>\n</template>\n<script setup lang="ts">\nconst active = ref(false)\n</script>\n<style scoped>\n.active { color: red; }\n</style>\n`,
  csharp: `using System;\nnamespace Demo {\n    public record Person(string Name);\n    class Program {\n        static async Task Main(string[] args) => Console.WriteLine($"Hi {args.Length}");\n    }\n}\n`,
  haskell: `module Main where\n\nimport Data.List (sort)\n\n-- | Doc\nmain :: IO ()\nmain = mapM_ print (sort [3, 1, 2])\n`,
  zig: `const std = @import("std");\n\npub fn main() !void {\n    const x: u32 = 42;\n    std.debug.print("{d}\\n", .{x});\n}\n`,
  graphql: `query GetUser($id: ID!) {\n  user(id: $id) {\n    name\n    ... on Admin { level }\n  }\n}\n`,
  objc: `#import <Foundation/Foundation.h>\n@interface Foo : NSObject\n@property (nonatomic, copy) NSString *name;\n@end\n@implementation Foo\n- (void)run { NSLog(@"%@", self.name); }\n@end\n`,
  'git-commit': `Fix the thing\n\nLonger description here.\n# Please enter the commit message\n`,
};

const fileSamples: [string, string][] = [
  ['typescript', 'packages/diffs/src/utils/iterateOverDiff.ts'],
  ['typescript', 'packages/diffs/src/types.ts'],
  ['tsx', 'packages/diffs/src/react/CodeView.tsx'],
  ['css', 'packages/diffs/src/style.css'],
  ['markdown', 'packages/diffs/README.md'],
  ['json', 'packages/diffs/package.json'],
  ['html', 'packages/diffs/test/e2e/fixtures/index.html'],
  ['yaml', 'pnpm-workspace.yaml'],
  ['javascript', 'svgo.config.js'],
];

const cases: { lang: string; code: string; name: string }[] = [];
for (const [lang, code] of Object.entries(snippets)) cases.push({ lang, code, name: `snippet-${lang}` });
for (const [lang, path] of fileSamples) {
  let code = readFileSync(join(PIERRE_DIR, path), 'utf8');
  const lines = code.split('\n');
  if (lines.length > 400) code = lines.slice(0, 400).join('\n');
  cases.push({ lang, code, name: path });
}
// Edge cases: CRLF, unicode, long lines, empty lines.
cases.push({ lang: 'typescript', code: 'const a = "é😀x";\r\nlet b = `t ${a}`;\r\n\r\n// done', name: 'crlf-unicode' });
cases.push({ lang: 'typescript', code: 'x'.repeat(50) + ' = "' + 'y'.repeat(200) + '";\nconst z = 1;', name: 'long-line' });
cases.push({ lang: 'text', code: 'plain\ntext', name: 'plain-text' });

const langs = [...new Set(cases.map((c) => c.lang))].filter((l) => l !== 'text');

async function run(engine: any) {
  const highlighter = await shiki.createHighlighter({ themes: themeObjects, langs, engine });
  const output: any[] = [];
  for (const c of cases) {
    const byTheme: any = {};
    for (const theme of THEMES) {
      const tokens = highlighter.codeToTokensBase(c.code, {
        lang: c.lang,
        theme,
        tokenizeMaxLineLength: c.name === 'long-line' ? 120 : 0,
        tokenizeTimeLimit: 0,
      });
      byTheme[theme] = tokens.map((line: any[]) => line.map((t) => [t.content.length, t.color ?? null, t.fontStyle ?? 0]));
    }
    output.push(byTheme);
  }
  return output;
}

const wasm = await run(await shiki.createOnigurumaEngine(import(join(SHIKI_MODULES, 'shiki/dist/wasm.mjs'))));
const js = await run(shiki.createJavaScriptRegexEngine());
let jsDiffers = 0;
const fixtures = cases.map((c, i) => {
  const differs = JSON.stringify(wasm[i]) !== JSON.stringify(js[i]);
  if (differs) jsDiffers++;
  return { ...c, themes: THEMES, expected: wasm[i], jsEngineDiffers: differs };
});
writeFileSync(join(OUT_DIR, 'highlight.json'), JSON.stringify(fixtures));
console.log(`cases=${fixtures.length} jsEngineDiffers=${jsDiffers}`);
