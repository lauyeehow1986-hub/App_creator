demo_app <- system.file("examples", "demo-app", package = "shinyalcatraz")

test_that("check_app_dir rejects a non-existent directory", {
  expect_error(check_app_dir(fs::path_temp("does-not-exist")), class = "rlang_error")
})

test_that("check_app_dir rejects a directory with no app.R/ui.R+server.R", {
  empty_dir <- fs::path_temp("shinyalcatraz-empty-dir")
  fs::dir_create(empty_dir)
  on.exit(fs::dir_delete(empty_dir))
  expect_error(check_app_dir(empty_dir))
})

test_that("check_app_dir accepts the bundled demo app", {
  skip_if(demo_app == "", "demo app not installed")
  expect_invisible(check_app_dir(demo_app))
})

test_that("match_targets rejects unknown targets", {
  expect_error(match_targets("carrier_pigeon"))
})

test_that("match_targets deduplicates and preserves valid targets", {
  expect_identical(match_targets(c("wasm", "wasm", "tauri")), c("wasm", "tauri"))
})

test_that("build_portable is honest about macOS/Linux being unimplemented", {
  skip_if(demo_app == "", "demo app not installed")
  expect_error(build_portable(demo_app, platform = "macos"), regexp = "not implemented")
  expect_error(build_portable(demo_app, platform = "linux"), regexp = "not implemented")
})

test_that("build_tauri is honest about unimplemented backend/platform combos", {
  skip_if(demo_app == "", "demo app not installed")
  expect_error(build_tauri(demo_app, backend = "portable"), regexp = "not implemented")
  expect_error(build_tauri(demo_app, platform = "android"), regexp = "not implemented")
  expect_error(build_tauri(demo_app, platform = "ios"), regexp = "not implemented")
})

test_that("write_tauri_project embeds the frontend via a relative path", {
  project_dir <- fs::path_temp("shinyalcatraz-tauri-project")
  if (fs::dir_exists(project_dir)) fs::dir_delete(project_dir)
  fs::dir_create(project_dir)
  on.exit(fs::dir_delete(project_dir))

  frontend <- fs::path_temp("shinyalcatraz-tauri-frontend")
  if (fs::dir_exists(frontend)) fs::dir_delete(frontend)
  fs::dir_create(frontend)
  writeLines("<html></html>", fs::path(frontend, "index.html"))
  on.exit(fs::dir_delete(frontend), add = TRUE)

  write_tauri_project(project_dir, frontend_dist = frontend,
                       app_name = "My Demo App", identifier = "com.example.demo")

  conf <- jsonlite::read_json(fs::path(project_dir, "src-tauri", "tauri.conf.json"))
  expect_identical(conf$identifier, "com.example.demo")
  # frontend is copied into the project and referenced relative to the config,
  # so generate_context!() embeds it (an absolute path is loaded as file:// at
  # runtime and shows a directory listing - see docs/ARCHITECTURE.md).
  expect_identical(conf$build$frontendDist, "../frontend")
  expect_true(fs::file_exists(fs::path(project_dir, "frontend", "index.html")))
  expect_true(fs::file_exists(fs::path(project_dir, "src-tauri", "icons", "icon.png")))
  # icon.ico is required for the Windows resource embed
  expect_true(fs::file_exists(fs::path(project_dir, "src-tauri", "icons", "icon.ico")))
  expect_true(fs::file_exists(fs::path(project_dir, "src-tauri", "Cargo.toml")))
})

test_that("tauri_safe_name produces a valid crate-name-like slug", {
  expect_identical(tauri_safe_name("My Demo App!"), "my-demo-app")
  expect_identical(tauri_safe_name("demo-app"), "demo-app")
})

test_that("build_tauri actually compiles a working native binary end-to-end", {
  skip_if(demo_app == "", "demo app not installed")
  skip_if_not(nzchar(Sys.which("cargo")), "cargo not available")
  skip_if_not(nzchar(Sys.getenv("SHINYALCATRAZ_RUN_NETWORK_TESTS")),
              "set SHINYALCATRAZ_RUN_NETWORK_TESTS=1 to run this slow, network/toolchain-dependent test")

  out_dir <- fs::path_temp("shinyalcatraz-tauri-build")
  on.exit(fs::dir_delete(out_dir))
  frontend <- fs::path_temp("shinyalcatraz-tauri-frontend")
  on.exit(fs::dir_delete(frontend), add = TRUE)
  fs::dir_create(frontend)
  writeLines("<!doctype html><html><body>test</body></html>", fs::path(frontend, "index.html"))

  manifest <- build_tauri(demo_app, out_dir = out_dir, frontend_dist = frontend)

  expect_true(manifest$built)
  expect_true(fs::file_exists(manifest$entry_point))
})

test_that("scan_r_package_deps finds library()/require()/pkg:: usage", {
  dep_dir <- fs::path_temp("shinyalcatraz-dep-scan")
  fs::dir_create(dep_dir)
  on.exit(fs::dir_delete(dep_dir))
  writeLines(c(
    'library(shiny)',
    'require(ggplot2)',
    'server <- function(input, output) {',
    '  x <- dplyr::filter(mtcars, mpg > 20)',
    '  DT::datatable(x)',
    '}'
  ), fs::path(dep_dir, "app.R"))

  expect_identical(scan_r_package_deps(dep_dir), c("DT", "dplyr", "ggplot2", "shiny"))
})

test_that("scan_r_package_deps excludes base/recommended packages", {
  dep_dir <- fs::path_temp("shinyalcatraz-dep-scan-base")
  fs::dir_create(dep_dir)
  on.exit(fs::dir_delete(dep_dir))
  writeLines('library(stats); library(utils)', fs::path(dep_dir, "app.R"))

  expect_identical(scan_r_package_deps(dep_dir), character(0))
})

test_that("build_portable(platform = 'windows') downloads a real R-Portable bundle", {
  skip_if(demo_app == "", "demo app not installed")
  skip_if_not(nzchar(Sys.getenv("SHINYALCATRAZ_RUN_NETWORK_TESTS")),
              "set SHINYALCATRAZ_RUN_NETWORK_TESTS=1 to run this slow, network-dependent test")

  out_dir <- fs::path_temp("shinyalcatraz-portable-build")
  on.exit(fs::dir_delete(out_dir))
  manifest <- build_portable(demo_app, out_dir = out_dir, platform = "windows")

  expect_true(fs::file_exists(fs::path(out_dir, "run.bat")))
  expect_true(fs::file_exists(fs::path(out_dir, "R-Portable", "bin", "x64", "Rscript.exe")))
  expect_identical(manifest$target, "portable")
})

test_that("enable_update_check injects a script tag and writes the JS file", {
  bundle_dir <- fs::path_temp("shinyalcatraz-update-check")
  fs::dir_create(bundle_dir)
  on.exit(fs::dir_delete(bundle_dir))
  writeLines(c("<html><body><h1>app</h1></body></html>"), fs::path(bundle_dir, "index.html"))
  jsonlite::write_json(list(build_sha = "abc123", package_version = "0.0.0.9000"),
                        fs::path(bundle_dir, "manifest.json"), auto_unbox = TRUE)

  enable_update_check(bundle_dir, version_url = "https://example.com/version.json")

  js_path <- fs::path(bundle_dir, "shinyalcatraz-update-check.js")
  expect_true(fs::file_exists(js_path))
  js <- paste(readLines(js_path), collapse = "\n")
  expect_true(grepl("https://example.com/version.json", js, fixed = TRUE))
  expect_true(grepl("abc123", js, fixed = TRUE))

  html <- paste(readLines(fs::path(bundle_dir, "index.html")), collapse = "\n")
  expect_true(grepl("shinyalcatraz-update-check.js", html, fixed = TRUE))

  manifest <- jsonlite::read_json(fs::path(bundle_dir, "manifest.json"))
  expect_true(manifest$update_check$enabled)
})

test_that("enable_update_check is idempotent (no duplicate script tags)", {
  bundle_dir <- fs::path_temp("shinyalcatraz-update-check-idempotent")
  fs::dir_create(bundle_dir)
  on.exit(fs::dir_delete(bundle_dir))
  writeLines(c("<html><body><h1>app</h1></body></html>"), fs::path(bundle_dir, "index.html"))
  jsonlite::write_json(list(build_sha = "abc123"), fs::path(bundle_dir, "manifest.json"), auto_unbox = TRUE)

  enable_update_check(bundle_dir, version_url = "https://example.com/version.json")
  enable_update_check(bundle_dir, version_url = "https://example.com/version.json")

  html <- readLines(fs::path(bundle_dir, "index.html"))
  expect_identical(sum(grepl("shinyalcatraz-update-check.js", html, fixed = TRUE)), 1L)
})

test_that("enable_update_check errors clearly on a missing manifest or index.html", {
  bundle_dir <- fs::path_temp("shinyalcatraz-update-check-missing")
  fs::dir_create(bundle_dir)
  on.exit(fs::dir_delete(bundle_dir))
  expect_error(enable_update_check(bundle_dir, "https://example.com/v.json"))
})

test_that("find_7zip returns a scalar string and honours PATH when 7z is present", {
  res <- find_7zip()
  expect_type(res, "character")
  expect_length(res, 1L)
  on_path <- Sys.which("7z")
  if (nzchar(on_path)) expect_identical(res, unname(on_path))
})

test_that("check_wasm_packages short-circuits (no network) for a dependency-free app", {
  dep_dir <- fs::path_temp("shinyalcatraz-nodeps")
  fs::dir_create(dep_dir)
  on.exit(fs::dir_delete(dep_dir))
  writeLines("x <- 1 + 1", fs::path(dep_dir, "app.R"))
  res <- check_wasm_packages(dep_dir)
  expect_true(res$checked)
  expect_identical(res$no_wasm_build, character(0))
  expect_identical(res$from_github, character(0))
})

test_that("check_wasm_packages passes a plain shiny-only app (network)", {
  skip_if(demo_app == "", "demo app not installed")
  skip_if_not(nzchar(Sys.getenv("SHINYALCATRAZ_RUN_NETWORK_TESTS")),
              "set SHINYALCATRAZ_RUN_NETWORK_TESTS=1 to run this slow, network-dependent test")
  res <- check_wasm_packages(demo_app)
  skip_if(!isTRUE(res$checked), "webR repo unreachable")
  expect_identical(res$no_wasm_build, character(0))
})
