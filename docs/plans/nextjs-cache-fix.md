# Next.js Cache Fix Plan

## Problem

When deploying new builds on Vercel, Grist data updates are not reflected on the site.
The site serves stale/cached data despite fresh deploys.

## Current Architecture

- **Next.js version**: 13.4.12
- **Data flow**: Build script (`downloadCacheData`) fetches from Grist API at build time and writes to `data/*.json` files. All pages use `getStaticProps` to read these JSON files and generate static pages.
- **Router**: Pages Router (`pages/`)
- **No ISR**: None of the `getStaticProps` return a `revalidate` property, so pages are purely static (SSG) - generated once at build time.
- **Hybrid routing**: There's also an `app/sitemap.ts` using the App Router.

## Root Cause Analysis

### Why stale data persists after deploy

The core issue is that **all pages use `getStaticProps` without `revalidate`**, meaning they are purely static. On Vercel, this creates a caching problem:

1. **Build cache**: Vercel caches the `.next` build output between deployments. If the build cache is reused, previously generated static pages (with old data) may be served even after a new deploy.

2. **CDN/Edge cache**: Even when pages are rebuilt, Vercel's edge network may serve cached versions of the static pages from previous deployments.

3. **Known Next.js 13.4.x caching bugs**: Next.js 13.4.x had several well-documented aggressive caching issues:
   - `fetch()` in the App Router defaulted to `force-cache`, caching responses indefinitely
   - The Data Cache persisted across deployments by default
   - Static pages generated via `getStaticProps` could be served from stale caches
   - These were partially addressed in 13.5.x where `fetch` defaults changed to `no-store`

4. **The `data/` directory**: The `downloadCacheData` script writes to `data/*.json` at build time. If Vercel's build cache includes this directory from a previous build and the download step fails silently, old data would be used.

### The hybrid App Router / Pages Router setup

Having `app/sitemap.ts` alongside `pages/` means the app uses both routers simultaneously. This is supported but the App Router's aggressive caching defaults in 13.4.x may interact poorly with the Pages Router pages.

## Proposed Fix: Update to Next.js 13.5.11

The latest stable Next.js 13.x release is **13.5.11**. This is the safest upgrade path that stays within the 13.x major version.

### Why 13.5.11

- 13.5.0 changed `fetch` default from `force-cache` to `no-store` (major caching fix)
- 13.5.x includes numerous caching-related bug fixes
- Staying on 13.x avoids the breaking changes of Next.js 14
- 13.5.11 is the latest patch, with all accumulated fixes

### Why not Next.js 14+

- Major version bump with significant breaking changes
- Would require more extensive testing and potentially code changes
- The SQLite migration (separate branch) is already in progress
- Better to fix the immediate caching issue first, then consider a major upgrade as part of the broader refactor

## Update Steps

### Step 1: Update Next.js and eslint-config-next

```
npm install --save-exact next@13.5.11
npm install --save-exact --save-dev eslint-config-next@13.5.11
```

### Step 2: Review Next.js 13.5.x breaking changes

Key changes between 13.4.12 and 13.5.11 to verify:

- **`fetch` caching default changed**: In App Router, `fetch()` now defaults to `no-store` instead of `force-cache`. Since the app primarily uses Pages Router with `getStaticProps`, this mainly affects `app/sitemap.ts`.
- **`@next/font` removed**: If used, must migrate to `next/font`. Check if the project uses this.
- **`next/image` changes**: Verify no breaking changes affect current usage.
- **`next/link` changes**: Verify no breaking changes affect current usage.

### Step 3: Add explicit Vercel cache-busting configuration

Even after upgrading, consider these additional measures:

1. **Disable Vercel build cache** for this project (via Vercel dashboard or `vercel.json`):
   ```json
   {
     "buildCommand": "npm run build",
     "framework": "nextjs"
   }
   ```
   Or set environment variable `VERCEL_FORCE_NO_BUILD_CACHE=1` in Vercel project settings.

2. **`data/` directory IS in `.gitignore`**: This means the JSON cache files are never committed. They must be freshly downloaded on every build via `downloadCacheData`. The Grist API requests do throw on HTTP errors, so a failed download should fail the build. However, if Vercel's build cache preserves the `data/` directory from a previous build AND the download fails silently for some other reason, stale data would be served. This is a likely contributor to the problem.

### Step 4: Verify data freshness in build

Add validation to the build script to ensure data was actually downloaded fresh:

- Log timestamps of downloaded data
- Fail the build if `downloadCacheData` fails (verify it currently does)

### Step 5: Test locally

```bash
npm run build
npm run start
```

Verify that pages render with current Grist data.

### Step 6: Test on Vercel

- Deploy to a preview branch
- Verify data is fresh
- Update Grist data, trigger a new deploy, verify the update is reflected

## Verification Checklist

- [ ] `npm run build` succeeds with Next.js 13.5.11
- [ ] `npm run lint` passes
- [ ] `npm run type-check` passes
- [ ] `npm run test:ci` passes
- [ ] Local dev server works (`npm run dev`)
- [ ] Pages render correctly with current data
- [ ] Preview deploy on Vercel shows fresh data
- [ ] After Grist data change + redeploy, new data appears

## Risk Assessment

- **Low risk**: This is a minor version bump within 13.x
- **Main concern**: The `fetch` caching default change, but this primarily affects App Router code (only `app/sitemap.ts` in this project)
- **Fallback**: If 13.5.11 causes issues, can try intermediate versions (13.4.19, 13.5.0, etc.)

## Alternative: Quick Fix Without Upgrade

If upgrading is too risky right now, setting `VERCEL_FORCE_NO_BUILD_CACHE=1` as a Vercel environment variable may resolve the immediate issue without any code changes. This forces Vercel to do a clean build every time, ensuring `downloadCacheData` runs fresh.

This should be tried first as a diagnostic step regardless of whether we upgrade.
