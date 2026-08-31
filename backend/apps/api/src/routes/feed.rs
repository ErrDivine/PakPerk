use std::time::Instant;

use axum::{
    http::{
        HeaderMap, HeaderValue,
        header::{CACHE_CONTROL, ETAG, IF_NONE_MATCH},
    },
    response::Response,
};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use domain::{Capabilities, FeedPage, PaperSummary};
use observability::{
    CacheClass, CacheOutcome, OperationClass, OperationOutcome, record_cache_result,
    record_operation,
};
use sha2::{Digest as _, Sha256};

use super::{
    ApiError, AppState, FeedParams, FeedQuery, FulltextPolicy, IntoResponse, Json, Query,
    RequestId, State, StatusCode, apply_summary_policy, cursor_error, internal_db_error,
    valid_category,
};
use crate::middleware::RequestPrincipal;

const FEED_CACHE_CONTROL: &str = "public, max-age=60, stale-while-revalidate=300";
const FEED_ETAG_VERSION: &[u8] = b"pakperk-feed-etag-v2";
const MAX_EMPTY_ETAG_LIST_ELEMENTS: usize = 16;
const MAX_IF_NONE_MATCH_BYTES: usize = 16 * 1024;

#[utoipa::path(
    get,
    path = "/v1/feed",
    security((), ("oidcBearer" = [])),
    params(
        ("category" = Option<String>, Query, description = "arXiv category"),
        ("cursor" = Option<String>, Query, description = "Opaque page cursor"),
        ("limit" = Option<u32>, Query, description = "Page size"),
        ("If-None-Match" = Option<String>, Header, description = "Entity tag returned by an earlier response for the same feed query")
    ),
    responses(
        (
            status = 200,
            description = "Paper summary page",
            body = crate::openapi::FeedPageSchema,
            headers(
                ("ETag" = String, description = "Opaque validator for this feed query and representation"),
                ("Cache-Control" = String, description = "Public chronological-feed cache policy")
            )
        ),
        (
            status = 304,
            description = "Feed representation has not changed; response body is empty",
            headers(
                ("ETag" = String, description = "Current opaque feed validator"),
                ("Cache-Control" = String, description = "Public chronological-feed cache policy")
            )
        ),
        (status = 400, description = "Invalid query", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn feed(
    State(state): State<AppState>,
    principal: RequestPrincipal,
    headers: HeaderMap,
    Query(params): Query<FeedParams>,
) -> Result<Response, ApiError> {
    let request_id = RequestId(principal.request_id);
    validate_feed_category(request_id, params.category.as_deref())?;
    let cursor = params
        .cursor
        .as_deref()
        .map(|cursor| {
            state
                .papers
                .decode_feed_cursor(params.category.as_deref(), cursor)
        })
        .transpose()
        .map_err(|error| cursor_error(request_id, &error))?;
    let limit = params.limit.unwrap_or(20);
    let feed_started = Instant::now();
    let query_started = Instant::now();
    let page_result = state
        .papers
        .feed(&FeedQuery {
            category: params.category.clone(),
            cursor,
            limit,
        })
        .await;
    record_operation(
        OperationClass::DatabaseRead,
        if page_result.is_ok() {
            OperationOutcome::Success
        } else {
            OperationOutcome::RetryableFailure
        },
        query_started.elapsed(),
    );
    let mut page = match page_result {
        Ok(page) => page,
        Err(error) => {
            record_operation(
                OperationClass::Feed,
                OperationOutcome::RetryableFailure,
                feed_started.elapsed(),
            );
            return Err(internal_db_error(request_id, &error));
        }
    };
    if state.fulltext_policy == FulltextPolicy::Strict {
        let paper_ids = page
            .items
            .iter()
            .map(|paper| paper.paper_id)
            .collect::<Vec<_>>();
        let query_started = Instant::now();
        let licenses_result = state.papers.license_uris(&paper_ids).await;
        record_operation(
            OperationClass::DatabaseRead,
            if licenses_result.is_ok() {
                OperationOutcome::Success
            } else {
                OperationOutcome::RetryableFailure
            },
            query_started.elapsed(),
        );
        let licenses = match licenses_result {
            Ok(licenses) => licenses,
            Err(error) => {
                record_operation(
                    OperationClass::Feed,
                    OperationOutcome::RetryableFailure,
                    feed_started.elapsed(),
                );
                return Err(internal_db_error(request_id, &error));
            }
        };
        for paper in &mut page.items {
            apply_summary_policy(
                state.fulltext_policy,
                licenses.get(&paper.paper_id).and_then(Option::as_ref),
                paper,
            );
        }
    }

    let representation = FeedRepresentation {
        category: params.category.as_deref(),
        cursor: params.cursor.as_deref(),
        limit,
        cursor_key_epoch: &state.cursor_key_epoch,
    };
    record_operation(
        OperationClass::Feed,
        OperationOutcome::Success,
        feed_started.elapsed(),
    );
    Ok(feed_response(page, representation, &headers))
}

fn validate_feed_category(request_id: RequestId, category: Option<&str>) -> Result<(), ApiError> {
    if category.is_some_and(|category| !valid_category(category)) {
        return Err(ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_CATEGORY",
            "Category must be an arXiv category such as cs.AI.",
            false,
        ));
    }
    Ok(())
}

#[derive(Debug, Clone, Copy)]
struct FeedRepresentation<'a> {
    category: Option<&'a str>,
    cursor: Option<&'a str>,
    limit: u32,
    cursor_key_epoch: &'a [u8; 32],
}

#[derive(Debug)]
struct FeedEntityTag {
    header: HeaderValue,
    opaque: String,
}

fn feed_response(
    page: FeedPage,
    representation: FeedRepresentation<'_>,
    request_headers: &HeaderMap,
) -> Response {
    let entity_tag = feed_entity_tag(&page, representation);
    if if_none_match_matches(request_headers, &entity_tag.opaque) {
        record_cache_result(CacheClass::FeedEtag, CacheOutcome::Hit);
        let mut response = StatusCode::NOT_MODIFIED.into_response();
        apply_feed_cache_headers(&mut response, &entity_tag.header);
        return response;
    }

    record_cache_result(CacheClass::FeedEtag, CacheOutcome::Miss);
    let mut response = (StatusCode::OK, Json(page)).into_response();
    apply_feed_cache_headers(&mut response, &entity_tag.header);
    response
}

fn apply_feed_cache_headers(response: &mut Response, entity_tag: &HeaderValue) {
    response.headers_mut().insert(ETAG, entity_tag.clone());
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static(FEED_CACHE_CONTROL));
}

/// Builds a weak, opaque semantic validator without serializing the response
/// body a second time. Every feed item field, the complete request variant,
/// next-page presence, and active cursor-key epoch participate in the digest,
/// so content changes and key promotion invalidate cached pagination safely.
fn feed_entity_tag(page: &FeedPage, representation: FeedRepresentation<'_>) -> FeedEntityTag {
    let mut digest = Sha256::new();
    hash_bytes(&mut digest, FEED_ETAG_VERSION);
    hash_optional_str(&mut digest, representation.category);
    hash_optional_str(&mut digest, representation.cursor);
    digest.update(representation.limit.to_be_bytes());
    hash_bytes(&mut digest, representation.cursor_key_epoch);

    // Exhaustive destructuring intentionally makes a future public response
    // field a compile error here until its validator contribution is chosen.
    let FeedPage { items, next_cursor } = page;
    hash_len(&mut digest, items.len());
    for paper in items {
        let PaperSummary {
            paper_id,
            arxiv_id,
            title,
            abstract_text,
            authors,
            primary_category,
            categories,
            published_at,
            updated_at,
            abs_url,
            pdf_url,
            capabilities,
        } = paper;
        digest.update(paper_id.as_bytes());
        hash_str(&mut digest, arxiv_id);
        hash_str(&mut digest, title);
        hash_str(&mut digest, abstract_text);
        hash_len(&mut digest, authors.len());
        for author in authors {
            hash_str(&mut digest, author);
        }
        hash_str(&mut digest, primary_category);
        hash_len(&mut digest, categories.len());
        for category in categories {
            hash_str(&mut digest, category);
        }
        hash_timestamp(&mut digest, published_at);
        hash_timestamp(&mut digest, updated_at);
        hash_str(&mut digest, abs_url.as_str());
        hash_str(&mut digest, pdf_url.as_str());
        let Capabilities {
            metadata,
            introduction,
            chat,
            connections,
            visual_objects,
            terms,
            semantic_facets,
            paper_passport,
        } = *capabilities;
        digest.update([
            u8::from(metadata),
            u8::from(introduction),
            u8::from(chat),
            u8::from(connections),
            u8::from(visual_objects),
            u8::from(terms),
            u8::from(semantic_facets),
            u8::from(paper_passport),
        ]);
    }
    // Cursor ciphertext is intentionally randomized on every issuance. The
    // complete item sequence above already binds the last ordering identity;
    // only the presence of a following page is additionally semantic here.
    digest.update([u8::from(next_cursor.is_some())]);

    let opaque = format!("pp-feed-v2-{}", URL_SAFE_NO_PAD.encode(digest.finalize()));
    let header = HeaderValue::from_str(&format!("W/\"{opaque}\""))
        .expect("a base64url feed entity tag is always a valid HTTP header value");
    FeedEntityTag { header, opaque }
}

fn hash_optional_str(digest: &mut Sha256, value: Option<&str>) {
    match value {
        Some(value) => {
            digest.update([1]);
            hash_str(digest, value);
        }
        None => digest.update([0]),
    }
}

fn hash_str(digest: &mut Sha256, value: &str) {
    hash_bytes(digest, value.as_bytes());
}

fn hash_bytes(digest: &mut Sha256, value: &[u8]) {
    hash_len(digest, value.len());
    digest.update(value);
}

fn hash_len(digest: &mut Sha256, value: usize) {
    let value = u64::try_from(value).expect("feed collection length must fit in u64");
    digest.update(value.to_be_bytes());
}

fn hash_timestamp(digest: &mut Sha256, value: &chrono::DateTime<chrono::Utc>) {
    digest.update(value.timestamp().to_be_bytes());
    digest.update(value.timestamp_subsec_nanos().to_be_bytes());
}

fn if_none_match_matches(headers: &HeaderMap, current_opaque: &str) -> bool {
    let values = headers.get_all(IF_NONE_MATCH);
    let mut combined = Vec::new();
    for value in values {
        let additional = value
            .as_bytes()
            .len()
            .saturating_add(usize::from(!combined.is_empty()));
        if combined.len().saturating_add(additional) > MAX_IF_NONE_MATCH_BYTES {
            return false;
        }
        if !combined.is_empty() {
            combined.push(b',');
        }
        combined.extend_from_slice(value.as_bytes());
    }
    if combined.is_empty() {
        return false;
    }

    let Some(condition) = parse_if_none_match(&combined) else {
        return false;
    };
    match condition {
        IfNoneMatch::Any => true,
        IfNoneMatch::Tags(tags) => tags.iter().any(|tag| tag == current_opaque.as_bytes()),
    }
}

#[derive(Debug, PartialEq, Eq)]
enum IfNoneMatch {
    Any,
    Tags(Vec<Vec<u8>>),
}

/// Parses the RFC 9110 `If-None-Match` wildcard or entity-tag list. Entity tags
/// use weak comparison for GET, so the optional `W/` marker is discarded while
/// the opaque value remains byte-exact. Invalid field syntax is ignored by the
/// caller, making the request unconditional rather than returning a false 304.
fn parse_if_none_match(input: &[u8]) -> Option<IfNoneMatch> {
    let input = trim_ows(input);
    if input == b"*" {
        return Some(IfNoneMatch::Any);
    }
    if input.is_empty() {
        return None;
    }

    let mut index = 0;
    let mut empty_elements = 0;
    let mut expects_element = true;
    let mut tags = Vec::new();
    loop {
        while index < input.len() && matches!(input[index], b' ' | b'\t') {
            index += 1;
        }
        if index == input.len() {
            if expects_element {
                empty_elements += 1;
                if empty_elements > MAX_EMPTY_ETAG_LIST_ELEMENTS {
                    return None;
                }
            }
            break;
        }
        if input[index] == b',' {
            empty_elements += 1;
            if empty_elements > MAX_EMPTY_ETAG_LIST_ELEMENTS {
                return None;
            }
            index += 1;
            expects_element = true;
            continue;
        }
        if input[index..].starts_with(b"W/") {
            index += 2;
        }
        if input.get(index) != Some(&b'\"') {
            return None;
        }
        index += 1;
        let opaque_start = index;
        while let Some(byte) = input.get(index).copied() {
            if byte == b'\"' {
                break;
            }
            if !valid_etag_character(byte) {
                return None;
            }
            index += 1;
        }
        if input.get(index) != Some(&b'\"') {
            return None;
        }
        tags.push(input[opaque_start..index].to_vec());
        expects_element = false;
        index += 1;
        while index < input.len() && matches!(input[index], b' ' | b'\t') {
            index += 1;
        }
        if index < input.len() {
            if input[index] != b',' {
                return None;
            }
            index += 1;
            expects_element = true;
        }
    }

    (!tags.is_empty()).then_some(IfNoneMatch::Tags(tags))
}

const fn valid_etag_character(byte: u8) -> bool {
    byte == 0x21 || (byte >= 0x23 && byte <= 0x7e) || byte >= 0x80
}

fn trim_ows(mut input: &[u8]) -> &[u8] {
    while input
        .first()
        .is_some_and(|byte| matches!(byte, b' ' | b'\t'))
    {
        input = &input[1..];
    }
    while input
        .last()
        .is_some_and(|byte| matches!(byte, b' ' | b'\t'))
    {
        input = &input[..input.len() - 1];
    }
    input
}

#[cfg(test)]
mod tests {
    use axum::{body::to_bytes, http::header::CONTENT_TYPE};
    use chrono::{TimeZone as _, Utc};
    use domain::{Capabilities, PaperSummary};
    use url::Url;
    use uuid::Uuid;

    use super::*;

    const TEST_CURSOR_KEY_EPOCH: [u8; 32] = [0x31; 32];

    fn page() -> FeedPage {
        FeedPage {
            items: vec![PaperSummary {
                paper_id: Uuid::parse_str("0198fa17-3499-7a02-8406-846ab42ba686").unwrap(),
                arxiv_id: "2401.12345v2".to_owned(),
                title: "A production feed validator".to_owned(),
                abstract_text: "Metadata changes must invalidate the page.".to_owned(),
                authors: vec!["Ada Tester".to_owned(), "Grace Reviewer".to_owned()],
                primary_category: "cs.AI".to_owned(),
                categories: vec!["cs.AI".to_owned(), "stat.ML".to_owned()],
                published_at: Utc.with_ymd_and_hms(2026, 7, 29, 12, 13, 14).unwrap(),
                updated_at: Utc.with_ymd_and_hms(2026, 7, 30, 8, 0, 0).unwrap(),
                abs_url: Url::parse("https://arxiv.org/abs/2401.12345v2").unwrap(),
                pdf_url: Url::parse("https://arxiv.org/pdf/2401.12345v2").unwrap(),
                capabilities: Capabilities::metadata_only(),
            }],
            next_cursor: Some("opaque-next-page".to_owned()),
        }
    }

    fn first_page(category: Option<&str>, limit: u32) -> FeedRepresentation<'_> {
        FeedRepresentation {
            category,
            cursor: None,
            limit,
            cursor_key_epoch: &TEST_CURSOR_KEY_EPOCH,
        }
    }

    #[test]
    fn entity_tag_is_stable_opaque_and_separated_by_complete_query() {
        let page = page();
        let first = feed_entity_tag(&page, first_page(None, 30));
        let repeated = feed_entity_tag(&page, first_page(None, 30));
        let category = feed_entity_tag(&page, first_page(Some("cs.AI"), 30));
        let other_category = feed_entity_tag(&page, first_page(Some("stat.ML"), 30));
        let other_limit = feed_entity_tag(&page, first_page(None, 20));
        let cursor_page = feed_entity_tag(
            &page,
            FeedRepresentation {
                category: None,
                cursor: Some("opaque-request-cursor"),
                limit: 30,
                cursor_key_epoch: &TEST_CURSOR_KEY_EPOCH,
            },
        );

        assert_eq!(first.header, repeated.header);
        assert_ne!(first.header, category.header);
        assert_ne!(category.header, other_category.header);
        assert_ne!(first.header, other_limit.header);
        assert_ne!(first.header, cursor_page.header);
        let visible = first.header.to_str().unwrap();
        assert!(!visible.contains("0198fa17"));
        assert!(!visible.contains("2026"));
        assert!(!visible.contains("2401.12345"));
        assert!(visible.starts_with("W/\"pp-feed-v2-"));
    }

    #[test]
    fn semantic_first_page_revisions_change_the_entity_tag() {
        let original = page();
        let original_tag = feed_entity_tag(&original, first_page(None, 30)).header;

        let mut metadata_changed = original.clone();
        metadata_changed.items[0].title.push_str(" revised");
        assert_ne!(
            original_tag,
            feed_entity_tag(&metadata_changed, first_page(None, 30)).header
        );

        let mut capability_changed = original.clone();
        capability_changed.items[0].capabilities.introduction = true;
        assert_ne!(
            original_tag,
            feed_entity_tag(&capability_changed, first_page(None, 30)).header
        );

        let mut reencrypted_boundary = original.clone();
        reencrypted_boundary.next_cursor = Some("fresh-randomized-ciphertext".to_owned());
        assert_eq!(
            original_tag,
            feed_entity_tag(&reencrypted_boundary, first_page(None, 30)).header
        );

        let mut final_page = original.clone();
        final_page.next_cursor = None;
        assert_ne!(
            original_tag,
            feed_entity_tag(&final_page, first_page(None, 30)).header
        );
    }

    #[test]
    fn if_none_match_parses_rfc_lists_wildcards_and_weak_tags() {
        assert_eq!(parse_if_none_match(b" * \t"), Some(IfNoneMatch::Any));
        assert_eq!(
            parse_if_none_match(b"\"old\", W/\"current\", \"tag,with,commas\""),
            Some(IfNoneMatch::Tags(vec![
                b"old".to_vec(),
                b"current".to_vec(),
                b"tag,with,commas".to_vec(),
            ]))
        );
        assert!(parse_if_none_match(b"W/current").is_none());
        assert!(parse_if_none_match(b"*, \"current\"").is_none());
        assert!(parse_if_none_match(b"\"unterminated").is_none());
        assert!(parse_if_none_match(b"\"valid\" garbage").is_none());
        assert_eq!(
            parse_if_none_match(b", \"current\","),
            Some(IfNoneMatch::Tags(vec![b"current".to_vec()]))
        );
        assert_eq!(
            parse_if_none_match(b"\"old\",,\"current\""),
            Some(IfNoneMatch::Tags(vec![
                b"old".to_vec(),
                b"current".to_vec(),
            ]))
        );

        let reasonable_empty_prefix = format!("{}\"current\"", ",".repeat(16));
        assert_eq!(
            parse_if_none_match(reasonable_empty_prefix.as_bytes()),
            Some(IfNoneMatch::Tags(vec![b"current".to_vec()]))
        );
        let excessive_empty_prefix = format!("{}\"current\"", ",".repeat(17));
        assert!(parse_if_none_match(excessive_empty_prefix.as_bytes()).is_none());
    }

    #[test]
    fn if_none_match_combines_multiple_header_field_lines() {
        let mut headers = HeaderMap::new();
        headers.append(IF_NONE_MATCH, HeaderValue::from_static("\"old\""));
        headers.append(
            IF_NONE_MATCH,
            HeaderValue::from_static("W/\"current\", \"newer\""),
        );
        assert!(if_none_match_matches(&headers, "current"));
        assert!(!if_none_match_matches(&headers, "absent"));

        headers.append(IF_NONE_MATCH, HeaderValue::from_static("malformed"));
        assert!(!if_none_match_matches(&headers, "current"));

        let oversized = format!("\"{}\"", "x".repeat(MAX_IF_NONE_MATCH_BYTES));
        let mut oversized_headers = HeaderMap::new();
        oversized_headers.insert(IF_NONE_MATCH, HeaderValue::from_str(&oversized).unwrap());
        assert!(!if_none_match_matches(&oversized_headers, "current"));
    }

    #[tokio::test]
    async fn unchanged_first_page_returns_empty_304_with_cache_headers() {
        let page = page();
        let representation = first_page(None, 30);
        let entity_tag = feed_entity_tag(&page, representation);
        let mut headers = HeaderMap::new();
        headers.insert(IF_NONE_MATCH, entity_tag.header.clone());

        let response = feed_response(page, representation, &headers);
        assert_eq!(response.status(), StatusCode::NOT_MODIFIED);
        assert_eq!(response.headers()[ETAG], entity_tag.header);
        assert_eq!(response.headers()[CACHE_CONTROL], FEED_CACHE_CONTROL);
        assert!(!response.headers().contains_key(CONTENT_TYPE));
        assert!(
            to_bytes(response.into_body(), 1024)
                .await
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn changed_first_page_ignores_stale_validator_and_returns_json() {
        let original = page();
        let representation = first_page(Some("cs.AI"), 30);
        let stale = feed_entity_tag(&original, representation);
        let mut changed = original;
        changed.items[0].abstract_text.push_str(" Updated.");
        let expected_json = serde_json::to_value(&changed).unwrap();
        let mut headers = HeaderMap::new();
        headers.insert(IF_NONE_MATCH, stale.header.clone());

        let response = feed_response(changed, representation, &headers);
        assert_eq!(response.status(), StatusCode::OK);
        assert_ne!(response.headers()[ETAG], stale.header);
        assert_eq!(response.headers()[CACHE_CONTROL], FEED_CACHE_CONTROL);
        assert_eq!(response.headers()[CONTENT_TYPE], "application/json");
        let bytes = to_bytes(response.into_body(), 1024 * 1024).await.unwrap();
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&bytes).unwrap(),
            expected_json
        );
    }

    #[tokio::test]
    async fn promoted_cursor_key_epoch_forces_a_fresh_feed_body() {
        let page = page();
        let prior_representation = first_page(None, 30);
        let stale = feed_entity_tag(&page, prior_representation);
        let promoted_epoch = [0x32; 32];
        let promoted_representation = FeedRepresentation {
            category: None,
            cursor: None,
            limit: 30,
            cursor_key_epoch: &promoted_epoch,
        };
        let mut headers = HeaderMap::new();
        headers.insert(IF_NONE_MATCH, stale.header.clone());

        let response = feed_response(page, promoted_representation, &headers);
        assert_eq!(response.status(), StatusCode::OK);
        assert_ne!(response.headers()[ETAG], stale.header);
        assert_eq!(response.headers()[CONTENT_TYPE], "application/json");
    }

    #[tokio::test]
    async fn matching_cursor_page_validator_returns_an_empty_304() {
        let page = page();
        let representation = FeedRepresentation {
            category: Some("cs.AI"),
            cursor: Some("opaque-request-cursor"),
            limit: 30,
            cursor_key_epoch: &TEST_CURSOR_KEY_EPOCH,
        };
        let entity_tag = feed_entity_tag(&page, representation);
        let mut headers = HeaderMap::new();
        headers.insert(IF_NONE_MATCH, entity_tag.header);

        let response = feed_response(page, representation, &headers);
        assert_eq!(response.status(), StatusCode::NOT_MODIFIED);
        assert!(
            to_bytes(response.into_body(), 1024 * 1024)
                .await
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn wildcard_revalidates_an_existing_first_page() {
        let mut headers = HeaderMap::new();
        headers.insert(IF_NONE_MATCH, HeaderValue::from_static("*"));
        let response = feed_response(page(), first_page(None, 30), &headers);
        assert_eq!(response.status(), StatusCode::NOT_MODIFIED);
        assert_eq!(to_bytes(response.into_body(), 1024).await.unwrap().len(), 0);
    }
}
