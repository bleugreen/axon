use crate::{
    BackgroundPixelPointer, PixelDispatch, PixelDispatchError, PixelPlan, PixelTarget,
    PointerTargetVerifier, VisualObservation, VisualObservationProvider,
};
use axon_core::{
    AppQuery, Application, BackendError, Capability, CapabilityInfo, ForegroundTarget,
    KeyboardIntent, Node, Observation, PlatformBackend, RecognizedText, RecordedCall, Rect,
    Screenshot, Snapshot, SnapshotHandle, TextRecognitionProvider, Window, dispatch_in_foreground,
};

#[path = "capture.rs"]
mod graphics_capture;
#[path = "pixel.rs"]
mod pixel;
use std::{
    ffi::c_void,
    sync::{Arc, mpsc},
    thread,
    time::{Duration, Instant},
};
use windows::{
    Win32::{
        Foundation::{HWND, POINT},
        System::{
            Com::{
                CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx,
                CoUninitialize,
            },
            Variant::VARIANT,
        },
        UI::{
            Accessibility::{
                AutomationElementMode_Full, CUIAutomation, CUIAutomation8, IUIAutomation,
                IUIAutomation2, IUIAutomationCacheRequest, IUIAutomationElement,
                IUIAutomationEventHandler, IUIAutomationEventHandler_Impl,
                IUIAutomationFocusChangedEventHandler, IUIAutomationFocusChangedEventHandler_Impl,
                IUIAutomationInvokePattern, IUIAutomationScrollItemPattern,
                IUIAutomationStructureChangedEventHandler,
                IUIAutomationStructureChangedEventHandler_Impl, IUIAutomationValuePattern,
                StructureChangeType, TreeScope_Children, TreeScope_Descendants, TreeScope_Element,
                UIA_AutomationIdPropertyId, UIA_BoundingRectanglePropertyId,
                UIA_ButtonControlTypeId, UIA_CheckBoxControlTypeId, UIA_ComboBoxControlTypeId,
                UIA_ControlTypePropertyId, UIA_CustomControlTypeId, UIA_DocumentControlTypeId,
                UIA_EditControlTypeId, UIA_GroupControlTypeId, UIA_HyperlinkControlTypeId,
                UIA_ImageControlTypeId, UIA_InvokePatternId, UIA_ListControlTypeId,
                UIA_ListItemControlTypeId, UIA_MenuControlTypeId, UIA_MenuItemControlTypeId,
                UIA_NamePropertyId, UIA_PaneControlTypeId, UIA_ProgressBarControlTypeId,
                UIA_RadioButtonControlTypeId, UIA_ScrollBarControlTypeId, UIA_ScrollItemPatternId,
                UIA_SliderControlTypeId, UIA_TabControlTypeId, UIA_TabItemControlTypeId,
                UIA_Text_TextChangedEventId, UIA_TextControlTypeId, UIA_ThumbControlTypeId,
                UIA_ToolBarControlTypeId, UIA_ToolTipControlTypeId, UIA_TreeControlTypeId,
                UIA_TreeItemControlTypeId, UIA_ValuePatternId, UIA_WindowControlTypeId,
            },
            HiDpi::{DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetProcessDpiAwarenessContext},
            Input::KeyboardAndMouse::{
                INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT, KEYEVENTF_KEYUP,
                KEYEVENTF_UNICODE, MOUSEEVENTF_ABSOLUTE, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP,
                MOUSEEVENTF_MOVE, MOUSEEVENTF_VIRTUALDESK, MOUSEINPUT, SendInput, VIRTUAL_KEY,
            },
            WindowsAndMessaging::{
                GetSystemMetrics, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN,
                SM_YVIRTUALSCREEN,
            },
        },
    },
    core::{BSTR, Interface, Ref, Result as WinResult, implement},
};

const MAX_DEPTH: usize = 18;
const MAX_CHILDREN: usize = 200;
const MAX_NODES: usize = 2_000;

enum Command {
    Enumerate(mpsc::Sender<Result<Vec<Application>, BackendError>>),
    Capture(AppQuery, mpsc::Sender<Result<Snapshot, BackendError>>),
    Screenshot(AppQuery, mpsc::Sender<Result<Screenshot, BackendError>>),
    RecognizeText(
        AppQuery,
        mpsc::Sender<Result<Vec<graphics_capture::OcrWord>, BackendError>>,
    ),
    ObserveVisuals(
        AppQuery,
        bool,
        bool,
        mpsc::Sender<Result<VisualObservation, BackendError>>,
    ),
    VerifyOcrTarget(
        AppQuery,
        (f64, f64),
        Rect,
        mpsc::Sender<Result<bool, BackendError>>,
    ),
    Invoke(SnapshotHandle, mpsc::Sender<Result<(), BackendError>>),
    Read(
        SnapshotHandle,
        mpsc::Sender<Result<Option<String>, BackendError>>,
    ),
    Set(
        SnapshotHandle,
        String,
        mpsc::Sender<Result<(), BackendError>>,
    ),
    Focus(SnapshotHandle, mpsc::Sender<Result<(), BackendError>>),
    Scroll(SnapshotHandle, mpsc::Sender<Result<(), BackendError>>),
    Hit((f64, f64), mpsc::Sender<Result<Option<Node>, BackendError>>),
    VerifyPointerTarget(
        SnapshotHandle,
        (f64, f64),
        mpsc::Sender<Result<bool, BackendError>>,
    ),
    PlanPixelClick(
        SnapshotHandle,
        (f64, f64),
        mpsc::Sender<Result<PixelPlan, BackendError>>,
    ),
    DispatchPixelClick(
        PixelTarget,
        mpsc::Sender<Result<Result<PixelDispatch, PixelDispatchError>, BackendError>>,
    ),
    /// Probe-only: lets `axon-win probe pixel-click` reach a class the allowlist has not yet
    /// accepted, which is how a class becomes a candidate for it in the first place.
    AllowUnverifiedPixelClasses(bool, mpsc::Sender<Result<(), BackendError>>),
}

impl VisualObservationProvider for WindowsBackend {
    fn observe_visuals(
        &mut self,
        q: &AppQuery,
        screenshot: bool,
        screen_text: bool,
    ) -> Result<VisualObservation, BackendError> {
        self.call(|tx| Command::ObserveVisuals(q.clone(), screenshot, screen_text, tx))
    }
}

impl TextRecognitionProvider for WindowsBackend {
    fn recognize_text(&mut self, q: &AppQuery) -> Result<Vec<RecognizedText>, BackendError> {
        self.recognize_window_text(q).map(|words| {
            words
                .into_iter()
                .map(|word| RecognizedText {
                    text: word.text,
                    frame: word.frame,
                    confidence: None,
                })
                .collect()
        })
    }
}

impl WindowsBackend {
    pub fn recognize_window_text(
        &mut self,
        q: &AppQuery,
    ) -> Result<Vec<graphics_capture::OcrWord>, BackendError> {
        self.call(|tx| Command::RecognizeText(q.clone(), tx))
    }
}

fn normalize_virtual_desktop_point(
    (x, y): (f64, f64),
    (origin_x, origin_y): (i32, i32),
    (width, height): (i32, i32),
) -> (i32, i32) {
    fn axis(value: f64, origin: i32, extent: i32) -> i32 {
        if extent <= 1 {
            return 0;
        }
        (((value - f64::from(origin)) * 65535.0 / f64::from(extent - 1)).round())
            .clamp(0.0, 65535.0) as i32
    }
    (axis(x, origin_x, width), axis(y, origin_y, height))
}

#[cfg(test)]
mod tests {
    use super::normalize_virtual_desktop_point;

    #[test]
    fn virtual_desktop_normalization_accounts_for_negative_origin_and_endpoints() {
        let origin = (-1920, -1080);
        let size = (3840, 2160);
        assert_eq!(
            normalize_virtual_desktop_point((-1920.0, -1080.0), origin, size),
            (0, 0)
        );
        assert_eq!(
            normalize_virtual_desktop_point((1919.0, 1079.0), origin, size),
            (65535, 65535)
        );
    }

    #[test]
    fn virtual_desktop_normalization_accounts_for_nonzero_positive_origin() {
        let origin = (100, 200);
        let size = (101, 201);
        assert_eq!(
            normalize_virtual_desktop_point((100.0, 200.0), origin, size),
            (0, 0)
        );
        assert_eq!(
            normalize_virtual_desktop_point((200.0, 400.0), origin, size),
            (65535, 65535)
        );
    }
}

impl PointerTargetVerifier for WindowsBackend {
    fn verify_pointer_target(
        &mut self,
        handle: &SnapshotHandle,
        point: (f64, f64),
    ) -> Result<bool, BackendError> {
        self.call(|tx| Command::VerifyPointerTarget(handle.clone(), point, tx))
    }

    fn verify_ocr_target(
        &mut self,
        app: &AppQuery,
        point: (f64, f64),
        frame: Rect,
    ) -> Result<bool, BackendError> {
        self.call(|tx| Command::VerifyOcrTarget(app.clone(), point, frame, tx))
    }
}

pub struct WindowsBackend {
    tx: Option<mpsc::Sender<Command>>,
    thread: Option<thread::JoinHandle<()>>,
    /// The window last seen holding the foreground, per process that owned it.
    ///
    /// The transaction's identity vocabulary is the process id, which is what lets a macOS, Linux,
    /// and Windows refusal be one contract. But a process owns several top-level windows, and
    /// restoring "some window of that process" is not handing the session back to where the user
    /// left it. Remembering the window the foreground was actually taken from closes that gap
    /// without widening the shared vocabulary.
    ///
    /// Keyed by process rather than held as a single slot, because one transaction reads the
    /// foreground several times — before activating, to prove activation, and again to restore —
    /// and a single slot is overwritten by the target long before the prior application needs it
    /// back.
    last_foreground: std::collections::HashMap<u32, u64>,
}

impl WindowsBackend {
    pub fn start() -> Result<Self, BackendError> {
        Self::start_with_logger(|_| {})
    }

    pub fn start_with_logger(
        log: impl Fn(&str) + Send + Sync + 'static,
    ) -> Result<Self, BackendError> {
        let log = Arc::new(log);
        log("DPI awareness: begin");
        if let Err(error) =
            unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) }
        {
            let message = format!(
                "WARNING: per-monitor DPI awareness unavailable; coordinate accuracy may be reduced: {error}"
            );
            eprintln!("axon-win: {message}");
            log(&message);
        } else {
            log("DPI awareness: complete");
        }
        let (tx, rx) = mpsc::channel();
        let (ready_tx, ready_rx) = mpsc::sync_channel(1);
        let thread_log = Arc::clone(&log);
        log("UIA thread spawn: begin");
        let thread = thread::Builder::new()
            .name("axon-uia-mta".into())
            .spawn(move || {
                let result = UiaState::new(|stage| thread_log(stage));
                if let Err(error) = &result {
                    thread_log(&format!("UIA initialization: failed: {error}"));
                }
                let _ = ready_tx.send(result.as_ref().map(|_| ()).map_err(CloneError::from));
                let Ok(mut state) = result else { return };
                while let Ok(command) = rx.recv() {
                    state.execute(command);
                }
            })
            .map_err(|e| op("start UIA thread", e.to_string()))?;
        log("UIA thread readiness: waiting");
        match ready_rx.recv_timeout(Duration::from_secs(30)) {
            Ok(result) => result.map_err(BackendError::from)?,
            Err(error) => {
                log(&format!(
                    "UIA thread readiness: failed after 30000 ms: {error}"
                ));
                return Err(op("start UIA thread", error.to_string()));
            }
        }
        log("UIA thread readiness: complete");
        Ok(Self {
            tx: Some(tx),
            thread: Some(thread),
            last_foreground: std::collections::HashMap::new(),
        })
    }
}
impl Drop for WindowsBackend {
    fn drop(&mut self) {
        // Closing the command channel makes the MTA thread drop UiaState and its
        // COM apartment before the daemon reports a clean process exit.
        self.tx.take();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}
fn immediate_node(e: &IUIAutomationElement) -> Result<Node, BackendError> {
    let ct = unsafe { e.CurrentControlType() }.map_err(|e| operation("read hit ControlType", e))?;
    let text = |value: windows::core::Result<BSTR>| {
        value.ok().map(|x| x.to_string()).filter(|x| !x.is_empty())
    };
    let name = text(unsafe { e.CurrentName() });
    let r = unsafe { e.CurrentBoundingRectangle() }.ok();
    Ok(Node {
        role: control_type_name(ct.0).into(),
        subrole: None,
        name: name.clone(),
        title: name.clone(),
        label: name,
        value: None,
        description: None,
        identifier: text(unsafe { e.CurrentAutomationId() }),
        actions: vec![],
        frame: r.map(|x| Rect {
            x: x.left as f64,
            y: x.top as f64,
            width: (x.right - x.left) as f64,
            height: (x.bottom - x.top) as f64,
        }),
        editable: ct == UIA_EditControlTypeId || ct == UIA_DocumentControlTypeId,
        focused: unsafe { e.CurrentHasKeyboardFocus() }.ok().map(bool::from),
        enabled: unsafe { e.CurrentIsEnabled() }.ok().map(bool::from),
        children: vec![],
        child_count: None,
        truncation_reason: None,
    })
}
impl WindowsBackend {
    fn call<T>(
        &self,
        make: impl FnOnce(mpsc::Sender<Result<T, BackendError>>) -> Command,
    ) -> Result<T, BackendError> {
        let (tx, rx) = mpsc::channel();
        self.tx
            .as_ref()
            .expect("UIA command channel is available until backend drop")
            .send(make(tx))
            .map_err(|e| op("send UIA command", e.to_string()))?;
        rx.recv()
            .map_err(|e| op("receive UIA result", e.to_string()))?
    }
}

struct UiaState {
    automation: IUIAutomation,
    snapshot: Option<Snapshot>,
    elements: Vec<IUIAutomationElement>,
    /// The top-level window the last capture came from. A pixel plan is only allowed to bind a
    /// window inside this one; without it there is no verified ancestry and no plan.
    capture_window: Option<u64>,
    allow_unverified_pixel_classes: bool,
    _com: ComApartment,
}
impl UiaState {
    fn new(log: impl Fn(&str)) -> Result<Self, BackendError> {
        log("COM MTA initialization: begin");
        let com = ComApartment::mta()?;
        log("COM MTA initialization: complete");
        log("UI Automation client creation: begin");
        let automation = create_automation()?;
        log("UI Automation client creation: complete");
        // Provider timeouts improve resilience but are not a prerequisite for UIA itself.
        // Older providers may expose only IUIAutomation; service startup must still work.
        if let Ok(automation2) = automation.cast::<IUIAutomation2>() {
            log("UI Automation timeout setup: begin");
            unsafe {
                automation2
                    .SetConnectionTimeout(1500)
                    .map_err(|e| operation("set UIA connection timeout", e))?;
                automation2
                    .SetTransactionTimeout(1500)
                    .map_err(|e| operation("set UIA transaction timeout", e))?;
            }
            log("UI Automation timeout setup: complete");
        } else {
            log("UI Automation timeout setup: skipped (IUIAutomation2 unavailable)");
        }
        Ok(Self {
            automation,
            snapshot: None,
            elements: vec![],
            capture_window: None,
            allow_unverified_pixel_classes: false,
            _com: com,
        })
    }
    fn execute(&mut self, command: Command) {
        match command {
            Command::Enumerate(tx) => {
                let _ = tx.send(self.enumerate());
            }
            Command::Capture(q, tx) => {
                let _ = tx.send(self.capture(q));
            }
            Command::Screenshot(q, tx) => {
                let _ = tx.send(
                    self.capture_graphics(q)
                        .and_then(|captured| graphics_capture::screenshot(&captured)),
                );
            }
            Command::RecognizeText(q, tx) => {
                let _ = tx.send(
                    self.capture_graphics(q)
                        .and_then(|captured| graphics_capture::ocr(&captured)),
                );
            }
            Command::ObserveVisuals(q, wants_screenshot, wants_screen_text, tx) => {
                let result = self.capture_graphics(q).and_then(|captured| {
                    let screenshot = wants_screenshot
                        .then(|| graphics_capture::screenshot(&captured))
                        .transpose()?;
                    let recognized_text = wants_screen_text
                        .then(|| graphics_capture::ocr(&captured))
                        .transpose()?
                        .map(|words| {
                            words
                                .into_iter()
                                .map(|word| RecognizedText {
                                    text: word.text,
                                    frame: word.frame,
                                    confidence: None,
                                })
                                .collect()
                        });
                    Ok(VisualObservation {
                        screenshot,
                        recognized_text,
                    })
                });
                let _ = tx.send(result);
            }
            Command::Invoke(h, tx) => {
                let _ = tx.send(self.element(&h).and_then(|e| {
                    let p: IUIAutomationInvokePattern =
                        unsafe { e.GetCurrentPatternAs(UIA_InvokePatternId) }
                            .map_err(|e| operation("get InvokePattern", e))?;
                    unsafe { p.Invoke() }.map_err(|e| operation("invoke", e))
                }));
            }
            Command::VerifyPointerTarget(handle, (x, y), tx) => {
                let result = self.element(&handle).and_then(|target| {
                    let hit = unsafe {
                        self.automation.ElementFromPoint(POINT {
                            x: x.round() as i32,
                            y: y.round() as i32,
                        })
                    }
                    .map_err(|e| operation("hit test", e))?;
                    unsafe { self.automation.CompareElements(&target, &hit) }
                        .map(|same| same.as_bool())
                        .map_err(|e| operation("compare pointer target identity", e))
                });
                let _ = tx.send(result);
            }
            Command::VerifyOcrTarget(q, (x, y), frame, tx) => {
                let result =
                    self.find_window(&q, "verify OCR pointer target")
                        .and_then(|(window, _)| {
                            if x < frame.x
                                || y < frame.y
                                || x > frame.x + frame.width
                                || y > frame.y + frame.height
                            {
                                return Ok(false);
                            }
                            let hit = self.element_at((x, y))?;
                            self.contains(&window, hit)
                        });
                let _ = tx.send(result);
            }
            Command::Hit((x, y), tx) => {
                let _ = tx.send(
                    unsafe {
                        self.automation.ElementFromPoint(POINT {
                            x: x.round() as i32,
                            y: y.round() as i32,
                        })
                    }
                    .map_err(|e| operation("hit test", e))
                    .and_then(|element| immediate_node(&element).map(Some)),
                );
            }
            Command::Read(h, tx) => {
                let _ = tx.send(self.element(&h).and_then(|e| {
                    let p: IUIAutomationValuePattern =
                        unsafe { e.GetCurrentPatternAs(UIA_ValuePatternId) }
                            .map_err(|e| operation("get ValuePattern", e))?;
                    unsafe { p.CurrentValue() }
                        .map(|v| Some(v.to_string()))
                        .map_err(|e| operation("read value", e))
                }));
            }
            Command::Set(h, v, tx) => {
                let _ = tx.send(self.element(&h).and_then(|e| {
                    let p: IUIAutomationValuePattern =
                        unsafe { e.GetCurrentPatternAs(UIA_ValuePatternId) }
                            .map_err(|e| operation("get ValuePattern", e))?;
                    unsafe { p.SetValue(&BSTR::from(v)) }.map_err(|e| operation("set value", e))
                }));
            }
            Command::Focus(h, tx) => {
                let _ =
                    tx.send(self.element(&h).and_then(|e| {
                        unsafe { e.SetFocus() }.map_err(|e| operation("set focus", e))
                    }));
            }
            Command::Scroll(h, tx) => {
                let _ = tx.send(self.element(&h).and_then(|e| {
                    let p: IUIAutomationScrollItemPattern =
                        unsafe { e.GetCurrentPatternAs(UIA_ScrollItemPatternId) }
                            .map_err(|e| operation("get ScrollItemPattern", e))?;
                    unsafe { p.ScrollIntoView() }.map_err(|e| operation("scroll into view", e))
                }));
            }
            Command::PlanPixelClick(handle, point, tx) => {
                let _ = tx.send(self.plan_pixel_click(&handle, point));
            }
            Command::DispatchPixelClick(target, tx) => {
                let _ = tx.send(Ok(self.dispatch_pixel_click(&target)));
            }
            Command::AllowUnverifiedPixelClasses(allow, tx) => {
                self.allow_unverified_pixel_classes = allow;
                let _ = tx.send(Ok(()));
            }
        }
    }

    /// Whether `hit` is `ancestor` or sits underneath it in the control view.
    ///
    /// One walk shared by every check that has to answer "is what is at this point still the thing
    /// we resolved": the OCR frame check, and the pixel rung's revalidation.
    fn contains(
        &self,
        ancestor: &IUIAutomationElement,
        hit: IUIAutomationElement,
    ) -> Result<bool, BackendError> {
        let walker = unsafe { self.automation.ControlViewWalker() }
            .map_err(|e| operation("get UIA control walker", e))?;
        let mut current = Some(hit);
        for _ in 0..pixel::MAX_ANCESTRY {
            let Some(element) = current else {
                return Ok(false);
            };
            if unsafe { self.automation.CompareElements(ancestor, &element) }
                .map_err(|e| operation("compare target ancestry", e))?
                .as_bool()
            {
                return Ok(true);
            }
            current = unsafe { walker.GetParentElement(&element) }.ok();
        }
        Ok(false)
    }

    fn element_at(&self, (x, y): (f64, f64)) -> Result<IUIAutomationElement, BackendError> {
        unsafe {
            self.automation.ElementFromPoint(POINT {
                x: x.round() as i32,
                y: y.round() as i32,
            })
        }
        .map_err(|e| operation("hit test", e))
    }

    /// The nearest ancestor that owns a native window, walked through the control view.
    fn host_window(&self, element: &IUIAutomationElement) -> Result<Option<HWND>, BackendError> {
        let walker = unsafe { self.automation.ControlViewWalker() }
            .map_err(|e| operation("get UIA control walker", e))?;
        let mut current = Some(element.clone());
        for _ in 0..pixel::MAX_ANCESTRY {
            let Some(node) = current else {
                return Ok(None);
            };
            if let Ok(native) = unsafe { node.CurrentNativeWindowHandle() }
                && !native.is_invalid()
            {
                return Ok(Some(native));
            }
            current = unsafe { walker.GetParentElement(&node) }.ok();
        }
        Ok(None)
    }

    /// Binds one click to one window, or names why it cannot be bound.
    ///
    /// Pure inspection throughout: the planner that calls this may discard the answer and refuse,
    /// so by the time a rung is chosen nothing native may have happened.
    fn plan_pixel_click(
        &mut self,
        handle: &SnapshotHandle,
        point: (f64, f64),
    ) -> Result<PixelPlan, BackendError> {
        let Some(root) = self.capture_window.map(pixel::hwnd) else {
            return Ok(PixelPlan::unavailable(
                "no window has been captured, so there is no verified ancestry to bind this click \
                 to",
            ));
        };
        let element = self.element(handle)?;
        let Some(host) = self.host_window(&element)? else {
            return Ok(PixelPlan::unavailable(
                "the resolved element has no native window in its accessibility ancestry",
            ));
        };
        // The invariant that forbids inferring a window from an unscoped point: the window this
        // binds to has to be the one the caller already captured and resolved against.
        if pixel::root_of(host) != root {
            return Ok(PixelPlan::unavailable(
                "the resolved element's native window is not inside the captured window",
            ));
        }
        let Some(pid) = pixel::process_of(host) else {
            return Ok(PixelPlan::unavailable(
                "the target window's owning process could not be read",
            ));
        };
        if let Some(reason) = pixel::integrity_obstacle(pid) {
            return Ok(PixelPlan::blocked(reason));
        }
        Ok(
            match pixel::bind(host, point, pid, self.allow_unverified_pixel_classes) {
                Err(reason) => PixelPlan::unavailable(reason),
                Ok(bound) => PixelPlan::Bound(PixelTarget {
                    handle: handle.clone(),
                    window: pixel::bits(bound.window),
                    window_class: bound.class,
                    dpi_awareness: bound.dpi_awareness,
                    root_window: pixel::bits(root),
                    process_identifier: pid as i64,
                    screen_point: point,
                    client_origin: bound.client_origin,
                    client_point: bound.client_point,
                }),
            },
        )
    }

    /// Revalidates a plan and posts it, in that order and with nothing in between.
    fn dispatch_pixel_click(
        &mut self,
        target: &PixelTarget,
    ) -> Result<PixelDispatch, PixelDispatchError> {
        let window = pixel::hwnd(target.window);
        let root = pixel::hwnd(target.root_window);
        pixel::revalidate(window, root, target.client_origin).map_err(PixelDispatchError::Stale)?;
        let element = self
            .element(&target.handle)
            .map_err(PixelDispatchError::Backend)?;
        let hit = self
            .element_at(target.screen_point)
            .map_err(PixelDispatchError::Backend)?;
        if !self
            .contains(&element, hit)
            .map_err(PixelDispatchError::Backend)?
        {
            return Err(PixelDispatchError::Stale(
                "the resolved element is no longer under the planned point".into(),
            ));
        }
        // The invariants are read either side of a delivery that has an explicit end: the call
        // below returns only once the target's window procedure has processed each message, so
        // what follows observes the handler rather than racing it. With a posted sequence these
        // two comparisons would straddle nothing at all.
        let frontmost_before = pixel::foreground_window();
        let cursor_before = pixel::cursor();
        let delivered = pixel::deliver_click(
            window,
            POINT {
                x: target.client_point.0 as i32,
                y: target.client_point.1 as i32,
            },
        )
        .map_err(|message| PixelDispatchError::Backend(op("deliver pixel click", message)))?;
        Ok(PixelDispatch {
            complete: delivered.complete,
            partial: delivered.partial,
            frontmost_unchanged: pixel::foreground_window() == frontmost_before,
            pointer_unchanged: pixel::cursor() == cursor_before,
        })
    }
    fn top_level(&self) -> Result<Vec<IUIAutomationElement>, BackendError> {
        let root = unsafe { self.automation.GetRootElement() }
            .map_err(|e| operation("get desktop root", e))?;
        let c = unsafe { self.automation.CreateTrueCondition() }
            .map_err(|e| operation("create condition", e))?;
        let a = unsafe { root.FindAll(TreeScope_Children, &c) }
            .map_err(|e| operation("enumerate windows", e))?;
        let n = unsafe { a.Length() }.map_err(|e| operation("read window count", e))?;
        (0..n)
            .map(|i| unsafe { a.GetElement(i) }.map_err(|e| operation("read window", e)))
            .collect()
    }
    fn enumerate(&self) -> Result<Vec<Application>, BackendError> {
        Ok(self
            .top_level()?
            .into_iter()
            .filter_map(|e| {
                let name = unsafe { e.CurrentName() }.ok()?.to_string();
                (!name.is_empty()).then(|| Application {
                    process_id: unsafe { e.CurrentProcessId() }.ok(),
                    name,
                    identifier: None,
                    windows: vec![],
                })
            })
            .collect())
    }
    fn capture(&mut self, q: AppQuery) -> Result<Snapshot, BackendError> {
        let (window, query) = self.find_window(&q, "capture")?;
        if let Ok(hwnd) = unsafe { window.CurrentNativeWindowHandle() } {
            msaa::activate(hwnd.0 as isize);
        }
        // Recorded here and nowhere else: the pixel rung binds only inside the window a caller
        // actually captured, so this is the anchor every later ancestry check is measured against.
        self.capture_window = unsafe { window.CurrentNativeWindowHandle() }
            .ok()
            .filter(|native| !native.is_invalid())
            .map(pixel::bits);
        let capture_root = self
            .wait_for_root_web_area(&window, Duration::from_secs(2))
            .unwrap_or_else(|| window.clone());
        self.elements.clear();
        let cache = self.capture_cache_request()?;
        let capture_root = unsafe { capture_root.BuildUpdatedCache(&cache) }
            .map_err(|e| operation("cache capture root", e))?;
        let mut count = 0;
        let root = self.capture_node(&capture_root, &cache, 0, &mut count)?;
        let title = unsafe { window.CurrentName() }.ok().map(|x| x.to_string());
        let snapshot = Snapshot::new(Application {
            process_id: unsafe { window.CurrentProcessId() }.ok(),
            name: title.clone().unwrap_or_else(|| query.clone()),
            identifier: None,
            windows: vec![Window { title, root }],
        });
        self.snapshot = Some(snapshot.clone());
        Ok(snapshot)
    }
    fn find_window(
        &self,
        q: &AppQuery,
        operation: &str,
    ) -> Result<(IUIAutomationElement, String), BackendError> {
        let query = q
            .name
            .as_ref()
            .or(q.identifier.as_ref())
            .map(|value| value.to_lowercase());
        if q.process_id.is_none() && query.is_none() {
            return Err(op(
                operation,
                "app name, identifier, or process id is required",
            ));
        }
        let window = self
            .top_level()?
            .into_iter()
            .find(|element| {
                let name = unsafe { element.CurrentName() }
                    .unwrap_or_default()
                    .to_string()
                    .to_lowercase();
                let pid = unsafe { element.CurrentProcessId() }.unwrap_or_default();
                q.process_id.map_or_else(
                    || {
                        query
                            .as_deref()
                            .is_some_and(|query| name == query || name.contains(query))
                    },
                    |wanted| wanted == pid,
                )
            })
            .ok_or_else(|| op(operation, format!("no top-level window matches {q:?}")))?;
        Ok((
            window,
            query.unwrap_or_else(|| q.process_id.unwrap().to_string()),
        ))
    }
    fn capture_graphics(
        &self,
        q: AppQuery,
    ) -> Result<graphics_capture::CapturedBitmap, BackendError> {
        let (window, _) = self.find_window(&q, "capture window graphics")?;
        let native = unsafe { window.CurrentNativeWindowHandle() }
            .map_err(|e| operation("read native window handle", e))?;
        graphics_capture::capture(HWND(native.0))
    }
    fn wait_for_root_web_area(
        &self,
        window: &IUIAutomationElement,
        timeout: Duration,
    ) -> Option<IUIAutomationElement> {
        let value = VARIANT::from(BSTR::from("RootWebArea"));
        let condition = unsafe {
            self.automation
                .CreatePropertyCondition(UIA_AutomationIdPropertyId, &value)
        }
        .ok()?;
        let started = Instant::now();
        loop {
            if let Ok(root) = unsafe { window.FindFirst(TreeScope_Descendants, &condition) } {
                return Some(root);
            }
            if started.elapsed() >= timeout {
                return None;
            }
            thread::sleep(Duration::from_millis(50));
        }
    }
    fn capture_cache_request(&self) -> Result<IUIAutomationCacheRequest, BackendError> {
        let cache = unsafe { self.automation.CreateCacheRequest() }
            .map_err(|e| operation("create capture cache request", e))?;
        unsafe {
            cache
                .SetAutomationElementMode(AutomationElementMode_Full)
                .map_err(|e| operation("set capture cache element mode", e))?;
            // FindAllBuildCache applies this scope to every matched element. Descendants here
            // would cache each match's subtree rather than the match itself.
            cache
                .SetTreeScope(TreeScope_Element)
                .map_err(|e| operation("set capture cache tree scope", e))?;
            for property in [
                UIA_ControlTypePropertyId,
                UIA_NamePropertyId,
                UIA_AutomationIdPropertyId,
                UIA_BoundingRectanglePropertyId,
            ] {
                cache
                    .AddProperty(property)
                    .map_err(|e| operation("add capture cached property", e))?;
            }
            for pattern in [
                UIA_InvokePatternId,
                UIA_ValuePatternId,
                UIA_ScrollItemPatternId,
            ] {
                cache
                    .AddPattern(pattern)
                    .map_err(|e| operation("add capture cached pattern", e))?;
            }
        }
        Ok(cache)
    }
    fn capture_node(
        &mut self,
        e: &IUIAutomationElement,
        cache: &IUIAutomationCacheRequest,
        depth: usize,
        count: &mut usize,
    ) -> Result<Node, BackendError> {
        *count += 1;
        self.elements.push(e.clone());
        let ct = unsafe { e.CachedControlType() }
            .map_err(|e| operation("read cached ControlType", e))?;
        let mut actions = Vec::new();
        if unsafe { e.GetCachedPatternAs::<IUIAutomationInvokePattern>(UIA_InvokePatternId) }
            .is_ok()
        {
            actions.push("Invoke".into())
        }
        if unsafe { e.GetCachedPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId) }.is_ok()
        {
            actions.push("Value".into())
        }
        if unsafe {
            e.GetCachedPatternAs::<IUIAutomationScrollItemPattern>(UIA_ScrollItemPatternId)
        }
        .is_ok()
        {
            actions.push("ScrollItem".into())
        }
        let mut children = Vec::new();
        let mut trunc = None;
        let condition = unsafe { self.automation.CreateTrueCondition() }
            .map_err(|e| operation("create child capture condition", e))?;
        let child_array = unsafe { e.FindAllBuildCache(TreeScope_Children, &condition, cache) }
            .map_err(|e| operation("bulk cache child properties", e))?;
        let child_count = unsafe { child_array.Length() }
            .map_err(|e| operation("read cached child count", e))?
            .max(0) as usize;
        for index in 0..child_count {
            let c = unsafe { child_array.GetElement(index as i32) }
                .map_err(|e| operation("read cached child", e))?;
            if depth >= MAX_DEPTH || children.len() >= MAX_CHILDREN || *count >= MAX_NODES {
                trunc.get_or_insert_with(|| {
                    (if depth >= MAX_DEPTH {
                        "maxDepth"
                    } else if *count >= MAX_NODES {
                        "maxNodes"
                    } else {
                        "maxChildren"
                    })
                    .into()
                });
            } else {
                children.push(self.capture_node(&c, cache, depth + 1, count)?);
            }
        }
        let r = unsafe { e.CachedBoundingRectangle() }.ok();
        let name = unsafe { e.CachedName() }
            .ok()
            .map(|x| x.to_string())
            .filter(|x| !x.is_empty());
        let id = unsafe { e.CachedAutomationId() }
            .ok()
            .map(|x| x.to_string())
            .filter(|x| !x.is_empty());
        let value =
            unsafe { e.GetCachedPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId) }
                .ok()
                .and_then(|p| unsafe { p.CachedValue() }.ok())
                .map(|x| x.to_string());
        Ok(Node {
            role: control_type_name(ct.0).into(),
            subrole: None,
            name: name.clone(),
            title: name.clone(),
            label: name,
            value,
            description: None,
            identifier: id,
            actions,
            frame: r.map(|x| Rect {
                x: x.left as f64,
                y: x.top as f64,
                width: (x.right - x.left) as f64,
                height: (x.bottom - x.top) as f64,
            }),
            editable: ct == UIA_EditControlTypeId || ct == UIA_DocumentControlTypeId,
            focused: unsafe { e.CurrentHasKeyboardFocus() }.ok().map(bool::from),
            enabled: unsafe { e.CurrentIsEnabled() }.ok().map(bool::from),
            children,
            child_count: Some(child_count),
            truncation_reason: trunc,
        })
    }
    fn element(&self, h: &SnapshotHandle) -> Result<IUIAutomationElement, BackendError> {
        let s = self
            .snapshot
            .as_ref()
            .ok_or_else(|| op("resolve handle", "no active snapshot"))?;
        let i = s
            .index_for_handle(h)
            .map_err(|e| op("resolve handle", e.to_string()))?;
        self.elements
            .get(i)
            .cloned()
            .ok_or_else(|| op("resolve handle", "handle index outside snapshot"))
    }
}

impl PlatformBackend for WindowsBackend {
    fn capabilities(&self) -> Result<Vec<CapabilityInfo>, BackendError> {
        // `SendInput` posts to whatever desktop this process is attached to, and in session 0 or
        // off the interactive window station that desktop has no user on it. UI Automation keeps
        // answering there, so nothing else in the daemon notices; this is where the ladder finds
        // out, and it is why a foreground refusal in session 0 is `noDeliveryCandidate` rather
        // than an invitation to opt in to a device that reaches nobody.
        let session = crate::lifecycle::current_session();
        let global_input = (!session.interactive || !session.graphical).then(|| {
            session.detail.clone().unwrap_or_else(|| {
                "this session cannot reach the interactive desktop's input devices".to_string()
            })
        });
        Ok([
            Capability::Enumerate,
            Capability::Capture,
            Capability::RetainedHandles,
            Capability::Invoke,
            Capability::ReadValue,
            Capability::SetValue,
            Capability::Focus,
            Capability::Scroll,
            Capability::PointerInput,
            Capability::KeyboardInput,
            Capability::Screenshot,
            Capability::HitTest,
        ]
        .into_iter()
        .map(|capability| {
            let restriction = matches!(
                capability,
                Capability::PointerInput | Capability::KeyboardInput
            )
            .then(|| global_input.clone())
            .flatten();
            CapabilityInfo {
                capability,
                usable: restriction.is_none(),
                restriction,
            }
        })
        .collect())
    }
    fn enumerate_applications(&self) -> Result<Vec<Application>, BackendError> {
        self.call(Command::Enumerate)
    }
    fn capture(&mut self, q: &AppQuery) -> Result<Snapshot, BackendError> {
        self.call(|tx| Command::Capture(q.clone(), tx))
    }
    fn invoke(&mut self, h: &SnapshotHandle, _: &str) -> Result<(), BackendError> {
        self.call(|tx| Command::Invoke(h.clone(), tx))
    }
    fn read_value(&self, h: &SnapshotHandle) -> Result<Option<String>, BackendError> {
        self.call(|tx| Command::Read(h.clone(), tx))
    }
    fn set_value(&mut self, h: &SnapshotHandle, v: &str) -> Result<(), BackendError> {
        self.call(|tx| Command::Set(h.clone(), v.into(), tx))
    }
    fn focus(&mut self, h: &SnapshotHandle) -> Result<(), BackendError> {
        self.call(|tx| Command::Focus(h.clone(), tx))
    }
    fn scroll(&mut self, h: &SnapshotHandle, _: (f64, f64)) -> Result<(), BackendError> {
        self.call(|tx| Command::Scroll(h.clone(), tx))
    }
    fn pointer_click(&mut self, p: (f64, f64)) -> Result<(), BackendError> {
        send_click(p)
    }
    fn keyboard(&mut self, _: &AppQuery, intent: KeyboardIntent<'_>) -> Result<(), BackendError> {
        match intent {
            KeyboardIntent::Text(text) => send_text(text),
            // Chords need virtual-key and modifier handling this backend does not have. Typing the
            // chord's own name into the user's window would be worse than saying so.
            KeyboardIntent::Key(key) => Err(cap(
                Capability::KeyboardInput,
                format!(
                    "named keys and chords are not implemented on this backend, so {key} cannot be posted"
                ),
            )),
        }
    }
    fn observe(&mut self, _: &AppQuery, _: Duration) -> Result<Observation, BackendError> {
        Err(cap(
            Capability::ObserveChanges,
            "event observation is probe-only in v1",
        ))
    }
    fn wait_for_value(
        &mut self,
        _: &SnapshotHandle,
        _: &serde_json::Value,
        _: Duration,
    ) -> Result<Observation, BackendError> {
        Err(cap(Capability::ObserveChanges, "excluded from v1"))
    }
    fn pointer_drag(
        &mut self,
        _: (f64, f64),
        _: (f64, f64),
        _: Duration,
    ) -> Result<(), BackendError> {
        Err(cap(Capability::PointerInput, "drag excluded from v1"))
    }
    fn screenshot(&mut self, q: &AppQuery) -> Result<Screenshot, BackendError> {
        self.call(|tx| Command::Screenshot(q.clone(), tx))
    }
    fn hit_test(&mut self, point: (f64, f64)) -> Result<Option<Node>, BackendError> {
        self.call(|tx| Command::Hit(point, tx))
    }
    fn recorded_calls(&self) -> Result<Vec<RecordedCall>, BackendError> {
        Err(cap(Capability::SerializeHistory, "excluded from v1"))
    }
    fn set_recording(&mut self, _: bool) -> Result<(), BackendError> {
        Err(cap(Capability::SerializeHistory, "excluded from v1"))
    }
    fn observe_global_input(&mut self, _: Duration) -> Result<Vec<RecordedCall>, BackendError> {
        Err(cap(Capability::ObserveGlobalInput, "excluded from v1"))
    }

    /// Withheld, on measurement rather than on principle.
    ///
    /// Every other part of the transaction works on a real desktop, and
    /// `axon-win probe foreground` shows it: activation is proved, the dispatch runs once, and the
    /// real pointer is captured and put back. What fails is the hand-back. `SetForegroundWindow`
    /// activates the target and is then refused when asked to return the foreground to the
    /// application it was taken from — twice, against two unrelated prior applications, with the
    /// thread-attachment assist in place and a bounded wait for the change to settle. The probe
    /// reports `accepted: false` on a direct retry, so this is Windows declining rather than a
    /// readback sampled too early.
    ///
    /// The rung is global input that hands the session back. Offering one that reliably steals the
    /// foreground and reliably reports `success: false` is the worst of both: the caller pays the
    /// side effect and does not get the guarantee. So the seams below stay — they are what the
    /// probe exercises and what a fix will need — and the rung stays closed until the probe says
    /// the foreground comes home.
    fn supports_foreground_transaction(&self) -> bool {
        false
    }

    /// The foreground window's process id.
    ///
    /// The process id, deliberately: it is the same vocabulary `capture` records in
    /// `Application::identifier`, and the transaction proves activation by comparing identities.
    /// A window title would compare unequal against that and could never prove anything.
    fn frontmost_application(&mut self) -> Result<Option<String>, BackendError> {
        let window = pixel::foreground_window();
        let Some(pid) = pixel::process_of(window) else {
            return Ok(None);
        };
        // Bounded: this is a hint for restoration, not something anything reads for truth, and a
        // long-lived daemon does not need to remember every window it has ever watched.
        if self.last_foreground.len() >= 32 {
            self.last_foreground.clear();
        }
        self.last_foreground.insert(pid, pixel::bits(window));
        Ok(Some(pid.to_string()))
    }

    fn activate_application(&mut self, identity: &str) -> Result<bool, BackendError> {
        // Identities reaching here are process ids, because `resolve_application` above is what
        // the transaction translates a caller's request through. Anything else cannot be
        // activated, and saying so leaves the transaction to refuse without posting rather than
        // guessing at a window.
        let Ok(pid) = identity.parse::<u32>() else {
            return Ok(false);
        };
        let remembered = self.last_foreground.get(&pid).copied().map(pixel::hwnd);
        Ok(pixel::activate(pid, remembered))
    }

    fn pointer_location(&mut self) -> Result<Option<(f64, f64)>, BackendError> {
        Ok(pixel::cursor().map(|(x, y)| (x as f64, y as f64)))
    }

    fn move_pointer(&mut self, to: (f64, f64)) -> Result<bool, BackendError> {
        Ok(pixel::set_cursor(to.0.round() as i32, to.1.round() as i32))
    }

    /// The process id of the application an `AppQuery` names.
    ///
    /// This is the translation the foreground transaction depends on, and it lives here rather
    /// than in the router because only this backend knows that it spells an identity as a process
    /// id. Handing a display name straight through would compare a window title against a process
    /// id and refuse every aimed action as `activationNotProved`.
    fn resolve_application(&mut self, app: &AppQuery) -> Result<Option<String>, BackendError> {
        let applications = self.enumerate_applications()?;
        let identified = |app: &Application| {
            app.identifier
                .clone()
                .filter(|identity| !identity.is_empty())
        };
        if let Some(wanted) = app.identifier.as_deref() {
            return Ok(applications
                .iter()
                .find(|candidate| identified(candidate).as_deref() == Some(wanted))
                .and_then(identified));
        }
        let Some(wanted) = app.name.as_deref().map(str::to_lowercase) else {
            return Ok(None);
        };
        // Exact before substring, so "Notepad" cannot be answered by "Notepad++" while the
        // application the caller meant is running.
        Ok(applications
            .iter()
            .find(|candidate| candidate.name.to_lowercase() == wanted)
            .or_else(|| {
                applications
                    .iter()
                    .find(|candidate| candidate.name.to_lowercase().contains(&wanted))
            })
            .and_then(identified))
    }
}

impl BackgroundPixelPointer for WindowsBackend {
    fn plan_pixel_click(
        &mut self,
        handle: &SnapshotHandle,
        point: (f64, f64),
    ) -> Result<PixelPlan, BackendError> {
        self.call(|tx| Command::PlanPixelClick(handle.clone(), point, tx))
    }

    fn dispatch_pixel_click(
        &mut self,
        target: &PixelTarget,
    ) -> Result<PixelDispatch, PixelDispatchError> {
        self.call(|tx| Command::DispatchPixelClick(target.clone(), tx))
            .map_err(PixelDispatchError::Backend)?
    }
}

impl WindowsBackend {
    /// Probe-only: lets a plan bind a window class the allowlist has not accepted yet.
    ///
    /// This is how a class becomes a candidate for the allowlist at all, and it is deliberately
    /// not reachable through the tool surface. The daemon never bypasses its own table.
    pub fn allow_unverified_pixel_classes(&mut self, allow: bool) -> Result<(), BackendError> {
        self.call(|tx| Command::AllowUnverifiedPixelClasses(allow, tx))
    }
}

pub struct IntegrationProbe;
impl IntegrationProbe {
    pub fn run(args: &[String]) -> Result<serde_json::Value, BackendError> {
        let command = args.first().map(String::as_str).ok_or_else(|| {
            op("probe", "expected value <app-query>, events <app-query> [seconds], timeout [app-query] [milliseconds], pixel-click <app-query> <element-query> [--unverified-class] [--settle-ms N], or foreground <app-query>")
        })?;
        // These two drive the shipping backend rather than a parallel client, which is the point:
        // a probe that exercised its own copy of the mechanism would prove nothing about the one
        // the daemon runs. They must run in the interactive desktop session; over SSH they land
        // in session 0, where UIA and SetForegroundWindow cannot reach the user's UI at all and
        // every answer is a false negative.
        match command {
            "pixel-click" => return probe_pixel_click(args),
            "foreground" => return probe_foreground(args),
            _ => {}
        }
        let _com = ComApartment::mta()?;
        let automation = create_automation()?;
        match command {
            "value" => probe_value(&automation, required_probe_arg(args, 1, "app-query")?),
            "events" => {
                let seconds = probe_number(args.get(2), 15, "seconds")?;
                probe_events(
                    &automation,
                    required_probe_arg(args, 1, "app-query")?,
                    seconds,
                )
            }
            "timeout" => {
                let app = args.get(1).map(String::as_str);
                let milliseconds = probe_number(args.get(2), 1500, "milliseconds")?;
                probe_timeout(&automation, app, milliseconds)
            }
            other => Err(op("probe", format!("unknown probe {other:?}"))),
        }
    }
}

fn required_probe_arg<'a>(
    args: &'a [String],
    index: usize,
    name: &str,
) -> Result<&'a str, BackendError> {
    args.get(index)
        .map(String::as_str)
        .ok_or_else(|| op("probe", format!("missing {name}")))
}

fn probe_flag<'a>(args: &'a [String], name: &str) -> Option<&'a String> {
    args.iter()
        .position(|arg| arg == name)
        .and_then(|index| args.get(index + 1))
}

/// Every node of a snapshot, in the order its handles are numbered.
fn flattened(snapshot: &Snapshot) -> Vec<&Node> {
    fn add<'a>(node: &'a Node, out: &mut Vec<&'a Node>) {
        out.push(node);
        for child in &node.children {
            add(child, out);
        }
    }
    let mut out = Vec::new();
    for window in &snapshot.app.windows {
        add(&window.root, &mut out);
    }
    out
}

fn find_probe_node(
    snapshot: &Snapshot,
    query: &str,
) -> Result<(SnapshotHandle, Node), BackendError> {
    let wanted = query.to_lowercase();
    let matches = |text: &Option<String>| {
        text.as_ref()
            .is_some_and(|value| value.to_lowercase().contains(&wanted))
    };
    flattened(snapshot)
        .into_iter()
        .enumerate()
        .find(|(_, node)| {
            matches(&node.name)
                || matches(&node.title)
                || matches(&node.label)
                || matches(&node.identifier)
        })
        .map(|(index, node)| (snapshot.handle(index), node.clone()))
        .ok_or_else(|| op("probe", format!("no element matches {query:?}")))
}

fn probe_point(point: Option<(i32, i32)>) -> serde_json::Value {
    match point {
        Some((x, y)) => serde_json::json!({"x": x, "y": y}),
        None => serde_json::Value::Null,
    }
}

/// Plans and posts one pixel click, reporting everything an allowlist entry has to be earned on.
///
/// The four acceptance criteria read straight off the output: the element state changed, the
/// foreground window is identical before and after, the cursor is identical before and after, and
/// `clientOrigin` plus `windowPoint` reconstruct `screenPoint`. Nothing here decides whether a
/// class is good enough; a person reads this and edits `PIXEL_MESSAGE_CLASSES`.
fn probe_pixel_click(args: &[String]) -> Result<serde_json::Value, BackendError> {
    let app = required_probe_arg(args, 1, "app-query")?.to_string();
    let element_query = required_probe_arg(args, 2, "element-query")?.to_string();
    let unverified = args.iter().any(|arg| arg == "--unverified-class");
    let settle = probe_number(probe_flag(args, "--settle-ms"), 750, "settle-ms")?;
    // The element that changes is usually not the element that was clicked — a calculator key
    // moves the display, a tab moves the pane. Watching only the target would report "nothing
    // changed" for a click that worked perfectly.
    let observed_query = probe_flag(args, "--observe")
        .cloned()
        .unwrap_or_else(|| element_query.clone());

    let mut backend = WindowsBackend::start()?;
    if unverified {
        backend.allow_unverified_pixel_classes(true)?;
    }
    let query = AppQuery {
        process_id: None,
        name: Some(app.clone()),
        identifier: None,
    };
    let snapshot = backend.capture(&query)?;
    let (handle, target_node) = find_probe_node(&snapshot, &element_query)?;
    let frame = target_node
        .frame
        .ok_or_else(|| op("probe", "the resolved element has no actionable frame"))?;
    let point = (frame.x + frame.width / 2.0, frame.y + frame.height / 2.0);
    let (observed_handle, before) = find_probe_node(&snapshot, &observed_query)?;
    let value_before = backend.read_value(&observed_handle).ok().flatten();

    let target = match backend.plan_pixel_click(&handle, point)? {
        PixelPlan::Bound(target) => target,
        PixelPlan::Unavailable {
            reason,
            blocks_global_input,
        } => {
            return Ok(serde_json::json!({
                "probe": "pixel-click",
                "app": app,
                "element": element_query,
                "planned": false,
                "reason": reason,
                "blocksGlobalInput": blocks_global_input,
            }));
        }
    };

    // The two checks the router already runs against this pairing, reported alongside the
    // dispatch. A revalidation that refuses is only diagnosable if what is actually under the
    // point, and whether the shipping identity check agrees, are both on the record.
    let hit_at_point = backend.hit_test(point).ok().flatten();
    let identity_verified = backend
        .verify_pointer_target(&handle, point)
        .unwrap_or(false);

    let foreground_before = pixel::bits(pixel::foreground_window());
    let cursor_before = pixel::cursor();
    let dispatch = backend.dispatch_pixel_click(&target);
    let foreground_after = pixel::bits(pixel::foreground_window());
    let cursor_after = pixel::cursor();
    thread::sleep(Duration::from_millis(settle));
    // Sampled a second time, after the target has had time to finish reacting. The dispatch's own
    // invariant check ends where the window procedure returns, which is the boundary it can prove;
    // a handler that defers activation onto its own message loop would land after that and before
    // this. An allowlist entry has to survive both readings.
    let foreground_settled = pixel::bits(pixel::foreground_window());
    let cursor_settled = pixel::cursor();

    let after_snapshot = backend.capture(&query)?;
    let after = find_probe_node(&after_snapshot, &observed_query).ok();
    let value_after = after
        .as_ref()
        .and_then(|(handle, _)| backend.read_value(handle).ok().flatten());

    Ok(serde_json::json!({
        "probe": "pixel-click",
        "app": app,
        "element": element_query,
        "observed": observed_query,
        "planned": true,
        "unverifiedClassAllowed": unverified,
        "target": {
            "processIdentifier": target.process_identifier,
            "screenPoint": {"x": target.screen_point.0, "y": target.screen_point.1},
            "window": target.evidence(),
        },
        "dispatch": match &dispatch {
            Ok(dispatch) => serde_json::json!({
                "complete": dispatch.complete,
                "partial": dispatch.partial,
                "frontmostAppUnchanged": dispatch.frontmost_unchanged,
                "pointerUnchanged": dispatch.pointer_unchanged,
            }),
            Err(PixelDispatchError::Stale(reason)) => serde_json::json!({"stale": reason}),
            Err(PixelDispatchError::Backend(error)) => {
                serde_json::json!({"error": error.to_string()})
            }
        },
        "foregroundWindowBefore": format!("0x{foreground_before:08X}"),
        "foregroundWindowAfter": format!("0x{foreground_after:08X}"),
        "foregroundWindowSettled": format!("0x{foreground_settled:08X}"),
        "cursorBefore": probe_point(cursor_before),
        "cursorAfter": probe_point(cursor_after),
        "cursorSettled": probe_point(cursor_settled),
        "settleMs": settle,
        "clickedElement": target_node,
        "hitAtPoint": hit_at_point,
        "identityVerified": identity_verified,
        "observedBefore": before,
        "observedAfter": after.map(|(_, node)| node),
        "valueBefore": value_before,
        "valueAfter": value_after,
    }))
}

/// Runs the foreground transaction against a real application and reports the whole of it.
///
/// This is what answers whether `SetForegroundWindow` is usable from the daemon on this machine.
/// If it is not, `activationProved` is false, nothing was posted, and the honest response is to
/// leave the foreground rung withheld rather than to ship a rung that always refuses late.
///
/// The body deliberately moves the real pointer, because that is the seam a `SendInput` click
/// depends on: `pointerRestored` in the output is the daemon proving it can hand the cursor back.
fn probe_foreground(args: &[String]) -> Result<serde_json::Value, BackendError> {
    let app = required_probe_arg(args, 1, "app-query")?.to_string();
    let mut backend = WindowsBackend::start()?;
    let query = AppQuery {
        process_id: None,
        name: Some(app.clone()),
        identifier: None,
    };
    let snapshot = backend.capture(&query)?;
    let identity = snapshot
        .app
        .identifier
        .clone()
        .unwrap_or_else(|| snapshot.app.name.clone());
    let nudge = snapshot
        .app
        .windows
        .first()
        .and_then(|window| window.root.frame)
        .map(|frame| {
            (
                (frame.x + frame.width / 2.0).round() as i32,
                (frame.y + frame.height / 2.0).round() as i32,
            )
        });

    let prior_window = pixel::bits(pixel::foreground_window());
    let cursor_before = pixel::cursor();
    let dispatch = dispatch_in_foreground(
        &mut backend,
        ForegroundTarget::Application(&identity),
        // This probe's whole subject is the hand-back, so it deliberately moves the cursor and
        // then reports whether the transaction put it home. Passing false would exercise the one
        // path it exists to measure and skip it.
        true,
        |_| {
            if let Some((x, y)) = nudge {
                pixel::set_cursor(x, y);
            }
        },
    );
    let cursor_after = pixel::cursor();

    // What the transaction's own restore could not report: where the foreground actually ended up,
    // and whether asking again changes the answer. A restore that fails is only diagnosable if the
    // difference between "the request was refused" and "the request was accepted and ignored" is
    // visible.
    let settled = pixel::foreground_window();
    let prior_identity = dispatch.cleanup.prior_app.clone();
    let retry = prior_identity.as_ref().map(|identity| {
        let accepted = backend.activate_application(identity).unwrap_or(false);
        let immediately = pixel::foreground_window();
        // Read once, then again after a wait longer than the transaction's own. Acceptance is a
        // request and the foreground changes when Windows gets to it, so a single read cannot tell
        // a refusal from an activation that had not happened yet — which is precisely the
        // confusion that would have this rung withheld for the wrong reason.
        thread::sleep(Duration::from_millis(1_000));
        let eventually = pixel::foreground_window();
        serde_json::json!({
            "identity": identity,
            "accepted": accepted,
            "foregroundWindow": format!("0x{:08X}", pixel::bits(immediately)),
            "foregroundProcess": pixel::process_of(immediately),
            "foregroundWindowAfterWait": format!("0x{:08X}", pixel::bits(eventually)),
            "foregroundProcessAfterWait": pixel::process_of(eventually),
        })
    });

    Ok(serde_json::json!({
        "probe": "foreground",
        "app": app,
        "identity": identity,
        "priorForegroundWindow": format!("0x{prior_window:08X}"),
        "priorForegroundProcess": pixel::process_of(pixel::hwnd(prior_window)),
        "foreground": dispatch.cleanup,
        "refusal": dispatch.refusal,
        "pointerNudgedTo": probe_point(nudge),
        "cursorBefore": probe_point(cursor_before),
        "cursorAfter": probe_point(cursor_after),
        "settledForegroundWindow": format!("0x{:08X}", pixel::bits(settled)),
        "settledForegroundProcess": pixel::process_of(settled),
        "restoreRetry": retry,
    }))
}

fn probe_number(value: Option<&String>, default: u64, name: &str) -> Result<u64, BackendError> {
    value.map_or(Ok(default), |value| {
        value
            .parse()
            .map_err(|_| op("probe", format!("invalid {name} {value:?}")))
    })
}

fn probe_window(
    automation: &IUIAutomation,
    query: &str,
) -> Result<IUIAutomationElement, BackendError> {
    let root =
        unsafe { automation.GetRootElement() }.map_err(|e| operation("get desktop root", e))?;
    let condition = unsafe { automation.CreateTrueCondition() }
        .map_err(|e| operation("create condition", e))?;
    let windows = unsafe { root.FindAll(TreeScope_Children, &condition) }
        .map_err(|e| operation("enumerate windows", e))?;
    let count = unsafe { windows.Length() }.map_err(|e| operation("read window count", e))?;
    let query = query.to_lowercase();
    for index in 0..count {
        let element =
            unsafe { windows.GetElement(index) }.map_err(|e| operation("read window", e))?;
        let name = unsafe { element.CurrentName() }
            .unwrap_or_default()
            .to_string();
        let pid = unsafe { element.CurrentProcessId() }
            .unwrap_or_default()
            .to_string();
        if name.to_lowercase().contains(&query) || pid == query {
            return Ok(element);
        }
    }
    Err(op(
        "probe",
        format!("no top-level window matches {query:?}"),
    ))
}

fn probe_value(automation: &IUIAutomation, query: &str) -> Result<serde_json::Value, BackendError> {
    let window = probe_window(automation, query)?;
    let condition = unsafe { automation.CreateTrueCondition() }
        .map_err(|e| operation("create condition", e))?;
    let elements = unsafe { window.FindAll(TreeScope_Descendants, &condition) }
        .map_err(|e| operation("find editable elements", e))?;
    let count = unsafe { elements.Length() }.map_err(|e| operation("read element count", e))?;
    for index in 0..count {
        let element =
            unsafe { elements.GetElement(index) }.map_err(|e| operation("read element", e))?;
        let Ok(pattern) = (unsafe {
            element.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)
        }) else {
            continue;
        };
        if bool::from(unsafe { pattern.CurrentIsReadOnly() }.unwrap_or(true.into())) {
            continue;
        }
        let original = unsafe { pattern.CurrentValue() }
            .map_err(|e| operation("read original value", e))?
            .to_string();
        let sentinel = format!(
            "axon-value-probe-{}-{}",
            std::process::id(),
            Instant::now().elapsed().as_nanos()
        );
        let mut restore = ValueRestore {
            pattern: pattern.clone(),
            original: original.clone(),
            restored: false,
        };
        let result = (|| {
            unsafe { pattern.SetValue(&BSTR::from(&sentinel)) }
                .map_err(|e| operation("set sentinel value", e))?;
            let observed = unsafe { pattern.CurrentValue() }
                .map_err(|e| operation("read sentinel value", e))?
                .to_string();
            if observed != sentinel {
                return Err(op("value probe", "sentinel readback did not match"));
            }
            restore.restore()?;
            let restored = unsafe { pattern.CurrentValue() }
                .map_err(|e| operation("read restored value", e))?
                .to_string();
            if restored != original {
                return Err(op("value probe", "restored value readback did not match"));
            }
            Ok(
                serde_json::json!({"probe":"value","appQuery":query,"elementIndex":index,"original":original,"sentinel":sentinel,"sentinelObserved":observed,"sentinelValidated":true,"restoredObserved":restored,"restoreValidated":true}),
            )
        })();
        return result;
    }
    Err(op("value probe", "no editable ValuePattern element found"))
}

struct ValueRestore {
    pattern: IUIAutomationValuePattern,
    original: String,
    restored: bool,
}
impl ValueRestore {
    fn restore(&mut self) -> Result<(), BackendError> {
        unsafe { self.pattern.SetValue(&BSTR::from(&self.original)) }
            .map_err(|e| operation("restore original value", e))?;
        self.restored = true;
        Ok(())
    }
}
impl Drop for ValueRestore {
    fn drop(&mut self) {
        if !self.restored {
            let _ = unsafe { self.pattern.SetValue(&BSTR::from(&self.original)) };
        }
    }
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct ProbeEvent {
    kind: &'static str,
    native_kind: i32,
    callback_thread: String,
}

#[implement(IUIAutomationEventHandler)]
struct AutomationProbeHandler {
    tx: mpsc::Sender<ProbeEvent>,
}
impl IUIAutomationEventHandler_Impl for AutomationProbeHandler_Impl {
    fn HandleAutomationEvent(
        &self,
        _sender: Ref<IUIAutomationElement>,
        eventid: windows::Win32::UI::Accessibility::UIA_EVENT_ID,
    ) -> WinResult<()> {
        let _ = self.tx.send(ProbeEvent {
            kind: "automation",
            native_kind: eventid.0,
            callback_thread: format!("{:?}", thread::current().id()),
        });
        Ok(())
    }
}
#[implement(IUIAutomationStructureChangedEventHandler)]
struct StructureProbeHandler {
    tx: mpsc::Sender<ProbeEvent>,
}
impl IUIAutomationStructureChangedEventHandler_Impl for StructureProbeHandler_Impl {
    fn HandleStructureChangedEvent(
        &self,
        _sender: Ref<IUIAutomationElement>,
        change: StructureChangeType,
        _runtime_id: *const windows::Win32::System::Com::SAFEARRAY,
    ) -> WinResult<()> {
        let _ = self.tx.send(ProbeEvent {
            kind: "structure",
            native_kind: change.0,
            callback_thread: format!("{:?}", thread::current().id()),
        });
        Ok(())
    }
}
#[implement(IUIAutomationFocusChangedEventHandler)]
struct FocusProbeHandler {
    tx: mpsc::Sender<ProbeEvent>,
}
impl IUIAutomationFocusChangedEventHandler_Impl for FocusProbeHandler_Impl {
    fn HandleFocusChangedEvent(&self, _sender: Ref<IUIAutomationElement>) -> WinResult<()> {
        let _ = self.tx.send(ProbeEvent {
            kind: "focus",
            native_kind: 0,
            callback_thread: format!("{:?}", thread::current().id()),
        });
        Ok(())
    }
}

fn probe_events(
    automation: &IUIAutomation,
    query: &str,
    seconds: u64,
) -> Result<serde_json::Value, BackendError> {
    let window = probe_window(automation, query)?;
    let root =
        unsafe { automation.GetRootElement() }.map_err(|e| operation("get desktop root", e))?;
    let (tx, rx) = mpsc::channel();
    let automation_handler: IUIAutomationEventHandler =
        AutomationProbeHandler { tx: tx.clone() }.into();
    let structure_handler: IUIAutomationStructureChangedEventHandler =
        StructureProbeHandler { tx: tx.clone() }.into();
    let focus_handler: IUIAutomationFocusChangedEventHandler = FocusProbeHandler { tx }.into();
    unsafe {
        automation.AddAutomationEventHandler(
            UIA_Text_TextChangedEventId,
            &window,
            TreeScope_Descendants,
            None,
            &automation_handler,
        )
    }
    .map_err(|e| operation("register automation event handler", e))?;
    let mut cleanup = EventCleanup {
        automation,
        automation_element: window.clone(),
        structure_element: root.clone(),
        automation_handler: Some(automation_handler),
        structure_handler: None,
        focus_handler: None,
    };
    unsafe {
        automation.AddStructureChangedEventHandler(
            &root,
            TreeScope_Descendants,
            None,
            &structure_handler,
        )
    }
    .map_err(|e| operation("register structure event handler", e))?;
    cleanup.structure_handler = Some(structure_handler);
    unsafe { automation.AddFocusChangedEventHandler(None, &focus_handler) }
        .map_err(|e| operation("register focus event handler", e))?;
    cleanup.focus_handler = Some(focus_handler);
    let deadline = Instant::now() + Duration::from_secs(seconds);
    let mut records = Vec::new();
    while let Some(remaining) = deadline.checked_duration_since(Instant::now()) {
        match rx.recv_timeout(remaining) {
            Ok(record) => records.push(record),
            Err(mpsc::RecvTimeoutError::Timeout) => break,
            Err(_) => break,
        }
    }
    cleanup.remove()?;
    let count = |kind| records.iter().filter(|record| record.kind == kind).count();
    Ok(
        serde_json::json!({"probe":"events","appQuery":query,"timeoutSeconds":seconds,"registered":{"automation":"Text_TextChanged","structure":"desktop descendants","focus":true},"counts":{"automation":count("automation"),"structure":count("structure"),"focus":count("focus")},"records":records,"handlersRemoved":true}),
    )
}

struct EventCleanup<'a> {
    automation: &'a IUIAutomation,
    automation_element: IUIAutomationElement,
    structure_element: IUIAutomationElement,
    automation_handler: Option<IUIAutomationEventHandler>,
    structure_handler: Option<IUIAutomationStructureChangedEventHandler>,
    focus_handler: Option<IUIAutomationFocusChangedEventHandler>,
}
impl EventCleanup<'_> {
    fn remove(&mut self) -> Result<(), BackendError> {
        if let Some(handler) = self.focus_handler.take() {
            unsafe { self.automation.RemoveFocusChangedEventHandler(&handler) }
                .map_err(|e| operation("remove focus event handler", e))?;
        }
        if let Some(handler) = self.structure_handler.take() {
            unsafe {
                self.automation
                    .RemoveStructureChangedEventHandler(&self.structure_element, &handler)
            }
            .map_err(|e| operation("remove structure event handler", e))?;
        }
        if let Some(handler) = self.automation_handler.take() {
            unsafe {
                self.automation.RemoveAutomationEventHandler(
                    UIA_Text_TextChangedEventId,
                    &self.automation_element,
                    &handler,
                )
            }
            .map_err(|e| operation("remove automation event handler", e))?;
        }
        Ok(())
    }
}
impl Drop for EventCleanup<'_> {
    fn drop(&mut self) {
        let _ = self.remove();
    }
}

fn probe_timeout(
    automation: &IUIAutomation,
    app: Option<&str>,
    milliseconds: u64,
) -> Result<serde_json::Value, BackendError> {
    let timeout =
        u32::try_from(milliseconds).map_err(|_| op("timeout probe", "milliseconds exceeds u32"))?;
    let automation2: IUIAutomation2 = match automation.cast() {
        Ok(value) => value,
        Err(error) => {
            return Ok(serde_json::json!({
                "probe":"timeout",
                "connectionTimeoutMs":timeout,
                "transactionTimeoutMs":timeout,
                "configured":false,
                "controlledHungProviderAvailable":false,
                "reason":"IUIAutomation2 is unavailable from the installed UI Automation provider",
                "diagnostic":error.to_string()
            }));
        }
    };
    unsafe { automation2.SetConnectionTimeout(timeout) }
        .map_err(|e| operation("set connection timeout", e))?;
    unsafe { automation2.SetTransactionTimeout(timeout) }
        .map_err(|e| operation("set transaction timeout", e))?;
    let element = match app {
        Some(query) => probe_window(automation, query)?,
        None => {
            unsafe { automation.GetRootElement() }.map_err(|e| operation("get desktop root", e))?
        }
    };
    let started = Instant::now();
    let result = unsafe { element.CurrentName() };
    let elapsed = started.elapsed().as_millis();
    Ok(
        serde_json::json!({"probe":"timeout","connectionTimeoutMs":timeout,"transactionTimeoutMs":timeout,"controlledHungProviderAvailable":false,"controlledHungProviderNote":"no controlled hung provider was supplied; result measures a bounded live provider call only","providerTarget":app.unwrap_or("desktop-root"),"operation":"CurrentName","elapsedMs":elapsed,"result":match result { Ok(value) => serde_json::json!({"status":"ok","value":value.to_string()}), Err(error) => serde_json::json!({"status":"error","diagnostic":error.to_string()}) }}),
    )
}

fn create_automation() -> Result<IUIAutomation, BackendError> {
    unsafe { CoCreateInstance(&CUIAutomation8, None, CLSCTX_INPROC_SERVER) }
        .or_else(|_| unsafe { CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER) })
        .map_err(|e| operation("create UI Automation client", e))
}

fn send_text(text: &str) -> Result<(), BackendError> {
    let mut inputs = Vec::new();
    for unit in text.encode_utf16() {
        for flags in [KEYEVENTF_UNICODE, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP] {
            inputs.push(INPUT {
                r#type: INPUT_KEYBOARD,
                Anonymous: INPUT_0 {
                    ki: KEYBDINPUT {
                        wVk: VIRTUAL_KEY(0),
                        wScan: unit,
                        dwFlags: flags,
                        time: 0,
                        dwExtraInfo: 0,
                    },
                },
            })
        }
    }
    let sent = unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) };
    if sent != inputs.len() as u32 {
        return Err(op(
            "SendInput keyboard",
            format!("sent {sent} of {} events", inputs.len()),
        ));
    }
    Ok(())
}
fn send_click((x, y): (f64, f64)) -> Result<(), BackendError> {
    let origin_x = unsafe { GetSystemMetrics(SM_XVIRTUALSCREEN) };
    let origin_y = unsafe { GetSystemMetrics(SM_YVIRTUALSCREEN) };
    let width = unsafe { GetSystemMetrics(SM_CXVIRTUALSCREEN) };
    let height = unsafe { GetSystemMetrics(SM_CYVIRTUALSCREEN) };
    let (dx, dy) = normalize_virtual_desktop_point((x, y), (origin_x, origin_y), (width, height));
    let mi = |flags| INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT {
                dx,
                dy,
                mouseData: 0,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    let inputs = [
        mi(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK),
        mi(MOUSEEVENTF_LEFTDOWN | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK),
        mi(MOUSEEVENTF_LEFTUP | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK),
    ];
    let sent = unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) };
    if sent != 3 {
        Err(op("SendInput click", format!("sent {sent} of 3 events")))
    } else {
        Ok(())
    }
}
fn control_type_name(id: i32) -> &'static str {
    match id {
        x if x == UIA_ButtonControlTypeId.0 => "Button",
        x if x == UIA_CheckBoxControlTypeId.0 => "CheckBox",
        x if x == UIA_ComboBoxControlTypeId.0 => "ComboBox",
        x if x == UIA_EditControlTypeId.0 => "Edit",
        x if x == UIA_DocumentControlTypeId.0 => "Document",
        x if x == UIA_HyperlinkControlTypeId.0 => "Hyperlink",
        x if x == UIA_ImageControlTypeId.0 => "Image",
        x if x == UIA_ListControlTypeId.0 => "List",
        x if x == UIA_ListItemControlTypeId.0 => "ListItem",
        x if x == UIA_MenuControlTypeId.0 => "Menu",
        x if x == UIA_MenuItemControlTypeId.0 => "MenuItem",
        x if x == UIA_PaneControlTypeId.0 => "Pane",
        x if x == UIA_RadioButtonControlTypeId.0 => "RadioButton",
        x if x == UIA_ScrollBarControlTypeId.0 => "ScrollBar",
        x if x == UIA_SliderControlTypeId.0 => "Slider",
        x if x == UIA_TabControlTypeId.0 => "Tab",
        x if x == UIA_TabItemControlTypeId.0 => "TabItem",
        x if x == UIA_TextControlTypeId.0 => "Text",
        x if x == UIA_TreeControlTypeId.0 => "Tree",
        x if x == UIA_TreeItemControlTypeId.0 => "TreeItem",
        x if x == UIA_WindowControlTypeId.0 => "Window",
        x if x == UIA_GroupControlTypeId.0 => "Group",
        x if x == UIA_ProgressBarControlTypeId.0 => "ProgressBar",
        x if x == UIA_ThumbControlTypeId.0 => "Thumb",
        x if x == UIA_ToolBarControlTypeId.0 => "ToolBar",
        x if x == UIA_ToolTipControlTypeId.0 => "ToolTip",
        x if x == UIA_CustomControlTypeId.0 => "Custom",
        _ => "Unknown",
    }
}
struct ComApartment;
impl ComApartment {
    fn mta() -> Result<Self, BackendError> {
        unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }
            .ok()
            .map_err(|e| operation("initialize COM MTA", e))?;
        Ok(Self)
    }
}
impl Drop for ComApartment {
    fn drop(&mut self) {
        unsafe { CoUninitialize() }
    }
}
#[derive(Clone)]
struct CloneError {
    capability: Option<Capability>,
    operation: String,
    message: String,
}
impl From<&BackendError> for CloneError {
    fn from(e: &BackendError) -> Self {
        match e {
            BackendError::Capability {
                capability, reason, ..
            } => Self {
                capability: Some(*capability),
                operation: String::new(),
                message: reason.clone(),
            },
            BackendError::Operation {
                operation, message, ..
            } => Self {
                capability: None,
                operation: operation.clone(),
                message: message.clone(),
            },
        }
    }
}
impl From<CloneError> for BackendError {
    fn from(e: CloneError) -> Self {
        if let Some(capability) = e.capability {
            cap(capability, e.message)
        } else {
            op(e.operation, e.message)
        }
    }
}
fn operation(name: &str, e: windows::core::Error) -> BackendError {
    BackendError::Operation {
        operation: name.into(),
        message: "native operation failed".into(),
        diagnostic: Some(e.to_string()),
    }
}
fn op(name: impl Into<String>, message: impl Into<String>) -> BackendError {
    BackendError::Operation {
        operation: name.into(),
        message: message.into(),
        diagnostic: None,
    }
}
fn cap(capability: Capability, reason: impl Into<String>) -> BackendError {
    BackendError::Capability {
        capability,
        reason: reason.into(),
        diagnostic: None,
    }
}

mod msaa {
    use super::c_void;
    #[repr(C)]
    struct Guid {
        data1: u32,
        data2: u16,
        data3: u16,
        data4: [u8; 8],
    }
    const IID: Guid = Guid {
        data1: 0x618736e0,
        data2: 0x3c3d,
        data3: 0x11cf,
        data4: [0x81, 0x0c, 0, 0xaa, 0, 0x38, 0x9b, 0x71],
    };
    #[link(name = "oleacc")]
    unsafe extern "system" {
        fn AccessibleObjectFromWindow(
            hwnd: isize,
            id: u32,
            iid: *const Guid,
            out: *mut *mut c_void,
        ) -> i32;
    }
    #[link(name = "user32")]
    unsafe extern "system" {
        fn EnumChildWindows(
            hwnd: isize,
            callback: unsafe extern "system" fn(isize, isize) -> i32,
            param: isize,
        ) -> i32;
    }
    pub fn activate(hwnd: isize) {
        touch(hwnd);
        unsafe {
            EnumChildWindows(hwnd, visit, 0);
        }
    }
    unsafe extern "system" fn visit(hwnd: isize, _: isize) -> i32 {
        touch(hwnd);
        1
    }
    fn touch(hwnd: isize) {
        let mut out = std::ptr::null_mut();
        if unsafe { AccessibleObjectFromWindow(hwnd, (-4_i32) as u32, &IID, &mut out) } >= 0
            && !out.is_null()
        {
            unsafe {
                let v = *(out as *mut *mut *mut c_void);
                let release: unsafe extern "system" fn(*mut c_void) -> u32 =
                    std::mem::transmute(*v.add(2));
                release(out);
            }
        }
    }
}
