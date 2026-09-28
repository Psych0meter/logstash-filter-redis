# Changelog

All notable changes to this project will be documented in this file.

## [0.6.0]
Drop-in upgrade: existing configurations keep working unchanged and produce
the same events (verified against 0.5.1 by the standalone suite). The new
options are opt-in.

### Added
- Batch-level lookups: the keys of a pipeline batch are de-duplicated and
  resolved with pipelined commands, at most two round trips per batch
  (`TYPE`, then fetch) instead of one or two per event.
- `data_type` option (`auto` by default) to skip the `TYPE` round trip when
  all keys share a type.
- Local bounded TTL cache, disabled by default: `cache_ttl`, `cache_miss_ttl`
  (negative caching), `cache_size`.
- `cache_hits` and `redis_lookups` plugin metrics.
- Connections are closed when the pipeline stops or reloads.
- Standalone test suite (MRI Ruby + Redis, no Logstash needed), including a
  golden-output compatibility test against 0.5.1; end-to-end test script in a
  real Logstash; GitHub Codespaces devcontainer; GitHub Actions workflow.

### Changed
- One Redis connection per pipeline worker thread, instead of one connection
  shared (and serialized) by all workers.
- Pattern list refresh is thread-safe: a single worker rescans while the others
  keep matching against the previous list, and a failed refresh keeps the
  previous list instead of emptying it.
- A lookup failure is logged once per batch instead of once per event, and the
  worker's connection is reset so the next batch reconnects.
- The rspec suite matches the actual output format.

### Fixed
- `pattern_namespace` is handled as a literal prefix (it was used as a regular
  expression when stripping it from pattern keys).
- In pattern mode, a pattern key deleted between two refreshes is skipped
  instead of producing `{"value": null}`, and non-hash values no longer make
  the lookup fail.

## [0.5.1]
### Added
- `pattern_cache_refresh_interval`: the pattern list is reloaded from Redis
  periodically instead of once.

## [0.5.0]
### Added
- Wildcard pattern matching support via `pattern_matching` configuration
- Configurable pattern namespace with `pattern_namespace` setting
- SCAN-based pattern lookup for better performance with large datasets
- Regex pattern caching for improved matching efficiency
- Support for matching event values against Redis-stored patterns
- New output structure with matched pattern metadata
- Support for appending multiple Redis values to an array with `append` configuration
- JSON parsing for string values to handle structured data in Redis
- Improved value formatting with type preservation
- Better handling of array input values from the source field

## [0.4.0]
### Added
- Support for Redis data types: `string`, `hash`, `list`, `set`, and `zset`.
- `fallback` configuration to set a default value when Redis lookup fails or key is missing.
- `timeout` option for Redis connection handling.
- Improved error logging on Redis failures.
- Enhanced documentation, gemspec metadata, and plugin comments for clarity.

### Changed
- Connection handling is now lazy and resilient to failures.
- Internal structure aligned with Logstash plugin best practices for maintainability.

---

## [0.3.0]
### Added
- Initial support for Logstash 5.0.0.

---

## [0.2.0]
### Changed
- Removed the data store feature.
- Renamed configuration option `key` to `field` to match the `translate` plugin convention.
- Aligned plugin behavior with [logstash-filter-translate](https://github.com/logstash-plugins/logstash-filter-translate):
  - Introduced `field`, `destination`, and `override` settings.
  - Updated logic to reflect `translate`-style mappings.

---

## [0.1.0]
### Added
- Initial fork from [meulop/logstash-filter-redis](https://github.com/meulop/logstash-filter-redis).
