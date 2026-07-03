#' Add an opportunistic "update available" banner to a built bundle
#'
#' Injects a small vanilla-JS snippet into a [build_wasm()] bundle's
#' `index.html` that, on page load, tries a single short-timeout fetch
#' to `version_url`. If that succeeds and reports a newer build than
#' this bundle's own `manifest.json`, a small dismissible banner is
#' shown. If the machine is offline, or `version_url` is unreachable,
#' or the request errors for any reason, the check fails **silently**
#' - no banner, no console noise, no delay to app startup. This is
#' opt-in and deliberately dumb: it never auto-updates anything, it
#' only tells whoever's looking at the screen that a newer copy
#' exists somewhere reachable.
#'
#' Must be called *after* the target bundle has been built (so its
#' `manifest.json` and `index.html` already exist).
#'
#' @param bundle_dir Path to a bundle directory previously produced by
#'   [build_wasm()] (must contain `index.html` and `manifest.json`).
#' @param version_url URL of a small JSON endpoint your team controls
#'   that returns `{"build_sha": "...", "package_version": "..."}"`
#'   for the latest build. Never called at build time - only from the
#'   deployed app itself, and only if that machine happens to have a
#'   route to it.
#' @param timeout_ms How long the banner check waits before giving up
#'   silently. Default 1500ms - short enough that a fully offline
#'   machine never notices a delay.
#' @return Invisibly, `bundle_dir`.
#' @export
enable_update_check <- function(bundle_dir, version_url, timeout_ms = 1500) {
  manifest_path <- fs::path(bundle_dir, "manifest.json")
  index_path <- fs::path(bundle_dir, "index.html")
  if (!fs::file_exists(manifest_path)) {
    cli::cli_abort("{.path {manifest_path}} not found - run a build_*() target on this directory first.")
  }
  if (!fs::file_exists(index_path)) {
    cli::cli_abort(c(
      "!" = "{.path {index_path}} not found.",
      "i" = "{.fn enable_update_check} currently only supports {.fn build_wasm} bundles."
    ))
  }

  manifest <- jsonlite::read_json(manifest_path)
  js_path <- fs::path(bundle_dir, "shinyalcatraz-update-check.js")
  writeLines(
    update_check_js(
      version_url = version_url,
      current_build_sha = manifest$build_sha %||% "unknown",
      current_package_version = manifest$package_version %||% "unknown",
      timeout_ms = timeout_ms
    ),
    js_path
  )

  html <- readLines(index_path, warn = FALSE)
  tag <- '<script src="shinyalcatraz-update-check.js" defer></script>'
  if (!any(grepl(tag, html, fixed = TRUE))) {
    body_close <- grep("</body>", html, ignore.case = TRUE)
    if (length(body_close) == 0) {
      cli::cli_abort("Could not find a {.code </body>} tag in {.path {index_path}} to inject the update-check script before.")
    }
    insert_at <- body_close[length(body_close)]
    html <- append(html, tag, after = insert_at - 1)
    writeLines(html, index_path)
  }

  manifest$update_check <- list(enabled = TRUE, version_url = version_url)
  jsonlite::write_json(manifest, manifest_path, auto_unbox = TRUE, pretty = TRUE)

  cli::cli_inform(c("v" = "Update check enabled - polls {.url {version_url}} (fails silently if unreachable)."))
  invisible(bundle_dir)
}

#' @keywords internal
#' @noRd
update_check_js <- function(version_url, current_build_sha, current_package_version, timeout_ms) {
  sprintf('(function () {
  "use strict";
  var VERSION_URL = %s;
  var CURRENT_BUILD_SHA = %s;
  var TIMEOUT_MS = %d;

  function showBanner(remote) {
    var el = document.createElement("div");
    el.textContent = "A newer version of this app is available (" +
      (remote.package_version || "?") + "). Ask your team for the latest copy.";
    el.setAttribute("style",
      "position:fixed;bottom:0;left:0;right:0;z-index:2147483647;" +
      "background:#333;color:#fff;padding:8px 12px;font:13px sans-serif;" +
      "display:flex;align-items:center;justify-content:space-between;");
    var dismiss = document.createElement("button");
    dismiss.textContent = "Dismiss";
    dismiss.setAttribute("style",
      "margin-left:12px;background:transparent;color:#fff;border:1px solid #fff;" +
      "border-radius:3px;padding:2px 8px;cursor:pointer;");
    dismiss.onclick = function () { el.remove(); };
    el.appendChild(dismiss);
    document.body.appendChild(el);
  }

  // Deliberately silent on any failure: no network, blocked host, CORS
  // denial, timeout, or malformed response should ever surface to the
  // user or the console on an offline machine - that is the whole point.
  try {
    var controller = new AbortController();
    var timer = setTimeout(function () { controller.abort(); }, TIMEOUT_MS);
    fetch(VERSION_URL, { signal: controller.signal, cache: "no-store" })
      .then(function (res) { return res.ok ? res.json() : null; })
      .then(function (remote) {
        clearTimeout(timer);
        if (remote && remote.build_sha && remote.build_sha !== CURRENT_BUILD_SHA) {
          showBanner(remote);
        }
      })
      .catch(function () { /* offline or blocked - do nothing */ });
  } catch (e) { /* fetch/AbortController unsupported - do nothing */ }
})();
', jsonlite::toJSON(version_url), jsonlite::toJSON(current_build_sha), as.integer(timeout_ms))
}
