# OPENDap request for NARR data
# https://psl.noaa.gov/data/gridded/data.narr.html
# MAC 02/22/25

###### NOT FINISHED --- see scratchNARR.R for correct download


library(ncdf4)
library(terra)

# Define the base OPeNDAP URL
#base_url <- "https://psl.noaa.gov/thredds/dodsC/Datasets/ncep.reanalysis2/pressure/rhum."
base_url <- "https://psl.noaa.gov/thredds/dodsC/Datasets/ncep.reanalysis2/pressure/hgt."
#base_url <- "http://psl.noaa.gov/thredds/dodsC/Datasets/NARR/monolevel/rhum.2m."


var="hgt"
#var="rhum"

# get study area of extent
states <- geodata::gadm(country = "USA", level = 1, path = tempdir())
#regionStates<-c("CT","ME","MA","NH","NJ","NY","PA","RI","VT")
regionStates<-c("AZ","NM")
aoi<-ext(states[states$NAME_1 %in% state.name[match(regionStates, state.abb)], ])+5

# Define your bounding box (latitude and longitude in degrees) extent(-84, -62, 35, 50)
#lat_min <- aoi[3]   # Minimum latitude
#lat_max <- aoi[4]   # Maximum latitude
#lon_min <- aoi[1] # Minimum longitude
#lon_max <- aoi[2]  # Maximum longitude

# manually set bounding box
lat_min <- 20   # Minimum latitude
lat_max <- 60   # Maximum latitude
lon_min <- -140 # Minimum longitude
lon_max <- -60  # Maximum longitude


# Initialize an empty SpatRaster to hold all years
r_stack <- NULL

# Loop through each year
for (year in 1992:2020) {
  tryCatch({
    # Construct the OPeNDAP URL for the year
    opendap_url <- paste0(base_url, year, ".nc")
    
    # Open the dataset
    nc <- nc_open(opendap_url)
    
    # Get latitude and longitude values from the dataset
    lat_values <- ncvar_get(nc, "lat")
    lon_values <- ncvar_get(nc, "lon")
    
    # Convert longitude to 0-360 range if needed
    lon_min_adj <- ifelse(lon_min < 0, lon_min + 360, lon_min)
    lon_max_adj <- ifelse(lon_max < 0, lon_max + 360, lon_max)
    
    # Find indices for bounding box
    lat_indices <- which(lat_values >= lat_min & lat_values <= lat_max)
    lon_indices <- which(lon_values >= lon_min_adj & lon_values <= lon_max_adj)
    
    # Validate indices
    if (length(lat_indices) == 0 || length(lon_indices) == 0) {
      stop(paste("Latitude or longitude indices are empty for year", year, ". Check your bounding box."))
    }
    
    # # Extract time variable to determine range dynamically
    # time_values <- ncvar_get(nc, "time")
    # time_start <- 0
    # time_end <- length(time_values) - 1  # Determine dynamically based on dataset
    # 
    # # Convert time values to dates
    # time_origin <- "1800-01-01"  # Time origin from metadata
    # dates <- as.Date(time_values / 24, origin = time_origin)  # Divide hours by 24 to get days
    
    # Determine the time indices for 18Z
    time_values <- ncvar_get(nc, "time")
    time_origin <- "1800-01-01"  # Adjust based on metadata
    dates <- as.Date(time_values / 24, origin = time_origin)  # Convert hours to days
    
    # Calculate the indices corresponding to 18Z
    # Assuming 4 time steps per day
    #time_step_per_day <- 4
    # set index 1=0Z, 4=18Z
    #idx=4
    #time_indices <- seq(idx, length(time_values), by = time_step_per_day)
    
    # Define pressure level index (500mb level), 6=500mb, 4=700mb
    level_index <- 1  # Confirm with dataset metadata
    
    # Extract subset of data
    hgt_500mb <- ncvar_get(
      nc,
      var,
      start = c(lon_indices[1], lat_indices[1], level_index, 1),
      count = c(length(lon_indices), length(lat_indices), 1, length(time_values))
    )
    
    # reorder matrix to lon,lat,time
    hgt_500mb <- aperm(hgt_500mb, c(2,1,3))
    
    # Close the dataset
    nc_close(nc)
    
    # Adjust longitude values for -180 to 180 range
    adjusted_lon_min <- ifelse(min(lon_values[lon_indices]) > 180, min(lon_values[lon_indices]) - 360, min(lon_values[lon_indices]))
    adjusted_lon_max <- ifelse(max(lon_values[lon_indices]) > 180, max(lon_values[lon_indices]) - 360, max(lon_values[lon_indices]))
    
    # Create a SpatRaster for the current year with corrected longitude extent
    r_year <- rast(
      hgt_500mb,
      ext = ext(adjusted_lon_min, adjusted_lon_max,
                min(lat_values[lat_indices]), max(lat_values[lat_indices])),
      crs = "EPSG:4326"
    )
    
    # subset time to 6-hr time slice each day
    # Assuming 4 time steps per day
    time_step_per_day <- 4
    # set index 1=0Z, 4=18Z
    idx=4
    time_indices <- seq(idx, length(time_values), by = time_step_per_day)
    r_year<-r_year[[time_indices]]
    
    # Assign dates to the raster layers
    time(r_year) <- dates[time_indices]
    
    # Add the current year's data to the main stack
    r_stack <- if (is.null(r_stack)) r_year else c(r_stack, r_year)
    
    cat("Successfully processed data for year:", year, "\n")
  }, error = function(e) {
    cat("Error processing data for year:", year, "-", conditionMessage(e), "\n")
  })
}

# Save the combined SpatRaster as a single GeoTIFF
output_file <- "./Data/Reanalysis2/R2_hgt_1000mb_1992_2020_CONUS.tif"
writeRaster(r_stack, output_file, filetype = "GTiff", overwrite = TRUE)

cat("All years successfully processed and saved as a single file:", output_file, "\n")

##### check level index
 library(ncdf4)
# 
# # Define the OPeNDAP URL for one year (e.g., 1979)
# opendap_url <- "https://psl.noaa.gov/thredds/dodsC/Datasets/ncep.reanalysis2/pressure/hgt.1979.nc"
 opendap_url <- "https://psl.noaa.gov/thredds/dodsC/Datasets/ncep.reanalysis2/pressure/rhum.1979.nc"
# 
# # Open the dataset
 nc <- nc_open(opendap_url)
# 
# # Get the pressure levels
 levels <- ncvar_get(nc, "level")
# 
# # Print levels for debugging
cat("Available pressure levels:\n", levels, "\n")

# Find the index for 500mb
level_index <- which(levels == 700)

if (length(level_index) == 0) {
  stop("500mb level not found in the dataset.")
} else {
  cat("The index for 500mb is:", level_index, "\n")
}

# Close the dataset
nc_close(nc)
#####




