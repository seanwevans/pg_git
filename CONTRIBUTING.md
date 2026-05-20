# Contributing

## Release Checklist

Before cutting a release, complete all of the following:

1. **Bump the extension version** in the relevant versioned SQL migration files (for example, creating the next `sql/pg_git--<new_version>.sql` as needed).
2. **Update `pg_git.control`** to reflect the new `default_version` and any related release metadata.
3. **Update `meta.json`** so package/version metadata matches the release.
4. **Verify versioned SQL file references** are consistent across repository metadata and install/upgrade paths.

## Test Checklist

When adding or changing functionality, ensure tests are updated:

1. **Add a new test file to `test/sql/`** and include it in the `TESTS` list in `makefile`.
2. **Follow naming conventions** for test files: use lowercase snake case and the `_test.sql` suffix (for example, `new_feature_test.sql`).
3. **Validate expected target behavior** with assertions that cover:
   - normal/success paths,
   - relevant edge cases,
   - error handling where applicable.

## Documentation Checklist

When SQL function signatures, behavior, or usage changes:

1. **Update README examples** to match current function signatures and output expectations.
2. **Confirm sample commands still run as written** and reflect current behavior.

## Dependency Checklist

When introducing, removing, or changing dependencies:

1. **Keep runtime prerequisites synchronized** across:
   - `README.md` setup requirements,
   - `meta.json` dependency metadata,
   - `pg_git.control` (where applicable),
   - any other install/release documentation.
2. **Verify dependency names and versions are consistent** in all docs and metadata files.
