# XC 开发路径规范

## 目的

统一源码、构建、产物、设备备份和部署临时文件的位置。所有自动化命令必须使用本文件定义的绝对路径或经过校验的脚本参数，不得依赖当前工作目录推断源码。

## 标准路径

| 用途 | 标准路径 |
| --- | --- |
| Windows 仓库 | `C:\Users\sdjam\Documents\设计xray切换插件（luci）` |
| Windows 实施工作树 | `C:\Users\sdjam\Documents\设计xray切换插件（luci）\.worktrees\implement-luci-app-xc` |
| WSL 实施工作树 | `/mnt/c/Users/sdjam/Documents/设计xray切换插件（luci）/.worktrees/implement-luci-app-xc` |
| OpenWrt buildroot | `/home/dean/immortalwrt-mt798x-6.6` |
| 固定构建源码副本 | `/home/dean/xc-build/luci-app-xc` |
| buildroot 包入口 | `/home/dean/immortalwrt-mt798x-6.6/package/luci-app-xc` |
| IPK 输出目录 | `/home/dean/immortalwrt-mt798x-6.6/bin/packages/aarch64_cortex-a53/base` |
| 设备上传目录 | `/tmp/xc-deploy` |
| 设备配置备份 | `/tmp/xc-backups/<版本>-<UTC时间>` |

`package/luci-app-xc` 只能链接到固定构建源码副本，不得链接到随机的 `/tmp/xc-*-build-src-*` 目录。

## 构建流程

1. 从 WSL 实施工作树同步到固定构建源码副本。同步命令必须写出完整源路径和完整目标路径，不得使用 `$PWD` 作为源路径。
2. 同步后检查固定副本中的 `Makefile` 版本号和关键源文件。
3. 确认 buildroot 包入口解析为 `/home/dean/xc-build/luci-app-xc`。
4. 使用 root 身份在 buildroot 中编译，明确启用主包和中文包。
5. 对两个 IPK 计算 SHA-256，并把待部署副本复制回实施工作树。

禁止把仓库的 `.git`、`.tools`、`docs`、`tests` 和既有 IPK 同步到固定构建源码副本。

## 设备部署流程

1. 在独立备份目录中复制 `/etc/config/xc`、`/etc/config/xc-opkg` 和 `/etc/config/xc-opkg.backup`。
2. 对原配置和备份副本计算 SHA-256，只有一致时才继续。
3. 将 IPK 上传到 `/tmp/xc-deploy`，安装前再次核对 SHA-256。
4. 安装后核对包版本、配置哈希、XC 状态、7890/10809 监听和 LuCI 缓存清理结果。
5. 验收完成后删除上传的 IPK；保留配置备份，直到下一个版本稳定运行。

## 安全约束

- 远程命令不得用未赋值变量、通配符或命令替换作为复制、权限修改或删除目标。
- `chmod`、`cp`、`mv` 和删除操作必须列出完整目标路径。
- 不得把密码、Token、节点凭据或设备配置写入仓库、构建日志和部署日志。
- 不得把 `/tmp` 随机目录、工作区根目录或 buildroot 根目录作为递归删除目标。
- 构建和部署失败时先检查实际路径与解析后的软链接，再重试命令。
