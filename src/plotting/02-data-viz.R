# ==============================================================================
# 02-data-viz.R
# ------------------------------------------------------------------------------
# Diagnostic Visualizations & Calibration Curves:
#   1. Predicted vs. Assigned Grade Level (LOESS calibration curves & scatter)
#   2. Divergence from Truth (Compression to the mean effect)
#   3. Latency & Inference Duration Analysis
#
# Output Figures:
#   - `figs/predicted_vs_true_grades.png`
#   - `figs/flash_vs_rf.png`
#   - `figs/thinking_vs_rf.png`
#   - `figs/latency_trend_comparison.png`
# ==============================================================================

user_lib <- file.path(Sys.getenv("LOCALAPPDATA"), "R", "win-library", paste0(R.version$major, ".", substr(R.version$minor, 1, 1)))
if (dir.exists(user_lib)) {
  .libPaths(c(user_lib, .libPaths()))
}

suppressPackageStartupMessages({
  library(tidyverse)
  library(see)
})

cat("==================================================================\n")
cat(" Generating Model Diagnostics & Calibration Visualizations\n")
cat("==================================================================\n")

# Load Metadata
meta_file <- "data/input/all_metadata.csv"
meta_df <- read_csv(meta_file, show_col_types = FALSE) |>
  select(passage_id, true_grade = grade, word_count, genre)

preds_list <- list()

# 1. Random Forest
rf_new <- "data/output/rf_results.csv"
rf_old <- "data/output/rf_results_with_ci.csv"
if (file.exists(rf_new)) {
  rf_df <- read_csv(rf_new, show_col_types = FALSE) |>
    transmute(
      passage_id = as.character(passage_id),
      model = "Random Forest",
      model_type = "RF",
      predicted_grade = as.numeric(predicted_grade),
      duration_seconds = as.numeric(duration_seconds)
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
      model_type = "RF",
      predicted_grade = as.numeric(random_forest_predictions.Median_Prediction),
      duration_seconds = NA_real_
    )
  preds_list[[length(preds_list) + 1]] <- rf_df
}

# 2. Gemini API
gemini_file <- "data/output/gemini_results.csv"
if (file.exists(gemini_file)) {
  gemini_df <- read_csv(gemini_file, show_col_types = FALSE) |>
    filter(is.na(parse_error) | parse_error == FALSE) |>
    transmute(
      passage_id = as.character(passage_id),
      model = case_when(
        str_detect(model, "3.6-flash|2.5-flash") & !str_detect(model, "thinking") ~ "Gemini Flash",
        str_detect(model, "thinking") ~ "Gemini Thinking",
        str_detect(model, "3.1-pro|pro") ~ "Gemini 3.1 Pro",
        TRUE ~ model
      ),
      model_type = case_when(
        str_detect(model, regex("thinking", ignore_case = TRUE)) ~ "Thinking",
        str_detect(model, regex("pro", ignore_case = TRUE)) ~ "Cloud Pro",
        TRUE ~ "Flash"
      ),
      predicted_grade = as.numeric(predicted_grade),
      duration_seconds = as.numeric(duration_seconds)
    )
  preds_list[[length(preds_list) + 1]] <- gemini_df
}

all_preds <- bind_rows(preds_list) |>
  left_join(meta_df |> select(passage_id, meta_true_grade = true_grade, word_count, genre), by = "passage_id")

if ("true_grade" %in% names(all_preds)) {
  all_preds <- all_preds |> mutate(true_grade = coalesce(true_grade, meta_true_grade))
} else {
  all_preds <- all_preds |> mutate(true_grade = meta_true_grade)
}
all_preds <- all_preds |> filter(!is.na(predicted_grade) & !is.na(true_grade))

# ------------------------------------------------------------------------------
# Plot 1: Calibration Curves (Predicted vs Assigned Grade Level)
# ------------------------------------------------------------------------------
p_calibration <- ggplot(all_preds, aes(x = true_grade, y = predicted_grade, color = model_type, fill = model_type)) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", color = "#777777", linewidth = 0.7) +
  geom_jitter(width = 0.15, height = 0.15, alpha = 0.45, size = 1.6) +
  geom_smooth(method = "loess", formula = y ~ x, se = TRUE, alpha = 0.18, linewidth = 1.1) +
  scale_color_manual(values = c(
    "RF"        = "#8E24AA",
    "Flash"     = "#6CC24A",
    "Thinking"  = "#0D6E52",
    "Cloud Pro" = "#E9C46A"
  ), name = "Model Type") +
  scale_fill_manual(values = c(
    "RF"        = "#8E24AA",
    "Flash"     = "#6CC24A",
    "Thinking"  = "#0D6E52",
    "Cloud Pro" = "#E9C46A"
  ), name = "Model Type") +
  scale_x_continuous(breaks = 3:8, limits = c(2.5, 8.5)) +
  scale_y_continuous(breaks = 2:9, limits = c(1.5, 9.5)) +
  labs(
    title = "Systematic Divergence from Assigned Grade Levels",
    subtitle = "Predicted vs. assigned grade level — dashed line indicates perfect agreement with assigned levels",
    caption = "Predictions rate low-grade passages above and high-grade passages below their assigned levels (compression to the mean)",
    x = "Assigned Grade Level",
    y = "Predicted Grade Level"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    plot.title = element_text(face = "bold"),
    plot.caption = element_text(hjust = 0.5, size = 9),
    legend.position = "bottom"
  )

dir.create("figs", showWarnings = FALSE, recursive = TRUE)
ggsave("figs/predicted_vs_true_grades.png", plot = p_calibration, width = 9.5, height = 6, dpi = 300)
cat("[+] Saved calibration curves to: figs/predicted_vs_true_grades.png\n")

# ------------------------------------------------------------------------------
# Plot 2: Flash vs. RF Divergence
# ------------------------------------------------------------------------------
flash_sub <- all_preds |>
  filter(model_type %in% c("RF", "Flash"))

p_flash <- ggplot(flash_sub, aes(x = true_grade, y = predicted_grade, color = model, fill = model)) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", color = "#777777", linewidth = 0.7) +
  geom_jitter(width = 0.15, height = 0.15, alpha = 0.4, size = 1.5) +
  geom_smooth(method = "loess", formula = y ~ x, se = TRUE, alpha = 0.15, linewidth = 0.9) +
  scale_color_manual(values = c("Random Forest" = "#8E24AA", "Gemini Flash" = "#6CC24A", "Gemini Thinking" = "#0D6E52")) +
  scale_fill_manual(values = c("Random Forest" = "#8E24AA", "Gemini Flash" = "#6CC24A", "Gemini Thinking" = "#0D6E52")) +
  scale_x_continuous(breaks = 3:8) +
  scale_y_continuous(breaks = 2:9) +
  labs(
    title = "Gemini Flash vs. Random Forest",
    subtitle = "Assigned vs. Predicted Reading Grade Level",
    x = "Assigned Grade Level",
    y = "Predicted Grade Level"
  ) +
  theme_minimal(base_size = 11) +
  theme(plot.title = element_text(face = "bold"), legend.position = "right")

ggsave("figs/flash_vs_rf.png", plot = p_flash, width = 9, height = 5.5, dpi = 300)
cat("[+] Saved Flash comparison to: figs/flash_vs_rf.png\n")

# ------------------------------------------------------------------------------
# Plot 3: Thinking vs. RF Divergence
# ------------------------------------------------------------------------------
thinking_sub <- all_preds |>
  filter(model_type %in% c("RF", "Thinking"))

p_thinking <- ggplot(thinking_sub, aes(x = true_grade, y = predicted_grade, color = model, fill = model)) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", color = "#777777", linewidth = 0.7) +
  geom_jitter(width = 0.15, height = 0.15, alpha = 0.4, size = 1.5) +
  geom_smooth(method = "loess", formula = y ~ x, se = TRUE, alpha = 0.15, linewidth = 0.9) +
  scale_color_manual(values = c("Random Forest" = "#8E24AA", "Gemini Flash" = "#6CC24A", "Gemini Thinking" = "#0D6E52")) +
  scale_fill_manual(values = c("Random Forest" = "#8E24AA", "Gemini Flash" = "#6CC24A", "Gemini Thinking" = "#0D6E52")) +
  scale_x_continuous(breaks = 3:8) +
  scale_y_continuous(breaks = 2:9) +
  labs(
    title = "Gemini Thinking vs. Random Forest",
    subtitle = "Assigned vs. Predicted Reading Grade Level",
    x = "Assigned Grade Level",
    y = "Predicted Grade Level"
  ) +
  theme_minimal(base_size = 11) +
  theme(plot.title = element_text(face = "bold"), legend.position = "right")

ggsave("figs/thinking_vs_rf.png", plot = p_thinking, width = 9, height = 5.5, dpi = 300)
cat("[+] Saved Thinking comparison to: figs/thinking_vs_rf.png\n")

# ------------------------------------------------------------------------------
# Plot 4: Latency & Duration Analysis
# ------------------------------------------------------------------------------
latency_df <- all_preds |>
  filter(!is.na(duration_seconds) & duration_seconds > 0) |>
  mutate(log_rt = log(duration_seconds))

if (nrow(latency_df) > 0) {
  p_latency <- ggplot(latency_df, aes(x = true_grade, y = duration_seconds, color = model_type, fill = model_type)) +
    geom_jitter(width = 0.2, alpha = 0.5, size = 1.8) +
    geom_smooth(method = "lm", formula = y ~ x, se = TRUE, alpha = 0.15) +
    scale_y_log10() +
    scale_x_continuous(breaks = 3:8) +
    scale_color_manual(values = c(
      "RF"        = "#8E24AA",
      "Flash"     = "#6CC24A",
      "Thinking"  = "#0D6E52",
      "Cloud Pro" = "#E9C46A"
    ), name = "Model Paradigm") +
    scale_fill_manual(values = c(
      "RF"        = "#8E24AA",
      "Flash"     = "#6CC24A",
      "Thinking"  = "#0D6E52",
      "Cloud Pro" = "#E9C46A"
    ), name = "Model Paradigm") +
    labs(
      title = "Inference Latency by Grade Level & Model Paradigm",
      subtitle = "Log-scaled latency (seconds) across assigned reading grade levels",
      x = "Assigned Grade Level",
      y = "Inference Duration (Seconds, Log Scale)"
    ) +
    theme_minimal(base_size = 12) +
    theme(
      plot.title = element_text(face = "bold"),
      panel.grid.minor = element_blank(),
      legend.position = "bottom"
    )

  ggsave("figs/latency_trend_comparison.png", plot = p_latency, width = 9, height = 5.5, dpi = 300)
  cat("[+] Saved latency comparison to: figs/latency_trend_comparison.png\n")
}
