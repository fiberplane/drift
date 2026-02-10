import { resolve } from "node:path";
import { unlinkSync } from "node:fs";

import sveltePlugin from "bun-plugin-svelte";

// Step 1: Build the frontend entry with Svelte compiled away
const frontendBuild = await Bun.build({
  entrypoints: ["src/ui/src/entry.ts"],
  target: "browser",
  minify: true,
  plugins: [sveltePlugin],
});

if (!frontendBuild.success) {
  for (const log of frontendBuild.logs) {
    console.error(log);
  }
  process.exit(1);
}

let compiledJs = "";
let compiledCss = "";

for (const output of frontendBuild.outputs) {
  if (output.path.endsWith(".css")) {
    compiledCss += await output.text();
  } else {
    compiledJs += await output.text();
  }
}

// Step 2: Create self-contained production HTML with inlined assets
const htmlTemplate = await Bun.file("src/ui/index.html").text();
let productionHtml = htmlTemplate;

if (compiledCss.length > 0) {
  productionHtml = productionHtml.replace(
    "</head>",
    `<style>${compiledCss}</style>\n</head>`,
  );
}

productionHtml = productionHtml.replace(
  '<script type="module" src="./src/entry.ts"></script>',
  `<script type="module">\n${compiledJs}\n</script>`,
);

// Step 3: Generate a module that exports the HTML as a static route Response
const generatedPath = resolve("dist/_homepage.ts");
const generatedModule = `const html = ${JSON.stringify(productionHtml)};\nexport default new Response(html, {\n  headers: { "content-type": "text/html; charset=utf-8" },\n});\n`;
await Bun.write(generatedPath, generatedModule);

// Step 4: Build the CLI/server, replacing the HTML import with the pre-built version
const serverBuild = await Bun.build({
  entrypoints: ["src/cli/main.ts"],
  outdir: "dist",
  target: "bun",
  minify: true,
  plugins: [
    sveltePlugin,
    {
      name: "inline-homepage",
      setup(build) {
        build.onResolve({ filter: /\.html$/ }, (args) => {
          if (args.path.includes("index.html")) {
            return { path: generatedPath };
          }
        });
      },
    },
  ],
});

if (!serverBuild.success) {
  for (const log of serverBuild.logs) {
    console.error(log);
  }
  process.exit(1);
}

try {
  unlinkSync(generatedPath);
} catch {
  // ignore if already cleaned
}

const frontendKb = (compiledJs.length / 1024).toFixed(1);
console.log(`Built ${serverBuild.outputs.length} files to dist/ (frontend: ${frontendKb}KB)`);
