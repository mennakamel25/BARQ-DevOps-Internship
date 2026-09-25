# Security Review

This document reviews the security posture of the BARQ DevOps assessment environment.

The review distinguishes between controls that are implemented in the assessment and improvements that would be considered for a production deployment.

---

## 1. Application Secrets

### Risk

Secrets must not be baked into Docker images or committed to source control.

The original application image copied `config/app.env` into the container image. This could expose application credentials through the image filesystem and image history.

### Implemented Improvement

The Dockerfile no longer copies `config/app.env` into the image.

Runtime configuration is provided through environment variables.

The repository also uses `.env.example` with placeholder values, while the local `.env` file is ignored by Git.

### Production Improvement

Use a dedicated secrets-management solution such as a cloud secrets manager or Vault.

Secrets should be injected at runtime and rotated according to organizational requirements.

### Status

**Implemented for the assessment.**

Production-grade centralized secret management is **not implemented**.

---

## 2. PostgreSQL and Redis Network Exposure

### Risk

Databases and internal services should not be directly exposed to the host or public network.

Direct host exposure would increase the attack surface and could allow clients to bypass the application layer.

### Implemented Improvement

PostgreSQL and Redis do not publish host ports.

They are connected to the internal `backend` Docker network.

The application instances communicate with them through the backend network.

### Production Improvement

Use private subnets/security groups or equivalent network controls in a production environment.

Database access should be restricted to the application tier.

### Status

**Implemented for the assessment.**

---

## 3. Network Segmentation

### Risk

Putting every service on one shared network would provide unnecessary connectivity between components.

For example, NGINX should not require direct access to PostgreSQL.

### Implemented Improvement

The Compose environment uses:

```text
frontend
backend
```

Connectivity is intentionally separated:

```text
NGINX
  |
frontend
  |
app-01 / app-02
  |
backend
  +-- PostgreSQL
  +-- Redis
```

### Production Improvement

Production deployments should apply additional network segmentation using infrastructure-level controls, security groups, firewalls, and private networking.

### Status

**Implemented for the assessment.**

---

## 4. Container User Privileges

### Risk

Running application processes as `root` increases the potential impact of an application compromise.

If an attacker gains code execution inside the application container, unnecessary privileges can increase the blast radius.

### Implemented Improvement

The application image creates a dedicated `app` user with UID `10001`.

The application runs as this non-root user.

### Production Improvement

Production deployments should additionally review:

* Linux capabilities
* Read-only filesystems
* Seccomp/AppArmor policies
* Writable directories
* Container runtime isolation

### Status

**Non-root execution is implemented.**

The additional production hardening controls are not part of the assessment implementation.

---

## 5. Container Image Integrity

### Risk

Using mutable image tags alone means that the image content can change when the tag is updated.

This can make builds less reproducible and makes it harder to identify exactly which image version was deployed.

### Implemented Improvement

The Compose configuration pins service images by digest.

The application base image is also pinned by digest in the Dockerfile.

### Production Improvement

A production image pipeline should additionally include:

* Vulnerability scanning
* Software bill of materials (SBOM)
* Image signing
* Trusted registries
* Controlled promotion between environments

### Status

**Digest pinning is implemented.**

Image scanning, signing, and SBOM enforcement are not implemented in this assessment.

---

## 6. Host Port Exposure

### Risk

Every published container port increases the host attack surface.

Publishing PostgreSQL, Redis, or application ports directly would allow clients to bypass NGINX.

### Implemented Improvement

Only NGINX publishes a host port:

```text
127.0.0.1:8080 -> nginx:80
```

The application, PostgreSQL, and Redis services do not publish host ports.

### Production Improvement

For a production deployment, public exposure should normally be controlled through a dedicated ingress/load-balancing layer with appropriate TLS and network security controls.

### Status

**Implemented and validated.**

The validation script confirms that only NGINX publishes the host port.

---

## 7. NGINX Upstream Failure Handling

### Risk

If one application instance becomes unavailable and NGINX does not retry eligible upstream failures, clients can receive avoidable gateway errors even when another application instance is available.

### Implemented Improvement

NGINX uses:

```nginx
proxy_next_upstream error timeout http_502 http_503 http_504;
```

This allows eligible failures to be retried against another configured upstream.

### Verification

The failure/recovery test stopped `app-01` while traffic continued through NGINX.

The observed result was:

```text
During failure: 20 success, 0 errors
```

The stopped backend did not serve traffic, while `app-02` handled the requests.

After restarting `app-01`, recovery traffic also completed successfully.

### Production Improvement

Production retry behavior should consider:

* Request idempotency
* Retry limits
* Backoff
* Circuit breaking
* Upstream health
* Request timeouts

### Status

**Implemented and tested.**

---

## 8. PostgreSQL Backup Protection

### Risk

A database backup is sensitive because it may contain application data.

A local backup file can be lost, modified, or accessed by unauthorized users.

### Implemented Improvement

The repository includes a backup workflow using PostgreSQL custom-format dumps.

Backup files are stored under:

```text
backups/
```

The backup directory is excluded from Git.

### Production Improvement

Production backups should normally include:

* Encryption at rest
* Restricted access
* Off-host storage
* Retention policies
* Backup rotation
* Immutable or protected copies
* Restore testing
* Monitoring and alerting

### Status

**Backup and restore are implemented and tested locally.**

The production backup controls above are not implemented.

---

## 9. Backup and Restore Verification

### Risk

Creating backups without testing restoration does not prove that the backup can actually recover data.

### Implemented Improvement

The assessment includes both:

```text
backup.sh
restore.sh
```

A database record was created, a backup was generated, and the dump was restored into a temporary PostgreSQL database.

The restored record was verified after the restore.

### Production Improvement

Production environments should perform scheduled restore tests and record the results.

Recovery objectives should also be defined:

* Recovery Point Objective (RPO)
* Recovery Time Objective (RTO)

### Status

**Implemented and verified locally.**

Formal production DR testing is not implemented.

---

## 10. Persistent Storage Protection

### Risk

A Docker named volume provides persistence across container recreation, but it does not provide protection against host-level failure or accidental deletion.

### Implemented Improvement

PostgreSQL uses:

```text
postgres-data
```

The persistence test confirmed that application data survived container recreation when the volume was retained.

### Production Improvement

Production database storage should use durable storage with:

* Replication where required
* Automated backups
* Monitoring
* Disaster recovery
* Controlled deletion policies

### Status

**Local persistence is implemented and verified.**

Production database resilience is not implemented.

---

## 11. Logging and Sensitive Data

### Risk

Application and proxy logs can contain request information and operational details.

If sensitive data is logged, logs can become another source of information disclosure.

### Implemented Improvement

NGINX uses structured JSON access logs and sends logs to standard output/error streams.

The logging configuration records request metadata such as:

* Timestamp
* Request ID
* HTTP method
* Path
* Status
* Upstream
* Request time

### Production Improvement

Production logging should define:

* Data-retention policies
* Access controls
* Centralized log storage
* Sensitive-field filtering
* Log integrity requirements
* Alerting for security-relevant events

### Status

**Structured container logging is implemented.**

Centralized production log management is not implemented.

---

## 12. Health and Readiness Checks

### Risk

A container can be running while the application or one of its dependencies is unavailable.

Checking only container state can therefore produce false confidence.

### Implemented Improvement

The application exposes:

```text
/health
/ready
```

The application container also has a Docker healthcheck.

The readiness endpoint verifies PostgreSQL and Redis availability.

### Production Improvement

Production monitoring should combine application health with:

* Infrastructure metrics
* Dependency monitoring
* External synthetic checks
* Alerting
* Distributed tracing

### Status

**Implemented for the assessment.**

Full production observability is not implemented.

---

## 13. Dependency and Image Vulnerability Scanning

### Risk

Pinned images improve reproducibility but do not guarantee that the image or its packages are free of known vulnerabilities.

### Current State

The assessment pins image digests, but automated vulnerability scanning is not part of the implemented environment.

### Production Improvement

A production CI/CD pipeline should scan:

* Container images
* Python dependencies
* Operating-system packages
* Infrastructure-as-code
* Application source code

Build or deployment policies can then define how findings are handled.

### Status

**Production improvement — not implemented in the assessment.**

---

## 14. CI Validation

### Risk

Changes that are not validated automatically can introduce broken configurations or application failures.

### Implemented Improvement

The CI workflow performs:

* Python syntax checks
* Docker Compose configuration validation
* Image builds
* Environment startup
* Readiness checks
* Environment validation

The validation script exits non-zero when a required check fails.

### Production Improvement

A production pipeline should additionally consider security and quality gates such as:

* Dependency scanning
* Container scanning
* Secret scanning
* IaC scanning
* Tests
* Deployment approval controls

### Status

**Basic CI validation is implemented and verified.**

The additional security gates are not implemented in this assessment.

---

## Security Review Summary

The assessment implements several concrete security controls:

* Runtime secret injection instead of baking secrets into the application image
* Ignored local environment files
* No direct host exposure for PostgreSQL or Redis
* Frontend/backend network segmentation
* Non-root application execution
* Digest-pinned images
* Single controlled public entry point
* Structured logging
* Health and readiness checks
* Backup and restore workflow
* CI validation

The following areas remain production considerations rather than implemented assessment features:

* Centralized secrets management
* Encrypted/off-host backups
* Disaster recovery
* Centralized log management
* Image and dependency vulnerability scanning
* Image signing and SBOM enforcement
* Production-grade network controls
* Advanced runtime hardening
* External monitoring and alerting
* High availability across hosts

These limitations are intentional boundaries of the local Docker Compose assessment environment and should not be represented as implemented production capabilities.
