//! Message type for solid-mcp-core

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// A message in the pub/sub system
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    /// Unique message ID (database primary key)
    #[serde(default)]
    pub id: i64,

    /// Session ID this message belongs to (UUID format, 36 chars)
    pub session_id: String,

    /// Event type (e.g., "message", "ping", "notification")
    pub event_type: String,

    /// JSON payload
    pub data: String,

    /// When the message was created
    pub created_at: DateTime<Utc>,

    /// When the message was delivered (None = undelivered)
    #[serde(default)]
    pub delivered_at: Option<DateTime<Utc>>,
}

impl Message {
    /// Create a new message (id will be set by database)
    pub fn new(
        session_id: impl Into<String>,
        event_type: impl Into<String>,
        data: impl Into<String>,
    ) -> Self {
        Self {
            id: 0,
            session_id: session_id.into(),
            event_type: event_type.into(),
            data: data.into(),
            created_at: Utc::now(),
            delivered_at: None,
        }
    }

    /// Create a message with JSON data
    pub fn with_json<T: Serialize>(
        session_id: impl Into<String>,
        event_type: impl Into<String>,
        data: &T,
    ) -> Result<Self, serde_json::Error> {
        let json = serde_json::to_string(data)?;
        Ok(Self::new(session_id, event_type, json))
    }

    /// Check if this message has been delivered
    pub fn is_delivered(&self) -> bool {
        self.delivered_at.is_some()
    }

    /// Mark this message as delivered now
    pub fn mark_delivered(&mut self) {
        self.delivered_at = Some(Utc::now());
    }
}

/// Batch of messages for efficient database operations
#[derive(Debug, Default)]
pub struct MessageBatch {
    messages: Vec<Message>,
}

impl MessageBatch {
    /// Create a new empty batch
    pub fn new() -> Self {
        Self::default()
    }

    /// Create a batch with pre-allocated capacity
    pub fn with_capacity(capacity: usize) -> Self {
        Self {
            messages: Vec::with_capacity(capacity),
        }
    }

    /// Add a message to the batch
    pub fn push(&mut self, message: Message) {
        self.messages.push(message);
    }

    /// Get the number of messages in the batch
    pub fn len(&self) -> usize {
        self.messages.len()
    }

    /// Check if the batch is empty
    pub fn is_empty(&self) -> bool {
        self.messages.is_empty()
    }

    /// Clear the batch
    pub fn clear(&mut self) {
        self.messages.clear();
    }

    /// Get the messages as a slice
    pub fn as_slice(&self) -> &[Message] {
        &self.messages
    }

    /// Take ownership of the messages
    pub fn into_vec(self) -> Vec<Message> {
        self.messages
    }

    /// Iterate over messages
    pub fn iter(&self) -> impl Iterator<Item = &Message> {
        self.messages.iter()
    }
}

impl IntoIterator for MessageBatch {
    type Item = Message;
    type IntoIter = std::vec::IntoIter<Message>;

    fn into_iter(self) -> Self::IntoIter {
        self.messages.into_iter()
    }
}

impl FromIterator<Message> for MessageBatch {
    fn from_iter<T: IntoIterator<Item = Message>>(iter: T) -> Self {
        Self {
            messages: iter.into_iter().collect(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_message_new() {
        let msg = Message::new("session-123", "message", r#"{"hello":"world"}"#);
        assert_eq!(msg.session_id, "session-123");
        assert_eq!(msg.event_type, "message");
        assert_eq!(msg.data, r#"{"hello":"world"}"#);
        assert!(!msg.is_delivered());
    }

    #[test]
    fn test_message_with_json() {
        #[derive(Serialize)]
        struct Payload {
            hello: String,
        }

        let payload = Payload {
            hello: "world".to_string(),
        };
        let msg = Message::with_json("session-123", "message", &payload).unwrap();
        assert_eq!(msg.data, r#"{"hello":"world"}"#);
    }

    #[test]
    fn test_mark_delivered() {
        let mut msg = Message::new("session-123", "message", "{}");
        assert!(!msg.is_delivered());

        msg.mark_delivered();
        assert!(msg.is_delivered());
        assert!(msg.delivered_at.is_some());
    }

    #[test]
    fn test_message_batch() {
        let mut batch = MessageBatch::with_capacity(10);
        assert!(batch.is_empty());

        batch.push(Message::new("s1", "msg", "{}"));
        batch.push(Message::new("s2", "msg", "{}"));

        assert_eq!(batch.len(), 2);
        assert!(!batch.is_empty());

        let messages: Vec<_> = batch.into_iter().collect();
        assert_eq!(messages.len(), 2);
    }
}
