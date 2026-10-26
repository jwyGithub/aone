# aone

AOne 零信任客户端的 Docker 封装：容器内运行 AOne 客户端建立隧道，通过 mihomo 将容器网络以 HTTP/SOCKS 代理端口暴露给外部，实现从任意设备访问 AOne 覆盖的内网服务。

## 实现了什么

- 自动化 AOne 客户端的初始化（`--config`）与登录（`--login`）：图形验证码经容器内 OCR（ddddocr）自动识别，短信验证码由自定义脚本获取后自动提交，全程无人值守
- 登录成功后守护 ctEAO 守护进程（隧道实际载体），每 60 秒通过 `AOne --status` 检测在线状态，掉线自动重登
- mihomo 以 DIRECT 出站方式对外暴露 mixed 代理端口，外部客户端经此端口即可访问隧道内网

```
外部客户端 ──► mihomo (mixed 端口) ──► 容器网络 ──► ctEAO/utun10 隧道 ──► 内网服务
```

## 如何运行

```bash
# 1. 准备配置
cp env.example .env && vi .env          # 填写运行时参数（见下）
cp sms/get_code.sh.example sms/get_code.sh   # 实现你的取码脚本并 chmod +x
vi mihomo/config.yaml                   # 按需调整代理端口

# 2. 构建并启动
docker compose up -d --build

# 3. 观察登录（出现"登录流程完成"即就绪）
docker compose logs -f aone
```

登录就绪后即可使用代理：

```bash
curl -x http://127.0.0.1:7890 https://目标服务/
```

## 运行时参数

环境变量（`.env`）：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `AONE_CORP` | 无（必填） | 企业标识 |
| `AONE_USER` | 无（必填） | 账号 |
| `AONE_PASS` | 无（必填） | 密码 |
| `SMS_SCRIPT` | 无（必填） | 验证码脚本容器内路径，支持 `.sh`/`.py`/`.js`，如 `/sms/get_code.sh` |
| `MIHOMO_PORT` | 7890 | 对外代理端口，需与 mihomo/config.yaml 一致 |

挂载：

| 宿主机路径 | 容器路径 | 用途 |
|---|---|---|
| `mihomo/` | `/etc/mihomo` | mihomo 配置 |
| `sms/` | `/sms` | 验证码脚本目录 |
| `aone-data` volume | `/root` | AOne 配置/登录态持久化 |

`SMS_SCRIPT` 契约：支持 `.sh` / `.py` / `.js`（按扩展名自动用 bash / python3 / node 调用，无需可执行权限）；第一个参数为过滤时间戳（毫秒，图形验证码提交时刻），用于忽略旧短信；**stdout 只输出验证码文本**（3-8 位字母数字），日志写 stderr；非 0 退出视为获取失败（自动指数退避重试，最多 10 次）。

镜像构建（`docker compose build`）时从远端下载 aone/mihomo 的 rpm，构建机需可访问对应链接；可用 `--build-arg AONE_RPM_URL=...` / `MIHOMO_RPM_URL=...` 覆盖版本。

## 常见问题排查

```bash
docker compose exec aone bash        # 进入容器
ip addr show utun10                  # 隧道设备应有 inet 地址
ip route | grep utun10               # 应有内网路由条目
tail /var/log/cteao.log              # ctEAO 日志
tail /var/log/mihomo.log             # mihomo 日志
```

- **隧道不通，cteao.log 刷 `exec: "route": not found`**：镜像缺 net-tools（已内置），确认镜像为最新构建
- **反复提示图形验证码错误**：OCR 偶发误识别，entrypoint 会自动重试，无需干预
- **`发送验证码服务调用失败: 验证码获取过于频繁`**：短时间内重试过多触发了服务端限频，等待几分钟后再观察
- **中文企业标识变成 `????`**：locale 问题，镜像已内置 C.UTF-8，确认未改坏 Dockerfile 的 ENV
- **重启容器后要求重新登录**：正常行为（会话不跨重启），会自动完成，消耗一条短信
- **mihomo 端口不通**：确认 `MIHOMO_PORT` 与 mihomo/config.yaml 的 `mixed-port` 一致，且 docker-compose.yml 的 ports 已映射
