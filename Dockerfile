# Path: Dockerfile
FROM postgres:14

RUN apt-get update && apt-get install -y \
    build-essential \
    postgresql-server-dev-14 \
    git \
    pg-prove \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /pg_git

COPY . .

RUN make && make install

# Path: docker-compose.yml
version: '3.8'

services:
  db:
    build: .
    environment:
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: pg_git_dev
    ports:
      - "5432:5432"
    volumes:
      - .:/pg_git
      - pg_data:/var/lib/postgresql/data

  test:
    build: .
    depends_on:
      - db
    environment:
      PGHOST: db
      PGUSER: postgres
      PGPASSWORD: postgres
      PGDATABASE: pg_git_dev
    command: make test

volumes:
  pg_data:

# Path: .dockerignore
.git
.github
.gitlab-ci.yml
debian/
*.deb
*.o
*.so