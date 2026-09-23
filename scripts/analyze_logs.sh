#!/usr/bin/env bash

set -u
set -o pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LOG_DIR="$BASE_DIR/logs"

ACCESS="$LOG_DIR/access.log"
APP="$LOG_DIR/application.log"
ERROR="$LOG_DIR/error.log"

TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

ACCESS_VALID="$TMP_DIR/access_valid.jsonl"
APP_VALID="$TMP_DIR/app_valid.jsonl"

ACCESS_MALFORMED="$TMP_DIR/access_malformed.txt"
APP_MALFORMED="$TMP_DIR/app_malformed.txt"

FINAL_STATUS_FILE="$TMP_DIR/final_status.tsv"
LATENCY_FILE="$TMP_DIR/latencies.txt"
TIMELINE="$TMP_DIR/timeline.tsv"

touch "$ACCESS_VALID"
touch "$APP_VALID"
touch "$ACCESS_MALFORMED"
touch "$APP_MALFORMED"


###############################################################################
# HELPERS
###############################################################################

print_header() {
    echo
    echo "### $1"
    echo "------------------------------------------------------------"
}

validate_json_log() {

    local input="$1"
    local valid="$2"
    local malformed="$3"

    local line_no=0

    while IFS= read -r line; do

        ((line_no++))

        if printf '%s\n' "$line" | jq -e . >/dev/null 2>&1; then

            printf '%s\n' "$line" >> "$valid"

        else

            printf 'line=%s\t%s\n' "$line_no" "$line" >> "$malformed"

        fi

    done < "$input"
}


###############################################################################
# 0. ENVIRONMENT CHECK
###############################################################################

print_header "0. ENVIRONMENT CHECK"

for command in jq awk sort uniq grep sed cut wc date; do

    if command -v "$command" >/dev/null 2>&1; then

        echo "PASS: $command"

    else

        echo "FAIL: $command not found"
        exit 1

    fi

done


###############################################################################
# 1. INPUT FILES
###############################################################################

print_header "1. INPUT FILES"

for file in "$ACCESS" "$APP" "$ERROR"; do

    if [[ -f "$file" ]]; then

        echo "PASS: $(basename "$file")"
        echo "  lines=$(wc -l < "$file")"

    else

        echo "FAIL: missing $file"
        exit 1

    fi

done


###############################################################################
# 2. PARSE JSON LOGS
###############################################################################

validate_json_log \
    "$ACCESS" \
    "$ACCESS_VALID" \
    "$ACCESS_MALFORMED"

validate_json_log \
    "$APP" \
    "$APP_VALID" \
    "$APP_MALFORMED"


###############################################################################
# 3. FILE COUNTS
###############################################################################

print_header "3. FILE COUNTS"

echo "access.log:"
echo "  total=$(wc -l < "$ACCESS")"
echo "  valid=$(wc -l < "$ACCESS_VALID")"
echo "  malformed=$(wc -l < "$ACCESS_MALFORMED")"

echo

echo "application.log:"
echo "  total=$(wc -l < "$APP")"
echo "  valid=$(wc -l < "$APP_VALID")"
echo "  malformed=$(wc -l < "$APP_MALFORMED")"

echo

echo "error.log:"
echo "  total=$(wc -l < "$ERROR")"


###############################################################################
# 4. MALFORMED LINES
###############################################################################

print_header "4. MALFORMED LINES"

echo "access.log:"

if [[ -s "$ACCESS_MALFORMED" ]]; then

    cat "$ACCESS_MALFORMED"

else

    echo "  none"

fi

echo

echo "application.log:"

if [[ -s "$APP_MALFORMED" ]]; then

    cat "$APP_MALFORMED"

else

    echo "  none"

fi


###############################################################################
# 5. DUPLICATE REQUEST IDS
###############################################################################

print_header "5. DUPLICATE REQUEST IDS"

echo "access.log duplicate request IDs:"

jq -r '.request_id // empty' "$ACCESS_VALID" |
    sort |
    uniq -d |
    tee "$TMP_DIR/access_duplicate_ids.txt"

ACCESS_DUPLICATE_GROUPS="$(
    jq -r '.request_id // empty' "$ACCESS_VALID" |
        sort |
        uniq -d |
        wc -l
)"

echo "duplicate groups=$ACCESS_DUPLICATE_GROUPS"

echo

echo "application.log duplicate request IDs:"

jq -r '.request_id // empty' "$APP_VALID" |
    sort |
    uniq -d |
    tee "$TMP_DIR/app_duplicate_ids.txt"

APP_DUPLICATE_GROUPS="$(
    jq -r '.request_id // empty' "$APP_VALID" |
        sort |
        uniq -d |
        wc -l
)"

echo "duplicate groups=$APP_DUPLICATE_GROUPS"


###############################################################################
# 6. UTC INTERVAL
###############################################################################

print_header "6. UTC INTERVAL"

echo "access.log:"

jq -r '.timestamp // empty' "$ACCESS_VALID" |
    sort |
    awk '
        NR == 1 {
            first=$0
        }

        {
            last=$0
        }

        END {
            print "  first=" first
            print "  last=" last
        }
    '

echo

echo "application.log:"

jq -r '.timestamp // empty' "$APP_VALID" |
    sort |
    awk '
        NR == 1 {
            first=$0
        }

        {
            last=$0
        }

        END {
            print "  first=" first
            print "  last=" last
        }
    '

echo

echo "error.log:"

ERROR_FIRST="$(
    grep -E '^[0-9]{4}/[0-9]{2}/[0-9]{2}' "$ERROR" |
        head -n 1
)"

ERROR_LAST="$(
    grep -E '^[0-9]{4}/[0-9]{2}/[0-9]{2}' "$ERROR" |
        tail -n 1
)"

echo "  first=$ERROR_FIRST"
echo "  last=$ERROR_LAST"


###############################################################################
# 7. DISTINCT CLIENT REQUESTS
###############################################################################

print_header "7. DISTINCT CLIENT REQUESTS"

ACCESS_RECORDS="$(wc -l < "$ACCESS_VALID")"

ACCESS_REQUESTS="$(
    jq -r '.request_id // empty' "$ACCESS_VALID" |
        sort -u |
        wc -l
)"

ACCESS_DUPLICATE_LINES=$((ACCESS_RECORDS - ACCESS_REQUESTS))

echo "Valid access records: $ACCESS_RECORDS"
echo "Distinct request IDs: $ACCESS_REQUESTS"
echo "Duplicate records excluded: $ACCESS_DUPLICATE_LINES"

echo

echo "Deduplication method:"
echo "  - malformed records are excluded"
echo "  - request_id is the primary request identity"
echo "  - duplicate request_id values represent the same client request"
echo "  - final outcome is determined from the latest timestamp"


###############################################################################
# 8. FINAL OUTCOME PER UNIQUE CLIENT REQUEST
###############################################################################

print_header "8. FINAL OUTCOME PER UNIQUE CLIENT REQUEST"

jq -r '
    [
        .request_id,
        .timestamp,
        (.status | tostring)
    ]
    |
    @tsv
' "$ACCESS_VALID" |
sort -k1,1 -k2,2 |
awk -F '\t' '

{
    request_id=$1
    timestamp=$2
    status=$3

    final_status[request_id]=status
    final_timestamp[request_id]=timestamp
}

END {

    for (id in final_status) {

        print id "\t" \
              final_timestamp[id] "\t" \
              final_status[id]

    }

}
' |
sort > "$FINAL_STATUS_FILE"


echo "Final status counts:"

cut -f3 "$FINAL_STATUS_FILE" |
    sort |
    uniq -c |
    sort -n


echo

echo "Total unique client requests:"

wc -l < "$FINAL_STATUS_FILE"


echo

echo "Final failed requests:"

awk -F '\t' '$3 >= 400' "$FINAL_STATUS_FILE" |
    wc -l


echo

echo "Final successful requests:"

awk -F '\t' '$3 < 400' "$FINAL_STATUS_FILE" |
    wc -l


###############################################################################
# 9. FINAL CLIENT ERROR RATE
###############################################################################

print_header "9. FINAL CLIENT ERROR RATE"

FINAL_TOTAL="$(
    wc -l < "$FINAL_STATUS_FILE"
)"

FINAL_ERRORS="$(
    awk -F '\t' '$3 >= 400' "$FINAL_STATUS_FILE" |
        wc -l
)"

FINAL_SUCCESS="$(
    awk -F '\t' '$3 < 400' "$FINAL_STATUS_FILE" |
        wc -l
)"

echo "Unique client requests: $FINAL_TOTAL"
echo "Final successful requests: $FINAL_SUCCESS"
echo "Final failed requests: $FINAL_ERRORS"

echo

if [[ "$FINAL_TOTAL" -gt 0 ]]; then

    awk \
        -v errors="$FINAL_ERRORS" \
        -v total="$FINAL_TOTAL" \
        'BEGIN {
            printf "Final client error rate: %.2f%%\n",
                   (errors / total) * 100
        }'

fi

echo

echo "Denominator:"
echo "  one final outcome per unique request_id"


###############################################################################
# 10. RAW FAILURE STATUS COUNTS
###############################################################################

print_header "10. RAW ACCESS STATUS COUNTS"

jq -r '.status // empty' "$ACCESS_VALID" |
    sort |
    uniq -c |
    sort -n


###############################################################################
# 11. FINAL FAILURE STATUS COUNTS
###############################################################################

print_header "11. FINAL FAILURE STATUS COUNTS"

awk -F '\t' '$3 >= 400 {print $3}' "$FINAL_STATUS_FILE" |
    sort |
    uniq -c |
    sort -n


###############################################################################
# 12. FAILURE PATHS
###############################################################################

print_header "12. FAILURE PATHS"

echo "Raw access failures by path:"

jq -r '
    select(.status >= 400) |
    .path
' "$ACCESS_VALID" |
    sort |
    uniq -c |
    sort -nr

echo

echo "Final failed requests by path:"

FINAL_FAILED_IDS="$TMP_DIR/final_failed_ids.txt"

awk -F '\t' '$3 >= 400 {print $1}' "$FINAL_STATUS_FILE" |
    sort -u > "$FINAL_FAILED_IDS"

while IFS= read -r id; do

    jq -r --arg id "$id" '
        select(.request_id == $id) |
        .path
    ' "$ACCESS_VALID"

done < "$FINAL_FAILED_IDS" |
sort |
uniq -c |
sort -nr


###############################################################################
# 13. FAILURE TIME WINDOWS
###############################################################################

###############################################################################
# 13. FAILURE TIME WINDOWS
###############################################################################

print_header "13. FAILURE TIME WINDOWS"

echo "Raw failures grouped by minute:"

jq -r '
    select(.status >= 400) |
    .timestamp[0:16]
' "$ACCESS_VALID" |
sort |
uniq -c |
sort -nr

echo

echo "Final failed requests grouped by minute:"

awk -F '\t' '
    $3 >= 400 {
        print substr($2, 1, 16)
    }
' "$FINAL_STATUS_FILE" |
sort |
uniq -c |
sort -nr

###############################################################################
# 14. FAILURE BACKENDS
###############################################################################

print_header "14. FAILURE BACKENDS"

echo "Raw access failures by upstream:"

jq -r '
    select(.status >= 400) |
    .upstream
' "$ACCESS_VALID" |
sort |
uniq -c |
sort -nr


###############################################################################
# 15. STATUS BY BACKEND
###############################################################################

print_header "15. STATUS BY BACKEND"

jq -r '
    [
        .upstream,
        (.status | tostring)
    ]
    |
    @tsv
' "$ACCESS_VALID" |
sort |
uniq -c |
sort -nr


###############################################################################
# 16. APPLICATION INSTANCES
###############################################################################

print_header "16. APPLICATION INSTANCES"

jq -r '.instance_id // empty' "$APP_VALID" |
    sort |
    uniq -c |
    sort -nr


###############################################################################
# 17. CLIENT LATENCY
###############################################################################

print_header "17. CLIENT LATENCY"

jq -r '
    select(.request_time != null) |
    .request_time
' "$ACCESS_VALID" |
awk '{print $1 * 1000}' |
sort -n > "$LATENCY_FILE"

LATENCY_COUNT="$(wc -l < "$LATENCY_FILE")"

echo "Samples: $LATENCY_COUNT"

if [[ "$LATENCY_COUNT" -gt 0 ]]; then

    MEDIAN="$(
        awk '
            {
                a[NR]=$1
            }

            END {

                if (NR % 2 == 1)

                    print a[(NR+1)/2]

                else

                    print (a[NR/2] + a[NR/2+1]) / 2
            }
        ' "$LATENCY_FILE"
    )"


    P95="$(
        awk '
            {
                a[NR]=$1
            }

            END {

                pos=(NR-1)*0.95+1

                lower=int(pos)
                upper=lower+1

                if (upper > NR)
                    upper=NR

                fraction=pos-lower

                print a[lower] + \
                      (a[upper]-a[lower])*fraction
            }
        ' "$LATENCY_FILE"
    )"


    printf "Median: %.3f ms\n" "$MEDIAN"
    printf "P95: %.3f ms\n" "$P95"

    echo "Percentile method: linear interpolation"
    echo "Source: access.log request_time"
    echo "Unit: milliseconds"

fi


###############################################################################
# 18. UPSTREAM ATTEMPTS / RETRIES
###############################################################################

print_header "18. UPSTREAM ATTEMPTS / RETRIES"

echo "Requests with multiple upstream attempts:"

jq -r '
    select(.upstream != null) |
    [
        .request_id,
        .timestamp,
        (.status | tostring),
        .upstream,
        (.upstream_status // "")
    ]
    |
    @tsv
' "$ACCESS_VALID" |
awk -F '\t' '$4 ~ /,/ {
    print
}'


RETRY_COUNT="$(
    jq -r '
        select(.upstream != null) |
        .upstream
    ' "$ACCESS_VALID" |
    awk 'index($0,",") > 0' |
    wc -l
)"

echo

echo "Requests containing multiple upstream attempts: $RETRY_COUNT"


echo

echo "Retry outcomes:"

jq -r '
    select(
        .upstream != null
        and (.upstream | contains(","))
    ) |

    [
        .request_id,
        .timestamp,
        (.status | tostring),
        .upstream,
        (.upstream_status // "")
    ]
    |
    @tsv
' "$ACCESS_VALID"


echo

echo "Retries that eventually succeeded:"

jq -r '
    select(
        .upstream != null
        and (.upstream | contains(","))
        and .status < 400
    ) |

    [
        .request_id,
        .timestamp,
        (.status | tostring),
        .upstream,
        (.upstream_status // "")
    ]
    |
    @tsv
' "$ACCESS_VALID" |
tee "$TMP_DIR/retry_successes.tsv"

RETRY_SUCCESS_COUNT="$(
    jq -r '
        select(
            .upstream != null
            and (.upstream | contains(","))
            and .status < 400
        )
        |
        .request_id
    ' "$ACCESS_VALID" |
    sort -u |
    wc -l
)"

echo

echo "Retry requests that eventually succeeded: $RETRY_SUCCESS_COUNT"


###############################################################################
# 19. NGINX ERROR TYPES
###############################################################################

print_header "19. NGINX ERROR TYPES"

CONNECTION_REFUSED="$(
    grep -ci "connection refused" "$ERROR"
)"

TIMEOUT_ERRORS="$(
    grep -Eic "timed out|timeout" "$ERROR"
)"

OTHER_ERRORS="$(
    grep -Eiv \
        "connection refused|timed out|timeout" \
        "$ERROR" |
    grep -c "\[error\]" || true
)"

echo "Connection refused log lines: $CONNECTION_REFUSED"
echo "Timeout log lines: $TIMEOUT_ERRORS"
echo "Other NGINX error lines: $OTHER_ERRORS"


###############################################################################
# 20. FAILED REQUEST IDS
###############################################################################

print_header "20. FINAL FAILED REQUEST IDS"

cat "$FINAL_FAILED_IDS"


###############################################################################
# 21. NGINX ERROR REQUEST IDS
###############################################################################

print_header "21. NGINX ERROR REQUEST IDS"

ERROR_IDS="$TMP_DIR/error_ids.txt"

grep -oE 'request_id=[A-Za-z0-9._-]+' "$ERROR" |
    cut -d= -f2 |
    sort -u > "$ERROR_IDS"

cat "$ERROR_IDS"


###############################################################################
# 22. CORRELATED FAILED REQUESTS
###############################################################################

print_header "22. CORRELATED FAILED REQUESTS"

echo "Showing selected final failures for evidence."

SELECTED_FAILED_IDS="$TMP_DIR/selected_failed_ids.txt"

head -n 10 "$FINAL_FAILED_IDS" > "$SELECTED_FAILED_IDS"

while IFS= read -r id; do

    echo
    echo "============================================================"
    echo "REQUEST_ID=$id"
    echo "============================================================"

    echo
    echo "ACCESS:"

    jq -c --arg id "$id" '
        select(.request_id == $id)
    ' "$ACCESS_VALID"


    echo
    echo "APPLICATION:"

    jq -c --arg id "$id" '
        select(.request_id == $id)
    ' "$APP_VALID" || true


    echo
    echo "NGINX ERROR:"

    grep "request_id=$id" "$ERROR" || true

done < "$SELECTED_FAILED_IDS"


###############################################################################
# 23. CORRELATED SUCCESSFUL REQUESTS
###############################################################################

print_header "23. CORRELATED SUCCESSFUL REQUESTS"

SUCCESS_IDS="$TMP_DIR/success_ids.txt"

awk -F '\t' '$3 < 400 {print $1}' "$FINAL_STATUS_FILE" |
    head -n 5 > "$SUCCESS_IDS"


while IFS= read -r id; do

    echo
    echo "============================================================"
    echo "REQUEST_ID=$id"
    echo "============================================================"

    echo
    echo "ACCESS:"

    jq -c --arg id "$id" '
        select(.request_id == $id)
    ' "$ACCESS_VALID"


    echo
    echo "APPLICATION:"

    jq -c --arg id "$id" '
        select(.request_id == $id)
    ' "$APP_VALID" || true


    echo
    echo "NGINX ERROR:"

    grep "request_id=$id" "$ERROR" || true

done < "$SUCCESS_IDS"


###############################################################################
# 24. INCIDENT TIMELINE
###############################################################################

print_header "24. INCIDENT TIMELINE"

: > "$TIMELINE"


###############################################################################
# ACCESS FAILURES
###############################################################################

jq -r '
    select(.status >= 400) |

    [
        .timestamp,
        "ACCESS",
        .request_id,
        .path,
        (.status | tostring),
        (.upstream // ""),
        (.upstream_status // "")
    ]

    |
    @tsv
' "$ACCESS_VALID" >> "$TIMELINE"


###############################################################################
# APPLICATION FAILURES
###############################################################################

jq -r '
    select(.status >= 400) |

    [
        .timestamp,
        "APP",
        .request_id,
        .path,
        (.status | tostring),
        (.instance_id // ""),
        ""
    ]

    |
    @tsv
' "$APP_VALID" >> "$TIMELINE"


###############################################################################
# NGINX ERRORS
###############################################################################

while IFS= read -r line; do

    timestamp="$(
        printf '%s\n' "$line" |
        awk '{print $1 " " $2}'
    )"

    request_id="$(
        printf '%s\n' "$line" |
        grep -oE 'request_id=[A-Za-z0-9._-]+' |
        cut -d= -f2
    )"

    printf '%s\tERROR\t%s\t\t\t%s\n' \
        "$timestamp" \
        "${request_id:-unknown}" \
        "$line" >> "$TIMELINE"

done < "$ERROR"


sort "$TIMELINE"


###############################################################################
# 25. CONNECTION REFUSED TIMELINE
###############################################################################

print_header "25. CONNECTION REFUSED TIMELINE"

grep -i "connection refused" "$ERROR" || true


###############################################################################
# 26. TIMEOUT TIMELINE
###############################################################################

print_header "26. TIMEOUT TIMELINE"

grep -Ei "timed out|timeout" "$ERROR" || true


###############################################################################
# 27. REQUEST CORRELATION SUMMARY
###############################################################################

print_header "27. REQUEST CORRELATION SUMMARY"

ERROR_MATCHES=0
ERROR_WITH_ACCESS=0
ERROR_WITH_APP=0

while IFS= read -r id; do

    [[ -z "$id" ]] && continue

    ((ERROR_MATCHES++))


    if jq -e --arg id "$id" '
        select(.request_id == $id)
    ' "$ACCESS_VALID" >/dev/null 2>&1; then

        ((ERROR_WITH_ACCESS++))

    fi


    if jq -e --arg id "$id" '
        select(.request_id == $id)
    ' "$APP_VALID" >/dev/null 2>&1; then

        ((ERROR_WITH_APP++))

    fi

done < "$ERROR_IDS"


echo "Distinct request IDs in NGINX error.log: $ERROR_MATCHES"
echo "NGINX error IDs found in access.log: $ERROR_WITH_ACCESS"
echo "NGINX error IDs found in application.log: $ERROR_WITH_APP"


###############################################################################
# 28. IMPORTANT ANALYSIS NOTES
###############################################################################

print_header "28. ANALYSIS NOTES"

echo "1. access.log and application.log malformed records were excluded."
echo "2. Original log files were not modified."
echo "3. request_id is used as the primary client-request identity."
echo "4. Duplicate request IDs are not counted as separate client requests."
echo "5. Final client outcome is the latest timestamp for each request_id."
echo "6. Comma-separated upstream values represent multiple upstream attempts."
echo "7. A retry may produce an NGINX error while the final client request succeeds."
echo "8. NGINX connection refused proves upstream connection failure at that moment."
echo "9. NGINX timeout proves the proxy waited without receiving the expected response."
echo "10. Logs alone do not prove the underlying application/container cause."


###############################################################################
# 29. RAW EVIDENCE FILES
###############################################################################

print_header "29. RAW EVIDENCE FILES"

echo "Valid access records:"
echo "  $ACCESS_VALID"

echo

echo "Valid application records:"
echo "  $APP_VALID"

echo

echo "Malformed access records:"
echo "  $ACCESS_MALFORMED"

echo

echo "Malformed application records:"
echo "  $APP_MALFORMED"

echo

echo "Final request outcomes:"
echo "  $FINAL_STATUS_FILE"

echo

echo "Retry successes:"
echo "  $TMP_DIR/retry_successes.tsv"

echo

echo "Timeline:"
echo "  $TIMELINE"


###############################################################################
# COMPLETE
###############################################################################

echo
echo "============================================================"
echo "ANALYSIS COMPLETE"
echo "============================================================"