UFEED_setup_crop_models <- function(install_r = FALSE, engine_paths = NULL) {
  engines <- c("apsim", "dssat", "stics")
  if (!is.logical(install_r) || length(install_r) != 1L || is.na(install_r)) {
    stop("install_r must be TRUE or FALSE.", call. = FALSE)
  }
  if (!is.null(engine_paths) && (!is.character(engine_paths) ||
      is.null(names(engine_paths)) || anyDuplicated(names(engine_paths)) ||
      !all(names(engine_paths) %in% engines) || anyNA(engine_paths))) {
    stop("engine_paths must be a named character vector with apsim, dssat or stics entries.",
         call. = FALSE)
  }
  packages <- c("CroptimizR", "SticsOnR", "SticsRFiles")
  available <- function() vapply(packages, requireNamespace, logical(1), quietly = TRUE)
  installed <- available()
  if (install_r && any(!installed)) {
    utils::install.packages(
      names(installed)[!installed],
      repos = c("https://sticsrpacks.r-universe.dev", "https://cloud.r-project.org")
    )
    installed <- available()
  }

  windows <- .Platform$OS.type == "windows"
  programs <- Sys.getenv(c("ProgramFiles", "ProgramFiles(x86)"), unset = "")
  programs <- unique(programs[nzchar(programs)])
  apsim_dirs <- unlist(lapply(programs, function(p) Sys.glob(file.path(p, "APSIM*"))))
  dssat_drive <- Sys.getenv("SystemDrive", unset = "C:")
  dssat_dirs <- Sys.glob(paste0(dssat_drive, "/DSSAT*"))
  stics_dirs <- unlist(lapply(programs, function(p) Sys.glob(file.path(p, "JavaSTICS*"))))
  candidates <- list(
    apsim = c(Sys.which(c("Models.exe", "Models")), file.path(apsim_dirs, "bin", "Models.exe")),
    dssat = c(Sys.which(c("dscsm048.exe", "dscsm048")), file.path(dssat_dirs, "dscsm048.exe")),
    stics = c(Sys.which(c("stics_modulo.exe", "stics_modulo", "stics_modulo_mac")),
              file.path(stics_dirs, "bin", "stics_modulo.exe"))
  )
  env <- c(apsim = "UFEED_APSIM_EXE", dssat = "UFEED_DSSAT_EXE", stics = "UFEED_STICS_EXE")
  path <- vapply(engines, function(engine) {
    explicit <- if (engine %in% names(engine_paths)) engine_paths[[engine]] else Sys.getenv(env[[engine]])
    choices <- if (nzchar(explicit)) {
      explicit
    } else if (windows) {
      candidates[[engine]]
    } else {
      unname(Sys.which(switch(engine, apsim = "Models", dssat = "dscsm048",
                               stics = c("stics_modulo", "stics_modulo_mac"))))
    }
    choices <- choices[nzchar(choices)]
    info <- file.info(choices)
    existing <- choices[!is.na(info$isdir) & !info$isdir]
    if (!length(existing)) return(NA_character_)
    normalizePath(existing[1], winslash = "/")
  }, character(1), USE.NAMES = FALSE)
  list(
    r_packages = data.frame(package = packages, available = unname(installed)),
    engines = data.frame(
      engine = engines, executable = path, detected = !is.na(path),
      path_variable = unname(env),
      download = c("https://www.apsim.info/download-apsim/downloads/",
                   "https://dssat.net/main-download/",
                   "https://stics.inrae.fr/eng/download")
    )
  )
}
