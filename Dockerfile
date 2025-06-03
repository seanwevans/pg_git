FROM postgres:14

RUN apt-get update && apt-get install -y \
    build-essential \
    postgresql-server-dev-all \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /pg_git

COPY . .

RUN make && make install
