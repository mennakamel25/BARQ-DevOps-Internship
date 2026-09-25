# AI Usage

## Tool Used

ChatGPT

## Purpose

AI assistance was used for:

* Explaining Docker Compose, networking, and troubleshooting concepts.
* Reviewing Bash/Python validation logic and configuration.
* Structuring technical documentation and investigation notes.
* Improving technical wording and distinguishing verified results from assumptions.

All commands and changes were executed and verified locally.

## Affected Files

AI assistance was used for implementation review and documentation across the main application, infrastructure, testing, CI, and documentation files.

The original files under `logs/` were analyzed but not modified.

## Verification

AI suggestions were not treated as proof of correctness. Changes were verified locally using:

```bash
docker compose -p barq-assessment config -q
docker exec nginx nginx -t
python3 validate.py
python3 failure_test.py
./backup.sh
./restore.sh
git diff --check
```

Results included:

```text
Validation result: PASS (10/10)
Failure/recovery test: PASS
```

The CI workflow also passed, and the PostgreSQL backup was successfully restored and verified.

## Limitations

AI assistance was used for guidance and review only. Technical claims are based on actual configuration, command output, and test results.

Production recommendations are clearly separated from features actually implemented and verified in the assessment.
