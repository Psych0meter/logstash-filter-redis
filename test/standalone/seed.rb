# Test data shared by the suite and by record_compat_fixture.rb.
module RedisSeed
  def self.seed(port)
    with_db(port, 0) do |db|
      db.flushall
      db.set("str", "plain")
      db.set("json", '{"feed":"x","n":1}')
      db.set("num", "123")
      db.set("empty", "")
      db.hset("hash", "a", "1", "b", '{"c":2}', "c", "text")
      db.rpush("list", ["l1", '{"j":1}'])
      db.sadd("set", ["s1"])
      db.zadd("zset", [[1, "z1"], [2, "z2"]])
    end
    with_db(port, 1) do |db|
      db.hset("*curl*", "tool", "curl")
      db.hset("*bot*", "kind", "bot")
      db.set("Mozilla*", '{"ua":"moz"}')
    end
    with_db(port, 2) do |db|
      db.hset("ua:*curl*", "tool", "curl2")
      db.hset("other", "z", "1")
    end
  end

  def self.with_db(port, number)
    client = Redis.new(:port => port, :db => number)
    yield client
  ensure
    client&.close
  end
end
