# Path: .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        postgresql: [12, 13, 14, 15]

    services:
      postgres:
        image: postgres:${{ matrix.postgresql }}
        env:
          POSTGRES_PASSWORD: postgres
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    steps:
    - uses: actions/checkout@v3

    - name: Install PostgreSQL development files
      run: |
        sudo apt-get update
        sudo apt-get install postgresql-server-dev-${{ matrix.postgresql }}

    - name: Build
      run: make

    - name: Install extension
      run: sudo make install

    - name: Run tests
      run: |
        export PGPASSWORD=postgres
        make test

  package:
    needs: test
    runs-on: ubuntu-latest
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'

    steps:
    - uses: actions/checkout@v3

    - name: Build Debian package
      run: |
        sudo apt-get update
        sudo apt-get install devscripts debhelper postgresql-server-dev-all
        debuild -us -uc

    - name: Upload package artifact
      uses: actions/upload-artifact@v3
      with:
        name: debian-package
        path: ../postgresql-*-pg-git_*.deb

# Path: .gitlab-ci.yml
image: postgres:14

variables:
  POSTGRES_PASSWORD: postgres
  PGPASSWORD: postgres

stages:
  - build
  - test
  - package

build:
  stage: build
  script:
    - apt-get update
    - apt-get install -y make gcc postgresql-server-dev-14
    - make
  artifacts:
    paths:
      - ./*.so
      - ./sql/

test:
  stage: test
  script:
    - apt-get update
    - apt-get install -y make gcc postgresql-server-dev-14 pg-prove
    - make install
    - make test

package:
  stage: package
  script:
    - apt-get update
    - apt-get install -y devscripts debhelper postgresql-server-dev-all
    - debuild -us -uc
  artifacts:
    paths:
      - ../*.deb
  only:
    - main