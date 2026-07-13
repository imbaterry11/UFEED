# UFEED feature expansion helpers --------------------------------------------
#
# This script is intentionally separate from UFEED_core_functions.R.
# It adds optional, post-processing feature modules without changing the
# existing UFEED download or core feature-computation workflow.
#
# Current implementation status:
#   Phase 1: atmospheric evaporative demand -- IMPLEMENTED
#   Phase 2: surface energy and radiation balance -- planned
#   Phase 3: event persistence and environmental variability -- planned
#   Phase 4: soil hydraulic capacity and profile structure -- planned
#
# Required package for Phase 1:
#   bigleaf
#
# Add to DESCRIPTION Imports:
#   bigleaf
#
# Typical usage:
#
#   expanded_data <- UFEED_history(...) |>
#     UFEED_expand_features(
#       included_module = "atmospheric_demand"
#     )
#
# or:
#
#   expanded_data <- UFEED_present(...) |>
#     UFEED_expand_features()


# -----------------------------------------------------------------------------
# 0. Expansion-module registry
# -----------------------------------------------------------------------------

UFEED_EXPANSION_MODULES <- c(
  "atmospheric_demand"
)


# -----------------------------------------------------------------------------
# 1. Small internal utilities
# -----------------------------------------------------------------------------

.UFEED_expansion_check_packages <- function(pkgs) {
  missing <- pkgs[
    !vapply(pkgs, requireNamespace, quietly = TRUE, FUN.VALUE = logical(1))
  ]

  if (length(missing) > 0L) {
    stop(
      "Missing required package(s) for UFEED feature expansion: ",
      paste(missing, collapse = ", "),
      ". Please install them before running this module.",
      call. = FALSE
    )
  }

  invisible(TRUE)
}


.UFEED_validate_expansion_modules <- function(included_module) {
  if (!is.character(included_module) || length(included_module) == 0L) {
    stop(
      "`included_module` must be a non-empty character vector.",
      call. = FALSE
    )
  }

  included_module <- unique(included_module)
  bad <- setdiff(included_module, UFEED_EXPANSION_MODULES)

  if (length(bad) > 0L) {
    stop(
      "Unknown expansion module(s): ",
      paste(bad, collapse = ", "),
      ". Currently implemented modules are: ",
      paste(UFEED_EXPANSION_MODULES, collapse = ", "),
      ".",
      call. = FALSE
    )
  }

  included_module
}


.UFEED_require_columns <- function(data, required_cols, module_name) {
  missing_cols <- setdiff(required_cols, names(data))

  if (length(missing_cols) > 0L) {
    stop(
      "Missing required column(s) for the `", module_name, "` module: ",
      paste(missing_cols, collapse = ", "),
      ".",
      call. = FALSE
    )
  }

  invisible(TRUE)
}


.UFEED_numeric_or_na <- function(data, column) {
  if (!column %in% names(data)) {
    return(rep(NA_real_, nrow(data)))
  }

  out <- suppressWarnings(as.numeric(data[[column]]))
  out[!is.finite(out)] <- NA_real_
  out
}


.UFEED_bigleaf_esat <- function(temperature, formula = "Allen_1998") {
  out <- rep(NA_real_, length(temperature))
  ok <- is.finite(temperature)

  if (any(ok)) {
    result <- bigleaf::Esat.slope(
      Tair = temperature[ok],
      formula = formula
    )
    out[ok] <- as.numeric(result[, "Esat"])
  }

  out
}


.UFEED_bigleaf_vpd_from_e <- function(
    vapor_pressure,
    temperature,
    formula = "Allen_1998"
) {
  out <- rep(NA_real_, length(temperature))
  ok <- is.finite(vapor_pressure) & is.finite(temperature)

  if (any(ok)) {
    out[ok] <- bigleaf::e.to.VPD(
      e = vapor_pressure[ok],
      Tair = temperature[ok],
      Esat.formula = formula
    )
  }

  out
}


# -----------------------------------------------------------------------------
# 2. Phase 1: atmospheric evaporative demand
# -----------------------------------------------------------------------------

#' Compute atmospheric evaporative-demand features
#'
#' Adds daily atmospheric moisture-demand variables using functions from the
#' `bigleaf` package. Actual vapor pressure is calculated preferentially from
#' daily dew-point temperature (`T2MDEW`). If dew point is missing for a row,
#' relative humidity (`RH2M`) is used as a fallback.
#'
#' The daily maximum and minimum VPD variables are proxies because UFEED has
#' daily temperature extrema and daily mean dew point rather than simultaneous
#' hourly temperature and humidity observations.
#'
#' @param ufeed_data A data frame containing UFEED raw weather columns.
#' @param esat_formula Saturation-vapor-pressure formulation passed to
#'   `bigleaf`. The default, `"Allen_1998"`, is consistent with FAO-56.
#' @param clamp_negative_vpd Logical. Replace small negative VPD values caused
#'   by inconsistent daily summaries or numerical noise with zero.
#'
#' @return The input data frame with atmospheric-demand features appended.
#'
#' @details
#' Required input:
#' - `T2M`
#'
#' At least one humidity input is required:
#' - `T2MDEW`, or
#' - `RH2M`
#'
#' Optional inputs:
#' - `T2M_MAX` for `VPD_MAX_PROXY`
#' - `T2M_MIN` for `VPD_MIN_PROXY`
#' - `PS` for `SPECIFIC_HUMIDITY`
#' - `WS2M` for `VPD_WIND`
#'
#' Generated variables and units:
#' - `ESAT_T2M`: saturation vapor pressure at mean temperature, kPa
#' - `ESAT_T2M_MAX`: saturation vapor pressure at maximum temperature, kPa
#' - `ESAT_T2M_MIN`: saturation vapor pressure at minimum temperature, kPa
#' - `EA`: actual vapor pressure, kPa
#' - `VPD`: vapor pressure deficit at mean temperature, kPa
#' - `VPD_MAX_PROXY`: VPD proxy using Tmax and daily mean dew point/RH, kPa
#' - `VPD_MIN_PROXY`: VPD proxy using Tmin and daily mean dew point/RH, kPa
#' - `DEWPOINT_DEPRESSION`: T2M minus T2MDEW, degree C
#' - `SPECIFIC_HUMIDITY`: specific humidity, kg kg-1
#' - `VPD_WIND`: VPD multiplied by mean wind speed, kPa m s-1
#'
#' @export
UFEED_compute_atmospheric_demand_features <- function(
    ufeed_data,
    esat_formula = c("Allen_1998", "Sonntag_1990", "Alduchov_1996"),
    clamp_negative_vpd = TRUE
) {
  .UFEED_expansion_check_packages(c("bigleaf"))

  esat_formula <- match.arg(esat_formula)

  if (!is.data.frame(ufeed_data)) {
    stop("`ufeed_data` must be a data frame.", call. = FALSE)
  }

  .UFEED_require_columns(
    data = ufeed_data,
    required_cols = "T2M",
    module_name = "atmospheric_demand"
  )

  if (!any(c("T2MDEW", "RH2M") %in% names(ufeed_data))) {
    stop(
      "The `atmospheric_demand` module requires `T2MDEW` or `RH2M`.",
      call. = FALSE
    )
  }

  Tmean <- .UFEED_numeric_or_na(ufeed_data, "T2M")
  Tmax <- .UFEED_numeric_or_na(ufeed_data, "T2M_MAX")
  Tmin <- .UFEED_numeric_or_na(ufeed_data, "T2M_MIN")
  Tdew <- .UFEED_numeric_or_na(ufeed_data, "T2MDEW")
  RH <- .UFEED_numeric_or_na(ufeed_data, "RH2M")
  pressure <- .UFEED_numeric_or_na(ufeed_data, "PS")
  wind <- .UFEED_numeric_or_na(ufeed_data, "WS2M")

  esat_mean <- .UFEED_bigleaf_esat(Tmean, formula = esat_formula)
  esat_max <- .UFEED_bigleaf_esat(Tmax, formula = esat_formula)
  esat_min <- .UFEED_bigleaf_esat(Tmin, formula = esat_formula)

  # Primary humidity path: actual vapor pressure from dew-point temperature.
  ea_from_dewpoint <- .UFEED_bigleaf_esat(Tdew, formula = esat_formula)

  # Fallback humidity path: derive actual vapor pressure from daily mean RH.
  # RH2M is supplied by UFEED as percent saturation and is converted to 0-1.
  rh_fraction <- pmin(pmax(RH / 100, 0), 1)
  ea_from_rh <- esat_mean * rh_fraction

  actual_vapor_pressure <- ifelse(
    is.finite(ea_from_dewpoint),
    ea_from_dewpoint,
    ea_from_rh
  )

  VPD <- .UFEED_bigleaf_vpd_from_e(
    vapor_pressure = actual_vapor_pressure,
    temperature = Tmean,
    formula = esat_formula
  )

  VPD_max_proxy <- .UFEED_bigleaf_vpd_from_e(
    vapor_pressure = actual_vapor_pressure,
    temperature = Tmax,
    formula = esat_formula
  )

  VPD_min_proxy <- .UFEED_bigleaf_vpd_from_e(
    vapor_pressure = actual_vapor_pressure,
    temperature = Tmin,
    formula = esat_formula
  )

  if (isTRUE(clamp_negative_vpd)) {
    VPD <- ifelse(is.na(VPD), NA_real_, pmax(VPD, 0))
    VPD_max_proxy <- ifelse(
      is.na(VPD_max_proxy),
      NA_real_,
      pmax(VPD_max_proxy, 0)
    )
    VPD_min_proxy <- ifelse(
      is.na(VPD_min_proxy),
      NA_real_,
      pmax(VPD_min_proxy, 0)
    )
  }

  specific_humidity <- rep(NA_real_, nrow(ufeed_data))
  q_ok <- is.finite(actual_vapor_pressure) &
    is.finite(pressure) &
    pressure > actual_vapor_pressure

  if (any(q_ok)) {
    specific_humidity[q_ok] <- bigleaf::e.to.q(
      e = actual_vapor_pressure[q_ok],
      pressure = pressure[q_ok]
    )
  }

  dewpoint_depression <- ifelse(
    is.finite(Tmean) & is.finite(Tdew),
    Tmean - Tdew,
    NA_real_
  )

  vpd_wind <- ifelse(
    is.finite(VPD) & is.finite(wind),
    VPD * wind,
    NA_real_
  )

  ufeed_data$ESAT_T2M <- esat_mean
  ufeed_data$ESAT_T2M_MAX <- esat_max
  ufeed_data$ESAT_T2M_MIN <- esat_min
  ufeed_data$EA <- actual_vapor_pressure
  ufeed_data$VPD <- VPD
  ufeed_data$VPD_MAX_PROXY <- VPD_max_proxy
  ufeed_data$VPD_MIN_PROXY <- VPD_min_proxy
  ufeed_data$DEWPOINT_DEPRESSION <- dewpoint_depression
  ufeed_data$SPECIFIC_HUMIDITY <- specific_humidity
  ufeed_data$VPD_WIND <- vpd_wind

  ufeed_data
}


# -----------------------------------------------------------------------------
# 3. Public expansion pipeline
# -----------------------------------------------------------------------------

#' Expand a completed UFEED data frame with optional feature modules
#'
#' This is a post-processing wrapper. It does not modify the UFEED weather
#' download, soil download, EWMA/REWMA, cumulative-temperature, or seasonal
#' feature functions.
#'
#' @param ufeed_data A data frame returned by `UFEED_history()`,
#'   `UFEED_present()`, or `UFEED_wrap_up()`.
#' @param included_module Character vector of expansion modules. Currently
#'   implemented: `"atmospheric_demand"`.
#' @param esat_formula Saturation-vapor-pressure formulation used by the
#'   atmospheric-demand module.
#' @param clamp_negative_vpd Logical. Clamp negative VPD estimates to zero.
#' @param message_progress Logical. Print module progress messages.
#'
#' @return The input UFEED table with selected expansion features appended.
#' @export
UFEED_expand_features <- function(
    ufeed_data,
    included_module = "atmospheric_demand",
    esat_formula = c("Allen_1998", "Sonntag_1990", "Alduchov_1996"),
    clamp_negative_vpd = TRUE,
    message_progress = TRUE
) {
  included_module <- .UFEED_validate_expansion_modules(included_module)
  esat_formula <- match.arg(esat_formula)

  out <- ufeed_data

  if ("atmospheric_demand" %in% included_module) {
    if (isTRUE(message_progress)) {
      message("Computing atmospheric evaporative-demand features...")
    }

    out <- UFEED_compute_atmospheric_demand_features(
      ufeed_data = out,
      esat_formula = esat_formula,
      clamp_negative_vpd = clamp_negative_vpd
    )
  }

  out
}
