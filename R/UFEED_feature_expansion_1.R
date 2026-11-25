# UFEED feature expansion 1 --------------------------------------------------
# Standalone post-processing module; no UFEED core functions are modified.

.ufe1_fail <- function(...) stop(..., call. = FALSE)

.ufe1_numeric <- function(data, column) {
  if (!column %in% names(data)) return(rep(NA_real_, nrow(data)))
  x <- suppressWarnings(as.numeric(data[[column]]))
  x[!is.finite(x)] <- NA_real_
  x
}

.ufe1_unit <- function(input_units, column) {
  if (is.null(input_units) || is.null(names(input_units)) ||
      !column %in% names(input_units) || !nzchar(input_units[[column]])) {
    .ufe1_fail("Declare the source unit for `", column,
               "` in `input_units`; units are never inferred from numeric values.")
  }
  tolower(gsub("[[:space:]_.-]", "", input_units[[column]]))
}

.ufe1_convert_temperature <- function(x, unit, column) {
  if (unit %in% c("degc", "c", "celsius", "degreec", "degreescelsius")) return(x)
  if (unit %in% c("k", "kelvin")) return(x - 273.15)
  if (unit %in% c("degf", "f", "fahrenheit", "degreef")) return((x - 32) * 5 / 9)
  .ufe1_fail("Unsupported temperature unit for `", column, "`: ", unit)
}

.ufe1_convert_pressure <- function(x, unit) {
  if (unit %in% c("kpa", "kilopascal", "kilopascals")) return(x)
  if (unit %in% c("hpa", "mbar", "millibar", "millibars")) return(x / 10)
  if (unit %in% c("pa", "pascal", "pascals")) return(x / 1000)
  if (unit %in% c("bar", "bars")) return(x * 100)
  .ufe1_fail("Unsupported pressure unit for `PS`: ", unit)
}

.ufe1_convert_rh <- function(x, unit) {
  if (unit %in% c("percent", "%", "pct", "percentage")) return(x)
  if (unit %in% c("fraction", "proportion", "01")) return(x * 100)
  .ufe1_fail("Unsupported relative-humidity unit for `RH2M`: ", unit)
}

.ufe1_convert_wind <- function(x, unit) {
  if (unit %in% c("ms1", "ms", "m/s", "meterpersecond", "metrepersecond")) return(x)
  if (unit %in% c("kmh1", "kmh", "km/h", "kilometerperhour", "kilometreperhour")) return(x / 3.6)
  if (unit %in% c("mph", "mileperhour", "milesperhour")) return(x * 0.44704)
  if (unit %in% c("knot", "knots", "kt")) return(x * 0.514444)
  .ufe1_fail("Unsupported wind-speed unit for `WS2M`: ", unit)
}

.ufe1_convert_radiation <- function(x, unit, column) {
  if (unit %in% c("mjm2day1", "mj/m2/day", "mjm2d1")) return(x)
  if (unit %in% c("kwhm2day1", "kwh/m2/day", "kwhm2d1")) return(x * 3.6)
  if (unit %in% c("jm2day1", "j/m2/day", "jm2d1")) return(x / 1e6)
  if (unit %in% c("wm2", "w/m2", "dailymeanwm2")) return(x * 0.0864)
  .ufe1_fail("Unsupported radiation unit for `", column, "`: ", unit)
}

.ufe1_convert_elevation <- function(x, unit) {
  if (unit %in% c("m", "meter", "meters", "metre", "metres")) return(x)
  if (unit %in% c("ft", "foot", "feet")) return(x * 0.3048)
  .ufe1_fail("Unsupported elevation unit: ", unit)
}

.ufe1_convert_latitude <- function(x, unit) {
  if (unit %in% c("degree", "degrees", "deg", "decimaldegrees")) return(x)
  if (unit %in% c("radian", "radians", "rad")) return(x * 180 / pi)
  .ufe1_fail("Unsupported latitude unit for `lat`: ", unit)
}

.ufe1_assert_range <- function(x, lower, upper, label) {
  bad <- is.finite(x) & (x < lower | x > upper)
  if (any(bad)) {
    .ufe1_fail("Converted `", label, "` is outside [", lower, ", ", upper,
               "]. First invalid row: ", which(bad)[1], ".")
  }
}

.ufe1_esat_kpa <- function(temperature_c) {
  0.6108 * exp(17.27 * temperature_c / (temperature_c + 237.3))
}

.ufe1_pressure_from_elevation <- function(elevation_m) {
  101.3 * ((293 - 0.0065 * elevation_m) / 293)^5.26
}

.ufe1_elevation_from_pressure <- function(pressure_kpa) {
  (293 - 293 * (pressure_kpa / 101.3)^(1 / 5.26)) / 0.0065
}

.ufe1_standardize_inputs <- function(data, input_units, wind_height_m) {
  if (!is.data.frame(data)) .ufe1_fail("`ufeed_data` must be a data frame.")
  if (nrow(data) == 0L) .ufe1_fail("`ufeed_data` must contain at least one row.")
  required <- c("Date", "lat", "T2M", "T2M_MAX", "T2M_MIN",
                "ALLSKY_SFC_SW_DWN", "WS2M")
  missing <- setdiff(required, names(data))
  if (length(missing)) .ufe1_fail("Missing required input column(s): ", paste(missing, collapse = ", "))
  if (!any(c("T2MDEW", "RH2M") %in% names(data))) {
    .ufe1_fail("At least one humidity input is required: `T2MDEW` or `RH2M`.")
  }

  date <- as.Date(data$Date)
  if (anyNA(date)) .ufe1_fail("`Date` must contain valid daily dates without missing values.")
  lat <- .ufe1_convert_latitude(.ufe1_numeric(data, "lat"), .ufe1_unit(input_units, "lat"))
  tmean <- .ufe1_convert_temperature(.ufe1_numeric(data, "T2M"), .ufe1_unit(input_units, "T2M"), "T2M")
  tmax <- .ufe1_convert_temperature(.ufe1_numeric(data, "T2M_MAX"), .ufe1_unit(input_units, "T2M_MAX"), "T2M_MAX")
  tmin <- .ufe1_convert_temperature(.ufe1_numeric(data, "T2M_MIN"), .ufe1_unit(input_units, "T2M_MIN"), "T2M_MIN")
  rs <- .ufe1_convert_radiation(.ufe1_numeric(data, "ALLSKY_SFC_SW_DWN"), .ufe1_unit(input_units, "ALLSKY_SFC_SW_DWN"), "ALLSKY_SFC_SW_DWN")
  uz <- .ufe1_convert_wind(.ufe1_numeric(data, "WS2M"), .ufe1_unit(input_units, "WS2M"))

  tdew <- rep(NA_real_, nrow(data))
  if ("T2MDEW" %in% names(data)) {
    tdew <- .ufe1_convert_temperature(.ufe1_numeric(data, "T2MDEW"), .ufe1_unit(input_units, "T2MDEW"), "T2MDEW")
  }
  rh <- rep(NA_real_, nrow(data))
  if ("RH2M" %in% names(data)) {
    rh <- .ufe1_convert_rh(.ufe1_numeric(data, "RH2M"), .ufe1_unit(input_units, "RH2M"))
  }
  pressure <- rep(NA_real_, nrow(data))
  if ("PS" %in% names(data)) {
    pressure <- .ufe1_convert_pressure(.ufe1_numeric(data, "PS"), .ufe1_unit(input_units, "PS"))
  }
  elevation_candidates <- c("elevation", "ELEVATION", "elev", "Elev")
  elevation_column <- elevation_candidates[elevation_candidates %in% names(data)][1]
  elevation <- rep(NA_real_, nrow(data))
  if (!is.na(elevation_column)) {
    elevation <- .ufe1_convert_elevation(.ufe1_numeric(data, elevation_column), .ufe1_unit(input_units, elevation_column))
  }
  if (all(!is.finite(pressure)) && all(!is.finite(elevation))) {
    .ufe1_fail("Surface-energy calculations require `PS` or elevation; no sea-level default is assumed.")
  }
  both_observed <- is.finite(pressure) & is.finite(elevation)
  pressure_expected <- .ufe1_pressure_from_elevation(elevation)
  inconsistent_pressure <- both_observed & abs(pressure - pressure_expected) > 5
  if (any(inconsistent_pressure)) {
    .ufe1_fail("`PS` and elevation are inconsistent by more than 5 kPa; first invalid row: ",
               which(inconsistent_pressure)[1], ".")
  }
  pressure <- ifelse(is.finite(pressure), pressure, .ufe1_pressure_from_elevation(elevation))
  elevation <- ifelse(is.finite(elevation), elevation, .ufe1_elevation_from_pressure(pressure))

  if (!is.numeric(wind_height_m) || !length(wind_height_m) %in% c(1L, nrow(data)) ||
      any(!is.finite(wind_height_m)) || any(wind_height_m <= 0)) {
    .ufe1_fail("`wind_height_m` must give one positive measurement height, or one per row, in meters.")
  }
  wind_height_m <- rep(wind_height_m, length.out = nrow(data))
  wind_factor <- 4.87 / log(67.8 * wind_height_m - 5.42)
  # A measurement already made at the FAO reference height needs no adjustment;
  # avoid the tiny rounding offset produced by the empirical equation at z = 2.
  wind_factor[abs(wind_height_m - 2) < sqrt(.Machine$double.eps)] <- 1
  if (any(!is.finite(wind_factor) | wind_factor <= 0)) {
    .ufe1_fail("`wind_height_m` is outside the valid FAO-56 wind-adjustment range.")
  }
  u2 <- uz * wind_factor

  .ufe1_assert_range(lat, -90, 90, "lat")
  .ufe1_assert_range(tmean, -100, 70, "T2M")
  .ufe1_assert_range(tmax, -100, 70, "T2M_MAX")
  .ufe1_assert_range(tmin, -100, 70, "T2M_MIN")
  .ufe1_assert_range(tdew, -100, 70, "T2MDEW")
  .ufe1_assert_range(rh, 0, 100, "RH2M")
  .ufe1_assert_range(pressure, 30, 110, "PS")
  .ufe1_assert_range(elevation, -500, 9000, "elevation")
  .ufe1_assert_range(uz, 0, 100, "WS2M")
  .ufe1_assert_range(rs, 0, 60, "ALLSKY_SFC_SW_DWN")
  bad_order <- is.finite(tmin) & is.finite(tmean) & is.finite(tmax) &
    (tmin > tmean | tmean > tmax)
  if (any(bad_order)) .ufe1_fail("Expected T2M_MIN <= T2M <= T2M_MAX; first invalid row: ", which(bad_order)[1], ".")
  bad_dew <- is.finite(tdew) & is.finite(tmean) & tdew > tmean + 1
  if (any(bad_dew)) .ufe1_fail("Dew point exceeds mean air temperature by >1 degC; first invalid row: ", which(bad_dew)[1], ".")

  data.frame(Date = date, lat_deg = lat, tmean_c = tmean, tmax_c = tmax,
             tmin_c = tmin, tdew_c = tdew, rh_percent = rh,
             pressure_kpa = pressure, elevation_m = elevation,
             rs_mj_m2_day = rs, wind_original_m_s = uz,
             wind_height_m = wind_height_m, wind_2m_m_s = u2,
             wind_adjustment_factor = wind_factor)
}

.ufe1_humidity <- function(x) {
  es_tmean <- .ufe1_esat_kpa(x$tmean_c)
  es_tmax <- .ufe1_esat_kpa(x$tmax_c)
  es_tmin <- .ufe1_esat_kpa(x$tmin_c)
  es_daily <- (es_tmax + es_tmin) / 2
  ea_dew <- .ufe1_esat_kpa(x$tdew_c)
  ea_rhmean <- es_daily * x$rh_percent / 100
  use_dew <- is.finite(ea_dew)
  ea <- ifelse(use_dew, ea_dew, ea_rhmean)
  if (any(!is.finite(ea))) .ufe1_fail("Actual vapor pressure could not be calculated for every row.")
  list(es_tmean = es_tmean, es_tmax = es_tmax, es_tmin = es_tmin,
       es_daily = es_daily, ea = ea,
       method = ifelse(use_dew, "dew_point_fao56_eq14", "mean_rh_fao56_eq19_lower_quality"),
       vpd_tmean = pmax(es_tmean - ea, 0),
       vpd_daily = pmax(es_daily - ea, 0),
       vpd_tmax_proxy = pmax(es_tmax - ea, 0),
       vpd_tmin_proxy = pmax(es_tmin - ea, 0))
}

.ufe1_solar <- function(date, lat_deg) {
  doy <- as.integer(format(date, "%j"))
  phi <- lat_deg * pi / 180
  dr <- 1 + 0.033 * cos(2 * pi * doy / 365)
  delta <- 0.409 * sin(2 * pi * doy / 365 - 1.39)
  sunset_angle <- acos(pmin(pmax(-tan(phi) * tan(delta), -1), 1))
  ra <- (24 * 60 / pi) * 0.0820 * dr *
    (sunset_angle * sin(phi) * sin(delta) +
       cos(phi) * cos(delta) * sin(sunset_angle))
  list(daylength_h = 24 / pi * sunset_angle,
       extraterrestrial_radiation = pmax(ra, 0))
}

#' Compute unit-safe post-processing features from completed UFEED raw data.
UFEED_feature_expansion_1 <- function(
    ufeed_data, input_units, wind_height_m, albedo = 0.23,
    soil_heat_flux = 0, soil_heat_flux_unit = "MJ m-2 day-1") {
  if (!is.numeric(albedo) || length(albedo) != 1L || !is.finite(albedo) || albedo < 0 || albedo > 1) {
    .ufe1_fail("`albedo` must be one finite dimensionless value from 0 to 1.")
  }
  if (!is.numeric(soil_heat_flux) || length(soil_heat_flux) != 1L || !is.finite(soil_heat_flux)) {
    .ufe1_fail("`soil_heat_flux` must be one finite numeric value.")
  }
  g_unit <- tolower(gsub("[[:space:]_.-]", "", soil_heat_flux_unit))
  g <- .ufe1_convert_radiation(soil_heat_flux, g_unit, "soil_heat_flux")
  x <- .ufe1_standardize_inputs(ufeed_data, input_units, wind_height_m)
  h <- .ufe1_humidity(x)
  solar <- .ufe1_solar(x$Date, x$lat_deg)
  ra <- solar$extraterrestrial_radiation
  rso <- (0.75 + 2e-5 * x$elevation_m) * ra
  rns <- (1 - albedo) * x$rs_mj_m2_day
  relative_solar_raw <- ifelse(rso > 0, x$rs_mj_m2_day / rso, NA_real_)
  relative_solar_for_rnl <- pmin(pmax(relative_solar_raw, 0.3), 1)
  sigma <- 4.903e-9
  rnl <- sigma * (((x$tmax_c + 273.16)^4 + (x$tmin_c + 273.16)^4) / 2) *
    (0.34 - 0.14 * sqrt(pmax(h$ea, 0))) *
    (1.35 * relative_solar_for_rnl - 0.35)
  rn <- rns - rnl
  slope <- 4098 * .ufe1_esat_kpa(x$tmean_c) / (x$tmean_c + 237.3)^2
  gamma <- 0.000665 * x$pressure_kpa
  et0_raw <- (0.408 * slope * (rn - g) +
                gamma * (900 / (x$tmean_c + 273)) * x$wind_2m_m_s * h$vpd_daily) /
    (slope + gamma * (1 + 0.34 * x$wind_2m_m_s))
  q <- 0.622 * h$ea / (x$pressure_kpa - 0.378 * h$ea)
  if (any(x$pressure_kpa <= h$ea)) {
    .ufe1_fail("Atmospheric pressure must exceed actual vapor pressure on every row.")
  }

  out <- ufeed_data
  out$SATURATION_VAPOR_PRESSURE_TMEAN_KPA <- h$es_tmean
  out$SATURATION_VAPOR_PRESSURE_TMAX_KPA <- h$es_tmax
  out$SATURATION_VAPOR_PRESSURE_TMIN_KPA <- h$es_tmin
  out$SATURATION_VAPOR_PRESSURE_DAILY_KPA <- h$es_daily
  out$ACTUAL_VAPOR_PRESSURE_KPA <- h$ea
  out$VPD_TMEAN_KPA <- h$vpd_tmean
  out$VPD_DAILY_FAO56_KPA <- h$vpd_daily
  out$VPD_AT_TMAX_PROXY_KPA <- h$vpd_tmax_proxy
  out$VPD_AT_TMIN_PROXY_KPA <- h$vpd_tmin_proxy
  out$DEWPOINT_DEPRESSION_DEGC <- x$tmean_c - x$tdew_c
  out$SPECIFIC_HUMIDITY_KG_KG <- q
  out$VPD_WIND_INTERACTION_KPA_M_S <- h$vpd_tmean * x$wind_2m_m_s
  out$WIND_SPEED_2M_M_S <- x$wind_2m_m_s
  out$WIND_ADJUSTMENT_FACTOR_TO_2M <- x$wind_adjustment_factor
  out$DAYLENGTH_H <- solar$daylength_h
  out$EXTRATERRESTRIAL_RADIATION_MJ_M2_DAY <- ra
  out$CLEAR_SKY_RADIATION_MJ_M2_DAY <- rso
  out$CLEARNESS_INDEX_RS_RA <- ifelse(ra > 0, x$rs_mj_m2_day / ra, NA_real_)
  out$RELATIVE_SOLAR_RADIATION_RS_RSO <- relative_solar_raw
  radiation_qa_flag <- ifelse(
    ra <= 0 & x$rs_mj_m2_day > 0, "positive_rs_during_polar_night",
    ifelse(ra > 0 & x$rs_mj_m2_day > 1.2 * ra, "rs_exceeds_1.2_ra",
           ifelse(rso > 0 & x$rs_mj_m2_day > rso, "rs_exceeds_rso", "ok"))
  )
  out$NET_SHORTWAVE_RADIATION_MJ_M2_DAY <- rns
  out$NET_OUTGOING_LONGWAVE_RADIATION_MJ_M2_DAY <- rnl
  out$NET_RADIATION_MJ_M2_DAY <- rn
  out$ET0_FAO56_RAW_MM_DAY <- et0_raw
  out$ET0_FAO56_MM_DAY <- pmax(et0_raw, 0)
  attr(out, "UFEED_feature_expansion_1_output_units") <- c(
    SATURATION_VAPOR_PRESSURE_TMEAN_KPA = "kPa",
    SATURATION_VAPOR_PRESSURE_DAILY_KPA = "kPa",
    ACTUAL_VAPOR_PRESSURE_KPA = "kPa", VPD_TMEAN_KPA = "kPa",
    VPD_DAILY_FAO56_KPA = "kPa", SPECIFIC_HUMIDITY_KG_KG = "kg kg-1",
    WIND_SPEED_2M_M_S = "m s-1", DAYLENGTH_H = "h",
    NET_RADIATION_MJ_M2_DAY = "MJ m-2 day-1",
    ET0_FAO56_MM_DAY = "mm day-1")
  attr(out, "UFEED_feature_expansion_1_reference") <-
    "FAO Irrigation and Drainage Paper 56 (Allen et al., 1998)"
  attr(out, "UFEED_feature_expansion_1_actual_vapor_pressure_method") <- h$method
  attr(out, "UFEED_feature_expansion_1_radiation_qa_flag") <- radiation_qa_flag
  out
}

UFEED_feature_expansion_1_canonical_units <- function() {
  c(lat = "degree", T2M = "degC", T2M_MAX = "degC", T2M_MIN = "degC",
    T2MDEW = "degC", RH2M = "percent", PS = "kPa", WS2M = "m s-1",
    ALLSKY_SFC_SW_DWN = "MJ m-2 day-1", elevation = "m")
}

# Selected temporal summaries for expansion 1 -------------------------------

UFEED_EXPANSION_1_TEMPORAL_COLUMNS <- c(
  "VPD_DAILY_FAO56_KPA", "VPD_AT_TMAX_PROXY_KPA",
  "DEWPOINT_DEPRESSION_DEGC", "SPECIFIC_HUMIDITY_KG_KG",
  "VPD_WIND_INTERACTION_KPA_M_S", "WIND_SPEED_2M_M_S",
  "CLEARNESS_INDEX_RS_RA", "NET_RADIATION_MJ_M2_DAY", "ET0_FAO56_MM_DAY"
)

.ufe1_temporal_apply <- function(x, dates, key, fun) {
  out <- rep(NA_real_, length(x))
  for (idx in split(seq_along(x), key)) {
    ord <- order(dates[idx]); out[idx[ord]] <- fun(x[idx[ord]])
  }
  out
}

.ufe1_temporal_key <- function(data, columns, label) {
  if (is.null(columns) || !is.character(columns) || !length(columns)) {
    .ufe1_fail("`", label, "` must be a non-empty character vector.")
  }
  missing <- setdiff(columns, names(data))
  if (length(missing)) .ufe1_fail("Missing grouping column(s): ", paste(missing, collapse = ", "))
  interaction(data[columns], drop = TRUE, lex.order = TRUE)
}

.ufe1_running_extreme <- function(x, type) {
  out <- rep(NA_real_, length(x)); current <- if (type == "max") -Inf else Inf
  for (i in seq_along(x)) {
    if (is.finite(x[i])) current <- if (type == "max") max(current, x[i]) else min(current, x[i])
    if (is.finite(current)) out[i] <- current
  }
  out
}

.ufe1_running_sum <- function(x) {
  out <- rep(NA_real_, length(x)); total <- 0
  for (i in seq_along(x)) if (is.finite(x[i])) { total <- total + x[i]; out[i] <- total }
  out
}

#' Add selected EWMA, REWMA, seasonal extrema, and cycle sums to expansion 1.
UFEED_feature_expansion_1_temporal <- function(
    expansion_1_data,
    temporal_group_columns = c("lon", "lat"),
    cycle_id_columns,
    windows = c(7L, 14L, 30L)
) {
  data <- expansion_1_data
  windows <- unique(as.integer(windows))
  if (!length(windows) || any(!is.finite(windows)) || any(windows < 2)) {
    .ufe1_fail("`windows` must contain integers >= 2.")
  }
  required <- unique(c(
    UFEED_EXPANSION_1_TEMPORAL_COLUMNS,
    "VPD_WIND_INTERACTION_KPA_M_S", "NET_RADIATION_MJ_M2_DAY",
    "ET0_FAO56_MM_DAY", "SPECIFIC_HUMIDITY_KG_KG", "CLEARNESS_INDEX_RS_RA"
  ))
  missing <- setdiff(c("Date", required), names(data))
  if (length(missing)) .ufe1_fail("Missing expansion-1 temporal input(s): ", paste(missing, collapse = ", "))
  dates <- as.Date(data$Date); if (anyNA(dates)) .ufe1_fail("Invalid `Date` values.")
  temporal_key <- .ufe1_temporal_key(data, temporal_group_columns, "temporal_group_columns")
  cycle_key <- .ufe1_temporal_key(data, cycle_id_columns, "cycle_id_columns")
  out <- data
  if (!identical(temporal_group_columns, c("lon", "lat"))) {
    .ufe1_fail("The core EWMA/REWMA function groups by `lon` and `lat`; `temporal_group_columns` must be c(\"lon\", \"lat\").")
  }
  if (!exists(".UFEED_compute_EWMA_REWMA_features", mode = "function", inherits = TRUE)) {
    .ufe1_fail("The UFEED core `.UFEED_compute_EWMA_REWMA_features()` function is not loaded.")
  }
  core_smoothed <- .UFEED_compute_EWMA_REWMA_features(
    weather_data = data,
    columns_for_EWMA_REWMA = UFEED_EXPANSION_1_TEMPORAL_COLUMNS,
    EWMA_REWMA_windows = windows,
    max_missing_prop = 0.10,
    require_full_window = TRUE
  )
  data_key <- paste(data$Date, data$lon, data$lat, sep = "\r")
  core_key <- paste(core_smoothed$Date, core_smoothed$lon, core_smoothed$lat, sep = "\r")
  if (anyDuplicated(data_key) || anyDuplicated(core_key)) {
    .ufe1_fail("EWMA/REWMA requires unique Date-lon-lat rows.")
  }
  row_match <- match(data_key, core_key)
  if (anyNA(row_match)) .ufe1_fail("Could not align core EWMA/REWMA results to expansion-1 rows.")
  for (column in setdiff(names(core_smoothed), c("Date", "lon", "lat"))) {
    out[[column]] <- core_smoothed[[column]][row_match]
  }
  season_max <- c("VPD_DAILY_FAO56_KPA", "VPD_AT_TMAX_PROXY_KPA",
                  "VPD_WIND_INTERACTION_KPA_M_S", "WIND_SPEED_2M_M_S",
                  "NET_RADIATION_MJ_M2_DAY", "ET0_FAO56_MM_DAY")
  season_min <- c("SPECIFIC_HUMIDITY_KG_KG", "CLEARNESS_INDEX_RS_RA",
                  "NET_RADIATION_MJ_M2_DAY")
  for (column in season_max) out[[paste0(column, "_SEASON_TO_DATE_MAX")]] <-
    .ufe1_temporal_apply(data[[column]], dates, cycle_key, function(x) .ufe1_running_extreme(x, "max"))
  for (column in season_min) out[[paste0(column, "_SEASON_TO_DATE_MIN")]] <-
    .ufe1_temporal_apply(data[[column]], dates, cycle_key, function(x) .ufe1_running_extreme(x, "min"))
  for (column in c("ET0_FAO56_MM_DAY", "NET_RADIATION_MJ_M2_DAY")) {
    out[[paste0(column, "_CYCLE_CUMSUM")]] <-
      .ufe1_temporal_apply(data[[column]], dates, cycle_key, .ufe1_running_sum)
  }
  new_columns <- setdiff(names(out), names(data))
  stopifnot(all(vapply(out[new_columns], is.numeric, logical(1))))
  attr(out, "UFEED_feature_expansion_1_temporal_feature_count") <- length(new_columns)
  out
}
