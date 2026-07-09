# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-07-09

First release intended for use by others, not just the author.

### Added
- `--help`, `--version`, and `--install` command-line flags.
- Multi-distro dependency installation (apt, dnf, yum, pacman, zypper, apk).
- README with modules table, requirements, quick start, and tmux cheatsheet.
- MIT license.
- GitHub Actions CI running `bash -n` and shellcheck on every push and PR.

### Changed
- Dependencies are never installed automatically; missing tools are reported
  and installation is gated behind `--install` plus a confirmation prompt.
- The SECURITY module now tails ssh/sshd activity instead of generic
  priority-3 errors.
- An existing `monitor` tmux session is offered for re-attach instead of being
  killed silently.
- `ncdu` runs with `-x` to stay on the root filesystem.
- tmux options are scoped to the session rather than set globally.

### Removed
- `curl | bash` installation of lazydocker; it is now detected and users are
  pointed at the official install docs.

### Fixed
- Pane-index increment no longer aborts the script under `set -e`.

[0.2.0]: https://github.com/Amahdip/devops-toolbox/releases/tag/v0.2.0
