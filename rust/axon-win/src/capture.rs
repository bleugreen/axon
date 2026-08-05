use axon_core::{BackendError, Rect, Screenshot};
use std::{
    ops::Deref,
    sync::mpsc,
    time::{Duration, Instant},
};
use windows::{
    Foundation::TypedEventHandler,
    Graphics::{
        Capture::{
            Direct3D11CaptureFrame, Direct3D11CaptureFramePool, GraphicsCaptureItem,
            GraphicsCaptureSession,
        },
        DirectX::{Direct3D11::IDirect3DDevice, DirectXPixelFormat},
        Imaging::{BitmapDecoder, BitmapEncoder, SoftwareBitmap},
    },
    Media::Ocr::OcrEngine,
    Storage::Streams::{DataReader, InMemoryRandomAccessStream},
    Win32::{
        Foundation::{HMODULE, HWND, RECT},
        Graphics::{
            Direct3D::{D3D_DRIVER_TYPE_HARDWARE, D3D_FEATURE_LEVEL},
            Direct3D11::{
                D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_SDK_VERSION, D3D11CreateDevice,
                ID3D11Device,
            },
            Dwm::{DWMWA_EXTENDED_FRAME_BOUNDS, DwmGetWindowAttribute},
            Dxgi::IDXGIDevice,
        },
        System::WinRT::{
            Direct3D11::CreateDirect3D11DeviceFromDXGIDevice,
            Graphics::Capture::IGraphicsCaptureItemInterop,
        },
        UI::WindowsAndMessaging::GetWindowRect,
    },
    core::{Interface, factory},
};

const FRAME_TIMEOUT: Duration = Duration::from_secs(3);

struct CaptureResources {
    pool: Direct3D11CaptureFramePool,
    session: GraphicsCaptureSession,
    frame_arrived_token: Option<i64>,
}

fn bitmap_for_ocr(
    bitmap: &SoftwareBitmap,
    max_dimension: u32,
) -> Result<SoftwareBitmap, BackendError> {
    let width = bitmap
        .PixelWidth()
        .map_err(|e| operation("read OCR bitmap width", e))?;
    let height = bitmap
        .PixelHeight()
        .map_err(|e| operation("read OCR bitmap height", e))?;
    let (scaled_width, scaled_height) = scaled_dimensions((width, height), max_dimension)?;
    if scaled_width == width && scaled_height == height {
        return Ok(bitmap.clone());
    }

    let stream =
        InMemoryRandomAccessStream::new().map_err(|e| operation("create OCR resize stream", e))?;
    let encoder = BitmapEncoder::CreateAsync(
        BitmapEncoder::BmpEncoderId().map_err(|e| operation("get BMP encoder id", e))?,
        &stream,
    )
    .and_then(|operation| operation.join())
    .map_err(|e| operation("create OCR resize encoder", e))?;
    encoder
        .SetSoftwareBitmap(bitmap)
        .map_err(|e| operation("set OCR resize bitmap", e))?;
    let transform = encoder
        .BitmapTransform()
        .map_err(|e| operation("get OCR resize transform", e))?;
    transform
        .SetScaledWidth(scaled_width as u32)
        .map_err(|e| operation("set OCR resize width", e))?;
    transform
        .SetScaledHeight(scaled_height as u32)
        .map_err(|e| operation("set OCR resize height", e))?;
    encoder
        .FlushAsync()
        .and_then(|operation| operation.join())
        .map_err(|e| operation("resize OCR bitmap", e))?;
    stream
        .Seek(0)
        .map_err(|e| operation("rewind OCR resize stream", e))?;
    let decoder = BitmapDecoder::CreateAsync(&stream)
        .and_then(|operation| operation.join())
        .map_err(|e| operation("decode resized OCR bitmap", e))?;
    decoder
        .GetSoftwareBitmapAsync()
        .and_then(|operation| operation.join())
        .map_err(|e| operation("read resized OCR bitmap", e))
}

fn scaled_dimensions(size: (i32, i32), max_dimension: u32) -> Result<(i32, i32), BackendError> {
    let (width, height) = size;
    if width <= 0 || height <= 0 || max_dimension == 0 {
        return Err(op(
            "resize OCR bitmap",
            "bitmap and OCR limits must be positive",
        ));
    }
    let largest = width.max(height) as u64;
    if largest <= max_dimension as u64 {
        return Ok(size);
    }
    let max = max_dimension as u64;
    let scaled_width = ((width as u64 * max) / largest).max(1) as i32;
    let scaled_height = ((height as u64 * max) / largest).max(1) as i32;
    Ok((scaled_width, scaled_height))
}

impl Drop for CaptureResources {
    fn drop(&mut self) {
        if let Some(token) = self.frame_arrived_token.take() {
            let _ = self.pool.RemoveFrameArrived(token);
        }
        let _ = self.session.Close();
        let _ = self.pool.Close();
    }
}

struct CaptureFrame(Direct3D11CaptureFrame);

impl Deref for CaptureFrame {
    type Target = Direct3D11CaptureFrame;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl Drop for CaptureFrame {
    fn drop(&mut self) {
        let _ = self.0.Close();
    }
}

pub(crate) struct CapturedBitmap {
    pub bitmap: SoftwareBitmap,
    pub screen_frame: Rect,
}

#[derive(Clone, Debug, PartialEq)]
pub struct OcrWord {
    pub text: String,
    pub frame: Rect,
}

pub(crate) fn capture(hwnd: HWND) -> Result<CapturedBitmap, BackendError> {
    if !GraphicsCaptureSession::IsSupported()
        .map_err(|e| operation("check Graphics Capture support", e))?
    {
        return Err(op(
            "capture window",
            "Windows Graphics Capture is unsupported",
        ));
    }

    let item_factory: IGraphicsCaptureItemInterop =
        factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>()
            .map_err(|e| operation("get GraphicsCaptureItem HWND interop", e))?;
    let item = unsafe { item_factory.CreateForWindow::<GraphicsCaptureItem>(hwnd) }
        .map_err(|e| operation("create capture item for HWND", e))?;
    let device = create_direct3d_device()?;
    let size = item
        .Size()
        .map_err(|e| operation("read capture item size", e))?;
    if size.Width <= 0 || size.Height <= 0 {
        return Err(op("capture window", "capture item has an empty size"));
    }

    let pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
        &device,
        DirectXPixelFormat::B8G8R8A8UIntNormalized,
        2,
        size,
    )
    .map_err(|e| operation("create free-threaded capture frame pool", e))?;
    let session = match pool.CreateCaptureSession(&item) {
        Ok(session) => session,
        Err(error) => {
            let _ = pool.Close();
            return Err(operation("create capture session", error));
        }
    };
    let (tx, rx) = mpsc::sync_channel(1);
    let token = match pool.FrameArrived(&TypedEventHandler::<
        Direct3D11CaptureFramePool,
        windows::core::IInspectable,
    >::new(move |sender, _| {
        if let Some(sender) = sender.as_ref() {
            let _ = tx.try_send(sender.TryGetNextFrame());
        }
        Ok(())
    })) {
        Ok(token) => token,
        Err(error) => {
            let _ = session.Close();
            let _ = pool.Close();
            return Err(operation("register frame arrival", error));
        }
    };
    let resources = CaptureResources {
        pool,
        session,
        frame_arrived_token: Some(token),
    };

    resources
        .session
        .StartCapture()
        .map_err(|e| operation("start window capture", e))?;
    let deadline = Instant::now() + FRAME_TIMEOUT;
    let mut pool_size = size;
    let frame = loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(op("wait for captured frame", "timed out after a resize"));
        }
        let frame = CaptureFrame(
            rx.recv_timeout(remaining)
                .map_err(|e| op("wait for captured frame", e.to_string()))?
                .map_err(|e| operation("obtain captured frame", e))?,
        );
        let content_size = frame
            .ContentSize()
            .map_err(|e| operation("read captured frame content size", e))?;
        if content_size.Width <= 0 || content_size.Height <= 0 {
            return Err(op(
                "capture window",
                "captured frame has an empty content size",
            ));
        }
        if content_size == pool_size {
            break frame;
        }
        resources
            .pool
            .Recreate(
                &device,
                DirectXPixelFormat::B8G8R8A8UIntNormalized,
                2,
                content_size,
            )
            .map_err(|e| operation("resize capture frame pool", e))?;
        pool_size = content_size;
    };
    let content_size = frame
        .ContentSize()
        .map_err(|e| operation("read captured frame content size", e))?;
    let surface = frame
        .Surface()
        .map_err(|e| operation("read captured Direct3D surface", e))?;
    let bitmap = SoftwareBitmap::CreateCopyFromSurfaceAsync(&surface)
        .and_then(|operation| operation.join())
        .map_err(|e| operation("copy captured surface to software bitmap", e))?;
    let bitmap_size = (
        bitmap
            .PixelWidth()
            .map_err(|e| operation("read captured bitmap width", e))?,
        bitmap
            .PixelHeight()
            .map_err(|e| operation("read captured bitmap height", e))?,
    );
    if bitmap_size != (content_size.Width, content_size.Height) {
        return Err(op(
            "capture window",
            format!(
                "captured surface is {}x{} but frame content is {}x{}",
                bitmap_size.0, bitmap_size.1, content_size.Width, content_size.Height,
            ),
        ));
    }

    let screen_frame = capture_screen_frame(hwnd, (content_size.Width, content_size.Height))?;

    Ok(CapturedBitmap {
        bitmap,
        screen_frame,
    })
}

fn capture_screen_frame(hwnd: HWND, content_size: (i32, i32)) -> Result<Rect, BackendError> {
    let mut bounds = RECT::default();
    let dwm_result = unsafe {
        DwmGetWindowAttribute(
            hwnd,
            DWMWA_EXTENDED_FRAME_BOUNDS,
            &mut bounds as *mut RECT as *mut _,
            size_of::<RECT>() as u32,
        )
    };
    if dwm_result.is_err() || bounds.right <= bounds.left || bounds.bottom <= bounds.top {
        unsafe { GetWindowRect(hwnd, &mut bounds) }
            .map_err(|e| operation("get physical window rectangle", e))?;
    }
    physical_capture_frame(bounds, content_size)
}

fn physical_capture_frame(bounds: RECT, content_size: (i32, i32)) -> Result<Rect, BackendError> {
    let width = bounds.right - bounds.left;
    let height = bounds.bottom - bounds.top;
    if width <= 0 || height <= 0 || content_size.0 <= 0 || content_size.1 <= 0 {
        return Err(op("capture window", "capture geometry must be positive"));
    }
    Ok(Rect {
        x: bounds.left as f64,
        y: bounds.top as f64,
        width: width as f64,
        height: height as f64,
    })
}

pub(crate) fn screenshot(captured: &CapturedBitmap) -> Result<Screenshot, BackendError> {
    let stream =
        InMemoryRandomAccessStream::new().map_err(|e| operation("create PNG output stream", e))?;
    let encoder = BitmapEncoder::CreateAsync(
        BitmapEncoder::PngEncoderId().map_err(|e| operation("get PNG encoder id", e))?,
        &stream,
    )
    .and_then(|operation| operation.join())
    .map_err(|e| operation("create PNG encoder", e))?;
    encoder
        .SetSoftwareBitmap(&captured.bitmap)
        .map_err(|e| operation("set PNG software bitmap", e))?;
    encoder
        .FlushAsync()
        .and_then(|operation| operation.join())
        .map_err(|e| operation("encode PNG", e))?;

    let size = stream.Size().map_err(|e| operation("read PNG size", e))?;
    let len = u32::try_from(size).map_err(|_| op("read PNG", "encoded PNG exceeds 4 GiB"))?;
    stream
        .Seek(0)
        .map_err(|e| operation("rewind PNG stream", e))?;
    let reader = DataReader::CreateDataReader(&stream)
        .map_err(|e| operation("create PNG data reader", e))?;
    reader
        .LoadAsync(len)
        .and_then(|operation| operation.join())
        .map_err(|e| operation("load encoded PNG bytes", e))?;
    let mut bytes = vec![0; len as usize];
    reader
        .ReadBytes(&mut bytes)
        .map_err(|e| operation("read encoded PNG bytes", e))?;

    Ok(Screenshot {
        bytes,
        media_type: "image/png".into(),
        frame: captured.screen_frame,
    })
}

pub(crate) fn ocr(captured: &CapturedBitmap) -> Result<Vec<OcrWord>, BackendError> {
    let engine = OcrEngine::TryCreateFromUserProfileLanguages()
        .map_err(|e| operation("create OCR engine from user languages", e))?;
    let max_dimension = OcrEngine::MaxImageDimension()
        .map_err(|e| operation("read OCR maximum image dimension", e))?;
    let ocr_bitmap = bitmap_for_ocr(&captured.bitmap, max_dimension)?;
    let result = engine
        .RecognizeAsync(&ocr_bitmap)
        .and_then(|operation| operation.join())
        .map_err(|e| operation("recognize captured window text", e))?;
    let bitmap_size = (
        ocr_bitmap
            .PixelWidth()
            .map_err(|e| operation("read OCR bitmap width", e))?,
        ocr_bitmap
            .PixelHeight()
            .map_err(|e| operation("read OCR bitmap height", e))?,
    );
    let mut words = Vec::new();
    for line in result.Lines().map_err(|e| operation("read OCR lines", e))? {
        for word in line.Words().map_err(|e| operation("read OCR words", e))? {
            let bounds = word
                .BoundingRect()
                .map_err(|e| operation("read OCR word bounds", e))?;
            words.push(OcrWord {
                text: word
                    .Text()
                    .map_err(|e| operation("read OCR word text", e))?
                    .to_string(),
                frame: map_bitmap_rect(
                    Rect {
                        x: bounds.X as f64,
                        y: bounds.Y as f64,
                        width: bounds.Width as f64,
                        height: bounds.Height as f64,
                    },
                    bitmap_size,
                    captured.screen_frame,
                )?,
            });
        }
    }
    Ok(words)
}

fn create_direct3d_device() -> Result<IDirect3DDevice, BackendError> {
    let mut device: Option<ID3D11Device> = None;
    let mut level = D3D_FEATURE_LEVEL::default();
    unsafe {
        D3D11CreateDevice(
            None,
            D3D_DRIVER_TYPE_HARDWARE,
            HMODULE::default(),
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            None,
            D3D11_SDK_VERSION,
            Some(&mut device),
            Some(&mut level),
            None,
        )
    }
    .map_err(|e| operation("create D3D11 device", e))?;
    let dxgi: IDXGIDevice = device
        .ok_or_else(|| op("create D3D11 device", "API returned no device"))?
        .cast()
        .map_err(|e| operation("cast D3D11 device to DXGI", e))?;
    unsafe { CreateDirect3D11DeviceFromDXGIDevice(&dxgi) }
        .and_then(|value| value.cast())
        .map_err(|e| operation("create WinRT Direct3D device", e))
}

fn map_bitmap_rect(
    rect: Rect,
    bitmap_size: (i32, i32),
    screen_frame: Rect,
) -> Result<Rect, BackendError> {
    let (bitmap_width, bitmap_height) = bitmap_size;
    if bitmap_width <= 0 || bitmap_height <= 0 {
        return Err(op(
            "map OCR coordinates",
            "bitmap dimensions must be positive",
        ));
    }
    let scale_x = screen_frame.width / bitmap_width as f64;
    let scale_y = screen_frame.height / bitmap_height as f64;
    Ok(Rect {
        x: screen_frame.x + rect.x * scale_x,
        y: screen_frame.y + rect.y * scale_y,
        width: rect.width * scale_x,
        height: rect.height * scale_y,
    })
}

fn operation(name: &str, error: windows::core::Error) -> BackendError {
    op(name, error.to_string())
}

fn op(name: &str, message: impl Into<String>) -> BackendError {
    BackendError::Operation {
        operation: name.into(),
        message: message.into(),
        diagnostic: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_bitmap_pixels_to_negative_origin_physical_screen_rect() {
        let mapped = map_bitmap_rect(
            Rect {
                x: 100.0,
                y: 50.0,
                width: 200.0,
                height: 100.0,
            },
            (1000, 500),
            Rect {
                x: -1920.0,
                y: -200.0,
                width: 1500.0,
                height: 1000.0,
            },
        )
        .unwrap();
        assert_eq!(
            mapped,
            Rect {
                x: -1770.0,
                y: -100.0,
                width: 300.0,
                height: 200.0
            }
        );
    }

    #[test]
    fn maps_nonuniform_bitmap_scaling_per_axis() {
        let mapped = map_bitmap_rect(
            Rect {
                x: 10.0,
                y: 20.0,
                width: 30.0,
                height: 40.0,
            },
            (200, 400),
            Rect {
                x: 100.0,
                y: 200.0,
                width: 400.0,
                height: 200.0,
            },
        )
        .unwrap();
        assert_eq!(
            mapped,
            Rect {
                x: 120.0,
                y: 210.0,
                width: 60.0,
                height: 20.0
            }
        );
    }

    #[test]
    fn rejects_empty_bitmap_dimensions() {
        assert!(
            map_bitmap_rect(
                Rect {
                    x: 0.0,
                    y: 0.0,
                    width: 1.0,
                    height: 1.0
                },
                (0, 100),
                Rect {
                    x: 0.0,
                    y: 0.0,
                    width: 100.0,
                    height: 100.0
                },
            )
            .is_err()
        );
    }

    #[test]
    fn scales_oversized_ocr_bitmap_without_changing_aspect_ratio() {
        assert_eq!(scaled_dimensions((8000, 4000), 4096).unwrap(), (4096, 2048));
        assert_eq!(scaled_dimensions((3000, 6000), 4096).unwrap(), (2048, 4096));
        assert_eq!(scaled_dimensions((1920, 1080), 4096).unwrap(), (1920, 1080));
    }

    #[test]
    fn keeps_one_pixel_in_extremely_thin_ocr_bitmap() {
        assert_eq!(scaled_dimensions((1, 10000), 4096).unwrap(), (1, 4096));
    }

    #[test]
    fn maps_content_pixels_through_visible_physical_bounds() {
        let frame = physical_capture_frame(
            RECT {
                left: -10,
                top: 20,
                right: 990,
                bottom: 770,
            },
            (1200, 900),
        )
        .unwrap();
        assert_eq!(
            frame,
            Rect {
                x: -10.0,
                y: 20.0,
                width: 1000.0,
                height: 750.0
            }
        );
        let mapped = map_bitmap_rect(
            Rect {
                x: 600.0,
                y: 450.0,
                width: 120.0,
                height: 90.0,
            },
            (1200, 900),
            frame,
        )
        .unwrap();
        assert_eq!(
            mapped,
            Rect {
                x: 490.0,
                y: 395.0,
                width: 100.0,
                height: 75.0
            }
        );
    }
}
