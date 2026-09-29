# rspec suite for the Logstash plugin test framework (JRuby + logstash-core +
# logstash-devutils, see README "Testing"). Needs a Redis on 127.0.0.1:6379
# that may be written to. For a quick check without Logstash, use
# test/standalone/run.sh instead.
require "logstash/devutils/rspec/spec_helper"
require "logstash/filters/redis"
require "redis"

describe LogStash::Filters::Redis do
  before(:all) do
    @redis = Redis.new
    @redis.set("somekey", "somevalue")
    @redis.hset("somehash", "feed", "misp")
  end

  after(:all) do
    @redis.del("somekey", "somehash")
  end

  describe "string lookup" do
    config <<-CONFIG
      filter {
        redis {
          field => "redis-key"
          destination => "redis-value"
        }
      }
    CONFIG

    sample("redis-key" => "somekey") do
      insist { subject.get("redis-value") } == { "value" => "somevalue" }
    end
  end

  describe "hash lookup, using the first element of an array field" do
    config <<-CONFIG
      filter {
        redis {
          field => "redis-key"
          destination => "redis-value"
        }
      }
    CONFIG

    sample("redis-key" => ["somehash", "somekey"]) do
      insist { subject.get("redis-value") } == { "feed" => "misp" }
    end
  end

  describe "missing key" do
    config <<-CONFIG
      filter {
        redis {
          field => "redis-key"
          destination => "redis-value"
        }
      }
    CONFIG

    sample("redis-key" => "notakey") do
      insist { subject.include?("redis-value") } == false
    end
  end

  describe "missing key with fallback and cache" do
    config <<-CONFIG
      filter {
        redis {
          field => "redis-key"
          destination => "redis-value"
          fallback => "none"
          cache_ttl => 60
        }
      }
    CONFIG

    sample("redis-key" => "notakey") do
      insist { subject.get("redis-value") } == "none"
    end
  end
end
