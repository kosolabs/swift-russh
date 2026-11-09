use std::io;

use russh_sftp::client::error::Error as SftpClientError;
use russh_sftp::protocol::{Status, StatusCode};

pub(crate) type Result<T> = std::result::Result<T, RusshError>;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum KeyErrorKind {
    PassphraseRequired,
    Invalid,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ConnectionFailureKind {
    UnknownHost,
    Refused,
    TimedOut,
    Lost,
    Other,
}

impl ConnectionFailureKind {
    pub(crate) fn of(error: &io::Error) -> Self {
        match error.kind() {
            io::ErrorKind::ConnectionRefused => Self::Refused,
            io::ErrorKind::TimedOut => Self::TimedOut,
            io::ErrorKind::ConnectionReset
            | io::ErrorKind::ConnectionAborted
            | io::ErrorKind::BrokenPipe
            | io::ErrorKind::NotConnected
            | io::ErrorKind::UnexpectedEof => Self::Lost,
            _ => Self::Other,
        }
    }
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum RusshError {
    #[error("{message}")]
    ConnectionFailed { kind: ConnectionFailureKind, message: String },
    #[error("{message}")]
    Closed { message: String },
    #[error("{message}")]
    AuthenticationFailed { message: String },
    #[error("{message}")]
    Key { kind: KeyErrorKind, message: String },
    #[error("{message}")]
    Sftp { code: u32, message: String },
    #[error("{message}")]
    ChannelOpenFailed { message: String },
    #[error("{message}")]
    InvalidState { message: String },
}

impl RusshError {
    pub(crate) fn connection_failed(kind: ConnectionFailureKind, message: impl Into<String>) -> Self {
        Self::ConnectionFailed { kind, message: message.into() }
    }

    pub(crate) fn closed(message: impl Into<String>) -> Self {
        Self::Closed { message: message.into() }
    }

    pub(crate) fn invalid_state(message: impl Into<String>) -> Self {
        Self::InvalidState { message: message.into() }
    }

    pub(crate) fn sftp(code: StatusCode, message: impl Into<String>) -> Self {
        Self::Sftp { code: code as u32, message: message.into() }
    }

    pub(crate) fn sftp_code(&self) -> Option<u32> {
        match self {
            Self::Sftp { code, .. } => Some(*code),
            _ => None,
        }
    }
}

impl From<russh::Error> for RusshError {
    fn from(error: russh::Error) -> Self {
        match error {
            russh::Error::ChannelOpenFailure(reason) => {
                Self::ChannelOpenFailed { message: format!("Channel open failed: {reason:?}") }
            }
            russh::Error::NotAuthenticated => {
                Self::AuthenticationFailed { message: error.to_string() }
            }
            russh::Error::IO(ref io) => {
                Self::connection_failed(ConnectionFailureKind::of(io), error.to_string())
            }
            russh::Error::Disconnect
            | russh::Error::HUP
            | russh::Error::SendError
            | russh::Error::RecvError => {
                Self::connection_failed(ConnectionFailureKind::Lost, error.to_string())
            }
            russh::Error::ConnectionTimeout
            | russh::Error::KeepaliveTimeout
            | russh::Error::InactivityTimeout
            | russh::Error::Elapsed(_) => {
                Self::connection_failed(ConnectionFailureKind::TimedOut, error.to_string())
            }
            other => Self::connection_failed(ConnectionFailureKind::Other, other.to_string()),
        }
    }
}

impl From<Status> for RusshError {
    fn from(status: Status) -> Self {
        Self::sftp(status.status_code, status.error_message)
    }
}

impl From<SftpClientError> for RusshError {
    fn from(error: SftpClientError) -> Self {
        match error {
            SftpClientError::Status(status) => status.into(),
            SftpClientError::Limited(message) => Self::invalid_state(message),
            SftpClientError::UnexpectedPacket => Self::invalid_state(error.to_string()),
            SftpClientError::Timeout => {
                Self::connection_failed(ConnectionFailureKind::TimedOut, error.to_string())
            }
            SftpClientError::IO(_) | SftpClientError::UnexpectedBehavior(_) => {
                Self::connection_failed(ConnectionFailureKind::Lost, error.to_string())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kind(error: impl Into<RusshError>) -> Option<ConnectionFailureKind> {
        match error.into() {
            RusshError::ConnectionFailed { kind, .. } => Some(kind),
            _ => None,
        }
    }

    fn io_error(kind: io::ErrorKind) -> io::Error {
        io::Error::new(kind, "test")
    }

    #[test]
    fn io_errors_are_classified_by_kind() {
        use ConnectionFailureKind::*;
        assert_eq!(ConnectionFailureKind::of(&io_error(io::ErrorKind::ConnectionRefused)), Refused);
        assert_eq!(ConnectionFailureKind::of(&io_error(io::ErrorKind::TimedOut)), TimedOut);
        assert_eq!(ConnectionFailureKind::of(&io_error(io::ErrorKind::ConnectionReset)), Lost);
        assert_eq!(ConnectionFailureKind::of(&io_error(io::ErrorKind::BrokenPipe)), Lost);
        assert_eq!(ConnectionFailureKind::of(&io_error(io::ErrorKind::UnexpectedEof)), Lost);
        assert_eq!(ConnectionFailureKind::of(&io_error(io::ErrorKind::PermissionDenied)), Other);
    }

    #[test]
    fn russh_errors_are_classified() {
        use ConnectionFailureKind::*;
        assert_eq!(kind(russh::Error::KeepaliveTimeout), Some(TimedOut));
        assert_eq!(kind(russh::Error::InactivityTimeout), Some(TimedOut));
        assert_eq!(kind(russh::Error::HUP), Some(Lost));
        assert_eq!(kind(russh::Error::Disconnect), Some(Lost));
        assert_eq!(kind(russh::Error::SendError), Some(Lost));
        assert_eq!(kind(russh::Error::IO(io_error(io::ErrorKind::ConnectionReset))), Some(Lost));
        assert_eq!(kind(russh::Error::IO(io_error(io::ErrorKind::ConnectionRefused))), Some(Refused));
        assert_eq!(kind(russh::Error::Kex), Some(Other));
        assert_eq!(kind(russh::Error::NotAuthenticated), None);
    }

    #[test]
    fn sftp_errors_are_classified() {
        use ConnectionFailureKind::*;
        assert_eq!(kind(SftpClientError::Timeout), Some(TimedOut));
        assert_eq!(kind(SftpClientError::UnexpectedBehavior("sender dropped".into())), Some(Lost));
        assert_eq!(kind(SftpClientError::IO("broken pipe".into())), Some(Lost));
        assert_eq!(kind(SftpClientError::Limited("read limit".into())), None);
    }
}
