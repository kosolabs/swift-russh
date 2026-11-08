use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use russh::client::Msg;
use russh::{ChannelMsg, ChannelWriteHalf, Sig};
use tokio::sync::Notify;
use tokio::task::JoinHandle;

use crate::error::{Result, RusshError};
use crate::runtime::{run, spawn};
use crate::session::{Session, SessionInner};

#[derive(Debug, Clone, uniffi::Record)]
pub struct ExitStatus {
    pub code: Option<u32>,
    pub signal: Option<String>,
    pub core_dumped: bool,
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum StreamKind {
    Stdout,
    Stderr,
}

#[derive(Default)]
struct Buffers {
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    eof: bool,
    closed: bool,
    exec_reply: Option<bool>,
    exit: Option<ExitStatus>,
}

#[derive(Default)]
struct ChannelState {
    buffers: Mutex<Buffers>,
    changed: Notify,
}

impl ChannelState {
    fn update(&self, body: impl FnOnce(&mut Buffers)) {
        body(&mut self.buffers.lock().unwrap());
        self.changed.notify_waiters();
    }

    async fn wait_for<T>(&self, mut ready: impl FnMut(&mut Buffers) -> Option<T>) -> T {
        loop {
            let changed = self.changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            if let Some(value) = ready(&mut self.buffers.lock().unwrap()) {
                return value;
            }
            changed.await;
        }
    }
}

fn signal_name(signal: Sig) -> String {
    match signal {
        Sig::ABRT => "ABRT".into(),
        Sig::ALRM => "ALRM".into(),
        Sig::FPE => "FPE".into(),
        Sig::HUP => "HUP".into(),
        Sig::ILL => "ILL".into(),
        Sig::INT => "INT".into(),
        Sig::KILL => "KILL".into(),
        Sig::PIPE => "PIPE".into(),
        Sig::QUIT => "QUIT".into(),
        Sig::SEGV => "SEGV".into(),
        Sig::TERM => "TERM".into(),
        Sig::USR1 => "USR1".into(),
        Sig::Custom(name) => name,
    }
}

#[derive(uniffi::Object)]
pub struct ExecChannel {
    session: Arc<SessionInner>,
    writer: ChannelWriteHalf<Msg>,
    state: Arc<ChannelState>,
    closed: AtomicBool,
    reader: JoinHandle<()>,
}

impl ExecChannel {
    fn check_open(&self) -> Result<()> {
        self.session.check_open()?;
        if self.closed.load(Ordering::Acquire) {
            return Err(RusshError::closed("SSH channel is closed"));
        }
        Ok(())
    }
}

#[uniffi::export]
impl Session {
    pub async fn open_channel(&self) -> Result<Arc<ExecChannel>> {
        let session = self.inner.clone();
        run(async move {
            let channel = session.open_channel().await?;
            let (mut read_half, writer) = channel.split();
            let state = Arc::new(ChannelState::default());
            let reader_state = state.clone();
            let reader = spawn(async move {
                while let Some(message) = read_half.wait().await {
                    reader_state.update(|buffers| match message {
                        ChannelMsg::Data { data } => buffers.stdout.extend_from_slice(&data),
                        ChannelMsg::ExtendedData { data, ext: 1 } => {
                            buffers.stderr.extend_from_slice(&data)
                        }
                        ChannelMsg::Eof => buffers.eof = true,
                        ChannelMsg::Success => buffers.exec_reply = Some(true),
                        ChannelMsg::Failure => buffers.exec_reply = Some(false),
                        ChannelMsg::ExitStatus { exit_status } => {
                            buffers.exit = Some(ExitStatus {
                                code: Some(exit_status),
                                signal: None,
                                core_dumped: false,
                            })
                        }
                        ChannelMsg::ExitSignal { signal_name: signal, core_dumped, .. } => {
                            buffers.exit = Some(ExitStatus {
                                code: None,
                                signal: Some(signal_name(signal)),
                                core_dumped,
                            })
                        }
                        ChannelMsg::Close => buffers.closed = true,
                        _ => {}
                    });
                }
                reader_state.update(|buffers| buffers.closed = true);
            });
            Ok(Arc::new(ExecChannel {
                session,
                writer,
                state,
                closed: AtomicBool::new(false),
                reader,
            }))
        })
        .await
    }
}

#[uniffi::export]
impl ExecChannel {
    pub async fn exec(self: Arc<Self>, command: String) -> Result<()> {
        run(async move {
            self.check_open()?;
            self.writer.exec(true, command).await?;
            let accepted = self
                .state
                .wait_for(|buffers| buffers.exec_reply.or(buffers.closed.then_some(false)))
                .await;
            if !accepted {
                return Err(RusshError::invalid_state("Server rejected the exec request"));
            }
            Ok(())
        })
        .await
    }

    pub async fn read(self: Arc<Self>, stream: StreamKind, max_length: u32) -> Result<Vec<u8>> {
        run(async move {
            self.check_open()?;
            let max_length = max_length as usize;
            Ok(self
                .state
                .wait_for(|buffers| {
                    let ended = buffers.eof || buffers.closed;
                    let buffer = match stream {
                        StreamKind::Stdout => &mut buffers.stdout,
                        StreamKind::Stderr => &mut buffers.stderr,
                    };
                    if !buffer.is_empty() {
                        let length = buffer.len().min(max_length);
                        return Some(buffer.drain(..length).collect());
                    }
                    ended.then(Vec::new)
                })
                .await)
        })
        .await
    }

    pub async fn exit_status(self: Arc<Self>) -> Result<ExitStatus> {
        run(async move {
            self.check_open()?;
            Ok(self
                .state
                .wait_for(|buffers| {
                    buffers.exit.clone().or_else(|| {
                        buffers.closed.then_some(ExitStatus {
                            code: None,
                            signal: None,
                            core_dumped: false,
                        })
                    })
                })
                .await)
        })
        .await
    }

    pub async fn close(self: Arc<Self>) {
        if self.closed.swap(true, Ordering::AcqRel) {
            return;
        }
        run(async move {
            let _ = self.writer.close().await;
            self.reader.abort();
        })
        .await
    }
}
