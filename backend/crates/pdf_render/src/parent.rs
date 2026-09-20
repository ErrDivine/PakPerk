//! The parent side: starts the render child, bounds what it may output and how
//! long it may run, and decodes the result.

use std::{path::Path, process::Stdio, time::Duration};

use tokio::{io::AsyncReadExt as _, process::Command, time::timeout};

use crate::{CHILD_ARGUMENT, PageImage, RenderError, RenderLimits, wire};

/// Renders the PDF at `pdf` by re-executing `executable` as a render child.
///
/// The child gets an empty environment, no stdin, and no stderr, and is killed
/// if it outlives `deadline`, writes more than the limits allow, or the caller
/// drops this future.
pub async fn render_pdf_pages(
    executable: &Path,
    pdf: &Path,
    limits: &RenderLimits,
    deadline: Duration,
) -> Result<Vec<PageImage>, RenderError> {
    if !limits.is_valid() {
        return Err(RenderError::Internal);
    }
    let mut command = Command::new(executable);
    command
        .arg(CHILD_ARGUMENT)
        .args(wire::child_arguments(pdf, limits));
    run_child(command, limits, deadline).await
}

async fn run_child(
    mut command: Command,
    limits: &RenderLimits,
    deadline: Duration,
) -> Result<Vec<PageImage>, RenderError> {
    command
        .env_clear()
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let mut child = command.spawn().map_err(RenderError::Spawn)?;
    let mut stdout = child.stdout.take().ok_or(RenderError::ChildFailed)?;
    let capacity = wire::maximum_stream_bytes(limits);

    let finished = timeout(deadline, async {
        let mut bytes = Vec::new();
        (&mut stdout)
            .take(capacity.saturating_add(1))
            .read_to_end(&mut bytes)
            .await
            .map_err(|_| RenderError::ChildFailed)?;
        if u64::try_from(bytes.len()).map_or(true, |length| length > capacity) {
            return Err(RenderError::OutputTooLarge);
        }
        let status = child.wait().await.map_err(|_| RenderError::ChildFailed)?;
        Ok((status, bytes))
    })
    .await;
    let (status, bytes) = match finished {
        Ok(Ok(done)) => done,
        Ok(Err(error)) => {
            stop(&mut child).await;
            return Err(error);
        }
        Err(_elapsed) => {
            stop(&mut child).await;
            return Err(RenderError::Deadline);
        }
    };

    if status.success() {
        return wire::read_pages(&bytes, limits).ok_or(RenderError::ChildFailed);
    }
    // A signal (a crash, an out-of-memory kill, the CPU limit) has no exit code.
    Err(status
        .code()
        .and_then(RenderError::from_exit_code)
        .unwrap_or(RenderError::ChildFailed))
}

async fn stop(child: &mut tokio::process::Child) {
    // The child may already have exited; there is nothing left to do then.
    let _ = child.kill().await;
}

#[cfg(all(test, unix))]
mod tests {
    use std::time::Instant;

    use super::*;

    fn shell(script: &str) -> Command {
        let mut command = Command::new("/bin/sh");
        command.arg("-c").arg(script);
        command
    }

    fn limits() -> RenderLimits {
        RenderLimits {
            max_page_bytes: 1_000,
            max_total_bytes: 2_000,
            ..RenderLimits::default()
        }
    }

    const SECOND: Duration = Duration::from_secs(1);

    #[tokio::test]
    async fn a_hung_child_is_killed_at_the_deadline() {
        let started = Instant::now();
        let error = run_child(
            shell("exec /bin/sleep 30"),
            &limits(),
            Duration::from_millis(300),
        )
        .await
        .unwrap_err();
        assert!(matches!(error, RenderError::Deadline), "{error:?}");
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[tokio::test]
    async fn child_detected_failures_keep_their_meaning() {
        for (script, expected) in [
            ("exit 10", "render_invalid_pdf"),
            ("exit 14", "render_too_many_pages"),
            ("exit 15", "render_unsafe_page_size"),
            ("exit 2", "render_child_failed"),
            ("exit 101", "render_child_failed"),
            ("kill -9 $$", "render_child_failed"),
        ] {
            let error = run_child(shell(script), &limits(), 10 * SECOND)
                .await
                .unwrap_err();
            assert_eq!(error.kind(), expected, "{script}");
        }
    }

    #[tokio::test]
    async fn output_beyond_the_limits_stops_the_child() {
        let started = Instant::now();
        let error = run_child(
            shell("exec /usr/bin/yes"),
            &limits(),
            Duration::from_secs(20),
        )
        .await
        .unwrap_err();
        assert!(matches!(error, RenderError::OutputTooLarge), "{error:?}");
        assert!(started.elapsed() < Duration::from_secs(10));
    }

    #[tokio::test]
    async fn garbage_and_empty_output_from_a_successful_exit_are_rejected() {
        for script in ["printf garbage", "exit 0"] {
            let error = run_child(shell(script), &limits(), 10 * SECOND)
                .await
                .unwrap_err();
            assert!(matches!(error, RenderError::ChildFailed), "{script}");
        }
    }

    #[tokio::test]
    async fn a_valid_frame_stream_is_decoded() {
        let pages = vec![PageImage {
            number: 1,
            width: 1_400,
            height: 1_812,
            png: {
                let mut png = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
                png.extend([1, 2, 3, 4]);
                png
            },
        }];
        let directory = std::env::temp_dir().join(format!("pdf-render-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("frames.bin");
        let mut bytes = Vec::new();
        wire::write_pages(&mut bytes, &pages).unwrap();
        std::fs::write(&path, bytes).unwrap();

        let mut command = Command::new("/bin/cat");
        command.arg(&path);
        let decoded = run_child(command, &limits(), 10 * SECOND).await.unwrap();
        std::fs::remove_dir_all(&directory).unwrap();
        assert_eq!(decoded, pages);
    }

    #[tokio::test]
    async fn a_missing_executable_is_a_spawn_error() {
        let error = run_child(Command::new("/definitely/not/a/binary"), &limits(), SECOND)
            .await
            .unwrap_err();
        assert!(matches!(error, RenderError::Spawn(_)), "{error:?}");
    }
}
