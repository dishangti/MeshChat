//! Upstream proxy support for Arti's guard and directory connections.

use std::io;
use std::net::{IpAddr, SocketAddr};

use async_trait::async_trait;
use base64::Engine as _;
use futures::io::{AsyncReadExt, AsyncWriteExt};
use tor_rtcompat::NetStreamProvider;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProxyKind {
    Socks5,
    HttpConnect,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProxyConfig {
    pub kind: ProxyKind,
    pub host: String,
    pub port: u16,
    pub username: Option<String>,
    pub password: Option<String>,
}

impl ProxyConfig {
    pub fn validate(&self) -> io::Result<()> {
        if self.host.trim().is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Proxy host is empty",
            ));
        }
        if self.username.is_some() != self.password.is_some() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Proxy username and password must be supplied together",
            ));
        }
        if self.kind == ProxyKind::Socks5 {
            if self
                .username
                .as_ref()
                .is_some_and(|value| value.len() > u8::MAX as usize)
                || self
                    .password
                    .as_ref()
                    .is_some_and(|value| value.len() > u8::MAX as usize)
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "SOCKS5 credentials exceed 255 bytes",
                ));
            }
        }
        Ok(())
    }
}

/// Replaces Arti's TCP connector while preserving its TLS, timing, and task runtime.
/// Every TCP connection to a Tor directory or relay is tunneled through the configured
/// outer proxy before Arti performs any Tor protocol work.
#[derive(Clone)]
pub struct ProxyTcpProvider<T> {
    inner: T,
    proxy_addresses: Vec<SocketAddr>,
    config: ProxyConfig,
}

impl<T> ProxyTcpProvider<T> {
    pub fn new(
        inner: T,
        proxy_addresses: Vec<SocketAddr>,
        config: ProxyConfig,
    ) -> io::Result<Self> {
        config.validate()?;
        if proxy_addresses.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::AddrNotAvailable,
                "Proxy host did not resolve to an address",
            ));
        }
        Ok(Self {
            inner,
            proxy_addresses,
            config,
        })
    }
}

#[async_trait]
impl<T> NetStreamProvider for ProxyTcpProvider<T>
where
    T: NetStreamProvider,
{
    type Stream = T::Stream;
    type Listener = T::Listener;

    async fn connect(&self, target: &SocketAddr) -> io::Result<Self::Stream> {
        let mut last_error = None;
        for proxy_address in &self.proxy_addresses {
            match self.inner.connect(proxy_address).await {
                Ok(mut stream) => {
                    let result = match self.config.kind {
                        ProxyKind::Socks5 => {
                            socks5_connect(&mut stream, target, &self.config).await
                        }
                        ProxyKind::HttpConnect => {
                            http_connect(&mut stream, target, &self.config).await
                        }
                    };
                    match result {
                        Ok(()) => return Ok(stream),
                        Err(error) => last_error = Some(error),
                    }
                }
                Err(error) => last_error = Some(error),
            }
        }
        Err(last_error.unwrap_or_else(|| {
            io::Error::new(
                io::ErrorKind::AddrNotAvailable,
                "No proxy address is available",
            )
        }))
    }

    async fn listen(&self, address: &SocketAddr) -> io::Result<Self::Listener> {
        self.inner.listen(address).await
    }
}

async fn socks5_connect<S>(
    stream: &mut S,
    target: &SocketAddr,
    config: &ProxyConfig,
) -> io::Result<()>
where
    S: futures::AsyncRead + futures::AsyncWrite + Unpin,
{
    let authenticated = config.username.is_some();
    // When credentials are configured, do not advertise no-authentication as
    // an alternative. Accepting a proxy-selected downgrade would silently
    // bypass the user's authentication policy.
    let methods: &[u8] = if authenticated { &[0x02] } else { &[0x00] };
    stream.write_all(&[0x05, methods.len() as u8]).await?;
    stream.write_all(methods).await?;
    stream.flush().await?;

    let mut selection = [0u8; 2];
    stream.read_exact(&mut selection).await?;
    if selection[0] != 0x05 {
        return Err(invalid_data("Invalid SOCKS5 proxy response"));
    }
    match selection[1] {
        0x00 if !authenticated => {}
        0x02 if authenticated => {
            let username = config.username.as_deref().unwrap_or_default().as_bytes();
            let password = config.password.as_deref().unwrap_or_default().as_bytes();
            let mut request = Vec::with_capacity(username.len() + password.len() + 3);
            request.extend_from_slice(&[0x01, username.len() as u8]);
            request.extend_from_slice(username);
            request.push(password.len() as u8);
            request.extend_from_slice(password);
            stream.write_all(&request).await?;
            stream.flush().await?;
            let mut response = [0u8; 2];
            stream.read_exact(&mut response).await?;
            if response != [0x01, 0x00] {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "SOCKS5 proxy authentication failed",
                ));
            }
        }
        0xff => {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "SOCKS5 proxy rejected all authentication methods",
            ));
        }
        _ => return Err(invalid_data("SOCKS5 proxy selected an unsupported method")),
    }

    let mut request = vec![0x05, 0x01, 0x00];
    match target.ip() {
        IpAddr::V4(address) => {
            request.push(0x01);
            request.extend_from_slice(&address.octets());
        }
        IpAddr::V6(address) => {
            request.push(0x04);
            request.extend_from_slice(&address.octets());
        }
    }
    request.extend_from_slice(&target.port().to_be_bytes());
    stream.write_all(&request).await?;
    stream.flush().await?;

    let mut header = [0u8; 4];
    stream.read_exact(&mut header).await?;
    if header[0] != 0x05 || header[2] != 0x00 {
        return Err(invalid_data("Invalid SOCKS5 CONNECT response"));
    }
    if header[1] != 0x00 {
        return Err(io::Error::new(
            io::ErrorKind::ConnectionRefused,
            format!("SOCKS5 proxy rejected CONNECT with status {}", header[1]),
        ));
    }
    consume_socks5_address(stream, header[3]).await
}

async fn consume_socks5_address<S>(stream: &mut S, address_type: u8) -> io::Result<()>
where
    S: futures::AsyncRead + Unpin,
{
    let address_length = match address_type {
        0x01 => 4,
        0x04 => 16,
        0x03 => {
            let mut length = [0u8; 1];
            stream.read_exact(&mut length).await?;
            length[0] as usize
        }
        _ => {
            return Err(invalid_data(
                "SOCKS5 proxy returned an unknown address type",
            ))
        }
    };
    let mut remainder = vec![0u8; address_length + 2];
    stream.read_exact(&mut remainder).await?;
    Ok(())
}

async fn http_connect<S>(
    stream: &mut S,
    target: &SocketAddr,
    config: &ProxyConfig,
) -> io::Result<()>
where
    S: futures::AsyncRead + futures::AsyncWrite + Unpin,
{
    let authority = match target.ip() {
        IpAddr::V4(_) => target.to_string(),
        IpAddr::V6(address) => format!("[{}]:{}", address, target.port()),
    };
    let mut request = format!(
        "CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\nProxy-Connection: Keep-Alive\r\n"
    );
    if let (Some(username), Some(password)) = (&config.username, &config.password) {
        let token =
            base64::engine::general_purpose::STANDARD.encode(format!("{username}:{password}"));
        request.push_str(&format!("Proxy-Authorization: Basic {token}\r\n"));
    }
    request.push_str("\r\n");
    stream.write_all(request.as_bytes()).await?;
    stream.flush().await?;

    let mut response = Vec::with_capacity(512);
    while response.len() < 16 * 1024 {
        let mut byte = [0u8; 1];
        stream.read_exact(&mut byte).await?;
        response.push(byte[0]);
        if response.ends_with(b"\r\n\r\n") {
            break;
        }
    }
    if !response.ends_with(b"\r\n\r\n") {
        return Err(invalid_data("HTTP proxy response headers are too large"));
    }
    let first_line = response
        .split(|byte| *byte == b'\n')
        .next()
        .and_then(|line| std::str::from_utf8(line).ok())
        .ok_or_else(|| invalid_data("HTTP proxy returned an invalid response"))?;
    let status = first_line
        .split_whitespace()
        .nth(1)
        .and_then(|value| value.parse::<u16>().ok())
        .ok_or_else(|| invalid_data("HTTP proxy returned an invalid status"))?;
    if !(200..300).contains(&status) {
        let kind = if status == 407 {
            io::ErrorKind::PermissionDenied
        } else {
            io::ErrorKind::ConnectionRefused
        };
        return Err(io::Error::new(
            kind,
            format!("HTTP proxy rejected CONNECT with status {status}"),
        ));
    }
    Ok(())
}

fn invalid_data(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_partial_credentials() {
        let config = ProxyConfig {
            kind: ProxyKind::HttpConnect,
            host: "127.0.0.1".into(),
            port: 8080,
            username: Some("user".into()),
            password: None,
        };
        assert!(config.validate().is_err());
    }

    #[test]
    fn rejects_oversized_socks_credentials() {
        let config = ProxyConfig {
            kind: ProxyKind::Socks5,
            host: "127.0.0.1".into(),
            port: 1080,
            username: Some("x".repeat(256)),
            password: Some("secret".into()),
        };
        assert!(config.validate().is_err());
    }
}
