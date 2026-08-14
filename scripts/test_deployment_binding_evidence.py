#!/usr/bin/env python3
"""Focused regressions for the dark-deployment evidence contract."""

from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
import uuid

from deployment_binding_evidence import (
    EvidenceError,
    build_evidence,
    pod_spec_id,
    read_evidence,
    strict_json,
    validate_evidence,
    write_evidence,
)


SOURCE_REVISION = "0123456789abcdef0123456789abcdef01234567"


def sha(label: str) -> str:
    return "sha256:" + hashlib.sha256(label.encode("ascii")).hexdigest()


def raw_sha(label: str) -> str:
    return hashlib.sha256(label.encode("ascii")).hexdigest()


def canonical(value: object) -> bytes:
    return (
        json.dumps(value, allow_nan=False, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
        + "\n"
    ).encode("ascii")


def compact(value: object) -> str:
    return json.dumps(value, allow_nan=False, ensure_ascii=True, separators=(",", ":"), sort_keys=True)


def fixtures() -> tuple[bytes, bytes, bytes, bytes]:
    promotion = {
        "schema": 1,
        "environment": "production",
        "source_revision": SOURCE_REVISION,
        "scan_handoff": {
            "artifact_id": "88421",
            "artifact_digest": raw_sha("artifact"),
            "manifest_sha256": raw_sha("scan manifest"),
        },
        "helm_values": {
            "image": {
                "repository": "ghcr.io/errdivine/pakperk-backend",
                "digest": sha("backend image"),
            },
            "siteImage": {
                "repository": "ghcr.io/errdivine/pakperk-site",
                "digest": sha("site image"),
            },
        },
    }
    features = {
        "accounts": True,
        "library": True,
        "libraryWrites": True,
        "comments": True,
        "commentCreation": True,
        "accountDeletion": True,
    }
    approvals = {
        "legalReviewId": sha("legal approval"),
        "moderationReadinessId": sha("moderation approval"),
        "accountDeletionE2eId": sha("deletion approval"),
        "restoreDrillId": sha("restore approval"),
        "reviewerFlowId": sha("reviewer approval"),
        "strictContentReviewId": sha("strict-content approval"),
    }
    images = {
        "backend": promotion["helm_values"]["image"],
        "site": promotion["helm_values"]["siteImage"],
        "grobid": {
            "repository": "grobid/grobid",
            "digest": sha("grobid image"),
        },
        "otelCollector": {
            "repository": "ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib",
            "digest": sha("collector image"),
        },
    }
    chart = {"name": "pakperk", "version": "0.2.1", "appVersion": "0.2.0"}
    legal = {
        "documentVersion": "2026-08-01",
        "termsVersion": "2026-08-01",
        "communityGuidelinesVersion": "2026-08-01",
        "fulltext": "strict",
    }
    contract = {
        "schemaVersion": 1,
        "environment": "production",
        "features": features,
        "releaseEvidence": approvals,
        "alertPolicySha256": sha("alert policy"),
        "images": images,
        "chart": chart,
        "legalPolicy": legal,
    }
    binding_sha = sha_from_bytes(compact(contract).encode("ascii"))
    approval_sha = sha_from_bytes(compact(approvals).encode("ascii"))
    config_map = {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": (
                "pakperk-release-evidence-"
                + binding_sha.removeprefix("sha256:")[:12]
            ),
            "namespace": "pakperk-production",
            "labels": {
                "app.kubernetes.io/name": "pakperk",
                "app.kubernetes.io/instance": "pakperk",
                "app.kubernetes.io/component": "release-evidence",
                "app.kubernetes.io/version": chart["appVersion"],
                "helm.sh/chart": f"{chart['name']}-{chart['version']}",
            },
            "annotations": {
                "pakperk.app/release-binding-schema": "1",
                "pakperk.app/release-binding-sha256": binding_sha,
                "pakperk.app/release-evidence-sha256": approval_sha,
            },
        },
        "immutable": True,
        "data": {
            "environment": "production",
            "enabledFeatures.json": compact(features),
            "alertPolicySha256": contract["alertPolicySha256"],
            "imageIdentities.json": compact(images),
            "chartIdentity.json": compact(chart),
            "legalPolicy.json": compact(legal),
            "releaseContract.json": compact(contract),
            **approvals,
        },
    }

    replica_counts = {
        "api": 2,
        "paper-worker": 1,
        "deletion-worker": 1,
        "telemetry-gateway": 2,
        "site": 2,
        "grobid": 1,
        "otel-collector": 1,
    }
    image_keys = {
        "api": "backend",
        "paper-worker": "backend",
        "deletion-worker": "backend",
        "telemetry-gateway": "backend",
        "site": "site",
        "grobid": "grobid",
        "otel-collector": "otelCollector",
    }
    pods = []
    for component, count in replica_counts.items():
        image = images[image_keys[component]]
        exact_image = f"{image['repository']}@{image['digest']}"
        for index in range(count):
            name = f"pakperk-{component}-{index}"
            owner_kind = "DaemonSet" if component == "otel-collector" else "ReplicaSet"
            owner_name = f"pakperk-{component}-controller"
            pod = {
                "apiVersion": "v1",
                "kind": "Pod",
                "metadata": {
                    "name": name,
                    "namespace": "pakperk-production",
                    "uid": str(uuid.uuid5(uuid.NAMESPACE_URL, name)),
                    "ownerReferences": [
                        {
                            "apiVersion": "apps/v1",
                            "kind": owner_kind,
                            "name": owner_name,
                            "uid": str(uuid.uuid5(uuid.NAMESPACE_URL, owner_name)),
                            "controller": True,
                            "blockOwnerDeletion": True,
                        }
                    ],
                    "labels": {
                        "app.kubernetes.io/name": "pakperk",
                        "app.kubernetes.io/instance": "pakperk",
                        "app.kubernetes.io/component": component,
                    },
                },
                "spec": {
                    "containers": [{"name": component, "image": exact_image}],
                },
                "status": {
                    "phase": "Running",
                    "conditions": [{"type": "Ready", "status": "True"}],
                    "containerStatuses": [
                        {
                            "name": component,
                            "ready": True,
                            "restartCount": 0,
                            "imageID": (
                                "docker-pullable://docker.io/" + exact_image
                                if component == "grobid"
                                else f"docker-pullable://{exact_image}"
                            ),
                        }
                    ],
                },
            }
            if component == "api":
                pod["spec"]["initContainers"] = [
                    {"name": "materialize-owner-only-secrets", "image": exact_image}
                ]
                pod["status"]["initContainerStatuses"] = [
                    {
                        "name": "materialize-owner-only-secrets",
                        "imageID": f"containerd://{exact_image}",
                        "state": {"terminated": {"exitCode": 0}},
                    }
                ]
            pods.append(pod)
    pod_list = {"apiVersion": "v1", "kind": "PodList", "items": pods}
    expected_pod_specs = {}
    for pod in pods:
        component = pod["metadata"]["labels"]["app.kubernetes.io/component"]
        expected_pod_specs.setdefault(
            component, pod_spec_id(pod["spec"], component)
        )

    observation = {
        "schema": 1,
        "environment": "production",
        "source_revision": SOURCE_REVISION,
        "captured_at": "2026-08-09T06:00:00Z",
        "release_namespace": "pakperk-production",
        "release_instance": "pakperk",
        "cluster_identity": sha("production cluster"),
        "expected_replicas": replica_counts,
        "expected_pod_specs": expected_pod_specs,
        "controls": {
            "rendered_values_sha256": sha("rendered values"),
            "auth_configuration_sha256": sha("auth configuration"),
            "database_roles_sha256": sha("database roles"),
            "network_policies_sha256": sha("network policies"),
            "retention_configuration_sha256": sha("retention configuration"),
            "secret_rotation_sha256": sha("secret rotation"),
        },
        "ingress": {
            "controller_repository": "registry.k8s.io/ingress-nginx/controller",
            "controller_digest": sha("ingress image"),
            "configuration_sha256": sha("ingress config"),
            "review_reference": sha("ingress review"),
        },
        "staging_smoke": {
            "environment": "staging",
            "source_revision": SOURCE_REVISION,
            "backend_digest": images["backend"]["digest"],
            "site_digest": images["site"]["digest"],
            "checks": {
                "api_readiness": "passed",
                "site_readiness": "passed",
                "public_feed": "passed",
                "telemetry_readiness": "passed",
                "candidate_identity": "passed",
            },
            "reference": sha("staging smoke run"),
        },
        "approval": {
            "role": "platform_owner",
            "reference": sha("platform approval"),
        },
    }
    return canonical(promotion), canonical(config_map), canonical(pod_list), canonical(observation)


def sha_from_bytes(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def rewrite_contract(config_map_bytes: bytes, mutate) -> bytes:
    config_map = json.loads(config_map_bytes)
    contract = json.loads(config_map["data"]["releaseContract.json"])
    mutate(contract)
    config_map["data"]["releaseContract.json"] = compact(contract)
    config_map["data"]["enabledFeatures.json"] = compact(contract["features"])
    config_map["data"]["imageIdentities.json"] = compact(contract["images"])
    config_map["data"]["chartIdentity.json"] = compact(contract["chart"])
    config_map["data"]["legalPolicy.json"] = compact(contract["legalPolicy"])
    config_map["data"]["alertPolicySha256"] = contract["alertPolicySha256"]
    for key, value in contract["releaseEvidence"].items():
        config_map["data"][key] = value
    binding_sha = sha_from_bytes(compact(contract).encode("ascii"))
    approval_sha = sha_from_bytes(
        compact(contract["releaseEvidence"]).encode("ascii")
    )
    config_map["metadata"]["name"] = (
        "pakperk-release-evidence-"
        + binding_sha.removeprefix("sha256:")[:12]
    )
    config_map["metadata"]["annotations"][
        "pakperk.app/release-binding-sha256"
    ] = binding_sha
    config_map["metadata"]["annotations"][
        "pakperk.app/release-evidence-sha256"
    ] = approval_sha
    return canonical(config_map)


class DeploymentBindingEvidenceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.directory = Path(self.temporary_directory.name)

    def write_fixture(self, name: str, data: bytes) -> Path:
        path = self.directory / name
        path.write_bytes(data)
        path.chmod(0o600)
        return path

    def test_builds_closed_self_addressed_sanitized_evidence(self) -> None:
        promotion, config_map, pods, observation = fixtures()
        evidence = build_evidence(promotion, config_map, pods, observation)
        validated = validate_evidence(evidence)
        encoded = json.dumps(validated, sort_keys=True)
        self.assertRegex(
            validated["content_id"],
            r"^deployment-binding-v1:sha256:[0-9a-f]{64}$",
        )
        self.assertEqual(len(validated["workloads"]), 7)
        self.assertEqual(
            {item["component"]: item["replicas"] for item in validated["workloads"]}["api"],
            2,
        )
        for excluded in (
            "pakperk-production",
            "pakperk-api-0",
            "operator_email",
            "kubeconfig",
            "Bearer ",
        ):
            self.assertNotIn(excluded, encoded)

    def test_release_binding_and_runtime_image_mismatches_fail_closed(self) -> None:
        promotion, config_map, pods, observation = fixtures()
        bad_config = json.loads(config_map)
        bad_config["metadata"]["annotations"]["pakperk.app/release-binding-sha256"] = sha("wrong binding")
        with self.assertRaisesRegex(EvidenceError, "binding annotation"):
            build_evidence(promotion, canonical(bad_config), pods, observation)

        bad_pods = json.loads(pods)
        bad_pods["items"][0]["status"]["containerStatuses"][0]["imageID"] = (
            "docker-pullable://ghcr.io/errdivine/pakperk-backend@" + sha("other image")
        )
        with self.assertRaisesRegex(EvidenceError, "runtime container image ID"):
            build_evidence(promotion, config_map, canonical(bad_pods), observation)

        changed_command = json.loads(pods)
        changed_command["items"][0]["spec"]["containers"][0]["command"] = [
            "sleep",
            "infinity",
        ]
        with self.assertRaisesRegex(EvidenceError, "Pod spec"):
            build_evidence(
                promotion,
                config_map,
                canonical(changed_command),
                observation,
            )

    def test_unready_missing_and_unknown_release_pods_fail_closed(self) -> None:
        promotion, config_map, pods, observation = fixtures()
        unready = json.loads(pods)
        unready["items"][0]["status"]["conditions"][0]["status"] = "False"
        with self.assertRaisesRegex(EvidenceError, "not Ready"):
            build_evidence(promotion, config_map, canonical(unready), observation)

        missing = json.loads(pods)
        missing["items"] = missing["items"][1:]
        with self.assertRaisesRegex(EvidenceError, "replica count"):
            build_evidence(promotion, config_map, canonical(missing), observation)

        unknown = json.loads(pods)
        unknown["items"][0]["metadata"]["labels"]["app.kubernetes.io/component"] = "mystery"
        with self.assertRaisesRegex(EvidenceError, "unknown component"):
            build_evidence(promotion, config_map, canonical(unknown), observation)

        ownerless = json.loads(pods)
        del ownerless["items"][0]["metadata"]["ownerReferences"]
        with self.assertRaisesRegex(EvidenceError, "owner references"):
            build_evidence(
                promotion, config_map, canonical(ownerless), observation
            )

        split_rollout = json.loads(pods)
        split_rollout["items"][1]["metadata"]["ownerReferences"][0]["uid"] = str(
            uuid.uuid5(uuid.NAMESPACE_URL, "other-api-replicaset")
        )
        with self.assertRaisesRegex(EvidenceError, "settled controller"):
            build_evidence(
                promotion, config_map, canonical(split_rollout), observation
            )

        terminating = json.loads(pods)
        terminating["items"][0]["metadata"]["deletionTimestamp"] = (
            "2026-08-09T06:01:00Z"
        )
        with self.assertRaisesRegex(EvidenceError, "terminating"):
            build_evidence(
                promotion, config_map, canonical(terminating), observation
            )

        unsettled_job = json.loads(pods)
        job = copy.deepcopy(unsettled_job["items"][0])
        job["metadata"]["name"] = "pakperk-migration-bogus"
        job["metadata"]["uid"] = str(
            uuid.uuid5(uuid.NAMESPACE_URL, "pakperk-migration-bogus")
        )
        job["metadata"]["labels"]["app.kubernetes.io/component"] = "migration"
        job["status"]["phase"] = "Bogus"
        unsettled_job["items"].append(job)
        with self.assertRaisesRegex(EvidenceError, "not settled"):
            build_evidence(
                promotion,
                config_map,
                canonical(unsettled_job),
                observation,
            )

    def test_noncanonical_or_mismatched_source_inputs_fail_closed(self) -> None:
        promotion, config_map, pods, observation = fixtures()
        noncanonical = json.dumps(json.loads(promotion), indent=2).encode("ascii")
        with self.assertRaisesRegex(EvidenceError, "not canonical"):
            build_evidence(noncanonical, config_map, pods, observation)

        mismatch = json.loads(observation)
        mismatch["source_revision"] = "fedcba9876543210fedcba9876543210fedcba98"
        with self.assertRaisesRegex(EvidenceError, "source revision"):
            build_evidence(promotion, config_map, pods, canonical(mismatch))
        for hostile in (b"1" * 5000, b"[" * 5000 + b"]" * 5000):
            with self.subTest(size=len(hostile)), self.assertRaises(EvidenceError):
                strict_json(hostile)

    def test_invalid_production_feature_dependencies_fail_closed(self) -> None:
        promotion, config_map, pods, observation = fixtures()

        def make_deletion_without_account(contract) -> None:
            contract["features"].update(
                {
                    "accounts": False,
                    "library": False,
                    "libraryWrites": False,
                    "comments": False,
                    "commentCreation": False,
                    "accountDeletion": True,
                }
            )

        invalid = rewrite_contract(config_map, make_deletion_without_account)
        with self.assertRaisesRegex(EvidenceError, "feature dependencies"):
            build_evidence(promotion, invalid, pods, observation)
        wrong_chart = rewrite_contract(
            config_map,
            lambda contract: contract["chart"].update({"name": "other"}),
        )
        with self.assertRaisesRegex(EvidenceError, "not Pakperk"):
            build_evidence(promotion, wrong_chart, pods, observation)

    def test_daemonset_target_node_affinity_is_normalized_exactly(self) -> None:
        base = {
            "containers": [{"name": "otel-collector", "image": "example/image"}],
            "tolerations": [{"key": "node.kubernetes.io/not-ready"}],
        }

        def for_node(name: str) -> dict:
            result = copy.deepcopy(base)
            result["nodeName"] = name
            result["affinity"] = {
                "nodeAffinity": {
                    "requiredDuringSchedulingIgnoredDuringExecution": {
                        "nodeSelectorTerms": [
                            {
                                "matchFields": [
                                    {
                                        "key": "metadata.name",
                                        "operator": "In",
                                        "values": [name],
                                    }
                                ]
                            }
                        ]
                    }
                }
            }
            return result

        self.assertEqual(
            pod_spec_id(for_node("worker-a"), "otel-collector"),
            pod_spec_id(for_node("worker-b"), "otel-collector"),
        )
        malformed = for_node("worker-a")
        malformed["affinity"]["nodeAffinity"][
            "requiredDuringSchedulingIgnoredDuringExecution"
        ]["nodeSelectorTerms"][0]["matchFields"][0]["operator"] = "Exists"
        with self.assertRaisesRegex(EvidenceError, "target-node affinity"):
            pod_spec_id(malformed, "otel-collector")
        mismatched = for_node("worker-a")
        mismatched["affinity"]["nodeAffinity"][
            "requiredDuringSchedulingIgnoredDuringExecution"
        ]["nodeSelectorTerms"][0]["matchFields"][0]["values"] = ["worker-b"]
        with self.assertRaisesRegex(EvidenceError, "target-node affinity"):
            pod_spec_id(mismatched, "otel-collector")

    def test_failed_smoke_placeholder_and_tampering_fail_closed(self) -> None:
        promotion, config_map, pods, observation = fixtures()
        failed = json.loads(observation)
        failed["staging_smoke"]["checks"]["public_feed"] = "failed"
        with self.assertRaisesRegex(EvidenceError, "smoke check"):
            build_evidence(promotion, config_map, pods, canonical(failed))

        placeholder = json.loads(observation)
        placeholder["approval"]["reference"] = "sha256:" + "a" * 64
        with self.assertRaisesRegex(EvidenceError, "placeholder"):
            build_evidence(promotion, config_map, pods, canonical(placeholder))

        evidence = build_evidence(promotion, config_map, pods, observation)
        extra = copy.deepcopy(evidence)
        extra["operator"] = "somebody"
        with self.assertRaisesRegex(EvidenceError, "closed key set"):
            validate_evidence(extra)
        tampered = copy.deepcopy(evidence)
        tampered["workloads"][0]["replicas"] = 1
        with self.assertRaises(EvidenceError):
            validate_evidence(tampered)

    def test_private_no_overwrite_round_trip_and_symlink_rejection(self) -> None:
        promotion, config_map, pods, observation = fixtures()
        evidence = build_evidence(promotion, config_map, pods, observation)
        output = self.directory / "evidence.json"
        write_evidence(output, evidence)
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
        self.assertEqual(read_evidence(output), evidence)
        with self.assertRaises(EvidenceError):
            write_evidence(output, evidence)
        link = self.directory / "evidence-link.json"
        link.symlink_to(output)
        with self.assertRaises(EvidenceError):
            read_evidence(link)

    def test_cli_build_verify_and_validate(self) -> None:
        promotion, config_map, pods, observation = fixtures()
        pod_list = json.loads(pods)
        paths = {
            "promotion": self.write_fixture("promotion.json", promotion),
            "config": self.write_fixture("config-map.json", config_map),
            "pods": self.write_fixture("pods.json", pods),
            "observation": self.write_fixture("observation.json", observation),
            "pod": self.write_fixture("pod.json", canonical(pod_list["items"][0])),
        }
        evidence_path = self.directory / "evidence.json"
        script = Path(__file__).with_name("deployment_binding_evidence.py")
        base = [
            sys.executable,
            str(script),
            "--promotion-handoff",
            str(paths["promotion"]),
            "--release-config-map",
            str(paths["config"]),
            "--pods",
            str(paths["pods"]),
            "--observation",
            str(paths["observation"]),
        ]
        built = subprocess.run(
            [base[0], base[1], "build", *base[2:], "--output", str(evidence_path)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(built.returncode, 0, built.stderr)
        verified = subprocess.run(
            [base[0], base[1], "verify", *base[2:], "--evidence", str(evidence_path)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(verified.returncode, 0, verified.stderr)
        validated = subprocess.run(
            [sys.executable, str(script), "validate", "--evidence", str(evidence_path)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(validated.returncode, 0, validated.stderr)
        self.assertEqual(built.stdout, verified.stdout)
        self.assertEqual(built.stdout, validated.stdout)
        pod_id = subprocess.run(
            [
                sys.executable,
                str(script),
                "pod-spec-id",
                "--component",
                "api",
                "--pod",
                str(paths["pod"]),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(pod_id.returncode, 0, pod_id.stderr)
        self.assertEqual(
            pod_id.stdout.strip(),
            json.loads(observation)["expected_pod_specs"]["api"],
        )


if __name__ == "__main__":
    unittest.main()
