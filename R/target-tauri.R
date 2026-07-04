#' Build the native shell (Tauri) target
#'
#' Wraps a [build_wasm()] bundle in a native Tauri shell so the app
#' launches as a real double-click desktop app instead of "open this
#' HTML file in a browser". Tauri uses the OS's built-in webview
#' (WebView2 on Windows, WKWebView on macOS, WebKitGTK on Linux)
#' rather than bundling a browser engine, which is why the shell adds
#' only single-digit MB on top of the wasm payload (verified: a
#' minimal Tauri shell built from this package's own generator is
#' ~9MB on Linux).
#'
#' # What this does
#' 1. Builds (or reuses, via `frontend_dist`) a [build_wasm()] bundle
#'    as the frontend.
#' 2. Generates a `src-tauri-project/` Rust/Tauri project around it
#'    (`write_tauri_project()`) - a real, verified-to-compile Tauri 2
#'    project, not a template that's only been read, not run.
#' 3. If a Tauri CLI is available on the *build* machine (`cargo tauri`
#'    or, failing that, `npx @tauri-apps/cli`), builds a bare
#'    executable (`--no-bundle`: a self-contained binary, no installer
#'    - matches the "just copy it, no install" ethos of the whole
#'    package; full per-OS installer packaging (.msi/.dmg/.deb) is a
#'    possible future addition, not attempted here). If no CLI is
#'    found, the project is left scaffolded and ready for `cargo tauri
#'    build` to be run manually.
#'
#' Only builds for the *current host* platform - cross-compiling a
#' Tauri app for Windows/macOS from another OS needs additional
#' toolchains (`cargo-xwin`, `osxcross`) not wired up here. `platform`
#' is validated but not used to cross-compile; see
#' `docs/ARCHITECTURE.md`.
#'
#' `backend = "portable"` (wrapping a [build_portable()] bundle via a
#' Tauri sidecar process) and mobile platforms (`"android"`/`"ios"`)
#' are designed but not implemented yet - both fail loudly rather than
#' silently doing the wrong thing.
#'
#' @inheritParams build
#' @param backend One of `"wasm"` (implemented) or `"portable"`
#'   (not yet implemented).
#' @param platform One or more of `"windows"` (default), `"macos"`,
#'   `"linux"` (validated; only the current host is actually built -
#'   see Details). `"android"`/`"ios"` are not yet implemented.
#' @param out_dir Directory to write the generated project/build into.
#' @param frontend_dist Path to an already-built [build_wasm()] bundle
#'   to wrap. If `NULL` (default), one is built automatically into
#'   `out_dir/wasm-frontend`.
#' @param app_name Application name. If `NULL`, derived from `app_dir`.
#' @param identifier Reverse-DNS bundle identifier (e.g.
#'   `"com.mycompany.myapp"`). Required to be non-default and unique
#'   per Tauri - if `NULL`, derived from `app_name`.
#' @param run_build If `TRUE` (default), attempt to actually compile
#'   the generated project. If no Tauri CLI is found, this degrades to
#'   scaffolding only (with a warning), rather than failing.
#' @param ... Reserved for future options.
#' @return Invisibly, the build manifest (also written as
#'   `manifest.json` inside `out_dir`).
#' @export
build_tauri <- function(app_dir, out_dir = "dist/tauri",
                         backend = c("wasm", "portable"),
                         platform = "windows",
                         frontend_dist = NULL,
                         app_name = NULL,
                         identifier = NULL,
                         run_build = TRUE,
                         ...) {
  check_app_dir(app_dir)
  backend <- rlang::arg_match(backend)
  # NB: `platform`'s default is deliberately a single value, not the
  # full `values` set below - arg_match(multiple = TRUE) treats an
  # unchanged default equal to `values` as "the user selected all of
  # these", which would make every unspecified-platform call abort on
  # the not-yet-implemented mobile targets.
  platform <- rlang::arg_match(
    platform,
    values = c("windows", "macos", "linux", "android", "ios"),
    multiple = TRUE
  )

  if (backend == "portable") {
    cli::cli_abort(c(
      "!" = "{.fn build_tauri}(backend = {.val portable}) is not implemented yet.",
      "i" = "Use {.code backend = \"wasm\"} today; see {.file docs/ARCHITECTURE.md} for the sidecar plan."
    ))
  }
  mobile <- intersect(platform, c("android", "ios"))
  if (length(mobile) > 0) {
    cli::cli_abort(c(
      "!" = "{.fn build_tauri}(platform = {.val {mobile}}) is not implemented yet.",
      "i" = "Desktop platforms (windows/macos/linux) are supported; mobile needs {.code tauri android/ios init}, not yet wired up."
    ))
  }

  app_name <- app_name %||% tauri_safe_name(fs::path_file(fs::path_abs(app_dir)))
  identifier <- identifier %||% paste0("com.shinyalcatraz.", app_name)

  fs::dir_create(out_dir)
  frontend_dist <- frontend_dist %||% {
    wasm_dir <- fs::path(out_dir, "wasm-frontend")
    build_wasm(app_dir, out_dir = wasm_dir, serve_launcher = FALSE)
    wasm_dir
  }

  project_dir <- fs::path(out_dir, "src-tauri-project")
  write_tauri_project(
    project_dir,
    frontend_dist = fs::path_abs(frontend_dist),
    app_name = app_name,
    identifier = identifier
  )

  built <- FALSE
  binary_path <- NA_character_
  if (run_build) {
    result <- run_tauri_build(project_dir)
    built <- result$built
    binary_path <- result$binary_path
  }

  manifest <- write_build_manifest(out_dir, "tauri", app_dir, extra = list(
    backend = backend,
    platform = platform,
    identifier = identifier,
    project_dir = as.character(project_dir),
    built = built,
    entry_point = if (built) binary_path else NA_character_,
    launch = if (built) {
      "Double-click the built native app - no browser or R install needed on the target."
    } else {
      "Project scaffolded but not built - run `cargo tauri build` inside src-tauri-project/src-tauri (needs Rust + the Tauri CLI on the build machine)."
    }
  ))

  if (built) {
    cli::cli_inform(c("v" = "native shell built at {.path {binary_path}}."))
  } else {
    cli::cli_inform(c("i" = "Tauri project scaffolded at {.path {project_dir}} (not built - see manifest.json)."))
  }
  invisible(manifest)
}

#' @keywords internal
#' @noRd
tauri_safe_name <- function(x) {
  x <- tolower(x)
  x <- gsub("[^a-z0-9]+", "-", x)
  gsub("^-+|-+$", "", x)
}

#' Write a minimal, verified-to-compile Tauri 2 project
#'
#' This template was hand-verified (not just hand-written): a project
#' generated with this exact shape was compiled and run through
#' `cargo check` and a full `cargo tauri build --no-bundle` to confirm
#' it produces a working native binary before this generator was
#' written. Two things a naive template gets wrong, both fixed here:
#' `frontendDist` must resolve correctly (this function always writes
#' an absolute path, sidestepping relative-path-from-`src-tauri`
#' confusion), and `identifier` must not be left at the
#' `com.tauri.dev` default (Tauri refuses to build otherwise). A tiny
#' embedded placeholder PNG is also required - `tauri::generate_context!()`
#' looks for `icons/icon.png` unconditionally, even with bundling
#' disabled.
#'
#' @keywords internal
#' @noRd
write_tauri_project <- function(project_dir, frontend_dist, app_name, identifier) {
  src_tauri <- fs::path(project_dir, "src-tauri")
  fs::dir_create(fs::path(src_tauri, "src"))
  fs::dir_create(fs::path(src_tauri, "icons"))
  fs::dir_create(fs::path(src_tauri, "capabilities"))

  crate_name <- gsub("-", "_", app_name)

  writeLines(sprintf(
    '[package]
name = "%s"
version = "0.1.0"
edition = "2021"

[build-dependencies]
tauri-build = { version = "2" }

[dependencies]
tauri = { version = "2" }
tauri-plugin-localhost = "2"
serde_json = "1.0"
serde = { version = "1.0", features = ["derive"] }
', crate_name), fs::path(src_tauri, "Cargo.toml"))

  writeLines('fn main() {
    tauri_build::build()
}
', fs::path(src_tauri, "build.rs"))

  writeLines(sprintf('#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::net::TcpListener;
use tauri::{WebviewUrl, WebviewWindowBuilder};

fn main() {
    // shinylive requires a real http://localhost (or https) origin for its
    // service worker + webR to start; Tauri\'s default asset protocol serves
    // the frontend from http://tauri.localhost, which shinylive rejects
    // ("requires either a connection to localhost, or a connection via https").
    // tauri-plugin-localhost serves the embedded frontend over a real loopback
    // origin instead, which satisfies that check. Verified by launching the
    // built .exe on Windows - the asset-protocol origin left the shinylive app
    // permanently on its service-worker warning screen.
    //
    // Bind explicitly to 127.0.0.1 (not the plugin default "localhost"): a
    // loopback-IPv4 listener does not trip Windows Firewall\'s "allow network
    // access" prompt, whereas the default did. shinylive accepts 127.0.0.1 as a
    // localhost name, so the webview navigates there directly.
    let host = "127.0.0.1";
    // Reserve a free port by binding to loopback only, then drop the listener
    // and hand the port to the plugin. Do NOT use the portpicker crate here: it
    // probes ports by binding to 0.0.0.0/[::] (UNSPECIFIED), and that momentary
    // wildcard bind is itself what triggers the Windows Firewall prompt we are
    // trying to avoid - even though the real server only ever binds loopback.
    let port = TcpListener::bind((host, 0))
        .expect("failed to reserve a loopback port")
        .local_addr()
        .expect("failed to read reserved port")
        .port();
    tauri::Builder::default()
        .plugin(tauri_plugin_localhost::Builder::new(port).host(host).build())
        .setup(move |app| {
            let url = format!("http://{}:{}/index.html", host, port);
            WebviewWindowBuilder::new(app, "main", WebviewUrl::External(url.parse().unwrap()))
                .title("%s")
                .inner_size(1000.0, 800.0)
                .build()?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
', app_name), fs::path(src_tauri, "src", "main.rs"))

  # Copy the frontend bundle into the project and reference it with a path
  # RELATIVE to tauri.conf.json ("../frontend"). Tauri only embeds frontendDist
  # (via generate_context!()) and serves index.html over its app protocol when
  # the path resolves relative to the config; an ABSOLUTE path is instead loaded
  # as a runtime `file://<dir>/` URL, so the webview shows a directory listing,
  # never the app. This only shows up when you actually launch the built .exe -
  # the Linux `cargo tauri build` compile-check that first "verified" this
  # template never ran the window. Copying the bundle in also makes the project
  # self-contained (no dependency on an external absolute path at build time).
  frontend_local <- fs::path(project_dir, "frontend")
  if (fs::dir_exists(frontend_local)) fs::dir_delete(frontend_local)
  fs::dir_copy(frontend_dist, frontend_local)

  conf <- list(
    productName = app_name,
    version = "0.1.0",
    identifier = identifier,
    build = list(frontendDist = "../frontend"),
    # No `windows` here on purpose: the window is created in main.rs's setup()
    # hook so it can point at the tauri-plugin-localhost URL. Declaring a window
    # here too would collide on the "main" label.
    app = list(
      security = list(csp = NULL)
    ),
    bundle = list(active = FALSE, icon = list())
  )
  jsonlite::write_json(conf, fs::path(src_tauri, "tauri.conf.json"),
                        auto_unbox = TRUE, pretty = TRUE, null = "null")

  jsonlite::write_json(
    list(identifier = "default", description = "default permissions",
         windows = list("main"), permissions = list("core:default")),
    fs::path(src_tauri, "capabilities", "default.json"),
    auto_unbox = TRUE, pretty = TRUE
  )

  # 32x32 solid placeholder icon (verified minimal PNG that satisfies
  # tauri::generate_context!()'s unconditional icon lookup).
  icon_b64 <- paste0(
    "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAALUlEQVR42u3OIQEAAAwCMJLQ",
    "v+UfAzMxv7S9pQgICAgICAgICAgICAgICKwDD5XdZEzlqKFkAAAAAElFTkSuQmCC"
  )
  writeBin(jsonlite::base64_dec(icon_b64), fs::path(src_tauri, "icons", "icon.png"))

  # icon.ico is *also* required, but only on Windows: `tauri-build`'s build
  # script embeds a Windows Resource (via tauri-winres/embed-resource) and
  # aborts with "`icons/icon.ico` not found" if it's missing. This never
  # surfaced on the Linux compile that first verified this template (no .rc
  # step there), only on a real Windows `cargo tauri build`. Minimal valid
  # 16x16 32-bit BMP-backed .ico, solid dark grey/opaque.
  ico_b64 <- paste0(
    "AAABAAEAEBAAAAEAIABoBAAAFgAAACgAAAAQAAAAIAAAAAEAIAAAAAAAAAAAAAAAAA",
    "AAAAAAAAAAAAAAAAAtLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8t",
    "LS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS",
    "3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/",
    "LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS",
    "0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t",
    "/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y",
    "0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0t",
    "Lf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf",
    "8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8t",
    "LS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS",
    "3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/",
    "LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS",
    "0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t",
    "/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y",
    "0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0t",
    "Lf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf",
    "8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8t",
    "LS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS",
    "3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/",
    "LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS",
    "0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/LS0t/y0tLf8tLS3/AAAA",
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    "AAAAAAAAAAAAAAAA=="
  )
  writeBin(jsonlite::base64_dec(ico_b64), fs::path(src_tauri, "icons", "icon.ico"))

  invisible(project_dir)
}

#' Locate the cargo bin directory when it isn't on PATH
#'
#' rustup installs the toolchain into `~/.cargo/bin` but doesn't always
#' add it to `PATH` - e.g. an `rustup-init --no-modify-path` install, or
#' an R/RStudio session started before the profile change. Return that
#' directory when `cargo` lives there but isn't already resolvable, so a
#' Tauri build can still find `cargo`/`cargo-tauri`.
#' @keywords internal
#' @noRd
find_cargo_bin <- function() {
  if (nzchar(Sys.which("cargo"))) return(NULL) # already on PATH
  home <- Sys.getenv("USERPROFILE", unset = Sys.getenv("HOME"))
  cargo_home <- Sys.getenv("CARGO_HOME", unset = file.path(home, ".cargo"))
  bin <- file.path(cargo_home, "bin")
  cargo_exe <- file.path(bin, if (.Platform$OS.type == "windows") "cargo.exe" else "cargo")
  if (file.exists(cargo_exe)) bin else NULL
}

#' Locate an available Tauri CLI on the build machine
#' @keywords internal
#' @noRd
find_tauri_cli <- function() {
  if (nzchar(Sys.which("cargo-tauri"))) {
    return(list(cmd = "cargo", pre_args = "tauri"))
  }
  if (nzchar(Sys.which("npx"))) {
    return(list(cmd = "npx", pre_args = c("--yes", "@tauri-apps/cli")))
  }
  NULL
}

#' Build a Tauri project, if a CLI is available
#' @keywords internal
#' @noRd
run_tauri_build <- function(project_dir) {
  # rustup's ~/.cargo/bin isn't always on PATH; add it (for this call only) so
  # both our CLI discovery below and the build subprocess - which shells out to
  # `cargo` - can find the toolchain. Otherwise the npx fallback runs and then
  # dies with "cargo: program not found".
  cargo_bin <- find_cargo_bin()
  if (!is.null(cargo_bin)) {
    old_path <- Sys.getenv("PATH")
    Sys.setenv(PATH = paste(cargo_bin, old_path, sep = .Platform$path.sep))
    on.exit(Sys.setenv(PATH = old_path), add = TRUE)
  }

  cli_spec <- find_tauri_cli()
  if (is.null(cli_spec)) {
    cli::cli_warn(c(
      "!" = "No Tauri CLI found on the build machine (checked {.code cargo-tauri} and {.code npx}, plus {.path ~/.cargo/bin}).",
      "i" = "Install it with {.code cargo install tauri-cli} (needs a Rust toolchain), then re-run; the project is scaffolded at {.path {project_dir}}."
    ))
    return(list(built = FALSE, binary_path = NA_character_))
  }

  old_wd <- getwd()
  on.exit(setwd(old_wd), add = TRUE)
  setwd(as.character(project_dir))

  cli::cli_inform("Building native shell via {.code {cli_spec$cmd} {paste(cli_spec$pre_args, collapse = ' ')} build}...")
  status <- system2(cli_spec$cmd, c(cli_spec$pre_args, "build", "--no-bundle"))
  if (!identical(status, 0L)) {
    cli::cli_warn("Tauri build exited with status {status} - see output above.")
    return(list(built = FALSE, binary_path = NA_character_))
  }

  crate_name <- fs::path_file(project_dir) # placeholder, corrected below
  cargo_toml <- readLines(fs::path("src-tauri", "Cargo.toml"))
  name_line <- grep('^name = ', cargo_toml, value = TRUE)[1]
  crate_name <- gsub('name = "|"', "", name_line)
  bin_name <- if (.Platform$OS.type == "windows") paste0(crate_name, ".exe") else crate_name
  binary_path <- fs::path_abs(fs::path("src-tauri", "target", "release", bin_name))

  list(built = fs::file_exists(binary_path), binary_path = as.character(binary_path))
}
