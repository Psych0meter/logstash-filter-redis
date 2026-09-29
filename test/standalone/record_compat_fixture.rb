# Records fixtures/compat_0.5.1.json by running a given version of the filter
# one event at a time. Only needed to regenerate the fixture, e.g.:
#   git worktree add /tmp/lfr-0.5.1 0.5.1
#   REDIS_TEST_FLUSH=1 ruby test/standalone/record_compat_fixture.rb /tmp/lfr-0.5.1/lib
# (with a disposable Redis on REDIS_TEST_PORT, as for the test suite).
lib = ARGV.fetch(0) { abort "usage: record_compat_fixture.rb <plugin lib dir>" }
$LOAD_PATH.unshift File.expand_path("support", __dir__), File.expand_path(lib)
begin
  gem "redis", ">= 4.0.1", "< 5"
rescue Gem::LoadError
  nil
end
require "redis"
require "json"
require "logstash/filters/base"
require "logstash/filters/redis"
require_relative "seed"

port = Integer(ENV.fetch("REDIS_TEST_PORT", "6390"))
abort "set REDIS_TEST_FLUSH=1 (disposable instance only)" unless ENV["REDIS_TEST_FLUSH"] == "1"
RedisSeed.seed(port)

configs = [
  { "field" => "k", "destination" => "t" },
  { "field" => "k", "destination" => "t", "fallback" => "none" },
  { "field" => "k", "destination" => "t", "override" => true },
  { "field" => "k", "destination" => "t", "append" => true },
  { "field" => "k", "destination" => "t", "append" => true, "fallback" => "fb" },
  { "field" => "[a][b]", "destination" => "[x][y]" },
  { "field" => "k", "destination" => "t", "db" => 1, "pattern_matching" => true },
  { "field" => "k", "destination" => "t", "db" => 1, "pattern_matching" => true, "append" => true, "fallback" => "nomatch" },
  { "field" => "k", "destination" => "t", "db" => 2, "pattern_matching" => true, "pattern_namespace" => "ua:" },
  { "field" => "k", "destination" => "t", "fallback" => "down", "port" => 1, "timeout" => 1 }
]
inputs = JSON.parse(File.read(File.expand_path("fixtures/compat_inputs.json", __dir__)))

fixture = configs.map do |config|
  filter = LogStash::Filters::Redis.new({ "port" => port }.merge(config))
  filter.register
  events = inputs.map { |data| LogStash::Event.new(Marshal.load(Marshal.dump(data))) }
  events.each { |e| filter.filter(e) }
  [config, events.map(&:to_hash)]
end
File.write(File.expand_path("fixtures/compat_0.5.1.json", __dir__), JSON.pretty_generate(fixture) + "\n")
puts "recorded #{fixture.size} configurations x #{inputs.size} events"
