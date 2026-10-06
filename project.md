# project.md — 开发地图

**这份文档面向要改代码的人。** 只想装来用的话看 [`readme.md`](readme.md) 就够了。

内容：项目结构与两个功能的实现细节、数据结构、配置流转、踩过的坑、
怎么验证、怎么扩展、许可与合规。

> 文档里引用的行号以 **`pakku.lua`（1398 行，本项目的核心新文件）** 为准，
> 它有 9 个编号章节，用 `grep '^-- [0-9]'` 可以快速定位。
> 对**上游被改过的文件**（`menu.lua` / `utils.lua` / `parse.lua` 等）
> 一律只给**函数名不给行号** —— 那些文件改动频繁，行号很快就会失效。

---

## 1. 项目是什么

### 1.1 三个功能

本项目 = [uosc_danmaku](https://github.com/Tony15246/uosc_danmaku)（宿主，MIT）
上的三部分增强，**互相独立**：

| # | 功能 | 核心文件 | 关键选项 | 代码默认 |
|---|---|---|---|---|
| 一 | **pakku 弹幕合并** | `modules/pakku.lua`（新增，1398 行） | `pakku_enable` | `no`（conf 里显式 `yes`） |
| 二 | **无键盘支持** | `modules/menu.lua` + `modules/utils.lua` | `danmaku_auto_select` 等 3 项 | `yes` |
| 三 | **保存过滤后的弹幕** | `modules/parse.lua` | `save_danmaku_mode` | `raw`（上游行为） |

选项目录与用户视角的说明在 [`readme.md`](readme.md)；本文讲**为什么这么写**。

### 1.2 文档分工

| 文件 | 给谁 | 内容 |
|---|---|---|
| `readme.md` | 使用者 | 三个功能是什么、怎么装、**全部选项与默认值**、常见问题、排查 |
| `project.md` | 改代码的人（本文） | 实现细节、数据结构、坑、验证方法、扩展指南、合规 |
| `changelog.md` | 翻旧账的人 | 按版本记录「为什么改这一版」，含当时的日志证据 |
| `THIRD-PARTY.md` | 分发的人 | 第三方组件与许可证全文位置 |
| `test/auto_select_test.lua` | CI / 改功能二的人 | 自动选择逻辑的单测（47 项） |
| `test/save_danmaku_test.lua` | CI / 改功能三的人 | 保存模式的单测（24 项） |
| `test/docs_check.lua` | CI / 改任何选项的人 | 文档与代码的一致性检查（8 项） |

---

## 2. 仓库结构

```
.
├── readme.md / project.md / changelog.md / THIRD-PARTY.md / LICENSE
├── test/
│   └── auto_select_test.lua       功能二的单测
├── testdata/                      回归用弹幕（3 集，20086 条）
└── portable_config/
    ├── scripts/uosc_danmaku/      宿主（vendored，MIT）
    │   ├── modules/pakku.lua      ★ 本项目新增
    │   ├── modules/menu.lua       ● 功能二主要改动处
    │   ├── modules/utils.lua      ● 工具 + 流程日志
    │   ├── modules/parse.lua      ● 合并分支 / 标记渲染
    │   ├── modules/options.lua    ● 选项默认值
    │   ├── main.lua               ● 构建指纹 / 一键搜索键绑定
    │   └── apis/ sites/ dicts/    上游代码
    └── script-opts/
        └── uosc_danmaku.conf      pakku 段 + 无键盘段
```

---

## 3. 一次播放的完整链路

```
                 ┌──────────────────────────┐
   本地 xml ─────┤ parse_xml_danmaku()      │
   弹弹play ─────┤ parse_json_danmaku()     │  统一结构：
   其它站点 ─────┤ sites/*.lua              │  { time, type, size, color, text }
                 └────────────┬─────────────┘
                              ▼
              DANMAKU.sources[url].data（每条源各自一份）
                              │
                              ▼
        convert_danmaku_to_ass_events(force)          ← parse.lua
                              │
                 ┌────────────┴─────────────┐
                 │ 1. 逐源展开 + 延迟校正    │  make_delay_lookup()
                 │ 2. 黑名单过滤             │  is_blacklisted()
                 │ 3. 多源按时间归并         │  new_min_heap() 小顶堆
                 └────────────┬─────────────┘
                              ▼
                 ┌────────────┴─────────────┐
                 │ 合并（二选一）            │
   pakku_enable  ├─ yes → pakku.merge()      │  ★ 功能一
        =no      └─ no  → merge_duplicate_   │
                              danmaku()      │
                 └────────────┬─────────────┘
                              ▼
                 ┌──────────────────────────┐
                 │ 布局：滚动/顶部/底部各算 y │  DanmakuArray
                 │ 字号：fontsize×merge_scale │  ★ 功能一分支
                 │ 文本：ASS 转义 + 标记加粗  │  ★ 功能一分支
                 └────────────┬─────────────┘
                              ▼
                    COMMENTS = ass_events
                              │
                              ▼
          modules/render.lua → mp.set_osd_ass() / uosc 层
```

同时在**合并那一步之后**存了一份快照，供功能三导出：

```
   合并之后 ──► RENDERED_DANMAKU = danmakus          ★ 功能三
                      │
                      ▼
   convert_danmaku_to_xml()：raw / filtered 现取，merged 用这份快照
```

**关键点**：`pakku.merge()` 的位置在**黑名单过滤之后、布局之前**，
处理的是全部弹幕源的合并结果 —— 它替换的只是「合并」这一步，
不碰时间轴、不碰渲染。

功能二（无键盘）不在上面这条链路里，它作用在**链路之前**：
帮你把弹幕**取回来**（搜索 → 选番剧 → 选集 → 拉取）。
功能三在**链路之后**：把处理过的结果写回磁盘。

---

## 4. 改动清单（相对上游 uosc_danmaku）

| 文件 | 职责 | 本项目改动 | 属于 |
|---|---|---|---|
| `modules/pakku.lua` | — | **新增**，算法本体 | 一 |
| `modules/options.lua` | 选项默认值 | 23 个 `pakku_*` + 3 个 `danmaku_*` + `save_danmaku_mode` | 一 + 二 + 三 |
| `modules/parse.lua` | 解析/合并/生成 ASS/导出 xml | 合并分支、标记加粗与字号分支、**保存模式**、`RENDERED_DANMAKU` 快照 | 一 + 三 |
| `main.lua` | 入口、事件、脚本消息 | `require("modules/pakku")`、一键搜索键绑定、**构建指纹** | 一 + 二 |
| `modules/utils.lua` | 通用工具 | `trace_osd` `brief_error` `http_error_hint` `get_media_filename` `build_fingerprint` | 主要二 |
| `modules/menu.lua` | 菜单/搜索/选择 | `danmaku-quick-search`、**自动选择**、流程日志、去重 | 二 |
| `apis/dandanplay.lua` | 弹弹play 接口 | 失败原因上屏、日志级别提升 | 二 |
| `apis/extra.lua` | 其它源 | 日志级别提升 | 二 |
| `script-opts/uosc_danmaku.conf` | 用户配置 | pakku 段 + 无键盘段 + 保存段 | 一 + 二 + 三 |

---

## 5. 功能一：pakku 合并

### 5.1 `modules/pakku.lua` 内部结构

文件按 9 个编号章节组织，每章开头有 `-- n. 标题` 分隔注释
（`grep '^-- [0-9]'` 可列出章节）。

| 章节 | 行号 | 内容 |
|---|---|---|
| 头部文档 | 1–38 | 用法、接口、字段说明 |
| **0. UTF-8 小工具** | 63–102 | `utf8_char_list` `utf8_codepoint` `utf8_count` `is_cjk_codepoint` |
| **1. 拼音字典** | 104–539 | `PINYIN_SRC` 数据块（116–514）、`pinyin_dict()`（519）懒加载 |
| **2. 文本预处理** | 542–670 | `ENDING_CHARS`、`WIDTH_TABLE`、`normalize_spaces()`（581）、`quantifier_to_lua()`（613）、`M.normalize()`（635） |
| **3. 相似度计算** | 673–771 | `freq_of_chars` `freq_of_pinyin` `freq_distance` `make_bigrams` `gram_cosine`、`M.edit_distance`（752）、`M.pinyin_distance`（759）、`M.cosine_similarity`（767） |
| **4. 配置** | 774–879 | `pick` `tonum` `tobool`、`M.build_config()`（806） |
| **5. 聚类** | 882–1017 | `M.build_ir()`（886）、`M.check_similar()`（914）、`cluster()`（971） |
| **6. 字号放大 / 标记** | 1020–1085 | `enlarge_scale()`、`SUBSCRIPT_DIGITS`、`to_subscript()`（1045）、`make_mark_tag()`（1067）、`make_mark()`（1078） |
| **7. 密度调控** | 1088–1178 | `M.dispval()`（1096）、`judge_drop()`、`M.adjust_density()`（1114） |
| **8. 对外主入口** | 1181–1398 | `choose_display_text()`（1185）、`dominant_reason()`、`M.merge()`（1250） |

### 5.2 四级相似判定

`M.check_similar(a, b, cfg)` 按顺序试，**任意一级命中就合并**，
返回 `(reason, dist)`：

| 顺序 | reason | 判据 | 选项 |
|---|---|---|---|
| 1 | `identical` | 预处理后的文本完全相同 | — |
| 2 | `edit` | 字符频率近似编辑距离 ≤ 上限 | `pakku_max_dist` |
| 3 | `pinyin` | 拼音 token 多重集距离为 0 | `pakku_use_pinyin` |
| 4 | `cosine` | bigram 余弦相似度 ≥ 阈值 | `pakku_max_cosine` |

顺序即优先级，`dominant_reason()` 里有一张 `rank` 表决定簇的代表 reason。

### 5.3 簇与代表

`cluster()` 自后向前扫描滑动窗口：`nearby` 队列按时间递增维护**未定型**的簇，
当簇的代表时间落后超过 `pakku_threshold` 秒就输出定型。

**代表选取**由 `pakku_representative_percent` 决定：取簇内第 20% 那个成员
的时间 / 颜色 / 字号作为整个簇的代表（对齐 pakku.js 的 `REPRESENTATIVE_PERCENT`）。

### 5.4 合并标记

标记**不靠正则猜**，而是由 `make_mark_tag(count, cfg)` 直接生成、写进
`entry.merge_mark`；`parse.lua` 拿它做**明文比对**定位，再插 ASS 覆盖标签。
这样换任何标记样式都不用改渲染层。

| 配置 | 产出 |
|---|---|
| `mark=suffix`（默认）+ `mark_subscript=no`（默认） | `恭喜(12)` |
| `mark=suffix` + `mark_subscript=yes` | `恭喜₍₁₂₎` |
| `mark=prefix` + `mark_subscript=no` | `(12)恭喜` |
| `mark=off` | `恭喜`（`merge_mark` 为空串） |

默认形式 `(12)` 是**本项目自选的**，不对应 pakku.js 的任何取值：
pakku.js 只有下标 `₍₁₂₎` 和 `[x12]` 两种，没有括号数字。

#### 为什么放弃下标

pakku.js 默认 `DANMU_SUBSCRIPT=on`，即 `₍₁₂₎`。下标字形的问题有两个：

1. **天生小**：Microsoft YaHei 下下标数字只有正文数字的 **55.4%** 高
2. **比例随字体浮动**：实测 7 个字体在 **47.0%（MS Gothic）~ 63.3%（Verdana）** 之间

也就是说同一个 `\fs` 值在不同字体、不同机器上观感不一致，得不到稳定的默认值。
要补偿只能加 `\fs`（就是 `pakku_mark_scale` 做的事），但补偿倍数本身又依赖字体。

改成普通数字 + 半角括号 `(12)` 后，标记直接跟随正文字体，
既不需要补偿、也不会随字体变样，横向占用还更小。

下标形式仍保留在 `mark_subscript=yes` 后面（代码里 `to_subscript()` 和
`SUBSCRIPT_LPAREN/RPAREN` 都没删），想要原始观感随时可以切回去。

#### 下标模式下的字号补偿

**pakku.js 没有给标记单独设过字号** —— 它的 `make_mark_meta()`（pakku.js 源码里的函数，
不是本项目的）只是把 `₍${to_subscript(cnt)}₎` 拼到文本上，
剩下的交给 B 站播放器按弹幕字号渲染。
换句话说「pakku 的字号」就是弹幕本身的字号，没有额外参数可抄。

所以在 `mark_subscript=yes` 时，本项目用 `\fs` 做补偿。用
`System.Drawing`（GDI+ 与 libass 走同一套字体轮廓）量 Microsoft YaHei Bold
在 size=100 下的墨迹高度：

| 内容 | 墨迹高度 | 相对正文数字 |
|---|---|---|
| 正文数字 `0123456789` | 78.61 | 100% |
| 下标数字 `₀₁₂₃₄₅₆₇₈₉` | 43.56 | **55.4%** |
| 下标括号 `₍₎` | 53.71 | 68.3% |
| 完整标记 `₍₁₂₎` | 53.71 | 68.3% |

| `pakku_mark_scale` | 效果 |
|---|---|
| `1.0` | 不放大，完全还原 pakku.js 的原始观感（标记明显偏小） |
| `1.46` | 下标括号与正文数字同高 |
| `1.8`（默认值） | 下标数字与正文数字同高 |

实现上由 `parse.lua` 的字号分支折算：`\fs` 取
`event_fontsize × pakku_mark_scale`，标签形如 `{\b1\fs90}₍₅₎`。
**只对下标标记生效**，`mark_subscript=no`（默认）时 `mark_scale` 被强制为 1，
标签退化成 `{\b1}(5)`。

> 下标数字在 Microsoft YaHei 下是**贴着基线**的（底部 106.83 vs 正文数字
> 107.13），所以只需要放大、不需要再补 `\rise`。

### 5.5 密度调控

`M.adjust_density()` 在合并之后执行，就地修改 `merge_scale`，
并给要丢弃的条目打 `drop = true`。常量：

| 常量 | 值 | 含义 |
|---|---|---|
| `DISPVAL_POWER` | 0.35 | dispval 的幂次 |
| `DISPVAL_TIME_THRESHOLD_MS` | 5000 | 密度累加的滑动窗口 |
| `SHRINK_MAX_RATE` | 1.732 | 单条最多缩小到 1/1.732 |

`judge_drop()` 决定丢弃概率，权重来自 `merge_count`
（uosc_danmaku 没有点赞数可用，pakku.js 那边用的是 `proto_likecount`）。

> ⚠️ 两个阈值默认都是 `0`（禁用），而且**数值与 `fontsize` 强相关**：
> pakku.js 假设基准字号 25，uosc_danmaku 默认 `fontsize=50`，
> `dispval` 里的 `(size/25)^1.5` 会翻倍，所以要用的话得相应放大。

### 5.6 拼音字典编码（重要）

`pinyin_dict.txt` 里是 `{0x554a, {1, 0}}` 这种形式，两个数字是
**声母索引 / 韵母索引**，不是一个序号：

```
巴/八/吧/爸 = {6, 1}    → ba
麻/马/骂/妈 = {46, 1}   → ma
怕/爬       = {48, 1}   → pa
天          = {53, 12}  → tian
他          = {53, 1}   → ta
啊/阿/锕    = {1, 0}    → a
```

同音字共享同一对数值，全表共 **398 组**（≈ 无声调音节数）。
`main.cpp` 的用法是按顺序把 `first` 和（非 0 的）`second` 两个 token
塞进频率表，本实现照做：

```lua
PINYIN_DICT[汉字] = first * 64 + second      -- 64 > max(second) = 55
-- 取用时
f[math.floor(code / 64)] += 1
if code % 64 > 0 then f[code % 64] += 1 end
```

这样 `在`(zai) 和 `再`(zai) 产生完全相同的 token 多重集，拼音距离为 0。
**不需要**知道数字对应的具体拼音字符串 —— 判定只依赖等价性。

### 5.7 与 pakku.js 的对照

所有 `pick(o, name, default)` 的 default、以及 `options.lua` / `.conf` 的取值，
都对齐 `pakku.js/background/config.ts` 的 `DEFAULT_CONFIG`：

| 本实现 | 值 | pakku.js |
|---|---|---|
| `pakku_threshold` | 30 | `THRESHOLD` |
| `pakku_max_dist` | 5 | `MAX_DIST` |
| `pakku_max_cosine` | 45 | `MAX_COSINE` |
| `pakku_use_pinyin` | true | `TRIM_PINYIN` |
| `pakku_cross_mode` | true | `CROSS_MODE` |
| `pakku_enlarge_min_count` | 5 | `calc_enlarge_rate()` 里 `count <= 5` 不放大 |
| `pakku_enlarge_log_base` | 5 | `Math.log(count) / Math.log(5)` |
| `pakku_enlarge_max_scale` | 2.0 | `Math.min(..., 2)` 的等效上限 |
| `pakku_representative_percent` | 20 | `REPRESENTATIVE_PERCENT` |
| `pakku_mode_elevation` | true | `MODE_ELEVATION` |
| `pakku_mark` | `suffix` | `DANMU_MARK`（pakku.js 是 `prefix`） |
| `pakku_mark_subscript` | false | `DANMU_SUBSCRIPT`（pakku.js 是 `true`） |
| `pakku_mark_scale` | 1.8 | **无对应项**（pakku.js 不给标记单独设字号） |
| `pakku_mark_threshold` | 1 | `MARK_THRESHOLD` |
| `pakku_forcelist` | 23333 / 66666 | `FORCELIST` |
| `pakku_shrink_threshold` / `pakku_drop_threshold` | 0 | `SHRINK_THRESHOLD` / `DROP_THRESHOLD` |

**三处有意偏离**：

1. **标记的位置**：`pakku_mark=suffix`，标在末尾（`文本(12)`）。
   pakku.js 默认 `prefix`，标在开头。
2. **标记的字形**：`pakku_mark_subscript=false` → `(12)`。
   理由见 §5.4。`(12)` 这个具体形式在 pakku.js 里没有对应项。
3. **`pakku_enable` 的库默认仍是 `false`**，但本项目自带的 conf 里显式写 `yes`。
   这样库升级不会突然改变已有用户的行为，而本项目装好即用。

文章（出处博客）给的默认值与 pakku.js 官方默认不同
（文章写 `threshold` 短、放大「10 条起、以 10 为底」）。
**本实现以 pakku.js 的 `DEFAULT_CONFIG` 为准。**

### 5.8 公开 API

```lua
local pakku = require("modules/pakku")

-- 主入口：合并弹幕，返回新数组 + 统计信息。cfg 可直接传全局 options 表
local merged, stats = pakku.merge(danmakus, cfg)

-- 密度调控：就地修改 merge_scale，并给要丢弃的条目打 drop = true
pakku.adjust_density(danmakus, cfg)

-- 配置整理：把 options 或普通 table 归一成内部 cfg
local cfg = pakku.build_config(o)

-- 中间结构构造与判定（便于单测与调试）
local ir = pakku.build_ir(danmaku, cfg)
local reason, dist = pakku.check_similar(ir_a, ir_b, cfg)

-- 纯函数
pakku.normalize(text, cfg)          -- 文本预处理
pakku.edit_distance(s1, s2)         -- 字符频率近似编辑距离
pakku.pinyin_distance(s1, s2)       -- 拼音层面距离
pakku.cosine_similarity(s1, s2)     -- bigram 余弦相似度，0-100
pakku.dispval(text, fontsize)       -- 单条弹幕的显示价值
pakku.pinyin_group_count()          -- 拼音组数量（自检用，应为 398）
```

`M.merge()` 返回的 `stats` 字段：
`total` `merged` `clusters` `max_combo` `identical` `edit` `pinyin` `cosine`
`dropped` `shrunk` `enlarged` `ms`。

### 5.9 兼容性设计

- `require("mp.msg")` / `require("mp.utils")` 都用 `pcall` 包住，失败时退化成空实现，
  因此本模块**可以脱离 mpv、用裸 luajit 直接单测**。
- `pick(o, name, default)` 同时认 `o.pakku_xxx` 和 `o.xxx` 两种键名，
  所以既能把 uosc 的 `options` 全局表直接丢进去，也能在测试里传精简 table。

### 5.10 已知限制

- **性能**：O(窗口内簇数 × 每簇一次判定)。默认 `threshold=30` 时 6700 条约 320ms；
  `threshold=10` 约 181ms，`threshold=5` 约 141ms。窗口越大越慢，线性以上增长。
- **`cross_mode` 默认开启**（对齐 pakku.js）：滚动/顶部/底部会互相合并，
  靠 `MODE_ELEVATION` 把类型提升为「底部 > 顶部 > 滚动」。
  关掉后合并率从 71.5% 降到 76.0%。
- **单条簇不回退原文**：簇数量为 1 时 `choose_display_text` 返回的仍是
  预处理后的文本（跟随 pakku.js 行为）。
- **`{n,m}` 量词有损**：Lua 模式没有上界，只能近似成「至少 n 次」。
- **uosc 菜单未接入**：pakku 选项目前只能改 conf，没做进 uosc 图形化菜单。
- **拼音表只覆盖简体常用字**：6763 字以外（生僻字、假名、emoji）
  按原字符参与比较，靠编辑距离/余弦兜底。
- **默认标记 `(12)` 与 pakku.js 不一致**：有意选择，见 §5.4。
- **下标模式依赖字体覆盖**：`U+2080-2089` / `U+208D-E` 不在 CJK 基本区，
  换到字形不全的字体上可能显示成方框；这种情况用默认的 `(12)` 即可回避。
- **下标模式的字号是补偿值不是 pakku 原值**：`pakku_mark_scale=1.8` 是按
  Microsoft YaHei 的字形度量算出来的，换字体后不一定精确。
- **标记宽度不计入布局**：`parse.lua` 用不含标记的 `clean_text` 算文本宽度，
  所以标记会额外多出一截（滚动弹幕尾部更明显）。

---

## 6. 功能二：无键盘支持

### 6.1 问题

弹幕搜索原本是「**输入关键词 → 选番剧 → 选集**」，而安卓 mpv 上前两步都做不了：

| 步骤 | 原实现 | 安卓上的问题 |
|---|---|---|
| 输入关键词 | uosc 菜单 `open_input_menu_uosc()`（`search_debounce="submit"`）<br>`mp.input.get()` 原生输入框 | 都要**回车**，安卓没有 |
| 从结果选 | uosc 菜单（`cursor:zone('primary_down', ...)`，要鼠标事件）<br>没 uosc 时 → `mp.input` 的 `input.select` | uosc 菜单点不动（前端不转触摸）<br>`选择:` 列表**纯键盘** |

实测（安卓 mpvex）卡死时的日志：搜索**成功**返回 2 条，然后什么都没有 ——
因为屏幕上是一个没人能操作的键盘列表。

### 6.2 一键搜索（`danmaku-quick-search`）

关键观察：**搜索框里本来就预填好了番剧名**
（uosc 路径是 `search_suggestion = parse_title()`，原生路径是 `default_text = title`）。
所以缺的不是「打字」，只是「确认」。

于是在 `menu.lua` 注册了 `danmaku-quick-search` 消息，直接拿 `parse_title()`
的结果调已有的 `search-anime-event`，跳过搜索框：

```
script-message danmaku-quick-search
script-message danmaku-quick-search "孤独摇滚"        -- 可选参数，手动指定
```

两个细节：

1. **关键词里的 `|` 和 `@`**：`search-anime-event` 约定用 `|` 分隔「名称\|类型」、
   `@` 分隔过滤词。文件名里出现这两个字符会被误解，所以**只有从文件名解析出来的**
   关键词才替换成空格；手动传入的参数原样保留，留出用高级语法的余地。
2. **`parse_title()` 返回空**时给提示并 warn，不做无意义的空搜索。

键位绑定在 `main.lua`，由 `danmaku_quick_search_key` 控制，
默认空字符串 = **不绑定**（不改变现有行为）。

#### 为什么不直接用 uosc 的 `search_submit`

uosc 的 `Menu.lua` 支持 `search_submit`，加上去就能让搜索菜单**打开即自动搜索**，
是更省事的一条路。但它只解决「提交」，不解决「触发」—— 在安卓上还得先有办法
点开那个菜单，而 uosc 菜单靠鼠标区域点击，前端不把触摸转成鼠标就点不动。

所以选了更独立、可由前端按钮直接调用的 script-message 方案。
如果哪天确认前端支持触摸转鼠标，把 `search_submit = true` 加进
`open_input_menu_uosc()` 的 `menu_props` 即可，两者不冲突。

### 6.3 自动选择（`danmaku_auto_select`）

#### 为什么必须有

结果列表有两种实现，**在安卓上都会卡住**：

| 列表实现 | 触发条件 | 选中方式 |
|---|---|---|
| uosc 菜单 | `uosc_available == true` | 鼠标区域，要触摸转鼠标 |
| `mp.input`（`input.select`） | 没有 uosc 时的降级路径 | **纯键盘**：上下键 + 回车 |

判据：`open_menu_select()` 用的 `prompt = '选择:'`，而 uosc 路径的菜单标题是
「在此处输入番剧名称」。日志/截图里出现 `选择:` 就说明那台设备上 uosc 没在跑。

#### 三道判定

`pick_auto_item(items, origin)` 是唯一实现，被三个入口调用：

| 入口（origin 标记） | 位置 | context |
|---|---|---|
| `搜索` | `do_final_update`（`get_animes` 内） | 搜索词 |
| `剧集` | `get_episodes` 末尾 | 文件名 |
| `列表` | `open_menu_select` 开头（覆盖 `apis/extra.lua` 等所有降级路径） | 文件名 |

**第一步：判断列表类型** —— 看菜单项要执行的**命令**，不是猜标题：

| `item_command_kind()` 识别 | 含义 |
|---|---|
| `load-danmaku` | episode → 剧集列表 |
| `search-episodes-event` / `get-extra-event` | anime → 搜索列表 |
| `open-latest-menu-anime` / `open-menu` | nav → **导航项，不参与选择** |

> ⚠️ 这里踩过两次坑，详见 §10 的「列表类型判定」。

**第二步：按类型挑**

| 列表类型 | 规则 |
|---|---|
| 剧集列表 | 只在 `kind == "episode"` 的项里找；按文件名推断的集数精确匹配，匹配不上取第一个**剧集项**（导航项永远跳过）。一条剧集项都没有就返回 nil 交回上层 |
| 搜索列表 | 只在 `kind == "anime"` 的项里打分取最高；一条都认不出（第三方 value 形状）时才退化为给全部项打分 |

**集数从哪里来**：`pick_auto_item` 直接取 `parse_title()` 的 `season, episode`
返回值，拿不到时才退回 `get_episode_number(get_media_filename())`。

> ⚠️ 这里也有坑，见 §10 的「网盘串流」。

**打分公式**：

```
分数 = jaro_winkler(规范化(parse_title()), 规范化(标题)) × 100
     + 标题完全一致 ? 30 : 0
     + 类型关键词：动漫/番剧 +40，电影/剧场版 -35，真人 -30，电视剧 -20
     + 噪音关键词：countdown/特番/总集篇/预告/花絮/生放送… -20 ~ -40
     - min(标题比搜索词多出的字数, 40) × 0.8
```

类型表 `AUTO_SELECT_TYPE_RULES`、噪音表 `AUTO_SELECT_NOISE_RULES`。
噪音表存在的理由：特番/总集篇/预告这类条目标题又长又像正片
（`S11 BOCCHI THE ROCK! Presents COUNTDOWN BOCCHI!` 前缀完全命中搜索词），
但**往往根本没有弹幕**。实测它拿 83.1 分压过正片，结果弹「该集弹幕内容为空」；
加了噪音扣分和长度惩罚后降到 62.3，正片 170.0。

### 6.4 去重

`auto_select_should_skip(stage, context, item)` + `auto_select_is_duplicate(key)`，
窗口 `AUTO_SELECT_DEDUP_SEC = 5` 秒。

**key 以「目标命令」为准**（`item.value` 拼出来），不是「阶段 + 上下文 + 标题」：

> ⚠️ 这是踩坑后改的。原来 key 里带 `stage` 和 `context`，而同一个番剧从
> 「搜索」和「列表」两个入口进来时两者都不一样，于是被当成两次不同的选择，
> **去重形同虚设**（日志里 `忽略重复触发` 一直是 0 次）。
> 现在语义是「同一个目标 5 秒内只触发一次」，与入口无关。

内部用 `key → 时间` 的表而不是「只记最后一个 key」—— 后者在 A→B→A
来回点时会绕过去重。表在每次检查时顺便剪枝，不会长起来。

> **为什么必须有去重**：重复触发会排两次后续请求，而
> `search-episodes-event` 一进来就调 `perform_cancel_active_request()`，
> 第二次会把第一次正在跑的 curl 掐掉。表现是
> `HTTP 请求失败：Exit code: -2` 加一行 `0 0 0 0` 的 curl 进度表 ——
> **真网络错误不会打出进度表**，这是区分两者的判据。

### 6.5 可诊断性

安卓上拿日志很难，所以这套东西是**围绕「日志本身要够用」**设计的。

| 机制 | 位置 | 说明 |
|---|---|---|
| `trace_osd()`（`[flow]` 行） | `utils.lua` | **永远写 `msg.info`**，只有 OSD 部分受 `danmaku_verbose_osd` 门控 |
| 构建指纹 | `main.lua` 启动时 | 6 个关键文件的内容哈希 |
| `http_error_hint()` | `utils.lua` | 把 curl 退出码翻成人话 |
| `finish()` | `menu.lua` | 收尾只跑一次 + 异常不再被 `pcall` 静默吞掉 |

**`trace_osd` 的语义**（0.8.4 起）：

```lua
function trace_osd(fmt, ...)
    local text = ...                      -- 格式化（pcall 保护）
    msg.info("[flow] " .. text)           -- 永远写日志
    if options and options.danmaku_verbose_osd
       and type(show_message) == 'function' then
        pcall(show_message, text, 6)      -- 只有开关打开才上屏
    end
end
```

关键依据：**`msg.info` 不会显示在屏幕上**，只有 `show_message` 才会。
所以「永远写日志」对用户完全无感，但导出的日志天然带上 ①~⑧。

**编号表**：

| 编号 | 内容 | 位置 |
|---|---|---|
| ① | 关键词 | `danmaku-quick-search` |
| ② | 搜索 / 服务器数 | `get_animes` 开头 |
| ③ | 每个服务器的结果或失败 | `make_handle_response` |
| ④ | 合计结果数 | `do_final_update` |
| ⑤ | 显示哪种选择界面 | `do_final_update` / `get_episodes` 菜单分支 |
| ⑥ | 选中项 | `run_menu_item` |
| ⑦ | 剧集列表条数 | `get_episodes` 末尾 |
| ⑧ | 拉取弹幕的 URL | `fetch_danmaku` |

另有两条排错说明（不带编号）：`列表判定[入口]`、`打分参考词「…」，前三：…`。

**构建指纹**：`build_fingerprint()`（`utils.lua`）对
`main.lua` / `menu.lua` / `utils.lua` / `options.lua` / `parse.lua` /
`dandanplay.lua` 做多项式滚动哈希（不依赖 bit 库），格式为
`build 识别到的文件数/总字节/合并哈希`。

> 吃过一次亏：设备上只更新了 `utils.lua` 没更新 `menu.lua`，新旧混着跑，
> 从现象上完全看不出来（日志是新格式、判定逻辑是旧的）。**排查第一步就看这行。**

---

## 7. 功能三：保存过滤后的弹幕

### 7.1 为什么需要

上游的 `convert_danmaku_to_xml()` 直接从 `DANMAKU.sources` 取数据，**绕过了整条
处理链**：不应用黑名单、不合并。也就是说存下来的和你看到的不是一回事，
而且永远是条数最大的那一份（实测 6592 vs 合并后的 4768）。

### 7.2 三种模式

新增 `save_danmaku_mode`，取值与实现对应：

| 模式 | 走哪套代码 | 条数（`[03]`） |
|---|---|---|
| `raw`（默认） | **上游原样实现**（`parse.lua`，逐字节未改） | 6592 |
| `filtered` | 新模块 `collect(true)` | 6579 |
| `merged` | 新模块 `collect_rendered()`，即 `RENDERED_DANMAKU` 快照 | 4768 |

`merged` 是关键：`convert_danmaku_to_ass_events()` 在合并之后把结果存了一份：

```lua
-- ★ 放在空数组检查之前，免得为空时留着上一次的旧结果
RENDERED_DANMAKU = danmakus
```

它是**浅拷贝引用**；保存时为新模块要排序，会另复制一份数组再排，
不动缓存本身。条目里已经带了 `merge_count` / `merge_mark` / `merge_scale`，
而 `pakku.merge()` 会把标记拼进 `text`（`pakku.lua:1337`），
所以写出去的 xml 正文就是 `恭喜(12)` —— 和屏幕上一致。

### 7.3 和上游怎么共存（本功能的设计重点）

> 目标：**合并上游更新时不冲突**。按这个目标拆的：

| 东西 | 放哪 | 为什么 |
|---|---|---|
| 新模式的全部实现 | **新文件** `modules/save_danmaku.lua` | 上游没有这个文件，永远不会冲突 |
| 上游原实现 | `parse.lua` 里逐字节保留 | 上游改它内部时能自动合并 |
| 转发 | `convert_danmaku_to_xml()` 开头 3 行 | 冲突面只有一个函数头 |
| 快照赋值 | `convert_danmaku_to_ass_events()` 里 1 行 | 单行新增 |
| 依赖注入 | `is_blacklisted()` 之后一次 `set_deps{}` | 见下 |

**为什么需要依赖注入**：`black_patterns` 和 `make_delay_lookup` 是 `parse.lua`
的 **local**，新模块拿不到。把它们提升成全局算「改上游代码」，
所以改成由 `parse.lua` 主动传进去：

```lua
save_ext.set_deps({
    get_sources       = function() return DANMAKU.sources end,
    get_rendered      = function() return RENDERED_DANMAKU end,
    black_patterns    = black_patterns,
    is_blacklisted    = is_blacklisted,
    make_delay_lookup = make_delay_lookup,
})
```

`get_sources` / `get_rendered` 必须是 getter —— 这两个值会被**整体替换**
（卸载时 `DANMAKU = {sources={}}`，渲染时 `RENDERED_DANMAKU = danmakus`），
捕获引用会拿到旧表。

> ⚠️ `set_deps` 必须放在 `is_blacklisted` 定义**之后**。它是全局函数，
> 在此之前还是 `nil` —— 这个坑我踩过一次（注入到 nil，filtered 直接崩）。

**转发 shim**：

```lua
function convert_danmaku_to_xml(danmaku_out)
    local handled, result = save_ext.handle(danmaku_out)
    if handled then return result end

    -- ↓↓↓ 以下为上游原样实现，请勿改动 ↓↓↓
    local danmakus = {}
    ...
```

`handle()` 返回两个值：`handled=false` 表示「这次不归我管」（raw），
调用方继续往下走；`handled=true` 表示已经处理完，`result` 是成败。
这样 shim 只有两行，上游函数的头尾都不需要改。

**标记约定**：`parse.lua` 里本项目新增/改动的地方都带 `★`，
`grep '★' modules/parse.lua` 能一次列全（共 4 处）。

### 7.4 本功能内部实现要点

**排序只在新模式做**：`pairs(DANMAKU.sources)` 的顺序不确定，
所以上游导出的行顺序每次都不一样。新模块统一按时间排序；
`raw` **故意不排**，以保持和上游逐字节一致。

**非法取值回退**：`normalize_mode()` 里除了 `filtered` / `merged` 一律当 `raw`，
所以写错值不会导致保存失败，只是回到上游行为。先 `:lower()`，大小写不敏感。

**失败要说话**：`merged` 还没渲染过时返回 `false` 并提示
「还没有合并结果可保存，请先让弹幕显示一次」，不写空文件、也不写旧文件。
（静默写错文件比不写更糟。）

**没注入依赖不甩锅**：如果 `set_deps` 漏了，`handle()` 返回 `handled=true`
+ 明确报错，**不会**返回 `handled=false` 让上游去跑 —— 那样会静默存成 raw，
比报错更难查。

**提示带模式**：成功时写明模式和条数，排查时一眼看出模式有没有生效：

```
转换 XML 弹幕成功（merged，4768 条）：/path/to/xxx.xml
```

### 7.5 与上游行为的差异

| 行为 | 上游 | 本项目 |
|---|---|---|
| `save_danmaku_mode` 缺席 / = `raw` | —— | **完全不变**（走的就是上游那段代码） |
| `filtered` / `merged` 的行顺序 | —— | 按时间排序（新模式自己的行为） |
| `filtered` / `merged` 的成功提示 | —— | 带 `（模式，N 条）` |
| 自动保存遇到同名文件 | 跳过 | 不变 |

> `raw` 的输出与上游**逐字节一致**，已用 `git show <加功能前的提交>` 取旧文件、
> 逐字节比对验证（1983 字节 / 60 行全等）。

### 7.6 已知限制

- **`merged` 依赖渲染**：没有渲染过就没有快照。`on_unload`（自动保存）时
  弹幕早就渲染过了，所以自动保存没问题；提前手动触发才会遇到。
- **`merged` 存的是展示文本**：如果 `pakku_normalize_display=yes`（默认），
  存下来的是**预处理并合并**之后的文本，不是原始文本。想要原文用 `filtered`。
- **密度调控的结果没体现**：`pakku_shrink_threshold` / `pakku_drop_threshold`
  作用在布局阶段（`merge_scale` 会被就地改小、`drop` 标记会被筛掉），
  快照里存的是**合并后、调控前**的条目。真要在文件里体现丢弃，
  得在 `adjust_density` 之后再存一次。
- **xml 转义逻辑复制了一份**：新模块里的写出格式和上游一样（转义 + `<d p="...">`），
  但代码是**复制**的 —— 复用就得改上游那个函数内部，那正是要避免的。
  代价是上游若改了 xml 格式，新模块要跟着改（xml 格式由弹幕规范定死，实际不会动）。
- **转义与解码是一对**：写出去之前把 `& < > " '` 换成实体，加载时
  `decode_html_entities()`，两者配套所以往返一致，别只改一边。

---

## 8. 核心数据结构

### 8.1 输入（uosc_danmaku 的弹幕条目）

```lua
{ time = 12.345, type = 1, size = 25, color = 0xFFFFFF, text = "我是一条弹幕", orig_time = 12.345 }
```

`type`：1/2/3 滚动，4 底部，5 顶部，6 逆向，7 高级，8/9 代码/BAS。
默认只合并 `{1,2,3,4,5}`（`DEFAULT_MERGE_TYPES`），其它类型原样透传。

### 8.2 中间结构 `ir`（对应 C++ 的 `DanmuCacheline`）

`M.build_ir(d, cfg)` 产出，所有可复用的中间量在这里预计算，避免聚类时重复算：

```lua
{
  d        = 原始弹幕,
  raw      = 原始文本,
  str      = 预处理后的文本,
  chars    = UTF-8 字符数组,
  len      = 字符数,
  mode     = 弹幕类型,
  time_ms  = 毫秒时间戳（滑动窗口用）,
  char_freq= 字符频率表,
  gram     = bigram 频率表,
  py_freq  = 拼音 token 频率表,
  py_len   = 拼音 token 总数,
}
```

### 8.3 簇 `cluster`

```lua
{ time_ms = 代表时间, irs = {ir, ...}, reasons = {"orig","edit",...},
  dists = {...}, weak_reason = "edit" }
```

### 8.4 输出（`M.merge` 的返回值）

在原始字段之外新增：

| 字段 | 含义 |
|---|---|
| `merge_count` | 该簇合并了多少条原始弹幕 |
| `merge_scale` | 字号系数（放大 >1，密度缩小时 <1，正常 =1） |
| `merge_reason` | 命中判定：`identical` / `edit` / `pinyin` / `cosine` / `orig` |
| `merge_mark` | 标记本体，如 `(12)`；未加标记时为空串 `""` |
| `text` | 合并后带标记的文本，如 `恭喜(12)` |

`parse.lua` 依赖两个字段：

- `merge_scale` 存在与否，区分「pakku 路径」和「内置合并路径」的字号算法
- `merge_mark` 用于把标记加粗 —— 用明文比对定位（先试末尾、再试开头），
  不依赖正则，所以换标记样式不需要动渲染层

### 8.5 菜单项（功能二用）

```lua
{
  title = "第1话 翻转孤独",
  hint  = 1,                                  -- 或 "动漫 | 2022 | 来源：b 站"
  value = { "script-message-to", "uosc_danmaku", "load-danmaku", ... },
  selectable = true,
}
```

`value` 是**最终要执行的命令数组**，功能二的类型判定和去重都靠它。

---

## 9. 配置流转

```
script-opts/uosc_danmaku.conf       用户写的值（注释掉就不生效）
              │
              ▼  mp.options.read_options(options, "uosc_danmaku", cb)
modules/options.lua 的 `options` 全局表     默认值在这里
              │
              ▼  pakku.merge(danmakus, options)
pakku.build_config(options)
              │   同时认 pakku_xxx 和 xxx 两种键名
              ▼
内部 cfg（带 _built = true，二次调用直接返回）
              │
              ▼
M.normalize / M.check_similar / enlarge_scale / adjust_density 等
```

**加新选项的固定套路**（4 处都要动，缺一个就不生效）：

1. `modules/options.lua` 里加默认值
2. `script-opts/uosc_danmaku.conf` 里加注释说明 + 注释掉的行
3. `pakku.build_config()` 里 `pick()` 出来做归一化/钳制（pakku 选项）
4. 在用到它的函数里消费

**文档同步**：`readme.md` 的选项全表也要加一行。
可以用下面这条命令自查有没有漏（它把 `options.lua` 里的选项名和 `readme.md`
做双向核对）：

```bash
# 见 changelog 0.8.x 的交叉核对脚本；核心是拿 `选项名` 去 readme 里找
```

---

## 10. 踩过的坑

### 10.1 Lua 语言层

#### Lua 模式的字符类按字节匹配 ⚠️

真实踩到并修掉的 bug。原来的写法：

```lua
out = out:gsub("[ 　]+", " ")   -- 想匹配「空格和全角空格」
```

`[ 　]` 在 Lua 模式里展开成**字节集合** `{0x20, 0xE3, 0x80}`，
于是任何包含 `0x80` 字节的汉字都会被咬掉一截：

```
一 (E4 B8 80) → E4 B8        -- 静默截断，不报错
```

后果是弹幕文本在预处理阶段被无声损坏。修法是按 UTF-8 字符遍历
（`normalize_spaces()`）。**同类风险**：`[，。！]` 之类的写法全部有这个问题。

#### 没有正则前瞻 / 量词区间

- `TRIM_CJK_SPACE_RE` 用了 `(?=...)`，Lua 不支持 → 改成逐字符扫描。
- pakku.js 的 forcelist 默认值是 `^23{2,}$`，Lua 模式不认识 `{n,}` →
  写了 `quantifier_to_lua()` 把 `{n}` / `{n,}` / `{n,m}` 翻译成等价的 Lua 模式。
  `{n,m}` 只能近似成「至少 n 次」。

#### 其它语言层

| 坑 | 说明 |
|---|---|
| `goto` | mpv 内置 LuaJIT 支持，但为兼容纯 Lua 5.1，`adjust_density` 里改用 `if/else` |
| 长括号嵌套 | `pakku_forcelist` 的值里有 `]]`，Lua 字面量必须用 `[=[ ... ]=]` |
| `table.remove(t, 1)` | 是 O(n)，窗口大时有开销；当前跟随文章用 FIFO，窗口通常 <100 |
| `msg` 未定义 | `utils.lua` 以前只用 `mp.msg`，从没 `require("mp.msg")`；新加的 `trace_osd` 里写 `msg.info` 就炸了。**被新加的 `pcall` 当场抓出来** |
| 裸 `pcall` 吞异常 | `pcall(do_final_update)` 出错零输出，现象和网络失败无法区分（日志停在 ④ 然后什么都没有）。现在统一走 `finish()`，出错会 `msg.error` + OSD |
| `mp.get_time()` | 实测**暂停时仍按真实时间前进**（暂停 2 秒差 2.000），去重窗口不会被暂停冻住 |

### 10.2 列表类型判定（功能二）⚠️

判「这是剧集列表还是搜索列表」踩了两次：

| 版本 | 判据 | 结果 |
|---|---|---|
| 原始 | `tonumber(it.hint)` | 真剧集列表判不出来（服务端 `episodeNumber` 不保证是数字） |
| 第一次修改 | 从 hint 抠数字 | **搜索列表被误判** —— `动漫 \| 2022 \| 来源：b 站` 里的 **2022 被当成集数**，2 条搜索候选被判定为剧集列表。**被自己的单测拦下** |
| 最终 | `item_command_kind(it)` | 可靠：直接读 `value` 里的命令名 |

教训：**能读语义就不要猜格式。** `hint` 是给人看的显示文本，
`value` 才是机器语义。现在 `hint_episode_number()` 只作为兜底，
且额外限制「整串 ≤ 12 字节、数字 ≤ 3 位」（一集番剧不会超过 999），
避免年份再次混进来。

### 10.3 网盘串流取不到集数（功能二）⚠️

`pick_auto_item()` 原来用 `mp.get_property("filename/no-ext")`，
但安卓上播网盘串流时 `path` 是 `network://…`，`filename` 只是一串
**不透明的 fileId** —— 一个数字都抠不出来。日志里「文件名集数」全程显示「无」，
集数匹配从来没生效过。

而 `parse_title()` 早就处理了这种情况（协议路径改用 `media-title`）。
修法：新增 `get_media_filename()` 抽出一套选择逻辑，
`pick_auto_item` 直接取 `parse_title()` 的 `season, episode` 返回值。

> 顺带澄清一个误解：`get_episode_number()` 对 `[01]` 这种番剧命名
> **本来就是好的** —— `format_filename("… BOCCHI THE ROCK! [01][Ma10p…]")`
> 得到 `BOCCHI THE ROCK E01`，集数 01 正常。问题只出在输入是 fileId。

### 10.4 重复选择：三个不同的来源

一共修了三次，因为**每次的成因都不一样**，值得记下来：

| 版本 | 成因 | 修法 |
|---|---|---|
| 0.8.3 | 连按按钮 → 两次搜索各排一次后续请求 | 加去重 |
| 0.8.7 | `ctx.remaining.n = math.max(0, n-1)` 下限卡在 0，多来一次回调就再收尾一遍 | `finish()` + `ctx.finished` |
| 0.8.8 | 「结果先到先显示」那段排的 `add_timeout(0.1)` 没考虑 `danmaku_auto_select`，`open_menu_select` 又选了一次 | 开自动选择时整段跳过 |
| 0.8.9 | 去重 key 带 `stage`+`context`，同一目标从不同入口进来被当成两次不同选择 | key 改为按 `item.value` |

**诊断技巧**：两次的**条数不一样**（2 条 vs 3 条）说明不是同一份列表
（3 条 = `加载数据中…` 占位 + 2 条结果）；条数一样则多半是同一份被判了两次。

### 10.5 其它

| 坑 | 说明 |
|---|---|
| `merge_scale` vs `merge_count` | `parse.lua` 里 `merge_scale` 非空就走 pakku 字号分支，会**跳过** `merge_fontsize_growth` / `merge_fontsize_max` |
| ASS 标记 | `{\b1\i1}` 是「粗体 + **斜体**」。合并标记只需要粗体，写成 `{\b1}` 即可；早期版本误带 `\i1`，后缀显示成斜体 |
| 加粗不要用正则猜 | 早期 `gsub("x(%d+)$", ...)` 会把正文里恰好以 `x12` 结尾的弹幕误加粗，也锁死了标记样式。现在由 `pakku.lua` 给出 `merge_mark`，`parse.lua` 明文比对后插 `{\b1}` |
| 双守卫互相抵消 | 0.8.7 第一版把「收尾守卫」同时写进 `finish()` 和 `do_final_update()`，`finish()` 先置位、`do_final_update()` 一进去就 return —— **自动选择被彻底废掉**。单测当场发现（trace 只到 ③）。守卫只能有一处 |
| `mpv --vo=image` 不含 OSD | 截图验证渲染时 `--vo=image` 产出纯视频帧，OSD 不会被合成（连 `--osd-msg1` 都不出现）。本项目改用「直接量字体轮廓」 |
| `--script-opts` 会被覆盖 | 它是**单个字符串选项**，重复传后者覆盖前者。要一次传多个必须用逗号：`--script-opts=a-b=1,a-c=2` |
| `--no-config` 不加载 scripts 目录 | 端到端测试时想用隔离 `MPV_HOME` 就别加 `--no-config`，否则 `MPV_HOME/scripts/` 不会被自动加载 |
| `--script=<file>` 的 `package.path` | 不含脚本目录，`require("modules/…")` 会失败。必须用 `MPV_HOME/scripts/<名字>/main.lua` 的目录布局 |

---

## 11. 开发与验证

### 11.1 功能二 / 功能三：单测（秒级）

```bash
luajit test/auto_select_test.lua     # 通过 47，失败 0
luajit test/save_danmaku_test.lua    # 通过 27，失败 0
```

两个测试都**直接从 `menu.lua` / `utils.lua` / `parse.lua` 里按标记切出真实代码**
来跑（`slice()`），不复制实现 —— 这样实现改了而测试没跟上时会直接失败，
而不是拿一份过时的副本自欺欺人。

`auto_select_test.lua` 覆盖：`get_media_filename`、`hint_episode_number`
（含「年份不算集数」）、`item_command_kind`、`looks_like_episode_list`、
`pick_auto_item`（剧集/导航项/搜索列表/未知 value）、连按去重（含 A→B→A）、
跨入口去重、收尾只跑一次、「先到先显示」抑制。

`save_danmaku_test.lua` 覆盖：`normalize_mode` 的各种取值、**`raw` 时必须返回
`handled=false` 把活让回上游**、`filtered` 过滤黑名单、`merged` 用快照且保留
`(12)` 标记、按时间排序、XML 转义、快照为空时不瞎存、所有源被屏蔽时的提示、
没注入依赖时明确报错（而不是静默甩给上游）。

`docs_check.lua` 是**文档一致性**检查（8 项）：选项覆盖、默认值逐值比对、
文档引用的函数名是否存在、目录锚点、表格列数、章节编号连续。
**加选项或改默认值之后要跑它**，否则文档会悄悄和代码脱节。

**测试抓过两个我自己写出来的 bug**（见 §10.2 和 §10.5 的「双守卫」）。
建议每加一条判定就补一条用例。

> `slice()` 找终点标记时是从**起点之后**开始找的。踩过坑：注释里提到了
> 同一个函数名，从文件头找就把注释当成了终点，切出来的片段是空的。
> 两个测试文件里都做了这个防护。

### 11.2 功能一：纯 Lua 单测（秒级）

`pakku.lua` 不依赖 mpv 也能跑：

```powershell
.\luajit.exe -e "package.path='portable_config/scripts/uosc_danmaku/?.lua;'..package.path; local p=require('modules/pakku'); print(p.pinyin_group_count())"
```

自检清单（改完必须全过）：

| 用例 | 期望 |
|---|---|
| `normalize("完结撒花！！！")` | `完结撒花` |
| `normalize("这是完全不一样的一句话")` | 原样返回，**字节数不变** |
| `normalize("ＡＢＣ１２３")` | `ABC123` |
| `normalize("你 好 吗")` | `你好吗` |
| `normalize("！！！")` | `！！！`（整条都是标点则不动） |
| `normalize("2333333")` | `23333`（forcelist 的 `{n,}` 量词翻译） |
| `edit_distance("哈哈哈","哈哈哈啊")` | `1` |
| `pinyin_distance("在","再")` | `0` |
| `pinyin_distance("是","事")` | `0` |
| `pinyin_distance("你","我")` | `> 0` |
| `pinyin_group_count()` | `398` |
| `build_config({})` 的各字段 | 全部等于 §5.7 表里的 pakku.js 默认值 |
| 合并 3 条相同弹幕后的 `text` | `恭喜(3)`，`merge_mark == "(3)"` |
| `to_subscript` 覆盖多位数 | 1/2/5/9/10/12/23/47/69/100/1234 → `₁`…`₁₂₃₄` |
| `mark_subscript=true` | 标记变成 `₍₃₎` |
| `mark=prefix` | 文本变成 `(3)恭喜` |
| `mark=off` | `merge_mark == ""`，文本保持 `恭喜` |
| 未合并的单条且正文以 `x12` 结尾 | `merge_count == 1`、`merge_mark == ""`、`text` 保持原文 |

### 11.3 真实弹幕压测

工作区自带 3 集弹幕（合计 20086 条），跑一遍确认合并数量和耗时：

```
03   6592 -> 4773   306ms  最多(60)
04   6702 -> 4884   314ms  最多(69)
07   6792 -> 4709   307ms  最多(47)
合计 20086 -> 14366（71.5%），平均 309ms/集
```

期望的 top 结果形态：`？？？？？？？(60)`、`kksk(46)`、`👍...👍(69)`、`波门(47)`
这类刷屏弹幕。

### 11.4 端到端跑 mpv

**功能一的自动加载有两个前置条件**，缺一个就什么都不发生：

1. `duration >= 60`（`main.lua` 里硬编码判断，短视频直接 return）
2. `danmaku-history.json` 里 `show_danmaku` 为 `true`

所以端到端测试需要：

```powershell
# 1. 用独立 MPV_HOME，避免污染真实便携配置
$env:MPV_HOME="$PWD\_e2ecfg"
# 2. 造一个 >=60s 的合成视频（纯 Y4M，脚本生成即可；注意要 16:9，
#    32x32 会被当成 1920x1920）
# 3. 把弹幕文件复制成 <视频同名>.xml
# 4. 预置 files/danmaku-history.json = {"show_danmaku": true}
# 5. 跑并看统计
.\mpv.com --vo=null --ao=null --length=6 --msg-level=all=v _e2e.y4m
```

日志里应出现：

```
[uosc_danmaku] pakku: 拼音字典载入 6763 个汉字 / 398 个拼音组
[uosc_danmaku] pakku: 6702 条 -> 4884 条（簇 4884，最多合并 69；==467 ≤1058 P46 247%；丢弃 0，缩小 0，放大 73，耗时 319ms）
[uosc_danmaku] 已解析 4884 条弹幕
```

**功能二**的端到端：让脚本自己去 `MPV_HOME/scripts/<名字>/main.lua` 加载
（不要用 `--script=` 指定文件，见 §10.5），再加一个只负责发消息的触发脚本：

```lua
mp.register_event("file-loaded", function()
  mp.add_timeout(1.0, function() mp.commandv("script-message", "danmaku-quick-search") end)
  mp.add_timeout(5.0, function() mp.command("quit") end)
end)
```

`--script-opts` 指向一个必定连不上的地址（如 `http://127.0.0.1:1`），
这样流程会一路走到 ⑤ 并且不需要真实网络：

```
[flow] ① 关键词：…
[flow] ② 搜索「…」，1 个服务器
[flow] ③ http://127.0.0.1:1 失败：exit -3 子进程没起来（可能缺 curl）
[flow] ④ 合计 0 条搜索结果
[flow] 列表判定[搜索]：搜索列表 → 按标题打分（0 条，文件名集数 1）
[flow] ⑤ 显示键盘列表（0 条），等待回车确认
```

> 沙箱里 mpv 的 subprocess 走管道捕获会被拦（`Subprocess failed: init`），
> 失败发生在**起进程**那一步而不是网络 —— 这正好绕过了限制，把流程推到了 ⑤。
> 真实 HTTP 跑不通，所以**联网成功那一段只能靠设备实测**。

验证渲染层可以临时在 `convert_danmaku_to_ass_events` 末尾把 `ass_events`
dump 到文件，检查标记格式与字号。下面是**默认模式**（普通数字跟随正文字体）：

```
0.00  50  {\pos(960, 869)}{\c&HFFFFFF&}2026/2/5簽到{\b1}(5)
2.00  72  {\move(2028, 251, -108, 251)}{\c&HFFFFFF&}簽{\b1}(10)
```

下标模式（`mark_subscript=yes`）下才会带 `\fs`：

```
0.00  50  {\pos(960, 869)}{\c&HFFFFFF&}2026/2/5簽到{\b1\fs90}₍₅₎
2.00  72  {\move(2100, 251, -180, 251)}{\c&HFFFFFF&}簽{\b1\fs130}₍₁₀₎
```

自检项（对 dump 结果做计数）：

| 检查 | 期望 |
|---|---|
| 默认模式：含 `{\b1}(N)` 的行数 | `> 0` |
| 默认模式：含 `\fs` / 下标 `₍` / 旧式 `[xN]` 的行数 | `0` |
| 含 `\i1`（斜体）的行数 | `0` |
| 下标模式：`\fsN == event_fontsize × pakku_mark_scale` | 全部一致 |
| 字号分布 | 从 `50` 起，最大不超过 `100`（2 倍上限） |
| libass 缺字形告警 | 无 |

> 注意区分两个字号：dump 第 2 列是**弹幕正文**的字号（受 `pakku_enlarge_*`
> 控制，上限 100）；只有下标模式标记才有独立的 `\fs`，且会超过 100
> （如 `\fs130`），属正常。默认模式 `(12)` 没有独立字号。

**功能三的端到端**：用同一套 `testdata` 弹幕，把三种模式各跑一遍并数条目数。
视频与 xml 同名（`autoload_local_danmaku` 的要求），触发用
`script-message immediately_save_danmaku`（自动保存会因为同名文件已存在而跳过）：

```
mode=raw       6592 条   日志是「转换 XML 弹幕成功： <路径>」← 上游原样提示
mode=filtered  6579 条   （blacklist_path 里放了「簽到」，命中 13 条）
mode=merged    4768 条   （含 791 条带 (N) 标记，按时间有序，无裸 &）
```

**`raw` 那一行是判断 shim 有没有写对的关键**：它的提示**不带** `（模式，N 条）`，
说明走的是上游那段代码，而不是新模块。

还做了一次更硬的验证：用 `git show <加功能之前的提交>` 取旧版 `parse.lua`，
把两边的 `convert_danmaku_to_xml()` 函数体抽出来逐字节比对 ——
**1983 字节 / 60 行全等**，证明上游实现确实原封不动。

这条路径能真跑通，所以**不要**只靠单测：单测用的是桩数据，
而这里能验到「渲染时确实填了 `RENDERED_DANMAKU`」这个集成点。

> 沙箱里 mpv 的 subprocess 被拦（起不了 curl），但**本地 xml 不需要网络**，
> 所以功能三能完整跑通；功能二的联网那一段仍然只能靠设备实测。

### 11.5 语法检查（改任何 Lua 后必跑）

```powershell
Get-ChildItem -Recurse portable_config\scripts -Filter *.lua | ForEach-Object {
  .\luajit.exe -e "local f,e=loadfile([[$($_.FullName)]]); if not f then io.write(e); os.exit(1) end"
}
```

---

## 12. 扩展指南

### 功能一

#### 加一条新的相似判定规则

1. 在 §3 里写判定函数（输入两条 `ir`，输出 `true/false`）
2. 在 `M.check_similar()`（`pakku.lua:914`）的四级判定链里插入，**注意顺序即优先级**
3. 若需要新的预计算量，加进 `M.build_ir()`（`pakku.lua:886`）
4. 在 `dominant_reason()` 的 `rank` 表里给新 reason 一个权重
5. 在 `stats` 表里加同名字段，`M.merge()` 会自动统计
6. 若要有独立开关，按 §9 的 4 处套路加选项

#### 换掉 / 更新拼音字典

```powershell
# 从 pakku.js 的原始表重新生成「编码:汉字串」数据块
# 输入：pakku.js/pakkujs/similarity/repo-cpp/src/pinyin_dict.txt
# 输出：替换 pakku.lua 的 PINYIN_SRC 内容（约 116–514 行）
# 校验：组数应为 398，汉字数应为 6763
```

只需保证同音字落在同一组，算法不关心数字的具体含义。

#### 调整密度策略

见 §5.5 的常量表。`judge_drop()` 决定丢弃概率，权重来自 `merge_count`。

#### 改合并后的展示文本

`choose_display_text()`（`pakku.lua:1185`）：
先按预处理文本分组取最高频，并列时取长度中位数；
`pakku_normalize_display=no` 时改显示该组里出现最多的**原始**文本。

#### 改合并标记的样式

只需要动 `make_mark_tag()`（`pakku.lua:1067`）这一个函数，返回什么就显示什么：

```lua
local function make_mark_tag(count, cfg)
    if cfg.mark == "off" or count <= cfg.mark_threshold then return "" end
    if cfg.mark_subscript then
        return SUBSCRIPT_LPAREN .. to_subscript(count) .. SUBSCRIPT_RPAREN
    end
    return "(" .. count .. ")"
end
```

位置（前/后缀）由 `make_mark()`（`pakku.lua:1078`）按 `cfg.mark` 拼装。
**渲染层不用改** —— `parse.lua` 拿的是 `entry.merge_mark` 明文，多长都能定位。

#### 调整标记的字号

默认模式 `(12)` **没有独立字号**，直接跟随正文字体，`parse.lua` 里的
`mark_scale` 会被强制为 1，标签只剩 `{\b1}`。

只有下标模式才会折算 `\fs`，在 `parse.lua` 的标记字号分支里：

```lua
local mark_scale = tonumber(options.pakku_mark_scale) or 1
if mark_scale < 0.1 then mark_scale = 1 end
if options.pakku_mark_subscript == false then mark_scale = 1 end   -- 默认走这条

local tag = "{\\b1"
if mark_scale ~= 1 then
    tag = tag .. string.format("\\fs%d", math.max(1, math.floor(event_fontsize * mark_scale + 0.5)))
end
tag = tag .. "}"
```

### 功能二

#### 加一条自动选择的关键词规则

`AUTO_SELECT_TYPE_RULES`（类型加权）和 `AUTO_SELECT_NOISE_RULES`（噪音扣分）
都是 `{ pattern = "…", score = ±N }` 的表，**照格式加一行即可**。
`pattern` 用 `string.find` 的**纯文本**模式匹配（不是 Lua 模式），
所以里面的 `%`、`(` 之类不需要转义。

加完记得在 `test/auto_select_test.lua` 补一条用例。

#### 改选择界面

`do_final_update` 和 `get_episodes` 各有三条分支（uosc 菜单 / 键盘列表 /
无可用界面）。要让自动选择在某个新入口也生效，**优先挂在 `open_menu_select()`
开头** —— 它是所有「没有 uosc 时」的列表入口，一刀能覆盖全部降级路径。

#### 加一个新的流程节点

1. 在合适的位置调 `trace_osd("⑨ …", …)`（编号接在 ⑧ 后面）
2. 在本文 §6.5 的编号表里加一行
3. `readme.md` 的流程跟踪示例同步一下

`trace_osd` **不需要**改开关控制 —— 日志部分本来就是永远写的。

---

## 13. 待办

- [ ] 把 pakku 选项接进 uosc 菜单（`modules/menu.lua`），支持运行时切换
- [ ] 给 `M.merge()` 加增量/分块处理，避免超长视频（>3 万条）一次性聚类
- [ ] 把 `pakku_threshold` 从「固定秒数」改成按弹幕密度自适应
- [ ] 给功能二的其余判定补单测（目前覆盖 `pick_auto_item` 一族）
- [ ] 给 `danmaku-quick-search` 加入口节流，从根上避免连按发两次搜索
      （现在只是去重后续命令，请求本身仍会白发一次）
- [ ] 把 `AUTO_SELECT_NOISE_RULES` 挪到 `uosc_danmaku.conf`，让用户能自己加词
- [ ] 给 `build_fingerprint` 加一个「哪个文件变了」的输出，目前只有合并哈希
- [ ] 功能三：`merged` 存的是「合并后、密度调控前」的快照，
      想让 xml 里也体现 `pakku_drop_threshold` 丢掉的那些，得挪到
      `adjust_density` 之后再存
- [ ] 功能三：可以考虑再存一份 json（带 `merge_count` / `merge_reason`），
      方便做合并质量的统计分析，xml 格式塞不下这些元数据
- [ ] 功能三：`filtered` / `merged` 的 xml 写出格式是从上游**复制**的，
      上游若改了格式这里要手动同步 —— 目前靠 `README` 和注释提醒，
      可以考虑加一条测试比对两边生成的 xml 结构

---

## 14. 许可与合规

### 14.1 结论：本项目整体 GPL-3.0

| 组件 | 许可证 | 是否随仓库分发 |
|---|---|---|
| `modules/pakku.lua`（本项目） | **GPL-3.0** | 是 |
| uosc_danmaku（宿主，vendored） | MIT，© 2024 吴南李 | 是 |
| pakku.js（算法与拼音字典来源） | GPLv3 | 否（仅衍生） |
| uosc（运行时依赖） | LGPL-2.1 | 否 |
| `testdata/*.xml` | 各弹幕作者 | 是 |

判定依据：`pakku.lua` 复用了 pakku.js 的四级判定逻辑、聚类/标记/密度调控算法、
文本预处理规则、**6763 字的拼音字典数据**以及各项默认配置值，构成衍生作品。
GPLv3 是强 copyleft，衍生作品必须以 GPLv3 分发。

MIT（uosc_danmaku）与 GPLv3 兼容，可并入 GPLv3 作品一起分发；
未改动的上游文件仍可按 MIT 使用，其许可证全文保留在
`portable_config/scripts/uosc_danmaku/LICENSE`。

完整说明见 [`THIRD-PARTY.md`](THIRD-PARTY.md)。

> **功能二（无键盘支持）本身不涉及 pakku.js**，是独立写的，但它和
> `pakku.lua` 在同一个仓库、同一份分发物里，所以整体仍是 GPL-3.0。

### 14.2 分发时的义务

1. 保留 `LICENSE` 与 `portable_config/scripts/uosc_danmaku/LICENSE`
2. 保留 `THIRD-PARTY.md`（或等效的第三方声明）
3. 修改 GPL 部分后需一并提供修改后的源码

### 14.3 隐私自查（每次入库前建议重跑）

| 检查项 | 结果 |
|---|---|
| 弹幕 `p` 属性字段 | 只有 `时间,类型,字号,颜色` 四个，**无**用户 ID / 用户哈希 / 发送时间戳 |
| 弹幕正文里的手机号 / QQ / 邮箱 / 网址 / 群号 | 扫描后无真实命中（唯一疑似项是一条经纬度坐标，属原视频公开弹幕内容） |
| 跟踪文件里的本机绝对路径 | 无（文档里一律用 `$PWD` / 相对路径） |
| 跟踪文件里的用户名 / 邮箱 | 无（唯一出现的是 `209313510+lnmp30@users.noreply.github.com`，是**公开的** GitHub noreply 地址） |
| `portable_config/files/`（观看历史、弹幕历史） | 已在 `.gitignore` 中排除，未入库 |
| `portable_config/cache`、`fonts`、`shaders`、`icc` | 已排除 |
| 调试残留（`_e2e*`、`_frames`、`_*.lua`） | 已排除，仓库中无残留 |
| 第三方博客原文存档 | 已移出仓库（`.gitignore`），仅本地保留 |

跑法（在仓库根目录）：

```powershell
git grep -nEI "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}" -- . |
  Where-Object { $_ -notmatch 'noreply|iskolbin|ikaros' }
git grep -nEI "[A-Z]:\\\\Users|/Users/|/home/[a-z]|AppData" -- .
```

（`iskolbin` / `ikaros` 是上游第三方库作者的署名，属正常。）

### 14.4 git 历史重写（2026-10-05 已完成）

首次推送后做过一次历史重写，处理掉两处已经进入历史的问题：

| 问题 | 处理 |
|---|---|
| 提交者邮箱是个人 QQ 邮箱 | 全部提交的 author + committer 改为 `209313510+lnmp30@users.noreply.github.com` |
| 第三方博客原文存档留在历史里 | 从全部提交中移除 |

做法是**手工重建**，没有用 `git filter-branch`：

- 用 `git cat-file commit` 取出原提交对象，按第一个空行切出原始信息
- `git read-tree` 把原提交的 tree 装进索引 → `git rm --cached` 剔除博客存档
  → `git write-tree`
- 用 `GIT_AUTHOR_*` / `GIT_COMMITTER_*` 环境变量（时间、姓名原样，邮箱替换）
  调 `git commit-tree`

之所以不用 `filter-branch`：它在 Windows 上把 filter 命令交给 `sh -c` 执行，
中文路径要穿过 PowerShell → git → sh 三层，编码很容易出问题。

重写结果逐项核对过：提交信息、作者名、作者时间、提交时间全部原样；
每个提交相对旧版的 diff 只有那一个文件；最终 HEAD 的 tree 与重写前**完全相同**。

**遗留注意事项：**

- 强推**不会立刻**从 GitHub 服务端删掉旧提交对象。知道旧 SHA 的人在一段时间内
  仍能按 SHA 访问，网页缓存也可能还在。要彻底清除需要联系 GitHub Support，
  或者删库重建。
- 本仓库的 `user.email` 是**本地**配置（`git config --local`），全局配置未动。
  想在所有仓库统一，执行
  `git config --global user.email "209313510+lnmp30@users.noreply.github.com"`。
- 重写前的历史保留在 `refs/backup/pre-rewrite`。确认远端没问题后可以删：

  ```powershell
  git update-ref -d refs/backup/pre-rewrite
  git reflog expire --expire=now --all
  git gc --prune=now
  ```

---

## 附录：故障排查索引

按「日志里看到什么」查「该看哪里」。

| 日志 / 现象 | 含义 | 去哪里看 |
|---|---|---|
| `已解析 N 条弹幕` 条数明显少于弹幕总数 | pakku 合并生效 | §5 |
| `已解析` 完全不出现 | 弹幕没加载成功 | §3 链路、`readme.md` 排查 |
| `pakku: 拼音字典载入 6763 个汉字 / 398 个拼音组` | 合并被调用了 | §5 |
| 这条都没有 | `pakku_enable` 没生效或 conf 编码不是 UTF-8 | §9 |
| `uosc_danmaku+pakku 2.2.0 build X/Y/Z` | 构建指纹 | §6.5；**对不上就是文件没拷全** |
| `[flow] ①`~`④` 后什么都没有 | 卡在「选番剧」 | §6.3 |
| `[flow] ⑤ 显示键盘列表` | 没装 uosc，弹的是纯键盘列表 | §6.3，开 `danmaku_auto_select` |
| `[flow] ⑤ 无可用的选择界面` | 既没 uosc 也没 `mp.input` | §6.3 |
| `[flow] 列表判定[入口]：…` | 这份列表被当成什么、谁在选 | §6.3 |
| `[flow] 打分参考词「…」，前三：…` | 为什么是它分最高 | §6.3 |
| `自动选择：忽略重复触发（…）` | 去重拦下了一次重复 | §6.4 |
| `HTTP 请求失败：Exit code: -2` + `0 0 0 0` | **不是网络错误**，请求被自己掐掉了 | §6.4 |
| `exit -3 子进程没起来` | mpv 调不起 curl（安卓常见） | `readme.md` 排查 |
| `该集弹幕内容为空（服务器 / 剧集 N）` | 那集在那个服务器上确实没弹幕 | §6.3，多半是选中了特番 |
| `搜索结果处理出错：…` | 收尾过程抛异常（以前会被静默吞掉） | §10.1 |
| `搜索结果处理出错` 里带 `attempt to index global 'msg'` | `utils.lua` 少了 `require("mp.msg")` | §10.1 |
| 下标标记显示成方框 | 字体缺 `U+2080-2089` 字形 | 用默认的 `(12)`，§5.4 |
| 合并标记是斜体 | ASS 标签里误带了 `\i1` | §10.5 |
| `转换 XML 弹幕成功（模式，N 条）` | 保存成功，**模式写在这里** | §7 |
| 存出来的条数和弹幕总数一样、没有 `(12)` | `save_danmaku_mode` 还是 `raw` | §7.2 |
| 黑名单没生效在存出来的文件里 | 模式是 `raw`（raw 不过滤黑名单） | §7.2 |
| `还没有合并结果可保存，请先让弹幕显示一次` | `merged` 依赖渲染快照 | §7.3 |
| `已存在同名弹幕文件：…` | 自动保存不覆盖已有文件 | 手动发 `immediately_save_danmaku` |
| `此弹幕文件不支持保存至本地` | 网络串流且没设 `save_danmaku_path` | `readme.md` 其余选项 |
