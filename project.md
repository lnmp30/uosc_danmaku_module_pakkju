# 开发地图 · uosc_danmaku × pakku

> 本文件面向**改代码的人**。用户使用说明见 [`readme.md`](readme.md)，版本历史见 [`changelog.md`](changelog.md)。

---

## 1. 这是什么

把 [pakku.js](https://github.com/xmcp/pakku.js) 的弹幕合并算法移植进 mpv 弹幕插件
[uosc_danmaku](https://github.com/Tony15246/uosc_danmaku)，以纯 Lua 模块的形式落地。

uosc_danmaku 自带的合并（`merge_tolerance`）只能做**文本完全相同**的合并；
移植后新增四级相似判定 + 滑动窗口聚类，能做到：

- `完结撒花` / `完结撒花！！！` → 同一条（文本预处理）
- `哈哈哈` / `哈哈哈啊` → 同一条（字符频率编辑距离）
- `在` / `再`、`是` / `事` → 同一条（拼音距离，内置 6763 字拼音字典）
- `弹幕` / `弹幕啊` → 同一条（bigram 余弦相似度）

参考实现与素材来源：工作区里的 `pakku.js-master/`，以及
`在 uosc_danmaku 中集成 pakkujs 弹幕合并算法.md`（博客原文转码稿）。

---

## 2. 文档分工

| 文档 | 读者 | 内容 |
|---|---|---|
| `readme.md` | 普通用户 | 怎么开、选项怎么调、出问题怎么查 |
| `project.md` | 开发者 | 代码在哪、数据怎么流、怎么扩展、有哪些坑 |
| `changelog.md` | 所有人 | 每个版本改了什么、为什么改 |
| `THIRD-PARTY.md` | 分发者 | 各组件来源与许可证，以及为什么本项目是 GPL-3.0 |
| `LICENSE` | 所有人 | GPL-3.0 全文 |

> **许可证速查**：本项目整体 **GPL-3.0**。因为 `modules/pakku.lua` 是
> [pakku.js](https://github.com/xmcp/pakku.js)（GPLv3）的衍生作品；
> 宿主 uosc_danmaku 是 MIT，MIT 与 GPLv3 兼容。
> 详见 [`THIRD-PARTY.md`](THIRD-PARTY.md) 与 §15。

---

## 3. 工作区总览

```
mpv_pakkujs/
├── mpv.exe / mpv.com            mpv v0.41.0 播放器（含 luajit、lua51.dll）
├── luajit.exe                   独立 LuaJIT，用来跑纯 Lua 单元测试
├── alass.exe                    字幕对齐工具（本次工作无关）
├── portable_config/             mpv 便携配置根目录（脚本、着色器、字体都在这里）
│   ├── scripts/
│   │   ├── uosc/                UI 框架（上游代码，未改动）
│   │   └── uosc_danmaku/        ★ 本次工作的主战场
│   └── script-opts/
│       └── uosc_danmaku.conf    ★ 新增 pakku 选项段
├── pakku.js-master/             算法参考实现（TypeScript + C++/WASM）※ 未入库
│   └── pakkujs/similarity/repo-cpp/src/
│       ├── main.cpp             相似判定与聚类的权威实现
│       └── pinyin_dict.txt      汉字 → {声母,韵母} 原始数据（6763 条）
├── testdata/                    回归测试用的弹幕文件（3 集，共 20086 条）
│   └── [DMG&VCB-Studio] BOCCHI THE ROCK! [NN][Ma10p_1080p][x265_flac].xml
├── LICENSE                      GPL-3.0 全文
├── THIRD-PARTY.md               第三方组件与许可证说明
├── readme.md / project.md / changelog.md
└── 在 uosc_danmaku 中集成 pakkujs 弹幕合并算法.md
                                 第三方博客存档，仅本地参考 ※ 未入库
```

> 标「※ 未入库」的都在 `.gitignore` 里：`pakku.js-master/` 是第三方检出，
> 博客存档是他人版权内容，都不随本仓库分发。

`★` 标记的是本次新增或修改的部分：

| 文件 | 状态 | 说明 |
|---|---|---|
| `portable_config/scripts/uosc_danmaku/modules/pakku.lua` | **新增** | 1398 行 / 57 KB，算法本体 |
| `portable_config/scripts/uosc_danmaku/modules/options.lua` | 修改 | 新增 23 个 `pakku_*` 选项 + 一键搜索键位选项 |
| `portable_config/scripts/uosc_danmaku/modules/parse.lua` | 修改 | 合并分支接入、`merge_mark` 加粗与字号补偿、字号缩放 |
| `portable_config/scripts/uosc_danmaku/modules/menu.lua` | 修改 | 新增 `danmaku-quick-search` 消息（无键盘环境的一键搜索） |
| `portable_config/scripts/uosc_danmaku/main.lua` | 修改 | `require("modules/pakku")`、一键搜索的键位绑定 |
| `portable_config/script-opts/uosc_danmaku.conf` | 修改 | 新增 pakku 选项段（已按 pakku.js 默认值启用） |

---

## 4. 运行链路

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
        convert_danmaku_to_ass_events(force)      ← parse.lua:638
                              │
                 ┌────────────┴─────────────┐
                 │ 1. 逐源展开 + 延迟校正    │  make_delay_lookup()
                 │ 2. 黑名单过滤             │  is_blacklisted()
                 │ 3. 多源按时间归并         │  new_min_heap() 小顶堆
                 └────────────┬─────────────┘
                              ▼
                 ┌────────────┴─────────────┐
                 │ 合并                      │
   pakku_enable  ├─ yes → pakku.merge()      │  ★ 本次接入
        =no      └─ no  → merge_duplicate_   │
                              danmaku()      │
                 └────────────┬─────────────┘
                              ▼
                 ┌──────────────────────────┐
                 │ 布局：滚动/顶部/底部各算 y │  DanmakuArray
                 │ 字号：fontsize×merge_scale │  ★ 本次新增分支
                 │ 文本：ASS 转义 + 标记加粗 │  ★ 本次新增分支
                 └────────────┬─────────────┘
                              ▼
                    COMMENTS = ass_events
                              │
                              ▼
          modules/render.lua → mp.set_osd_ass() / uosc 层
```

**关键点**：`pakku.merge()` 的位置在**黑名单过滤之后、布局之前**，且处理的是
全部弹幕源的合并结果，所以它替换的是「合并」这一步，不碰时间轴、不碰渲染。

---

## 5. uosc_danmaku 模块职责（改了哪些）

| 文件 | 职责 | 本次改动 |
|---|---|---|
| `main.lua` | 入口、事件注册、脚本消息、全局状态 | 加一行 `require("modules/pakku")` |
| `modules/options.lua` | 选项默认值 + `mp.options` 读取 | 新增 pakku 选项段 |
| `modules/parse.lua` | 弹幕解析、合并、ASS 事件生成 | 合并分支、字号分支、加粗分支 |
| `modules/render.lua` | 把 `COMMENTS` 交给 mpv 渲染 | 无 |
| `modules/menu.lua` | uosc 菜单/搜索/样式面板 | 无（pakku 选项目前只走 conf） |
| `modules/utils.lua` | 通用工具（UTF-8、堆、JSON…） | 无 |
| `modules/guess.lua` `hash.lua` `md5.lua` `aes.lua` `base64.lua` `inflate.lua` | 文件名识别、哈希匹配、站点接口解密 | 无 |
| `apis/*` `sites/*` `dicts/*` | 各弹幕源的接口实现 | 无 |

---

## 6. `modules/pakku.lua` 内部结构

文件按 8 个编号章节组织，每章开头都有 `-- n. 标题` 分隔注释，便于 `grep '^-- [0-9]'` 定位。

| 章节 | 行号 | 内容 |
|---|---|---|
| 头部文档 | 1–38 | 用法、接口、字段说明 |
| **0. UTF-8 小工具** | 63–102 | `utf8_char_list` `utf8_codepoint` `utf8_count` `is_cjk_codepoint` |
| **1. 拼音字典** | 104–539 | `PINYIN_SRC` 数据块（116–514）、`pinyin_dict()` 懒加载（519） |
| **2. 文本预处理** | 542–670 | `ENDING_CHARS`、`WIDTH_TABLE`、`normalize_spaces()`（581）、`quantifier_to_lua()`（613）、`M.normalize()`（635） |
| **3. 相似度计算** | 673–771 | `freq_of_chars` `freq_of_pinyin` `freq_distance` `make_bigrams` `gram_cosine`、`M.edit_distance`（752） `M.pinyin_distance`（759） `M.cosine_similarity`（767） |
| **4. 配置** | 774–879 | `pick` `tonum` `tobool`、`M.build_config()`（806），标记相关配置都在这一段 |
| **5. 聚类** | 882–1017 | `M.build_ir()`（886） `M.check_similar()`（914） `cluster()`（971） |
| **6. 字号放大 / 标记** | 1020–1085 | `enlarge_scale()`、`SUBSCRIPT_DIGITS`、`to_subscript()`（1045）、`make_mark_tag()`（1067）、`make_mark()`（1078） |
| **7. 密度调控** | 1088–1178 | `M.dispval()` `judge_drop()` `M.adjust_density()`（1114） |
| **8. 对外主入口** | 1181–1398 | `choose_display_text()`（1185） `dominant_reason()` `M.merge()`（1250） |

### 合并标记的生成

标记不靠正则猜，而是由 `make_mark_tag(count, cfg)` 直接生成、写进
`entry.merge_mark`，`parse.lua` 拿它做明文比对定位再插 ASS 覆盖标签。
这样换任何标记样式都不用改渲染层的正则。

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

1. **天生小**：Microsoft YaHei 下下标数字只有正文数字的 55.4% 高
2. **比例随字体浮动**：实测 7 个字体在 47.0%（MS Gothic）~ 63.3%（Verdana）之间

也就是说同一个 `\fs` 值在不同字体、不同机器上观感不一致，没法得到一个
稳定的默认值。要补偿只能加 `\fs`（就是 `pakku_mark_scale` 做的事），
但补偿倍数本身又依赖字体。

改成普通数字 + 半角括号 `(12)` 后，标记直接跟随正文字体，
既不需要补偿、也不会随字体变样，横向占用还更小。

下标形式仍保留在 `mark_subscript=yes` 后面（代码里 `to_subscript()` 和
`SUBSCRIPT_LPAREN/RPAREN` 都没删），想要 pakku.js 原始观感随时可以切回去。

#### 下标模式下的字号补偿（pakku_mark_scale）

**pakku.js 没有给标记单独设过字号** —— `make_mark_meta()` 只是把
`₍${to_subscript(cnt)}₎` 拼到文本上，剩下的交给 B 站播放器按弹幕字号渲染。
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
| `1.8`（默认值） | 下标数字与正文数字同高，视觉上就是正常大小的数字 |

实现上由 `parse.lua:760` 起算：`\fs` 取 `event_fontsize × pakku_mark_scale`，
标签形如 `{\b1\fs90}₍₅₎`。**只对下标标记生效**，
`mark_subscript=no`（默认）时 `mark_scale` 被强制为 1，标签退化成 `{\b1}(5)`。

> 下标数字在 Microsoft YaHei 下是**贴着基线**的（底部 106.83 vs 正文数字
> 107.13），所以只需要放大、不需要再补 `\rise`。

### 默认值对齐 pakku.js

`M.build_config()` 里所有 `pick(o, name, default)` 的 default、
以及 `options.lua` / `uosc_danmaku.conf` 的取值，都对齐
`pakku.js-master/pakkujs/background/config.ts` 的 `DEFAULT_CONFIG`：

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
| `pakku_mark_scale` | 1.8 | **无对应项**（pakku.js 不给标记单独设字号，见上） |
| `pakku_mark_threshold` | 1 | `MARK_THRESHOLD` |
| `pakku_forcelist` | 23333 / 66666 | `FORCELIST` |
| `pakku_shrink_threshold` / `pakku_drop_threshold` | 0 | `SHRINK_THRESHOLD` / `DROP_THRESHOLD` |

**三处有意偏离**（都写在 `options.lua` 的注释里）：

1. **标记的位置**：`pakku_mark=suffix`。pakku.js 默认 `DANMU_MARK='prefix'`，
   标在弹幕开头（`(12)文本`）；本实现按使用习惯标在**末尾**（`文本(12)`）。
2. **标记的字形**：`pakku_mark_subscript=false` → `(12)`。pakku.js 默认用下标
   `₍₁₂₎`，本实现改用普通数字跟随正文字体。理由见上一节。
   `(12)` 这个具体形式在 pakku.js 里没有对应项（它只有 `₍₁₂₎` 和 `[x12]`）。
3. `pakku_enable` 在库层面（`options.lua`）默认仍是 `false`，
   但本项目自带的 `uosc_danmaku.conf` 里显式写了 `pakku_enable=yes`。
   这样库升级不会突然改变已有用户的行为，而本项目装好即用。

### 公开 API

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

### 兼容性设计

- `require("mp.msg")` 和 `require("mp.utils")` 都用 `pcall` 包住，失败时退化成空实现，
  因此本模块**可以脱离 mpv、用裸 luajit 直接单测**。
- `pick(o, name, default)` 同时认 `o.pakku_xxx` 和 `o.xxx` 两种键名，
  所以既能把 uosc 的 `options` 全局表直接丢进去，也能在测试里传精简 table。

---

## 7. 与原始文章的对照

文章给的是另一份（未公开的）Lua 实现的行号，这里给出本实现的对应位置：

| 文章提到 | 文章行号 | 本实现位置 | 备注 |
|---|---|---|---|
| `PINYIN_DICT` | `modules/pakku.lua:16` | `pakku.lua:116` `PINYIN_SRC` + `pakku.lua:519` `pinyin_dict()` | 改为「编码→汉字串」压缩存储，398 行 |
| 文本预处理 | `modules/pakku.lua:436` | `pakku.lua:635` `M.normalize()` | 空格处理改成逐字符，见 §10 |
| `M.edit_distance` | `modules/pakku.lua:488` | `pakku.lua:752` | 算法一致 |
| `M.cosine_similarity` | `modules/pakku.lua:522` | `pakku.lua:767` | 算法一致（未采用 C++ 的环绕 bigram） |
| `cluster` | `modules/pakku.lua:578` | `pakku.lua:971` | 一致，自后向前扫描窗口 |
| 密度调控 | 未给行号 | `pakku.lua:1114` `M.adjust_density()` | 按 `post_combine.ts` 实现 |

文章的默认值参数与 pakku.js 官方默认不同（文章写 `threshold` 短、
放大「10 条起、以 10 为底」）。本实现**以 pakku.js 的 `DEFAULT_CONFIG` 为准**，
对照表见 §6 的「默认值对齐 pakku.js」。

### 拼音字典编码说明（重要）

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
`main.cpp` 的用法是按顺序把 `first` 和（非 0 的）`second` 两个 token 塞进频率表，
所以本实现也照做：

```lua
PINYIN_DICT[汉字] = first * 64 + second      -- 64 > max(second) = 55
-- 取用时
f[math.floor(code / 64)] += 1
if code % 64 > 0 then f[code % 64] += 1 end
```

这样 `在`(zai) 和 `再`(zai) 产生完全相同的 token 多重集，拼音距离为 0。
**不需要**知道数字对应的具体拼音字符串——判定只依赖等价性。

---

## 8. 核心数据结构

### 8.1 输入（uosc_danmaku 的弹幕条目）

```lua
{ time = 12.345, type = 1, size = 25, color = 0xFFFFFF, text = "我是一条弹幕", orig_time = 12.345 }
```

`type`：1/2/3 滚动，4 底部，5 顶部，6 逆向，7 高级，8/9 代码/BAS。
默认只合并 `{1,2,3,4,5}`（`DEFAULT_MERGE_TYPES`），其它类型原样透传。

### 8.2 中间结构 `ir`（对应 C++ 的 `DanmuCacheline`）

`M.build_ir(d, cfg)` 产出，所有可复用的中间量都在这里预计算，避免聚类时重复算：

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

`nearby` 队列按时间递增维护未定型的簇，代表时间落后超过 `threshold` 秒就输出定型。

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
- `merge_mark` 用于把标记加粗——用明文比对定位（先试末尾、再试开头），
  不依赖正则，所以换标记样式不需要动渲染层

---

## 9. 配置流转

```
script-opts/uosc_danmaku.conf       用户写的值（只有取消注释才生效）
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
3. `pakku.build_config()` 里 `pick()` 出来做归一化/钳制
4. 在用到它的函数里消费

---

## 10. 容易踩的坑

### 10.1 Lua 模式的字符类是按字节匹配的 ⚠️

这是本次开发中真实踩到并修掉的 bug。原来的写法：

```lua
out = out:gsub("[ 　]+", " ")   -- 想匹配「空格和全角空格」
```

`[ 　]` 在 Lua 模式里展开成**字节集合** `{0x20, 0xE3, 0x80}`，
于是任何包含 `0x80` 字节的汉字都会被咬掉一截：

```
一 (E4 B8 80) → E4 B8        -- 静默截断，不报错
```

后果是弹幕文本在预处理阶段被无声损坏。修法是按 UTF-8 字符遍历
（`normalize_spaces()`），永远不要在 Lua 字符类里放多字节字面量。
**同类风险**：`[，。！]`、`[，]` 之类的写法全部有这个问题。

### 10.2 Lua 没有正则前瞻 / 量词区间

- `TRIM_CJK_SPACE_RE` 用了 `(?=...)`，Lua 不支持 → 改成逐字符扫描。
- `pakku.js` 的 forcelist 默认值是 `^23{2,}$`，Lua 模式不认识 `{n,}` →
  写了 `quantifier_to_lua()` 把 `{n}` / `{n,}` / `{n,m}` 翻译成等价的 Lua 模式。
  `{n,m}` 只能近似成「至少 n 次」。

### 10.3 其它

| 坑 | 说明 |
|---|---|
| `goto` | mpv 内置 LuaJIT 支持，但为兼容纯 Lua 5.1 环境，`adjust_density` 里已改用 `if/else` 结构 |
| 长括号嵌套 | `pakku_forcelist` 的值里有 `]]`，Lua 字面量必须用 `[=[ ... ]=]`，否则字符串提前结束 |
| `table.remove(t, 1)` | 是 O(n)，窗口大时（threshold 调很大）会有开销；当前实现跟随文章用 FIFO，窗口通常 <100 |
| `merge_scale` vs `merge_count` | `parse.lua` 里 `merge_scale` 非空就走 pakku 字号分支，会**跳过** `merge_fontsize_growth` / `merge_fontsize_max` |
| 字号基准不同 | pakku.js 假设基准字号 25，uosc_danmaku 默认 `fontsize=50`，dispval 按 `(size/25)^1.5` 会翻倍，所以 `pakku_shrink_threshold` / `pakku_drop_threshold` 的数值需要相应放大 |
| ASS 标记 | `{\b1\i1}` 是「粗体 + **斜体**」，`\i1` 就是斜体开关。合并标记只需要粗体，写成 `{\b1}` 即可；0.1.0 版本误带了 `\i1`，后缀会显示成斜体 |
| 加粗不要用正则猜 | 早期写法 `gsub("x(%d+)$", ...)` 既会把正文里恰好以 `x12` 结尾的弹幕误加粗，也锁死了标记的样式。现在由 `pakku.lua` 给出 `merge_mark`，`parse.lua` 用**明文比对**定位（先试末尾、再试开头）后插 `{\b1}`，换任何标记样式都不用动渲染层 |
| 下标字符的字体覆盖 | 只在 `mark_subscript=yes` 时相关：`U+2080-2089` / `U+208D-E` 不在基本区，字体缺字形时会显示成方框。本项目字体（Microsoft YaHei / Noto Sans CJK）渲染正常；换字体后可用 `--msg-level=all=v` 观察 libass 有无缺字形告警 |
| 下标字形天生小且随字体浮动 | 同一字号下 `₀-₉` 只有正文数字的 55% 高，而且实测 7 个字体在 47%~63% 之间，没有稳定的默认值可调。这正是默认放弃下标、改用 `(12)` 的原因，见 §6 |
| mpv 的 `--vo=image` 不含 OSD | 想截图验证弹幕/标记渲染时，`--vo=image` 产出的是**纯视频帧**，OSD 完全不会被合成进去（实测连 `--osd-msg1` 都不出现）。要么用 `--vo=gpu` + `window` 模式截图，要么直接量字体轮廓（本项目采用后者） |
| 测试时 `--script-opts` 会被覆盖 | mpv 的 `script-opts` 是单个字符串选项，**重复传会后者覆盖前者**。要一次传多个必须用逗号：`--script-opts=a-b=1,a-c=2` |

---

## 11. 开发与验证

### 11.1 纯 Lua 单元测试（秒级，改算法时首选）

`pakku.lua` 不依赖 mpv 也能跑：

```powershell
# 在工作区根目录
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
| `build_config({})` 的 17 个字段 | 全部等于 §6 表里的 pakku.js 默认值 |
| 合并 3 条相同弹幕后的 `text` | `恭喜(3)`，`merge_mark == "(3)"` |
| `to_subscript` 覆盖多位数 | 1/2/5/9/10/12/23/47/69/100/1234 → `₁`…`₁₂₃₄` |
| `mark_subscript=true` | 标记变成 `₍₃₎`（下标形式） |
| `mark=prefix` | 文本变成 `(3)恭喜` |
| `mark=off` | `merge_mark == ""`，文本保持 `恭喜` |
| 未合并的单条且正文以 `x12` 结尾 | `merge_count == 1`、`merge_mark == ""`，`text` 保持原文 |

### 11.2 真实弹幕压测

工作区自带 3 集弹幕（合计 20086 条），跑一遍确认合并数量和耗时：

```
03   6592 -> 4773   306ms  最多(60)
04   6702 -> 4884   314ms  最多(69)
07   6792 -> 4709   307ms  最多(47)
合计 20086 -> 14366（71.5%），平均 309ms/集
```

期望的 top 结果形态：`？？？？？？？(60)`、`kksk(46)`、`👍...👍(69)`、`波门(47)`
这类刷屏弹幕。

### 11.3 端到端跑 mpv

uosc_danmaku 的自动加载有两个前置条件，缺一个就什么都不发生：

1. `duration >= 60`（`main.lua` 里硬编码判断，短视频直接 return）
2. `danmaku-history.json` 里 `show_danmaku` 为 `true`

所以端到端测试需要：

```powershell
# 1. 用独立 MPV_HOME，避免污染真实便携配置
$env:MPV_HOME="$PWD\_e2ecfg"
# 2. 造一个 >=60s 的合成视频（纯 Y4M，脚本生成即可）
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

验证渲染层可以临时在 `convert_danmaku_to_ass_events` 末尾把 `ass_events` dump 到文件，
检查标记格式与字号（下面是**默认模式**，普通数字跟随正文字体）：

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
| 默认模式：含 `{\b1}(N)` 的行数 | `> 0`（本次实测 735） |
| 默认模式：含 `\fs` 的行数 | `0` |
| 默认模式：含下标 `₍` 的行数 | `0` |
| 默认模式：含旧式 `[xN]` 的行数 | `0` |
| 含 `\i1`（斜体）的行数 | `0` |
| 下标模式：含 `{\b1\fsN}₍M₎` 的行数 | `> 0`，且 `\fsN == event_fontsize × pakku_mark_scale`（735/735 一致） |
| 字号分布（第 2 列） | 从 `50` 起，最大不超过 `100`（即 2 倍上限） |
| libass 缺字形告警 | 无 |

> 注意区分两个字号：dump 第 2 列的 `font_size` 是**弹幕正文**的字号（受
> `pakku_enlarge_*` 控制，上限 100）；只有下标模式下标记才会有独立的 `\fs`，
> 且会超过 100（如 `\fs130`），属正常。默认模式(`(12)`)没有独立字号。

### 11.4 语法检查

```powershell
.\luajit.exe -e "assert(loadfile('portable_config/scripts/uosc_danmaku/modules/pakku.lua')); print('OK')"
```

---

## 12. 扩展指南

### 加一条新的相似判定规则

1. 在 §3 里写判定函数（输入两条 `ir`，输出 `true/false`）
2. 在 `M.check_similar()`（`pakku.lua:914`）的四级判定链里插入，注意顺序即优先级
3. 若需要新的预计算量，加进 `M.build_ir()`（`pakku.lua:886`）
4. 在 `dominant_reason()` 的 `rank` 表里给新 reason 一个权重
5. 在 `stats` 表里加同名字段，`M.merge()` 会自动统计
6. 若要有独立开关，按 §9 的 4 处套路加选项

### 换掉 / 更新拼音字典

```powershell
# 从 pakku.js 的原始表重新生成「编码:汉字串」数据块
# 输入：pakku.js-master/pakkujs/similarity/repo-cpp/src/pinyin_dict.txt
# 输出：替换 pakku.lua 第 116–513 行（PINYIN_SRC 的内容）
# 校验：组数应为 398，汉字数应为 6763
```

只需保证同音字落在同一组，算法不关心数字的具体含义。

### 调整密度策略

`M.adjust_density()`（`pakku.lua:1114`）里的常量：

| 常量 | 值 | 含义 |
|---|---|---|
| `DISPVAL_POWER` | 0.35 | dispval 的幂次 |
| `DISPVAL_TIME_THRESHOLD_MS` | 5000 | 密度累加的滑动窗口 |
| `SHRINK_MAX_RATE` | 1.732 | 单条最多缩小到 1/1.732 |

`judge_drop()` 决定丢弃概率，权重来自 `merge_count`（uosc_danmaku 没有点赞数可用，
pakku.js 那边用的是 `proto_likecount`）。

### 改合并后的展示文本

`choose_display_text()`（`pakku.lua:1185`）：
先按预处理文本分组取最高频，并列时取长度中位数；
`pakku_normalize_display=no` 时改显示该组里出现最多的**原始**文本。

### 改合并标记的样式

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
渲染层不用改——`parse.lua` 拿的是 `entry.merge_mark` 明文，多长的标记都能定位。

### 调整标记的字号

默认模式（`(12)`）**没有独立字号**，直接跟随正文字体，`parse.lua` 里的
`mark_scale` 会被强制为 1，标签只剩 `{\b1}`。

只有下标模式才会折算 `\fs`。在 `parse.lua:760` 一带：

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

想改补偿策略（比如换成 `\fs` + `\rise` 的组合），改这一段即可。
下标数字本身贴基线，不需要 `\rise`。

---

## 13. 已知限制

- **性能**：O(窗口内簇数 × 每簇一次判定)。默认 `threshold=30` 时 6700 条约 320ms；
  改成 `threshold=10` 约 181ms，`threshold=5` 约 141ms（3 集平均，见 `readme.md` 的「性能」一节）。
  窗口开得越大越慢，是线性以上增长。
- **`cross_mode` 默认开启**（对齐 pakku.js）：滚动/顶部/底部会互相合并，
  靠 `MODE_ELEVATION` 把类型提升为「底部 > 顶部 > 滚动」。
  关掉后合并率会从 71.5% 降到 76.0%。
- **单条簇不回退原文**：簇数量为 1 时 `choose_display_text` 返回的仍是
  预处理后的文本（跟随 pakku.js 行为）。
- **`{n,m}` 量词有损**：Lua 模式没有上界，只能近似成「至少 n 次」。
- **uosc 菜单未接入**：pakku 选项目前只能改 `uosc_danmaku.conf`，
  没做进 uosc 的图形化菜单（`modules/menu.lua`）。
- **拼音表只覆盖简体常用字**：6763 字以外的字符（生僻字、日文假名、emoji）
  按原字符参与比较，靠编辑距离/余弦兜底。
- **默认标记 `(12)` 与 pakku.js 不一致**：pakku.js 只有 `₍₁₂₎` 和 `[x12]`，
  没有括号数字。这是有意选择（见 §6），想要原样把
  `pakku_mark_subscript=yes` 打开即可。
- **下标模式依赖字体覆盖**：`U+2080-2089` / `U+208D-E` 属于
  Superscripts and Subscripts 区段，不在 CJK 基本区。本项目字体渲染正常，
  但换到字形不全的字体上可能显示成方框；这种情况用默认的 `(12)` 即可回避。
- **下标模式的字号是补偿值不是 pakku 原值**：pakku.js 不设标记字号，
  `pakku_mark_scale=1.8` 是按 Microsoft YaHei 的字形度量算出来的。
  换字体后这个比例不一定仍然精确，觉得偏大或偏小直接改数值即可。
- **标记宽度不计入布局**：`parse.lua` 用 `clean_text`（不含标记）算文本宽度，
  所以标记会额外多出一截；标记放大后这一截会变长（滚动弹幕尾部更明显）。

---

## 14. 待办

- [ ] 把 pakku 选项接进 uosc 菜单（`modules/menu.lua`），支持运行时切换
- [ ] 给 `M.merge()` 加增量/分块处理，避免超长视频（>3 万条）一次性聚类
- [ ] 把 `pakku_threshold` 从「固定秒数」改成按弹幕密度自适应
- [ ] 补一份自动化测试脚本（当前自检清单是手动的）

---

## 15. 许可与合规

### 结论：本项目整体 GPL-3.0

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

### 分发时的义务

1. 保留 `LICENSE` 与 `portable_config/scripts/uosc_danmaku/LICENSE`
2. 保留 `THIRD-PARTY.md`（或等效的第三方声明）
3. 修改 GPL 部分后需一并提供修改后的源码

### 隐私自查（每次入库前建议重跑）

| 检查项 | 结果 |
|---|---|
| 弹幕 `p` 属性字段 | 只有 `时间,类型,字号,颜色` 四个，**无**用户 ID / 用户哈希 / 发送时间戳 |
| 弹幕正文里的手机号 / QQ / 邮箱 / 网址 / 群号 | 扫描后无真实命中（唯一疑似项是一条经纬度坐标，属原视频公开弹幕内容） |
| 跟踪文件里的本机绝对路径 | 无（文档里一律用 `$PWD` / 相对路径） |
| 跟踪文件里的用户名 / 邮箱 | 无 |
| `portable_config/files/`（观看历史、弹幕历史） | 已在 `.gitignore` 中排除，未入库 |
| `portable_config/cache`、`fonts`、`shaders`、`icc` | 已排除 |
| 调试残留（`_e2e*`、`_frames`、`_*.lua`） | 已排除，仓库中无残留 |
| 第三方博客原文存档 | 已移出仓库（`.gitignore`），仅本地保留 |

### git 历史重写（2026-10-05 已完成）

首次推送后做过一次历史重写，处理掉两处已经进入历史的隐私 / 版权问题：

| 问题 | 处理 |
|---|---|
| 提交者邮箱是个人 QQ 邮箱 | 全部 5 个提交的 author + committer 改为 `209313510+lnmp30@users.noreply.github.com` |
| 第三方博客原文存档留在历史里 | 从全部 5 个提交中移除（该文件从未入库的最新状态也不再包含） |

做法是**手工重建**，没有用 `git filter-branch`：

- 用 `git cat-file commit` 取出原提交对象，按第一个空行切出原始信息
- `git read-tree` 把原提交的 tree 装进索引 → `git rm --cached` 剔除博客存档 → `git write-tree`
- 用 `GIT_AUTHOR_*` / `GIT_COMMITTER_*` 环境变量（时间、姓名原样，邮箱替换）调 `git commit-tree`

之所以不用 `filter-branch`：它在 Windows 上把 filter 命令交给 `sh -c` 执行，
中文路径要穿过 PowerShell → git → sh 三层，编码很容易出问题。

重写结果逐项核对过：提交信息、作者名、作者时间、提交时间全部原样；
每个提交相对旧版的 diff 只有那一个文件；最终 HEAD 的 tree 与重写前**完全相同**。

**遗留注意事项：**

- 强推**不会立刻**从 GitHub 服务端删掉旧提交对象。知道旧 SHA 的人在一段时间内仍能按
  SHA 访问，网页缓存也可能还在。要彻底清除需要联系 GitHub Support，或者删库重建。
- 本仓库的 `user.email` 已改成本地配置（`git config --local`），全局配置未动。
  想在所有仓库统一，执行 `git config --global user.email "209313510+lnmp30@users.noreply.github.com"`。

---

## 16. 无键盘环境支持（`danmaku-quick-search`）

### 问题

弹幕搜索有两条路径，都要**按回车**才能提交：

| 路径 | 位置 | 卡点 |
|---|---|---|
| uosc 菜单 | `menu.lua:514` `open_input_menu_uosc()` | `search_debounce = "submit"`，脚注写着「使用 enter 或 ctrl+enter 进行搜索」 |
| mpv 原生输入框 | `menu.lua:479` `open_input_menu_get()` | `mp.input.get()` 本身就是打字框 |

安卓 mpv、遥控器、手柄都没有回车键。

但搜索框里**本来就预填好了**番剧名：uosc 路径是 `search_suggestion = parse_title()`，
原生路径是 `default_text = title`。所以缺的不是「打字」，只是「确认」。

### 做法

在 `menu.lua:1446` 加了 `danmaku-quick-search` 消息，直接拿 `parse_title()`
的结果调已有的 `search-anime-event`（`menu.lua:1415`），跳过搜索框：

```
script-message danmaku-quick-search
script-message danmaku-quick-search "孤独摇滚"        -- 可选参数，手动指定
```

两个细节：

1. **关键词的 `|` 和 `@` 处理**：`search-anime-event` 约定用 `|` 分隔
   「名称\|类型」、`@` 分隔过滤词。文件名里出现这两个字符会被误解，
   所以**只有从文件名解析出来的**关键词才替换成空格；
   手动传入的参数原样保留，留出用高级语法的余地。
2. **`parse_title()` 返回空**时给提示并 warn，不做无意义的空搜索。

键位绑定在 `main.lua:741`，由 `options.danmaku_quick_search_key` 控制，
默认空字符串 = 不绑定（不改变现有行为）。

### 为什么不直接用 `search_submit`

uosc 的 `Menu.lua:151` 支持 `search_submit`，加上去就能让搜索菜单**打开即自动搜索**，
是更省事的一条路。但它只解决「提交」，不解决「触发」——
在安卓上还得先有办法点开那个菜单，而 uosc 的菜单靠鼠标区域点击
（`Menu.lua:1751` 用 `cursor:zone('primary_down', ...)`），
前端不把触摸转成鼠标事件就点不动。所以选了更独立、可由前端按钮直接调用的
script-message 方案。

如果哪天确认前端支持触摸转鼠标，把 `search_submit = true` 加进
`open_input_menu_uosc()` 的 `menu_props` 即可，两者不冲突。

### 验证

用隔离的 `MPV_HOME` + 合成视频，加一个只负责发消息的触发脚本，跑 mpv 看日志：

```
[2.030][i][uosc_danmaku] 一键搜索：qs DMG&VCB-Studio BOCCHI THE ROCK     -- 自动解析，| @ 被清掉
[2.026][i][uosc_danmaku] 一键搜索：孤独摇滚 | tv @SP                     -- 手动传参，| @ 原样保留
```

三次运行日志里都没有 `[error]` 或 `stack traceback`。
