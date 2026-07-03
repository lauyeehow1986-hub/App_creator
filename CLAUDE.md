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
| `build_wasm()` | Implemented (shinylive/webR bundle) |
| `build_portable()` | Scaffolded, `cli_abort()`s with "not yet implemented" |
| `build_tauri()` | Scaffolded, `cli_abort()`s with "not yet implemented" |
| `build()` dispatcher | Implemented, routes to the above |
| Tests | Skeleton exists (`tests/testthat/test-build.R`), covers validation logic only |
| CI | `.github/workflows/R-CMD-check.yaml` present, unverified (no R in the sandbox this was authored in — see below) |
| Demo app | `inst/examples/demo-app/` — plain `shiny`-only app, no extra deps, used to exercise the pipeline |

## Codebase structure

```
DESCRIPTION, NAMESPACE, LICENSE, LICENSE.md   Standard R package metadata (MIT license)
R/
  build.R                  build() dispatcher + target validation
  target-wasm.R            build_wasm() - implemented
  target-portable.R        build_portable() - planned, not implemented
  target-tauri.R           build_tauri() - planned, not implemented
  utils.R                  check_app_dir(), write_build_manifest(), git_sha(), dir_size()
  shinyalcatraz-package.R  package-level roxygen doc (_PACKAGE)
inst/examples/demo-app/    Minimal demo Shiny app (shiny only, no extra deps)
tests/testthat/            Test skeleton
docs/ARCHITECTURE.md       Design decisions and tradeoff matrix - READ THIS FIRST
.github/workflows/         R-CMD-check CI
```

There is no `man/` content yet (no roxygen2 available in the sandbox that
authored this scaffold — see below); `NAMESPACE` was hand-written to
match the current `@export` tags in `R/`. Regenerate both properly with
`devtools::document()` once you have a working R install.

## Development workflow

**This repo's own build/test loop needs R, which is not guaranteed to be
present in every environment an AI assistant runs in** (it was not
present in the sandbox this scaffold was authored in — everything below
was hand-written and has not been executed against a real R
interpreter). If R is available:

```r
devtools::load_all()   # iterate
devtools::document()   # regenerate NAMESPACE/man/ after changing roxygen comments or exports
devtools::test()       # run tests/testthat
devtools::check()      # full R CMD check before anything you'd call "done"
```

If R is *not* available in your environment, say so explicitly rather
than claiming a change works — this mirrors the project's own top-level
instruction to never claim success on unverified code. Read the code
carefully for syntax correctness instead, and flag anything that would
need a real R session to confirm (in particular: `shinylive::export()`
argument names/behavior, and anything touching `httpuv`/portable-R/Tauri
once those targets are implemented).

### Testing a build end-to-end (when R is available)

```r
library(shinyalcatraz)
demo_app <- system.file("examples", "demo-app", package = "shinyalcatraz")
build_wasm(demo_app, out_dir = "dist/wasm")
# then open dist/wasm/index.html or run dist/wasm/run.sh / run.bat
```

`build_wasm()` requires the `shinylive` R package and internet access on
*first* run (to download/cache the webR runtime + package binaries).
Later runs reuse that cache — this matches the project's core assumption
that the *build* machine has internet even though the *deployment*
target never does.

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
- Don't implement `build_portable()` or `build_tauri()` speculatively
  without re-reading `docs/ARCHITECTURE.md`'s "Native shell notes" and
  "Explicitly deferred" sections first — there are real platform caveats
  (WebView2 bundling, R-Portable library isolation) that are easy to get
  wrong silently.
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
