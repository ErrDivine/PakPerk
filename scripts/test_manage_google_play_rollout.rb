#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "manage_google_play_rollout"

FakePlayRelease = Struct.new(
  :country_targeting,
  :in_app_update_priority,
  :name,
  :release_notes,
  :status,
  :user_fraction,
  :version_codes,
  keyword_init: true
)
FakePlayTrack = Struct.new(:track, :releases, keyword_init: true)
FakePlayEdit = Struct.new(:id, keyword_init: true)
FakePlayBundle = Struct.new(:sha256, :version_code, keyword_init: true)
FakePlayBundles = Struct.new(:bundles, keyword_init: true)

class FakePlayService
  attr_reader :calls, :live_tracks
  attr_accessor :bundles, :commit_error, :post_commit_mutator

  def initialize(tracks)
    @live_tracks = deep_copy(tracks)
    @edits = {}
    @next_id = 0
    @calls = []
    @bundles = []
  end

  def insert_edit(package_name, _edit)
    @next_id += 1
    identifier = "edit-#{@next_id}"
    @edits[identifier] = deep_copy(@live_tracks)
    @calls << ["insert", package_name, identifier]
    FakePlayEdit.new(id: identifier)
  end

  def get_edit_track(package_name, edit_id, track)
    @calls << ["get", package_name, edit_id, track]
    deep_copy(
      @edits.fetch(edit_id).fetch(
        track,
        FakePlayTrack.new(track: track, releases: [])
      )
    )
  end

  def update_edit_track(package_name, edit_id, track, desired)
    @calls << ["update", package_name, edit_id, track]
    @edits.fetch(edit_id)[track] = FakePlayTrack.new(
      track: track,
      releases: deep_copy(desired.releases)
    )
  end

  def list_edit_bundles(package_name, edit_id)
    @calls << ["list_bundles", package_name, edit_id]
    FakePlayBundles.new(bundles: deep_copy(@bundles))
  end

  def commit_edit(package_name, edit_id)
    @calls << ["commit", package_name, edit_id]
    raise @commit_error if @commit_error

    @live_tracks = deep_copy(@edits.delete(edit_id))
    @post_commit_mutator&.call(@live_tracks)
    FakePlayEdit.new(id: edit_id)
  end

  def delete_edit(package_name, edit_id)
    @calls << ["delete", package_name, edit_id]
    @edits.delete(edit_id)
  end

  private

  def deep_copy(value)
    Marshal.load(Marshal.dump(value))
  end
end

class GooglePlayRolloutTest < Minitest::Test
  def test_file_identity_binds_whole_timestamp_seconds
    stat = Struct.new(:dev, :ino, :size, :mtime, :ctime)
    first = stat.new(1, 2, 3, Time.at(100, 456, :nsec), Time.at(200, 789, :nsec))
    second = stat.new(1, 2, 3, Time.at(101, 456, :nsec), Time.at(200, 789, :nsec))

    refute_equal(
      PakPerkGooglePlayRollout.file_identity(first),
      PakPerkGooglePlayRollout.file_identity(second)
    )
  end

  PACKAGE = PakPerkGooglePlayRollout::PRODUCTION_PACKAGE
  TARGET = "42"
  PREVIOUS = "41"
  AAB_SHA256 = "a" * 64

  def release(code, status:, fraction: nil)
    FakePlayRelease.new(
      country_targeting: nil,
      in_app_update_priority: 0,
      name: "release-#{code}",
      release_notes: [],
      status: status,
      user_fraction: fraction,
      version_codes: [code]
    )
  end

  def tracks(target: nil, fallback: release(PREVIOUS, status: "completed"), internal: nil)
    production_releases = [target, fallback].compact
    {
      "production" => FakePlayTrack.new(
        track: "production",
        releases: production_releases
      ),
      "internal" => FakePlayTrack.new(
        track: "internal",
        releases: [internal].compact
      )
    }
  end

  def client_for(initial_tracks)
    service = FakePlayService.new(initial_tracks)
    journals = []
    client = PakPerkGooglePlayRollout::Client.new(
      service: service,
      edit_factory: -> { FakePlayEdit.new },
      release_factory: ->(**attributes) { FakePlayRelease.new(**attributes) },
      track_factory: ->(**attributes) { FakePlayTrack.new(**attributes) },
      journal_writer: ->(value) { journals << Marshal.load(Marshal.dump(value)) }
    )
    service.define_singleton_method(:journals) { journals }
    [client, service]
  end

  def transition(client, operation:, expected:, target:, previous: PREVIOUS)
    client.transition(
      package_name: PACKAGE,
      version_code: TARGET,
      previous_production_version_code: previous,
      operation: operation,
      expected_fraction: expected,
      target_fraction: target
    )
  end

  def test_start_requires_completed_internal_candidate_and_completed_fallback
    client, service = client_for(
      tracks(internal: release(TARGET, status: "completed"))
    )
    result = transition(client, operation: "start", expected: "none", target: "0.01")
    assert_nil result.dig("before", "target")
    assert_equal "completed", result.dig("before", "fallback", "status")
    assert_equal "inProgress", result.dig("after", "target", "status")
    assert_equal "0.01", result.dig("after", "target", "user_fraction")
    assert_equal "completed", result.dig("after", "fallback", "status")
    assert service.calls.any? { |call| call.first == "commit" }
    assert_equal "unknown_reconcile_required", service.journals.fetch(0).fetch("mutation_status")
    assert_equal "succeeded_verified", result.fetch("mutation_status")
  end

  def test_upload_verification_reads_exact_completed_internal_singleton
    client, service = client_for(tracks(internal: release(TARGET, status: "completed")))
    service.bundles = [FakePlayBundle.new(version_code: TARGET.to_i, sha256: AAB_SHA256)]
    result = client.verify_internal_upload(
      package_name: PACKAGE,
      version_code: TARGET,
      artifact_sha256: AAB_SHA256
    )
    assert_equal "succeeded_verified", result.fetch("verification_status")
    assert_equal [TARGET], result.dig("internal_target", "version_codes")
    assert_equal AAB_SHA256, result.dig("bundle", "sha256")
    assert_equal TARGET, result.dig("bundle", "version_code")
    assert service.calls.any? { |call| call.first == "list_bundles" }
  end

  def test_upload_verification_rejects_a_different_remote_bundle_digest
    client, service = client_for(tracks(internal: release(TARGET, status: "completed")))
    service.bundles = [FakePlayBundle.new(version_code: TARGET.to_i, sha256: "b" * 64)]
    error = assert_raises(PakPerkGooglePlayRollout::Error) do
      client.verify_internal_upload(
        package_name: PACKAGE,
        version_code: TARGET,
        artifact_sha256: AAB_SHA256
      )
    end
    assert_match(/digest does not match/, error.message)
  end

  def test_upload_verification_rejects_an_ambiguous_remote_bundle
    client, service = client_for(tracks(internal: release(TARGET, status: "completed")))
    service.bundles = [
      FakePlayBundle.new(version_code: TARGET.to_i, sha256: AAB_SHA256),
      FakePlayBundle.new(version_code: TARGET.to_i, sha256: AAB_SHA256)
    ]
    error = assert_raises(PakPerkGooglePlayRollout::Error) do
      client.verify_internal_upload(
        package_name: PACKAGE,
        version_code: TARGET,
        artifact_sha256: AAB_SHA256
      )
    end
    assert_match(/lookup is not exact/, error.message)
  end

  def test_commit_error_retains_a_precommit_reconciliation_journal
    client, service = client_for(
      tracks(internal: release(TARGET, status: "completed"))
    )
    service.commit_error = IOError.new("ambiguous commit response")
    error = assert_raises(PakPerkGooglePlayRollout::Error) do
      transition(client, operation: "start", expected: "none", target: "0.01")
    end
    assert_match(/transition failed/, error.message)
    assert_equal 1, service.journals.length
    assert_equal "unknown_reconcile_required", service.journals.first.fetch("mutation_status")
    assert service.calls.any? { |call| call.first == "commit" }
  end

  def test_journal_failure_prevents_commit
    service = FakePlayService.new(tracks(internal: release(TARGET, status: "completed")))
    client = PakPerkGooglePlayRollout::Client.new(
      service: service,
      edit_factory: -> { FakePlayEdit.new },
      release_factory: ->(**attributes) { FakePlayRelease.new(**attributes) },
      track_factory: ->(**attributes) { FakePlayTrack.new(**attributes) },
      journal_writer: ->(_value) { raise IOError, "disk full" }
    )
    assert_raises(PakPerkGooglePlayRollout::Error) do
      transition(client, operation: "start", expected: "none", target: "0.01")
    end
    refute service.calls.any? { |call| call.first == "commit" }
  end

  def test_first_public_play_release_is_rejected_without_a_completed_fallback
    client, = client_for(
      tracks(
        fallback: nil,
        internal: release(TARGET, status: "completed")
      )
    )
    error = assert_raises(PakPerkGooglePlayRollout::Error) do
      transition(client, operation: "start", expected: "none", target: "0.01")
    end
    assert_match(/previous completed production release is missing/, error.message)
  end

  def test_another_active_production_release_is_rejected
    initial = tracks(
      target: release(TARGET, status: "inProgress", fraction: 0.01)
    )
    initial.fetch("production").releases << release(
      "40", status: "inProgress", fraction: 0.50
    )
    client, = client_for(initial)
    error = assert_raises(PakPerkGooglePlayRollout::Error) do
      transition(client, operation: "advance", expected: "0.01", target: "0.02")
    end
    assert_match(/another active or draft release/, error.message)
  end

  def test_supplied_fallback_must_be_highest_completed_prior_release
    initial = tracks(
      target: release(TARGET, status: "inProgress", fraction: 0.01),
      fallback: release("40", status: "completed")
    )
    initial.fetch("production").releases << release("41", status: "completed")
    client, = client_for(initial)
    error = assert_raises(PakPerkGooglePlayRollout::Error) do
      transition(
        client,
        operation: "advance",
        expected: "0.01",
        target: "0.02",
        previous: "40"
      )
    end
    assert_match(/highest completed prior release/, error.message)
  end

  def test_target_must_be_newer_than_every_production_release
    initial = tracks(
      target: release(TARGET, status: "inProgress", fraction: 0.01)
    )
    initial.fetch("production").releases << release("43", status: "completed")
    client, = client_for(initial)
    error = assert_raises(PakPerkGooglePlayRollout::Error) do
      transition(client, operation: "advance", expected: "0.01", target: "0.02")
    end
    assert_match(/not newer than every production release/, error.message)
  end

  def test_strictly_older_completed_history_is_preserved
    initial = tracks(
      target: release(TARGET, status: "inProgress", fraction: 0.01)
    )
    initial.fetch("production").releases << release("40", status: "completed")
    client, service = client_for(initial)
    transition(client, operation: "advance", expected: "0.01", target: "0.02")
    codes = service.live_tracks.fetch("production").releases.map do |item|
      item.version_codes.fetch(0)
    end
    assert_equal %w[40 41 42], codes.sort
  end

  def test_start_rejects_a_draft_internal_release
    client, = client_for(tracks(internal: release(TARGET, status: "draft")))
    assert_raises(PakPerkGooglePlayRollout::Error) do
      transition(client, operation: "start", expected: "none", target: "0.01")
    end
  end

  def test_advance_requires_exact_remote_fraction_and_next_schedule_step
    client, = client_for(
      tracks(target: release(TARGET, status: "inProgress", fraction: 0.01))
    )
    result = transition(client, operation: "advance", expected: "0.01", target: "0.02")
    assert_equal "0.01", result.dig("before", "target", "user_fraction")
    assert_equal "0.02", result.dig("after", "target", "user_fraction")

    skipped_client, = client_for(
      tracks(target: release(TARGET, status: "inProgress", fraction: 0.01))
    )
    assert_raises(PakPerkGooglePlayRollout::Error) do
      transition(skipped_client, operation: "advance", expected: "0.01", target: "0.10")
    end
  end

  def test_advance_rejects_remote_fraction_drift
    client, = client_for(
      tracks(target: release(TARGET, status: "inProgress", fraction: 0.05))
    )
    assert_raises(PakPerkGooglePlayRollout::Error) do
      transition(client, operation: "advance", expected: "0.01", target: "0.02")
    end
  end

  def test_post_commit_remote_drift_fails_postflight
    client, service = client_for(
      tracks(target: release(TARGET, status: "inProgress", fraction: 0.01))
    )
    service.post_commit_mutator = lambda do |live|
      target = live.fetch("production").releases.find do |item|
        item.version_codes == [TARGET]
      end
      target.user_fraction = 0.05
    end
    error = assert_raises(PakPerkGooglePlayRollout::Error) do
      transition(client, operation: "advance", expected: "0.01", target: "0.02")
    end
    assert_match(/postflight state/, error.message)
    assert_equal "unknown_reconcile_required", service.journals.fetch(0).fetch("mutation_status")
  end

  def test_draft_cannot_advance_or_complete
    %w[advance complete].each do |operation|
      client, = client_for(tracks(target: release(TARGET, status: "draft")))
      expected, target = operation == "advance" ? %w[0.01 0.02] : %w[0.50 1.00]
      assert_raises(PakPerkGooglePlayRollout::Error) do
        transition(client, operation: operation, expected: expected, target: target)
      end
    end
  end

  def test_halt_binds_the_exact_current_fraction
    client, = client_for(
      tracks(target: release(TARGET, status: "inProgress", fraction: 0.20))
    )
    result = transition(client, operation: "halt", expected: "0.20", target: "0.20")
    assert_equal "halted", result.dig("after", "target", "status")
    assert_equal "0.20", result.dig("after", "target", "user_fraction")
  end

  def test_complete_is_allowed_only_from_fifty_percent
    client, = client_for(
      tracks(target: release(TARGET, status: "inProgress", fraction: 0.50))
    )
    result = transition(client, operation: "complete", expected: "0.50", target: "1.00")
    assert_equal "completed", result.dig("after", "target", "status")
    assert_nil result.dig("after", "target", "user_fraction")

    wrong_client, = client_for(
      tracks(target: release(TARGET, status: "inProgress", fraction: 0.20))
    )
    assert_raises(PakPerkGooglePlayRollout::Error) do
      transition(wrong_client, operation: "complete", expected: "0.50", target: "1.00")
    end
  end

  def test_post_completion_rollback_halts_exact_target_and_preserves_fallback
    client, = client_for(tracks(target: release(TARGET, status: "completed")))
    result = transition(client, operation: "rollback", expected: "1.00", target: "1.00")
    assert_equal "completed", result.dig("after", "fallback", "status")
    assert_equal "halted", result.dig("after", "target", "status")
    assert_nil result.dig("after", "target", "user_fraction")
  end

  def test_post_completion_rollback_rejects_a_missing_fallback
    client, = client_for(
      tracks(target: release(TARGET, status: "completed"), fallback: nil)
    )
    assert_raises(PakPerkGooglePlayRollout::Error) do
      transition(client, operation: "rollback", expected: "1.00", target: "1.00")
    end
  end

  def test_halted_release_cannot_be_advanced_or_completed
    %w[advance complete].each do |operation|
      client, = client_for(
        tracks(target: release(TARGET, status: "halted", fraction: 0.50))
      )
      expected, target = operation == "advance" ? %w[0.20 0.50] : %w[0.50 1.00]
      assert_raises(PakPerkGooglePlayRollout::Error) do
        transition(client, operation: operation, expected: expected, target: target)
      end
    end
  end

  def test_private_output_is_canonical_exclusive_and_owner_only
    Dir.mktmpdir do |directory|
      path = File.join(directory, "result.json")
      PakPerkGooglePlayRollout.write_private(path, { "z" => 2, "a" => { "z" => 1, "a" => 0 } })
      assert_equal "{\"a\":{\"a\":0,\"z\":1},\"z\":2}\n", File.binread(path)
      assert_equal 0, File.stat(path).mode & 0o077
      assert_raises(PakPerkGooglePlayRollout::Error) do
        PakPerkGooglePlayRollout.write_private(path, {})
      end
    end
  end

  def test_private_credential_reader_rejects_symlinks_and_hard_links
    Dir.mktmpdir do |directory|
      target = File.join(directory, "credential.json")
      File.write(target, "{}")
      File.chmod(0o600, target)
      symlink = File.join(directory, "symlink.json")
      File.symlink(target, symlink)
      assert_raises(PakPerkGooglePlayRollout::Error) do
        PakPerkGooglePlayRollout.read_private(symlink, 1024)
      end
      hardlink = File.join(directory, "hardlink.json")
      File.link(target, hardlink)
      assert_raises(PakPerkGooglePlayRollout::Error) do
        PakPerkGooglePlayRollout.read_private(target, 1024)
      end
    end
  end

  def test_service_account_schema_fails_before_loading_network_dependencies
    error = assert_raises(PakPerkGooglePlayRollout::Error) do
      PakPerkGooglePlayRollout.build_service("{\"type\":\"authorized_user\"}")
    end
    assert_match(/schema is invalid/, error.message)
  end
end
