# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# Set up test environment
ENV["RAILS_ENV"] = "test"

require "active_record"
require "active_job"
require "active_support/test_case"
require "minitest/autorun"
require "solid_mcp"

# Global flag to track if database has been initialized
$solid_mcp_test_db_initialized ||= false

unless $solid_mcp_test_db_initialized
  # Use shared memory SQLite database for better thread visibility
  ActiveRecord::Base.establish_connection(
    adapter: "sqlite3",
    database: "file:solid_mcp_test?mode=memory&cache=shared",
    pool: 10,  # Increase pool size for multiple threads
    timeout: 5000
  )

  # Create the messages table
  ActiveRecord::Schema.define do
    create_table :solid_mcp_messages, force: true do |t|
      t.string :session_id, null: false, limit: 36
      t.string :event_type, null: false, limit: 50
      t.text :data
      t.datetime :created_at, null: false
      t.datetime :delivered_at
      
      t.index [:session_id, :id], name: 'idx_solid_mcp_messages_on_session_and_id'
      t.index [:delivered_at, :created_at], name: 'idx_solid_mcp_messages_on_delivered_and_created'
    end
  end
  
  # Mark as initialized
  $solid_mcp_test_db_initialized = true
end

# Load the app/models directory
$LOAD_PATH.unshift File.expand_path("../app/models", __dir__)
require "solid_mcp/message"

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

class ActiveSupport::TestCase
  include SolidMCP::TestHelper
end