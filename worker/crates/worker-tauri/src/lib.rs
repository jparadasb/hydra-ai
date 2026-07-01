//! Command layer for the hydra-worker desktop app.
//!
//! Every function here returns a serializable DTO that is safe to hand to the web UI. Raw
//! tokens NEVER cross this boundary — only masked fingerprints and booleans. The Tauri app
//! wraps each `commands::*` function in a `#[tauri::command]` and exposes it to the frontend.

pub mod commands;
pub mod dto;
pub mod runner;
pub mod support;

pub use commands::Commands;
pub use runner::Runner;
