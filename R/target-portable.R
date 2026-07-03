#' Build the portable-R backend target (planned, not yet implemented)
#'
#' Bundles a real portable R runtime plus the app's full package
#' library, with a launcher script that starts a local `httpuv` server
#' and opens the default browser at `http://127.0.0.1:<port>`. Unlike
#' [build_wasm()], this gives full CRAN compatibility (compiled
#' C/C++/Fortran packages, real filesystem/DB access) at the cost of a
#' much larger bundle (~100-300+MB).
#'
#' # Planned implementation
#' 1. Resolve the app's dependencies (`renv::dependencies()` or a
#'    manually supplied list).
#' 2. Fetch/cache a portable R build for `platform` (Windows via
#'    [R-Portable](https://sourceforge.net/projects/rportable/);
#'    macOS/Linux via a statically-linked R build, e.g. from
#'    rig/conda-forge) into a local cache dir so repeat builds are
#'    fast and offline-buildable.
#' 3. Install the resolved packages into a private library inside the
#'    bundle (`R_LIBS_USER` pinned to the bundle, never the host's
#'    library — see the R-Portable isolation caveat in
#'    `vignette("architecture")`).
#' 4. Write a `run.bat`/`run.command`/`run.sh` launcher that sets
#'    `R_LIBS`, starts `httpuv::runServer()`, and opens the browser.
#' 5. Emit `manifest.json` via [write_build_manifest()], same as every
#'    other target, so version-stamping is consistent across targets.
#'
#' @inheritParams build
#' @param platform One of `"windows"`, `"macos"`, `"linux"`.
#' @param out_dir Directory to write the portable bundle into.
#' @param ... Reserved for future options.
#' @return Never returns normally yet; see Details.
#' @export
build_portable <- function(app_dir, out_dir = "dist/portable",
                            platform = c("windows", "macos", "linux"), ...) {
  check_app_dir(app_dir)
  platform <- rlang::arg_match(platform)
  cli::cli_abort(c(
    "!" = "{.fn build_portable} is planned but not yet implemented.",
    "i" = "Use {.fn build_wasm} today, or track progress in {.file docs/ARCHITECTURE.md}."
  ))
}
