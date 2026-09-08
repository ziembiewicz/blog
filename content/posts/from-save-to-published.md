---
title: "From Save to Published: The Pipeline Behind a Static Blog"
date: 2026-09-08T13:20:04+02:00
draft: true
categories: ["DevOps"]
tags: ["hugo", "github-actions", "github-pages", "ci-cd", "git"]
cover: "/img/posts/from-save-to-published.jpg"
coverAlt: "grayscale photography of metal pipes"
coverCredit: "Samuel Sianipar"
coverCreditUrl: "https://unsplash.com/@samthewam24?utm_source=blog-devops&utm_medium=referral"
description: "Hosting a blog on GitHub Pages is a solved problem. The interesting part is everything between pressing Ctrl+S and the page being live — two feedback loops, one trust boundary, and a handful of decisions that look trivial until they bite."
---

Setting up a blog is not an engineering achievement. Hugo renders Markdown, GitHub hosts the
result, and you are done in an afternoon.

What makes it worth writing about is that the path from *a character typed in an editor* to
*bytes served from a CDN* contains, in miniature, nearly everything a real deployment pipeline
contains: a fast inner loop, a slow outer loop, a trust boundary where secrets must not cross,
a build that has to be reproducible on a machine you have never seen, and a set of permissions
that should be exactly as wide as the job needs and no wider.

This post walks that path end to end and explains the machinery at each step — not just which
commands to run, but what is actually happening underneath.

## Installing Hugo locally

Hugo ships as a single binary with no runtime dependencies. There is one meaningful choice:
the **extended** edition. It bundles the WebP encoder and the embedded Sass/SCSS transpiler.
If a theme calls `resources.ToCSS` or does image processing, the standard edition fails the
build with an unhelpful error. Install extended and stop thinking about it.

```powershell
# Windows
winget install Hugo.Hugo.Extended
```

```bash
# macOS
brew install hugo

# Linux — the snap and most distro packages are the extended build,
# but the .deb from the release page is the one CI uses, so it is the one to match
sudo snap install hugo
```

Verify that the word `extended` actually appears:

```console
$ hugo version
hugo v0.165.0+extended windows/amd64
```

That `+extended` suffix is the whole point of the check. A version number alone tells you
nothing about whether your local build matches CI.

## The inner loop: what actually happens on Ctrl+S

```bash
hugo server -D    # -D also builds drafts
```

The server prints a few lines that are easy to scroll past and worth reading:

```console
Built in 10 ms
Environment: "development"
Serving pages from disk
Running in Fast Render Mode. For full rebuilds on change: hugo server --disableFastRender
Web Server is available at http://localhost:1313/ (bind address 127.0.0.1)
```

Four separate mechanisms are involved in getting a saved file onto your screen.

**1. A filesystem watcher.** Hugo registers a recursive watch on the project directory through
the OS notification API — `ReadDirectoryChangesW` on Windows, `inotify` on Linux, `FSEvents` on
macOS. This is push, not polling: the kernel tells Hugo the moment your editor closes the file
handle. That is why the delay feels like zero rather than like a one-second tick.

**2. An incremental rebuild.** *Fast Render Mode* re-renders only the pages affected by the
change instead of the whole site. Editing one post rebuilds one page. This is why the rebuild
stays in the low milliseconds even as the site grows — and also why, if you ever see a stale
page after changing a template or a config value, `--disableFastRender` is the first thing to
reach for.

**3. A LiveReload client injected into the page.** Hugo rewrites the HTML on the way out and
adds a script tag that is not in your templates and not in your production output:

```html
<script src="/livereload.js?mindelay=10&v=2&port=1313&path=livereload"
        data-no-instant defer></script>
```

That script opens a WebSocket back to the dev server on the `/livereload` path. When a rebuild
finishes, the server pushes a message down that socket and the client either swaps the
stylesheet in place — CSS changes apply without losing scroll position or form state — or
reloads the document. The injection happens only in the development server; the same page
built by `hugo` for production contains no trace of it.

**4. Serving from disk.** Note the `Serving pages from disk` line. By default the dev server
writes rendered pages to `public/` and serves them from there. This has a consequence that is
genuinely worth internalising:

> Running a production `hugo --minify` build in another terminal **while the dev server is
> running** overwrites `public/` underneath it. The server happily serves your minified
> production output, and you spend twenty minutes wondering why your draft "disappeared".

Symptom: the page in the browser does not match the source you are editing, and hard-refreshing
does not help. Fix: stop the production build, or start the server with `--renderToMemory` so
the two never share a directory. It is the local, small-scale version of two pipelines writing
to the same artifact store — the same bug class, with the same confusing symptoms.

**Two flags worth knowing**, because both cause "my post vanished" reports:

| Flag | Without it |
|---|---|
| `-D` / `--buildDrafts` | pages with `draft: true` are skipped entirely |
| `-F` / `--buildFuture` | pages with a `date` in the future are skipped entirely |

The second one is sneakier than it sounds. `date: 2026-09-08T11:00:00+01:00` looks like today,
but that offset is Central European *Winter* Time. In September the correct offset is `+02:00`,
so what you actually wrote was 12:00 local — and at 11:30 the post is in the future and Hugo
drops it from the build. Use `hugo new`, which stamps the current time with the correct offset,
and this whole class of problem disappears.

## The trust boundary: what git is allowed to know

Before anything reaches GitHub, decide what is *source* and what is *derived*.

```gitignore
public/            # build output — derived from source, regenerated every build
resources/_gen/    # processed images and compiled CSS — a cache, not source
.hugo_build.lock
.env               # secrets — must never cross this line
```

`public/` is committed by a surprising number of Hugo repositories, and it is always a mistake.
It produces merge conflicts in generated HTML, it doubles the size of every diff, and it makes
the repository the second source of truth for something the build already determines. If the
build is reproducible you do not need to store its output. If it is not reproducible, storing
the output hides that problem instead of fixing it.

`.env` is the other side of the same principle. This site pulls cover images from the Unsplash
API, which needs an API key. The key lives in `.env`, `.env` is ignored, and a committed
`.env.example` documents the shape without the value:

```bash
UNSPLASH_ACCESS_KEY=your-access-key-here
```

There is a second, less obvious decision behind that. The Unsplash call happens **when I write
the post**, on my machine — not during the build. A helper script searches Unsplash, downloads
the image into `static/img/posts/`, and writes the photographer credit into the post's front
matter. The image is committed like any other asset.

The alternative — calling the API from a template during `hugo build` — is genuinely tempting,
because Hugo's `resources.GetRemote` supports custom headers and would make it a five-line
template change. It is also how you build a deployment that fails on a Tuesday for reasons
unrelated to anything you changed:

- The API key would have to become a CI secret, widening the blast radius of the pipeline.
- Every CI build starts with a cold cache, so every build would re-fetch every image.
- Unsplash's demo tier allows 50 requests per hour. At 25 posts with two calls each, a single
  clean build exhausts the quota and the deploy fails — not because the site is broken, but
  because a third party is rate-limiting a build step that had no business being there.

**Fetching an asset is authoring work, not build work.** Moving it out of the pipeline costs
one script and buys a build that depends on nothing but the repository and a Hugo binary.

## Committing and pushing

```bash
git init
git add .
git commit -m "init: hugo blog + phosphor theme"
git branch -M main
git remote add origin git@github.com:USER/REPO.git
git push -u origin main
```

The repository name determines the URL. `USER.github.io` publishes at the root; any other name,
say `blog`, publishes under `https://USER.github.io/blog/`. That distinction matters more than
it looks — every internal link in the built site depends on it, which is exactly why the
workflow does not hardcode it.

Then, once in the repository settings: **Settings → Pages → Build and deployment → Source:
GitHub Actions**. Without this, GitHub uses its own legacy Jekyll pipeline and quietly ignores
the workflow you wrote.

## The outer loop: GitHub Actions

Here is the workflow this site runs, in full, with the reasoning for each block.

### Trigger

```yaml
on:
  push:
    branches: [main]
  workflow_dispatch:
```

Publishing on push to `main` makes the default branch the source of truth: what is on `main` is
what is live, with no separate "deploy" ritual to forget. `workflow_dispatch` adds a manual
button, which matters more than it seems — it lets you re-run a deploy without inventing an
empty commit when something external changed.

### Permissions

```yaml
permissions:
  contents: read
  pages: write
  id-token: write
```

This is least privilege, spelled out. Declaring any `permissions` block replaces the default
token scope entirely, so the job gets these three and nothing else. A compromised action in
this workflow cannot push to the repository, because `contents` is read-only.

`id-token: write` is the interesting one. It does not grant access to anything directly — it
allows the job to request a short-lived OIDC token from GitHub's identity provider. The
`deploy-pages` action presents that token as proof of *which repository, which workflow and
which branch* is requesting the deployment. Pages verifies the claims before accepting the
upload. There is no long-lived deploy key anywhere in this setup, and nothing to rotate or
leak, because the credential is minted per run and expires with it.

### Concurrency

```yaml
concurrency:
  group: pages
  cancel-in-progress: false
```

Two pushes in quick succession would otherwise race, and a static host has no notion of an
atomic swap between two competing uploads. The named group serialises them.

`cancel-in-progress: false` is a deliberate choice rather than a default. Cancelling would be
right for CI checks, where only the newest commit's result matters. It is wrong for deployment:
killing a half-finished upload can leave the site in a partially-updated state. Let the running
deploy finish; queue the next one behind it.

### Build job

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    env:
      HUGO_VERSION: 0.139.0
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive
          fetch-depth: 0
      - name: Install Hugo (extended)
        run: |
          wget -O ${{ runner.temp }}/hugo.deb https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_extended_${HUGO_VERSION}_linux-amd64.deb
          sudo dpkg -i ${{ runner.temp }}/hugo.deb
```

Four decisions in that short block:

- **Pinned version.** `HUGO_VERSION` is explicit, not "latest". A build that silently changes
  toolchain versions is a build that breaks at the worst possible moment, and the failure will
  look like it came from your last commit.
- **`submodules: recursive`.** Many Hugo themes are git submodules. Without this the theme
  directory is empty and the build fails with a confusing "template not found".
- **`fetch-depth: 0`.** A full clone rather than a shallow one, because Hugo can derive
  `.Lastmod` from git commit timestamps — which needs the history to be present.
- **Extended edition again**, matching what runs locally. The whole point of pinning is that
  local and CI agree.

```yaml
      - id: pages
        uses: actions/configure-pages@v5
      - name: Build
        env:
          HUGO_ENVIRONMENT: production
        run: hugo --gc --minify --baseURL "${{ steps.pages.outputs.base_url }}/"
```

`configure-pages` queries the Pages API and outputs the site's real base URL. Feeding it into
`--baseURL` means the same workflow produces correct absolute links whether the site lives at
`USER.github.io` or `USER.github.io/blog/` — and keeps working if you later attach a custom
domain. Hardcoding that URL is the single most common cause of a site that renders but whose
every stylesheet and link 404s.

`--gc` cleans unused cache entries after the build; `--minify` strips whitespace from HTML, CSS
and JS. `HUGO_ENVIRONMENT: production` is what makes `hugo.IsProduction` true in templates, so
analytics snippets and similar can be excluded from local development.

### A gate that reports without blocking

```yaml
      - name: Check links (non-blocking)
        continue-on-error: true
        run: |
          curl -sSL https://github.com/wjdp/htmltest/releases/download/v0.17.0/htmltest_0.17.0_linux_amd64.tar.gz | tar xz htmltest
          ./htmltest -c .htmltest.yml public
```

`htmltest` crawls the built output for broken internal links, missing images and malformed
anchors. `continue-on-error: true` makes it advisory: the result is visible in the Actions log,
but a dead link does not block publication.

That is a judgement about **what a failing check should cost**. A broken link on a personal blog
is worth knowing about and not worth blocking a deploy over. A failing test suite on a payment
service is worth blocking over. The mechanism is identical; only the severity assignment
differs, and being deliberate about that assignment is most of what separates a pipeline people
trust from one people learn to ignore.

### The handoff

```yaml
      - uses: actions/upload-pages-artifact@v3
        with:
          path: ./public

  deploy:
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    runs-on: ubuntu-latest
    needs: build
    steps:
      - id: deployment
        uses: actions/deploy-pages@v4
```

`upload-pages-artifact` tars `public/` and uploads it as a workflow artifact in the specific
format Pages expects. The `deploy` job then runs on a **fresh runner** with no checkout, no
Hugo, and no source code — it only takes the artifact and hands it to Pages.

Splitting build from deploy is not ceremony. It means the thing that gets published is exactly
the artifact that was built and link-checked, with no opportunity for a later step to modify it.
It gives Pages a single, well-defined input. And it keeps the deploy step's dependencies
minimal, which matters because that is the step holding the OIDC token.

The `environment:` block registers the deployment in the repository's Environments tab with a
clickable URL, and is where you would attach a required-reviewer approval gate if you ever
wanted a human in the loop.

## What the two loops cost

| | Inner loop | Outer loop |
|---|---|---|
| Trigger | Ctrl+S | `git push` |
| Mechanism | fsnotify → incremental render → WebSocket | Actions → artifact → Pages |
| Duration | milliseconds | ~1 minute |
| Scope | one page | whole site |
| Failure cost | a stale browser tab | a broken public site |

Almost all of the work happens in the left column. The right column exists to make the
transition from "works on my machine" to "works for everyone" boring and repeatable. That is
the actual product of a pipeline: not automation for its own sake, but the removal of the
question *did I remember to do all the steps?*

## When it breaks

- **Build fails in CI, works locally.** Compare versions first. Nine times out of ten it is the
  standard vs extended edition, or a `HUGO_VERSION` that drifted from what you have installed.
- **Site deploys but has no styling.** `baseURL`. Check what `configure-pages` actually
  resolved to in the build log.
- **Post is missing from the deployed site.** `draft: true`, or a future `date` — CI has no
  `-D` and no `-F`, so both are silently dropped. Reproduce with a plain `hugo --gc --minify`
  locally, which behaves exactly like CI, rather than with `hugo server -D`, which does not.
- **Workflow does not run at all.** Pages source is still set to the legacy branch-based
  deployment instead of GitHub Actions.

## Closing

None of the individual pieces here are difficult. Pinning a version, scoping a token,
serialising deploys, deciding that a link check reports rather than blocks, keeping an API call
out of the build path — each is a small decision, and any one of them could be skipped without
immediate consequence.

The point is that they compound. Taken together they produce a system where publishing is a
`git push`, where the deployed site is a deterministic function of the repository, and where
nothing in the pipeline holds a credential that outlives the run that used it.

That is worth practising on something with no stakes, precisely so the reasoning is already
automatic when the stakes are real.
