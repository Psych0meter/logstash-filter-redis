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
  config :override, :validate => :boolean, :default => false
  config :append, :validate => :boolean, :default => false
  config :destination, :validate => :string, :default => "redis"
  config :fallback, :validate => :string

  # Pattern matching
  config :pattern_matching, :validate => :boolean, :default => false
  config :pattern_namespace, :validate => :string, :default => ""
  config :scan_count, :validate => :number, :default => 1000
  config :pattern_cache_refresh_interval, :validate => :number, :default => 60
  # How often (in seconds) to refresh the pattern cache from Redis

  public
  def register
    require "redis"
    require "json"
    @redis = nil
    @pattern_cache = {}
    @pattern_keys = []
    @last_pattern_load_time = Time.at(0)
  end

  public
  def filter(event)
    return unless event.include?(@field)
    return if event.include?(@destination) && !@override && !@append

    source_value = event.get(@field).is_a?(Array) ?
                     event.get(@field).first.to_s :
                     event.get(@field).to_s

    begin
      @redis ||= connect

      if @pattern_matching
        handle_pattern_matching(event, source_value)
      else
        handle_standard_lookup(event, source_value)
      end

    rescue => e
      @logger.warn("Redis lookup failed", :error => e.message)
      if @fallback
        if @append
          append_value(event, @destination, @fallback)
        else
          event.set(@destination, @fallback)
        end
      end
    end

    filter_matched(event)
  end

  private

  def connect
    Redis.new(
      host: @host,
      port: @port,
      timeout: @timeout,
      db: @db,
      password: @password.nil? ? nil : @password.value
    )
  end

  def handle_standard_lookup(event, source_value)
    type = @redis.type(source_value)

    case type
    when "string"
      value = @redis.get(source_value)
      set_or_append_value(event, @destination, format_redis_value(value)) if value
    when "hash"
      hash = @redis.hgetall(source_value)
      set_or_append_value(event, @destination, format_redis_value(hash)) unless hash.empty?
    when "list"
      list = @redis.lrange(source_value, 0, -1)
      set_or_append_value(event, @destination, format_redis_value(list)) unless list.empty?
    when "set"
      set = @redis.smembers(source_value)
      set_or_append_value(event, @destination, format_redis_value(set)) unless set.empty?
    when "zset"
      zset = @redis.zrange(source_value, 0, -1, with_scores: true)
      set_or_append_value(event, @destination, format_redis_value(zset)) unless zset.empty?
    else
      set_or_append_value(event, @destination, @fallback) if @fallback
    end
  end

  # Efficient pattern matching with periodic pattern cache refresh
  def handle_pattern_matching(event, value_to_match)
    refresh_patterns_if_needed

    matched = false
    @pattern_keys.each do |pattern_key, pattern|
      regex = @pattern_cache[pattern]
      next unless regex
      
      if regex.match(value_to_match)
        redis_value = fetch_redis_value(pattern_key)
        formatted = format_redis_value(redis_value)
        formatted["matched_pattern"] = pattern
        set_or_append_value(event, @destination, formatted)
        matched = true
        break unless @append
      end
    end

    set_or_append_value(event, @destination, @fallback) if !matched && @fallback
  end

  # Periodically reloads Redis keys matching the namespace
  def refresh_patterns_if_needed
    now = Time.now
    if now - @last_pattern_load_time > @pattern_cache_refresh_interval
      @pattern_keys = []
      @pattern_cache = {}

      @redis.scan_each(match: "#{@pattern_namespace}*", count: @scan_count) do |pattern_key|
        pattern = pattern_key.sub(/^#{@pattern_namespace}/, '')
        @pattern_keys << [pattern_key, pattern]
        @pattern_cache[pattern] = compile_pattern(pattern)
      end

      @last_pattern_load_time = now
      @logger.debug("Pattern cache refreshed", count: @pattern_keys.size)
    end
  end

  def fetch_redis_value(key)
    case @redis.type(key)
    when "string" then @redis.get(key)
    when "hash" then @redis.hgetall(key)
    when "list" then @redis.lrange(key, 0, -1)
    when "set" then @redis.smembers(key)
    when "zset" then @redis.zrange(key, 0, -1, with_scores: true)
    else nil
    end
  end

  def compile_pattern(pattern)
    Regexp.new("\\A" + Regexp.escape(pattern).gsub("\\*", ".*") + "\\z", Regexp::IGNORECASE)
  end

  def format_redis_value(value)
    case value
    when Hash
      value.each_with_object({}) do |(k, v), h|
        h[k] = parse_json_safe(v) || v
      end
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
  rescue
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
      current << value
      event.set(field, current)
    else
      event.set(field, [current, value])
    end
  end
end
