# pg_git

A PostgreSQL-native implementation of Git functionality.

## Features

- Core Git operations (init, add, commit, log)
- Branching and merging with conflict resolution
- Diff generation
- Reset operations
- Tag support
- Remote operations with HTTPS transport
- Schema migrations
- Repository maintenance (GC, integrity checks, optimization)

## Directory Structure

```
pg_git/
├── Makefile
├── README.md
├── META.json
├── pg_git.control
├── docker-compose.yml
├── Dockerfile
├── .dockerignore
├── sql/
│   ├── schema/
│   │   └── 001-core.sql           # Core tables
│   ├── functions/
│   │   ├── 001-init.sql          # Repository initialization
│   │   ├── 002-add.sql           # Staging operations
│   │   ├── 003-commit.sql        # Commit operations
│   │   ├── 004-log.sql           # History viewing
│   │   ├── 005-status.sql        # Working tree status
│   │   ├── 006-branch.sql        # Branch operations
│   │   ├── 007-merge.sql         # Merge operations
│   │   ├── 008-diff.sql          # Diff operations
│   │   ├── 009-reset.sql         # Reset operations
│   │   ├── 010-tag.sql           # Tag operations
│   │   ├── 011-remote.sql        # Remote operations
│   │   ├── 012-migrations.sql    # Schema migrations
│   │   ├── 013-merge-conflicts.sql # Conflict resolution
│   │   ├── 014-https.sql         # HTTPS transport
│   │   └── 015-admin.sql         # Admin functions
│   └── updates/
│       ├── pg_git--0.1.0--0.2.0.sql
│       ├── pg_git--0.2.0--0.3.0.sql
│       └── pg_git--0.3.0.sql
└── test/
    └── sql/
        └── [test files...]

## Development Environment

```bash
# Start the environment
docker-compose up -d

# Access psql
docker-compose exec db psql -U postgres

# Run tests
docker-compose run test
```

## Installation

```bash
make && make install

# In PostgreSQL:
CREATE EXTENSION pg_git;
```

## Usage Examples

```sql
-- Initialize repository
SELECT pg_git.init_repository('my_repo', '/path/to/repo');

-- Stage and commit
SELECT pg_git.stage_file(1, 'file.txt', 'content'::bytea);
SELECT pg_git.commit_index(1, 'author', 'Initial commit');

-- Branch operations
SELECT pg_git.create_branch(1, 'feature');
SELECT pg_git.merge_branches(1, 'feature', 'main');

-- Remote operations with HTTPS
SELECT pg_git.store_credentials(1, 'github.com', 'username', 'token');
SELECT pg_git.clone('https://github.com/org/repo.git', 'local_name', '/path');

-- Maintenance
SELECT pg_git.gc(1, aggressive := true);
SELECT pg_git.verify_integrity(1);
SELECT pg_git.optimize_indexes(1);
```

## License

PostgreSQL License