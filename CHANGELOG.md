# Changelog

All notable changes to this project will be documented in this file.

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
