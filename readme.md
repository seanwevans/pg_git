# pg_git

A PostgreSQL-native Git implementation.

## Features

### Core Operations
- Core Git operations (init, add, commit, log)
- Branching and merging
- Diff generation
- Reset operations
- Tag support
- Remote operations (clone, fetch, push, pull)
- Repository initialization and cloning
- File staging and committing
- Branching and merging with conflict resolution
- History viewing and diffing
- Reset and restore operations
- Schema migrations
- Repository maintenance (GC, integrity checks, optimization)
- Notes

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

### Plumbing Commands
- cat-file
- hash-object
- ls-tree
- merge-base
- rev-list
- and more...

## Directory Structure
```
pg_git/
 ├── makefile
 ├── README.md
 ├── META.json
 ├── pg_git.control
 ├── docker-compose.yml
 ├── Dockerfile
 ├── .dockerignore
 ├── sql/
 │    ├── schema/
 │    │    └── 001-core.sql             # Core tables
 │    └── functions/
 │         ├── 001-init.sql             # Repository initialization
 │         ├── 002-add.sql              # Staging operations
 │         ├── 003-commit.sql           # Commit operations
 │         ├── 004-log.sql              # History viewing
 │         ├── 005-status.sql           # Working tree status
 │         ├── 006-branch.sql           # Branch operations
 │         ├── 007-merge.sql            # Merge operations
 │         ├── 008-diff.sql             # Diff operations
 │         ├── 009-reset.sql            # Reset operations
 │         ├── 010-tag.sql              # Tag operations
 │         ├── 011-remote.sql           # Remote operations
 │         ├── 012-migrations.sql       # Schema migrations
 │         ├── 013-merge-conflicts.sql  # Conflict resolution
 │         ├── 014-https.sql            # HTTPS transport
 │         ├── 015-admin.sql            # Admin functions
 │         ├── 016-bundle.sql
 │         ├── 017-version.sql
 │         ├── 018-update.sql
 │         ├── 019-diagnose.sql
 │         ├── 020-verify-tag.sql
 │         ├── 021-version-updates.sql
 │         ├── 022-control.sql
 │         ├── 023-rerere.sql
 │         ├── 024-replace.sql
 │         ├── 025-tests.sql
 │         ├── 026-version-updates.sql
 │         ├── 027-ci
 │         ├── 028-advanced-commands.sql
 │         ├── 029-plumbing.sql
 │         ├── 030-extras.sql
 │         ├── 031-archive.sql
 │         ├── 032-submodule.sql
 │         ├── 033-sparse.sql
 │         ├── 034-merge-tree.sql
 │         ├── 035-verify-commit.sql
 │         ├── 036-whatchanged.sql
 │         ├── 037-instaweb.sql
 │         ├── 038-pack-refs.sql
 │         └── 039-repack.sql
 └── test/
      └── sql/
           ├── init.sql                 # Test initialization
           ├── add_test.sql             # Add/stage tests
           ├── commit_test.sql          # Commit tests
           ├── branch_test.sql          # Branch operation tests
           ├── merge_test.sql           # Merge operation tests
          └── remote_test.sql          # Remote operation tests
```

The `pg_git.control` file provides PostgreSQL with metadata about the
extension and instructs it to load `sql/pg_git--0.4.0.sql` when the
extension is created. Both the control file and the SQL script are
installed by `make install`.

## Dependencies
- PostgreSQL 12+
- PL/pgSQL
- pgcrypto
- pg_trgm

## Installation
```bash
make && make install

# In PostgreSQL:
CREATE EXTENSION pgcrypto;
CREATE EXTENSION pg_trgm;
CREATE EXTENSION pg_git;
# Alternatively, from the command line:
# psql -d yourdb -c "CREATE EXTENSION pg_git;"
```

## Testing

```bash
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

-- Stage a file
SELECT pg_git.stage_file(1, 'file.txt', 'content'::bytea);

-- Commit
SELECT pg_git.commit_index(1, 'author', 'Your commit message here');

-- Commit verification
SELECT pg_git.verify_commit(1, 'commit_hash');

-- Branch creation
SELECT pg_git.create_branch(1, 'feature');

-- Merge Branch
SELECT pg_git.merge_branches(1, 'feature', 'main');

-- Remote operations with HTTPS
-- Set encryption key for storing credentials
ALTER SYSTEM SET pg_git.credential_key = 'my_secret';
SELECT pg_reload_conf();
SELECT pg_git.store_credentials(1, 'github.com', 'username', 'token');
-- `http_fetch` uses Python to perform the actual HTTPS request

-- Garbage collection
SELECT pg_git.gc(1, aggressive := true);

-- Integrity verification
SELECT pg_git.verify_integrity(1);

-- Index optimization
SELECT pg_git.optimize_indexes(1);

-- View history
SELECT * FROM pg_git.get_log(1);

-- Submodule support
SELECT pg_git.submodule_add(1, 'https://repo.git', 'modules/lib');

-- Sparse Checkout
SELECT pg_git.sparse_checkout_set(1, ARRAY['src/*', 'docs/*']);

-- Maintenance
SELECT pg_git.pack_refs(1, true);
SELECT pg_git.repack(1, true);

-- Stash
SELECT pg_git.stash_save(1, 'WIP changes');

-- Blame
SELECT pg_git.blame(1, 'file.txt');

-- Grep
SELECT pg_git.grep(1, 'pattern');
```

## Version
Current: 0.4.0

## License
See [LICENSE](LICENSE) for the full text of the PostgreSQL License.

