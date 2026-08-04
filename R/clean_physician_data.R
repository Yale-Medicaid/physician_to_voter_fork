#' Physician-side inputs for one year
#'
#' @description One row per NPI, from NBER `core` (the only per-year source), NBER
#' `ptaxcode`, the NUCC crosswalk, and the CMS Physician Compare file. State and ZIP come
#' from the *practice* location, falling back to mailing, with `addr_source` recording which
#' was used. An NPI with conflicting CMS records is dropped entirely. See CLAUDE.md.
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
#' @description How much the drop-conflicting-NPIs rule costs, and which field disagrees.
#' In-memory: `targets::tar_read(cms_npi_conflicts)`.
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
      n_rows = dplyr::n(),
      n_grd_yr = dplyr::n_distinct(grd_yr),
      n_med_sch = dplyr::n_distinct(med_sch),
      .groups = "drop"
    ) |>
    dplyr::summarize(
      n_npi = dplyr::n(),
      n_conflicting = sum(n_rows > 1),
      pct_conflicting = n_conflicting/n_npi,
      max_rows_per_npi = max(n_rows),
      n_grd_yr_only = sum(n_rows > 1 & n_grd_yr > 1 & n_med_sch == 1),
      n_med_sch_only = sum(n_rows > 1 & n_grd_yr == 1 & n_med_sch > 1),
      n_both = sum(n_rows > 1 & n_grd_yr > 1 & n_med_sch > 1)
    )
}
