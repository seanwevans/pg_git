# pg_git
<img width="256" alt="pg_git" src="https://github.com/user-attachments/assets/ac2cde34-f51e-4f19-8c4b-28383ffedf30" />

A PostgreSQL-native Git implementation.

## Features

> **Implemented vs Planned**
> - ✅ **Implemented**: Backed by concrete SQL functions in `sql/functions/*.sql`.
> - 🧭 **Planned / Aspirational**: Mentioned for roadmap/completeness, but not currently exported as callable functions.

### Core Operations (Implemented)
- Repository initialization (`init_repository`)
- File staging (`stage_file`, `unstage_file`)
- Commit creation (`commit_index`)
- Commit history and status (`get_log`, `get_decorated_log`, `get_status`, `get_formatted_status`)
- Branch management (`create_branch`, `list_branches`, `checkout_branch`)
- Merge primitives (`find_merge_base`, `can_fast_forward`, `merge_branches`)
- Diff operations (`diff_text`, `diff_blobs`, `diff_commits`)
- Reset operations (`reset_soft`, `reset_mixed`, `reset_file`)
- Tag operations (`create_tag`, `list_tags`)
- Remote operations (`add_remote`, `fetch_remote`, `push`, `pull`, `clone`)

### Advanced Operations
- Submodule support
- Sparse checkout for large repositories
- Archive creation
- GPG signature verification for commits and tags
- Reuse recorded resolution (rerere)
- Repository diagnostics
- Whatchanged view
- Instaweb interface
- Pack and repack support
- Object replacement
- Remote operations with HTTPS transport (uses `plpython3u`)
- Stash management
- Worktree support
- Bisect debugging
- Blame tracking
- Cherry-pick and revert
- Grep functionality

### Administrative
- Garbage collection
- File system check
- Reflog
- Repository maintenance
- Schema migrations
- Pack refs optimization
- ✅ HTTPS transport and credential storage (`store_credentials`, `http_fetch`)
- ✅ Merge conflict detection (`detect_conflicts`)
- 🧭 Submodule support
- 🧭 Sparse checkout for large repositories
- 🧭 Archive creation
- 🧭 GPG signature verification for commits and tags
- 🧭 Reuse recorded resolution (rerere)
- 🧭 Repository diagnostics / whatchanged view / instaweb interface
- 🧭 Pack and repack support
- 🧭 Object replacement
- 🧭 Stash management
- 🧭 Worktree support
- 🧭 Bisect debugging
- 🧭 Blame tracking
- 🧭 Cherry-pick and revert
- 🧭 Grep functionality

### Administrative (Implemented)
- Schema migration helpers (`get_current_schema_version`, `run_migration`)
- Garbage collection (`gc`)
- Repository integrity checks (`verify_integrity`)
- Index maintenance / optimization (`optimize_indexes`)

### Plumbing Commands
- ✅ Tree/index plumbing: `create_tree_from_index`
- 🧭 Additional low-level commands (`cat-file`, `hash-object`, `ls-tree`, `rev-list`, and more)

---

The `pg_git.control` file provides PostgreSQL with metadata about the
extension and instructs it to load `sql/pg_git--0.4.0.sql` when the
extension is created. Both the control file and the SQL script are
installed by `make install`.

## Dependencies

### Required (extension install/runtime)
- PostgreSQL 12+
- PL/pgSQL (`plpgsql`)
- `pgcrypto`
- `pg_trgm`
- `plpython3u`

### Optional (feature usage)
- None currently. All listed dependencies are required to install `pg_git` as shipped.

> **Why `plpython3u` is required:** the extension defines HTTPS helper functions (for example `pg_git.http_fetch`) in `LANGUAGE plpython3u`. That means `plpython3u` must be present when `CREATE EXTENSION pg_git` runs. In practice, only HTTPS-related features use those functions directly.

## Installation
```bash
make && make install

# In PostgreSQL:
CREATE EXTENSION plpython3u;
CREATE EXTENSION pgcrypto;
CREATE EXTENSION pg_trgm;
CREATE EXTENSION pg_git;

# Alternatively, from the command line:
# psql -d yourdb -c "CREATE EXTENSION plpython3u; CREATE EXTENSION pgcrypto; CREATE EXTENSION pg_trgm; CREATE EXTENSION pg_git;"
```

## Testing

The authoritative test execution order is defined in `test/sql/manifest.txt`.
`make test` reads that manifest, runs tests in the listed order, and enforces a guard
that every `test/sql/*_test.sql` file is present in the manifest.

```bash
# Optional overrides for your local PostgreSQL connection used by pg_prove:
# PGHOST=localhost PGPORT=5432 PGUSER=postgres PGDATABASE=postgres
make test
```

## Development
Using Docker:
```bash
# Start the development environment
docker-compose up -d

# Access psql console
docker-compose exec db psql -U postgres

# Run tests
docker-compose run test

```

## Usage

```sql

-- Initialize repository
SELECT pg_git.init_repository('my_repository', '/path/to/repo');

-- Clone repository
SELECT pg_git.clone('https://github.com/org/repo.git', 'local_name', '/path');

-- Stage / unstage files
SELECT pg_git.stage_file(1, 'file.txt', 'content'::bytea);
SELECT pg_git.unstage_file(1, 'file.txt');

-- Commit
SELECT pg_git.commit_index(1, 'author', 'Your commit message here');

-- Branch creation and checkout
SELECT pg_git.create_branch(1, 'feature');
SELECT pg_git.checkout_branch(1, 'feature');

-- Merge Branch
SELECT pg_git.merge_branches(1, 'feature', 'main');

-- Remote operations with HTTPS
-- Set encryption key for storing credentials
ALTER SYSTEM SET pg_git.credential_key = 'my_secret';
SELECT pg_reload_conf();
SELECT pg_git.store_credentials(1, 'github.com', 'username', 'token');
-- `http_fetch` uses Python to perform the actual HTTPS request

-- Garbage collection
SELECT * FROM pg_git.gc(1);

-- Integrity verification
SELECT * FROM pg_git.verify_integrity(1);

-- Index optimization
SELECT * FROM pg_git.optimize_indexes(1);

-- View history
SELECT * FROM pg_git.get_log(1);

-- Tagging
SELECT pg_git.create_tag(1, 'v1.0.0');
SELECT * FROM pg_git.list_tags(1);
```

## Version
Current: 0.4.0

## License
See [LICENSE](LICENSE) for the full text of the PostgreSQL License.
