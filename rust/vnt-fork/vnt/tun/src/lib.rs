/// 参考
/// https://github.com/meh/rust-tun
/// https://github.com/Tazdevil971/tap-windows
/// https://github.com/nulldotblack/wintun

pub mod device;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub use linux::Device;

#[cfg(target_os = "android")]
mod android;
#[cfg(target_os = "android")]
pub use android::Device;

// macOS and iOS both use utun, but ioctl-sys doesn't support iOS
// So we only enable macOS for now
#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
pub use macos::Device;

// iOS uses a stub that requires file descriptor from Network Extension
#[cfg(target_os = "ios")]
mod ios_stub;
#[cfg(target_os = "ios")]
pub use ios_stub::Device;

#[cfg(unix)]
mod unix;
#[cfg(unix)]
pub use unix::Fd;

#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub use windows::Device;

#[cfg(windows)]
mod packet;
