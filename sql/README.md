# `sql/` layout and composition

This directory contains extension SQL for `pg_git` and is split into composable layers.

## File roles

- **Install script**
  - `pg_git--0.4.0.sql`: extension install entrypoint for version `0.4.0`.
- **Upgrade scripts** (generated)
  - `pg_git--0.1.0--0.2.0.sql`, `pg_git--0.2.0--0.3.0.sql`, `pg_git--0.3.0--0.4.0.sql`.
  - PostgreSQL discovers these by filename alone: `ALTER EXTENSION pg_git UPDATE`
    looks for `pg_git--<from>--<to>.sql` in the extension directory and will not
    find a script stored under any other name. They are also listed in `DATA` so
    `make install` copies them; an upgrade script that is not installed is an
    upgrade path that does not exist.
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
  - `pg_git--<from>--<to>.sql` for upgrade scripts. These two patterns are fixed
    by PostgreSQL, not by convention.
  - `pgit-*.sql` for top-level feature modules.
  - zero-padded numeric prefixes for ordered fragments under `functions/` and `schema/`.
- Generated files (`pg_git--*.sql`) are assembled by the makefile from the
  fragments and committed. Edit the fragments and re-run `make`; do not hand-edit
  a generated file.

## Load order assumptions

Install/compose flow is:

1. `pg_git--0.4.0.sql` creates/ensures schema context.
2. `schema/*.sql` fragments initialize base relational structures.
3. `functions/*.sql` numbered fragments load core command primitives.
4. `pgit-*.sql` feature modules extend with higher-level command families.

Because top-level modules depend on base objects, loading order is significant and should remain deterministic.

## Version attribution

The makefile assigns every install fragment to the version that introduced it
(`V0_1_0_PARTS` ... `V0_4_0_PARTS`). A fresh install of version N is the
concatenation of every list up to and including N, and the upgrade script for
`N-1 -> N` is exactly the list for N. Because both paths are generated from the
same fragments they cannot drift apart.

`make check-parts` asserts that those lists partition `INSTALL_PARTS` exactly,
so a new fragment added to the install but not attributed to a version fails the
build rather than silently going missing for anyone who upgrades.

## Packaging strategy (`makefile` `DATA`)

`DATA` is limited to the artifacts PostgreSQL loads directly:

- the install entrypoint `pg_git--$(EXTVERSION).sql`;
- every `pg_git--<from>--<to>.sql` upgrade script.

The fragments under `sql/schema/`, `sql/functions/` and `sql/pgit-*.sql` are
build inputs, not install artifacts, and are not copied into the extension
directory.

Two files in `sql/` are excluded from the build entirely:

- `pgit-ci.sql`
- `pgit-control.sql`

These are documentation/config snapshots rather than extension SQL.
