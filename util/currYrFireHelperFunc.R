# functions to get current year fire occurrence and merge with thinned FOD
# MAC 08/18/25


# load libraries
library(sf)
library(httr)
library(dplyr)
library(lubridate)
#install.packages("tigris")
library(tigris)   # for states
library(sf)
library(stringr)


# function to get current year fire occurrence data
get_wfigs_data <- function(bbox = NULL, page_size = 2000, pause = 1) {
  base_url <- "https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/WFIGS_Incident_Locations_YearToDate/FeatureServer/0/query"
  
  params <- list(
    where = "1=1",
    outFields = "*",
    returnGeometry = "true",
    outSR = "4326",
    f = "geojson",
    resultRecordCount = page_size,
    resultOffset = 0
  )
  
  if (!is.null(bbox)) {
    params$geometry <- paste(bbox, collapse = ",")
    params$geometryType <- "esriGeometryEnvelope"
    params$spatialRel <- "esriSpatialRelIntersects"
    params$inSR <- "4326"
  }
  
  all_pages <- list()
  page <- 1
  
  repeat {
    message(sprintf("Fetching page %d (offset = %d)", page, params$resultOffset))
    res <- httr::GET(base_url, query = params)
    
    # Retry after delay if rate limited
    if (res$status_code == 429) {
      warning("Rate limit hit. Waiting 60 seconds...")
      Sys.sleep(60)
      next
    }
    
    stop_for_status(res)
    sf_page <- tryCatch(
      st_read(rawToChar(res$content), quiet = TRUE),
      error = function(e) NULL
    )
    
    if (is.null(sf_page) || nrow(sf_page) == 0) break
    
    all_pages[[page]] <- sf_page
    
    params$resultOffset <- params$resultOffset + page_size
    page <- page + 1
    
    Sys.sleep(pause)  # pause between requests
  }
  
  do.call(rbind, all_pages)
}
#####

# add in state column
add_state_column <- function(fire_sf) {
  options(tigris_use_cache = TRUE)
  
  # Load U.S. states polygon layer from TIGER/Line shapefiles
  states_sf <- tigris::states(cb = TRUE, year = 2023) %>%
    st_transform(crs = st_crs(fire_sf)) %>%
    select(STUSPS)  # STUSPS = 2-letter postal code
  
  # Perform spatial join
  fire_with_state <- st_join(fire_sf, states_sf, left = TRUE)
  fire_with_state$STATE <- fire_with_state$STUSPS
  
  return(fire_with_state)
}
#####

# massage to FOD thinned format
format_wfigs_to_fod <- function(fire_sf) {
  fire_sf %>%
    mutate(
      FIRE_YEAR = year(as_datetime(FireDiscoveryDateTime / 1000)),
      DISCOVERY_DATE = format(as_datetime(FireDiscoveryDateTime / 1000), "%m/%d/%Y"),
      DISCOVERY_DOY = yday(as_datetime(FireDiscoveryDateTime / 1000)),
      NWCG_CAUSE_CLASSIFICATION = case_when(
        str_detect(FireCause, "Human|Arson") ~ "Human",
        str_detect(FireCause, "Natural|Lightning") ~ "Natural",
        TRUE ~ "Undetermined"
      ),
      CONT_DATE = ifelse(!is.na(ContainmentDateTime),
                         format(as_datetime(ContainmentDateTime / 1000), "%m/%d/%Y"),
                         NA),
      CONT_DOY = ifelse(!is.na(ContainmentDateTime),
                        yday(as_datetime(ContainmentDateTime / 1000)),
                        NA),
      FIRE_SIZE = DiscoveryAcres,
      FIRE_SIZE_CLASS = case_when(
        FIRE_SIZE < 0.25 ~ "A",
        FIRE_SIZE < 10 ~ "B",
        FIRE_SIZE < 100 ~ "C",
        FIRE_SIZE < 300 ~ "D",
        FIRE_SIZE < 1000 ~ "E",
        FIRE_SIZE < 5000 ~ "F",
        FIRE_SIZE >= 5000 ~ "G",
        TRUE ~ NA_character_
      ),
      LATITUDE = st_coordinates(.)[, 2],
      LONGITUDE = st_coordinates(.)[, 1]
    ) %>%
    st_drop_geometry() %>%
    select(FIRE_YEAR, DISCOVERY_DATE, DISCOVERY_DOY,
           NWCG_CAUSE_CLASSIFICATION, CONT_DATE, CONT_DOY,
           FIRE_SIZE, FIRE_SIZE_CLASS, LATITUDE, LONGITUDE, STATE)
}
#####

# merge with FOD
merge_with_fod <- function(fod_df, wfigs_df) {
  bind_rows(fod_df, wfigs_df)
}
#####

# Example usage:
# Step 1: Download data
# wfigs <- get_wfigs_data()
# 
# # Step 2: Add state info
# wfigs<- add_state_column(wfigs)
# 
# # Step 3: Format to FOD structure
# wfigs<- format_wfigs_to_fod(wfigs)
# 
# # # Load data
# load("./Data/FODthin.Rdata")
# 
# # Step 4: Merge with your existing FOD dataset (fc)
# fc_combined <- merge_with_fod(fc, wfigs)


##### append current year Reanalysis 2 data

append_current_year_reanalysis <- function(existing_rast, year = format(Sys.Date(), "%Y"),
                                           level_index = 6,  # 6 = 500 mb, 4 = 700 mb
                                           var = "hgt",
                                           lon_min = -140, lon_max = -60,
                                           lat_min = 20, lat_max = 60,
                                           opendap_base = "https://psl.noaa.gov/thredds/dodsC/Datasets/ncep.reanalysis2/pressure/hgt.") {
  
  library(ncdf4)
  library(terra)
  
  tryCatch({
    url <- paste0(opendap_base, year, ".nc")
    nc <- nc_open(url)
    
    lat_vals <- ncvar_get(nc, "lat")
    lon_vals <- ncvar_get(nc, "lon")
    
    # Adjust longitudes if needed
    lon_min_adj <- ifelse(lon_min < 0, lon_min + 360, lon_min)
    lon_max_adj <- ifelse(lon_max < 0, lon_max + 360, lon_max)
    
    lat_idx <- which(lat_vals >= lat_min & lat_vals <= lat_max)
    lon_idx <- which(lon_vals >= lon_min_adj & lon_vals <= lon_max_adj)
    
    if (length(lat_idx) == 0 || length(lon_idx) == 0) stop("Lat/lon indices empty. Check bounds.")
    
    time_vals <- ncvar_get(nc, "time")
    dates <- as.Date(time_vals / 24, origin = "1800-01-01")
    
    # 18Z = 4th time index of each day
    t_idx <- seq(4, length(time_vals), by = 4)
    
    hgt_data <- ncvar_get(nc, var,
                          start = c(lon_idx[1], lat_idx[1], level_index, 1),
                          count = c(length(lon_idx), length(lat_idx), 1, length(time_vals)))
    nc_close(nc)
    
    hgt_data <- aperm(hgt_data, c(2, 1, 3))  # lat, lon, time
    
    lon_out <- ifelse(lon_vals[lon_idx] > 180, lon_vals[lon_idx] - 360, lon_vals[lon_idx])
    lat_out <- lat_vals[lat_idx]
    
    r_year <- rast(hgt_data,
                   ext = ext(min(lon_out), max(lon_out), min(lat_out), max(lat_out)),
                   crs = "EPSG:4326")
    r_year <- r_year[[t_idx]]
    time(r_year) <- dates[t_idx]
    
    # Append to existing raster
    combined <- c(existing_rast, r_year)
    return(combined)
    
  }, error = function(e) {
    message("Failed to append current year data: ", conditionMessage(e))
    return(existing_rast)
  })
}

# # Load existing dataset
# gh500 <- rast("./Data/R2_hgt_500mb_1992_2020_CONUS.tif")
# 
# # Append 2025 data (or whatever current year)
# gh500_updated <- append_current_year_reanalysis(gh500, 
#                                                 level_index = 6, # 6 = 500 mb, 4 = 700 mb
#                                                 year = 2025)


# get only current year Reanalysis 2 data
# Download current-year geopotential height data (500mb or 700mb)
# Author: MAC
# Date: 2025-xx-xx

get_current_year_reanalysis <- function(year = format(Sys.Date(), "%Y"),
                                        var = "hgt",
                                        level_index = 6,  # 6 = 500mb, 4 = 700mb
                                        lat_min = 20, lat_max = 60,
                                        lon_min = -140, lon_max = -60,
                                        base_url = "https://psl.noaa.gov/thredds/dodsC/Datasets/ncep.reanalysis2/pressure/hgt.") {
  
  library(ncdf4)
  library(terra)
  
  tryCatch({
    
    opendap_url <- paste0(base_url, year, ".nc")
    nc <- nc_open(opendap_url)
    
    # Get dimension values
    lat_values <- ncvar_get(nc, "lat")
    lon_values <- ncvar_get(nc, "lon")
    time_values <- ncvar_get(nc, "time")
    
    # Adjust longitudes if necessary (0–360)
    lon_min_adj <- ifelse(lon_min < 0, lon_min + 360, lon_min)
    lon_max_adj <- ifelse(lon_max < 0, lon_max + 360, lon_max)
    
    # Indexing for spatial subset
    lat_idx <- which(lat_values >= lat_min & lat_values <= lat_max)
    lon_idx <- which(lon_values >= lon_min_adj & lon_values <= lon_max_adj)
    
    # Time subset: extract every 4th step (18Z only)
    time_origin <- "1800-01-01"
    dates <- as.Date(time_values / 24, origin = time_origin)
    t_idx <- seq(4, length(time_values), by = 4)
    
    # Extract data: var[lon, lat, level, time]
    hgt_data <- ncvar_get(nc, var,
                          start = c(lon_idx[1], lat_idx[1], level_index, 1),
                          count = c(length(lon_idx), length(lat_idx), 1, length(time_values)))
    nc_close(nc)
    
    # Reorder to lat, lon, time
    hgt_data <- aperm(hgt_data, c(2, 1, 3))
    
    # Adjust longitudes back to -180:180
    lon_out <- ifelse(lon_values[lon_idx] > 180, lon_values[lon_idx] - 360, lon_values[lon_idx])
    lat_out <- lat_values[lat_idx]
    
    # Create SpatRaster
    r <- rast(hgt_data,
              ext = ext(min(lon_out), max(lon_out), min(lat_out), max(lat_out)),
              crs = "EPSG:4326")
    r <- r[[t_idx]]
    time(r) <- dates[t_idx]
    
    message("Downloaded current-year ", var, " data for ", year)
    return(r)
    
  }, error = function(e) {
    message("Error retrieving data for ", year, ": ", conditionMessage(e))
    return(NULL)
  })
}




