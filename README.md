# UFEED

**UFEED** (*Universal Feature Extraction from Environmental Data*) is an R package for downloading, processing, and engineering environmental features for plant physiology and crop modeling. It was developed to support automated modeling workflows where physiological observations.

UFEED can be used in two ways:

1. **High-level workflow**: one function downloads weather, computes the standard UFEED feature set, extracts soil features, and returns a modelling-ready dataframe.
2. **Modular workflow**: users can download weather, replace it with local weather station data, compute selected feature modules with custom parameters, extract soil features, and combine everything themselves.

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

Some optional workflows, especially those using Google Earth Engine through `weather_data_source = "power_ee"`, require a working [`rgee`](https://github.com/r-spatial/rgee) and Google Earth Engine configuration. Users who want to use this option should follow the installation, authentication, and configuration procedures described in the [`rgee` GitHub repository](https://github.com/r-spatial/rgee) before running UFEED functions with `weather_data_source = "power_ee"`.

---

## Data source options

UFEED separates weather data acquisition, weather feature computation, soil feature extraction, and final table assembly. This is useful because users can either run the default UFEED workflow or replace intermediate data with local measurements, such as data from a weather station.

### Historical weather sources

Historical weather can be downloaded through `UFEED_history()` or `UFEED_download_history_weather()` using the `weather_data_source` argument.

| `weather_data_source` | Main data source | How UFEED uses it | Main advantages | Main limitations | Setup required |
|---|---|---|---|---|---|
| `"power"` | [NASA POWER daily API](https://power.larc.nasa.gov/docs/services/api/temporal/daily/) | Uses NASA POWER as the direct weather source for the requested daily variables. | Easiest option; no user account or API key; suitable for large batch downloads; generally few practical API-access barriers for normal research use. | Coarser spatial resolution. NASA POWER meteorology is commonly provided at approximately 0.5° × 0.625°, while solar parameters are commonly provided at approximately 1° × 1° resolution. See NASA POWER API guidance for details. | None. This option can be used directly after installing UFEED. |
| `"power_open_meteo"` | [NASA POWER](https://power.larc.nasa.gov/) + [Open-Meteo](https://open-meteo.com/) | Uses NASA POWER as the backbone, then replaces available variables with Open-Meteo/ERA5-derived data where implemented in UFEED. | Higher spatial resolution than POWER-only for many variables; fast; no API key required for non-commercial use; useful when ERA5-like spatial resolution is desired without Earth Engine setup. | The free Open-Meteo API is rate-limited. Open-Meteo currently describes the free non-commercial API as limited to 10,000 calls/day, 5,000 calls/hour, and 600 calls/minute, with subscription options for higher/commercial use. Check the [Open-Meteo terms](https://open-meteo.com/en/terms) and [pricing page](https://open-meteo.com/en/pricing) before large-scale runs. | None for normal free non-commercial use, but large jobs may need batching or a subscription. |
| `"power_ee"` | [NASA POWER](https://power.larc.nasa.gov/) + [Google Earth Engine](https://earthengine.google.com/) [ERA5-Land Daily Aggregated](https://developers.google.com/earth-engine/datasets/catalog/ECMWF_ERA5_LAND_DAILY_AGGR#bands) | Uses NASA POWER as the backbone, then replaces available parameters with ERA5-Land daily aggregated variables through Earth Engine where implemented in UFEED. | High-resolution ERA5-Land data through Google Earth Engine; suitable for large spatial workflows once configured; avoids many direct API call limitations associated with repeatedly downloading ERA5 data through ordinary web APIs. | More complicated setup. Users must configure `rgee`, authenticate Google Earth Engine, and use a registered Google Cloud / Earth Engine project. | Required. Follow the [`rgee` repository](https://github.com/r-spatial/rgee) and Google Earth Engine project setup guidance before using this option. |

A simple decision guide:

```text
Need the easiest setup and broad compatibility?
  -> use weather_data_source = "power"

Need better spatial resolution without Earth Engine setup?
  -> use weather_data_source = "power_open_meteo"

Need ERA5-Land through Earth Engine for larger spatial workflows?
  -> use weather_data_source = "power_ee"
```

### Notes on `power_ee`

The `power_ee` option requires a working [`rgee`](https://github.com/r-spatial/rgee) installation and Google Earth Engine authentication. Users also need access to a Google Cloud / Earth Engine project. The `rgee` repository notes that a Cloud project needs to be created and registered for Earth Engine use, and that the project ID is supplied when initializing Earth Engine sessions. Follow the setup, authentication, and troubleshooting instructions in the [`rgee` GitHub repository](https://github.com/r-spatial/rgee) and the [Google Earth Engine access guide](https://developers.google.com/earth-engine/guides/access).

In UFEED, this option uses NASA POWER as the backbone and replaces available variables using the Earth Engine dataset [`ECMWF/ERA5_LAND/DAILY_AGGR`](https://developers.google.com/earth-engine/datasets/catalog/ECMWF_ERA5_LAND_DAILY_AGGR#bands). Users who need to inspect variable definitions should check the ERA5-Land Daily Aggregated dataset page, especially the band list.

### Present-season weather sources

`UFEED_present()` and `UFEED_download_present_weather()` also use previous weather data to compute cumulative dormant-season and growing-season features. For Northern Hemisphere sites, the present-season workflow needs weather beginning from September 1 of the previous year so that dormant-season cumulative features can be computed. For Southern Hemisphere sites, UFEED uses the corresponding Southern Hemisphere seasonal logic.

The `weather_data_source` argument is still available for the historical/backbone part of the present-season workflow:

```r
weather_data_source = c("power", "power_ee", "power_open_meteo")
```

However, very recent and forecast weather in the present-season workflow is handled with Open-Meteo by default. This allows UFEED to extend the current season through the recent/forecast horizon, while still using the selected historical backbone to compute cumulative features.

### Soil data sources

Static soil features are extracted from [SoilGrids](https://isric.org/explore/soilgrids). In UFEED, the `soil_data_source` argument controls whether these rasters are accessed from local files or remotely.

| `soil_data_source` | Data access mode | Recommended use | Advantages | Limitations |
|---|---|---|---|---|
| `"local"` | Reads SoilGrids `.tif` files from a local folder. | Best option when extracting static soil properties for many sites or repeated analyses. | Much faster for many lon/lat combinations; avoids repeated remote file access; more reproducible once files are downloaded. | Requires users to download and store the required SoilGrids files first. |
| `"remote"` | Accesses SoilGrids files remotely. | Convenient for small jobs or quick testing. | No local SoilGrids folder required. | Slower than local access; more sensitive to network/server availability; large repeated jobs may be inefficient. |

For `soil_data_source = "local"`, the local folder should contain the relevant SoilGrids `.tif` files for each static soil-property category used by UFEED. The 1 km aggregated SoilGrids files are available from the ISRIC SoilGrids WebDAV directory:

<https://files.isric.org/soilgrids/latest/data_aggregated/1000m/>

See also the ISRIC SoilGrids WebDAV documentation:

<https://docs.isric.org/globaldata/soilgrids/WebDav.html>

A typical local-soil setup looks like this:

```text
soilgrids_1k/
  bdod/
  cec/
  cfvo/
  clay/
  nitrogen/
  ocd/
  phh2o/
  sand/
  silt/
  soc/
  ocs/
  wv0010/
  wv0033/
  wv1500/
```

Then use:

```r
soil_features <- UFEED_get_soil_features(
  lon = 7.155,
  lat = 46.16,
  soil_data_source = "local",
  soil_data_local_dir = "/path/to/soilgrids_1k"
)
```

For small tests where no local SoilGrids folder has been prepared, use:

```r
soil_features <- UFEED_get_soil_features(
  lon = 7.155,
  lat = 46.16,
  soil_data_source = "remote"
)
```


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

## License

This package is released under the MIT license. See `LICENSE` and `LICENSE.md` for details.

---

## Citation

If you use UFEED in a publication or analysis, please cite the corresponding UFEED software repository and any associated manuscript describing the environmental feature-engineering workflow.
