mod fd;

pub use fd::Fd;
#[cfg(any(target_os = "macos", target_os = "linux", target_os = "ios"))]
use std::process::Output;
#[cfg(any(target_os = "macos", target_os = "linux", target_os = "ios"))]
mod sockaddr;
#[cfg(any(target_os = "macos", target_os = "linux", target_os = "ios"))]
pub use sockaddr::SockAddr;

#[cfg(any(target_os = "macos", target_os = "linux", target_os = "ios"))]
pub fn exe_cmd(cmd: &str) -> std::io::Result<Output> {
    use std::io;
    use std::process::Command;
    println!("exe cmd: {}", cmd);
    let out = Command::new("sh")
        .arg("-c")
        .arg(cmd)
        .output()
        .expect("sh exec error!");
    if !out.status.success() {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            format!("cmd={},out={:?}", cmd, out),
        ));
    }
    Ok(out)
}
