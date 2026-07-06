#!/usr/bin/env bash
# aidc module: Per-project VM isolation backends (Lima on macOS, Firecracker on Linux).
# Sourced by lib/aidc.sh — never directly. Functions moved verbatim from
# the former monolith; behavior changes ride their own commits.

# ─── VM isolation backend (Lima on macOS, Firecracker on Linux) ───
#
# When AIDC_ISOLATE_VM=1 each project gets its own lightweight VM instead of
# sharing the host Docker daemon.  The compose stack still runs unchanged —
# we just point DOCKER_HOST at the per-project VM's Docker socket.

aidc::vm_name() {
  local workspace="$1"
  local slug
  slug="$(aidc::repo_slug "$workspace")"
  printf 'aidc-%s\n' "$slug"
}

aidc::vm_socket_dir() {
  printf '%s/aidc-vm\n' "$AIDC_HOST_CONFIG_ROOT"
}

aidc::vm_socket_path() {
  local vm_name="$1"
  printf '%s/%s.sock\n' "$(aidc::vm_socket_dir)" "$vm_name"
}

# Detect which VM backend to use based on the host OS.
aidc::vm_backend() {
  local uname_s
  uname_s="$(uname -s)"
  case "$uname_s" in
    Darwin) printf 'lima' ;;
    Linux)  printf 'firecracker' ;;
    *)      aidc::die "VM isolation is not supported on $uname_s" ;;
  esac
}

# Ensure the per-project VM is running.  Creates it on first use.
aidc::vm_ensure() {
  local workspace="$1"
  local backend
  backend="$(aidc::vm_backend)"
  aidc::log "VM isolation enabled (backend: $backend)"

  case "$backend" in
    lima)        aidc::lima_ensure "$workspace" ;;
    firecracker) aidc::firecracker_ensure "$workspace" ;;
  esac
}

# Stop the per-project VM (called from 'aidc down').
aidc::vm_stop() {
  local workspace="$1"
  local backend
  backend="$(aidc::vm_backend)"

  case "$backend" in
    lima)        aidc::lima_stop "$workspace" ;;
    firecracker) aidc::firecracker_stop "$workspace" ;;
  esac
}

# Destroy the per-project VM (called from 'aidc destroy').
aidc::vm_destroy() {
  local workspace="$1"
  local backend
  backend="$(aidc::vm_backend)"

  case "$backend" in
    lima)        aidc::lima_destroy "$workspace" ;;
    firecracker) aidc::firecracker_destroy "$workspace" ;;
  esac
}

aidc::lima_config_path() {
  local vm_name="$1"
  printf '%s/%s.yaml\n' "$AIDC_LIMA_CONFIG_DIR" "$vm_name"
}

aidc::lima_generate_config() {
  local vm_name="$1"
  local workspace="$2"
  local config_path
  config_path="$(aidc::lima_config_path "$vm_name")"

  # Pick an SSH port that won't collide.  Hash the vm_name to get a port
  # in 4200–4299 range.
  local ssh_port
  ssh_port=$((4200 + ($(printf '%s' "$vm_name" | cksum | cut -d' ' -f1) % 100)))

  mkdir -p "$AIDC_LIMA_CONFIG_DIR"
  cat >"$config_path" <<LIMAEOF
# aidc-managed Lima config for $vm_name
# DO NOT EDIT — regenerated from 'aidc up --isolate-vm'

vmType: qemu
os: Linux
arch: $(uname -m | sed 's/arm64/aarch64/')
images:
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-\$(uname -m | sed 's/arm64/aarch64/').img"
    digest: "sha256:auto"

cpus: $AIDC_LIMA_CPUS
memory: $AIDC_LIMA_MEMORY
disk: $AIDC_LIMA_DISK

firmware:
  legacyBIOS: false

ssh:
  localPort: $ssh_port
  loadDotSSHPubKeys: false
  forwardAgent: false

containerd:
  system: false
  user: false

# Install Docker inside the VM so we can use the standard compose stack.
provision:
  - mode: system
    script: |
      #!/bin/bash
      set -euo pipefail
      if command -v docker >/dev/null 2>&1; then
        exit 0
      fi
      apt-get update -qq
      apt-get install -y -qq ca-certificates curl gnupg
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo "\$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
      apt-get update -qq
      apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      usermod -aG docker "${AIDC_CONTAINER_USER}"

mounts:
  - location: "$workspace"
    writable: true
  - location: "~/.config/aidc/empty/claude"
    mountPoint: "/host-seed/claude"
    writable: false
  - location: "~/.config/aidc/empty/codex"
    mountPoint: "/host-seed/codex"
    writable: false

networks:
  - lima: shared

message: |
  aidc Lima VM "{{.Name}}" — managed by aidc. Do not edit manually.
LIMAEOF

  printf '%s\n' "$config_path"
}

aidc::lima_ensure() {
  local workspace="$1"
  aidc::need_cmd limactl

  local vm_name
  vm_name="$(aidc::vm_name "$workspace")"

  # Already running?
  if limactl list --format '{{.Name}}' 2>/dev/null | grep -qxF "$vm_name"; then
    local vm_state
    vm_state="$(limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null | awk -v n="$vm_name" '$1==n {print $2}')"
    if [[ "$vm_state" == "Running" ]]; then
      aidc::log "Lima VM $vm_name is already running"
      aidc::lima_export_docker_host "$vm_name"
      return
    fi
    # Stopped — start it.
    aidc::log "starting Lima VM $vm_name ..."
    limactl start "$vm_name"
    aidc::lima_export_docker_host "$vm_name"
    return
  fi

  # First time — generate config and create the VM.
  aidc::log "creating Lima VM $vm_name (this may take a few minutes on first run) ..."
  aidc::log "  CPUs: $AIDC_LIMA_CPUS  Memory: $AIDC_LIMA_MEMORY  Disk: $AIDC_LIMA_DISK"
  aidc::log "  ⚠ Each isolated VM uses significant CPU/RAM/disk. See README 'Isolation modes'."

  local config_path
  config_path="$(aidc::lima_generate_config "$vm_name" "$workspace")"
  limactl start --tty=false "$config_path"
  aidc::lima_export_docker_host "$vm_name"
  aidc::log "Lima VM $vm_name is ready"
}

aidc::lima_export_docker_host() {
  local vm_name="$1"
  # Lima exposes the guest Docker socket via a Unix socket under ~/.lima/<name>/sock/
  local lima_socket="$HOME/.lima/${vm_name}/sock/docker.sock"
  if [[ -S "$lima_socket" ]]; then
    export DOCKER_HOST="unix://$lima_socket"
    aidc::log "DOCKER_HOST set to Lima VM: $DOCKER_HOST"
  else
    # Fallback: use limactl to copy the socket context
    local socket_dir
    socket_dir="$(aidc::vm_socket_dir)"
    mkdir -p "$socket_dir"
    limactl copy "$vm_name:/var/run/docker.sock" "$(aidc::vm_socket_path "$vm_name")" 2>/dev/null || true
    if [[ -S "$(aidc::vm_socket_path "$vm_name")" ]]; then
      local vm_docker_host
      vm_docker_host="unix://$(aidc::vm_socket_path "$vm_name")"
      export DOCKER_HOST="$vm_docker_host"
      aidc::log "DOCKER_HOST set to Lima VM: $DOCKER_HOST"
    else
      aidc::warn "could not locate Docker socket for Lima VM $vm_name"
    fi
  fi
}

aidc::lima_stop() {
  local workspace="$1"
  local vm_name
  vm_name="$(aidc::vm_name "$workspace")"

  if ! limactl list --format '{{.Name}}' 2>/dev/null | grep -qxF "$vm_name"; then
    return
  fi

  aidc::log "stopping Lima VM $vm_name ..."
  limactl stop "$vm_name"
  unset DOCKER_HOST
  aidc::log "Lima VM $vm_name stopped"
}

aidc::lima_destroy() {
  local workspace="$1"
  local vm_name
  vm_name="$(aidc::vm_name "$workspace")"

  if ! limactl list --format '{{.Name}}' 2>/dev/null | grep -qxF "$vm_name"; then
    return
  fi

  aidc::log "destroying Lima VM $vm_name ..."
  limactl delete --force "$vm_name"

  local config_path
  config_path="$(aidc::lima_config_path "$vm_name")"
  rm -f "$config_path"

  unset DOCKER_HOST
  aidc::log "Lima VM $vm_name destroyed"
}

aidc::firecracker_ensure() {
  local workspace="$1"
  aidc::need_cmd firecracker

  if [[ ! -f "$AIDC_FIRECRACKER_KERNEL" ]]; then
    aidc::die "Firecracker kernel not found at $AIDC_FIRECRACKER_KERNEL. " \
      "Set AIDC_FIRECRACKER_KERNEL in .ai-container/project.env or place a kernel there."
  fi
  if [[ ! -f "$AIDC_FIRECRACKER_ROOTFS" ]]; then
    aidc::die "Firecracker rootfs not found at $AIDC_FIRECRACKER_ROOTFS. " \
      "Set AIDC_FIRECRACKER_ROOTFS in .ai-container/project.env or place a rootfs there."
  fi

  local vm_name
  vm_name="$(aidc::vm_name "$workspace")"
  local socket_dir="$AIDC_FIRECRACKER_SOCKET_DIR"
  local fc_socket="$socket_dir/$vm_name.sock"
  mkdir -p "$socket_dir"

  # Already running?  Check the socket.
  if [[ -S "$fc_socket" ]] && curl -s --unix-socket "$fc_socket" http://localhost/ >/dev/null 2>&1; then
    aidc::log "Firecracker VM $vm_name is already running"
    return
  fi

  aidc::log "creating Firecracker VM $vm_name ..."
  aidc::log "  Kernel: $AIDC_FIRECRACKER_KERNEL  Rootfs: $AIDC_FIRECRACKER_ROOTFS"
  aidc::log "  ⚠ Each isolated VM uses significant CPU/RAM/disk. See README 'Isolation modes'."

  # Generate a per-VM copy-on-write rootfs overlay so the base image stays clean.
  local vm_rootfs="$socket_dir/$vm_name-rootfs.ext4"
  if [[ ! -f "$vm_rootfs" ]]; then
    cp --reflink=auto "$AIDC_FIRECRACKER_ROOTFS" "$vm_rootfs" 2>/dev/null || \
      cp "$AIDC_FIRECRACKER_ROOTFS" "$vm_rootfs"
  fi

  # Firecracker config via API socket.
  rm -f "$fc_socket"
  firecracker --api-sock "$fc_socket" &
  local fc_pid=$!

  # Give Firecracker a moment to create the socket.
  local tries=0
  while [[ ! -S "$fc_socket" ]] && [[ $tries -lt 20 ]]; do
    sleep 0.25
    tries=$((tries + 1))
  done
  [[ -S "$fc_socket" ]] || aidc::die "Firecracker failed to start (socket not created)"

  # Configure the microVM via the API.
  local kernel_boot_args="console=ttyS0 reboot=k panic=1 pci=off"
  curl -s --unix-socket "$fc_socket" -X PUT "http://localhost/boot-source" \
    -H "Content-Type: application/json" \
    -d "{\"kernel_image_path\":\"$AIDC_FIRECRACKER_KERNEL\",\"boot_args\":\"$kernel_boot_args\"}" || true

  curl -s --unix-socket "$fc_socket" -X PUT "http://localhost/drives/rootfs" \
    -H "Content-Type: application/json" \
    -d "{\"drive_id\":\"rootfs\",\"path_on_host\":\"$vm_rootfs\",\"is_root_device\":true,\"is_read_only\":false}" || true

  # Network: use a TAP device.  Create one if it doesn't exist.
  local tap_name="aidc-${vm_name:0:12}"
  if ! ip link show "$tap_name" >/dev/null 2>&1; then
    ip tuntap add dev "$tap_name" mode tap 2>/dev/null || true
    ip addr add 172.30.0.1/24 dev "$tap_name" 2>/dev/null || true
    ip link set "$tap_name" up 2>/dev/null || true
  fi
  curl -s --unix-socket "$fc_socket" -X PUT "http://localhost/network-interfaces/eth0" \
    -H "Content-Type: application/json" \
    -d "{\"iface_id\":\"eth0\",\"host_dev_name\":\"$tap_name\",\"guest_mac\":\"AA:FC:00:00:00:01\"}" 2>/dev/null || true

  curl -s --unix-socket "$fc_socket" -X PUT "http://localhost/machine-config" \
    -H "Content-Type: application/json" \
    -d "{\"vcpu_count\":${AIDC_LIMA_CPUS},\"mem_size_mib\":$(( ${AIDC_LIMA_MEMORY%[^0-9]*} * 1024 ))}" 2>/dev/null || \
    curl -s --unix-socket "$fc_socket" -X PUT "http://localhost/machine-config" \
      -H "Content-Type: application/json" \
      -d '{"vcpu_count":2,"mem_size_mbibytes":2048}' 2>/dev/null || true

  curl -s --unix-socket "$fc_socket" -X PUT "http://localhost/actions" \
    -H "Content-Type: application/json" \
    -d '{"action_type":"InstanceStart"}' || true

  aidc::log "Firecracker VM $vm_name started (pid $fc_pid)"
  aidc::warn "Firecracker backend is experimental — Docker inside the microVM is not yet automated"
  aidc::warn "You will need to SSH into the VM and run 'docker compose up' manually for now"
}

aidc::firecracker_stop() {
  local workspace="$1"
  local vm_name
  vm_name="$(aidc::vm_name "$workspace")"
  local fc_socket="$AIDC_FIRECRACKER_SOCKET_DIR/$vm_name.sock"

  if [[ -S "$fc_socket" ]]; then
    curl -s --unix-socket "$fc_socket" -X PUT "http://localhost/actions" \
      -H "Content-Type: application/json" \
      -d '{"action_type":"InstanceHalt"}' 2>/dev/null || true
    rm -f "$fc_socket"
    aidc::log "Firecracker VM $vm_name stopped"
  fi
}

aidc::firecracker_destroy() {
  local workspace="$1"
  local vm_name
  vm_name="$(aidc::vm_name "$workspace")"
  local socket_dir="$AIDC_FIRECRACKER_SOCKET_DIR"

  # Halt if running.
  local fc_socket="$socket_dir/$vm_name.sock"
  if [[ -S "$fc_socket" ]]; then
    curl -s --unix-socket "$fc_socket" -X PUT "http://localhost/actions" \
      -H "Content-Type: application/json" \
      -d '{"action_type":"InstanceHalt"}' 2>/dev/null || true
  fi

  rm -f "$fc_socket" "$socket_dir/$vm_name-rootfs.ext4"
  aidc::log "Firecracker VM $vm_name destroyed"
}
