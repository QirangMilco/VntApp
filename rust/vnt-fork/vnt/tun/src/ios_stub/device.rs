use crate::device::IFace;
use crate::Fd;
use std::io;
use std::net::Ipv4Addr;
use std::os::fd::RawFd;
use std::sync::atomic::{AtomicUsize, Ordering};
#[cfg(target_os = "ios")]
use libc;

/// iOS TUN device backed by two pipes (not a utun fd directly).
///
/// The PacketTunnelProvider Extension is the sole reader/writer of `packetFlow`.
/// It forwards received packets to this device via `read_fd`, and reads
/// outbound packets from `write_fd`.
///
/// Wire format (BOTH directions — symmetric):
///   [4-byte BE total_length][4-byte BE protocol_family][IP packet data]
///   where total_length = 4 + IP_packet_length
///   protocol_family = AF_INET (2) or AF_INET6 (30)
static IOS_PIPE_READ_ICMP_TRACE_COUNT: AtomicUsize = AtomicUsize::new(0);

pub struct Device {
    /// Pipe fd we read from: Extension writes packets here
    read_fd: Fd,
    /// Pipe fd we write to: Extension reads packets from here
    write_fd: Fd,
}

impl Device {
    /// Create device with separate read and write pipe fds.
    /// `read_fd`: the fd to read IP packets from (Extension → App pipe, app's read end)
    /// `write_fd`: the fd to write IP packets to (App → Extension pipe, app's write end)
    pub fn new(read_fd: RawFd, write_fd: RawFd) -> io::Result<Self> {
        log::info!("[iOS pipe] Device::new(read_fd={}, write_fd={})", read_fd, write_fd);

        // On iOS, ignore SIGPIPE globally. When the Extension dies or pipe breaks,
        // write() would otherwise raise SIGPIPE which kills the process immediately.
        // With SIGPIPE ignored, write() returns EPIPE instead, which we handle as an error.
        unsafe {
            libc::signal(libc::SIGPIPE, libc::SIG_IGN);
        }

        Ok(Self {
            read_fd: Fd::new(read_fd)?,
            write_fd: Fd::new(write_fd)?,
        })
    }
}

impl Device {
    /// Return the read fd for mio poll registration.
    pub fn as_tun_fd(&self) -> &Fd {
        &self.read_fd
    }
}

impl IFace for Device {
    fn version(&self) -> io::Result<String> {
        Ok(String::new())
    }

    fn name(&self) -> io::Result<String> {
        Ok(String::new())
    }

    fn shutdown(&self) -> io::Result<()> {
        Err(io::Error::from(io::ErrorKind::Unsupported))
    }

    fn set_ip(&self, _address: Ipv4Addr, _mask: Ipv4Addr) -> io::Result<()> {
        Ok(())
    }

    fn mtu(&self) -> io::Result<u32> {
        Ok(1500)
    }

    fn set_mtu(&self, _value: u32) -> io::Result<()> {
        Ok(())
    }

    fn add_route(&self, _dest: Ipv4Addr, _netmask: Ipv4Addr, _metric: u16) -> io::Result<()> {
        Ok(())
    }

    fn delete_route(&self, _dest: Ipv4Addr, _netmask: Ipv4Addr) -> io::Result<()> {
        Ok(())
    }

    fn read(&self, buf: &mut [u8]) -> io::Result<usize> {
        // Read 4-byte total_length prefix
        let mut len_buf = [0u8; 4];
        read_exact(&self.read_fd, &mut len_buf).map_err(|e| {
            log::error!("[iOS pipe] read total_length failed: {}", e);
            e
        })?;
        let total_len = u32::from_be_bytes(len_buf) as usize;

        if total_len < 4 || total_len > buf.len() {
            log::error!("[iOS pipe] invalid total_length from pipe: {}", total_len);
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("invalid total_length from pipe: {}", total_len),
            ));
        }

        // total_len = 4 (protocol_family) + IP_packet_length
        let packet_len = total_len - 4;

        // Read 4-byte protocol_family
        let mut proto_buf = [0u8; 4];
        read_exact(&self.read_fd, &mut proto_buf).map_err(|e| {
            log::error!("[iOS pipe] read protocol_family failed: {}", e);
            e
        })?;
        let _proto_family = u32::from_be_bytes(proto_buf);

        // Read the actual IP packet data
        read_exact(&self.read_fd, &mut buf[..packet_len]).map_err(|e| {
            log::error!("[iOS pipe] read packet data ({} bytes) failed: {}", packet_len, e);
            e
        })?;

        if packet_len >= 20 {
            let version = buf[0] >> 4;
            let proto = buf[9];
            if version == 4 && proto == 1 {
                let idx = IOS_PIPE_READ_ICMP_TRACE_COUNT.fetch_add(1, Ordering::Relaxed);
                if idx < 20 {
                    let src = format!("{}.{}.{}.{}", buf[12], buf[13], buf[14], buf[15]);
                    let dst = format!("{}.{}.{}.{}", buf[16], buf[17], buf[18], buf[19]);
                    log::info!(
                        "[iOS ICMP TRACE][ios-pipe-read#{}] src={} dst={} len={}",
                        idx + 1,
                        src,
                        dst,
                        packet_len
                    );
                }
            }
        }

        Ok(packet_len)
    }

    fn write(&self, buf: &[u8]) -> io::Result<usize> {
        // Write to the appToExt pipe: [4-byte BE total_length][4-byte BE protocol_family][IP packet data]
        // total_length = 4 (proto) + IP_packet_length
        // Determine protocol from the IP version nibble
        let protocol_family = if !buf.is_empty() && (buf[0] >> 4) == 6 {
            libc::PF_INET6 as u32
        } else {
            libc::PF_INET as u32
        };
        if protocol_family == libc::PF_INET as u32 && buf.len() >= 20 {
            let proto = buf[9];
            if proto == 1 {
                let src = format!("{}.{}.{}.{}", buf[12], buf[13], buf[14], buf[15]);
                let dst = format!("{}.{}.{}.{}", buf[16], buf[17], buf[18], buf[19]);
                log::info!(
                    "[iOS ICMP TRACE][ios-pipe-write] src={} dst={} len={}",
                    src,
                    dst,
                    buf.len()
                );
            }
        }
        let total_len = (4 + buf.len() as u32).to_be_bytes();
        fd_write_all(&self.write_fd, &total_len).map_err(|e| {
            log::error!("[iOS pipe] write total_length header failed: {}", e);
            e
        })?;
        fd_write_all(&self.write_fd, &protocol_family.to_be_bytes()).map_err(|e| {
            log::error!("[iOS pipe] write protocol_family header failed: {}", e);
            e
        })?;
        fd_write_all(&self.write_fd, buf).map_err(|e| {
            log::error!("[iOS pipe] write packet data ({} bytes) failed: {}", buf.len(), e);
            e
        })?;
        Ok(buf.len())
    }
}

/// Read exactly `n` bytes from an Fd, handling partial reads and WouldBlock
fn read_exact(fd: &Fd, buf: &mut [u8]) -> io::Result<()> {
    let mut offset = 0;
    while offset < buf.len() {
        match fd.read(&mut buf[offset..]) {
            Ok(0) => return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "pipe closed")),
            Ok(n) => offset += n,
            Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => {
                std::thread::sleep(std::time::Duration::from_micros(100));
            }
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

/// Write all bytes to an Fd, retrying on WouldBlock
fn fd_write_all(fd: &Fd, mut buf: &[u8]) -> io::Result<()> {
    while !buf.is_empty() {
        match fd.write(buf) {
            Ok(0) => return Err(io::Error::new(io::ErrorKind::WriteZero, "write_all: zero write")),
            Ok(n) => buf = &buf[n..],
            Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => {
                std::thread::sleep(std::time::Duration::from_micros(100));
            }
            Err(e) => return Err(e),
        }
    }
    Ok(())
}
