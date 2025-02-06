# pg_git

A PostgreSQL-native implementation of Git functionality.

## Directory Structure

```
pg_git/
├── Makefile
├── README.md
├── META.json
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
│   │   └── 011-remote.sql        # Remote operations
│   └── updates/
│       └── 001-to-002.sql        # Version upgrade scripts
├── test/
│   └── sql/
│       ├── init.sql              # Test initialization
│       ├── add_test.sql          # Add/stage tests
│       ├── commit_test.sql       # Commit tests
│       ├── branch_test.sql       # Branch operation tests
│       ├── merge_test.sql        # Merge operation tests
│       └── remote_test.sql       # Remote operation tests
└── debian/                       # Packaging files
    ├── control
    ├── copyright
    └── changelog
```

## Features

- Core Git operations (init, add, commit, log)
- Branching and merging
- Diff generation
- Reset operations
- Tag support
- Remote operations (clone, fetch, push, pull)

## Dependencies

- PostgreSQL 12+
- PL/pgSQL

## Installation

```sql
CREATE EXTENSION pg_git;
```

## Usage Example

```sql
-- Initialize a repository
SELECT pg_git.init_repository('my_repo', '/path/to/repo');

-- Stage a file
SELECT pg_git.stage_file(repo_id, 'file.txt', 'content'::bytea);

-- Create a commit
SELECT pg_git.commit_index(repo_id, 'author', 'Initial commit');
```