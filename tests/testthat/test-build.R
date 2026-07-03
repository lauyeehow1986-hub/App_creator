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

test_that("build_portable and build_tauri are honest about being unimplemented", {
  skip_if(demo_app == "", "demo app not installed")
  expect_error(build_portable(demo_app, platform = "windows"), regexp = "not yet implemented")
  expect_error(build_tauri(demo_app, platform = "windows"), regexp = "not yet implemented")
})
