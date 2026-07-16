//! Zero-install machine capability probes (Bundles M1).
//!
//! `profile::detect()` reads RAM/arch/disk/etc.; `profile::system_profile`
//! is the Tauri command registered in `lib.rs`.

pub mod profile;
