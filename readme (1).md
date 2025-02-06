# pg_git

PostgreSQL-native Git implementation.

## Features

### Core Operations
- Repository initialization and cloning
- File staging and committing
- Branching and merging with conflict resolution
- History viewing and diffing
- Reset and restore operations

### Advanced Features
- Tag support
- Remote operations with HTTPS transport
- Stash management
- Worktree support
- Notes
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
├── sql/
│   ├── schema/
│   ├── functions/
│   └── updates/
├── test/
└── debian/
```

## Installation
```bash
make && make install

# In PostgreSQL:
CREATE EXTENSION pg_git;
```

## Development
```bash
docker-compose up -d
docker-compose exec db psql -U postgres
docker-compose run test
```

## Usage Examples
```sql
-- Initialize
SELECT pg_git.init_repository('repo', '/path');

-- Basic operations
SELECT pg_git.stage_file(1, 'file.txt', 'content'::bytea);
SELECT pg_git.commit_index(1, 'author', 'message');
SELECT pg_git.create_branch(1, 'feature');

-- Advanced features
SELECT pg_git.stash_save(1, 'WIP changes');
SELECT pg_git.blame(1, 'file.txt');
SELECT pg_git.grep(1, 'pattern');

-- Maintenance
SELECT pg_git.gc(1);
SELECT pg_git.verify_integrity(1);
```

## Documentation
Complete documentation available at: [docs/index.md](docs/index.md)

## License
PostgreSQL License