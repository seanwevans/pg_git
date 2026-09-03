FROM postgres:14

# postgresql-plpython3-14 is not needed by core pg_git; it is here so the
# opt-in HTTPS integration suite can install the pg_git_https extension.
RUN apt-get update && apt-get install -y \
    build-essential \
    postgresql-server-dev-14 \
    git \
    openssl \
    postgresql-14-pgtap \
    postgresql-plpython3-14 \
    libtap-parser-sourcehandler-pgtap-perl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /pg_git

COPY . .

RUN make PG_CONFIG=/usr/lib/postgresql/14/bin/pg_config && \
    make PG_CONFIG=/usr/lib/postgresql/14/bin/pg_config install
