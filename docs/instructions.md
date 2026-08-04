# Instructions for Replicating

## Step 1: Clone the repository

```bash
git clone git@github.com:Yale-Medicaid/physician_to_voter.git
cd physician_to_voter
```

This assumes your SSH keys are set up; if not, see
[GitHub's instructions](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent).

## Step 2: Install the R dependencies

There is **no lockfile**. Packages must be present in the R library of whatever environment
you run in — on the HPC, typically via a module load or a shared site library.

The direct dependencies, and the versions the code has been validated against, are listed in
`CLAUDE.md` at the repo root. The set includes `targets`, `crew`, `parallelly`, `arrow`,
`zoomerjoin`, `grf`, `tidyverse`, `lubridate` and `glue`.

!!! warning "zoomerjoin must be the CRAN build"

    Not the GitHub build. The GitHub version requires a Rust toolchain wherever the pipeline
    runs, which is not a dependency we want on the cluster.

## Step 3: Put the manually placed inputs in place

Most inputs download themselves. Four do not, and go under `trunk/raw/`:

| Input | Expected location | How to obtain |
| --- | --- | --- |
| L2 voter file | outside the repo, on the HPC | licensed — see below |
| CMS Doctors and Clinicians | `trunk/raw/DAC_NationalDownloadableFile.csv` | public, from CMS |
| NUCC taxonomy crosswalk | `trunk/raw/nucc_taxonomy_230.csv` | public, from [NUCC](https://www.nucc.org/) |
| NBER ZCTA centroids | `trunk/raw/gaz2024zcta5centroid.csv` | `https://data.nber.org/distance/zip/2024/centroid/gaz2024zcta5centroid.csv` |
| Labelled training data | `trunk/raw/labelled_training_data/` | produced by `scripts/label.R`; the existing labels are human judgements and cannot be regenerated |

NPPES `core` and taxonomy files are **not** in this table — the pipeline downloads them from
NBER on demand and skips the fetch if the file is already present.

!!! danger "The L2 voter file is licensed"

    It must stay inside its approved environment (the HPC) and must never be copied into this
    repository or committed. It is not read from `trunk/` at all: the path template is the
    `l2_path` constant at the top of `_targets.R`, pointing at the HPC filesystem. Edit that
    constant to match your environment.

    L2 is expected in the layout `state=XX/year=YYYY/month=MM/day=DD/`, holding parquet files.
    A state-year may contain several extract dates; the pipeline resolves the latest.

## Step 4: Run the pipeline

Locally, or on a login node for a small scoped run:

```r
targets::tar_make()
```

On the cluster, submit rather than running interactively. Two scripts are provided:

```bash
sbatch small_submit.sh   # scoped pilot -- use this first
sbatch submit.sh         # full 2018-2025 run
```

!!! warning "Size the full run from the pilot first"

    The resource requests in `submit.sh` are starting points, not measurements — nothing has
    yet been run against real L2 data.

    **Memory is the binding constraint, not CPU.** The pipeline reads a whole state-year voter
    file into memory per worker, and crew runs one worker per core on a single node, so peak
    memory is roughly `--cpus-per-task` × the largest state-year partition. Raising the core
    count without raising `--mem` is how the job gets killed on California.

Worker logs and SLURM output land in `job_outputs/`.

## Step 5: Read the output

```r
targets::tar_read(physician_matches)             # one row per physician, best match
targets::tar_read(physician_year_panel_data)     # one row per physician-year
targets::tar_read(physician_year_panel_filled)   # the panel plus confident gap fills
```

Each returns a path to an [arrow](https://arrow.apache.org/docs/r/) dataset rather than a data
frame — targets in this pipeline pass paths, not data:

```r
arrow::open_dataset(targets::tar_read(physician_matches)) |>
  dplyr::filter(best_match_prob >= 0.9) |>
  dplyr::collect()
```

!!! note "No threshold is applied for you"

    Every physician with any candidate appears, however weak the match. Choosing a
    `match_prob` cutoff is left to whoever consumes the output.

Two diagnostics are worth reading before trusting anything:

```r
targets::tar_read(cms_npi_conflicts)   # NPIs dropped for conflicting CMS records
targets::tar_read(panel_gap_summary)   # how many panel gaps, and why each was filled
```

## Step 6: Run the tests

```bash
Rscript tests/test_l2_and_geography.R
```

Self-contained — it builds a synthetic L2 hive tree in a temp directory, so it needs no real
data and writes nothing inside the repo. Exits non-zero on failure.
