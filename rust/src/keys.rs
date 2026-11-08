use std::sync::Arc;

use russh::keys::{Algorithm, EcdsaCurve, Error as KeyError};

use crate::error::{KeyErrorKind, Result, RusshError};

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum KeyType {
    Dss,
    Rsa,
    EcdsaP256,
    EcdsaP384,
    EcdsaP521,
    Ed25519,
    SecurityKeyEcdsa,
    SecurityKeyEd25519,
    Other { name: String },
}

impl From<&Algorithm> for KeyType {
    fn from(algorithm: &Algorithm) -> Self {
        match algorithm {
            Algorithm::Dsa => Self::Dss,
            Algorithm::Rsa { .. } => Self::Rsa,
            Algorithm::Ecdsa { curve: EcdsaCurve::NistP256 } => Self::EcdsaP256,
            Algorithm::Ecdsa { curve: EcdsaCurve::NistP384 } => Self::EcdsaP384,
            Algorithm::Ecdsa { curve: EcdsaCurve::NistP521 } => Self::EcdsaP521,
            Algorithm::Ed25519 => Self::Ed25519,
            Algorithm::SkEcdsaSha2NistP256 => Self::SecurityKeyEcdsa,
            Algorithm::SkEd25519 => Self::SecurityKeyEd25519,
            other => Self::Other { name: other.as_str().to_owned() },
        }
    }
}

#[derive(uniffi::Object)]
pub struct PrivateKey {
    pub(crate) key: Arc<russh::keys::PrivateKey>,
}

#[uniffi::export]
impl PrivateKey {
    #[uniffi::constructor]
    pub fn decode(contents: String, passphrase: Option<String>) -> Result<Arc<Self>> {
        let key = russh::keys::decode_secret_key(&contents, passphrase.as_deref()).map_err(
            |error| {
                let kind = match (&error, &passphrase) {
                    (KeyError::KeyIsEncrypted, None) => KeyErrorKind::PassphraseRequired,
                    _ => KeyErrorKind::Invalid,
                };
                RusshError::Key { kind, message: error.to_string() }
            },
        )?;
        Ok(Arc::new(Self { key: Arc::new(key) }))
    }

    pub fn key_type(&self) -> KeyType {
        KeyType::from(&self.key.algorithm())
    }
}
