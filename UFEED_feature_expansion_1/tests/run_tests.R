source(file.path("R", "UFEED_core_functions.R"))
module <- file.path("UFEED_feature_expansion_1", "R", "UFEED_feature_expansion_1.R")
if (!file.exists(module)) module <- file.path("..", "R", "UFEED_feature_expansion_1.R")
source(module)

units <- c(lat = "degree", T2M = "degC", T2M_MAX = "degC", T2M_MIN = "degC",
  T2MDEW = "degC", RH2M = "percent", PS = "kPa", WS2M = "m s-1",
  ALLSKY_SFC_SW_DWN = "MJ m-2 day-1", elevation = "m")
input <- data.frame(
  Date = as.Date("2024-06-01") + 0:4, lat = rep(46.16, 5), lon = rep(7.155, 5),
  T2M = c(24.5, 25.5, 23.5, 22.5, 21.5), T2M_MAX = c(31, 32, 30, 29, 28),
  T2M_MIN = c(18, 19, 17, 16, 15), T2MDEW = c(14, 15, 13, 12, 11),
  RH2M = rep(70, 5), ALLSKY_SFC_SW_DWN = c(22, 23, 21, 20, 19),
  WS2M = c(2, 2.1, 1.8, 2.2, 2), PS = rep(100, 5), elevation = rep(500, 5))

out2 <- UFEED_feature_expansion_1(input, units, wind_height_m = 2)
out10 <- UFEED_feature_expansion_1(input, units, wind_height_m = 10)
stopifnot(nrow(out2) == nrow(input))
new_columns <- setdiff(names(out2), names(input))
stopifnot(length(new_columns) == 24L)
stopifnot(all(vapply(out2[new_columns], is.numeric, logical(1))))
stopifnot(all(abs(out2$WIND_SPEED_2M_M_S - input$WS2M) < 1e-12))
stopifnot(all(abs(out10$WIND_ADJUSTMENT_FACTOR_TO_2M - 0.74795) < 1e-4))
stopifnot(all(out2$ET0_FAO56_MM_DAY >= 0))
stopifnot(identical(
  attr(out2, "UFEED_feature_expansion_1_actual_vapor_pressure_method"),
  rep("dew_point_fao56_eq14", 5)))

# Equivalent inputs in other units must return identical values.
converted <- input
converted[c("T2M", "T2M_MAX", "T2M_MIN", "T2MDEW")] <-
  lapply(converted[c("T2M", "T2M_MAX", "T2M_MIN", "T2MDEW")], function(x) x + 273.15)
converted$PS <- converted$PS * 10
converted$WS2M <- converted$WS2M * 3.6
converted$ALLSKY_SFC_SW_DWN <- converted$ALLSKY_SFC_SW_DWN / 3.6
converted_units <- units
converted_units[c("T2M", "T2M_MAX", "T2M_MIN", "T2MDEW")] <- "K"
converted_units["PS"] <- "hPa"; converted_units["WS2M"] <- "km/h"
converted_units["ALLSKY_SFC_SW_DWN"] <- "kWh m-2 day-1"
out_converted <- UFEED_feature_expansion_1(converted, converted_units, 2)
stopifnot(isTRUE(all.equal(out2$ET0_FAO56_RAW_MM_DAY, out_converted$ET0_FAO56_RAW_MM_DAY, tolerance = 1e-10)))
stopifnot(isTRUE(all.equal(out2$VPD_DAILY_FAO56_KPA, out_converted$VPD_DAILY_FAO56_KPA, tolerance = 1e-10)))

# Mean-RH fallback follows FAO-56 Eq 19 and is labeled lower quality.
rh_input <- input[1, ]; rh_input$T2MDEW <- NULL
rh_units <- units[names(units) != "T2MDEW"]
rh_out <- UFEED_feature_expansion_1(rh_input, rh_units, 2)
expected_es <- mean(0.6108 * exp(17.27 * c(rh_input$T2M_MAX, rh_input$T2M_MIN) /
  (c(rh_input$T2M_MAX, rh_input$T2M_MIN) + 237.3)))
stopifnot(abs(rh_out$ACTUAL_VAPOR_PRESSURE_KPA - expected_es * rh_input$RH2M / 100) < 1e-10)
stopifnot(attr(rh_out, "UFEED_feature_expansion_1_actual_vapor_pressure_method") ==
            "mean_rh_fao56_eq19_lower_quality")

bad_units <- units[names(units) != "ALLSKY_SFC_SW_DWN"]
stopifnot(inherits(try(UFEED_feature_expansion_1(input, bad_units, 2), silent = TRUE), "try-error"))
bad_temp <- input; bad_temp$T2M_MIN[1] <- 30
stopifnot(inherits(try(UFEED_feature_expansion_1(bad_temp, units, 2), silent = TRUE), "try-error"))

# Independent package checks: bigleaf humidity conversions and the
# Evapotranspiration package's daily FAO-56 Penman-Monteith implementation.
if (requireNamespace("bigleaf", quietly = TRUE)) {
  es_bigleaf <- as.numeric(bigleaf::Esat.slope(input$T2M, formula = "Allen_1998")[, "Esat"])
  ea_bigleaf <- as.numeric(bigleaf::Esat.slope(input$T2MDEW, formula = "Allen_1998")[, "Esat"])
  q_bigleaf <- bigleaf::e.to.q(ea_bigleaf, input$PS)
  stopifnot(isTRUE(all.equal(out2$SATURATION_VAPOR_PRESSURE_TMEAN_KPA, es_bigleaf, tolerance = 1e-3)))
  stopifnot(isTRUE(all.equal(out2$SPECIFIC_HUMIDITY_KG_KG, q_bigleaf, tolerance = 1e-6)))
}

if (requireNamespace("Evapotranspiration", quietly = TRUE)) {
  data("defaultconstants", package = "Evapotranspiration")
  constants <- defaultconstants
  constants$lat <- input$lat[1]
  constants$lat_rad <- input$lat[1] * pi / 180
  constants$Elev <- input$elevation[1]
  constants$z <- 2
  package_input <- data.frame(
    Year = as.integer(format(input$Date, "%Y")),
    Month = as.integer(format(input$Date, "%m")), Day = as.integer(format(input$Date, "%d")),
    Tmax = input$T2M_MAX, Tmin = input$T2M_MIN,
    va = 0.6108 * exp(17.27 * input$T2MDEW / (input$T2MDEW + 237.3)),
    vs = (0.6108 * exp(17.27 * input$T2M_MAX / (input$T2M_MAX + 237.3)) +
            0.6108 * exp(17.27 * input$T2M_MIN / (input$T2M_MIN + 237.3))) / 2,
    u2 = input$WS2M, Rs = input$ALLSKY_SFC_SW_DWN)
  processed <- Evapotranspiration::ReadInputs(
    varnames = c("Tmax", "Tmin", "va", "vs", "u2", "Rs"),
    climatedata = package_input, constants = constants,
    stopmissing = c(99, 99, 99), timestep = "daily", message = "no")
  package_output <- Evapotranspiration::ET.PenmanMonteith(
    processed, constants, ts = "daily", solar = "data", wind = "yes",
    crop = "short", message = "no", AdditionalStats = "no", save.csv = "no")
  stopifnot(isTRUE(all.equal(as.numeric(out2$ET0_FAO56_MM_DAY),
                              as.numeric(package_output$ET.Daily), tolerance = 0.05)))
}
# Temporal calculations stay inside expansion 1 and append only numeric fields.
out2$cycle_id <- "test_cycle"
temporal1 <- UFEED_feature_expansion_1_temporal(
  out2, cycle_id_columns = "cycle_id", windows = c(2, 3))
temporal1_columns <- setdiff(names(temporal1), names(out2))
stopifnot(length(temporal1_columns) == 47L)
stopifnot(all(vapply(temporal1[temporal1_columns], is.numeric, logical(1))))
stopifnot(temporal1$ET0_FAO56_MM_DAY_SEASON_TO_DATE_MAX[5] ==
            max(out2$ET0_FAO56_MM_DAY))
message("All UFEED_feature_expansion_1 tests passed.")
