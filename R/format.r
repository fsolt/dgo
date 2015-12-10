#'Format data for use with dgirt
#'
#' @param data Named `list` of `data.frame`s containing:
#'   \describe{
#'     \item{level1}{Survey responses at the lowest level of aggregation (e.g. individual).}
#'     \item{level2}{Survey responses at higher level
#'        of aggregation. Currently restricted to geographic units, and must be
#'        accompanied by `level2_modifiers`.}
#'     \item{targets}{Population targets for stratification. Strata in
#'        `level1` must be a subset of those in the target data,
#'        and there can't be missingness in the stratifying variables.}
#'   }
#' @param vars Named `list` of character vectors that give the variable or variables in representing:
#'   \describe{
#'     \item{items}{Item responses in `data$level1`}
#'     \item{groups}{Respondent characteristics in `data$level1`.}
#'     \item{time_id}{Time period in `data$level1` and `data$level2`.}
#'     \item{geo_id}{Geographic identifier in `data$level1` and `data$level2`.}
#'     \item{survey_id}{Survey identifier in `data$level1`.}
#'     \item{survey_weight}{Survey weight in `data$level1`.}
#'     \item{group_proportion}{Population proportions in `data$targets`.}
#'     \item{level2_modifiers}{Geographic characteristics in `data$level2`.}
#'     \item{level2_period1_modifiers}{Geographic characteristics in `data$level2` to be used in place of `vars$level2_modifiers` in the first period.}
#'   }
#' @param filters Named `list` of filters that will be applied to the data.
#'   \describe{
#'     \item{periods}{A character vector of time periods to be used in estimation,
#'        including unobserved periods or excluding observed periods as desired.
#'        Defaults to the values of the `vars$time_id` variable in the data.}
#'     \item{geo_ids}{A character vector giving the subset of values of `vars$geo_id` in the data to be used in estimation.
#'        Defaults to the values of `vars$geo_id` in the data.}
#'     \item{min_surveys}{A positive integer giving the minimum surveys in which an item must appear to be used in estimation.}
#'     \item{min_periods}{A positive integer giving the minimum periods in which an item must appear to be used in esimation.}
#'   }
#' @param params Named `list` of modeling choices.
#'   \describe{
#'     \item{separate_periods}{Logical for whether estimates should be pooled over time. No pooling if `TRUE`.}
#'     \item{constant_item}{Logical for whether item parameters should be constant over time.}
#'     \item{difficulty_count}{Number of difficulty parameters.}
#'   }
#' @return \code{list} List formatted for `run_dgirt`.
#' @export

format_data <- function(data = list(level1,
                                    level2 = NULL,
                                    targets = NULL),
                       vars = list(items,
                                   groups,
                                   time_id,
                                   geo_id,
                                   survey_id,
                                   survey_weight,
                                   group_proportion = NULL,
                                   level2_modifiers = NULL,
                                   level2_period1_modifiers = NULL),
                       filters = list(periods = NULL,
                                      geo_ids = NULL,
                                      min_surveys = 1L,
                                      min_periods = 1L),
                       params = list(separate_periods = FALSE,
                                     difficulty_count = 1L,
                                     constant_item = TRUE)){

  arg <- handle_arguments()
  level1 <- handle_data(arg$level1, arg)
  arg$level2 <- handle_data(arg$level2, arg)

  arg$demo_id <- "dgirt_demo"
  level1 <- level1 %>%
    dplyr::mutate(dgirt_demo = interaction(.[, arg$groups], drop = TRUE))

  # Drop rows lacking covariates or time variable
  level1 <- drop_rows_missing_covariates(level1, arg)
  level1 <- level1 %>% dplyr::filter_(lazyeval::interp(~!is.na(varname),
    varname = as.name(arg$demo_id)))

  # Filter data
  checks <- check_restrictions(level1, arg)
  # Find rows with no valid question responses
  level1$none_valid <- get_missing_respondents(level1[, arg$items])
  level1 <- apply_restrictions(level1, checks, arg)
  # Update arg$items
  arg$items <- intersect(arg$items, names(level1))

  # Create weights from population targets
  if (!is.null(arg$targets)) {
    level1 <- create_weights(level1, arg)
  }

  arg$use_geo <- update_use_geo(level1, arg)
  arg$use_t <- set_use_t(level1, arg)

  level1 <- subset_to_estimation_periods(level1, arg)
  if (!is.null(arg$level2)){
    arg$level2 <- subset_to_estimation_periods(arg$level2, arg)
  }

  # Create _gt. variables
  level1 <- createGT(d = level1, .items = arg$items)
  level1 <- drop_rows_missing_gt_variables(level1)

  # Fix levels of variables after filtering
  level1 <- droplevels(level1)

  arg$level2 <- subset_to_observed_geo_periods(arg)

  # Quick hack: observed periods should be be the periods observed after
  # dropping observations
  if (is.factor(level1[[arg$time_id]])) {
    checks$observed_periods <- levels(droplevels(level1[[arg$time_id]]))
  } else {
    checks$observed_periods <- unique(level1[[arg$time_id]])
  }
  checks$observed_periods <- as.character(checks$observed_periods)

  # Represent covariates in data as model frame
  f0 <- as.formula(paste("~", paste("0", arg$geo_id, arg$demo_id, sep = " + ")))
  f0_t <- as.formula(paste("~", paste("0", arg$geo_id, arg$demo_id, arg$time_id, sep = " + ")))
  MF <- model.frame(f0, data = level1, na.action = return)
  MF_t <- model.frame(f0_t, data = level1, na.action = return)
  # Get frequency counts of factor combinations (reordered in factor order)
  xtab_t <- as.data.frame(table(MF_t))
  stopifnot(checks$observed_periods[1] %in% as.character(xtab_t[[arg$time_id]]))
  xtab <- xtab_t %>%
    dplyr::filter_(lazyeval::interp(~ x %in% y, x = as.name(arg$time_id),
      y = checks$observed_periods[1])) %>%
    dplyr::select_(arg$geo_id, arg$demo_id, arg$time_id)
  stopifnot(nrow(xtab) > 0)

  # Create a variable counting the number of responses given by each respondent in the data
  level1$n_responses <- count_respondent_trials(level1)

  ## GROUPS ##

  # Create table of design effects
  design_effects <- summarize_design_effects(level1, arg)
  group_grid <- make_group_grid(level1, arg)
  # Create table of (adjusted) trial counts by geographic, demographic, and time variable combination
  trial_counts <- summarize_trial_counts(level1, design_effects, group_grid, arg)
  # Create table of (weighted) average outcomes within combinations of geographic, demographic, and time variables.
  mean_y <- summarize_mean_y(level1, group_grid, arg)
  # Take the product of the (weighted) average cell outcome and the (adjusted) trial count
  success_counts <- summarize_success_count(trial_counts, mean_y, arg)
  # Create a summary table: for each period t, are there any nonmissing responses?
  trials_by_period <- summarize_trials_by_period(trial_counts, arg)
  # Giving us the periods in which we observe responses, which may be different from the periods we"ll use in estimation (given in arg$use_t)
  checks$nonmissing_t <- as.character(trials_by_period$t[trials_by_period$any_valid])

  # NOTE: use_t must match nonmissing t at the moment

  # T gives the number of time periods
  T <- length(arg$use_t)
  # Q gives the number of questions
  Q <- count_questions(level1)
  # G gives the number of covariate combinations
  G <- count_covariate_combos(level1, arg)

  Gl2 <- count_level2_groups(arg$level2, xtab, arg)
  XX <- model.matrix(f0, xtab)

  # NOTE: not implemented
  # Calculate G x T x Gl2 weight matrix
  WT <- make_dummy_weight_matrix(T, Gl2, G)

  l2_only <- make_l2_only(trial_counts, level1, T, Q, arg)
  NNl2 <- make_NNl2(level1, T, Q, Gl2, arg)
  SSl2 <- NNl2

  ns_long_obs <- make_ns_long_obs(trial_counts, success_counts, arg)
  ns_long <- make_ns_long(ns_long_obs, arg)
  n_vec <- unlist(ns_long$n_grp)
  s_vec <- unlist(ns_long$s_grp)
  names(n_vec) <- ns_long$name
  names(s_vec) <- ns_long$name

  MMM <- make_missingness_array(ns_long, group_grid, arg)

  # The indicator matrix for hierarchical variables, XX, has as many columns as geographic units; drop one
  XX <- XX[, -1]

  # Assemble data for the geographic model
  ZZ <- createZZ(XX, arg)
  ZZ_prior <- createZZ(XX, arg)

  stan_data <- list(
    n_vec = n_vec,      # trial counts
    s_vec = s_vec,      # sums
    NNl2 = NNl2,
    SSl2 = SSl2,
    XX = XX,
    ZZ = ZZ,            # geographic predictors
    ZZ_prior = ZZ_prior,
    MMM = MMM,          # missingness array (T x Q x G)
    G = G,              # number of covariate groups
    Q = Q,              # number of questions (items)
    T = T,              # number of time units (years)
    N = length(n_vec),  # number of observed group-question cells
    P = ncol(XX),       # number of hierarchical parameters
    S = dim(ZZ)[[2]],   # number of geographic units
    H = dim(ZZ)[[3]],   # number of geographic-level predictors
    Hprior = dim(ZZ_prior)[[3]],
    separate_t = as.integer(arg$separate_periods),  # if 1, no pooling over time
    constant_item = as.integer(arg$constant_item),  # if 1, item parameters constant
    D = as.integer(arg$difficulty_count),           # number of difficulty parameters
    WT = WT,            # weight matrix for calculating level-two mean
    l2_only = l2_only,
    Gl2 = Gl2)          # number of second-level groups

  # Check dimensions against what Stan will expect
  with(stan_data, {
    stopifnot(identical(length(n_vec), length(s_vec)))
    stopifnot(identical(dim(NNl2), as.integer(c(T, Q, Gl2))))
    stopifnot(identical(dim(SSl2), as.integer(c(T, Q, Gl2))))
    stopifnot(identical(dim(MMM), c(T, Q, G)))
    stopifnot(identical(dim(WT), as.integer(c(T, Gl2, G))))
    stopifnot(identical(dim(l2_only), c(T, Q)))
    stopifnot(identical(dim(XX), c(G, P)))
    stopifnot(identical(dim(ZZ), c(T, P, H)))
    stopifnot(identical(dim(ZZ_prior), c(T, P, H)))
    stopifnot(!is.null(constant_item))
    stopifnot(!is.null(separate_t))
    })

  return(stan_data)
}

as_tbl <- function(dataframe){
  if (is.null(dataframe)) {
    return(NULL)
  } else {
    return(dplyr::as.tbl(dataframe))
  }
}

check_restrictions <- function(level1, .arg){
  checks <- list()
  # We need to find out which time periods are observed in the data
  checks$observed_periods <- get_t(level1[, .arg$time_id])

  # And which question columns have no valid responses
  checks$q_all_missing <- get_missing_items(level1, .arg$items)

  # And which variables don"t satisfy the min_periods requirement
  checks$q_when_asked <- get_question_periods(level1, .arg)
  checks$q_rare.t <- get_rare_items_over_t(checks, .arg)

  # And which variables don"t satisfy the min_surveys requirement
  checks$q_which_asked <- get_question_polls(level1, .arg)
  checks$q_rare.polls <- get_rare_items_over_polls(checks, .arg)

  return(checks)
}

get_question_periods <- function(.data, .arg) {
  .data %>%
    dplyr::group_by_(.arg$time_id) %>%
    dplyr::summarise_each_(~anyValid, vars = .arg$items)
}

get_rare_items_over_t <- function(.checks, .arg){
  stopifnot(is.integer(.arg$min_periods))
  q_t_count <- colSums(dplyr::select(.checks$q_when_asked, -one_of(.arg$time_id)))
  q_rare <- names(q_t_count)[q_t_count < .arg$min_periods]
  return(q_rare)
}

get_question_polls <- function(.data, .arg) {
  .data %>%
    dplyr::group_by_(.arg$survey_id) %>%
    dplyr::summarise_each(dplyr::funs(anyValid), one_of(.arg$items))
}

get_rare_items_over_polls <- function(.checks, ..arg){
  q_counts <- .checks$q_which_asked %>%
    dplyr::select(-one_of(..arg$survey_id)) %>%
    dplyr::summarise_each(dplyr::funs(sum))
  lt_min_surveys <- colnames(q_counts)[unlist(q_counts) < ..arg$min_surveys]
  lt_min_surveys
}

get_t <- function(t_data){
  observed_t <- unlist(t_data)
  stopifnot(is.factor(observed_t))
  observed_t <- droplevels(observed_t)
  levels(observed_t)
}

get_missing_items <- function(.data, item_names){
  nonmissing <- .data %>%
    dplyr::select(one_of(item_names)) %>%
    dplyr::summarise_each(~sum(!is.na(.)) > 0) %>%
    wrap_melt(id.vars = NULL) %>%
    dplyr::filter(value == FALSE)
  unlist(nonmissing$variable)
}

get_missing_respondents <- function(item_data){
  not_na <- !is.na(item_data)
  rowSums(not_na) == 0
}

summarize_design_effects <- function(.data, .arg){
  de_table <- .data %>%
    dplyr::group_by_(.arg$geo_id, .arg$demo_id, .arg$time_id) %>%
    dplyr::select_(.arg$survey_weight) %>%
    dplyr::summarise_(def = ~createDef(.[[.arg$survey_weight]])) %>%
    dplyr::arrange_(.arg$geo_id, .arg$demo_id, .arg$time_id)
  return(de_table)
}

summarize_trial_counts <- function(.data, design_effects, group_grid, .arg){
  trial_counts <- .data %>%
    # The _gt variables can take values of 0/1/NA
    dplyr::mutate_each(dplyr::funs(notNA), contains("_gt")) %>%
    # For a respondent who only answered questions A and B, we now have
    #  T,   T,   T,   T,   T,   F,   F.
    dplyr::mutate_each(dplyr::funs(. / n_responses), contains("_gt"))  %>%
    # Dividing the booleans by n_responses = 5 calculated earlier gives us
    #.02, .02, .02, .02, .02,   0,   0.
    dplyr::group_by_(.arg$geo_id, .arg$demo_id, .arg$time_id) %>%
    dplyr::summarise_each(dplyr::funs(sum), contains("_gt")) %>%
    dplyr::ungroup() %>%
    # Summing over respondents within the grouping variables gives the count
    # of trials for each combination of geo, demo, and time variables, divided
    # equally across the _gt indicators.
    # Joining the design effect table by the grouping variables attaches
    # the design effect associated with each variable combination.
    muffle_full_join(design_effects, by = c(.arg$geo_id, .arg$demo_id, .arg$time_id)) %>%
    dplyr::mutate_each(dplyr::funs(ceiling(. / def)), contains("_gt")) %>%
    # Dividing by the design effect gives us a design-effect-adjusted trial
    # count.
    dplyr::select(-def) %>%
    # Tidy up.
    dplyr::mutate_each_(~as.character, vars = c(.arg$geo_id, .arg$demo_id, .arg$time_id))

  # A dplyr::full_join of trial_counts and group_grid will create rows for the desired
  # covariate combinations, where unobserved cells take NA values
  trial_counts <- muffle_full_join(trial_counts, group_grid,
    by = c(.arg$geo_id, .arg$demo_id, .arg$time_id))
  # Replace the NA values in those rows representing unobserved covariate
  # combinations with zeroes
  trial_counts <- trial_counts %>% dplyr::mutate_each(~replaceNA, contains("_gt"))
  # NOTE: Order will matter in a moment
  trial_counts <- trial_counts %>% dplyr::arrange_(.arg$geo_id, .arg$demo_id, .arg$time_id) %>%
    dplyr::mutate_each(dplyr::funs(as.vector), contains("_gt"))
  return(trial_counts)
}

summarize_mean_y <- function(level1, group_grid, .arg){
  mean_y <- level1 %>%
    dplyr::group_by_(.arg$geo_id, .arg$demo_id, .arg$time_id) %>%
    dplyr::select_("contains('_gt')", "n_responses", .arg$survey_weight) %>%
    dplyr::mutate_(weight = lazyeval::interp(~ w / n,
      w = as.name(.arg$survey_weight), n = quote(n_responses))) %>%
    dplyr::summarise_each_(dplyr::funs(weighted.mean(as.vector(.), weight,
      na.rm = TRUE)), vars = "contains('_gt')") %>%
    dplyr::group_by_(.arg$geo_id, .arg$demo_id, .arg$time_id) %>%
    dplyr::mutate_each(dplyr::funs(replaceNaN)) %>%
    dplyr::ungroup() %>%
    dplyr::mutate_each_(~as.character, vars = c(.arg$geo_id, .arg$demo_id, .arg$time_id))

  # As above, create rows for unobserved but desired covariate combinations,
  # but this time leave the values as NA
  mean_y <- muffle_full_join(mean_y, group_grid,
    by = c(.arg$geo_id, .arg$demo_id, .arg$time_id)) %>%
      # NOTE: Order will matter in a moment
      dplyr::arrange_(.arg$geo_id, .arg$demo_id, .arg$time_id) %>%
      dplyr::mutate_each(dplyr::funs(as.vector), contains("_gt"))
  return(mean_y)
}

summarize_success_count <- function(trial_counts, mean_y, .arg){
  # Confirm row order is identical before taking product
  stopifnot(identical(
      dplyr::select_(mean_y, .arg$geo_id, .arg$demo_id, .arg$time_id),
      dplyr::select_(trial_counts, .arg$geo_id, .arg$demo_id, .arg$time_id)))
  success_counts <- dplyr::select(trial_counts, contains("_gt")) * dplyr::select(mean_y, contains("_gt"))
  success_counts <- success_counts %>%
    # Reattach our identifiers
    dplyr::bind_cols(dplyr::select_(trial_counts, .arg$geo_id, .arg$demo_id, .arg$time_id), .) %>%
    # Round off returning integers and replace NA with 0
    dplyr::ungroup() %>%
    dplyr::mutate_each(dplyr::funs(replaceNA), contains("_gt")) %>%
    dplyr::mutate_each(dplyr::funs(round(., digits = 0)), contains("_gt")) %>%
    dplyr::arrange_(.arg$geo_id, .arg$demo_id, .arg$time_id)
  return(success_counts)
}

summarize_trials_by_period <- function(trial_counts, .arg){
  N.valid <- data.frame(
    t = trial_counts[[.arg$time_id]],
    n = dplyr::select(trial_counts, contains("_gt")) %>% rowSums()) %>%
          dplyr::group_by(t) %>%
          dplyr::summarise(any_valid = sum(n, na.rm = TRUE) > 0)
  return(N.valid)
}

make_group_identifier <- function(.data, .arg){
  interaction(.data[, .arg$groups], drop = TRUE)
}

make_ns_long_obs <- function(trial_counts, success_counts, .arg){
  trial_counts_melt <- wrap_melt(trial_counts,
    id.vars = c(.arg$geo_id, .arg$demo_id, .arg$time_id), value.name = "n_grp")
  success_counts_melt <- wrap_melt(success_counts,
    id.vars = c(.arg$geo_id, .arg$demo_id, .arg$time_id), value.name = "s_grp")
  joined <- dplyr::left_join(trial_counts_melt, success_counts_melt,
      by = c(.arg$geo_id, .arg$demo_id, .arg$time_id, "variable")) %>%
    dplyr::arrange_("variable", .arg$time_id, .arg$demo_id, .arg$geo_id) %>%
    dplyr::mutate(name = stringr::str_c(.arg$geo_id, .arg$demo_id, sep = "__")) %>%
    dplyr::filter(n_grp != 0) %>%
    dplyr::as.tbl()
  return(joined)
}

wrap_melt <- function(...) {
  melt <- reshape2::melt(...)
  melt$variable <- as.character(melt$variable)
  return(melt)
}

make_ns_long <- function(ns_long_obs, .arg){
  ns_long <- setNames(data.frame(expand.grid(unique(ns_long_obs$name), .arg$use_t)), c("name", .arg$time_id)) %>%
    dplyr::mutate_each(dplyr::funs(as.character)) %>%
    dplyr::left_join(ns_long_obs, ., by = c("name", .arg$time_id)) %>%
    dplyr::mutate(
      n_grp = replaceNA(n_grp),
      name = stringr::str_c(name, .arg$time_id, sep = "__"),
      name = stringr::str_c(name, variable, sep = " | ")) %>%
    dplyr::arrange_(.arg$geo_id, .arg$demo_id, "variable", .arg$time_id)

  ns_long$s_grp[is.na(ns_long$s_grp)] <- 0
  ns_long$n_grp[is.na(ns_long$n_grp)] <- 0
  ns_long$s_grp <- as.integer(ns_long$s_grp)
  ns_long$n_grp <- as.integer(ns_long$n_grp)
  ns_long
}

make_missingness_array <- function(ns_long, group_grid, .arg){
  # Create missingness indicator array
  acast_formula = as.formula(paste0(.arg$time_id, "~ variable ~", .arg$demo_id, "+", .arg$geo_id))
  MMM <- ns_long %>%
    # Include in the missingness array all group-variables that might not exist
    # in the data because of unobserved use_t
    muffle_full_join(group_grid, by = c(.arg$geo_id, .arg$demo_id, .arg$time_id)) %>%
    # Get missingness by group
    dplyr::group_by_(.arg$geo_id, .arg$demo_id, .arg$time_id, "variable") %>%
    dplyr::summarise(m_grp = as.integer(sum(n_grp, na.rm = TRUE) == 0)) %>%
    reshape2::acast(acast_formula, value.var = "m_grp", fill = 1)
  # But we don"t want to include "NA" as a variable
  MMM <- MMM[!(dimnames(MMM)[[1]] == "NA"),
    !(dimnames(MMM)[[2]] == "NA"),
    !(dimnames(MMM)[[3]] == "NA")]
  MMM
}

make_dummy_weight_matrix <- function(T, Gl2, G) {
  array(1, dim = c(T, Gl2, G))
}

make_l2_only <- function(trial_counts, level1, T, Q, .arg){
  l2_only <- array(0, dim = c(T, Q), dimnames = list(.arg$use_t,
      grep("_gt", colnames(level1), fixed = TRUE, value = TRUE)))
  l2_only <- trial_counts %>%
    dplyr::group_by_(.arg$time_id) %>%
    dplyr::summarise_each(dplyr::funs(c(0)), contains("_gt"))
  rownames(l2_only) <- l2_only[[.arg$time_id]]
  l2_only <- l2_only %>%
    dplyr::select(contains("_gt"))
  as.matrix(l2_only, rownames.force = TRUE)
}

make_NNl2 <- function(level1, T, Q, Gl2, .arg){
  array(0, c(T, Q, Gl2), list(.arg$use_t,
      grep("_gt", colnames(level1), fixed= TRUE, value = TRUE), NULL))
}

factorize_arg_vars <- function(.data, .arg){
  arg_vars <- intersect(names(.data),
    c(.arg$time_id, .arg$groups, .arg$geo_id, .arg$survey_id))
  if (is.null(.data)) {
    return(NULL)
  }
  .data %>% dplyr::mutate_each_(dplyr::funs(factor), vars = arg_vars)
}

drop_missing_respondents <- function(.data, .arg){
  .data <- dplyr::filter(.data, !none_valid)
  if (!.arg$silent){
    message(sprintf(ngettext(sum(.data$none_valid),
          "%i row has no responses",
          "%i rows have no responses"),
        sum(.data$none_valid)))
  }
  .data
}

drop_missing_items <- function(.data, q_all_missing, .arg){
  q_all_missing <- intersect(q_all_missing, names(.data))
  if (length(q_all_missing) > 0) {
    .data <- dplyr::select(.data, -one_of(q_all_missing))
    if (!.arg$silent){
      message(sprintf(ngettext(length(q_all_missing),
            "%i question, %s, has no responses",
            "%i questions have no responses: %s"),
          length(q_all_missing),
          stringi::stri_c(q_all_missing, collapse = ", ")))
    }
  }
  .data
}

drop_rare_items_over_t <- function(.data, q_rare, .arg){
  q_rare <- intersect(q_rare, names(.data))
  if (length(q_rare) > 0) {
    .data <- dplyr::select(.data, -one_of(q_rare))
    if (!.arg$silent){
      message(sprintf(ngettext(length(q_rare),
            "%i question fails min_periods requirement (%i): %s",
            "%i questions fail min_periods requirement (%i): %s"),
          length(q_rare), .min_periods,
          stringi::stri_c(q_rare, collapse = ", ")))
    }
  }
  .data
}

drop_rare_items_over_polls <- function(.data, .lt_min_surveys, .arg){
  .lt_min_surveys <- intersect(.lt_min_surveys, names(.data))
  if (length(.lt_min_surveys) > 0) {
    .data <- dplyr::select(.data, -one_of(.lt_min_surveys))
    if (!.arg$silent){
      message(sprintf(ngettext(length(.lt_min_surveys),
            "%i question fails min_surveys requirement (%i): %s",
            "%i questions fail min_surveys requirement (%i): %s"),
          length(.lt_min_surveys), arg$min_surveys,
          stringi::stri_c(.lt_min_surveys, collapse = ", ")))
    }
  }
  .data
}

update_use_geo <- function(.data, .arg){
  levels(unlist(.data[[.arg$geo_id]]))
}

set_use_t <- function(.data, .arg){
  if (is.null(.arg$use_t)){
    return(levels(.data[[.arg$time_id]]))
  } else {
    return(.arg$use_t)
  }
}

subset_to_estimation_periods <- function(.data, .arg){
  stopifnot(is.data.frame(.data))
  stopifnot(is.factor(.data[[.arg$time_id]]))
  stopifnot(is.character(.arg$use_t))
  periods_filter <- as.character(.data[[.arg$time_id]]) %in%
    as.character(.arg$use_t)
  .data <- .data %>% dplyr::filter(periods_filter)
  stopifnot(nrow(.data) > 0)
  .data <- droplevels(.data)
  .data
}

drop_rows_missing_covariates <- function(.data, .arg){
  .data <- .data %>%
    dplyr::filter_(lazyeval::interp(~!is.na(geo_name) & !is.na(demo_name)
        & !is.na(time_name),
      geo_name = as.name(.arg$geo_id),
      demo_name = as.name(.arg$demo_id),
      time_name = as.name(.arg$time_id)))
  droplevels(.data)
}

drop_rows_missing_gt_variables <- function(.data){
  # Drop rows lacking at least one _gt variable
  .data <- .data %>%
    dplyr::filter(rowSums(!is.na(dplyr::select(.data, contains("_gt")))) > 0)
  droplevels(.data)
}

subset_to_observed_geo_periods <- function(.arg){
  # Subset level-2 data to geographic units observed and time periods
  # specified
  if (is.null(.arg$level2)) {
    return(NULL)
  } else {
    .arg$level2 <- .arg$level2 %>%
      dplyr::filter(.arg$geo_id %in% .arg$use_geo)
    stopifnot(nrow(.arg$level2) > 0)
  }
  .arg$level2[[.arg$geo_id]] <- droplevels(.arg$level2[[.arg$geo_id]])
  return(.arg$level2)
}

count_respondent_trials <- function(level1){
  rowSums(
    !is.na(dplyr::select(level1, contains("_gt")) %>% as.matrix(.)),
    na.rm = TRUE)
}

count_questions <- function(level1){
  sum(grepl("_gt", colnames(level1), fixed = TRUE))
}

count_covariate_combos <- function(level1, .arg){
  nlevels(level1[[.arg$geo_id]]) * nlevels(level1[[.arg$demo_id]])
}

add_survey_period_id <- function(level1, .arg){
  level1 <- level1 %>% tidyr::unite(survey_period_id,
    one_of(.arg$survey_id, .arg$time_id), sep = ".", remove = FALSE)
  level1 <- level1 %>% dplyr::mutate(survey_period_id = factor(survey_period_id))
}

handle_arguments <- function(){
  arg <- mget(names(formals(format_data)), parent.frame(),
    ifnotfound = list(rep(NULL, length(formals(format_data)))))
  arg <- unlist(arg, recursive = FALSE)
  stopifnot(length(names(arg)) > 0)
  names(arg) <- sub("^(data|vars|filters|params)\\.", "", names(arg))

  # Set defaults
  arg <- set_arg_defaults(arg)

  # Check arguments and throw errors on failures
  check_arg_lengths(arg)
  check_arg_names(arg)
  check_arg_types(arg)

  arg$min_periods <- as.integer(arg$min_periods)
  arg$min_surveys <- as.integer(arg$min_surveys)

  return(arg)
}

handle_data <- function(.data, .arg){
  .data <- as_tbl(.data)
  # Make all the variables given as strings factors
  .data <- factorize_arg_vars(.data, .arg)
}

apply_restrictions <- function(.data, .checks, .arg){
  # Drop rows with no valid question responses
  .data <- drop_missing_respondents(.data, .arg)

  # Drop variables columns with no valid responses
  .data <- drop_missing_items(.data, .checks$q_all_missing, .arg)

  # Drop variables that don"t satisfy min_periods requirement
  .data <- drop_rare_items_over_t(.data, .checks$q_rare.t, .arg)

  if (length(.arg$items) == 0) stop("no response variables left")
  if (nrow(.data) == 0) stop("no rows left")

  .data <- add_survey_period_id(.data, .arg)

  .data <- drop_rare_items_over_polls(.data, .checks$q_rare.polls, .arg)

  return(.data)
}

count_level2_groups <- function(level2, xtab, .arg){
  # Generate factor levels for combinations of demographic variables
  # Gl2 gives the number of level-2 modifier combinations
  if (is.null(.arg$level2)) {
    l2.group <- gl(1, nrow(xtab))
    Gl2 <- nlevels(l2.group)
    return(Gl2)
  } else {
    Gl2 <- nlevels(.arg$level2[[.arg$demo_id]])
    if (Gl2 == 0) Gl2 <- 1
    stopifnot(Gl2 > 0)
    return(Gl2)
  }
}

make_group_grid <- function(level1, .arg){
  # The table just created excludes covariate combinations not observed in the
  # data, but we want all combinations of the demographic and geographic
  # covariates and specified periods
  group_grid = expand.grid(
    sort(unique(level1[[.arg$geo_id]])),
    sort(unique(level1[[.arg$demo_id]])),
    as.character(.arg$use_t), stringsAsFactors = FALSE)
  setNames(group_grid, c(.arg$geo_id, .arg$demo_id, .arg$time_id))
}

muffle_full_join <- function(...) {
  suppressWarnings(dplyr::full_join(...))
}