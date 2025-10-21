# pg_git
<img width="256" alt="pg_git" src="https://github.com/user-attachments/assets/ac2cde34-f51e-4f19-8c4b-28383ffedf30" />

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

---

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
SELECT pg_git.gc(1);

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

