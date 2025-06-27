# SolidMCP

SolidMCP is a high-performance, database-backed pub/sub engine specifically designed for ActionMCP (Model Context Protocol for Rails). It provides reliable message delivery for MCP's Server-Sent Events (SSE) with support for SQLite, PostgreSQL, and MySQL.

## Features

- **Database-agnostic**: Works with SQLite, PostgreSQL, and MySQL
- **Session-based routing**: Optimized for MCP's point-to-point messaging pattern
- **Batched writes**: Handles SQLite's single-writer limitation efficiently
- **Automatic cleanup**: Configurable retention periods for delivered/undelivered messages
- **Thread-safe**: Dedicated writer thread with in-memory queuing
- **SSE resumability**: Supports reconnection with last-event-id
- **Rails Engine**: Seamless integration with Rails applications
- **Multiple backends**: Database backend by default, Redis backend coming soon

## Requirements

- Ruby 3.0+
- Rails 8.0+
- ActiveRecord 8.0+
- SQLite, PostgreSQL, or MySQL database

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'solid_mcp'
```

And then execute:

```bash
bundle install
```

Run the installation generator:

```bash
bin/rails generate solid_mcp:install
bin/rails db:migrate
```

This will:
- Create a migration for the `solid_mcp_messages` table
- Create an initializer with default configuration

## Configuration

Configure SolidMCP in your Rails application:

```ruby
# config/initializers/solid_mcp.rb
SolidMcp.configure do |config|
  # Number of messages to write in a single batch
  config.batch_size = 200
  
  # Seconds between batch flushes
  config.flush_interval = 0.05
  
  # Polling interval for checking new messages
  config.polling_interval = 0.1
  
  # Maximum time to wait for messages before timeout
  config.max_wait_time = 30
  
  # How long to keep delivered messages
  config.delivered_retention = 1.hour
  
  # How long to keep undelivered messages
  config.undelivered_retention = 24.hours
end
```

## Usage with ActionMCP

In your `config/mcp.yml`:

```yaml
production:
  adapter: solid_mcp
  polling_interval: 0.5.seconds
  batch_size: 200
  flush_interval: 0.05
```

## Architecture

SolidMCP is implemented as a Rails Engine with the following components:

### Core Components

1. **SolidMCP::MessageWriter**: Singleton that handles batched writes to the database
   - Non-blocking enqueue operation
   - Dedicated writer thread per Rails process
   - Automatic batching and flushing
   - Graceful shutdown with pending message delivery

2. **SolidMCP::PubSub**: Main interface for publishing and subscribing to messages
   - Session-based subscriptions (not channel-based)
   - Automatic listener management per session
   - Thread-safe operations

3. **SolidMCP::Subscriber**: Handles polling for new messages
   - Efficient database queries using indexes
   - Automatic message delivery tracking
   - Configurable polling intervals

4. **SolidMCP::Message**: ActiveRecord model for message storage
   - Optimized indexes for polling and cleanup
   - Scopes for message filtering
   - Built-in cleanup methods

### Message Flow

1. Publisher calls `broadcast(session_id, event_type, data)`
2. MessageWriter queues the message in memory
3. Writer thread batches messages and writes to database
4. Subscriber polls for new messages for its session
5. Messages are marked as delivered after successful processing

## Database Schema

The gem creates a `solid_mcp_messages` table:

```ruby
create_table :solid_mcp_messages do |t|
  t.string :session_id, null: false, limit: 36      # MCP session identifier
  t.string :event_type, null: false, limit: 50      # SSE event type
  t.text :data                                       # Message payload (usually JSON)
  t.datetime :created_at, null: false                # Message creation time
  t.datetime :delivered_at                           # Delivery timestamp
  
  t.index [:session_id, :id], name: 'idx_solid_mcp_messages_on_session_and_id'
  t.index [:delivered_at, :created_at], name: 'idx_solid_mcp_messages_on_delivered_and_created'
end
```

## Performance Considerations

### SQLite
- Single writer thread prevents "database is locked" errors
- Batching reduces write frequency
- Consider WAL mode for better concurrency

### PostgreSQL/MySQL
- Benefits from batching to reduce transaction overhead
- Can handle multiple writers but single writer is maintained for consistency
- Consider partitioning for high-volume applications

## Maintenance

### Automatic Cleanup

Old messages are automatically cleaned up based on retention settings:

```ruby
# Run periodically (e.g., with whenever gem or solid_queue)
SolidMCP::CleanupJob.perform_later

# Or directly:
SolidMCP::Message.cleanup
```

### Manual Cleanup

```ruby
# Clean up delivered messages older than 1 hour
SolidMCP::Message.old_delivered(1.hour).delete_all

# Clean up undelivered messages older than 24 hours
SolidMCP::Message.old_undelivered(24.hours).delete_all
```

### Monitoring

```ruby
# Check message queue size
SolidMCP::Message.undelivered.count

# Check messages for a specific session
SolidMCP::Message.for_session(session_id).count

# Find stuck messages
SolidMCP::Message.undelivered.where('created_at < ?', 1.hour.ago)
```

## Testing

The gem includes a test implementation for use in test environments:

```ruby
# In test environment, SolidMCP::PubSub automatically uses TestPubSub
# which provides immediate delivery without database persistence
```

Run the test suite:

```bash
bundle exec rake test
```

### Testing in Your Application

```ruby
# test/test_helper.rb
class ActiveSupport::TestCase
  setup do
    SolidMCP::Message.delete_all
  end
end

# In your tests
test "broadcasts message to session" do
  pubsub = SolidMCP::PubSub.new
  messages = []
  
  pubsub.subscribe("test-session") do |msg|
    messages << msg
  end
  
  pubsub.broadcast("test-session", "test_event", { data: "test" })
  
  assert_equal 1, messages.size
  assert_equal "test_event", messages.first[:event_type]
end
```

## SSE Integration

SolidMCP is designed to work seamlessly with Server-Sent Events:

```ruby
# In your SSE controller
def sse_endpoint
  response.headers['Content-Type'] = 'text/event-stream'
  
  pubsub = SolidMCP::PubSub.new
  last_event_id = request.headers['Last-Event-ID']
  
  # Resume from last event if reconnecting
  if last_event_id
    missed_messages = SolidMCP::Message
      .for_session(session_id)
      .after_id(last_event_id)
      .undelivered
    
    missed_messages.each do |msg|
      response.stream.write "id: #{msg.id}\n"
      response.stream.write "event: #{msg.event_type}\n"
      response.stream.write "data: #{msg.data}\n\n"
    end
  end
  
  # Subscribe to new messages
  pubsub.subscribe(session_id) do |message|
    response.stream.write "id: #{message[:id]}\n"
    response.stream.write "event: #{message[:event_type]}\n"
    response.stream.write "data: #{message[:data]}\n\n"
  end
ensure
  pubsub&.unsubscribe(session_id)
  response.stream.close
end
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests.

### Running Tests

```bash
# Run all tests
bundle exec rake test

# Run specific test file
bundle exec ruby test/solid_mcp/message_test.rb
```

## Roadmap

### Redis Backend (Coming Soon)

Future versions will support Redis as an alternative backend:

```ruby
# config/initializers/solid_mcp.rb
SolidMCP.configure do |config|
  config.backend = :redis
  config.redis_url = ENV['REDIS_URL']
end
```

This will provide:
- Lower latency for high-traffic applications
- Pub/Sub without polling
- Automatic expiration of old messages
- Better horizontal scaling

## Comparison with Other Solutions

| Feature | SolidMCP | ActionCable + Redis | Custom Polling |
|---------|----------|-------------------|----------------|
| No Redis Required | ✅ | ❌ | ✅ |
| SSE Resumability | ✅ | ❌ | Manual |
| Horizontal Scaling | ✅ (with DB) | ✅ | ❌ |
| Message Persistence | ✅ | ❌ | Manual |
| Batch Writing | ✅ | N/A | ❌ |
| SQLite Support | ✅ | ❌ | ✅ |

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/seuros/solid_mcp.

### Development Setup

1. Fork the repository
2. Clone your fork
3. Install dependencies: `bundle install`
4. Create a feature branch: `git checkout -b my-feature`
5. Make your changes and add tests
6. Run tests: `bundle exec rake test`
7. Push to your fork and submit a pull request

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).