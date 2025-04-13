#!/bin/bash

set -e  # Exit if any command fails

check_ubuntu() {
  if ! grep -q "Ubuntu" /etc/os-release; then
    echo "Error: This script is intended for Ubuntu systems only."
    exit 1
  fi
}

check_disk_space() {
  REQUIRED_SPACE=30  # GB
  AVAILABLE_SPACE=$(df / --output=avail | tail -n 1)
  AVAILABLE_SPACE_GB=$((AVAILABLE_SPACE / 1024 / 1024))  # Convert to GB

  if [ "$AVAILABLE_SPACE_GB" -lt "$REQUIRED_SPACE" ]; then
    echo "Error: At least ${REQUIRED_SPACE}GB required. Only ${AVAILABLE_SPACE_GB}GB available."
    exit 1
  fi
}

update_system() {
  echo "Updating system packages..."
  apt-get update && apt-get upgrade -y
  sudo apt autoremove -y
  echo "System update complete."
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

install_dependencies() {
  echo "Installing required dependencies..."

  required_packages=("curl" "git" "apt-transport-https" "ca-certificates" "build-essential" "unzip" "nginx" "gnupg")

  for pkg in "${required_packages[@]}"; do
    if ! command_exists "$pkg"; then
      echo "Installing $pkg..."
      apt-get install -y "$pkg"
    else
      echo "$pkg is already installed."
    fi
  done
}

install_docker() {
  echo "Setting up Docker repository..."
  install -m 0755 -d /etc/apt/keyrings

  echo "Adding Docker GPG key..."
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  echo "Adding Docker repository to APT sources..."
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update -y

  echo "Installing Docker..."
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable docker
  systemctl start docker
}

install_node() {
  echo "Installing Node.js 22..."

  # Set up fnm (Fast Node Manager)
  export FNM_DIR="$HOME/.fnm"
  export PATH="$FNM_DIR:$PATH"

  TEMP_DIR=$(mktemp -d)
  curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "$TEMP_DIR" --skip-shell

  # Move fnm to system path
  mkdir -p /usr/local/lib/fnm
  cp -r "$TEMP_DIR"/* /usr/local/lib/fnm/
  ln -sf /usr/local/lib/fnm/fnm /usr/local/bin/fnm

  export PATH="/usr/local/bin:$PATH"

  # Install and link Node.js 22
  fnm install 22
  CURRENT_NODE_PATH=$(fnm exec --using=22 which node)
  CURRENT_NPM_PATH=$(fnm exec --using=22 which npm)
  ln -sf "$CURRENT_NODE_PATH" /usr/local/bin/node
  ln -sf "$CURRENT_NPM_PATH" /usr/local/bin/npm

  rm -rf "$TEMP_DIR"

  echo "Node.js $(node -v) and npm $(npm -v) installed"
}

setup_backend() {
  echo "Setting up CARE Backend..."
  export COMPOSE_BAKE=true

  if [ -d "care" ]; then
    echo "Backend repository exists. Pulling latest changes..."
    cd care
    git pull
  else
    echo "Cloning backend repository..."
    git clone https://github.com/ohcnetwork/care.git
    cd care
  fi

  # Check if Docker services are already up
  if docker compose ps | grep -q "Up"; then
    echo "Backend services already running. Skipping 'make up'."
  else
    echo "Starting backend services with Docker..."
    make up
  fi
}

setup_frontend() {
  echo "Setting up CARE Frontend..."
  cd ..

  if [ -d "care_fe" ]; then
    echo "Frontend repository exists. Pulling latest changes..."
    cd care_fe
    git pull
  else
    echo "Cloning frontend repository..."
    git clone https://github.com/ohcnetwork/care_fe.git
    cd care_fe
  fi

  echo "Installing frontend dependencies..."
  npm install --yes

  echo "Running setup script..."
  npm run setup --yes
}

configure_nginx() {
  echo "Configuring Nginx..."
  API_BASE_PATH="/api/v1"

  cat > /etc/nginx/sites-available/care << EOF
server {
    listen 80;
    server_name _;

    location / {
      proxy_pass http://localhost:4000;
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection 'upgrade';
      proxy_set_header Host \$host;
      proxy_cache_bypass \$http_upgrade;
    }

    location ${API_BASE_PATH}/ {
      proxy_pass http://localhost:9000${API_BASE_PATH}/;
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection 'upgrade';
      proxy_set_header Host \$host;
      proxy_cache_bypass \$http_upgrade;
    }

    access_log /var/log/nginx/care-access.log;
    error_log /var/log/nginx/care-error.log;
}
EOF

  echo "Activating Nginx configuration..."
  ln -sf /etc/nginx/sites-available/care /etc/nginx/sites-enabled/
  rm -f /etc/nginx/sites-enabled/default
  systemctl restart nginx
}

update_frontend_config() {
  echo "Updating API URL to use Nginx proxy path..."
  if [ -f ".env" ]; then
    sed -i "s|REACT_CARE_API_URL=.*|REACT_CARE_API_URL=http://$PUBLIC_IP|g" .env
  else
    echo "REACT_CARE_API_URL=http://$PUBLIC_IP" > .env
  fi

  # Check if npm dev server is already running
  if pgrep -f "npm run dev" > /dev/null; then
    echo "Frontend development server already running. Skipping 'npm run dev'."
  else
    echo "Starting frontend development server..."
    nohup npm run dev > /dev/null 2>&1 &
  fi
}

# cleanup() {
#   echo "Clearing any existing port forwarding rules..."
#   iptables -t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 4000 2>/dev/null || true
#   netfilter-persistent save
# }

### --- Main Script Execution --- ###

echo "Starting CARE installation..."

check_ubuntu
check_disk_space
update_system

PUBLIC_IP=$(curl -s http://checkip.amazonaws.com)
echo "Public IP: $PUBLIC_IP"

install_dependencies
install_docker
install_node

setup_backend
setup_frontend
configure_nginx
update_frontend_config
# cleanup

echo "Installation complete!"
echo "CARE Frontend is running at: http://$PUBLIC_IP"
echo "CARE Backend is running at: http://$PUBLIC_IP/api/v1"
