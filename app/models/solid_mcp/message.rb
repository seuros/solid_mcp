# frozen_string_literal: true

module SolidMCP
  class Message < Record
    self.table_name = "solid_mcp_messages"

    scope :for_session, ->(session_id) { where(session_id: session_id) }
    scope :undelivered, -> { where(delivered_at: nil) }
    scope :delivered, -> { where.not(delivered_at: nil) }
    scope :after_id, ->(id) { where("id > ?", id) }
    scope :old_delivered, ->(age) { delivered.where("delivered_at < ?", age.ago) }
    scope :old_undelivered, ->(age) { undelivered.where("created_at < ?", age.ago) }

    # Mark messages as delivered
    def self.mark_delivered(ids)
      where(id: ids).update_all(delivered_at: Time.now.utc)
    end

    # Cleanup old messages with transaction safety
    def self.cleanup(delivered_retention: 1.hour, undelivered_retention: 24.hours)
      transaction do
        old_delivered(delivered_retention).delete_all
        old_undelivered(undelivered_retention).delete_all
      end
    end
  end
end