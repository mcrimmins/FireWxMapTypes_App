# get fire data from NIFC
# https://data-nifc.opendata.arcgis.com/datasets/nifc::2025-wildland-fire-incident-locations-to-date/api
# https://data-nifc.opendata.arcgis.com/


library(httr)
library(sf)

# Customize your query URL
url <- "https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/WFIGS_Incident_Locations_YearToDate/FeatureServer/0/query"

params <- list(
  where = "1=1",
  # Optionally add spatial filter
  # geometry = "-113,34,-111,36",
  # geometryType = "esriGeometryEnvelope",
  inSR = "4269",
  spatialRel = "esriSpatialRelIntersects",
  outFields = "*",
  returnGeometry = "true",
  outSR = "4269",
  f = "geojson"
)

res <- httr::GET(url, query = params)
stop_for_status(res)

fire_sf <- sf::st_read(rawToChar(res$content))
print(fire_sf)
