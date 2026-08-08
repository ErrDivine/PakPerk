#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "optparse"
require "uri"

module PakPerkAppStorePhasedRelease
  MAX_RESPONSE_BYTES = 1_048_576
  MAX_PRIVATE_KEY_BYTES = 32 * 1024
  MAX_OUTPUT_BYTES = 64 * 1024
  MAX_ARTIFACT_BYTES = 8 * 1024 * 1024 * 1024
  API_ORIGIN = URI("https://api.appstoreconnect.apple.com")
  SAFE_ID = /\A[A-Za-z0-9-]{1,128}\z/
  SAFE_BUNDLE_ID = /\A[A-Za-z][A-Za-z0-9_-]{0,62}(?:\.[A-Za-z][A-Za-z0-9_-]{0,62}){1,9}\z/
  SAFE_VERSION = /\A[0-9][0-9A-Za-z._+-]{0,63}\z/
  BUILD_NUMBER = /\A[1-9][0-9]{0,9}\z/
  SHA256 = /\A[0-9a-f]{64}\z/
  ISSUER_ID = /\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  OPERATIONS = %w[verify-build verify-update verify-submission observe pause complete].freeze
  PHASED_STATES = %w[INACTIVE ACTIVE PAUSED COMPLETE].freeze

  class Error < StandardError; end

  class Client
    def initialize(
      token:,
      transport: nil,
      journal_writer: nil,
      expected_app_id: nil,
      expected_build_id: nil,
      expected_pre_release_version_id: nil
    )
      raise Error, "App Store Connect token is empty" if token.empty?
      {
        "application" => expected_app_id,
        "build" => expected_build_id,
        "pre-release version" => expected_pre_release_version_id
      }.each do |label, identifier|
        if identifier && !SAFE_ID.match?(identifier)
          raise Error, "expected App Store #{label} ID is invalid"
        end
      end

      @token = token
      @transport = transport || method(:net_http_transport)
      @journal_writer = journal_writer
      @expected_app_id = expected_app_id
      @expected_build_id = expected_build_id
      @expected_pre_release_version_id = expected_pre_release_version_id
    end

    def verify_update(bundle_id:, app_version:, build_number:, previous_public_version:)
      raise Error, "App Store target version is invalid" unless SAFE_VERSION.match?(app_version)
      unless SAFE_VERSION.match?(previous_public_version) && previous_public_version != app_version
        raise Error, "App Store previous public version is invalid"
      end

      app = find_app(bundle_id)
      app_id = safe_id(app.fetch("id"))
      previous = version_state(
        app_id: app_id,
        version: previous_public_version,
        label: "previous public App Store version"
      )
      unless previous.fetch("state") == "READY_FOR_DISTRIBUTION"
        raise Error, "previous App Store version is not exactly READY_FOR_DISTRIBUTION"
      end
      target = version_state(
        app_id: app_id,
        version: app_version,
        label: "target App Store version"
      )
      unless %w[PREPARE_FOR_SUBMISSION READY_FOR_REVIEW].include?(target.fetch("state"))
        raise Error, "target App Store version is not in a reviewed pre-submit state"
      end
      target_build = verify_build(
        app_id: app_id,
        app_version: app_version,
        build_number: build_number
      )
      {
        "app_id" => app_id,
        "previous" => previous,
        "target" => target,
        "target_build" => target_build
      }
    rescue KeyError => error
      raise Error, "App Store Connect response is missing #{error.key.inspect}"
    end

    def verify_uploaded_build(
      bundle_id:,
      app_version:,
      build_number:,
      artifact_sha256:,
      artifact_size:
    )
      unless artifact_sha256.is_a?(String) && SHA256.match?(artifact_sha256)
        raise Error, "uploaded IPA SHA-256 is invalid"
      end
      unless artifact_size.is_a?(Integer) && artifact_size.positive? &&
             artifact_size <= MAX_ARTIFACT_BYTES
        raise Error, "uploaded IPA size is invalid"
      end
      app = find_app(bundle_id)
      app_id = safe_id(app.fetch("id"))
      build = verify_build(
        app_id: app_id,
        app_version: app_version,
        build_number: build_number
      )
      {
        "app_id" => app_id,
        "build" => build,
        "build_upload" => verify_build_upload(
          app_id: app_id,
          app_version: app_version,
          build_number: build_number,
          build_id: build.fetch("build_id"),
          artifact_sha256: artifact_sha256,
          artifact_size: artifact_size
        )
      }
    rescue KeyError => error
      raise Error, "App Store Connect response is missing #{error.key.inspect}"
    end

    def observe(bundle_id:, app_version:, build_number:)
      app = find_app(bundle_id)
      version = exactly_one(
        request(
          "GET",
          "/v1/apps/#{safe_id(app.fetch('id'))}/appStoreVersions",
          query: {
            "filter[platform]" => "IOS",
            "filter[versionString]" => app_version,
            "fields[appStoreVersions]" => "versionString,platform",
            "limit" => "2"
          }
        ),
        "App Store version"
      )
      version_attributes = version.fetch("attributes")
      unless version_attributes.is_a?(Hash) &&
             version_attributes.fetch("versionString") == app_version &&
             version_attributes.fetch("platform") == "IOS"
        raise Error, "App Store version identity does not match the exact target"
      end
      phased = request(
        "GET",
        "/v1/appStoreVersions/#{safe_id(version.fetch('id'))}/appStoreVersionPhasedRelease",
        query: {
          "fields[appStoreVersionPhasedReleases]" =>
            "phasedReleaseState,startDate,totalPauseDuration,currentDayNumber"
        }
      ).fetch("data")
      raise Error, "App Store phased-release response is malformed" unless phased.is_a?(Hash)

      attributes = phased.fetch("attributes")
      raise Error, "App Store phased-release attributes are malformed" unless attributes.is_a?(Hash)
      build = app_store_version_build(
        app_version_id: safe_id(version.fetch("id")),
        app_version: app_version,
        build_number: build_number
      )

      {
        "app_id" => safe_id(app.fetch("id")),
        "app_version_id" => safe_id(version.fetch("id")),
        "build" => build,
        "current_day_number" => optional_integer(attributes["currentDayNumber"]),
        "phased_release_id" => safe_id(phased.fetch("id")),
        "start_date" => optional_string(attributes["startDate"]),
        "state" => phased_state(attributes.fetch("phasedReleaseState")),
        "total_pause_duration" => optional_integer(attributes["totalPauseDuration"])
      }
    rescue KeyError => error
      raise Error, "App Store Connect response is missing #{error.key.inspect}"
    end

    def update(bundle_id:, app_version:, build_number:, operation:)
      target = { "pause" => "PAUSED", "complete" => "COMPLETE" }.fetch(operation) do
        raise Error, "operation must be pause or complete"
      end
      before = observe(
        bundle_id: bundle_id,
        app_version: app_version,
        build_number: build_number
      )
      raise Error, "App Store mutation journal writer is not configured" unless @journal_writer
      if before.fetch("state") == target
        @journal_writer.call(
          "application_id" => bundle_id,
          "app_version" => app_version,
          "build_number" => build_number,
          "before" => before,
          "mutation_status" => "proven_not_committed",
          "operation" => operation,
          "schema" => 1
        )
        return before.merge(
          "previous_state" => before.fetch("state"),
          "idempotent" => true,
          "mutation_status" => "succeeded_verified"
        )
      end
      unless before.fetch("state") == "ACTIVE"
        raise Error, "cannot #{operation} phased release from #{before.fetch('state')}"
      end

      @journal_writer.call(
        "application_id" => bundle_id,
        "app_version" => app_version,
        "build_number" => build_number,
        "before" => before,
        "mutation_status" => "unknown_reconcile_required",
        "operation" => operation,
        "schema" => 1
      )

      response = request(
        "PATCH",
        "/v1/appStoreVersionPhasedReleases/#{before.fetch('phased_release_id')}",
        body: {
          "data" => {
            "type" => "appStoreVersionPhasedReleases",
            "id" => before.fetch("phased_release_id"),
            "attributes" => { "phasedReleaseState" => target }
          }
        }
      )
      patched = phased_state(response.dig("data", "attributes", "phasedReleaseState"))
      raise Error, "App Store Connect did not apply requested phased-release state" unless patched == target

      after = observe(
        bundle_id: bundle_id,
        app_version: app_version,
        build_number: build_number
      )
      stable_ids = %w[app_id app_version_id phased_release_id].all? do |key|
        before.fetch(key) == after.fetch(key)
      end
      unless stable_ids && after.fetch("state") == target
        raise Error, "App Store Connect postflight state does not match the requested transition"
      end
      after.merge(
        "previous_state" => before.fetch("state"),
        "idempotent" => false,
        "mutation_status" => "succeeded_verified"
      )
    end

    private

    def verify_build(app_id:, app_version:, build_number:)
      document = request(
        "GET",
        "/v1/builds",
        query: {
          "filter[app]" => app_id,
          "filter[preReleaseVersion.version]" => app_version,
          "filter[version]" => build_number,
          "fields[builds]" => "version,processingState,preReleaseVersion",
          "fields[preReleaseVersions]" => "version,platform",
          "include" => "preReleaseVersion",
          "limit" => "2"
        }
      )
      record = exactly_one(document, "uploaded App Store build")
      unless record.fetch("type") == "builds"
        raise Error, "uploaded App Store build resource type is invalid"
      end
      attributes = record.fetch("attributes")
      unless attributes.is_a?(Hash) && attributes.fetch("version") == build_number &&
             attributes.fetch("processingState") == "VALID"
        raise Error, "uploaded App Store build is not the exact processed build"
      end
      build_id = safe_id(record.fetch("id"))
      relationship = record.dig("relationships", "preReleaseVersion", "data")
      unless relationship.is_a?(Hash) && relationship["type"] == "preReleaseVersions"
        raise Error, "uploaded App Store build pre-release relationship type is invalid"
      end
      relationship_id = safe_id(relationship.fetch("id"))
      included = document["included"]
      unless included.is_a?(Array) && included.length == 1 &&
             included.first.is_a?(Hash) && included.first["type"] == "preReleaseVersions" &&
             safe_id(included.first["id"]) == relationship_id &&
             included.first.dig("attributes", "version") == app_version &&
             included.first.dig("attributes", "platform") == "IOS"
        raise Error, "uploaded App Store build is not bound to the exact app version"
      end
      verify_expected_build_identity(
        build_id: build_id,
        pre_release_version_id: relationship_id
      )
      {
        "build_id" => build_id,
        "build_number" => build_number,
        "pre_release_version_id" => relationship_id,
        "processing_state" => "VALID"
      }
    rescue KeyError => error
      raise Error, "App Store Connect response is missing #{error.key.inspect}"
    end

    def verify_build_upload(
      app_id:,
      app_version:,
      build_number:,
      build_id:,
      artifact_sha256:,
      artifact_size:
    )
      document = request(
        "GET",
        "/v1/apps/#{safe_id(app_id)}/buildUploads",
        query: {
          "filter[cfBundleShortVersionString]" => app_version,
          "filter[cfBundleVersion]" => build_number,
          "filter[platform]" => "IOS",
          "filter[state]" => "COMPLETE",
          "fields[buildUploads]" =>
            "cfBundleShortVersionString,cfBundleVersion,state,platform,build,assetFile",
          "fields[builds]" => "version",
          "fields[buildUploadFiles]" =>
            "assetDeliveryState,assetType,fileSize,sourceFileChecksums,uti",
          "include" => "build,assetFile",
          "limit" => "2"
        }
      )
      upload = exactly_one(document, "completed App Store build upload")
      unless upload.fetch("type") == "buildUploads"
        raise Error, "App Store build upload resource type is invalid"
      end
      attributes = upload.fetch("attributes")
      state = attributes.fetch("state") if attributes.is_a?(Hash)
      unless attributes.is_a?(Hash) &&
             attributes.fetch("cfBundleShortVersionString") == app_version &&
             attributes.fetch("cfBundleVersion") == build_number &&
             attributes.fetch("platform") == "IOS" &&
             state.is_a?(Hash) && state.fetch("state") == "COMPLETE" &&
             (state["errors"].nil? || state["errors"] == [])
        raise Error, "App Store build upload is not the exact completed iOS upload"
      end

      relationship_build = upload.dig("relationships", "build", "data")
      relationship_asset = upload.dig("relationships", "assetFile", "data")
      unless relationship_build.is_a?(Hash) && relationship_build["type"] == "builds" &&
             safe_id(relationship_build["id"]) == build_id &&
             relationship_asset.is_a?(Hash) &&
             relationship_asset["type"] == "buildUploadFiles"
        raise Error, "App Store build upload relationships are not bound to the exact build"
      end
      asset_file_id = safe_id(relationship_asset.fetch("id"))

      included = document.fetch("included")
      unless included.is_a?(Array) && included.length == 2 &&
             included.all? { |record| record.is_a?(Hash) }
        raise Error, "App Store build upload included resources are not exact"
      end
      included_builds = included.select do |record|
        record["type"] == "builds" && record["id"] == build_id
      end
      included_assets = included.select do |record|
        record["type"] == "buildUploadFiles" && record["id"] == asset_file_id
      end
      unless included_builds.length == 1 && included_assets.length == 1 &&
             included_builds.first.dig("attributes", "version") == build_number
        raise Error, "App Store build upload included resources do not match the exact build"
      end

      asset_attributes = included_assets.first.fetch("attributes")
      asset_state = asset_attributes.fetch("assetDeliveryState") if asset_attributes.is_a?(Hash)
      checksum = asset_attributes.dig("sourceFileChecksums", "file") if asset_attributes.is_a?(Hash)
      remote_hash = checksum["hash"] if checksum.is_a?(Hash)
      unless asset_attributes.is_a?(Hash) &&
             asset_attributes.fetch("assetType") == "ASSET" &&
             asset_attributes.fetch("uti") == "com.apple.ipa" &&
             asset_attributes.fetch("fileSize") == artifact_size &&
             asset_state.is_a?(Hash) && asset_state.fetch("state") == "COMPLETE" &&
             (asset_state["errors"].nil? || asset_state["errors"] == []) &&
             checksum.is_a?(Hash) && checksum.fetch("algorithm") == "SHA_256" &&
             remote_hash.is_a?(String) && /\A[0-9A-Fa-f]{64}\z/.match?(remote_hash) &&
             remote_hash.downcase == artifact_sha256
        raise Error, "App Store uploaded IPA bytes do not match the signed candidate"
      end

      {
        "asset_file" => {
          "asset_delivery_state" => "COMPLETE",
          "asset_type" => "ASSET",
          "build_upload_file_id" => asset_file_id,
          "file_size" => artifact_size,
          "source_file_checksum" => {
            "algorithm" => "SHA_256",
            "hash" => artifact_sha256
          },
          "uti" => "com.apple.ipa"
        },
        "build_id" => build_id,
        "build_upload_id" => safe_id(upload.fetch("id")),
        "state" => "COMPLETE"
      }
    rescue KeyError => error
      raise Error, "App Store Connect response is missing #{error.key.inspect}"
    end

    def app_store_version_build(app_version_id:, app_version:, build_number:)
      document = request(
        "GET",
        "/v1/appStoreVersions/#{safe_id(app_version_id)}/build",
        query: {
          "fields[builds]" => "version,processingState,preReleaseVersion",
          "fields[preReleaseVersions]" => "version,platform",
          "include" => "preReleaseVersion"
        }
      )
      record = document.fetch("data")
      unless record.is_a?(Hash) && record.fetch("type") == "builds"
        raise Error, "App Store version build relationship is malformed"
      end
      attributes = record.fetch("attributes")
      unless attributes.is_a?(Hash) && attributes.fetch("version") == build_number &&
             attributes.fetch("processingState") == "VALID"
        raise Error, "App Store version is not bound to the exact processed build"
      end
      build_id = safe_id(record.fetch("id"))
      relationship = record.dig("relationships", "preReleaseVersion", "data")
      unless relationship.is_a?(Hash) && relationship["type"] == "preReleaseVersions"
        raise Error, "App Store version build pre-release relationship type is invalid"
      end
      relationship_id = safe_id(relationship.fetch("id"))
      included = document["included"]
      unless included.is_a?(Array) && included.length == 1 &&
             included.first.is_a?(Hash) && included.first["type"] == "preReleaseVersions" &&
             safe_id(included.first["id"]) == relationship_id &&
             included.first.dig("attributes", "version") == app_version &&
             included.first.dig("attributes", "platform") == "IOS"
        raise Error, "App Store version build is not bound to the exact pre-release version"
      end
      verify_expected_build_identity(
        build_id: build_id,
        pre_release_version_id: relationship_id
      )
      {
        "build_id" => build_id,
        "build_number" => build_number,
        "processing_state" => "VALID"
      }
    rescue KeyError => error
      raise Error, "App Store Connect response is missing #{error.key.inspect}"
    end

    def verify_expected_build_identity(build_id:, pre_release_version_id:)
      if @expected_build_id && build_id != @expected_build_id
        raise Error, "App Store build resource ID does not match the upload handoff"
      end
      if @expected_pre_release_version_id &&
         pre_release_version_id != @expected_pre_release_version_id
        raise Error, "App Store pre-release version ID does not match the upload handoff"
      end
    end

    def find_app(bundle_id)
      app = exactly_one(
        request(
          "GET",
          "/v1/apps",
          query: {
            "filter[bundleId]" => bundle_id,
            "fields[apps]" => "bundleId",
            "limit" => "2"
          }
        ),
        "App Store application"
      )
      attributes = app.fetch("attributes")
      unless attributes.is_a?(Hash) && attributes.fetch("bundleId") == bundle_id
        raise Error, "App Store application identity does not match the exact bundle"
      end
      observed_id = safe_id(app.fetch("id"))
      if @expected_app_id && observed_id != @expected_app_id
        raise Error, "App Store application resource ID does not match the upload handoff"
      end
      app
    rescue KeyError => error
      raise Error, "App Store Connect response is missing #{error.key.inspect}"
    end

    def version_state(app_id:, version:, label:)
      record = exactly_one(
        request(
          "GET",
          "/v1/apps/#{safe_id(app_id)}/appStoreVersions",
          query: {
            "filter[platform]" => "IOS",
            "filter[versionString]" => version,
            "fields[appStoreVersions]" => "versionString,platform,appVersionState",
            "limit" => "2"
          }
        ),
        label
      )
      attributes = record.fetch("attributes")
      unless attributes.is_a?(Hash) && attributes.fetch("versionString") == version &&
             attributes.fetch("platform") == "IOS" &&
             attributes.fetch("appVersionState").is_a?(String)
        raise Error, "#{label} state response is malformed"
      end
      {
        "app_version_id" => safe_id(record.fetch("id")),
        "state" => attributes.fetch("appVersionState"),
        "version" => version
      }
    end

    def exactly_one(document, label)
      data = document["data"]
      raise Error, "#{label} response is malformed" unless data.is_a?(Array)
      raise Error, "#{label} lookup returned #{data.length} records" unless data.length == 1

      record = data.first
      raise Error, "#{label} record is malformed" unless record.is_a?(Hash)

      record
    end

    def request(method, path, query: nil, body: nil)
      uri = API_ORIGIN.dup
      uri.path = path
      uri.query = URI.encode_www_form(query) if query
      headers = {
        "Accept" => "application/json",
        "Authorization" => "Bearer #{@token}"
      }
      payload = nil
      if body
        headers["Content-Type"] = "application/json"
        payload = JSON.generate(body)
      end
      status, raw = @transport.call(method, uri, headers, payload)
      unless status.between?(200, 299)
        raise Error, "App Store Connect #{method} #{path} returned HTTP #{status}"
      end
      if raw.bytesize > MAX_RESPONSE_BYTES
        raise Error, "App Store Connect response exceeded #{MAX_RESPONSE_BYTES} bytes"
      end

      parsed = JSON.parse(raw)
      raise Error, "App Store Connect response root is not an object" unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError
      raise Error, "App Store Connect response is not valid JSON"
    end

    def net_http_transport(method, uri, headers, payload)
      request_class = { "GET" => Net::HTTP::Get, "PATCH" => Net::HTTP::Patch }.fetch(method)
      request = request_class.new(uri)
      headers.each { |key, value| request[key] = value }
      request.body = payload if payload
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 15
      http.write_timeout = 15
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      raw = +""
      status = nil
      http.request(request) do |response|
        status = Integer(response.code, 10)
        response.read_body do |chunk|
          if raw.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES
            raise Error, "App Store Connect response exceeded #{MAX_RESPONSE_BYTES} bytes"
          end

          raw << chunk
        end
      end
      [status, raw]
    end

    def safe_id(value)
      unless value.is_a?(String) && SAFE_ID.match?(value)
        raise Error, "App Store Connect returned an unsafe resource ID"
      end

      value
    end

    def phased_state(value)
      unless PHASED_STATES.include?(value)
        raise Error, "App Store Connect returned an unsupported phased-release state"
      end

      value
    end

    def optional_integer(value)
      return nil if value.nil?
      unless value.is_a?(Integer) && !value.is_a?(TrueClass) && !value.is_a?(FalseClass) && value >= 0
        raise Error, "App Store Connect returned an invalid integer attribute"
      end

      value
    end

    def optional_string(value)
      return nil if value.nil?
      unless value.is_a?(String) && value.bytesize <= 128
        raise Error, "App Store Connect returned an invalid string attribute"
      end

      value
    end
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

  def self.read_private(path, maximum_bytes)
    expanded = File.expand_path(path)
    linked = File.lstat(expanded)
    unless linked.file? && !linked.symlink? && linked.nlink == 1 &&
           (linked.mode & 0o077).zero? && linked.size.positive? && linked.size <= maximum_bytes
      raise Error, "App Store private key is not bounded owner-only regular storage"
    end
    flags = File::RDONLY | (File.const_defined?(:NOFOLLOW) ? File::NOFOLLOW : 0)
    file = File.open(expanded, flags)
    begin
      before = file.stat
      data = file.read(maximum_bytes + 1)
      after = file.stat
      unless file_identity(linked) == file_identity(before) &&
             file_identity(before) == file_identity(after) && data.bytesize == before.size
        raise Error, "App Store private key changed while it was read"
      end
      data
    ensure
      file.close
    end
  rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
    raise Error, "App Store private key could not be opened"
  end

  def self.build_token(key_id:, issuer_id:, private_key_path:, now: Time.now.to_i)
    raise Error, "App Store key ID is invalid" unless /\A[A-Z0-9]{10}\z/.match?(key_id)
    raise Error, "App Store issuer ID is invalid" unless ISSUER_ID.match?(issuer_id)

    key_bytes = read_private(private_key_path, MAX_PRIVATE_KEY_BYTES)
    require "jwt"
    key = OpenSSL::PKey::EC.new(key_bytes)
    JWT.encode(
      { "iss" => issuer_id, "iat" => now - 5, "exp" => now + 600, "aud" => "appstoreconnect-v1" },
      key,
      "ES256",
      { "kid" => key_id, "typ" => "JWT" }
    )
  rescue OpenSSL::PKey::PKeyError, LoadError => error
    raise Error, "App Store private key could not be loaded: #{error.class}"
  end

  def self.result_document(
    client:,
    bundle_id:,
    app_version:,
    build_number:,
    operation:,
    previous_public_version: nil,
    artifact_sha256: nil,
    artifact_size: nil
  )
    if operation == "verify-build"
      uploaded = client.verify_uploaded_build(
        bundle_id: bundle_id,
        app_version: app_version,
        build_number: build_number,
        artifact_sha256: artifact_sha256,
        artifact_size: artifact_size
      )
      return {
        "application_id" => bundle_id,
        "app_version" => app_version,
        "build_number" => build_number,
        "operation" => operation,
        "schema" => 1,
        "upload_verification" => uploaded,
        "verification_status" => "succeeded_verified"
      }
    end
    if operation == "verify-update"
      prior = client.verify_update(
        bundle_id: bundle_id,
        app_version: app_version,
        build_number: build_number,
        previous_public_version: previous_public_version
      )
      return {
        "application_id" => bundle_id,
        "app_version" => app_version,
        "build_number" => build_number,
        "mutation_status" => "unknown_reconcile_required",
        "operation" => operation,
        "update_preflight" => prior,
        "schema" => 1
      }
    end

    phased = if %w[observe verify-submission].include?(operation)
               observed = client.observe(
                 bundle_id: bundle_id,
                 app_version: app_version,
                 build_number: build_number
               )
               expected = operation == "observe" ? "ACTIVE" : "INACTIVE"
               unless observed.fetch("state") == expected
                 raise Error, "#{operation} requires an #{expected} phased release"
               end
               observed
             else
               client.update(
                 bundle_id: bundle_id,
                 app_version: app_version,
                 build_number: build_number,
                 operation: operation
               )
             end
    {
      "application_id" => bundle_id,
      "app_version" => app_version,
      "build_number" => build_number,
      "operation" => operation,
      "phased_release" => phased,
      "schema" => 1
    }
  end

  def self.canonical_json(value)
    case value
    when Hash
      value.keys.sort.to_h { |key| [key, canonical_json(value.fetch(key))] }
    when Array
      value.map { |child| canonical_json(child) }
    else
      value
    end
  end

  def self.write_private(path, value)
    raw = (JSON.generate(canonical_json(value)) + "\n").encode("UTF-8")
    raise Error, "App Store result exceeds its output bound" if raw.bytesize > MAX_OUTPUT_BYTES

    expanded = File.expand_path(path)
    raise Error, "App Store result output already exists" if File.exist?(expanded) || File.symlink?(expanded)

    flags = File::WRONLY | File::CREAT | File::EXCL |
            (File.const_defined?(:NOFOLLOW) ? File::NOFOLLOW : 0)
    File.open(expanded, flags, 0o600) do |file|
      file.write(raw)
      file.flush
      file.fsync
    end
    metadata = File.lstat(expanded)
    unless metadata.file? && !metadata.symlink? && metadata.nlink == 1 &&
           (metadata.mode & 0o077).zero?
      raise Error, "App Store result is not owner-only regular storage"
    end
  end

  def self.run(argv)
    options = {}
    parser = OptionParser.new do |value|
      value.on("--operation OPERATION", OPERATIONS) { |item| options[:operation] = item }
      value.on("--bundle-id BUNDLE_ID") { |item| options[:bundle_id] = item }
      value.on("--app-version VERSION") { |item| options[:app_version] = item }
      value.on("--build-number BUILD") { |item| options[:build_number] = item }
      value.on("--artifact-sha256 SHA256") { |item| options[:artifact_sha256] = item }
      value.on("--artifact-size BYTES") { |item| options[:artifact_size] = item }
      value.on("--previous-public-version VERSION") { |item| options[:previous_public_version] = item }
      value.on("--key-id KEY_ID") { |item| options[:key_id] = item }
      value.on("--issuer-id ISSUER_ID") { |item| options[:issuer_id] = item }
      value.on("--private-key PATH") { |item| options[:private_key_path] = item }
      value.on("--output PATH") { |item| options[:output] = item }
      value.on("--journal PATH") { |item| options[:journal] = item }
      value.on("--expected-app-id ID") { |item| options[:expected_app_id] = item }
      value.on("--expected-build-id ID") { |item| options[:expected_build_id] = item }
      value.on("--expected-pre-release-version-id ID") do |item|
        options[:expected_pre_release_version_id] = item
      end
    end
    parser.parse!(argv)
    raise Error, "unexpected positional arguments" unless argv.empty?
    required = %i[operation bundle_id app_version build_number key_id issuer_id private_key_path output]
    missing = required.reject { |key| options[key].is_a?(String) && !options[key].empty? }
    raise Error, "missing options: #{missing.join(', ')}" unless missing.empty?
    raise Error, "bundle ID is invalid" unless SAFE_BUNDLE_ID.match?(options[:bundle_id])
    raise Error, "app version is invalid" unless SAFE_VERSION.match?(options[:app_version])
    raise Error, "build number is invalid" unless BUILD_NUMBER.match?(options[:build_number])
    if options[:operation] == "verify-build"
      unless options[:artifact_sha256].is_a?(String) && SHA256.match?(options[:artifact_sha256])
        raise Error, "artifact SHA-256 is required for upload verification"
      end
      unless options[:artifact_size].is_a?(String) &&
             /\A[1-9][0-9]{0,15}\z/.match?(options[:artifact_size]) &&
             Integer(options[:artifact_size], 10) <= MAX_ARTIFACT_BYTES
        raise Error, "artifact size is required for upload verification"
      end
      options[:artifact_size] = Integer(options[:artifact_size], 10)
    elsif options.key?(:artifact_sha256) || options.key?(:artifact_size)
      raise Error, "artifact evidence is only valid for verify-build"
    end
    if options[:operation] == "verify-update"
      unless options[:previous_public_version].is_a?(String) &&
             SAFE_VERSION.match?(options[:previous_public_version]) &&
             options[:previous_public_version] != options[:app_version]
        raise Error, "previous public App Store version is invalid"
      end
    elsif options.key?(:previous_public_version)
      raise Error, "previous public version is only valid for verify-update"
    end
    if %w[pause complete].include?(options[:operation]) &&
       (!options[:journal].is_a?(String) || options[:journal].empty?)
      raise Error, "mutation journal is required for App Store updates"
    end

    token = build_token(
      key_id: options[:key_id],
      issuer_id: options[:issuer_id],
      private_key_path: options[:private_key_path]
    )
    journal_writer = if options[:journal]
                       ->(value) { write_private(options[:journal], value) }
                     end
    client = Client.new(
      token: token,
      journal_writer: journal_writer,
      expected_app_id: options[:expected_app_id],
      expected_build_id: options[:expected_build_id],
      expected_pre_release_version_id: options[:expected_pre_release_version_id]
    )
    result = result_document(
      client: client,
      bundle_id: options[:bundle_id],
      app_version: options[:app_version],
      build_number: options[:build_number],
      operation: options[:operation],
      previous_public_version: options[:previous_public_version],
      artifact_sha256: options[:artifact_sha256],
      artifact_size: options[:artifact_size]
    )
    write_private(options[:output], result)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    PakPerkAppStorePhasedRelease.run(ARGV)
  rescue OptionParser::ParseError, PakPerkAppStorePhasedRelease::Error => error
    warn(error.message)
    exit 1
  rescue StandardError => error
    warn("App Store rollout failed closed (#{error.class})")
    exit 1
  end
end
