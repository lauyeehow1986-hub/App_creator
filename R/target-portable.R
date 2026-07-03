#' Build the portable-R backend target (Windows implemented)
#'
#' Bundles a real portable R runtime plus the app's package
#' dependencies, with a `run.bat` launcher that starts the app via
#' `shiny::runApp()` and opens the default browser. Unlike
#' [build_wasm()], this gives full CRAN compatibility (compiled
#' C/C++/Fortran packages, real filesystem/DB access) at the cost of a
#' much larger bundle (~150-300+MB depending on dependencies).
#'
#' # How it works (`platform = "windows"`)
#' 1. Dependencies are auto-detected from the app's R files (every
#'    `library()`/`require()` call and every `pkg::fn()` usage) unless
#'    `packages` is supplied explicitly.
#' 2. A portable R runtime is downloaded from the
#'    [R-Portable](https://sourceforge.net/projects/rportable/) project
#'    (a PortableApps NSIS package) and cached in `cache_dir`, so
#'    repeat builds don't re-download it.
#' 3. Dependencies are installed into a private library inside the
#'    bundle using the *bundled* Rscript.exe (not the build machine's
#'    R), so the installed binaries match the shipped R version/ABI.
#'    The build machine needs internet for this step; the resulting
#'    bundle does not.
#' 4. A `run.bat` launcher sets `R_LIBS` to the bundle's private
#'    library (never the host's), then calls the bundled Rscript.exe
#'    to run `shiny::runApp(launch.browser = TRUE)`.
#' 5. `manifest.json` is written via the same `write_build_manifest()`
#'    every target uses, for version-stamping.
#'
#' `platform = "macos"`/`"linux"` are not implemented yet (R-Portable
#' is Windows-only; macOS/Linux would need a statically-linked R build,
#' e.g. via rig or conda-forge, not yet evaluated - see
#' `docs/ARCHITECTURE.md`).
#'
#' @inheritParams build
#' @param platform One of `"windows"`, `"macos"`, `"linux"`. Only
#'   `"windows"` is currently implemented.
#' @param out_dir Directory to write the portable bundle into.
#' @param packages Character vector of R package names to install into
#'   the bundle. If `NULL` (default), auto-detected from `app_dir`'s R
#'   files via [scan_r_package_deps()].
#' @param r_portable_version R-Portable version to fetch, e.g.
#'   `"4.2.0"`. If `NULL` (default), uses whatever
#'   `sourceforge.net/projects/rportable/files/latest` currently
#'   resolves to.
#' @param cache_dir Directory to cache the downloaded R-Portable build
#'   in across calls. Defaults to a per-user cache dir (see
#'   [tools::R_user_dir()]).
#' @param port Local port the launcher should use. Defaults to a fixed
#'   port (8973); pass a different value if that's likely to collide
#'   with something else on target machines.
#' @param ... Reserved for future options.
#' @return Invisibly, the build manifest (also written as
#'   `manifest.json` inside `out_dir`).
#' @export
build_portable <- function(app_dir, out_dir = "dist/portable",
                            platform = c("windows", "macos", "linux"),
                            packages = NULL,
                            r_portable_version = NULL,
                            cache_dir = tools::R_user_dir("shinyalcatraz", "cache"),
                            port = 8973,
                            ...) {
  check_app_dir(app_dir)
  platform <- rlang::arg_match(platform)
  if (platform != "windows") {
    cli::cli_abort(c(
      "!" = "{.fn build_portable}(platform = {.val {platform}}) is not implemented yet.",
      "i" = "Only {.val windows} is implemented so far (R-Portable is Windows-only).",
      "i" = "See {.file docs/ARCHITECTURE.md} for the macOS/Linux plan."
    ))
  }

  pkgs <- packages %||% scan_r_package_deps(app_dir)
  cli::cli_inform("Detected package dependencies: {.pkg {pkgs}}")

  r_portable_src <- fetch_r_portable(cache_dir, version = r_portable_version)

  fs::dir_create(out_dir)
  bundle_r_dir <- fs::path(out_dir, "R-Portable")
  if (!fs::dir_exists(bundle_r_dir)) {
    cli::cli_inform("Copying portable R runtime into bundle...")
    fs::dir_copy(r_portable_src, bundle_r_dir)
  }

  app_out <- fs::path(out_dir, "app")
  fs::dir_copy(app_dir, app_out, overwrite = TRUE)

  lib_dir <- fs::path(out_dir, "library")
  fs::dir_create(lib_dir)
  install_packages_portable(bundle_r_dir, lib_dir, pkgs)

  write_portable_launcher(out_dir, port = port)

  manifest <- write_build_manifest(out_dir, "portable", app_dir, extra = list(
    platform = platform,
    packages = pkgs,
    entry_point = "run.bat",
    launch = "Double-click run.bat - starts a local Shiny session and opens your default browser.",
    size = as.character(dir_size(out_dir))
  ))
  cli::cli_inform(c("v" = "portable bundle written to {.path {out_dir}} ({manifest$size})."))
  invisible(manifest)
}

#' Statically scan an app's R files for package dependencies
#'
#' Deliberately does not depend on `renv` (which would need its own
#' CRAN access to install, and is heavier than this needs): walks
#' parsed R expressions for `library()`/`require()` calls and regexes
#' for `pkg::fn()` usage instead.
#'
#' @param app_dir Directory containing the app's R files.
#' @return Sorted, deduplicated character vector of package names
#'   (excluding base/recommended packages already in R-Portable).
#' @export
scan_r_package_deps <- function(app_dir) {
  r_files <- fs::dir_ls(app_dir, recurse = TRUE, regexp = "[.][Rr]$", type = "file")
  base_pkgs <- rownames(utils::installed.packages(priority = c("base", "recommended")))

  pkgs <- unlist(lapply(r_files, function(f) {
    exprs <- tryCatch(parse(f, keep.source = FALSE), error = function(e) NULL)
    if (is.null(exprs)) return(character(0))

    from_calls <- unlist(lapply(exprs, extract_library_calls))

    text <- paste(readLines(f, warn = FALSE), collapse = "\n")
    from_ns <- regmatches(text, gregexpr("\\b[a-zA-Z][a-zA-Z0-9._]*(?=:{2,3})", text, perl = TRUE))[[1]]

    c(from_calls, from_ns)
  }))

  sort(unique(setdiff(pkgs, c(base_pkgs, "shinyalcatraz"))))
}

#' @keywords internal
#' @noRd
extract_library_calls <- function(expr) {
  if (!is.call(expr)) return(character(0))
  fn <- as.character(expr[[1]])[1]
  found <- character(0)
  if (fn %in% c("library", "require", "requireNamespace", "loadNamespace")) {
    arg <- expr[[2]]
    found <- if (is.symbol(arg)) as.character(arg) else if (is.character(arg)) arg else character(0)
  }
  # recurse into sub-expressions (e.g. calls inside a function body / block)
  sub <- unlist(lapply(as.list(expr)[-1], function(e) {
    if (is.call(e)) extract_library_calls(e) else character(0)
  }))
  c(found, sub)
}

#' Download and cache a portable R runtime for Windows
#' @keywords internal
#' @noRd
fetch_r_portable <- function(cache_dir, version = NULL) {
  fs::dir_create(cache_dir)

  url <- if (is.null(version)) {
    "https://sourceforge.net/projects/rportable/files/latest/download"
  } else {
    sprintf(
      "https://sourceforge.net/projects/rportable/files/R-Portable/%s/R-Portable_%s.paf.exe/download",
      version, version
    )
  }

  # Resolve redirects up front so we can name the cache dir by the
  # actual version, even when `version` wasn't supplied.
  resolved <- tryCatch(
    resolve_final_url(url),
    error = function(e) url
  )
  ver <- version %||% sub(".*/R-Portable_([0-9.]+)\\.paf\\.exe.*", "\\1", resolved)
  if (identical(ver, resolved)) ver <- "unknown"

  cached <- fs::path(cache_dir, paste0("R-Portable-", ver))
  if (fs::dir_exists(fs::path(cached, "bin"))) {
    cli::cli_inform("Using cached R-Portable {ver} from {.path {cached}}.")
    return(cached)
  }

  archive <- fs::path(cache_dir, paste0("R-Portable-", ver, ".paf.exe"))
  cli::cli_inform("Downloading R-Portable {ver} (one-time, then cached)...")
  # sourceforge's mirror-selection redirect chain isn't always followed
  # correctly by utils::download.file(); download from the
  # already-resolved final URL instead (falls back to download.file if
  # curl isn't on the build machine, though 7z is required regardless).
  curl_bin <- Sys.which("curl")
  if (nzchar(curl_bin)) {
    status <- system2(curl_bin, c(curl_windows_ssl_args(), "-sSL", "--max-time", "300", "-o", shQuote(archive), shQuote(resolved)))
    if (!identical(status, 0L) || !fs::file_exists(archive)) {
      cli::cli_abort("Download of R-Portable {ver} failed (curl exit status {status}).")
    }
  } else {
    utils::download.file(resolved, archive, mode = "wb", quiet = FALSE)
  }

  extract_dir <- fs::path(cache_dir, paste0(".extract-", ver))
  fs::dir_create(extract_dir)
  seven_zip <- Sys.which("7z")
  if (nzchar(seven_zip)) {
    system2(seven_zip, c("x", "-y", shQuote(archive), paste0("-o", shQuote(extract_dir))),
            stdout = FALSE, stderr = FALSE)
  } else {
    cli::cli_abort(c(
      "!" = "7-Zip ({.code 7z}) is required on the build machine to unpack R-Portable.",
      "i" = "Install it (e.g. {.code apt-get install p7zip-full} or {.url https://www.7-zip.org}) and retry."
    ))
  }

  extracted_r <- fs::path(extract_dir, "App", "R-Portable")
  if (!fs::dir_exists(fs::path(extracted_r, "bin"))) {
    cli::cli_abort("Unexpected R-Portable archive layout - {.path App/R-Portable/bin} not found after extraction.")
  }
  fs::dir_copy(extracted_r, cached)
  fs::dir_delete(extract_dir)
  fs::file_delete(archive)

  cached
}

#' Resolve the final URL after following HTTP redirects (sourceforge
#' mirror-selection redirects several times before the real file URL)
#' @keywords internal
#' @noRd
resolve_final_url <- function(url) {
  curl_bin <- Sys.which("curl")
  if (!nzchar(curl_bin)) return(url)
  out <- suppressWarnings(system2(
    curl_bin,
    c(curl_windows_ssl_args(), "-sS", "-o", "/dev/null", "-w", "%{url_effective}", "-L", "--max-time", "30", shQuote(url)),
    stdout = TRUE, stderr = FALSE
  ))
  if (length(out) > 0 && nzchar(out[1])) out[1] else url
}

#' Extra curl flags needed on Windows builds of curl (schannel backend)
#'
#' Verified on a real Windows machine: curl's schannel backend treats a
#' failed certificate-revocation check (`CRYPT_E_NO_REVOCATION_CHECK`,
#' curl exit 35) as fatal by default, which fires whenever the OCSP/CRL
#' endpoint isn't reachable - plausible on exactly the locked-down
#' corporate networks this package targets. `--ssl-no-revoke` is
#' schannel-specific (errors on curl builds using OpenSSL/other
#' backends), so only add it on Windows.
#' @keywords internal
#' @noRd
curl_windows_ssl_args <- function() {
  if (.Platform$OS.type == "windows") "--ssl-no-revoke" else character(0)
}

#' Install packages into a private library using the bundled R
#'
#' Two things verified on a real Windows machine, both silent-corruption
#' bugs a code-only review would have missed:
#'
#' 1. Forces `download.file.method = "wininet"`: R-Portable's bundled
#'    Rscript.exe defaults to the `libcurl` download method, whose
#'    schannel SSL backend hangs indefinitely (not even a fast failure)
#'    on this machine's network when it can't reach the
#'    certificate-revocation endpoint - the same underlying issue as
#'    `curl_windows_ssl_args()` above, but libcurl-via-R has no
#'    equivalent of curl.exe's `--ssl-no-revoke` flag exposed, so
#'    `wininet` (which doesn't do revocation checking the same way) is
#'    the workaround here instead.
#' 2. Clears `R_LIBS_USER`/`R_LIBS_SITE`/`R_LIBS` for the child process:
#'    the *build machine's own R* sets `R_LIBS_USER` in its process
#'    environment at startup (even when no such variable is configured
#'    anywhere persistent), and `system2()` passes that down to the
#'    bundled Rscript.exe by default. The bundled R then resolves
#'    `.libPaths()` to include the build machine's per-user library
#'    (a different R version/ABI) and can load an incompatible compiled
#'    dependency from there instead of building its own - observed as
#'    `shiny`'s install failing with `LoadLibrary failure: The specified
#'    procedure could not be found` while loading a `digest.dll` built
#'    for the *host's* R, not R-Portable's. Left unfixed, this is exactly
#'    the failure mode roxygen's "installed binaries match the shipped
#'    R version/ABI" claim promises can't happen.
#'
#' Without both fixes, a "successful"-looking bundle (no build error
#' surfaced beyond a warning) can silently ship with an empty or
#' broken package library.
#'
#' Also forces `type = "win.binary"`. R-Portable is pinned at an old,
#' fixed R version (currently 4.2.0), and CRAN stops refreshing a given
#' R-series' Windows *binary* repo well before it stops publishing new
#' *source* releases - so `install.packages()`'s default of preferring
#' whichever is newer will, for any actively-maintained package,
#' eventually try to compile from source on a machine that isn't
#' guaranteed to have Rtools. Forcing the binary means a missing binary
#' fails loudly and immediately instead of silently attempting (and
#' sometimes, as above, half-succeeding into) a source build.
#' @keywords internal
#' @noRd
install_packages_portable <- function(r_portable_dir, lib_dir, pkgs) {
  if (length(pkgs) == 0) return(invisible())
  rscript <- fs::path(r_portable_dir, "bin", "x64", "Rscript.exe")
  if (!fs::file_exists(rscript)) rscript <- fs::path(r_portable_dir, "bin", "Rscript.exe")

  install_expr <- sprintf(
    'options(download.file.method = "wininet"); install.packages(c(%s), lib = %s, repos = "https://cloud.r-project.org", type = "win.binary")',
    paste(sprintf('"%s"', pkgs), collapse = ", "),
    sprintf('"%s"', gsub("\\\\", "/", as.character(lib_dir)))
  )
  cli::cli_inform("Installing {length(pkgs)} package{?s} into the bundle's private library...")
  # system2()'s own `env` argument is unreliable on Windows (verified: it
  # makes even a trivial `system2("cmd", ..., env = "FOO=bar")` fail with
  # status 5) - Sys.setenv()/Sys.unsetenv() around the call, relying on
  # ordinary child-process environment inheritance, is the version that
  # actually works.
  isolate_vars <- c("R_LIBS_USER", "R_LIBS_SITE", "R_LIBS")
  old_vals <- Sys.getenv(isolate_vars, unset = NA, names = TRUE)
  Sys.setenv(R_LIBS_USER = "", R_LIBS_SITE = "", R_LIBS = "")
  on.exit({
    to_restore <- old_vals[!is.na(old_vals)]
    if (length(to_restore) > 0) do.call(Sys.setenv, as.list(to_restore))
    Sys.unsetenv(names(old_vals)[is.na(old_vals)])
  }, add = TRUE)

  status <- system2(as.character(rscript), c("--vanilla", "-e", shQuote(install_expr)))
  if (!identical(status, 0L)) {
    cli::cli_warn("Package installation exited with status {status} - check the bundle's library before shipping it.")
  }
  invisible()
}

#' Write the run.bat launcher for a portable bundle
#' @keywords internal
#' @noRd
write_portable_launcher <- function(out_dir, port) {
  runner_r <- c(
    'options(shiny.launch.browser = TRUE)',
    sprintf('shiny::runApp("app", port = %d, launch.browser = TRUE, host = "127.0.0.1")', port)
  )
  writeLines(runner_r, fs::path(out_dir, "run_app.R"))

  bat <- c(
    "@echo off",
    "cd /d %~dp0",
    'set R_LIBS=%~dp0library',
    'set R_LIBS_USER=%~dp0library',
    '"%~dp0R-Portable\\bin\\x64\\Rscript.exe" --vanilla run_app.R'
  )
  writeLines(bat, fs::path(out_dir, "run.bat"))
  invisible(out_dir)
}
