# Atlas 图集词库（镜头单取词的权威语料）

> 本文件解决一件事：写 `anchors`（角色锚点、场景、光位、质感、负向）时，**词从哪来**。
> 词库实体在 `master/prompt-atlas.json`（279 个可填槽位、7400+ 枚举选项），检索脚本 `scripts/atlas-lookup.ps1`。
> atlas 里的选项是**候选词，不是成品句**；成品句仍要过 SKILL.md 的硬规则（具名、可被画面验证、逐格原句复制）。

## 一、atlas 与镜头单的分工

| 你在写什么 | 词从哪来 |
|---|---|
| `anchors.characters`（长相/发型/服装/标志物） | atlas「主体」「表情情绪大典」「动作与肢体语言」分卷 |
| `anchors.scene` / `blueprint`（场景固定物、材质） | atlas「场景美术」「质感与材质成像」分卷 |
| `anchors.lighting`（光位、光比、色温） | atlas「灯光层」「打光参数配方」分卷 |
| `anchors.style`（风格质感句，对应 `style_preset`） | atlas「①风格母语」「调色层」分卷 |
| 单格 Prompt 的质感/介质句 | atlas「质感与材质成像」「环境介质与影」分卷 |
| `anchors.negative` 四段补充 | atlas「负面词」分卷（先过本技能 `negative_parts` 四段框架） |
| 动态化模式的运镜与运动句 | atlas「运动与时间_视频」「速度与运动感」分卷 |
| `delta` 写不出位移量时找参照 | atlas「动作与肢体语言」（接触点与肢体量词） |

规则：anchors 每一句写完，自造专名 ≤ 20%；能回 atlas 的专名优先回 atlas，不凭空造形容词。

## 二、节点字段协议

atlas 树的叶子形如：

```json
{ "值": "35mm", "_opt": ["14mm", "24mm", "35mm", "50mm", "85mm"], "_en": "35mm lens", "_hint": "环境与人兼顾", "_ref": "卷8" }
```

| 字段 | 用法 |
|---|---|
| `值` | 该槽位当前默认填法；写镜头单时按题材重选 `_opt` |
| `_opt` | 该槽位的全部枚举选项；超出枚举的自创词必须具名且可被画面验证 |
| `_en` | 英文对照；动态化模式的 H3 英文版直接取用 |
| `_hint` | 适用场景提示；拿不准选哪个选项时看它 |
| `_ref` | 溯源卷号；`qa` 字段记录责任句时一并记卷号 |

## 三、检索命令（PowerShell 5.1，无需安装库）

```powershell
# 列出全部分卷与选项规模
& "<skill-dir>\scripts\atlas-lookup.ps1" -Outline

# 列出某分卷下的子节点
& "<skill-dir>\scripts\atlas-lookup.ps1" -Outline -Path "摄影层"

# 取某节点的全部选项（写锚点句前先看这一层）
& "<skill-dir>\scripts\atlas-lookup.ps1" -Path "摄影层/焦段镜头"

# 跨全库模糊搜（中英都命中，最多 40 条）
& "<skill-dir>\scripts\atlas-lookup.ps1" -Query "推轨","dolly","环绕"

# 限定子树搜（写光位句时只在灯光层里找）
& "<skill-dir>\scripts\atlas-lookup.ps1" -Query "轮廓光" -Path "灯光层"
```

## 四、镜头单写作时的取词顺序

1. **先 Outline 定位分卷**：写哪一层锚点，就进对应分卷（见第一节映射表）。
2. **再 -Path 取选项**：把该槽位的 `_opt` 全部过一遍，按故事题材挑 1 个；`_hint` 拿不准时做裁决。
3. **然后组句**：选项是词，句子按本技能规则组——空间蓝图只用固定物坐标、侧位短语逐字复用、状态卡语义正确。
4. **最后记溯源**：`qa` 字段与锚点句旁标注 `_ref` 卷号，复现时能指回语料。

## 五、atlas 顺序 ≠ 提示词顺序

atlas 分卷是词库目录，不是提示词结构。组进单格 Prompt 时必须重排成本技能的正向块十行顺序（画幅／质感／主体绑定／角色锚点／场景／站位／屏幕侧位／比例锚与状态卡／入格状态与本镜动作／出格状态）。**禁止按 atlas 卷号顺序直接拼 Prompt**——那是词库的目录顺序，不是画面的因果顺序。

## 六、纪律

- atlas 的 `_en` 只服务于英文平台壳（动态化模式 H3 版）；Seedance 版、单格分镜图一律中文。
- atlas 不含本技能的衔接规则（delta 四量、in/out_state 接力、screen_side）——这些永远以 SKILL.md 与 continuity.md 为准，atlas 只供词。
- 同一 anchors 句在一版镜头单里只允许一个来源：要么 atlas 原选项组句，要么已标 `[自创]`；不许一半 atlas 一半即兴混着改写。
