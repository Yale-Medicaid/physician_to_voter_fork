# `trunk/` — data root

Nothing in here is tracked by git except this file and the `.gitkeep` markers
that preserve the directory structure. The directories are committed so a fresh
clone has somewhere to put data; the data itself never enters the repository.

| Directory | Holds | Tracked? |
| --- | --- | --- |
| `raw/` | Inputs the pipeline reads but does not produce | No |
| `derived/` | Anything the pipeline generates from `raw/` | No |
| `analysis/` | Analysis outputs — tables, figures, exports | No |

## `raw/`

Placed by hand; there is no download step yet. Paths are declared as targets at
the top of `_targets.R`, so check there if a target reports a missing file.

| Path | Source |
| --- | --- |
| `rawl2/` | L2 voter file — **licensed, HPC only** |
| `NPPES_Data_Dissemination_February_2023/` | Public (CMS NPPES dissemination) |
| `DAC_NationalDownloadableFile.csv` | Public (CMS Physician Compare) |
| `nucc_taxonomy_230.csv` | Public (NUCC taxonomy crosswalk) |
| `labelled_training_data/` | Hand- and rule-labelled RF training pairs |
| `unlabelled_training_data/` | Labelling partitions, pre-annotation |

The two training-data directories sit under `raw/` rather than `derived/`
because although they began as samples of the LSH output, the labels in them are
human judgements the pipeline cannot regenerate. Losing them means re-doing the
annotation, so they are treated as irreplaceable inputs.

> **The L2 voter file is licensed.** It must stay inside its approved
> environment and must never be copied into this repository or committed. See
> the data rule in `CLAUDE.md`.

## `derived/`

Regenerable — safe to delete and rebuild with `targets::tar_make()`.

| Path | Produced by |
| --- | --- |
| `processed_voter_data/` | `process_voter_data()` in `R/extract_l2.R` |

Note that `targets` keeps its own cache in `_targets/` at the repo root, not
here. `derived/` is for outputs written to disk as an explicit side effect.
