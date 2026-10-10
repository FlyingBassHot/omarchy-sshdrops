# Developing SSHDrops

The plugin is a git repo, so the loop is: edit here, sync to
`~/.config/omarchy/plugins/`, reload the shell.

```bash
# one-time
cd ~/Work/myomarchy-plugins/omarchy-sshdrops
git init && git add -A && git commit -m "SSHDrops: initial"

# every change
rsync -a --delete --exclude .git --exclude tests . \
  ~/.config/omarchy/plugins/io.github.flyingbasshot.sshdrops/
omarchy restart shell
```

`--exclude .git` matters: the installed copy is what the shell loads, and
copying a `.git` into it confuses `omarchy plugin update`.

## Tests

Run these before every commit. They load `Model.js` directly — the same file
`Panel.qml` imports — so a failure here is a failure in the plugin, not in a
copy.

```bash
node tests/model.test.mjs      # pure logic: parsing, ranking, formatting
node tests/connect-argv.test.mjs  # the argv handed to ssh
```

`connect-argv.test.mjs` is the one that matters most. The reconnect path
embeds the host name in a `bash -ic` command string, so that test hands the
generated command to a real `bash` and checks that a host called `; rm -rf ~`
or `$(id)` arrives as one literal argument.

## Reading shell logs

A QML error names the file and line:

```bash
journalctl --user -t omarchy-shell --since "2 minutes ago" --no-pager \
  | grep -i sshdrops
```

The shell runs with `QS_DISABLE_FILE_WATCHER=1`, so **edits are not picked up
live** — a `rescanPlugins` reloads the plugin but can still serve cached
compiled QML. When in doubt, `omarchy restart shell`. A stale error naming a
line you already fixed is almost always this.

## Checklist for a new UI element

The `qs.Ui` components have properties that shadow their own names. Declaring
`property color foreground` and then writing `foreground: foreground` inside
the same item is a `Property value set multiple times` error at load, and it
takes the whole widget down rather than just that element.

Look at an existing first-party widget before adding to one — the current
sources are the reference for what actually works:

- `/usr/share/omarchy/shell/plugins/panels/tailscale/` — a full-featured panel
- `/usr/share/omarchy/shell/plugins/panels/clock/BarWidget.qml` — a bar widget
  that is mostly a label
- `/usr/share/omarchy/shell/Ui/` — the component kit itself

Two gotchas that cost real time here:

- **`WidgetButton` hides itself unless it has content.** `hasVisualContent`
  defaults to `text !== ""`, so a widget that draws its own icon inside a
  `Row` must set `hasVisualContent: true` or the whole button renders at
  `opacity: 0`. It fails silently — no error in the log.
- **Don't nest a `RowLayout` inside a `ColumnLayout`** when a child needs
  `fillWidth` plus `elide`. The two fight over width and the label collapses
  to nothing with no error at all. A single flat `Item` with anchored
  children and an explicit trailing `Row` behaves.

## Verifying by hand

```bash
omarchy plugin validate .                                  # manifest schema
omarchy-shell shell rescanPlugins                          # rediscover
omarchy-shell io.github.flyingbasshot.sshdrops hosts       # library as JSON
omarchy-shell io.github.flyingbasshot.sshdrops sessions    # live sessions
omarchy-shell io.github.flyingbasshot.sshdrops toggle '{}'
```

For a screenshot:

```bash
grim full.png && magick full.png -crop 620x440+1272+38 +repage preview.png
```

Adjust the crop rectangle to wherever the panel landed.

## Testing session detection

`refreshSessions` reads `ps -eo args`. To see it light up without a real
server, start something whose argv looks like ssh:

```bash
printf '#!/bin/bash\nexec -a "/usr/bin/ssh $*" sleep 900\n' > /tmp/fake-ssh.sh
chmod +x /tmp/fake-ssh.sh
setsid /tmp/fake-ssh.sh "bastion" &

omarchy-shell io.github.flyingbasshot.sshdrops refresh
omarchy-shell io.github.flyingbasshot.sshdrops sessions
```

The `exec -a` matters: `ps` prints argv as the kernel sees it, so a process
only counts as ssh when its program basename is exactly `ssh`.

Clean up with:

```bash
ps -eo pid,args | awk '$2=="/usr/bin/ssh"{print $1}' | xargs -r kill
```

Do not `pkill -f ssh` — the pattern matches the cleanup command's own command
line and the shell hangs.
