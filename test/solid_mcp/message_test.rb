# frozen_string_literal: true

require "test_helper"

module SolidMCP
  class MessageTest < ActiveSupport::TestCase
    def setup
      SolidMCP::Message.delete_all
    end

    def test_required_fields
      message = Message.new

      # Should require session_id and event_type
      assert_raises(ActiveRecord::NotNullViolation) do
        message.save!
      end
    end

    def test_creates_valid_message
      message = Message.create!(
        session_id: "test-123",
        event_type: "message",
        data: "Hello, World!",
        created_at: Time.current
      )

      assert message.persisted?
      assert_equal "test-123", message.session_id
      assert_equal "message", message.event_type
      assert_equal "Hello, World!", message.data
      assert_nil message.delivered_at
    end

    def test_scopes
      session1 = "scope-test-1"
      session2 = "scope-test-2"

      # Create test data
      msg1 = Message.create!(
        session_id: session1,
        event_type: "test",
        data: "1",
        created_at: Time.current
      )

      msg2 = Message.create!(
        session_id: session1,
        event_type: "test",
        data: "2",
        created_at: Time.current,
        delivered_at: Time.current
      )

      msg3 = Message.create!(
        session_id: session2,
        event_type: "test",
        data: "3",
        created_at: Time.current
      )

      # Test for_session scope
      session1_messages = Message.for_session(session1)
      assert_equal 2, session1_messages.count
      assert_includes session1_messages, msg1
      assert_includes session1_messages, msg2

      # Test undelivered scope
      undelivered = Message.undelivered
      assert_equal 2, undelivered.count
      assert_includes undelivered, msg1
      assert_includes undelivered, msg3

      # Test delivered scope
      delivered = Message.delivered
      assert_equal 1, delivered.count
      assert_equal msg2, delivered.first

      # Test after_id scope
      after_first = Message.after_id(msg1.id)
      assert_equal 2, after_first.count
      assert_includes after_first, msg2
      assert_includes after_first, msg3
    end

    def test_mark_delivered
      messages = 3.times.map do |i|
        Message.create!(
          session_id: "mark-test",
          event_type: "test",
          data: i.to_s,
          created_at: Time.current
        )
      end

      # Mark first two as delivered
      Message.mark_delivered([messages[0].id, messages[1].id])

      messages.each(&:reload)

      assert_not_nil messages[0].delivered_at
      assert_not_nil messages[1].delivered_at
      assert_nil messages[2].delivered_at
    end

    def test_cleanup_old_delivered
      # Create messages with different ages
      old_delivered = Message.create!(
        session_id: "cleanup-test",
        event_type: "old",
        data: "old",
        created_at: 2.hours.ago,
        delivered_at: 2.hours.ago
      )

      recent_delivered = Message.create!(
        session_id: "cleanup-test",
        event_type: "recent",
        data: "recent",
        created_at: 30.minutes.ago,
        delivered_at: 30.minutes.ago
      )

      # Old delivered scope
      old = Message.old_delivered(1.hour)
      assert_equal 1, old.count
      assert_equal old_delivered, old.first

      # Cleanup
      count = Message.old_delivered(1.hour).delete_all
      assert_equal 1, count

      # Recent should remain
      assert Message.exists?(recent_delivered.id)
      assert !Message.exists?(old_delivered.id)
    end

    def test_cleanup_old_undelivered
      # Create messages with different ages
      old_undelivered = Message.create!(
        session_id: "cleanup-test",
        event_type: "abandoned",
        data: "old",
        created_at: 25.hours.ago
      )

      recent_undelivered = Message.create!(
        session_id: "cleanup-test",
        event_type: "new",
        data: "recent",
        created_at: 1.hour.ago
      )

      # Old undelivered scope
      old = Message.old_undelivered(24.hours)
      assert_equal 1, old.count
      assert_equal old_undelivered, old.first

      # Cleanup
      count = Message.old_undelivered(24.hours).delete_all
      assert_equal 1, count

      # Recent should remain
      assert Message.exists?(recent_undelivered.id)
      assert !Message.exists?(old_undelivered.id)
    end

    def test_cleanup_method
      # Create various messages
      Message.create!(
        session_id: "cleanup",
        event_type: "old_delivered",
        data: "1",
        created_at: 2.hours.ago,
        delivered_at: 2.hours.ago
      )

      Message.create!(
        session_id: "cleanup",
        event_type: "old_undelivered",
        data: "2",
        created_at: 25.hours.ago
      )

      recent = Message.create!(
        session_id: "cleanup",
        event_type: "recent",
        data: "3",
        created_at: 5.minutes.ago
      )

      # Run cleanup
      Message.cleanup(
        delivered_retention: 1.hour,
        undelivered_retention: 24.hours
      )

      # Only recent should remain
      remaining = Message.all
      assert_equal 1, remaining.count
      assert_equal recent, remaining.first
    end

    def test_session_id_length_limit
      # Test that session_id respects the 36 character limit
      message = Message.new(
        session_id: "a" * 36, # Max length
        event_type: "test",
        data: "test",
        created_at: Time.current
      )

      assert message.valid?

      # This would depend on database enforcement
      # Some databases truncate, others error
    end

    def test_event_type_length_limit
      # Test that event_type respects the 50 character limit
      message = Message.new(
        session_id: "test",
        event_type: "a" * 50, # Max length
        data: "test",
        created_at: Time.current
      )

      assert message.valid?
    end

    def test_data_can_be_nil
      message = Message.create!(
        session_id: "test",
        event_type: "ping",
        data: nil,
        created_at: Time.current
      )

      assert message.persisted?
      assert_nil message.data
    end

    def test_indexes_exist
      # This is more of a schema test, but ensures our indexes are created
      indexes = ActiveRecord::Base.connection.indexes("solid_mcp_messages")
      index_names = indexes.map(&:name)

      assert_includes index_names, "idx_solid_mcp_messages_on_session_and_id"
      assert_includes index_names, "idx_solid_mcp_messages_on_delivered_and_created"
    end
  end
end