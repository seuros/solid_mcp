//! High-level pub/sub API
//!
//! This is the main interface for solid-mcp-core, providing:
//! - Session-based subscriptions
//! - Non-blocking message broadcasting
//! - Graceful shutdown

use crate::db::{Database, DbPool};
use crate::subscriber::{MessageCallback, Subscriber};
use crate::writer::MessageWriter;
use crate::{Config, Error, Message, Result};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::{debug, info};

/// The main pub/sub engine
pub struct PubSub {
    db: Arc<DbPool>,
    config: Config,
    writer: Arc<MessageWriter>,
    subscribers: RwLock<HashMap<String, Subscriber>>,
}

impl PubSub {
    /// Create a new pub/sub engine
    pub async fn new(config: Config) -> Result<Self> {
        let db = Arc::new(DbPool::new(&config).await?);
        let writer = Arc::new(MessageWriter::new(db.clone(), &config).await?);

        info!("PubSub engine initialized");

        Ok(Self {
            db,
            config,
            writer,
            subscribers: RwLock::new(HashMap::new()),
        })
    }

    /// Create a new pub/sub engine with an existing database pool
    pub async fn with_db(db: Arc<DbPool>, config: Config) -> Result<Self> {
        let writer = Arc::new(MessageWriter::new(db.clone(), &config).await?);

        Ok(Self {
            db,
            config,
            writer,
            subscribers: RwLock::new(HashMap::new()),
        })
    }

    /// Broadcast a message to a session (non-blocking)
    ///
    /// Returns `true` if the message was enqueued, `false` if the queue was full.
    pub fn broadcast(
        &self,
        session_id: impl Into<String>,
        event_type: impl Into<String>,
        data: impl Into<String>,
    ) -> Result<bool> {
        let message = Message::new(session_id, event_type, data);
        self.writer.enqueue(message)
    }

    /// Broadcast a message to a session (async, waits if queue is full)
    pub async fn broadcast_async(
        &self,
        session_id: impl Into<String>,
        event_type: impl Into<String>,
        data: impl Into<String>,
    ) -> Result<()> {
        let message = Message::new(session_id, event_type, data);
        self.writer.enqueue_async(message).await
    }

    /// Subscribe to messages for a session
    ///
    /// The callback will be invoked for each new message.
    /// Returns an error if already subscribed to this session.
    pub async fn subscribe(
        &self,
        session_id: impl Into<String>,
        callback: MessageCallback,
    ) -> Result<()> {
        let session_id = session_id.into();

        let mut subscribers = self.subscribers.write().await;

        if subscribers.contains_key(&session_id) {
            return Err(Error::Config(format!(
                "Already subscribed to session {}",
                session_id
            )));
        }

        let subscriber =
            Subscriber::new(&session_id, self.db.clone(), &self.config, callback).await?;
        subscribers.insert(session_id, subscriber);

        Ok(())
    }

    /// Unsubscribe from a session
    pub async fn unsubscribe(&self, session_id: &str) -> Result<()> {
        let mut subscribers = self.subscribers.write().await;

        if let Some(subscriber) = subscribers.remove(session_id) {
            subscriber.stop().await?;
        }

        Ok(())
    }

    /// Check if subscribed to a session
    pub async fn is_subscribed(&self, session_id: &str) -> bool {
        let subscribers = self.subscribers.read().await;
        subscribers.contains_key(session_id)
    }

    /// Get the number of active subscriptions
    pub async fn subscription_count(&self) -> usize {
        let subscribers = self.subscribers.read().await;
        subscribers.len()
    }

    /// Flush all pending messages to the database
    pub async fn flush(&self) -> Result<()> {
        self.writer.flush().await
    }

    /// Mark messages as delivered
    pub async fn mark_delivered(&self, ids: &[i64]) -> Result<()> {
        self.db.mark_delivered(ids).await
    }

    /// Cleanup old messages
    pub async fn cleanup(&self) -> Result<(u64, u64)> {
        let delivered = self
            .db
            .cleanup_delivered(self.config.delivered_retention)
            .await?;
        let undelivered = self
            .db
            .cleanup_undelivered(self.config.undelivered_retention)
            .await?;
        debug!(
            "Cleanup complete: {} delivered, {} undelivered messages removed",
            delivered, undelivered
        );
        Ok((delivered, undelivered))
    }

    /// Shutdown the pub/sub engine gracefully
    pub async fn shutdown(self) -> Result<()> {
        info!("PubSub engine shutting down...");

        // Stop all subscribers
        let mut subscribers = self.subscribers.write().await;
        for (session_id, subscriber) in subscribers.drain() {
            debug!("Stopping subscriber for session {}", session_id);
            if let Err(e) = subscriber.stop().await {
                tracing::error!("Error stopping subscriber for {}: {}", session_id, e);
            }
        }
        drop(subscribers);

        // Shutdown writer (flushes remaining messages)
        // Need to unwrap the Arc - this only works if we're the last holder
        match Arc::try_unwrap(self.writer) {
            Ok(writer) => writer.shutdown().await?,
            Err(_) => {
                tracing::warn!("Could not unwrap writer Arc, forcing flush");
                // Best effort - can't fully shutdown
            }
        }

        info!("PubSub engine shutdown complete");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    #[tokio::test]
    async fn test_pubsub_basic() {
        let config = Config::new("sqlite::memory:")
            .batch_size(10)
            .polling_interval(Duration::from_millis(10));

        let pubsub = PubSub::new(config).await.unwrap();

        let received = Arc::new(AtomicUsize::new(0));
        let received_clone = received.clone();

        pubsub
            .subscribe(
                "session-1",
                Box::new(move |_| {
                    received_clone.fetch_add(1, Ordering::SeqCst);
                }),
            )
            .await
            .unwrap();

        // Broadcast messages
        for i in 0..5 {
            pubsub
                .broadcast("session-1", "message", format!(r#"{{"i":{}}}"#, i))
                .unwrap();
        }

        // Flush and wait for delivery
        pubsub.flush().await.unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;

        assert_eq!(received.load(Ordering::SeqCst), 5);

        pubsub.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn test_pubsub_multiple_sessions() {
        let config = Config::new("sqlite::memory:").polling_interval(Duration::from_millis(10));

        let pubsub = PubSub::new(config).await.unwrap();

        let received1 = Arc::new(AtomicUsize::new(0));
        let received2 = Arc::new(AtomicUsize::new(0));

        let r1 = received1.clone();
        let r2 = received2.clone();

        pubsub
            .subscribe(
                "session-1",
                Box::new(move |_| {
                    r1.fetch_add(1, Ordering::SeqCst);
                }),
            )
            .await
            .unwrap();

        pubsub
            .subscribe(
                "session-2",
                Box::new(move |_| {
                    r2.fetch_add(1, Ordering::SeqCst);
                }),
            )
            .await
            .unwrap();

        // Broadcast to different sessions
        pubsub.broadcast("session-1", "msg", "{}").unwrap();
        pubsub.broadcast("session-1", "msg", "{}").unwrap();
        pubsub.broadcast("session-2", "msg", "{}").unwrap();

        pubsub.flush().await.unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;

        assert_eq!(received1.load(Ordering::SeqCst), 2);
        assert_eq!(received2.load(Ordering::SeqCst), 1);

        pubsub.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn test_pubsub_unsubscribe() {
        let config = Config::new("sqlite::memory:").polling_interval(Duration::from_millis(10));

        let pubsub = PubSub::new(config).await.unwrap();

        let received = Arc::new(AtomicUsize::new(0));
        let r = received.clone();

        pubsub
            .subscribe(
                "session-1",
                Box::new(move |_| {
                    r.fetch_add(1, Ordering::SeqCst);
                }),
            )
            .await
            .unwrap();

        assert!(pubsub.is_subscribed("session-1").await);
        assert_eq!(pubsub.subscription_count().await, 1);

        pubsub.unsubscribe("session-1").await.unwrap();

        assert!(!pubsub.is_subscribed("session-1").await);
        assert_eq!(pubsub.subscription_count().await, 0);

        pubsub.shutdown().await.unwrap();
    }
}
