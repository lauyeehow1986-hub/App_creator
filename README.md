# shinyalcatraz

Turn a Shiny app into a **portable, zero-admin-install bundle** that runs
on a locked-down machine: copy the folder over, double-click (or open in a
browser), no R install, no internet, no administrator rights required on
the target.

> Status: early scaffold. `build_wasm()` is implemented; `build_portable()`
> and `build_tauri()` are designed but not yet implemented — see
> [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Install

```r
# install.packages("pak")
pak::pkg_install("lauyeehow1986-hub/app_creator")
```

## Quick start

```r
library(shinyalcatraz)

demo_app <- system.file("examples", "demo-app", package = "shinyalcatraz")

# Pure-browser WebAssembly build: no R install needed on the target at all.
build_wasm(demo_app, out_dir = "dist/wasm")
```

This produces `dist/wasm/`, a self-contained static bundle. Copy that
folder anywhere — a USB drive, a network share — and on the target
machine either open `index.html` directly, or run the generated
`run.bat` / `run.sh` to serve it over `http://localhost` (works around
`file://` CORS/service-worker restrictions some browsers apply to WASM).

## Build targets

| Target | Function | What it needs on the target machine |
|---|---|---|
| WebAssembly (browser-only) | `build_wasm()` | A modern browser. Nothing else. |
| Portable R backend *(planned)* | `build_portable()` | Nothing — bundles a real portable R runtime. |
| Native shell *(planned)* | `build_tauri()` | Nothing — wraps either target above in a native double-click app. |

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full tradeoff
matrix (size, package compatibility, filesystem/DB access, platform
reach) and the reasoning behind what's implemented first.

## Development

This package targets standard R package tooling:

```r
devtools::load_all()
devtools::document()
devtools::test()
```

See [`CLAUDE.md`](CLAUDE.md) for codebase structure, conventions, and
the full architecture/decision history for AI assistants (and humans)
working on this repo.

## License

MIT — see [`LICENSE.md`](LICENSE.md).
