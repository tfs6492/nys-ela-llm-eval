library(quanteda)
library(quanteda.textstats)
library(randomForest)

train_ds <- read.csv("data/input/GASS_2024_Passages.csv", stringsAsFactors = FALSE)
test_ds <- read.csv("data/input/2024_passages.csv", stringsAsFactors = FALSE)

y_train <- train_ds$"Reading.Level"
y_test <- test_ds$"Grade.Level"

x_train <- train_ds$Passage
x_test <- test_ds$Passage

# Traditional text ranking features.
corp_train <- corpus(x_train)
toks_train <- tokens(corp_train, remove_punct = TRUE, remove_numbers = TRUE)
toks_train <- tokens_remove(toks_train, pattern = stopwords("en"))

corp_test <- corpus(x_test)
toks_test <- tokens(corp_test, remove_punct = TRUE, remove_numbers = TRUE)
toks_test <- tokens_remove(toks_test, pattern = stopwords("en"))

train_lex <- textstat_lexdiv(toks_train, measure = "CTTR")
test_lex <- textstat_lexdiv(toks_test, measure = "CTTR")

train_read <- textstat_readability(
  x_train,
  measure = c("Flesch.Kincaid", "SMOG", "Dale.Chall", "Coleman.Liau.grade")
)

test_read <- textstat_readability(
  x_test,
  measure = c("Flesch.Kincaid", "SMOG", "Dale.Chall", "Coleman.Liau.grade")
)

calc_density <- function(txt) {
  toks <- tokens(txt, remove_punct = TRUE)
  total <- ntoken(toks)
  content <- ntoken(tokens_remove(toks, stopwords("en")))
  content / total
}

# The original notebook narrowed the feature set to these three predictors.
x_train_dense <- cbind(
  Flesch = train_read$Flesch.Kincaid,
  DaleChall = train_read$Dale.Chall,
  Diversity = train_lex$CTTR
)

x_test_dense <- cbind(
  Flesch = test_read$Flesch.Kincaid,
  DaleChall = test_read$Dale.Chall,
  Diversity = test_lex$CTTR
)

n_iterations <- 100
preds_list <- vector("list", n_iterations)
rmse_values <- numeric(n_iterations)

for (i in seq_len(n_iterations)) {
  set.seed(123 + 853 * i)

  current_mtry <- sample(2:4, 1)
  current_nodesize <- sample(3:7, 1)

  cat(
    "Running iteration", i,
    "with mtry =", current_mtry,
    "& nodesize =", current_nodesize, "...\n"
  )

  rf_model <- randomForest(
    x = x_train_dense,
    y = y_train,
    xtest = x_test_dense,
    ntree = 100,
    mtry = current_mtry,
    nodesize = current_nodesize,
    importance = FALSE,
    keep.forest = FALSE
  )

  rf_preds <- rf_model$test$predicted
  preds_list[[i]] <- rf_preds
  rmse_values[i] <- sqrt(mean((y_test - rf_preds)^2))
}

rf_preds_df <- as.data.frame(do.call(cbind, preds_list))
colnames(rf_preds_df) <- paste0("Preds_Iter_", seq_len(n_iterations))

cat("Average RMSE across", n_iterations, "iterations:", round(mean(rmse_values), 4), "\n")
cat("RMSE per iteration:\n")
print(round(rmse_values, 4))

median_preds <- apply(rf_preds_df, MARGIN = 1, FUN = median)
lower_95 <- apply(rf_preds_df, MARGIN = 1, FUN = quantile, probs = 0.025)
upper_95 <- apply(rf_preds_df, MARGIN = 1, FUN = quantile, probs = 0.975)

rf_summary_df <- data.frame(
  Lower_95_CI = lower_95,
  Median_Prediction = median_preds,
  Upper_95_CI = upper_95
)

results_to_export <- data.frame(
  true_y = y_test,
  random_forest_predictions = rf_summary_df
)

write.csv(results_to_export, "data/output/rf_results_with_ci.csv", row.names = FALSE)
