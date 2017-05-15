#!/bin/bash
(
# This script was created to automate the procedure of configuring Cachet on a CentOS 7 x64 minimal install
# Script created by Travis McDade on 11/20/2016
# Last updated on: 05/14/2017
# This script can be found at: https://github.com/thetechgy
# Prior to running this script, you should do the OS setup basics - set the IP info, hostname, join a domain, configure selinux, configure the firewall, etc as it applies to your circumstances
# Make sure you've made the script executable to run it by running chmod +x CachetSetup_CentOS7.sh
# Note that the Lets Encrypt verification process will require that you allow HTTP and HTTPS traffic to the VM. You also need a public DNS entry for the status page URL that points back to your public IP
# Usage: ./CachetSetup_CentOS7.sh

####PREP####
echo "Preparing to configure CentOS 7 for Cachet..."
echo "Checking to confirm you're running this script as the root user..."
if [ "$EUID" -ne 0 ]
  then echo "Please re-run this script logged-in as root - exiting..."
  exit 1
fi

####GET DESIRED URL####
read -p "Please enter the desired URL for your status page (ex. subdomain.domain.com): " cachet_url

####GET EMAIL ADDRESS####
read -p "Please enter the email address to use for Let's Encrypt: " email_address

####RUN UPDATES AND INSTALL PACKAGES####
echo "Installing required repositories and packages..."
yum update -y
yum install -y epel-release
rpm -ivh http://rpms.famillecollet.com/enterprise/remi-release-7.rpm
rpm --import http://rpms.famillecollet.com/RPM-GPG-KEY-remi
yum update -y
sed -i '/\[remi\]/,/^ *\[/ s/enabled=0/enabled=1/' /etc/yum.repos.d/remi.repo
sed -i '/\[remi-php56\]/,/^ *\[/ s/enabled=0/enabled=1/' /etc/yum.repos.d/remi.repo
yum update -y
yum install -y deltarpm php php-mysql php-mbstring php-gd php-cli php-process php-mcrypt php-common php-fpm php-xml php-opcache php-pecl-apcu php-pdo php-mysqlnd mariadb-server mariadb git curl nginx pwgen certbot

####DEFINE VARIABLES FOR LATER####
mariadb_root_password=$(pwgen -N 1 -s 96)
cachet_db_username=cachet
cachet_db_password=$(pwgen -N 1 -s 96)

####START SERVICES####
echo "Starting services and enabling them to start at boot..."
systemctl enable nginx.service; systemctl start nginx.service
systemctl enable php-fpm.service; systemctl start php-fpm.service
systemctl enable mariadb.service; systemctl start mariadb.service

####SECURE MARIADB INSTALL####
echo "Securing the MariaDB install..."
mysql --user=root <<EOF
UPDATE mysql.user SET Password=PASSWORD('${mariadb_root_password}') WHERE User='root';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

####CACHET INSTALL####
echo "Downloading and configuring Cachet..."
cd /var/www/ || exit
git clone https://github.com/cachethq/Cachet.git
cd Cachet/ || exit
latest_git_tag=$(git tag -l | tail -n 1)
git checkout "$latest_git_tag"
cp .env.example .env
sed -i -e "s/http:\/\/localhost/https:\/\/$cachet_url/g" .env
sed -i -e "s/DB_USERNAME=homestead/DB_USERNAME=$cachet_db_username/g" .env
sed -i -e "s/DB_PASSWORD=secret/DB_PASSWORD=$cachet_db_password/g" .env
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
php /usr/local/bin/composer install --no-dev -o
php artisan key:generate
mysql --user=root --password="$mariadb_root_password" <<EOF
CREATE DATABASE cachet;
CREATE USER '$cachet_db_username'@'localhost' IDENTIFIED BY '$cachet_db_password';
GRANT ALL PRIVILEGES ON cachet.* TO '$cachet_db_username'@'localhost' IDENTIFIED BY '$cachet_db_password';
FLUSH PRIVILEGES;
EOF
php artisan app:install
chmod -R 777 storage

####DISABLE DEFAULT NGINX SERVER BLOCK####
sed -i '38,57 s/^/#/' /etc/nginx/nginx.conf

####CERTIFICATE AND HTTPS NGINX CONFIGURATION####
echo "Generating the SSL certificate and enabling HTTPS access for Cachet..."
systemctl stop nginx
certbot certonly -n --agree-tos --email "$email_address" --standalone -d "$cachet_url"
ls -l /etc/letsencrypt/live/"$cachet_url"
openssl dhparam -out /etc/ssl/certs/dhparam.pem 2048
sed "s/\${cachet_url}/$cachet_url/g" << 'EOF' > /etc/nginx/conf.d/ssl.conf
server {
    listen 443 default;
    server_name ${cachet_url};

    ssl on;
    ssl_certificate     /etc/letsencrypt/live/${cachet_url}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${cachet_url}/privkey.pem;
    ssl_session_timeout 5m;

    ssl_ciphers               'AES128+EECDH:AES128+EDH:!aNULL';
    ssl_protocols              TLSv1 TLSv1.1 TLSv1.2;
    ssl_prefer_server_ciphers on;

    root /var/www/Cachet/public;

    index index.php;

    charset utf-8;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    access_log  /var/log/nginx/cachet.access.log;
    error_log   /var/log/nginx/cachet.error.log;

    sendfile off;

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
    }

    location ~ /\.ht {
        deny all;
    }
}

server {
    listen 80;
    server_name ${cachet_url};

    add_header Strict-Transport-Security max-age=2592000;
    rewrite ^ https://$server_name$request_uri? permanent;
}
EOF
nginx -t
systemctl restart nginx
systemctl restart php-fpm
echo "Setting the SSL Certificate to auto-renew every Monday at 2:30AM and reload NGINX at 2:35AM..."
crontab <<EOF
30 2 * * 1 /usr/bin/certbot renew >> /var/log/le-renew.log
35 2 * * 1 /usr/bin/systemctl reload nginx
EOF

####FIREWALL CONFIGURATION####
echo "Allowing HTTPS traffic through the firewall for the Public zone..."
firewall-cmd --permanent --zone=public --add-service=https
firewall-cmd --reload

####CLEANUP####
echo "Removing unnecessary packages..."
yum -y autoremove
echo "Cachet configuration completed!"

####SCRIPT FINISHED####
echo "SETUP COMPLETE!"
read -p "Press [ENTER] to reboot..."
) 2>&1 | tee CachetSetup_CentOS7Install.log
reboot
