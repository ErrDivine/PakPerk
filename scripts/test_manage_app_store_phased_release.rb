#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "manage_app_store_phased_release"

class AppStorePhasedReleaseTest < Minitest::Test
  BUNDLE_ID = "app.pakperk.pakperk"
  TARGET_VERSION = "0.2.0"
  PREVIOUS_VERSION = "0.1.0"
  BUILD_NUMBER = "42"
  IPA_SHA256 = "a" * 64
  IPA_SIZE = 12_345

  def fixture(
    state: "ACTIVE",
    previous_state: "READY_FOR_DISTRIBUTION",
    target_state: "PREPARE_FOR_SUBMISSION",
    previous_count: 1,
    post_patch_state: nil,
    returned_bundle_id: BUNDLE_ID,
    returned_app_id: "app-1",
    returned_build_id: "build-42",
    returned_build_type: "builds",
    returned_pre_release_version_id: "pre-1",
    returned_pre_release_relationship_type: "preReleaseVersions",
    returned_pre_release_platform: "IOS",
    returned_target_version: TARGET_VERSION,
    returned_target_platform: "IOS",
    returned_build_upload_count: 1,
    returned_build_upload_state: "COMPLETE",
    returned_upload_build_id: nil,
    returned_asset_file_id: "upload-file-1",
    returned_asset_delivery_state: "COMPLETE",
    returned_asset_type: "ASSET",
    returned_asset_size: IPA_SIZE,
    returned_asset_checksum_algorithm: "SHA_256",
    returned_asset_checksum: IPA_SHA256,
    returned_asset_uti: "com.apple.ipa"
  )
    returned_upload_build_id ||= returned_build_id
    calls = []
    current_state = state
    patch_seen = false
    transport = lambda do |method, uri, _headers, payload|
      calls << [method, uri.request_uri, payload]
      document = case uri.path
                 when "/v1/apps"
                   {
                     "data" => [{
                       "id" => returned_app_id,
                       "attributes" => { "bundleId" => returned_bundle_id }
                     }]
                   }
                 when "/v1/apps/app-1/appStoreVersions"
                   query = URI.decode_www_form(uri.query || "").to_h
                   requested_version = query.fetch("filter[versionString]")
                   if requested_version == PREVIOUS_VERSION
                     records = Array.new(previous_count) do |index|
                       {
                         "id" => "previous-#{index + 1}",
                         "attributes" => {
                           "versionString" => PREVIOUS_VERSION,
                           "platform" => "IOS",
                           "appVersionState" => previous_state
                         }
                       }
                     end
                     { "data" => records }
                   else
                     if query.key?("fields[appStoreVersions]")
                       {
                         "data" => [{
                           "id" => "version-1",
                           "attributes" => {
                             "versionString" => returned_target_version,
                             "platform" => returned_target_platform,
                             "appVersionState" => target_state
                           }
                         }]
                       }
                     else
                       {
                         "data" => [{
                           "id" => "version-1",
                           "attributes" => {
                             "versionString" => returned_target_version,
                             "platform" => returned_target_platform
                           }
                         }]
                       }
                     end
                   end
                 when "/v1/appStoreVersions/version-1/appStoreVersionPhasedRelease"
                   observed_state = if patch_seen && post_patch_state
                                      post_patch_state
                                    else
                                      current_state
                                    end
                   {
                     "data" => {
                       "id" => "phase-1",
                       "attributes" => {
                         "phasedReleaseState" => observed_state,
                         "currentDayNumber" => 2,
                         "totalPauseDuration" => 0,
                         "startDate" => "2026-08-03"
                       }
                     }
                   }
                 when "/v1/appStoreVersions/version-1/build"
                   {
                     "data" => {
                       "id" => returned_build_id,
                       "type" => "builds",
                       "attributes" => {
                         "version" => BUILD_NUMBER,
                         "processingState" => "VALID"
                       },
                       "relationships" => {
                         "preReleaseVersion" => {
                           "data" => {
                             "id" => returned_pre_release_version_id,
                             "type" => returned_pre_release_relationship_type
                           }
                         }
                       }
                     },
                     "included" => [{
                       "id" => returned_pre_release_version_id,
                       "type" => "preReleaseVersions",
                       "attributes" => {
                         "version" => TARGET_VERSION,
                         "platform" => returned_pre_release_platform
                       }
                     }]
                   }
                 when "/v1/builds"
                   {
                     "data" => [{
                       "id" => returned_build_id,
                       "type" => returned_build_type,
                       "attributes" => {
                         "version" => BUILD_NUMBER,
                         "processingState" => "VALID"
                       },
                       "relationships" => {
                         "preReleaseVersion" => {
                           "data" => {
                             "id" => returned_pre_release_version_id,
                             "type" => returned_pre_release_relationship_type
                           }
                         }
                       }
                     }],
                     "included" => [{
                       "id" => returned_pre_release_version_id,
                       "type" => "preReleaseVersions",
                       "attributes" => {
                         "version" => TARGET_VERSION,
                         "platform" => returned_pre_release_platform
                       }
                     }]
                   }
                 when "/v1/apps/app-1/buildUploads"
                   uploads = Array.new(returned_build_upload_count) do |index|
                     {
                       "id" => "build-upload-#{index + 1}",
                       "type" => "buildUploads",
                       "attributes" => {
                         "cfBundleShortVersionString" => TARGET_VERSION,
                         "cfBundleVersion" => BUILD_NUMBER,
                         "platform" => "IOS",
                         "state" => {
                           "errors" => [],
                           "state" => returned_build_upload_state
                         }
                       },
                       "relationships" => {
                         "build" => {
                           "data" => {
                             "id" => returned_upload_build_id,
                             "type" => "builds"
                           }
                         },
                         "assetFile" => {
                           "data" => {
                             "id" => returned_asset_file_id,
                             "type" => "buildUploadFiles"
                           }
                         }
                       }
                     }
                   end
                   {
                     "data" => uploads,
                     "included" => [
                       {
                         "id" => returned_upload_build_id,
                         "type" => "builds",
                         "attributes" => { "version" => BUILD_NUMBER }
                       },
                       {
                         "id" => returned_asset_file_id,
                         "type" => "buildUploadFiles",
                         "attributes" => {
                           "assetDeliveryState" => {
                             "errors" => [],
                             "state" => returned_asset_delivery_state
                           },
                           "assetType" => returned_asset_type,
                           "fileSize" => returned_asset_size,
                           "sourceFileChecksums" => {
                             "file" => {
                               "algorithm" => returned_asset_checksum_algorithm,
                               "hash" => returned_asset_checksum
                             }
                           },
                           "uti" => returned_asset_uti
                         }
                       }
                     ]
                   }
                 when "/v1/appStoreVersionPhasedReleases/phase-1"
                   target = JSON.parse(payload).dig("data", "attributes", "phasedReleaseState")
                   current_state = target
                   patch_seen = true
                   {
                     "data" => {
                       "id" => "phase-1",
                       "attributes" => { "phasedReleaseState" => target }
                     }
                   }
                 else
                   raise "unexpected URI #{uri}"
                 end
      [200, JSON.generate(document)]
    end
    journals = []
    client = PakPerkAppStorePhasedRelease::Client.new(
      token: "safe-test-token",
      transport: transport,
      journal_writer: ->(value) { journals << Marshal.load(Marshal.dump(value)) },
      expected_app_id: "app-1",
      expected_build_id: "build-42",
      expected_pre_release_version_id: "pre-1"
    )
    client.define_singleton_method(:journals) { journals }
    [client, calls]
  end

  def test_observes_exact_app_version_and_closed_snapshot
    client, calls = fixture
    result = client.observe(
      bundle_id: BUNDLE_ID,
      app_version: TARGET_VERSION,
      build_number: BUILD_NUMBER
    )
    assert_equal(
      %w[
        app_id app_version_id build current_day_number phased_release_id
        start_date state total_pause_duration
      ],
      result.keys.sort
    )
    assert_equal "ACTIVE", result.fetch("state")
    assert_includes calls[0][1], "filter%5BbundleId%5D=app.pakperk.pakperk"
    assert_includes calls[1][1], "filter%5BversionString%5D=0.2.0"
  end

  def test_pause_journals_before_patch_and_marks_verified_postflight
    client, calls = fixture
    result = client.update(
      bundle_id: BUNDLE_ID,
      app_version: TARGET_VERSION,
      build_number: BUILD_NUMBER,
      operation: "pause"
    )
    assert_equal "unknown_reconcile_required", client.journals.fetch(0).fetch("mutation_status")
    assert_equal "succeeded_verified", result.fetch("mutation_status")
    assert_operator calls.index { |call| call[0] == "PATCH" }, :>, 0
  end

  def test_journal_failure_prevents_patch
    client, = fixture
    client.instance_variable_set(:@journal_writer, ->(_value) { raise IOError, "disk full" })
    assert_raises(IOError) do
      client.update(
        bundle_id: BUNDLE_ID,
        app_version: TARGET_VERSION,
        build_number: BUILD_NUMBER,
        operation: "pause"
      )
    end
  end

  def test_observe_result_is_bound_to_application_version_and_operation
    client, = fixture
    result = PakPerkAppStorePhasedRelease.result_document(
      client: client,
      bundle_id: BUNDLE_ID,
      app_version: TARGET_VERSION,
      build_number: BUILD_NUMBER,
      operation: "observe"
    )
    assert_equal(
      %w[app_version application_id build_number operation phased_release schema],
      result.keys.sort
    )
    assert_equal BUNDLE_ID, result.fetch("application_id")
    assert_equal TARGET_VERSION, result.fetch("app_version")
    assert_equal "observe", result.fetch("operation")
    assert_equal 1, result.fetch("schema")
  end

  def test_upload_verification_binds_remote_ipa_bytes_to_exact_processed_build
    client, calls = fixture
    result = PakPerkAppStorePhasedRelease.result_document(
      client: client,
      bundle_id: BUNDLE_ID,
      app_version: TARGET_VERSION,
      build_number: BUILD_NUMBER,
      operation: "verify-build",
      artifact_sha256: IPA_SHA256,
      artifact_size: IPA_SIZE
    )
    assert_equal "succeeded_verified", result.fetch("verification_status")
    assert_equal BUILD_NUMBER, result.dig("upload_verification", "build", "build_number")
    assert_equal "VALID", result.dig("upload_verification", "build", "processing_state")
    assert_equal "build-42", result.dig("upload_verification", "build_upload", "build_id")
    assert_equal "build-upload-1", result.dig(
      "upload_verification", "build_upload", "build_upload_id"
    )
    assert_equal IPA_SHA256, result.dig(
      "upload_verification", "build_upload", "asset_file", "source_file_checksum", "hash"
    )
    assert_equal IPA_SIZE, result.dig(
      "upload_verification", "build_upload", "asset_file", "file_size"
    )
    upload_call = calls.find { |call| URI(call[1]).path.end_with?("/buildUploads") }
    assert_includes upload_call[1], "filter%5Bstate%5D=COMPLETE"
    assert_includes upload_call[1], "include=build%2CassetFile"
  end

  def test_upload_verification_rejects_remote_bytes_or_asset_identity_drift
    overrides = [
      { returned_asset_checksum: "b" * 64 },
      { returned_asset_checksum_algorithm: "MD5" },
      { returned_asset_size: IPA_SIZE + 1 },
      { returned_asset_uti: "com.apple.pkg" },
      { returned_asset_type: "ASSET_DESCRIPTION" },
      { returned_asset_delivery_state: "FAILED" }
    ]
    overrides.each do |override|
      client, = fixture(**override)
      error = assert_raises(PakPerkAppStorePhasedRelease::Error) do
        client.verify_uploaded_build(
          bundle_id: BUNDLE_ID,
          app_version: TARGET_VERSION,
          build_number: BUILD_NUMBER,
          artifact_sha256: IPA_SHA256,
          artifact_size: IPA_SIZE
        )
      end
      assert_match(/uploaded IPA bytes/, error.message)
    end
  end

  def test_upload_verification_rejects_ambiguous_or_wrong_build_upload_relation
    [
      { returned_build_upload_count: 2 },
      { returned_build_upload_state: "PROCESSING" },
      { returned_upload_build_id: "other-build" }
    ].each do |override|
      client, = fixture(**override)
      assert_raises(PakPerkAppStorePhasedRelease::Error) do
        client.verify_uploaded_build(
          bundle_id: BUNDLE_ID,
          app_version: TARGET_VERSION,
          build_number: BUILD_NUMBER,
          artifact_sha256: IPA_SHA256,
          artifact_size: IPA_SIZE
        )
      end
    end
  end

  def test_upload_verification_requires_bounded_local_ipa_evidence
    client, = fixture
    [
      ["A" * 64, IPA_SIZE],
      [IPA_SHA256, 0],
      [IPA_SHA256, PakPerkAppStorePhasedRelease::MAX_ARTIFACT_BYTES + 1]
    ].each do |digest, size|
      assert_raises(PakPerkAppStorePhasedRelease::Error) do
        client.verify_uploaded_build(
          bundle_id: BUNDLE_ID,
          app_version: TARGET_VERSION,
          build_number: BUILD_NUMBER,
          artifact_sha256: digest,
          artifact_size: size
        )
      end
    end
  end

  def test_observe_rejects_mismatched_bundle_version_and_platform_responses
    [
      { returned_bundle_id: "app.attacker.other" },
      { returned_target_version: "9.9.9" },
      { returned_target_platform: "MAC_OS" }
    ].each do |override|
      client, = fixture(**override)
      assert_raises(PakPerkAppStorePhasedRelease::Error) do
        client.observe(
          bundle_id: BUNDLE_ID,
          app_version: TARGET_VERSION,
          build_number: BUILD_NUMBER
        )
      end
    end
  end

  def test_app_resource_id_must_match_verified_upload_handoff
    client, = fixture(returned_app_id: "other-app")
    error = assert_raises(PakPerkAppStorePhasedRelease::Error) do
      client.observe(
        bundle_id: BUNDLE_ID,
        app_version: TARGET_VERSION,
        build_number: BUILD_NUMBER
      )
    end
    assert_match(/does not match the upload handoff/, error.message)
  end

  def test_build_and_pre_release_ids_must_match_verified_upload_handoff
    [
      { returned_build_id: "other-build" },
      { returned_pre_release_version_id: "other-pre-release" }
    ].each do |override|
      client, = fixture(**override)
      error = assert_raises(PakPerkAppStorePhasedRelease::Error) do
        client.observe(
          bundle_id: BUNDLE_ID,
          app_version: TARGET_VERSION,
          build_number: BUILD_NUMBER
        )
      end
      assert_match(/does not match the upload handoff/, error.message)
    end
  end

  def test_build_pre_release_version_must_be_ios
    client, = fixture(returned_pre_release_platform: "MAC_OS")
    error = assert_raises(PakPerkAppStorePhasedRelease::Error) do
      client.verify_uploaded_build(
        bundle_id: BUNDLE_ID,
        app_version: TARGET_VERSION,
        build_number: BUILD_NUMBER,
        artifact_sha256: IPA_SHA256,
        artifact_size: IPA_SIZE
      )
    end
    assert_match(/exact app version/, error.message)
  end

  def test_uploaded_build_resource_type_must_be_builds
    client, = fixture(returned_build_type: "appStoreVersions")
    error = assert_raises(PakPerkAppStorePhasedRelease::Error) do
      client.verify_uploaded_build(
        bundle_id: BUNDLE_ID,
        app_version: TARGET_VERSION,
        build_number: BUILD_NUMBER,
        artifact_sha256: IPA_SHA256,
        artifact_size: IPA_SIZE
      )
    end
    assert_match(/resource type/, error.message)
  end

  def test_pre_release_relationship_type_is_exact_for_upload_and_rollout_reads
    client, = fixture(returned_pre_release_relationship_type: "appStoreVersions")
    upload_error = assert_raises(PakPerkAppStorePhasedRelease::Error) do
      client.verify_uploaded_build(
        bundle_id: BUNDLE_ID,
        app_version: TARGET_VERSION,
        build_number: BUILD_NUMBER,
        artifact_sha256: IPA_SHA256,
        artifact_size: IPA_SIZE
      )
    end
    assert_match(/relationship type/, upload_error.message)

    rollout_error = assert_raises(PakPerkAppStorePhasedRelease::Error) do
      client.observe(
        bundle_id: BUNDLE_ID,
        app_version: TARGET_VERSION,
        build_number: BUILD_NUMBER
      )
    end
    assert_match(/relationship type/, rollout_error.message)
  end

  def test_advance_observation_rejects_every_non_active_state
    %w[INACTIVE PAUSED COMPLETE].each do |state|
      client, = fixture(state: state)
      error = assert_raises(PakPerkAppStorePhasedRelease::Error) do
        PakPerkAppStorePhasedRelease.result_document(
          client: client,
          bundle_id: BUNDLE_ID,
          app_version: TARGET_VERSION,
          build_number: BUILD_NUMBER,
          operation: "observe"
        )
      end
      assert_match(/requires an ACTIVE/, error.message)
    end
  end

  def test_submission_postflight_requires_exact_inactive_phased_resource
    client, = fixture(state: "INACTIVE")
    result = PakPerkAppStorePhasedRelease.result_document(
      client: client,
      bundle_id: BUNDLE_ID,
      app_version: TARGET_VERSION,
      build_number: BUILD_NUMBER,
      operation: "verify-submission"
    )
    assert_equal "INACTIVE", result.dig("phased_release", "state")
    assert_equal "verify-submission", result.fetch("operation")

    active_client, = fixture(state: "ACTIVE")
    assert_raises(PakPerkAppStorePhasedRelease::Error) do
      PakPerkAppStorePhasedRelease.result_document(
        client: active_client,
        bundle_id: BUNDLE_ID,
        app_version: TARGET_VERSION,
        build_number: BUILD_NUMBER,
        operation: "verify-submission"
      )
    end
  end

  def test_pause_patches_and_reobserves_exact_phased_release
    client, calls = fixture
    result = client.update(
      bundle_id: BUNDLE_ID,
      app_version: TARGET_VERSION,
      build_number: BUILD_NUMBER,
      operation: "pause"
    )
    assert_equal "PAUSED", result.fetch("state")
    assert_equal "ACTIVE", result.fetch("previous_state")
    refute result.fetch("idempotent")
    patch = calls.find { |call| call.first == "PATCH" }
    assert_equal "/v1/appStoreVersionPhasedReleases/phase-1", URI(patch[1]).path
    assert_equal 2, calls.count { |call| URI(call[1]).path.end_with?("appStoreVersionPhasedRelease") }
  end

  def test_post_patch_remote_drift_fails_closed
    client, = fixture(post_patch_state: "ACTIVE")
    error = assert_raises(PakPerkAppStorePhasedRelease::Error) do
      client.update(
        bundle_id: BUNDLE_ID,
        app_version: TARGET_VERSION,
        build_number: BUILD_NUMBER,
        operation: "pause"
      )
    end
    assert_match(/postflight state/, error.message)
    assert_equal "unknown_reconcile_required", client.journals.fetch(0).fetch("mutation_status")
  end

  def test_repeated_pause_is_idempotent
    client, calls = fixture(state: "PAUSED")
    result = client.update(
      bundle_id: BUNDLE_ID,
      app_version: TARGET_VERSION,
      build_number: BUILD_NUMBER,
      operation: "pause"
    )
    assert result.fetch("idempotent")
    refute calls.any? { |call| call.first == "PATCH" }
    assert_equal "proven_not_committed", client.journals.fetch(0).fetch("mutation_status")
  end

  def test_complete_rejects_a_paused_release_after_terminal_halt
    client, = fixture(state: "PAUSED")
    error = assert_raises(PakPerkAppStorePhasedRelease::Error) do
      client.update(
        bundle_id: BUNDLE_ID,
        app_version: TARGET_VERSION,
        build_number: BUILD_NUMBER,
        operation: "complete"
      )
    end
    assert_match(/cannot complete phased release from PAUSED/, error.message)
  end

  def test_update_preflight_proves_exact_ready_for_distribution_prior_version
    client, calls = fixture
    result = PakPerkAppStorePhasedRelease.result_document(
      client: client,
      bundle_id: BUNDLE_ID,
      app_version: TARGET_VERSION,
      build_number: BUILD_NUMBER,
      operation: "verify-update",
      previous_public_version: PREVIOUS_VERSION
    )
    assert_equal(
      %w[app_version application_id build_number mutation_status operation schema update_preflight],
      result.keys.sort
    )
    assert_equal "READY_FOR_DISTRIBUTION", result.dig("update_preflight", "previous", "state")
    assert_equal PREVIOUS_VERSION, result.dig("update_preflight", "previous", "version")
    assert_equal "PREPARE_FOR_SUBMISSION", result.dig("update_preflight", "target", "state")
    version_call = calls.find { |call| call[1].include?("0.1.0") }
    assert_includes version_call[1], "fields%5BappStoreVersions%5D=versionString%2Cplatform%2CappVersionState"
  end

  def test_first_publication_is_rejected_without_prior_version
    client, = fixture(previous_count: 0)
    error = assert_raises(PakPerkAppStorePhasedRelease::Error) do
      client.verify_update(
        bundle_id: BUNDLE_ID,
        app_version: TARGET_VERSION,
        build_number: BUILD_NUMBER,
        previous_public_version: PREVIOUS_VERSION
      )
    end
    assert_match(/returned 0 records/, error.message)
  end

  def test_prior_version_must_be_ready_for_distribution
    client, = fixture(previous_state: "REPLACED_WITH_NEW_VERSION")
    error = assert_raises(PakPerkAppStorePhasedRelease::Error) do
      client.verify_update(
        bundle_id: BUNDLE_ID,
        app_version: TARGET_VERSION,
        build_number: BUILD_NUMBER,
        previous_public_version: PREVIOUS_VERSION
      )
    end
    assert_match(/not exactly READY_FOR_DISTRIBUTION/, error.message)
  end

  def test_target_version_must_be_in_reviewed_pre_submit_state
    client, = fixture(target_state: "IN_REVIEW")
    error = assert_raises(PakPerkAppStorePhasedRelease::Error) do
      client.verify_update(
        bundle_id: BUNDLE_ID,
        app_version: TARGET_VERSION,
        build_number: BUILD_NUMBER,
        previous_public_version: PREVIOUS_VERSION
      )
    end
    assert_match(/not in a reviewed pre-submit state/, error.message)
  end

  def test_ambiguous_prior_version_fails_closed
    client, = fixture(previous_count: 2)
    error = assert_raises(PakPerkAppStorePhasedRelease::Error) do
      client.verify_update(
        bundle_id: BUNDLE_ID,
        app_version: TARGET_VERSION,
        build_number: BUILD_NUMBER,
        previous_public_version: PREVIOUS_VERSION
      )
    end
    assert_match(/returned 2 records/, error.message)
  end

  def test_duplicate_application_lookup_fails_closed
    transport = lambda do |_method, _uri, _headers, _payload|
      [200, JSON.generate("data" => [{ "id" => "one" }, { "id" => "two" }])]
    end
    client = PakPerkAppStorePhasedRelease::Client.new(token: "test", transport: transport)
    error = assert_raises(PakPerkAppStorePhasedRelease::Error) do
      client.observe(
        bundle_id: BUNDLE_ID,
        app_version: TARGET_VERSION,
        build_number: BUILD_NUMBER
      )
    end
    assert_match(/returned 2 records/, error.message)
  end

  def test_redirect_and_oversized_response_fail_closed
    [
      [302, "{}"],
      [200, "x" * (PakPerkAppStorePhasedRelease::MAX_RESPONSE_BYTES + 1)]
    ].each do |status, body|
      client = PakPerkAppStorePhasedRelease::Client.new(
        token: "test",
        transport: ->(*) { [status, body] }
      )
      assert_raises(PakPerkAppStorePhasedRelease::Error) do
        client.observe(
          bundle_id: BUNDLE_ID,
          app_version: TARGET_VERSION,
          build_number: BUILD_NUMBER
        )
      end
    end
  end

  def test_token_identity_rejects_malformed_issuer_before_reading_key
    error = assert_raises(PakPerkAppStorePhasedRelease::Error) do
      PakPerkAppStorePhasedRelease.build_token(
        key_id: "ABCDEFGHIJ",
        issuer_id: "------------------------------------",
        private_key_path: "/not/read"
      )
    end
    assert_match(/issuer ID is invalid/, error.message)
  end

  def test_private_key_reader_rejects_symlink_and_hardlink
    Dir.mktmpdir do |directory|
      root = File.expand_path(directory)
      key = File.join(root, "key.p8")
      File.write(key, "private")
      File.chmod(0o600, key)
      symlink = File.join(root, "symlink.p8")
      hardlink = File.join(root, "hardlink.p8")
      File.symlink(key, symlink)
      File.link(key, hardlink)
      assert_raises(PakPerkAppStorePhasedRelease::Error) do
        PakPerkAppStorePhasedRelease.read_private(symlink, 32)
      end
      assert_raises(PakPerkAppStorePhasedRelease::Error) do
        PakPerkAppStorePhasedRelease.read_private(hardlink, 32)
      end
    end
  end

  def test_file_identity_binds_whole_timestamp_seconds
    stat = Struct.new(:dev, :ino, :size, :mtime, :ctime)
    first = stat.new(1, 2, 3, Time.at(100, 456, :nsec), Time.at(200, 789, :nsec))
    second = stat.new(1, 2, 3, Time.at(101, 456, :nsec), Time.at(200, 789, :nsec))
    refute_equal(
      PakPerkAppStorePhasedRelease.file_identity(first),
      PakPerkAppStorePhasedRelease.file_identity(second)
    )
  end

  def test_private_result_is_canonical_owner_only_and_exclusive
    Dir.mktmpdir do |directory|
      path = File.join(directory, "result.json")
      PakPerkAppStorePhasedRelease.write_private(path, { "z" => 1, "a" => 2 })
      assert_equal "{\"a\":2,\"z\":1}\n", File.read(path)
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_raises(PakPerkAppStorePhasedRelease::Error) do
        PakPerkAppStorePhasedRelease.write_private(path, {})
      end
    end
  end
end
