use axon_core::{
    BackendError, Capability, OBSERVATION_SCREENSHOT_MAX_DIMENSION,
    OBSERVATION_SCREENSHOT_MEDIA_TYPE, Rect, Screenshot,
};
use std::{ffi::c_void, ptr::null};

type CFTypeRef = *const c_void;
type CFMutableDataRef = *mut c_void;
type CFStringRef = *const c_void;
type CFArrayRef = *const c_void;
type CGImageRef = *const c_void;
type CGContextRef = *mut c_void;

#[repr(C)]
#[derive(Clone, Copy)]
struct CGPoint {
    x: f64,
    y: f64,
}

struct CaptureWindow {
    id: u32,
    frame: Rect,
}

fn window_for_pid(pid: i32) -> Result<CaptureWindow, BackendError> {
    let windows = Owned::new(
        unsafe {
            CGWindowListCopyWindowInfo(
                WINDOW_LIST_OPTION_ON_SCREEN_ONLY | WINDOW_LIST_EXCLUDE_DESKTOP_ELEMENTS,
                0,
            )
        },
        "list on-screen windows",
    )?;
    for index in 0..unsafe { CFArrayGetCount(windows.0) } {
        let dictionary = unsafe { CFArrayGetValueAtIndex(windows.0, index) };
        if dictionary.is_null() {
            continue;
        }
        let owner = dictionary_number(dictionary, unsafe { kCGWindowOwnerPID });
        let layer = dictionary_number(dictionary, unsafe { kCGWindowLayer });
        if owner == Some(i64::from(pid)) && layer == Some(0) {
            let id = dictionary_number(dictionary, unsafe { kCGWindowNumber })
                .and_then(|value| u32::try_from(value).ok())
                .ok_or_else(|| op("resolve capture window", "window has no numeric identifier"))?;
            let bounds = unsafe { CFDictionaryGetValue(dictionary, kCGWindowBounds) };
            let mut frame = CGRect {
                origin: CGPoint { x: 0.0, y: 0.0 },
                size: CGSize {
                    width: 0.0,
                    height: 0.0,
                },
            };
            if bounds.is_null()
                || !unsafe { CGRectMakeWithDictionaryRepresentation(bounds, &mut frame) }
                || frame.size.width <= 0.0
                || frame.size.height <= 0.0
            {
                return Err(op("resolve capture window", "window has no valid bounds"));
            }
            return Ok(CaptureWindow {
                id,
                frame: Rect {
                    x: frame.origin.x,
                    y: frame.origin.y,
                    width: frame.size.width,
                    height: frame.size.height,
                },
            });
        }
    }
    Err(op(
        "resolve capture window",
        "application owns no on-screen layer-zero window",
    ))
}

fn dictionary_number(dictionary: *const c_void, key: CFStringRef) -> Option<i64> {
    let value = unsafe { CFDictionaryGetValue(dictionary, key) };
    if value.is_null() {
        return None;
    }
    let mut number = 0i64;
    unsafe { CFNumberGetValue(value, 4, (&mut number as *mut i64).cast()) }.then_some(number)
}

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    static kCGWindowNumber: CFStringRef;
    static kCGWindowOwnerPID: CFStringRef;
    static kCGWindowLayer: CFStringRef;
    static kCGWindowBounds: CFStringRef;
    fn CGRectMakeWithDictionaryRepresentation(
        dictionary: *const c_void,
        rect: *mut CGRect,
    ) -> bool;
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CGSize {
    width: f64,
    height: f64,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CGRect {
    origin: CGPoint,
    size: CGSize,
}

const WINDOW_LIST_OPTION_INCLUDING_WINDOW: u32 = 1 << 3;
const WINDOW_LIST_OPTION_ON_SCREEN_ONLY: u32 = 1;
const WINDOW_LIST_EXCLUDE_DESKTOP_ELEMENTS: u32 = 1 << 4;
const WINDOW_IMAGE_BOUNDS_IGNORE_FRAMING: u32 = 1 << 0;
const INTERPOLATION_HIGH: i32 = 3;

#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    static CGRectNull: CGRect;
    fn CGPreflightScreenCaptureAccess() -> bool;
    fn CGWindowListCreateImage(
        screen_bounds: CGRect,
        list_option: u32,
        window_id: u32,
        image_option: u32,
    ) -> CGImageRef;
    fn CGWindowListCopyWindowInfo(list_option: u32, relative_to_window: u32) -> CFArrayRef;
    fn CGImageGetWidth(image: CGImageRef) -> usize;
    fn CGImageGetHeight(image: CGImageRef) -> usize;
    fn CGBitmapContextCreate(
        data: *mut c_void,
        width: usize,
        height: usize,
        bits_per_component: usize,
        bytes_per_row: usize,
        color_space: *const c_void,
        bitmap_info: u32,
    ) -> CGContextRef;
    fn CGColorSpaceCreateDeviceRGB() -> CFTypeRef;
    fn CGContextSetInterpolationQuality(context: CGContextRef, quality: i32);
    fn CGContextDrawImage(context: CGContextRef, rect: CGRect, image: CGImageRef);
    fn CGBitmapContextCreateImage(context: CGContextRef) -> CGImageRef;
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(value: CFTypeRef);
    fn CFDataCreateMutable(allocator: *const c_void, capacity: isize) -> CFMutableDataRef;
    fn CFDataGetLength(data: CFMutableDataRef) -> isize;
    fn CFDataGetBytePtr(data: CFMutableDataRef) -> *const u8;
    fn CFArrayGetCount(array: CFArrayRef) -> isize;
    fn CFArrayGetValueAtIndex(array: CFArrayRef, index: isize) -> *const c_void;
    fn CFDictionaryGetValue(dictionary: *const c_void, key: *const c_void) -> *const c_void;
    fn CFNumberGetValue(number: CFTypeRef, number_type: i64, value: *mut c_void) -> bool;
    fn CFStringCreateWithCString(
        allocator: *const c_void,
        text: *const i8,
        encoding: u32,
    ) -> CFStringRef;
}

#[link(name = "ImageIO", kind = "framework")]
unsafe extern "C" {
    fn CGImageDestinationCreateWithData(
        data: CFMutableDataRef,
        image_type: CFStringRef,
        count: usize,
        options: CFTypeRef,
    ) -> CFTypeRef;
    fn CGImageDestinationAddImage(destination: CFTypeRef, image: CGImageRef, properties: CFTypeRef);
    fn CGImageDestinationFinalize(destination: CFTypeRef) -> bool;
}

struct Owned(CFTypeRef);

impl Owned {
    fn new(value: CFTypeRef, operation: &str) -> Result<Self, BackendError> {
        (!value.is_null())
            .then_some(Self(value))
            .ok_or_else(|| op(operation, "native API returned null"))
    }
}

impl Drop for Owned {
    fn drop(&mut self) {
        unsafe { CFRelease(self.0) };
    }
}

pub(crate) fn screen_capture_enabled() -> bool {
    unsafe { CGPreflightScreenCaptureAccess() }
}

pub(crate) fn screenshot(pid: i32) -> Result<Screenshot, BackendError> {
    if !screen_capture_enabled() {
        return Err(BackendError::Capability {
            capability: Capability::Screenshot,
            reason: "Screen Recording permission is not granted".into(),
            diagnostic: None,
        });
    }
    let window = window_for_pid(pid)?;

    let captured = Owned::new(
        unsafe {
            CGWindowListCreateImage(
                CGRectNull,
                WINDOW_LIST_OPTION_INCLUDING_WINDOW,
                window.id,
                WINDOW_IMAGE_BOUNDS_IGNORE_FRAMING,
            )
        },
        "capture window image",
    )?;
    let source_width = unsafe { CGImageGetWidth(captured.0) };
    let source_height = unsafe { CGImageGetHeight(captured.0) };
    let (width, height) = scaled_dimensions(
        (source_width, source_height),
        OBSERVATION_SCREENSHOT_MAX_DIMENSION,
    )?;
    let image = if (width, height) == (source_width, source_height) {
        None
    } else {
        Some(resize(captured.0, width, height)?)
    };
    let image_ref = image.as_ref().map_or(captured.0, |image| image.0);
    let bytes = encode_png(image_ref)?;

    Ok(Screenshot {
        bytes,
        media_type: OBSERVATION_SCREENSHOT_MEDIA_TYPE.into(),
        width: u32::try_from(width).map_err(|_| op("capture window image", "width overflow"))?,
        height: u32::try_from(height).map_err(|_| op("capture window image", "height overflow"))?,
        frame: window.frame,
    })
}

fn scaled_dimensions(
    size: (usize, usize),
    max_dimension: u32,
) -> Result<(usize, usize), BackendError> {
    let (width, height) = size;
    if width == 0 || height == 0 || max_dimension == 0 {
        return Err(op("resize screenshot", "image dimensions must be positive"));
    }
    let largest = width.max(height);
    let max = max_dimension as usize;
    if largest <= max {
        return Ok(size);
    }
    Ok((
        (width * max / largest).max(1),
        (height * max / largest).max(1),
    ))
}

fn resize(image: CGImageRef, width: usize, height: usize) -> Result<Owned, BackendError> {
    let color_space = Owned::new(
        unsafe { CGColorSpaceCreateDeviceRGB() },
        "create RGB color space",
    )?;
    // Premultiplied-last RGBA with 8-bit components. Passing null data asks Core Graphics to own
    // the backing allocation, whose lifetime is then tied to the context.
    let context = Owned::new(
        unsafe {
            CGBitmapContextCreate(std::ptr::null_mut(), width, height, 8, 0, color_space.0, 1)
        },
        "create screenshot resize context",
    )?;
    unsafe {
        CGContextSetInterpolationQuality(context.0.cast_mut(), INTERPOLATION_HIGH);
        CGContextDrawImage(
            context.0.cast_mut(),
            CGRect {
                origin: CGPoint { x: 0.0, y: 0.0 },
                size: CGSize {
                    width: width as f64,
                    height: height as f64,
                },
            },
            image,
        );
    }
    Owned::new(
        unsafe { CGBitmapContextCreateImage(context.0.cast_mut()) },
        "create resized screenshot image",
    )
}

fn encode_png(image: CGImageRef) -> Result<Vec<u8>, BackendError> {
    let data = Owned::new(unsafe { CFDataCreateMutable(null(), 0) }, "create PNG data")?;
    let image_type = Owned::new(
        unsafe { CFStringCreateWithCString(null(), c"public.png".as_ptr(), 0x0800_0100) },
        "create PNG type identifier",
    )?;
    let destination = Owned::new(
        unsafe { CGImageDestinationCreateWithData(data.0.cast_mut(), image_type.0, 1, null()) },
        "create PNG destination",
    )?;
    unsafe { CGImageDestinationAddImage(destination.0, image, null()) };
    if !unsafe { CGImageDestinationFinalize(destination.0) } {
        return Err(op("encode PNG", "ImageIO could not finalize the image"));
    }
    let length = unsafe { CFDataGetLength(data.0.cast_mut()) };
    if length <= 0 {
        return Err(op("encode PNG", "ImageIO produced no data"));
    }
    let bytes = unsafe { CFDataGetBytePtr(data.0.cast_mut()) };
    if bytes.is_null() {
        return Err(op("encode PNG", "ImageIO returned a null data pointer"));
    }
    Ok(unsafe { std::slice::from_raw_parts(bytes, length as usize) }.to_vec())
}

fn op(operation: &str, message: impl Into<String>) -> BackendError {
    BackendError::Operation {
        operation: operation.into(),
        message: message.into(),
        diagnostic: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scales_long_edge_without_upscaling() {
        let max = OBSERVATION_SCREENSHOT_MAX_DIMENSION;
        assert_eq!(scaled_dimensions((2560, 1600), max).unwrap(), (1280, 800));
        assert_eq!(scaled_dimensions((640, 480), max).unwrap(), (640, 480));
        assert_eq!(scaled_dimensions((1, 4096), max).unwrap(), (1, 1280));
    }
}
