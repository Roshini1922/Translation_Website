#!/usr/bin/env bash

set -Eeuo pipefail

# ==========================================
# Universal Promote Script (Docker -> VPS)
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
die() { log_error "$1"; exit 1; }

prompt() {
    local prompt_text=$1
    local var_name=$2
    local default_val=${3:-}
    local input=""
    if [[ -n "$default_val" ]]; then
        read -r -p "$prompt_text [$default_val]: " input
        [[ -z "$input" ]] && input="$default_val"
    else
        while [[ -z "$input" ]]; do
            read -r -p "$prompt_text: " input
        done
    fi
    printf -v "$var_name" "%s" "$input"
}

prompt_password() {
    local prompt_text=$1
    local var_name=$2
    local input=""
    read -r -s -p "$prompt_text: " input
    echo ""
    printf -v "$var_name" "%s" "$input"
}

# --- 1. Check Local Dependencies ---
check_deps() {
    log_info "Checking local dependencies..."
    local deps=("docker" "ssh")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            die "Required dependency '$dep' is missing. Please install it."
        fi
    done
    log_success "All local dependencies found."
}

# --- 2. Gather VPS Details ---
step_vps_credentials() {
    echo -e "\n--- VPS Connection Details ---"
    prompt "VPS IP address or Hostname" VPS_IP
    prompt "SSH Username" VPS_USER "root"
    read -r -p "SSH Key Path (leave blank for default): " VPS_KEY
    [[ -z "$VPS_KEY" ]] && VPS_KEY="$HOME/.ssh/id_rsa_laxmi_sysinfra"
    prompt_password "SSH Password (leave blank if using SSH keys)" VPS_PASS
    
    log_info "Verifying SSH connection to VPS ($VPS_USER@$VPS_IP)..."
    if ! run_remote "echo 'Connection successful'"; then
        die "Failed to connect to VPS via SSH. Check IP, user, password, or key path."
    fi
    log_success "SSH connection verified."

    log_info "Verifying Docker on VPS..."
    if ! run_remote "docker --version >/dev/null 2>&1"; then
        log_warn "Docker is not installed on the remote VPS or requires sudo."
        prompt "Do you want to attempt installation of Docker on VPS? (y/n)" INSTALL_DOCKER "n"
        if [[ "${INSTALL_DOCKER,,}" == "y" ]]; then
             run_remote "curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh && rm get-docker.sh"
        else
            die "Cannot proceed without Docker on the VPS."
        fi
    fi
    log_success "Docker is ready on VPS."
}

# --- Remote Execution Helper ---
run_remote() {
    local cmd="$1"
    local ssh_cmd="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
    if [[ -n "$VPS_KEY" && -f "$VPS_KEY" ]]; then
        ssh_cmd="$ssh_cmd -i $VPS_KEY"
    fi

    if [[ -n "$VPS_PASS" ]] && command -v sshpass >/dev/null 2>&1; then
        sshpass -p "$VPS_PASS" $ssh_cmd -q "$VPS_USER@$VPS_IP" "$cmd"
    else
        $ssh_cmd -q "$VPS_USER@$VPS_IP" "$cmd"
    fi
}

scp_to_remote() {
    local local_file="$1"
    local remote_path="$2"
    local scp_cmd="scp -o StrictHostKeyChecking=accept-new"
    if [[ -n "$VPS_KEY" && -f "$VPS_KEY" ]]; then
        scp_cmd="$scp_cmd -i $VPS_KEY"
    fi

    if [[ -n "$VPS_PASS" ]] && command -v sshpass >/dev/null 2>&1; then
        sshpass -p "$VPS_PASS" $scp_cmd -q "$local_file" "$VPS_USER@$VPS_IP:$remote_path"
    else
        $scp_cmd -q "$local_file" "$VPS_USER@$VPS_IP:$remote_path"
    fi
}

stream_image_to_vps() {
    local target_tag="$1"
    log_info "Streaming ${target_tag} to VPS..."
    
    local ssh_cmd="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"
    if [[ -n "$VPS_KEY" && -f "$VPS_KEY" ]]; then
        ssh_cmd="$ssh_cmd -i $VPS_KEY"
    fi

    if [[ -n "$VPS_PASS" ]] && command -v sshpass >/dev/null 2>&1; then
        ssh_cmd="sshpass -p \"$VPS_PASS\" $ssh_cmd"
    fi

    # Using gzip to compress during transfer, docker load uncompresses it
    if command -v pv >/dev/null 2>&1; then
        docker save "${target_tag}" | pv | gzip | eval "$ssh_cmd \"$VPS_USER@$VPS_IP\" 'gunzip | docker load'"
    else
        docker save "${target_tag}" | gzip | eval "$ssh_cmd \"$VPS_USER@$VPS_IP\" 'gunzip | docker load'"
    fi
}

# --- 3. Discover and Build Dockerfiles ---
build_and_promote() {
    echo -e "\n--- Discovering Docker Projects ---"
    
    # Find all Dockerfiles, excluding common heavy directories
    local dockerfiles
    mapfile -t dockerfiles < <(find . -type f -name "Dockerfile" -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/dist/*" -not -path "*/vendor/*")

    if [[ ${#dockerfiles[@]} -eq 0 ]]; then
        die "No Dockerfile found in this project. Please create a Dockerfile first."
    fi

    local selected_images=()

    for df in "${dockerfiles[@]}"; do
        local dir
        dir=$(dirname "$df")
        # Get base directory name for default image name (use 'app' if it's the root directory)
        local base_dir
        base_dir=$(basename "$dir")
        if [[ "$base_dir" == "." ]]; then
            base_dir=$(basename "$PWD")
        fi
        # Clean the name to be docker-tag friendly
        base_dir=$(echo "$base_dir" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g')

        echo -e "\nFound Dockerfile at: ${YELLOW}$df${NC}"
        prompt "Do you want to build and deploy this? (y/n)" BUILD_CHOICE "y"
        
        if [[ "${BUILD_CHOICE,,}" == "y" ]]; then
            prompt "Enter Docker Image Name" IMAGE_NAME "$base_dir"
            prompt "Enter Container Port (e.g. 8080 or 3000,8080)" APP_PORT "8080"
            local target_tag="${IMAGE_NAME}:latest"
            
            log_info "Building image '${target_tag}' from directory '${dir}'..."
            if ! docker build -t "${target_tag}" "${dir}"; then
                die "Docker build failed for ${dir}"
            fi
            log_success "Built ${target_tag} successfully."
            
            # Store metadata for promotion: tag|container_name|port
            selected_images+=("${target_tag}|${IMAGE_NAME}-app|${APP_PORT}")
        fi
    done

    if [[ ${#selected_images[@]} -eq 0 ]]; then
        log_warn "No images were selected for deployment."
        exit 0
    fi

    echo -e "\n--- Promotion Phase ---"
    for img_data in "${selected_images[@]}"; do
        IFS='|' read -r tag container port <<< "$img_data"
        stream_image_to_vps "$tag"
        log_success "Promotion of ${tag} completed."
        
        echo -e "\n--- Container Management ---"
        echo "Image ${tag} is now on the VPS."
        echo "What would you like to do with the container?"
        echo "1) Start (Creates and runs a new container)"
        echo "2) Restart (Stops the old one and starts the new one)"
        echo "3) Stop (Stops and removes the container)"
        echo "4) Skip (Do nothing)"
        prompt "Select an action (1/2/3/4)" ACTION_CHOICE "2"
        
        if [[ "$ACTION_CHOICE" != "4" ]]; then
            local action_cmd=""
            if [[ "$ACTION_CHOICE" == "1" ]]; then action_cmd="start"; fi
            if [[ "$ACTION_CHOICE" == "2" ]]; then action_cmd="restart"; fi
            if [[ "$ACTION_CHOICE" == "3" ]]; then action_cmd="stop"; fi
            
            if [[ -f "./manage.sh" ]]; then
                log_info "Deploying manage.sh to VPS..."
                scp_to_remote "./manage.sh" "/tmp/manage_${container}.sh"
                run_remote "chmod +x /tmp/manage_${container}.sh"
                
                log_info "Executing '$action_cmd' on VPS..."
                run_remote "/tmp/manage_${container}.sh $action_cmd $container $port $tag"
                log_success "Container action '$action_cmd' completed successfully!"
            else
                log_error "manage.sh not found locally. Skipping container management."
            fi
        else
            log_info "Skipping container management for ${tag}."
        fi
    done
}

main() {
    echo -e "${GREEN}======================================"
    echo -e " Universal Docker Promote Script"
    echo -e "======================================${NC}"
    check_deps
    step_vps_credentials
    build_and_promote
    echo -e "\n${GREEN}======================================"
    echo -e " All chosen deployments complete!"
    echo -e "======================================${NC}\n"
}

main
