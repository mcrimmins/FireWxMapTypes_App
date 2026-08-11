# util/getFOD.R --------------------------------------------------------------
# Download the latest FPA-FOD release and rebuild Data/FODthin.Rdata
#
# Dataset: Short, Karen C. 2026. Spatial wildfire occurrence data for the
#   United States, 1992-2024 [FPA_FOD_20260615]. 7th Edition. Fort Collins, CO:
#   Forest Service Research Data Archive. https://doi.org/10.2737/RDS-2013-0009.7
#
# Supersedes the ad-hoc util/thinFOD.R, which read a local ./oldVersions/FOD.RData
# built from the 6th edition (1992-2020). Same output contract: a data.frame
# named `fc`, saved to Data/FODthin.Rdata, which app.R loads at startup.
#
# Run from the project root:
#   source("util/getFOD.R")
#   fod_main()
#
# Requires: DBI, RSQLite, sf (all in renv.lock).
#
# NOTE ON COORDINATES: through the 6th edition the Fires table carried plain
# LATITUDE / LONGITUDE columns. The 7th edition dropped them -- the point
# location now exists only in the `geom` blob. So this script reads the layer
# with sf and recovers LATITUDE / LONGITUDE via st_coordinates(), while still
# taking the fast RSQLite path on any edition that does publish the columns.
#
# MAC 2026-08-10
# ---------------------------------------------------------------------------

FODCFG <- list(

  # --- release ---------------------------------------------------------------
  edition   = "RDS-2013-0009.7",
  release   = "FPA_FOD_20260615",
  doi       = "https://doi.org/10.2737/RDS-2013-0009.7",
  catalog   = "https://www.fs.usda.gov/rds/archive/catalog/RDS-2013-0009.7",

  # GeoPackage build (open format, ~185 MB zipped). The same data is published
  # as ACCDB / GDB / SQLITE -- swap Format3_GPKG for Format1_ACCDB,
  # Format2_GDB or Format4_SQLITE if you ever need one of those instead.
  url = paste0(
    "https://www.fs.usda.gov/rds/archive/products/RDS-2013-0009.7/",
    "RDS-2013-0009.7_Data_Format3_GPKG.zip"
  ),
  url_meta = paste0(
    "https://www.fs.usda.gov/rds/archive/products/RDS-2013-0009.7/",
    "RDS-2013-0009.7_Metadata_Fileindex.zip"
  ),
  expect_mb = 184.8,   # published size; used as a sanity check only

  # --- paths -----------------------------------------------------------------
  raw_dir  = file.path("Data", "fod_raw"),
  out_file = file.path("Data", "FODthin.Rdata"),

  # --- thinning --------------------------------------------------------------
  # 1992-2024 is the full 7th-edition span. Note the CPC precip and NCEP R2
  # height grids in Data/ only cover 1992-2020, so anything past 2020 has no
  # matching weather layer yet -- see Data/README.md.
  years = 1992:2024,

  # Final column set of the saved object. LATITUDE / LONGITUDE are derived from
  # geometry when the table doesn't carry them (7th edition onward); everything
  # else must exist as an attribute column.
  keep = c("FIRE_YEAR", "DISCOVERY_DATE", "DISCOVERY_DOY",
           "NWCG_CAUSE_CLASSIFICATION",
           "CONT_DATE", "CONT_DOY", "FIRE_SIZE", "FIRE_SIZE_CLASS",
           "LATITUDE", "LONGITUDE", "STATE"),

  # --- behaviour -------------------------------------------------------------
  redownload = FALSE,  # TRUE forces a re-fetch even if the zip is already there
  reextract  = FALSE,  # TRUE forces a re-unzip even if the .gpkg is already there
  keep_raw   = TRUE,   # FALSE deletes Data/fod_raw when the thin file is written
  get_meta   = TRUE,   # also fetch the small metadata/fileindex zip

  # Read the geometry-bearing layer one year at a time and drop geometry as we
  # go. 2.66M sf points held at once needs several GB; year chunks keep the
  # peak to a few hundred MB and give progress output. Set FALSE for a single
  # read if you have the headroom.
  chunk_by_year = TRUE
)


# --- helpers ----------------------------------------------------------------

fod_msg <- function(...) message(format(Sys.time(), "[%H:%M:%S] "), ...)

fod_need <- function(pkgs) {
  missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
  if (length(missing)) {
    stop("Missing package(s): ", paste(missing, collapse = ", "),
         ". Install with renv::install(c(",
         paste0('"', missing, '"', collapse = ", "), "))", call. = FALSE)
  }
}

fod_mb <- function(path) round(file.info(path)$size / 1024^2, 1)


# --- 1. download -------------------------------------------------------------

fod_download <- function(cfg = FODCFG) {

  dir.create(cfg$raw_dir, recursive = TRUE, showWarnings = FALSE)
  zip_path <- file.path(cfg$raw_dir, basename(cfg$url))

  if (file.exists(zip_path) && !cfg$redownload) {
    fod_msg("zip already present (", fod_mb(zip_path), " MB): ", zip_path)
  } else {
    # Big file over a slow federal server -- default 60 s timeout is far too
    # short. Download to .part first so an interrupted run never leaves a
    # truncated file that looks complete.
    old_opt <- options(timeout = max(7200, getOption("timeout")))
    on.exit(options(old_opt), add = TRUE)

    part <- paste0(zip_path, ".part")
    fod_msg("downloading ", basename(cfg$url), " (~", cfg$expect_mb, " MB)")
    fod_msg("  from ", cfg$url)
    utils::download.file(cfg$url, destfile = part, mode = "wb", quiet = FALSE)
    file.rename(part, zip_path)
    fod_msg("downloaded ", fod_mb(zip_path), " MB")
  }

  got <- fod_mb(zip_path)
  if (abs(got - cfg$expect_mb) > 0.05 * cfg$expect_mb) {
    warning("Downloaded size ", got, " MB differs from the published ",
            cfg$expect_mb, " MB. The archive may have been revised -- check ",
            cfg$catalog, call. = FALSE)
  }

  if (isTRUE(cfg$get_meta)) {
    meta_path <- file.path(cfg$raw_dir, basename(cfg$url_meta))
    if (!file.exists(meta_path) || cfg$redownload) {
      fod_msg("downloading metadata/fileindex zip")
      try(utils::download.file(cfg$url_meta, destfile = meta_path,
                               mode = "wb", quiet = TRUE), silent = TRUE)
    }
  }

  zip_path
}


# --- 2. extract --------------------------------------------------------------

fod_extract <- function(zip_path, cfg = FODCFG) {

  found <- list.files(cfg$raw_dir, pattern = "\\.gpkg$",
                      recursive = TRUE, full.names = TRUE)

  if (length(found) && !cfg$reextract) {
    fod_msg("gpkg already extracted (", fod_mb(found[1]), " MB): ", found[1])
    return(found[1])
  }

  fod_msg("unzipping into ", cfg$raw_dir, " (needs ~1.5 GB free)")
  utils::unzip(zip_path, exdir = cfg$raw_dir, overwrite = TRUE)

  found <- list.files(cfg$raw_dir, pattern = "\\.gpkg$",
                      recursive = TRUE, full.names = TRUE)
  if (!length(found)) {
    stop("No .gpkg found under ", cfg$raw_dir, " after unzipping ",
         basename(zip_path), call. = FALSE)
  }
  if (length(found) > 1) {
    fod_msg("note: ", length(found), " .gpkg files found, using the largest")
    found <- found[order(file.info(found)$size, decreasing = TRUE)]
  }

  fod_msg("extracted ", fod_mb(found[1]), " MB: ", basename(found[1]))
  found[1]
}


# --- 3. read + thin ----------------------------------------------------------

# Inspect the GeoPackage schema without reading any rows: which feature table
# holds the fires, which columns we can have, and whether coordinates need to
# come out of geometry.
fod_schema <- function(gpkg, cfg = FODCFG) {

  fod_need(c("DBI", "RSQLite"))

  con <- DBI::dbConnect(RSQLite::SQLite(), gpkg)
  on.exit(DBI::dbDisconnect(con), add = TRUE)

  # The fire-point layer is named "Fires" in every edition so far, but resolve
  # it from gpkg_contents rather than hardcoding, in case that ever changes.
  contents <- DBI::dbGetQuery(
    con, "SELECT table_name, data_type FROM gpkg_contents")
  feats <- contents$table_name[contents$data_type == "features"]
  if (!length(feats)) {
    stop("No feature table in ", basename(gpkg), ". Tables present: ",
         paste(contents$table_name, collapse = ", "), call. = FALSE)
  }
  tbl <- if ("Fires" %in% feats) "Fires" else feats[1]
  fod_msg("layer '", tbl, "' (of: ",
          paste(contents$table_name, collapse = ", "), ")")

  have <- DBI::dbListFields(con, tbl)

  gcol <- NULL
  gc_tab <- tryCatch(
    DBI::dbGetQuery(con, sprintf(
      "SELECT column_name FROM gpkg_geometry_columns WHERE table_name = '%s'",
      tbl)),
    error = function(...) NULL)
  if (!is.null(gc_tab) && nrow(gc_tab)) gcol <- gc_tab$column_name[1]

  # Column names have shifted between editions -- STAT_CAUSE_DESCR became
  # NWCG_CAUSE_CLASSIFICATION in the 6th, LATITUDE/LONGITUDE disappeared in the
  # 7th -- so report a rename rather than failing blindly on it.
  xy_cols   <- c("LATITUDE", "LONGITUDE")
  attr_want <- setdiff(cfg$keep, xy_cols)
  present   <- intersect(attr_want, have)
  absent    <- setdiff(attr_want, have)
  has_xy    <- all(xy_cols %in% have)

  if (length(absent)) {
    fod_msg("!! requested but not in this edition: ",
            paste(absent, collapse = ", "))
    fod_msg("   available columns: ", paste(have, collapse = ", "))
  }
  if (!"FIRE_YEAR" %in% have) {
    stop("FIRE_YEAR is missing -- the schema changed materially. ",
         "Reconcile FODCFG$keep against ", cfg$catalog, call. = FALSE)
  }
  if (!has_xy && is.null(gcol)) {
    stop("This layer has neither LATITUDE/LONGITUDE columns nor a geometry ",
         "column, so there is no way to recover fire locations.", call. = FALSE)
  }
  if (has_xy) {
    present <- c(present, xy_cols)
    fod_msg("coordinates: using the published LATITUDE/LONGITUDE columns")
  } else {
    fod_msg("coordinates: no LATITUDE/LONGITUDE columns in this edition, ",
            "deriving them from the '", gcol, "' geometry")
  }

  yrs <- DBI::dbGetQuery(con, sprintf(
    "SELECT MIN(FIRE_YEAR) AS lo, MAX(FIRE_YEAR) AS hi FROM \"%s\"", tbl))

  list(table = tbl, cols = present, geom_col = gcol, has_xy = has_xy,
       year_lo = as.integer(yrs$lo), year_hi = as.integer(yrs$hi))
}


# Attribute-only read, for editions that publish LATITUDE/LONGITUDE.
fod_read_attrs <- function(gpkg, sch, cfg = FODCFG) {

  con <- DBI::dbConnect(RSQLite::SQLite(), gpkg)
  on.exit(DBI::dbDisconnect(con), add = TRUE)

  DBI::dbGetQuery(con, sprintf(
    "SELECT %s FROM \"%s\" WHERE FIRE_YEAR BETWEEN %d AND %d",
    paste0('"', sch$cols, '"', collapse = ", "), sch$table,
    min(cfg$years), max(cfg$years)))
}


# Geometry read, for the 7th edition onward. Pulls the requested attributes
# plus the point geometry, converts geometry to LATITUDE/LONGITUDE, and drops
# it immediately so the sf object never has to be held for the whole table.
fod_read_geom <- function(gpkg, sch, cfg = FODCFG) {

  fod_need("sf")

  read_block <- function(lo, hi) {
    sql <- sprintf(
      "SELECT %s, \"%s\" FROM \"%s\" WHERE FIRE_YEAR BETWEEN %d AND %d",
      paste0('"', sch$cols, '"', collapse = ", "), sch$geom_col,
      sch$table, lo, hi)

    x <- sf::st_read(gpkg, query = sql, quiet = TRUE)
    if (!nrow(x)) return(NULL)

    # FOD points are NAD83 geographic, which is what the old LATITUDE/LONGITUDE
    # columns held. Transform only if some future edition ships projected data.
    crs <- sf::st_crs(x)
    if (!is.na(crs) && !isTRUE(sf::st_is_longlat(x))) {
      x <- sf::st_transform(x, 4326)
    }

    xy <- sf::st_coordinates(x)
    if (nrow(xy) != nrow(x)) {
      stop("Geometry is not simple points (got ", nrow(xy),
           " coordinates for ", nrow(x), " features) -- ",
           "st_coordinates cannot be matched back row-for-row.", call. = FALSE)
    }

    out <- sf::st_drop_geometry(x)
    out$LONGITUDE <- as.numeric(xy[, "X"])
    out$LATITUDE  <- as.numeric(xy[, "Y"])
    rm(x, xy)
    out
  }

  lo <- max(min(cfg$years), sch$year_lo)
  hi <- min(max(cfg$years), sch$year_hi)

  if (!isTRUE(cfg$chunk_by_year)) return(read_block(lo, hi))

  blocks <- vector("list", hi - lo + 1L)
  for (i in seq_along(blocks)) {
    y <- lo + i - 1L
    blocks[[i]] <- read_block(y, y)
    n <- if (is.null(blocks[[i]])) 0L else nrow(blocks[[i]])
    fod_msg("  ", y, ": ", format(n, big.mark = ","), " records")
  }
  blocks <- blocks[!vapply(blocks, is.null, logical(1))]
  if (!length(blocks)) {
    stop("No records read for ", lo, "-", hi, call. = FALSE)
  }
  do.call(rbind, blocks)
}


fod_read <- function(gpkg, cfg = FODCFG) {

  sch <- fod_schema(gpkg, cfg)

  if (sch$year_lo > max(cfg$years) || sch$year_hi < min(cfg$years)) {
    stop("FODCFG$years (", min(cfg$years), "-", max(cfg$years),
         ") does not overlap the data (", sch$year_lo, "-", sch$year_hi, ")",
         call. = FALSE)
  }
  if (max(cfg$years) > sch$year_hi || min(cfg$years) < sch$year_lo) {
    fod_msg("note: data covers ", sch$year_lo, "-", sch$year_hi,
            ", requested ", min(cfg$years), "-", max(cfg$years))
  }

  fc <- if (sch$has_xy) fod_read_attrs(gpkg, sch, cfg)
        else            fod_read_geom(gpkg, sch, cfg)

  fod_msg("read ", format(nrow(fc), big.mark = ","), " records, ",
          ncol(fc), " columns")
  fc
}


fod_thin <- function(fc, cfg = FODCFG) {

  # FIRE_YEAR is stored as INTEGER in the GeoPackage but has been text in some
  # editions -- normalise before filtering.
  fc$FIRE_YEAR <- as.integer(fc$FIRE_YEAR)
  fc <- fc[!is.na(fc$FIRE_YEAR) & fc$FIRE_YEAR %in% cfg$years, , drop = FALSE]

  # Dates: the GeoPackage stores these as 'YYYY-MM-DD' text, older ACCDB
  # editions used a Julian day number. Handle both, and derive DOY if the
  # published *_DOY columns are absent.
  as_fod_date <- function(x) {
    if (inherits(x, "Date")) return(x)
    if (is.numeric(x)) return(as.Date(x - 2440588, origin = "1970-01-01"))
    as.Date(substr(as.character(x), 1, 10), format = "%Y-%m-%d")
  }

  for (pair in list(c("DISCOVERY_DATE", "DISCOVERY_DOY"),
                    c("CONT_DATE", "CONT_DOY"))) {
    dcol <- pair[1]; ycol <- pair[2]
    if (dcol %in% names(fc)) {
      fc[[dcol]] <- as_fod_date(fc[[dcol]])
      if (!ycol %in% names(fc)) {
        fod_msg("deriving ", ycol, " from ", dcol)
        fc[[ycol]] <- as.integer(format(fc[[dcol]], "%j"))
      }
    }
    if (ycol %in% names(fc)) fc[[ycol]] <- as.integer(fc[[ycol]])
  }

  fc$FIRE_SIZE <- as.numeric(fc$FIRE_SIZE)
  fc$LATITUDE  <- as.numeric(fc$LATITUDE)
  fc$LONGITUDE <- as.numeric(fc$LONGITUDE)

  for (ch in c("FIRE_SIZE_CLASS", "STATE", "NWCG_CAUSE_CLASSIFICATION")) {
    if (ch %in% names(fc)) fc[[ch]] <- as.character(fc[[ch]])
  }

  # Column order matches the old thinFOD.R output.
  fc <- fc[, intersect(cfg$keep, names(fc)), drop = FALSE]
  rownames(fc) <- NULL
  fc
}


# --- 4. verify ---------------------------------------------------------------

fod_verify <- function(fc, cfg = FODCFG) {

  cat("\n--- FODthin summary ------------------------------------------\n")
  cat("records      :", format(nrow(fc), big.mark = ","), "\n")
  cat("columns      :", paste(names(fc), collapse = ", "), "\n")
  cat("year range   :", min(fc$FIRE_YEAR), "-", max(fc$FIRE_YEAR), "\n")
  cat("acres burned :", format(round(sum(fc$FIRE_SIZE, na.rm = TRUE) / 1e6, 1),
                               nsmall = 1), "million\n")
  cat("lat range    :", sprintf("%.2f to %.2f",
                                min(fc$LATITUDE,  na.rm = TRUE),
                                max(fc$LATITUDE,  na.rm = TRUE)), "\n")
  cat("lon range    :", sprintf("%.2f to %.2f",
                                min(fc$LONGITUDE, na.rm = TRUE),
                                max(fc$LONGITUDE, na.rm = TRUE)), "\n")

  na_frac <- vapply(fc, function(x) mean(is.na(x)), numeric(1))
  cat("NA fraction  :\n")
  print(round(na_frac, 3))

  cat("\nrecords per year:\n")
  print(table(fc$FIRE_YEAR))

  if ("NWCG_CAUSE_CLASSIFICATION" %in% names(fc)) {
    cat("\ncause classification:\n")
    print(table(fc$NWCG_CAUSE_CLASSIFICATION, useNA = "ifany"))
  }

  # The 7th edition is documented as 2.66 million records / 209 million acres
  # across 1992-2024. Flag if we are far off that when pulling the full span.
  if (identical(range(cfg$years), c(1992L, 2024L))) {
    if (nrow(fc) < 2.5e6) {
      warning("Expected ~2.66M records for the full 1992-2024 span, got ",
              format(nrow(fc), big.mark = ","), call. = FALSE)
    }
  }

  # Compare against whatever FODthin.Rdata is currently on disk, if any.
  if (file.exists(cfg$out_file)) {
    e <- new.env()
    ok <- tryCatch({ load(cfg$out_file, envir = e); TRUE },
                   error = function(...) FALSE)
    if (ok && exists("fc", envir = e)) {
      old <- get("fc", envir = e)
      cat("\nexisting file:", format(nrow(old), big.mark = ","), "records,",
          min(old$FIRE_YEAR), "-", max(old$FIRE_YEAR), "\n")
      new_cols <- setdiff(names(fc), names(old))
      gone     <- setdiff(names(old), names(fc))
      if (length(new_cols)) cat("  columns added  :",
                                paste(new_cols, collapse = ", "), "\n")
      if (length(gone))     cat("  columns dropped:",
                                paste(gone, collapse = ", "), "\n")
      if (length(gone)) {
        warning("Columns present in the old FODthin.Rdata are missing from ",
                "the new one -- app.R may reference them.", call. = FALSE)
      }
    }
  }
  cat("--------------------------------------------------------------\n\n")
  invisible(TRUE)
}


# --- 5. driver ---------------------------------------------------------------

fod_main <- function(cfg = FODCFG) {

  if (!dir.exists("Data")) {
    stop("No ./Data directory -- run this from the project root ",
         "(setwd to the FireWxMapTypes_App folder).", call. = FALSE)
  }

  fod_msg("FPA-FOD ", cfg$edition, " (", cfg$release, ")")

  zip_path <- fod_download(cfg)
  gpkg     <- fod_extract(zip_path, cfg)
  fc       <- fod_read(gpkg, cfg)
  fc       <- fod_thin(fc, cfg)

  fod_verify(fc, cfg)

  # Back up the current file before overwriting -- this one is not in git.
  if (file.exists(cfg$out_file)) {
    bak <- paste0(cfg$out_file, ".bak")
    file.copy(cfg$out_file, bak, overwrite = TRUE)
    fod_msg("previous file backed up to ", bak)
  }

  save(fc, file = cfg$out_file, compress = "xz")
  fod_msg("wrote ", cfg$out_file, " (", fod_mb(cfg$out_file), " MB)")

  if (!isTRUE(cfg$keep_raw)) {
    unlink(cfg$raw_dir, recursive = TRUE)
    fod_msg("removed ", cfg$raw_dir)
  } else {
    fod_msg("raw download kept in ", cfg$raw_dir,
            " -- delete it once you're satisfied with the output")
  }

  fod_msg("done. Restart the app to pick up the new data.")
  invisible(fc)
}


# Sourcing this file defines the functions but does not run anything.
# Call fod_main() explicitly.
if (sys.nframe() == 0L && !interactive()) fod_main()
