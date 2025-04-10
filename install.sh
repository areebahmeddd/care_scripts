#!/bin/bash

set -e  # Exit if any command fails

echo "Starting CARE installation..."
# Get public IP address
PUBLIC_IP=$(curl -s http://checkip.amazonaws.com)

### --- System Update & Essentials --- ###

echo "Updating system packages..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

echo "Installing build essentials..."
apt-get install -y build-essential

echo "Installing git..."
apt-get install -y git


### --- Docker Installation --- ###

echo "Setting up Docker repository..."
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings

# Add Docker GPG key
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Add Docker repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
| tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y

echo "Installing Docker..."
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker
systemctl start docker


### --- Node.js 22 via fnm --- ###

echo "Installing Node.js 22..."
apt-get install -y unzip

# Set up fnm
export FNM_DIR="$HOME/.fnm"
export PATH="$FNM_DIR:$PATH"

# Temporary install directory
TEMP_DIR=$(mktemp -d)
curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "$TEMP_DIR" --skip-shell

# Move fnm to system path
mkdir -p /usr/local/lib/fnm
cp -r "$TEMP_DIR"/* /usr/local/lib/fnm/
ln -sf /usr/local/lib/fnm/fnm /usr/local/bin/fnm

# Load fnm in script
export PATH="/usr/local/bin:$PATH"

# Install and link Node.js 22
fnm install 22
CURRENT_NODE_PATH=$(fnm exec --using=22 which node)
CURRENT_NPM_PATH=$(fnm exec --using=22 which npm)
ln -sf "$CURRENT_NODE_PATH" /usr/local/bin/node
ln -sf "$CURRENT_NPM_PATH" /usr/local/bin/npm

# Cleanup
rm -rf "$TEMP_DIR"

echo "Node.js $(node -v) and npm $(npm -v) installed"


### --- CARE Backend Setup --- ###

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
cd ..


### --- CARE Frontend Setup --- ###

echo "Setting up CARE Frontend..."

if [ -d "care_fe" ]; then
  echo "Frontend repository exists. Pulling latest changes..."
  cd care_fe
  git pull
else
  echo "Cloning frontend repository..."
  git clone https://github.com/ohcnetwork/care_fe.git
  cd care_fe
fi

# Install dependencies and run setup
echo "Installing frontend dependencies..."
npm install --yes

echo "Running setup script..."
npm run setup --yes

# Update .env with backend API URL
echo "Updating API URL configuration to use http://$PUBLIC_IP:9000..."
if [ -f ".env" ]; then
  sed -i "s|REACT_CARE_API_URL=.*|REACT_CARE_API_URL=http://$PUBLIC_IP:9000|g" .env
else
  echo "REACT_CARE_API_URL=http://$PUBLIC_IP:9000" > .env
fi

# Start dev server in background
echo "Starting frontend development server..."
nohup npm run dev > /dev/null 2>&1 &


### --- Port Forwarding --- ###

echo "Forwarding port 80 to frontend on port 4000..."
iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 4000

echo "Installing iptables-persistent to save port forwarding rule..."
DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
netfilter-persistent save


### --- Completion --- ###

echo "Installation complete!"
echo "CARE Frontend is available at: http://$PUBLIC_IP"
echo "CARE Backend is available at: http://$PUBLIC_IP:9000"
