# logstash-filter-redis

A [Logstash](https://github.com/elastic/logstash) filter plugin that enriches
events with values looked up in Redis or Valkey. The value of an event field is
used as the key, or matched against wildcard patterns stored as keys.

Licensed under the Apache 2.0 License.

## Features

- Looks up `string`, `hash`, `list`, `set` and `zset` values; JSON strings are
  parsed into objects.
- Wildcard pattern matching against pattern keys (`*curl*`, `Mozilla*`), with
  an optional key prefix.
- Fallback value when a key is missing or Redis is unreachable.
- Override or append to the destination field.
- **Batch-level lookups**: the keys of a whole pipeline batch are
  de-duplicated and fetched with pipelined commands, so a batch costs one or
  two network round trips instead of one or two per event.
- **One connection per pipeline worker**: workers don't wait on each other.
- **Optional local cache**, including caching of misses.

## Installation

```sh
bin/logstash-plugin install logstash-filter-redis
# or, from a built gem file:
bin/logstash-plugin install --no-verify /path/to/logstash-filter-redis-0.6.0.gem
```

### Upgrading from 0.5.x

0.6.0 is a drop-in upgrade: existing configurations keep working without any
change and produce the same events. The standalone test suite checks this
against the output of 0.5.1 for a matrix of configurations. Batching and
per-worker connections apply automatically; caching and `data_type` are
opt-in. See [CHANGELOG.md](CHANGELOG.md) for the full list of changes.

## Configuration options

| Setting | Type | Default | Description |
|---|---|---|---|
| `host` | string | `"127.0.0.1"` | Redis host. |
| `port` | number | `6379` | Redis port. |
| `password` | password | — | Redis password. |
| `db` | number | `0` | Redis database number. |
| `timeout` | number | `5` | Connection and command timeout, in seconds. |
| `field` | string | *(required)* | Event field holding the key (the first element is used when it is an array). |
| `destination` | string | `"redis"` | Field receiving the result. |
| `override` | boolean | `false` | Overwrite `destination` when it already exists (otherwise the event is skipped). |
| `append` | boolean | `false` | Append results to `destination` as an array. With `pattern_matching`, keeps every matching pattern instead of the first. |
| `fallback` | string | — | Value set when the key is missing, nothing matches, or the lookup fails. |
| `data_type` | string | `"auto"` | `auto` asks Redis for each key's type first. `string`, `hash`, `list`, `set` or `zset` skip that round trip; a key of another type then fails the batch's lookups (those events get the fallback), so only use it when all keys share that type. |
| `cache_ttl` | number | `0` | Seconds a found value stays in the local cache. `0` disables caching of found values. |
| `cache_miss_ttl` | number | `cache_ttl` | Seconds a miss stays in the local cache. |
| `cache_size` | number | `10000` | Maximum number of cached keys per filter instance; the oldest entries are evicted first. |
| `pattern_matching` | boolean | `false` | Match the field value against pattern keys instead of using it as a key. |
| `pattern_namespace` | string | `""` | Key prefix of the pattern keys (e.g. `"ua:"`). |
| `scan_count` | number | `1000` | `COUNT` hint for the `SCAN` that loads the pattern keys. |
| `pattern_cache_refresh_interval` | number | `60` | Seconds between two reloads of the pattern keys. |

The cache is disabled unless `cache_ttl` or `cache_miss_ttl` is greater than 0.

## Examples

### Direct lookup

```logstash
filter {
  redis {
    host => "valkey.example.org"
    field => "[source][ip]"
    destination => "[threat][source]"
    fallback => "none"
  }
}
```

### Threat-intelligence enrichment with caching

Most lookups of threat indicators miss. Caching misses removes most of the
Redis traffic, at the cost of freshness: a newly added indicator is only seen
once the cached miss expires.

```logstash
filter {
  redis {
    host => "valkey.example.org"
    field => "[source][ip]"
    destination => "[threat][source]"
    data_type => "hash"      # every indicator is stored as a hash
    cache_ttl => 300         # found values: 5 minutes
    cache_miss_ttl => 60     # misses: new indicators seen within a minute
    cache_size => 20000
  }
}
```

### Pattern matching

With pattern keys such as `ua:*curl*` or `ua:Mozilla*` in database 1:

```logstash
filter {
  redis {
    db => 1
    field => "[user_agent][original]"
    destination => "[threat][user_agent]"
    pattern_matching => true
    pattern_namespace => "ua:"
  }
}
```

`*` matches any sequence of characters; matching is case-insensitive and
anchored at both ends. Without `append`, the first matching pattern wins, in
the order Redis returns the keys. That order is arbitrary, so avoid
overlapping patterns or use `append`.

## Output format

| Redis value | Result in `destination` |
|---|---|
| string | Parsed JSON value when the string is JSON (`{"feed":"x"}` → object, `"123"` → `123`), otherwise `{"value": "<string>"}` |
| hash | Object; each field value parsed as JSON when possible |
| list, set | Array; each element parsed as JSON when possible |
| zset | Array of `[member, score]` pairs |

In pattern mode the result is an object carrying the matched pattern; non-object
values are wrapped in `value`:

```json
{ "tool": "curl", "matched_pattern": "*curl*" }
```

With `append`, results are collected in an array, next to any existing value of
`destination`:

```json
[
  { "kind": "bot", "matched_pattern": "*bot*" },
  { "ua": "moz", "matched_pattern": "Mozilla*" }
]
```

## How lookups work

- **Batching.** Logstash hands the filter the events of a batch that reach it.
  Their keys are de-duplicated and resolved with pipelined commands: in `auto`
  mode, one round trip for the types and one for the values; with an explicit
  `data_type`, a single round trip. `pipeline.batch.size` therefore sets how
  many keys go into each round trip.
- **Connections.** Each pipeline worker thread lazily opens its own connection.
  After a failed lookup, the worker's connection is dropped and re-opened on
  the next batch. All connections are closed when the pipeline stops or
  reloads.
- **Cache.** Each `redis {}` block has its own cache of up to `cache_size`
  keys, shared by the pipeline's workers. Budget heap accordingly when you use
  large caches in many filters.
- **Pattern keys** are loaded with `SCAN` on first use and reloaded every
  `pattern_cache_refresh_interval` seconds by a single worker, while the others
  keep matching against the previous list. If a reload fails, the previous
  list is kept.

### Metrics

Each filter increments two counters in its plugin metrics: `cache_hits`
(keys served from the local cache) and `redis_lookups` (keys sent to Redis).
Their ratio shows how effective the cache is.

## Testing

### Standalone suite (no Logstash needed)

Runs the filter on MRI Ruby, with a minimal stand-in for the Logstash classes,
against a throwaway Redis/Valkey server that the script starts and stops. It
covers lookups, batching (checked through Redis `commandstats`), caching,
pattern matching, concurrency, failures, and output compatibility with 0.5.1.

```sh
sudo apt-get install -y redis-server   # or valkey-server
test/standalone/run.sh                 # installs the redis gem 4.x if missing
test/standalone/run.sh -n /cache/      # only the tests matching /cache/
```

The server listens on port 6390 (`REDIS_TEST_PORT` to change it) and is wiped
by the suite; the script refuses to reuse a port that is already in use.

`test/standalone/fixtures/compat_0.5.1.json` holds the events produced by
0.5.1. To re-record it from another version of the filter, see
`test/standalone/record_compat_fixture.rb`.

### End-to-end in Logstash

Builds the gem, installs it into Logstash OSS (downloaded once into `.cache/`),
starts a throwaway Redis, runs `test/logstash/events.jsonl` through a
0.5.x-style configuration and through one using the cache options, and checks
the enriched events.

```sh
test/logstash/run.sh                        # Logstash OSS 9.5.4
LS_VERSION=<version> test/logstash/run.sh   # another Logstash version
LS_HOME=/opt/logstash test/logstash/run.sh  # an existing install (the plugin gets installed into it)
```

### GitHub Codespaces

The repository ships a devcontainer (Ruby 3.3, redis-server, redis gem). Open
a Codespace, then run either test script above. The end-to-end test needs
about 4 GB of memory for Logstash.

### Logstash plugin test framework (rspec)

`spec/` uses the standard Logstash plugin test framework, which needs JRuby,
a Logstash source checkout and a Redis on `127.0.0.1:6379`:

```sh
export LOGSTASH_SOURCE=1 LOGSTASH_PATH=/path/to/logstash
bundle install
bundle exec rspec
```

### Continuous integration

`.github/workflows/test.yml` runs the standalone suite and builds the gem on
every push and pull request. The end-to-end job runs on tags and on manual
dispatch.

## Building

```sh
gem build logstash-filter-redis.gemspec
```

## Contributing

Issues and pull requests are welcome at
https://github.com/Psych0meter/logstash-filter-redis.
