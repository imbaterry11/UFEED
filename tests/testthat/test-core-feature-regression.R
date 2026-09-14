make_regression_weather <- function(n = 120, lat = 46.16) {
  dates <- as.Date("2024-01-01") + seq_len(n) - 1L
  x <- seq_len(n)

  data.frame(
    Date = dates,
    lon = rep(7.155, n),
    lat = rep(lat, n),
    T2M = x,
    T2M_MAX = x + 5,
    T2M_MIN = x - 5,
    T2MDEW = x - 10,
    PRECTOTCORR = x,
    RH2M = rep(60, n),
    WS2M = rep(2, n),
    WS2M_MAX = rep(3, n),
    GWETROOT = x / 100,
    GWETTOP = x / 100,
    TSOIL1 = x + 1,
    TSOIL3 = x + 2,
    EVPTRNS = x / 10
  )
}

manual_ewma <- function(x, window, reverse = FALSE) {
  alpha <- 2 / (window + 1)
  out <- rep(NA_real_, length(x))

  for (i in seq_along(x)) {
    start_i <- i - window + 1L
    if (start_i < 1L) next

    x_window <- x[start_i:i]
    weights <- if (reverse) {
      (1 - alpha)^(0:(window - 1L))
    } else {
      (1 - alpha)^((window - 1L):0)
    }
    weights <- weights / sum(weights)
    out[i] <- sum(x_window * weights)
  }

  out
}

test_that("ERA5-Land U/V components follow meteorological direction", {
  wind_direction_from_uv <- function(u, v) {
    (atan2(-u, -v) * 180 / pi + 360) %% 360
  }

  expect_equal(
    wind_direction_from_uv(
      u = c(0, -1, 0, 1),
      v = c(-1, 0, 1, 0)
    ),
    c(0, 90, 180, 270),
    tolerance = 1e-12
  )
})

test_that("cumsum features are backward cumulative sums within season", {
  weather <- make_regression_weather(n = 10)

  features <- UFEED_compute_weather_features(
    weather_data = weather,
    feature_profile = "history",
    included_module = "cumsum_features",
    cumsum_cols = "PRECTOTCORR",
    cumsum_max_missing_prop = 1,
    message_progress = FALSE
  )

  expect_equal(features$PRECTOTCORR_y2d, cumsum(weather$PRECTOTCORR))
  expect_equal(features$PRECTOTCORR_dormant2d, cumsum(weather$PRECTOTCORR))
  expect_equal(features[, c("Date", "lon", "lat")], weather[, c("Date", "lon", "lat")])
})

test_that("EWMA and REWMA use only backward full windows with expected weights", {
  weather <- make_regression_weather(n = 8)

  features <- UFEED_compute_weather_features(
    weather_data = weather,
    feature_profile = "history",
    included_module = "EWMA_REWMA_features",
    ewma_rewma_cols = "T2M",
    ewma_rewma_windows = 3,
    ewma_rewma_max_missing_prop = 0,
    ewma_rewma_require_full_window = TRUE,
    message_progress = FALSE
  )

  expect_equal(features$T2M_EWMA_3, manual_ewma(weather$T2M, 3))
  expect_equal(features$T2M_REWMA_3, manual_ewma(weather$T2M, 3, reverse = TRUE))
  expect_true(all(is.na(features$T2M_EWMA_3[1:2])))
  expect_true(all(is.na(features$T2M_REWMA_3[1:2])))
})

test_that("EWMA and REWMA values are not changed by future rows", {
  weather <- make_regression_weather(n = 8)
  weather_future_changed <- weather
  weather_future_changed$T2M[5:8] <- weather_future_changed$T2M[5:8] * 100

  baseline <- UFEED_compute_weather_features(
    weather_data = weather,
    feature_profile = "history",
    included_module = "EWMA_REWMA_features",
    ewma_rewma_cols = "T2M",
    ewma_rewma_windows = 3,
    message_progress = FALSE
  )

  changed <- UFEED_compute_weather_features(
    weather_data = weather_future_changed,
    feature_profile = "history",
    included_module = "EWMA_REWMA_features",
    ewma_rewma_cols = "T2M",
    ewma_rewma_windows = 3,
    message_progress = FALSE
  )

  expect_equal(changed$T2M_EWMA_3[1:4], baseline$T2M_EWMA_3[1:4])
  expect_equal(changed$T2M_REWMA_3[1:4], baseline$T2M_REWMA_3[1:4])
})

test_that("season summary features are cumulative within season", {
  weather <- make_regression_weather(n = 8)

  features <- UFEED_compute_weather_features(
    weather_data = weather,
    feature_profile = "history",
    included_module = "season_summary_features",
    ewma_rewma_cols = c("T2M_MAX", "T2M_MIN"),
    ewma_rewma_windows = 2,
    ewma_rewma_require_full_window = FALSE,
    season_max_cols = "T2M_MAX",
    season_min_cols = "T2M_MIN",
    message_progress = FALSE
  )

  expect_equal(
    features$T2M_MAX_EWMA_2_season_max,
    cummax(features$T2M_MAX_EWMA_2)
  )
  expect_equal(
    features$T2M_MIN_EWMA_2_season_min,
    cummin(features$T2M_MIN_EWMA_2)
  )
  expect_equal(features[, c("Date", "lon", "lat")], weather[, c("Date", "lon", "lat")])
})

test_that("current-year lag warnings can be suppressed by present workflows", {
  current_year <- as.integer(format(Sys.Date(), "%Y"))

  collect_warnings <- function(expr) {
    messages <- character()
    tryCatch(
      withCallingHandlers(
        expr,
        warning = function(w) {
          messages <<- c(messages, conditionMessage(w))
          invokeRestart("muffleWarning")
        }
      ),
      error = function(e) NULL
    )
    messages
  }

  power_args <- list(
    lon = 7.155,
    lat = 46.16,
    start_year = current_year,
    end_year = current_year,
    parameters = "T2M",
    max_retries = 0,
    retry_wait_sec = 0
  )

  power_warnings <- collect_warnings(
    do.call(UFEED:::get_weather_data_NASA_POWER_ONLY, power_args)
  )
  expect_length(power_warnings, 1)
  expect_match(power_warnings, "NASA POWER data may lag", fixed = TRUE)

  power_args$warn_current_year <- FALSE
  expect_length(
    collect_warnings(do.call(UFEED:::get_weather_data_NASA_POWER_ONLY, power_args)),
    0
  )

  combined_args <- power_args
  combined_args$warn_current_year <- TRUE
  combined_warnings <- collect_warnings(
    do.call(UFEED:::get_weather_data_power_open_meteo, combined_args)
  )
  expect_length(combined_warnings, 1)
  expect_match(combined_warnings, "POWER/Open-Meteo may lag", fixed = TRUE)

  combined_args$warn_current_year <- FALSE
  expect_length(
    collect_warnings(do.call(UFEED:::get_weather_data_power_open_meteo, combined_args)),
    0
  )
})
