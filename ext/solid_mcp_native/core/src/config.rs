//! Configuration for solid-mcp-core

use std::time::Duration;

/// Configuration for the pub/sub engine
#[derive(Debug, Clone)]
pub struct Config {
    /// Maximum messages per batch write (default: 200)
    pub batch_size: usize,

    /// Polling interval for SQLite subscribers (default: 100ms)
    pub polling_interval: Duration,

    /// Maximum wait time for SSE connections (default: 30s)
    pub max_wait_time: Duration,

    /// How long to keep delivered messages (default: 1 hour)
    pub delivered_retention: Duration,

    /// How long to keep undelivered messages (default: 24 hours)
    pub undelivered_retention: Duration,

    /// Maximum messages in memory queue (default: 10,000)
    pub max_queue_size: usize,

    /// Maximum time to wait for graceful shutdown (default: 30s)
    pub shutdown_timeout: Duration,

    /// Database URL (required)
    pub database_url: String,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            batch_size: 200,
            polling_interval: Duration::from_millis(100),
            max_wait_time: Duration::from_secs(30),
            delivered_retention: Duration::from_secs(3600),
            undelivered_retention: Duration::from_secs(86400),
            max_queue_size: 10_000,
            shutdown_timeout: Duration::from_secs(30),
            database_url: String::new(),
        }
    }
}

impl Config {
    /// Create a new config with the given database URL
    pub fn new(database_url: impl Into<String>) -> Self {
        Self {
            database_url: database_url.into(),
            ..Default::default()
        }
    }

    /// Builder pattern: set batch size
    pub fn batch_size(mut self, size: usize) -> Self {
        self.batch_size = size;
        self
    }

    /// Builder pattern: set polling interval
    pub fn polling_interval(mut self, interval: Duration) -> Self {
        self.polling_interval = interval;
        self
    }

    /// Builder pattern: set max queue size
    pub fn max_queue_size(mut self, size: usize) -> Self {
        self.max_queue_size = size;
        self
    }

    /// Builder pattern: set shutdown timeout
    pub fn shutdown_timeout(mut self, timeout: Duration) -> Self {
        self.shutdown_timeout = timeout;
        self
    }

    /// Check if this is a PostgreSQL connection
    pub fn is_postgres(&self) -> bool {
        self.database_url.starts_with("postgres://")
            || self.database_url.starts_with("postgresql://")
    }

    /// Check if this is a SQLite connection
    pub fn is_sqlite(&self) -> bool {
        self.database_url.starts_with("sqlite://")
            || self.database_url.starts_with("sqlite:")
            || self.database_url.ends_with(".db")
            || self.database_url.ends_with(".sqlite")
            || self.database_url.ends_with(".sqlite3")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_config() {
        let config = Config::default();
        assert_eq!(config.batch_size, 200);
        assert_eq!(config.polling_interval, Duration::from_millis(100));
        assert_eq!(config.max_queue_size, 10_000);
    }

    #[test]
    fn test_builder_pattern() {
        let config = Config::new("sqlite::memory:")
            .batch_size(100)
            .polling_interval(Duration::from_millis(50))
            .max_queue_size(5000);

        assert_eq!(config.batch_size, 100);
        assert_eq!(config.polling_interval, Duration::from_millis(50));
        assert_eq!(config.max_queue_size, 5000);
        assert_eq!(config.database_url, "sqlite::memory:");
    }

    #[test]
    fn test_database_type_detection() {
        assert!(Config::new("postgres://localhost/test").is_postgres());
        assert!(Config::new("postgresql://localhost/test").is_postgres());
        assert!(!Config::new("postgres://localhost/test").is_sqlite());

        assert!(Config::new("sqlite::memory:").is_sqlite());
        assert!(Config::new("sqlite://./test.db").is_sqlite());
        assert!(Config::new("./test.sqlite3").is_sqlite());
        assert!(!Config::new("sqlite::memory:").is_postgres());
    }
}
