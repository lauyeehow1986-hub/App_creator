# Architecture & decisions

`shinyalcatraz` turns a normal Shiny app into one or more **copy-and-run
bundles** that need no administrator rights and no internet access on the
machine they run on. This doc records why it's built the way it is, so
future changes don't quietly re-litigate settled tradeoffs.

## The three build targets

| | `build_wasm()` | `build_portable()` | `build_tauri()` |
|---|---|---|---|
| **Status** | Implemented | Planned | Planned |
| **What runs on target** | Browser only (WASM) | Real portable R + `httpuv` | Native shell (Tauri) wrapping either of the other two |
| **R install needed on target** | None | None (bundled) | None (bundled) |
| **Admin rights needed** | None | None | None (portable exe; WebView2 caveat below) |
| **CRAN package compatibility** | Only packages with precompiled WASM binaries (no arbitrary C/C++/Fortran source packages) | Full — anything installable on a normal R | Same as whichever backend it wraps |
| **Real filesystem / DB access** | No (browser sandbox only; virtual FS) | Yes | Yes, if backend is `"portable"` |
| **Typical size** | Tens of MB (webR runtime + package wasm binaries) | 100-300+ MB (R runtime + library) | Shell adds only ~1-10MB on top of its backend |
| **Cross-platform reach** | Anywhere with a modern browser: Windows/macOS/Linux/Android/iOS | Windows easiest (R-Portable); macOS/Linux need a statically-built R | Windows/macOS/Linux desktop + Android/iOS via Tauri 2 mobile |
| **Cold start** | Slower (WASM interpreter warmup) | Fast (native R) | Fast |

**Why WASM/shinylive is the default and the only implemented target so far:**
given the "maximum capability, minimum size" framing, minimum size is the
one that's non-negotiable across every target platform (including
Android/iOS, where you *can't* bundle a portable R runtime at all) — so
it has to work everywhere, and it's also the cheapest to build and verify
without needing per-OS portable R binaries or a Rust/Tauri toolchain.
`build_portable()` and `build_tauri()` are real, designed, and scaffolded
(see their roxygen docs in `R/target-portable.R` / `R/target-tauri.R`) but
intentionally not implemented until there's a concrete app that needs what
WASM can't do (native DB drivers, compiled-only packages, real disk I/O).

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
   told apart without diffing files. A "phone home if reachable" update
   banner is a plausible future addition (tracked below) but out of
   scope until there's a concrete intranet endpoint to check against.

## Why no bundled static-server binary

`build_wasm()`'s launcher scripts (`write_serve_launchers()`) shell out to
`python3 -m http.server` if it's present, and fall back to opening
`index.html` directly, rather than shipping a bundled static-file-server
executable (e.g. a Go single-binary server). Locked-down corporate images
very often already have *some* Python, and shipping zero extra bytes beats
shipping a few hundred KB "just in case" — consistent with the project's
lazy/minimal coding convention (see `CLAUDE.md`). Revisit this if real
deployments show target machines with neither Python nor a browser that
tolerates `file://` WASM+service-worker loading.

## Native shell notes (for when `build_tauri()` gets implemented)

- Tauri uses the OS's built-in webview (WebView2 on Windows, WKWebView on
  macOS/iOS, WebKitGTK on Linux, system webview on Android) instead of
  bundling a browser engine — this is what keeps the shell itself small
  (single-digit MB) regardless of what it wraps.
- **WebView2 caveat:** present by default on Windows 10 21H2+ and Windows
  11. Older/locked-down images may lack it; the "Fixed Version" WebView2
  distributable can be xcopied alongside the app without an install step
  (no admin rights needed), but adds ~150MB. The evergreen bootstrapper
  is *not* an option here since it typically needs admin rights.
- `backend = "wasm"`: no sidecar process; Tauri serves the shinylive
  bundle via its asset protocol directly, which also sidesteps the
  `file://` CORS/MIME issues the plain-browser launch path works around.
- `backend = "portable"`: the portable-R runtime runs as a Tauri
  *sidecar* process; the webview points at the sidecar's local `httpuv`
  port.
- Android/iOS builds go through `tauri android` / `tauri ios`, producing
  a sideloadable `.apk`/`.ipa` — no app-store or admin dependency.

## Explicitly deferred / not designed yet

- Opportunistic online update-check banner (`enable_update_check()` or
  similar) — needs a real intranet version endpoint to design against.
- Fully offline *build* pipeline (pre-mirroring webR/R-Portable/Tauri
  toolchain dependencies for build machines with no internet) — current
  design assumes the build machine has internet; revisit if that
  assumption turns out to be wrong for your team.
- `build_portable()` for macOS/Linux specifically (Windows via
  R-Portable is the well-trodden path; macOS/Linux need a statically
  linked R build, e.g. via `rig` or conda-forge R, not yet evaluated).
