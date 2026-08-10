# UFEED_feature_expansion_1

This isolated, sourceable post-processing module operates on completed UFEED
daily environmental data. It does not change downloading or core EWMA, REWMA,
cumulative, minimum, maximum, or seasonal calculations.

## Unit contract

The module never guesses units from numeric magnitudes. Callers must provide a
named `input_units` vector and the wind measurement height. Values are converted
internally to the FAO-56 calculation system: degC, kPa, m s-1 at 2 m,
MJ m-2 day-1, meters above sea level, and decimal degrees.

Open-Meteo wind is measured at 10 m, so use `wind_height_m = 10`. NASA POWER
`WS2M` is nominally at 2 m, so use `wind_height_m = 2`. Verify the source when
data were combined; do not rely only on the column name.

```r
source("UFEED_feature_expansion_1/R/UFEED_feature_expansion_1.R")

expanded <- UFEED_feature_expansion_1(
  completed_ufeed_data,
  input_units = c(
    lat = "degree", T2M = "degC", T2M_MAX = "degC", T2M_MIN = "degC",
    T2MDEW = "degC", RH2M = "percent", PS = "kPa", WS2M = "m s-1",
    ALLSKY_SFC_SW_DWN = "MJ m-2 day-1", elevation = "m"
  ),
  wind_height_m = 10
)
```

## Interpretation rules

- `VPD_DAILY_FAO56_KPA` uses mean saturation vapor pressure at daily Tmax and
  Tmin and is the VPD term used for daily FAO-56 ET0.
- `VPD_TMEAN_KPA` is a separate plant-response predictor evaluated at Tmean.
- VPD at Tmax and Tmin is explicitly labeled as a proxy because daily mean
  humidity is not simultaneous with temperature extremes.
- Dew point is preferred for actual vapor pressure. Mean RH is a documented,
  lower-quality FAO-56 fallback.
- `VPD_WIND_INTERACTION_KPA_M_S` is a model interaction term, not a flux.
- `ET0_FAO56_MM_DAY` is reference ET for hypothetical well-watered short grass;
  it is not actual ET, crop ET, or transpiration.
- Net radiation is retained even when negative. Both raw and nonnegative ET0
  are provided.

See `REFERENCES.md` and `FEATURE_DICTIONARY.csv` for provenance and units.

## Temporal features within expansion 1

`UFEED_feature_expansion_1_temporal()` adds selected physical-process EWMA
and REWMA summaries, season-to-date extrema, and cycle cumulative ET0 and net
radiation. Defaults are 7, 14, and 30 days. `cycle_id_columns` must be
explicit; biological-season boundaries are never inferred.
