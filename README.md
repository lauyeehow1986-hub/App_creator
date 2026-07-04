# shinyalcatraz

Turn a Shiny app into a **portable, zero-admin-install bundle** that runs
on a locked-down machine: copy the folder over, double-click (or open in a
browser), no R install, no internet, no administrator rights required on
the target.

> **Status:** `build_wasm()`, `build_portable()` (Windows), and
> `build_tauri()` (desktop, wasm backend) are all implemented and
> **verified end-to-end on a real Windows machine** (real download, real
> compile, and the output actually launched and rendered). See
> [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for exactly what's
> verified vs. still planned (macOS/Linux portable, Tauri + portable-R
> sidecar, mobile).

---

## The two machines

Keep these straight — almost every setup question comes down to which one
you mean:

| | **Build machine** | **Target machine** |
|---|---|---|
| What it is | A normal, internet-connected dev box where you *run* `shinyalcatraz` to produce a bundle. | The locked-down box where the app *runs*. |
| Needs internet | **Yes** (to fetch webR / R-Portable / Rust toolchains once). | **No.** |
| Needs admin rights | No. | **No.** |
| Needs R installed | Yes (to run this package). | **No** — the runtime is bundled (or is the browser). |

You do all the setup below on the **build machine**. The **target** gets a
copy-and-run folder and nothing else.

---

## Install the package (build machine)

```r
# install.packages("pak")
pak::pkg_install("lauyeehow1986-hub/App_creator")
```

This pulls the package and its hard dependencies (`cli`, `fs`, `jsonlite`,
`rlang`). It needs **R ≥ 4.1.0**. Each build target then has a few extra
build-machine prerequisites — set up only the target(s) you actually use.

---

## Setup, step by step, per target

### A. `build_wasm()` — pure browser (WebAssembly)

Smallest, most portable output; the target needs only a browser. Runs your
app as WebAssembly via [`shinylive`](https://posit-dev.github.io/r-shinylive/)/webR.

**Build-machine prerequisites**

1. The `shinylive` R package:
   ```r
   install.packages("shinylive")
   ```
2. Internet at build time. `shinylive` downloads the webR runtime + package
   wasm binaries, and `pkgcache` does a Bioconductor version check
   (`bioconductor.org`) during export. *(The **output** bundle is fully
   offline; only the build step needs the network.)*

**Build**

```r
library(shinyalcatraz)
demo_app <- system.file("examples", "demo-app", package = "shinyalcatraz")

build_wasm(demo_app, out_dir = "dist/wasm")
```

By default `build_wasm()` runs a **pre-flight compatibility check** first
and aborts with a clear list if your app depends on packages that can't
run in a browser bundle — either because they have no WebAssembly build
(e.g. `ggradar`, or `webshot2`, which needs headless Chrome) or because
they were installed from GitHub (which trips a confusing
`get_github_wasm_assets()` 404). Run it standalone to see the report
without building, or pass `check_deps = FALSE` to skip:

```r
check_wasm_packages("path/to/app")            # what won't work, and why
build_wasm("path/to/app", check_deps = FALSE) # skip the pre-flight
```

If a flagged package is only *installed from GitHub* but does have a webR
binary (common for CRAN-archived packages), reinstall it from CRAN — or
clear its `Remote*`/`Github*` `DESCRIPTION` fields — and it'll work.

**Run on the target**

Copy `dist/wasm/` over, then either:

- run the generated **`run.bat`** (Windows) / **`run.sh`** (macOS/Linux) —
  it serves the folder over `http://localhost` using whatever's present
  (`python3`, or on Windows a bundled `serve.ps1` using PowerShell's
  `HttpListener` — no admin, no `netsh`); **or**
- host `dist/wasm/` on any internal web/file server.

> Do **not** just double-click `index.html` off `file://` — browsers block
> shinylive's service worker under `file://` (CORS), leaving a blank page.
> `run.bat`/`run.sh`/`serve.ps1` exist precisely to avoid that.

---

### B. `build_portable()` — bundled portable R (Windows)

Full R compatibility (any package that installs on normal Windows R),
launched from a bundled [R-Portable](https://sourceforge.net/projects/rportable/)
runtime. Larger output (~150–300 MB, scales with dependencies).

**Build-machine prerequisites (Windows)**

1. **7-Zip** (unpacks the R-Portable installer). A standard Windows
   install (`C:\Program Files\7-Zip`) is found automatically — the
   installer doesn't add itself to `PATH`, so `build_portable()` looks in
   the usual locations for you. Only a *non-standard* install needs `7z`
   on `PATH`:
   ```powershell
   $env:PATH = "C:\path\to\7-Zip;" + $env:PATH
   ```
   On Linux build machines, `p7zip-full` provides `7z`.
2. Internet at build time (downloads R-Portable from SourceForge, cached
   after the first run, and the app's package **binaries** from CRAN).

**Build**

```r
build_portable(
  demo_app,
  out_dir = "dist/portable",
  platform = "windows",
  r_portable_version = "4.2.0"   # optional; see "R versions" below
)
```

**Run on the target**

Copy `dist/portable/` over and double-click **`run.bat`**. It launches the
app from the bundled `R-Portable\` against the private `library\` — no R
install, no admin.

---

### C. `build_tauri()` — native double-click desktop app

Wraps a `build_wasm()` bundle in a native [Tauri](https://tauri.app/) shell
so the target gets a real `.exe` (uses the OS's built-in WebView2 on
Windows — no bundled browser engine). Output is a single **self-contained
`.exe`** (~59 MB for the demo: the whole wasm frontend is embedded).

**Build-machine prerequisites**

1. Everything from **A** (`build_tauri` builds a wasm frontend first, or
   reuses one via `frontend_dist =`).
2. A **Rust toolchain** (`rustc` + `cargo`) via [rustup](https://rustup.rs/):
   ```powershell
   # Windows: download & run rustup-init from https://rustup.rs, then:
   rustc --version
   cargo --version
   ```
3. A **C/C++ linker** for Rust's MSVC target:
   - **Windows:** Visual Studio **Build Tools** with the "Desktop
     development with C++" workload (provides `link.exe` + the Windows
     SDK). `rustc` finds it automatically.
   - **Linux:** `libwebkit2gtk-4.1-dev`, `libgtk-3-dev`, `build-essential`
     (WebKitGTK instead of WebView2).
4. A **Tauri CLI**. Either:
   ```powershell
   cargo install tauri-cli      # provides `cargo-tauri`  (preferred)
   ```
   …or have `npx` available (the code falls back to
   `npx @tauri-apps/cli`).
5. **WebView2 runtime** on the *target* (not the build machine): present by
   default on Windows 10 21H2+ and Windows 11. For older/locked-down
   images, xcopy the "Fixed Version" WebView2 distributable alongside the
   app (no install/admin needed, adds ~150 MB).

**Build**

```r
# Full build (builds the wasm frontend, then compiles the native shell):
build_tauri(demo_app, out_dir = "dist/tauri")

# Or wrap a frontend you already built (faster iteration):
build_wasm(demo_app, out_dir = "dist/wasm")
build_tauri(demo_app, out_dir = "dist/tauri", frontend_dist = "dist/wasm")
```

The built binary lands at
`dist/tauri/src-tauri-project/src-tauri/target/release/<app>.exe`.

**Run on the target**

Copy that `.exe` over and double-click it. It serves its embedded frontend
over a loopback-only `http://127.0.0.1:<port>` (so shinylive's service
worker + webR start) — **no admin, and no Windows Firewall prompt**.

---

## R versions and package dependencies

This is where "it worked on my machine" bites, so read this before shipping.

### The build machine's R version is (mostly) independent of the bundled one

- **`build_wasm()` / `build_tauri()`** run your app in **webR's** R (the
  version `shinylive` ships as WebAssembly — an R 4.x line), *not* your
  build machine's R. Your build machine's R only orchestrates the export.
- **`build_portable()`** installs your app's packages **for the bundled
  R-Portable's version and ABI**, using the *bundled* `Rscript.exe` (not
  your build machine's R). So your build machine can be any R ≥ 4.1 and the
  bundle stays consistent.

Practical rule: **pick the runtime version at build time**, don't assume it
matches your dev R.

### Pinning / choosing the runtime R version

- `build_portable(..., r_portable_version = "4.2.0")` pins the bundled R.
  If you omit it, it takes SourceForge's "latest" R-Portable.
- **Why the pin matters:** R-Portable trails current R, and CRAN stops
  refreshing a given R-series' *Windows binary* repo before it stops
  publishing *source* releases. `build_portable()` forces
  `type = "win.binary"` on purpose — so a package with **no binary for
  your pinned R** fails **loudly** instead of silently trying a source
  build (which would need Rtools you may not have). If an install fails
  for a package that clearly exists, try a newer `r_portable_version` so a
  matching binary exists.

### How dependencies are detected and installed

- **`build_portable()`** statically scans your app's `.R`/`.r` files for
  `library()`, `require()`, and `pkg::fn` calls, resolves the full
  transitive tree, and installs it (as Windows binaries) into a private
  `library\` inside the bundle. It deliberately does **not** use `renv`.
  - Consequence: dependencies loaded *dynamically* (e.g.
    `library(pkg, character.only = TRUE)` with a computed name, or
    `requireNamespace()` behind a variable) won't be detected — name such
    packages explicitly with a plain `library(pkg)` somewhere so the
    scanner sees them.
- **`build_wasm()` / `build_tauri()`** rely on `shinylive`/webR to resolve
  the app's packages from webR's package repositories.
  - Consequence: **only packages that have a precompiled WebAssembly
    build** work (webR's repo + r-universe wasm builds). Pure-R packages
    and popular CRAN packages generally do; anything requiring arbitrary
    C/C++/Fortran **source** compilation does **not**. If your app needs
    such a package, use `build_portable()` instead.

### Quick "which target for my dependencies?"

| Your app's packages | Use |
|---|---|
| Pure R, or CRAN packages with wasm builds | `build_wasm()` (or `build_tauri()` for a desktop icon) |
| Anything installable as a Windows binary on normal R (incl. compiled packages) | `build_portable()` |
| Needs native DB drivers / real disk I/O / a source-only package | `build_portable()` |

---

## Troubleshooting

- **Downloads fail with `SEC_E_UNTRUSTED_ROOT` / `UnknownIssuer` /
  `NET::ERR_CERT_AUTHORITY_INVALID` (cargo, `install.packages`, rustup, or
  the browser).** Antivirus **HTTPS/TLS scanning** (AVG, Avast, Kaspersky,
  ESET, BitDefender, …) is man-in-the-middling TLS with a root the tools
  don't trust. Turn off the AV's "HTTPS scanning / Web Shield" (or use a
  network without it), then retry. This bit us hard during verification —
  it is the first thing to check when *every* HTTPS client suddenly fails.
- **`build_portable()` errors that 7-Zip isn't found.** A standard
  `C:\Program Files\7-Zip` install is auto-detected; if yours is
  elsewhere, put `7z` on `PATH` (see B‑1).
- **A portable bundle opens nothing / the console flashes and closes.**
  The app is crashing on startup - almost always `there is no package
  called '<name>'` for a **GitHub-only or CRAN-archived** package (e.g.
  `ggradar`) that has no Windows binary, so `build_portable()` couldn't
  install it. The build now **warns at build time** listing any package
  that didn't land. To fix: copy a pure-R package's folder into the
  bundle's `library/`, or `remotes::install_github()` it using the
  bundle's own `R-Portable\bin\x64\Rscript.exe`, or drop it from the app.
  To *see* the error yourself, run the bundle from a terminal
  (`R-Portable\bin\x64\Rscript.exe --vanilla run_app.R`) so the window
  stays open.
- **`build_wasm()` fails on a package (GitHub 404, or "not wasm
  compatible").** Run `check_wasm_packages("your/app")` to list every
  incompatible dependency up front and why (no wasm build vs.
  GitHub-installed), then remove/replace or reinstall-from-CRAN as
  advised.
- **`build_portable()` package install fails for a package that exists.**
  No Windows binary for the pinned R series — bump `r_portable_version`
  (see "Pinning" above).
- **`build_tauri()` says no Tauri CLI found.** `cargo install tauri-cli`,
  or ensure `npx` is on `PATH`.
- **`build_tauri()` link errors on Windows.** Install VS Build Tools with
  the C++ workload (see C‑3).
- **The wasm bundle shows a blank page.** You opened `index.html` off
  `file://`. Use `run.bat`/`run.sh` or serve it over `http://localhost`.
- **The Tauri window shows "…requires a connection to localhost, or …
  https".** You're on an old build; current `build_tauri()` serves over
  `http://127.0.0.1` via `tauri-plugin-localhost` to satisfy shinylive.

---

## Development

Standard R package tooling:

```r
devtools::load_all()
devtools::document()
devtools::test()
devtools::check()
```

Slow tests that do real downloads/compiles are gated behind
`Sys.setenv(SHINYALCATRAZ_RUN_NETWORK_TESTS = "1")`.

See [`CLAUDE.md`](CLAUDE.md) for codebase structure, conventions, and the
full architecture/decision history for AI assistants (and humans) working
on this repo, and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the
tradeoff matrix and what's verified vs. planned.

## License

MIT — see [`LICENSE.md`](LICENSE.md).
