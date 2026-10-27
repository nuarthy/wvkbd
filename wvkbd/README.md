# wvkbd

An on-screen keyboard plugin for [Noctalia](https://docs.noctalia.dev/noctalia/) v5. It
starts [`wvkbd`](https://github.com/jjsullivan5196/wvkbd), keeps it for the session, and
toggles it from a bar pill or a keybinding.

The plugin draws no keyboard of its own. wvkbd compiles its layout, colours, and layers
from the build it comes from, so a custom build looks and types exactly as it did before
the plugin existed.

| Field | Value |
| --- | --- |
| ID | `nuarthy/wvkbd` |
| Plugin API | 34 |
| Entries | service `service`, bar widget `keyboard` |

## Requirements

- Noctalia v5.3.0 or later
- A wvkbd binary: `wvkbd-custom`, `wvkbd-mobintl`, or `wvkbd-deskintl`
- A compositor that exposes `zwp_virtual_keyboard_manager_v1` (niri, sway, Hyprland, labwc)

```shell
# Fedora
sudo dnf install wvkbd
# Arch Linux
sudo pacman -S wvkbd
# Debian and Ubuntu
sudo apt install wvkbd
```

A build from source works too. The plugin finds `wvkbd-custom`, `wvkbd-mobintl`, and
`wvkbd-deskintl` on `PATH`, then in `~/applications/wvkbd`, where
`make LAYOUT=custom` leaves the binary of the wvkbd checkout.

## Install

```shell
noctalia msg plugins source add nuarthy git https://github.com/nuarthy/noctalia-wvkbd
noctalia msg plugins enable nuarthy/wvkbd
```

To work on the plugin, symlink the plugin directory into the plugin folder instead:

```shell
ln -sfn ~/Projects/noctalia-wvkbd/wvkbd ~/.local/share/noctalia/plugins/wvkbd
noctalia msg plugins enable nuarthy/wvkbd
```

Edits to `.luau` files reload automatically. `noctalia msg config-reload` picks up
manifest changes.

## Add it to the bar

The keyboard pill is a bar widget. Add it in **Settings → Bar**, or append the entry to a
bar in the shell settings:

```toml
[bar.default]
end = [ "tray", "volume", "nuarthy/wvkbd:keyboard", "notifications" ]
```

The pill is glyph-only, so it fits a horizontal bar and the capsule of a vertical one. The
glyph is `keyboard-off` in the muted foreground while the keyboard is hidden, `keyboard` in
the accent colour while it is up, and `keyboard-off` in the error colour when no binary is
found; the tooltip gives the reason.

## Use

| Action | Result |
| --- | --- |
| Left-click the pill | Show the keyboard, or hide it while it is up. |
| Right-click the pill | Open the plugin settings. |
| Keybinding | The same toggle, with no pill placed. |

```kdl
// niri
binds {
    Mod+Shift+K { spawn "noctalia" "msg" "plugin" "nuarthy/wvkbd:service" "all" "toggle"; }
}
```

## How it runs wvkbd

The service starts the binary docked and visible, and by default the second click ends the
process — the same toggle an older shell script did, with nothing left holding a virtual
keyboard device. Set **When hidden → Keep it loaded** to leave wvkbd running and hide it
with `SIGUSR1` instead; showing it again is then a `SIGUSR2` away and does not re-take the
compositor's keyboard. The process always stops when the plugin is disabled or reloaded,
and when Noctalia exits.

Every two seconds the service compares its state with the process table. A wvkbd started
outside the plugin, such as by an older toggle script, is adopted instead of doubled, and
a keyboard that dies on its own returns the pill to "hidden".

A failed start writes wvkbd's own output to
`$XDG_STATE_HOME/noctalia/plugins/data/nuarthy/wvkbd/wvkbd.log`; the pill and the failure
notification quote its last lines.

## Colours

The keyboard follows the active Noctalia palette by default. The surface becomes the
keyboard background, the surface variant the keys, the secondary container the special keys,
and the accent the pressed key; the text roles come from the palette's `on_*` counterparts.
Switching theme mode or changing the wallpaper repaints a running keyboard within two
seconds.

wvkbd reads its colours once, at startup, so the plugin passes them as flags on the command
line and restarts the process when the palette moves. Set **Colours → From the binary** to
stop passing them and keep whatever palette the build carries.

## Settings

| Setting | Default | Notes |
| --- | --- | --- |
| wvkbd binary | empty | A path, a command name, or empty to auto-detect. |
| Height | 0 | Docked height in pixels. 0 uses 30% of the output height. |
| Layers | empty | Layouts to cycle through, such as `full,special`. Empty keeps the compiled-in layers. |
| Font | empty | Pango font for the key labels, such as `Sans 14`. Empty keeps the compiled-in font. |
| Key rounding | -1 | Corner radius in pixels. -1 keeps the compiled-in radius. |
| Colours | Follow the shell palette | The keyboard takes its colours from the active Noctalia palette; **From the binary** keeps the palette compiled into wvkbd. |
| When hidden | Stop the process | **Keep it loaded** hides the keyboard with `SIGUSR1` instead of ending it. |

## IPC commands

```shell
noctalia msg plugin nuarthy/wvkbd:service all toggle    # Show or hide
noctalia msg plugin nuarthy/wvkbd:service all show      # Show
noctalia msg plugin nuarthy/wvkbd:service all hide      # Hide, leave the process running
noctalia msg plugin nuarthy/wvkbd:service all stop      # Hide and end the process
noctalia msg plugin nuarthy/wvkbd:service all restart   # Re-read the settings and start again
noctalia msg plugin nuarthy/wvkbd:service all status    # Log the state as JSON
```

`status` writes the JSON to `~/.cache/noctalia/noctalia.log` and shows a notification,
because plugin IPC has no return channel.

## Troubleshooting

- **The pill is red and the tooltip says no binary was found.** Install wvkbd, or set the
  full path of your build under **Settings → Plugins → wvkbd**. The service retries every
  two seconds, so no restart is needed.
- **The keyboard appears, then closes.** Check the compositor's virtual keyboard support
  and the tail of
  `$XDG_STATE_HOME/noctalia/plugins/data/nuarthy/wvkbd/wvkbd.log`.
- **Keys do not reach the focused window.** Some compositors do not route
  `zwp_virtual_keyboard_v1` keys through their own keybindings. Typing still works in
  applications.
- **The keyboard opens on another display.** wvkbd uses the display that holds keyboard focus
  when it starts, and a palette change restarts it. Put the pointer on the target display, then
  click the pill again.
- **The keyboard covers a window instead of shrinking it.** wvkbd asks for an exclusive
  zone at the bottom. A build started with `--non-exclusive` overlays windows instead; put
  that flag in a wrapper script and point the binary setting at it.

## License

MIT. See [LICENSE](../LICENSE).
