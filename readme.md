# pg_git

PostgreSQL-native Git implementation.

## Features

### Core Operations
- Repository initialization and cloning
- File staging and committing
- Branching and merging with advanced conflict resolution
- History viewing and diffing
- Reset and restore operations

### Advanced Features
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

### Administrative
- Garbage collection
- File system check
- Reflog
- Repository maintenance
- Schema migrations
- Pack refs optimization

## Directory Structure
```
pg_git/
├── sql/
│   ├── schema/
│   │   └── 001-core.sql
│   ├── functions/
│   │   ├── 001-031-*.sql        # Core functionality
│   └── updates/
│       └── pg_git--*.sql        # Version updates
├── test/
└── debian/
```

## Installation
```bash
make && make install

# In PostgreSQL:
CREATE EXTENSION pg_git;
```

## Usage Examples
```sql
-- Basic operations
SELECT pg_git.init_repository('repo', '/path');
SELECT pg_git.stage_file(1, 'file.txt', 'content'::bytea);
SELECT pg_git.commit_index(1, 'author', 'message');

-- Advanced features
SELECT pg_git.submodule_add(1, 'https://repo.git', 'modules/lib');
SELECT pg_git.sparse_checkout_set(1, ARRAY['src/*', 'docs/*']);
SELECT pg_git.verify_commit(1, 'commit_hash');

-- Maintenance
SELECT pg_git.pack_refs(1, true);
SELECT pg_git.repack(1, true);
SELECT pg_git.gc(1);
```

## Development
```bash
docker-compose up -d
docker-compose exec db psql -U postgres
docker-compose run test
```

## Version
Current: 0.4.0

## License
PostgreSQL License