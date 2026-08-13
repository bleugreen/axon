//! Task Scheduler COM registration for the current interactive user.
#![cfg(windows)]
use std::{ffi::c_void, io, ptr};
use windows::Win32::System::{
    Com::{
        CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED, CoCreateInstance, CoInitializeEx,
        CoUninitialize,
    },
    TaskScheduler::{
        ITaskService, TASK_CREATE_OR_UPDATE, TASK_LOGON_INTERACTIVE_TOKEN, TaskScheduler,
    },
    Variant::VARIANT,
};
use windows_core::BSTR;
pub const MULTIPLE_INSTANCES_POLICY: &str = "IgnoreNew";
struct Apartment;
impl Apartment {
    fn initialize() -> io::Result<Self> {
        unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED) }
            .ok()
            .map_err(as_io)?;
        Ok(Self)
    }
}
impl Drop for Apartment {
    fn drop(&mut self) {
        unsafe { CoUninitialize() }
    }
}
fn as_io(error: windows_core::Error) -> io::Error {
    if error.code().0 == 0x80070005u32 as i32 {
        io::Error::from_raw_os_error(5)
    } else {
        io::Error::other(error.to_string())
    }
}
fn escape_xml(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}
fn current_user_sid() -> io::Result<String> {
    #[repr(C)]
    struct SidAndAttributes {
        sid: *mut c_void,
        attributes: u32,
    }
    #[link(name = "advapi32")]
    unsafe extern "system" {
        fn GetTokenInformation(
            token: isize,
            class: u32,
            info: *mut c_void,
            len: u32,
            needed: *mut u32,
        ) -> i32;
        fn ConvertSidToStringSidW(sid: *mut c_void, string_sid: *mut *mut u16) -> i32;
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn LocalFree(memory: *mut c_void) -> *mut c_void;
    }
    let mut needed = 0;
    unsafe { GetTokenInformation(-4, 1, ptr::null_mut(), 0, &mut needed) };
    if needed == 0 {
        return Err(io::Error::last_os_error());
    }
    let mut data = vec![0u8; needed as usize];
    if unsafe { GetTokenInformation(-4, 1, data.as_mut_ptr().cast(), needed, &mut needed) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let sid = unsafe { (*(data.as_ptr() as *const SidAndAttributes)).sid };
    let mut text = ptr::null_mut();
    if unsafe { ConvertSidToStringSidW(sid, &mut text) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let len = unsafe { (0..).find(|&i| *text.add(i) == 0).unwrap() };
    let result = unsafe { String::from_utf16_lossy(std::slice::from_raw_parts(text, len)) };
    unsafe {
        LocalFree(text.cast());
    }
    Ok(result)
}
fn folder() -> io::Result<(
    Apartment,
    windows::Win32::System::TaskScheduler::ITaskFolder,
)> {
    let apartment = Apartment::initialize()?;
    let service: ITaskService =
        unsafe { CoCreateInstance(&TaskScheduler, None, CLSCTX_INPROC_SERVER) }.map_err(as_io)?;
    let empty = VARIANT::default();
    unsafe { service.Connect(&empty, &empty, &empty, &empty) }.map_err(as_io)?;
    let root = unsafe { service.GetFolder(&BSTR::from(r"\")) }.map_err(as_io)?;
    Ok((apartment, root))
}
pub fn register(name: &str, executable: &str) -> io::Result<()> {
    let sid = current_user_sid()?;
    let xml = format!(
        r#"<?xml version="1.0" encoding="UTF-16"?><Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Triggers><LogonTrigger><Enabled>true</Enabled><UserId>{sid}</UserId></LogonTrigger></Triggers><Principals><Principal id="Author"><UserId>{sid}</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals><Settings><MultipleInstancesPolicy>{policy}</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><Enabled>true</Enabled></Settings><Actions Context="Author"><Exec><Command>{command}</Command></Exec></Actions></Task>"#,
        sid = escape_xml(&sid),
        policy = MULTIPLE_INSTANCES_POLICY,
        command = escape_xml(executable)
    );
    let (_apartment, root) = folder()?;
    let empty = VARIANT::default();
    unsafe {
        root.RegisterTask(
            &BSTR::from(name),
            &BSTR::from(xml),
            TASK_CREATE_OR_UPDATE.0,
            &empty,
            &empty,
            TASK_LOGON_INTERACTIVE_TOKEN,
            &empty,
        )
    }
    .map_err(as_io)?;
    Ok(())
}
pub fn delete(name: &str) -> io::Result<()> {
    let (_apartment, root) = folder()?;
    unsafe { root.DeleteTask(&BSTR::from(name), 0) }.map_err(as_io)
}
