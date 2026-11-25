\name{UFEED_setup_crop_models}
\alias{UFEED_setup_crop_models}
\title{Set up optional crop model tools}
\usage{
UFEED_setup_crop_models(install_r = FALSE, engine_paths = NULL)
}
\arguments{
\item{install_r}{Install missing R wrapper packages from SticsRPacks R-universe
and CRAN when true.}
\item{engine_paths}{Optional named character vector of executable paths.
Names may be \code{apsim}, \code{dssat}, or \code{stics}.}
}
\description{Find installed engines and optionally install the R wrapper
packages. Each missing engine is reported with its official download location.}
\details{Explicit paths override the corresponding environment variables
\code{UFEED_APSIM_EXE}, \code{UFEED_DSSAT_EXE}, and \code{UFEED_STICS_EXE}.
Otherwise the function checks the system path and common Windows locations.
Executable detection does not validate the engine version, example data or
simulation configuration.}
\value{A list with two data frames, \code{r_packages} and \code{engines}.}
