# BARQ DevOps Internship Task

## Overview

This repository contains a containerized Flask application deployed with:

* NGINX as the public reverse proxy
* Two Flask application instances
* PostgreSQL for persistent application data
* Redis for application counters
* Docker Compose for local orchestration

The public application endpoint is:

```text
http://127.0.0.1:8080
```

The application uses two Docker networks:

* `frontend` — connects NGINX to the application instances
* `backend` — connects the application instances to PostgreSQL and Redis

PostgreSQL and Redis are not exposed directly on host ports.

## Prerequisites

The following tools are required:

* Linux or WSL2
* Python 3.12
* Git
* Docker
* Docker Compose

Verify the installation:

```bash
python3 --version
git --version
docker version
docker compose version
```

## Setup

Clone the repository and enter the project directory:

```bash
git clone https://github.com/mennakamel25/BARQ-DevOps-Internship.git
cd BARQ-DevOps-Internship
```

Create the local environment file from the provided example:

```bash
cp .env.example .env
```

Do not commit `.env`. It is ignored by Git and is intended for local configuration only.

Verify the repository state:

```bash
git status
```

## Build

Validate the resolved Docker Compose configuration:

```bash
docker compose -p barq-assessment config -q
```

Build the application image:

```bash
docker compose -p barq-assessment build
```

## Start

Start the complete environment in detached mode:

```bash
docker compose -p barq-assessment up -d
```

Check the service status:

```bash
docker compose -p barq-assessment ps
```

The environment contains:

```text
app-01
app-02
nginx
postgres
redis
```

View all service logs:

```bash
docker compose -p barq-assessment logs --no-color
```

Follow NGINX logs:

```bash
docker compose -p barq-assessment logs -f nginx
```

## Health and Readiness

Check the public health endpoint:

```bash
curl -fsS http://127.0.0.1:8080/health
```

Check application and dependency readiness:

```bash
curl -fsS http://127.0.0.1:8080/ready
```

A successful `/ready` response confirms that the application can reach both PostgreSQL and Redis.

Check the running containers and their health status:

```bash
docker compose -p barq-assessment ps
```

## Tests

### Application Unit Tests

Create and activate a Python virtual environment:

```bash
python3 -m venv .venv
source .venv/bin/activate
```

Install the application dependencies:

```bash
python -m pip install -r requirements.txt
```

Run the application unit tests:

```bash
python -m unittest discover -s tests -v
```

### Environment Validation

Run the environment validator:

```bash
python3 validate.py
```

The validator checks:

* Public access through NGINX
* Application endpoints
* PostgreSQL readiness
* Redis readiness
* Required containers
* Host port isolation
* Docker network isolation

A successful validation ends with:

```text
Validation result: PASS
```

The validator exits with a non-zero status when a required validation check fails.

### Docker Compose Validation

Validate the Compose configuration:

```bash
docker compose -p barq-assessment config -q
```

The command must complete successfully.

## Failure and Recovery Test

The failure/recovery test verifies that the application remains available when one backend instance is stopped and that the stopped instance can recover and serve traffic again.

Run:

```bash
python3 failure_test.py
```

The test performs the following sequence:

1. Verify baseline application health.
2. Generate baseline traffic.
3. Stop `app-01`.
4. Generate traffic while `app-01` is unavailable.
5. Verify that the stopped instance does not serve traffic.
6. Measure successful requests and errors during the failure.
7. Start `app-01` again.
8. Wait for recovery.
9. Generate recovery traffic.
10. Verify that `app-01` serves successful requests through NGINX.

A successful test ends with:

```text
Failure/recovery test: PASS
```

The test uses bounded request and recovery timeouts and exits with a non-zero status when the recovery requirements are not met.

## Backup

Create a PostgreSQL backup using the provided script:

```bash
./backup.sh
```

The script creates a timestamped PostgreSQL custom-format dump under:

```text
backups/
```

Example:

```text
backups/postgres_YYYYMMDD_HHMMSS.dump
```

List available backups:

```bash
ls -lh backups/
```

Backups are local evidence files and must not be committed to Git.

## Restore

The restore script accepts a PostgreSQL backup file:

```bash
./restore.sh backups/<backup-file>.dump
```

For example:

```bash
./restore.sh backups/postgres_YYYYMMDD_HHMMSS.dump
```

The restore operation uses `pg_restore` against the `barq_tasks` database.

The backup was also independently restored into a temporary PostgreSQL database during verification to prove that the dump contains recoverable application data.

## Persistence Verification

The PostgreSQL data is stored in the named Docker volume:

```text
postgres-data
```

A persistence test can be performed by:

1. Creating a record through the API.
2. Recreating the application and PostgreSQL containers without removing volumes.
3. Querying the API again.
4. Verifying that the previously created record still exists.

Recreate the application and PostgreSQL containers while preserving volumes:

```bash
docker compose -p barq-assessment up -d --force-recreate app-01 app-02 postgres
```

Verify the environment:

```bash
docker compose -p barq-assessment ps
```

Then verify the record through the API:

```bash
curl -fsS http://127.0.0.1:8080/records
```

Do not use `--volumes` during persistence testing.

## Stop

Stop the environment without removing persistent volumes:

```bash
docker compose -p barq-assessment down
```

Start it again when required:

```bash
docker compose -p barq-assessment up -d
```

## Cleanup

For normal lab cleanup:

```bash
docker compose -p barq-assessment down
```

Do not use:

```bash
docker compose -p barq-assessment down -v
```

when testing PostgreSQL persistence.

Avoid global Docker cleanup commands such as:

```bash
docker system prune
```

because they can remove resources outside this project.

## CI

GitHub Actions is configured in:

```text
.github/workflows/ci.yml
```

The workflow runs on:

* Pushes
* Pull requests

The CI pipeline performs:

1. Repository checkout
2. Python syntax checks
3. Docker Compose configuration validation
4. Application image build
5. Environment startup
6. Readiness wait
7. Environment validation
8. Cleanup

Run locally before pushing:

```bash
python3 -m py_compile app/server.py validate.py failure_test.py
docker compose -p barq-assessment config -q
python3 validate.py
```

A green CI run proves that the checked workflow successfully built the environment, reached readiness, and passed the automated validation in the CI environment.

A green CI run does not by itself prove production availability, high availability, disaster recovery, external monitoring, or infrastructure-level resilience.

## Known Failure and Recovery Behavior

NGINX is the single public entry point and distributes requests between `app-01` and `app-02`.

When one backend becomes unavailable, NGINX can retry eligible upstream failures against the other application instance.

The failure test verifies this behavior by stopping `app-01`, measuring traffic during the failure, restoring the container, and verifying that the recovered instance serves requests again.

## Documentation

Additional investigation and design evidence is documented in:

* [`troubleshooting.md`](troubleshooting.md) — investigation journal, failed attempts, fixes and retests
* [`log_analysis.md`](log_analysis.md) — historical log analysis and correlated evidence
* [`decisions.md`](decisions.md) — implementation decisions, alternatives, trade-offs and limitations
* [`security_review.md`](security_review.md) — security risks and improvements
* [`AI_USAGE.md`](AI_USAGE.md) — AI-assisted work and verification
* [`docs/EVIDENCE_INDEX.md`](docs/EVIDENCE_INDEX.md) — evidence index
* [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — architecture documentation
