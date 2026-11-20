# FM Client for Neovim

Minimal Neovim frontend for `fmclient` from [fm-node](https://github.com/fm-hive/fm-node).

### Install

#### Lazy:

```lua
{ 'https://github.com/fm-hive/fmclient-nvim' }
```

#### Neovim 0.12+ (`vim.pack.add`)

```lua
vim.pack.add { 'https://github.com/fm-hive/fmclient-nvim' }
```

Restart Neovim once after adding the specification so `vim.pack` can clone the
repository. `vim.pack.update()` updates it later. When you start Neovim in the
project directory containing the built `fmclient` and an authorized
`data/fmclient.db`, both panes open automatically.


### fmclient binary

The `fmclient` executable must be in `PATH` (or set `g:fmclient_cmd`), and
`g:fmclient_data` must point at the directory containing `fmclient.db`.


### Automatic detection

When Neovim starts in a directory that contains an executable `fmclient` (or
`fmclient.exe`) — or has `fmclient` in `PATH` — plus an authorized
`fmclient.db`, the plugin automatically opens a two-pane client and shows the
local database contents. The left pane is the echo/netmail menu; the right pane
is the work area for message lists and opened messages. Its header shows the
network name from the accepted policy (`net_name`) and the user address.
Authorization is checked with `fmclient policy show --json`.

Search order:

- binary: `vim.g.fmclient_cmd`, then `fmclient` in the launch directory, the
  current buffer directory, or the current directory, then `PATH`;
- data: `vim.g.fmclient_data`, then `data/` (or the directory itself) in the
  launch directory, the current buffer directory, or the current directory.

A relative `vim.g.fmclient_data` is resolved against the launch directory. This
keeps detection working when a plugin such as `project.nvim` changes Neovim's
working directory to a repository root after startup.

Disable automatic opening with:

```lua
vim.g.fmclient_auto = false
```

Then use `:FMClient` to open the two-pane client, `:FMClientCompose <echo>` or
`:FMClientNetmail <address>` to compose. Writes/`<leader>s`/`:FMClientSend`
queue the message and call `fmclient send_receive`.

Keys:

- menu: `<CR>` open, `r` refresh, `s` send/receive, `e` compose, `q` close both panes;
- work area: `<CR>` open a selected message, `q`/`u` go back to the previous list.

Protocol messages (votes, elections, excommunicate, merge, change_policy,
refill) are hidden from the feed by default. Press `P` to toggle them; the
sidebar shows the current state. The `Active protocols` menu item (or
`:FMClientProtocols [echo]`) lists active protocols with voting actions. Vote
actions are also available at the bottom of a protocol message: digits `1..9`,
`0` to retract, `A` to apply in an election, `R` to respond to a refill.

Dates are shown in the system's local timezone. Override the format with
`vim.g.fmclient_date_format` (default `%Y-%m-%d %H:%M`). Set
`vim.g.fmclient_show_protocols = true` to show protocol messages by default.

Set `vim.g.fmclient_cmd` and `vim.g.fmclient_data` only if the binary/data
directory are not found automatically. Detection can be checked with
`fmclient-nvim/tests/detect_paths.lua`.

