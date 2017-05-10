#!/bin/sh
(
# This script was created to automate the procedure of configuring Cachet on a CentOS 7 x64 minimal install
# Script created by Travis McDade on 11/20/2016
# Last updated on: 12/4/2016
# Make sure you've made the script executable to run it chmod +x scriptname.sh
# Usage: ./scriptname.sh url
# Usage Examples:
#	http://subdomain.domain.com	Configures the URL for your Cachet instance and specifies HTTP
#	https://subdomain.domain.com	Configures the URL for your Cachet instance and specifies HTTPS

####PREP####
echo "Preparing to configure CentOS 7 for Cachet..."
echo "Checking to confirm you're running this script as the root user..."
if [ "$EUID" -ne 0 ]
  then echo "Please re-run this script logged-in as root - exiting..."
  exit 1
fi

####PARSE ARGUMENTS####
cachet_full_url=$1
connection_method=$(echo "$1" | awk -F '://' '{print $1}')
cachet_url=$(echo "$1" | awk -F '://' '{print $2}')
if [ -z "$1" ]
  then echo "Required argument not supplied - exiting..."
  exit 1
fi

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
yum install -y deltarpm php php-mysql php-mbstring php-gd php-cli php-process php-mcrypt php-mbstring php-common php-fpm php-xml php-opcache php-pecl-apcu php-pdo php-mysqlnd mariadb-server mariadb git curl nginx pwgen
if [ "$connection_method" = "https" ]; then
	yum install -y certbot
fi

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
sed -i -e "s/http:\/\/localhost/$connection_method:\/\/$cachet_url/g" .env
sed -i -e "s/DB_USERNAME=homestead/DB_USERNAME=$cachet_db_username/g" .env
sed -i -e "s/DB_PASSWORD=secret/DB_PASSWORD=$cachet_db_password/g" .env
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
#composer install --no-dev -o
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

####CERTIFICATE AND HTTPS NGINX CONFIGURATION####
if [ "$connection_method" = "https" ]; then
echo "Generating the SSL certificate and enabling HTTPS access for Cachet..."
cat <<EOF /etc/nginx/default.d/le-well-known.conf
location ~ /.well-known {
        allow all;
}
EOF
nginx -t
systemctl stop nginx
certbot certonly -a webroot --webroot-path=/var/www/Cachet/public -d "$cachet_url"
ls -l /etc/letsencrypt/live/"$cachet_url"
openssl dhparam -out /etc/ssl/certs/dhparam.pem 2048
cat <<EOF /etc/nginx/conf.d/ssl.conf
server {
        listen 443 ssl;

        server_name $cachet_url;

        ssl_certificate /etc/letsencrypt/live/$cachet_url/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/$cachet_url/privkey.pem;

        ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
        ssl_prefer_server_ciphers on;
        ssl_dhparam /etc/ssl/certs/dhparam.pem;
        ssl_ciphers 'ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-DSS-AES128-GCM-SHA256:kEDH+AESGCM:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-DSS-AES128-SHA256:DHE-RSA-AES256-SHA256:DHE-DSS-AES256-SHA:DHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA256:AES256-SHA256:AES128-SHA:AES256-SHA:AES:CAMELLIA:DES-CBC3-SHA:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK:!aECDH:!EDH-DSS-DES-CBC3-SHA:!EDH-RSA-DES-CBC3-SHA:!KRB5-DES-CBC3-SHA';
        ssl_session_timeout 1d;
        ssl_session_cache shared:SSL:50m;
        ssl_stapling on;
        ssl_stapling_verify on;
        add_header Strict-Transport-Security max-age=15768000;

        location ~ /.well-known {
                allow all;
        }

        # The rest of your server block
        root /var/www/Cachet/public;
        index index.php;

        location / {
                # First attempt to serve request as file, then
                # as directory, then fall back to displaying a 404.
                try_files $uri $uri/ =404;
                # Uncomment to enable naxsi on this location
                # include /etc/nginx/naxsi.rules
        }
}
EOF
cat <<EOF /etc/nginx/default.d/ssl-redirect.conf
return 301 https://$host$request_uri;
EOF
nginx -t
systemctl restart nginx
echo "Setting the SSL Certificate to auto-renew every Monday at 2:30AM and reload NGINX at 2:35AM..."
crontab <<EOF
30 2 * * 1 /usr/bin/certbot renew >> /var/log/le-renew.log
35 2 * * 1 /usr/bin/systemctl reload nginx
EOF
fi

####NGINX HTTP CONFIG####
if [ "$connection_method" != "https" ]; then
echo "Configuring NGINX..."
chown -R apache:apache /var/www/Cachet/
echo -e "server {
    listen 80;
    server_name ${cachet_url};

    root /var/www/Cachet/public;
    index index.php;

    location / {
        try_files \$uri /index.php\$is_args\$args;
    }

    location ~ \.php$ {
                include fastcgi_params;
                fastcgi_pass 127.0.0.1:9000;
                fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
                fastcgi_index index.php;
                fastcgi_keep_conn on;
    }
}" > /etc/nginx/conf.d/cachet.conf
systemctl restart nginx
systemctl restart php-fpm
fi

####FIREWALL CONFIGURATION####
if [ "$connection_method" = "https" ]; then
echo "Allowing HTTPS traffic through the firewall for the Public zone..."
firewall-cmd --permanent --zone=public --add-service=https
else
echo "Allowing HTTP traffic through the firewall for the Public zone..."
firewall-cmd --permanent --zone=public --add-service=http
fi
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
