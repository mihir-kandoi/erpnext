#!/bin/bash

set -e

cd ~ || exit

githubbranch=${GITHUB_BASE_REF:-${GITHUB_REF##*/}}
frappeuser=${FRAPPE_USER:-"frappe"}
frappecommitish=${FRAPPE_BRANCH:-$githubbranch}
db_host=${DB_HOST:-"127.0.0.1"}
db_user_host=${DB_USER_HOST:-"localhost"}
wkhtmltox_deb=${WKHTMLTOX_DEB:-"/tmp/wkhtmltox.deb"}
bench_cache_dir=${BENCH_CACHE_DIR:-}

# ---------------------------------------------------------------------------
# Phase 1 — parallelise the three slow, independent setup steps:
#   a) system packages   b) frappe-bench pip install   c) frappe git fetch
# ---------------------------------------------------------------------------

if [ "${SKIP_SYSTEM_SETUP:-0}" != "1" ]; then
    sudo apt-get update

    # apt remove/install must run sequentially but can overlap with pip and git.
    sudo apt-get remove -y mysql-server mysql-client
    sudo apt-get install -y libcups2-dev redis-server mariadb-client libmariadb-dev &
    apt_pid=$!

    pip install frappe-bench &
    pip_pid=$!
else
    apt_pid=
    pip_pid=
fi

mkdir frappe
(
  cd frappe
  git init
  git remote add origin "https://github.com/${frappeuser}/frappe"
  git fetch origin "${frappecommitish}" --depth 1
) &
clone_pid=$!

if [ -n "$apt_pid" ]; then wait $apt_pid; fi
if [ -n "$pip_pid" ]; then wait $pip_pid; fi
wait $clone_pid

pushd frappe
git checkout FETCH_HEAD
popd
frappe_sha=$(git -C frappe rev-parse HEAD)

get_bench_cache_archive() {
    if [ -z "$bench_cache_dir" ]; then
        return
    fi

    mkdir -p "$bench_cache_dir"

    local cache_key
    cache_key=$(
        {
            echo "frappe:${frappe_sha}"
            uname -m
            python --version
            node --version
            bench --version
        } | sha256sum | awk '{print $1}'
    )

    echo "${bench_cache_dir}/frappe-bench-${cache_key}.tar.zst"
}

restore_warm_bench() {
    bench_cache_archive=$(get_bench_cache_archive)
    if [ -n "$bench_cache_archive" ] && [ -f "$bench_cache_archive" ]; then
        echo "Restoring warm bench from ${bench_cache_archive}"
        tar --use-compress-program=unzstd -xf "$bench_cache_archive" -C ~
        return 0
    fi

    return 1
}

save_warm_bench() {
    if [ -z "${bench_cache_archive:-}" ] || [ -f "$bench_cache_archive" ]; then
        return
    fi

    local tmp_archive
    tmp_archive="${bench_cache_archive}.${$}.tmp"

    echo "Saving warm bench to ${bench_cache_archive}"
    tar \
        --use-compress-program="zstd -T0 -3" \
        --exclude="frappe-bench/logs" \
        --exclude="frappe-bench/sites" \
        -cf "$tmp_archive" \
        -C ~ frappe-bench
    mv "$tmp_archive" "$bench_cache_archive"
}

# ---------------------------------------------------------------------------
# Phase 2 — bench init and site setup
# ---------------------------------------------------------------------------

install_whktml() {
    # Re-use the .deb if the wkhtmltopdf cache step already restored it.
    if [ ! -f "$wkhtmltox_deb" ]; then
        wget -O "$wkhtmltox_deb" https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb
    fi
    sudo apt-get install -y "$wkhtmltox_deb"
}
if [ "${SKIP_WKHTMLTOX_SETUP:-0}" != "1" ]; then
    install_whktml &
    wkpid=$!
else
    wkpid=
fi

if ! restore_warm_bench; then
    bench init --skip-assets --frappe-path ~/frappe --python "$(which python)" frappe-bench

    cd ~/frappe-bench || exit

    sed -i 's/watch:/# watch:/g' Procfile
    sed -i 's/schedule:/# schedule:/g' Procfile
    sed -i 's/socketio:/# socketio:/g' Procfile
    sed -i 's/redis_socketio:/# redis_socketio:/g' Procfile

    CI=Yes bench build --app frappe
    save_warm_bench
fi

if [ -n "$wkpid" ]; then wait $wkpid; fi

mkdir ~/frappe-bench/sites/test_site

if [ "$DB" == "mariadb" ];then
    cp -r "${GITHUB_WORKSPACE}/.github/helper/site_config_mariadb.json" ~/frappe-bench/sites/test_site/site_config.json
    if [ "$db_host" != "127.0.0.1" ]; then
        sed -i "s/\"db_host\": \"127.0.0.1\"/\"db_host\": \"${db_host}\"/" ~/frappe-bench/sites/test_site/site_config.json
    fi
else
    cp -r "${GITHUB_WORKSPACE}/.github/helper/site_config_postgres.json" ~/frappe-bench/sites/test_site/site_config.json
fi


if [ "$DB" == "mariadb" ];then
    mariadb --host "$db_host" --port 3306 -u root -proot -e "SET GLOBAL character_set_server = 'utf8mb4'"
    mariadb --host "$db_host" --port 3306 -u root -proot -e "SET GLOBAL collation_server = 'utf8mb4_unicode_ci'"

    # Belt-and-suspenders: also set performance variables at runtime in case
    # MARIADB_EXTRA_FLAGS was not honoured by the container image.
    mariadb --host "$db_host" --port 3306 -u root -proot \
        -e "SET GLOBAL innodb_flush_log_at_trx_commit=0; SET GLOBAL sync_binlog=0;"

    mariadb --host "$db_host" --port 3306 -u root -proot -e "CREATE USER 'test_frappe'@'${db_user_host}' IDENTIFIED BY 'test_frappe'"
    mariadb --host "$db_host" --port 3306 -u root -proot -e "CREATE DATABASE test_frappe"
    mariadb --host "$db_host" --port 3306 -u root -proot -e "GRANT ALL PRIVILEGES ON \`test_frappe\`.* TO 'test_frappe'@'${db_user_host}'"

    mariadb --host "$db_host" --port 3306 -u root -proot -e "FLUSH PRIVILEGES"
fi

if [ "$DB" == "postgres" ];then
    echo "travis" | psql -h 127.0.0.1 -p 5432 -c "CREATE DATABASE test_frappe" -U postgres;
    echo "travis" | psql -h 127.0.0.1 -p 5432 -c "CREATE USER test_frappe WITH PASSWORD 'test_frappe'" -U postgres;
fi

cd ~/frappe-bench || exit

bench get-app payments --branch develop
bench get-app erpnext "${GITHUB_WORKSPACE}"

if [ "$TYPE" == "server" ]; then bench setup requirements --dev; fi

bench start >> ~/frappe-bench/bench_start.log 2>&1 &
bench --site test_site reinstall --yes
