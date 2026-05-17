"""
llm_grading.py
--------------
Sends each passage in GASS_Final_DS.csv through a structured chain-of-thought
grading prompt and records the model's predicted reading grade level.

Usage
-----
    # Set your API key first:
    export ANTHROPIC_API_KEY=sk-ant-...

    # Basic run (Claude only):
    python src/llm_grading.py

    # Specify input/output paths explicitly:
    python src/llm_grading.py \
        --input  data/input/GASS_Final_DS.csv \
        --prompt prompt.md \
        --output data/output/llm_results.csv

    # Resume a partial run (skips already-completed passage_ids):
    python src/llm_grading.py --resume

Dependencies
------------
    pip install anthropic pandas

Output
------
    llm_results.csv  — one row per passage, columns:
        passage_id          : 0-indexed row number from the input CSV
        true_grade          : ground-truth grade level from input CSV
        model               : model string returned by the API
        raw_response        : full text returned by the model (for auditing)
        predicted_grade     : integer parsed from the model's output line
        parse_error         : True if the response could not be parsed
        error_message       : API or parsing error text (empty string if none)
        duration_seconds    : wall-clock time for that API call
"""

from __future__ import annotations

import anthropic
import argparse
import csv
import os
import re
import time
from datetime import datetime
from pathlib import Path

import pandas as pd


# ---------------------------------------------------------------------------
# Configuration defaults
# ---------------------------------------------------------------------------

PROJECT_ROOT = Path(__file__).resolve().parents[1]

DEFAULT_INPUT = str(PROJECT_ROOT / "data/input/GASS_Final_DS.csv")
DEFAULT_PROMPT = str(PROJECT_ROOT / "prompts/prompt.md")
DEFAULT_OUTPUT = str(PROJECT_ROOT / "data/output/llm_results.csv")

MODEL = "claude-opus-4-5"
MAX_TOKENS = 100  # the prompt asks for a single short line
TEMPERATURE = 0.0  # deterministic — critical for reproducibility
REQUEST_DELAY = 1.0  # seconds between requests (rate-limit buffer)
MAX_RETRIES = 3  # retry on transient API errors
RETRY_BACKOFF = 5.0  # seconds to wait before first retry (doubles each time)


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------


def parse_args():
    parser = argparse.ArgumentParser(
        description="Grade reading passages via the Anthropic API."
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
        "--model", default=MODEL, help=f"Anthropic model string (default: {MODEL})"
    )
    parser.add_argument(
        "--resume",
        action="store_true",
        help="Skip passage_ids already present in the output file",
    )
    return parser.parse_args()


# ---------------------------------------------------------------------------
# Grade parsing
# ---------------------------------------------------------------------------

# Matches both "Reading Level: Grade 5" and (with note preamble) lines like
# "[Note: preamble stripped before analysis]\nReading Level: Grade 5"
GRADE_PATTERN = re.compile(r"Reading Level:\s*Grade\s*(\d+)", re.IGNORECASE)


def parse_grade(raw: str) -> tuple[int | None, bool]:
    """
    Returns (grade_int, parse_error).
    parse_error is True when the pattern was not found.
    """
    match = GRADE_PATTERN.search(raw)
    if match:
        return int(match.group(1)), False
    return None, True


# ---------------------------------------------------------------------------
# API call with retry logic
# ---------------------------------------------------------------------------


def call_api(
    client: anthropic.Anthropic,
    system_prompt: str,
    passage: str,
    model: str,
    max_retries: int = MAX_RETRIES,
    backoff: float = RETRY_BACKOFF,
) -> tuple[str, str, float]:
    """
    Returns (raw_response_text, model_string, duration_seconds).
    Raises on non-retryable errors after max_retries attempts.
    """
    attempt = 0
    while True:
        t0 = time.time()
        try:
            response = client.messages.create(
                model=model,
                max_tokens=MAX_TOKENS,
                temperature=TEMPERATURE,
                system=system_prompt,
                messages=[{"role": "user", "content": passage}],
            )
            duration = time.time() - t0
            raw = response.content[0].text.strip()
            return raw, response.model, duration

        except anthropic.RateLimitError as e:
            attempt += 1
            wait = backoff * (2 ** (attempt - 1))
            print(
                f"    [Rate limit] Waiting {wait:.0f}s before retry {attempt}/{max_retries}…"
            )
            if attempt >= max_retries:
                raise
            time.sleep(wait)

        except anthropic.APIStatusError as e:
            # 5xx errors are transient; 4xx (except rate limit) are not
            if e.status_code >= 500:
                attempt += 1
                wait = backoff * (2 ** (attempt - 1))
                print(
                    f"    [API {e.status_code}] Waiting {wait:.0f}s before retry {attempt}/{max_retries}…"
                )
                if attempt >= max_retries:
                    raise
                time.sleep(wait)
            else:
                raise


# ---------------------------------------------------------------------------
# Resume helper
# ---------------------------------------------------------------------------


def load_completed_ids(output_path: str) -> set[int]:
    """Return the set of passage_ids already written to the output file."""
    p = Path(output_path)
    if not p.exists():
        return set()
    try:
        done = pd.read_csv(p)
        return set(done["passage_id"].tolist())
    except Exception:
        return set()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    args = parse_args()

    # -- Validate environment ------------------------------------------------
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        raise EnvironmentError(
            "ANTHROPIC_API_KEY environment variable is not set.\n"
            "Run:  export ANTHROPIC_API_KEY=sk-ant-..."
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
    client = anthropic.Anthropic(api_key=api_key)

    # -- Resume logic --------------------------------------------------------
    completed_ids = load_completed_ids(args.output) if args.resume else set()
    if completed_ids:
        print(f"[Resume] Skipping {len(completed_ids)} already-completed passages.")

    # -- Open output file (append if resuming, write fresh otherwise) --------
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
    print(f"\n{'=' * 60}")
    print(f"  LLM Grading Run — {run_timestamp}")
    print(f"  Model  : {args.model}")
    print(f"  Input  : {args.input}  ({len(df)} passages)")
    print(f"  Output : {args.output}")
    print(f"{'=' * 60}\n")

    mode = "a" if args.resume else "w"
    with open(output_path, mode, newline="", encoding="utf-8") as fout:
        writer = csv.DictWriter(fout, fieldnames=fieldnames)
        if write_header:
            writer.writeheader()

        for idx, row in df.iterrows():
            passage_id = int(idx)
            true_grade = int(row["Grade Level"])
            passage_text = str(row["Passage"])

            if passage_id in completed_ids:
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
                "model": args.model,
                "raw_response": "",
                "predicted_grade": "",
                "parse_error": False,
                "error_message": "",
                "duration_seconds": "",
            }

            try:
                raw, model_str, duration = call_api(
                    client, system_prompt, passage_text, args.model
                )
                grade, parse_error = parse_grade(raw)

                record.update(
                    {
                        "model": model_str,
                        "raw_response": raw,
                        "predicted_grade": grade if grade is not None else "",
                        "parse_error": parse_error,
                        "duration_seconds": round(duration, 3),
                    }
                )

                status = f"→ Grade {grade}" if not parse_error else "→ PARSE ERROR"
                print(f"{status}  ({duration:.1f}s)")

                if parse_error:
                    print(f"    [!] Could not parse grade from: {repr(raw)}")

            except Exception as e:
                record.update(
                    {
                        "parse_error": True,
                        "error_message": str(e),
                    }
                )
                print(f"→ API ERROR: {e}")

            writer.writerow(record)
            fout.flush()  # write immediately so partial runs are recoverable

            time.sleep(REQUEST_DELAY)

    # -- Summary -------------------------------------------------------------
    results = pd.read_csv(output_path)
    completed = results[results["error_message"] == ""]
    errors = results[results["error_message"] != ""]
    parse_errs = results[results["parse_error"] == True]

    print(f"\n{'=' * 60}")
    print(f"  Done.")
    print(f"  Completed : {len(completed)}/{len(df)} passages")
    if len(errors):
        print(f"  API errors: {len(errors)} — rerun with --resume to retry")
    if len(parse_errs):
        print(f"  Parse errs: {len(parse_errs)} — check 'raw_response' column")
    print(f"  Output written to: {output_path.resolve()}")
    print(f"{'=' * 60}\n")


if __name__ == "__main__":
    main()
