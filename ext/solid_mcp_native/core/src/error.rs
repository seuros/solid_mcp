//! Error types for solid-mcp-core

use thiserror::Error;

/// Result type alias using our Error type
pub type Result<T> = std::result::Result<T, Error>;

/// Errors that can occur in solid-mcp-core
#[derive(Error, Debug)]
pub enum Error {
    /// Database operation failed
    #[error("database error: {0}")]
    Database(#[from] sqlx::Error),

    /// JSON serialization/deserialization failed
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),

    /// Channel send failed (queue full or shutdown)
    #[error("channel send error: queue full or shutdown")]
    ChannelSend,

    /// Channel receive failed (shutdown)
    #[error("channel receive error: shutdown")]
    ChannelRecv,

    /// Configuration error
    #[error("configuration error: {0}")]
    Config(String),

    /// Shutdown requested
    #[error("shutdown requested")]
    Shutdown,

    /// Session not found
    #[error("session not found: {0}")]
    SessionNotFound(String),
}
