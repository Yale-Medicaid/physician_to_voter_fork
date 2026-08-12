#' URL for the NUCC taxonomy crosswalk
#'
#' @description Pinned to version 23.0 deliberately, matching the file the pipeline has always
#' used. Newer releases exist (24.1, 25.0, 25.1, 26.1 at time of writing) and the URL pattern
#' is predictable, but bumping the version changes **which taxonomy codes carry the
#' `Allopathic & Osteopathic Physicians` grouping** -- that is the physician filter in
#' `clean_physician_data()`, so it is a data decision rather than a plumbing one. Change it
#' knowingly, and re-check the resulting provider count.
#'
#' Note NUCC's version numbers are not a dense sequence: 25.2 and 26.0 both 404 while 26.1
#' resolves, so a "fetch the newest" rule would have to probe and would still guess wrong.
#'
#' @return a single URL
nucc_taxonomy_url <- function() {
  "https://www.nucc.org/images/stories/CSV/nucc_taxonomy_230.csv"
}


#' URL for the NBER ZCTA centroid file
#'
#' @description Census ZCTA internal points, ~890 KB. `locality_sensitive_hash()` computes
#' great-circle distances from these rather than downloading one of NBER's pre-computed
#' distance files -- see that function for why.
#'
#' Centroid files exist for 2019-2024 while the panel spans 2018-2025. ZCTA internal points
#' move little year to year, so one file is used for every year.
#'
#' @return a single URL
zip_centroid_url <- function() {
  "https://data.nber.org/distance/zip/2024/centroid/gaz2024zcta5centroid.csv"
}


#' Resolve the current URL for the CMS Doctors and Clinicians national downloadable file
#'
#' @description Unlike the other two, this one cannot be pinned. CMS embeds a content hash and
#' a timestamp in the path:
#'
#' ```
#' .../resources/52c3f098d7e56028a298fd297cb0b38d_1782750575/DAC_NationalDownloadableFile.csv
#' ```
#'
#' Both change with every release, so a hardcoded URL would 404 within months. The dataset
#' identifier `mj5m-pzi6` is stable, and the metastore API returns the live download URL for
#' it. Note the API answers automated requests even though the human-facing download pages
#' return 403.
#'
#' **This makes the CMS input a moving target.** The pipeline gets whatever CMS currently
#' publishes, so `grd_yr` and `med_sch` -- and therefore `year_dist`, and therefore matches --
#' can change between runs without anything in this repository changing. `download_once()`
#' will not re-fetch a file already on disk, so in practice a given `trunk/raw/` stays fixed
#' until someone deletes it. Delete it deliberately, not incidentally.
#'
#' @param dataset_id CMS provider-data dataset identifier
#' @param timeout seconds to allow for the metadata request
#'
#' @return a single URL
cms_dac_url <- function(dataset_id = "mj5m-pzi6", timeout = 300) {
  api <- paste0("https://data.cms.gov/provider-data/api/1/metastore/schemas/dataset/items/",
                dataset_id, "?show-reference-ids=true")

  old <- options(timeout = timeout)
  on.exit(options(old), add = TRUE)

  meta <- jsonlite::fromJSON(api, simplifyVector = FALSE)
  dists <- meta$distribution

  urls <- vapply(dists,
                 \(d) {
                   inner <- if (!is.null(d$data)) d$data else d
                   u <- inner$downloadURL
                   if (is.null(u)) NA_character_ else as.character(u)
                 },
                 character(1))
  urls <- urls[!is.na(urls) & grepl("[.]csv$", urls)]

  assertthat::assert_that(
    length(urls) >= 1,
    msg = cli::format_error(c(
      "No CSV distribution found for CMS dataset {.val {dataset_id}}",
      "i" = "Checked {.url {api}}",
      ">" = "The metastore response shape may have changed; inspect it by hand."
    ))
  )

  urls[[1]]
}


#' Download the NUCC taxonomy crosswalk
#'
#' @inheritParams download_once
#'
#' @return path to the downloaded csv
download_nucc_taxonomy <- function(out_dir = "trunk/raw", timeout = 3600) {
  download_once(nucc_taxonomy_url(), out_dir = out_dir, timeout = timeout)
}


#' Download the NBER ZCTA centroid file
#'
#' @inheritParams download_once
#'
#' @return path to the downloaded csv
download_zip_centroids <- function(out_dir = "trunk/raw", timeout = 3600) {
  download_once(zip_centroid_url(), out_dir = out_dir, timeout = timeout)
}


#' Download the CMS Doctors and Clinicians national downloadable file
#'
#' @description Roughly 600 MB, so the generous default timeout matters. Idempotent, like the
#' others -- and see `cms_dac_url()` for why that idempotency is load-bearing here rather than
#' merely convenient.
#'
#' @inheritParams download_once
#'
#' @return path to the downloaded csv
download_cms_dac <- function(out_dir = "trunk/raw", timeout = 7200) {
  download_once(cms_dac_url(), out_dir = out_dir, timeout = timeout)
}
