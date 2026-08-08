# Raspberry Pi setup

Ansible playbook for configuring the Raspberry Pi.

## Layout

```
ansible.cfg
inventory/hosts.yml     # target host -- edit ansible_host before first run
site.yml                # entry point
roles/dns/              # NetworkManager DNS servers + priority
roles/podman_rootless/  # linger + rootless podman.socket for the core user
roles/hawser/           # hawser quadlet, storage dir and env file
```

## Usage

Set the pi's address in `inventory/hosts.yml`, then:

```sh
ansible-playbook site.yml --check --diff   # dry run
ansible-playbook site.yml
```

Add `-K` if the `pi` user needs a sudo password.

## What the `dns` role does

Edits `[ipv4]` in
`/etc/NetworkManager/system-connections/Wired connection 1.nmconnection`:

```ini
dns=10.0.10.2;10.0.10.21;10.0.10.1;
dns-priority=10
```

`dns-priority` is lower than NetworkManager's default of 100, so these servers
are consulted ahead of the ones the router hands out over DHCP, while those stay
in place as a fallback. Set it negative to make the configured list exclusive.

There is no per-server priority in NetworkManager -- `dns-priority` orders
whole connection profiles, not servers within one. The order of `dns_servers`
is preserved in `resolv.conf` though, and glibc queries them in that order,
falling back to the next only on timeout. Note that glibc reads at most three
`nameserver` lines (`MAXNS`), so a fourth entry is silently ignored.

Everything else in the keyfile -- `uuid`, `timestamp`, `method=auto` -- is left
alone, since NetworkManager owns those.

The role reloads the profile with `nmcli connection reload` and applies it with
`nmcli device reapply eth0`. It deliberately avoids `nmcli connection up`, which
would deactivate the link and kill the SSH session the play is running over.

## Variables

Overridable in `inventory/hosts.yml` or on the command line; defaults in
`roles/dns/defaults/main.yml`.

| Variable | Default | Purpose |
| --- | --- | --- |
| `dns_connection_name` | `Wired connection 1` | Profile name, also the filename |
| `dns_interface` | `eth0` | Device passed to `nmcli device reapply` |
| `dns_servers` | OpenDNS pair | Written to `[ipv4] dns=` |
| `dns_priority` | `10` | Written to `[ipv4] dns-priority=` |

If the play aborts saying the keyfile is missing, list the real profile names
on the pi with `nmcli -g NAME connection show` and override
`dns_connection_name`.

## What the `podman_rootless` role does

Prepares the rootless podman instance for the `core` user:

- enables lingering, so the user manager starts at boot and its containers keep
  running after logout
- enables and starts the user-scope `podman.socket`
- enables and starts the user-scope `podman-auto-update.timer`
- creates `/etc/containers/systemd/users/<uid>/` for rootless quadlets

### Auto-update

`AutoUpdate=registry` in a quadlet does nothing on its own -- something has to
run `podman auto-update`. That is `podman-auto-update.timer`, and for a rootless
instance it has to be enabled in the *user* scope, which this role does.

Only the timer is enabled. It carries no explicit `Unit=`, so systemd already
activates the same-named `podman-auto-update.service` on schedule (`OnCalendar=daily`,
`Persistent=true`, so a missed run is caught up after boot). That service also
ships `WantedBy=default.target`, so enabling it as well would additionally pull
images and restart every container on *every boot* -- the same reasoning is
written into `fcos-base-tmplt.yaml` on the `main` branch. Set
`podman_rootless_auto_update_service=true` if you want that anyway.

UID and home directory are read from `getent passwd` rather than hardcoded. The
role asserts up front that `ansible_user` equals `podman_rootless_user`: it
drives the user's login session over the SSH connection itself, and escalating
to the user with `sudo` would not give it a usable session bus.

Note that `systemctl --user` needs both `XDG_RUNTIME_DIR` and
`DBUS_SESSION_BUS_ADDRESS`; with only the former it fails with *"Failed to
connect to user scope bus"*. Both are set from `podman_rootless_env`.

Also note that the inventory sets `ansible_become: true` as a group variable,
which overrides the `become:` task keyword. User-scope tasks therefore switch it
off with `vars: {ansible_become: false}`, not `become: false`.

## What the `hawser` role does

Installs `/etc/containers/systemd/users/<uid>/hawser.container`, creates
`~/quadlet-storage/hawser` and seeds `~/quadlet-storage/hawser.env`.

This is a port of the Fedora CoreOS ignition quadlet
(`fcos-base-tmplt.yaml` on the `edge` branch), adapted to Debian:

| FCOS | here | why |
| --- | --- | --- |
| `/var/home/core/...` | `/home/core/...` | `/var/home` is an ostree layout, absent on Debian |
| `:Z` / `:z`, `SecurityLabelType=` | dropped | Debian has no SELinux, so the labels do nothing |
| `DNS=100.100.100.100` | unset | that is Tailscale MagicDNS; no Tailscale on the pi |
| `After/Requires=default.target` | `podman.socket` | the container bind-mounts the rootless socket, so it must not start before that socket exists |
| `ExecStartPre=mkdir`/`chown` | dropped | Ansible creates the directory, already owned by `core` |

Quadlet units are *generated*, so they cannot be `systemctl --user enable`d --
the `[Install]` section is processed by the generator during `daemon-reload`.
The role flushes its handlers before checking the service, otherwise on a first
run the unit would not exist yet.

### The token

`hawser_token` is empty by default. In that state the env file is seeded once
with a placeholder and then never touched again, so a token edited on the host
survives re-runs:

```sh
sudo -u core sh -c 'echo TOKEN=real-token > /home/core/quadlet-storage/hawser.env'
sudo -u core XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart hawser
```

Set `hawser_token` (ideally from vault) and Ansible takes ownership of the file
and keeps it in sync instead.

### Variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `podman_rootless_user` | `core` | Owner of the rootless instance |
| `podman_rootless_auto_update` | `true` | Enable `podman-auto-update.timer` |
| `podman_rootless_auto_update_service` | `false` | Also enable the service; see above |
| `hawser_image` | `ghcr.io/finsys/hawser:latest` | Has amd64, arm64 and arm/v7 manifests |
| `hawser_agent_name` | `pi` | `AGENT_NAME` in the container |
| `hawser_server_url` | `wss://dockhand.arexoor.dev/api/hawser/connect` | `DOCKHAND_SERVER_URL` |
| `hawser_token` | `""` | See above |
| `hawser_dns` | `""` | Empty means inherit the host resolver |
