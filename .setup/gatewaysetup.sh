#########################################################################
#  Gateway setup script for RaspberryPi
#  LowPowerLab.com/gateway
#########################################################################
#!/bin/bash

RED='\033[1;31m'
GRN='\033[1;32m'
YLW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
APPSRVDIR=/home/${USER}/gateway/

CONFIG=/boot/config.txt
CMDLINE=/boot/cmdline.txt
USER=${SUDO_USER:-$(who -m | awk '{ print $1 }')}

echo -e "${GRN}#########################################################################${NC}"
echo -e "${GRN}#         Low Power Lab Gateway App Setup - Ubuntu Server x64           #${NC}"
echo -e "${GRN}#########################################################################${NC}"
echo -e "${YLW}Note: Recommended to use Pi 4${NC}"
echo -e "${YLW}Note: setup requires your input at certain steps${NC}"

if (whiptail --title "  Gateway User License Agreement  " --yesno "This software is licensed with CC-BY-NC-4.0 and requires a commercial license for any commercial or for-profit use.\n\nBy installing this software I certify that either:\n\n- I use this software for personal/non-profit purposes\n- I have obtained a commercial license already" 15 78) then
  echo -e "${GRN}#                 LICENSE confirmation applied.                         #${NC}"
else
  echo -e "${RED}#                 License required, exiting.                            #${NC}"
  exit 0
fi

# #update apt-get, distribution, kernel
echo -e "${CYAN}************* STEP: Running apt-get update *************${NC}"
sudo apt-get update -m
# echo -e "${CYAN}************* STEP: Upgrading distribution *************${NC}"
# sudo apt-get upgrade
# echo -e "${CYAN}************* STEP: Running dist-upgrade *************${NC}"
# sudo apt-get dist-upgrade

echo -e "${CYAN}************* STEP: Installing git & apache2-utils *************${NC}"
sudo apt-get -y install git apache2-utils

echo -e "${CYAN}************* STEP: Install latest NGINX *************${NC}"
sudo apt-get -y install nginx

echo -e "${CYAN}************* STEP: Install PHP7 *********************${NC}"
sudo apt-get -y install php-common php-cli php-fpm

echo -e "${CYAN}************* STEP: Install nodeJS & npm *************${NC}"
#install latest NodeJS --- https://www.raspberrypi.org/forums/viewtopic.php?t=141770
NODEYN=$(
whiptail --title "Install Node/NPM?" --menu "Pick version" 16 100 9 \
	"1)" "Install NodeJS/NPM" \
	"2)" "It is already installed" --nocancel 3>&2 2>&1 1>&3
)

if [ "$NODEYN" == "1)" ]; then
  echo -e "${RED}#          Installing Latest Node/NPM.              #${NC}"
  #could use git clone but that requires empty target directory which won't work if executed repeatedly
  sudo wget -O - https://raw.githubusercontent.com/audstanley/NodeJs-Raspberry-Pi/master/Install-Node.sh | sudo bash
  sudo npm install -g npm
else
  echo -e "${GRN}#          Make sure you already have Node/NPM installed.             #${NC}"
fi

echo -e "${CYAN}************* STEP: Setup Gateway app & dependencies *************${NC}"
sudo mkdir -p $APPSRVDIR    #main dir where gateway app lives
cd $APPSRVDIR || exit

#just for sanity
sudo rm -rf package-lock.json
sudo rm -rf node_modules

git init
git remote add origin https://github.com/bgoette/RaspberryPi-Gateway.git

echo -e "${RED}#    Installing LATEST GATEWAY CODE (HEAD).              #${NC}"
#could use git clone but that requires empty target directory which won't work if executed repeatedly
git pull origin master
rm -rf blueprints #remove irrelevant blueprints directory

sudo npm install --unsafe-perm --build-from-source
sudo npm cache verify    #clear any caches/incomplete installs
sudo mkdir $APPSRVDIR/logs -p

#create db and empty placeholders so chown pi will override root permissions
sudo mkdir $APPSRVDIR/data/db -p
touch $APPSRVDIR/data/db/gateway.db
touch $APPSRVDIR/data/db/gateway_nonmatches.db

#create uploads dir for user icons
sudo mkdir $APPSRVDIR/www/images/uploads -p
sudo chown -R www-data:$USER $APPSRVDIR/www/images/uploads

#create self signed certificate
#WARNING: must do this *AFTER* the gateway app was git-cloned
echo -e "${CYAN}************* STEP: Create self signed HTTPS certificate (10 year) *************${NC}"
HTTPSYN=$(
whiptail --title "Use HTTPS?" --menu "Make your choice" 16 100 9 \
	"1)" "Yes, use HTTPS" \
	"2)" "No thanks" --nocancel 3>&2 2>&1 1>&3
)

if [ "$HTTPSYN" == "1)" ]; then 
  echo -e "${CYAN}************* Creating SSL Keys *************${NC}"
  sudo mkdir $APPSRVDIR/data/secure -p
  sudo openssl req -new -x509 -nodes -days 3650 -newkey rsa:2048 -out $APPSRVDIR/data/secure/server.crt -keyout $APPSRVDIR/data/secure/server.key -subj "/C=US/ST=MI/L=Detroit/O=LowPowerLab/OU=IoT Department/CN=lowpowerlab.com"
  sudo chown -R $USER:$USER $APPSRVDIR

  echo -e "${CYAN}************* STEP: Create HTTP AUTH credentials *************${NC}"
  HTTPUSER=""
  HTTPPASS=""
  while [ -z ${HTTPUSER} ]; do
    HTTPUSER=$(whiptail --inputbox "\nLogin username (cannot be blank):" 8 78 "pi" --title "Gateway HTTP_AUTH Setup" --nocancel 3>&1 1>&2 2>&3)
  done
  while [ -z ${HTTPPASS} ]; do
    HTTPPASS=$(whiptail --passwordbox "\nLogin  password (default='raspberry', cannot be blank):" 10 78 "raspberry" --title "Gateway HTTP_AUTH Setup" --nocancel 3>&1 1>&2 2>&3)
  done
  touch $APPSRVDIR/data/secure/.htpasswd
  htpasswd -b $APPSRVDIR/data/secure/.htpasswd $HTTPUSER $HTTPPASS
  echo -e "${YLW}Done. You can add/change http_auth credentials using ${RED}htpasswd $APPSRVDIR/data/secure/.htpasswd user newpassword${NC}"

  echo -e "${CYAN}************* STEP: Copy gateway site config to sites-available *************${NC}"
  cp -rf $APPSRVDIR/.setup/gateway-secure /etc/nginx/sites-available/gateway
else 
  echo -e "${RED}************** Not using HTTPS ***************${NC}"

  echo -e "${CYAN}************* STEP: Copy gateway site config to sites-available *************${NC}"
  cp -rf $APPSRVDIR/.setup/gateway /etc/nginx/sites-available/gateway
fi

#determine php-fpm version and replace in gateway site config
phpfpmsock=$(grep -ri "listen = " /etc/php)  #search for file containing "listen =" in php path
phpfpmsock=${phpfpmsock##*/}                 #extract everything after last /
sudo sed -i "s/PHPFPMSOCK/${phpfpmsock}/g" /etc/nginx/sites-available/gateway  #replace PHPFPMSOCK with it in site config file
cd /etc/nginx/sites-enabled
sudo rm /etc/nginx/sites-enabled/default
sudo ln -s /etc/nginx/sites-available/gateway
sudo service nginx restart

#create simlinks to webserver logs for easy access
sudo ln -s -f /var/log/nginx/gateway.access.log $APPSRVDIR/logs/webserver.access.log
sudo ln -s -f /var/log/nginx/gateway.error.log $APPSRVDIR/logs/webserver.error.log

echo -e "${CYAN}************* STEP: Fail2Ban install *************${NC}"
if (whiptail --title "Fail2ban" --yesno "Do you want to install Fail2Ban?\nNote: Fail2Ban couples into the NGINX webserver to ban clients that make repeated failed attempts to authenticate to the Gateway App." 12 78) then
  sudo apt-get -y install fail2ban
  cp -n $APPSRVDIR/.setup/jail.local /etc/fail2ban/
  sudo service fail2ban restart
fi

echo -e "${CYAN}************* STEP: ATXRaspi/MightyHat shutdown script setup *************${NC}"
if (whiptail --title "ATXRaspi shutdown script" --yesno "Do you have a MightyHat or ATXRaspi installed on this Pi?\nNote: the script will start running only after a reboot so make sure to your ATXRaspi is wired before next boot otherwise leaving the feedback GPIO7 floating can cause unexpected reboots/shutdown!" 12 78) then
  sudo wget https://raw.githubusercontent.com/LowPowerLab/ATX-Raspi/master/shutdownchecksetup.sh
  sudo bash shutdownchecksetup.sh && sudo rm shutdownchecksetup.sh
fi

# Commented out for Ubuntu x64
#echo -e "${CYAN}************* STEP: Enable GPIO serial0, disable serial0 shell & Bluetooth *************${NC}"
#sudo raspi-config nonint do_serial 1            #disables console shell over GPIO serial
#set_config_var enable_uart 1 $CONFIG            #enables GPIO serial
#set_config_var dtoverlay pi3-disable-bt $CONFIG #disables bluetooth

echo -e "${CYAN}************* STEP: Configuring logrotate *************${NC}"
sudo echo "#this is used by logrotate and should be placed in /etc/logrotate.d/
#rotate the gateway logs and keep a limit of how many are archived
#note: archives are rotated in $APPSRVDIR/logs so that dir must exist prior to rotation
$APPSRVDIR/logs/*.log {
        size 20M
        missingok
        rotate 20
        dateext
        dateformat -%Y-%m-%d
        compress
        notifempty
        nocreate
        copytruncate
}" | sudo tee /etc/logrotate.d/gateway

echo -e "${CYAN}************* STEP: Setup Gateway service ... *************${NC}"
sudo cp $APPSRVDIR/.setup/gateway.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable gateway.service
sudo systemctl start gateway.service

echo -e "${CYAN}************* STEP: Proftpd install *************${NC}"
if (whiptail --title "Proftpd" --yesno "Do you want to install Proftpd?\nNote: Proftpd makes it easy to connect to the Pi via FTP." 12 78) then
  sudo apt-get -y install proftpd
fi

sudo apt-get clean
cd ~/

# Commented out for Ubuntu x64
#echo -e "${CYAN}************* STEP: Run raspi-config *************${NC}"
#if (whiptail --title "Run raspi-config ?" --yesno "Would you like to run raspi-config?\nNote: you should run this tool and configure the essential settings of your Pi if you haven't done it yet!" 12 78) then
  #sudo raspi-config
#fi

echo -e "${RED}Make sure: ${YLW}to edit your gateway settings from the UI or from settings.json5 (and restart to apply changes)${NC}"
echo -e "${RED}By default ${YLW}the gateway app uses the USB serial port (/dev/ttyUSB0)"
echo -e "${YLW}If you use regular Moteino or another GPIO serial port you must edit the serial port setting or the app will not receive messages from your Moteino nodes.${NC}"
echo -e "${RED}App restarts ${YLW}can be requested from the Gateway UI (power symbol button on settings page, or from the terminal via ${RED}sudo systemctl restart gateway.service${NC}"
echo -e "${YLW}You can change httpauth password using ${RED}htpasswd $APPSRVDIR/data/secure/.htpasswd user newpassword if you setup HTTPS${NC}"

# Commented out for Ubuntu x64 - Didn't change serial port settings
#if (whiptail --title "REBOOT ?" --yesno "All done, a REBOOT is required for the GPIO serial port to be ready.\n\nWould you like to REBOOT now?" 12 78) then
  #echo -e "${CYAN}************* ALL DONE - REBOOTING... *****************${NC}"
  #sudo reboot
#else
  #echo -e "${CYAN}************* ALL DONE - REBOOT REQUIRED! *************${NC}"
#fi

exit 0
