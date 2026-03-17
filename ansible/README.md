# Ansible runbook for homelab K3s cluster provisioning
#
# This directory contains Ansible playbooks that automate the bootstrap
# process documented in docs/bootstrap.md. Each playbook corresponds to
# a stage of the provisioning workflow and can be run individually or
# together via site.yml.
#
# Quick start:
#
#   # Install Ansible on macOS
#   brew install ansible
#
#   # Review and edit the inventory
#   vim ansible/inventory/hosts.yml
#
#   # Review variables
#   vim ansible/group_vars/all.yml
#
#   # Run the full bootstrap
#   cd ansible
#   ansible-playbook site.yml
#
#   # Or run individual stages
#   ansible-playbook playbooks/01-bootstrap-k3s.yml
#   ansible-playbook playbooks/02-install-rancher.yml
#   ...
#
# See docs/ansible.md for the full guide.
