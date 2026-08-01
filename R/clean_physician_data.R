#' Physician-side inputs for one year
#'
#' @description Combines three sources into one row per NPI for a single year:
#'
#' - **NBER `core`** (per year) -- names and addresses. This is the only per-year source;
#'   it is what makes the physician side vary across the panel.
#' - **NBER `ptaxcode`**, four extracts unioned newest-first -- taxonomy code. NBER's `core`
#'   has no taxonomy field, and only four of the eight years publish a joinable one. See
#'   `nppes_taxonomy_urls()` for which and why.
#' - **NUCC crosswalk** and **CMS Physician Compare** -- taxonomy descriptions, and
#'   graduation year / medical school.
#'
#' **Address.** State and ZIP come from the *practice location* (`plocstatename`,
#' `ploczip`), falling back to the mailing address where practice is missing. Practice
#' location is what `zip_dist` is meant to measure distance from -- a mailing address can be
#' a billing office or a PO box. `addr_source` records which was used, since a column whose
#' meaning varies by row should say so.
#'
#' Note the pipeline previously used the mailing address throughout, which never matched
#' what `figures/processing.png` described.
#'
#' @param nppes_core_file per-year NBER core file from `download_nppes_core()`
#' @param taxonomy_files NBER ptaxcode files from `download_nppes_taxonomy()`
#' @param cms_file CMS Physician Compare csv (grd_yr, med_sch)
#' @param nucc_file NUCC taxonomy crosswalk
#' @param year the year being built
#' @param out_pth glue template; output is partitioned `year=/state=`
#'
#' @return `out_pth` -- one row per NPI, asserted distinct
clean_physician_data <- function(nppes_core_file, taxonomy_files, cms_file, nucc_file, year,
                                 out_pth = "trunk/derived/physician_data/year={year}") {
  out_pth <- glue::glue(out_pth)
  unlink(out_pth, recursive = TRUE)

  cms_raw <- readr::read_csv(cms_file, show_col_types = FALSE) |>
    dplyr::rename_with(tolower) |>
    dplyr::select(npi, grd_yr, med_sch) |>
    dplyr::distinct()

  conflicted_npi <- cms_raw |>
    dplyr::count(npi) |>
    dplyr::filter(n > 1) |>
    dplyr::select(npi)

  cms_data <- dplyr::anti_join(cms_raw, conflicted_npi, by = dplyr::join_by(npi))

  taxonomy <- read_taxonomy_union(taxonomy_files)

  nucc_data <- readr::read_csv(nucc_file, show_col_types = FALSE) |>
    dplyr::rename_with(~tolower(gsub(" ", "_", .x)))

  providers <- read_nppes_core(nppes_core_file) |>
    dplyr::select(npi, entity, pfname, pmname, plname,
                  plocstatename, ploczip, pmailstatename, pmailzip) |>
    dplyr::filter(entity == 1) |>
    dplyr::collect() |>
    dplyr::mutate(
      addr_source = dplyr::if_else(!is.na(plocstatename) & plocstatename != "",
                                   "practice", "mailing"),
      state = dplyr::if_else(addr_source == "practice", plocstatename, pmailstatename),
      zip = dplyr::if_else(addr_source == "practice", ploczip, pmailzip)
    ) |>
    dplyr::select(npi, provider_first_name = pfname, provider_middle_name = pmname,
                  provider_last_name = plname, state, zip, addr_source)

  full_data <- providers |>
    dplyr::mutate(npi = as.numeric(npi)) |>
    dplyr::anti_join(conflicted_npi, by = dplyr::join_by(npi)) |>
    dplyr::left_join(taxonomy, by = dplyr::join_by(npi)) |>
    dplyr::left_join(nucc_data, by = dplyr::join_by(taxonomy_code == code)) |>
    dplyr::left_join(cms_data, by = dplyr::join_by(npi)) |>
    dplyr::filter(grouping == "Allopathic & Osteopathic Physicians") |>
    dplyr::mutate(year = as.integer(year))

  arrow::write_dataset(full_data, out_pth, partitioning = "state")

  return_out_pth_check_distinct(out_pth, distinct_col = "npi")
}


#' Count NPIs carrying conflicting CMS records
#'
#' @description `clean_physician_data()` drops any NPI with more than one
#' (grd_yr, med_sch) combination. This measures how much that costs, and which field is
#' responsible -- two graduation years is a different data-quality story from two medical
#' schools. Small, so it stays an in-memory target: `targets::tar_read(cms_npi_conflicts)`.
#'
#' @param cms_file path to the CMS Physician Compare csv
#'
#' @return a one-row tibble of counts and shares
count_cms_npi_conflicts <- function(cms_file) {
  readr::read_csv(cms_file, show_col_types = FALSE) |>
    dplyr::rename_with(tolower) |>
    dplyr::select(npi, grd_yr, med_sch) |>
    dplyr::distinct() |>
    dplyr::group_by(npi) |>
    dplyr::summarize(
      n_rows = n(),
      n_grd_yr = dplyr::n_distinct(grd_yr),
      n_med_sch = dplyr::n_distinct(med_sch),
      .groups = "drop"
    ) |>
    dplyr::summarize(
      n_npi = n(),
      n_conflicting = sum(n_rows > 1),
      pct_conflicting = n_conflicting/n_npi,
      max_rows_per_npi = max(n_rows),
      n_grd_yr_only = sum(n_rows > 1 & n_grd_yr > 1 & n_med_sch == 1),
      n_med_sch_only = sum(n_rows > 1 & n_grd_yr == 1 & n_med_sch > 1),
      n_both = sum(n_rows > 1 & n_grd_yr > 1 & n_med_sch > 1)
    )
}
