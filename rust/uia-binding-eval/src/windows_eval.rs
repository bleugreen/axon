use std::{
    ffi::c_void,
    fmt,
    sync::{Arc, Mutex},
    thread,
    time::{Duration, Instant},
};

use windows::{
    Win32::{
        System::Com::{
            CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx,
            CoUninitialize,
        },
        System::Variant::VARIANT,
        UI::Accessibility::{
            AutomationElementMode_Full, CUIAutomation, IUIAutomation, IUIAutomation2,
            IUIAutomationCacheRequest, IUIAutomationElement, IUIAutomationFocusChangedEventHandler,
            IUIAutomationFocusChangedEventHandler_Impl, IUIAutomationInvokePattern,
            IUIAutomationScrollItemPattern, IUIAutomationTreeWalker, IUIAutomationValuePattern,
            TreeScope_Children, TreeScope_Descendants, TreeScope_Element,
            UIA_AutomationIdPropertyId, UIA_BoundingRectanglePropertyId, UIA_ControlTypePropertyId,
            UIA_InvokePatternId, UIA_NamePropertyId, UIA_ScrollItemPatternId, UIA_ValuePatternId,
        },
    },
    core::{BSTR, Error as WinError, HRESULT, Interface, Ref, Result as WinResult, implement},
};

#[derive(Debug)]
pub(super) enum EvalError {
    InvalidInput(String),
    NotFound(String),
    Unsupported(String),
    Timeout {
        operation: &'static str,
        elapsed: Duration,
    },
    ProviderUnavailable {
        operation: &'static str,
        diagnostic: String,
    },
    Native {
        operation: &'static str,
        diagnostic: String,
    },
}

fn configure_provider_timeouts(
    automation: &IUIAutomation,
    timeout_ms: u32,
) -> Result<(), EvalError> {
    let automation2: IUIAutomation2 = automation
        .cast()
        .map_err(|error| native("query IUIAutomation2", error))?;
    unsafe {
        automation2
            .SetConnectionTimeout(timeout_ms)
            .map_err(|error| native("set provider connection timeout", error))?;
        automation2
            .SetTransactionTimeout(timeout_ms)
            .map_err(|error| native("set provider transaction timeout", error))?;
    }
    println!(
        "provider_timeouts connection_ms={timeout_ms} transaction_ms={timeout_ms} cancellation=deadline-between-calls"
    );
    Ok(())
}

impl fmt::Display for EvalError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidInput(message) | Self::NotFound(message) | Self::Unsupported(message) => {
                f.write_str(message)
            }
            Self::Timeout { operation, elapsed } => {
                write!(f, "{operation} timed out after {elapsed:?}")
            }
            Self::ProviderUnavailable {
                operation,
                diagnostic,
            } => write!(f, "{operation}: provider unavailable ({diagnostic})"),
            Self::Native {
                operation,
                diagnostic,
            } => write!(f, "{operation}: native operation failed ({diagnostic})"),
        }
    }
}

impl std::error::Error for EvalError {}

fn native(operation: &'static str, error: WinError) -> EvalError {
    // UIA_E_ELEMENTNOTAVAILABLE. Keep the HRESULT in diagnostics, never in the typed boundary.
    if error.code() == HRESULT(0x80040201_u32 as i32) {
        EvalError::ProviderUnavailable {
            operation,
            diagnostic: error.to_string(),
        }
    } else {
        EvalError::Native {
            operation,
            diagnostic: error.to_string(),
        }
    }
}

struct ComApartment;
impl ComApartment {
    fn mta() -> Result<Self, EvalError> {
        unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }
            .ok()
            .map_err(|error| native("initialize COM MTA", error))?;
        Ok(Self)
    }
}
impl Drop for ComApartment {
    fn drop(&mut self) {
        unsafe { CoUninitialize() }
    }
}

pub(super) fn run(args: Vec<String>) -> Result<(), EvalError> {
    let _apartment = ComApartment::mta()?;
    let automation: IUIAutomation =
        unsafe { CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER) }
            .map_err(|error| native("create UI Automation client", error))?;
    configure_provider_timeouts(&automation, 1_000)?;

    let command = args.first().map(String::as_str).unwrap_or("benchmark");
    match command {
        "benchmark" => benchmark(
            &automation,
            arg(&args, "--window").unwrap_or("cairn"),
            number(&args, "--max-nodes", 250)?,
        ),
        "patterns" => patterns(
            &automation,
            arg(&args, "--window").unwrap_or("cairn"),
            arg(&args, "--name").unwrap_or("Continue"),
            arg(&args, "--set-value"),
        ),
        "events" => events(&automation, number(&args, "--seconds", 20)? as u64),
        other => Err(EvalError::InvalidInput(format!(
            "unknown command {other:?}; expected benchmark, patterns, or events"
        ))),
    }
}

fn arg<'a>(args: &'a [String], flag: &str) -> Option<&'a str> {
    args.windows(2)
        .find(|pair| pair[0] == flag)
        .map(|pair| pair[1].as_str())
}
fn number(args: &[String], flag: &str, default: usize) -> Result<usize, EvalError> {
    arg(args, flag).map_or(Ok(default), |value| {
        value
            .parse()
            .map_err(|_| EvalError::InvalidInput(format!("{flag} requires an integer")))
    })
}

fn benchmark(
    automation: &IUIAutomation,
    window_name: &str,
    max_nodes: usize,
) -> Result<(), EvalError> {
    let window = find_window(automation, window_name)?;
    let hwnd = unsafe { window.CurrentNativeWindowHandle() }
        .map_err(|e| native("read window handle", e))?;
    let activation = msaa::activate(hwnd.0 as isize);
    println!(
        "msaa_activation attempted_hwnds={} successful_queries={}",
        activation.0, activation.1
    );
    let root_web = wait_for_root_web_area(automation, &window, Duration::from_secs(5))?;
    let condition = unsafe { automation.CreateTrueCondition() }
        .map_err(|e| native("create true condition", e))?;

    let started = Instant::now();
    let uncached = unsafe { root_web.FindAll(TreeScope_Descendants, &condition) }
        .map_err(|e| native("FindAll uncached", e))?;
    let uncached_nodes = snapshot_array(&uncached, max_nodes, false)?;
    let uncached_elapsed = started.elapsed();

    let cache = cache_request(automation)?;
    let started = Instant::now();
    let cached = unsafe { root_web.FindAllBuildCache(TreeScope_Descendants, &condition, &cache) }
        .map_err(|e| native("FindAllBuildCache", e))?;
    let cached_nodes = snapshot_array(&cached, max_nodes, true)?;
    let cached_elapsed = started.elapsed();

    let walker = unsafe { automation.ControlViewWalker() }
        .map_err(|e| native("create ControlView walker", e))?;
    let started = Instant::now();
    let manual_count = manual_walk(&walker, &root_web, max_nodes)?;
    let manual_elapsed = started.elapsed();

    println!(
        "benchmark nodes={} uncached_ms={:.3} cached_ms={:.3} manual_walker_nodes={} manual_walker_ms={:.3}",
        cached_nodes,
        uncached_elapsed.as_secs_f64() * 1000.0,
        cached_elapsed.as_secs_f64() * 1000.0,
        manual_count,
        manual_elapsed.as_secs_f64() * 1000.0
    );
    println!(
        "condition_findall_nodes={uncached_nodes} cache_properties=ControlType,Name,AutomationId,BoundingRectangle"
    );
    Ok(())
}

fn cache_request(automation: &IUIAutomation) -> Result<IUIAutomationCacheRequest, EvalError> {
    let cache = unsafe { automation.CreateCacheRequest() }
        .map_err(|e| native("create cache request", e))?;
    unsafe {
        cache
            .SetAutomationElementMode(AutomationElementMode_Full)
            .map_err(|e| native("configure cache element mode", e))?;
        cache
            .SetTreeScope(TreeScope_Element)
            .map_err(|e| native("configure cache tree scope", e))?;
        for property in [
            UIA_ControlTypePropertyId,
            UIA_NamePropertyId,
            UIA_AutomationIdPropertyId,
            UIA_BoundingRectanglePropertyId,
        ] {
            cache
                .AddProperty(property)
                .map_err(|e| native("add cached property", e))?;
        }
    }
    Ok(cache)
}

fn snapshot_array(
    array: &windows::Win32::UI::Accessibility::IUIAutomationElementArray,
    max_nodes: usize,
    cached: bool,
) -> Result<usize, EvalError> {
    let len = unsafe { array.Length() }
        .map_err(|e| native("read result length", e))?
        .max(0) as usize;
    for index in 0..len.min(max_nodes) {
        let element = unsafe { array.GetElement(index as i32) }
            .map_err(|e| native("read result element", e))?;
        if cached {
            unsafe {
                element
                    .CachedControlType()
                    .map_err(|e| native("read cached ControlType", e))?;
                element
                    .CachedName()
                    .map_err(|e| native("read cached Name", e))?;
                element
                    .CachedAutomationId()
                    .map_err(|e| native("read cached AutomationId", e))?;
                element
                    .CachedBoundingRectangle()
                    .map_err(|e| native("read cached BoundingRectangle", e))?;
            }
        } else {
            unsafe {
                element
                    .CurrentControlType()
                    .map_err(|e| native("read current ControlType", e))?;
                element
                    .CurrentName()
                    .map_err(|e| native("read current Name", e))?;
                element
                    .CurrentAutomationId()
                    .map_err(|e| native("read current AutomationId", e))?;
                element
                    .CurrentBoundingRectangle()
                    .map_err(|e| native("read current BoundingRectangle", e))?;
            }
        }
    }
    Ok(len.min(max_nodes))
}

fn manual_walk(
    walker: &IUIAutomationTreeWalker,
    root: &IUIAutomationElement,
    limit: usize,
) -> Result<usize, EvalError> {
    let mut stack = vec![root.clone()];
    let mut count = 0;
    while let Some(parent) = stack.pop() {
        if count >= limit {
            break;
        }
        count += 1;
        let Ok(mut child) = (unsafe { walker.GetFirstChildElement(&parent) }) else {
            continue;
        };
        loop {
            stack.push(child.clone());
            match unsafe { walker.GetNextSiblingElement(&child) } {
                Ok(next) => child = next,
                Err(_) => break,
            }
        }
    }
    Ok(count)
}

fn patterns(
    automation: &IUIAutomation,
    window_name: &str,
    name: &str,
    set_value: Option<&str>,
) -> Result<(), EvalError> {
    let window = find_window(automation, window_name)?;
    let name_value = VARIANT::from(BSTR::from(name));
    let condition = unsafe { automation.CreatePropertyCondition(UIA_NamePropertyId, &name_value) }
        .map_err(|e| native("create name condition", e))?;
    let element = unsafe { window.FindFirst(TreeScope_Descendants, &condition) }
        .map_err(|e| native("find pattern target", e))?;
    let invoke: WinResult<IUIAutomationInvokePattern> =
        unsafe { element.GetCurrentPatternAs(UIA_InvokePatternId) };
    let value: WinResult<IUIAutomationValuePattern> =
        unsafe { element.GetCurrentPatternAs(UIA_ValuePatternId) };
    let scroll: WinResult<IUIAutomationScrollItemPattern> =
        unsafe { element.GetCurrentPatternAs(UIA_ScrollItemPatternId) };
    println!(
        "pattern_support invoke={} value={} scroll_item={}",
        invoke.is_ok(),
        value.is_ok(),
        scroll.is_ok()
    );
    if let Some(new_value) = set_value {
        let pattern = value
            .map_err(|_| EvalError::Unsupported("target does not support ValuePattern".into()))?;
        unsafe { pattern.SetValue(&BSTR::from(new_value)) }
            .map_err(|e| native("set ValuePattern value", e))?;
        println!("value_set=true");
    }
    if let Ok(pattern) = scroll {
        unsafe { pattern.ScrollIntoView() }
            .map_err(|e| native("ScrollItemPattern.ScrollIntoView", e))?;
        println!("scroll_into_view=true");
    }
    if let Ok(pattern) = invoke {
        unsafe { pattern.Invoke() }.map_err(|e| native("InvokePattern.Invoke", e))?;
        println!("invoke=true");
    }
    Ok(())
}

#[implement(IUIAutomationFocusChangedEventHandler)]
struct FocusHandler {
    records: Arc<Mutex<Vec<String>>>,
    owner_thread: thread::ThreadId,
}
impl IUIAutomationFocusChangedEventHandler_Impl for FocusHandler_Impl {
    fn HandleFocusChangedEvent(&self, sender: Ref<'_, IUIAutomationElement>) -> WinResult<()> {
        let _ = sender;
        let callback_thread = format!("{:?}", thread::current().id());
        self.records.lock().unwrap().push(format!(
            "callback_thread={callback_thread} owner_thread={:?}",
            self.owner_thread
        ));
        Ok(())
    }
}

fn events(automation: &IUIAutomation, seconds: u64) -> Result<(), EvalError> {
    let records = Arc::new(Mutex::new(Vec::new()));
    let handler: IUIAutomationFocusChangedEventHandler = FocusHandler {
        records: records.clone(),
        owner_thread: thread::current().id(),
    }
    .into();
    unsafe { automation.AddFocusChangedEventHandler(None, &handler) }
        .map_err(|e| native("register focus handler", e))?;
    println!(
        "event_handler_registered apartment=MTA owner_thread={:?} wait_seconds={seconds}",
        thread::current().id()
    );
    thread::sleep(Duration::from_secs(seconds));
    unsafe { automation.RemoveFocusChangedEventHandler(&handler) }
        .map_err(|e| native("remove focus handler", e))?;
    let records = records.lock().unwrap();
    println!("focus_events={}", records.len());
    for record in records.iter() {
        println!("{record}");
    }
    Ok(())
}

fn find_window(automation: &IUIAutomation, query: &str) -> Result<IUIAutomationElement, EvalError> {
    let root = unsafe { automation.GetRootElement() }.map_err(|e| native("get desktop root", e))?;
    let condition = unsafe { automation.CreateTrueCondition() }
        .map_err(|e| native("create true condition", e))?;
    let windows = unsafe { root.FindAll(TreeScope_Children, &condition) }
        .map_err(|e| native("enumerate windows", e))?;
    let len = unsafe { windows.Length() }.map_err(|e| native("read windows length", e))?;
    let query = query.to_lowercase();
    let mut partial = None;
    for index in 0..len {
        let element = unsafe { windows.GetElement(index) }.map_err(|e| native("read window", e))?;
        let name = unsafe { element.CurrentName() }
            .unwrap_or_default()
            .to_string();
        if name.to_lowercase() == query {
            return Ok(element);
        }
        if partial.is_none() && name.to_lowercase().contains(&query) {
            partial = Some(element);
        }
    }
    partial.ok_or_else(|| EvalError::NotFound(format!("no top-level window matches {query:?}")))
}

fn wait_for_root_web_area(
    automation: &IUIAutomation,
    window: &IUIAutomationElement,
    timeout: Duration,
) -> Result<IUIAutomationElement, EvalError> {
    let value = VARIANT::from(BSTR::from("RootWebArea"));
    let condition =
        unsafe { automation.CreatePropertyCondition(UIA_AutomationIdPropertyId, &value) }
            .map_err(|e| native("create RootWebArea condition", e))?;
    let started = Instant::now();
    loop {
        if let Ok(element) = unsafe { window.FindFirst(TreeScope_Descendants, &condition) } {
            return Ok(element);
        }
        if started.elapsed() >= timeout {
            return Err(EvalError::Timeout {
                operation: "wait for RootWebArea",
                elapsed: started.elapsed(),
            });
        }
        thread::sleep(Duration::from_millis(100));
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
    pub fn activate(hwnd: isize) -> (usize, usize) {
        let mut r = (0, 0);
        touch(hwnd, &mut r);
        unsafe {
            EnumChildWindows(hwnd, visit, (&mut r as *mut (usize, usize)) as isize);
        };
        r
    }
    unsafe extern "system" fn visit(hwnd: isize, param: isize) -> i32 {
        touch(hwnd, unsafe { &mut *(param as *mut (usize, usize)) });
        1
    }
    fn touch(hwnd: isize, r: &mut (usize, usize)) {
        r.0 += 1;
        let mut out = std::ptr::null_mut();
        if unsafe { AccessibleObjectFromWindow(hwnd, (-4_i32) as u32, &IID, &mut out) } >= 0
            && !out.is_null()
        {
            r.1 += 1;
            unsafe { release(out) }
        }
    }
    unsafe fn release(object: *mut c_void) {
        let v = unsafe { *(object as *mut *mut *mut c_void) };
        let f: unsafe extern "system" fn(*mut c_void) -> u32 =
            unsafe { std::mem::transmute(*v.add(2)) };
        unsafe { f(object) };
    }
}
