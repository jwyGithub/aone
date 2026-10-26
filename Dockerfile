FROM almalinux:9

# pip 镜像源：本地构建可用清华镜像，GitHub Actions 用官方源覆盖
ARG PIP_MIRROR=https://pypi.org/simple

# curl-minimal 已提供 curl 命令，勿装 curl（与 curl-minimal 冲突）
# glibc-langpack-zh 提供 UTF-8 locale，否则 expect 发送中文会变 ????
# net-tools 提供 route 命令，ctEAO 配置隧道路由依赖它
# tzdata + TZ 时区设为 UTC+8
# iptables: ctEAO 登录后创建 DNS 劫持 DNAT 规则(udp 53 -> 127.0.0.1:61119)必需，
# 缺失会导致内网域名解析到公网不可达入口
RUN dnf -y install expect iproute python3-pip glibc-langpack-zh net-tools tzdata iptables && \
    dnf clean all && \
    echo "export LANG=C.UTF-8" > /etc/profile.d/lang.sh
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 TZ=Asia/Shanghai
RUN ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
    echo "Asia/Shanghai" > /etc/timezone

# 安装两个本地 rpm。AOne 的 %pre/%post 脚本调用 systemctl（容器无 systemd）会失败，
# 用 --noscripts 跳过，再手动建 AOne 软链；mihomo 正常 dnf 安装。
# rpm 均从远端下载（构建机需可访问这两个链接）
ARG AONE_RPM_URL=https://soc-0trust.ctcdn.cn/client/20260313013812-AOne-1.6.0-Linux-X64-release-20260108204230.x86-64.rpm
ARG MIHOMO_RPM_URL=https://github.com/MetaCubeX/mihomo/releases/download/v1.19.32/mihomo-linux-amd64-v3-v1.19.32.rpm
RUN curl -fSL --connect-timeout 60 --retry 5 --retry-delay 3 -o /tmp/aone.rpm "$AONE_RPM_URL" && \
    curl -fSL --connect-timeout 60 --retry 5 --retry-delay 3 -o /tmp/mihomo.rpm "$MIHOMO_RPM_URL" && \
    dnf -y install libnfnetlink && \
    rpm -ivh --noscripts /tmp/aone.rpm && \
    dnf -y install /tmp/mihomo.rpm && \
    ln -sf /usr/local/aone/bin/AOne /usr/local/bin/AOne && \
    rm -f /tmp/aone.rpm /tmp/mihomo.rpm && \
    dnf clean all

# 最小 OCR（ddddocr，专为图形验证码训练的轻量模型）
RUN pip3 install --no-cache-dir -i ${PIP_MIRROR} ddddocr

# JS 运行时（支持 .js 版 SMS_SCRIPT）。关掉 weak deps 并不装 docs/i18n 以控制体积，
# Node 18+ 自带 fetch，简单取码脚本无需 npm 依赖
RUN dnf -y install --setopt=install_weak_deps=False nodejs npm && \
    dnf clean all

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY config.exp /usr/local/bin/config.exp
COPY login.exp /usr/local/bin/login.exp
COPY ocr.py /usr/local/bin/ocr.py
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/config.exp \
             /usr/local/bin/login.exp /usr/local/bin/ocr.py

WORKDIR /data/aone

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
