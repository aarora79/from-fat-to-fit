library(gt)
library(xts)
library(zoo)
library(glue)
library(dplyr)
library(tidyr)
library(waffle)
library(ggplot2)
library(stringr)
library(janitor)
library(ggthemes)
library(kableExtra)
library(lubridate)
library(tidyverse)
library(futile.logger)

source("globals.R")

# read the data, this comes from the biomettracker repo
# sometimes due to a bug in the weight measurement machine
# the lean mass and weight come as the same value, this is not 
# correct so we set the lean mass to NA in that case.
df_P1 <- read_csv(P1_DATA_URL) %>%
  mutate(Date=ymd(Date)) %>%
  mutate(`Lean Mass` = ifelse(`Lean Mass` == Weight, NA, Weight))
df_P2 <- read_csv(P2_DATA_URL) %>%
  mutate(Date=ymd(Date))%>%
  mutate(`Lean Mass` = ifelse(`Lean Mass` == Weight, NA, Weight))

df_p1_starting_weight <- df_P1 %>% filter(year(Date) == 2020) %>% filter(Date == min(Date, na.rm=TRUE)) %>% pull(Weight)
df_p2_starting_weight <- df_P2 %>% filter(year(Date) == 2020) %>% filter(Date == min(Date, na.rm=TRUE)) %>% pull(Weight)

df_starting_and_target_weights <- data.frame(name=c(P1_NAME, P2_NAME),
                                             Starting=c(df_p1_starting_weight, df_p2_starting_weight),
                                             Target=c(P1_TARGET_WEIGHT, P2_TARGET_WEIGHT),
                                             Ideal=c(P1_IDEAL_WEIGHT, P2_IDEAL_WEIGHT))

df_starting_and_target_weights <- df_starting_and_target_weights %>% 
  gather(metric, value, -name) %>%
  mutate(metric = paste0(metric, " Weight"),
         value = as.numeric(value))

# in this section of the code we will do all our data reading, cleaning, wrangling...basically
# everything except the timeseries forecasting bit so that the rest of the sections simply display the 
# charts based on the data analysis done here. The forecasting is left to its own section later in the code
# because it is based on user input and so it needs to be done redone whenever the input changes.

# read the raw data for person 1, print basic summary and metadata
df_P1 <- read_csv(P1_DATA_URL) %>%
  mutate(name=P1_NAME) %>%
  arrange(Date) %>%
  mutate(Date=ymd(Date)) %>%
  filter(Date >= START_DATE) %>%
  mutate(`Lean Mass` = ifelse(`Lean Mass` == Weight, NA, Weight))
# read the raw data for person 2, ultimately we want to have this dashboard work the same way
# even if there was only person 1 so put the following in an if checl
if(!is.na(P2_NAME)) {
  df_P2 <- read_csv(P2_DATA_URL) %>%
    mutate(name=P2_NAME) %>%
    arrange(Date) %>%
    mutate(Date=ymd(Date)) %>%
    filter(Date >= START_DATE) %>%
    mutate(`Lean Mass` = ifelse(`Lean Mass` == Weight, NA, Weight))
}
# read the important dates csv file. This is needed because we would like to annotate this journey
# so that we can say oh right there was an increase in weight for these days and it followed a birthday party, for example...
if(!is.na(IMPORTANT_DATES_FPATH)) {
  important_dates <- read_csv(IMPORTANT_DATES_FPATH)
}
# combine the dataframes, we want to do a side by side analysis for both people
if(!is.na(df_P2)) {
  df <- bind_rows(df_P1, df_P2)
} else {
  df <- df_P1
}
# get the data in tidy format i.e. Each variable must have its own column.
# Each observation must have its own row.
# Each value must have its own cell.
# see https://r4ds.had.co.nz/tidy-data.html
df_tidy <- df %>%
  gather(metric, value, -Date, -name) %>%
  mutate(value=as.numeric(value))

# determine the per day weight loss dataframe by
# calculating loss as weight - the one previous value of weight
# this is done by first grouping the dataframe by name since it has
# data for two people and then arranging by date while maintaining
# the grouping (NOTE: .by_group=TRUE)
df_wt_loss <- df_tidy %>%
  filter(metric=="Weight") %>%
  select(name, Date, value) %>%
  group_by(name) %>%
  arrange(Date, .by_group=TRUE) %>%
  mutate(loss_per_day = -1*(value-lag(value, 1)))  %>%
  mutate(loss_per_day_7_day_ma=rollapply(loss_per_day, 7, mean,align='right',fill=NA))
# is the curse of the weekend real? Assign the day to each date so that we can determine
# if say the weight loss eventually after the weekend was very less or maybe not even there...
df_wt_loss <- df_wt_loss %>%
  mutate(day = weekdays(as.Date(Date)))
# determine how much of theweight loss target has been achieved, this is done by finding the starting
# weight (configured), target weight (configured) and seeing how far each person has reached based on
# what their current weight is. This percentage is used to display a gauge (like the needle of a speedometer)
p1_starting_weight <- df_tidy %>% filter(name==P1_NAME & metric=="Weight") %>% head(1) %>% pull(value)
p1_latest_weight <- df_tidy %>% filter(name==P1_NAME & metric=="Weight") %>% tail(1) %>% pull(value)
# weight loss would be negative when calculated so multiply by -1
p1_wt_lost_as_pct <- -1*100*((p1_latest_weight-p1_starting_weight)/p1_starting_weight)
p2_starting_weight <- df_tidy %>% filter(name==P2_NAME & metric=="Weight") %>% head(1) %>% pull(value)
p2_latest_weight <- df_tidy %>% filter(name==P2_NAME & metric=="Weight") %>% tail(1) %>% pull(value)
p2_wt_lost_as_pct <- -1*100*((p2_latest_weight-p2_starting_weight)/p2_starting_weight)
p1_target_achieved_pct <- (p1_starting_weight-p1_latest_weight)/(p1_starting_weight-P1_TARGET_WEIGHT)*100
p2_target_achieved_pct <- (p2_starting_weight-p2_latest_weight)/(p2_starting_weight-P2_TARGET_WEIGHT)*100
# daily weight loss, this is important for a lot of charts and tables
# not the use of group by (name) and then lag. The dataframe is already sorted
# in asc order of time, so if the weight is reducing the daily_wt_loss would be a 
# -ve number, for several charts and tables this is multiplied with -1 so provide
# the absolute loss
df_daily_wt_loss <- df_tidy %>%
  filter(metric == "Weight") %>%
  group_by(name) %>%
  mutate(daily_wt_loss = value - lag(value))
# how many days did it take for each pound to drop? This is found by finding the max date i.e. the last date
# on which each weight (as a whole number, so 230, 229 etc) was seen and then subtracting that date from
# the last date of the previous highest weight. So if 230 was say the 20th pound to drop (if we started from 250 say)
# then the number of days between 231 and 230 becomes the number of days it took to lose the 20th pound.
df_days_to_next_drop <- df_daily_wt_loss %>%
  mutate(value = floor(value)) %>%
  ungroup() %>%
  group_by(name, value) %>%
  summarize(Date=max(Date)) %>%
  arrange(desc(Date)) %>%
  mutate(value_diff=value-lag(value), days=abs(as.numeric(Date-lag(Date)))) %>%
  replace_na(list(value_diff = 0, days = 0)) %>%
  mutate(value=value-min(value)) %>%
  filter(value != 0)
# read the precalculated forecasts and target achievement data 
# this is needed because shinyapps.io does not support Prophet (in the sense there are errors in installing it)
df_forecast_p1 <- read_csv(P1_FORECAST_FPATH) %>%
  select(y, yhat, yhat_lower, yhat_upper, ds) %>%
  mutate(ds=as.Date(ds)) %>%
  left_join(df_tidy %>%
              select(Date, metric, value, name) %>%
              filter(name==P1_NAME & metric == "Weight") %>%
              group_by(Date) %>%
              filter(value==min(value)) %>%
              ungroup(),
            by = c("ds"="Date")) %>%
  mutate(y = value, ds=ymd(ds)) %>%
  select(-metric, -value, -name)


df_target_achieved_p1 <- read_csv(P1_TARGET_ACHIEVED_FPATH)
df_forecast_p2 <- read_csv(P2_FORECAST_FPATH) %>%
  select(y, yhat, yhat_lower, yhat_upper, ds) %>%
  mutate(ds=as.Date(ds)) %>%
  left_join(df_tidy %>% 
              select(Date, metric, value, name) %>% 
              filter(name==P2_NAME & metric == "Weight") %>%
              group_by(Date) %>%
              filter(value==min(value)) %>%
              ungroup(),
            by = c("ds"="Date")) %>%
  mutate(y = value, ds=ymd(ds)) %>%
  select(-metric, -value, -name)


df_target_achieved_p2 <- read_csv(P2_TARGET_ACHIEVED_FPATH)
# read body measurements file
df_measurements <- read_csv(MEASUREMENTS_FPATH)
df_measurements <- df_measurements %>%
  filter(measurement %in% MEASUREMENTS_TO_KEEP)

# table for different types of exercises
df_exercises <- read_csv(EXERCISES_URL) 

# exercise dates for calendar plot
df_exercise_dates <- read_csv(EXERCISE_DATES_URL)  %>%
  mutate(date=ymd(date)) 
df_deadlifts <- read_csv(P2_DEADLIFT_URL)

# references
# df_references <- read_csv(REFERENCES_URL)


# clean eating list
df_clean_eating_list <- read_csv(CLEAN_EATING_URL) %>%
  replace_na(list(`(Optional) Notes` = ""))

# break up of days, how many days did we lose wieght, gain weight, no change
p1_days_counts <- df_wt_loss %>%
  filter(name == P1_NAME) %>%
  ungroup() %>%
  select(Date, loss_per_day) %>%
  drop_na() %>%
  mutate(category = case_when(
    loss_per_day > 0 ~ "Weight Loss",
    loss_per_day < 0 ~ "Weight Gain",
    loss_per_day == 0 ~ "No Change"
  )) %>%
  count(category, sort=FALSE) %>%
  mutate(category_label = glue("{category} ({n} days)")) %>%
  select(-category)

p1_days_total <- sum(p1_days_counts$n)
p1_days_counts_as_list <- unlist(p1_days_counts$n)
names(p1_days_counts_as_list) <- p1_days_counts$category_label

p2_days_counts <- df_wt_loss %>%
  filter(name == P2_NAME) %>%
  ungroup() %>%
  select(Date, loss_per_day) %>%
  drop_na() %>%
  mutate(category = case_when(
    loss_per_day > 0 ~ "Weight Loss",
    loss_per_day < 0 ~ "Weight Gain",
    loss_per_day == 0 ~ "No Change"
  )) %>%
  count(category, sort=FALSE) %>%
  mutate(category_label = glue("{category} ({n} days)")) %>%
  select(-category)

p2_days_total <- sum(p2_days_counts$n)
p2_days_counts_as_list <- unlist(p2_days_counts$n)
names(p2_days_counts_as_list) <- p2_days_counts$category_label

workouts <- read_csv("https://raw.githubusercontent.com/aarora79/biomettracker/master/raw_data/exercises_w_details.csv")

col_for_list <- list(exercise=md("**Exercise**"), 
                     muscle_group_or_body_part=md("**Body part/Muscle Group**"))

strength_workout_table <- workouts %>%
  filter(exercise_type=='Strength') %>%
  select(-exercise_type) %>%
  gt() %>%
  cols_label(.list = col_for_list)


strength_and_conditioning_workout_table <- workouts %>%
  filter(exercise_type=='Strength & Conditioning') %>%
  select(-exercise_type) %>%
  gt() %>%
  cols_label(.list = col_for_list)

core_workout_table <- workouts %>%
  filter(exercise_type=='Core') %>%
  select(-exercise_type) %>%
  gt() %>%
  cols_label(.list = col_for_list)

warmup_workout_table <- workouts %>%
  filter(exercise_type=='Warmup') %>%
  select(-exercise_type) %>%
  gt() %>%
  cols_label(.list = col_for_list)




df_wt_loss2 <- df_wt_loss %>%
  #ungroup() %>%
  drop_na() %>%
  mutate(clean_eating = ifelse(between(Date, df_iter1$Start, df_iter1$End),
                               "clean",
                               "careful-but-not-clean")) 
df_wt_loss_medians <- df_wt_loss2 %>%
  group_by(name, clean_eating) %>%
  summarize(med=round(median(loss_per_day, na.rm=TRUE), 4), .groups="keep")

df_wt_loss2 %>%
  drop_na() %>%
  filter(abs(loss_per_day) < 10) %>%
  ggplot(aes(x=name, y=loss_per_day, col=clean_eating)) + 
  geom_boxplot(show.legend = TRUE) +
  geom_text(data = df_wt_loss_medians,
            position=position_dodge(width=.75),
            aes(y = med, label = glue("{med} lb"), col=clean_eating), 
            size = 7, vjust = -.5, show.legend = FALSE) +
  #scale_y_continuous(breaks = seq(-2.5, 2.5, by = .5)) + 
  theme_fivethirtyeight() +
  xlab("") +
  theme(axis.title = element_text()) + ylab('Weight Loss (lb)/Day') +
  labs(title="Clean eating days Vs Others",
       subtitle=glue("Clean eating days clearly have a higher median per day weight loss."),
       caption=CAPTION) + 
  theme(text = element_text(size=CHART_ELEMENT_TEXT_SIZE), legend.title = element_blank()) + 
  scale_color_tableau() + 
  scale_fill_tableau()