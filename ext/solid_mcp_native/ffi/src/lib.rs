//! Ruby FFI bridge for solid-mcp-core
//!
//! Exposes the Rust pub/sub engine to Ruby via Magnus.

use magnus::{Error, Ruby, function};
use solid_mcp_core::{Config, PubSub};
use std::cell::RefCell;
use std::sync::{Arc, OnceLock};
use std::time::Duration;
use tokio::runtime::Runtime;
use tracing::Level;
use tracing_subscriber::FmtSubscriber;

// Global Tokio runtime
static RUNTIME: OnceLock<Runtime> = OnceLock::new();

// Thread-local PubSub instance (each Ruby thread gets its own)
thread_local! {
    static PUBSUB: RefCell<Option<Arc<PubSub>>> = const { RefCell::new(None) };
}

fn get_runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .worker_threads(4)
            .thread_name("solid-mcp-worker")
            .build()
            .expect("Failed to create Tokio runtime")
    })
}

/// Helper to create a runtime error
fn runtime_error(msg: impl Into<String>) -> Error {
    Error::new(Ruby::get().unwrap().exception_runtime_error(), msg.into())
}

/// Initialize the pub/sub engine with a database URL
fn init_engine(database_url: String) -> Result<bool, Error> {
    // Initialize tracing if DEBUG env var is set
    if std::env::var("DEBUG_SOLID_MCP").is_ok() {
        let subscriber = FmtSubscriber::builder()
            .with_max_level(Level::DEBUG)
            .finish();
        let _ = tracing::subscriber::set_global_default(subscriber);
    }

    let rt = get_runtime();

    let config = Config::new(&database_url);

    let pubsub = rt
        .block_on(async { PubSub::new(config).await })
        .map_err(|e| runtime_error(e.to_string()))?;

    PUBSUB.with(|ps| {
        *ps.borrow_mut() = Some(Arc::new(pubsub));
    });

    Ok(true)
}

/// Initialize with custom configuration
fn init_engine_with_config(
    database_url: String,
    batch_size: usize,
    polling_interval_ms: u64,
    max_queue_size: usize,
) -> Result<bool, Error> {
    let rt = get_runtime();

    let config = Config::new(&database_url)
        .batch_size(batch_size)
        .polling_interval(Duration::from_millis(polling_interval_ms))
        .max_queue_size(max_queue_size);

    let pubsub = rt
        .block_on(async { PubSub::new(config).await })
        .map_err(|e| runtime_error(e.to_string()))?;

    PUBSUB.with(|ps| {
        *ps.borrow_mut() = Some(Arc::new(pubsub));
    });

    Ok(true)
}

/// Broadcast a message to a session (non-blocking)
fn broadcast(session_id: String, event_type: String, data: String) -> Result<bool, Error> {
    PUBSUB.with(|ps| {
        let ps = ps.borrow();
        let pubsub = ps.as_ref().ok_or_else(|| {
            runtime_error("Engine not initialized")
        })?;

        pubsub
            .broadcast(&session_id, &event_type, &data)
            .map_err(|e| runtime_error(e.to_string()))
    })
}

/// Flush all pending messages to the database
fn flush() -> Result<bool, Error> {
    let rt = get_runtime();

    PUBSUB.with(|ps| {
        let ps = ps.borrow();
        let pubsub = ps.as_ref().ok_or_else(|| {
            runtime_error("Engine not initialized")
        })?;

        rt.block_on(async { pubsub.flush().await })
            .map_err(|e| runtime_error(e.to_string()))?;

        Ok(true)
    })
}

/// Mark messages as delivered
fn mark_delivered(ids: Vec<i64>) -> Result<bool, Error> {
    let rt = get_runtime();

    PUBSUB.with(|ps| {
        let ps = ps.borrow();
        let pubsub = ps.as_ref().ok_or_else(|| {
            runtime_error("Engine not initialized")
        })?;

        rt.block_on(async { pubsub.mark_delivered(&ids).await })
            .map_err(|e| runtime_error(e.to_string()))?;

        Ok(true)
    })
}

/// Cleanup old messages
/// Returns [delivered_count, undelivered_count]
fn cleanup() -> Result<Vec<u64>, Error> {
    let rt = get_runtime();

    PUBSUB.with(|ps| {
        let ps = ps.borrow();
        let pubsub = ps.as_ref().ok_or_else(|| {
            runtime_error("Engine not initialized")
        })?;

        let (delivered, undelivered) = rt
            .block_on(async { pubsub.cleanup().await })
            .map_err(|e| runtime_error(e.to_string()))?;

        Ok(vec![delivered, undelivered])
    })
}

/// Shutdown the pub/sub engine
fn shutdown() -> Result<bool, Error> {
    let rt = get_runtime();

    PUBSUB.with(|ps| {
        let mut ps = ps.borrow_mut();
        if let Some(pubsub) = ps.take() {
            // Try to get exclusive access
            match Arc::try_unwrap(pubsub) {
                Ok(pubsub) => {
                    let _ = rt.block_on(async { pubsub.shutdown().await });
                }
                Err(_) => {
                    // Other references exist, can't fully shutdown
                    tracing::warn!("Cannot fully shutdown: other references exist");
                }
            }
        }
        Ok(true)
    })
}

/// Get the library version
fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

/// Check if the engine is initialized
fn initialized() -> bool {
    PUBSUB.with(|ps| ps.borrow().is_some())
}

/// Get subscription count
fn subscription_count() -> Result<usize, Error> {
    let rt = get_runtime();

    PUBSUB.with(|ps| {
        let ps = ps.borrow();
        let pubsub = ps.as_ref().ok_or_else(|| {
            runtime_error("Engine not initialized")
        })?;

        Ok(rt.block_on(async { pubsub.subscription_count().await }))
    })
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("SolidMCPNative")?;

    // Core functions
    module.define_module_function("version", function!(version, 0))?;
    module.define_module_function("initialized?", function!(initialized, 0))?;

    // Lifecycle
    module.define_module_function("init", function!(init_engine, 1))?;
    module.define_module_function("init_with_config", function!(init_engine_with_config, 4))?;
    module.define_module_function("shutdown", function!(shutdown, 0))?;

    // Messaging
    module.define_module_function("broadcast", function!(broadcast, 3))?;
    module.define_module_function("flush", function!(flush, 0))?;
    module.define_module_function("mark_delivered", function!(mark_delivered, 1))?;
    module.define_module_function("cleanup", function!(cleanup, 0))?;

    // Status
    module.define_module_function("subscription_count", function!(subscription_count, 0))?;

    Ok(())
}
