# pg_git
<img width="256" alt="pg_git" src="https://github.com/user-attachments/assets/ac2cde34-f51e-4f19-8c4b-28383ffedf30" />

A PostgreSQL-native Git implementation.

## Features

> **Status markers** — every entry below carries one.
> - ✅ **Implemented**: exported by `sql/functions/*.sql` or `sql/pgit-*.sql`, and does the work in the database.
> - ⚠️ **Partial**: exported and callable, but a named part of it is a placeholder. The note says which part.
> - 🧭 **Planned / Aspirational**: mentioned for roadmap completeness, not exported as a callable function.

### Core Operations
- ✅ Repository initialization (`init_repository`)
- ✅ File staging (`stage_file`, `unstage_file`)
- ✅ Commit creation (`commit_index`)
- ✅ Commit history and status (`get_log`, `get_decorated_log`, `get_status`, `get_formatted_status`)
- ✅ Branch management (`create_branch`, `list_branches`, `checkout_branch`)
- ✅ Diff operations (`diff_text`, `diff_blobs`, `diff_commits`)
- ✅ Reset operations (`reset_soft`, `reset_mixed`, `reset_file`)
- ✅ Tag operations (`create_tag`, `list_tags`)
- ✅ Merge conflict detection (`can_auto_merge`, `detect_conflicts`)
- ⚠️ Merge (`find_merge_base`, `can_fast_forward`, `merge_branches`) — fast-forward only; `merge_branches` raises `Only fast-forward merges are currently supported` on a divergent history
- ⚠️ Remote operations (`add_remote`, `fetch_remote`, `pull`, `clone`, `push`) — `push` resolves the ref and raises a notice; it does not transfer objects to the remote

### Advanced Operations
- ✅ Stash management (`stash_save`, `stash_pop`)
- ✅ Worktree support (`add_worktree`)
- ✅ Commit notes (`add_note`)
- ✅ Blame tracking (`blame`)
- ✅ Bisect debugging (`bisect_start`, `bisect_good`, `bisect_bad`, `bisect_reset`)
- ✅ Cherry-pick and revert (`cherry_pick`, `revert`)
- ✅ Grep functionality (`grep`)
- ✅ Submodule support (`submodule_add`, `submodule_update`, `submodule_update_recursive`)
- ✅ Sparse checkout for large repositories (`sparse_checkout_set`, `sparse_checkout_add`, `is_path_in_sparse_checkout`, `get_tree_files`)
- ✅ Reuse recorded resolution / rerere (`record_resolution`, `find_resolution`, `clear_rerere_cache`)
- ✅ Tree-level merge (`merge_trees`)
- ✅ Whatchanged view (`whatchanged`)
- ✅ Repository diagnostics (`collect_diagnostics`, `get_diagnostic_report`)
- ✅ Object replacement (`replace`, `get_replaced_hash`, `remove_replace`, `list_replace`)
- ✅ Pack refs optimization (`pack_refs`, `unpack_refs`, `verify_packed_refs`)
- ✅ Repack support (`repack`, `unpack`)
- ✅ Bundles (`create_bundle`, `unbundle`)
- ✅ HTTPS transport and credential storage (`store_credentials`, `http_fetch`) — the only feature that needs `plpython3u`
- ⚠️ Archive creation (`create_archive`) — walks the tree and concatenates blob contents, but the tar/zip headers are placeholders, so the result is not a valid archive for `tar`/`unzip`
- ⚠️ GPG signature verification (`add_gpg_key`, `sign_commit`, `verify_commit`, `sign_tag`, `verify_tag`, `verify_all_tags`) — stores signatures and enforces key trust levels, but performs no cryptographic verification: any stored signature is reported valid
- ⚠️ Instaweb interface (`generate_repo_view`, `start_instaweb`, `stop_instaweb`) — renders repository HTML and records the listener config, but starts no web server; `start_instaweb` returns the URL it would serve on

### Administrative
- ✅ Schema migration helpers (`get_current_schema_version`, `run_migration`)
- ✅ Garbage collection (`gc`)
- ✅ Repository integrity checks (`verify_integrity`)
- ✅ Index maintenance / optimization (`optimize_indexes`)
- 🧭 Reflog
- 🧭 File system check (beyond what `verify_integrity` covers)

### Plumbing Commands
- ✅ Tree/index plumbing (`create_tree_from_index`)
- ✅ Object and history plumbing (`cat_file`, `hash_object`, `ls_tree`, `rev_list`, `merge_base`)

---

The `pg_git.control` file provides PostgreSQL with metadata about the
extension and instructs it to load `sql/pg_git--0.5.0.sql` when the
extension is created. Both the control file and the SQL script are
installed by `make install`. The install script is generated from the
modular fragments under `sql/schema/`, `sql/functions/` and `sql/pgit-*.sql`
(run `make` to regenerate it); editing it by hand is not recommended.

> **Schema name:** the extension installs its objects into the `pggit`
> schema (e.g. `pggit.init_repository(...)`). PostgreSQL reserves the
> `pg_` prefix for system schemas, so the schema cannot be named `pg_git`
> even though the extension itself is called `pg_git`.

## Dependencies

### Required (`pg_git`)
- PostgreSQL 12+
- PL/pgSQL (`plpgsql`)
- `pgcrypto`
- `pg_trgm`

All of these are trusted or built in, so `pg_git` installs on managed
PostgreSQL (RDS, Cloud SQL, Supabase, Neon) as well as on self-hosted servers.

### Required (`pg_git_https`, optional companion extension)
- `pg_git`
- `plpython3u`

> **Why HTTPS is a separate extension:** `pggit.http_fetch` is defined in
> `LANGUAGE plpython3u`, which is untrusted — it requires superuser and is not
> offered by managed PostgreSQL providers. Listing it in `pg_git`'s `requires`
> made the whole extension uninstallable there, so the HTTPS transport ships as
> `pg_git_https` instead. Everything else in `pg_git` is unaffected; install the
> companion only if you need HTTPS remotes.

## Installation
```bash
make && make install

# Core extension. CASCADE auto-installs pgcrypto and pg_trgm.
CREATE EXTENSION pg_git CASCADE;

# Optional: HTTPS transport. Needs plpython3u, so it requires a self-hosted
# server (or any provider that offers plpython3u).
CREATE EXTENSION pg_git_https CASCADE;

# Alternatively, from the command line:
# psql -d yourdb -c "CREATE EXTENSION pg_git CASCADE;"
```

### Upgrading from 0.4.0 or earlier
```sql
ALTER EXTENSION pg_git UPDATE;
```
The 0.4.0 -> 0.5.0 step releases `pggit.credentials`, `pggit.store_credentials`
and `pggit.http_fetch` from `pg_git` without dropping them, so stored
credentials are preserved. If you use HTTPS remotes, follow it with
`CREATE EXTENSION pg_git_https;` to bring those objects back under extension
management. If you do not, drop the three leftovers — the SQL is spelled out at
the top of `sql/pg_git--0.4.0--0.5.0.sql`.

## Testing

Test suites are split by speed and external dependencies:

- `test-core` (default): deterministic SQL tests for local logic. **Expected runtime:** ~10-30 seconds in Docker on a modern laptop. **Prerequisites:** running PostgreSQL test database.
- `test-integration` (opt-in): HTTPS transport checks in `test/sql/https_fetch_test.sql`. **Expected runtime:** ~30-90 seconds depending on network/container startup. **Prerequisites:** set `RUN_INTEGRATION=1`; `plpython3u` available so the test can install `pg_git_https`. The test serves its own endpoints on loopback, so no outbound network is needed.
- `test-performance` (opt-in): GC performance regression checks in `test/sql/gc_performance_test.sql`. **Expected runtime:** ~1-5+ minutes depending on machine load. **Prerequisites:** set `RUN_PERF=1`; stable CPU/IO for consistent measurements.
- `test-all`: runs `test-core` and then conditionally runs integration/performance suites when their flags are enabled.

In CI, `test-core` runs on every push and pull request. The HTTPS integration
suite additionally runs on any pull request that touches an HTTPS file, so
changes to the transport are exercised before they land rather than at the next
weekly run. The performance suite stays on the weekly schedule (and
`workflow_dispatch`), since it is slow and sensitive to runner load.

```bash
# Fast default suite (also what `make test` runs)
make test-core

# Explicitly include HTTPS/integration tests
RUN_INTEGRATION=1 make test-integration

# Explicitly include performance tests
RUN_PERF=1 make test-performance

# Run everything (slow suites run only when flags are set)
RUN_INTEGRATION=1 RUN_PERF=1 make test-all
```

## Development
Using Docker:
```bash
# Start the development environment
docker-compose up -d

# Access psql console
docker-compose exec db psql -U postgres -d pg_git_dev

# Run tests (includes the same preflight checks as local runs)
docker-compose run --rm test

```

## Usage

```sql

-- Initialize repository
SELECT pggit.init_repository('my_repository', '/path/to/repo');

-- Clone repository
SELECT pggit.clone('https://github.com/org/repo.git', 'local_name', '/path');

-- Stage / unstage files
SELECT pggit.stage_file(1, 'file.txt', 'content'::bytea);
SELECT pggit.unstage_file(1, 'file.txt');

-- Commit
SELECT pggit.commit_index(1, 'author', 'Your commit message here');

-- Branch creation and checkout
SELECT pggit.create_branch(1, 'feature');
SELECT pggit.checkout_branch(1, 'feature');

-- Merge Branch
SELECT pggit.merge_branches(1, 'feature', 'main');

-- Remote operations with HTTPS (requires: CREATE EXTENSION pg_git_https)
-- Set encryption key for storing credentials
ALTER SYSTEM SET pggit.credential_key = 'my_secret';
SELECT pg_reload_conf();
SELECT pggit.store_credentials(1, 'github.com', 'username', 'token');
-- `http_fetch` uses Python to perform the actual HTTPS request

-- Garbage collection
SELECT * FROM pggit.gc(1);

-- Integrity verification
SELECT * FROM pggit.verify_integrity(1);

-- Index optimization
SELECT * FROM pggit.optimize_indexes(1);

-- View history
SELECT * FROM pggit.get_log(1);

-- Tagging
SELECT pggit.create_tag(1, 'v1.0.0');
SELECT * FROM pggit.list_tags(1);
```

## Version
Current: `pg_git` 0.5.0, `pg_git_https` 0.1.0

## License
See [LICENSE](LICENSE) for the full text of the PostgreSQL License.
