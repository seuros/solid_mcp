# frozen_string_literal: true

require "test_helper"

module SolidMCP
  class SSEResumabilityTest < ActiveSupport::TestCase
    def setup
      SolidMCP::Message.delete_all
      @session_id = "sse-test-session"
    end

    def test_resumes_from_last_event_id
      # Create initial messages
      msg1 = create_message(event_type: "message", data: "First message")
      msg2 = create_message(event_type: "message", data: "Second message")
      msg3 = create_message(event_type: "message", data: "Third message")

      # Simulate first SSE connection
      first_connection_messages = SolidMCP::Message
        .for_session(@session_id)
        .undelivered
        .order(:id)
        .to_a

      assert_equal 3, first_connection_messages.size

      # Mark first two as delivered (simulating successful SSE delivery)
      SolidMCP::Message.mark_delivered([msg1.id, msg2.id])

      # Simulate connection drop and reconnect with last-event-id
      last_event_id = msg2.id

      # Client reconnects and requests messages after last_event_id
      resumed_messages = SolidMCP::Message
        .for_session(@session_id)
        .after_id(last_event_id)
        .undelivered
        .order(:id)
        .to_a

      assert_equal 1, resumed_messages.size
      assert_equal msg3.id, resumed_messages.first.id
      assert_equal "Third message", resumed_messages.first.data
    end

    def test_handles_missing_messages_during_disconnect
      # Initial messages delivered
      msg1 = create_message(event_type: "message", data: "Message 1")
      msg2 = create_message(event_type: "message", data: "Message 2")

      SolidMCP::Message.mark_delivered([msg1.id, msg2.id])
      last_event_id = msg2.id

      # Messages created while client was disconnected
      msg3 = create_message(event_type: "message", data: "Message during disconnect 1")
      msg4 = create_message(event_type: "message", data: "Message during disconnect 2")
      msg5 = create_message(event_type: "ping", data: "Keep alive")

      # Client reconnects
      missed_messages = SolidMCP::Message
        .for_session(@session_id)
        .after_id(last_event_id)
        .undelivered
        .order(:id)
        .to_a

      assert_equal 3, missed_messages.size
      assert_equal [msg3.id, msg4.id, msg5.id], missed_messages.map(&:id)
    end

    def test_event_id_ordering_consistency
      # Create messages with slight time delays to ensure consistent ordering
      messages = []
      10.times do |i|
        messages << create_message(
          event_type: "sequence",
          data: { sequence: i }.to_json
        )
      end

      # IDs should be strictly increasing
      ids = messages.map(&:id)
      assert_equal ids.sort, ids, "Message IDs should be in ascending order"

      # Test resuming from middle
      middle_id = messages[4].id
      resumed = SolidMCP::Message
        .for_session(@session_id)
        .after_id(middle_id)
        .order(:id)
        .to_a

      assert_equal 5, resumed.size
      assert_equal messages[5..9].map(&:id), resumed.map(&:id)
    end

    def test_cleanup_preserves_undelivered_recent_messages
      # Old delivered message
      old_delivered = create_message(
        event_type: "old",
        data: "Should be cleaned up",
        created_at: 2.hours.ago
      )
      old_delivered.update!(delivered_at: 1.hour.ago)

      # Recent undelivered message
      recent_undelivered = create_message(
        event_type: "recent",
        data: "Should be kept"
      )

      # Run cleanup
      SolidMCP::Message.cleanup(
        delivered_retention: 30.minutes,
        undelivered_retention: 24.hours
      )

      remaining = SolidMCP::Message.where(session_id: @session_id)
      assert_equal 1, remaining.count
      assert_equal recent_undelivered.id, remaining.first.id
    end

    def test_simulates_sse_reconnection_flow
      pubsub = SolidMCP::PubSub.new
      received_events = []
      last_received_id = nil

      # Initial connection
      pubsub.subscribe(@session_id) do |message|
        received_events << message
        last_received_id = message[:id]
      end

      # Send some events
      pubsub.broadcast(@session_id, "message", "Event 1")
      pubsub.broadcast(@session_id, "message", "Event 2")

      # Ensure messages are written to database
      MessageWriter.instance.flush

      # Wait for delivery
      assert wait_for_condition { received_events.size == 2 }

      # Simulate disconnect
      pubsub.unsubscribe(@session_id)
      disconnect_checkpoint = last_received_id

      # Events sent while disconnected
      pubsub.broadcast(@session_id, "message", "Event 3")
      pubsub.broadcast(@session_id, "message", "Event 4")

      # Give time for messages to be written
      sleep 0.1

      # Simulate reconnection with last-event-id
      reconnect_events = []
      pubsub.subscribe(@session_id) do |message|
        # In real SSE, we'd check if message[:id] > disconnect_checkpoint
        reconnect_events << message if message[:id] && disconnect_checkpoint && message[:id] > disconnect_checkpoint
      end

      # Wait a bit for subscription to catch up
      sleep 0.2

      # Send a new event to trigger processing
      pubsub.broadcast(@session_id, "message", "Event 5")

      # Should receive the new event
      assert wait_for_condition { reconnect_events.any? }

      pubsub.shutdown
    end

    def test_different_event_types_resumability
      # Create different event types
      msg1 = create_message(event_type: "message", data: "Chat message")
      msg2 = create_message(event_type: "ping", data: "")
      create_message(event_type: "notification", data: { alert: "New item" }.to_json)
      create_message(event_type: "message", data: "Another chat")

      # Mark first two as delivered
      SolidMCP::Message.mark_delivered([msg1.id, msg2.id])

      # Resume should get all undelivered regardless of type
      resumed = SolidMCP::Message
        .for_session(@session_id)
        .after_id(msg2.id)
        .undelivered
        .order(:id)

      assert_equal 2, resumed.count
      assert_equal ["notification", "message"], resumed.pluck(:event_type)
    end

    private

    def create_message(attrs = {})
      defaults = {
        session_id: @session_id,
        created_at: Time.current
      }
      SolidMCP::Message.create!(defaults.merge(attrs))
    end
  end
end