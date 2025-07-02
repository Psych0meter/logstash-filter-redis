# Logstash Filter Plugin: Redis Lookup

This is a custom [Logstash](https://github.com/elastic/logstash) filter plugin that enriches event data by querying a Redis datastore. The plugin retrieves values from Redis using a field in the event as the lookup key and supports various Redis data types (`string`, `hash`, `list`, `set`, `zset`).

It is fully free and open source under the Apache 2.0 License.

## 🔧 Features

- Look up values from Redis based on a specified event field
- Supports all Redis data types: `string`, `hash`, `list`, `set`, and `zset`
- Optional fallback value if the key is not found or Redis is unreachable
- Configurable key source field, destination field, and override behavior
- Wildcard pattern matching against Redis-stored patterns
- Efficient SCAN-based pattern lookup for large datasets
- Regex pattern caching for improved performance
- Array value support with `append` option
- Automatic JSON parsing for string values
- Configurable connection timeout and Redis database selection

## 📄 Configuration Options

| Setting | Description | Default |
|---------|-------------|---------|
| `host` | Redis host address | "127.0.0.1" |
| `port` | Redis port | 6379 |
| `password` | Redis password (optional) | nil |
| `db` | Redis database number | 0 |
| `field` | Event field to use as lookup key | (required) |
| `destination` | Field where to store lookup results | "redis" |
| `override` | Overwrite destination field if it exists | false |
| `fallback` | Default value if lookup fails | nil |
| `timeout` | Redis connection timeout in seconds | 5 |
| `append` | Append results to an array instead of overwriting | false |
| `pattern_matching` | Enable wildcard pattern matching | false |
| `pattern_namespace` | Redis key namespace for patterns | "" |
| `scan_count` | Number of items to scan per iteration | 1000 |

## 🛠 Configuration Examples

### Standard Lookup
```logstash
filter {
  redis {
    host => "localhost"
    port => 6379
    db => 0
    field => "user_id"
    destination => "user_data"
    override => true
    fallback => "unknown"
  }
}
```

### Pattern Matching with Namespace
```logstash
filter {
  redis {
    field => "[source][ip]"
    destination => "[threat][match]"
    pattern_matching => true
    pattern_namespace => "ip_patterns:"
    scan_count => 2000
  }
}
```

### Appending Multiple Values
```logstash
filter {
  redis {
    field => "tags"
    destination => "enriched_data"
    append => true
    fallback => {"default" => "value"}
  }
}
```

## 🧠 How It Works

### Value Lookup Modes
1. **Direct Lookup**: Uses the field value as a direct Redis key
2. **Pattern Matching**: When enabled, scans Redis for pattern keys that match the field value

### Data Type Handling
- **Strings**: Stored directly or parsed as JSON if valid
- **Hashes**: Converted to nested objects
- **Lists/Sets**: Converted to arrays
- **Sorted Sets**: Converted to arrays with scores

### Pattern Matching Output
When pattern matching finds a result, the output includes metadata:
```json
{
  "matched_pattern": "192.168.*",
  "value": "internal_network",
  "original_value": "192.168.1.1"
}
```

### Array Handling with `append`
When `append` is true, multiple matches will be collected in an array:
```json
{
  "enriched_data": [
    {"matched_pattern": "192.168.*", "value": "internal"},
    {"matched_pattern": "192.*", "value": "private"}
  ]
}
```

## Need Help?

Need help? Try #logstash on freenode IRC or the https://discuss.elastic.co/c/logstash discussion forum.

## Developing

### 1. Plugin Developement and Testing

#### Code
- To get started, you'll need JRuby with the Bundler gem installed.

- Create a new plugin or clone and existing from the GitHub [logstash-plugins](https://github.com/logstash-plugins) organization. We also provide [example plugins](https://github.com/logstash-plugins?query=example).

- Install dependencies
```sh
bundle install
```

#### Test

- Update your dependencies

```sh
bundle install
```

- Run tests

```sh
bundle exec rspec
```

### 2. Running your unpublished Plugin in Logstash

#### 2.1 Run in a local Logstash clone

- Edit Logstash `Gemfile` and add the local plugin path, for example:
```ruby
gem "logstash-filter-awesome", :path => "/your/local/logstash-filter-awesome"
```
- Install plugin
```sh
# Logstash 2.3 and higher
bin/logstash-plugin install --no-verify

# Prior to Logstash 2.3
bin/plugin install --no-verify

```
- Run Logstash with your plugin
```sh
bin/logstash -e 'filter {awesome {}}'
```
At this point any modifications to the plugin code will be applied to this local Logstash setup. After modifying the plugin, simply rerun Logstash.

#### 2.2 Run in an installed Logstash

You can use the same **2.1** method to run your plugin in an installed Logstash by editing its `Gemfile` and pointing the `:path` to your local plugin development directory or you can build the gem and install it using:

- Build your plugin gem
```sh
gem build logstash-filter-awesome.gemspec
```
- Install the plugin from the Logstash home
```sh
# Logstash 2.3 and higher
bin/logstash-plugin install --no-verify

# Prior to Logstash 2.3
bin/plugin install --no-verify

```
- Start Logstash and proceed to test the plugin

## Contributing

All contributions are welcome: ideas, patches, documentation, bug reports, complaints, and even something you drew up on a napkin.

Programming is not a required skill. Whatever you've seen about open source and maintainers or community members  saying "send patches or die" - you will not see that here.

It is more important to the community that you are able to contribute.

For more information about contributing, see the [CONTRIBUTING](https://github.com/elastic/logstash/blob/master/CONTRIBUTING.md) file.
