#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# ==========================================
# Nginx Configurator Script
# ==========================================

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Helper Functions ---
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
check_local_deps() {
    log_info "Checking local dependencies..."
    local deps=("ssh" "curl" "dig" "scp")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            die "Required local dependency '$dep' is missing. Please install it."
        fi
    done
    log_success "All local dependencies found."
}

# --- Remote Execution Wrapper ---
run_remote() {
    local cmd="$1"
    local ssh_cmd=("ssh" "-o" "StrictHostKeyChecking=accept-new" "-o" "ConnectTimeout=10")
    if [[ -n "${VPS_KEY:-}" && -f "$VPS_KEY" ]]; then
        ssh_cmd+=("-i" "$VPS_KEY")
    fi

    if [[ -n "${VPS_PASS:-}" ]] && command -v sshpass >/dev/null 2>&1; then
        sshpass -p "$VPS_PASS" "${ssh_cmd[@]}" -q "$VPS_USER@$VPS_IP" "$cmd"
    else
        "${ssh_cmd[@]}" -q "$VPS_USER@$VPS_IP" "$cmd"
    fi
}
run_remote_sudo() {
    local cmd="$1"
    if [[ -n "${VPS_PASS:-}" ]]; then
        run_remote "echo '$VPS_PASS' | sudo -S -p '' bash -c $(printf "%q" "$cmd")"
    else
        run_remote "sudo bash -c $(printf "%q" "$cmd")"
    fi
}
scp_to_remote() {
    local local_file="$1"
    local remote_path="$2"
    local scp_cmd=("scp" "-o" "StrictHostKeyChecking=accept-new")
    if [[ -n "${VPS_KEY:-}" && -f "$VPS_KEY" ]]; then
        scp_cmd+=("-i" "$VPS_KEY")
    fi

    if [[ -n "${VPS_PASS:-}" ]] && command -v sshpass >/dev/null 2>&1; then
        sshpass -p "$VPS_PASS" "${scp_cmd[@]}" -q "$local_file" "$VPS_USER@$VPS_IP:$remote_path"
    else
        "${scp_cmd[@]}" -q "$local_file" "$VPS_USER@$VPS_IP:$remote_path"
    fi
}

# --- 2. Step-by-Step Gathering and Validation ---
step_vps() {
    echo -e "\n--- VPS Connection Details ---"
    echo "Provide the connection details for the remote server (VPS) where Nginx will be configured."
    prompt "VPS IP address or Hostname (Example: 192.168.1.100 or myserver.com)" VPS_IP
    prompt "SSH Username (Example: root, ubuntu, admin)" VPS_USER "root"
    read -r -p "SSH Key Path (leave blank for default): " VPS_KEY
    [[ -z "$VPS_KEY" ]] && VPS_KEY="$HOME/.ssh/id_rsa_laxmi_sysinfra"
    prompt_password "SSH Password (leave blank and press Enter if using SSH keys)" VPS_PASS
    if [[ -n "$VPS_PASS" ]] && ! command -v sshpass >/dev/null 2>&1; then
        export ASKPASS_SCRIPT=$(mktemp)
        echo '#!/bin/bash' > "$ASKPASS_SCRIPT"
        echo 'echo "$VPS_PASS"' >> "$ASKPASS_SCRIPT"
        chmod +x "$ASKPASS_SCRIPT"
        export SSH_ASKPASS="$ASKPASS_SCRIPT"
        export SSH_ASKPASS_REQUIRE=force
        export DISPLAY=dummydisplay:0
        trap 'rm -f "$ASKPASS_SCRIPT"' EXIT
    fi
    verify_vps
}

step_domain() {
    echo -e "\n--- Website Details ---"
    echo "This is the domain name users will type into their browser."
    prompt "Domain or Subdomain (Example: api.mywebsite.com or mywebsite.com)" DOMAIN
    verify_dns
}

step_application() {
    echo -e "\n--- Service Role ---"
    echo "What kind of application are you hosting?"
    echo "1) Frontend (e.g., React, Vue, Static HTML)"
    echo "2) Backend / API (e.g., Node.js, Python API, Go server)"
    prompt "Select Service Role (Enter 1 or 2)" ROLE_CHOICE
    if [[ "$ROLE_CHOICE" == "1" ]]; then
        ROLE="Frontend"
        echo -e "\n--- Application Type ---"
        echo "How is your frontend running?"
        echo "1) Docker (Running in a container)"
        echo "2) Static files (Raw HTML/CSS/JS files on the server)"
        prompt "Select App Type (Enter 1 or 2)" APP_CHOICE
        if [[ "$APP_CHOICE" == "1" ]]; then
            APP_TYPE="docker"
            prompt "Container Port - The port your Docker container exposes (Example: 3000, 80)" APP_PORT
        elif [[ "$APP_CHOICE" == "2" ]]; then
            APP_TYPE="static"
            prompt "Static files directory - Absolute path on the VPS to your built files (Example: /var/www/mywebsite/html)" APP_DIR
        else
            die "Invalid choice. Please enter 1 or 2."
        fi
        
        echo -e "\n--- API Connection ---"
        prompt "Enter the Backend API Domain this frontend connects to (Example: api.mywebsite.com) or leave blank if none" CONNECTED_DOMAIN ""

    elif [[ "$ROLE_CHOICE" == "2" ]]; then
        ROLE="Backend"
        echo -e "\n--- Application Type ---"
        echo "How is your backend running?"
        echo "1) Docker (Running in a container)"
        echo "2) Existing service/process (e.g., running via PM2, systemd, or raw command)"
        prompt "Select App Type (Enter 1 or 2)" APP_CHOICE
        if [[ "$APP_CHOICE" == "1" ]]; then
            APP_TYPE="docker"
            prompt "Container Port - The port your Docker container exposes (Example: 8080, 5000)" APP_PORT
        elif [[ "$APP_CHOICE" == "2" ]]; then
            APP_TYPE="service"
            prompt "Backend Port - The port your backend application is listening on (Example: 8080, 3000)" APP_PORT
        else
            die "Invalid choice. Please enter 1 or 2."
        fi
        
        echo -e "\n--- CORS Configuration ---"
        prompt "Enter the Frontend Domain allowed to access this API for CORS (Example: mywebsite.com) or leave blank if none" CONNECTED_DOMAIN ""

    else
        die "Invalid choice. Please enter 1 or 2."
    fi
    verify_application
}

step_ssl() {
    echo -e "\n--- SSL Status ---"
    echo "How do you want to secure your site with HTTPS?"
    echo "1) Let's Encrypt (Automatically generate a free SSL certificate on the VPS)"
    echo "2) Cloudflare Origin CA (You have your own .pem and .key files locally)"
    echo "3) No SSL / Terminate elsewhere (I'll handle SSL later, or I'm using a Load Balancer)"
    prompt "Select SSL option (Enter 1, 2, or 3)" SSL_CHOICE

    if [[ "$SSL_CHOICE" == "2" ]]; then
        echo "Please provide the absolute paths on your local machine to your Cloudflare certificates."
        prompt "Local path to Cloudflare Origin Certificate (Example: /home/user/certs/mywebsite.pem)" CF_CERT_PATH
        prompt "Local path to Cloudflare Origin Private Key (Example: /home/user/certs/mywebsite.key)" CF_KEY_PATH
        if [[ ! -f "$CF_CERT_PATH" || ! -f "$CF_KEY_PATH" ]]; then
            die "Cloudflare cert or key file not found locally. Please check the paths."
        fi
    fi

    echo -e "\n--- HTTP Redirect ---"
    prompt "Automatically redirect all insecure HTTP traffic to secure HTTPS? (y/n) (Example: y)" HTTP_REDIRECT "y"
}

# --- 3. Verify Connection and Environment ---
verify_vps() {
    log_info "Connecting to VPS ($VPS_USER@$VPS_IP)..."
    if ! run_remote "echo 'Connection successful'"; then
        die "Failed to connect to VPS via SSH. Check IP, user, and password."
    fi
    log_success "SSH connection verified."

    log_info "Checking sudo access..."
    if ! run_remote_sudo "echo 'Sudo access verified'"; then
        die "User does not have sudo privileges or password is incorrect."
    fi
    log_success "Sudo access verified."

    log_info "Checking Nginx installation..."
    if ! run_remote_sudo "command -v nginx >/dev/null"; then
        log_warn "Nginx is not installed. Installing Nginx..."
        if run_remote_sudo "apt-get update -y && apt-get install -y nginx"; then
            log_success "Nginx installed successfully."
        else
            die "Failed to install Nginx."
        fi
    fi

    log_info "Ensuring Nginx is running..."
    if ! run_remote_sudo "systemctl enable --now nginx"; then
        log_warn "Nginx could not be started right now (it might have a broken default config). We will fix the config shortly."
    fi
}

verify_dns() {
    log_info "Checking DNS for $DOMAIN..."
    local resolved_ips
    resolved_ips=$(dig +short "$DOMAIN")
    if [[ -z "$resolved_ips" ]]; then
        log_warn "No DNS records found for $DOMAIN. Ensure Cloudflare or your DNS provider is configured."
    else
        log_info "$DOMAIN resolves to: $resolved_ips"
        log_info "Note: If using Cloudflare Proxy (orange cloud), IP will not match VPS IP, which is expected."
    fi
}

verify_application() {
    if [[ "$APP_TYPE" == "docker" ]]; then
        log_info "Checking Docker availability..."
        if ! run_remote_sudo "docker --version >/dev/null 2>&1" && ! run_remote "docker --version >/dev/null 2>&1"; then
            die "Docker is not installed on the VPS."
        fi
        log_info "Checking if port $APP_PORT is in use..."
        if ! run_remote_sudo "ss -tulpn | grep -q ':$APP_PORT '"; then
            log_warn "Nothing seems to be listening on port $APP_PORT currently. Ensure your container is running."
        else
            log_success "Service detected on port $APP_PORT."
        fi
    elif [[ "$APP_TYPE" == "static" ]]; then
        log_info "Checking static directory $APP_DIR..."
        if ! run_remote_sudo "test -d '$APP_DIR'"; then
            die "Directory '$APP_DIR' does not exist on the VPS."
        fi
        log_success "Directory $APP_DIR verified."
    elif [[ "$APP_TYPE" == "service" ]]; then
        log_info "Checking if service is listening on port $APP_PORT..."
        if ! run_remote_sudo "ss -tulpn | grep -q ':$APP_PORT '"; then
            log_warn "Nothing seems to be listening on port $APP_PORT currently."
        else
            log_success "Service detected on port $APP_PORT."
        fi
    fi
}

# --- 4. Setup SSL ---
setup_ssl() {
    SSL_CERT_PATH=""
    SSL_KEY_PATH=""

    if [[ "$SSL_CHOICE" == "1" ]]; then
        log_info "Setting up Let's Encrypt for $DOMAIN..."
        if ! run_remote_sudo "command -v certbot >/dev/null"; then
            log_info "Installing certbot..."
            run_remote_sudo "apt-get install -y certbot"
        fi
        
        log_info "Obtaining Let's Encrypt certificate..."
        if run_remote_sudo "[ -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem ]"; then
            log_success "Certificate already exists for $DOMAIN. Skipping Certbot generation."
        else
            # Stop Nginx temporarily to free up port 80 for Certbot standalone server
            run_remote_sudo "systemctl stop nginx || true"
            
            if ! run_remote_sudo "certbot certonly --standalone -d $DOMAIN --non-interactive --keep-until-expiring --agree-tos -m admin@$DOMAIN"; then
                run_remote_sudo "systemctl start nginx || true"
                die "Failed to obtain Let's Encrypt certificate."
            fi
            
            # Restart Nginx safely
            if ! run_remote_sudo "systemctl start nginx"; then
                log_warn "Nginx failed to start after Certbot. It might be due to a bad existing config. We will proceed to deploy the new config anyway."
            fi
        fi
        
        SSL_CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
        SSL_KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
        
        log_success "Let's Encrypt certificate obtained."

    elif [[ "$SSL_CHOICE" == "2" ]]; then
        log_info "Uploading Cloudflare Origin Certificates..."
        run_remote_sudo "mkdir -p /etc/nginx/ssl/$DOMAIN"
        scp_to_remote "$CF_CERT_PATH" "/tmp/$DOMAIN.pem"
        scp_to_remote "$CF_KEY_PATH" "/tmp/$DOMAIN.key"
        run_remote_sudo "mv /tmp/$DOMAIN.pem /etc/nginx/ssl/$DOMAIN/cert.pem"
        run_remote_sudo "mv /tmp/$DOMAIN.key /etc/nginx/ssl/$DOMAIN/key.pem"
        run_remote_sudo "chmod 600 /etc/nginx/ssl/$DOMAIN/key.pem"
        
        SSL_CERT_PATH="/etc/nginx/ssl/$DOMAIN/cert.pem"
        SSL_KEY_PATH="/etc/nginx/ssl/$DOMAIN/key.pem"
        log_success "Cloudflare Origin CA certificates uploaded."
    fi
}

# --- 5. Generate and Deploy Nginx Config ---
deploy_nginx_config() {
    log_info "Generating Nginx configuration..."
    
    local tmp_conf="nginx_$DOMAIN.conf"
    
    cat > "$tmp_conf" <<EOF
# Nginx configuration for $DOMAIN
# Generated by nginx-configurator.sh

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

EOF

    if [[ "$HTTP_REDIRECT" == "y" || "$HTTP_REDIRECT" == "Y" ]] && [[ "$SSL_CHOICE" != "3" ]]; then
        cat >> "$tmp_conf" <<EOF
    # Redirect HTTP to HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
    else
        # HTTP block handling
        if [[ -n "${CONNECTED_DOMAIN:-}" && "$ROLE" == "Frontend" ]]; then
            cat >> "$tmp_conf" <<EOF
    # Allow frontend to connect to the backend API
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline' 'unsafe-eval'; connect-src 'self' http://$CONNECTED_DOMAIN https://$CONNECTED_DOMAIN;" always;
EOF
        fi

        if [[ "$APP_TYPE" == "static" ]]; then
            cat >> "$tmp_conf" <<EOF
    root $APP_DIR;
    index index.html index.htm;
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
        else
            cat >> "$tmp_conf" <<EOF
    location / {
EOF
            if [[ -n "${CONNECTED_DOMAIN:-}" && "$ROLE" == "Backend" ]]; then
                cat >> "$tmp_conf" <<EOF
        # CORS Preflight
        if (\$request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin "http://$CONNECTED_DOMAIN" always;
            add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
            add_header Access-Control-Allow-Headers "Authorization, Content-Type, Cache-Control, Pragma, Expires, X-Requested-With, X-CSRF-Token, Accept" always;
            add_header Access-Control-Allow-Credentials "true" always;
            add_header Content-Length 0;
            add_header Content-Type text/plain;
            return 204;
        }
EOF
            fi
            cat >> "$tmp_conf" <<EOF
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF
        fi
    fi

    # HTTPS Block
    if [[ "$SSL_CHOICE" != "3" ]]; then
        cat >> "$tmp_conf" <<EOF

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate $SSL_CERT_PATH;
    ssl_certificate_key $SSL_KEY_PATH;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

EOF
        if [[ -n "${CONNECTED_DOMAIN:-}" && "$ROLE" == "Frontend" ]]; then
            cat >> "$tmp_conf" <<EOF
    # Allow frontend to connect to the backend API
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline' 'unsafe-eval'; connect-src 'self' https://$CONNECTED_DOMAIN;" always;
EOF
        fi

        if [[ "$APP_TYPE" == "static" ]]; then
            cat >> "$tmp_conf" <<EOF
    root $APP_DIR;
    index index.html index.htm;
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
        else
            cat >> "$tmp_conf" <<EOF
    location / {
EOF
            if [[ -n "${CONNECTED_DOMAIN:-}" && "$ROLE" == "Backend" ]]; then
                cat >> "$tmp_conf" <<EOF
        # CORS Preflight
        if (\$request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin "https://$CONNECTED_DOMAIN" always;
            add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
            add_header Access-Control-Allow-Headers "Authorization, Content-Type, Cache-Control, Pragma, Expires, X-Requested-With, X-CSRF-Token, Accept" always;
            add_header Access-Control-Allow-Credentials "true" always;
            add_header Content-Length 0;
            add_header Content-Type text/plain;
            return 204;
        }
EOF
            fi
            cat >> "$tmp_conf" <<EOF
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF
        fi
    fi

    log_info "Checking for existing Nginx configuration..."
    if run_remote_sudo "[ -f /etc/nginx/sites-available/$DOMAIN ]"; then
        echo -e "\n${YELLOW}An existing Nginx configuration for $DOMAIN was found.${NC}"
        prompt "Do you want to (b)ackup and overwrite, (o)verwrite without backup, or (a)bort? (b/o/a)" BACKUP_CHOICE "b"
        
        # Convert choice to lowercase for comparison
        BACKUP_CHOICE="${BACKUP_CHOICE,,}"
        
        if [[ "$BACKUP_CHOICE" == "b" ]]; then
            log_info "Backing up existing configuration..."
            run_remote_sudo "cp /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-available/$DOMAIN.bak.\$(date +%F_%T)"
        elif [[ "$BACKUP_CHOICE" == "o" ]]; then
            log_info "Overwriting without backup..."
        else
            die "Aborted by user."
        fi
    fi

    log_info "Deploying new configuration..."
    scp_to_remote "$tmp_conf" "/tmp/$tmp_conf"
    run_remote_sudo "mv /tmp/$tmp_conf /etc/nginx/sites-available/$DOMAIN"
    run_remote_sudo "ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN"
    rm -f "$tmp_conf"
    
    # Configure Firewall securely (UFW)
    log_info "Checking UFW firewall rules..."
    if run_remote_sudo "command -v ufw >/dev/null"; then
        run_remote_sudo "ufw allow 'Nginx Full' >/dev/null 2>&1 || true"
        run_remote_sudo "ufw allow OpenSSH >/dev/null 2>&1 || true"
    fi

    log_info "Testing Nginx configuration..."
    if ! run_remote_sudo "nginx -t"; then
        run_remote_sudo "rm -f /etc/nginx/sites-enabled/$DOMAIN"
        if run_remote_sudo "[ -f /etc/nginx/sites-available/$DOMAIN.bak* ]"; then
             log_info "Restoring previous configuration..."
             # Restore latest backup
             run_remote_sudo "ls -t /etc/nginx/sites-available/$DOMAIN.bak* | head -n 1 | xargs -I {} cp {} /etc/nginx/sites-available/$DOMAIN"
             run_remote_sudo "ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN"
        fi
        die "Nginx configuration test failed. Rolled back changes."
    fi

    log_info "Reloading Nginx..."
    if ! run_remote_sudo "systemctl reload nginx"; then
        log_warn "Reload failed, attempting a full restart..."
        if ! run_remote_sudo "systemctl restart nginx"; then
            die "Nginx failed to restart with the new configuration. Please check the logs on the VPS."
        fi
    fi
    log_success "Nginx configured and reloaded successfully!"
}

# --- 6. Curl Verification ---
verify_deployment() {
    log_info "Verifying deployment locally (Origin test)..."
    local protocol="http"
    if [[ "$SSL_CHOICE" != "3" ]]; then
        protocol="https"
    fi

    local test_path="/"
    if [[ "$ROLE" == "Backend" ]]; then
        test_path="/swagger/index.html"
    fi

    # Origin test
    if [[ "$protocol" == "https" ]]; then
        log_info "Running Origin HTTPS test on VPS..."
        if run_remote "curl --fail --silent --show-error --max-time 15 --resolve \"$DOMAIN:443:127.0.0.1\" -k \"https://$DOMAIN$test_path\" > /dev/null"; then
            log_success "Origin HTTPS test passed."
        else
            log_error "Origin HTTPS test failed."
        fi
    else
        log_info "Running Origin HTTP test on VPS..."
        if run_remote "curl --fail --silent --show-error --max-time 15 --resolve \"$DOMAIN:80:127.0.0.1\" \"http://$DOMAIN$test_path\" > /dev/null"; then
            log_success "Origin HTTP test passed."
        else
            log_error "Origin HTTP test failed."
        fi
    fi

    log_info "Running Public test..."
    if curl --fail --silent --show-error --location --max-time 15 "$protocol://$DOMAIN$test_path" > /dev/null; then
        log_success "Public test passed."
    else
        log_error "Public test failed. (This could be due to DNS propagation or Cloudflare proxy settings)"
    fi
}

# --- Main Flow ---
main() {
    echo -e "${GREEN}======================================"
    echo -e "   Nginx Configurator Automation"
    echo -e "======================================${NC}"
    check_local_deps
    
    # Execute steps sequentially with immediate validation
    step_vps
    step_domain
    step_application
    step_ssl
    
    if [[ "$SSL_CHOICE" != "3" ]]; then
        setup_ssl
    fi
    deploy_nginx_config
    verify_deployment
    
    echo -e "\n${GREEN}======================================"
    echo -e " Configuration Complete!"
    echo -e "======================================${NC}\n"
}

main
