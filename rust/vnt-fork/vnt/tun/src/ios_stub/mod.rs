//! iOS TUN Device Stub Implementation
//!
//! This module provides a stub implementation for iOS TUN devices.
//! On iOS, TUN devices must be created through the Network Extension framework,
//! and the file descriptor is passed from Swift/Objective-C code via FFI.
//!
//! This stub allows the project to compile for iOS, but requires the application
//! to handle TUN device creation through the callback mechanism.

mod device;
pub use device::Device;
