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
        serve_connections(&listener, PATIENCE, move |line| {
            saw.send(line.to_owned()).unwrap();
            if line == "wait" {
                entered.send(()).unwrap();
                held.recv().unwrap();
            }
            (json!({ "echo": line }), line == "shutdown")
        })
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
fn a_client_that_connects_and_says_nothing_is_dropped_rather_than_served_forever() {
    let path = endpoint("silent");
    let listener = UnixListener::bind(&path).expect("bind the endpoint");
    let patience = Duration::from_millis(200);

    let server = thread::spawn(move || {
        serve_connections(&listener, patience, |line| {
            (json!({ "echo": line }), line == "shutdown")
        })
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
