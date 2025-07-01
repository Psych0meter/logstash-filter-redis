class LogStash::Filters::Redis < LogStash::Filters::Base
  config_name "redis"

  # Redis connection settings
  config :host, :validate => :string, :default => "127.0.0.1"
  config :port, :validate => :number, :default => 6379
  config :password, :validate => :password
  config :db, :validate => :number, :default => 0

  # Event processing options
  config :field, :validate => :string, :required => true          # Field whose value will be used as the Redis key
  config :override, :validate => :boolean, :default => false      # Whether to overwrite the destination field if it already exists
  config :destination, :validate => :string, :default => "redis"  # Where to store the retrieved value in the event
  config :fallback, :validate => :string                          # Value to set if lookup fails or key doesn't exist
  config :timeout, :validate => :number, :default => 5            # Redis connection timeout

  # Pattern matching options
  config :pattern_matching, :validate => :boolean, :default => false
  config :pattern_namespace, :validate => :string, :default => ""
  config :scan_count, :validate => :number, :default => 1000

  public
  def register
    require 'redis'
    require 'json'
    @redis = nil
    @pattern_cache = {} # Cache for compiled regex patterns
  end

  public
  def filter(event)
    # Skip processing if the target field is missing or if destination exists and override is false
    return unless event.include?(@field)
    return if event.include?(@destination) && !@override

    # Resolve source key from event (handle both string and array values)
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
      event.set(@destination, @fallback) if @fallback
    end

    filter_matched(event)
  end

  private
  # Establish a new Redis connection using configured options  
  def handle_standard_lookup(event, source_value)
    type = @redis.type(source_value)

    case type
    when "string"
      value = @redis.get(source_value)
      event.set(@destination, value) if value
    when "hash"
      hash = @redis.hgetall(source_value)
      hash.each { |k, v| event.set("#{@destination}[#{k}]", v) } unless hash.empty?
    when "list"
      list = @redis.lrange(source_value, 0, -1)
      event.set(@destination, list) unless list.empty?
    when "set"
      set = @redis.smembers(source_value)
      event.set(@destination, set) unless set.empty?
    when "zset"
      zset = @redis.zrange(source_value, 0, -1, with_scores: true)
      event.set(@destination, zset) unless zset.empty?
    else
      event.set(@destination, @fallback) if @fallback
    end
  end

  def handle_pattern_matching(event, value_to_match)
    matched = false
    
    # Use SCAN for better performance with large datasets
    @redis.scan_each(match: "#{@pattern_namespace}*", count: @scan_count) do |pattern_key|
      pattern = pattern_key.gsub(/^#{@pattern_namespace}/, '')
      
      # Check cache or compile new regex
      regex = @pattern_cache[pattern] ||= compile_pattern(pattern)
      
      if regex.match(value_to_match)
        redis_value = fetch_redis_value(pattern_key)
        
        # Convert to same format as standard lookup
        if redis_value.is_a?(Hash)
          # For hash results, merge the pattern info into the hash
          enriched_value = redis_value.merge({
            "matched_pattern" => pattern,
            "original_value" => value_to_match
          })
          enriched_value.each { |k, v| event.set("#{@destination}[#{k}]", v) }
        else
          # For non-hash results, create consistent structure
          event.set(@destination, {
            "value" => value_to_match,
            "matched_pattern" => pattern,
            "indicator" => redis_value
          })
        end
        
        matched = true
        break # Stop after first match
      end
    end

    event.set(@destination, @fallback) if !matched && @fallback
  end

  def compile_pattern(pattern)
    # Convert wildcard pattern (*) to regex
    Regexp.new("\\A" + Regexp.escape(pattern).gsub("\\*", ".*") + "\\z", Regexp::IGNORECASE)
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

  def connect
    Redis.new(
      host: @host,
      port: @port,
      timeout: @timeout,
      db: @db,
      password: @password.nil? ? nil : @password.value
    )
  end
end
