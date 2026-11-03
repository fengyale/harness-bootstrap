# hooks 说明（可选门禁怎么配；真正的强制门禁是 git pre-commit）

## 一、为什么默认是空的

`.trae/hooks.json` 现在长这样：

```json
{ "hooks": {} }
```

**这是故意的。** 我无法核实 TRAE 官方 hook 的**事件名与字段名**（你只确认了"写在 `.trae/hooks.json` 里、写法与 Claude 类似"）。
如果我把猜的字段名写进去，最坏情况是**配置报错导致 hook 机制整个失效**——那还不如空着。
所以：空壳 = 安全；示例在下面，核对过官方文档再贴进去。

## 二、先理解两层的分工（这条比配置本身重要）

| 门禁 | 放哪 | 依赖 | 可靠性 | 作用 |
| --- | --- | --- | --- | --- |
| **git pre-commit 钩子** | `.git/hooks/pre-commit` | 只依赖 git | **高（工具无关）** | **真正的门禁**：无论改动来自 TRAE、其它 IDE 还是你手敲，提交都过不去 |
| **编辑器 hook** | `.trae/hooks.json` | 依赖 TRAE 的 schema | 中 | **快速反馈**：改完立刻知道，不用等到提交 |

> 所以顺序是：**先装 git pre-commit（已经能用），再考虑 hooks.json。**
> 装 git 钩子：
> ```powershell
> powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install-git-hooks.ps1
> ```

## 三、启用编辑器 hook 的步骤

### 第 1 步：核对官方 schema

打开 TRAE 官方文档，确认这三件事（**不要凭猜**）：

1. `hooks.json` 的**顶层结构**是不是 `{ "hooks": { ... } }`
2. **事件名**有哪些（Claude Code 是 `PreToolUse` / `PostToolUse` / `Stop` 等，TRAE 可能不同）
3. **匹配字段**叫什么（Claude Code 是 `matcher` + `hooks[].type/command`）

### 第 2 步：把示例贴进去

下面这个示例是**按 Claude Code 的写法**给的（结构仅供参考，字段名务必替换成 TRAE 的）：

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/red-line-scan.ps1"
          }
        ]
      }
    ]
  }
}
```

**为什么推荐挂在"改完文件之后"而不是"提交之前"**：

- 挂在提交前 → 你得先写完一堆代码才知道违规，**修起来贵**
- 挂在改完文件后 → 每次编辑立刻知道，**修起来便宜**
- 而且"提交前"这件事 **git pre-commit 已经管了**，不用重复

### 第 3 步：验证它真的生效

1. 在项目里新建一个 `.java` 文件，写一行 `throw new RuntimeException();`
2. 保存 → **应该立刻弹出红线告警**，且阻止继续
3. 删掉那行 → 告警消失

**如果没有任何反应**：说明 schema 不对，或者 TRAE 需要重启。先把 `hooks.json` 恢复成 `{ "hooks": {} }`，别让它挡着你干活。

## 四、两条纪律

1. **只把"能被脚本确定性判定"的检查放进 hooks。**
   语义级检查（"这个消费者幂等键选错了吗"）交给 `red-line-auditor` 智能体——放进 hooks 只会随机拦人，久了你就想把它关掉。
2. **hook 里的命令必须先在终端手工跑通。**
   没跑通就挂上去，等于给自己装了一个随机失败的提交按钮。
