//! Bounded PDF page rasterization for model-assisted document recovery.
//!
//! PDFs are untrusted input, and this is the last resort after the primary
//! parser failed, so the files that reach this crate are disproportionately
//! malformed or hostile. Rendering therefore never runs in the worker's own
//! process. The caller re-executes its own binary with [`CHILD_ARGUMENT`]; the
//! child renders with a pure-Rust rasterizer under CPU and address-space limits
//! and an empty environment, and the parent reads back length-prefixed PNG
//! frames under a deadline and a byte cap, killing the child when either is
//! exceeded. A hang, a crash, or an out-of-memory abort can only cost the child.

mod child;
mod parent;
mod render;
#[cfg(any(test, feature = "test-support"))]
pub mod testing;
mod wire;

use thiserror::Error;

pub use child::{CHILD_ARGUMENT, run_child_if_requested};
pub use parent::render_pdf_pages;
pub use render::render_pages;

/// Hard bounds on one rendering. Every value is enforced by the child and
/// re-checked by the parent, so a misbehaving child cannot exceed them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RenderLimits {
    /// Most pages rendered. A longer document fails instead of being truncated.
    pub max_pages: u32,
    /// Width of every rendered page in pixels; height follows the page shape.
    pub width: u32,
    /// Tallest rendered page in pixels. Pages that would be taller fail.
    pub max_height: u32,
    /// Largest PDF the child reads.
    pub max_pdf_bytes: u64,
    /// Largest encoded PNG for one page.
    pub max_page_bytes: usize,
    /// Largest total of encoded PNG bytes for the document.
    pub max_total_bytes: usize,
}

impl Default for RenderLimits {
    fn default() -> Self {
        Self {
            max_pages: 40,
            width: 1_400,
            max_height: 4_096,
            max_pdf_bytes: 64 * 1024 * 1024,
            max_page_bytes: 6 * 1024 * 1024,
            max_total_bytes: 96 * 1024 * 1024,
        }
    }
}

impl RenderLimits {
    pub(crate) fn is_valid(&self) -> bool {
        (1..=1_000).contains(&self.max_pages)
            && (200..=4_096).contains(&self.width)
            && (200..=8_192).contains(&self.max_height)
            && self.max_pdf_bytes > 0
            && self.max_page_bytes > 0
            && self.max_total_bytes >= self.max_page_bytes
    }
}

/// One rendered page: an 8-bit grayscale PNG.
#[derive(Clone, PartialEq, Eq)]
pub struct PageImage {
    /// 1-based page number.
    pub number: u32,
    pub width: u32,
    pub height: u32,
    pub png: Vec<u8>,
}

impl std::fmt::Debug for PageImage {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("PageImage")
            .field("number", &self.number)
            .field("width", &self.width)
            .field("height", &self.height)
            .field("png_bytes", &self.png.len())
            .finish()
    }
}

#[derive(Debug, Error)]
pub enum RenderError {
    #[error("the file could not be read as a PDF document")]
    InvalidPdf,
    #[error("the PDF is encrypted")]
    Encrypted,
    #[error("the PDF is larger than the render limit")]
    PdfTooLarge,
    #[error("the PDF has no pages")]
    NoPages,
    #[error("the PDF has more pages than the render limit")]
    TooManyPages,
    #[error("a page has dimensions outside the render limits")]
    UnsafePageSize,
    #[error("the rendered pages exceed the output limit")]
    OutputTooLarge,
    #[error("the renderer failed internally")]
    Internal,
    #[error("the renderer did not finish before its deadline")]
    Deadline,
    #[error("the renderer process failed")]
    ChildFailed,
    #[error("the renderer process could not be started")]
    Spawn(#[source] std::io::Error),
}

impl RenderError {
    /// Stable, content-free label for logs and metrics.
    #[must_use]
    pub const fn kind(&self) -> &'static str {
        match self {
            Self::InvalidPdf => "render_invalid_pdf",
            Self::Encrypted => "render_encrypted",
            Self::PdfTooLarge => "render_pdf_too_large",
            Self::NoPages => "render_no_pages",
            Self::TooManyPages => "render_too_many_pages",
            Self::UnsafePageSize => "render_unsafe_page_size",
            Self::OutputTooLarge => "render_output_too_large",
            Self::Internal => "render_internal",
            Self::Deadline => "render_deadline",
            Self::ChildFailed => "render_child_failed",
            Self::Spawn(_) => "render_spawn",
        }
    }

    /// Exit status of the render child for a failure it detected itself.
    pub(crate) const fn exit_code(&self) -> u8 {
        match self {
            Self::InvalidPdf => 10,
            Self::Encrypted => 11,
            Self::PdfTooLarge => 12,
            Self::NoPages => 13,
            Self::TooManyPages => 14,
            Self::UnsafePageSize => 15,
            Self::OutputTooLarge => 16,
            Self::Internal | Self::Deadline | Self::ChildFailed | Self::Spawn(_) => 17,
        }
    }

    pub(crate) const fn from_exit_code(code: i32) -> Option<Self> {
        match code {
            10 => Some(Self::InvalidPdf),
            11 => Some(Self::Encrypted),
            12 => Some(Self::PdfTooLarge),
            13 => Some(Self::NoPages),
            14 => Some(Self::TooManyPages),
            15 => Some(Self::UnsafePageSize),
            16 => Some(Self::OutputTooLarge),
            17 => Some(Self::Internal),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exit_codes_round_trip_for_every_child_detected_failure() {
        for error in [
            RenderError::InvalidPdf,
            RenderError::Encrypted,
            RenderError::PdfTooLarge,
            RenderError::NoPages,
            RenderError::TooManyPages,
            RenderError::UnsafePageSize,
            RenderError::OutputTooLarge,
            RenderError::Internal,
        ] {
            let code = i32::from(error.exit_code());
            let decoded = RenderError::from_exit_code(code).expect("code is mapped");
            assert_eq!(decoded.kind(), error.kind());
        }
        assert!(RenderError::from_exit_code(0).is_none());
        assert!(RenderError::from_exit_code(2).is_none());
        assert!(RenderError::from_exit_code(101).is_none());
    }

    #[test]
    fn default_limits_are_valid_and_bounded() {
        let limits = RenderLimits::default();
        assert!(limits.is_valid());
        assert!(
            !RenderLimits {
                width: 100,
                ..limits
            }
            .is_valid()
        );
        assert!(
            !RenderLimits {
                max_total_bytes: 1,
                ..limits
            }
            .is_valid()
        );
    }
}
