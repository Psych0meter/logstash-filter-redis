# Shared setup for the standalone suite. Needs a Redis/Valkey server that the
# suite may FLUSHALL: run it through test/standalone/run.sh, which starts a
# throwaway instance, or export REDIS_TEST_PORT and REDIS_TEST_FLUSH=1 yourself.
$LOAD_PATH.unshift File.expand_path("support", __dir__)
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)

begin
  gem "redis", ">= 4.0.1", "< 5" # same constraint as the gemspec
rescue Gem::LoadError
  nil # not installed as a gem (e.g. provided through RUBYLIB)
end
require "redis"
require "json"
require "minitest/autorun"
require "logstash/filters/base"
require "logstash/filters/redis"
require_relative "seed"

REDIS_TEST_PORT = Integer(ENV.fetch("REDIS_TEST_PORT", "6390"))
UNREACHABLE_PORT = 1 # nothing listens there: connection refused immediately

unless ENV["REDIS_TEST_FLUSH"] == "1"
  abort "Refusing to run: the suite FLUSHALLs the Redis on port #{REDIS_TEST_PORT}. " \
        "Use test/standalone/run.sh, or set REDIS_TEST_FLUSH=1 for a disposable instance."
end

module RedisTestHelper
  def redis
    @redis ||= Redis.new(:port => REDIS_TEST_PORT)
  end

  def build_filter(params)
    filter = LogStash::Filters::Redis.new({ "port" => REDIS_TEST_PORT }.merge(params))
    filter.register
    filter
  end

  def event(data)
    LogStash::Event.new(data)
  end

  def calls(command)
    stats = redis.info("commandstats")[command]
    stats ? stats["calls"].to_i : 0
  end

  def reset_stats
    redis.config(:resetstat)
  end

  def seed
    RedisSeed.seed(REDIS_TEST_PORT)
  end
end
