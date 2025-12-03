//! # solid-mcp-core
//!
//! High-performance async pub/sub engine for MCP (Model Context Protocol).
//!
//! This crate provides the core functionality for solid_mcp:
//! - Async message writing with batching
//! - Session-based subscriptions with PostgreSQL LISTEN/NOTIFY or SQLite polling
//! - Database-backed message persistence
//!
//! ## Features
//! - `sqlite` - Enable SQLite backend (default)
//! - `postgres` - Enable PostgreSQL backend with LISTEN/NOTIFY (default)

pub mod config;
pub mod db;
pub mod error;
pub mod message;
pub mod pubsub;
pub mod subscriber;
pub mod writer;

pub use config::Config;
pub use error::{Error, Result};
pub use message::Message;
pub use pubsub::PubSub;
