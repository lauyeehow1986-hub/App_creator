#' Build the native shell (Tauri) target (planned, not yet implemented)
#'
#' Wraps a [build_wasm()] or [build_portable()] bundle in a native
#' Tauri shell so the app launches as a real double-click desktop app
#' (or, via Tauri 2 mobile targets, an installable Android/iOS app)
#' instead of "open this HTML file in a browser". Tauri uses the OS's
#' built-in webview (WebView2 on Windows, WKWebView on
#' macOS/iOS, WebKitGTK on Linux, the system webview on Android)
#' rather than bundling a browser engine, which is what keeps the
#' shell itself small (single-digit MB) regardless of payload size.
#'
#' # Planned implementation
#' 1. Generate a minimal Tauri project (`src-tauri/`) around the
#'    chosen `backend` bundle's output directory as Tauri's static
#'    asset root.
#' 2. `backend = "wasm"`: no sidecar process needed, Tauri serves the
#'    shinylive bundle straight from its asset protocol (also sidesteps
#'    the `file://` CORS/MIME issues [build_wasm()]'s launcher scripts
#'    work around).
#' 3. `backend = "portable"`: ship the portable-R runtime as a Tauri
#'    *sidecar* binary, launched by Tauri on startup, with the webview
#'    pointed at the sidecar's local `httpuv` port.
#' 4. Cross-compile per `platform` using `tauri build --target`;
#'    Windows build requires no admin rights to *run* the output (a
#'    portable `.exe`), but on machines lacking WebView2 the "Fixed
#'    Version" WebView2 runtime must be bundled alongside (~150MB) since
#'    the evergreen bootstrapper needs admin rights to install.
#' 5. Android/iOS builds go through `tauri android`/`tauri ios`,
#'    producing an `.apk`/`.ipa` for sideloading or internal
#'    distribution — still no third-party admin/store dependency.
#'
#' @inheritParams build
#' @param backend One of `"wasm"` (default) or `"portable"`; which
#'   target this shell wraps.
#' @param platform One or more of `"windows"`, `"macos"`, `"linux"`,
#'   `"android"`, `"ios"`.
#' @param out_dir Directory to write the native shell project/output into.
#' @param ... Reserved for future options.
#' @return Never returns normally yet; see Details.
#' @export
build_tauri <- function(app_dir, out_dir = "dist/tauri",
                         backend = c("wasm", "portable"),
                         platform = c("windows", "macos", "linux", "android", "ios"),
                         ...) {
  check_app_dir(app_dir)
  backend <- rlang::arg_match(backend)
  platform <- rlang::arg_match(platform, multiple = TRUE)
  cli::cli_abort(c(
    "!" = "{.fn build_tauri} is planned but not yet implemented.",
    "i" = "Use {.fn build_wasm} today, or track progress in {.file docs/ARCHITECTURE.md}."
  ))
}
