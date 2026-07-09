# DevOps Toolbox

[![CI](https://github.com/Amahdip/devops-toolbox/actions/workflows/ci.yml/badge.svg)](https://github.com/Amahdip/devops-toolbox/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Practical scripts for people who run Linux servers. The philosophy: don't
reinvent monitoring tools — **compose the best existing ones** (btop,
lazydocker, nload, ncdu) into workflows you can launch in one command.

## monitor.sh — interactive tmux monitoring dashboard

One command gives you a full server dashboard: pick the modules you want from
a checklist and get a tiled tmux session with live logs, resource usage,
Docker management, and network stats.

<!-- TODO: record a demo with `vhs` or asciinema and embed it here -->
<!-- ![demo](docs/demo.gif) -->

### Modules

| Module      | Tool                  | Where          |
| ----------- | --------------------- | -------------- |
| Security    | `journalctl` (ssh/auth) + `ccze` | Dashboard pane |
| App logs    | nginx/syslog + `ccze` | Dashboard pane |
| Docker      | `lazydocker`          | Dashboard pane |
| Resources   | `btop`                | Dashboard pane |
| Bandwidth   | `nload`               | Own tab        |
| Open ports  | `ss` + `watch`        | Own tab        |
| Disk usage  | `ncdu`                | Own tab        |
| Latency     | `ping` + `watch`      | Own tab        |

Docker and nginx modules are auto-detected and only offered when present.

### Requirements

- Linux (tested on Debian/Ubuntu; apt, dnf, yum, pacman, zypper and apk are
  supported for dependency installation)
- `tmux ccze btop whiptail nload ncdu`
- Optional: `docker` + [`lazydocker`](https://github.com/jesseduffield/lazydocker#installation), nginx

### Quick start

```sh
git clone https://github.com/Amahdip/devops-toolbox.git
cd devops-toolbox
./scripts/monitor.sh            # checks deps and tells you what's missing
./scripts/monitor.sh --install  # or: offer to install missing deps (sudo, asks first)
```

The script never installs anything unless you pass `--install` **and**
confirm the prompt.

### Usage

```
monitor.sh [OPTIONS]

  --install      Offer to install missing dependencies
  -h, --help     Show help
  -V, --version  Print version
```

Handy tmux keys once you're in the session:

| Keys                | Action                    |
| ------------------- | ------------------------- |
| `Ctrl-b` `n` / `p`  | Next / previous tab       |
| `Ctrl-b` `←↑↓→`     | Move between panes        |
| `Ctrl-b` `z`        | Zoom current pane         |
| `Ctrl-b` `d`        | Detach (dashboard keeps running) |

Re-running the script while a session exists offers to re-attach instead of
destroying it.

## Development

```sh
shellcheck scripts/*.sh   # linting — CI enforces this on every push
```

Contributions welcome — open an issue or PR.

## License

[MIT](LICENSE)
