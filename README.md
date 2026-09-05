# Presets for Omarchy

Launch a saved set of windows from the Omarchy bar, or build a profile that
sets up several workspaces at once. Presets can also be assigned to numbered
keyboard shortcuts, and one profile can optionally run when Omarchy starts.

![Launching a preset, then a two-workspace profile with live progress](docs/opening-them-up.gif)

## What it does

- Saves ordered groups of terminal commands, web apps, and custom commands.
- Opens windows in Omarchy's scrolling layout and preserves their configured
  left-to-right order.
- Maps presets to workspaces in reusable profiles.
- Shows live progress while a profile launches.
- Offers nine quick-launch slots for presets and nine for profiles.
- Can run one explicitly selected default profile after login.
- Stores everything as readable JSON outside the plugin directory.

<table>
<tr>
<td><img src="docs/preset-list.png" alt="Preset list with tabs, shortcut slots, and quick actions"></td>
<td><img src="docs/evening-hero.png" alt="A privacy-safe Evening preset arranged across the scrolling layout"></td>
</tr>
</table>

## Requirements

Presets requires the Quickshell-based Omarchy shell and the `omarchy plugin`
and `omarchy hook` commands. It has been tested with:

- Omarchy 4.0.2
- Quickshell 0.3.1
- Hyprland 0.56.2

There are no extra package dependencies beyond a current Omarchy install. The
plugin uses tools Omarchy already provides or depends on: Bash, `jq`, `flock`, `luac`,
`hyprctl`, `omarchy-launch-terminal`, `omarchy-launch-webapp`, and
`omarchy-notification-send`. Applications and commands saved in your presets
are, naturally, your responsibility.

## Install

```bash
omarchy plugin add https://github.com/Kyotroo/omarchy-workspace-profiles.git
omarchy plugin enable kdm.presets --section left --after omarchy.workspaces
```

The second command places Presets in the left side of the bar, immediately
after Workspaces. Open it by clicking the bar icon.

![Enabling the plugin and completing its one-question shortcut setup](docs/install-clip.gif)

### First run and configuration consent

On first open, Presets asks whether it may add its quick-launch bindings to
`~/.config/hypr/bindings.lua`. Accepting appends one clearly marked block. It
first makes a temporary backup, checks the result with `luac`, reloads
Hyprland, and restores the original file if either validation step fails.
Declining leaves the file untouched.

The post-boot hook is separate: it is installed only when you explicitly mark
a profile as the default. Its path is:

```text
~/.config/omarchy/hooks/post-boot.d/kdm-presets-activate-default-profile.sh
```

## Quick start

1. Open Presets and choose **New preset** (`n`).
2. After saving the name, the new preset opens directly in its editor. Choose
   **Add window** (`a`) and add any combination of:
   - **Terminal** — a command opened in a terminal, such as `btop`.
   - **Web app** — an installed Omarchy web app or a custom URL such as
     `https://omarchy.org`.
   - **Custom** — any shell command, run as your user.
3. Reorder entries with `Shift+J` / `Shift+K`; this controls their
   left-to-right order.
4. Press `Enter` on the preset to launch it.

![Building and reordering a preset, then assigning a shortcut](docs/setting-up-presets.gif)

### Preset controls

| Key | Action |
| --- | --- |
| `↑` / `↓` or `j` / `k` | Move selection |
| `Enter` / `Space` | Launch selected preset |
| `→` / `l` | Edit selected preset |
| `n` | Create preset |
| `a` | Add a window while editing |
| `Shift+J` / `Shift+K` | Move a window later / earlier |
| `s` | Assign a preset shortcut slot |
| `x` | Delete selected preset or window |
| `[` / `]` | Switch between Presets and Profiles |
| `Esc` | Go back or close the panel |

Terminal and Custom entries can have an optional display title. Installed web
apps use the title from their desktop entry automatically.

Preset names must be unique, ignoring surrounding spaces and letter case. The
same rule applies separately to profile names. A duplicate stays in the naming
form with an inline message, so shortcuts and profile references always resolve
to one item.

## Profiles

A profile maps workspace numbers to presets. For example, workspace 2 can open
a Reading preset while workspace 3 opens an Evening preset. Create a profile
from the **Profiles** tab, add each workspace/preset pair, then choose what
happens to windows already on those workspaces.

![Creating a two-workspace profile and assigning a shortcut](docs/setting-up-profile.gif)

| Close mode | Behavior |
| --- | --- |
| **Close ours only** | Closes this profile's tracked windows only if their process/session identity and current workspace still match. This is the default. |
| **Close all on workspace** | Closes every window on each target workspace. |
| **Keep existing** | Leaves all existing windows and adds the new ones. |

Only one profile can activate at a time, including shortcut and IPC requests.
A second request returns `busy`. The entire profile is checked before any
workspace changes: missing presets, invalid entries, and repeated workspace
numbers stop activation. A preset referenced by a profile cannot be deleted
until that reference is removed.

Closing uses a window-specific request, never process termination. If an
application keeps a window open (for example, for a save dialog), activation
stops with an error. Resolve the dialog before retrying. Workspace-switch and
window-launch timeouts also stop activation and preserve tracking for windows
already opened.

Ownership is retained across profile switches and scoped to the current
Hyprland session. On upgrade, legacy tracking records lack enough identity
information to close safely, so existing windows are left alone. New launches
write the stronger records. Launch detection still observes newly appearing
windows: avoid manually opening other windows during activation, since a
single unrelated arrival can be mistaken for the requested application.

Activating a profile shows pending/running/done/failed progress. Press `d` in a profile's
edit view to make it the login default. Only one profile can be default at a
time; that explicit action also installs the plugin-specific post-boot hook.
If you ever need to reinstall the hook manually, run:

```bash
omarchy hook install post-boot ~/.config/omarchy/plugins/kdm.presets/hooks/kdm-presets-activate-default-profile.sh
```

## Keyboard shortcuts

After accepting first-run shortcut setup, assign numbered slots with `s` or
the keyboard button on a row:

- `SUPER + CTRL + SHIFT + 1` through `9` launch preset slots.
- `SUPER + CTRL + ALT + 1` through `9` launch profile slots and open the live
  progress panel.

If you declined onboarding, add this block to
`~/.config/hypr/bindings.lua` manually:

```lua
-- kdm.presets quick-launch shortcut slots
for slot = 1, 9 do
  o.bind("SUPER + CTRL + SHIFT + code:" .. tostring(slot + 9), "Preset slot " .. slot,
    "omarchy-shell kdm.presets activatePresetSlot " .. slot)
  o.bind("SUPER + CTRL + ALT + code:" .. tostring(slot + 9), "Profile slot " .. slot,
    "omarchy-shell kdm.presets activateProfileSlot " .. slot)
end
```

The physical key codes are intentional: shifted number keys produce different
characters on many keyboard layouts.

To open or close the panel with `SUPER + SHIFT + Q`, add this optional binding
to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + Q", "Presets", "omarchy-shell shell toggle kdm.presets")
```

## Data, commands, and permissions

Presets runs entirely as your user and makes no network requests of its own.
Web apps and custom commands you configure may use the network.

Its own state lives under `~/.local/state/omarchy/kdm-presets/`:

| File | Purpose |
| --- | --- |
| `presets.json` | Preset names and ordered window definitions |
| `profiles.json` | Profile workspace mappings, close modes, and default flag |
| `shortcuts.json` | Numbered shortcut assignments |
| `active-profile.json` | Versioned window ownership records across profiles, including process/session identity |
| `activation-progress.json` | Current profile-launch progress |
| `activation.lock` | Advisory lock held only while a profile activation runs |
| `onboarding.json` / `onboarding-result.json` | First-run status |

Preset, profile, and shortcut saves run through a single queue. Rapid edits
coalesce to the latest snapshot, and older disk notifications cannot overwrite
unsaved edits. Each write uses a unique sibling temporary file and an atomic
rename. Failed saves remain in memory with a **Retry saving** action; keep the
shell running until retry succeeds to preserve those unsaved changes.

The plugin may also make these user-approved configuration changes:

- append the marked shortcut block to `~/.config/hypr/bindings.lua` after the
  onboarding prompt is accepted;
- install its named post-boot hook after a profile is explicitly made default;
- set target workspaces to Hyprland's scrolling layout when launching;
- close windows according to the profile close mode you selected.

Custom entries are shell commands. Only save commands you trust.

### Example formats

`presets.json`:

```json
[
  {
    "name": "Evening",
    "windows": [
      { "type": "terminal", "value": "cal", "label": "Calendar" },
      { "type": "webapp", "value": "https://omarchy.org", "label": "Omarchy" }
    ]
  }
]
```

`profiles.json`:

```json
[
  {
    "name": "Daily Setup",
    "default": false,
    "closeMode": "trackedOnly",
    "workspaces": [
      { "workspace": 2, "preset": "Reading" },
      { "workspace": 3, "preset": "Evening" }
    ]
  }
]
```

## Remove

Disable the widget, remove its post-boot hook, then remove the plugin:

```bash
omarchy plugin disable kdm.presets
rm -f -- ~/.config/omarchy/hooks/post-boot.d/kdm-presets-activate-default-profile.sh
omarchy plugin remove kdm.presets --yes
```

If you accepted shortcut setup, also delete the marked `kdm.presets
quick-launch shortcut slots` block from `~/.config/hypr/bindings.lua`, then run
`hyprctl reload`.

Plugin state is deliberately preserved when the plugin is removed. Delete it
only if you do not want to reinstall or keep your presets:

```bash
rm -rf -- ~/.local/state/omarchy/kdm-presets
```

## Development checks

Run the regression suite with Node.js 22+ and the normal Bash/`jq`/`flock`
tools:

```bash
node --test tests/safety.test.cjs
bash -n scripts/activate-profile.sh scripts/write-json.sh
```

Tests execute the QML functions and real shell helpers with a fake compositor
and temporary state. They do not launch or close real application windows.
On an Omarchy machine, an additional runtime check uses actual Quickshell
FileViews and Processes, with only the display surface stubbed:

```bash
node tests/qml-smoke.cjs
```

## License

[MIT](LICENSE) © kdm
