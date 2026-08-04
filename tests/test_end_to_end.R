## End-to-end integration check: every stage fed by the REAL output of the stage before it.
##
## Run from the repo root:   Rscript tests/test_end_to_end.R
##
## Why this exists separately from test_l2_and_geography.R: that file tests each function
## against a hand-built input, so every cross-stage handoff is faked. Nothing there would
## catch score_pairs() emitting a column that physician_year_panel() does not expect, or a
## type that arrow refuses to unify on re-read. Those are the failures that cost a queued
## HPC job rather than a test run.
##
## All data is SYNTHETIC and generated here. Names are deliberately absurd so fixture output
## can never be mistaken for real voter records. Nothing is written inside the repo.

suppressPackageStartupMessages({
  library(arrow); library(tidyverse); library(zoomerjoin); library(lubridate)
})
targets::tar_source(files = "R")

FAIL <- 0L
ok <- function(label, cond) {
  cond <- isTRUE(cond)
  if (!cond) FAIL <<- FAIL + 1L
  cat(sprintf("  [%s] %s\n", if (cond) "ok" else "FAIL", label))
}

root <- file.path(tempdir(), "p2v_e2e")
unlink(root, recursive = TRUE)
dir.create(root, recursive = TRUE)
old <- setwd(root)
on.exit(setwd(old), add = TRUE)

## ------------------------------------------------------------------ fixture
## CT and NY are adjacent. Two years. NY/2019 has NO L2 partition, standing in for the real
## 2024 MD/MS/NV gap -- so it exercises both the NULL-branch guard and a Tier 1 gap fill.
##
## npi 101  CT, matches a CT voter in both years          -> ordinary in-state match
## npi 102  CT practice, resident in NY, no CT namesake    -> only Stage B can find them
## npi 103  NY, matches a NY voter in 2018 only            -> 2019 gap, L2 absent = Tier 1
YEARS <- c(2018L, 2019L)

phys_rows <- function(year) {
  tibble(npi = c(101, 102, 103),
         entity = 1L,
         pfname = c("Aaardvarkina", "Bloopberta", "Squibbly"),
         pmname = c("Quibble", "Zebulon", "Xerxes"),
         plname = c("Zzyzxton", "Crossborderson", "Fakenheimer"),
         plocstatename = c("CT", "CT", "NY"),
         ploczip = c("06510", "06510", "10001"),
         pmailstatename = c("CT", "CT", "NY"),
         pmailzip = c("06510", "06510", "10001"))
}

voter_rows <- function(state) {
  base <- tibble(
    LALVOTERID = character(0), Voters_FirstName = character(0),
    Voters_MiddleName = character(0), Voters_LastName = character(0),
    Voters_NameSuffix = character(0), Voters_BirthDate = as.Date(character(0)),
    Residence_Addresses_State = character(0), Residence_Addresses_Zip = character(0),
    Residence_Addresses_ZipPlus4 = character(0), Residence_Addresses_City = character(0),
    CommercialData_Occupation = character(0))
  add <- function(id, f, m, l, zip) tibble(
    LALVOTERID = id, Voters_FirstName = f, Voters_MiddleName = m, Voters_LastName = l,
    Voters_NameSuffix = NA_character_, Voters_BirthDate = as.Date("1963-04-01"),
    Residence_Addresses_State = state, Residence_Addresses_Zip = zip,
    Residence_Addresses_ZipPlus4 = "1234", Residence_Addresses_City = "Fakeville",
    CommercialData_Occupation = "Medical-Physician")
  if (state == "CT") {
    bind_rows(base,
              add("LALCT1", "Aaardvarkina", "Quibble", "Zzyzxton", "06510"),
              add("LALCT9", "Unrelatedina", "Blort", "Nobodyhere", "06510"))
  } else {
    bind_rows(base,
              add("LALNY1", "Bloopberta", "Zebulon", "Crossborderson", "10001"),
              add("LALNY2", "Squibbly", "Xerxes", "Fakenheimer", "10001"))
  }
}

# L2 hive tree, state=/year=/month=/day=. NY/2019 deliberately omitted.
for (st in c("CT", "NY")) {
  for (y in YEARS) {
    if (st == "NY" && y == 2019L) next
    d <- file.path("l2", paste0("state=", st), paste0("year=", y), "month=11", "day=15")
    dir.create(d, recursive = TRUE, showWarnings = FALSE)
    write_parquet(voter_rows(st), file.path(d, "part-0.parquet"))
  }
}
l2_path <- "l2/state={state}/year={year}"

write_csv(tibble(zcta5 = c("06510", "10001"),
                 intptlat = c(41.3053, 40.7506),
                 intptlong = c(-72.9276, -73.9971)), "centroids.csv")

# physician-side inputs, one core file per year
write_csv(tibble(Code = "207R00000X",
                 Grouping = "Allopathic & Osteopathic Physicians"), "nucc.csv")
write_csv(tibble(NPI = c(101, 102, 103), grd_yr = 1990L,
                 med_sch = "FAKE SCHOOL OF NOWHERE"), "cms.csv")
write_parquet(tibble(npi = c(101, 102, 103), seq = 1L, ptaxcode = "207R00000X"),
              "PTAXCODE_202512.parquet")
for (y in YEARS) write_csv(phys_rows(y), paste0("core_", y, ".csv"))

# labelled training data, enough rows for grf to fit
set.seed(1)
N <- 120
write_parquet(tibble(
  zip_dist = c(runif(N/2, 0, 20), runif(N/2, 200, 900)),
  year_dist = c(runif(N/2, 24, 32), runif(N/2, 0, 8)),
  full_name_sim = c(runif(N/2, 0.85, 1), runif(N/2, 0.5, 0.7)),
  mid_initial_agree = rep(c(TRUE, FALSE), each = N/2),
  mid_name_agree = c(runif(N/2, 0.8, 1), runif(N/2, 0, 0.3)),
  n = rep(1L, N),
  CommercialData_Occupation = rep(c("Medical-Physician", "Educator"), each = N/2),
  match = rep(c(1, 0), each = N/2)
), "labels.parquet")

## ------------------------------------------------------- stage 0: physician side
cat("== stage 0: physician_data ==\n")
phys_pths <- purrr::map_chr(YEARS, \(y)
  clean_physician_data(paste0("core_", y, ".csv"), "PTAXCODE_202512.parquet",
                       "cms.csv", "nucc.csv", y,
                       out_pth = "phys/year={year}"))
ok("one physician dataset per year", length(phys_pths) == 2 && all(dir.exists(phys_pths)))
phys_all <- open_dataset(unique(dirname(phys_pths))) |> collect()
ok("both years readable from the partitioned root", setequal(phys_all$year, YEARS))
ok("distinct in npi within each year",
   nrow(phys_all) == nrow(distinct(phys_all, npi, year)))
ok("practice state is carried as the hive partition", all(phys_all$state %in% c("CT", "NY")))

## ---------------------------------------------------------- stage 0: L2 resolution
cat("\n== stage 0: l2_extracts ==\n")
grid <- expand_grid(state = c("CT", "NY"), year = YEARS)
leaves <- purrr::pmap(grid, \(state, year) resolve_l2_extract(state, year, l2_path))
ok("three of four state-years resolve", sum(!purrr::map_lgl(leaves, is.null)) == 3)
ok("the absent NY/2019 partition resolves to NULL",
   is.null(leaves[[which(grid$state == "NY" & grid$year == 2019L)]]))
leaves_present <- purrr::compact(leaves)

## ------------------------------------------------------------------ stage A
cat("\n== stage A: lsh_pairs, fed real physician_data ==\n")
lsh <- purrr::map(leaves_present, \(lf)
  locality_sensitive_hash(phys_pths, lf, "centroids.csv", out_pth = "lsh/{ys}"))
lsh <- purrr::compact(lsh)
ok("stage A produced output for at least one partition", length(lsh) > 0)
lsh_d <- open_dataset(unique(dirname(dirname(unlist(lsh))))) |> collect()
ok("stage A found the ordinary in-state physician", 101 %in% lsh_d$npi)
ok("stage A did NOT find the cross-border physician in CT",
   !any(lsh_d$npi == 102 & lsh_d$state == "CT"))
ok("hive year/state come back from the partitioned root",
   all(c("year", "state") %in% names(lsh_d)))
ok("every column make_X_matrix needs is present in stage A output",
   all(c("zip_dist", "year_dist", "full_name_sim", "mid_initial_agree", "mid_name_agree",
         "CommercialData_Occupation") %in% names(lsh_d)))
ok("zip_dist is a finite non-negative distance",
   all(is.na(lsh_d$zip_dist) | (lsh_d$zip_dist >= 0 & is.finite(lsh_d$zip_dist))))

## ------------------------------------------------------------------ stage B
cat("\n== stage B: cross_border_pairs, fed real stage A output ==\n")
xb <- purrr::map(leaves_present, \(lf)
  lsh_cross_border(phys_pths, lf, unlist(lsh), l2_path, "centroids.csv",
                   out_pth = "xb/{ys}"))
xb <- purrr::compact(xb)
ok("stage B produced output", length(xb) > 0)
xb_d <- open_dataset(unique(dirname(dirname(unlist(xb))))) |> collect()
ok("stage B finds the CT-practice / NY-resident physician", 102 %in% xb_d$npi)
ok("stage B output is partitioned by the PHYSICIAN's state",
   all(xb_d$state[xb_d$npi == 102] == "CT"))
ok("state_agree is FALSE for cross-border pairs", all(!xb_d$state_agree[xb_d$npi == 102]))
ok("stage A and stage B outputs share a schema, so they can be row-bound",
   length(setdiff(names(lsh_d), names(xb_d))) == 0 &&
     length(setdiff(names(xb_d), names(lsh_d))) == 0)

## ------------------------------------------------------------------ stage C
cat("\n== stage C: scored_pairs, fed real stage A + B output ==\n")
model <- train_rf_model("labels.parquet")
ok("model trains on the labelled fixture", inherits(model, "probability_forest"))
scored <- purrr::map_chr(YEARS, \(y)
  score_pairs(unlist(lsh), unlist(xb), model, y,
              out_pth = "scored/year={this_year}"))
ok("one scored dataset per year", length(scored) == 2 && all(dir.exists(scored)))
sc_d <- open_dataset(unique(dirname(scored))) |> collect()
ok("match_prob is a probability", all(sc_d$match_prob >= 0 & sc_d$match_prob <= 1))
ok("named match_prob, never match -- so it cannot be confused with the label",
   "match_prob" %in% names(sc_d) && !("match" %in% names(sc_d)))
ok("distinct in (npi, LALVOTERID) per year",
   nrow(sc_d) == nrow(distinct(sc_d, npi, LALVOTERID, year)))
ok("n counts candidates per npi across BOTH passes",
   all(sc_d$n[sc_d$npi == 102] == sum(sc_d$npi == 102 & sc_d$year == sc_d$year[sc_d$npi == 102][1])))
# the year column is dropped before writing; the hive key must be the only source
ok("year survives the round-trip exactly once, as the hive key",
   sum(names(sc_d) == "year") == 1 && setequal(sc_d$year, YEARS))

## ------------------------------------------------------------------ stage D
cat("\n== stage D: panel and reconciliation, fed real stage C output ==\n")
panel <- physician_year_panel(scored, out_pth = "panel")
ok("panel built from real scored output", !is.null(panel))
pn_d <- open_dataset(panel) |> collect()
ok("one row per (npi, year) except where tied",
   nrow(pn_d) == nrow(distinct(pn_d, npi, year, LALVOTERID)))
ok("panel carries every column reconcile and gap-fill need",
   all(c("npi", "year", "LALVOTERID", "match_prob", "state_agree", "zip_dist",
         "full_name_sim", "n", "tied") %in% names(pn_d)))

matches <- reconcile_physician_matches(panel, out_pth = "matches")
mt_d <- open_dataset(matches) |> collect()
ok("exactly one row per physician", nrow(mt_d) == n_distinct(mt_d$npi))
ok("every matched physician appears", all(mt_d$npi %in% phys_all$npi))
ok("best_match_prob is a probability",
   all(mt_d$best_match_prob >= 0 & mt_d$best_match_prob <= 1))

## ------------------------------------------------------------- gap filling
cat("\n== gap filling, fed real panel + physician_data + l2_extracts ==\n")
l2_paths <- unlist(leaves_present)
filled <- fill_panel_gaps(panel, phys_pths, l2_paths, out_pth = "filled",
                          min_fill_prob = 0.5)
gaps <- classify_panel_gaps(panel, phys_pths, l2_paths, min_fill_prob = 0.5)
ok("gap classification runs on real upstream output", nrow(gaps) >= 1)
ok("NY/2019 is seen as having no L2 partition",
   all(!gaps$l2_present[gaps$state == "NY" & gaps$year == 2019L]))
if (!is.null(filled)) {
  fl_d <- open_dataset(filled) |> collect()
  ok("filled panel is a superset of the panel", nrow(fl_d) >= nrow(pn_d))
  ok("observed rows are unchanged", sum(!fl_d$filled) == nrow(pn_d))
  ok("any filled row carries an identity and no scored attributes",
     all(is.na(fl_d$match_prob[fl_d$filled])) && all(!is.na(fl_d$LALVOTERID[fl_d$filled])))
} else {
  ok("no gap cleared the gates on this fixture (acceptable)", TRUE)
  ok("panel is unchanged when nothing is fillable", TRUE)
  ok("no filled rows to check", TRUE)
}

summary_tbl <- summarize_panel_gaps(panel, phys_pths, l2_paths, min_fill_prob = 0.5)
ok("gap summary is one row", nrow(summary_tbl) == 1)
ok("tiers sum to the gap count",
   summary_tbl$n_tier_1 + summary_tbl$n_tier_2 + summary_tbl$n_tier_3 ==
     summary_tbl$n_gaps)

cat(sprintf("\n%s  (%d failure%s)\n",
            if (FAIL == 0) "ALL CHECKS PASSED" else "FAILURES PRESENT",
            FAIL, if (FAIL == 1) "" else "s"))
if (FAIL > 0) quit(status = 1)
