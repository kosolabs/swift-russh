use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use russh_sftp::client::error::Error as SftpClientError;
use russh_sftp::client::rawsession::Limits;
use russh_sftp::client::{Config, RawSftpSession};
use russh_sftp::protocol::{FileAttributes, OpenFlags, Packet, StatusCode};
use tokio::sync::oneshot;

use crate::error::{Result, RusshError};
use crate::runtime::{run, spawn};
use crate::session::{Session, SessionInner};

const POSIX_RENAME: &str = "posix-rename@openssh.com";
const LSETSTAT: &str = "lsetstat@openssh.com";
const LIMITS: &str = "limits@openssh.com";

const FX_FILE_ALREADY_EXISTS: u32 = 11;

const ATTR_SIZE: u32 = 0x1;
const ATTR_UIDGID: u32 = 0x2;
const ATTR_PERMISSIONS: u32 = 0x4;
const ATTR_ACMODTIME: u32 = 0x8;

#[derive(Debug, Clone, uniffi::Record)]
pub struct SftpLimits {
    pub max_open_handles: u64,
    pub max_packet_length: u64,
    pub max_read_length: u64,
    pub max_write_length: u64,
}

impl Default for SftpLimits {
    fn default() -> Self {
        Self { max_open_handles: 0, max_packet_length: 34000, max_read_length: 32768, max_write_length: 32768 }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Attributes {
    pub name: Option<String>,
    pub longname: Option<String>,
    pub size: Option<u64>,
    pub uid: Option<u32>,
    pub gid: Option<u32>,
    pub permissions: Option<u32>,
    pub access_time: Option<u32>,
    pub modify_time: Option<u32>,
}

impl Attributes {
    fn from(attrs: &FileAttributes, name: Option<String>, longname: Option<String>) -> Self {
        Self {
            name,
            longname,
            size: attrs.size,
            uid: attrs.uid,
            gid: attrs.gid,
            permissions: attrs.permissions,
            access_time: attrs.atime,
            modify_time: attrs.mtime,
        }
    }
}

#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct AttributeChanges {
    pub size: Option<u64>,
    pub uid: Option<u32>,
    pub gid: Option<u32>,
    pub permissions: Option<u32>,
    pub access_time: Option<u32>,
    pub modify_time: Option<u32>,
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum AccessMode {
    ReadOnly,
    WriteOnly,
    ReadWrite,
}

impl AccessMode {
    fn flags(self) -> OpenFlags {
        match self {
            Self::ReadOnly => OpenFlags::READ,
            Self::WriteOnly => OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::TRUNCATE,
            Self::ReadWrite => {
                OpenFlags::READ | OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::TRUNCATE
            }
        }
    }
}

pub(crate) struct SftpInner {
    session: Arc<SessionInner>,
    raw: RawSftpSession,
    closed: AtomicBool,
    limits: SftpLimits,
    posix_rename: bool,
    lsetstat: bool,
}

impl SftpInner {
    fn check_open(&self) -> Result<()> {
        self.session.check_open()?;
        if self.closed.load(Ordering::Acquire) {
            return Err(RusshError::closed("SFTP session is closed"));
        }
        Ok(())
    }

    async fn stat(&self, path: String, follow_symlinks: bool) -> Result<FileAttributes> {
        self.check_open()?;
        let attrs = if follow_symlinks {
            self.raw.stat(path).await?
        } else {
            self.raw.lstat(path).await?
        };
        Ok(attrs.attrs)
    }

    async fn extended(&self, request: &str, data: Vec<u8>) -> Result<()> {
        match self.raw.extended(request, data).await? {
            Packet::Status(status) if status.status_code == StatusCode::Ok => Ok(()),
            Packet::Status(status) => Err(status.into()),
            _ => Err(RusshError::invalid_state(format!("Unexpected reply to {request}"))),
        }
    }

    async fn set_attributes(
        &self,
        path: String,
        follow_symlinks: bool,
        changes: AttributeChanges,
    ) -> Result<()> {
        let current = self.stat(path.clone(), follow_symlinks).await?;
        let mut attrs = FileAttributes::empty();
        attrs.size = changes.size;
        if changes.uid.is_some() || changes.gid.is_some() {
            attrs.uid = changes.uid.or(current.uid);
            attrs.gid = changes.gid.or(current.gid);
        }
        attrs.permissions = changes.permissions;
        if changes.access_time.is_some() || changes.modify_time.is_some() {
            attrs.atime = changes.access_time.or(current.atime);
            attrs.mtime = changes.modify_time.or(current.mtime);
        }

        if follow_symlinks {
            self.raw.setstat(path, attrs).await?;
            return Ok(());
        }
        if !self.lsetstat {
            return Err(RusshError::sftp(StatusCode::OpUnsupported, "Server does not support lsetstat"));
        }
        let mut data = encode_string(&path);
        data.extend(encode_attributes(&attrs));
        self.extended(LSETSTAT, data).await
    }

    async fn rename(&self, from: String, to: String) -> Result<()> {
        self.check_open()?;
        if self.posix_rename {
            let mut data = encode_string(&from);
            data.extend(encode_string(&to));
            return self.extended(POSIX_RENAME, data).await;
        }
        self.raw.rename(from, to).await?;
        Ok(())
    }

    async fn mkdir(&self, path: String, mode: u32) -> Result<()> {
        self.check_open()?;
        let mut attrs = FileAttributes::empty();
        attrs.permissions = Some(mode);
        match self.raw.mkdir(path.clone(), attrs).await {
            Ok(_) => Ok(()),
            Err(error) => Err(self.already_exists_if_present(error.into(), path).await),
        }
    }

    async fn already_exists_if_present(&self, error: RusshError, path: String) -> RusshError {
        if error.sftp_code() == Some(StatusCode::Failure as u32) && self.raw.lstat(path).await.is_ok() {
            return RusshError::Sftp { code: FX_FILE_ALREADY_EXISTS, message: error.to_string() };
        }
        error
    }

    async fn symlink(&self, target: String, dest: String) -> Result<()> {
        self.check_open()?;
        // OpenSSH's sftp-server reads the two SSH_FXP_SYMLINK paths in the reverse of
        // the order the draft specifies: target first, then the link.
        match self.raw.symlink(target, dest.clone()).await {
            Ok(_) => Ok(()),
            Err(error) => Err(self.already_exists_if_present(error.into(), dest).await),
        }
    }
}

fn encode_string(value: &str) -> Vec<u8> {
    let mut data = (value.len() as u32).to_be_bytes().to_vec();
    data.extend_from_slice(value.as_bytes());
    data
}

fn encode_attributes(attrs: &FileAttributes) -> Vec<u8> {
    let mut flags = 0;
    let mut data = Vec::new();
    if let Some(size) = attrs.size {
        flags |= ATTR_SIZE;
        data.extend(size.to_be_bytes());
    }
    if attrs.uid.is_some() || attrs.gid.is_some() {
        flags |= ATTR_UIDGID;
        data.extend(attrs.uid.unwrap_or(0).to_be_bytes());
        data.extend(attrs.gid.unwrap_or(0).to_be_bytes());
    }
    if let Some(permissions) = attrs.permissions {
        flags |= ATTR_PERMISSIONS;
        data.extend(permissions.to_be_bytes());
    }
    if attrs.atime.is_some() || attrs.mtime.is_some() {
        flags |= ATTR_ACMODTIME;
        data.extend(attrs.atime.unwrap_or(0).to_be_bytes());
        data.extend(attrs.mtime.unwrap_or(0).to_be_bytes());
    }
    let mut encoded = flags.to_be_bytes().to_vec();
    encoded.extend(data);
    encoded
}

#[derive(uniffi::Object)]
pub struct Sftp {
    inner: Arc<SftpInner>,
}

#[uniffi::export]
impl Session {
    pub async fn sftp(&self) -> Result<Arc<Sftp>> {
        let session = self.inner.clone();
        run(async move {
            let channel = session.open_channel().await?;
            channel.request_subsystem(true, "sftp").await?;
            let config = Config { request_timeout_secs: session.timeout.as_secs(), ..Config::default() };
            let mut raw = RawSftpSession::new_with_config(channel.into_stream(), config);
            let version = raw.init().await?;
            let limits = if version.extensions.contains_key(LIMITS) {
                let limits = raw.limits().await?;
                SftpLimits {
                    max_open_handles: limits.max_open_handles,
                    max_packet_length: limits.max_packet_len,
                    max_read_length: limits.max_read_len,
                    max_write_length: limits.max_write_len,
                }
            } else {
                SftpLimits::default()
            };
            raw.set_limits(Limits {
                packet_len: Some(limits.max_packet_length),
                read_len: Some(limits.max_read_length),
                write_len: Some(limits.max_write_length),
                open_handles: (limits.max_open_handles > 0).then_some(limits.max_open_handles),
            });
            Ok(Arc::new(Sftp {
                inner: Arc::new(SftpInner {
                    session,
                    raw,
                    closed: AtomicBool::new(false),
                    limits,
                    posix_rename: version.extensions.contains_key(POSIX_RENAME),
                    lsetstat: version.extensions.contains_key(LSETSTAT),
                }),
            }))
        })
        .await
    }
}

#[uniffi::export]
impl Sftp {
    pub fn limits(&self) -> SftpLimits {
        self.inner.limits.clone()
    }

    pub async fn close(&self) {
        if !self.inner.closed.swap(true, Ordering::AcqRel) {
            let _ = self.inner.raw.close_session();
        }
    }

    pub async fn mkdir(&self, path: String, mode: u32) -> Result<()> {
        let inner = self.inner.clone();
        run(async move { inner.mkdir(path, mode).await }).await
    }

    pub async fn rmdir(&self, path: String) -> Result<()> {
        let inner = self.inner.clone();
        run(async move {
            inner.check_open()?;
            inner.raw.rmdir(path).await?;
            Ok(())
        })
        .await
    }

    pub async fn remove(&self, path: String) -> Result<()> {
        let inner = self.inner.clone();
        run(async move {
            inner.check_open()?;
            inner.raw.remove(path).await?;
            Ok(())
        })
        .await
    }

    pub async fn stat(&self, path: String, follow_symlinks: bool) -> Result<Attributes> {
        let inner = self.inner.clone();
        run(async move {
            let attrs = inner.stat(path, follow_symlinks).await?;
            Ok(Attributes::from(&attrs, None, None))
        })
        .await
    }

    pub async fn set_attributes(
        &self,
        path: String,
        follow_symlinks: bool,
        changes: AttributeChanges,
    ) -> Result<()> {
        let inner = self.inner.clone();
        run(async move { inner.set_attributes(path, follow_symlinks, changes).await }).await
    }

    pub async fn rename(&self, from: String, to: String) -> Result<()> {
        let inner = self.inner.clone();
        run(async move { inner.rename(from, to).await }).await
    }

    pub async fn readlink(&self, path: String) -> Result<String> {
        let inner = self.inner.clone();
        run(async move {
            inner.check_open()?;
            let name = inner.raw.readlink(path).await?;
            name.files
                .into_iter()
                .next()
                .map(|file| file.filename)
                .ok_or_else(|| RusshError::invalid_state("Server returned no link target"))
        })
        .await
    }

    pub async fn symlink(&self, target: String, dest: String) -> Result<()> {
        let inner = self.inner.clone();
        run(async move { inner.symlink(target, dest).await }).await
    }

    pub async fn open(&self, path: String, access: AccessMode, mode: u32) -> Result<Arc<File>> {
        let inner = self.inner.clone();
        run(async move {
            inner.check_open()?;
            let mut attrs = FileAttributes::empty();
            attrs.permissions = Some(mode);
            let handle = inner.raw.open(path, access.flags(), attrs).await?.handle;
            Ok(Arc::new(File {
                inner: Arc::new(FileInner {
                    sftp: inner,
                    handle,
                    closed: AtomicBool::new(false),
                    position: Mutex::new(0),
                }),
            }))
        })
        .await
    }

    pub async fn open_dir(&self, path: String) -> Result<Arc<Directory>> {
        let inner = self.inner.clone();
        run(async move {
            inner.check_open()?;
            let handle = inner.raw.opendir(path).await?.handle;
            Ok(Arc::new(Directory {
                inner: Arc::new(DirectoryInner {
                    sftp: inner,
                    handle,
                    closed: AtomicBool::new(false),
                    eof: AtomicBool::new(false),
                }),
            }))
        })
        .await
    }
}

// MARK: - Files

struct FileInner {
    sftp: Arc<SftpInner>,
    handle: String,
    closed: AtomicBool,
    position: Mutex<u64>,
}

impl FileInner {
    fn check_open(&self) -> Result<()> {
        self.sftp.check_open()?;
        if self.closed.load(Ordering::Acquire) {
            return Err(RusshError::closed("SFTP file is closed"));
        }
        Ok(())
    }

    fn reserve(&self, length: u64) -> u64 {
        let mut position = self.position.lock().unwrap();
        let offset = *position;
        *position += length;
        offset
    }

    async fn read_at(&self, offset: u64, length: u32) -> Result<Vec<u8>> {
        self.check_open()?;
        match self.sftp.raw.read(self.handle.as_str(), offset, length).await {
            Ok(data) => Ok(data.data),
            Err(SftpClientError::Status(status)) if status.status_code == StatusCode::Eof => {
                Ok(Vec::new())
            }
            Err(error) => Err(error.into()),
        }
    }

    async fn write_at(&self, offset: u64, data: Vec<u8>) -> Result<()> {
        self.check_open()?;
        self.sftp.raw.write(self.handle.as_str(), offset, data).await?;
        Ok(())
    }
}

#[derive(uniffi::Object)]
pub struct File {
    inner: Arc<FileInner>,
}

#[uniffi::export]
impl File {
    pub async fn close(&self) {
        let inner = self.inner.clone();
        if inner.closed.swap(true, Ordering::AcqRel) || inner.sftp.check_open().is_err() {
            return;
        }
        run(async move {
            let _ = inner.sftp.raw.close(inner.handle.as_str()).await;
        })
        .await
    }

    pub async fn stat(&self) -> Result<Attributes> {
        let inner = self.inner.clone();
        run(async move {
            inner.check_open()?;
            let attrs = inner.sftp.raw.fstat(inner.handle.as_str()).await?.attrs;
            Ok(Attributes::from(&attrs, None, None))
        })
        .await
    }

    pub fn seek(&self, offset: u64) -> Result<()> {
        self.inner.check_open()?;
        *self.inner.position.lock().unwrap() = offset;
        Ok(())
    }

    pub async fn read(&self, length: u32) -> Result<Vec<u8>> {
        let inner = self.inner.clone();
        run(async move {
            let offset = *inner.position.lock().unwrap();
            let data = inner.read_at(offset, length).await?;
            *inner.position.lock().unwrap() = offset + data.len() as u64;
            Ok(data)
        })
        .await
    }

    pub async fn write(&self, data: Vec<u8>) -> Result<u64> {
        let inner = self.inner.clone();
        run(async move {
            let length = data.len() as u64;
            let offset = inner.reserve(length);
            inner.write_at(offset, data).await?;
            Ok(length)
        })
        .await
    }

    pub fn begin_read(&self, length: u32) -> Result<Arc<PendingRead>> {
        self.inner.check_open()?;
        let inner = self.inner.clone();
        let offset = inner.reserve(length as u64);
        let (sender, receiver) = oneshot::channel();
        spawn(async move {
            let _ = sender.send(inner.read_at(offset, length).await);
        });
        Ok(Arc::new(PendingRead { receiver: tokio::sync::Mutex::new(Some(receiver)) }))
    }

    pub fn begin_write(&self, data: Vec<u8>) -> Result<Arc<PendingWrite>> {
        self.inner.check_open()?;
        let inner = self.inner.clone();
        let length = data.len() as u64;
        let offset = inner.reserve(length);
        let (sender, receiver) = oneshot::channel();
        spawn(async move {
            let _ = sender.send(inner.write_at(offset, data).await);
        });
        Ok(Arc::new(PendingWrite { length, receiver: tokio::sync::Mutex::new(Some(receiver)) }))
    }
}

#[derive(uniffi::Object)]
pub struct PendingRead {
    receiver: tokio::sync::Mutex<Option<oneshot::Receiver<Result<Vec<u8>>>>>,
}

#[uniffi::export]
impl PendingRead {
    pub async fn wait(&self) -> Result<Vec<u8>> {
        let receiver = self.receiver.lock().await.take();
        let receiver = receiver.ok_or_else(|| RusshError::invalid_state("Read already awaited"))?;
        receiver.await.map_err(|_| RusshError::connection_failed("Read was abandoned"))?
    }
}

#[derive(uniffi::Object)]
pub struct PendingWrite {
    length: u64,
    receiver: tokio::sync::Mutex<Option<oneshot::Receiver<Result<()>>>>,
}

#[uniffi::export]
impl PendingWrite {
    pub fn length(&self) -> u64 {
        self.length
    }

    pub async fn wait(&self) -> Result<()> {
        let receiver = self.receiver.lock().await.take();
        let receiver = receiver.ok_or_else(|| RusshError::invalid_state("Write already awaited"))?;
        receiver.await.map_err(|_| RusshError::connection_failed("Write was abandoned"))?
    }
}

// MARK: - Directories

struct DirectoryInner {
    sftp: Arc<SftpInner>,
    handle: String,
    closed: AtomicBool,
    eof: AtomicBool,
}

#[derive(uniffi::Object)]
pub struct Directory {
    inner: Arc<DirectoryInner>,
}

impl DirectoryInner {
    fn check_open(&self) -> Result<()> {
        self.sftp.check_open()?;
        if self.closed.load(Ordering::Acquire) {
            return Err(RusshError::closed("SFTP directory is closed"));
        }
        Ok(())
    }
}

#[uniffi::export]
impl Directory {
    pub fn check_open(&self) -> Result<()> {
        self.inner.check_open()
    }

    pub async fn read(&self) -> Result<Vec<Attributes>> {
        let inner = self.inner.clone();
        run(async move {
            inner.check_open()?;
            if inner.eof.load(Ordering::Acquire) {
                return Ok(Vec::new());
            }
            match inner.sftp.raw.readdir(inner.handle.as_str()).await {
                Ok(name) => Ok(name
                    .files
                    .into_iter()
                    .map(|file| Attributes::from(&file.attrs, Some(file.filename), Some(file.longname)))
                    .collect()),
                Err(SftpClientError::Status(status)) if status.status_code == StatusCode::Eof => {
                    inner.eof.store(true, Ordering::Release);
                    Ok(Vec::new())
                }
                Err(error) => Err(error.into()),
            }
        })
        .await
    }

    pub async fn close(&self) {
        let inner = self.inner.clone();
        if inner.closed.swap(true, Ordering::AcqRel) || inner.sftp.check_open().is_err() {
            return;
        }
        run(async move {
            let _ = inner.sftp.raw.close(inner.handle.as_str()).await;
        })
        .await
    }
}
