#!/bin/bash
#
# Hydrate a test shard from the setup job's artifact.
#
# The bench (apps, venv, node_modules, sites) is already on disk at ~/frappe-bench — the
# workflow untar'd it from the artifact the setup job built. So there is NO bench init, no
# asset build, and no reinstall here: just bring the DB up and restore the dump the setup job
# baked into the bench, then start bench so tests can run. Mirrors the DB + bench-start tail of
# install.sh. The whole point is that the expensive work happened ONCE in the setup job.
#
set -e

ci_user="${ERPNEXT_CI_USER:-frappe}"
db_host="${DB_HOST:-127.0.0.1}"
dump="${CI_BASELINE_BACKUP:-/home/$ci_user/frappe-bench/test_site-db.sql.gz}"

# Re-exec as the ci user (uid 1001) so bench/cache ownership matches the artifact, same as
# install.sh. The workflow untar'd as root with -p, so the files are already owned by ci.
if [ "$(id -u)" = "0" ] && [ "${SKIP_SYSTEM_SETUP:-0}" = "1" ] && [ "$ci_user" != "root" ]; then
    exec su -m "$ci_user" -s /bin/bash -c \
        "ERPNEXT_CI_USER='$ci_user' DB_HOST='$db_host' CI_BASELINE_BACKUP='$dump' bash '$0'"
fi

cd ~/frappe-bench

# Start MariaDB in-container on the datadir baked into the artifact. The DB is already populated
# (the setup job reinstalled into this very datadir), so there is NO restore — the server just
# comes up on the existing files. This is what replaces the per-shard SQL replay.
bash ~/frappe-bench/start-db.sh

# Bring up bench (redis + web; PDF tests need the web server) and wait for redis, as install.sh.
bench start >> ~/frappe-bench/bench_start.log 2>&1 &

cfg=~/frappe-bench/sites/common_site_config.json
if [ -f "$cfg" ]; then
    ports=$(python - "$cfg" <<'PY'
import json, re, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for key in ("redis_cache", "redis_queue"):
    m = re.search(r":(\d+)", str(cfg.get(key, "")))
    if m:
        print(m.group(1))
PY
)
    for port in $ports; do
        for _ in $(seq 1 120); do
            if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then exec 3>&- 3<&-; break; fi
            sleep 1
        done
    done
fi

echo "Hydrated: bench untar'd, DB restored, bench started — ready for tests."
