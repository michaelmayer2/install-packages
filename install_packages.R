#!/usr/bin/env Rscript
#
# Install R packages (with pinned versions) from a CSV manifest into R's
# site-library, using pak.
#
# Usage:
#   Rscript install_packages.R (--csv <path> | --lockfile <path>) [--packages] [--sysdeps]
#                              [--site-library <path>] [--site-library-first] [--no-register]
#                              [--snapshot <date>] [--ppm-url <url>] [--cran-repo <name>]
#                              [--source] [--pin-pak] [--lockfile-create <path>]
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
#   --site-library-first       -> register <path> at the front of .libPaths()
#                                  (before the user and default libraries)
#   --no-register              -> do not register --site-library in
#                                  Rprofile.site (e.g. for a library that is
#                                  only activated on demand)
#   --snapshot <date>          -> pin the Posit Package Manager (PPM) CRAN/
#                                  Bioconductor snapshot to <date> (YYYY-MM-DD)
#                                  instead of the rolling "latest"
#   --ppm-url <url>            -> PPM server to use (default https://p3m.dev)
#   --cran-repo <name>         -> CRAN-type repository on that server
#                                  (default "cran"; e.g. a curated repo name)
#   --source                   -> install R packages from source, never binaries
#   --pin-pak                  -> install pak itself from the dated snapshot,
#                                  so the installer's version is pinned too
#   --lockfile-create <path>   -> resolve the CSV and write a pak lockfile to
#                                  <path>; nothing is installed
#   --lockfile <path>          -> install (or, with --sysdeps alone, install the
#                                  system dependencies of) exactly the packages
#                                  in a pak lockfile, instead of a CSV
#
# CSV format: columns "package" and "version" (every package must have a
# pinned version).

usage <- function() {
  cat(paste(
    "Usage: Rscript install_packages.R (--csv <path> | --lockfile <path>) [--packages] [--sysdeps]",
    "         [--site-library <path>] [--site-library-first] [--no-register] [--snapshot <date>] [--ppm-url <url>]",
    "         [--cran-repo <name>] [--source] [--pin-pak] [--lockfile-create <path>]\n",
    sep = "\n"
  ), file = stderr())
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
opt_site_library_first <- FALSE
opt_no_register <- FALSE
opt_snapshot <- "latest"
opt_ppm_url <- "https://p3m.dev"
opt_cran_repo <- "cran"
opt_source <- FALSE
opt_pin_pak <- FALSE
opt_lockfile_create <- NULL
opt_lockfile <- NULL
unknown <- character(0)

# Flags that take a value, and the variable each one sets
value_flags <- c(
  "--csv" = "opt_csv", "--site-library" = "opt_site_library", "--snapshot" = "opt_snapshot",
  "--ppm-url" = "opt_ppm_url", "--cran-repo" = "opt_cran_repo",
  "--lockfile-create" = "opt_lockfile_create", "--lockfile" = "opt_lockfile"
)

i <- 1
while (i <= length(args)) {
  a <- args[[i]]
  if (a %in% names(value_flags)) {
    if (i == length(args)) die(sprintf("%s requires an argument", a))
    assign(value_flags[[a]], args[[i + 1]])
    i <- i + 2
  } else if (a == "--packages") {
    opt_packages <- TRUE
    i <- i + 1
  } else if (a == "--sysdeps") {
    opt_sysdeps <- TRUE
    i <- i + 1
  } else if (a == "--site-library-first") {
    opt_site_library_first <- TRUE
    i <- i + 1
  } else if (a == "--no-register") {
    opt_no_register <- TRUE
    i <- i + 1
  } else if (a == "--source") {
    opt_source <- TRUE
    i <- i + 1
  } else if (a == "--pin-pak") {
    opt_pin_pak <- TRUE
    i <- i + 1
  } else {
    unknown <- c(unknown, a)
    i <- i + 1
  }
}

if (length(unknown) > 0) {
  usage()
  die(paste("unrecognized argument(s):", paste(unknown, collapse = ", ")))
}
if (!is.null(opt_lockfile) && !is.null(opt_csv)) {
  die("--csv and --lockfile are mutually exclusive (the lockfile already pins every package)")
}
if (!is.null(opt_lockfile) && !is.null(opt_lockfile_create)) {
  die("--lockfile and --lockfile-create are mutually exclusive")
}
if (is.null(opt_csv) && is.null(opt_lockfile)) {
  usage()
  die("--csv <path> (or --lockfile <path>) is required")
}
if (!is.null(opt_csv) && !file.exists(opt_csv)) {
  die(sprintf("CSV file not found: %s", opt_csv))
}
if (!is.null(opt_lockfile) && !file.exists(opt_lockfile)) {
  die(sprintf("Lockfile not found: %s", opt_lockfile))
}
if (opt_snapshot != "latest" && !grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", opt_snapshot)) {
  die(sprintf("--snapshot must be 'latest' or a date (YYYY-MM-DD), got: %s", opt_snapshot))
}
# A lockfile or a pinned pak resolved against the rolling "latest" snapshot would not be
# reproducible, which defeats their purpose.
if (opt_snapshot == "latest" && !is.null(opt_lockfile_create)) {
  die("--lockfile-create requires a dated --snapshot (YYYY-MM-DD), not 'latest'")
}
if (opt_no_register && opt_site_library_first) {
  die("--site-library-first has no effect together with --no-register")
}
if (opt_snapshot == "latest" && opt_pin_pak) {
  die("--pin-pak requires a dated --snapshot (YYYY-MM-DD), not 'latest'")
}

mode <- if (!is.null(opt_lockfile_create)) {
  "lockfile_create"
} else if (opt_sysdeps && !opt_packages) {
  "sysdeps_only"
} else {
  "full"
}

# Creating a lockfile is a planning step: it must not modify this R installation.
modify_installation <- mode != "lockfile_create"

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
register <- modify_installation && !is.null(opt_site_library) && !opt_no_register
# The library must exist where packages are installed into it, or where it is
# registered; a --sysdeps-only run that registers nothing does not need it.
if ((mode == "full" || register) && !dir.exists(site_lib)) {
  die(sprintf("site-library not found at %s - cannot continue.", site_lib))
}

rprofile_site <- file.path(R.home(), "etc", "Rprofile.site")

if (register) {
  # Register the custom location in Rprofile.site so future R sessions on
  # this installation pick it up via .libPaths() automatically. The marker is
  # the path, so switching between first/last for the same path updates the
  # block in place.
  lib_paths_expr <- if (opt_site_library_first) {
    sprintf(".libPaths(c(%s, .libPaths()))", deparse(site_lib))
  } else {
    sprintf(".libPaths(c(.libPaths(), %s))", deparse(site_lib))
  }
  write_rprofile_block(rprofile_site, site_lib, lib_paths_expr)
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

ppm_base <- sub("/+$", "", opt_ppm_url)
# With --source, packages come only from the snapshot's (immutable) source
# tarballs: no binary segment in the repository URL.
package_path <- if (opt_source) "" else binary_path
cran_repo <- sprintf("%s/%s/%s%s", ppm_base, opt_cran_repo, package_path, opt_snapshot)
bioc_mirror <- sprintf("%s/bioconductor/%s%s", ppm_base, package_path, opt_snapshot)
bioc_config <- sprintf("%s/bioconductor/%s/config.yaml", ppm_base, opt_snapshot)

if (modify_installation) {
  write_rprofile_block(
    rprofile_site,
    "Posit Package Manager configuration",
    c(
      "# Configure R/pak to use Posit Package Manager for CRAN packages",
      sprintf("options(repos = c(CRAN = %s))", deparse(cran_repo)),
      "",
      "# Configure BiocManager to use Posit Package Manager",
      sprintf("options(BioC_mirror = %s)", deparse(bioc_mirror)),
      "",
      "# Configure BiocManager to load its configuration from Package Manager",
      sprintf("options(BIOCONDUCTOR_CONFIG_FILE = %s)", deparse(bioc_config))
    )
  )
}

# Also apply to this already-running process (Rprofile.site only affects
# future sessions, not the currently-running interpreter).
options(repos = c(CRAN = cran_repo), BioC_mirror = bioc_mirror, BIOCONDUCTOR_CONFIG_FILE = bioc_config)

# pak's resolution and installation run in a background subprocess, which
# inherits environment variables, so set the platform restriction there.
if (opt_source) Sys.setenv(PKG_PLATFORMS = "source")

## ---- 3. Install & load pak into a custom /tmp library -----------------

# pak is the installer, not part of the installed library, so a binary is fine
# for pak itself even with --source.
if (opt_pin_pak) {
  # pak's version is then whatever was current on CRAN at the snapshot date
  pak_lib <- file.path("/tmp", paste0("pak-lib-", opt_snapshot))
  pak_repo <- sprintf("%s/%s/%s%s", ppm_base, opt_cran_repo, binary_path, opt_snapshot)
} else {
  pak_lib <- "/tmp/pak-lib"
  pak_repo <- sprintf(
    "https://r-lib.github.io/p/pak/stable/%s/%s/%s",
    .Platform$pkgType, R.Version()$os, R.Version()$arch
  )
}
if (!dir.exists(pak_lib)) dir.create(pak_lib, recursive = TRUE)

if (!requireNamespace("pak", lib.loc = pak_lib, quietly = TRUE)) {
  install.packages("pak", lib = pak_lib, repos = pak_repo)
}

# pak spawns a background subprocess that must resolve its own namespace via
# .libPaths(), so it's not enough to just library(pak, lib.loc = pak_lib).
.libPaths(c(pak_lib, .libPaths()))
library(pak)
cat(sprintf("Using pak %s from %s\n", packageVersion("pak"), pak_lib))

# The lockfile modes read the lockfile (JSON) themselves. jsonlite is not part
# of base R, so install it next to pak: a tool, kept out of the site-library.
if ((!is.null(opt_lockfile) || !is.null(opt_lockfile_create)) &&
    !requireNamespace("jsonlite", lib.loc = pak_lib, quietly = TRUE)) {
  install.packages("jsonlite", lib = pak_lib,
                   repos = sprintf("%s/%s/%s%s", ppm_base, opt_cran_repo, binary_path, opt_snapshot))
}

## ---- 4. Read & validate the CSV ---------------------------------------

refs <- NULL
if (!is.null(opt_csv)) {
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
}

## ---- 5. Install packages and/or system dependencies --------------------

# Runs system-requirement commands one by one, stopping at the first failure.
# system(), not system2("sh", c("-c", cmd)): system2 does not shell-quote its
# args, so the inner sh -c would only see the first word of each command.
run_sysreq_commands <- function(commands) {
  if (length(commands) == 0) {
    cat("No system requirements needed for the given packages.\n")
    return(invisible())
  }
  for (cmd in commands) {
    cat(sprintf("Executing: %s\n", cmd))
    status <- system(cmd)
    if (status != 0) {
      die(sprintf("System requirement command failed (exit %d): %s", status, cmd))
    }
  }
}

if (mode == "lockfile_create") {
  # An explicit "pkg@version" makes pak take the package from the CRAN
  # archive, even when that version is the current one in the snapshot, and
  # archive entries carry no checksum. So resolve pins that match the
  # snapshot's current version by name (regular index: URL + SHA-256), and
  # verify afterwards that every pin ended up in the lockfile as written.
  current <- available.packages(repos = cran_repo, type = "source")[, "Version"]
  cur <- unname(current[pkg_name])
  is_current <- !is.na(cur) & cur == pkg_version
  resolve_refs <- ifelse(is_current, pkg_name, refs)

  # Resolve from scratch (an empty library), so the lockfile lists every
  # dependency, independent of what happens to be installed here.
  pak::lockfile_create(pkg = resolve_refs, lockfile = opt_lockfile_create, lib = tempfile("empty-lib-"))
  lock <- jsonlite::fromJSON(opt_lockfile_create, simplifyVector = FALSE)

  locked <- setNames(vapply(lock$packages, function(p) p$version, ""),
                     vapply(lock$packages, function(p) p$package, ""))
  lv <- unname(locked[pkg_name])
  mismatch <- pkg_name[is.na(lv) | lv != pkg_version]
  if (length(mismatch) > 0) {
    die(sprintf("The lockfile does not contain the pinned version of: %s",
                paste(sprintf("%s (pinned %s, locked %s)", mismatch,
                              pkg_version[match(mismatch, pkg_name)], locked[mismatch]),
                      collapse = ", ")))
  }

  no_sha <- vapply(lock$packages, function(p) is.null(p$sha256) || identical(p$sha256, ""), logical(1))
  cat(sprintf("Wrote %s: %d packages, resolved against %s\n",
              opt_lockfile_create, length(lock$packages), cran_repo))
  if (any(no_sha)) {
    cat(sprintf(
      "Note: no SHA-256 checksum recorded for %s (pinned to a version older than the snapshot's current one, so it comes from the CRAN archive, which has no checksums).\n",
      paste(vapply(lock$packages[no_sha], function(p) paste0(p$package, "@", p$version), ""), collapse = ", ")
    ))
  }
} else if (mode == "full") {
  if (!is.null(opt_lockfile)) {
    # Installs exactly the packages, versions and URLs recorded in the lockfile.
    # As root, pak also installs the recorded system requirements.
    pak::lockfile_install(lockfile = opt_lockfile, lib = site_lib)
  } else {
    # As root on a supported Linux distro, pak::pkg_install() automatically
    # installs matching system dependencies as a side effect - no separate
    # sysreqs call needed.
    pak::pkg_install(pkg = refs, lib = site_lib, ask = FALSE)

    # pak does not always honour a pin: e.g. for a Bioconductor version that is
    # not available for this R version it silently installs another one. Report
    # any difference loudly (a warning, not an error, to keep existing builds
    # working; --lockfile-create treats it as an error).
    installed <- vapply(pkg_name, function(p) {
      v <- tryCatch(as.character(packageVersion(p, lib.loc = site_lib)), error = function(e) NA_character_)
      v
    }, character(1))
    # packageVersion() normalises "0.7-8" to "0.7.8", so compare as versions
    differs <- is.na(installed) | mapply(function(a, b) {
      !is.na(a) && package_version(a) != package_version(b)
    }, installed, pkg_version)
    if (any(differs)) {
      cat(sprintf(
        "WARNING: installed version differs from the pinned version for: %s\n",
        paste(sprintf("%s (pinned %s, installed %s)", pkg_name[differs], pkg_version[differs],
                      ifelse(is.na(installed[differs]), "none", installed[differs])), collapse = ", ")
      ), file = stderr())
    }
  }
  # pak leaves its (empty) install lock files in <lib>/_cache. Remove them, so
  # the library contains only installed packages.
  pak_cache <- file.path(site_lib, "_cache")
  if (dir.exists(pak_cache)) unlink(pak_cache, recursive = TRUE)
} else {
  # --sysdeps only: run the system requirement commands ourselves, without
  # installing any R packages.
  if (!is.null(opt_lockfile)) {
    # Use the commands recorded in the lockfile, so every node gets exactly the
    # same system dependencies as the node that installed the packages.
    lock <- jsonlite::fromJSON(opt_lockfile, simplifyVector = FALSE)
    sr <- lock$sysreqs
    if (is.null(sr)) {
      die("The lockfile records no system requirements (was it created on a platform pak supports for sysreqs?)")
    }
    run_sysreq_commands(unlist(c(sr$pre_install, sr$install_scripts, sr$post_install)))
  } else {
    if (!isTRUE(pak::sysreqs_is_supported())) {
      die("System-requirements installation is not supported on this platform.")
    }
    sysreqs <- pak::pkg_sysreqs(refs)
    run_sysreq_commands(c(sysreqs$pre_install, sysreqs$install_scripts, sysreqs$post_install))
  }
}

cat("Done.\n")
