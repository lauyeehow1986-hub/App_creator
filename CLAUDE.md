# CLAUDE.md

Guidance for Claude (and other AI assistants) working in this repository.

## What this project is

`shinyalcatraz` (GitHub repo name: `app_creator`) is an R package that
turns a Shiny app into one or more **portable, zero-admin-install
bundles** for locked-down environments: copy the output folder onto the
target machine (USB, network share, mapped drive) and run it, with no R
install, no internet, and no administrator rights required on that
target machine.

It is a *build tool*, analogous to electron-builder or `usethis`'s role
for R packages — not itself a Shiny app. Read
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) before touching anything
under `R/` — it records *why* the three build targets are shaped the way
they are, the constraints they're designed around, and what's explicitly
deferred. Don't re-derive or contradict those decisions without a good
reason and a note in that file.

## Current status (check before assuming something works)

| Piece | Status |
|---|---|
| `build_wasm()` | Implemented and **verified end-to-end on a real Windows machine**: real `shinylive` export, bundle renders a working Shiny app in a real browser — served via the generated `serve.ps1`, since `file://` is blocked by CORS (that fallback was added as a fix this run). See Verification notes. |
| `build_portable()` (Windows) | Implemented and **verified end-to-end on a real Windows machine**: downloads/caches a real R-Portable, installs the app's full transitive dependency tree into the bundle's private library, and the generated `run.bat` actually launches the Shiny app in a browser. Three real Windows-only bugs were found and fixed doing this. macOS/Linux `cli_abort()` as not implemented. Also installs from CRAN/Bioc/all git-forge+URL remotes/r-universe/PPM/local tarballs. Launchers: `run.bat` (console) + `run.vbs` (windowless); all R output logged to `log/last-run.txt`, which auto-opens on error (verified incl. forced-crash path). **Reproducible builds**: `r_portable_version` pins R; `snapshot="YYYY-MM-DD"` pins all CRAN package versions via a Posit PM snapshot (renv-free); manifest records `r_version`/`r_source`/`snapshot`/`package_versions`. **Portable R source** (`r_source`): default `"github"` (selkamand/r-portable-windows, recent R via GitHub release zips); `"cran"` builds portable R from the *official* `R-<ver>-win.exe` (silent Inno `/CURRENTUSER /DIR` extract) for **any** version incl. the latest; `"sourceforge"` (frozen at 4.2.0) is the legacy fallback. `"github"` auto-falls-back to `"cran"` for versions selkamand lacks. Verified end-to-end: `r_portable_version="4.6.1"` → fetched R 4.6.1, full 30-pkg shiny tree, app serves (HTTP 200); also `snapshot="2026-01-01"` on R 4.5.1 → shiny 1.12.1 frozen. Manifest records the *effective* source (post-fallback). A same-R-version isolation bug was found+fixed here: setting `R_LIBS_USER=""` isn't isolation (R falls back to the build machine's `win-library/<ver>`, so deps get skipped) → point it at the bundle library. |
| `build_portable()` native runtimes | `native_runtime_providers()` registry stages the *external* runtime a package needs (impossible in wasm, hence portable-only), all **verified end-to-end offline on Windows**: **rJava** (portable Temurin JRE), **tesseract** (OCR traineddata), opt-in **`RMariaDB(server=TRUE)`** (portable MariaDB server: datadir bootstrap + `mysqld` on 127.0.0.1 + graceful shutdown), and opt-in **`rstan`/`brms`(`rtools=TRUE`)** (bundled Rtools: version matched to the bundled R's ABI, silent non-admin install, compiles R-loadable C++ with the system toolchain stripped from PATH). **RMariaDB** client works offline as-is. The two opt-in paths are gated only because they're large (~150MB / ~500MB), not unproven. `build_portable(runtimes=)` is a coarse preset (`"none"`/`"all"`/`"auto"`) for shipping a small **lite** bundle and a self-contained **full** one from the same app; the manifest records the mode + which runtimes were bundled. See `docs/ARCHITECTURE.md` "Native-runtime provisioning". |
| `build_tauri()` (`backend = "wasm"`, desktop) | Implemented and **verified end-to-end on a real Windows machine**: real `cargo tauri build` produces a native `.exe` that launches, and its WebView2 window renders the shinylive Shiny app running webR (reactive UI + a rendered plot + data table). Three real Windows-only bugs were found and fixed doing this (missing `icons/icon.ico`; absolute `frontendDist` → directory listing; shinylive's service worker needs a `http://localhost` origin → `tauri-plugin-localhost`). Also compile-verified on Linux earlier. `backend = "portable"` and mobile platforms `cli_abort()` as not implemented. |
| `enable_update_check()` | Implemented and tested (injection logic + generated JS syntax-checked with `node --check`); the JS itself has not been exercised in a real browser. |
| `build()` dispatcher | Implemented, routes to the above |
| Tests | `tests/testthat/test-build.R` - fast unit tests run every time; a few slow/network/toolchain tests are gated behind `SHINYALCATRAZ_RUN_NETWORK_TESTS=1` (see below) |
| CI | `.github/workflows/R-CMD-check.yaml` present, itself unverified (GitHub Actions runners weren't exercised from this sandbox) |
| Demo app | `inst/examples/demo-app/` — plain `shiny`-only app, no extra deps, used to exercise the pipeline |

## Codebase structure

```
DESCRIPTION, NAMESPACE, LICENSE, LICENSE.md   Standard R package metadata (MIT license)
R/
  build.R                  build() dispatcher + target validation
  target-wasm.R            build_wasm() - implemented & verified on Windows (see below)
  target-portable.R        build_portable() - Windows implemented & verified
  target-tauri.R           build_tauri() - implemented & verified end-to-end on Windows (see below)
  update-check.R           enable_update_check() - implemented & tested
  utils.R                  check_app_dir(), write_build_manifest(), git_sha(), dir_size(), %||%
  shinyalcatraz-package.R  package-level roxygen doc (_PACKAGE)
inst/examples/demo-app/    Minimal demo Shiny app (shiny only, no extra deps)
tests/testthat/            Fast tests + a few network/toolchain-gated integration tests
man/                       roxygen2-generated - regenerate with roxygen2::roxygenise(".") after any @param/@export change, don't hand-edit
docs/ARCHITECTURE.md       Design decisions and tradeoff matrix - READ THIS FIRST
.github/workflows/         R-CMD-check CI
```

## Development workflow

R **is not guaranteed to be present** in every environment an AI
assistant runs in. If it's missing, Ubuntu's `apt` has precompiled
binaries for every dependency this package needs (`r-base-core` plus
`r-cran-{cli,fs,jsonlite,rlang,testthat,roxygen2,pkgload,desc}`) — this
worked when CRAN itself was network-policy-blocked in the sandbox that
built this package, so prefer it over `install.packages()` if CRAN is
unreachable. `p7zip-full` is also needed on the build machine for
`build_portable()` (unpacks the R-Portable archive), and a Rust
toolchain + `libwebkit2gtk-4.1-dev`/`libgtk-3-dev`/etc. (or `npx
@tauri-apps/cli`, which ships a prebuilt binary and needs no local Rust
install) for `build_tauri()`.

```r
devtools::load_all()   # iterate
devtools::document()   # regenerate NAMESPACE/man/ after changing roxygen comments or exports
devtools::test()       # run tests/testthat (fast subset by default)
devtools::check()      # full R CMD check before anything you'd call "done"
```

If R is genuinely unavailable and can't be installed, say so explicitly
rather than claiming a change works — this mirrors the project's own
top-level instruction to never claim success on unverified code.

### Testing a build end-to-end

```r
library(shinyalcatraz)
demo_app <- system.file("examples", "demo-app", package = "shinyalcatraz")
build_wasm(demo_app, out_dir = "dist/wasm")       # unverified in this sandbox - see below
build_portable(demo_app, out_dir = "dist/portable", platform = "windows")  # verified
build_tauri(demo_app, out_dir = "dist/tauri")     # verified (backend = "wasm", desktop)
```

Slow/network/toolchain-dependent integration tests (real downloads, real
compiles) are skipped by default and gated behind an env var:

```r
Sys.setenv(SHINYALCATRAZ_RUN_NETWORK_TESTS = "1")
devtools::test()
```

### Verification notes (read this before trusting "implemented")

This package was originally built in a sandbox with a restrictive
egress policy, then given a **second verification pass on a real
Windows 11 machine**. Both are recorded below — trust the Windows-pass
result where the two differ, but keep the sandbox context because it
explains *why* some things are shaped the way they are.

- **`build_wasm()`**: **verified end-to-end on Windows** (superseding
  the sandbox, where `shinylive`'s CDN was blocked so it couldn't run
  at all). Real `shinylive` export produced a bundle that renders a
  working Shiny app in a real browser. One real bug surfaced only by
  running it: opening `index.html` off `file://` is a permanently blank
  page — the shinylive service worker is blocked by CORS under
  `file://` — so a `serve.ps1` fallback (plain `System.Net.HttpListener`
  on `localhost`, no admin/`netsh` needed) was added between the
  `python3` and bare-`file://` launcher tiers. See the
  "Why no bundled static-server binary" section of
  `docs/ARCHITECTURE.md`. (Caveat: the export step still needs network
  — `shinylive`/`pkgcache` phones `bioconductor.org` for a version
  check — so a fully-offline *rebuild* isn't possible; the *output*
  bundle is fully offline, which is the point.)
- **`build_portable()`**: **verified end-to-end on Windows**, including
  the two things the sandbox couldn't do (it's a Linux box): actually
  running the bundled `Rscript.exe` to install packages, and launching
  the finished `run.bat`. Doing this surfaced **three real, silent
  Windows-only bugs**, all now fixed in `R/target-portable.R` and
  documented in the "build_portable() Windows notes" section of
  `docs/ARCHITECTURE.md`: (1) `curl`'s schannel backend hangs on
  cert-revocation-check failures → `--ssl-no-revoke` (Windows-gated);
  (2) the build machine's own `R_LIBS_USER` leaks into the bundled R
  via `system2()` and loads an ABI-incompatible DLL → clear
  `R_LIBS*` with `Sys.setenv()` (not `system2(env=)`, which is broken
  on this R/Windows combo); (3) `install.packages()` silently prefers
  a newer *source* release over the older *binary* for R-Portable's
  pinned R → force `type = "win.binary"`.
- **`build_tauri()`**: **verified end-to-end on Windows** — `cargo tauri
  build` produced a native `.exe` (~8MB) that launches and whose WebView2
  window renders the shinylive Shiny app running webR (reactive UI, a
  live plot, and a data table computed by R-in-WASM). Getting there
  surfaced **three real Windows-only bugs the earlier Linux compile-only
  check could not** (compiling ≠ running the window), all fixed in
  `write_tauri_project()` and documented in the "Native shell notes"
  section of `docs/ARCHITECTURE.md`: (1) `tauri-build` aborts with
  "`icons/icon.ico` not found" — Windows resource embedding needs a real
  `.ico`, not just the `.png`; (2) an **absolute** `frontendDist` is
  loaded at runtime as `file://<dir>/`, so the webview shows a directory
  listing, never the app — the frontend is now copied into the project
  and referenced relative (`../frontend`) so `generate_context!()`
  embeds it and serves it over the app protocol; (3) shinylive's service
  worker (which webR needs) refuses Tauri's default `http://tauri.localhost`
  origin — fixed with `tauri-plugin-localhost`, which serves the embedded
  frontend over `http://localhost:<port>`. The three Linux-caught
  template bugs (absolute-path `frontendDist` handling, non-default
  `identifier`, unconditional `icons/icon.png`, plus the `platform`
  `arg_match(multiple = TRUE)` default-subset bug) still stand.
  The local HTTP listener is bound to `127.0.0.1` (loopback only) so it
  raises **no Windows Firewall prompt** (verified: `netstat` shows a lone
  `127.0.0.1:<port>` listener, clean launch shows no dialog). Two things
  were needed: `.host("127.0.0.1")` on the plugin, and reserving the port
  with a `std::net::TcpListener` on `127.0.0.1:0` instead of the
  `portpicker` crate — `portpicker` probes ports by binding `0.0.0.0`,
  and that wildcard bind alone triggers the prompt.
- **`enable_update_check()`**: the R-side file injection is unit
  tested; the generated JS was checked for syntax validity with `node
  --check` but never actually run in a browser against a real `fetch`.

## Conventions

**Coding style is deliberately minimal**, borrowed as an explicit
convention from the (unrelated, third-party) `ponytail` project's
"lazy senior dev" ruleset — not copied wholesale, just the philosophy:

1. Does this need to exist? If not (YAGNI), don't add it.
2. Does base R / an already-imported package already do it? Use that.
3. No abstractions, config options, or parameters that weren't actually
   asked for. Three similar lines beat a premature helper.
4. Fully-qualify calls to non-base packages (`fs::dir_create()`, not
   `library(fs)` + bare calls) — keeps `NAMESPACE`/imports obvious and
   avoids masking surprises. This is why `R/` has no `@importFrom` tags.
5. Not lazy about: input validation at trust boundaries (`check_app_dir()`
   exists for this reason), anything that would silently produce a
   broken offline bundle, and being honest when something is unimplemented
   (`build_portable()`/`build_tauri()` fail loudly and say so, rather than
   pretending to work).
6. When you deliberately cut a corner, say so in a comment naming the
   ceiling and the upgrade path — don't leave a silent limitation.

**Every build target must**, at minimum:
- Validate its `app_dir` via `check_app_dir()`.
- Write `manifest.json` via `write_build_manifest()` (version-stamping —
  every offline bundle must be identifiable/auditable without diffing
  files against another copy).
- Fail with `cli::cli_abort()` and a clear message, never a bare `stop()`.

**Adding a new build target**: add `R/target-<name>.R` with a
`build_<name>()` function following the pattern in `target-wasm.R`
(validate → do the work → `write_build_manifest()` → return the
manifest invisibly), register it in `match_targets()`'s `valid` vector
and the `switch()` in `build()`, add a row to the tradeoff table in
`docs/ARCHITECTURE.md`, and add tests mirroring `test-build.R`.

## Things not to do

- **Do not touch `lauyeehow1986-hub/ponytail`.** It's an unrelated,
  pre-existing third-party open-source project (an AI-coding-style
  plugin) that happened to be in this session's repo scope. Only its
  *philosophy* (see Conventions above) was deliberately borrowed into
  this project's own `CLAUDE.md` — nothing in that repo itself should be
  modified as part of work on `shinyalcatraz`.
- Don't extend `build_portable()` to macOS/Linux, or `build_tauri()` to
  `backend = "portable"`/mobile, without re-reading `docs/ARCHITECTURE.md`'s
  "Native shell notes" and "Explicitly deferred" sections first — there
  are real platform caveats (WebView2 bundling, R-Portable library
  isolation) that are easy to get wrong silently.
- Don't trust a Tauri config template (yours or anyone else's) that
  hasn't actually been run through `cargo tauri build` — see
  "Verification notes" above for three real, non-obvious bugs a
  read-only review would have missed.
- Don't add a bundled static-server binary to `build_wasm()`'s launcher
  path — see "Why no bundled static-server binary" in
  `docs/ARCHITECTURE.md` for why that's a deliberate size/complexity
  tradeoff, not an oversight.
- Don't commit build output. `dist/`, `build/`, `src-tauri/target/`,
  `node_modules/`, and toolchain caches are gitignored on purpose —
  generated bundles are large and fully reproducible from source.

## Git workflow

- Feature work happens on branches; this scaffold was created on
  `claude/claude-md-shiny-package-082zmw`.
- Keep commits scoped and descriptive. This is a young, fast-moving
  package — prefer small, reviewable commits over large ones while the
  architecture is still settling.
