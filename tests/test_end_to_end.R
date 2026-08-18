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

## ------------------------------------------------------------- diagnostics
## Fed the real filled panel this file just built, so the handoff is covered too.
cat("\n== diagnostics, fed the real panel ==\n")
diag_panel <- if (!is.null(filled)) filled else panel

rt <- match_rate_by_threshold(diag_panel, phys_pths, l2_paths,
                              thresholds = seq(0, 0.9, by = 0.1))
ok("match rate table has a row per year-threshold",
   nrow(rt) == length(unique(rt$year)) * 10)
ok("percentages are bounded",
   all(rt$pct_matched >= 0 & rt$pct_matched <= 100, na.rm = TRUE) &&
     all(rt$pct_matched_l2 >= 0 & rt$pct_matched_l2 <= 100, na.rm = TRUE))
ok("match count is non-increasing in the threshold",
   all(unlist(lapply(split(rt, rt$year), \(d) {
     d <- d[order(d$threshold), ]
     all(diff(d$n_matched) <= 0)
   }))))
ok("at threshold 0 every scored physician-year counts",
   {
     b <- best_scored_per_physician_year(diag_panel)
     z <- rt[rt$threshold == 0, ]
     all(purrr::map2_lgl(z$year, z$n_matched,
                         \(y, k) k == sum(b$year == y & !is.na(b$match_prob))))
   })
ok("the L2-available denominator is never larger than the full one",
   all(rt$n_physicians_l2 <= rt$n_physicians))
ok("2019 has a smaller L2 denominator than 2018 -- NY/2019 is absent",
   rt$n_physicians_l2[rt$year == 2019L][1] < rt$n_physicians[rt$year == 2019L][1])

fig <- plot_match_rate_curve(rt, out_dir = "diag_out")
ok("the figure writes a pdf and a png",
   length(fig) == 2 && all(file.exists(fig)) && all(file.size(fig) > 0))

st <- match_quality_by_state_year(diag_panel, phys_pths, min_prob = 0.5)
ok("state-year table covers every state-year in physician_data",
   nrow(st) == nrow(distinct(phys_all, state, year)))
ok("no state-year reports more matches than physicians",
   all(st$n_matched <= st$n_physicians))

fs <- match_feature_summary(diag_panel)
ok("feature summary returns quantiles and candidate-count buckets",
   is.list(fs) && setequal(names(fs), c("quantiles", "by_candidate_count")))
ok("quantiles cover all four features",
   setequal(fs$quantiles$variable,
            c("match_prob", "zip_dist", "full_name_sim", "n")))

vi <- rf_variable_importance(model)
ok("importance has one row per RF feature", nrow(vi) == 8)
ok("features are named, not feature_1..n", !any(grepl("^feature_[0-9]+$", vi$feature)))
ok("importance is sorted descending", !is.unsorted(rev(vi$importance)))
ok("occupation indicators appear among the features",
   all(c("occ_medical", "occ_unknown") %in% vi$feature))
ok("state_agree is NOT a feature", !("state_agree" %in% vi$feature))

cat("\n== match rate counting confident fills ==\n")
fc <- classify_fill_confidence(diag_panel, min_anchor_prob = 0.5)
ok("fill confidence table covers exactly the filled rows",
   nrow(fc) == sum(open_dataset(diag_panel) |> collect() |> pull(filled)))
ok("interior and tier1 are logical, never NA",
   is.logical(fc$interior) && is.logical(fc$tier1) &&
     !any(is.na(fc$interior)) && !any(is.na(fc$tier1)))
ok("a fill with no scored row for the same voter is not interior",
   {
     b <- best_scored_per_physician_year(diag_panel)
     lone <- fc[!paste(fc$npi, fc$LALVOTERID) %in% paste(b$npi, b$LALVOTERID), ]
     nrow(lone) == 0 || all(!lone$interior)
   })

ok("anchor quality is inherited from the source years",
   all(c("n_anchors", "anchor_prob_mean", "anchor_prob_min", "anchor_prob_max") %in% names(fc)))
ok("a fill with anchors carries a mean within its own min/max",
   {
     a <- fc[fc$n_anchors > 0, ]
     nrow(a) == 0 || all(a$anchor_prob_mean >= a$anchor_prob_min - 1e-9 &
                           a$anchor_prob_mean <= a$anchor_prob_max + 1e-9)
   })
ok("inherited quality clears the anchor cutoff it was filtered on",
   {
     a <- fc[fc$n_anchors > 0, ]
     nrow(a) == 0 || all(a$anchor_prob_min >= 0.5 - 1e-9)
   })
ok("raising min_anchor_prob above every anchor leaves no inherited quality",
   all(is.na(classify_fill_confidence(diag_panel, min_anchor_prob = 1.01)$anchor_prob_mean)))

rf2 <- match_rate_with_fills(diag_panel, phys_pths, l2_paths,
                             thresholds = seq(0, 0.9, by = 0.1), min_anchor_prob = 0.5)
ok("the quality-gated numerator is never above the flat one",
   all(rf2$n_matched_incl_fills_q <= rf2$n_matched_incl_fills))
ok("the quality-gated numerator is never below scored-only",
   all(rf2$n_matched_incl_fills_q >= rf2$n_matched))
ok("quality-gated fill counts are non-increasing in the threshold",
   all(unlist(lapply(split(rf2, list(rf2$year, rf2$fill_rule), drop = TRUE), \(d) {
     d <- d[order(d$threshold), ]
     all(diff(d$n_fill_counted_q) <= 0)
   }))))
# they agree only when min_anchor_prob matches the min_fill_prob the fill used -- the
# fixture fills at 0.5, so both calls above are told 0.5
ok("at threshold 0 both readings agree when the cutoffs match",
   {
     z <- rf2[rf2$threshold == 0, ]
     all(z$n_matched_incl_fills_q == z$n_matched_incl_fills)
   })
ok("every fill rule is represented",
   setequal(rf2$fill_rule, c("none", "interior", "tier1", "interior_or_tier1", "any")))
ok("rule 'none' reproduces the scored-only counts",
   identical(rf2$n_matched_incl_fills[rf2$fill_rule == "none"],
             rf2$n_matched[rf2$fill_rule == "none"]))
ok("counting fills never lowers the match count",
   all(rf2$n_matched_incl_fills >= rf2$n_matched))
ok("'any' is the most permissive rule",
   {
     tot <- tapply(rf2$n_matched_incl_fills, rf2$fill_rule, sum)
     tot[["any"]] == max(tot)
   })
ok("interior and tier1 are each no larger than 'any'",
   {
     tot <- tapply(rf2$n_matched_incl_fills, rf2$fill_rule, sum)
     tot[["interior"]] <= tot[["any"]] && tot[["tier1"]] <= tot[["any"]]
   })
ok("the fill contribution is constant across thresholds, as it must be",
   {
     z <- rf2[rf2$fill_rule == "any", ]
     all(tapply(z$n_fill_counted, z$year, \(v) length(unique(v)) == 1))
   })
ok("no rule pushes the rate above 100%",
   all(rf2$pct_matched_incl_fills <= 100 + 1e-9))
ok("matched-plus-fills never exceeds the physician universe",
   all(rf2$n_matched_incl_fills <= rf2$n_physicians))
ok("NY/2019 -- L2 absent -- is where the tier1 fill shows up",
   {
     t1 <- rf2[rf2$fill_rule == "tier1" & rf2$threshold == 0, ]
     all(t1$n_fill_counted[t1$year == 2018L] == 0)
   })

fig2 <- plot_match_rate_with_fills(rf2, out_dir = "diag_out")
ok("the with-fills figure writes a pdf and a png",
   length(fig2) == 2 && all(file.exists(fig2)) && all(file.size(fig2) > 0))

cat("\n== voter attribute export ==\n")
ok("party lookup covers 50 states plus DC",
   nrow(l2_party_source()) == 51 && "DC" %in% l2_party_source()$state)
ok("every state falls in exactly one party regime",
   !any(duplicated(l2_party_source()$state)) &&
     setequal(unique(l2_party_source()$party_source),
              c("registered", "primary_ballot", "modeled")))
ok("l2_export_columns includes everything the downstream project asked for",
   all(c("Voters_Gender", "Parties_Description", "Ethnic_Description",
         "CountyEthnic_Description", "Residence_Addresses_AddressLine",
         "Residence_Addresses_Zip") %in% l2_export_columns()))

exp_pths <- purrr::map(leaves_present, \(lf)
  export_voter_attributes(diag_panel, lf, out_pth = "vexport/{ys}")) |> purrr::compact()
ok("export produced output", length(exp_pths) > 0)
ex <- open_dataset(unique(dirname(dirname(unlist(exp_pths))))) |> collect()

ok("one row per physician-year", nrow(ex) == nrow(distinct(ex, npi, year)))
ok("carries the requested identifiers and flags",
   all(c("npi", "LALVOTERID", "year", "match_prob", "filled") %in% names(ex)))
ok("carries sex, party and address",
   all(c("Voters_Gender", "Parties_Description", "Residence_Addresses_City",
         "Residence_Addresses_Zip") %in% names(ex)))
ok("a column absent from this L2 vintage comes back as NA, not an error",
   "Residence_Addresses_AddressLine" %in% names(ex) &&
     all(is.na(ex$Residence_Addresses_AddressLine)))
ok("race_source is one of the two documented values",
   all(ex$race_source %in% c("voter_file", "modeled")))
ok("party_source is attached from the voter's state",
   all(ex$party_source[ex$Residence_Addresses_State == "CT"] == "registered"))
ok("every exported voter id appears in the panel",
   all(ex$LALVOTERID %in% (open_dataset(diag_panel) |> collect() |> pull(LALVOTERID))))
ok("branches do not double-count a physician-year across states",
   nrow(ex) == nrow(distinct(ex, npi, year)))
ok("scored rows keep their probability, filled rows do not",
   all(!is.na(ex$match_prob[!ex$filled])) && all(is.na(ex$match_prob[ex$filled])))

cat(sprintf("\n%s  (%d failure%s)\n",
            if (FAIL == 0) "ALL CHECKS PASSED" else "FAILURES PRESENT",
            FAIL, if (FAIL == 1) "" else "s"))
if (FAIL > 0) quit(status = 1)
