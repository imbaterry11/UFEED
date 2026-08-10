# UFEED_feature_expansion_2

This module converts daily environmental forcing into transparent
reference-plant and environmental-exposure features. It must be applied after
`UFEED_feature_expansion_1` and does not modify UFEED core or expansion 1.

## Scientific boundary

Expansion 2 does **not** estimate actual photosynthesis, GPP, transpiration,
water stress, nitrogen stress, phenological stage, biomass, or yield. Those
require evolving plant/soil states and calibrated species, cultivar, and
management parameters. STICS uses such states and parameters in addition to
weather forcing.

Instead, the module describes a user-declared reference canopy:

- incident PAR from declared shortwave radiation and a declared PAR fraction;
- reference intercepted PAR using Beer-Lambert attenuation;
- reference absorbed PAR using a declared PAR absorptance;
- stress-free potential dry-matter opportunity using declared RUE;
- a separately reported cardinal-temperature-limited dry-matter opportunity;
- nonlinear Wang-Engel temperature responses for development and growth;
- an explicit neutral, long-day, or short-day photoperiod response;
- daily and crop-cycle atmospheric drought, frost, and heat exposure indices.

Potential dry matter is an RUE-model result, not measured biomass or biochemical
photosynthesis. The growth temperature response is a declared reference
modifier; it is not assumed to equal the development temperature response.

## Example pipeline

```r
source("UFEED_feature_expansion_1/R/UFEED_feature_expansion_1.R")
source("UFEED_feature_expansion_2/R/UFEED_feature_expansion_2.R")

physical <- UFEED_feature_expansion_1(
  raw_ufeed_data,
  input_units = physical_units,
  wind_height_m = 10
)

reference_plant <- UFEED_expansion_2_reference_parameters(
  reference_lai = 3,
  light_extinction_coefficient = 0.6,
  par_absorptance = 0.85,
  rue_g_mj_apar = 2.5,
  development_tmin_c = 0,
  development_topt_c = 26,
  development_tmax_c = 40,
  growth_tmin_c = 5,
  growth_topt_c = 25,
  growth_tmax_c = 40,
  photoperiod_type = "neutral",
  frost_threshold_c = 0,
  heat_threshold_c = 35
)

process_features <- UFEED_feature_expansion_2(
  physical,
  input_units = c(
    T2M = "degC", T2M_MAX = "degC", T2M_MIN = "degC",
    ALLSKY_SFC_SW_DWN = "MJ m-2 day-1"
  ),
  reference_parameters = reference_plant,
  cycle_id_columns = c("site_id", "crop_cycle_id")
)
```

`cycle_id_columns` is required for meaningful cumulative values. When it is
`NULL`, cumulative outputs are `NA`; the module never assumes that a calendar
year or the beginning of the supplied table is a crop-cycle boundary.

## Parameters that must be justified for each application

- LAI trajectory, m2 leaf m-2 ground
- canopy light-extinction coefficient
- canopy PAR absorptance
- RUE definition and unit, specifically g dry matter per MJ absorbed PAR
- development cardinal temperatures
- growth cardinal temperatures
- crop photoperiod class and thresholds
- biologically relevant frost and heat thresholds
- PAR fraction if direct PAR is unavailable

Do not transfer published RUE values unless they use the same radiation basis:
solar versus PAR, intercepted versus absorbed, and above-ground versus total
dry matter.

## Temporal features within expansion 2

`UFEED_feature_expansion_2_temporal()` adds selected 7-, 14-, and 30-day
EWMA/REWMA summaries, cycle-aware seasonal extrema, and rolling sums and maxima
for heat and frost severity. Already-cumulative features are not smoothed.

## Final product

`UFEED_finalize_feature_product()` returns only `Date`, `lon`, `lat`, numeric
core features, and numeric expansion/temporal features. It removes categorical
columns, the raw diagnostic ET0 result, the wind-height adjustment factor, and
the daily atmospheric-drought alias of daily VPD. Every feature is returned as
double precision; calculation parameters and QA remain outside the feature
matrix.
