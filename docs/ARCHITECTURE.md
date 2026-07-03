# Architecture & decisions

`shinyalcatraz` turns a normal Shiny app into one or more **copy-and-run
bundles** that need no administrator rights and no internet access on the
machine they run on. This doc records why it's built the way it is, so
future changes don't quietly re-litigate settled tradeoffs.

## The three build targets

| | `build_wasm()` | `build_portable()` | `build_tauri()` |
|---|---|---|---|
| **Status** | Implemented (code unverified - see `CLAUDE.md` Verification notes) | Implemented for Windows, verified end-to-end; macOS/Linux not implemented | Implemented for `backend = "wasm"` desktop, verified end-to-end (real compile); `backend = "portable"` and mobile not implemented |
| **What runs on target** | Browser only (WASM) | Real portable R, launched via `shiny::runApp()` | Native shell (Tauri) wrapping either of the other two |
| **R install needed on target** | None | None (bundled) | None (bundled) |
| **Admin rights needed** | None | None | None (portable exe; WebView2 caveat below) |
| **CRAN package compatibility** | Only packages with precompiled WASM binaries (no arbitrary C/C++/Fortran source packages) | Full — anything installable on a normal R | Same as whichever backend it wraps |
| **Real filesystem / DB access** | No (browser sandbox only; virtual FS) | Yes | Yes, if backend is `"portable"` |
| **Typical size** | Tens of MB (webR runtime + package wasm binaries) | ~167MB verified for the demo app (R-Portable 4.2.0 + 1 package); scales with dependencies | Shell adds ~9MB verified on top of its backend |
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
`python3 -m http.server` if it's present, and fall back to opening
`index.html` directly, rather than shipping a bundled static-file-server
executable (e.g. a Go single-binary server). Locked-down corporate images
very often already have *some* Python, and shipping zero extra bytes beats
shipping a few hundred KB "just in case" — consistent with the project's
lazy/minimal coding convention (see `CLAUDE.md`). Revisit this if real
deployments show target machines with neither Python nor a browser that
tolerates `file://` WASM+service-worker loading.

## Native shell notes (verified for `backend = "wasm"` desktop; the rest is still planned)

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
- **WebView2 caveat (Windows, not yet verified — no Windows machine in
  the sandbox that built this):** present by default on Windows 10
  21H2+ and Windows 11. Older/locked-down images may lack it; the
  "Fixed Version" WebView2 distributable can be xcopied alongside the
  app without an install step (no admin rights needed), but adds
  ~150MB. The evergreen bootstrapper is *not* an option here since it
  typically needs admin rights.
- `backend = "wasm"` (implemented): no sidecar process; Tauri serves the
  frontend bundle via its asset protocol directly.
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
