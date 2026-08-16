//! The two AppKit windows the campaign owns: the decoy that holds the
//! foreground, and the native target whose controls a delivered click would
//! have to move.
//!
//! Both are the same program in different roles, because they need the same
//! thing — a window that reports every event `NSApplication` is handed and
//! every change to its own controls. That double reporting is what separates
//! the three outcomes a sending side cannot tell apart: an event that never
//! arrived, one that arrived and was declined, and one that was acted on.
//!
//! The event loop is AppKit's own `[NSApp run]`, not a hand-written one. That
//! matters: an `NSButton` decides it was clicked inside a mouse-tracking loop
//! it starts from `mouseDown:`, and a hand-written loop that dequeues the
//! matching `mouseUp` first stops every control from ever acting — which would
//! make the fixture report a refusal that belonged to the fixture rather than
//! to macOS. So observation is added the way AppKit intends: an
//! `NSApplication` subclass that records each event on its way through
//! `sendEvent:` and then calls super, plus a timer that polls the controls.

use std::cell::RefCell;
use std::ffi::c_void;
use std::io::Write;
use std::net::TcpStream;
use std::ptr::null_mut;
use std::time::{Duration, Instant};

use crate::args::Args;
use crate::json::J;
use crate::sys::*;

const NS_WINDOW_STYLE_TITLED: u64 = 1 << 0;
const NS_WINDOW_STYLE_CLOSABLE: u64 = 1 << 1;
const NS_WINDOW_STYLE_RESIZABLE: u64 = 1 << 3;
const NS_BACKING_STORE_BUFFERED: u64 = 2;
const NS_BUTTON_TYPE_SWITCH: u64 = 3;
const NS_APPLICATION_ACTIVATION_POLICY_REGULAR: i64 = 0;

/// Everything the two callbacks need. Both run on the main thread, which is
/// also where it is populated, so a thread local is the whole of the
/// synchronisation story.
struct Context {
    report: Option<String>,
    role: String,
    nonce: String,
    /// Null in the embedded-web-view role, where the page reports its own
    /// state over the same channel and there are no native controls to poll.
    checkbox: Id,
    field: Id,
    last_checkbox: i64,
    last_text: String,
    counts: Vec<(u64, i64)>,
    deadline: Instant,
    /// Whether the opening reading has been published. The campaign compares
    /// control state before and after a dispatch, so the baseline has to be
    /// reported even though nothing has changed yet.
    reported_baseline: bool,
}

thread_local! {
    static CONTEXT: RefCell<Option<Context>> = const { RefCell::new(None) };
}

pub fn run(args: &Args) -> Result<(), String> {
    let role = args
        .optional_string("role")
        .unwrap_or_else(|| "target".into());
    let title = args
        .optional_string("title")
        .unwrap_or_else(|| format!("axon-acceptance-{role}"));
    let nonce = args.string("nonce")?;
    let report = args.optional_string("report");
    let seconds = args.optional_f64("seconds").unwrap_or(600.0);
    let origin = CGPoint {
        x: args.optional_f64("x").unwrap_or(80.0),
        y: args.optional_f64("y").unwrap_or(80.0),
    };
    let size = CGSize {
        width: args.optional_f64("width").unwrap_or(420.0),
        height: args.optional_f64("height").unwrap_or(220.0),
    };

    let application_class = define_class(
        "AxonAcceptanceApplication",
        "NSApplication",
        &[
            ("sendEvent:", observe_event as *const c_void, "v@:@"),
            ("axonTick:", tick as *const c_void, "v@:@"),
        ],
    );
    if application_class.is_null() {
        return Err("the observing NSApplication subclass could not be registered".into());
    }
    // Sent to the subclass, so `NSApp` becomes an instance of it: AppKit builds
    // the shared application out of whichever class first asks for it.
    let application = send(application_class, "sharedApplication");
    send_i64_arg(
        application,
        "setActivationPolicy:",
        NS_APPLICATION_ACTIVATION_POLICY_REGULAR,
    );

    let window = send_rect_mask_backing_defer(
        send(class("NSWindow"), "alloc"),
        "initWithContentRect:styleMask:backing:defer:",
        CGRect { origin, size },
        NS_WINDOW_STYLE_TITLED | NS_WINDOW_STYLE_CLOSABLE | NS_WINDOW_STYLE_RESIZABLE,
        NS_BACKING_STORE_BUFFERED,
        false,
    );
    if window.is_null() {
        return Err("NSWindow could not be created".into());
    }
    send_id(window, "setTitle:", nsstring(&title));
    let view = send(window, "contentView");

    // The embedded-web-view role. Safari answers what Safari does; this answers
    // whether the answer belongs to WebKit or to Safari, which is a different
    // question and the one a future acceptance key would have to be able to
    // tell apart — an entry keyed on `com.apple.Safari` says nothing about an
    // application that embeds the same engine.
    if let Some(address) = args.optional_string("webview") {
        let bounds = send_ret_rect(view, "bounds");
        let configuration = send(send(class("WKWebViewConfiguration"), "alloc"), "init");
        let webview = send_rect_id(
            send(class("WKWebView"), "alloc"),
            "initWithFrame:configuration:",
            bounds,
            configuration,
        );
        if webview.is_null() {
            return Err("WKWebView could not be created".into());
        }
        let url = send_id(class("NSURL"), "URLWithString:", nsstring(&address));
        let request = send_id(class("NSURLRequest"), "requestWithURL:", url);
        send_id(webview, "loadRequest:", request);
        send_id(view, "addSubview:", webview);
        send_id(window, "makeKeyAndOrderFront:", null_mut());
        send_bool_arg(application, "activateIgnoringOtherApps:", true);
        send(application, "finishLaunching");
        let ready = J::obj(vec![
            ("kind", J::str("ready")),
            ("role", J::str(role.clone())),
            ("nonce", J::str(nonce.clone())),
            ("pid", J::Int(std::process::id() as i64)),
            ("windowNumber", J::Int(send_ret_i64(window, "windowNumber"))),
            ("title", J::str(title)),
            ("webview", J::str(address)),
            ("window", rect_json(screen_rect(window, view, view))),
        ]);
        println!("{}", ready.render());
        let _ = std::io::stdout().flush();
        if let Some(url) = &report {
            post(url, &ready.render());
        }
        CONTEXT.with(|context| {
            *context.borrow_mut() = Some(Context {
                report,
                role,
                nonce,
                checkbox: null_mut(),
                field: null_mut(),
                last_checkbox: 0,
                last_text: String::new(),
                counts: Vec::new(),
                deadline: Instant::now() + Duration::from_secs_f64(seconds),
                reported_baseline: true,
            });
        });
        send_timer(
            class("NSTimer"),
            "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:",
            0.05,
            application,
            sel("axonTick:"),
            null_mut(),
            true,
        );
        send(application, "run");
        return Ok(());
    }

    // A checkbox rather than a push button, because a checkbox records that it
    // was clicked in its own state: no action target is needed for the click to
    // leave a trace this process can read back.
    let checkbox = send_rect_arg(
        send(class("NSButton"), "alloc"),
        "initWithFrame:",
        CGRect {
            origin: CGPoint { x: 24.0, y: 32.0 },
            size: CGSize {
                width: size.width - 48.0,
                height: 28.0,
            },
        },
    );
    send_u64_arg(checkbox, "setButtonType:", NS_BUTTON_TYPE_SWITCH);
    send_id(checkbox, "setTitle:", nsstring("acceptance target"));
    // A switch button hit-tests what it draws — the box and its title — and not
    // the rest of its frame. Sizing it to fit makes the rectangle this fixture
    // publishes the rectangle a click can actually land in, so the centre of
    // the reported rectangle is a real target rather than empty space beside
    // the label. Without this, a control click misses and every verdict the
    // control was meant to license is a statement about the fixture.
    send(checkbox, "sizeToFit");
    send_id(view, "addSubview:", checkbox);

    let field = send_rect_arg(
        send(class("NSTextField"), "alloc"),
        "initWithFrame:",
        CGRect {
            origin: CGPoint { x: 24.0, y: 96.0 },
            size: CGSize {
                width: size.width - 48.0,
                height: 28.0,
            },
        },
    );
    send_id(field, "setStringValue:", nsstring(""));
    send_id(view, "addSubview:", field);

    send_id(window, "makeKeyAndOrderFront:", null_mut());
    send_id(window, "makeFirstResponder:", field);
    send_bool_arg(application, "activateIgnoringOtherApps:", true);
    send(application, "finishLaunching");

    let ready = J::obj(vec![
        ("kind", J::str("ready")),
        ("role", J::str(role.clone())),
        ("nonce", J::str(nonce.clone())),
        ("pid", J::Int(std::process::id() as i64)),
        ("windowNumber", J::Int(send_ret_i64(window, "windowNumber"))),
        ("title", J::str(title.clone())),
        ("window", rect_json(screen_rect(window, view, view))),
        ("checkbox", rect_json(screen_rect(window, view, checkbox))),
        ("textField", rect_json(screen_rect(window, view, field))),
    ]);
    println!("{}", ready.render());
    let _ = std::io::stdout().flush();
    if let Some(url) = &report {
        post(url, &ready.render());
    }

    CONTEXT.with(|context| {
        *context.borrow_mut() = Some(Context {
            report,
            role,
            nonce,
            checkbox,
            field,
            last_checkbox: send_ret_i64(checkbox, "state"),
            last_text: nsstring_to_string(send(field, "stringValue")).unwrap_or_default(),
            counts: Vec::new(),
            deadline: Instant::now() + Duration::from_secs_f64(seconds),
            reported_baseline: false,
        });
    });

    send_timer(
        class("NSTimer"),
        "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:",
        0.05,
        application,
        sel("axonTick:"),
        null_mut(),
        true,
    );
    send(application, "run");
    Ok(())
}

/// Every event AppKit is about to dispatch, recorded and then passed on
/// untouched. Recording before `super` is what makes "arrived but was declined"
/// visible: an event this sees and no control reacts to did reach the
/// application.
extern "C" fn observe_event(this: Id, _command: Sel, event: Id) {
    if !event.is_null() {
        let kind = send_ret_u64(event, "type");
        CONTEXT.with(|context| {
            let mut borrowed = context.borrow_mut();
            let Some(context) = borrowed.as_mut() else {
                return;
            };
            bump(&mut context.counts, kind);
            if !interesting(kind) {
                return;
            }
            let record = J::obj(vec![
                ("kind", J::str("event")),
                ("role", J::str(context.role.clone())),
                ("nonce", J::str(context.nonce.clone())),
                ("eventType", J::Int(kind as i64)),
                ("eventName", J::str(name_of(kind))),
                ("windowNumber", J::Int(send_ret_i64(event, "windowNumber"))),
                ("timestamp", J::Num(send_ret_f64(event, "timestamp"))),
                (
                    "locationInWindow",
                    point_json(send_ret_point(event, "locationInWindow")),
                ),
            ]);
            if let Some(url) = &context.report {
                post(url, &record.render());
            }
        });
    }
    send_super_id(this, "NSApplication", "sendEvent:", event);
}

/// Polls the controls. A control's own state is the target-side mutation the
/// campaign records; the event stream above only says what arrived.
extern "C" fn tick(_this: Id, _command: Sel, _timer: Id) {
    let expired = CONTEXT.with(|context| {
        let mut borrowed = context.borrow_mut();
        let Some(context) = borrowed.as_mut() else {
            return false;
        };
        if context.checkbox.is_null() {
            return Instant::now() >= context.deadline;
        }
        let checkbox = send_ret_i64(context.checkbox, "state");
        let text = nsstring_to_string(send(context.field, "stringValue")).unwrap_or_default();
        let changed = checkbox != context.last_checkbox || text != context.last_text;
        if changed || !context.reported_baseline {
            context.reported_baseline = true;
            context.last_checkbox = checkbox;
            context.last_text = text.clone();
            let record = J::obj(vec![
                ("kind", J::str("state")),
                ("role", J::str(context.role.clone())),
                ("nonce", J::str(context.nonce.clone())),
                ("checkbox", J::Int(checkbox)),
                ("text", J::str(text)),
                ("eventCounts", counts_json(&context.counts)),
            ]);
            if let Some(url) = &context.report {
                post(url, &record.render());
            }
        }
        Instant::now() >= context.deadline
    });
    if expired {
        std::process::exit(0);
    }
}

/// Mouse-moved and cursor-update events arrive by the hundred and say nothing
/// about delivery; everything that could carry a click or a keystroke is kept.
fn interesting(kind: u64) -> bool {
    matches!(kind, 1 | 2 | 3 | 4 | 10 | 11 | 12 | 25 | 26 | 27)
}

fn name_of(kind: u64) -> String {
    match kind {
        1 => "leftMouseDown",
        2 => "leftMouseUp",
        3 => "rightMouseDown",
        4 => "rightMouseUp",
        10 => "keyDown",
        11 => "keyUp",
        12 => "flagsChanged",
        25 => "otherMouseDown",
        26 => "otherMouseUp",
        27 => "otherMouseDragged",
        _ => "other",
    }
    .to_string()
}

fn bump(counts: &mut Vec<(u64, i64)>, kind: u64) {
    for entry in counts.iter_mut() {
        if entry.0 == kind {
            entry.1 += 1;
            return;
        }
    }
    counts.push((kind, 1));
}

fn counts_json(counts: &[(u64, i64)]) -> J {
    J::Obj(
        counts
            .iter()
            .map(|(kind, total)| (name_of(*kind), J::Int(*total)))
            .collect(),
    )
}

/// AppKit measures from the bottom left of the primary screen and Core Graphics
/// from the top left. Every rectangle this fixture publishes is in Core
/// Graphics coordinates, because that is the space the campaign posts events
/// in and the space `CGWindowListCopyWindowInfo` reports bounds in.
fn screen_rect(window: Id, content: Id, control: Id) -> CGRect {
    let frame = if control == content {
        send_ret_rect(content, "bounds")
    } else {
        send_ret_rect(control, "frame")
    };
    let in_window = send_ret_rect_with_rect_view(content, "convertRect:toView:", frame, null_mut());
    let on_screen = send_ret_rect_with_rect(window, "convertRectToScreen:", in_window);
    let screens = send(class("NSScreen"), "screens");
    let primary = send_u64_arg(screens, "objectAtIndex:", 0);
    let primary_frame = send_ret_rect(primary, "frame");
    let flip = primary_frame.origin.y + primary_frame.size.height;
    CGRect {
        origin: CGPoint {
            x: on_screen.origin.x,
            y: flip - (on_screen.origin.y + on_screen.size.height),
        },
        size: on_screen.size,
    }
}

fn rect_json(rect: CGRect) -> J {
    J::obj(vec![
        ("x", J::Num(rect.origin.x)),
        ("y", J::Num(rect.origin.y)),
        ("width", J::Num(rect.size.width)),
        ("height", J::Num(rect.size.height)),
        (
            "center",
            J::obj(vec![
                ("x", J::Num(rect.origin.x + rect.size.width / 2.0)),
                ("y", J::Num(rect.origin.y + rect.size.height / 2.0)),
            ]),
        ),
    ])
}

fn point_json(point: CGPoint) -> J {
    J::obj(vec![("x", J::Num(point.x)), ("y", J::Num(point.y))])
}

/// One blocking POST per report. The fixture reports on change rather than on
/// exit, so a report that never arrives is a report about a fixture that was
/// killed, not a lost observation.
fn post(url: &str, body: &str) {
    let Some(rest) = url.strip_prefix("http://") else {
        return;
    };
    let (authority, path) = match rest.find('/') {
        Some(index) => (&rest[..index], &rest[index..]),
        None => (rest, "/"),
    };
    let Ok(mut stream) = TcpStream::connect(authority) else {
        return;
    };
    let request = format!(
        "POST {path} HTTP/1.1\r\nHost: {authority}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(request.as_bytes());
    let _ = stream.flush();
}
