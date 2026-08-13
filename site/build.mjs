import { cp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { extname, join, resolve } from 'node:path';
import GithubSlugger from 'github-slugger';
import { Marked } from 'marked';

const siteRoot = resolve(import.meta.dirname);
const repositoryRoot = resolve(siteRoot, '..');
const outputRoot = join(siteRoot, 'dist');
const docsRoot = join(repositoryRoot, 'docs');

const docs = [
  ['install', 'Install'],
  ['connect', 'Connect your agent'],
  ['tool-surface', 'Tools'],
  ['axn', 'The .axn file'],
  ['cross-platform', 'Cross-platform'],
  ['embedding', 'Embedding'],
];

// cross-platform.md links to this contract. It is rendered but deliberately omitted from the
// primary navigation so the requested documentation set remains focused.
const supportingDocs = [['platform-spec', 'Platform Contract']];

const escapeHtml = (value) => String(value)
  .replaceAll('&', '&amp;')
  .replaceAll('<', '&lt;')
  .replaceAll('>', '&gt;')
  .replaceAll('"', '&quot;');

function renderMarkdown(source, { omitSections = [] } = {}) {
  for (const heading of omitSections) {
    const start = source.indexOf(`## ${heading}\n`);
    if (start === -1) continue;
    const next = source.indexOf('\n## ', start + 4);
    source = source.slice(0, start) + (next === -1 ? '' : source.slice(next + 1));
  }

  const slugger = new GithubSlugger();
  const marked = new Marked({ gfm: true });

  marked.use({
    walkTokens(token) {
      if (token.type !== 'link') return;
      if (/^(?:javascript|data|vbscript):/i.test(token.href.trim())) {
        token.href = '#unsafe-link';
        return;
      }
      const match = token.href.match(/^([^/:#]+)\.md(#[^ ]+)?$/);
      if (match) token.href = `/docs/${match[1]}/${match[2] ?? ''}`;
      if (token.href.startsWith('../')) {
        token.href = `https://github.com/bleugreen/axon/blob/main/${token.href.slice(3)}`;
      }
    },
    renderer: {
      html({ raw }) {
        return escapeHtml(raw);
      },
      heading({ tokens, depth }) {
        const text = this.parser.parseInline(tokens);
        const id = slugger.slug(tokens.map((token) => token.text ?? token.raw ?? '').join(''));
        return `<h${depth} id="${escapeHtml(id)}">${text}</h${depth}>\n`;
      },
    },
  });

  return marked.parse(source);
}

function internalTarget(href, currentPage) {
  const [rawPath, fragment] = href.split('#', 2);
  if (!rawPath && fragment) return { path: currentPage, fragment };
  if (!rawPath.startsWith('/')) return undefined;
  const path = rawPath.endsWith('/') ? `${rawPath}index.html` : rawPath;
  return { path, fragment };
}

async function validateInternalLinks() {
  const pages = [
    '/index.html',
    ...[...docs, ...supportingDocs].map(([slug]) => `/docs/${slug}/index.html`),
  ];
  const missing = [];
  for (const page of pages) {
    const html = await readFile(join(outputRoot, page), 'utf8');
    for (const [, href] of html.matchAll(/href="([^"]+)"/g)) {
      const target = internalTarget(href, page);
      if (!target) continue;
      try {
        const targetHtml = await readFile(join(outputRoot, target.path), 'utf8');
        if (target.fragment && !targetHtml.includes(`id="${escapeHtml(decodeURIComponent(target.fragment))}"`)) {
          missing.push(`${page}: ${href} (missing heading)`);
        }
      } catch {
        missing.push(`${page}: ${href}`);
      }
    }
  }
  if (missing.length) throw new Error(`Broken internal links:\n${missing.join('\n')}`);
}

function shellBlock(command, label) {
  return `<div class="command"><span>${escapeHtml(label)}</span><code>${escapeHtml(command)}</code></div>`;
}

function page({ title, description, body, docsPage = false, docsSlug }) {
  const nav = docs.map(([slug, label]) =>
    `<a href="/docs/${slug}/"${slug === docsSlug ? ' aria-current="page"' : ''}>${label}</a>`
  ).join('');
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="${escapeHtml(description)}">
  <title>${escapeHtml(title)}</title>
  <link rel="icon" href="/axon-mark.svg" type="image/svg+xml">
  <link rel="stylesheet" href="/styles.css">
</head>
<body>
  <header class="site-header">
    <a class="wordmark" href="/" aria-label="Axon home"><img src="/axon-mark.svg" alt=""><span>axon</span></a>
    <nav aria-label="Primary"><a href="/docs/install/">Docs</a><a href="https://github.com/bleugreen/axon">GitHub</a></nav>
  </header>
  ${docsPage ? `<div class="docs-shell${docsSlug === 'cross-platform' ? ' docs-shell-wide' : ''}"><aside><div class="docs-label">Documentation</div>${nav}</aside><main class="prose">${body}</main></div>` : body}
  <footer><span>Axon is open source under the MIT license.</span><span>Small. Local. Inspectable.</span></footer>
</body>
</html>`;
}

function home(version) {
  const guarantees = [
    ['01', 'Semantic targets', 'Address a button by its role, label, window, and surrounding context.'],
    ['02', 'Same interface everywhere', 'The same small tool surface works on macOS, Windows, and Linux.'],
    ['03', 'Replayable work', 'Save sessions as plain-text .axn files. Read them, edit them, share them, and run them again.'],
  ];
  return page({
    title: 'Axon — local UI access for agents',
    description: 'A local accessibility service that gives agents semantic, honest, and replayable control of desktop apps.',
    body: `<main>
      <section class="hero">
        <div class="eyebrow"><span></span>Local accessibility infrastructure</div>
        <h1>Let the computer <em>use</em> the computer.</h1>
        <p>Axon turns the OS accessibility layer into a small, consistent tool surface for agents on macOS, Windows, and Linux.</p>
        <div class="hero-actions"><a class="button primary" href="/docs/install/">Get started</a><a class="button" href="/docs/tool-surface/">Explore the tools</a></div>
      </section>
      <section class="loop" aria-label="Axon's core loop">
        <span>look</span><i>→</i><span>find</span><i>→</i><span>act</span><i>→</i><span>replay</span>
      </section>
      <section class="guarantees">
        <div class="section-heading"><h2>General-purpose automation for agents</h2></div>
        <div class="guarantee-grid">${guarantees.map(([number, title, copy]) => `<article><span>${number}</span><h3>${title}</h3><p>${copy}</p></article>`).join('')}</div>
      </section>
      <section class="artifact">
        <div><p class="kicker">The unit of memory</p><h2>A route becomes a reflex.</h2><p>A <code>.axn</code> file is an ordered sequence of tool calls you can inspect, edit, share, and run again.</p><a href="/docs/axn/">Read about the file format →</a></div>
        <pre aria-label="Example axn file"><code><b>version:</b> 2
<b>actions:</b>
  - <b>tool:</b> click
    <b>target:</b>
      <b>app:</b> Linear
      <b>role:</b> button
      <b>name:</b> New issue
  - <b>tool:</b> type
    <b>target:</b> { <b>role:</b> textField }
    <b>value:</b> Ship the honest path</code></pre>
      </section>
      <section class="install">
        <div><p class="kicker">Install Axon ${escapeHtml(version)}</p><h2>Get started.</h2></div>
        <div class="commands">
          ${shellBlock('curl -fsSL https://axn.dev/install.sh | sh', 'macOS / Linux · shell')}
          ${shellBlock('irm https://axn.dev/install.ps1 | iex', 'Windows · administrator PowerShell')}
          ${shellBlock('brew install --cask bleugreen/tap/axon', 'macOS · Homebrew')}
        </div>
      </section>
    </main>`,
  });
}

async function build() {
  await rm(outputRoot, { recursive: true, force: true });
  await mkdir(outputRoot, { recursive: true });
  await cp(join(siteRoot, 'public'), outputRoot, { recursive: true });
  await cp(join(repositoryRoot, 'Assets', 'AxonMark.svg'), join(outputRoot, 'axon-mark.svg'));
  const version = (await readFile(join(repositoryRoot, 'VERSION'), 'utf8')).trim();
  await writeFile(join(outputRoot, 'index.html'), home(version));

  for (const [slug, title] of [...docs, ...supportingDocs]) {
    const markdown = await readFile(join(docsRoot, `${slug}.md`), 'utf8');
    const directory = join(outputRoot, 'docs', slug);
    await mkdir(directory, { recursive: true });
    await writeFile(join(directory, 'index.html'), page({
      title: `${title} — Axon`,
      description: `${title}, from the Axon documentation.`,
      body: renderMarkdown(markdown, {
        omitSections: slug === 'tool-surface' ? ['Protocol reference'] : [],
      }),
      docsPage: true,
      docsSlug: slug,
    }));
  }
  await validateInternalLinks();
}

function serve() {
  const types = { '.css': 'text/css; charset=utf-8', '.html': 'text/html; charset=utf-8', '.svg': 'image/svg+xml', '.sh': 'text/plain; charset=utf-8', '.ps1': 'text/plain; charset=utf-8' };
  const server = createServer(async (request, response) => {
    const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
    let file = join(outputRoot, pathname);
    if (pathname.endsWith('/')) file = join(file, 'index.html');
    try {
      const content = await readFile(file);
      response.writeHead(200, { 'content-type': types[extname(file)] ?? 'application/octet-stream' });
      response.end(content);
    } catch {
      response.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
      response.end('Not found');
    }
  });
  server.listen(4321, '127.0.0.1', () => console.log('Axon site running at http://127.0.0.1:4321'));
}

await build();
if (process.argv.includes('--serve')) serve();