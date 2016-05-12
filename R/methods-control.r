`:=` <- data.table::`:=`
`%chin%` <- data.table::`%chin%`

# Constructor for Control
init_control <- function(item_data,
                         item_names,
                         time_name,
                         geo_name,
                         group_names,
                         weight_name,
                         survey_name,
                         ...) {
  ctrl <- new("Control", item_names = item_names,
                 time_name = time_name, geo_name = geo_name, group_names =
                   group_names, weight_name = weight_name, survey_name =
                   survey_name, ...)

  is_name <- valid_names(item_data, ctrl, 1L)
  is_name(c("time_name", "geo_name"))
  has_type(c("time_name", "geo_name"), item_data, ctrl)
  if (!length(ctrl@time_filter)) {
    ctrl@time_filter <- sort(unique(item_data[[ctrl@time_name]]))
  }
  if (!length(ctrl@geo_filter)) {
    ctrl@geo_filter <- sort(unique(as.character(item_data[[ctrl@geo_name]])))
  }
  ctrl
}