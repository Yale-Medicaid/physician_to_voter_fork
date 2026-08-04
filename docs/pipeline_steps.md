# Pipeline Steps

What each target does, in dependency order. `_targets.R` is authoritative — if this page and
that file disagree, the file is right and this page is stale.

19 targets. `targets::tar_manifest()` lists them; `targets::tar_visnetwork()` draws the graph.

## Shape

```
years ──┬─ cross ──> l2_extracts ──┬──> lsh_pairs ──────────┐
states ─┘         (408 branches)   └──> cross_border_pairs ─┤
                                                            │
nppes_core_files ────> physician_data ──────────────────────┤
nppes_taxonomy_files ─┘                                     │
rf_model ───────────────────────────────────────────────────┴──> scored_pairs
                                                                     │
                          physician_matches <── physician_year_panel_data
                                                     │
                          panel_gap_summary <────────┴──> physician_year_panel_filled
```

## Inputs

### `years`, `states`

The grid, 2018–2025 crossed with the 50 states plus DC. Crossed rather than mapped over a
discovered manifest so the graph stays static and readable.

### `l2_extracts`

One branch per state-year — 408 in total. L2 is partitioned
`state=XX/year=YYYY/month=MM/day=DD`, and a single state-year may hold **several** extract
dates, so this resolves the latest `month=/day=` leaf and returns only that.

!!! warning

    Never open a dataset scoped at the `state=/year=` level. It would silently union several
    distinct extract dates together.

State-years with no directory (2024 MD, MS, NV) return nothing and drop out of downstream
aggregation on their own. Note the branch is still *created* for those, so the early return
inside each branched function is load-bearing rather than defensive.

### `nppes_core_files`, `nppes_taxonomy_files`

Downloads from NBER's static mirror, one `core` file per year plus the four usable taxonomy
extracts. Idempotent — an already-present file is returned untouched, so re-running does not
re-fetch. Downloads land on a `.part` name first so an interrupted transfer cannot leave a
truncated file that the idempotency check would then accept forever.

### `cms_file`, `nucc_taxonomy_file`, `zip_centroid_file`, `labelled_training_files`

Manually placed inputs under `trunk/raw/`. See [Instructions](instructions.md) for what they
are and where to get them.

## Physician side

### `physician_data`

One table per year: names and addresses from that year's NBER `core` file, taxonomy from the
unioned extracts, graduation year and medical school from CMS. Filtered to
`Allopathic & Osteopathic Physicians` and to individuals rather than organisations.

Partitioned `year=/state=` so each matching branch prunes to one directory instead of
scanning nationally 408 times. Asserted distinct in NPI — see
[Methodology](methodology.md#physician-side) for how conflicting CMS records are handled.

### `cms_npi_conflicts`

A small in-memory diagnostic: how many NPIs were dropped for carrying conflicting CMS records,
and whether graduation year or medical school is the field that disagrees.

```r
targets::tar_read(cms_npi_conflicts)
```

## Matching

### `lsh_pairs` — Stage A

Candidate physician-voter pairs within each state-year, from LSH on name. One branch per
state-year, writing `trunk/derived/lsh_pairs/year=YYYY/state=XX`.

Note the partition order is **flipped** relative to L2's own layout: L2 nests `state=` outside
`year=`, everything this project writes is `year=` outside `state=`.

### `rf_model`

The trained `grf::probability_forest()`. Small enough to stay in memory rather than being
written to disk. Trained once on the 2018 labels and reused for every year.

### `cross_border_pairs` — Stage B

Physicians without a unique strong in-state match, retried against the voter files of
bordering states. Branches over the same grid as Stage A; adjacent partitions are resolved
from the path template inside the function, because a dynamic branch cannot reach its siblings.

Output is partitioned by the **physician's** state-year, not the voter's, so all of a
physician's pairs stay in one place.

### `scored_pairs` — Stage C

Combines both passes for a year, computes `n` over the combined set, and predicts. One branch
per year.

!!! note

    This is the one target that declares `packages = "grf"`. It calls `predict()` on a model
    built in a *different* target, and S3 dispatch needs grf loaded to find the method —
    namespacing the calls is not sufficient.

## Outputs

### `physician_year_panel_data` — Stage D

One row per physician-year: that year's best-scoring voter. Ties are kept and flagged.

### `physician_matches`

One row per physician: the best match found in any year, plus context — `n_years_matched`,
`n_distinct_voters`, `mover`, and the two tie flags. Asserted distinct in NPI.

### `physician_year_panel_filled`

The panel plus one row per gap judged confidently fillable. A separate target from
`physician_year_panel_data` on purpose, so the unfilled panel stays available and nothing
downstream starts seeing imputed rows by accident. Filled rows carry an identity and missing
values for every scored attribute.

Read [the gap-filling section](methodology.md#gap-filling) before using it — a fill is unsafe
wherever registration or turnout is the outcome.

### `panel_gap_summary`

In-memory ledger of how many gaps there were and why each was or was not filled. Worth reading
before trusting the filled panel.

```r
targets::tar_read(panel_gap_summary)
```

## Standalone scripts

These are **not** targets. They execute on `source()`, which is why they live in `scripts/`
rather than `R/` — `targets::tar_source()` loads all of `R/`, and having them there aborted
pipeline definition.

### `scripts/make_training_data.R`

Samples the LSH output into semi-overlapping partitions for hand-labelling. The overlap is
what allows inter-coder reliability to be computed.

### `scripts/label.R`

Interactive CLI for hand-labelling candidate pairs, plus the inter-coder kappa calculation.
Output goes to `trunk/raw/labelled_training_data/`.

!!! note

    The labelled training data lives under `trunk/raw/`, not `trunk/derived/`, even though it
    began as LSH output. The labels are human judgements the pipeline cannot regenerate, so
    losing them means re-doing the annotation.
