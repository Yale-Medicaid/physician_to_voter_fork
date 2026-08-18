#' L2 columns to carry into the export
#'
#' @description **This is the list to edit when the downstream project wants another
#' attribute.** `export_voter_attributes()` pulls exactly these from the L2 partition, so
#' adding a field here is the whole change -- no other target depends on it.
#'
#' Anything absent from a given year's L2 is filled with `NA` rather than erroring, since the
#' schema is not stable across 2018-2025 (see the L2 schema notes in CLAUDE.md).
#'
#' @return character vector of L2 column names
l2_export_columns <- function() {
  c(
    "LALVOTERID",
    # sex
    "Voters_Gender",
    # race/ethnicity -- see race_source() for which of these is reported vs modelled
    "Ethnic_Description", "EthnicGroups_EthnicGroup1Desc",
    "CountyEthnic_LALEthnicCode", "CountyEthnic_Description",
    # party
    "Parties_Description",
    # home address
    "Residence_Addresses_AddressLine", "Residence_Addresses_City",
    "Residence_Addresses_State", "Residence_Addresses_Zip",
    "Residence_Addresses_ZipPlus4"
  )
}


#' Where L2's party affiliation comes from, by state
#'
#' @description Transcribed from L2's own "State by State Partisanship (Party)" document
#' (`l2-data.com`, September 2024). Three regimes:
#'
#' | `party_source` | Meaning |
#' | --- | --- |
#' | `registered` | voters register by party and the state reports that choice in its voter file |
#' | `primary_ballot` | no party registration; L2 infers from primary ballot choice, supplemented by modelling |
#' | `modeled` | the state provides nothing party-related; L2 assigns from analytics and commercial data |
#'
#' Only `registered` is administrative. The other two are L2's estimate, and in several
#' `primary_ballot` states L2 states that race -- self-reported where the state collects it,
#' modelled otherwise -- is a major input to that estimate. That matters if the downstream
#' analysis regresses party on race: in those states the two are not independent measurements.
#'
#' NJ and VT are transcribed from the document's introductory examples rather than their own
#' entries, which the text extraction merged into the preamble. Verify those two against the
#' source before relying on them.
#'
#' @return a tibble of `state`, `party_source`
l2_party_source <- function() {
  registered <- c("AK", "AR", "AZ", "CA", "CO", "CT", "DC", "DE", "FL", "IA", "ID", "KS",
                  "KY", "LA", "MA", "MD", "ME", "NC", "NE", "NH", "NJ", "NM", "NV", "NY",
                  "OK", "OR", "PA", "RI", "SD", "UT", "WV", "WY")
  primary_ballot <- c("GA", "IL", "IN", "MI", "MS", "OH", "SC", "TN", "TX", "VA", "WA")
  modeled <- c("AL", "HI", "MN", "MO", "MT", "ND", "VT", "WI")

  tibble::tibble(state = c(registered, primary_ballot, modeled),
                 party_source = c(rep("registered", length(registered)),
                                  rep("primary_ballot", length(primary_ballot)),
                                  rep("modeled", length(modeled))))
}


#' Voter attributes for each matched physician-year
#'
#' @description One row per (npi, year) for the physician's best match, with the L2 attributes
#' the downstream project needs, joined back from the L2 partition itself rather than from
#' anything the matching stages happened to carry. That is what lets `l2_export_columns()` be
#' the single place to add a field later.
#'
#' Branches over `l2_extracts`, so each branch reads one state-year and joins it to that
#' year's matches on `LALVOTERID`. A voter appears in exactly one state's partition per year,
#' so the branches partition the matches between them without overlap -- including
#' cross-border matches, which land in the branch for the state the *voter* lives in.
#'
#' @section Filled rows:
#'
#' Rows carried over by `fill_panel_gaps()` have a `LALVOTERID` but were never scored. They
#' are kept, and they do get real attributes wherever the voter is present in that year's L2 --
#' which is the case for tier 2 fills. Tier 1 fills exist precisely because that state-year has
#' no L2 partition, so their attributes are `NA` and no branch can supply them. `filled` and
#' `fill_tier` distinguish the cases; `match_prob` is `NA` for every filled row.
#'
#' @section Provenance flags:
#'
#' `race_source` is derived per row: `voter_file` where L2's `CountyEthnic_Description` is
#' populated, which is the field carrying state-reported ethnicity where a state collects it,
#' and `modeled` otherwise -- `Ethnic_Description` and `EthnicGroups_EthnicGroup1Desc` are
#' L2's own estimate. `party_source` comes from `l2_party_source()` and is a property of the
#' state, not the row.
#'
#' @param panel path to `physician_year_panel_filled`
#' @param l2_extract one resolved L2 leaf, or `NULL` for an absent state-year
#' @param out_pth glue template; output is partitioned `year=/state=` by the VOTER's state
#'
#' @return `out_pth`, or `NULL` if this state-year has no matches
export_voter_attributes <- function(panel, l2_extract,
                                    out_pth = "trunk/derived/voter_export/{ys}") {
  if (rlang::is_empty(panel) || rlang::is_empty(l2_extract)) {
    return(NULL)
  }

  yr <- get_l2_year(l2_extract)
  ys <- build_l2_out_subdir(l2_extract)
  out_pth <- glue::glue(out_pth)
  unlink(out_pth, recursive = TRUE)

  # one row per npi-year: the best scored candidate, or the filled row where there is one.
  # Filled and scored never coexist for the same npi-year, so this cannot mix them.
  best <- arrow::open_dataset(panel) |>
    dplyr::filter(year == !!yr) |>
    dplyr::select(dplyr::any_of(c("npi", "year", "LALVOTERID", "match_prob",
                                  "filled", "fill_tier"))) |>
    dplyr::collect()

  if (nrow(best) == 0) {
    return(NULL)
  }

  best <- best |>
    dplyr::arrange(dplyr::desc(match_prob), LALVOTERID) |>
    dplyr::group_by(npi, year) |>
    dplyr::slice_head(n = 1) |>
    dplyr::ungroup()

  attrs <- arrow::open_dataset(l2_extract) |>
    dplyr::select(dplyr::any_of(l2_export_columns())) |>
    dplyr::filter(LALVOTERID %in% best$LALVOTERID) |>
    dplyr::collect()

  if (nrow(attrs) == 0) {
    return(NULL)
  }

  # any_of() above means a column missing from this year's L2 is simply absent; add it back as
  # NA so every partition writes the same schema and the pieces re-read as one dataset
  missing <- setdiff(l2_export_columns(), names(attrs))
  for (m in missing) {
    attrs[[m]] <- NA_character_
  }

  out <- best |>
    dplyr::inner_join(attrs, by = dplyr::join_by(LALVOTERID)) |>
    dplyr::left_join(l2_party_source(),
                     by = dplyr::join_by(Residence_Addresses_State == state)) |>
    dplyr::mutate(
      race_source = dplyr::if_else(!is.na(CountyEthnic_Description) &
                                     CountyEthnic_Description != "",
                                   "voter_file", "modeled")
    )

  if (nrow(out) == 0) {
    return(NULL)
  }

  arrow::write_dataset(out, out_pth)

  return_out_pth_check_distinct(out_pth, distinct_col = c("npi", "year"))
}
