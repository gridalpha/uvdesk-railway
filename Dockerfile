# UVdesk Community Helpdesk, built for Railway.
#
# Upstream publishes no container image: uvdesk/community-skeleton ships a
# Dockerfile that installs Apache *and* a MySQL server into one Ubuntu box and
# ends on `CMD ["/bin/bash"]`. This image builds the same PHP application from
# an upstream release tarball, talks to an external MySQL, serves it on $PORT
# and installs itself unattended so the shipped /wizard never has to be reached.
FROM php:8.2-apache-bookworm

# The upstream git ref to build. Railway passes service variables to the build,
# so a deployer can move to a newer UVdesk release without touching this file.
ARG UVDESK_REF=v1.1.8

ENV UVDESK_HOME=/var/www/uvdesk \
    UVDESK_DATA=/data \
    APP_ENV=prod \
    APP_DEBUG=0 \
    UVDESK_DB_SERVER_VERSION=5.7 \
    UV_SESSION_COOKIE_LIFETIME=86400 \
    MAILER_DSN=null://null \
    MAILER_URL=null://localhost \
    UVDESK_MAILBOX_POLL_SECONDS=300 \
    UVDESK_ADMIN_NAME="Helpdesk Owner" \
    TRUSTED_PROXIES=0.0.0.0/0,::/0 \
    COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_MEMORY_LIMIT=-1

# ---------------------------------------------------------------------------
# System packages and PHP extensions.
# imap + mailparse + mysqli are the three the helpdesk's own requirement check
# insists on; intl/zip/gd are pulled in by Symfony and intervention/image.
# libc-client is only packaged as libc-client2007e-dev on Debian bookworm.
# ---------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        unzip \
        default-mysql-client \
        libc-client2007e-dev \
        libfreetype6-dev \
        libicu-dev \
        libjpeg62-turbo-dev \
        libkrb5-dev \
        libpng-dev \
        libssl-dev \
        libzip-dev; \
    docker-php-ext-configure imap --with-kerberos --with-imap-ssl; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j"$(nproc)" gd imap intl mysqli opcache pdo_mysql zip; \
    pecl install mailparse; \
    docker-php-ext-enable mailparse; \
    rm -rf /var/lib/apt/lists/*; \
    php -r 'foreach (["ctype","gd","iconv","imap","intl","mailparse","mysqli","Zend OPcache","pdo_mysql","zip"] as $e) { if (!extension_loaded($e)) { fwrite(STDERR, "missing php extension: $e\n"); exit(1); } } echo "php extensions ok\n";'

# Composer
RUN set -eux; \
    curl -fsSL -o /tmp/composer-setup.php https://getcomposer.org/installer; \
    expected="$(curl -fsSL https://composer.github.io/installer.sig)"; \
    actual="$(sha384sum /tmp/composer-setup.php | awk '{print $1}')"; \
    [ "$expected" = "$actual" ]; \
    php /tmp/composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer; \
    rm -f /tmp/composer-setup.php; \
    composer --version

# ---------------------------------------------------------------------------
# Application source
# ---------------------------------------------------------------------------
WORKDIR ${UVDESK_HOME}
RUN set -eux; \
    curl -fsSL "https://github.com/uvdesk/community-skeleton/archive/refs/tags/${UVDESK_REF}.tar.gz" -o /tmp/uvdesk.tar.gz \
      || curl -fsSL "https://github.com/uvdesk/community-skeleton/archive/${UVDESK_REF}.tar.gz" -o /tmp/uvdesk.tar.gz; \
    tar -xzf /tmp/uvdesk.tar.gz --strip-components=1 -C "${UVDESK_HOME}"; \
    rm -f /tmp/uvdesk.tar.gz; \
    test -f "${UVDESK_HOME}/composer.json"

COPY docker/ /opt/uvdesk-railway/

# ---------------------------------------------------------------------------
# Dependencies. --no-dev keeps the profiler, debug and maker bundles out of a
# public deployment; the fixtures bundle is a production requirement upstream,
# so it survives. Flex writes config/bundles.php during this step, which is why
# the patches below run after it and not before.
# ---------------------------------------------------------------------------
RUN set -eux; \
    cd "${UVDESK_HOME}"; \
    DATABASE_URL='' composer install --no-interaction --no-dev --prefer-dist --no-scripts

# Repo patches, each asserted so an upstream change fails the build rather than
# deploying a container that quietly lost the fix. See bin/patch-repo.php.
RUN php /opt/uvdesk-railway/bin/patch-repo.php

RUN set -eux; \
    cd "${UVDESK_HOME}"; \
    DATABASE_URL='' composer dump-autoload --optimize --no-dev; \
    DATABASE_URL='' php bin/console assets:install public --no-interaction; \
    test -d "${UVDESK_HOME}/public/bundles/uvdeskcoreframework"; \
    rm -rf "${UVDESK_HOME}/var/cache" "${UVDESK_HOME}/var/log"

# ---------------------------------------------------------------------------
# Apache + PHP configuration
# ---------------------------------------------------------------------------
RUN set -eux; \
    cp /opt/uvdesk-railway/php/uvdesk.ini "${PHP_INI_DIR}/conf.d/zz-uvdesk.ini"; \
    mkdir -p /var/www/health; \
    cp /opt/uvdesk-railway/health/healthz.php /var/www/health/healthz.php; \
    cp /opt/uvdesk-railway/apache/uvdesk.conf /etc/apache2/sites-available/000-default.conf; \
    a2enmod rewrite remoteip; \
    install -m 0755 /opt/uvdesk-railway/entrypoint.sh /usr/local/bin/uvdesk-entrypoint.sh; \
    install -m 0755 /opt/uvdesk-railway/mailbox-poll.sh /usr/local/bin/uvdesk-mailbox-poll.sh; \
    bash -n /usr/local/bin/uvdesk-entrypoint.sh; \
    bash -n /usr/local/bin/uvdesk-mailbox-poll.sh; \
    php -l /var/www/health/healthz.php; \
    for f in /opt/uvdesk-railway/bin/*.php; do php -l "$f"; done; \
    chown -R www-data:www-data "${UVDESK_HOME}"

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/uvdesk-entrypoint.sh"]
CMD ["apache2-foreground"]
