# axn.dev

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

The deployment workflow expects an existing Cloudflare Pages project named `axn-dev` and these
GitHub Actions repository secrets:

- `CLOUDFLARE_API_TOKEN`: a Cloudflare API token with Pages edit permission.
- `CLOUDFLARE_ACCOUNT_ID`: the account identifier that owns the Pages project.

After the first deployment, attach `axn.dev` as the project's custom domain in the Cloudflare
dashboard. DNS configuration is intentionally not managed by this repository.