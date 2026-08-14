//! Interactive, probe-only keyboard observer. This intentionally lives beside the shipping
//! dispatch boundary: it observes that boundary without becoming another delivery implementation.
use super::{KeyboardBatchIntent, key_input, keyboard_event_metadata, op, send_keyboard_batch};
use crate::keys::VirtualKey;
use axon_core::BackendError;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};
use windows::Win32::Foundation::{CloseHandle, HANDLE, HWND, LPARAM, LRESULT, MAX_PATH, WPARAM};
use windows::Win32::Security::{
    GetTokenInformation, TOKEN_MANDATORY_LABEL, TOKEN_QUERY, TokenIntegrityLevel,
};
use windows::Win32::System::Com::{
    CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx, CoUninitialize,
};
use windows::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS,
};
use windows::Win32::System::RemoteDesktop::ProcessIdToSessionId;
use windows::Win32::System::Threading::{
    GetCurrentThreadId, OpenProcess, OpenProcessToken, PROCESS_NAME_FORMAT,
    PROCESS_QUERY_LIMITED_INFORMATION, QueryFullProcessImageNameW,
};
use windows::Win32::UI::Accessibility::{
    CUIAutomation, HWINEVENTHOOK, IUIAutomation, IUIAutomationElement, SetWinEventHook,
    UIA_DocumentControlTypeId, UIA_EditControlTypeId, UnhookWinEvent,
};
use windows::Win32::UI::Input::KeyboardAndMouse::SendInput;
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, DispatchMessageW, EVENT_OBJECT_FOCUS, GetForegroundWindow,
    GetWindowThreadProcessId, HHOOK, KBDLLHOOKSTRUCT, MSG, PM_REMOVE, PeekMessageW,
    SetWindowsHookExW, TranslateMessage, UnhookWindowsHookEx, WH_KEYBOARD_LL,
    WINEVENT_OUTOFCONTEXT, WM_KEYUP, WM_SYSKEYUP,
};
use windows::core::BSTR;

const EVENT_CAPACITY: usize = 512;
static EPOCH: OnceLock<Instant> = OnceLock::new();
static EVENTS: OnceLock<Mutex<EventBuffer>> = OnceLock::new();

#[derive(Default)]
struct EventBuffer {
    keyboard: Vec<RawKeyEvent>,
    focus: Vec<RawFocusEvent>,
    overflowed: bool,
}
#[derive(Clone, Debug)]
struct RawKeyEvent {
    at_us: u64,
    vk: u32,
    scan: u32,
    flags: u32,
    message: u32,
    thread: u32,
}
#[derive(Clone, Debug)]
struct RawFocusEvent {
    at_us: u64,
    hwnd: u64,
    object_id: i32,
    child_id: i32,
    thread: u32,
}

fn now_us() -> u64 {
    EPOCH
        .get_or_init(Instant::now)
        .elapsed()
        .as_micros()
        .min(u64::MAX as u128) as u64
}
fn hwnd_bits(hwnd: HWND) -> u64 {
    hwnd.0 as usize as u64
}

unsafe extern "system" fn keyboard_hook(code: i32, message: WPARAM, data: LPARAM) -> LRESULT {
    if code >= 0 {
        let event = unsafe { &*(data.0 as *const KBDLLHOOKSTRUCT) };
        if let Ok(mut out) = EVENTS.get_or_init(Default::default).try_lock() {
            if out.keyboard.len() < EVENT_CAPACITY {
                out.keyboard.push(RawKeyEvent {
                    at_us: now_us(),
                    vk: event.vkCode,
                    scan: event.scanCode,
                    flags: event.flags.0,
                    message: message.0 as u32,
                    thread: unsafe { GetCurrentThreadId() },
                });
            } else {
                out.overflowed = true;
            }
        }
    }
    unsafe { CallNextHookEx(None, code, message, data) }
}

unsafe extern "system" fn focus_hook(
    _: HWINEVENTHOOK,
    _: u32,
    hwnd: HWND,
    object_id: i32,
    child_id: i32,
    _: u32,
    _: u32,
) {
    if let Ok(mut out) = EVENTS.get_or_init(Default::default).try_lock() {
        if out.focus.len() < EVENT_CAPACITY {
            out.focus.push(RawFocusEvent {
                at_us: now_us(),
                hwnd: hwnd_bits(hwnd),
                object_id,
                child_id,
                thread: unsafe { GetCurrentThreadId() },
            });
        } else {
            out.overflowed = true;
        }
    }
}

struct Observer {
    keyboard: Option<HHOOK>,
    focus: Option<HWINEVENTHOOK>,
}
impl Observer {
    fn install() -> Result<Self, BackendError> {
        let keyboard = unsafe { SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_hook), None, 0) }
            .map_err(|e| {
            op(
                "keyboard diagnostic",
                format!("WH_KEYBOARD_LL installation failed: {e}"),
            )
        })?;
        let focus = unsafe {
            SetWinEventHook(
                EVENT_OBJECT_FOCUS,
                EVENT_OBJECT_FOCUS,
                None,
                Some(focus_hook),
                0,
                0,
                WINEVENT_OUTOFCONTEXT,
            )
        };
        if focus.is_invalid() {
            unsafe {
                let _ = UnhookWindowsHookEx(keyboard);
            }
            return Err(op(
                "keyboard diagnostic",
                "focus WinEvent hook installation failed",
            ));
        }
        Ok(Self {
            keyboard: Some(keyboard),
            focus: Some(focus),
        })
    }
    fn pump(&self, duration: Duration) {
        let end = Instant::now() + duration;
        let mut msg = MSG::default();
        while Instant::now() < end {
            while unsafe { PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE) }.as_bool() {
                unsafe {
                    let _ = TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
            }
            thread::sleep(Duration::from_millis(1));
        }
    }
    fn remove(mut self) -> bool {
        let focus_removed = self
            .focus
            .take()
            .is_none_or(|hook| unsafe { UnhookWinEvent(hook) }.as_bool());
        let keyboard_removed = self
            .keyboard
            .take()
            .is_none_or(|hook| unsafe { UnhookWindowsHookEx(hook) }.is_ok());
        focus_removed && keyboard_removed
    }
}
impl Drop for Observer {
    fn drop(&mut self) {
        if let Some(hook) = self.focus.take() {
            unsafe {
                let _ = UnhookWinEvent(hook);
            }
        }
        if let Some(hook) = self.keyboard.take() {
            unsafe {
                let _ = UnhookWindowsHookEx(hook);
            }
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct HookEvent {
    at_us: u64,
    virtual_key: u32,
    scan_code: u32,
    injected: bool,
    lower_integrity_injected: bool,
    direction: &'static str,
    message_time: u32,
    observer_thread: u32,
}
fn normalize(event: &RawKeyEvent) -> HookEvent {
    HookEvent {
        at_us: event.at_us,
        virtual_key: event.vk,
        scan_code: event.scan,
        injected: event.flags & 0x10 != 0,
        lower_integrity_injected: event.flags & 0x02 != 0,
        direction: if matches!(event.message, WM_KEYUP | WM_SYSKEYUP) {
            "up"
        } else {
            "down"
        },
        message_time: 0,
        observer_thread: event.thread,
    }
}
fn ordered_timeline(mut events: Vec<Value>) -> Vec<Value> {
    events.sort_by_key(|v| v.get("atUs").and_then(Value::as_u64).unwrap_or(u64::MAX));
    events
}

fn wide_text(buffer: &[u16]) -> String {
    String::from_utf16_lossy(&buffer[..buffer.iter().position(|c| *c == 0).unwrap_or(buffer.len())])
}

fn parent_process_id(pid: u32) -> Option<u32> {
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) }.ok()?;
    let mut entry = PROCESSENTRY32W {
        dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32,
        ..Default::default()
    };
    let mut found = None;
    if unsafe { Process32FirstW(snapshot, &mut entry) }.is_ok() {
        loop {
            if entry.th32ProcessID == pid {
                found = Some(entry.th32ParentProcessID);
                break;
            }
            if unsafe { Process32NextW(snapshot, &mut entry) }.is_err() {
                break;
            }
        }
    }
    unsafe {
        let _ = CloseHandle(snapshot);
    }
    found
}

fn process_details(pid: u32) -> (Option<String>, Option<u32>, Option<String>) {
    let process = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) }.ok();
    let path = process.and_then(|handle| {
        let mut buffer = [0u16; 32768];
        let mut size = buffer.len() as u32;
        let result = unsafe {
            QueryFullProcessImageNameW(
                handle,
                PROCESS_NAME_FORMAT(0),
                windows::core::PWSTR(buffer.as_mut_ptr()),
                &mut size,
            )
        };
        result
            .ok()
            .map(|_| String::from_utf16_lossy(&buffer[..size as usize]))
    });
    let integrity = process.and_then(|handle| {
        let mut token = HANDLE::default();
        unsafe { OpenProcessToken(handle, TOKEN_QUERY, &mut token) }.ok()?;
        let mut size = 0;
        let _ = unsafe { GetTokenInformation(token, TokenIntegrityLevel, None, 0, &mut size) };
        let mut bytes = vec![0u8; size as usize];
        let ok = unsafe {
            GetTokenInformation(
                token,
                TokenIntegrityLevel,
                Some(bytes.as_mut_ptr().cast()),
                size,
                &mut size,
            )
        }
        .is_ok();
        let level = ok
            .then(|| unsafe {
                let label = &*(bytes.as_ptr().cast::<TOKEN_MANDATORY_LABEL>());
                let count =
                    *windows::Win32::Security::GetSidSubAuthorityCount(label.Label.Sid) as u32;
                *windows::Win32::Security::GetSidSubAuthority(label.Label.Sid, count - 1)
            })
            .map(|rid| {
                match rid {
                    0x0000..=0x0fff => "untrusted",
                    0x1000..=0x1fff => "low",
                    0x2000..=0x2fff => "medium",
                    0x3000..=0x3fff => "high",
                    _ => "system",
                }
                .to_string()
            });
        unsafe {
            let _ = CloseHandle(token);
        }
        level
    });
    if let Some(handle) = process {
        unsafe {
            let _ = CloseHandle(handle);
        }
    }
    (path, parent_process_id(pid), integrity)
}

fn identity(pid: u32, window: HWND, task_name: Option<&str>) -> Value {
    let mut owner = 0;
    let gui_thread = unsafe { GetWindowThreadProcessId(window, Some(&mut owner)) };
    let mut session = 0;
    let session_id = unsafe { ProcessIdToSessionId(pid, &mut session) }
        .is_ok()
        .then_some(session);
    let (path, parent, integrity) = process_details(pid);
    let mut class = [0u16; 256];
    let class_len =
        unsafe { windows::Win32::UI::WindowsAndMessaging::GetClassNameW(window, &mut class) };
    let mut title = [0u16; MAX_PATH as usize];
    let title_len =
        unsafe { windows::Win32::UI::WindowsAndMessaging::GetWindowTextW(window, &mut title) };
    json!({"processId":pid,"executablePath":path,"parentProcessId":parent,"sessionId":session_id,"integrityLevel":integrity,
        "window":{"hwnd":format!("0x{:X}",hwnd_bits(window)),"className":wide_text(&class[..class_len.max(0) as usize]),"title":wide_text(&title[..title_len.max(0) as usize]),"guiThreadId":if owner==pid { Some(gui_thread) } else { None }},"taskName":task_name})
}

fn foreground_identity_from(
    owner_pid: u32,
    window: HWND,
    describe: impl FnOnce(u32, HWND, Option<&str>) -> Value,
) -> Value {
    describe(owner_pid, window, None)
}

fn foreground_identity() -> Value {
    let window = unsafe { GetForegroundWindow() };
    let mut owner_pid = 0;
    unsafe { GetWindowThreadProcessId(window, Some(&mut owner_pid)) };
    foreground_identity_from(owner_pid, window, identity)
}

struct Uia {
    automation: IUIAutomation,
}
impl Uia {
    fn new() -> Result<Self, BackendError> {
        unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }
            .ok()
            .map_err(|e| {
                op(
                    "keyboard diagnostic",
                    format!("initialize UI Automation COM: {e}"),
                )
            })?;
        let automation = unsafe { CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER) }
            .map_err(|e| {
                op(
                    "keyboard diagnostic",
                    format!("create UI Automation client: {e}"),
                )
            })?;
        Ok(Self { automation })
    }
    fn focused_element(&self) -> Option<IUIAutomationElement> {
        unsafe { self.automation.GetFocusedElement() }.ok()
    }

    fn describe(&self, element: Option<&IUIAutomationElement>) -> Value {
        let Some(element) = element else {
            return json!({"observed":false,"classification":"unknown"});
        };
        let control = unsafe { element.CurrentControlType() }.ok();
        let automation_id = unsafe { element.CurrentAutomationId() }
            .ok()
            .map(|v: BSTR| v.to_string())
            .unwrap_or_default();
        let class_name = unsafe { element.CurrentClassName() }
            .ok()
            .map(|v: BSTR| v.to_string())
            .unwrap_or_default();
        let name = unsafe { element.CurrentName() }
            .ok()
            .map(|v: BSTR| v.to_string())
            .unwrap_or_default();
        let process_id = unsafe { element.CurrentProcessId() }.ok();
        let classification = if control == Some(UIA_DocumentControlTypeId) {
            "page"
        } else if control == Some(UIA_EditControlTypeId)
            && (automation_id.to_ascii_lowercase().contains("address")
                || name.to_ascii_lowercase().contains("address"))
        {
            "browserChrome"
        } else {
            "other"
        };
        json!({"observed":true,"classification":classification,"processId":process_id,"controlType":control.map(|v|v.0),"automationId":automation_id,"className":class_name,"name":name})
    }
}
impl Drop for Uia {
    fn drop(&mut self) {
        unsafe { CoUninitialize() }
    }
}

pub(super) fn run(args: &[String]) -> Result<Value, BackendError> {
    let pid: u32 = args
        .get(1)
        .ok_or_else(|| op("probe", "missing target-pid"))?
        .parse()
        .map_err(|_| op("probe", "invalid target-pid"))?;
    let max_trials: usize = args
        .iter()
        .position(|a| a == "--max-trials")
        .and_then(|i| args.get(i + 1))
        .map_or(Ok(1), |v| {
            v.parse().map_err(|_| op("probe", "invalid max-trials"))
        })?;
    if !(1..=10).contains(&max_trials) {
        return Err(op("probe", "max-trials must be between 1 and 10"));
    }
    let task_name = args
        .iter()
        .position(|a| a == "--task-name")
        .and_then(|i| args.get(i + 1))
        .map(String::as_str)
        .unwrap_or("Axon Live Probe Keyboard Diagnostic");
    let target_window = unsafe { GetForegroundWindow() };
    let target = json!({"processId":pid,"identity":identity(pid, target_window, None)});
    let observer = Observer::install()?;
    observer.pump(Duration::ZERO);
    let uia = Uia::new()?;
    let mut trials = Vec::new();
    let mut page_focus: Option<IUIAutomationElement> = None;
    for index in 0..max_trials {
        let foreground_before = foreground_identity();
        let started = now_us();
        let activated = super::pixel::activate(pid, None);
        let proved = now_us();
        let setup_focus_restored = if index == 0 {
            true
        } else {
            page_focus
                .as_ref()
                .is_some_and(|element| unsafe { element.SetFocus() }.is_ok())
        };
        if index > 0 {
            observer.pump(Duration::from_millis(50));
            let mut events = EVENTS.get_or_init(Default::default).lock().unwrap();
            events.keyboard.clear();
            events.focus.clear();
            events.overflowed = false;
        }
        let focused_before = uia.focused_element();
        let focus_before = uia.describe(focused_before.as_ref());
        if index == 0 && focus_before["classification"] == "page" {
            page_focus = focused_before;
        }
        let dispatch_started = now_us();
        let ctrl = VirtualKey {
            code: 0x11,
            extended: false,
        };
        let l = VirtualKey {
            code: 0x4c,
            extended: false,
        };
        let inputs = [
            key_input(ctrl, false),
            key_input(l, false),
            key_input(l, true),
            key_input(ctrl, true),
        ];
        let metadata = keyboard_event_metadata(&inputs);
        let result = send_keyboard_batch(
            &inputs,
            KeyboardBatchIntent::NamedChord { events: metadata },
        );
        let returned = now_us();
        let sentinel_key = VirtualKey {
            code: 0x87,
            extended: false,
        };
        let sentinel_inputs = [
            key_input(sentinel_key, false),
            key_input(sentinel_key, true),
        ];
        let sentinel_sent = unsafe {
            SendInput(
                &sentinel_inputs,
                std::mem::size_of_val(&sentinel_inputs[0]) as i32,
            )
        };
        observer.pump(Duration::from_millis(150));
        let focused_after = uia.focused_element();
        let focus_after = uia.describe(focused_after.as_ref());
        let ctrl_l_transition = focus_before["classification"] == "page"
            && focus_after["classification"] == "browserChrome";
        let (keys, focuses, overflowed) = {
            let mut b = EVENTS.get_or_init(Default::default).lock().unwrap();
            (
                std::mem::take(&mut b.keyboard),
                std::mem::take(&mut b.focus),
                b.overflowed,
            )
        };
        let sentinel_observed = keys
            .iter()
            .filter(|event| event.vk == 0x87 && event.flags & 0x10 != 0)
            .count()
            >= 2;
        let hook_events: Vec<_> = keys.iter().map(normalize).collect();
        let focus_events: Vec<_> = focuses.iter().map(|e| json!({"atUs":e.at_us,"hwnd":format!("0x{:X}",e.hwnd),"objectId":e.object_id,"childId":e.child_id,"observerThread":e.thread})).collect();
        let mut timeline = vec![
            json!({"atUs":started,"phase":"activation","source":"native","data":{"started":true}}),
            json!({"atUs":proved,"phase":"stablePrecondition","source":"native","data":{"proved":activated}}),
        ];
        timeline.extend(hook_events.iter().map(
            |e| json!({"atUs":e.at_us,"phase":"injectedStream","source":"WH_KEYBOARD_LL","data":e}),
        ));
        timeline.extend(
            focus_events.iter().map(
                |e| json!({"atUs":e["atUs"],"phase":"edgeFocus","source":"WinEvent","data":e}),
            ),
        );
        let dispatch = match result {
            Ok(d) => {
                json!({"ordinal":1,"intent":"ctrl+l","requestedUs":dispatch_started,"returnedUs":returned,"requestedCount":d.requested_count,"returnedCount":d.returned_count,"snapshots":{"focusProof":d.focus_proof,"beforeSend":d.before_send,"immediatelyAfterSend":d.immediately_after_send,"boundedAfterSend":d.bounded_after_send}})
            }
            Err(e) => {
                json!({"ordinal":1,"intent":"ctrl+l","requestedUs":dispatch_started,"returnedUs":returned,"requestedCount":4,"returnedCount":0,"error":e.to_string(),"snapshots":[]})
            }
        };
        trials.push(json!({"index":index+1,"experiment":"baseline","requestedDelayMs":0,"foregroundBefore":{"identity":foreground_before},"activation":{"startedUs":started,"provedUs":proved,"proof":{"proved":activated}},"setup":{"pageFocusRestored":setup_focus_restored},"dispatches":[dispatch],"hook":{"valid":sentinel_sent == 2 && sentinel_observed,"sentinelObserved":sentinel_observed,"overflowed":overflowed,"events":hook_events},"focusEvents":focus_events,"focus":{"before":focus_before,"after":focus_after,"ctrlLTransitionObserved":ctrl_l_transition},"page":{"observedUs":if focus_before["classification"] == "page" { Some(started) } else { None },"navigated":false,"url":null,"classificationBefore":focus_before["classification"],"browserChromeFocusedAfter":focus_after["classification"] == "browserChrome","outcome":if ctrl_l_transition { "pageToBrowserChrome" } else { "transitionNotObserved" }},"timeline":ordered_timeline(timeline)}));
    }
    let hook_removed = observer.remove();
    Ok(
        json!({"schemaVersion":"keyboard-diagnostic-v1","observer":{"processId":std::process::id(),"taskName":task_name},"target":target,"trials":trials,"finalForeground":{"identity":foreground_identity()},"cleanup":{"hookRemoved":hook_removed,"observerWindowCreated":false,"observerWindowDestroyed":null}}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn foreground_identity_uses_foreground_owner_not_intended_edge_pid() {
        const INTENDED_EDGE_PID: u32 = 6664;
        const FOREGROUND_OWNER_PID: u32 = 7112;

        let identity = foreground_identity_from(
            FOREGROUND_OWNER_PID,
            HWND::default(),
            |pid, _, _| json!({"processId": pid}),
        );

        assert_eq!(identity["processId"], FOREGROUND_OWNER_PID);
        assert_ne!(identity["processId"], INTENDED_EDGE_PID);
    }

    #[test]
    fn normalizes_hook_flags_and_direction() {
        let e = normalize(&RawKeyEvent {
            at_us: 4,
            vk: 76,
            scan: 38,
            flags: 0x12,
            message: WM_KEYUP,
            thread: 9,
        });
        assert!(e.injected);
        assert!(e.lower_integrity_injected);
        assert_eq!(e.direction, "up");
    }
    #[test]
    fn timeline_is_monotonic_and_stable() {
        let got = ordered_timeline(vec![
            json!({"atUs":9,"phase":"b"}),
            json!({"atUs":2,"phase":"a"}),
            json!({"atUs":9,"phase":"c"}),
        ]);
        assert_eq!(
            got.iter()
                .map(|v| v["phase"].as_str().unwrap())
                .collect::<Vec<_>>(),
            vec!["a", "b", "c"]
        );
    }
}
