# Facts give each host's distribution. Debian and Ubuntu read extra config
# from /etc/unbound/unbound.conf.d, the Red Hat family from
# /etc/unbound/conf.d, and the CA bundle lives in a different place too.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = try(each.value.os, self.os_id) == self.os_id
      error_message = "Host ${each.key} is ${self.os_id}, not the ${try(each.value.os, "")} its os says."
    }
  }
}

locals {
  # A host object's os stands in for the facts of a host created in the
  # same plan, which can't be read until it exists.
  os     = { for name, h in var.hosts : name => try(h.os, data.conn3x_host.facts[name].os_id) }
  debian = { for name, o in local.os : name => contains(["debian", "ubuntu"], o) }

  config_file = { for name, d in local.debian : name => d ? "/etc/unbound/unbound.conf.d/conn3x.conf" : "/etc/unbound/conf.d/conn3x.conf" }
  ca_bundle   = { for name, d in local.debian : name => d ? "/etc/ssl/certs/ca-certificates.crt" : "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem" }

  # Outside every include glob, so unbound never reads it by accident.
  candidate = "/etc/unbound/conn3x.candidate"

  # With a wildcard address, interface-automatic makes unbound reply from
  # the address a query came in on, rather than the one the kernel picks,
  # which matters on a host with more than one.
  wildcard = length(setintersection(var.interfaces, ["0.0.0.0", "::", "::0"])) > 0

  # DNS over TLS goes to port 853. A forwarder written without a port gets
  # it, ahead of any #name used to check the certificate.
  forwarders = [for f in var.forwarders : var.forward_tls && !strcontains(f, "@") ? replace(f, "/^([^#]+)(#.*)?$/", "$${1}@853$${2}") : f]

  config = { for host, d in local.debian : host => join("\n", concat(
    [
      "# Written by Conn3x. Changes here are overwritten on the next apply.",
      "server:",
    ],
    [for i in var.interfaces : "    interface: ${i}"],
    local.wildcard ? ["    interface-automatic: yes"] : [],
    [for a in var.access_control : "    access-control: ${a.cidr} ${a.action}"],
    [
      "    msg-cache-size: ${var.msg_cache_size}",
      "    rrset-cache-size: ${var.rrset_cache_size}",
    ],
    var.forward_tls ? ["    tls-cert-bundle: \"${local.ca_bundle[host]}\""] : [],
    [for zone, type in var.local_zones : "    local-zone: \"${zone}\" ${type}"],
    [for rr in var.local_data : "    local-data: \"${rr}\""],
    length(local.forwarders) == 0 ? [] : concat(
      [
        "",
        "forward-zone:",
        "    name: \".\"",
        "    forward-tls-upstream: ${var.forward_tls ? "yes" : "no"}",
      ],
      [for f in local.forwarders : "    forward-addr: ${f}"],
    ),
    [""],
  )) }
}

# systemd-resolved, which Ubuntu, Fedora and many Debian hosts run, holds
# port 53 on 127.0.0.53 and 127.0.0.54 for its stub listener. unbound on
# 127.0.0.1 sits fine beside it, but can't bind a wildcard address while it
# is there. So for a wildcard, or when unbound takes over the host's lookups
# anyway, the stub goes and the rest of resolved keeps running. On a host
# without resolved the drop-in sits unused.
circuit "stub" {
  hosts = local.wildcard || var.use_as_system_resolver ? var.hosts : {}

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "off" {
    file {
      path    = "/etc/systemd/resolved.conf.d/conn3x-unbound-stub.conf"
      content = "# Written by Conn3x so unbound can listen on port 53.\n[Resolve]\nDNSStubListener=no\n"
    }
  }

  step "restart" {
    command {
      command  = "! systemctl is-active -q systemd-resolved || systemctl restart systemd-resolved"
      triggers = conn3x_file.stub__off[each.key].revision
    }
  }

  # With the stub gone, a resolv.conf pointing at 127.0.0.53 leaves the host
  # without DNS, including for installing unbound. resolved keeps the real
  # upstream servers in a file of its own.
  step "resolv_conf" {
    command {
      command = "ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf"
      unless  = "! readlink /etc/resolv.conf | grep -q stub-resolv.conf"
    }
  }
}

circuit "unbound" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # The root trust anchor. Debian and Ubuntu copy it from dns-root-data,
  # which unbound only recommends. The Red Hat family gets it from
  # unbound-anchor, which unbound already requires.
  step "anchor" {
    depends_on = [conn3x_command.stub__resolv_conf]
    package {
      name = local.debian[each.key] ? "dns-root-data" : "unbound-anchor"
    }
  }

  step "package" {
    package {
      name = "unbound"
    }
  }

  # The CA bundle that checks forwarders' certificates. Minimal images can
  # be without it.
  step "ca" {
    for_each = var.forward_tls ? ["ca-certificates"] : []
    package {
      name = item.value
    }
  }

  step "candidate" {
    file {
      path    = local.candidate
      content = local.config[each.key]
    }
  }

  # Puts the candidate in place and runs unbound-checkconf over the whole
  # config, the distribution's files included. On Debian and Ubuntu the
  # anchor file only exists once unbound's helper has copied it, which the
  # unit does on each start, and the check needs it now. If the check fails, the
  # previous file goes back, so a bad address or record never reaches a
  # restart. Also puts the file back after a hand edit.
  step "config" {
    command {
      command  = <<-EOT
        live=${local.config_file[each.key]}
        if [ -e "$live" ]; then cp -p "$live" /etc/unbound/conn3x.previous; fi
        install -m 644 ${local.candidate} "$live"
        if command -v restorecon >/dev/null; then restorecon "$live"; fi
        if [ -x /usr/libexec/unbound-helper ]; then /usr/libexec/unbound-helper root_trust_anchor_update; fi
        if unbound-checkconf; then
          rm -f /etc/unbound/conn3x.previous
        elif [ -e /etc/unbound/conn3x.previous ]; then
          mv /etc/unbound/conn3x.previous "$live"; exit 1
        else
          rm -f "$live"; exit 1
        fi
      EOT
      unless   = "[ \"$(sha256sum < ${local.candidate})\" = \"$(sha256sum < ${local.config_file[each.key]} 2>/dev/null)\" ]"
      triggers = { candidate = conn3x_file.unbound__candidate[each.key].revision }
    }
    notify = [handler.restart]
  }

  step "running" {
    service {
      name    = "unbound"
      state   = "started"
      enabled = true
    }
  }

  # A reload would flush the cache just as a restart does, and can't bind
  # new interfaces once unbound has dropped root.
  handler "restart" {
    service {
      name = "unbound"
    }
  }
}

# Points the host's own lookups at unbound. Runs after unbound has restarted
# on its new config, so the host is never left pointing at nothing.
circuit "system_resolver" {
  hosts = var.use_as_system_resolver ? var.hosts : {}

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # systemd-resolved sends every lookup to unbound, including those that
  # come through nss-resolve and never read /etc/resolv.conf, as on Debian.
  # The empty DNS= drops servers set in earlier drop-ins, such as a cloud
  # provider's, and Domains=~. keeps the links' DHCP servers out of it.
  step "resolved" {
    depends_on = [conn3x_service_action.unbound__restart]
    file {
      path    = "/etc/systemd/resolved.conf.d/conn3x-unbound.conf"
      content = "# Written by Conn3x so the host resolves through unbound.\n[Resolve]\nDNS=\nDNS=127.0.0.1\nDomains=~.\n"
    }
  }

  step "resolved_restart" {
    command {
      command  = "! systemctl is-active -q systemd-resolved || systemctl restart systemd-resolved"
      triggers = conn3x_file.system_resolver__resolved[each.key].revision
    }
  }

  # Stops NetworkManager writing the DHCP servers into /etc/resolv.conf,
  # which it does on Rocky Linux, or into resolved, which it does on Fedora.
  step "networkmanager" {
    file {
      path    = "/etc/NetworkManager/conf.d/conn3x-unbound.conf"
      content = "# Written by Conn3x so the host resolves through unbound.\n[main]\ndns=none\n"
    }
  }

  step "networkmanager_reload" {
    command {
      command  = "! systemctl is-active -q NetworkManager || systemctl reload NetworkManager"
      triggers = conn3x_file.system_resolver__networkmanager[each.key].revision
    }
  }

  # Replaces any link to one of resolved's files. trust-ad
  # passes unbound's DNSSEC verdict on to programs that ask for it, which
  # is safe because the answer never leaves the host.
  step "resolv_conf" {
    file {
      path    = "/etc/resolv.conf"
      content = "# Written by Conn3x. unbound answers on 127.0.0.1.\nnameserver 127.0.0.1\noptions edns0 trust-ad\n"
    }
  }
}
