use axon_core::{
    AppQuery, Application, BackendError, Capability, CapabilityInfo, Node, Observation,
    PlatformBackend, RecordedCall, Rect, Screenshot, Snapshot, SnapshotHandle, Window,
};
use std::{
    ffi::c_void,
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};
use windows::{
    Win32::{
        Foundation::POINT,
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
                MOUSEEVENTF_MOVE, MOUSEINPUT, SendInput, VIRTUAL_KEY,
            },
            WindowsAndMessaging::{GetSystemMetrics, SM_CXSCREEN, SM_CYSCREEN},
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
}

pub struct WindowsBackend {
    tx: mpsc::Sender<Command>,
}

impl WindowsBackend {
    pub fn start() -> Result<Self, BackendError> {
        unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) }
            .map_err(|e| operation("set per-monitor DPI awareness", e))?;
        let (tx, rx) = mpsc::channel();
        let (ready_tx, ready_rx) = mpsc::sync_channel(1);
        thread::Builder::new()
            .name("axon-uia-mta".into())
            .spawn(move || {
                let result = UiaState::new();
                let _ = ready_tx.send(result.as_ref().map(|_| ()).map_err(CloneError::from));
                let Ok(mut state) = result else { return };
                while let Ok(command) = rx.recv() {
                    state.execute(command);
                }
            })
            .map_err(|e| op("start UIA thread", e.to_string()))?;
        ready_rx
            .recv()
            .map_err(|e| op("start UIA thread", e.to_string()))?
            .map_err(BackendError::from)?;
        Ok(Self { tx })
    }
    fn immediate_node(&self, e: &IUIAutomationElement) -> Result<Node, BackendError> {
        let ct = unsafe { e.CurrentControlType() }
            .map_err(|e| operation("read hit ControlType", e))?;
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
            children: vec![],
            child_count: None,
            truncation_reason: None,
        })
    }
    fn call<T>(
        &self,
        make: impl FnOnce(mpsc::Sender<Result<T, BackendError>>) -> Command,
    ) -> Result<T, BackendError> {
        let (tx, rx) = mpsc::channel();
        self.tx
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
    _com: ComApartment,
}
impl UiaState {
    fn new() -> Result<Self, BackendError> {
        let com = ComApartment::mta()?;
        let automation = create_automation()?;
        // Provider timeouts improve resilience but are not a prerequisite for UIA itself.
        // Older providers may expose only IUIAutomation; service startup must still work.
        if let Ok(automation2) = automation.cast::<IUIAutomation2>() {
            unsafe {
                automation2
                    .SetConnectionTimeout(1500)
                    .map_err(|e| operation("set UIA connection timeout", e))?;
                automation2
                    .SetTransactionTimeout(1500)
                    .map_err(|e| operation("set UIA transaction timeout", e))?;
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
            Command::Hit((x, y), tx) => {
                let _ = tx.send(unsafe {
                    self.automation.ElementFromPoint(POINT {
                        x: x.round() as i32,
                        y: y.round() as i32,
                    })
                }
                .map_err(|e| operation("hit test", e))
                .and_then(|element| self.immediate_node(&element).map(Some)));
            }
        }
        Ok(Self {
            automation,
            snapshot: None,
            elements: vec![],
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
            Command::Invoke(h, tx) => {
                let _ = tx.send(self.element(&h).and_then(|e| {
                    let p: IUIAutomationInvokePattern =
                        unsafe { e.GetCurrentPatternAs(UIA_InvokePatternId) }
                            .map_err(|e| operation("get InvokePattern", e))?;
                    unsafe { p.Invoke() }.map_err(|e| operation("invoke", e))
                }));
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
        }
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
                    name,
                    identifier: unsafe { e.CurrentProcessId() }.ok().map(|x| x.to_string()),
                    windows: vec![],
                })
            })
            .collect())
    }
    fn capture(&mut self, q: AppQuery) -> Result<Snapshot, BackendError> {
        let query = q
            .name
            .or(q.identifier)
            .ok_or_else(|| op("capture", "app name or identifier is required"))?
            .to_lowercase();
        let window = self
            .top_level()?
            .into_iter()
            .find(|e| {
                let name = unsafe { e.CurrentName() }
                    .unwrap_or_default()
                    .to_string()
                    .to_lowercase();
                let pid = unsafe { e.CurrentProcessId() }
                    .unwrap_or_default()
                    .to_string();
                name == query || name.contains(&query) || pid == query
            })
            .ok_or_else(|| op("capture", format!("no top-level window matches {query:?}")))?;
        if let Ok(hwnd) = unsafe { window.CurrentNativeWindowHandle() } {
            msaa::activate(hwnd.0 as isize);
        }
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
            name: title.clone().unwrap_or_else(|| query.clone()),
            identifier: unsafe { window.CurrentProcessId() }
                .ok()
                .map(|x| x.to_string()),
            windows: vec![Window { title, root }],
        });
        self.snapshot = Some(snapshot.clone());
        Ok(snapshot)
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
            Capability::HitTest,
        ]
        .into_iter()
        .map(|capability| CapabilityInfo {
            capability,
            usable: true,
            restriction: None,
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
    fn keyboard(&mut self, _: &AppQuery, s: &str) -> Result<(), BackendError> {
        send_text(s)
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
    fn screenshot(&mut self, _: &AppQuery) -> Result<Screenshot, BackendError> {
        Err(cap(Capability::Screenshot, "not implemented"))
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
}

pub struct IntegrationProbe;
impl IntegrationProbe {
    pub fn run(args: &[String]) -> Result<serde_json::Value, BackendError> {
        let command = args.first().map(String::as_str).ok_or_else(|| {
            op("probe", "expected value <app-query>, events <app-query> [seconds], or timeout [app-query] [milliseconds]")
        })?;
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
    let w = unsafe { GetSystemMetrics(SM_CXSCREEN) }.max(1) as f64;
    let h = unsafe { GetSystemMetrics(SM_CYSCREEN) }.max(1) as f64;
    let mi = |flags| INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT {
                dx: (x * 65535.0 / w) as i32,
                dy: (y * 65535.0 / h) as i32,
                mouseData: 0,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    let inputs = [
        mi(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE),
        mi(MOUSEEVENTF_LEFTDOWN | MOUSEEVENTF_ABSOLUTE),
        mi(MOUSEEVENTF_LEFTUP | MOUSEEVENTF_ABSOLUTE),
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
                capability: Some(capability.clone()),
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
