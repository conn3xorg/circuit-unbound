# circuit-unbound

A Conn3x circuit that installs Unbound, a validating, caching DNS resolver, from your distribution's own packages. It asks the root servers itself, or forwards to upstreams you pick, over DNS over TLS if you like, and checks DNSSEC signatures on every answer, so a forged record comes back as `SERVFAIL` rather than as an address. Names on your own network, such as `nas.home.arpa`, can be answered locally.

The same settings land on Debian, Ubuntu, Fedora and Rocky Linux. The circuit picks the parts that differ: where each distribution reads extra config from, where its CA bundle lives, and how it keeps the DNSSEC root key current. Each config change goes through `unbound-checkconf` before Unbound sees it. Optionally, the host itself can use Unbound for its own lookups, with systemd-resolved and NetworkManager set up to match.

## Usage

```hcl
module "unbound" {
  source = "github.com/conn3xorg/circuit-unbound?ref=v0.1.0"

  hosts                = { dns = "192.168.1.2" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  interfaces = ["127.0.0.1", "::1", "192.168.1.2"]
  access_control = [
    { cidr = "127.0.0.0/8", action = "allow" },
    { cidr = "::1/128", action = "allow" },
    { cidr = "192.168.1.0/24", action = "allow" },
  ]

  local_zones = { "home.arpa." = "static" }
  local_data = [
    "nas.home.arpa. A 192.168.1.10",
    "printer.home.arpa. A 192.168.1.20",
  ]

  use_as_system_resolver = true
}
```

Then run `conn3x init` and `conn3x apply`. A second `conn3x plan` says `No changes.` Point your router's DHCP at `192.168.1.2` and the rest of the network resolves through it.

To forward everything to public resolvers over TLS instead of resolving from the root servers:

```hcl
  forwarders  = ["9.9.9.9#dns.quad9.net", "1.1.1.1#cloudflare-dns.com"]
  forward_tls = true
```

The name after `#` is what Unbound checks the upstream's certificate against. Without it, the connection is encrypted but anyone in the path could answer in the upstream's place.

For hosts created in the same plan, pass host objects with the host key you generated, so Conn3x checks it without a known_hosts entry. Give each one's distribution in `os` too: the circuit picks its paths by distribution, and Conn3x can't ask a host that doesn't exist yet. If `os` turns out not to match the host, Conn3x stops before configuring it. Set `os` as well when you put `depends_on` on this module: `depends_on` holds back reading the hosts until the apply, so without `os` the plan fails with `Invalid for_each argument`.

```hcl
hosts = {
  for name, d in digitalocean_droplet.dns : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
    os       = "ubuntu"
  }
}
```

To try it on a throwaway container first, see [examples/local](examples/local).

### Who may ask

`interfaces` decides where Unbound listens, on port 53, and `access_control` decides who gets an answer. Anything not listed is refused, and the most specific match wins, so `{ cidr = "192.168.1.66/32", action = "refuse" }` carves one address out of an allowed network. Unbound also takes `deny`, which drops the query without a reply, and a few finer actions, all listed under Inputs.

Leave `access_control` at loopback unless you mean otherwise. A resolver that answers anyone on the internet gets found, and used to flood other people with amplified replies.

A wildcard, `"0.0.0.0"` or `"::"`, turns on `interface-automatic`, so Unbound replies from the address each query came in on. It then listens on every IPv4 and IPv6 address, whichever of the two you name.

### systemd-resolved

Ubuntu, Fedora and many Debian hosts run systemd-resolved, whose stub listener holds port 53 on `127.0.0.53` and `127.0.0.54`. Unbound on `127.0.0.1` sits fine beside it: on Ubuntu 24.04 and Debian 13 droplets, both answered with the default `interfaces`. A wildcard can't bind next to it, though, so with a wildcard in `interfaces` the circuit turns the stub off with a drop-in, `/etc/systemd/resolved.conf.d/conn3x-unbound-stub.conf`, and points `/etc/resolv.conf` at resolved's list of real upstream servers. The rest of resolved keeps running.

### Using it for the host's own lookups

`use_as_system_resolver = true` sends the host's own lookups through Unbound as well:

- It turns resolved's stub off, as above, and adds `/etc/systemd/resolved.conf.d/conn3x-unbound.conf` with `DNS=127.0.0.1` and `Domains=~.`. That matters on Debian and Fedora, whose `nsswitch.conf` asks resolved directly and never reads `/etc/resolv.conf`. The file first clears the server list, so a cloud provider's own drop-in, such as DigitalOcean's, doesn't stay ahead of Unbound.
- It writes `/etc/NetworkManager/conf.d/conn3x-unbound.conf` with `dns=none`, so NetworkManager stops putting DHCP's servers into `/etc/resolv.conf`, as it does on Rocky Linux, or into resolved, as on Fedora.
- It replaces `/etc/resolv.conf` with a file holding `nameserver 127.0.0.1` and `options edns0 trust-ad`. `trust-ad` lets programs that ask see Unbound's DNSSEC verdict, which is safe because the answer never leaves the host.

These run after Unbound has restarted on its new config, so the host is never pointed at a resolver that isn't there. `interfaces` must include `127.0.0.1` or `0.0.0.0`. The circuit leaves resolved and NetworkManager running, and on a host without either the drop-ins sit unused.

## What it does

On each host, in order:

1. With a wildcard in `interfaces` or `use_as_system_resolver` on, turns off systemd-resolved's stub listener and relinks `/etc/resolv.conf` if it pointed at the stub. See [systemd-resolved](#systemd-resolved).
2. Installs the DNSSEC root trust anchor's package, `dns-root-data` on Debian and Ubuntu, which Unbound only recommends there, or `unbound-anchor` on the Red Hat family. Then installs `unbound`, and `ca-certificates` with `forward_tls` on.
3. Writes the rendered config to `/etc/unbound/conn3x.candidate`, then copies it to `/etc/unbound/unbound.conf.d/conn3x.conf` on Debian and Ubuntu, or `/etc/unbound/conf.d/conn3x.conf` on the Red Hat family, and runs `unbound-checkconf` over the whole config, the distribution's own files included. If the check fails, the previous file goes back and the apply stops with Unbound's error, such as `Bad local-data RR bad.home.arpa. A 999.1.1.1`. A hand edit to the live file is put back on the next apply.
4. Starts Unbound now and at boot, and restarts it when the config changes. A reload would empty the cache just the same, and can't open new listening addresses once Unbound has dropped root.
5. With `use_as_system_resolver` on, points the host at Unbound. See [Using it for the host's own lookups](#using-it-for-the-hosts-own-lookups).

DNSSEC validation comes from each distribution's own setup, which the circuit leaves on: both keep the root key in `/var/lib/unbound/root.key` and update it under RFC 5011. Debian and Ubuntu copy it from `dns-root-data` each time Unbound starts; Fedora and Rocky Linux run `unbound-anchor` each time before Unbound starts. Fedora and Rocky Linux also turn on prefetching, serving expired answers while it refreshes them, and a few hardening options in `/usr/share/unbound/fedora-defaults.conf`. Debian and Ubuntu use Unbound's built-in defaults.

`unbound-control` works as root on every distribution, over a local Unix socket. `unbound-control stats_noreset` shows query and cache-hit counts; `unbound-control flush example.com` drops a name from the cache.

### Unbound versions

The circuit uses each distribution's package, so the version follows the distribution, and there's no version to pin. On the hosts tested:

| Distribution | Unbound |
| --- | --- |
| Ubuntu 24.04 | 1.19.2 |
| Debian 13 | 1.26.2 |
| Rocky Linux 10 | 1.24.2 |
| Fedora 45 | 1.26.1 |

### What it doesn't do

- It doesn't open the firewall for port 53. See [circuit-firewall](https://github.com/conn3xorg/circuit-firewall) for that.
- It doesn't write `PTR` records for `local_data`. Add them as records of their own, such as `"10.1.168.192.in-addr.arpa. PTR nas.home.arpa."`.
- It doesn't block ads or serve DNS over TLS or HTTPS to clients. For blocking, see [circuit-pihole](https://github.com/conn3xorg/circuit-pihole), which can use Unbound as its upstream.
- Turning `use_as_system_resolver` off, or deleting the module, leaves the drop-ins and `/etc/resolv.conf` as they are. Delete `/etc/systemd/resolved.conf.d/conn3x-unbound*.conf` and `/etc/NetworkManager/conf.d/conn3x-unbound.conf`, then restart resolved and NetworkManager, to hand lookups back. Deleting the module leaves Unbound installed and running with the last config.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file`, `jump_hosts` and `os`, the distribution's ID, such as `ubuntu` or `rocky`, which a host created in the same plan needs. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `interfaces` | list(string) | `["127.0.0.1", "::1"]` | Addresses Unbound listens on, port 53. `"0.0.0.0"` or `"::"` listens on every address. |
| `access_control` | list(object) | loopback allowed | Who may query, as `{ cidr, action }`. `action` is `allow`, `allow_setrd`, `allow_snoop`, `allow_cookie`, `deny`, `refuse`, `deny_non_local` or `refuse_non_local`. Networks not listed are refused. The default allows `127.0.0.0/8` and `::1/128`. |
| `forwarders` | list(string) | `[]` | Upstream resolvers that get every query, in Unbound's `forward-addr` form, such as `"9.9.9.9#dns.quad9.net"` or `"192.168.1.1@5353"`. When empty, Unbound resolves from the root servers itself. |
| `forward_tls` | bool | `false` | Use DNS over TLS to the forwarders, on port 853 unless a forwarder gives its own. Give each a `#name` to check its certificate against. |
| `local_zones` | map(string) | `{}` | Zones Unbound answers itself, with their type, such as `{ "home.arpa." = "static" }`. A `static` zone answers from `local_data` and says any other name in it doesn't exist; `transparent` passes other names on. |
| `local_data` | list(string) | `[]` | Records Unbound answers with, in zone file form, such as `["nas.home.arpa. A 192.168.1.10"]`. A record outside every `local_zones` zone gets a `transparent` zone of its own. |
| `msg_cache_size` | string | `"16m"` | Memory for cached answers, such as `"64m"`. |
| `rrset_cache_size` | string | `"32m"` | Memory for cached records. Unbound suggests twice `msg_cache_size`. |
| `use_as_system_resolver` | bool | `false` | Point the host's own lookups at Unbound on `127.0.0.1`. See [Using it for the host's own lookups](#using-it-for-the-hosts-own-lookups). |

## Outputs

| Name | Description |
| --- | --- |
| `config_files` | Path of the file the circuit writes on each host, by host name, such as `{ dns = "/etc/unbound/unbound.conf.d/conn3x.conf" }`. |

## Requirements

Requires Conn3x v0.6.5 or later and systemd on each host, with a package mirror the host can reach. Full recursion needs outbound UDP and TCP on port 53; DNS over TLS needs outbound TCP on 853.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to each on amd64, once resolving from the root servers and once forwarding over TLS to Cloudflare and Quad9, and checks that the second plan has no changes. It then checks that `example.com` comes back with the `ad` flag, that `dnssec-failed.org` gets `SERVFAIL`, that `nas.home.arpa` answers from `local_data` and other `home.arpa` names get `NXDOMAIN`, that a repeat query counts as a cache hit in `unbound-control stats_noreset`, and that a query from the container's own address, outside `access_control`, is refused. The same checks passed in Podman on arm64.

On Ubuntu 24.04, Debian 13 and Rocky Linux 10 droplets, the same checks passed with the default `interfaces`, beside systemd-resolved's stub on Ubuntu and Debian, then with `0.0.0.0`, where a query to the droplet's public address was refused. With `use_as_system_resolver`, `getent hosts` found `nas.home.arpa` and Unbound's query count rose with each lookup on all three, through nss-resolve on Debian, and still did after a reboot, with the plan still at no changes. Forwarding over TLS held open connections to port 853 on all three. Rocky Linux ran with SELinux enforcing: Unbound ran confined as `named_t`, and the audit log had no denials.

A config that fails `unbound-checkconf` was tried on Rocky Linux 10: the apply stopped with Unbound's error and the previous file stayed in place.

## License

MPL-2.0. See [LICENSE](LICENSE). Unbound itself is BSD-3-Clause.
