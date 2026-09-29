require_relative "test_helper"

class RedisFilterTest < Minitest::Test
  include RedisTestHelper

  def setup
    seed
  end

  # --- behaviour --------------------------------------------------------------

  def test_hash_lookup_with_json_values
    e = event("k" => "hash")
    build_filter("field" => "k", "destination" => "t").filter(e)
    assert_equal({ "a" => 1, "b" => { "c" => 2 }, "c" => "text" }, e.get("t"))
    assert e.get("[@matched]")
  end

  def test_miss_leaves_destination_unset_and_applies_fallback
    e1 = event("k" => "missing")
    build_filter("field" => "k", "destination" => "t").filter(e1)
    assert_nil e1.get("t")

    e2 = event("k" => "missing")
    build_filter("field" => "k", "destination" => "t", "fallback" => "none").filter(e2)
    assert_equal "none", e2.get("t")
  end

  def test_event_without_field_is_untouched
    e = event("other" => 1)
    build_filter("field" => "k", "destination" => "t").multi_filter([e])
    assert_nil e.get("[@matched]")
  end

  def test_existing_destination_is_kept_unless_override
    e = event("k" => "str", "t" => "keep")
    build_filter("field" => "k", "destination" => "t").filter(e)
    assert_equal "keep", e.get("t")

    e = event("k" => "str", "t" => "keep")
    build_filter("field" => "k", "destination" => "t", "override" => true).filter(e)
    assert_equal({ "value" => "plain" }, e.get("t"))
  end

  def test_cancelled_events_are_dropped_from_the_batch
    kept = event("k" => "str")
    gone = event("k" => "str")
    gone.cancel
    out = build_filter("field" => "k", "destination" => "t").multi_filter([kept, gone])
    assert_equal [kept], out
  end

  # --- batching ---------------------------------------------------------------

  def test_batch_deduplicates_keys_and_pipelines_lookups
    events = Array.new(500) { |i| event("k" => %w[hash str missing][i % 3]) }
    reset_stats
    out = build_filter("field" => "k", "destination" => "t").multi_filter(events)

    assert_equal 500, out.size
    assert_equal 3, calls("type")
    assert_equal 1, calls("hgetall")
    assert_equal 1, calls("get")
    assert_equal({ "value" => "plain" }, events[1].get("t"))
    assert_nil events[2].get("t")
  end

  def test_explicit_data_type_skips_type_lookups
    reset_stats
    events = [event("k" => "hash"), event("k" => "missing")]
    build_filter("field" => "k", "destination" => "t", "data_type" => "hash").multi_filter(events)
    assert_equal 0, calls("type")
    assert_equal 2, calls("hgetall")
    assert_equal "text", events[0].get("[t][c]")
    assert_nil events[1].get("t")
  end

  def test_wrong_data_type_falls_back_and_warns
    filter = build_filter("field" => "k", "destination" => "t", "data_type" => "hash", "fallback" => "fb")
    e = event("k" => "str")
    filter.multi_filter([e])
    assert_equal "fb", e.get("t")
    assert_equal 1, filter.logger.warnings.size
  end

  # --- cache ------------------------------------------------------------------

  def test_cache_serves_hits_and_misses_without_redis
    filter = build_filter("field" => "k", "destination" => "t", "cache_ttl" => 60)
    filter.multi_filter([event("k" => "hash"), event("k" => "missing")])

    reset_stats
    events = [event("k" => "hash"), event("k" => "missing")]
    filter.multi_filter(events)
    assert_equal 0, calls("type") + calls("hgetall")
    assert_equal "text", events[0].get("[t][c]")
    assert_nil events[1].get("t")
    assert_equal 2, filter.metric.counters[:cache_hits]
  end

  def test_miss_ttl_zero_only_caches_hits
    filter = build_filter("field" => "k", "destination" => "t", "cache_ttl" => 60, "cache_miss_ttl" => 0)
    filter.multi_filter([event("k" => "hash"), event("k" => "missing")])
    reset_stats
    filter.multi_filter([event("k" => "hash"), event("k" => "missing")])
    assert_equal 1, calls("type") # only the uncached miss goes back to Redis
  end

  def test_cache_is_disabled_by_default
    filter = build_filter("field" => "k", "destination" => "t")
    filter.multi_filter([event("k" => "hash")])
    reset_stats
    filter.multi_filter([event("k" => "hash")])
    assert_equal 1, calls("hgetall")
  end

  def test_cache_size_is_bounded
    cache = LogStash::Filters::Redis::TtlCache.new(3)
    5.times { |i| cache.put(i, i, 60) }
    assert_equal 3, cache.size
    assert_nil cache.get(0)
    assert_equal 4, cache.get(4)
  end

  def test_cache_entries_expire
    cache = LogStash::Filters::Redis::TtlCache.new(10)
    cache.put("k", "v", 0.05)
    assert_equal "v", cache.get("k")
    sleep 0.1
    assert_nil cache.get("k")
  end

  # --- pattern matching -------------------------------------------------------

  def test_pattern_matching_first_match_and_append
    events = [event("k" => "curl/8"), event("k" => "Mozilla bot"), event("k" => "wget")]
    build_filter("field" => "k", "destination" => "t", "db" => 1, "pattern_matching" => true).multi_filter(events)
    assert_equal({ "tool" => "curl", "matched_pattern" => "*curl*" }, events[0].get("t"))
    assert_nil events[2].get("t")

    e = event("k" => "Mozilla bot")
    build_filter("field" => "k", "destination" => "t", "db" => 1,
                 "pattern_matching" => true, "append" => true).filter(e)
    assert_equal ["*bot*", "Mozilla*"], e.get("t").map { |h| h["matched_pattern"] }.sort
  end

  def test_pattern_namespace_is_a_literal_prefix
    e = event("k" => "curl/8")
    build_filter("field" => "k", "destination" => "t", "db" => 2,
                 "pattern_matching" => true, "pattern_namespace" => "ua:").filter(e)
    assert_equal({ "tool" => "curl2", "matched_pattern" => "*curl*" }, e.get("t"))
  end

  def test_pattern_list_is_loaded_once_across_threads
    filter = build_filter("field" => "k", "destination" => "t", "db" => 1, "pattern_matching" => true)
    reset_stats
    threads = Array.new(8) do
      Thread.new do
        Array.new(25) do
          ev = event("k" => "curl/1")
          filter.multi_filter([ev])
          ev.get("[t][tool]")
        end
      end
    end
    assert_equal ["curl"], threads.flat_map(&:value).uniq
    assert_equal 1, calls("scan")
  end

  # --- connections ------------------------------------------------------------

  def test_one_connection_per_thread_and_close
    filter = build_filter("field" => "k", "destination" => "t")
    Array.new(4) { Thread.new { filter.multi_filter([event("k" => "str")]) } }.each(&:join)
    assert_equal 4, filter.instance_variable_get(:@clients).size
    filter.close
    assert_empty filter.instance_variable_get(:@clients)
  end

  def test_unreachable_redis_applies_fallback
    filter = build_filter("field" => "k", "destination" => "t", "fallback" => "down",
                          "port" => UNREACHABLE_PORT, "timeout" => 1)
    e = event("k" => "str")
    filter.multi_filter([e])
    assert_equal "down", e.get("t")
    assert e.get("[@matched]")
  end

  # --- compatibility with 0.5.x -----------------------------------------------

  # fixtures/compat_0.5.1.json holds the events produced by the 0.5.1 filter
  # (one event at a time) for a matrix of configurations. The current filter
  # must produce exactly the same events, per event and per batch.
  def test_output_matches_0_5_1_per_event_and_per_batch
    fixture = JSON.parse(File.read(File.expand_path("fixtures/compat_0.5.1.json", __dir__)))
    inputs = JSON.parse(File.read(File.expand_path("fixtures/compat_inputs.json", __dir__)))

    fixture.each do |config, expected|
      params = config.dup
      params["port"] = UNREACHABLE_PORT if params.key?("port")
      %i[filter multi_filter].each do |mode|
        filter = build_filter(params)
        events = inputs.map { |data| event(Marshal.load(Marshal.dump(data))) }
        mode == :filter ? events.each { |e| filter.filter(e) } : filter.multi_filter(events)
        assert_equal expected, events.map(&:to_hash), "#{mode} with #{config}"
      end
    end
  end
end
