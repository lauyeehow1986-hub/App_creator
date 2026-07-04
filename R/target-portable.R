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
#'    Each dependency is routed by where the build machine got it:
#'    CRAN packages install as Windows binaries; packages from a git
#'    forge or URL (GitHub/GitLab/Bitbucket/generic git/tarball URL, per
#'    the `RemoteType` in their `DESCRIPTION`) reinstall via the matching
#'    `remotes::install_*()`; Bioconductor packages (a `biocViews` field)
#'    from the Bioconductor repos; and packages from a custom CRAN-like
#'    repo (r-universe, Posit Package Manager) via that repo's URL from
#'    their `Repository` field - all run by the bundled R so the binaries
#'    match its ABI. Anything a repo still can't provide but that's
#'    installed and pure-R on the build machine is copied in. After
#'    install, the bundle library is checked and any package that failed
#'    to install is reported, rather than silently shipping a bundle
#'    that crashes on the target. The build machine needs internet for
#'    this step; the resulting bundle does not.
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
#' @param native_runtime Named list of per-provider options for packages
#'   that need a *native runtime outside the R package* (a JVM for
#'   `rJava`, OCR language data for `tesseract`, a database server for
#'   `RMariaDB`, a C++ toolchain for `rstan`/`brms`). Providers are
#'   auto-selected from the dependency tree; this list only tunes them,
#'   e.g. `list(tesseract = list(langs = c("eng", "fra")), mariadb =
#'   list(server = TRUE), toolchain = list(rtools = TRUE))`. Set a
#'   provider's `enabled = FALSE` to skip it. See
#'   [native_runtime_providers()] and `docs/ARCHITECTURE.md`.
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
                            native_runtime = list(),
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

  env_lines <- provision_native_runtimes(pkgs, out_dir, cache_dir, native_runtime)

  write_portable_launcher(out_dir, port = port, env_lines = env_lines)

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
#' @param include_commented If `TRUE`, also pick up `library()`/`require()`
#'   calls that are *commented out*. Off by default (a commented-out
#'   `library()` isn't a real dependency), but the `build_wasm()`
#'   pre-flight turns it on because `shinylive`'s own dependency scanner
#'   (renv-based) reads commented `library()` lines and will try to fetch
#'   those packages - so the pre-flight must see them too.
#' @return Sorted, deduplicated character vector of package names
#'   (excluding base/recommended packages already in R-Portable).
#' @export
scan_r_package_deps <- function(app_dir, include_commented = FALSE) {
  r_files <- fs::dir_ls(app_dir, recurse = TRUE, regexp = "[.][Rr]$", type = "file")

  # Skip build outputs and vendored/library dirs that aren't the app's own
  # source. Scanning e.g. a previous `dist/wasm` shinylive distribution (which
  # bundles webR + package sources and C++ headers) turns every `Foo::` into a
  # bogus "dependency" - Eigen, ArrayXd, BiocGenerics, ... - and its non-UTF-8
  # data files trip parse/regex warnings.
  ignore <- c("dist", "build", "node_modules", "src-tauri", "shinylive",
              "wasm-frontend", "renv", "packrat", ".git", ".Rproj.user", "_snaps")
  rel_parts <- strsplit(as.character(fs::path_rel(r_files, app_dir)), "/", fixed = TRUE)
  r_files <- r_files[!vapply(rel_parts, function(p) any(p %in% ignore), logical(1))]

  base_pkgs <- rownames(utils::installed.packages(priority = c("base", "recommended")))

  pkgs <- unlist(lapply(r_files, function(f) {
    exprs <- tryCatch(suppressWarnings(parse(f, keep.source = FALSE)),
                      error = function(e) NULL)
    from_calls <- if (is.null(exprs)) character(0) else unlist(lapply(exprs, extract_library_calls))

    text <- tryCatch(
      iconv(paste(readLines(f, warn = FALSE, encoding = "UTF-8"), collapse = "\n"),
            to = "UTF-8", sub = ""),
      error = function(e) ""
    )
    from_ns <- suppressWarnings(
      regmatches(text, gregexpr("\\b[a-zA-Z][a-zA-Z0-9._]*(?=:{2,3})", text, perl = TRUE))[[1]]
    )

    # Optionally also match library()/require() in the raw text, which catches
    # commented-out calls that `parse()` (and thus `from_calls`) skips - shinylive
    # detects those and tries to fetch them.
    from_commented <- if (include_commented) {
      m <- suppressWarnings(regmatches(
        text,
        gregexpr("(?:library|require)\\s*\\(\\s*[\"']?([A-Za-z][A-Za-z0-9._]*)", text, perl = TRUE)
      )[[1]])
      sub("^(?:library|require)\\s*\\(\\s*[\"']?", "", m, perl = TRUE)
    } else {
      character(0)
    }

    c(from_calls, from_ns, from_commented)
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

#' Locate the 7-Zip executable
#'
#' The Windows 7-Zip installer does *not* add itself to `PATH`, so a
#' `Sys.which("7z")` alone fails on a perfectly normal install. Check
#' `PATH` first, then the standard install locations before giving up.
#' @keywords internal
#' @noRd
find_7zip <- function() {
  found <- Sys.which("7z")
  if (nzchar(found)) return(unname(found))
  if (.Platform$OS.type == "windows") {
    candidates <- c(
      file.path(Sys.getenv("ProgramFiles"), "7-Zip", "7z.exe"),
      file.path(Sys.getenv("ProgramFiles(x86)"), "7-Zip", "7z.exe"),
      file.path(Sys.getenv("ProgramW6432"), "7-Zip", "7z.exe"),
      "C:/Program Files/7-Zip/7z.exe",
      "C:/Program Files (x86)/7-Zip/7z.exe"
    )
    candidates <- candidates[nzchar(candidates)]
    hit <- candidates[file.exists(candidates)]
    if (length(hit)) return(hit[[1]])
  }
  ""
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
  seven_zip <- find_7zip()
  if (nzchar(seven_zip)) {
    system2(seven_zip, c("x", "-y", shQuote(archive), paste0("-o", shQuote(extract_dir))),
            stdout = FALSE, stderr = FALSE)
  } else {
    cli::cli_abort(c(
      "!" = "7-Zip ({.code 7z}) is required on the build machine to unpack R-Portable, but wasn't found.",
      "i" = "Install it ({.code apt-get install p7zip-full} on Linux, or {.url https://www.7-zip.org} on Windows).",
      "i" = "If it's already installed on Windows, its folder (e.g. {.path C:/Program Files/7-Zip}) just isn't on {.envvar PATH} - this build looks there automatically, so a standard install should be picked up; a non-standard install needs {.code 7z} on {.envvar PATH}."
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
#' Build the R expression to reinstall one package from its recorded remote
#'
#' Covers every git-forge / URL remote type `remotes` (and `pak`) record
#' in an installed package's `DESCRIPTION` `RemoteType`: `github`,
#' `gitlab`, `bitbucket`, a generic `git` URL, and a source-tarball
#' `url`. Returns `NULL` for anything else (`cran`/`standard`/`local`/
#' `bioc`, handled elsewhere). CRAN's `install.packages()` can't fetch
#' any of these, so `build_portable()` routes them through the matching
#' `remotes::install_*()` instead.
#' @param d A `packageDescription` (or a list with the same fields).
#' @param lib Forward-slashed library path to install into.
#' @keywords internal
#' @noRd
build_remote_install_expr <- function(d, lib) {
  rt <- tolower(d$RemoteType %||% "")
  ref <- d$RemoteRef %||% d$RemoteSha %||% ""
  atref <- if (nzchar(ref) && !identical(ref, "HEAD")) paste0("@", ref) else ""
  subdir <- if (!is.null(d$RemoteSubdir) && nzchar(d$RemoteSubdir)) paste0("/", d$RemoteSubdir) else ""
  slug <- paste0(d$RemoteUsername %||% "", "/", d$RemoteRepo %||% "", subdir, atref)
  switch(rt,
    github = sprintf('remotes::install_github("%s", lib = "%s", upgrade = "never")', slug, lib),
    gitlab = sprintf('remotes::install_gitlab("%s", host = "%s", lib = "%s", upgrade = "never")',
                     slug, d$RemoteHost %||% "gitlab.com", lib),
    bitbucket = sprintf('remotes::install_bitbucket("%s", lib = "%s", upgrade = "never")', slug, lib),
    git = sprintf('remotes::install_git("%s", ref = "%s", lib = "%s", upgrade = "never")',
                  d$RemoteUrl %||% "", if (nzchar(ref)) ref else "HEAD", lib),
    url = sprintf('remotes::install_url("%s", lib = "%s")', d$RemoteUrl %||% "", lib),
    NULL
  )
}

#' Reinstall expressions for any of `pkgs` installed from a git/URL remote
#' @return Named character vector: package -> `remotes::install_*()` expression.
#' @keywords internal
#' @noRd
remote_install_specs <- function(pkgs, lib) {
  lib <- gsub("\\\\", "/", as.character(lib))
  out <- character(0)
  for (p in pkgs) {
    d <- tryCatch(utils::packageDescription(p), error = function(e) NULL)
    if (!inherits(d, "packageDescription")) next
    e <- build_remote_install_expr(d, lib)
    if (!is.null(e)) out[[p]] <- e
  }
  out
}

#' Non-CRAN repo URLs recorded for any of `pkgs` (r-universe, Posit PM, ...)
#'
#' Packages installed from an r-universe or Posit Package Manager repo (or
#' any custom CRAN-like repo) record that repo's URL in their `DESCRIPTION`
#' `Repository` field rather than a `RemoteType`. Returning those URLs lets
#' the CRAN install pass add them to `repos`, so a package that lives only
#' there still resolves. (A plain-word `Repository` like `CRAN`/`RSPM` is
#' ignored - only real URLs are added.)
#' @keywords internal
#' @noRd
custom_repo_urls <- function(pkgs) {
  repos <- character(0)
  for (p in pkgs) {
    d <- tryCatch(utils::packageDescription(p), error = function(e) NULL)
    r <- if (inherits(d, "packageDescription")) d$Repository else NULL
    if (!is.null(r) && grepl("^https?://", r)) repos <- c(repos, sub("/+$", "", r))
  }
  unique(repos)
}

#' The git URL for a remote-installed package, for an r-universe registry
#'
#' Reconstructs the source git URL from a package's installed `DESCRIPTION`
#' `Remote*` fields, for the git-forge types r-universe can build from
#' (github/gitlab/bitbucket, or a generic `git` URL). `NULL` otherwise.
#' @keywords internal
#' @noRd
remote_git_url <- function(d) {
  rt <- tolower(d$RemoteType %||% "")
  host <- switch(rt,
    github = "github.com",
    gitlab = sub("/api/v[0-9]+$", "", d$RemoteHost %||% "gitlab.com"),
    bitbucket = "bitbucket.org",
    NULL
  )
  user <- d$RemoteUsername
  repo <- d$RemoteRepo
  if (!is.null(host) && !is.null(user) && !is.null(repo) && nzchar(user) && nzchar(repo)) {
    return(sprintf("https://%s/%s/%s", host, user, repo))
  }
  if (rt == "git" && !is.null(d$RemoteUrl) && nzchar(d$RemoteUrl)) return(d$RemoteUrl)
  NULL
}

#' Build an r-universe registry (`packages.json`) from an app's remotes
#'
#' Scans an app for the packages it uses (via [scan_r_package_deps()],
#' including commented-out `library()` calls, since shinylive reads those),
#' keeps the ones the build machine installed from a git forge
#' (GitHub/GitLab/Bitbucket/git), and returns the registry entries an
#' r-universe needs to build them - crucially their **WebAssembly** binaries,
#' which [build_wasm()] then bundles offline. This is the automated form of
#' hand-writing `packages.json`.
#'
#' @param app_dir Directory containing the Shiny app.
#' @return A list of `list(package=, url=, branch=?)` entries (possibly empty).
#' @seealso [write_runiverse_registry()]
#' @export
runiverse_registry <- function(app_dir) {
  direct <- scan_r_package_deps(app_dir, include_commented = TRUE)
  installed <- rownames(utils::installed.packages())
  entries <- list()
  for (p in intersect(direct, installed)) {
    d <- tryCatch(utils::packageDescription(p), error = function(e) NULL)
    if (!inherits(d, "packageDescription")) next
    url <- remote_git_url(d)
    if (is.null(url)) next
    entry <- list(package = p, url = url)
    ref <- d$RemoteRef
    if (!is.null(ref) && nzchar(ref) && !identical(ref, "HEAD")) entry$branch <- ref
    entries[[length(entries) + 1L]] <- entry
  }
  entries
}

#' Write an r-universe registry (`packages.json`) for an app's remote packages
#'
#' Writes the [runiverse_registry()] entries to a `packages.json` file - the
#' registry you commit to a repo named `universe` in your GitHub account to
#' have r-universe build (and wasm-compile) those packages, so [build_wasm()]
#' can bundle them offline. See the README "r-universe" setup.
#'
#' @param app_dir Directory containing the Shiny app.
#' @param path Output path for the registry JSON.
#' @return Invisibly, `path` (or an empty string if there was nothing to write).
#' @export
write_runiverse_registry <- function(app_dir, path = "packages.json") {
  entries <- runiverse_registry(app_dir)
  if (length(entries) == 0) {
    cli::cli_inform(c(
      "i" = "No GitHub/GitLab/Bitbucket-installed packages found in {.path {app_dir}} - nothing to add to an r-universe."
    ))
    return(invisible(""))
  }
  jsonlite::write_json(entries, path, auto_unbox = TRUE, pretty = TRUE)
  pkgs <- vapply(entries, function(e) e$package, character(1))
  cli::cli_inform(c(
    "v" = "Wrote {length(entries)} package{?s} to {.path {path}}: {.pkg {pkgs}}.",
    "i" = "Commit it as {.file packages.json} in a GitHub repo named {.val <your-username>.r-universe.dev}, then install the {.href https://github.com/apps/r-universe} app."
  ))
  invisible(path)
}

#' Check r-universe build status and/or wasm-bundle presence for an app's remotes
#'
#' Wraps the two verification steps of the r-universe path for [build_wasm()]:
#' (step 4) whether each of an app's git-forge packages is being served by your
#' r-universe yet, and (step 7) whether each one actually landed in a built wasm
#' bundle. Pass `universe`, `bundle`, or both.
#'
#' @param app_dir Directory containing the Shiny app.
#' @param universe Your r-universe URL, e.g. `"https://you.r-universe.dev"`.
#'   When given, checks each package is available there (i.e. r-universe has
#'   built it - the WebAssembly target is built alongside, so also confirm the
#'   Emscripten column on your universe dashboard).
#' @param bundle A built [build_wasm()] output directory; when given, checks
#'   each package's `.tgz` is present under `shinylive/webr/packages/`.
#' @return Invisibly, a data frame with `package`, `on_universe`, `in_bundle`
#'   (`NA` where not checked).
#' @seealso [runiverse_registry()], [write_runiverse_registry()]
#' @export
runiverse_status <- function(app_dir, universe = NULL, bundle = NULL) {
  entries <- runiverse_registry(app_dir)
  pkgs <- vapply(entries, function(e) e$package, character(1))
  if (length(pkgs) == 0) {
    cli::cli_inform("No GitHub/GitLab/Bitbucket-installed packages found in {.path {app_dir}}.")
    return(invisible(data.frame(package = character(0), on_universe = logical(0),
                                in_bundle = logical(0))))
  }

  on_universe <- rep(NA, length(pkgs))
  if (!is.null(universe)) {
    ap <- tryCatch(suppressWarnings(rownames(utils::available.packages(repos = universe))),
                   error = function(e) NULL)
    if (is.null(ap)) cli::cli_warn("Couldn't reach {.url {universe}}.") else on_universe <- pkgs %in% ap
  }

  in_bundle <- rep(NA, length(pkgs))
  if (!is.null(bundle)) {
    pdir <- fs::path(bundle, "shinylive", "webr", "packages")
    in_bundle <- vapply(pkgs, function(p) {
      dd <- fs::path(pdir, p)
      fs::dir_exists(dd) && length(fs::dir_ls(dd, glob = "*.tgz")) > 0
    }, logical(1))
  }

  mark <- function(x) ifelse(is.na(x), "-", ifelse(x, "yes", "NO"))
  for (i in seq_along(pkgs)) {
    cli::cli_inform("{.pkg {pkgs[i]}}: on universe = {mark(on_universe[i])}, in bundle = {mark(in_bundle[i])}")
  }
  invisible(data.frame(package = pkgs, on_universe = on_universe, in_bundle = in_bundle,
                       stringsAsFactors = FALSE))
}

#' Install git/URL-remote packages into the bundle via the bundle's Rscript
#'
#' Runs the per-package `remotes::install_*()` expressions from
#' [remote_install_specs()] (github, gitlab, bitbucket, git, url) with the
#' *bundled* R so the result matches R-Portable's version/ABI (the same
#' reason CRAN installs use the bundled Rscript). `remotes` is bootstrapped
#' into the bundle by copying the build machine's copy - it's pure R (no
#' compiled code), so it loads fine under the older R - falling back to a
#' binary install. The bundle library is put on `.libPaths()` so already-
#' installed CRAN dependencies are reused rather than refetched. A remote
#' package with *compiled* code will still fail here without Rtools in the
#' bundled R; that surfaces in the post-install missing-package check.
#' @param exprs Named character vector of install expressions.
#' @keywords internal
#' @noRd
install_remotes_into_bundle <- function(rscript, lib_dir, exprs) {
  if (length(exprs) == 0) return(invisible())
  if (!fs::dir_exists(fs::path(lib_dir, "remotes"))) {
    bm <- tryCatch(find.package("remotes"), error = function(e) NULL)
    if (!is.null(bm)) tryCatch(fs::dir_copy(bm, fs::path(lib_dir, "remotes")),
                               error = function(e) NULL)
  }
  lib <- gsub("\\\\", "/", as.character(fs::path_abs(lib_dir)))
  full <- sprintf(paste0(
    '.libPaths(c("%s", .libPaths())); options(download.file.method = "wininet"); ',
    'if (!requireNamespace("remotes", quietly = TRUE)) ',
    'install.packages("remotes", lib = "%s", repos = "https://cloud.r-project.org", type = "win.binary"); ',
    '%s'),
    lib, lib, paste(unname(exprs), collapse = "; ")
  )
  status <- system2(as.character(rscript), c("--vanilla", "-e", shQuote(full)))
  if (!identical(status, 0L)) {
    cli::cli_warn("Remote package install exited with status {status} - see output above.")
  }
  invisible()
}

#' Which of `pkgs` are Bioconductor packages
#'
#' Bioconductor packages declare a `biocViews` field in their
#' `DESCRIPTION` - the reliable marker. CRAN's `install.packages()`
#' can't fetch them, so `build_portable()` installs them from the
#' Bioconductor repos instead (see `install_bioc_into_bundle()`).
#' @keywords internal
#' @noRd
bioc_packages <- function(pkgs) {
  keep <- vapply(pkgs, function(p) {
    d <- tryCatch(utils::packageDescription(p), error = function(e) NULL)
    inherits(d, "packageDescription") && !is.null(d$biocViews) && nzchar(d$biocViews)
  }, logical(1))
  pkgs[keep]
}

#' Install Bioconductor packages into the bundle via the bundle's Rscript
#'
#' Like `install_github_into_bundle()`: runs with the *bundled* R so the
#' installed binaries match R-Portable's version/ABI. `BiocManager` is
#' bootstrapped by copying the build machine's copy (it's pure R), and
#' `BiocManager::repositories()` supplies the Bioconductor + CRAN repos
#' for the bundled R's Bioc release, so `type = "win.binary"` fetches
#' the matching Windows binaries (no Rtools needed - Bioconductor hosts
#' binaries for each release).
#' @keywords internal
#' @noRd
install_bioc_into_bundle <- function(rscript, lib_dir, pkgs) {
  if (!fs::dir_exists(fs::path(lib_dir, "BiocManager"))) {
    bm <- tryCatch(find.package("BiocManager"), error = function(e) NULL)
    if (!is.null(bm)) tryCatch(fs::dir_copy(bm, fs::path(lib_dir, "BiocManager")),
                               error = function(e) NULL)
  }
  lib <- gsub("\\\\", "/", as.character(fs::path_abs(lib_dir)))
  expr <- sprintf(paste0(
    '.libPaths(c("%s", .libPaths())); options(download.file.method = "wininet"); ',
    'if (!requireNamespace("BiocManager", quietly = TRUE)) ',
    'install.packages("BiocManager", lib = "%s", repos = "https://cloud.r-project.org", type = "win.binary"); ',
    'install.packages(c(%s), lib = "%s", repos = BiocManager::repositories(), type = "win.binary")'),
    lib, lib, paste(sprintf('"%s"', pkgs), collapse = ", "), lib
  )
  status <- system2(as.character(rscript), c("--vanilla", "-e", shQuote(expr)))
  if (!identical(status, 0L)) {
    cli::cli_warn("Bioconductor package install exited with status {status} - see output above.")
  }
  invisible()
}

#' Which required packages are missing from a bundle's library
#' @keywords internal
#' @noRd
missing_bundle_packages <- function(lib_dir, pkgs) {
  if (length(pkgs) == 0 || !fs::dir_exists(lib_dir)) return(pkgs)
  installed_ok <- fs::path_file(fs::dir_ls(lib_dir, type = "directory"))
  setdiff(pkgs, installed_ok)
}

#' Copy pure-R packages the repos couldn't provide from the build machine
#'
#' Last-resort fallback for packages no repo can install: ones the build
#' machine got from a **local source tarball**, or that are CRAN-archived
#' / source-only. Since the build machine already has them installed, a
#' pure-R package (no compiled code) can just be copied into the bundle -
#' pure-R code is R-version-independent, so the older bundled R loads it
#' fine (this is exactly why `install.packages(type = "win.binary")`
#' couldn't help but a copy can). Compiled packages are skipped - copying
#' a binary built for the build machine's R into the bundle's older R is
#' the ABI mismatch this package works hard to avoid; those are left for
#' the missing-package check to report.
#' @return The names actually copied.
#' @keywords internal
#' @noRd
copy_pure_r_packages <- function(lib_dir, pkgs) {
  copied <- character(0)
  for (p in pkgs) {
    if (fs::dir_exists(fs::path(lib_dir, p))) next
    src <- tryCatch(find.package(p), error = function(e) NULL)
    if (is.null(src)) next
    d <- tryCatch(utils::packageDescription(p), error = function(e) NULL)
    needs_comp <- inherits(d, "packageDescription") &&
      identical(tolower(d$NeedsCompilation %||% "no"), "yes")
    if (needs_comp || fs::dir_exists(fs::path(src, "libs"))) next # compiled: unsafe
    ok <- tryCatch({ fs::dir_copy(src, fs::path(lib_dir, p)); TRUE },
                   error = function(e) FALSE)
    if (ok) copied <- c(copied, p)
  }
  copied
}

#' @keywords internal
#' @noRd
install_packages_portable <- function(r_portable_dir, lib_dir, pkgs) {
  if (length(pkgs) == 0) return(invisible())
  rscript <- fs::path(r_portable_dir, "bin", "x64", "Rscript.exe")
  if (!fs::file_exists(rscript)) rscript <- fs::path(r_portable_dir, "bin", "Rscript.exe")

  # Split by how each package must be fetched (CRAN's install.packages() can't
  # get most of these):
  #  * git-forge / URL remotes (github/gitlab/bitbucket/git/url) -> remotes
  #  * Bioconductor (biocViews field)                            -> Bioc repos
  #  * everything else                                           -> CRAN, plus any
  #    custom repo (r-universe / Posit PM) recorded in a Repository field
  remote_exprs <- remote_install_specs(pkgs, lib_dir)
  non_remote <- setdiff(pkgs, names(remote_exprs))
  bioc <- bioc_packages(non_remote)
  cran_pkgs <- setdiff(non_remote, bioc)
  extra_repos <- custom_repo_urls(cran_pkgs)

  # system2()'s own `env` argument is unreliable on Windows (verified: it makes
  # even a trivial system2("cmd", ..., env = "FOO=bar") fail with status 5) -
  # clear R_LIBS* via Sys.setenv() and rely on ordinary child-process
  # environment inheritance instead, so the bundled R doesn't pick up the build
  # machine's (ABI-incompatible) user library.
  isolate_vars <- c("R_LIBS_USER", "R_LIBS_SITE", "R_LIBS")
  old_vals <- Sys.getenv(isolate_vars, unset = NA, names = TRUE)
  Sys.setenv(R_LIBS_USER = "", R_LIBS_SITE = "", R_LIBS = "")
  on.exit({
    to_restore <- old_vals[!is.na(old_vals)]
    if (length(to_restore) > 0) do.call(Sys.setenv, as.list(to_restore))
    Sys.unsetenv(names(old_vals)[is.na(old_vals)])
  }, add = TRUE)

  if (length(cran_pkgs) > 0) {
    cli::cli_inform("Installing {length(cran_pkgs)} CRAN package{?s} into the bundle's private library...")
    repos <- c("https://cloud.r-project.org", extra_repos)
    install_expr <- sprintf(
      'options(download.file.method = "wininet"); install.packages(c(%s), lib = %s, repos = c(%s), type = "win.binary")',
      paste(sprintf('"%s"', cran_pkgs), collapse = ", "),
      sprintf('"%s"', gsub("\\\\", "/", as.character(lib_dir))),
      paste(sprintf('"%s"', repos), collapse = ", ")
    )
    status <- system2(as.character(rscript), c("--vanilla", "-e", shQuote(install_expr)))
    if (!identical(status, 0L)) {
      cli::cli_warn("CRAN package installation exited with status {status} - check the bundle's library before shipping it.")
    }
  }

  if (length(bioc) > 0) {
    cli::cli_inform("Installing {length(bioc)} Bioconductor package{?s} into the bundle ({.pkg {bioc}})...")
    install_bioc_into_bundle(rscript, lib_dir, bioc)
  }

  if (length(remote_exprs) > 0) {
    cli::cli_inform("Installing {length(remote_exprs)} package{?s} from git/URL remotes ({.pkg {names(remote_exprs)}}) via {.pkg remotes}...")
    install_remotes_into_bundle(rscript, lib_dir, remote_exprs)
  }

  # Last resort for anything no repo could provide (local source tarballs,
  # CRAN-archived / source-only packages): copy the build machine's pure-R copy.
  copied <- copy_pure_r_packages(lib_dir, missing_bundle_packages(lib_dir, pkgs))
  if (length(copied) > 0) {
    cli::cli_inform("Copied {length(copied)} pure-R package{?s} the repositories couldn't provide from the build machine ({.pkg {copied}}).")
  }

  # Verify every requested package actually landed. A bundle that looks built
  # but is missing a package the app calls is a silently-broken offline bundle:
  # it ships fine, then crashes on the target with "there is no package called
  # '<name>'" and the console closes before anyone can read it. The usual
  # culprit is a GitHub-only / CRAN-archived package with no Windows binary
  # (install.packages(type = "win.binary") can't fetch it).
  missing <- missing_bundle_packages(lib_dir, pkgs)
  if (length(missing) > 0) {
    cli::cli_warn(c(
      "!" = "{length(missing)} required package{?s} did NOT install into the bundle: {.pkg {missing}}",
      "i" = "CRAN, Bioconductor, GitHub, and pure-R local packages are handled automatically - what's left is usually a {.emph compiled} package with no Windows binary, which would need Rtools in the bundled R. The app will otherwise crash on the target with {.emph there is no package called '<name>'}.",
      "i" = "Fix each: put a matching Windows build into {.path {lib_dir}} yourself, or drop it from the app."
    ))
  }
  invisible()
}

#' Write the run.bat launcher for a portable bundle
#' @keywords internal
#' @noRd
write_portable_launcher <- function(out_dir, port, env_lines = character()) {
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
    # Native-runtime env vars (JAVA_HOME, TESSDATA_PREFIX, ...) go here, before R
    # starts, so the app's packages find their bundled runtime.
    env_lines,
    '"%~dp0R-Portable\\bin\\x64\\Rscript.exe" --vanilla run_app.R',
    # Rscript blocks until the app closes; clean up any bundled server after.
    'if exist "%~dp0db-stop.bat" call "%~dp0db-stop.bat"'
  )
  writeLines(bat, fs::path(out_dir, "run.bat"))
  invisible(out_dir)
}

# --- Native-runtime provisioning ---------------------------------------------
#
# Some R packages are only a thin binding to a *native runtime that lives
# outside the R package itself* - the very thing that makes them impossible in
# wasm (see build_wasm) is what makes them a portable-only problem here. The
# CRAN Windows binary carries the compiled glue + any bundled DLLs, but not that
# external runtime, so an offline bundle has to stage it in and wire it up in
# run.bat. Four classes, one mechanism:
#
#   class            example      external runtime            wired via
#   ---------------  -----------  --------------------------  ----------------
#   JVM              rJava        a portable JRE              JAVA_HOME + PATH
#   data files       tesseract    OCR language .traineddata   TESSDATA_PREFIX
#   server process   RMariaDB     a running DB server         start/stop in .bat
#   compiler         rstan/brms   a C++ toolchain (Rtools)    PATH + BINPREF
#
# A provider is `function(out_dir, cache_dir, opts)` that stages its runtime
# into `out_dir` (downloading at build time - the build machine has internet,
# the target doesn't) and returns the run.bat lines that point the app at it.

#' Native-runtime providers for [build_portable()]
#'
#' The registry mapping trigger packages to the provider that stages their
#' external native runtime into a portable bundle. Exported so the set is
#' discoverable/auditable; you don't normally call these directly - pass
#' `native_runtime = ...` to [build_portable()] instead.
#'
#' @return Named list of providers, each `list(pkgs = <character>, provision
#'   = <function(out_dir, cache_dir, opts)>)`.
#' @export
native_runtime_providers <- function() {
  list(
    java      = list(pkgs = "rJava",                        provision = provision_jre),
    tesseract = list(pkgs = "tesseract",                    provision = provision_tessdata),
    mariadb   = list(pkgs = c("RMariaDB", "RMySQL"),        provision = provision_mariadb),
    toolchain = list(pkgs = c("rstan", "brms", "cmdstanr"), provision = provision_toolchain)
  )
}

# Run every provider triggered by the bundle's package set; return the run.bat
# lines they contribute (in registry order, so env vars are set before R starts).
provision_native_runtimes <- function(pkgs, out_dir, cache_dir, native_runtime = list()) {
  providers <- native_runtime_providers()
  unknown <- setdiff(names(native_runtime), names(providers))
  if (length(unknown)) {
    cli::cli_warn("Ignoring unknown {.arg native_runtime} entr{cli::qty(unknown)}{?y/ies}: {.val {unknown}} (known: {.val {names(providers)}}).")
  }
  lines <- character(0)
  for (nm in names(providers)) {
    p <- providers[[nm]]
    hit <- intersect(p$pkgs, pkgs)
    if (!length(hit)) next
    opts <- native_runtime[[nm]] %||% list()
    if (isFALSE(opts$enabled)) {
      cli::cli_inform(c("!" = "Native runtime {.val {nm}} is needed by {.pkg {hit}} but disabled ({.code native_runtime${nm}$enabled = FALSE}) - the bundle may not run offline."))
      next
    }
    cli::cli_inform("Provisioning native runtime {.val {nm}} (for {.pkg {hit}})...")
    lines <- c(lines, p$provision(out_dir, cache_dir, opts))
  }
  lines
}

# Unzip with utils::unzip, falling back to 7-Zip (utils::unzip chokes on some
# large/awkward archives; 7-Zip - already required for R-Portable - handles them).
unzip_archive <- function(zip, exdir) {
  fs::dir_create(exdir)
  ok <- tryCatch({ utils::unzip(zip, exdir = exdir); TRUE },
                 warning = function(w) FALSE, error = function(e) FALSE)
  if (!ok || length(fs::dir_ls(exdir)) == 0) {
    z <- find_7zip()
    system2(z, c("x", "-y", sprintf("-o%s", exdir), zip), stdout = FALSE, stderr = FALSE)
  }
  invisible(exdir)
}

#' @keywords internal
#' @noRd
provision_jre <- function(out_dir, cache_dir, opts = list()) {
  ver <- opts$version %||% "21"
  dest <- fs::path(out_dir, "runtime", "jre")
  if (!fs::dir_exists(dest)) {
    # Temurin (Eclipse Adoptium) JRE: GPLv2 + Classpath Exception, freely
    # redistributable. The API URL 302-redirects to the current build's zip.
    url <- sprintf(
      "https://api.adoptium.net/v3/binary/latest/%s/ga/windows/x64/jre/hotspot/normal/eclipse",
      ver)
    fs::dir_create(cache_dir)
    zip <- fs::path(cache_dir, sprintf("temurin-jre-%s-win-x64.zip", ver))
    if (!fs::file_exists(zip)) {
      cli::cli_inform("Downloading Temurin JRE {ver} (Windows x64, ~45MB)...")
      utils::download.file(url, zip, mode = "wb", quiet = TRUE)
    }
    tmp <- fs::path(cache_dir, sprintf("jre-%s-unz", ver))
    if (fs::dir_exists(tmp)) fs::dir_delete(tmp)
    unzip_archive(zip, tmp)
    # The zip has one top-level jdk-<ver>-jre/ dir; flatten it into runtime/jre.
    top <- fs::dir_ls(tmp, type = "directory")
    fs::dir_create(fs::path_dir(dest))
    fs::dir_copy(top[[1]], dest)
    fs::dir_delete(tmp)
  }
  # jvm.dll lives in bin\server for a JRE; rJava finds it via JAVA_HOME + PATH.
  c('set "JAVA_HOME=%~dp0runtime\\jre"',
    'set "PATH=%JAVA_HOME%\\bin;%JAVA_HOME%\\bin\\server;%PATH%"')
}

#' @keywords internal
#' @noRd
provision_tessdata <- function(out_dir, cache_dir, opts = list()) {
  langs <- opts$langs %||% "eng"
  dest <- fs::path(out_dir, "tessdata")
  fs::dir_create(dest)
  for (lang in langs) {
    f <- fs::path(dest, paste0(lang, ".traineddata"))
    if (fs::file_exists(f)) next
    # tessdata_fast is the smaller LSTM model set; good enough for most apps.
    url <- sprintf("https://github.com/tesseract-ocr/tessdata_fast/raw/main/%s.traineddata", lang)
    cli::cli_inform("Downloading tesseract training data {.val {lang}} (~15MB)...")
    utils::download.file(url, f, mode = "wb", quiet = TRUE)
  }
  # libtesseract reads TESSDATA_PREFIX; point it at the folder holding the data.
  'set "TESSDATA_PREFIX=%~dp0tessdata"'
}

#' @keywords internal
#' @noRd
provision_mariadb <- function(out_dir, cache_dir, opts = list()) {
  if (!isTRUE(opts$server)) {
    # The CRAN Windows binary of RMariaDB statically bundles the MariaDB
    # Connector/C, so the *client* already works fully offline. What it needs is
    # a reachable server - by default assume an existing/remote one, stage
    # nothing. Opt into a bundled server with native_runtime = list(mariadb =
    # list(server = TRUE)).
    cli::cli_inform(c("i" = "{.pkg RMariaDB} client is self-contained and works offline against an existing server; nothing to bundle. Set {.code native_runtime = list(mariadb = list(server = TRUE))} to also bundle a portable server."))
    return(character(0))
  }
  # Verified end-to-end on a real Windows machine: datadir bootstrap ->
  # mysqld up on 127.0.0.1:<port> (loopback only, no firewall prompt) ->
  # RMariaDB client round-trip (DDL/DML/query) -> graceful InnoDB shutdown
  # via db-stop.bat. Kept behind the explicit opt-in because bundling a
  # ~150MB server should never be a silent surprise.
  cli::cli_inform(c("i" = "Bundling a portable MariaDB server (~150MB), started on 127.0.0.1:{opts$port %||% 3307} by {.file run.bat} and shut down when the app closes."))
  port <- opts$port %||% 3307
  url <- opts$url %||% "https://archive.mariadb.org/mariadb-11.4.4/winx64-packages/mariadb-11.4.4-winx64.zip"
  dest <- fs::path(out_dir, "runtime", "mariadb")
  if (!fs::dir_exists(dest)) {
    fs::dir_create(cache_dir)
    zip <- fs::path(cache_dir, "mariadb-winx64.zip")
    if (!fs::file_exists(zip)) {
      cli::cli_inform("Downloading portable MariaDB server (~150MB)...")
      utils::download.file(url, zip, mode = "wb", quiet = TRUE)
    }
    tmp <- fs::path(cache_dir, "mariadb-unz")
    if (fs::dir_exists(tmp)) fs::dir_delete(tmp)
    unzip_archive(zip, tmp)
    top <- fs::dir_ls(tmp, type = "directory")
    fs::dir_create(fs::path_dir(dest))
    fs::dir_copy(top[[1]], dest)
    fs::dir_delete(tmp)
  }
  # Init datadir + start/stop scripts. --skip-grant-tables = zero-auth local DB;
  # bound to 127.0.0.1 only (no firewall prompt, no network exposure).
  writeLines(c(
    "@echo off",
    "cd /d %~dp0",
    'if not exist "data\\mysql" (',
    '  "runtime\\mariadb\\bin\\mariadb-install-db.exe" --datadir="%~dp0data"',
    ')',
    sprintf('start "" /b "runtime\\mariadb\\bin\\mysqld.exe" --datadir="%%~dp0data" --port=%d --bind-address=127.0.0.1 --skip-grant-tables', port)
  ), fs::path(out_dir, "db-start.bat"))
  writeLines(c(
    "@echo off",
    "cd /d %~dp0",
    # Graceful shutdown of *our* server (by port), so we don't clobber another
    # mysqld the target might be running and the datadir flushes cleanly.
    sprintf('"runtime\\mariadb\\bin\\mariadb-admin.exe" --host=127.0.0.1 --port=%d -u root shutdown 2>nul', port),
    "if not errorlevel 1 goto :eof",
    "rem last resort only if mariadb-admin is unavailable/refused:",
    'taskkill /f /im mysqld.exe >nul 2>&1'
  ), fs::path(out_dir, "db-stop.bat"))
  # run.bat starts the DB before R; write_portable_launcher's trailing
  # `if exist db-stop.bat` stops it after the app closes.
  c('call "%~dp0db-start.bat"',
    sprintf('rem MariaDB on 127.0.0.1:%d - app connects via RMariaDB (skip-grant-tables, no password)', port))
}

#' @keywords internal
#' @noRd
provision_toolchain <- function(out_dir, cache_dir, opts = list()) {
  if (!isTRUE(opts$rtools)) {
    # rstan/brms *generate and compile C++ at runtime*, so a fixed-model app is
    # far better served by precompiling on the build machine (no toolchain on
    # target). Only bundle Rtools if end-users author new models at runtime.
    cli::cli_inform(c(
      "i" = "{.pkg rstan}/{.pkg brms} compile C++ at runtime. Preferred: precompile your models at build time (compile once here, ship the objects - no toolchain on target). See {.file docs/ARCHITECTURE.md}.",
      "i" = "To let the target compile {.emph new} models offline, bundle Rtools: {.code native_runtime = list(toolchain = list(rtools = TRUE))}."))
    return(character(0))
  }
  # CEILING: generated, not verified end-to-end. Rtools is large (~500MB) and
  # must match the bundled R's toolchain (Rtools44 for R 4.4/4.5/4.6). Upgrade
  # path: from the finished bundle offline, compile a trivial Stan model and
  # confirm it builds, then drop this warning.
  cli::cli_warn(c("!" = "Bundling Rtools: this path is generated but not yet verified end-to-end. Test a compile from the bundle before relying on it."))
  ver <- opts$rtools_version %||% "44"
  dest <- fs::path(out_dir, "runtime", "rtools")
  if (!fs::dir_exists(dest)) {
    fs::dir_create(cache_dir)
    exe <- fs::path(cache_dir, sprintf("rtools%s-installer.exe", ver))
    url <- opts$url %||% sprintf("https://cran.r-project.org/bin/windows/Rtools/rtools%s/files/rtools%s-x86_64.exe", ver, ver)
    if (!fs::file_exists(exe)) {
      cli::cli_inform("Downloading Rtools{ver} (~500MB)...")
      utils::download.file(url, exe, mode = "wb", quiet = TRUE)
    }
    # Rtools ships as an Inno Setup installer; /VERYSILENT /DIR= extracts it to a
    # user dir with no admin rights.
    fs::dir_create(dest)
    system2(exe, c("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART",
                   sprintf('/DIR=%s', dest)), stdout = FALSE, stderr = FALSE)
  }
  c('set "PATH=%~dp0runtime\\rtools\\usr\\bin;%~dp0runtime\\rtools\\x86_64-w64-mingw32.static.posix\\bin;%PATH%"',
    'set "BINPREF=%~dp0runtime/rtools/x86_64-w64-mingw32.static.posix/bin/"')
}
