import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar widget: a bar icon that opens a panel listing named "presets" — saved
// sets of windows to open together. Presets and their window lists are fully
// editable from inside the panel, either with the mouse (every action has a
// visible button: Edit, Delete, + New preset, + Add window, ↑/↓ reorder) or
// the keyboard (n add preset, Right/l edit, a add window inside edit,
// Shift+J/Shift+K reorder, x delete, Escape back). Adding a "web app" window
// picks from your already-installed web apps (~/.local/share/applications)
// instead of retyping a URL. Everything persists under
// ~/.local/state/omarchy/kdm-presets/ immediately; see README for the
// on-disk formats.
//
// Launching a preset forces the active workspace into Omarchy's "scrolling"
// (column) layout, then opens each window in list order, waiting for each
// one to actually map before starting the next — so window order always
// matches list order regardless of how long any individual app takes to
// start (a browser-backed web app is much slower to map than a terminal).
Panel {
  id: root
  moduleName: "kdm.presets"
  ipcTarget: "kdm.presets"
  // This plugin defines its own IpcHandler below (adding activateProfile
  // alongside open/close/toggle) — manageIpc:false stops the base Panel's
  // default handler from also registering for the same target, which would
  // otherwise silently lose the race ("Handler was registered but will not
  // be used because another handler is registered for target kdm.presets").
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // Deliberately outside this plugin's own folder: Omarchy's shell watches
  // each plugin's source directory for hot-reload, and treats ANY change in
  // there (including this app writing its own data file) as "the plugin
  // changed" — destroying and rebuilding the whole panel, which used to
  // slam the popup shut on every save. Living under .local/state sidesteps
  // that entirely, matching the convention other Omarchy state uses (e.g.
  // ~/.local/state/omarchy/workspace-layouts/).
  readonly property string presetsPath: Quickshell.env("HOME") + "/.local/state/omarchy/kdm-presets/presets.json"
  // Profiles: a named mapping of workspace number -> preset, activated
  // together. Deliberately a separate file/schema from presets.json — see
  // README. Same hot-reload-avoidance reasoning as presetsPath above.
  readonly property string profilesPath: Quickshell.env("HOME") + "/.local/state/omarchy/kdm-presets/profiles.json"
  // Which window addresses the currently-active profile opened, so a later
  // "trackedOnly" activation can close exactly those and nothing else.
  readonly property string activeProfilePath: Quickshell.env("HOME") + "/.local/state/omarchy/kdm-presets/active-profile.json"
  // Live step-by-step status for whichever profile is currently launching,
  // written by the activation script and watched here for the progress UI.
  readonly property string progressPath: Quickshell.env("HOME") + "/.local/state/omarchy/kdm-presets/activation-progress.json"
  // Quick-launch keybinding slots. Two separate reserved modifier families
  // (SUPER+CTRL+SHIFT+1-9 for presets, SUPER+CTRL+ALT+1-9 for profiles —
  // both confirmed free on this machine before claiming them, see
  // bindings.lua) rather than one shared pool: a preset slot is fast and
  // strictly additive, a profile slot can close windows and jumps you across
  // its own fixed workspaces, so the modifier itself should say which kind
  // of thing you're about to fire.
  readonly property string shortcutsPath: Quickshell.env("HOME") + "/.local/state/omarchy/kdm-presets/shortcuts.json"
  // First-run onboarding: presence of this file (not its content) is the
  // signal. onLoadFailed(FileNotFound) below means "never onboarded" —
  // deliberately a dedicated marker rather than reusing presets.json/
  // profiles.json being empty, since a real user can legitimately have zero
  // presets without that meaning "never used this before".
  readonly property string onboardingPath: Quickshell.env("HOME") + "/.local/state/omarchy/kdm-presets/onboarding.json"
  // Result of the last shortcut-setup attempt (or lack of one), watched the
  // same way profile-activation progress already is: a script writes it,
  // this reloads it.
  readonly property string onboardingResultPath: Quickshell.env("HOME") + "/.local/state/omarchy/kdm-presets/onboarding-result.json"
  readonly property string bindingsLuaPath: Quickshell.env("HOME") + "/.config/hypr/bindings.lua"
  readonly property var closeModes: ["trackedOnly", "workspaceAll", "keepExisting"]
  readonly property var closeModeLabels: ({
    trackedOnly: "Close ours only",
    workspaceAll: "Close all on workspace",
    keepExisting: "Keep existing"
  })
  readonly property var closeModeHints: ({
    trackedOnly: "Closes only the windows this profile itself opened last time — anything you opened by hand stays.",
    workspaceAll: "Closes everything on the target workspace, regardless of who opened it.",
    keepExisting: "Closes nothing — new windows just join whatever's already there."
  })
  readonly property var windowTypes: ["terminal", "webapp", "custom"]
  readonly property var windowTypeLabels: ({
    terminal: "Terminal",
    webapp: "Web app",
    custom: "Custom"
  })
  // FontAwesome glyphs (the original 0xf0xx range every Nerd Font build
  // carries, unlike newer icon-set ranges that vary more by build) —
  // confirmed present in this machine's JetBrainsMono Nerd Font cmap before
  // use. terminal / globe / cog, one per window type.
  readonly property var windowTypeIcons: ({
    terminal: "",
    webapp: "",
    custom: ""
  })
  readonly property var windowTypePrompts: ({
    terminal: "Command to run in a terminal (e.g. btop)",
    webapp: "URL to open as a web app (e.g. https://example.com)",
    custom: "Any shell command, run as-is"
  })

  // One shell one-liner, scanned fresh every time the panel opens (and again
  // whenever "Web app" is chosen), so newly-installed web apps show up
  // without restarting anything. Emits "Name<TAB>url" per line rather than
  // JSON — desktop-entry names never contain tabs, and this sidesteps having
  // to build valid JSON out of a shell loop.
  readonly property string webappScanScript: `
for f in "$HOME"/.local/share/applications/*.desktop; do
  [ -f "$f" ] || continue
  exec_line=$(grep -m1 '^Exec=' "$f" 2>/dev/null)
  case "$exec_line" in
    *omarchy-launch-webapp*)
      name=$(grep -m1 '^Name=' "$f" 2>/dev/null | cut -d= -f2-)
      url=$(printf '%s\n' "$exec_line" | sed -E 's/^Exec=omarchy-launch-webapp[[:space:]]+//' | sed -E 's/^"//; s/"$//')
      [ -n "$name" ] && [ -n "$url" ] && printf '%s\t%s\n' "$name" "$url"
      ;;
  esac
done | sort -f
`

  property var presets: []
  property var installedWebapps: []
  property var profiles: []
  property var shortcuts: []
  property var activationSteps: []
  property bool activationRunning: false
  property string activationError: ""
  // One worker serializes all data writes; edits coalesce by destination.
  property var pendingWrites: ({})
  property string writingPath: ""
  property string writingJson: ""
  property string saveError: ""
  // true until the onboarding FileView proves otherwise (FileNotFound) —
  // fail toward "don't nag" rather than "always ask" if detection is ever
  // ambiguous (e.g. a permission error reading the marker).
  property bool onboardingDone: true
  property string onboardingPhase: "ask" // "ask" | "running" | "done"
  property int onboardingChoiceIndex: 0 // 0 = yes, 1 = no, in "ask"
  property var onboardingResult: null
  // "list" (preset picker) -> "edit" (one preset's window list)
  // -> "addType" (pick a window type) -> "pickWebapp" (installed web apps,
  // only for the webapp type) -> "addValue" (enter a command/custom URL)
  // "list" -> "namePreset" (name a brand new preset)
  // "list" -> "profiles" (profile picker) -> "profileEdit" (one profile's
  // workspace list) -> "profileAddWorkspace" (pick workspace number + preset)
  // any activation -> "activating" (live progress, input mostly blocked)
  // "list"/"profiles" -> "assignSlot" (pick a 1-9 quick-launch slot for the
  // selected preset/profile; returns to whichever of the two opened it)
  // "onboarding" — shown instead of "list" only on the very first ever open
  // (see onboardingDone), offering to set up quick-launch shortcuts.
  property string mode: "list"
  property int selectedIndex: 0
  property int editingPresetIndex: -1
  property int windowIndex: 0
  property int newWindowTypeIndex: 0
  property int pickWebappIndex: 0
  property int profileIndex: 0
  property int editingProfileIndex: -1
  property int profileWorkspaceIndex: 0
  property int pickPresetIndex: 0
  property bool cursorActive: false

  // assignSlot state: which family/item we're assigning a slot to, which
  // mode to return to, and the 1-9 cursor while picking.
  property string assigningFamily: ""
  property string assigningName: ""
  property string assignReturnMode: "list"
  property int assignSlotIndex: 0

  readonly property bool activationComplete: activationSteps.length > 0
    && activationSteps.every(function(s) { return s.status === "done" })

  onModeChanged: if (panelFlick) panelFlick.contentY = 0
  onSelectedIndexChanged: if (cursorActive && mode === "list" && presetRepeater)
    Qt.callLater(function() { scrollItemIntoView(presetRepeater.itemAt(selectedIndex)) })
  onWindowIndexChanged: if (cursorActive && mode === "edit" && windowRepeater)
    Qt.callLater(function() { scrollItemIntoView(windowRepeater.itemAt(windowIndex)) })
  onPickWebappIndexChanged: if (cursorActive && mode === "pickWebapp" && webappRepeater)
    Qt.callLater(function() {
      scrollItemIntoView(pickWebappIndex < installedWebapps.length ? webappRepeater.itemAt(pickWebappIndex) : customUrlBtn)
    })
  onProfileIndexChanged: if (cursorActive && mode === "profiles" && profileRepeater)
    Qt.callLater(function() { scrollItemIntoView(profileRepeater.itemAt(profileIndex)) })
  onProfileWorkspaceIndexChanged: if (cursorActive && mode === "profileEdit" && profileWorkspaceRepeater)
    Qt.callLater(function() { scrollItemIntoView(profileWorkspaceRepeater.itemAt(profileWorkspaceIndex)) })
  onPickPresetIndexChanged: if (cursorActive && mode === "profileAddWorkspace" && pickPresetRepeater)
    Qt.callLater(function() { scrollItemIntoView(pickPresetRepeater.itemAt(pickPresetIndex)) })
  onAssignSlotIndexChanged: if (cursorActive && mode === "assignSlot" && assignSlotRepeater)
    Qt.callLater(function() { scrollItemIntoView(assignSlotRepeater.itemAt(assignSlotIndex)) })

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function currentPreset() {
    return (editingPresetIndex >= 0 && editingPresetIndex < presets.length) ? presets[editingPresetIndex] : null
  }

  function currentProfile() {
    return (editingProfileIndex >= 0 && editingProfileIndex < profiles.length) ? profiles[editingProfileIndex] : null
  }

  function presetByName(name) {
    for (var i = 0; i < presets.length; i++) if (presets[i].name === name) return presets[i]
    return null
  }

  function profileByName(name) {
    for (var i = 0; i < profiles.length; i++) if (profiles[i].name === name) return profiles[i]
    return null
  }

  // -------------------------------------------------------------- shortcuts

  function loadShortcuts(raw) {
    if (hasPendingWrite(shortcutsPath)) return
    try {
      var parsed = JSON.parse(raw)
      root.shortcuts = Array.isArray(parsed) ? parsed : []
    } catch (e) {
      root.shortcuts = []
    }
  }

  function persistShortcuts() {
    persistJson(root.shortcutsPath, root.shortcuts)
  }

  function shortcutAt(family, slot) {
    for (var i = 0; i < shortcuts.length; i++)
      if (shortcuts[i].family === family && shortcuts[i].slot === slot) return shortcuts[i]
    return null
  }

  // Which slot (if any) the given preset/profile currently holds, so a row
  // can show "⌨3" instead of making you open the picker to find out.
  function shortcutSlotForItem(family, name) {
    for (var i = 0; i < shortcuts.length; i++)
      if (shortcuts[i].family === family && shortcuts[i].name === name) return shortcuts[i].slot
    return 0
  }

  // A slot holds at most one item; assigning it here replaces whatever was
  // there, and any other slot the same item held in this family is cleared
  // first — an item only ever occupies one slot at a time.
  function setShortcut(family, slot, name) {
    var next = []
    for (var i = 0; i < root.shortcuts.length; i++) {
      var s = root.shortcuts[i]
      if (s.family === family && (s.slot === slot || s.name === name)) continue
      next.push(s)
    }
    next.push({ family: family, slot: slot, name: name })
    root.shortcuts = next
    persistShortcuts()
  }

  function clearShortcut(family, slot) {
    var next = root.shortcuts.filter(function(s) { return !(s.family === family && s.slot === slot) })
    root.shortcuts = next
    persistShortcuts()
  }

  function enterAssignSlot(family, name, returnTo) {
    assigningFamily = family
    assigningName = name
    assignReturnMode = returnTo
    assignSlotIndex = 0
    cursorActive = false
    mode = "assignSlot"
  }

  function pickAssignSlot(slot) {
    setShortcut(assigningFamily, slot, assigningName)
    mode = assignReturnMode
  }

  function clearAssigningSlot() {
    var existing = shortcutSlotForItem(assigningFamily, assigningName)
    if (existing) clearShortcut(assigningFamily, existing)
    mode = assignReturnMode
  }

  // Row text has a fixed pixel budget (buttons don't shrink to fit), so any
  // value long enough to matter — a shell command, a long preset name — has
  // to be capped in characters rather than left to overflow. The full text
  // always stays reachable via tooltipText.
  function elide(str, maxChars) {
    var s = String(str || "")
    return s.length > maxChars ? s.slice(0, Math.max(0, maxChars - 1)) + "…" : s
  }

  // Keep the keyboard-highlighted row inside the visible scroll area: arrow
  // navigation moves the cursor, not the viewport, so without this a cursor
  // driven past the bottom of a long list (e.g. 12 installed web apps)
  // would highlight a row the user can't see.
  function scrollItemIntoView(item) {
    if (!item || !panelFlick) return
    var pos = item.mapToItem(column, 0, 0)
    var top = pos.y
    var bottom = top + item.height
    if (top < panelFlick.contentY) panelFlick.contentY = Math.max(0, top)
    else if (bottom > panelFlick.contentY + panelFlick.height) panelFlick.contentY = Math.max(0, bottom - panelFlick.height)
  }

  // -------------------------------------------------------------- onboarding

  function markOnboardingDone() {
    root.onboardingDone = true
    persistJson(root.onboardingPath, { completed: true })
  }

  function installStartupHook() {
    // Setting a default profile is the explicit consent boundary for writing
    // into post-boot.d. Keep the installed filename plugin-specific so this
    // cannot collide with another hook that happens to describe the same job.
    Util.execDetached("omarchy hook install post-boot "
      + Util.shellQuote(Quickshell.env("HOME") + "/.config/omarchy/plugins/kdm.presets/hooks/kdm-presets-activate-default-profile.sh"))
  }

  function declineOnboardingShortcuts() {
    markOnboardingDone()
    mode = "list"
  }

  // Appends the quick-launch binding loop to the user's real bindings.lua —
  // the one genuinely risky thing this plugin ever does to a file it doesn't
  // own. Layered safety, cheapest check first: (1) skip entirely if already
  // present (idempotent — grep on the distinctive activatePresetSlot call,
  // which matches both this auto-install and the old manual-copy-paste
  // instructions from before this flow existed), (2) back up before writing
  // anything, (3) luac -p as a fast syntax gate with no Hyprland involved at
  // all, (4) hyprctl reload + configerrors as the final live check, since
  // Hyprland's Lua environment has requirements luac's generic parser can't
  // see (e.g. calling functions — o.bind — that only exist in that context).
  // Any failure at (3) or (4) restores the backup and reloads again before
  // reporting anything — the user should never be left with a broken config.
  function buildOnboardingScript() {
    var snippet = [
      '',
      "-- kdm.presets quick-launch shortcut slots (added by the Presets plugin's first-run setup)",
      'for slot = 1, 9 do',
      '  o.bind("SUPER + CTRL + SHIFT + code:" .. tostring(slot + 9), "Preset slot " .. slot,',
      '    "omarchy-shell kdm.presets activatePresetSlot " .. slot)',
      '  o.bind("SUPER + CTRL + ALT + code:" .. tostring(slot + 9), "Profile slot " .. slot,',
      '    "omarchy-shell kdm.presets activateProfileSlot " .. slot)',
      'end'
    ].join('\n')

    var lines = []
    lines.push('bindings=' + Util.shellQuote(root.bindingsLuaPath))
    lines.push('result=' + Util.shellQuote(root.onboardingResultPath))
    lines.push('luac_err=$(mktemp)')
    lines.push('mkdir -p "$(dirname "$result")"')
    lines.push('write_result() { printf %s "$1" > "$result.tmp" && mv "$result.tmp" "$result"; }')
    lines.push('if [ ! -f "$bindings" ]; then write_result \'{"result":"error","message":"bindings.lua not found"}\'; rm -f "$luac_err"; exit 0; fi')
    lines.push('if grep -qF "activatePresetSlot" "$bindings"; then write_result \'{"result":"already-installed"}\'; rm -f "$luac_err"; exit 0; fi')
    lines.push('backup="$bindings.kdm-presets-backup-$(date +%s)"')
    lines.push('cp "$bindings" "$backup"')
    lines.push('cat >> "$bindings" <<' + "'LUA_EOF'")
    lines.push(snippet)
    lines.push('LUA_EOF')
    lines.push('if ! luac -p "$bindings" >"$luac_err" 2>&1; then')
    lines.push('  cp "$backup" "$bindings"; rm -f "$backup"')
    lines.push('  write_result "$(jq -n --arg err "$(cat "$luac_err")" \'{result:"failed", error:$err}\')"')
    lines.push('  rm -f "$luac_err"; exit 0')
    lines.push('fi')
    lines.push('rm -f "$luac_err"')
    lines.push('hyprctl reload >/dev/null 2>&1')
    lines.push('sleep 0.4')
    lines.push('errors=$(hyprctl configerrors 2>&1)')
    lines.push('if [ -n "$errors" ]; then')
    lines.push('  cp "$backup" "$bindings"')
    lines.push('  hyprctl reload >/dev/null 2>&1')
    lines.push('  rm -f "$backup"')
    lines.push('  write_result "$(jq -n --arg err "$errors" \'{result:"failed", error:$err}\')"')
    lines.push('else')
    lines.push('  rm -f "$backup"')
    lines.push('  write_result \'{"result":"success"}\'')
    lines.push('fi')
    return lines.join('\n')
  }

  function acceptOnboardingShortcuts() {
    onboardingPhase = "running"
    Util.execDetached(root.buildOnboardingScript())
  }

  function loadOnboardingResult(raw) {
    try {
      root.onboardingResult = JSON.parse(raw)
    } catch (e) {
      root.onboardingResult = null
    }
    if (root.onboardingResult) {
      root.onboardingPhase = "done"
      root.markOnboardingDone()
    }
  }

  onOpenedChanged: if (opened) {
    // Don't reset away from "activating" if a profile launch is still
    // running in the background — reopening the panel mid-launch should
    // show live progress, not silently drop back to the preset list.
    if (!activationRunning) {
      mode = root.onboardingDone ? "list" : "onboarding"
      onboardingPhase = "ask"
    }
    cursorActive = false
    selectedIndex = Math.min(selectedIndex, Math.max(0, presets.length - 1))
    scanWebapps()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function loadPresets(raw) {
    if (hasPendingWrite(presetsPath)) return
    try {
      var parsed = JSON.parse(raw)
      root.presets = Array.isArray(parsed) ? parsed : []
    } catch (e) {
      root.presets = []
    }
    if (selectedIndex >= presets.length) selectedIndex = Math.max(0, presets.length - 1)
  }

  function hasPendingWrite(path) {
    return writingPath === path || pendingWrites[path] !== undefined
  }

  function persistJson(path, data) {
    var next = Object.assign({}, pendingWrites)
    next[path] = JSON.stringify(data, null, 2) + "\n"
    pendingWrites = next
    startNextWrite()
  }

  function startNextWrite() {
    if (writingPath !== "") return
    var paths = Object.keys(pendingWrites)
    if (paths.length === 0) return
    writingPath = paths[0]
    writingJson = pendingWrites[writingPath]
    var next = Object.assign({}, pendingWrites)
    delete next[writingPath]
    pendingWrites = next
    saveProcess.command = ["bash", helperPath("write-json.sh"), writingPath, writingJson]
    saveProcess.running = true
  }

  function finishWrite(exitCode) {
    if (exitCode !== 0) {
      var next = Object.assign({}, pendingWrites)
      // Retain unsaved data, but never replace a newer pending edit.
      if (next[writingPath] === undefined) next[writingPath] = writingJson
      pendingWrites = next
      saveError = "Could not save changes. Retry when storage is available."
    }
    writingPath = ""
    writingJson = ""
    if (exitCode === 0) {
      saveError = ""
      startNextWrite()
    }
  }

  function persistPresets() {
    persistJson(root.presetsPath, root.presets)
  }

  // -------------------------------------------------------------- profiles

  function loadProfiles(raw) {
    if (hasPendingWrite(profilesPath)) return
    try {
      var parsed = JSON.parse(raw)
      root.profiles = Array.isArray(parsed) ? parsed : []
    } catch (e) {
      root.profiles = []
    }
    if (profileIndex >= profiles.length) profileIndex = Math.max(0, profiles.length - 1)
  }

  function persistProfiles() {
    persistJson(root.profilesPath, root.profiles)
  }

  function loadProgress(raw) {
    try {
      var parsed = JSON.parse(raw)
      root.activationSteps = Array.isArray(parsed) ? parsed : []
    } catch (e) {
      // Leave whatever's there — the script overwrites the file atomically
      // (write to a temp file, then mv), so a mid-write partial read here
      // should be rare, and dropping steps we already know about would
      // flicker the progress list backwards.
    }
  }

  function addProfile(name) {
    var trimmed = String(name || "").trim()
    if (trimmed === "") return
    var next = Util.cloneJson(root.profiles)
    next.push({ name: trimmed, default: false, closeMode: "trackedOnly", workspaces: [] })
    root.profiles = next
    profileIndex = next.length - 1
    persistProfiles()
  }

  function submitNewProfileName(name) {
    addProfile(name)
    mode = "profiles"
    // profileNameField doesn't lose Qt keyboard focus just because its
    // Column went invisible — without this, the next keystrokes partially
    // leak into the hidden field instead of driving navigation (observed
    // directly: typing after this created a second, garbage-named profile).
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function deleteProfileAt(index) {
    if (index < 0 || index >= root.profiles.length) return
    var next = Util.cloneJson(root.profiles)
    next.splice(index, 1)
    root.profiles = next
    if (profileIndex >= next.length) profileIndex = Math.max(0, next.length - 1)
    persistProfiles()
  }

  function enterProfileEdit(index) {
    if (index < 0 || index >= profiles.length) return
    editingProfileIndex = index
    profileWorkspaceIndex = 0
    cursorActive = false
    mode = "profileEdit"
  }

  // Only one profile may be default at a time — clearing every other
  // profile's flag here is what enforces that, rather than leaving it to
  // the UI to prevent a double-select.
  function setProfileDefault(index) {
    if (index < 0 || index >= root.profiles.length) return
    var next = Util.cloneJson(root.profiles)
    for (var i = 0; i < next.length; i++) next[i].default = (i === index)
    root.profiles = next
    persistProfiles()
    installStartupHook()
  }

  function setProfileCloseMode(closeMode) {
    if (editingProfileIndex < 0) return
    var next = Util.cloneJson(root.profiles)
    var profile = next[editingProfileIndex]
    if (!profile) return
    profile.closeMode = closeMode
    root.profiles = next
    persistProfiles()
  }

  function addWorkspaceToEditingProfile(workspaceNum, presetName) {
    var ws = parseInt(workspaceNum, 10)
    var preset = String(presetName || "").trim()
    if (!isFinite(ws) || ws < 1 || preset === "" || editingProfileIndex < 0) return
    var next = Util.cloneJson(root.profiles)
    var profile = next[editingProfileIndex]
    if (!profile) return
    if (!Array.isArray(profile.workspaces)) profile.workspaces = []
    profile.workspaces.push({ workspace: ws, preset: preset })
    root.profiles = next
    profileWorkspaceIndex = profile.workspaces.length - 1
    persistProfiles()
  }

  function deleteProfileWorkspaceAt(index) {
    if (editingProfileIndex < 0) return
    var next = Util.cloneJson(root.profiles)
    var profile = next[editingProfileIndex]
    if (!profile || !Array.isArray(profile.workspaces) || index < 0 || index >= profile.workspaces.length) return
    profile.workspaces.splice(index, 1)
    root.profiles = next
    if (profileWorkspaceIndex >= profile.workspaces.length) profileWorkspaceIndex = Math.max(0, profile.workspaces.length - 1)
    persistProfiles()
  }

  function moveProfileWorkspace(index, delta) {
    if (editingProfileIndex < 0) return
    var next = Util.cloneJson(root.profiles)
    var profile = next[editingProfileIndex]
    if (!profile || !Array.isArray(profile.workspaces)) return
    var newIndex = index + delta
    if (newIndex < 0 || newIndex >= profile.workspaces.length) return
    var tmp = profile.workspaces[index]
    profile.workspaces[index] = profile.workspaces[newIndex]
    profile.workspaces[newIndex] = tmp
    root.profiles = next
    profileWorkspaceIndex = newIndex
    persistProfiles()
  }

  function enterProfileAddWorkspace() {
    pickPresetIndex = 0
    workspaceNumberField.text = ""
    mode = "profileAddWorkspace"
  }

  // ---------------------------------------------------------- activation

  // Resolve and validate the whole profile before making any desktop changes.
  function profileValidationError(profile) {
    if (!profile || !String(profile.name || "").trim()) return "A profile name is required."
    if (!Array.isArray(profile.workspaces) || profile.workspaces.length === 0) return "Add at least one workspace."
    if (closeModes.indexOf(profile.closeMode || "trackedOnly") < 0) return "Invalid close mode."
    var seen = {}
    for (var i = 0; i < profile.workspaces.length; i++) {
      var step = profile.workspaces[i]
      if (!step || typeof step.workspace !== "number" || !isFinite(step.workspace)
          || step.workspace < 1 || Math.floor(step.workspace) !== step.workspace)
        return "Invalid workspace number."
      if (seen[step.workspace]) return "Workspace " + step.workspace + " appears more than once."
      seen[step.workspace] = true
      var preset = root.presetByName(step.preset)
      if (!preset) return "Missing preset: " + step.preset + ". Update the profile before launching."
      if (!Array.isArray(preset.windows)) return "Invalid window list in " + preset.name + "."
      for (var j = 0; j < preset.windows.length; j++) {
        var w = preset.windows[j]
        if (!w || windowTypes.indexOf(w.type) < 0 || typeof w.value !== "string" || !w.value.trim())
          return "Invalid window in " + preset.name + "."
      }
    }
    return ""
  }

  function helperPath(name) {
    return decodeURIComponent(String(Qt.resolvedUrl("scripts/" + name)).replace(/^file:\/\//, ""))
  }

  function buildProfileScript(profile) {
    var error = profileValidationError(profile)
    if (error) return ""
    var plan = {name: profile.name, closeMode: profile.closeMode || "trackedOnly", workspaces: []}
    for (var i = 0; i < profile.workspaces.length; i++) {
      var step = profile.workspaces[i]
      var preset = presetByName(step.preset)
      plan.workspaces.push({workspace: step.workspace, preset: step.preset,
        commands: preset.windows.map(function(w) { return root.commandForWindow(w) })})
    }
    var dir = root.progressPath.substring(0, root.progressPath.lastIndexOf("/"))
    return "exec bash " + Util.shellQuote(helperPath("activate-profile.sh"))
      + " " + Util.shellQuote(dir) + " " + Util.shellQuote(JSON.stringify(plan))
  }

  function activateProfile(profile) {
    if (activationRunning) return "busy"
    activationError = profileValidationError(profile)
    if (activationError) {
      mode = "activating"
      activationSteps = []
      Util.execDetached("omarchy-notification-send 'Cannot activate profile' " + Util.shellQuote(activationError))
      return activationError
    }
    activationSteps = profile.workspaces.map(function(s) {
      return {workspace: s.workspace, preset: s.preset, status: "pending"}
    })
    activationError = ""
    activationRunning = true
    mode = "activating"
    activationProcess.command = ["bash", "-lc", buildProfileScript(profile)]
    activationProcess.running = true
    return "ok"
  }

  function activateProfileByName(name) {
    var p = null
    for (var i = 0; i < profiles.length; i++) if (profiles[i].name === name) { p = profiles[i]; break }
    if (p) activateProfile(p)
  }

  function scanWebapps() {
    if (!webappScan.running) webappScan.running = true
  }

  function parseWebapps(text) {
    var lines = String(text || "").split("\n")
    var out = []
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!line) continue
      var idx = line.indexOf("\t")
      if (idx < 0) continue
      var name = line.substring(0, idx).trim()
      var url = line.substring(idx + 1).trim()
      if (name === "" || url === "") continue
      out.push({ name: name, url: url })
    }
    return out
  }

  // ---------------------------------------------------------------- presets

  function addPreset(name) {
    var trimmed = String(name || "").trim()
    if (trimmed === "") return
    var next = Util.cloneJson(root.presets)
    next.push({ name: trimmed, windows: [] })
    root.presets = next
    selectedIndex = next.length - 1
    persistPresets()
  }

  function submitNewPresetName(name) {
    addPreset(name)
    mode = "list"
    // See the matching comment in submitNewProfileName — same stale-focus
    // issue applies here.
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function deletePresetAt(index) {
    if (index < 0 || index >= root.presets.length) return
    var name = root.presets[index].name
    for (var p = 0; p < profiles.length; p++) {
      var workspaces = profiles[p].workspaces || []
      for (var w = 0; w < workspaces.length; w++) {
        if (workspaces[w].preset === name) {
          Util.execDetached("omarchy-notification-send 'Preset is in use' "
            + Util.shellQuote("Remove " + name + " from profile " + profiles[p].name + " before deleting it."))
          return
        }
      }
    }
    var next = Util.cloneJson(root.presets)
    next.splice(index, 1)
    root.presets = next
    if (selectedIndex >= next.length) selectedIndex = Math.max(0, next.length - 1)
    persistPresets()
  }

  function enterEdit(index) {
    if (index < 0 || index >= presets.length) return
    editingPresetIndex = index
    windowIndex = 0
    cursorActive = false
    mode = "edit"
  }

  // ---------------------------------------------------------------- windows

  function addWindowToEditing(type, value, label) {
    var trimmed = String(value || "").trim()
    if (trimmed === "" || editingPresetIndex < 0) return
    var next = Util.cloneJson(root.presets)
    var preset = next[editingPresetIndex]
    if (!preset) return
    if (!Array.isArray(preset.windows)) preset.windows = []
    var entry = { type: type, value: trimmed }
    var trimmedLabel = String(label || "").trim()
    if (trimmedLabel !== "") entry.label = trimmedLabel
    preset.windows.push(entry)
    root.presets = next
    windowIndex = preset.windows.length - 1
    persistPresets()
  }

  function saveNewWindowValue(text, title) {
    addWindowToEditing(windowTypes[newWindowTypeIndex], text, title)
    mode = "edit"
    // Same stale-focus issue as submitNewProfileName — titleField/valueField
    // don't release focus on their own when this Column goes invisible.
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function choosePickedWebapp(index) {
    if (index < 0 || index >= installedWebapps.length) return
    var app = installedWebapps[index]
    addWindowToEditing("webapp", app.url, app.name)
    mode = "edit"
  }

  function deleteWindowAt(index) {
    if (editingPresetIndex < 0) return
    var next = Util.cloneJson(root.presets)
    var preset = next[editingPresetIndex]
    if (!preset || !Array.isArray(preset.windows) || index < 0 || index >= preset.windows.length) return
    preset.windows.splice(index, 1)
    root.presets = next
    if (windowIndex >= preset.windows.length) windowIndex = Math.max(0, preset.windows.length - 1)
    persistPresets()
  }

  function moveWindow(index, delta) {
    if (editingPresetIndex < 0) return
    var next = Util.cloneJson(root.presets)
    var preset = next[editingPresetIndex]
    if (!preset || !Array.isArray(preset.windows)) return
    var newIndex = index + delta
    if (newIndex < 0 || newIndex >= preset.windows.length) return
    var tmp = preset.windows[index]
    preset.windows[index] = preset.windows[newIndex]
    preset.windows[newIndex] = tmp
    root.presets = next
    windowIndex = newIndex
    persistPresets()
  }

  function enterAddType() {
    newWindowTypeIndex = 0
    mode = "addType"
  }

  function chooseWindowType(index) {
    newWindowTypeIndex = index
    if (windowTypes[index] === "webapp") {
      pickWebappIndex = 0
      scanWebapps()
      mode = "pickWebapp"
    } else {
      mode = "addValue"
    }
  }

  // ---------------------------------------------------------------- launch

  function commandForWindow(w) {
    var type = String((w && w.type) || "custom")
    var value = String((w && w.value) || "").trim()
    if (value === "") return ""
    if (type === "terminal") {
      // Run through bash -c (not passed to omarchy-launch-terminal as bare
      // words) so the value is shell-quoted exactly once here, rather than
      // relying on the outer eval-based launch script to tokenize it —
      // spaces/quotes/semicolons in the user's command survive intact.
      // Held open with a trailing prompt: a fast-exiting command (e.g.
      // `echo hi`) would otherwise flash the terminal shut before it's
      // visible; long-running commands (btop, nvim) never reach the
      // "exited" line until the user quits them, so this is a no-op there.
      var held = value + "; __ec=$?; printf \"\\n[exited %s - press Enter to close]\\n\" \"$__ec\"; read -r _"
      return "omarchy-launch-terminal bash -c " + Util.shellQuote(held)
    }
    if (type === "webapp") return "omarchy-launch-webapp " + Util.shellQuote(value)
    return value
  }

  // Built as one shell script (not one bar.run() call per window) so window
  // creation is strictly sequenced: each entry waits for the client list to
  // grow before firing the next one, rather than trusting a fixed delay that
  // a slow-to-start browser web app could blow past.
  function buildLaunchScript(preset) {
    var windows = (preset && preset.windows) || []
    var lines = []
    lines.push('wsid=$(hyprctl activeworkspace -j | jq -r .id)')
    lines.push('hyprctl keyword workspace "$wsid, layout:scrolling" >/dev/null 2>&1')
    lines.push('wait_launch() {')
    lines.push('  n0=$(hyprctl clients -j | jq "length")')
    lines.push('  eval "$1" &')
    lines.push('  disown')
    lines.push('  i=0')
    lines.push('  while [ "$i" -lt 50 ]; do')
    lines.push('    n1=$(hyprctl clients -j | jq "length")')
    lines.push('    if [ "$n1" -gt "$n0" ]; then break; fi')
    lines.push('    sleep 0.1')
    lines.push('    i=$((i+1))')
    lines.push('  done')
    lines.push('}')
    for (var i = 0; i < windows.length; i++) {
      var cmd = commandForWindow(windows[i])
      if (cmd !== "") lines.push('wait_launch ' + Util.shellQuote(cmd))
    }
    return lines.join('\n')
  }

  // Shared by list-click launch and slot-activation (from a keybinding, no
  // panel involved at all — see the IpcHandler's activatePresetSlot below).
  function launchPreset(preset) {
    if (!preset) return
    var script = buildLaunchScript(preset)
    if (script !== "" && root.bar) root.bar.run(script)
  }

  function launchSelected() {
    if (presets.length === 0) return
    launchPreset(presets[selectedIndex])
    root.close()
  }

  FileView {
    path: root.presetsPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadPresets(text())
    onFileChanged: reload()
  }

  FileView {
    path: root.profilesPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadProfiles(text())
    onFileChanged: reload()
  }

  FileView {
    id: progressFile
    path: root.progressPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadProgress(text())
    onFileChanged: reload()
  }

  FileView {
    path: root.shortcutsPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadShortcuts(text())
    onFileChanged: reload()
  }

  // preload: true so this resolves at shell-startup time, well before the
  // user ever clicks the bar icon — onOpenedChanged reads onboardingDone
  // synchronously on first open, so a still-pending load here would show
  // the normal preset list instead of onboarding on that very first open.
  FileView {
    path: root.onboardingPath
    preload: true
    printErrors: false
    onLoaded: root.onboardingDone = true
    onLoadFailed: function(error) {
      root.onboardingDone = error !== FileViewError.FileNotFound
    }
  }

  FileView {
    path: root.onboardingResultPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadOnboardingResult(text())
    onFileChanged: reload()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    // Called by the post-boot hook (and available for any other external
    // trigger) to run whichever profile is flagged default, or a specific
    // named one. No-op (returns "not found") if the name doesn't match —
    // deliberately does not throw, since this may run unattended at login.
    function activateProfile(name: string): string {
      var p = null
      for (var i = 0; i < root.profiles.length; i++) if (root.profiles[i].name === name) { p = root.profiles[i]; break }
      if (!p) return "not found"
      return root.activateProfile(p)
    }
    // Bound to SUPER+CTRL+SHIFT+1-9 in bindings.lua. Fires silently — no
    // panel, matches how fast/harmless a preset launch already is from the
    // list. "not found" (not a throw) if the slot is unassigned or its
    // preset was since deleted, since this may fire from a keybinding with
    // no one watching for an exception.
    function activatePresetSlot(slot: int): string {
      var s = root.shortcutAt("preset", slot)
      if (!s) return "not found"
      var preset = root.presetByName(s.name)
      if (!preset) return "not found"
      root.launchPreset(preset)
      return "ok"
    }
    // Bound to SUPER+CTRL+ALT+1-9. Unlike the preset slot above, this forces
    // the panel open into the live-progress view first — a profile can take
    // several seconds and can close windows depending on its close mode, so
    // firing it with zero visual feedback would be startling.
    function activateProfileSlot(slot: int): string {
      var s = root.shortcutAt("profile", slot)
      if (!s) return "not found"
      var profile = root.profileByName(s.name)
      if (!profile) return "not found"
      if (root.activationRunning) return "busy"
      root.open()
      return root.activateProfile(profile)
    }
  }

  Process {
    id: saveProcess
    onExited: function(exitCode, exitStatus) { root.finishWrite(exitCode === 0 && exitStatus === 0 ? 0 : 1) }
  }

  Process {
    id: activationProcess
    stderr: StdioCollector { id: activationStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      root.activationRunning = false
      if (exitCode !== 0 || exitStatus !== 0) {
        root.activationError = activationStderr.text.trim() || "Profile activation failed."
        Util.execDetached("omarchy-notification-send 'Profile activation stopped' " + Util.shellQuote(root.activationError))
      }
      progressFile.reload()
    }
  }

  Process {
    id: webappScan
    running: false
    command: ["bash", "-lc", root.webappScanScript]
    stdout: StdioCollector { id: webappScanOut; waitForEnd: true; onStreamFinished: root.installedWebapps = root.parseWebapps(text) }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󱂬"
    onPressed: function(buttonCode) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(480))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // "activating" is blocked too — the plan calls for input not being
      // able to interrupt a profile launch mid-flight. The script itself
      // runs detached regardless (blocking keys is a UX guard, not what
      // actually protects the launch), so Escape/clicks staying inert here
      // is intentional; the Close button that appears on completion still
      // works since mouse clicks bypass this keyboard-only catcher.
      blocked: root.mode === "namePreset" || root.mode === "addValue"
        || root.mode === "nameProfile" || root.mode === "activating"
        || (root.mode === "profileAddWorkspace" && workspaceNumberField.activeFocus)

      onMoveRequested: function(dx, dy) {
        if (root.mode === "list") {
          if (dy !== 0 && root.presets.length > 0) {
            root.cursorActive = true
            root.selectedIndex = ((root.selectedIndex + dy) % root.presets.length + root.presets.length) % root.presets.length
          } else if (dx > 0 && root.presets.length > 0) {
            root.enterEdit(root.selectedIndex)
          }
        } else if (root.mode === "edit") {
          var preset = root.currentPreset()
          var count = (preset && preset.windows) ? preset.windows.length : 0
          if (dy !== 0 && count > 0) {
            root.cursorActive = true
            root.windowIndex = ((root.windowIndex + dy) % count + count) % count
          } else if (dx < 0) {
            root.mode = "list"
          }
        } else if (root.mode === "addType") {
          if (dx !== 0) root.newWindowTypeIndex = ((root.newWindowTypeIndex + dx) % 3 + 3) % 3
          else if (dx < 0) root.mode = "edit"
        } else if (root.mode === "pickWebapp") {
          var total = root.installedWebapps.length + 1
          if (dy !== 0) {
            root.cursorActive = true
            root.pickWebappIndex = ((root.pickWebappIndex + dy) % total + total) % total
          } else if (dx < 0) {
            root.mode = "addType"
          }
        } else if (root.mode === "profiles") {
          if (dy !== 0 && root.profiles.length > 0) {
            root.cursorActive = true
            root.profileIndex = ((root.profileIndex + dy) % root.profiles.length + root.profiles.length) % root.profiles.length
          } else if (dx > 0 && root.profiles.length > 0) {
            root.enterProfileEdit(root.profileIndex)
          } else if (dx < 0) {
            root.mode = "list"
          }
        } else if (root.mode === "profileEdit") {
          var profile = root.currentProfile()
          var pcount = (profile && profile.workspaces) ? profile.workspaces.length : 0
          if (dy !== 0 && pcount > 0) {
            root.cursorActive = true
            root.profileWorkspaceIndex = ((root.profileWorkspaceIndex + dy) % pcount + pcount) % pcount
          } else if (dx < 0) {
            root.mode = "profiles"
          }
        } else if (root.mode === "assignSlot") {
          if (dy !== 0) {
            root.cursorActive = true
            root.assignSlotIndex = ((root.assignSlotIndex + dy) % 9 + 9) % 9
          } else if (dx < 0) {
            root.mode = root.assignReturnMode
          }
        } else if (root.mode === "profileAddWorkspace") {
          // Only reachable once workspaceNumberField has given up focus (see
          // `blocked` above) — Enter in that field sends focus here so the
          // preset picker below it becomes keyboard-navigable too, matching
          // every other picker in this panel instead of being mouse-only.
          if (dy !== 0 && root.presets.length > 0) {
            root.cursorActive = true
            root.pickPresetIndex = ((root.pickPresetIndex + dy) % root.presets.length + root.presets.length) % root.presets.length
          } else if (dx < 0) {
            workspaceNumberField.text = ""
            root.mode = "profileEdit"
          }
        } else if (root.mode === "onboarding") {
          if (root.onboardingPhase === "ask" && dx !== 0) {
            root.cursorActive = true
            root.onboardingChoiceIndex = root.onboardingChoiceIndex === 0 ? 1 : 0
          }
        }
      }

      onActivateRequested: {
        if (root.mode === "list") root.launchSelected()
        else if (root.mode === "addType") root.chooseWindowType(root.newWindowTypeIndex)
        else if (root.mode === "pickWebapp") {
          if (root.pickWebappIndex < root.installedWebapps.length) root.choosePickedWebapp(root.pickWebappIndex)
          else root.mode = "addValue"
        } else if (root.mode === "profiles") {
          if (root.profiles.length > 0) root.activateProfile(root.profiles[root.profileIndex])
        } else if (root.mode === "assignSlot") {
          root.pickAssignSlot(root.assignSlotIndex + 1)
        } else if (root.mode === "profileAddWorkspace") {
          if (workspaceNumberField.text !== "" && root.pickPresetIndex < root.presets.length) {
            root.addWorkspaceToEditingProfile(workspaceNumberField.text, root.presets[root.pickPresetIndex].name)
            workspaceNumberField.text = ""
            root.mode = "profileEdit"
          }
        } else if (root.mode === "onboarding") {
          if (root.onboardingPhase === "ask") {
            if (root.onboardingChoiceIndex === 0) root.acceptOnboardingShortcuts()
            else root.declineOnboardingShortcuts()
          } else if (root.onboardingPhase === "done") {
            root.mode = "list"
          }
        }
      }

      onCloseRequested: {
        if (root.mode === "list") root.close()
        else if (root.mode === "edit") root.mode = "list"
        else if (root.mode === "addType") root.mode = "edit"
        else if (root.mode === "pickWebapp") root.mode = "addType"
        else if (root.mode === "profiles") root.mode = "list"
        else if (root.mode === "profileEdit") root.mode = "profiles"
        else if (root.mode === "assignSlot") root.mode = root.assignReturnMode
        else if (root.mode === "profileAddWorkspace") { workspaceNumberField.text = ""; root.mode = "profileEdit" }
        else if (root.mode === "onboarding") {
          if (root.onboardingPhase === "done") root.mode = "list"
          else if (root.onboardingPhase === "ask") root.declineOnboardingShortcuts()
        }
      }

      onDeleteRequested: {
        if (root.mode === "list" && root.presets.length > 0) {
          root.deletePresetAt(root.selectedIndex)
        } else if (root.mode === "edit") {
          var preset = root.currentPreset()
          if (preset && preset.windows && preset.windows.length > 0) root.deleteWindowAt(root.windowIndex)
        } else if (root.mode === "profiles" && root.profiles.length > 0) {
          root.deleteProfileAt(root.profileIndex)
        } else if (root.mode === "profileEdit") {
          var profile = root.currentProfile()
          if (profile && profile.workspaces && profile.workspaces.length > 0) root.deleteProfileWorkspaceAt(root.profileWorkspaceIndex)
        } else if (root.mode === "assignSlot") {
          root.clearAssigningSlot()
        }
      }

      onTabRequested: function(direction) { if (root.mode === "list") root.switchPanel(direction) }

      onTextKey: function(t) {
        // Bracket keys flip between the Presets/Profiles top-level tabs —
        // Left/Right are already claimed (dx>0 enters edit on the selected
        // row) so this needed a key of its own; [ and ] were unused anywhere
        // in this panel.
        if ((root.mode === "list" || root.mode === "profiles") && (t === "[" || t === "]")) {
          root.mode = root.mode === "list" ? "profiles" : "list"
          root.cursorActive = false
          return
        }
        if (root.mode === "list" && (t === "n" || t === "N")) {
          nameField.text = ""
          root.mode = "namePreset"
          Qt.callLater(function() { nameField.forceActiveFocus() })
        } else if (root.mode === "list" && (t === "s" || t === "S")) {
          if (root.presets.length > 0) root.enterAssignSlot("preset", root.presets[root.selectedIndex].name, "list")
        } else if (root.mode === "edit") {
          if (t === "a" || t === "A") {
            root.enterAddType()
          } else if (t === "J") {
            root.moveWindow(root.windowIndex, 1)
          } else if (t === "K") {
            root.moveWindow(root.windowIndex, -1)
          }
        } else if (root.mode === "profiles" && (t === "n" || t === "N")) {
          profileNameField.text = ""
          root.mode = "nameProfile"
          Qt.callLater(function() { profileNameField.forceActiveFocus() })
        } else if (root.mode === "profiles" && (t === "s" || t === "S")) {
          if (root.profiles.length > 0) root.enterAssignSlot("profile", root.profiles[root.profileIndex].name, "profiles")
        } else if (root.mode === "profileEdit") {
          if (t === "a" || t === "A") {
            if (root.presets.length > 0) root.enterProfileAddWorkspace()
          } else if (t === "J") {
            root.moveProfileWorkspace(root.profileWorkspaceIndex, 1)
          } else if (t === "K") {
            root.moveProfileWorkspace(root.profileWorkspaceIndex, -1)
          } else if (t === "d" || t === "D") {
            var profile = root.currentProfile()
            if (profile) root.setProfileDefault(root.editingProfileIndex)
          }
        }
      }

      // The base KeyboardPanel is a fixed-size card with no scrolling of its
      // own — content past contentHeight was silently clipped (the webapp
      // picker's last row went unreachable once the list outgrew the panel).
      // Wrapping the content in a Flickable makes the overflow reachable by
      // wheel/drag/scrollbar; scrollItemIntoView() above keeps keyboard nav
      // in sync so an arrow-key cursor never lands on a hidden row.
      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: column
        width: panelFlick.width
        spacing: Style.space(10)

        Text {
          visible: root.saveError !== ""
          width: parent.width
          text: root.saveError
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Button {
          visible: root.saveError !== ""
          enabled: root.writingPath === ""
          width: parent.width
          text: "Retry saving"
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: true
          onClicked: root.startNextWrite()
        }

        // Presets and Profiles are peers, not nested — this strip is the
        // whole reason "Profiles →" (a row buried inside the preset list)
        // went away. [ and ] flip it from the keyboard from either top-level
        // list; clicking works from anywhere either tab is visible.
        Row {
          visible: root.mode === "list" || root.mode === "profiles"
          width: parent.width
          spacing: Style.spacing.sm

          Button {
            width: (parent.width - parent.spacing) / 2
            text: "Presets"
            bordered: true
            selected: root.mode === "list"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: { root.mode = "list"; root.cursorActive = false }
          }

          Button {
            width: (parent.width - parent.spacing) / 2
            text: "Profiles"
            bordered: true
            selected: root.mode === "profiles"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: { root.mode = "profiles"; root.cursorActive = false }
          }
        }

        PanelSectionHeader {
          width: parent.width
          text: {
            if (root.mode === "edit") { var p = root.currentPreset(); return (p ? p.name : "Edit").toUpperCase() }
            if (root.mode === "addType") return "ADD WINDOW · TYPE"
            if (root.mode === "pickWebapp") return "ADD WINDOW · WEB APP"
            if (root.mode === "addValue") return "ADD WINDOW"
            if (root.mode === "namePreset") return "NEW PRESET"
            if (root.mode === "profiles") return "PROFILES"
            if (root.mode === "profileEdit") { var pr = root.currentProfile(); return (pr ? pr.name : "Profile").toUpperCase() }
            if (root.mode === "profileAddWorkspace") return "ADD WORKSPACE"
            if (root.mode === "nameProfile") return "NEW PROFILE"
            if (root.mode === "assignSlot") return "ASSIGN SHORTCUT"
            if (root.mode === "activating") return "ACTIVATING"
            if (root.mode === "onboarding") return "WELCOME"
            return "PRESETS"
          }
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        // ---------- onboarding: shown once, on the very first open ----------
        Column {
          visible: root.mode === "onboarding"
          width: parent.width
          spacing: Style.space(10)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Presets launch a saved set of windows at once. Profiles do the same for whole workspaces, on command or at login."
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Column {
            visible: root.onboardingPhase === "ask"
            width: parent.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Want quick-launch keyboard shortcuts? This adds a few lines to your Hyprland config so any preset or profile can fire with SUPER+CTRL+SHIFT/ALT+1-9, no panel needed. Your config is backed up first, and rolled back automatically if anything doesn't apply cleanly."
              color: Qt.darker(root.foreground, 1.55)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Row {
              width: parent.width
              spacing: Style.spacing.md

              Button {
                width: (parent.width - parent.spacing) / 2
                text: "Yes, set them up"
                bordered: true
                selected: true
                hasCursor: root.cursorActive && root.onboardingChoiceIndex === 0
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: { root.cursorActive = true; root.onboardingChoiceIndex = 0; root.acceptOnboardingShortcuts() }
              }

              Button {
                width: (parent.width - parent.spacing) / 2
                text: "No thanks"
                bordered: true
                hasCursor: root.cursorActive && root.onboardingChoiceIndex === 1
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: { root.cursorActive = true; root.onboardingChoiceIndex = 1; root.declineOnboardingShortcuts() }
              }
            }
          }

          Text {
            visible: root.onboardingPhase === "running"
            textFormat: Text.PlainText
            width: parent.width
            text: "Setting up your shortcuts…"
            color: Qt.darker(root.foreground, 1.55)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Column {
            visible: root.onboardingPhase === "done"
            width: parent.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: {
                var r = root.onboardingResult
                if (!r) return ""
                if (r.result === "success") return "Done — SUPER+CTRL+SHIFT+1-9 and SUPER+CTRL+ALT+1-9 are ready. Assign one from the ⌨ button on any preset or profile row."
                if (r.result === "already-installed") return "Looks like these shortcuts are already set up on this machine — nothing to do."
                if (r.result === "error") return "Couldn't find ~/.config/hypr/bindings.lua, so nothing was changed. Add the snippet from the README's Setup section by hand whenever you're ready."
                return "That didn't apply cleanly, so nothing was changed — your bindings.lua is exactly as it was. Paste the snippet from the README's Setup section in by hand if you'd still like shortcuts."
              }
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              visible: !!(root.onboardingResult && root.onboardingResult.result === "failed" && root.onboardingResult.error)
              width: parent.width
              text: root.onboardingResult ? String(root.onboardingResult.error || "") : ""
              color: Qt.darker(root.foreground, 1.55)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Button {
              width: parent.width
              text: "Get started"
              bordered: true
              selected: true
              hasCursor: root.cursorActive
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.body
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.mode = "list"
            }
          }
        }

        // ---------- list: pick / launch a preset ----------
        Column {
          visible: root.mode === "list"
          width: parent.width
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            visible: root.presets.length === 0
            width: parent.width
            text: "No presets yet — use + New preset below."
            color: Qt.darker(root.foreground, 1.55)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Repeater {
            id: presetRepeater
            model: root.mode === "list" ? root.presets : []

            Row {
              id: presetRow
              required property var modelData
              required property int index

              width: parent.width
              spacing: Style.spacing.sm

              Button {
                id: launchBtn
                width: presetRow.width - editBtn.implicitWidth - shortcutBtn.implicitWidth - deleteBtn.implicitWidth - presetRow.spacing * 3
                // clip: true is the hard backstop — Button's inner Row sizes to
                // its content, not to this width, so a char-count elide() that
                // guesses even slightly too generously for the actual font
                // metrics would otherwise still paint past the button's edge.
                clip: true
                text: root.elide(presetRow.modelData.name || ("Preset " + (presetRow.index + 1)), 22) + "  ·  " + ((presetRow.modelData.windows ? presetRow.modelData.windows.length : 0)) + " window" + ((presetRow.modelData.windows && presetRow.modelData.windows.length === 1) ? "" : "s")
                  + (root.shortcutSlotForItem("preset", presetRow.modelData.name) ? "  ·  ⌨" + root.shortcutSlotForItem("preset", presetRow.modelData.name) : "")
                leftAlign: true
                bordered: true
                hasCursor: root.cursorActive && presetRow.index === root.selectedIndex
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.body
                verticalPadding: Style.spacing.controlPaddingY
                tooltipText: "Launch this preset"

                onClicked: {
                  root.cursorActive = true
                  root.selectedIndex = presetRow.index
                  root.launchSelected()
                }
                onHovered: function(isHovered) {
                  if (isHovered) { root.cursorActive = true; root.selectedIndex = presetRow.index }
                }
              }

              Button {
                id: editBtn
                text: "Edit"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                tooltipText: "Edit this preset's windows"
                onClicked: { root.cursorActive = true; root.selectedIndex = presetRow.index; root.enterEdit(presetRow.index) }
              }

              Button {
                id: shortcutBtn
                text: "⌨"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                tooltipText: "Assign a SUPER+CTRL+SHIFT+1-9 quick-launch shortcut"
                onClicked: { root.cursorActive = true; root.selectedIndex = presetRow.index; root.enterAssignSlot("preset", presetRow.modelData.name, "list") }
              }

              Button {
                id: deleteBtn
                text: "✕"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                tooltipText: "Delete this preset"
                onClicked: root.deletePresetAt(presetRow.index)
              }
            }
          }

          Button {
            width: parent.width
            text: "+ New preset"
            leftAlign: true
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.body
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: {
              root.cursorActive = false
              nameField.text = ""
              root.mode = "namePreset"
              Qt.callLater(function() { nameField.forceActiveFocus() })
            }
          }

        }

        // ---------- edit: one preset's ordered window list ----------
        Column {
          visible: root.mode === "edit"
          width: parent.width
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Top-to-bottom order below = left-to-right window order when launched."
            color: Qt.darker(root.foreground, 1.55)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: root.mode === "edit" && (!root.currentPreset() || !root.currentPreset().windows || root.currentPreset().windows.length === 0)
            width: parent.width
            text: "No windows yet — use + Add window below."
            color: Qt.darker(root.foreground, 1.55)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Repeater {
            id: windowRepeater
            model: (root.mode === "edit" && root.currentPreset() && root.currentPreset().windows) ? root.currentPreset().windows : []

            Row {
              id: windowRow
              required property var modelData
              required property int index

              width: parent.width
              spacing: Style.spacing.sm

              Button {
                id: selectBtn
                width: windowRow.width - upBtn.implicitWidth - downBtn.implicitWidth - delBtn.implicitWidth - windowRow.spacing * 3
                // clip: true — same reasoning as launchBtn above. This is the
                // row that showed a terminal command's full value spilling
                // out of the panel.
                clip: true
                iconText: root.windowTypeIcons[windowRow.modelData.type] || ""
                text: (windowRow.index + 1) + ". " + root.elide(windowRow.modelData.label || windowRow.modelData.value, 26)
                leftAlign: true
                bordered: true
                hasCursor: root.cursorActive && windowRow.index === root.windowIndex
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.body
                verticalPadding: Style.spacing.controlPaddingY
                tooltipText: root.windowTypeLabels[windowRow.modelData.type] + ": " + (windowRow.modelData.label || windowRow.modelData.value)

                onClicked: { root.cursorActive = true; root.windowIndex = windowRow.index }
                onHovered: function(isHovered) {
                  if (isHovered) { root.cursorActive = true; root.windowIndex = windowRow.index }
                }
              }

              Button {
                id: upBtn
                text: "↑"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                tooltipText: "Move earlier (left)"
                onClicked: root.moveWindow(windowRow.index, -1)
              }

              Button {
                id: downBtn
                text: "↓"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                tooltipText: "Move later (right)"
                onClicked: root.moveWindow(windowRow.index, 1)
              }

              Button {
                id: delBtn
                text: "✕"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                tooltipText: "Remove this window"
                onClicked: root.deleteWindowAt(windowRow.index)
              }
            }
          }

          Button {
            width: parent.width
            text: "+ Add window"
            leftAlign: true
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.body
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.enterAddType()
          }

          Button {
            width: parent.width
            text: "← Back to presets"
            leftAlign: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.mode = "list"
          }
        }

        // ---------- addType: pick terminal / webapp / custom ----------
        Column {
          visible: root.mode === "addType"
          width: parent.width
          spacing: Style.space(6)

          Row {
            width: parent.width
            spacing: Style.spacing.md

            readonly property real cellWidth: (width - spacing * 2) / 3

            Repeater {
              model: root.mode === "addType" ? root.windowTypes : []

              Button {
                required property var modelData
                required property int index

                width: parent.cellWidth
                iconText: root.windowTypeIcons[modelData] || ""
                text: root.windowTypeLabels[modelData]
                selected: index === root.newWindowTypeIndex
                hasCursor: root.cursorActive && index === root.newWindowTypeIndex
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY

                onClicked: {
                  root.cursorActive = true
                  root.chooseWindowType(index)
                }
                onHovered: function(isHovered) { if (isHovered) { root.cursorActive = true; root.newWindowTypeIndex = index } }
              }
            }
          }

          Button {
            width: parent.width
            text: "← Back"
            leftAlign: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.mode = "edit"
          }
        }

        // ---------- pickWebapp: choose an installed web app ----------
        Column {
          visible: root.mode === "pickWebapp"
          width: parent.width
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            visible: root.installedWebapps.length === 0
            width: parent.width
            text: "No installed web apps found. Use Custom URL below, or install one first (omarchy webapp install)."
            color: Qt.darker(root.foreground, 1.55)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Repeater {
            id: webappRepeater
            model: root.mode === "pickWebapp" ? root.installedWebapps : []

            Button {
              required property var modelData
              required property int index

              width: parent.width
              clip: true
              iconText: root.windowTypeIcons.webapp
              text: root.elide(modelData.name, 40)
              leftAlign: true
              bordered: true
              hasCursor: root.cursorActive && index === root.pickWebappIndex
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.body
              verticalPadding: Style.spacing.controlPaddingY
              tooltipText: modelData.url

              onClicked: {
                root.cursorActive = true
                root.pickWebappIndex = index
                root.choosePickedWebapp(index)
              }
              onHovered: function(isHovered) { if (isHovered) { root.cursorActive = true; root.pickWebappIndex = index } }
            }
          }

          Button {
            id: customUrlBtn
            width: parent.width
            text: "Custom URL…"
            leftAlign: true
            bordered: true
            hasCursor: root.cursorActive && root.pickWebappIndex === root.installedWebapps.length
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.body
            verticalPadding: Style.spacing.controlPaddingY

            onClicked: {
              root.cursorActive = true
              root.pickWebappIndex = root.installedWebapps.length
              root.mode = "addValue"
            }
            onHovered: function(isHovered) { if (isHovered) { root.cursorActive = true; root.pickWebappIndex = root.installedWebapps.length } }
          }

          Button {
            width: parent.width
            text: "← Back"
            leftAlign: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.mode = "addType"
          }
        }

        // ---------- addValue: text entry for a command / custom URL ----------
        Column {
          visible: root.mode === "addValue"
          width: parent.width
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Title (optional) — shown in the list instead of the raw value, e.g. \"Say Hello\" or \"System Monitor\"."
            color: Qt.darker(root.foreground, 1.55)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          TextField {
            id: titleField
            width: parent.width
            foreground: root.foreground
            placeholderText: "Title (optional)"

            onAccepted: valueField.forceActiveFocus()
            Keys.onEscapePressed: {
              text = ""; valueField.text = ""
              root.mode = (root.windowTypes[root.newWindowTypeIndex] === "webapp") ? "pickWebapp" : "addType"
            }

            onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            topPadding: Style.space(4)
            text: root.windowTypePrompts[root.windowTypes[root.newWindowTypeIndex]] || ""
            color: Qt.darker(root.foreground, 1.55)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          TextField {
            id: valueField
            width: parent.width
            foreground: root.foreground
            placeholderText: root.windowTypeLabels[root.windowTypes[root.newWindowTypeIndex]] || ""

            onAccepted: { root.saveNewWindowValue(text, titleField.text); text = ""; titleField.text = "" }
            Keys.onEscapePressed: {
              text = ""; titleField.text = ""
              root.mode = (root.windowTypes[root.newWindowTypeIndex] === "webapp") ? "pickWebapp" : "addType"
            }
          }

          Row {
            width: parent.width
            spacing: Style.spacing.md

            Button {
              width: (parent.width - parent.spacing) / 2
              text: "Save"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: { root.saveNewWindowValue(valueField.text, titleField.text); valueField.text = ""; titleField.text = "" }
            }

            Button {
              width: (parent.width - parent.spacing) / 2
              text: "← Back"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: {
                valueField.text = ""; titleField.text = ""
                root.mode = (root.windowTypes[root.newWindowTypeIndex] === "webapp") ? "pickWebapp" : "addType"
              }
            }
          }
        }

        // ---------- namePreset: text entry for a brand new preset's name ----------
        Column {
          visible: root.mode === "namePreset"
          width: parent.width
          spacing: Style.space(6)

          TextField {
            id: nameField
            width: parent.width
            foreground: root.foreground
            placeholderText: "Preset name"

            onAccepted: { root.submitNewPresetName(text); text = "" }
            Keys.onEscapePressed: { text = ""; root.mode = "list" }

            onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
          }

          Row {
            width: parent.width
            spacing: Style.spacing.md

            Button {
              width: (parent.width - parent.spacing) / 2
              text: "Save"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: { root.submitNewPresetName(nameField.text); nameField.text = "" }
            }

            Button {
              width: (parent.width - parent.spacing) / 2
              text: "Cancel"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: { nameField.text = ""; root.mode = "list" }
            }
          }
        }

        // ---------- profiles: pick / launch / manage a profile ----------
        Column {
          visible: root.mode === "profiles"
          width: parent.width
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "A profile maps workspace numbers to presets, and launches them all together."
            color: Qt.darker(root.foreground, 1.55)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: root.profiles.length === 0
            width: parent.width
            text: "No profiles yet — use + New profile below."
            color: Qt.darker(root.foreground, 1.55)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Repeater {
            id: profileRepeater
            model: root.mode === "profiles" ? root.profiles : []

            Row {
              id: profileRow
              required property var modelData
              required property int index

              width: parent.width
              spacing: Style.spacing.sm

              Button {
                id: activateBtn
                width: profileRow.width - profileEditBtn.implicitWidth - profileShortcutBtn.implicitWidth - profileDeleteBtn.implicitWidth - profileRow.spacing * 3
                clip: true
                iconText: profileRow.modelData.default ? "" : ""
                text: root.elide(profileRow.modelData.name, 16) + "  ·  "
                  + ((profileRow.modelData.workspaces ? profileRow.modelData.workspaces.length : 0)) + " workspace"
                  + ((profileRow.modelData.workspaces && profileRow.modelData.workspaces.length === 1) ? "" : "s")
                  + (profileRow.modelData.default ? "  ·  default" : "")
                  + (root.shortcutSlotForItem("profile", profileRow.modelData.name) ? "  ·  ⌨" + root.shortcutSlotForItem("profile", profileRow.modelData.name) : "")
                leftAlign: true
                bordered: true
                hasCursor: root.cursorActive && profileRow.index === root.profileIndex
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.body
                verticalPadding: Style.spacing.controlPaddingY
                tooltipText: "Activate this profile"

                onClicked: {
                  root.cursorActive = true
                  root.profileIndex = profileRow.index
                  root.activateProfile(profileRow.modelData)
                }
                onHovered: function(isHovered) {
                  if (isHovered) { root.cursorActive = true; root.profileIndex = profileRow.index }
                }
              }

              Button {
                id: profileEditBtn
                text: "Edit"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                tooltipText: "Edit this profile's workspaces"
                onClicked: { root.cursorActive = true; root.profileIndex = profileRow.index; root.enterProfileEdit(profileRow.index) }
              }

              Button {
                id: profileShortcutBtn
                text: "⌨"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                tooltipText: "Assign a SUPER+CTRL+ALT+1-9 quick-launch shortcut"
                onClicked: { root.cursorActive = true; root.profileIndex = profileRow.index; root.enterAssignSlot("profile", profileRow.modelData.name, "profiles") }
              }

              Button {
                id: profileDeleteBtn
                text: "✕"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                tooltipText: "Delete this profile"
                onClicked: root.deleteProfileAt(profileRow.index)
              }
            }
          }

          Button {
            width: parent.width
            text: "+ New profile"
            leftAlign: true
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.body
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: {
              root.cursorActive = false
              profileNameField.text = ""
              root.mode = "nameProfile"
              Qt.callLater(function() { profileNameField.forceActiveFocus() })
            }
          }
        }

        // ---------- profileEdit: one profile's workspace -> preset list ----------
        Column {
          visible: root.mode === "profileEdit"
          width: parent.width
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Each row is a workspace this profile sets up. Order doesn't matter here — the workspace number does."
            color: Qt.darker(root.foreground, 1.55)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: root.mode === "profileEdit" && (!root.currentProfile() || !root.currentProfile().workspaces || root.currentProfile().workspaces.length === 0)
            width: parent.width
            text: "No workspaces yet — use + Add workspace below."
            color: Qt.darker(root.foreground, 1.55)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Repeater {
            id: profileWorkspaceRepeater
            model: (root.mode === "profileEdit" && root.currentProfile() && root.currentProfile().workspaces) ? root.currentProfile().workspaces : []

            Row {
              id: pwRow
              required property var modelData
              required property int index

              width: parent.width
              spacing: Style.spacing.sm

              Button {
                id: pwSelectBtn
                width: pwRow.width - pwUpBtn.implicitWidth - pwDownBtn.implicitWidth - pwDelBtn.implicitWidth - pwRow.spacing * 3
                clip: true
                text: "Workspace " + pwRow.modelData.workspace + "  →  " + root.elide(pwRow.modelData.preset, 20)
                leftAlign: true
                bordered: true
                hasCursor: root.cursorActive && pwRow.index === root.profileWorkspaceIndex
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.body
                verticalPadding: Style.spacing.controlPaddingY

                onClicked: { root.cursorActive = true; root.profileWorkspaceIndex = pwRow.index }
                onHovered: function(isHovered) {
                  if (isHovered) { root.cursorActive = true; root.profileWorkspaceIndex = pwRow.index }
                }
              }

              Button {
                id: pwUpBtn
                text: "↑"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.moveProfileWorkspace(pwRow.index, -1)
              }

              Button {
                id: pwDownBtn
                text: "↓"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.moveProfileWorkspace(pwRow.index, 1)
              }

              Button {
                id: pwDelBtn
                text: "✕"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                tooltipText: "Remove this workspace"
                onClicked: root.deleteProfileWorkspaceAt(pwRow.index)
              }
            }
          }

          Button {
            width: parent.width
            text: "+ Add workspace"
            leftAlign: true
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.body
            verticalPadding: Style.spacing.controlPaddingY
            enabled: root.presets.length > 0
            tooltipText: root.presets.length === 0 ? "Create a preset first" : ""
            onClicked: root.enterProfileAddWorkspace()
          }

          PanelSectionHeader {
            width: parent.width
            text: "WHEN ACTIVATING"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.currentProfile() ? (root.closeModeHints[root.currentProfile().closeMode] || "") : ""
            color: Qt.darker(root.foreground, 1.55)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.mode === "profileEdit" ? root.closeModes : []

            Button {
              required property string modelData
              width: parent.width
              leftAlign: true
              bordered: true
              text: root.closeModeLabels[modelData]
              selected: root.currentProfile() && root.currentProfile().closeMode === modelData
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.setProfileCloseMode(modelData)
            }
          }

          PanelSectionHeader {
            width: parent.width
            text: "STARTUP"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Button {
            width: parent.width
            leftAlign: true
            bordered: true
            text: (root.currentProfile() && root.currentProfile().default)
              ? "✓ Runs when Omarchy starts"
              : "Set as the profile that runs at startup"
            selected: !!(root.currentProfile() && root.currentProfile().default)
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            verticalPadding: Style.spacing.controlPaddingY
            tooltipText: "Only one profile can run at startup"
            onClicked: root.setProfileDefault(root.editingProfileIndex)
          }

          Button {
            width: parent.width
            text: "← Back to profiles"
            leftAlign: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.mode = "profiles"
          }
        }

        // ---------- profileAddWorkspace: pick a workspace number + preset ----------
        Column {
          visible: root.mode === "profileAddWorkspace"
          width: parent.width
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Workspace number, then pick the preset it should open:"
            color: Qt.darker(root.foreground, 1.55)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          TextField {
            id: workspaceNumberField
            width: parent.width
            foreground: root.foreground
            placeholderText: "Workspace number (e.g. 1)"
            validator: IntValidator { bottom: 1; top: 99 }

            // Enter or Down hands focus to the key catcher below, which
            // un-blocks it (see `blocked` above) so ↑/↓ + Enter can pick a
            // preset — the field's own text stays put, only focus moves.
            onAccepted: if (text !== "") { root.cursorActive = true; keyCatcher.forceActiveFocus() }
            Keys.onDownPressed: if (text !== "") { root.cursorActive = true; keyCatcher.forceActiveFocus() }
            Keys.onEscapePressed: { text = ""; root.mode = "profileEdit" }
            onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
          }

          Text {
            textFormat: Text.PlainText
            visible: root.presets.length === 0
            width: parent.width
            text: "No presets exist yet — back out and create one first."
            color: Qt.darker(root.foreground, 1.55)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Repeater {
            id: pickPresetRepeater
            model: root.mode === "profileAddWorkspace" ? root.presets : []

            Button {
              required property var modelData
              required property int index

              width: parent.width
              clip: true
              text: root.elide(modelData.name, 40)
              leftAlign: true
              bordered: true
              hasCursor: root.cursorActive && index === root.pickPresetIndex
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.body
              verticalPadding: Style.spacing.controlPaddingY
              enabled: workspaceNumberField.text !== ""
              tooltipText: workspaceNumberField.text === "" ? "Enter a workspace number first" : "Assign this preset to that workspace"

              onClicked: {
                root.cursorActive = true
                root.pickPresetIndex = index
                if (workspaceNumberField.text !== "") {
                  root.addWorkspaceToEditingProfile(workspaceNumberField.text, modelData.name)
                  workspaceNumberField.text = ""
                  root.mode = "profileEdit"
                  // A mouse click here can land while the field still has
                  // Qt focus (never pressed Enter/Down to hand it off) — same
                  // stale-focus issue as the submit* functions elsewhere.
                  Qt.callLater(function() { keyCatcher.forceActiveFocus() })
                }
              }
              onHovered: function(isHovered) { if (isHovered) { root.cursorActive = true; root.pickPresetIndex = index } }
            }
          }

          Button {
            width: parent.width
            text: "← Back"
            leftAlign: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: { workspaceNumberField.text = ""; root.mode = "profileEdit" }
          }
        }

        // ---------- nameProfile: text entry for a brand new profile's name ----------
        Column {
          visible: root.mode === "nameProfile"
          width: parent.width
          spacing: Style.space(6)

          TextField {
            id: profileNameField
            width: parent.width
            foreground: root.foreground
            placeholderText: "Profile name"

            onAccepted: { root.submitNewProfileName(text); text = "" }
            Keys.onEscapePressed: { text = ""; root.mode = "profiles" }

            onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
          }

          Row {
            width: parent.width
            spacing: Style.spacing.md

            Button {
              width: (parent.width - parent.spacing) / 2
              text: "Save"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: { root.submitNewProfileName(profileNameField.text); profileNameField.text = "" }
            }

            Button {
              width: (parent.width - parent.spacing) / 2
              text: "Cancel"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: { profileNameField.text = ""; root.mode = "profiles" }
            }
          }
        }

        // ---------- assignSlot: pick a 1-9 quick-launch slot ----------
        Column {
          visible: root.mode === "assignSlot"
          width: parent.width
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.assigningFamily === "preset"
              ? "Assign \"" + root.assigningName + "\" to a SUPER+CTRL+SHIFT+ number:"
              : "Assign \"" + root.assigningName + "\" to a SUPER+CTRL+ALT+ number:"
            color: Qt.darker(root.foreground, 1.55)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Repeater {
            id: assignSlotRepeater
            model: root.mode === "assignSlot" ? 9 : 0

            Button {
              required property int index
              readonly property int slotNum: index + 1
              readonly property var occupant: root.shortcutAt(root.assigningFamily, slotNum)
              readonly property bool isMine: !!occupant && occupant.name === root.assigningName

              width: parent.width
              leftAlign: true
              bordered: true
              clip: true
              selected: isMine
              hasCursor: root.cursorActive && index === root.assignSlotIndex
              text: "Slot " + slotNum + "  —  " + (occupant ? (isMine ? "this one" : root.elide(occupant.name, 24)) : "free")
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.body
              verticalPadding: Style.spacing.controlPaddingY

              onClicked: { root.cursorActive = true; root.assignSlotIndex = index; root.pickAssignSlot(slotNum) }
              onHovered: function(isHovered) { if (isHovered) { root.cursorActive = true; root.assignSlotIndex = index } }
            }
          }

          Button {
            visible: root.shortcutSlotForItem(root.assigningFamily, root.assigningName) > 0
            width: parent.width
            text: "Clear shortcut"
            leftAlign: true
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.clearAssigningSlot()
          }

          Button {
            width: parent.width
            text: "← Back"
            leftAlign: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.mode = root.assignReturnMode
          }
        }

        // ---------- activating: live progress while a profile launches ----------
        Column {
          visible: root.mode === "activating"
          width: parent.width
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.activationError || (root.activationRunning ? "Setting things up — hang on…"
              : root.activationComplete ? "All set." : "Activation stopped.")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Repeater {
            model: root.mode === "activating" ? root.activationSteps : []

            Row {
              required property var modelData
              width: parent.width
              spacing: Style.spacing.sm

              Text {
                textFormat: Text.PlainText
                text: modelData.status === "done" ? "✓" : modelData.status === "failed" ? "!" : "⏳"
                color: modelData.status === "done" ? root.foreground : Qt.darker(root.foreground, 1.55)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                textFormat: Text.PlainText
                text: "Workspace " + modelData.workspace + " → " + modelData.preset
                color: modelData.status === "done" ? root.foreground : Qt.darker(root.foreground, 1.55)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
                width: parent.width - 24
              }
            }
          }

          Button {
            visible: !root.activationRunning
            width: parent.width
            text: "Close"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.body
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.close()
          }
        }

        // ---------- footer: plain-language hint, one line per mode ----------
        Text {
          textFormat: Text.PlainText
          width: parent.width
          topPadding: Style.space(4)
          text: {
            if (root.mode === "list") return "Click a preset to launch it, or use Edit / Delete / + New preset."
            if (root.mode === "edit") return "Use + Add window, or ↑ / ↓ to reorder and ✕ to remove a row."
            if (root.mode === "addType") return "Choose what kind of window to add."
            if (root.mode === "pickWebapp") return "Pick one of your installed web apps, or add a custom URL."
            if (root.mode === "addValue") return "Type the value, then click Save."
            if (root.mode === "namePreset") return "Name your new preset, then click Save."
            if (root.mode === "profiles") return "Click a profile to activate it, or use Edit / Delete / + New profile."
            if (root.mode === "profileEdit") return "Add workspaces, choose what happens to existing windows, and optionally set this as your startup profile."
            if (root.mode === "profileAddWorkspace") return "Enter a workspace number, then click the preset it should open."
            if (root.mode === "nameProfile") return "Name your new profile, then click Save."
            if (root.mode === "assignSlot") return "Pick a free slot, or click one you already used to move the shortcut here."
            if (root.mode === "activating") return root.activationRunning ? "Please wait, setting up your workspaces…" : "You can close this now."
            return ""
          }
          color: Qt.darker(root.foreground, 1.55)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
        }

        Text {
          textFormat: Text.PlainText
          visible: root.mode === "list" || root.mode === "edit" || root.mode === "profiles" || root.mode === "profileEdit"
          width: parent.width
          text: {
            if (root.mode === "list") return "Keyboard: Enter launch · l edit · s shortcut · n new · x delete · [/] tabs"
            if (root.mode === "edit") return "Keyboard: a add · Shift+J/K reorder · x delete · Esc back"
            if (root.mode === "profiles") return "Keyboard: Enter activate · l edit · s shortcut · n new · x delete · [/] tabs"
            return "Keyboard: a add · Shift+J/K reorder · d set default · x delete · Esc back"
          }
          color: Qt.darker(root.foreground, 1.9)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
        }
      }
      }
    }
  }
}
