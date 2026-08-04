use axon_core::{BackendError, Rect, Screenshot};
use std::{sync::mpsc, time::Duration};
use windows::{
    Foundation::TypedEventHandler,
    Graphics::{
        Capture::{
            Direct3D11CaptureFramePool, GraphicsCaptureItem, GraphicsCaptureSession,
        },
        DirectX::{
            Direct3D11::IDirect3DDevice, DirectXPixelFormat,
        },
        Imaging::{BitmapEncoder, SoftwareBitmap},
        SizeInt32,
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
            Dxgi::IDXGIDevice,
        },
        System::WinRT::{
            Direct3D11::CreateDirect3D11DeviceFromDXGIDevice,
            Graphics::Capture::IGraphicsCaptureItemInterop,
        },
        UI::WindowsAndMessaging::GetWindowRect,
    },
    core::{factory, Interface},
};

const FRAME_TIMEOUT: Duration = Duration::from_secs(3);

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
        return Err(op("capture window", "Windows Graphics Capture is unsupported"));
    }

    let mut window_rect = RECT::default();
    unsafe { GetWindowRect(hwnd, &mut window_rect) }
        .map_err(|e| operation("get physical window rectangle", e))?;
    let width = window_rect.right - window_rect.left;
    let height = window_rect.bottom - window_rect.top;
    if width <= 0 || height <= 0 {
        return Err(op("capture window", "window has an empty physical rectangle"));
    }

    let item_factory: IGraphicsCaptureItemInterop =
        factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>()
            .map_err(|e| operation("get GraphicsCaptureItem HWND interop", e))?;
    let item = unsafe { item_factory.CreateForWindow::<GraphicsCaptureItem>(hwnd) }
        .map_err(|e| operation("create capture item for HWND", e))?;
    let device = create_direct3d_device()?;
    let size = item.Size().map_err(|e| operation("read capture item size", e))?;
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
    let session = pool
        .CreateCaptureSession(&item)
        .map_err(|e| operation("create capture session", e))?;
    let (tx, rx) = mpsc::sync_channel(1);
    let token = pool
        .FrameArrived(&TypedEventHandler::new(move |sender, _| {
            if let Some(sender) = sender {
                let _ = tx.try_send(sender.TryGetNextFrame());
            }
            Ok(())
        }))
        .map_err(|e| operation("register frame arrival", e))?;

    session
        .StartCapture()
        .map_err(|e| operation("start window capture", e))?;
    let frame = rx
        .recv_timeout(FRAME_TIMEOUT)
        .map_err(|e| op("wait for captured frame", e.to_string()))?
        .map_err(|e| operation("obtain captured frame", e))?;
    let _ = pool.RemoveFrameArrived(token);
    let surface = frame
        .Surface()
        .map_err(|e| operation("read captured Direct3D surface", e))?;
    let bitmap = SoftwareBitmap::CreateCopyFromSurfaceAsync(&surface)
        .and_then(|operation| operation.join())
        .map_err(|e| operation("copy captured surface to software bitmap", e))?;

    frame.Close().map_err(|e| operation("close capture frame", e))?;
    session.Close().map_err(|e| operation("close capture session", e))?;
    pool.Close().map_err(|e| operation("close capture frame pool", e))?;

    Ok(CapturedBitmap {
        bitmap,
        screen_frame: Rect {
            x: window_rect.left as f64,
            y: window_rect.top as f64,
            width: width as f64,
            height: height as f64,
        },
    })
}

pub(crate) fn screenshot(captured: &CapturedBitmap) -> Result<Screenshot, BackendError> {
    let stream = InMemoryRandomAccessStream::new()
        .map_err(|e| operation("create PNG output stream", e))?;
    let encoder = BitmapEncoder::CreateAsync(BitmapEncoder::PngEncoderId()
        .map_err(|e| operation("get PNG encoder id", e))?, &stream)
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
    stream.Seek(0).map_err(|e| operation("rewind PNG stream", e))?;
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
    let result = engine
        .RecognizeAsync(&captured.bitmap)
        .and_then(|operation| operation.join())
        .map_err(|e| operation("recognize captured window text", e))?;
    let bitmap_size = (
        captured.bitmap.PixelWidth()
            .map_err(|e| operation("read OCR bitmap width", e))?,
        captured.bitmap.PixelHeight()
            .map_err(|e| operation("read OCR bitmap height", e))?,
    );
    let mut words = Vec::new();
    for line in result.Lines().map_err(|e| operation("read OCR lines", e))? {
        for word in line.Words().map_err(|e| operation("read OCR words", e))? {
            let bounds = word.BoundingRect()
                .map_err(|e| operation("read OCR word bounds", e))?;
            words.push(OcrWord {
                text: word.Text()
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
        return Err(op("map OCR coordinates", "bitmap dimensions must be positive"));
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
            Rect { x: 100.0, y: 50.0, width: 200.0, height: 100.0 },
            (1000, 500),
            Rect { x: -1920.0, y: -200.0, width: 1500.0, height: 1000.0 },
        )
        .unwrap();
        assert_eq!(
            mapped,
            Rect { x: -1770.0, y: -100.0, width: 300.0, height: 200.0 }
        );
    }

    #[test]
    fn maps_nonuniform_bitmap_scaling_per_axis() {
        let mapped = map_bitmap_rect(
            Rect { x: 10.0, y: 20.0, width: 30.0, height: 40.0 },
            (200, 400),
            Rect { x: 100.0, y: 200.0, width: 400.0, height: 200.0 },
        )
        .unwrap();
        assert_eq!(
            mapped,
            Rect { x: 120.0, y: 210.0, width: 60.0, height: 20.0 }
        );
    }

    #[test]
    fn rejects_empty_bitmap_dimensions() {
        assert!(map_bitmap_rect(
            Rect { x: 0.0, y: 0.0, width: 1.0, height: 1.0 },
            (0, 100),
            Rect { x: 0.0, y: 0.0, width: 100.0, height: 100.0 },
        )
        .is_err());
    }
}
