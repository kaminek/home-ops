terraform {
  backend "remote" {
    organization = "kaminek"
    workspaces {
      name = "home-ops"
    }
  }
}
