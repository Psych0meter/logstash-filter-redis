# A custom Logstash filter plugin to enrich events using data fetched from Redis.
class LogStash::Filters::Redis < LogStash::Filters::Base
  config_name "redis"

  # Redis connection settings
  config :host, :validate => :string, :default => "127.0.0.1"
  config :port, :validate => :number, :default => 6379
  config :password, :validate => :password
  config :db, :validate => :number, :default => 0

  # Event processing options
  config :field, :validate => :string, :required => true       # Field whose value will be used as the Redis key
  config :override, :validate => :boolean, :default => false   # Whether to overwrite the destination field if it already exists
  config :destination, :validate => :string, :default => "redis" # Where to store the retrieved value in the event
  config :fallback, :validate => :string                        # Value to set if lookup fails or key doesn't exist
  config :timeout, :validate => :number, :required => false, :default => 5 # Redis connection timeout

  public
  def register
    require 'redis'
    require 'json'
    @redis = nil
  end

  public
  def filter(event)
    # Skip processing if the target field is missing or if destination exists and override is false
    return unless event.include?(@field)
    return if event.include?(@destination) && !@override

    # Resolve source key from event (handle both string and array values)
    source = event.get(@field).is_a?(Array) ? event.get(@field).first.to_s : event.get(@field).to_s

    begin
      @redis ||= connect
      type = @redis.type(source)

      case type
      when "string"
        value = @redis.get(source)
        event.set(@destination, value) if value

      when "hash"
        hash = @redis.hgetall(source)
        hash.each { |k, v| event.set("#{@destination}[#{k}]", v) } unless hash.empty?

      when "list"
        list = @redis.lrange(source, 0, -1)
        event.set(@destination, list) unless list.empty?

      when "set"
        set = @redis.smembers(source)
        event.set(@destination, set) unless set.empty?

      when "zset"
        zset = @redis.zrange(source, 0, -1, with_scores: true)
        event.set(@destination, zset) unless zset.empty?

      else
        # Unsupported or nonexistent key type, use fallback if available
        event.set(@destination, @fallback) if @fallback
      end

    rescue => e
      # On error (connection, lookup, etc.), log and optionally set fallback
      @logger.warn("Redis lookup failed", :error => e.message)
      event.set(@destination, @fallback) if @fallback
    end

    filter_matched(event)
  end

  private
  # Establish a new Redis connection using configured options
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
