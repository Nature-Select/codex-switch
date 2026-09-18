# codex-switch

中文 | [English](#english)

`codex-switch` 是一个 macOS 命令行工具，用来在同一台 Mac 上管理多个 Codex / ChatGPT 账号，并在它们之间安全切换。

```console
$ codex-switch list --sort quota
 #     ACCOUNT               PLAN  WEEKLY  RESETS IN  RESET AT         CHECKED
 2     backup@example.com    pro     100%     6d 23h  Fri 09-25 14:21  13m ago
 1  ●  main@example.com      pro      64%     6d 21h  Fri 09-25 11:41  just now
 3     spare@example.com     pro       0%      1d 9h  Sun 09-20 00:34  2d 2h ago
```

## 中文

### 它解决什么问题

Codex 同一时间只认 `~/.codex/auth.json` 里的一个账号。手上有多个账号时，切换意味着手动备份、覆盖这个文件，很容易搞混甚至覆盖掉还在用的凭据。

`codex-switch` 把每个账号存在各自独立的 Codex home 里，切换时先把当前凭据归位、再原子地换入目标账号，并顺带告诉你每个账号还剩多少额度、什么时候重置。

它不做这些事：不会绕过 Codex 的任何限制；不会把你的凭据传到任何地方；除非你显式开启 `auto`，否则不会自己切换账号。

### 安装

```fish
brew tap nature-select/codex-switch https://github.com/Nature-Select/codex-switch
brew trust nature-select/codex-switch   # 新版 Homebrew 要求显式信任第三方 tap
brew install codex-switch
```

或者下载发布包（arm64 + x86_64 通用二进制）：

```fish
curl -fsSL https://github.com/Nature-Select/codex-switch/releases/latest/download/codex-switch-macos-universal.tar.gz | tar xz
sudo install -m 0755 codex-switch /usr/local/bin/
```

或者从源码构建（需要 macOS 13+ 与 Swift 5.9）：

```fish
git clone https://github.com/Nature-Select/codex-switch
cd codex-switch
bash scripts/install.sh                          # 装到 /usr/local/bin
env PREFIX=$HOME/.local bash scripts/install.sh  # 或装到自己的目录
```

### 命令

| 命令 | 作用 |
| --- | --- |
| `codex-switch status` | 当前用的是哪个账号、还剩多少、什么时候重置 |
| `codex-switch list` | 列出所有账号，`●` 标记当前账号 |
| `codex-switch use <账号>` | 切换当前账号 |
| `codex-switch add` | 登录一个新账号并保存 |
| `codex-switch adopt` | 把当前已登录的账号纳入管理 |
| `codex-switch auto` | 额度见底时自动切换（默认关闭） |
| `codex-switch refresh [账号]` | 重新读取额度 |
| `codex-switch reauth <账号>` | 登录被吊销后重新登录，保留原条目 |
| `codex-switch rename <账号> <名字>` | 改显示名 |
| `codex-switch forget <账号>` | 移除账号 |
| `codex-switch repair` | 认领磁盘上有凭据、但注册表里没记录的目录 |
| `codex-switch migrate` | 从旧的 `Codex Manager` 目录导入账号 |
| `codex-switch update` | 更新 codex-switch 自己 |
| `codex-switch paths` | 查看数据存放位置 |

`<账号>` 可以写列表序号、显示名、邮箱或 id，写唯一前缀即可：

```fish
codex-switch use 3
codex-switch use work@example.com
codex-switch use work
```

所有命令都支持 `--json`（机器可读）和 `--no-color`；`codex-switch help <命令>` 看详细参数。

### 日常用法

第一次用，先把手上已登录的账号纳入管理：

```fish
codex-switch adopt --label 主号
```

加一个新账号（走 Codex 设备码登录，验证码会自动复制到剪贴板并打开浏览器）：

```fish
codex-switch add --switch
```

日常切换：

```fish
codex-switch list --sort quota   # 额度最多的排前面
codex-switch list --sort reset   # 最快恢复的排前面
codex-switch use 2
```

序号是稳定引用：无论怎么排序，`use 2` 永远指向同一个账号。

### 登录失效了怎么办

普通的 token 过期不用管，Codex 会自己续。但如果服务端**吊销**了某个号的授权（登出、被踢等），刷新是救不回来的 —— `refresh` 会把它标成 `!`，`list` 底部会列出来，自动切换也会跳过它（避免切到一个看着还有额度、实际不能用的号）。

修复只能重新登录，用 `reauth` 而不是 `add`，这样原来的显示名、id、历史都保留：

```fish
codex-switch reauth hayseed          # 浏览器登录那个账号
```

如果登错了账号，工具会拒绝写入并告诉你实际登录的是谁 —— 想把那个新账号存下来用 `add`。

### 更新自己

```fish
codex-switch update --check   # 只看有没有新版本
codex-switch update           # 更新
```

brew 装的会走 `brew update && brew upgrade codex-switch`；直接下载安装的会拉最新 release、校验 sha256 后原地替换二进制（目录没权限时会提示用 sudo）。

### 自动切换

默认关闭。开启后，当前账号额度低于阈值时自动切到剩余最多的那个：

```fish
codex-switch auto enable                      # 低于 5%，每 5 分钟检查一次
codex-switch auto enable --threshold 10 --interval 600
codex-switch auto                             # 看状态
codex-switch auto disable                     # 关掉
```

`enable` 会装一个后台任务（launchd）替你定时检查，不需要挂着终端窗口；`disable` 会把它一并移除。每次切换都会记到 `~/Library/Logs/codex-switch/auto.log`。

判断额度用账号**最紧的那个窗口**（周窗口和 5 小时窗口取小），目标账号本身也必须高于阈值，否则宁可不动。

### 工作方式

每个账号存在各自独立的目录：

```
~/Library/Application Support/codex-switch/accounts/<account-id>/home/auth.json
```

Codex 实际读取的仍然是 `~/.codex/auth.json`。`codex-switch use` 会：

1. 先按凭据指纹判断当前 `~/.codex` 属于哪个账号，把它归位到自己的目录（保住期间刷新过的 token）
2. 再把目标账号的凭据原子写入 `~/.codex/auth.json`
3. 如果 ChatGPT 桌面端在跑，退出并重新拉起它，让它读到新账号

**关于桌面端**：它运行期间也持有 `~/.codex`，所以不重启它的话，它可能把旧账号写回去。默认重启就是这个原因，`--no-restart` 只适合桌面端没开的时候。退出走三级递进（AppleScript → SIGTERM → SIGKILL），所以它自带的"确认退出"弹窗不会卡住流程。

### 隐私与安全

- 凭据只保存在本机，不上传任何地方
- 注册表 `accounts.json` 只存非敏感元数据；账号 id 以 SHA-256 指纹存储，不存原值
- 所有目录 `0700`、凭据文件 `0600`，写入采用原子替换
- 注册表写入前会检查文件是否被其他进程改动，避免并发覆盖
- `forget` 默认会删掉该账号的本地凭据，想保留加 `--keep-credentials`
- 凭据只有这一份，建议定期备份：
  ```fish
  tar -czf ~/codex-switch-backup-(date +%Y%m%d).tar.gz -C ~/Library/"Application Support" codex-switch
  ```

### 环境变量

- `CODEX_HOME`：Codex 当前使用的目录，默认 `~/.codex`（与 Codex 本身一致）
- `CODEX_SWITCH_HOME`：本工具的数据目录，默认 `~/Library/Application Support/codex-switch`
- `NO_COLOR` / `CLICOLOR_FORCE`：强制关闭 / 强制开启颜色

### 开发

```fish
swift build
swift run CodexSwitchSelfTest
./.build/debug/codex-switch --help
```

推一个 `v*` tag 会自动跑测试、构建通用二进制、发布 Release 并更新 Homebrew formula。

### License

MIT

## English

`codex-switch` is a macOS CLI for keeping several Codex / ChatGPT accounts on one Mac and switching between them safely.

### Why

Codex reads exactly one account from `~/.codex/auth.json`. With more than one account, switching means copying that file around by hand — easy to get wrong, and easy to overwrite credentials that were still in use.

`codex-switch` parks every account in its own isolated Codex home, swaps the target in atomically, and shows how much quota each account has left and when it resets.

It does not bypass any Codex limit, never sends credentials anywhere, and never switches accounts on its own unless you enable `auto`.

### Install

```bash
brew tap nature-select/codex-switch https://github.com/Nature-Select/codex-switch
brew trust nature-select/codex-switch   # recent Homebrew requires trusting third-party taps
brew install codex-switch
```

Or grab the release tarball (universal arm64 + x86_64), or build from source with `bash scripts/install.sh`.

### Commands

| Command | What it does |
| --- | --- |
| `codex-switch status` | Which account is in use, what is left, when it resets |
| `codex-switch list` | List saved accounts; `●` marks the active one |
| `codex-switch use <account>` | Switch the account Codex uses |
| `codex-switch add` | Sign in to another account and save it |
| `codex-switch adopt` | Save the account you are already signed in as |
| `codex-switch auto` | Switch automatically when quota runs low (off by default) |
| `codex-switch refresh [account]` | Ask Codex for fresh quota numbers |
| `codex-switch reauth <account>` | Sign in again after a login was revoked |
| `codex-switch rename` / `forget` | Relabel or drop an account |
| `codex-switch repair` | Re-register account directories missing from the registry |
| `codex-switch migrate` | Import accounts from a `Codex Manager` directory |
| `codex-switch update` | Update codex-switch itself |
| `codex-switch paths` | Show where everything is stored |

Accounts are named by list number, label, email, or id prefix. Every command supports `--json` and `--no-color`; `codex-switch help <command>` has the details.

### Auto-switch

```bash
codex-switch auto enable --threshold 5 --interval 300
codex-switch auto            # status
codex-switch auto disable
```

`enable` installs a launchd job that does the checking, so nothing has to stay open in a terminal, and logs each switch to `~/Library/Logs/codex-switch/auto.log`. Quota is judged on the tightest window an account reports, and the target must itself be above the threshold.

### How it works

Accounts live in `~/Library/Application Support/codex-switch/accounts/<id>/home/`. A switch parks the credentials currently in `~/.codex` back with their owner (keeping any token refresh that happened meanwhile), writes the target's credentials in atomically, and restarts the ChatGPT desktop app if it is running — while running, that app owns `~/.codex` too, so skipping the restart lets it write the old account back.

### Privacy

Credentials never leave the Mac. The registry stores only non-sensitive metadata, with account ids kept as SHA-256 fingerprints. Directories are `0700`, credential files `0600`, and writes are atomic.

### Development

```bash
swift build
swift run CodexSwitchSelfTest
```

### License

MIT
