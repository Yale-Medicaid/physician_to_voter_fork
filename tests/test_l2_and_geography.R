## Self-contained checks for the L2 partition helpers and the state adjacency table.
##
## Run from the repo root:   Rscript tests/test_l2_and_geography.R
##
## Builds its own SYNTHETIC L2 hive tree in a temp directory -- no real data, and nothing
## is written inside the repo. Names are deliberately absurd so fixture output can never
## be mistaken for real voter records.

suppressPackageStartupMessages({
  library(arrow); library(tidyverse); library(zoomerjoin); library(lubridate)
})
# source before the setwd() below -- these paths are relative to the repo root
source("R/helpers.R"); source("R/l2.R"); source("R/geographic.R")
source("R/clean_physician_data.R"); source("R/locality_sensitive_hash.R")
source("R/random_forest.R"); source("R/reconcile.R")

FAIL <- 0L
ok <- function(label, cond) {
  cond <- isTRUE(cond)
  if (!cond) FAIL <<- FAIL + 1L
  cat(sprintf("  [%s] %s\n", if (cond) "ok" else "FAIL", label))
}

root <- file.path(tempdir(), "p2v_test")
unlink(root, recursive = TRUE)
dir.create(root, recursive = TRUE)
old <- setwd(root)
on.exit(setwd(old), add = TRUE)

## ---------------------------------------------------------------- fixture
## CT/2018 has TWO extracts (the later must win). NY/2019 is absent, standing in for the
## real 2024 MD/MS/NV gap. CT/2025 exercises the occupation column rename.
leaves <- tribble(
  ~state, ~year, ~month, ~day,  ~tag,
  "CT",   2018,  "06",   "01",  "stale",
  "CT",   2018,  "11",   "15",  "current",
  "NY",   2018,  "07",   "04",  "current",
  "CT",   2019,  "6",    "9",   "current",   # unpadded on purpose
  "CT",   2025,  "05",   "20",  "current"
)
for (i in seq_len(nrow(leaves))) {
  L <- leaves[i, ]
  d <- file.path("l2root", paste0("state=", L$state), paste0("year=", L$year),
                 paste0("month=", L$month), paste0("day=", L$day))
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  occ_col <- if (L$year <= 2024) "CommercialData_Occupation" else "ConsumerData_Occupation_of_Person"
  v <- tibble(LALVOTERID = paste0("LAL", L$state, 1:4),
              Voters_FirstName = c("Aaardvarkina","Bloopberta","Squibbly","Fakeworth"),
              Voters_MiddleName = c("Q", NA, "Zebulon", "X"),
              Voters_LastName = if (L$tag == "stale") rep("Staleextract", 4) else
                c("Zzyzxton","Quibblesnort","Fakenheimer","Notarealname"),
              Residence_Addresses_State = L$state)
  v[[occ_col]] <- c("Medical-Physician", "Unknown", NA, "Educator")
  write_parquet(v, file.path(d, "part-0.parquet"))
}
l2_path <- "l2root/state={state}/year={year}"

## -------------------------------------------------- L2 partition resolution
cat("\n== resolve_l2_extract ==\n")
ct18 <- resolve_l2_extract("CT", 2018, l2_path)
ok("resolves a state-year that exists", !is.null(ct18))
ok("picks the LATER of two extracts (11/15, not 06/01)", grepl("month=11/day=15", ct18))
ok("absent state-year returns NULL", is.null(resolve_l2_extract("NY", 2019, l2_path)))
ok("state-year outside the tree returns NULL", is.null(resolve_l2_extract("ZZ", 2018, l2_path)))
ok("unpadded month=6/day=9 resolves", !is.null(resolve_l2_extract("CT", 2019, l2_path)))
ok("the stale extract's rows are not reachable via the resolved leaf",
   !any(open_dataset(ct18) |> collect() |> pull(Voters_LastName) == "Staleextract"))

cat("\n== parse_l2_extract_date ==\n")
ok("padded and unpadded parse to the same date",
   parse_l2_extract_date("x/year=2019/month=6/day=9") ==
     parse_l2_extract_date("x/year=2019/month=06/day=09"))
ok("later extract sorts later",
   parse_l2_extract_date("x/year=2018/month=11/day=15") >
     parse_l2_extract_date("x/year=2018/month=06/day=01"))

cat("\n== path key parsing (L2 nests state OUTSIDE year) ==\n")
ok("get_l2_state reads by key, not position", get_l2_state(ct18) == "CT")
ok("get_l2_year reads by key, not position", get_l2_year(ct18) == 2018)
ok("output subdir FLIPS to year=/state=",
   as.character(build_l2_out_subdir(ct18)) == "year=2018/state=CT")

cat("\n== occupation column by year ==\n")
ok("<=2024 uses CommercialData_Occupation",
   l2_occupation_col(2024) == "CommercialData_Occupation")
ok(">=2025 uses ConsumerData_Occupation_of_Person",
   l2_occupation_col(2025) == "ConsumerData_Occupation_of_Person")
ok("the 2025 fixture really does store the consumer name",
   "ConsumerData_Occupation_of_Person" %in%
     names(open_dataset(resolve_l2_extract("CT", 2025, l2_path)) |> collect()))

## ------------------------------------------------------- state adjacency
cat("\n== state_adjacency ==\n")
adj <- state_adjacency()
all_states <- sort(unique(c(adj$state_a, adj$state_b)))
ok("109 undirected pairs", nrow(adj) == 109)
ok("each pair listed once (no duplicates, no reversed duplicates)",
   nrow(adj) == nrow(distinct(mutate(adj,
     lo = pmin(state_a, state_b), hi = pmax(state_a, state_b)) |> select(lo, hi))))
ok("no state borders itself", !any(adj$state_a == adj$state_b))
ok("49 states have land neighbours (AK and HI have none)", length(all_states) == 49)
ok("AK has no neighbours", length(adjacent_states("AK")) == 0)
ok("HI has no neighbours", length(adjacent_states("HI")) == 0)
ok("adjacency is symmetric under adjacent_states()",
   all(vapply(all_states,
              function(s) all(vapply(adjacent_states(s),
                                     function(t) s %in% adjacent_states(t), logical(1))),
              logical(1))))
ok("DC borders exactly MD and VA", identical(adjacent_states("DC"), c("MD","VA")))
ok("Four Corners point contacts included (AZ-CO)", "CO" %in% adjacent_states("AZ"))
ok("Four Corners point contacts included (NM-UT)", "UT" %in% adjacent_states("NM"))
ok("MI-WI included (real land border via the Upper Peninsula)",
   "WI" %in% adjacent_states("MI"))
ok("RI-NY excluded (water only)", !("NY" %in% adjacent_states("RI")))
ok("MI-IL excluded (water only)", !("IL" %in% adjacent_states("MI")))
ok("MI-NY excluded (water only)", !("NY" %in% adjacent_states("MI")))
ok("MI-PA excluded (water only)", !("PA" %in% adjacent_states("MI")))
ok("MI-MN excluded (water only)", !("MN" %in% adjacent_states("MI")))
# guard against the easy misreading of the rule above: these are MICHIGAN pairs.
# NY-PA is a long land border and must stay in.
ok("NY-PA included (long land border, not a Michigan lake pair)",
   "PA" %in% adjacent_states("NY"))
ok("every abbreviation is a real state or DC",
   all(all_states %in% c(state.abb, "DC")))

## ------------------------------------------------ unmatched_physicians
cat("\n== unmatched_physicians ==\n")
write_csv(tibble(NPI = 1:5,
                 `Provider First Name` = c("Aaardvarkina","Bloopberta","Squibbly","Fakeworth","Grumbelina"),
                 `Provider Middle Name` = c("Q", NA, "Zebulon", "X", "J"),
                 `Provider Last Name (Legal Name)` = c("Zzyzxton","Quibblesnort","Fakenheimer","Notarealname","Blorptastic"),
                 `Provider Business Mailing Address State Name` = "CT",
                 `Provider Business Mailing Address Postal Code` = "06510",
                 `Healthcare Provider Taxonomy Code_1` = "207R00000X",
                 `Entity Type Code` = 1L), "nppes.csv")
write_csv(tibble(Code = "207R00000X", Grouping = "Allopathic & Osteopathic Physicians"), "nucc.csv")
write_csv(tibble(NPI = 1:5, grd_yr = 1990L, med_sch = "FAKE SCHOOL"), "cms.csv")
phys <- clean_physician_data("cms.csv", "nppes.csv", "nucc.csv", out_pth = "phys")

# Stage A results per physician:
#   npi 1 -- ONE strong candidate (0.99)        -> exempt
#   npi 2 -- one weak candidate (0.40)          -> retried
#   npi 3 -- no candidates at all               -> retried
#   npi 4 -- one candidate at 0.80, below 0.85  -> retried (pins the default)
#   npi 5 -- THREE strong candidates (all 0.99) -> retried (ambiguous common name)
dir.create("lsh/year=2018/state=CT", recursive = TRUE, showWarnings = FALSE)
write_parquet(tibble(npi = c(1, 2, 4, 5, 5, 5),
                     full_name_sim = c(0.99, 0.40, 0.80, 0.99, 0.99, 0.99)),
              "lsh/year=2018/state=CT/part-0.parquet")

u <- unmatched_physicians(phys, "lsh/year=2018/state=CT", "CT", 2018)
ok("strong in-state match is NOT sent cross-border", !(1 %in% u$npi))
ok("weak in-state match IS sent cross-border", 2 %in% u$npi)
ok("physician with no candidate at all IS sent cross-border", 3 %in% u$npi)
ok("returns 4 of 5 physicians", nrow(u) == 4)
ok("default min_name_sim is 0.85, so a 0.80 in-state hit is still retried",
   4 %in% u$npi)
ok("lowering the cutoff to 0.75 exempts the 0.80 case",
   !(4 %in% unmatched_physicians(phys, "lsh/year=2018/state=CT", "CT", 2018,
                                 min_name_sim = 0.75)$npi))
ok("exactly ONE strong candidate is exempt", !(1 %in% u$npi))
ok("THREE strong candidates are retried -- uniqueness is required, not just a high max",
   5 %in% u$npi)
# 2019 has no Stage A data, so nobody has an in-state match and all 4 go cross-border.
# If the filter read the hive `year` column instead of the argument it would match 2018
# and return 2, so this pins the {{ }} disambiguation.
ok("the state/year filter uses the arguments, not the hive columns of the same name",
   nrow(unmatched_physicians(phys, "lsh/year=2018/state=CT", "CT", 2019)) == 5)
ok("NULL lsh_pairs sends everyone cross-border",
   nrow(unmatched_physicians(phys, NULL, "CT", 2018)) == 5)
ok("a state with no physicians returns NULL",
   is.null(unmatched_physicians(phys, "lsh/year=2018/state=CT", "NY", 2018)))

## ------------------------------------------------------ cross-border matching
cat("\n== lsh_cross_border ==\n")
# CT and NY are adjacent. npi 12 practises in CT but lives in NY, with no CT namesake.
# npi 11 has a unique strong CT match and must stay exempt.
write_csv(tibble(NPI = 11:12,
                 `Provider First Name` = c("Aaardvarkina","Bloopberta"),
                 `Provider Middle Name` = c("Q","Zebulon"),
                 `Provider Last Name (Legal Name)` = c("Zzyzxton","Crossborderson"),
                 `Provider Business Mailing Address State Name` = "CT",
                 `Provider Business Mailing Address Postal Code` = "06510",
                 `Healthcare Provider Taxonomy Code_1` = "207R00000X",
                 `Entity Type Code` = 1L), "xb_nppes.csv")
write_csv(tibble(NPI = 11:12, grd_yr = 1990L, med_sch = "FAKE SCHOOL"), "xb_cms.csv")
xb_phys <- clean_physician_data("xb_cms.csv", "xb_nppes.csv", "nucc.csv", out_pth = "xb_phys")

mkv <- function(first, mid, last, state, zip, id) tibble(
  LALVOTERID = id, Voters_FirstName = first, Voters_MiddleName = mid,
  Voters_LastName = last, Voters_NameSuffix = NA_character_,
  Voters_BirthDate = as.Date("1963-01-01"), Residence_Addresses_State = state,
  Residence_Addresses_Zip = zip, Residence_Addresses_ZipPlus4 = "1234",
  # required by read_l2_partition()'s bare select, unlike the any_of() columns
  Residence_Addresses_City = "Fakeville",
  CommercialData_Occupation = "Medical-Physician")
for (p in list(list("CT", mkv("Aaardvarkina","Q","Zzyzxton","CT","06510","XBCT1")),
               list("NY", mkv("Bloopberta","Zebulon","Crossborderson","NY","10001","XBNY1")))) {
  d <- file.path("xb", paste0("state=", p[[1]]), "year=2018", "month=06", "day=01")
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  write_parquet(p[[2]], file.path(d, "part-0.parquet"))
}
# minimal centroid file covering just these two ZIPs
write_csv(tibble(zcta5 = c("06510","10001"),
                 intptlat = c(41.3053, 40.7506),
                 intptlong = c(-72.9276, -73.9971)), "xb_cent.csv")

xb_l2 <- "xb/state={state}/year={year}"
ct_leaf <- resolve_l2_extract("CT", 2018, xb_l2)
# NB the {ys} in out_pth is not optional: unmatched_physicians() and score_pairs() both
# recover the partitioned root with dirname(dirname(path)), so the output must sit two
# levels deep. A flat out_pth silently resolves the root to "." .
a <- locality_sensitive_hash(xb_phys, ct_leaf, "xb_cent.csv", out_pth = "xb_a/{ys}")
a_d <- open_dataset(a) |> collect()
ok("in-state pass matches the physician who has a CT namesake", 11 %in% a_d$npi)
ok("in-state pass finds nothing for the cross-border physician", !(12 %in% a_d$npi))

b <- lsh_cross_border(xb_phys, ct_leaf, a, xb_l2, "xb_cent.csv", out_pth = "xb_b/{ys}")
ok("cross-border pass produced output", !is.null(b))
b_d <- open_dataset(b) |> collect()
ok("cross-border pass finds the NY-resident physician", 12 %in% b_d$npi)
ok("...matched to a NY voter", all(b_d$st.y[b_d$npi == 12] == "ny"))
ok("physician with a unique strong in-state match is NOT retried", !(11 %in% b_d$npi))
ok("state_agree is TRUE for every in-state pair", all(a_d$state_agree))
ok("state_agree is FALSE for every cross-border pair", all(!b_d$state_agree))
ok("state_agree is carried in the output but is NOT an RF feature",
   "state_agree" %in% names(b_d) &&
     !("state_agree" %in% colnames(make_X_matrix(mutate(b_d, n = 1L)))))
ok("the RF matrix has 8 features",
   ncol(make_X_matrix(mutate(b_d, n = 1L))) == 8)
ok("cross-border output is partitioned by the PHYSICIAN's state",
   all(get_l2_state(b) == "CT"))
ok("zip_dist across the border is a real positive distance",
   all(b_d$zip_dist > 0 & is.finite(b_d$zip_dist)))

## ------------------------------------------------- cross-year reconciliation
cat("\n== physician_year_panel / reconcile_physician_matches ==\n")
# npi 21 -- same voter every year, high prob        -> not a mover
# npi 22 -- DIFFERENT best voter in 2018 vs 2019    -> mover
# npi 23 -- only appears in 2018 (stands in for a physician in a 2024-gap state)
# npi 24 -- two candidates TIED for best in 2018    -> flagged, not dropped
# npi 25 -- best match is cross-border
for (y in c(2018L, 2019L)) {
  dir.create(file.path("scored", paste0("year=", y)), recursive = TRUE, showWarnings = FALSE)
  rows <- tibble(
    npi = c(21, 21, 22, 24, 24, 25),
    LALVOTERID = c("V21", "V21b", if (y == 2018) "V22a" else "V22b", "V24a", "V24b", "V25"),
    match_prob = c(0.90, 0.30, 0.80, 0.60, 0.60, 0.70),
    state_agree = c(TRUE, TRUE, TRUE, TRUE, TRUE, FALSE),
    zip_dist = 5, full_name_sim = 0.95, n = 2L
  )
  if (y == 2018) rows <- bind_rows(rows, tibble(npi = 23, LALVOTERID = "V23",
    match_prob = 0.75, state_agree = TRUE, zip_dist = 5, full_name_sim = 0.95, n = 1L))
  write_parquet(rows, file.path("scored", paste0("year=", y), "part-0.parquet"))
}
scored <- file.path("scored", paste0("year=", c(2018L, 2019L)))

pan <- physician_year_panel(scored, out_pth = "panel")
pd <- open_dataset(pan) |> collect()
ok("panel keeps only each year's best candidate",
   nrow(filter(pd, npi == 21)) == 2 && all(pd$match_prob[pd$npi == 21] == 0.90))
ok("tied candidates are KEPT, not dropped", sum(pd$npi == 24 & pd$year == 2018) == 2)
ok("ties are flagged", all(pd$tied[pd$npi == 24]))
ok("untied rows are not flagged", !any(pd$tied[pd$npi == 21]))

rec <- reconcile_physician_matches(pan, out_pth = "matches")
rd <- open_dataset(rec) |> collect()
ok("one row per physician", nrow(rd) == n_distinct(rd$npi))
ok("stable physician is not a mover", !rd$mover[rd$npi == 21])
ok("physician whose best voter changes IS a mover", rd$mover[rd$npi == 22])
ok("mover has 2 distinct voters", rd$n_distinct_voters[rd$npi == 22] == 2)
ok("best match is the highest probability found in any year",
   rd$best_match_prob[rd$npi == 21] == 0.90 && rd$best_LALVOTERID[rd$npi == 21] == "V21")
ok("a physician present in only one year is NOT flagged as a mover",
   !rd$mover[rd$npi == 23])
ok("...and its missing year shows as n_years_matched, not as a failure",
   rd$n_years_matched[rd$npi == 23] == 1)
ok("tie is carried through to the physician level", rd$any_tied[rd$npi == 24])
ok("cross-border best match is flagged", rd$best_cross_border[rd$npi == 25])
ok("in-state best match is not", !rd$best_cross_border[rd$npi == 21])
ok("no match_prob cutoff is applied -- weak matches still appear",
   min(rd$best_match_prob) < 0.75)

cat(sprintf("\n%s  (%d failure%s)\n",
            if (FAIL == 0) "ALL CHECKS PASSED" else "FAILURES PRESENT",
            FAIL, if (FAIL == 1) "" else "s"))
if (FAIL > 0) quit(status = 1)
