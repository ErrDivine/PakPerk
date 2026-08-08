#!/usr/bin/env ruby
# frozen_string_literal: true

require "bigdecimal"
require "json"
require "optparse"
require "stringio"

module PakPerkGooglePlayRollout
  PRODUCTION_PACKAGE = "app.pakperk.pakperk"
  MAX_CREDENTIAL_BYTES = 64 * 1024
  MAX_OUTPUT_BYTES = 64 * 1024
  REVIEWED_FRACTIONS = %w[0.01 0.02 0.05 0.10 0.20 0.50].freeze
  NEXT_FRACTION = REVIEWED_FRACTIONS.each_cons(2).to_h.freeze
  OPERATIONS = %w[start advance halt complete rollback].freeze
  COMMANDS = (OPERATIONS + ["verify-upload"]).freeze
  STATES = %w[draft inProgress halted completed].freeze
  SAFE_ID = /\A[A-Za-z0-9_-]{1,128}\z/
  VERSION_CODE = /\A[1-9][0-9]{0,9}\z/
  SHA256 = /\A[0-9a-f]{64}\z/

  class Error < StandardError; end

  class Client
    def initialize(service:, edit_factory:, track_factory:, release_factory:, journal_writer: nil)
      @service = service
      @edit_factory = edit_factory
      @track_factory = track_factory
      @release_factory = release_factory
      @journal_writer = journal_writer
    end

    def transition(
      package_name:,
      version_code:,
      previous_production_version_code:,
      operation:,
      expected_fraction:,
      target_fraction:
    )
      validate_request(
        package_name: package_name,
        version_code: version_code,
        previous_production_version_code: previous_production_version_code,
        operation: operation,
        expected_fraction: expected_fraction,
        target_fraction: target_fraction
      )

      before = nil
      edit_id = begin_edit(package_name)
      committed = false
      begin
        production = @service.get_edit_track(package_name, edit_id, "production")
        internal = if operation == "start"
                     @service.get_edit_track(package_name, edit_id, "internal")
                   end
        before, source_release, desired_status, desired_fraction = preflight(
          production: production,
          internal: internal,
          version_code: version_code,
          previous_version_code: previous_production_version_code,
          operation: operation,
          expected_fraction: expected_fraction,
          target_fraction: target_fraction
        )
        desired_release = copy_release(
          source_release,
          status: desired_status,
          fraction: desired_fraction
        )
        releases = production_releases(production).reject do |release|
          release.version_codes.map(&:to_s).include?(version_code)
        end
        releases << desired_release
        desired_track = @track_factory.call(
          track: "production",
          releases: releases
        )
        @service.update_edit_track(
          package_name,
          edit_id,
          "production",
          desired_track
        )
        write_mutation_journal(
          package_name: package_name,
          version_code: version_code,
          previous_production_version_code: previous_production_version_code,
          operation: operation,
          expected_fraction: expected_fraction,
          target_fraction: target_fraction,
          before: before
        )
        @service.commit_edit(package_name, edit_id)
        committed = true
      ensure
        discard_edit(package_name, edit_id) unless committed
      end

      production_after = observe_track(package_name, "production")
      after = verify_postflight(
        production: production_after,
        version_code: version_code,
        previous_version_code: previous_production_version_code,
        operation: operation,
        target_fraction: target_fraction
      )
      {
        "after" => after,
        "application_id" => package_name,
        "before" => before,
        "operation" => operation,
        "mutation_status" => "succeeded_verified",
        "previous_production_version_code" => previous_production_version_code,
        "requested" => {
          "expected_current_fraction" => expected_fraction,
          "target_fraction" => target_fraction
        },
        "schema" => 1,
        "version_code" => version_code
      }
    rescue Error
      raise
    rescue StandardError => error
      raise Error, "Google Play API transition failed (#{error.class})"
    end

    def verify_internal_upload(package_name:, version_code:, artifact_sha256:)
      raise Error, "Google Play package is not production" unless package_name == PRODUCTION_PACKAGE
      positive_version_code(version_code, "target version code")
      raise Error, "uploaded AAB SHA-256 is invalid" unless SHA256.match?(artifact_sha256)
      internal, bundles = observe_internal_upload(package_name)
      release = exact_release(internal, version_code, "uploaded internal release")
      observed = snapshot(release)
      unless observed.fetch("status") == "completed" && observed.fetch("user_fraction").nil?
        raise Error, "uploaded internal release is not completed"
      end
      bundle = exact_bundle(bundles, version_code)
      unless bundle.fetch("sha256") == artifact_sha256
        raise Error, "uploaded Google Play bundle digest does not match the candidate"
      end
      {
        "application_id" => package_name,
        "bundle" => bundle,
        "internal_target" => observed,
        "schema" => 1,
        "verification_status" => "succeeded_verified",
        "version_code" => version_code
      }
    rescue Error
      raise
    rescue StandardError => error
      raise Error, "Google Play upload verification failed (#{error.class})"
    end

    private

    def exact_bundle(response, version_code)
      bundles = response&.bundles
      raise Error, "Google Play bundle response is malformed" unless bundles.is_a?(Array)
      matches = bundles.select { |bundle| bundle&.version_code.to_s == version_code }
      raise Error, "uploaded Google Play bundle lookup is not exact" unless matches.length == 1

      sha256 = matches.first.sha256
      unless sha256.is_a?(String) && SHA256.match?(sha256)
        raise Error, "uploaded Google Play bundle SHA-256 is invalid"
      end
      { "sha256" => sha256, "version_code" => version_code }
    end

    def write_mutation_journal(
      package_name:,
      version_code:,
      previous_production_version_code:,
      operation:,
      expected_fraction:,
      target_fraction:,
      before:
    )
      raise Error, "Google Play mutation journal writer is not configured" unless @journal_writer

      @journal_writer.call(
        "application_id" => package_name,
        "before" => before,
        "mutation_status" => "unknown_reconcile_required",
        "operation" => operation,
        "previous_production_version_code" => previous_production_version_code,
        "requested" => {
          "expected_current_fraction" => expected_fraction,
          "target_fraction" => target_fraction
        },
        "schema" => 1,
        "version_code" => version_code
      )
    end

    def validate_request(
      package_name:,
      version_code:,
      previous_production_version_code:,
      operation:,
      expected_fraction:,
      target_fraction:
    )
      raise Error, "Google Play package is not production" unless package_name == PRODUCTION_PACKAGE
      code = positive_version_code(version_code, "target version code")
      previous = positive_version_code(
        previous_production_version_code,
        "previous production version code"
      )
      raise Error, "previous production version code must be older" unless previous < code
      raise Error, "unsupported Google Play rollout operation" unless OPERATIONS.include?(operation)

      case operation
      when "start"
        require_fractions(expected_fraction, target_fraction, "none", "0.01")
      when "advance"
        unless NEXT_FRACTION[expected_fraction] == target_fraction
          raise Error, "advance must use the next reviewed rollout fraction"
        end
      when "halt"
        unless REVIEWED_FRACTIONS.include?(expected_fraction) && target_fraction == expected_fraction
          raise Error, "halt must bind the exact current staged fraction"
        end
      when "complete"
        require_fractions(expected_fraction, target_fraction, "0.50", "1.00")
      when "rollback"
        require_fractions(expected_fraction, target_fraction, "1.00", "1.00")
      end
    end

    def require_fractions(observed_expected, observed_target, expected, target)
      return if observed_expected == expected && observed_target == target

      raise Error, "rollout fraction contract does not match the requested operation"
    end

    def positive_version_code(value, label)
      unless value.is_a?(String) && VERSION_CODE.match?(value)
        raise Error, "#{label} is invalid"
      end
      number = Integer(value, 10)
      raise Error, "#{label} exceeds the Android limit" if number > 2_100_000_000

      number
    end

    def preflight(
      production:,
      internal:,
      version_code:,
      previous_version_code:,
      operation:,
      expected_fraction:,
      target_fraction:
    )
      fallback = exact_release(
        production,
        previous_version_code,
        "previous completed production release"
      )
      validate_production_shape(
        production,
        version_code: version_code,
        previous_version_code: previous_version_code,
        target_required: operation != "start"
      )
      fallback_snapshot = snapshot(fallback)
      unless fallback_snapshot.fetch("status") == "completed" && fallback_snapshot.fetch("user_fraction").nil?
        raise Error, "previous production release is not a completed fallback"
      end

      target = exact_release(
        production,
        version_code,
        "target production release",
        required: operation != "start"
      )
      internal_target = nil
      source = target
      desired_status = nil
      desired_fraction = nil

      case operation
      when "start"
        raise Error, "target version already exists on production" unless target.nil?
        internal_target = exact_release(
          internal,
          version_code,
          "target internal release"
        )
        internal_snapshot = snapshot(internal_target)
        unless internal_snapshot.fetch("status") == "completed" && internal_snapshot.fetch("user_fraction").nil?
          raise Error, "target internal release is not completed"
        end
        source = internal_target
        desired_status = "inProgress"
        desired_fraction = target_fraction
      when "advance"
        require_staged_target(target, expected_fraction)
        desired_status = "inProgress"
        desired_fraction = target_fraction
      when "halt"
        require_staged_target(target, expected_fraction)
        desired_status = "halted"
        desired_fraction = target_fraction
      when "complete"
        require_staged_target(target, expected_fraction)
        desired_status = "completed"
      when "rollback"
        target_snapshot = snapshot(target)
        unless target_snapshot.fetch("status") == "completed" && target_snapshot.fetch("user_fraction").nil?
          raise Error, "post-completion rollback requires the exact completed target"
        end
        desired_status = "halted"
      end

      before = {
        "fallback" => fallback_snapshot,
        "internal_target" => internal_target.nil? ? nil : snapshot(internal_target),
        "target" => target.nil? ? nil : snapshot(target)
      }
      [before, source, desired_status, desired_fraction]
    end

    def require_staged_target(release, expected_fraction)
      observed = snapshot(release)
      unless observed.fetch("status") == "inProgress" &&
             observed.fetch("user_fraction") == expected_fraction
        raise Error, "target is not at the exact expected staged state"
      end
    end

    def verify_postflight(
      production:,
      version_code:,
      previous_version_code:,
      operation:,
      target_fraction:
    )
      target = exact_release(production, version_code, "postflight target release")
      fallback = exact_release(
        production,
        previous_version_code,
        "postflight completed fallback"
      )
      validate_production_shape(
        production,
        version_code: version_code,
        previous_version_code: previous_version_code,
        target_required: true
      )
      fallback_snapshot = snapshot(fallback)
      unless fallback_snapshot.fetch("status") == "completed" && fallback_snapshot.fetch("user_fraction").nil?
        raise Error, "postflight fallback is not completed"
      end

      expected_status = {
        "start" => "inProgress",
        "advance" => "inProgress",
        "halt" => "halted",
        "complete" => "completed",
        "rollback" => "halted"
      }.fetch(operation)
      expected_fraction = if %w[start advance halt].include?(operation)
                            target_fraction
                          end
      target_snapshot = snapshot(target)
      unless target_snapshot.fetch("status") == expected_status &&
             target_snapshot.fetch("user_fraction") == expected_fraction
        raise Error, "Google Play postflight state does not match the requested transition"
      end
      {
        "fallback" => fallback_snapshot,
        "target" => target_snapshot
      }
    end

    def exact_release(track, version_code, label, required: true)
      releases = production_releases(track, label)

      matches = releases.select do |release|
        codes = release.version_codes
        codes.is_a?(Array) && codes.map(&:to_s).include?(version_code)
      end
      if matches.empty?
        return nil unless required

        raise Error, "#{label} is missing"
      end
      raise Error, "#{label} is ambiguous" unless matches.length == 1

      release = matches.first
      unless release.version_codes.map(&:to_s) == [version_code]
        raise Error, "#{label} contains an unexpected version-code set"
      end
      release
    end

    def production_releases(track, label = "Google Play")
      releases = track&.releases
      raise Error, "#{label} track response is malformed" unless releases.nil? || releases.is_a?(Array)

      releases || []
    end

    def validate_production_shape(
      track,
      version_code:,
      previous_version_code:,
      target_required:
    )
      target_number = positive_version_code(version_code, "target version code")
      previous_number = positive_version_code(
        previous_version_code,
        "previous production version code"
      )
      seen = {}
      completed_prior = []
      target_count = 0
      production_releases(track).each do |release|
        codes = release.version_codes
        unless codes.is_a?(Array) && codes.length == 1
          raise Error, "production track contains a non-singleton version-code set"
        end
        number = positive_version_code(codes.first.to_s, "production version code")
        raise Error, "production track contains duplicate version codes" if seen[number]

        seen[number] = true
        observed = snapshot(release)
        if number == target_number
          target_count += 1
          next
        end
        if number >= target_number
          raise Error, "target version code is not newer than every production release"
        end
        unless observed.fetch("status") == "completed" && observed.fetch("user_fraction").nil?
          raise Error, "production track contains another active or draft release"
        end
        completed_prior << number
      end
      if target_count != (target_required ? 1 : 0)
        raise Error, "production target presence does not match the requested operation"
      end
      unless completed_prior.max == previous_number
        raise Error, "supplied fallback is not the highest completed prior release"
      end
    end

    def snapshot(release)
      status = release.status
      raise Error, "Google Play returned an unsupported release state" unless STATES.include?(status)

      {
        "status" => status,
        "user_fraction" => canonical_fraction(release.user_fraction),
        "version_codes" => release.version_codes.map(&:to_s)
      }
    end

    def canonical_fraction(value)
      return nil if value.nil?

      decimal = BigDecimal(value.to_s)
      rendered = format("%.2f", decimal)
      unless REVIEWED_FRACTIONS.include?(rendered) && BigDecimal(rendered) == decimal
        raise Error, "Google Play returned an unreviewed rollout fraction"
      end
      rendered
    rescue ArgumentError
      raise Error, "Google Play returned an invalid rollout fraction"
    end

    def copy_release(source, status:, fraction:)
      @release_factory.call(
        country_targeting: source.country_targeting,
        in_app_update_priority: source.in_app_update_priority,
        name: source.name,
        release_notes: source.release_notes,
        status: status,
        user_fraction: fraction.nil? ? nil : Float(fraction),
        version_codes: source.version_codes.map(&:to_s)
      )
    end

    def begin_edit(package_name)
      edit = @service.insert_edit(package_name, @edit_factory.call)
      identifier = edit&.id
      raise Error, "Google Play returned an unsafe edit ID" unless identifier.is_a?(String) && SAFE_ID.match?(identifier)

      identifier
    end

    def discard_edit(package_name, edit_id)
      @service.delete_edit(package_name, edit_id)
    rescue StandardError
      nil
    end

    def observe_track(package_name, track_name)
      edit_id = begin_edit(package_name)
      begin
        @service.get_edit_track(package_name, edit_id, track_name)
      ensure
        discard_edit(package_name, edit_id)
      end
    end

    def observe_internal_upload(package_name)
      edit_id = begin_edit(package_name)
      begin
        [
          @service.get_edit_track(package_name, edit_id, "internal"),
          @service.list_edit_bundles(package_name, edit_id)
        ]
      ensure
        discard_edit(package_name, edit_id)
      end
    end
  end

  def self.read_private(path, maximum_bytes)
    expanded = File.expand_path(path)
    linked = File.lstat(expanded)
    unless linked.file? && !linked.symlink? && linked.nlink == 1 &&
           (linked.mode & 0o077).zero? && linked.size.positive? && linked.size <= maximum_bytes
      raise Error, "Google Play credential is not bounded owner-only regular storage"
    end
    flags = File::RDONLY | (File.const_defined?(:NOFOLLOW) ? File::NOFOLLOW : 0)
    file = File.open(expanded, flags)
    begin
      before = file.stat
      data = file.read(maximum_bytes + 1)
      after = file.stat
      unless file_identity(linked) == file_identity(before) &&
             file_identity(before) == file_identity(after) && data.bytesize == before.size
        raise Error, "Google Play credential changed while it was read"
      end
      data
    ensure
      file.close
    end
  rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
    raise Error, "Google Play credential could not be opened"
  end

  def self.file_identity(value)
    [
      value.dev,
      value.ino,
      value.size,
      value.mtime.to_i,
      value.mtime.nsec,
      value.ctime.to_i,
      value.ctime.nsec
    ]
  end

  def self.build_service(credential_bytes)
    document = JSON.parse(credential_bytes)
    unless document.is_a?(Hash) && document["type"] == "service_account" &&
           document["token_uri"] == "https://oauth2.googleapis.com/token" &&
           document["client_email"].is_a?(String) && document["client_email"].bytesize <= 320 &&
           document["private_key"].is_a?(String) && document["private_key"].bytesize <= 32 * 1024
      raise Error, "Google Play service-account credential schema is invalid"
    end

    require "google/apis/androidpublisher_v3"
    require "googleauth"
    credentials = Google::Auth::ServiceAccountCredentials.make_creds(
      json_key_io: StringIO.new(credential_bytes),
      scope: Google::Apis::AndroidpublisherV3::AUTH_ANDROIDPUBLISHER
    )
    credentials.fetch_access_token!
    service = Google::Apis::AndroidpublisherV3::AndroidPublisherService.new
    service.authorization = credentials
    service.client_options.application_name = "PakPerk protected rollout"
    factories = {
      edit_factory: -> { Google::Apis::AndroidpublisherV3::AppEdit.new },
      release_factory: ->(**attributes) { Google::Apis::AndroidpublisherV3::TrackRelease.new(**attributes) },
      track_factory: ->(**attributes) { Google::Apis::AndroidpublisherV3::Track.new(**attributes) }
    }
    [service, factories]
  rescue JSON::ParserError, LoadError => error
    raise Error, "Google Play client could not be initialized (#{error.class})"
  end

  def self.canonical_json(value)
    normalized = case value
                 when Hash
                   value.keys.sort.to_h { |key| [key, canonical_json(value.fetch(key))] }
                 when Array
                   value.map { |child| canonical_json(child) }
                 else
                   value
                 end
    normalized
  end

  def self.write_private(path, value)
    raw = (JSON.generate(canonical_json(value)) + "\n").encode("UTF-8")
    raise Error, "Google Play result exceeds its output bound" if raw.bytesize > MAX_OUTPUT_BYTES

    expanded = File.expand_path(path)
    raise Error, "Google Play result output already exists" if File.exist?(expanded) || File.symlink?(expanded)

    flags = File::WRONLY | File::CREAT | File::EXCL |
            (File.const_defined?(:NOFOLLOW) ? File::NOFOLLOW : 0)
    File.open(expanded, flags, 0o600) do |file|
      file.write(raw)
      file.flush
      file.fsync
    end
    metadata = File.lstat(expanded)
    unless metadata.file? && !metadata.symlink? && metadata.nlink == 1 && (metadata.mode & 0o077).zero?
      raise Error, "Google Play result is not owner-only regular storage"
    end
  end

  def self.run(argv)
    options = {}
    parser = OptionParser.new do |value|
      value.on("--operation OPERATION", COMMANDS) { |item| options[:operation] = item }
      value.on("--package-name PACKAGE") { |item| options[:package_name] = item }
      value.on("--version-code CODE") { |item| options[:version_code] = item }
      value.on("--previous-production-version-code CODE") { |item| options[:previous_version_code] = item }
      value.on("--expected-current-fraction FRACTION") { |item| options[:expected_fraction] = item }
      value.on("--target-fraction FRACTION") { |item| options[:target_fraction] = item }
      value.on("--service-account PATH") { |item| options[:service_account] = item }
      value.on("--output PATH") { |item| options[:output] = item }
      value.on("--journal PATH") { |item| options[:journal] = item }
      value.on("--artifact-sha256 SHA256") { |item| options[:artifact_sha256] = item }
    end
    parser.parse!(argv)
    raise Error, "unexpected positional arguments" unless argv.empty?
    required = %i[operation package_name version_code service_account output]
    required << :artifact_sha256 if options[:operation] == "verify-upload"
    if options[:operation] != "verify-upload"
      required += %i[previous_version_code expected_fraction target_fraction journal]
    end
    missing = required.reject { |key| options[key].is_a?(String) && !options[key].empty? }
    raise Error, "missing Google Play rollout options: #{missing.join(', ')}" unless missing.empty?

    credential_bytes = read_private(options[:service_account], MAX_CREDENTIAL_BYTES)
    service, factories = build_service(credential_bytes)
    journal_writer = if options[:journal]
                       ->(value) { write_private(options[:journal], value) }
                     end
    client = Client.new(service: service, journal_writer: journal_writer, **factories)
    result = if options[:operation] == "verify-upload"
               client.verify_internal_upload(
                 package_name: options[:package_name],
                 version_code: options[:version_code],
                 artifact_sha256: options[:artifact_sha256]
               )
             else
               client.transition(
                 package_name: options[:package_name],
                 version_code: options[:version_code],
                 previous_production_version_code: options[:previous_version_code],
                 operation: options[:operation],
                 expected_fraction: options[:expected_fraction],
                 target_fraction: options[:target_fraction]
               )
             end
    write_private(options[:output], result)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    PakPerkGooglePlayRollout.run(ARGV)
  rescue OptionParser::ParseError, PakPerkGooglePlayRollout::Error => error
    warn(error.message)
    exit 1
  rescue StandardError => error
    warn("Google Play rollout failed closed (#{error.class})")
    exit 1
  end
end
