#!/usr/bin/env bash
# table-size-report.sh — where is your MySQL disk space going?
#
# Prints a per-table breakdown (data size, index size, total, % of DB,
# fragmentation from DATA_FREE) for one database or all of them, plus a
# totals line. Perfect before a cleanup run, a migration, or when /var/lib/mysql
# is suddenly full.
#
# Reads credentials the safe way: from ~/.my.cnf [client] (user/password),
# never from the command line (which leaks into `ps` output).
#
#   table-size-report.sh --database wordpress --top 20
#   table-size-report.sh --all --sort index --min-size 10M --json
#
# Exit codes: 0 ok, 1 usage/config error, 2 mysql connection/query failed.

set -u

DB=""
ALL=0
TOP=25
MIN_SIZE_MB=0
SORT="size"      # size | index | frag
JSON=0

usage() {
    cat <<'EOF'
Usage: table-size-report.sh [options]

  --database NAME   Report on one database (default: all non-system DBs)
  --all             Report on every non-system database
  --top N           Show top N tables per database (default: 25, 0 = all)
  --min-size SIZE   Skip tables smaller than SIZE (e.g. 10M, 500K, 2G)
  --sort KEY        Order tables by: size (default), index, frag (fragmentation)
  --json            Machine-readable JSON output
  -h, --help        This help

Credentials: put user/password in ~/.my.cnf under [client], chmod 600.
EOF
    exit "${1:-0}"
}

to_mb() { # "10M" / "500K" / "2G" / "1024" -> MB (float)
    local v="${1^^}"
    case "$v" in
        *G) awk -v n="${v%G}" 'BEGIN{print n*1024}' ;;
        *M) awk -v n="${v%M}" 'BEGIN{print n+0}' ;;
        *K) awk -v n="${v%K}" 'BEGIN{print n/1024}' ;;
        *)  awk -v n="$v"      'BEGIN{print n/1024/1024}' ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --database) DB="$2"; shift 2 ;;
        --all)      ALL=1; shift ;;
        --top)      TOP="$2"; shift 2 ;;
        --min-size) MIN_SIZE_MB="$(to_mb "$2")"; shift 2 ;;
        --sort)     SORT="$2"; shift 2 ;;
        --json)     JSON=1; shift ;;
        -h|--help)  usage 0 ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

case "$SORT" in
    size)  ORDER="total_mb DESC" ;;
    index) ORDER="index_mb DESC" ;;
    frag)  ORDER="frag_mb DESC" ;;
    *) echo "Invalid --sort: $SORT (size|index|frag)" >&2; exit 1 ;;
esac

[[ "$TOP" =~ ^[0-9]+$ ]] || { echo "--top must be a number" >&2; exit 1; }

command -v mysql >/dev/null || { echo "mysql client not found in PATH" >&2; exit 1; }

# Connection smoke test first — friendlier error than a SQL trace.
if ! mysql --batch --skip-column-names -e "SELECT 1" >/dev/null 2>/tmp/tsr.err; then
    echo "Cannot connect to MySQL. Check ~/.my.cnf [client] credentials." >&2
    head -3 /tmp/tsr.err >&2
    exit 2
fi

# Database list: explicit, or everything except system schemas.
if [[ -n "$DB" ]]; then
    DBS="$DB"
elif [[ $ALL -eq 1 ]]; then
    DBS=$(mysql --batch --skip-column-names -e \
        "SELECT schema_name FROM information_schema.schemata
          WHERE schema_name NOT IN ('information_schema','performance_schema','mysql','sys')")
else
    DBS=$(mysql --batch --skip-column-names -e \
        "SELECT schema_name FROM information_schema.schemata
          WHERE schema_name NOT IN ('information_schema','performance_schema','mysql','sys')")
fi

QUERY="SELECT table_name,
       ROUND(data_length/1024/1024, 2)  AS data_mb,
       ROUND(index_length/1024/1024, 2) AS index_mb,
       ROUND((data_length+index_length)/1024/1024, 2) AS total_mb,
       ROUND(data_free/1024/1024, 2)   AS frag_mb,
       table_rows
FROM information_schema.tables
WHERE table_schema='%s' AND table_type='BASE TABLE'
  AND (data_length+index_length)/1024/1024 >= %s
ORDER BY %s"

run_for_db() {
    local db="$1"
    local q
    # shellcheck disable=SC2059
    q=$(printf "$QUERY" "$db" "$MIN_SIZE_MB" "$ORDER")
    [[ "$TOP" -gt 0 ]] && q="$q LIMIT $TOP"
    mysql --batch --skip-column-names -e "$q" 2>/tmp/tsr.err || {
        echo "Query failed for database '$db':" >&2; cat /tmp/tsr.err >&2; exit 2
    }
}

if [[ $JSON -eq 1 ]]; then
    echo -n '{"databases":{'
    first_db=1
    grand_total=0
    for db in $DBS; do
        [[ $first_db -eq 0 ]] && echo -n ','
        first_db=0
        echo -n "\"$db\":["
        first_row=1
        while IFS=$'\t' read -r t d i tot frag rows; do
            [[ $first_row -eq 0 ]] && echo -n ','
            first_row=0
            printf '{"table":"%s","data_mb":%s,"index_mb":%s,"total_mb":%s,"frag_mb":%s,"rows":"%s"}' \
                "$t" "$d" "$i" "$tot" "$frag" "$rows"
            grand_total=$(awk -v g="$grand_total" -v t="$tot" 'BEGIN{print g+t}')
        done < <(run_for_db "$db")
        echo -n ']'
    done
    printf '},"grand_total_mb":%.2f}\n' "$grand_total"
    exit 0
fi

# ---- human-readable output ----
printf '%-40s %10s %10s %10s %8s %10s %12s\n' "TABLE" "DATA" "INDEX" "TOTAL" "%DB" "FRAG" "ROWS"
printf '%-40s %10s %10s %10s %8s %10s %12s\n' "$(printf '%.0s-' {1..40})" \
    "$(printf '%.0s-' {1..10})" "$(printf '%.0s-' {1..10})" "$(printf '%.0s-' {1..10})" \
    "$(printf '%.0s-' {1..8})" "$(printf '%.0s-' {1..10})" "$(printf '%.0s-' {1..12})"

grand_total=0
for db in $DBS; do
    echo "== $db =="
    db_total=$(mysql --batch --skip-column-names -e \
        "SELECT ROUND(SUM(data_length+index_length)/1024/1024,2)
         FROM information_schema.tables WHERE table_schema='$db'" 2>/dev/null)
    db_total=${db_total:-0}
    while IFS=$'\t' read -r t d i tot frag rows; do
        pct=$(awk -v t="$tot" -v db="$db_total" 'BEGIN{printf "%.1f", (db>0? t/db*100 : 0)}')
        frag_note=""
        # Flag fragmentation worth an OPTIMIZE TABLE (>= 50MB free or >= 30% of table).
        if awk -v f="$frag" -v t="$tot" 'BEGIN{exit !(f>=50 || (t>0 && f/t>=0.30))}'; then
            frag_note="  <-- OPTIMIZE?"
        fi
        printf '%-40s %9sM %9sM %9sM %7s%% %9sM %12s%s\n' \
            "${t:0:40}" "$d" "$i" "$tot" "$pct" "$frag" "$rows" "$frag_note"
        grand_total=$(awk -v g="$grand_total" -v t="$tot" 'BEGIN{print g+t}')
    done < <(run_for_db "$db")
    echo
done

printf 'Grand total across reported databases: %.2f MB\n' "$grand_total"
