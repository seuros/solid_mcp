//! PostgreSQL database backend for solid-mcp-core
//!
//! Supports LISTEN/NOTIFY for real-time message delivery without polling.

use crate::{Message, Result};
use async_trait::async_trait;
use sqlx::postgres::{PgConnectOptions, PgListener, PgPoolOptions};
use sqlx::{Pool, Postgres};
use std::str::FromStr;
use std::time::Duration;

/// PostgreSQL connection pool
#[derive(Clone)]
pub struct PostgresPool {
    pool: Pool<Postgres>,
    database_url: String,
}

impl PostgresPool {
    /// Create a new PostgreSQL pool from a database URL
    pub async fn new(database_url: &str) -> Result<Self> {
        let options = PgConnectOptions::from_str(database_url)?;

        let pool = PgPoolOptions::new()
            .max_connections(10)
            .acquire_timeout(Duration::from_secs(30))
            .connect_with(options)
            .await?;

        let this = Self {
            pool,
            database_url: database_url.to_string(),
        };
        this.migrate().await?;

        Ok(this)
    }

    /// Run database migrations
    async fn migrate(&self) -> Result<()> {
        sqlx::query(
            r#"
            CREATE TABLE IF NOT EXISTS solid_mcp_messages (
                id BIGSERIAL PRIMARY KEY,
                session_id VARCHAR(36) NOT NULL,
                event_type VARCHAR(50) NOT NULL,
                data TEXT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                delivered_at TIMESTAMPTZ
            )
            "#,
        )
        .execute(&self.pool)
        .await?;

        // Create indexes
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

        // Create NOTIFY trigger for real-time updates
        sqlx::query(
            r#"
            CREATE OR REPLACE FUNCTION solid_mcp_notify()
            RETURNS TRIGGER AS $$
            BEGIN
                PERFORM pg_notify('solid_mcp_' || NEW.session_id, NEW.id::text);
                RETURN NEW;
            END;
            $$ LANGUAGE plpgsql
            "#,
        )
        .execute(&self.pool)
        .await?;

        // Create trigger if not exists (PostgreSQL doesn't have IF NOT EXISTS for triggers)
        sqlx::query(
            r#"
            DO $$
            BEGIN
                IF NOT EXISTS (
                    SELECT 1 FROM pg_trigger WHERE tgname = 'solid_mcp_insert_trigger'
                ) THEN
                    CREATE TRIGGER solid_mcp_insert_trigger
                    AFTER INSERT ON solid_mcp_messages
                    FOR EACH ROW
                    EXECUTE FUNCTION solid_mcp_notify();
                END IF;
            END $$
            "#,
        )
        .execute(&self.pool)
        .await?;

        Ok(())
    }

    /// Create a LISTEN connection for a session
    ///
    /// This is used for real-time message delivery without polling.
    pub async fn listen(&self, session_id: &str) -> Result<PgListener> {
        let mut listener = PgListener::connect(&self.database_url).await?;
        let channel = format!("solid_mcp_{}", session_id);
        listener.listen(&channel).await?;
        Ok(listener)
    }

    /// Send a NOTIFY for a session (called after insert for immediate delivery)
    pub async fn notify(&self, session_id: &str, message_id: i64) -> Result<()> {
        let channel = format!("solid_mcp_{}", session_id);
        sqlx::query("SELECT pg_notify($1, $2)")
            .bind(&channel)
            .bind(message_id.to_string())
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}

#[async_trait]
impl super::Database for PostgresPool {
    async fn insert_batch(&self, messages: &[Message]) -> Result<()> {
        if messages.is_empty() {
            return Ok(());
        }

        // Use COPY for maximum performance on large batches
        // Fall back to multi-row INSERT for smaller batches
        if messages.len() >= 100 {
            self.insert_batch_copy(messages).await
        } else {
            self.insert_batch_values(messages).await
        }
    }

    async fn fetch_after(
        &self,
        session_id: &str,
        after_id: i64,
        limit: i64,
    ) -> Result<Vec<Message>> {
        let rows = sqlx::query_as::<
            _,
            (
                i64,
                String,
                String,
                String,
                chrono::DateTime<chrono::Utc>,
                Option<chrono::DateTime<chrono::Utc>>,
            ),
        >(
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
            .map(|(id, session_id, event_type, data, created_at, delivered_at)| Message {
                id,
                session_id,
                event_type,
                data,
                created_at,
                delivered_at,
            })
            .collect();

        Ok(messages)
    }

    async fn mark_delivered(&self, ids: &[i64]) -> Result<()> {
        if ids.is_empty() {
            return Ok(());
        }

        sqlx::query(
            r#"
            UPDATE solid_mcp_messages
            SET delivered_at = NOW()
            WHERE id = ANY($1)
            "#,
        )
        .bind(ids)
        .execute(&self.pool)
        .await?;

        Ok(())
    }

    async fn cleanup_delivered(&self, older_than: Duration) -> Result<u64> {
        let cutoff = chrono::Utc::now() - chrono::Duration::from_std(older_than).unwrap();

        let result = sqlx::query(
            r#"
            DELETE FROM solid_mcp_messages
            WHERE delivered_at IS NOT NULL AND delivered_at < $1
            "#,
        )
        .bind(cutoff)
        .execute(&self.pool)
        .await?;

        Ok(result.rows_affected())
    }

    async fn cleanup_undelivered(&self, older_than: Duration) -> Result<u64> {
        let cutoff = chrono::Utc::now() - chrono::Duration::from_std(older_than).unwrap();

        let result = sqlx::query(
            r#"
            DELETE FROM solid_mcp_messages
            WHERE delivered_at IS NULL AND created_at < $1
            "#,
        )
        .bind(cutoff)
        .execute(&self.pool)
        .await?;

        Ok(result.rows_affected())
    }

    async fn max_id(&self) -> Result<i64> {
        let row: (Option<i64>,) =
            sqlx::query_as("SELECT MAX(id) FROM solid_mcp_messages")
                .fetch_one(&self.pool)
                .await?;

        Ok(row.0.unwrap_or(0))
    }
}

impl PostgresPool {
    /// Insert using multi-row VALUES (good for small batches)
    async fn insert_batch_values(&self, messages: &[Message]) -> Result<()> {
        let mut query = String::from(
            "INSERT INTO solid_mcp_messages (session_id, event_type, data, created_at) VALUES ",
        );

        for (i, _) in messages.iter().enumerate() {
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
        }

        let mut q = sqlx::query(&query);
        for msg in messages {
            q = q
                .bind(&msg.session_id)
                .bind(&msg.event_type)
                .bind(&msg.data)
                .bind(msg.created_at);
        }
        q.execute(&self.pool).await?;

        Ok(())
    }

    /// Insert using COPY (efficient for large batches)
    async fn insert_batch_copy(&self, messages: &[Message]) -> Result<()> {
        // For now, fall back to VALUES insert
        // TODO: Implement proper COPY protocol for maximum throughput
        self.insert_batch_values(messages).await
    }
}

#[cfg(test)]
mod tests {
    // PostgreSQL tests require a running database
    // Run with: DATABASE_URL=postgres://localhost/test_solid_mcp cargo test

    use super::*;
    use crate::db::Database;

    #[tokio::test]
    #[ignore] // Requires PostgreSQL
    async fn test_postgres_pool_creation() {
        let url = std::env::var("DATABASE_URL").unwrap_or_else(|_| {
            "postgres://localhost/test_solid_mcp".to_string()
        });
        let pool = PostgresPool::new(&url).await.unwrap();
        let _ = pool.max_id().await.unwrap();
    }
}
