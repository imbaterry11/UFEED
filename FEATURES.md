# UFEED feature descriptions

Use the [feature inventory](UFEED_feature_inventory.csv) to look up names,
units, inputs, and how each feature is produced. Names in angle brackets are
patterns, not literal output columns. For example, `T2M_EWMA_14` is a 14-day
exponentially weighted average of daily mean air temperature, in °C.

| Group | Where it is generated | How to read it |
|---|---|---|
| Weather and soil | `UFEED(modules = c("weather", "soil"))` | Daily weather uses the selected provider or supplied data. Soil values are site-level gridded estimates by property and depth; they are repeated on the daily grid. |
| Core thermal, rolling, and seasonal features | `UFEED(modules = "weather")` | The source variable, base temperature, window length, and summary type appear in the name. `_y2d` is cumulative within a growth season; `_dormant2d` is cumulative within the dormant season. Rolling windows need sufficient earlier data. |
| Daily reference processes | `UFEED(modules = "derived")` | Day length, Hargreaves reference ET, rain minus reference ET, frost/heat severity, and trailing water balance. These do not represent simulated biomass or measured crop water use. |
| Atmospheric physics and reference canopy | Feature expansion helpers | The [atmospheric dictionary](inst/feature-expansion/UFEED_feature_expansion_1/FEATURE_DICTIONARY.csv) defines VPD, radiation, and FAO-56 reference ET. The [reference canopy dictionary](inst/feature-expansion/UFEED_feature_expansion_2/FEATURE_DICTIONARY.csv) defines scenario-based light interception, development, growth and stress. These helpers take explicit units and, for canopy processes, declared reference parameters. |
| Root-zone water balance | `UFEED_reference_water_balance()` | Soil storage, drainage, modeled actual ET, and unmet demand describe a specified reference soil scenario. They are not satellite ET or field measurements. |
| Period precipitation indices | `UFEED_precipitation_indices()` | Each row summarizes an explicit interval. Bordeaux's combined file prefixes these columns with `period_`. Do not use the full-period summaries to predict dates within that period. R95p needs a prior baseline; sunshine- and crop-ET-based indices need their corresponding inputs. |
| Crop-engine outputs | Configured APSIM, DSSAT, or STICS runner | `apsim_`, `dssat_`, and `stics_` identify the source engine. Output names and units depend on the configured report; dates without a simulation result are missing, not zero. These outputs are not added automatically by the `derived` switch. |
| Satellite | `UFEED(modules = "satellite")` | MODIS LAI/FPAR, NDVI/EVI, and retrospective actual ET. Each feature carries its composite date, age, and source. |

## Satellite source and coverage

UFEED uses a valid **point** retrieval when available. If none qualifies
within the lookback window, it tries the median of quality-screened pixels in
a square around the requested coordinate. The default square extends 3 km
each way. It never changes the output coordinates. Set
`satellite_half_width_km = 0` for point-only extraction.

- `*_source` is `point`, `neighborhood_median`, or `unavailable`.
- `*_valid_pixels` counts the pixels used; `*_half_width_km` records the selected square's half-width.
- `*_quality` applies to a single point only. A spatial median has no single native quality code.
- `*_composite_end` and `*_age_days` describe the underlying composite. Repeating a value on several rows does not make it a daily measurement.
- `most_recent_ET_mm_composite` is an **8-day accumulated amount** (shorter at year-end), not mm/day or reference ET. The gap-filled version is retrospective only.

The same algorithm runs for any supported land coordinate, but valid
coverage is not guaranteed. Water, mixed land cover, clouds, or the absence
of a suitable composite can leave missing values. Prediction-ready mode
also enforces the first-seen cache date; a retrospective archive download
does not establish past availability.

## Bordeaux wheat example engine fields

| Field | Interpretation |
|---|---|
| `dssat_lai`, `dssat_shoot_kg_ha`, `dssat_grain_kg_ha` | DSSAT leaf area index, shoot dry mass, and grain dry mass. LAI is m²/m²; mass is kg/ha. |
| `apsim_Wheat.AboveGround.N`, `apsim_Wheat.Grain.Total.N` | Nitrogen in aboveground biomass and grain, respectively. |
| `apsim_Wheat.AboveGround.Wt`, `apsim_Wheat.Total.Wt`, `apsim_Wheat.Grain.Total.Wt`, `apsim_Yield` | Model report values for aboveground mass, whole-plant mass, grain mass, and yield. Use the template's report definitions; do not assume all four use the same units. |
| `apsim_Wheat.Grain.Number`, `apsim_Wheat.Grain.Size`, `apsim_Wheat.Grain.Protein` | Simulated grain number, grain size, and grain protein as exported by the wheat report. |
| `apsim_Wheat.LAI`, `apsim_Wheat.Phenology.Zadok.Stage` | Simulated canopy LAI and Zadoks development code. |
| `stics_azomes`, `stics_mafruit`, `stics_masecnp`, `stics_resmes` | Soil nitrate-N integrated to the measurement depth, harvested-organ biomass, aerial/nonperennial biomass, and soil water integrated to the measurement depth, respectively. |
| `stics_HR_<layer>`, `stics_AZnit_<layer>` | STICS native soil water and nitrate outputs by model layer. Layers are not the same thing as the fixed-depth SoilGrids columns. |
| `<engine>_daily_output_available` | Whether the scenario returned at least one numeric result for this engine and date. |

### Daily crop processes

Pass an existing `crop_model = list(crop = ..., runners = ...)` or
`crop_model = list(crop = ..., croptimizr = ...)` configuration directly to
`UFEED()`. It joins numeric engine reports by date and site and records
`crop_model_status`. The engines and scenario templates must be configured;
the `derived` module by itself does not run a crop engine.

- **APSIM Wheat:** reports leaf dry-matter fixation supply, leaf and root
  allocation, transpiration, layer water uptake, signed native N uptake, soil
  evaporation, drainage and runoff. Total root water uptake sums the reported
  layers without replacing missing layer values with zero.
- **DSSAT CERES-Wheat:** reads water fluxes from `ET.OUT`, stress factors from
  `PlantGrf.OUT`, and nitrogen and soil counters from `PlantN.OUT` and
  `SoilWat.OUT`. Daily N uptake and drainage are calculated from adjacent
  cumulative values. The first day, gaps, and counter resets stay missing.
- **STICS Wheat:** requests daily growth and senescence, biomass remobilization,
  transpiration, evaporation, ET, drainage and the native stress factors.
  The STICS growth term is biomass accumulation, not gross photosynthesis.

These features are engine-specific simulated rates and fluxes. APSIM's
dry-matter fixation supply is not gross carbon assimilation. DSSAT's
photosynthesis factors are modifiers, not assimilation rates.

For a configured APSIM Wheat template, pass report expressions such as
`[Wheat].Leaf.DMSupplyPhotosynthesis as dm_fixation_supply_g_m2_day`,
`[Wheat].Leaf.Allocated.Wt as leaf_dm_allocation_g_m2_day`, and
`[Wheat].Root.Allocated.Wt as root_dm_allocation_g_m2_day` to
`UFEED_apsim_runner(..., report_variables = ...)`. The Bordeaux config also
reported `[Wheat].Leaf.Transpiration`, `[Wheat].WaterUptake` by layer,
`[Wheat].Root.NUptake`, and `[SoilWater].Es`, `Drainage`, and `Runoff`.

The DSSAT example parses the daily files from one run with the internal
`UFEED:::ufeed_dssat_wheat_processes(run_directory)` and joins them to the
plant report by date. For STICS, the tested additions to the case's
`var.mod` were `dltams(n)`, `dltamsen`, `ep`, `esol`, `et`, `drain`,
`remobilj`, `swfac`, `turfac`, `inns`, `innlai`, and `dltaisen`.
The local engines, configured scenarios, and Bordeaux exports are not
bundled with the package.
