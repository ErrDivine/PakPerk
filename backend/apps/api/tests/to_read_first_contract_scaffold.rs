//! Executable, offline contract checks for the To Read First JSON fixtures.
//!
//! The API transport DTOs are intentionally crate-private, so this integration
//! target binds the exact fixtures to the runtime code-first `OpenAPI` document.
//! It then enforces the cross-field queue, discovery, import, and privacy rules
//! that a structural schema cannot express.

use std::collections::BTreeSet;

use chrono::{DateTime, Utc};
use pakperk_api::ApiDoc;
use serde_json::Value;
use url::Url;
use utoipa::OpenApi as _;
use uuid::Uuid;

const FEED_TO_READ: &str = include_str!("fixtures/to_read_first/reading_feed_to_read.json");
const FEED_RECOMMENDATIONS: &str =
    include_str!("fixtures/to_read_first/reading_feed_recommendations.json");
const PAPER_SEARCH_REQUEST: &str = include_str!("fixtures/to_read_first/paper_search_request.json");
const PAPER_SEARCH_RESPONSE: &str =
    include_str!("fixtures/to_read_first/paper_search_response.json");
const AMBIGUOUS_SEARCH_REQUEST: &str =
    include_str!("fixtures/to_read_first/paper_search_ambiguous_request.json");
const AMBIGUOUS_SEARCH_RESPONSE: &str =
    include_str!("fixtures/to_read_first/paper_search_ambiguous_response.json");
const IMPORT_REQUEST: &str = include_str!("fixtures/to_read_first/library_import_url_request.json");
const IMPORT_RESPONSE: &str =
    include_str!("fixtures/to_read_first/library_import_saved_response.json");

#[test]
fn exact_fixtures_match_the_runtime_code_first_openapi_contracts() {
    let document = openapi_document();
    let fixtures = [
        (
            "reading_feed_to_read.json",
            FEED_TO_READ,
            "ReadingFeedEnvelopeSchema",
        ),
        (
            "reading_feed_recommendations.json",
            FEED_RECOMMENDATIONS,
            "ReadingFeedEnvelopeSchema",
        ),
        (
            "paper_search_request.json",
            PAPER_SEARCH_REQUEST,
            "PaperSearchBody",
        ),
        (
            "paper_search_response.json",
            PAPER_SEARCH_RESPONSE,
            "PaperSearchEnvelopeSchema",
        ),
        (
            "paper_search_ambiguous_request.json",
            AMBIGUOUS_SEARCH_REQUEST,
            "PaperSearchBody",
        ),
        (
            "paper_search_ambiguous_response.json",
            AMBIGUOUS_SEARCH_RESPONSE,
            "PaperSearchEnvelopeSchema",
        ),
        (
            "library_import_url_request.json",
            IMPORT_REQUEST,
            "PaperImportBody",
        ),
        (
            "library_import_saved_response.json",
            IMPORT_RESPONSE,
            "PaperImportEnvelopeSchema",
        ),
    ];

    for (name, fixture, component) in fixtures {
        let value = parse_fixture(name, fixture);
        validate_component(&document, component, &value)
            .unwrap_or_else(|error| panic!("{name} drifted from {component}: {error}"));
    }

    let mut search_with_side_effect =
        parse_fixture("paper_search_request.json", PAPER_SEARCH_REQUEST);
    search_with_side_effect["auto_save"] = Value::Bool(true);
    assert!(
        validate_component(&document, "PaperSearchBody", &search_with_side_effect).is_err(),
        "strict search requests must reject side-effect controls"
    );

    let mut import_with_preparation =
        parse_fixture("library_import_url_request.json", IMPORT_REQUEST);
    import_with_preparation["prepare"] = Value::Bool(true);
    assert!(
        validate_component(&document, "PaperImportBody", &import_with_preparation).is_err(),
        "strict imports must reject preparation controls"
    );
}

#[test]
fn feed_fixtures_enforce_mutually_exclusive_queue_and_recommendation_modes() {
    let queue = parse_fixture("reading_feed_to_read.json", FEED_TO_READ);
    let recommendations = parse_fixture("reading_feed_recommendations.json", FEED_RECOMMENDATIONS);

    validate_feed_semantics(&queue).expect("queue fixture must satisfy queue-first arbitration");
    validate_feed_semantics(&recommendations)
        .expect("recommendation fixture must satisfy proven-empty arbitration");

    let mut recommendation_with_queue = recommendations.clone();
    recommendation_with_queue["items"][0]["queue"] = queue["items"][0]["queue"].clone();
    assert!(
        validate_feed_semantics(&recommendation_with_queue).is_err(),
        "a recommendation item cannot also carry queue authority"
    );

    let mut queue_with_recommendation = queue.clone();
    queue_with_recommendation["items"][0]["recommendation"] =
        recommendations["items"][0]["recommendation"].clone();
    assert!(
        validate_feed_semantics(&queue_with_recommendation).is_err(),
        "a queue item cannot also carry recommendation provenance"
    );

    let mut recommendations_without_empty_proof = recommendations;
    recommendations_without_empty_proof["decision"]["queue_proven_empty"] = Value::Bool(false);
    assert!(
        validate_feed_semantics(&recommendations_without_empty_proof).is_err(),
        "recommendations require affirmative empty-queue proof"
    );
}

#[test]
fn title_search_fixture_is_bounded_navigation_without_queue_mutation() {
    let request = parse_fixture("paper_search_request.json", PAPER_SEARCH_REQUEST);
    let response = parse_fixture("paper_search_response.json", PAPER_SEARCH_RESPONSE);
    let query = request["query"].as_str().expect("search query is a string");
    let limit = request["limit"]
        .as_u64()
        .expect("search limit is an integer");

    assert!((3..=300).contains(&query.chars().count()));
    assert!((1..=10).contains(&limit));
    assert_eq!(response["normalized_query"], request["query"]);
    assert_valid_uuid(&response["query_id"], "search response query_id");
    let candidates = response["candidates"]
        .as_array()
        .expect("search candidates are an array");
    assert!(!candidates.is_empty());
    assert!(u64::try_from(candidates.len()).unwrap() <= limit);

    for (index, candidate) in candidates.iter().enumerate() {
        assert_eq!(candidate["match"]["kind"], "title");
        assert_eq!(candidate["match"]["rank"], index + 1);
        assert_canonical_arxiv_url(&candidate["abs_url"]);
        assert_versioned_arxiv_id(
            candidate["arxiv_id"]
                .as_str()
                .expect("candidate arxiv_id is a string"),
        );
        assert!(candidate.get("paper_id").is_none());
        assert!(candidate.get("pdf_url").is_none());
        assert!(candidate.get("capabilities").is_none());
    }

    for forbidden in [
        "operation_id",
        "target_state",
        "save_source_kind",
        "auto_save",
        "prepare",
        "queue",
    ] {
        assert!(
            !contains_key(&request, forbidden) && !contains_key(&response, forbidden),
            "search fixture must remain side-effect free: found {forbidden}"
        );
    }
}

#[test]
fn ambiguous_title_fixture_requires_an_explicit_candidate_selection() {
    let document = openapi_document();
    let request = parse_fixture(
        "paper_search_ambiguous_request.json",
        AMBIGUOUS_SEARCH_REQUEST,
    );
    let response = parse_fixture(
        "paper_search_ambiguous_response.json",
        AMBIGUOUS_SEARCH_RESPONSE,
    );
    validate_component(&document, "PaperSearchBody", &request).unwrap();
    validate_component(&document, "PaperSearchEnvelopeSchema", &response).unwrap();

    assert_eq!(response["normalized_query"], request["query"]);
    let limit = request["limit"].as_u64().unwrap();
    let candidates = response["candidates"].as_array().unwrap();
    assert!(
        candidates.len() > 1,
        "ambiguity fixture must contain multiple plausible candidates"
    );
    assert!(u64::try_from(candidates.len()).unwrap() <= limit);
    let identities = candidates
        .iter()
        .map(|candidate| candidate["arxiv_id"].as_str().unwrap())
        .collect::<BTreeSet<_>>();
    assert_eq!(identities.len(), candidates.len());
    for (index, candidate) in candidates.iter().enumerate() {
        assert_eq!(candidate["match"]["rank"], index + 1);
        assert!(candidate.get("selected").is_none());
        assert!(candidate.get("operation_id").is_none());
        assert!(candidate.get("paper_id").is_none());
    }

    // Selection becomes queue intent only when the client submits the exact
    // candidate identity through the canonical import contract.
    let selected_id = candidates[1]["arxiv_id"].as_str().unwrap();
    let operation_id = Uuid::now_v7();
    let selected_import = serde_json::json!({
        "operation_id": operation_id,
        "source": {"kind": "arxiv_id", "value": selected_id},
        "target_state": "inbox",
        "save_source_kind": "title_search"
    });
    validate_component(&document, "PaperImportBody", &selected_import).unwrap();
    validate_import_semantics(&selected_import).unwrap();
    assert_eq!(selected_import["source"]["value"], selected_id);
}

#[test]
fn import_fixture_binds_explicit_inbox_intent_to_the_idempotent_result() {
    let request = parse_fixture("library_import_url_request.json", IMPORT_REQUEST);
    let response = parse_fixture("library_import_saved_response.json", IMPORT_RESPONSE);

    assert_valid_uuid(&request["operation_id"], "import operation_id");
    assert_eq!(request["source"]["kind"], "arxiv_url");
    assert_eq!(request["target_state"], "inbox");
    assert_eq!(request["save_source_kind"], request["source"]["kind"]);
    assert_canonical_arxiv_url(&request["source"]["value"]);
    assert!(!contains_key(&request, "prepare"));

    assert_eq!(response["result"], "saved");
    assert_eq!(
        response["resolution"]["input_kind"],
        request["source"]["kind"]
    );
    assert_eq!(response["item"]["state"], request["target_state"]);
    assert_eq!(
        response["item"]["save_source_kind"],
        request["save_source_kind"]
    );
    assert_eq!(
        response["item"]["last_operation_id"],
        request["operation_id"]
    );
    assert_eq!(response["sync_revision"], response["item"]["revision"]);
    assert_eq!(response["item"]["paper_id"], response["paper"]["paper_id"]);
    assert_eq!(
        response["resolution"]["canonical_arxiv_id"],
        response["paper"]["arxiv_id"]
    );
    assert_eq!(response["item"]["private_note"], Value::Null);
    assert_eq!(response["item"]["reminder_at"], Value::Null);
    assert!(!response["item"]["removed"].as_bool().unwrap());
    assert_metadata_only_paper(&response["paper"]);

    let mut mismatched_provenance = request;
    mismatched_provenance["save_source_kind"] = Value::String("arxiv_id".to_owned());
    assert!(
        validate_import_semantics(&mismatched_provenance).is_err(),
        "direct import provenance must agree with its input discriminator"
    );
}

#[test]
fn fixtures_contain_only_public_metadata_and_content_free_authority() {
    for (name, fixture) in [
        ("reading_feed_to_read.json", FEED_TO_READ),
        ("reading_feed_recommendations.json", FEED_RECOMMENDATIONS),
        ("paper_search_request.json", PAPER_SEARCH_REQUEST),
        ("paper_search_response.json", PAPER_SEARCH_RESPONSE),
        (
            "paper_search_ambiguous_request.json",
            AMBIGUOUS_SEARCH_REQUEST,
        ),
        (
            "paper_search_ambiguous_response.json",
            AMBIGUOUS_SEARCH_RESPONSE,
        ),
        ("library_import_url_request.json", IMPORT_REQUEST),
        ("library_import_saved_response.json", IMPORT_RESPONSE),
    ] {
        let value = parse_fixture(name, fixture);
        assert_no_private_identity_or_secret(&value, name);
        assert_only_canonical_arxiv_urls(&value, name);
    }

    for feed in [
        parse_fixture("reading_feed_to_read.json", FEED_TO_READ),
        parse_fixture("reading_feed_recommendations.json", FEED_RECOMMENDATIONS),
    ] {
        for item in feed["items"].as_array().unwrap() {
            assert_metadata_only_paper(&item["paper"]);
        }
    }
}

fn validate_feed_semantics(feed: &Value) -> Result<(), String> {
    if feed["decision"]["policy_version"] != "queue_first_v1" {
        return Err("unknown queue policy version".to_owned());
    }
    let revision = feed["decision"]["library_revision"]
        .as_i64()
        .ok_or_else(|| "library_revision is not an integer".to_owned())?;
    if revision < 0 {
        return Err("library_revision is negative".to_owned());
    }
    let active = feed["decision"]["active_to_read_count"]
        .as_u64()
        .ok_or_else(|| "active_to_read_count is not an integer".to_owned())?;
    let proven_empty = feed["decision"]["queue_proven_empty"]
        .as_bool()
        .ok_or_else(|| "queue_proven_empty is not a boolean".to_owned())?;
    let items = feed["items"]
        .as_array()
        .ok_or_else(|| "items is not an array".to_owned())?;
    let batch_pair_matches = feed["batch_id"].is_null() == feed["batch_metadata"].is_null();
    if !batch_pair_matches {
        return Err("batch_id and batch_metadata must appear together".to_owned());
    }
    parse_utc(&feed["server_time"], "feed server_time")?;

    match feed["mode"].as_str() {
        Some("to_read") => {
            if active == 0 || proven_empty {
                return Err("queue mode requires a non-empty active count".to_owned());
            }
            if !feed["batch_id"].is_null() {
                return Err("queue mode cannot expose a recommendation batch".to_owned());
            }
            for item in items {
                let queue = item["queue"]
                    .as_object()
                    .ok_or_else(|| "queue item is missing queue authority".to_owned())?;
                if !matches!(
                    queue.get("state").and_then(Value::as_str),
                    Some("inbox" | "read_next" | "reading")
                ) {
                    return Err("queue item is not in an active state".to_owned());
                }
                if queue["revision"]
                    .as_i64()
                    .is_none_or(|item_revision| item_revision < 0 || item_revision > revision)
                {
                    return Err("queue item revision exceeds the decision fence".to_owned());
                }
                if item["source"] != "to_read" || !item["recommendation"].is_null() {
                    return Err("queue item carries recommendation provenance".to_owned());
                }
                assert_metadata_only_paper_result(&item["paper"])?;
            }
        }
        Some("recommendations") => {
            if active != 0 || !proven_empty {
                return Err("recommendations require proven zero active rows".to_owned());
            }
            if feed["batch_id"].is_null() {
                return Err("persisted recommendation fixture requires batch authority".to_owned());
            }
            for item in items {
                if !item["queue"].is_null() {
                    return Err("recommendation item carries queue authority".to_owned());
                }
                let recommendation = item["recommendation"]
                    .as_object()
                    .ok_or_else(|| "recommendation item lacks provenance".to_owned())?;
                let mode = recommendation["mode"]
                    .as_str()
                    .ok_or_else(|| "recommendation mode is missing".to_owned())?;
                let expected_source = format!("{mode}_v1");
                if item["source"] != expected_source {
                    return Err("recommendation source disagrees with its mode".to_owned());
                }
                if recommendation["reason_codes"]
                    .as_array()
                    .is_none_or(Vec::is_empty)
                {
                    return Err("recommendation has no bounded reason code".to_owned());
                }
                assert_metadata_only_paper_result(&item["paper"])?;
            }
        }
        _ => return Err("feed mode is not closed".to_owned()),
    }
    Ok(())
}

fn validate_import_semantics(request: &Value) -> Result<(), String> {
    let kind = request["source"]["kind"]
        .as_str()
        .ok_or_else(|| "source.kind is missing".to_owned())?;
    if request["target_state"] != "inbox" {
        return Err("imports may target only Inbox".to_owned());
    }
    match request["save_source_kind"].as_str() {
        Some("arxiv_url") if kind != "arxiv_url" => {
            return Err("direct URL provenance disagrees with input kind".to_owned());
        }
        Some("arxiv_id") if kind != "arxiv_id" => {
            return Err("direct identifier provenance disagrees with input kind".to_owned());
        }
        Some(
            "arxiv_url" | "arxiv_id" | "title_search" | "lookup" | "discovery" | "connection"
            | "other",
        ) => {}
        _ => return Err("save_source_kind is outside the closed provenance set".to_owned()),
    }
    if contains_key(request, "prepare") {
        return Err("imports may not request preparation".to_owned());
    }
    Ok(())
}

fn assert_metadata_only_paper(paper: &Value) {
    assert_metadata_only_paper_result(paper).unwrap();
}

fn assert_metadata_only_paper_result(paper: &Value) -> Result<(), String> {
    assert_valid_uuid_result(&paper["paper_id"], "paper.paper_id")?;
    let capabilities = paper["capabilities"]
        .as_object()
        .ok_or_else(|| "paper capabilities are missing".to_owned())?;
    if capabilities.get("metadata") != Some(&Value::Bool(true))
        || ["introduction", "chat", "connections"]
            .iter()
            .any(|key| capabilities.get(*key) != Some(&Value::Bool(false)))
    {
        return Err("fixture advertises a derived/prepared capability".to_owned());
    }
    assert_versioned_arxiv_id_result(
        paper["arxiv_id"]
            .as_str()
            .ok_or_else(|| "paper arxiv_id is missing".to_owned())?,
    )?;
    assert_canonical_arxiv_url_result(&paper["abs_url"])?;
    assert_canonical_arxiv_url_result(&paper["pdf_url"])?;
    parse_utc(&paper["published_at"], "paper published_at")?;
    parse_utc(&paper["updated_at"], "paper updated_at")?;
    Ok(())
}

fn openapi_document() -> Value {
    serde_json::to_value(ApiDoc::openapi()).expect("runtime OpenAPI serializes")
}

fn validate_component(document: &Value, component: &str, value: &Value) -> Result<(), String> {
    let schema = document
        .pointer(&format!("/components/schemas/{component}"))
        .ok_or_else(|| format!("OpenAPI component {component} is missing"))?;
    validate_schema(document, schema, value, component)
}

fn validate_schema(
    document: &Value,
    schema: &Value,
    value: &Value,
    path: &str,
) -> Result<(), String> {
    if let Some(reference) = schema.get("$ref").and_then(Value::as_str) {
        let pointer = reference
            .strip_prefix('#')
            .ok_or_else(|| format!("{path}: external schema reference is not allowed"))?;
        let resolved = document
            .pointer(pointer)
            .ok_or_else(|| format!("{path}: unresolved schema reference {reference}"))?;
        return validate_schema(document, resolved, value, path);
    }

    if let Some(branches) = schema.get("oneOf").and_then(Value::as_array) {
        let matching = branches
            .iter()
            .filter(|branch| validate_schema(document, branch, value, path).is_ok())
            .count();
        return (matching == 1).then_some(()).ok_or_else(|| {
            format!("{path}: expected exactly one oneOf branch, matched {matching}")
        });
    }

    if !schema_type_allows(schema, value) {
        return Err(format!(
            "{path}: value type {} is not allowed by schema type {}",
            json_type(value),
            schema.get("type").unwrap_or(&Value::Null)
        ));
    }

    if value.is_null() {
        return Ok(());
    }

    if let Some(values) = schema.get("enum").and_then(Value::as_array)
        && !values.contains(value)
    {
        return Err(format!("{path}: value {value} is outside the closed enum"));
    }

    match value {
        Value::Object(object) => validate_object(document, schema, object, path),
        Value::Array(items) => validate_array(document, schema, items, path),
        Value::String(text) => validate_string(schema, value, text, path),
        Value::Number(_) => validate_number(schema, value, path),
        Value::Null | Value::Bool(_) => Ok(()),
    }
}

fn validate_object(
    document: &Value,
    schema: &Value,
    object: &serde_json::Map<String, Value>,
    path: &str,
) -> Result<(), String> {
    let properties = schema
        .get("properties")
        .and_then(Value::as_object)
        .ok_or_else(|| format!("{path}: object schema has no properties"))?;
    let mut actual = object.keys().map(String::as_str).collect::<Vec<_>>();
    let mut expected = properties.keys().map(String::as_str).collect::<Vec<_>>();
    actual.sort_unstable();
    expected.sort_unstable();
    if actual != expected {
        return Err(format!(
            "{path}: strict property mismatch; expected {expected:?}, found {actual:?}"
        ));
    }
    if let Some(required) = schema.get("required").and_then(Value::as_array) {
        for key in required.iter().filter_map(Value::as_str) {
            if !object.contains_key(key) {
                return Err(format!("{path}: required property {key} is missing"));
            }
        }
    }
    for (key, property_value) in object {
        validate_schema(
            document,
            &properties[key],
            property_value,
            &format!("{path}.{key}"),
        )?;
    }
    Ok(())
}

fn validate_array(
    document: &Value,
    schema: &Value,
    items: &[Value],
    path: &str,
) -> Result<(), String> {
    if let Some(minimum) = schema.get("minItems").and_then(Value::as_u64)
        && u64::try_from(items.len()).unwrap() < minimum
    {
        return Err(format!("{path}: array is shorter than {minimum}"));
    }
    if let Some(maximum) = schema.get("maxItems").and_then(Value::as_u64)
        && u64::try_from(items.len()).unwrap() > maximum
    {
        return Err(format!("{path}: array is longer than {maximum}"));
    }
    if let Some(item_schema) = schema.get("items") {
        for (index, item) in items.iter().enumerate() {
            validate_schema(document, item_schema, item, &format!("{path}[{index}]"))?;
        }
    }
    Ok(())
}

fn validate_string(schema: &Value, value: &Value, text: &str, path: &str) -> Result<(), String> {
    let length = u64::try_from(text.chars().count()).unwrap();
    if schema
        .get("minLength")
        .and_then(Value::as_u64)
        .is_some_and(|minimum| length < minimum)
    {
        return Err(format!("{path}: string is shorter than the schema minimum"));
    }
    if schema
        .get("maxLength")
        .and_then(Value::as_u64)
        .is_some_and(|maximum| length > maximum)
    {
        return Err(format!("{path}: string is longer than the schema maximum"));
    }
    match schema.get("format").and_then(Value::as_str) {
        Some("uuid") => assert_valid_uuid_result(value, path),
        Some("date-time") => parse_utc(value, path).map(drop),
        _ => Ok(()),
    }
}

fn validate_number(schema: &Value, value: &Value, path: &str) -> Result<(), String> {
    let number = value
        .as_f64()
        .ok_or_else(|| format!("{path}: number cannot be represented"))?;
    if schema
        .get("minimum")
        .and_then(Value::as_f64)
        .is_some_and(|minimum| number < minimum)
    {
        return Err(format!("{path}: number is below the schema minimum"));
    }
    if schema
        .get("maximum")
        .and_then(Value::as_f64)
        .is_some_and(|maximum| number > maximum)
    {
        return Err(format!("{path}: number is above the schema maximum"));
    }
    Ok(())
}

fn schema_type_allows(schema: &Value, value: &Value) -> bool {
    let Some(schema_type) = schema.get("type") else {
        return true;
    };
    match schema_type {
        Value::String(expected) => expected == json_type(value),
        Value::Array(expected) => expected
            .iter()
            .filter_map(Value::as_str)
            .any(|expected| expected == json_type(value)),
        _ => false,
    }
}

fn json_type(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(number) if number.is_i64() || number.is_u64() => "integer",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

fn parse_fixture(name: &str, fixture: &str) -> Value {
    serde_json::from_str(fixture).unwrap_or_else(|error| panic!("{name} is invalid JSON: {error}"))
}

fn assert_valid_uuid(value: &Value, path: &str) {
    assert_valid_uuid_result(value, path).unwrap();
}

fn assert_valid_uuid_result(value: &Value, path: &str) -> Result<(), String> {
    let text = value
        .as_str()
        .ok_or_else(|| format!("{path}: UUID is not a string"))?;
    let uuid = Uuid::parse_str(text).map_err(|error| format!("{path}: invalid UUID: {error}"))?;
    if uuid.is_nil() {
        return Err(format!("{path}: UUID must not be nil"));
    }
    Ok(())
}

fn parse_utc(value: &Value, path: &str) -> Result<DateTime<Utc>, String> {
    value
        .as_str()
        .ok_or_else(|| format!("{path}: timestamp is not a string"))?
        .parse::<DateTime<Utc>>()
        .map_err(|error| format!("{path}: timestamp is not RFC 3339 UTC: {error}"))
}

fn assert_versioned_arxiv_id(value: &str) {
    assert_versioned_arxiv_id_result(value).unwrap();
}

fn assert_versioned_arxiv_id_result(value: &str) -> Result<(), String> {
    let (base, version) = value
        .rsplit_once('v')
        .ok_or_else(|| format!("arXiv identifier is not versioned: {value}"))?;
    if version.is_empty()
        || !version.bytes().all(|byte| byte.is_ascii_digit())
        || base.matches('.').count() != 1
        || !base
            .bytes()
            .all(|byte| byte.is_ascii_digit() || byte == b'.')
    {
        return Err(format!("arXiv identifier is not canonical: {value}"));
    }
    Ok(())
}

fn assert_canonical_arxiv_url(value: &Value) {
    assert_canonical_arxiv_url_result(value).unwrap();
}

fn assert_canonical_arxiv_url_result(value: &Value) -> Result<(), String> {
    let text = value
        .as_str()
        .ok_or_else(|| "arXiv URL is not a string".to_owned())?;
    let url = Url::parse(text).map_err(|error| format!("invalid arXiv URL: {error}"))?;
    if url.scheme() != "https"
        || url.host_str() != Some("arxiv.org")
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || !(url.path().starts_with("/abs/") || url.path().starts_with("/pdf/"))
    {
        return Err(format!(
            "URL is outside the canonical arXiv boundary: {text}"
        ));
    }
    Ok(())
}

fn contains_key(value: &Value, needle: &str) -> bool {
    match value {
        Value::Object(object) => {
            object.contains_key(needle) || object.values().any(|value| contains_key(value, needle))
        }
        Value::Array(array) => array.iter().any(|value| contains_key(value, needle)),
        _ => false,
    }
}

fn assert_no_private_identity_or_secret(value: &Value, fixture: &str) {
    const FORBIDDEN_KEYS: &[&str] = &[
        "user_id",
        "account_id",
        "email",
        "authorization",
        "access_token",
        "refresh_token",
        "id_token",
        "password",
        "secret",
    ];
    for key in FORBIDDEN_KEYS {
        assert!(
            !contains_key(value, key),
            "{fixture} contains forbidden private field {key}"
        );
    }
    if let Some(private_note) = find_key(value, "private_note") {
        assert!(
            private_note.is_null(),
            "{fixture} must not contain private note content"
        );
    }
    walk_strings(value, &mut |text| {
        assert!(
            !text.starts_with("Bearer "),
            "{fixture} contains a bearer token"
        );
        assert!(
            !text.contains("@example."),
            "{fixture} contains an email fixture"
        );
    });
}

fn assert_only_canonical_arxiv_urls(value: &Value, fixture: &str) {
    walk_strings(value, &mut |text| {
        if Url::parse(text).is_ok_and(|url| url.has_host()) {
            assert_canonical_arxiv_url_result(&Value::String(text.to_owned())).unwrap_or_else(
                |error| panic!("{fixture} contains an unapproved external URL: {error}"),
            );
        }
    });
}

fn find_key<'a>(value: &'a Value, needle: &str) -> Option<&'a Value> {
    match value {
        Value::Object(object) => object
            .get(needle)
            .or_else(|| object.values().find_map(|value| find_key(value, needle))),
        Value::Array(array) => array.iter().find_map(|value| find_key(value, needle)),
        _ => None,
    }
}

fn walk_strings(value: &Value, visitor: &mut impl FnMut(&str)) {
    match value {
        Value::String(text) => visitor(text),
        Value::Array(array) => {
            for value in array {
                walk_strings(value, visitor);
            }
        }
        Value::Object(object) => {
            for value in object.values() {
                walk_strings(value, visitor);
            }
        }
        Value::Null | Value::Bool(_) | Value::Number(_) => {}
    }
}
