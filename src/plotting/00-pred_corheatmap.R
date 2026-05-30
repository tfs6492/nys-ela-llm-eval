library(tidyverse)
library(janitor)

llm_results <- read_csv("data/output/opus_results.csv") |> clean_names()

rf_results <- read_csv("data/output/rf_results_with_ci.csv") |>
  mutate(passage_id = row_number() - 1) |>
  select(-true_y) |> 
  clean_names()

ollama_results <- read_csv("data/output/ollama_results.csv") |> 
  clean_names()

join_results <- llm_results |>
  left_join(rf_results, by = "passage_id") |>
  select(passage_id, true_grade, random_forest_predictions_median_prediction, predicted_grade) |>
  pivot_longer(
    cols = c(true_grade, random_forest_predictions_median_prediction, predicted_grade),
    names_to = "origin",
    values_to = "grade_level"
  ) |>
  mutate(origin = recode(origin,
                         "true_grade" = "true_grade",
                         "random_forest_predictions_median_prediction" = "rf",
                         "predicted_grade"  = "llm"
  )) |>
  mutate(grade_level = if_else(origin == "rf", round(grade_level), grade_level))

model_key_map <- c(
  "deepseek-r1:8b"          = "deepseek_r1",
  "gpt-oss:20b"             = "gpt_oss",
  "cogito:14b"              = "cogito",
  "qwen3:8b"                = "qwen3",
  "mistral-small3.2:latest" = "mistral_small",
  "phi4"                    = "phi4"
)

ollama_wide <- ollama_results |>
  select(passage_id, model, predicted_grade) |>
  mutate(model = recode(model, !!!model_key_map)) |>
  pivot_wider(names_from = model, values_from = predicted_grade)

correlation_results <- llm_results |>
  select(passage_id, true_grade, claude = predicted_grade) |>
  left_join(
    rf_results |>
      select(passage_id, rf = random_forest_predictions_median_prediction),
    by = "passage_id"
  ) |>
  left_join(ollama_wide, by = "passage_id") |>
  mutate(across(-passage_id, as.numeric))

correlation_matrix <- correlation_results |>
  select(-passage_id) |>
  cor(use = "pairwise.complete.obs", method = "pearson")

correlation_plot_data <- correlation_matrix |>
  as.data.frame() |>
  rownames_to_column("method_1") |>
  pivot_longer(-method_1, names_to = "method_2", values_to = "correlation") |>
  mutate(
    method_1 = recode(method_1,
                      "true_grade"    = "True Grade",
                      "claude"        = "Claude Opus 4.5",
                      "rf"            = "Random Forest",
                      "deepseek_r1"   = "DeepSeek R1 8B",
                      "gpt_oss"       = "GPT OSS 20B",
                      "cogito"        = "Cogito 14B",
                      "qwen3"         = "Qwen3 8B",
                      "mistral_small" = "Mistral Small 3.2",
                      "phi4"          = "Phi-4"),
    method_2 = recode(method_2,
                      "true_grade"    = "True Grade",
                      "claude"        = "Claude Opus 4.5",
                      "rf"            = "Random Forest",
                      "deepseek_r1"   = "DeepSeek R1 8B",
                      "gpt_oss"       = "GPT OSS 20B",
                      "cogito"        = "Cogito 14B",
                      "qwen3"         = "Qwen3 8B",
                      "mistral_small" = "Mistral Small 3.2",
                      "phi4"          = "Phi-4")
  )

method_order <- c(
  "True Grade",
  "Random Forest",
  "Claude Opus 4.5",
  "DeepSeek R1 8B",
  "GPT OSS 20B",
  "Cogito 14B",
  "Qwen3 8B",
  "Mistral Small 3.2",
  "Phi-4"
)

correlation_heatmap <- correlation_plot_data |>
  mutate(
    method_1 = factor(method_1, levels = rev(method_order)),
    method_2 = factor(method_2, levels = method_order)
  ) |>
  ggplot(aes(x = method_2, y = method_1, fill = correlation)) +
  geom_tile(color = "white", linewidth = 0.8) +
  geom_text(aes(label = round(correlation, 2)), size = 4) +
  scale_fill_gradient2(
    low = "#4DFFF3",
    mid = "white",
    high = "#FE6D73",
    midpoint = 0,
    limits = c(-1, 1),
    name = "Pearson r"
  ) +
  coord_equal() +
  labs(
    title = "Prediction Correlations Across Methods",
    x = NULL,
    y = NULL
  ) +
  theme_minimal(base_size = 12) +
  theme(
    panel.grid = element_blank(),
    axis.text.x = element_text(angle = 35, hjust = 1),
    legend.position = "right"
  )

correlation_heatmap

ggsave(
  filename = "figs/correlation_heatmap.png",
  plot = correlation_heatmap,
  width = 8,
  height = 6,
  dpi = 300
)
