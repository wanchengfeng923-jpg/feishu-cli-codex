# Codex 接入飞书 CLI 全流程脚本

一个通用的 Windows PowerShell 安装/引导脚本：在任意一台新电脑上全自动安装飞书cli且接入codex，实现用codex操控飞书进行工作，**检测缺什么、逐步补齐**，装完马上可用
## 文件说明

| 文件 | 作用 |
|---|---|
| `setup-lark-cli.ps1` | 主脚本（全流程：预检 → 安装/更新 lark-cli → 应用配置 → 登录授权 → Codex 集成（skills/规则/PATH）→ 可用性验证 → cc-connect 远程接入 → 权限申请单） |
| `setup-lark-cli.exe` | 主脚本编译的单文件版（自包含，含模板/标签） |
| `permission-report-template.md` | 权限申请单的 Markdown 模板（中文，脚本自动填充） |
| `lark-domain-labels.json` | 权限域的中文名映射（可自行修改） |
| `README.md` | 本说明 |

## 一键 EXE 版（推荐）

`setup-lark-cli.exe` 是脚本编译后的单文件版本，**拷贝这一个文件到任何 Windows 电脑即可**，不需要旁边的模板/标签文件（已内嵌），也不受 PowerShell 执行策略限制。

**Node.js 也会自动安装**：首次运行时如果电脑没有 Node.js，脚本会自动处理——

- 优先用 `winget` 静默安装官方 Node.js LTS（Windows 10/11 自带；会弹一次 UAC 确认，点是即可）；
- 没有 winget 或安装失败时，自动下载官方便携版 Node.js 解压到 `%LOCALAPPDATA%\Programs\codex-node` 并加入用户 PATH（**免管理员权限**）；
- 装完自动继续安装 lark-cli，全程无需手动操作。不需要自动装 Node 时加 `-SkipNodeInstall`。

```powershell
# 双击运行，或命令行执行：
setup-lark-cli.exe                # 全流程安装
setup-lark-cli.exe -CheckOnly     # 只检测 + 生成权限申请单，不改动任何东西
setup-lark-cli.exe -AppId cli_xxx -AppSecret your_secret   # 非交互式配置已有应用
```

生成的文件（权限申请单、登录二维码）默认输出到 EXE 所在目录，可用 `-ReportDir <目录>` 指定。

> 说明：EXE 由 PowerShell 脚本编译生成（ps2exe）。个别杀毒软件/Windows SmartScreen 可能对"由脚本编译的 exe"有提示，属正常现象；遇到时选择"仍要运行"即可，或用下面的 `.ps1` 版本（两个版本行为完全一致）。

重新打包 EXE（修改脚本后）：

```powershell
Install-Module ps2exe -Scope CurrentUser   # 首次需要，另需 NuGet provider
ps2exe -inputFile setup-lark-cli.ps1 -outputFile setup-lark-cli.exe `
       -title "Codex Feishu CLI Setup" -version "1.0.0.0"
```

## cc-connect 远程接入（默认开启）

脚本默认会在最后自动安装并配置 **cc-connect**（飞书聊天 → 本机 Codex CLI 的桥），装完即可在飞书里直接给机器人发任务：

- 安装 cc-connect 与官方 Codex CLI（npm 全局，`codex --version` 可验证）；
- **复用同一个飞书应用**写 `~/.cc-connect/config.toml`——不产生新的权限申请，沿用同一份一次性权限申请单；
- 默认开启**卡片进度**（`enable_feishu_card = true`、`progress_style = "card"`）：任务进度显示为一张自动更新的卡片，不刷屏；聊天内隐藏「工具 #N: Bash …」过程行（`[display] tool_messages = false`）；
- 自动在工作目录写入 `AGENTS.md`，告诉 Codex 会话「lark-cli 已安装、沙箱文件视图不可靠」，避免误报“lark-cli 未安装”；
- 安装 Windows 后台服务（计划任务），并自动转为**非交互会话（S4U）**：桌面不会弹出控制台窗口，开机/登录自启；
- 默认工作目录为 `%USERPROFILE%\CodexWorkspace`（可随时在飞书里用 `/dir` 切换）。

相关参数：

```powershell
setup-lark-cli.exe -CcWorkDir D:\Projects   # 指定 cc-connect 项目工作目录
setup-lark-cli.exe -SkipCcConnect           # 跳过 cc-connect 安装/配置
```

> 说明：cc-connect 需要该应用的 AppSecret，脚本会询问一次（仅写入 `~/.cc-connect/config.toml`）；机器人收发消息所需的 IM 权限已包含在同一份全量权限申请单中，无需单独再申请。

## 在 Codex 里使用（沙箱规则 + PATH，自动处理）

如果新电脑上还要让 **Codex 直接在沙箱里调用 lark-cli**（例如让 Codex 代理帮你操作飞书），脚本会自动额外做两件事：

1. **创建 Codex 沙箱放行规则** `~/.codex/rules/lark-cli.rules`：允许 `lark-cli` 在沙箱外运行。这条规则同时解决"沙箱里找不到/禁止执行 lark-cli"和"网络受限反复弹窗"两个问题。
2. **把 npm 全局目录 `%APPDATA%\npm` 加入用户 PATH**：保证普通终端和 Codex 都能找到 `lark-cli`。

> 修改 PATH 和规则后，需要**重启 Codex（重开应用或任务）**才生效。之后在 Codex 里输入 `lark-cli doctor` 即可验证。

## 快速开始

1. 把整个文件夹拷贝到新电脑（或只拷贝 `setup-lark-cli.ps1`、`permission-report-template.md`、`lark-domain-labels.json`）。
2. 确认已安装 Node.js（首次安装 lark-cli 需要，安装后日常使用不再需要）。
3. 在 PowerShell 中运行：

```powershell
powershell -ExecutionPolicy Bypass -File setup-lark-cli.ps1
```

## 新电脑上的两种场景

**场景一：新账号 / 没有应用（推荐给新同事）**

直接运行 EXE，脚本检测到没有应用配置时会问一句"自动创建新应用？"，回车确认后走一次浏览器授权即可自动建好应用，**全程不用复制 AppId/AppSecret**。

新应用权限从零开始，所以脚本最后会生成全量权限申请单，发给管理员批一次（一次性全量，含敏感权限），批完重跑脚本扫码授权即可使用。

**场景二：已有应用（比如你现有的飞书应用）**

已有应用的 AppSecret 相当于应用密码，飞书不允许脚本未登录自动读取，所以在新电脑上需要填一次：

```powershell
setup-lark-cli.exe -AppId cli_xxx -AppSecret 你的secret
```

凭据在开发者后台获取：https://open.feishu.cn → 开发者后台 → 你的应用 → 凭证与基础信息。

已有应用的好处：权限已经在应用侧全量开通，新电脑填完凭据扫码授权后**直接可用，不需要管理员审批**。

> 也可以不写命令参数：运行 EXE 时，脚本问"自动创建新应用？"回答 `n`，它会直接在终端里一步一步提示你输入 App ID 和 App Secret（密码输入不显示，粘贴即可），随后自动完成配置并进入扫码授权。

脚本会自动完成：

- 预检：PowerShell / Node / npx / 网络连通性
- 安装或更新 `lark-cli`
- 应用配置（没有配置时会引导：提供 AppId/AppSecret，或 `-NewApp` 新建应用，或进入交互向导）
- 用户登录授权（生成二维码，用飞书扫码即可；Bot 身份随配置自动就绪）
- Codex 集成：lark skills、沙箱放行规则、npm PATH
- 可用性验证（`doctor` + 各域只读冒烟测试）
- **最后一步**：生成全量权限申请单 `lark-permission-request-<时间>.md`

## 权限申请（最后一步）

脚本内置了**飞书全量权限清单（203 项，覆盖所有业务域，含敏感权限，风险已接受）**，生成申请单时逐项标注状态：

- `已授权生效`：直接用
- `应用已启用,待用户授权`：重新运行脚本或 `lark-cli auth login --domain all` 扫码即可
- `待管理员在控制台开启`：需要管理员审批

把申请单和其中的控制台链接发给管理员一次，全部勾选审批即可。之后任何新电脑重跑脚本，检测通过后即可直接使用。

> 说明：内置权限清单来自全量启用的应用（`lark-cli auth scopes`）。若飞书后续新增权限，可在一个全量授权的机器上执行 `lark-cli auth scopes --format json` 核对，并同步更新脚本中的清单。

## 常用参数

| 参数 | 作用 |
|---|---|
| `-CheckOnly` | 只检测 + 生成报告，不做任何安装/更新/登录修改 |
| `-SkipUpdate` | 跳过 lark-cli 更新 |
| `-SkipLogin` | 跳过用户扫码登录 |
| `-SkipSkills` | 跳过 Codex skills 安装 |
| `-Domains all` | 登录授权请求的域（默认 `all`，即全部） |
| `-Brand feishu` | `feishu`（国内）或 `lark`（国际版），默认 `feishu` |
| `-AppId xxx -AppSecret yyy` | 非交互式配置已有应用（AppSecret 不会写入终端/日志） |
| `-NewApp` | 没有应用时，走浏览器流程新建应用 |
| `-LarkCli C:\path\to\lark-cli.cmd` | 指定 lark-cli 路径（一般不需要） |
| `-ReportDir <dir>` | 报告和二维码输出目录（默认脚本所在目录） |

示例：

```powershell
# 只检测并生成权限申请单（不改动任何东西）
powershell -ExecutionPolicy Bypass -File setup-lark-cli.ps1 -CheckOnly

# 全流程安装
powershell -ExecutionPolicy Bypass -File setup-lark-cli.ps1

# 用已有应用凭据非交互式安装
powershell -ExecutionPolicy Bypass -File setup-lark-cli.ps1 -AppId cli_xxx -AppSecret your_secret
```

## 常见问题

- **提示 `npx not found`**：正常情况脚本会自动安装 Node.js；若加了 `-SkipNodeInstall` 或自动安装失败，手动安装 [Node.js](https://nodejs.org) 后重开终端再运行。
- **提示 `lark-cli installed but not found on PATH`**：安装后需要重开终端，或手动把 npm 全局目录加进 PATH。
- **执行策略被禁止运行脚本**：使用上面的 `-ExecutionPolicy Bypass` 方式运行。
- **申请单显示"待管理员在控制台开启"**：这是预期结果，把申请单发给管理员一次审批即可，之后重跑脚本完成扫码授权。
- **Mac / Linux**：本脚本面向 Windows PowerShell；Mac/Linux 可参照官方文档手动执行对应命令（安装 `npx @larksuite/cli@latest install`、配置 `lark-cli config init`、登录 `lark-cli auth login --domain all`、skills `npx skills add larksuite/cli -y -g`）。
