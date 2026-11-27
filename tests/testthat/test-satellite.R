test_that("the satellite module keeps its schema and honors first-seen dates", {
  day <- as.Date("2024-06-20")
  cache <- tempfile()
  directory <- file.path(cache, "tesvis-v1",
                         "44.8400000000_-0.5800000000", "MCD15A3H")
  dir.create(directory, recursive = TRUE)
  on.exit(unlink(cache, recursive = TRUE))
  saveRDS(list(end = as.Date("2024-06-12"), first_seen = day - 1,
               bands = list(Lai_500m = 24, Fpar_500m = 62, FparLai_QC = 0)),
          file.path(directory, "A2024161.rds"))
  saveRDS(list(end = as.Date("2024-06-16"), first_seen = day + 1,
               bands = list(Lai_500m = 30, Fpar_500m = 70, FparLai_QC = 0)),
          file.path(directory, "A2024165.rds"))
  out <- UFEED_satellite(44.84, -0.58, day, cache_dir = cache)
  expect_equal(out$most_recent_LAI, 2.4)
  expect_equal(out$most_recent_FPAR, 0.62)
  expect_equal(out$LAI_age_days, 8L)
  expect_true(is.na(out$most_recent_NDVI))
  expect_true(is.na(UFEED_satellite(44.84, -0.58, day - 2,
                                  cache_dir = cache)$most_recent_LAI))
})

test_that("satellite retrievals are scaled and screened", {
  expect_equal(ufeed_modis_value(list(Lai_500m = 30, FparLai_QC = 32), "LAI"), 3)
  expect_true(is.na(ufeed_modis_value(list(Lai_500m = 30, FparLai_QC = 8), "LAI")))
  expect_equal(ufeed_modis_value(list(`250m_16_days_NDVI` = 6200,
                                     `250m_16_days_pixel_reliability` = 0), "NDVI"), 0.62)
})

test_that("daily satellite series never uses a future or unpublished composite", {
  local_mocked_bindings(ufeed_modis_composites = function(product, ...) {
    if (product != "MCD15A3H") return(list())
    list(list(end = as.Date("2024-06-01"), first_seen = as.Date("2024-06-04"),
              bands = list(Lai_500m = 24, Fpar_500m = 62, FparLai_QC = 0)))
  })
  dates <- as.Date("2024-06-01") + 0:4
  daily <- data.frame(Date = dates, lon = 1, lat = 2)
  retrospective <- ufeed_satellite_series(daily, dates[5], FALSE, tempdir())
  expect_equal(retrospective$most_recent_LAI, c(NA, rep(2.4, 4)))
  as_of <- ufeed_satellite_series(daily, dates[5], TRUE, tempdir())
  expect_equal(as_of$most_recent_LAI, c(rep(NA, 3), 2.4, 2.4))
  expect_equal(as_of$LAI_age_days, c(rep(NA_integer_, 3), 3L, 4L))
  expect_false("most_recent_ET_mm_composite" %in% names(as_of))
})

test_that("neighborhood fallback is quality screened and never replaces a valid point", {
  local_mocked_bindings(ufeed_modis_composites = function(product, lat, lon,
    as_of, today, prediction_ready, lookback_days, cache_dir, half_width_km = 0L) {
    if (product != "MCD15A3H" || lon != 1) return(list())
    seen <- as.Date("2024-06-02")
    if (half_width_km == 0L) {
      return(list(list(end = seen, first_seen = seen,
                       bands = list(Lai_500m = 25, Fpar_500m = 255, FparLai_QC = 0))))
    }
    list(list(end = seen, first_seen = seen,
              bands = list(Lai_500m = c(10, 30, 90), Fpar_500m = c(30, 50, 90),
                           FparLai_QC = c(0, 0, 8))))
  })
  dates <- as.Date("2024-06-01") + 0:3
  data <- rbind(data.frame(Date = dates, lon = 1, lat = 2),
                data.frame(Date = dates, lon = 3, lat = 4))
  out <- ufeed_satellite_series(data, dates[4], FALSE, tempdir(), half_width_km = 3L)
  first <- out[out$lon == 1 & out$Date == dates[3], ]
  expect_equal(first$most_recent_LAI, 2.5)
  expect_equal(first$LAI_source, "point")
  expect_equal(first$most_recent_FPAR, 0.4)
  expect_equal(first$FPAR_source, "neighborhood_median")
  expect_equal(first$FPAR_valid_pixels, 2L)
  expect_equal(first$FPAR_half_width_km, 3L)
  expect_true(is.na(first$FPAR_quality))
  expect_true(all(is.na(out$most_recent_FPAR[out$lon == 3])))
  expect_true(all(is.na(out$most_recent_FPAR[out$Date <= dates[2]])))
})
