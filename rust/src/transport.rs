use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};

use russh_sftp::client::error::Error as SftpClientError;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio_util::sync::CancellationToken;

/// Cancels `lost` once the stream ends or fails, so requests on it stop
/// waiting for replies that can no longer arrive.
pub(crate) struct WatchedStream<S> {
    inner: S,
    lost: CancellationToken,
}

impl<S> WatchedStream<S> {
    pub(crate) fn new(inner: S, lost: CancellationToken) -> Self {
        Self { inner, lost }
    }

    fn watch<T>(&self, poll: Poll<io::Result<T>>) -> Poll<io::Result<T>> {
        if let Poll::Ready(Err(_)) = poll {
            self.lost.cancel();
        }
        poll
    }
}

impl<S: AsyncRead + Unpin> AsyncRead for WatchedStream<S> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let filled = buf.filled().len();
        let poll = Pin::new(&mut self.inner).poll_read(cx, buf);
        if let Poll::Ready(Ok(())) = poll
            && buf.filled().len() == filled
            && buf.remaining() > 0
        {
            self.lost.cancel();
        }
        self.watch(poll)
    }
}

impl<S: AsyncWrite + Unpin> AsyncWrite for WatchedStream<S> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        let poll = Pin::new(&mut self.inner).poll_write(cx, buf);
        self.watch(poll)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let poll = Pin::new(&mut self.inner).poll_flush(cx);
        self.watch(poll)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let poll = Pin::new(&mut self.inner).poll_shutdown(cx);
        if poll.is_ready() {
            self.lost.cancel();
        }
        poll
    }
}

/// Runs an SFTP request unless the transport is lost first. russh-sftp only
/// fails the requests pending when its read loop ends; one sent just after
/// would otherwise wait out its full request timeout.
pub(crate) async fn unless_lost<T>(
    lost: &CancellationToken,
    request: impl Future<Output = Result<T, SftpClientError>>,
) -> Result<T, SftpClientError> {
    if lost.is_cancelled() {
        return Err(connection_lost());
    }
    tokio::select! {
        biased;
        result = request => result,
        () = lost.cancelled() => Err(connection_lost()),
    }
}

fn connection_lost() -> SftpClientError {
    SftpClientError::UnexpectedBehavior("Connection lost".into())
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    use russh_sftp::client::{Config, RawSftpSession};
    use tokio::io::{AsyncWriteExt, duplex};

    use super::*;

    fn session(lost: &CancellationToken) -> (Arc<RawSftpSession>, tokio::io::DuplexStream) {
        session_with(lost, 64 * 1024, 30)
    }

    fn session_with(
        lost: &CancellationToken,
        buffer: usize,
        timeout_secs: u64,
    ) -> (Arc<RawSftpSession>, tokio::io::DuplexStream) {
        let (client, server) = duplex(buffer);
        let config = Config { request_timeout_secs: timeout_secs, ..Config::default() };
        let raw = RawSftpSession::new_with_config(WatchedStream::new(client, lost.clone()), config);
        (Arc::new(raw), server)
    }

    /// The server stops reading, so russh-sftp's writer blocks mid-packet and
    /// never sees its read loop end. Closing the server's side then fails the
    /// pending request but leaves the writer accepting new ones.
    async fn lose_transport_with_writer_stuck(
        raw: &Arc<RawSftpSession>,
        server: &mut tokio::io::DuplexStream,
    ) {
        let first = {
            let raw = raw.clone();
            tokio::spawn(async move { raw.stat("/first").await })
        };
        tokio::time::sleep(Duration::from_millis(50)).await;
        server.shutdown().await.unwrap();
        let result = tokio::time::timeout(Duration::from_secs(2), first)
            .await
            .expect("russh-sftp fails requests pending when its read loop ends")
            .unwrap();
        assert!(result.is_err(), "{result:?}");
    }

    #[tokio::test]
    async fn without_the_guard_a_request_after_the_loss_waits_for_its_timeout() {
        let lost = CancellationToken::new();
        let (raw, mut server) = session_with(&lost, 8, 2);
        lose_transport_with_writer_stuck(&raw, &mut server).await;

        let start = Instant::now();
        let result = raw.stat("/second").await;
        assert!(matches!(result, Err(SftpClientError::Timeout)), "{result:?}");
        assert!(start.elapsed() >= Duration::from_millis(1900), "{:?}", start.elapsed());
    }

    #[tokio::test]
    async fn with_the_guard_a_request_after_the_loss_fails_promptly() {
        let lost = CancellationToken::new();
        let (raw, mut server) = session_with(&lost, 8, 2);
        lose_transport_with_writer_stuck(&raw, &mut server).await;

        let start = Instant::now();
        let result = unless_lost(&lost, raw.stat("/second")).await;
        assert!(matches!(result, Err(SftpClientError::UnexpectedBehavior(_))), "{result:?}");
        assert!(start.elapsed() < Duration::from_millis(500), "{:?}", start.elapsed());
    }

    #[tokio::test]
    async fn eof_from_the_server_marks_the_transport_lost() {
        let lost = CancellationToken::new();
        let (_raw, mut server) = session(&lost);
        server.shutdown().await.unwrap();
        tokio::time::timeout(Duration::from_secs(2), lost.cancelled())
            .await
            .expect("the transport should be marked lost when the server closes");
    }

    #[tokio::test]
    async fn pending_request_fails_when_the_transport_is_lost() {
        let lost = CancellationToken::new();
        let (raw, _server) = session(&lost);
        let pending = {
            let (raw, lost) = (raw.clone(), lost.clone());
            tokio::spawn(async move { unless_lost(&lost, raw.stat("/")).await })
        };
        tokio::time::sleep(Duration::from_millis(50)).await;

        let start = Instant::now();
        lost.cancel();
        let result = pending.await.unwrap();
        assert!(matches!(result, Err(SftpClientError::UnexpectedBehavior(_))), "{result:?}");
        assert!(start.elapsed() < Duration::from_secs(1));
    }

    #[tokio::test]
    async fn request_after_the_transport_is_lost_fails_without_waiting() {
        let lost = CancellationToken::new();
        let (raw, _server) = session(&lost);
        lost.cancel();

        let start = Instant::now();
        let result = unless_lost(&lost, raw.stat("/")).await;
        assert!(matches!(result, Err(SftpClientError::UnexpectedBehavior(_))), "{result:?}");
        assert!(start.elapsed() < Duration::from_secs(1));
    }
}
