# File Browser 一键安装脚本（Debian 13）

面向个人服务器的 File Browser 安装、升级与卸载脚本。

> [!IMPORTANT]
> File Browser 上游已经归档，最后计划发布版本为 `v2.63.23`，之后不会再提供 Bug 或安全修复。建议只在可信内网使用；如需公网访问，请在 HTTPS 反向代理和防火墙后运行。

## 支持范围

- Debian 13（Trixie）
- amd64
- arm64
- armhf（使用上游 armv7 二进制）
- riscv64
- systemd

上游没有为 Debian 13 的 ppc64el 和 s390x 提供二进制文件，因此脚本会明确拒绝安装，而不会下载错误架构。

## 默认设置

| 项目 | 默认值 |
| --- | --- |
| 访问端口 | `9184` |
| 监听地址 | `0.0.0.0` |
| 文件目录 | `/srv/filebrowser` |
| 数据库 | `/var/lib/filebrowser/filebrowser.db` |
| 程序 | `/usr/local/bin/filebrowser` |
| systemd 服务 | `filebrowser.service` |
| 运行用户 | `filebrowser`（非 root） |
| 上游版本 | `v2.63.23`（最后计划发布版本） |

## 一键下载安装

直接从本仓库下载并安装：

```bash
curl -fsSL https://raw.githubusercontent.com/brian952700/filebrowser/master/filebrowser.sh | sudo bash -s -- install
```

如果当前已经是 `root` 用户：

```bash
curl -fsSL https://raw.githubusercontent.com/brian952700/filebrowser/master/filebrowser.sh | bash -s -- install
```

该命令会立即执行远程脚本。希望先检查脚本内容时，请使用下面的分步安装方式。

## 下载后安装（便于先检查脚本）

```bash
curl -fsSL https://raw.githubusercontent.com/brian952700/filebrowser/master/filebrowser.sh -o filebrowser.sh
chmod +x filebrowser.sh
sudo ./filebrowser.sh install
```

也可以直接运行脚本并使用交互菜单：

```bash
sudo ./filebrowser.sh
```

安装完成后，查看首次启动生成的 `admin` 随机密码：

```bash
sudo journalctl -u filebrowser --no-pager | grep -i password
```

服务管理：

```bash
sudo systemctl status filebrowser
sudo systemctl restart filebrowser
sudo journalctl -u filebrowser -f
```

## 自定义目录或端口

在安装命令前设置环境变量：

```bash
sudo env \
  FILEBROWSER_ROOT=/mnt/storage \
  FILEBROWSER_ADDRESS=0.0.0.0 \
  FILEBROWSER_PORT=8080 \
  ./filebrowser.sh install
```

自定义文件目录必须使用绝对路径，并且路径中不能包含空格或特殊字符。

如果自定义目录已经存在，必须保证 `filebrowser` 用户能够读取；需要通过网页上传、删除或修改文件时，还必须拥有写权限。例如：

```bash
sudo chown -R filebrowser:filebrowser /mnt/storage
```

请确认该命令不会破坏其他服务依赖的文件所有权后再执行。

## 卸载

卸载程序和服务，保留数据库及个人文件：

```bash
sudo ./filebrowser.sh uninstall
```

同时删除数据库和服务账号，但仍保留个人文件目录：

```bash
sudo ./filebrowser.sh purge
```

脚本永远不会自动删除 `/srv/filebrowser` 或通过 `FILEBROWSER_ROOT` 指定的个人文件目录。

## 安全措施

- 自动选择与 Debian 架构匹配的官方二进制文件。
- 使用上游 SHA-256 清单验证下载文件。
- 保持 HTTPS 证书验证，不使用 `--no-check-certificate`。
- 以专用低权限账号运行服务。
- 使用 systemd 沙箱限制服务访问系统目录。
- 首次启动使用上游生成的随机管理员密码。
- 卸载时默认保留数据库和个人文件。

## 许可证

[MIT](LICENSE)
