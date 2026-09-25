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

---

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

---

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

---

## Build

Validate the resolved Docker Compose configuration:

```bash
docker compose -p barq-assessment config -q
```

Build the application image:

```bash
docker compose -p barq-assessment build
```

---

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

---

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

---

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

---

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

---

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

---

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

---

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

---

## Stop

Stop the environment without removing persistent volumes:

```bash
docker compose -p barq-assessment down
```

Start it again when required:

```bash
docker compose -p barq-assessment up -d
```

---

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

---

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

---

## Known Failure and Recovery Behavior

NGINX is the single public entry point and distributes requests between `app-01` and `app-02`.

When one backend becomes unavailable, NGINX can retry eligible upstream failures against the other application instance.

The failure test verifies this behavior by stopping `app-01`, measuring traffic during the failure, restoring the container, and verifying that the recovered instance serves requests again.

---

# Assessment Questions and Answers

## 1. What failed first? What proved the cause? Which failed attempt taught you something?

The first functional failure was observed during the backend failure test when `app-01` was stopped.

The initial NGINX configuration used:

```nginx
proxy_next_upstream off;
```

The failure test produced upstream errors while `app-01` was unavailable. NGINX logs showed connection and timeout failures against the stopped backend.

This provided evidence that the failure was related to upstream availability and retry behavior.

The initial failed test also showed that having two application instances alone was not sufficient. NGINX needed an appropriate upstream retry policy.

The configuration was changed to:

```nginx
proxy_next_upstream error timeout http_502 http_503 http_504;
```

The retest completed successfully:

```text
During failure: 20 success, 0 errors
Recovery traffic: 20 success, 0 errors
```

---

## 2. What patterns did the logs reveal? How did you avoid double-counting requests?

The historical logs showed several recurring patterns:

* Connection-refused errors
* Upstream timeouts
* `502`, `503`, and `504` responses
* Application-level `404` responses
* Requests that initially failed against one upstream and later succeeded against another

The analysis identified:

```text
720 unique request IDs
615 successful final responses
105 failed final responses
14.58% final failure rate
```

The logs were correlated using request IDs.

To avoid double-counting, each unique request ID was counted once using its final access-log status. Intermediate upstream attempts were treated as part of the same request.

For example:

```text
502 -> 200
```

was counted as **one request with a successful final result**, rather than two requests.

This distinction is important because an intermediate upstream failure does not necessarily mean that the client request ultimately failed.

---

## 3. How do requests flow? Why these ports, networks and readiness checks?

The request flow is:

```text
Client
  |
  | 127.0.0.1:8080
  v
NGINX :80
  |
  | frontend network
  v
app-01 / app-02 :8080
  |
  | backend network
  +------> PostgreSQL :5432
  |
  +------> Redis :6379
```

Only NGINX publishes a host port.

The host port `8080` is mapped to NGINX port `80`. The application containers listen on port `8080` internally and are not directly published to the host.

PostgreSQL uses port `5432` and Redis uses port `6379`. Both are reachable through the backend network and are not exposed through host port mappings.

The `frontend` network connects NGINX to the application instances, while the `backend` network connects the application instances to PostgreSQL and Redis.

The `/health` endpoint checks application health.

The `/ready` endpoint also verifies that the application can reach PostgreSQL and Redis.

This distinction is important because a running container does not necessarily mean that all required dependencies are ready to serve requests.

---

## 4. Why these timeouts, retries, restart settings and resource limits?

NGINX uses bounded upstream timeouts:

```nginx
proxy_connect_timeout 2s;
proxy_read_timeout 3s;
```

The connection timeout limits how long NGINX waits to establish a connection to an upstream. The read timeout prevents a request from waiting indefinitely for an upstream response.

NGINX also uses:

```nginx
proxy_next_upstream error timeout http_502 http_503 http_504;
```

This allows eligible upstream failures to be retried against another application instance.

The behavior was verified by stopping `app-01` and confirming that traffic continued successfully through `app-02`.

The application services use:

```yaml
restart: "no"
```

This is intentional for the assessment failure test. It allows the backend to remain stopped while failure behavior is tested instead of Docker automatically restarting it.

Resource limits are not claimed as implemented unless they are explicitly configured in the Compose file.

Arbitrary resource limits were not introduced without workload evidence because inappropriate CPU or memory limits could create artificial failures during the assessment.

For production, timeout, retry, restart, and resource-limit values should be based on measured workload, capacity requirements, and availability objectives.

---

## 5. When should validation fail? What does green CI prove, or not prove?

Validation should fail whenever a required part of the environment does not meet the expected contract.

This includes:

* Unavailable public access
* Failed application endpoints
* Unavailable PostgreSQL or Redis dependencies
* Missing required containers
* Unexpected host port exposure
* Incorrect network isolation

`validate.py` checks:

* Public access
* Application endpoints
* PostgreSQL readiness
* Redis readiness
* Required containers
* Host port isolation
* Network isolation

The validator is bounded by a timeout and exits with a non-zero status when a required check fails.

A green CI run proves that the configured CI checks passed in the CI environment.

In this assessment, CI validates Python syntax, Docker Compose configuration, image builds, environment startup, readiness, and the validation script.

Green CI does **not** prove:

* Production high availability
* Disaster recovery
* Real production performance
* External monitoring
* Multi-host resilience
* Off-host backup durability
* Resilience against every possible production failure

Therefore, CI results are evidence for the checks that were actually executed, not proof that the system is production-ready under all conditions.

---

## 6. Which single points of failure remain? How would you fix them in production?

The assessment environment still contains several potential single points of failure.

### NGINX

There is one NGINX instance acting as the public entry point.

If it fails, the application instances cannot be reached through the configured entry point.

**Production improvement:** use multiple ingress/load-balancer instances with a highly available load-balancing layer.

### Docker Host

The application, NGINX, PostgreSQL, and Redis currently run on the same host.

A host failure could therefore affect the entire environment.

**Production improvement:** distribute workloads across multiple hosts or cluster nodes.

### PostgreSQL

The assessment uses a single PostgreSQL instance.

**Production improvement:** use highly available managed PostgreSQL or a replicated PostgreSQL deployment with automated failover.

### Redis

The assessment uses a single Redis instance.

**Production improvement:** use a replicated or managed Redis deployment where the application's availability requirements require it.

### Backups

Assessment backups are stored locally.

**Production improvement:** store backups off-host with appropriate encryption, access controls, retention, and regular restore testing.

The implemented failure test only proves application-level failover from `app-01` to `app-02`. It does not prove high availability of NGINX, the Docker host, PostgreSQL, Redis, or local backup storage.

---

## 7. What would you improve? How did you verify AI-assisted work?

Potential production improvements include:

* Centralized secrets management
* Vulnerability scanning
* Image signing and SBOM generation
* Centralized logging and alerting
* External monitoring
* High availability across hosts
* Off-host encrypted backups
* Disaster recovery testing
* Additional container runtime hardening
* Production resource limits based on measured workload requirements

These are production improvements and are not claimed as implemented assessment features unless explicitly verified.

AI assistance was used for:

* Explanation
* Troubleshooting support
* Configuration review
* Documentation

AI suggestions were not treated as proof of correctness.

Changes were verified using actual commands and tests:

```bash
docker compose -p barq-assessment config -q
docker exec nginx nginx -t
python3 validate.py
python3 failure_test.py
./backup.sh
./restore.sh
git diff --check
```

The verification results included:

```text
Validation: PASS (10/10)
Failure/recovery test: PASS
CI: PASS
Backup/restore: successfully verified
```

This approach kept AI assistance as guidance and review while using actual command output, automated tests, and CI results as the evidence for the technical claims.

---

## Documentation

Additional investigation and design evidence is documented in:

* [`troubleshooting.md`](troubleshooting.md) — investigation journal, failed attempts, fixes, and retests
* [`log_analysis.md`](log_analysis.md) — historical log analysis and correlated evidence
* [`decisions.md`](decisions.md) — implementation decisions, alternatives, trade-offs, and limitations
* [`security_review.md`](security_review.md) — security risks and improvements
* [`AI_USAGE.md`](AI_USAGE.md) — AI-assisted work and verification
* [`docs/EVIDENCE_INDEX.md`](docs/EVIDENCE_INDEX.md) — evidence index
* [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — architecture documentation
