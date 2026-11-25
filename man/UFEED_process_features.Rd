\name{UFEED_process_features}
\alias{UFEED_apsim_runner}
\alias{UFEED_precipitation_indices}
\alias{UFEED_reference_water_balance}
\alias{UFEED_soil_water_capacity}
\alias{UFEED_feature_expansion_1}
\alias{UFEED_feature_expansion_1_canonical_units}
\alias{UFEED_feature_expansion_1_temporal}
\alias{UFEED_feature_expansion_2}
\alias{UFEED_feature_expansion_2_temporal}
\alias{UFEED_expansion_2_reference_parameters}
\alias{UFEED_finalize_feature_product}
\title{Experimental precipitation, soil and crop process features}
\description{Optional post-processing for UFEED weather and SoilGrids tables.
See the feature expansion section in the package repository README for the
input contract, example and limitations.}
\details{
Precipitation summaries default to complete calendar years. Supply a table
with lon, lat, start and end (Date) to compute other windows. Supply a complete
prior baseline as two Dates for wet-day percentiles. Full-period results
should only be used after the end of their calculation window. The calendar
year precipitation share is only available after the entire denominator year.

Soil water capacity uses raw SoilGrids water retention and coarse fragments.
The reference water balance assumes rainfed conditions and uses daily
reference evapotranspiration. Its default scenario uses a 100 cm profile
initialized at half its plant-available capacity.

Crop runners receive weather, soil and crop and return a data frame of
Date, lon, lat and numeric simulated variables. APSIM uses the soil and
management already configured in the supplied template. STICS and DSSAT
require runner functions. Each engine has its own run status and output prefix.
Select \code{"crop_model_features"} in \code{UFEED_compute_weather_features}.
The \code{croptimizr} entry in \code{crop_model} accepts named engine configurations with a
\code{wrapper}, \code{model_options}, optional \code{param_values}, and a
\code{sites} table with \code{situation}, \code{lon}, and \code{lat}.
The wrapper runs a configured simulation and returns \code{error} and
\code{sim_list} using the CroptimizR format.
}
