# util/era5_common.R
# -----------------------------------------------------------------------------
# Shared helpers for the ERA5 pipeline. NOTHING IN HERE MAY DEPEND ON ggplot2,
# dplyr, maps, terra, shiny, or anything else the app needs but a headless build
# box does not. This file is sourced by:
#
#   util/era5_compare.R   (phase 0, laptop — adds the plotting stack itself)
#   util/build_era5.R     (phase 1, build server — needs only these)
#   util/gridpack.R       (phase 2, when it exists)
#
# It exists so the build server can run the acquisition without installing the
# 85-package app environment. Before this split, build_era5.R sourced
# era5_compare.R purely for five helpers and dragged ggplot2 + dplyr + maps in
# with them.
#
# Everything here is safe to source more than once and has no side effects
# beyond defining objects (and, on a headless Linux box, choosing a keyring
# backend — see setup_cds).
#
# MAC / drafted with Claude, 2026-08
# -----------------------------------------------------------------------------

# ============================ constants ======================================

G0 <- 9.80665  # WMO standard gravity, m s-2 (scope R3)

# Plausible geopotential height ranges by level, over this domain, any season.
# 500 mb is a hard assert per the scope doc; the others warn.
HGT_RANGE <- list(
  `500`  = list(lo = 4500, hi = 6100, hard = TRUE),
  `700`  = list(lo = 2400, hi = 3400, hard = FALSE),
  `1000` = list(lo = -500, hi =  600, hard = FALSE)   # below ground inland (R9)
)

# ============================ small utilities ================================

`%||%` <- function(a, b) if (is.null(a)) b else a

# flush() matters on the server: when stdout is a pipe rather than a terminal it
# is block-buffered, so without this a `journalctl -f` shows nothing for minutes
# and a run that is working looks like a run that has hung.
#
# Arguments are coerced with as.character() rather than handed straight to cat().
# cat() rejects anything list-like with "argument N (type 'list') cannot be
# handled by 'cat'" — and several perfectly ordinary things are list-like,
# including getRversion() and packageVersion(), both of which print fine
# everywhere else. A logging call that kills the run it is logging is a bad
# trade for a microsecond.
msg <- function(...) {
  parts <- vapply(list(...),
                  function(a) paste(as.character(a), collapse = " "),
                  character(1))
  cat(format(Sys.time(), "[%Y-%m-%d %H:%M:%S] "), parts, "\n", sep = "")
  try(flush(stdout()), silent = TRUE)
  invisible(NULL)
}

need_pkgs <- function(pkgs) {
  missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
  if (length(missing)) {
    stop("Missing packages: ", paste(missing, collapse = ", "),
         "\n  install.packages(c(", paste0('"', missing, '"', collapse = ", "), "))",
         "\n  (on the build server: Rscript build/bootstrap.R)",
         call. = FALSE)
  }
  invisible(TRUE)
}

# ============================ project root ===================================

# The old check demanded Data/FODthin.Rdata — a 34 MB fire-occurrence file that
# the acquisition build never reads. On a fresh server clone (Data/ is
# gitignored) that made the build refuse to start for want of a file it does not
# need. Identify the root by tracked files that are always present, and let each
# caller name the data files IT actually requires.
#
#   require_project_root()                          # build_era5.R
#   require_project_root("Data/FODthin.Rdata")      # era5_compare.R
PROJECT_MARKERS <- c("FireWxMapTypes_App.Rproj", "util/era5_common.R")

require_project_root <- function(extra = character()) {
  if (!all(file.exists(PROJECT_MARKERS))) {
    stop("This does not look like the FireWxMapTypes_App project root.\n",
         "  working directory: ", normalizePath(".", mustWork = FALSE), "\n",
         "  expected to find:  ", paste(PROJECT_MARKERS, collapse = ", "), "\n",
         "  On the laptop, open the .Rproj. On the server, run from the repo root\n",
         "  (the systemd unit sets WorkingDirectory for you).", call. = FALSE)
  }
  miss <- extra[!file.exists(extra)]
  if (length(miss)) {
    stop("Required data file(s) not found: ", paste(miss, collapse = ", "),
         "\n  Data/ is gitignored, so these do not arrive with a clone.",
         call. = FALSE)
  }
  invisible(TRUE)
}

# Back-compat: anything still calling the old name gets the old meaning.
check_project_root <- function() require_project_root("Data/FODthin.Rdata")

# ============================ CDS authentication =============================

ecmwfr_major <- function() {
  need_pkgs("ecmwfr")
  as.integer(unlist(utils::packageVersion("ecmwfr"))[1])
}

# ecmwfr 2.x stores the token via the keyring package. On a desktop that is the
# OS keychain; on a headless Linux box there is no Secret Service and no D-Bus
# session, so wf_set_key() either errors or (with backend "file") blocks on an
# interactive password prompt — which would hang an unattended systemd run at
# second zero.
#
# The "env" backend keeps the secret in the process environment. It does not
# persist between sessions, which is exactly right here: setup_cds() is called
# at the start of every run and re-sets the key from CDS_KEY each time, so
# persistence buys nothing and a plaintext keyring file on disk is a liability.
cds_keyring_backend <- function() {
  if (!is.null(getOption("keyring_backend"))) return(invisible(FALSE))
  if (nzchar(Sys.getenv("R_KEYRING_BACKEND")))  return(invisible(FALSE))
  if (.Platform$OS.type != "unix")              return(invisible(FALSE))
  if (identical(Sys.info()[["sysname"]], "Darwin")) return(invisible(FALSE))
  if (nzchar(Sys.getenv("DBUS_SESSION_BUS_ADDRESS"))) return(invisible(FALSE))
  options(keyring_backend = "env")
  msg("headless Linux detected (no D-Bus session): keyring backend = \"env\"")
  invisible(TRUE)
}

setup_cds <- function() {
  need_pkgs("ecmwfr")
  key <- Sys.getenv("CDS_KEY")
  if (!nzchar(key)) {
    stop("CDS_KEY not found in the environment. Add it to .Renviron as\n",
         "  CDS_KEY=<your CDS personal access token>\n",
         "then restart R. .Renviron is read from the working directory at R\n",
         "startup, so R must be started from the project root.", call. = FALSE)
  }
  cds_keyring_backend()
  v <- ecmwfr_major()
  if (v >= 2) {
    # ecmwfr 2.x: single PAT, user argument deprecated
    ecmwfr::wf_set_key(key = key)
    user <- NULL
  } else {
    # ecmwfr 1.x: legacy CDS wanted "UID:APIKEY"; the UID is the part before ":"
    user <- if (grepl(":", key, fixed = TRUE)) sub(":.*$", "", key) else "ecmwfs"
    ecmwfr::wf_set_key(user = user, key = key, service = "cds")
  }
  msg("ecmwfr ", as.character(utils::packageVersion("ecmwfr")),
      " configured for CDS", if (!is.null(user)) paste0(" (user ", user, ")") else "")
  user
}

# ============================ push notifications =============================

# ntfy (https://ntfy.sh) — HTTP POST to a topic URL, no account, no SDK. Set in
# .Renviron on the build server:
#
#   NTFY_TOPIC=firewx-build-<something-unguessable>
#   NTFY_SERVER=https://ntfy.sh        # optional, or your own instance
#   NTFY_TOKEN=tk_...                  # optional, only for protected topics
#
# A topic name IS the credential on the public server: anyone who knows it can
# read and post. Use a long random suffix and do not commit it.
#
# With NTFY_TOPIC unset every call below is a silent no-op, so the same scripts
# run unchanged on the laptop. Notification failure never fails the build — a
# dead network is the build's problem to report, not a reason to stop.

ntfy_enabled <- function() nzchar(Sys.getenv("NTFY_TOPIC"))

#' @param body     message text
#' @param title    short headline shown in the notification
#' @param priority min | low | default | high | urgent
#' @param tags     emoji shortcodes, e.g. c("white_check_mark"), c("rotating_light")
notify <- function(body, title = NULL, priority = "default", tags = NULL) {
  if (!ntfy_enabled()) return(invisible(FALSE))
  server <- sub("/+$", "", Sys.getenv("NTFY_SERVER", "https://ntfy.sh"))
  url    <- paste0(server, "/", Sys.getenv("NTFY_TOPIC"))
  token  <- Sys.getenv("NTFY_TOKEN")
  hdrs   <- c(Priority = priority)
  if (!is.null(title)) hdrs["Title"] <- title
  if (!is.null(tags))  hdrs["Tags"]  <- paste(tags, collapse = ",")
  if (nzchar(token))   hdrs["Authorization"] <- paste("Bearer", token)

  ok <- tryCatch({
    if (requireNamespace("httr", quietly = TRUE)) {
      r <- httr::POST(url, httr::add_headers(.headers = hdrs),
                      body = body, encode = "raw", httr::timeout(15))
      httr::status_code(r) < 300
    } else {
      # curl(1) is present on Ubuntu Server and on Windows 10+; no R dependency.
      args <- c("-fsS", "--max-time", "15",
                unlist(lapply(names(hdrs), function(h)
                  c("-H", sprintf("%s: %s", h, hdrs[[h]])))),
                "-d", body, url)
      system2("curl", args, stdout = FALSE, stderr = FALSE) == 0L
    }
  }, error = function(e) FALSE)
  if (!isTRUE(ok)) msg("  (ntfy delivery failed — continuing)")
  invisible(isTRUE(ok))
}

# Convenience wrappers so call sites read as intent, not as HTTP headers.
notify_start <- function(body)
  notify(body, title = "FireWx build started",  priority = "low",
         tags = "hourglass_flowing_sand")
notify_progress <- function(body)
  notify(body, title = "FireWx build progress", priority = "min",
         tags = "chart_with_upwards_trend")
notify_warn <- function(body)
  notify(body, title = "FireWx build warning",  priority = "high",
         tags = "warning")
notify_fail <- function(body)
  notify(body, title = "FireWx build FAILED",   priority = "urgent",
         tags = "rotating_light")
notify_done <- function(body)
  notify(body, title = "FireWx build complete", priority = "default",
         tags = "white_check_mark")

# Human-readable duration for notification bodies.
fmt_dur <- function(secs) {
  secs <- as.numeric(secs)
  if (secs < 90) return(sprintf("%.0f s", secs))
  if (secs < 5400) return(sprintf("%.0f min", secs / 60))
  sprintf("%.1f h", secs / 3600)
}
