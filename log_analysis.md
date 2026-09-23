# Log analysis

This analysis uses all three supplied historical logs:

* `logs/access.log`
* `logs/application.log`
* `logs/error.log`

The original log files were kept unchanged. Analysis was performed using Bash, `jq`, `awk`, `sort`, `uniq`, `grep`, and standard Linux tools.

The supplied logs contain synthetic historical lab data in UTC. The analysis treats `request_id` as the primary client-request identity and uses the final/latest access-log outcome for deduplicated request results.

---

## Investigation approach

### Symptoms observed

The supplied logs show several classes of failures:

* HTTP `404` responses for `/missing`.
* HTTP `502` responses associated with upstream connection failures.
* HTTP `503` responses from application requests.
* HTTP `504` responses associated with NGINX upstream timeouts.
* Increased client latency during failure periods.
* Requests where NGINX first received `502` from one upstream and then successfully retried another upstream.

### Initial hypotheses

The investigation considered the following possible explanations:

1. Some failures could be normal application-level errors, such as a missing route.
2. `502` failures could indicate an upstream connectivity or availability problem.
3. `503` responses could indicate application readiness/dependency problems.
4. `504` responses could indicate slow application processing or a dependency/resource problem.
5. Retry behavior could hide some upstream failures from the final client result.
6. The logs might not contain enough evidence to identify the underlying container, dependency, or infrastructure root cause.

The analysis was used to distinguish what the supplied evidence proves from what would require checks in a running environment.

---

## Commands / scripts

The main reproducible analysis script is:

```bash
./scripts/analyze_logs.sh
```

To save the generated analysis output locally:

```bash
./scripts/analyze_logs.sh > /tmp/barq-analysis.txt
```

Examples of reproducible commands used during investigation:

```bash
sed -n '/### 13. FAILURE TIME WINDOWS/,/### 14. FAILURE BACKENDS/p' /tmp/barq-analysis.txt

sed -n '/### 14. FAILURE BACKENDS/,/### 15. STATUS BY BACKEND/p' /tmp/barq-analysis.txt

sed -n '/### 15. STATUS BY BACKEND/,/### 16. APPLICATION INSTANCES/p' /tmp/barq-analysis.txt

sed -n '/### 16. APPLICATION INSTANCES/,/### 17. CLIENT LATENCY/p' /tmp/barq-analysis.txt

sed -n '/### 17. CLIENT LATENCY/,/### 18. RETRIES/p' /tmp/barq-analysis.txt
```

The script:

* validates JSON records;
* separates malformed records;
* identifies duplicate request IDs;
* uses `request_id` as the request identity;
* determines the final/latest client outcome for each request;
* analyzes raw and final status counts;
* calculates failure windows and backend distribution;
* calculates median and p95 latency;
* identifies multiple upstream attempts;
* correlates access, application, and NGINX error records;
* builds an incident timeline.

The original logs are read-only inputs and are not modified.

---

## Results

### 1. Log interval, valid/malformed/duplicate records

The supplied access and application logs cover approximately:

**2026-08-20 11:00 UTC → 11:29 UTC**

The analysis script validates individual records before including them in calculations.

| File                   | Total lines | Valid | Malformed |      Duplicate request IDs / groups |
| ---------------------- | ----------: | ----: | --------: | ----------------------------------: |
| `logs/access.log`      |         726 |   725 |         1 |             5 duplicate request IDs |
| `logs/application.log` |         730 |   729 |         1 |      49 duplicate request-ID groups |
| `logs/error.log`       |          68 |    68 |         0 | No duplicate request IDs identified |

For `access.log`, the 5 duplicate request IDs are excluded from the distinct-client-request count.

The application log's 49 duplicate request-ID groups are treated as duplicate application events and are not used as the client-request denominator.

The error log is an NGINX text log rather than a structured request-ID dataset, so duplicate request-ID grouping is not applied to it in the same way.

The access log contains 725 valid records, while the deduplicated request set contains 720 unique request IDs.

---

### 2. Distinct client requests and deduplication

There are:

**720 distinct client requests.**

The access log contains **725 valid records**, while the deduplicated request set contains **720 unique request IDs**.

The analysis avoids counting upstream retries as separate client requests by grouping records by `request_id`.

For each request ID, the final/latest client outcome is used as the final request result.

For example, the retry requests contain:

```text
172.23.0.12:8080, 172.23.0.11:8080
```

with upstream statuses:

```text
502, 200
```

These are counted as one client request whose final outcome is `200`, not as two client requests.

---

### 3. Final client status counts and error rate

Final status counts for the 720 unique requests:

| Final status |   Count |
| ------------ | ------: |
| 200          |     615 |
| 404          |      10 |
| 502          |      40 |
| 503          |      47 |
| 504          |       8 |
| **Total**    | **720** |

Final failed requests:

**105**

Final successful requests:

**615**

Client error rate:

**105 / 720 = 14.58%**

The denominator is **one final client outcome per unique `request_id`**.

---

### 4. Failure paths, time windows and backends

Final failure counts by path:

| Path       | Failures |
| ---------- | -------: |
| `/records` |       26 |
| `/counter` |       26 |
| `/ready`   |       23 |
| `/missing` |       10 |
| `/health`  |       10 |
| `/`        |       10 |
| **Total**  |  **105** |

The major failure windows are:

* `11:05–11:09 UTC`: repeated upstream connection-refused failures.
* `11:12–11:15 UTC`: application-level `503` responses.
* `11:20–11:21 UTC`: additional application-level failures.
* `11:25–11:26 UTC`: `/records` requests timing out through NGINX.
* Isolated failures also occur at earlier and later timestamps.

Raw access failures by upstream:

| Upstream           | Failures |
| ------------------ | -------: |
| `172.23.0.12:8080` |       73 |
| `172.23.0.11:8080` |       32 |
| **Total**          |  **105** |

This shows that more failures were observed through `172.23.0.12:8080`, although the logs alone do not establish why that upstream experienced more failures.

---

### 5. Median and p95 client latency

Latency was calculated from the valid access-log `request_time` values.

* Samples: **725**
* Median: **54 ms**
* P95: **2001 ms**
* Percentile method: **linear interpolation**
* Source: `access.log`
* Unit: **milliseconds**

The difference between the 54 ms median and approximately 2 second p95 indicates that a relatively small portion of requests experienced substantially higher latency.

---

### 6. Upstream retries

There are:

**19 requests with multiple upstream attempts.**

All 19 follow this pattern:

```text
172.23.0.12:8080 → 172.23.0.11:8080
502 → 200
```

All **19/19** retrying requests eventually succeeded.

Therefore:

* Requests retried: **19**
* Retry requests eventually successful: **19**
* Final client result for all 19: **200**

These requests demonstrate that an upstream failure can occur without becoming a final client failure when NGINX successfully retries another upstream.

---

## Timeline and correlated examples

### 7. Incident timeline

#### 11:00–11:03 UTC

Normal successful traffic is present alongside isolated `/missing` `404` responses.

Example:

```text
lab-000001
11:00:00.015Z
GET /missing
404
```

The corresponding application log identifies `app-01` and also reports status `404`.

This is consistent with an application-level not-found response rather than an NGINX connectivity failure.

#### 11:05–11:09 UTC

NGINX reports repeated:

```text
connect() failed (111: Connection refused) while connecting to upstream
```

Most of these events target:

```text
172.23.0.12:8080
```

Some requests are retried against:

```text
172.23.0.11:8080
```

and eventually succeed.

#### 11:12–11:15 UTC

Both application instances produce `503` responses for requests including `/ready` and `/counter`.

This provides application-layer evidence in addition to client-facing NGINX/access evidence.

#### 11:20–11:21 UTC

Additional `503` failures occur, continuing the application-level failure pattern.

#### 11:25–11:26 UTC

NGINX reports:

```text
upstream timed out while reading response header from upstream
```

These events affect `/records` and occur against both upstream addresses:

```text
172.23.0.11:8080
172.23.0.12:8080
```

This indicates that NGINX reached the upstream path far enough to wait for a response header, but the expected response was not received before the timeout.

#### 11:30 UTC

The error log contains:

```text
log collector rotated stream
```

This is a log-management event rather than an application request failure.

---

### 8. Correlated failed and successful requests

#### Correlated failed request — application-level 404

Request:

```text
request_id: lab-000001
timestamp: 2026-08-20T11:00:00.015Z
method: GET
path: /missing
client status: 404
upstream: 172.23.0.11:8080
```

Application log:

```text
request_id: lab-000001
instance_id: app-01
status: 404
duration_ms: 15.0
```

There is no matching NGINX error entry.

This supports an application-level `404` rather than a proxy/connectivity failure.

#### Correlated failed request — upstream connectivity failure

Request:

```text
request_id: lab-000122
timestamp: 2026-08-20T11:05:02.503Z
method: GET
path: /health
client status: 502
upstream: 172.23.0.12:8080
```

Matching NGINX error:

```text
2026/08/20 11:05:02
request_id=lab-000122
connect() failed (111: Connection refused)
upstream: http://172.23.0.12:8080/health
```

There is no matching application-log request record for this request ID.

This is strong evidence that NGINX could not establish the upstream connection at that moment.

#### Correlated successful request

Request:

```text
request_id: lab-000002
timestamp: 2026-08-20T11:00:02.532Z
method: GET
path: /health
client status: 200
upstream: 172.23.0.12:8080
```

Application log:

```text
request_id: lab-000002
instance_id: app-02
status: 200
duration_ms: 32.0
```

There is no matching NGINX error.

The access and application records agree on timestamp, request ID and successful status.

---

### 9. Proxy/connectivity errors vs dependency/application errors

#### Proxy/upstream connectivity evidence

The strongest proxy/connectivity evidence is the NGINX error:

```text
connect() failed (111: Connection refused) while connecting to upstream
```

This proves that NGINX could not establish a connection to the specified upstream at that moment.

The `502` client responses associated with these events are consistent with this failure.

However, the logs do not prove whether the underlying cause was:

* a stopped container;
* a crashed process;
* an unavailable listener;
* a transient network condition;
* resource exhaustion;
* or another infrastructure condition.

#### Timeout evidence

The `504` responses during `11:25–11:26 UTC` correlate with:

```text
upstream timed out while reading response header from upstream
```

All observed timeout requests target `/records`.

This proves that NGINX waited for an upstream response header and timed out.

It does not prove whether the underlying cause was PostgreSQL, Redis, Flask application processing, CPU/memory pressure, connection-pool exhaustion, or another dependency/resource issue.

#### Application-level evidence

The `503` requests during the later failure window have matching application-log records with application status `503`.

This demonstrates that those responses were generated at the application layer.

The supplied logs do not provide enough evidence to identify the exact internal dependency or readiness condition that caused the `503`.

---

## 10. What the logs do not prove

The logs do not prove:

* that a particular Docker container was stopped;
* that PostgreSQL caused the `/records` timeout;
* that Redis caused any failure;
* that CPU or memory exhaustion occurred;
* that the Docker network itself was broken;
* the exact reason an upstream stopped accepting connections;
* the exact internal reason for the application `503` responses;
* whether a dependency was slow, unavailable, or resource constrained unless additional application/dependency logs confirm it.

### Checks to perform in a running environment

If the incident were happening live, the next checks would include:

```bash
docker compose ps
docker compose logs --tail=200 app-01 app-02
docker compose logs --tail=200 postgres redis nginx
```

Check listening ports and connectivity:

```bash
docker compose exec app-01 sh
```

Then from the application container:

```bash
getent hosts postgres
getent hosts redis
```

and appropriate connectivity checks against the service names and ports.

Check container resource usage:

```bash
docker stats
```

Check PostgreSQL readiness:

```bash
pg_isready
```

Check Redis:

```bash
redis-cli ping
```

Also inspect:

* application readiness/dependency errors;
* PostgreSQL connection counts and slow queries;
* Redis availability;
* container restart history;
* Docker network connectivity;
* CPU/memory limits and OOM events;
* NGINX timeout and retry configuration.

---

## Conclusions and limits

### Proven findings

1. The supplied logs contain **720 unique client requests**.
2. There are **615 successful final outcomes** and **105 failed final outcomes**.
3. The final client error rate is **14.58%**, using one final outcome per unique request ID.
4. There are **19 requests with multiple upstream attempts**, and all 19 eventually succeeded.
5. The `11:05–11:09 UTC` period contains repeated NGINX upstream connection-refused events.
6. The `11:12–11:21 UTC` period contains application-level `503` responses.
7. The `11:25–11:26 UTC` period contains `/records` upstream timeout events against both upstreams.
8. NGINX `connection refused` entries prove upstream connection failure at the recorded moment.
9. NGINX timeout entries prove that the proxy waited for an upstream response and timed out.
10. The supplied logs do not prove the deeper infrastructure or dependency root cause for every failure.

### Investigation correction / failed attempt

During analysis, the first implementation of the final failure-window calculation did not filter the final-status records to failed statuses. As a result, successful `200` requests were initially included in the "Final failed requests grouped by minute" output.

The calculation was corrected to include only final statuses `>= 400`:

```bash
awk -F '\t' '
    $3 >= 400 {
        print substr($2, 1, 16)
    }
' "$FINAL_STATUS_FILE" |
sort |
uniq -c |
sort -nr
```

After the correction, the raw failure-window counts and final failure-window counts both total **105**, matching the final failure count.

### Root-cause boundary

The analysis distinguishes between **observed/proven behavior** and **unproven underlying causes**.

The evidence proves upstream connection failures, application-level `503` responses, and NGINX upstream timeouts at specific timestamps. It does not establish a single underlying infrastructure or dependency root cause without runtime/container/dependency evidence.

This boundary is intentional: no root cause is claimed beyond what the supplied evidence supports.
