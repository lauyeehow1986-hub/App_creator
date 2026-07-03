#' Build a portable, zero-admin-install bundle from a Shiny app
#'
#' Single entry point for every build target. Dispatches to
#' [build_wasm()], [build_portable()], and/or [build_tauri()] and
#' returns one manifest per target.
#'
#' @param app_dir Path to a directory containing a runnable Shiny app
#'   (an `app.R`, or `ui.R` + `server.R`).
#' @param targets Character vector of targets to build. One or more of
#'   `"wasm"`, `"portable"`, `"tauri"`. See `vignette("architecture")`
#'   for the tradeoffs of each.
#' @param out_dir Directory to write build output into. One
#'   subdirectory per target is created.
#' @param ... Target-specific arguments, forwarded to the underlying
#'   `build_*()` function (e.g. `platform` for `"portable"`/`"tauri"`).
#'
#' @return Invisibly, a list of manifests (one per target), each as
#'   returned by the corresponding `build_*()` function.
#' @export
build <- function(app_dir,
                   targets = "wasm",
                   out_dir = "dist",
                   ...) {
  check_app_dir(app_dir)
  targets <- match_targets(targets)

  manifests <- lapply(targets, function(target) {
    target_out <- fs::path(out_dir, target)
    switch(
      target,
      wasm     = build_wasm(app_dir, out_dir = target_out, ...),
      portable = build_portable(app_dir, out_dir = target_out, ...),
      tauri    = build_tauri(app_dir, out_dir = target_out, ...)
    )
  })
  names(manifests) <- targets

  invisible(manifests)
}

match_targets <- function(targets) {
  valid <- c("wasm", "portable", "tauri")
  unknown <- setdiff(targets, valid)
  if (length(unknown) > 0) {
    cli::cli_abort(c(
      "Unknown build target{?s}: {.val {unknown}}.",
      "i" = "Valid targets are {.val {valid}}."
    ))
  }
  unique(targets)
}
