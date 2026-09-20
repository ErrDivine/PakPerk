//! The worker binary re-executed as its own PDF-rendering child, exactly as
//! page-image recovery starts it in production.

use std::{path::PathBuf, time::Duration};

use image::ImageFormat;
use pdf_render::{
    RenderError, RenderLimits, render_pdf_pages,
    testing::{TestPage, letter, minimal_pdf},
};

const WORKER: &str = env!("CARGO_BIN_EXE_pakperk-worker");
const DEADLINE: Duration = Duration::from_secs(60);

fn write_pdf(directory: &tempfile::TempDir, name: &str, bytes: &[u8]) -> PathBuf {
    let path = directory.path().join(name);
    std::fs::write(&path, bytes).unwrap();
    path
}

#[tokio::test]
async fn the_worker_binary_renders_every_page_without_any_configuration() {
    // The child needs no DATABASE_URL, provider key, or anything else: it is
    // dispatched before configuration, telemetry, or an async runtime exists.
    let directory = tempfile::tempdir().unwrap();
    let pdf = write_pdf(
        &directory,
        "paper.pdf",
        &minimal_pdf(&[
            letter(&["1 Introduction", "We study parsing of scientific papers."]),
            TestPage {
                width: 792.0,
                height: 612.0,
                lines: &["A landscape page"],
            },
        ]),
    );
    let limits = RenderLimits::default();

    let pages = render_pdf_pages(std::path::Path::new(WORKER), &pdf, &limits, DEADLINE)
        .await
        .unwrap();

    assert_eq!(pages.len(), 2);
    assert_eq!(
        pages.iter().map(|page| page.number).collect::<Vec<_>>(),
        [1, 2]
    );
    assert!(pages.iter().all(|page| page.width == limits.width));
    assert_eq!((pages[0].height, pages[1].height), (1_812, 1_082));
    for page in &pages {
        let decoded = image::load_from_memory_with_format(&page.png, ImageFormat::Png)
            .expect("each page is a valid PNG")
            .into_luma8();
        assert_eq!(
            (decoded.width(), decoded.height()),
            (page.width, page.height)
        );
        assert!(
            decoded.pixels().any(|pixel| pixel.0[0] < 64),
            "ink is visible"
        );
    }
}

#[tokio::test]
async fn documents_the_child_cannot_render_fail_with_a_specific_error() {
    let directory = tempfile::tempdir().unwrap();
    let worker = std::path::Path::new(WORKER);
    let limits = RenderLimits::default();

    let garbage = write_pdf(&directory, "garbage.pdf", b"this is not a PDF at all");
    assert!(matches!(
        render_pdf_pages(worker, &garbage, &limits, DEADLINE).await,
        Err(RenderError::InvalidPdf)
    ));

    let three = write_pdf(
        &directory,
        "three.pdf",
        &minimal_pdf(&[letter(&["a"]), letter(&["b"]), letter(&["c"])]),
    );
    let one_page_only = RenderLimits {
        max_pages: 1,
        ..limits
    };
    assert!(matches!(
        render_pdf_pages(worker, &three, &one_page_only, DEADLINE).await,
        Err(RenderError::TooManyPages)
    ));

    let tall = write_pdf(
        &directory,
        "tall.pdf",
        &minimal_pdf(&[TestPage {
            width: 612.0,
            height: 30_000.0,
            lines: &["a very tall page"],
        }]),
    );
    assert!(matches!(
        render_pdf_pages(worker, &tall, &limits, DEADLINE).await,
        Err(RenderError::UnsafePageSize)
    ));

    let missing = directory.path().join("missing.pdf");
    assert!(matches!(
        render_pdf_pages(worker, &missing, &limits, DEADLINE).await,
        Err(RenderError::Internal)
    ));
}
