# Project: NPPES–L2 Voter File Match

## What this project does
Matches physicians in NPPES (National Plan and Provider Enumeration System) records
to L2 voter file records, to append voter-file-derived attributes to physician data.
Two matching methods exist:
1. A rules-based / flow-diagram string match (original method).
2. A trained random forest classifier on match-candidate features (current best
   performer — prefer this method unless explicitly told otherwise).

Annual extracts span 2018–2025. **2024 is missing MD, MS, and NV** — this is a known,
permanent gap in the source data, not a bug to fix. Any year-over-year linkage logic,
QA check, or completeness report must treat 2024 MD/MS/NV as intentionally absent,
not as a pipeline failure.

## Critical data rule — read this first
**Real L2 voter file data must never be added to, committed to, or generated into
this repository.** L2 data is licensed and cannot leave its approved environment
(the HPC). This repo may contain:
- Real NPPES extracts (public data — fine), whether manually placed or
  fetched via the planned NBER download target (see "NPPES data" section
  below).
- The L2 **schema** (field names, types, codebooks) — not real L2 rows.
- The RF training data schema — not real training rows if they derive from L2.
- **Synthetic L2-shaped data** generated locally to match the schema, clearly
  labeled as synthetic (e.g., `data/l2_synthetic/`), used only for development
  and testing.

If you (Claude Code) are ever about to write, paste, or generate something that
looks like real voter records — real names + addresses + party registration
combinations that weren't synthetically generated — stop and ask first.

All actual runs against real L2 data happen on an HPC cluster via SLURM, executed
by the user directly. This repo/session is for development and testing only.

## DVC — deprecated, do not use
This repo previously used DVC (Data Version Control) for data versioning. **Do not
use DVC going forward, and do not add new DVC tracking.** Existing `.dvc` files,
`dvc.yaml`, `dvc.lock`, `.dvcignore`, and any DVC remote config in `.dvc/config`
reflect a past approach, not current practice — do not assume they are active
tooling to preserve or work around.

Data versioning going forward: real data (L2, and anything derived from it) never
enters this repo at all, versioned or not — it stays on the HPC. Synthetic data
is small enough to commit directly as regular git-tracked files, no DVC needed.

**Status: DVC has been removed** (branch `chore/remove-dvc`). `.dvc/`,
`.dvcignore`, the six `data/*.dvc` pointers, and `requirements.txt` (a pip
freeze that existed only to install DVC) are all gone, and the replication docs
no longer reference `dvc pull`. There are no DVC artifacts left to preserve or
work around. If you encounter a reference to DVC anywhere, it is stale and
should be flagged.

## Pipeline structure — `targets`
This project uses the R `targets` package, not a linear script pipeline. That means:
- The dependency graph is defined in `_targets.R` (or `_targets.yaml` if split
  across multiple pipelines) — read this first to understand execution order,
  not just the individual R scripts.
- Targets are lazily evaluated and cached; re-running `targets::tar_make()` will
  skip anything unchanged. When debugging "why didn't my change take effect,"
  check target dependency tracking before assuming a bug — it may just be cache
  hits behaving as designed.
- When adding new steps, add new targets in `_targets.R` (or the relevant target
  factory file) rather than bolting logic into an existing target's function body,
  unless the change is a genuine fix to that step.
- Use `targets::tar_visnetwork()` or `targets::tar_manifest()` to inspect the
  graph when orienting — this is the fastest way to build an accurate mental model
  of the pipeline, faster than reading every function top to bottom.
- Respect the existing target naming and grouping conventions found in the repo
  (to be filled in during the read-only pass — see below).

## L2 data — file access pattern
Real L2 data lives outside this repo, on the HPC filesystem, under a path structured as:
```
.../l2/transformed/vm2/uniform.parquet/state=XX/year=YYYY/month=MM/day=DD/
```
(Note: despite the `uniform.parquet` path segment, this is a directory, not a file.)
Within a given `state=XX/year=YYYY/` directory, there may be **multiple `month=/day=`
subdirectories representing different extract dates**, and each leaf directory may
contain multiple parquet files.

**Critical: never open a dataset scoped at the `state=/year=` level.** Doing so
would silently union multiple distinct extract dates together. The correct
pattern is:
1. List the `month=/day=` subdirectories under a given `state=XX/year=YYYY/`.
2. Parse them into dates and take the max (the `year/month/day` values represent
   the extract date, not some other date field).
3. Open the dataset (e.g., `arrow::open_dataset()`) scoped to that single resolved
   `month=MM/day=DD/` leaf path only — this may still contain multiple parquet
   files, which is expected and fine.
4. Some state-years have no directory at all (currently: 2024 MD, MS, NV — see
   note above). Treat an empty/missing listing as "no data for this state-year,"
   not as an error condition.

### Implemented in `R/l2.R`
`resolve_l2_extract(state, year, l2_path)` does exactly the above and returns the single
resolved leaf, or `NULL` when the state-year has no directory. The root template is the
`l2_path` constant at the top of `_targets.R`:

```r
l2_path <- "/home/pg589/project_pi_cdn7/pg589/l2/transformed/vm2/uniform.parquet/state={state}/year={year}"
```

It stops at `year=` deliberately — `month=/day=` cannot be part of a `glue` template
because which one is correct is only known at run time.

Branching is `pattern = cross(years, states)` over `years` (2018:2025) and `states`
(`state.abb` + DC), giving the full 408-branch grid. **Absent state-years are handled by
the branch returning `NULL`, not by trimming the grid.** Verified on a synthetic full-scale
tree: 408 branches build with zero errors, aggregation yields 405 paths, 2024 MD/MS/NV are
absent while other 2024 states are present, and a state-year holding two extract dates
resolves to the later one.

Two behaviours worth knowing, both verified rather than assumed:
- `format = "file"` **accepts `NULL`**, and `targets` drops those branches from downstream
  aggregation automatically — a downstream target receives only the paths that exist, so no
  `purrr::compact()` is needed for the plain-vector case.
- `parse_l2_extract_date()` handles unpadded components, so `month=6/day=9` and
  `month=06/day=09` both parse.

**Do not reuse position-based `get_year()`/`get_state()` helpers from other projects on L2
paths.** L2 nests `state=` *outside* `year=`; this project's own derived output uses the
opposite order. `get_l2_state()` / `get_l2_year()` parse by key, not position.

## L2 schema — stability across years (2018–2025, every year checked)
The L2 schema is not fully stable across years. Every year 2018–2025 has been
individually diffed (not sampled/assumed):

**Stable — safe to reference by a single hardcoded name across years:**
- Name: `Voters_FirstName`, `Voters_MiddleName`, `Voters_LastName`, `Voters_NameSuffix`
- Core address: `Residence_Addresses_AddressLine`, `_City`, `_State`, `_Zip`,
  `_ZipPlus4`, `_HouseNumber`, `_PrefixDirection`, `_StreetName`, `_Designator`,
  `_SuffixDirection`, `_ApartmentNum`, `_ApartmentType`, `_CensusTract`,
  `_CensusBlockGroup`, `_CensusBlock`, `_Latitude`, `_Longitude`
- Core demographics: `Voters_Gender`, `Voters_Age`, `Voters_BirthDate`,
  `Parties_Description`, `Ethnic_Description`, `EthnicGroups_EthnicGroup1Desc`,
  `CountyEthnic_LALEthnicCode`, `CountyEthnic_Description`, `Voters_Active`,
  `Voters_CalculatedRegDate`, `Voters_OfficialRegDate`, `Voters_PlaceOfBirth`

**Known unstable / do not hardcode a single name — needs year-aware handling
if used:**
- **Occupation fields — fully resolved; nothing left to investigate.** Schema
  verified across every year 2018–2025 individually (2018–2024 all confirmed
  identical to each other; 2025 confirmed different). The change is a single clean
  cutover between 2024 and 2025, not a gradual drift:
  - **2018–2024** (7 years, all confirmed identical): `CommercialData_Occupation`,
    `CommercialData_OccupationGroup`, `CommercialData_OccupationIndustry`
  - **2025**: `ConsumerData_Occupation_of_Person`, `ConsumerData_Occupation_Group`
    only. **`OccupationIndustry` has no 2025+ successor — it is dropped
    entirely, not renamed.**
  - **The value set is unchanged across the cutover** (user-confirmed). The 2025
    values match 2018–2024, so `"Medical-Physician"`, `"Unknown"` and the rest stay
    valid literals. The year-aware work is therefore a **pure column rename** — no
    value mapping, no codebook translation, and the `grepl("Medical", ...)` and
    `== "Unknown"` tests in `make_X_matrix()` and `locality_sensitive_hash()` hold
    for every year.
  - **Code usage:** `CommercialData_Occupation` is the only occupation field used in
    logic. It feeds the RF via `occ_medical` / `occ_unknown`, and the
    `medical` / `na_medical` / `medical_sub` columns in
    `locality_sensitive_hash()`. `OccupationGroup` and `OccupationIndustry` are
    read into the parquet but never referenced anywhere.
  - **`OccupationIndustry` disappearing in 2025+ is therefore moot** — nothing
    consumes it. It becomes a decision only if someone adds it as a feature.
  - **Still to implement:** the rename itself. Deferred alongside the L2 parquet
    source refactor, since that changes where L2 columns are selected and doing it
    now would mean writing it twice. Note the code has no year dimension at all
    today, so there is currently nowhere to branch on year.
- Broader pattern: most `CommercialData_*` (2018) fields were renamed to
  `ConsumerData_*` (2025) — this is a wide, systemic rename. Only occupation
  has been checked in detail; other `CommercialData_*`/`ConsumerData_*` fields
  should be assumed unstable unless separately confirmed.

Do not assume any field outside the "stable" list above is safe to hardcode
across years without checking both a 2018 and 2025 (or nearer) schema.

## RF training data — schema not yet provided, files not yet identified
The RF match method has associated training data spread across multiple files,
but **which files are actually relevant, and what role each plays (raw
features vs. labels vs. intermediate artifacts), is not yet known** — the user
has not yet supplied this schema, specifically because it's unclear which
files matter. **This is exactly what the read-only pass should help resolve:**
identify which file(s) feed the RF model's training data, what each contains,
and report this back concretely (file path, role, key columns) so the user can
supply the right schema(s) afterward — rather than the user guessing now or
Claude Code guessing which files are relevant without having read the RF-match
code and `_targets.R` first. Do not assume any particular file is "the" RF
training data file without confirming via the pipeline code.

## NPPES data — source and planned download target
NPPES data comes from NBER's processed mirror, not a manually placed local file
(current state may still have a manually-placed file if the existing code
predates this — check during the read-only pass and report which it is).

**Source pattern:** `https://data.nber.org/npi/YYYY/MM/core_YYYYMM_csv.zip`
- Only the **`core`** file is needed (non-repeated fields: name, address,
  demographics). NBER also publishes `byvar` files (`ptaxcode`, `plicnum`,
  `othpid`) for repeated-value fields linked by NPI — **not needed for this
  project**, do not download these.
- CSV format (not SAS/Stata), consistent with the R/tidyverse workflow.
- "End of year" means month `12` in the URL, e.g. 2018 →
  `https://data.nber.org/npi/2018/12/core_201812_csv.zip`.
- **NBER's own documentation notes some months/years contain incomplete or
  missing data.** Do not assume December data exists for every year 2018–2024
  without checking — verify availability per year rather than hardcoding the
  assumption.
- NPPES is public data (unlike L2) — no licensing/access restriction on
  storing it in this repo or on committing derived artifacts, though raw
  downloaded files are still probably better gitignored given their size (use
  judgment; this is a size/repo-hygiene call, not a compliance one).

**Planned enhancement, not yet built:** a `targets` step that downloads the
NBER `core` file for a given year if it isn't already present locally
(idempotent — check for the local file first, skip download if it exists).
This should be implemented as its own feature branch (e.g.,
`feature/nppes-download-target`) **after** the read-only pass and summary
review, not before — same sequencing logic as the DVC removal and other
enhancements. Do not build this speculatively during the read-only pass;
that pass should only report on how NPPES data is *currently* sourced/loaded
by the existing code.

## Repo map
*Filled in from the read-only pass (2026-07-30). Reflects actual structure, which
differs substantially from the placeholder's assumptions — see "does not exist" below.*

- `_targets.R` — pipeline definition (root). **9 targets** (was 10; `dt_match_data`
  went with the flow-diagram matcher), no target factories, no `_targets.yaml`, no
  `tar_map`/branching. `source()`s four `R/*.R` files; `match_diagnostics.R` is
  commented out. Note: uses `library(targets)` + bare `tar_target()`, not the
  namespaced style this file prescribes elsewhere — not yet reconciled.
- `physician_to_voter.Rproj` — RStudio project file. Tabs, not spaces, matching
  the existing code.
- `R/` — all target functions plus standalone scripts, flat, **unnumbered**. The
  old `code/` directory and its `0N_` prefixes are gone.
  - `unzip_l2.R` — standalone, NOT a target. Unzips L2 from a mounted Yale
    `B:/` network drive into `trunk/raw/rawl2/`. Hardcoded to **2018 only**.
  - `extract_l2.R` — `process_voter_data()`; TSV → parquet conversion.
  - `clean_physician_data.R` — `clean_physician_data()`; NPPES+CMS+NUCC merge.
  - `locality_sensitive_hash.R` — `locality_sensitive_hash()`; zoomerjoin LSH
    blocking + comparison-feature construction.
  - `random_forest.R` — `make_X_matrix()` + `add_rf_match_predictions_to_df()`;
    **the only matching method.** `grf::probability_forest`.
  - `make_training_data.R` — standalone; samples LSH output into labeller
    partitions + writes two rule-labelled files.
  - `label.R` — standalone; interactive CLI hand-labelling + inter-coder kappa.
  - `match_diagnostics.R` — `make_match_diagnostic_plots()`; sourced-out/inactive.
- **Deleted** in `refactor/project-layout` (recoverable from git history):
  `05_match_model.R` (the flow-diagram `descision_tree_matcher()`),
  `random_forest_match_model.R` (superseded 10-feature RF), and
  `naive_bayes_match_model.R` (a byte-for-byte twin of the latter). The one thing
  worth remembering from the superseded RF: it fed four features the current
  model does not — `medical` (occupation-derived), `CommercialData_EstimatedHHIncome`,
  `CommercialData_Education`, `Voters_Gender` — and `ntile`-binned everything.
  Treat those as feature candidates, not as code to restore; `grf` handles
  continuous features and NAs natively, so the binning was a downgrade.
- `trunk/` — the data root. Only `README.md` and four `.gitkeep` markers are
  tracked; all data is gitignored. See `trunk/README.md` for the full layout.
  - `trunk/raw/` — inputs the pipeline reads but does not produce. Sizes observed
    from the former DVC pointers: `rawl2/` (361 GB, 102 files),
    `NPPES_Data_Dissemination_February_2023/` (9.4 GB, 10 files),
    `DAC_NationalDownloadableFile.csv` (623 MB), `nucc_taxonomy_230.csv` (513 KB),
    `labelled_training_data/` (4 files, 812 KB), `unlabelled_training_data/`
    (3 files, 495 KB).
  - `trunk/derived/` — `processed_voter_data/`, written by `process_voter_data()`.
    Regenerable; safe to delete.
  - `trunk/analysis/` — created for analysis outputs, currently unused. Note that
    `match_diagnostics.R` still writes to `figures/`, not here.
  - The two training-data directories live under `raw/`, not `derived/`: they began
    as LSH samples, but their labels are human judgements the pipeline cannot
    regenerate, so losing them means re-doing the annotation.
  - NPPES is a **manually-placed CMS dissemination file**, not NBER — see
    "NPPES data" section; nothing in the code downloads it.
  - `unlabelled_training_data/anthony.parquet` is **abandoned** — never labelled,
    not consumed by anything.
- `job_outputs/` — gitignored, for SLURM job output. Nothing writes here yet.
- `docs/` — mkdocs source, only three pages: `index.md` (repo layout + contacts),
  `pipeline_steps.md` (per-target prose, "Last updated 17/06/24"),
  `instructions.md` (replication steps). `mkdocs.yml` at root.
  **No methodology writeup of the flow-diagram logic or the RF approach, and no
  reported performance numbers anywhere.**
- `figures/` — pipeline outputs + diagrams. `at_a_glance.png` (data-flow overview)
  and `processing.png` (the flow-diagram decision tree — now a historical record
  of the deleted matcher, not a spec for anything live). Also
  `age_dist_hist.{pdf,png}`, `matches_by_state.{pdf,png}`, `screenshot.png`,
  `targets_screenshot.PNG`. Predates `trunk/analysis/`; not yet migrated.
- `dependency_graph.png` (root) — **stale** `tar_visnetwork()` export. Shows
  targets `labelled_file`, `match_diagnostic_plots`, `match_slides` that no longer
  exist in `_targets.R`.
- `.github/workflows/push_website.yml` — mkdocs-material gh-deploy on push to
  `main`/`master`. The only CI.
- Environment: `shell.nix` only (a nix shell that just runs `mkdocs serve`).
  No dependency management of any kind — `renv.lock`, `renv/`, `.Rprofile`, and
  `.renvignore` are all gone; see "Dependencies" below. No Python in the project
  either — no `.py`, no notebooks, no `requirements.txt`.

**Does not exist** — do not reference these as if present: `schemas/`, `data/`
(replaced by `trunk/`), `slurm/`, `tests/`. There is **no test suite of any kind**
(no testthat, no `tar_test`), **no SLURM submission scripts**, and **no committed
schema documentation** — the L2 schema exists only as inline `col_types` vectors
duplicated in `R/locality_sensitive_hash.R` (`R/extract_l2.R` is gone).

## Pipeline shape after Stages A and C
```
years ┐
      ├─ cross ─> l2_extracts ──map──> lsh_pairs ─┐
states┘          (408 branches,    (per state-year) │
                  ~3 NULL)                          ├──map(years)──> scored_pairs
physician_data ────────────────────────────────────┘                (per year)
rf_model ──────────────────────────────────────────┘
```

- **`lsh_pairs`** — one branch per state-year, `pattern = map(l2_extracts)`. Writes
  `trunk/derived/lsh_pairs/year=YYYY/state=XX`. Note the partition order is **flipped**
  relative to L2's input layout; `build_l2_out_subdir()` is the single place that flip
  happens.
- **`rf_model`** — trained once on the 2018 labels, in-memory, reused for every year.
- **`scored_pairs`** — one branch per year, `pattern = map(years)`. Recovers the
  partitioned root with `unique(dirname(dirname(lsh_pairs)))` (the house idiom) so hive
  `year`/`state` columns come back, filters to its year, computes `n`, predicts.

**`map()` branches over ALL upstream branches, including `NULL` ones.** Verified: 408
upstream branches give 408 downstream branches, and aggregation yields 405. So the early
`return(NULL)` guard in every branched function is load-bearing, not defensive decoration.

**Where `n` is computed, and why it looks redundant.** `score_pairs()` computes it, not
`locality_sensitive_hash()`. Today the two are equivalent — physicians are filtered to
their own practice state, so within a year an NPI appears in exactly one state branch. It
starts to matter at Stage B, when the cross-border pass adds pairs for the same NPI from
*adjacent* states and a per-branch count would undercount. Do not "simplify" it back into
the LSH step.

**The prediction column is `match_prob`, not `match`.** `match` is the training *label*
column read from the labelled files; keeping the names distinct means a scored dataset can
never be mistaken for a labelled one.

**Blocking after partitioning.** The first join drops `block_by` entirely — the partition
*is* the state-year. The second join keeps `block_by = "mi"` (middle initial alone),
because it previously blocked on `st_mi` = state **and** initial: dropping `block_by`
outright there would also drop the middle-initial *agreement* requirement and start
matching first+last across all middle initials. The post-filter is not a substitute — it
tests middle-name *length*, not agreement. `by` remains required either way.

**`state_agree` is constant `TRUE` until Stage B exists**, since everything is same-state.
It is computed but deliberately not yet an RF feature; add it as the 9th feature when the
cross-border pass lands.

## Tests
`tests/test_l2_and_geography.R` — 30 checks over the L2 partition helpers, the state
adjacency table, and the cross-border physician selector. Run from the repo root:

```bash
Rscript tests/test_l2_and_geography.R
```

Self-contained: it builds its own synthetic L2 hive tree in `tempdir()`, so it needs no
real data and writes nothing inside the repo. Exits non-zero on failure.

This is the whole test suite. It exists because the interesting failures in this pipeline
are not syntax errors — they are silent behavioural ones (a stale extract being unioned in,
a `NULL` branch reaching an operation that cannot take it, an occupation column renamed out
from under a `contains()` selector). Those need a fixture to catch, and a fixture in a
scratch directory dies with the session.

## State adjacency — the rules, and one common error
`state_adjacency()` in `R/geographic.R` is a 109-row tribble of undirected pairs. It is a
proxy for "could plausibly commute across this border", not a statement of geography:

- **Land borders: in.**
- **Water-only borders: out** — RI↔NY across Block Island Sound, and Michigan's Great Lakes
  pairs (IL, MN, NY, PA).
- **Four Corners point contacts: in** — AZ↔CO and NM↔UT. Including them costs nothing.
- **DC↔MD and DC↔VA: in**, and the most consequential pair in the country here.
- **AK and HI have no land neighbours** and so never get a cross-border pass.

**MI↔WI is a land border and is included.** Michigan's Upper Peninsula shares a real land
boundary with Wisconsin. It is frequently mislabelled a water border — I made that mistake
in the plan before checking — so the test asserts it explicitly.

## Documentation
Methodology documentation lives in the mkdocs `docs/` source files and is the
source of truth for *why* the pipeline works the way it does — read it before
inferring methodology purely from code. If code and docs disagree, flag the
discrepancy rather than silently trusting one over the other.

## Dependencies — no lockfile, install manually
`renv` has been removed (branch `chore/remove-renv`), along with `renv.lock`,
`renv/`, `.renvignore`, and the `.Rprofile` that activated it. **There is no
dependency pinning any more** — packages must be present in the R library of
whatever environment the pipeline runs in (on the HPC, typically via a module
load or a shared site library).

Direct dependencies. The **validated** column is what the code has actually been
run against (R 4.5.2, aarch64-apple-darwin20, 2026-07-30); the **old lock**
column is what the removed lockfile pinned, kept because the gap explains the
compatibility fixes in `fix/current-package-compat`:

| Package | Validated | Old lock | Used by |
| --- | --- | --- | --- |
| `targets` | 1.12.0 | 1.7.0 | pipeline |
| `tarchetypes` | 0.14.1 | 0.9.0 | pipeline |
| `arrow` | 25.0.0 | 16.1.0 | L2 parquet read/write |
| `zoomerjoin` | 0.2.3 | 0.1.4 | LSH blocking (in-house pkg) |
| `grf` | 2.6.1 | 2.3.2 | `probability_forest` — the RF matcher |
| `tidyverse` | 2.0.0 | 2.0.0 | throughout |
| `lubridate` | 1.9.5 | 1.9.3 | date parsing |
| `furrr` | 0.4.0 | 0.3.1 | parallel L2 conversion |
| `digest` | 0.6.39 | 0.6.35 | declared in `tar_option_set` |
| `readxl` | 1.5.0 | 1.4.2 | `label.R` |
| `glue` | 1.8.1 | 1.6.2 | `label.R` |
| `yesno` | 0.1.3 | 0.1.2 | `label.R` interactive prompts |
| `vcd` | 1.4-14 | 1.4-12 | `label.R` inter-coder kappa |

**Removed** (branch `refactor/arrow-and-nber-distance`): `duckplyr` (replaced by
`arrow`), `zipcodeR` (replaced by the NBER distance database — see below), and
`terra`, which was only ever a `zipcodeR` dependency. Do not reintroduce any of
them; `arrow` is the query engine for this project.

The old lockfile pinned **R 4.3.3** and 151 packages in total (the rest
transitive); full detail is recoverable from git history. Under the tidyverse
versions above, `dplyr` is 1.2.1, `purrr` 1.2.2, `readr` 2.1.6, `ggplot2` 4.0.1.

### ⚠ zoomerjoin `block_by` — do not "restore" the named form
`block_by` must be a **single column name present in both tables**
(`block_by = "st"`). The `c("phys_col" = "voter_col")` renaming form — which the
original code used — **errors on CRAN zoomerjoin** with `Can't rename variables in
this context`, because the named form reaches `unite()` internally.

Upstream [issue #135](https://github.com/beniaminogreen/zoomerjoin/issues/135):
the maintainer confirmed the bug and fixed it on `main` in April 2026, but stated
there is **no planned CRAN release**. CRAN 0.2.3 was published 2026-03-14, before
the fix, so the named form stays broken on CRAN indefinitely. We deliberately do
*not* use the GitHub build — it would require a Rust toolchain wherever the
pipeline runs.

Consequences for `R/locality_sensitive_hash.R`:
- The voter-side blocking columns are named `st` / `st_mi` to match the physician
  side, **not** `st_2` / `st_mi_2`. The join therefore suffixes them, which is why
  `state_agree` compares `st.x` to `st.y`.
- **`by` is not optional.** Omitting it errors with `'by_a' must be of length 1`.

### Arrow is the query engine — no duckdb
`arrow` does all the out-of-memory work: reading the L2 parquet, the voter-side
derived columns, and the ZIP-distance join. duckdb/duckplyr have been removed and
should not come back.

Two Arrow gotchas worth knowing before editing `locality_sensitive_hash()`:
- **Use `coalesce()`, never `replace_na()`.** Arrow has no binding for
  `replace_na`, and rather than erroring it *silently pulls the whole table into
  R* with only a warning. In a function that handles the full voter file that
  turns an out-of-memory query into an in-memory one. Verified that the current
  code triggers zero "Pulling data into R" fallbacks — keep it that way.
- The voter-side `mutate()` sits **before** `collect()` deliberately, so it
  evaluates as the dataset streams. Moving it after `collect()` still works but
  reverts the memory benefit. Arrow's `paste0` matches base R's NA handling and
  Arrow honours sequential column references within a single `mutate()`, both
  verified, so neither is a reason to move it back.

### ZIP distance — NBER centroids, computed here, not zipcodeR
`zip_dist` is computed in `locality_sensitive_hash()` from the **NBER ZCTA centroid
file**, a 890 KB / 33,791-row `trunk/raw/` input:
`https://data.nber.org/distance/zip/2024/centroid/gaz2024zcta5centroid.csv`
— columns `zcta5, intptlat, intptlong`. Those are Census ZCTA "internal points"
(NBER's `source/` directory holds the underlying `2024_Gaz_zcta_national.txt`
Gazetteer file).

**We compute great-circle distance rather than downloading one of NBER's
pre-computed distance files.** Their distance files are Haversine distances between
exactly these internal points, so this reproduces their published numbers:
validated to a **max absolute error of 0.000035 miles (2.2 inches)** across 50,000
pairs sampled from their own 25-mile file. The radius constant that achieves that
is `6371 / 1.609344 = 3958.756` miles (6371 km) — **that value is not arbitrary,
do not "round" it**; 3958.8 or 3963.19 both degrade the agreement.

Why compute instead of look up:
- **No truncation.** Every published distance file is capped (5/25/50/100/500
  miles), so pairs beyond the cap are simply absent. On the synthetic fixture,
  switching from the 100-mile file took `zip_dist` from 60% `NA` to 0% `NA`.
- **`NA` now means one thing:** "not a valid ZCTA" (PO-box-only ZIPs have none).
  It no longer conflates that with "farther apart than the cap".
- **No same-ZIP special case.** The distance files omit `zip1 == zip2` rows and
  needed them filled to 0; Haversine returns 0 naturally.
- 890 KB instead of ~0.5 GB (100-mile) or ~10 GB (500-mile).

Implementation notes:
- ZCTAs must be read with an **explicit string schema**; inferred types strip the
  leading zeros many ZIPs carry.
- Lookup is by `match()` rather than a join, because the centroid table is tiny but
  `processed` is not — a join would materialise four extra lat/long columns
  alongside every candidate pair. An unmatched ZIP gives `NA`, which indexes to
  `NA` and propagates to `NA` distance.
- `pmin(1, a)` guards `asin()`, since floating point can nudge the Haversine term a
  hair above 1.

**Feature semantics vs. the original pipeline.** This largely *restores* what
`zipcodeR::zip_distance` gave — an exact distance for any pair — so the existing
labelled training data is broadly comparable again. The residual difference is
coverage: `zip_dist` is `NA` for ZIPs with no ZCTA, where zipcodeR's own database
may have had a coordinate. Comparable, not identical.

Centroid files exist for **2019–2024** while the project spans 2018–2025. ZCTA
internal points move little year to year, so a single file is used for all years;
revisit if that assumption ever matters.

### The second LSH join's middle-name filter (fixed)
The second join is post-filtered to admit pairs where at least one side has only a middle
initial or nothing. It originally read:

```r
filter(nchar(Voters_MiddleName) <= 1 | nchar(mid_nm) <= 1)
```

`nchar(NA)` is `NA`, not `0` or `2`, and both columns are still raw at that point (the
`coalesce` to `""` happens later, in `processed`). So a missing middle name gave
`NA <= 1` → `NA`, and `filter()` drops `NA` rows — meaning a pair with **no middle name on
either side** evaluated to `NA | NA` and was dropped entirely. The exact opposite of the
filter's intent.

Fixed in `fix/lsh-middle-name-na-filter` by coalescing before `nchar()`. Verified across all
seven middle-name combinations: the three NA-involving cases are recovered, nothing is newly
excluded, and "both sides have a full middle name" remains correctly excluded.

### Occupation is now an RF feature — as two indicators, not one
`make_X_matrix()` derives **`occ_medical`** (`grepl("Medical", ..., ignore.case = TRUE)`)
and **`occ_unknown`** (`is.na(...) | ... == "Unknown"`) from `CommercialData_Occupation`,
bringing the RF to **8 features**. Previously occupation reached the model not at all:
`med_prof` was computed and then dropped by the following `select()`.

Two indicators rather than one is deliberate. `grepl()` returns `FALSE` for `NA`, so a
single medical flag folds missing and `"Unknown"` occupations in with genuinely
non-medical ones — a voter whose occupation is merely unrecorded would score as evidence
*against* a match, identically to one recorded as `"Educator"`. L2's commercial
occupation data is sparse, so that case is common rather than marginal. The pair encodes
three distinguishable states:

| Occupation value | `occ_medical` | `occ_unknown` | Reads as |
| --- | --- | --- | --- |
| `Medical-Physician`, `Medical-Nurse`, … | 1 | 0 | evidence for |
| `Educator`, any other known value | 0 | 0 | evidence against |
| `Unknown` or `NA` | 0 | 1 | uninformative |

Computed from the raw field rather than reusing the `medical` / `na_medical` columns that
`locality_sensitive_hash()` also derives, so the function depends only on
`CommercialData_Occupation` being present.

**This makes the year-aware column mapping consequential**, where before it was moot.
Occupation is now load-bearing for the RF, so the 2024→2025 rename
(`CommercialData_Occupation` → `ConsumerData_Occupation_of_Person`) must be handled
before any 2025 run. It is a **rename only** — the value set is confirmed unchanged
across the cutover, so `grepl("Medical", ...)` and `== "Unknown"` stay correct.

Finer options not taken, worth revisiting once variable importance is available: an exact
`== "Medical-Physician"` indicator, and the `medical_sub` column
`locality_sensitive_hash()` already computes, which retains *which* medical occupation.

### Other findings from the compatibility pass
- `jaccard_similarity()`'s n-gram argument is `ngram_width` and **defaults to 2**,
  whereas `jaccard_inner_join()`'s is `n_gram_width`. The code passes `3`
  positionally for `full_name_sim` but omits it for `mid_name_agree`, so that
  feature was computed on 2-grams while every other name comparison uses 3.
  **Confirmed intentional** (middle names are short enough that 3-grams are too
  coarse) and now passed explicitly at the call site, so it reads as a decision
  rather than an inherited default. Do not "correct" it to 3.
- `make_X_matrix()` selected 6 columns but emitted **7**: `model.matrix.lm(~ -1 + .)`
  expands the logical `mid_initial_agree` into both `...FALSE` and `...TRUE`
  dummies. **This was previously recorded here as a latent `predict()`
  dimension-mismatch failure. That was wrong** — logicals have a fixed
  `{FALSE, TRUE}` domain, so `model.matrix` emits both dummies regardless of which
  values are present, and the width was stable at 7 even for all-`TRUE` or all-`NA`
  input. Only *factors* vary in width with the data (and a single-level factor
  errors outright rather than narrowing). `grf`'s default `mtry` is
  `min(ceiling(sqrt(p) + 20), p)`, which equals `p` at this size, so the redundant
  column did not affect feature sampling either. Simplified to 6 columns in
  `refactor/simplify-x-matrix` purely for legibility.

**Known gap (fixed):** `duckplyr` was missing from
`tar_option_set(packages = ...)` and worked only because the call site is
namespaced; now declared.

## Targets pass paths, not data
Every substantial pipeline function writes an arrow dataset and returns its path; the
target is declared `format = "file"`. The shape is:

```r
f <- function(input, out_pth = "trunk/derived/name") {
  arrow::open_dataset(input) |> ... |> write_and_return(out_pth)
}
```

`return_out_pth()` (in `R/helpers.R`) returns the path if it exists and `NULL` otherwise;
`return_out_pth_check_distinct()` additionally asserts distinctness before handing it back.
Both are ported from `treated-by-thy-neighbor`. Emptiness is handled by an **explicit early
`return(NULL)` guard at the top of the function**, not by threading `NULL` through a writer.

**Small artifacts stay in memory.** There is no point writing a two-column lookup to disk
to hand back a path. Path-passing is for L2 reads, candidate pairs, scored matches and the
cross-year panel; in-memory is for `years`, `states`, lookup tribbles, tuning constants and
the fitted RF model (which carries an external pointer, making `format = "file"` awkward).

Why it matters here: Phase 5 fans out to 408 state-year branches. Passing frames through
target boundaries would mean every branch's candidate pairs are serialised into the targets
store *and* held in memory during aggregation. Paths keep the store a set of directory
pointers.

Consequences already absorbed:
- `clean_physician_data()`, `locality_sensitive_hash()` and
  `add_rf_match_predictions_to_df()` all take and return paths. Their `out_pth` defaults
  live under `trunk/derived/`.
- `locality_sensitive_hash()` now `ungroup()`s before writing. It previously returned a
  frame still grouped by `npi`.
- `add_rf_match_predictions_to_df()` still `collect()`s internally, because `grf` needs a
  materialised matrix. Path-passing is about what crosses the target boundary, not about
  never materialising.
- Distinctness is asserted where there is a real invariant: `physician_data` on `npi`,
  and both `lshed_data` and `rf_match_data` on `(npi, LALVOTERID)`. The pair invariant
  holds *only because* `physician_data` is distinct in `npi` — a duplicated physician row
  would duplicate every candidate pair it generates.
- Parquet round-trips the awkward `provider_last_name_(legal_name)` column name — verified,
  since that name would be a plausible thing to break on a write/read cycle.

### `physician_data` is distinct in `npi`, by dropping conflicts
An NPI carrying more than one `(grd_yr, med_sch)` combination in CMS is **dropped
entirely** — there is no principled way to choose between them, and keeping one would fan
that physician out through every downstream join.

The subtlety that makes this easy to get wrong: removing the conflicted rows from
`cms_data` is *not* sufficient. The join to NPPES is a `left_join`, so the physician
survives with `grd_yr`/`med_sch` as `NA` instead of being dropped. The `anti_join` has to
happen on the NPPES side, before the CMS join. NPIs simply *absent* from CMS are still
kept with `NA grd_yr`, which is unchanged behaviour.

`count_cms_npi_conflicts()` reports how much this costs and which field disagrees — a
provider listed with two graduation years is a different data-quality story from one listed
with two medical schools. It is a small in-memory target: `tar_read(cms_npi_conflicts)`.

## R style conventions
- Use tidyverse packages where possible.
- Prefix non-base function calls with their package namespace
  (e.g., `dplyr::mutate()`, `tidyr::pivot_longer()`, `targets::tar_target()`),
  rather than attaching packages with `library()` and calling bare functions.
- Match existing code style/conventions found in the repo over introducing new
  patterns, unless there's a clear correctness or maintainability reason to change.

## Git workflow
- **Never commit directly to `main`.** Always work on a feature branch.
- Branch naming: `feature/...`, `fix/...`, `refactor/...` as appropriate to the
  change (e.g., `feature/synthetic-l2-generator`, `fix/2024-state-gap-handling`).
- **Commit frequently**, in small logical units — after each meaningful step
  (schema drafted, function working, tests passing), not one large commit at
  the end of a session.
- Write descriptive commit messages explaining *why*, not just *what*.
- Open a PR into `main` when a branch is ready, rather than merging directly.
  Assume the user will review the diff before merging.
- Do not rewrite history on shared branches (no force-push to `main` or any
  branch others may have pulled) without explicit confirmation.

## First-session task — COMPLETE (2026-07-30)
**This pass has been done; the checklist below is kept as a record of what it
covered, not as work to repeat.** Its findings are folded into "Repo map",
"Dependencies", and the occupation notes above. Key outcomes: NPPES is a
manually-placed CMS dissemination file (not NBER); the RF training data is
`data/labelled_training_data/` (two rule-labelled files plus two hand-labelled);
`CommercialData_Occupation` is the only occupation field used in logic (now an RF
feature via `occ_medical`/`occ_unknown`, see `feature/rf-occupation-feature`), and
`OccupationGroup`/`OccupationIndustry` are read but never referenced; the code
is 2018-only with no year dimension at all.

Original checklist — before making any code changes, do a **read-only pass**:
1. Read `_targets.R` and any target-factory files to map the actual pipeline
   dependency graph.
2. Read the existing string-match and RF-match code.
3. Read the mkdocs methodology docs.
4. Check how NPPES data is currently sourced/loaded by the existing code —
   a manually-placed local file, an existing download step, or something
   else (see "NPPES data — source and planned download target" section
   above; report which it is, don't assume).
5. Read the L2 schema and RF training data schema docs.
6. Patch the "Repo map" section above with the real structure you find.
7. Note any DVC artifacts found (`.dvc` files, `dvc.yaml`, `dvc.lock`, etc.) in
   your summary — do not remove or modify them yet (see "DVC — deprecated"
   section above).
8. Identify which file(s) feed the RF training data (see "RF training data"
   section above) and report path/role/key-columns for each.
9. Do NOT propose or make any code changes yet — this is a comprehension
   check only. Then produce a written summary covering:

   **Pipeline structure** — the full targets dependency graph, stage by stage
   (what each stage does, not just target names). Where the two matching
   methods enter the pipeline: parallel alternatives, does one feed the other,
   fully independent branches? Where does SLURM execution fit — which stage(s)
   need HPC scale vs. could run locally?

   **Matching methods** — Flow-diagram method: what fields it uses, the
   decision logic/order, what determines match/no-match/ambiguous. RF method:
   what features feed the model, what the training data/labels are and how
   they relate to the flow-diagram method's output (was RF trained on
   flow-diagram-labeled matches?), and what performance was reported in the
   docs. Separate any explicit documented reason RF outperformed flow-diagram
   from your own inference — label these differently.

   **Data** — NPPES: fields actually used, join keys, known quirks handled in
   code. L2 (schema only): fields used as match candidates/features. Confirm
   exactly which occupation field(s) are used and where (see "Occupation
   fields" note above — report this specifically, not folded into a general
   list). RF training data: which file(s), what role each plays. Confirm
   understanding of the 2024 MD/MS/NV gap and how the current code handles it.

   **Open questions/ambiguities** — anything code and docs disagree on;
   anything underspecified that would block writing a synthetic data
   generator or making method changes without guessing.
