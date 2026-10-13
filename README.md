# mysql-table-size-report

One script that answers **"where is my MySQL disk space going?"** — per-table data size, index size, % of database, and fragmentation (from `DATA_FREE`), with automatic `OPTIMIZE TABLE` hints.

## Quick start

```bash
chmod +x table-size-report.sh
./table-size-report.sh --database wordpress --top 20
```

Output:

```
TABLE                                       DATA      INDEX      TOTAL      %DB       FRAG         ROWS
---------------------------------------- ---------- ---------- ---------- -------- ---------- ------------
wp_postmeta                                812.45M    301.20M   1113.65M     61.2%    210.30M      1842032  <-- OPTIMIZE?
...
== wordpress ==
Grand total across reported databases: 1820.44 MB
```

## Options

| Flag | Purpose |
|---|---|
| `--database NAME` | Report on one database (default: all non-system DBs) |
| `--all` | Explicitly scan every non-system database |
| `--top N` | Top N tables per database (default 25, `0` = all) |
| `--min-size SIZE` | Skip tables under SIZE (`10M`, `500K`, `2G`) |
| `--sort KEY` | Order by `size` (default), `index`, or `frag` (fragmentation) |
| `--json` | Machine-readable output for monitoring/Zabbix |

## Why it's useful

- **Finds bloat fast** — autoloaded options tables, `wp_postmeta` explosions, and log tables jump out immediately.
- **Flags fragmentation** — tables with ≥50MB free or ≥30% free space get an `OPTIMIZE?` hint.
- **Safe credentials** — reads `~/.my.cnf` `[client]`, never puts passwords on the command line (`chmod 600 ~/.my.cnf`).

Typical follow-up after this report: truncate/purge the offending tables, then `OPTIMIZE TABLE` the flagged ones during a maintenance window (it locks the table on most engines).

Requires the `mysql` client. MIT licensed.
