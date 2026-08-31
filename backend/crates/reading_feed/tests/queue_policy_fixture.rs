use std::collections::BTreeSet;

use serde::Deserialize;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Fixture {
    schema_version: u32,
    invariant: String,
    active_states: BTreeSet<String>,
    inactive_states: BTreeSet<String>,
    cases: Vec<Case>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
#[allow(clippy::struct_excessive_bools)]
struct Case {
    name: String,
    active_count: u64,
    pending_intents: u64,
    authority_known: bool,
    revision_current: bool,
    account_scope_current: bool,
    recommendations_allowed: bool,
    expected_surface: Surface,
    recommendation_source_invocations: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Surface {
    Queue,
    Recommendations,
    Unavailable,
}

#[test]
fn plan_02_queue_policy_fixture_is_complete_and_fail_closed() {
    let fixture: Fixture =
        serde_json::from_str(include_str!("fixtures/queue_policy_v2.json")).unwrap();

    assert_eq!(fixture.schema_version, 3);
    assert_eq!(
        fixture.invariant,
        "recommendations require a server-proven empty active set at the current library revision"
    );
    assert_eq!(
        fixture.active_states,
        BTreeSet::from([
            "inbox".to_owned(),
            "read_next".to_owned(),
            "reading".to_owned(),
        ])
    );
    assert_eq!(
        fixture.inactive_states,
        BTreeSet::from(["archived".to_owned(), "reviewed".to_owned()])
    );

    let expected_cases = BTreeSet::from([
        "empty_current",
        "inbox_active",
        "read_next_active",
        "reading_active",
        "reviewed_only",
        "archived_only",
        "many_active",
        "pending_save_before_ack",
        "final_item_remove_before_ack",
        "final_item_remove_after_ack",
        "cross_device_revision_between_pages",
        "account_switch_stale_response",
        "offline_empty_local_cache",
        "sync_reset",
        "unresolved_import_draft",
        "late_recommendation_batch_after_save",
        "brief_exhausted_while_active_remain",
        "generation_skipped_while_queue_active",
    ]);
    assert_eq!(
        fixture
            .cases
            .iter()
            .map(|case| case.name.as_str())
            .collect::<BTreeSet<_>>(),
        expected_cases
    );

    for case in fixture.cases {
        let may_show_recommendations = case.authority_known
            && case.revision_current
            && case.account_scope_current
            && case.active_count == 0
            && case.pending_intents == 0;
        assert_eq!(
            case.recommendations_allowed, may_show_recommendations,
            "{} diverges from the queue-first invariant",
            case.name
        );

        if may_show_recommendations {
            assert_eq!(
                case.expected_surface,
                Surface::Recommendations,
                "{}",
                case.name
            );
        } else {
            assert_ne!(
                case.expected_surface,
                Surface::Recommendations,
                "{}",
                case.name
            );
            assert_eq!(
                case.recommendation_source_invocations, 0,
                "{} invoked recommendations before eligibility",
                case.name
            );
        }
        if case.active_count > 0 || case.pending_intents > 0 {
            assert_eq!(case.expected_surface, Surface::Queue, "{}", case.name);
        }
    }
}
