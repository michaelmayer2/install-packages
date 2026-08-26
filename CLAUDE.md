# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single-script R package installer, `install_packages.R`, plus a `Dockerfile` that exercises it
on Rocky Linux 10. It uses `pak` to install a pinned list of R packages (from a CSV manifest) into
R's `site-library`, optionally installing system dependencies, and configures Posit Package
Manager (PPM) as the binary package source. `req.txt` is the original informal spec this was built
from — read it for the "why" behind the CLI shape if a requirement seems arbitrary.

There is no package/build system here (no `DESCRIPTION`, no tests directory, no Makefile) — this
is a standalone ops script, verified by hand against a real Docker build each time it changes.

## Commands

- **Syntax-check the script** (fast, no Docker needed): `Rscript -e "invisible(parse('install_packages.R'))"`
- **Build the test image**: `docker build -t alnylam-test .`
- **Run/inspect a specific code path** without re-running the Dockerfile's baked-in install:
  `docker run --rm alnylam-test sh -c "/opt/R/4.6.1/bin/Rscript /tmp/install_packages.R --csv /tmp/packages.csv --sysdeps --site-library /opt/site-library"`
  (swap flags to hit the branch you're changing; `--site-library`/`--snapshot` writes are visible
  at `/opt/R/4.6.1/lib/R/etc/Rprofile.site` inside the container — note `R.home()` on this image is
  `/opt/R/4.6.1/lib/R`, not `/opt/R/4.6.1`).
- Always test with `docker build --no-cache` when validating a behavior change — Docker layer
  caching will otherwise silently reuse a stale `RUN` result and hide the bug (this has bitten us
  before: a broken command still showed `DONE` because the cached layer replayed an old, valid run).
- Clean up test images after verifying: `docker rmi alnylam-test`.

There's no automated test suite; verification is: syntax-check, then a real (`--no-cache`) Docker
build/run exercising the changed branch, checking actual stdout/exit codes/file contents rather
than assuming success from a clean build.

## Architecture

`install_packages.R` runs top-to-bottom as a single script, in this order:

1. **CLI parsing** — a hand-rolled loop over `commandArgs()` (no argparse package). Flags:
   `--csv <path>` (required), `--packages`, `--sysdeps`, `--site-library <path>`, `--snapshot <date>`.
   Mode resolution: `--sysdeps` present **and** `--packages` absent → `sysdeps_only`; every other
   combination (no flags, `--packages` alone, or both together) → `full`.
2. **`site_lib` resolution** — defaults to `R.home()/site-library`, overridable via `--site-library`.
   Missing directory is a hard error (`die()`), by design — this script never creates it.
3. **`write_rprofile_block()`** — a generic helper that idempotently manages named blocks inside
   `Rprofile.site` (`R.home()/etc/Rprofile.site`), delimited by `# --- BEGIN/END install_packages.R: <marker_id> ---`
   comments. Two call sites use it with different `marker_id` semantics:
   - Site-library registration: `marker_id` = the path itself, so distinct `--site-library` paths
     persist as independent blocks (multiple site libraries can coexist across runs).
   - PPM/Bioconductor config: `marker_id` is a fixed string, so re-running with a different
     `--snapshot` **replaces** the previous block in place instead of duplicating or going stale.
   If you add a new persistent Rprofile.site setting, decide up front which semantics you want and
   pick `marker_id` accordingly — this is the one subtlety in the file that isn't obvious from a
   local read.
4. **PPM/Bioconductor configuration** — builds `https://p3m.dev/cran/__linux__/<segment>/<snapshot>`
   (and the Bioconductor equivalents) and writes it both to `Rprofile.site` (for future R sessions)
   *and* via `options()` in the current process (Rprofile.site only affects new sessions, not this
   one). `<segment>` comes from `detect_ppm_binary_segment()`, which reads `/etc/redhat-release` or
   `/etc/debian_version` to map the running distro to PPM's binary path naming (`rhel10`, `centos7`,
   `noble`, ...); falls back to no binary segment (source only) if undetected. The Bioconductor
   `config.yaml` URL never gets a distro segment — that's a PPM API quirk, not a bug, confirmed
   against PPM's own source.
   Note: a pinned CSV version only installs as a binary if it matches whatever was "current" on
   CRAN at `--snapshot`'s date — pinning an old version against `latest` will legitimately fall
   back to a source build from the CRAN archive. That's expected PPM behavior, not a repo-config bug.
5. **pak bootstrap** — installs `pak` itself into a fixed `/tmp/pak-lib` (separate from `site_lib`,
   never mixed with user packages), then prepends that lib to `.libPaths()` *before* `library(pak)`.
   This prepend is required, not cosmetic: pak spawns a background `callr` subprocess that resolves
   its own namespace via `.libPaths()` at spawn time, so `library(pak, lib.loc=...)` alone isn't
   enough.
6. **CSV validation** — requires `package`/`version` columns, forces `colClasses = "character"`
   (numeric coercion would mangle versions like `"1.0"` → `1`), and hard-errors on any missing
   version — every row must be pinned, there's no "install latest" fallback.
7. **Install branch** — `full` calls `pak::pkg_install()` once (which also installs system
   dependencies automatically when run as root); `sysdeps_only` calls the query-only
   `pak::pkg_sysreqs()` and then executes the returned commands itself via `system(cmd)` (not
   `system2("sh", c("-c", cmd))` — that form silently drops everything after the first word because
   `system2` doesn't shell-quote its `args`, so the "command" arg passed to the *inner* `sh -c`
   ends up being just the first token; this was a real, hard-to-spot bug here once).

The `Dockerfile` is both the deployment target and the de facto test harness: it installs R via
Posit's RPM (`cdn.posit.co/r/rhel-10/...`), then runs `install_packages.R` as the final step.
Changing script behavior generally means rebuilding this image to verify it.