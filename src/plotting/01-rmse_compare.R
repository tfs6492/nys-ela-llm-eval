# ==============================================================================
# 01-rmse_compare.R
# ------------------------------------------------------------------------------
# Comprehensive RMSE and Error Metrics Comparison Across All Evaluation Methods.
#
# Computes:
#   1. Overall Root Mean Square Error (RMSE) & Mean Absolute Error (MAE)
#   2. Matched-pair comparison (Gemini Flash instruct vs. thinking on the same base model)
#   3. Grade-level deviation progression (Grades 3 through 8)
#
# Output:
#   - `figs/overall_rmse_compare.png`
#   - `figs/matched_pairs_rmse_comparison.png`
#   - `figs/abs_error_by_grade.png`
# ==============================================================================

user_lib <- file.path(Sys.getenv("LOCALAPPDATA"), "R", "win-library", paste0(R.version$major, ".", substr(R.version$minor, 1, 1)))
if (dir.exists(user_lib)) {
  .libPaths(c(user_lib, .libPaths()))
}

suppressPackageStartupMessages({
  library(tidyverse)
})

cat("==================================================================\n")
cat(" Computing RMSE & Comparative Error Metrics\n")
cat("==================================================================\n")

# Load Ground Truth
meta_file <- "data/input/all_metadata.csv"
if (!file.exists(meta_file)) {
  stop("Master metadata not found: ", meta_file)
}
meta_df <- read_csv(meta_file, show_col_types = FALSE) |>
  select(passage_id, true_grade = grade, year, genre)

preds_list <- list()

# 1. Random Forest Baseline
rf_new <- "data/output/rf_results.csv"
rf_old <- "data/output/rf_results_with_ci.csv"
if (file.exists(rf_new)) {
  rf_df <- read_csv(rf_new, show_col_types = FALSE) |>
    transmute(
      passage_id = as.character(passage_id),
      model = "Random Forest",
      model_type = "Baseline",
      base_architecture = "Quanteda RF",
      predicted_grade = as.numeric(predicted_grade)
    )
  preds_list[[length(preds_list) + 1]] <- rf_df
} else if (file.exists(rf_old)) {
  rf_df <- read_csv(rf_old, show_col_types = FALSE)
  if (!"passage_id" %in% names(rf_df)) {
    rf_df <- rf_df |> mutate(passage_id = as.character(row_number() - 1))
  }
  rf_df <- rf_df |>
    transmute(
      passage_id = as.character(passage_id),
      model = "Random Forest",
      model_type = "Baseline",
      base_architecture = "Quanteda RF",
      predicted_grade = as.numeric(random_forest_predictions.Median_Prediction)
    )
  preds_list[[length(preds_list) + 1]] <- rf_df
}

# 2. Gemini API Results
gemini_file <- "data/output/gemini_results.csv"
if (file.exists(gemini_file)) {
  gemini_df <- read_csv(gemini_file, show_col_types = FALSE) |>
    filter(is.na(parse_error) | parse_error == FALSE) |>
    transmute(
      passage_id = as.character(passage_id),
      model = case_when(
        str_detect(model, "3.6-flash|2.5-flash") & !str_detect(model, "thinking") ~ "Gemini Flash",
        str_detect(model, "thinking") ~ "Gemini Flash Thinking",
        str_detect(model, "3.1-pro|pro") ~ "Gemini 3.1 Pro",
        TRUE ~ model
      ),
      model_type = case_when(
        str_detect(model, regex("thinking", ignore_case = TRUE)) ~ "Reasoning",
        str_detect(model, regex("pro", ignore_case = TRUE)) ~ "Cloud Pro",
        TRUE ~ "Instruct"
      ),
      base_architecture = case_when(
        str_detect(model, "Flash") ~ "Gemini Flash",
        TRUE ~ "Gemini Pro"
      ),
      predicted_grade = as.numeric(predicted_grade)
    )
  preds_list[[length(preds_list) + 1]] <- gemini_df
}

all_preds <- bind_rows(preds_list) |>
  left_join(meta_df |> select(passage_id, meta_true_grade = true_grade, year, genre), by = "passage_id")

if ("true_grade" %in% names(all_preds)) {
  all_preds <- all_preds |> mutate(true_grade = coalesce(true_grade, meta_true_grade))
} else {
  all_preds <- all_preds |> mutate(true_grade = meta_true_grade)
}
all_preds <- all_preds |> filter(!is.na(predicted_grade) & !is.na(true_grade))

# Compute Per-Model RMSE and MAE
rmse_summary <- all_preds |>
  group_by(model, model_type, base_architecture) |>
  summarise(
    n_passages = n(),
    rmse = sqrt(mean((predicted_grade - true_grade)^2)),
    mae  = mean(abs(predicted_grade - true_grade)),
    correlation = cor(predicted_grade, true_grade),
    .groups = "drop"
  ) |>
  arrange(rmse)

cat("\nModel Performance Summary:\n")
print(as.data.frame(rmse_summary |> select(model, model_type, n_passages, rmse, mae, correlation)))

# Group color palette
group_colors <- c(
  "Baseline"   = "#2A9D8F",
  "Instruct"   = "#E76F51",
  "Reasoning"  = "#264653",
  "Cloud Pro"  = "#E9C46A"
)

# ------------------------------------------------------------------------------
# Plot 1: Overall RMSE Comparison Bar Chart
# ------------------------------------------------------------------------------
p_overall <- rmse_summary |>
  mutate(model = fct_reorder(model, rmse, .desc = TRUE)) |>
  ggplot(aes(x = rmse, y = model, fill = model_type)) +
  geom_col(width = 0.7) +
  geom_text(aes(label = sprintf("%.2f", rmse)), hjust = -0.15, size = 3.8, fontface = "bold") +
  scale_fill_manual(values = group_colors, name = "Model Family / Type") +
  scale_x_continuous(expand = expansion(mult = c(0, 0.15))) +
  labs(
    title = "Agreement with Assigned Grade Levels (RMSE)",
    subtitle = "Lower RMSE = closer agreement with assigned grade levels",
    x = "RMSE vs. Assigned Grade (Grade Levels)",
    y = NULL
  ) +
  theme_minimal(base_size = 12) +
  theme(
    panel.grid.major.y = element_blank(),
    panel.grid.minor = element_blank(),
    axis.text.y = element_text(face = "bold", size = 10),
    plot.title = element_text(face = "bold"),
    legend.position = "bottom"
  )

dir.create("figs", showWarnings = FALSE, recursive = TRUE)
ggsave("figs/overall_rmse_compare.png", plot = p_overall, width = 10, height = 6, dpi = 300)
cat("[+] Saved overall RMSE chart to: figs/overall_rmse_compare.png\n")

# ------------------------------------------------------------------------------
# Plot 2: Matched Pairs (Instruct vs Reasoning) Comparison
# ------------------------------------------------------------------------------
paired_models <- rmse_summary |>
  filter(model_type %in% c("Instruct", "Reasoning")) |>
  group_by(base_architecture) |>
  filter(n_distinct(model_type) == 2) |>
  ungroup()

if (nrow(paired_models) > 0) {
  p_pairs <- paired_models |>
    ggplot(aes(x = rmse, y = fct_reorder(base_architecture, rmse), fill = model_type)) +
    geom_col(position = position_dodge(width = 0.7), width = 0.6) +
    geom_text(aes(label = sprintf("%.2f", rmse)),
              position = position_dodge(width = 0.7),
              hjust = -0.1, size = 3.5, fontface = "bold") +
    scale_fill_manual(values = c("Instruct" = "#E76F51", "Reasoning" = "#264653"), name = "Paradigm") +
    scale_x_continuous(expand = expansion(mult = c(0, 0.15))) +
    labs(
      title = "Agreement with Assigned Grades: Instruct vs. Thinking on a Shared Base Model",
      subtitle = "Deviation from assigned grade levels for Gemini Flash with and without extended thinking",
      x = "RMSE (Grade Levels)",
      y = "Base Architecture"
    ) +
    theme_minimal(base_size = 12) +
    theme(
      panel.grid.major.y = element_blank(),
      panel.grid.minor = element_blank(),
      plot.title = element_text(face = "bold"),
      legend.position = "bottom"
    )
  ggsave("figs/matched_pairs_rmse_comparison.png", plot = p_pairs, width = 10, height = 5.5, dpi = 300)
  cat("[+] Saved matched pairs comparison to: figs/matched_pairs_rmse_comparison.png\n")
}

# ------------------------------------------------------------------------------
# Plot 3: Absolute Error by Assigned Grade Level (Grades 3 to 8)
# ------------------------------------------------------------------------------
p_grade_error <- all_preds |>
  mutate(abs_err = abs(predicted_grade - true_grade)) |>
  group_by(true_grade, model_type) |>
  summarise(mean_abs_error = mean(abs_err), .groups = "drop") |>
  ggplot(aes(x = factor(true_grade), y = mean_abs_error, fill = model_type)) +
  geom_col(position = position_dodge(width = 0.75), width = 0.7) +
  scale_fill_manual(values = group_colors, name = "Model Paradigm") +
  labs(
    title = "Deviation from Assigned Grade Level, Grades 3 to 8",
    subtitle = "Mean absolute deviation shows where models diverge from assigned grades",
    x = "Assigned Grade Level",
    y = "Mean Absolute Deviation (Grade Levels)"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    panel.grid.major.x = element_blank(),
    plot.title = element_text(face = "bold"),
    legend.position = "bottom"
  )

ggsave("figs/abs_error_by_grade.png", plot = p_grade_error, width = 9, height = 5.5, dpi = 300)
cat("[+] Saved error by grade level to: figs/abs_error_by_grade.png\n")
