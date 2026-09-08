---
title: "Blog in a DevOps pipelines way"
date: 2026-09-08T13:20:04+02:00
draft: false
categories: ["DevOps"]
tags: ["hugo", "github-actions", "github-pages", "ci-cd", "git"]
cover: "/img/posts/2026-09-08-blog-devops-way.jpg"
coverAlt: "grayscale photography of metal pipes"
coverCredit: "Samuel Sianipar"
coverCreditUrl: "https://unsplash.com/@samthewam24?utm_source=blog-devops&utm_medium=referral"
description: "You know that as a DevOps engineer, you can’t just set up WordPress, install a bunch of plugins, and hope that after a month, no new CVEs will take down your blog on that platform, right? Well, here’s how to do it the hard way :)"
---

Setting up a blog is not an engineering achievement. Hugo renders Markdown, GitHub hosts the
result, and you *are** done in an afternoon.

What makes it worth writing about is that the path from *a character typed in an editor* to
*bytes served from a CDN* contains, in miniature, nearly everything a real deployment pipeline
contains: a fast inner loop, a slow outer loop, a trust boundary where secrets must not cross,
a build that has to be reproducible on a machine you have never seen, a set of permissions that
should be exactly as wide as the job needs and no wider, and — at the very end — DNS and TLS,
where the ordering of two clicks is a security control rather than a preference.

This post walks that path end to end and explains the machinery at each step: not just which
commands to run, but what is happening underneath and why it fails the way it does. Everything
here is from an actual first deployment, including the parts that went wrong.

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
git init && git branch -M main
git add .
git commit -m "init: hugo blog + phosphor theme"
gh repo create blog --public --source=. --remote=origin --push
```

The repository name determines the default URL. `USER.github.io` publishes at the root; any
other name, say `blog`, publishes under `https://USER.github.io/blog/`. That distinction matters
more than it looks — every internal link in the built site depends on it, which is exactly why
the workflow does not hardcode it.

### Two authentication traps

This is where a first push tends to fail, and both failure modes are worth knowing because the
error messages point away from the actual cause.

**The token needs the `workflow` scope.** The repository contains
`.github/workflows/deploy.yml`, and GitHub refuses to let an OAuth token create or update
workflow files unless it carries that scope. A default `gh` login does not include it. Every
other file pushes fine and the one file that makes the pipeline exist is rejected:

```bash
gh auth refresh -h github.com -s workflow
```

**The protocol setting is per-host.** `gh config set git_protocol https` sets a global default
that a host-specific entry silently overrides. If `gh auth status` says *Git operations
protocol: ssh* while your SSH key belongs to a different GitHub account than the one `gh` is
authenticated as, the repository gets created under the right account and the push is then
rejected as the wrong one:

```console
$ gh repo create blog --public --source=. --remote=origin --push
https://github.com/USER/blog
ERROR: Permission to USER/blog.git denied to OTHER-ACCOUNT.
```

The repository exists at that point; only the push failed. Fix the host-level setting and the
remote, then push:

```bash
gh config set -h github.com git_protocol https
git remote set-url origin https://github.com/USER/blog.git
git push -u origin main
```

The general lesson is worth more than the specific fix: **an identity mismatch surfaces at the
step furthest from its cause.** Check `gh auth status` and `ssh -T git@github.com` and confirm
they name the same account before you debug anything else.

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
      HUGO_VERSION: 0.165.0
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

## Turning it on: Pages, DNS and the certificate

The pipeline exists now, but nothing serves it yet. This last stretch is where most of the
waiting lives, and where the ordering genuinely matters.

### Enable Pages before the first push, or expect a red run

`actions/configure-pages` asks the Pages API for the site's base URL. If Pages has never been
enabled on the repository, there is no site to ask about and the step fails:

```console
X Get Pages site failed. Please verify that the repository has Pages enabled and configured
  to build using GitHub Actions.
  Error: Not Found
```

The push already triggered a run, so the first thing you see in a fresh repository is a failure
that has nothing to do with your code. Either enable Pages before pushing, or enable it and
re-run. The UI path is **Settings → Pages → Build and deployment → Source: GitHub Actions**; the
API does the same thing without leaving the terminal:

```bash
gh api -X POST repos/USER/blog/pages -f build_type=workflow
```

`build_type=workflow` is the important part. Without it Pages falls back to its legacy
branch-based Jekyll pipeline and quietly ignores the workflow you just wrote.

### Claim the domain in GitHub *before* touching DNS

```bash
gh api -X PUT repos/USER/blog/pages -f cname=blog.example.com
```

This ordering is a security control, not a preference. GitHub's own documentation is blunt about
it: pointing DNS at GitHub *before* the domain is registered to your repository leaves a window
in which somebody else can claim that hostname on Pages and serve their content from your
subdomain. Claim first, then point.

### The DNS record

At the registrar, in the zone for your domain:

```
# subdomain — one record
Type:   CNAME
Name:   blog
Target: USER.github.io.

# apex — four A records instead
@  A  185.199.108.153
@  A  185.199.109.153
@  A  185.199.110.153
@  A  185.199.111.153
```

Three things reliably go wrong here:

- **The target is the account, not the repository.** `USER.github.io.`, never
  `USER.github.io/blog`. The repository is resolved by GitHub from the incoming `Host` header.
- **The trailing dot.** In most zone editors an unqualified target is treated as relative and
  the zone origin gets appended, turning `USER.github.io` into
  `USER.github.io.example.com`. Some panels add the dot for you; some do not. Check what the
  zone actually contains after saving.
- **Saving is not applying.** Several providers — OVH among them — stage zone edits and apply
  them in a separate step. It is entirely possible to fill the form, close the tab, and have
  changed nothing.

Verify against the authoritative nameserver rather than your resolver, which skips propagation
delay and cache entirely:

```bash
# who is authoritative for the zone
nslookup -type=NS example.com 8.8.8.8

# ask one of them directly
nslookup -type=CNAME blog.example.com ns.provider.example
```

If the authoritative server returns `Non-existent domain`, the record is not there. That is a
different problem from "not propagated yet", and waiting will not fix it.

### The certificate, and the wait

Once DNS resolves, GitHub verifies the domain and queues a certificate request to Let's Encrypt
on your behalf. You cannot supply your own certificate — Pages manages TLS termination itself
and there is no bring-your-own-certificate option.

Provisioning is not instant. On this site it took **five and a half minutes** from the DNS
record going live to HTTPS answering; GitHub's documentation allows up to 24 hours. Rather than
refreshing the settings page, poll for it:

```bash
until [ "$(curl -s -o /dev/null -m 15 -w '%{http_code}' https://blog.example.com/)" = "200" ]; do
  sleep 30
done
```

You can watch the state directly, too:

```console
$ gh api repos/USER/blog/pages --jq '.https_certificate.state'
approved
```

### The `.dev` trap: the site is live and the browser still refuses

This one deserves its own warning, because every diagnostic disagrees with the browser.

`.dev` is on the HSTS preload list compiled into Chrome, Firefox, Edge and Safari. The registry
states it plainly:

> The .dev top-level domain is included on the HSTS preload list, making HTTPS required on all
> connections to .dev websites and pages without needing individual HSTS registration or
> configuration.

"Required" is literal. Browsers refuse plain HTTP to any `.dev` hostname outright — not a
redirect, not a warning, a hard failure before the request leaves the machine, and nothing the
site operator can opt out of. `.app` carries the same policy.

So in the window between DNS going live and the certificate being issued:

```console
$ curl -s -o /dev/null -w '%{http_code}' http://blog.example.com/
200
```

…while the browser shows a connection error. `curl` is not bound by preload lists, so it happily
speaks HTTP and reports a perfectly healthy site. Nothing is broken; the certificate simply is
not there yet. If your domain is `.dev` or `.app`, **there is no usable window before
the certificate lands** — plan for it rather than debugging it.

### Enforce HTTPS, then rebuild — the step people skip

```bash
gh api -X PUT repos/USER/blog/pages -F https_enforced=true
```

That flips the redirect on. It does **not** fix your generated content, and this is the part that
gets missed.

While HTTPS was not yet enforced, `configure-pages` reported the site's base URL as
`http://blog.example.com/`, and the build faithfully used it:

```console
Run hugo --gc --minify --baseURL "http://blog.example.com/"
```

Every absolute URL Hugo generated — the RSS feed, the sitemap, canonical tags — is baked with
`http://`. Relative links inside pages are unaffected, which is exactly why this survives a
casual look at the site. Feed readers and crawlers see the `http://` URLs.

So after enabling enforcement, trigger a rebuild:

```bash
gh workflow run deploy.yml
```

This is the concrete payoff of the `workflow_dispatch` trigger from earlier. Nothing in the
repository changed — the *environment* changed — and without a manual trigger the only way to
republish would be an empty commit. Confirm it took:

```console
$ curl -s https://blog.example.com/index.xml | grep -o '<link>[^<]*</link>' | head -1
<link>https://blog.example.com/</link>
```

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
- **First run in a new repository fails on `configure-pages`.** Pages was never enabled. Enable
  it, then re-run — the commit is fine.
- **Push rejected for the workflow file only.** The token lacks the `workflow` scope.
- **Push rejected as a different account than the one that owns the repository.** `gh` and your
  SSH key are authenticated as different users. Compare `gh auth status` with
  `ssh -T git@github.com`.
- **`curl` says 200, the browser refuses to connect.** A `.dev` or `.app` domain before
  the certificate has been issued. Wait for provisioning; there is nothing to fix.
- **DNS "not propagated" for a long time.** Ask the authoritative nameserver directly. If it
  also returns `Non-existent domain`, the record was never applied — many panels stage zone
  edits behind a separate confirm step.
- **RSS and sitemap contain `http://` links on an HTTPS site.** The site was built before
  Enforce HTTPS was on. Re-run the workflow.

## Closing

None of the individual pieces here are difficult. Pinning a version, scoping a token,
serialising deploys, deciding that a link check reports rather than blocks, keeping an API call
out of the build path, claiming a domain before pointing DNS at it — each is a small decision,
and any one of them could be skipped without immediate consequence.

What is difficult is diagnosis, and that is where most of the time actually went. Nearly every
failure in this build announced itself somewhere other than where it originated: a push rejected
for the wrong account, a first run failing on a step unrelated to the commit that triggered it,
a browser refusing a site that `curl` reports as perfectly healthy, an RSS feed quietly carrying
`http://` links on an HTTPS site. None of those error messages point at their cause. Knowing the
mechanism underneath is what turns each of them from an afternoon into a minute.

The point is that they compound. Taken together they produce a system where publishing is a
`git push`, where the deployed site is a deterministic function of the repository, and where
nothing in the pipeline holds a credential that outlives the run that used it.

That is worth practising on something with no stakes, precisely so the reasoning is already
automatic when the stakes are real.
