# Changelog · uosc_danmaku × pakku

本文件记录 **pakku 弹幕合并算法移植** 这一项目的版本历史。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号参考 [语义化版本](https://semver.org/lang/zh-CN/)。

变更类型：`新增` / `修改` / `修复` / `移除` / `性能` / `文档`

---

## 版本号约定

本项目是 **uosc_danmaku 的一个功能分支/补丁集**，不是 uosc_danmaku 本体的复刻。
两套版本号并行存在，不要混淆：

| 版本号 | 位置 | 说明 |
|---|---|---|
| `uosc_danmaku` **2.2.0** | `portable_config/scripts/uosc_danmaku/main.lua:1` | 上游版本，本项目**未改动** |
| 本项目 **0.1.0** | 本文件 | pakku 移植的版本 |

也就是说：`main.lua` 里的 `VERSION` 仍然报 2.2.0。
如果希望 mpv 脚本消息里也能看出多了 pakku，可以自行改成
`2.2.0+pakku.1`（`mp.commandv('script-message', 'uosc_danmaku-version', VERSION)`
会把它广播给 uosc 的按钮提示）。

---

## [0.2.0] - 2026-10-05

对齐 pakku.js 官方默认配置，并修掉合并标记的显示问题。
同时把验证数据从 1 集扩展到 3 集（合计 20086 条）。

### 修改

**默认配置全面对齐 pakku.js 的 `DEFAULT_CONFIG`**（`background/config.ts`）

`modules/options.lua`、`script-opts/uosc_danmaku.conf` 与
`M.build_config()` 里的兜底默认值三处同步改成：

| 选项 | 旧默认 | 新默认 | pakku.js |
|---|---|---|---|
| `pakku_threshold` | 5 | **30** | `THRESHOLD` |
| `pakku_max_dist` | 4 | **5** | `MAX_DIST` |
| `pakku_max_cosine` | 60 | **45** | `MAX_COSINE` |
| `pakku_cross_mode` | no | **yes** | `CROSS_MODE` |
| `pakku_enlarge_min_count` | 10 | **5** | `calc_enlarge_rate()` 的 `count <= 5` |
| `pakku_enlarge_log_base` | 10 | **5** | `Math.log(count)/Math.log(5)` |

其余选项（`use_pinyin` / `mark_threshold` / `enlarge` / `enlarge_max_scale` /
`mode_elevation` / `representative_percent` / `trim_*` / `forcelist` /
`shrink_threshold` / `drop_threshold`）原本就与 pakku.js 一致，未动。

放大曲线随之变化：旧默认合并 100 条才翻倍，新默认合并 25 条即翻倍
（6 条 ×1.11、25 条 ×2.00、100 条仍是上限 ×2.00）。

**`script-opts/uosc_danmaku.conf` 的 pakku 段改为显式启用**

之前整段是注释状态（等于「默认关闭」）。现在所有 `pakku_*` 都以 pakku.js
默认值显式写出、且 `pakku_enable=yes`，装好即用，也方便逐项对照修改。

**合并数量标记由 `[xN]` 改为 `xN`**

- `pakku.lua` 的 `make_mark()`：`"[x" .. count .. "]"` → `"x" .. count`
- `parse.lua` 去掉了针对 `[xN]` 的两个 gsub 分支，只保留 `xN` 后缀一种
- 效果：`恭喜x12`，不再有方括号

### 修复

- **合并标记显示为斜体**。ASS 覆盖标签 `{\b1\i1}` 里 `\i1` 就是斜体开关，
  这是上游 uosc_danmaku 原有的写法，pakku 合并量大之后变得很显眼。
  现已改为只加粗的 `{\b1}`。
  （`parse.lua` 里验证：dump 出的 ASS 事件中 `\i1` 出现次数为 0。）

- **加粗正则误伤正文**。原来无条件执行 `gsub("x(%d+)$", ...)`，
  正文里恰好以 `x12` 结尾的弹幕（如 `codex12`）也会被加粗。
  现在先判断 `(d.merge_count or 1) > 1`，只有真的发生合并才处理。

### 性能

3 集真实弹幕（合计 20086 条）实测，mpv v0.41.0 / LuaJIT：

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
| 03 | 6592 | 4773 | x60 | ~306 ms |
| 04 | 6702 | 4884 | x69 | ~314 ms |
| 07 | 6792 | 4709 | x47 | ~307 ms |

耗时增加主要来自 `threshold` 从 5 秒放宽到 30 秒（对齐 pakku.js），
合并率因此从 80.7% 提升到 71.5%。这仍是一次性开销，不影响播放。

### 验证

- 默认值自检：`build_config({})` 的 15 个字段逐个比对 pakku.js `DEFAULT_CONFIG`，全部一致。
- 纯 LuaJIT 单元测试：预处理、距离/相似度、聚类、标记格式、拼音专有判定全部通过。
- 新增用例：合并后 `text == "恭喜x3"` 且不含方括号；正文以 `x12` 结尾的单条弹幕不被加粗。
- 3 集回归：结果形态与 pakku.js 一致（`？？？？？？？x60`、`kksk x46`、`👍...👍x69`）。
- mpv 端到端（隔离 `MPV_HOME` + 合成 64 秒 Y4M 视频 + 同名 xml 自动加载）：
  ```
  [uosc_danmaku] pakku: 拼音字典载入 6763 个汉字 / 398 个拼音组
  [uosc_danmaku] pakku: 6702 条 -> 4884 条（簇 4884，最多合并 69；
                 ==467 ≤1058 P46 247%；丢弃 0，缩小 0，放大 73，耗时 319 ms）
  [uosc_danmaku] 已解析 4884 条弹幕
  ```
- 渲染层校验（dump 真实 ASS 事件，共 4883 条）：
  ```
  2.00  72  {\move(2010, 251, -90, 251)}{\c&HFFFFFF&}簽{\b1}x10
  3.00  50  {\move(2057, 51, -137, 51)}{\c&HFFFFFF&}2024.2.14{\b1}x2
  ```
  | 检查 | 结果 |
  |---|---|
  | 含 `\i1`（斜体）的行数 | 0 |
  | 含 `[xN]` 方括号的行数 | 0 |
  | 含 `{\b1}xN` 的行数 | 735 |
  | 字号范围 | 50 – 100（2 倍上限生效） |

### 备注

- **升级影响**：合并会更激进（单集 5732 → 4884 条），耗时从约 134ms 涨到约 319ms，
  标记从 `[x2]` 变成 `x2`。想回到 0.1.0 的手感，把 `pakku_threshold` 改回 5、
  `pakku_max_dist` 改回 4、`pakku_max_cosine` 改回 60、`pakku_cross_mode` 改回 no。
- **有意保留的偏离**：`pakku_mark=suffix` 且输出纯文本 `xN`。
  pakku.js 默认是 `DANMU_MARK='prefix'` + `DANMU_SUBSCRIPT=true`，即 `₍₁₂₎文本`，
  下标数字没有移植。
- **库默认仍是关闭**：`options.lua` 里 `pakku_enable=false` 不变，
  只有本项目自带的 `uosc_danmaku.conf` 显式写了 `pakku_enable=yes`，
  这样脱离本项目使用该模块时不会突然改变行为。

---

## [0.1.0] - 2026-10-05

首次落地：把 pakku.js 的弹幕合并算法完整移植为 uosc_danmaku 的 Lua 模块，
并接入原有的合并流程。基线为上游 uosc_danmaku 2.2.0。

### 新增

**算法模块 `portable_config/scripts/uosc_danmaku/modules/pakku.lua`**（1349 行 / 55 KB）

- 文本预处理：去尾部标点（`ENDING_CHARS`）、全角半角归一（`WIDTH_TABLE`）、
  合并多余空格、去除 CJK 之间的单个空格、自定义 `forcelist` 替换规则。
- 字符频率近似编辑距离 `M.edit_distance()`：用字符出现次数的 L1 距离近似
  Levenshtein，复杂度 O(n)，可容忍错别字与多字少字。
- 拼音距离 `M.pinyin_distance()`：内置 **6763 个汉字 / 398 个拼音组** 的拼音字典
  （数据取自 `pakku.js-master/.../pinyin_dict.txt`），可合并谐音弹幕。
- bigram 余弦相似度 `M.cosine_similarity()`：把文本拆成相邻字符对向量求余弦，
  返回 0–100 整数，可合并语气词/局部结构差异。
- 四级相似判定 `M.check_similar()`：完全相同 → 编辑距离 → 拼音距离 → 余弦相似度，
  优先级即判定顺序，任一命中即归入同一簇。
- 滑动窗口聚类 `cluster()`：在 `threshold` 秒窗口内维护候选簇，窗口随时间向前滑动，
  自后向前寻找第一个可合并的簇。
- 字号放大：合并数量超过阈值后按对数放大，默认以 10 为底、上限 2 倍
  （合并 100 条翻倍，1000 条仍是 2 倍）。
- 合并数量标记：支持 `[xN]` 前缀 / 后缀 / 关闭三种模式。
- 密度调控 `M.adjust_density()`：按 5 秒窗口累加「显示价值」（与文本长度平方根、
  字号 1.5 次方相关），超阈值时整体缩小字号（最多 1.732 倍）或按权重丢弃弹幕。
- 类型提升：簇内含底部弹幕时提升为底部，其次顶部，最后滚动。

**配置选项**（`modules/options.lua` + `script-opts/uosc_danmaku.conf`）

新增 21 个 `pakku_*` 选项，全部默认关闭、conf 中全部注释掉，不影响既有用户：

```
pakku_enable  pakku_threshold  pakku_max_dist  pakku_max_cosine  pakku_use_pinyin
pakku_cross_mode  pakku_mark  pakku_mark_threshold
pakku_enlarge  pakku_enlarge_min_count  pakku_enlarge_max_scale  pakku_enlarge_log_base
pakku_mode_elevation  pakku_representative_percent  pakku_normalize_display
pakku_trim_ending  pakku_trim_width  pakku_trim_space  pakku_forcelist
pakku_shrink_threshold  pakku_drop_threshold
```

**模块加载**：`main.lua` 增加 `require("modules/pakku")`。

**文档**：新增 `project.md`（开发地图）、`read.md`（使用说明）、本文件。

### 修改

- `modules/parse.lua`
  - `convert_danmaku_to_ass_events()` 的合并步骤改为分支：
    `pakku_enable` 打开时走 `pakku.merge()`，否则保持原有的
    `merge_duplicate_danmaku()`（行为完全不变）。
  - 字号计算增加 pakku 分支：存在 `merge_scale` 时用
    `基础字号 × merge_scale`，否则沿用 `DanmakuArray.get_merged_font_size()`。
  - 合并标记加粗的正则扩展为同时支持 `[xN]` 后缀、`[xN]` 前缀和原有的 `xN` 后缀。
  - 新增 pakku 统计的 verbose 日志。

### 修复

- **文本预处理会静默损坏汉字**（开发过程中发现并修复）。
  原写法 `out:gsub("[ 　]+", " ")` 在 Lua 模式里是按**字节**匹配的，
  字符类实际展开为 `{0x20, 0xE3, 0x80}`，会吃掉汉字编码中的 `0x80` 字节：

  ```
  一 (E4 B8 80) → E4 B8      -- 截断，无任何报错
  ```

  已改为按 UTF-8 字符遍历的 `normalize_spaces()`，并加了
  「`这是完全不一样的一句话` 归一后字节数不变」的回归用例。

- `forcelist` 默认规则 `^23{2,}$` / `^6{3,}$` 用的是 JS 风格量词，
  Lua 模式不支持。新增 `quantifier_to_lua()` 做 `{n}` / `{n,}` / `{n,m}` 翻译，
  并对非法模式做预校验与告警，避免每帧报错。

### 性能

在 6702 条真实弹幕（`[DMG&VCB-Studio] BOCCHI THE ROCK! [04]....xml`）上的实测：

| 配置 | 结果 | 耗时 |
|---|---|---|
| `pakku_enable=no`（基线） | 6702 → 6702 | 0 ms |
| 默认（`threshold=5` `dist=4` `cos=60` 拼音开） | 6702 → 5732 | ~117 ms |
| 宽松（`dist=6` `cos=45`） | 6702 → 5629 | ~114 ms |
| 严格（`dist=2` `cos=80`） | 6702 → 5922 | ~106 ms |
| 仅精确 + 拼音（`dist=0` `cos=101`） | 6702 → 6295 | ~85 ms |
| `threshold=10` | 6702 → 5494 | ~126 ms |
| `threshold=30` | 6702 → 5235 | ~223 ms |

端到端（mpv 内实际加载）为 134 ms，与裸 LuaJIT 数据基本一致，
说明 Lua 层不是瓶颈。拼音字典首次使用时懒加载，约 0.06 s，之后常驻内存。
同一输入重复 6 次结果完全一致（合并过程是确定性的）。

### 验证

- 纯 LuaJIT 单元测试：预处理 6 项、距离/相似度 6 项、合并聚类、拼音专有判定、
  密度调控，全部通过。
- 真实弹幕压测：合并结果形态与 pakku.js 一致
  （`👍...👍[x23]`、`kksk[x11]`、`芳文跳[x9]`）。
- mpv 端到端（隔离 `MPV_HOME` + 合成 64 秒 Y4M 视频 + 同名 xml 自动加载）：
  ```
  [uosc_danmaku] pakku: 拼音字典载入 6763 个汉字 / 398 个拼音组
  [uosc_danmaku] pakku: 6702 条 -> 5732 条（簇 5732，最多合并 23；
                 ==238 ≤541 P39 152%；丢弃 0，缩小 0，放大 4，耗时 134 ms）
  [uosc_danmaku] 已解析 5732 条弹幕
  ```
- 渲染层校验（dump 真实 ASS 事件）：
  ```
  837.00  68  {\move(2345, 201, -425, 201)}{\c&HFFFFFF&}👍...{\b1\i1}[x23]
  1415.00 52  {\move(2037, 551, -117, 551)}{\c&HFFFFFF&}kksk{\b1\i1}[x11]
  ```
  字号放大、`[xN]` 加粗、颜色标签均正确。
- 密度调控端到端：`pakku_shrink_threshold=40` 时字号整体落到 29–33；
  `pakku_drop_threshold=200` 时条数 5732 → 5685。

### 备注

- 默认 **关闭**。既有用户升级后行为零变化。
- 启用 pakku 后，原有的 `merge_tolerance` 合并**不再生效**（被接管）。
- `pakku_shrink_threshold` / `pakku_drop_threshold` 默认 `0`（禁用）。
  注意 pakku.js 假设基准字号 25，uosc_danmaku 默认 `fontsize=50`，
  dispval 会随之翻倍，开启时数值需要按比例上调。
  在测试用的 6702 条番剧上：`shrink_threshold=200` 约缩小 11% 的弹幕，
  `=400` 则完全不触发；`drop_threshold=200` 约丢 1%，`=600` 完全不丢。
- 拼音字典的数值编码是 `<声母索引, 韵母索引>`，不是音节序号；
  算法只依赖「同音字同编码」，无需还原成拼音字符串。
  详见 `project.md` §7。

---

## 未发布

（下一次改动写在这里）

---

## 上游基线

### uosc_danmaku 2.2.0

本项目所基于的上游版本，原样保留在 `portable_config/scripts/uosc_danmaku/`，
除上表列出的 4 处修改（外加 1 个新增模块）外未做其它改动。

相关上游项目：

- [uosc_danmaku](https://github.com/Tony15246/uosc_danmaku) —— mpv 弹幕插件
- [uosc](https://github.com/tomasklaen/uosc) —— UI 框架
- [pakku.js](https://github.com/xmcp/pakku.js) —— 弹幕合并算法来源
