use std::ffi::{c_char, c_void};

type CFTypeRef = *const c_void;
type CFStringRef = *const c_void;

const UTF8: u32 = 0x0800_0100;

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFGetTypeID(value: CFTypeRef) -> usize;
    fn CFStringGetTypeID() -> usize;
    fn CFStringGetLength(value: CFStringRef) -> isize;
    fn CFStringGetMaximumSizeForEncoding(length: isize, encoding: u32) -> isize;
    fn CFStringGetCString(
        value: CFStringRef,
        buffer: *mut c_char,
        size: isize,
        encoding: u32,
    ) -> u8;
}

fn nul_terminated_buffer_len(maximum_encoded_size: isize) -> Option<usize> {
    usize::try_from(maximum_encoded_size).ok()?.checked_add(1)
}

pub(crate) fn string_value(value: CFTypeRef) -> Option<String> {
    if value.is_null() || unsafe { CFGetTypeID(value) } != unsafe { CFStringGetTypeID() } {
        return None;
    }

    let length = unsafe { CFStringGetLength(value) };
    let maximum_encoded_size = unsafe { CFStringGetMaximumSizeForEncoding(length, UTF8) };
    let buffer_len = nul_terminated_buffer_len(maximum_encoded_size)?;
    let mut buffer = vec![0u8; buffer_len];
    if unsafe {
        CFStringGetCString(
            value,
            buffer.as_mut_ptr().cast(),
            buffer.len().try_into().ok()?,
            UTF8,
        )
    } == 0
    {
        return None;
    }

    let end = buffer.iter().position(|byte| *byte == 0)?;
    String::from_utf8(buffer[..end].to_vec()).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{ffi::CString, ptr::null};

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringCreateWithCString(
            allocator: *const c_void,
            text: *const c_char,
            encoding: u32,
        ) -> CFStringRef;
        fn CFRelease(value: CFTypeRef);
    }

    #[test]
    fn reads_a_utf8_string_larger_than_four_kibibytes() {
        let expected = format!("{}{}", "a".repeat(10_000), "😀".repeat(100));
        let bytes = CString::new(expected.as_str()).unwrap();
        let value = unsafe { CFStringCreateWithCString(null(), bytes.as_ptr(), UTF8) };
        assert!(!value.is_null());

        assert_eq!(string_value(value), Some(expected));

        unsafe { CFRelease(value) };
    }

    #[test]
    fn rejects_invalid_buffer_sizes() {
        assert_eq!(nul_terminated_buffer_len(-1), None);
        assert_eq!(nul_terminated_buffer_len(10_000), Some(10_001));
    }
}