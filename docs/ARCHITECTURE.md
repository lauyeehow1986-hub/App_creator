# Architecture & decisions

`shinyalcatraz` turns a normal Shiny app into one or more **copy-and-run
bundles** that need no administrator rights and no internet access on the
machine they run on. This doc records why it's built the way it is, so
future changes don't quietly re-litigate settled tradeoffs.

## The three build targets

| | `build_wasm()` | `build_portable()` | `build_tauri()` |
|---|---|---|---|
| **Status** | Implemented, verified end-to-end on Windows (renders in a real browser via `serve.ps1`) | Implemented for Windows, verified end-to-end; macOS/Linux not implemented | Implemented for `backend = "wasm"` desktop, verified end-to-end on Linux *and* Windows (real `.exe`, WebView2 renders the app); `backend = "portable"` and mobile not implemented |
| **What runs on target** | Browser only (WASM) | Real portable R, launched via `shiny::runApp()` | Native shell (Tauri) wrapping either of the other two |
| **R install needed on target** | None | None (bundled) | None (bundled) |
| **Admin rights needed** | None | None | None (portable exe; WebView2 caveat below) |
| **CRAN package compatibility** | Only packages with precompiled WASM binaries (no arbitrary C/C++/Fortran source packages) | Full — anything installable on a normal R | Same as whichever backend it wraps |
| **Real filesystem / DB access** | No (browser sandbox only; virtual FS) | Yes | Yes, if backend is `"portable"` |
| **Typical size** | Tens of MB (webR runtime + package wasm binaries) | ~225MB verified for the demo app (R-Portable 4.2.0 + shiny + its 28 transitive deps, all as Windows binaries); scales with dependencies | The whole frontend is *embedded* in the `.exe`, so size ≈ frontend + a few-MB shell: the demo's 65MB wasm bundle → a **59MB self-contained Windows `.exe`** (verified; brotli-compressed embed). The bare shell alone is ~9MB (Linux, no frontend embedded) |
| **Cross-platform reach** | Anywhere with a modern browser: Windows/macOS/Linux/Android/iOS | Windows only so far (R-Portable); macOS/Linux need a statically-built R | Windows/macOS/Linux desktop implemented; Android/iOS via Tauri 2 mobile not implemented |
| **Cold start** | Slower (WASM interpreter warmup) | Fast (native R) | Fast |

**Why WASM/shinylive is the default target:** given the "maximum
capability, minimum size" framing, minimum size is the one that's
non-negotiable across every target platform (including Android/iOS,
where you *can't* bundle a portable R runtime at all) — so it has to
work everywhere. `build_portable()` (Windows) and `build_tauri()`
(`backend = "wasm"`, desktop) are now also implemented and verified;
`build_portable()` for macOS/Linux, `build_tauri(backend = "portable")`,
and mobile platforms remain deliberately unimplemented until there's a
concrete app that needs what WASM can't do (native DB drivers,
compiled-only packages, real disk I/O) to design the harder cases
against.

## Key constraints this design is built around

1. **Build machine has internet; deployment target does not.** All asset
   fetching (webR runtime, R-Portable, Tauri/Rust toolchains) happens at
   build time on a normal connected dev machine. The *output* of a build
   is what gets air-gapped-copied to the locked-down target — never the
   package's own dependency-fetching step.
2. **Deployment target platforms, in priority order:** Windows first,
   then Android, then iOS/macOS/Linux. This is why WASM (which is the
   only target that reaches Android/iOS at all without an app-store
   install) is the flagship path, and why the portable-R target's first
   planned `platform` is Windows (R-Portable is the mature, well-trodden
   option there).
3. **Delivery/launch mechanism is not assumed.** Some target environments
   allow double-clicking an unsigned `.exe`; some only allow opening a
   file in an already-whitelisted browser; some only offer a mapped
   network drive. `build_wasm()` handles all three today: open
   `index.html` directly, run the generated `run.bat`/`run.sh` launcher
   (uses whatever local `python3` is already present — see note below),
   or host `out_dir` on an internal file/web server. `build_tauri()` is
   the planned answer for "give me a real double-click desktop icon."
4. **Versioning on offline machines is manual re-copy, but auditable.**
   Every target writes a `manifest.json` (via `write_build_manifest()`)
   into its bundle root with the package version, git SHA of the app
   source, and build timestamp, so two copies on two machines can be
   told apart without diffing files. `enable_update_check()` adds an
   opt-in, fail-silent "phone home if reachable" banner on top of a
   `build_wasm()` bundle for teams that do have some intranet endpoint
   to check against — see its roxygen docs in `R/update-check.R`.

## Why no bundled static-server binary

`build_wasm()`'s launcher scripts (`write_serve_launchers()`) shell out to
`python3 -m http.server` if it's present, and on Windows fall back to a
small inline `serve.ps1` (plain `System.Net.HttpListener` on
`http://localhost:<port>/`) if PowerShell is present, rather than shipping
a bundled static-file-server executable (e.g. a Go single-binary server).
Locked-down corporate images very often already have *some* Python or
PowerShell, and shipping zero extra bytes beats shipping a few hundred KB
"just in case" — consistent with the project's lazy/minimal coding
convention (see `CLAUDE.md`).

**Verified on a real Windows machine with no Python installed**: opening
`index.html` straight off `file://` is *not* a working fallback — Edge
and Chrome both block the shinylive service worker under `file://` with
`Access to script ... has been blocked by CORS policy: Cross origin
requests are only supported for protocol schemes: ... http, https, ...`,
leaving a permanently blank page with no error visible to the user unless
they open devtools. This is exactly the failure mode this section
originally flagged as a reason to revisit the no-bundled-binary decision.
Rather than bundling a binary, the fix was a second real fallback tier:
`serve.ps1`, since PowerShell ships with every supported Windows version
and `HttpListener` on `localhost` needs no admin rights or `netsh` URL-ACL
reservation (confirmed empirically, not just from docs — non-elevated
`New-Item -TypeName System.Net.HttpListener` bound to
`http://localhost:<port>/` starts cleanly). The final fallback (opening
`index.html` directly) is now only reached if *neither* Python nor
PowerShell is found, and its message says explicitly that this will
likely produce a blank page, rather than implying it's a working option.

## `build_portable()` Windows notes (verified on a real Windows machine)

The original sandbox verification downloaded and assembled a bundle but
never actually launched the resulting `.exe`/`run.bat`, and never
installed a package with real transitive dependencies (the demo app's
only dependency is `shiny` itself). Doing both on a real Windows machine
surfaced three real, silent-corruption bugs, none visible from a
code-only review:

1. **`curl`'s schannel SSL backend hangs on cert-revocation-check
   failures.** `fetch_r_portable()`'s `curl` calls (downloading
   R-Portable itself) failed outright with `CRYPT_E_NO_REVOCATION_CHECK`
   when the OCSP/CRL endpoint wasn't reachable - very plausible on the
   locked-down corporate networks this package targets. Fixed by adding
   `--ssl-no-revoke` (Windows/schannel-only; gated by
   `curl_windows_ssl_args()`).
2. **The build machine's own R environment leaks into the bundled R.**
   `install_packages_portable()` runs the *bundled* Rscript.exe via
   `system2()` specifically so installed binaries match R-Portable's
   ABI (see that function's roxygen docs) - but `system2()` passes the
   parent process's full environment to the child by default, including
   `R_LIBS_USER` that the *build machine's own R* sets for itself at
   startup (even with nothing persisted in the registry/profile). The
   bundled R then resolved `.libPaths()` to include the build machine's
   per-user library and loaded an incompatible compiled dependency from
   there instead of its own - observed as `shiny`'s install crashing
   with `LoadLibrary failure: The specified procedure could not be
   found` while loading a `digest.dll` built for the wrong R ABI. Fixed
   by temporarily clearing `R_LIBS_USER`/`R_LIBS_SITE`/`R_LIBS` via
   `Sys.setenv()` before the `system2()` call (not via `system2()`'s own
   `env` argument - verified separately that `env` is unreliable on this
   R/Windows combination, failing even a trivial `system2("cmd", ...,
   env = "FOO=bar")` with status 5).
3. **`install.packages()` prefers a newer source release over an older
   binary.** R-Portable is pinned to a fixed, aging R version (currently
   4.2.0); CRAN stops refreshing that R-series' Windows *binary* repo
   well before it stops publishing new *source* releases, so for any
   actively-maintained package `install.packages()`'s default
   binary-vs-source preference eventually flips to source - on a machine
   with no guaranteed Rtools. Fixed by forcing `type = "win.binary"`, so
   a missing binary now fails loudly and immediately instead of
   silently attempting (and, per bug 2 above, sometimes half-succeeding
   into) a source build.

All three are fixed in `R/target-portable.R`; a from-scratch
`build_portable()` → `run.bat` → real Shiny app in a real browser run
was re-verified after each fix.

## Native-runtime provisioning (portable-only, `R/target-portable.R`)

Some packages are only a thin R binding to a **native runtime that lives
outside the R package**. Those are exactly the packages `build_wasm()`
*can't* handle (a browser sandbox has no JVM, no DB socket, no local
compiler) — which makes them a `build_portable()`-only problem, and one
the CRAN Windows binary alone doesn't solve: the binary carries the
compiled glue + any bundled DLLs, but not the external runtime. So the
bundle has to **stage the runtime in at build time** (the build machine
has internet; the target doesn't) and **wire it up in `run.bat`** before
R starts. Four classes, one mechanism:

| Class | Trigger pkg | Runtime staged into bundle | Wired via | Status |
|---|---|---|---|---|
| JVM | `rJava` | portable Temurin JRE → `runtime/jre` | `JAVA_HOME` + `jvm.dll` on `PATH` | **verified end-to-end** (offline `.jinit()`, JVM `java.home` == bundled path) |
| Data files | `tesseract` | OCR `*.traineddata` → `tessdata` | `TESSDATA_PREFIX` | **verified end-to-end** (offline OCR through the staged data) |
| Server process | `RMariaDB` | *(client only)* nothing — the win.binary bundles Connector/C, so the client already works offline against an existing server | — | verified: no staging needed |
| Server process | `RMariaDB` (`server = TRUE`) | portable MariaDB server → `runtime/mariadb` + `db-start/stop.bat` | started/stopped by `run.bat` (127.0.0.1 only) | **scaffolded, NOT yet run** — opt-in, emits a build-time warning |
| Compiler | `rstan`/`brms` | *(preferred)* nothing — precompile models at build time | — | documented recommendation |
| Compiler | `rstan`/`brms` (`rtools = TRUE`) | Rtools toolchain → `runtime/rtools` | `PATH` + `BINPREF` | **scaffolded, NOT yet run** — opt-in, emits a build-time warning |

The registry is `native_runtime_providers()` (exported for
auditability); each provider is `function(out_dir, cache_dir, opts)` that
stages its runtime and returns the `run.bat` lines that point the app at
it. `build_portable()` auto-selects providers from the dependency tree
and threads per-provider options through its `native_runtime` argument.

**Why the split verification status is deliberate, not laziness.** The
JRE and tessdata providers were run end-to-end (real download → stage →
apply the exact env vars `run.bat` injects → exercise the package
offline: an actual `.jinit()` on the bundled JVM, an actual OCR through
`TESSDATA_PREFIX`). The MariaDB-server and Rtools providers are a
genuinely bigger, heavier lift (a stateful `mysqld` datadir bootstrap; a
~500 MB toolchain that must match R-Portable's ABI) that this build
couldn't exercise honestly, so — per the project's "never claim
unverified success" rule and convention #6 (name the corner) — they're
kept **behind an explicit opt-in** (`server = TRUE` / `rtools = TRUE`),
each emits a `cli::cli_warn()` at build time saying it hasn't been run,
and the code comments name the exact verification step that would let the
warning be dropped. The default `RMariaDB` path (client-only) and the
default `rstan` path (precompile) are the *correct* answers for most
apps anyway, so nobody hits the unverified paths without asking for them.

## Native shell notes (verified end-to-end for `backend = "wasm"` desktop on Linux *and* Windows; the rest is still planned)

- Tauri uses the OS's built-in webview (WebView2 on Windows, WKWebView on
  macOS/iOS, WebKitGTK on Linux, system webview on Android) instead of
  bundling a browser engine — this is what keeps the shell itself small.
  **Verified**: a project generated by `write_tauri_project()` and built
  with `cargo tauri build --no-bundle` produced a 9.1MB dynamically-linked
  Linux binary (confirmed via `ldd` that it links the system
  `libwebkit2gtk-4.1.so`, not a bundled copy).
- `write_tauri_project()` currently generates `bundle.active = false`
  (`--no-bundle` output: a bare native executable, no `.deb`/`.msi`/`.dmg`
  installer). This is deliberate, not a shortcut taken under time
  pressure: an installer is the opposite of "just copy the folder and
  run it." Full per-OS installer packaging remains a possible future
  addition if a real use case wants it.
- **WebView2 (Windows): verified present and rendering.** On a real
  Windows 11 machine the built `.exe` launched and its WebView2 window
  (runtime 150.x, the evergreen runtime shipped with Win11) rendered the
  shinylive app. Present by default on Windows 10 21H2+ and Windows 11.
  Older/locked-down images may lack it; the "Fixed Version" WebView2
  distributable can be xcopied alongside the app without an install step
  (no admin rights needed), but adds ~150MB. The evergreen bootstrapper
  is *not* an option here since it typically needs admin rights.
- **Three Windows-only bugs, found only by launching the built `.exe`
  (the Linux verification compiled but never ran the window):**
  1. **`icons/icon.ico` is required on Windows.** `tauri-build` embeds a
     Windows Resource (via `tauri-winres`/`embed-resource`) and aborts
     with "`icons/icon.ico` not found"; the `.png` that satisfies
     `generate_context!()` is not enough. `write_tauri_project()` now
     also writes a minimal valid 16x16 `.ico`.
  2. **`frontendDist` must be relative, not absolute.** An absolute path
     is loaded at runtime as `file://<dir>/`, so the webview shows a
     directory listing instead of the app. The frontend is now copied
     into the project and referenced as `../frontend`, so
     `generate_context!()` embeds it and it is served over the app
     protocol. (This *reverses* the earlier "always absolute" decision,
     which had only ever been checked by a Linux compile, never a run.)
  3. **shinylive needs a real `http://localhost` origin.** Its service
     worker — which webR depends on for cross-origin isolation /
     `SharedArrayBuffer` — refuses Tauri's default `http://tauri.localhost`
     asset-protocol origin ("requires either a connection to localhost,
     or a connection via https"), leaving a permanent warning screen.
     This is the same class of failure `build_wasm()` hit under `file://`
     (see "Why no bundled static-server binary"), and the fix is the same
     shape: serve over a real localhost HTTP origin. The template now
     depends on `tauri-plugin-localhost`, creates the window in
     `main.rs`'s `setup()` pointed at `http://localhost:<port>/index.html`
     (picked via `portpicker`), and omits the config `windows` array to
     avoid a duplicate `"main"` label.
- `backend = "wasm"` (implemented): no sidecar R process; the embedded
  frontend is served to the webview over `http://127.0.0.1:<port>` by
  `tauri-plugin-localhost`, and the webview navigates to that same
  `127.0.0.1` origin (which shinylive accepts as a localhost name).
  **No Windows Firewall prompt** — verified. Two things had to be right
  for that: (a) the plugin is given `.host("127.0.0.1")` (its default,
  `"localhost"`, prompted); and, less obviously, (b) the port is
  reserved by binding a `std::net::TcpListener` to `127.0.0.1:0`
  directly, *not* via the `portpicker` crate — `portpicker` probes for a
  free port by binding to `0.0.0.0`/`[::]` (`UNSPECIFIED`), and that
  momentary wildcard bind is itself enough to trigger the firewall
  prompt even though the real server only ever listens on loopback.
  With both in place, `netstat` shows a single `127.0.0.1:<port>`
  listener and launching the `.exe` shows no prompt.
- `backend = "portable"` (not implemented): the portable-R runtime would
  run as a Tauri *sidecar* process; the webview would point at the
  sidecar's local port. Not attempted yet — wiring a Windows-only
  sidecar binary into a Tauri project that was only build/run-tested on
  Linux in this sandbox would be unverified in exactly the way this
  project tries to avoid.
- Android/iOS builds (not implemented) would go through `tauri android` /
  `tauri ios`, producing a sideloadable `.apk`/`.ipa`.

## Explicitly deferred / not designed yet

- Fully offline *build* pipeline (pre-mirroring webR/R-Portable/Tauri
  toolchain dependencies for build machines with no internet) — current
  design assumes the build machine has internet; revisit if that
  assumption turns out to be wrong for your team.
- `build_portable()` for macOS/Linux specifically (Windows via
  R-Portable is the well-trodden path; macOS/Linux need a statically
  linked R build, e.g. via `rig` or conda-forge R, not yet evaluated).
- `build_tauri(backend = "portable")` (Tauri + portable-R sidecar) and
  `build_tauri(platform = c("android", "ios"))`.
- Full per-OS Tauri installer bundling (`.msi`/`.dmg`/`.deb`/`.AppImage`)
  — `write_tauri_project()` deliberately ships `bundle.active = false`
  today; see "Native shell notes" above for why that's the right default,
  not just what got skipped.
- End-to-end verification of the opt-in `RMariaDB(server = TRUE)` and
  `rstan(rtools = TRUE)` native-runtime providers — implemented and
  scaffolded (see "Native-runtime provisioning" above) but not yet run
  on a clean box; each warns loudly at build time until it is.
