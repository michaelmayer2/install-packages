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

1. **CLI parsing** — a hand-rolled loop over `commandArgs()` (no argparse package). Value flags are
   looked up in the `value_flags` map (flag → variable name); boolean flags have their own branches.
   Flags: `--csv <path>` or `--lockfile <path>` (one is required; they are mutually exclusive),
   `--packages`, `--sysdeps`, `--site-library <path>`, `--site-library-first`, `--snapshot <date>`,
   `--ppm-url <url>`, `--cran-repo <name>`, `--source`, `--pin-pak`, `--lockfile-create <path>`.
   Mode resolution: `--lockfile-create` → `lockfile_create`; else `--sysdeps` present **and**
   `--packages` absent → `sysdeps_only`; every other combination → `full`. `--lockfile-create` and
   `--pin-pak` refuse the rolling `latest` snapshot (a lockfile against `latest` is not reproducible).
   **Backward compatibility is a hard requirement:** with none of the newer flags, the script must
   behave exactly as it did before they were added (binaries, library appended last).
2. **`site_lib` resolution** — defaults to `R.home()/site-library`, overridable via `--site-library`.
   Missing directory is a hard error (`die()`), by design — this script never creates it.
   `lockfile_create` mode is a planning step and must **not** modify the R installation: it skips
   the site-library check and all `Rprofile.site` writes (`modify_installation` is `FALSE`).
   `--no-register` suppresses only the site-library registration (`register` is `FALSE`); the
   library must still exist for a `full` install, but a `--sysdeps`-only run that registers nothing
   no longer requires any site library.
3. **`write_rprofile_block()`** — a generic helper that idempotently manages named blocks inside
   `Rprofile.site` (`R.home()/etc/Rprofile.site`), delimited by `# --- BEGIN/END install_packages.R: <marker_id> ---`
   comments. Two call sites use it with different `marker_id` semantics:
   - Site-library registration: `marker_id` = the path itself, so distinct `--site-library` paths
     persist as independent blocks (multiple site libraries can coexist across runs). With
     `--site-library-first` the block prepends instead of appends; because the marker is still the
     path, switching between the two for the same path updates the block in place.
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
   `--ppm-url`/`--cran-repo` replace the server and repository name. `--source` drops the
   `__linux__/<segment>` part (source tarballs only) and sets `PKG_PLATFORMS=source` via
   `Sys.setenv()` — an environment variable rather than an option, because pak resolves and installs
   in a background subprocess, which inherits the environment.
5. **pak bootstrap** — installs `pak` itself into a fixed `/tmp/pak-lib` (separate from `site_lib`,
   never mixed with user packages), then prepends that lib to `.libPaths()` *before* `library(pak)`.
   With `--pin-pak`, pak comes from the dated snapshot instead (binary channel even with `--source`:
   pak is the tool, not part of the installed library) into a per-snapshot `/tmp/pak-lib-<date>`,
   so a cached pak from another snapshot is never reused. The lockfile modes also need `jsonlite`
   to read the lockfile; it is installed into the same tool library, never into `site_lib`.
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
   ends up being just the first token; this was a real, hard-to-spot bug here once). That logic now
   lives in `run_sysreq_commands()`, shared by both `--sysdeps` paths.
   - With `--lockfile`, `full` calls `pak::lockfile_install()` (as root, it installs the lockfile's
     recorded system requirements too — verified), and `sysdeps_only` runs the commands recorded in
     the lockfile's top-level `sysreqs` entry, so every node gets exactly the build node's list.
   - After a `full` install, `<site_lib>/_cache` is removed: pak leaves empty install lock files there.
   - After a `full` install from a CSV, installed versions are compared with the pins (as
     `package_version`s, because `packageVersion()` normalises `0.7-8` to `0.7.8`) and differences
     are printed as a `WARNING:` on stderr. Deliberately not an error, to keep existing builds
     working: e.g. the example `packages.csv` pins `rhdf5` 2.57.12, a Bioconductor version pak
     silently replaces with 2.56.1 on R 4.6 (the original script did the same).
   - `lockfile_create` subtlety: an explicit `pkg@version` makes pak take the package from the CRAN
     **archive** even when that version is current in the snapshot, and archive entries have no
     SHA-256. So pins that equal the snapshot's current version (from `available.packages()`) are
     resolved by bare name, and the script then verifies every pin is in the lockfile as written.

The `Dockerfile` is both the deployment target and the de facto test harness: it installs R via
Posit's RPM (`cdn.posit.co/r/rhel-10/...`), then runs `install_packages.R` as the final step.
Changing script behavior generally means rebuilding this image to verify it.

For the multi-node workflow (README, "Validated builds on a multi-node setup"), the Dockerfile is not
enough: simulate the nodes with separate `docker run --rm` containers from an R-only image, sharing
a host directory mounted at `/shared`. Check that the build node compiles from source (`[bld][cmp]`
in pak's output) into the shared library, that a second node in `--sysdeps` mode installs no R
packages, and that both see the shared library first in `.libPaths()`. Note that Docker Desktop on
macOS does not share `/tmp` with containers; use a directory under `$HOME` for the shared mount.