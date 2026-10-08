#!/bin/bash

# Copyright (C) 2026 Oleh Mamont
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org>.

set -e

# === Конфигурация ===
WEB_DIR="/var/www/unbound"
DB_NAME="unbound"
DB_USER="dns_user"
# Генерируем безопасный буквенно-цифровой пароль (без слешей и кавычек)
DB_PASS=$(openssl rand -hex 8)
REPO_URL="https://github.com/kdrypr/Unbound-DNS-Server-Web-Interface.git"

echo "🔧 [1/8] Установка зависимостей..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y apache2 libapache2-mod-php php php-mysql php-mbstring php-xml mariadb-server unbound git rsyslog curl

echo "📥 [2/8] Клонирование репозитория..."
if [ -d "$WEB_DIR" ]; then
    rm -rf "$WEB_DIR"
fi
git clone "$REPO_URL" "$WEB_DIR"
chown -R www-data:www-data "$WEB_DIR"

echo "🗄️ [3/8] Настройка MariaDB и импорт схемы..."
systemctl start mariadb
systemctl enable mariadb

mysql -e "CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -e "DROP USER IF EXISTS '$DB_USER'@'localhost'; CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost'; FLUSH PRIVILEGES;"

mysql "$DB_NAME" <<'EOSQL'
CREATE TABLE IF NOT EXISTS users (
    id INT AUTO_INCREMENT PRIMARY KEY, username VARCHAR(100) NOT NULL, password VARCHAR(255) NOT NULL,
    role ENUM('admin','user') NOT NULL DEFAULT 'user', email VARCHAR(255) DEFAULT NULL,
    is_active TINYINT(1) NOT NULL DEFAULT 1, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS audit_logs (
    id INT AUTO_INCREMENT PRIMARY KEY, user_id INT NOT NULL, username VARCHAR(100) NOT NULL,
    action VARCHAR(50) NOT NULL, details TEXT, ip_address VARCHAR(45), created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_user_id (user_id), INDEX idx_action (action), INDEX idx_created_at (created_at)
);
CREATE TABLE IF NOT EXISTS login_attempts (
    id INT AUTO_INCREMENT PRIMARY KEY, ip_address VARCHAR(45) NOT NULL, username VARCHAR(100),
    attempted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, INDEX idx_ip_time (ip_address, attempted_at)
);
EOSQL

# Генерируем правильный bcrypt-хэш через PHP, чтобы он точно подошел к password_verify
ADMIN_HASH=$(php -r "echo password_hash('changeme', PASSWORD_BCRYPT, ['cost' => 12]);")
mysql "$DB_NAME" -e "DELETE FROM users WHERE username='admin'; INSERT INTO users (username, password, role) VALUES ('admin', '$ADMIN_HASH', 'admin');"

echo "⚙️ [4/8] Запись корректного конфига db.php..."
# Используем безопасные плейсхолдеры, чтобы bash не интерпретировал PHP-переменные
cat <<'EOF' > "$WEB_DIR/config/db.php"
<?php
declare(strict_types=1);
$dbhost = 'localhost';
$dbname = 'PLACEHOLDER_DBNAME';
$dbuser = 'PLACEHOLDER_DBUSER';
$dbpass = 'PLACEHOLDER_DBPASS';

try {
    $pdo = new PDO(
        "mysql:host={$dbhost};dbname={$dbname};charset=utf8mb4",
        $dbuser,
        $dbpass,
        [
            PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES   => false,
        ]
    );
} catch (PDOException $e) {
    error_log('Database connection failed: ' . $e->getMessage());
    http_response_code(500);
    exit('Database connection error.');
}
EOF

sed -i "s/PLACEHOLDER_DBNAME/$DB_NAME/g" "$WEB_DIR/config/db.php"
sed -i "s/PLACEHOLDER_DBUSER/$DB_USER/g" "$WEB_DIR/config/db.php"
sed -i "s/PLACEHOLDER_DBPASS/$DB_PASS/g" "$WEB_DIR/config/db.php"
chown www-data:www-data "$WEB_DIR/config/db.php"

echo "🔒 [5/8] Настройка Unbound DNS..."
touch /etc/unbound/host_entries.conf
chown root:www-data /etc/unbound/host_entries.conf
chmod 664 /etc/unbound/host_entries.conf

if ! grep -q "host_entries.conf" /etc/unbound/unbound.conf; then
    echo 'include: "/etc/unbound/host_entries.conf"' >> /etc/unbound/unbound.conf
fi

if ! grep -q "so-sndbuf" /etc/unbound/unbound.conf; then
    sed -i '/^server:/a\    so-sndbuf: 0\n    so-rcvbuf: 0' /etc/unbound/unbound.conf
fi

touch "$WEB_DIR/filehash.txt"
chown www-data:www-data "$WEB_DIR/filehash.txt"
chmod 664 "$WEB_DIR/filehash.txt"

echo "🛡️ [6/8] Настройка sudoers для веб-сервера..."
cat <<'EOSUDO' > /etc/sudoers.d/unbound-web
www-data ALL=(ALL) NOPASSWD: /usr/sbin/service unbound reload
www-data ALL=(ALL) NOPASSWD: /usr/sbin/service unbound restart
www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart rsyslog
www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl reload rsyslog
EOSUDO
chmod 440 /etc/sudoers.d/unbound-web

echo "🌐 [7/8] Настройка Apache VirtualHost..."
SERVER_IP=$(hostname -I | awk '{print $1}')
cat <<EOF > /etc/apache2/sites-available/unbound-web.conf
<VirtualHost *:80>
    ServerName $SERVER_IP
    DocumentRoot $WEB_DIR
    <Directory $WEB_DIR>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF

a2dissite 000-default.conf 2>/dev/null || true
a2ensite unbound-web.conf
a2enmod rewrite
systemctl restart apache2

echo "🔄 [8/8] Финальный запуск сервисов..."
systemctl enable unbound rsyslog
systemctl restart unbound
systemctl restart rsyslog

echo "========================================="
echo "✅ Установка успешно завершена!"
echo ""
echo "🌐 URL веб-интерфейса: http://$SERVER_IP"
echo "👤 Логин: admin"
echo "🔑 Пароль: changeme"
echo ""
echo "💾 Данные для подключения к БД (сохрани их):"
echo "   DB Name: $DB_NAME"
echo "   DB User: $DB_USER"
echo "   DB Pass: $DB_PASS"
echo "========================================="
