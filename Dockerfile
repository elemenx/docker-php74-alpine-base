FROM php:7.4-cli-alpine3.12

RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

# Add Repositories
RUN rm -f /etc/apk/repositories &&\
    echo "http://dl-cdn.alpinelinux.org/alpine/v3.12/main" >> /etc/apk/repositories && \
    echo "http://dl-cdn.alpinelinux.org/alpine/v3.12/community" >> /etc/apk/repositories

# Add Build Dependencies
RUN apk add --no-cache --virtual .build-deps  \
    zlib-dev \
    libjpeg-turbo-dev \
    libpng-dev \
    libxml2-dev \
    bzip2-dev \
    libzip-dev

# Add Production Dependencies
RUN apk add --update --no-cache \
    git \
    jpegoptim \
    pngquant \
    optipng \
    autoconf \
    g++ \
    libtool \
    make \
    supervisor \
    curl \
    tzdata \
    nano \
    icu-dev \
    freetype-dev \
    mysql-client

# Configure & Install Extension
RUN docker-php-ext-configure \
    opcache --enable-opcache &&\
    docker-php-ext-configure gd &&\
    docker-php-ext-install \
    opcache \
    mysqli \
    pdo \
    pdo_mysql \
    sockets \
    json \
    intl \
    gd \
    zip \
    bz2 \
    pcntl \
    bcmath

ENV SWOOLE_VERSION=4.5.2

RUN pecl install swoole && docker-php-ext-enable swoole && \
    pecl install redis && docker-php-ext-enable redis

# Add Composer
RUN curl -s https://getcomposer.org/installer | php --install-dir=/usr/local/bin/ --filename=composer && \
    composer global require hirak/prestissimo && \
    composer config -g repo.packagist composer https://mirrors.aliyun.com/composer/

ENV COMPOSER_ALLOW_SUPERUSER=1
ENV PATH="./vendor/bin:$PATH"

# Remove Build Dependencies
RUN apk del -f .build-deps

# Setup Working Dir
WORKDIR /var/www/html

CMD ["/usr/bin/supervisord"]
