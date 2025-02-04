# Time Series Forecasting: Machine Learning and Deep Learning with R & Python ----
# 12 March 2022


# Packages ----------------------------------------------------------------

setwd("/Users/mathiascardarellofierro/Documents/DSE/TS lab/tsforecasting-course-master")
source("R/utils.R")
source("R/packages.R") #error with catboost and treesnip

library(tidymodels)
library(modeltime)
library(modeltime.ensemble)
library(quantmod)



# Data --------------------------------------------------------------------

dataset <- read_rds("data/hackathon_dataset.rds")
# we have 20 series per each period type


## Part 1: Manipulation, Transformation & Visualization -----------------

# Manipulation ------------------------------------------------------------

# daily
dataset_daily <- dataset$data %>%
  filter(period == 'Daily')


# Visualization ------------------------------------------------------

dataset$data %>%
  filter(period == 'Daily') %>%
  group_by(id) %>%
  plot_time_series(date, value, 
                   .facet_ncol = 5, .facet_scales = "free",
                   .interactive = TRUE)

# Log Transforms
dataset$data %>%
  filter(period == 'Daily') %>%
  group_by(id) %>%
  plot_time_series(date, log(value+1), 
                   .facet_ncol = 5, .facet_scales = "free",
                   .interactive = TRUE)


# * Autocorrelation Function (ACF) Plot -----------------------------------

dataset$data %>%
  filter(period == 'Daily') %>%
  group_by(id) %>%
  plot_acf_diagnostics(date, log(value + 1), .lags = 10, 
                       .facet_ncol = 3, .facet_scales = "free",
                       .show_white_noise_bars = TRUE)


# * Smoothing Plot --------------------------------------------------------

dataset$data %>%
  filter(period == 'Daily') %>%
  group_by(id) %>%
  plot_time_series(date, log(value+1), 
                   .smooth_period = "90 days",
                   .smooth_degree = 1,
                   .facet_ncol = 5, .facet_scales = "free",
                   .interactive = TRUE)


# * Seasonality Plot ------------------------------------------------------

dataset$data %>%
  filter(period == 'Daily') %>%
  group_by(id) %>%
  plot_seasonal_diagnostics(date, log(value + 1))


# * Decomposition Plot ----------------------------------------------------

dataset$data %>%
  filter(id == "D1017") %>%
  plot_stl_diagnostics(date, log(value + 1))


# * Anomaly Detection Plot ------------------------------------------------

dataset$data %>%
  filter(id == "D1017") %>%
  tk_anomaly_diagnostics(date, value, .alpha = .01, .max_anomalies = .01)


# * Time Series Regression Plot -------------------------------------------

dataset$data %>%
  filter(id == "D1017") %>%
  plot_time_series_regression(
    date,
    log(value + 1) ~
      as.numeric(date) + # linear trend
      lubridate::wday(date, label = TRUE) + # week day calendar features
      lubridate::month(date, label = TRUE), # month calendar features
    .show_summary = TRUE
  )


# * Pad by Time -----------------------------------------------------------

# - Filling in time series gaps

#periods <- c('Hourly', 'Daily', 'Weekly', 'Monthly', 'Quarterly', 'Yearly')

#for (freq in periods){
#  dataset0 <- 0
#  dataset0 <- dataset$data %>%
#  filter(period == freq) %>%
#  group_by(id) %>%  
#  pad_by_time(.date_var = date, .pad_value = 0)
#  assign(paste("dataset", freq, sep = "_"), dataset0)
#}

dataset_hourly <- dataset$data %>%
  filter(period == "Hourly") %>%
  group_by(id) %>%  
  pad_by_time(.date_var = date, .by = "hour", .pad_value = 0)


dataset_daily <- dataset$data %>%
  filter(period == "Daily") %>%
  group_by(id) %>%  
  pad_by_time(.date_var = date, .by = "day", .pad_value = 0)


dataset_weekly <- dataset$data %>%
  filter(period == "Weekly") %>%
  group_by(id) %>%  
  pad_by_time(.date_var = date, .by = "week", .pad_value = 0)


#error
dataset_monthly <- dataset$data %>%
  filter(period == "Monthly") %>%
  group_by(id) %>%  
  pad_by_time(.date_var = date, .by = "month", .pad_value = 0)


dataset_yearly <- dataset$data %>%
  filter(period == "Yearly") %>%
  group_by(id) %>%  
  pad_by_time(.date_var = date, .by = "year", .pad_value = 0)


#error
dataset_quarterly <- dataset$data %>%
  filter(period == "Quarterly") %>%
  group_by(id) %>%  
  pad_by_time(.date_var = date, .by = "quarter", .pad_value = 0)



# Recipes -----------------------------------------------------------------

# Splitting Data
(dataset$data %>%
   filter(period == 'Daily') %>%
   group_by(id) %>%  
   tk_summary_diagnostics())


#14 days to forecast

nested_daily_data <- dataset$data %>%
  filter(period == 'Daily') %>%
  select(id, date, value) %>%
  # Step 1: Nest
  nest_timeseries(
    .id_var        = id,
    .length_future = 14
  ) %>%
  
  # Step 2: Splitting
  split_nested_timeseries(
    .length_test = 14
  )

nested_daily_data


## Part 2.A: Create Tidymodels Workflows -----------------

#First, we create tidymodels workflows for the various models 


# Prophet ------------------------------------------------------------

rec_prophet <- recipe(value ~ date, extract_nested_train_split(nested_daily_data)) 

wflw_prophet <- workflow() %>%
  add_model(
    prophet_reg("regression", seasonality_yearly = TRUE) %>% 
      set_engine("prophet")
  ) %>%
  add_recipe(rec_prophet)


# XGBoost ------------------------------------------------------------

rec_xgb <- recipe(value ~ ., extract_nested_train_split(nested_daily_data)) %>%
  step_timeseries_signature(date) %>%
  step_rm(date) %>%
  step_zv(all_predictors()) %>%
  step_dummy(all_nominal_predictors(), one_hot = TRUE)

wflw_xgb <- workflow() %>%
  add_model(boost_tree("regression") %>% set_engine("xgboost")) %>%
  add_recipe(rec_xgb)


## Part 2.B: Nested Modeltime Tables -----------------

nested_modeltime_tbl <- modeltime_nested_fit(
  # Nested data 
  nested_data = nested_daily_data,
  
  # Add workflows
  wflw_prophet,
  wflw_xgb
)

nested_modeltime_tbl



# Accuracy check ------------------------------------------------------------


tab_style_by_group <- function(object, ..., style) {
  
  subset_log <- object[["_boxhead"]][["type"]]=="row_group"
  grp_col    <- object[["_boxhead"]][["var"]][subset_log] %>% rlang::sym()
  
  object %>%
    tab_style(
      style = style,
      locations = cells_body(
        rows = .[["_data"]] %>%
          rowid_to_column("rowid") %>%
          group_by(!! grp_col) %>%
          filter(...) %>%
          ungroup() %>%
          pull(rowid)
      )
    )
}


nested_modeltime_tbl %>% 
  extract_nested_test_accuracy() %>%
  group_by(id) %>%
  table_modeltime_accuracy(.interactive = FALSE) %>%
  tab_style_by_group(
    rmse == min(rmse),
    style = cell_fill(color = "lightgreen")
  )


## Part 2.C: Make Ensembles -----------------

# Average Ensemble 

nested_ensemble_1_tbl <- nested_modeltime_tbl %>%
  ensemble_nested_average(
    type           = "mean", 
    keep_submodels = TRUE
  )

nested_ensemble_1_tbl

nested_ensemble_1_tbl %>% 
  extract_nested_test_accuracy() %>%
  group_by(id) %>%
  table_modeltime_accuracy(.interactive = FALSE) %>%
  tab_style_by_group(
    rmse == min(rmse),
    style = cell_fill(color = "lightgreen")
  )



# Weighted Ensemble

nested_ensemble_2_tbl <- nested_ensemble_1_tbl %>%
  ensemble_nested_weighted(
    loadings        = c(2,1),  
    metric          = "rmse",
    model_ids       = c(1,2), 
    control         = control_nested_fit(allow_par = FALSE, verbose = TRUE)
  ) 

nested_ensemble_2_tbl

nested_ensemble_2_tbl %>% 
  extract_nested_test_accuracy() %>%
  group_by(id) %>%
  table_modeltime_accuracy(.interactive = FALSE) %>%
  tab_style_by_group(
    rmse == min(rmse),
    style = cell_fill(color = "lightblue")
  )


## Part 3: Best models -----------------


best_nested_modeltime_tbl <- nested_ensemble_2_tbl %>%
  modeltime_nested_select_best(
    metric                = "rmse", 
    minimize              = TRUE, 
    filter_test_forecasts = TRUE
  )

best_nested_modeltime_tbl %>%
  extract_nested_best_model_report() %>%
  table_modeltime_accuracy(.interactive = TRUE)


# Forecast plot

best_nested_modeltime_tbl %>%
  extract_nested_test_forecast() %>%
  group_by(id) %>%
  filter(id == "D1142") %>%
  plot_modeltime_forecast(
    .facet_ncol  = 1,
    .interactive = TRUE
  )




