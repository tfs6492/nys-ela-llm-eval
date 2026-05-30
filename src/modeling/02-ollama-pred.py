"""
ollama_grading.py
-----------------
Sends each passage in GASS_Final_DS.csv through a structured chain-of-thought
grading prompt using a local Ollama model, and records the predicted reading
grade level.

Usage
-----
    # Make sure Ollama is running first:
    ollama serve

    # Run for a single model:
    python src/ollama_grading.py --model deepseek-r1:8b

    # Run reasoning models only:
    python src/ollama_grading.py --model deepseek-r1:8b gpt-oss:20b cogito:14b

    # Run instruction models only:
    python src/ollama_grading.py --model qwen3:8b mistral-small3.2:latest phi4

    # Specify input/output paths explicitly:
    python src/ollama_grading.py \
        --model deepseek-r1:8b gpt-oss:20b cogito:14b qwen3:8b mistral-small3.2:latest phi4 \
        --input  data/input/GASS_Final_DS.csv \
        --prompt prompt.md \
        --output data/output/ollama_results.csv

    # Resume a partial run:
    python src/ollama_grading.py --model qwen2.5:1.5b --resume
    
Dependencies
------------
    pip install requests pandas

Output
------
    ollama_results.csv  — one row per passage per model, columns:
        passage_id          : 0-indexed row number from the input CSV
        true_grade          : ground-truth grade level from input CSV
        model               : model string used for this prediction
        raw_response        : full text returned by the model (for auditing)
        predicted_grade     : integer parsed from the model's output line
        parse_error         : True if the response could not be parsed
        error_message       : error text if call failed (empty string if none)
        duration_seconds    : wall-clock time for that API call
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import time
from datetime import datetime
from pathlib import Path

import pandas as pd
import requests


# ---------------------------------------------------------------------------
# Configuration defaults
# ---------------------------------------------------------------------------

PROJECT_ROOT = Path(__file__).resolve().parents[2]

DEFAULT_INPUT = str(PROJECT_ROOT / "data/input/2024_passages.csv")
DEFAULT_PROMPT = str(PROJECT_ROOT / "prompts/prompt.md")
DEFAULT_OUTPUT = str(PROJECT_ROOT / "data/output/ollama_results.csv")
REASONING_MODELS = ["deepseek-r1:8b", "gpt-oss:20b", "cogito:14b"]
INSTRUCTION_MODELS = ["qwen3:8b", "mistral-small3.2:latest", "phi4"]
DEFAULT_MODELS = REASONING_MODELS + INSTRUCTION_MODELS


OLLAMA_URL = "http://localhost:11434/api/generate"
REQUEST_DELAY = 2.0  # seconds between requests
MAX_RETRIES = 3
RETRY_BACKOFF = 10.0  # seconds before first retry (doubles each time)


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------


def parse_args():
    parser = argparse.ArgumentParser(
        description="Grade reading passages via local Ollama models."
    )
    parser.add_argument(
        "--model",
        nargs="+",
        default=DEFAULT_MODELS,
        help="One or more Ollama model names to run",
    )
    parser.add_argument(
        "--input",
        default=DEFAULT_INPUT,
        help=f"Path to input CSV (default: {DEFAULT_INPUT})",
    )
    parser.add_argument(
        "--prompt",
        default=DEFAULT_PROMPT,
        help=f"Path to system prompt file (default: {DEFAULT_PROMPT})",
    )
    parser.add_argument(
        "--output",
        default=DEFAULT_OUTPUT,
        help=f"Path for output CSV (default: {DEFAULT_OUTPUT})",
    )
    parser.add_argument(
        "--resume",
        action="store_true",
        help="Skip passage_id + model combinations already in output",
    )
    return parser.parse_args()


# ---------------------------------------------------------------------------
# Grade parsing
# ---------------------------------------------------------------------------

GRADE_PATTERN = re.compile(r"Reading Level:\s*Grade\s*(\d+)", re.IGNORECASE)


def parse_grade(raw: str) -> tuple[int | None, bool]:
    """
    Returns (grade_int, parse_error).
    parse_error is True when the pattern was not found.
    Handles:
      - DeepSeek <think>...</think> reasoning blocks
      - Markdown bold/header formatting (**, ##)
      - Trailing punctuation or whitespace
    """
    # Strip DeepSeek chain-of-thought blocks
    cleaned = re.sub(r"<think>.*?</think>", "", raw, flags=re.DOTALL)
    # Strip markdown formatting
    cleaned = re.sub(r"[\*#]+", "", cleaned)
    match = GRADE_PATTERN.search(cleaned)
    if match:
        return int(match.group(1)), False
    return None, True


# ---------------------------------------------------------------------------
# Ollama API call
# ---------------------------------------------------------------------------


def call_ollama(
    model: str,
    system_prompt: str,
    passage: str,
    max_retries: int = MAX_RETRIES,
    backoff: float = RETRY_BACKOFF,
) -> tuple[str, float]:
    """
    Returns (raw_response_text, duration_seconds).
    Raises on non-retryable errors after max_retries attempts.
    """
    payload = {
        "model": model,
        "system": system_prompt,
        "prompt": passage,
        "stream": False,
        "options": {
            "temperature": 0.0,  # deterministic
            "num_predict": 8000,  # reasoning models need space for <think> blocks
        },
    }

    attempt = 0
    while True:
        t0 = time.time()
        try:
            response = requests.post(
                OLLAMA_URL,
                json=payload,
                timeout=300,  # 5 min timeout — large models can be slow
            )
            duration = time.time() - t0

            if response.status_code != 200:
                raise RuntimeError(
                    f"Ollama returned HTTP {response.status_code}: {response.text[:200]}"
                )

            data = response.json()
            raw = data.get("response", "").strip()
            return raw, duration

        except (requests.ConnectionError, requests.Timeout) as e:
            attempt += 1
            wait = backoff * (2 ** (attempt - 1))
            print(
                f"\n    [Connection error] Waiting {wait:.0f}s before retry "
                f"{attempt}/{max_retries}… ({e})"
            )
            if attempt >= max_retries:
                raise
            time.sleep(wait)

        except RuntimeError:
            attempt += 1
            wait = backoff * (2 ** (attempt - 1))
            print(
                f"\n    [API error] Waiting {wait:.0f}s before retry "
                f"{attempt}/{max_retries}…"
            )
            if attempt >= max_retries:
                raise
            time.sleep(wait)


# ---------------------------------------------------------------------------
# Resume helper
# ---------------------------------------------------------------------------


def load_completed_pairs(output_path: str) -> set[tuple[int, str]]:
    """Return set of (passage_id, model) pairs already in the output file."""
    p = Path(output_path)
    if not p.exists():
        return set()
    try:
        done = pd.read_csv(p)
        return set(zip(done["passage_id"], done["model"]))
    except Exception:
        return set()


# ---------------------------------------------------------------------------
# Check Ollama is running
# ---------------------------------------------------------------------------


def check_ollama_running():
    try:
        r = requests.get("http://localhost:11434/api/tags", timeout=5)
        if r.status_code == 200:
            available = [m["name"] for m in r.json().get("models", [])]
            return available
    except requests.ConnectionError:
        pass
    return None


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    args = parse_args()

    # -- Validate Ollama is running ------------------------------------------
    available_models = check_ollama_running()
    if available_models is None:
        raise RuntimeError(
            "Cannot connect to Ollama at http://localhost:11434\n"
            "Make sure Ollama is running: ollama serve"
        )

    # -- Warn about any requested models not found ---------------------------
    for model in args.model:
        if not any(model in m for m in available_models):
            print(
                f"  [Warning] Model '{model}' not found in ollama list. "
                f"Run: ollama pull {model}"
            )

    # -- Load inputs ---------------------------------------------------------
    if not Path(args.input).exists():
        raise FileNotFoundError(f"Input CSV not found: {args.input}")
    if not Path(args.prompt).exists():
        raise FileNotFoundError(
            f"Prompt file not found: {args.prompt}\n"
            "Save your chain-of-thought prompt as prompt.md in the project root."
        )

    df = pd.read_csv(args.input)
    if "Passage" not in df.columns or "Grade Level" not in df.columns:
        raise ValueError(
            f"Expected columns 'Passage' and 'Grade Level' in {args.input}. "
            f"Found: {list(df.columns)}"
        )

    system_prompt = Path(args.prompt).read_text(encoding="utf-8")

    # -- Resume logic --------------------------------------------------------
    completed_pairs = load_completed_pairs(args.output) if args.resume else set()
    if completed_pairs:
        print(
            f"[Resume] Skipping {len(completed_pairs)} already-completed "
            f"passage-model combinations."
        )

    # -- Open output file ----------------------------------------------------
    output_path = Path(args.output)
    write_header = (not args.resume) or (not output_path.exists())
    fieldnames = [
        "passage_id",
        "true_grade",
        "model",
        "raw_response",
        "predicted_grade",
        "parse_error",
        "error_message",
        "duration_seconds",
    ]

    run_timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    total_calls = len(df) * len(args.model)

    print(f"\n{'=' * 60}")
    print(f"  Ollama Grading Run — {run_timestamp}")
    print(f"  Models : {', '.join(args.model)}")
    print(f"  Input  : {args.input}  ({len(df)} passages)")
    print(f"  Output : {args.output}")
    print(f"  Total  : {total_calls} API calls")
    print(f"{'=' * 60}\n")

    mode = "a" if args.resume else "w"
    with open(output_path, mode, newline="", encoding="utf-8") as fout:
        writer = csv.DictWriter(fout, fieldnames=fieldnames)
        if write_header:
            writer.writeheader()

        for model in args.model:
            print(f"\n--- Model: {model} ---\n")

            for idx, row in df.iterrows():
                passage_id = int(idx)
                true_grade = int(row["Grade Level"])
                passage_text = str(row["Passage"])

                if (passage_id, model) in completed_pairs:
                    continue

                print(
                    f"  [{passage_id + 1:02d}/{len(df)}] true_grade={true_grade} | "
                    f"{len(passage_text):,} chars … ",
                    end="",
                    flush=True,
                )

                record = {
                    "passage_id": passage_id,
                    "true_grade": true_grade,
                    "model": model,
                    "raw_response": "",
                    "predicted_grade": "",
                    "parse_error": False,
                    "error_message": "",
                    "duration_seconds": "",
                }

                try:
                    raw, duration = call_ollama(model, system_prompt, passage_text)
                    grade, parse_error = parse_grade(raw)

                    record.update(
                        {
                            "raw_response": raw,
                            "predicted_grade": grade if grade is not None else "",
                            "parse_error": parse_error,
                            "duration_seconds": round(duration, 3),
                        }
                    )

                    status = f"→ Grade {grade}" if not parse_error else "→ PARSE ERROR"
                    print(f"{status}  ({duration:.1f}s)")

                    if parse_error:
                        print(f"    [!] Could not parse grade from: {repr(raw[:200])}")

                except Exception as e:
                    record.update(
                        {
                            "parse_error": True,
                            "error_message": str(e),
                        }
                    )
                    print(f"→ ERROR: {e}")

                writer.writerow(record)
                fout.flush()

                time.sleep(REQUEST_DELAY)

    # -- Summary -------------------------------------------------------------
    results = pd.read_csv(output_path)
    print(f"\n{'=' * 60}")
    print(f"  Done.")
    for model in args.model:
        model_results = results[results["model"] == model]
        completed = model_results[model_results["error_message"] == ""]
        errors = model_results[model_results["error_message"] != ""]
        parse_err = model_results[model_results["parse_error"] == True]
        print(f"\n  {model}:")
        print(f"    Completed : {len(completed)}/{len(df)}")
        if len(errors):
            print(f"    API errors: {len(errors)} — rerun with --resume to retry")
        if len(parse_err):
            print(f"    Parse errs: {len(parse_err)} — check 'raw_response' column")
    print(f"\n  Output written to: {output_path.resolve()}")
    print(f"{'=' * 60}\n")


if __name__ == "__main__":
    main()
