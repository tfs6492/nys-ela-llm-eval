# ==============================================================================
# 00-pred_corheatmap.R
# ------------------------------------------------------------------------------
# Generates correlation heatmap across all evaluation methods and ground truth.
#
# Integrates:
#   - Ground truth (`all_metadata.csv`)
#   - Random Forest baseline (`rf_results.csv`)
#   - Google Gemini API models (`gemini_results.csv`)
#
# Output:
#   - `figs/correlation_heatmap.png`
# ==============================================================================

user_lib <- file.path(Sys.getenv("LOCALAPPDATA"), "R", "win-library", paste0(R.version$major, ".", substr(R.version$minor, 1, 1)))
if (dir.exists(user_lib)) {
  .libPaths(c(user_lib, .libPaths()))
}

suppressPackageStartupMessages({
  library(tidyverse)
})

cat("==================================================================\n")
cat(" Generating Prediction Correlation Heatmap\n")
cat("==================================================================\n")

# Load Ground Truth Metadata
metadata_file <- "data/input/all_metadata.csv"
if (!file.exists(metadata_file)) {
  stop("Master metadata not found: ", metadata_file)
}
meta_df <- read_csv(metadata_file, show_col_types = FALSE) |>
  select(passage_id, true_grade = grade)

# List of prediction sources to assemble
preds_list <- list()

# 1. Ground Truth
preds_list[[length(preds_list) + 1]] <- meta_df |>
  transmute(passage_id = as.character(passage_id), model = "True Grade", predicted_grade = as.numeric(true_grade))

# 2. Random Forest Baseline
rf_new <- "data/output/rf_results.csv"
rf_old <- "data/output/rf_results_with_ci.csv"
if (file.exists(rf_new)) {
  rf_df <- read_csv(rf_new, show_col_types = FALSE) |>
    transmute(passage_id = as.character(passage_id), model = "Random Forest", predicted_grade = as.numeric(predicted_grade))
  preds_list[[length(preds_list) + 1]] <- rf_df
} else if (file.exists(rf_old)) {
  rf_df <- read_csv(rf_old, show_col_types = FALSE)
  if (!"passage_id" %in% names(rf_df)) {
    rf_df <- rf_df |> mutate(passage_id = as.character(row_number() - 1))
  }
  rf_df <- rf_df |>
    transmute(passage_id = as.character(passage_id),
              model = "Random Forest",
              predicted_grade = as.numeric(random_forest_predictions.Median_Prediction))
  preds_list[[length(preds_list) + 1]] <- rf_df
}

# 3. Gemini Results
gemini_file <- "data/output/gemini_results.csv"
if (file.exists(gemini_file)) {
  gemini_df <- read_csv(gemini_file, show_col_types = FALSE) |>
    filter(is.na(parse_error) | parse_error == FALSE) |>
    transmute(
      passage_id = as.character(passage_id),
      model = case_when(
        str_detect(model, "3.6-flash|2.5-flash") & !str_detect(model, "thinking") ~ "Gemini Flash",
        str_detect(model, "thinking") ~ "Gemini Thinking",
        str_detect(model, "3.1-pro|pro") ~ "Gemini Pro",
        TRUE ~ model
      ),
      predicted_grade = as.numeric(predicted_grade)
    )
  preds_list[[length(preds_list) + 1]] <- gemini_df
}

# Bind all collected predictions
all_preds <- bind_rows(preds_list)

cat(sprintf("[*] Assembled predictions from %d methods across %d unique passages.\n",
            n_distinct(all_preds$model), n_distinct(all_preds$passage_id)))

# Pivot to wide format
wide_preds <- all_preds |>
  filter(!is.na(predicted_grade)) |>
  distinct(passage_id, model, .keep_all = TRUE) |>
  pivot_wider(names_from = model, values_from = predicted_grade)

# Compute pairwise complete Pearson correlation
feature_cols <- setdiff(names(wide_preds), "passage_id")
cor_matrix <- wide_preds |>
  select(all_of(feature_cols)) |>
  cor(use = "pairwise.complete.obs", method = "pearson")

# Convert to long format for ggplot
cor_df <- cor_matrix |>
  as.data.frame() |>
  rownames_to_column("Method_A") |>
  pivot_longer(-Method_A, names_to = "Method_B", values_to = "correlation")

# Order methods: True Grade first, then Random Forest, then API/LLMs
method_order <- c("True Grade", "Random Forest", setdiff(feature_cols, c("True Grade", "Random Forest")))

cor_df <- cor_df |>
  mutate(
    Method_A = factor(Method_A, levels = rev(method_order)),
    Method_B = factor(Method_B, levels = method_order)
  )

p_heatmap <- ggplot(cor_df, aes(x = Method_B, y = Method_A, fill = correlation)) +
  geom_tile(color = "white", linewidth = 0.8) +
  geom_text(aes(label = sprintf("%.2f", correlation)), size = 3.5, fontface = "bold") +
  scale_fill_gradient2(
    low = "#2A9D8F",
    mid = "#F8F9FA",
    high = "#E76F51",
    midpoint = 0,
    limits = c(-1, 1),
    name = "Pearson r"
  ) +
  coord_equal() +
  labs(
    title = "Prediction Correlation Heatmap Across Methods",
    subtitle = "Pairwise Pearson correlation including agreement with assigned grade levels",
    x = NULL,
    y = NULL
  ) +
  theme_minimal(base_size = 11) +
  theme(
    panel.grid = element_blank(),
    axis.text.x = element_text(angle = 35, hjust = 1, face = "bold"),
    axis.text.y = element_text(face = "bold"),
    legend.position = "right",
    plot.title = element_text(face = "bold", size = 13)
  )

dir.create("figs", showWarnings = FALSE, recursive = TRUE)
output_fig <- "figs/correlation_heatmap.png"
ggsave(output_fig, plot = p_heatmap, width = 9, height = 7, dpi = 300)
cat("[+] Saved correlation heatmap to:", output_fig, "\n")
