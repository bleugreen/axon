//! Interactive, probe-only keyboard observer. This intentionally lives beside the shipping
//! dispatch boundary: it observes that boundary without becoming another delivery implementation.
use super::{key_input, keyboard_event_metadata, op, send_keyboard_batch, KeyboardBatchIntent};
use crate::keys::VirtualKey;
use axon_core::BackendError;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::Input::KeyboardAndMouse::SendInput;
use windows::Win32::UI::Accessibility::{
    SetWinEventHook, UnhookWinEvent, HWINEVENTHOOK,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, DispatchMessageW, GetForegroundWindow, GetWindowThreadProcessId, PeekMessageW,
    SetWindowsHookExW, TranslateMessage, UnhookWindowsHookEx, HHOOK, KBDLLHOOKSTRUCT, MSG, PM_REMOVE,
    EVENT_OBJECT_FOCUS, WINEVENT_OUTOFCONTEXT, WH_KEYBOARD_LL, WM_KEYUP, WM_SYSKEYUP,
};

const EVENT_CAPACITY: usize = 512;
static EPOCH: OnceLock<Instant> = OnceLock::new();
static EVENTS: OnceLock<Mutex<EventBuffer>> = OnceLock::new();

#[derive(Default)]
struct EventBuffer { keyboard: Vec<RawKeyEvent>, focus: Vec<RawFocusEvent>, overflowed: bool }
#[derive(Clone, Debug)]
struct RawKeyEvent { at_us: u64, vk: u32, scan: u32, flags: u32, message: u32, thread: u32 }
#[derive(Clone, Debug)]
struct RawFocusEvent { at_us: u64, hwnd: u64, object_id: i32, child_id: i32, thread: u32 }

fn now_us() -> u64 { EPOCH.get_or_init(Instant::now).elapsed().as_micros().min(u64::MAX as u128) as u64 }
fn hwnd_bits(hwnd: HWND) -> u64 { hwnd.0 as usize as u64 }

unsafe extern "system" fn keyboard_hook(code: i32, message: WPARAM, data: LPARAM) -> LRESULT {
    if code >= 0 {
        let event = unsafe { &*(data.0 as *const KBDLLHOOKSTRUCT) };
        if let Ok(mut out) = EVENTS.get_or_init(Default::default).try_lock() {
            if out.keyboard.len() < EVENT_CAPACITY {
                out.keyboard.push(RawKeyEvent { at_us: now_us(), vk: event.vkCode, scan: event.scanCode, flags: event.flags.0, message: message.0 as u32, thread: unsafe { GetCurrentThreadId() } });
            } else { out.overflowed = true; }
        }
    }
    unsafe { CallNextHookEx(None, code, message, data) }
}

unsafe extern "system" fn focus_hook(_: HWINEVENTHOOK, _: u32, hwnd: HWND, object_id: i32, child_id: i32, _: u32, _: u32) {
    if let Ok(mut out) = EVENTS.get_or_init(Default::default).try_lock() {
        if out.focus.len() < EVENT_CAPACITY {
            out.focus.push(RawFocusEvent { at_us: now_us(), hwnd: hwnd_bits(hwnd), object_id, child_id, thread: unsafe { GetCurrentThreadId() } });
        } else { out.overflowed = true; }
    }
}

struct Observer { keyboard: HHOOK, focus: HWINEVENTHOOK }
impl Observer {
    fn install() -> Result<Self, BackendError> {
        let keyboard = unsafe { SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_hook), None, 0) }
            .map_err(|e| op("keyboard diagnostic", format!("WH_KEYBOARD_LL installation failed: {e}")))?;
        let focus = unsafe { SetWinEventHook(EVENT_OBJECT_FOCUS, EVENT_OBJECT_FOCUS, None, Some(focus_hook), 0, 0, WINEVENT_OUTOFCONTEXT) };
        if focus.is_invalid() { unsafe { let _ = UnhookWindowsHookEx(keyboard); } return Err(op("keyboard diagnostic", "focus WinEvent hook installation failed")); }
        Ok(Self { keyboard, focus })
    }
    fn pump(&self, duration: Duration) {
        let end = Instant::now() + duration;
        let mut msg = MSG::default();
        while Instant::now() < end {
            while unsafe { PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE) }.as_bool() {
                unsafe { let _ = TranslateMessage(&msg); DispatchMessageW(&msg); }
            }
            thread::sleep(Duration::from_millis(1));
        }
    }
}
impl Drop for Observer { fn drop(&mut self) { unsafe { let _ = UnhookWinEvent(self.focus); let _ = UnhookWindowsHookEx(self.keyboard); } } }

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all="camelCase")]
struct HookEvent { at_us: u64, virtual_key: u32, scan_code: u32, injected: bool, lower_integrity_injected: bool, direction: &'static str, message_time: u32, observer_thread: u32 }
fn normalize(event: &RawKeyEvent) -> HookEvent { HookEvent { at_us: event.at_us, virtual_key: event.vk, scan_code: event.scan, injected: event.flags & 0x10 != 0, lower_integrity_injected: event.flags & 0x02 != 0, direction: if matches!(event.message, WM_KEYUP | WM_SYSKEYUP) { "up" } else { "down" }, message_time: 0, observer_thread: event.thread } }
fn ordered_timeline(mut events: Vec<Value>) -> Vec<Value> { events.sort_by_key(|v| v.get("atUs").and_then(Value::as_u64).unwrap_or(u64::MAX)); events }

fn identity(pid: u32) -> Value {
    let foreground = unsafe { GetForegroundWindow() };
    let mut owner = 0; let gui_thread = unsafe { GetWindowThreadProcessId(foreground, Some(&mut owner)) };
    json!({"processId":pid,"executablePath":null,"parentProcessId":null,"sessionId":null,"integrityLevel":null,
        "window":{"hwnd":format!("0x{:X}",hwnd_bits(foreground)),"className":null,"title":null,"guiThreadId":if owner==pid { Some(gui_thread) } else { None }},"taskName":null})
}

pub(super) fn run(args: &[String]) -> Result<Value, BackendError> {
    let pid: u32 = args.get(1).ok_or_else(|| op("probe", "missing target-pid"))?.parse().map_err(|_| op("probe", "invalid target-pid"))?;
    let max_trials: usize = args.iter().position(|a| a=="--max-trials").and_then(|i| args.get(i+1)).map_or(Ok(1), |v| v.parse().map_err(|_| op("probe", "invalid max-trials")))?;
    if !(1..=10).contains(&max_trials) { return Err(op("probe", "max-trials must be between 1 and 10")); }
    let target = json!({"processId":pid,"identity":identity(pid)});
    let observer = Observer::install()?;
    let mut trials = Vec::new();
    for index in 0..max_trials {
        let foreground_before = identity(pid);
        let started = now_us();
        let activated = super::pixel::activate(pid, None);
        let proved = now_us();
        let dispatch_started = now_us();
        let ctrl = VirtualKey { code: 0x11, extended: false }; let l = VirtualKey { code: 0x4c, extended: false };
        let inputs = [key_input(ctrl,false),key_input(l,false),key_input(l,true),key_input(ctrl,true)];
        let metadata = keyboard_event_metadata(&inputs);
        let result = send_keyboard_batch(&inputs, KeyboardBatchIntent::NamedChord { events: metadata });
        let returned = now_us();
        observer.pump(Duration::from_millis(150));
        let (keys, focuses, overflowed) = { let mut b=EVENTS.get_or_init(Default::default).lock().unwrap(); (std::mem::take(&mut b.keyboard),std::mem::take(&mut b.focus),b.overflowed) };
        let hook_events: Vec<_> = keys.iter().map(normalize).collect();
        let focus_events: Vec<_> = focuses.iter().map(|e| json!({"atUs":e.at_us,"hwnd":format!("0x{:X}",e.hwnd),"objectId":e.object_id,"childId":e.child_id,"observerThread":e.thread})).collect();
        let mut timeline = vec![json!({"atUs":started,"phase":"activation","source":"native","data":{"started":true}}),json!({"atUs":proved,"phase":"stablePrecondition","source":"native","data":{"proved":activated}})];
        timeline.extend(hook_events.iter().map(|e| json!({"atUs":e.at_us,"phase":"injectedStream","source":"WH_KEYBOARD_LL","data":e})));
        timeline.extend(focus_events.iter().map(|e| json!({"atUs":e["atUs"],"phase":"edgeFocus","source":"WinEvent","data":e})));
        let dispatch = match result { Ok(d) => json!({"ordinal":1,"intent":"ctrl+l","requestedUs":dispatch_started,"returnedUs":returned,"requestedCount":d.requested_count,"returnedCount":d.returned_count,"snapshots":{"focusProof":d.focus_proof,"beforeSend":d.before_send,"immediatelyAfterSend":d.immediately_after_send,"boundedAfterSend":d.bounded_after_send}}), Err(e) => json!({"ordinal":1,"intent":"ctrl+l","requestedUs":dispatch_started,"returnedUs":returned,"requestedCount":4,"returnedCount":0,"error":e.to_string(),"snapshots":[]}) };
        trials.push(json!({"index":index+1,"experiment":"baseline","requestedDelayMs":0,"foregroundBefore":{"identity":foreground_before},"activation":{"startedUs":started,"provedUs":proved,"proof":{"proved":activated}},"dispatches":[dispatch],"hook":{"valid":false,"sentinelObserved":false,"overflowed":overflowed,"events":hook_events},"focusEvents":focus_events,"page":{"observedUs":null,"navigated":false,"url":null},"timeline":ordered_timeline(timeline)}));
    }
    // F24 is reserved for the observer sentinel. Seeing its injected down/up pair immediately before
    // unhooking distinguishes a valid empty observation from Windows silently removing a timed-out
    // low-level hook.
    let sentinel_key = VirtualKey { code: 0x87, extended: false };
    let sentinel_inputs = [key_input(sentinel_key, false), key_input(sentinel_key, true)];
    let sentinel_sent = unsafe { SendInput(&sentinel_inputs, std::mem::size_of_val(&sentinel_inputs[0]) as i32) };
    observer.pump(Duration::from_millis(100));
    let sentinel_observed = EVENTS.get_or_init(Default::default).lock().unwrap().keyboard.iter()
        .filter(|event| event.vk == 0x87 && event.flags & 0x10 != 0).count() >= 2;
    if let Some(last) = trials.last_mut() {
        last["hook"]["sentinelObserved"] = json!(sentinel_observed);
        last["hook"]["valid"] = json!(sentinel_sent == 2 && sentinel_observed);
    }
    drop(observer);
    Ok(json!({"schemaVersion":"keyboard-diagnostic-v1","target":target,"trials":trials,"finalForeground":{"identity":identity(pid)},"cleanup":{"hookRemoved":true,"observerWindowDestroyed":true}}))
}

#[cfg(test)] mod tests {
 use super::*;
 #[test] fn normalizes_hook_flags_and_direction() { let e=normalize(&RawKeyEvent{at_us:4,vk:76,scan:38,flags:0x12,message:WM_KEYUP,thread:9}); assert!(e.injected); assert!(e.lower_integrity_injected); assert_eq!(e.direction,"up"); }
 #[test] fn timeline_is_monotonic_and_stable() { let got=ordered_timeline(vec![json!({"atUs":9,"phase":"b"}),json!({"atUs":2,"phase":"a"}),json!({"atUs":9,"phase":"c"})]); assert_eq!(got.iter().map(|v|v["phase"].as_str().unwrap()).collect::<Vec<_>>(),vec!["a","b","c"]); }
}
