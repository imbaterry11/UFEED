UFEED_apsim_runner <- function(executable, template, crop_name, report = "Report",
                              radiation_to_mj = 1, climate_normals = NULL,
                              report_variables = character()) {
  if (!file.exists(executable) || !file.exists(template) ||
      !grepl("^[A-Za-z0-9_]+$", report) || length(radiation_to_mj) != 1L ||
      !is.finite(radiation_to_mj) || radiation_to_mj <= 0) {
    stop("Supply an APSIM executable, template, report name and positive radiation conversion.", call. = FALSE)
  }
  executable <- normalizePath(executable, winslash = "/")
  template <- normalizePath(template, winslash = "/")
  if (!is.character(report_variables) || anyNA(report_variables) ||
      any(!nzchar(report_variables))) stop("APSIM report variables must be nonempty strings.")
  if (!is.null(climate_normals) && (!is.function(climate_normals))) {
    stop("Climate normals must be a function of lon and lat returning named tav and amp.", call. = FALSE)
  }
  function(weather, soil, crop) {
    if (!identical(crop, crop_name)) stop("APSIM template is configured for ", crop_name, ".")
    groups <- .ufeed_daily_groups(weather, c("Date", "lon", "lat"))
    required <- c("PRECTOTCORR", "T2M_MAX", "T2M_MIN", "ALLSKY_SFC_SW_DWN")
    if (!length(groups) || !all(required %in% names(weather)) ||
        !all(vapply(weather[required], function(x) is.numeric(x) && all(is.finite(x)), logical(1)))) {
      stop("APSIM needs complete daily rainfall, minimum/maximum temperature and shortwave radiation.")
    }
    directory <- tempfile("ufeed-apsim-")
    dir.create(directory)
    on.exit(unlink(directory, recursive = TRUE), add = TRUE)
    output <- lapply(groups, function(ix) {
      w <- weather[ix[order(weather$Date[ix])], ]
      if (any(diff(w$Date) != 1) || any(w$PRECTOTCORR < 0 |
          w$ALLSKY_SFC_SW_DWN < 0 | w$T2M_MIN > w$T2M_MAX)) {
        stop("APSIM weather has a date gap or physically invalid inputs.")
      }
      met <- data.frame(year = format(w$Date, "%Y"), day = format(w$Date, "%j"),
                        radn = w$ALLSKY_SFC_SW_DWN * radiation_to_mj,
                        maxt = w$T2M_MAX, mint = w$T2M_MIN, rain = w$PRECTOTCORR)
      met_file <- file.path(directory, "weather.met")
      writeLines(c("[weather.met.weather]", paste("latitude =", w$lat[1]),
                   paste("longitude =", w$lon[1])), met_file)
      if (!is.null(climate_normals)) {
        normals <- climate_normals(w$lon[1], w$lat[1])
        if (!is.numeric(normals) || !all(is.finite(normals[c("tav", "amp")])) ||
            normals[["amp"]] < 0) stop("Invalid APSIM tav or amp climate normal.")
        cat("tav =", normals[["tav"]], "\namp =", normals[["amp"]], "\n",
            file = met_file, append = TRUE)
      }
      cat("year day radn maxt mint rain\n() () (MJ/m^2) (oC) (oC) (mm)\n",
          file = met_file, append = TRUE)
      utils::write.table(met, met_file, append = TRUE, row.names = FALSE,
                         col.names = FALSE, quote = FALSE)
      count <- c(weather = 0L, clock = 0L, report = 0L)
      configure <- function(node) {
        kind <- sub(",.*$", "", node[["$type"]])
        if (identical(kind, "Models.Climate.Weather")) {
          node$FileName <- normalizePath(met_file, winslash = "/")
          count["weather"] <<- count["weather"] + 1L
        }
        if (identical(kind, "Models.Clock")) {
          node$Start <- paste0(min(w$Date), "T00:00:00")
          node$End <- paste0(max(w$Date), "T00:00:00")
          count["clock"] <<- count["clock"] + 1L
        }
        if (identical(kind, "Models.Report") && identical(node$Name, report)) {
          node$VariableNames <- as.list(unique(c("[Clock].Today", unlist(node$VariableNames),
                                                report_variables)))
          node$EventNames <- list("[Clock].EndOfDay")
          count["report"] <<- count["report"] + 1L
        }
        if (length(node$Children)) node$Children <- lapply(node$Children, configure)
        node
      }
      model <- configure(jsonlite::read_json(template, simplifyVector = FALSE))
      if (any(count != 1L)) stop("APSIM template needs one Clock, one Weather and one selected Report.")
      input <- tempfile("site-", tmpdir = directory, fileext = ".apsimx")
      jsonlite::write_json(model, input, auto_unbox = TRUE, null = "null", digits = NA)
      log <- system2(executable, c(shQuote(input), "--csv", "--single-threaded"),
                     stdout = TRUE, stderr = TRUE)
      csv <- paste0(tools::file_path_sans_ext(input), ".", report, ".csv")
      if (!is.null(attr(log, "status")) || !file.exists(csv)) {
        stop("APSIM report failed. ", paste(utils::head(log, 12), collapse = " "))
      }
      x <- utils::read.csv(csv, check.names = FALSE)
      dates <- as.Date(x$Clock.Today)
      if (anyNA(dates) || anyDuplicated(dates) || !setequal(dates, w$Date)) {
        stop("APSIM report must have exactly one row per day and site.")
      }
      fields <- setdiff(names(x), c("SimulationID", "CheckpointID"))
      numeric_fields <- fields[vapply(x[fields], is.numeric, logical(1))]
      data.frame(Date = dates, lon = w$lon[1], lat = w$lat[1],
                 x[numeric_fields], check.names = FALSE)
    })
    do.call(rbind, output)
  }
}
