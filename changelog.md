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

## [0.6.0] - 2026-10-05

仓库整理与合规：重写 README、测试数据归档、确定本项目许可证为 **GPL-3.0**、
做了一次隐私自查。

### 新增

- **`LICENSE`**：GNU General Public License v3.0 全文（674 行）。

- **`THIRD-PARTY.md`**：第三方组件清单与许可证说明，并解释为什么本项目
  必须是 GPL-3.0。

- **`testdata/`**：三集弹幕文件从仓库根目录移入此目录。

### 修改

- **`read.md` → `readme.md`**，并按 GitHub README 的阅读习惯整体重写：
  - 开头改为「这个模块解决什么问题」+ 实测效果，而不是直接讲选项
  - 补「快速开始（3 步）」「仓库结构」「目录」锚点
  - 选项表按功能分组（基础 / 判定严格程度 / 显示样式 / 文本预处理 / 密度调控）
  - 常见问题里补上「和 `merge_tolerance` 冲突吗」
  - 文末补「出处 / 致谢 / 许可」三小节

- `project.md`：
  - 文档分工表加入 `readme.md` / `THIRD-PARTY.md` / `LICENSE`
  - 工作区总览更新为新目录结构，标出未入库的第三方内容
  - 新增 §15「许可与合规」，含组件许可证表、分发义务、**隐私自查表**

### 许可证判定

| 组件 | 许可证 |
|---|---|
| **本项目整体** | **GPL-3.0** |
| uosc_danmaku（宿主，vendored） | MIT，© 2024 吴南李 |
| pakku.js（算法与拼音字典来源） | GPLv3 |
| uosc（运行时依赖，未分发） | LGPL-2.1 |

`modules/pakku.lua` 复用了 pakku.js 的四级判定逻辑、聚类/标记/密度调控算法、
文本预处理规则、6763 字拼音字典数据与默认配置值，构成衍生作品。
GPLv3 是强 copyleft，衍生作品必须以 GPLv3 分发，所以本项目整体采用 GPL-3.0。
MIT 与 GPLv3 兼容，未改动的 uosc_danmaku 上游文件仍可按 MIT 使用。

### 隐私自查

| 检查项 | 结果 |
|---|---|
| 弹幕 `p` 属性字段 | 只有 `时间,类型,字号,颜色`，无用户 ID / 哈希 / 时间戳 |
| 弹幕正文中的手机号 / QQ / 邮箱 / 网址 / 群号 | 无真实命中 |
| 跟踪文件中的本机绝对路径 | 无 |
| 跟踪文件中的用户名 / 邮箱 | 无 |
| `portable_config/files/`（观看历史） | 已在 `.gitignore` 排除 |
| 调试残留 | 已排除，无残留 |

### 移除

- **第三方博客原文存档移出仓库**：`在 uosc_danmaku 中集成 pakkujs 弹幕合并算法.md`
  （2 MB，含原作者截图）版权归原作者，不宜随仓库分发。
  已加入 `.gitignore`，本地文件保留；README 里改为只放原文链接。

### 备注

- 本次**没有**改动任何 Lua 代码，合并结果与 0.5.0 完全一致。
- git 历史里仍留有提交者的 QQ 邮箱和那份博客存档，
  要彻底清除需要重写历史后强推，见 `project.md` §15。

---

## [0.5.0] - 2026-10-05

合并标记不再用下标，改成**普通数字 + 半角括号** `(12)`，跟随正文字体。
下标形式保留为可选项。

### 背景

用户对比 B 站后发现下标标记「差不多一半多一点」，追问是不是 B 站做了什么处理。
排查结论：**B 站没有做任何处理**，`₍₁₂₎` 就是普通的 Unicode 下标字符
（`U+208D` / `U+2080-2089` / `U+208E`），大小完全由字体决定。

把 `(13)紧跟时事` 和 `₍₁₃₎紧跟时事` 按同字号渲染对照后，后者与 B 站截图形态完全一致
（括号高、数字小、贴着基线），确认字符没被替换。

关键问题在于这个比例**不稳定**：同一字号下「下标数字高 ÷ 正文数字高」实测：

| 字体 | 比例 |
|---|---|
| MS Gothic | 47.0% |
| Times New Roman | 52.0% |
| Arial | 54.1% |
| Microsoft YaHei | 55.4% |
| Segoe UI | 59.8% |
| Tahoma | 62.8% |
| Verdana | 63.3% |

在 47%~63% 之间浮动，且换字体就变。也就是说 `pakku_mark_scale` 要补偿多少
本身依赖于字体，没法给出一个到处都合适的默认值。

### 修改

- **默认标记改为 `(12)`**：`make_mark_tag()` 在 `mark_subscript` 关闭时
  产出 `"(" .. count .. ")"`，取代之前的 `[x12]`。

  注意 `(12)` 这个形式**不对应 pakku.js 的任何取值** ——
  pakku.js 只有下标 `₍₁₂₎` 和 `[x12]` 两种。这是本项目自选的。

- **`pakku_mark_subscript` 默认值 `true` → `false`**
  （`options.lua`、`uosc_danmaku.conf`、`M.build_config()` 三处同步）。

- **`pakku_mark_scale` 默认模式下失效**：`parse.lua` 在
  `pakku_mark_subscript == false` 时强制 `mark_scale = 1`，
  标记标签退化成只剩 `{\b1}`，标记完全跟随正文字体，不带独立字号。
  选项本身保留，`mark_subscript=yes` 时照旧生效。

### 验证

- 纯 LuaJIT：`(2)` / `(5)` / `(10)` / `(12)` / `(69)` / `(100)` / `(1234)` 全部正确；
  下标模式仍产出 `₍₃₎`，前缀模式产出 `(3)恭喜`，`mark=off` 时不加标记。
- mpv 端到端（隔离 `MPV_HOME` + 合成 64 秒 Y4M 视频 + 同名 xml 自动加载）：
  ```
  [uosc_danmaku] pakku: 6702 条 -> 4884 条（簇 4884，最多合并 69；
                 ==467 ≤1058 P46 247%；丢弃 0，缩小 0，放大 73，耗时 315 ms）
  ```
- 渲染层校验（dump 真实 ASS 事件，共 4883 条）：

  | 检查 | 结果 |
  |---|---|
  | 含 `{\b1}(N)` 的行数 | 735 |
  | 含 `\fs` 的行数 | 0 |
  | 含下标 `₍` 的行数 | 0 |
  | 含 `[xN]` 的行数 | 0 |
  | 含 `\i1`（斜体）的行数 | 0 |

  样例：
  ```
  0.00  50  {\pos(960, 869)}{\c&HFFFFFF&}2026/2/5簽到{\b1}(5)
  2.00  72  {\move(2028, 251, -108, 251)}{\c&HFFFFFF&}簽{\b1}(10)
  ```
- 合并结果（条数、耗时）与 0.4.0 完全一致，本次只动标记渲染。

### 备注

- 想要 pakku.js 的下标观感：`pakku_mark_subscript=yes`
  （配合 `pakku_mark_scale`，`1` = pakku 原始大小，`1.8` = 补到与正文数字同高）。
- `to_subscript()` 和下标字符表**没有删除**，只是默认不启用。
- 标记的位置偏离（pakku.js 默认标开头，本项目标末尾）保持不变。

---

## [0.4.0] - 2026-10-05

给合并标记加字号补偿：下标字形天生偏小，现在用 ASS 的 `\fs` 单独放大到与正文数字同高。

### 背景（结论：pakku.js 没有可抄的字号）

用户反馈 `₍₁₂₎` 太小，希望"抄 pakku 的字号"。
核对 `pakku.js-master/pakkujs/core/post_combine.ts` 的 `make_mark_meta()` 后确认：

```js
make_cnt = (cnt) => `₍${to_subscript(cnt)}₎`;
```

**pakku.js 从未给标记设置过字号**，只是把下标字符拼到文本后面，由播放器按弹幕
本身的字号渲染。也就是说"pakku 的字号" = 弹幕字号，没有额外参数可抄。
`₍₁₂₎` 看起来小，是**下标字形的固有属性**。

用 `System.Drawing`（GDI+ 与 libass 走同一套字体轮廓）量 Microsoft YaHei Bold
在 size=100 下的墨迹高度：

| 内容 | 墨迹高度 | 相对正文数字 |
|---|---|---|
| 正文数字 `0123456789` | 78.61 | 100% |
| 下标数字 `₀₁₂₃₄₅₆₇₈₉` | 43.56 | **55.4%** |
| 下标括号 `₍₎` | 53.71 | 68.3% |

所以本版本提供的是**补偿**，不是"抄"。

### 新增

- **`pakku_mark_scale` 选项**（默认 `1.8`）：标记的额外放大倍数。
  `parse.lua` 把它折算成 ASS 覆盖标签 `{\b1\fs<N>}₍M₎`，
  其中 `N = event_fontsize × pakku_mark_scale`。
  - `1` = 不放大，完全还原 pakku.js 的原始观感
  - `1.46` = 下标括号与正文数字同高
  - `1.8`（默认）= 下标数字与正文数字同高
  - 只对下标标记生效；`pakku_mark_subscript=no` 时自动失效（`[xN]` 是普通字形）

### 修改

- `parse.lua` 的事件循环调整了顺序：先算 `event_fontsize`，再拼文本与标记标签，
  因为标记的 `\fs` 依赖正文最终字号（含 `merge_scale` 的放大/缩小）。

### 验证

- 字体度量：用 GDI+ 量出下标数字 / 下标括号 / 正文数字的墨迹高度比，
  默认值由 `1 / 0.554 ≈ 1.8` 推得，而不是拍脑袋。
- 下标数字贴基线（底部 106.83 vs 正文数字 107.13），确认只需要 `\fs`、不需要 `\rise`。
- mpv 端到端（隔离 `MPV_HOME` + 合成 64 秒 Y4M 视频 + 同名 xml 自动加载）：
  ```
  0.00  50  {\pos(960, 869)}{\c&HFFFFFF&}2026/2/5簽到{\b1\fs90}₍₅₎
  2.00  72  {\move(2100, 251, -180, 251)}{\c&HFFFFFF&}簽{\b1\fs130}₍₁₀₎
  ```
  | 检查 | 结果 |
  |---|---|
  | `\fs` 值 == `event_fontsize × 1.8` | 735/735 全部一致 |
  | 含下标 `₍` 但不含 `\fs` 的行数 | 0 |
  | 含 `\i1`（斜体）的行数 | 0 |
  | `pakku_mark_subscript=no` 时 | 735 处 `[xN]`，`\fs` 出现 0 次 |
  | libass 缺字形告警 | 无 |

### 备注

- 合并结果（条数、耗时）与 0.3.0 完全一致，本次只动渲染。
- 标记的 `\fs` 会超过正文 2 倍上限（如正文 72 → 标记 130），这是刻意的：
  上限限制的是弹幕正文，标记是在正文基础上再补偿。
- 标记宽度不计入布局（`clean_text` 不含标记），放大后滚动弹幕尾部会多出一小截。
- 换字体后 `1.8` 这个比例不一定仍精确，觉得偏大偏小直接改数值即可。

---

## [0.3.0] - 2026-10-05

合并标记改用 pakku.js 的默认样式：**下标数字 + 下标括号**（`₍₁₂₎`），
去掉 `x` 与方括号。同时把标记的加粗逻辑从「正则猜」改成「模块直给」。

### 新增

- **`pakku_mark_subscript` 选项**（`yes` / `no`，默认 `yes`），
  对齐 pakku.js 的 `DANMU_SUBSCRIPT`：
  - `yes` → `恭喜₍₁₂₎`
  - `no` → `恭喜[x12]`

- **`to_subscript()`**（`pakku.lua:1040`）：把十进制数逐位转成下标数字，
  移植自 pakku.js 的同名函数。用 Unicode Superscripts and Subscripts 区段：
  数字 `U+2080`–`U+2089`，括号 `₍ U+208D` / `₎ U+208E`。
  已覆盖 1/2/5/9/10/12/23/47/69/100/1234 等位数边界。

- **`merge_mark` 输出字段**：`M.merge()` 现在把标记本体（如 `₍₁₂₎`，
  未标记时为空串）单独交给渲染层，不再让渲染层从文本里反推。

### 修改

- **标记样式**：`make_mark()` 拆成 `make_mark_tag()`（生成标记本体，
  `pakku.lua:1060`）+ `make_mark()`（按 `mark` 决定前/后缀，`pakku.lua:1071`）。
  默认输出从 `恭喜x12` 变成 `恭喜₍₁₂₎`。

- **`parse.lua` 的加粗逻辑**：不再用 `gsub("x(%d+)$", ...)` 猜标记形状，
  改成拿 `d.merge_mark` 做**明文比对**定位（先试末尾、再试开头）后插 `{\b1}`。

  这样有两个好处：
  1. 换任何标记样式（下标 / `[xN]` / 将来别的）都不用动渲染层
  2. 下标标记里没有 `x`，原本的正则根本匹配不到，不改就会丢失加粗

  内置合并（`merge_duplicate_danmaku`）的老路径没有 `merge_mark`，
  仍走原来的 `xN` 后缀正则。

- `options.lua` / `uosc_danmaku.conf` 的注释同步更新：
  现在**唯一**有意偏离 pakku.js 的只剩标记的**位置**（pakku.js 标在开头，
  本项目标在末尾），标记的**内容**已完全一致。

### 验证

- 标记生成自检：11 个数量值（含多位数、100、1234）全部生成正确的下标串。
- 组合自检：`mark=off` / `mark=prefix` / `mark_subscript=no` 三种组合输出正确；
  未合并的单条且正文以 `x12` 结尾时 `merge_mark == ""`，不被加粗。
- mpv 端到端（隔离 `MPV_HOME` + 合成 64 秒 Y4M 视频 + 同名 xml 自动加载）：
  ```
  [uosc_danmaku] pakku: 6702 条 -> 4884 条（簇 4884，最多合并 69；
                 ==467 ≤1058 P46 247%；丢弃 0，缩小 0，放大 73，耗时 315 ms）
  ```
- 渲染层校验（dump 真实 ASS 事件，共 4883 条）：
  ```
  2.00  72  {\move(2100, 251, -180, 251)}{\c&HFFFFFF&}簽{\b1}₍₁₀₎
  0.00  50  {\move(2157, 51, -237, 51)}{\c&H3DE5FD&}2024.12.23 簽{\b1}₍₂₎
  ```
  | 检查 | 结果 |
  |---|---|
  | 含 `{\b1}₍N₎` 的行数 | 735 |
  | 含 `\i1`（斜体）的行数 | 0 |
  | 含旧样式 `xN` 的行数 | 0 |
  | libass 缺字形告警 | 无（下标码位在 Microsoft YaHei / Noto Sans CJK 下可渲染） |

### 备注

- 下标码位不在 CJK 基本区，字体缺字形时会显示成方框。
  本项目字体环境实测无问题；换字体后可 `pakku_mark_subscript=no` 退回 `[xN]`。
- `pakku_mark` 默认仍是 `suffix`（pakku.js 是 `prefix`）。
  想要完全等同 pakku.js 的观感，再加 `pakku_mark=prefix`。
- 本次改动只影响标记的显示与加粗，合并结果（条数、耗时）与 0.2.0 完全一致。

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

**文档**：新增 `project.md`（开发地图）、`read.md`（使用说明，0.6.0 起更名为 `readme.md`）、本文件。

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
