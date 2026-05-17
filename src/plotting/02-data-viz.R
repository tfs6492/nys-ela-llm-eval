library(tidyverse)
library(see)

llm_results     <- read_csv("data/output/llm_results.csv")
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
# ggsave(filename = "figs/opus_vs_rf.png", plot = opus_vs_rf)

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
# ggsave(filename = "figs/rmse_bar.png", plot = rmse_bar)

# ── Plot 3: Local LLMs (Llama, Qwen) vs. Random Forest ───────────────────────
join_results2 <- ollama_results |>
  select(passage_id, model, predicted_grade) |>
  pivot_wider(names_from = model, values_from = predicted_grade) |>
  left_join(rf_results, by = "passage_id") |>
  rename(
    llama = `llama3.2:1b`,
    qwen  = `qwen2.5:1.5b`,
    rf    = random_forest_predictions.Median_Prediction
  ) |>
  mutate(rf = round(rf)) |>
  left_join(
    llm_results |> select(passage_id, true_grade),
    by = "passage_id"
  ) |>
  pivot_longer(
    cols      = c(true_grade, rf, llama, qwen),
    names_to  = "origin",
    values_to = "grade_level"
  )

wide_results2 <- join_results2 |>
  pivot_wider(names_from = origin, values_from = grade_level)

ollama_qwen_vs_rf <- ggplot(wide_results2) +
  geom_abline(slope = 1, intercept = 0,
              linetype = "dashed", color = col_ref, linewidth = 0.6) +
  geom_smooth(aes(x = true_grade, y = rf,
                  color = "Random Forest", fill = "Random Forest"),
              method = "loess", se = TRUE, span = 0.8, alpha = 0.15) +
  geom_smooth(aes(x = true_grade, y = llama,
                  color = "Llama 3.2 1B", fill = "Llama 3.2 1B"),
              method = "loess", se = TRUE, span = 0.8, alpha = 0.15) +
  geom_smooth(aes(x = true_grade, y = qwen,
                  color = "Qwen 2.5 1.5B", fill = "Qwen 2.5 1.5B"),
              method = "loess", se = TRUE, span = 0.8, alpha = 0.15) +
  geom_point(aes(x = true_grade, y = rf,    color = "Random Forest"),
             size = 1.5, alpha = 0.7) +
  geom_point(aes(x = true_grade, y = llama, color = "Llama 3.2 1B"),
             size = 1.5, alpha = 0.7) +
  geom_point(aes(x = true_grade, y = qwen,  color = "Qwen 2.5 1.5B"),
             size = 1.5, alpha = 0.7) +
  scale_color_manual(
    name   = NULL,
    values = c(
      "Random Forest" = col_rf,
      "Llama 3.2 1B"  = col_ollama,
      "Qwen 2.5 1.5B" = col_qwen
    ),
    limits = c("Random Forest", "Llama 3.2 1B", "Qwen 2.5 1.5B")
  ) +
  scale_fill_manual(
    name   = NULL,
    values = c(
      "Random Forest" = col_rf,
      "Llama 3.2 1B"  = col_ollama,
      "Qwen 2.5 1.5B" = col_qwen
    ),
    limits = c("Random Forest", "Llama 3.2 1B", "Qwen 2.5 1.5B")
  ) +
  scale_x_continuous(breaks = 3:8) +
  scale_y_continuous(breaks = 3:8) +
  labs(
    title    = "Local LLMs and Random Forest systematically diverge from assigned reading grade level",
    subtitle = "Predicted vs. assigned grade level - dashed line indicates agreement with assigned grade level",
    caption = "RF and Qwen transition from overestimation at lower grades to underestimation at higher grades;\nLlama shows higher variance throughout.",
    x        = "Assigned Grade Level",
    y        = "Predicted Grade Level"
  ) +
  theme_minimal() +
  theme(
    axis.ticks      = element_blank(),
    legend.position = "right",
    plot.caption = element_text(hjust = 0.5)
  )
ollama_qwen_vs_rf
# ggsave(filename = "figs/ollama_qwen_vs_rf.png", plot = ollama_qwen_vs_rf)

run_palette <- c(
  "Claude Opus 4.5" = col_llm,
  "Llama 3.2 1B"    = col_ollama,
  "Qwen 2.5 1.5B"   = col_qwen
)

# --- Data Preparation ---
# Combine Claude and Ollama results for latency analysis
latency_data <- bind_rows(
  llm_results |> 
    mutate(model_label = "Claude Opus 4.5"),
  ollama_results |> 
    mutate(model_label = recode(model, 
                                "llama3.2:1b"  = "Llama 3.2 1B", 
                                "qwen2.5:1.5b" = "Qwen 2.5 1.5B"))
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
    title    = "Opus leads in latency; small models nearly converge by passage 30",
    subtitle = "Opus vs. Local LLMs: Inference Latency Trends",
    x        = "Passage ID",
    y        = "Log-scaled Duration in Seconds",
    caption  = "Log-scaled duration across passage IDs\nLines indicate OLS trend. Higher Passage IDs may correlate with longer text length or complexity."
  ) +
  theme_minimal(base_size = 12) +
  theme(
    legend.position = "bottom",
    panel.grid.minor = element_blank(),
    axis.ticks = element_blank()
  )

rt_on_passage

# ggsave(filename = "figs/latency_trend_comparison.png", plot = rt_on_passage, width = 9, height = 5, dpi = 300)

