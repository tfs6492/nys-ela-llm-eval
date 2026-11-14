"""
01-gemini-pred.py
-----------------
Evaluates reading passages using Google Gemini models (Gemini Flash, Gemini Thinking,
and Gemini Pro) via the Google GenAI REST API or google-genai SDK.

Features:
- Normalized schema support: reads `all_passages.csv` (or specific `passages_{YEAR}.csv`)
  and merges with `all_metadata.csv` (or `metadata_{YEAR}.csv`) to benchmark predictions
  against true ground truth grade levels.
- Supports both standard Flash mode and extended Thinking mode.
- Tracks token economics (input tokens, output tokens, thinking tokens), latency, and parsing integrity.
- Resumable: `--resume` skips already processed (passage_id, model) combinations.
- Test mode: `--limit N` tests a subset of passages before full run.

Usage:
------
    # Set your API key:
    export GEMINI_API_KEY="AIzaSy..."  (or set in .env file)

    # Run default pair (Flash & Thinking) on all passages:
    python src/modeling/01-gemini-pred.py

    # Test run on first 3 passages:
    python src/modeling/01-gemini-pred.py --limit 3

    # Run specific models:
    python src/modeling/01-gemini-pred.py --models gemini-2.5-flash gemini-2.5-flash-thinking gemini-3.1-pro
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import pandas as pd
import requests

# ---------------------------------------------------------------------------
# Project Paths & Defaults
# ---------------------------------------------------------------------------

PROJECT_ROOT = Path(__file__).resolve().parents[2]

DEFAULT_PASSAGES = PROJECT_ROOT / "data/input/all_passages.csv"
DEFAULT_METADATA = PROJECT_ROOT / "data/input/all_metadata.csv"
DEFAULT_PROMPT = PROJECT_ROOT / "prompts/prompt.md"
DEFAULT_OUTPUT = PROJECT_ROOT / "data/output/gemini_results.csv"

# Model presets
DEFAULT_MODELS = [
    "gemini-3.6-flash",           # High-speed Flash
    "gemini-3.6-thinking",        # Matched Thinking (thinking budget enabled)
]

GEMINI_API_BASE = "https://generativelanguage.googleapis.com/v1beta/models"


# ---------------------------------------------------------------------------
# API Key Resolution
# ---------------------------------------------------------------------------

def get_api_key() -> str:
    """Resolve Gemini API key from environment variables or .env file."""
    api_key = os.getenv("GEMINI_API_KEY") or os.getenv("GOOGLE_API_KEY")
    if api_key:
        return api_key.strip()

    # Check for .env in project root or current working dir
    env_paths = [PROJECT_ROOT / ".env", Path(".env")]
    for p in env_paths:
        if p.exists():
            with open(p, "r", encoding="utf-8-sig") as f:
                for line in f:
                    line = line.strip().lstrip("\ufeff")
                    if line.startswith("GEMINI_API_KEY=") or line.startswith("GOOGLE_API_KEY="):
                        val = line.split("=", 1)[1].strip().strip('"').strip("'")
                        if val:
                            return val

    raise ValueError(
        "Gemini API key not found. Please set GEMINI_API_KEY or GOOGLE_API_KEY in your "
        "environment or in a .env file."
    )


# ---------------------------------------------------------------------------
# Prompt & Input Loading
# ---------------------------------------------------------------------------

def load_prompt(prompt_path: Path) -> str:
    if not prompt_path.exists():
        raise FileNotFoundError(f"Prompt file not found at: {prompt_path}")
    return prompt_path.read_text(encoding="utf-8").strip()


def load_dataset(passages_path: Path, metadata_path: Optional[Path]) -> pd.DataFrame:
    if not passages_path.exists():
        raise FileNotFoundError(f"Passages CSV not found at: {passages_path}")

    df_p = pd.read_csv(passages_path, encoding="utf-8")
    if "passage_id" not in df_p.columns or "passage_text" not in df_p.columns:
        raise ValueError(f"Passages CSV must contain 'passage_id' and 'passage_text' columns.")

    if metadata_path and metadata_path.exists():
        df_m = pd.read_csv(metadata_path, encoding="utf-8")
        # Merge on passage_id to attach true_grade, year, title, word_count
        cols_to_use = [c for c in df_m.columns if c in ["passage_id", "grade", "year", "passage_title", "word_count"]]
        df = pd.merge(df_p, df_m[cols_to_use], on="passage_id", how="left")
        df.rename(columns={"grade": "true_grade"}, inplace=True)
    else:
        df = df_p.copy()
        df["true_grade"] = None

    return df


# ---------------------------------------------------------------------------
# Response Parsing
# ---------------------------------------------------------------------------

def parse_grade(raw_text: str) -> Tuple[Optional[int], bool]:
    """
    Parses the predicted grade from model output.
    Returns: (predicted_grade: Optional[int], parse_error: bool)
    """
    if not raw_text or not raw_text.strip():
        return None, True

    # Check for standard prompt output: Reading Level: Grade [X]
    m = re.search(r"Reading\s+Level:\s*Grade\s*(\d+)", raw_text, re.IGNORECASE)
    if m:
        return int(m.group(1)), False

    # Check for bold variant: **Reading Level: Grade [X]** or **Grade [X]**
    m_bold = re.search(r"Grade\s*(\d+)", raw_text, re.IGNORECASE)
    if m_bold:
        return int(m_bold.group(1)), False

    # Check for standalone integer if output is just the grade digit
    lines = [l.strip() for l in raw_text.splitlines() if l.strip()]
    if lines:
        last_line = lines[-1]
        digit_match = re.search(r"\b([3-8])\b", last_line)
        if digit_match:
            return int(digit_match.group(1)), False

    return None, True


# ---------------------------------------------------------------------------
# Gemini API Execution
# ---------------------------------------------------------------------------

def call_gemini_api(
    model: str,
    prompt: str,
    passage: str,
    api_key: str,
    temperature: float = 0.0,
    max_retries: int = 3,
    backoff: float = 5.0
) -> Dict:
    """
    Calls the Gemini API endpoint with error handling and retry logic.
    Supports thinking models by setting appropriate thinkingConfig.
    """
    # Determine base model name and whether thinking is enabled
    is_thinking_model = "thinking" in model.lower()
    
    # Map model aliases to Google API model IDs
    endpoint_map = {
        "gemini-3.6-flash": "gemini-3.6-flash",
        "gemini-3.6-thinking": "gemini-3.6-flash",
        "gemini-3.8-flash": "gemini-3.8-flash",
        "gemini-3.8-thinking": "gemini-3.8-flash",
        "gemini-3.1-pro": "gemini-3.1-pro-preview",
        "gemini-2.5-flash-thinking": "gemini-2.5-flash",
    }
    actual_model = endpoint_map.get(model.lower(), model.replace("-thinking", ""))

    url = f"{GEMINI_API_BASE}/{actual_model}:generateContent?key={api_key}"

    # Build prompt payload
    contents = [
        {
            "role": "user",
            "parts": [
                {
                    "text": (
                        f"{prompt}\n\n"
                        f"--- BEGIN PASSAGE ---\n"
                        f"{passage}\n"
                        f"--- END PASSAGE ---"
                    )
                }
            ]
        }
    ]

    gen_config: Dict = {
        "temperature": temperature,
        "maxOutputTokens": 2048 if is_thinking_model else 256,
    }

    if is_thinking_model:
        gen_config["thinkingConfig"] = {
            "thinkingBudget": 1024
        }
    else:
        # Turn off thinking tokens for pure Flash comparison if supported
        gen_config["thinkingConfig"] = {
            "thinkingBudget": 0
        }

    payload = {
        "contents": contents,
        "generationConfig": gen_config
    }

    headers = {"Content-Type": "application/json"}

    for attempt in range(1, max_retries + 1):
        start_time = time.time()
        try:
            resp = requests.post(url, headers=headers, json=payload, timeout=90)
            elapsed = time.time() - start_time

            if resp.status_code == 200:
                data = resp.json()
                candidates = data.get("candidates", [])
                if not candidates:
                    return {
                        "raw_response": "",
                        "prompt_tokens": 0,
                        "output_tokens": 0,
                        "thinking_tokens": 0,
                        "duration_seconds": elapsed,
                        "error_message": "Empty candidates returned by API"
                    }

                candidate = candidates[0]
                content = candidate.get("content", {})
                parts = content.get("parts", [])

                text_response = ""
                thinking_text = ""
                for part in parts:
                    if "text" in part:
                        text_response += part["text"]
                    if "thought" in part:
                        thinking_text += part["thought"]

                # Extract token usage metadata if provided
                usage = data.get("usageMetadata", {})
                prompt_tokens = usage.get("promptTokenCount", 0)
                output_tokens = usage.get("candidatesTokenCount", 0)
                thinking_tokens = usage.get("thoughtsTokenCount") or usage.get("thinkingTokenCount", len(thinking_text.split()))

                return {
                    "raw_response": text_response.strip(),
                    "prompt_tokens": prompt_tokens,
                    "output_tokens": output_tokens,
                    "thinking_tokens": thinking_tokens,
                    "duration_seconds": round(elapsed, 3),
                    "error_message": ""
                }

            elif resp.status_code in [429, 500, 503]:
                # Rate limit or transient error
                wait_time = backoff * (2 ** (attempt - 1))
                print(f"[WARN] API returned status {resp.status_code}. Retrying in {wait_time:.1f}s (attempt {attempt}/{max_retries})...")
                time.sleep(wait_time)
            else:
                err_text = resp.text[:300]
                return {
                    "raw_response": "",
                    "prompt_tokens": 0,
                    "output_tokens": 0,
                    "thinking_tokens": 0,
                    "duration_seconds": round(elapsed, 3),
                    "error_message": f"HTTP {resp.status_code}: {err_text}"
                }

        except requests.RequestException as e:
            elapsed = time.time() - start_time
            if attempt == max_retries:
                return {
                    "raw_response": "",
                    "prompt_tokens": 0,
                    "output_tokens": 0,
                    "thinking_tokens": 0,
                    "duration_seconds": round(elapsed, 3),
                    "error_message": f"Request exception: {str(e)}"
                }
            wait_time = backoff * (2 ** (attempt - 1))
            print(f"[WARN] Connection error: {e}. Retrying in {wait_time:.1f}s...")
            time.sleep(wait_time)

    return {
        "raw_response": "",
        "prompt_tokens": 0,
        "output_tokens": 0,
        "thinking_tokens": 0,
        "duration_seconds": 0.0,
        "error_message": "Exceeded maximum retry attempts"
    }


# ---------------------------------------------------------------------------
# Evaluation Pipeline Runner
# ---------------------------------------------------------------------------

def run_evaluation(
    passages_path: Path,
    metadata_path: Path,
    prompt_path: Path,
    output_path: Path,
    models: List[str],
    resume: bool = True,
    limit: Optional[int] = None,
    delay: float = 1.0
):
    api_key = get_api_key()
    prompt = load_prompt(prompt_path)
    df = load_dataset(passages_path, metadata_path)

    if limit and limit > 0:
        df = df.head(limit)
        print(f"[*] Running in sample mode: limited to first {limit} passages.")

    output_path.parent.mkdir(parents=True, exist_ok=True)

    # Load existing results if resuming
    completed_pairs = set()
    if resume and output_path.exists():
        try:
            df_existing = pd.read_csv(output_path)
            for _, r in df_existing.iterrows():
                completed_pairs.add((str(r["passage_id"]), str(r["model"])))
            print(f"[*] Resuming from {output_path}: found {len(completed_pairs)} existing evaluation records.")
        except Exception as e:
            print(f"[WARN] Could not parse existing results file for resume: {e}")

    # Prepare CSV fieldnames
    fieldnames = [
        "passage_id",
        "model",
        "model_type",
        "true_grade",
        "predicted_grade",
        "parse_error",
        "duration_seconds",
        "prompt_tokens",
        "output_tokens",
        "thinking_tokens",
        "raw_response",
        "error_message",
        "timestamp"
    ]

    write_header = not output_path.exists() or not resume

    print(f"\n==================================================================")
    print(f" Starting Gemini Evaluation Pipeline")
    print(f" Passages dataset: {passages_path.name} ({len(df)} passages)")
    print(f" Models to evaluate: {models}")
    print(f" Target output: {output_path}")
    print(f"==================================================================\n")

    with open(output_path, "a" if resume else "w", newline="", encoding="utf-8") as f_out:
        writer = csv.DictWriter(f_out, fieldnames=fieldnames)
        if write_header:
            writer.writeheader()
            f_out.flush()

        for m_idx, model in enumerate(models, 1):
            is_thinking = "thinking" in model.lower()
            m_type = "thinking" if is_thinking else "flash"
            print(f"\n[{m_idx}/{len(models)}] Running model: {model} (type: {m_type})")
            print("-" * 65)

            for p_idx, (_, row) in enumerate(df.iterrows(), 1):
                p_id = str(row["passage_id"])
                p_text = str(row["passage_text"])
                true_g = row.get("true_grade")

                # Skip if already completed
                if (p_id, model) in completed_pairs:
                    continue

                res = call_gemini_api(
                    model=model,
                    prompt=prompt,
                    passage=p_text,
                    api_key=api_key,
                    temperature=0.0
                )

                pred_grade, parse_err = parse_grade(res["raw_response"])

                record = {
                    "passage_id": p_id,
                    "model": model,
                    "model_type": m_type,
                    "true_grade": true_g,
                    "predicted_grade": pred_grade,
                    "parse_error": parse_err,
                    "duration_seconds": res["duration_seconds"],
                    "prompt_tokens": res["prompt_tokens"],
                    "output_tokens": res["output_tokens"],
                    "thinking_tokens": res["thinking_tokens"],
                    "raw_response": res["raw_response"],
                    "error_message": res["error_message"],
                    "timestamp": datetime.now(timezone.utc).isoformat()
                }

                writer.writerow(record)
                f_out.flush()
                completed_pairs.add((p_id, model))

                status_str = f"Pred: {pred_grade} | True: {true_g}" if not parse_err else "[PARSE ERROR]"
                err_str = f" (ERR: {res['error_message']})" if res["error_message"] else ""
                print(f"  [{p_idx}/{len(df)}] {p_id.ljust(18)} -> {status_str} in {res['duration_seconds']}s{err_str}")

                if delay > 0:
                    time.sleep(delay)

    print(f"\n[DONE] Evaluation completed. Results saved to: {output_path}")


# ---------------------------------------------------------------------------
# CLI Entry Point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Evaluate reading passages with Google Gemini models.")
    parser.add_argument("--passages", type=Path, default=DEFAULT_PASSAGES, help="Path to passages CSV")
    parser.add_argument("--metadata", type=Path, default=DEFAULT_METADATA, help="Path to metadata CSV")
    parser.add_argument("--prompt", type=Path, default=DEFAULT_PROMPT, help="Path to prompt markdown file")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="Path to output CSV")
    parser.add_argument("--models", nargs="+", default=DEFAULT_MODELS, help="List of Gemini model identifiers")
    parser.add_argument("--no-resume", action="store_true", help="Overwrite existing output instead of resuming")
    parser.add_argument("--limit", type=int, default=None, help="Limit to first N passages for test runs")
    parser.add_argument("--delay", type=float, default=0.5, help="Delay in seconds between API calls")

    args = parser.parse_args()

    run_evaluation(
        passages_path=args.passages,
        metadata_path=args.metadata,
        prompt_path=args.prompt,
        output_path=args.output,
        models=args.models,
        resume=not args.no_resume,
        limit=args.limit,
        delay=args.delay
    )


if __name__ == "__main__":
    main()
