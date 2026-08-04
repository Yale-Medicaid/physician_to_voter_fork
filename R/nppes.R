#' NBER NPPES `core` file for one year
#'
#' @description An explicit table, not a constructed URL: NBER uses four different layouts
#' across 2018-2025 and the documented pattern resolves for only three years. Vintage is the
#' latest month available per year (December, except 2023 which stops at May), and format is
#' parquet where it exists. A rule would fail silently on the next reorganisation; a listed
#' URL that stops resolving fails loudly. See CLAUDE.md.
#'
#' @param year four-digit year, 2018-2025
#'
#' @return a one-row tibble of `year`, `month`, `format`, `url`
nppes_core_url <- function(year) {
  urls <- tibble::tribble(
    ~ "year", ~ "month", ~ "format", ~ "url",
    2018L, 12L, "csv", "https://data.nber.org/npi/2018/core201812.csv",
    2019L, 12L, "parquet", "https://data.nber.org/npi/2019/12/core_201912.parquet",
    2020L, 12L, "parquet", "https://data.nber.org/npi/2020/csv/core202012.parquet",
    2021L, 12L, "parquet", "https://data.nber.org/npi/2021/csv/core202112.parquet",
    2022L, 12L, "parquet", "https://data.nber.org/npi/2022/csv/core202212.parquet",
    2023L, 5L, "csv", "https://data.nber.org/npi/2023/5/core_20235.csv",
    2024L, 12L, "parquet", "https://data.nber.org/npi/2024/12/core_202412.parquet",
    2025L, 12L, "parquet", "https://data.nber.org/npi/2025/12/core_202512.parquet"
  )

  # !! not {{ }}: the embrace would resolve `year` to the column, matching every row
  out <- dplyr::filter(urls, year == !!year)

  assertthat::assert_that(
    nrow(out) == 1,
    msg = cli::format_error(c(
      "No NPPES {.pkg core} file is listed for {.val {year}}",
      "i" = "Years covered: {.val {sort(urls$year)}}",
      ">" = "Add a row to {.fn nppes_core_url} if NBER now publishes it."
    ))
  )

  out
}


#' Download one year's NPPES core file
#'
#' @description Idempotent, so re-running does not re-fetch ~80 MB per year.
#'
#' @param year four-digit year
#' @param out_dir directory to download into
#' @param timeout seconds to allow; the default `options(timeout=)` of 60 is far too short
#'   for these files
#'
#' @return path to the downloaded file
download_nppes_core <- function(year, out_dir = "trunk/raw/nppes", timeout = 3600) {
  download_nber_file(nppes_core_url(year)$url, out_dir = out_dir, timeout = timeout)
}


#' NBER taxonomy (`ptaxcode`) extracts
#'
#' @description From NBER rather than CMS, so every NPPES input comes from one static
#' archive. Only four of the eight years are usable and that is the source's doing, not a
#' choice -- 2018 publishes none, 2020 returns 403, and 2021/2022 ship without an `npi`
#' column. Listed newest-first, so the most recent designation wins. See CLAUDE.md for the
#' per-year detail and the residual coverage gap.
#'
#' @return a tibble of `vintage`, `url`, newest first
nppes_taxonomy_urls <- function() {
  tibble::tribble(
    ~ "vintage", ~ "url",
    "2025-12", "https://data.nber.org/npi/2025/12/byvar/PTAXCODE_202512.parquet",
    "2024-12", "https://data.nber.org/npi/2024/12/byvar/PTAXCODE_202412.parquet",
    "2023-05", "https://data.nber.org/npi/2023/5/ptaxcode_20235.csv",
    "2019-12", "https://data.nber.org/npi/2019/12/byvar/PTAXCODE_201912.parquet"
  )
}


#' Download every usable NBER taxonomy extract
#'
#' @param out_dir directory to download into
#' @param timeout seconds to allow per file
#'
#' @return paths, newest vintage first
download_nppes_taxonomy <- function(out_dir = "trunk/raw/nppes", timeout = 3600) {
  nppes_taxonomy_urls()$url |>
    purrr::map_chr(\(u) download_nber_file(u, out_dir = out_dir, timeout = timeout))
}


#' Read and union the taxonomy extracts, most recent designation winning
#'
#' @description Sorts by vintage internally, so a caller cannot invert the precedence.
#' `seq == 1` selects the primary taxonomy and is also mechanically required -- without it
#' the downstream join would duplicate providers.
#'
#' @param paths taxonomy files from `download_nppes_taxonomy()`
#'
#' @return a tibble of `npi`, `taxonomy_code`, one row per NPI
read_taxonomy_union <- function(paths) {
  order <- nppes_taxonomy_urls() |>
    dplyr::mutate(file = basename(url)) |>
    dplyr::arrange(dplyr::desc(vintage))

  ordered <- tibble::tibble(path = paths, file = basename(paths)) |>
    dplyr::inner_join(order, by = dplyr::join_by(file)) |>
    dplyr::arrange(dplyr::desc(vintage)) |>
    dplyr::pull(path)

  ordered |>
    purrr::map(\(pth) {
      ds <- if (tools::file_ext(pth) == "parquet") {
        arrow::open_dataset(pth)
      } else {
        arrow::open_dataset(pth, format = "csv")
      }

      ds |>
        dplyr::filter(seq == 1) |>
        dplyr::select(npi, taxonomy_code = ptaxcode) |>
        dplyr::collect() |>
        # npi arrives as int64 from parquet and double from csv; unify before binding
        dplyr::mutate(npi = as.numeric(npi))
    }) |>
    purrr::list_rbind() |>
    dplyr::distinct(npi, .keep_all = TRUE)
}


#' Fetch a file from NBER, once
#'
#' @description Idempotent. Downloads land on a `.part` name first, so an interrupted
#' transfer cannot leave a truncated file that the check would accept forever.
#'
#' @param url file to fetch
#' @param out_dir directory to download into
#' @param timeout seconds to allow; the default `options(timeout=)` of 60 is far too short
#'
#' @return path to the downloaded file
download_nber_file <- function(url, out_dir = "trunk/raw/nppes", timeout = 3600) {
  dest <- file.path(out_dir, basename(url))

  if (file.exists(dest)) {
    return(dest)
  }

  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  old <- options(timeout = timeout)
  on.exit(options(old), add = TRUE)

  part <- paste0(dest, ".part")
  utils::download.file(url, destfile = part, mode = "wb", quiet = TRUE)

  assertthat::assert_that(
    file.exists(part) && file.size(part) > 0,
    msg = cli::format_error("Downloaded an empty file from {.url {url}}")
  )

  file.rename(part, dest)

  dest
}


#' Read a downloaded NPPES core file, whichever format it is in
#'
#' @description ZIP columns are pinned to string. Inference turns `06510` into `6510`, which
#' then fails every ZCTA lookup silently.
#'
#' @param path path returned by `download_nppes_core()`
#'
#' @return an arrow Dataset
read_nppes_core <- function(path) {
  if (tools::file_ext(path) == "parquet") {
    arrow::open_dataset(path)
  } else {
    arrow::open_dataset(path,
                        format = "csv",
                        col_types = arrow::schema(ploczip = arrow::string(),
                                                  pmailzip = arrow::string()))
  }
}
