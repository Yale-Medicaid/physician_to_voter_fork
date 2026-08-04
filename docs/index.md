# Physician to Voter Documentation

Matches physicians in NPPES to registered voters in the L2 voter file, so that
voter-file-derived attributes can be appended to physician records. Annual extracts span
2018–2025.

!!! warning

    The L2 voter file is licensed. It stays inside its approved environment (the HPC) and
    must never be copied into this repository or committed. NPPES, the NBER mirrors and the
    CMS inputs are all public.

## Where to start

| Page | What it covers |
| --- | --- |
| [Methodology](methodology.md) | how the match actually works — blocking, features, the model, the four stages |
| [Pipeline steps](pipeline_steps.md) | what each target does, in dependency order |
| [Instructions](instructions.md) | how to obtain the inputs and run the thing |

The pipeline is a [targets](https://books.ropensci.org/targets/) graph, so `_targets.R` is
the authoritative description of execution order — not the individual files in `R/`.
`targets::tar_visnetwork()` or `targets::tar_manifest()` is the quickest way to orient.

## Layout

```
.
├── _targets.R              pipeline definition -- read this first
├── R/                      all target functions, flat and unnumbered
├── scripts/                standalone, side-effecting scripts (not targets)
├── tests/                  one self-contained test script, no real data needed
├── trunk/                  data root; everything inside is gitignored
│   ├── raw/                inputs the pipeline reads but does not produce
│   ├── derived/            everything the pipeline writes
│   └── analysis/           analysis outputs
├── docs/                   this documentation
├── figures/                diagrams and pipeline figures
├── job_outputs/            SLURM and crew worker logs
├── submit.sh               sbatch script for the full 2018-2025 run
└── small_submit.sh         sbatch script for a scoped pilot run
```

`R/` holds **only function definitions**, because `targets::tar_source()` loads the entire
directory — anything that executes at load time belongs in `scripts/`.

## Known gaps in the source data

- **2024 is missing MD, MS and NV.** This is a permanent gap in the L2 extracts, not a
  pipeline failure. Those state-years resolve to nothing and drop out of the graph; the
  affected physicians simply have a lower `n_years_matched`.
- **NBER's taxonomy files are usable for only four of the eight years.** 2018 publishes none,
  2020 returns HTTP 403, and 2021/2022 ship without an NPI column. See
  [Methodology](methodology.md#physician-side).

## Other useful links

Package site for [zoomerjoin](https://github.com/beniaminogreen/zoomerjoin), the in-house
package used for fast fuzzy name linkage.
