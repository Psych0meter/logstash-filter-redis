#!/usr/bin/env bash
# End-to-end test in a real Logstash. Builds the gem, installs it into a
# Logstash OSS distribution, starts a throwaway Redis/Valkey, runs
# test/logstash/events.jsonl through legacy.conf (0.5.x-style options) and
# cached.conf (0.6.0 options), and checks the enriched events.
#
#   test/logstash/run.sh                        # downloads Logstash OSS into .cache/
#   LS_VERSION=9.5.4 test/logstash/run.sh       # pick the Logstash version
#   LS_HOME=/opt/logstash test/logstash/run.sh  # use an existing install
#                                               # (the plugin is installed into it!)
#
# Needs: curl, tar, ruby, redis-server/valkey-server + redis-cli/valkey-cli.
set -euo pipefail
cd "$(dirname "$0")/../.."

ls_version="${LS_VERSION:-9.5.4}"
port="${REDIS_TEST_PORT:-6391}"
server="$(command -v valkey-server || command -v redis-server || true)"
cli="$(command -v valkey-cli || command -v redis-cli || true)"
if [[ -z "$server" || -z "$cli" ]]; then
  echo "error: valkey/redis server and cli needed (e.g. sudo apt-get install -y redis-server)" >&2
  exit 1
fi
if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
  echo "error: port $port is already in use; set REDIS_TEST_PORT to a free port" >&2
  exit 1
fi

# --- Logstash -----------------------------------------------------------------
if [[ -z "${LS_HOME:-}" ]]; then
  case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) echo "error: unsupported architecture $(uname -m)" >&2; exit 1 ;;
  esac
  LS_HOME=".cache/logstash-${ls_version}"
  if [[ ! -x "$LS_HOME/bin/logstash" ]]; then
    mkdir -p .cache
    url="https://artifacts.elastic.co/downloads/logstash/logstash-oss-${ls_version}-linux-${arch}.tar.gz"
    echo "==> downloading $url"
    curl -fL --retry 3 "$url" | tar xz -C .cache
  fi
fi

# --- plugin -------------------------------------------------------------------
LS_HOME="$(cd "$LS_HOME" && pwd)"
version="$(ruby -e 'puts Gem::Specification.load("logstash-filter-redis.gemspec").version')"
gem_file="$PWD/logstash-filter-redis-${version}.gem"
echo "==> building $gem_file"
gem build logstash-filter-redis.gemspec >/dev/null
echo "==> installing into $LS_HOME"
"$LS_HOME/bin/logstash-plugin" install --no-verify "$gem_file"

# --- Redis --------------------------------------------------------------------
workdir="$(mktemp -d)"
"$server" --port "$port" --bind 127.0.0.1 --save '' --appendonly no \
  --dir "$workdir" --pidfile "$workdir/server.pid" --daemonize yes >/dev/null
cleanup() {
  if [[ -f "$workdir/server.pid" ]]; then
    kill "$(cat "$workdir/server.pid")" 2>/dev/null || true
    for _ in $(seq 50); do
      (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null || break
      sleep 0.1
    done
  fi
  rm -rf "$workdir"
}
trap cleanup EXIT
for _ in $(seq 50); do
  "$cli" -p "$port" ping >/dev/null 2>&1 && break
  sleep 0.1
done

"$cli" -p "$port" set 203.0.113.7 '{"feed":"misp","score":90}' >/dev/null
"$cli" -p "$port" hset 198.51.100.1 feed intelmq category scanner >/dev/null
"$cli" -p "$port" -n 1 hset '*curl*' tool curl >/dev/null

# --- run & check --------------------------------------------------------------
status=0
for conf in legacy cached; do
  echo "==> pipeline $conf.conf"
  rc=0
  REDIS_PORT="$port" env -u JAVA_HOME "$LS_HOME/bin/logstash" \
    --path.data "$workdir/data-$conf" --path.logs "$workdir/logs-$conf" \
    --log.level warn --pipeline.workers 2 --pipeline.batch.size 3 \
    -f "$PWD/test/logstash/$conf.conf" < test/logstash/events.jsonl > "$workdir/$conf.out" 2>&1 || rc=$?

  if [[ $rc -ne 0 ]]; then
    echo "  FAILED: logstash exited with status $rc"
    sed 's/^/    /' "$workdir/$conf.out"
    if [[ -f "$workdir/logs-$conf/logstash-plain.log" ]]; then
      echo "  logstash-plain.log (last 40 lines):"
      tail -n 40 "$workdir/logs-$conf/logstash-plain.log" | sed 's/^/    /'
    fi
    status=1
    continue
  fi

  ruby -rjson -e '
    events = File.readlines(ARGV[0]).filter_map { |l| JSON.parse(l) rescue nil }
                 .select { |e| e.is_a?(Hash) && e["id"] }.to_h { |e| [e["id"], e] }
    misp = { "feed" => "misp", "score" => 90 }
    expected = {
      1 => { "source" => misp, "user_agent" => { "tool" => "curl", "matched_pattern" => "*curl*" } },
      2 => { "source" => { "feed" => "intelmq", "category" => "scanner" } },
      3 => { "source" => "none" },
      4 => { "source" => misp },
      5 => nil
    }
    failures = expected.reject { |id, threat| events.dig(id, "threat") == threat }
    failures.each { |id, threat| warn "  event #{id}: expected threat=#{threat.inspect}, got #{events.dig(id, "threat").inspect}" }
    puts failures.empty? ? "  OK (#{events.size} events)" : "  FAILED"
    exit(failures.empty? ? 0 : 1)
  ' "$workdir/$conf.out" || { status=1; echo "  raw output:"; sed "s/^/    /" "$workdir/$conf.out"; }
done
