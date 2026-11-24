locals {
  fleet_count        = 3
  flavour            = "DEV-2xCPU-8GB"
  region             = "uk-lon1"
  cloudflare_zone_id = data.sops_file.secrets.data.cloudflare_zone_id
  # https://www.cloudflare.com/ips-v4
  cloudflare_ipv4 = [
    "173.245.48.0/20",
    "103.21.244.0/22",
    "103.22.200.0/22",
    "103.31.4.0/22",
    "141.101.64.0/18",
    "108.162.192.0/18",
    "190.93.240.0/20",
    "188.114.96.0/20",
    "197.234.240.0/22",
    "198.41.128.0/17",
    "162.158.0.0/15",
    "104.16.0.0/13",
    "104.24.0.0/14",
    "172.64.0.0/13",
    "131.0.72.0/22",
  ]
}

resource "upcloud_network" "private_network" {
  name = "private-network"
  zone = local.region
  ip_network {
    address            = "10.10.0.0/24"
    dhcp               = true
    dhcp_default_route = false
    family             = "IPv4"
  }
}

resource "upcloud_server" "node" {
  count = local.fleet_count

  plan     = local.flavour
  hostname = "node${count.index}"
  zone     = local.region
  metadata = true
  firewall = true

  template {
    storage = "01000000-0000-4000-8000-000030240200" # Ubuntu 24.02
    title   = "node${count.index}-rootfs"
    size    = 80
    encrypt = true
    tier    = "standard"
  }

  network_interface {
    ip_address_family = "IPv4"
    type              = "public"
  }

  network_interface {
    ip_address_family = "IPv6"
    type              = "public"
  }

  network_interface {
    type                = "private"
    network             = upcloud_network.private_network.id
    ip_address          = "10.10.0.1${count.index}"
    ip_address_family   = "IPv4"
    source_ip_filtering = false
  }

  login {
    keys = data.github_user.kaminek.ssh_keys
  }

  labels = {
    cluster = "homelab"
    env     = "prod"
    node    = "node${count.index}"
  }
}

resource "upcloud_server_group" "main" {
  title                = "cluster"
  anti_affinity_policy = "strict"
  labels = {
    cluster = "homelab"
    env     = "prod"
  }
  members = upcloud_server.node[*].id
}

resource "upcloud_firewall_rules" "nodes" {
  count     = local.fleet_count
  server_id = upcloud_server.node[count.index].id

  firewall_rule {
    action                 = "accept"
    comment                = "Allow SSH"
    destination_port_start = "22"
    destination_port_end   = "22"
    direction              = "in"
    family                 = "IPv4"
    protocol               = "tcp"
    source_address_start   = data.sops_file.secrets.data.allowed_ip
    source_address_end     = data.sops_file.secrets.data.allowed_ip
  }

  firewall_rule {
    action                 = "accept"
    comment                = "Allow K8s api server"
    destination_port_start = "6443"
    destination_port_end   = "6443"
    direction              = "in"
    family                 = "IPv4"
    protocol               = "tcp"
    source_address_start   = data.sops_file.secrets.data.allowed_ip
    source_address_end     = data.sops_file.secrets.data.allowed_ip
  }

  firewall_rule {
    action                 = "accept"
    comment                = "Allow DNSoUDP replies from 1.1.1.1"
    source_port_start      = "53"
    source_port_end        = "53"
    destination_port_start = "32768"
    destination_port_end   = "65535"
    direction              = "in"
    family                 = "IPv4"
    protocol               = "udp"
    source_address_start   = "1.1.1.1"
    source_address_end     = "1.1.1.1"
  }

  firewall_rule {
    action                 = "accept"
    comment                = "Allow DNSoUDP replies from 1.0.0.1"
    source_port_start      = "53"
    source_port_end        = "53"
    destination_port_start = "32768"
    destination_port_end   = "65535"
    direction              = "in"
    family                 = "IPv4"
    protocol               = "udp"
    source_address_start   = "1.0.0.1"
    source_address_end     = "1.0.0.1"
  }

  # origin lock: apps are proxied by cloudflare (external-dns --cloudflare-proxied)
  dynamic "firewall_rule" {
    for_each = local.cloudflare_ipv4
    content {
      action                 = "accept"
      comment                = "Allow HTTPS from Cloudflare"
      destination_port_start = "443"
      destination_port_end   = "443"
      direction              = "in"
      family                 = "IPv4"
      protocol               = "tcp"
      source_address_start   = cidrhost(firewall_rule.value, 0)
      source_address_end     = cidrhost(firewall_rule.value, -1)
    }
  }

  # tailscaled listens on 41641; wireguard and STUN replies both land there.
  # matching on source port instead let any sender reach any udp port.
  firewall_rule {
    action                 = "accept"
    comment                = "Allow Tailscale wireguard"
    destination_port_start = "41641"
    destination_port_end   = "41641"
    direction              = "in"
    family                 = "IPv4"
    protocol               = "udp"
  }

  firewall_rule {
    action                 = "accept"
    comment                = "Allow NTP response"
    source_port_start      = "123"
    source_port_end        = "123"
    destination_port_start = "32768" # chrony queries from random ephemeral ports
    destination_port_end   = "60999"
    direction              = "in"
    family                 = "IPv4"
    protocol               = "udp"
  }

  firewall_rule {
    action    = "drop"
    direction = "in"
  }

  firewall_rule {
    action    = "accept"
    direction = "out"
  }
}

# DNS
resource "cloudflare_dns_record" "nodes" {
  count = local.fleet_count

  zone_id = local.cloudflare_zone_id
  comment = "homelab node${count.index}"
  name    = "node${count.index}.cluster"
  content = upcloud_server.node[count.index].network_interface[0].ip_address
  type    = "A"
  proxied = false
  ttl     = 60
}

resource "cloudflare_dns_record" "cluster" {
  count = local.fleet_count

  zone_id = local.cloudflare_zone_id
  comment = "homelab cluster"
  name    = "cluster"
  content = upcloud_server.node[count.index].network_interface[0].ip_address
  type    = "A"
  proxied = false
  ttl     = 60
}
