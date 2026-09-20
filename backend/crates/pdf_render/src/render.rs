//! In-process rasterization. This runs inside the sandboxed child, never in the
//! worker's own process.

use std::sync::Arc;

use hayro::{
    RenderSettings,
    hayro_interpret::InterpreterSettings,
    hayro_syntax::{LoadPdfError, Pdf},
    render,
    vello_cpu::{Pixmap, color::palette::css::WHITE},
};
use image::{
    ExtendedColorType, ImageEncoder as _,
    codecs::png::{CompressionType, FilterType, PngEncoder},
};

use crate::{PageImage, RenderError, RenderLimits};

/// Smallest page edge, in PDF points (half an inch), that is rendered.
const MIN_PAGE_POINTS: f32 = 36.0;

/// Renders every page of a PDF to a grayscale PNG of the configured width.
///
/// Fails closed: a document with more pages than the limit, an unusable page
/// size, or an oversized result is an error, never a truncated rendering.
pub fn render_pages(pdf: Vec<u8>, limits: &RenderLimits) -> Result<Vec<PageImage>, RenderError> {
    if !limits.is_valid() {
        return Err(RenderError::Internal);
    }
    if u64::try_from(pdf.len()).map_or(true, |length| length > limits.max_pdf_bytes) {
        return Err(RenderError::PdfTooLarge);
    }
    let document = Pdf::new(Arc::new(pdf)).map_err(|error| {
        if matches!(error, LoadPdfError::Decryption(_)) {
            RenderError::Encrypted
        } else {
            RenderError::InvalidPdf
        }
    })?;
    let pages = document.pages();
    if pages.is_empty() {
        return Err(RenderError::NoPages);
    }
    if pages.len() > usize::try_from(limits.max_pages).unwrap_or(usize::MAX) {
        return Err(RenderError::TooManyPages);
    }

    let interpreter_settings = InterpreterSettings::default();
    let mut rendered = Vec::with_capacity(pages.len());
    let mut total_bytes = 0_usize;
    for (index, page) in pages.iter().enumerate() {
        let (width, height) = page.render_dimensions();
        let (pixel_width, pixel_height, scale) = target_size(width, height, limits)?;
        let pixmap = render(
            page,
            &interpreter_settings,
            &RenderSettings {
                x_scale: scale,
                y_scale: scale,
                width: Some(u16::try_from(pixel_width).map_err(|_| RenderError::UnsafePageSize)?),
                height: Some(u16::try_from(pixel_height).map_err(|_| RenderError::UnsafePageSize)?),
                bg_color: WHITE,
            },
        );
        let png = encode_grayscale_png(&pixmap)?;
        total_bytes = total_bytes.saturating_add(png.len());
        if png.len() > limits.max_page_bytes || total_bytes > limits.max_total_bytes {
            return Err(RenderError::OutputTooLarge);
        }
        rendered.push(PageImage {
            number: u32::try_from(index + 1).map_err(|_| RenderError::TooManyPages)?,
            width: pixel_width,
            height: pixel_height,
            png,
        });
    }
    Ok(rendered)
}

/// Pixel size and scale for a page of `width` by `height` points. Page sizes
/// come from the (untrusted) document, so a hostile media box must not choose
/// the size of an allocation.
fn target_size(
    width: f32,
    height: f32,
    limits: &RenderLimits,
) -> Result<(u32, u32, f32), RenderError> {
    if !(width.is_finite() && height.is_finite())
        || width < MIN_PAGE_POINTS
        || height < MIN_PAGE_POINTS
    {
        return Err(RenderError::UnsafePageSize);
    }
    let scale = f64::from(limits.width) / f64::from(width);
    let pixel_height = (f64::from(height) * scale).ceil();
    if !(1.0..=f64::from(limits.max_height)).contains(&pixel_height) {
        return Err(RenderError::UnsafePageSize);
    }
    // `pixel_height` is a whole number in 1..=max_height, so both conversions
    // are exact.
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let (pixel_height, scale) = (pixel_height as u32, scale as f32);
    Ok((limits.width, pixel_height, scale))
}

/// Text pages carry no information in color, and 8-bit grayscale is about a
/// third of the size of the rasterizer's RGBA PNG.
fn encode_grayscale_png(pixmap: &Pixmap) -> Result<Vec<u8>, RenderError> {
    let luma = pixmap
        .data_as_u8_slice()
        .chunks_exact(4)
        .map(|pixel| {
            // The page background is opaque white, so premultiplied and
            // straight alpha agree.
            let weighted =
                u32::from(pixel[0]) * 299 + u32::from(pixel[1]) * 587 + u32::from(pixel[2]) * 114;
            u8::try_from(weighted / 1_000).unwrap_or(u8::MAX)
        })
        .collect::<Vec<u8>>();
    let mut png = Vec::new();
    PngEncoder::new_with_quality(&mut png, CompressionType::Default, FilterType::Adaptive)
        .write_image(
            &luma,
            u32::from(pixmap.width()),
            u32::from(pixmap.height()),
            ExtendedColorType::L8,
        )
        .map_err(|_| RenderError::Internal)?;
    Ok(png)
}

#[cfg(test)]
mod tests {
    use image::ImageFormat;

    use super::*;
    use crate::testing::{TestPage, letter, minimal_pdf};

    fn decode(page: &PageImage) -> image::GrayImage {
        image::load_from_memory_with_format(&page.png, ImageFormat::Png)
            .expect("the page is a valid PNG")
            .into_luma8()
    }

    #[test]
    fn every_page_is_rendered_at_the_target_width() {
        let pdf = minimal_pdf(&[
            letter(&["1 Introduction", "We study parsing of scientific papers."]),
            letter(&["2 Method"]),
        ]);
        let limits = RenderLimits::default();
        let pages = render_pages(pdf, &limits).unwrap();

        assert_eq!(pages.len(), 2);
        for (index, page) in pages.iter().enumerate() {
            assert_eq!(page.number as usize, index + 1);
            assert_eq!(page.width, limits.width);
            // 792 / 612 of the width, rounded up.
            assert_eq!(page.height, 1_812);
            let image = decode(page);
            assert_eq!((image.width(), image.height()), (page.width, page.height));
            assert!(
                image.pixels().any(|pixel| pixel.0[0] < 64),
                "page {} has visible ink",
                page.number
            );
            let white = image.pixels().filter(|pixel| pixel.0[0] > 240).count();
            assert!(white * 10 > image.pixels().len() * 9, "mostly paper");
        }
    }

    #[test]
    fn landscape_pages_keep_their_shape() {
        let pdf = minimal_pdf(&[TestPage {
            width: 792.0,
            height: 612.0,
            lines: &["wide page"],
        }]);
        let pages = render_pages(pdf, &RenderLimits::default()).unwrap();
        // 612 / 792 of the width.
        assert_eq!(pages[0].height, 1_082);
    }

    #[test]
    fn documents_that_are_not_pdfs_are_rejected() {
        let limits = RenderLimits::default();
        assert!(matches!(
            render_pages(b"this is not a PDF".to_vec(), &limits),
            Err(RenderError::InvalidPdf)
        ));
        assert!(matches!(
            render_pages(Vec::new(), &limits),
            Err(RenderError::InvalidPdf)
        ));
    }

    #[test]
    fn documents_without_pages_are_rejected() {
        let error = render_pages(minimal_pdf(&[]), &RenderLimits::default()).unwrap_err();
        assert!(
            matches!(error, RenderError::NoPages | RenderError::InvalidPdf),
            "{error:?}"
        );
    }

    #[test]
    fn a_page_count_over_the_limit_fails_instead_of_truncating() {
        let pdf = minimal_pdf(&[letter(&["a"]), letter(&["b"]), letter(&["c"])]);
        let limits = RenderLimits {
            max_pages: 2,
            ..RenderLimits::default()
        };
        assert!(matches!(
            render_pages(pdf, &limits),
            Err(RenderError::TooManyPages)
        ));
    }

    #[test]
    fn hostile_page_sizes_are_refused_before_anything_is_allocated() {
        let limits = RenderLimits::default();
        for (width, height) in [(612.0, 20_000.0), (612.0, 5.0), (5.0, 792.0), (1.0, 1.0)] {
            let pdf = minimal_pdf(&[TestPage {
                width,
                height,
                lines: &["x"],
            }]);
            assert!(
                matches!(render_pages(pdf, &limits), Err(RenderError::UnsafePageSize)),
                "{width} x {height}"
            );
        }
    }

    #[test]
    fn a_huge_media_box_cannot_choose_the_size_of_the_bitmap() {
        // The bitmap size follows the configured width, not the page's own
        // units, so an enormous square page still renders at 1400 x 1400.
        let pdf = minimal_pdf(&[TestPage {
            width: 1.0e9,
            height: 1.0e9,
            lines: &["x"],
        }]);
        let pages = render_pages(pdf, &RenderLimits::default()).unwrap();
        assert_eq!((pages[0].width, pages[0].height), (1_400, 1_400));
    }

    #[test]
    fn oversized_input_and_output_are_refused() {
        let pdf = minimal_pdf(&[letter(&["a"])]);
        let small_input = RenderLimits {
            max_pdf_bytes: 64,
            ..RenderLimits::default()
        };
        assert!(matches!(
            render_pages(pdf.clone(), &small_input),
            Err(RenderError::PdfTooLarge)
        ));
        let small_output = RenderLimits {
            max_page_bytes: 100,
            ..RenderLimits::default()
        };
        assert!(matches!(
            render_pages(pdf, &small_output),
            Err(RenderError::OutputTooLarge)
        ));
    }

    #[test]
    fn invalid_limits_are_an_internal_error() {
        let limits = RenderLimits {
            width: 10,
            ..RenderLimits::default()
        };
        assert!(matches!(
            render_pages(minimal_pdf(&[letter(&["a"])]), &limits),
            Err(RenderError::Internal)
        ));
    }
}
