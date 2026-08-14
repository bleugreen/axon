use axon_core::{BackendError, RecognizedText, Rect};
use std::{
    collections::BTreeMap,
    io::{Read, Write},
    path::Path,
    process::{Command, ExitStatus, Stdio},
    thread,
    time::{Duration, Instant},
};

const OCR_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Debug, PartialEq, Eq)]
enum OcrFailure {
    EngineMissing,
    LanguageDataMissing(String),
    Timeout,
    MalformedOutput(String),
    Execution(String),
}

impl std::fmt::Display for OcrFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::EngineMissing => write!(
                f,
                "tesseract was not found on PATH; install Tesseract OCR and an English language pack"
            ),
            Self::LanguageDataMissing(message) => {
                write!(f, "Tesseract language data is unavailable: {message}")
            }
            Self::Timeout => write!(
                f,
                "Tesseract did not finish within {} seconds",
                OCR_TIMEOUT.as_secs()
            ),
            Self::MalformedOutput(message) => {
                write!(f, "Tesseract returned malformed TSV: {message}")
            }
            Self::Execution(message) => write!(f, "Tesseract execution failed: {message}"),
        }
    }
}

pub fn recognize_png(
    png: &[u8],
    image_size: (u32, u32),
    screen: Rect,
) -> Result<Vec<RecognizedText>, BackendError> {
    recognize_png_with("tesseract", png, image_size, screen, OCR_TIMEOUT)
        .map_err(|error| BackendError::Operation {
            operation: "recognize X11 window text".into(),
            message: error.to_string(),
            diagnostic: Some("Linux screenshot OCR requires the `tesseract` executable and at least one installed language pack (for example `tesseract-ocr-eng`).".into()),
        })
}

fn recognize_png_with(
    executable: impl AsRef<Path>,
    png: &[u8],
    image_size: (u32, u32),
    screen: Rect,
    timeout: Duration,
) -> Result<Vec<RecognizedText>, OcrFailure> {
    run_tesseract_with(executable, png, timeout)
        .and_then(|tsv| parse_tsv(&tsv, image_size, screen))
}

fn run_tesseract_with(
    executable: impl AsRef<Path>,
    png: &[u8],
    timeout: Duration,
) -> Result<String, OcrFailure> {
    let mut child = Command::new(executable.as_ref())
        .args(["stdin", "stdout", "-l", "eng", "tsv"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                OcrFailure::EngineMissing
            } else {
                OcrFailure::Execution(error.to_string())
            }
        })?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| OcrFailure::Execution("stdin was not available".into()))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| OcrFailure::Execution("stdout was not available".into()))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| OcrFailure::Execution("stderr was not available".into()))?;

    // All three pipes must make progress independently. In particular, waiting for the process
    // before reading output deadlocks as soon as either kernel pipe buffer fills.
    let input = png.to_vec();
    let writer = thread::spawn(move || stdin.write_all(&input));
    let stdout_reader = thread::spawn(move || read_all(stdout));
    let stderr_reader = thread::spawn(move || read_all(stderr));
    let started = Instant::now();
    let status: ExitStatus = loop {
        match child
            .try_wait()
            .map_err(|error| OcrFailure::Execution(error.to_string()))?
        {
            Some(status) => break status,
            None if started.elapsed() >= timeout => {
                let _ = child.kill();
                let _ = child.wait();
                let _ = writer.join();
                let _ = stdout_reader.join();
                let _ = stderr_reader.join();
                return Err(OcrFailure::Timeout);
            }
            None => thread::sleep(Duration::from_millis(10)),
        }
    };
    let write_result = writer
        .join()
        .map_err(|_| OcrFailure::Execution("stdin writer panicked".into()))?;
    let stdout = stdout_reader
        .join()
        .map_err(|_| OcrFailure::Execution("stdout reader panicked".into()))?
        .map_err(|error| OcrFailure::Execution(error.to_string()))?;
    let stderr = stderr_reader
        .join()
        .map_err(|_| OcrFailure::Execution("stderr reader panicked".into()))?
        .map_err(|error| OcrFailure::Execution(error.to_string()))?;
    let stderr = String::from_utf8_lossy(&stderr).trim().to_string();
    if !status.success() {
        let lowered = stderr.to_ascii_lowercase();
        return Err(
            if lowered.contains("traineddata")
                || lowered.contains("tessdata")
                || lowered.contains("failed loading language")
            {
                OcrFailure::LanguageDataMissing(stderr)
            } else {
                OcrFailure::Execution(stderr)
            },
        );
    }
    write_result.map_err(|error| OcrFailure::Execution(error.to_string()))?;
    String::from_utf8(stdout).map_err(|error| OcrFailure::MalformedOutput(error.to_string()))
}

fn read_all(mut stream: impl Read) -> std::io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    stream.read_to_end(&mut bytes)?;
    Ok(bytes)
}

#[derive(Default)]
struct Line {
    words: Vec<String>,
    left: i64,
    top: i64,
    right: i64,
    bottom: i64,
    confidence_sum: f64,
    confidence_count: usize,
}

fn parse_tsv(
    tsv: &str,
    image_size: (u32, u32),
    screen: Rect,
) -> Result<Vec<RecognizedText>, OcrFailure> {
    if image_size.0 == 0 || image_size.1 == 0 {
        return Err(OcrFailure::MalformedOutput(
            "image dimensions are zero".into(),
        ));
    }
    let mut rows = tsv.lines();
    let header = rows
        .next()
        .ok_or_else(|| OcrFailure::MalformedOutput("output is empty".into()))?;
    if header.split('\t').collect::<Vec<_>>()
        != [
            "level",
            "page_num",
            "block_num",
            "par_num",
            "line_num",
            "word_num",
            "left",
            "top",
            "width",
            "height",
            "conf",
            "text",
        ]
    {
        return Err(OcrFailure::MalformedOutput("unexpected columns".into()));
    }
    let mut lines: BTreeMap<(i64, i64, i64, i64), Line> = BTreeMap::new();
    for (index, row) in rows.enumerate() {
        let columns = row.split('\t').collect::<Vec<_>>();
        if columns.len() != 12 {
            return Err(OcrFailure::MalformedOutput(format!(
                "row {} has {} columns",
                index + 2,
                columns.len()
            )));
        }
        let number = |column: usize| {
            columns[column].parse::<i64>().map_err(|_| {
                OcrFailure::MalformedOutput(format!(
                    "row {} column {} is not an integer",
                    index + 2,
                    column + 1
                ))
            })
        };
        if number(0)? != 5 {
            continue;
        }
        let text = columns[11].trim();
        let (left, top, width, height) = (number(6)?, number(7)?, number(8)?, number(9)?);
        if text.is_empty() || width <= 0 || height <= 0 {
            continue;
        }
        let key = (number(1)?, number(2)?, number(3)?, number(4)?);
        let line = lines.entry(key).or_insert_with(|| Line {
            left,
            top,
            right: left + width,
            bottom: top + height,
            ..Line::default()
        });
        line.words.push(text.into());
        line.left = line.left.min(left);
        line.top = line.top.min(top);
        line.right = line.right.max(left + width);
        line.bottom = line.bottom.max(top + height);
        if let Ok(confidence) = columns[10].parse::<f64>() {
            if confidence >= 0.0 {
                line.confidence_sum += confidence / 100.0;
                line.confidence_count += 1;
            }
        }
    }
    let sx = screen.width / f64::from(image_size.0);
    let sy = screen.height / f64::from(image_size.1);
    let mut recognized = lines
        .into_values()
        .map(|line| RecognizedText {
            text: line.words.join(" "),
            frame: Rect {
                x: screen.x + line.left as f64 * sx,
                y: screen.y + line.top as f64 * sy,
                width: (line.right - line.left) as f64 * sx,
                height: (line.bottom - line.top) as f64 * sy,
            },
            confidence: (line.confidence_count > 0)
                .then(|| line.confidence_sum / line.confidence_count as f64),
        })
        .collect::<Vec<_>>();
    recognized.sort_by(|a, b| {
        a.frame
            .y
            .total_cmp(&b.frame.y)
            .then_with(|| a.frame.x.total_cmp(&b.frame.x))
    });
    Ok(recognized)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, os::unix::fs::PermissionsExt, path::PathBuf, sync::atomic::{AtomicUsize, Ordering}};
    const HEADER: &str = "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n";
    #[test]
    fn groups_words_and_scales_non_uniformly_from_negative_origin() {
        let tsv = format!(
            "{HEADER}5\t1\t1\t1\t1\t1\t10\t20\t30\t10\t80\tHello\n5\t1\t1\t1\t1\t2\t45\t18\t40\t14\t100\tworld\n5\t1\t1\t1\t2\t1\t5\t60\t0\t10\t90\tignored\n"
        );
        let items = parse_tsv(
            &tsv,
            (100, 100),
            Rect {
                x: -200.0,
                y: 40.0,
                width: 200.0,
                height: 50.0,
            },
        )
        .unwrap();
        assert_eq!(
            items,
            vec![RecognizedText {
                text: "Hello world".into(),
                frame: Rect {
                    x: -180.0,
                    y: 49.0,
                    width: 150.0,
                    height: 7.0
                },
                confidence: Some(0.9)
            }]
        );
    }
    #[test]
    fn malformed_rows_are_not_silently_empty() {
        assert!(matches!(
            parse_tsv(
                &format!("{HEADER}5\t1"),
                (1, 1),
                Rect {
                    x: 0.0,
                    y: 0.0,
                    width: 1.0,
                    height: 1.0
                }
            ),
            Err(OcrFailure::MalformedOutput(_))
        ));
    }
    fn fake_executable(body: &str) -> PathBuf {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "axon-tesseract-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        path
    }
    #[test]
    fn reports_missing_executable() {
        assert_eq!(run_tesseract_with("/axon/missing/tesseract", b"", Duration::from_secs(1)), Err(OcrFailure::EngineMissing));
    }
    #[test]
    fn classifies_missing_language_data() {
        let executable = fake_executable("cat >/dev/null; echo 'Error opening eng.traineddata' >&2; exit 1");
        let result = run_tesseract_with(executable, b"png", Duration::from_secs(1));
        assert!(matches!(result, Err(OcrFailure::LanguageDataMissing(_))), "{result:?}");
    }
    #[test]
    fn preserves_nonzero_exit_as_execution_failure() {
        let executable = fake_executable("cat >/dev/null; echo exploded >&2; exit 7");
        assert_eq!(run_tesseract_with(executable, b"png", Duration::from_secs(1)), Err(OcrFailure::Execution("exploded".into())));
    }
    #[test]
    fn kills_an_executable_that_times_out() {
        let executable = fake_executable("exec sleep 5");
        assert_eq!(run_tesseract_with(executable, b"png", Duration::from_millis(30)), Err(OcrFailure::Timeout));
    }
    #[test]
    fn executable_malformed_output_is_typed() {
        let executable = fake_executable("cat >/dev/null; echo not-tsv");
        let result = recognize_png_with(
            executable,
            b"png",
            (1, 1),
            Rect { x: 0.0, y: 0.0, width: 1.0, height: 1.0 },
            Duration::from_secs(1),
        );
        assert!(matches!(result, Err(OcrFailure::MalformedOutput(_))));
    }
    #[test]
    fn drains_output_larger_than_pipe_backpressure_capacity() {
        let executable = fake_executable("cat >/dev/null; head -c 200000 /dev/zero | tr '\\000' x");
        let output = run_tesseract_with(executable, b"png", Duration::from_secs(2)).unwrap();
        assert_eq!(output.len(), 200_000);
    }
}
