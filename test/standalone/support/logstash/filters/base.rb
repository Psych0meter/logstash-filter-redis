# Minimal stand-in for LogStash::Filters::Base and LogStash::Event, just enough
# to run the filter outside Logstash (MRI Ruby, no JRuby / logstash-core).
# It does not replace a real Logstash test: see test/logstash/run.sh.
require "logstash/namespace"

module LogStash
  class TestPassword
    def initialize(value)
      @value = value
    end

    attr_reader :value
  end

  class TestLogger
    attr_reader :warnings

    def initialize
      @warnings = []
    end

    def warn(message, data = {})
      @warnings << [message, data]
    end

    def debug(*); end
  end

  class TestMetric
    attr_reader :counters

    def initialize
      @counters = Hash.new(0)
    end

    def increment(key, value = 1)
      @counters[key] += value
    end
  end

  class Event
    def initialize(data = {})
      @data = data
      @cancelled = false
    end

    def get(field)
      path(field).reduce(@data) { |node, key| node.is_a?(Hash) ? node[key] : nil }
    end

    def set(field, value)
      keys = path(field)
      parent = keys[0..-2].reduce(@data) { |node, key| node[key] ||= {} }
      # Logstash converts values to its own structures on set: copy likewise.
      parent[keys.last] = Marshal.load(Marshal.dump(value))
    end

    def include?(field)
      !get(field).nil?
    end

    def cancel
      @cancelled = true
    end

    def cancelled?
      @cancelled
    end

    def to_hash
      @data
    end

    private

    def path(field)
      keys = field.scan(/\[([^\]]+)\]/).flatten
      keys.empty? ? [field] : keys
    end
  end

  module Filters
    class Base
      def self.config_name(_name); end

      def self.config(name, opts = {})
        (@configs ||= {})[name] = opts
      end

      def self.configs
        @configs || {}
      end

      attr_reader :logger, :metric

      def initialize(params = {})
        self.class.configs.each do |name, opts|
          value = params.key?(name.to_s) ? params[name.to_s] : opts[:default]
          value = TestPassword.new(value) if opts[:validate] == :password && value
          instance_variable_set("@#{name}", value)
        end
        @logger = TestLogger.new
        @metric = TestMetric.new
      end

      # Stands in for add_field / add_tag handling.
      def filter_matched(event)
        event.set("[@matched]", true)
      end
    end
  end
end
