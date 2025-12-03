//! Database abstraction layer for solid-mcp-core
//!
//! Supports both SQLite and PostgreSQL backends.

#[cfg(feature = "postgres")]
pub mod postgres;
#[cfg(feature = "sqlite")]
pub mod sqlite;

use crate::{Config, Message, Result};
use async_trait::async_trait;
use std::time::Duration;

/// Database backend trait
#[async_trait]
pub trait Database: Send + Sync + 'static {
    /// Insert a batch of messages
    async fn insert_batch(&self, messages: &[Message]) -> Result<()>;

    /// Fetch undelivered messages for a session after the given ID
    async fn fetch_after(&self, session_id: &str, after_id: i64, limit: i64) -> Result<Vec<Message>>;

    /// Mark messages as delivered
    async fn mark_delivered(&self, ids: &[i64]) -> Result<()>;

    /// Delete old delivered messages
    async fn cleanup_delivered(&self, older_than: Duration) -> Result<u64>;

    /// Delete old undelivered messages
    async fn cleanup_undelivered(&self, older_than: Duration) -> Result<u64>;

    /// Get the maximum message ID (for initialization)
    async fn max_id(&self) -> Result<i64>;
}

/// Database pool type (enum dispatch for runtime selection)
pub enum DbPool {
    #[cfg(feature = "sqlite")]
    Sqlite(sqlite::SqlitePool),
    #[cfg(feature = "postgres")]
    Postgres(postgres::PostgresPool),
}

impl DbPool {
    /// Create a new database pool from config
    pub async fn new(config: &Config) -> Result<Self> {
        #[cfg(feature = "postgres")]
        if config.is_postgres() {
            return Ok(Self::Postgres(postgres::PostgresPool::new(&config.database_url).await?));
        }

        #[cfg(feature = "sqlite")]
        if config.is_sqlite() {
            return Ok(Self::Sqlite(sqlite::SqlitePool::new(&config.database_url).await?));
        }

        Err(crate::Error::Config(format!(
            "Unsupported database URL: {}",
            config.database_url
        )))
    }

    /// Check if this is a PostgreSQL pool (supports LISTEN/NOTIFY)
    pub fn is_postgres(&self) -> bool {
        matches!(self, Self::Postgres(_))
    }
}

#[async_trait]
impl Database for DbPool {
    async fn insert_batch(&self, messages: &[Message]) -> Result<()> {
        match self {
            #[cfg(feature = "sqlite")]
            Self::Sqlite(pool) => pool.insert_batch(messages).await,
            #[cfg(feature = "postgres")]
            Self::Postgres(pool) => pool.insert_batch(messages).await,
        }
    }

    async fn fetch_after(&self, session_id: &str, after_id: i64, limit: i64) -> Result<Vec<Message>> {
        match self {
            #[cfg(feature = "sqlite")]
            Self::Sqlite(pool) => pool.fetch_after(session_id, after_id, limit).await,
            #[cfg(feature = "postgres")]
            Self::Postgres(pool) => pool.fetch_after(session_id, after_id, limit).await,
        }
    }

    async fn mark_delivered(&self, ids: &[i64]) -> Result<()> {
        match self {
            #[cfg(feature = "sqlite")]
            Self::Sqlite(pool) => pool.mark_delivered(ids).await,
            #[cfg(feature = "postgres")]
            Self::Postgres(pool) => pool.mark_delivered(ids).await,
        }
    }

    async fn cleanup_delivered(&self, older_than: Duration) -> Result<u64> {
        match self {
            #[cfg(feature = "sqlite")]
            Self::Sqlite(pool) => pool.cleanup_delivered(older_than).await,
            #[cfg(feature = "postgres")]
            Self::Postgres(pool) => pool.cleanup_delivered(older_than).await,
        }
    }

    async fn cleanup_undelivered(&self, older_than: Duration) -> Result<u64> {
        match self {
            #[cfg(feature = "sqlite")]
            Self::Sqlite(pool) => pool.cleanup_undelivered(older_than).await,
            #[cfg(feature = "postgres")]
            Self::Postgres(pool) => pool.cleanup_undelivered(older_than).await,
        }
    }

    async fn max_id(&self) -> Result<i64> {
        match self {
            #[cfg(feature = "sqlite")]
            Self::Sqlite(pool) => pool.max_id().await,
            #[cfg(feature = "postgres")]
            Self::Postgres(pool) => pool.max_id().await,
        }
    }
}
