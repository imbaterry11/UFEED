#' Build environmental features from downloaded or supplied data
#'
#' @param lon,lat Site coordinates, or `lon` and `lat` columns in weather.
#' @param start_date,end_date Inclusive dates. Defaults to supplied weather
#'   dates, or the current year through today for downloaded weather.
#' @param weather Daily data with Date and UFEED weather columns in canonical units.
#' @param soil Optional soil table; with multiple sites it must have coordinate keys.
#' @param modules Feature groups: weather, soil, derived, or satellite.
#'   "core" is shorthand for weather and soil.
#' @param weather_data_source Historical weather provider: power or open_meteo.
#' @param soil_data_source Soil provider: remote, local, or none. NULL uses
#'   remote for downloaded weather and none for supplied weather.
#' @param soil_data_local_dir Local soil directory when using local soils.
#' @param fill_missing Fill gaps in supplied canonical weather fields.
#' @param forecast_days Number of future dates to request from Open-Meteo (0–15).
#' @param prediction_ready Exclude noncausal Core summaries and interpolation.
#' @param as_of Issue date; defaults to today in prediction-ready mode.
#' @param progress Show planned calls, completed requests and data coverage.
#' @param satellite_cache_dir Directory for reusable NASA MODIS point subsets.
#' @param satellite_half_width_km Half-width of the optional square satellite
#'   fallback window. Set to zero for point-only extraction.
#' @param crop_model Optional crop name and configured runners or CroptimizR
#'   wrappers. Engine outputs are joined by date and coordinates.
#' @return A daily feature data frame, with download and fill diagnostics as attributes.
#' @export
UFEED <- function(lon = NULL, lat = NULL, start_date = NULL, end_date = NULL,
                  weather = NULL, soil = NULL, modules = c("weather", "soil"),
                  weather_data_source = c("power", "open_meteo"),
                  soil_data_source = NULL, soil_data_local_dir = "",
                  fill_missing = FALSE, forecast_days = 0L,
                  prediction_ready = FALSE, as_of = NULL, progress = interactive(),
                  satellite_cache_dir = tools::R_user_dir("UFEED", "cache"),
                  satellite_half_width_km = 3L, crop_model = NULL) {
  weather_data_source <- match.arg(weather_data_source)
  modules <- match.arg(modules, c("weather", "soil", "derived", "satellite", "core"),
                       several.ok = TRUE)
  if ("core" %in% modules) modules <- union(setdiff(modules, "core"), c("weather", "soil"))
  stopifnot(is.logical(fill_missing), length(fill_missing) == 1L, !is.na(fill_missing),
            is.logical(prediction_ready), length(prediction_ready) == 1L,
            !is.na(prediction_ready))
  forecast_days <- UFEED_validate_positive_integerish(forecast_days, "forecast_days",
                                                      min_value = 0L)
  if (length(forecast_days) != 1L || forecast_days > 15L) {
    stop("Supply one forecast_days value from 0 to 15.", call. = FALSE)
  }
  today <- as.Date(Sys.time(), tz = "UTC")
  issue <- ufeed_date(as_of, today)
  if (issue > today || (forecast_days > 0L && issue != today)) {
    stop("Live forecast weather can only be requested for today's issue date.", call. = FALSE)
  }
  supplied <- !is.null(weather)
  if (identical(modules, "soil") && !is.null(soil)) return(soil)
  keys <- c("Date", "lon", "lat")
  weather <- ufeed_input_weather(weather, lon, lat)
  sites <- unique(weather[c("lon", "lat")])
  if (is.null(soil_data_source)) {
    soil_data_source <- if ("soil" %in% modules && (!supplied || identical(modules, "soil")))
      "remote" else "none"
  }
  soil_data_source <- match.arg(soil_data_source, c("remote", "local", "none"))
  if (!"soil" %in% modules) {
    soil_data_source <- "none"
    soil <- NULL
  }
  if (anyNA(sites) && (!supplied || fill_missing || forecast_days > 0L ||
      "satellite" %in% modules || (is.null(soil) && soil_data_source != "none"))) {
    stop("Coordinates are required for downloading data.", call. = FALSE)
  }
  # A soil-only request is a site table; it needs neither a date grid nor weather.
  if (identical(modules, "soil")) {
    if (soil_data_source == "none") stop("Select a soil source or supply a soil table.")
    return(UFEED_get_soil_features(sites$lon, sites$lat, soil_data_source,
                                   soil_data_local_dir))
  }
  first <- ufeed_date(start_date, if (supplied) min(weather$Date) else
    as.Date(paste0(format(issue, "%Y"), "-01-01")))
  last <- ufeed_date(end_date, if (supplied) max(weather$Date) else issue)
  if (prediction_ready || !supplied || fill_missing || forecast_days > 0L) {
    last <- min(last, issue)
  }
  if (first > last || (forecast_days > 0L && last != issue)) {
    stop("Check the date range; live forecasts must follow today's end date.", call. = FALSE)
  }

  # Build an explicit daily grid so omitted dates are treated like NA cells.
  variables <- if (supplied) intersect(names(weather), UFEED_WEATHER_PARAMETERS_HISTORY)
    else if (weather_data_source == "power") UFEED_WEATHER_PARAMETERS_HISTORY else
      names(ufeed_open_meteo_fields())
  grid <- do.call(rbind, lapply(seq_len(nrow(sites)), function(i) {
    data.frame(Date = seq(first, last + forecast_days, by = "day"),
               lon = sites$lon[i], lat = sites$lat[i])
  }))
  daily <- if (supplied) dplyr::left_join(grid, weather, by = keys) else grid
  for (variable in variables) {
    if (!variable %in% names(daily)) daily[[variable]] <- NA_real_
    if (!is.numeric(daily[[variable]]) && !all(is.na(daily[[variable]]))) {
      stop("Weather column must be numeric: ", variable, call. = FALSE)
    }
  }
  # Never treat a supplied future row as an observation or a forecast issued by UFEED.
  if (forecast_days > 0L && supplied) {
    daily[daily$Date > last, setdiff(names(daily), keys)] <- NA
  }
  gaps <- is.na(daily[variables])
  jobs <- ufeed_weather_jobs(daily, sites, variables, gaps, last, issue,
                             !supplied || fill_missing, forecast_days,
                             weather_data_source)
  downloaded <- ufeed_run_weather_jobs(jobs, daily, progress)
  daily <- downloaded$data
  weather_out <- daily
  core_modules <- UFEED_MODULES[1:4]
  if (prediction_ready) core_modules <- c("cumsum_features", "cumulative_temp_features")
  # The season and reconstructed hourly temperature need geographic inputs.
  # Ordinary moving averages only need a series ID, not a real coordinate.
  core_input <- daily
  anonymous_site <- anyNA(sites)
  if (anonymous_site) {
    core_modules <- intersect(core_modules, "EWMA_REWMA_features")
    site_keys <- dplyr::left_join(daily[c("lon", "lat")],
      dplyr::mutate(sites, series_id = seq_len(nrow(sites))), by = c("lon", "lat"))
    core_input$lon <- site_keys$series_id
    core_input$lat <- 0
  }
  if ("weather" %in% modules) {
    features <- UFEED_compute_weather_features(
      core_input, included_module = core_modules, feature_profile = "history",
      cumulative_temp_fill_direction = if (prediction_ready) "down" else "downup",
      message_progress = FALSE, cumulative_temp_message_missing = FALSE)
    if (anonymous_site) {
      ids <- features$lon
      features$lon <- sites$lon[ids]
      features$lat <- sites$lat[ids]
    }
    weather_out <- UFEED_add_daily_temp_fluctuation(weather_out)
    weather_out <- UFEED_safe_left_join_features(weather_out, features)
  }
  if (is.null(soil) && soil_data_source != "none") {
    soil <- UFEED_get_soil_features(sites$lon, sites$lat, soil_data_source,
                                   soil_data_local_dir)
  }
  if (!is.null(soil)) {
    if (!all(c("lon", "lat") %in% names(soil)) && nrow(soil) == 1L && nrow(sites) == 1L) {
      soil$lon <- sites$lon
      soil$lat <- sites$lat
    }
    weather_out <- UFEED_wrap_up(weather_out, soil_features = soil, clean_names = FALSE)
  }
  if ("derived" %in% modules) {
    if (anyNA(sites)) stop("Derived process features require site coordinates.", call. = FALSE)
    weather_out <- UFEED_safe_left_join_features(weather_out, .ufeed_reference_crop_processes(daily))
  }
  if (!is.null(crop_model)) {
    if (!is.list(crop_model) || is.null(crop_model$crop) ||
        !length(c(crop_model$runners, crop_model$croptimizr))) {
      stop("crop_model needs a crop name and at least one configured engine.", call. = FALSE)
    }
    simulations <- .UFEED_compute_crop_model_features(
      daily, soil, crop_model$crop, crop_model$runners, crop_model$croptimizr)
    weather_out <- UFEED_safe_left_join_features(weather_out, simulations$features)
    attr(weather_out, "crop_model_status") <- simulations$status
  }
  if ("satellite" %in% modules) {
    half_width <- UFEED_validate_positive_integerish(
      satellite_half_width_km, "satellite_half_width_km", min_value = 0L)
    if (length(half_width) != 1L || half_width > 100L) {
      stop("satellite_half_width_km must be one integer from 0 to 100.", call. = FALSE)
    }
    # Fetch each site/product series once, then align it to the daily output.
    # Future rows may reuse information known on the issue date, not future images.
    satellite <- ufeed_satellite_series(weather_out[keys], last, prediction_ready,
      cache_dir = satellite_cache_dir, half_width_km = half_width)
    weather_out <- dplyr::left_join(weather_out, satellite, by = keys)
  }
  recovered <- sum(gaps & !is.na(daily[variables]))
  attr(weather_out, "download_report") <- downloaded$report
  attr(weather_out, "weather_fill") <- downloaded$filled
  attr(weather_out, "weather_coverage") <- c(expected = length(gaps),
    available = sum(!is.na(daily[variables])), missing_before = sum(gaps),
    downloaded = recovered, missing_after = sum(is.na(daily[variables])))
  if (isTRUE(progress) && length(gaps)) {
    message(sprintf("Weather coverage: %d/%d values (%.1f%%); %d gaps remain.",
      sum(!is.na(daily[variables])), length(gaps),
      100 * mean(!is.na(daily[variables])), sum(is.na(daily[variables]))))
    if (supplied && fill_missing) {
      observed <- daily$Date <= last
      requested_gaps <- sum(gaps[observed, , drop = FALSE])
      recovered_gaps <- sum(gaps[observed, , drop = FALSE] &
        !is.na(daily[observed, variables, drop = FALSE]))
      if (requested_gaps) message(sprintf("Supplied weather: %d/%d gaps filled (%.1f%%).",
        recovered_gaps, requested_gaps, 100 * recovered_gaps / requested_gaps))
    }
  }
  weather_out
}

ufeed_date <- function(value, default) {
  if (is.null(value)) return(default)
  value <- as.Date(value)
  if (length(value) != 1L || is.na(value)) stop("Supply one valid date.", call. = FALSE)
  value
}

ufeed_input_weather <- function(weather, lon, lat) {
  if (is.null(weather)) {
    if (is.null(lon) || is.null(lat)) stop("Supply lon and lat, or a weather table.")
    coords <- UFEED_normalize_coordinates(lon, lat)
    return(coords[c("lon", "lat")])
  }
  if (!is.data.frame(weather) || !nrow(weather) || !"Date" %in% names(weather)) {
    stop("Supply a nonempty weather table with a Date column.", call. = FALSE)
  }
  weather$Date <- as.Date(weather$Date)
  if (!"lon" %in% names(weather)) weather$lon <- if (is.null(lon)) NA_real_ else lon
  if (!"lat" %in% names(weather)) weather$lat <- if (is.null(lat)) NA_real_ else lat
  if (!is.numeric(weather$lon) || !is.numeric(weather$lat) ||
      any(!is.na(weather$lon) & (!is.finite(weather$lon) | abs(weather$lon) > 180)) ||
      any(!is.na(weather$lat) & (!is.finite(weather$lat) | abs(weather$lat) > 90)) ||
      anyNA(weather$Date) || anyDuplicated(weather[c("Date", "lon", "lat")])) {
    stop("Weather requires numeric coordinates and unique, valid site/date keys.",
         call. = FALSE)
  }
  weather
}
