# Map only fields with compatible daily definitions and units. In particular,
# Open-Meteo's 10 m winds cannot silently fill measured 2 m winds.
ufeed_open_meteo_fields <- function() {
  c(T2M = "temperature_2m_mean", T2M_MAX = "temperature_2m_max",
    T2M_MIN = "temperature_2m_min", T2MDEW = "dew_point_2m_mean",
    PRECTOTCORR = "precipitation_sum", RH2M = "relative_humidity_2m_mean",
    ALLSKY_SFC_SW_DWN = "shortwave_radiation_sum")
}

# Open-Meteo charges fractional weighted calls, not simply HTTP transactions.
# This workflow sends one location and one weather model per transaction.
ufeed_open_meteo_calls <- function(variables, days, locations = 1, models = 1) {
  locations * pmax(1, variables * models / 10 * pmax(1, days / 14))
}

ufeed_weather_jobs <- function(daily, sites, variables, gaps, last, issue,
                               download_history, forecast_days, provider) {
  jobs <- list()
  for (i in seq_len(nrow(sites))) {
    site <- sites[i, , drop = FALSE]
    rows <- which(daily$lon == site$lon & daily$lat == site$lat)
    if (download_history) {
      history <- rows[daily$Date[rows] <= last]
      fields <- variables[colSums(gaps[history, , drop = FALSE]) > 0L]
      if (provider == "open_meteo") fields <- intersect(fields, names(ufeed_open_meteo_fields()))
      # POWER's 20-parameter limit applies to this request, not to TESViS.
      for (batch in split(fields, ceiling(seq_along(fields) / 20))) {
        dates <- daily$Date[history[rowSums(gaps[history, batch, drop = FALSE]) > 0L]]
        jobs[[length(jobs) + 1L]] <- list(provider = provider, site = site,
          start = min(dates), end = max(dates), fields = batch, forecast = FALSE)
      }
    }
    fields <- intersect(variables, names(ufeed_open_meteo_fields()))
    if (forecast_days && length(fields)) {
      jobs[[length(jobs) + 1L]] <- list(provider = "open_meteo", site = site,
        start = issue + 1, end = issue + forecast_days, fields = fields, forecast = TRUE)
    }
  }
  jobs
}

ufeed_run_weather_jobs <- function(jobs, daily, progress) {
  filled <- list()
  report <- data.frame(provider = character(), start = as.Date(character()),
                       end = as.Date(character()), estimated_open_meteo_calls = numeric())
  weights <- vapply(jobs, function(job) {
    if (job$provider != "open_meteo") return(0)
    # Forecast requests also include today, which Open-Meteo counts.
    days <- as.integer(job$end - job$start) + 1L + job$forecast
    ufeed_open_meteo_calls(length(job$fields), days)
  }, numeric(1))
  if (length(jobs) && isTRUE(progress)) {
    message(sprintf("Weather: %d requests planned; %.2f estimated Open-Meteo calls.",
                    length(jobs), sum(weights)))
  }
  for (i in seq_along(jobs)) {
    job <- jobs[[i]]
    fetched <- ufeed_fetch_weather(job)
    rows <- which(daily$lon == job$site$lon & daily$lat == job$site$lat &
                    daily$Date >= job$start & daily$Date <= job$end)
    matches <- match(daily$Date[rows], fetched$Date)
    for (field in intersect(job$fields, names(fetched))) {
      values <- fetched[[field]][matches]
      replace <- is.na(daily[[field]][rows]) & is.finite(values)
      if (any(replace)) {
        daily[[field]][rows[replace]] <- values[replace]
        filled[[length(filled) + 1L]] <- data.frame(
          daily[rows[replace], c("Date", "lon", "lat")], variable = field,
          source = job$provider, forecast = job$forecast)
      }
    }
    report[nrow(report) + 1L, ] <- list(job$provider, job$start, job$end, weights[i])
    if (isTRUE(progress)) message(sprintf("Weather downloads: %d/%d (%.0f%%).",
                                          i, length(jobs), 100 * i / length(jobs)))
  }
  list(data = daily, report = report, filled = if (length(filled)) do.call(rbind, filled)
    else data.frame(Date = as.Date(character()), lon = numeric(), lat = numeric(),
                    variable = character(), source = character(), forecast = logical()))
}

ufeed_fetch_weather <- function(job) {
  site <- job$site
  query <- list(latitude = site$lat, longitude = site$lon)
  if (job$provider == "power") {
    url <- "https://power.larc.nasa.gov/api/temporal/daily/point"
    query <- c(query, list(start = format(job$start, "%Y%m%d"),
      end = format(job$end, "%Y%m%d"), community = "AG", format = "JSON",
      parameters = paste(UFEED_prepare_power_parameters(job$fields), collapse = ","),
      `time-standard` = "UTC"))
    payload <- ufeed_weather_json(url, query, "NASA POWER")$properties$parameter
    if (!length(payload)) stop("NASA POWER returned no weather parameters.", call. = FALSE)
    dates <- sort(unique(unlist(lapply(payload, names))))
    out <- data.frame(Date = as.Date(dates, "%Y%m%d"))
    for (field in job$fields) {
      values <- as.numeric(unlist(payload[[UFEED_prepare_power_parameters(field)]])[dates])
      if (length(values) == length(dates)) out[[field]] <- replace(values, values == -999, NA)
    }
    return(out)
  }

  # Build the URL from known hosts only. Keep the key out of diagnostics and errors.
  key <- Sys.getenv("OPEN_METEO_API_KEY", unset = "")
  host <- if (job$forecast) "api" else "archive-api"
  if (nzchar(key)) {
    host <- paste0("customer-", host)
    query$apikey <- key
  }
  endpoint <- if (job$forecast) "forecast" else "archive"
  url <- paste0("https://", host, ".open-meteo.com/v1/", endpoint)
  mapping <- ufeed_open_meteo_fields()[job$fields]
  query$daily <- paste(unname(mapping), collapse = ",")
  query$timezone <- "UTC"
  if (job$forecast) {
    query$forecast_days <- as.integer(job$end - job$start) + 2L
    query$models <- "gfs_seamless"
  } else {
    query$start_date <- format(job$start)
    query$end_date <- format(job$end)
    query$models <- "era5"
  }
  result <- ufeed_weather_json(url, query, "Open-Meteo")
  if (is.null(result$daily$time)) stop("Open-Meteo returned no daily dates.", call. = FALSE)
  out <- data.frame(Date = as.Date(result$daily$time))
  for (field in names(mapping)) {
    values <- result$daily[[mapping[[field]]]]
    if (length(values) == nrow(out)) out[[field]] <- as.numeric(values)
  }
  out
}

ufeed_weather_json <- function(url, query, provider) {
  response <- tryCatch(httr::RETRY("GET", url, query = query, httr::timeout(45),
    times = 3L, terminate_on = c(400, 401, 403, 404, 422), quiet = TRUE),
    error = function(e) stop(provider, " request could not connect.", call. = FALSE))
  status <- httr::status_code(response)
  if (status != 200L) {
    hint <- if (status == 429L) " (rate limited; try again later)" else ""
    stop(provider, " returned HTTP ", status, hint, ".", call. = FALSE)
  }
  jsonlite::fromJSON(httr::content(response, as = "text", encoding = "UTF-8"))
}
