#!/bin/bash

set -e  # Exit if any command fails

check_debian_based() {
  if ! [ -f /etc/debian_version ] && ! grep -qi "debian\|ubuntu" /etc/os-release 2>/dev/null; then
    echo "Error: This script is intended for Debian-based systems only."
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
  echo "Checking for Docker installation..."

  if command_exists docker; then
    echo "Docker is already installed."
  else
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com | sudo sh &> /dev/null
    # sudo usermod -aG docker $USER &> /dev/null
    echo "Docker installed"
  fi
}

install_node() {
  echo "Checking for Node.js installation..."

  if command_exists node; then
    echo "Node.js is already installed. Version: $(node -v)"
  else
    echo "Installing Node.js 22..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - &> /dev/null
    sudo apt-get install -y nodejs &> /dev/null
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

load_fixtures() {
  echo "Loading fixtures for CARE..."
  cd ../care
  make load-fixtures
  echo "Fixtures loaded successfully."
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

check_debian_based
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
load_fixtures
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
echo "🔐 Default Admin Credentials:"
echo "    Username : admin"
echo "    Password : admin"
echo ""
echo "🔐 Other User Credentials:"
echo "    Role            Username                       Password"
echo "    ----------------------------------------------------------"
echo "    Volunteer       volunteer_2_0                  Coronasafe@123"
echo "    Doctor          doctor_2_0                     Coronasafe@123"
echo "    Staff           staff_2_0                      Coronasafe@123"
echo "    Nurse           nurse_2_0                      Coronasafe@123"
echo "    Administrator   administrator_2_0              Coronasafe@123"
echo "    Facility Admin  facility_admin_2_0             Coronasafe@123"
echo ""
echo "📘 Docs & FAQ: https://docs.ohc.network/docs/faq"
echo "========================================"
