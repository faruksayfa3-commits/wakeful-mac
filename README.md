# Wakeful 👁️ — keep your Mac awake only while it matters

**Close the lid. Your AI agent keeps working. The moment it's done, the Mac goes to sleep.**

Wakeful is a tiny open-source menu-bar app (Swift, universal Intel + Apple Silicon, macOS 12+) for people who leave
Claude Code, Codex, aider, builds, `rsync` or backups running overnight — and don't want a Mac that either
falls asleep at 3 a.m. and kills the job, or stays awake forever and cooks itself in a backpack.

## Why not Amphetamine / Caffeine / KeepingYouAwake?

| | Amphetamine | KeepingYouAwake | Caffeine | **Wakeful** |
|---|:-:|:-:|:-:|:-:|
| Keep awake for a time | ✅ | ✅ | ✅ | ✅ |
| Lid closed, no external display | needs a helper script | ❌ | ❌ | ✅ |
| Stays awake **only while an agent / task is actually working** | ❌ | ❌ | ❌ | ✅ |
| Stays awake while an SSH / Screen Sharing session is open | partial | ❌ | ❌ | ✅ |
| Sleeps on low battery / battery budget / **overheating** / **"backpack mode"** | partial | ❌ | ❌ | ✅ |
| "Looks stuck" detector | ❌ | ❌ | ❌ | ✅ |
| Phone notifications + phone commands (panic button) | ❌ | ❌ | ❌ | ✅ |
| CLI, URL scheme, hooks, Home Assistant webhook | ❌ | CLI | ❌ | ✅ |
| Morning report + shareable night card | ❌ | ❌ | ❌ | ✅ |

## Features

- **Agent-aware.** Watches `claude`, `codex`, `aider`, `gemini`, `cursor-agent` (CPU + child-process activity) and tasks like `rsync`, `xcodebuild`, `cargo`, `brew`, `ffmpeg`. Awake while they work, asleep when they finish. Edit the lists in **Settings → Watch**.
- **Remote-aware.** An open SSH login or Screen Sharing session keeps the Mac up.
- **Safety first.** Auto-sleep when the battery is low, when a *battery budget* is used ("this night may use 30%"), when it overheats, and in **backpack mode** (lid closed + on battery + warming up). Warns before it acts.
- **Stuck detector.** A watched process is alive but silent for 15 minutes → you get a notification instead of a dead night.
- **Lock on lid close.** The Mac stays awake but the screen locks; display turns off; Wi-Fi is kept alive; Low Power Mode on battery.
- **Phone.** Notifications through [ntfy](https://ntfy.sh). Send `off`, `on 2h` or `status` to `<your-topic>-cmd` from your phone — a panic button with no open ports.
- **Timers & schedules.** 30 min … 24 h, "until 07:00", wait-for-process, weekly schedules (**Settings → Schedules**).
- **Night report + card.** Hours awake, battery used, peak temperature, what finished, score and streak — as Markdown and a 1080×1920 PNG you can post.
- **Moods.** The menu-bar icon (eye / cat / robot) sleeps, wakes, gets tired, sweats when hot and smiles when done.
- **Fan check.** Hot at low CPU for 5+ minutes → "dust or a blocked vent?".
- **Hackable.** `wakeful` CLI, `wakeful://` URL scheme (Shortcuts: *Open URL*), `hooks/{on,off,finished,guard}.d/` scripts, webhook for Home Assistant.
- **Settings window** (menu → **Settings…**, ⌘,). Every option without editing JSON: watched agents and tasks, battery and heat limits, lid behaviour, icon, ntfy server and topic, webhook, schedules. Changes apply at once.
- **Health check.** On first launch, and from the menu any time: is the sudoers rule in place, is ntfy reachable, is the CLI installed, is there a temperature sensor and a lid. Anything missing comes with the exact command to fix it. The same in Terminal: `wakeful doctor`.
- **Launch at login** from the menu, and **Check for updates…**, which asks GitHub only when you click it and opens the release page. Nothing auto-installs.

## Install

However you install it, Wakeful needs one sudoers rule, `/etc/sudoers.d/wakeful`, that allows exactly four commands and nothing else:
`pmset -a disablesleep 0|1` and `pmset -a lowpowermode 0|1`. The script that creates it is [`Resources/setup-sudoers.sh`](Resources/setup-sudoers.sh) (a dozen lines, read it first); it asks for your password **once**.

### From source (recommended)

```sh
git clone https://github.com/faruksayfa3-commits/wakeful-mac.git && cd wakeful-mac
./install.sh
```

`install.sh` builds the app, copies it to `/Applications`, adds `~/.local/bin/wakeful`, a login item, and runs the sudoers setup.

### Release zip

Download `Wakeful-<version>.zip` from [Releases](https://github.com/faruksayfa3-commits/wakeful-mac/releases) (compare it with the `.sha256` next to it: `shasum -a 256 Wakeful-*.zip`), unzip, move `Wakeful.app` to `/Applications`, then:

```sh
xattr -dr com.apple.quarantine /Applications/Wakeful.app       # ad-hoc signed, not notarized
/Applications/Wakeful.app/Contents/Resources/setup-sudoers.sh    # the sudoers rule
mkdir -p ~/.local/bin && ln -sf /Applications/Wakeful.app/Contents/Resources/wakeful ~/.local/bin/wakeful   # optional CLI
```

Open Wakeful: the welcome window says if anything is still missing. Turn on **Launch at login** in the menu.

### Homebrew

There is no tap yet. The cask is [`packaging/homebrew/wakeful.rb`](packaging/homebrew/wakeful.rb), and every release attaches a copy with the version and checksum filled in. Put that copy in a tap of your own (`<you>/homebrew-tap/Casks/wakeful.rb`), then:

```sh
brew install --cask <you>/tap/wakeful
/Applications/Wakeful.app/Contents/Resources/setup-sudoers.sh
```

The cask links the `wakeful` command and prints the same notes (sudoers rule, Gatekeeper `xattr`).

## Use

```sh
wakeful on 2h          # stay awake two hours (lid closed too)
wakeful until 07:00
wakeful watch rsync    # until the process exits
wakeful status --json
wakeful off
wakeful doctor         # sudoers rule, phone, CLI, login item, sensors, and how to fix what's missing
```

Or click the eye. **Settings…** in the menu edits everything; the file behind it is `~/Library/Application Support/Wakeful/config.json`.
In the ntfy app, subscribe to the topic from the menu (**Copy phone topic**) — keep it secret, it is the only "password".

## Screenshots

Not taken yet. They will live in [`docs/screenshots/`](docs/screenshots/):

- `menu.png`: the menu-bar menu
- `settings-watch.png`, `settings-schedules.png`: the Settings window
- `health-check.png`: the welcome / health check window
- `night-card.png`: a night card

## Honest limits

- Tested on an Intel MacBook Pro (2017) with macOS 15. The Apple Silicon slice builds but has **not been run on real hardware yet** — reports welcome.
- "Working" is a heuristic (CPU and child processes). An agent waiting only on the network can look idle; raise `activityGraceMin` if that bites.
- Temperatures come from SMC keys (Intel and common Apple Silicon keys); if none exist, Wakeful falls back to macOS thermal pressure.
- Locking the screen uses a private macOS call (`SACLockScreenImmediate`); it may break in a future macOS.
- Not notarized: the release zip is ad-hoc signed, so Gatekeeper needs the `xattr` line above. Building it yourself (`install.sh`) avoids that.
- Launch at login uses `SMAppService` on macOS 13+. If macOS refuses it for an ad-hoc signed app, Wakeful falls back to a LaunchAgent in `~/Library/LaunchAgents`, which is what macOS 12 always uses.

## Română, pe scurt

Wakeful ține MacBook-ul treaz (și cu capacul închis) **doar cât timp rulează ceva important** — un agent AI, un build, un backup — și îl lasă să adoarmă imediat ce termină. Te protejează de supraîncălzire și baterie goală, îți trimite notificări pe telefon și îți face dimineața un raport cu ce a lucrat peste noapte. Open-source, MIT.

## License

MIT
