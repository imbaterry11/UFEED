# UFEED

**UFEED** (*Universal Feature Extraction from Environmental Data*) is an R package for downloading, processing, and engineering environmental features for plant physiology and crop modeling. It was developed to support automated modeling workflows where physiological observations.

UFEED can be used in two ways:

1. **High-level workflow**: one function downloads weather, computes the standard UFEED feature set, extracts soil features, and returns a modelling table.
2. **Modular workflow**: users can download weather, replace it with local weather-station data, compute selected feature modules with custom parameters, extract soil features, and combine everything themselves.

![UFEED workflow](man/figures/FigureS1_UFEED_workflow.png)

---

## Installation

```r
install.packages("remotes")

remotes::install_github(
  "imbaterry11/UFEED",
  dependencies = TRUE,
  upgrade = "never"
)
```

Then load the package:

```r
library(UFEED)
```

Some optional workflows, especially those using Earth Engine through `weather_data_source = "power_ee"`, require a working `rgee`/Google Earth Engine configuration.

---

## Main functions

### High-level wrappers

| Function | Purpose |
|---|---|
| `UFEED_history()` | Full historical workflow: download historical weather, compute standard UFEED features, extract soil features, and return one modelling table. |
| `UFEED_present()` | Full present-season workflow: combine recent historical weather with Open-Meteo recent/forecast data, compute standard UFEED features, extract soil features, and return one modelling table. |

### Modular workflow functions

| Function | Purpose |
|---|---|
| `UFEED_download_history_weather()` | Download historical daily weather. |
| `UFEED_download_present_weather()` | Download present-season weather. For Northern Hemisphere sites, this includes data starting from September 1 of the previous year so dormant-season cumulative features can be computed. |
| `UFEED_compute_weather_features()` | Compute selected weather-derived feature modules from downloaded or user-supplied weather data. |
| `UFEED_get_soil_features()` | Extract SoilGrids-derived static soil features. |
| `UFEED_wrap_up()` | Join raw weather, computed weather features, and soil features into one UFEED modelling data frame. |

---

## Quick start: historical UFEED table

```r
soil_dir <- "/path/to/soilgrids_1k"

ufeed_history <- UFEED_history(
  lon = 7.155,
  lat = 46.16,
  start_year = 2023,
  end_year = 2024,
  weather_data_source = "power",
  soil_data_source = "local",
  soil_data_local_dir = soil_dir
)
```

For multiple paired sites:

```r
ufeed_history <- UFEED_history(
  lon = c(7.155, 7.300),
  lat = c(46.160, 46.250),
  start_year = 2023,
  end_year = 2024,
  weather_data_source = "power",
  soil_data_source = "local",
  soil_data_local_dir = soil_dir
)
```

---

## Quick start: present-season UFEED table

```r
soil_dir <- "/path/to/soilgrids_1k"

ufeed_present <- UFEED_present(
  lon = 7.155,
  lat = 46.16,
  weather_data_source = "power",
  soil_data_source = "local",
  soil_data_local_dir = soil_dir
)
```

`UFEED_present()` uses a historical backbone plus recent/forecast Open-Meteo data. This allows the current dormant or growing season to be represented up to the forecast horizon.

---

## Modular workflow

The modular workflow is useful when users want to inspect intermediate data, use their own weather-station data, or customize the feature engineering settings.

### 1. Download historical weather

```r
weather <- UFEED_download_history_weather(
  lon = 7.155,
  lat = 46.16,
  start_year = 2023,
  end_year = 2024,
  weather_data_source = "power"
)
```

Available historical weather sources:

```r
c("power", "power_ee", "power_open_meteo")
```

- `"power"`: NASA POWER daily weather.
- `"power_ee"`: NASA POWER plus Google Earth Engine / ERA5-Land-derived variables where used by the UFEED workflow.
- `"power_open_meteo"`: NASA POWER plus Open-Meteo-derived variables where used by the UFEED workflow.

### 2. Or use local weather-station data

Users can bypass the download step and provide their own daily weather data. At minimum, all user-supplied weather data must include:

```r
c("Date", "lon", "lat")
```

For cumulative temperature features, the weather data must also include:

```r
c("T2M_MAX", "T2M_MIN")
```

A simple local-weather example:

```r
local_weather <- readr::read_csv("local_weather.csv") |>
  dplyr::mutate(
    Date = as.Date(Date),
    lon = 7.155,
    lat = 46.16
  )
```

### 3. Compute weather features

```r
weather_features <- UFEED_compute_weather_features(
  weather_data = weather,
  feature_profile = "history"
)
```

`feature_profile` controls which default variable sets are used:

```r
feature_profile = "history"
feature_profile = "present"
feature_profile = "auto"
```

Use `"history"` for data from `UFEED_download_history_weather()` and `"present"` for data from `UFEED_download_present_weather()`. The `"auto"` option tries to infer the appropriate profile from the available columns.

### 4. Extract soil features

```r
soil_features <- UFEED_get_soil_features(
  lon = 7.155,
  lat = 46.16,
  soil_data_source = "local",
  soil_data_local_dir = soil_dir
)
```

Available soil sources:

```r
c("remote", "local")
```

Use `"local"` when SoilGrids rasters have already been downloaded to a local directory. Use `"remote"` to extract soil features from remote SoilGrids resources.

### 5. Combine everything

```r
ufeed_df <- UFEED_wrap_up(
  weather_data = weather,
  weather_features = weather_features,
  soil_features = soil_features
)
```

You can also filter the final table:

```r
ufeed_df <- UFEED_wrap_up(
  weather_data = weather,
  weather_features = weather_features,
  soil_features = soil_features,
  start_filter_date = "2023-09-01",
  end_filter_date = "2024-08-31"
)
```

---

## Weather feature modules

`UFEED_compute_weather_features()` can compute four feature modules:

```r
included_module = c(
  "cumsum_features",
  "EWMA_REWMA_features",
  "cumulative_temp_features",
  "season_summary_features"
)
```

| Module | Description |
|---|---|
| `"cumsum_features"` | Seasonal cumulative sums for selected radiation and precipitation variables. |
| `"EWMA_REWMA_features"` | Exponentially weighted moving average and reverse EWMA features for selected daily weather variables. |
| `"cumulative_temp_features"` | Chilling, growing degree day, and growing degree hour features based on daily maximum and minimum temperature. |
| `"season_summary_features"` | Seasonal maximum and minimum summaries for selected variables. |

Example: compute only EWMA/REWMA and cumulative temperature features:

```r
weather_features <- UFEED_compute_weather_features(
  weather_data = weather,
  feature_profile = "history",
  included_module = c("EWMA_REWMA_features", "cumulative_temp_features")
)
```

---

## Column-selection rules

For column arguments, UFEED uses biologically meaningful default sets rather than all numeric columns.

The following arguments can be set to `"default"` or to a smaller valid subset:

```r
cumsum_cols
ewma_rewma_cols
season_max_cols
season_min_cols
```

Rules:

1. `"default"` uses the appropriate UFEED default set for the selected `feature_profile`.
2. If a default column is missing from `weather_data`, it is skipped with a message.
3. If the user explicitly requests a column that is not valid for that feature category, the function errors.
4. If the user explicitly requests a valid column that is absent from `weather_data`, the function errors.

### Cumulative-sum variables

Historical profile defaults:

```r
c(
  "ALLSKY_SFC_SW_DWN",
  "ALLSKY_SFC_LW_DWN",
  "ALLSKY_SFC_PAR_TOT",
  "PRECTOTCORR"
)
```

Present profile defaults:

```r
c(
  "ALLSKY_SFC_SW_DWN",
  "PRECTOTCORR"
)
```

Example:

```r
weather_features <- UFEED_compute_weather_features(
  weather_data = weather,
  feature_profile = "history",
  cumsum_cols = c("ALLSKY_SFC_SW_DWN", "PRECTOTCORR")
)
```

### EWMA/REWMA variables

Historical profile defaults:

```r
c(
  "T2M", "T2M_MAX", "T2M_MIN", "T2MDEW", "Daily_Temp_Fluctuation",
  "ALLSKY_SFC_SW_DWN", "ALLSKY_SFC_LW_DWN", "ALLSKY_SFC_PAR_TOT",
  "PRECTOTCORR", "RH2M", "WS2M", "WD2M", "WS2M_MAX", "WS2M_MIN",
  "PS", "GWETROOT", "GWETTOP", "TSOIL1", "TSOIL3", "EVPTRNS", "CLOUD_AMT"
)
```

Present profile defaults:

```r
c(
  "T2M", "T2M_MAX", "T2M_MIN", "T2MDEW", "Daily_Temp_Fluctuation",
  "ALLSKY_SFC_SW_DWN", "PRECTOTCORR", "RH2M", "WS2M", "WD2M",
  "WS2M_MAX", "WS2M_MIN", "PS", "GWETROOT", "GWETTOP", "TSOIL1",
  "TSOIL3", "EVPTRNS"
)
```

Example:

```r
weather_features <- UFEED_compute_weather_features(
  weather_data = weather,
  feature_profile = "history",
  ewma_rewma_cols = c("T2M", "T2M_MAX", "T2M_MIN", "PRECTOTCORR"),
  ewma_rewma_windows = c(3, 7, 14, 30)
)
```

### Seasonal maximum variables

Valid choices:

```r
c(
  "T2M_MAX",
  "Daily_Temp_Fluctuation",
  "WS2M_MAX",
  "GWETROOT",
  "GWETTOP",
  "TSOIL1",
  "TSOIL3",
  "EVPTRNS"
)
```

Example:

```r
weather_features <- UFEED_compute_weather_features(
  weather_data = weather,
  feature_profile = "history",
  season_max_cols = c("T2M_MAX", "WS2M_MAX")
)
```

### Seasonal minimum variables

Valid choices:

```r
c(
  "T2M_MIN",
  "Daily_Temp_Fluctuation",
  "GWETROOT",
  "GWETTOP",
  "TSOIL1",
  "TSOIL3",
  "EVPTRNS"
)
```

Example:

```r
weather_features <- UFEED_compute_weather_features(
  weather_data = weather,
  feature_profile = "history",
  season_min_cols = c("T2M_MIN")
)
```

`T2M_MIN` is valid for `season_min_cols`, but it is not valid for `season_max_cols`.

---

## Window and temperature-base settings

The following arguments accept user-supplied integer vectors and do not need to be subsets of the default values:

```r
ewma_rewma_windows
cumulative_temp_rollsum_windows
cumulative_temp_gdh_bases
cumulative_temp_gdd_bases
```

Defaults:

```r
ewma_rewma_windows = c(2, 3, 4, 5, 6, 7, 10, 14, 21, 30, 45, 60, 90)
cumulative_temp_rollsum_windows = c(3, 7, 14, 30, 60, 90)
cumulative_temp_gdh_bases = c(10, 7, 4, 0)
cumulative_temp_gdd_bases = c(0, 4, 7, 10)
```

`ewma_rewma_windows` must be integer values greater than or equal to 2. A value of 1 is not allowed.

Example:

```r
weather_features <- UFEED_compute_weather_features(
  weather_data = weather,
  feature_profile = "history",
  ewma_rewma_windows = c(5, 15, 45, 120),
  cumulative_temp_rollsum_windows = c(5, 10, 20, 40),
  cumulative_temp_gdh_bases = c(0, 5, 10, 15),
  cumulative_temp_gdd_bases = c(0, 6, 8, 12)
)
```

---

## Cumulative temperature features

The cumulative temperature module requires:

```r
c("Date", "lon", "lat", "T2M_MAX", "T2M_MIN")
```

It can compute:

```r
cumulative_temp_chilling_models = c("CU", "Utah", "NC", "DP")
```

where:

- `"CU"`: chilling units
- `"Utah"`: modified Utah model
- `"NC"`: North Carolina model
- `"DP"`: dynamic model chill portions

Example:

```r
weather_features <- UFEED_compute_weather_features(
  weather_data = weather,
  feature_profile = "history",
  included_module = "cumulative_temp_features",
  cumulative_temp_chilling_models = c("CU", "Utah", "DP"),
  cumulative_temp_rollsum_windows = c(7, 14, 30),
  cumulative_temp_gdh_bases = c(4, 7, 10),
  cumulative_temp_gdd_bases = c(0, 4, 7, 10),
  cumulative_temp_gdh_Topt = 25,
  cumulative_temp_gdh_Tcrit = 36
)
```

If `"cumulative_temp_features"` is selected and either `T2M_MAX` or `T2M_MIN` is missing, UFEED stops with an error.

---

## Example: using local weather-station data

```r
local_weather <- readr::read_csv("my_station_weather.csv") |>
  dplyr::mutate(
    Date = as.Date(Date),
    lon = 7.155,
    lat = 46.16
  )

weather_features <- UFEED_compute_weather_features(
  weather_data = local_weather,
  feature_profile = "history",
  included_module = c("EWMA_REWMA_features", "cumulative_temp_features"),
  ewma_rewma_cols = c("T2M", "T2M_MAX", "T2M_MIN", "PRECTOTCORR"),
  ewma_rewma_windows = c(7, 14, 30),
  cumulative_temp_rollsum_windows = c(7, 14, 30)
)

soil_features <- UFEED_get_soil_features(
  lon = 7.155,
  lat = 46.16,
  soil_data_source = "local",
  soil_data_local_dir = soil_dir
)

ufeed_df <- UFEED_wrap_up(
  weather_data = local_weather,
  weather_features = weather_features,
  soil_features = soil_features
)
```

---

## Testing during development

From the package root:

```r
devtools::document()
devtools::install()
```

Restart R, then run:

```r
library(UFEED)

testthat::test_file("tests/testthat/test-compute-weather-features.R")
```

Or run the full package test suite:

```r
devtools::test()
```

---

## Development workflow

After editing package code:

```bash
git status
git diff --stat
```

Then in R:

```r
devtools::document()
devtools::install()
```

After testing:

```bash
git add DESCRIPTION NAMESPACE R/ man/ tests/
git commit -m "Describe the change"
git push
```

---

## License

This package is released under the MIT license. See `LICENSE` and `LICENSE.md` for details.

---

## Citation

If you use UFEED in a publication or analysis, please cite the corresponding UFEED software repository and any associated manuscript describing the environmental feature-engineering workflow.
