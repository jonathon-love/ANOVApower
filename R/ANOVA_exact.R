#' Simulates on exact empirical data set from the design to calculate power
#' @param design_result Output from the ANOVA_design function
#' @param alpha_level Alpha level used to determine statistical significance
#' @param verbose Set to FALSE to not print results (default = TRUE)
#' @return Returns dataframe with simulation data (power and effect sizes), anova results and simple effect results, plot of exact data, and alpha_level.
#' @examples
#' ## Set up a within design with 2 factors, each with 2 levels,
#' ## with correlation between observations of 0.8,
#' ## 40 participants (who do all conditions), and standard deviation of 2
#' ## with a mean pattern of 1, 0, 1, 0, conditions labeled 'condition' and
#' ## 'voice', with names for levels of "cheerful", "sad", amd "human", "robot"
#' design_result <- ANOVA_design(design = "2w*2w", n = 40, mu = c(1, 0, 1, 0),
#'       sd = 2, r = 0.8, labelnames = c("condition", "cheerful",
#'       "sad", "voice", "human", "robot"))
#'  set.seed(252)
#' exact_result <- ANOVA_exact(design_result, alpha_level = 0.05)
#' @section References:
#' to be added
#' @importFrom stats pnorm pt qnorm qt as.formula median qf power.t.test
#' @importFrom utils combn
#' @importFrom reshape2 melt
#' @importFrom MASS mvrnorm
#' @importFrom afex aov_car
#' @import ggplot2
#' @export
#'

ANOVA_exact <- function(design_result, alpha_level, verbose = TRUE) {

  effect_size_d <- function(x, y, conf.level = 0.95){
    sd1 <- sd(x) #standard deviation of measurement 1
    sd2 <- sd(y) #standard deviation of measurement 2
    n1 <- length(x) #number of pairs
    n2 <- length(y) #number of pairs
    df <- n1 + n2 - 2
    m_diff <- mean(y - x)
    sd_pooled <- (sqrt((((n1 - 1) * ((sd1^2))) + (n2 - 1) * ((sd2^2))) / ((n1 + n2 - 2)))) #pooled standard deviation
    j <- (1 - 3/(4 * (n1 + n2 - 2) - 1))  #Calculate Hedges' correction.
    t_value <- m_diff / sqrt(sd_pooled^2 / n1 + sd_pooled^2 / n2)
    p_value = 2*pt(-abs(t_value), df = df)
    #Calculate power
    power = power.t.test(
      n = n1,
      delta = m_diff,
      sd = sd_pooled,
      type = "two.sample",
      alternative = "two.sided",
      strict = TRUE
    )$power

    d <- m_diff / sd_pooled #Cohen's d
    d_unb <- d*j #Hedges g, of unbiased d

    invisible(list(d = d,
                   d_unb = d_unb,
                   p_value = p_value,
                   power = power))
  }

  effect_size_d_paired <- function(x, y, conf.level = 0.95){
    sd1 <- sd(x) #standard deviation of measurement 1
    sd2 <- sd(y) #standard deviation of measurement 2
    s_diff <- sd(x - y) #standard deviation of the difference scores
    N <- length(x) #number of pairs
    df = N - 1
    s_av <- sqrt((sd1 ^ 2 + sd2 ^ 2) / 2) #averaged standard deviation of both measurements

    #Cohen's d_av, using s_av as standardizer
    m_diff <- mean(y - x)
    d_av <- m_diff / s_av
    d_av_unb <- (1 - (3 / (4 * (N - 1) - 1))) * d_av

    #get the t-value for the CI
    t_value <- m_diff / (s_diff / sqrt(N))
    p_value = 2 * pt(-abs(t_value), df = df)

    power = power.t.test(
      n = N,
      delta = m_diff,
      sd = s_diff,
      type = "paired",
      alternative = "two.sided",
      strict = TRUE
    )$power

    #Cohen's d_z, using s_diff as standardizer
    d_z <- t_value / sqrt(N)
    d_z_unb <- (1 - (3 / (4 * (N - 1) - 1))) * d_z

    invisible(list(
      d_z = d_z,
      d_z_unb = d_z_unb,
      p_value = p_value,
      power = power
    ))
  }

  round_dig <- 4 #Set digits to which you want to round the output.

  if (missing(alpha_level)) {
    alpha_level <- 0.05
  }

  if (alpha_level >= 1 | alpha_level <= 0  ) {
    stop("alpha_level must be less than 1 and greater than zero")
  }

  #Read in all variables from the design_result object
  design <- design_result$design #String used to specify the design
  factornames <- design_result$factornames #Get factor names
  n <- design_result$n
  mu = design_result$mu # population means - should match up with the design
  sd <- design_result$sd #population standard deviation (currently assumes equal variances)
  r <- design_result$r # correlation between within factors (currently only 1 value can be entered)
  factors <- design_result$factors
  design_factors <- design_result$design_factors
  sigmatrix <- design_result$sigmatrix
  dataframe <- design_result$dataframe
  design_list <- design_result$design_list

  #Errors with very small sample size; issue with mvrnorm function from MASS package
  if(n < 8){
    stop("ANOVA_exact cannot handle small sample sizes (n < 8) at this time; please pass this design_result to the ANOVA_power function to simulate power")
  }

  ###############
  #Specify factors for formula ----
  ###############

  frml1 <- design_result$frml1
  frml2 <- design_result$frml2

  aov_result <- suppressMessages({aov_car(frml1, #here we use frml1 to enter formula 1 as designed above on the basis of the design
                                          data = dataframe, include_aov = FALSE,
                                          anova_table = list(es = "pes")) }) #This reports PES not GES

  ###############
  # Set up dataframe for storing empirical results
  ###############

  #How many possible planned comparisons are there (to store p and es)
  possible_pc <- (((prod(
    as.numeric(strsplit(design, "\\D+")[[1]])
  )) ^ 2) - prod(as.numeric(strsplit(design, "\\D+")[[1]])))/2

  #create empty dataframe to store simulation results
  #number of columns for ANOVA results and planned comparisons, times 2 (p-values and effect sizes)
  sim_data <- as.data.frame(matrix(
    ncol = 2 * (2 ^ factors - 1) + 2 * possible_pc,
    nrow = 1
  ))

  paired_tests <- combn(unique(dataframe$cond),2)
  paired_p <- numeric(possible_pc)
  paired_d <- numeric(possible_pc)
  within_between <- sigmatrix[lower.tri(sigmatrix)] #based on whether correlation is 0 or not, we can determine if we should run a paired or independent t-test

  #Dynamically create names for the data we will store
  names(sim_data) = c(paste("anova_",
                            rownames(aov_result$anova_table),
                            sep = ""),
                      paste("anova_es_",
                            rownames(aov_result$anova_table),
                            sep = ""),
                      paste("p_",
                            paste(paired_tests[1,],paired_tests[2,],sep = "_"),
                            sep = ""),
                      paste("d_",
                            paste(paired_tests[1,],paired_tests[2,], sep = "_"),
                            sep = ""))

  #We simulate a new y variable, melt it in long format, and add it to the dataframe (surpressing messages)
  #empirical set to true to create "exact" dataset

  dataframe$y <- suppressMessages({
    melt(as.data.frame(mvrnorm(
      n = n,
      mu = mu,
      Sigma = as.matrix(sigmatrix),
      empirical = TRUE
    )))$value
  })

  # We perform the ANOVA using AFEX
  #Can be set to NICE to speed up, but required data grabbing from output the change.
  aov_result <- suppressMessages({aov_car(frml1, #here we use frml1 to enter fromula 1 as designed above on the basis of the design
                                          data = dataframe, include_aov = FALSE, #Need development code to get aov_include function
                                          anova_table = list(es = "pes"))}) #This reports PES not GES


  #Add additional statistics
  #Create dataframe from afex results
  anova_table <- as.data.frame(aov_result$anova_table)
  colnames(anova_table) <- c("num_Df", "den_Df", "MSE", "F", "pes", "p")

  #Calculate cohen's f
  anova_table$f2 <- anova_table$pes/(1-anova_table$pes)
  #Calculate noncentrality
  anova_table$lambda <- anova_table$f2*anova_table$den_Df

  #minusalpha<- 1-alpha_level
  anova_table$Ft <- qf((1-alpha_level), anova_table$num_Df, anova_table$den_Df)
  #Calculate power
  anova_table$power <- (1-pf(anova_table$Ft, anova_table$num_Df, anova_table$den_Df, anova_table$lambda))*100

  for (j in 1:possible_pc) {
    x <- dataframe$y[which(dataframe$cond == paired_tests[1,j])]
    y <- dataframe$y[which(dataframe$cond == paired_tests[2,j])]
    #this can be sped up by tweaking the functions that are loaded to only give p and dz
    ifelse(within_between[j] == 0,
           t_test_res <- effect_size_d(x, y, conf.level = 1 - alpha_level),
           t_test_res <- effect_size_d_paired(x, y, conf.level = 1 - alpha_level))
    paired_p[j] <- (t_test_res$power*100)
    paired_d[j] <- ifelse(within_between[j] == 0,
                          t_test_res$d,
                          t_test_res$d_z)
  }

  # store p-values and effect sizes for calculations
  sim_data[1,] <- c(aov_result$anova_table[[6]], #p-value for ANOVA
                    aov_result$anova_table[[5]], #partial eta squared
                    paired_p, #power for paired comparisons, dropped correction for multiple comparisons
                    paired_d) #effect sizes

  ###############
  #Sumary of power and effect sizes of main effects and contrasts ----
  ###############
  main_results <- round(data.frame(anova_table$power, anova_table$pes, sqrt(anova_table$f2), anova_table$lambda), round_dig)
  rownames(main_results) <- rownames(anova_table)
  colnames(main_results) <- c("power", "partial_eta_squared", "cohen_f", "non_centrality")
  main_results$power <- round(main_results$power, 2)

  #Data summary for pairwise comparisons
  power_paired = as.data.frame(apply(as.matrix(sim_data[(2 * (2 ^ factors - 1) + 1):(2 * (2 ^ factors - 1) + possible_pc)]), 2,
                                     function(x) round(x, 2)))

  es_paired = as.data.frame(apply(as.matrix(sim_data[(2 * (2 ^ factors - 1) + possible_pc + 1):(2*(2 ^ factors - 1) + 2 * possible_pc)]), 2,
                                  function(x) round(x,round_dig)))

  pc_results <- data.frame(power_paired, es_paired)
  names(pc_results) = c("power","effect_size")

  #Create plot

  if (factors == 1) {meansplot = ggplot(dataframe, aes_string(y = "y", x = factornames[1]))}
  if (factors == 2) {meansplot = ggplot(dataframe, aes_string(y = "y", x = factornames[1])) + facet_wrap(  paste("~",factornames[2],sep=""))}
  if (factors == 3) {meansplot = ggplot(dataframe, aes_string(y = "y", x = factornames[1])) + facet_grid(  paste(factornames[3],"~",factornames[2], sep=""))}

  meansplot2 = meansplot +
    geom_jitter(position = position_jitter(0.2)) +
    stat_summary(
      fun.data = "mean_sdl",
      fun.args = list(mult = 1),
      geom = "crossbar",
      color = "red"
    ) +
    coord_cartesian(ylim = c(min(dataframe$y), max(dataframe$y))) +
    theme_bw() + ggtitle("Exact data for each condition in the design")

  #######################
  # Return Results ----
  #######################
  if(verbose == TRUE){
    # The section below should be blocked out when in Shiny
    cat("Power and Effect sizes for ANOVA tests")
    cat("\n")
    print(main_results)
    cat("\n")
    cat("Power and Effect sizes for contrasts")
    cat("\n")
    print(pc_results)
  }

  # Return results in list()
  invisible(list(dataframe = dataframe,
                 aov_result = aov_result,
                 main_results = main_results,
                 pc_results = pc_results,
                 alpha_level = alpha_level,
                 plot = meansplot2))
}
