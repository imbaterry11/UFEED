test_that("atmospheric demand preserves rows and keys", {
  input <- data.frame(
    Date = as.Date("2024-06-01") + 0:2,
    lon = rep(7.155, 3),
    lat = rep(46.16, 3),
    T2M = c(20, 21, 22),
    T2MDEW = c(10, 11, 12),
    RH2M = c(80, 80, 80),
    PS = c(101.3, 101.3, 101.3),
    WS2M = c(2, 3, 4)
  )

  output <- UFEED_expand_features(input, message_progress = FALSE)

  expect_equal(nrow(output), nrow(input))
  expect_equal(output[, c("Date", "lon", "lat")], input[, c("Date", "lon", "lat")])
  expect_true(all(c(
    "ESAT_T2M", "EA", "VPD", "SPECIFIC_HUMIDITY", "VPD_WIND"
  ) %in% names(output)))
})

test_that("dew point is preferred over relative humidity", {
  input <- data.frame(
    T2M = 20,
    T2MDEW = 10,
    RH2M = 100
  )

  output <- UFEED_compute_atmospheric_demand_features(input)

  dewpoint_ea <- bigleaf::Esat.slope(10, formula = "Allen_1998")[, "Esat"]
  rh_ea <- bigleaf::Esat.slope(20, formula = "Allen_1998")[, "Esat"]

  expect_equal(output$EA, as.numeric(dewpoint_ea), tolerance = 1e-8)
  expect_false(isTRUE(all.equal(output$EA, as.numeric(rh_ea), tolerance = 1e-8)))
})

test_that("relative humidity is used when dew point is missing", {
  input <- data.frame(
    T2M = 20,
    T2MDEW = NA_real_,
    RH2M = 50
  )

  output <- UFEED_compute_atmospheric_demand_features(input)

  expected_ea <- as.numeric(bigleaf::Esat.slope(20, formula = "Allen_1998")[, "Esat"]) * 0.5
  expect_equal(output$EA, expected_ea, tolerance = 1e-8)
})

test_that("optional columns generate NA features rather than failure", {
  input <- data.frame(
    T2M = c(20, 21),
    RH2M = c(50, 55)
  )

  output <- UFEED_compute_atmospheric_demand_features(input)

  expect_true(all(is.na(output$ESAT_T2M_MAX)))
  expect_true(all(is.na(output$ESAT_T2M_MIN)))
  expect_true(all(is.na(output$VPD_MAX_PROXY)))
  expect_true(all(is.na(output$VPD_MIN_PROXY)))
  expect_true(all(is.na(output$DEWPOINT_DEPRESSION)))
  expect_true(all(is.na(output$SPECIFIC_HUMIDITY)))
  expect_true(all(is.na(output$VPD_WIND)))
})

test_that("negative VPD is clamped by default and can be retained", {
  input <- data.frame(
    T2M = 10,
    T2MDEW = 20
  )

  clamped <- UFEED_compute_atmospheric_demand_features(input)
  unclamped <- UFEED_compute_atmospheric_demand_features(
    input,
    clamp_negative_vpd = FALSE
  )

  expect_equal(clamped$VPD, 0)
  expect_lt(unclamped$VPD, 0)
})

test_that("specific humidity requires valid pressure", {
  input <- data.frame(
    T2M = c(20, 20),
    T2MDEW = c(10, 10),
    PS = c(101.3, 0.5)
  )

  output <- UFEED_compute_atmospheric_demand_features(input)

  expect_true(is.finite(output$SPECIFIC_HUMIDITY[1]))
  expect_true(is.na(output$SPECIFIC_HUMIDITY[2]))
})

test_that("atmospheric demand matches independent Allen-style equations", {
  input <- data.frame(
    T2M = 25,
    T2M_MAX = 31,
    T2M_MIN = 18,
    T2MDEW = 14,
    RH2M = 99,
    PS = 100,
    WS2M = 2.5
  )

  output <- UFEED_compute_atmospheric_demand_features(input)

  manual_esat <- function(temperature) {
    0.6108 * exp((17.27 * temperature) / (temperature + 237.3))
  }

  expected_esat <- manual_esat(input$T2M)
  expected_ea <- manual_esat(input$T2MDEW)
  expected_vpd <- expected_esat - expected_ea
  expected_specific_humidity <- 0.622 * expected_ea /
    (input$PS - 0.378 * expected_ea)

  expect_equal(output$ESAT_T2M, expected_esat, tolerance = 1e-3)
  expect_equal(output$EA, expected_ea, tolerance = 1e-3)
  expect_equal(output$VPD, expected_vpd, tolerance = 1e-3)
  expect_equal(output$VPD_MAX_PROXY, manual_esat(input$T2M_MAX) - expected_ea, tolerance = 1e-3)
  expect_equal(output$VPD_MIN_PROXY, manual_esat(input$T2M_MIN) - expected_ea, tolerance = 1e-3)
  expect_equal(output$DEWPOINT_DEPRESSION, input$T2M - input$T2MDEW)
  expect_equal(output$SPECIFIC_HUMIDITY, expected_specific_humidity, tolerance = 1e-6)
  expect_equal(output$VPD_WIND, expected_vpd * input$WS2M, tolerance = 1e-3)
})

test_that("invalid expansion modules and missing humidity inputs error clearly", {
  expect_error(
    UFEED_expand_features(data.frame(T2M = 20), included_module = "bad_module"),
    "Unknown expansion module"
  )

  expect_error(
    UFEED_compute_atmospheric_demand_features(data.frame(T2M = 20)),
    "requires `T2MDEW` or `RH2M`"
  )
})
