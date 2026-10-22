# elemenx/php74-alpine-base（PHP 7.4.33 + CVE-2026-109618/109619 补丁）

## 1. 这次修的是什么

2026-10-21 PHP 官方发布两个 **CVSS 9.2 的未授权 RCE**：

| CVE | GHSA | 说明 |
| --- | --- | --- |
| CVE-2026-109618 | GHSA-w8hw-w9fx-j79w | OOM 处理过程中打断 PHP，请求数据只初始化了一半，清理阶段把无效数据当成有效数据使用 |
| CVE-2026-109619 | GHSA-6wmf-4rv5-p3rp | 请求级全局状态在内存释放后仍然残留，同一 worker 的下一个请求可能用到脏状态 |

官方修复版本只有 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12。PHP 7.4 已 EOL，官方额外给出了
**最小化源码 backport 分支**：

- 公告：<https://www.php.net/archive/2026.php#2026-10-21-5>
- 7.4 分支：<https://github.com/php/php-src/tree/PHP-7.4-CVE-2026-109618-109619>
- 补丁提交：<https://github.com/php/php-src/commit/712e60f9edfd03f0960fc4fc3c2c375f42b90aa2>

本目录就是把该补丁打进 PHP 7.4.33，重建 `elemenx/php74-alpine-base`。

> 已在 Apple Silicon + Docker buildx（`--platform linux/amd64`）实测构建通过：
> `php -v` 为 PHP 7.4.33，`ini_get('max_multipart_body_parts')` 为 `"-1"`，
> Swoole 4.8.1、redis、imagick、gd、intl、zip 等模块均正常加载。

> 补丁基于 **7.4.33**（7.4 最后一个版本）的源码树。现有镜像里是 7.4.29，
> 所以下面直接从 7.4.33 源码重新编译，而不是在 7.4.29 上打补丁。

## 2. 关于 “把 Alpine 拉到 3.24”

**PHP 7.4 无法在 Alpine 3.24 上直接编译**，不是“多装几个包”的问题：

1. **OpenSSL 3.x**：PHP 7.4 的 `ext/openssl` 只支持到 OpenSSL 1.1.1（源码里没有
   OpenSSL 3 的兼容分支）。Alpine 3.16 起就是 OpenSSL 3.x，3.24 是 3.5，编译会失败。
   实测（`alpine:3.24` + `php-7.4.33`，已用 CFLAGS 压掉 GCC 14 的报错）：

   ```
   ext/openssl/openssl.c:1520:58: error: 'RSA_SSLV23_PADDING' undeclared
   make: *** [Makefile:491: ext/openssl/openssl.lo] Error 1
   ```

   而 PHP 的 openssl 扩展又是 composer / HTTPS 必需的。
2. **GCC 14/15**：Alpine 3.21+ 的 GCC 默认把 `implicit-function-declaration`、
   `implicit-int`、`incompatible-pointer-types` 当错误，PHP 7.4 源码会大量触发
   （必须额外加 `-Wno-error=...`）。
3. **libxml2 2.14 / ICU 76+**：PHP 7.4 的 `dom`、`intl` 等扩展还需要额外兼容补丁；
   Swoole 4.8.1 也没有在新工具链上验证过。

也就是说，3.24 + 7.4 需要自己再编译一份 OpenSSL 1.1.1w、改 PHP 的 OpenSSL 调用、
再给 GCC/libxml2 打补丁，属于“把 7.4 移植到新工具链”的工程，风险和维护成本都远高于
本次安全修复。

建议：

- **短期（本次）**：保持 Alpine 3.14（与现有基础镜像一致），只把 PHP 升到
  7.4.33 并打官方 backport。改动最小、可回滚。
- **中期**：把应用升到 PHP 8.2+（注意 Laravel / 依赖版本），再换
  `php:8.2-cli-alpine3.24` 或 `8.3`；那才是真正“Alpine 3.24”的路径。
- 如果一定要在 3.24 上跑，只能是 PHP 8.x，不能是 7.4。

## 3. 文件

```
container/php74-base/
├── Dockerfile
├── patches/
│   └── php-7.4-CVE-2026-109618-109619.patch   # 官方 7.4 backport（git diff）
└── README.md
```

Dockerfile 做的事：

1. `FROM php:7.4-cli-alpine3.14`（保留原来的 `docker-php-*` 脚本、php.ini、www-data）。
2. 用官方镜像完全相同的 `./configure` 参数，从 7.4.33 源码重编译，编译前 `patch -p1`。
3. 按原 Dockerfile 安装扩展、Swoole 4.8.1、redis、imagick、Composer。
4. 用 `scanelf` 找回扩展依赖的运行时 so，再删掉 `.php-build-deps` / `.ext-build-deps` 和源码。
5. 时区、`CMD ["/usr/bin/supervisord"]` 与原镜像一致。

和原 Dockerfile 的少量差异：

- 不再安装 `pdo`、`json` 两个扩展：它们在 PHP 7.4 里是内建的，按原样装成
  shared 只会得到 `Module 'pdo' already loaded` 警告。
- `redis`、`imagick` 固定了版本（6.0.2 / 3.7.0），并且直接用 PECL tarball 编译：
  这个 2022 年的镜像里自带的 `pecl` 客户端访问现在的 PECL channel 会报
  `No releases available for package "pecl.php.net/redis"`。
- 去掉了 `fswatch`（仅开发时监听文件用，生产镜像和 supervisord 都没用到；它需要
  从 GitHub clone + autotools，构建不稳定）。若确实需要，见文末。
- `APK_MIRROR` 可覆盖；国内构建建议用阿里云镜像（见下）。

## 4. 构建

在仓库根目录执行（**注意是 linux/amd64**，和线上一致）：

```bash
docker buildx build \
  --platform linux/amd64 \
  --build-arg APK_MIRROR=https://mirrors.aliyun.com/alpine \
  -t elemenx/php74-alpine-base:7.4.33-cve-2026-109619 \
  -f container/php74-base/Dockerfile \
  container/php74-base \
  --load
```

- `--load` 把镜像载入本机；要直接推仓库就把 `--load` 换成 `--push`（先 `docker login`）。
- 构建机是 amd64 时（比如 CI）可以去掉 `--platform`，速度快很多。
- 如果 GitHub / php.net 慢，可先把 `php-7.4.33.tar.xz` 放到构建上下文里改成 `COPY`；
  补丁已经在 `patches/` 里，不依赖 GitHub。

默认 `APK_MIRROR` 仍是官方 `https://dl-cdn.alpinelinux.org/alpine`；国内网络下
`dl-cdn` 很慢，建议显式传阿里云/清华镜像。

## 5. 验证

```bash
IMG=elemenx/php74-alpine-base:7.4.33-cve-2026-109619

# 1) 版本必须是 7.4.33
docker run --rm $IMG php -v

# 2) 补丁标记：这个 ini 项只有打了 backport 才有，值为 -1
docker run --rm $IMG php -r 'var_dump(PHP_VERSION, ini_get("max_multipart_body_parts"));'
# string(6) "7.4.33"
# string(2) "-1"

# 3) 扩展都在
docker run --rm $IMG php -m | grep -E 'opcache|swoole|redis|imagick|gd|intl|zip|bz2|bcmath|pdo_mysql|mysqli'

# 4) Swoole 的 curl-native 检查（原 Dockerfile 里也有这一步）
docker run --rm $IMG php --ri swoole | grep -E 'Version|curl-native|openssl'

# 5) Composer
docker run --rm $IMG composer --version
```

第 2 步是最直接的“补丁是否生效”检查；如果还是 7.4.29 或没有
`max_multipart_body_parts`，说明镜像没有重建成功。

## 6. 在应用镜像里使用

已把根目录 `Dockerfile` 改成可用 build-arg 指定基础镜像（默认仍是原来的
`:latest`，不破坏现有 CI）：

```dockerfile
ARG PHP_BASE_IMAGE=elemenx/php74-alpine-base:latest
FROM ${PHP_BASE_IMAGE}
```

构建时指定新 tag 即可：

```bash
docker build \
  --build-arg PHP_BASE_IMAGE=elemenx/php74-alpine-base:7.4.33-cve-2026-109619 \
  -t your-app:patched .
```

确认没问题后，也可以直接把新镜像 retag 成 `:latest` 推回仓库，应用侧就不用改：

```bash
docker tag elemenx/php74-alpine-base:7.4.33-cve-2026-109619 elemenx/php74-alpine-base:latest
docker push elemenx/php74-alpine-base:7.4.33-cve-2026-109619
docker push elemenx/php74-alpine-base:latest
```

`container/jiulong/Dockerfile`、`container/hz-bank/Dockerfile` 等使用
`elemenx/php74-alpine-base` 的，按同样方式换 tag（或 retag 后推 `elemenx` 命名空间）。

## 7. 临时缓解（不能替代升级）

如果新镜像上线前需要先降低风险（官方公告给出的措施，只降低特定攻击面）：

- `memory_limit=-1`（用 `php_admin_value` 等应用改不掉的方式设置）。
- `post_max_size=8M`（无上传）或 `32M`（有上传），`upload_max_filesize` 更小；
  在网关/代理层限制请求体、字段数、multipart part 数。
- `session.upload_progress.enabled=0`，并重启所有 worker。
- 用容器/cgroup 限制内存，只杀受影响 worker；不要用 `RLIMIT_AS`/`RLIMIT_DATA`。

## 8. 已知注意点

- 镜像里仍保留 `/usr/src/php.tar.xz`（**未打补丁的 7.4.33 源码**，`docker-php-source
  delete` 只删解压目录）。它只用于以后在派生镜像里 `docker-php-ext-install` 编译
  扩展；不要拿它重新 `make install`，否则会把补丁覆盖掉。
- Alpine 3.14 本身早已 EOL（openssl 1.1.1、musl 等都是旧版本）。本镜像只解决了
  PHP 的这两个 CVE，不代表基础系统是“安全版本”；长期还是要整体升级到受支持的
  Alpine + PHP 8.x。
- 如果你在派生镜像里还需要编译新扩展，把清理段的 `docker-php-source delete`
  去掉即可（代价是镜像大一点）。

## 9. 附：真要 fswatch

原镜像的 fswatch 只是开发辅助。需要的话在扩展安装之后加：

```dockerfile
RUN apk add --no-cache --virtual .fswatch-deps autoconf automake libtool make texinfo g++ \
 && git clone --depth 1 https://github.com/emcrisostomo/fswatch.git /tmp/fswatch \
 && cd /tmp/fswatch && ./autogen.sh && ./configure && make -j"$(nproc)" && make install \
 && cd / && rm -rf /tmp/fswatch \
 && apk del --no-network .fswatch-deps
```

国内构建建议把 GitHub 换成可达的镜像/代理，或者在 CI 里预下载源码。
