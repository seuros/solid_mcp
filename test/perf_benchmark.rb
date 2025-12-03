# frozen_string_literal: true

# Benchmark comparing Ruby vs Rust MessageWriter performance
#
# Usage:
#   ruby test/benchmark.rb
#   DISABLE_SOLID_MCP_NATIVE=1 ruby test/benchmark.rb  # Pure Ruby only

require "bundler/setup"
require "active_job"
require "solid_mcp"
require "benchmark"
require "json"
require "fileutils"

# Setup test database
DB_PATH = File.expand_path("benchmark_test.db", __dir__)
FileUtils.rm_f(DB_PATH)

# Configure SolidMCP
SolidMCP.configure do |config|
  config.batch_size = 100
  config.flush_interval = 0.01
  config.polling_interval = 0.01
  config.max_queue_size = 50_000
end

# Setup ActiveRecord with SQLite
require "active_record"
ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: DB_PATH
)

# Create messages table
ActiveRecord::Schema.define do
  create_table :solid_mcp_messages, force: true do |t|
    t.string :session_id, null: false
    t.string :event_type, null: false
    t.text :data
    t.datetime :delivered_at
    t.timestamps
  end
  add_index :solid_mcp_messages, [:session_id, :created_at]
end

# Define the Message model
class SolidMCP::Message < ActiveRecord::Base
  self.table_name = "solid_mcp_messages"
end

puts "=" * 60
puts "SolidMCP Benchmark"
puts "=" * 60
puts
puts "Native extension available: #{SolidMCP::NativeSpeedup.available?}"
if SolidMCP::NativeSpeedup.available?
  puts "Native extension version: #{SolidMCP::NativeSpeedup.version}"
end
puts

MESSAGE_COUNTS = [100, 1_000, 10_000]
SESSIONS = ["session-1", "session-2", "session-3"]

def generate_message(session_id)
  {
    session_id: session_id,
    event_type: "test.event",
    data: { timestamp: Time.now.to_i, value: rand(1000) }.to_json
  }
end

def run_benchmark(count)
  puts "-" * 40
  puts "Enqueuing #{count} messages"
  puts "-" * 40

  # Reset singleton for each benchmark
  SolidMCP::MessageWriter.reset!
  writer = SolidMCP::MessageWriter.instance

  messages = count.times.map do |i|
    generate_message(SESSIONS[i % SESSIONS.size])
  end

  # Clear table
  SolidMCP::Message.delete_all

  result = Benchmark.measure do
    messages.each do |msg|
      writer.enqueue(msg[:session_id], msg[:event_type], msg[:data])
    end
    writer.flush
    # Wait for batch writes to complete
    sleep 0.1
    writer.shutdown
  end

  written = SolidMCP::Message.count
  rate = count / result.real

  puts format("  Time:     %.4fs", result.real)
  puts format("  Messages: %d written", written)
  puts format("  Rate:     %.0f msg/s", rate)
  puts

  rate
end

puts "Warming up..."
run_benchmark(100)

puts
puts "Running benchmarks..."
puts

results = MESSAGE_COUNTS.map do |count|
  [count, run_benchmark(count)]
end

puts "=" * 60
puts "Summary"
puts "=" * 60
puts
puts format("%-15s %15s", "Messages", "Rate (msg/s)")
puts "-" * 30
results.each do |count, rate|
  puts format("%-15d %15.0f", count, rate)
end

# Cleanup
FileUtils.rm_f(DB_PATH)
