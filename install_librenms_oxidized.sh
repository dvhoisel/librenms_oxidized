#!/bin/bash
# by Daniel Hoisel daniel@hoisel.com.br 15/03/2024 v0.3
echo "Rodar esse script como root. Cuidado com o preenchimento, pois não há validação de campos."
echo "A instalação do LibreNMS por esse script não exige interação pela web."
echo "Configuração inicial do LibreNMS..."
read -p "1. String da comunidade SNMP: " snmp_community
read -s -p "2. Senha do usuário do banco de dados 'librenms': " dbpass
echo
read -p "3. FQDN ou endereço IP do seu servidor LibreNMS: " serverip
read -p "4. Fuso horário preferencial (exemplo: America/Bahia): " usertimezone
read -p "5. Usuário administrativo do LibreNMS: " adminuser
read -p "6. E-mail do usuário administrativo: " adminmail
read -s -p "7. Senha do usuário administrativo: " adminpass
echo
read -s -p "8. Senha do usuário do Oxidized (não pode ser numérica): " oxidizedpass
echo
dbname="librenms"
dbuser="librenms"
apt update
apt dist-upgrade -y
apt install -y acl curl fping git graphviz imagemagick mariadb-client mariadb-server mtr-tiny nginx-full nmap php8.4-cli php8.4-curl php8.4-fpm php8.4-gd php8.4-gmp php8.4-mbstring php8.4-mysql php8.4-snmp php8.4-xml php8.4-zip \
rrdtool snmp snmpd unzip python3-pymysql python3-dotenv python3-redis python3-setuptools python3-systemd python3-pip whois traceroute apt-transport-https lsb-release ca-certificates syslog-ng monitoring-plugins ruby ruby-dev \
libsqlite3-dev libssl-dev pkg-config cmake libssh2-1-dev libicu-dev zlib1g-dev g++ libyaml-dev libgit2-dev libzstd-dev
useradd librenms -d /opt/librenms -M -r -s "$(which bash)"
cd /opt
git clone https://github.com/librenms/librenms.git
chown -R librenms:librenms /opt/librenms
chmod 771 /opt/librenms
su - librenms -c 'cd /opt/librenms && ./scripts/composer_wrapper.php install --no-dev'
sed -i "s|;date.timezone =.*|date.timezone = $usertimezone|" /etc/php/8.4/fpm/php.ini
sed -i "s|;date.timezone =.*|date.timezone = $usertimezone|" /etc/php/8.4/cli/php.ini
timedatectl set-timezone "$usertimezone"
sed -i '/\[mysqld\]/a innodb_file_per_table=1\nlower_case_table_names=0' /etc/mysql/mariadb.conf.d/50-server.cnf
systemctl enable mariadb
systemctl restart mariadb
sleep 5
mysql -e "CREATE DATABASE $dbname;"
mysql -e "CREATE USER '$dbuser'@'localhost' IDENTIFIED BY '$dbpass';"
mysql -e "GRANT ALL PRIVILEGES ON $dbname.* TO '$dbuser'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"
cp /etc/php/8.4/fpm/pool.d/www.conf /etc/php/8.4/fpm/pool.d/librenms.conf
sed -i 's/\[www\]/\[librenms\]/' /etc/php/8.4/fpm/pool.d/librenms.conf
sed -i 's/^user = www-data/user = librenms/' /etc/php/8.4/fpm/pool.d/librenms.conf
sed -i 's/^group = www-data/group = librenms/' /etc/php/8.4/fpm/pool.d/librenms.conf
sed -i 's/^listen = \/run\/php\/php8.4-fpm.sock/listen = \/run\/php-fpm-librenms.sock/' /etc/php/8.4/fpm/pool.d/librenms.conf
systemctl restart php8.4-fpm
cat <<EOF > /etc/nginx/sites-enabled/librenms.vhost
server {
 listen      80;
 server_name $serverip;
 root        /opt/librenms/html;
 index       index.php;
 charset utf-8;
 gzip on;
 gzip_types text/css application/javascript text/javascript application/x-javascript image/svg+xml text/plain text/xsd text/xsl text/xml image/x-icon;
 location / {
  try_files \$uri \$uri/ /index.php?\$query_string;
 }
 location ~ [^/]\.php(/|$) {
  fastcgi_pass unix:/run/php-fpm-librenms.sock;
  fastcgi_split_path_info ^(.+\.php)(/.+)$;
  include fastcgi.conf;
 }
 location ~ /\.(?!well-known).* {
  deny all;
 }
}
EOF
rm /etc/nginx/sites-enabled/default
systemctl reload nginx
systemctl restart php8.4-fpm
ln -s /opt/librenms/lnms /usr/bin/lnms
cp /opt/librenms/misc/lnms-completion.bash /etc/bash_completion.d/
cp /opt/librenms/snmpd.conf.example /etc/snmp/snmpd.conf
sed -i "s/RANDOMSTRINGGOESHERE/$snmp_community/" /etc/snmp/snmpd.conf
curl -o /usr/bin/distro https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/distro
chmod +x /usr/bin/distro
systemctl enable snmpd
systemctl restart snmpd
cp /opt/librenms/dist/librenms.cron /etc/cron.d/librenms
cp /opt/librenms/dist/librenms-scheduler.service /opt/librenms/dist/librenms-scheduler.timer /etc/systemd/system/
systemctl enable librenms-scheduler.timer
systemctl start librenms-scheduler.timer
cp /opt/librenms/misc/librenms.logrotate /etc/logrotate.d/librenms
sed -i 's/^#DB_HOST=.*/DB_HOST=localhost/' /opt/librenms/.env
sed -i "s/^#DB_DATABASE=.*/DB_DATABASE=$dbname/" /opt/librenms/.env
sed -i "s/^#DB_USERNAME=.*/DB_USERNAME=$dbuser/" /opt/librenms/.env
sed -i "s/^#DB_PASSWORD=.*/DB_PASSWORD=$dbpass/" /opt/librenms/.env
sed -i "s|^#APP_URL=.*|APP_URL=http://$serverip|" /opt/librenms/.env
su - librenms -c './lnms migrate --force'
su - librenms -c './lnms db:seed --force'
su - librenms -c "./lnms user:add --role=admin --password='$adminpass' --email='$adminmail' $adminuser"
su - librenms -c "./lnms device:add $serverip --v2c -c $snmp_community"
sed -i 's/INSTALL=true/INSTALL=false/' /opt/librenms/.env
cp /opt/librenms/config.php.default /opt/librenms/config.php
sed -i '/\$config\['\''show_services'\''\]\s*=\s*1;/s/^#//' /opt/librenms/config.php
echo "\$config['nagios_plugins']   = \"/usr/lib/nagios/plugins\";" >> /opt/librenms/config.php
mysql -u $dbuser -p$dbpass -D $dbname -e "INSERT INTO users_widgets (user_id, widget, col, row, size_x, size_y, title, refresh, settings, dashboard_id) VALUES (1, 'availability-map', 1, 2, 6, 3, 'Availability Map', 60, '', 1);"
gem install oxidized
gem install oxidized-script oxidized-web
useradd -s /bin/bash -m oxidized
echo "oxidized:$oxidizedpass" | sudo chpasswd
su - oxidized -c 'oxidized'
su - librenms -c './lnms config:set oxidized.enabled true'
su - librenms -c "./lnms config:set oxidized.url http://127.0.0.1:8888"
su - librenms -c './lnms config:set oxidized.features.versioning true'
su - librenms -c './lnms config:set oxidized.group_support true'
su - librenms -c './lnms config:set oxidized.default_group default'
su - librenms -c './lnms config:set oxidized.ignore_groups "[\"badgroup\", \"nobackup\"]"'
su - librenms -c './lnms config:set oxidized.reload_nodes true'
su - librenms -c "./lnms config:set oxidized.ignore_types '[\"server\"]'"
TOKEN=$(openssl rand -hex 16)
mysql -u $dbuser -p$dbpass -D $dbname -e "INSERT INTO api_tokens (user_id, token_hash, description, disabled) VALUES (1, '$TOKEN', 'oxidized', 0);"
OXIDIZED_CONFIG="/home/oxidized/.config/oxidized/config"
cat << EOF > $OXIDIZED_CONFIG
---
username: oxidized
password: $oxidizedpass
resolve_dns: true
append_all_supported_algorithms: true
interval: 3600
use_syslog: true
debug: false
threads: 30
use_max_threads: false
timeout: 20
retries: 3
prompt: !ruby/regexp /^([\w.@-]+[#>]\s?)$/
rest: 127.0.0.1:8888
next_adds_job: false
vars: {}
groups: {}
group_map: {}
models: {}
pid: "/home/oxidized/.config/oxidized/pid"
crash:
  directory: "/home/oxidized/.config/oxidized/crashes"
  hostnames: false
stats:
  history_size: 10
input:
  default: ssh, telnet
  debug: false
  ssh:
    secure: false
  ftp:
    passive: true
  utf8_encoded: true
output:
  default: file
  file:
    directory: "/home/oxidized/.config/oxidized/configs"
source:
  default: http
  http:
    url: http://$serverip/api/v0/oxidized
    scheme: https
    secure: true
    map:
      name: hostname
      model: os
      group: group
    headers:
      X-Auth-Token: $TOKEN
model_map:
  airos-af: airos
  cisco: ios
  mikrotik: routeros
  juniper: junos
  hp: comware
  huawei: vrp
  olt_huawei: smartax
  linux: linuxgeneric
EOF
SERVICE_FILE="/etc/systemd/system/oxidized.service"
cat <<EOF | sudo tee $SERVICE_FILE > /dev/null
[Unit]
Description=Oxidized - Network Device Configuration Backup Tool
After=network-online.target multi-user.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/oxidized
User=oxidized
KillSignal=SIGKILL
#Environment="OXIDIZED_HOME=/etc/oxidized"
Restart=on-failure
RestartSec=300s

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable oxidized.service
systemctl start oxidized.service
echo "Instalação concluída!"
