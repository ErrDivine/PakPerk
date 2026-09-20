use std::{ffi::OsString, path::PathBuf};

use anyhow::{Context as _, Result, bail};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cli {
    pub command: Command,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Command {
    Run,
    SyncMetadata {
        manifest: PathBuf,
    },
    PrepareDemo {
        manifest: PathBuf,
        wait: bool,
        timeout_seconds: u64,
    },
    VerifyDemo {
        manifest: PathBuf,
        expected_connections: PathBuf,
        content_evaluation: PathBuf,
        output: PathBuf,
    },
    ValidateDemoContent {
        manifest: PathBuf,
        expected_connections: PathBuf,
        content_evaluation: PathBuf,
        output: PathBuf,
    },
    /// Runs page-image recovery on one local PDF without a database, GROBID, or
    /// arXiv, and prints what would be stored.
    RecoverPdf {
        pdf: PathBuf,
        markdown: Option<PathBuf>,
    },
}

impl Cli {
    pub fn parse(arguments: impl IntoIterator<Item = OsString>) -> Result<Self> {
        let mut arguments = arguments.into_iter();
        let _binary = arguments.next();
        let command = arguments.next().map_or_else(
            || "run".to_owned(),
            |argument| argument.to_string_lossy().into_owned(),
        );
        let rest = arguments.collect::<Vec<_>>();
        let command = match command.as_str() {
            "run" => {
                ensure_empty(&rest)?;
                Command::Run
            }
            "sync-metadata" => {
                let options = Options::parse(rest)?;
                Command::SyncMetadata {
                    manifest: options.required_path("--manifest")?,
                }
            }
            "prepare-demo" => {
                let options = Options::parse(rest)?;
                Command::PrepareDemo {
                    manifest: options.required_path("--manifest")?,
                    wait: options.flag("--wait"),
                    timeout_seconds: options
                        .optional("--timeout-seconds")
                        .map(str::parse)
                        .transpose()
                        .context("--timeout-seconds must be an integer")?
                        .unwrap_or(1_800),
                }
            }
            "verify-demo" => {
                let options = Options::parse(rest)?;
                Command::VerifyDemo {
                    manifest: options.required_path("--manifest")?,
                    expected_connections: options.required_path("--expected-connections")?,
                    content_evaluation: options.required_path("--content-evaluation")?,
                    output: options.required_path("--output")?,
                }
            }
            "validate-demo-content" => {
                let options = Options::parse(rest)?;
                Command::ValidateDemoContent {
                    manifest: options.required_path("--manifest")?,
                    expected_connections: options.required_path("--expected-connections")?,
                    content_evaluation: options.required_path("--content-evaluation")?,
                    output: options.required_path("--output")?,
                }
            }
            "recover-pdf" => {
                let options = Options::parse(rest)?;
                Command::RecoverPdf {
                    pdf: options.required_path("--pdf")?,
                    markdown: options.optional("--markdown").map(PathBuf::from),
                }
            }
            other => bail!(
                "unknown command `{other}`; expected run, sync-metadata, prepare-demo, verify-demo, \
                 validate-demo-content, or recover-pdf"
            ),
        };
        Ok(Self { command })
    }
}

#[derive(Debug)]
struct Options {
    values: std::collections::HashMap<String, String>,
    flags: std::collections::HashSet<String>,
}

impl Options {
    fn parse(arguments: Vec<OsString>) -> Result<Self> {
        let mut values = std::collections::HashMap::new();
        let mut flags = std::collections::HashSet::new();
        let mut arguments = arguments.into_iter().peekable();
        while let Some(option) = arguments.next() {
            let option = option.to_string_lossy().into_owned();
            if !option.starts_with("--") {
                bail!("unexpected positional argument `{option}`");
            }
            if option == "--wait" {
                flags.insert(option);
                continue;
            }
            let value = arguments
                .next()
                .with_context(|| format!("{option} requires a value"))?
                .to_string_lossy()
                .into_owned();
            if value.starts_with("--") {
                bail!("{option} requires a value");
            }
            if values.insert(option.clone(), value).is_some() {
                bail!("{option} was provided more than once");
            }
        }
        Ok(Self { values, flags })
    }

    fn required_path(&self, name: &str) -> Result<PathBuf> {
        self.optional(name)
            .map(PathBuf::from)
            .with_context(|| format!("{name} is required"))
    }

    fn optional(&self, name: &str) -> Option<&str> {
        self.values.get(name).map(String::as_str)
    }

    fn flag(&self, name: &str) -> bool {
        self.flags.contains(name)
    }
}

fn ensure_empty(arguments: &[OsString]) -> Result<()> {
    if let Some(argument) = arguments.first() {
        bail!("unexpected argument `{}`", argument.to_string_lossy());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(values: &[&str]) -> Vec<OsString> {
        values.iter().map(OsString::from).collect()
    }

    #[test]
    fn defaults_to_run() {
        assert_eq!(
            Cli::parse(args(&["pakperk-worker"])).unwrap().command,
            Command::Run
        );
    }

    #[test]
    fn parses_script_compatible_prepare_command() {
        assert_eq!(
            Cli::parse(args(&[
                "pakperk-worker",
                "prepare-demo",
                "--manifest",
                "/inputs/seed.json",
                "--wait",
                "--timeout-seconds",
                "90",
            ]))
            .unwrap()
            .command,
            Command::PrepareDemo {
                manifest: PathBuf::from("/inputs/seed.json"),
                wait: true,
                timeout_seconds: 90,
            }
        );
    }

    #[test]
    fn parses_content_aware_verify_command() {
        assert_eq!(
            Cli::parse(args(&[
                "pakperk-worker",
                "verify-demo",
                "--manifest",
                "/inputs/seed.json",
                "--expected-connections",
                "/inputs/connections.json",
                "--content-evaluation",
                "/inputs/evaluation.json",
                "--output",
                "/reports/verification.json",
            ]))
            .unwrap()
            .command,
            Command::VerifyDemo {
                manifest: PathBuf::from("/inputs/seed.json"),
                expected_connections: PathBuf::from("/inputs/connections.json"),
                content_evaluation: PathBuf::from("/inputs/evaluation.json"),
                output: PathBuf::from("/reports/verification.json"),
            }
        );
    }

    #[test]
    fn parses_the_local_pdf_recovery_command() {
        assert_eq!(
            Cli::parse(args(&[
                "pakperk-worker",
                "recover-pdf",
                "--pdf",
                "/papers/scan.pdf",
                "--markdown",
                "/tmp/scan.md",
            ]))
            .unwrap()
            .command,
            Command::RecoverPdf {
                pdf: PathBuf::from("/papers/scan.pdf"),
                markdown: Some(PathBuf::from("/tmp/scan.md")),
            }
        );
        assert_eq!(
            Cli::parse(args(&["pakperk-worker", "recover-pdf", "--pdf", "a.pdf"]))
                .unwrap()
                .command,
            Command::RecoverPdf {
                pdf: PathBuf::from("a.pdf"),
                markdown: None,
            }
        );
        assert!(Cli::parse(args(&["pakperk-worker", "recover-pdf"])).is_err());
    }

    #[test]
    fn rejects_unknown_flags_without_values() {
        assert!(Cli::parse(args(&["pakperk-worker", "sync-metadata", "--unknown"])).is_err());
    }
}
