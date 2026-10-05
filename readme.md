# uosc_danmaku_module_pakkju

**把 [pakku.js](https://github.com/xmcp/pakku.js) 的弹幕合并算法搬进 mpv 的弹幕插件
[uosc_danmaku](https://github.com/Tony15246/uosc_danmaku)。**

用 mpv 看番时，弹幕刷屏最烦人的不是数量多，而是同一句话被几百人重复发，
还各自带点错别字、谐音、多打的标点，插件按「文本完全相同」根本合不掉。
这个模块能把这些变体认成同一句，合成一条，并标上被合并的次数。

```
完结撒花(12)
👍👍👍👍👍👍👍👍👍👍(69)
kksk(46)
```

- 输出是**普通的半角括号数字**，跟随正文字体，不需要额外字体
- 合并得越多，那条弹幕显示得越大（默认最多放大到 2 倍）
- 默认**开启**，装好后即可用；改成 `pakku_enable=no` 就和以前完全一样

> 算法原理（编辑距离、拼音距离、余弦相似度、滑动窗口聚类）请看出处博客，
> 本文只讲怎么用。出处见文末。

---

## 目录

- [它解决什么问题](#它解决什么问题)
- [快速开始](#快速开始)
- [确认生效](#确认生效)
- [安装](#安装)
- [仓库结构](#仓库结构)
- [全部选项](#全部选项)
- [常见场景配方](#常见场景配方)
- [常见问题](#常见问题)
- [排查问题](#排查问题)
- [性能](#性能)
- [关闭与卸载](#关闭与卸载)
- [出处、致谢与许可](#出处致谢与许可)

---

## 它解决什么问题

uosc_danmaku 自带的合并（`merge_tolerance`）只能合并**文本一模一样**的弹幕。
本模块在此基础上补了三级模糊判定：

| 弹幕原文 | 自带合并 | 加上本模块 |
|---|---|---|
| `完结撒花` `完结撒花` `完结撒花` | ✅ 合成一条 | ✅ 合成一条 |
| `完结撒花` `完结撒花！！！` `完结撒花~` | ❌ 各显示各的 | ✅ 合成一条（文本预处理） |
| `哈哈哈哈` `哈哈哈哈啊` | ❌ | ✅ 合成一条（编辑距离） |
| `在吗` `再吗`、`是` `事` | ❌ | ✅ 合成一条（拼音相同） |
| `好看` `好看啊` | ❌ | ✅ 合成一条（余弦相似度） |

四级判定按顺序执行，**任意一级命中就合并**。

### 实测效果

在一部番剧的其中一集上（6702 条弹幕）：

```
合并前    6702 条
合并后    4884 条    减少 27%
耗时      约 320ms    只在弹幕加载时执行一次
最大合并  👍 刷屏，合并了 69 条
```

---

## 快速开始

**前提**：已经装好 mpv 和 [uosc_danmaku](https://github.com/Tony15246/uosc_danmaku)。

1. 把本仓库 `portable_config/` 里的 `scripts/uosc_danmaku/` 和
   `script-opts/uosc_danmaku.conf` 覆盖到你的 mpv 配置目录
2. 确认 `script-opts/uosc_danmaku.conf` 里有这一行（本仓库已默认写好）：

   ```ini
   pakku_enable=yes
   ```

3. 重启 mpv

就这三步。

---

## 确认生效

打开 mpv 看日志：

```
[uosc_danmaku] 已解析 4884 条弹幕
```

条数明显少于弹幕总数，说明合并生效了。

想看详细信息，用命令行启动：

```powershell
mpv.exe --msg-level=uosc_danmaku=v "你的视频.mkv"
```

```
[uosc_danmaku] pakku: 拼音字典载入 6763 个汉字 / 398 个拼音组
[uosc_danmaku] pakku: 6702 条 -> 4884 条（簇 4884，最多合并 69；
               ==467 ≤1058 P46 247%；丢弃 0，缩小 0，放大 73，耗时 319ms）
```

统计行怎么读：

| 片段 | 含义 |
|---|---|
| `6702 条 -> 4884 条` | 合并前后条数 |
| `最多合并 69` | 最大的一个簇合并了 69 条 |
| `==467` | 467 条靠「文本完全相同」合并 |
| `≤1058` | 1058 条靠「编辑距离」合并 |
| `P46` | 46 条靠「拼音」合并 |
| `247%` | 247 条靠「余弦相似度」合并 |
| `丢弃 / 缩小 / 放大` | 密度调控与字号放大的命中数 |
| `耗时 319ms` | 整个合并过程花了多久 |

---

## 安装

### 方式一：整包覆盖（推荐）

把本仓库 `portable_config/` 里的内容覆盖到你的 mpv 配置目录：

```
<你的配置目录>/
├── scripts/uosc_danmaku/            ← 覆盖整个目录
└── script-opts/uosc_danmaku.conf    ← 覆盖此文件
```

配置目录通常是 `portable_config/`（便携版）或 `%APPDATA%/mpv/`。
两者同时存在时 mpv 优先用 `portable_config/`。

### 方式二：只给已有的 uosc_danmaku 打补丁

本模块对上游 uosc_danmaku 的改动只有 4 处，加上 1 个新文件：

| 文件 | 改动 |
|---|---|
| `modules/pakku.lua` | **新增**，算法本体（约 1400 行） |
| `modules/parse.lua` | 合并分支、标记加粗与字号处理 |
| `modules/options.lua` | 23 个 `pakku_*` 选项默认值 |
| `main.lua` | 加一行 `require("modules/pakku")` |
| `script-opts/uosc_danmaku.conf` | 追加 pakku 选项段 |

### 环境要求

- mpv（在 **v0.41.0** 上验证，任意带 Lua 支持的版本都可以）
- 文件必须是 **UTF-8 编码 + Unix 换行（LF）**，否则 mpv 读不出中文
- 不需要额外安装字体：默认标记只用半角括号和数字

---

## 仓库结构

```
.
├── readme.md                  你正在看的这份
├── project.md                 开发地图：架构、数据结构、扩展方式、踩过的坑
├── changelog.md               版本历史
├── THIRD-PARTY.md             第三方组件与许可证说明
├── LICENSE                    GPL-3.0 全文
├── testdata/                  回归测试用的弹幕文件（3 集，共 20086 条）
│   └── [DMG&VCB-Studio] BOCCHI THE ROCK! [NN]....xml
└── portable_config/
    ├── scripts/uosc_danmaku/
    │   ├── modules/pakku.lua   ★ 本项目新增的算法模块
    │   └── ...                 上游 uosc_danmaku 的其它文件
    └── script-opts/
        └── uosc_danmaku.conf   含 pakku 选项段
```

`testdata/` 里的弹幕文件可以直接拿来验证：把文件名改成和你的视频同名、
放在视频同目录，uosc_danmaku 就会自动加载（注意视频时长需 ≥ 60 秒）。

---

## 全部选项

所有选项都写在 `script-opts/uosc_danmaku.conf` 的 pakku 段里，改完重启 mpv 生效。
默认值基本等于 **pakku.js 官方默认配置**，有意不同的只有标记的位置与字形。

### 基础

| 选项 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `pakku_enable` | yes/no | `yes` | 总开关。打开后接管 `merge_tolerance` 的合并 |
| `pakku_threshold` | 秒 | `30` | 滑动窗口大小。只有相隔不超过这个秒数的弹幕才会互相比较 |
| `pakku_use_pinyin` | yes/no | `yes` | 是否用拼音判定，关掉就合不了谐音弹幕 |

`pakku_threshold` 是最影响耗时的一项。它决定了「往前看多久」的弹幕，
调到 5 秒能快一倍多，但漏合并也会变多。

### 判定严格程度（最常调的三个）

| 选项 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `pakku_max_dist` | 整数 | `5` | 编辑距离上限。**调大 = 更容易合并 = 更容易误伤** |
| `pakku_max_cosine` | 0–100 | `45` | 余弦相似度阈值。**调小 = 更容易合并**；填 `101` 可禁用这一级 |
| `pakku_cross_mode` | yes/no | `yes` | 是否允许滚动/顶部/底部弹幕互相合并 |

四级判定按顺序执行，**任意一级命中就合并**。想让合并更保守，
需要同时调小 `pakku_max_dist` 和调大 `pakku_max_cosine`。

### 显示样式

| 选项 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `pakku_mark` | 枚举 | `suffix` | 标记位置：`suffix` 末尾（`恭喜(12)`）/ `prefix` 开头 / `off` 不显示 |
| `pakku_mark_subscript` | yes/no | `no` | `no` → `(12)` 普通数字；`yes` → `₍₁₂₎` pakku.js 的下标形式 |
| `pakku_mark_scale` | 倍数 | `1.8` | 只在下标模式下生效的补偿倍数，默认模式下无效 |
| `pakku_mark_threshold` | 整数 | `1` | 合并条数超过这个值才加标记 |
| `pakku_enlarge` | yes/no | `yes` | 是否按合并条数放大字号 |
| `pakku_enlarge_min_count` | 整数 | `5` | 合并条数超过这个值才开始放大 |
| `pakku_enlarge_max_scale` | 倍数 | `2.0` | 放大上限 |
| `pakku_enlarge_log_base` | 数字 | `5` | 放大曲线的对数底数。默认下合并 25 条就翻倍 |
| `pakku_mode_elevation` | yes/no | `yes` | 簇里混有底部/顶部弹幕时，把整簇提升为更醒目的类型 |
| `pakku_representative_percent` | 0–100 | `20` | 取簇内第百分之几的成员作为代表，决定合并后的时间、颜色、字号 |

标记的四种组合：

| `pakku_mark` | `pakku_mark_subscript` | 效果 |
|---|---|---|
| `suffix`（默认） | `no`（默认） | `恭喜(12)` |
| `suffix` | `yes` | `恭喜₍₁₂₎` |
| `prefix` | `no` | `(12)恭喜` |
| `off` | — | `恭喜` |

**为什么默认不用下标？** pakku.js 的默认是下标 `₍₁₂₎`，但下标字形天生小，
而且小多少完全由字体决定。实测「下标数字高 ÷ 正文数字高」：

| 字体 | 比例 |
|---|---|
| MS Gothic | 47.0% |
| Times New Roman | 52.0% |
| Arial | 54.1% |
| Microsoft YaHei | 55.4% |
| Segoe UI | 59.8% |
| Tahoma | 62.8% |
| Verdana | 63.3% |

在 47%~63% 之间浮动，换字体就变，观感很难稳定。所以默认改用普通数字 `(12)`，
跟随正文字体，不需要任何补偿。想回到 pakku.js 的下标观感：
`pakku_mark_subscript=yes`（此时 `pakku_mark_scale` 才会生效）。

### 文本预处理

| 选项 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `pakku_trim_ending` | yes/no | `yes` | 去掉末尾标点：`完结撒花！！！` → `完结撒花` |
| `pakku_trim_width` | yes/no | `yes` | 全角半角统一：`ＡＢＣ１２３` → `ABC123` |
| `pakku_trim_space` | yes/no | `yes` | 合并多余空格、去掉汉字之间的空格：`你 好` → `你好` |
| `pakku_normalize_display` | yes/no | `yes` | 合并后显示预处理过的文本；关掉则显示出现最多的**原始**文本 |
| `pakku_forcelist` | JSON | 见下 | 自定义替换规则 |

```ini
pakku_forcelist=[["^23{2,}$","23333"],["^6{3,}$","66666"]]
```

- 格式是 JSON 数组，每项 `[模式, 替换]`
- 模式用 **Lua 模式**语法，但额外支持 `{n}` / `{n,}` / `{n,m}` 量词
- 上面两条把「2333333…」统一成「23333」，「6666666…」统一成「66666」
- 写错的正则会被告警并跳过，不会崩

### 密度调控（进阶，默认关闭）

| 选项 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `pakku_shrink_threshold` | 数字 | `0` | 屏幕上累积的「显示价值」超过它就整体缩小字号。`0` = 关闭 |
| `pakku_drop_threshold` | 数字 | `0` | 超过它就按权重丢弃低优先级弹幕。`0` = 关闭 |

⚠️ 这两个值需要按自己的字号调。pakku.js 假设基准字号 25，而 uosc_danmaku 默认
`fontsize=50`，显示价值会翻倍。实测（20086 条）：`shrink_threshold=200` 只缩小
约 0.8% 的弹幕，`=400` 完全不触发；`drop_threshold=200` 只丢约 10 条，
`=600` 完全不丢。**200–400 是「有感但不激进」的量级**。

如果已经用 `max_screen_danmaku` 限制了同屏条数，这两个通常不需要开。

---

## 常见场景配方

### 还是觉得刷屏，想更激进

```ini
pakku_threshold=60
pakku_max_dist=6
pakku_max_cosine=35
```

代价是耗时翻倍，且可能把剧情推进后的弹幕也合进来。

### 担心误伤，只想合并「几乎一模一样」的

```ini
pakku_max_dist=0
pakku_max_cosine=101
```

只保留「完全相同」和「拼音完全相同（谐音）」两种合并。实测 20086 条会合到
17665 条（87.9%）。

### 只想在同一类型的弹幕内部合并

```ini
pakku_cross_mode=no
```

实测合到 15273 条（76.0%）。

### 觉得耗时长，想快一点

```ini
pakku_threshold=10
```

耗时约砍半（每集 319ms → 181ms），代价是合并率从 71.5% 降到 76.4%。

### 关掉字号放大，保持字号统一

```ini
pakku_enlarge=no
```

### 不想要 `(12)` 标记

```ini
pakku_mark=off          ; 完全不显示
pakku_mark_threshold=5  ; 只在合并 5 条以上时才显示
pakku_mark=prefix       ; 标记挪到开头
```

### 想要 pakku.js 那种下标标记

```ini
pakku_mark_subscript=yes
pakku_mark_scale=1      ; 1 = pakku.js 原始大小，1.8 = 补到与正文数字同高
```

### 合并后文本被改了，想保留原文

```ini
pakku_normalize_display=no
```

---

## 常见问题

**Q：打开后弹幕数量没变？**
确认改的是 mpv 实际读取的那个 `uosc_danmaku.conf`（`portable_config/` 优先于
`%APPDATA%/mpv/`）。用 `--msg-level=uosc_danmaku=v` 看有没有
`pakku: 拼音字典载入` 这行。

**Q：合并得太狠了，不相干的弹幕被合到一起。**
调小 `pakku_max_dist`（3 或 2），调大 `pakku_max_cosine`（70），
或关掉 `pakku_cross_mode` 避免跨类型吸走弹幕。

**Q：合并得不够，还是刷屏。**
调大 `pakku_max_dist`（6）、调小 `pakku_max_cosine`（35）、
调大 `pakku_threshold`（60）。

**Q：某些弹幕的字变了。**
那是文本预处理在起作用（去尾部标点、全角转半角）。
想显示原文就设 `pakku_normalize_display=no`。

**Q：弹幕变得很大 / 很小。**
大是 `pakku_enlarge`（默认合并 25 条就翻倍），小是 `pakku_shrink_threshold`。
分别关掉即可。

**Q：会不会拖慢播放？**
不会。合并在弹幕加载时一次性完成，一集约 320ms，播放过程中零开销。

**Q：支持哪些弹幕类型？**
滚动（1/2/3）、底部（4）、顶部（5）参与合并。逆向（6）、高级（7）、
代码（8/9）弹幕原样透传不做合并。

**Q：和 uosc_danmaku 自带的 `merge_tolerance` 冲突吗？**
互斥。`pakku_enable=no` 时用 `merge_tolerance`（行为完全不变）；
`pakku_enable=yes` 时 `merge_tolerance` 被忽略。
`merge_fontsize_growth` / `merge_fontsize_max` 同样在 pakku 模式下不生效。
`max_screen_danmaku`（同屏条数限制）两者都生效，在合并之后执行。

---

## 排查问题

1. **确认脚本加载了**

   ```powershell
   mpv.exe --msg-level=all=v "视频.mkv" 2>&1 | Select-String "uosc_danmaku"
   ```

   应能看到 `Loading lua script .../uosc_danmaku/main.lua`。

2. **确认模块生效了**

   在同一输出里找 `pakku: 拼音字典载入 6763 个汉字 / 398 个拼音组`。
   没有这行说明没被调用——检查 `pakku_enable=yes` 是否写对、
   conf 文件编码是不是 UTF-8。

3. **确认本地弹幕被加载了**

   uosc_danmaku 自动加载本地弹幕有两个前提：

   - 视频时长 **≥ 60 秒**（源码里的硬性判断）
   - 弹幕文件叫 `<视频文件名不含扩展名>.xml`，放在视频同目录

   另外 `danmaku-history.json` 里的 `show_danmaku` 必须是 `true`
   （在 uosc 界面上点一下弹幕按钮切换即可）。

4. **开日志文件**

   ```powershell
   mpv.exe --log-file=mpv.log "视频.mkv"
   ```

5. **怀疑是本模块引起的异常**

   把 `pakku_enable` 改成 `no` 对比。两者差异只应该在「合并了什么」上。

---

## 性能

3 集真实弹幕（合计 20086 条）实测，mpv v0.41.0 / LuaJIT，`fontsize=50`：

| 配置 | 合并结果 | 平均耗时 |
|---|---|---|
| 关闭 | 20086 → 20086 | 0 ms |
| **默认** | **20086 → 14366（71.5%）** | **~319 ms/集** |
| `threshold=10` | 20086 → 15340（76.4%） | ~181 ms/集 |
| `threshold=5` | 20086 → 16216（80.7%） | ~141 ms/集 |
| 保守（`dist=3` `cos=70`） | 20086 → 15385（76.6%） | ~292 ms/集 |
| 不跨类型（`cross=no`） | 20086 → 15273（76.0%） | ~256 ms/集 |
| 仅精确 + 拼音（`dist=0`） | 20086 → 17665（87.9%） | ~135 ms/集 |

单集明细：

| 集数 | 原始 | 合并后 | 最大合并 | 耗时 |
|---|---|---|---|---|
| 03 | 6592 | 4773 | (60) | ~306 ms |
| 04 | 6702 | 4884 | (69) | ~314 ms |
| 07 | 6792 | 4709 | (47) | ~307 ms |

耗时都在**弹幕加载时**（一次性），播放过程中没有额外开销。
拼音字典首次使用时懒加载约 60ms，之后常驻内存。
同一输入重复运行结果完全一致（合并过程是确定性的）。

---

## 关闭与卸载

- **临时关闭**：`pakku_enable=no`
- **完全卸载**：删掉 `scripts/uosc_danmaku/modules/pakku.lua`，
  并把 `parse.lua` / `options.lua` / `main.lua` / `uosc_danmaku.conf` 里的
  pakku 相关代码去掉（见 [`project.md`](project.md) 的改动清单）

因为是「1 个新增模块 + 4 处条件分支」，回滚不会影响 uosc_danmaku 的其它功能。

---

## 出处、致谢与许可

### 出处

本模块的需求来源与算法说明出自下面这篇博客：

| 项目 | 内容 |
|---|---|
| 标题 | 在 uosc_danmaku 中集成 pakkujs 弹幕合并算法 |
| 作者站点 | [blog.episvr.top](https://blog.episvr.top) |
| **原文地址** | **<https://blog.episvr.top/2026/06/29/uosc_danmaku-pakkujs/>** |

算法的原理推导（编辑距离、拼音距离、余弦相似度、滑动窗口聚类）请看原文。

### 致谢

- [pakku.js](https://github.com/xmcp/pakku.js) —— 合并算法、拼音字典与默认配置的来源
- [uosc_danmaku](https://github.com/Tony15246/uosc_danmaku) —— mpv 弹幕插件（宿主）
- [uosc](https://github.com/tomasklaen/uosc) —— UI 框架

### 许可

本项目整体以 **[GPL-3.0](LICENSE)** 分发。

原因：核心模块 `modules/pakku.lua` 是 pakku.js（GPLv3）的移植与衍生作品，
GPLv3 要求衍生作品同样以 GPLv3 授权。宿主 uosc_danmaku 是 MIT，
MIT 与 GPLv3 兼容，未改动的上游文件仍可按 MIT 使用。

完整的组件清单与许可证全文位置见 [`THIRD-PARTY.md`](THIRD-PARTY.md)。

> 想用于闭源项目的话本项目**不适合**，请自行联系 pakku.js 作者洽谈另一套授权。
