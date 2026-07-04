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

test_that("scan_r_package_deps ignores build-output dirs (dist/, shinylive/)", {
  app <- fs::path_temp("shinyalcatraz-scan-ignore")
  if (fs::dir_exists(app)) fs::dir_delete(app)
  fs::dir_create(fs::path(app, "dist", "wasm", "shinylive"))
  on.exit(fs::dir_delete(app))
  writeLines("library(dplyr); DT::datatable(iris)", fs::path(app, "app.R"))
  # a previous build output full of C++ / package sources must NOT leak in
  writeLines("Eigen::ArrayXd(); BiocGenerics::foo(); waffle::waffle()",
             fs::path(app, "dist", "wasm", "shinylive", "junk.R"))
  deps <- scan_r_package_deps(app)
  expect_true(all(c("dplyr", "DT") %in% deps))
  expect_false(any(c("Eigen", "ArrayXd", "BiocGenerics", "waffle") %in% deps))
})

test_that("scan_r_package_deps optionally catches commented-out library() calls", {
  d <- fs::path_temp("shinyalcatraz-commented")
  if (fs::dir_exists(d)) fs::dir_delete(d)
  fs::dir_create(d)
  on.exit(fs::dir_delete(d))
  writeLines(c("library(dplyr)", "#library(ggradar)", "# require(waffle)"),
             fs::path(d, "app.R"))
  # default: a commented-out library() is not a dependency
  expect_false("ggradar" %in% scan_r_package_deps(d))
  # opt-in: shinylive reads them, so the wasm pre-flight must too
  with_comments <- scan_r_package_deps(d, include_commented = TRUE)
  expect_true(all(c("dplyr", "ggradar", "waffle") %in% with_comments))
})

test_that("missing_bundle_packages flags required packages absent from the library", {
  lib <- fs::path_temp("shinyalcatraz-bundle-lib")
  if (fs::dir_exists(lib)) fs::dir_delete(lib)
  fs::dir_create(fs::path(lib, "shiny"))
  fs::dir_create(fs::path(lib, "dplyr"))
  on.exit(fs::dir_delete(lib))
  # ggradar requested but not present -> reported missing; installed ones aren't
  expect_identical(missing_bundle_packages(lib, c("shiny", "dplyr", "ggradar")), "ggradar")
  expect_identical(missing_bundle_packages(lib, c("shiny", "dplyr")), character(0))
})

test_that("build_remote_install_expr covers every git-forge/URL remote type", {
  gh <- list(RemoteType = "github", RemoteUsername = "u", RemoteRepo = "r", RemoteRef = "HEAD")
  expect_match(build_remote_install_expr(gh, "L"), 'install_github\\("u/r"')
  gl <- list(RemoteType = "gitlab", RemoteUsername = "u", RemoteRepo = "r",
             RemoteHost = "gitlab.example.com", RemoteRef = "v1")
  expect_match(build_remote_install_expr(gl, "L"),
               'install_gitlab\\("u/r@v1", host = "gitlab.example.com"')
  bb <- list(RemoteType = "bitbucket", RemoteUsername = "u", RemoteRepo = "r")
  expect_match(build_remote_install_expr(bb, "L"), 'install_bitbucket\\("u/r"')
  g <- list(RemoteType = "git", RemoteUrl = "https://x/y.git", RemoteRef = "main")
  expect_match(build_remote_install_expr(g, "L"), 'install_git\\("https://x/y.git", ref = "main"')
  u <- list(RemoteType = "url", RemoteUrl = "https://x/p.tar.gz")
  expect_match(build_remote_install_expr(u, "L"), 'install_url\\("https://x/p.tar.gz"')
  expect_null(build_remote_install_expr(list(RemoteType = "cran"), "L"))
  expect_null(build_remote_install_expr(list(), "L"))
})

test_that("remote_install_specs ignores CRAN/base packages", {
  expect_length(remote_install_specs(character(0), "L"), 0L)
  expect_length(remote_install_specs("stats", "L"), 0L)
})

test_that("custom_repo_urls returns only real URL repositories", {
  expect_length(custom_repo_urls(character(0)), 0L)
  expect_length(custom_repo_urls("stats"), 0L)
})

test_that("bioc_packages ignores CRAN/base packages", {
  expect_length(bioc_packages(character(0)), 0L)
  expect_length(bioc_packages("stats"), 0L)
})

test_that("copy_pure_r_packages copies pure-R packages and skips compiled ones", {
  skip_if_not(nzchar(system.file(package = "R6")) &&
              nzchar(system.file(package = "rlang")), "R6/rlang not installed")
  lib <- fs::path_temp("shinyalcatraz-copy-pure")
  if (fs::dir_exists(lib)) fs::dir_delete(lib)
  fs::dir_create(lib)
  on.exit(fs::dir_delete(lib))
  copied <- copy_pure_r_packages(lib, c("R6", "rlang"))   # R6 pure-R, rlang compiled
  expect_true("R6" %in% copied)
  expect_false("rlang" %in% copied)
  expect_true(fs::dir_exists(fs::path(lib, "R6")))
  expect_false(fs::dir_exists(fs::path(lib, "rlang")))
})

test_that("remote_git_url builds source URLs for git-forge remotes", {
  expect_identical(remote_git_url(list(RemoteType = "github", RemoteUsername = "u", RemoteRepo = "r")),
                   "https://github.com/u/r")
  expect_identical(remote_git_url(list(RemoteType = "gitlab", RemoteUsername = "u", RemoteRepo = "r",
                                       RemoteHost = "gitlab.com/api/v4")),
                   "https://gitlab.com/u/r")
  expect_identical(remote_git_url(list(RemoteType = "bitbucket", RemoteUsername = "u", RemoteRepo = "r")),
                   "https://bitbucket.org/u/r")
  expect_identical(remote_git_url(list(RemoteType = "git", RemoteUrl = "https://x/y.git")),
                   "https://x/y.git")
  expect_null(remote_git_url(list(RemoteType = "cran")))
  # legacy devtools fields (no RemoteType) are handled too
  expect_identical(remote_git_url(list(GithubUsername = "u", GithubRepo = "r")),
                   "https://github.com/u/r")
})

test_that("runiverse_registry is empty for an app with no remote packages", {
  d <- fs::path_temp("shinyalcatraz-noremote")
  if (fs::dir_exists(d)) fs::dir_delete(d)
  fs::dir_create(d)
  on.exit(fs::dir_delete(d))
  writeLines("library(stats)", fs::path(d, "app.R"))
  expect_length(runiverse_registry(d), 0L)
})

test_that("runiverse_status returns an empty frame for an app with no remotes", {
  d <- fs::path_temp("shinyalcatraz-rustatus")
  if (fs::dir_exists(d)) fs::dir_delete(d)
  fs::dir_create(d)
  on.exit(fs::dir_delete(d))
  writeLines("library(stats)", fs::path(d, "app.R"))
  res <- runiverse_status(d)
  expect_s3_class(res, "data.frame")
  expect_identical(nrow(res), 0L)
})

test_that("native_runtime_providers registers a provision fn per trigger package", {
  p <- native_runtime_providers()
  expect_setequal(names(p), c("java", "tesseract", "mariadb", "toolchain"))
  expect_true("rJava" %in% p$java$pkgs)
  expect_true("RMariaDB" %in% p$mariadb$pkgs)
  expect_true("rstan" %in% p$toolchain$pkgs)
  for (prov in p) expect_true(is.function(prov$provision))
})

test_that("provision_native_runtimes returns nothing when no package triggers a runtime", {
  d <- fs::path_temp("shinyalcatraz-nortdir"); fs::dir_create(d); on.exit(fs::dir_delete(d))
  expect_length(provision_native_runtimes(c("shiny", "ggplot2"), d, d), 0L)
})

test_that("provision_native_runtimes handles the no-download providers without touching the network", {
  d <- fs::path_temp("shinyalcatraz-rtnodl"); fs::dir_create(d); on.exit(fs::dir_delete(d))
  # RMariaDB client (no server opt) and rstan (no rtools opt) stage nothing and
  # emit no run.bat lines - so this needs no network.
  expect_length(provision_native_runtimes(c("RMariaDB", "rstan"), d, d), 0L)
})

test_that("provision_native_runtimes skips a provider disabled via native_runtime", {
  d <- fs::path_temp("shinyalcatraz-rtdisabled"); fs::dir_create(d); on.exit(fs::dir_delete(d))
  # java would normally download a JRE; enabled = FALSE must short-circuit it.
  expect_length(
    provision_native_runtimes("rJava", d, d, native_runtime = list(java = list(enabled = FALSE))),
    0L)
})

test_that("provision_native_runtimes warns on an unknown native_runtime entry", {
  d <- fs::path_temp("shinyalcatraz-rtunknown"); fs::dir_create(d); on.exit(fs::dir_delete(d))
  expect_warning(provision_native_runtimes("shiny", d, d, native_runtime = list(nope = list())),
                 "unknown")
})

test_that("cran_repo pins to a Posit PM snapshot and rejects bad dates", {
  expect_identical(cran_repo(NULL), "https://cloud.r-project.org")
  expect_identical(cran_repo("2024-06-01"),
                   "https://packagemanager.posit.co/cran/2024-06-01")
  expect_error(cran_repo("June 2024"), "snapshot")
  expect_error(cran_repo("2024/06/01"), "snapshot")
})

test_that("installed_package_versions reads exact versions from DESCRIPTIONs", {
  lib <- fs::path_temp("shinyalcatraz-vers"); if (fs::dir_exists(lib)) fs::dir_delete(lib)
  fs::dir_create(fs::path(lib, "foo")); fs::dir_create(fs::path(lib, "bar"))
  on.exit(fs::dir_delete(lib))
  writeLines(c("Package: foo", "Version: 1.2.3"), fs::path(lib, "foo", "DESCRIPTION"))
  writeLines(c("Package: bar", "Version: 0.9.0"), fs::path(lib, "bar", "DESCRIPTION"))
  v <- installed_package_versions(lib)
  expect_identical(v[["foo"]], "1.2.3")
  expect_identical(v[["bar"]], "0.9.0")
})

test_that("resolve_runtime_preset expands auto/all/none correctly", {
  # auto: no forced options
  expect_identical(resolve_runtime_preset("auto"), list())
  # none: every provider disabled
  none <- resolve_runtime_preset("none")
  expect_true(all(vapply(none, function(x) isFALSE(x$enabled), logical(1))))
  expect_setequal(names(none), names(native_runtime_providers()))
  # all: heavy opt-ins forced on
  all <- resolve_runtime_preset("all")
  expect_true(isTRUE(all$mariadb$server))
  expect_true(isTRUE(all$toolchain$rtools))
})

test_that("resolve_runtime_preset lets explicit native_runtime override the preset", {
  # user disables java even though 'all' would enable it
  res <- resolve_runtime_preset("all", list(java = list(enabled = FALSE),
                                            tesseract = list(langs = "fra")))
  expect_true(isFALSE(res$java$enabled))
  expect_identical(res$tesseract$langs, "fra")
  expect_true(isTRUE(res$mariadb$server))     # preset key preserved
})

test_that("rtools_version_for maps an R version to its paired Rtools version", {
  expect_identical(rtools_version_for("4.5.1"), "45")
  expect_identical(rtools_version_for("4.2.0"), "42")
  expect_identical(rtools_version_for(getRversion()), rtools_version_for(as.character(getRversion())))
})

test_that("provision_toolchain aborts clearly when it can't determine the Rtools version", {
  d <- fs::path_temp("shinyalcatraz-notc"); fs::dir_create(d); on.exit(fs::dir_delete(d))
  # rtools = TRUE but neither rtools_version nor r_version supplied
  expect_error(provision_toolchain(d, d, list(rtools = TRUE)), "Rtools version")
})

test_that("write_portable_launcher injects native-runtime env lines before Rscript", {
  d <- fs::path_temp("shinyalcatraz-launcher"); fs::dir_create(d); on.exit(fs::dir_delete(d))
  write_portable_launcher(d, port = 8973,
                          env_lines = 'set "TESSDATA_PREFIX=%~dp0tessdata"')
  bat <- readLines(fs::path(d, "run.bat"))
  env_at <- grep("TESSDATA_PREFIX", bat)
  rscript_at <- grep("Rscript.exe", bat)
  expect_length(env_at, 1L)
  expect_true(env_at < rscript_at)                 # env set before R starts
})

test_that("write_portable_launcher logs R output and ships a windowless launcher", {
  d <- fs::path_temp("shinyalcatraz-launch2"); fs::dir_create(d); on.exit(fs::dir_delete(d))
  write_portable_launcher(d, port = 8973)
  bat <- readLines(fs::path(d, "run.bat"))
  # R output is redirected to a log, and the log is popped open on a non-zero exit
  expect_true(any(grepl("run_app.R >.*log.\\\\?last-run.txt", bat)))
  expect_true(any(grepl("notepad", bat)))
  expect_true(fs::dir_exists(fs::path(d, "log")))
  # windowless launcher ships and calls run.bat hidden (Run ..., 0, False)
  expect_true(fs::file_exists(fs::path(d, "run.vbs")))
  vbs <- readLines(fs::path(d, "run.vbs"))
  expect_true(any(grepl("run.bat", vbs)) && any(grepl(", 0, False", vbs, fixed = TRUE)))
})
