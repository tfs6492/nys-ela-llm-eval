library(tidyverse)
library(janitor)

llm_results <- read_csv("data/output/llm_results.csv", show_col_types = FALSE) |>
  clean_names()

rf_results <- read_csv("data/output/rf_results_with_ci.csv", show_col_types = FALSE) |>
  mutate(passage_id = row_number() - 1) |>
  select(-true_y) |>
  clean_names()

ollama_results <- read_csv("data/output/ollama_results.csv", show_col_types = FALSE) |>
  clean_names()

ollama_wide <- ollama_results |>
  select(passage_id, model, predicted_grade) |>
  mutate(model = recode(model,
                        "llama3.2:1b" = "llama",
                        "qwen2.5:1.5b" = "qwen")) |>
  pivot_wider(names_from = model, values_from = predicted_grade)

model_predictions <- llm_results |>
  select(passage_id, true_grade, claude = predicted_grade) |>
  left_join(
    rf_results |>
      select(passage_id, rf = random_forest_predictions_median_prediction),
    by = "passage_id"
  ) |>
  left_join(ollama_wide, by = "passage_id") |>
  mutate(across(-passage_id, as.numeric))

rmse_results <- model_predictions |>
  pivot_longer(
    cols = c(rf, claude, llama, qwen),
    names_to = "model",
    values_to = "predicted_grade"
  ) |>
  group_by(model) |>
  summarise(
    rmse = sqrt(mean((predicted_grade - true_grade)^2, na.rm = TRUE)),
    .groups = "drop"
  ) |>
  mutate(
    model = recode(model,
                   "rf" = "Random Forest",
                   "claude" = "Claude Opus 4.5",
                   "llama" = "Llama 3.2 1B",
                   "qwen" = "Qwen 2.5 1.5B"),
    model = fct_reorder(model, rmse)
  )

passage_error_results <- model_predictions |>
  pivot_longer(
    cols = c(rf, claude, llama, qwen),
    names_to = "model",
    values_to = "predicted_grade"
  ) |>
  mutate(
    absolute_error = abs(predicted_grade - true_grade),
    squared_error = (predicted_grade - true_grade)^2,
    model = recode(model,
                   "rf" = "Random Forest",
                   "claude" = "Claude Opus 4.5",
                   "llama" = "Llama 3.2 1B",
                   "qwen" = "Qwen 2.5 1.5B"),
    model = factor(
      model,
      levels = c("Random Forest", "Claude Opus 4.5", "Llama 3.2 1B", "Qwen 2.5 1.5B")
    )
  )

overall_rmse_comparison <- rmse_results |>
  ggplot(aes(x = model, y = rmse, fill = model)) +
  geom_col(width = 0.7, show.legend = FALSE) +
  geom_text(
    aes(label = round(rmse, 2)),
    hjust = -0.15,
    size = 4
  ) +
  coord_flip() +
  scale_fill_manual(
    values = c(
      "Random Forest" = "#009E73",
      "Claude Opus 4.5" = "#E69F00",
      "Llama 3.2 1B" = "#56B4E9",
      "Qwen 2.5 1.5B" = "#CC79A7"
    )
  ) +
  scale_y_continuous(
    limits = c(0, max(rmse_results$rmse) * 1.15),
    expand = expansion(mult = c(0, 0.02))
  ) +
  labs(
    title = "RMSE by Grade-Level Prediction Method",
    x = NULL,
    y = "RMSE in Grade Levels"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    panel.grid.major.y = element_blank(),
    panel.grid.minor = element_blank()
  )


ggsave(
  filename = "figs/overall_rmse_compare.png",
  plot = overall_rmse_comparison,
  width = 8,
  height = 5,
  dpi = 300
)

passage_rmse_grid <- passage_error_results |>
  ggplot(aes(x = passage_id, y = absolute_error, fill = model)) +
  geom_col(width = 0.8, show.legend = FALSE) +
  facet_wrap(~model, ncol = 1) +
  scale_x_continuous(breaks = seq(0, 30, by = 2)) +
  scale_y_continuous(
    breaks = 0:5,
    expand = expansion(mult = c(0, 0.08))
  ) +
  scale_fill_manual(
    values = c(
      "Random Forest" = "#009E73",
      "Claude Opus 4.5" = "#E69F00",
      "Llama 3.2 1B" = "#56B4E9",
      "Qwen 2.5 1.5B" = "#CC79A7"
    )
  ) +
  labs(
    title = "Per-Passage Prediction Error by Method",
    subtitle = "Absolute grade-level error for each passage",
    x = "Passage ID",
    y = "Absolute Error"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    panel.grid.major.x = element_blank(),
    panel.grid.minor = element_blank(),
    strip.text = element_text(face = "bold"),
    axis.text.x = element_text(size = 8)
  )

ggsave(
  filename = "figs/absolute_error_grid.png",
  plot = passage_rmse_grid,
  width = 10,
  height = 8,
  dpi = 300
)

passage_abs_heatmap <- passage_error_results |>
  mutate(model = fct_rev(model)) |>
  ggplot(aes(x = passage_id, y = model, fill = absolute_error)) +
  geom_tile(color = "white", linewidth = 0.5) +
  geom_text(aes(label = round(absolute_error, 1)), size = 3) +
  scale_x_continuous(breaks = seq(0, 30, by = 2)) +
  scale_fill_gradient(
    low = "#F7FCF5",
    high = "#D55E00",
    name = "Absolute\nerror"
  ) +
  labs(
    title = "Per-Passage Prediction Error Heatmap",
    subtitle = "Darker cells show larger grade-level misses",
    x = "Passage ID",
    y = NULL
  ) +
  theme_minimal(base_size = 12) +
  theme(
    panel.grid = element_blank(),
    axis.text.x = element_text(size = 8),
    legend.position = "right"
  )

ggsave(
  filename = "figs/abs_error_heatmap.png",
  plot = passage_abs_heatmap,
  width = 10,
  height = 4,
  dpi = 300
)
