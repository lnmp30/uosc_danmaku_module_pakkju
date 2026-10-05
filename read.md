# 使用说明 · 给 uosc_danmaku 加上 pakku 弹幕合并

> 这份文档面向**使用者**，不需要懂代码，照着改一行配置就能用。
> 想了解实现原理请看 [`project.md`](project.md)，版本改动看 [`changelog.md`](changelog.md)。

---

## 0. 出处

本项目的**需求来源与算法说明**出自下面这篇博客文章：

| 项目 | 内容 |
|---|---|
| 标题 | 在 uosc_danmaku 中集成 pakkujs 弹幕合并算法 |
| 作者站点 | [blog.episvr.top](https://blog.episvr.top) |
| 原文地址 | **<https://blog.episvr.top/2026/06/29/uosc_danmaku-pakkujs/>** |
| 本地存档 | `在 uosc_danmaku 中集成 pakkujs 弹幕合并算法.md`（工作区根目录，含原文配图） |
| 参考实现 | [xmcp/pakku.js](https://github.com/xmcp/pakku.js) —— 算法、拼音字典与默认配置均取自这里 |
| 宿主插件 | [Tony15246/uosc_danmaku](https://github.com/Tony15246/uosc_danmaku) |

本文档只描述**本项目做了哪些取舍、怎么用**；
算法的原理推导（编辑距离、拼音距离、余弦相似度、滑动窗口聚类）
请直接看上面那篇博客，这里不重复。

---

## 1. 它能做什么

B 站网页版有个很有名的扩展叫 **pakku.js**，专门用来把刷屏的重复弹幕合并成一条。
但 mpv 里的弹幕插件 **uosc_danmaku** 只有「文本完全一样」才能合并，
稍微改一个字就合不了：

| 弹幕原文 | uosc_danmaku 自带合并 | 加上 pakku 之后 |
|---|---|---|
| `完结撒花` `完结撒花` `完结撒花` | ✅ 合成一条 | ✅ 合成一条 |
| `完结撒花` `完结撒花！！！` `完结撒花~` | ❌ 各显示各的 | ✅ 合成一条 |
| `哈哈哈哈` `哈哈哈哈啊` | ❌ | ✅ 合成一条（编辑距离） |
| `在吗` `再吗` | ❌ | ✅ 合成一条（拼音相同） |
| `好看` `好看啊` | ❌ | ✅ 合成一条（余弦相似） |

合并后会在末尾标上合并条数，样式**和 pakku.js 一致** —— 下标数字加下标括号：

```
完结撒花₍₁₂₎
👍👍👍👍👍👍👍👍👍👍₍₆₉₎
kksk₍₄₆₎
```

- 是**下标**数字，没有 `x`，也没有方括号
- 标记是**粗体**，不是斜体；字号单独做过补偿，看起来和正文数字一样大
  （下标字形天生只有正文数字的一半高，所以默认放大了 1.8 倍，可调）
- 合并得越多，这条弹幕在屏幕上**显示得越大**（默认最多放大到 2 倍），
  让真正的热门弹幕更醒目

> 标记的位置与 pakku.js 略有不同：pakku.js 默认标在弹幕**开头**，
> 本项目标在**末尾**。内容（`₍₁₂₎`）完全一样。
> 想改成开头：`pakku_mark=prefix`。

---

## 2. 环境要求

- mpv（本项目在 **v0.41.0** 上验证，任意带 Lua 支持的版本都可以）
- 已安装 [uosc_danmaku](https://github.com/Tony15246/uosc_danmaku) 插件
- 文件必须是 **UTF-8 编码 + Unix 换行（LF）**，否则 mpv 读不出中文
- 字体需要覆盖下标码位（`U+2080-2089`、`U+208D-E`）。
  Microsoft YaHei、Noto Sans CJK 都可以；换字体后如果标记显示成方框，
  把 `pakku_mark_subscript=no` 即可切回 `[x12]` 样式

---

## 3. 安装

把两个东西放到你的 mpv 配置目录里（`portable_config/` 或 `%APPDATA%/mpv/`）：

```
<配置目录>/
├── scripts/uosc_danmaku/modules/pakku.lua      ← 新增这个文件
└── script-opts/uosc_danmaku.conf               ← 把 pakku 选项段追加进去
```

`pakku.lua` 是一个独立模块，**不修改** uosc_danmaku 之外的任何东西。
但它需要 uosc_danmaku 的 `parse.lua` / `options.lua` / `main.lua` 里那几处接入代码，
所以最省事的做法是直接使用本项目 `portable_config/` 里的完整 `uosc_danmaku` 目录。

如果只想给现有安装打补丁，参考 `project.md` §3 的改动清单（4 个文件各改一处 + 1 个新增模块）。

---

## 4. 开启

打开 `script-opts/uosc_danmaku.conf`，找到 pakku 段：

```ini
pakku_enable=yes
```

- **本项目自带的配置文件里已经打开**，装好即用，无需改动
- 如果你的 conf 里这行是 `#pakku_enable=yes`（被注释掉了），把 `#` 去掉即可
- 想彻底关掉就改成 `pakku_enable=no`

存盘，重启 mpv。

> 下面所有 pakku 选项本项目都采用了 **pakku.js 的官方默认值**，
> 并且已经写进 conf 里显式列出（不是注释掉的状态），方便你按需改。

---

## 5. 效果确认

开启后可以看 mpv 的日志（默认已经输出一条 info）：

```
[uosc_danmaku] 已解析 4884 条弹幕
```

条数比你原来看到的少，说明合并生效了。

想看更详细的过程，用命令行启动 mpv：

```powershell
mpv.exe --msg-level=uosc_danmaku=v "你的视频.mkv"
```

会多出这样的统计行：

```
[uosc_danmaku] pakku: 拼音字典载入 6763 个汉字 / 398 个拼音组
[uosc_danmaku] pakku: 6702 条 -> 4884 条（簇 4884，最多合并 69；
               ==467 ≤1058 P46 247%；丢弃 0，缩小 0，放大 73，耗时 319ms）
```

这一行怎么读：

| 片段 | 含义 |
|---|---|
| `6702 条 -> 4884 条` | 合并前后条数 |
| `最多合并 69` | 最大的一个簇合并了 69 条 |
| `==467` | 有 467 条是靠「文本完全相同」进来的 |
| `≤1058` | 有 1058 条是靠「编辑距离」进来的 |
| `P46` | 有 46 条是靠「拼音」进来的 |
| `247%` | 有 247 条是靠「余弦相似度」进来的 |
| `丢弃 / 缩小 / 放大` | 密度调控与字号放大的命中数 |
| `耗时 319ms` | 整个合并过程花了多久 |

---

## 6. 全部选项

下面所有默认值都等于 **pakku.js 官方 DEFAULT_CONFIG**，
唯一有意不同的是标记的**位置**（pakku.js 标在开头，这里标在末尾）。
改完重启 mpv 生效。

### 6.1 基础

| 选项 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `pakku_enable` | yes/no | `yes` | 总开关。打开后接管 `merge_tolerance` 的合并 |
| `pakku_threshold` | 秒 | `30` | 滑动窗口大小。只有相隔不超过这个秒数的弹幕才会互相比较 |
| `pakku_use_pinyin` | yes/no | `yes` | 是否用拼音判定，关掉就合不了谐音弹幕 |

`pakku_threshold=30` 是 pakku.js 的默认，也是几个选项里**最影响耗时**的一个：
它决定了「往前看多久」的弹幕。调到 5 秒能快一倍多，但漏合并也会变多。

### 6.2 判定严格程度（最常调的三个）

| 选项 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `pakku_max_dist` | 整数 | `5` | 编辑距离上限。**调大 = 更容易合并 = 更容易误伤** |
| `pakku_max_cosine` | 0–100 | `45` | 余弦相似度阈值。**调小 = 更容易合并**；填 `101` 可彻底禁用这一级 |
| `pakku_cross_mode` | yes/no | `yes` | 是否允许滚动/顶部/底部弹幕互相合并 |

四级判定按顺序执行，**任意一级命中就合并**，所以想让合并更保守，
需要同时调小 `pakku_max_dist` 和调大 `pakku_max_cosine`。

`pakku_cross_mode=yes` 意味着一条顶部弹幕可能被吸进滚动弹幕的簇里。
关掉它合并会明显变少（实测从 71.5% 升到 76.0%）。

### 6.3 显示样式

| 选项 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `pakku_mark` | 枚举 | `suffix` | 标记位置：`suffix` 末尾（`恭喜₍₁₂₎`）/ `prefix` 开头（`₍₁₂₎恭喜`）/ `off` 不显示 |
| `pakku_mark_subscript` | yes/no | `yes` | 标记是否用下标数字：`yes` → `₍₁₂₎`，`no` → `[x12]` |
| `pakku_mark_scale` | 倍数 | `1.8` | 标记的额外放大倍数，用来补偿下标字形偏小。见下方说明 |
| `pakku_mark_threshold` | 整数 | `1` | 合并条数超过这个值才加标记 |
| `pakku_enlarge` | yes/no | `yes` | 是否按合并条数放大字号 |
| `pakku_enlarge_min_count` | 整数 | `5` | 合并条数超过这个值才开始放大 |
| `pakku_enlarge_max_scale` | 倍数 | `2.0` | 放大上限 |
| `pakku_enlarge_log_base` | 数字 | `5` | 放大曲线的对数底数。默认值下合并 25 条就翻倍，再多也保持 2 倍 |
| `pakku_mode_elevation` | yes/no | `yes` | 簇里混有底部/顶部弹幕时，把整簇提升为更醒目的类型 |
| `pakku_representative_percent` | 0–100 | `20` | 取簇内第百分之几的成员作为代表，决定合并后的时间、颜色、字号 |

标记的四种组合：

| `pakku_mark` | `pakku_mark_subscript` | 效果 |
|---|---|---|
| `suffix`（默认） | `yes`（默认） | `恭喜₍₁₂₎` |
| `suffix` | `no` | `恭喜[x12]` |
| `prefix` | `yes` | `₍₁₂₎恭喜` |
| `off` | — | `恭喜` |

备注：

- 标记在画面上是**粗体**显示（`{\b1}`），不带斜体
- 标记是不是加粗，由 pakku 模块直接告诉渲染层（`merge_mark` 字段），
  不靠正则去猜，所以正文里恰好以 `x12` 结尾的弹幕不会被误加粗
- `pakku_representative_percent` 一般不用动。它取的是一个**簇内**的相对位置：
  合并 N 条时取第 `floor(N × 百分比 ÷ 100) + 1` 条作为代表，
  比如合并了 10 条、取值 20，就取第 3 条的时间点作为这一簇的出现时间

#### 关于 `pakku_mark_scale`（标记偏小的原因）

**pakku.js 并没有给标记单独设字号** —— 它只是把 `₍₁₂₎` 拼到弹幕文本后面，
由播放器按弹幕本身的字号渲染。`₍₁₂₎` 之所以显得小，是因为**下标字形本身就这么小**。

实测 Microsoft YaHei Bold 在同等字号下：

| 内容 | 高度 |
|---|---|
| 正文数字 `0123456789` | 100% |
| 下标数字 `₀₁₂₃₄₅₆₇₈₉` | **55%** |
| 下标括号 `₍₎` | 68% |

所以本项目加了一个补偿倍数 `pakku_mark_scale`，用 ASS 的 `\fs` 单独把标记放大：

| 取值 | 效果 |
|---|---|
| `1` | 不放大，**完全还原 pakku.js 的原始观感**（标记明显偏小） |
| `1.46` | 下标括号与正文数字同高 |
| `1.8`（默认） | 下标数字与正文数字同高，看着就是正常大小的数字 |

标记的放大倍数会跟着弹幕字号走：这条弹幕越大，标记也同比例放大。
`pakku_mark_subscript=no`（用 `[x12]`）时该项自动失效，因为普通字形不需要补偿。

### 6.4 文本预处理

| 选项 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `pakku_trim_ending` | yes/no | `yes` | 去掉末尾标点：`完结撒花！！！` → `完结撒花` |
| `pakku_trim_width` | yes/no | `yes` | 全角半角统一：`ＡＢＣ１２３` → `ABC123` |
| `pakku_trim_space` | yes/no | `yes` | 合并多余空格、去掉汉字之间的空格：`你 好` → `你好` |
| `pakku_normalize_display` | yes/no | `yes` | 合并后显示预处理过的文本。关掉则显示出现最多的**原始**文本 |
| `pakku_forcelist` | JSON | 见下 | 自定义替换规则 |

`pakku_forcelist` 格式是 JSON 数组，每项是 `[模式, 替换]`：

```ini
pakku_forcelist=[["^23{2,}$","23333"],["^6{3,}$","66666"]]
```

- 模式用 **Lua 模式**语法，但额外支持 JS 风格的 `{n}` / `{n,}` / `{n,m}` 量词
- 上面两条的效果：把「2333333…」统一成「23333」，「6666666…」统一成「66666」
- 命中后**所有**规则都会依次尝试（对齐 pakku.js 的 `FORCELIST_CONTINUE_ON_MATCH`）
- 注意 Lua 模式里的 `-` 是量词，要匹配字面量横线需要写成 `%-`
- 写错的正则会被告警并跳过，不会崩

### 6.5 密度调控（进阶，默认关闭）

| 选项 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `pakku_shrink_threshold` | 数字 | `0` | 屏幕上累积的「显示价值」超过它就整体缩小字号。`0` = 关闭 |
| `pakku_drop_threshold` | 数字 | `0` | 超过它就按权重丢弃低优先级弹幕。`0` = 关闭 |

⚠️ **这两个值需要按自己的字号调。** pakku.js 假设基准字号是 25，
而 uosc_danmaku 默认 `fontsize=50`，显示价值会翻倍，
所以阈值也要相应放大，否则一开就会把所有弹幕都缩小/丢掉。

在 3 集合计 20086 条弹幕上的实测（`fontsize=50`，合并后 14366 条）：

| 设置 | 效果 |
|---|---|
| `pakku_shrink_threshold=40` | 几乎全部弹幕缩小（很激进，实测字号落到 29–33px） |
| `pakku_shrink_threshold=200` | 只有 119 条被缩小（约 0.8%），基本无感 |
| `pakku_shrink_threshold=400` | 一条都不缩 |
| `pakku_drop_threshold=200` | 只丢掉 10 条 |
| `pakku_drop_threshold=600` | 一条都不丢 |

也就是说 **200–400 这个区间是「有感但不激进」的量级**。
数字越小越激进。为避免开过头，建议从偏大的值往小调，边调边看日志里的
`丢弃 / 缩小` 计数。

如果已经用 `max_screen_danmaku` 限制了同屏条数，这两个通常不需要开。

---

## 7. 常见场景配方

### 场景 A：还是觉得刷屏，想更激进

当前默认已经是 pakku.js 的推荐值。还想更狠可以把窗口拉长、判定放宽：

```ini
pakku_threshold=60
pakku_max_dist=6
pakku_max_cosine=35
```

代价是耗时翻倍，且可能把剧情推进后的弹幕也合进来。

### 场景 B：担心误伤，只想合并「几乎一模一样」的

```ini
pakku_max_dist=0
pakku_max_cosine=101
pakku_use_pinyin=yes
```

这样只保留「完全相同」和「拼音完全相同（谐音）」两种合并。
实测 20086 条会合到 17665 条（87.9%）。

### 场景 C：只想在同一类型的弹幕内部合并

```ini
pakku_cross_mode=no
```

实测 20086 条会合到 15273 条（76.0%，比开着的 71.5% 少合一些）。

### 场景 D：觉得耗时长，想快一点

```ini
pakku_threshold=10
```

耗时大约砍掉一半（每集 319ms → 181ms），代价是合并率从 71.5% 降到 76.4%。

### 场景 E：关掉字号放大，保持字号统一

```ini
pakku_enlarge=no
```

### 场景 F：不想看到 `₍₁₂₎` 这种标记

```ini
pakku_mark=off
```

只想在合并很多条时才显示：

```ini
pakku_mark_threshold=5
```

标记改成 pakku.js 的**开头**位置（默认在末尾）：

```ini
pakku_mark=prefix
```

### 场景 G：标记看着太大或太小

默认 `pakku_mark_scale=1.8`，让下标数字和正文数字一样高。想调节：

```ini
pakku_mark_scale=1.46   ; 下标括号与正文数字同高，比默认小一点
pakku_mark_scale=1      ; 完全还原 pakku.js 的原始观感（标记很小）
pakku_mark_scale=2.2    ; 比正文数字还大，非常醒目
```

### 场景 H：字体不支持下标，标记显示成方框

```ini
pakku_mark_subscript=no
```

标记会退回 `[x12]` 的形式（此时 `pakku_mark_scale` 不再生效）。

### 场景 I：合并后文本被改了，想保留原文

```ini
pakku_normalize_display=no
```

---

## 8. 和 `merge_tolerance` 的关系

`merge_tolerance` 是 uosc_danmaku 自带的合并选项（本项目 conf 里默认是 `5`）。

**两者互斥**：

- `pakku_enable=no` → 用 `merge_tolerance`，行为完全不变
- `pakku_enable=yes` → 用 pakku，`merge_tolerance` 被忽略

同样，`merge_fontsize_growth` / `merge_fontsize_max` 在 pakku 模式下也不生效，
字号改由 `pakku_enlarge_*` 系列控制。

`max_screen_danmaku`（同屏条数限制）**两者都生效**，是在合并之后才执行的。

---

## 9. 常见问题

**Q：后缀为什么曾经是斜体？**
A：旧版本把加粗标记写成 `{\b1\i1}`，`\i1` 就是斜体。现在只加粗（`{\b1}`），
**不会再斜**。升级后如果还看到斜体，确认 `parse.lua` 里插的是 `{\\b1}`。

**Q：后缀为什么是 `₍₁₂₎` 这种小字？**
A：这是 pakku.js 的默认样式（`DANMU_SUBSCRIPT=on`），用下标数字加下标括号表示合并条数。
本项目与它保持一致。想换成 `[x12]` 就把 `pakku_mark_subscript` 改成 `no`。

**Q：`₍₁₂₎` 看着太小了，能调大吗？**
A：可以，`pakku_mark_scale`，默认 `1.8`（下标数字与正文数字同高）。
注意 pakku.js 本身**没有**给标记设字号，小是下标字形的固有属性，
所以这一项是本项目加的补偿，调到 `1` 就是 pakku.js 的原始观感。
详见 §6.3。

**Q：标记能不能放在开头？**
A：可以，`pakku_mark=prefix`，这就是 pakku.js 的原始默认位置。

**Q：开了之后弹幕数量没变？**
A：确认改的是 mpv 实际读取的那个 `uosc_danmaku.conf`。
如果你同时有 `portable_config/` 和 `%APPDATA%/mpv/`，mpv 优先用 `portable_config/`。
用 `--msg-level=uosc_danmaku=v` 看有没有 `pakku: 拼音字典载入` 这行。

**Q：合并得太狠了，很多不相干的弹幕被合到一起。**
A：调小 `pakku_max_dist`（比如 3 或 2），调大 `pakku_max_cosine`（比如 70）。
也可以把 `pakku_cross_mode` 关掉，避免跨类型吸走弹幕。

**Q：合并得不够，还是刷屏。**
A：调大 `pakku_max_dist`（6）、调小 `pakku_max_cosine`（35）、调大 `pakku_threshold`（60）。

**Q：某些弹幕的字变了。**
A：那是文本预处理在起作用（去掉末尾标点、全角转半角）。
想显示原文就把 `pakku_normalize_display=no`（合并后显示出现最多的原始文本）。

**Q：日文/英文弹幕被改得怪怪的。**
A：预处理里的全角半角归一也会作用于英文和符号。
介意的话关掉 `pakku_trim_width`（注意这会影响相似判定的结果，不只是显示）。

**Q：弹幕变得很大/很小。**
A：大是 `pakku_enlarge`（默认合并 25 条就翻倍），小是 `pakku_shrink_threshold` 在起作用。
分别关掉即可。

**Q：会不会拖慢播放？**
A：不会。合并在弹幕加载时一次性完成，一集约 320ms，之后播放过程中零开销。

**Q：支持哪些弹幕类型？**
A：滚动（1/2/3）、底部（4）、顶部（5）会参与合并。
逆向（6）、高级（7）、代码（8/9）弹幕原样透传不做合并。

---

## 10. 排查问题

1. **确认脚本加载了**

   ```powershell
   mpv.exe --msg-level=all=v "视频.mkv" 2>&1 | Select-String "uosc_danmaku"
   ```

   应该能看到 `Loading lua script .../uosc_danmaku/main.lua`。

2. **确认 pakku 生效了**

   在上面输出里找 `pakku: 拼音字典载入 6763 个汉字 / 398 个拼音组`。
   没有这行说明 pakku 根本没被调用，检查 `pakku_enable=yes` 是否写对、
   conf 文件的编码是不是 UTF-8。

3. **确认本地弹幕被加载了**

   uosc_danmaku 自动加载本地弹幕有两个前提：

   - 视频时长 **≥ 60 秒**（源码里的硬性判断）
   - 弹幕文件必须叫 `<视频文件名不含扩展名>.xml`，放在视频同目录

   另外 `danmaku-history.json` 里的 `show_danmaku` 必须是 `true`
   （在 uosc 界面上点一下弹幕按钮切换即可）。

4. **标记显示成方框**

   说明当前字体没有下标字形。用 `--msg-level=all=v` 启动，
   在日志里搜 `Glyph` 看有没有 libass 的缺字形告警。
   解决办法：`pakku_mark_subscript=no`，或换一个覆盖
   Superscripts and Subscripts 区段的字体。

5. **标记大小不合适**

   调 `pakku_mark_scale`（默认 `1.8`）。`1` = pakku.js 原始大小，
   `1.46` = 下标括号与正文数字同高。详细对照见 §6.3。

6. **开日志文件**

   ```powershell
   mpv.exe --log-file=mpv.log "视频.mkv"
   ```

7. **怀疑是 pakku 引起的卡顿或异常**

   把 `pakku_enable` 改成 `no` 对比一下。两者行为差异只应该在「合并了什么」上。

---

## 11. 关闭 / 卸载

- **临时关闭**：`pakku_enable=no`
- **完全卸载**：删掉 `scripts/uosc_danmaku/modules/pakku.lua`，
  并把 `parse.lua` / `options.lua` / `main.lua` / `uosc_danmaku.conf` 里的 pakku
  相关代码去掉（参考 `project.md` §3 的改动清单）

因为是纯新增模块 + 4 处条件分支，回滚不会影响 uosc_danmaku 的其它功能。

---

## 12. 性能参考

在 3 集真实弹幕（合计 20086 条）上的实测，mpv v0.41.0 / LuaJIT，
`fontsize=50`，其余为当前默认值：

| 配置 | 合并结果 | 平均耗时 |
|---|---|---|
| 关闭 | 20086 → 20086 | 0 ms |
| **默认（`threshold=30` `dist=5` `cos=45` `cross=yes`）** | **20086 → 14366（71.5%）** | **~319 ms/集** |
| `threshold=10` | 20086 → 15340（76.4%） | ~181 ms/集 |
| `threshold=5` | 20086 → 16216（80.7%） | ~141 ms/集 |
| 保守（`dist=3` `cos=70`） | 20086 → 15385（76.6%） | ~292 ms/集 |
| 不跨类型（`cross=no`） | 20086 → 15273（76.0%） | ~256 ms/集 |
| 仅精确 + 拼音（`dist=0` `cos=101`） | 20086 → 17665（87.9%） | ~135 ms/集 |

单集明细：

| 集数 | 原始 | 合并后 | 最大合并 | 耗时 |
|---|---|---|---|---|
| 03 | 6592 | 4773 | ₍₆₀₎ | ~306 ms |
| 04 | 6702 | 4884 | ₍₆₉₎ | ~314 ms |
| 07 | 6792 | 4709 | ₍₄₇₎ | ~307 ms |

耗时发生在**弹幕加载时**（一次性），播放过程中没有额外开销。
拼音字典首次使用时懒加载约 60ms，之后常驻内存。
同一输入重复运行结果完全一致（合并过程是确定性的）。

---

## 13. 致谢与许可

- [pakku.js](https://github.com/xmcp/pakku.js) —— 合并算法、拼音字典与默认配置的来源
- [uosc_danmaku](https://github.com/Tony15246/uosc_danmaku) —— mpv 弹幕插件
- [uosc](https://github.com/tomasklaen/uosc) —— UI 框架
- [在 uosc_danmaku 中集成 pakkujs 弹幕合并算法](https://blog.episvr.top/2026/06/29/uosc_danmaku-pakkujs/)
  —— 本项目的需求来源（出处详见本文 §0）

使用前请一并遵守上述项目的开源许可。
