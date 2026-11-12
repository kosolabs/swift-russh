# Changelog

## [0.9.0](https://github.com/kosolabs/swift-russh/compare/v0.8.0...v0.9.0) (2026-11-12)


### ⚠ BREAKING CHANGES

* SSHError.ConnectionFailure has a new case, unreachable, so exhaustive switches over it need to handle it.

### Features

* classify unreachable hosts and report every address tried ([#38](https://github.com/kosolabs/swift-russh/issues/38)) ([476b550](https://github.com/kosolabs/swift-russh/commit/476b5508f839a6240c7c1d446446c96fc705a220))

## [0.8.0](https://github.com/kosolabs/swift-russh/compare/v0.7.0...v0.8.0) (2026-11-09)


### ⚠ BREAKING CHANGES

* make SFTPReader a Sendable struct ([#28](https://github.com/kosolabs/swift-russh/issues/28))
* run scoped closures on the caller's isolation ([#27](https://github.com/kosolabs/swift-russh/issues/27))

### Features

* make SFTPReader a Sendable struct ([#28](https://github.com/kosolabs/swift-russh/issues/28)) ([786fde6](https://github.com/kosolabs/swift-russh/commit/786fde645e8b0b986b7abc0c04461634694a905b))
* run scoped closures on the caller's isolation ([#27](https://github.com/kosolabs/swift-russh/issues/27)) ([8e5fdbc](https://github.com/kosolabs/swift-russh/commit/8e5fdbc7a11542e76a61c6137b7a35374c5a3067))

## [0.7.0](https://github.com/kosolabs/swift-russh/compare/v0.6.0...v0.7.0) (2026-11-09)


### ⚠ BREAKING CHANGES

* use Int for buffer sizes and SFTP limits ([#25](https://github.com/kosolabs/swift-russh/issues/25))
* require a host-key validator and take a Duration timeout ([#24](https://github.com/kosolabs/swift-russh/issues/24))

### Features

* require a host-key validator and take a Duration timeout ([#24](https://github.com/kosolabs/swift-russh/issues/24)) ([1ad37d6](https://github.com/kosolabs/swift-russh/commit/1ad37d65e31822e1a920c726aab1cf9b7a3ae0ec))
* use Int for buffer sizes and SFTP limits ([#25](https://github.com/kosolabs/swift-russh/issues/25)) ([700ff1c](https://github.com/kosolabs/swift-russh/commit/700ff1c3e3ffaa313f75573100e2391941cbf21e))

## [0.6.0](https://github.com/kosolabs/swift-russh/compare/v0.5.0...v0.6.0) (2026-11-09)


### ⚠ BREAKING CHANGES

* see the list above.
* see the list above.

### Features

* give exec channels stdout and stderr sequences ([#21](https://github.com/kosolabs/swift-russh/issues/21)) ([a403327](https://github.com/kosolabs/swift-russh/commit/a403327d726f653ad0283b6f3b771f7942da2c51))
* list directories as named entries and trim SFTPAttributes ([#22](https://github.com/kosolabs/swift-russh/issues/22)) ([a78e879](https://github.com/kosolabs/swift-russh/commit/a78e879b0cbe1c4a5031875d2a69d1adb48584dc))

## [0.5.0](https://github.com/kosolabs/swift-russh/compare/v0.4.0...v0.5.0) (2026-11-09)


### ⚠ BREAKING CHANGES

* see the list above.

### Features

* read and write SFTP files at explicit offsets ([#19](https://github.com/kosolabs/swift-russh/issues/19)) ([4037087](https://github.com/kosolabs/swift-russh/commit/4037087733a542d74c7ccbd6800b5d93ada36763))

## [0.4.0](https://github.com/kosolabs/swift-russh/compare/v0.3.0...v0.4.0) (2026-11-09)


### ⚠ BREAKING CHANGES

* see the list above. Code that relied on typed throws must cast with `as? SSHError` or match with `catch SSHError.<case>`.

### Features

* make SSHError idiomatic ([#17](https://github.com/kosolabs/swift-russh/issues/17)) ([15c1488](https://github.com/kosolabs/swift-russh/commit/15c1488aba4f36ae7f3ff4cc458d621c940e38c2))

## [0.3.0](https://github.com/kosolabs/swift-russh/compare/v0.2.1...v0.3.0) (2026-11-09)


### ⚠ BREAKING CHANGES

* the iterators of SSHChannelData, SFTPReader and SFTPDirectory, SSHSessionChannel.read(from:) and SSHClient.execute(_:) now throw any Error instead of SSHError, so code relying on the typed error must cast it.

### Bug Fixes

* clamp SFTP timestamps instead of crashing on out-of-range dates ([#13](https://github.com/kosolabs/swift-russh/issues/13)) ([6c00466](https://github.com/kosolabs/swift-russh/commit/6c004669c6538f99a222178e107d485ff943c70e))
* throw CancellationError when a stream is cancelled ([#14](https://github.com/kosolabs/swift-russh/issues/14)) ([aeffe8f](https://github.com/kosolabs/swift-russh/commit/aeffe8f9302a2da34f7d209d993a8a0adad597dc))

## [0.2.1](https://github.com/kosolabs/swift-russh/compare/v0.2.0...v0.2.1) (2026-11-09)


### Bug Fixes

* block release PRs until their binary is pinned ([#10](https://github.com/kosolabs/swift-russh/issues/10)) ([e8da10e](https://github.com/kosolabs/swift-russh/commit/e8da10ea2771a193326b3733a0b9617b64396bd1))

## [0.2.0](https://github.com/kosolabs/swift-russh/compare/v0.1.1...v0.2.0) (2026-11-09)


### Features

* give connection failures a reason ([#9](https://github.com/kosolabs/swift-russh/issues/9)) ([fe09507](https://github.com/kosolabs/swift-russh/commit/fe095077d7b25b4f4a5c24b2762083169f72490f))


### Bug Fixes

* fail SFTP requests as soon as the connection is lost ([#7](https://github.com/kosolabs/swift-russh/issues/7)) ([dd47cb5](https://github.com/kosolabs/swift-russh/commit/dd47cb5de67a140901132dc5089958921dab1a48))

## [0.1.1](https://github.com/kosolabs/swift-russh/compare/v0.1.0...v0.1.1) (2026-11-08)


### Bug Fixes

* speed up CI and stop cancelling pin runs ([#5](https://github.com/kosolabs/swift-russh/issues/5)) ([d1d896d](https://github.com/kosolabs/swift-russh/commit/d1d896d94c8cf9b245f0f54e5c0806739e2fb0b4))

## 0.1.0 (2026-11-08)


### Features

* SSH and SFTP client built on russh ([e3ebc16](https://github.com/kosolabs/swift-russh/commit/e3ebc16d7f472995d86521040548a03336ff1c20))


### Bug Fixes

* run Pin Binary on release branch pushes ([#3](https://github.com/kosolabs/swift-russh/issues/3)) ([291a8db](https://github.com/kosolabs/swift-russh/commit/291a8db31a54b37fa1c78b4b6609d6783d4e3132))


### Miscellaneous Chores

* release 0.1.0 ([#4](https://github.com/kosolabs/swift-russh/issues/4)) ([36c8891](https://github.com/kosolabs/swift-russh/commit/36c8891d36e20eee9a772b295265815fdcf913cb))
