# Read one DSSAT run report. Accept only dated data lines below its header;
# keep DSSAT missing sentinels out of the physical flux calculations.
ufeed_dssat_report <- function(path, fields) {
  lines <- readLines(path, skipNul = TRUE, warn = FALSE)
  header <- which(startsWith(lines, "@YEAR"))
  if (length(header) != 1L) stop("Expected one DSSAT report section in ", basename(path))
  records <- grep("^\\s*[0-9]{4}\\s+[0-9]+\\s", lines[seq.int(header + 1L, length(lines))],
                  value = TRUE)
  values <- utils::read.table(text = c(sub("^@", "", lines[header]), records),
    header = TRUE, check.names = FALSE, comment.char = "", na.strings = c("-99", "-99.0", "-99.000"))
  if (!all(c("YEAR", "DOY", fields) %in% names(values))) {
    stop("Missing required DSSAT fields in ", basename(path))
  }
  date <- as.Date(sprintf("%04d-%03d", values$YEAR, values$DOY), "%Y-%j")
  if (anyNA(date) || anyDuplicated(date) || is.unsorted(date)) {
    stop("DSSAT report dates must be valid, ordered, and unique.")
  }
  data.frame(Date = date, values[fields], check.names = FALSE)
}

# A cumulative uptake counter has no valid daily increment on its first day
# or after a missing day or reset. Do not convert those boundaries to zero.
ufeed_daily_counter_increment <- function(value, date) {
  previous <- c(NA_real_, head(value, -1L))
  gap <- c(NA_real_, as.numeric(diff(date)))
  increment <- value - previous
  increment[is.na(gap) | gap != 1 | is.na(increment) | increment < 0] <- NA_real_
  increment
}

ufeed_dssat_wheat_processes <- function(directory) {
  water <- ufeed_dssat_report(file.path(directory, "ET.OUT"), c("ETAA", "EPAA", "ESAA", "EFAA", "EMAA"))
  names(water)[-1] <- c("et_mm_day", "transpiration_mm_day", "soil_evaporation_mm_day",
                       "canopy_evaporation_mm_day", "mulch_evaporation_mm_day")
  # ET.OUT columns are interval means; a daily report is required.
  if (any(diff(water$Date) != 1)) stop("DSSAT ET.OUT must be daily.")
  stress <- ufeed_dssat_report(file.path(directory, "PlantGrf.OUT"),
                              c("TFPD", "WFPD", "NFPD", "WFGD", "NFGD"))
  names(stress)[-1] <- c("temperature_photosynthesis_factor", "water_photosynthesis_factor",
    "nitrogen_photosynthesis_factor", "water_growth_factor", "nitrogen_growth_factor")
  nitrogen <- ufeed_dssat_report(file.path(directory, "PlantN.OUT"), "NUAC")
  nitrogen$nitrogen_uptake_kg_ha_day <- ufeed_daily_counter_increment(nitrogen$NUAC, nitrogen$Date)
  nitrogen$NUAC <- NULL
  soil <- ufeed_dssat_report(file.path(directory, "SoilWat.OUT"), c("DRNC", "ROFD"))
  soil$drainage_mm_day <- ufeed_daily_counter_increment(soil$DRNC, soil$Date)
  soil$DRNC <- NULL
  names(soil)[names(soil) == "ROFD"] <- "runoff_mm_day"
  Reduce(function(x, y) dplyr::full_join(x, y, by = "Date"),
         list(water, stress, nitrogen, soil))
}
