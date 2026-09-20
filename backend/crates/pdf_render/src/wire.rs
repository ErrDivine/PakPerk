//! The frame protocol between the render child and its parent, and the child's
//! argument list. Everything the parent reads from the child is treated as
//! untrusted: a malformed or oversized stream is rejected, never repaired.

use std::{
    ffi::OsString,
    io::{self, Write},
    path::{Path, PathBuf},
};

use crate::{PageImage, RenderLimits};

const MAGIC: [u8; 5] = *b"PKRP\x01";
const END: [u8; 4] = *b"END!";
const PNG_SIGNATURE: [u8; 8] = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
/// Per-page header: number, width, height, and length as little-endian `u32`.
const FRAME_HEADER_BYTES: u64 = 16;

/// Most bytes a well-behaved child can write for these limits.
pub(crate) fn maximum_stream_bytes(limits: &RenderLimits) -> u64 {
    let payload = u64::try_from(limits.max_total_bytes).unwrap_or(u64::MAX);
    payload
        .saturating_add(u64::from(limits.max_pages).saturating_mul(FRAME_HEADER_BYTES))
        .saturating_add((MAGIC.len() + END.len() + 4) as u64)
}

pub(crate) fn write_pages(out: &mut impl Write, pages: &[PageImage]) -> io::Result<()> {
    let oversized = || io::Error::new(io::ErrorKind::InvalidInput, "frame field exceeds u32");
    out.write_all(&MAGIC)?;
    out.write_all(
        &u32::try_from(pages.len())
            .map_err(|_| oversized())?
            .to_le_bytes(),
    )?;
    for page in pages {
        out.write_all(&page.number.to_le_bytes())?;
        out.write_all(&page.width.to_le_bytes())?;
        out.write_all(&page.height.to_le_bytes())?;
        out.write_all(
            &u32::try_from(page.png.len())
                .map_err(|_| oversized())?
                .to_le_bytes(),
        )?;
        out.write_all(&page.png)?;
    }
    out.write_all(&END)?;
    out.flush()
}

struct Cursor<'a> {
    bytes: &'a [u8],
}

impl<'a> Cursor<'a> {
    fn take(&mut self, count: usize) -> Option<&'a [u8]> {
        if self.bytes.len() < count {
            return None;
        }
        let (head, tail) = self.bytes.split_at(count);
        self.bytes = tail;
        Some(head)
    }

    fn u32(&mut self) -> Option<u32> {
        Some(u32::from_le_bytes(self.take(4)?.try_into().ok()?))
    }
}

/// Decodes a complete child stream. `None` means the stream is malformed,
/// truncated, out of bounds, or carries trailing bytes.
pub(crate) fn read_pages(bytes: &[u8], limits: &RenderLimits) -> Option<Vec<PageImage>> {
    let mut cursor = Cursor { bytes };
    if cursor.take(MAGIC.len())? != MAGIC {
        return None;
    }
    let count = cursor.u32()?;
    if !(1..=limits.max_pages).contains(&count) {
        return None;
    }
    let mut pages = Vec::with_capacity(usize::try_from(count).ok()?);
    let mut total = 0_usize;
    for expected in 1..=count {
        let number = cursor.u32()?;
        let width = cursor.u32()?;
        let height = cursor.u32()?;
        let length = usize::try_from(cursor.u32()?).ok()?;
        if number != expected
            || !(1..=limits.width).contains(&width)
            || !(1..=limits.max_height).contains(&height)
            || !(PNG_SIGNATURE.len()..=limits.max_page_bytes).contains(&length)
        {
            return None;
        }
        total = total.checked_add(length)?;
        if total > limits.max_total_bytes {
            return None;
        }
        let png = cursor.take(length)?;
        if !png.starts_with(&PNG_SIGNATURE) {
            return None;
        }
        pages.push(PageImage {
            number,
            width,
            height,
            png: png.to_vec(),
        });
    }
    if cursor.take(END.len())? != END || !cursor.bytes.is_empty() {
        return None;
    }
    Some(pages)
}

/// Positional arguments after [`crate::CHILD_ARGUMENT`].
pub(crate) fn child_arguments(pdf: &Path, limits: &RenderLimits) -> Vec<OsString> {
    vec![
        pdf.as_os_str().to_owned(),
        limits.max_pages.to_string().into(),
        limits.width.to_string().into(),
        limits.max_height.to_string().into(),
        limits.max_pdf_bytes.to_string().into(),
        limits.max_page_bytes.to_string().into(),
        limits.max_total_bytes.to_string().into(),
    ]
}

pub(crate) fn parse_child_arguments(arguments: &[OsString]) -> Option<(PathBuf, RenderLimits)> {
    let [
        pdf,
        max_pages,
        width,
        max_height,
        max_pdf_bytes,
        max_page_bytes,
        max_total_bytes,
    ] = arguments
    else {
        return None;
    };
    let number = |value: &OsString| value.to_str()?.parse::<u64>().ok();
    let limits = RenderLimits {
        max_pages: u32::try_from(number(max_pages)?).ok()?,
        width: u32::try_from(number(width)?).ok()?,
        max_height: u32::try_from(number(max_height)?).ok()?,
        max_pdf_bytes: number(max_pdf_bytes)?,
        max_page_bytes: usize::try_from(number(max_page_bytes)?).ok()?,
        max_total_bytes: usize::try_from(number(max_total_bytes)?).ok()?,
    };
    limits.is_valid().then(|| (PathBuf::from(pdf), limits))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn png(extra: usize) -> Vec<u8> {
        let mut bytes = PNG_SIGNATURE.to_vec();
        bytes.extend(std::iter::repeat_n(7_u8, extra));
        bytes
    }

    fn pages() -> Vec<PageImage> {
        (1..=3)
            .map(|number| PageImage {
                number,
                width: 1_400,
                height: 1_812,
                png: png(number as usize * 10),
            })
            .collect()
    }

    fn encoded(pages: &[PageImage]) -> Vec<u8> {
        let mut bytes = Vec::new();
        write_pages(&mut bytes, pages).unwrap();
        bytes
    }

    #[test]
    fn frames_round_trip() {
        let limits = RenderLimits::default();
        let bytes = encoded(&pages());
        assert!(u64::try_from(bytes.len()).unwrap() <= maximum_stream_bytes(&limits));
        assert_eq!(read_pages(&bytes, &limits), Some(pages()));
    }

    #[test]
    fn every_truncation_of_a_valid_stream_is_rejected() {
        let limits = RenderLimits::default();
        let bytes = encoded(&pages());
        for length in 0..bytes.len() {
            assert_eq!(read_pages(&bytes[..length], &limits), None, "{length}");
        }
    }

    #[test]
    fn trailing_bytes_wrong_magic_and_wrong_order_are_rejected() {
        let limits = RenderLimits::default();
        let mut trailing = encoded(&pages());
        trailing.push(0);
        assert_eq!(read_pages(&trailing, &limits), None);

        let mut magic = encoded(&pages());
        magic[0] = b'X';
        assert_eq!(read_pages(&magic, &limits), None);

        let mut swapped = pages();
        swapped.swap(0, 1);
        assert_eq!(read_pages(&encoded(&swapped), &limits), None);
    }

    #[test]
    fn frames_outside_the_limits_are_rejected() {
        let limits = RenderLimits::default();
        let too_many = RenderLimits {
            max_pages: 2,
            ..limits
        };
        assert_eq!(read_pages(&encoded(&pages()), &too_many), None);

        let mut wide = pages();
        wide[0].width = limits.width + 1;
        assert_eq!(read_pages(&encoded(&wide), &limits), None);

        let mut tall = pages();
        tall[0].height = limits.max_height + 1;
        assert_eq!(read_pages(&encoded(&tall), &limits), None);

        let big_page = RenderLimits {
            max_page_bytes: 12,
            ..limits
        };
        assert_eq!(read_pages(&encoded(&pages()), &big_page), None);

        // Each page fits on its own (18, 28, and 38 bytes), but not together.
        let big_total = RenderLimits {
            max_total_bytes: 70,
            max_page_bytes: 40,
            ..limits
        };
        assert_eq!(read_pages(&encoded(&pages()), &big_total), None);
    }

    #[test]
    fn payloads_that_are_not_png_are_rejected() {
        let limits = RenderLimits::default();
        let mut not_png = pages();
        not_png[1].png = vec![0; 20];
        assert_eq!(read_pages(&encoded(&not_png), &limits), None);
        assert_eq!(read_pages(&encoded(&[]), &limits), None);
    }

    #[test]
    fn child_arguments_round_trip_and_reject_invalid_limits() {
        let limits = RenderLimits {
            max_pages: 7,
            ..RenderLimits::default()
        };
        let arguments = child_arguments(Path::new("/tmp/paper.pdf"), &limits);
        let (path, parsed) = parse_child_arguments(&arguments).unwrap();
        assert_eq!(path, Path::new("/tmp/paper.pdf"));
        assert_eq!(parsed, limits);

        assert!(parse_child_arguments(&arguments[..6]).is_none());
        let mut garbled = arguments.clone();
        garbled[1] = "seven".into();
        assert!(parse_child_arguments(&garbled).is_none());
        let mut invalid = arguments;
        invalid[2] = "50".into();
        assert!(parse_child_arguments(&invalid).is_none());
    }
}
