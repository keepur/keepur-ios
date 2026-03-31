# Quality Gate

Pre-PR validation pipeline. Runs three checks in sequence, stopping immediately on failure.

## Trigger

Run `/quality-gate` before creating a PR. Must pass before `dodi-dev:review` and `dodi-dev:submit`.

## Pipeline

### Step 1: Swift Compliance

**Run:** `/swift-compliance`

Validates architecture layering, concurrency safety, SwiftData hygiene, WebSocket protocol consistency, and file organization against project rules.

**On failure:** STOP. Developer must fix violations and re-run from the top.
**On pass:** Proceed to step 2.

### Step 2: Test Creation

**Run:** `/create-tests`

Analyzes changed files, generates unit/UI tests, runs them, fixes failures, commits passing tests.

**On no code changes or docs-only:** Skip with "no tests needed."
**On completion:** Proceed to step 3.

### Step 3: Pre-Submit Testing

**Run:** `/pre-submit-testing`

Builds the project, runs the full test suite (unit + UI), fixes failures along the way.

**On failure:** STOP. Developer must fix test failures before creating PR.
**On pass:** Report success.

## Final Report

```
## Quality Gate Results

**Branch:** <branch-name>

### 1. Swift Compliance
[PASS/FAIL] — N files checked, summary

### 2. Test Creation
[PASS/SKIP] — Created N unit tests, N UI tests
(or: No new tests needed for these changes)

### 3. Test Suite
[PASS/FAIL] — Build: OK, Unit: N/N, UI: N/N

**Ready for PR:** [YES/NO] — proceed with `dodi-dev:review` then `dodi-dev:submit`
```

## Notes

- **Sequencing is strict.** Each step runs only if the previous step passed.
- **Re-running is safe.** All steps are idempotent.
- **No code changes?** If the branch has only docs, specs, or asset changes, skip all steps and report "no code changes to gate."
- **Self-healing.** Test creation and pre-submit testing include fix loops — they attempt to resolve test failures automatically before reporting failure.
