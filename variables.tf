variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file, jump_hosts or os."

  validation {
    condition     = alltrue([for h in var.hosts : contains(["debian", "ubuntu", "rocky", "almalinux", "rhel", "centos", "fedora"], try(h.os, "debian"))])
    error_message = "A host object's os must be one of debian, ubuntu, rocky, almalinux, rhel, centos or fedora."
  }
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}
variable "interfaces" {
  type        = list(string)
  default     = ["127.0.0.1", "::1"]
  description = "Addresses unbound listens on, port 53. \"0.0.0.0\" and \"::\" mean every address."

  validation {
    condition     = length(var.interfaces) > 0 && alltrue([for i in var.interfaces : can(cidrhost("${i}/${strcontains(i, ":") ? 128 : 32}", 0))])
    error_message = "interfaces must hold one or more IP addresses, such as \"127.0.0.1\" or \"192.168.1.2\"."
  }
}

variable "access_control" {
  type = list(object({
    cidr   = string
    action = string
  }))
  default = [
    { cidr = "127.0.0.0/8", action = "allow" },
    { cidr = "::1/128", action = "allow" },
  ]
  description = "Who may query, as a list of { cidr, action }, such as { cidr = \"192.168.1.0/24\", action = \"allow\" }. Networks not listed are refused. The most specific match wins."

  validation {
    condition     = alltrue([for a in var.access_control : can(cidrhost(a.cidr, 0))])
    error_message = "Each access_control cidr must be a CIDR network, such as \"192.168.1.0/24\" or \"::1/128\"."
  }

  validation {
    condition     = alltrue([for a in var.access_control : contains(["allow", "allow_setrd", "allow_snoop", "allow_cookie", "deny", "refuse", "deny_non_local", "refuse_non_local"], a.action)])
    error_message = "Each access_control action must be one of allow, allow_setrd, allow_snoop, allow_cookie, deny, refuse, deny_non_local or refuse_non_local."
  }
}

variable "forwarders" {
  type        = list(string)
  default     = []
  description = "Upstream resolvers to send every query to, in unbound's forward-addr form, such as \"9.9.9.9#dns.quad9.net\". When empty, unbound resolves from the root servers itself."

  validation {
    condition     = alltrue([for f in var.forwarders : can(regex("^[0-9A-Fa-f.:]+(@[0-9]+)?(#[A-Za-z0-9.-]+)?$", f))])
    error_message = "Each forwarder is an IP address with an optional @port and #name, such as \"1.1.1.1\" or \"1.1.1.1@853#cloudflare-dns.com\"."
  }
}

variable "forward_tls" {
  type        = bool
  default     = false
  description = "Send queries to forwarders over DNS over TLS, on port 853 unless a forwarder gives its own. Give each forwarder a #name to check its certificate against."

  validation {
    condition     = !var.forward_tls || length(var.forwarders) > 0
    error_message = "forward_tls needs at least one forwarder."
  }
}

variable "local_zones" {
  type        = map(string)
  default     = {}
  description = "Zones unbound answers itself, by name, with their type, such as { \"home.arpa.\" = \"static\" }. A static zone answers from local_data and says any other name in it doesn't exist."

  validation {
    condition     = alltrue([for z in keys(var.local_zones) : can(regex("^([A-Za-z0-9_-]+\\.)*[A-Za-z0-9_-]*\\.?$", z))])
    error_message = "local_zones keys must be domain names, such as \"home.arpa.\"."
  }

  validation {
    condition     = alltrue([for t in values(var.local_zones) : contains(["deny", "refuse", "static", "transparent", "typetransparent", "redirect", "inform", "inform_deny", "inform_redirect", "always_transparent", "block_a", "always_refuse", "always_nxdomain", "always_null", "noview", "nodefault"], t)])
    error_message = "Each local_zones type must be one of unbound's local-zone types, such as static, transparent, redirect, refuse or always_nxdomain."
  }
}

variable "local_data" {
  type        = list(string)
  default     = []
  description = "Records unbound answers with, in zone file form, such as [\"nas.home.arpa. A 192.168.1.10\"]."

  validation {
    condition     = alltrue([for rr in var.local_data : !strcontains(rr, "\"") && !strcontains(rr, "\n") && length(trimspace(rr)) > 0])
    error_message = "Each local_data record is one line without double quotes, such as \"nas.home.arpa. A 192.168.1.10\"."
  }
}

variable "msg_cache_size" {
  type        = string
  default     = "16m"
  description = "Memory for cached answers, such as \"16m\" or \"256m\"."

  validation {
    condition     = can(regex("^[0-9]+[kmgKMG]?$", var.msg_cache_size))
    error_message = "msg_cache_size is a number of bytes with an optional k, m or g, such as \"64m\"."
  }
}

variable "rrset_cache_size" {
  type        = string
  default     = "32m"
  description = "Memory for cached records. Unbound suggests twice msg_cache_size."

  validation {
    condition     = can(regex("^[0-9]+[kmgKMG]?$", var.rrset_cache_size))
    error_message = "rrset_cache_size is a number of bytes with an optional k, m or g, such as \"128m\"."
  }
}

variable "use_as_system_resolver" {
  type        = bool
  default     = false
  description = "Point the host's own lookups at unbound on 127.0.0.1, through systemd-resolved where it runs, and keep NetworkManager from changing that."

  validation {
    condition     = !var.use_as_system_resolver || length(setintersection(var.interfaces, ["127.0.0.1", "0.0.0.0"])) > 0
    error_message = "use_as_system_resolver needs unbound listening on 127.0.0.1: put \"127.0.0.1\" or \"0.0.0.0\" in interfaces."
  }
}
