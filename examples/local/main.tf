variable "port" {
  type    = number
  default = 2222
}

# CI sets this to try DNS over TLS as well as full recursion.
variable "forwarders" {
  type    = list(string)
  default = []
}

module "unbound" {
  source = "../.."

  hosts                = { box = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  # Listens on every address, but only loopback and 192.168.0.0/16 may ask.
  # The container's own address on Podman's network is refused.
  interfaces = ["0.0.0.0", "::1"]
  access_control = [
    { cidr = "127.0.0.0/8", action = "allow" },
    { cidr = "::1/128", action = "allow" },
    { cidr = "192.168.0.0/16", action = "allow" },
  ]

  forwarders  = var.forwarders
  forward_tls = length(var.forwarders) > 0

  local_zones = { "home.arpa." = "static" }
  local_data  = ["nas.home.arpa. A 192.168.1.10"]

  msg_cache_size   = "32m"
  rrset_cache_size = "64m"
}

output "config_files" {
  value = module.unbound.config_files
}
