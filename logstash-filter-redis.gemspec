Gem::Specification.new do |s|

  s.name = 'logstash-filter-redis'
  s.version = '0.4.0'
  s.licenses = ['Apache-2.0']
  s.summary = "Logstash filter plugin for enriching events with values from Redis."
  s.description = "This plugin allows Logstash to enrich event data by looking up values from Redis using a specified field as a key. It supports Redis types including string, hash, list, set, and zset. Install using: $LS_HOME/bin/logstash-plugin install logstash-filter-redis."

  s.authors = ["meulop", "make", "Psych0meter"]
  s.email = 'psychometer@chpavaldon.com'
  s.homepage = "https://github.com/Psych0meter/logstash-filter-redis"
  s.require_paths = ["lib"]

  # Files
  s.files = Dir['lib/**/*','spec/**/*','vendor/**/*','*.gemspec','*.md','CONTRIBUTORS','Gemfile','LICENSE','NOTICE.TXT']

  # Tests
  s.test_files = s.files.grep(%r{^(test|spec|features)/})

  # Metadata to identify this as a Logstash plugin
  s.metadata = { "logstash_plugin" => "true", "logstash_group" => "filter" }

  # Runtime dependencies
  s.add_runtime_dependency "logstash-core-plugin-api", ">= 1.60", "<= 2.99"
  s.add_runtime_dependency "redis", ">= 4.0.1", "< 5"

  # Development dependencies
  s.add_development_dependency 'logstash-devutils', ">= 2.6", "< 2.7"

  # Ruby version constraint
  s.required_ruby_version = '>= 3.0'
end
