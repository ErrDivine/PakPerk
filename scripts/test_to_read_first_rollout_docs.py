#!/usr/bin/env python3
"""Contract checks for current queue-first discovery source runbooks."""

from __future__ import annotations

import re
from pathlib import Path

import operational_gate_evidence as evidence


ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def section(document: str, heading: str) -> str:
    marker = f"## {heading}\n"
    start = document.index(marker) + len(marker)
    end = document.find("\n## ", start)
    return document[start:] if end == -1 else document[start:end]


def assert_in_order(document: str, values: list[str]) -> None:
    positions = [document.index(value) for value in values]
    assert positions == sorted(positions), (values, positions)


def markdown_anchors(document: str) -> set[str]:
    anchors: set[str] = set()
    for heading in re.findall(r"^#{1,6}\s+(.+?)\s*$", document, flags=re.MULTILINE):
        without_markup = heading.replace("`", "")
        anchor = re.sub(r"[^\w\- ]", "", without_markup.lower())
        anchors.add(re.sub(r" +", "-", anchor))
    return anchors


def assert_local_links(relative: str) -> None:
    source = ROOT / relative
    document = source.read_text(encoding="utf-8")
    for raw_target in re.findall(r"\[[^]]*\]\(([^)]+)\)", document):
        target = raw_target.strip("<>")
        if target.startswith(("http://", "https://", "mailto:")):
            continue
        path_text, _, anchor = target.partition("#")
        target_path = source if not path_text else (source.parent / path_text).resolve()
        assert target_path.exists(), f"{relative}: missing link target {target}"
        if anchor:
            assert (
                target_path.is_file()
            ), f"{relative}: directory link has anchor {target}"
            target_document = target_path.read_text(encoding="utf-8")
            assert anchor in markdown_anchors(
                target_document
            ), f"{relative}: missing anchor {target}"


def main() -> int:
    release = read("docs/runbooks/release.md")
    normalized_release = " ".join(release.split())
    operational = " ".join(section(release, "Operational gate evidence bundle").split())
    for required in (
        "all 30 release switches reconciled",
        "all 39 required dependency edges rejected",
        "remains schema/domain v1",
        "schema 18 to 24",
        "new 18-to-24 subject",
        "30-switch/39-edge contract",
        "schema-24 private-data/restore checks",
    ):
        assert required in operational, required

    rollout = section(release, "Queue-first discovery staged enablement")
    normalized_rollout = " ".join(rollout.split())
    assert "preserves the Plan 02 schema 11-to-18 enablement sequence" in normalized_rollout
    assert "historical prerequisite evidence" in normalized_rollout
    assert_in_order(
        rollout,
        [
            "`PAPER_RESOLUTION_ENABLED`",
            "`PAPER_TITLE_SEARCH_ENABLED`",
            "`READING_FEED_ENABLED`",
            "`LIBRARY_V2_ENABLED`",
            "`RESEARCH_PROFILES_ENABLED`",
            "`SEARCH_LOOKUP_ENABLED`",
            "`SEARCH_EXPLORE_ENABLED`",
            "`SAVED_QUERIES_ENABLED`",
            "`RECOMMENDATION_EVENTS_ENABLED`",
            "`RECOMMENDATIONS_ENABLED`",
            "`READING_BRIEFS_ENABLED`",
            "`SUBSCRIPTIONS_ENABLED`",
            "`NOTIFICATIONS_ENABLED`",
        ],
    )
    assert "`LIBRARY_IMPORT_WRITES_ENABLED` independently" in normalized_rollout
    assert "schema 11-to-18" in normalized_rollout
    assert "all 30 release switches" in normalized_rollout
    assert "all 39 required dependency" in normalized_rollout
    assert "decision.policy_version=queue_first_v1" in normalized_rollout
    assert "`TO_READ_FIRST_ENFORCEMENT_ENABLED` only after" in normalized_rollout
    assert "suggestions" in normalized_rollout
    assert "not-relevant and dismissed are hard exclusions" in normalized_rollout
    assert "Following uses explicit groups only" in normalized_rollout
    assert "offline evaluation corpus/result digest" in normalized_rollout
    assert "queue-leakage target zero" in normalized_rollout
    assert (
        "Brief progress or completion must neither change nor prove queue emptiness"
        in normalized_rollout
    )
    assert "no raw search query or title" in normalized_rollout
    assert "Repository tests" in normalized_rollout
    assert "none substitutes" in normalized_rollout
    for required in (
        "validate-old-client-policy",
        "minimum_supported_version",
        "disable_legacy_account_library",
        "advisory_until_adoption_threshold",
        "never chooses an adoption threshold",
        "strict enforcement flag is false",
    ):
        assert required in normalized_release, required

    rollback = section(release, "Rollback")
    normalized_rollback = " ".join(rollback.split())
    assert_in_order(
        rollback,
        [
            "`TO_READ_FIRST_ENFORCEMENT_ENABLED` first",
            "`NOTIFICATIONS_ENABLED`",
            "`SUBSCRIPTIONS_ENABLED`",
            "`READING_FEED_ENABLED`",
            "`SAVED_QUERIES_ENABLED`",
            "`SEARCH_EXPLORE_ENABLED`",
            "`SEARCH_LOOKUP_ENABLED`",
            "`PAPER_TITLE_SEARCH_ENABLED`",
            "`PAPER_RESOLUTION_ENABLED`",
        ],
    )
    assert "Keep additive schema 24 in place" in normalized_rollback
    assert (
        "never restore schema 18 merely to disable a Plan 03 capability"
        in normalized_rollback
    )
    assert (
        "historical Plan 02 rule likewise never allowed a downgrade"
        in normalized_rollback
    )

    incident = read("docs/runbooks/incident-response.md")
    containment = section(incident, "Declare and contain")
    assert_in_order(
        containment,
        [
            "`TO_READ_FIRST_ENFORCEMENT_ENABLED` first",
            "`NOTIFICATIONS_ENABLED`",
            "`SUBSCRIPTIONS_ENABLED`",
            "`READING_BRIEFS_ENABLED`",
            "`RECOMMENDATIONS_ENABLED`",
            "`READING_FEED_ENABLED`",
        ],
    )
    recovery = " ".join(section(incident, "Recovery and closure").split())
    assert "Keep schema 24 in place for the current candidate" in recovery
    assert "Keep schema 18 in place" in recovery
    assert "historical Plan 02 rule" in recovery
    assert "notifications; and enforcement only after compatible-client" in recovery

    deployment = " ".join(section(release, "Expand/contract deployment").split())
    assert "all 30 switch results" in deployment
    assert "exact 39-edge dependency contract" in deployment

    completion = " ".join(read("docs/production-v0.0-completion-audit.md").split())
    assert "all 30 feature-switch states" in completion
    assert "all 39 required dependency edges" in completion
    assert (
        "schema-10-to-11, schema-11-to-16, schema-11-to-17, six-switch, eleven-switch, or 21-switch evidence"
        in completion
    )

    observability = " ".join(read("docs/runbooks/observability.md").split())
    for required in (
        "reading-feed-authority-unavailable",
        "authenticated reading feed could not prove queue authority",
        "no raw search query or paper title",
        "bearer or refresh token",
        "account/paper/batch/event identifier",
        "reading-feed/search cursor",
        "saved-query/subscription key",
        "notification payload",
        "recommendation-source invocation while active (target zero)",
        "topic/author concentration",
        "Library sync conflict/outbox age",
        "retention-cleanup outcomes",
        "pakperk.operation.count",
        "reading_feed.request",
        "reading_feed.queue_snapshot",
        "reading_feed.queue_page",
        "reading_feed.recommendation_eligibility",
        "reading_feed.recommendation_page",
        "paper_search.request",
        "paper_import.resolve",
        "paper_import.library_save",
        "lookup|suggestions|explore",
        "success|no_result|pending|deferred|rejected|retryable_failure|terminal_failure",
        "pakperk.notification.work.items",
        "pakperk.recommendation.generation.count",
        "pakperk.recommendation.generation.duration",
        "completed|superseded|retrying|failed|unavailable|idle",
        "pakperk.retention.removed",
        "recommendation-generation-job",
        "same database statement and snapshot",
        "recommendation_generation",
        "no job, batch, account, paper, or revision data",
    ):
        assert required in observability, required

    backup = read("docs/runbooks/backup-restore.md")
    assert "## Migrations 12–18 release rehearsal" in backup
    assert "PAKPERK_RESTORE_DRILL_EXPECTED_MIGRATION=18" in backup
    assert "## Migrations 19–24 current release rehearsal" in backup
    assert "PAKPERK_RESTORE_DRILL_EXPECTED_MIGRATION=24" in backup
    assert "provider-backed isolated" in backup

    developer = read("docs/developer-guide.md")
    local = " ".join(section(developer, "Feature flags").split())
    for required in ("env_file", "`.env`", "run the API on the host"):
        assert required in local, required

    boundaries = read("docs/deployment-boundaries.md")
    current_migration = " ".join(
        section(boundaries, "Current migration boundary").split()
    )
    assert "starts at schema 18 and applies migrations 19–24" in current_migration
    assert "apply the reviewed migration image to schema 24 exactly once" in current_migration
    current_boundaries = section(boundaries, "Current default-off server controls")
    deep_reader_rollout = read("docs/runbooks/deep-reader-rollout.md")
    for feature in evidence.RELEASE_FEATURE_SWITCHES:
        assert (
            feature in release or feature in deep_reader_rollout
        ), f"release runbooks omit {feature}"
        assert feature in current_boundaries, f"deployment boundary omits {feature}"
    assert len(evidence.RELEASE_FEATURE_SWITCHES) == 30
    assert evidence.RELEASE_FEATURE_DEPENDENCY_EDGE_COUNT == 39

    discovery = " ".join(read("docs/discovery-and-library.md").split())
    for required in (
        "feedback_revision",
        "/v1/search/suggestions",
        "at most eight",
        "not-systematic disclaimer",
        "not affiliated with or endorsed by arXiv",
        "not-relevant and dismissed items are hard exclusions",
        "Following uses explicit interests only",
        "Reset All deletes raw feedback",
        "generation jobs older than 30 days",
        "brief progress/completion neither mutates nor proves queue emptiness",
        "executable 18-case queue-policy matrix",
        "production latency/cost",
        "schema 18",
    ):
        assert required in discovery, required

    for source in (
        "docs/deployment-boundaries.md",
        "docs/discovery-and-library.md",
        "docs/reading-feed.md",
        "docs/paper-import.md",
        "docs/developer-guide.md",
        "docs/runbooks/release.md",
        "docs/runbooks/observability.md",
        "docs/runbooks/backup-restore.md",
        "docs/runbooks/incident-response.md",
        "docs/runbooks/deep-reader-rollout.md",
        "docs/runbooks/account-deletion.md",
        "docs/legal/privacy.md",
    ):
        assert_local_links(source)

    print("To Read First rollout documentation contract passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
