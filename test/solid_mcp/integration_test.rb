# frozen_string_literal: true

require "test_helper"

module SolidMCP
  class IntegrationTest < Minitest::Test
    def setup
      SolidMCP::Message.delete_all
      @session_id = "integration-test-session"
      
      # Configure for fast testing
      SolidMCP.configuration.flush_interval = 0.01
      SolidMCP.configuration.polling_interval = 0.05
      SolidMCP.configuration.batch_size = 10
    end

    def teardown
      MessageWriter.instance.shutdown
    end

    def test_full_message_flow_with_batching
      pubsub = PubSub.new
      received = []
      
      pubsub.subscribe(@session_id) do |message|
        received << message
      end
      
      # Send multiple messages quickly to test batching
      10.times do |i|
        pubsub.broadcast(@session_id, "batch_test", { number: i })
      end
      
      # Wait for all messages to be received
      assert wait_for_condition(3) { received.size == 10 }
      
      # Verify order is preserved
      received.each_with_index do |msg, i|
        data = JSON.parse(msg[:data])
        assert_equal i, data["number"]
      end
      
      # Check that messages were written to database
      db_messages = SolidMCP::Message.for_session(@session_id).order(:id)
      assert_equal 10, db_messages.count
      
      # All should be marked as delivered
      assert_equal 10, db_messages.delivered.count
      
      pubsub.shutdown
    end

    def test_concurrent_publishers
      pubsub = PubSub.new
      received = Concurrent::Array.new
      
      pubsub.subscribe(@session_id) do |message|
        received << message
      end
      
      # Simulate multiple concurrent publishers
      threads = 5.times.map do |thread_num|
        Thread.new do
          5.times do |msg_num|
            pubsub.broadcast(
              @session_id, 
              "concurrent", 
              { thread: thread_num, message: msg_num }
            )
          end
        end
      end
      
      threads.each(&:join)
      
      # Should receive all 25 messages
      assert wait_for_condition(3) { received.size == 25 }
      
      # Group by thread and verify each thread sent 5 messages
      by_thread = received.group_by { |msg| JSON.parse(msg[:data])["thread"] }
      assert_equal 5, by_thread.keys.size
      by_thread.each do |thread_num, messages|
        assert_equal 5, messages.size
      end
      
      pubsub.shutdown
    end

    def test_multiple_sessions_isolation
      pubsub = PubSub.new
      session1_received = []
      session2_received = []
      
      session1 = "session-isolation-1"
      session2 = "session-isolation-2"
      
      pubsub.subscribe(session1) { |msg| session1_received << msg }
      pubsub.subscribe(session2) { |msg| session2_received << msg }
      
      # Broadcast to different sessions
      pubsub.broadcast(session1, "test", "Message for session 1")
      pubsub.broadcast(session2, "test", "Message for session 2")
      pubsub.broadcast(session1, "test", "Another for session 1")
      
      # Wait for messages
      assert wait_for_condition { session1_received.size == 2 && session2_received.size == 1 }
      
      # Verify isolation
      assert_equal 2, session1_received.size
      assert_equal 1, session2_received.size
      
      session1_msgs = session1_received.map { |m| m[:data] }
      assert_includes session1_msgs, "Message for session 1"
      assert_includes session1_msgs, "Another for session 1"
      
      assert_equal "Message for session 2", session2_received.first[:data]
      
      pubsub.shutdown
    end

    def test_graceful_shutdown_delivers_pending_messages
      pubsub = PubSub.new
      received = []
      
      pubsub.subscribe(@session_id) do |message|
        received << message
      end
      
      # Send messages and immediately shutdown
      5.times do |i|
        pubsub.broadcast(@session_id, "shutdown_test", "Message #{i}")
      end
      
      # Shutdown should flush pending messages
      pubsub.shutdown
      
      # Give a little time for final delivery
      sleep 0.2
      
      # All messages should have been written to database
      db_count = SolidMCP::Message.where(session_id: @session_id).count
      assert_equal 5, db_count
    end

    def test_error_recovery_in_message_writer
      # This test is tricky because we need to simulate a database error
      # For now, we'll test that the writer continues after handling bad data
      
      pubsub = PubSub.new
      received = []
      
      pubsub.subscribe(@session_id) do |message|
        received << message
      end
      
      # Send a mix of valid and potentially problematic data
      pubsub.broadcast(@session_id, "test", "Simple string")
      pubsub.broadcast(@session_id, "test", { complex: { nested: "data" } })
      pubsub.broadcast(@session_id, "test", ["array", "of", "items"])
      pubsub.broadcast(@session_id, "test", nil)
      pubsub.broadcast(@session_id, "test", "")
      
      # Should handle all message types
      assert wait_for_condition(3) { received.size >= 5 }
      
      pubsub.shutdown
    end

    def test_cleanup_job_execution
      # Create old messages
      old_delivered = SolidMCP::Message.create!(
        session_id: "cleanup-test",
        event_type: "old",
        data: "old data",
        created_at: 2.hours.ago,
        delivered_at: 2.hours.ago
      )
      
      old_undelivered = SolidMCP::Message.create!(
        session_id: "cleanup-test",
        event_type: "abandoned",
        data: "never delivered",
        created_at: 25.hours.ago
      )
      
      recent = SolidMCP::Message.create!(
        session_id: "cleanup-test",
        event_type: "recent",
        data: "keep this",
        created_at: 5.minutes.ago
      )
      
      # Run cleanup job
      CleanupJob.new.perform
      
      # Old messages should be gone
      assert_nil SolidMCP::Message.find_by(id: old_delivered.id)
      assert_nil SolidMCP::Message.find_by(id: old_undelivered.id)
      
      # Recent should remain
      assert SolidMCP::Message.exists?(recent.id)
    end

    def test_sse_event_format
      # Test that the data format matches what SSE expects
      pubsub = PubSub.new
      received = []
      
      pubsub.subscribe(@session_id) do |message|
        received << message
      end
      
      # Different event types that SSE might use
      pubsub.broadcast(@session_id, "message", { text: "Hello SSE" })
      pubsub.broadcast(@session_id, "ping", "")
      pubsub.broadcast(@session_id, "close", { reason: "Server shutdown" })
      
      assert wait_for_condition { received.size == 3 }
      
      # Each message should have the SSE structure
      received.each do |msg|
        assert msg.key?(:id), "Message should have an ID for SSE"
        assert msg.key?(:event_type), "Message should have event type"
        assert msg.key?(:data), "Message should have data"
        
        # ID should be numeric and increasing
        assert_kind_of Integer, msg[:id]
      end
      
      # Event types should match
      assert_equal ["message", "ping", "close"], received.map { |m| m[:event_type] }
      
      pubsub.shutdown
    end
  end
end