#' NBER NPPES `core` file for one year
#'
#' @description NBER mirrors the NPPES dissemination files, but the layout is **not**
#' uniform across years -- there are four different schemes, and one year is truncated. The
#' URL pattern given in older documentation
#' (`/{YYYY}/{MM}/core_{YYYYMM}_csv.zip`) resolves for only three of the eight years, so the
#' table below is explicit rather than constructed from a rule.
#'
#' | Years | Layout |
#' |---|---|
#' | 2018 | `/2018/core2018{M}.*` -- flat, month **not** zero-padded |
#' | 2019 | `/2019/{MM}/core_{YYYYMM}.*` -- only months 07-12 exist |
#' | 2020-2022 | `/{YYYY}/csv/core{YYYY}{M}.*` -- format-first, month not padded |
#' | 2023 | `/2023/csv/core_{MonthName}_2023.*` (Jan-Apr) **and** `/2023/5/core_20235.*` (May) |
#' | 2024-2025 | `/{YYYY}/{MM}/core_{YYYYMM}.*` |
#'
#' An explicit table is deliberate. Rule-based construction across four schemes plus a
#' truncated year is fragile and would fail *silently* the next time NBER reorganises;
#' a listed URL that stops resolving fails loudly instead. It is also citable in a methods
#' write-up, which a rule is not.
#'
#' **Vintage: the latest month available in each year.** December for every year except
#' 2023, which stops at May -- there is no month present in all eight years (2019 starts in
#' July, 2023 ends in May), so a uniform vintage is not on offer from this source.
#'
#' **Format: parquet where it exists, CSV otherwise.** 2018 has no parquet at all, and
#' 2023's May file has none either (its January-April files do, but those are older
#' vintages). Everything else is parquet, which suits `arrow` and avoids an unzip step.
#'
#' @param year four-digit year, 2018-2025
#'
#' @return a one-row tibble of `year`, `month`, `format`, `url`
nppes_core_url <- function(year) {
  urls <- tibble::tribble(
    ~"year", ~"month", ~"format",  ~"url",
    2018L,   12L,      "csv",      "https://data.nber.org/npi/2018/core201812.csv",
    2019L,   12L,      "parquet",  "https://data.nber.org/npi/2019/12/core_201912.parquet",
    2020L,   12L,      "parquet",  "https://data.nber.org/npi/2020/csv/core202012.parquet",
    2021L,   12L,      "parquet",  "https://data.nber.org/npi/2021/csv/core202112.parquet",
    2022L,   12L,      "parquet",  "https://data.nber.org/npi/2022/csv/core202212.parquet",
    # 2023 stops at May, and the May file is CSV only -- the April file has parquet but is
    # an earlier vintage, and latest-available wins.
    2023L,    5L,      "csv",      "https://data.nber.org/npi/2023/5/core_20235.csv",
    2024L,   12L,      "parquet",  "https://data.nber.org/npi/2024/12/core_202412.parquet",
    2025L,   12L,      "parquet",  "https://data.nber.org/npi/2025/12/core_202512.parquet"
  )

  # !! not {{ }}: the embrace injects the argument *expression*, so a caller doing
  # nppes_core_url(year) would inject the symbol `year`, which the data mask resolves to
  # the column -- making the test trivially true for every row. !! injects the value.
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
#' @description Idempotent: if the file is already on disk it is returned untouched, so
#' re-running the pipeline does not re-fetch ~80 MB per year.
#'
#' @param year four-digit year
#' @param out_dir directory to download into
#' @param timeout seconds to allow; the default `options(timeout=)` of 60 is far too short
#'   for these files
#'
#' @return path to the downloaded file
download_nppes_core <- function(year, out_dir = "trunk/raw/nppes", timeout = 3600) {
  spec <- nppes_core_url(year)
  dest <- file.path(out_dir, basename(spec$url))

  if (file.exists(dest)) {
    return(dest)
  }

  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  old <- options(timeout = timeout)
  on.exit(options(old), add = TRUE)

  # download to a temporary name first, so an interrupted transfer cannot leave a
  # truncated file that the idempotency check above would then happily accept forever
  part <- paste0(dest, ".part")
  utils::download.file(spec$url, destfile = part, mode = "wb", quiet = TRUE)

  assertthat::assert_that(
    file.exists(part) && file.size(part) > 0,
    msg = cli::format_error("Downloaded an empty file from {.url {spec$url}}")
  )

  file.rename(part, dest)

  dest
}


#' Read a downloaded NPPES core file, whichever format it is in
#'
#' @description ZIP columns are forced to string. Left to type inference a CSV ZIP becomes
#' an integer and loses its leading zero -- `06510` reads back as `6510` -- which then fails
#' every ZCTA centroid lookup, silently, since the centroid table is zero-padded. Only the
#' ZIP columns need pinning; everything else infers fine.
#'
#' @param path path returned by `download_nppes_core()`
#'
#' @return an arrow Dataset
read_nppes_core <- function(path) {
  if (tools::file_ext(path) == "parquet") {
    arrow::open_dataset(path)
  } else {
    arrow::open_dataset(
      path,
      format = "csv",
      col_types = arrow::schema(ploczip = arrow::string(), pmailzip = arrow::string())
    )
  }
}
