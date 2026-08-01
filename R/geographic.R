#' State adjacency, for the cross-border matching pass
#'
#' @description Which states share a border, used to decide whose L2 partitions to open
#' when looking for physicians who practise in one state and live in another.
#'
#' This is a proxy for "could plausibly commute across this border", not a statement of
#' geography, so the inclusion rules are:
#' - **Land borders: in.** Including Michigan-Wisconsin, which share a real land border via
#'   the Upper Peninsula (it is often mislabelled a water border).
#' - **Water-only borders: out.** Rhode Island-New York across Block Island Sound, and the
#'   four pairs where Michigan faces another state across a Great Lake rather than touching
#'   it: MI-IL, MI-MN, MI-NY, MI-PA. Nobody commutes those.
#'   (Not to be confused with NY-PA, which is a ~300-mile land border and IS included.)
#' - **Four Corners point contacts: in.** Arizona-Colorado and New Mexico-Utah touch only
#'   at a point, but including them costs nothing -- the LSH simply finds little.
#' - **DC-Maryland and DC-Virginia: in**, and the most consequential pair in the country
#'   for this purpose.
#'
#' Alaska and Hawaii have no land neighbours and so never get a cross-border pass.
#'
#' Listed once per undirected pair;  symmetrises.
#'
#' @return a tibble of `state_a`, `state_b`
state_adjacency <- function() {
  tibble::tribble(
    ~ "state_a", ~ "state_b",
    "AL", "FL",
    "AL", "GA",
    "AL", "MS",
    "AL", "TN",
    "AR", "LA",
    "AR", "MO",
    "AR", "MS",
    "AR", "OK",
    "AR", "TN",
    "AR", "TX",
    "AZ", "CA",
    "AZ", "CO",
    "AZ", "NM",
    "AZ", "NV",
    "AZ", "UT",
    "CA", "NV",
    "CA", "OR",
    "CO", "KS",
    "CO", "NE",
    "CO", "NM",
    "CO", "OK",
    "CO", "UT",
    "CO", "WY",
    "CT", "MA",
    "CT", "NY",
    "CT", "RI",
    "DC", "MD",
    "DC", "VA",
    "DE", "MD",
    "DE", "NJ",
    "DE", "PA",
    "FL", "GA",
    "GA", "NC",
    "GA", "SC",
    "GA", "TN",
    "IA", "IL",
    "IA", "MN",
    "IA", "MO",
    "IA", "NE",
    "IA", "SD",
    "IA", "WI",
    "ID", "MT",
    "ID", "NV",
    "ID", "OR",
    "ID", "UT",
    "ID", "WA",
    "ID", "WY",
    "IL", "IN",
    "IL", "KY",
    "IL", "MO",
    "IL", "WI",
    "IN", "KY",
    "IN", "MI",
    "IN", "OH",
    "KS", "MO",
    "KS", "NE",
    "KS", "OK",
    "KY", "MO",
    "KY", "OH",
    "KY", "TN",
    "KY", "VA",
    "KY", "WV",
    "LA", "MS",
    "LA", "TX",
    "MA", "NH",
    "MA", "NY",
    "MA", "RI",
    "MA", "VT",
    "MD", "PA",
    "MD", "VA",
    "MD", "WV",
    "ME", "NH",
    "MI", "OH",
    "MI", "WI",
    "MN", "ND",
    "MN", "SD",
    "MN", "WI",
    "MO", "NE",
    "MO", "OK",
    "MO", "TN",
    "MS", "TN",
    "MT", "ND",
    "MT", "SD",
    "MT", "WY",
    "NC", "SC",
    "NC", "TN",
    "NC", "VA",
    "ND", "SD",
    "NE", "SD",
    "NE", "WY",
    "NH", "VT",
    "NJ", "NY",
    "NJ", "PA",
    "NM", "OK",
    "NM", "TX",
    "NM", "UT",
    "NV", "OR",
    "NV", "UT",
    "NY", "PA",
    "NY", "VT",
    "OH", "PA",
    "OH", "WV",
    "OK", "TX",
    "OR", "WA",
    "PA", "WV",
    "SD", "WY",
    "TN", "VA",
    "UT", "WY",
    "VA", "WV"
  )
}

#' States bordering a given state
#'
#' @param state two-letter abbreviation
#'
#' @return character vector of bordering states, empty for AK and HI
adjacent_states <- function(state) {
  adj <- state_adjacency()

  c(adj$state_b[adj$state_a == state],
    adj$state_a[adj$state_b == state]) |>
    unique() |>
    sort()
}
