\name{UFEED}
\alias{UFEED}
\title{Build environmental features from downloaded or supplied data}
\usage{
UFEED(lon = NULL, lat = NULL, start_date = NULL, end_date = NULL,
  weather = NULL, soil = NULL, modules = c("weather", "soil"),
  weather_data_source = c("power", "open_meteo"), soil_data_source = NULL,
  soil_data_local_dir = "", fill_missing = FALSE, forecast_days = 0L,
  prediction_ready = FALSE, as_of = NULL, progress = interactive(),
  satellite_cache_dir = tools::R_user_dir("UFEED", "cache"),
  satellite_half_width_km = 3L, crop_model = NULL)
}
\arguments{
\item{lon, lat}{Coordinates, or use coordinate columns in supplied weather.}
\item{start_date, end_date}{Inclusive dates. Defaults to the supplied weather
range, or January 1 through today when downloading weather.}
\item{weather}{Optional daily table with Date and canonical UFEED weather fields.
When filling gaps, use the same daily boundary (UTC) and units as the provider.}
\item{soil}{Optional soil table, keyed by lon and lat for multiple sites.}
\item{modules}{One or more of weather, soil, derived, and satellite.
Core is shorthand for weather and soil. A soil-only request skips weather.}
\item{weather_data_source}{Historical weather provider: power or open_meteo.}
\item{soil_data_source}{Remote, local, or none (lower case). Defaults to remote
when downloading weather and none when supplying it.}
\item{soil_data_local_dir}{Directory for local soil inputs.}
\item{fill_missing}{Fill missing dates and NA in recognized existing fields
using downloaded weather, without replacing nonmissing values.}
\item{forecast_days}{Future dates to request (0 to 15); live forecasts use
Open-Meteo regardless of the historical weather provider.}
\item{prediction_ready}{Use a date cutoff and omit noncausal core summaries.}
\item{as_of}{Issue date, defaulting to today. Historical downloads do not
establish that a weather value had already been published on a past issue date.}
\item{progress}{Show weather request progress and data coverage.}
\item{satellite_cache_dir}{Directory for reusable NASA MODIS point subsets.}
\item{satellite_half_width_km}{Half-width of the square MODIS fallback window
in kilometers. Set to zero for point-only data.}
\item{crop_model}{Optional list with a crop name and named engine runners or
CroptimizR configurations. User-supplied wrappers are responsible for using
only weather and other inputs appropriate to the selected issue date.}
}
\description{Combines historical or current weather, optional soil, and selected
feature groups. Known user data are retained when filling gaps.}
\details{Open-Meteo call estimates are based on request duration and variable
count. They are not account usage. Set OPEN_METEO_API_KEY in your local
.Renviron to use the customer endpoint. The satellite module attaches the
latest eligible composite to each daily row, up to 48 days old at its
information cutoff. Finalized gap-filled ET is retrospective only.
When a valid point composite is unavailable, the satellite module can use the
median of quality-screened pixels within the fallback window. Source, pixel
count, and window size are reported. Sites without usable pixels retain NA.
Historical prediction-ready satellite results require a dated local cache.
This interface does not reconstruct historical weather
publication times or previously issued forecasts.}
\value{Daily feature table. Attributes download_report, weather_fill and
weather_coverage describe weather requests, filled cells, and coverage.}
