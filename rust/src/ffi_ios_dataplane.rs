use crate::api::vnt_api;
use std::collections::VecDeque;
use std::ffi::{c_char, CStr};
use std::io;
use std::net::{Ipv4Addr, Ipv6Addr};
use std::ptr;
use std::slice;
use std::str::FromStr;
use std::sync::{Arc, Mutex, OnceLock};

const VNT_PACKET_HEADROOM: usize = 12;
const VNT_PACKET_ENCRYPTION_RESERVED: usize = 60;
const VNT_PACKET_BUFFER_PREFIX: usize = VNT_PACKET_HEADROOM;
const VNT_PACKET_BUFFER_SUFFIX: usize = VNT_PACKET_ENCRYPTION_RESERVED;

use serde::{Deserialize, Serialize};
use vnt::channel::punch::PunchModel;
use vnt::channel::{sender::IpPacketSender, UseChannelType};
use vnt::cipher::CipherModel;
use vnt::compression::Compressor;
use vnt::core::{Config, Vnt};
use vnt::vnt_device::DeviceWrite;
use vnt::handle::callback::RegisterInfo;
use vnt::VntCallback;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct IosPeerRouteSnapshot {
    protocol: String,
    addr: String,
    metric: u8,
    rt: i64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct IosPeerSnapshot {
    virtual_ip: String,
    name: String,
    status: String,
    client_secret: bool,
    route: Option<IosPeerRouteSnapshot>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct IosDataplaneSnapshot {
    running: bool,
    current_virtual_ip: Option<String>,
    current_virtual_netmask: Option<String>,
    current_virtual_gateway: Option<String>,
    current_virtual_network: Option<String>,
    current_connect_server: Option<String>,
    current_status: Option<String>,
    current_broadcast_ip: Option<String>,
    nat_type: Option<String>,
    public_ips: Option<Vec<String>>,
    local_ipv4: Option<String>,
    ipv6: Option<String>,
    peer_virtual_ips: Vec<String>,
    peer_devices: Vec<IosPeerSnapshot>,
    last_error: Option<String>,
    last_error_code: i32,
}

#[repr(C)]
pub struct VntIosDataplaneStats {
    pub running: i32,
    pub packets_from_system: u64,
    pub packets_to_system: u64,
    pub output_queue_len: u64,
    pub output_dropped: u64,
    pub poll_error_count: u64,
    pub last_error_code: i32,
    pub ipv6_enabled: i32,
    pub ipv6_map_size: u64,
    pub ipv6_map_miss_count: u64,
    pub ipv6_compat_downgrade_count: u64,
}

#[derive(Clone)]
struct IosDeviceWriter {
    output_packets: Arc<Mutex<VecDeque<(Vec<u8>, i32)>>>,
}

impl DeviceWrite for IosDeviceWriter {
    fn write(&self, buf: &[u8]) -> io::Result<usize> {
        const MAX_OUTPUT_QUEUE: usize = 2048;

        let proto = if !buf.is_empty() && (buf[0] >> 4) == 6 { 30 } else { 2 };
        if let Ok(mut q) = self.output_packets.lock() {
            if q.len() >= MAX_OUTPUT_QUEUE {
                q.pop_front();
                if let Ok(mut state) = global_state().lock() {
                    state.output_dropped = state.output_dropped.saturating_add(1);
                    state.last_error_code = -6;
                    state.last_error = Some("output queue overflow, drop oldest".to_string());
                }
            }
            q.push_back((buf.to_vec(), proto));
            Ok(buf.len())
        } else {
            Err(io::Error::new(io::ErrorKind::Other, "queue lock failed"))
        }
    }

    fn into_device_adapter(self) -> vnt::tun_create_helper::DeviceAdapter {
        vnt::tun_create_helper::DeviceAdapter::default()
    }
}

#[derive(Clone, Default)]
struct IosVntCallback;
impl VntCallback for IosVntCallback {
    fn register(&self, info: RegisterInfo) -> bool {
        if let Ok(mut state) = global_state().lock() {
            if state.running {
                state.assigned_virtual_ip = Some(info.virtual_ip);
                state.assigned_virtual_netmask = Some(info.virtual_netmask);
                state.assigned_virtual_gateway = Some(info.virtual_gateway);
                state.last_error_code = 0;
            }
        }
        true
    }

    fn peer_client_list(&self, info: Vec<vnt::handle::callback::PeerClientInfo>) {
        if let Ok(mut state) = global_state().lock() {
            if state.running {
                let mut peer_virtual_ips = info
                    .into_iter()
                    .map(|peer| peer.virtual_ip)
                    .collect::<Vec<_>>();
                peer_virtual_ips.sort_unstable();
                peer_virtual_ips.dedup();
                state.peer_virtual_ips = peer_virtual_ips;
            }
        }
    }
}

#[derive(Default)]
struct DataPlaneState {
    running: bool,
    packets_from_system: u64,
    packets_to_system: u64,
    last_error: Option<String>,
    last_error_code: i32,
    output_dropped: u64,
    poll_error_count: u64,
    ipv6_enabled: bool,
    ipv6_map_miss_count: u64,
    ipv6_compat_downgrade_count: u64,
    assigned_virtual_ip: Option<Ipv4Addr>,
    assigned_virtual_netmask: Option<Ipv4Addr>,
    assigned_virtual_gateway: Option<Ipv4Addr>,
    peer_virtual_ips: Vec<Ipv4Addr>,
    sender: Option<IpPacketSender>,
    vnt: Option<Vnt>,
    ipv6_to_virtual_ipv4: std::collections::HashMap<Ipv6Addr, Ipv4Addr>,
    output_packets: Arc<Mutex<VecDeque<(Vec<u8>, i32)>>>,
}

fn global_state() -> &'static Mutex<DataPlaneState> {
    static STATE: OnceLock<Mutex<DataPlaneState>> = OnceLock::new();
    STATE.get_or_init(|| Mutex::new(DataPlaneState::default()))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct IosVntConfig {
    token: String,
    device_id: String,
    name: String,
    server_address_str: String,
    #[serde(default)]
    name_servers: Vec<String>,
    #[serde(default)]
    stun_server: Vec<String>,
    #[serde(default)]
    in_ips: Vec<(u32, u32, String)>,
    #[serde(default)]
    out_ips: Vec<(u32, u32)>,
    #[serde(default)]
    password: Option<String>,
    #[serde(default)]
    mtu: Option<u32>,
    #[serde(default)]
    ip: Option<String>,
    #[serde(default)]
    no_proxy: bool,
    #[serde(default)]
    server_encrypt: bool,
    #[serde(default = "default_cipher_model")]
    cipher_model: String,
    #[serde(default)]
    finger: bool,
    #[serde(default = "default_punch_model")]
    punch_model: String,
    #[serde(default)]
    ports: Option<Vec<u16>>,
    #[serde(default)]
    first_latency: bool,
    #[serde(default = "default_use_channel_type")]
    use_channel_type: String,
    #[serde(default)]
    packet_loss_rate: Option<f64>,
    #[serde(default)]
    packet_delay: u32,
    #[serde(default)]
    port_mapping_list: Vec<String>,
    #[serde(default = "default_compressor")]
    compressor: String,
    #[serde(default)]
    allow_wire_guard: bool,
    #[serde(default)]
    local_ipv4: Option<String>,
    #[serde(default = "default_enable_ipv6_over_vnt")]
    enable_ipv6_over_vnt: bool,
}

fn default_cipher_model() -> String {
    "none".to_string()
}
fn default_punch_model() -> String {
    "all".to_string()
}
fn default_use_channel_type() -> String {
    "all".to_string()
}
fn default_compressor() -> String {
    "none".to_string()
}
fn default_enable_ipv6_over_vnt() -> bool {
    true
}

fn parse_config(config_json: *const c_char) -> anyhow::Result<IosVntConfig> {
    if config_json.is_null() {
        anyhow::bail!("配置为空")
    }
    let cstr = unsafe { CStr::from_ptr(config_json) };
    let text = cstr.to_string_lossy();

    let value: serde_json::Value = serde_json::from_str(&text)?;
    if let Some(vnt_config_json) = value
        .get("vntConfigJson")
        .and_then(|v| v.as_str())
        .filter(|v| !v.is_empty())
    {
        let cfg: IosVntConfig = serde_json::from_str(vnt_config_json)?;
        return Ok(cfg);
    }

    let cfg: IosVntConfig = serde_json::from_value(value)?;
    Ok(cfg)
}

fn build_vnt(cfg: IosVntConfig, writer: IosDeviceWriter) -> anyhow::Result<(Vnt, IpPacketSender)> {
    let mut in_ips = Vec::with_capacity(cfg.in_ips.len());
    for (a, b, ip) in cfg.in_ips {
        in_ips.push((a, b, Ipv4Addr::from_str(&ip)?));
    }

    let ip = cfg.ip.map(|v| Ipv4Addr::from_str(&v)).transpose()?;
    let cipher_model = CipherModel::from_str(&cfg.cipher_model)
        .map_err(|e| anyhow::anyhow!("cipher_model 无效: {:?}", e))?;
    let punch_model = PunchModel::from_str(&cfg.punch_model)
        .map_err(|e| anyhow::anyhow!("punch_model 无效: {:?}", e))?;
    let use_channel_type = UseChannelType::from_str(&cfg.use_channel_type)
        .map_err(|e| anyhow::anyhow!("use_channel_type 无效: {:?}", e))?;
    let compressor = Compressor::from_str(&cfg.compressor)
        .map_err(|e| anyhow::anyhow!("compressor 无效: {:?}", e))?;

    let conf = Config::new(
        cfg.token,
        cfg.device_id,
        cfg.name,
        cfg.server_address_str,
        cfg.name_servers,
        cfg.stun_server,
        in_ips,
        cfg.out_ips,
        cfg.password,
        cfg.mtu,
        ip,
        cfg.no_proxy,
        cfg.server_encrypt,
        cipher_model,
        cfg.finger,
        punch_model,
        cfg.ports,
        cfg.first_latency,
        #[cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))]
        None,
        use_channel_type,
        cfg.packet_loss_rate,
        cfg.packet_delay,
        cfg.port_mapping_list,
        compressor,
        true,
        cfg.allow_wire_guard,
        cfg.local_ipv4,
        false,
    )?;

    let vnt = Vnt::new_device(conf, IosVntCallback, writer)?;
    let sender = vnt
        .ipv4_packet_sender()
        .ok_or_else(|| anyhow::anyhow!("未获取到 ipv4 sender"))?;

    Ok((vnt, sender))
}

#[unsafe(no_mangle)]
pub extern "C" fn vnt_ios_dataplane_init_log(log_dir: *const c_char) -> i32 {
    if log_dir.is_null() {
        return -2;
    }

    let cstr = unsafe { CStr::from_ptr(log_dir) };
    let path = cstr.to_string_lossy().trim().to_string();
    if path.is_empty() {
        return -2;
    }

    match vnt_api::init_log_with_path(path.clone()) {
        Ok(_) => {
            log::info!("[ios-dataplane] file log initialized: {}", path);
            0
        }
        Err(e) => {
            eprintln!("[ios-dataplane] init log failed: {}", e);
            if let Ok(mut s) = global_state().lock() {
                s.last_error = Some(format!("日志初始化失败: {e}"));
                s.last_error_code = -9;
            }
            -9
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn vnt_ios_dataplane_start(config_json: *const c_char) -> i32 {
    let cfg = match parse_config(config_json) {
        Ok(v) => v,
        Err(e) => {
            if let Ok(mut s) = global_state().lock() {
                s.last_error = Some(format!("配置解析失败: {e}"));
                s.last_error_code = -2;
            }
            return -2;
        }
    };

    let output_packets = if let Ok(s) = global_state().lock() {
        s.output_packets.clone()
    } else {
        return -1;
    };

    let writer = IosDeviceWriter {
        output_packets: output_packets.clone(),
    };

    let enable_ipv6_over_vnt = cfg.enable_ipv6_over_vnt;
    let (vnt, sender) = match build_vnt(cfg, writer) {
        Ok(v) => v,
        Err(e) => {
            if let Ok(mut s) = global_state().lock() {
                s.last_error = Some(format!("vnt 启动失败: {e}"));
                s.last_error_code = -3;
            }
            return -3;
        }
    };

    match global_state().lock() {
        Ok(mut state) => {
            state.running = true;
            state.packets_from_system = 0;
            state.packets_to_system = 0;
            state.output_dropped = 0;
            state.poll_error_count = 0;
            state.last_error = None;
            state.last_error_code = 0;
            state.ipv6_enabled = enable_ipv6_over_vnt;
            state.ipv6_map_miss_count = 0;
            state.ipv6_compat_downgrade_count = 0;
            state.assigned_virtual_ip = None;
            state.assigned_virtual_netmask = None;
            state.assigned_virtual_gateway = None;
            state.peer_virtual_ips.clear();
            state.sender = Some(sender);
            state.ipv6_to_virtual_ipv4.clear();
            for peer in vnt.device_list() {
                let vip = peer.virtual_ip;
                if let Some(nat) = vnt.peer_nat_info(&vip) {
                    if let Some(v6) = nat.ipv6() {
                        state.ipv6_to_virtual_ipv4.insert(v6, vip);
                    }
                }
            }
            state.peer_virtual_ips = vnt
                .device_list()
                .into_iter()
                .map(|peer| peer.virtual_ip)
                .collect::<Vec<_>>();
            state.peer_virtual_ips.sort_unstable();
            state.peer_virtual_ips.dedup();
            state.vnt = Some(vnt);
            if let Ok(mut q) = state.output_packets.lock() {
                q.clear();
            }
            0
        }
        Err(_) => -1,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn vnt_ios_dataplane_stop() -> i32 {
    match global_state().lock() {
        Ok(mut state) => {
            state.running = false;
            if let Some(vnt) = state.vnt.take() {
                vnt.stop();
            }
            state.sender = None;
            state.assigned_virtual_ip = None;
            state.assigned_virtual_netmask = None;
            state.assigned_virtual_gateway = None;
            state.peer_virtual_ips.clear();
            state.last_error_code = 0;
            if let Ok(mut q) = state.output_packets.lock() {
                q.clear();
            }
            0
        }
        Err(_) => -1,
    }
}

fn input_ipv4_packet(packet_ptr: *const u8, packet_len: usize) -> i32 {
    if packet_ptr.is_null() || packet_len < 20 {
        return -2;
    }

    let packet = unsafe { slice::from_raw_parts(packet_ptr, packet_len) };
    let version = packet[0] >> 4;
    if version != 4 {
        return -8;
    }
    let dest_ip = Ipv4Addr::new(packet[16], packet[17], packet[18], packet[19]);

    let sender = {
        match global_state().lock() {
            Ok(state) => {
                if !state.running {
                    return -3;
                }
                state.sender.clone()
            }
            Err(_) => return -1,
        }
    };

    let Some(sender) = sender else {
        return -4;
    };

    let mut packet_buf = vec![0u8; VNT_PACKET_BUFFER_PREFIX + packet_len + VNT_PACKET_BUFFER_SUFFIX];
    packet_buf[VNT_PACKET_BUFFER_PREFIX..VNT_PACKET_BUFFER_PREFIX + packet_len].copy_from_slice(packet);
    let data_len = VNT_PACKET_BUFFER_PREFIX + packet_len;
    let mut aux = vec![0u8; 65536];

    let send_ret = sender.send_ip(&mut packet_buf, data_len, &mut aux, dest_ip);
    match send_ret {
        Ok(_) => match global_state().lock() {
            Ok(mut state) => {
                state.packets_from_system = state.packets_from_system.saturating_add(1);
                0
            }
            Err(_) => -1,
        },
        Err(e) => {
            if let Ok(mut state) = global_state().lock() {
                state.last_error = Some(format!("send_ip 失败: {e}"));
                state.last_error_code = -5;
            }
            -5
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn vnt_ios_dataplane_input_ipv4(
    packet_ptr: *const u8,
    packet_len: usize,
    _protocol: i32,
) -> i32 {
    input_ipv4_packet(packet_ptr, packet_len)
}

#[unsafe(no_mangle)]
pub extern "C" fn vnt_ios_dataplane_input_ipv6(
    packet_ptr: *const u8,
    packet_len: usize,
    _protocol: i32,
) -> i32 {
    if packet_ptr.is_null() || packet_len < 40 {
        return -2;
    }

    let packet = unsafe { slice::from_raw_parts(packet_ptr, packet_len) };
    let version = packet[0] >> 4;
    if version != 6 {
        return -8;
    }

    let dest_v6 = Ipv6Addr::from([
        packet[24], packet[25], packet[26], packet[27],
        packet[28], packet[29], packet[30], packet[31],
        packet[32], packet[33], packet[34], packet[35],
        packet[36], packet[37], packet[38], packet[39],
    ]);

    let sender = match global_state().lock() {
        Ok(state) => {
            if !state.running {
                return -3;
            }
            if !state.ipv6_enabled {
                drop(state);
                if let Ok(mut s) = global_state().lock() {
                    s.ipv6_compat_downgrade_count = s.ipv6_compat_downgrade_count.saturating_add(1);
                }
                return 0;
            }
            state.sender.clone()
        }
        Err(_) => return -1,
    };

    let Some(sender) = sender else {
        return -4;
    };

    let mut dest_v4 = None;
    if let Ok(state) = global_state().lock() {
        dest_v4 = state.ipv6_to_virtual_ipv4.get(&dest_v6).copied();
    }

    if dest_v4.is_none() {
        let _ = vnt_ios_dataplane_refresh_ipv6_map();
        if let Ok(mut state) = global_state().lock() {
            dest_v4 = state.ipv6_to_virtual_ipv4.get(&dest_v6).copied();
            if dest_v4.is_none() {
                state.ipv6_map_miss_count = state.ipv6_map_miss_count.saturating_add(1);
                state.last_error_code = -10;
                state.last_error = Some(format!("ipv6 map miss: {dest_v6}"));
            }
        }
    }

    let Some(dest_v4) = dest_v4 else {
        return -10;
    };

    let mut packet_buf = vec![0u8; VNT_PACKET_BUFFER_PREFIX + packet_len + VNT_PACKET_BUFFER_SUFFIX];
    packet_buf[VNT_PACKET_BUFFER_PREFIX..VNT_PACKET_BUFFER_PREFIX + packet_len].copy_from_slice(packet);
    let data_len = VNT_PACKET_BUFFER_PREFIX + packet_len;
    let mut aux = vec![0u8; 65536];

    let send_ret = sender.send_ip_packet_by_virtual_ip(
        &mut packet_buf,
        data_len,
        &mut aux,
        dest_v4,
        vnt::protocol::ip_turn_packet::Protocol::Ipv6,
    );
    match send_ret {
        Ok(_) => match global_state().lock() {
            Ok(mut state) => {
                state.packets_from_system = state.packets_from_system.saturating_add(1);
                0
            }
            Err(_) => -1,
        },
        Err(e) => {
            if let Ok(mut state) = global_state().lock() {
                state.last_error = Some(format!("send_ip(ipv6) 失败: {e}"));
                state.last_error_code = -5;
            }
            -5
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn vnt_ios_dataplane_poll_output(
    out_packet_ptr: *mut u8,
    out_packet_capacity: usize,
    out_packet_len: *mut usize,
    out_protocol: *mut i32,
) -> i32 {
    if out_packet_ptr.is_null()
        || out_packet_len.is_null()
        || out_protocol.is_null()
        || out_packet_capacity == 0
    {
        if let Ok(mut s) = global_state().lock() {
            s.poll_error_count = s.poll_error_count.saturating_add(1);
            s.last_error_code = -2;
        }
        return -2;
    }

    let output_packets = match global_state().lock() {
        Ok(mut state) => {
            if !state.running {
                state.poll_error_count = state.poll_error_count.saturating_add(1);
                state.last_error_code = -3;
                return -3;
            }
            state.output_packets.clone()
        }
        Err(_) => return -1,
    };

    let mut q = match output_packets.lock() {
        Ok(v) => v,
        Err(_) => {
            if let Ok(mut s) = global_state().lock() {
                s.poll_error_count = s.poll_error_count.saturating_add(1);
                s.last_error_code = -1;
            }
            return -1;
        }
    };

    let Some((packet, protocol)) = q.pop_front() else {
        return 1;
    };

    if packet.len() > out_packet_capacity {
        q.push_front((packet, protocol));
        if let Ok(mut s) = global_state().lock() {
            s.poll_error_count = s.poll_error_count.saturating_add(1);
            s.last_error_code = -4;
        }
        return -4;
    }

    unsafe {
        ptr::copy_nonoverlapping(packet.as_ptr(), out_packet_ptr, packet.len());
        *out_packet_len = packet.len();
        *out_protocol = protocol;
    }

    0
}

#[unsafe(no_mangle)]
pub extern "C" fn vnt_ios_dataplane_output_count(count: u64) -> i32 {
    match global_state().lock() {
        Ok(mut state) => {
            if !state.running {
                return -3;
            }
            state.packets_to_system = state.packets_to_system.saturating_add(count);
            0
        }
        Err(_) => -1,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn vnt_ios_dataplane_refresh_ipv6_map() -> i32 {
    match global_state().lock() {
        Ok(mut state) => {
            let Some(vnt) = state.vnt.as_ref() else {
                state.last_error_code = -3;
                state.last_error = Some("vnt not running".to_string());
                return -3;
            };

            let mut next_map = std::collections::HashMap::new();
            for peer in vnt.device_list() {
                let vip = peer.virtual_ip;
                if let Some(nat) = vnt.peer_nat_info(&vip) {
                    if let Some(v6) = nat.ipv6() {
                        next_map.insert(v6, vip);
                    }
                }
            }
            state.ipv6_to_virtual_ipv4 = next_map;
            0
        }
        Err(_) => -1,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn vnt_ios_dataplane_snapshot_json(
    out_ptr: *mut *const c_char,
    out_len: *mut usize,
) -> i32 {
    if out_ptr.is_null() || out_len.is_null() {
        return -2;
    }

    let snapshot = match global_state().lock() {
        Ok(state) => {
            let peer_virtual_ips = state
                .peer_virtual_ips
                .iter()
                .map(|ip| ip.to_string())
                .collect::<Vec<_>>();
            let (current_virtual_ip, current_virtual_netmask, current_virtual_gateway, current_virtual_network, current_connect_server, current_status, current_broadcast_ip, nat_type, public_ips, local_ipv4, ipv6, peer_devices) =
                if let Some(vnt) = state.vnt.as_ref() {
                    let current = vnt.current_device();
                    let nat = vnt.nat_info();
                    let peers = vnt
                        .device_list()
                        .into_iter()
                        .map(|d| {
                            let route = vnt.route(&d.virtual_ip).map(|r| IosPeerRouteSnapshot {
                                protocol: format!("{:?}", r.protocol),
                                addr: r.addr.to_string(),
                                metric: r.metric,
                                rt: r.rt,
                            });
                            IosPeerSnapshot {
                                virtual_ip: d.virtual_ip.to_string(),
                                name: d.name,
                                status: format!("{:?}", d.status),
                                client_secret: d.client_secret,
                                route,
                            }
                        })
                        .collect::<Vec<_>>();
                    let assigned_ip = state
                        .assigned_virtual_ip
                        .map(|v| v.to_string())
                        .filter(|v| v != "0.0.0.0");
                    let assigned_netmask = state
                        .assigned_virtual_netmask
                        .map(|v| v.to_string())
                        .filter(|v| v != "0.0.0.0");
                    let assigned_gateway = state
                        .assigned_virtual_gateway
                        .map(|v| v.to_string())
                        .filter(|v| v != "0.0.0.0");

                    (
                        assigned_ip.or_else(|| Some(current.virtual_ip.to_string())),
                        assigned_netmask.or_else(|| Some(current.virtual_netmask.to_string())),
                        assigned_gateway.or_else(|| Some(current.virtual_gateway.to_string())),
                        Some(current.virtual_network.to_string()),
                        Some(current.connect_server.to_string()),
                        Some(format!("{:?}", current.status)),
                        Some(current.broadcast_ip.to_string()),
                        Some(format!("{:?}", nat.nat_type)),
                        Some(nat.public_ips.iter().map(|ip| ip.to_string()).collect::<Vec<_>>()),
                        nat.local_ipv4().map(|v| v.to_string()),
                        nat.ipv6().map(|v| v.to_string()),
                        peers,
                    )
                } else {
                    (None, None, None, None, None, None, None, None, None, None, None, Vec::new())
                };

            IosDataplaneSnapshot {
                running: state.running,
                current_virtual_ip,
                current_virtual_netmask,
                current_virtual_gateway,
                current_virtual_network,
                current_connect_server,
                current_status,
                current_broadcast_ip,
                nat_type,
                public_ips,
                local_ipv4,
                ipv6,
                peer_virtual_ips,
                peer_devices,
                last_error: state.last_error.clone(),
                last_error_code: state.last_error_code,
            }
        }
        Err(_) => return -1,
    };

    let json = match serde_json::to_string(&snapshot) {
        Ok(v) => v,
        Err(_) => return -3,
    };

    let len = json.len();
    let boxed = match std::ffi::CString::new(json) {
        Ok(v) => v,
        Err(_) => return -4,
    };

    unsafe {
        *out_len = len;
        *out_ptr = boxed.into_raw();
    }

    0
}

#[unsafe(no_mangle)]
pub extern "C" fn vnt_ios_dataplane_snapshot_json_free(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        let _ = std::ffi::CString::from_raw(ptr);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn vnt_ios_dataplane_get_stats(out_stats: *mut VntIosDataplaneStats) -> i32 {
    if out_stats.is_null() {
        return -2;
    }

    match global_state().lock() {
        Ok(state) => {
            let queue_len = state.output_packets.lock().map(|q| q.len() as u64).unwrap_or(0);
            let stats = VntIosDataplaneStats {
                running: if state.running { 1 } else { 0 },
                packets_from_system: state.packets_from_system,
                packets_to_system: state.packets_to_system,
                output_queue_len: queue_len,
                output_dropped: state.output_dropped,
                poll_error_count: state.poll_error_count,
                last_error_code: state.last_error_code,
                ipv6_enabled: if state.ipv6_enabled { 1 } else { 0 },
                ipv6_map_size: state.ipv6_to_virtual_ipv4.len() as u64,
                ipv6_map_miss_count: state.ipv6_map_miss_count,
                ipv6_compat_downgrade_count: state.ipv6_compat_downgrade_count,
            };

            unsafe {
                *out_stats = stats;
            }
            0
        }
        Err(_) => -1,
    }
}
