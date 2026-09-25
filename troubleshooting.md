# Troubleshooting Journal

This document records the main investigation steps, failed attempts, fixes, and retests performed while repairing the BARQ DevOps assessment environment.

Only actual investigation attempts and observed results are recorded.

---

## Entry 1 — NGINX Backend Failure and Recovery

### Date / Time

2026-09-24

### Symptom

When one application backend was stopped, requests sent through NGINX were not consistently recovered by the remaining backend.

The failure/recovery test showed request errors while `app-01` was unavailable and also showed errors after the backend was restarted.

### Hypothesis

The initial hypothesis was that NGINX was not retrying failed upstream requests against the remaining healthy application instance.

The upstream configuration needed to be inspected to determine whether NGINX was allowed to retry requests after connection failures, timeouts, or upstream HTTP errors.

### Command or Test

The failure scenario was tested by running:

```bash
python3 failure_test.py
```

The test stops `app-01`, sends requests through the public NGINX endpoint, restores `app-01`, and then sends recovery traffic.

The NGINX configuration was also inspected and tested with:

```bash
docker exec nginx nginx -t
```

### Actual Output

The initial failure test showed that requests were failing while one backend was unavailable.

The important behavior was:

```text
10 success / 10 errors
```

The failure was associated with the NGINX upstream handling while `app-01` was unavailable.

### Failed Attempt and What Changed the Thinking

The initial NGINX configuration contained:

```nginx
proxy_next_upstream off;
```

With this configuration, NGINX did not retry eligible failed upstream requests against the other application instance.

The failure test demonstrated that the remaining healthy backend was available, but requests were still failing instead of being retried through the healthy upstream.

This changed the investigation from an application availability problem to an NGINX upstream failover configuration problem.

### Root Cause

NGINX was configured with:

```nginx
proxy_next_upstream off;
```

This disabled upstream request retry behavior.

As a result, an upstream connection failure or timeout could be returned to the client instead of allowing NGINX to retry the request against another configured backend.

### Fix

The upstream configuration was changed to allow retries for connection errors, timeouts, and relevant upstream HTTP errors:

```nginx
proxy_next_upstream error timeout http_502 http_503 http_504;
```

The NGINX configuration was then syntax-checked:

```bash
docker exec nginx nginx -t
```

The configuration test completed successfully.

### Retest Evidence

The failure/recovery test was executed again:

```bash
python3 failure_test.py
```

During the backend failure:

```text
Baseline traffic: 10 success, 0 errors
During failure: 20 success, 0 errors
instances={'app-02': 20}
```

The test confirmed:

```text
[PASS] No request errors observed while one backend was stopped
[PASS] Stopped backend app-01 did not serve traffic
```

After restoring `app-01`:

```text
Recovery traffic: 20 success, 0 errors
```

The test also confirmed:

```text
[PASS] app-01 recovered and service is healthy
[PASS] Recovered backend app-01 served successful recovery traffic through NGINX

Failure/recovery test: PASS
```

NGINX access logs also showed successful requests reaching the recovered backend, including successful `200` responses from the `app-01` upstream.

### Related Commit

```text
37121d3 feat: add failure recovery backup restore and CI
```

### Remaining Uncertainty

The local failure test verifies failover between the two application containers in the Docker Compose environment.

It does not prove high availability of the NGINX container itself, the Docker host, PostgreSQL, Redis, or the underlying workstation.

---

## Entry 2 — PostgreSQL Backup Restore Test

### Date / Time

2026-09-24

### Symptom

The starter `backup.sh` and `restore.sh` scripts were placeholders and exited with status `2`.

### Hypothesis

The scripts needed to provide an actual PostgreSQL backup and restore workflow and produce a verifiable recovery result.

### Command or Test

The PostgreSQL backup was created with:

```bash
./backup.sh
```

A test record was created through the application:

```bash
curl -s -X POST http://127.0.0.1:8080/records \
  -H 'Content-Type: application/json' \
  -d '{"title":"backup-restore-proof"}'
```

The record was then included in a PostgreSQL backup.

### Actual Output

The application created the record successfully:

```text
{"record":{"id":4,"title":"backup-restore-proof"}}
```

A timestamped backup was created under:

```text
backups/
```

The backup contained PostgreSQL table data for the `records` table.

### Failed Attempt and What Changed the Thinking

An initial restore attempt tried to reference the host backup path directly from inside the PostgreSQL container:

```text
pg_restore: error: could not open input file "backups/postgres_20260924_082814.dump": No such file or directory
```

This demonstrated that the backup file path on the host is not automatically available as the same path inside the container.

The restore approach was changed to stream the backup file through standard input.

### Root Cause

The restore command was using a host filesystem path as if it were a path inside the PostgreSQL container.

### Fix

The backup was streamed into `pg_restore`:

```bash
docker compose -p barq-assessment exec -T postgres \
  pg_restore \
  -U barq_app \
  -d backup_restore_test \
  --no-owner \
  < backups/postgres_20260924_082814.dump
```

### Retest Evidence

The restore completed successfully.

The restored database was queried:

```bash
docker compose -p barq-assessment exec -T postgres \
  psql -U barq_app -d backup_restore_test \
  -c "SELECT id, title FROM records WHERE title = 'backup-restore-proof';"
```

The record was recovered:

```text
 id |        title
----+----------------------
  4 | backup-restore-proof
(1 row)
```

The temporary database was then removed.

### Related Commit

```text
37121d3 feat: add failure recovery backup restore and CI
```

### Remaining Uncertainty

The restore test proves that the generated PostgreSQL dump can recover application data.

It does not provide production-grade disaster recovery, off-host backup storage, backup encryption management, or automated restore testing.

---

## Entry 3 — PostgreSQL Persistence After Container Recreation

### Date / Time

2026-09-24

### Symptom

The assessment required proof that application data survives container recreation while the PostgreSQL volume is retained.

### Hypothesis

PostgreSQL data should persist because the database uses the named Docker volume:

```text
postgres-data
```

### Command or Test

The application and PostgreSQL containers were recreated without removing volumes:

```bash
docker compose -p barq-assessment up -d --force-recreate app-01 app-02 postgres
```

The previously created record was then queried again through the application.

### Actual Output

The environment returned the previously created record after container recreation:

```text
backup-restore-proof
```

The application and PostgreSQL containers were healthy after recreation.

### Failed Attempt and What Changed the Thinking

No failed attempt was required for this investigation.

The test was designed specifically to verify persistence while retaining the named volume.

### Root Cause

The data remained available because PostgreSQL stores its database files in the persistent `postgres-data` Docker volume rather than only inside the PostgreSQL container filesystem.

### Fix

No corrective fix was required for this test. The persistence mechanism was verified as implemented.

### Retest Evidence

After recreation:

```bash
docker compose -p barq-assessment ps
```

showed the required services running, and:

```bash
curl -fsS http://127.0.0.1:8080/records
```

returned the previously created record.

### Related Commit

```text
37121d3 feat: add failure recovery backup restore and CI
```

### Remaining Uncertainty

A local Docker volume is not equivalent to production storage resilience.

The test does not prove protection against host loss, filesystem corruption, or deletion of the Docker volume.

---

## Investigation Summary

The main investigated runtime issue was NGINX upstream failover.

The initial configuration disabled upstream retries, which caused request failures when one application backend became unavailable. After enabling retry behavior for connection errors, timeouts, and relevant upstream HTTP errors, the failure test demonstrated successful traffic through the remaining backend and successful traffic from the recovered backend.

The database investigations separately verified:

* PostgreSQL backup creation
* PostgreSQL backup restoration
* Data persistence after container recreation

All retests were performed against the local Docker Compose environment.
