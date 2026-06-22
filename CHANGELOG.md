# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.1] - 2026-06-22

### Added
- `netrc-manager.sh` — interactive manager for `~/.netrc` credentials.
- `netrc-manager-check-machine.sh` — sourceable library to validate the
  connection of a `.netrc` machine entry.

### Changed
- Renamed the connection checker to `netrc-manager-check-machine.sh` and turned
  it into a sourced library.

### Removed
- `netrc-check.sh` (replaced by `netrc-manager-check-machine.sh`).

[Unreleased]: https://github.com/MickaelBlet/netrc-manager/compare/v0.0.1...HEAD
[0.0.1]: https://github.com/MickaelBlet/netrc-manager/releases/tag/v0.0.1
