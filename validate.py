#!/usr/bin/env python3

import json
import subprocess
import sys
import time
import urllib.error
import urllib.request


BASE_URL = "http://127.0.0.1:8080"
PROJECT = "barq-assessment"
TIMEOUT = 30

results = []


def report(name, passed, details=""):
    status = "PASS" if passed else "FAIL"
    message = f"[{status}] {name}"
    if details:
        message += f" - {details}"

    print(message)
    results.append(passed)


def run_command(command):
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        return result.returncode, result.stdout.strip(), result.stderr.strip()

    except subprocess.TimeoutExpired:
        return 124, "", "command timed out"


def wait_for_http(url, timeout=TIMEOUT):
    deadline = time.monotonic() + timeout

    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=2) as response:
                return response.status

        except (urllib.error.URLError, TimeoutError, OSError):
            time.sleep(1)

    return None


def get_json(path):
    try:
        with urllib.request.urlopen(
            f"{BASE_URL}{path}",
            timeout=5,
        ) as response:
            body = response.read().decode()
            return response.status, json.loads(body)

    except Exception as exc:
        return None, str(exc)


def check_public_access():
    status = wait_for_http(f"{BASE_URL}/health")

    report(
        "Public access",
        status == 200,
        f"HTTP {status}"
        if status
        else "no response within bounded wait",
    )


def check_endpoints():
    endpoints = [
        "/",
        "/health",
        "/ready",
        "/instance",
        "/records",
        "/counter",
    ]

    for endpoint in endpoints:
        status, body = get_json(endpoint)

        passed = status == 200
        details = f"HTTP {status}" if status else str(body)

        if endpoint == "/ready" and status == 200 and isinstance(body, dict):
            dependencies = body.get("dependencies", {})

            postgres_ready = (
                dependencies.get("postgres") == "ready"
            )
            redis_ready = (
                dependencies.get("redis") == "ready"
            )

            passed = postgres_ready and redis_ready

            details = (
                f"postgres={dependencies.get('postgres')}, "
                f"redis={dependencies.get('redis')}"
            )

        if endpoint == "/instance" and status == 200:
            if isinstance(body, dict):
                instance_id = body.get("instance_id")
                passed = bool(instance_id)
                details = f"instance_id={instance_id}"

        report(
            f"Endpoint {endpoint}",
            passed,
            details,
        )


def check_containers():
    expected = {
        "app-01",
        "app-02",
        "nginx",
        "postgres",
        "redis",
    }

    rc, stdout, stderr = run_command(
        [
            "docker",
            "compose",
            "-p",
            PROJECT,
            "ps",
            "-a",
            "--format",
            "{{.Name}}",
        ]
    )

    actual = set(stdout.splitlines()) if rc == 0 else set()
    missing = expected - actual

    report(
        "Required containers",
        rc == 0 and not missing,
        (
            f"missing={sorted(missing)}"
            if missing
            else "all required containers present"
        ),
    )


def check_host_ports():
    rc, stdout, stderr = run_command(
        [
            "docker",
            "ps",
            "--format",
            "{{.Names}}|{{.Ports}}",
        ]
    )

    if rc != 0:
        report(
            "Host port isolation",
            False,
            stderr or "docker ps failed",
        )
        return

    allowed = True
    violations = []

    expected_containers = {
        "app-01",
        "app-02",
        "nginx",
        "postgres",
        "redis",
    }

    for line in stdout.splitlines():
        if "|" not in line:
            continue

        name, ports = line.split("|", 1)

        if name not in expected_containers:
            continue

        has_host_binding = "->" in ports

        if name == "nginx":
            if (
                not has_host_binding
                or ":8080->80/" not in ports
            ):
                allowed = False
                violations.append(
                    f"{name}: {ports}"
                )

        elif has_host_binding:
            allowed = False
            violations.append(
                f"{name}: {ports}"
            )

    report(
        "Host port isolation",
        allowed,
        (
            "only nginx publishes host port 8080"
            if allowed
            else "; ".join(violations)
        ),
    )


def check_network_isolation():
    expected_networks = {
        "app-01": {
            "barq-assessment_frontend",
            "barq-assessment_backend",
        },
        "app-02": {
            "barq-assessment_frontend",
            "barq-assessment_backend",
        },
        "nginx": {
            "barq-assessment_frontend",
        },
        "postgres": {
            "barq-assessment_backend",
        },
        "redis": {
            "barq-assessment_backend",
        },
    }

    all_passed = True
    failures = []

    for container, expected in expected_networks.items():
        rc, stdout, stderr = run_command(
            [
                "docker",
                "inspect",
                container,
                "--format",
                "{{json .NetworkSettings.Networks}}",
            ]
        )

        if rc != 0:
            all_passed = False
            failures.append(
                f"{container}: inspect failed"
            )
            continue

        try:
            networks = set(
                json.loads(stdout).keys()
            )

        except json.JSONDecodeError:
            all_passed = False
            failures.append(
                f"{container}: invalid network data"
            )
            continue

        if networks != expected:
            all_passed = False
            failures.append(
                f"{container}: "
                f"expected={sorted(expected)}, "
                f"actual={sorted(networks)}"
            )

    report(
        "Network isolation",
        all_passed,
        (
            "network layout matches required "
            "frontend/backend isolation"
            if all_passed
            else "; ".join(failures)
        ),
    )


def main():
    print(
        f"Validating BARQ environment: {BASE_URL}"
    )
    print()

    check_public_access()
    check_endpoints()
    check_containers()
    check_host_ports()
    check_network_isolation()

    print()

    passed = sum(results)
    total = len(results)

    if passed == total:
        print(
            f"Validation result: PASS "
            f"({passed}/{total})"
        )
        return 0

    print(
        f"Validation result: FAIL "
        f"({passed}/{total})"
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())