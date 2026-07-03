#' @keywords internal
#' @noRd
`%||%` <- function(x, y) if (is.null(x)) y else x

#' Validate that a directory looks like a runnable Shiny app
#' @param app_dir Path to check.
#' @keywords internal
#' @noRd
check_app_dir <- function(app_dir) {
  if (!fs::dir_exists(app_dir)) {
    cli::cli_abort("{.path {app_dir}} does not exist or is not a directory.")
  }
  has_app_r <- fs::file_exists(fs::path(app_dir, "app.R"))
  has_ui_server <- fs::file_exists(fs::path(app_dir, "ui.R")) &&
    fs::file_exists(fs::path(app_dir, "server.R"))
  if (!has_app_r && !has_ui_server) {
    cli::cli_abort(c(
      "{.path {app_dir}} does not look like a Shiny app.",
      "i" = "Expected an {.file app.R}, or both {.file ui.R} and {.file server.R}."
    ))
  }
  invisible(app_dir)
}

#' Current git commit SHA of the working directory, if any
#' @keywords internal
#' @noRd
git_sha <- function(path = ".") {
  sha <- tryCatch(
    system2("git", c("-C", shQuote(path), "rev-parse", "--short", "HEAD"),
            stdout = TRUE, stderr = FALSE),
    error = function(e) character(0)
  )
  if (length(sha) == 0 || !nzchar(sha)) "unknown" else sha
}

#' Total size of a directory, human-readable
#' @keywords internal
#' @noRd
dir_size <- function(path) {
  files <- fs::dir_ls(path, recurse = TRUE, type = "file")
  if (length(files) == 0) return(fs::as_fs_bytes(0))
  sum(fs::file_size(files))
}

#' Write the manifest.json every build target embeds in its output
#'
#' Supports the "version-stamped builds" convention: every bundle
#' carries a visible version/build-hash so IT/analysts can tell two
#' offline copies apart without diffing files.
#'
#' @keywords internal
#' @noRd
write_build_manifest <- function(out_dir, target, app_dir, extra = list()) {
  fs::dir_create(out_dir)
  manifest <- utils::modifyList(
    list(
      package = "shinyalcatraz",
      target = target,
      app = fs::path_file(fs::path_abs(app_dir)),
      built_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
      build_sha = git_sha(app_dir),
      package_version = as.character(utils::packageVersion("shinyalcatraz"))
    ),
    extra
  )
  jsonlite::write_json(
    manifest,
    fs::path(out_dir, "manifest.json"),
    auto_unbox = TRUE,
    pretty = TRUE
  )
  manifest
}
