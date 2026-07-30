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
- **Occupation fields — schema mapping CONFIRMED. Code usage CONFIRMED (the
  user has verified the current codebase does use an occupation field from
  L2); exactly how/where is not yet confirmed and should surface in the
  read-only pass.** Schema verified across every year 2018–2025 individually
  (2018, 2019, 2020, 2021, 2022, 2023, 2024 all confirmed identical to each
  other; 2025 confirmed different). The change is a single clean cutover
  between 2024 and 2025, not a gradual drift:
  - **2018–2024** (7 years, all confirmed identical): `CommercialData_Occupation`,
    `CommercialData_OccupationGroup`, `CommercialData_OccupationIndustry`
  - **2025**: `ConsumerData_Occupation_of_Person`, `ConsumerData_Occupation_Group`
    only. **`OccupationIndustry` has no 2025+ successor — it is dropped
    entirely, not renamed.**
  - Year-aware handling is therefore a simple `year <= 2024` vs. `year >= 2025`
    branch, not a multi-point mapping.
  - **Open decision, not yet made:** what to do about `OccupationIndustry`
    disappearing in 2025+ (e.g., drop the feature entirely going forward vs.
    treat as structurally missing for those years). This is a modeling
    decision for the user, not something to resolve automatically.
  - **During the read-only pass, identify exactly which occupation field(s)
    the code uses (`Occupation`, `OccupationGroup`, `OccupationIndustry`, or
    some combination), where (flow-diagram match, RF features, or both), and
    report this back specifically** — don't fold it into a general field
    list, call it out on its own, since it determines whether/how the
    year-aware mapping above needs to be implemented and whether the
    `OccupationIndustry` open decision is actually consequential.
  - Do not implement the year-aware column-mapping code until the read-only
    pass has confirmed exactly which fields and pipeline stage(s) are involved.
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

- `_targets.R` — pipeline definition (root). 10 targets, no target factories, no
  `_targets.yaml`, no `tar_map`/branching. `source()`s five `code/*.R` files;
  `match_diagnostics.R` and `random_forest_match_model.R` are commented out.
  Note: uses `library(targets)` + bare `tar_target()`, not the namespaced style
  this file prescribes elsewhere.
- `code/` — all target functions plus standalone scripts, flat, organized by
  **pipeline stage via numeric prefix** (not by method). No `R/` directory.
  - `00_unzip_l2.R` — standalone, NOT a target. Unzips L2 from a mounted Yale
    `B:/` network drive into `data/rawl2/`. Hardcoded to **2018 only**.
  - `01_extract_l2.R` — `process_voter_data()`; TSV → parquet conversion.
  - `03_clean_physician_data.R` — `clean_physician_data()`; NPPES+CMS+NUCC merge.
    (There is no `02_`.)
  - `04_locality_sensitive_hash.R` — `locality_sensitive_hash()`; zoomerjoin LSH
    blocking + comparison-feature construction.
  - `05_match_model.R` — `descision_tree_matcher()` [sic]; the flow-diagram
    rules-based matcher.
  - `06_random_forest.R` — `make_X_matrix()` + `add_rf_match_predictions_to_df()`;
    the **active** RF method (`grf::probability_forest`).
  - `make_training_data.R` — standalone; samples LSH output into labeller
    partitions + writes two rule-labelled files.
  - `label.R` — standalone; interactive CLI hand-labelling + inter-coder kappa.
  - `random_forest_match_model.R` — **superseded** older RF variant (10-feature
    `agree_mat`, `load()`s an `.RData` labelled file). Not sourced.
  - `naive_bayes_match_model.R` — **dead code**; byte-for-byte identical to
    `random_forest_match_model.R` except the function name; its naive-Bayes body
    is commented out with "we no longer use naive bayes". Not sourced.
  - `match_diagnostics.R` — `make_match_diagnostic_plots()`; sourced-out/inactive.
- `data/` — **empty in git except a tracked `.gitkeep`.** All contents are
  gitignored (`data/*`, `!data/.gitkeep`); every input is placed by hand. Paths
  the pipeline expects, with sizes observed from the former DVC pointers:
  `rawl2/` (361 GB, 102 files), `NPPES_Data_Dissemination_February_2023/`
  (9.4 GB, 10 files), `DAC_NationalDownloadableFile.csv` (623 MB),
  `nucc_taxonomy_230.csv` (513 KB), `labelled_training_data/` (4 files, 812 KB),
  `unlabelled_training_data/` (3 files, 495 KB).
  - NPPES is a **manually-placed CMS dissemination file**, not NBER — see
    "NPPES data" section; nothing in the code downloads it.
  - `data/processed_voter_data/` — written at runtime by `process_voter_data()`.
  - `unlabelled_training_data/anthony.parquet` is **abandoned** — never labelled,
    not consumed by anything.
- `docs/` — mkdocs source, only three pages: `index.md` (repo layout + contacts),
  `pipeline_steps.md` (per-target prose, "Last updated 17/06/24"),
  `instructions.md` (replication steps — still DVC-based). `mkdocs.yml` at root.
  **No methodology writeup of the flow-diagram logic or the RF approach, and no
  reported performance numbers anywhere.**
- `figures/` — pipeline outputs + diagrams. `at_a_glance.png` (data-flow overview)
  and `processing.png` (**the flow-diagram decision tree** — this image is the
  closest thing to a spec for `05_match_model.R`). Also `age_dist_hist.{pdf,png}`,
  `matches_by_state.{pdf,png}`, `screenshot.png`, `targets_screenshot.PNG`.
- `dependency_graph.png` (root) — **stale** `tar_visnetwork()` export. Shows
  targets `labelled_file`, `match_diagnostic_plots`, `match_slides` that no longer
  exist in `_targets.R`.
- `.github/workflows/push_website.yml` — mkdocs-material gh-deploy on push to
  `main`/`master`. The only CI.
- Environment: `renv.lock` + `renv/activate.R` + `.Rprofile` (R deps),
  `shell.nix` (nix shell that just runs `mkdocs serve`), `.renvignore`.
  No Python in the project at all any more — no `.py`, no notebooks, no
  `requirements.txt`.

**Does not exist** (placeholder assumed these; do not reference them as if present):
`R/`, `schemas/`, `data/nppes/`, `data/l2_synthetic/`, `slurm/`, `tests/`.
There is **no test suite of any kind** (no testthat, no `tar_test`), **no SLURM
submission scripts**, and **no committed schema documentation** — the L2 schema
exists only as inline `col_types` vectors duplicated in `01_extract_l2.R` and
`04_locality_sensitive_hash.R`.

## Documentation
Methodology documentation lives in the mkdocs `docs/` source files and is the
source of truth for *why* the pipeline works the way it does — read it before
inferring methodology purely from code. If code and docs disagree, flag the
discrepancy rather than silently trusting one over the other.

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

## First-session task
Before making any code changes, do a **read-only pass**:
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
