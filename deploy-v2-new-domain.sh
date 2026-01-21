#!/bin/bash

###############################################################################
# AWS CloudWatch Monitor v2.0 - Complete Deployment Script
# Domain: cwmonitorv2.logiciel-services.com
# Stack: Next.js + Tremor + Flask Backend
###############################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

###############################################################################
# CONFIGURATION
###############################################################################
NEW_DOMAIN="cwmonitorv2.logiciel-services.com"
OLD_DOMAIN="cwmonitor.logicielservice.com"  # v1.0 keeps running here

APP_NAME="cloudwatch-v2"
APP_DIR="/opt/bitnami/apps/$APP_NAME"
FLASK_DIR="/opt/bitnami/apps/aws-monitor"  # Existing Flask backend

NEXTJS_PORT=3001  # Different from Flask (5000)

echo -e "${BLUE}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   AWS CloudWatch Monitor v2.0 Deployment          ║${NC}"
echo -e "${BLUE}║   Next.js + Tremor on New Domain                   ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════╝${NC}"

if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Please run as root (use sudo)${NC}"
    exit 1
fi

echo -e "\n${YELLOW}Configuration:${NC}"
echo -e "  Old domain (v1.0): ${OLD_DOMAIN}"
echo -e "  New domain (v2.0): ${NEW_DOMAIN}"
echo -e "  v1.0 location:     ${FLASK_DIR}"
echo -e "  v2.0 location:     ${APP_DIR}"
echo -e "  Next.js port:      ${NEXTJS_PORT}"
echo -e "  Flask port:        5000 (shared backend)"

###############################################################################
# STEP 1: Install Node.js
###############################################################################
echo -e "\n${YELLOW}[1/8] Checking Node.js...${NC}"

if ! command -v node &> /dev/null; then
    echo -e "Installing Node.js 20..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
    echo -e "${GREEN}✓ Node.js installed ($(node -v))${NC}"
else
    echo -e "${GREEN}✓ Node.js already installed ($(node -v))${NC}"
fi

###############################################################################
# STEP 2: Create Application Directory
###############################################################################
echo -e "\n${YELLOW}[2/8] Creating application directory...${NC}"

# Stop old service if exists
sudo systemctl stop $APP_NAME 2>/dev/null || true

# Clean up old installation
sudo rm -rf $APP_DIR

# Create fresh directory
sudo mkdir -p $APP_DIR
cd $APP_DIR

echo -e "${GREEN}✓ Directory created at $APP_DIR${NC}"

###############################################################################
# STEP 3: Upload and Extract React App
###############################################################################
echo -e "\n${YELLOW}[3/8] Waiting for application files...${NC}"
echo -e "${BLUE}Upload cloudwatch-v2.tar.gz to /home/bitnami/${NC}"
echo -e "${BLUE}From your local machine run:${NC}"
echo -e "${GREEN}  scp cloudwatch-v2.tar.gz bitnami@YOUR_IP:/home/bitnami/${NC}"

read -p "Press Enter when file is uploaded..."

if [ -f "/home/bitnami/cloudwatch-v2.tar.gz" ]; then
    echo -e "Extracting application..."
    sudo tar -xzf /home/bitnami/cloudwatch-v2.tar.gz -C $APP_DIR --strip-components=1
    echo -e "${GREEN}✓ Files extracted${NC}"
else
    echo -e "${RED}ERROR: cloudwatch-v2.tar.gz not found in /home/bitnami/${NC}"
    exit 1
fi

###############################################################################
# STEP 4: Configure Environment
###############################################################################
echo -e "\n${YELLOW}[4/8] Configuring environment...${NC}"

# Create .env.local for Next.js
sudo tee $APP_DIR/.env.local > /dev/null <<ENVEOF
# API calls will go through Nginx proxy to Flask backend
NEXT_PUBLIC_API_URL=
ENVEOF

sudo chown -R bitnami:bitnami $APP_DIR

echo -e "${GREEN}✓ Environment configured${NC}"

###############################################################################
# STEP 5: Install Dependencies and Build
###############################################################################
echo -e "\n${YELLOW}[5/8] Installing dependencies...${NC}"

cd $APP_DIR
sudo -u bitnami npm install

echo -e "${GREEN}✓ Dependencies installed${NC}"

echo -e "\n${YELLOW}Building Next.js application...${NC}"
sudo -u bitnami npm run build

echo -e "${GREEN}✓ Build complete${NC}"

###############################################################################
# STEP 6: Create Systemd Service
###############################################################################
echo -e "\n${YELLOW}[6/8] Creating systemd service...${NC}"

NPM_PATH=$(which npm)

sudo tee /etc/systemd/system/$APP_NAME.service > /dev/null <<SERVICEEOF
[Unit]
Description=AWS CloudWatch Monitor v2.0 (Next.js + Tremor)
After=network.target aws-monitor.service

[Service]
Type=simple
User=bitnami
Group=bitnami
WorkingDirectory=$APP_DIR
Environment="NODE_ENV=production"
Environment="PORT=$NEXTJS_PORT"
ExecStart=$NPM_PATH start
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICEEOF

sudo systemctl daemon-reload
sudo systemctl enable $APP_NAME

echo -e "${GREEN}✓ Systemd service created${NC}"

###############################################################################
# STEP 7: Configure Nginx for New Domain
###############################################################################
echo -e "\n${YELLOW}[7/8] Configuring Nginx for new domain...${NC}"

# Backup existing config
sudo cp /opt/bitnami/nginx/conf/nginx.conf \
    /opt/bitnami/nginx/conf/nginx.conf.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true

# Create server block for v2.0
sudo tee /opt/bitnami/nginx/conf/server_blocks/$APP_NAME.conf > /dev/null <<NGINXEOF
# Redirect HTTP to HTTPS
server {
    listen 80;
    server_name $NEW_DOMAIN;
    return 301 https://\$host\$request_uri;
}

# v2.0 HTTPS Server
server {
    listen 443 ssl http2;
    server_name $NEW_DOMAIN;
    
    # SSL Certificate (will use same as v1.0 for now)
    ssl_certificate /opt/bitnami/nginx/conf/bitnami/certs/server.crt;
    ssl_certificate_key /opt/bitnami/nginx/conf/bitnami/certs/server.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    
    # Security Headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Strict-Transport-Security "max-age=31536000" always;
    
    # Logs
    access_log /opt/bitnami/nginx/logs/${APP_NAME}_access.log;
    error_log /opt/bitnami/nginx/logs/${APP_NAME}_error.log;
    
    # Next.js App (Frontend)
    location / {
        proxy_pass http://127.0.0.1:$NEXTJS_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 60s;
    }
    
    # API calls go to Flask backend (port 5000)
    location /api/ {
        proxy_pass http://127.0.0.1:5000/api/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_read_timeout 60s;
    }
    
    # Health check
    location /health {
        proxy_pass http://127.0.0.1:5000/health;
    }
}
NGINXEOF

# Test nginx configuration
echo -e "Testing Nginx configuration..."
sudo /opt/bitnami/nginx/sbin/nginx -t

if [ $? -ne 0 ]; then
    echo -e "${RED}Nginx configuration test failed${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Nginx configured for $NEW_DOMAIN${NC}"

###############################################################################
# STEP 8: Start Services
###############################################################################
echo -e "\n${YELLOW}[8/8] Starting services...${NC}"

# Ensure Flask backend is running (shared by both v1.0 and v2.0)
if ! sudo systemctl is-active --quiet aws-monitor; then
    echo -e "Starting Flask backend..."
    sudo systemctl start aws-monitor
    sleep 2
fi

if sudo systemctl is-active --quiet aws-monitor; then
    echo -e "${GREEN}✓ Flask backend running (port 5000)${NC}"
else
    echo -e "${RED}✗ Flask backend failed to start${NC}"
    sudo journalctl -u aws-monitor -n 20
    exit 1
fi

# Start Next.js v2.0
echo -e "Starting Next.js v2.0..."
sudo systemctl start $APP_NAME
sleep 3

if sudo systemctl is-active --quiet $APP_NAME; then
    echo -e "${GREEN}✓ Next.js v2.0 running (port $NEXTJS_PORT)${NC}"
else
    echo -e "${RED}✗ Next.js failed to start${NC}"
    sudo journalctl -u $APP_NAME -n 20
    exit 1
fi

# Restart Nginx
echo -e "Restarting Nginx..."
sudo /opt/bitnami/ctlscript.sh restart nginx
sleep 2

if sudo fuser 443/tcp 2>/dev/null; then
    echo -e "${GREEN}✓ Nginx running on port 443${NC}"
else
    echo -e "${RED}✗ Nginx failed to start${NC}"
    exit 1
fi

###############################################################################
# DEPLOYMENT COMPLETE
###############################################################################
echo -e "\n${BLUE}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║          DEPLOYMENT SUCCESSFUL!                    ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════╝${NC}"

echo -e "\n${GREEN}✓ AWS CloudWatch Monitor v2.0 is live!${NC}\n"

echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}DEPLOYMENT SUMMARY${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"

echo -e "\n${BLUE}URLs:${NC}"
echo -e "  v1.0 (HTML):      ${GREEN}https://$OLD_DOMAIN${NC}"
echo -e "  v2.0 (React):     ${GREEN}https://$NEW_DOMAIN${NC}"

echo -e "\n${BLUE}Services:${NC}"
echo -e "  Flask Backend:    Port 5000 (shared by both versions)"
echo -e "  v2.0 Next.js:     Port $NEXTJS_PORT"

echo -e "\n${BLUE}Service Status:${NC}"
sudo systemctl status aws-monitor --no-pager --lines=2
sudo systemctl status $APP_NAME --no-pager --lines=2

echo -e "\n${BLUE}Ports:${NC}"
sudo ss -tulpn | grep -E "443|5000|$NEXTJS_PORT" | grep LISTEN

echo -e "\n${YELLOW}═══════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}NEXT STEPS${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"

echo -e "\n${BLUE}1. Configure DNS:${NC}"
echo -e "   Add A record: ${GREEN}cwmonitorv2.logiciel-services.com → YOUR_STATIC_IP${NC}"
echo -e "   Wait for propagation (check: ${GREEN}dig $NEW_DOMAIN${NC})"

echo -e "\n${BLUE}2. Setup SSL Certificate:${NC}"
echo -e "   ${GREEN}sudo /opt/bitnami/bncert-tool${NC}"
echo -e "   Add domain: ${GREEN}$NEW_DOMAIN${NC}"
echo -e "   This will generate Let's Encrypt certificate"

echo -e "\n${BLUE}3. Test v2.0:${NC}"
echo -e "   Open: ${GREEN}https://$NEW_DOMAIN${NC}"
echo -e "   Check: Light/Dark theme toggle works"
echo -e "   Check: Search filters instances"
echo -e "   Check: Auto-scroll button works"

echo -e "\n${YELLOW}═══════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}USEFUL COMMANDS${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"

echo -e "\n${BLUE}View Logs:${NC}"
echo -e "  v2.0 Next.js: ${GREEN}sudo journalctl -u $APP_NAME -f${NC}"
echo -e "  Flask:        ${GREEN}sudo journalctl -u aws-monitor -f${NC}"
echo -e "  Nginx:        ${GREEN}sudo tail -f /opt/bitnami/nginx/logs/${APP_NAME}_error.log${NC}"

echo -e "\n${BLUE}Restart Services:${NC}"
echo -e "  v2.0:         ${GREEN}sudo systemctl restart $APP_NAME${NC}"
echo -e "  Flask:        ${GREEN}sudo systemctl restart aws-monitor${NC}"
echo -e "  Nginx:        ${GREEN}sudo /opt/bitnami/ctlscript.sh restart nginx${NC}"

echo -e "\n${BLUE}Check Status:${NC}"
echo -e "  v2.0:         ${GREEN}sudo systemctl status $APP_NAME${NC}"
echo -e "  Ports:        ${GREEN}sudo ss -tulpn | grep -E '443|5000|$NEXTJS_PORT'${NC}"

echo -e "\n${BLUE}Troubleshooting:${NC}"
echo -e "  Test Next.js: ${GREEN}curl http://localhost:$NEXTJS_PORT${NC}"
echo -e "  Test Flask:   ${GREEN}curl http://localhost:5000/health${NC}"
echo -e "  Test Nginx:   ${GREEN}curl -I https://$NEW_DOMAIN${NC}"

echo -e "\n${YELLOW}═══════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}DNS CONFIGURATION REQUIRED${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"

echo -e "\n${BLUE}Add this DNS record at your provider:${NC}"
echo -e "  Type:  ${GREEN}A${NC}"
echo -e "  Name:  ${GREEN}cwmonitorv2${NC}"
echo -e "  Value: ${GREEN}YOUR_LIGHTSAIL_STATIC_IP${NC}"
echo -e "  TTL:   ${GREEN}300${NC}"

echo -e "\n${BLUE}Then setup SSL:${NC}"
echo -e "  ${GREEN}sudo /opt/bitnami/bncert-tool${NC}"
echo -e "  Enter domains: ${GREEN}$NEW_DOMAIN${NC}"

echo -e "\n${GREEN}Deployment script completed!${NC}\n"

exit 0
