# Interactive MLM Tutorial: Fixed vs Random Effects
## Plan for Web-Based Interface

### Context
You want to build a locally-served, interactive web tutorial that helps clarify why random effects are preferable to fixed effects when you have many groups (classrooms) but few observations per group (students). The key confusion is around the **parameter trade-off**: fixed effects require one parameter per group, while random effects model group variation more parsimoniously.

The tutorial should use notation and framing from your course materials (de Leeuw & Meijer handbook, Lecture 4 on simulating multilevel data).

---

## Design Overview

### Core Learning Progression
The tutorial will follow your lecture's narrative arc:

1. **Discover the Problem** (Section 1)
   - Show raw scatter: study time vs test score (no group labels)
   - Ask: Is there a relationship between study time and scores?
   - User sees overall positive trend

2. **Reveal Group Structure** (Section 2)
   - Re-color same data by classroom
   - Ask: Does classroom assignment matter?
   - User discovers classrooms have different intercepts AND slopes
   - Animated transition makes the pattern clear

3. **The Fixed Effects Approach** (Section 3)
   - Show fitting separate regression line to each classroom
   - Display the fitted lines overlaid on data
   - **New**: Show uncertainty bands (confidence intervals) around each classroom-specific line
     - When few students per classroom: bands are very wide (estimates noisy)
     - This reveals the core problem: you don't have enough data to pin down each group's parameters reliably
   - Parameter count: 1 + 1 + J (global intercept + global slope + J group intercept adjustments)
     - For 9 classrooms: 11 parameters total

4. **The Random Effects Approach** (Section 4)
   - Same fitted lines, but generated differently (borrowing strength across classrooms)
   - Show the distribution assumption: intercepts ~ N(μ, τ²)
   - **Key insight**: Very narrow uncertainty bands around lines because each classroom's estimate is stabilized by information from other classrooms
   - Parameter count: 1 global intercept + 1 global slope + 2 variance components (σ² within-group, τ² between-group) = **4 parameters**
   - Visualization: overlay the estimated distribution N(μ, τ²) on the scatter of classroom intercepts

5. **The Trade-Off Explainer** (Section 5)
   - Side-by-side comparison table
   - **Fixed Effects**: Maximally flexible, no assumptions, but many parameters → unstable estimates with small groups
   - **Random Effects**: Fewer parameters, borrows strength across groups, but assumes groups from common distribution
   - Interactive slider: vary n_students per classroom → watch parameter counts change

6. **The Formal Notation** (Section 6)
   - Two-level MLM from textbook (equations 1.4a-b from de Leeuw & Meijer)
   - Show random intercept model explicitly:
     - y_ij = μ + β*study_time_ij + δ_j + ε_ij
     - δ_j ~ N(0, τ²), ε_ij ~ N(0, σ²)
   - Highlight: δ_j is the random classroom effect

---

## Interactive Components

### 1. Data Visualization Layers
**Reveal-on-click or animated transitions:**
- **Layer 1**: All points black, no classroom label → asks "is there a trend?"
- **Layer 2**: Points colored by classroom → asks "does grouping matter?"
- **Layer 3**: Add fitted regression line across all data (pooled model)
- **Layer 4**: Add classroom-specific fitted lines (fixed effects solution)
- **Layer 5**: Replace lines with random-effects fit (same visual, but derived differently)

**Interactive features:**
- Hover over a classroom to highlight its data points and fitted line
- Slider to fade between fixed effects lines and random effects distribution

### 2. Parameter Counter & Efficiency Comparison
**Visualization 1: Parameter count (varies only with J)**
- Display two "scorecards": Fixed Effects vs Random Effects
- Fixed Effects: 1 + 1 + J parameters (always grows with number of classrooms)
- Random Effects: 1 + 1 + 2 = **4 parameters** (constant regardless of J)
- For 9 classrooms: Fixed effects use 11 params, random effects use 4

**Visualization 2: Estimation Uncertainty (varies with both J and n)**
- **Most important interactive element**: Slider to vary students per classroom (n = 5, 10, 30, 100)
- As n decreases:
  - Fixed effects confidence bands widen dramatically (estimates become unreliable)
  - Random effects confidence bands stay relatively narrow (borrowing strength from other groups)
  - Visual effect: watch the fixed effects lines get "jittery" with small n
- Callout: "With 5 students per classroom, the fixed effects estimate for that classroom is very uncertain. Random effects borrows information from all classrooms to stabilize the estimate."

### 3. Distribution Visualization
Show the random effects assumption explicitly:
- Scatter plot of classroom intercepts (empirical)
- Overlay normal distribution curve (theoretical): N(μ, τ²)
- Shade the area under the curve
- Text: "Random effects assume classroom intercepts come from a common normal distribution"

### 4. Trade-Off Comparison Table
Side-by-side, with interactive explanations:

| Aspect | Fixed Effects | Random Effects |
|--------|---------------|-----------------|
| **Parameters** | 1 + 1 + J (grows with # groups) | 1 + 1 + 2 (constant) |
| **Flexibility** | High (each group free to differ) | Medium (groups share distribution) |
| **Assumptions** | None about groups; nonparametric | Groups drawn from N(μ, τ²) |
| **Estimation uncertainty** | Wide CI when n small per group | Narrow CI (borrows strength across groups) |
| **When to use** | Few groups, many obs/group | **Many groups, few obs/group** |
| **Borrowing strength?** | No—each group estimated alone | **Yes—uses all groups to estimate each group** |
| **Typical estimation** | OLS per group | REML, MLE, Bayes |

Clicking a row triggers a detailed explanation. **Key row highlighted**: "Estimation uncertainty"—this is where the pedagogical payoff is.

### 5. Collapsible Math Box
Hide-by-default notation section with the formal equations:
- Two-level MLM: y_ij = X_ij β + Z_ij δ_j + ε_ij
- Random intercept special case: y_ij = μ + β x_ij + δ_j + ε_ij
- Distributional assumptions for δ_j and ε_ij
- Use LaTeX/MathJax for pretty rendering

### 6. Interactive Slider: Group Size Sensitivity
**Pedagogical widget (CORE insight):**
- Horizontal slider: students per classroom (5 to 100)
- As you move the slider:
  - **Fixed effects**: confidence bands widen when n is small, narrow when n is large
    - At n=5: lines look very wiggly/unreliable
    - At n=100: lines are tight but still estimated independently
  - **Random effects**: confidence bands stay relatively stable across all n values
    - Borrowing strength keeps estimates stable even with few students per group
- Caption: "Notice: with only 5 students per classroom, the fixed effects estimate is very uncertain. Random effects stays stable by learning from all classrooms."

---

## Technical Architecture

### Frontend Stack
- **Framework**: React (component-based, good for interactive visualizations)
- **Plotting**: Plotly.js or D3.js (interactive scatter plots, overlaid lines, distributions)
- **Math rendering**: MathJax or KaTeX for LaTeX equations
- **Styling**: TailwindCSS or styled-components for clean, responsive UI
- **State management**: React hooks (useState for visualization layers, sliders)

### Data & Simulation
- **Simulated dataset**: Use the lecture example (9 classrooms, 30 students each)
  - Pre-compute: y_ij = 30 + 15*study_time_ij + δ_j + ε_ij
  - Classroom effects δ_j ~ N(0, τ² = 25)
  - Within-classroom noise ε_ij ~ N(0, σ² = 100)
  - Load as JSON; no backend needed
- **Fitted models**:
  - Pre-fit fixed-effects model (one OLS per classroom)
  - Pre-fit random-effects model (REML or Bayes in R, save estimates)
  - Store predictions and credible intervals

### Deliverable Structure
```
mlm-tutorial/
├── index.html
├── css/
│   └── main.css (or tailwind build)
├── js/
│   ├── app.js (React root)
│   ├── components/
│   │   ├── DataViz.jsx (main scatter + fitted lines)
│   │   ├── ParameterCounter.jsx (fixed vs random parameter counts)
│   │   ├── DistributionViz.jsx (normal distribution overlay)
│   │   ├── TradeOffTable.jsx (comparison table)
│   │   ├── MathBox.jsx (collapsible equations)
│   │   └── SliderControls.jsx (group size sensitivity)
│   ├── data/
│   │   ├── simulated_data.json (raw observations)
│   │   ├── fixed_effects_fits.json (OLS per classroom)
│   │   └── random_effects_fits.json (REML estimates)
│   └── utils/
│       ├── plot.js (Plotly configuration helpers)
│       └── math.js (parameter counting logic)
└── README.md
```

### Server
- Simple local HTTP server (e.g., Python `http.server`, Node `http-server`)
- No backend required; everything is client-side React + precomputed data

---

## Interactive Features (Priority Order)

### P1: Core Learning Path
1. ✅ Reveal-on-scroll or button-click: transition from pooled → fixed effects → random effects
2. ✅ Main scatter plot with overlaid fitted lines; hover to highlight classroom
3. ✅ Parameter counter for fixed vs random approaches
4. ✅ Slider to vary n_classrooms or n_students_per_classroom; watch parameter counts update

### P2: Intuition Builders
5. **Confidence interval visualization**: Show uncertainty bands around fixed and random effects lines; make them responsive to the slider so users see how they change with group size
6. Distribution visualization (empirical classroom intercepts + normal curve overlay showing the N(μ, τ²) assumption)
7. Trade-off comparison table with clickable explanations
8. Collapsible math box with formal equations (can hide if user prefers intuition-only)

### P3: Polish & Engagement
8. Smooth animations between visualization layers
9. Tooltips on hover (e.g., what is τ²? what is borrowing strength?)
10. Mobile-responsive layout

---

## Verification & Testing

### Golden Path (How to test the tutorial works)
1. **Start tutorial**: Load page, see pooled regression on all data
2. **Reveal structure**: Click "Reveal classroom colors" → data re-colors by classroom, visual pattern appears
3. **Fixed effects view**: Show 9 separate fitted lines with **confidence bands**
   - Verify: lines fit each classroom data
   - Verify: parameter counter shows 1 + 1 + 9 = 11 parameters
4. **Random effects view**: Show same fitted lines + narrower confidence bands + distribution overlay
   - Verify: lines visually similar to fixed effects (fitted values should be close)
   - Verify: parameter counter shows 1 + 1 + 2 = 4 parameters
5. **Adjust group size via slider**: Vary students per classroom (5 → 10 → 30 → 100)
   - At n=5: Fixed effects CI bands very wide (wiggly, unreliable); Random effects bands narrow (stable)
   - At n=100: Both sets of bands narrow, but fixed effects still estimated independently
   - **Key observation**: Random effects stays stable across all n values; fixed effects gets better as n increases
   - Verify: visual clearly shows the "borrowing strength" benefit of random effects
6. **Read explanations**: Click each row of trade-off table; verify detailed text appears
7. **See math** (optional): Expand math box; verify LaTeX renders correctly

### Browser Testing
- Test on Chrome, Firefox, Safari (latest 2 versions)
- Test responsiveness: desktop (1920×1080), tablet (768×1024), mobile (375×667)

---

## Notes & Assumptions

- **Data source**: Use simulated data matching your lecture (9 classrooms, 30 students). Can parameterize if needed.
- **Pre-fitted models**: Fit fixed and random effects models in R offline (using `lm()` per group and `lme4::lmer()` or `nlme::lme()`). Save point estimates and intervals as JSON.
- **No live fitting**: Don't fit models in the browser on-the-fly; too slow. Pre-compute everything.
- **Audience**: Students in your course who have seen Lecture 4; math box is optional/collapsible for those who want it.
- **Notation alignment**: Use your textbook's notation (y_ij, β, δ_j, τ², σ²) throughout.
