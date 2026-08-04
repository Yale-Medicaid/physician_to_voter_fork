# L2 is partitioned state=XX/year=YYYY/month=MM/day=DD; the template stops at year=
# because resolve_l2_extract() picks the extract date at run time.
l2_path <- "/home/pg589/project_pi_cdn7/pg589/l2/transformed/vm2/uniform.parquet/state={state}/year={year}"

targets::tar_source(files = "R")

controller_primary <- crew::crew_controller_local(
  name = "my_controller_primary",
  workers = 1,
  options_local = crew::crew_options_local(log_directory = "job_outputs/",
                                           log_join = TRUE)
)

# Concurrency is a PRODUCT, not either number alone: every crew worker running an LSH join
# spawns its own Rayon pool, so what lands on the node is n_workers * lsh_nthread. With 408
# independent state-year branches, branch parallelism beats intra-branch threading, so
# nthread is 1 and the workers take the cores. Raising lsh_nthread lowers n_workers to match.
n_cores <- parallelly::availableCores()
lsh_nthread <- 1L
n_workers <- max(1L, n_cores %/% lsh_nthread)

controller_max <- crew::crew_controller_local(
  name = "my_controller_max",
  workers = n_workers,
  options_local = crew::crew_options_local(log_directory = "job_outputs/",
                                           log_join = TRUE),
  seconds_launch = 90,
  seconds_interval = 3
)

targets::tar_option_set(controller = crew::crew_controller_group(controller_primary,
                                                                 controller_max),
                        garbage_collection = TRUE,
                        # replaces the deprecated format = "file_fast"
                        trust_timestamps = TRUE)

# Every branched target fans out on controller_max; the aggregating ones materialise a whole
# year and stay on controller_primary.
on_max <- targets::tar_resources(
  crew = targets::tar_resources_crew(controller = "my_controller_max")
)

list(
  # the state-year grid
  targets::tar_target(years,
                      2018:2025,
                      iteration = "vector"),
  targets::tar_target(states,
                      sort(c(state.abb, "DC")),
                      iteration = "vector"),
  targets::tar_target(l2_extracts,
                      resolve_l2_extract(states, years, l2_path),
                      pattern = cross(years, states),
                      format = "file",
                      resources = on_max),

  # NPPES downloads. Left on controller_primary deliberately: these are one-time and
  # idempotent, so parallelism buys almost nothing, and NBER already 403s some requests.
  targets::tar_target(nppes_core_files,
                      download_nppes_core(years),
                      pattern = map(years),
                      format = "file"),
  targets::tar_target(nppes_taxonomy_files,
                      download_nppes_taxonomy(),
                      format = "file"),

  # manually placed inputs
  targets::tar_target(cms_file, "trunk/raw/DAC_NationalDownloadableFile.csv",
                      format = "file"),
  targets::tar_target(nucc_taxonomy_file, "trunk/raw/nucc_taxonomy_230.csv",
                      format = "file"),
  targets::tar_target(zip_centroid_file, "trunk/raw/gaz2024zcta5centroid.csv",
                      format = "file"),
  targets::tar_target(labelled_training_files,
                      list.files("trunk/raw/labelled_training_data/",
                                 full.names = TRUE),
                      format = "file"),

  # physician side, one table per year
  targets::tar_target(physician_data,
                      clean_physician_data(nppes_core_files, nppes_taxonomy_files,
                                           cms_file, nucc_taxonomy_file, years),
                      pattern = map(years, nppes_core_files),
                      format = "file",
                      resources = on_max),
  targets::tar_target(cms_npi_conflicts,
                      count_cms_npi_conflicts(cms_file)),

  # Stage A -- in-state candidate pairs, one branch per state-year
  targets::tar_target(lsh_pairs,
                      locality_sensitive_hash(physician_data, l2_extracts,
                                              zip_centroid_file,
                                              nthread = lsh_nthread),
                      pattern = map(l2_extracts),
                      format = "file",
                      resources = on_max),

  targets::tar_target(rf_model,
                      train_rf_model(labelled_training_files)),

  # Stage B -- unmatched physicians retried against bordering states
  targets::tar_target(cross_border_pairs,
                      lsh_cross_border(physician_data, l2_extracts, lsh_pairs,
                                       l2_path, zip_centroid_file,
                                       nthread = lsh_nthread),
                      pattern = map(l2_extracts),
                      format = "file",
                      resources = on_max),

  # Stage C -- combine both passes for a year, compute n, predict.
  # packages = "grf" is required, not decoration: score_pairs() calls predict() on a model
  # built in another target, and S3 dispatch needs grf loaded to find the method.
  targets::tar_target(scored_pairs,
                      score_pairs(lsh_pairs, cross_border_pairs, rf_model, years),
                      pattern = map(years),
                      packages = "grf",
                      format = "file"),

  # Stage D -- collapse to physician-year, then to one best match per physician
  targets::tar_target(physician_year_panel_data,
                      physician_year_panel(scored_pairs),
                      format = "file"),
  targets::tar_target(physician_matches,
                      reconcile_physician_matches(physician_year_panel_data),
                      format = "file"),

  # the panel again, with confident gaps filled
  targets::tar_target(physician_year_panel_filled,
                      fill_panel_gaps(physician_year_panel_data, physician_data,
                                      l2_extracts),
                      format = "file"),
  targets::tar_target(panel_gap_summary,
                      summarize_panel_gaps(physician_year_panel_data, physician_data,
                                           l2_extracts))
)
