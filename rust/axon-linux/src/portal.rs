//! ScreenCast portal state, restore-token persistence, and PipeWire frame normalization.
//!
//! The D-Bus and PipeWire callbacks belong on the platform actor thread. This module deliberately
//! exposes a small, synchronous seam: callbacks publish complete frames into [`LatestFrame`], while
//! the backend reads snapshots without ever waiting on a PipeWire callback.

use axon_core::{Rect, Screenshot};
use image::{DynamicImage, ImageFormat, RgbaImage, imageops::FilterType};
use serde::{Deserialize, Serialize};
use std::{
    env, fs,
    io::{self, Cursor, Write},
    path::{Path, PathBuf},
    sync::{Arc, RwLock},
};

const TOKEN_SCHEMA_VERSION: u32 = 3;
pub const AUTHORIZATION_REQUIRED: &str = "portal-authorization-required";

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PortalState {
    AuthorizationRequired,
    Starting,
    Streaming,
    Unavailable(String),
    Failed(String),
}

impl PortalState {
    pub fn usable(&self) -> bool {
        matches!(self, Self::Streaming)
    }

    #[test]
    fn fresh_authorization_replaces_malformed_token_file() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("axon/portal/screencast.json");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, b"not json").unwrap();
        let store = TokenStore::at(path);
        assert_eq!(store.load().unwrap_err().kind(), io::ErrorKind::InvalidData);

        store
            .replace(Some("fresh-source"), RestoreToken::new("fresh-secret"))
            .unwrap();

        let (source, token) = store.load().unwrap().unwrap();
        assert_eq!(source.as_deref(), Some("fresh-source"));
        assert_eq!(token.expose(), "fresh-secret");
        assert_eq!(
            fs::metadata(store.path()).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}

/// Opaque capability material. Its custom `Debug` prevents accidental token disclosure.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct RestoreToken(String);

impl RestoreToken {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }
    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Debug for RestoreToken {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("RestoreToken([REDACTED])")
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct TokenRecord {
    source_id: Option<String>,
    token: RestoreToken,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct TokenFile {
    version: u32,
    records: Vec<TokenRecord>,
}

#[derive(Clone, Debug)]
pub struct TokenStore {
    path: PathBuf,
}

impl TokenStore {
    pub fn from_environment() -> io::Result<Self> {
        let root = match env::var_os("XDG_STATE_HOME") {
            Some(path) if !path.is_empty() => PathBuf::from(path),
            _ => PathBuf::from(env::var_os("HOME").ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotFound,
                    "neither XDG_STATE_HOME nor HOME is set",
                )
            })?)
            .join(".local/state"),
        };
        Ok(Self::at(root.join("axon/portal/screencast.json")))
    }

    pub fn at(path: PathBuf) -> Self {
        Self { path }
    }
    pub fn path(&self) -> &Path {
        &self.path
    }

    fn records(&self) -> io::Result<Vec<TokenRecord>> {
        let bytes = match fs::read(&self.path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => return Err(error),
        };
        let file: TokenFile = serde_json::from_slice(&bytes)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        if file.version != TOKEN_SCHEMA_VERSION {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("unsupported portal token schema {}", file.version),
            ));
        }
        Ok(file.records)
    }

    pub fn load(&self) -> io::Result<Option<(Option<String>, RestoreToken)>> {
        Ok(self
            .records()?
            .into_iter()
            .next()
            .map(|record| (record.source_id, record.token)))
    }

    pub(crate) fn clear(&self) -> io::Result<()> {
        match fs::remove_file(&self.path) {
            Ok(()) => {
                if let Some(parent) = self.path.parent() {
                    fs::File::open(parent)?.sync_all()?;
                }
                Ok(())
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error),
        }
    }

    pub fn replace(&self, source_id: Option<&str>, token: RestoreToken) -> io::Result<()> {
        // Replacement follows a successful portal Start response, which is the authority to
        // supersede malformed or old-schema capability material without first parsing it.
        let records = vec![TokenRecord {
            source_id: source_id.map(str::to_owned),
            token,
        }];
        let parent = self.path.parent().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "token path has no parent")
        })?;
        fs::create_dir_all(parent)?;
        restrict(parent, 0o700)?;
        let bytes = serde_json::to_vec(&TokenFile {
            version: TOKEN_SCHEMA_VERSION,
            records,
        })
        .map_err(io::Error::other)?;
        let temporary = parent.join(format!(".screencast.json.{}.tmp", std::process::id()));
        let result = (|| {
            let mut options = fs::OpenOptions::new();
            options.write(true).create(true).truncate(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options.open(&temporary)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            fs::rename(&temporary, &self.path)?;
            restrict(&self.path, 0o600)
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result
    }
}

#[cfg(unix)]
fn restrict(path: &Path, mode: u32) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
}
#[cfg(not(unix))]
fn restrict(_: &Path, _: u32) -> io::Result<()> {
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PackedFormat {
    Bgrx,
    Bgra,
    Rgbx,
    Rgba,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PipeWireFrame {
    pub width: u32,
    pub height: u32,
    pub offset: usize,
    pub stride: isize,
    pub format: PackedFormat,
    pub data: Vec<u8>,
}

impl PipeWireFrame {
    pub fn rgba(&self) -> Result<Vec<u8>, FrameError> {
        if self.width == 0 || self.height == 0 {
            return Err(FrameError::InvalidDimensions);
        }
        let row = usize::try_from(self.width)
            .ok()
            .and_then(|w| w.checked_mul(4))
            .ok_or(FrameError::InvalidDimensions)?;
        let stride = self.stride.unsigned_abs();
        let height = usize::try_from(self.height).map_err(|_| FrameError::InvalidDimensions)?;
        if stride < row || height == 0 {
            return Err(FrameError::Truncated);
        }
        let span = stride
            .checked_mul(height - 1)
            .and_then(|value| value.checked_add(row))
            .ok_or(FrameError::InvalidDimensions)?;
        let end = self
            .offset
            .checked_add(span)
            .ok_or(FrameError::InvalidDimensions)?;
        if end > self.data.len() {
            return Err(FrameError::Truncated);
        }
        let mut output = Vec::with_capacity(row * height);
        for output_row in 0..height {
            let storage_row = if self.stride < 0 {
                height - 1 - output_row
            } else {
                output_row
            };
            let start = self.offset + storage_row * stride;
            let source = &self.data[start..start + row];
            for pixel in source.chunks_exact(4) {
                let rgba = match self.format {
                    PackedFormat::Bgrx => [pixel[2], pixel[1], pixel[0], 255],
                    PackedFormat::Bgra => [pixel[2], pixel[1], pixel[0], pixel[3]],
                    PackedFormat::Rgbx => [pixel[0], pixel[1], pixel[2], 255],
                    PackedFormat::Rgba => [pixel[0], pixel[1], pixel[2], pixel[3]],
                };
                output.extend_from_slice(&rgba);
            }
        }
        Ok(output)
    }

    pub fn screenshot(&self) -> Result<Screenshot, FrameError> {
        let rgba = self.rgba()?;
        let image =
            RgbaImage::from_raw(self.width, self.height, rgba).ok_or(FrameError::Truncated)?;
        let max = axon_core::OBSERVATION_SCREENSHOT_MAX_DIMENSION;
        let image = if self.width.max(self.height) > max {
            DynamicImage::ImageRgba8(image).resize(max, max, FilterType::Triangle)
        } else {
            DynamicImage::ImageRgba8(image)
        };
        let mut png = Cursor::new(Vec::new());
        image
            .write_to(&mut png, ImageFormat::Png)
            .map_err(|error| FrameError::Encode(error.to_string()))?;
        Ok(Screenshot {
            bytes: png.into_inner(),
            media_type: axon_core::OBSERVATION_SCREENSHOT_MEDIA_TYPE.into(),
            width: image.width(),
            height: image.height(),
            frame: Rect {
                x: 0.0,
                y: 0.0,
                width: self.width as f64,
                height: self.height as f64,
            },
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FrameError {
    InvalidDimensions,
    Truncated,
    Encode(String),
}

/// Lock-protected single-slot mailbox. Publishing always replaces the older complete frame.
#[derive(Clone, Default)]
pub struct LatestFrame(Arc<RwLock<Option<PipeWireFrame>>>);

impl LatestFrame {
    pub fn publish(&self, frame: PipeWireFrame) {
        *self.0.write().expect("latest frame lock poisoned") = Some(frame);
    }
    pub fn snapshot(&self) -> Option<PipeWireFrame> {
        self.0.read().expect("latest frame lock poisoned").clone()
    }
    pub fn clear(&self) {
        *self.0.write().expect("latest frame lock poisoned") = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn token_round_trip_is_atomic_private_and_redacted() {
        let root = tempfile::tempdir().unwrap();
        let store = TokenStore::at(root.path().join("axon/portal/screencast.json"));
        store
            .replace(Some("portal-source"), RestoreToken::new("secret-one"))
            .unwrap();
        assert_eq!(store.load().unwrap().unwrap().1.expose(), "secret-one");
        store
            .replace(Some("portal-source"), RestoreToken::new("secret-two"))
            .unwrap();
        assert_eq!(store.load().unwrap().unwrap().1.expose(), "secret-two");
        assert_eq!(
            fs::metadata(store.path()).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert!(!format!("{:?}", store.load().unwrap()).contains("secret-two"));
        assert_eq!(
            fs::read_dir(store.path().parent().unwrap())
                .unwrap()
                .count(),
            1
        );
    }

    #[test]
    fn rejects_unknown_schema_without_deleting_it() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("screencast.json");
        fs::write(&path, r#"{"version":99,"source_id":null,"token":"old"}"#).unwrap();
        let store = TokenStore::at(path.clone());
        assert_eq!(store.load().unwrap_err().kind(), io::ErrorKind::InvalidData);
        assert!(path.exists());
    }

    #[test]
    fn converts_bgrx_and_ignores_stride_padding() {
        let frame = PipeWireFrame {
            width: 2,
            height: 1,
            offset: 0,
            stride: 12,
            format: PackedFormat::Bgrx,
            data: vec![3, 2, 1, 9, 6, 5, 4, 9, 99, 99, 99, 99],
        };
        assert_eq!(frame.rgba().unwrap(), vec![1, 2, 3, 255, 4, 5, 6, 255]);
        let shot = frame.screenshot().unwrap();
        assert_eq!((shot.width, shot.height), (2, 1));
        assert_eq!(&shot.bytes[..8], b"\x89PNG\r\n\x1a\n");
    }

    #[test]
    fn clearing_a_token_is_private_atomic_and_idempotent() {
        let root = tempfile::tempdir().unwrap();
        let store = TokenStore::at(root.path().join("axon/portal/screencast.json"));
        store
            .replace(Some("source"), RestoreToken::new("never-serialize-me"))
            .unwrap();
        store.clear().unwrap();
        assert_eq!(store.load().unwrap(), None);
        store.clear().unwrap();
        assert!(!format!("{store:?}").contains("never-serialize-me"));
    }

    #[test]
    fn successful_start_replaces_the_single_source_token() {
        let root = tempfile::tempdir().unwrap();
        let store = TokenStore::at(root.path().join("token"));
        store
            .replace(Some("source-a"), RestoreToken::new("token-a"))
            .unwrap();
        store
            .replace(Some("source-b"), RestoreToken::new("token-b"))
            .unwrap();
        let (source, token) = store.load().unwrap().unwrap();
        assert_eq!(source.as_deref(), Some("source-b"));
        assert_eq!(token.expose(), "token-b");
    }

    #[test]
    fn applies_chunk_offset_and_bottom_up_stride() {
        let frame = PipeWireFrame {
            width: 1,
            height: 2,
            offset: 2,
            stride: -4,
            format: PackedFormat::Rgba,
            data: vec![99, 99, 5, 6, 7, 8, 1, 2, 3, 4],
        };
        assert_eq!(frame.rgba().unwrap(), vec![1, 2, 3, 4, 5, 6, 7, 8]);
    }

    #[test]
    fn rejects_short_and_invalid_frames() {
        let short = PipeWireFrame {
            width: 2,
            height: 2,
            offset: 0,
            stride: 8,
            format: PackedFormat::Rgba,
            data: vec![0; 15],
        };
        assert_eq!(short.rgba(), Err(FrameError::Truncated));
        let empty = PipeWireFrame {
            width: 0,
            height: 1,
            offset: 0,
            stride: 0,
            format: PackedFormat::Rgba,
            data: vec![],
        };
        assert_eq!(empty.rgba(), Err(FrameError::InvalidDimensions));
    }

    #[test]
    fn latest_frame_replaces_and_clears() {
        let latest = LatestFrame::default();
        assert!(latest.snapshot().is_none());
        latest.publish(PipeWireFrame {
            width: 1,
            height: 1,
            offset: 0,
            stride: 4,
            format: PackedFormat::Rgba,
            data: vec![1, 2, 3, 4],
        });
        latest.publish(PipeWireFrame {
            width: 1,
            height: 1,
            offset: 0,
            stride: 4,
            format: PackedFormat::Rgba,
            data: vec![5, 6, 7, 8],
        });
        assert_eq!(latest.snapshot().unwrap().data, vec![5, 6, 7, 8]);
        latest.clear();
        assert!(latest.snapshot().is_none());
    }
}
