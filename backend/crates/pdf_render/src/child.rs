//! The render child: the caller's own binary re-executed with
//! [`CHILD_ARGUMENT`]. It must be dispatched before any configuration,
//! telemetry, or database access, so the child never holds a credential.

use std::{
    ffi::{OsStr, OsString},
    fs::File,
    io::{BufWriter, Read as _},
    path::Path,
    process::ExitCode,
};

use crate::{RenderError, RenderLimits, render_pages, wire};

/// First argument that turns the caller's binary into a renderer.
pub const CHILD_ARGUMENT: &str = "__render-pdf-pages";

/// Exit status for a malformed command line.
const USAGE_EXIT_CODE: u8 = 2;
/// Address space the renderer may map. A page tree that asks for more ends in
/// an allocation abort instead of taking the host down.
#[cfg(target_os = "linux")]
const ADDRESS_SPACE_BYTES: u64 = 3 * 1024 * 1024 * 1024;
/// CPU seconds before the kernel terminates a runaway renderer.
#[cfg(target_os = "linux")]
const CPU_SECONDS: u64 = 180;

/// Runs the render child when `arguments` (a full `argv`) ask for it, and
/// returns its exit status. Returns `None` for every other invocation.
#[must_use]
pub fn run_child_if_requested(arguments: impl IntoIterator<Item = OsString>) -> Option<ExitCode> {
    let mut arguments = arguments.into_iter();
    let _binary = arguments.next();
    if arguments.next().as_deref() != Some(OsStr::new(CHILD_ARGUMENT)) {
        return None;
    }
    Some(run(&arguments.collect::<Vec<_>>()))
}

fn run(arguments: &[OsString]) -> ExitCode {
    let Some((path, limits)) = wire::parse_child_arguments(arguments) else {
        return ExitCode::from(USAGE_EXIT_CODE);
    };
    restrict_process();
    let pages = match read_pdf(&path, &limits).and_then(|pdf| render_pages(pdf, &limits)) {
        Ok(pages) => pages,
        Err(error) => return ExitCode::from(error.exit_code()),
    };
    let mut output = BufWriter::new(std::io::stdout().lock());
    match wire::write_pages(&mut output, &pages) {
        Ok(()) => ExitCode::SUCCESS,
        Err(_) => ExitCode::from(RenderError::Internal.exit_code()),
    }
}

/// Reads at most one byte more than the limit, so an oversized file is
/// detected without buffering all of it.
fn read_pdf(path: &Path, limits: &RenderLimits) -> Result<Vec<u8>, RenderError> {
    let file = File::open(path).map_err(|_| RenderError::Internal)?;
    let mut bytes = Vec::new();
    file.take(limits.max_pdf_bytes.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|_| RenderError::Internal)?;
    Ok(bytes)
}

/// Lowers what a compromised or runaway renderer can consume. Best effort: a
/// failure to lower a limit must not mask the render result.
#[cfg(target_os = "linux")]
fn restrict_process() {
    use rustix::process::{Resource, Rlimit, setrlimit};

    for (resource, limit) in [
        (Resource::Core, 0),
        (Resource::As, ADDRESS_SPACE_BYTES),
        (Resource::Cpu, CPU_SECONDS),
    ] {
        let _ = setrlimit(
            resource,
            Rlimit {
                current: Some(limit),
                maximum: Some(limit),
            },
        );
    }
}

#[cfg(not(target_os = "linux"))]
fn restrict_process() {}

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(arguments: &[&str]) -> Vec<OsString> {
        arguments.iter().map(OsString::from).collect()
    }

    #[test]
    fn ordinary_invocations_are_not_hijacked() {
        assert!(run_child_if_requested(argv(&["pakperk-worker", "run"])).is_none());
        assert!(run_child_if_requested(argv(&["pakperk-worker"])).is_none());
        assert!(run_child_if_requested(Vec::new()).is_none());
    }

    #[test]
    fn malformed_child_arguments_exit_with_the_usage_status() {
        let status = run_child_if_requested(argv(&["pakperk-worker", CHILD_ARGUMENT, "only-one"]));
        assert_eq!(status, Some(ExitCode::from(USAGE_EXIT_CODE)));
    }

    #[test]
    fn a_missing_pdf_is_an_internal_failure() {
        let limits = RenderLimits::default();
        assert!(matches!(
            read_pdf(Path::new("/definitely/not/here.pdf"), &limits),
            Err(RenderError::Internal)
        ));
    }
}
