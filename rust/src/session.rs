use std::borrow::Cow;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use russh::client::{self, Handle, Msg};
use russh::keys::{PrivateKeyWithHashAlg, PublicKey, PublicKeyOrCertificate};
use russh::{Channel, Disconnect, Preferred, cipher};
use tokio::net::TcpStream;
use tokio::sync::RwLock;
use tokio::time::timeout;

use crate::error::{Result, RusshError};
use crate::keys::PrivateKey;
use crate::runtime::run;

static CIPHERS: &[cipher::Name] = &[
    cipher::AES_128_GCM,
    cipher::AES_256_GCM,
    cipher::CHACHA20_POLY1305,
    cipher::AES_256_CTR,
    cipher::AES_192_CTR,
    cipher::AES_128_CTR,
];

const KEEPALIVE_MAX: usize = 3;

#[derive(Debug, Clone, uniffi::Record)]
pub struct HostKey {
    pub key_type: String,
    pub blob: Vec<u8>,
}

impl HostKey {
    fn from(key: &PublicKey) -> Option<Self> {
        Some(Self { key_type: key.algorithm().as_str().to_owned(), blob: key.to_bytes().ok()? })
    }
}

pub(crate) struct ClientHandler {
    host_key: Arc<Mutex<Option<HostKey>>>,
}

impl client::Handler for ClientHandler {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        key: &PublicKeyOrCertificate,
    ) -> std::result::Result<bool, Self::Error> {
        let key = match key {
            PublicKeyOrCertificate::PublicKey { key, .. } => HostKey::from(key),
            PublicKeyOrCertificate::Certificate(certificate) => {
                HostKey::from(&PublicKey::from(certificate.public_key().clone()))
            }
        };
        *self.host_key.lock().unwrap() = key;
        Ok(true)
    }
}

pub(crate) struct SessionInner {
    handle: RwLock<Option<Handle<ClientHandler>>>,
    closed: AtomicBool,
    host_key: Arc<Mutex<Option<HostKey>>>,
    pub(crate) timeout: Duration,
}

impl SessionInner {
    pub(crate) fn check_open(&self) -> Result<()> {
        if self.closed.load(Ordering::Acquire) {
            return Err(RusshError::closed("SSH session is closed"));
        }
        Ok(())
    }

    pub(crate) async fn open_channel(&self) -> Result<Channel<Msg>> {
        self.check_open()?;
        let guard = self.handle.read().await;
        let handle = guard.as_ref().ok_or_else(|| RusshError::closed("SSH session is closed"))?;
        if handle.is_closed() {
            return Err(RusshError::connection_failed("Connection lost"));
        }
        Ok(handle.channel_open_session().await?)
    }

    async fn is_connected(&self) -> bool {
        if self.closed.load(Ordering::Acquire) {
            return false;
        }
        self.handle.read().await.as_ref().is_some_and(|handle| !handle.is_closed())
    }

    async fn close(&self) {
        self.closed.store(true, Ordering::Release);
        let handle = self.handle.write().await.take();
        if let Some(handle) = handle {
            let _ = handle.disconnect(Disconnect::ByApplication, "", "en").await;
        }
    }

    async fn authenticate(&self, auth: Auth) -> Result<()> {
        self.check_open()?;
        let mut guard = self.handle.write().await;
        let handle = guard.as_mut().ok_or_else(|| RusshError::closed("SSH session is closed"))?;
        let result = match auth {
            Auth::None { user } => handle.authenticate_none(user).await?,
            Auth::Password { user, password } => {
                handle.authenticate_password(user, password).await?
            }
            Auth::PublicKey { user, key } => {
                let hash = handle.best_supported_rsa_hash().await?.flatten();
                handle.authenticate_publickey(user, PrivateKeyWithHashAlg::new(key, hash)).await?
            }
        };
        if !result.success() {
            return Err(RusshError::AuthenticationFailed {
                message: "Access denied: authentication failed".into(),
            });
        }
        Ok(())
    }
}

enum Auth {
    None { user: String },
    Password { user: String, password: String },
    PublicKey { user: String, key: Arc<russh::keys::PrivateKey> },
}

#[derive(uniffi::Object)]
pub struct Session {
    pub(crate) inner: Arc<SessionInner>,
}

#[uniffi::export]
pub async fn connect(host: String, port: u16, timeout_secs: u64) -> Result<Arc<Session>> {
    run(async move {
        let timeout_duration = Duration::from_secs(timeout_secs.max(1));
        let stream = connect_tcp(&host, port, timeout_duration).await?;
        let host_key = Arc::new(Mutex::new(None));
        let handler = ClientHandler { host_key: host_key.clone() };
        let handle = timeout(
            timeout_duration,
            client::connect_stream(Arc::new(config(timeout_duration)), stream, handler),
        )
        .await
        .map_err(|_| RusshError::connection_failed(format!("Timed out connecting to {host}")))??;
        Ok(Arc::new(Session {
            inner: Arc::new(SessionInner {
                handle: RwLock::new(Some(handle)),
                closed: AtomicBool::new(false),
                host_key,
                timeout: timeout_duration,
            }),
        }))
    })
    .await
}

fn config(timeout: Duration) -> client::Config {
    let keepalive = (timeout / (KEEPALIVE_MAX as u32 + 1)).max(Duration::from_secs(1));
    client::Config {
        preferred: Preferred { cipher: Cow::Borrowed(CIPHERS), ..Default::default() },
        keepalive_interval: Some(keepalive),
        keepalive_max: KEEPALIVE_MAX,
        nodelay: true,
        ..Default::default()
    }
}

async fn connect_tcp(host: &str, port: u16, timeout_duration: Duration) -> Result<TcpStream> {
    let addresses = timeout(timeout_duration, tokio::net::lookup_host((host, port)))
        .await
        .map_err(|_| RusshError::connection_failed(format!("Timed out resolving {host}")))?
        .map_err(|error| {
            RusshError::connection_failed(format!("Failed to resolve hostname {host}: {error}"))
        })?;

    let mut last_error = format!("No addresses found for {host}");
    for address in addresses {
        match timeout(timeout_duration, TcpStream::connect(address)).await {
            Ok(Ok(stream)) => return Ok(stream),
            Ok(Err(error)) => last_error = format!("Failed to connect to {address}: {error}"),
            Err(_) => last_error = format!("Timed out connecting to {address}"),
        }
    }
    Err(RusshError::connection_failed(last_error))
}

#[uniffi::export]
impl Session {
    pub fn host_key(&self) -> Result<HostKey> {
        self.inner.check_open()?;
        self.inner
            .host_key
            .lock()
            .unwrap()
            .clone()
            .ok_or_else(|| RusshError::invalid_state("Server did not provide a host key"))
    }

    pub async fn is_connected(&self) -> bool {
        let inner = self.inner.clone();
        run(async move { inner.is_connected().await }).await
    }

    pub async fn close(&self) {
        let inner = self.inner.clone();
        run(async move { inner.close().await }).await
    }

    pub async fn authenticate_none(&self, user: String) -> Result<()> {
        let inner = self.inner.clone();
        run(async move { inner.authenticate(Auth::None { user }).await }).await
    }

    pub async fn authenticate_password(&self, user: String, password: String) -> Result<()> {
        let inner = self.inner.clone();
        run(async move { inner.authenticate(Auth::Password { user, password }).await }).await
    }

    pub async fn authenticate_key(&self, user: String, key: Arc<PrivateKey>) -> Result<()> {
        let inner = self.inner.clone();
        let key = key.key.clone();
        run(async move { inner.authenticate(Auth::PublicKey { user, key }).await }).await
    }
}
