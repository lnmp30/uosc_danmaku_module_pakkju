# 开发地图 · uosc_danmaku × pakku

> 本文件面向**改代码的人**。用户使用说明见 [`read.md`](read.md)，版本历史见 [`changelog.md`](changelog.md)。

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
| `read.md` | 普通用户 | 怎么开、选项怎么调、出问题怎么查 |
| `project.md` | 开发者 | 代码在哪、数据怎么流、怎么扩展、有哪些坑 |
| `changelog.md` | 所有人 | 每个版本改了什么、为什么改 |

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
├── pakku.js-master/             算法参考实现（TypeScript + C++/WASM）
│   └── pakkujs/similarity/repo-cpp/src/
│       ├── main.cpp             相似判定与聚类的权威实现
│       └── pinyin_dict.txt      汉字 → {声母,韵母} 原始数据（6763 条）
├── [DMG&VCB-Studio] BOCCHI THE ROCK! [04]....xml
│                                6702 条真实弹幕，用来做回归/压测
└── 在 uosc_danmaku 中集成 pakkujs 弹幕合并算法.md
                                 需求来源与算法说明
```

`★` 标记的是本次新增或修改的部分：

| 文件 | 状态 | 说明 |
|---|---|---|
| `portable_config/scripts/uosc_danmaku/modules/pakku.lua` | **新增** | 1352 行 / 56 KB，算法本体 |
| `portable_config/scripts/uosc_danmaku/modules/options.lua` | 修改 | 新增 21 个 `pakku_*` 选项默认值（对齐 pakku.js） |
| `portable_config/scripts/uosc_danmaku/modules/parse.lua` | 修改 | 合并分支接入、`xN` 加粗、字号缩放 |
| `portable_config/scripts/uosc_danmaku/main.lua` | 修改 | 加载顺序里加 `require("modules/pakku")` |
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
                 │ 文本：ASS 转义 + xN 加粗 │  ★ 本次新增分支
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
| 头部文档 | 1–37 | 用法、接口、字段说明 |
| **0. UTF-8 小工具** | 62–101 | `utf8_char_list` `utf8_codepoint` `utf8_count` `is_cjk_codepoint` |
| **1. 拼音字典** | 103–538 | `PINYIN_SRC` 数据块（115–513）、`pinyin_dict()` 懒加载（518） |
| **2. 文本预处理** | 541–669 | `ENDING_CHARS`、`WIDTH_TABLE`、`normalize_spaces()`（580）、`quantifier_to_lua()`（612）、`M.normalize()`（634） |
| **3. 相似度计算** | 672–770 | `freq_of_chars` `freq_of_pinyin` `freq_distance` `make_bigrams` `gram_cosine`、`M.edit_distance`（751） `M.pinyin_distance`（758） `M.cosine_similarity`（766） |
| **4. 配置** | 773–874 | `pick` `tonum` `tobool`、`M.build_config()`（805） |
| **5. 聚类** | 877–1012 | `M.build_ir()`（881） `M.check_similar()`（909） `cluster()`（966） |
| **6. 字号放大 / 标记** | 1015–1041 | `enlarge_scale()`、`make_mark()`（1029） |
| **7. 密度调控** | 1044–1134 | `M.dispval()` `judge_drop()` `M.adjust_density()`（1070） |
| **8. 对外主入口** | 1137–1352 | `choose_display_text()`（1141） `dominant_reason()` `M.merge()`（1206） |

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
| `pakku_mark_threshold` | 1 | `MARK_THRESHOLD` |
| `pakku_forcelist` | 23333 / 66666 | `FORCELIST` |
| `pakku_shrink_threshold` / `pakku_drop_threshold` | 0 | `SHRINK_THRESHOLD` / `DROP_THRESHOLD` |

**两处有意偏离**（都写在 `options.lua` 的注释里）：

1. `pakku_mark=suffix` + 纯文本 `xN`。pakku.js 是 `DANMU_MARK='prefix'` +
   `DANMU_SUBSCRIPT=true`，即 `₍₁₂₎文本`。本实现按使用习惯保留 `xN` 后缀，
   也没有移植下标数字。
2. `pakku_enable` 在库层面（`options.lua`）默认仍是 `false`，
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
| `PINYIN_DICT` | `modules/pakku.lua:16` | `pakku.lua:115` `PINYIN_SRC` + `pakku.lua:518` `pinyin_dict()` | 改为「编码→汉字串」压缩存储，398 行 |
| 文本预处理 | `modules/pakku.lua:436` | `pakku.lua:634` `M.normalize()` | 空格处理改成逐字符，见 §10 |
| `M.edit_distance` | `modules/pakku.lua:488` | `pakku.lua:751` | 算法一致 |
| `M.cosine_similarity` | `modules/pakku.lua:522` | `pakku.lua:766` | 算法一致（未采用 C++ 的环绕 bigram） |
| `cluster` | `modules/pakku.lua:578` | `pakku.lua:966` | 一致，自后向前扫描窗口 |
| 密度调控 | 未给行号 | `pakku.lua:1070` `M.adjust_density()` | 按 `post_combine.ts` 实现 |

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
| `text` | 合并后带 `xN` 标记的文本，如 `恭喜x12` |

`merge_scale` 存在与否是 `parse.lua` 区分「pakku 路径」和「内置合并路径」的开关。

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
| ASS 标记 | `{\b1\i1}` 是「粗体 + **斜体**」，`\i1` 就是斜体开关。合并标记只需要粗体，写成 `{\b1}` 即可；早期版本误带了 `\i1`，后缀会显示成斜体 |
| 加粗正则要限流 | `gsub("x(%d+)$", ...)` 会把正文里恰好以 `x12` 结尾的弹幕也加粗。现在的写法先判断 `(d.merge_count or 1) > 1`，只有真合并过的条目才处理 |
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
| `build_config({})` 的 15 个字段 | 全部等于 §6 表里的 pakku.js 默认值 |
| 合并 3 条相同弹幕后的 `text` | `恭喜x3`，**不含 `[` `]`** |
| 未合并的单条且正文以 `x12` 结尾 | `merge_count == 1`，`text` 保持原文（不该被当成标记） |

### 11.2 真实弹幕压测

工作区自带 3 集弹幕（合计 20086 条），跑一遍确认合并数量和耗时：

```
03   6592 -> 4773   306ms  最多x60
04   6702 -> 4884   314ms  最多x69
07   6792 -> 4709   307ms  最多x47
合计 20086 -> 14366（71.5%），平均 309ms/集
```

期望的 top 结果形态：`？？？？？？？x60`、`kksk x46`、`👍...👍x69`、`波门x47`
这类刷屏弹幕。注意**没有方括号**。

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
检查标记格式与字号：

```
2.00  72  {\move(2010, 251, -90, 251)}{\c&HFFFFFF&}簽{\b1}x10
3.00  50  {\move(2057, 51, -137, 51)}{\c&HFFFFFF&}2024.2.14{\b1}x2
```

自检三项（对 dump 结果做计数）：

| 检查 | 期望 |
|---|---|
| 含 `\i1`（斜体）的行数 | `0` |
| 含 `[xN]` 方括号的行数 | `0` |
| 含 `{\b1}xN` 的行数 | `> 0` |
| 字号分布 | 从 `50` 起，最大不超过 `100`（即 2 倍上限） |

### 11.4 语法检查

```powershell
.\luajit.exe -e "assert(loadfile('portable_config/scripts/uosc_danmaku/modules/pakku.lua')); print('OK')"
```

---

## 12. 扩展指南

### 加一条新的相似判定规则

1. 在 §3 里写判定函数（输入两条 `ir`，输出 `true/false`）
2. 在 `M.check_similar()`（`pakku.lua:909`）的四级判定链里插入，注意顺序即优先级
3. 若需要新的预计算量，加进 `M.build_ir()`（`pakku.lua:881`）
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

`M.adjust_density()`（`pakku.lua:1067`）里的常量：

| 常量 | 值 | 含义 |
|---|---|---|
| `DISPVAL_POWER` | 0.35 | dispval 的幂次 |
| `DISPVAL_TIME_THRESHOLD_MS` | 5000 | 密度累加的滑动窗口 |
| `SHRINK_MAX_RATE` | 1.732 | 单条最多缩小到 1/1.732 |

`judge_drop()` 决定丢弃概率，权重来自 `merge_count`（uosc_danmaku 没有点赞数可用，
pakku.js 那边用的是 `proto_likecount`）。

### 改合并后的展示文本

`choose_display_text()`（`pakku.lua:1138`）：
先按预处理文本分组取最高频，并列时取长度中位数；
`pakku_normalize_display=no` 时改显示该组里出现最多的**原始**文本。

---

## 13. 已知限制

- **性能**：O(窗口内簇数 × 每簇一次判定)。默认 `threshold=30` 时 6700 条约 320ms；
  改成 `threshold=10` 约 181ms，`threshold=5` 约 141ms（3 集平均，见 `read.md` §12）。
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

---

## 14. 待办

- [ ] 把 pakku 选项接进 uosc 菜单（`modules/menu.lua`），支持运行时切换
- [ ] 给 `M.merge()` 加增量/分块处理，避免超长视频（>3 万条）一次性聚类
- [ ] 把 `pakku_threshold` 从「固定秒数」改成按弹幕密度自适应
- [ ] 补一份自动化测试脚本（当前自检清单是手动的）
