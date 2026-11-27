test_that("precipitation totals, consecutive days and wet day intensity respect windows", {
  w <- data.frame(Date = as.Date("2020-01-01") + 0:7, lon = 7, lat = 46,
                  PRECTOTCORR = c(0, 1, 2, 10, 20, 0, 0, 0), T2M = 15)
  p <- data.frame(lon = 7, lat = 46, start = min(w$Date), end = max(w$Date))
  x <- UFEED_precipitation_indices(w[8:1, ], p)
  expect_equal(unlist(x[c("precip_mm", "wet_days", "cwd", "cdd", "rx1day", "rx5day", "sdii")],
                      use.names = FALSE), c(33, 4, 4, 3, 20, 33, 8.25))
  expect_false(UFEED_precipitation_indices(w[-3, ], p)$complete_precip)
})

test_that("mapped soil capacity and daily fluxes conserve water", {
  soil <- data.frame(lon = 7, lat = 46, wv0033_0_5cm = 300,
                     wv1500_0_5cm = 100, cfvo_0_5cm = 200)
  w <- data.frame(Date = as.Date("2020-01-01") + 0:2, lon = 7, lat = 46,
                  PRECTOTCORR = c(10, 0, 0), ET0_FAO56_MM_DAY = c(2, 3, 5))
  expect_equal(UFEED_soil_water_capacity(soil, 5)$capacity_mm, 8)
  x <- UFEED_reference_water_balance(w, soil, 5)
  expect_equal(x$refsoil_storage_mm, c(6, 3, 0))
  expect_equal(x$refsoil_drainage_mm, c(6, 0, 0))
  expect_equal(x$refsoil_unmet_et_mm, c(0, 0, 2))
  expect_equal(4 + sum(w$PRECTOTCORR),
               sum(x$refsoil_drainage_mm + x$refsoil_actual_et_mm))
  expect_true(is.na(UFEED_reference_water_balance(w[-2, ], soil, 5)$refsoil_storage_mm[2]))
})

test_that("FAO-56 published daily Example 18 rounds to 3.9 mm/day", {
  ea <- 1.409
  dew <- 237.3 * log(ea / 0.6108) / (17.27 - log(ea / 0.6108))
  w <- data.frame(Date = as.Date("2023-07-06"), lat = 50.8, T2M = 16.9,
                  T2M_MIN = 12.3, T2M_MAX = 21.5, elevation = 100,
                  T2MDEW = dew, WS2M = 10 / 3.6, ALLSKY_SFC_SW_DWN = 22.07)
  x <- UFEED_feature_expansion_1(w, UFEED_feature_expansion_1_canonical_units(), 10)
  expect_equal(round(x$ET0_FAO56_MM_DAY, 1), 3.9)
  expect_lt(abs(x$ET0_FAO56_MM_DAY - 3.88), 0.03)
})

test_that("soil capacity reproduces FAO-56 Example 36 for maize", {
  soil <- data.frame(lon = 7, lat = 46)
  depths <- c("0_5cm", "5_15cm", "15_30cm", "30_60cm", "60_100cm", "100_200cm")
  for (d in depths) {
    soil[[paste0("wv0033_", d)]] <- 320
    soil[[paste0("wv1500_", d)]] <- 150
    soil[[paste0("cfvo_", d)]] <- 0
  }
  expect_equal(UFEED_soil_water_capacity(soil, depth_cm = 120)$capacity_mm, 204)
})

test_that("all engines are attempted and successful output is joined by daily keys", {
  w <- data.frame(Date = as.Date("2020-01-01") + 0:1, lon = 7, lat = 46)
  ok <- function(weather, soil, crop) transform(weather[2:1, ], LAI = c(2, 1))
  bad <- function(weather, soil, crop) stop("crop unavailable")
  x <- UFEED_compute_weather_features(
    w, included_module = "crop_model_features", message_progress = FALSE,
    crop_model = list(crop = "wheat", runners = list(stics = ok, dssat = bad, apsim = ok))
  )
  expect_identical(attr(x, "crop_model_status")$status, c("completed", "failed", "completed"))
  expect_equal(x$apsim_LAI, 1:2)
  expect_equal(x$stics_LAI, 1:2)
})

test_that("CroptimizR situation outputs map to the correct sites and dates", {
  day <- as.Date("2020-01-01") + 0:1
  w <- data.frame(Date = rep(day, 2), lon = rep(c(7, 8), each = 2), lat = 46)
  sites <- data.frame(situation = c("east", "west"), lon = c(8, 7), lat = 46)
  ok <- function(param_values, situation, model_options) {
    stopifnot(identical(situation, c("east", "west")), is.null(param_values))
    list(error = FALSE, sim_list = structure(list(
      west = data.frame(Date = day[2:1], LAI = c(2, 1) * model_options),
      east = data.frame(Date = as.POSIXct(day, tz = "UTC"), LAI = c(3, 4) * model_options)
    ), class = "cropr_simulation"))
  }
  failure <- function(...) list(error = TRUE, sim_list = list())
  config <- list(wrapper = ok, model_options = 2, sites = sites)
  x <- UFEED_compute_weather_features(
    w, included_module = "crop_model_features", message_progress = FALSE,
    crop_model = list(crop = "wheat", croptimizr = list(
      stics = config, dssat = list(wrapper = failure, sites = sites), apsim = config
    ))
  )
  expect_identical(attr(x, "crop_model_status")$status, c("completed", "failed", "completed"))
  expect_equal(x$stics_LAI, c(2, 4, 6, 8))
  expect_equal(x$apsim_LAI, x$stics_LAI)
  expect_error(UFEED_compute_weather_features(
    w, included_module = "crop_model_features", message_progress = FALSE,
    crop_model = list(crop = "wheat")
  ), "at least one model configuration")
})

test_that("the reference process module works with ordinary daily weather", {
  w <- data.frame(Date = as.Date("2023-07-15") + 0:7, lon = 4.8, lat = 45 + 43/60,
                  T2M_MIN = 14.8, T2M_MAX = 26.6, PRECTOTCORR = 8)
  run <- function(x) UFEED_compute_weather_features(
    x, included_module = "crop_model_features", message_progress = FALSE
  )
  x <- run(w)
  # FAO-56 chapter 4, Lyon July comparison with Hargreaves.
  expect_equal(round(x$process_et0_hargreaves_mm[1], 1), 5.0)
  expect_equal(x$process_climatic_balance_mm_7d[7],
               sum(x$process_climatic_balance_mm[1:7]))
  expect_true(all(is.na(run(w[-2, ])$process_climatic_balance_mm_7d)))
  expect_null(attr(x, "crop_model_status"))
})

test_that("opt-in setup reports explicit engine paths and missing engines", {
  engine <- tempfile(fileext = ".exe")
  file.create(engine)
  on.exit(unlink(engine), add = TRUE)
  checks <- UFEED_setup_crop_models(
    engine_paths = c(apsim = engine, dssat = tempfile(), stics = tempdir())
  )
  expect_identical(checks$engines$detected, c(TRUE, FALSE, FALSE))
  expect_identical(checks$engines$executable[1], normalizePath(engine, winslash = "/"))
  expect_true(all(startsWith(checks$engines$download, "https://")))
})
test_that("daily counter increments do not bridge gaps or reset boundaries", {
  dates <- as.Date("2011-01-01") + c(0, 1, 3, 4, 5)
  expect_equal(ufeed_daily_counter_increment(c(0, 2, 4, 0, 3), dates),
               c(NA, 2, NA, NA, 3))
})

test_that("the main entry point joins crop processes by site and date", {
  dates <- as.Date("2011-04-01") + 0:2
  w <- data.frame(Date = dates, lon = 1, lat = 2, PRECTOTCORR = 0)
  runner <- function(weather, soil, crop) {
    data.frame(weather[2:3, c("Date", "lon", "lat")], transpiration_mm_day = c(0L, 2L))
  }
  out <- UFEED(weather = w, modules = "derived", progress = FALSE,
    crop_model = list(crop = "wheat", runners = list(apsim = runner)))
  expect_equal(out$apsim_transpiration_mm_day, c(NA, 0, 2))
  expect_equal(attr(out, "crop_model_status")$status[3], "completed")
})
