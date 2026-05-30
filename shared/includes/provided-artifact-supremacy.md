# Provided-Artifact Supremacy

**Purpose:** When the user hands you a design artifact — a prototype, a `HANDOFF.md`, a mockup, a spec doc, a screenshot/image, a Figma link, a reference URL, or any "match this / 1:1 / like the prototype" — **that artifact is the SOURCE OF TRUTH for WHAT to build.** The existing codebase tells you HOW to build it; it is NEVER grounds to override the design.

**Why this exists (2026-05-30 failure):** a `plan`+`execute` for a single-column editor dock was handed a complete prototype + `HANDOFF.md` that said *"one sliding dock... Do not regress to persistent side panels."* The plan header wrote **"HANDOFF.md is reference-only"**, then made a decision (*"R1: retain the left sidebar"*) grounded in the repo's existing structure — the exact opposite of the handoff. Three plan revisions + cross-model adversarial all passed it, because every reviewer checked the plan's *internal consistency*, not its *fidelity to the provided design*. Result: 5 hours building the wrong architecture correctly; output worse than before. The agent read the handoff but treated it as advisory and substituted its own repo reading — the cardinal sin this include forbids.

---

## 1. Detect (before any repo exploration)

A design artifact is "provided" if the user, this turn or earlier in the session, did ANY of:
- attached/uploaded or referenced a file or folder (`HANDOFF.md`, a downloaded prototype, a spec `.md`/`.docx`/`.pdf`, a design export);
- pasted/attached a screenshot, mockup, or image of the intended UI;
- linked a Figma/prototype/reference URL or named a page to "match";
- said "match this", "1:1", "pixel", "like the prototype/design", "they gave me the full design".

If ANY holds → this protocol is MANDATORY. If none → skip it (you are designing from scratch; the user's words are the brief).

## 2. Extract FIRST — read it IN FULL, not skim

Before exploring the codebase, **read the artifact end-to-end** and extract its hard constraints into a `## Design Constraints` checklist with IDs. Capture, verbatim where it matters:
- **Layout / structure** — panels, columns, docks, regions, what is where (e.g. "icon rail | one dock | canvas").
- **Interactions** — what each control does, navigation, state transitions.
- **Explicit do / don't** — every `do not`, `never`, `must`, `always`, `one`, `single`, `no <X>` is a HARD constraint. Quote it. (The 2026-05-30 miss was an un-extracted *"Do not regress to persistent side panels."*)
- **Visual specifics** that the user can verify (counts, order, spacing rules the design states).

```
## Design Constraints (source: <artifact>)
- DC-1 [layout] "<verbatim or precise paraphrase>"
- DC-2 [interaction] "..."
- DC-3 [DO-NOT] "Do not regress to persistent side panels." ← HARD
...
```

Skimming and extracting the wrong thing (the 2026-05-30 plan extracted only a "URL-selection assumption" and missed the single-dock mandate) is the failure. If the artifact is long, read all of it; do not stop at the first section that looks relevant.

## 2.5. If the artifact IS code — PORT it, do not re-derive it

If the provided artifact contains a **working implementation** (a prototype with `.jsx`/`.tsx`/`.vue`/`.svelte`/component files, a runnable demo, a code export — not just a `.md` or an image), the default is to **port that code 1:1** into the target stack, NOT to read its behavior in prose and hand-roll your own version. (2026-05-30, second instance: the prototype folder held real `app.jsx`/`sidebar.jsx`/`canvas.jsx`/`inspector.jsx`; the agent ignored them and built a worse re-derivation from the `HANDOFF.md` description — twice.)

- **First action: inventory the artifact's code files** (`find` for component/source files) and READ them. They are the ground truth for layout, structure, interactions, and styling — far more precise than any prose handoff.
- Port component-by-component: map each artifact component to a target-stack equivalent, preserving its structure, class names / tokens, and interaction wiring. Adapt only what the stack genuinely requires (e.g. React state → the repo's store; CSS modules → the repo's styling system).
- "Reinventing it from the handoff because the stack differs" is the failure. The stack difference is a porting task, not a reason to design fresh.
- Only when the artifact is *purely* prose/image (no code) do you design the implementation yourself — and even then §2–§4 bind you to its constraints.

## 3. Grounding inversion — the artifact wins on WHAT, the repo informs HOW

When repo reality and the artifact conflict:
- The artifact decides **what the result must be** (layout, behavior, the do/don'ts).
- The repo decides **how you implement it** (which store, which component, migration path).
- You may NEVER downgrade the artifact to "reference-only" because the current code is structured differently. "The repo already has a left sidebar hosting other modes" is a HOW problem to solve (move those modes), not a license to keep a panel the design forbids.

## 3.5. The artifact is NOT infallible — surface its gaps, don't blindly copy either

The artifact is the source of truth you may not **silently ignore** — but it is NOT always 100%. Prototypes ship with gaps, mistakes, dead states, placeholder data, accessibility holes, and details that collide with the real data model or backend. The rule is therefore **NO SILENT DIVERGENCE IN EITHER DIRECTION** — not "copy the prototype pixel-for-pixel no matter what":

- The original sin (2026-05-30) is silently substituting **your own** design for the artifact's. Forbidden.
- The opposite sin is silently "fixing" or improving the artifact with **your own** opinion. Also forbidden.
- When the artifact is **wrong / incomplete / ambiguous / impossible / conflicts with reality** (a state it never shows, a field the data model can't supply, a contrast/a11y failure, an obvious prototype bug), you do NOT blindly copy the mistake AND you do NOT quietly override it. You **surface it** with your proposed correction and get the user's call (§4). The prototype being authoritative means it's the default and the baseline — not that it's beyond question.

So: follow the artifact by default; flag where it's genuinely deficient; let the user decide. Both "I ignored your design" and "I copied a flaw in your design without telling you" are failures.

## 4. Deviation gate (surface + get a decision — do not silently diverge)

When a spec/plan decision would **differ from a Design Constraint** — whether because you'd rather do it another way OR because the constraint is wrong/incomplete/impossible — you do NOT proceed silently and you do NOT rationalize it from repo structure. Surface it and get a decision:

```
[DEVIATION] DC-3 says "Do not regress to persistent side panels", but I propose
keeping the left sidebar because <reason>. This differs from your design.
Confirm: (a) follow the design as-is, or (b) accept this deviation.
```
```
[ARTIFACT-GAP] DC-7 (the prototype) shows no empty/loading state for the tree, and
the real data model can return zero sections. I propose <X>. Confirm or adjust.
```

A **surfaced, user-approved** deviation recorded in the spec/plan is legitimate — that is the prototype not being 100%, handled honestly. The defect is a **SILENT** divergence in either direction (quietly substituting your design, or quietly copying/overriding a flaw). Reviewers FAIL only the silent ones.

## 5. Question prioritization

Clarifying questions cover **deviations from the provided design FIRST** — the places where your plan cannot or should not match it — before any generic gap. The load-bearing question is "your design shows X, the repo has Y — which wins here?", asked EARLY, not "how should I build the thing your prototype already specifies?", asked at the end. If the artifact already answers a question unambiguously, do NOT ask it — follow it.

## 6. Carry-through

The `## Design Constraints` checklist is copied into the spec (brainstorm) and the plan (plan), and is the contract the spec-reviewer / plan-reviewer grade **fidelity** against (not just internal consistency). Every architecture decision that touches a DC cites it (`per DC-1`). A plan that is internally perfect but contradicts a DC is a FAIL, not an APPROVE.
