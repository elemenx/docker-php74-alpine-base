FROM alpine:3.11

# Install packages
RUN apk update && apk upgrade && \
    apk --no-cache add \
    git php7 php7-pdo php7-pdo_mysql php7-mysqli php7-json php7-openssl php7-curl \
    php7-zlib php7-xml php7-phar php7-dom php7-xmlreader php7-xmlwriter php7-ctype \
    php7-mbstring php7-gd php7-redis php7-opcache php7-fileinfo php7-simplexml php7-tokenizer supervisor curl tzdata && \
    apk --no-cache -X http://dl-cdn.alpinelinux.org/alpine/edge/testing add php7-pecl-swoole && \
    cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
    echo 'Asia/Shanghai' > /etc/timezone

ENV COMPOSER_ALLOW_SUPERUSER 1

RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer && \
    ln -s $(composer config --global home) /root/composer

ENV PATH=$PATH:/root/composer/vendor/bin COMPOSER_ALLOW_SUPERUSER=1

RUN composer global require hirak/prestissimo && \
    composer config -g repo.packagist composer https://mirrors.aliyun.com/composer/
