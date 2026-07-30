//! Bounded HTTP client for the GROBID sidecar.

use std::{path::Path, time::Duration};

use reqwest::{
    Client, StatusCode,
    multipart::{Form, Part},
};
use thiserror::Error;
use url::Url;

#[derive(Debug, Clone)]
pub struct GrobidConfig {
    pub base_url: Url,
    pub connect_timeout: Duration,
    pub request_timeout: Duration,
    pub max_pdf_bytes: usize,
    pub max_tei_bytes: usize,
}

impl Default for GrobidConfig {
    fn default() -> Self {
        Self {
            base_url: Url::parse("http://grobid:8070").expect("default GROBID URL is valid"),
            connect_timeout: Duration::from_secs(10),
            request_timeout: Duration::from_secs(180),
            max_pdf_bytes: 50 * 1024 * 1024,
            max_tei_bytes: 64 * 1024 * 1024,
        }
    }
}

#[derive(Debug, Error)]
pub enum GrobidError {
    #[error("invalid GROBID configuration: {0}")]
    InvalidConfiguration(String),
    #[error("GROBID request failed")]
    Transport(#[from] reqwest::Error),
    #[error("could not read PDF for GROBID")]
    ReadPdf(#[from] std::io::Error),
    #[error("GROBID returned HTTP {status}")]
    HttpStatus { status: StatusCode },
    #[error("GROBID returned an empty TEI document")]
    EmptyDocument,
    #[error("GROBID TEI exceeds configured limit of {maximum_bytes} bytes")]
    TeiTooLarge { maximum_bytes: usize },
    #[error("PDF exceeds configured GROBID upload limit of {maximum_bytes} bytes")]
    PdfTooLarge { maximum_bytes: usize },
    #[error("GROBID returned non-UTF-8 TEI")]
    InvalidUtf8,
}

#[derive(Debug, Clone)]
pub struct GrobidClient {
    config: GrobidConfig,
    http: Client,
}

impl GrobidClient {
    pub fn new(config: GrobidConfig) -> Result<Self, GrobidError> {
        if !matches!(config.base_url.scheme(), "http" | "https") {
            return Err(GrobidError::InvalidConfiguration(
                "base URL must use HTTP or HTTPS".into(),
            ));
        }
        if config.connect_timeout.is_zero()
            || config.request_timeout.is_zero()
            || config.max_pdf_bytes == 0
            || config.max_tei_bytes == 0
        {
            return Err(GrobidError::InvalidConfiguration(
                "timeouts and response limit must be positive".into(),
            ));
        }
        let http = Client::builder()
            .connect_timeout(config.connect_timeout)
            .timeout(config.request_timeout)
            .build()?;
        Ok(Self { config, http })
    }

    pub async fn health(&self) -> Result<(), GrobidError> {
        let response = self.http.get(self.endpoint("api/isalive")).send().await?;
        if !response.status().is_success() {
            return Err(GrobidError::HttpStatus {
                status: response.status(),
            });
        }
        let body = read_bounded(response, 4 * 1024).await?;
        let body = String::from_utf8(body).map_err(|_| GrobidError::InvalidUtf8)?;
        if !body.trim().eq_ignore_ascii_case("true") && !body.to_ascii_lowercase().contains("alive")
        {
            return Err(GrobidError::EmptyDocument);
        }
        Ok(())
    }

    pub async fn process_fulltext_file(&self, path: &Path) -> Result<String, GrobidError> {
        let bytes = tokio::fs::read(path).await?;
        let filename = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("paper.pdf");
        self.process_fulltext_document(bytes, filename).await
    }

    pub async fn process_fulltext_document(
        &self,
        pdf: Vec<u8>,
        filename: &str,
    ) -> Result<String, GrobidError> {
        if pdf.len() > self.config.max_pdf_bytes {
            return Err(GrobidError::PdfTooLarge {
                maximum_bytes: self.config.max_pdf_bytes,
            });
        }
        let safe_filename = sanitize_filename(filename);
        let input = Part::bytes(pdf)
            .file_name(safe_filename)
            .mime_str("application/pdf")?;
        let form = Form::new()
            .part("input", input)
            // Consolidation can trigger hidden Crossref/network calls inside
            // GROBID. Keep parsing deterministic; reference resolution belongs
            // to the Pakperk worker.
            .text("consolidateHeader", "0")
            .text("consolidateCitations", "0")
            .text("includeRawCitations", "1")
            .text("includeRawAffiliations", "0")
            .text("segmentSentences", "1")
            // GROBID models this option as a repeated multipart field. A
            // comma-combined value is accepted by the HTTP layer but ignored
            // as an unknown element name, silently dropping paragraph pages.
            .text("teiCoordinates", "p")
            .text("teiCoordinates", "ref")
            .text("teiCoordinates", "biblStruct");
        let response = self
            .http
            .post(self.endpoint("api/processFulltextDocument"))
            .multipart(form)
            .send()
            .await?;
        if !response.status().is_success() {
            return Err(GrobidError::HttpStatus {
                status: response.status(),
            });
        }
        if let Some(length) = response.content_length()
            && length > self.config.max_tei_bytes as u64
        {
            return Err(GrobidError::TeiTooLarge {
                maximum_bytes: self.config.max_tei_bytes,
            });
        }
        let bytes = read_bounded(response, self.config.max_tei_bytes).await?;
        if bytes.is_empty() {
            return Err(GrobidError::EmptyDocument);
        }
        let tei = String::from_utf8(bytes).map_err(|_| GrobidError::InvalidUtf8)?;
        if tei.trim().is_empty() {
            return Err(GrobidError::EmptyDocument);
        }
        Ok(tei)
    }

    fn endpoint(&self, path: &str) -> Url {
        let mut endpoint = self.config.base_url.clone();
        endpoint.set_query(None);
        endpoint.set_fragment(None);
        endpoint.set_path(&format!(
            "{}/{}",
            endpoint.path().trim_end_matches('/'),
            path.trim_start_matches('/')
        ));
        endpoint
    }
}

async fn read_bounded(
    mut response: reqwest::Response,
    maximum_bytes: usize,
) -> Result<Vec<u8>, GrobidError> {
    if let Some(length) = response.content_length()
        && length > maximum_bytes as u64
    {
        return Err(GrobidError::TeiTooLarge { maximum_bytes });
    }
    let advertised = response
        .content_length()
        .unwrap_or(0)
        .min(u64::try_from(maximum_bytes).unwrap_or(u64::MAX));
    let mut body = Vec::with_capacity(usize::try_from(advertised).unwrap_or(maximum_bytes));
    while let Some(chunk) = response.chunk().await? {
        if body.len().saturating_add(chunk.len()) > maximum_bytes {
            return Err(GrobidError::TeiTooLarge { maximum_bytes });
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

fn sanitize_filename(filename: &str) -> String {
    let filename = Path::new(filename)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("paper.pdf");
    let normalized = filename
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '.' | '-' | '_') {
                character
            } else {
                '_'
            }
        })
        .take(128)
        .collect::<String>();
    if normalized.to_ascii_lowercase().ends_with(".pdf") {
        normalized
    } else {
        format!("{normalized}.pdf")
    }
}

#[cfg(test)]
mod tests {
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::{TcpListener, TcpStream},
        sync::oneshot,
    };

    use super::*;

    #[test]
    fn constructs_endpoints_below_base_path() {
        let client = GrobidClient::new(GrobidConfig {
            base_url: Url::parse("http://localhost:8070/grobid/").unwrap(),
            ..GrobidConfig::default()
        })
        .unwrap();
        assert_eq!(
            client.endpoint("api/processFulltextDocument").as_str(),
            "http://localhost:8070/grobid/api/processFulltextDocument"
        );
    }

    #[test]
    fn strips_paths_and_unsafe_filename_characters() {
        assert_eq!(sanitize_filename("../../my paper?.PDF"), "my_paper_.PDF");
        assert_eq!(sanitize_filename("paper"), "paper.pdf");
    }

    #[tokio::test]
    async fn rejects_oversized_pdf_before_network_access() {
        let client = GrobidClient::new(GrobidConfig {
            base_url: Url::parse("http://127.0.0.1:1").unwrap(),
            max_pdf_bytes: 3,
            ..GrobidConfig::default()
        })
        .unwrap();
        let error = client
            .process_fulltext_document(vec![0; 4], "paper.pdf")
            .await
            .unwrap_err();
        assert!(matches!(
            error,
            GrobidError::PdfTooLarge { maximum_bytes: 3 }
        ));
    }

    #[tokio::test]
    async fn sends_bounded_deterministic_multipart_request() {
        let Some(listener) = bind_loopback().await else {
            return;
        };
        let address = listener.local_addr().unwrap();
        let (request_sender, request_receiver) = oneshot::channel();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let request = read_request(&mut stream).await;
            request_sender.send(request).unwrap();
            let body = "<TEI><text><body/></text></TEI>";
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/xml\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(response.as_bytes()).await.unwrap();
        });
        let client = GrobidClient::new(GrobidConfig {
            base_url: Url::parse(&format!("http://{address}")).unwrap(),
            request_timeout: Duration::from_secs(2),
            ..GrobidConfig::default()
        })
        .unwrap();
        let tei = client
            .process_fulltext_document(b"%PDF-fixture".to_vec(), "../unsafe paper.pdf")
            .await
            .unwrap();
        assert!(tei.starts_with("<TEI>"));
        let request = String::from_utf8(request_receiver.await.unwrap()).unwrap();
        assert!(request.starts_with("POST /api/processFulltextDocument HTTP/1.1"));
        assert!(request.contains("name=\"input\""));
        assert!(request.contains("filename=\"unsafe_paper.pdf\""));
        assert!(request.contains("name=\"consolidateHeader\"\r\n\r\n0"));
        assert!(request.contains("name=\"consolidateCitations\"\r\n\r\n0"));
        assert_eq!(request.matches("name=\"teiCoordinates\"").count(), 3);
        for coordinate_type in ["p", "ref", "biblStruct"] {
            assert!(
                request.contains(&format!("name=\"teiCoordinates\"\r\n\r\n{coordinate_type}")),
                "missing repeated coordinate type {coordinate_type}"
            );
        }
        server.await.unwrap();
    }

    #[tokio::test]
    async fn live_service_returns_structured_tei_when_configured() {
        let (Ok(base_url), Ok(pdf_path)) = (
            std::env::var("TEST_GROBID_URL"),
            std::env::var("TEST_GROBID_PDF"),
        ) else {
            eprintln!(
                "TEST_GROBID_URL and TEST_GROBID_PDF are unset; skipped live GROBID coverage"
            );
            return;
        };
        let client = GrobidClient::new(GrobidConfig {
            base_url: Url::parse(&base_url).expect("TEST_GROBID_URL must be a valid URL"),
            ..GrobidConfig::default()
        })
        .unwrap();

        client.health().await.unwrap();
        let tei = client
            .process_fulltext_file(Path::new(&pdf_path))
            .await
            .unwrap();

        assert!(tei.contains("<TEI"));
        assert!(tei.contains("<body"));
        assert!(tei.contains("<div"));
        assert!(
            tei.contains("<p coords="),
            "live GROBID response must retain paragraph page coordinates"
        );
    }

    async fn bind_loopback() -> Option<TcpListener> {
        match TcpListener::bind("127.0.0.1:0").await {
            Ok(listener) => Some(listener),
            Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => {
                eprintln!(
                    "loopback sockets are unavailable; skipped mocked GROBID boundary coverage"
                );
                None
            }
            Err(error) => panic!("could not bind mocked GROBID server: {error}"),
        }
    }

    async fn read_request(stream: &mut TcpStream) -> Vec<u8> {
        let mut request = Vec::new();
        let mut buffer = [0_u8; 4096];
        let mut expected_length = None;
        loop {
            let count = stream.read(&mut buffer).await.unwrap();
            if count == 0 {
                break;
            }
            request.extend_from_slice(&buffer[..count]);
            if expected_length.is_none()
                && let Some(header_end) =
                    request.windows(4).position(|window| window == b"\r\n\r\n")
            {
                let headers = String::from_utf8_lossy(&request[..header_end]);
                let content_length = headers.lines().find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().ok())
                        .flatten()
                });
                expected_length = content_length.map(|length| header_end + 4 + length);
            }
            if expected_length.is_some_and(|length| request.len() >= length) {
                break;
            }
        }
        request
    }
}
