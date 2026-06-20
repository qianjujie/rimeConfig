# 我的 Rime 配置

这是我的 Rime 配置仓库，基于 [gaboolic/rime-shuangpin-fuzhuma](https://github.com/gaboolic/rime-shuangpin-fuzhuma) 的墨奇音形方案做了个人化调整。

核心目标不是极限简码，而是：

- 小鹤双拼节奏优先，两键一个字，尽量空格上屏
- 常用单字和聊天短语稳定首选
- 保留墨奇辅助码，用来处理冷门字和不好选的字
- 关闭整句语言模型，减少候选被上下文模型重排
- 用 Git 同步配置，但不同步本机生成数据

## 安装路径

macOS 鼠须管：

```text
~/Library/Rime
```

Windows 小狼毫：

```text
%APPDATA%\Rime
```

Linux fcitx5：

```text
~/.local/share/fcitx5/rime
```

部署后在输入法菜单里点“重新部署”。

## 当前启用方案

配置入口是 `default.custom.yaml`：

```yaml
schema_list:
  - schema: moqi_wan_flypymo
  - schema: moqi_wan_flypy
```

主力方案：

- `moqi_wan_flypymo`：墨奇 + 小鹤双拼 + 墨奇形
- `moqi_wan_flypy`：墨奇 + 小鹤双拼 + 鹤形

想启用/隐藏方案，改 `default.custom.yaml` 里的 `schema_list`，然后重新部署。

## 我改了什么

### 1. 让 custom 补丁真正生效

这两个 schema 文件末尾显式加载了自己的 custom 补丁：

- `moqi_wan_flypymo.schema.yaml`
- `moqi_wan_flypy.schema.yaml`

原因：原方案里同名 `*.custom.yaml` 没有稳定进入最终 build，导致重新部署后看起来“不生效”。

### 2. 关闭整句语言模型

在两个 custom 文件里：

```yaml
translator/contextual_suggestions: false
grammar/language: ""
```

效果：

- 候选更接近词库词频和手动置顶表
- 减少 `吗/的/是/了` 这类虚词被整句模型压低
- 长句自动组句能力会弱一些

这符合我的使用方式：更像微信输入法的短节奏输入，而不是打一长串让模型猜整句。

### 3. 调整短码表优先级

在两个 custom 文件里：

```yaml
custom_phrase/initial_quality: 100000
custom_phrase_3_code/initial_quality: -1
```

意思是：

- 保留 `custom_phrase.txt`，用来固定我想要的首选
- 压低 `custom_phrase_3_code`，减少作者预设短码污染候选

### 4. 清理会污染单字首选的短码

在 `custom_phrase/custom_phrase.txt` 里注释了这些作者预设短码：

```text
# 使 ui 3
# 得 de 2
# 乐 le 2
# 骂 ma 2
```

避免：

```text
ma -> 骂
de -> 得
ui -> 使
le -> 乐
```

这种破坏节奏的情况。

### 5. 增加个人节奏首选

在 `custom_phrase/custom_phrase.txt` 末尾有一段：

```text
## 个人节奏首选
```

这里放我希望直接空格上屏的基础字和聊天短语，例如：

```text
吗    ma      100
的    de      100
是    ui      100
了    le      100
是的  uide    100
是吗  uima    100
会吗  hvma    100
好的  hcde    100
收到  uzdc    100
谢谢  xpxp    100
```

## 日常怎么改

### 增加常用聊天短语

编辑：

```text
custom_phrase/custom_phrase.txt
```

找到：

```text
## 个人节奏首选
```

按这个格式加：

```text
词条<Tab>编码<Tab>权重
```

例子：

```text
会吗	hvma	100
没问题	mwwfti	100
知道了	vidcle	100
```

注意中间最好用 Tab，不要用空格。

改完重新部署。

### 调整候选数量

编辑 `default.custom.yaml`：

```yaml
menu/page_size: 6
```

想一页显示 9 个就改成：

```yaml
menu/page_size: 9
```

### 开启用户词库学习

现在是关闭的，保证候选稳定。

如果想让 Rime 学习我的选择，在对应方案 custom 文件里取消注释：

```yaml
translator/enable_user_dict: true
```

文件：

- `moqi_wan_flypymo.custom.yaml`
- `moqi_wan_flypy.custom.yaml`

取舍：

- 开启后会越用越贴合习惯
- 但候选顺序可能随使用变化

### 重新打开语言模型

不推荐，但可以。

把 custom 文件里的：

```yaml
translator/contextual_suggestions: false
grammar/language: ""
```

改回类似：

```yaml
translator/contextual_suggestions: true
grammar/language: zh-moqi
```

效果：

- 长句组句可能更强
- 单字和短回复排序可能再次变差

## 外观主题

macOS 鼠须管外观配置：

```text
squirrel.custom.yaml
```

Windows 小狼毫外观配置：

```text
weasel.custom.yaml
```

当前只保留了 macOS 候选横排：

```yaml
style/candidate_list_layout: linear
```

鼠须管默认主题是：

```yaml
style/color_scheme: native
```

`native` 是鼠须管系统原生配色，不是一个完整写在 YAML 里的颜色表。

## Git 同步规则

这个仓库提交源配置，不提交生成产物和本机状态。

`.gitignore` 已忽略：

```text
build/
*.userdb/
sync/
installation.yaml
user.yaml
```

这些文件不要提交：

- `build/`：重新部署生成
- `*.userdb/`：本机用户词库和学习数据
- `sync/`：Rime 同步数据
- `installation.yaml`：本机安装 ID
- `user.yaml`：当前方案等本机状态

## Windows 使用提示

核心词库、schema、custom phrase 是跨平台的。

macOS 专用：

```text
squirrel.yaml
squirrel.custom.yaml
```

Windows 专用：

```text
weasel.yaml
weasel.custom.yaml
```

如果在 Windows 上只想先使用输入方案和短语排序，可以直接 clone 到 `%APPDATA%\Rime`，重新部署即可。外观主题需要另外写 `weasel.custom.yaml`。

## 常用测试

重新部署后测试：

```text
ma    -> 吗
de    -> 的
ui    -> 是
le    -> 了
uide  -> 是的
uima  -> 是吗
hvma  -> 会吗
hcde  -> 好的
uzdc  -> 收到
```

如果没有变化：

- 确认改的是源文件，不是 `build/`
- 点“重新部署”
- 切换一下方案再切回来
- 重新聚焦输入框

## 上游与许可

本配置基于：

- [gaboolic/rime-shuangpin-fuzhuma](https://github.com/gaboolic/rime-shuangpin-fuzhuma)
- [gaboolic/rime-frost](https://github.com/gaboolic/rime-frost)

原项目许可证保留在 `LICENSE`。
