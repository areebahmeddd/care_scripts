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

  required_packages=("curl" "git" "apt-transport-https" "ca-certificates" "build-essential" "unzip" "nginx" "gnupg" "lsof")

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
  if command_exists docker; then
    echo "Docker is already installed."
  else
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
  fi
}

install_node() {
  echo "Checking for Node.js installation..."

  if command_exists node; then
    echo "Node.js is already installed. Version: $(node -v)"
  else
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
  fi
}

check_ports() {
  echo "Checking for port conflicts..."

  for port in 80 4000 9000; do
    if lsof -i:$port > /dev/null 2>&1; then
      echo "Port $port is in use. Attempting to free it..."
      sudo kill -9 $(lsof -t -i:$port)
      echo "Port $port is now free."
    else
      echo "Port $port is free."
    fi
  done
}

setup_backend() {
  echo "Setting up CARE Backend..."
  export COMPOSE_BAKE=true

  if [ -d "care" ]; then
    echo "Backend repository exists. Pulling latest changes..."
    cd care
    git pull
  else
    git clone https://github.com/ohcnetwork/care.git
    cd care
  fi

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
    git clone https://github.com/ohcnetwork/care_fe.git
    cd care_fe
  fi

  echo "Installing frontend dependencies..."
  npm install --yes

  # echo "Running setup script..."
  # npm run setup --yes

  echo "Updating API URL..."

  # Check if the server is a cloud VM or local machine
  if curl -s --connect-timeout 3 "http://$PUBLIC_IP" > /dev/null 2>&1; then
    sed -i "s|REACT_CARE_API_URL=.*|REACT_CARE_API_URL=http://$PUBLIC_IP|g" .env
    IS_CLOUD_VM=true
  else
    sed -i "s|REACT_CARE_API_URL=.*|REACT_CARE_API_URL=http://localhost:9000|g" .env
    IS_CLOUD_VM=false
  fi

  echo "Starting frontend development server..."
  nohup npm run dev > /dev/null 2>&1 &
}

create_superuser() {
  echo "Creating Django superuser..."

  cd ../care

  docker compose exec backend bash -c "
    export DJANGO_SUPERUSER_USERNAME=ohcadmin
    export DJANGO_SUPERUSER_PASSWORD=admin@123
    export DJANGO_SUPERUSER_EMAIL=hi@example.com
    python manage.py createsuperuser --noinput
  "
}

configure_nginx() {
  echo "Configuring Nginx..."

  NGINX_CONF_PATH="/etc/nginx/sites-available/care"
  API_BASE_PATH="/api/v1"

  cat > "$NGINX_CONF_PATH" << EOF
server {
    listen 80;
    server_name ${PUBLIC_IP};

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
check_ports

setup_backend
setup_frontend
create_superuser
configure_nginx
# cleanup

echo "========================================"
echo "✅ Installation complete!"
echo ""
if [ "$IS_CLOUD_VM" = true ]; then
  echo "🌐 CARE Frontend URL : http://$PUBLIC_IP"
  echo "🔧 CARE Backend URL  : http://$PUBLIC_IP/api/v1"
else
  echo "🌐 CARE Frontend URL : http://localhost:4000"
  echo "🔧 CARE Backend URL  : http://localhost:9000"
fi
echo ""
echo "🔐 Superuser Credentials:"
echo "    Username : ohcadmin"
echo "    Password : admin@123"
echo ""
echo "📘 Docs & FAQ: https://docs.ohc.network/docs/faq"
echo "========================================"
