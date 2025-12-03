//! Async message writer with batching
//!
//! Uses Tokio channels for non-blocking enqueue and background batch writes.

use crate::db::{Database, DbPool};
use crate::{Config, Error, Message, Result};
use std::sync::Arc;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::{debug, error, info, warn};

/// Message writer that batches writes to the database
pub struct MessageWriter {
    tx: mpsc::Sender<WriterCommand>,
    handle: JoinHandle<()>,
}

enum WriterCommand {
    Message(Message),
    Flush(tokio::sync::oneshot::Sender<()>),
    Shutdown,
}

impl MessageWriter {
    /// Create a new message writer
    pub async fn new(db: Arc<DbPool>, config: &Config) -> Result<Self> {
        let (tx, rx) = mpsc::channel(config.max_queue_size);
        let batch_size = config.batch_size;
        let _shutdown_timeout = config.shutdown_timeout; // TODO: Use for timeout handling

        let handle = tokio::spawn(async move {
            writer_loop(rx, db, batch_size).await;
            debug!("MessageWriter worker shutdown complete");
        });

        info!(
            "MessageWriter started with batch_size={}, queue_size={}",
            batch_size, config.max_queue_size
        );

        Ok(Self { tx, handle })
    }

    /// Enqueue a message for writing (non-blocking)
    ///
    /// Returns `Ok(true)` if enqueued, `Ok(false)` if queue is full.
    pub fn enqueue(&self, message: Message) -> Result<bool> {
        match self.tx.try_send(WriterCommand::Message(message)) {
            Ok(()) => Ok(true),
            Err(mpsc::error::TrySendError::Full(_)) => {
                warn!("MessageWriter queue full, dropping message");
                Ok(false)
            }
            Err(mpsc::error::TrySendError::Closed(_)) => Err(Error::Shutdown),
        }
    }

    /// Enqueue a message for writing (async, waits if queue is full)
    pub async fn enqueue_async(&self, message: Message) -> Result<()> {
        self.tx
            .send(WriterCommand::Message(message))
            .await
            .map_err(|_| Error::Shutdown)
    }

    /// Flush all pending messages to the database
    pub async fn flush(&self) -> Result<()> {
        let (tx, rx) = tokio::sync::oneshot::channel();
        self.tx
            .send(WriterCommand::Flush(tx))
            .await
            .map_err(|_| Error::Shutdown)?;
        rx.await.map_err(|_| Error::Shutdown)
    }

    /// Shutdown the writer gracefully
    pub async fn shutdown(self) -> Result<()> {
        info!("MessageWriter shutting down...");

        // Send shutdown command
        let _ = self.tx.send(WriterCommand::Shutdown).await;

        // Wait for worker to finish
        self.handle
            .await
            .map_err(|e| Error::Config(format!("Worker panicked: {}", e)))?;

        info!("MessageWriter shutdown complete");
        Ok(())
    }
}

async fn writer_loop(mut rx: mpsc::Receiver<WriterCommand>, db: Arc<DbPool>, batch_size: usize) {
    let mut batch = Vec::with_capacity(batch_size);
    let mut flush_waiters: Vec<tokio::sync::oneshot::Sender<()>> = Vec::new();

    loop {
        // Wait for first message or command
        let cmd = match rx.recv().await {
            Some(cmd) => cmd,
            None => {
                debug!("Channel closed, exiting writer loop");
                break;
            }
        };

        match cmd {
            WriterCommand::Message(msg) => {
                batch.push(msg);
            }
            WriterCommand::Flush(waiter) => {
                flush_waiters.push(waiter);
            }
            WriterCommand::Shutdown => {
                debug!("Shutdown command received");
                // Drain remaining messages
                drain_remaining(&mut rx, &mut batch, &mut flush_waiters);
                // Write final batch
                if !batch.is_empty() {
                    write_batch(&db, &mut batch).await;
                }
                // Signal all flush waiters
                signal_flush_waiters(&mut flush_waiters);
                break;
            }
        }

        // Try to fill batch (non-blocking)
        while batch.len() < batch_size {
            match rx.try_recv() {
                Ok(WriterCommand::Message(msg)) => {
                    batch.push(msg);
                }
                Ok(WriterCommand::Flush(waiter)) => {
                    flush_waiters.push(waiter);
                    break; // Stop filling, write now
                }
                Ok(WriterCommand::Shutdown) => {
                    drain_remaining(&mut rx, &mut batch, &mut flush_waiters);
                    if !batch.is_empty() {
                        write_batch(&db, &mut batch).await;
                    }
                    signal_flush_waiters(&mut flush_waiters);
                    return;
                }
                Err(_) => break, // No more messages available
            }
        }

        // Write batch if non-empty
        if !batch.is_empty() {
            write_batch(&db, &mut batch).await;
        }

        // Signal flush waiters
        signal_flush_waiters(&mut flush_waiters);
    }
}

fn drain_remaining(
    rx: &mut mpsc::Receiver<WriterCommand>,
    batch: &mut Vec<Message>,
    flush_waiters: &mut Vec<tokio::sync::oneshot::Sender<()>>,
) {
    while let Ok(cmd) = rx.try_recv() {
        match cmd {
            WriterCommand::Message(msg) => batch.push(msg),
            WriterCommand::Flush(waiter) => flush_waiters.push(waiter),
            WriterCommand::Shutdown => {}
        }
    }
}

async fn write_batch(db: &DbPool, batch: &mut Vec<Message>) {
    let count = batch.len();
    debug!("Writing batch of {} messages", count);

    match db.insert_batch(batch).await {
        Ok(()) => {
            debug!("Successfully wrote {} messages", count);
        }
        Err(e) => {
            error!("Failed to write batch: {}", e);
            // TODO: Implement retry logic or dead letter queue
        }
    }

    batch.clear();
}

fn signal_flush_waiters(waiters: &mut Vec<tokio::sync::oneshot::Sender<()>>) {
    for waiter in waiters.drain(..) {
        let _ = waiter.send(());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::sqlite::SqlitePool;

    #[tokio::test]
    async fn test_writer_basic() {
        let sqlite = SqlitePool::new("sqlite::memory:").await.unwrap();
        let db = Arc::new(DbPool::Sqlite(sqlite));
        let config = Config::new("sqlite::memory:").batch_size(10);

        let writer = MessageWriter::new(db.clone(), &config).await.unwrap();

        // Enqueue some messages
        for i in 0..5 {
            let msg = Message::new("session-1", "message", format!(r#"{{"i":{}}}"#, i));
            assert!(writer.enqueue(msg).unwrap());
        }

        // Flush to ensure writes complete
        writer.flush().await.unwrap();

        // Verify messages in database
        let messages = db.fetch_after("session-1", 0, 100).await.unwrap();
        assert_eq!(messages.len(), 5);

        // Shutdown
        writer.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn test_writer_batching() {
        let sqlite = SqlitePool::new("sqlite::memory:").await.unwrap();
        let db = Arc::new(DbPool::Sqlite(sqlite));
        let config = Config::new("sqlite::memory:").batch_size(3);

        let writer = MessageWriter::new(db.clone(), &config).await.unwrap();

        // Enqueue more messages than batch size
        for i in 0..10 {
            let msg = Message::new("session-1", "message", format!(r#"{{"i":{}}}"#, i));
            writer.enqueue_async(msg).await.unwrap();
        }

        writer.flush().await.unwrap();

        let messages = db.fetch_after("session-1", 0, 100).await.unwrap();
        assert_eq!(messages.len(), 10);

        writer.shutdown().await.unwrap();
    }
}
