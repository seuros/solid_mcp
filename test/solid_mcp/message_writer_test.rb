# frozen_string_literal: true

require "test_helper"

module SolidMCP
  class MessageWriterTest < ActiveSupport::TestCase
    def setup
      # Clear any existing messages
      SolidMCP::Message.delete_all
      
      # Configure for faster testing
      SolidMCP.configuration.flush_interval = 0.01
      SolidMCP.configuration.batch_size = 200
      
      # Ensure MessageWriter is properly initialized
      # The singleton will initialize itself on first access
      MessageWriter.instance
    end

    def teardown
      # Ensure any pending messages are flushed
      if MessageWriter.instance.instance_variable_get(:@executor)&.running?
        MessageWriter.instance.flush
      end
      SolidMCP::Message.delete_all
    end

    def test_singleton_instance
      writer1 = MessageWriter.instance
      writer2 = MessageWriter.instance
      assert_same writer1, writer2
    end

    def test_enqueue_non_blocking
      start_time = Time.now
      
      # Enqueue multiple messages quickly
      100.times do |i|
        MessageWriter.instance.enqueue("session-#{i}", "message", { count: i })
      end
      
      elapsed_time = Time.now - start_time
      # Should be very fast since it's just queuing in memory
      assert elapsed_time < 0.1, "Enqueue took too long: #{elapsed_time}s"
    end

    def test_messages_are_written_to_database
      session_id = "test-session-123"
      event_type = "test-event"
      data = { message: "Hello, World!" }

      MessageWriter.instance.enqueue(session_id, event_type, data)
      MessageWriter.instance.flush
      
      # Wait for the writer thread to process
      assert wait_for_condition(3) { SolidMCP::Message.count > 0 }

      message = SolidMCP::Message.first
      assert_not_nil message, "No message was written to database"
      assert_equal session_id, message.session_id
      assert_equal event_type, message.event_type
      assert_equal data.to_json, message.data
    end

    def test_batch_writing
      # Configure smaller batch size for testing
      SolidMCP.configuration.batch_size = 5
      SolidMCP.configuration.flush_interval = 0.01

      # Enqueue exactly batch_size messages
      5.times do |i|
        MessageWriter.instance.enqueue("session-batch", "event", { num: i })
      end

      MessageWriter.instance.flush
      
      # Wait for batch to be written
      assert wait_for_condition(2) { SolidMCP::Message.count == 5 }

      # All messages should be written in one batch
      messages = SolidMCP::Message.where(session_id: "session-batch").order(:id)
      assert_equal 5, messages.count
      
      # Verify message order is preserved
      messages.each_with_index do |msg, i|
        data = JSON.parse(msg.data)
        assert_equal i, data["num"]
      end
    ensure
      # Reset configuration
      SolidMCP.configuration.batch_size = 200
      SolidMCP.configuration.flush_interval = 0.05
    end

    def test_handles_string_data
      MessageWriter.instance.enqueue("session-string", "event", "plain string data")
      MessageWriter.instance.flush
      
      assert wait_for_condition(2) { SolidMCP::Message.count > 0 }

      message = SolidMCP::Message.first
      assert_equal "plain string data", message.data
    end

    def test_handles_hash_data
      data = { key: "value", nested: { inner: "data" } }
      MessageWriter.instance.enqueue("session-hash", "event", data)
      MessageWriter.instance.flush
      
      assert wait_for_condition(2) { SolidMCP::Message.count > 0 }

      message = SolidMCP::Message.first
      assert_equal data.to_json, message.data
      
      # Verify it can be parsed back
      parsed = JSON.parse(message.data)
      assert_equal "value", parsed["key"]
      assert_equal "data", parsed["nested"]["inner"]
    end

    def test_shutdown_flushes_remaining_messages
      # Enqueue messages
      10.times do |i|
        MessageWriter.instance.enqueue("shutdown-test", "event", { num: i })
      end

      # Immediately shutdown
      MessageWriter.instance.shutdown

      # All messages should be written
      assert_equal 10, SolidMCP::Message.where(session_id: "shutdown-test").count
    ensure
      # Reset the singleton after this test
      MessageWriter.reset!
    end

    def test_thread_restarts_on_error
      skip "Complex thread testing - would need to mock internal methods"
    end
  end
end