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
pak::pkg_install("lauyeehow1986-hub/shiny_alcatraz")
```

This pulls the package and its hard dependencies (`cli`, `fs`, `jsonlite`,
`rlang`). It needs **R ≥ 4.1.0**. Each build target then has a few extra
build-machine prerequisites — set up only the target(s) you actually use.

---

## Dependencies at a glance

Everything here is on the **build machine only** — the target never needs
any of it. **Do you need Rust, Docker, etc.?** Only for the specific target:

| Build target | Extra build-machine dependencies | Rust? | Docker? | Target needs |
|---|---|---|---|---|
| `build_wasm()` | `shinylive` R package + internet | **No** | **No** | a modern browser |
| `build_portable()` (Windows) | 7-Zip + internet | **No** | **No** | nothing (R is bundled) |
| `build_tauri()` (desktop) | wasm prereqs **+** Rust (`rustup`) + a C++ linker (MSVC Build Tools on Windows / WebKitGTK on Linux) + a Tauri CLI + internet | **Yes** | **No** | WebView2 (preinstalled on Win 10 21H2+ / Win 11) |

- **Rust is only for `build_tauri()`.** `build_wasm()` and `build_portable()`
  never touch it.
- **Docker is never required.** Even for a GitHub-only package with no
  WebAssembly binary, you use **r-universe** (which builds the wasm binary in
  the cloud) rather than a local wasm toolchain — see
  [Including a package with no wasm binary](#including-a-package-with-no-wasm-binary-eg-a-github-only-package).
- These are one-time installs; the per-target sections below have the details.

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

#### Including a package with no wasm binary (e.g. a GitHub-only package)

webR runs pre-compiled WebAssembly, not R source, so a package's **wasm
binary has to exist somewhere shinylive can fetch it** — `repo.r-wasm.org`, a
GitHub *release*, Bioconductor, or an **r-universe**. For a GitHub-only
package like `ggradar` that has none, the robust, offline-preserving fix is
to put it on your own **r-universe**: it builds the wasm binary in the cloud
(no local Docker or Rust), and `build_wasm()` bundles it at build time so the
target still needs no internet. **Verified end-to-end** (the exported offline
app renders the `ggradar` chart).

> **This only works for packages that *can* compile to wasm** but just aren't
> on `repo.r-wasm.org` — typically **GitHub-only** packages. It does **not**
> rescue a **CRAN** package that's missing a wasm binary: `repo.r-wasm.org`
> already builds ~all of CRAN to wasm (22k+ packages, including `sf`, `terra`,
> `V8`, `magick`), so a CRAN package that's *still* missing genuinely can't
> cross-compile (needs a JVM, a live DB/socket, threads, …). r-universe uses
> the same toolchain and would fail identically — for those, use
> [`build_portable()`](#b-build_portable--bundled-portable-r-windows) (real R,
> no wasm) or replace the package.

Everything is R/CLI except one browser click:

1. **Generate the registry** from your app (finds every GitHub/GitLab/
   Bitbucket-installed dependency):
   ```r
   write_runiverse_registry("path/to/app", "packages.json")
   ```
2. **Create a public GitHub repo named `<your-username>.r-universe.dev`** and
   commit that `packages.json`. Scriptable with `gh`:
   ```sh
   gh repo create <you>.r-universe.dev --public --source=. --push
   ```
3. **Install the r-universe app** — the *one* manual step (an OAuth consent you
   do yourself): [github.com/apps/r-universe](https://github.com/apps/r-universe)
   → Install → select that repo. r-universe then builds every target, including
   **WebAssembly**, automatically.
4. **Wait for the build**, then check it's live (a first build can queue on
   r-universe's shared runners — minutes to ~an hour):
   ```r
   runiverse_status("path/to/app", universe = "https://<you>.r-universe.dev")
   ```
5. **Install the package *from* your universe** (this stamps its `Repository`
   field, which is what shinylive keys off):
   ```r
   install.packages("ggradar",
     repos = c("https://<you>.r-universe.dev", "https://cloud.r-project.org"))
   ```
6. **Build** — the pre-flight now recognises r-universe packages, so no
   `check_deps = FALSE` needed:
   ```r
   build_wasm("path/to/app", out_dir = "dist/wasm")
   ```
7. **Verify** the wasm binary landed in the bundle:
   ```r
   runiverse_status("path/to/app", bundle = "dist/wasm")
   ```

Adding another such package later is just `write_runiverse_registry()` → push
to that repo → it rebuilds automatically.

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

1. **7-Zip** — only needed for `r_source = "sourceforge"` (unpacks its
   `.paf.exe`). The default `r_source = "github"` ships plain zips, so 7-Zip
   isn't required for it. A standard Windows install
   (`C:\Program Files\7-Zip`) is found automatically; a non-standard one
   needs `7z` on `PATH` (`$env:PATH = "C:\path\to\7-Zip;" + $env:PATH`). On
   Linux build machines, `p7zip-full` provides `7z`.
2. Internet at build time (downloads a portable R build — by default the
   recent [selkamand/r-portable-windows](https://github.com/selkamand/r-portable-windows)
   release, cached after the first run — and the app's package **binaries**
   from CRAN).

**Build**

```r
build_portable(
  demo_app,
  out_dir = "dist/portable",
  platform = "windows"
  # r_source = "github" (default) fetches a recent portable R (currently 4.5.1);
  # r_portable_version = "4.5.1" to pin it. "sourceforge" is the legacy source.
)
```

**Run on the target**

Copy `dist/portable/` over, then double-click one of:

- **`run.bat`** — launches the app in a console window you can close to stop
  it. Launches from the bundled `R-Portable\` against the private
  `library\` — no R install, no admin.
- **`run.vbs`** — the same launch but **windowless** (no console box behind
  the browser), for a more app-like feel.

Either way, all R output is written to **`log\last-run.txt`**, and if the
app exits with an error that log **opens automatically** — so a crash
leaves a readable diagnosis instead of a console that flashes and vanishes.

#### Reproducible builds (lock the R version *and* package versions)

By default the build floats: it fetches the latest R-Portable and the
latest package versions on CRAN at build time, so two builds weeks apart
can differ. To lock both:

```r
build_portable(
  my_app, platform = "windows",
  r_portable_version = "4.5.1",       # pin R (a version your r_source offers)
  snapshot           = "2026-01-01"   # pin every CRAN package to that day's versions
)
```

`snapshot` installs from that day's
[Posit Public Package Manager](https://packagemanager.posit.co) snapshot
instead of the floating latest, so every rebuild resolves the *same*
versions (no `renv` needed). Each bundle's `manifest.json` also records
`r_version`, `r_source`, `snapshot`, and `package_versions` (the exact
version of every package that landed), so any bundle is auditable and
reproducible without a rebuild.

> **Keep the R version and snapshot date close.** PPM only serves Windows
> *binaries* for R versions it still builds for; pinning a very old R with a
> recent snapshot can leave only source packages (which then need a compiler
> on the build machine). The default `r_source = "github"` gives a recent R
> (currently 4.5.1), so a recent snapshot date pairs cleanly — verified with
> R 4.5.1 + the 2026-01-01 snapshot (installs `shiny 1.12.1`).

#### Packages that need a native runtime (rJava, tesseract, RMariaDB, rstan)

Some packages are only a thin binding to a **native runtime that lives
outside the R package** — the exact packages `build_wasm()` can't handle
(a browser has no JVM, no DB, no compiler). The CRAN Windows binary gives
you the compiled glue, but not that runtime, so `build_portable()` stages
it into the bundle and wires it into `run.bat`. Providers are
auto-selected from your dependency tree; tune them with `native_runtime`:

```r
build_portable(
  my_app, platform = "windows",
  native_runtime = list(
    tesseract = list(langs = c("eng", "fra")),  # extra OCR languages
    mariadb   = list(server = TRUE),            # bundle a portable DB server
    toolchain = list(rtools  = TRUE)            # bundle Rtools (compile at runtime)
  )
)
```

| Package | What gets bundled | Status |
|---|---|---|
| **rJava** | a portable Temurin JRE → `runtime/jre` (`JAVA_HOME` set in `run.bat`) | ✅ verified end-to-end offline |
| **tesseract** | OCR `*.traineddata` → `tessdata` (`TESSDATA_PREFIX` set) | ✅ verified end-to-end offline |
| **RMariaDB** | *nothing* — the client is self-contained; point it at an existing server | ✅ works as-is |
| **RMariaDB** `server = TRUE` | a portable MariaDB server + `db-start/stop.bat` (127.0.0.1 only, graceful shutdown) | ✅ verified end-to-end offline (opt-in) |
| **rstan / brms** | *nothing* — **precompile your models at build time** (recommended) | ✅ recommended |
| **rstan / brms** `rtools = TRUE` | Rtools toolchain → `runtime/rtools` (compile new models on target) | ✅ verified end-to-end offline (opt-in; large — ~500 MB) |

The registry is `native_runtime_providers()` (run it to see the full set).
All of these are verified end-to-end offline; the two opt-in paths
(`server = TRUE`, `rtools = TRUE`) are gated only because they're large,
not because they're unproven. See `docs/ARCHITECTURE.md` → "Native-runtime
provisioning" for the verification detail.

##### Shipping a **lite** and a **full** bundle

For an app that needs one of these runtimes, you often want two downloads:
a small one for machines that already have Java / a database / a compiler,
and a self-contained one for locked-down targets. The `runtimes` argument
switches between them without hand-writing the `native_runtime` options:

```r
# self-contained: bundle every runtime the app needs (largest)
build_portable(my_app, out_dir = "dist/portable-full", runtimes = "all")

# lite: bundle no native runtime (smallest; target must supply the JVM/DB/etc.
# - you get a warning naming what's missing)
build_portable(my_app, out_dir = "dist/portable-lite", runtimes = "none")
```

`runtimes = "auto"` (the default) sits in between: it bundles the
lightweight runtimes automatically and leaves the heavy ones (DB server,
Rtools) opt-in. Each bundle's `manifest.json` records its `runtimes` mode
and exactly which runtimes were bundled, so the two are easy to tell apart.
Explicit `native_runtime` entries still override the preset (e.g.
`runtimes = "all"` plus `native_runtime = list(toolchain = list(enabled = FALSE))`
= everything except Rtools).

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

- `build_portable(..., r_portable_version = "4.5.1")` pins the bundled R.
  Omit it for the latest from the chosen `r_source`.
- **Any version works, including the newest.** The default
  `r_source = "github"` uses pre-built zips
  ([selkamand/r-portable-windows](https://github.com/selkamand/r-portable-windows))
  for the few versions it curates; for anything it lacks it **automatically
  falls back** to `r_source = "cran"`, which builds a portable R by silently
  extracting the **official** `R-<ver>-win.exe` installer (per-user, no
  admin). So `r_portable_version = "4.6.1"` just works — **verified
  end-to-end**: it fetched R 4.6.1, installed shiny's full tree, and the
  bundle served (HTTP 200). The manifest records the *effective* source.
- **Why the version matters:** `build_portable()` forces
  `type = "win.binary"` on purpose — so a package with **no binary for
  your pinned R** fails **loudly** instead of silently trying a source
  build (which would need Rtools you may not have). A *current* R (the
  default) has the widest binary coverage on CRAN/PPM; if an install fails
  for a package that clearly exists, a newer `r_portable_version` usually
  fixes it.

### How dependencies are detected and installed

- **`build_portable()`** statically scans your app's `.R`/`.r` files for
  `library()`, `require()`, and `pkg::fn` calls, resolves the full
  transitive tree, and installs it (as Windows binaries) into a private
  `library\` inside the bundle. It deliberately does **not** use `renv`.
  - **Remote-installed packages are handled too:** any dependency you
    installed from a git forge or URL — **GitHub, GitLab, Bitbucket, a
    generic git URL, or a source-tarball URL** (whatever `remotes`/`pak`
    recorded as its `RemoteType`) — is reinstalled into the bundle via
    the matching `remotes::install_*()`, run by the bundle's *own* R so
    the ABI matches. Pure-R ones just work; a *compiled* remote package
    still needs Rtools in the bundled R. (`remotes` is bootstrapped into
    the bundle automatically.) *Verified end-to-end for GitHub; the other
    forges go through the same `remotes` machinery.*
  - **r-universe / Posit Package Manager:** packages from a custom
    CRAN-like repo carry that repo's URL in their `Repository` field;
    it's added to the install `repos` so they resolve.
  - **Bioconductor packages are handled too:** dependencies with a
    `biocViews` field are installed from the Bioconductor repos
    (`BiocManager::repositories()`, pinned to the bundled R's Bioc
    release) as Windows binaries — no Rtools needed, since Bioconductor
    ships binaries per release. (`BiocManager` is bootstrapped
    automatically.)
  - **Local / source-tarball packages are handled too:** anything no
    repo can provide (installed from a local `.tar.gz`, CRAN-archived, or
    source-only) is copied into the bundle from the build machine *if
    it's pure R* — pure-R code is R-version-independent, so it loads in
    the bundled R. A *compiled* such package can't be copied safely
    (ABI) and is reported by the missing-package check instead.
  - If a required package can't be installed, the build **warns and
    lists it** rather than shipping a bundle that crashes on the target.
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
