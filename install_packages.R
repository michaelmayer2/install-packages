#!/usr/bin/env Rscript
#
# Install R packages (with pinned versions) from a CSV manifest into R's
# site-library, using pak.
#
# Usage:
#   Rscript install_packages.R --csv <path> [--packages] [--sysdeps] [--site-library <path>] [--snapshot <date>]
#
#   (no flags)                 -> install packages + dependencies + system deps
#   --packages                 -> same as above
#   --packages --sysdeps       -> same as above
#   --sysdeps (without --packages) -> only compute/run system dependency
#                                      installation, do not install R packages
#   --site-library <path>      -> install into <path> instead of R's default
#                                  site-library, and register <path> in
#                                  Rprofile.site so future R sessions pick it
#                                  up via .libPaths()
#   --snapshot <date>          -> pin the Posit Package Manager (PPM) CRAN/
#                                  Bioconductor snapshot to <date> (YYYY-MM-DD)
#                                  instead of the rolling "latest"
#
# CSV format: columns "package" and "version" (every package must have a
# pinned version).

usage <- function() {
  cat("Usage: Rscript install_packages.R --csv <path> [--packages] [--sysdeps] [--site-library <path>] [--snapshot <date>]\n", file = stderr())
}

die <- function(msg, status = 1) {
  cat(paste0("Error: ", msg, "\n"), file = stderr())
  quit(save = "no", status = status)
}

## ---- 1. CLI parsing --------------------------------------------------

args <- commandArgs(trailingOnly = TRUE)

opt_csv <- NULL
opt_packages <- FALSE
opt_sysdeps <- FALSE
opt_site_library <- NULL
opt_snapshot <- "latest"
unknown <- character(0)

i <- 1
while (i <= length(args)) {
  a <- args[[i]]
  if (a == "--csv") {
    if (i == length(args)) die("--csv requires a path argument")
    opt_csv <- args[[i + 1]]
    i <- i + 2
  } else if (a == "--packages") {
    opt_packages <- TRUE
    i <- i + 1
  } else if (a == "--sysdeps") {
    opt_sysdeps <- TRUE
    i <- i + 1
  } else if (a == "--site-library") {
    if (i == length(args)) die("--site-library requires a path argument")
    opt_site_library <- args[[i + 1]]
    i <- i + 2
  } else if (a == "--snapshot") {
    if (i == length(args)) die("--snapshot requires a date argument (YYYY-MM-DD)")
    opt_snapshot <- args[[i + 1]]
    i <- i + 2
  } else {
    unknown <- c(unknown, a)
    i <- i + 1
  }
}

if (length(unknown) > 0) {
  usage()
  die(paste("unrecognized argument(s):", paste(unknown, collapse = ", ")))
}
if (is.null(opt_csv)) {
  usage()
  die("--csv <path> is required")
}
if (!file.exists(opt_csv)) {
  die(sprintf("CSV file not found: %s", opt_csv))
}

mode <- if (opt_sysdeps && !opt_packages) "sysdeps_only" else "full"

## ---- 2. R.home() / site-library check ---------------------------------

# Replaces the marked block identified by marker_id in rprofile_site (if
# present) with body_lines, otherwise appends it. Distinct marker_ids persist
# as independent blocks; reusing the same marker_id updates that block in
# place instead of duplicating or going stale.
write_rprofile_block <- function(rprofile_site, marker_id, body_lines) {
  begin <- sprintf("# --- BEGIN install_packages.R: %s ---", marker_id)
  end <- sprintf("# --- END install_packages.R: %s ---", marker_id)
  existing <- if (file.exists(rprofile_site)) readLines(rprofile_site, warn = FALSE) else character(0)
  begin_idx <- which(existing == begin)
  end_idx <- which(existing == end)
  if (length(begin_idx) == 1 && length(end_idx) == 1 && end_idx > begin_idx) {
    existing <- existing[-(begin_idx:end_idx)]
  }
  writeLines(c(existing, begin, body_lines, end, ""), rprofile_site)
}

site_lib <- if (!is.null(opt_site_library)) opt_site_library else file.path(R.home(), "site-library")
if (!dir.exists(site_lib)) {
  die(sprintf("site-library not found at %s - cannot continue.", site_lib))
}

rprofile_site <- file.path(R.home(), "etc", "Rprofile.site")

if (!is.null(opt_site_library)) {
  # Register the custom location in Rprofile.site so future R sessions on
  # this installation pick it up via .libPaths() automatically.
  write_rprofile_block(
    rprofile_site, site_lib,
    sprintf(".libPaths(c(.libPaths(), %s))", deparse(site_lib))
  )
}

## ---- 2b. Configure Posit Package Manager (PPM) as the CRAN/Bioconductor source ----

# Detects the PPM "__linux__/<segment>" binary path segment for the running
# distro (e.g. "rhel10", "centos7", "noble"), or NULL if undetected (source
# packages only, no binaries).
detect_ppm_binary_segment <- function() {
  if (file.exists("/etc/redhat-release")) {
    version <- strsplit(
      system(". /etc/os-release && echo $VERSION_ID", intern = TRUE),
      "[.]"
    )[[1]][1]
    os <- if (version %in% c("9", "10")) "rhel" else "centos"
    return(paste0(os, version))
  }
  if (file.exists("/etc/debian_version")) {
    return(system(". /etc/os-release && echo $VERSION_CODENAME", intern = TRUE))
  }
  NULL
}

binary_segment <- detect_ppm_binary_segment()
binary_path <- if (!is.null(binary_segment)) sprintf("__linux__/%s/", binary_segment) else ""

ppm_base <- "https://p3m.dev"
cran_repo <- sprintf("%s/cran/%s%s", ppm_base, binary_path, opt_snapshot)
bioc_mirror <- sprintf("%s/bioconductor/%s%s", ppm_base, binary_path, opt_snapshot)
bioc_config <- sprintf("%s/bioconductor/%s/config.yaml", ppm_base, opt_snapshot)

write_rprofile_block(
  rprofile_site,
  "Posit Package Manager configuration",
  c(
    "# Configure R/pak to use Posit Package Manager for CRAN binaries",
    sprintf("options(repos = c(CRAN = %s))", deparse(cran_repo)),
    "",
    "# Configure BiocManager to use Posit Package Manager",
    sprintf("options(BioC_mirror = %s)", deparse(bioc_mirror)),
    "",
    "# Configure BiocManager to load its configuration from Package Manager",
    sprintf("options(BIOCONDUCTOR_CONFIG_FILE = %s)", deparse(bioc_config))
  )
)

# Also apply to this already-running process (Rprofile.site only affects
# future sessions, not the currently-running interpreter).
options(repos = c(CRAN = cran_repo), BioC_mirror = bioc_mirror, BIOCONDUCTOR_CONFIG_FILE = bioc_config)

## ---- 3. Install & load pak into a custom /tmp library -----------------

pak_lib <- "/tmp/pak-lib"
if (!dir.exists(pak_lib)) dir.create(pak_lib, recursive = TRUE)

if (!requireNamespace("pak", lib.loc = pak_lib, quietly = TRUE)) {
  install.packages(
    "pak",
    lib = pak_lib,
    repos = sprintf(
      "https://r-lib.github.io/p/pak/stable/%s/%s/%s",
      .Platform$pkgType, R.Version()$os, R.Version()$arch
    )
  )
}

# pak spawns a background subprocess that must resolve its own namespace via
# .libPaths(), so it's not enough to just library(pak, lib.loc = pak_lib).
.libPaths(c(pak_lib, .libPaths()))
library(pak)

## ---- 4. Read & validate the CSV ---------------------------------------

csv <- read.csv(opt_csv, stringsAsFactors = FALSE, colClasses = "character")

required_cols <- c("package", "version")
missing_cols <- setdiff(required_cols, names(csv))
if (length(missing_cols) > 0) {
  die(sprintf("CSV is missing required column(s): %s", paste(missing_cols, collapse = ", ")))
}

pkg_name <- trimws(csv$package)
pkg_version <- trimws(csv$version)

if (any(is.na(pkg_name) | pkg_name == "")) {
  die("CSV contains row(s) with an empty package name")
}

missing_version <- pkg_name[is.na(pkg_version) | pkg_version == ""]
if (length(missing_version) > 0) {
  die(sprintf("The following package(s) are missing a pinned version: %s",
              paste(unique(missing_version), collapse = ", ")))
}

refs <- sprintf("%s@%s", pkg_name, pkg_version)

## ---- 5. Install packages and/or system dependencies --------------------

if (mode == "full") {
  # As root on a supported Linux distro, pak::pkg_install() automatically
  # installs matching system dependencies as a side effect - no separate
  # sysreqs call needed.
  pak::pkg_install(pkg = refs, lib = site_lib, ask = FALSE)
} else {
  # --sysdeps only: compute the system requirement commands and run them
  # ourselves, without installing any R packages. pkg_sysreqs() is query-only.
  if (!isTRUE(pak::sysreqs_is_supported())) {
    die("System-requirements installation is not supported on this platform.")
  }

  sysreqs <- pak::pkg_sysreqs(refs)
  commands <- c(sysreqs$pre_install, sysreqs$install_scripts, sysreqs$post_install)

  if (length(commands) == 0) {
    cat("No system requirements needed for the given packages.\n")
  } else {
    for (cmd in commands) {
      cat(sprintf("Executing: %s\n", cmd))
      status <- system(cmd)
      if (status != 0) {
        die(sprintf("System requirement command failed (exit %d): %s", status, cmd))
      }
    }
  }
}

cat("Done.\n")
