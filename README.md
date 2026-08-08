# Raspberry Pi setup

Ansible playbook for configuring the Raspberry Pi.

## Layout

```
ansible.cfg
inventory/hosts.yml     # target host -- edit ansible_host before first run
site.yml                # entry point
roles/dns/              # NetworkManager DNS servers + priority
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
dns=208.67.222.222;208.67.220.220;
dns-priority=10
```

`dns-priority` is lower than NetworkManager's default of 100, so OpenDNS is
consulted ahead of the DNS servers the router hands out over DHCP, while those
stay in place as a fallback. Set it negative to make OpenDNS exclusive instead.

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
