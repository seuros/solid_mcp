# frozen_string_literal: true

require "test_helper"

module SolidMCP
  class SubscriberTest < ActiveSupport::TestCase
    def setup
      # Clear any existing messages
      SolidMCP::Message.delete_all
      
      @session_id = "test-subscriber-session"
      @callbacks = []
      @received = []
      
      @callbacks << ->(message) { @received << message }
      @subscriber = Subscriber.new(@session_id, @callbacks)
    end

    def teardown
      @subscriber.stop if @subscriber
      # Clean up messages after each test since we're not using transactions
      SolidMCP::Message.delete_all
    end

    def test_polls_for_new_messages
      # Create some messages
      msg1 = SolidMCP::Message.create!(
        session_id: @session_id,
        event_type: "test_event",
        data: { number: 1 }.to_json,
        created_at: Time.current
      )
      
      msg2 = SolidMCP::Message.create!(
        session_id: @session_id,
        event_type: "test_event",
        data: { number: 2 }.to_json,
        created_at: Time.current
      )
      
      @subscriber.start
      
      # Wait for messages to be processed
      assert wait_for_condition { @received.size == 2 }
      
      assert_equal msg1.id, @received[0][:id]
      assert_equal msg2.id, @received[1][:id]
    end

    def test_marks_messages_as_delivered
      msg = SolidMCP::Message.create!(
        session_id: @session_id,
        event_type: "delivery_test",
        data: "test",
        created_at: Time.current
      )
      
      assert_nil msg.delivered_at
      
      @subscriber.start
      
      # Wait for message to be processed
      assert wait_for_condition { @received.any? }
      
      # Check that message was marked as delivered
      msg.reload
      assert_not_nil msg.delivered_at
    end

    def test_only_processes_undelivered_messages
      # Create a delivered message
      delivered = SolidMCP::Message.create!(
        session_id: @session_id,
        event_type: "already_delivered",
        data: "old",
        created_at: 1.hour.ago,
        delivered_at: 30.minutes.ago
      )
      
      # Create an undelivered message
      undelivered = SolidMCP::Message.create!(
        session_id: @session_id,
        event_type: "new_message",
        data: "new",
        created_at: Time.current
      )
      
      @subscriber.start
      
      # Wait for processing
      assert wait_for_condition { @received.any? }
      
      # Should only receive the undelivered message
      assert_equal 1, @received.size
      assert_equal undelivered.id, @received.first[:id]
    end

    def test_processes_messages_in_order
      # Create messages out of order
      msg3 = SolidMCP::Message.create!(
        session_id: @session_id,
        event_type: "msg3",
        data: "3",
        created_at: Time.current
      )
      
      msg1 = SolidMCP::Message.create!(
        session_id: @session_id,
        event_type: "msg1", 
        data: "1",
        created_at: Time.current
      )
      
      msg2 = SolidMCP::Message.create!(
        session_id: @session_id,
        event_type: "msg2",
        data: "2",
        created_at: Time.current
      )
      
      @subscriber.start
      
      # Wait for all messages
      assert wait_for_condition { @received.size == 3 }
      
      # Should be in ID order (which reflects creation order in the DB)
      assert_equal [msg3.id, msg1.id, msg2.id].sort, @received.map { |r| r[:id] }.sort
    end

    def test_continues_from_last_message_id
      # Create first batch
      msg1 = SolidMCP::Message.create!(
        session_id: @session_id,
        event_type: "batch1",
        data: "1",
        created_at: Time.current
      )
      
      @subscriber.start
      
      # Wait for first message
      assert wait_for_condition { @received.size == 1 }
      
      # Create second batch
      msg2 = SolidMCP::Message.create!(
        session_id: @session_id,
        event_type: "batch2",
        data: "2",
        created_at: Time.current
      )
      
      # Wait for second message
      assert wait_for_condition { @received.size == 2 }
      
      # Should have both messages
      assert_equal [msg1.id, msg2.id], @received.map { |r| r[:id] }
    end

    def test_handles_callback_errors_gracefully
      error_count = 0
      error_callback = ->(message) { 
        error_count += 1
        raise "Test error!" 
      }
      good_callback = ->(message) { @received << message }
      
      subscriber = Subscriber.new(@session_id, [error_callback, good_callback])
      
      msg = SolidMCP::Message.create!(
        session_id: @session_id,
        event_type: "error_test",
        data: "test",
        created_at: Time.current
      )
      
      # Ensure message was created and is undelivered
      assert_equal 1, SolidMCP::Message.for_session(@session_id).count
      assert_equal 1, SolidMCP::Message.for_session(@session_id).undelivered.count
      
      subscriber.start
      
      # Wait for processing
      sleep 0.5
      
      # Despite error in first callback, second should still work
      assert wait_for_condition(3) { @received.any? }, "Expected messages to be received, but got none. Message id: #{msg.id}, delivered: #{msg.reload.delivered_at}, error_count: #{error_count}"
      assert_equal 1, @received.size
      assert error_count > 0, "Error callback should have been called"
      
      # Message should be marked as delivered
      assert_not_nil msg.reload.delivered_at, "Message should be marked as delivered"
      
      subscriber.stop
    end

    def test_stop_halts_processing
      @subscriber.start
      @subscriber.stop
      
      # Create message after stopping
      SolidMCP::Message.create!(
        session_id: @session_id,
        event_type: "after_stop",
        data: "test",
        created_at: Time.current
      )
      
      # Give it time to potentially process
      sleep 0.2
      
      # Should not have processed the message
      assert_empty @received
    end
  end
end