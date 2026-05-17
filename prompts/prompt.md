# Task

Analyze the provided text passage and determine its most appropriate reading grade level for students in Grades 3 through 8. Work through each step internally. Output only the final grade level.

---

# Input Specification

The input will be a reading passage from a standardized assessment dataset. Accept any of the following input forms without rejection:

- **Continuous prose** of any length. Passages in this dataset typically range from 125 to 1,100 words; do not treat length alone as grounds to decline analysis.
- **Poetry or verse.** Analyze qualitatively only; skip the FK formula (it is not valid for non-prose) and note this in your internal reasoning.
- **Prose with embedded glossary entries** in the format `word = definition`. Treat these as part of the passage. Do not count glossary lines as sentences when estimating ASL.
- **Prose with internal section headings.** Treat headings as structural markers; include them when assessing structural complexity (Dimension 4) but exclude them from sentence-length calculations.

**Data quality issues — handle as follows:**
- If the passage begins with LLM-generated meta-text (e.g., "Here are the passages extracted from…", "I have removed line numbers…", "Note: the file truncated…"), strip that preamble mentally before analysis. Begin analysis at the first sentence of actual passage content.
- If the entry contains two or more clearly labeled, self-contained passages (e.g., "Passage 1: … Passage 2: …"), analyze the first complete passage only and note that the entry contained multiple passages.

There is no minimum or maximum length requirement. If a passage is shorter than ~150 words, note that the quantitative estimates will have higher uncertainty due to small sample size.

---

# Internal Analysis (do not output — reasoning only)

## Step 1 — Quantitative Approximation

If the passage is prose, estimate average sentence length (ASL) and average syllables per word (ASW) from a representative sample of 20–30 words. Apply:

`FK ≈ 0.39 × ASL + 11.8 × ASW − 15.59`

Treat the result as a surface-level signal only. FK does not capture meaning, prior knowledge demands, or thematic difficulty.

**Exclude from FK calculation:** glossary lines (`word = definition`), section headings, and any stripped meta-text preamble.

If the passage is poetry or verse, skip FK entirely. Proceed to Step 2.

---

## Step 2 — Vocabulary Analysis

Identify 4–6 words from the passage that are likely to challenge a target-grade reader. Classify each word using the following tiers:

- **Tier 2:** High-utility academic words that appear across disciplines (e.g., *analyze*, *conclude*, *significant*). These are the most important for instruction.
- **Tier 3:** Domain-specific technical terms limited to a particular field (e.g., *photosynthesis*, *legislature*, *isosceles*). These add difficulty but are often defined in context.

For each identified word, briefly note whether it is defined or supported in context (including by the inline glossary), or whether a reader must bring external knowledge to it.

---

## Step 3 — Qualitative Dimension Scoring

Rate the passage on each of the four dimensions below. Use the anchored scale provided. Do not produce a single holistic judgment — score each dimension independently.

---

**Dimension 1: Syntactic Complexity**
How complex is the sentence structure?

| Score | Description |
|-------|-------------|
| 1–2 | Simple and compound sentences predominate; clear subject-verb-object structure; minimal embedding |
| 3–4 | Mix of simple, compound, and some complex sentences; occasional subordinate clauses |
| 5–6 | Frequent complex and compound-complex sentences; multiple layers of embedding; passive constructions |

**Dimension 2: Language Abstractness**
How much does the text rely on non-literal language?

| Score | Description |
|-------|-------------|
| 1–2 | Predominantly literal and explicit; minimal figurative language; direct statements |
| 3–4 | Some figurative language (similes, mild metaphors); occasional implied meaning or subtext |
| 5–6 | Extended metaphors, irony, or abstraction; meaning frequently requires inferential processing |

**Dimension 3: Knowledge Demands**
How much prior knowledge must the reader supply?

| Score | Description |
|-------|-------------|
| 1–2 | Self-contained; familiar everyday topics; no specialized background required |
| 3–4 | Assumes some familiarity with the topic area; a few concepts not explained in context |
| 5–6 | Requires significant prior content knowledge or cultural context; key concepts assumed, not taught |

**Dimension 4: Structural Complexity**
How easy is the text to navigate and follow?

| Score | Description |
|-------|-------------|
| 1–2 | Linear narrative or argument; clear topic sentences; predictable organizational pattern |
| 3–4 | Generally clear structure with some deviation; mild non-linear elements |
| 5–6 | Multiple perspectives, non-linear structure, or complex argument requiring active reconstruction |

---

## Step 4 — Grade Band Determination

### 4A. Map Scores to Grade Bands

| Dimension Score | Grade Band |
|----------------|------------|
| 1–2 | Grade 3–4 |
| 3–4 | Grade 5–6 |
| 5–6 | Grade 7–8 |

### 4B. Resolve Cross-Dimension Conflict

- **All four dimensions agree:** Assign that grade band. Confidence: High.
- **Three of four agree:** Assign the majority band. Note the dissenting dimension. Confidence: Moderate-High.
- **Two-two split:** Assign the *higher* of the two bands (conservative default). Confidence: Moderate.
- **One dimension is an outlier:** Assign the band supported by three dimensions; note whether the outlier reflects a local feature or a global property.

### 4C. Integrate FK Estimate

Compare the FK grade estimate (if computed) to the qualitative band. If they diverge by two or more grade levels, determine whether FK is inflated by Tier 3 jargon or suppressed by short but abstract sentences, and adjust reasoning accordingly.

---

## Step 5 — Sensitivity Analysis

Mentally test three perturbations:

1. **Sentence removal:** If the single most complex sentence were removed, would any dimension score change? Would the grade band change?
2. **Vocabulary neutralization:** If Tier 3 vocabulary were replaced with common synonyms, would the grade band change? If yes, flag as jargon-dependent.
3. **Passage consistency:** Is the complexity level consistent throughout, or concentrated in one section?

---

# Output

Return exactly one line in this format:

**Reading Level: Grade [X]**

Use the midpoint grade of the assigned band (e.g., Grade 5 for a Grade 5–6 band, Grade 7 for a Grade 7–8 band, Grade 3 for a Grade 3–4 band).

Do not include any explanation, reasoning, or additional text, with two exceptions:
- If the passage begins with LLM meta-text that was stripped before analysis, prepend one line: `[Note: preamble stripped before analysis]`
- If the entry contained multiple labeled passages and only the first was analyzed, prepend one line: `[Note: multiple passages detected; analyzed Passage 1 only]`

