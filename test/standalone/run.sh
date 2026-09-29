#!/usr/bin/env bash
# Runs the standalone test suite (MRI Ruby, no Logstash needed) against a
# throwaway Redis/Valkey server started and stopped by this script.
#
#   test/standalone/run.sh                      # whole suite
#   test/standalone/run.sh -n /cache/           # only tests matching /cache/
#
# Needs: ruby >= 3.0, redis-server or valkey-server on PATH, and the redis gem
# 4.x (installed automatically if missing). REDIS_TEST_PORT overrides the
# port (default 6390); it must be free.
set -euo pipefail
cd "$(dirname "$0")/../.."

port="${REDIS_TEST_PORT:-6390}"
server="$(command -v valkey-server || command -v redis-server || true)"
if [[ -z "$server" ]]; then
  echo "error: no valkey-server/redis-server on PATH (e.g. sudo apt-get install -y redis-server)" >&2
  exit 1
fi
if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
  echo "error: port $port is already in use; set REDIS_TEST_PORT to a free port" >&2
  exit 1
fi

if ! ruby -e 'begin; gem "redis", ">= 4.0.1", "< 5"; rescue Gem::LoadError; end; require "redis"; exit(Redis::VERSION < "5" ? 0 : 1)' 2>/dev/null; then
  echo "installing the redis gem 4.x ..."
  gem install --no-document redis -v '~> 4.8'
fi

workdir="$(mktemp -d)"
"$server" --port "$port" --bind 127.0.0.1 --save '' --appendonly no \
  --dir "$workdir" --pidfile "$workdir/server.pid" --daemonize yes >/dev/null
cleanup() {
  if [[ -f "$workdir/server.pid" ]]; then
    kill "$(cat "$workdir/server.pid")" 2>/dev/null || true
    for _ in $(seq 50); do # wait until the port is released
      (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null || break
      sleep 0.1
    done
  fi
  rm -rf "$workdir"
}
trap cleanup EXIT

for _ in $(seq 50); do
  (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break
  sleep 0.1
done

REDIS_TEST_PORT="$port" REDIS_TEST_FLUSH=1 ruby test/standalone/redis_filter_test.rb "$@"
