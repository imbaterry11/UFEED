test_that("Open-Meteo estimates allow fractional calls and count locations", {
  expect_equal(ufeed_open_meteo_calls(15, 14), 1.5)
  expect_equal(ufeed_open_meteo_calls(15, 28), 3)
  expect_equal(ufeed_open_meteo_calls(1, 1, locations = 2), 2)
})

test_that("weather gap filling preserves measured zeroes and records provenance", {
  dates <- as.Date("2024-06-01") + 0:2
  local_mocked_bindings(ufeed_fetch_weather = function(job) {
    expect_equal(job$fields, "PRECTOTCORR")
    expect_equal(job$start, dates[2L])
    data.frame(Date = dates[2:3], PRECTOTCORR = c(2, 3))
  })
  supplied <- data.frame(Date = dates[c(1, 3)], PRECTOTCORR = c(0, NA))
  result <- UFEED(lon = 1, lat = 2, weather = supplied, modules = "derived",
                  fill_missing = TRUE, progress = FALSE)
  expect_equal(result$PRECTOTCORR, c(0, 2, 3))
  expect_equal(attr(result, "weather_fill")$Date, dates[2:3])
  expect_equal(unname(attr(result, "weather_coverage")["missing_after"]), 0)
})

test_that("cutoffs exclude rows before feature calculation and offline avoids HTTP", {
  local_mocked_bindings(ufeed_fetch_weather = function(...) stop("Unexpected HTTP"))
  weather <- data.frame(Date = as.Date("2024-06-01") + 0:2, PRECTOTCORR = 1:3)
  out <- UFEED(weather = weather, lon = 1, lat = 2, modules = "derived",
               prediction_ready = TRUE, as_of = "2024-06-02", progress = FALSE)
  expect_equal(out$PRECTOTCORR, 1:2)
  expect_equal(nrow(attr(out, "download_report")), 0)
})

test_that("coordinate-free weather does not guess a growing season", {
  local_mocked_bindings(ufeed_fetch_weather = function(...) stop("Unexpected HTTP"))
  weather <- data.frame(Date = as.Date("2024-06-01") + 0:14,
                        PRECTOTCORR = 0, T2M_MIN = 10, T2M_MAX = 20)
  out <- UFEED(weather = weather, progress = FALSE)
  expect_equal(out$PRECTOTCORR, weather$PRECTOTCORR)
  expect_false("PRECTOTCORR_y2d" %in% names(out))
})

test_that("soil-only and weather-only runs skip the other provider", {
  local_mocked_bindings(
    ufeed_fetch_weather = function(...) stop("Unexpected weather download"),
    UFEED_get_soil_features = function(lon, lat, ...) data.frame(lon, lat, clay = 25))
  expect_equal(UFEED(lon = 1, lat = 2, modules = "soil")$clay, 25)
  supplied <- data.frame(lon = 1, lat = 2, clay = 30)
  expect_equal(UFEED(soil = supplied, modules = "soil"), supplied)
  weather <- data.frame(Date = as.Date("2024-06-01") + 0:14,
                        PRECTOTCORR = 0, T2M_MIN = 10, T2M_MAX = 20)
  out <- UFEED(weather = weather, lon = 1, lat = 2, modules = "weather",
               soil_data_source = "remote")
  expect_false("clay" %in% names(out))
})
