//! SQLite database backend for solid-mcp-core

use crate::{Message, Result};
use async_trait::async_trait;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::{Pool, Sqlite};
use std::str::FromStr;
use std::time::Duration;

/// SQLite connection pool
#[derive(Clone)]
pub struct SqlitePool {
    pool: Pool<Sqlite>,
}

impl SqlitePool {
    /// Create a new SQLite pool from a database URL
    ///
    /// The database and tables must already exist (created by Ruby migrations).
    pub async fn new(database_url: &str) -> Result<Self> {
        // Parse the URL and configure for WAL mode (better concurrency)
        let options = SqliteConnectOptions::from_str(database_url)?
            .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal)
            .synchronous(sqlx::sqlite::SqliteSynchronous::Normal)
            .busy_timeout(Duration::from_secs(30));

        let pool = SqlitePoolOptions::new()
            .max_connections(1) // SQLite works best with single writer
            .connect_with(options)
            .await?;

        Ok(Self { pool })
    }

    /// Create tables for testing purposes only
    #[cfg(test)]
    pub(crate) async fn setup_test_schema(&self) -> Result<()> {
        sqlx::query(
            r#"
            CREATE TABLE IF NOT EXISTS solid_mcp_messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                event_type TEXT NOT NULL,
                data TEXT NOT NULL,
                created_at TEXT NOT NULL,
                delivered_at TEXT
            )
            "#,
        )
        .execute(&self.pool)
        .await?;

        sqlx::query(
            r#"
            CREATE INDEX IF NOT EXISTS idx_solid_mcp_messages_session_id
            ON solid_mcp_messages(session_id, id)
            "#,
        )
        .execute(&self.pool)
        .await?;

        sqlx::query(
            r#"
            CREATE INDEX IF NOT EXISTS idx_solid_mcp_messages_delivered
            ON solid_mcp_messages(delivered_at, created_at)
            "#,
        )
        .execute(&self.pool)
        .await?;

        Ok(())
    }
}

#[async_trait]
impl super::Database for SqlitePool {
    async fn insert_batch(&self, messages: &[Message]) -> Result<()> {
        if messages.is_empty() {
            return Ok(());
        }

        // Build batch insert query
        let mut query = String::from(
            "INSERT INTO solid_mcp_messages (session_id, event_type, data, created_at) VALUES ",
        );

        let mut params: Vec<String> = Vec::with_capacity(messages.len() * 4);

        for (i, msg) in messages.iter().enumerate() {
            if i > 0 {
                query.push_str(", ");
            }
            let base = i * 4 + 1;
            query.push_str(&format!(
                "(${}, ${}, ${}, ${})",
                base,
                base + 1,
                base + 2,
                base + 3
            ));
            params.push(msg.session_id.clone());
            params.push(msg.event_type.clone());
            params.push(msg.data.clone());
            params.push(msg.created_at.to_rfc3339());
        }

        // Execute with parameters
        let mut q = sqlx::query(&query);
        for param in &params {
            q = q.bind(param);
        }
        q.execute(&self.pool).await?;

        Ok(())
    }

    async fn fetch_after(
        &self,
        session_id: &str,
        after_id: i64,
        limit: i64,
    ) -> Result<Vec<Message>> {
        let rows = sqlx::query_as::<_, (i64, String, String, String, String, Option<String>)>(
            r#"
            SELECT id, session_id, event_type, data, created_at, delivered_at
            FROM solid_mcp_messages
            WHERE session_id = $1 AND delivered_at IS NULL AND id > $2
            ORDER BY id
            LIMIT $3
            "#,
        )
        .bind(session_id)
        .bind(after_id)
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;

        let messages = rows
            .into_iter()
            .map(
                |(id, session_id, event_type, data, created_at, delivered_at)| Message {
                    id,
                    session_id,
                    event_type,
                    data,
                    created_at: chrono::DateTime::parse_from_rfc3339(&created_at)
                        .unwrap_or_default()
                        .with_timezone(&chrono::Utc),
                    delivered_at: delivered_at.and_then(|d| {
                        chrono::DateTime::parse_from_rfc3339(&d)
                            .ok()
                            .map(|dt| dt.with_timezone(&chrono::Utc))
                    }),
                },
            )
            .collect();

        Ok(messages)
    }

    async fn mark_delivered(&self, ids: &[i64]) -> Result<()> {
        if ids.is_empty() {
            return Ok(());
        }

        // $1 is for the timestamp, ids start from $2
        let placeholders: Vec<String> = (2..=ids.len() + 1).map(|i| format!("${}", i)).collect();
        let query = format!(
            "UPDATE solid_mcp_messages SET delivered_at = $1 WHERE id IN ({})",
            placeholders.join(", ")
        );

        let now = chrono::Utc::now().to_rfc3339();
        let mut q = sqlx::query(&query).bind(&now);
        for id in ids {
            q = q.bind(id);
        }
        q.execute(&self.pool).await?;

        Ok(())
    }

    async fn cleanup_delivered(&self, older_than: Duration) -> Result<u64> {
        let cutoff =
            (chrono::Utc::now() - chrono::Duration::from_std(older_than).unwrap()).to_rfc3339();

        let result = sqlx::query(
            r#"
            DELETE FROM solid_mcp_messages
            WHERE delivered_at IS NOT NULL AND delivered_at < $1
            "#,
        )
        .bind(&cutoff)
        .execute(&self.pool)
        .await?;

        Ok(result.rows_affected())
    }

    async fn cleanup_undelivered(&self, older_than: Duration) -> Result<u64> {
        let cutoff =
            (chrono::Utc::now() - chrono::Duration::from_std(older_than).unwrap()).to_rfc3339();

        let result = sqlx::query(
            r#"
            DELETE FROM solid_mcp_messages
            WHERE delivered_at IS NULL AND created_at < $1
            "#,
        )
        .bind(&cutoff)
        .execute(&self.pool)
        .await?;

        Ok(result.rows_affected())
    }

    async fn max_id(&self) -> Result<i64> {
        let row: (Option<i64>,) = sqlx::query_as("SELECT MAX(id) FROM solid_mcp_messages")
            .fetch_one(&self.pool)
            .await?;

        Ok(row.0.unwrap_or(0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Database;

    async fn create_test_pool() -> SqlitePool {
        let pool = SqlitePool::new("sqlite::memory:").await.unwrap();
        pool.setup_test_schema().await.unwrap();
        pool
    }

    #[tokio::test]
    async fn test_sqlite_pool_creation() {
        let pool = create_test_pool().await;
        assert_eq!(pool.max_id().await.unwrap(), 0);
    }

    #[tokio::test]
    async fn test_insert_and_fetch() {
        let pool = create_test_pool().await;

        let messages = vec![
            Message::new("session-1", "message", r#"{"test":1}"#),
            Message::new("session-1", "message", r#"{"test":2}"#),
        ];

        pool.insert_batch(&messages).await.unwrap();

        let fetched = pool.fetch_after("session-1", 0, 100).await.unwrap();
        assert_eq!(fetched.len(), 2);
        assert_eq!(fetched[0].data, r#"{"test":1}"#);
        assert_eq!(fetched[1].data, r#"{"test":2}"#);
    }

    #[tokio::test]
    async fn test_mark_delivered() {
        let pool = create_test_pool().await;

        let messages = vec![Message::new("session-1", "message", r#"{}"#)];
        pool.insert_batch(&messages).await.unwrap();

        let fetched = pool.fetch_after("session-1", 0, 100).await.unwrap();
        assert_eq!(fetched.len(), 1);

        pool.mark_delivered(&[fetched[0].id]).await.unwrap();

        // Should not fetch delivered messages
        let fetched = pool.fetch_after("session-1", 0, 100).await.unwrap();
        assert_eq!(fetched.len(), 0);
    }
}
