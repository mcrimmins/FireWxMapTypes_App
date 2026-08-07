# utility script to reduce the size of precip data
# convert to integer grids
# MAC 03/12/25

library(terra)
library(pryr)

r<-terra::rast("./Data/CPC_Global_precip_14dyPercAvg_1992_2020_CONUS.tif")
r_small <- round(r, 1)  # Reduce decimal precision
writeRaster(r_small,
            "./Data/CPC_Global_precip_14dyPercAvg_1992_2020_CONUS_INT.tif",
            datatype="INT2S", overwrite=TRUE)
