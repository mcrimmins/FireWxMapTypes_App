# reduce size of FOD dataset
# MAC 03/14/25

load("./oldVersions/FOD.RData")

fc <- sf::st_drop_geometry(fc)

names<-colnames(fc)
# keep certain columns by name
keep<-c("FIRE_YEAR","DISCOVERY_DATE","DISCOVERY_DOY",
        "NWCG_CAUSE_CLASSIFICATION",
        "CONT_DATE","CONT_DOY","FIRE_SIZE","FIRE_SIZE_CLASS","LATITUDE",
        "LONGITUDE","STATE")   

fc<-fc[,keep]
rm(keep,names)

save(fc, file="./Data/FODthin.Rdata")