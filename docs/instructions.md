# Instructions for Replicating

## Step 1: Clone the repository

Use the git command line to clone the physician to voter repository.  This
assumes that you have your ssh keys setup. If you don't, check out the
instructions
[here](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent).

```
git clone git@github.com:Yale-Medicaid/physician_to_voter.git
cd physician_to_voter
```

## Step 2: Put the input data in place

The pipeline reads four inputs from `data/`. None of them are distributed with
this repository, and there is no automated download step yet, so they have to be
placed by hand.

!!! Warning inline end

    The L2 voter file is licensed. It must stay inside its approved environment
    (the HPC) and must never be copied into this repository or committed.

| Input | Expected location | How to obtain |
| --- | --- | --- |
| L2 voter file | `data/rawl2/` | HPC only — licensed, not redistributable |
| NPPES | `data/NPPES_Data_Dissemination_February_2023/` | Public ([CMS NPPES data dissemination](https://download.cms.gov/nppes/NPI_Files.html)) |
| CMS Physician Compare | `data/DAC_NationalDownloadableFile.csv` | Public |
| NUCC taxonomy crosswalk | `data/nucc_taxonomy_230.csv` | Public ([NUCC](https://www.nucc.org/)) |

The exact paths the pipeline expects are declared as targets at the top of
`_targets.R`; check there if a target reports a missing file.

!!! Note inline end

    L2 ingestion is mid-migration. The current code expects the older layout of
    unzipped `.tab` files under `data/rawl2/`, produced by
    `code/00_unzip_l2.R`. It is being moved to read the newer partitioned
    parquet extracts directly.

## Step 3: Run the pipeline

R dependencies are not managed automatically — install them yourself into the R
library of whatever environment you are running in. The direct dependencies are
listed in `CLAUDE.md`, and the runtime set is declared in
`tar_option_set(packages = ...)` at the top of `_targets.R`. Once they are
available, start the pipeline from an R session in the root directory:

```r
> targets::tar_make()
```

This will start the process to link the physician and voter files. The linked dataset can be accessed by running the following command in R:

```r
> targets::tar_read(rf_match_data)
```
