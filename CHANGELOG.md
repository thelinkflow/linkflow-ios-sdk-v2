# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2026-08-05

### Fixed
- **Advertising and vendor identifiers now reach the server.** The SDK sent
  `idfa`/`idfv` while the server bound `advertisingId`/`vendorId`, so every iOS
  install stored null identifiers. Now sends the canonical spellings; the server
  accepts both for a transition period.
- **Probabilistic attribution now works.** The device fingerprint omitted the IP
  address entirely while the server required one from the request body, which
  disabled fingerprint matching on iOS. The server now takes the IP from the
  connection, and the SDK sends corroborating signals instead.
- Attribution is retried until it succeeds. The first-launch flag was previously
  set *before* the network call, so a launch with no connectivity permanently
  lost the attribution.
- Events are no longer dropped on network failure.

### Added
- `LinkFlowConfig` initializer carrying `appKey`, consent policy and retry
  settings. The legacy `initialize(apiBaseURL:enableLogging:)` still works.
- Durable offline event queue with exponential backoff and full jitter. Each
  event carries a client-generated id the server uses as an idempotency key, so
  retries cannot double-count revenue.
- App key and install token authentication for the attribution endpoints.
- `setConsent(_:)` for GDPR/DMA/CCPA gating. Launches requested before consent
  are buffered and replayed on grant rather than lost.
- `getAttributionResult()`, `pendingEventCount()`, `setTrackingAuthorized()`.
- `AttributionResult` now reports `attributionMethod`, `confidence` and
  `isReinstall`.
- Hardware device model (e.g. `iPhone15,2`) in the fingerprint. `UIDevice.model`
  returns only "iPhone"/"iPad", too coarse for the server's scored matcher.
- Unit tests covering retry policy, event queue, response parsing, URL handling
  and redaction.

### Changed
- **The SDK no longer presents the App Tracking Transparency prompt.** It used to
  call `requestTrackingAuthorization` from inside attribution resolution, showing
  Apple's prompt at a moment the host app did not control and with no priming
  screen — a common App Review rejection. Request authorization yourself, then
  call `setTrackingAuthorized()` if you want the IDFA included. Attribution
  degrades gracefully without it.
- **Install identity moved from `UserDefaults` to the Keychain**, written with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. `UserDefaults` is included
  in device backups, so restoring a backup onto a new device carried the install
  identity across and produced attributed events from a device that never
  installed from the link. Existing 1.x installs are migrated on first launch.
- Default `apiBaseURL` is now `https://thelinkflow.app`, matching the Android and
  React Native SDKs. It previously pointed at `https://api.linkflow.io`.
- `deviceName` is no longer collected — user-set, often a real name, and useless
  for matching.
- Logs redact identifiers. The previous implementation printed full request
  bodies including the IDFA.
- Sources split into a platform-independent core and an Objective-C-facing
  layer, so the core compiles and unit-tests without a Mac.

## [1.0.0] - 2024-11-01

### Added
- Initial standalone release extracted from main LinkFlow repository
- ATT (App Tracking Transparency) permission helper
- IDFA/IDFV retrieval with consent management
- Deferred deep link resolution via device fingerprinting
- Universal Link handling
- In-app event tracking with revenue support
- Reward validation and redemption (Phase 3)
- Swift Package Manager support
- CocoaPods distribution support
