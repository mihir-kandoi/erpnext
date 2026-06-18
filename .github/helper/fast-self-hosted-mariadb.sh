#!/usr/bin/env bash
set -euo pipefail

CACHE_ROOT="$HOME/frappe-ci-cache/${RUNNER_NAME}/mariadb"
BENCH="$CACHE_ROOT/frappe-bench"
FRAPPE_REPO="$CACHE_ROOT/frappe"
SNAPSHOT="$CACHE_ROOT/test_site.sql.gz"
DEPS_HASH_FILE="$CACHE_ROOT/deps.hash"
LOCK="$CACHE_ROOT.lock"

mkdir -p "$CACHE_ROOT"
exec 9>"$LOCK"
flock 9

mysql_root() {
	mariadb -h 127.0.0.1 -P "$DB_PORT" -uroot -proot "$@"
}

reset_db() {
	mysql_root -e "DROP DATABASE IF EXISTS test_frappe"
	mysql_root -e "DROP USER IF EXISTS 'test_frappe'@'%'"
	mysql_root -e "CREATE DATABASE test_frappe CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
	mysql_root -e "CREATE USER 'test_frappe'@'%' IDENTIFIED BY 'test_frappe'"
	mysql_root -e "GRANT ALL PRIVILEGES ON test_frappe.* TO 'test_frappe'@'%'"
	mysql_root -e "FLUSH PRIVILEGES"
}

write_site_config() {
	mkdir -p "$BENCH/sites/test_site"
	cat > "$BENCH/sites/test_site/site_config.json" <<EOF
{
 "db_host": "127.0.0.1",
 "db_port": $DB_PORT,
 "db_name": "test_frappe",
 "db_password": "test_frappe",
 "admin_password": "admin",
 "use_mysqlclient": 1,
 "root_login": "root",
 "root_password": "root",
 "host_name": "http://test_site:8000",
 "install_apps": ["payments", "erpnext"],
 "throttle_user_limit": 100
}
EOF
}

current_deps_hash() {
	{
		git -C "$BENCH/apps/frappe" rev-parse HEAD
		git -C "$BENCH/apps/payments" rev-parse HEAD
		git -C "$BENCH/apps/erpnext" rev-parse HEAD
		find "$BENCH/apps" -maxdepth 3 -type f \( \
			-name "pyproject.toml" -o \
			-name "requirements*.txt" -o \
			-name "package.json" -o \
			-name "yarn.lock" \
		\) -print0 | sort -z | xargs -0 sha256sum
	} | sha256sum | awk '{ print $1 }'
}

ensure_requirements() {
	local new_hash old_hash
	new_hash="$(current_deps_hash)"
	old_hash=""
	if [ -f "$DEPS_HASH_FILE" ]; then
		old_hash="$(cat "$DEPS_HASH_FILE")"
	fi

	if [ "$new_hash" != "$old_hash" ]; then
		bench setup requirements --dev
		echo "$new_hash" > "$DEPS_HASH_FILE"
	fi
}

ensure_bench() {
	if [ -d "$BENCH" ]; then
		return
	fi

	python -m pip install --upgrade pip frappe-bench
	git clone --depth 1 --branch "$FRAPPE_BRANCH" https://github.com/frappe/frappe "$FRAPPE_REPO"
	bench init --skip-assets --frappe-path "$FRAPPE_REPO" --python "$(command -v python)" "$BENCH"

	cd "$BENCH"
	bench get-app --skip-assets payments --branch develop
	bench get-app --skip-assets erpnext https://github.com/frappe/erpnext --branch develop

	bench set-config -g redis_cache "redis://127.0.0.1:$REDIS_CACHE_PORT"
	bench set-config -g redis_queue "redis://127.0.0.1:$REDIS_QUEUE_PORT"
	bench set-config -g redis_socketio "redis://127.0.0.1:$REDIS_CACHE_PORT"

	sed -i \
		-e 's/watch:/# watch:/g' \
		-e 's/schedule:/# schedule:/g' \
		-e 's/socketio:/# socketio:/g' \
		-e 's/redis_cache:/# redis_cache:/g' \
		-e 's/redis_queue:/# redis_queue:/g' \
		-e 's/redis_socketio:/# redis_socketio:/g' \
		Procfile

	ensure_requirements
	CI=Yes bench build --app frappe
}

refresh_base_apps() {
	git -C "$BENCH/apps/frappe" fetch origin "$FRAPPE_BRANCH" --depth 1
	git -C "$BENCH/apps/frappe" checkout -f FETCH_HEAD
	git -C "$BENCH/apps/frappe" clean -fdx

	git -C "$BENCH/apps/payments" fetch origin develop --depth 1
	git -C "$BENCH/apps/payments" checkout -f FETCH_HEAD
	git -C "$BENCH/apps/payments" clean -fdx
}

ensure_snapshot() {
	if [ -f "$SNAPSHOT" ]; then
		return
	fi

	git -C "$BENCH/apps/erpnext" fetch origin develop --depth 1
	git -C "$BENCH/apps/erpnext" checkout -f FETCH_HEAD
	git -C "$BENCH/apps/erpnext" clean -fdx

	ensure_requirements
	reset_db
	rm -rf "$BENCH/sites/test_site"

	bench new-site test_site \
		--db-type mariadb \
		--db-host 127.0.0.1 \
		--db-port "$DB_PORT" \
		--db-root-username root \
		--db-root-password root \
		--admin-password admin \
		--mariadb-user-host-login-scope="%" \
		--install-app payments \
		--install-app erpnext

	mariadb-dump -h 127.0.0.1 -P "$DB_PORT" -uroot -proot test_frappe | gzip > "$SNAPSHOT.tmp"
	mv "$SNAPSHOT.tmp" "$SNAPSHOT"
}

ensure_bench
cd "$BENCH"

refresh_base_apps
ensure_snapshot

git -C "$BENCH/apps/erpnext" fetch "$ERPNEXT_REPO_URL" "$ERPNEXT_SHA" --depth 1
git -C "$BENCH/apps/erpnext" checkout -f FETCH_HEAD
git -C "$BENCH/apps/erpnext" clean -fdx

"$BENCH/env/bin/python" -m compileall -fq "$BENCH/apps/erpnext"
if grep -lr --exclude-dir=node_modules "^<<<<<<< " "$BENCH/apps/erpnext"; then
	echo "Found merge conflicts"
	exit 1
fi

ensure_requirements
reset_db
write_site_config
gzip -dc "$SNAPSHOT" | mariadb -h 127.0.0.1 -P "$DB_PORT" -uroot -proot test_frappe

bench set-config -g redis_cache "redis://127.0.0.1:$REDIS_CACHE_PORT"
bench set-config -g redis_queue "redis://127.0.0.1:$REDIS_QUEUE_PORT"
bench set-config -g redis_socketio "redis://127.0.0.1:$REDIS_CACHE_PORT"

bench --site test_site migrate
