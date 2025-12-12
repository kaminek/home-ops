# Home Ops

This repository contains the infrastructure and configuration for my personal home lab, managed with a GitOps approach.

## Overview

The goal of this project is to automate the provisioning and management of a Kubernetes cluster and its applications. This repository is the single source of truth for the entire infrastructure.

## Technologies

This project uses a combination of open-source tools to achieve a fully automated home lab:

- **Ansible:** For provisioning the operating system and configuring the nodes.
- **Terraform:** For managing infrastructure resources.
- **Flux:** For continuous delivery and GitOps in the Kubernetes cluster.
- **Kubernetes:** The container orchestration platform.
- **Sops:** For managing secrets.
- **Renovate:** For keeping dependencies up to date.

## Repository Structure

The repository is organized as follows:

- `bootstrap/`: Contains the initial setup scripts for the cluster.
- `cluster/`: Holds the Kubernetes manifests and configurations managed by Flux.
- `provision/`: Ansible playbooks for provisioning the nodes.
- `terraform/`: Terraform configurations for the infrastructure.

## Getting Started

To get started with this project, you will need to have the following tools installed:

- `ansible`
- `terraform`
- `kubectl`
- `flux`
- `sops`

After cloning the repository, you can inspect the `Taskfile.yml` for available commands to manage the environment.

## Contributing

While this is a personal project, suggestions and contributions are welcome. Please open an issue to discuss any changes.
