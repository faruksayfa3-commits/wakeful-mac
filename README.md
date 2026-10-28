# Vigil 👁️ — keep your Mac awake only while it matters

**Close the lid. Your AI agent keeps working. The moment it's done, the Mac goes to sleep.**

Vigil is a tiny open-source menu-bar app (Swift, universal Intel + Apple Silicon, macOS 12+) for people who leave
Claude Code, Codex, aider, builds, `rsync` or backups running overnight — and don't want a Mac that either
falls asleep at 3 a.m. and kills the job, or stays awake forever and cooks itself in a backpack.

## Why not Amphetamine / Caffeine / KeepingYouAwake?

| | Amphetamine | KeepingYouAwake | Caffeine | **Vigil** |
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

- **Agent-aware.** Watches `claude`, `codex`, `aider`, `gemini`, `cursor-agent` (CPU + child-process activity) and tasks like `rsync`, `xcodebuild`, `cargo`, `brew`, `ffmpeg`. Awake while they work, asleep when they finish. Edit the lists in the config.
- **Remote-aware.** An open SSH login or Screen Sharing session keeps the Mac up.
- **Safety first.** Auto-sleep when the battery is low, when a *battery budget* is used ("this night may use 30%"), when it overheats, and in **backpack mode** (lid closed + on battery + warming up). Warns before it acts.
- **Stuck detector.** A watched process is alive but silent for 15 minutes → you get a notification instead of a dead night.
- **Lock on lid close.** The Mac stays awake but the screen locks; display turns off; Wi-Fi is kept alive; Low Power Mode on battery.
- **Phone.** Notifications through [ntfy](https://ntfy.sh). Send `off`, `on 2h` or `status` to `<your-topic>-cmd` from your phone — a panic button with no open ports.
- **Timers & schedules.** 30 min … 24 h, "until 07:00", wait-for-process, weekly schedules in the config.
- **Night report + card.** Hours awake, battery used, peak temperature, what finished, score and streak — as Markdown and a 1080×1920 PNG you can post.
- **Moods.** The menu-bar icon (eye / cat / robot) sleeps, wakes, gets tired, sweats when hot and smiles when done.
- **Fan check.** Hot at low CPU for 5+ minutes → "dust or a blocked vent?".
- **Hackable.** `vigil` CLI, `vigil://` URL scheme (Shortcuts: *Open URL*), `hooks/{on,off,finished,guard}.d/` scripts, webhook for Home Assistant.

## Install

```sh
git clone https://github.com/faruksayfa3-commits/vigil-mac.git && cd vigil-mac
./install.sh
```

`install.sh` builds the app, copies it to `/Applications`, adds `~/.local/bin/vigil`, a login item, and asks for your password **once** to create `/etc/sudoers.d/vigil` — a rule that allows exactly four commands and nothing else:
`pmset -a disablesleep 0|1` and `pmset -a lowpowermode 0|1`. Read it before you run it; it's ~40 lines.

## Use

```sh
vigil on 2h          # stay awake two hours (lid closed too)
vigil until 07:00
vigil watch rsync    # until the process exits
vigil status --json
vigil off
```

Or click the eye. Settings live in `~/Library/Application Support/Vigil/config.json`.
In the ntfy app, subscribe to the topic from the menu (**Copy phone topic**) — keep it secret, it is the only "password".

## Honest limits

- Tested on an Intel MacBook Pro (2017) with macOS 15. The Apple Silicon slice builds but has **not been run on real hardware yet** — reports welcome.
- "Working" is a heuristic (CPU and child processes). An agent waiting only on the network can look idle; raise `activityGraceMin` if that bites.
- Temperatures come from SMC keys (Intel and common Apple Silicon keys); if none exist, Vigil falls back to macOS thermal pressure.
- Locking the screen uses a private macOS call (`SACLockScreenImmediate`); it may break in a future macOS.
- Not notarized: build it yourself (that is what `install.sh` does).

## Română, pe scurt

Vigil ține MacBook-ul treaz (și cu capacul închis) **doar cât timp rulează ceva important** — un agent AI, un build, un backup — și îl lasă să adoarmă imediat ce termină. Te protejează de supraîncălzire și baterie goală, îți trimite notificări pe telefon și îți face dimineața un raport cu ce a lucrat peste noapte. Open-source, MIT.

## License

MIT
