//! The daemon outlives its clients.
//!
//! A client is not a trusted participant. It may vanish before it asks anything, halfway through
//! asking, or between asking and hearing the answer, and none of those may end the daemon: it
//! serves a whole desktop session, and one abandoned connection taking it down is an availability
//! outage for everything else. This drives `serve_connections` through each of those endings and
//! then requires it to answer normally, which is the only proof that it survived them.

#![cfg(unix)]

use axon_linux::socket::serve_connections;
use serde_json::{Value, json};
use std::{
    io::{BufRead, BufReader, Write},
    os::unix::net::{UnixListener, UnixStream},
    path::{Path, PathBuf},
    sync::mpsc,
    thread,
    time::Duration,
};

/// Long enough that a loaded machine does not fail the test, short enough to notice a hang.
const PATIENCE: Duration = Duration::from_secs(10);

fn endpoint(name: &str) -> PathBuf {
    let mut path = std::env::temp_dir();
    path.push(format!("axon-{name}-{}.sock", std::process::id()));
    let _ = std::fs::remove_file(&path);
    path
}

/// Sends one line and reads the answer, the way every Axon client speaks to the daemon.
fn ask(path: &Path, line: &str) -> String {
    let mut stream = UnixStream::connect(path).expect("the daemon is still accepting connections");
    stream.set_read_timeout(Some(PATIENCE)).unwrap();
    stream.write_all(format!("{line}\n").as_bytes()).unwrap();
    let mut answer = String::new();
    BufReader::new(stream)
        .read_line(&mut answer)
        .expect("the daemon answers");
    answer
}

#[test]
fn a_client_that_hangs_up_never_takes_the_daemon_with_it() {
    let path = endpoint("hangup");
    let listener = UnixListener::bind(&path).expect("bind the endpoint");

    // Lets the test hold the daemon inside the handler for one request, so that the client can be
    // gone for certain before the answer is written. Without this the disconnect would race the
    // write and the mid-response case would only sometimes be exercised.
    let (release, held) = mpsc::channel::<()>();
    let (entered, waiting) = mpsc::channel::<()>();
    let (saw, requests) = mpsc::channel::<String>();

    let server = thread::spawn(move || {
        serve_connections(&listener, PATIENCE, move || {
          let release = release.clone();
          let entered = entered.clone();
          let saw = saw.clone();
          Box::new(move |line| {
            saw.send(line.to_owned()).unwrap();
            if line == "wait" {
                entered.send(()).unwrap();
                held.recv().unwrap();
            }
            (json!({ "echo": line }), line == "shutdown")
          })
        }))
    });

    // A liveness probe: connect, ask nothing, hang up.
    drop(UnixStream::connect(&path).expect("the probe connects"));

    // A client that dies partway through its request, leaving no newline behind.
    let mut truncated = UnixStream::connect(&path).unwrap();
    truncated.write_all(b"{\"jsonrpc\"").unwrap();
    drop(truncated);

    // A client that asks, then walks away before the answer is written.
    let mut abandoning = UnixStream::connect(&path).unwrap();
    abandoning.write_all(b"wait\n").unwrap();
    waiting
        .recv_timeout(PATIENCE)
        .expect("the daemon reached the handler");
    drop(abandoning);
    release.send(()).unwrap();

    let answer: Value = serde_json::from_str(&ask(&path, "ping")).unwrap();
    assert_eq!(
        answer,
        json!({"echo": "ping"}),
        "the daemon still answers after three clients hung up on it"
    );

    let farewell: Value = serde_json::from_str(&ask(&path, "shutdown")).unwrap();
    assert_eq!(farewell, json!({"echo": "shutdown"}));
    server
        .join()
        .unwrap()
        .expect("the loop ends because a request asked it to, not because a client left");

    // The connection that sent nothing is absent on purpose: there was no request to answer, so
    // the daemon has nothing to say and nothing to log.
    let seen = requests.iter().collect::<Vec<_>>();
    assert_eq!(seen, vec!["{\"jsonrpc\"", "wait", "ping", "shutdown"]);

    let _ = std::fs::remove_file(&path);
}

#[test]
fn a_shutdown_whose_caller_walked_away_still_stops_the_daemon() {
    let path = endpoint("shutdown");
    let listener = UnixListener::bind(&path).expect("bind the endpoint");
    let (release, held) = mpsc::channel::<()>();
    let (entered, waiting) = mpsc::channel::<()>();

    let server = thread::spawn(move || {
        let held = std::sync::Arc::new(std::sync::Mutex::new(held));
        serve_connections(&listener, PATIENCE, move || {
          let entered = entered.clone();
          let held = held.clone();
          Box::new(move |line| {
            entered.send(()).unwrap();
            held.lock().unwrap().recv().unwrap();
            (json!({ "echo": line }), line == "shutdown")
          })
        })
    });

    let mut caller = UnixStream::connect(&path).unwrap();
    caller.write_all(b"shutdown\n").unwrap();
    waiting
        .recv_timeout(PATIENCE)
        .expect("the daemon reached the handler");
    drop(caller);
    release.send(()).unwrap();

    // The request was received and carried out; that the caller is no longer there to hear the
    // answer does not un-ask it. Observing silence rather than joining first means a daemon that
    // wrongly kept running fails this test instead of hanging the suite.
    assert!(
        wait_until_silent(&path),
        "a shutdown request stops the daemon even when writing the answer fails"
    );
    server.join().unwrap().expect("the loop ends cleanly");
    let _ = std::fs::remove_file(&path);
}

/// Whether the endpoint stops accepting within [`PATIENCE`], which is what a stopped daemon that
/// has dropped its listener looks like from outside.
fn wait_until_silent(path: &Path) -> bool {
    let deadline = std::time::Instant::now() + PATIENCE;
    while std::time::Instant::now() < deadline {
        if UnixStream::connect(path).is_err() {
            return true;
        }
        thread::sleep(Duration::from_millis(10));
    }
    false
}

#[test]
fn a_client_that_stops_reading_its_answer_does_not_park_the_daemon() {
    let path = endpoint("stalled");
    let listener = UnixListener::bind(&path).expect("bind the endpoint");
    let patience = Duration::from_millis(300);

    let server = thread::spawn(move || {
        serve_connections(&listener, patience, || Box::new(|line| {
            // Comfortably past what a socket buffer holds, which is what makes the answer block
            // in the daemon rather than disappear into the kernel and return. A `look` at a real
            // application is large enough to reach the same state.
            let answer = if line == "big" {
                "x".repeat(8 * 1024 * 1024)
            } else {
                line.to_owned()
            };
            (json!({ "echo": answer }), line == "shutdown")
        })
    });

    // Asks for a large answer, then never reads a byte of it while staying connected. Hanging up
    // would hand the daemon an immediate broken pipe; this client extends no such courtesy, and
    // an unbounded write would wait on it for as long as it cared to hold on.
    let mut stalled = UnixStream::connect(&path).unwrap();
    stalled.write_all(b"big\n").unwrap();

    let answer: Value = serde_json::from_str(&ask(&path, "ping")).unwrap();
    assert_eq!(
        answer,
        json!({"echo": "ping"}),
        "the daemon answers other clients while one refuses to read"
    );

    drop(stalled);
    let _ = ask(&path, "shutdown");
    server.join().unwrap().expect("the loop ends cleanly");
    let _ = std::fs::remove_file(&path);
}

#[test]
fn a_client_that_connects_and_says_nothing_is_dropped_rather_than_served_forever() {
    let path = endpoint("silent");
    let listener = UnixListener::bind(&path).expect("bind the endpoint");
    let patience = Duration::from_millis(200);

    let server = thread::spawn(move || {
        serve_connections(&listener, patience, || Box::new(|line| {
            (json!({ "echo": line }), line == "shutdown")
        }))
    });

    // Held open and silent. The daemon serves one connection at a time, so if this one were
    // waited on forever the request below would never be accepted.
    let mute = UnixStream::connect(&path).expect("the silent client connects");

    let answer: Value = serde_json::from_str(&ask(&path, "ping")).unwrap();
    assert_eq!(answer, json!({"echo": "ping"}));

    drop(mute);
    let _ = ask(&path, "shutdown");
    server.join().unwrap().expect("the loop ends cleanly");
    let _ = std::fs::remove_file(&path);
}
