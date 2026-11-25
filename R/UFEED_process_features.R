.ufeed_daily_groups <- function(x, keys) {
  if (!is.data.frame(x) || !nrow(x) || !all(keys %in% names(x)) ||
      !inherits(x$Date, "Date") || anyNA(x[keys]) ||
      anyDuplicated(x[keys]) || any(!is.finite(x$lon) | !is.finite(x$lat))) {
    stop("Expected unique, complete daily Date/lon/lat keys.", call. = FALSE)
  }
  split(seq_len(nrow(x)), interaction(x$lon, x$lat, drop = TRUE))
}

.ufeed_reference_crop_processes <- function(weather) {
  keys <- c("Date", "lon", "lat")
  sites <- .ufeed_daily_groups(weather, keys)
  daily <- function(name) {
    x <- weather[[name]]
    if (!is.numeric(x)) return(rep(NA_real_, nrow(weather)))
    replace(x, !is.finite(x), NA_real_)
  }
  rain <- daily("PRECTOTCORR")
  rain[rain < 0] <- NA_real_
  tmin <- daily("T2M_MIN")
  tmax <- daily("T2M_MAX")
  valid <- !is.na(tmin) & !is.na(tmax) & tmin <= tmax &
    tmin >= -90 & tmax <= 65
  tmin[!valid] <- tmax[!valid] <- NA_real_
  solar <- .ufe1_solar(weather$Date, replace(weather$lat, abs(weather$lat) > 90, NA_real_))
  # FAO-56 Eq. 52 uses extraterrestrial radiation in equivalent mm/day.
  et0 <- 0.0023 * pmax((tmin + tmax) / 2 + 17.8, 0) *
    sqrt(tmax - tmin) * solar$extraterrestrial_radiation * 0.408
  out <- weather[keys]
  out$process_daylength_h <- solar$daylength_h
  out$process_et0_hargreaves_mm <- et0
  out$process_climatic_balance_mm <- rain - et0
  out$process_frost_degc <- pmax(-tmin, 0)
  out$process_heat35_degc <- pmax(tmax - 35, 0)
  for (window in c(7L, 30L)) {
    roll <- rep(NA_real_, nrow(weather))
    for (ix in sites) {
      ix <- ix[order(weather$Date[ix])]
      segments <- split(ix, cumsum(c(TRUE, diff(weather$Date[ix]) != 1)))
      for (rows in segments) {
        if (length(rows) >= window) {
          roll[rows] <- as.numeric(stats::filter(
            out$process_climatic_balance_mm[rows], rep(1, window), sides = 1
          ))
        }
      }
    }
    out[[paste0("process_climatic_balance_mm_", window, "d")]] <- roll
  }
  out
}

UFEED_precipitation_indices <- function(weather, periods = NULL, baseline = NULL) {
  keys <- c("Date", "lon", "lat")
  .ufeed_daily_groups(weather, keys)
  if (!is.numeric(weather$PRECTOTCORR) ||
      any(weather$PRECTOTCORR < 0, na.rm = TRUE)) {
    stop("PRECTOTCORR must be nonnegative daily precipitation in mm.", call. = FALSE)
  }
  if (!is.null(baseline) && (length(baseline) != 2L ||
      !inherits(baseline, "Date") || anyNA(baseline) || baseline[1] > baseline[2])) {
    stop("Supply two ordered Date values for baseline.", call. = FALSE)
  }
  if (is.null(periods)) {
    periods <- unique(data.frame(
      weather[c("lon", "lat")], year = format(weather$Date, "%Y")
    ))
    periods$start <- as.Date(paste0(periods$year, "-01-01"))
    periods$end <- as.Date(paste0(periods$year, "-12-31"))
  }
  if (!is.data.frame(periods) || !all(c("lon", "lat", "start", "end") %in% names(periods)) ||
      !inherits(periods$start, "Date") || !inherits(periods$end, "Date") ||
      anyNA(periods[c("lon", "lat", "start", "end")]) ||
      any(periods$start > periods$end)) {
    stop("Periods need lon, lat and ordered Date columns start and end.", call. = FALSE)
  }
  cols <- c("precip_mm", "wet_days", "r10mm", "r20mm", "r30mm", "cwd", "cdd",
            "dry_spells_ge5", "rx1day", "rx5day", "sdii", "r95p_mm",
            "r95p_share_pct", "calendar_year_precip_share_pct", "pc", "hyl",
            "hc", "dmi_period", "iao_e", "ibcv", "cwb_mm", "crop_balance_mm",
            "crop_deficit_mm")
  for (nm in cols) periods[[nm]] <- rep(NA_real_, nrow(periods))
  periods$complete_precip <- rep(FALSE, nrow(periods))
  periods$baseline_wet_days <- rep(NA_integer_, nrow(periods))
  for (i in seq_len(nrow(periods))) {
    day <- seq(periods$start[i], periods$end[i], by = "day")
    w <- weather[weather$lon == periods$lon[i] & weather$lat == periods$lat[i], ]
    j <- match(day, w$Date)
    p <- w$PRECTOTCORR[j]
    if (!all(is.finite(p))) next
    periods$complete_precip[i] <- TRUE
    wet <- p >= 1
    runs <- rle(wet)
    spells <- rle(p <= 1)
    total <- sum(p)
    wet_total <- sum(p[wet])
    periods[i, cols[1:11]] <- list(
      total, sum(wet), sum(p >= 10), sum(p >= 20), sum(p >= 30),
      max(c(0, runs$lengths[runs$values])), max(c(0, runs$lengths[!runs$values])),
      sum(spells$values & spells$lengths >= 5), max(p),
      if (length(p) >= 5) max(stats::filter(p, rep(1, 5), sides = 1), na.rm = TRUE) else NA_real_,
      if (any(wet)) mean(p[wet]) else NA_real_
    )
    if (!is.null(baseline) && baseline[2] < day[1]) {
      b <- w$PRECTOTCORR[match(seq(baseline[1], baseline[2], by = "day"), w$Date)]
      if (all(is.finite(b))) {
        b <- b[b >= 1]
        periods$baseline_wet_days[i] <- length(b)
        if (length(b) >= 20) {
          q <- stats::quantile(b, 0.95, names = FALSE, type = 8)
          periods$r95p_mm[i] <- sum(p[wet & p > q])
          if (wet_total > 0) periods$r95p_share_pct[i] <- 100 * periods$r95p_mm[i] / wet_total
        }
      }
    }
    yr <- format(day, "%Y")
    if (length(unique(yr)) == 1L) {
      yr_days <- seq(as.Date(paste0(yr[1], "-01-01")), as.Date(paste0(yr[1], "-12-31")), by = "day")
      yp <- w$PRECTOTCORR[match(yr_days, w$Date)]
      if (all(is.finite(yp)) && sum(yp) > 0) {
        periods$calendar_year_precip_share_pct[i] <- 100 * total / sum(yp)
      }
    }
    if (is.numeric(w$T2M) && all(is.finite(t <- w$T2M[j]))) {
      active <- t > 10
      if (any(active)) {
        periods$pc[i] <- total / sum(active)
        periods$hc[i] <- 10 * total / sum(t[active])
      }
      if (mean(t) > -10) periods$dmi_period[i] <- total / (mean(t) + 10)
      months <- format(day, "%Y-%m")
      next_day <- day[length(day)] + 1
      if (format(day[1], "%d") == "01" && format(next_day, "%d") == "01") {
        periods$hyl[i] <- sum(tapply(t, months, mean) * tapply(p, months, mean))
      }
      if (is.numeric(w$sunshine_hours) && all(is.finite(s <- w$sunshine_hours[j]) & s >= 0 & s <= 24)) {
        periods$iao_e[i] <- sum(s) + sum(t[active]) - max(total - 250, 0)
        if (total > 0) periods$ibcv[i] <- sum(t[active]) * sum(s) / (total * length(p) * 10)
      }
    }
    if (is.numeric(w$ET0_FAO56_MM_DAY) && all(is.finite(et <- w$ET0_FAO56_MM_DAY[j]) & et >= 0)) {
      periods$cwb_mm[i] <- sum(p - et)
    }
    if (is.numeric(w$ETC_MM_DAY) && all(is.finite(etc <- w$ETC_MM_DAY[j]) & etc >= 0)) {
      periods$crop_balance_mm[i] <- sum(p - etc)
      periods$crop_deficit_mm[i] <- sum(etc - p)
    }
  }
  periods
}

UFEED_soil_water_capacity <- function(soil, depth_cm = 100) {
  if (!is.data.frame(soil) || !all(c("lon", "lat") %in% names(soil)) ||
      anyNA(soil[c("lon", "lat")]) || anyDuplicated(soil[c("lon", "lat")]) ||
      length(depth_cm) != 1L || !is.finite(depth_cm) || depth_cm <= 0 || depth_cm > 200) {
    stop("Supply unique soil sites and a depth in (0, 200] cm.", call. = FALSE)
  }
  edges <- c(0, 5, 15, 30, 60, 100, 200)
  result <- soil[c("lon", "lat")]
  result$capacity_mm <- rep(0, nrow(soil))
  result$depth_cm <- rep(depth_cm, nrow(soil))
  for (k in which(utils::head(edges, -1) < depth_cm)) {
    suffix <- paste0("_", edges[k], "_", edges[k + 1L], "cm")
    get <- function(property) {
      value <- soil[[paste0(property, suffix)]]
      if (is.numeric(value)) value / 1000 else rep(NA_real_, nrow(soil))
    }
    fc <- get("wv0033")
    wp <- get("wv1500")
    rock <- get("cfvo")
    valid <- is.finite(fc) & is.finite(wp) & is.finite(rock) &
      wp >= 0 & fc > wp & fc <= 1 & rock >= 0 & rock <= 1
    contribution <- (fc - wp) * (1 - rock) * 10 *
      (min(edges[k + 1L], depth_cm) - edges[k])
    result$capacity_mm <- result$capacity_mm + ifelse(valid, contribution, NA_real_)
  }
  result
}

UFEED_reference_water_balance <- function(weather, soil, depth_cm = 100,
                                          initial_fraction = 0.5) {
  keys <- c("Date", "lon", "lat")
  sites <- .ufeed_daily_groups(weather, keys)
  if (!is.numeric(weather$PRECTOTCORR) || !is.numeric(weather$ET0_FAO56_MM_DAY) ||
      length(initial_fraction) != 1L || !is.finite(initial_fraction) ||
      initial_fraction < 0 || initial_fraction > 1) {
    stop("Supply daily precipitation, reference ET and an initial fraction in [0, 1].", call. = FALSE)
  }
  cap <- UFEED_soil_water_capacity(soil, depth_cm)
  out <- weather[keys]
  for (nm in c("capacity_mm", "storage_mm", "fraction_available", "drainage_mm",
               "actual_et_mm", "unmet_et_mm")) out[[paste0("refsoil_", nm)]] <- rep(NA_real_, nrow(out))
  for (ix in sites) {
    ix <- ix[order(weather$Date[ix])]
    capacity <- cap$capacity_mm[match(TRUE, cap$lon == weather$lon[ix[1]] &
                                             cap$lat == weather$lat[ix[1]])]
    if (!is.finite(capacity) || capacity <= 0) next
    out$refsoil_capacity_mm[ix] <- capacity
    storage <- capacity * initial_fraction
    previous <- weather$Date[ix[1]] - 1
    for (i in ix) {
      rain <- weather$PRECTOTCORR[i]
      demand <- weather$ET0_FAO56_MM_DAY[i]
      if (weather$Date[i] - previous != 1 || !all(is.finite(c(rain, demand))) ||
          min(rain, demand) < 0) break
      water <- storage + rain
      excess <- max(water - capacity, 0)
      available <- water - excess
      et <- min(available, demand)
      storage <- available - et
      out[i, c("refsoil_storage_mm", "refsoil_fraction_available", "refsoil_drainage_mm",
               "refsoil_actual_et_mm", "refsoil_unmet_et_mm")] <-
        list(storage, storage / capacity, excess, et, demand - et)
      previous <- weather$Date[i]
    }
  }
  attr(out, "scenario") <- list(depth_cm = depth_cm, initial_fraction = initial_fraction,
                                irrigation = "rainfed", demand = "reference ET0")
  out
}

.ufeed_run_croptimizr <- function(config) {
  sites <- config$sites
  if (!is.function(config$wrapper) || !is.data.frame(sites) ||
      !all(c("situation", "lon", "lat") %in% names(sites)) ||
      !nrow(sites) || !is.character(sites$situation) ||
      anyNA(sites[c("situation", "lon", "lat")]) ||
      any(!nzchar(sites$situation)) || anyDuplicated(sites$situation) ||
      !is.numeric(sites$lon) || !is.numeric(sites$lat) ||
      any(!is.finite(sites$lon) | !is.finite(sites$lat))) {
    stop("Supply a CroptimizR wrapper and a sites table with unique situation names and coordinates.")
  }
  result <- config$wrapper(param_values = config$param_values,
                           situation = sites$situation,
                           model_options = config$model_options)
  if (!is.list(result) || !identical(result$error, FALSE)) {
    stop("The CroptimizR wrapper did not report a successful simulation.")
  }
  sim <- result$sim_list
  if (!is.list(sim) || anyDuplicated(names(sim)) ||
      !setequal(sites$situation, names(sim))) {
    stop("The CroptimizR wrapper must return one named result per requested situation.")
  }
  frames <- lapply(seq_len(nrow(sites)), function(i) {
    x <- sim[[sites$situation[i]]]
    if (!is.data.frame(x) || !nrow(x) || anyDuplicated(names(x)) ||
        !inherits(x$Date, c("Date", "POSIXct")) ||
        any(c("lon", "lat") %in% names(x))) {
      stop("Invalid daily CroptimizR output for situation ", sites$situation[i], ".")
    }
    x$Date <- if (inherits(x$Date, "POSIXct")) {
      as.Date(format(x$Date, "%Y-%m-%d"))
    } else {
      x$Date
    }
    x$lon <- sites$lon[i]
    x$lat <- sites$lat[i]
    x
  })
  dplyr::bind_rows(frames)
}

.UFEED_compute_crop_model_features <- function(weather, soil, crop, runners, croptimizr) {
  if (is.null(runners)) runners <- list()
  if (is.null(croptimizr)) croptimizr <- list()
  keys <- c("Date", "lon", "lat")
  .ufeed_daily_groups(weather, keys)
  engines <- c("stics", "dssat", "apsim")
  if (!is.character(crop) || length(crop) != 1L || is.na(crop) || !nzchar(crop) ||
      !is.list(runners) || (length(runners) && (is.null(names(runners)) ||
      anyDuplicated(names(runners)) || !all(names(runners) %in% engines) ||
      !all(vapply(runners, is.function, logical(1)))))) {
    stop("Supply one crop name and optional named stics, dssat and apsim runner functions.", call. = FALSE)
  }
  if (!is.list(croptimizr) || (length(croptimizr) &&
      (is.null(names(croptimizr)) || anyDuplicated(names(croptimizr)) ||
       !all(names(croptimizr) %in% engines) ||
       !all(vapply(croptimizr, is.list, logical(1))))) ||
      length(intersect(names(runners), names(croptimizr)))) {
    stop("Supply named CroptimizR configurations and configure each engine only once.", call. = FALSE)
  }
  features <- weather[keys]
  status <- data.frame(engine = engines, status = "unconfigured", detail = "No runner configured.")
  for (i in seq_along(engines)) {
    engine <- engines[i]
    run <- runners[[engine]]
    config <- croptimizr[[engine]]
    if (is.null(run) && is.null(config)) next
    result <- tryCatch({
      sim <- if (is.null(config)) {
        run(weather = weather, soil = soil, crop = crop)
      } else {
        .ufeed_run_croptimizr(config)
      }
      .ufeed_daily_groups(sim, keys)
      vars <- setdiff(names(sim), keys)
      if (!nrow(sim) || !length(vars) || anyDuplicated(names(sim)) ||
          !all(vapply(sim[vars], is.numeric, logical(1)))) {
        stop("Runner must return daily keys and numeric features.")
      }
      matched <- merge(transform(features[keys], .weather_row = seq_len(nrow(features))),
                       transform(sim[keys], .simulation_row = seq_len(nrow(sim))),
                       by = keys, sort = FALSE)
      if (nrow(matched) != nrow(sim)) stop("Runner returned dates or sites outside the weather input.")
      rows <- rep(NA_integer_, nrow(features))
      rows[matched$.weather_row] <- matched$.simulation_row
      stats::setNames(sim[rows, vars, drop = FALSE], paste0(engine, "_", vars))
    }, error = function(e) e)
    if (inherits(result, "error")) {
      status[i, 2:3] <- list("failed", conditionMessage(result))
    } else {
      features[names(result)] <- result
      status[i, 2:3] <- list("completed", "")
    }
  }
  list(features = features, status = status, crop = crop)
}
