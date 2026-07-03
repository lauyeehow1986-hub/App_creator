#' Build the pure-browser WebAssembly (shinylive/webR) target
#'
#' Compiles the app's R/Shiny code and pre-compiled WASM package
#' binaries into a static bundle that runs entirely inside the user's
#' existing browser — no R install, no server process, on any OS with
#' a modern browser (Windows/macOS/Linux/Android/iOS). This is the
#' default, smallest-footprint target; see `vignette("architecture")`
#' for where it breaks down (arbitrary compiled CRAN packages, native
#' filesystem/DB access).
#'
#' Requires the `shinylive` package on the *build* machine only (the
#' deployment target needs nothing). Run once with internet access so
#' `shinylive` can download/cache the webR runtime and package
#' binaries; subsequent builds reuse that cache.
#'
#' @inheritParams build
#' @param out_dir Directory to write the static bundle into.
#' @param serve_launcher If `TRUE` (default), write a `run.bat` /
#'   `run.sh` launcher into `out_dir` that serves the bundle over
#'   `http://localhost` using whatever local static-server tooling is
#'   already on the machine, sidestepping the `file://` CORS/MIME
#'   restrictions some browsers apply to WASM + service workers.
#' @param ... Passed through to `shinylive::export()`.
#' @return Invisibly, the build manifest (also written as
#'   `manifest.json` inside `out_dir`).
#' @export
build_wasm <- function(app_dir, out_dir = "dist/wasm", serve_launcher = TRUE, ...) {
  check_app_dir(app_dir)
  rlang::check_installed("shinylive", reason = "to build the wasm target")

  fs::dir_create(fs::path_dir(fs::path_abs(out_dir)))
  cli::cli_inform("Exporting {.path {app_dir}} to a shinylive/webR bundle...")
  shinylive::export(appdir = app_dir, destdir = out_dir, ...)

  if (serve_launcher) write_serve_launchers(out_dir)

  manifest <- write_build_manifest(out_dir, "wasm", app_dir, extra = list(
    entry_point = "index.html",
    launch = if (serve_launcher) {
      "Double-click run.bat (Windows) or run.sh (macOS/Linux) to serve locally, or open index.html directly."
    } else {
      "Open index.html directly, or serve out_dir with any static file server."
    },
    size = as.character(dir_size(out_dir))
  ))
  cli::cli_inform(c("v" = "wasm bundle written to {.path {out_dir}} ({manifest$size})."))
  invisible(manifest)
}

#' Write minimal launcher scripts that serve a static bundle locally
#'
#' Deliberately does not bundle a static-server binary: locked-down
#' machines already have *something* that can serve a folder (Python,
#' or the browser itself via file://), so we shell out to whatever is
#' found first instead of shipping more bytes.
#' @keywords internal
#' @noRd
write_serve_launchers <- function(out_dir, port = 8973) {
  bat <- c(
    "@echo off",
    "cd /d %~dp0",
    sprintf("where python >nul 2>nul && (python -m http.server %d) || (echo No local Python found - opening index.html directly instead. & start index.html)", port)
  )
  sh <- c(
    "#!/bin/sh",
    "cd \"$(dirname \"$0\")\"",
    sprintf(
      "command -v python3 >/dev/null 2>&1 && exec python3 -m http.server %d || { echo 'No local python3 found - opening index.html directly instead.'; xdg-open index.html 2>/dev/null || open index.html 2>/dev/null; }",
      port
    )
  )
  fs::path(out_dir, "run.bat") |> writeLines(text = bat)
  sh_path <- fs::path(out_dir, "run.sh")
  writeLines(sh, sh_path)
  fs::file_chmod(sh_path, "755")
  invisible(out_dir)
}
