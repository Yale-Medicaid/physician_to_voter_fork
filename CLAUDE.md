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
  - **Implemented.** `l2_occupation_col(year)` in `R/l2.R` returns the year's column name,
    and `read_l2_partition()` canonicalises it to `CommercialData_Occupation` at
    `R/locality_sensitive_hash.R:97,105` via `dplyr::rename(... = dplyr::any_of(occ_col))`.
    `any_of()` rather than `all_of()` deliberately, so a year missing the column does not
    error — though note that also means a *future* rename would fail silently, with every
    occupation-derived column coming out empty rather than erroring.
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

- `_targets.R` — pipeline definition (root). **19 targets**, no target factories and no
  `_targets.yaml`; the whole graph stays in this one file. Loads `R/` with
  `targets::tar_source()`, defines the two crew controllers at the top, and namespaces
  every `targets::` call.
- `physician_to_voter.Rproj` — RStudio project file. `UseSpacesForTab: Yes` at 2, matching
  the code after the style pass.
- `R/` — function definitions only, flat and **unnumbered**. Nine files, 35 functions.
  Anything that executes at load time is in `scripts/`, because `tar_source()` loads the
  whole directory.
  - `l2.R` — partition resolution, key-based path parsing, the cross-border selector.
  - `nppes.R` — the NBER URL tables, idempotent downloads, taxonomy union.
  - `clean_physician_data.R` — per-year physician table; NBER + NUCC + CMS merge.
  - `locality_sensitive_hash.R` — the shared match core plus Stages A and B.
  - `random_forest.R` — `make_X_matrix()`, `train_rf_model()`, `score_pairs()`.
  - `reconcile.R` — Stage D: the physician-year panel and the per-physician best match.
  - `gap_fill.R` — gap classification, the filled panel, the gap summary.
  - `geographic.R` — the state adjacency table.
  - `helpers.R` — path-returning and distinctness helpers.
- `scripts/` — standalone, side-effecting; **not** targets.
  - `make_training_data.R` — samples LSH output into labeller partitions.
  - `label.R` — interactive CLI hand-labelling + inter-coder kappa.

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
  - `trunk/derived/` — the seven datasets the pipeline writes; see `trunk/README.md`.
    Regenerable; safe to delete.
  - `trunk/analysis/` — created for analysis outputs, currently unused. Pipeline figures
    still live in `figures/` at the repo root, unmigrated.
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

## The cross-border selection rule, and the `n` tension it exposes
`unmatched_physicians()` exempts a physician from the cross-border pass only when Stage A
found **exactly one** strong in-state candidate (a single voter at or above
`min_name_sim`, default 0.85). Zero strong candidates, or two or more, both mean retry.

Requiring *uniqueness* rather than just a high maximum is what closes the common-name hole:
a dozen in-state voters all scoring 0.99 is evidence of a common name, not of a match.

**The tension worth knowing about.** `n` (candidates per NPI) is an RF feature, so adding
cross-border candidates *raises `n` for the retried physician and thereby moves the scores
of their existing in-state candidates*. Extra candidates are therefore not free, and the
claim "over-including only costs compute" is not quite right.

Two consequences follow, neither yet resolved:
- For a physician whose true match **is** in-state but ambiguous, retrying them cross-border
  inflates `n` and may depress the correct candidate's `match_prob`.
- More generally, `n` now partly encodes *"was this physician retried"*, which correlates
  with "had a weak or ambiguous in-state match". So `n` is no longer purely a proxy for
  name commonness — some selection-rule signal leaks into it.

This is inherent to combining a selection rule with a count-based feature, not specific to
the uniqueness variant. Worth measuring on a real run before trying to fix: compare
`match_prob` for in-state candidates of retried versus exempted physicians.

## Output paths must stay two levels deep
`unmatched_physicians()` and `score_pairs()` both recover a pass's partitioned root with
`unique(dirname(dirname(path)))` — the idiom borrowed from `treated-by-thy-neighbor`. That
makes the *depth* of every writer's `out_pth` template a load-bearing contract:

```r
out_pth = "trunk/derived/lsh_pairs/{ys}"   # -> .../lsh_pairs/year=YYYY/state=XX
```

Flatten it and `dirname(dirname(...))` resolves to something useless (`"."` for a
single-segment path), and `arrow::open_dataset()` then tries to read whatever else is in
that directory. It fails loudly rather than silently, but the error is confusing —
"Parquet magic bytes not found" pointing at an unrelated CSV. Caught exactly this way while
writing the tests.

## `R/` holds only function definitions
`R/label.R` and `R/make_training_data.R` used to live in `R/` but are **standalone,
side-effecting scripts** — they execute on `source()` and try to read training data. They
are now in `scripts/`.

This matters because `targets::tar_source(files = "R")` loads *everything* in the
directory. With those two present it aborted with `Failed to open local file
'trunk/raw/labelled_training_data/ben.parquet'` before the pipeline could even be defined.
Verified after the move: `tar_source(files = "R")` loads all 25 functions cleanly, which
unblocks replacing the manual `source()` calls in Phase 4.

Keep `R/` pure. Anything that runs at load time belongs in `scripts/`.

## Why the RF has 8 features and not 9
`state_agree` is computed in the comparison block and carried into the output, but is
**not** in `make_X_matrix()`. That is deliberate, and the reasoning is worth keeping
because the omission looks like an oversight:

- A state line is a partitioning artifact, not a commuting barrier. `zip_dist` already
  measures the thing that actually matters, and measures it continuously.
- The model transfers to cross-border pairs **without new labels**. Training data is
  same-state only, but intra-state distances in large states run to hundreds of miles, so a
  67-mile cross-border pair sits well inside the `zip_dist` range the model already learned
  from — it just learned it from Texas rather than from a border crossing.
- `state_agree` is constant `TRUE` in the existing labels, so `grf` could not split on it
  regardless. Adding it would have been inert *and* redundant.

I initially argued the opposite — that Stage B would need a hand-labelled cross-border
sample before its candidates could be scored properly. That overstated the problem: it
treated the state boundary as the causal variable when distance is.

## Stage D output, and what `mover` does not mean
Two targets: `physician_year_panel_data` (one row per npi-year, the year's best voter) and
`physician_matches` (one row per npi, asserted distinct).

- **No `match_prob` cutoff is applied at either step.** Thresholding is the consumer's
  choice, so every physician with any candidate appears, however weak.
- **Ties are kept and flagged, not dropped**, and there are *two* kinds:
  - `any_tied_in_year` — two candidates tied for a given year's best. Comes from the panel,
    where both rows are kept.
  - `best_is_tied` — two or more **distinct voters** tie for the physician's overall best,
    possibly in different years. The panel flag cannot see these.

  `best_is_tied` counts *distinct voters*, not rows. Counting rows would wrongly flag the
  common and entirely unambiguous case of the same voter matching equally well in several
  years.

  `physician_matches` still emits exactly one row per NPI. The tie is broken
  deterministically by `LALVOTERID` then `year`, both ascending — arbitrary, but
  reproducible, which is what matters. `year` is in the key so a voter matching equally well
  across years yields a stable `best_year`. Do not replace this with `which.max()`: it
  silently takes the first maximum and flags nothing.
- **`mover` means the best-matching voter changed between years — nothing more.** That is
  consistent with a genuine move, and equally with two similar voters trading places
  because of scoring noise. It is a flag to investigate, not a finding.
- **A physician absent from a year is not a failed match.** 2024 MD/MS/NV physicians simply
  have a lower `n_years_matched`. No special case is needed, but do not read the shortfall
  as non-matching.

### The `year` column / hive key collision
`score_pairs()` **drops the `year` column before writing**, because its `out_pth` is itself
a `year=` hive directory. Keeping it means a re-read sees `year` from two sources, and
arrow refuses to merge them the moment the types differ at all —
`Field year has incompatible types: double vs int32`.

Types happen to line up in the current pipeline, so this was latent rather than broken; it
surfaced in a test fixture that built `year` as a double. Note `get_l2_year()` returns
`as.numeric()`, i.e. double, so a double `year` is one small refactor away. Letting the
partition key be the single source removes the whole class of failure.

Note also the root-recovery asymmetry this creates: `lsh_pairs` and `cross_border_pairs`
return paths two levels deep (`year=/state=`) and need `dirname(dirname())`, while
`scored_pairs` is one level (`year=`) and needs a single `dirname()`. That is structural —
they branch over different keys — not an inconsistency to tidy away.

## Gap filling — a separate panel, identity only
`R/gap_fill.R` adds two targets. `physician_year_panel_filled` is the panel plus one row per
gap judged fillable; `panel_gap_summary` is the in-memory ledger of how many gaps there were
and why each was or was not filled (`targets::tar_read(panel_gap_summary)`).

Deliberately a **second** target rather than a change to `physician_year_panel_data`. The
unfilled panel stays available, and nothing downstream starts seeing imputed rows because
someone forgot this step exists.

**The gap universe is `physician_data`, not the panel.** A gap exists only where the
physician held an NPI record that year — otherwise there is nothing to fill and no claim to
make. This is what makes the whole thing possible only after the per-year physician work:
before that, the physician side had no year dimension to be absent from.

**Four gates, and `NA` fails every one of them.** `has_anchor` (some year matched at
`match_prob >= min_fill_prob`, default 0.9 — the panel applies no cutoff, so a physician's
only "match" may be near-zero), `unambiguous` (exactly one distinct `LALVOTERID` across
anchor years), `state_stable` (the gap year's practice state equals the anchors' single
practice state), `near` (best anchor's `zip_dist` non-`NA` and within `max_fill_zip_dist`,
default 50 miles).

`fill_tier` then records *why the year was empty*, given the gates passed: **1** = no L2
partition existed (2024 MD/MS/NV — matching was impossible, so absence carries no
information about the physician), **2** = L2 existed and the physician was not matched
(absence is now evidence, though ambiguous), **3** = gates failed, not filled.

The tiers are a confidence label, not different gates — both apply the same four. That is
the point: Tier 2 is weaker because there is counter-evidence, not because it was checked
less carefully.

**Movers are never filled**, because `unambiguous` fails for them by construction. That is
intentional. `mover` already means only that the best-matching voter *changed*, which is
equally consistent with scoring noise; picking one of the two records to carry across a gap
would be a guess dressed as data.

**Filled rows carry an identity and nothing else.** `LALVOTERID` is set; `match_prob`,
`zip_dist`, `full_name_sim`, `n`, `state_agree` and `tied` are all `NA`. There is no model
output for a year that was never scored, and copying the anchor year's values in would
invent a measurement. It also makes a filled row impossible to mistake for a scored one even
if `filled` is ignored.

**What a fill licenses.** It asserts *this physician is this voter*, extended to a year where
that was not observed. Safe for appending time-invariant voter attributes. **Unsafe wherever
registration or turnout is the outcome** — in Tier 2 especially, the absence may *be* the
finding, and filling it then answers the question with the assumption. Filter on `filled` or
`fill_tier`.

`n_fail_far` and `n_fail_no_zip` are reported apart in the summary: a distant anchor is a
plausibility problem, a missing `zip_dist` is a ZCTA coverage one (PO-box-only ZIPs have no
centroid). Lumping them reads the second as the first.

### Arrow's `distinct()` does not promise a row order
`classify_panel_gaps()` ends with `dplyr::arrange(npi, year)` because `universe` is read
through arrow, and arrow's distinct/aggregate ordering is not guaranteed stable between
calls. Caught by a test that indexed one call's result with another call's logical mask and
passed or failed depending on which check ran — the classic symptom. Any comparison of two
runs row-by-row needs an explicit order; do not remove the `arrange()`.

## Use `!!`, not `{{ }}`, to disambiguate an argument from a same-named column
Several functions take a `year` or `state` argument and filter a dataset whose hive
partition columns have the *same names*. The tempting tidyeval form is wrong:

```r
f <- function(year) dplyr::filter(ds, year == {{year}})   # WRONG
```

`{{ }}` injects the argument **expression**. Called as `f(2024)` that is the literal and it
works — but called as `f(year)` from another function, it injects the *symbol* `year`, the
data mask resolves it to the column, and `year == year` is trivially true for every row.
The filter silently does nothing.

`!!year` injects the **value**, evaluated in the function's own environment, and is robust
regardless of what the caller names its locals. `.env$year` also works; `!!` was chosen to
keep the tidyeval style.

This bit for real. `nppes_core_url()` failed exactly this way the first time
`download_nppes_core()` called it. `unmatched_physicians()` had the same latent bug and
was working only because `lsh_cross_border()` happens to pass locals named `this_year` and
`this_state` — rename those and it would have started matching every row, silently. Both
now use `!!`, and both have a test that calls them from a wrapper whose locals *are* named
`year`/`state`.

## NPPES: four layouts, one truncated year
`nppes_core_url()` is an explicit 8-row table, not a constructed URL. NBER uses four
different layouts across 2018–2025 and the documented
`/{YYYY}/{MM}/core_{YYYYMM}_csv.zip` pattern resolves for only three years.

- **Vintage is the latest month available per year**: December everywhere except **2023,
  which stops at May**. There is no month present in all eight years — 2019 starts in July,
  2023 ends in May — so a uniform vintage is not available from this source.
- **Format is parquet where it exists, CSV otherwise**: 2018 has no parquet at all, and
  2023's May file has none either (its Jan–Apr files do, but those are older vintages).
- Downloads are **idempotent** and go via a `.part` file, so an interrupted transfer cannot
  leave a truncated file that the idempotency check would then accept forever.

Do not replace the table with a rule. Four schemes plus a truncated year means a rule fails
*silently* on the next reorganisation; a listed URL that stops resolving fails loudly.

## Physician side: three sources, one per-year table
`clean_physician_data()` builds one table per year from:

| Source | Varies by year? | Gives |
| --- | --- | --- |
| NBER `core` | **yes** | names, practice + mailing addresses |
| NBER `ptaxcode`, two extracts | no | primary taxonomy code |
| NUCC crosswalk | no | taxonomy grouping, for the physician filter |
| CMS **DAC** / Physician Compare | no | `grd_yr`, `med_sch` |

Everything except the CMS DAC file now comes from **one static archive** (`data.nber.org`),
deliberately — CMS reorganises its download pages, NBER's tree does not. The CMS NPPES
dissemination file is no longer used at all; that target is gone, and with it a 9.4 GB
manually-placed input.

`DAC_NationalDownloadableFile.csv` is the Medicare "Doctors and Clinicians" file, not
NPPES — easy to confuse. Consequence: `grd_yr`, and so `year_dist`, is `NA` for any
physician who does not bill Medicare. Pre-existing, but it means that missingness tracks
Medicare participation rather than data quality.

**Taxonomy: four extracts unioned, newest-first.** `read_taxonomy_union()` reads them in
descending vintage and keeps the first row per NPI, so the most recent designation wins and
providers who drop out mid-panel are still recovered. It sorts by vintage internally rather
than trusting the order it is handed.

**Only four of eight years are usable, and that is the source's doing, not a choice:**

| Year | Status |
| --- | --- |
| 2018 | no taxonomy file published at all |
| 2019 | usable — `npi, seq, ptaxcode` |
| 2020 | HTTP **403** for every format, while `core` in the same directory serves fine |
| 2021, 2022 | published **without an `npi` column** (`ptaxcode, ptaxgroup, pprimtax`) — unjoinable |
| 2023 | usable — extra columns, same keys |
| 2024, 2025 | usable |

Residual gap: an NPI that both appeared and disappeared strictly between 2019-12 and
2023-05 is in none of the four. Small, since NPIs are rarely deactivated — but real.

`seq == 1` selects the primary taxonomy, matching the `_1` suffix the CMS dissemination
file used, so the physician filter is unchanged in meaning. It is also load-bearing
mechanically: `ptaxcode` holds one row per taxonomy per NPI, so without it the join would
duplicate providers and the `distinct in npi` assertion would fire.

**Address: practice location, falling back to mailing.** `plocstatename`/`ploczip` with
`pmailstatename`/`pmailzip` as fallback, and `addr_source` recording which was used. The
pipeline previously used the *mailing* address everywhere, which never matched what
`figures/processing.png` described — a mailing address can be a billing office or a PO box,
which is not what `zip_dist` is meant to measure.

**ZIP columns must be read as strings.** `read_nppes_core()` pins `ploczip` and `pmailzip`
via a partial `col_types` schema. Left to inference a CSV ZIP becomes an integer and loses
its leading zero — `06510` reads back as `6510` — which then fails every ZCTA centroid
lookup silently, because the centroid table is zero-padded. Same trap as the centroid file
itself; it bites on both sides.

Output is partitioned `year=/state=`, so each matching branch prunes to one directory
instead of scanning nationally 408 times.

## Tests
`tests/test_l2_and_geography.R` — **140 checks** over the L2 partition helpers, the state
adjacency table, the cross-border physician selector, the NPPES URL table and taxonomy
union, and the panel gap filler. Run from the repo root:

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
- **Water-only borders: out** — RI↔NY across Block Island Sound, and the four pairs where
  Michigan faces another state across a Great Lake rather than touching it: MI↔IL, MI↔MN,
  MI↔NY, MI↔PA. Each of those is *Michigan* paired with that state — **NY↔PA itself is a
  ~300-mile land border and is included.**
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
| `crew` | 1.3.1 | — | worker controllers |
| `parallelly` | 1.48.0 | — | `availableCores()`, reads `SLURM_CPUS_PER_TASK` |
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
  `score_pairs()` all take and return paths. Their `out_pth` defaults
  live under `trunk/derived/`.
- `locality_sensitive_hash()` now `ungroup()`s before writing. It previously returned a
  frame still grouped by `npi`.
- `score_pairs()` still `collect()`s internally, because `grf` needs a
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

### Whitespace — verified against `treated-by-thy-neighbor`, not inferred
These are the author's own conventions, checked by counting occurrences in that repo rather
than guessed at. The Phase 4 style pass applies them; much of the current `R/` violates them
because I wrote it.

- **Never vertically align.** One space before `=`, `<-` and `|>`, always. No padding to line
  up a block of named arguments or assignments. (Zero counter-examples in ~890 pipe
  expressions.) So `n_anchor_years = n_distinct(year)`, not `n_anchor_years  = ...`.
- **`*` and `/` are tight; `+` and `-` are spaced.** `NDC_QTY/DAYS_SUPPLY*factor`, but
  `a + b`. Verified: 0 spaced `*`//`/`, 0 tight `+`/`-`. This matches the tidyverse guide's
  high-precedence-operator rule.
- **`==`, `<=`, `%in%` and friends are always spaced.** 136 spaced, 0 tight.
- **Continuation lines align to the opening parenthesis**, and the first argument stays on
  the same line as the call. Where that first argument needs a pipe, pipe it inline and
  indent the continuation two from the first argument's column:

  ```r
  # yes
  dplyr::left_join(universe |>
                     dplyr::select(npi, year, anchor_state = state),
                   by = dplyr::join_by(npi, year))

  # no -- first argument on its own line, closing paren dedented
  dplyr::left_join(
    dplyr::select(universe, npi, year, anchor_state = state),
    by = dplyr::join_by(npi, year)
  )
  ```
- **Native `|>` only.** Zero `%>%` in the reference repo.
- **Spaces, never tabs**, at 2 per level. `.Rproj` sets `NumSpacesForTab: 2`, so the old
  tab-indented files converted faithfully with `expand -t2`.
- **Tribble columns are not aligned either** — single space after each comma, and `~ "col"`
  with a space after the tilde. Alignment there is still alignment.
- **Line width is loose 80**: rewrap only what exceeds 100, and bring it under 80. Lines
  between 81 and 100 stay as they are. Two exemptions, both because wrapping would do
  damage: markdown table rows inside roxygen blocks (it breaks the rendering) and the
  `l2_path` string literal in `_targets.R` (a string cannot be broken without changing it).

Applied across `R/` and `_targets.R` in `refactor/style-pass`. Two traps found doing it:

- **Adding a namespace moves the opening parenthesis**, so every paren-aligned continuation
  silently goes out of alignment by the length of the prefix. Six needed re-indenting.
  `scratchpad/align.pl`-style checking (compare each continuation's indent to the column
  after the innermost unclosed `(`) is the only reliable way to catch them; note the checker
  must mask string *contents* without changing their length, or it reports false positives.
- **`pattern = map(...)` and `pattern = cross(...)` are targets' branching DSL, not purrr.**
  A blanket namespacing pass will rewrite them to `purrr::map()` and break branching
  entirely. They must stay bare.

### In-body comments: only where they prevent a wrong edit
No inline commentary explaining what the code does. A comment inside a function body earns
its place only by stopping a specific, plausible "fix" that would break something — and the
reason must not be visible from the code itself. Everything else goes.

Cut from 138 lines to 31 across `R/` and `_targets.R`. For calibration,
`treated-by-thy-neighbor` carries 33 in-body comments across 3270 lines of code, and most of
those are commented-out code rather than prose.

The eleven that survived in `R/` are all of one kind — a trap with a named failure mode:
`by` being required by CRAN zoomerjoin, `block_by = "mi"` carrying the middle-initial
agreement, `coalesce` before `nchar`, the 2-gram width being deliberate, `!!` not `{{ }}`
(twice), dropping `year` before writing to a `year=` directory, arrow's unstable `distinct()`
ordering, `n_distinct()` counting `NA`, the int64/double unification, and the `asin()` clamp.

`_targets.R` keeps only short section labels (`# Stage A -- in-state candidate pairs, one
branch per state-year`), matching the reference repo, plus the `packages = "grf"` note.

**Reasoning belongs here, not in the code.** Every explanation removed was already recorded
in this file — that is what made the deletion safe, and it is the standing division of
labour. If a future change needs justifying, write it here and leave the code clean.

## Parallelism — two crew controllers, and concurrency is a product
`_targets.R` defines `controller_primary` (1 worker) and `controller_max`
(`n_workers`), grouped with `crew::crew_controller_group()`. The fan-out targets
(`l2_extracts`, `physician_data`, `lsh_pairs`, `cross_border_pairs`) carry
`resources = on_max`; everything that materialises a whole year stays on primary.

**NPPES downloads deliberately stay on primary.** They are one-time and idempotent, so
parallelism buys almost nothing, and NBER already 403s some requests.

**Concurrency is `n_workers * lsh_nthread`, not either number alone.** Every crew worker
running an LSH join spawns its own Rayon pool, so the old `Sys.setenv(RAYON_NUM_THREADS = 30)`
meant N workers × 30 threads on the node. `nthread` is now an argument threaded through
`locality_sensitive_hash()` / `lsh_cross_border()` / `match_pairs()` to
`zoomerjoin::jaccard_inner_join()`, and `n_workers` derives from it, so the product cannot
drift. `nthread = 1` because 408 independent branches make branch parallelism the better use
of cores — unverified against real data, so revisit after the pilot.

`nthread = NULL` (zoomerjoin's default) means Rayon's global pool, i.e. every logical core.
That is the wrong default here for exactly the reason above.

### ⚠ `seconds_interval = 3` cost 92× on the 408-branch fan-out
Measured, not guessed. Smoke-tested `l2_extracts` with no L2 present so every branch returns
`NULL`:

| `seconds_interval` | wall clock | max branch | branches > 10s |
| --- | --- | --- | --- |
| 3 (the reference repo's value) | **920s** | 903s | 2 |
| crew's default 0.25 | **10s** | 0.1s | 0 |

Two branches stalled ~903s each under the 3s interval while the median branch took 0.03s.
A standalone `crew` benchmark pushing 200 trivial tasks did **not** reproduce it, so the cost
comes from how `targets` dispatches through a `crew_controller_group`, not from crew's own
push/wait loop — worth knowing, because it means micro-benchmarking crew in isolation will not
surface this class of problem.

`treated-by-thy-neighbor` uses 3s because its targets run for minutes each, where the poll
interval is irrelevant. Do not copy it into a wide fan-out. `seconds_launch = 90` is kept,
well above crew's default of 30, because R startup on a loaded HPC node is genuinely slow.

### Memory, not CPU, is the binding constraint on the full run
`read_l2_partition()` `collect()`s an entire state-year voter file into R, and
`crew_controller_local` workers are processes on one node. Peak memory is therefore roughly
`--cpus-per-task * (largest state-year partition)`. Raising cores without raising `--mem` is
how the job gets OOM-killed on California. Nothing has measured this yet — it is the main
thing `small_submit.sh` exists to find out.

`submit.sh` and `small_submit.sh` are at the repo root, following the reference repo's shape.
`job_outputs/` is now tracked via `.gitkeep`: it was gitignored with nothing in it, so a fresh
clone lacked the directory and `sbatch --output` fails outright when its directory is missing,
before R starts.

### Roxygen: `@param`/`@return` in full, `@description` in two or three sentences
Cut from 579 lines to 359 against 912 lines of code. Every `@param` and `@return` was kept —
they are the only record of what the arguments mean. The `@description` blocks lost their
prose: the reasoning belongs in this file, and repeating it above the function meant
maintaining it in three places (here, roxygen, in-body comment) and letting all three drift.

Where a decision needs justifying, the block now says so and points here. For calibration,
`treated-by-thy-neighbor` carries 10 roxygen lines across 3270 lines of code, in one file of
twenty; this project is far more documented than that even after the cut.

### ⚠ Dropping `packages` breaks bare calls that no test here can catch
Removing the project-wide `packages` argument means **every** call in `R/` must be namespaced
or base. Four sites shipped bare and would have died on the first real run:

- `n()` inside `dplyr::summarize()`/`mutate()` — dplyr does **not** put `n` in the data mask.
  It fails with `could not find function "n"`. Now `dplyr::n()`.
- `read_parquet` passed *as a value* to `purrr::map()` — no parentheses, so no regex looking
  for `name(` will ever find it. Now `arrow::read_parquet`.
- `replace_na()` and `year()` in `match_pairs()` — tidyr and lubridate. `replace_na` was also
  against this file's own rule, so it became `dplyr::coalesce()`; `year` became
  `lubridate::year()`.

`tidyselect::where()` inside `dplyr::across()` is the one case that works bare, because
tidyselect supplies it in the selection context. Namespaced anyway for consistency.

**The test suite cannot catch this by running the code**, because it does
`library(arrow); library(tidyverse)` for its own convenience — so a bare dplyr call works
there and still dies in a crew worker. The guard at the top of
`tests/test_l2_and_geography.R` therefore uses `codetools::findGlobals(merge = FALSE)$functions`
to enumerate call-position symbols and diff them against project functions plus the base
packages. Complete by construction, unlike a list of remembered names — which is exactly how
`replace_na` and `year` survived the first attempt. Verified to fail when a bare call is
injected.

### ⚠ `packages = "grf"` on `scored_pairs` is load-bearing
`tar_option_set()` no longer takes a project-wide `packages` argument, because everything in
`R/` is namespaced. There is exactly **one** exception, declared per-target on `scored_pairs`.

`score_pairs()` calls `predict()` on an `rf_model` built in a *different* target. S3 dispatch
needs `predict.probability_forest`, which is registered only once grf is loaded — and nothing
in that target calls `grf::` itself, so the namespace would never load. Verified by
reproducing the failure in a fresh session:

```
no applicable method for 'predict' applied to an object of class
c('probability_forest', 'grf')
```

This is the general hazard with dropping `packages`: namespacing fixes *calls*, but not **S3
dispatch on a class that crosses a target boundary**. Anything else added later that returns
a classed object from one target and dispatches on it in another needs the same treatment.
`arrow` is fine by luck — its dplyr methods are registered because the same function also
calls `arrow::open_dataset()`.

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
