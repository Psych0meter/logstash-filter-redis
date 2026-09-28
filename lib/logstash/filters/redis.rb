# encoding: utf-8
require "logstash/filters/base"
require "logstash/namespace"

# Enriches events with values looked up in Redis (or Valkey), using an event
# field as the key.
#
# Lookups are resolved per pipeline batch: the keys of all events of a batch
# are de-duplicated and fetched with pipelined commands, so a batch costs one
# or two network round trips instead of one or two per event. Each pipeline
# worker thread uses its own connection. An optional local TTL cache (disabled
# by default) can absorb repeated lookups, including misses.
class LogStash::Filters::Redis < LogStash::Filters::Base
  config_name "redis"

  # Redis connection settings
  config :host, :validate => :string, :default => "127.0.0.1"
  config :port, :validate => :number, :default => 6379
  config :password, :validate => :password
  config :db, :validate => :number, :default => 0
  config :timeout, :validate => :number, :default => 5

  # Event processing
  config :field, :validate => :string, :required => true
  config :destination, :validate => :string, :default => "redis"
  config :override, :validate => :boolean, :default => false
  config :append, :validate => :boolean, :default => false
  config :fallback, :validate => :string

  # Type of the looked-up keys. `auto` asks Redis for each key's type first
  # (mixed types supported, two round trips per batch). An explicit type skips
  # that step; a key of another type then fails the batch's lookups
  # (WRONGTYPE) and the events get the fallback, so only use it when every key
  # has that type.
  config :data_type, :validate => %w[auto string hash list set zset], :default => "auto"

  # Local cache, per filter instance. `cache_ttl` (seconds) caches found values,
  # `cache_miss_ttl` caches misses and defaults to `cache_ttl`. Both 0 (the
  # default) disables the cache. `cache_size` bounds the number of entries;
  # the oldest entries are evicted first.
  config :cache_ttl, :validate => :number, :default => 0
  config :cache_miss_ttl, :validate => :number
  config :cache_size, :validate => :number, :default => 10_000

  # Pattern matching: match the field value against wildcard patterns stored
  # as Redis keys (`*` matches anything), optionally under a key prefix.
  config :pattern_matching, :validate => :boolean, :default => false
  config :pattern_namespace, :validate => :string, :default => ""
  config :scan_count, :validate => :number, :default => 1000
  # Seconds between two reloads of the pattern list from Redis.
  config :pattern_cache_refresh_interval, :validate => :number, :default => 60

  FETCHABLE_TYPES = %w[string hash list set zset].freeze
  MISS = Object.new.freeze

  # Bounded, thread-safe TTL cache with insertion-order eviction.
  class TtlCache
    def initialize(max_size)
      @max_size = [max_size.to_i, 1].max
      @store = {}
      @lock = Mutex.new
    end

    def get(key)
      @lock.synchronize do
        entry = @store[key]
        return nil unless entry
        if entry[1] < now
          @store.delete(key)
          return nil
        end
        entry[0]
      end
    end

    def put(key, value, ttl)
      return if ttl.nil? || ttl <= 0
      @lock.synchronize do
        @store.delete(key)
        @store[key] = [value, now + ttl]
        @store.shift while @store.size > @max_size
      end
    end

    def size
      @lock.synchronize { @store.size }
    end

    private

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end

  public

  def register
    require "redis"
    require "json"

    @thread_key = :"logstash_filter_redis_#{object_id}"
    @clients = []
    @clients_lock = Mutex.new

    @hit_ttl = @cache_ttl.to_f
    @miss_ttl = @cache_miss_ttl.nil? ? @hit_ttl : @cache_miss_ttl.to_f
    @cache = (@hit_ttl > 0 || @miss_ttl > 0) ? TtlCache.new(@cache_size) : nil

    @patterns = nil # frozen Array of frozen [redis_key, pattern, regex]
    @patterns_loaded_at = 0.0
    @patterns_lock = Mutex.new
  end

  def filter(event)
    process_batch([event])
  end

  # Called by the pipeline with the events of a batch that reach this filter.
  def multi_filter(events)
    LogStash::Util.set_thread_plugin(self) if defined?(LogStash::Util) && LogStash::Util.respond_to?(:set_thread_plugin)
    live = events.reject(&:cancelled?)
    process_batch(live)
    live
  end

  def close
    @clients_lock.synchronize do
      @clients.each { |client| safe_close(client) }
      @clients.clear
    end
  end

  private

  def process_batch(events)
    pending = []
    events.each do |event|
      next unless event.include?(@field)
      next if event.include?(@destination) && !@override && !@append
      raw = event.get(@field)
      pending << [event, (raw.is_a?(Array) ? raw.first : raw).to_s]
    end
    return if pending.empty?

    values = pending.map(&:last).uniq
    results =
      begin
        @pattern_matching ? resolve_patterns(values) : resolve_keys(values)
      rescue StandardError => e
        @logger.warn("Redis lookup failed", :error => e.message, :class => e.class.name,
                     :host => @host, :port => @port, :db => @db, :keys => values.size)
        reset_client
        nil
      end

    pending.each do |event, value|
      entries = results && results[value]
      if entries.nil? || entries.equal?(MISS)
        set_or_append_value(event, @destination, @fallback) if @fallback
      elsif @append
        entries.each { |entry| append_value(event, @destination, entry) }
      else
        event.set(@destination, entries.first)
      end
      filter_matched(event)
    end
  end

  # --- direct lookups ---------------------------------------------------------

  # Returns { value => [formatted] | MISS }.
  def resolve_keys(values)
    results = {}
    todo = []
    values.each do |value|
      cached = cache_get(value)
      cached.nil? ? todo << value : results[value] = cached
    end
    count_metric(:cache_hits, values.size - todo.size)
    return results if todo.empty?

    count_metric(:redis_lookups, todo.size)
    fetched = fetch_many(todo)
    todo.each do |value|
      raw = fetched[value]
      entry = present?(raw) ? [format_redis_value(raw)].freeze : MISS
      results[value] = entry
      cache_put(value, entry)
    end
    results
  end

  # Returns { key => raw value } for the keys that exist, using one pipelined
  # round trip for the types (auto mode) and one for the values.
  def fetch_many(keys)
    client = redis
    types =
      if @data_type == "auto"
        client.pipelined { |pipe| keys.each { |key| pipe.type(key) } }
      else
        Array.new(keys.size, @data_type)
      end

    wanted = keys.each_with_index.select { |_, i| FETCHABLE_TYPES.include?(types[i]) }
                 .map { |key, i| [key, types[i]] }
    return {} if wanted.empty?

    replies = client.pipelined do |pipe|
      wanted.each { |key, type| issue_fetch(pipe, key, type) }
    end
    wanted.each_with_index.to_h { |(key, _), i| [key, replies[i]] }
  end

  def issue_fetch(pipe, key, type)
    case type
    when "string" then pipe.get(key)
    when "hash"   then pipe.hgetall(key)
    when "list"   then pipe.lrange(key, 0, -1)
    when "set"    then pipe.smembers(key)
    when "zset"   then pipe.zrange(key, 0, -1, :with_scores => true)
    end
  end

  # --- pattern matching -------------------------------------------------------

  # Returns { value => [formatted, ...] | MISS }. Without `append` only the
  # first matching pattern is kept.
  def resolve_patterns(values)
    results = {}
    matches = {}
    values.each do |value|
      cached = cache_get(value)
      cached.nil? ? matches[value] = nil : results[value] = cached
    end
    count_metric(:cache_hits, values.size - matches.size)
    return results if matches.empty?

    patterns = current_patterns
    needed = {}
    matches.each_key do |value|
      hits = []
      patterns.each do |redis_key, pattern, regex|
        next unless regex.match?(value)
        hits << [redis_key, pattern]
        break unless @append
      end
      matches[value] = hits
      hits.each { |redis_key, _| needed[redis_key] = true }
    end

    count_metric(:redis_lookups, needed.size)
    fetched = needed.empty? ? {} : fetch_many(needed.keys)

    matches.each do |value, hits|
      entries = hits.filter_map do |redis_key, pattern|
        raw = fetched[redis_key]
        next unless present?(raw)
        formatted = format_redis_value(raw)
        formatted = { "value" => formatted } unless formatted.is_a?(Hash)
        formatted.merge("matched_pattern" => pattern)
      end
      entry = entries.empty? ? MISS : entries.freeze
      results[value] = entry
      cache_put(value, entry)
    end
    results
  end

  # The first load blocks every worker (matching against an empty list would
  # cache false misses). Later refreshes are done by the worker that takes the
  # lock; the others keep matching against the previous snapshot.
  def current_patterns
    if @patterns.nil?
      @patterns_lock.synchronize { refresh_patterns! if @patterns.nil? }
    elsif patterns_stale? && @patterns_lock.try_lock
      begin
        refresh_patterns_keeping_previous if patterns_stale?
      ensure
        @patterns_lock.unlock
      end
    end
    @patterns
  end

  def refresh_patterns_keeping_previous
    refresh_patterns!
  rescue StandardError => e
    @logger.warn("Redis pattern refresh failed, keeping previous patterns",
                 :error => e.message, :count => @patterns.size)
    reset_client
    @patterns_loaded_at = monotonic_now
  end

  def patterns_stale?
    monotonic_now - @patterns_loaded_at > @pattern_cache_refresh_interval
  end

  def refresh_patterns!
    prefix = @pattern_namespace.to_s
    list = []
    redis.scan_each(:match => "#{prefix}*", :count => @scan_count) do |redis_key|
      pattern = redis_key.start_with?(prefix) ? redis_key[prefix.length..] : redis_key
      list << [redis_key, pattern, compile_pattern(pattern)].freeze
    end
    @patterns = list.freeze
    @patterns_loaded_at = monotonic_now
    @logger.debug("Pattern cache refreshed", :count => list.size)
  end

  def compile_pattern(pattern)
    Regexp.new("\\A" + Regexp.escape(pattern).gsub("\\*", ".*") + "\\z", Regexp::IGNORECASE)
  end

  # --- connections ------------------------------------------------------------

  def redis
    Thread.current[@thread_key] ||= begin
      client = connect
      @clients_lock.synchronize { @clients << client }
      client
    end
  end

  def connect
    Redis.new(
      :host => @host,
      :port => @port,
      :timeout => @timeout,
      :db => @db,
      :password => @password.nil? ? nil : @password.value
    )
  end

  def reset_client
    client = Thread.current[@thread_key]
    Thread.current[@thread_key] = nil
    return unless client
    @clients_lock.synchronize { @clients.delete(client) }
    safe_close(client)
  end

  def safe_close(client)
    client.close
  rescue StandardError
    nil
  end

  # --- cache & metrics --------------------------------------------------------

  def cache_get(key)
    @cache&.get(key)
  end

  def cache_put(key, entry)
    @cache&.put(key, entry, entry.equal?(MISS) ? @miss_ttl : @hit_ttl)
  end

  def count_metric(name, value)
    return if value <= 0
    metric.increment(name, value)
  rescue StandardError
    nil
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # --- value formatting (same output as 0.5.x) --------------------------------

  def present?(raw)
    return false if raw.nil?
    return !raw.empty? if raw.is_a?(Hash) || raw.is_a?(Array)
    true
  end

  def format_redis_value(value)
    case value
    when Hash
      value.transform_values { |v| parse_json_safe(v) || v }
    when Array
      value.map { |v| parse_json_safe(v) || v }
    when String
      parse_json_safe(value) || { "value" => value }
    else
      { "value" => value }
    end
  end

  def parse_json_safe(str)
    return str unless str.is_a?(String)
    JSON.parse(str)
  rescue StandardError
    nil
  end

  def set_or_append_value(event, field, value)
    if @append
      append_value(event, field, value)
    else
      event.set(field, value)
    end
  end

  def append_value(event, field, value)
    current = event.get(field)
    if current.nil?
      event.set(field, [value])
    elsif current.is_a?(Array)
      event.set(field, current << value)
    else
      event.set(field, [current, value])
    end
  end
end
