use russh_sftp::client::error::Error as SftpClientError;
use russh_sftp::protocol::{Status, StatusCode};

pub(crate) type Result<T> = std::result::Result<T, RusshError>;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum KeyErrorKind {
    PassphraseRequired,
    Invalid,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum RusshError {
    #[error("{message}")]
    ConnectionFailed { message: String },
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
    pub(crate) fn connection_failed(message: impl Into<String>) -> Self {
        Self::ConnectionFailed { message: message.into() }
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
            other => Self::connection_failed(other.to_string()),
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
            SftpClientError::IO(_)
            | SftpClientError::Timeout
            | SftpClientError::UnexpectedBehavior(_) => Self::connection_failed(error.to_string()),
        }
    }
}
