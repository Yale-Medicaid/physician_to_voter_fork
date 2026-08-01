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
source("R/random_forest.R"); source("R/reconcile.R"); source("R/nppes.R")
source("R/gap_fill.R")

FAIL <- 0L
ok <- function(label, cond) {
  cond <- isTRUE(cond)
  if (!cond) FAIL <<- FAIL + 1L
  cat(sprintf("  [%s] %s\n", if (cond) "ok" else "FAIL", label))
}

# Build a physician dataset in the NBER `core` schema. Used by several sections below.
make_phys <- function(npi, first, mid, last, state, zip, year = 2018, tag = "p") {
  # named for the newest vintage so read_taxonomy_union() recognises it
  core <- paste0(tag, "_core.csv"); tax <- "PTAXCODE_202512.parquet"
  cms  <- paste0(tag, "_cms.csv");  nuc <- paste0(tag, "_nucc.csv")
  readr::write_csv(tibble::tibble(npi = npi, entity = 1L, pfname = first, pmname = mid,
                                  plname = last, plocstatename = state, ploczip = zip,
                                  pmailstatename = state, pmailzip = zip), core)
  arrow::write_parquet(tibble::tibble(npi = npi, seq = 1L, ptaxcode = "207R00000X"), tax)
  readr::write_csv(tibble::tibble(Code = "207R00000X",
                                  Grouping = "Allopathic & Osteopathic Physicians"), nuc)
  readr::write_csv(tibble::tibble(NPI = npi, grd_yr = 1990L, med_sch = "FAKE SCHOOL"), cms)
  clean_physician_data(core, tax, cms, nuc, year,
                       out_pth = paste0(tag, "_out/year={year}"))
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
nm  <- c("Aaardvarkina","Bloopberta","Squibbly","Fakeworth","Grumbelina")
mid <- c("Q", NA, "Zebulon", "X", "J")
ln  <- c("Zzyzxton","Quibblesnort","Fakenheimer","Notarealname","Blorptastic")
phys <- make_phys(1:5, nm, mid, ln, "CT", "06510", year = 2018, tag = "um")
# a second year, so the year filter has something to discriminate between
invisible(make_phys(1:5, nm, mid, ln, "CT", "06510", year = 2019, tag = "um"))

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
# 2019 has physicians but no Stage A output, so all 5 go cross-border. If the filter read
# the hive `year` column instead of the argument it would pick up 2018's matches and
# return fewer -- so this pins the !! disambiguation.
ok("the state/year filter uses the arguments, not the hive columns of the same name",
   nrow(unmatched_physicians(phys, "lsh/year=2018/state=CT", "CT", 2019)) == 5)
ok("NULL lsh_pairs sends everyone cross-border",
   nrow(unmatched_physicians(phys, NULL, "CT", 2018)) == 5)
# the shape that {{ }} got wrong: a caller whose locals share the column names
ok("filter is robust to a caller whose locals are named state/year",
   (\() { state <- "CT"; year <- 2019
          nrow(unmatched_physicians(phys, "lsh/year=2018/state=CT", state, year)) })() == 5)
ok("a state with no physicians returns NULL",
   is.null(unmatched_physicians(phys, "lsh/year=2018/state=CT", "NY", 2018)))

## ------------------------------------------------------ cross-border matching
cat("\n== lsh_cross_border ==\n")
# CT and NY are adjacent. npi 12 practises in CT but lives in NY, with no CT namesake.
# npi 11 has a unique strong CT match and must stay exempt.
xb_phys <- make_phys(11:12, c("Aaardvarkina","Bloopberta"), c("Q","Zebulon"),
                     c("Zzyzxton","Crossborderson"), "CT", "06510",
                     year = 2018, tag = "xb")

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
    npi = c(21, 21, 22, 24, 24, 25, 26),
    LALVOTERID = c("V21", "V21b", if (y == 2018) "V22a" else "V22b", "V24a", "V24b", "V25",
                   if (y == 2018) "V26a" else "V26b"),
    match_prob = c(0.90, 0.30, 0.80, 0.60, 0.60, 0.70, 0.85),
    state_agree = c(TRUE, TRUE, TRUE, TRUE, TRUE, FALSE, TRUE),
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
ok("within-year tie is carried to the physician level", rd$any_tied_in_year[rd$npi == 24])
ok("CROSS-YEAR tie is flagged -- the panel flag cannot see these",
   rd$best_is_tied[rd$npi == 26] && !rd$any_tied_in_year[rd$npi == 26])
ok("the SAME voter matching equally well in two years is not a tie",
   !rd$best_is_tied[rd$npi == 21])
ok("...and its best_year is stable, not arbitrary", rd$best_year[rd$npi == 21] == 2018)
ok("a tied physician still yields exactly one row", sum(rd$npi == 26) == 1)

# determinism: shuffling the input must not change which voter is chosen
set.seed(99)
dir.create("scored_shuf/year=2018", recursive = TRUE, showWarnings = FALSE)
dir.create("scored_shuf/year=2019", recursive = TRUE, showWarnings = FALSE)
for (y in c(2018L, 2019L)) {
  src <- open_dataset(file.path("scored", paste0("year=", y))) |> collect()
  write_parquet(slice_sample(src, prop = 1), file.path("scored_shuf", paste0("year=", y), "p.parquet"))
}
rd2 <- reconcile_physician_matches(
  physician_year_panel(file.path("scored_shuf", paste0("year=", c(2018L, 2019L))),
                       out_pth = "panel_shuf"),
  out_pth = "matches_shuf") |> open_dataset() |> collect()
ok("tie-break is deterministic under shuffled input",
   identical(arrange(rd, npi)$best_LALVOTERID, arrange(rd2, npi)$best_LALVOTERID))
ok("cross-border best match is flagged", rd$best_cross_border[rd$npi == 25])
ok("in-state best match is not", !rd$best_cross_border[rd$npi == 21])
ok("no match_prob cutoff is applied -- weak matches still appear",
   min(rd$best_match_prob) < 0.75)

## ------------------------------------------- per-year physician data
cat("\n== clean_physician_data (NBER core schema) ==\n")
# NBER core column names, and three address situations:
#   npi 31 -- practice address present            -> uses practice
#   npi 32 -- practice BLANK, mailing present     -> falls back to mailing
#   npi 33 -- practice present but in another state than mailing -> practice wins
# NB: build the combined frame in memory. Round-tripping through readr::read_csv() would
# strip the leading zeros from the ZIPs before read_nppes_core() ever sees the file, and
# the test would then be checking its own corruption rather than the code.
core_both <- "core_all.csv"
bind_rows(
  tibble(npi = 31:33, entity = 1L,
         pfname = c("Aaardvarkina","Bloopberta","Squibbly"),
         pmname = c("Q", NA, "Zebulon"),
         plname = c("Zzyzxton","Quibblesnort","Fakenheimer"),
         plocstatename = c("CT", "",  "NY"), ploczip = c("06510", "", "10001"),
         pmailstatename = c("MA", "RI", "CT"), pmailzip = c("02101", "02901", "06510")),
  # an organisation, which must be excluded
  tibble(npi = 34L, entity = 2L, pfname = NA, pmname = NA, plname = NA,
         plocstatename = "CT", ploczip = "06510",
         pmailstatename = "CT", pmailzip = "06510")
) |> write_csv(core_both)

# Four vintages, named as NBER names them so read_taxonomy_union() can order them.
#   npi 31 -- in 2025 as a physician, and in 2019 as something else -> 2025 must win
#   npi 32 -- 2025 only
#   npi 33 -- 2019 only          (left before the panel ended)
#   npi 34 -- 2023 only          (the mid-panel case two bookends would miss)
arrow::write_parquet(tibble(npi = c(31L, 32L), seq = 1L, ptaxcode = "207R00000X"),
                     "PTAXCODE_202512.parquet")
arrow::write_parquet(tibble(npi = integer(0), seq = integer(0), ptaxcode = character(0)),
                     "PTAXCODE_202412.parquet")
write_csv(tibble(npi = 34L, seq = 1L, ptaxcode = "207R00000X"), "ptaxcode_20235.csv")
arrow::write_parquet(tibble(npi = c(31L, 33L, 33L), seq = c(1L, 1L, 2L),
                            ptaxcode = c("NOTADOCTOR", "207R00000X", "999X")),
                     "PTAXCODE_201912.parquet")
tax_all <- c("PTAXCODE_202512.parquet", "PTAXCODE_202412.parquet",
             "ptaxcode_20235.csv", "PTAXCODE_201912.parquet")
write_csv(tibble(Code = "207R00000X", Grouping = "Allopathic & Osteopathic Physicians"), "nucc2.csv")
write_csv(tibble(NPI = 31:34, grd_yr = 1990L, med_sch = "FAKE SCHOOL"), "cms2.csv")

pp <- clean_physician_data(core_both, tax_all, "cms2.csv", "nucc2.csv", 2018,
                           out_pth = "phys_yr/year={year}")
pd <- open_dataset(unique(dirname(pp))) |> collect()
ok("organisations (entity 2) are excluded", !(34 %in% pd$npi))
ok("individuals are kept", all(31:33 %in% pd$npi))
ok("practice address is used when present",
   pd$state[pd$npi == 31] == "CT" && pd$zip[pd$npi == 31] == "06510")
ok("falls back to mailing when practice is blank",
   pd$state[pd$npi == 32] == "RI" && pd$zip[pd$npi == 32] == "02901")
ok("practice wins over a DIFFERENT mailing state", pd$state[pd$npi == 33] == "NY")
ok("addr_source records which was used",
   pd$addr_source[pd$npi == 31] == "practice" && pd$addr_source[pd$npi == 32] == "mailing")
ok("output is partitioned year=/state=",
   all(c("year","state") %in% names(pd)) &&
     dir.exists(file.path("phys_yr", "year=2018", "state=CT")))
ok("distinct in npi", nrow(pd) == n_distinct(pd$npi))
ok("leading zeros survive the read (06510, not 6510)",
   pd$zip[pd$npi == 31] == "06510" && pd$zip[pd$npi == 32] == "02901")
ok("an NPI present only in the OLDEST extract is still kept", 33 %in% pd$npi)
ok("only seq == 1 is used, so a second taxonomy row does not duplicate the NPI",
   sum(pd$npi == 33) == 1)

# precedence and mid-panel recovery, checked on the union directly
tu <- read_taxonomy_union(tax_all)
ok("most RECENT designation wins (2025 physician beats 2019 non-physician)",
   tu$taxonomy_code[tu$npi == 31] == "207R00000X")
ok("shuffling the input does not invert precedence",
   identical(read_taxonomy_union(rev(tax_all))$taxonomy_code[
               read_taxonomy_union(rev(tax_all))$npi == 31], "207R00000X"))
ok("an NPI seen only in a MIDDLE year is recovered", 34 %in% tu$npi)
ok("one row per NPI after the union", nrow(tu) == n_distinct(tu$npi))

## ------------------------------------------------------------- NPPES URLs
## Table logic only -- no network. The URLs themselves were verified by hand against NBER;
## re-verifying them here would make the suite slow and offline-hostile.
cat("\n== nppes_core_url / download_nppes_core ==\n")
all_urls <- purrr::map(2018:2025, nppes_core_url) |> purrr::list_rbind()
ok("every year 2018-2025 is covered", nrow(all_urls) == 8)
ok("one row per year", !any(duplicated(all_urls$year)))
ok("no duplicated URLs", !any(duplicated(all_urls$url)))
ok("every URL points at NBER's npi tree",
   all(startsWith(all_urls$url, "https://data.nber.org/npi/")))
ok("the year in each URL matches its row",
   all(purrr::map2_lgl(all_urls$year, all_urls$url, \(y, u) grepl(as.character(y), u, fixed = TRUE))))
ok("file extension agrees with the declared format",
   all(tools::file_ext(all_urls$url) == all_urls$format))
ok("2018 is csv (NBER publishes no parquet for it)",
   all_urls$format[all_urls$year == 2018] == "csv")
ok("2023 is csv and stops at May, not December",
   all_urls$format[all_urls$year == 2023] == "csv" && all_urls$month[all_urls$year == 2023] == 5)
ok("every other year is parquet at December",
   all(all_urls$format[!all_urls$year %in% c(2018, 2023)] == "parquet") &&
     all(all_urls$month[!all_urls$year %in% c(2018, 2023)] == 12))
ok("an uncovered year fails loudly rather than returning nothing",
   inherits(try(nppes_core_url(1999), silent = TRUE), "try-error"))

ok("URL lookup is robust to a caller whose local is named `year`",
   (\() { year <- 2024; nrow(nppes_core_url(year)) })() == 1)

# idempotency, without downloading: plant the file the function would fetch
dir.create("nppes_dl", showWarnings = FALSE)
planted <- file.path("nppes_dl", basename(nppes_core_url(2024)$url))
writeLines("not really a parquet file", planted)
before <- file.mtime(planted)
got <- download_nppes_core(2024, out_dir = "nppes_dl")
ok("an already-present file is returned, not re-downloaded",
   normalizePath(got) == normalizePath(planted) && file.mtime(planted) == before)
ok("no .part leftover", length(list.files("nppes_dl", pattern = "[.]part$")) == 0)

cat("\n== panel gap fill ==\n")

# Physician-year universe: who had an NPI record where, per year.
gap_universe <- tribble(
  ~npi,  ~year, ~state,
  101,   2023,  "MD",   101, 2024, "MD",   101, 2025, "MD",   # L2 absent for MD/2024
  102,   2018,  "CT",   102, 2019, "CT",
  103,   2018,  "CT",   103, 2019, "CT",
  104,   2018,  "CT",   104, 2019, "CT",   104, 2020, "CT",
  105,   2018,  "CT",   105, 2019, "MA",                      # changed practice state
  106,   2018,  "CT",   106, 2019, "CT",
  107,   2018,  "CT",   107, 2019, "CT",
  108,   2018,  "CT",                                         # no 2019 record at all
  109,   2018,  "CT",   109, 2019, "CT",                      # matched both years
  110,   2018,  "CT",   110, 2019, "CT",   110, 2020, "CT"
)

# The panel. Deliberately absurd voter ids -- nothing here resembles a real record.
gap_panel <- tribble(
  ~npi, ~year, ~LALVOTERID, ~match_prob, ~zip_dist, ~tied,
  101,  2023,  "FAKE-V1",   0.95,        3,         FALSE,
  101,  2025,  "FAKE-V1",   0.97,        3,         FALSE,
  102,  2018,  "FAKE-V2",   0.95,        5,         FALSE,
  103,  2018,  "FAKE-V3",   0.20,        5,         FALSE,   # too weak to anchor
  104,  2018,  "FAKE-V4",   0.95,        5,         FALSE,   # two distinct anchor voters
  104,  2020,  "FAKE-V5",   0.96,        5,         FALSE,
  105,  2018,  "FAKE-V6",   0.95,        5,         FALSE,
  106,  2018,  "FAKE-V7",   0.95,        500,       FALSE,   # anchor voter far away
  107,  2018,  "FAKE-V8",   0.95,        NA,        FALSE,   # ZIP had no ZCTA
  108,  2018,  "FAKE-V9",   0.95,        5,         FALSE,
  109,  2018,  "FAKE-VA",   0.95,        5,         FALSE,
  109,  2019,  "FAKE-VA",   0.96,        5,         FALSE,
  110,  2018,  "FAKE-VB",   0.95,        5,         TRUE,    # tied anchor year
  110,  2018,  "FAKE-VC",   0.95,        5,         TRUE
) %>%
  mutate(state_agree = TRUE, full_name_sim = 0.99, n = 1L)

phys_pths <- local({
  unlink("gapf_phys", recursive = TRUE)
  u <- mutate(gap_universe, year = as.integer(year))
  for (y in sort(unique(u$year))) {
    write_dataset(filter(u, year == y), file.path("gapf_phys", paste0("year=", y)),
                  partitioning = "state")
  }
  file.path("gapf_phys", paste0("year=", sort(unique(u$year))))
})

panel_pth <- local({
  unlink("gapf_panel", recursive = TRUE)
  write_dataset(mutate(gap_panel, year = as.integer(year)), "gapf_panel")
  "gapf_panel"
})

# Synthetic L2 leaves -- these only need to parse, not exist. MD/2024 is deliberately
# missing, standing in for the real 2024 MD/MS/NV gap.
gap_l2 <- c("l2/state=CT/year=2018/month=11/day=15", "l2/state=CT/year=2019/month=11/day=15",
            "l2/state=CT/year=2020/month=11/day=15", "l2/state=MA/year=2019/month=11/day=15",
            "l2/state=MD/year=2023/month=11/day=15", "l2/state=MD/year=2025/month=11/day=15")

cls <- classify_panel_gaps(panel_pth, phys_pths, gap_l2)

ok("gaps come from physician_data, so a year with no NPI record is not a gap",
   nrow(cls) == 9 && !any(cls$npi == 108))
ok("a physician matched in every year they exist has no gap", !any(cls$npi == 109))

tier <- function(n, y) cls$fill_tier[cls$npi == n & cls$year == y]
ok("structural absence (no L2 partition) is tier 1", tier(101, 2024) == 1L)
ok("L2 present but unmatched, gates passed, is tier 2", tier(102, 2019) == 2L)
ok("a weak-only anchor is not filled", tier(103, 2019) == 3L)
ok("two distinct anchor voters is not filled", tier(104, 2019) == 3L)
ok("a changed practice state is not filled", tier(105, 2019) == 3L)
ok("an anchor voter beyond max_fill_zip_dist is not filled", tier(106, 2019) == 3L)
ok("an NA zip_dist is not filled -- proximity cannot be checked", tier(107, 2019) == 3L)
ok("a tied anchor year is ambiguous, so not filled",
   all(cls$fill_tier[cls$npi == 110] == 3L))

ok("only the intended gate fails for the weak anchor",
   !cls$has_anchor[cls$npi == 103] && cls$l2_present[cls$npi == 103])
ok("the far-anchor gap fails `near` and nothing else",
   with(cls[cls$npi == 106, ], has_anchor && unambiguous && state_stable && !near))
ok("the moved physician fails `state_stable` and nothing else",
   with(cls[cls$npi == 105, ], has_anchor && unambiguous && !state_stable && near))
ok("l2_present is FALSE only for the missing MD/2024 partition",
   sum(!cls$l2_present) == 1 && !cls$l2_present[cls$npi == 101])

# Tier 1 must not depend on the state-year being missing for *everyone* -- MD/2023 and
# MD/2025 exist, only 2024 does not.
ok("tier 1 keys on the gap's own state-year, not the state",
   tier(101, 2024) == 1L && nrow(cls[cls$npi == 101, ]) == 1)

filled_pth <- fill_panel_gaps(panel_pth, phys_pths, gap_l2, out_pth = "gapf_out")
fp <- open_dataset(filled_pth) %>% collect()

ok("filled panel is the panel plus exactly the fillable gaps",
   nrow(fp) == nrow(gap_panel) + 2)
ok("two rows are flagged filled", sum(fp$filled) == 2)
ok("both tiers appear once each",
   setequal(fp$fill_tier[fp$filled], c(1L, 2L)))
ok("observed rows carry filled = FALSE and no tier",
   all(!fp$filled[!fp$filled]) && all(is.na(fp$fill_tier[!fp$filled])))

fills <- filter(fp, filled)
ok("a fill carries the anchor's voter identity",
   fills$LALVOTERID[fills$npi == 101] == "FAKE-V1" &&
     fills$LALVOTERID[fills$npi == 102] == "FAKE-V2")
ok("a fill carries NO scored attributes -- identity only",
   all(is.na(fills$match_prob)) && all(is.na(fills$zip_dist)) &&
     all(is.na(fills$full_name_sim)) && all(is.na(fills$n)) &&
     all(is.na(fills$state_agree)) && all(is.na(fills$tied)))
ok("fills land in the year that was empty",
   fills$year[fills$npi == 101] == 2024 && fills$year[fills$npi == 102] == 2019)
ok("fills are unique per npi-year, and never collide with an observed row",
   !anyDuplicated(fp[c("npi", "year", "LALVOTERID")]))

# The observed half must survive untouched: same rows, same values.
obs_back <- fp %>% filter(!filled) %>% select(names(gap_panel)) %>% arrange(npi, year, LALVOTERID)
ok("observed rows pass through unchanged",
   isTRUE(all.equal(as.data.frame(obs_back),
                    as.data.frame(gap_panel %>% mutate(year = as.integer(year)) %>%
                                    arrange(npi, year, LALVOTERID)),
                    check.attributes = FALSE)))

gs <- summarize_panel_gaps(panel_pth, phys_pths, gap_l2)
ok("summary counts every gap", gs$n_gaps == 9 && gs$n_npi_with_gap == 8)
ok("summary tiers sum to the gap count",
   gs$n_tier_1 + gs$n_tier_2 + gs$n_tier_3 == gs$n_gaps)
ok("summary reports one tier 1 and one tier 2", gs$n_tier_1 == 1 && gs$n_tier_2 == 1)
ok("summary attributes each failure to the right gate",
   gs$n_fail_no_anchor == 1 && gs$n_fail_ambiguous == 3 && gs$n_fail_moved == 1)
ok("summary tells a distant anchor apart from a missing zip_dist",
   gs$n_fail_far == 1 && gs$n_fail_no_zip == 1)

# Thresholds must actually bind, or they are decoration. Pull the tier out by npi rather
# than by position -- two calls need not agree on row order, and indexing one result with
# another's mask silently compares the wrong rows.
tier_of <- function(df, id) dplyr::pull(dplyr::filter(df, npi == !!id), fill_tier)
ok("raising min_fill_prob above the anchors stops all filling",
   all(classify_panel_gaps(panel_pth, phys_pths, gap_l2, min_fill_prob = 0.99)$fill_tier == 3L))
ok("relaxing max_fill_zip_dist admits the far anchor",
   tier_of(classify_panel_gaps(panel_pth, phys_pths, gap_l2,
                               max_fill_zip_dist = 1000), 106) == 2L)
ok("dropping min_fill_prob admits the weak anchor",
   tier_of(classify_panel_gaps(panel_pth, phys_pths, gap_l2,
                               min_fill_prob = 0.1), 103) == 2L)
ok("classification row order is deterministic across runs",
   identical(classify_panel_gaps(panel_pth, phys_pths, gap_l2)[c("npi", "year")],
             cls[c("npi", "year")]))

# An empty L2 list means nothing could be matched anywhere, so every gap is structural.
ok("with no L2 at all, fillable gaps are tier 1",
   all(classify_panel_gaps(panel_pth, phys_pths, character(0)) %>%
         filter(fillable) %>% pull(fill_tier) == 1L))
ok("a NULL panel yields no filled dataset",
   is.null(fill_panel_gaps(NULL, phys_pths, gap_l2, out_pth = "gapf_null")))

cat(sprintf("\n%s  (%d failure%s)\n",
            if (FAIL == 0) "ALL CHECKS PASSED" else "FAILURES PRESENT",
            FAIL, if (FAIL == 1) "" else "s"))
if (FAIL > 0) quit(status = 1)
