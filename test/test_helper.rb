# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# Set up test environment
ENV["RAILS_ENV"] = "test"

require "active_record"
require "active_job"
require "minitest/autorun"
require "solid_mcp"

# Set up in-memory SQLite database for testing
ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: ":memory:"
)

# Create the messages table
ActiveRecord::Schema.define do
  create_table :solid_mcp_messages do |t|
    t.string :session_id, null: false, limit: 36
    t.string :event_type, null: false, limit: 50
    t.text :data
    t.datetime :created_at, null: false
    t.datetime :delivered_at
    
    t.index [:session_id, :id], name: 'idx_solid_mcp_messages_on_session_and_id'
    t.index [:delivered_at, :created_at], name: 'idx_solid_mcp_messages_on_delivered_and_created'
  end
end

# Model is loaded automatically by the gem

# Test helper methods
module SolidMCP
  module TestHelper
    def wait_for_condition(timeout = 2)
      start_time = Time.now
      while Time.now - start_time < timeout
        return true if yield
        sleep 0.01
      end
      false
    end

    def capture_logs
      original_logger = Rails.logger if defined?(Rails)
      logs = StringIO.new
      test_logger = Logger.new(logs)
      
      if defined?(Rails)
        Rails.stub :logger, test_logger do
          yield
        end
      else
        yield
      end
      
      logs.string
    ensure
      Rails.logger = original_logger if defined?(Rails) && original_logger
    end
  end
end

class Minitest::Test
  include SolidMCP::TestHelper
end
