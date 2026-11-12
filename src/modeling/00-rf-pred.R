# ==============================================================================
# 00-rf-pred.R
# ------------------------------------------------------------------------------
# Baseline Random Forest Regression on Text Complexity & Readability Metrics.
#
# Reads the normalized passages (`all_passages.csv`) and metadata (`all_metadata.csv`),
# extracts traditional readability and lexical diversity metrics via quanteda,
# and generates out-of-bag (OOB) predictions with 95% bootstrap confidence intervals.
#
# Output:
#   - `data/output/rf_results.csv` (Standardized cross-model evaluation format)
#   - `data/output/rf_results_with_ci.csv` (Legacy backwards-compatible format)
# ==============================================================================

# Ensure user R libraries are accessible if running on Windows
user_lib <- file.path(Sys.getenv("LOCALAPPDATA"), "R", "win-library", paste0(R.version$major, ".", substr(R.version$minor, 1, 1)))
if (dir.exists(user_lib)) {
  .libPaths(c(user_lib, .libPaths()))
}

suppressPackageStartupMessages({
  library(quanteda)
  library(quanteda.textstats)
  library(randomForest)
})

# Parse command-line arguments or fallback to project defaults
args <- commandArgs(trailingOnly = TRUE)
passages_file <- if (length(args) >= 1) args[1] else "data/input/all_passages.csv"
metadata_file <- if (length(args) >= 2) args[2] else "data/input/all_metadata.csv"
output_file   <- if (length(args) >= 3) args[3] else "data/output/rf_results.csv"

cat("==================================================================\n")
cat(" Random Forest Baseline Readability Predictor\n")
cat(" Passages:", passages_file, "\n")
cat(" Metadata:", metadata_file, "\n")
cat(" Output:  ", output_file, "\n")
cat("==================================================================\n\n")

if (!file.exists(passages_file)) {
  stop(paste("Passages file not found:", passages_file))
}
if (!file.exists(metadata_file)) {
  stop(paste("Metadata file not found:", metadata_file))
}

passages_df <- read.csv(passages_file, stringsAsFactors = FALSE)
metadata_df <- read.csv(metadata_file, stringsAsFactors = FALSE)

# Inner join on passage_id
merged_df <- merge(metadata_df, passages_df, by = "passage_id")
merged_df <- merged_df[order(merged_df$passage_id), ]

cat(sprintf("[*] Loaded %d passages across grades %d to %d (years: %s)\n",
            nrow(merged_df),
            min(merged_df$grade, na.rm = TRUE),
            max(merged_df$grade, na.rm = TRUE),
            paste(sort(unique(merged_df$year)), collapse = ", ")))

x_text <- merged_df$passage_text
y_true <- as.numeric(merged_df$grade)
passage_ids <- merged_df$passage_id

# ------------------------------------------------------------------------------
# Feature Engineering: Lexical Diversity & Traditional Readability Formulas
# ------------------------------------------------------------------------------
cat("[*] Extracting lexical diversity (CTTR) and readability features...\n")
start_time <- Sys.time()

corp <- corpus(x_text)
toks <- tokens(corp, remove_punct = TRUE, remove_numbers = TRUE)
toks <- tokens_remove(toks, pattern = stopwords("en"))

# Corrected Type-Token Ratio
lex_div <- textstat_lexdiv(toks, measure = "CTTR")

# Classical Readability Indices
read_metrics <- textstat_readability(
  x_text,
  measure = c("Flesch.Kincaid", "Dale.Chall", "SMOG", "Coleman.Liau.grade")
)

# Standardized dense feature matrix (consistent with published baseline)
x_dense <- cbind(
  Flesch    = read_metrics$Flesch.Kincaid,
  DaleChall = read_metrics$Dale.Chall,
  Diversity = lex_div$CTTR
)

# Check for any NA/NaN values
if (any(is.na(x_dense))) {
  cat("[WARN] Imputing missing feature values with column medians...\n")
  for (j in 1:ncol(x_dense)) {
    x_dense[is.na(x_dense[, j]), j] <- median(x_dense[, j], na.rm = TRUE)
  }
}

# ------------------------------------------------------------------------------
# Out-of-Bag (OOB) Repeated Random Forest Iterations
# ------------------------------------------------------------------------------
n_iterations <- 100
preds_matrix <- matrix(NA, nrow = length(y_true), ncol = n_iterations)
rmse_values  <- numeric(n_iterations)

cat(sprintf("[*] Training Random Forest across %d iterations with OOB estimation...\n", n_iterations))

for (i in seq_len(n_iterations)) {
  set.seed(123 + 853 * i)

  current_mtry     <- sample(2:3, 1)
  current_nodesize <- sample(3:7, 1)

  rf_model <- randomForest(
    x = x_dense,
    y = y_true,
    ntree = 100,
    mtry = current_mtry,
    nodesize = current_nodesize,
    importance = FALSE,
    keep.forest = FALSE
  )

  # Out-of-bag predictions
  oob_preds <- rf_model$predicted
  preds_matrix[, i] <- oob_preds
  rmse_values[i] <- sqrt(mean((y_true - oob_preds)^2, na.rm = TRUE))
}

elapsed_total <- as.numeric(difftime(Sys.time(), start_time, units = "secs"))
per_sample_duration <- round(elapsed_total / nrow(merged_df), 4)

mean_rmse <- mean(rmse_values)
cat(sprintf("\n[+] Average Out-Of-Bag RMSE across %d iterations: %.4f (min: %.4f, max: %.4f)\n",
            n_iterations, mean_rmse, min(rmse_values), max(rmse_values)))

median_preds <- apply(preds_matrix, 1, median)
lower_95     <- apply(preds_matrix, 1, quantile, probs = 0.025)
upper_95     <- apply(preds_matrix, 1, quantile, probs = 0.975)

# ------------------------------------------------------------------------------
# Export Results
# ------------------------------------------------------------------------------
dir.create(dirname(output_file), showWarnings = FALSE, recursive = TRUE)

# 1. Standardized multi-model evaluation schema
standard_rf_results <- data.frame(
  passage_id       = passage_ids,
  model            = "random_forest",
  model_type       = "baseline",
  true_grade       = y_true,
  predicted_grade  = round(median_preds, 2),
  lower_95_ci      = round(lower_95, 2),
  upper_95_ci      = round(upper_95, 2),
  parse_error      = FALSE,
  duration_seconds = per_sample_duration,
  stringsAsFactors = FALSE
)
write.csv(standard_rf_results, output_file, row.names = FALSE)
cat("[+] Saved standardized RF results to:", output_file, "\n")

# 2. Backwards-compatible format with legacy names
legacy_output <- "data/output/rf_results_with_ci.csv"
legacy_results <- data.frame(
  passage_id                                = passage_ids,
  true_y                                    = y_true,
  random_forest_predictions.Lower_95_CI     = lower_95,
  random_forest_predictions.Median_Prediction = median_preds,
  random_forest_predictions.Upper_95_CI     = upper_95,
  stringsAsFactors = FALSE
)
write.csv(legacy_results, legacy_output, row.names = FALSE)
cat("[+] Saved backwards-compatible RF results to:", legacy_output, "\n")
