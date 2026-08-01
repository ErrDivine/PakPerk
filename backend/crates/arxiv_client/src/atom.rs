use std::collections::HashSet;

use chrono::{DateTime, Utc};
use domain::{ArxivIdentifier, Author, PaperMetadata};
use quick_xml::{
    Reader, XmlVersion,
    events::{BytesStart, Event},
};
use url::Url;

use crate::{ArxivError, normalize_arxiv_id};

#[derive(Debug, Default)]
struct EntryBuilder {
    id: Option<String>,
    title: Option<String>,
    summary: Option<String>,
    authors: Vec<String>,
    primary_category: Option<String>,
    categories: Vec<String>,
    published: Option<String>,
    updated: Option<String>,
    abs_url: Option<String>,
    pdf_url: Option<String>,
    doi: Option<String>,
    journal_reference: Option<String>,
    comment: Option<String>,
    license_uri: Option<String>,
    active_text: Option<TextTarget>,
    text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TextTarget {
    Id,
    Title,
    Summary,
    AuthorName,
    Published,
    Updated,
    Doi,
    JournalReference,
    Comment,
}

#[allow(clippy::too_many_lines)] // Streaming state machine keeps XML state explicit.
pub fn parse_atom_feed(
    xml: &str,
    fetched_at: DateTime<Utc>,
) -> Result<Vec<PaperMetadata>, ArxivError> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(false);
    let mut entries = Vec::new();
    let mut current: Option<EntryBuilder> = None;
    let mut in_author = false;

    loop {
        match reader.read_event() {
            Ok(Event::Start(element)) => {
                let local_name = element.local_name();
                let local = local_name.as_ref();
                if local == b"entry" {
                    current = Some(EntryBuilder::default());
                    continue;
                }
                let Some(entry) = current.as_mut() else {
                    continue;
                };
                match local {
                    b"author" => in_author = true,
                    b"id" => start_text(entry, TextTarget::Id),
                    b"title" => start_text(entry, TextTarget::Title),
                    b"summary" => start_text(entry, TextTarget::Summary),
                    b"name" if in_author => start_text(entry, TextTarget::AuthorName),
                    b"published" => start_text(entry, TextTarget::Published),
                    b"updated" => start_text(entry, TextTarget::Updated),
                    b"doi" => start_text(entry, TextTarget::Doi),
                    b"journal_ref" => start_text(entry, TextTarget::JournalReference),
                    b"comment" => start_text(entry, TextTarget::Comment),
                    b"category" => {
                        if let Some(term) = attribute(&reader, &element, b"term")? {
                            entry.categories.push(term);
                        }
                    }
                    b"primary_category" => {
                        entry.primary_category = attribute(&reader, &element, b"term")?;
                    }
                    b"link" => consume_link(&reader, &element, entry)?,
                    _ => {}
                }
            }
            Ok(Event::Empty(element)) => {
                let Some(entry) = current.as_mut() else {
                    continue;
                };
                let local_name = element.local_name();
                match local_name.as_ref() {
                    b"category" => {
                        if let Some(term) = attribute(&reader, &element, b"term")? {
                            entry.categories.push(term);
                        }
                    }
                    b"primary_category" => {
                        entry.primary_category = attribute(&reader, &element, b"term")?;
                    }
                    b"link" => consume_link(&reader, &element, entry)?,
                    _ => {}
                }
            }
            Ok(Event::Text(text)) => {
                if let Some(entry) = current.as_mut()
                    && entry.active_text.is_some()
                {
                    let decoded = text
                        .decode()
                        .map_err(|error| ArxivError::Xml(error.to_string()))?;
                    let unescaped = quick_xml::escape::unescape(&decoded)
                        .map_err(|error| ArxivError::Xml(error.to_string()))?;
                    entry.text.push_str(&unescaped);
                }
            }
            Ok(Event::CData(text)) => {
                if let Some(entry) = current.as_mut()
                    && entry.active_text.is_some()
                {
                    entry.text.push_str(
                        &text
                            .decode()
                            .map_err(|error| ArxivError::Xml(error.to_string()))?,
                    );
                }
            }
            Ok(Event::GeneralRef(reference)) => {
                if let Some(entry) = current.as_mut()
                    && entry.active_text.is_some()
                {
                    let name = reference
                        .decode()
                        .map_err(|error| ArxivError::Xml(error.to_string()))?;
                    entry.text.push_str(&decode_entity_reference(&name)?);
                }
            }
            Ok(Event::End(element)) => {
                let local = element.local_name();
                if local.as_ref() == b"entry" {
                    let entry = current
                        .take()
                        .ok_or_else(|| ArxivError::Xml("unexpected entry end".into()))?;
                    entries.push(finish_entry(entry, fetched_at)?);
                    continue;
                }
                if local.as_ref() == b"author" {
                    in_author = false;
                }
                if let Some(entry) = current.as_mut() {
                    let should_finish = matches!(
                        (local.as_ref(), entry.active_text),
                        (b"id", Some(TextTarget::Id))
                            | (b"title", Some(TextTarget::Title))
                            | (b"summary", Some(TextTarget::Summary))
                            | (b"name", Some(TextTarget::AuthorName))
                            | (b"published", Some(TextTarget::Published))
                            | (b"updated", Some(TextTarget::Updated))
                            | (b"doi", Some(TextTarget::Doi))
                            | (b"journal_ref", Some(TextTarget::JournalReference))
                            | (b"comment", Some(TextTarget::Comment))
                    );
                    if should_finish {
                        finish_text(entry);
                    }
                }
            }
            Ok(Event::Eof) => break,
            Ok(_) => {}
            Err(error) => return Err(ArxivError::Xml(error.to_string())),
        }
    }
    Ok(entries)
}

fn start_text(entry: &mut EntryBuilder, target: TextTarget) {
    entry.active_text = Some(target);
    entry.text.clear();
}

fn finish_text(entry: &mut EntryBuilder) {
    let value = normalize_text(&entry.text);
    match entry.active_text.take() {
        Some(TextTarget::Id) => entry.id = nonempty(value),
        Some(TextTarget::Title) => entry.title = nonempty(value),
        Some(TextTarget::Summary) => entry.summary = nonempty(value),
        Some(TextTarget::AuthorName) => {
            if !value.is_empty() {
                entry.authors.push(value);
            }
        }
        Some(TextTarget::Published) => entry.published = nonempty(value),
        Some(TextTarget::Updated) => entry.updated = nonempty(value),
        Some(TextTarget::Doi) => entry.doi = nonempty(value),
        Some(TextTarget::JournalReference) => entry.journal_reference = nonempty(value),
        Some(TextTarget::Comment) => entry.comment = nonempty(value),
        None => {}
    }
    entry.text.clear();
}

fn consume_link(
    reader: &Reader<&[u8]>,
    element: &BytesStart<'_>,
    entry: &mut EntryBuilder,
) -> Result<(), ArxivError> {
    let href = attribute(reader, element, b"href")?;
    let rel = attribute(reader, element, b"rel")?.unwrap_or_else(|| "alternate".into());
    let media_type = attribute(reader, element, b"type")?;
    match (rel.as_str(), media_type.as_deref(), href) {
        ("alternate", _, Some(href)) if entry.abs_url.is_none() => entry.abs_url = Some(href),
        (_, Some("application/pdf"), Some(href)) => entry.pdf_url = Some(href),
        ("license", _, Some(href)) => entry.license_uri = Some(href),
        _ => {}
    }
    Ok(())
}

fn attribute(
    reader: &Reader<&[u8]>,
    element: &BytesStart<'_>,
    wanted: &[u8],
) -> Result<Option<String>, ArxivError> {
    for result in element.attributes().with_checks(false) {
        let attr = result.map_err(|error| ArxivError::Xml(error.to_string()))?;
        if attr.key.local_name().as_ref() == wanted {
            return attr
                .decoded_and_normalized_value(XmlVersion::Implicit1_0, reader.decoder())
                .map(|value| Some(value.into_owned()))
                .map_err(|error| ArxivError::Xml(error.to_string()));
        }
    }
    Ok(None)
}

fn finish_entry(
    mut entry: EntryBuilder,
    fetched_at: DateTime<Utc>,
) -> Result<PaperMetadata, ArxivError> {
    if entry.active_text.is_some() {
        finish_text(&mut entry);
    }
    let raw_id = required(entry.id, "id")?;
    let normalized = normalize_arxiv_id(&raw_id)?;
    let version = normalized.version.ok_or_else(|| {
        ArxivError::Xml(format!(
            "entry identifier `{raw_id}` does not contain a version"
        ))
    })?;
    let published = parse_timestamp(required(entry.published, "published")?)?;
    let updated = parse_timestamp(required(entry.updated, "updated")?)?;

    let mut seen = HashSet::new();
    entry
        .categories
        .retain(|category| seen.insert(category.clone()));
    let primary_category = entry
        .primary_category
        .or_else(|| entry.categories.first().cloned())
        .ok_or(ArxivError::MissingField("primary_category"))?;
    if seen.insert(primary_category.clone()) {
        entry.categories.insert(0, primary_category.clone());
    }

    let abs_url = entry
        .abs_url
        .map(|value| Url::parse(&value))
        .transpose()?
        .unwrap_or(Url::parse(&format!(
            "https://arxiv.org/abs/{}",
            normalized.as_query_id()
        ))?);
    let pdf_url = entry
        .pdf_url
        .map(|value| Url::parse(&value))
        .transpose()?
        .unwrap_or(Url::parse(&format!(
            "https://arxiv.org/pdf/{}.pdf",
            normalized.as_query_id()
        ))?);
    if !is_matching_arxiv_url(&abs_url, &normalized)
        || !is_matching_arxiv_url(&pdf_url, &normalized)
    {
        return Err(ArxivError::UnsafeUrl);
    }
    let license_uri = entry
        .license_uri
        .map(|value| Url::parse(&value))
        .transpose()?;
    if license_uri
        .as_ref()
        .is_some_and(|url| !matches!(url.scheme(), "http" | "https"))
    {
        return Err(ArxivError::UnsafeUrl);
    }

    Ok(PaperMetadata {
        arxiv_id: ArxivIdentifier {
            base_id: normalized.base_id,
            version,
        },
        title: required(entry.title, "title")?,
        abstract_text: required(entry.summary, "summary")?,
        authors: entry.authors.into_iter().map(Author::from).collect(),
        primary_category,
        categories: entry.categories,
        published_at: published,
        updated_at: updated,
        abs_url,
        pdf_url,
        doi: entry.doi,
        journal_reference: entry.journal_reference,
        comment: entry.comment,
        license_uri,
        metadata_fetched_at: fetched_at,
    })
}

fn is_matching_arxiv_url(url: &Url, expected: &crate::NormalizedArxivId) -> bool {
    if !matches!(url.scheme(), "http" | "https")
        || !url.host_str().is_some_and(|host| {
            matches!(
                host.to_ascii_lowercase().as_str(),
                "arxiv.org" | "www.arxiv.org" | "export.arxiv.org"
            )
        })
    {
        return false;
    }
    normalize_arxiv_id(url.as_str()).is_ok_and(|observed| {
        observed.base_id == expected.base_id
            && observed
                .version
                .is_none_or(|version| Some(version) == expected.version)
    })
}

fn parse_timestamp(value: String) -> Result<DateTime<Utc>, ArxivError> {
    DateTime::parse_from_rfc3339(&value)
        .map(|timestamp| timestamp.with_timezone(&Utc))
        .map_err(|_| ArxivError::InvalidTimestamp(value))
}

fn required(value: Option<String>, field: &'static str) -> Result<String, ArxivError> {
    value.ok_or(ArxivError::MissingField(field))
}

fn normalize_text(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn nonempty(value: String) -> Option<String> {
    (!value.is_empty()).then_some(value)
}

fn decode_entity_reference(name: &str) -> Result<String, ArxivError> {
    let value = match name {
        "amp" => "&".into(),
        "lt" => "<".into(),
        "gt" => ">".into(),
        "apos" => "'".into(),
        "quot" => "\"".into(),
        value if value.starts_with("#x") => u32::from_str_radix(&value[2..], 16)
            .ok()
            .and_then(char::from_u32)
            .map(|character| character.to_string())
            .ok_or_else(|| ArxivError::Xml("invalid numeric entity".into()))?,
        value if value.starts_with('#') => value[1..]
            .parse::<u32>()
            .ok()
            .and_then(char::from_u32)
            .map(|character| character.to_string())
            .ok_or_else(|| ArxivError::Xml("invalid numeric entity".into()))?,
        _ => {
            return Err(ArxivError::Xml(
                "custom XML entities are not supported".into(),
            ));
        }
    };
    Ok(value)
}

#[cfg(test)]
mod tests {
    use chrono::TimeZone;

    use super::*;

    #[test]
    fn parses_namespaced_atom_fixture() {
        let fetched_at = Utc.with_ymd_and_hms(2026, 7, 29, 12, 0, 0).unwrap();
        let records = parse_atom_feed(include_str!("../fixtures/feed.xml"), fetched_at).unwrap();
        assert_eq!(records.len(), 2);

        let first = &records[0];
        assert_eq!(first.arxiv_id.base_id, "2401.12345");
        assert_eq!(first.arxiv_id.version, 2);
        assert_eq!(first.title, "A Paper with XML & Whitespace");
        assert_eq!(first.authors[0].name, "Ada Lovelace");
        assert_eq!(first.primary_category, "cs.AI");
        assert_eq!(first.categories, ["cs.AI", "cs.LG"]);
        assert_eq!(first.doi.as_deref(), Some("10.1000/example"));
        assert_eq!(
            first.license_uri.as_ref().map(Url::as_str),
            Some("https://creativecommons.org/licenses/by/4.0/")
        );
        assert_eq!(first.metadata_fetched_at, fetched_at);

        assert_eq!(records[1].arxiv_id.base_id, "hep-th/9901001");
        assert_eq!(records[1].arxiv_id.version, 3);
    }
}
