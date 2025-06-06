## QAQC manual discharge function
## AUTOMATED L1 QAQC SCRIPT FOR UGGA 
#This QAQC cleaning script was applied to create the data files included in this data package
## Authors: Dexter Howard and Adrienne Breef-Pilz
## Last edited: 12-19-2024 A. Breef-Pilz did major updates and added in a combine historical files, and subset data
## Additional notes: This script is included with this EDI package to show which QAQC has already been applied to generate these data. This script is only for internal use by the data creator team and is provided as a reference; it may not run as-is.



ManualDischarge_qaqc <- function(gsheet_url,
                                 historical_file,
                                 maintenance_file,
                                output_file,
				                        start_date,
				                        end_date){
  
  
  # gsheet_url = "https://docs.google.com/spreadsheets/d/1fgYcGsZeALuwdAX3H0UeA3u57zKsuqTkouh2bxuBTKw/"
  # historical_file = NULL
  # maintenance_file = "Data/DataNotYetUploadedToEDI/Raw_Discharge/ManualDischarge_Maintenance_Log.csv"
  # output_file = NULL
  # start_date = as.Date("2024-01-01")
  # end_date = Sys.Date()
  
#read in and format data

discharge_df <- gsheet::gsheet2tbl(gsheet_url)

discharge_df$DateTime = lubridate::parse_date_time(discharge_df$Date, orders = c('ymd HMS','ymd HM','ymd','mdy', 'mdy HMS', 'mdy HM'))


## calculate Q from flowmate 
flowmate_Q <- discharge_df %>% 
  filter(Method == "Flowmeter") %>%   #filter to just flowmate measurements 
  mutate(Depth_m = Depth_cm/100,    # convert depth to m from cm 
         Velocity_m.s = ifelse(Velocity_unit %in% c("ft_s", "ft/s"), Velocity*0.3048, Velocity),  #convert velocity to m/s if it was measured in ft/s
         Discharge = Depth_m * Velocity_m.s * WidthInterval_m      #calculate discharge for each interval 
         ) %>% 
  group_by(Reservoir, Site, DateTime) %>% #group by site and date
  mutate(Discharge_m3s = sum(Discharge, na.rm = T),  #sum across intervals to get final discharge
         Method = "F") %>%  #assign method flag 
  select(Reservoir, Site, DateTime, Discharge_m3s, Method) %>% 
  distinct(Reservoir, DateTime, Site, .keep_all = TRUE) %>% 
  ungroup() #ungroup data so that for loop below works


## calculate Q from float method 
float_Q <- discharge_df %>% 
  filter(Method == "Float") %>% #filter to float measurements
  mutate(Depth_m = Depth_cm/100,   # convert depth to meters
         Velocity_m.s = Float_Length_m/Float_Time_sec,  #calculate velocity 
         Discharge = Depth_m * Width_m * Velocity_m.s) %>%   # calculate discharge for each rep
  group_by(Reservoir, DateTime, Site) %>%  # group by site and date
  mutate(Discharge_m3s = mean(Discharge, na.rm = T),  #average across reps to get final Q
         Method = "V") %>%  # assign method flag
  select(Reservoir, Site, DateTime, Discharge_m3s, Method) %>% 
  distinct(Reservoir, DateTime, Site, .keep_all = TRUE) %>% 
  ungroup() #ungroup data so that for loop below works


## calculate Q from bucket method
bucket_Q <- discharge_df %>% 
  filter(Method == "Bucket") %>% #filter to bucket methods 
  mutate(Bucket_Volume_m3 = Bucket_Volume_L/1000,  #convert volume from L to cubic meters
         Discharge = Bucket_Volume_m3/Bucket_time_sec) %>%  #calculate discharge for each rep 
  group_by(Reservoir, DateTime, Site, Bucket_Site) %>%  #group by site and date and sub sites w/in each site (for tunnels with multiple outflow spouts from tunnel)
  mutate(Discharge_m3s = mean(Discharge, na.rm = T), .groups = "drop") %>% # get average from reps 
  group_by(Reservoir, DateTime, Site) %>%  # now group by just date and site
  mutate(Discharge_m3s = sum(Discharge_m3s, na.rm = T),  #sum across sites w/in each site (for tunnel sites with multiple outflow spouts from tunnel)
            Method = "B") %>%  #assign method flag
  select(Reservoir, Site, DateTime, Discharge_m3s, Method) %>% 
  distinct(Reservoir, DateTime, Site, .keep_all = TRUE) %>% 
  ungroup() #ungroup data so that for loop below works

##bind Q values together 
final_Q <- rbind(flowmate_Q, float_Q, bucket_Q)|>
  rename(Flow_cms = Discharge_m3s) # rename column

## Add in historical file

if(!is.null(historical_file)){
  
  his <- read_csv(historical_file)|>
    drop_na(Reservoir)
  
  # convert datetime into ymd
  
  his$DateTime <- lubridate::parse_date_time(his$DateTime, orders = c('ymd HMS','ymd HM',
                                                                                    'ymd','mdy', 
                                                                                    'mdy HMS', 'mdy HM'))
}else{
  his=NULL
}


### bind the historical file and the current file

curr_file <- bind_rows(his, final_Q)|>
  arrange(DateTime)|> 
  mutate(Flag_DateTime = 0,
    Flag_Flow_cms = 0) 


# subset the file if there are start and end dates

### identify the date subsetting for the data
if (!is.null(start_date)){
  #force tz check 
  start_date <- force_tz(as.POSIXct(start_date), tzone = "America/New_York")
  
  curr_file <- curr_file %>% 
    filter(DateTime >= start_date)
}

if(!is.null(end_date)){
  #force tz check 
  end_date <- force_tz(as.POSIXct(end_date), tzone = "America/New_York")
  
  curr_file <- curr_file %>% 
    filter(DateTime <= end_date)
}

# subset the maintenance log if there are start and end dates


## get datetimes and flag noon values
final_Q <- curr_file %>% 
  mutate(Time = format(DateTime,"%H:%M:%S"),
         Time = ifelse(Time == "00:00:00", "12:00:00",Time),
         Flag_DateTime = ifelse(Time == "12:00:00", 1, 0), # Flag if set time to noon
         Date = as.Date(DateTime),
         DateTime = ymd_hms(paste0(Date, "", Time), tz = "America/New_York"),
         Hours = hour(DateTime),
         DateTime = ifelse(Hours<5, DateTime + (12*60*60), DateTime), # convert time to 24 hour time
         DateTime = as_datetime(DateTime, tz = "America/New_York"))%>% # time is in seconds put it in ymd_hms
  select(-c(Time, Date, Hours))

## ADD MAINTENANCE LOG FLAGS (manual edits to the data for suspect samples or human error)

log_read <- read_csv(maintenance_file, col_types = cols(
  .default = col_character(),
  TIMESTAMP_start = col_datetime("%Y-%m-%d %H:%M:%S%*"),
  TIMESTAMP_end = col_datetime("%Y-%m-%d %H:%M:%S%*"),
  flag = col_integer()
))

# Filter maintenance log based on start and end times
if(!is.null(end_date)){
  log <- log_read |>
    filter(year(TIMESTAMP_start)<= end_date)
}else{
  log <- log_read
}


if(!is.null(start_date)){
  log <- log_read %>% 
    filter(TIMESTAMP_end >= start_date)
}else{
  log <- log_read
}

if(nrow(log)>0){

for(i in 1:nrow(log)){
  ### Assign variables based on lines in the maintenance log.

  ### get start and end time of one maintenance event
  start <- force_tz(as.POSIXct(log$TIMESTAMP_start[i]), tzone = "America/New_York")
  end <- force_tz(as.POSIXct(log$TIMESTAMP_end[i]), tzone = "America/New_York")

  ### Get the Reservoir Name
  Reservoir <- log$Reservoir[i]

  ### Get the Site Number
  Site <- as.numeric(log$Site[i])

  ### Get the Maintenance Flag
  flag <- log$flag[i]

  ### Get the new value for a column or an offset
  update_value <- as.numeric(log$update_value[i])

  ### Get the names of the columns affected by maintenance
  colname_start <- log$start_parameter[i]
  colname_end <- log$end_parameter[i]

  ### if it is only one parameter parameter then only one column will be selected

  if(is.na(colname_start)){

    maintenance_cols <- colnames(final_Q%>%select(colname_end))

  }else if(is.na(colname_end)){

    maintenance_cols <- colnames(final_Q%>%select(colname_start))

  }else{
    maintenance_cols <- colnames(final_Q%>%select(colname_start:colname_end))
  }

  if(is.na(end)){
    # If there the maintenance is on going then the columns will be removed until
    # and end date is added
    Time <- final_Q |> filter(DateTime >= start) |> select(DateTime)

  }else if (is.na(start)){
    # If there is only an end date change columns from beginning of data frame until end date
    Time <- final_Q |> filter(DateTime <= end) |> select(DateTime)

  }else {
    Time <- final_Q |> filter(DateTime >= start & DateTime <= end) |> select(DateTime)
  }

  ### This is where information in the maintenance log gets updated

  if(flag %in% c(3,5)){ ## UPDATE THIS WITH ANY NEW FLAGS
    # FLAG values that may not have been well captured by the method, keeping value but just adding flag based on method used

    final_Q[c(which(final_Q[,'Reservoir'] == Reservoir & final_Q[,'Site'] == Site & final_Q$DateTime %in% Time$DateTime)),paste0("Flag_",maintenance_cols)] <- as.numeric(flag)
    #final_Q[c(which(final_Q[,'Reservoir'] == Reservoir & final_Q[,'Site'] == Site & final_Q$DateTime %in% Time$DateTime)),maintenance_cols] <- as.numeric(update_value) #this was to change value to a new value; keeping for if making a new flag latter on

  } else if(flag %in% c(1)){ ## UPDATE THIS WITH ANY NEW FLAGS
    # FLAG and remove suspect values that should be set to NA
    
    final_Q[c(which(final_Q[,'Reservoir'] == Reservoir & final_Q[,'Site'] == Site & final_Q$DateTime %in% Time$DateTime)),paste0("Flag_",maintenance_cols)] <- as.numeric(flag)
    final_Q[c(which(final_Q[,'Reservoir'] == Reservoir & final_Q[,'Site'] == Site & final_Q$DateTime %in% Time$DateTime)),maintenance_cols] <- NA #to set value to NA
    
  } else{
    warning("Flag not coded in the L1 script. See Austin or Adrienne")
  }
}
}
#### END MAINTENANCE LOG CODE #####


if (!is.null(output_file)){
  # Write to CSV -- save as L1 file
  
  # format datetime as a character
  
  final_Q$DateTime <- as.character(format(final_Q$DateTime)) # convert DateTime to character
  
  write_csv(final_Q, output_file)
} else{

# If the output_file is Null then we want to use the file and we don't want to save it. 
  
return(final_Q)

}  
#write maint log as csv to data publishing folder
# Don't need to save the maintenance log here 
#write.csv(log, output_file, row.names = FALSE)


}

