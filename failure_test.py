#!/usr/bin/env python3

import json
import subprocess
import sys
import time
import urllib.error
import urllib.request


BASE_URL = "http://127.0.0.1:8080"

PROJECT = "barq-assessment"
TARGET = "app-01"

REQUEST_TIMEOUT = 3
COMMAND_TIMEOUT = 10
WAIT_TIMEOUT = 30

BASELINE_REQUESTS = 10
FAILURE_REQUESTS = 20
RECOVERY_REQUESTS = 20


def run_command(command):
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=COMMAND_TIMEOUT,
            check=False,
        )
        return (
            result.returncode,
            result.stdout.strip(),
            result.stderr.strip(),
        )
    except subprocess.TimeoutExpired:
        return 124, "", "command timed out"


def http_get(path):
    try:
        with urllib.request.urlopen(
            f"{BASE_URL}{path}",
            timeout=REQUEST_TIMEOUT,
        ) as response:
            body = response.read().decode()
            return response.status, body
    except urllib.error.HTTPError as exc:
        return exc.code, ""
    except Exception:
        return None, ""


def wait_for_health(timeout=WAIT_TIMEOUT):
    deadline = time.monotonic() + timeout

    while time.monotonic() < deadline:
        status, _ = http_get("/health")

        if status == 200:
            return True

        time.sleep(1)

    return False


def request_instances(count):
    successes = 0
    errors = 0
    instances = {}

    for _ in range(count):
        status, body = http_get("/instance")

        if status == 200:
            try:
                data = json.loads(body)
                instance_id = data.get("instance_id")

                if instance_id:
                    successes += 1
                    instances[instance_id] = (
                        instances.get(instance_id, 0) + 1
                    )
                else:
                    errors += 1

            except json.JSONDecodeError:
                errors += 1
        else:
            errors += 1

    return successes, errors, instances


def get_target_backend_ip():
    rc, stdout, stderr = run_command(
        [
            "docker",
            "inspect",
            TARGET,
            "--format",
            "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}",
        ]
    )

    if rc != 0:
        print(f"[FAIL] Could not get IP for {TARGET}")
        print(stderr or stdout)
        return None

    ips = stdout.split()

    for ip in ips:
        if ip.startswith("172.25."):
            return ip

    print(
        f"[FAIL] Could not identify backend IP for {TARGET}: {ips}"
    )
    return None


def get_nginx_logs():
    rc, stdout, stderr = run_command(
        [
            "docker",
            "logs",
            "nginx",
        ]
    )

    if rc != 0:
        print("[FAIL] Could not read NGINX logs")
        print(stderr or stdout)
        return None

    return f"{stdout}\n{stderr}"


def stop_target():
    rc, stdout, stderr = run_command(
        [
            "docker",
            "compose",
            "-p",
            PROJECT,
            "stop",
            TARGET,
        ]
    )

    if rc != 0:
        print(f"[FAIL] Could not stop {TARGET}")
        print(stderr or stdout)
        return False

    print(f"[PASS] Stopped {TARGET}")
    return True


def restore_target():
    rc, stdout, stderr = run_command(
        [
            "docker",
            "compose",
            "-p",
            PROJECT,
            "start",
            TARGET,
        ]
    )

    if rc != 0:
        print(f"[FAIL] Could not restore {TARGET}")
        print(stderr or stdout)
        return False

    print(f"[PASS] Started {TARGET}")
    return True


def target_served_successfully(logs, target_ip):
    target_marker = f"{target_ip}:8080"

    for line in logs.splitlines():
        try:
            data = json.loads(line)
        except json.JSONDecodeError:
            continue

        if data.get("status") != 200:
            continue

        upstream = data.get("upstream", "")
        upstream_status = data.get("upstream_status", "")

        upstreams = [
            item.strip()
            for item in upstream.split(",")
        ]

        statuses = [
            item.strip()
            for item in upstream_status.split(",")
        ]

        for server, status in zip(upstreams, statuses):
            if server == target_marker and status == "200":
                return True

    return False


def main():
    print("Starting scoped backend failure/recovery test")
    print(f"Target backend: {TARGET}")
    print()

    target_ip = get_target_backend_ip()

    if not target_ip:
        return 1

    print(f"[INFO] {TARGET} backend IP: {target_ip}")
    print()

    if not wait_for_health():
        print("[FAIL] Baseline service is not healthy")
        return 1

    print("[PASS] Baseline service is healthy")

    baseline_success, baseline_errors, baseline_instances = (
        request_instances(BASELINE_REQUESTS)
    )

    print(
        f"[INFO] Baseline traffic: "
        f"{baseline_success} success, "
        f"{baseline_errors} errors, "
        f"instances={baseline_instances}"
    )

    if baseline_success == 0:
        print("[FAIL] No successful baseline requests")
        return 1

    target_was_stopped = False
    test_failed = False

    try:
        if not stop_target():
            test_failed = True
        else:
            target_was_stopped = True

            time.sleep(2)

            failure_success, failure_errors, failure_instances = (
                request_instances(FAILURE_REQUESTS)
            )

            print(
                f"[INFO] During failure: "
                f"{failure_success} success, "
                f"{failure_errors} errors, "
                f"instances={failure_instances}"
            )

            if failure_success == 0:
                print(
                    "[FAIL] Service became completely unavailable "
                    "when one backend stopped"
                )
                test_failed = True

            if failure_errors > 0:
                print(
                    f"[INFO] Errors observed during failure: "
                    f"{failure_errors}/{FAILURE_REQUESTS}"
                )
            else:
                print(
                    "[PASS] No request errors observed while "
                    "one backend was stopped"
                )

            if TARGET in failure_instances:
                print(
                    f"[FAIL] Stopped backend {TARGET} "
                    "still served traffic"
                )
                test_failed = True
            else:
                print(
                    f"[PASS] Stopped backend {TARGET} "
                    "did not serve traffic"
                )

    finally:
        if target_was_stopped:
            restore_target()

    if not wait_for_health():
        print(
            f"[FAIL] {TARGET} did not recover "
            "within bounded wait"
        )
        return 1

    print(
        f"[PASS] {TARGET} recovered and service is healthy"
    )

    recovery_success, recovery_errors, recovery_instances = (
        request_instances(RECOVERY_REQUESTS)
    )

    print(
        f"[INFO] Recovery traffic: "
        f"{recovery_success} success, "
        f"{recovery_errors} errors, "
        f"instances={recovery_instances}"
    )

    if recovery_success == 0:
        print("[FAIL] No successful requests after recovery")
        test_failed = True

    if recovery_errors > 0:
        print(
            f"[FAIL] Requests still failing after recovery: "
            f"{recovery_errors}/{RECOVERY_REQUESTS}"
        )
        test_failed = True

    recovery_logs = get_nginx_logs()

    if recovery_logs is None:
        return 1

    if target_served_successfully(
        recovery_logs,
        target_ip,
    ):
        print(
            f"[PASS] Recovered backend {TARGET} "
            "served successful recovery traffic through NGINX"
        )
    else:
        print(
            f"[FAIL] Recovered backend {TARGET} "
            "was not proven to serve successful recovery "
            "traffic through NGINX"
        )
        test_failed = True

    print()

    if test_failed:
        print("Failure/recovery test: FAIL")
        return 1

    print("Failure/recovery test: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())