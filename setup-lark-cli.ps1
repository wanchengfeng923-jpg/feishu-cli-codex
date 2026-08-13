#requires -Version 5.1
<#
  setup-lark-cli.ps1
  Universal bootstrap for Codex + Lark/Feishu CLI (lark-cli).

  Flow:
    0. Preflight        (PowerShell / Node / network)
    1. lark-cli         (detect -> install -> update)
    2. App config       (detect -> init)
    3. Auth             (detect -> user device login, bot auto)
    4. Codex skills     (detect -> npx skills add larksuite/cli)
    5. Verify           (doctor + read-only smoke tests per domain)
    5.5 cc-connect      (default on: bridge Feishu -> Codex CLI, reuses same app; -SkipCcConnect to disable)
    6. Permission req   (LAST: generate one full-scope approval report; one-time only)

  The permission application is intentionally the LAST step and requests ALL
  Feishu scopes at once (risk accepted), so the admin is only asked once.

  Examples:
    powershell -ExecutionPolicy Bypass -File setup-lark-cli.ps1            # full setup
    powershell -ExecutionPolicy Bypass -File setup-lark-cli.ps1 -CheckOnly # detect + report only
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly,        # detect and report only; make no changes
    [switch]$SkipUpdate,       # do not run `lark-cli update`
    [switch]$SkipLogin,        # do not run the interactive user login
    [switch]$SkipSkills,       # do not install Codex skills
    [switch]$SkipNodeInstall,  # do not auto-install Node.js if missing
    [string]$Brand = 'feishu', # feishu (default) or lark (international)
    [string]$Domains = 'all',  # domains requested at login, default: all
    [string]$AppId = '',       # non-interactive config init
    [string]$AppSecret = '',   # non-interactive config init (kept in memory only)
    [switch]$NewApp,           # create a brand-new Feishu app when no config
    [string]$LarkCli = '',     # explicit lark-cli executable path override
    [string]$ReportDir = '',   # where artifacts (QR, report) are written; default: script dir
    [switch]$SkipCcConnect,    # skip cc-connect install/configuration (default: enabled)
    [string]$CcWorkDir = ''    # cc-connect project working directory (default: $HOME\CodexWorkspace)
)

Set-StrictMode -Version Latest
# 使用 Continue 而不是 Stop：ps2exe 环境下外部命令 shim 的 stderr 噪音
# 会被 Stop 策略当成致命错误导致闪退。真实失败靠 $LASTEXITCODE / Write-Fail 捕获。
$ErrorActionPreference = 'Continue'

trap {
    Write-Host ''
    Write-Host ("[FATAL] 未处理异常: " + $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    $script:FailCount++
    if (-not [Console]::IsInputRedirected) {
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { Read-Host '按回车键退出（建议在终端中运行以查看完整报错）' | Out-Null } catch { }
        $ErrorActionPreference = $old
    }
    exit 1
}

# Suppress lark-cli update/skills notifiers so JSON output stays clean.
$env:LARKSUITE_CLI_NO_UPDATE_NOTIFIER = '1'
$env:LARKSUITE_CLI_NO_SKILLS_NOTIFIER = '1'

$script:LarkCliBin  = $null
$script:LarkOutput  = ''
$script:LarkExit    = 0
$script:FailCount   = 0
$script:WarnCount   = 0

$script:BaseDir = $null
if ($PSScriptRoot) {
    $script:BaseDir = $PSScriptRoot
} elseif ($PSCommandPath) {
    $script:BaseDir = Split-Path -Parent $PSCommandPath
} else {
    try {
        $script:BaseDir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    } catch {
        $script:BaseDir = $null
    }
}
if (-not $script:BaseDir) { $script:BaseDir = $PWD.Path }
if (-not $ReportDir) { $ReportDir = $script:BaseDir }
if (-not (Test-Path -LiteralPath $ReportDir)) {
    try { New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null } catch { $ReportDir = $PWD.Path }
}
$script:OutDir = (Resolve-Path -LiteralPath $ReportDir).Path

# Embedded copies of the report template and domain labels (base64, UTF-8).
# Used when the companion files are not present next to the script/EXE.
$script:EmbeddedTemplateB64 = 'IyDpo57kuaYgQ0xJ77yIbGFyay1jbGnvvInmnYPpmZDnlLPor7fljZUKCj4g55Sf5oiQ5pe26Ze077yae3tEQVRFfX0gIAo+IOW6lOeUqOWQjeensO+8mnt7QVBQX05BTUV9fSAgCj4gQXBwIElE77yae3tBUFBfSUR9fSAgCj4g5bmz5Y+w77yae3tCUkFORH19CgojIyDkuIDjgIHnlLPor7for7TmmI4KCuacrOeUs+ivt+S4uioq5LiA5qyh5oCn5YWo6YeP55Sz6K+3Kirpo57kuablvIDmlL7lubPlj7DmnYPpmZDvvIzopobnm5blhajpg6jkuJrliqHln5/vvIjkupHmlofmoaPjgIHkupHnm5jjgIHooajmoLzjgIHlpJrnu7TooajmoLzjgIHml6XljobjgIHmtojmga/jgIHku7vliqHjgIHnn6Xor4blupPjgIHpgq7nrrHjgIHlrqHmibnjgIHkvJrorq7jgIHlppnorrDjgIFPS1LjgIHpgJrorq/lvZXjgIHnmb3mnb/jgIHlupTnlKjlubPlj7DnrYnvvInvvIzlhbEgKip7e1RPVEFMX1NDT1BFU319Kiog6aG55p2D6ZmQ77yMKirljIXlkKvlhajpg6jmlY/mhJ8v6auY6aOO6Zmp5p2D6ZmQKirjgIIKCj4g5bey56Gu6K6k5o6l5Y+X55u45YWz6aOO6Zmp44CC6YeH55So5LiA5qyh5oCn5YWo6YeP5byA6YCa5pa55byP77yM6YG/5YWN5ZCO57ut5paw5aKe5p2D6ZmQ5pe25Y+N5aSN5omT5omw5a6h5om544CCCgojIyDkuozjgIHpnIDopoHnrqHnkIblkZjmk43kvZwKCuivt+WcqOmjnuS5puW8gOWPkeiAheWQjuWPsOaJk+W8gOivpeW6lOeUqO+8jOi/m+WFpSAqKuadg+mZkOeuoeeQhioqIOmhtemdou+8jCoq5YWo6YCJ5LiL5pa55p2D6ZmQ5riF5Y2V5bm25o+Q5Lqk5a6h5om5L+WQr+eUqCoq77yaCgotIOaOp+WItuWPsOmTvuaOpe+8mnt7Q09OU09MRV9VUkx9fQoK5a6h5om56YCa6L+H5ZCO77yM5bqU55So5L6n5Y2z5a6M5oiQ5YWo6YOo5p2D6ZmQ5byA6YCa44CC5L2/55So6ICF5YaN5omn6KGM5LiA5qyh55m75b2V5o6I5p2D5Y2z5Y+v55u05o6l5L2/55So77yI6KeB56ys5Zub6IqC77yJ44CCCgojIyDkuInjgIHmnYPpmZDmmI7nu4bkuI7lvZPliY3nirbmgIEKCiMjIyAzLjEg5Z+f5rGH5oC7Cgrnm67moIfmnYPpmZDmgLvmlbDvvJoqKnt7VE9UQUxfU0NPUEVTfX0qKiDvvZwg5bqU55So5bey5ZCv55So77yaKip7e0VOQUJMRURfQ09VTlR9fSoqIO+9nCDnlKjmiLflt7LmjojmnYPvvJoqKnt7R1JBTlRFRF9DT1VOVH19Kiog772cIOW+heeuoeeQhuWRmOW8gOWQr++8mioqe3tBRE1JTl9NSVNTSU5HfX0qKiDvvZwg5bqU55So5bey5ZCv55So5b6F55So5oi35o6I5p2D77yaKip7e1VTRVJfTUlTU0lOR319KioKCnwg5Z+fIHwg6K+05piOIHwg55uu5qCH5p2D6ZmQ5pWwIHwg5bqU55So5bey5ZCv55SoIHwg55So5oi35bey5o6I5p2DIHwKfC0tLXwtLS18LS0tfC0tLXwtLS18Cnt7RE9NQUlOX1NVTU1BUllfVEFCTEV9fQoKIyMjIDMuMiDlhajpg6jmnYPpmZDmuIXljZXvvIh7e1RPVEFMX1NDT1BFU319IOmhue+8iQoK54q25oCB6K+05piO77yaCgotIGDlt7LmjojmnYPnlJ/mlYhg77ya5p2D6ZmQ5bey5ZCv55So5LiU55So5oi35bey5a6M5oiQ5o6I5p2D77yM5Y+v55u05o6l5L2/55SoCi0gYOW6lOeUqOW3suWQr+eUqCzlvoXnlKjmiLfmjojmnYNg77ya566h55CG5ZGY5bey5byA5ZCv77yM5L2/55So6ICF5omr56CB5o6I5p2D5ZCO5Y2z5Y+v55Sf5pWICi0gYOW+heeuoeeQhuWRmOWcqOaOp+WItuWPsOW8gOWQr2DvvJrpnIDopoHnrqHnkIblkZjlnKjmnKzljZXnrKzkuozoioLnmoTpk77mjqXkuK3lvIDlkK8KCnwg5p2D6ZmQIHwg5omA5bGe5Z+fIHwg54q25oCBIHwKfC0tLXwtLS18LS0tfAp7e1NDT1BFX1RBQkxFfX0KCiMjIOWbm+OAgeWuoeaJuemAmui/h+WQjuS9v+eUqOiAheeahOaTjeS9nAoKMS4g5Zyo5pys5py66YeN5paw6L+Q6KGM5a6J6KOF6ISa5pys77yM5oiW55u05o6l5omn6KGM55m75b2V5o6I5p2D77yI5LiA5qyh5Y2z5Y+v77yJ77yaCgogICBgYGBiYXNoCiAgIGxhcmstY2xpIGF1dGggbG9naW4gLS1kb21haW4gYWxsCiAgIGBgYAoKMi4g6aqM6K+B5Y+v55So5oCn77yaCgogICBgYGBiYXNoCiAgIGxhcmstY2xpIGRvY3RvcgogICBsYXJrLWNsaSBjYWxlbmRhciArYWdlbmRhCiAgIGxhcmstY2xpIGltICtjaGF0LWxpc3QKICAgYGBgCgozLiDoi6XkuYvlkI7mnYPpmZDku43mnInnvLrlpLHvvIzph43mlrDov5DooYwgYHNldHVwLWxhcmstY2xpLnBzMWDvvIzohJrmnKzkvJroh6rliqjmiornvLrlj6PlubblhaXmlrDmiqXlkYrjgIIKCiMjIOS6lOOAgeWPr+ebtOaOpeWPkee7meWuoeaJueS6uueahOeUs+ivt+ivneacrwoK5oKo5aW977yM55Sz6K+35Li65bqU55So44CMe3tBUFBfTkFNRX1944CN77yIQXBwSWTvvJp7e0FQUF9JRH1977yJ5LiA5qyh5oCn5byA6YCa6aOe5Lmm5byA5pS+5bmz5Y+w5YWo6YOo5p2D6ZmQ77yI5YWxIHt7VE9UQUxfU0NPUEVTfX0g6aG577yM6KaG55uW5omA5pyJ5Lia5Yqh5Z+f77yM5YyF5ZCr5pWP5oSf5p2D6ZmQ77yJ44CCCgrnlKjpgJTvvJrmnKzlnLDoh6rliqjljJYgLyBDb2RleCDpgJrov4flrpjmlrkgbGFyay1jbGkg6K6/6Zeu6aOe5Lmm6LWE5rqQ44CC6YeH55So5LiA5qyh5oCn5YWo6YeP5byA6YCa5pa55byP77yM6YG/5YWN5ZCO57ut5paw5aKe5p2D6ZmQ5pe25Y+N5aSN55Sz6K+344CCCgrmjqfliLblj7Dpk77mjqXvvJp7e0NPTlNPTEVfVVJMfX0KCuW3suehruiupOaOleWPl+ebuOW6lOmjjumZqeOAgum6u+eDpuWuoeaJue+8jOiwouiwou+8gQo='
$script:EmbeddedLabelsB64 = 'ewogICJsYWJlbHMiOiB7CiAgICAiaW0iOiAi5Y2z5pe26YCa6K6vIiwKICAgICJjYWxlbmRhciI6ICLml6XljoYiLAogICAgImRvY3MiOiAi5LqR5paH5qGjIiwKICAgICJkb2N4IjogIuS6keaWh+ahoyjmlrDniYgpIiwKICAgICJkcml2ZSI6ICLkupHnm5gv5paH5Lu2IiwKICAgICJzaGVldHMiOiAi55S15a2Q6KGo5qC8IiwKICAgICJiYXNlIjogIuWkmue7tOihqOagvCIsCiAgICAiYml0YWJsZSI6ICLlpJrnu7TooajmoLwo5pen54mIKSIsCiAgICAic2xpZGVzIjogIuW5u+eBr+eJhyIsCiAgICAidGFzayI6ICLku7vliqEiLAogICAgIndpa2kiOiAi55+l6K+G5bqTIiwKICAgICJtYWlsIjogIumCrueusSIsCiAgICAidmMiOiAi6KeG6aKR5Lya6K6uIiwKICAgICJtaW51dGVzIjogIuWmmeiusC/nuqropoEiLAogICAgIm9rciI6ICJPS1IiLAogICAgIm1pbmRub3RlIjogIuaAnee7tOeslOiusCIsCiAgICAiY29udGFjdCI6ICLpgJrorq/lvZUiLAogICAgImFwcHJvdmFsIjogIuWuoeaJuSIsCiAgICAiYXR0ZW5kYW5jZSI6ICLogIPli6QiLAogICAgImFwcGxpY2F0aW9uIjogIuW6lOeUqOiDveWKmyIsCiAgICAic3BhcmsiOiAi5aaZ5pCtL+W6lOeUqOW5s+WPsCIsCiAgICAiYm9hcmQiOiAi55m95p2/IiwKICAgICJzZWFyY2giOiAi5pCc57SiIiwKICAgICJwcm9maWxlIjogIueUqOaIt+i1hOaWmSIsCiAgICAic3BhY2UiOiAi5LqR56m66Ze0IiwKICAgICJhdXRoIjogIui6q+S7veiupOivgSIsCiAgICAib2ZmbGluZV9hY2Nlc3MiOiAi5Z+656GAKOemu+e6vykiLAogICAgImV2ZW50IjogIuS6i+S7tuiuoumYhSIsCiAgICAibm90ZSI6ICLkvJrorq7nuqropoEiLAogICAgIm1hcmtkb3duIjogIk1hcmtkb3duIiwKICAgICJhcHBzIjogIuW6lOeUqOW8gOWPkSIsCiAgICAidW5rbm93biI6ICLlhbbku5YiCiAgfSwKICAic3RhdHVzIjogewogICAgImdyYW50ZWQiOiAi5bey5o6I5p2D55Sf5pWIIiwKICAgICJlbmFibGVkIjogIuW6lOeUqOW3suWQr+eUqCzlvoXnlKjmiLfmjojmnYMiLAogICAgIm1pc3NpbmciOiAi5b6F566h55CG5ZGY5Zyo5o6n5Yi25Y+w5byA5ZCvIgogIH0KfQo='

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step { param([string]$s) Write-Host ("`n===== " + $s + " =====") -ForegroundColor Cyan }
function Write-Ok   { param([string]$s) Write-Host "[OK]   $s" -ForegroundColor Green }
function Write-Warn { param([string]$s) $script:WarnCount++; Write-Host "[WARN] $s" -ForegroundColor Yellow }
function Write-Fail { param([string]$s) $script:FailCount++; Write-Host "[FAIL] $s" -ForegroundColor Red }

function Read-UserInput {
    param([string]$Prompt)
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        return [string](Read-Host $Prompt)
    } catch {
        Write-Warn '交互输入不可用（控制台输入被重定向或当前环境不支持），已按空输入继续。'
        return ''
    } finally {
        $ErrorActionPreference = $oldEAP
    }
}

function Show-AppSecretGuidance {
    param([string]$ForWhat)
    Write-Host ''
    Write-Host ("需要你的飞书应用 AppSecret（应用密钥）" + $ForWhat + "。") -ForegroundColor Yellow
    Write-Host '获取方式（约 30 秒）：' -ForegroundColor Cyan
    Write-Host '  1) 打开飞书开放平台：https://open.feishu.cn'
    Write-Host '  2) 右上角点「开发者后台」→ 选择你的应用'
    Write-Host '     （就是你之前配置/新建的那个应用，名字可能类似「xxx 的飞书 CLI」）'
    Write-Host '  3) 左侧菜单点「凭证与基础信息」→ 找到「App Secret」→ 点「查看」'
    Write-Host '     （首次查看可能需要二次验证或扫码，按页面提示操作即可）'
    Write-Host '  4) 复制这串密钥（约 32 位，大小写字母+数字混合）'
    Write-Host ''
    Write-Host '⚠ 注意：AppSecret 相当于应用的密码，只会写入本机配置文件，请勿发到聊天或群里。' -ForegroundColor DarkYellow
    Write-Host ''
}

function Invoke-Lark {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$LarkArgs)
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $stdout = (& $script:LarkCliBin @LarkArgs 2>&1 | Out-String)
        $script:LarkExit   = $LASTEXITCODE
        $script:LarkOutput = ([string]$stdout -replace '^(.*?\.(cmd|ps1|exe) : )', '')
    } finally {
        $ErrorActionPreference = $oldEAP
    }
}

function Get-LarkJson {
    if ([string]::IsNullOrWhiteSpace($script:LarkOutput)) { return $null }
    $m = [regex]::Match($script:LarkOutput, '\{.*\}', 'Singleline')
    if (-not $m.Success) { return $null }
    try { return ($m.Value | ConvertFrom-Json) } catch { return $null }
}

function Get-JsonProp {
    param($Obj, [string]$Path)
    if ($null -eq $Obj) { return $null }
    $cur = $Obj
    foreach ($p in $Path -Split '\.') {
        try { $cur = $cur.$p } catch { return $null }
        if ($null -eq $cur) { return $null }
    }
    return $cur
}

function Find-Npx {
    $c = Get-Command 'npx.cmd' -CommandType Application -ErrorAction SilentlyContinue
    if (-not $c) { $c = Get-Command 'npx' -CommandType Application -ErrorAction SilentlyContinue }
    return $c
}

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Test-NodeReady {
    $node = Get-Command 'node' -CommandType Application -ErrorAction SilentlyContinue
    $npxc = Find-Npx
    return ($null -ne $node -and $null -ne $npxc)
}

function Refresh-PathFromRegistry {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = ($machine + ';' + $user + ';' + $env:Path)
}

function Install-NodeViaWinget {
    $w = Get-Command 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue
    if (-not $w) { $w = Get-Command 'winget' -CommandType Application -ErrorAction SilentlyContinue }
    if (-not $w) { return $false }
    try {
        Write-Host 'Installing Node.js LTS via winget (a UAC confirmation may appear) ...' -ForegroundColor Yellow
        if (Test-Admin) {
            & $w.Source install --id OpenJS.NodeJS.LTS --silent --accept-package-agreements --accept-source-agreements
        } else {
            $argsLine = 'install --id OpenJS.NodeJS.LTS --silent --accept-package-agreements --accept-source-agreements'
            Start-Process -FilePath $w.Source -ArgumentList $argsLine -Verb RunAs -Wait
        }
    } catch {
        Write-Host 'winget install failed or was cancelled.' -ForegroundColor Yellow
    }
    Refresh-PathFromRegistry
    return (Test-NodeReady)
}

function Get-LatestNodeLtsVersion {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $idx = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec 30
        $cand = @($idx | Where-Object {
            $_.lts -and (($_.files -contains 'win-x64-zip') -or ($_.files -contains 'win-x64-exe'))
        } | Select-Object -First 1)
        if ($cand.Count -gt 0) { return [string]$cand[0].version }
    } catch { }
    foreach ($maj in @('24', '22', '20')) {
        try {
            $html = (Invoke-WebRequest -Uri "https://nodejs.org/dist/latest-v$maj.x/" -UseBasicParsing -TimeoutSec 30).Content
            $m = [regex]::Match($html, 'node-v(\d+\.\d+\.\d+)-x64\.zip')
            if ($m.Success) { return 'v' + $m.Groups[1].Value }
        } catch { }
    }
    return $null
}

function Install-NodePortable {
    $ver = Get-LatestNodeLtsVersion
    if (-not $ver) { return $false }
    $nodeHome = Join-Path $env:LOCALAPPDATA 'Programs\codex-node'
    $zipUrl   = "https://nodejs.org/dist/$ver/node-$ver-win-x64.zip"
    $zip      = Join-Path $env:TEMP ("node-$ver.zip")
    $extract  = Join-Path $env:TEMP ("node-extract-" + [guid]::NewGuid().ToString('N'))
    try {
        Write-Host "Downloading Node.js $ver (portable, no admin needed) ..." -ForegroundColor Yellow
        Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 120
        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
        $src = Get-ChildItem -LiteralPath $extract -Directory |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'node.exe') } |
            Select-Object -First 1
        if (-not $src) { Write-Host 'Portable package structure unexpected.' -ForegroundColor Yellow; return $false }
        New-Item -ItemType Directory -Path $nodeHome -Force | Out-Null
        Copy-Item -Path (Join-Path $src.FullName '*') -Destination $nodeHome -Recurse -Force
        $env:Path = $nodeHome + ';' + $env:Path
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $npmGlobal = Join-Path $env:APPDATA 'npm'
        $toAdd = @($nodeHome, $npmGlobal) | Where-Object { $userPath -notlike "*$_*" }
        if (@($toAdd).Count -gt 0) {
            [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + ($toAdd -join ';')), 'User')
        }
        return $true
    } catch {
        Write-Host "Portable Node install failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    } finally {
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Ensure-Node {
    if (Test-NodeReady) { return $true }
    if ($CheckOnly) {
        Write-Warn 'Node.js/npx not found (would auto-install Node.js LTS).'
        return $false
    }
    if ($SkipNodeInstall) {
        Write-Warn 'Node.js missing and -SkipNodeInstall is set. Install it from https://nodejs.org and rerun.'
        return $false
    }
    Write-Host 'Node.js not found - installing automatically ...' -ForegroundColor Yellow
    if (Install-NodeViaWinget) {
        Write-Ok 'Node.js installed via winget.'
        return $true
    }
    Write-Host 'winget unavailable or failed - falling back to portable Node.js ...' -ForegroundColor Yellow
    if (Install-NodePortable) {
        if (Test-NodeReady) { Write-Ok 'Node.js portable install done.'; return $true }
    }
    Write-Fail 'Could not install Node.js automatically. Install it from https://nodejs.org and rerun.'
    return $false
}

function Resolve-LarkCli {
    if ($LarkCli) {
        if (-not (Test-Path -LiteralPath $LarkCli)) { throw "Explicit LarkCli path not found: $LarkCli" }
        $script:LarkCliBin = $LarkCli
        return $true
    }
    $cmd = Get-Command 'lark-cli.cmd' -CommandType Application -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command 'lark-cli' -CommandType Application -ErrorAction SilentlyContinue }
    if (-not $cmd) {
        $npmPrefix = (& npm.cmd prefix -g 2>$null | Out-String).Trim()
        if ($npmPrefix) {
            $cand = Join-Path $npmPrefix 'lark-cli.cmd'
            if (Test-Path -LiteralPath $cand) { $cmd = Get-Item -LiteralPath $cand }
        }
    }
    if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) {
        $script:LarkCliBin = $cmd.Source
        return $true
    }
    return $false
}

function Install-LarkCli {
    $npx = Find-Npx
    if (-not $npx) { throw 'npx not found. Install Node.js first (https://nodejs.org), then rerun.' }
    Write-Host 'Installing lark-cli via npm (this needs network)...' -ForegroundColor Yellow
    & $npx.Source '@larksuite/cli@latest' install
    if ($LASTEXITCODE -ne 0) { throw 'lark-cli install failed. Check network / npm registry access.' }
    if (-not (Resolve-LarkCli)) {
        throw 'lark-cli installed but not found on PATH. Reopen the terminal and rerun this script.'
    }
    Write-Ok "lark-cli installed: $script:LarkCliBin"
}

function Test-SkillsInstalled {
    $roots = @(
        (Join-Path $HOME '.agents\skills'),
        (Join-Path $HOME '.codex\skills')
    )
    foreach ($r in $roots) {
        if (Test-Path -LiteralPath (Join-Path $r 'lark-shared\SKILL.md')) { return $true }
    }
    return $false
}

function Install-Skills {
    $npx = Find-Npx
    if (-not $npx) { throw 'npx not found. Install Node.js first, then rerun.' }
    Write-Host 'Installing Codex skills for lark-cli (npx skills add larksuite/cli -g)...' -ForegroundColor Yellow
    & $npx.Source skills add larksuite/cli -y -g
    if ($LASTEXITCODE -ne 0) { throw 'skills install failed. Run manually: npx skills add larksuite/cli -y -g' }
    if (Test-SkillsInstalled) { Write-Ok 'Codex skills installed.' }
    else { Write-Warn 'Skills install finished but could not confirm files; verify manually.' }
}

function Ensure-CodexRule {
    $codexHome = $env:CODEX_HOME
    if (-not $codexHome) { $codexHome = Join-Path $HOME '.codex' }
    $rulesDir  = Join-Path $codexHome 'rules'
    $ruleFile  = Join-Path $rulesDir 'lark-cli.rules'
    if (Test-Path -LiteralPath $ruleFile) {
        Write-Ok "Codex sandbox rule already exists: $ruleFile"
        return $true
    }
    if ($CheckOnly) {
        Write-Warn "Would create Codex sandbox rule: $ruleFile (allows lark-cli outside the sandbox)"
        return $false
    }
    try {
        New-Item -ItemType Directory -Path $rulesDir -Force | Out-Null
        $content = @"
prefix_rule(
    pattern = ["lark-cli"],
    decision = "allow",
    justification = "Allow lark-cli to run outside the Codex sandbox (Feishu CLI setup)",
)
"@
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($ruleFile, $content, $utf8NoBom)
        Write-Ok "Codex sandbox rule created: $ruleFile"
        Write-Host 'Restart Codex (reopen the app/task) so the rule takes effect.' -ForegroundColor Yellow
        return $true
    } catch {
        Write-Fail ("Could not create Codex sandbox rule: " + $_.Exception.Message)
        return $false
    }
}

function Ensure-NpmOnPath {
    $npmGlobal = Join-Path $env:APPDATA 'npm'
    $userPath  = [Environment]::GetEnvironmentVariable('Path', 'User')
    $already = ($userPath -like "*$npmGlobal*") -or ($userPath -like '*%APPDATA%\npm*')
    if ($already) {
        Write-Ok 'npm global dir already on user PATH.'
        return $true
    }
    if ($CheckOnly) {
        Write-Warn "Would add npm global dir to user PATH: $npmGlobal"
        return $false
    }
    try {
        $newPath = $userPath.TrimEnd(';') + ';' + $npmGlobal
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        $env:Path = $env:Path + ';' + $npmGlobal
        Write-Ok "Added to user PATH: $npmGlobal"
        Write-Host 'Reopen terminals and restart Codex for PATH to take effect.' -ForegroundColor Yellow
        return $true
    } catch {
        Write-Fail ("Could not update PATH: " + $_.Exception.Message)
        return $false
    }
}

function Get-CcOwnerOpenId {
    $ErrorActionPreference = 'Continue'
    $show = lark-cli config show 2>$null | Out-String
    $m = [regex]::Match($show, 'ou_[A-Za-z0-9]+')
    if ($m.Success) { return $m.Value }
    return ''
}

function Ensure-CcConnect {
    $ErrorActionPreference = 'Continue'
    $found = $false
    try {
        $v = cc-connect --version 2>&1 | Out-String
        if ($v -match 'v\d+\.\d+\.\d+') { $found = $true }
    } catch { }
    if ($found) {
        Write-Ok 'cc-connect already installed.'
        return $true
    }
    if ($CheckOnly) {
        Write-Warn 'Would install cc-connect: npm install -g cc-connect'
        return $false
    }
    if (-not (Test-NodeReady)) {
        if (-not (Ensure-Node)) { Write-Fail 'Node.js missing; cannot install cc-connect.'; return $false }
    }
    Write-Host 'Installing cc-connect (npm install -g cc-connect)...' -ForegroundColor Yellow
    npm install -g cc-connect 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Fail 'cc-connect npm install failed.'; return $false }
    Write-Ok 'cc-connect installed.'
    return $true
}

function Ensure-CodexCli {
    $ErrorActionPreference = 'Continue'
    $ok = $false
    try {
        $v = codex --version 2>&1 | Out-String
        if ($v -match 'codex-cli\s+\d+\.\d+\.\d+') { $ok = $true }
    } catch { }
    if ($ok) {
        Write-Ok 'Codex CLI available (cc-connect can spawn it).'
        return $true
    }
    if ($CheckOnly) {
        Write-Warn 'Would install Codex CLI: npm install -g @openai/codex (desktop-bundled codex cannot be spawned by cc-connect)'
        return $false
    }
    Write-Host 'Installing Codex CLI (npm install -g @openai/codex)...' -ForegroundColor Yellow
    npm install -g @openai/codex 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Fail 'Codex CLI install failed.'; return $false }
    Write-Ok 'Codex CLI installed.'
    return $true
}

function Install-CcConnectProject {
    param([string]$AppIdValue, [string]$SecretValue)
    $ErrorActionPreference = 'Continue'
    $workDir = if ($CcWorkDir) { $CcWorkDir } else { Join-Path $HOME 'CodexWorkspace' }
    $workDirForward = $workDir -replace '\\', '/'
    if (-not (Test-Path -LiteralPath $workDir)) {
        try { New-Item -ItemType Directory -Path $workDir -Force | Out-Null; Write-Ok ("cc-connect work dir created: $workDir") }
        catch { Write-Fail ("Could not create work dir: " + $_.Exception.Message); return $false }
    }
    $ownerId = Get-CcOwnerOpenId
    $allow = if ($ownerId) { $ownerId } else { '*' }
    $cfgDir = Join-Path $HOME '.cc-connect'
    if (-not (Test-Path -LiteralPath $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir | Out-Null }
    $cfgPath = Join-Path $cfgDir 'config.toml'
    $existing = $null
    if (Test-Path -LiteralPath $cfgPath) {
        try { $existing = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 } catch { }
    }
    if ($existing -and $existing -match 'type\s*=\s*"feishu"' -and $existing -match [regex]::Escape($AppIdValue)) {
        Write-Ok "cc-connect 配置已存在且使用同一飞书应用（$AppIdValue），保留现有配置（含已配置的其他平台，如微信）。"
    } else {
        $toml = @"
# Generated by setup-lark-cli (cc-connect integration). Reuses the same Feishu app:
# no separate permission application is created.
language = "zh"

[log]
level = "info"

[display]
thinking_messages = true
tool_messages = false

[[projects]]
name = "codex"

[projects.agent]
type = "codex"

[projects.agent.options]
work_dir = "$workDirForward"
mode = "suggest"

[[projects.platforms]]
type = "feishu"

[projects.platforms.options]
app_id = "$AppIdValue"
app_secret = "$SecretValue"
enable_feishu_card = true
progress_style = "card"
allow_from = "$allow"
"@
        try {
            Set-Content -LiteralPath $cfgPath -Value $toml -Encoding UTF8
            Write-Ok ("cc-connect config written: $cfgPath (allow_from=$allow)")
        } catch {
            Write-Fail ("Could not write cc-connect config: " + $_.Exception.Message)
            return $false
        }
    }
    $agentsMd = Join-Path $workDir 'AGENTS.md'
    if (-not (Test-Path -LiteralPath $agentsMd)) {
        $agentsContent = @'
# CodexWorkspace 说明（cc-connect 远程会话专用）

## 环境事实（重要，避免误判）

- lark-cli 已安装并可用。直接运行 `lark-cli <domain> +<command> ...` 即可，例如：
  - `lark-cli auth status` 检查登录与身份
  - `lark-cli drive +search --query "<关键词>" --as user` 搜索飞书云空间文档
- **沙箱假象**：当前执行环境对文件系统/命令解析做了隔离。`Get-Command lark-cli`、
  `where.exe lark-cli`、`Test-Path ...\AppData\Roaming\npm\lark-cli.cmd` 可能返回
  “找不到”或显示目录为空——这是沙箱视图造成的，不代表 lark-cli 未安装。
- 网络：lark-cli 已由 `~/.codex/rules/lark-cli.rules` 放行，可以访问飞书 API。
- 身份：访问个人资源（云盘、文档、日历、邮件等）用 `--as user`；机器人身份用 `--as bot`。
- 飞书 skills 位于 `~/.agents/skills/lark-*`（lark-drive、lark-doc、lark-sheets、
  lark-calendar、lark-im 等），按需读取对应 SKILL.md 获取完整命令用法。

## 工作约定

- 飞书相关任务优先使用 lark-cli + 对应 skill 完成。
- 若命令报错（权限、scope、参数等），把**原始错误信息**原样报告给用户，不要自行推断
  “未安装”或“环境缺失”。
- 搜索云空间文件时，`--query` 必须给具体关键词，避免空查询。
'@
        try {
            Set-Content -LiteralPath $agentsMd -Value $agentsContent -Encoding UTF8
            Write-Ok "workspace AGENTS.md written: $agentsMd"
        } catch {
            Write-Warn ("Could not write AGENTS.md: " + $_.Exception.Message)
        }
    }
    cc-connect config format 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Fail 'cc-connect config format validation failed.'; return $false }
    Write-Ok 'cc-connect config validated.'
    Write-Host 'Installing cc-connect as a Windows background service (daemon install)...' -ForegroundColor Yellow
    cc-connect daemon install --config $cfgPath --force 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Fail 'cc-connect daemon install failed; run manually: cc-connect daemon install --config <path>'; return $false }
    Write-Ok 'cc-connect daemon installed and started (auto-start on login).'
    try {
        $t = Get-ScheduledTask -TaskName 'cc-connect' -ErrorAction SilentlyContinue
        if ($t -and $t.Principal.LogonType -ne 'S4U') {
            $principal = New-ScheduledTaskPrincipal -UserId $t.Principal.UserId -LogonType S4U -RunLevel Limited
            $triggers = @((New-ScheduledTaskTrigger -AtLogOn -User $t.Principal.UserId), (New-ScheduledTaskTrigger -AtStartup))
            $s4uOk = $false
            try {
                Set-ScheduledTask -TaskName 'cc-connect' -Principal $principal -Trigger $triggers -ErrorAction Stop | Out-Null
                $s4uOk = $true
            } catch {
                Write-Warn ("S4U 无窗口转换失败（" + $_.Exception.Message + "）：服务仍可使用，但控制台窗口可能弹出；可尝试以管理员身份运行一次本脚本。")
            }
            if ($s4uOk) {
                $t2 = Get-ScheduledTask -TaskName 'cc-connect' -ErrorAction SilentlyContinue
                if ($t2 -and $t2.Principal.LogonType -eq 'S4U') {
                    Write-Ok 'cc-connect service converted to non-interactive (S4U): no console windows on desktop.'
                } else {
                    Write-Warn 'S4U 转换未生效（计划任务登录类型未改变）；服务仍可用，但控制台窗口可能弹出。'
                }
            }
        }
        cc-connect daemon stop 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        Get-Process cc-connect -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        cc-connect daemon start 2>&1 | Out-Null
        Write-Ok 'cc-connect service restarted with the new config.'
    } catch {
        Write-Warn ("Could not restart cc-connect service: " + $_.Exception.Message)
    }
    Start-Sleep -Seconds 6
    $ccLogFile = Join-Path $HOME '.cc-connect\logs\cc-connect.log'
    $daemonJson = Join-Path $HOME '.cc-connect\daemon.json'
    if (Test-Path -LiteralPath $daemonJson) {
        try {
            $ccLogFile = [string]((Get-Content -LiteralPath $daemonJson -Raw -Encoding UTF8 | ConvertFrom-Json).log_file)
            if (-not $ccLogFile) { $ccLogFile = Join-Path $HOME '.cc-connect\logs\cc-connect.log' }
        } catch { }
    }
    $ccLogLines = @(Get-Content -LiteralPath $ccLogFile -ErrorAction SilentlyContinue)
    $lastStart = -1
    for ($i = $ccLogLines.Count - 1; $i -ge 0; $i--) {
        if ($ccLogLines[$i] -match 'config loaded') { $lastStart = $i; break }
    }
    if ($lastStart -ge 0) { $ccLogLines = $ccLogLines[$lastStart..($ccLogLines.Count - 1)] }
    $ccLog = $ccLogLines -join "`n"
    if ($ccLog -match '(?i)secret invalid|app_id or app_secret is invalid|websocket error|10014|1000040345') {
        Write-Warn 'cc-connect 启动日志显示飞书凭据无效（AppSecret 可能不正确）。请到飞书开放平台核对 AppSecret 后重新运行本脚本，或修改 ~/.cc-connect/config.toml 后执行 cc-connect daemon restart。'
    } else {
        Write-Ok 'cc-connect 飞书连接检查通过（日志未发现凭据错误）。'
    }
    return $true
}

function Invoke-UserLogin {
    param([string]$LoginDomains)
    Write-Step 'User login (authorize the app)'
    Invoke-Lark auth login --domain $LoginDomains --no-wait --json
    $flow = Get-LarkJson
    $url  = Get-JsonProp $flow 'verification_url'
    $code = Get-JsonProp $flow 'device_code'
    if (-not $url -or -not $code) {
        Write-Fail 'Could not start device login flow.'
        return $false
    }
    Write-Host ''
    Write-Host '1) Open this URL in a browser and authorize:' -ForegroundColor Yellow
    Write-Host $url
    Write-Host '2) Or scan the QR code with the Feishu app (saved at lark-login-qr.png):' -ForegroundColor Yellow
    Push-Location
    try {
        Set-Location $script:OutDir
        Invoke-Lark auth qrcode $url --output 'lark-login-qr.png'
        if ($script:LarkExit -eq 0) {
            Write-Ok ("QR code saved: " + (Join-Path $script:OutDir 'lark-login-qr.png'))
        }
        Invoke-Lark auth qrcode $url --ascii
        if ($script:LarkExit -eq 0) { Write-Host $script:LarkOutput }
    } finally {
        Pop-Location
    }
    Write-Host ''
    Read-UserInput 'After authorizing in the Feishu app, press Enter to continue'
    Invoke-Lark auth login --device-code $code
    if ($script:LarkExit -ne 0) {
        Write-Fail 'Login completion failed. Reopen the URL and authorize, then rerun.'
        return $false
    }
    Write-Ok 'User login completed.'
    return $true
}

# ---------------------------------------------------------------------------
# Embedded target scope set: ALL Feishu scopes (full coverage, risk accepted).
# Keep in sync with `lark-cli auth scopes` on a fully-provisioned app.
# ---------------------------------------------------------------------------
$script:AllScopeText = @'
docs:document.comment:create
docs:document.comment:read
docs:document.comment:update
docx:document:write_only
docx:document:readonly
drive:drive.metadata:readonly
docs:document.comment:delete
docs:document.comment:write_only
im:chat:read
im:chat:update
im:message.pins:read
im:message.pins:write_only
im:message.reactions:read
im:message.reactions:write_only
im:message:readonly
im:message:update
im:resource
wiki:node:read
application:app_slash_command:read
application:app_slash_command:write
offline_access
task:task:read
base:form:create
drive:file:view_record:readonly
base:app:update
wiki:member:update
spark:app:write
docs:event:subscribe
wiki:node:move
wiki:member:retrieve
vc:note:read
slides:presentation:update
base:dashboard:read
base:record:update
contact:user:search
board:whiteboard:node:create
wiki:node:copy
im:chat.members:read
base:record:create
im:message.group_msg:get_as_user
docs:document:export
base:app:copy
space:document:shortcut
task:section:read
im:chat.managers:write_only
minutes:minutes.search:read
base:table:delete
docs:permission.member:auth
base:dashboard:create
wiki:member:create
docs:permission.setting:read
base:table:create
base:field:create
wiki:space:read
docs:document.media:download
im:chat.user_setting:read
base:field:read
approval:task:write
slides:presentation:write_only
docs:document.media:upload
task:tasklist:write
approval:instance:read
docs:document:copy
im:chat:moderation:write_only
base:form:read
slides:presentation:read
vc:record:readonly
contact:user.base:readonly
vc:meeting.search:read
base:view:write_only
im:message
base:table:read
sheets:spreadsheet.meta:read
docs:document.content:read
base:form:update
space:document:move
task:custom_field:write
minutes:minutes.artifacts:read
wiki:space:retrieve
base:workflow:read
base:record:delete
wiki:node:create
docx:document:create
docs:permission.member:apply
task:comment:write
im:chat.user_setting:write
task:attachment:write
sheets:spreadsheet:write_only
im:feed.flag:read
im:message.p2p_msg:get_as_user
space:folder:create
wiki:node:retrieve
base:workflow:create
base:form:delete
base:field:delete
task:task:write
base:view:read
drive:file:download
sheets:spreadsheet:create
base:dashboard:delete
docs:permission.member:create
base:dashboard:update
base:workflow:update
docs:permission.member:retrieve
base:app:read
board:whiteboard:node:read
base:field:update
im:chat.members:write_only
docs:permission.setting:write_only
im:chat.moderation:read
im:chat.nickname:write
docs:permission.member:transfer
mail:user_mailbox:readonly
base:role:read
spark:app:read
base:history:read
docs:document:import
task:custom_field:read
sheets:spreadsheet.meta:write_only
wiki:space:write_only
mail:user_mailbox.message:modify
approval:task:read
base:role:delete
base:app:create
base:role:update
im:feed.flag:write
minutes:minutes.upload:write
task:section:write
base:record:read
base:role:create
im:chat.nickname:read
drive:file:upload
approval:instance:write
sheets:spreadsheet:read
task:tasklist:read
slides:presentation:create
space:document:delete
base:table:update
drive:quota_detail:read_one
vc:meeting.meetingevent:read
docs:secure_label:write_only
bitable:app:readonly
search:docs:read
im:feed.shortcut:read
minutes:minutes:readonly
calendar:calendar.free_busy:read
calendar:calendar.event:create
mail:user_mailbox.message:readonly
im:message.send_as_user
im:feed.shortcut:write
mail:user_mailbox.message.body:read
okr:okr.setting:read
mindnote:node:create
base:block:delete
mail:user_mailbox.event.mail_address:read
okr:okr.content:writeonly
search:bot
calendar:calendar.event:reply
mail:user_mailbox.folder:read
mail:user_mailbox.rule:read
vc:meeting.bot.join:write
search:message
mail:user_mailbox.message:send
calendar:calendar:read
im:chat:create_by_user
base:block:create
vc:meeting.message:write
calendar:calendar:update
mail:event
approval:approval:read
mail:user_mailbox.folder:write
minutes:minutes.basic:read
mindnote:node:read
mail:user_mailbox.mail_contact:read
base:block:update
im:feed_group_v1:read
mail:user_mailbox.message.subject:read
minutes:minutes.media:export
slides:presentation:screenshot
calendar:calendar.event:read
mail:user_mailbox.mail_contact:write
im:feed_group_v1:write
okr:okr.progress:writeonly
space:document:retrieve
mail:user_mailbox.message.address:read
okr:okr.period:readonly
calendar:calendar.event:delete
okr:okr.content:readonly
base:block:read
calendar:calendar.event:update
mail:user_mailbox.rule:write
contact:user.basic_profile:readonly
profile:user_profile:read
attendance:task:readonly
minutes:minutes:update
okr:okr.progress.file:upload
minutes:permission:apply
calendar:calendar:create
docs:secure_label:readonly
okr:okr.progress:delete
im:message:recall
calendar:calendar:delete
okr:okr.progress:readonly
'@
$script:AllScopes = @($script:AllScopeText -Split "`r?`n" | Where-Object { $_ -and $_.Trim() })

# ---------------------------------------------------------------------------
# Phase 0: Preflight
# ---------------------------------------------------------------------------
Write-Step 'Phase 0/6 - Preflight'
$psPlatform = if ($PSVersionTable.ContainsKey('Platform')) { $PSVersionTable.Platform } else { 'Windows' }
Write-Host "PowerShell $($PSVersionTable.PSVersion) on $psPlatform"
if ($PSVersionTable.PSVersion.Major -lt 5) { Write-Fail 'PowerShell 5.1+ is required.' }

$node = Get-Command 'node' -CommandType Application -ErrorAction SilentlyContinue
if ($node) {
    $nodeVer = (& node --version 2>$null | Out-String).Trim()
    Write-Host "Node: $nodeVer"
} else {
    Write-Warn 'node not found on PATH (will be auto-installed in Phase 1 if needed).'
}
$npx = Find-Npx
if ($npx) { Write-Host "npx: $($npx.Source)" }
else { Write-Warn 'npx not found (will be auto-installed together with Node.js in Phase 1).' }

Write-Host 'Checking network reachability of open.feishu.cn ...'
$netOk = $false
try {
    $r = Invoke-WebRequest -Uri "https://$($Brand).cn" -Method Head -TimeoutSec 10 -UseBasicParsing
    $netOk = ($null -ne $r)
} catch {
    $netOk = $false
}
if ($netOk) { Write-Ok 'Network reachable.' }
else { Write-Warn 'Cannot reach Feishu Open Platform (may be offline / proxy). Later steps will show clearer errors.' }

# ---------------------------------------------------------------------------
# Phase 1: lark-cli
# ---------------------------------------------------------------------------
Write-Step 'Phase 1/6 - lark-cli binary'
$cliFound = Resolve-LarkCli
if (-not $cliFound) {
    if ($CheckOnly) {
        Write-Fail 'lark-cli is NOT installed (would install via: npx @larksuite/cli@latest install).'
    } else {
        if (-not (Ensure-Node)) {
            Write-Fail 'Node.js prerequisite missing; aborting. Install Node.js from https://nodejs.org and rerun.'
            exit 1
        }
        Install-LarkCli
    }
} else {
    Write-Ok "lark-cli found: $script:LarkCliBin"
    Invoke-Lark --version
    $ver = ($script:LarkOutput -replace 'lark-cli version ', '').Trim()
    Write-Host "Version: $ver"
}

if (-not $script:LarkCliBin) {
    Write-Fail 'lark-cli not available; aborting before report generation.'
    exit 1
}

Invoke-Lark doctor
$doctor = Get-LarkJson
$updateAvailable = $false
if ($doctor) {
    foreach ($c in @($doctor.checks)) {
        $n = Get-JsonProp $c 'name'
        $s = Get-JsonProp $c 'status'
        if ($n -eq 'cli_update' -and $s -eq 'warn') { $updateAvailable = $true }
    }
}
if ($updateAvailable) {
    if ($CheckOnly) {
        Write-Warn 'A newer lark-cli version is available (run `lark-cli update`).'
    } elseif ($SkipUpdate) {
        Write-Warn 'A newer lark-cli version is available (skipped due to -SkipUpdate).'
    } else {
        Write-Host 'Updating lark-cli ...' -ForegroundColor Yellow
        Invoke-Lark update
        if ($script:LarkExit -eq 0) { Write-Ok 'lark-cli updated.' }
        else { Write-Warn 'lark-cli update failed; continuing with current version.' }
    }
} else {
    Write-Ok 'lark-cli is up to date.'
}

# ---------------------------------------------------------------------------
# Phase 2: App config
# ---------------------------------------------------------------------------
Write-Step 'Phase 2/6 - App configuration'
Invoke-Lark config show
$hasConfig = ($script:LarkExit -eq 0)
$configAppId = $null
if ($hasConfig) {
    $m = [regex]::Match($script:LarkOutput, '"appId":\s*"([^"]+)"')
    if ($m.Success) { $configAppId = $m.Groups[1].Value }
    Write-Ok "App config found. AppId: $configAppId"
} else {
    Write-Warn 'No app configuration found.'
    if ($CheckOnly) {
        Write-Fail 'Config missing (would run `lark-cli config init`). Report generation will be skipped.'
    } else {
        if ($AppId -and $AppSecret) {
            Write-Host 'Initializing config with provided AppId/AppSecret ...' -ForegroundColor Yellow
            $AppSecret | & $script:LarkCliBin config init --app-id $AppId --app-secret-stdin --brand $Brand
            if ($LASTEXITCODE -eq 0) { $configAppId = $AppId; Write-Ok 'Config initialized.' }
            else { Write-Fail 'Config init failed; check AppId/AppSecret.' }
        } elseif ($NewApp) {
            Write-Host 'Creating a new Feishu app (follow the browser flow) ...' -ForegroundColor Yellow
            & $script:LarkCliBin config init --new --brand $Brand --force-init
            if ($LASTEXITCODE -eq 0) { Write-Ok 'New app created and configured.' }
            else { Write-Fail 'New app creation flow failed or was cancelled.' }
        } else {
                $ans = Read-UserInput 'No app found on this machine. Auto-create a new Feishu app now (one browser authorization)? [Y/n]'
            if ($ans -and $ans -notmatch '^[nN]') {
                Write-Host 'Creating a new Feishu app (browser flow; finish the authorization once)...' -ForegroundColor Yellow
                & $script:LarkCliBin config init --new --brand $Brand --force-init
                if ($LASTEXITCODE -eq 0) {
                    Invoke-Lark config show
                    if ($script:LarkExit -eq 0) {
                        $m3 = [regex]::Match($script:LarkOutput, '"appId":\s*"([^"]+)"')
                        if ($m3.Success) {
                            $configAppId = $m3.Groups[1].Value
                            Write-Ok "New app configured. AppId: $configAppId"
                        }
                    }
                }
                if (-not $configAppId) { Write-Fail 'New app creation did not produce a valid config.' }
            } else {
                Write-Host 'Using your existing app. Get AppId/AppSecret at: https://open.feishu.cn -> developer console -> your app -> Credentials & Basic Info.' -ForegroundColor Yellow
                $appIdInput = Read-UserInput 'Enter App ID'
                if ([string]::IsNullOrWhiteSpace($appIdInput)) {
                    Write-Fail 'No App ID entered.'
                } else {
                    Show-AppSecretGuidance -ForWhat '（lark-cli 应用配置）'
                    Write-Host '(输入时会明文显示；也可改用 -AppId/-AppSecret 参数避免交互输入)' -ForegroundColor Yellow
                    $appSecretInput = Read-UserInput 'Enter App Secret'
                    if ([string]::IsNullOrWhiteSpace($appSecretInput)) {
                        Write-Fail 'No App Secret entered.'
                    } else {
                        Write-Host 'Initializing config with the entered credentials ...' -ForegroundColor Yellow
                        $appSecretInput | & $script:LarkCliBin config init --app-id $appIdInput --app-secret-stdin --brand $Brand
                        if ($LASTEXITCODE -eq 0) {
                            $configAppId = $appIdInput
                            Write-Ok "Config initialized. AppId: $configAppId"
                        } else { Write-Fail 'Config init failed; check AppId/AppSecret.' }
                    }
                }
            }
        }
        if (-not $configAppId) { Write-Fail 'Still no valid app config; aborting before report generation.'; exit 1 }
    }
}

# ---------------------------------------------------------------------------
# Phase 3: Auth
# ---------------------------------------------------------------------------
Write-Step 'Phase 3/6 - Authentication'
$st = $null
if ($hasConfig -or $configAppId) {
    Invoke-Lark auth status --json --verify
    $st = Get-LarkJson
}
$botStatus   = Get-JsonProp $st 'identities.bot.status'
$botAppName  = Get-JsonProp $st 'identities.bot.appName'
$userToken   = Get-JsonProp $st 'identities.user.tokenStatus'
$userName    = Get-JsonProp $st 'identities.user.userName'
$userOpenId  = Get-JsonProp $st 'identities.user.openId'
$userScope   = Get-JsonProp $st 'identities.user.scope'
$appId       = Get-JsonProp $st 'appId'
if (-not $appId) { $appId = $configAppId }

if ($st -and $userToken -eq 'valid') {
    if ($botStatus) {
        Write-Ok "Bot identity: $botStatus ($botAppName)"
    } else {
        Write-Warn "Bot identity: $botStatus (bot scopes may need enabling in the developer console)"
    }
    if ($userToken -eq 'valid') {
        Write-Ok "User identity: $userName ($userOpenId), token valid"
        # Some app-enabled scopes may not be user-consented yet (new scopes
        # added after the last login). Offer one consolidated re-authorization.
        Invoke-Lark auth scopes --format json
        $scCov = Get-LarkJson
        $enabledTmp  = @(if ($scCov -and $scCov.userScopes) { @($scCov.userScopes) } else { @() })
        $grantedTmp  = @(if ($userScope) { @($userScope -Split '\s+') } else { @() })
        $missingCov  = @($enabledTmp | Where-Object { $_ -and ($grantedTmp -notcontains $_) })
        if ($missingCov.Count -gt 0) {
            Write-Warn "$($missingCov.Count) app scopes are enabled but not yet authorized by the user."
            if ($CheckOnly -or $SkipLogin) {
                Write-Host '  Fix later with: lark-cli auth login --domain all' -ForegroundColor Yellow
            } else {
                $statePath = Join-Path $HOME '.lark-cli\codex-setup-state.json'
                $curHash = (($missingCov | Sort-Object) -join '|')
                $lastHash = $null
                if (Test-Path -LiteralPath $statePath) {
                    try { $lastHash = [string]((Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json).missingScopeHash) } catch { }
                }
                if ($lastHash -ne $curHash) {
                    $ans = Read-UserInput "Re-authorize now to grant all $($missingCov.Count) missing scopes? [Y/n]"
                    if ($ans -and $ans -notmatch '^[nN]') {
                        $ok = Invoke-UserLogin -LoginDomains $Domains
                        if ($ok) {
                            Invoke-Lark auth status --json --verify
                            $st = Get-LarkJson
                            $userToken = Get-JsonProp $st 'identities.user.tokenStatus'
                            $userScope = Get-JsonProp $st 'identities.user.scope'
                        }
                    } else {
                        Write-Host 'Skipped; missing scopes are listed in the final permission report.' -ForegroundColor Yellow
                    }
                    try {
                        $state = @{ missingScopeHash = $curHash } | ConvertTo-Json
                        Set-Content -LiteralPath $statePath -Value $state -Encoding UTF8
                    } catch { }
                } else {
                    Write-Host "缺失权限与上次运行相同（$($missingCov.Count) 项），不再重复询问。需要补充时可运行：lark-cli auth login --domain all" -ForegroundColor Yellow
                }
            }
        } else {
            Write-Ok 'All app-enabled scopes are authorized by the user.'
        }
    } else {
        Write-Warn "User identity: $userName, token status: $userToken"
        if ($CheckOnly -or $SkipLogin) {
            Write-Warn 'User login skipped (would run: lark-cli auth login --domain all).'
        } else {
            $ok = Invoke-UserLogin -LoginDomains $Domains
            if ($ok) {
                Invoke-Lark auth status --json --verify
                $st = Get-LarkJson
                $userToken = Get-JsonProp $st 'identities.user.tokenStatus'
                $userScope = Get-JsonProp $st 'identities.user.scope'
            }
        }
    }
} else {
    Write-Warn "User identity: $userName, token status: $userToken (需重新授权才会通过)"
    if (-not ($CheckOnly -or $SkipLogin)) {
        $ok = Invoke-UserLogin -LoginDomains $Domains
        if ($ok) {
            Invoke-Lark auth status --json --verify
            $st = Get-LarkJson
            $userToken = Get-JsonProp $st 'identities.user.tokenStatus'
            $userScope = Get-JsonProp $st 'identities.user.scope'
        }
    }
}

# ---------------------------------------------------------------------------
# Phase 4: Codex skills
# ---------------------------------------------------------------------------
Write-Step 'Phase 4/7 - Codex integration (skills / sandbox rule / PATH)'
$skillsOk = Test-SkillsInstalled
if ($skillsOk) {
    Write-Ok 'Codex lark skills already installed.'
} else {
    Write-Warn 'Codex lark skills not found.'
    if ($CheckOnly) {
        Write-Warn 'Would install: npx skills add larksuite/cli -y -g'
    } elseif ($SkipSkills) {
        Write-Warn 'Skipped due to -SkipSkills.'
    } else {
        if (-not (Test-NodeReady)) {
            if (-not (Ensure-Node)) { Write-Warn 'Node.js missing; skills install skipped.' }
        }
        if (Test-NodeReady) {
            try { Install-Skills } catch { Write-Fail $_.Exception.Message }
        }
    }
}

Ensure-CodexRule
Ensure-NpmOnPath

# ---------------------------------------------------------------------------
# Phase 5: Verify (immediately usable)
# ---------------------------------------------------------------------------
Write-Step 'Phase 5/7 - Usability verification'

if ($doctor) {
    foreach ($c in @($doctor.checks)) {
        $n = Get-JsonProp $c 'name'
        $s = Get-JsonProp $c 'status'
        $msg = Get-JsonProp $c 'message'
        if ($s -eq 'fail') { Write-Fail "doctor.$n : $msg" }
        elseif ($s -eq 'warn') { Write-Warn "doctor.$n : $msg" }
    }
    Write-Ok 'doctor checks completed.'
} else {
    Write-Warn 'doctor output could not be parsed.'
}

$userScopeSet = @{}
if ($userScope) {
    @($userScope -Split '\s+') | ForEach-Object { if ($_) { $userScopeSet[$_] = $true } }
}

$enabledSet = @{}
$enabledCount = 0
Invoke-Lark auth scopes --format json
$sc = Get-LarkJson
if ($sc -and $sc.userScopes) {
    @($sc.userScopes) | ForEach-Object { $enabledSet[$_] = $true; $enabledCount++ }
}

Write-Host ''
Write-Host 'Domain coverage (representative scopes):'
$rep = @{
    calendar   = 'calendar:calendar:read'
    im         = 'im:chat:read'
    task       = 'task:task:read'
    docs       = 'docx:document:readonly'
    drive      = 'drive:drive.metadata:readonly'
    contact    = 'contact:user.basic_profile:readonly'
    base       = 'base:table:read'
    sheets     = 'sheets:spreadsheet:read'
    wiki       = 'wiki:node:read'
    mail       = 'mail:user_mailbox:readonly'
    approval   = 'approval:task:read'
    minutes    = 'minutes:minutes.basic:read'
    vc         = 'vc:record:readonly'
    okr        = 'okr:okr.content:readonly'
    mindnote   = 'mindnote:node:read'
    attendance = 'attendance:task:readonly'
    slides     = 'slides:presentation:read'
    board      = 'board:whiteboard:node:read'
    spark      = 'spark:app:read'
    application = 'application:app_slash_command:read'
    search     = 'search:docs:read'
    profile    = 'profile:user_profile:read'
}
$smokePassed = 0
$smokeTotal  = 0
foreach ($d in ($rep.Keys | Sort-Object)) {
    $scope = $rep[$d]
    if ($enabledSet.ContainsKey($scope)) {
        if ($userScopeSet.ContainsKey($scope)) { Write-Ok ("{0,-12} scope granted" -f $d) }
        else { Write-Warn ("{0,-12} app enabled, user not yet authorized" -f $d) }
    } else {
        Write-Warn ("{0,-12} scope not enabled for this app (see permission report)" -f $d)
    }
}

Write-Host ''
Write-Host 'Read-only smoke tests:'
$smokeTests = @(
    @{ Name = 'calendar'; Args = @('calendar', '+agenda', '--as', 'user') }
    @{ Name = 'im';       Args = @('im', '+chat-list', '--as', 'user') }
    @{ Name = 'task';     Args = @('task', '+get-my-tasks', '--as', 'user') }
    @{ Name = 'docs';     Args = @('docs', '+search', '--query', 'codex', '--as', 'user') }
    @{ Name = 'drive';    Args = @('drive', '+search', '--query', 'codex', '--as', 'user') }
    @{ Name = 'contact';  Args = @('contact', '+get-user', '--as', 'user') }
)
foreach ($t in $smokeTests) {
    $smokeTotal++
    try {
        $smokeArgs = @($t.Args)
        Invoke-Lark @smokeArgs
        if ($script:LarkExit -eq 0) {
            Write-Ok ("{0,-10} OK" -f $t.Name)
            $smokePassed++
        } elseif ($script:LarkOutput -match 'missing_scope|missing scope|missing_scopes') {
            Write-Warn ("{0,-10} missing scope (covered by permission report)" -f $t.Name)
        } else {
            $line = $script:LarkOutput
            $sm = [regex]::Match($line, '\{.*\}', 'Singleline')
            if ($sm.Success) {
                try {
                    $sj = $sm.Value | ConvertFrom-Json
                    $errMsg = Get-JsonProp $sj 'error.message'
                    if (-not $errMsg) { $errMsg = Get-JsonProp $sj 'error.subtype' }
                    if ($errMsg) { $line = $errMsg }
                } catch { }
            }
            $line = ($line -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1)
            if ($line -and $line.Length -gt 160) { $line = $line.Substring(0, 160) }
            Write-Fail ("{0,-10} {1}" -f $t.Name, $line)
        }
    } catch {
        Write-Fail ("{0,-10} {1}" -f $t.Name, $_.Exception.Message)
    }
}
Write-Host ''
if ($smokeTotal -gt 0 -and $smokePassed -eq $smokeTotal) {
    Write-Ok "All $smokeTotal smoke tests passed - lark-cli is immediately usable."
} else {
    Write-Warn "Smoke tests: $smokePassed/$smokeTotal passed. Missing scopes are consolidated in the permission report below."
}

$ccStatus = 'skipped (-SkipCcConnect)'
# ---------------------------------------------------------------------------
# Phase 6: cc-connect integration (default on; -SkipCcConnect to disable)
# Reuses the SAME Feishu app as lark-cli. No additional permission request:
# the single consolidated permission application (Phase 7) covers everything.
# ---------------------------------------------------------------------------
if (-not $SkipCcConnect) {
    Write-Step 'Phase 6/7 - cc-connect integration (Feishu remote -> Codex CLI)'
    if ($CheckOnly) {
        $ccStatus = 'would install (CheckOnly)'
        Write-Warn 'Would: install cc-connect + Codex CLI, write ~/.cc-connect/config.toml with the same app, install Windows service.'
    } elseif (-not (Ensure-CcConnect)) {
        $ccStatus = 'failed (cc-connect not available)'
        Write-Fail 'cc-connect not available; skipping project setup.'
    } elseif (-not (Ensure-CodexCli)) {
        $ccStatus = 'failed (Codex CLI not available)'
        Write-Fail 'Codex CLI not available; cc-connect needs a spawnable codex CLI.'
    } else {
        $ccSecret = $AppSecret
        if (-not $ccSecret -and (Get-Variable -Name appSecretInput -ErrorAction SilentlyContinue)) {
            $ccSecret = $appSecretInput
        }
        if (-not $ccSecret) {
            Write-Host 'cc-connect needs the AppSecret of the SAME Feishu app. It is stored in plaintext at ~/.cc-connect/config.toml.' -ForegroundColor Yellow
            Show-AppSecretGuidance -ForWhat '（cc-connect 接入）'
            Write-Host '(输入时会明文显示；也可用 -AppSecret 参数避免交互输入)' -ForegroundColor Yellow
            $ccSecret = Read-UserInput 'Enter App Secret for cc-connect'
        }
        if (-not $ccSecret) {
            $ccStatus = 'failed (no App Secret)'
            Write-Fail 'No App Secret; cc-connect project setup skipped.'
        } elseif (-not $appId) {
            $ccStatus = 'failed (no app id)'
            Write-Fail 'No app id; configure the Feishu app first.'
        } else {
            if (Install-CcConnectProject -AppIdValue $appId -SecretValue $ccSecret) {
                $ccStatus = 'installed & running'
                Write-Ok 'cc-connect is running as a Windows service. Test: message the bot in Feishu.'
            } else {
                $ccStatus = 'failed (see details above)'
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Phase 7: Permission application report (LAST - one consolidated request)
# ---------------------------------------------------------------------------
Write-Step 'Phase 7/7 - Full permission application report'
if (-not $appId) {
    Write-Warn 'No app id available; skipping report generation. Configure the app and rerun.'
} else {
    $labels = @{}
    $lbl = $null
    $labelFile = Join-Path $script:BaseDir 'lark-domain-labels.json'
    if (Test-Path -LiteralPath $labelFile) {
        try {
            $lbl = Get-Content -LiteralPath $labelFile -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch { Write-Warn 'Could not load domain labels file; using raw domain names.' }
    } else {
        try {
            $lbl = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script:EmbeddedLabelsB64)) | ConvertFrom-Json
        } catch { Write-Warn 'Could not decode embedded domain labels; using raw domain names.' }
    }
    if ($lbl -and $lbl.labels) {
        foreach ($p in $lbl.labels.PSObject.Properties) { $labels[$p.Name] = [string]$p.Value }
    }
    $statusGranted = 'granted'
    $statusEnabled = 'enabled'
    $statusMissing = 'missing'
    if ($lbl -and $lbl.status) {
        $statusGranted = [string]$lbl.status.granted
        $statusEnabled = [string]$lbl.status.enabled
        $statusMissing = [string]$lbl.status.missing
    }

    $domainGroups = @{}
    foreach ($s in $script:AllScopes) {
        $d = $s
        if ($s -match '^([^:]+):') { $d = $Matches[1] }
        if (-not $domainGroups.ContainsKey($d)) {
            $domainGroups[$d] = @{ All = @(); Enabled = @(); Granted = @() }
        }
        $domainGroups[$d].All += $s
        if ($enabledSet.ContainsKey($s)) { $domainGroups[$d].Enabled += $s }
        if ($userScopeSet.ContainsKey($s)) { $domainGroups[$d].Granted += $s }
    }

    $domainRows = New-Object System.Collections.Generic.List[string]
    foreach ($d in ($domainGroups.Keys | Sort-Object)) {
        $g = $domainGroups[$d]
        $label = if ($labels.ContainsKey($d)) { $labels[$d] } else { '-' }
        $domainRow = '| {0} | {1} | {2} | {3} | {4} |' -f $d, $label, $g.All.Count, $g.Enabled.Count, $g.Granted.Count
        $domainRows.Add($domainRow)
    }

    $scopeRows = New-Object System.Collections.Generic.List[string]
    $adminMissing = 0
    $userMissing  = 0
    foreach ($s in $script:AllScopes) {
        $d = $s
        if ($s -match '^([^:]+):') { $d = $Matches[1] }
        if ($userScopeSet.ContainsKey($s)) {
            $scopeRow = '| {0} | {1} | {2} |' -f $s, $d, $statusGranted
            $scopeRows.Add($scopeRow)
        } elseif ($enabledSet.ContainsKey($s)) {
            $userMissing++
            $scopeRow = '| {0} | {1} | {2} |' -f $s, $d, $statusEnabled
            $scopeRows.Add($scopeRow)
        } else {
            $adminMissing++
            $scopeRow = '| {0} | {1} | {2} |' -f $s, $d, $statusMissing
            $scopeRows.Add($scopeRow)
        }
    }

    $consoleUrl = if ($Brand -eq 'lark') { "https://open.larksuite.com/app/$appId/auth" } else { "https://open.feishu.cn/app/$appId/auth" }
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $appName = $botAppName
    if (-not $appName) { $appName = $appId }

    $tplFile = Join-Path $script:BaseDir 'permission-report-template.md'
    $tpl = $null
    if (Test-Path -LiteralPath $tplFile) {
        $tpl = Get-Content -LiteralPath $tplFile -Raw -Encoding UTF8
    } else {
        try {
            $tpl = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script:EmbeddedTemplateB64))
        } catch { $tpl = $null }
    }
    if (-not $tpl) {
        Write-Warn 'Report template not found; skipped report generation.'
    } else {
        $tpl = $tpl.Replace('{{DATE}}', $stamp)
        $tpl = $tpl.Replace('{{APP_NAME}}', $appName)
        $tpl = $tpl.Replace('{{APP_ID}}', $appId)
        $tpl = $tpl.Replace('{{BRAND}}', $Brand)
        $tpl = $tpl.Replace('{{CONSOLE_URL}}', $consoleUrl)
        $tpl = $tpl.Replace('{{TOTAL_SCOPES}}', "$($script:AllScopes.Count)")
        $tpl = $tpl.Replace('{{ENABLED_COUNT}}', "$enabledCount")
        $tpl = $tpl.Replace('{{GRANTED_COUNT}}', "$($userScopeSet.Count)")
        $tpl = $tpl.Replace('{{ADMIN_MISSING}}', "$adminMissing")
        $tpl = $tpl.Replace('{{USER_MISSING}}', "$userMissing")
        $tpl = $tpl.Replace('{{DOMAIN_SUMMARY_TABLE}}', ($domainRows -join "`n"))
        $tpl = $tpl.Replace('{{SCOPE_TABLE}}', ($scopeRows -join "`n"))
        $reportPath = Join-Path $script:OutDir ("lark-permission-request-" + (Get-Date -Format 'yyyyMMdd-HHmm') + ".md")
        if ($adminMissing -eq 0 -and $userMissing -eq 0) {
            Write-Ok '所有权限已就绪，无需生成申请单。'
        } elseif ($adminMissing -eq 0) {
            Write-Warn "无需管理员审批；还有 $userMissing 项权限待你本人扫码授权（可运行 lark-cli auth login --domain all 补充），本次不生成申请单。"
        } else {
            try {
                Set-Content -LiteralPath $reportPath -Value $tpl -Encoding UTF8
                Write-Ok "Permission report generated: $reportPath"
                Write-Host ''
                Write-Host 'Console URL for the admin:' -ForegroundColor Yellow
                Write-Host $consoleUrl
                Write-Host ''
                Write-Host "Summary: $($script:AllScopes.Count) target scopes | $enabledCount app-enabled | $($userScopeSet.Count) user-granted | $adminMissing need admin approval | $userMissing need user consent" -ForegroundColor Yellow
                Write-Host "Take the report to your leader/admin once; no repeated permission requests needed." -ForegroundColor Yellow
            } catch {
                Write-Fail ("Could not write report: " + $_.Exception.Message)
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
Write-Step 'Summary'
Write-Host "lark-cli      : $script:LarkCliBin"
Write-Host "app id        : $appId"
Write-Host "bot identity  : $botStatus"
Write-Host "user identity : $userToken ($userName)"
Write-Host "skills        : $(if ($skillsOk) { 'installed' } else { 'missing' })"
Write-Host "cc-connect    : $ccStatus"
Write-Host "failures      : $script:FailCount"
Write-Host "warnings      : $script:WarnCount"
if ($CheckOnly) { Write-Host '(CheckOnly mode: no changes were made)' -ForegroundColor Yellow }
if ($script:FailCount -gt 0) { Write-Host 'Some checks failed - see details above.' -ForegroundColor Red }
Write-Host 'Done.'

if (-not [Console]::IsInputRedirected) {
    Read-UserInput '按回车键退出'
}

if ($script:FailCount -gt 0) { exit 1 }
exit 0
