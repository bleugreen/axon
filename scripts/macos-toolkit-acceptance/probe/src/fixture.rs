//! The two AppKit windows the campaign owns: the decoy that holds the
//! foreground, and the native target whose controls a delivered click would
//! have to move.
//!
//! Both are the same program in different roles, because they need the same
//! thing — a window that reports every event it dequeues and every change to
//! its own controls. That double reporting is what separates the three
//! outcomes a sending side cannot tell apart: an event that never arrived, one
//! that arrived and was declined, and one that was acted on.
//!
//! There is no Objective-C subclass here and no target/action wiring. The main
//! loop is written out by hand — `nextEventMatchingMask:` then `sendEvent:` —
//! so the arrival of an event is observable before AppKit decides what to do
//! with it, and so the controls can be polled without a delegate.

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

pub fn run(args: &Args) -> Result<(), String> {
    let role = args.optional_string("role").unwrap_or_else(|| "target".into());
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

    let application = send(class("NSApplication"), "sharedApplication");
    send_i64_arg(
        application,
        "setActivationPolicy:",
        NS_APPLICATION_ACTIVATION_POLICY_REGULAR,
    );

    let content = CGRect {
        origin,
        size,
    };
    let window = send_rect_mask_backing_defer(
        send(class("NSWindow"), "alloc"),
        "initWithContentRect:styleMask:backing:defer:",
        content,
        NS_WINDOW_STYLE_TITLED | NS_WINDOW_STYLE_CLOSABLE | NS_WINDOW_STYLE_RESIZABLE,
        NS_BACKING_STORE_BUFFERED,
        false,
    );
    if window.is_null() {
        return Err("NSWindow could not be created".into());
    }
    send_id(window, "setTitle:", nsstring(&title));
    let view = send(window, "contentView");

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

    // One pass of the loop before geometry is read, so AppKit has laid the
    // window out where the window server actually put it.
    pump(application, 0.25);

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

    let mut last_checkbox = send_ret_i64(checkbox, "state");
    let mut last_text = nsstring_to_string(send(field, "stringValue")).unwrap_or_default();
    let mut counts: Vec<(u64, i64)> = Vec::new();
    let deadline = Instant::now() + Duration::from_secs_f64(seconds);

    while Instant::now() < deadline {
        let event = next_event(application, 0.03);
        if !event.is_null() {
            let kind = send_ret_u64(event, "type");
            bump(&mut counts, kind);
            if let Some(url) = &report {
                if interesting(kind) {
                    post(
                        url,
                        &J::obj(vec![
                            ("kind", J::str("event")),
                            ("role", J::str(role.clone())),
                            ("nonce", J::str(nonce.clone())),
                            ("eventType", J::Int(kind as i64)),
                            ("eventName", J::str(name_of(kind))),
                            (
                                "windowNumber",
                                J::Int(send_ret_i64(event, "windowNumber")),
                            ),
                            ("timestamp", J::Num(send_ret_f64(event, "timestamp"))),
                            (
                                "locationInWindow",
                                point_json(send_ret_point(event, "locationInWindow")),
                            ),
                        ])
                        .render(),
                    );
                }
            }
            send_id(application, "sendEvent:", event);
        }

        let checkbox_state = send_ret_i64(checkbox, "state");
        let text = nsstring_to_string(send(field, "stringValue")).unwrap_or_default();
        if checkbox_state != last_checkbox || text != last_text {
            last_checkbox = checkbox_state;
            last_text = text.clone();
            if let Some(url) = &report {
                post(
                    url,
                    &J::obj(vec![
                        ("kind", J::str("state")),
                        ("role", J::str(role.clone())),
                        ("nonce", J::str(nonce.clone())),
                        ("checkbox", J::Int(checkbox_state)),
                        ("text", J::str(text)),
                        ("eventCounts", counts_json(&counts)),
                    ])
                    .render(),
                );
            }
        }
    }
    Ok(())
}

fn pump(application: Id, seconds: f64) {
    let until = Instant::now() + Duration::from_secs_f64(seconds);
    while Instant::now() < until {
        let event = next_event(application, 0.01);
        if !event.is_null() {
            send_id(application, "sendEvent:", event);
        }
    }
}

fn next_event(application: Id, timeout: f64) -> Id {
    let until = send_f64_arg(
        class("NSDate"),
        "dateWithTimeIntervalSinceNow:",
        timeout,
    );
    send_next_event(
        application,
        "nextEventMatchingMask:untilDate:inMode:dequeue:",
        u64::MAX,
        until,
        nsstring("kCFRunLoopDefaultMode"),
        true,
    )
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
