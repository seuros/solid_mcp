//! Async subscriber for session-based message delivery
//!
//! Supports two modes:
//! - PostgreSQL: Uses LISTEN/NOTIFY for real-time delivery (no polling)
//! - SQLite: Falls back to efficient async polling

#[cfg(feature = "postgres")]
use crate::db::postgres::PostgresPool;
use crate::db::{Database, DbPool};
use crate::{Config, Message, Result};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::time::Duration;
use tokio::task::JoinHandle;
use tracing::{debug, error, info, warn};

/// Callback type for message delivery
pub type MessageCallback = Box<dyn Fn(Message) + Send + Sync + 'static>;

/// A subscriber for a specific session
pub struct Subscriber {
    session_id: String,
    handle: JoinHandle<()>,
    shutdown: Arc<AtomicBool>,
}

impl Subscriber {
    /// Create a new subscriber for a session
    ///
    /// The callback will be invoked for each new message.
    pub async fn new(
        session_id: impl Into<String>,
        db: Arc<DbPool>,
        config: &Config,
        callback: MessageCallback,
    ) -> Result<Self> {
        let session_id = session_id.into();
        let shutdown = Arc::new(AtomicBool::new(false));
        let shutdown_clone = shutdown.clone();
        let session_clone = session_id.clone();
        let polling_interval = config.polling_interval;

        // Get initial last_id
        let last_id = Arc::new(AtomicI64::new(db.max_id().await?));

        let handle = match &*db {
            #[cfg(feature = "postgres")]
            DbPool::Postgres(pg) => {
                // Use LISTEN/NOTIFY for PostgreSQL
                let pg_clone = pg.clone();
                let db_clone = db.clone();
                tokio::spawn(async move {
                    postgres_subscriber_loop(
                        session_clone,
                        pg_clone,
                        db_clone,
                        last_id,
                        shutdown_clone,
                        callback,
                    )
                    .await
                })
            }
            #[cfg(feature = "sqlite")]
            DbPool::Sqlite(_) => {
                // Use polling for SQLite
                tokio::spawn(async move {
                    polling_subscriber_loop(
                        session_clone,
                        db,
                        last_id,
                        polling_interval,
                        shutdown_clone,
                        callback,
                    )
                    .await
                })
            }
        };

        info!("Subscriber started for session {}", session_id);

        Ok(Self {
            session_id,
            handle,
            shutdown,
        })
    }

    /// Stop the subscriber
    pub async fn stop(self) -> Result<()> {
        info!("Stopping subscriber for session {}", self.session_id);
        self.shutdown.store(true, Ordering::SeqCst);

        // Wait for the task to complete (with timeout)
        tokio::select! {
            _ = self.handle => {
                debug!("Subscriber task completed");
            }
            _ = tokio::time::sleep(Duration::from_secs(5)) => {
                warn!("Subscriber task did not complete in time, aborting");
            }
        }

        Ok(())
    }

    /// Get the session ID
    pub fn session_id(&self) -> &str {
        &self.session_id
    }
}

/// Polling-based subscriber loop (for SQLite)
async fn polling_subscriber_loop(
    session_id: String,
    db: Arc<DbPool>,
    last_id: Arc<AtomicI64>,
    polling_interval: Duration,
    shutdown: Arc<AtomicBool>,
    callback: MessageCallback,
) {
    debug!(
        "Starting polling subscriber for session {} (interval: {:?})",
        session_id, polling_interval
    );

    while !shutdown.load(Ordering::SeqCst) {
        // Fetch new messages
        let current_last_id = last_id.load(Ordering::SeqCst);
        match db.fetch_after(&session_id, current_last_id, 100).await {
            Ok(messages) => {
                for msg in messages {
                    let msg_id = msg.id;

                    // Deliver to callback
                    callback(msg);

                    // Update last_id
                    last_id.store(msg_id, Ordering::SeqCst);
                }
            }
            Err(e) => {
                error!("Error fetching messages for session {}: {}", session_id, e);
            }
        }

        // Sleep until next poll (interruptible)
        tokio::select! {
            _ = tokio::time::sleep(polling_interval) => {}
            _ = async {
                while !shutdown.load(Ordering::SeqCst) {
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
            } => {
                break;
            }
        }
    }

    debug!("Polling subscriber for session {} stopped", session_id);
}

/// LISTEN/NOTIFY-based subscriber loop (for PostgreSQL)
#[cfg(feature = "postgres")]
async fn postgres_subscriber_loop(
    session_id: String,
    pg: PostgresPool,
    db: Arc<DbPool>,
    last_id: Arc<AtomicI64>,
    shutdown: Arc<AtomicBool>,
    callback: MessageCallback,
) {
    debug!(
        "Starting LISTEN/NOTIFY subscriber for session {}",
        session_id
    );

    // First, catch up on any missed messages
    let current_last_id = last_id.load(Ordering::SeqCst);
    match db.fetch_after(&session_id, current_last_id, 1000).await {
        Ok(messages) => {
            for msg in messages {
                let msg_id = msg.id;
                callback(msg);
                last_id.store(msg_id, Ordering::SeqCst);
            }
        }
        Err(e) => {
            error!(
                "Error catching up messages for session {}: {}",
                session_id, e
            );
        }
    }

    // Set up LISTEN
    let mut listener = match pg.listen(&session_id).await {
        Ok(l) => l,
        Err(e) => {
            error!(
                "Failed to create listener for session {}: {}",
                session_id, e
            );
            return;
        }
    };

    // Listen for notifications
    while !shutdown.load(Ordering::SeqCst) {
        tokio::select! {
            notification = listener.recv() => {
                match notification {
                    Ok(notif) => {
                        // Notification payload is the message ID
                        if let Ok(msg_id) = notif.payload().parse::<i64>() {
                            // Fetch the specific message
                            let current = last_id.load(Ordering::SeqCst);
                            if msg_id > current {
                                match db.fetch_after(&session_id, current, 100).await {
                                    Ok(messages) => {
                                        for msg in messages {
                                            let id = msg.id;
                                            callback(msg);
                                            last_id.store(id, Ordering::SeqCst);
                                        }
                                    }
                                    Err(e) => {
                                        error!("Error fetching message {}: {}", msg_id, e);
                                    }
                                }
                            }
                        }
                    }
                    Err(e) => {
                        error!("Listener error for session {}: {}", session_id, e);
                        // Reconnect logic could go here
                        break;
                    }
                }
            }
            _ = tokio::time::sleep(Duration::from_secs(1)) => {
                // Periodic check for shutdown
                if shutdown.load(Ordering::SeqCst) {
                    break;
                }
            }
        }
    }

    debug!(
        "LISTEN/NOTIFY subscriber for session {} stopped",
        session_id
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::sqlite::SqlitePool;
    use std::sync::atomic::AtomicUsize;

    #[tokio::test]
    async fn test_polling_subscriber() {
        let sqlite = SqlitePool::new("sqlite::memory:").await.unwrap();
        let db = Arc::new(DbPool::Sqlite(sqlite));
        let config = Config::new("sqlite::memory:").polling_interval(Duration::from_millis(10));

        let received = Arc::new(AtomicUsize::new(0));
        let received_clone = received.clone();

        let callback: MessageCallback = Box::new(move |_msg| {
            received_clone.fetch_add(1, Ordering::SeqCst);
        });

        let subscriber = Subscriber::new("session-1", db.clone(), &config, callback)
            .await
            .unwrap();

        // Insert some messages
        let messages: Vec<Message> = (0..5)
            .map(|i| Message::new("session-1", "message", format!(r#"{{"i":{}}}"#, i)))
            .collect();
        db.insert_batch(&messages).await.unwrap();

        // Wait for subscriber to pick them up
        tokio::time::sleep(Duration::from_millis(100)).await;

        assert_eq!(received.load(Ordering::SeqCst), 5);

        subscriber.stop().await.unwrap();
    }
}
