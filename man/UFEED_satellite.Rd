\name{UFEED_satellite}
\alias{UFEED_satellite}
\title{NASA MODIS canopy features for a land coordinate}
\usage{
UFEED_satellite(lat, lon, as_of = as.Date(Sys.time(), tz = "UTC"), prediction_ready = TRUE,
  lookback_days = 48L, cache_dir = tools::R_user_dir("UFEED", "cache"))
}
\arguments{
\item{lat, lon}{Latitude and longitude in decimal degrees.}
\item{as_of}{Issue date in UTC, interpreted at the day level.}
\item{prediction_ready}{If true, use only composites recorded in the local
cache by the issue date. If false, allow backfilled historical composites.}
\item{lookback_days}{Number of days before the issue date to search.}
\item{cache_dir}{Directory for site and composite cache files.}
}
\value{A one-row data frame with canopy values, composite dates, ages, and
quality codes. Features with no eligible retrieval are missing.}
\description{Downloads selected NASA MODIS canopy data from ORNL DAAC TESViS.
No Earth Engine account is needed.}
\details{Only composites ending before the issue date are considered.
A download today cannot prove historical availability. Prediction-ready
requests for past dates use only existing dated cache records. Satellite
pixels may represent mixed land cover.}
