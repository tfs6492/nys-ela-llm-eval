library(tidyverse)
library(see)

llm_results     <- read_csv("data/output/opus_results.csv")
rf_results      <- read_csv("data/output/rf_results_with_ci.csv") |>
  mutate(passage_id = row_number() - 1) |>
  select(-true_y)
ollama_results  <- read_csv("data/output/ollama_results.csv")

join_results <- llm_results |>
  left_join(rf_results, by = "passage_id") |>
  select(passage_id, 
         true_grade, 
         random_forest_predictions.Median_Prediction, 
         predicted_grade) |>
  pivot_longer(
    cols      = c(true_grade, 
                  random_forest_predictions.Median_Prediction, 
                  predicted_grade),
    names_to  = "origin",
    values_to = "grade_level"
  ) |>
  mutate(origin = recode(origin,
                         "true_grade"                = "true_grade",
                         "random_forest_predictions.Median_Prediction" = "rf",
                         "predicted_grade"           = "llm"
  )) |>
  mutate(grade_level = if_else(origin == "rf", round(grade_level), grade_level))

# ── Colors ────────────────────────────────────────────────────────────────────
col_ref    <- "#AAAAAA"   # reference line (perfect prediction diagonal)
col_rf     <- unname(okabeito_colors(3))
col_llm    <- unname(okabeito_colors(1))
col_ollama <- unname(okabeito_colors(2))
col_qwen   <- unname(okabeito_colors(7))

wide_results <- join_results |>
  pivot_wider(names_from = origin, values_from = grade_level)

# ── Plot 1: Claude Opus 4.5 vs. Random Forest ─────────────────────────────────
opus_vs_rf <- ggplot(wide_results) +
  geom_abline(slope = 1, intercept = 0,
              linetype = "dashed", color = col_ref, linewidth = 0.6) +
  geom_smooth(aes(x = true_grade, y = rf,
                  color = "Random Forest", fill = "Random Forest"),
              method = "loess", se = TRUE, span = 0.8, alpha = 0.15) +
  geom_smooth(aes(x = true_grade, y = llm,
                  color = "Claude Opus 4.5", fill = "Claude Opus 4.5"),
              method = "loess", se = TRUE, span = 0.8, alpha = 0.15) +
  geom_point(aes(x = true_grade, y = rf,  color = "Random Forest"),
             size = 1.5, alpha = 0.7) +
  geom_point(aes(x = true_grade, y = llm, color = "Claude Opus 4.5"),
             size = 1.5, alpha = 0.7) +
  scale_color_manual(
    name   = NULL,
    values = c("Random Forest" = col_rf, "Claude Opus 4.5" = col_llm),
    limits = c("Random Forest", "Claude Opus 4.5")
  ) +
  scale_fill_manual(
    name   = NULL,
    values = c("Random Forest" = col_rf, "Claude Opus 4.5" = col_llm),
    limits = c("Random Forest", "Claude Opus 4.5")
  ) +
  scale_x_continuous(breaks = 3:8) +
  scale_y_continuous(breaks = 3:8) +
  labs(
    title    = "Opus and Random Forest systematically diverge from assigned reading grade level",
    subtitle = "Predicted vs. assigned grade level - dashed line indicates agreement with assigned grade level",
    caption  = "Opus and Random Forest transition from overestimation to underestimation at assigned grades 5-6",
    x        = "Assigned Grade Level",
    y        = "Predicted Grade Level"
  ) +
  theme_minimal() +
  theme(
    axis.ticks        = element_blank(),
    legend.position   = "right",
    plot.caption    = element_text(hjust = 0.5)
  )
opus_vs_rf
ggsave(filename = "figs/opus_vs_rf.png", plot = opus_vs_rf)

# ── Plot 2: Absolute deviation by assigned grade level ────────────────────────
rmse_bar <- wide_results |>
  mutate(
    rmse_rf  = abs(rf  - true_grade),
    rmse_llm = abs(llm - true_grade)
  ) |>
  select(true_grade, rmse_rf, rmse_llm) |>
  pivot_longer(
    cols      = c(rmse_rf, rmse_llm),
    names_to  = "method",
    values_to = "abs_dev"
  ) |>
  mutate(method = recode(method,
                         "rmse_rf"  = "Random Forest",
                         "rmse_llm" = "Claude Opus 4.5"
  )) |>
  group_by(true_grade, method) |>
  summarise(abs_dev = mean(abs_dev), .groups = "drop") |>
  ggplot(aes(x = factor(true_grade), y = abs_dev, fill = method)) +
  geom_bar(stat = "identity", position = "dodge", width = 0.7, alpha = 0.8) +
  scale_fill_manual(
    name   = NULL,
    values = c("Random Forest" = col_rf, "Claude Opus 4.5" = col_llm)
  ) +
  scale_y_continuous(breaks = 0:3) +
  labs(
    title    = "RF deviations larger at lower grades; Opus deviations larger at higher grades",
    subtitle = "Mean absolute deviation by assigned grade level",
    x        = "Assigned Grade Level",
    y        = "Mean Absolute Deviation (Grade Levels)"
  ) +
  theme_minimal() +
  theme(
    legend.position      = "top",
    panel.grid.major.x   = element_blank(),
    axis.ticks           = element_blank()
  )
rmse_bar
ggsave(filename = "figs/rmse_bar.png", plot = rmse_bar)

# ── Plot 3: Local LLMs vs. Random Forest (split by model type) ───────────────

model_key_map <- c(
  "deepseek-r1:8b"          = "deepseek_r1",
  "gpt-oss:20b"             = "gpt_oss",
  "cogito:14b"              = "cogito",
  "qwen3:8b"                = "qwen3",
  "mistral-small3.2:latest" = "mistral_small",
  "phi4"                    = "phi4"
)

local_model_display <- c(
  "deepseek_r1"   = "DeepSeek R1 8B",
  "gpt_oss"       = "GPT OSS 20B",
  "cogito"        = "Cogito 14B",
  "qwen3"         = "Qwen3 8B",
  "mistral_small" = "Mistral Small 3.2",
  "phi4"          = "Phi-4"
)

local_model_colors <- c(
  "Random Forest"     = col_rf,
  "DeepSeek R1 8B"    = "#0072B2",
  "GPT OSS 20B"       = "#56B4E9",
  "Cogito 14B"        = "#332288",
  "Qwen3 8B"          = "#CC79A7",
  "Mistral Small 3.2" = "#D55E00",
  "Phi-4"             = "#999933"
)

wide_local <- ollama_results |>
  select(passage_id, model, predicted_grade) |>
  mutate(model = recode(model, !!!model_key_map)) |>
  pivot_wider(names_from = model, values_from = predicted_grade) |>
  left_join(rf_results, by = "passage_id") |>
  rename(rf = random_forest_predictions.Median_Prediction) |>
  mutate(rf = round(rf)) |>
  left_join(llm_results |> select(passage_id, true_grade), by = "passage_id")

make_local_plot <- function(data, model_cols, title, caption_text) {
  long_data <- data |>
    select(passage_id, true_grade, rf, all_of(model_cols)) |>
    pivot_longer(
      cols      = c(rf, all_of(model_cols)),
      names_to  = "origin",
      values_to = "predicted"
    ) |>
    mutate(
      label = if_else(
        origin == "rf", "Random Forest",
        recode(origin, !!!local_model_display)
      )
    )

  used_labels <- c("Random Forest", unname(local_model_display[model_cols]))
  used_colors <- local_model_colors[used_labels]

  ggplot(long_data, aes(x = true_grade, y = predicted,
                        color = label, fill = label)) +
    geom_abline(slope = 1, intercept = 0,
                linetype = "dashed", color = col_ref, linewidth = 0.6) +
    geom_smooth(method = "loess", se = TRUE, span = 0.8, alpha = 0.15) +
    geom_point(size = 1.5, alpha = 0.7) +
    scale_color_manual(name = NULL, values = used_colors, limits = names(used_colors)) +
    scale_fill_manual(name  = NULL, values = used_colors, limits = names(used_colors)) +
    scale_x_continuous(breaks = 3:8) +
    scale_y_continuous(breaks = 3:8) +
    labs(
      title    = title,
      subtitle = "Predicted vs. assigned grade level — dashed line indicates perfect agreement",
      caption  = caption_text,
      x        = "Assigned Grade Level",
      y        = "Predicted Grade Level"
    ) +
    theme_minimal() +
    theme(
      axis.ticks      = element_blank(),
      legend.position = "right",
      plot.caption    = element_text(hjust = 0.5)
    )
}

reasoning_vs_rf <- make_local_plot(
  wide_local,
  model_cols   = c("deepseek_r1", "gpt_oss", "cogito"),
  title        = "RF Tracks Assigned Grades, Reasoning-Based LLMs Compress to Mean",
  caption_text = "DeepSeek R1, GPT OSS, Cogito compared to RF baseline"
)
reasoning_vs_rf
ggsave(filename = "figs/reasoning_vs_rf.png", plot = reasoning_vs_rf, width = 9, height = 5, dpi = 300)

instruction_vs_rf <- make_local_plot(
  wide_local,
  model_cols   = c("qwen3", "mistral_small", "phi4"),
  title        = "RF Tracks Assigned Grades, Instruct-Based LLMs Compress to Mean",
  caption_text = "Qwen3, Mistral Small, Phi-4 compared to RF baseline"
)
instruction_vs_rf
ggsave(filename = "figs/instruction_vs_rf.png", plot = instruction_vs_rf, width = 9, height = 5, dpi = 300)

run_palette <- c(
  "Claude Opus 4.5"   = col_llm,
  "DeepSeek R1 8B"    = "#0072B2",
  "GPT OSS 20B"       = "#56B4E9",
  "Cogito 14B"        = "#332288",
  "Qwen3 8B"          = "#CC79A7",
  "Mistral Small 3.2" = "#D55E00",
  "Phi-4"             = "#999933"
)

# --- Data Preparation ---
# Combine Claude and Ollama results for latency analysis
latency_data <- bind_rows(
  llm_results |>
    mutate(model_label = "Claude Opus 4.5"),
  ollama_results |>
    mutate(model_label = recode(model,
                                "deepseek-r1:8b"          = "DeepSeek R1 8B",
                                "gpt-oss:20b"             = "GPT OSS 20B",
                                "cogito:14b"              = "Cogito 14B",
                                "qwen3:8b"                = "Qwen3 8B",
                                "mistral-small3.2:latest" = "Mistral Small 3.2",
                                "phi4"                    = "Phi-4"))
) |>
  # Apply the log transformation as requested
  mutate(log_rt = log(duration_seconds))

# --- Plotting ---
rt_on_passage <- ggplot(latency_data, aes(x = passage_id, y = log_rt, color = model_label, fill = model_label)) +
  # OLS regression lines for each model
  geom_smooth(
    method = "lm", 
    formula = y ~ x,
    se = TRUE, 
    alpha = 0.15, 
    linewidth = 0.8
  ) +
  # Jittered points for raw distribution
  geom_point(
    size = 1.8, 
    alpha = 0.6,
    position = position_jitter(width = 0.2, height = 0, seed = 42)
  ) +
  # Apply custom color and fill scales
  scale_color_manual(values = run_palette, name = NULL) +
  scale_fill_manual(values = run_palette, name = NULL) +
  # Formatting and Labels
  scale_x_continuous(breaks = seq(0, max(latency_data$passage_id, na.rm = TRUE), by = 5)) +
  labs(
    title    = "Local LLMs Defy Complexity-Driven Latency Spikes Seen in Opus",
    subtitle = "Opus vs. Local LLMs: Inference Latency Trends",
    x        = "Passage ID",
    y        = "Log-scaled Duration (Seconds)",
    caption  = "Log-scaled duration across passage IDs\nLines indicate OLS trend. Higher Passage IDs may correlate with longer text length or complexity."
  ) +
  theme_minimal(base_size = 12) +
  theme(
    legend.position = "bottom",
    panel.grid.minor = element_blank(),
    axis.ticks = element_blank()
  )

rt_on_passage

ggsave(filename = "figs/latency_trend_comparison.png", plot = rt_on_passage, width = 9, height = 5, dpi = 300)

