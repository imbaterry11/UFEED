# UFEED feature expansion 2 --------------------------------------------------
# Reference-plant and environmental-process features. This module is
# deliberately separate from UFEED core and UFEED_feature_expansion_1.

.ufe2_fail <- function(...) stop(..., call. = FALSE)

.ufe2_numeric <- function(data, column) {
  if (!column %in% names(data)) .ufe2_fail("Missing required column `", column, "`.")
  x <- suppressWarnings(as.numeric(data[[column]]))
  x[!is.finite(x)] <- NA_real_
  x
}

.ufe2_unit <- function(input_units, column) {
  if (is.null(input_units) || is.null(names(input_units)) ||
      !column %in% names(input_units) || !nzchar(input_units[[column]])) {
    .ufe2_fail("Declare the source unit for `", column,
               "` in `input_units`; expansion_2 never infers units from values.")
  }
  tolower(gsub("[[:space:]_.-]", "", input_units[[column]]))
}

.ufe2_temperature_c <- function(x, unit, column) {
  if (unit %in% c("degc", "c", "celsius", "degreec", "degreescelsius")) return(x)
  if (unit %in% c("k", "kelvin")) return(x - 273.15)
  if (unit %in% c("degf", "f", "fahrenheit", "degreef")) return((x - 32) * 5 / 9)
  .ufe2_fail("Unsupported temperature unit for `", column, "`: ", unit)
}

.ufe2_radiation_mj <- function(x, unit) {
  if (unit %in% c("mjm2day1", "mj/m2/day", "mjm2d1")) return(x)
  if (unit %in% c("kwhm2day1", "kwh/m2/day", "kwhm2d1")) return(x * 3.6)
  if (unit %in% c("jm2day1", "j/m2/day", "jm2d1")) return(x / 1e6)
  if (unit %in% c("wm2", "w/m2", "dailymeanwm2")) return(x * 0.0864)
  .ufe2_fail("Unsupported radiation unit for `ALLSKY_SFC_SW_DWN`: ", unit)
}

.ufe2_recycle_parameter <- function(x, n, name, lower, upper, lower_open = FALSE) {
  if (!is.numeric(x) || !length(x) %in% c(1L, n) || any(!is.finite(x))) {
    .ufe2_fail("`", name, "` must be finite numeric, length 1 or number of rows.")
  }
  x <- rep(x, length.out = n)
  low_bad <- if (lower_open) x <= lower else x < lower
  if (any(low_bad | x > upper)) {
    bracket <- if (lower_open) "(" else "["
    .ufe2_fail("`", name, "` must be in ", bracket, lower, ", ", upper, "].")
  }
  x
}

# Wang-Engel normalized beta temperature response. It is a development-rate
# response, not a biochemical photosynthesis model.
.ufe2_wang_engel <- function(temperature_c, tmin_c, topt_c, tmax_c) {
  if (!(is.numeric(tmin_c) && is.numeric(topt_c) && is.numeric(tmax_c)) ||
      any(lengths(list(tmin_c, topt_c, tmax_c)) != 1L) ||
      any(!is.finite(c(tmin_c, topt_c, tmax_c))) ||
      !(tmin_c < topt_c && topt_c < tmax_c)) {
    .ufe2_fail("Cardinal temperatures must be finite scalars with Tmin < Topt < Tmax.")
  }
  alpha <- log(2) / log((tmax_c - tmin_c) / (topt_c - tmin_c))
  out <- rep(0, length(temperature_c))
  inside <- is.finite(temperature_c) & temperature_c > tmin_c & temperature_c < tmax_c
  scaled <- (temperature_c[inside] - tmin_c) / (topt_c - tmin_c)
  out[inside] <- 2 * scaled^alpha - scaled^(2 * alpha)
  out[is.finite(temperature_c) & abs(temperature_c - topt_c) < sqrt(.Machine$double.eps)] <- 1
  pmin(pmax(out, 0), 1)
}

.ufe2_photoperiod_response <- function(daylength_h, type, critical_h, saturating_h) {
  type <- match.arg(type, c("neutral", "long_day", "short_day"))
  if (type == "neutral") return(rep(1, length(daylength_h)))
  if (!is.numeric(critical_h) || !is.numeric(saturating_h) ||
      length(critical_h) != 1L || length(saturating_h) != 1L ||
      any(!is.finite(c(critical_h, saturating_h))) ||
      any(c(critical_h, saturating_h) < 0 | c(critical_h, saturating_h) > 24)) {
    .ufe2_fail("Non-neutral photoperiod response requires critical and saturating hours in [0, 24].")
  }
  if (type == "long_day") {
    if (saturating_h <= critical_h) .ufe2_fail("For long-day response, saturating_h must exceed critical_h.")
    return(pmin(pmax((daylength_h - critical_h) / (saturating_h - critical_h), 0), 1))
  }
  if (saturating_h >= critical_h) .ufe2_fail("For short-day response, saturating_h must be less than critical_h.")
  pmin(pmax((critical_h - daylength_h) / (critical_h - saturating_h), 0), 1)
}

.ufe2_group_cumsum <- function(values, dates, data, cycle_id_columns) {
  if (is.null(cycle_id_columns)) return(rep(NA_real_, length(values)))
  if (!is.character(cycle_id_columns) || !length(cycle_id_columns)) {
    .ufe2_fail("`cycle_id_columns` must be NULL or a non-empty character vector.")
  }
  missing <- setdiff(cycle_id_columns, names(data))
  if (length(missing)) .ufe2_fail("Missing cycle identifier column(s): ", paste(missing, collapse = ", "))
  if (anyNA(data[cycle_id_columns])) .ufe2_fail("Cycle identifier columns cannot contain missing values.")
  key <- interaction(data[cycle_id_columns], drop = TRUE, lex.order = TRUE)
  out <- rep(NA_real_, length(values))
  for (idx in split(seq_along(values), key)) {
    ord <- order(dates[idx])
    out[idx[ord]] <- cumsum(values[idx[ord]])
  }
  out
}

#' Construct an explicit reference-plant parameter set.
UFEED_expansion_2_reference_parameters <- function(
    reference_lai,
    light_extinction_coefficient,
    par_absorptance,
    rue_g_mj_apar,
    development_tmin_c,
    development_topt_c,
    development_tmax_c,
    growth_tmin_c,
    growth_topt_c,
    growth_tmax_c,
    par_fraction = 0.48,
    photoperiod_type = "neutral",
    photoperiod_critical_h = NA_real_,
    photoperiod_saturating_h = NA_real_,
    frost_threshold_c = 0,
    heat_threshold_c = 35
) {
  list(
    reference_lai = reference_lai,
    light_extinction_coefficient = light_extinction_coefficient,
    par_absorptance = par_absorptance,
    rue_g_mj_apar = rue_g_mj_apar,
    development_tmin_c = development_tmin_c,
    development_topt_c = development_topt_c,
    development_tmax_c = development_tmax_c,
    growth_tmin_c = growth_tmin_c,
    growth_topt_c = growth_topt_c,
    growth_tmax_c = growth_tmax_c,
    par_fraction = par_fraction,
    photoperiod_type = photoperiod_type,
    photoperiod_critical_h = photoperiod_critical_h,
    photoperiod_saturating_h = photoperiod_saturating_h,
    frost_threshold_c = frost_threshold_c,
    heat_threshold_c = heat_threshold_c
  )
}

#' Compute reference-plant and environmental-process features.
#'
#' The input must first pass through UFEED_feature_expansion_1. Results describe
#' a declared reference canopy and environmental exposure, not an actual crop.
UFEED_feature_expansion_2 <- function(
    ufeed_expansion_1_data,
    input_units,
    reference_parameters,
    cycle_id_columns = NULL
) {
  data <- ufeed_expansion_1_data
  if (!is.data.frame(data) || nrow(data) == 0L) .ufe2_fail("Input must be a non-empty data frame.")
  required_expansion_1 <- c("VPD_DAILY_FAO56_KPA", "DAYLENGTH_H")
  missing_expansion_1 <- setdiff(required_expansion_1, names(data))
  if (length(missing_expansion_1)) {
    .ufe2_fail("Run UFEED_feature_expansion_1 first; missing: ", paste(missing_expansion_1, collapse = ", "))
  }
  if (!is.list(reference_parameters)) .ufe2_fail("`reference_parameters` must be created explicitly as a list.")
  needed_parameters <- c(
    "reference_lai", "light_extinction_coefficient", "par_absorptance",
    "rue_g_mj_apar", "development_tmin_c", "development_topt_c",
    "development_tmax_c", "growth_tmin_c", "growth_topt_c", "growth_tmax_c",
    "par_fraction", "photoperiod_type", "photoperiod_critical_h",
    "photoperiod_saturating_h", "frost_threshold_c", "heat_threshold_c"
  )
  missing_parameters <- setdiff(needed_parameters, names(reference_parameters))
  if (length(missing_parameters)) .ufe2_fail("Missing reference parameter(s): ", paste(missing_parameters, collapse = ", "))

  n <- nrow(data)
  date <- as.Date(data$Date)
  if (anyNA(date)) .ufe2_fail("`Date` must contain valid dates.")
  tmean <- .ufe2_temperature_c(.ufe2_numeric(data, "T2M"), .ufe2_unit(input_units, "T2M"), "T2M")
  tmax <- .ufe2_temperature_c(.ufe2_numeric(data, "T2M_MAX"), .ufe2_unit(input_units, "T2M_MAX"), "T2M_MAX")
  tmin <- .ufe2_temperature_c(.ufe2_numeric(data, "T2M_MIN"), .ufe2_unit(input_units, "T2M_MIN"), "T2M_MIN")
  rs <- .ufe2_radiation_mj(.ufe2_numeric(data, "ALLSKY_SFC_SW_DWN"), .ufe2_unit(input_units, "ALLSKY_SFC_SW_DWN"))
  vpd <- .ufe2_numeric(data, "VPD_DAILY_FAO56_KPA")
  daylength <- .ufe2_numeric(data, "DAYLENGTH_H")
  if (any(!is.finite(tmean) | !is.finite(tmax) | !is.finite(tmin) |
          !is.finite(rs) | !is.finite(vpd) | !is.finite(daylength))) {
    .ufe2_fail("Expansion_2 requires complete temperature, radiation, VPD, and daylength values.")
  }
  if (any(tmin > tmean | tmean > tmax)) .ufe2_fail("Expected T2M_MIN <= T2M <= T2M_MAX.")
  if (any(c(tmin, tmean, tmax) < -100 | c(tmin, tmean, tmax) > 70)) {
    .ufe2_fail("Converted temperatures must be within the broad physical range -100 to 70 degC.")
  }
  if (any(rs < 0) || any(vpd < 0) || any(daylength < 0 | daylength > 24)) {
    .ufe2_fail("Radiation and VPD must be nonnegative and daylength must be in [0, 24].")
  }
  if (any(rs > 60) || any(vpd > 15)) {
    .ufe2_fail("Radiation above 60 MJ m-2 day-1 or VPD above 15 kPa indicates a likely unit or data error.")
  }

  lai <- .ufe2_recycle_parameter(reference_parameters$reference_lai, n, "reference_lai", 0, 20)
  k <- .ufe2_recycle_parameter(reference_parameters$light_extinction_coefficient, n, "light_extinction_coefficient", 0, 3, TRUE)
  absorptance <- .ufe2_recycle_parameter(reference_parameters$par_absorptance, n, "par_absorptance", 0, 1)
  rue <- .ufe2_recycle_parameter(reference_parameters$rue_g_mj_apar, n, "rue_g_mj_apar", 0, 10, TRUE)
  par_fraction <- .ufe2_recycle_parameter(reference_parameters$par_fraction, n, "par_fraction", 0, 1)
  frost_threshold <- .ufe2_recycle_parameter(reference_parameters$frost_threshold_c, n, "frost_threshold_c", -100, 70)
  heat_threshold <- .ufe2_recycle_parameter(reference_parameters$heat_threshold_c, n, "heat_threshold_c", -100, 70)
  if (any(frost_threshold >= heat_threshold)) .ufe2_fail("Frost threshold must be below heat threshold.")

  ftemp_development <- .ufe2_wang_engel(
    tmean, reference_parameters$development_tmin_c,
    reference_parameters$development_topt_c, reference_parameters$development_tmax_c)
  ftemp_growth <- .ufe2_wang_engel(
    tmean, reference_parameters$growth_tmin_c,
    reference_parameters$growth_topt_c, reference_parameters$growth_tmax_c)
  fphotoperiod <- .ufe2_photoperiod_response(
    daylength, reference_parameters$photoperiod_type,
    reference_parameters$photoperiod_critical_h,
    reference_parameters$photoperiod_saturating_h)

  incident_par <- rs * par_fraction
  fipar <- 1 - exp(-k * lai)
  intercepted_par <- incident_par * fipar
  absorbed_par <- intercepted_par * absorptance
  potential_dm <- absorbed_par * rue
  temp_limited_dm <- potential_dm * ftemp_growth
  development_rate <- ftemp_development * fphotoperiod
  frost_severity <- pmax(frost_threshold - tmin, 0)
  heat_severity <- pmax(tmax - heat_threshold, 0)

  out <- data
  out$INCIDENT_PAR_MJ_M2_DAY <- incident_par
  out$REFERENCE_FIPAR <- fipar
  out$REFERENCE_INTERCEPTED_PAR_MJ_M2_DAY <- intercepted_par
  out$REFERENCE_APAR_MJ_M2_DAY <- absorbed_par
  out$REFERENCE_DEVELOPMENT_TEMP_RESPONSE_0_1 <- ftemp_development
  out$REFERENCE_PHOTOPERIOD_RESPONSE_0_1 <- fphotoperiod
  out$REFERENCE_DAILY_DEVELOPMENT_RATE_0_1 <- development_rate
  out$REFERENCE_GROWTH_TEMP_RESPONSE_0_1 <- ftemp_growth
  out$REFERENCE_POTENTIAL_DM_G_M2_DAY <- potential_dm
  out$REFERENCE_TEMP_LIMITED_DM_G_M2_DAY <- temp_limited_dm
  out$DAILY_ATMOSPHERIC_DROUGHT_DOSE_KPA_DAY <- vpd
  out$DAILY_FROST_SEVERITY_INDEX_DEGC <- frost_severity
  out$DAILY_HEAT_SEVERITY_INDEX_DEGC <- heat_severity
  out$CUMULATIVE_REFERENCE_DEVELOPMENT_UNITS <-
    .ufe2_group_cumsum(development_rate, date, data, cycle_id_columns)
  out$CUMULATIVE_REFERENCE_APAR_MJ_M2 <-
    .ufe2_group_cumsum(absorbed_par, date, data, cycle_id_columns)
  out$CUMULATIVE_REFERENCE_POTENTIAL_DM_G_M2 <-
    .ufe2_group_cumsum(potential_dm, date, data, cycle_id_columns)
  out$CUMULATIVE_REFERENCE_TEMP_LIMITED_DM_G_M2 <-
    .ufe2_group_cumsum(temp_limited_dm, date, data, cycle_id_columns)
  out$CUMULATIVE_ATMOSPHERIC_DROUGHT_DOSE_KPA_DAY <-
    .ufe2_group_cumsum(vpd, date, data, cycle_id_columns)
  out$CUMULATIVE_FROST_SEVERITY_INDEX_DEGC_DAY <-
    .ufe2_group_cumsum(frost_severity, date, data, cycle_id_columns)
  out$CUMULATIVE_HEAT_SEVERITY_INDEX_DEGC_DAY <-
    .ufe2_group_cumsum(heat_severity, date, data, cycle_id_columns)

  attr(out, "UFEED_feature_expansion_2_scope") <-
    "Reference-canopy potential processes and environmental exposure; not actual crop state, photosynthesis, transpiration, stress, or yield."
  attr(out, "UFEED_feature_expansion_2_parameters") <- reference_parameters
  attr(out, "UFEED_feature_expansion_2_references") <- c(
    "Wang and Engel 1998 doi:10.1016/S0308-521X(98)00028-6",
    "Monteith 1977 doi:10.1098/rstb.1977.0140",
    "Monsi and Saeki 1953 canopy light attenuation concept")
  out
}

# Selected temporal summaries for expansion 2 -------------------------------

UFEED_EXPANSION_2_TEMPORAL_COLUMNS <- c(
  "REFERENCE_APAR_MJ_M2_DAY", "REFERENCE_DEVELOPMENT_TEMP_RESPONSE_0_1",
  "REFERENCE_PHOTOPERIOD_RESPONSE_0_1", "REFERENCE_DAILY_DEVELOPMENT_RATE_0_1",
  "REFERENCE_GROWTH_TEMP_RESPONSE_0_1", "REFERENCE_POTENTIAL_DM_G_M2_DAY",
  "REFERENCE_TEMP_LIMITED_DM_G_M2_DAY"
)

.ufe2_temporal_apply <- function(x, dates, key, fun) {
  out <- rep(NA_real_, length(x))
  for (idx in split(seq_along(x), key)) {
    ord <- order(dates[idx]); out[idx[ord]] <- fun(x[idx[ord]])
  }
  out
}

.ufe2_temporal_key <- function(data, columns, label) {
  if (is.null(columns) || !is.character(columns) || !length(columns)) {
    .ufe2_fail("`", label, "` must be a non-empty character vector.")
  }
  missing <- setdiff(columns, names(data))
  if (length(missing)) .ufe2_fail("Missing grouping column(s): ", paste(missing, collapse = ", "))
  interaction(data[columns], drop = TRUE, lex.order = TRUE)
}

.ufe2_running_extreme <- function(x, type) {
  out <- rep(NA_real_, length(x)); current <- if (type == "max") -Inf else Inf
  for (i in seq_along(x)) {
    if (is.finite(x[i])) current <- if (type == "max") max(current, x[i]) else min(current, x[i])
    if (is.finite(current)) out[i] <- current
  }
  out
}

.ufe2_rolling_event <- function(x, window, type) {
  out <- rep(NA_real_, length(x))
  for (i in seq_along(x)) if (i >= window) {
    z <- x[(i - window + 1):i]
    if (mean(is.na(z)) <= 0.10 && !all(is.na(z))) {
      out[i] <- if (type == "sum") sum(z, na.rm = TRUE) else max(z, na.rm = TRUE)
    }
  }
  out
}

#' Add selected EWMA, REWMA, seasonal extrema, and event windows to expansion 2.
UFEED_feature_expansion_2_temporal <- function(
    expansion_2_data,
    temporal_group_columns = c("lon", "lat"),
    cycle_id_columns,
    windows = c(7L, 14L, 30L)
) {
  data <- expansion_2_data
  windows <- unique(as.integer(windows))
  if (!length(windows) || any(!is.finite(windows)) || any(windows < 2)) {
    .ufe2_fail("`windows` must contain integers >= 2.")
  }
  required <- c(UFEED_EXPANSION_2_TEMPORAL_COLUMNS,
                "DAILY_FROST_SEVERITY_INDEX_DEGC", "DAILY_HEAT_SEVERITY_INDEX_DEGC")
  missing <- setdiff(c("Date", required), names(data))
  if (length(missing)) .ufe2_fail("Missing expansion-2 temporal input(s): ", paste(missing, collapse = ", "))
  dates <- as.Date(data$Date); if (anyNA(dates)) .ufe2_fail("Invalid `Date` values.")
  temporal_key <- .ufe2_temporal_key(data, temporal_group_columns, "temporal_group_columns")
  cycle_key <- .ufe2_temporal_key(data, cycle_id_columns, "cycle_id_columns")
  out <- data
  if (!identical(temporal_group_columns, c("lon", "lat"))) {
    .ufe2_fail("The core EWMA/REWMA function groups by `lon` and `lat`; `temporal_group_columns` must be c(\"lon\", \"lat\").")
  }
  if (!exists(".UFEED_compute_EWMA_REWMA_features", mode = "function", inherits = TRUE)) {
    .ufe2_fail("The UFEED core `.UFEED_compute_EWMA_REWMA_features()` function is not loaded.")
  }
  core_smoothed <- .UFEED_compute_EWMA_REWMA_features(
    weather_data = data,
    columns_for_EWMA_REWMA = UFEED_EXPANSION_2_TEMPORAL_COLUMNS,
    EWMA_REWMA_windows = windows,
    max_missing_prop = 0.10,
    require_full_window = TRUE
  )
  data_key <- paste(data$Date, data$lon, data$lat, sep = "\r")
  core_key <- paste(core_smoothed$Date, core_smoothed$lon, core_smoothed$lat, sep = "\r")
  if (anyDuplicated(data_key) || anyDuplicated(core_key)) {
    .ufe2_fail("EWMA/REWMA requires unique Date-lon-lat rows.")
  }
  row_match <- match(data_key, core_key)
  if (anyNA(row_match)) .ufe2_fail("Could not align core EWMA/REWMA results to expansion-2 rows.")
  for (column in setdiff(names(core_smoothed), c("Date", "lon", "lat"))) {
    out[[column]] <- core_smoothed[[column]][row_match]
  }
  season_max <- c("REFERENCE_APAR_MJ_M2_DAY", "REFERENCE_POTENTIAL_DM_G_M2_DAY",
                  "REFERENCE_TEMP_LIMITED_DM_G_M2_DAY",
                  "DAILY_FROST_SEVERITY_INDEX_DEGC", "DAILY_HEAT_SEVERITY_INDEX_DEGC")
  season_min <- c("REFERENCE_DEVELOPMENT_TEMP_RESPONSE_0_1",
                  "REFERENCE_PHOTOPERIOD_RESPONSE_0_1",
                  "REFERENCE_DAILY_DEVELOPMENT_RATE_0_1",
                  "REFERENCE_GROWTH_TEMP_RESPONSE_0_1",
                  "REFERENCE_TEMP_LIMITED_DM_G_M2_DAY")
  for (column in season_max) out[[paste0(column, "_SEASON_TO_DATE_MAX")]] <-
    .ufe2_temporal_apply(data[[column]], dates, cycle_key, function(x) .ufe2_running_extreme(x, "max"))
  for (column in season_min) out[[paste0(column, "_SEASON_TO_DATE_MIN")]] <-
    .ufe2_temporal_apply(data[[column]], dates, cycle_key, function(x) .ufe2_running_extreme(x, "min"))
  for (column in c("DAILY_FROST_SEVERITY_INDEX_DEGC", "DAILY_HEAT_SEVERITY_INDEX_DEGC")) {
    for (window in windows) {
      out[[paste0(column, "_ROLLSUM_", window)]] <- .ufe2_temporal_apply(
        data[[column]], dates, temporal_key, function(x) .ufe2_rolling_event(x, window, "sum"))
      out[[paste0(column, "_ROLLMAX_", window)]] <- .ufe2_temporal_apply(
        data[[column]], dates, temporal_key, function(x) .ufe2_rolling_event(x, window, "max"))
    }
  }
  new_columns <- setdiff(names(out), names(data))
  stopifnot(all(vapply(out[new_columns], is.numeric, logical(1))))
  attr(out, "UFEED_feature_expansion_2_temporal_feature_count") <- length(new_columns)
  out
}

# Final modeling product ------------------------------------------------------

UFEED_FINAL_EXCLUDED_INTERMEDIATE_COLUMNS <- c(
  # Diagnostic/raw equation result; ET0_FAO56_MM_DAY is the retained feature.
  "ET0_FAO56_RAW_MM_DAY",
  # Calculation diagnostic rather than an environmental or process feature.
  "WIND_ADJUSTMENT_FACTOR_TO_2M",
  # Exact alias of VPD_DAILY_FAO56_KPA, retained only internally to build the
  # cycle cumulative atmospheric-drought dose.
  "DAILY_ATMOSPHERIC_DROUGHT_DOSE_KPA_DAY"
)

#' Assemble the final numeric UFEED feature product.
#'
#' Retains Date/lon/lat, numeric core features, expansion features, and their
#' temporal variants. Drops categorical fields, known intermediate/duplicate
#' columns, and all non-feature identifiers other than Date/lon/lat.
UFEED_finalize_feature_product <- function(feature_data) {
  if (!is.data.frame(feature_data) || nrow(feature_data) == 0L) {
    .ufe2_fail("`feature_data` must be a non-empty data frame.")
  }
  required_keys <- c("Date", "lon", "lat")
  missing_keys <- setdiff(required_keys, names(feature_data))
  if (length(missing_keys)) {
    .ufe2_fail("Final product requires key column(s): ", paste(missing_keys, collapse = ", "))
  }
  if (anyDuplicated(names(feature_data))) {
    .ufe2_fail("Final product cannot be assembled from duplicated column names.")
  }
  date <- as.Date(feature_data$Date)
  if (anyNA(date)) .ufe2_fail("Final product `Date` contains invalid values.")
  lon <- suppressWarnings(as.numeric(feature_data$lon))
  lat <- suppressWarnings(as.numeric(feature_data$lat))
  if (any(!is.finite(lon)) || any(!is.finite(lat)) || any(lat < -90 | lat > 90)) {
    .ufe2_fail("Final product coordinates must be finite decimal degrees.")
  }

  candidate_names <- setdiff(names(feature_data), c(required_keys, UFEED_FINAL_EXCLUDED_INTERMEDIATE_COLUMNS))
  numeric_names <- candidate_names[vapply(feature_data[candidate_names], is.numeric, logical(1))]
  out <- data.frame(Date = date, lon = as.double(lon), lat = as.double(lat),
                    stringsAsFactors = FALSE, check.names = FALSE)
  for (column in numeric_names) out[[column]] <- as.double(feature_data[[column]])

  feature_names <- setdiff(names(out), required_keys)
  if (!all(vapply(out[feature_names], is.double, logical(1)))) {
    .ufe2_fail("Internal error: every final feature must use double precision.")
  }
  if (anyDuplicated(names(out))) .ufe2_fail("Internal error: duplicated final column names.")
  attr(out, "UFEED_final_removed_intermediate_columns") <-
    intersect(UFEED_FINAL_EXCLUDED_INTERMEDIATE_COLUMNS, names(feature_data))
  attr(out, "UFEED_final_removed_categorical_columns") <-
    setdiff(candidate_names, numeric_names)
  attr(out, "UFEED_final_numeric_feature_count") <- length(feature_names)
  out
}
