data "github_user" "kaminek" {
  username = "kaminek"
}

data "sops_file" "secrets" {
  source_file = "secrets.sops.yaml"
  input_type  = "yaml"
}

# origin lock source ranges, see upcloud_firewall_rules.nodes
data "cloudflare_ip_ranges" "this" {}
