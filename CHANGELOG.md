# Changelog

All notable changes to Wakeful. Versions follow [semantic versioning](https://semver.org).

## [1.1.0] — 2026-10-29

### Added
- **Settings window** (menu → Settings…, ⌘,): every option in `config.json` in five tabs — General, Watch (agent and task lists), Safety (battery, budget, temperatures, thermal pressure, backpack mode), Phone (ntfy server and topic, Home Assistant webhook) and Schedules (weekdays + start/end). Changes apply immediately.
- **Welcome + Health check**: on first launch, and from the menu, a window shows whether the sudoers rule works (checked with `sudo -n -l`, nothing is changed), the phone topic, and the exact command to fix anything missing.
- **`wakeful doctor`**: the same checks in Terminal; exits 1 when something must be fixed.
- **Launch at login** toggle in the menu (SMAppService on macOS 13+, a LaunchAgent on macOS 12).
- **Check for updates…**: asks GitHub for the latest release only when clicked and opens its page if it is newer. Nothing is downloaded or installed.
- Release builds: pushing a `v*` tag publishes `Wakeful-<version>.zip` and its `.sha256` on GitHub Releases. Homebrew cask in `packaging/homebrew/wakeful.rb`.
- The app bundle carries the `wakeful` CLI and `setup-sudoers.sh`, so zip and Homebrew installs work without a source checkout.

### Fixed
- Remote sessions no longer start and stop a session every tick when a remote-desktop app hovers around its CPU threshold: a session only counts as ended after 60 s without a sighting.
- The "looks stuck" detector now works for tasks (`rsync`, `cargo`…), measured on CPU instead of on mere existence.
- Phone commands sent while the listener reconnects are no longer lost (`since=<last message id>`); commands older than 10 minutes are ignored instead of replayed.
- Helpers under `~/Library/Application Support/Claude/` or inside app bundles no longer count as the `claude` agent; native installs such as `~/.local/share/claude/versions/2.1.3` still do.
- A schedule whose start equals its end now means the whole day (it was never active).
- Report file names and streak keys use `en_US_POSIX` dates, independent of the user's calendar and clock settings.
- A missing sudoers rule notifies once per episode instead of every 10 seconds.
- A watched tool that exits and starts again begins with a clean activity and stuck state.
- Changing the ntfy server, topic or "phone commands" now reconnects the listener right away.

### Changed
- `install.sh` creates the sudoers rule through `Resources/setup-sudoers.sh`. The rule is identical.

## [1.0.0] — 2026-10-29

First public release: agent-aware keep-awake for the menu bar, lid closed included, with battery, heat and backpack guards, stuck detector, ntfy notifications and phone commands, schedules, CLI, URL scheme, hooks, Home Assistant webhook, night report and shareable card.
