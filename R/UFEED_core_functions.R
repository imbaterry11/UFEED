# UFEED core functions - v5
# Generated from working V3 with the Google Earth Engine route renamed to ee
# Date shift bug fixed: use vector-safe Date_shifted logic.

# UFEED core functions ---------------------------------------------------------
# This file defines two main user-facing functions:
#   1. UFEED_history(): historical UFEED weather + soil feature generation
#   2. UFEED_present(): current-season / near-future UFEED feature generation
#
# Notes for package development:
# - Do not call install.packages() inside package code.
# - Prefer package::function() calls where possible.
# - Earth Engine is only required when weather_data_source = "power_ee".
# - get_open_meteo_soil_daily_data() is included for North America recent/forecast soil fallback.

# -----------------------------------------------------------------------------
# 0. Constants
# -----------------------------------------------------------------------------

UFEED_WEATHER_PARAMETERS_HISTORY <- c(
  "T2M", "T2M_MAX", "T2M_MIN", "T2MDEW", "PRECTOTCORR",
  "RH2M", "WS2M", "WD2M", "WS2M_MAX", "WS2M_MIN", "PS",
  "ALLSKY_SFC_SW_DWN", "ALLSKY_SFC_LW_DWN", "ALLSKY_SFC_PAR_TOT",
  "GWETROOT", "GWETTOP", "TSOIL1", "TSOIL3", "EVPTRNS", "CLOUD_AMT"
)

UFEED_WEATHER_PARAMETERS_PRESENT <- c(
  "T2M", "T2M_MAX", "T2M_MIN", "T2MDEW", "PRECTOTCORR",
  "RH2M", "WS2M", "WD2M", "WS2M_MAX", "WS2M_MIN", "PS",
  "ALLSKY_SFC_SW_DWN",
  "GWETROOT", "GWETTOP", "TSOIL1", "TSOIL3", "EVPTRNS"
)

UFEED_CUMSUM_COLS_HISTORY <- c(
  "ALLSKY_SFC_SW_DWN",
  "ALLSKY_SFC_LW_DWN",
  "ALLSKY_SFC_PAR_TOT",
  "PRECTOTCORR"
)

UFEED_CUMSUM_COLS_PRESENT <- c(
  "ALLSKY_SFC_SW_DWN",
  "PRECTOTCORR"
)

UFEED_EWMA_REWMA_COLS_HISTORY <- c(
  "T2M", "T2M_MAX", "T2M_MIN", "T2MDEW", "Daily_Temp_Fluctuation",
  "ALLSKY_SFC_SW_DWN",
  "ALLSKY_SFC_LW_DWN",
  "ALLSKY_SFC_PAR_TOT",
  "PRECTOTCORR",
  "RH2M", "WS2M", "WD2M", "WS2M_MAX", "WS2M_MIN",
  "PS", "GWETROOT", "GWETTOP", "TSOIL1", "TSOIL3",
  "EVPTRNS", "CLOUD_AMT"
)

UFEED_EWMA_REWMA_COLS_PRESENT <- c(
  "T2M", "T2M_MAX", "T2M_MIN", "T2MDEW", "Daily_Temp_Fluctuation",
  "ALLSKY_SFC_SW_DWN",
  "PRECTOTCORR",
  "RH2M", "WS2M", "WD2M", "WS2M_MAX", "WS2M_MIN",
  "PS", "GWETROOT", "GWETTOP", "TSOIL1", "TSOIL3",
  "EVPTRNS"
)

UFEED_MODULES <- c(
  "cumsum_features",
  "EWMA_REWMA_features",
  "cumulative_temp_features",
  "season_summary_features"
)

# -----------------------------------------------------------------------------
# 1. Small utilities
# -----------------------------------------------------------------------------

UFEED_check_required_packages <- function(pkgs) {
  missing <- pkgs[!vapply(pkgs, requireNamespace, quietly = TRUE, FUN.VALUE = logical(1))]
  if (length(missing) > 0) {
    stop(
      "Missing required package(s): ", paste(missing, collapse = ", "),
      ". Please install them before running UFEED.",
      call. = FALSE
    )
  }
  invisible(TRUE)
}

UFEED_normalize_coordinates <- function(lon, lat, pairwise = TRUE) {
  if (pairwise) {
    if (length(lon) != length(lat)) {
      stop("When pairwise = TRUE, `lon` and `lat` must have the same length.", call. = FALSE)
    }
    out <- data.frame(lon = as.numeric(lon), lat = as.numeric(lat))
  } else {
    out <- expand.grid(
      lon = as.numeric(lon),
      lat = as.numeric(lat),
      KEEP.OUT.ATTRS = FALSE
    )
  }

  out <- unique(out)
  if (any(!is.finite(out$lon)) || any(!is.finite(out$lat))) {
    stop("`lon` and `lat` must be finite numeric values.", call. = FALSE)
  }
  if (any(out$lon < -180 | out$lon > 180)) {
    stop("`lon` must be between -180 and 180.", call. = FALSE)
  }
  if (any(out$lat < -90 | out$lat > 90)) {
    stop("`lat` must be between -90 and 90.", call. = FALSE)
  }
  row.names(out) <- NULL
  out
}

UFEED_recycle_year_arg <- function(x, n, arg_name) {
  x <- as.integer(x)
  if (length(x) == 1L) return(rep(x, n))
  if (length(x) == n) return(x)
  stop(
    "`", arg_name, "` must have length 1 or the same length as the number of coordinate pairs.",
    call. = FALSE
  )
}

UFEED_validate_modules <- function(included_module) {
  bad <- setdiff(included_module, UFEED_MODULES)
  if (length(bad) > 0) {
    stop(
      "Unknown module(s): ", paste(bad, collapse = ", "),
      ". Allowed modules are: ", paste(UFEED_MODULES, collapse = ", "), ".",
      call. = FALSE
    )
  }
  included_module
}

UFEED_safe_left_join_features <- function(df, feature_df) {
  if (is.null(feature_df)) return(df)
  join_cols <- intersect(c("Date", "lon", "lat"), names(feature_df))
  if (!all(c("Date", "lon", "lat") %in% join_cols)) {
    stop("Feature table must contain Date, lon, and lat for safe joining.", call. = FALSE)
  }
  dplyr::left_join(df, feature_df, by = c("Date", "lon", "lat"))
}

UFEED_remove_duplicate_columns <- function(df) {
  df[, !duplicated(names(df)), drop = FALSE]
}

UFEED_clean_names <- function(df) {
  df |>
    dplyr::rename_with(~ gsub("-", "_", ., fixed = TRUE))
}

UFEED_add_daily_temp_fluctuation <- function(df) {
  if (all(c("T2M_MAX", "T2M_MIN") %in% names(df))) {
    df$Daily_Temp_Fluctuation <- df$T2M_MAX - df$T2M_MIN
  }
  df
}

# -----------------------------------------------------------------------------
# 2. Earth Engine initialization
# -----------------------------------------------------------------------------

ensure_ee_initialized <- function(
    ee_user = NULL,
    ask = TRUE,
    drive = FALSE,
    gcs = FALSE,
    test_image = "NASA/NASADEM_HGT/001"
) {
  UFEED_check_required_packages("rgee")

  # Internal helper: test whether EE is actually usable.
  # This avoids treating ee_Initialize() as successful if EE is not really ready.
  ee_is_working <- function() {
    ee <- tryCatch(UFEED_get_ee(), error = function(e) NULL)

    if (is.null(ee)) {
      return(FALSE)
    }

    ok <- tryCatch({
      ee$Image(test_image)$getInfo()
      TRUE
    }, error = function(e) {
      FALSE
    })

    isTRUE(ok)
  }

  # First check: maybe the user has already initialized EE elsewhere.
  if (ee_is_working()) {
    message("Google Earth Engine is already initialized and working.")
    return(invisible(TRUE))
  }

  # Try a quiet initialization.
  # Important: quiet = TRUE reduces messages, but rgee may still trigger
  # the asset-home prompt in some environments.
  init_ok <- tryCatch({
    rgee::ee_Initialize(
      user = ee_user,
      drive = drive,
      gcs = gcs,
      quiet = TRUE
    )
    TRUE
  }, error = function(e) {
    FALSE
  })

  # Second check: only accept initialization if a real EE request works.
  if (init_ok && ee_is_working()) {
    message("Google Earth Engine initialized successfully.")
    return(invisible(TRUE))
  }

  if (!interactive()) {
    stop(
      "Google Earth Engine is not initialized or is not working.\n\n",
      "Because this is a non-interactive session, UFEED cannot ask for login.\n",
      "Please run the following manually before using weather_data_source = 'power_ee':\n\n",
      "  rgee::ee_Initialize()\n",
      "  ee$Image('", test_image, "')$getInfo()\n\n",
      "If the second command returns an error, Earth Engine is not fully initialized.",
      call. = FALSE
    )
  }

  if (ask) {
    answer <- utils::menu(
      choices = c("Yes, initialize Google Earth Engine", "No, stop"),
      title = paste(
        "weather_data_source = 'power_ee' requires Google Earth Engine.",
        "Do you want to initialize Earth Engine now?"
      )
    )

    if (answer != 1) {
      stop(
        "Earth Engine initialization cancelled.\n",
        "Use weather_data_source = 'power' or 'power_open_meteo' ",
        "if you do not want to use Earth Engine.",
        call. = FALSE
      )
    }
  }

  message("Initializing Google Earth Engine...")

  init_error <- NULL

  tryCatch({
    rgee::ee_Initialize(
      user = ee_user,
      drive = drive,
      gcs = gcs,
      quiet = FALSE
    )
  }, error = function(e) {
    init_error <<- conditionMessage(e)
  })

  # Final check using an actual public EE image request.
  if (ee_is_working()) {
    message("Google Earth Engine initialized successfully and passed the test request.")
    return(invisible(TRUE))
  }

  stop(
    "Google Earth Engine could not be initialized successfully.\n\n",
    "UFEED tested initialization with:\n",
    "  ee$Image('", test_image, "')$getInfo()\n\n",
    "This test failed, so UFEED will not attempt to download POWER/EE data.\n\n",
    if (!is.null(init_error)) paste0("Original initialization error:\n", init_error, "\n\n") else "",
    "Possible fixes:\n",
    "1. Run `rgee::ee_Initialize()` manually.\n",
    "2. Then test with `ee$Image('", test_image, "')$getInfo()`.\n",
    "3. If rgee asks for an Earth Engine Assets home root, press ESC if you do not want to create one.\n",
    "4. Check that your Google account is registered for Earth Engine.\n",
    "5. Run `rgee::ee_check()` to diagnose the rgee/Python environment.\n\n",
    "Alternative: use weather_data_source = 'power' or 'power_open_meteo' ",
    "to avoid Earth Engine.",
    call. = FALSE
  )
}


UFEED_get_ee <- function() {
  # rgee normally exposes `ee` in the rgee namespace after initialization.
  if (requireNamespace("rgee", quietly = TRUE)) {
    ee_ns <- tryCatch(
      get("ee", envir = asNamespace("rgee"), inherits = FALSE),
      error = function(e) NULL
    )

    if (!is.null(ee_ns)) {
      return(ee_ns)
    }
  }

  # Fallback for users who have `ee` in the global environment.
  if (exists("ee", envir = .GlobalEnv, inherits = FALSE)) {
    return(get("ee", envir = .GlobalEnv))
  }

  stop(
    "Earth Engine object `ee` was not found. ",
    "Run `rgee::ee_Initialize()` first.",
    call. = FALSE
  )
}


UFEED_check_ee_ready <- function(
    test_image = "NASA/NASADEM_HGT/001",
    error_call = TRUE
) {
  ee <- tryCatch(UFEED_get_ee(), error = function(e) NULL)

  if (is.null(ee)) {
    if (isTRUE(error_call)) {
      stop(
        "Google Earth Engine is not initialized. ",
        "Run `rgee::ee_Initialize()` first.",
        call. = FALSE
      )
    }
    return(FALSE)
  }

  ok <- tryCatch({
    ee$Image(test_image)$getInfo()
    TRUE
  }, error = function(e) {
    if (isTRUE(error_call)) {
      stop(
        "Google Earth Engine was found, but it is not working correctly.\n\n",
        "The following test failed:\n",
        "  ee$Image('", test_image, "')$getInfo()\n\n",
        "Original error:\n",
        conditionMessage(e),
        call. = FALSE
      )
    }
    FALSE
  })

  isTRUE(ok)
}

# -----------------------------------------------------------------------------
# 3. Main user-facing functions
# -----------------------------------------------------------------------------

#' Generate historical UFEED features
#'
#' Downloads weather data, attaches soil data, and computes UFEED features
#' for completed historical seasons.
#'
#' @param lon Numeric longitude.
#' @param lat Numeric latitude.
#' @param start_year Integer start year.
#' @param end_year Integer end year.
#' @param weather_data_source Weather source. One of `"power"`, `"power_ee"`, or `"power_open_meteo"`.
#' @param soil_data_source Soil source. One of `"remote"` or `"local"`.
#' @param soil_data_local_dir Local SoilGrids directory if `soil_data_source = "local"`.
#' @param included_module Character vector of feature modules to compute.
#'
#' @return A data frame of UFEED historical features.
#' @export
UFEED_history <- function(
    lon,
    lat,
    start_year,
    end_year,
    weather_data_source = c("power", "power_ee", "power_open_meteo"),
    soil_data_source = c("remote", "local"),
    soil_data_local_dir = "",
    included_module = c(
      "cumsum_features",
      "EWMA_REWMA_features",
      "cumulative_temp_features",
      "season_summary_features"
    )
) {
  weather_data_source <- match.arg(weather_data_source)
  soil_data_source <- match.arg(soil_data_source)
  included_module <- UFEED_validate_modules(included_module)

  current_year <- as.integer(format(Sys.Date(), "%Y"))
  if (any(as.integer(end_year) >= current_year)) {
    stop(
      "`UFEED_history()` only supports completed historical years. ",
      "`end_year` must be smaller than the current year (", current_year, "). ",
      "Use `UFEED_present()` for current-year and near-future data.",
      call. = FALSE
    )
  }

  coords <- UFEED_normalize_coordinates(lon, lat, pairwise = TRUE)
  coords$start_year <- UFEED_recycle_year_arg(start_year, nrow(coords), "start_year")
  coords$end_year <- UFEED_recycle_year_arg(end_year, nrow(coords), "end_year")

  if (any(coords$start_year > coords$end_year)) {
    stop("`start_year` must be <= `end_year` for every coordinate pair.", call. = FALSE)
  }

  if (weather_data_source == "power_ee") {
    ensure_ee_initialized(
      ee_user = NULL,
      ask = interactive(),
      drive = FALSE,
      gcs = FALSE
    )

    UFEED_check_ee_ready()
  }

  message("Getting historical weather data...")
  weather_data <- UFEED_download_weather_for_coordinates(
    coords = coords,
    weather_data_source = weather_data_source,
    parameters = UFEED_WEATHER_PARAMETERS_HISTORY,
    max_retries = 10,
    retry_wait_sec = 2
  )

  message("Computing historical UFEED weather features...")
  UFEED_feature_df <- UFEED_compute_weather_features(
    weather_data = weather_data,
    included_module = included_module,
    cumsum_cols = UFEED_CUMSUM_COLS_HISTORY,
    ewma_rewma_cols = UFEED_EWMA_REWMA_COLS_HISTORY,
    start_filter_date = NULL
  )

  coord_filter <- coords |>
    dplyr::transmute(
      lon = lon,
      lat = lat,
      UFEED_start_date = as.Date(paste0(start_year, "-01-01")),
      UFEED_end_date = as.Date(paste0(end_year, "-12-31"))
    )

  UFEED_feature_df <- UFEED_feature_df |>
    dplyr::left_join(coord_filter, by = c("lon", "lat")) |>
    dplyr::filter(Date >= UFEED_start_date, Date <= UFEED_end_date) |>
    dplyr::select(-UFEED_start_date, -UFEED_end_date, -dplyr::any_of(c("start_year", "end_year")))

  message("Getting soil features...")
  UFEED_soil <- UFEED_get_soil_features(
    lon = coords$lon,
    lat = coords$lat,
    soil_data_source = soil_data_source,
    soil_data_local_dir = soil_data_local_dir,
    pairwise = TRUE
  )
  UFEED_feature_df <- dplyr::left_join(UFEED_feature_df, UFEED_soil, by = c("lon", "lat"))

  UFEED_feature_df <- UFEED_feature_df |>
    UFEED_clean_names() |>
    dplyr::arrange(lon, lat, Date)

  message("Historical UFEED dataframe ready.")
  UFEED_feature_df
}


#' Generate present-season UFEED features
#'
#' Downloads current-year historical weather, recent weather, and forecast weather,
#' then computes present-season UFEED features.
#'
#' @param lon Numeric longitude.
#' @param lat Numeric latitude.
#' @param weather_data_source Weather source. One of `"power"`, `"power_ee"`, or `"power_open_meteo"`.
#' @param soil_data_source Soil source. One of `"remote"` or `"local"`.
#' @param soil_data_local_dir Local SoilGrids directory if `soil_data_source = "local"`.
#' @param included_module Character vector of feature modules to compute.
#'
#' @return A data frame of UFEED present-season features.
#' @export
UFEED_present <- function(
    lon,
    lat,
    weather_data_source = c("power", "power_ee", "power_open_meteo"),
    soil_data_source = c("remote", "local"),
    soil_data_local_dir = "",
    included_module = c(
      "cumsum_features",
      "EWMA_REWMA_features",
      "cumulative_temp_features",
      "season_summary_features"
    )
) {
  weather_data_source <- match.arg(weather_data_source)
  soil_data_source <- match.arg(soil_data_source)
  included_module <- UFEED_validate_modules(included_module)

  coords <- UFEED_normalize_coordinates(lon, lat, pairwise = TRUE)

  # UFEED_present is intentionally fixed to the current calendar year.
  # The weather download functions will still internally pull the needed
  # pre-season window from the previous year, because start_year is the
  # current year.
  current_year <- as.integer(format(Sys.Date(), "%Y"))
  coords$start_year <- rep(current_year, nrow(coords))
  coords$end_year <- rep(current_year, nrow(coords))

  if (weather_data_source == "power_ee") {
    ensure_ee_initialized(
      ee_user = NULL,
      ask = interactive(),
      drive = FALSE,
      gcs = FALSE
    )

    UFEED_check_ee_ready()
  }

  message("Getting selected-source current-year weather backbone...")
  weather_history <- UFEED_download_weather_for_coordinates(
    coords = coords,
    weather_data_source = weather_data_source,
    parameters = UFEED_WEATHER_PARAMETERS_PRESENT,
    max_retries = 10,
    retry_wait_sec = 2
  ) |>
    dplyr::mutate(data_source = paste0("historical_", weather_data_source))

  message("Getting Open-Meteo recent and forecast data...")
  weather_recent_forecast <- UFEED_download_recent_forecast_for_coordinates(
    coords = coords,
    past_days = 9,
    forecast_days = 8,
    weather_model = "era5_seamless",
    soil_model = "best_match",
    soil_na_lon_threshold = -50,
    soil_aggregation = "daily_mean",
    max_retries = 10,
    retry_wait_sec = 2
  ) |>
    dplyr::mutate(data_source = "recent_forecast_open_meteo")

  weather_combined <- dplyr::bind_rows(
    weather_history,
    weather_recent_forecast
  ) |>
    dplyr::mutate(
      Date = as.Date(Date),
      source_priority = dplyr::case_when(
        data_source == "recent_forecast_open_meteo" ~ 1L,
        TRUE ~ 2L
      )
    ) |>
    dplyr::arrange(lon, lat, Date, source_priority) |>
    dplyr::distinct(lon, lat, Date, .keep_all = TRUE) |>
    dplyr::select(-dplyr::any_of(c(
      "source_priority",
      "data_source",
      "data_source_period",
      "start_year",
      "end_year",
      "ALLSKY_SFC_LW_DWN",
      "ALLSKY_SFC_PAR_TOT",
      "CLOUD_AMT"
    ))) |>
    UFEED_add_daily_temp_fluctuation() |>
    dplyr::arrange(lon, lat, Date)

  message("Computing present UFEED weather features...")
  UFEED_feature_df <- UFEED_compute_weather_features(
    weather_data = weather_combined,
    included_module = included_module,
    cumsum_cols = UFEED_CUMSUM_COLS_PRESENT,
    ewma_rewma_cols = UFEED_EWMA_REWMA_COLS_PRESENT,
    start_filter_date = as.Date(paste0(format(Sys.Date(), "%Y"), "-01-01"))
  )

  message("Getting soil features...")
  UFEED_soil <- UFEED_get_soil_features(
    lon = coords$lon,
    lat = coords$lat,
    soil_data_source = soil_data_source,
    soil_data_local_dir = soil_data_local_dir,
    pairwise = TRUE
  )
  UFEED_feature_df <- dplyr::left_join(UFEED_feature_df, UFEED_soil, by = c("lon", "lat"))

  UFEED_feature_df <- UFEED_feature_df |>
    UFEED_clean_names() |>
    dplyr::arrange(lon, lat, Date)

  message("Present UFEED dataframe ready.")
  UFEED_feature_df
}

# -----------------------------------------------------------------------------
# 4. Core orchestration helpers
# -----------------------------------------------------------------------------

UFEED_download_weather_for_coordinates <- function(
    coords,
    weather_data_source,
    parameters,
    max_retries = 10,
    retry_wait_sec = 2
) {
  out <- vector("list", nrow(coords))

  for (i in seq_len(nrow(coords))) {
    lon_i <- coords$lon[i]
    lat_i <- coords$lat[i]
    start_i <- coords$start_year[i]
    end_i <- coords$end_year[i]

    message(sprintf(
      "Weather: lon = %.6f, lat = %.6f, start_year = %d, end_year = %d, source = %s",
      lon_i, lat_i, start_i, end_i, weather_data_source
    ))

    result <- tryCatch({
      if (weather_data_source == "power") {
        get_weather_data_NASA_POWER_ONLY(
          lon = lon_i,
          lat = lat_i,
          start_year = start_i,
          end_year = end_i,
          parameters = parameters,
          max_retries = max_retries,
          retry_wait_sec = retry_wait_sec
        )
      } else if (weather_data_source == "power_open_meteo") {
        get_weather_data_power_open_meteo(
          lon = lon_i,
          lat = lat_i,
          start_year = start_i,
          end_year = end_i,
          parameters = parameters,
          max_retries = max_retries,
          retry_wait_sec = retry_wait_sec
        )
      } else if (weather_data_source == "power_ee") {
        get_weather_data_power_ee(
          lon = lon_i,
          lat = lat_i,
          start_year = start_i,
          end_year = end_i,
          parameters = parameters,
          max_retries = max_retries,
          retry_wait_sec = retry_wait_sec
        )
      } else {
        stop("Unknown weather_data_source: ", weather_data_source, call. = FALSE)
      }
    }, error = function(e) {
      warning(
        sprintf(
          "Failed weather download for lon = %.6f, lat = %.6f, start = %d, end = %d: %s",
          lon_i, lat_i, start_i, end_i, conditionMessage(e)
        ),
        call. = FALSE
      )
      NULL
    })

    if (!is.null(result)) {
      result <- result |>
        dplyr::mutate(
          lon = lon_i,
          lat = lat_i,
          start_year = start_i,
          end_year = end_i
        ) |>
        UFEED_add_daily_temp_fluctuation()
    }

    out[[i]] <- result
  }

  out <- out[!vapply(out, is.null, logical(1))]
  if (length(out) == 0) {
    stop("All weather downloads failed.", call. = FALSE)
  }

  dplyr::bind_rows(out) |>
    dplyr::mutate(Date = as.Date(Date)) |>
    dplyr::arrange(lon, lat, Date)
}

UFEED_download_recent_forecast_for_coordinates <- function(
    coords,
    past_days = 9,
    forecast_days = 8,
    weather_model = "era5_seamless",
    soil_model = "best_match",
    soil_na_lon_threshold = -50,
    soil_aggregation = "daily_mean",
    max_retries = 10,
    retry_wait_sec = 2
) {
  out <- vector("list", nrow(coords))

  for (i in seq_len(nrow(coords))) {
    lon_i <- coords$lon[i]
    lat_i <- coords$lat[i]

    message(sprintf(
      "Recent/forecast weather: lon = %.6f, lat = %.6f",
      lon_i, lat_i
    ))

    result <- tryCatch({
      get_open_meteo_recent_forecast_data(
        lon = lon_i,
        lat = lat_i,
        past_days = past_days,
        forecast_days = forecast_days,
        timezone = "UTC",
        model = weather_model,
        max_retries = max_retries,
        retry_wait_sec = retry_wait_sec
      )
    }, error = function(e) {
      warning(
        sprintf(
          "Failed recent/forecast download for lon = %.6f, lat = %.6f: %s",
          lon_i, lat_i, conditionMessage(e)
        ),
        call. = FALSE
      )
      NULL
    })

    if (!is.null(result)) {
      result <- result |>
        dplyr::mutate(lon = lon_i, lat = lat_i) |>
        UFEED_add_daily_temp_fluctuation()
    }

    out[[i]] <- result
  }

  out <- out[!vapply(out, is.null, logical(1))]
  if (length(out) == 0) {
    stop("All recent/forecast Open-Meteo downloads failed.", call. = FALSE)
  }

  weather_recent_forecast <- dplyr::bind_rows(out) |>
    dplyr::mutate(Date = as.Date(Date)) |>
    dplyr::arrange(lon, lat, Date)

  # Some North America locations can miss daily soil variables in the main
  # Open-Meteo forecast call. For lon <= -50, download hourly soil variables
  # separately with best_match and aggregate them to POWER-style daily columns.
  soil_needed_sites <- coords |>
    dplyr::filter(lon <= soil_na_lon_threshold) |>
    dplyr::distinct(lon, lat)

  if (nrow(soil_needed_sites) > 0) {
    message("Getting Open-Meteo soil fallback for lon <= ", soil_na_lon_threshold, " ...")

    soil_out <- vector("list", nrow(soil_needed_sites))

    for (i in seq_len(nrow(soil_needed_sites))) {
      lon_i <- soil_needed_sites$lon[i]
      lat_i <- soil_needed_sites$lat[i]

      message(sprintf(
        "Recent/forecast soil fallback: lon = %.6f, lat = %.6f",
        lon_i, lat_i
      ))

      soil_result <- tryCatch({
        get_open_meteo_soil_daily_data(
          lon = lon_i,
          lat = lat_i,
          past_days = past_days,
          forecast_days = forecast_days,
          timezone = "UTC",
          model = soil_model,
          aggregation = soil_aggregation,
          max_retries = max_retries,
          retry_wait_sec = retry_wait_sec
        )
      }, error = function(e) {
        warning(
          sprintf(
            "Failed recent/forecast soil fallback for lon = %.6f, lat = %.6f: %s",
            lon_i, lat_i, conditionMessage(e)
          ),
          call. = FALSE
        )
        NULL
      })

      if (!is.null(soil_result)) {
        soil_result <- soil_result |>
          dplyr::mutate(
            lon = lon_i,
            lat = lat_i,
            data_source_soil = "recent_forecast_open_meteo_soil"
          )
      }

      soil_out[[i]] <- soil_result
    }

    soil_out <- soil_out[!vapply(soil_out, is.null, logical(1))]

    if (length(soil_out) > 0) {
      soil_recent_forecast <- dplyr::bind_rows(soil_out) |>
        dplyr::mutate(Date = as.Date(Date))

      for (soil_col in c("TSOIL1", "TSOIL3", "GWETTOP", "GWETROOT")) {
        if (!soil_col %in% names(weather_recent_forecast)) {
          weather_recent_forecast[[soil_col]] <- NA_real_
        }
      }

      weather_recent_forecast <- weather_recent_forecast |>
        dplyr::left_join(
          soil_recent_forecast |>
            dplyr::select(
              Date,
              lon,
              lat,
              TSOIL1_soil = TSOIL1,
              TSOIL3_soil = TSOIL3,
              GWETTOP_soil = GWETTOP,
              GWETROOT_soil = GWETROOT
            ),
          by = c("Date", "lon", "lat")
        ) |>
        dplyr::mutate(
          TSOIL1 = dplyr::coalesce(TSOIL1, TSOIL1_soil),
          TSOIL3 = dplyr::coalesce(TSOIL3, TSOIL3_soil),
          GWETTOP = dplyr::coalesce(GWETTOP, GWETTOP_soil),
          GWETROOT = dplyr::coalesce(GWETROOT, GWETROOT_soil)
        ) |>
        dplyr::select(
          -dplyr::any_of(c(
            "TSOIL1_soil",
            "TSOIL3_soil",
            "GWETTOP_soil",
            "GWETROOT_soil"
          ))
        )
    } else {
      warning(
        "All Open-Meteo soil fallback downloads failed for lon <= ",
        soil_na_lon_threshold,
        ". Keeping the main recent/forecast weather output as-is.",
        call. = FALSE
      )
    }
  }

  weather_recent_forecast |>
    dplyr::arrange(lon, lat, Date)
}

UFEED_get_soil_features <- function(
    lon,
    lat,
    soil_data_source = c("remote", "local"),
    soil_data_local_dir = "",
    pairwise = TRUE
) {
  soil_data_source <- match.arg(soil_data_source)

  if (soil_data_source == "remote") {
    return(UFEED_soil_online(
      lon = lon,
      lat = lat,
      pairwise = pairwise
    ))
  }

  if (soil_data_source == "local") {
    if (is.null(soil_data_local_dir) || !nzchar(soil_data_local_dir)) {
      stop(
        "`soil_data_local_dir` must be provided when soil_data_source = 'local'.",
        call. = FALSE
      )
    }
    if (!dir.exists(soil_data_local_dir)) {
      stop(
        "The local soil directory does not exist: ", soil_data_local_dir,
        call. = FALSE
      )
    }
    return(UFEED_soil_local_database(
      lon = lon,
      lat = lat,
      soil_dir = soil_data_local_dir,
      pairwise = pairwise
    ))
  }

  stop("Unknown soil_data_source: ", soil_data_source, call. = FALSE)
}

UFEED_compute_weather_features <- function(
    weather_data,
    included_module,
    cumsum_cols,
    ewma_rewma_cols,
    start_filter_date = NULL
) {
  weather_data <- weather_data |>
    dplyr::mutate(
      Date = as.Date(Date),
      lon = as.numeric(lon),
      lat = as.numeric(lat)
    ) |>
    UFEED_add_daily_temp_fluctuation() |>
    dplyr::arrange(lon, lat, Date)

  df <- weather_data
  weather_data_EWMA_REWMA <- NULL

  if ("cumsum_features" %in% included_module) {
    message("Computing cumsum features...")
    weather_data_cumsum <- weather_cumsum_features_compute(
      weather_data,
      columns_for_cumsum = cumsum_cols
    )
    df <- UFEED_safe_left_join_features(df, weather_data_cumsum)
  } else {
    message("Skipping cumsum features...")
  }

  if ("EWMA_REWMA_features" %in% included_module) {
    message("Computing EWMA/REWMA features...")
    weather_data_EWMA_REWMA <- weather_EWMA_REWMA_features_compute(
      weather_data,
      columns_for_EWMA_REWMA = ewma_rewma_cols
    )
    df <- UFEED_safe_left_join_features(df, weather_data_EWMA_REWMA)
  } else {
    message("Skipping EWMA/REWMA features...")
  }

  if ("cumulative_temp_features" %in% included_module) {
    message("Computing cumulative temperature features...")
    weather_data_cumulative_temp <- weather_cumulative_temp_features_compute(weather_data)
    df <- UFEED_safe_left_join_features(df, weather_data_cumulative_temp)
  } else {
    message("Skipping cumulative temperature features...")
  }

  if ("season_summary_features" %in% included_module) {
    if (is.null(weather_data_EWMA_REWMA)) {
      warning("EWMA_REWMA data not available. Cannot compute season summary features.", call. = FALSE)
    } else {
      message("Computing season summary features...")
      weather_data_season_summary <- weather_season_summary_compute(weather_data_EWMA_REWMA)
      df <- UFEED_safe_left_join_features(df, weather_data_season_summary)
    }
  } else {
    message("Skipping season summary features...")
  }

  if (!is.null(start_filter_date)) {
    df <- df |>
      dplyr::filter(Date >= as.Date(start_filter_date))
  }

  df |>
    UFEED_remove_duplicate_columns() |>
    dplyr::arrange(lon, lat, Date)
}

# -----------------------------------------------------------------------------
# 5. Weather download functions
# -----------------------------------------------------------------------------

UFEED_prepare_power_parameters <- function(parameters) {
  # User-facing UFEED name stays EVPTRNS.
  # NASA POWER request uses EVLAND instead.
  power_parameters <- parameters

  if ("EVPTRNS" %in% power_parameters) {
    power_parameters[power_parameters == "EVPTRNS"] <- "EVLAND"
  }

  unique(power_parameters)
}

get_weather_data_NASA_POWER_ONLY <- function(
    lon,
    lat,
    start_year,
    end_year,
    parameters = UFEED_WEATHER_PARAMETERS_HISTORY,
    community = "ag",
    max_retries = 10,
    retry_wait_sec = 2
) {
  UFEED_check_required_packages(c("httr", "jsonlite"))

  if (start_year < 1982) {
    stop(
      "start_year must be 1982 or later. NASA POWER daily data is not available before 1981. ",
      "UFEED uses daily weather data from one year before start_year.",
      call. = FALSE
    )
  }

  current_year <- as.integer(format(Sys.Date(), "%Y"))
  if (end_year > current_year) {
    stop("end_year cannot be greater than the current year.", call. = FALSE)
  }

  hemisphere <- ifelse(lat >= 0, "nh", "sh")
  preseason_start <- if (hemisphere == "nh") {
    as.Date(paste0(start_year - 1, "-09-01"))
  } else {
    as.Date(paste0(start_year - 1, "-03-01"))
  }

  if (end_year == current_year) {
    warning(
      "Current year selected. NASA POWER data may lag. Using Sys.Date() - 6 as end_date.",
      call. = FALSE
    )
    end_date <- Sys.Date() - 6
  } else {
    end_date <- as.Date(paste0(end_year, "-12-31"))
  }

  # ------------------------------------------------------------
  # Important change:
  # UFEED requests/output name = EVPTRNS
  # NASA POWER actual parameter = EVLAND
  # ------------------------------------------------------------
  power_parameters <- UFEED_prepare_power_parameters(parameters)

  start_date_fmt <- gsub("-", "", preseason_start)
  end_date_fmt <- gsub("-", "", end_date)
  param_str <- paste(power_parameters, collapse = ",")

  query_url <- paste0(
    "https://power.larc.nasa.gov/api/temporal/daily/point",
    "?start=", start_date_fmt,
    "&end=", end_date_fmt,
    "&latitude=", lat,
    "&longitude=", lon,
    "&community=", community,
    "&parameters=", param_str,
    "&format=JSON&header=true"
  )

  attempt <- 1
  success <- FALSE
  response <- NULL

  while (attempt <= max_retries && !success) {
    response <- try(httr::GET(query_url), silent = TRUE)

    if (inherits(response, "try-error")) {
      message(sprintf("POWER attempt %d: failed to reach server. Retrying...", attempt))
    } else if (httr::status_code(response) == 200) {
      success <- TRUE
    } else if (httr::status_code(response) %in% c(502, 503, 504)) {
      message(sprintf("POWER attempt %d: HTTP %d. Retrying...", attempt, httr::status_code(response)))
    } else {
      stop(
        sprintf(
          "POWER HTTP %d: %s",
          httr::status_code(response),
          httr::http_status(response)$message
        ),
        call. = FALSE
      )
    }

    if (!success) {
      Sys.sleep(retry_wait_sec)
      attempt <- attempt + 1
    }
  }

  if (!success) {
    stop("POWER: all retry attempts failed.", call. = FALSE)
  }

  json_data <- httr::content(response, "text", encoding = "UTF-8")
  parsed <- jsonlite::fromJSON(json_data, flatten = TRUE)
  parameter_block <- parsed$properties$parameter

  if (length(parameter_block) == 0) {
    stop("POWER: no data found for selected parameters.", call. = FALSE)
  }

  date_list <- names(parameter_block[[1]])

  df <- data.frame(
    Date = as.Date(date_list, format = "%Y%m%d"),
    lon = lon,
    lat = lat,
    stringsAsFactors = FALSE
  )

  for (param in names(parameter_block)) {
    df[[param]] <- suppressWarnings(as.numeric(unlist(parameter_block[[param]])))
  }

  # ------------------------------------------------------------
  # Important change:
  # Rename EVLAND data back to EVPTRNS for UFEED compatibility.
  # ------------------------------------------------------------
  if ("EVLAND" %in% names(df)) {
    df$EVPTRNS <- df$EVLAND
    df$EVLAND <- NULL
  }

  df[df == -999] <- NA
  df <- UFEED_add_daily_temp_fluctuation(df)

  attr(df, "power_query_url") <- query_url
  attr(df, "power_requested_parameters") <- power_parameters
  attr(df, "ufeed_requested_parameters") <- parameters

  row.names(df) <- NULL
  df
}

get_weather_data_power_open_meteo <- function(
    lon,
    lat,
    start_year,
    end_year,
    parameters = UFEED_WEATHER_PARAMETERS_HISTORY,
    community = "ag",
    max_retries = 10,
    retry_wait_sec = 2,
    openmeteo_timezone = "UTC",
    openmeteo_model = "era5_seamless"
) {
  UFEED_check_required_packages(c("httr", "jsonlite", "dplyr"))

  if (start_year < 1982) stop("start_year must be 1982 or later.", call. = FALSE)
  current_year <- as.integer(format(Sys.Date(), "%Y"))
  if (end_year > current_year) stop("end_year cannot be greater than the current year.", call. = FALSE)

  hemisphere <- ifelse(lat >= 0, "nh", "sh")
  preseason_start <- if (hemisphere == "nh") {
    as.Date(paste0(start_year - 1, "-09-01"))
  } else {
    as.Date(paste0(start_year - 1, "-03-01"))
  }

  if (end_year == current_year) {
    warning("Current year selected. POWER/Open-Meteo may lag. Using Sys.Date() - 10 as end_date.", call. = FALSE)
    end_date <- Sys.Date() - 10
  } else {
    end_date <- as.Date(paste0(end_year, "-12-31"))
  }

  df_power <- get_weather_data_NASA_POWER_ONLY(
    lon = lon,
    lat = lat,
    start_year = start_year,
    end_year = end_year,
    parameters = parameters,
    community = community,
    max_retries = max_retries,
    retry_wait_sec = retry_wait_sec
  )

  om_map <- c(
    PS                = "surface_pressure_mean",
    WS2M              = "wind_speed_10m_mean",
    WS2M_MAX          = "wind_speed_10m_max",
    WS2M_MIN          = "wind_speed_10m_min",
    WD2M              = "wind_direction_10m_dominant",
    T2M               = "temperature_2m_mean",
    T2M_MAX           = "temperature_2m_max",
    T2M_MIN           = "temperature_2m_min",
    T2MDEW            = "dew_point_2m_mean",
    RH2M              = "relative_humidity_2m_mean",
    PRECTOTCORR       = "precipitation_sum",
    ALLSKY_SFC_SW_DWN = "shortwave_radiation_sum",
    EVPTRNS           = "et0_fao_evapotranspiration_sum",
    CLOUD_AMT         = "cloud_cover_mean",
    TSOIL1            = "soil_temperature_0_to_7cm_mean",
    TSOIL3            = "soil_temperature_7_to_28cm_mean",
    GWETTOP           = "soil_moisture_0_to_7cm_mean",
    GWETROOT          = "soil_moisture_0_to_100cm_mean"
  )

  replace_cols <- intersect(names(om_map), parameters)
  daily_vars <- unique(unname(om_map[replace_cols]))
  df_om <- NULL
  om_url <- NULL

  if (length(daily_vars) > 0) {
    om_url <- paste0(
      "https://archive-api.open-meteo.com/v1/archive",
      "?latitude=", lat,
      "&longitude=", lon,
      "&start_date=", format(preseason_start, "%Y-%m-%d"),
      "&end_date=", format(end_date, "%Y-%m-%d"),
      "&daily=", paste(daily_vars, collapse = ","),
      "&timezone=", openmeteo_timezone,
      "&models=", openmeteo_model
    )

    attempt <- 1
    success <- FALSE
    resp_text <- NULL

    while (attempt <= max_retries && !success) {
      resp <- try(httr::GET(om_url), silent = TRUE)
      if (inherits(resp, "try-error")) {
        message(sprintf("Open-Meteo archive attempt %d: server unreachable. Retrying...", attempt))
      } else if (httr::status_code(resp) == 200) {
        success <- TRUE
        resp_text <- httr::content(resp, "text", encoding = "UTF-8")
      } else if (httr::status_code(resp) %in% c(502, 503, 504)) {
        message(sprintf("Open-Meteo archive attempt %d: HTTP %d. Retrying...", attempt, httr::status_code(resp)))
      } else {
        stop(sprintf("Open-Meteo archive HTTP %d: %s", httr::status_code(resp), httr::http_status(resp)$message), call. = FALSE)
      }

      if (!success) {
        Sys.sleep(retry_wait_sec)
        attempt <- attempt + 1
      }
    }

    if (!success) stop("Open-Meteo archive: all retry attempts failed.", call. = FALSE)

    om_parsed <- jsonlite::fromJSON(resp_text, flatten = TRUE)
    if (!is.null(om_parsed$daily) && !is.null(om_parsed$daily$time)) {
      d <- om_parsed$daily
      u <- om_parsed$daily_units
      df_om <- data.frame(Date = as.Date(d$time), stringsAsFactors = FALSE)

      getv <- function(vn) {
        if (!is.null(d[[vn]])) return(suppressWarnings(as.numeric(d[[vn]])))
        rep(NA_real_, length(d$time))
      }

      for (nm in replace_cols) {
        df_om[[nm]] <- getv(om_map[[nm]])
      }

      if ("PS" %in% names(df_om) && !is.null(u$surface_pressure_mean)) {
        if (tolower(u$surface_pressure_mean) %in% c("hpa", "mbar")) df_om$PS <- df_om$PS / 10
      }

      wind_cols <- intersect(c("WS2M", "WS2M_MAX", "WS2M_MIN"), names(df_om))
      wind_unit <- u$wind_speed_10m_mean
      if (!is.null(wind_unit) && tolower(wind_unit) %in% c("km/h", "kmh", "km h-1")) {
        df_om[wind_cols] <- lapply(df_om[wind_cols], function(x) x / 3.6)
      }
    } else {
      warning("Open-Meteo archive returned no daily data. Keeping NASA POWER values.", call. = FALSE)
    }
  }

  df <- df_power
  if (!is.null(df_om)) {
    df <- dplyr::left_join(df_power, df_om, by = "Date", suffix = c("", ".om"))
    for (nm in replace_cols) {
      om_nm <- paste0(nm, ".om")
      if (om_nm %in% names(df)) {
        df[[nm]] <- dplyr::if_else(!is.na(df[[om_nm]]), df[[om_nm]], df[[nm]])
      }
    }
    df <- df |>
      dplyr::select(-dplyr::any_of(paste0(replace_cols, ".om")))
  }

  df <- UFEED_add_daily_temp_fluctuation(df) |>
    dplyr::arrange(Date)

  attr(df, "open_meteo_url") <- om_url
  row.names(df) <- NULL
  df
}

get_open_meteo_recent_forecast_data <- function(
    lon,
    lat,
    past_days = 9,
    forecast_days = 8,
    timezone = "UTC",
    model = "era5_seamless",
    max_retries = 10,
    retry_wait_sec = 2
) {
  UFEED_check_required_packages(c("httr", "jsonlite", "dplyr"))

  om_map <- c(
    PS                = "surface_pressure_mean",
    WS2M              = "wind_speed_10m_mean",
    WS2M_MAX          = "wind_speed_10m_max",
    WS2M_MIN          = "wind_speed_10m_min",
    WD2M              = "wind_direction_10m_dominant",
    T2M               = "temperature_2m_mean",
    T2M_MAX           = "temperature_2m_max",
    T2M_MIN           = "temperature_2m_min",
    T2MDEW            = "dew_point_2m_mean",
    RH2M              = "relative_humidity_2m_mean",
    PRECTOTCORR       = "precipitation_sum",
    ALLSKY_SFC_SW_DWN = "shortwave_radiation_sum",
    EVPTRNS           = "et0_fao_evapotranspiration_sum",
    TSOIL1            = "soil_temperature_0_to_7cm_mean",
    TSOIL3            = "soil_temperature_7_to_28cm_mean",
    GWETTOP           = "soil_moisture_0_to_7cm_mean",
    GWETROOT          = "soil_moisture_0_to_100cm_mean"
  )

  daily_vars <- unname(om_map)
  query_url <- paste0(
    "https://api.open-meteo.com/v1/forecast",
    "?latitude=", lat,
    "&longitude=", lon,
    "&daily=", paste(daily_vars, collapse = ","),
    "&past_days=", past_days,
    "&forecast_days=", forecast_days,
    "&timezone=", timezone
  )

  attempt <- 1
  success <- FALSE
  resp_text <- NULL

  while (attempt <= max_retries && !success) {
    response <- try(httr::GET(query_url), silent = TRUE)
    if (inherits(response, "try-error")) {
      message(sprintf("Open-Meteo forecast attempt %d: server unreachable. Retrying...", attempt))
    } else if (httr::status_code(response) == 200) {
      success <- TRUE
      resp_text <- httr::content(response, "text", encoding = "UTF-8")
    } else if (httr::status_code(response) %in% c(502, 503, 504)) {
      message(sprintf("Open-Meteo forecast attempt %d: HTTP %d. Retrying...", attempt, httr::status_code(response)))
    } else {
      stop(sprintf("Open-Meteo forecast HTTP %d: %s", httr::status_code(response), httr::http_status(response)$message), call. = FALSE)
    }

    if (!success) {
      Sys.sleep(retry_wait_sec)
      attempt <- attempt + 1
    }
  }

  if (!success) stop("Open-Meteo forecast: all retry attempts failed.", call. = FALSE)

  parsed <- jsonlite::fromJSON(resp_text, flatten = TRUE)
  if (is.null(parsed$daily) || is.null(parsed$daily$time)) {
    stop("Open-Meteo forecast: no daily data returned.", call. = FALSE)
  }

  d <- parsed$daily
  u <- parsed$daily_units
  df <- data.frame(
    Date = as.Date(d$time),
    lon = lon,
    lat = lat,
    stringsAsFactors = FALSE
  )

  getv <- function(vn) {
    if (!is.null(d[[vn]])) return(suppressWarnings(as.numeric(d[[vn]])))
    rep(NA_real_, length(d$time))
  }

  for (nm in names(om_map)) {
    df[[nm]] <- getv(om_map[[nm]])
  }

  if ("PS" %in% names(df) && !is.null(u$surface_pressure_mean)) {
    if (tolower(u$surface_pressure_mean) %in% c("hpa", "mbar")) df$PS <- df$PS / 10
  }

  wind_cols <- intersect(c("WS2M", "WS2M_MAX", "WS2M_MIN"), names(df))
  wind_unit <- u$wind_speed_10m_mean
  if (!is.null(wind_unit) && tolower(wind_unit) %in% c("km/h", "kmh", "km h-1")) {
    df[wind_cols] <- lapply(df[wind_cols], function(x) x / 3.6)
  }

  df <- UFEED_add_daily_temp_fluctuation(df)

  today <- Sys.Date()
  df <- df |>
    dplyr::mutate(
      data_source_period = dplyr::case_when(
        Date < today ~ "recent_past",
        Date == today ~ "today",
        Date > today ~ "forecast"
      )
    ) |>
    dplyr::arrange(Date)

  attr(df, "open_meteo_url") <- query_url
  attr(df, "open_meteo_requested_model") <- model
  row.names(df) <- NULL
  df
}

get_open_meteo_soil_daily_data <- function(
    lon, lat,
    past_days = 9,
    forecast_days = 8,  # today + next 7 days
    timezone = "UTC",
    model = "best_match",
    aggregation = c("daily_mean", "single_hour"),
    sample_hour = 9,
    max_retries = 10,
    retry_wait_sec = 2
) {

  # ---- deps ----
  if (!requireNamespace("httr", quietly = TRUE)) stop("Install httr")
  if (!requireNamespace("jsonlite", quietly = TRUE)) stop("Install jsonlite")
  if (!requireNamespace("dplyr", quietly = TRUE)) stop("Install dplyr")

  aggregation <- match.arg(aggregation)

  # ---- Open-Meteo hourly soil variables ----
  # Current docs use "_to_"; fallback below handles older API spelling if needed.
  soil_vars <- c(
    "soil_temperature_0cm",
    "soil_temperature_6cm",
    "soil_temperature_18cm",
    "soil_temperature_54cm",
    "soil_moisture_0_to_1cm",
    "soil_moisture_1_to_3cm",
    "soil_moisture_3_to_9cm",
    "soil_moisture_9_to_27cm",
    "soil_moisture_27_to_81cm"
  )

  soil_vars_fallback <- c(
    "soil_temperature_0cm",
    "soil_temperature_6cm",
    "soil_temperature_18cm",
    "soil_temperature_54cm",
    "soil_moisture_0_1cm",
    "soil_moisture_1_3cm",
    "soil_moisture_3_9cm",
    "soil_moisture_9_27cm",
    "soil_moisture_27_81cm"
  )

  build_url <- function(vars) {
    paste0(
      "https://api.open-meteo.com/v1/forecast",
      "?latitude=", lat,
      "&longitude=", lon,
      "&hourly=", paste(vars, collapse = ","),
      "&past_days=", past_days,
      "&forecast_days=", forecast_days,
      "&timezone=", timezone,
      "&models=", model
    )
  }

  query_url <- build_url(soil_vars)

  # ---- helper: GET with retry ----
  get_with_retry <- function(url) {
    attempt <- 1
    success <- FALSE
    resp_text <- NULL
    last_status <- NA_integer_
    last_message <- NULL

    while (attempt <= max_retries && !success) {
      response <- try(httr::GET(url), silent = TRUE)

      if (inherits(response, "try-error")) {
        message(sprintf("Open-Meteo attempt %d: server unreachable. Retrying...", attempt))
      } else if (httr::status_code(response) == 200) {
        success <- TRUE
        resp_text <- httr::content(response, "text", encoding = "UTF-8")
      } else if (httr::status_code(response) %in% c(502, 503, 504)) {
        message(sprintf(
          "Open-Meteo attempt %d: HTTP %d. Retrying...",
          attempt,
          httr::status_code(response)
        ))
      } else {
        last_status <- httr::status_code(response)
        last_message <- httr::content(response, "text", encoding = "UTF-8")
        break
      }

      if (!success) {
        Sys.sleep(retry_wait_sec)
        attempt <- attempt + 1
      }
    }

    list(
      success = success,
      text = resp_text,
      status = last_status,
      message = last_message
    )
  }

  # ---- first try current variable names ----
  res <- get_with_retry(query_url)

  # ---- fallback if API rejects "_to_" variable names ----
  used_fallback_names <- FALSE

  if (!res$success) {
    fallback_url <- build_url(soil_vars_fallback)
    res2 <- get_with_retry(fallback_url)

    if (res2$success) {
      res <- res2
      query_url <- fallback_url
      used_fallback_names <- TRUE
    } else {
      stop(sprintf(
        "Open-Meteo failed. First status/message: HTTP %s: %s",
        res$status,
        res$message
      ))
    }
  }

  # ---- parse ----
  parsed <- jsonlite::fromJSON(res$text, flatten = TRUE)

  if (is.null(parsed$hourly) || is.null(parsed$hourly$time)) {
    stop("Open-Meteo: no hourly soil data returned.")
  }

  h <- parsed$hourly

  # ---- helper to read variable regardless of naming style ----
  get_hourly_var <- function(name_to, name_fallback = NULL) {
    if (!is.null(h[[name_to]])) {
      return(as.numeric(h[[name_to]]))
    }
    if (!is.null(name_fallback) && !is.null(h[[name_fallback]])) {
      return(as.numeric(h[[name_fallback]]))
    }
    rep(NA_real_, length(h$time))
  }

  df_hourly <- data.frame(
    DateTime = h$time,
    Date = as.Date(substr(h$time, 1, 10)),
    hour = as.integer(substr(h$time, 12, 13)),
    lon = lon,
    lat = lat,
    soil_temperature_0cm = get_hourly_var("soil_temperature_0cm"),
    soil_temperature_6cm = get_hourly_var("soil_temperature_6cm"),
    soil_temperature_18cm = get_hourly_var("soil_temperature_18cm"),
    soil_temperature_54cm = get_hourly_var("soil_temperature_54cm"),
    soil_moisture_0_1cm = get_hourly_var("soil_moisture_0_to_1cm", "soil_moisture_0_1cm"),
    soil_moisture_1_3cm = get_hourly_var("soil_moisture_1_to_3cm", "soil_moisture_1_3cm"),
    soil_moisture_3_9cm = get_hourly_var("soil_moisture_3_to_9cm", "soil_moisture_3_9cm"),
    soil_moisture_9_27cm = get_hourly_var("soil_moisture_9_to_27cm", "soil_moisture_9_27cm"),
    soil_moisture_27_81cm = get_hourly_var("soil_moisture_27_to_81cm", "soil_moisture_27_81cm"),
    stringsAsFactors = FALSE
  )

  # ---- aggregate hourly to daily ----
  if (aggregation == "daily_mean") {

    df_daily_raw <- df_hourly |>
      dplyr::group_by(Date, lon, lat) |>
      dplyr::summarise(
        soil_temperature_0cm = mean(soil_temperature_0cm, na.rm = TRUE),
        soil_temperature_6cm = mean(soil_temperature_6cm, na.rm = TRUE),
        soil_temperature_18cm = mean(soil_temperature_18cm, na.rm = TRUE),
        soil_temperature_54cm = mean(soil_temperature_54cm, na.rm = TRUE),
        soil_moisture_0_1cm = mean(soil_moisture_0_1cm, na.rm = TRUE),
        soil_moisture_1_3cm = mean(soil_moisture_1_3cm, na.rm = TRUE),
        soil_moisture_3_9cm = mean(soil_moisture_3_9cm, na.rm = TRUE),
        soil_moisture_9_27cm = mean(soil_moisture_9_27cm, na.rm = TRUE),
        soil_moisture_27_81cm = mean(soil_moisture_27_81cm, na.rm = TRUE),
        .groups = "drop"
      )

  } else {

    df_daily_raw <- df_hourly |>
      dplyr::filter(hour == sample_hour) |>
      dplyr::group_by(Date, lon, lat) |>
      dplyr::summarise(
        soil_temperature_0cm = dplyr::first(soil_temperature_0cm),
        soil_temperature_6cm = dplyr::first(soil_temperature_6cm),
        soil_temperature_18cm = dplyr::first(soil_temperature_18cm),
        soil_temperature_54cm = dplyr::first(soil_temperature_54cm),
        soil_moisture_0_1cm = dplyr::first(soil_moisture_0_1cm),
        soil_moisture_1_3cm = dplyr::first(soil_moisture_1_3cm),
        soil_moisture_3_9cm = dplyr::first(soil_moisture_3_9cm),
        soil_moisture_9_27cm = dplyr::first(soil_moisture_9_27cm),
        soil_moisture_27_81cm = dplyr::first(soil_moisture_27_81cm),
        .groups = "drop"
      )
  }

  # ---- construct POWER-style variables ----
  df_daily <- df_daily_raw |>
    dplyr::mutate(
      # TSOIL1: approximate 0-7 cm using 0 and 6 cm soil temp
      TSOIL1 = rowMeans(
        cbind(soil_temperature_0cm, soil_temperature_6cm),
        na.rm = TRUE
      ),

      # TSOIL3: midpoint of 7-28 cm is about 17.5 cm, so use 18 cm
      TSOIL3 = soil_temperature_18cm,

      # GWETTOP: weighted 0-7 cm approximation
      GWETTOP = (
        1 * soil_moisture_0_1cm +
          2 * soil_moisture_1_3cm +
          4 * soil_moisture_3_9cm
      ) / 7,

      # GWETROOT: approximate 0-100 cm.
      # Open-Meteo only gives down to 81 cm, so 81-100 cm is assumed
      # equal to the 27-81 cm layer.
      GWETROOT = (
        1 * soil_moisture_0_1cm +
          2 * soil_moisture_1_3cm +
          6 * soil_moisture_3_9cm +
          18 * soil_moisture_9_27cm +
          73 * soil_moisture_27_81cm
      ) / 100,

      data_source_period = dplyr::case_when(
        Date < Sys.Date()  ~ "recent_past",
        Date == Sys.Date() ~ "today",
        Date > Sys.Date()  ~ "forecast"
      )
    ) |>
    dplyr::select(
      Date, lon, lat,
      TSOIL1, TSOIL3, GWETTOP, GWETROOT,
      data_source_period
    ) |>
    dplyr::arrange(Date)

  attr(df_daily, "open_meteo_url") <- query_url
  attr(df_daily, "aggregation") <- aggregation
  attr(df_daily, "sample_hour") <- ifelse(aggregation == "single_hour", sample_hour, NA_integer_)
  attr(df_daily, "used_fallback_variable_names") <- used_fallback_names
  attr(df_daily, "soil_assumptions") <- paste(
    "TSOIL1 = mean of 0cm and 6cm soil temperature;",
    "TSOIL3 = 18cm soil temperature;",
    "GWETTOP = weighted 0-7cm using 0-1, 1-3, and 3-9cm layers;",
    "GWETROOT = weighted 0-100cm approximation; 81-100cm assumed equal to 27-81cm."
  )

  row.names(df_daily) <- NULL
  df_daily
}

get_weather_data_power_ee <- function(
    lon,
    lat,
    start_year,
    end_year,
    parameters = UFEED_WEATHER_PARAMETERS_HISTORY,
    community = "ag",
    max_retries = 10,
    retry_wait_sec = 2,
    ee_scale = 10000,
    dem_scale_site = 30,
    gamma = -0.0065,
    buf_fallback_m = 10000,
    chunk_years = 3,
    ee_timeout_sec = 300
) {
  UFEED_check_required_packages(c("httr", "jsonlite", "readr", "dplyr", "rgee"))

  if (start_year < 1982) stop("start_year must be 1982 or later.", call. = FALSE)
  current_year <- as.integer(format(Sys.Date(), "%Y"))
  if (end_year > current_year) stop("end_year cannot be greater than the current year.", call. = FALSE)

  df_power <- get_weather_data_NASA_POWER_ONLY(
    lon = lon,
    lat = lat,
    start_year = start_year,
    end_year = end_year,
    parameters = parameters,
    community = community,
    max_retries = max_retries,
    retry_wait_sec = retry_wait_sec
  )

  ee <- UFEED_get_ee()

  pt <- ee$Geometry$Point(list(lon, lat))
  pt_buf <- pt$buffer(as.numeric(buf_fallback_m))

  reduce_with_fallback <- function(img, key, geom_pt, geom_buf, scale) {
    v_pt <- img$reduceRegion(
      reducer = ee$Reducer$mean(),
      geometry = geom_pt,
      scale = scale,
      bestEffort = TRUE,
      maxPixels = 1e9
    )

    is_null <- ee$Algorithms$IsEqual(v_pt$get(key), NULL)

    v_buf <- img$reduceRegion(
      reducer = ee$Reducer$mean(),
      geometry = geom_buf,
      scale = scale,
      bestEffort = TRUE,
      maxPixels = 1e9
    )

    ee$Dictionary(ee$Algorithms$If(is_null, v_buf, v_pt))
  }

  dem <- ee$Image("USGS/SRTMGL1_003")$select("elevation")
  z_site_dict <- reduce_with_fallback(dem, "elevation", pt, pt_buf, dem_scale_site)
  z_grid_dict <- reduce_with_fallback(dem, "elevation", pt, pt_buf, ee_scale)

  z_site <- z_site_dict$get("elevation")
  z_grid <- z_grid_dict$get("elevation")
  dz <- ee$Number(z_site)$subtract(ee$Number(z_grid))
  deltaT <- ee$Number(gamma)$multiply(dz)

  ee_band_map_needed <- c(
    "temperature_2m", "temperature_2m_min", "temperature_2m_max",
    "dewpoint_temperature_2m",
    "surface_pressure",
    "total_precipitation_sum",
    "soil_temperature_level_1", "soil_temperature_level_3",
    "volumetric_soil_water_layer_1",
    "volumetric_soil_water_layer_2",
    "volumetric_soil_water_layer_3",
    "volumetric_soil_water_layer_4"
  )

  download_fc_csv_local <- function(
      fc,
      out_csv,
      max_retries = 5,
      retry_wait_sec = 5,
      timeout_sec = 300
  ) {
    url <- tryCatch({
      fc$getDownloadURL("csv")
    }, error = function(e) {
      stop(
        "Earth Engine failed while creating the download URL. ",
        "This may indicate that EE is stuck, disconnected, or the request is too large.\n",
        "Original error: ", conditionMessage(e),
        call. = FALSE
      )
    })

    attempt <- 1
    while (attempt <= max_retries) {
      message(sprintf("EE CSV download attempt %d/%d...", attempt, max_retries))
      res <- tryCatch({
        httr::GET(
          url,
          httr::timeout(timeout_sec),
          httr::write_disk(out_csv, overwrite = TRUE)
        )
      }, error = function(e) e)

      if (!inherits(res, "error") && httr::status_code(res) == 200) {
        return(readr::read_csv(out_csv, show_col_types = FALSE))
      }

      if (inherits(res, "error")) {
        message("EE download error: ", conditionMessage(res))
      } else {
        message("EE download HTTP status: ", httr::status_code(res))
      }

      if (attempt < max_retries) {
        message(sprintf("Retrying in %d seconds...", retry_wait_sec))
        Sys.sleep(retry_wait_sec)
      }
      attempt <- attempt + 1
    }

    stop(
      "Earth Engine CSV download failed after ", max_retries,
      " attempts. Try reducing `chunk_years`, checking EE login, or using another weather source.",
      call. = FALSE
    )
  }

  start_chunk_year <- start_year - 1L
  chunk_starts <- seq.int(start_chunk_year, end_year, by = as.integer(chunk_years))
  chunk_ends <- pmin(chunk_starts + as.integer(chunk_years) - 1L, end_year)
  ee_all <- vector("list", length(chunk_starts))

  for (i in seq_along(chunk_starts)) {
    s <- as.Date(sprintf("%d-01-01", chunk_starts[i]))
    e_inclusive <- as.Date(sprintf("%d-12-31", chunk_ends[i]))
    e_exclusive <- e_inclusive + 1

    message(sprintf("EE: downloading %s to %s ...", s, e_inclusive))

    ee_ic <- ee$ImageCollection("ECMWF/ERA5_LAND/DAILY_AGGR")$
      filterDate(format(s, "%Y-%m-%d"), format(e_exclusive, "%Y-%m-%d"))$
      select(ee_band_map_needed)

    fc <- ee$FeatureCollection(
      ee_ic$map(function(img) {
        tmean_C <- img$select("temperature_2m")$subtract(273.15)$add(deltaT)
        tmin_C <- img$select("temperature_2m_min")$subtract(273.15)$add(deltaT)
        tmax_C <- img$select("temperature_2m_max")$subtract(273.15)$add(deltaT)
        tdew_C <- img$select("dewpoint_temperature_2m")$subtract(273.15)
        tsoil1_C <- img$select("soil_temperature_level_1")$subtract(273.15)
        tsoil3_C <- img$select("soil_temperature_level_3")$subtract(273.15)
        prcp_mm <- img$select("total_precipitation_sum")$multiply(1000)
        ps_kPa <- img$select("surface_pressure")$divide(1000)

        sw1 <- img$select("volumetric_soil_water_layer_1")
        sw2 <- img$select("volumetric_soil_water_layer_2")
        sw3 <- img$select("volumetric_soil_water_layer_3")
        sw4 <- img$select("volumetric_soil_water_layer_4")
        gwetroot <- ee$Image$cat(list(sw1, sw2, sw3, sw4))$reduce(ee$Reducer$mean())

        pack <- ee$Image$cat(list(
          tmean_C, tmin_C, tmax_C, tdew_C,
          prcp_mm, ps_kPa,
          tsoil1_C, tsoil3_C,
          sw1, gwetroot
        ))$rename(c(
          "T2M", "T2M_MIN", "T2M_MAX", "T2MDEW",
          "PRECTOTCORR", "PS",
          "TSOIL1", "TSOIL3",
          "GWETTOP", "GWETROOT"
        ))

        v <- reduce_with_fallback(
          img = pack,
          key = "T2M",
          geom_pt = pt,
          geom_buf = pt_buf,
          scale = ee_scale
        )

        ee$Feature(NULL, list(
          Date = ee$Date(img$get("system:time_start"))$format("YYYY-MM-dd"),
          T2M = v$get("T2M"),
          T2M_MIN = v$get("T2M_MIN"),
          T2M_MAX = v$get("T2M_MAX"),
          T2MDEW = v$get("T2MDEW"),
          PRECTOTCORR = v$get("PRECTOTCORR"),
          PS = v$get("PS"),
          TSOIL1 = v$get("TSOIL1"),
          TSOIL3 = v$get("TSOIL3"),
          GWETTOP = v$get("GWETTOP"),
          GWETROOT = v$get("GWETROOT")
        ))
      })
    )

    tmp_csv <- file.path(tempdir(), sprintf("ee_point_%d_%d.csv", chunk_starts[i], chunk_ends[i]))
    chunk_df <- download_fc_csv_local(
      fc = fc,
      out_csv = tmp_csv,
      max_retries = max_retries,
      retry_wait_sec = retry_wait_sec,
      timeout_sec = ee_timeout_sec
    )

    chunk_df$Date <- as.Date(chunk_df$Date)
    for (cc in setdiff(names(chunk_df), "Date")) {
      chunk_df[[cc]] <- suppressWarnings(as.numeric(chunk_df[[cc]]))
    }
    ee_all[[i]] <- chunk_df
  }

  df_ee <- dplyr::bind_rows(ee_all) |>
    dplyr::arrange(Date) |>
    dplyr::distinct(Date, .keep_all = TRUE)

  replace_cols <- intersect(
    c("T2M", "T2M_MIN", "T2M_MAX", "T2MDEW", "PRECTOTCORR", "PS", "TSOIL1", "TSOIL3", "GWETTOP", "GWETROOT"),
    names(df_power)
  )

  df <- df_power |>
    dplyr::left_join(df_ee, by = "Date", suffix = c("", ".ee"))

  for (nm in replace_cols) {
    ee_nm <- paste0(nm, ".ee")
    if (ee_nm %in% names(df)) df[[nm]] <- df[[ee_nm]]
  }

  df <- df |>
    dplyr::select(-dplyr::any_of(paste0(replace_cols, ".ee"))) |>
    dplyr::select(-dplyr::any_of(c(".geo", "system:index"))) |>
    UFEED_add_daily_temp_fluctuation() |>
    dplyr::arrange(Date)

  row.names(df) <- NULL
  df
}

# -----------------------------------------------------------------------------
# 6. Weather feature functions
# -----------------------------------------------------------------------------

weather_cumsum_features_compute <- function(
    weather_data,
    columns_for_cumsum = UFEED_CUMSUM_COLS_HISTORY,
    max_missing_prop = 0.10
) {
  UFEED_check_required_packages(c("dplyr", "lubridate", "tidyr"))

  required_cols <- c("Date", "lon", "lat", columns_for_cumsum)
  missing_cols <- setdiff(required_cols, names(weather_data))
  if (length(missing_cols) > 0) {
    stop("Missing columns for cumsum features: ", paste(missing_cols, collapse = ", "), call. = FALSE)
  }

  safe_cumsum <- function(x) {
    if (mean(is.na(x)) > max_missing_prop) {
      rep(NA_real_, length(x))
    } else {
      cumsum(replace(x, is.na(x), 0))
    }
  }

  weather_data_cumsum <- weather_data |>
    dplyr::select(Date, lon, lat, dplyr::all_of(columns_for_cumsum)) |>
    dplyr::mutate(Date = as.Date(Date)) |>
    dplyr::arrange(lon, lat, Date) |>
    dplyr::group_by(lon, lat) |>
    dplyr::mutate(
      Hemisphere = ifelse(lat >= 0, "nh", "sh"),
      Date_original = Date,
      Date_shifted = Date + dplyr::if_else(Hemisphere == "sh", 183L, 0L),
      Month = lubridate::month(Date_shifted),
      dormant_season = dplyr::case_when(
        Month %in% 9:12 ~ paste0(lubridate::year(Date_shifted), "-", lubridate::year(Date_shifted) + 1),
        Month %in% 1:8 ~ paste0(lubridate::year(Date_shifted) - 1, "-", lubridate::year(Date_shifted))
      ),
      growth_season = paste0(lubridate::year(Date_shifted), "-", lubridate::year(Date_shifted) + 1)
    ) |>
    dplyr::ungroup() |>
    dplyr::group_by(lon, lat, growth_season) |>
    dplyr::arrange(Date_shifted, .by_group = TRUE) |>
    dplyr::mutate(
      dplyr::across(
        .cols = dplyr::all_of(columns_for_cumsum),
        .fns = ~ safe_cumsum(.x),
        .names = "{.col}_y2d"
      )
    ) |>
    dplyr::ungroup() |>
    dplyr::group_by(lon, lat, dormant_season) |>
    dplyr::arrange(Date_shifted, .by_group = TRUE) |>
    dplyr::mutate(
      dplyr::across(
        .cols = dplyr::all_of(columns_for_cumsum),
        .fns = ~ safe_cumsum(.x),
        .names = "{.col}_dormant2d"
      )
    ) |>
    dplyr::ungroup()

  dormant_cols <- grep("_dormant2d$", names(weather_data_cumsum), value = TRUE)

  if (length(dormant_cols) > 0) {
    weather_data_cumsum <- weather_data_cumsum |>
      dplyr::group_by(lon, lat, dormant_season) |>
      dplyr::arrange(Date_shifted, .by_group = TRUE) |>
      dplyr::mutate(
        dplyr::across(
          .cols = dplyr::all_of(dormant_cols),
          .fns = ~ {
            season_end_year <- as.integer(substr(dplyr::first(dormant_season), 6, 9))
            cap_date <- as.Date(paste0(season_end_year, "-04-30"))
            cap_date_shifted <- if (dplyr::first(Hemisphere) == "sh") cap_date + 183L else cap_date
            cap_val <- .x[Date_shifted == cap_date_shifted][1]
            if (length(cap_val) == 0 || is.na(cap_val)) cap_val <- NA_real_
            dplyr::if_else(Date_shifted > cap_date_shifted, cap_val, .x)
          }
        )
      ) |>
      dplyr::ungroup()
  }

  weather_data_cumsum |>
    dplyr::transmute(
      Date = Date_original,
      lon = lon,
      lat = lat,
      dplyr::across(dplyr::matches("_y2d$|_dormant2d$"))
    ) |>
    dplyr::arrange(lon, lat, Date)
}

weather_EWMA_REWMA_features_compute <- function(
    weather_data,
    columns_for_EWMA_REWMA = UFEED_EWMA_REWMA_COLS_HISTORY,
    EWMA_REWMA_windows = c(2, 3, 4, 5, 6, 7, 10, 14, 21, 30, 45, 60, 90),
    max_missing_prop = 0.5
) {
  UFEED_check_required_packages(c("dplyr"))

  required_cols <- c("Date", "lon", "lat", columns_for_EWMA_REWMA)
  missing_cols <- setdiff(required_cols, names(weather_data))
  if (length(missing_cols) > 0) {
    stop("Missing columns for EWMA/REWMA features: ", paste(missing_cols, collapse = ", "), call. = FALSE)
  }

  ewma_skipna_window <- function(x, window, max_missing_prop = 0.5) {
    x <- as.numeric(x)
    x[!is.finite(x)] <- NA_real_
    L <- length(x)
    out <- rep(NA_real_, L)
    if (L == 0L) return(out)

    for (i in seq_len(L)) {
      start_i <- max(1L, i - window + 1L)
      x_window <- x[start_i:i]
      missing_prop <- mean(is.na(x_window))
      if (missing_prop > max_missing_prop) next

      valid_idx <- !is.na(x_window)
      if (!any(valid_idx)) next

      n_window <- length(x_window)
      alpha <- 2 / (n_window + 1)
      weights <- (1 - alpha)^((n_window - 1):0)
      weights <- weights[valid_idx] / sum(weights[valid_idx])
      out[i] <- sum(x_window[valid_idx] * weights)
    }
    out
  }

  rewma_skipna_window <- function(x, window, max_missing_prop = 0.5) {
    x <- as.numeric(x)
    x[!is.finite(x)] <- NA_real_
    L <- length(x)
    out <- rep(NA_real_, L)
    if (L == 0L) return(out)

    for (i in seq_len(L)) {
      end_i <- min(L, i + window - 1L)
      x_window <- x[i:end_i]
      missing_prop <- mean(is.na(x_window))
      if (missing_prop > max_missing_prop) next

      valid_idx <- !is.na(x_window)
      if (!any(valid_idx)) next

      n_window <- length(x_window)
      alpha <- 2 / (n_window + 1)
      weights <- (1 - alpha)^(0:(n_window - 1))
      weights <- weights[valid_idx] / sum(weights[valid_idx])
      out[i] <- sum(x_window[valid_idx] * weights)
    }
    out
  }

  compute_one_site <- function(dat) {
    dat <- dat |>
      dplyr::arrange(Date) |>
      dplyr::mutate(
        dplyr::across(
          dplyr::all_of(columns_for_EWMA_REWMA),
          ~ suppressWarnings(as.numeric(.x))
        )
      )

    out <- dat |>
      dplyr::select(Date, lon, lat)

    for (col in columns_for_EWMA_REWMA) {
      for (window in EWMA_REWMA_windows) {
        out[[paste0(col, "_EWMA_", window)]] <- ewma_skipna_window(dat[[col]], window, max_missing_prop)
        out[[paste0(col, "_REWMA_", window)]] <- rewma_skipna_window(dat[[col]], window, max_missing_prop)
      }
    }
    out
  }

  split(weather_data, interaction(weather_data$lon, weather_data$lat, drop = TRUE)) |>
    lapply(compute_one_site) |>
    dplyr::bind_rows() |>
    dplyr::arrange(lon, lat, Date)
}

weather_cumulative_temp_features_compute <- function(weather_data) {
  UFEED_check_required_packages(c(
    "dplyr",
    "tidyr",
    "lubridate",
    "zoo",
    "chillR",
    "dormancyR",
    "fruclimadapt"
  ))

  required_cols <- c("Date", "lon", "lat", "T2M_MAX", "T2M_MIN")
  missing_cols <- setdiff(required_cols, names(weather_data))

  if (length(missing_cols) > 0) {
    stop(
      "Missing columns for cumulative temperature features: ",
      paste(missing_cols, collapse = ", "),
      call. = FALSE
    )
  }

  compute_one_site <- function(site_data) {
    df_daily <- site_data |>
      dplyr::select(Date, lon, lat, T2M_MAX, T2M_MIN) |>
      dplyr::rename(
        Tmax = T2M_MAX,
        Tmin = T2M_MIN
      ) |>
      dplyr::mutate(Date = as.Date(Date)) |>
      dplyr::arrange(Date)

    missing_temp_summary <- df_daily |>
      dplyr::summarise(
        n_days_with_Tmax_NA = sum(is.na(Tmax)),
        n_days_with_Tmin_NA = sum(is.na(Tmin)),
        n_days_with_Tmax_or_Tmin_NA = sum(is.na(Tmax) | is.na(Tmin)),
        n_days_with_both_Tmax_and_Tmin_NA = sum(is.na(Tmax) & is.na(Tmin))
      )

    df_daily <- df_daily |>
      tidyr::fill(Tmax, Tmin, .direction = "downup")

    if (any(is.na(df_daily$Tmax)) || any(is.na(df_daily$Tmin))) {
      stop(
        "Tmax or Tmin still contains NA after filling for lon = ",
        unique(df_daily$lon),
        ", lat = ",
        unique(df_daily$lat),
        ".",
        call. = FALSE
      )
    }

    lon_i <- df_daily$lon[1]
    lat_i <- df_daily$lat[1]
    hemisphere <- ifelse(lat_i >= 0, "nh", "sh")

    date_lookup <- df_daily |>
      dplyr::transmute(
        Date_original = Date,
        Date_shifted = if (hemisphere == "sh") Date + 183L else Date
      )

    df_shifted <- df_daily |>
      dplyr::mutate(
        Date = if (hemisphere == "sh") Date + 183L else Date,
        DOY = lubridate::yday(Date),
        Year = lubridate::year(Date),
        Month = lubridate::month(Date),
        Day = lubridate::day(Date),
        Hour = lubridate::hour(Date)
      )

    df_hourly <- chillR::stack_hourly_temps(
      df_shifted,
      latitude = lat_i
    )[[1]]

    CU <- dormancyR::chilling_units(
      df_hourly$Temp,
      summ = FALSE
    )

    Utah <- dormancyR::modified_utah_model(
      df_hourly$Temp,
      summ = FALSE
    )

    NC <- dormancyR::north_carolina_model(
      df_hourly$Temp,
      summ = FALSE
    )

    DP <- chillR::Dynamic_Model(
      df_hourly$Temp,
      summ = FALSE
    )

    df_hourly_for_gdh <- df_hourly[
      ,
      !names(df_hourly) %in% c("datetime", "Date"),
      drop = FALSE
    ]

    GDH_10 <- fruclimadapt::GDH_linear(
      df_hourly_for_gdh,
      Tb = 10,
      Topt = 25,
      Tcrit = 36
    )

    GDH_7 <- fruclimadapt::GDH_linear(
      df_hourly_for_gdh,
      Tb = 7,
      Topt = 25,
      Tcrit = 36
    )

    GDH_4 <- fruclimadapt::GDH_linear(
      df_hourly_for_gdh,
      Tb = 4,
      Topt = 25,
      Tcrit = 36
    )

    GDH_0 <- fruclimadapt::GDH_linear(
      df_hourly_for_gdh,
      Tb = 0,
      Topt = 25,
      Tcrit = 36
    )

    GDD_0 <- chillR::GDD(
      df_hourly$Temp,
      summ = FALSE,
      Tbase = 0
    )

    GDD_4 <- chillR::GDD(
      df_hourly$Temp,
      summ = FALSE,
      Tbase = 4
    )

    GDD_7 <- chillR::GDD(
      df_hourly$Temp,
      summ = FALSE,
      Tbase = 7
    )

    GDD_10 <- chillR::GDD(
      df_hourly$Temp,
      summ = FALSE,
      Tbase = 10
    )

    CU <- dplyr::if_else(CU < 0, 0, CU)
    Utah <- dplyr::if_else(Utah < 0, 0, Utah)
    NC <- dplyr::if_else(NC < 0, 0, NC)

    all_chilling_data <- data.frame(
      Date = as.Date(df_hourly$Date),
      CU = CU,
      Utah = Utah,
      NC = NC,
      DP = DP,
      GDD_0 = GDD_0,
      GDD_4 = GDD_4,
      GDD_7 = GDD_7,
      GDD_10 = GDD_10
    )

    GDHs <- data.frame(
      Date = as.Date(GDH_10$Date),
      GDH10 = GDH_10$GDH,
      GDH_7 = GDH_7$GDH,
      GDH_4 = GDH_4$GDH,
      GDH_0 = GDH_0$GDH
    )

    daily <- all_chilling_data |>
      dplyr::group_by(Date) |>
      dplyr::summarise(
        dplyr::across(dplyr::everything(), sum),
        .groups = "drop"
      ) |>
      dplyr::arrange(Date) |>
      dplyr::left_join(GDHs, by = "Date")

    columns_for_rollsum <- c(
      "CU",
      "NC",
      "Utah",
      "DP",
      "GDD_0",
      "GDD_4",
      "GDD_7",
      "GDD_10",
      "GDH10",
      "GDH_7",
      "GDH_4",
      "GDH_0"
    )

    window_lengths <- c(3, 7, 14, 30, 60, 90)

    for (column in columns_for_rollsum) {
      for (window in window_lengths) {
        daily[[paste0(column, "_", window, "days")]] <- zoo::rollsum(
          daily[[column]],
          window,
          fill = NA,
          align = "right"
        )
      }
    }

    daily$lat <- lat_i
    daily$lon <- lon_i

    dormant_columns <- c("CU", "NC", "Utah", "DP")

    columns_for_cumsum_year <- c(
      "GDD_0",
      "GDD_4",
      "GDD_7",
      "GDD_10",
      "GDH10",
      "GDH_7",
      "GDH_4",
      "GDH_0"
    )

    seasonal_cumsum <- daily |>
      dplyr::select(Date, lat, lon, dplyr::all_of(columns_for_rollsum)) |>
      dplyr::arrange(Date) |>
      dplyr::mutate(
        Month = lubridate::month(Date),
        dormant_season = dplyr::case_when(
          Month %in% 9:12 ~ paste0(lubridate::year(Date), "-", lubridate::year(Date) + 1),
          Month %in% 1:8 ~ paste0(lubridate::year(Date) - 1, "-", lubridate::year(Date))
        ),
        growth_season = paste0(lubridate::year(Date), "-", lubridate::year(Date) + 1)
      ) |>
      dplyr::group_by(lat, lon, growth_season) |>
      dplyr::mutate(
        dplyr::across(
          dplyr::all_of(columns_for_cumsum_year),
          cumsum,
          .names = "{.col}_y2d"
        )
      ) |>
      dplyr::ungroup() |>
      dplyr::group_by(lat, lon, dormant_season) |>
      dplyr::mutate(
        dplyr::across(
          dplyr::all_of(dormant_columns),
          cumsum,
          .names = "{.col}_dormant2d"
        )
      ) |>
      dplyr::ungroup()

    dormant_cols <- grep(
      "_dormant2d$",
      names(seasonal_cumsum),
      value = TRUE
    )

    seasonal_cumsum <- seasonal_cumsum |>
      dplyr::group_by(lat, lon, dormant_season) |>
      dplyr::arrange(Date, .by_group = TRUE) |>
      dplyr::mutate(
        dplyr::across(
          dplyr::all_of(dormant_cols),
          ~ {
            season_end_year <- as.integer(substr(dplyr::first(dormant_season), 6, 9))
            cap_date <- as.Date(paste0(season_end_year, "-04-30"))

            cap_val <- .x[Date == cap_date][1]
            cap_val <- cap_val[!is.na(cap_val)][1]

            if (length(cap_val) == 0 || is.na(cap_val)) {
              cap_val <- NA_real_
            }

            dplyr::if_else(Date > cap_date, cap_val, .x)
          }
        )
      ) |>
      dplyr::ungroup() |>
      dplyr::select(
        -Month,
        -dormant_season,
        -growth_season,
        -dplyr::all_of(columns_for_rollsum)
      )

    out <- dplyr::left_join(
      daily,
      seasonal_cumsum,
      by = c("Date", "lat", "lon")
    )

    if (hemisphere == "sh") {
      out <- out |>
        dplyr::left_join(
          date_lookup,
          by = c("Date" = "Date_shifted")
        ) |>
        dplyr::mutate(Date = Date_original) |>
        dplyr::select(-Date_original)
    }

    if (missing_temp_summary$n_days_with_Tmax_or_Tmin_NA > 0) {
      message(
        missing_temp_summary$n_days_with_Tmax_or_Tmin_NA,
        " days had NA in Tmax and/or Tmin for lon = ",
        lon_i,
        ", lat = ",
        lat_i,
        ". Missing values were filled using nearest available values before computing temperature features."
      )
    }

    out |>
      dplyr::select(Date, lon, lat, dplyr::everything()) |>
      dplyr::arrange(Date)
  }

  split(
    weather_data,
    interaction(weather_data$lon, weather_data$lat, drop = TRUE)
  ) |>
    lapply(compute_one_site) |>
    dplyr::bind_rows() |>
    dplyr::arrange(lon, lat, Date)
}

weather_season_summary_compute <- function(
    weather_data_EWMA_REWMA,
    season_max_cols = c("T2M_MAX", "Daily_Temp_Fluctuation", "WS2M_MAX", "GWETROOT", "GWETTOP", "TSOIL1", "TSOIL3", "EVPTRNS"),
    season_min_cols = c("T2M_MIN", "Daily_Temp_Fluctuation", "GWETROOT", "GWETTOP", "TSOIL1", "TSOIL3", "EVPTRNS")
) {
  UFEED_check_required_packages(c("dplyr", "lubridate"))

  required_cols <- c("Date", "lon", "lat")
  missing_cols <- setdiff(required_cols, names(weather_data_EWMA_REWMA))
  if (length(missing_cols) > 0) {
    stop("Missing columns for season summary: ", paste(missing_cols, collapse = ", "), call. = FALSE)
  }

  pattern_cols <- paste0("^(", paste(c(season_max_cols, season_min_cols), collapse = "|"), ")")

  df <- weather_data_EWMA_REWMA |>
    dplyr::select(
      Date,
      lon,
      lat,
      dplyr::matches(pattern_cols)
    ) |>
    dplyr::mutate(Date = as.Date(Date)) |>
    dplyr::arrange(lon, lat, Date)

  max_pattern <- paste0("^(", paste(season_max_cols, collapse = "|"), ")")
  min_pattern <- paste0("^(", paste(season_min_cols, collapse = "|"), ")")

  max_feature_cols <- grep(max_pattern, names(df), value = TRUE)
  min_feature_cols <- grep(min_pattern, names(df), value = TRUE)

  df |>
    dplyr::group_by(lon, lat) |>
    dplyr::mutate(
      Hemisphere = ifelse(lat >= 0, "nh", "sh"),
      Date_original = Date,
      Date_shifted = Date + dplyr::if_else(Hemisphere == "sh", 183L, 0L),
      Month = lubridate::month(Date_shifted),
      season = dplyr::case_when(
        Month %in% 9:12 ~ paste0(lubridate::year(Date_shifted), "-", lubridate::year(Date_shifted) + 1),
        Month %in% 1:8 ~ paste0(lubridate::year(Date_shifted) - 1, "-", lubridate::year(Date_shifted))
      )
    ) |>
    dplyr::ungroup() |>
    dplyr::group_by(lon, lat, season) |>
    dplyr::arrange(Date_shifted, .by_group = TRUE) |>
    dplyr::mutate(
      dplyr::across(
        .cols = dplyr::all_of(max_feature_cols),
        .fns = ~ cummax(dplyr::if_else(is.na(.x), -Inf, .x)),
        .names = "{.col}_season_max"
      ),
      dplyr::across(
        .cols = dplyr::all_of(min_feature_cols),
        .fns = ~ cummin(dplyr::if_else(is.na(.x), Inf, .x)),
        .names = "{.col}_season_min"
      )
    ) |>
    dplyr::ungroup() |>
    dplyr::transmute(
      Date = Date_original,
      lon = lon,
      lat = lat,
      dplyr::across(dplyr::matches("_season_max$|_season_min$"))
    ) |>
    dplyr::arrange(lon, lat, Date)
}

# -----------------------------------------------------------------------------
# 7. Soil functions
# -----------------------------------------------------------------------------

UFEED_soil_online <- function(
    lon,
    lat,
    vars = c(
      "bdod", "cec", "cfvo", "clay", "nitrogen", "ocd",
      "phh2o", "sand", "silt", "soc", "ocs",
      "wv0010", "wv0033", "wv1500"
    ),
    stat = "mean",
    method = c("simple", "bilinear"),
    radius_m = 5000,
    pairwise = TRUE,
    resolution_m = 1000,
    max_retries = 5,
    retry_wait_sec = 2
) {
  UFEED_check_required_packages(c("terra", "dplyr", "tools"))

  method <- match.arg(method)

  Sys.setenv(
    GDAL_DISABLE_READDIR_ON_OPEN = "EMPTY_DIR",
    CPL_VSIL_CURL_ALLOWED_EXTENSIONS = "vrt,tif,tiff,ovr,xml,idx"
  )

  depth_map <- list(
    default = c(
      "0-5cm",
      "5-15cm",
      "15-30cm",
      "30-60cm",
      "60-100cm",
      "100-200cm"
    ),
    ocs = c("0-30cm")
  )

  build_soilgrids_url <- function(v, d_lbl, stat, resolution_m) {
    paste0(
      "https://files.isric.org/soilgrids/latest/data_aggregated/",
      resolution_m, "m/",
      v, "/",
      v, "_", d_lbl, "_", stat, "_", resolution_m, ".tif"
    )
  }

  retry_expr <- function(expr, what, max_retries = 5, retry_wait_sec = 2) {
    last_error <- NULL

    for (attempt in seq_len(max_retries)) {
      result <- tryCatch(
        {
          force(expr)
        },
        error = function(e) {
          last_error <<- e
          NULL
        }
      )

      if (!is.null(result)) {
        if (attempt > 1) {
          message(sprintf(
            "%s succeeded on attempt %d/%d.",
            what, attempt, max_retries
          ))
        }
        return(result)
      }

      if (attempt < max_retries) {
        message(sprintf(
          "%s failed on attempt %d/%d. Retrying in %s seconds...",
          what, attempt, max_retries, retry_wait_sec
        ))
        Sys.sleep(retry_wait_sec)
      }
    }

    warning(
      what,
      " failed after ",
      max_retries,
      " attempts. Last error: ",
      if (!is.null(last_error)) conditionMessage(last_error) else "unknown error",
      call. = FALSE
    )

    NULL
  }

  pts_ll <- UFEED_normalize_coordinates(
    lon = lon,
    lat = lat,
    pairwise = pairwise
  )

  pts_wgs <- terra::vect(
    pts_ll,
    geom = c("lon", "lat"),
    crs = "EPSG:4326"
  )

  out <- pts_ll

  n_total <- sum(
    vapply(
      vars,
      function(v) {
        if (v == "ocs") {
          length(depth_map$ocs)
        } else {
          length(depth_map$default)
        }
      },
      numeric(1)
    )
  )

  pb <- utils::txtProgressBar(min = 0, max = n_total, style = 3)
  i <- 0
  on.exit(close(pb), add = TRUE)

  for (v in vars) {

    depths <- if (v == "ocs") {
      depth_map$ocs
    } else {
      depth_map$default
    }

    for (d_lbl in depths) {
      i <- i + 1

      cname <- paste0(v, "_", d_lbl)

      url <- build_soilgrids_url(
        v = v,
        d_lbl = d_lbl,
        stat = stat,
        resolution_m = resolution_m
      )

      message(sprintf("Processing soil %s at %s ...", v, d_lbl))
      message("URL: ", url)

      r <- retry_expr(
        terra::rast(paste0("/vsicurl/", url)),
        what = paste0("Accessing remote SoilGrids layer ", cname),
        max_retries = max_retries,
        retry_wait_sec = retry_wait_sec
      )

      if (is.null(r)) {
        warning(
          "Could not access remote SoilGrids layer: ",
          cname,
          ". Returning NA for this layer. URL was: ",
          url,
          call. = FALSE
        )
        out[[cname]] <- NA_real_
        utils::setTxtProgressBar(pb, i)
        next
      }

      pts_gih <- retry_expr(
        terra::project(pts_wgs, terra::crs(r)),
        what = paste0("Projecting points for SoilGrids layer ", cname),
        max_retries = max_retries,
        retry_wait_sec = retry_wait_sec
      )

      if (is.null(pts_gih)) {
        warning(
          "Could not project points for remote SoilGrids layer: ",
          cname,
          ". Returning NA for this layer.",
          call. = FALSE
        )
        out[[cname]] <- NA_real_
        utils::setTxtProgressBar(pb, i)
        next
      }

      lname <- names(r)[1]

      vals_df <- retry_expr(
        terra::extract(r, pts_gih, method = method),
        what = paste0("Extracting values for SoilGrids layer ", cname),
        max_retries = max_retries,
        retry_wait_sec = retry_wait_sec
      )

      if (is.null(vals_df)) {
        warning(
          "Could not extract values for remote SoilGrids layer: ",
          cname,
          ". Returning NA for this layer.",
          call. = FALSE
        )
        out[[cname]] <- NA_real_
        utils::setTxtProgressBar(pb, i)
        next
      }

      val_col <- if (lname %in% names(vals_df)) {
        lname
      } else {
        tail(names(vals_df), 1)
      }

      if (!val_col %in% names(vals_df)) {
        warning(
          "No valid value column found for remote SoilGrids layer: ",
          cname,
          ". Returning NA for this layer.",
          call. = FALSE
        )
        out[[cname]] <- NA_real_
        utils::setTxtProgressBar(pb, i)
        next
      }

      vals_df[[val_col]] <- as.numeric(vals_df[[val_col]])

      na_rows <- which(is.na(vals_df[[val_col]]) | is.nan(vals_df[[val_col]]))

      if (length(na_rows) > 0) {
        message(sprintf("%d rows need imputation for %s", length(na_rows), cname))

        for (j in na_rows) {
          imputed <- retry_expr(
            terra::extract(
              r,
              pts_gih[j, ],
              method = method,
              search_radius = radius_m
            ),
            what = paste0(
              "Imputing row ",
              j,
              " for SoilGrids layer ",
              cname
            ),
            max_retries = max_retries,
            retry_wait_sec = retry_wait_sec
          )

          if (!is.null(imputed)) {
            imputed_col <- if (val_col %in% names(imputed)) {
              val_col
            } else {
              tail(names(imputed), 1)
            }

            if (imputed_col %in% names(imputed)) {
              vals_df[[val_col]][j] <- as.numeric(imputed[[imputed_col]][1])
            } else {
              vals_df[[val_col]][j] <- NA_real_
            }
          } else {
            vals_df[[val_col]][j] <- NA_real_
          }
        }
      }

      out[[cname]] <- as.numeric(vals_df[[val_col]])

      utils::setTxtProgressBar(pb, i)
    }
  }

  out |>
    dplyr::rename_with(~ gsub("-", "_", ., fixed = TRUE))
}


UFEED_soil_local_database <- function(
    lon,
    lat,
    soil_dir,
    vars = c("bdod", "cec", "cfvo", "clay", "nitrogen", "ocd", "phh2o", "sand", "silt", "soc", "ocs", "wv0010", "wv0033", "wv1500"),
    method = c("simple", "bilinear"),
    radius_m = 5000,
    pairwise = TRUE
) {
  UFEED_check_required_packages(c("terra", "dplyr", "tools"))
  method <- match.arg(method)

  if (is.null(soil_dir) || !nzchar(soil_dir) || !dir.exists(soil_dir)) {
    stop("`soil_dir` must be an existing directory containing local soil .tif files.", call. = FALSE)
  }

  tif_files <- list.files(soil_dir, pattern = "\\.tif$", full.names = TRUE)
  if (length(tif_files) == 0) {
    stop("No .tif files found in `soil_dir`: ", soil_dir, call. = FALSE)
  }

  keys <- tools::file_path_sans_ext(basename(tif_files))
  keys <- gsub("_mean_1000", "", keys)
  soil_list <- lapply(tif_files, terra::rast)
  names(soil_list) <- keys

  depth_map <- list(
    default = c("0-5cm", "5-15cm", "15-30cm", "30-60cm", "60-100cm", "100-200cm"),
    ocs = c("0-30cm")
  )

  pts_ll <- UFEED_normalize_coordinates(lon, lat, pairwise = pairwise)
  pts_wgs <- terra::vect(pts_ll, geom = c("lon", "lat"), crs = "EPSG:4326")

  out <- pts_ll
  n_total <- sum(vapply(vars, function(v) if (v == "ocs") length(depth_map$ocs) else length(depth_map$default), numeric(1)))
  pb <- utils::txtProgressBar(min = 0, max = n_total, style = 3)
  i <- 0
  on.exit(close(pb), add = TRUE)

  for (v in vars) {
    depths <- if (v == "ocs") depth_map$ocs else depth_map$default
    for (d_lbl in depths) {
      i <- i + 1
      cname <- paste0(v, "_", d_lbl)
      cname_clean <- gsub("-", "_", cname, fixed = TRUE)
      message(sprintf("Processing local soil %s ...", cname))

      r <- soil_list[[cname]]
      if (is.null(r)) r <- soil_list[[cname_clean]]

      if (is.null(r) || inherits(r, "try-error")) {
        out[[cname]] <- NA_real_
        utils::setTxtProgressBar(pb, i)
        next
      }

      pts_gih <- terra::project(pts_wgs, terra::crs(r))
      lname <- names(r)[1]
      vals_df <- try(terra::extract(r, pts_gih, method = method), silent = TRUE)

      if (inherits(vals_df, "try-error")) {
        out[[cname]] <- NA_real_
        utils::setTxtProgressBar(pb, i)
        next
      }

      if (lname %in% names(vals_df)) {
        na_rows <- which(is.na(vals_df[[lname]]) | is.nan(vals_df[[lname]]))
        if (length(na_rows) > 0) {
          message(sprintf("%d rows need imputation for %s", length(na_rows), lname))
          for (j in na_rows) {
            vals_df[[lname]][j] <- tryCatch({
              terra::extract(
                r,
                pts_gih[j, ],
                method = method,
                search_radius = radius_m
              )[[lname]][1]
            }, error = function(e) NA_real_)
          }
        }
      }

      val_col <- if (lname %in% names(vals_df)) lname else tail(names(vals_df), 1)
      out[[cname]] <- as.numeric(vals_df[[val_col]])
      utils::setTxtProgressBar(pb, i)
    }
  }

  out |>
    dplyr::rename_with(~ gsub("-", "_", ., fixed = TRUE))
}


# -----------------------------------------------------------------------------
# 8. Elevation helper
# -----------------------------------------------------------------------------

get_elev_open_meteo <- function(coord_df, batch_size = 90) {
  UFEED_check_required_packages(c("httr", "jsonlite", "dplyr"))

  if (nrow(coord_df) == 0) {
    return(data.frame(lon = numeric(), lat = numeric(), elev = numeric()))
  }

  idx_list <- split(
    seq_len(nrow(coord_df)),
    ceiling(seq_len(nrow(coord_df)) / batch_size)
  )

  batch_results <- lapply(idx_list, function(idx) {
    chunk <- coord_df[idx, , drop = FALSE]
    lat_str <- paste(chunk$lat, collapse = ",")
    lon_str <- paste(chunk$lon, collapse = ",")

    url <- sprintf(
      "https://api.open-meteo.com/v1/elevation?latitude=%s&longitude=%s",
      lat_str,
      lon_str
    )

    res <- httr::GET(url)
    httr::stop_for_status(res)
    dat <- jsonlite::fromJSON(httr::content(res, "text", encoding = "UTF-8"))

    data.frame(
      lon = chunk$lon,
      lat = chunk$lat,
      elev = dat$elevation
    )
  })

  dplyr::bind_rows(batch_results)
}
