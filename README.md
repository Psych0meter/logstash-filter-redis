# Logstash Filter Plugin: Redis Lookup

This is a custom [Logstash](https://github.com/elastic/logstash) filter plugin that enriches event data by querying a Redis datastore. The plugin retrieves values from Redis using a field in the event as the lookup key and supports various Redis data types (`string`, `hash`, `list`, `set`, `zset`).

It is fully free and open source under the Apache 2.0 License.

## 🔧 Features

- Look up values from Redis based on a specified event field.
- Supports Redis types: `string`, `hash`, `list`, `set`, and `zset`.
- Optional fallback value if the key is not found or Redis is unreachable.
- Configurable key source field, destination field, and override behavior.

## 📄 Configuration Example

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
````

## 🧠 How It Works

Given an event field (e.g., `user_id`), the plugin queries Redis for a key matching the field’s value. Based on the key type, the plugin updates the event with the corresponding value(s):

* For a `string`, the value is set directly at the destination field.
* For a `hash`, each field in the hash becomes a nested field under the destination.
* For a `list`, `set`, or `zset`, the destination field is set to an array of values.

If the Redis key does not exist or an error occurs, the plugin can optionally populate the destination field with a fallback value.

## Documentation

Logstash provides infrastructure to automatically generate documentation for this plugin. We use the asciidoc format to write documentation so any comments in the source code will be first converted into asciidoc and then into html. All plugin documentation are placed under one [central location](http://www.elastic.co/guide/en/logstash/current/).

- For formatting code or config example, you can use the asciidoc `[source,ruby]` directive
- For more asciidoc formatting tips, see the excellent reference here https://github.com/elastic/docs#asciidoc-guide

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