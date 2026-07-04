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
#' @param check_deps If `TRUE` (default), run [check_wasm_packages()]
#'   first and abort with a clear, actionable list if the app depends on
#'   packages that can't run in a WebAssembly bundle (no webR binary, or
#'   installed from GitHub) - instead of letting `shinylive::export()`
#'   fail cryptically partway through. Set `FALSE` to skip the check.
#' @param ... Passed through to `shinylive::export()`.
#' @return Invisibly, the build manifest (also written as
#'   `manifest.json` inside `out_dir`).
#' @export
build_wasm <- function(app_dir, out_dir = "dist/wasm", serve_launcher = TRUE,
                       check_deps = TRUE, ...) {
  check_app_dir(app_dir)
  rlang::check_installed("shinylive", reason = "to build the wasm target")
  if (isTRUE(check_deps)) assert_wasm_compatible(app_dir)

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
#' PowerShell's `System.Net.HttpListener` on Windows, or the browser
#' itself via file://), so we shell out to whatever is found first
#' instead of shipping more bytes. Verified on a real Windows machine
#' with no Python installed: opening `index.html` straight off
#' `file://` is not a working fallback (browsers block the shinylive
#' service worker under `file://` with a CORS error, leaving a blank
#' page with no visible error) - `serve.ps1` exists to give Windows a
#' second real fallback before resorting to that, since PowerShell
#' ships with every supported Windows version.
#' @keywords internal
#' @noRd
write_serve_launchers <- function(out_dir, port = 8973) {
  bat <- c(
    "@echo off",
    "cd /d %~dp0",
    sprintf(
      paste0(
        "where python >nul 2>nul && (python -m http.server %d) || ",
        "(where powershell >nul 2>nul && (powershell -NoProfile -ExecutionPolicy Bypass -File \"%%~dp0serve.ps1\" -Port %d) || ",
        "(echo No local Python or PowerShell found - opening index.html directly instead, which will likely show a blank page ",
        "^(browsers block the WASM service worker under file:// with a CORS error^). & start index.html))"
      ),
      port, port
    )
  )
  sh <- c(
    "#!/bin/sh",
    "cd \"$(dirname \"$0\")\"",
    sprintf(
      "command -v python3 >/dev/null 2>&1 && exec python3 -m http.server %d || { echo 'No local python3 found - opening index.html directly instead, which will likely show a blank page (browsers block the WASM service worker under file:// with a CORS error).'; xdg-open index.html 2>/dev/null || open index.html 2>/dev/null; }",
      port
    )
  )
  fs::path(out_dir, "run.bat") |> writeLines(text = bat)
  sh_path <- fs::path(out_dir, "run.sh")
  writeLines(sh, sh_path)
  fs::file_chmod(sh_path, "755")
  writeLines(serve_ps1_lines(port), fs::path(out_dir, "serve.ps1"))
  invisible(out_dir)
}

#' PowerShell static file server used as `run.bat`'s second fallback
#'
#' Plain `System.Net.HttpListener` on `http://localhost:<port>/`, which
#' (unlike `http://+:<port>/`) does not require admin rights or a
#' `netsh` URL-ACL reservation - confirmed on a real, non-elevated
#' Windows session. Minimal MIME map covers what a shinylive bundle
#' actually serves (`.wasm` matters most: browsers refuse to
#' instantiate WebAssembly served as the default
#' `application/octet-stream` in some configurations).
#' @keywords internal
#' @noRd
serve_ps1_lines <- function(port) {
  c(
    sprintf("param([int]$Port = %d)", port),
    "$root = $PSScriptRoot",
    "$prefix = \"http://localhost:$Port/\"",
    "$listener = New-Object System.Net.HttpListener",
    "$listener.Prefixes.Add($prefix)",
    "try { $listener.Start() } catch { Write-Error \"Could not start local server on $prefix : $_\"; exit 1 }",
    "Write-Host \"Serving $root at $prefix (close this window to stop)\"",
    "Start-Process $prefix",
    "$mime = @{",
    "  '.html'='text/html'; '.htm'='text/html'; '.js'='text/javascript'; '.mjs'='text/javascript'",
    "  '.css'='text/css'; '.json'='application/json'; '.wasm'='application/wasm'",
    "  '.data'='application/octet-stream'; '.png'='image/png'; '.jpg'='image/jpeg'",
    "  '.svg'='image/svg+xml'; '.ico'='image/x-icon'; '.woff'='font/woff'; '.woff2'='font/woff2'",
    "  '.txt'='text/plain'; '.map'='application/json'",
    "}",
    "while ($listener.IsListening) {",
    "  $context = $listener.GetContext()",
    "  $request = $context.Request",
    "  $response = $context.Response",
    "  $localPath = [Uri]::UnescapeDataString($request.Url.AbsolutePath)",
    "  if ($localPath -eq '/' -or $localPath -eq '') { $localPath = '/index.html' }",
    "  if ($localPath -match '\\.\\.') { $response.StatusCode = 400; $response.OutputStream.Close(); continue }",
    "  $filePath = Join-Path $root ($localPath.TrimStart('/'))",
    "  if (Test-Path $filePath -PathType Leaf) {",
    "    $ext = [System.IO.Path]::GetExtension($filePath).ToLower()",
    "    $contentType = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'application/octet-stream' }",
    "    $bytes = [System.IO.File]::ReadAllBytes($filePath)",
    "    $response.ContentType = $contentType",
    "    $response.ContentLength64 = $bytes.Length",
    "    $response.OutputStream.Write($bytes, 0, $bytes.Length)",
    "  } else {",
    "    $response.StatusCode = 404",
    "  }",
    "  $response.OutputStream.Close()",
    "}"
  )
}

#' Check an app's package dependencies for WebAssembly compatibility
#'
#' A pre-flight for [build_wasm()]. It statically detects the packages an
#' app uses (via [scan_r_package_deps()]), expands their recursive
#' dependency tree, and checks each against the webR package repository
#' (`repo.r-wasm.org`), flagging two things that otherwise only surface
#' as a confusing failure partway through `shinylive::export()`:
#'
#' * **No WebAssembly build** - packages (or their dependencies) with no
#'   binary in the webR repo at all. These cannot run in a browser-only
#'   bundle and must be removed or swapped for a wasm-available
#'   alternative. Transitive blockers are reported with the direct
#'   dependency that pulls them in (e.g. `websocket (via webshot2)`).
#' * **Installed from GitHub** - packages whose local install metadata
#'   points at a GitHub repo. `shinylive` will try to fetch a matching
#'   GitHub *release* for them and fail if none exists (the common
#'   `get_github_wasm_assets()` 404). If such a package is *also* in the
#'   webR repo, reinstalling it from CRAN (or clearing its
#'   `Remote*`/`Github*` `DESCRIPTION` fields) is enough; if not, it has
#'   to go.
#'
#' Availability is checked against several recent R minor-version shelves
#' and unioned, so it stays correct as webR's bundled R version moves.
#' The check is fail-soft: if the webR repo can't be reached it warns and
#' returns rather than blocking a build.
#'
#' @param app_dir Directory containing the Shiny app.
#' @param r_versions webR repo R-version shelves to check (unioned).
#' @return Invisibly, a list: `no_wasm_build`, `from_github`,
#'   `github_but_wasm_available` (character vectors), `pulled_by` (named
#'   vector mapping each blocker to the direct dep that pulls it, or `""`
#'   if it is itself a direct dep), and `checked` (`FALSE` if the repo
#'   was unreachable).
#' @export
check_wasm_packages <- function(app_dir, r_versions = c("4.6", "4.5", "4.4")) {
  # include_commented = TRUE: shinylive reads commented-out library() calls and
  # tries to fetch them, so the pre-flight must see them too or it gives false
  # confidence (passes, then shinylive::export() fails on the commented package).
  direct <- scan_r_package_deps(app_dir, include_commented = TRUE)
  empty <- list(no_wasm_build = character(0), from_github = character(0),
                github_but_wasm_available = character(0),
                pulled_by = character(0), checked = TRUE)
  if (length(direct) == 0) return(invisible(empty))

  ip <- utils::installed.packages()
  installed <- rownames(ip)
  which_deps <- c("Depends", "Imports", "LinkingTo")
  rec <- tools::package_dependencies(intersect(direct, installed), db = ip,
                                     recursive = TRUE, which = which_deps)
  all_deps <- sort(unique(c(direct, unlist(rec, use.names = FALSE))))
  base_rec <- rownames(utils::installed.packages(priority = c("base", "recommended")))
  candidates <- setdiff(all_deps, base_rec)

  wasm <- character(0)
  reached <- FALSE
  for (rv in r_versions) {
    ap <- tryCatch(
      suppressWarnings(rownames(utils::available.packages(
        contriburl = sprintf("https://repo.r-wasm.org/bin/emscripten/contrib/%s", rv)))),
      error = function(e) NULL
    )
    if (length(ap)) { wasm <- union(wasm, ap); reached <- TRUE }
  }
  if (!reached) {
    cli::cli_warn(c(
      "!" = "Couldn't reach the webR package repo to check wasm compatibility - skipping the pre-flight check.",
      "i" = "The build will still run; a genuinely incompatible package would surface as an error during export."
    ))
    empty$checked <- FALSE
    return(invisible(empty))
  }

  # Only flag packages that are actually installed: a scanned `pkg::` token
  # that resolves to no installed package is almost always a false match
  # (a C++ namespace, an example in a comment, ...), and aborting a build on
  # one of those is worse than missing a genuinely-absent package (which
  # shinylive::export() would still surface).
  no_wasm <- sort(setdiff(intersect(candidates, installed), wasm))

  # Map each transitive blocker back to the direct dep(s) that pull it in,
  # so the advice is "remove webshot2", not "remove websocket".
  pulled_by <- vapply(no_wasm, function(p) {
    if (p %in% direct) return("")
    pull <- Filter(function(d) {
      dd <- tryCatch(tools::package_dependencies(d, db = ip, recursive = TRUE,
                                                 which = which_deps)[[1]],
                     error = function(e) character(0))
      p %in% dd
    }, intersect(direct, installed))
    paste(unlist(pull), collapse = ", ")
  }, character(1))

  # GitHub provenance only matters for directly-installed packages
  # (transitive deps of CRAN packages are themselves on CRAN).
  from_github <- Filter(function(p) {
    d <- tryCatch(utils::packageDescription(p), error = function(e) NULL)
    rt <- if (inherits(d, "packageDescription")) d$RemoteType else NULL
    !is.null(rt) && grepl("github", rt, ignore.case = TRUE)
  }, intersect(direct, installed))
  from_github <- sort(unlist(from_github))

  invisible(list(
    no_wasm_build = no_wasm,
    from_github = from_github,
    github_but_wasm_available = sort(intersect(from_github, wasm)),
    pulled_by = pulled_by,
    checked = TRUE
  ))
}

#' Abort a wasm build with a clear list if any dependency is incompatible
#' @keywords internal
#' @noRd
assert_wasm_compatible <- function(app_dir) {
  res <- check_wasm_packages(app_dir)
  if (!isTRUE(res$checked)) return(invisible())

  hard <- res$no_wasm_build
  fixable <- res$github_but_wasm_available
  if (length(hard) == 0 && length(fixable) == 0) return(invisible())

  hard_lab <- vapply(hard, function(p) {
    via <- res$pulled_by[[p]]
    if (!is.null(via) && nzchar(via)) sprintf("%s (via %s)", p, via) else p
  }, character(1))

  msg <- c("x" = "{.fn build_wasm}: this app depends on packages that can't run in a WebAssembly bundle.")
  if (length(hard)) {
    msg <- c(msg,
      "!" = "No webR/WebAssembly build (remove or replace): {.pkg {hard_lab}}",
      "i" = "webR runs pre-compiled WebAssembly, not R source, so installing from a remote (as {.fn build_portable} can) won't help here. To include one of these you'd have to build a wasm binary for it - see the {.pkg rwasm} package ({.url https://github.com/r-wasm/rwasm}), which needs a wasm/Emscripten toolchain.")
  }
  if (length(fixable)) {
    msg <- c(msg,
      "!" = "Installed from GitHub (shinylive looks for a usually-missing GitHub release): {.pkg {fixable}}",
      "i" = "These do have a webR binary - reinstall from CRAN, or clear their {.field Remote*}/{.field Github*} {.file DESCRIPTION} fields.")
  }
  msg <- c(msg,
    "i" = "A commented-out {.code library(pkg)} still counts - shinylive's scanner reads it. Delete the line to drop the package.",
    "i" = "Fix the above, or call {.code build_wasm(check_deps = FALSE)} to skip this check.")
  cli::cli_abort(msg)
}
