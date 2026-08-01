# L2 lives on the HPC, partitioned state=XX/year=YYYY/month=MM/day=DD. The template
# deliberately stops at year= : a single state-year can hold several month=/day=
# extracts, and resolve_l2_extract() picks the latest at run time.
l2_path <- "/home/pg589/project_pi_cdn7/pg589/l2/transformed/vm2/uniform.parquet/state={state}/year={year}"

targets::tar_source(files = "R")

# No project-wide `packages`: every call in R/ is namespaced, so nothing needs attaching.
# The one exception is declared per-target on `scored_pairs` -- see the note there.
targets::tar_option_set(garbage_collection = TRUE,
                        # replaces the deprecated format = "file_fast"
                        trust_timestamps = TRUE)

# This determines how many threads Zoomerjoin will use
Sys.setenv(RAYON_NUM_THREADS = 30)

list(
  # The state-year grid. Crossed rather than mapped over a discovered manifest, so the
  # graph stays static and readable; state-years with no data resolve to NULL inside
  # resolve_l2_extract() and drop out of downstream aggregation on their own.
  targets::tar_target(years,
                      2018:2025,
                      iteration = "vector"),
  targets::tar_target(states,
                      sort(c(state.abb, "DC")),
                      iteration = "vector"),

  # Latest L2 extract per state-year. NULL for absent state-years (2024 MD, MS, NV).
  targets::tar_target(l2_extracts,
                      resolve_l2_extract(states, years, l2_path),
                      pattern = cross(years, states),
                      format = "file"),

  # NPPES core files from NBER, one per year, downloaded on demand. Idempotent: an
  # already-present file is returned untouched rather than re-fetched.
  targets::tar_target(nppes_core_files,
                      download_nppes_core(years),
                      pattern = map(years),
                      format = "file"),

  # Taxonomy: the four NBER extracts that are actually joinable, newest first.
  # One target rather than a branched one, so the ordering the union depends on is
  # fixed by nppes_taxonomy_urls() and cannot be shuffled by branch aggregation.
  targets::tar_target(nppes_taxonomy_files,
                      download_nppes_taxonomy(),
                      format = "file"),

  # clean physician data
  targets::tar_target(cms_file, "trunk/raw/DAC_NationalDownloadableFile.csv",
                      format = "file"),
  targets::tar_target(nucc_taxonomy_file, "trunk/raw/nucc_taxonomy_230.csv",
                      format = "file"),
  # NBER ZCTA centroid file (Census internal points), 890 KB.
  # https://data.nber.org/distance/zip/2024/centroid/gaz2024zcta5centroid.csv
  # Columns: zcta5, intptlat, intptlong. locality_sensitive_hash() computes
  # great-circle distances from these directly, which is what NBER's own distance
  # files contain -- see that function for why we compute rather than look up.
  targets::tar_target(zip_centroid_file, "trunk/raw/gaz2024zcta5centroid.csv",
                      format = "file"),

  # One physician table per year: names and addresses from that year's NBER core file,
  # taxonomy from the fixed CMS snapshot. Partitioned year=/state= so each matching
  # branch prunes to its own directory instead of scanning nationally.
  targets::tar_target(physician_data,
                      clean_physician_data(nppes_core_files, nppes_taxonomy_files,
                                           cms_file, nucc_taxonomy_file, years),
                      pattern = map(years, nppes_core_files),
                      format = "file"),

  # How much the "drop NPIs with conflicting CMS records" rule in
  # clean_physician_data() actually costs, and which field disagrees. Small, so it
  # stays in memory -- read it with targets::tar_read(cms_npi_conflicts).
  targets::tar_target(cms_npi_conflicts,
                      count_cms_npi_conflicts(cms_file)),

  # Stage A -- candidate pairs, one branch per state-year. Branches whose l2_extracts
  # entry is NULL return NULL and drop out of aggregation. Note map() still creates a
  # branch for those, so the NULL guard inside the function is doing real work.
  targets::tar_target(lsh_pairs,
                      locality_sensitive_hash(physician_data, l2_extracts,
                                              zip_centroid_file),
                      pattern = map(l2_extracts),
                      format = "file"),

  targets::tar_target(labelled_training_files,
                      list.files("trunk/raw/labelled_training_data/",
                                 full.names = TRUE),
                      format = "file"),

  # Trained once on the 2018 labels and reused for every year. Small, so in-memory.
  targets::tar_target(rf_model,
                      train_rf_model(labelled_training_files)),

  # Stage B -- physicians without a unique strong in-state match, retried against the
  # voter files of bordering states. Branches over the same state-year grid as Stage A;
  # adjacent partitions are resolved from l2_path inside the function, since a dynamic
  # branch cannot reach its siblings.
  targets::tar_target(cross_border_pairs,
                      lsh_cross_border(physician_data, l2_extracts, lsh_pairs,
                                       l2_path, zip_centroid_file),
                      pattern = map(l2_extracts),
                      format = "file"),

  # Stage C -- combine both passes for a year, compute n, then predict. Per year because
  # grf needs a materialised matrix and eight years of national pairs will not fit.
  #
  # `packages = "grf"` is the one place a package must be attached rather than namespaced,
  # and it is not decoration: score_pairs() calls predict() on an rf_model built in a
  # *different* target. S3 dispatch needs predict.probability_forest registered, which only
  # happens once grf is loaded -- and nothing in this target calls grf:: itself. Without it
  # the run dies with "no applicable method for 'predict' applied to an object of class
  # c('probability_forest', 'grf')". Verified by reproducing exactly that error.
  targets::tar_target(scored_pairs,
                      score_pairs(lsh_pairs, cross_border_pairs, rf_model, years),
                      pattern = map(years),
                      packages = "grf",
                      format = "file"),

  # Stage D -- collapse to one row per physician-year, then to one best match per
  # physician. No match_prob cutoff is applied at either step; thresholding is left to
  # whoever consumes the output.
  targets::tar_target(physician_year_panel_data,
                      physician_year_panel(scored_pairs),
                      format = "file"),

  targets::tar_target(physician_matches,
                      reconcile_physician_matches(physician_year_panel_data),
                      format = "file"),

  # The panel again, with empty physician-years filled where the identity can be carried
  # across confidently. Separate from physician_year_panel_data on purpose: the unfilled
  # panel stays available, and nothing downstream starts seeing imputed rows by accident.
  # Filled rows carry a LALVOTERID and NA for every scored attribute.
  targets::tar_target(physician_year_panel_filled,
                      fill_panel_gaps(physician_year_panel_data, physician_data,
                                      l2_extracts),
                      format = "file"),

  # How many gaps there were and why each was or was not filled. Read it before trusting
  # the filled panel -- targets::tar_read(panel_gap_summary).
  targets::tar_target(panel_gap_summary,
                      summarize_panel_gaps(physician_year_panel_data, physician_data,
                                           l2_extracts))



)

