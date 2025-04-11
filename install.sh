#!/bin/bash

set -e  # Exit if any command fails

check_ubuntu() {
  if ! grep -q "Ubuntu" /etc/os-release; then
    echo "Error: This script is intended for Ubuntu systems only."
    exit 1
  fi
}

check_disk_space() {
  REQUIRED_SPACE=36  # GB
  AVAILABLE_SPACE=$(df / --output=avail | tail -n 1)
  AVAILABLE_SPACE_GB=$((AVAILABLE_SPACE / 1024 / 1024))  # Convert to GB

  if [ "$AVAILABLE_SPACE_GB" -lt "$REQUIRED_SPACE" ]; then
    echo "Error: At least ${REQUIRED_SPACE}GB required. Only ${AVAILABLE_SPACE_GB}GB available."
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

install_dependencies() {
  echo "Installing required dependencies..."

  required_packages=("curl" "git" "apt-transport-https" "ca-certificates" "build-essential" "unzip" "gnupg")

  for pkg in "${required_packages[@]}"; do
    if ! command_exists "$pkg"; then
      echo "Installing $pkg..."
      apt-get install -y "$pkg"
    else
      echo "$pkg is already installed."
    fi
  done
}

install_caddy() {
  echo "Installing Caddy..."

  # Add Caddy repository
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
  sudo apt install caddy

  # Start Caddy service
  systemctl enable caddy
  systemctl start caddy

  echo "Caddy installed successfully"
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
    cd ..
  else
    echo "Cloning backend repository..."
    git clone https://github.com/ohcnetwork/care.git
  fi

  cd care
  echo "Starting backend services with Docker..."
  make up
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

configure_caddy() {
  echo "Configuring Caddy..."
  API_BASE_PATH="/api/v1"

  # Create Caddy configuration file
  cat > /etc/caddy/Caddyfile << EOF
$PUBLIC_IP {
    # tls internal

    # Frontend
    handle / {
        reverse_proxy localhost:4000
    }

    # Backend
    handle $API_BASE_PATH/* {
        reverse_proxy localhost:9000
    }

    # Log requests
    log {
        output file /var/log/caddy/access.log
    }
}
EOF

  # Create log directory
  mkdir -p /var/log/caddy
  chown -R caddy:caddy /var/log/caddy

  # Reload Caddy to apply new configuration
  systemctl reload caddy

  echo "Caddy configuration updated."
}

update_frontend_config() {
  echo "Updating API URL to use Caddy proxy path..."
  if [ -f ".env" ]; then
    sed -i "s|REACT_CARE_API_URL=.*|REACT_CARE_API_URL=http://$PUBLIC_IP|g" .env
  else
    echo "REACT_CARE_API_URL=http://$PUBLIC_IP" > .env
  fi

  echo "Starting frontend development server..."
  nohup npm run dev > /dev/null 2>&1 &
}

cleanup() {
  echo "Clearing any existing port forwarding rules..."
  iptables -t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 4000 2>/dev/null || true
  netfilter-persistent save
}

### --- Main Script Execution --- ###

echo "Starting CARE installation..."

check_ubuntu
check_disk_space

PUBLIC_IP=$(curl -s http://checkip.amazonaws.com)
echo "Public IP: $PUBLIC_IP"

install_dependencies
install_caddy
install_docker
install_node

setup_backend
setup_frontend
configure_caddy
update_frontend_config

cleanup

echo "Installation complete!"
echo "CARE Frontend is running at: http://$PUBLIC_IP"
echo "CARE Backend is running at: http://$PUBLIC_IP/api/v1"
