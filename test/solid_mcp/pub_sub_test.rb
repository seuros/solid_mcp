# frozen_string_literal: true

require "test_helper"

module SolidMCP
  class PubSubTest < Minitest::Test
    def setup
      @pubsub = PubSub.new
      @received_messages = []
      @callback = ->(message) { @received_messages << message }
    end

    def teardown
      @pubsub.shutdown if @pubsub
    end

    def test_subscribe_and_broadcast
      session_id = "test-session-123"
      
      @pubsub.subscribe(session_id, &@callback)
      @pubsub.broadcast(session_id, "test_event", { message: "Hello" })
      
      # Wait for message to be delivered
      assert wait_for_condition { @received_messages.any? }
      
      message = @received_messages.first
      assert_equal "test_event", message[:event_type]
      assert_equal({ message: "Hello" }.to_json, message[:data])
    end

    def test_multiple_subscribers_same_session
      session_id = "multi-sub-session"
      received1 = []
      received2 = []
      
      @pubsub.subscribe(session_id) { |msg| received1 << msg }
      @pubsub.subscribe(session_id) { |msg| received2 << msg }
      
      @pubsub.broadcast(session_id, "event", "data")
      
      assert wait_for_condition { received1.any? && received2.any? }
      assert_equal 1, received1.size
      assert_equal 1, received2.size
    end

    def test_unsubscribe_stops_messages
      session_id = "unsub-session"
      
      @pubsub.subscribe(session_id, &@callback)
      @pubsub.broadcast(session_id, "event1", "data1")
      
      assert wait_for_condition { @received_messages.size == 1 }
      
      @pubsub.unsubscribe(session_id)
      @pubsub.broadcast(session_id, "event2", "data2")
      
      # Give it time to potentially receive the message
      sleep 0.1
      
      # Should still only have 1 message
      assert_equal 1, @received_messages.size
    end

    def test_different_sessions_isolated
      session1 = "session-1"
      session2 = "session-2"
      received1 = []
      received2 = []
      
      @pubsub.subscribe(session1) { |msg| received1 << msg }
      @pubsub.subscribe(session2) { |msg| received2 << msg }
      
      @pubsub.broadcast(session1, "event", "for session 1")
      @pubsub.broadcast(session2, "event", "for session 2")
      
      assert wait_for_condition { received1.any? && received2.any? }
      
      assert_equal 1, received1.size
      assert_equal 1, received2.size
      assert_equal "for session 1", received1.first[:data]
      assert_equal "for session 2", received2.first[:data]
    end

    def test_shutdown_stops_all_listeners
      session_id = "shutdown-test"
      
      @pubsub.subscribe(session_id, &@callback)
      @pubsub.shutdown
      
      # After shutdown, broadcasts shouldn't be delivered
      @pubsub.broadcast(session_id, "event", "data")
      sleep 0.1
      
      assert_empty @received_messages
    end
  end
end