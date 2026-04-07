# EqualFi Remediation Spec Steering

Purpose:
- give a `.kiro`-authoring agent a clear rule set for turning EqualFi remediation plans into `.kiro`-style spec docs
- prevent duplicate specs for the same root cause
- ensure spec boundaries follow implementation ownership rather than raw audit-report boundaries

This repository should be treated as **EqualFi**:
- `EdenFi` is only the local directory name
- use **EqualFi** in planning, specs, and implementation notes
- the basket product is **EDEN by EqualFi**

## Source Of Truth Hierarchy

Use these sources in this order:

1. `assets/remediation/EqualFi-unified-remediation-plan.md`
2. the normalized per-product remediation plans under `assets/remediation/`
3. the underlying reports in `assets/findings/`

The unified remediation plan is the portfolio-level source of truth.
The per-product remediation plans are implementation-detail notes.
The audit reports are evidence and regression targets, not the unit of spec ownership.

## Core Rule

Create **one `.kiro` spec per canonical remediation track**, not automatically:
- one spec per audit report
- one spec per findings file
- one spec per product module

Sometimes a current remediation plan already matches one coherent implementation track.
In that case, one plan can map directly to one `.kiro` spec.

Sometimes several remediation plans are really downstream expressions of one shared substrate fix.
In that case, write one shared `.kiro` spec and treat the product plans as downstream validation targets.

Sometimes one remediation plan contains multiple materially different implementation tracks.
In that case, split it into multiple `.kiro` specs.

## What A Spec Should Follow

A `.kiro` remediation spec should follow:
- implementation ownership
- code locality
- shared-library dependency order
- reusable regression coverage

A `.kiro` remediation spec should not follow:
- the exact numbering of one audit report
- whether the issue was first observed in a product facet or a library report
- whether a file happened to be grouped together in one remediation note

## Decision Rules

When deciding whether to create one spec or split/merge, use this checklist.

Create one spec when:
- the work lands mostly in one module or closely related module family
- the fixes share one state-machine or accounting invariant
- one bug-condition and preservation suite can validate most of the work
- the remediation plan already reads like one implementation backlog

Split into separate specs when:
- the plan mixes a narrow bug-fix set with a broader redesign
- one part is library-rooted and another is product-local
- the work would be implemented by different owners or in different phases
- the test strategy is materially different across the items

Merge into one shared spec when:
- multiple product findings are downstream symptoms of one shared library defect
- the same invariant fix closes several reports at once
- writing separate specs would duplicate requirements, design, and test work

## Canonical Track Mapping

Use the canonical track metadata already added to the remediation plans.

Current canonical tracks from `assets/remediation/EqualFi-unified-remediation-plan.md`:

- Track A. Native Asset Tracking and Transfer Symmetry
- Track B. ACI / Encumbrance / Debt Tracker Consistency
- Track C. Fee Routing, Backing Isolation, and Exotic Token Policy
- Track D. Payment Lifecycle and Delinquency State Machines
- Track E. EqualX AMM Correctness
- Track F. Options Lifecycle and Exerciseability
- Track G. EqualIndex Collateral and Mint/Burn Integrity
- Track H. Discovery, Storage Growth, and Registry Hygiene

Each new `.kiro` spec should state:
- which canonical track it implements
- which phase it belongs to
- which remediation plans it draws from
- which downstream reports/tests it is expected to close

## Practical Mapping Guidance

### Keep As-Is

The following kind of plan can usually stay as one `.kiro` spec:

- `EqualX-findings-1-5-remediation`
  - this already behaves like one coherent Track E implementation spec
  - keep using it as-is

Likely other one-plan-to-one-spec candidates:
- EqualScale lifecycle remediation
- EqualLend lifecycle remediation
- EqualIndex collateral-integrity remediation
- Options lifecycle-and-pricing remediation

### Likely Shared Specs

The following should usually become shared `.kiro` specs rather than product-by-product duplicates:

- native asset tracking and transfer symmetry
- ACI / encumbrance / debt tracker consistency
- user-count reconciliation if handled at the shared substrate layer
- fee-routing / backing-isolation cleanup
- registry / storage growth hygiene

### Likely Split Candidate

EDEN by EqualFi may need two layers:
- a near-term remediation spec for accepted tactical fixes
- a separate redesign spec if reward-backing isolation / rebasing support becomes architectural rather than incremental

Do not force both into one giant spec if that makes tasks fuzzy.

## Phasing Guidance

Generate specs in phase order unless there is already active execution underway.

### Phase 1. Shared Accounting Substrate

Prefer specs for:
- Track A
- Track B
- Track C

Reason:
- these fix assumptions used by multiple products
- downstream product specs should not bake in compensating logic if the shared substrate is still changing

### Phase 2. Product Lifecycle Fixes

Prefer specs for:
- Track D
- Track E
- Track F
- Track G

Reason:
- once shared invariants are clearer, product-local lifecycle fixes become safer to land

### Phase 3. Architectural Redesign and Hygiene

Prefer specs for:
- EDEN by EqualFi redesign work
- Track H
- governance/policy hardening that is not blocking immediate correctness

## What To Put In Each `.kiro` Spec

Each remediation spec should include:

- requirements
  - bug-condition requirements
  - preservation requirements
  - explicit non-goals where needed
- design
  - root cause
  - remediation direction
  - invariants being restored
  - dependencies on shared tracks
- tasks
  - tests first where practical
  - bug-condition regressions
  - preservation regressions
  - implementation steps
  - verification steps

Where possible, use the EqualX remediation spec structure as the model:
- write failing bug-condition tests first
- write preservation tests for behavior to keep
- implement fixes
- rerun the same tests

## Naming Guidance

Spec names should describe the implementation track, not the report file.

Good:
- `equalfi-native-tracking-remediation`
- `equalfi-aci-encumbrance-consistency`
- `equallend-payment-lifecycle-remediation`
- `options-lifecycle-and-pricing-remediation`

Acceptable when already active and coherent:
- `equalx-findings-1-5-remediation`

Avoid creating new names that are:
- just copied from one audit filename
- overly narrow if the implementation is shared
- overly broad if the work spans distinct redesign and bug-fix tracks

## Anti-Duplication Rules

Before generating a new spec:

1. Check the unified remediation plan.
2. Check whether a normalized remediation plan already maps the work to a canonical track.
3. Check whether an existing `.kiro` spec already owns that track.
4. Check whether the issue is really a downstream symptom of a shared library fix.

If yes, do one of these instead of creating a duplicate spec:
- extend the existing spec
- reference the shared track as a dependency
- add downstream regression tasks to the product spec

## Deliverable Expectation For The Spec-Writing Agent

When asked to generate `.kiro` docs from remediation plans, the agent should:

1. Identify the canonical track and phase.
2. Decide whether the work is:
   - one new spec
   - an extension to an existing spec
   - a split into multiple specs
3. Explain that decision briefly.
4. Generate `.kiro` docs that match implementation ownership.
5. Explicitly list:
   - source remediation plans used
   - dependencies on shared tracks
   - downstream reports/tests covered

## Current Recommendation

Use the normalized remediation plans as the working inputs, but generate `.kiro` specs according to canonical track ownership.

Today that means:
- keep `equalx-findings-1-5-remediation` active and unchanged in structure
- treat the unified remediation plan as the master roadmap
- create future specs in phase order, starting with shared substrate tracks where the work is genuinely cross-cutting

