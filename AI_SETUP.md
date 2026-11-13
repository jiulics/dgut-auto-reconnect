# 把项目交给 AI 配置

## 直接复制这段话

把项目目录交给有本地文件/终端权限的 AI，然后发送：

> 请帮我安装配置当前目录的 DGUT Auto Reconnect 项目。先完整阅读 README.md、AI_SETUP.md 和与你将执行的操作有关的脚本，不要假设我装过旧版本。
>
> 先只读检查我的操作系统、项目路径、可用 Python、默认浏览器、系统代理是否启用、项目环境是否存在、端口18761是否被占用，以及已有监控和自启动状态。不要照抄作者电脑的用户名、绝对路径或代理端口。非 Windows 系统请说明不支持，不要强行运行。
>
> 优先使用 setup.ps1 的 Install/Check/Start 操作和项目提供的中文入口，Python 依赖只能装进这个项目的 .venv，不要影响其他开发环境。可以为本项目创建虚拟环境并安装 requirements.txt 中的依赖；安装系统 Python 或其他软件、修改代理、注册自启动之前，请说明具体改动并取得我的同意。
>
> 不读取、导出或上传我的密码、Cookie、代理订阅、密钥或完整认证页面；不要主动断网、退出校园网账号、关闭代理、禁用安全软件、跳过证书校验，或结束不明进程。遇到工具权限/安全策略阻止时停止该操作，说明原因，交给我手动完成，不要换工具绕过限制。
>
> 浏览器扩展安装、站点权限、账号密码和验证码需要我操作时，请给出准确步骤。保留正常工作的配置；检测到不完整环境时不要直接删除。最后分别报告“本地环境就绪、后台运行、OCR可用、页面通信、联网、自启动注册”的证据和未验证项，并给出停止、关闭自启动和代理回滚方法。没有真实成功证据时，不要说已经实现无人值守重连。

AI 不能访问本机时，可把 `setup.ps1 -Action Check -Json` 的结果发给它。**不要整份发送日志、环境变量、代理配置或截图**；先确认里面没有账号、凭据及个人数据。

## 给执行 AI 的工作说明

### 1. 确认范围与环境

- 这是 Windows 用户会话项目，非系统服务，不支持 macOS/Linux 的原生安装。
- 校园认证目标和页面元素为 DGUT 专用，不能宣称自动支持其他学校。
- 运行目录取脚本目录，不取当前终端工作目录；源码备份目录与实际运行目录可能不同。
- 不修改全局执行策略。CMD 入口的 ExecutionPolicy Bypass 仅限当前启动的 PowerShell 进程，不表示可以绕过产品或系统安全限制。
- 对代理只报告启用/例外状态。不要打印 ProxyServer、AutoConfigURL、订阅链接或环境变量中的代理凭据。
- 不通过读取浏览器配置目录来检测 Cookie、密码或扩展账户。默认浏览器的 ProgId 足够用于引导；脚本是否生效以页面心跳/面板为依据。

### 2. 可用入口

在项目目录执行（路径可自行按当前实际目录替换）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -Action Check -Json
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -Action Install
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -Action Start
```

检测不到已有解释器时，先确认实际 Python 可执行文件，再使用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -Action Install -PythonPath "D:\实际安装位置\python.exe"
```

以上路径仅为格式示例，不是可以原样执行的目标。安装器检查现有项目环境、PATH、Python launcher 的已安装列表和标准 Python 注册表记录；不会遍历整块磁盘，不会把 Windows Store 占位程序当作可用 Python。

现有 `.venv` 已可用时跳过安装；损坏时保留并停止，不自动删除。先核实守护是否使用它，在用户同意、停止监控后将其备份到同目录的新名称，再重新安装；不要删除工作区根目录，也不要移动正在使用的环境。

### 3. 浏览器操作是独立步骤

1. 用户在默认浏览器的扩展商店安装 Tampermonkey。
2. 新建脚本，把 `dgut-reconnect.user.js` 全文复制进去，保存并启用。
3. 允许连接 `127.0.0.1`。首次认证由用户在学校页面正常完成。
4. 更新用户应替换已有副本，停用同类旧脚本后刷新；首次安装用户不需要寻找或安装旧版。
5. 不擅自调整浏览器安全设置。安装扩展或软件、登录和验证码操作还须遵循执行平台本身的确认规则；这份说明不替代这些规则。

### 4. 自启动和代理是可选操作

取得用户明确同意后，才能执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\autostart.ps1 -Action Enable
powershell -NoProfile -ExecutionPolicy Bypass -File .\proxy-bypass.ps1
```

自启动仅在当前用户登录后运行，不设置自动登录、不保存 Windows 密码。只在实际运行目录注册；快捷方式目标不匹配时停止，不擅自覆盖。

代理脚本仅增加认证域名的系统例外；不配置 TUN，不更换端口或订阅。不使用代理的人无需执行。

如用户明确希望防止代理客户端覆盖例外，可使用 `proxy-bypass.ps1 -EnableGuard`。它将精确域名的持续维护授权保存在本地策略文件，新版守护只在系统代理启用且例外缺失时修复。`-DisableGuard` 停止维护但保留例外；`-Restore` 同时关闭维护并按备份撤销。不要默认开启该功能，也不要上传策略或配置备份。运行中的代理客户端可能覆盖磁盘配置，不能未经核实就直接编辑其内部配置文件或重启客户端。

### 5. 验收标准

| 层级 | 通过证据 | 不能代替它的现象 |
|---|---|---|
| 本地环境 | Install 报告模型加载成功 | 只有 .venv 文件夹 |
| 后台 | 本目录守护进程存在，状态更新时间持续变化 | 只运行过 start.cmd |
| OCR | health 返回 ready/version=2/offline_ocr，进程归属本目录 | 端口有人监听 |
| 页面通信 | PageHeartbeat=true | 只安装了扩展 |
| 网页可自动操作 | 新版面板未暂停、没有旧版冲突 | 心跳正常但用户已暂停 |
| 联网 | 新鲜状态 Online=true | 点击过登录按钮 |
| 自启动注册 | Registered=true 且 Managed=true，目标正确 | 只有脚本文件 |
| 登录自启验收 | 用户下次正常登录后状态更新、服务启动 | 注册成功但未实际重新登录 |
| 验证码端到端 | 真实掉线后识别、提交，随后联网恢复 | 单张截图OCR正确 |

为了验收不得擅自断网、退出账号或重启电脑。若用户未要求这些操作，在报告中留下端到端未验证项即可。

### 6. 常见失败与处理

- **Python 缺失/版本不合适**：给出 Python 官方下载地址及64位3.10+要求，请用户安装或确认后再安装系统软件。
- **pip 下载失败**：让用户先登录校园网，检查其已有网络/代理；不自动换不可信镜像、不关闭TLS校验、不输出敏感代理配置。
- **端口被占用**：先区分本项目、另一份本项目与其他程序；不杀未知进程、不随意换端口（油猴也固定使用18761）。
- **OCR 不就绪**：检查缺失依赖与 ocr.log 的错误类别，避免上传含个人信息的文件。
- **无网页心跳**：引导打开认证页、检查脚本启用、127.0.0.1权限和标签页休眠。不能据此直接断定安装失败。
- **登录仍失败**：检查网页是否暂停、是否存在旧脚本、验证码类型与账号状态。不要扩大权限或提高提交频率。
- **询问掉线历史**：读取 `network-events.jsonl` 的首次失败、确认与恢复事件。持续时长以采样为准；`ContainsMonitoringGap=true` 时不能说全程断网。旧版本没有记录的起止时间无法补算，不把 OCR 成功等同于联网恢复。
- **安全策略阻止**：报告被阻止的具体操作，由用户在可信终端手动执行。不能尝试不同工具实现相同被阻止的行为。

### 7. 停止、撤销与移除

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -Action Stop
powershell -NoProfile -ExecutionPolicy Bypass -File .\autostart.ps1 -Action Disable
# 仅当本项目曾添加过代理例外，且用户希望撤销时执行
powershell -NoProfile -ExecutionPolicy Bypass -File .\proxy-bypass.ps1 -Restore
```

随后由用户停用油猴脚本。代码和 `.venv` 默认保留；彻底删除前说明目标目录并取得确认，不编写宽泛递归删除命令。不移除系统 Python、其他浏览器扩展或其他项目依赖。

### 8. 开发验证

```powershell
powershell -NoProfile -File .\setup.tests.ps1
powershell -NoProfile -File .\autostart.tests.ps1
powershell -NoProfile -File .\tests.ps1
powershell -NoProfile -File .\network-history.tests.ps1
powershell -NoProfile -File .\proxy-bypass.tests.ps1
node --test .\userscript.test.cjs .\ocr-userscript.test.cjs
.\.venv\Scripts\python.exe -m unittest discover -s . -p test_ocr_service.py
```

执行前审阅测试。自启动测试只使用独立临时文件夹，不修改真实启动目录。测试通过不等同于所有 Windows 版本、浏览器与校园网环境已被验证。
