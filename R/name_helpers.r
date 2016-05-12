flatnames <- function(dgirt_out, fnames = NULL) {

  control <- dgirt_out@dgirt_in$control
  if (!length(fnames)) {
    fnames <- dgirt_out@sim$fnames_oi
  }

  indexed_t <- c('delta_gamma', 'delta_tbar', 'sd_theta', 'sd_theta_bar',
                 'sd_total', 'var_theta', 'xi')
  for (varname in indexed_t) {
    fnames[grep(paste0('^', varname, "\\[\\d+\\]", "$"), fnames)] <-
      paste0(varname, "[", control@time_filter, "]")
  }

  theta_bar_indices <- paste(do.call(function(...) paste(..., sep = "__"),
                     dgirt_out@dgirt_in$group_grid[, -c(control@time_name), with = FALSE]),
             dgirt_out@dgirt_in$group_grid[[control@time_name]], sep = ",")

  fnames[grep(paste0('^', "theta_bar", "\\[\\d+,\\d+\\]", "$"), fnames)] <-
    paste0("theta_bar[", theta_bar_indices, "]")
  fnames[grep(paste0('^', "theta_bar_raw", "\\[\\d+,\\d+\\]", "$"), fnames)] <-
    paste0("theta_bar_raw[", theta_bar_indices, "]")

  gamma_indices <- do.call(function(...) paste(..., sep = ","),
                           list(dgirt_out@dgirt_in$hier_names, control@time_filter))
  fnames[grep(paste0('^', "gamma", "\\[\\d+,\\d+\\]", "$"), fnames)] <-
    paste0("gamma[", gamma_indices, "]")
  fnames[grep(paste0('^', "gamma_raw", "\\[\\d+,\\d+\\]", "$"), fnames)] <-
    paste0("gamma_raw[", gamma_indices, "]")

  indexed_th <- c('nu_geo', 'theta_l2', 'var_theta_bar_l2')
  for (varname in indexed_th) {
    fnames[grep(paste0('^', varname, "\\[\\d+,\\d+\\]", "$"), fnames)] <-
      paste0(varname, "[", control@time_filter, ",", 1, "]")
  }

  if (!control@constant_item) {
    fnames[grep(paste0('^kappa\\[\\d+,\\d+\\]$'), fnames)] <-
      paste0("kappa[", control@time_filter, "]")
  }

  # TODO: prob and z are indexed T x Q x G; take from MMM
  # TODO: prob_l2 and z_l2 are indexed T x Q

  mu_theta_bar_indices <- paste(dgirt_out@dgirt_in$group_grid[[control@time_name]],
                                do.call(function(...) paste(..., sep = "__"),
                                        dgirt_out@dgirt_in$group_grid[, -control@time_name, with = FALSE]),
                                sep = ",")
  fnames[grep(paste0('^', "mu_theta_bar", "\\[\\d+,\\d+\\]", "$"), fnames)] <-
    paste0("mu_theta_bar[", mu_theta_bar_indices, "]")

  fnames
}

arraynames <- function(dgirt_extract, dgirt_out) {

  control <- dgirt_out@dgirt_in$control

  dim2_indexed_t <- c('theta_bar', 'xi', 'gamma', 'delta_gamma', 'delta_tbar',
                      'nu_geo', 'sd_theta', 'sd_theta_bar', 'sd_total',
                      'theta_l2', 'var_theta_bar_l2')
  if (!as.logical(control@constant_item)) dim2_indexed_t <- c(dim2_indexed_t, "kappa")
  dim2_indexed_t <- intersect(dim2_indexed_t, names(dgirt_extract))

  for (i in dim2_indexed_t) {
    names(attributes(dgirt_extract[[i]])$dimnames)[2] <- 'time'
    stopifnot(identical(dim(dgirt_extract[[i]])[2], length(control@time_filter)))
    dimnames(dgirt_extract[[i]])[[2]] <- control@time_filter
  }

  if ('theta_bar' %chin% names(dgirt_extract)) {
    names(attributes(dgirt_extract[['theta_bar']])$dimnames)[3] <- 'group'
    groups_concat <- do.call(function(...) paste(..., sep = "__"), dgirt_out@dgirt_in$group_grid_t)
    stopifnot(identical(dim(dgirt_extract[['theta_bar']])[3], length(groups_concat)))
    dimnames(dgirt_extract[['theta_bar']])[[3]] <- groups_concat
  }

  if ('gamma' %chin% names(dgirt_extract)) {
    names(attributes(dgirt_extract[['gamma']])$dimnames)[3] <- 'param'
    assertthat::assert_that(identical(dim(dgirt_extract[['gamma']])[3], length(dgirt_out@dgirt_in$hier_names)))
    dimnames(dgirt_extract[['gamma']])[[3]] <- dgirt_out@dgirt_in$hier_names
  }

  if ('kappa' %chin% names(dgirt_extract)) {
    names(attributes(dgirt_extract[['kappa']])$dimnames)[3] <- 'item'
    assertthat::assert_that(identical(dim(dgirt_extract[['kappa']])[3], length(dgirt_out@dgirt_in$gt_items)))
    dimnames(dgirt_extract[['kappa']])[[3]] <- dgirt_out@dgirt_in$gt_items
  }

  if ('sd_item' %chin% names(dgirt_extract)) {
    names(attributes(dgirt_extract[['sd_item']])$dimnames)[2] <- 'item'
    assertthat::assert_that(identical(dim(dgirt_extract[['sd_item']])[2], length(dgirt_out@dgirt_in$gt_items)))
    dimnames(dgirt_extract[['sd_item']])[[2]] <- dgirt_out@dgirt_in$gt_items
  }

  if ('var_theta' %chin% names(dgirt_extract)) {
    names(attributes(dgirt_extract[['var_theta']])$dimnames)[2] <- 'time'
    assertthat::assert_that(identical(dim(dgirt_extract[['var_theta']])[2], length(control@time_filter)))
    dimnames(dgirt_extract[['var_theta']])[[2]] <- control@time_filter
  }

  dgirt_extract
}