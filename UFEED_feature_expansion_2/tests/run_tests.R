source(file.path("R", "UFEED_core_functions.R"))
source(file.path("UFEED_feature_expansion_2", "R", "UFEED_feature_expansion_2.R"))

input <- data.frame(
  Date = as.Date("2024-06-01") + 0:4,
  site_id = "A", crop_cycle_id = "cycle_1", lon = 7.155, lat = 46.16,
  T2M = c(0, 10, 25, 35, 40), T2M_MIN = c(-2, 5, 18, 25, 30),
  T2M_MAX = c(2, 15, 32, 42, 48), ALLSKY_SFC_SW_DWN = c(10, 15, 20, 25, 20),
  VPD_DAILY_FAO56_KPA = c(0.2, 0.5, 1.2, 2.5, 3), DAYLENGTH_H = rep(14, 5))
units <- c(T2M = "degC", T2M_MIN = "degC", T2M_MAX = "degC",
           ALLSKY_SFC_SW_DWN = "MJ m-2 day-1")
parameters <- UFEED_expansion_2_reference_parameters(
  reference_lai = 3, light_extinction_coefficient = 0.6,
  par_absorptance = 0.85, rue_g_mj_apar = 2.5,
  development_tmin_c = 0, development_topt_c = 25, development_tmax_c = 40,
  growth_tmin_c = 5, growth_topt_c = 25, growth_tmax_c = 40,
  photoperiod_type = "neutral", frost_threshold_c = 0, heat_threshold_c = 35)

out <- UFEED_feature_expansion_2(
  input, units, parameters, cycle_id_columns = c("site_id", "crop_cycle_id"))

new_columns <- setdiff(names(out), names(input))
stopifnot(length(new_columns) == 20L)
stopifnot(all(vapply(out[new_columns], is.numeric, logical(1))))

# Boundary and optimum checks for the Wang-Engel response.
stopifnot(out$REFERENCE_DEVELOPMENT_TEMP_RESPONSE_0_1[1] == 0)
stopifnot(out$REFERENCE_DEVELOPMENT_TEMP_RESPONSE_0_1[3] == 1)
stopifnot(out$REFERENCE_DEVELOPMENT_TEMP_RESPONSE_0_1[5] == 0)
stopifnot(all(out$REFERENCE_DEVELOPMENT_TEMP_RESPONSE_0_1 >= 0 &
              out$REFERENCE_DEVELOPMENT_TEMP_RESPONSE_0_1 <= 1))

# Beer-Lambert interception, absorption, and RUE identity.
expected_fipar <- 1 - exp(-0.6 * 3)
stopifnot(all(abs(out$REFERENCE_FIPAR - expected_fipar) < 1e-12))
stopifnot(all(abs(out$INCIDENT_PAR_MJ_M2_DAY - input$ALLSKY_SFC_SW_DWN * 0.48) < 1e-12))
stopifnot(all(abs(out$REFERENCE_APAR_MJ_M2_DAY -
                    out$INCIDENT_PAR_MJ_M2_DAY * expected_fipar * 0.85) < 1e-12))
stopifnot(all(abs(out$REFERENCE_POTENTIAL_DM_G_M2_DAY -
                    out$REFERENCE_APAR_MJ_M2_DAY * 2.5) < 1e-12))

# Explicit cycle accumulation and exposure definitions.
stopifnot(isTRUE(all.equal(out$CUMULATIVE_REFERENCE_APAR_MJ_M2,
                           cumsum(out$REFERENCE_APAR_MJ_M2_DAY))))
stopifnot(identical(out$DAILY_FROST_SEVERITY_INDEX_DEGC, c(2, 0, 0, 0, 0)))
stopifnot(identical(out$DAILY_HEAT_SEVERITY_INDEX_DEGC, c(0, 0, 0, 7, 13)))

# Unit-conversion invariance.
input_k <- input
input_k[c("T2M", "T2M_MIN", "T2M_MAX")] <-
  lapply(input_k[c("T2M", "T2M_MIN", "T2M_MAX")], function(x) x + 273.15)
input_k$ALLSKY_SFC_SW_DWN <- input_k$ALLSKY_SFC_SW_DWN / 3.6
units_k <- c(T2M = "K", T2M_MIN = "K", T2M_MAX = "K",
             ALLSKY_SFC_SW_DWN = "kWh m-2 day-1")
out_k <- UFEED_feature_expansion_2(
  input_k, units_k, parameters, cycle_id_columns = c("site_id", "crop_cycle_id"))
stopifnot(isTRUE(all.equal(out$REFERENCE_TEMP_LIMITED_DM_G_M2_DAY,
                           out_k$REFERENCE_TEMP_LIMITED_DM_G_M2_DAY, tolerance = 1e-10)))

# Long-day response and missing-cycle behavior.
long_day <- parameters
long_day$photoperiod_type <- "long_day"
long_day$photoperiod_critical_h <- 10
long_day$photoperiod_saturating_h <- 14
out_long <- UFEED_feature_expansion_2(input, units, long_day)
stopifnot(all(out_long$REFERENCE_PHOTOPERIOD_RESPONSE_0_1 == 1))
stopifnot(all(is.na(out_long$CUMULATIVE_REFERENCE_APAR_MJ_M2)))

# Refuse raw/core-only input and invalid cardinal temperatures.
raw_only <- input; raw_only$VPD_DAILY_FAO56_KPA <- NULL
stopifnot(inherits(try(UFEED_feature_expansion_2(raw_only, units, parameters), silent = TRUE), "try-error"))
bad_parameters <- parameters; bad_parameters$growth_topt_c <- 50
stopifnot(inherits(try(UFEED_feature_expansion_2(input, units, bad_parameters), silent = TRUE), "try-error"))

# Temporal calculations stay inside expansion 2 and append only numeric fields.
temporal2 <- UFEED_feature_expansion_2_temporal(
  out, cycle_id_columns = c("site_id", "crop_cycle_id"), windows = c(2, 3))
temporal2_columns <- setdiff(names(temporal2), names(out))
stopifnot(length(temporal2_columns) == 46L)
stopifnot(all(vapply(temporal2[temporal2_columns], is.numeric, logical(1))))
stopifnot(temporal2$DAILY_HEAT_SEVERITY_INDEX_DEGC_ROLLMAX_2[5] == 13)
message("All UFEED_feature_expansion_2 tests passed.")
