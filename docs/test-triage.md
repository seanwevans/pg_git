# Test Triage Guide

This guide defines a consistent workflow for diagnosing and fixing SQL test failures.

## 1) Capture the first failing test

1. Run the full suite and stop at first failure in your notes:

   ```bash
   make test
   ```

2. Record the first failure only (file + failing assertion + error text). Triage starts from the earliest failure to avoid chasing follow-on noise.
3. Save the exact command output snippet in the issue/PR notes so others can reproduce quickly.

## 2) Rerun one SQL test file

Use focused reruns before changing more than one area:

```bash
make test-one TEST=test/sql/merge_test.sql
```

For repeated local debugging, use:

```bash
make test-one-verbose TEST=test/sql/merge_test.sql
```

This keeps the failure loop short while preserving the same test harness.

## 3) Classify failure type before fixing

Every failure should be assigned one primary type:

- **Logic bug**: SQL/function behavior is incorrect relative to expected assertions.
- **Migration drift**: schema or upgrade path mismatch between expected and installed DB objects.
- **Env/setup**: missing dependency, bad config, service availability, permissions, or test harness setup issue.
- **Nondeterminism**: ordering, timing, randomization, or external-state dependency causing flaky behavior.

If a failure appears multi-causal, mark the dominant root cause first and list secondary factors.

## 4) Required artifacts for each failing test

Each failure tracked in an issue or PR must include:

1. **Root-cause note**: short explanation of why it failed (not only symptoms).
2. **Fix commit**: commit hash that resolves the issue.
3. **Regression assertion**: a new or tightened assertion in the same SQL test file, or an adjacent test file when shared setup is required.

No failure is considered closed without all three artifacts.

## 5) Post-fix checklist (cross-test isolation)

After implementing a fix, verify no accidental cross-test state leakage:

- [ ] Any objects created by the test are cleaned up (tables, schemas, temp artifacts, roles where applicable).
- [ ] Test setup does not assume prior test side effects.
- [ ] Schema/search path expectations are explicitly reset when modified.
- [ ] Sequences/counters or mutable globals used by assertions are reset or namespaced.
- [ ] Focused rerun (`make test-one`) passes.
- [ ] Full suite (`make test`) passes after focused fix validation.

## 6) Known failures (temporary tracking)

Track recurring signatures here until fully resolved (remove entries once fixed and stable):

| Signature / error text | Likely class | Current status | Owner | Linked issue |
| --- | --- | --- | --- | --- |
| _Example: duplicate key value violates unique constraint on merge temp table_ | Nondeterminism | Investigating | @owner | #123 |

Rules:

- Keep signature text short and copy-pastable from failure output.
- Update status on every recurrence or mitigation attempt.
- Delete entry only after the fix is merged and no recurrence is observed in subsequent runs.
