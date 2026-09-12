# rclone-onedrive-tray

[English](README.md) | **简体中文**

[![lint](https://github.com/Xcli0126/rclone-onedrive-tray/actions/workflows/lint.yml/badge.svg)](https://github.com/Xcli0126/rclone-onedrive-tray/actions/workflows/lint.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

一个仿 Windows OneDrive 客户端的 Linux 托盘图标，外加一套会自愈的同步循环，底层是 `rclone bisync`。

Linux 上没有官方 OneDrive 客户端。`rclone bisync` 能承担同步，但 rclone 给它标了 experimental，它没有界面，而且在 1.65 之前的版本里，一次中断就够它罢工。合上笔记本盖子，下一次同步会停在「Must run --resync to recover」，然后在你不手动敲那条命令之前一直停着。

这个项目把它包成接近 Windows 客户端的样子：托盘里一个图标，同步失败时弹一条通知，以及一套不用你管的恢复逻辑。

```
   托盘图标  ──────┐
                   ├──> onedrive-sync ──> rclone bisync ──> 你的云端
 systemd 定时器 ────┘         │
                              └── 重试 · 残留锁恢复 · 日志轮转
```

---

## 状态图标

| 图标 | 状态 | 含义 |
|---|---|---|
| ![synced](assets/icons/synced.png) | `synced` | 上一轮同步成功 |
| ![syncing](assets/icons/syncing.png) | `syncing` | 正在同步 |
| ![error](assets/icons/error.png) | `error` | 上一轮失败，提示里写了原因 |
| ![paused](assets/icons/paused.png) | `paused` | 自动同步已关闭 |
| ![unknown](assets/icons/unknown.png) | `unknown` | 还没有同步记录 |

---

## 它能做什么

托盘图标承载上面五种状态，点开是一个菜单：立即同步、打开同步目录、查看日志、暂停自动同步、开机自启、重建同步基线。同步失败时会弹通知，并附一句人能读懂的原因，例如「网络或 DNS 暂时不可用」或「本次待删除文件超过 100 个」。

菜单里还会显示账号已用空间，数据来自 `rclone about`，每 30 分钟在后台线程刷新一次，不会卡住界面。同步进行中时，状态行会显示实时进度：百分比、速率，以及当前正在传输的文件名。

本地一改就同步，不用等下一次定时。监听器盯着同步目录，改动停下来就立刻拉起一轮同步。实测新建一个文件，从落盘到云端确认收到用了 26 秒，其中大部分是去抖等待加一次完整的 bisync 扫描。**在另一台机器上做的改动仍然要等定时器**，因为 rclone 没有服务端推送，本地无从感知。

`rclone bisync` 留给使用者自己处理的部分，由同步包装器补上。

被中断的同步会自己恢复。包装器传了 `--recover` 和 `--resilient`，所以休眠或崩溃之后接着跑的是普通同步，而不是一条要你手动执行的命令。实测把同步在传输中途 `kill -9`，再跑一次，18 秒恢复完成。

残留的锁也会自己清掉。bisync 会在锁文件里写下持有它的进程号。休眠之后那个进程没了，文件还留着，bisync 就会拒绝运行直到锁过期。包装器先查这个进程号还在不在，不在就直接删锁。这一点值得做，因为 `--max-lock` 一旦设得宽松，一次崩溃就能换来一小时的停摆。

两个同步不可能撞在一起。包装器在整轮运行期间持有 `flock`，所以定时器正在跑时点「立即同步」只会排队等待。同一对文件上跑两个 bisync 进程，它们会互相删掉对方的清单文件，而恢复的代价是一次完整的 `--resync`。

删除有上限，每轮最多 `MAX_DELETE` 个文件。本地目录被清空时同步会中止，不至于一路传到云端。代价是如果你确实想批量删除，之后要跑一次 `onedrive-sync --resync`。

冲突时两份都留。一个文件两边都改过，rclone 会把两个版本都重命名保留，而不是替你选一个赢家，所以不会丢东西。代价是合并要你手动做。

日志到 5 MB 轮转，托盘只读它末尾 64 KB。每五分钟一次同步大约每天写 240 KB，对磁盘无所谓，但每三秒调一次 `readlines()` 再跑上一年就不是了。

进程模型保持很小：一个常驻监听器、一个 systemd 用户级 timer、一个 `oneshot` 同步服务。空闲时不持有你的文件、也不碰网络。所有配置集中在一个 shell 风格的配置文件里，脚本内没有硬编码路径。

---

## 环境要求

| 组件 | 说明 |
|---|---|
| 带 systemd（用户会话）的 Linux | 在 Ubuntu 24.04 和 26.04、GNOME Wayland 下测试 |
| [rclone](https://rclone.org/downloads/) 1.65 或更新 | `--recover`、`--resilient`、`--conflict-resolve` 需要它，发行版自带的往往偏旧 |
| `python3-gi`、GTK 3 | 托盘程序 |
| `gir1.2-ayatanaappindicator3-0.1` | 托盘图标。GNOME 下还需要 AppIndicator 扩展，Ubuntu 默认已装 |
| `libnotify` | 桌面通知 |
| `inotify-tools` | 实时同步。没装也能用，只是退回定时器节奏 |

Debian 或 Ubuntu：

```bash
sudo apt install rclone python3-gi gir1.2-ayatanaappindicator3-0.1 libnotify-bin inotify-tools
```

> 注意 rclone 版本。Ubuntu 源里的那个可能落后好几年，先用 `rclone version` 确认。低于 1.65 就去官网下新版本，把二进制放进 `/usr/local/bin`，它的优先级高于 `/usr/bin`。

---

## 安装

```bash
git clone https://github.com/Xcli0126/rclone-onedrive-tray.git
cd rclone-onedrive-tray
./install.sh
```

所有东西都装进你的家目录，安装器不会调用 `sudo`。

```
~/.local/bin/onedrive-sync, onedrive-tray
~/.config/rclone-onedrive-tray/config, filters.txt
~/.config/systemd/user/onedrive-sync.{service,timer}
~/.config/autostart/rclone-onedrive-tray.desktop
```

然后：

```bash
# 1. 确认 rclone 远程已存在并已授权
rclone config            # 创建/授权一个名为 onedrive 的远程
rclone lsd onedrive:     # 应该能列出你的文件

# 2. 建立一次同步基线，首次会把云端全部拉下来
onedrive-sync --resync

# 3. 托盘图标已在运行，以后每次登录也会自动启动
```

---

## 配置

配置文件在 `~/.config/rclone-onedrive-tray/config`，带注释的完整清单见
[`config/config.example`](config/config.example)。

```sh
REMOTE="onedrive:"            # rclone 远程，可带子路径："onedrive:Notes"
LOCAL="$HOME/OneDrive"        # 本地同步目录
INTERVAL_MIN="5"              # 自动同步间隔（分钟）
MAX_DELETE="100"              # 一轮删除超过这个数量就中止
BISYNC_ARGS="--resilient --recover --max-lock 2m --conflict-resolve none --conflict-loser num"
FILTERS_FILE="$HOME/.config/rclone-onedrive-tray/filters.txt"
OPEN_APP_CMD=""               # 可选：托盘菜单里能启动的应用，例如 "obsidian"
UI_LANG=""                    # 界面语言：en / zh，留空则跟随 $LANG
```

`~/.config/rclone-onedrive-tray/filters.txt` 放 [rclone 过滤规则](https://rclone.org/filtering/)，
一行一条。通常值得排除的是每台机器都会自己重建的缓存，以及各机器自己的界面状态。一个可用的
起点见 [`config/filters.example`](config/filters.example)：

```
- /.rag/**                          # 机器本地向量索引，可能几百 MB
- /.obsidian/workspace.json         # 编辑器布局，两台机器之间来回覆盖
- .DS_Store
- '**/__pycache__/**'
```

> 改动 `REMOTE`、`LOCAL`、`FILTERS_FILE` 或 `BISYNC_ARGS` 会让基线失效，之后跑一次
> `onedrive-sync --resync`。

---

## 使用

大多数时候你不需要管它。需要时点托盘图标：

```
上次同步 14:32
────────────────────────────────
Sync now
Open sync folder
View sync log
────────────────────────────────
☐ Pause automatic sync
☑ Start tray at login
────────────────────────────────
Rebuild sync baseline (resync)…
Quit
```

命令行：

```bash
onedrive-sync                 # 跑一次增量同步，最多 3 次尝试
onedrive-sync --resync        # 重建同步基线
systemctl --user list-timers onedrive-sync.timer
systemctl --user start onedrive-sync.service     # 立即同步
journalctl --user -u onedrive-sync.service -f
tail -f ~/.cache/rclone-onedrive-tray/sync.log
```

### 未登录时也同步

用户级服务随登录启动，所以停在登录界面的机器什么也不同步。想改：

```bash
sudo loginctl enable-linger "$USER"
```

---

## 设计说明

下面这些选择都是刻意的。每一条都在堵一个容易踩到、而且不好排查的故障。

定时器用 `OnUnitInactiveSec` 而不是 `OnUnitActiveSec`，它按「上一轮跑完之后固定间隔」排下一轮。
从启动时刻计时的话，一次慢同步就会和下一轮重叠，而重叠运行会破坏 bisync 的状态文件。

`TimeoutStartSec=1800` 是因为 systemd 对 `Type=oneshot` 的默认超时只有 90 秒。首次同步大目录远超
这个时间，会被从中间砍死。

`flock` 的存在是因为「定时同步正在跑时点立即同步」不是什么理论上的竞态。你第一次不耐烦就会碰上，
而这一对文件之后就只剩 `--resync` 一条路。

`--max-lock` 设短是一个取舍。两分钟意味着一次崩溃换来两分钟停摆，设长了则意味着同一次崩溃让同步
停掉近一小时。rclone 在同步真正运行期间会续租这个锁，所以设短不会危及长时间同步。

对 `oneshot` 服务，`systemctl is-active` 返回的是 `activating`，从来不是 `active`。一个判断
`== "active"` 的托盘永远看不到正在同步，也永远不会发出失败通知，而那恰恰是通知最该响的时刻。

---

## 已知限制

- `rclone bisync` 被 rclone 官方标记为 experimental。不可替代的东西请额外保有云端版本历史或另做备份。
- 冲突采用两份都留（`foo.txt` 变成 `foo.txt.conflict1` 和 `.conflict2`），不会丢数据，但要你手动合并。
- 同步一个正在被应用写入的目录可能产生冲突。排除易变的状态文件，也就是示例过滤规则的做法，能避免大部分。
- 托盘图标需要支持 AppIndicator 的桌面环境。原生 GNOME 需要 AppIndicator 扩展，KDE、Xfce、Cinnamon 开箱可用。
- 仅支持 Linux。

---

## 排障

微软废弃 `nativeclient` 重定向、`ObjectHandle is Invalid` 这个 drive-ID 陷阱、bisync 的锁与
resync 行为，以及为什么被打断的同步以前必须人工干预，都写在
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) 里。

---

## 卸载

```bash
./uninstall.sh            # 保留配置文件
./uninstall.sh --purge    # 配置文件一并删除
```

你的同步目录和 rclone 远程配置永远不会被碰。

---

## 更新记录

见 [CHANGELOG.md](CHANGELOG.md)。

## 许可证

[MIT](LICENSE)
