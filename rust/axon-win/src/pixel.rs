//! The Win32 half of the pixel rung: binding one window to one element's ancestry, proving the
//! boundary between us and it is crossable, and posting client-coordinate messages into it.
//!
//! Everything here is mechanism. The decision about *when* any of it may run lives in the router
//! and is verified against fakes on any machine; this file is what only a Windows machine can
//! check, which is why it is kept as small as the job allows.

use std::{
    ffi::c_void,
    thread,
    time::{Duration, Instant},
};
use windows::{
    Win32::{
        Foundation::{CloseHandle, HANDLE, HWND, LPARAM, POINT, RECT, WPARAM},
        Graphics::Gdi::{ClientToScreen, ScreenToClient},
        Security::{
            GetSidSubAuthority, GetSidSubAuthorityCount, GetTokenInformation,
            TOKEN_MANDATORY_LABEL, TOKEN_QUERY, TokenIntegrityLevel,
        },
        System::{
            SystemServices::MK_LBUTTON,
            Threading::{
                AttachThreadInput, GetCurrentThreadId, OpenProcess, OpenProcessToken,
                PROCESS_QUERY_LIMITED_INFORMATION,
            },
        },
        UI::{
            HiDpi::{
                DPI_AWARENESS_INVALID, DPI_AWARENESS_PER_MONITOR_AWARE,
                GetAwarenessFromDpiAwarenessContext, GetWindowDpiAwarenessContext,
                PhysicalToLogicalPointForPerMonitorDPI,
            },
            WindowsAndMessaging::{
                CWP_SKIPDISABLED, CWP_SKIPINVISIBLE, CWP_SKIPTRANSPARENT, ChildWindowFromPointEx,
                EnumWindows, GA_ROOT, GW_OWNER, GetAncestor, GetClassNameW, GetClientRect,
                GetCursorPos, GetForegroundWindow, GetWindow, GetWindowTextLengthW,
                GetWindowThreadProcessId, IsIconic, IsWindow, IsWindowVisible, SMTO_ABORTIFHUNG,
                SMTO_NORMAL, SendMessageTimeoutW, SetCursorPos, SetForegroundWindow,
                WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MOUSEMOVE,
            },
        },
    },
    core::BOOL,
};

/// Window classes with a live-probed client-coordinate message path, each named alongside the
/// probe run that proved it.
///
/// A class enters this table only after `axon-win probe pixel-click` observed a real state change
/// inside the target while the foreground window and the cursor position were both unchanged. A
/// class absent from it refuses, and a class is never added because it looks like it should work.
///
/// This table is the whole defence against the rung's central failure mode. A window procedure
/// that looks at a click and does nothing returns from it exactly like one that acts on it, so a
/// completed delivery proves the handler ran and never proves it did anything. Without an
/// allowlist built from observed effects, "the message was processed" would quietly stand in for
/// "the control was clicked".
///
/// That failure mode is not hypothetical. `Windows.UI.Core.CoreWindow` — the class hosting every
/// UWP and WinUI surface, Calculator included — takes the entire sequence and does nothing: every
/// message is accepted and the calculator display stays at zero. It is absent from this table for
/// that reason, and rediscovering it is the expensive mistake this note exists to prevent.
pub const PIXEL_MESSAGE_CLASSES: &[(&str, &str)] = &[(
    "Button",
    "charmap 'Advanced view' checkbox on bglab-win: the dialog expanded from 437 to 586 pixels \
     and gained nine controls; GetForegroundWindow (0x003401FC) and GetCursorPos (338, 242) were \
     identical before the delivery, after it, and again once the target had settled; and \
     clientOrigin (34, 449) + windowPoint (96, 10) reconstructed screenPoint (130, 459) exactly",
)];

/// How far the leaf descent may refine before it gives up. Deep child chains exist; unbounded
/// loops over live window trees do not belong in a dispatch path.
const MAX_DESCENT: usize = 16;

/// How far the ancestry walk may climb looking for a native window.
pub const MAX_ANCESTRY: usize = 64;

pub fn hwnd(bits: u64) -> HWND {
    HWND(bits as usize as *mut c_void)
}

pub fn bits(window: HWND) -> u64 {
    window.0 as usize as u64
}

struct OwnedHandle(HANDLE);
impl Drop for OwnedHandle {
    fn drop(&mut self) {
        if !self.0.is_invalid() {
            let _ = unsafe { CloseHandle(self.0) };
        }
    }
}

/// The mandatory integrity level of a process, read as the RID of its token's integrity SID.
fn integrity_level(pid: u32) -> Result<u32, String> {
    unsafe {
        let process =
            OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).map_err(|error| {
                format!(
                    "the target process could not be opened to read its integrity level ({error})"
                )
            })?;
        let _process = OwnedHandle(process);
        let mut token = HANDLE::default();
        OpenProcessToken(process, TOKEN_QUERY, &mut token).map_err(|error| {
            format!(
                "the target process token is not readable, so the integrity boundary cannot be \
                 established ({error})"
            )
        })?;
        let _token = OwnedHandle(token);
        // The sizing call is expected to fail; it exists to report the buffer the label needs.
        let mut needed = 0u32;
        let _ = GetTokenInformation(token, TokenIntegrityLevel, None, 0, &mut needed);
        if needed == 0 {
            return Err("the target process token reported no integrity label".into());
        }
        let mut buffer = vec![0u8; needed as usize];
        GetTokenInformation(
            token,
            TokenIntegrityLevel,
            Some(buffer.as_mut_ptr().cast::<c_void>()),
            needed,
            &mut needed,
        )
        .map_err(|error| {
            format!("the target process integrity label could not be read ({error})")
        })?;
        let label = &*buffer.as_ptr().cast::<TOKEN_MANDATORY_LABEL>();
        let count = GetSidSubAuthorityCount(label.Label.Sid);
        if count.is_null() || *count == 0 {
            return Err("the target process integrity label carries no level".into());
        }
        Ok(*GetSidSubAuthority(label.Label.Sid, (*count - 1) as u32))
    }
}

/// Whether an integrity boundary stands between the daemon and this process, named if it does.
///
/// Refusing here rather than posting is the point: UIPI discards messages from a lower-integrity
/// process into a higher-integrity one silently, so a dispatch across this boundary would report
/// a queue acceptance that Windows had already thrown away.
pub fn integrity_obstacle(pid: u32) -> Option<String> {
    let target = match integrity_level(pid) {
        Ok(level) => level,
        Err(reason) => return Some(reason),
    };
    let ours = match integrity_level(std::process::id()) {
        Ok(level) => level,
        Err(_) => {
            return Some(
                "the daemon's own integrity level could not be read, so the boundary between it \
                 and the target cannot be established"
                    .into(),
            );
        }
    };
    (target > ours).then(|| {
        "the target window runs at a higher integrity level than the daemon; UIPI discards posted \
         input"
            .to_string()
    })
}

fn to_client(window: HWND, point: &mut POINT) -> bool {
    unsafe { ScreenToClient(window, point) }.as_bool()
}

/// Refines a host window down to the leaf that actually owns `point`.
///
/// The descent starts inside ancestry already verified against the captured window and refuses to
/// leave the owning process, so it *refines* a bound target rather than inferring one from a bare
/// screen point — which is the thing the pixel rung is forbidden to do. Chromium is why it has to
/// exist at all: WebView2 content lives in `Chrome_RenderWidgetHostHWND`, and a message posted to
/// the top-level window never reaches it.
fn descend_to_leaf(host: HWND, screen: POINT, pid: u32) -> Result<HWND, String> {
    let mut current = host;
    for _ in 0..MAX_DESCENT {
        let mut local = screen;
        if !to_client(current, &mut local) {
            return Err("the target window's client coordinates could not be computed".into());
        }
        let child = unsafe {
            ChildWindowFromPointEx(
                current,
                local,
                CWP_SKIPINVISIBLE | CWP_SKIPTRANSPARENT | CWP_SKIPDISABLED,
            )
        };
        if child.is_invalid() || child == current {
            return Ok(current);
        }
        let Some(owner) = process_of(child) else {
            return Ok(current);
        };
        if owner != pid {
            // A child hosted by another process is a different target. Refining into it would
            // cross the very boundary the ancestry check was there to establish.
            return Ok(current);
        }
        current = child;
    }
    Ok(current)
}

/// Reconciles a physical screen point with the target window's DPI awareness.
///
/// The daemon runs per-monitor-v2. A window that does not has its coordinates virtualized by
/// Windows, so a physical point has to be converted into that window's logical space before it
/// means anything there. Skipping this is the trap that misses by exactly one scale factor and
/// still looks like a plausible click, which is why the probe has to run at a non-100% scale.
fn logical_point_for(window: HWND, screen: POINT) -> Result<(POINT, &'static str), String> {
    let context = unsafe { GetWindowDpiAwarenessContext(window) };
    let awareness = unsafe { GetAwarenessFromDpiAwarenessContext(context) };
    if awareness == DPI_AWARENESS_INVALID {
        return Err(
            "the target window's DPI awareness could not be read, so its coordinate space is \
             unknown"
                .into(),
        );
    }
    if awareness == DPI_AWARENESS_PER_MONITOR_AWARE {
        return Ok((screen, "perMonitorAware"));
    }
    let mut point = screen;
    if !unsafe { PhysicalToLogicalPointForPerMonitorDPI(Some(window), &mut point) }.as_bool() {
        return Err(
            "the target window's virtualized coordinates could not be reconciled with the \
             daemon's"
                .into(),
        );
    }
    Ok((point, "virtualized"))
}

pub fn class_name(window: HWND) -> String {
    let mut buffer = [0u16; 256];
    let length = unsafe { GetClassNameW(window, &mut buffer) }.max(0) as usize;
    String::from_utf16_lossy(&buffer[..length])
}

/// One window bound to one point, with the transform that reaches it.
pub struct Bound {
    pub window: HWND,
    pub class: String,
    pub client_origin: (f64, f64),
    pub client_point: (f64, f64),
    /// How the target declares its DPI awareness, carried so a probe run can say whether the
    /// reconciliation path was exercised or merely skipped as a no-op.
    pub dpi_awareness: &'static str,
}

/// Resolves the leaf window and client coordinates for a screen point inside a verified host.
///
/// Every refusal names its own obstacle, because "unsupported" tells a caller nothing they can
/// act on and hides the difference between a window Axon has never proven and one it never can.
pub fn bind(
    host: HWND,
    screen: (f64, f64),
    pid: u32,
    allow_unverified_class: bool,
) -> Result<Bound, String> {
    let physical = POINT {
        x: screen.0.round() as i32,
        y: screen.1.round() as i32,
    };
    let window = descend_to_leaf(host, physical, pid)?;
    let class = class_name(window);
    if !allow_unverified_class
        && !PIXEL_MESSAGE_CLASSES
            .iter()
            .any(|(known, _)| *known == class)
    {
        return Err(format!(
            "window class {class} has no probe-verified client-coordinate message path"
        ));
    }
    let (mut client, dpi_awareness) = logical_point_for(window, physical)?;
    if !to_client(window, &mut client) {
        return Err("the target window's client coordinates could not be computed".into());
    }
    let mut origin = POINT::default();
    if !unsafe { ClientToScreen(window, &mut origin) }.as_bool() {
        return Err("the target window's client origin could not be read".into());
    }
    let mut rect = RECT::default();
    unsafe { GetClientRect(window, &mut rect) }.map_err(|error| {
        format!("the target window's client rectangle could not be read ({error})")
    })?;
    if client.x < rect.left
        || client.y < rect.top
        || client.x >= rect.right
        || client.y >= rect.bottom
    {
        return Err("the click point falls outside the target window's client area".into());
    }
    // A window message packs its coordinates into two signed 16-bit fields. A point outside that
    // range does not fail to deliver; it delivers somewhere else entirely.
    let representable = |value: i32| (i16::MIN as i32..=i16::MAX as i32).contains(&value);
    if !representable(client.x) || !representable(client.y) {
        return Err(
            "the client coordinates do not fit the 16-bit fields a window message carries".into(),
        );
    }
    Ok(Bound {
        window,
        class,
        client_origin: (origin.x as f64, origin.y as f64),
        client_point: (client.x as f64, client.y as f64),
        dpi_awareness,
    })
}

/// Re-checks everything the plan asserted about the windows themselves, immediately before
/// anything is posted.
///
/// The transform comparison is the one that earns its place: a window that moved between planning
/// and dispatch still exists, is still visible, and still has the same ancestry, and clicking it
/// at the planned client point would land somewhere the caller never asked for.
pub fn revalidate(target: HWND, root: HWND, client_origin: (f64, f64)) -> Result<(), String> {
    if !unsafe { IsWindow(Some(target)) }.as_bool() {
        return Err("the receiving window no longer exists".into());
    }
    if !unsafe { IsWindow(Some(root)) }.as_bool() {
        return Err("the captured top-level window no longer exists".into());
    }
    if !unsafe { IsWindowVisible(target) }.as_bool() {
        return Err("the receiving window is no longer visible".into());
    }
    if unsafe { IsIconic(root) }.as_bool() {
        return Err("the captured top-level window has been minimized".into());
    }
    if root_of(target) != root {
        return Err(
            "the receiving window is no longer inside the captured top-level window".into(),
        );
    }
    let mut origin = POINT::default();
    if !unsafe { ClientToScreen(target, &mut origin) }.as_bool() {
        return Err("the receiving window's client origin could not be re-read".into());
    }
    if (origin.x as f64, origin.y as f64) != client_origin {
        return Err("the receiving window moved between planning and dispatch".into());
    }
    Ok(())
}

pub struct Delivered {
    pub complete: bool,
    pub partial: Option<String>,
}

/// How long one message is given to be processed by the target's window procedure.
///
/// A bound rather than a hope: a window procedure that enters a modal loop while handling a click
/// would otherwise block the daemon for as long as it liked. A timeout is reported as a failure to
/// deliver, never as a delivery.
const MESSAGE_TIMEOUT_MS: u32 = 1_000;

/// Delivers hover, press, release to one window in its own client coordinates, returning only
/// once the target's window procedure has processed each one.
///
/// `SendMessageTimeoutW` rather than `PostMessageW`, and that difference is the whole reason the
/// invariant checks around this call mean anything. A posted message only enters a queue: the call
/// returns while the target may not have looked at it yet, so reading the foreground and the
/// cursor immediately afterwards samples a moment *before* the handler ran. A window procedure
/// that activates its application or warps the pointer while handling the click would then do so
/// after the daemon had already reported both invariants intact — the published guarantee would be
/// stronger than anything actually observed.
///
/// `SendMessageTimeoutW` is documented not to return until the window procedure has processed the
/// message, which is an explicit completion boundary. State read after it covers the handler
/// rather than racing it.
///
/// A barrier built from `PostMessageW` plus a trailing `SendMessageTimeoutW(WM_NULL)` looks
/// equivalent and is not: `GetMessage` services sent messages ahead of posted ones, so the barrier
/// can be answered before the messages it was meant to be waiting on are dequeued. It is recorded
/// here because it is the obvious thing to reach for next.
///
/// Returning still means processed, never effective. A window procedure is free to look at a click
/// and do nothing, which is why a class earns its allowlist entry by observed state change.
///
/// An `Err` means nothing consequential was delivered. `Ok` with `complete: false` means the press
/// was processed and the release was not, a state the caller has to be told about by name.
pub fn deliver_click(window: HWND, client: POINT) -> Result<Delivered, String> {
    let lparam = LPARAM(
        (((client.y as i16 as u16 as u32) << 16) | (client.x as i16 as u16 as u32)) as isize,
    );
    let send = |message: u32, wparam: WPARAM| {
        let mut answered = 0usize;
        // SMTO_ABORTIFHUNG gives up immediately on a thread that has stopped pumping, rather than
        // spending the whole timeout discovering it.
        let result = unsafe {
            SendMessageTimeoutW(
                window,
                message,
                wparam,
                lparam,
                SMTO_NORMAL | SMTO_ABORTIFHUNG,
                MESSAGE_TIMEOUT_MS,
                Some(&mut answered),
            )
        };
        result.0 != 0
    };
    // Several toolkits only register a click after the window has seen the pointer arrive, and a
    // stray move is harmless if the sequence stops here.
    if !send(WM_MOUSEMOVE, WPARAM(0)) {
        return Err("the target window did not process a pointer-move message".into());
    }
    if !send(WM_LBUTTONDOWN, WPARAM(MK_LBUTTON.0 as usize)) {
        return Err(
            "the target window did not process the button-press message; nothing was delivered"
                .into(),
        );
    }
    if send(WM_LBUTTONUP, WPARAM(0)) {
        return Ok(Delivered {
            complete: true,
            partial: None,
        });
    }
    // Leaving a target believing the button is held is worse than anything this can report, so
    // the release is retried once before the state is admitted to.
    if send(WM_LBUTTONUP, WPARAM(0)) {
        return Ok(Delivered {
            complete: true,
            partial: None,
        });
    }
    Ok(Delivered {
        complete: false,
        partial: Some(
            "the button-release message was not processed after two attempts, and the press was; \
             the target may still consider the left button held"
                .into(),
        ),
    })
}

pub fn foreground_window() -> HWND {
    unsafe { GetForegroundWindow() }
}

/// The top-level window a window belongs to.
pub fn root_of(window: HWND) -> HWND {
    unsafe { GetAncestor(window, GA_ROOT) }
}

pub fn process_of(window: HWND) -> Option<u32> {
    if window.is_invalid() {
        return None;
    }
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(window, Some(&mut pid)) };
    (pid != 0).then_some(pid)
}

pub fn cursor() -> Option<(i32, i32)> {
    let mut point = POINT::default();
    unsafe { GetCursorPos(&mut point) }
        .ok()
        .map(|()| (point.x, point.y))
}

pub fn set_cursor(x: i32, y: i32) -> bool {
    unsafe { SetCursorPos(x, y) }.is_ok()
}

/// Whether a window is the kind a user would recognise as the application — the alt-tab test.
///
/// A process owns far more top-level windows than it shows: tooltips, drop shadows, message-only
/// helpers. Character Map's hover tooltip is one, and it is visible and owned by the same process
/// as the dialog. Activating it instead of the dialog is how a restore silently fails to hand the
/// session back. Owned windows and untitled ones are excluded for the same reason the shell
/// excludes them from alt-tab.
fn is_application_window(window: HWND) -> bool {
    unsafe { IsWindowVisible(window) }.as_bool()
        && unsafe { GetWindow(window, GW_OWNER) }.is_err()
        && unsafe { GetWindowTextLengthW(window) } > 0
}

fn top_level_window_for(pid: u32) -> Option<HWND> {
    struct Search {
        pid: u32,
        found: Option<HWND>,
    }
    unsafe extern "system" fn visit(window: HWND, param: LPARAM) -> BOOL {
        let search = unsafe { &mut *(param.0 as *mut Search) };
        if process_of(window) == Some(search.pid) && is_application_window(window) {
            search.found = Some(window);
            return false.into();
        }
        true.into()
    }
    let mut search = Search { pid, found: None };
    let _ = unsafe { EnumWindows(Some(visit), LPARAM(&mut search as *mut Search as isize)) };
    search.found
}

/// Brings a process's window forward, with the thread-attachment assist.
///
/// `preferred` is the exact window the daemon last saw holding the foreground for this process.
/// It matters on the way back: a process can own several top-level windows, and raising whichever
/// one `EnumWindows` reaches first is not handing the session back to where the user left it. The
/// search is the fallback for when that window is gone.
///
/// `SetForegroundWindow` is restricted: a background process normally gets a flashing taskbar
/// button rather than activation. The daemon temporarily joins both the current and target input
/// queues, retaining the joins until foreground readback observes the target or the bounded wait
/// expires. Both joins are undone on every path — a leaked attachment couples applications' input
/// queues for as long as their processes live.
///
/// The answer is only whether the request was accepted. The transaction proves the outcome by
/// reading the foreground back, so a true here is never taken as proof on its own.
pub fn activate(pid: u32, preferred: Option<HWND>) -> bool {
    let usable = |window: &HWND| {
        unsafe { IsWindow(Some(*window)) }.as_bool()
            && unsafe { IsWindowVisible(*window) }.as_bool()
            && process_of(*window) == Some(pid)
    };
    let Some(target) = preferred
        .filter(usable)
        .or_else(|| top_level_window_for(pid))
    else {
        return false;
    };
    let ours = unsafe { GetCurrentThreadId() };
    let mut attached = Vec::with_capacity(2);
    for window in [foreground_window(), target] {
        if window.is_invalid() {
            continue;
        }
        let thread_id = unsafe { GetWindowThreadProcessId(window, None) };
        if thread_id != 0
            && thread_id != ours
            && !attached.contains(&thread_id)
            && unsafe { AttachThreadInput(ours, thread_id, true) }.as_bool()
        {
            attached.push(thread_id);
        }
    }
    let accepted = unsafe { SetForegroundWindow(target) }.as_bool();
    if accepted {
        let deadline = Instant::now() + Duration::from_millis(250);
        while foreground_window() != target && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
        }
    }
    for thread_id in attached.into_iter().rev() {
        let _ = unsafe { AttachThreadInput(ours, thread_id, false) };
    }
    // Acceptance only. The shared transaction still performs the authoritative foreground proof;
    // this short wait exists solely to retain the input-queue joins while Windows applies the
    // queued activation.
    accepted
}
