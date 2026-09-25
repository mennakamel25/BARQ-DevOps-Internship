# Engineering Decisions

This document records the main implementation decisions made during the BARQ DevOps assessment.

Each decision includes the reason for the choice, assumptions, alternatives, trade-offs, and limitations.

The document distinguishes between changes implemented in the assessment environment and improvements that would be considered for production.

---

## Decision 1 — Use NGINX as the Single Public Entry Point

### Decision

Expose only NGINX to the host and route application traffic through it.

The public endpoint is:

```text
http://127.0.0.1:8080
```

NGINX listens on container port `80` and forwards requests to:

```text
app-01:8080
app-02:8080
```

### Why

Using a single public entry point provides a controlled boundary between the host and the application instances.

It also allows the two application instances to remain behind the reverse proxy instead of exposing their ports directly.

### Assumptions

* NGINX can reach both application containers through the `frontend` network.
* Both application instances expose the same application interface.
* Local port `8080` is available for the assessment environment.

### Alternative

Expose `app-01` and `app-02` directly on separate host ports.

### Trade-offs

**Benefits:**

* One public endpoint
* Centralized request routing
* Backend containers do not need host port mappings
* NGINX can perform upstream retry/failover

**Costs:**

* NGINX becomes part of the request path.
* NGINX itself can become a single point of failure in this local architecture.

### Limitations

This configuration does not provide highly available NGINX or multiple hosts.

For production, the public entry point would normally require redundancy and external health monitoring.

### Implementation Status

**Implemented in the assessment environment.**

---

## Decision 2 — Separate Frontend and Backend Networks

### Decision

Use two Docker networks:

```text
frontend
backend
```

The connectivity is:

```text
NGINX
  │
  │ frontend
  ▼
app-01 / app-02
  │
  │ backend
  ├── PostgreSQL
  └── Redis
```

NGINX is connected only to `frontend`.

PostgreSQL and Redis are connected only to `backend`.

The application instances are connected to both networks.

### Why

The separation limits which services can directly communicate with each other.

In particular:

* NGINX does not directly connect to PostgreSQL.
* NGINX does not directly connect to Redis.
* PostgreSQL is not connected to the public-facing network.
* Redis is not connected to the public-facing network.

### Assumptions

* The application requires access to both PostgreSQL and Redis.
* NGINX only needs access to the application instances.

### Alternative

Place every service on a single Docker network.

### Trade-offs

**Benefits:**

* Clear service boundaries
* Reduced unnecessary network exposure
* Easier network isolation validation

**Costs:**

* More network configuration
* Services must be attached to the correct networks

### Limitations

Docker network isolation is only one security layer.

It does not replace authentication, authorization, TLS, firewall controls, or production network segmentation.

### Implementation Status

**Implemented in the assessment environment.**

---

## Decision 3 — Run the Application as a Non-Root User

### Decision

The Flask application container runs using the dedicated `app` user instead of `root`.

The Docker image creates a dedicated application user and switches to it before the application starts.

### Why

Running the application as a non-root user reduces the privileges available to the application process inside the container.

### Assumptions

* The Flask application does not require root privileges.
* The application can read its required files and write only where necessary.

### Alternative

Run the application process as the container's default `root` user.

### Trade-offs

**Benefits:**

* Reduced container process privileges
* Better alignment with least-privilege principles

**Costs:**

* File ownership and permissions must be configured correctly.
* Some applications or startup scripts may require additional permission handling.

### Limitations

A non-root container does not eliminate all container security risks.

Production environments should also consider read-only filesystems, dropped Linux capabilities, seccomp/AppArmor policies, image scanning, runtime isolation, and resource controls where appropriate.

### Implementation Status

**Implemented in the assessment environment.**

---

## Decision 4 — Use a Named PostgreSQL Volume for Persistence

### Decision

PostgreSQL data is stored in the named Docker volume:

```text
postgres-data
```

The volume is mounted at:

```text
/var/lib/postgresql/data
```

### Why

The assessment requires proof that application data survives container recreation.

A named volume separates database storage from the lifecycle of the PostgreSQL container.

### Assumptions

* The Docker host remains available.
* The named volume is not intentionally deleted.
* The PostgreSQL data directory remains valid.

### Alternative

Store PostgreSQL data only inside the container filesystem.

### Trade-offs

**Benefits:**

* Data survives PostgreSQL container recreation.
* Simple local persistence mechanism.
* Easy to use with Docker Compose.

**Costs:**

* Data remains dependent on the local Docker host.
* Volume management must be handled carefully during cleanup.

### Limitations

A Docker named volume is not a production disaster-recovery solution.

It does not protect against:

* Host failure
* Disk failure
* Accidental volume deletion
* Site-level loss

### Implementation Status

**Implemented and verified.**

The persistence test recreated the application and PostgreSQL containers without removing volumes and confirmed that the previously created record remained available.

---

## Decision 5 — Enable NGINX Upstream Retry for Eligible Failures

### Decision

NGINX is configured to retry eligible upstream requests:

```nginx
proxy_next_upstream error timeout http_502 http_503 http_504;
```

### Why

The environment contains two application instances.

If one backend becomes unavailable, NGINX should be able to retry an eligible request against another configured backend rather than immediately returning the upstream failure to the client.

### Assumptions

* `app-01` and `app-02` provide equivalent application functionality.
* Retrying the request against another backend is safe for the relevant requests.
* NGINX can reach both application instances.

### Alternative

Disable upstream retries:

```nginx
proxy_next_upstream off;
```

This was the initial behavior investigated during the failure test.

### Trade-offs

**Benefits:**

* Improved availability when one backend fails
* Allows the remaining backend to serve traffic
* Verified through the failure/recovery test

**Costs:**

* A request can be attempted against more than one upstream.
* Retry behavior can increase latency during failures.
* Retry semantics must be considered carefully for non-idempotent operations.

### Limitations

The local configuration does not provide distributed tracing or advanced retry budgets.

Production retry policies should consider request idempotency, maximum attempts, backoff, circuit breaking, and service-specific failure semantics.

### Implementation Status

**Implemented and verified.**

The failure test produced:

```text
During failure: 20 success, 0 errors
```

and after recovery:

```text
Recovery traffic: 20 success, 0 errors
```

The recovered `app-01` was also proven to serve successful requests through NGINX.

---

## Decision 6 — Use Bounded Validation and Readiness Checks

### Decision

The validation and failure/recovery tests use bounded timeouts rather than waiting indefinitely.

The application also exposes:

```text
/health
/ready
```

`/health` verifies application liveness.

`/ready` verifies application readiness and checks PostgreSQL and Redis connectivity.

### Why

A running container does not necessarily mean that the application is ready to serve traffic.

Bounded checks make validation deterministic and allow failures to produce a non-zero exit status.

### Assumptions

* PostgreSQL and Redis readiness can be represented by successful dependency checks.
* The application can expose health and readiness endpoints.

### Alternative

Only check whether Docker containers are running.

### Trade-offs

**Benefits:**

* Detects dependency failures
* Prevents indefinite validation waits
* Works well in CI

**Costs:**

* Health checks add configuration and maintenance.
* A health endpoint cannot prove every possible application failure mode.

### Limitations

Readiness checks do not prove end-to-end production health.

They do not replace external monitoring, synthetic checks, distributed tracing, or dependency-level observability.

### Implementation Status

**Implemented and verified.**

`validate.py` successfully checks the public endpoint, application endpoints, PostgreSQL readiness, Redis readiness, container presence, port isolation, and network isolation.

---

## Decision 7 — Use PostgreSQL Custom-Format Backups

### Decision

The backup script uses PostgreSQL `pg_dump` with the custom format:

```bash
pg_dump -Fc
```

The resulting dump is stored under:

```text
backups/
```

The restore script uses `pg_restore`.

### Why

The custom PostgreSQL format supports restoration through `pg_restore` and is suitable for the assessment's backup/restore proof.

### Assumptions

* The PostgreSQL client tools are available in the PostgreSQL container.
* The database is accessible through the Compose service.

### Alternative

Use a plain SQL dump:

```bash
pg_dump > backup.sql
```

### Trade-offs

**Benefits:**

* Native PostgreSQL restore workflow
* Supports selective restore capabilities
* Compact binary/custom-format dump

**Costs:**

* The backup is not human-readable as plain SQL.
* The backup file must be kept safe and accessible during restore.

### Limitations

The assessment backup is stored locally.

It is not an off-host backup, encrypted
