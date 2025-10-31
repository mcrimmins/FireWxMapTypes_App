# updated version of app_v3.R; added FOD daily summary plots and daily weather maps
# github version control 
# MAC 2/25/25

library(shiny)
library(terra)
library(ggplot2)
library(maps)
library(dplyr)
library(tidyr)
library(plotly)
library(shinythemes)

# waiter message
message("Loading data...")

# Load data
load("./Data/FODthin.Rdata")
#fc <- sf::st_drop_geometry(fc)
us_states <- map_data("state")
us_states$region <- tools::toTitleCase(us_states$region)

# Load geopotential height and precipitation data
# look for data and helper scripts in /RProjects/FireWeatherScratch
# use getNARR_8xday.R to update/generate R2 data
gh500 <- terra::rast("./Data/R2_hgt_500mb_1992_2020_CONUS.tif")
gh700 <- terra::rast("./Data/R2_hgt_700mb_1992_2020_CONUS.tif")
gh1000 <- terra::rast("./Data/R2_hgt_1000mb_1992_2020_CONUS.tif")
precip90<-terra::rast("./Data/CPC_Global_precip_90dyPercAvg_1992_2020_CONUS_INT.tif")
#precip30<-terra::rast("./Data/CPC_Global_precip_30dyPercAvg_1992_2020_CONUS.tif")
precip14<-terra::rast("./Data/CPC_Global_precip_14dyPercAvg_1992_2020_CONUS_INT.tif")

# Adjust fire dates
fc$DISCOVERY_DATE <- as.Date(fc$DISCOVERY_DATE, "%m/%d/%Y")
fc$CONT_DATE <- as.Date(fc$CONT_DATE, "%m/%d/%Y")
fc$OPERATION_DAYS <- as.numeric(fc$CONT_DATE - fc$DISCOVERY_DATE)+1

# NEW: Determine min/max year from the dataset
fc$DISCOVERY_YEAR <- as.numeric(format(fc$DISCOVERY_DATE, "%Y"))
min_year <- min(fc$DISCOVERY_YEAR, na.rm = TRUE)  # e.g. 1992
max_year <- max(fc$DISCOVERY_YEAR, na.rm = TRUE)  # e.g. 2020


ui <- fluidPage(
  theme = shinytheme("spacelab"),    # <--- pick a theme here
  
  # Add the logo at the top of the page
  tags$div(
    style = "display: flex; align-items: center; justify-content: space-between; margin-bottom: 20px;",
    tags$h1("U.S. Wildfire & Weather Pattern Explorer"),
    tags$img(src = "UAlogo.jpg", height = "60px")  # Adjust the height as needed
  ),
  
  tags$head(tags$style("#loading-content { position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%); font-size: 24px; text-align: center; }")),
  #div(id = "loading-content", "Loading data..."),
  #titlePanel("U.S. Wildfire & Weather Pattern Explorer"),
  sidebarLayout(
    sidebarPanel(
      selectInput("states", "Select States:", choices = sort(unique(fc$STATE)), multiple = TRUE, selected = "AZ"),
      selectInput("height_level", "Select Geopotential Height Level:", choices = c("500mb" = "gh500", "700mb" = "gh700", "1000mb" = "gh1000"), selected = "gh500"),
      radioButtons(
        inputId = "precip_type",
        label = "Select % of Avg Precipitation Period:",
        choices = c("14-day" = "precip14",
                    #"30-day" = "precip30",
                    "90-day" = "precip90"),
        selected = "precip90"
      ),
      sliderInput("operation_days", "Filter by Operation Days:", min = min(fc$OPERATION_DAYS, na.rm = TRUE), max = max(fc$OPERATION_DAYS, na.rm = TRUE), value = c(min(fc$OPERATION_DAYS, na.rm = TRUE), max(fc$OPERATION_DAYS, na.rm = TRUE)), step = 1),
      sliderInput("month_range", "Select Month Range:", min = 1, max = 12, value = c(1, 12), step = 1, ticks = TRUE),
      # Year Range slider
      sliderInput(
        inputId = "year_range",
        label   = "Select Year Range:",
        min     = min_year,
        max     = max_year,
        value   = c(min_year, max_year),
        step    = 1,
        sep     = ""  # No thousands separator
      ),
      
      selectInput(
        inputId = "fire_size_class",
        label   = "Select Fire Size Class:",
        choices = sort(unique(fc$FIRE_SIZE_CLASS)),  # ensure sorted order
        multiple = TRUE, 
        selected = sort(unique(fc$FIRE_SIZE_CLASS))  # Start by including all classes by default
      ),
      
      sliderInput(
        inputId = "firesize_pctile",
        label   = "Filter by Fire Size Percentile Rank:",
        min     = 0,
        max     = 100,
        value   = c(0, 100),  # starts at full range
        step    = 1
      ),
      
      selectInput("cause_classification", "Select Cause Classification:", choices = c("All", sort(unique(fc$NWCG_CAUSE_CLASSIFICATION)))),
      selectInput("sort_metric", "Sort by:", choices = c("Fire Count" = "count", "Total Area Burned" = "area")),
      numericInput("top_days", "Number of Top Days to Display:", 12, min = 1, max = 30),
      sliderInput("expd", "Area of extent padding (in degrees):", min = 0.5, max = 10, value = 2, step = 0.5),
      
      # info on app
      tags$hr(), 
      p("This tool uses the Spatial wildfire occurrence database for the United States, 1992-2020 (FOD, Short 2022), NOAA-NCEP/DOE Reanalysis II for daily 18Z geopotential height data, and CPC Global Unified Gauge-Based Analysis of Daily Precipitation."),
      
      # Container div for logo and contact info
      div(
        style = "text-align: center;",  # center them (optional)
        
        # Logo image (assumes file is in www/my_logo.png)
        tags$img(src = "BP_app_logos.png", style = "width: 100%; height: auto;"),
        
        # Contact info
        tags$p("Contact: Mike Crimmins, crimmins@arizona.edu"),
        tags$p("https://cales.arizona.edu/climate/")
        
      )
      
      
    ),
    mainPanel(
      tabsetPanel(
        tabPanel("Extreme Fire Days", 
                 div(class = "left-align", plotOutput("fireMap", width="950px",height = "750px")),
                 DT::dataTableOutput("fireDaysTable")),
        tabPanel("Daily FOD Summary", plotlyOutput("fireSummaryPlot", width = "100%")),
        tabPanel("Daily Weather Maps", 
                 div(style = "display: flex; justify-content: center; align-items: center; height: 100px;",
                     #dateRangeInput("date_range", "Select Date Range:", start = min(fc$DISCOVERY_DATE),
                     #            end = min(fc$DISCOVERY_DATE)+29, min = min(fc$DISCOVERY_DATE), max = max(fc$DISCOVERY_DATE)),
                     dateInput("start_date", "Select first date:", value = min(fc$DISCOVERY_DATE), min = min(fc$DISCOVERY_DATE), max = max(fc$DISCOVERY_DATE)),
                     numericInput("days_range", "# days to plot:", value = 3, min = 1, max = 30)
                 ),
                 plotOutput("weatherMaps", width="900px",height = "700px")
        )
      )
    )
  )
)

server <- function(input, output, session) {
  # Hide loading message when session is ready
  observe({
    removeUI(selector = "#loading-content")
  })
  
  # precip selector
  getPrecipData <- reactive({
    switch(input$precip_type,
           "precip14" = precip14,
           #"precip30" = precip30,
           "precip90" = precip90)
  })
  
  # render maps
  output$fireMap <- renderPlot({
    req(input$states, input$height_level, input$sort_metric, input$top_days)
    
    #fireData <- subset(fc, STATE %in% input$states & OPERATION_DAYS >= input$operation_days[1] & OPERATION_DAYS <= input$operation_days[2])
    fireData <- subset(fc,
                       STATE %in% input$states &
                         # NEW: filter by year range
                         DISCOVERY_YEAR >= input$year_range[1] &
                         DISCOVERY_YEAR <= input$year_range[2] &
                         OPERATION_DAYS >= input$operation_days[1] &
                         OPERATION_DAYS <= input$operation_days[2])
    
    fireData <- fireData %>% filter(format(DISCOVERY_DATE, "%m") %in% sprintf("%02d", input$month_range[1]:input$month_range[2]))
    if (input$cause_classification != "All") {
      fireData <- fireData %>% filter(NWCG_CAUSE_CLASSIFICATION == input$cause_classification)
    }
    
    # Filter by Fire Size Class (if you have that input)
    if (!is.null(input$fire_size_class)) {
      fireData <- fireData %>%
        dplyr::filter(FIRE_SIZE_CLASS %in% input$fire_size_class)
    }
    
    # validate based on filters
    validate(
      need(nrow(fireData) > 0, "No fire data available for the selected filters.")
    )
    
    # calculate percent rank for filtering
    fireData$FIRE_SIZE_RANK <- (rank(fireData$FIRE_SIZE, na.last = "keep", ties.method = "random") / nrow(fireData))*100
    
    # NEW: Filter by Fire Size Percentile
    fireData <- fireData %>%
      dplyr::filter(FIRE_SIZE_RANK >= input$firesize_pctile[1],
                    FIRE_SIZE_RANK <= input$firesize_pctile[2])
    
    fireDays <- fireData %>%
      group_by(DISCOVERY_DATE) %>%
      summarise(FireCount = n(), TotalArea = sum(FIRE_SIZE, na.rm = TRUE)) %>%
      arrange(desc(FireCount))
    
    colnames(fireDays)[1] <- "Date"
    
    sortCol <- input$sort_metric
    fireDays <- if (sortCol == "count") {
      fireDays[order(fireDays$FireCount, decreasing = TRUE),]
    } else {
      fireDays[order(fireDays$TotalArea, decreasing = TRUE),]
    }
    
    selectDays <- unique(na.omit(fireDays$Date))[1:input$top_days]
    fireData <- fireData %>% filter(DISCOVERY_DATE %in% selectDays)
    fireData$Date <- factor(fireData$DISCOVERY_DATE, levels = selectDays)
    
    # subset geopotential height data
    #ghData <- if (input$height_level == "gh500") gh500 else gh700
    ##### adding 1000mb option
    ghData <- if (input$height_level == "gh500") {
      gh500
    } else if (input$height_level == "gh700") {
      gh700
    } else if (input$height_level == "gh1000") {
      gh1000
    }
    ######
    ghSub <- ghData[[which(time(ghData) %in% selectDays)]]
    names(ghSub) <- time(ghSub)
    gh_df <- as.data.frame(ghSub, xy = TRUE) %>%
      pivot_longer(cols = -c(x, y), names_to = "Date", values_to = "Geopotential_Height") %>%
      mutate(Date = as.Date(Date))
    
    # subset precipitation data
    # precipSub <- precip90[[which(time(precip90) %in% selectDays)]]
    # names(precipSub) <- time(precipSub)
    # precip_df <- as.data.frame(precipSub, xy = TRUE) %>%
    #   pivot_longer(cols = -c(x, y), names_to = "Date", values_to = "Precipitation") %>%
    #   mutate(Date = as.Date(Date))
    
    # Subset precipitation data based on selected dataset
    precipData <- getPrecipData()
    precipSub <- precipData[[which(time(precipData) %in% selectDays)]]
    names(precipSub) <- time(precipSub)
    precip_df <- as.data.frame(precipSub, xy = TRUE) %>%
      pivot_longer(cols = -c(x, y), 
                   names_to = "Date", 
                   values_to = "Precipitation") %>%
      mutate(Date = as.Date(Date))
    
    # Label for color scale
    precip_label <- switch(input$precip_type,
                           "precip14" = "14-day Precip (% of Avg)",
                           #"precip30" = "30-day Precip (% of Avg)",
                           "precip90" = "90-day Precip (% of Avg)")
    
    # define precip colorscale
    color_palette <- c("tan4","tan", "white","chartreuse2", "chartreuse4")  # Brown, White, Green
    breakpoints <- c(0,50,100,150,200)  # Define values corresponding to colors
    
    # adjust area of extent
    expd <- input$expd
    xmin <- min(fireData$LONGITUDE, na.rm = TRUE) - expd
    xmax <- max(fireData$LONGITUDE, na.rm = TRUE) + expd
    ymin <- min(fireData$LATITUDE, na.rm = TRUE) - expd
    ymax <- max(fireData$LATITUDE, na.rm = TRUE) + expd
    
    fireStats <- fireData %>%
      group_by(Date) %>%
      summarise(FireCount = n(), TotalArea = sum(FIRE_SIZE, na.rm = TRUE))
    fireStats$label <- paste0(fireStats$TotalArea, " / ", fireStats$FireCount)
    
    ggplot() +
      geom_tile(data = precip_df, aes(x = x, y = y, fill = Precipitation), alpha=0.7) +
      geom_point(data = fireData, aes(x = LONGITUDE, y = LATITUDE, size = FIRE_SIZE_CLASS), shape = 21, fill = "lightgrey", color = "black", stroke = 1, alpha = 0.8) +
      geom_contour(data = gh_df, aes(x = x, y = y, z = Geopotential_Height, color = after_stat(level)), binwidth = 10) +
      geom_path(data = us_states, aes(x = long, y = lat, group = group), color = "black", linewidth = 0.5) +
      #geom_text(data = fireStats, aes(x = xmin + 0.2, y = ymax - 0.2, label = label), inherit.aes = FALSE, hjust = 0, vjust = 1, size = 3, color = "black") +
      geom_label(data = fireStats, aes(x = xmin + 0.2, y = ymax - 0.2, label = label), inherit.aes = FALSE, hjust = 0, vjust = 1, size = 3, color = "black") +
      facet_wrap(~Date) +
      scale_color_gradientn(colors = c("blue", "cyan", "yellow", "orange", "red")) +
      scale_fill_gradientn(
        colors = color_palette,
        name = precip_label,
        values = scales::rescale(breakpoints, to = c(0, 1)),  # Rescale to 0-1 range
        limits = c(0, 200),  # Ensure out-of-bounds values are capped
        oob = scales::squish,  # Keeps values outside limits at the boundary colors
        breaks = c(0, 50, 100, 150,200),  # Define breaks
        labels = c("0", "50","100","150","200+")  # Label 600 as "600+"
      )+
      scale_size_manual(values = c("A" = 1, "B" = 2, "C" = 3, "D" = 4, "E" = 5, "F" = 6, "G" = 7)) +
      coord_fixed(ratio = 1, xlim = c(xmin, xmax), ylim = c(ymin, ymax)) +
      labs(title = paste(input$height_level, "Geopotential Height & Fire Locations"), x = "Longitude", y = "Latitude", color = "Geopotential Height (m)", size = "Fire Size Class") +
      theme_minimal() + theme(legend.position = "bottom")
    
  })
  
  # render summary plot
  output$fireSummaryPlot <- renderPlotly({
    req(input$states)
    
    fireData <- subset(fc, STATE %in% input$states)
    
    # Filter by Fire Size Class
    fireData <- fireData %>%
      filter(FIRE_SIZE_CLASS %in% input$fire_size_class)
    
    # calculate percent rank for filtering
    fireData$FIRE_SIZE_RANK <- (rank(fireData$FIRE_SIZE, na.last = "keep", ties.method = "random") / nrow(fireData))*100
    
    # NEW: Filter by Fire Size Percentile
    fireData <- fireData %>%
      dplyr::filter(FIRE_SIZE_RANK >= input$firesize_pctile[1],
                    FIRE_SIZE_RANK <= input$firesize_pctile[2])
    
    fireDays <- fireData %>%
      group_by(DISCOVERY_DATE) %>%
      summarise(count = n(), area = log(sum(FIRE_SIZE, na.rm = TRUE)))
    
    colnames(fireDays)[1] <- "Date"
    
    fireDays$year<-as.numeric(format(fireDays$Date,"%Y"))
    fireDays$doy<-as.numeric(format(fireDays$Date,"%j"))
    fireDays$plotDate<-as.Date(paste0(fireDays$doy,"-2000"),"%j-%Y")
    
    # Dynamically change the fill column based on user selection
    fill_col <- sym(input$sort_metric)  # Convert input string to a symbol for ggplot
    
    # Generate dynamic title
    dynamic_title <- if (input$sort_metric == "count") {
      "Daily Total Fire Count (based on Discovery Date)"
    } else {
      "Daily Total Area Burned (log-acres, based on Discovery Date)"
    }
    
    # Add tooltip text for hover interaction
    fireDays$tooltip_text <- paste0(
      "Date: ", format(fireDays$plotDate, "%b-%d"), "<br>",
      "Year: ", fireDays$year, "<br>",
      input$sort_metric, ": ", fireDays[[input$sort_metric]]
    )
    
    # Generate the ggplot
    p <- ggplot(fireDays, aes(x = plotDate, y = year, fill = !!fill_col, text = tooltip_text)) +
      geom_tile() +
      scale_x_date(date_labels = "%b", date_breaks = "1 month") +  
      scale_fill_viridis_c(option = "F", direction = -1) +
      theme_minimal() +
      labs(title=dynamic_title, x = "Day of Year", y = "Year", fill = input$sort_metric)
    # Convert to interactive plotly
    ggplotly(p, tooltip = "text")
    
  })
  
  
  # render table
  output$fireDaysTable <- DT::renderDataTable({
    req(input$states, input$sort_metric, input$top_days)
    
    #fireData <- subset(fc, STATE %in% input$states & OPERATION_DAYS >= input$operation_days[1] & OPERATION_DAYS <= input$operation_days[2])
    fireData <- subset(fc,
                       STATE %in% input$states &
                         # NEW: filter by year range
                         DISCOVERY_YEAR >= input$year_range[1] &
                         DISCOVERY_YEAR <= input$year_range[2] &
                         OPERATION_DAYS >= input$operation_days[1] &
                         OPERATION_DAYS <= input$operation_days[2])
    
    fireData <- fireData %>% filter(format(DISCOVERY_DATE, "%m") %in% sprintf("%02d", input$month_range[1]:input$month_range[2]))
    if (input$cause_classification != "All") {
      fireData <- fireData %>% filter(NWCG_CAUSE_CLASSIFICATION == input$cause_classification)
    }
    
    # Filter by Fire Size Class
    fireData <- fireData %>%
      filter(FIRE_SIZE_CLASS %in% input$fire_size_class)
    
    validate(
      need(nrow(fireData) > 0, "No fire data available for the selected filters.")
    )
    
    # calculate percent rank for filtering
    fireData$FIRE_SIZE_RANK <- (rank(fireData$FIRE_SIZE, na.last = "keep", ties.method = "random") / nrow(fireData))*100
    
    # NEW: Filter by Fire Size Percentile
    fireData <- fireData %>%
      dplyr::filter(FIRE_SIZE_RANK >= input$firesize_pctile[1],
                    FIRE_SIZE_RANK <= input$firesize_pctile[2])
    
    fireDays <- fireData %>%
      group_by(DISCOVERY_DATE) %>%
      summarise(FireCount = n(), TotalArea = sum(FIRE_SIZE, na.rm = TRUE)) %>%
      arrange(desc(FireCount))
    colnames(fireDays)[1] <- "Date"
    sortCol <- input$sort_metric
    fireDays <- if (sortCol == "count") {
      fireDays[order(fireDays$FireCount, decreasing = TRUE),]
    } else {
      fireDays[order(fireDays$TotalArea, decreasing = TRUE),]
    }
    fireDays[1:input$top_days, ]
  })
  
  
  # daily weather maps
  output$weatherMaps <- renderPlot({
    req(input$start_date, input$days_range, input$height_level, input$states, input$expd,input$cause_classification)
    # if (as.numeric(difftime(input$date_range[2], input$date_range[1], units = "days")) > 30) {
    #   showNotification("Date range cannot exceed 30 days", type = "error")
    #   return(NULL)
    # }
    
    #date_range <- seq(as.Date(input$date_range[1]), as.Date(input$date_range[2]), by = "day")
    date_range <- seq(as.Date(input$start_date), as.Date(input$start_date) + input$days_range - 1, by = "day")
    
    # ghData <- if (input$height_level == "gh500") gh500 else gh700
    # ghSub <- ghData[[which(time(ghData) %in% date_range)]]
    # 
    # if (length(ghSub) == 0) return(NULL)
    # 
    # names(ghSub) <- time(ghSub)
    # gh_df <- as.data.frame(ghSub, xy = TRUE) %>%
    #   pivot_longer(cols = -c(x, y), names_to = "Date", values_to = "Geopotential_Height") %>%
    #   mutate(Date = as.Date(Date))
    
    # subset geopotential height data
    ghData <- if (input$height_level == "gh500") gh500 else gh700
    ghSub <- ghData[[which(time(ghData) %in% date_range)]]
    names(ghSub) <- time(ghSub)
    gh_df <- as.data.frame(ghSub, xy = TRUE) %>%
      pivot_longer(cols = -c(x, y), names_to = "Date", values_to = "Geopotential_Height") %>%
      mutate(Date = as.Date(Date))
    
    
    # filter fire data
    fireData <- fc %>% filter(DISCOVERY_DATE %in% date_range)

    #fireData <- subset(fireData, STATE %in% input$states)
    fireData <- subset(fireData,
                       STATE %in% input$states &
                         # NEW: filter by year range
                         #DISCOVERY_YEAR >= input$year_range[1] &
                         #DISCOVERY_YEAR <= input$year_range[2] &
                         OPERATION_DAYS >= input$operation_days[1] &
                         OPERATION_DAYS <= input$operation_days[2])
    
    if (input$cause_classification != "All") {
      fireData <- fireData %>% filter(NWCG_CAUSE_CLASSIFICATION == input$cause_classification)
    }
    
    # Filter by Fire Size Class
    fireData <- fireData %>%
      filter(FIRE_SIZE_CLASS %in% input$fire_size_class)
    
    validate(
      need(nrow(fireData) > 0, "No fire data available for the selected filters.")
    )
    
    # calculate percent rank for filtering
    fireData$FIRE_SIZE_RANK <- (rank(fireData$FIRE_SIZE, na.last = "keep", ties.method = "random") / nrow(fireData))*100
    
    # NEW: Filter by Fire Size Percentile
    fireData <- fireData %>%
      dplyr::filter(FIRE_SIZE_RANK >= input$firesize_pctile[1],
                    FIRE_SIZE_RANK <= input$firesize_pctile[2])
    
    fireData$Date <- factor(fireData$DISCOVERY_DATE, levels = date_range)
    
    # subset precipitation data
    # precipSub <- precip90[[which(time(precip90) %in% date_range)]]
    # names(precipSub) <- time(precipSub)
    # precip_df <- as.data.frame(precipSub, xy = TRUE) %>%
    #   pivot_longer(cols = -c(x, y), names_to = "Date", values_to = "Precipitation") %>%
    #   mutate(Date = as.Date(Date))
    
    # Subset precipitation data based on input$precip_type
    precipData <- getPrecipData()
    precipSub <- precipData[[which(time(precipData) %in% date_range)]]
    validate(
      need(!is.null(precipSub) && nlyr(precipSub) > 0, 
           "No precipitation data available for these dates.")
    )
    names(precipSub) <- time(precipSub)
    precip_df <- as.data.frame(precipSub, xy = TRUE) %>%
      pivot_longer(cols = -c(x, y),
                   names_to = "Date",
                   values_to = "Precipitation") %>%
      mutate(Date = as.Date(Date))
    
    # Label for color scale
    precip_label <- switch(input$precip_type,
                           "precip14" = "14-day Precip (% of Avg)",
                           #"precip30" = "30-day Precip (% of Avg)",
                           "precip90" = "90-day Precip (% of Avg)")
    
    # define precip colorscale
    color_palette <- c("tan4","tan", "white","chartreuse2", "chartreuse4")  # Brown, White, Green
    breakpoints <- c(0,50,100,150,200)  # Define values corresponding to colors
    
    
    # adjust area of extent
    expd <- input$expd
    xmin <- min(fireData$LONGITUDE, na.rm = TRUE) - expd
    xmax <- max(fireData$LONGITUDE, na.rm = TRUE) + expd
    ymin <- min(fireData$LATITUDE, na.rm = TRUE) - expd
    ymax <- max(fireData$LATITUDE, na.rm = TRUE) + expd
    
    fireStats <- fireData %>%
      group_by(Date) %>%
      summarise(FireCount = n(), TotalArea = sum(FIRE_SIZE, na.rm = TRUE))
    fireStats$label <- paste0(fireStats$TotalArea, " / ", fireStats$FireCount)
    
    ggplot() +
      geom_tile(data = precip_df, aes(x = x, y = y, fill = Precipitation), alpha=0.7) +
      geom_point(data = fireData, aes(x = LONGITUDE, y = LATITUDE, size = FIRE_SIZE_CLASS), shape = 21, fill = "lightgrey", color = "black", stroke = 1, alpha = 0.8) +
      geom_contour(data = gh_df, aes(x = x, y = y, z = Geopotential_Height, color = after_stat(level)), binwidth = 10) +
      geom_path(data = us_states, aes(x = long, y = lat, group = group), color = "black", linewidth = 0.5) +
      #geom_text(data = fireStats, aes(x = xmin + 0.2, y = ymax - 0.2, label = label), inherit.aes = FALSE, hjust = 0, vjust = 1, size = 3, color = "black") +
      geom_label(data = fireStats, aes(x = xmin + 0.2, y = ymax - 0.2, label = label), inherit.aes = FALSE, hjust = 0, vjust = 1, size = 3, color = "black") +
      facet_wrap(~Date) +
      scale_color_gradientn(colors = c("blue", "cyan", "yellow", "orange", "red")) +
      scale_fill_gradientn(
        colors = color_palette,
        name = precip_label,
        values = scales::rescale(breakpoints, to = c(0, 1)),  # Rescale to 0-1 range
        limits = c(0, 200),  # Ensure out-of-bounds values are capped
        oob = scales::squish,  # Keeps values outside limits at the boundary colors
        breaks = c(0, 50, 100, 150,200),  # Define breaks
        labels = c("0", "50","100","150","200+")  # Label 600 as "600+"
      )+
      scale_size_manual(values = c("A" = 1, "B" = 2, "C" = 3, "D" = 4, "E" = 5, "F" = 6, "G" = 7)) +
      coord_fixed(ratio = 1, xlim = c(xmin, xmax), ylim = c(ymin, ymax)) +
      labs(title = paste(input$height_level, "Geopotential Height & Fire Locations"), x = "Longitude", y = "Latitude", color = "Geopotential Height (m)", size = "Fire Size Class") +
      theme_minimal() + theme(legend.position = "bottom")
    
  })
  
}

shinyApp(ui, server)
