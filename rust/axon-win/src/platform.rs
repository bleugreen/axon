use axon_core::{Application, AppQuery, BackendError, Capability, CapabilityInfo, Node, Observation, PlatformBackend, Rect, RecordedCall, Screenshot, Snapshot, SnapshotHandle, Window};
use std::{ffi::c_void, sync::mpsc, thread, time::Duration};
use windows::{
    core::{BSTR, Interface},
    Win32::{Foundation::POINT, System::Com::{CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx, CoUninitialize}, UI::{Accessibility::{CUIAutomation, IUIAutomation, IUIAutomation2, IUIAutomationElement, IUIAutomationInvokePattern, IUIAutomationScrollItemPattern, IUIAutomationTreeWalker, IUIAutomationValuePattern, TreeScope_Children, UIA_ButtonControlTypeId, UIA_CheckBoxControlTypeId, UIA_ComboBoxControlTypeId, UIA_CustomControlTypeId, UIA_DocumentControlTypeId, UIA_EditControlTypeId, UIA_GroupControlTypeId, UIA_HyperlinkControlTypeId, UIA_ImageControlTypeId, UIA_InvokePatternId, UIA_ListControlTypeId, UIA_ListItemControlTypeId, UIA_MenuControlTypeId, UIA_MenuItemControlTypeId, UIA_PaneControlTypeId, UIA_ProgressBarControlTypeId, UIA_RadioButtonControlTypeId, UIA_ScrollBarControlTypeId, UIA_ScrollItemPatternId, UIA_SliderControlTypeId, UIA_TabControlTypeId, UIA_TabItemControlTypeId, UIA_TextControlTypeId, UIA_ThumbControlTypeId, UIA_ToolBarControlTypeId, UIA_ToolTipControlTypeId, UIA_TreeControlTypeId, UIA_TreeItemControlTypeId, UIA_ValuePatternId, UIA_WindowControlTypeId}, HiDpi::{DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetProcessDpiAwarenessContext}, Input::KeyboardAndMouse::{INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP, KEYEVENTF_UNICODE, MOUSEEVENTF_ABSOLUTE, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MOVE, MOUSEINPUT, KEYBDINPUT, SendInput, VIRTUAL_KEY}, WindowsAndMessaging::{GetSystemMetrics, SM_CXSCREEN, SM_CYSCREEN}}},
};

const MAX_DEPTH: usize = 18;
const MAX_CHILDREN: usize = 200;
const MAX_NODES: usize = 2_000;

enum Command {
    Enumerate(mpsc::Sender<Result<Vec<Application>, BackendError>>),
    Capture(AppQuery, mpsc::Sender<Result<Snapshot, BackendError>>),
    Invoke(SnapshotHandle, mpsc::Sender<Result<(), BackendError>>),
    Read(SnapshotHandle, mpsc::Sender<Result<Option<String>, BackendError>>),
    Set(SnapshotHandle, String, mpsc::Sender<Result<(), BackendError>>),
    Focus(SnapshotHandle, mpsc::Sender<Result<(), BackendError>>),
    Scroll(SnapshotHandle, mpsc::Sender<Result<(), BackendError>>),
}

pub struct WindowsBackend { tx: mpsc::Sender<Command> }

impl WindowsBackend {
    pub fn start() -> Result<Self, BackendError> {
        unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) }
            .map_err(|e| operation("set per-monitor DPI awareness", e))?;
        let (tx, rx) = mpsc::channel();
        let (ready_tx, ready_rx) = mpsc::sync_channel(1);
        thread::Builder::new().name("axon-uia-mta".into()).spawn(move || {
            let result = UiaState::new();
            let _ = ready_tx.send(result.as_ref().map(|_| ()).map_err(CloneError::from));
            let Ok(mut state) = result else { return };
            while let Ok(command) = rx.recv() { state.execute(command); }
        }).map_err(|e| op("start UIA thread", e.to_string()))?;
        ready_rx.recv().map_err(|e| op("start UIA thread", e.to_string()))?.map_err(BackendError::from)?;
        Ok(Self { tx })
    }
    fn call<T>(&self, make: impl FnOnce(mpsc::Sender<Result<T, BackendError>>) -> Command) -> Result<T, BackendError> {
        let (tx, rx) = mpsc::channel(); self.tx.send(make(tx)).map_err(|e| op("send UIA command", e.to_string()))?;
        rx.recv().map_err(|e| op("receive UIA result", e.to_string()))?
    }
}

struct UiaState { automation: IUIAutomation, walker: IUIAutomationTreeWalker, snapshot: Option<Snapshot>, elements: Vec<IUIAutomationElement>, _com: ComApartment }
impl UiaState {
    fn new() -> Result<Self, BackendError> {
        let com = ComApartment::mta()?;
        let automation: IUIAutomation = unsafe { CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER) }.map_err(|e| operation("create UI Automation client", e))?;
        let automation2: IUIAutomation2 = automation.cast().map_err(|e| operation("query IUIAutomation2", e))?;
        unsafe { automation2.SetConnectionTimeout(1500).map_err(|e| operation("set UIA connection timeout", e))?; automation2.SetTransactionTimeout(1500).map_err(|e| operation("set UIA transaction timeout", e))?; }
        let walker = unsafe { automation.ControlViewWalker() }.map_err(|e| operation("create control-view walker", e))?;
        Ok(Self { automation, walker, snapshot: None, elements: vec![], _com: com })
    }
    fn execute(&mut self, command: Command) { match command {
        Command::Enumerate(tx) => { let _=tx.send(self.enumerate()); }, Command::Capture(q,tx) => { let _=tx.send(self.capture(q)); },
        Command::Invoke(h,tx) => { let _=tx.send(self.element(&h).and_then(|e| { let p:IUIAutomationInvokePattern=unsafe{e.GetCurrentPatternAs(UIA_InvokePatternId)}.map_err(|e|operation("get InvokePattern",e))?; unsafe{p.Invoke()}.map_err(|e|operation("invoke",e)) })); },
        Command::Read(h,tx) => { let _=tx.send(self.element(&h).and_then(|e| { let p:IUIAutomationValuePattern=unsafe{e.GetCurrentPatternAs(UIA_ValuePatternId)}.map_err(|e|operation("get ValuePattern",e))?; unsafe{p.CurrentValue()}.map(|v|Some(v.to_string())).map_err(|e|operation("read value",e)) })); },
        Command::Set(h,v,tx) => { let _=tx.send(self.element(&h).and_then(|e| { let p:IUIAutomationValuePattern=unsafe{e.GetCurrentPatternAs(UIA_ValuePatternId)}.map_err(|e|operation("get ValuePattern",e))?; unsafe{p.SetValue(&BSTR::from(v))}.map_err(|e|operation("set value",e)) })); },
        Command::Focus(h,tx) => { let _=tx.send(self.element(&h).and_then(|e|unsafe{e.SetFocus()}.map_err(|e|operation("set focus",e)))); },
        Command::Scroll(h,tx) => { let _=tx.send(self.element(&h).and_then(|e| { let p:IUIAutomationScrollItemPattern=unsafe{e.GetCurrentPatternAs(UIA_ScrollItemPatternId)}.map_err(|e|operation("get ScrollItemPattern",e))?; unsafe{p.ScrollIntoView()}.map_err(|e|operation("scroll into view",e)) })); }
    }}
    fn top_level(&self) -> Result<Vec<IUIAutomationElement>, BackendError> { let root=unsafe{self.automation.GetRootElement()}.map_err(|e|operation("get desktop root",e))?; let c=unsafe{self.automation.CreateTrueCondition()}.map_err(|e|operation("create condition",e))?; let a=unsafe{root.FindAll(TreeScope_Children,&c)}.map_err(|e|operation("enumerate windows",e))?; let n=unsafe{a.Length()}.map_err(|e|operation("read window count",e))?; (0..n).map(|i|unsafe{a.GetElement(i)}.map_err(|e|operation("read window",e))).collect() }
    fn enumerate(&self) -> Result<Vec<Application>, BackendError> { Ok(self.top_level()?.into_iter().filter_map(|e| { let name=unsafe{e.CurrentName()}.ok()?.to_string(); (!name.is_empty()).then(||Application{name,identifier:unsafe{e.CurrentProcessId()}.ok().map(|x|x.to_string()),windows:vec![]}) }).collect()) }
    fn capture(&mut self, q: AppQuery) -> Result<Snapshot, BackendError> {
        let query=q.name.or(q.identifier).ok_or_else(||op("capture","app name or identifier is required"))?.to_lowercase();
        let window=self.top_level()?.into_iter().find(|e| { let name=unsafe{e.CurrentName()}.unwrap_or_default().to_string().to_lowercase(); let pid=unsafe{e.CurrentProcessId()}.unwrap_or_default().to_string(); name==query||name.contains(&query)||pid==query }).ok_or_else(||op("capture",format!("no top-level window matches {query:?}")))?;
        if let Ok(hwnd)=unsafe{window.CurrentNativeWindowHandle()} { msaa::activate(hwnd.0 as isize); }
        self.elements.clear(); let mut count=0; let root=self.capture_node(&window,0,&mut count)?; let title=unsafe{window.CurrentName()}.ok().map(|x|x.to_string());
        let snapshot=Snapshot::new(Application{name:title.clone().unwrap_or_else(||query.clone()),identifier:unsafe{window.CurrentProcessId()}.ok().map(|x|x.to_string()),windows:vec![Window{title,root}]}); self.snapshot=Some(snapshot.clone()); Ok(snapshot)
    }
    fn capture_node(&mut self,e:&IUIAutomationElement,depth:usize,count:&mut usize)->Result<Node,BackendError>{
        *count+=1; self.elements.push(e.clone()); let ct=unsafe{e.CurrentControlType()}.unwrap_or_default(); let mut actions=Vec::new(); if unsafe{e.GetCurrentPatternAs::<IUIAutomationInvokePattern>(UIA_InvokePatternId)}.is_ok(){actions.push("Invoke".into())} if unsafe{e.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)}.is_ok(){actions.push("Value".into())} if unsafe{e.GetCurrentPatternAs::<IUIAutomationScrollItemPattern>(UIA_ScrollItemPatternId)}.is_ok(){actions.push("ScrollItem".into())}
        let mut children=Vec::new(); let mut child_count=0; let mut trunc=None; let mut child=unsafe{self.walker.GetFirstChildElement(e)}.ok(); while let Some(c)=child { child_count+=1; if depth>=MAX_DEPTH||children.len()>=MAX_CHILDREN||*count>=MAX_NODES {trunc=Some(if depth>=MAX_DEPTH{"maxDepth"}else if *count>=MAX_NODES{"maxNodes"}else{"maxChildren"}.into()); break} children.push(self.capture_node(&c,depth+1,count)?); child=unsafe{self.walker.GetNextSiblingElement(&c)}.ok(); }
        let r=unsafe{e.CurrentBoundingRectangle()}.ok(); let name=unsafe{e.CurrentName()}.ok().map(|x|x.to_string()).filter(|x|!x.is_empty()); let id=unsafe{e.CurrentAutomationId()}.ok().map(|x|x.to_string()).filter(|x|!x.is_empty()); let value=unsafe{e.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)}.ok().and_then(|p|unsafe{p.CurrentValue()}.ok()).map(|x|x.to_string());
        Ok(Node{role:control_type_name(ct.0).into(),subrole:None,name:name.clone(),title:name.clone(),label:name,value,description:unsafe{e.CurrentHelpText()}.ok().map(|x|x.to_string()).filter(|x|!x.is_empty()),identifier:id,actions,frame:r.map(|x|Rect{x:x.left,y:x.top,width:x.right-x.left,height:x.bottom-x.top}),editable:ct==UIA_EditControlTypeId||ct==UIA_DocumentControlTypeId,children,child_count:Some(child_count),truncation_reason:trunc})
    }
    fn element(&self,h:&SnapshotHandle)->Result<IUIAutomationElement,BackendError>{let s=self.snapshot.as_ref().ok_or_else(||op("resolve handle","no active snapshot"))?;let i=s.index_for_handle(h).map_err(|e|op("resolve handle",e.to_string()))?;self.elements.get(i).cloned().ok_or_else(||op("resolve handle","handle index outside snapshot"))}
}

impl PlatformBackend for WindowsBackend {
    fn capabilities(&self)->Result<Vec<CapabilityInfo>,BackendError>{Ok([Capability::Enumerate,Capability::Capture,Capability::RetainedHandles,Capability::Invoke,Capability::ReadValue,Capability::SetValue,Capability::Focus,Capability::Scroll,Capability::PointerInput,Capability::KeyboardInput].into_iter().map(|capability|CapabilityInfo{capability,usable:true,restriction:None}).collect())}
    fn enumerate_applications(&self)->Result<Vec<Application>,BackendError>{self.call(Command::Enumerate)} fn capture(&mut self,q:&AppQuery)->Result<Snapshot,BackendError>{self.call(|tx|Command::Capture(q.clone(),tx))} fn invoke(&mut self,h:&SnapshotHandle,_:&str)->Result<(),BackendError>{self.call(|tx|Command::Invoke(h.clone(),tx))} fn read_value(&self,h:&SnapshotHandle)->Result<Option<String>,BackendError>{self.call(|tx|Command::Read(h.clone(),tx))} fn set_value(&mut self,h:&SnapshotHandle,v:&str)->Result<(),BackendError>{self.call(|tx|Command::Set(h.clone(),v.into(),tx))} fn focus(&mut self,h:&SnapshotHandle)->Result<(),BackendError>{self.call(|tx|Command::Focus(h.clone(),tx))} fn scroll(&mut self,h:&SnapshotHandle,_:(f64,f64))->Result<(),BackendError>{self.call(|tx|Command::Scroll(h.clone(),tx))}
    fn pointer_click(&mut self,p:(f64,f64))->Result<(),BackendError>{send_click(p)} fn keyboard(&mut self,_:&AppQuery,s:&str)->Result<(),BackendError>{send_text(s)}
    fn observe(&mut self,_:&AppQuery,_:Duration)->Result<Observation,BackendError>{Err(cap(Capability::ObserveChanges,"event observation is probe-only in v1"))} fn wait_for_value(&mut self,_:&SnapshotHandle,_:&serde_json::Value,_:Duration)->Result<Observation,BackendError>{Err(cap(Capability::ObserveChanges,"excluded from v1"))} fn pointer_drag(&mut self,_:(f64,f64),_:(f64,f64),_:Duration)->Result<(),BackendError>{Err(cap(Capability::PointerInput,"drag excluded from v1"))} fn screenshot(&mut self,_:&AppQuery)->Result<Screenshot,BackendError>{Err(cap(Capability::Screenshot,"not implemented"))} fn hit_test(&mut self,_:(f64,f64))->Result<Option<Node>,BackendError>{Err(cap(Capability::HitTest,"not implemented"))} fn recorded_calls(&self)->Result<Vec<RecordedCall>,BackendError>{Err(cap(Capability::SerializeHistory,"excluded from v1"))} fn set_recording(&mut self,_:bool)->Result<(),BackendError>{Err(cap(Capability::SerializeHistory,"excluded from v1"))} fn observe_global_input(&mut self,_:Duration)->Result<Vec<RecordedCall>,BackendError>{Err(cap(Capability::ObserveGlobalInput,"excluded from v1"))}
}

pub struct IntegrationProbe;
impl IntegrationProbe { pub fn run() -> Result<serde_json::Value,BackendError> { let _backend=WindowsBackend::start()?; Ok(serde_json::json!({"uiaThread":"MTA","connectionTimeoutMs":1500,"transactionTimeoutMs":1500,"valuePattern":{"status":"requires --app/--locator live target"},"automationEvents":{"status":"manual session-1 interaction required"},"structureEvents":{"status":"manual session-1 interaction required"}})) } }

fn send_text(text:&str)->Result<(),BackendError>{let mut inputs=Vec::new();for unit in text.encode_utf16(){for flags in [KEYEVENTF_UNICODE,KEYEVENTF_UNICODE|KEYEVENTF_KEYUP]{inputs.push(INPUT{r#type:INPUT_KEYBOARD,Anonymous:INPUT_0{ki:KEYBDINPUT{wVk:VIRTUAL_KEY(0),wScan:unit,dwFlags:flags,time:0,dwExtraInfo:0}}})}}let sent=unsafe{SendInput(&inputs,std::mem::size_of::<INPUT>() as i32)};if sent!=inputs.len() as u32{return Err(op("SendInput keyboard",format!("sent {sent} of {} events",inputs.len())))}Ok(())}
fn send_click((x,y):(f64,f64))->Result<(),BackendError>{let w=unsafe{GetSystemMetrics(SM_CXSCREEN)}.max(1) as f64;let h=unsafe{GetSystemMetrics(SM_CYSCREEN)}.max(1) as f64;let mi=|flags|INPUT{r#type:INPUT_MOUSE,Anonymous:INPUT_0{mi:MOUSEINPUT{dx:(x*65535.0/w) as i32,dy:(y*65535.0/h) as i32,mouseData:0,dwFlags:flags,time:0,dwExtraInfo:0}}};let inputs=[mi(MOUSEEVENTF_MOVE|MOUSEEVENTF_ABSOLUTE),mi(MOUSEEVENTF_LEFTDOWN|MOUSEEVENTF_ABSOLUTE),mi(MOUSEEVENTF_LEFTUP|MOUSEEVENTF_ABSOLUTE)];let sent=unsafe{SendInput(&inputs,std::mem::size_of::<INPUT>() as i32)};if sent!=3{Err(op("SendInput click",format!("sent {sent} of 3 events")))}else{Ok(())}}
fn control_type_name(id:i32)->&'static str{match id{x if x==UIA_ButtonControlTypeId.0=>"Button",x if x==UIA_CheckBoxControlTypeId.0=>"CheckBox",x if x==UIA_ComboBoxControlTypeId.0=>"ComboBox",x if x==UIA_EditControlTypeId.0=>"Edit",x if x==UIA_DocumentControlTypeId.0=>"Document",x if x==UIA_HyperlinkControlTypeId.0=>"Hyperlink",x if x==UIA_ImageControlTypeId.0=>"Image",x if x==UIA_ListControlTypeId.0=>"List",x if x==UIA_ListItemControlTypeId.0=>"ListItem",x if x==UIA_MenuControlTypeId.0=>"Menu",x if x==UIA_MenuItemControlTypeId.0=>"MenuItem",x if x==UIA_PaneControlTypeId.0=>"Pane",x if x==UIA_RadioButtonControlTypeId.0=>"RadioButton",x if x==UIA_ScrollBarControlTypeId.0=>"ScrollBar",x if x==UIA_SliderControlTypeId.0=>"Slider",x if x==UIA_TabControlTypeId.0=>"Tab",x if x==UIA_TabItemControlTypeId.0=>"TabItem",x if x==UIA_TextControlTypeId.0=>"Text",x if x==UIA_TreeControlTypeId.0=>"Tree",x if x==UIA_TreeItemControlTypeId.0=>"TreeItem",x if x==UIA_WindowControlTypeId.0=>"Window",x if x==UIA_GroupControlTypeId.0=>"Group",x if x==UIA_ProgressBarControlTypeId.0=>"ProgressBar",x if x==UIA_ThumbControlTypeId.0=>"Thumb",x if x==UIA_ToolBarControlTypeId.0=>"ToolBar",x if x==UIA_ToolTipControlTypeId.0=>"ToolTip",x if x==UIA_CustomControlTypeId.0=>"Custom",_=>"Unknown"}}
struct ComApartment;impl ComApartment{fn mta()->Result<Self,BackendError>{unsafe{CoInitializeEx(None,COINIT_MULTITHREADED)}.ok().map_err(|e|operation("initialize COM MTA",e))?;Ok(Self)}}impl Drop for ComApartment{fn drop(&mut self){unsafe{CoUninitialize()}}}
#[derive(Clone)]struct CloneError{capability:Option<Capability>,operation:String,message:String}impl From<&BackendError> for CloneError{fn from(e:&BackendError)->Self{match e{BackendError::Capability{capability,reason,..}=>Self{capability:Some(capability.clone()),operation:String::new(),message:reason.clone()},BackendError::Operation{operation,message,..}=>Self{capability:None,operation:operation.clone(),message:message.clone()}}}}impl From<CloneError> for BackendError{fn from(e:CloneError)->Self{if let Some(capability)=e.capability{cap(capability,e.message)}else{op(e.operation,e.message)}}}
fn operation(name:&str,e:windows::core::Error)->BackendError{BackendError::Operation{operation:name.into(),message:"native operation failed".into(),diagnostic:Some(e.to_string())}}fn op(name:impl Into<String>,message:impl Into<String>)->BackendError{BackendError::Operation{operation:name.into(),message:message.into(),diagnostic:None}}fn cap(capability:Capability,reason:impl Into<String>)->BackendError{BackendError::Capability{capability,reason:reason.into(),diagnostic:None}}

mod msaa { use super::c_void; #[repr(C)]struct Guid{data1:u32,data2:u16,data3:u16,data4:[u8;8]}const IID:Guid=Guid{data1:0x618736e0,data2:0x3c3d,data3:0x11cf,data4:[0x81,0x0c,0,0xaa,0,0x38,0x9b,0x71]};#[link(name="oleacc")]unsafe extern "system"{fn AccessibleObjectFromWindow(hwnd:isize,id:u32,iid:*const Guid,out:*mut *mut c_void)->i32;}#[link(name="user32")]unsafe extern "system"{fn EnumChildWindows(hwnd:isize,callback:unsafe extern "system" fn(isize,isize)->i32,param:isize)->i32;}pub fn activate(hwnd:isize){touch(hwnd);unsafe{EnumChildWindows(hwnd,visit,0);}}unsafe extern "system" fn visit(hwnd:isize,_:isize)->i32{touch(hwnd);1}fn touch(hwnd:isize){let mut out=std::ptr::null_mut();if unsafe{AccessibleObjectFromWindow(hwnd,(-4_i32)as u32,&IID,&mut out)}>=0&&!out.is_null(){unsafe{let v=*(out as *mut *mut *mut c_void);let release:unsafe extern "system" fn(*mut c_void)->u32=std::mem::transmute(*v.add(2));release(out);}}}}