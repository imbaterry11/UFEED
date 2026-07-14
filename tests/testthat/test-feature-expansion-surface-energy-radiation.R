make_surface_energy_input <- function() {
  data.frame(
    Date = as.Date("2024-06-01") + 0:4,
    lon = rep(7.155, 5),
    lat = rep(46.16, 5),
    T2M = c(24.5, 25.5, 23.5, 22.5, 21.5),
    T2M_MAX = c(31, 32, 30, 29, 28),
    T2M_MIN = c(18, 19, 17, 16, 15),
    T2MDEW = c(14, 15, 13, 12, 11),
    RH2M = c(99, 99, 99, 99, 99),
    ALLSKY_SFC_SW_DWN = c(22, 23, 21, 20, 19),
    WS2M = c(2, 2.1, 1.8, 2.2, 2),
    PS = rep(100, 5),
    elevation = rep(500, 5)
  )
}

test_that("surface energy module preserves rows and appends expected columns", {
  input <- make_surface_energy_input()

  output <- UFEED_expand_features(
    input,
    included_module = "surface_energy_radiation",
    message_progress = FALSE
  )

  expect_equal(nrow(output), nrow(input))
  expect_equal(output[, c("Date", "lon", "lat")], input[, c("Date", "lon", "lat")])
  expect_true(all(c(
    "DAYLENGTH_HOURS",
    "EXTRATERRESTRIAL_RADIATION",
    "CLEAR_SKY_RADIATION",
    "CLEARNESS_INDEX",
    "NET_SHORTWAVE_RADIATION",
    "NET_LONGWAVE_RADIATION",
    "NET_RADIATION",
    "ET0_FAO56_INDEPENDENT"
  ) %in% names(output)))
})

test_that("surface energy radiation features match independent FAO-56 equations", {
  input <- make_surface_energy_input()[1, ]
  output <- UFEED_compute_surface_energy_radiation_features(input)

  doy <- as.integer(format(input$Date, "%j"))
  lat_rad <- input$lat * pi / 180
  dr <- 1 + 0.033 * cos((2 * pi / 365) * doy)
  delta <- 0.409 * sin((2 * pi / 365) * doy - 1.39)
  sunset <- acos(pmin(pmax(-tan(lat_rad) * tan(delta), -1), 1))
  expected_daylength <- 24 / pi * sunset
  expected_ra <- (24 * 60 / pi) * 0.0820 * dr *
    (sunset * sin(lat_rad) * sin(delta) + cos(lat_rad) * cos(delta) * sin(sunset))
  expected_rso <- (0.75 + 2e-5 * input$elevation) * expected_ra
  expected_rns <- (1 - 0.23) * input$ALLSKY_SFC_SW_DWN

  manual_esat <- function(temperature) {
    0.6108 * exp((17.27 * temperature) / (temperature + 237.3))
  }

  ea <- manual_esat(input$T2MDEW)
  expected_rnl <- 4.903e-9 *
    (((input$T2M_MAX + 273.16)^4 + (input$T2M_MIN + 273.16)^4) / 2) *
    (0.34 - 0.14 * sqrt(ea)) *
    (1.35 * min(input$ALLSKY_SFC_SW_DWN / expected_rso, 1) - 0.35)
  expected_rn <- expected_rns - expected_rnl

  es <- (manual_esat(input$T2M_MAX) + manual_esat(input$T2M_MIN)) / 2
  delta_slope <- 4098 * manual_esat(input$T2M) / ((input$T2M + 237.3)^2)
  gamma <- 0.000665 * input$PS
  expected_et0 <- (
    0.408 * delta_slope * expected_rn +
      gamma * (900 / (input$T2M + 273)) * input$WS2M * (es - ea)
  ) / (
    delta_slope + gamma * (1 + 0.34 * input$WS2M)
  )

  expect_equal(output$DAYLENGTH_HOURS, expected_daylength, tolerance = 1e-8)
  expect_equal(output$EXTRATERRESTRIAL_RADIATION, expected_ra, tolerance = 1e-8)
  expect_equal(output$CLEAR_SKY_RADIATION, expected_rso, tolerance = 1e-8)
  expect_equal(output$CLEARNESS_INDEX, input$ALLSKY_SFC_SW_DWN / expected_ra, tolerance = 1e-8)
  expect_equal(output$NET_SHORTWAVE_RADIATION, expected_rns, tolerance = 1e-8)
  expect_equal(output$NET_LONGWAVE_RADIATION, expected_rnl, tolerance = 1e-8)
  expect_equal(output$NET_RADIATION, expected_rn, tolerance = 1e-8)
  expect_equal(output$ET0_FAO56_INDEPENDENT, expected_et0, tolerance = 1e-8)
})

test_that("surface energy ET0 is consistent with Evapotranspiration package", {
  skip_if_not_installed("Evapotranspiration")

  input <- make_surface_energy_input()
  output <- UFEED_compute_surface_energy_radiation_features(input)

  data("defaultconstants", package = "Evapotranspiration")
  constants <- defaultconstants
  constants$lat <- input$lat[1]
  constants$lat_rad <- input$lat[1] * pi / 180
  constants$Elev <- input$elevation[1]
  constants$z <- 2

  package_input <- data.frame(
    Year = as.integer(format(input$Date, "%Y")),
    Month = as.integer(format(input$Date, "%m")),
    Day = as.integer(format(input$Date, "%d")),
    Tmax = input$T2M_MAX,
    Tmin = input$T2M_MIN,
    va = 0.6108 * exp((17.27 * input$T2MDEW) / (input$T2MDEW + 237.3)),
    vs = (
      0.6108 * exp((17.27 * input$T2M_MAX) / (input$T2M_MAX + 237.3)) +
        0.6108 * exp((17.27 * input$T2M_MIN) / (input$T2M_MIN + 237.3))
    ) / 2,
    u2 = input$WS2M,
    Rs = input$ALLSKY_SFC_SW_DWN
  )

  processed <- Evapotranspiration::ReadInputs(
    varnames = c("Tmax", "Tmin", "va", "vs", "u2", "Rs"),
    climatedata = package_input,
    constants = constants,
    stopmissing = c(99, 99, 99),
    timestep = "daily",
    message = "no"
  )

  package_output <- Evapotranspiration::ET.PenmanMonteith(
    processed,
    constants,
    ts = "daily",
    solar = "data",
    wind = "yes",
    crop = "short",
    message = "no",
    AdditionalStats = "no",
    save.csv = "no"
  )

  expect_equal(
    as.numeric(output$ET0_FAO56_INDEPENDENT),
    as.numeric(package_output$ET.Daily),
    tolerance = 0.02
  )
})

test_that("surface energy module validates required inputs", {
  expect_error(
    UFEED_compute_surface_energy_radiation_features(data.frame(T2M = 20)),
    "Missing required column"
  )

  expect_error(
    UFEED_compute_surface_energy_radiation_features(
      data.frame(
        Date = as.Date("2024-06-01"),
        lat = 46,
        T2M = 20,
        T2M_MAX = 25,
        T2M_MIN = 15,
        ALLSKY_SFC_SW_DWN = 20,
        WS2M = 2
      )
    ),
    "requires `T2MDEW` or `RH2M`"
  )
})
