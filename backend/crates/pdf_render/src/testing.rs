//! Synthetic PDFs for tests. Only compiled for tests and behind the
//! `test-support` feature, never in a production build.

use std::fmt::Write as _;

/// One page of a synthetic document: a size in points and lines of Times text.
#[derive(Debug, Clone, Copy)]
pub struct TestPage<'a> {
    pub width: f32,
    pub height: f32,
    pub lines: &'a [&'a str],
}

/// A US Letter page.
#[must_use]
pub const fn letter<'a>(lines: &'a [&'a str]) -> TestPage<'a> {
    TestPage {
        width: 612.0,
        height: 792.0,
        lines,
    }
}

/// A well-formed PDF with one Times-Roman text block per page and a correct
/// cross-reference table.
#[must_use]
pub fn minimal_pdf(pages: &[TestPage<'_>]) -> Vec<u8> {
    // 1 catalog, 2 page tree, 3 font, then a page and a content stream per page.
    let mut objects = vec![
        "<< /Type /Catalog /Pages 2 0 R >>".to_owned(),
        String::new(),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Times-Roman >>".to_owned(),
    ];
    let mut kids = String::new();
    for (index, page) in pages.iter().enumerate() {
        let page_object = 4 + 2 * index;
        let _ = write!(kids, "{page_object} 0 R ");
        let top = page.height - 72.0;
        let mut content = format!("BT /F1 12 Tf 14 TL 72 {top} Td\n");
        for line in page.lines {
            let escaped = line
                .replace('\\', "\\\\")
                .replace('(', "\\(")
                .replace(')', "\\)");
            let _ = writeln!(content, "({escaped}) Tj T*");
        }
        content.push_str("ET");
        objects.push(format!(
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {} {}] /Contents {} 0 R /Resources << /Font << /F1 3 0 R >> >> >>",
            page.width,
            page.height,
            page_object + 1,
        ));
        objects.push(format!(
            "<< /Length {} >>\nstream\n{content}\nendstream",
            content.len()
        ));
    }
    objects[1] = format!(
        "<< /Type /Pages /Kids [{}] /Count {} >>",
        kids.trim_end(),
        pages.len()
    );

    let mut bytes = b"%PDF-1.4\n".to_vec();
    let mut offsets = Vec::with_capacity(objects.len());
    for (index, body) in objects.iter().enumerate() {
        offsets.push(bytes.len());
        bytes.extend(format!("{} 0 obj\n{body}\nendobj\n", index + 1).as_bytes());
    }
    let xref = bytes.len();
    bytes.extend(format!("xref\n0 {}\n0000000000 65535 f \n", objects.len() + 1).as_bytes());
    for offset in offsets {
        bytes.extend(format!("{offset:010} 00000 n \n").as_bytes());
    }
    bytes.extend(
        format!(
            "trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n",
            objects.len() + 1
        )
        .as_bytes(),
    );
    bytes
}
