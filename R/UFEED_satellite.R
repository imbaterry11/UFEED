#' NASA MODIS canopy features for a land coordinate
#'
#' Returns the latest quality-screened canopy composites without Earth Engine.
#' In prediction-ready mode, only completed composites already seen in the
#' local cache by the issue date are eligible. A download today cannot establish
#' availability on an earlier historical issue date.
#' @param lat,lon Latitude and longitude in decimal degrees.
#' @param as_of Issue date (UTC, inclusive).
#' @param prediction_ready Restrict inputs to composites known by the issue date.
#' @param lookback_days Number of days before the issue date to search.
#' @param cache_dir Directory for site/product/composite cache files.
#' @return A one-row data frame with canopy values, dates, and age in days.
#' @export
UFEED_satellite <- function(lat, lon, as_of = as.Date(Sys.time(), tz = "UTC"),
                            prediction_ready = TRUE, lookback_days = 48L,
                            cache_dir = tools::R_user_dir("UFEED", "cache")) {
  stopifnot(length(lat) == 1L, is.numeric(lat), is.finite(lat), abs(lat) <= 90,
            length(lon) == 1L, is.numeric(lon), is.finite(lon), abs(lon) <= 180,
            is.logical(prediction_ready), length(prediction_ready) == 1L,
            !is.na(prediction_ready), is.numeric(lookback_days),
            length(lookback_days) == 1L, is.finite(lookback_days), lookback_days >= 0)
  as_of <- as.Date(as_of)
  today <- as.Date(Sys.time(), tz = "UTC")
  stopifnot(length(as_of) == 1L, !is.na(as_of), as_of <= today)
  result <- data.frame(lat = lat, lon = lon, as_of = as_of)
  for (product in c("MCD15A3H", "MOD13Q1")) {
    rows <- ufeed_modis_composites(product, lat, lon, as_of, today,
                                  prediction_ready, lookback_days, cache_dir)
    features <- if (product == "MCD15A3H") c("LAI", "FPAR") else c("NDVI", "EVI")
    for (feature in features) {
      values <- vapply(rows, function(x) ufeed_modis_value(x$bands, feature), numeric(1))
      valid <- which(!is.na(values))
      i <- if (length(valid)) tail(valid, 1L) else NA_integer_
      end <- if (is.na(i)) as.Date(NA_character_) else rows[[i]]$end
      result[[paste0("most_recent_", feature)]] <- if (is.na(i)) NA_real_ else values[i]
      result[[paste0(feature, "_composite_end")]] <- end
      result[[paste0(feature, "_age_days")]] <- as.integer(as_of - end)
      result[[paste0(feature, "_quality")]] <- if (is.na(i)) NA_integer_ else
        as.integer(rows[[i]]$bands[[ufeed_modis_band(feature)[2L]]])
    }
  }
  result
}

ufeed_modis_get <- function(product, resource, query) {
  url <- paste("https://modis.ornl.gov/rst/api/v1", product, resource, sep = "/")
  response <- httr::RETRY("GET", url, query = query, httr::timeout(30),
                          times = 3L, terminate_on = c(400, 401, 403, 404, 422),
                          quiet = TRUE)
  httr::stop_for_status(response)
  jsonlite::fromJSON(httr::content(response, as = "text", encoding = "UTF-8"),
                     simplifyVector = FALSE)
}

ufeed_modis_composites <- function(product, lat, lon, as_of, today,
                                   prediction_ready, lookback_days, cache_dir,
                                   half_width_km = 0L) {
  site <- paste(sprintf("%.10f", c(lat, lon)), collapse = "_")
  directory <- file.path(cache_dir, "tesvis-v1", site, product)
  if (half_width_km > 0L) {
    directory <- file.path(cache_dir, "tesvis-v1-neighborhood",
                           paste0(half_width_km, "km"), site, product)
  }
  files <- list.files(directory, pattern = "^A[0-9]{7}\\.rds$", full.names = TRUE)
  id <- sub("\\.rds$", "", basename(files))
  query <- list(latitude = lat, longitude = lon)
  fetch <- !prediction_ready || as_of == today
  if (fetch) {
    dates <- ufeed_modis_get(product, "dates", query)$dates
    id <- union(id, vapply(dates, function(x) x$modis_date, character(1)))
  }
  id <- sort(id[grepl("^A[0-9]{7}$", id)])
  start <- as.Date(sub("^A", "", id), format = "%Y%j")
  cadence <- switch(product, MCD15A3H = 4L, MOD16A2GF = 8L, 16L)
  end <- pmin(start + cadence - 1L,
              as.Date(paste0(substr(id, 2L, 5L), "-12-31"), format = "%Y-%m-%d"))
  keep <- which(end < as_of & end >= as_of - lookback_days)
  paths <- file.path(directory, paste0(id, ".rds"))
  missing <- keep[!file.exists(paths[keep])]
  if (fetch && length(missing)) {
    dir.create(directory, recursive = TRUE, showWarnings = FALSE)
    # Request only contiguous runs of uncached catalog dates, at most ten.
    groups <- cumsum(c(TRUE, diff(missing) != 1L))
    for (run in split(missing, groups)) {
      for (batch in split(run, ceiling(seq_along(run) / 10))) {
        data <- ufeed_modis_get(product, "subset", c(query, list(
          startDate = id[min(batch)], endDate = id[max(batch)],
          kmAboveBelow = half_width_km, kmLeftRight = half_width_km)))$subset
        for (j in batch) {
          entries <- Filter(function(x) identical(x$modis_date, id[j]), data)
          if (!length(entries)) next
          bands <- setNames(lapply(entries, function(x) {
            # Preserve pixel positions even if the API returns JSON nulls.
            vapply(x$data, function(value) {
              if (length(value) == 1L) as.numeric(value) else NA_real_
            }, numeric(1))
          }), vapply(entries, function(x) x$band, character(1)))
          saveRDS(list(end = end[j], first_seen = today, bands = bands), paths[j])
        }
      }
    }
  }
  rows <- lapply(paths[keep][file.exists(paths[keep])], readRDS)
  if (prediction_ready) rows <- Filter(function(x) x$first_seen <= as_of, rows)
  rows
}

ufeed_modis_band <- function(feature) {
  switch(feature,
         LAI = c("Lai_500m", "FparLai_QC"),
         FPAR = c("Fpar_500m", "FparLai_QC"),
         NDVI = c("250m_16_days_NDVI", "250m_16_days_pixel_reliability"),
         EVI = c("250m_16_days_EVI", "250m_16_days_pixel_reliability"))
}

ufeed_modis_value <- function(bands, feature) {
  keys <- ufeed_modis_band(feature)
  value <- bands[[keys[1L]]]
  qa <- bands[[keys[2L]]]
  if (length(value) != 1L || length(qa) != 1L || !is.finite(value) || !is.finite(qa)) {
    return(NA_real_)
  }
  if (feature %in% c("LAI", "FPAR")) {
    # Require clear sky and a successful main algorithm (including saturation).
    if (value < 0 || value > 100 || bitwAnd(qa, 25L) != 0L ||
        bitwAnd(bitwShiftR(qa, 5L), 7L) > 1L) return(NA_real_)
    return(value * if (feature == "LAI") 0.1 else 0.01)
  }
  if (qa != 0 || value < -2000 || value > 10000) return(NA_real_)
  value * 0.0001
}

# A composite's end date is not its publication date. Retrospective extraction
# can use finalized archive data; an as-of run also checks the first-seen cache
# date. Forecast rows share the observation cutoff of the issue date.
ufeed_satellite_series <- function(daily, issue, prediction_ready, cache_dir,
                                   max_age_days = 48L, half_width_km = 0L) {
  products <- list(MCD15A3H = c("LAI", "FPAR"), MOD13Q1 = c("NDVI", "EVI"))
  if (!prediction_ready) products$MOD16A2GF <- "ET_mm_composite"
  keys <- c("Date", "lon", "lat")
  sites <- .ufeed_daily_groups(daily, keys)
  results <- lapply(sites, function(indices) {
    out <- daily[indices, keys, drop = FALSE]
    cutoff <- pmin(out$Date, issue)
    today <- as.Date(Sys.time(), tz = "UTC")
    for (product in names(products)) {
      lookback <- as.integer(issue - min(cutoff)) + max_age_days
      rows <- ufeed_modis_composites(product, out$lat[1], out$lon[1], issue,
        today, prediction_ready, lookback, cache_dir)
      ends <- vapply(rows, function(row) as.numeric(row$end), numeric(1))
      first_seen <- vapply(rows, function(row) as.numeric(row$first_seen), numeric(1))
      neighborhood <- NULL
      for (feature in products[[product]]) {
        quality_band <- if (product == "MOD16A2GF") "ET_QC_500m" else
          ufeed_modis_band(feature)[2L]
        quality <- vapply(rows, function(row) {
          value <- row$bands[[quality_band]]
          if (length(value) == 1L && is.finite(value)) as.integer(value) else NA_integer_
        }, integer(1))
        values <- vapply(rows, function(row) {
          if (product == "MOD16A2GF") ufeed_modis_et_value(row$bands) else
            ufeed_modis_value(row$bands, feature)
        }, numeric(1))
        selected <- vapply(as.numeric(cutoff), function(day) {
          eligible <- which(!is.na(values) & ends < day & ends >= day - max_age_days &
            (!prediction_ready | first_seen <= day))
          if (length(eligible)) tail(eligible, 1L) else NA_integer_
        }, integer(1))
        out[[paste0("most_recent_", feature)]] <- values[selected]
        out[[paste0(feature, "_composite_end")]] <- as.Date(ends[selected], origin = "1970-01-01")
        out[[paste0(feature, "_age_days")]] <- as.integer(out$Date -
          out[[paste0(feature, "_composite_end")]])
        out[[paste0(feature, "_quality")]] <- quality[selected]
        source <- ifelse(is.na(selected), "unavailable", "point")
        pixels <- ifelse(is.na(selected), 0L, 1L)
        if (half_width_km > 0L && anyNA(selected)) {
          # Only query the wider window when the point series leaves a gap.
          # Reuse the same neighborhood response for every band in a product.
          if (is.null(neighborhood)) {
            neighborhood <- tryCatch(
              ufeed_modis_composites(product, out$lat[1], out$lon[1], issue,
                today, prediction_ready, lookback, cache_dir, half_width_km),
              error = function(e) {
                warning("MODIS neighborhood unavailable for ", product, " at ",
                        out$lat[1], ", ", out$lon[1], ": ", conditionMessage(e),
                        call. = FALSE)
                list()
              })
          }
          fallback <- ufeed_modis_neighborhood_values(neighborhood, feature, quality_band)
          for (i in which(is.na(selected))) {
            day <- as.numeric(cutoff[i])
            eligible <- which(fallback$pixels > 0L & fallback$end < day &
              fallback$end >= day - max_age_days &
              (!prediction_ready | fallback$first_seen <= day))
            if (!length(eligible)) next
            j <- tail(eligible, 1L)
            end_date <- as.Date(fallback$end[j], origin = "1970-01-01")
            out[[paste0("most_recent_", feature)]][i] <- fallback$value[j]
            out[[paste0(feature, "_composite_end")]][i] <- end_date
            out[[paste0(feature, "_age_days")]][i] <- as.integer(out$Date[i] - end_date)
            source[i] <- "neighborhood_median"
            pixels[i] <- fallback$pixels[j]
          }
        }
        out[[paste0(feature, "_source")]] <- source
        out[[paste0(feature, "_valid_pixels")]] <- pixels
        out[[paste0(feature, "_half_width_km")]] <- ifelse(
          source == "neighborhood_median", half_width_km,
          ifelse(source == "point", 0L, NA_integer_))
      }
    }
    out
  })
  do.call(rbind, unname(results))
}

ufeed_modis_neighborhood_values <- function(rows, feature, quality_band) {
  band <- if (feature == "ET_mm_composite") "ET_500m" else
    ufeed_modis_band(feature)[1L]
  result <- data.frame(
    end = vapply(rows, function(row) as.numeric(row$end), numeric(1)),
    first_seen = vapply(rows, function(row) as.numeric(row$first_seen), numeric(1)),
    value = rep(NA_real_, length(rows)), pixels = integer(length(rows)))
  for (i in seq_along(rows)) {
    raw <- rows[[i]]$bands[[band]]
    qa <- rows[[i]]$bands[[quality_band]]
    if (length(raw) != length(qa)) next
    values <- vapply(seq_along(raw), function(j) {
      pixel <- setNames(list(raw[j], qa[j]), c(band, quality_band))
      if (feature == "ET_mm_composite") ufeed_modis_et_value(pixel) else
        ufeed_modis_value(pixel, feature)
    }, numeric(1))
    valid <- values[is.finite(values)]
    if (length(valid)) {
      result$value[i] <- stats::median(valid)
      result$pixels[i] <- length(valid)
    }
  }
  result
}

ufeed_modis_et_value <- function(bands) {
  value <- bands[["ET_500m"]]
  qa <- bands[["ET_QC_500m"]]
  if (length(value) != 1L || length(qa) != 1L || !is.finite(value) ||
      !is.finite(qa) || value < 0 || value > 32700 ||
      bitwAnd(qa, 25L) != 0L || bitwAnd(bitwShiftR(qa, 5L), 7L) > 1L) {
    return(NA_real_)
  }
  value * 0.1
}
