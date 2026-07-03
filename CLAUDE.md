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
| `build_wasm()` | Implemented. **Code unverified** - see Verification notes below. |
| `build_portable()` (Windows) | Implemented and verified end-to-end against the real internet (downloads/caches a real R-Portable, produces a real launcher). macOS/Linux `cli_abort()` as not implemented. |
| `build_tauri()` (`backend = "wasm"`, desktop) | Implemented and verified end-to-end: really compiles a working native binary via a real Tauri build. `backend = "portable"` and mobile platforms `cli_abort()` as not implemented. |
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
  target-wasm.R            build_wasm() - implemented, unverified (see below)
  target-portable.R        build_portable() - Windows implemented & verified
  target-tauri.R           build_tauri() - wasm-backend desktop implemented & verified
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

This package was built in a sandbox with a restrictive egress policy.
What actually got exercised, and what didn't:

- **`build_portable()`**: fully verified. Downloaded a real R-Portable
  4.2.0 from sourceforge (79MB, extracted with `7z`), copied it into a
  bundle, generated `run.bat`, wrote `manifest.json`. The one thing
  *not* verified is actually running the resulting Windows `.exe` /
  installing packages via it, since that requires Windows (`Rscript.exe`
  correctly fails with "cannot execute binary file" on Linux — handled
  as a warning, not a crash, so the rest of the pipeline still
  completes).
- **`build_tauri()`**: fully verified, including compiling and running
  the actual `cargo tauri build` toolchain. Two real bugs were caught
  and fixed this way that a code-only review would have missed: (1) a
  relative `frontendDist` path resolves against the wrong base
  directory unless written as absolute, and (2) `tauri::generate_context!()`
  panics at compile time if `identifier` is left at the `com.tauri.dev`
  default, *and* separately still looks for `icons/icon.png`
  unconditionally even with `bundle.active = false`. All three are now
  baked into `write_tauri_project()`. A separate real bug was also
  caught in the `platform` argument: `rlang::arg_match(multiple = TRUE)`
  treats an unspecified argument equal to the full `values` set as "the
  user selected everything," so a multi-select arg's *default* must be
  a real subset, never the full validation set — the fix is documented
  inline in `target-tauri.R`.
- **`build_wasm()`**: implementation follows `shinylive::export()`'s
  documented API, but could **not** be exercised — `cloud.r-project.org`,
  `*.r-universe.dev`, `cdn.jsdelivr.net`, and `shinylive.io` were all
  network-policy-blocked (403) in that sandbox, which blocks both
  installing the `shinylive` R package and downloading the webR/package
  assets it needs at export time. (For contrast: sourceforge, crates.io,
  and the npm registry were all reachable, which is what let
  `build_portable()`/`build_tauri()` get verified for real.) Don't
  assume this reflects a real user's dev machine — it's very likely a
  sandbox-specific policy, not a real-world constraint — but do treat
  `build_wasm()`'s code as reviewed-not-run until someone runs it
  somewhere `shinylive` is actually installable.
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
