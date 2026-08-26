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
Rscript install_packages.R --csv <path> [--packages] [--sysdeps] [--site-library <path>] [--snapshot <date>]
```

`--csv <path>` is the only required flag. Everything else is optional and defaults to a full
install using PPM's rolling `latest` snapshot into R's default `site-library`.

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

### Flags

| Flag | Value | Effect |
|---|---|---|
| `--csv <path>` | required | Path to the package manifest CSV. |
| `--packages` | flag | Install the packages from the CSV. Combined with `--sysdeps` below, or on its own, or with no flags at all — all three produce the same **full install** (packages + their dependencies + system dependencies). |
| `--sysdeps` | flag | On its own (i.e. **without** `--packages`), only computes and runs the system-dependency installation commands for the CSV's packages — no R packages are installed. Combined with `--packages`, it's a no-op distinction: you still get the full install described above. |
| `--site-library <path>` | optional | Install into `<path>` instead of R's default `site-library` (`R.home()/site-library`). The path must already exist — the script errors out rather than creating it. The path is also registered in `Rprofile.site` so future R sessions on this installation pick it up automatically via `.libPaths()`. |
| `--snapshot <date>` | optional, default `latest` | Pin the PPM CRAN/Bioconductor snapshot to a specific `YYYY-MM-DD` date instead of the rolling `latest`, for reproducible builds. |

#### Mode summary

| Flags given | What happens |
|---|---|
| *(none)* | Full install: packages + dependencies + system deps, into the default site-library, at `latest`. |
| `--packages` | Same as above. |
| `--packages --sysdeps` | Same as above. |
| `--sysdeps` (no `--packages`) | System dependencies only — no R packages installed. |

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

## Exit behavior

The script exits non-zero with a message on stderr for any expected failure: missing/unrecognized
flags, a nonexistent CSV or `--site-library` path, a missing `site-library`, a CSV missing required
columns, or a CSV row missing a pinned version. Failures from `pak` itself (a package that can't be
resolved, a failed system-dependency command, etc.) propagate as normal R errors, which `Rscript`
already turns into a non-zero exit.
