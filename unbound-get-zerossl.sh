# 1. Устанавливаем acme.sh и привязываем почту ZeroSSL
# (Замени your_email@example.com на свой email от аккаунта ZeroSSL)
curl https://get.acme.sh | sh -s email=your_email@example.com

# 2. Переключаем центр сертификации на ZeroSSL и регистрируем аккаунт
~/.acme.sh/acme.sh --set-default-ca --server zerossl
~/.acme.sh/acme.sh --register-account -m your_email@example.com

# 3. Выпускаем сертификат через webroot (бот создаст проверочный файл в /var/www/unbound)
DOMAIN="dns.example.com"
~/.acme.sh/acme.sh --issue -d $DOMAIN --webroot /var/www/unbound

# 4. Настраиваем автоматическую установку сертификатов и перезагрузку Apache при обновлениях
mkdir -p /etc/ssl/certs/unbound-web /etc/ssl/private/unbound-web
~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
--cert-file      /etc/ssl/certs/unbound-web/cert.pem  \
--key-file       /etc/ssl/private/unbound-web/key.pem  \
--fullchain-file /etc/ssl/certs/unbound-web/fullchain.pem \
--reloadcmd     "systemctl reload apache2"

# 5. Включаем SSL-модуль Apache
a2enmod ssl

# 6. Обновляем виртуальный хост: делаем жесткий редирект с 80 на 443 и подключаем сертификаты
cat <<EOF > /etc/apache2/sites-available/unbound-web.conf
<VirtualHost *:80>
    ServerName $DOMAIN
    Redirect permanent / https://$DOMAIN/
</VirtualHost>

<VirtualHost *:443>
    ServerName $DOMAIN
    DocumentRoot /var/www/unbound
    
    SSLEngine on
    SSLCertificateFile /etc/ssl/certs/unbound-web/cert.pem
    SSLCertificateKeyFile /etc/ssl/private/unbound-web/key.pem
    SSLCertificateChainFile /etc/ssl/certs/unbound-web/fullchain.pem
    
    <Directory /var/www/unbound>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF

# 7. Перезапускаем веб-сервер
systemctl restart apache2
