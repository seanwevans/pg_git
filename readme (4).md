# pg_git

A PostgreSQL-native implementation of Git functionality.

## Directory Structure

```
pg_git/
├── Makefile
├── README.md
├── META.json
├── pg_git.control
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
│       ├── pg_git--0.1.0--0.2.0.sql  # Version 0.1.0 to 0.2.0
│       └── pg_git--0.2.0.sql         # Version 0.2.0 init
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
    ├── rules
    └── changelog
```

## Features

- Core Git operations (init, add, commit, log)
- Branching and merging
- Diff generation
- Reset operations
- Tag support
- Remote operations (clone, fetch, push, pull)

## Installation

```bash
make
make install
```

Then in PostgreSQL:
```sql
CREATE EXTENSION pg_git;
```

## Usage

```sql
-- Initialize repository
SELECT pg_git.init_repository('my_repo', '/path/to/repo');

-- Stage a file
SELECT pg_git.stage_file(1, 'file.txt', 'content'::bytea);

-- Create commit
SELECT pg_git.commit_index(1, 'author', 'Initial commit');

-- Create branch
SELECT pg_git.create_branch(1, 'feature');

-- View history
SELECT * FROM pg_git.get_log(1);
```

## Testing

```bash
make test
```

## License

PostgreSQL License