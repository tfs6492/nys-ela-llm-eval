library(tidyverse)
library(janitor)

llm_results <- read_csv("data/output/opus_results.csv", show_col_types = FALSE) |>
  clean_names()

rf_results <- read_csv("data/output/rf_results_with_ci.csv", show_col_types = FALSE) |>
  mutate(passage_id = row_number() - 1) |>
  select(-true_y) |>
  clean_names()

ollama_results <- read_csv("data/output/ollama_results.csv", show_col_types = FALSE) |>
  clean_names()

# Map raw Ollama model strings to short column-friendly keys
model_key_map <- c(
  "deepseek-r1:8b"         = "deepseek_r1",
  "gpt-oss:20b"            = "gpt_oss",
  "cogito:14b"             = "cogito",
  "qwen3:8b"               = "qwen3",
  "mistral-small3.2:latest" = "mistral_small",
  "phi4"                   = "phi4"
)

ollama_wide <- ollama_results |>
  select(passage_id, model, predicted_grade) |>
  mutate(model = recode(model, !!!model_key_map)) |>
  pivot_wider(names_from = model, values_from = predicted_grade)

local_model_cols <- unname(model_key_map)

model_predictions <- llm_results |>
  select(passage_id, true_grade, claude = predicted_grade) |>
  left_join(
    rf_results |>
      select(passage_id, rf = random_forest_predictions_median_prediction),
    by = "passage_id"
  ) |>
  left_join(ollama_wide, by = "passage_id") |>
  mutate(across(-passage_id, as.numeric))

# Display labels and group membership
model_display <- c(
  "rf"            = "Random Forest",
  "claude"        = "Claude Opus 4.5",
  "deepseek_r1"   = "DeepSeek R1 8B",
  "gpt_oss"       = "GPT OSS 20B",
  "cogito"        = "Cogito 14B",
  "qwen3"         = "Qwen3 8B",
  "mistral_small" = "Mistral Small 3.2",
  "phi4"          = "Phi-4"
)

model_group <- c(
  "rf"            = "Baseline",
  "claude"        = "API",
  "deepseek_r1"   = "Reasoning",
  "gpt_oss"       = "Reasoning",
  "cogito"        = "Reasoning",
  "qwen3"         = "Instruction",
  "mistral_small" = "Instruction",
  "phi4"          = "Instruction"
)

# Colorblind-friendly palette (8 models)
model_colors <- c(
  "Random Forest"      = "#009E73",
  "Claude Opus 4.5"    = "#E69F00",
  "DeepSeek R1 8B"     = "#0072B2",
  "GPT OSS 20B"        = "#56B4E9",
  "Cogito 14B"         = "#332288",
  "Qwen3 8B"           = "#CC79A7",
  "Mistral Small 3.2"  = "#D55E00",
  "Phi-4"              = "#999933"
)

all_model_cols <- c("rf", "claude", local_model_cols)

rmse_results <- model_predictions |>
  pivot_longer(
    cols = all_of(all_model_cols),
    names_to = "model",
    values_to = "predicted_grade"
  ) |>
  group_by(model) |>
  summarise(
    rmse = sqrt(mean((predicted_grade - true_grade)^2, na.rm = TRUE)),
    .groups = "drop"
  ) |>
  mutate(
    model_label = recode(model, !!!model_display),
    model_group = recode(model, !!!model_group),
    model_label = fct_reorder(model_label, rmse)
  )

passage_error_results <- model_predictions |>
  pivot_longer(
    cols = all_of(all_model_cols),
    names_to = "model",
    values_to = "predicted_grade"
  ) |>
  mutate(
    absolute_error = abs(predicted_grade - true_grade),
    squared_error  = (predicted_grade - true_grade)^2,
    model_label    = recode(model, !!!model_display),
    model_group    = recode(model, !!!model_group),
    model_label    = factor(model_label, levels = names(model_colors))
  )

overall_rmse_comparison <- rmse_results |>
  ggplot(aes(x = model_label, y = rmse, fill = model_label)) +
  geom_col(width = 0.7, show.legend = FALSE) +
  geom_text(
    aes(label = round(rmse, 2)),
    hjust = -0.15,
    size = 4
  ) +
  coord_flip() +
  scale_fill_manual(values = model_colors) +
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
  width = 9,
  height = 6,
  dpi = 300
)

passage_rmse_grid <- passage_error_results |>
  ggplot(aes(x = passage_id, y = absolute_error, fill = model_label)) +
  geom_col(width = 0.8, show.legend = FALSE) +
  facet_wrap(~model_label, ncol = 2) +
  scale_x_continuous(breaks = seq(0, 30, by = 5)) +
  scale_y_continuous(
    breaks = 0:5,
    expand = expansion(mult = c(0, 0.08))
  ) +
  scale_fill_manual(values = model_colors) +
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
  width = 12,
  height = 10,
  dpi = 300
)

passage_abs_heatmap <- passage_error_results |>
  mutate(model_label = fct_rev(model_label)) |>
  ggplot(aes(x = passage_id, y = model_label, fill = absolute_error)) +
  geom_tile(color = "white", linewidth = 0.5) +
  geom_text(aes(label = round(absolute_error, 1)), size = 3) +
  scale_x_continuous(breaks = seq(0, 30, by = 2)) +
  scale_fill_gradient(
    low  = "#F7FCF5",
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
  width = 12,
  height = 5,
  dpi = 300
)

# RMSE grouped by local model category (reasoning vs instruction)
local_rmse_by_group <- rmse_results |>
  filter(model_group %in% c("Reasoning", "Instruction")) |>
  ggplot(aes(x = model_label, y = rmse, fill = model_group)) +
  geom_col(width = 0.7) +
  geom_text(
    aes(label = round(rmse, 2)),
    hjust = -0.15,
    size = 4
  ) +
  coord_flip() +
  scale_fill_manual(
    values = c("Reasoning" = "#0072B2", "Instruction" = "#CC79A7"),
    name = "Model type"
  ) +
  scale_y_continuous(
    limits = c(0, max(rmse_results$rmse) * 1.15),
    expand = expansion(mult = c(0, 0.02))
  ) +
  labs(
    title = "Local Model RMSE: Reasoning vs. Instruction",
    x = NULL,
    y = "RMSE in Grade Levels"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    panel.grid.major.y = element_blank(),
    panel.grid.minor = element_blank()
  )

ggsave(
  filename = "figs/local_rmse_by_group.png",
  plot = local_rmse_by_group,
  width = 9,
  height = 5,
  dpi = 300
)
