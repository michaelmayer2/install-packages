# install_packages.R

A standalone R script that installs a pinned list of R packages (and, optionally, their system
dependencies) from a CSV manifest, using [`pak`](https://pak.r-lib.org/). It configures
[Posit Package Manager](https://p3m.dev) (PPM) as the CRAN/Bioconductor source so installs use
precompiled binaries instead of building from source, whenever a matching binary exists.

## Requirements

- Linux, run as root (needed for automatic system-dependency installation and for writing to
  `Rprofile.site`).
- Network access to `https://p3m.dev` (package/binary downloads) and
  `https://r-lib.github.io` (bootstrapping `pak` itself).
- An R installation whose `site-library` directory already exists (see
  [`--site-library`](#--site-library-path) below if it doesn't, or if you want packages installed
  somewhere else).

## Usage

```sh
Rscript install_packages.R (--csv <path> | --lockfile <path>) [--packages] [--sysdeps]
                           [--site-library <path>] [--site-library-first] [--no-register]
                           [--snapshot <date>] [--ppm-url <url>] [--cran-repo <name>]
                           [--source] [--pin-pak] [--lockfile-create <path>]
```

`--csv <path>` (or `--lockfile <path>`, see [Validated builds](#validated-builds-on-a-multi-node-setup))
is the only required flag. Everything else is optional and defaults to a full install using PPM's
rolling `latest` snapshot into R's default `site-library`, exactly as before the newer flags were
added.

### CSV format

A CSV with `package` and `version` columns (any extra columns are ignored). Every row must have a
non-empty version — there is no "just install latest" fallback; pin the exact version you want.

```csv
package,version
jsonlite,1.8.8
dplyr,1.1.4
```

Package refs are built as `<package>@<version>` and passed straight to `pak`, so any version pak
can resolve (including CRAN archive versions) works.

pak does not always honour a pin. For example, a Bioconductor version that is not available for the
running R version (such as a development-series version) is silently replaced by another one. After
installing, the script therefore compares every installed version with its pin and prints a
`WARNING:` line on stderr for any difference. The exit status is unchanged, so existing builds keep
working; `--lockfile-create` treats such a difference as an error.

### Flags

| Flag | Value | Effect |
|---|---|---|
| `--csv <path>` | required | Path to the package manifest CSV. |
| `--packages` | flag | Install the packages from the CSV. Combined with `--sysdeps` below, or on its own, or with no flags at all — all three produce the same **full install** (packages + their dependencies + system dependencies). |
| `--sysdeps` | flag | On its own (i.e. **without** `--packages`), only computes and runs the system-dependency installation commands for the CSV's packages — no R packages are installed. Combined with `--packages`, it's a no-op distinction: you still get the full install described above. |
| `--site-library <path>` | optional | Install into `<path>` instead of R's default `site-library` (`R.home()/site-library`). The path must already exist — the script errors out rather than creating it. The path is also registered in `Rprofile.site` so future R sessions on this installation pick it up automatically via `.libPaths()`. |
| `--snapshot <date>` | optional, default `latest` | Pin the PPM CRAN/Bioconductor snapshot to a specific `YYYY-MM-DD` date instead of the rolling `latest`, for reproducible builds. |
| `--site-library-first` | flag | Register the `--site-library` path at the **front** of `.libPaths()` instead of the end, so its packages take precedence over the user library and R's default `site-library`. Use this for a validated library that must not be shadowed. |
| `--no-register` | flag | Do **not** register the `--site-library` path in `Rprofile.site`. Use this for a library that should only be activated on demand, for example by a conditional block you manage yourself (see [Validated builds](#validated-builds-on-a-multi-node-setup)). With `--sysdeps` alone, no site library is needed at all. Cannot be combined with `--site-library-first`. |
| `--ppm-url <url>` | optional, default `https://p3m.dev` | The Posit Package Manager server to use, e.g. your organisation's own instance. |
| `--cran-repo <name>` | optional, default `cran` | The CRAN-type repository on that server, e.g. a curated repository. |
| `--source` | flag | Install R packages **from source** only, never binaries: the repository URL has no `__linux__/<distro>` segment and pak is restricted to source packages (`PKG_PLATFORMS=source`). pak itself may still be a binary, because it is the installer, not part of the installed library. |
| `--pin-pak` | flag | Install pak from the dated `--snapshot` (instead of the rolling `r-lib.github.io` stable build), so the installer's own version is pinned too. Requires a dated `--snapshot`. |
| `--lockfile-create <path>` | optional | Resolve the CSV's packages and all their dependencies and write a pak lockfile to `<path>`. **Nothing is installed and the R installation is not modified.** Requires a dated `--snapshot`. |
| `--lockfile <path>` | optional | Use a pak lockfile instead of a CSV: install exactly the packages, versions and URLs it records, or, with `--sysdeps` alone, run exactly the system-requirement commands it records. Mutually exclusive with `--csv`. |

#### Mode summary

| Flags given | What happens |
|---|---|
| *(none)* | Full install: packages + dependencies + system deps, into the default site-library, at `latest`. |
| `--packages` | Same as above. |
| `--packages --sysdeps` | Same as above. |
| `--sysdeps` (no `--packages`) | System dependencies only — no R packages installed. |
| `--lockfile-create <path>` | Write a lockfile for the CSV; nothing installed, installation not modified. |
| `--lockfile <path>` | Full install from the lockfile (packages + system deps). |
| `--lockfile <path> --sysdeps` | System dependencies recorded in the lockfile only — no R packages installed. |

### `--site-library <path>`

Use this to install into a location other than R's built-in `site-library` — for example, a
directory you intend to bake into a Docker image and mount/share elsewhere. Two things happen:

1. The script errors out immediately if `<path>` doesn't already exist (create it yourself first,
   e.g. `mkdir -p /opt/site-library`).
2. If it exists, the script appends a small block to `Rprofile.site` that adds `<path>` to
   `.libPaths()` on every future R session for this installation — so packages installed there
   remain discoverable without passing `--site-library` again.

Re-running with a *different* `--site-library` path adds another independent block (multiple
site-libraries can coexist); re-running with the *same* path is a no-op update.

### `--snapshot <date>`

Posit Package Manager serves binaries per historical snapshot: a snapshot's binary index only has
a binary for whichever package version was "current" on CRAN as of that date. This means:

- Pinning a package version in your CSV that matches what's "current" at your chosen
  `--snapshot` (or `latest`, if that's genuinely the latest release) installs as a binary.
- Pinning an **older** version than what's current at that snapshot falls back to building from
  source, fetched from the CRAN archive — this is expected PPM behavior, not a bug. If you need a
  binary for an older pinned version, pick a `--snapshot` date from when that version was current
  on CRAN.

Re-running with a different `--snapshot` replaces the previous PPM configuration in `Rprofile.site`
in place (it does not accumulate stale blocks).

### System dependency installation

On a supported Linux distro, running as root, `pak` installs matching system packages (via `dnf`,
`apt`, etc.) automatically as part of installing R packages — that's what happens in the default
full-install mode. `--sysdeps` on its own instead computes that same command list via
`pak::pkg_sysreqs()` and runs it directly, without installing any R packages — useful for
pre-warming a Docker layer with system dependencies separately from the (more frequently changing)
R package layer.

### Binary packages via Posit Package Manager

The script auto-detects your Linux distro (`/etc/redhat-release` → `rhel9`/`rhel10`/`centosN`,
`/etc/debian_version` → the release codename) and configures both `pak` (via `options(repos=...)`)
and `BiocManager` (via `options(BioC_mirror=...)`/`options(BIOCONDUCTOR_CONFIG_FILE=...)`) to pull
from PPM's matching binary channel at `https://p3m.dev`. If the distro isn't recognized, it falls
back to PPM's plain (source-only) URLs. This configuration is written to `Rprofile.site`, so it
also applies to any `install.packages()`/`BiocManager::install()`/`pak` call made later in a fresh
R session on the same installation — not just this script's own install.

## Example: Docker

```dockerfile
FROM rockylinux/rockylinux:10

ENV R_VERSION=4.6.1

RUN dnf install -y epel-release && crb enable

RUN dnf install https://cdn.posit.co/r/rhel-10/pkgs/R-${R_VERSION}-1-1.$(arch).rpm -y

COPY install_packages.R packages.csv /tmp/

RUN mkdir -p /opt/site-library

RUN /opt/R/$R_VERSION/bin/Rscript /tmp/install_packages.R \
      --csv /tmp/packages.csv --packages --sysdeps --site-library /opt/site-library
```

To pre-warm system dependencies in their own layer before installing R packages (so R-package-only
changes don't invalidate the system-dependency layer):

```dockerfile
RUN /opt/R/$R_VERSION/bin/Rscript /tmp/install_packages.R --csv /tmp/packages.csv --sysdeps
RUN /opt/R/$R_VERSION/bin/Rscript /tmp/install_packages.R --csv /tmp/packages.csv --packages --site-library /opt/site-library
```

## Validated builds on a multi-node setup

For a regulated (GxP) environment, for example a load-balanced Posit Workbench or Connect cluster,
the validated package library usually lives **once** on a shared file system, while every node
needs the **same system libraries** installed locally. The newer flags support this workflow:

1. **Create the lockfile once** per baseline release, from source, against a dated snapshot. Review
   it and keep it under change control alongside `packages.csv`:

   ```sh
   Rscript install_packages.R --csv packages.csv --snapshot 2026-10-01 --source --pin-pak \
     --lockfile-create pkg.lock
   ```

2. **Build node** (one node): install exactly what the lockfile records, from source, into a
   versioned directory on the shared file system, registered at the front of `.libPaths()`. As
   root, pak also installs the recorded system dependencies on this node:

   ```sh
   mkdir -p /shared/R/validated/4.6.1/2026-10
   Rscript install_packages.R --lockfile pkg.lock --source --pin-pak --snapshot 2026-10-01 \
     --site-library /shared/R/validated/4.6.1/2026-10 --site-library-first
   ```

3. **Every other node**: install only the system dependencies recorded in the same lockfile, and
   register the shared library. No R packages are installed:

   ```sh
   Rscript install_packages.R --lockfile pkg.lock --sysdeps --source --snapshot 2026-10-01 \
     --site-library /shared/R/validated/4.6.1/2026-10 --site-library-first
   ```

Things to know:

- **Checksums.** For each package, the lockfile records its download URL and, for packages that
  are current at the snapshot date, a SHA-256 checksum. A version pinned *older* than the snapshot's
  current one comes from the CRAN archive, which has no checksums; `--lockfile-create` lists any
  such packages. (Pins that *are* current are resolved through the regular index; the script then
  verifies that every pin is in the lockfile exactly as written.)
  **These checksums are those of the original CRAN tarballs.** Posit Package Manager serves its own
  copies of the source tarballs: in them, `DESCRIPTION` says `Repository: RSPM` instead of
  `Repository: CRAN`, and the package's `MD5` file is updated to match. All other files are
  identical, but the repacked tarball has a different SHA-256, so the lockfile's checksums cannot
  verify what was downloaded from Package Manager (pak does not reject the downloads either). For
  integrity evidence, download the tarballs from the lockfile's URLs right after the build, archive
  them, and record their own SHA-256; verify later downloads or rebuilds against that record. For
  stronger evidence, compare each archived tarball file by file with the CRAN original (verified
  against the lockfile's checksum): only the `Repository` field and `MD5` should differ.
- **Keep the nodes identical at the OS level.** Packages are compiled once, on the build node,
  against its system libraries. Even from the same base image, installing system dependencies on
  the build node can pull in newer patch levels of shared libraries than the other nodes have,
  until step 3 runs there. Run step 3 on every node, and compare installed system packages across
  nodes (e.g. `rpm -qa` / `dpkg -l`) as part of your installation checks.
- **Libraries activated on demand.** For an additional library that users should only see when they
  ask for it (for example additions between baseline releases), install it with `--no-register`,
  run the other nodes with `--sysdeps --no-register`, and add a conditional block to `Rprofile.site`
  yourself, for example:

  ```r
  if (identical(Sys.getenv("R_PLATFORM_SLUSHY"), "true")) {
    .libPaths(c(.libPaths(), "/shared/R/slushy/4.6.1/2026-10"))
  }
  ```

  A project then activates it with `R_PLATFORM_SLUSHY=true` in its `.Renviron`, which R reads
  before `Rprofile.site`.
- **One directory per baseline.** A new baseline goes into a new directory; the previous one stays
  available for re-running earlier analyses.
- **pak's lock files.** pak leaves empty install lock files in `<library>/_cache`; the script
  removes that folder after a successful install, so the library contains only packages.

## Exit behavior

The script exits non-zero with a message on stderr for any expected failure: missing/unrecognized
flags, a nonexistent CSV or `--site-library` path, a missing `site-library`, a CSV missing required
columns, a CSV row missing a pinned version, a missing lockfile, conflicting flags (`--csv` with
`--lockfile`, or `--lockfile` with `--lockfile-create`), an invalid `--snapshot`, `--lockfile-create`
or `--pin-pak` with the rolling `latest` snapshot, or a lockfile that does not contain a pinned
version. Failures from `pak` itself (a package that can't be
resolved, a failed system-dependency command, etc.) propagate as normal R errors, which `Rscript`
already turns into a non-zero exit.
