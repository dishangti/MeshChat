//! arti-bitchat: Minimal FFI wrapper around arti-client for BitChat
//!
//! Provides a C-compatible interface for embedding Arti (Rust Tor) in iOS/macOS apps.
//! Exposes a SOCKS5 proxy on localhost that Swift code can route traffic through.

use std::ffi::{c_char, c_int, CStr};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use arti_client::TorClient;
use once_cell::sync::OnceCell;
use tokio::net::TcpListener;
use tokio::runtime::Runtime as TokioRuntime;
use tokio::sync::oneshot;
use tor_rtcompat::{PreferredRuntime, RuntimeSubstExt as _};

mod proxy;
mod socks;

use proxy::{ProxyConfig, ProxyKind, ProxyTcpProvider};

/// Global state for the Arti instance
struct ArtiState {
    /// Tokio runtime (owned, single instance)
    runtime: TokioRuntime,
    /// Shutdown signal sender
    shutdown_tx: Option<oneshot::Sender<()>>,
}

static ARTI_STATE: OnceCell<Mutex<ArtiState>> = OnceCell::new();
static BOOTSTRAP_PROGRESS: AtomicI32 = AtomicI32::new(0);
static IS_RUNNING: AtomicBool = AtomicBool::new(false);
/// Identifies the task that currently owns the exported running/progress
/// state. A delayed completion from a stopped task must not overwrite a newer
/// start attempt.
static RUN_GENERATION: AtomicU64 = AtomicU64::new(0);
static BOOTSTRAP_SUMMARY: Mutex<String> = Mutex::new(String::new());

/// Initialize the global state with a new runtime
fn init_state() -> Result<(), &'static str> {
    ARTI_STATE.get_or_try_init(|| -> Result<Mutex<ArtiState>, &'static str> {
        let runtime = TokioRuntime::new().map_err(|_| "Failed to create tokio runtime")?;
        Ok(Mutex::new(ArtiState {
            runtime,
            shutdown_tx: None,
        }))
    })?;
    Ok(())
}

/// Start Arti with a SOCKS5 proxy.
///
/// # Arguments
/// * `data_dir` - Path to data directory for Tor state (C string)
/// * `socks_port` - Port for SOCKS5 proxy (e.g., 39050)
///
/// # Returns
/// * 0 on success
/// * -1 if already running
/// * -2 if data_dir is invalid
/// * -3 if runtime initialization failed
/// * -4 if bootstrap failed
#[no_mangle]
pub extern "C" fn arti_start(data_dir: *const c_char, socks_port: u16) -> c_int {
    start_arti(data_dir, socks_port, None)
}

/// Start Arti and route all of its outbound TCP connections through an outer proxy.
///
/// `proxy_kind` is 1 for SOCKS5 and 2 for HTTP CONNECT. Credentials must either both
/// be null or both contain valid UTF-8 strings.
#[no_mangle]
pub extern "C" fn arti_start_with_proxy(
    data_dir: *const c_char,
    socks_port: u16,
    proxy_kind: u8,
    proxy_host: *const c_char,
    proxy_port: u16,
    username: *const c_char,
    password: *const c_char,
) -> c_int {
    let kind = match proxy_kind {
        1 => ProxyKind::Socks5,
        2 => ProxyKind::HttpConnect,
        _ => return -5,
    };
    let host = match c_string(proxy_host) {
        Ok(Some(value)) if !value.trim().is_empty() => value,
        _ => return -5,
    };
    let username = match c_string(username) {
        Ok(value) => value,
        Err(()) => return -5,
    };
    let password = match c_string(password) {
        Ok(value) => value,
        Err(()) => return -5,
    };
    let proxy = ProxyConfig {
        kind,
        host,
        port: proxy_port,
        username,
        password,
    };
    if proxy.validate().is_err() {
        return -5;
    }
    start_arti(data_dir, socks_port, Some(proxy))
}

fn c_string(pointer: *const c_char) -> Result<Option<String>, ()> {
    if pointer.is_null() {
        return Ok(None);
    }
    unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map(|value| Some(value.to_owned()))
        .map_err(|_| ())
}

fn start_arti(data_dir: *const c_char, socks_port: u16, proxy: Option<ProxyConfig>) -> c_int {
    // Check if already running
    if IS_RUNNING.load(Ordering::SeqCst) {
        return -1;
    }

    // Parse data directory
    let data_path = match c_string(data_dir) {
        Ok(Some(value)) => PathBuf::from(value),
        _ => return -2,
    };

    // Initialize runtime if needed
    if let Err(_) = init_state() {
        return -3;
    }

    let state = match ARTI_STATE.get() {
        Some(s) => s,
        None => return -3,
    };

    let mut guard = match state.lock() {
        Ok(g) => g,
        Err(_) => return -3,
    };

    // Create shutdown channel
    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    guard.shutdown_tx = Some(shutdown_tx);

    let socks_addr: SocketAddr = format!("127.0.0.1:{}", socks_port)
        .parse()
        .expect("valid addr");

    // Publish running before spawning. The task can fail immediately (for
    // example on corrupt state or an unavailable proxy); publishing after
    // spawn lets that failure write `false` and then be overwritten with
    // `true`, leaving callers stuck with a ghost process and no SOCKS listener.
    let generation = RUN_GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    IS_RUNNING.store(true, Ordering::SeqCst);
    BOOTSTRAP_PROGRESS.store(0, Ordering::SeqCst);
    update_summary("Starting...");

    // Spawn the main Arti task.
    let data_path_clone = data_path.clone();
    guard.runtime.spawn(async move {
        match run_arti(data_path_clone, socks_addr, proxy, shutdown_rx).await {
            Ok(_) => {
                tracing::info!("Arti shutdown cleanly");
            }
            Err(e) => {
                tracing::error!("Arti error: {}", e);
                update_summary(&format!("Error: {}", e));
            }
        }
        if RUN_GENERATION.load(Ordering::SeqCst) == generation {
            IS_RUNNING.store(false, Ordering::SeqCst);
            BOOTSTRAP_PROGRESS.store(0, Ordering::SeqCst);
        }
    });

    0
}

/// Stop Arti gracefully.
///
/// # Returns
/// * 0 on success
/// * -1 if not running
#[no_mangle]
pub extern "C" fn arti_stop() -> c_int {
    if !IS_RUNNING.load(Ordering::SeqCst) {
        return -1;
    }

    let state = match ARTI_STATE.get() {
        Some(s) => s,
        None => return -1,
    };

    let mut guard = match state.lock() {
        Ok(g) => g,
        Err(_) => return -1,
    };

    // Send shutdown signal
    if let Some(tx) = guard.shutdown_tx.take() {
        let _ = tx.send(());
    }

    // Give async tasks time to complete
    std::thread::sleep(std::time::Duration::from_millis(200));

    IS_RUNNING.store(false, Ordering::SeqCst);
    BOOTSTRAP_PROGRESS.store(0, Ordering::SeqCst);
    update_summary("");

    0
}

/// Check if Arti is currently running.
///
/// # Returns
/// * 1 if running
/// * 0 if not running
#[no_mangle]
pub extern "C" fn arti_is_running() -> c_int {
    if IS_RUNNING.load(Ordering::SeqCst) {
        1
    } else {
        0
    }
}

/// Get the current bootstrap progress (0-100).
#[no_mangle]
pub extern "C" fn arti_bootstrap_progress() -> c_int {
    BOOTSTRAP_PROGRESS.load(Ordering::SeqCst)
}

/// Get the current bootstrap summary string.
///
/// # Arguments
/// * `buf` - Buffer to write the summary into
/// * `len` - Length of the buffer
///
/// # Returns
/// * Number of bytes written (not including null terminator)
/// * -1 if buffer is null or too small
#[no_mangle]
pub extern "C" fn arti_bootstrap_summary(buf: *mut c_char, len: c_int) -> c_int {
    if buf.is_null() || len <= 0 {
        return -1;
    }

    let summary = match BOOTSTRAP_SUMMARY.lock() {
        Ok(s) => s.clone(),
        Err(_) => return -1,
    };

    let bytes = summary.as_bytes();
    let copy_len = std::cmp::min(bytes.len(), (len - 1) as usize);

    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf as *mut u8, copy_len);
        *buf.add(copy_len) = 0; // null terminator
    }

    copy_len as c_int
}

/// Signal Arti to go dormant (reduce resource usage).
/// This is a hint; Arti may not fully support dormant mode yet.
///
/// # Returns
/// * 0 on success
/// * -1 if not running
#[no_mangle]
pub extern "C" fn arti_go_dormant() -> c_int {
    if !IS_RUNNING.load(Ordering::SeqCst) {
        return -1;
    }
    // Arti doesn't have explicit dormant mode yet, but we can note the intent
    update_summary("Dormant");
    0
}

/// Signal Arti to wake from dormant mode.
///
/// # Returns
/// * 0 on success
/// * -1 if not running
#[no_mangle]
pub extern "C" fn arti_wake() -> c_int {
    if !IS_RUNNING.load(Ordering::SeqCst) {
        return -1;
    }
    update_summary("Active");
    0
}

fn update_summary(s: &str) {
    if let Ok(mut guard) = BOOTSTRAP_SUMMARY.lock() {
        guard.clear();
        guard.push_str(s);
    }
}

/// Main async entry point for Arti
async fn run_arti(
    data_dir: PathBuf,
    socks_addr: SocketAddr,
    proxy: Option<ProxyConfig>,
    mut shutdown_rx: oneshot::Receiver<()>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // Ensure data directory exists
    std::fs::create_dir_all(&data_dir)?;

    update_summary("Configuring...");

    // Build Arti configuration with custom directories
    let cache_dir = data_dir.join("cache");
    let state_dir = data_dir.join("state");

    // Use from_directories which sets up storage correctly
    use arti_client::config::TorClientConfigBuilder;
    let config = TorClientConfigBuilder::from_directories(state_dir, cache_dir).build()?;

    update_summary("Bootstrapping...");

    let runtime = PreferredRuntime::current()?;
    if let Some(proxy) = proxy {
        let proxy_addresses: Vec<SocketAddr> =
            tokio::net::lookup_host((proxy.host.as_str(), proxy.port))
                .await?
                .collect();
        let provider = ProxyTcpProvider::new(runtime.clone(), proxy_addresses, proxy)?;
        let runtime = runtime.with_tcp_provider(provider);
        let client_builder = TorClient::with_runtime(runtime).config(config);
        let bootstrap = client_builder.create_bootstrapped();
        let client = tokio::select! {
            result = bootstrap => result?,
            _ = &mut shutdown_rx => {
                update_summary("Shutting down...");
                return Ok(());
            }
        };
        serve_socks(Arc::new(client), socks_addr, &mut shutdown_rx).await
    } else {
        let client_builder = TorClient::with_runtime(runtime).config(config);
        let bootstrap = client_builder.create_bootstrapped();
        let client = tokio::select! {
            result = bootstrap => result?,
            _ = &mut shutdown_rx => {
                update_summary("Shutting down...");
                return Ok(());
            }
        };
        serve_socks(Arc::new(client), socks_addr, &mut shutdown_rx).await
    }
}

async fn serve_socks<R>(
    client: Arc<TorClient<R>>,
    socks_addr: SocketAddr,
    shutdown_rx: &mut oneshot::Receiver<()>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>>
where
    R: tor_rtcompat::Runtime,
{
    // Bind SOCKS listener
    let listener = TcpListener::bind(socks_addr).await?;
    tracing::info!("SOCKS5 proxy listening on {}", socks_addr);

    // Do not publish readiness until the endpoint actually accepts sockets.
    BOOTSTRAP_PROGRESS.store(100, Ordering::SeqCst);
    update_summary("Ready");

    // Accept connections until shutdown
    loop {
        tokio::select! {
            accept_result = listener.accept() => {
                match accept_result {
                    Ok((stream, peer_addr)) => {
                        let client = client.clone();
                        tokio::spawn(async move {
                            if let Err(e) = socks::handle_socks_connection(stream, peer_addr, client).await {
                                tracing::debug!("SOCKS connection error from {}: {}", peer_addr, e);
                            }
                        });
                    }
                    Err(e) => {
                        tracing::warn!("Accept error: {}", e);
                    }
                }
            }
            _ = &mut *shutdown_rx => {
                tracing::info!("Shutdown signal received");
                break;
            }
        }
    }

    update_summary("Shutting down...");
    Ok(())
}
