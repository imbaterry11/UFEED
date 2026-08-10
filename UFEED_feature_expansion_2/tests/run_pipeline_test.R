source(file.path("R", "UFEED_core_functions.R"))
source(file.path("UFEED_feature_expansion_1", "R", "UFEED_feature_expansion_1.R"))
source(file.path("UFEED_feature_expansion_2", "R", "UFEED_feature_expansion_2.R"))

raw <- data.frame(
  Date = as.Date("2024-06-01") + 0:2, site_id = "A", crop_cycle_id = "A_2024",
  lon = 7.155, lat = 46.16, T2M = c(20, 25, 30),
  T2M_MIN = c(12, 16, 20), T2M_MAX = c(27, 33, 39),
  T2MDEW = c(10, 12, 14), RH2M = c(60, 55, 50), PS = 100,
  WS2M = c(2, 2.5, 3), ALLSKY_SFC_SW_DWN = c(18, 22, 25), elevation = 500)

units_1 <- c(lat = "degree", T2M = "degC", T2M_MAX = "degC",
  T2M_MIN = "degC", T2MDEW = "degC", RH2M = "percent", PS = "kPa",
  WS2M = "m s-1", ALLSKY_SFC_SW_DWN = "MJ m-2 day-1", elevation = "m")
physical <- UFEED_feature_expansion_1(raw, units_1, wind_height_m = 10)
physical_temporal <- UFEED_feature_expansion_1_temporal(
  physical, cycle_id_columns = c("site_id", "crop_cycle_id"), windows = 2)

parameters <- UFEED_expansion_2_reference_parameters(
  reference_lai = c(1, 2, 3), light_extinction_coefficient = 0.6,
  par_absorptance = 0.85, rue_g_mj_apar = 2.5,
  development_tmin_c = 0, development_topt_c = 25, development_tmax_c = 40,
  growth_tmin_c = 5, growth_topt_c = 25, growth_tmax_c = 40,
  photoperiod_type = "long_day", photoperiod_critical_h = 10,
  photoperiod_saturating_h = 15, frost_threshold_c = 0, heat_threshold_c = 35)
units_2 <- units_1[c("T2M", "T2M_MAX", "T2M_MIN", "ALLSKY_SFC_SW_DWN")]
process <- UFEED_feature_expansion_2(
  physical_temporal, units_2, parameters,
  cycle_id_columns = c("site_id", "crop_cycle_id"))
process_temporal <- UFEED_feature_expansion_2_temporal(
  process, cycle_id_columns = c("site_id", "crop_cycle_id"), windows = 2)
final_product <- UFEED_finalize_feature_product(process_temporal)

stopifnot(nrow(process) == nrow(raw))
stopifnot(all(process$REFERENCE_FIPAR[2:3] > process$REFERENCE_FIPAR[1:2]))
stopifnot(all(process$REFERENCE_POTENTIAL_DM_G_M2_DAY >= 0))
stopifnot(all(diff(process$CUMULATIVE_REFERENCE_POTENTIAL_DM_G_M2) >= 0))
stopifnot(!is.null(attr(process, "UFEED_feature_expansion_1_reference")))
stopifnot(!is.null(attr(process, "UFEED_feature_expansion_2_scope")))
stopifnot(identical(names(final_product)[1:3], c("Date", "lon", "lat")))
stopifnot(all(vapply(final_product[-1], is.double, logical(1))))
stopifnot(!any(c("site_id", "crop_cycle_id", "ACTUAL_VAPOR_PRESSURE_METHOD",
                "RADIATION_QA_FLAG", "ET0_FAO56_RAW_MM_DAY",
                "WIND_ADJUSTMENT_FACTOR_TO_2M",
                "DAILY_ATMOSPHERIC_DROUGHT_DOSE_KPA_DAY") %in% names(final_product)))
stopifnot(all(c("T2M", "VPD_DAILY_FAO56_KPA", "REFERENCE_APAR_MJ_M2_DAY",
                "VPD_DAILY_FAO56_KPA_EWMA_2",
                "REFERENCE_APAR_MJ_M2_DAY_EWMA_2",
                "ET0_FAO56_MM_DAY_CYCLE_CUMSUM") %in% names(final_product)))
stopifnot(!anyDuplicated(names(final_product)))
message("UFEED expansion_1 -> expansion_2 pipeline test passed.")
