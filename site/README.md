# axon

The website is a static build with no browser-side JavaScript. From this directory:

```sh
npm ci
npm run build
npm run dev
```

The build reads the published documentation directly from the repository's top-level `docs/`
directory. Do not copy documentation into `site/`; `docs/*.md` is the canonical source.

Files in `public/` are copied unchanged to the domain root. The platform installer work places
`install.sh` and `install.ps1` there, which makes them available at `/install.sh` and
`/install.ps1` as plain files.

## Cloudflare Pages

Cloudflare Pages owns builds and deployments through its native GitHub integration. Configure the
project with:

- Production branch: `main`
- Framework preset: None
- Build command: `npm ci && npm run build`
- Build output directory: `dist`
- Root directory: `site`

No GitHub Actions secrets are required. Cloudflare builds pull-request previews and deploys the
production site when `main` changes. After the first deployment, attach `axn.dev` as the project's
custom domain in the Cloudflare dashboard. DNS configuration is intentionally not managed here.