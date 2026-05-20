# `sql/` layout and composition

This directory contains extension SQL for `pg_git` and is split into composable layers.

## File roles

- **Install script**
  - `pg_git--0.4.0.sql`: extension install entrypoint for version `0.4.0`.
- **Upgrade scripts**
  - `pgit-version-updates.sql`: historical update fragments for `0.1.0 -> 0.2.0` plus legacy install notes.
  - `pgit-version-updates-0.2.0--0.3.0.sql`: upgrade path `0.2.0 -> 0.3.0`.
  - `pgit-version.sql`: upgrade path `0.3.0 -> 0.4.0`.
  - `pgit-update.sql`: legacy update helper content.
- **Feature modules** (`pgit-*.sql`)
  - Top-level modules such as `pgit-archive.sql`, `pgit-rerere.sql`, `pgit-submodule.sql`, etc.
  - These define optional/high-level command families and supporting objects.
- **Schema fragments** (`schema/*.sql`)
  - Foundational DDL loaded first.
- **Function fragments** (`functions/*.sql`)
  - Numbered, ordered function blocks loaded before feature modules.

## Naming conventions

- Canonical extension artifact naming uses:
  - `pg_git--<version>.sql` for extension install entrypoints.
  - `pgit-*.sql` for top-level feature/update modules.
  - zero-padded numeric prefixes for ordered fragments under `functions/` and `schema/`.
- This pass normalizes one legacy outlier:
  - `version-updates.sql` -> `pgit-version-updates-0.2.0--0.3.0.sql`.

## Load order assumptions

Install/compose flow is:

1. `pg_git--0.4.0.sql` creates/ensures schema context.
2. `schema/*.sql` fragments initialize base relational structures.
3. `functions/*.sql` numbered fragments load core command primitives.
4. `pgit-*.sql` feature modules extend with higher-level command families.
5. Version update modules are included for compatibility/upgrade composition.

Because top-level modules depend on base objects, loading order is significant and should remain deterministic.

## Packaging strategy (`makefile` `DATA`)

`DATA` is intentionally limited to installable SQL assets:

- top-level SQL entrypoints/modules in `sql/*.sql`;
- schema fragments in `sql/schema/*.sql`;
- function fragments in `sql/functions/*.sql`.

Two non-install artifacts in `sql/` are excluded from `DATA`:

- `pgit-ci.sql`
- `pgit-control.sql`

These are documentation/config snapshots rather than extension install scripts.
