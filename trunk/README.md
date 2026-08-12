# `trunk/` — data root

Nothing in here is tracked by git except this file and the `.gitkeep` markers
that preserve the directory structure. The directories are committed so a fresh
clone has somewhere to put data; the data itself never enters the repository.

| Directory | Holds | Tracked? |
| --- | --- | --- |
| `raw/` | Inputs the pipeline reads but does not produce | No |
| `derived/` | Anything the pipeline generates from `raw/` | No |
| `analysis/` | Analysis outputs — tables, figures, exports | No |

> **The L2 voter file is licensed.** It must stay inside its approved
> environment and must never be copied into this repository or committed. See
> the data rule in `CLAUDE.md`.
>
> Note L2 is **not** read from `trunk/` at all. Its location is the `l2_path`
> constant at the top of `_targets.R`, pointing at the HPC filesystem.

## `raw/`

| Path | Placed how | Source |
| --- | --- | --- |
| `nppes/` | **downloaded** | NBER's NPPES mirror — per-year `core` files plus four `ptaxcode` extracts |
| `DAC_NationalDownloadableFile.csv` | **downloaded** | CMS "Doctors and Clinicians" (~600 MB) |
| `nucc_taxonomy_230.csv` | **downloaded** | [NUCC](https://www.nucc.org/) taxonomy crosswalk |
| `gaz2024zcta5centroid.csv` | **downloaded** | [NBER ZIP Code Distance Database](https://www.nber.org/research/data/zip-code-distance-database) |
| `labelled_training_data/` | **by hand** | Hand- and rule-labelled RF training pairs |
| `unlabelled_training_data/` | **by hand** | Labelling partitions, pre-annotation |

Everything except the two training-data directories fetches itself. All downloads are
idempotent — an already-present file is returned untouched, so re-running does not
re-fetch, and a `.part` staging name means an interrupted transfer cannot leave a
truncated file that the check would then accept forever.

ZIP-to-ZIP distances are computed from the centroids rather than downloaded, so none
of NBER's large pre-computed distance files are needed.

> **The CMS file is a moving target.** Its URL embeds a content hash that changes
> every release, so it is resolved from the CMS metastore API at run time rather than
> pinned. Whatever CMS currently publishes is what you get — `grd_yr` and `med_sch`,
> and therefore matches, can change without anything in this repository changing.
> Idempotency is what keeps a given `trunk/raw/` stable, so delete that file
> deliberately rather than incidentally. NUCC and NBER *are* pinned; see
> `R/reference_data.R` for why the NUCC version in particular should not be bumped
> casually.

The two training-data directories sit under `raw/` rather than `derived/`
because although they began as samples of the LSH output, the labels in them are
human judgements the pipeline cannot regenerate. Losing them means re-doing the
annotation, so they are treated as irreplaceable inputs.

## `derived/`

Regenerable — safe to delete and rebuild with `targets::tar_make()`. Every one is
an [arrow](https://arrow.apache.org/docs/r/) dataset, and the corresponding target
returns its *path* rather than the data.

| Path | Written by | Partitioning |
| --- | --- | --- |
| `physician_data/` | `clean_physician_data()` | `year=/state=` |
| `lsh_pairs/` | `locality_sensitive_hash()` — Stage A | `year=/state=` |
| `cross_border_pairs/` | `lsh_cross_border()` — Stage B | `year=/state=` |
| `scored_pairs/` | `score_pairs()` — Stage C | `year=` |
| `physician_year_panel/` | `physician_year_panel()` — Stage D | none |
| `physician_matches/` | `reconcile_physician_matches()` | none |
| `physician_year_panel_filled/` | `fill_panel_gaps()` | none |

Note the partition order is **flipped** relative to L2's own layout: L2 nests
`state=` outside `year=`, everything written here is `year=` outside `state=`.

The depth of these paths is load-bearing. Readers recover a partitioned root with
`dirname(dirname(path))` for the two-level datasets and a single `dirname()` for
`scored_pairs`, so flattening a writer's output path breaks its consumer.

`targets` keeps its own cache in `_targets/` at the repo root, not here.
`derived/` is for datasets written to disk as an explicit side effect.

## `analysis/`

Created for analysis outputs and currently unused. Pipeline figures still live in
`figures/` at the repo root and have not been migrated.
