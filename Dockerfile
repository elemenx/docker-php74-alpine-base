# syntax=docker/dockerfile:1
#
# writing/php74-alpine-base, rebuilt with PHP 7.4.33 + the official PHP
# security-team backport for CVE-2026-109618 / CVE-2026-109619 ("PHP2Shell").
#
#   advisory : https://www.php.net/archive/2026.php#2026-10-21-5
#   branch   : https://github.com/php/php-src/tree/PHP-7.4-CVE-2026-109618-109619
#   commit   : https://github.com/php/php-src/commit/712e60f9edfd03f0960fc4fc3c2c375f42b90aa2
#
# Why Alpine 3.14 and not 3.24: see README.md. PHP 7.4 has no OpenSSL 3.x
# support, so it cannot be built against Alpine >= 3.16 (OpenSSL 3.x).
#
# Build:
#   docker buildx build --platform linux/amd64 \
#     -t writing/php74-alpine-base:7.4.33-cve-2026-109619 \
#     -f container/php74-base/Dockerfile container/php74-base
FROM php:7.4-cli-alpine3.14

ARG PHP_VERSION=7.4.33
ARG PHP_SHA256=924846abf93bc613815c55dd3f5809377813ac62a9ec4eb3778675b82a27b927
ARG PHP_URL="https://www.php.net/distributions/php-${PHP_VERSION}.tar.xz"

# Override for a faster/regional mirror, e.g.
#   --build-arg APK_MIRROR=https://mirrors.aliyun.com/alpine
ARG APK_MIRROR=https://dl-cdn.alpinelinux.org/alpine

COPY patches/php-7.4-CVE-2026-109618-109619.patch /tmp/php-cve.patch

# Rebuild the interpreter from source with the *same* configure flags as the
# official image, then apply the security backport. The base image already
# ships the docker-php-* helper scripts, php.ini and the www-data user.
RUN set -eux; \
    sed -i "s|https://dl-cdn.alpinelinux.org/alpine|${APK_MIRROR}|g" /etc/apk/repositories; \
    apk add --no-cache --virtual .php-build-deps \
        $PHPIZE_DEPS \
        argon2-dev \
        coreutils \
        curl-dev \
        gnu-libiconv-dev \
        libsodium-dev \
        libxml2-dev \
        linux-headers \
        oniguruma-dev \
        openssl-dev \
        patch \
        readline-dev \
        sqlite-dev \
    ; \
    # use GNU libiconv, exactly like the official php:7.4-alpine images
    rm -vf /usr/include/iconv.h; \
    ln -svf /usr/include/gnu-libiconv/*.h /usr/include/; \
    cd /usr/src; \
    curl -fsSL -o php.tar.xz "$PHP_URL"; \
    echo "$PHP_SHA256 *php.tar.xz" | sha256sum -c -; \
    mkdir -p php; \
    tar -xJf php.tar.xz -C php --strip-components=1; \
    cd php; \
    patch -p1 --dry-run < /tmp/php-cve.patch; \
    patch -p1 < /tmp/php-cve.patch; \
    gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
    ./configure \
        --build="$gnuArch" \
        --with-config-file-path="$PHP_INI_DIR" \
        --with-config-file-scan-dir="$PHP_INI_DIR/conf.d" \
        --enable-option-checking=fatal \
        --with-mhash \
        --with-pic \
        --enable-ftp \
        --enable-mbstring \
        --enable-mysqlnd \
        --with-password-argon2 \
        --with-sodium=shared \
        --with-pdo-sqlite=/usr \
        --with-sqlite3=/usr \
        --with-curl \
        --with-iconv=/usr \
        --with-openssl \
        --with-readline \
        --with-zlib \
        --enable-phpdbg \
        --enable-phpdbg-readline \
        --with-pear \
    ; \
    make -j"$(nproc)"; \
    find -type f -name '*.a' -delete; \
    make install; \
    find /usr/local -type f -perm '/0111' -exec sh -euxc 'strip --strip-all "$@" || :' -- '{}' +; \
    make clean; \
    cp -v php.ini-production "$PHP_INI_DIR/php.ini"; \
    php -v

# Production dependencies (kept identical to the original base image).
RUN apk add --no-cache \
    file \
    git \
    jpegoptim \
    pngquant \
    optipng \
    autoconf \
    automake \
    g++ \
    libtool \
    libzip \
    make \
    texinfo \
    gettext \
    supervisor \
    curl \
    tzdata \
    nano \
    icu-dev \
    freetype-dev \
    imagemagick-dev \
    imagemagick \
    mysql-client \
    nghttp2-libs

# Build-only headers for the extensions (the PHP build itself does not need
# them; freetype-dev / icu-dev / imagemagick-dev come with the production
# dependencies above).
RUN apk add --no-cache --virtual .ext-build-deps \
    bzip2-dev \
    libjpeg-turbo-dev \
    libpng-dev \
    libzip-dev \
    nghttp2-dev \
    zlib-dev

# Extensions from the original Dockerfile.
# "pdo" and "json" are compiled into PHP 7.4 already; installing them as
# shared modules only produces "Module already loaded" warnings, so they are
# intentionally left out. GD is configured exactly as before (no extra flags).
RUN set -eux; \
    docker-php-ext-configure opcache --enable-opcache; \
    docker-php-ext-configure gd; \
    docker-php-ext-install -j"$(nproc)" \
        opcache \
        mysqli \
        pdo_mysql \
        sockets \
        intl \
        gd \
        zip \
        bz2 \
        pcntl \
        bcmath

ENV SWOOLE_VERSION=4.8.1

RUN set -eux; \
    mkdir -p /usr/src/php/ext/swoole; \
    curl -fsSL "https://pecl.php.net/get/swoole-${SWOOLE_VERSION}.tgz" \
        | tar -xz -C /usr/src/php/ext/swoole --strip-components=1; \
    pkg-config --atleast-version=7.56.0 libcurl; \
    docker-php-ext-configure swoole --enable-openssl --enable-http2 --enable-swoole-curl; \
    docker-php-ext-install -j"$(nproc)" swoole; \
    php --ri swoole | grep -q 'curl-native'

# redis / imagick, pinned for reproducibility (both support PHP 7.4).
# Built from the PECL tarballs directly: the pecl client shipped in this
# 2022-era image fails against the current PECL channel with
# "No releases available for package pecl.php.net/redis".
RUN set -eux; \
    mkdir -p /usr/src/php/ext/redis /usr/src/php/ext/imagick; \
    curl -fsSL https://pecl.php.net/get/redis-6.0.2.tgz \
        | tar -xz -C /usr/src/php/ext/redis --strip-components=1; \
    curl -fsSL https://pecl.php.net/get/imagick-3.7.0.tgz \
        | tar -xz -C /usr/src/php/ext/imagick --strip-components=1; \
    docker-php-ext-install -j"$(nproc)" redis imagick

# Composer
RUN set -eux; \
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php; \
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer; \
    rm -f /tmp/composer-setup.php; \
    composer config -g repo.packagist composer https://mirrors.aliyun.com/composer/

ENV COMPOSER_ALLOW_SUPERUSER=1
ENV COMPOSER_MEMORY_LIMIT=-1
ENV PATH="./vendor/bin:$PATH"

# Keep the shared libraries the extensions link against, drop the build
# toolchain and the source tree, and set the timezone.
RUN set -eux; \
    apk add --no-cache --virtual .scan-deps pax-utils; \
    runDeps="$( \
        scanelf --needed --nobanner --format '%n#p' --recursive /usr/local \
            | tr ',' '\n' \
            | sort -u \
            | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )"; \
    apk add --no-cache $runDeps; \
    apk del --no-network .scan-deps .php-build-deps .ext-build-deps; \
    docker-php-source delete; \
    rm -f /tmp/php-cve.patch; \
    cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime; \
    echo 'Asia/Shanghai' > /etc/timezone

WORKDIR /var/www/html

CMD ["/usr/bin/supervisord"]
