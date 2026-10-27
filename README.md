# noctalia-wvkbd

Noctalia v5 plugin that adds [wvkbd](https://github.com/jjsullivan5196/wvkbd) as an
on-screen keyboard with a bar toggle. The plugin lives in [`wvkbd/`](wvkbd/);
`catalog.toml` indexes it so this repository can be added as a Noctalia plugin source:

```shell
noctalia msg plugins source add nuarthy git https://github.com/nuarthy/noctalia-wvkbd
```

To work on it locally instead, symlink the plugin directory into the plugin folder:

```shell
ln -sfn ~/Projects/noctalia-wvkbd/wvkbd ~/.local/share/noctalia/plugins/wvkbd
noctalia msg plugins enable nuarthy/wvkbd
```

See [wvkbd/README.md](wvkbd/README.md) for requirements, bar placement, settings, and IPC
commands.

MIT licensed.
