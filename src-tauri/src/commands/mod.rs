//! Tauri command surface. One sub-module per cluster of related commands.
//!
//! `lib.rs` re-exports these via `commands::*` and registers them in
//! `tauri::generate_handler![]`.

pub mod actions;
pub mod brew_env;
pub mod brewfile;
pub mod bundles;
pub mod cask_icon;
pub mod cask_icon_homepage;
pub mod catalog;
pub mod categories;
pub mod disk_usage;
pub mod enrichment;
pub mod env;
pub mod github;
pub mod info;
pub mod list;
pub mod search;
pub mod services;
pub mod settings;
pub mod trending;
pub mod updater;
pub mod vulns;

// Re-export every command in flat form so `invoke_handler!` can take them.
pub use actions::*;
pub use brew_env::*;
pub use brewfile::*;
pub use bundles::*;
pub use cask_icon::*;
pub use cask_icon_homepage::*;
pub use catalog::*;
pub use categories::*;
pub use disk_usage::*;
pub use enrichment::*;
pub use env::*;
pub use github::*;
pub use info::*;
pub use list::*;
pub use search::*;
pub use services::*;
pub use settings::*;
pub use trending::*;
pub use updater::*;
pub use vulns::*;
