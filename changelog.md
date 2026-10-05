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

## [0.8.7] - 2026-10-06

自动选择**终于跑起来了**（日志 7 里出现了 `自动选择：…`），但同一条日志里
暴露出三个问题：**重复收尾**、**错误被静默吞掉**、**剧集列表被当成搜索列表**。

### 进展

```
00:22:51.700  [flow] ③ https://danmaku-api.152468.xyz 返回 2 条
00:22:51.713  [flow] ④ 合计 2 条搜索结果
00:22:51.714  自动选择：孤独摇滚！（评分 48.3）
00:22:51.814  自动选择：孤独摇滚！（评分 48.3）    ← 又是 100ms 后
00:22:51.940  HTTP 请求失败：Calling failed. Exit code: -2 …
              ← curl 进度表：0 字节
00:22:53.012  [flow] ⑥ 剧集列表 43 条
00:22:53.017  自动选择：S8 BOCCHI STATION（评分 77.2）
00:22:54.754  该集弹幕内容为空，结束加载：…/comment/160639008
```

### 问题一：`do_final_update` 会被执行两次（真 bug，已定位）

两次自动选择的**标题和评分完全一样**，说明是同一份 `final_items` 被判了两次
—— 不是两次搜索。两次间隔 100ms，正好是 `run_menu_item` 里 `add_timeout(0.1)`
的等待时间。

根因在收尾条件上：

```lua
ctx.remaining.n = math.max(0, ctx.remaining.n - 1)   -- 下限被卡在 0
if ctx.remaining.n == 0 then pcall(do_final_update) end
```

`math.max(0, ...)` 把 n 的下限卡在 0，而三处调用点都判「== 0」。
**所以只要多来一次回调，n 已经是 0，收尾就会再跑一遍。**

实测对照（同一份代码，只去掉守卫）：

```
--- 修复前（无守卫）---  自动选中次数 = 2
--- 修复后 -----------  自动选中次数 = 1
```

第二次收尾又排了一次 `search-episodes-event`，把第一次正在跑的 curl 掐了 ——
就是那行 `Exit code: -2` 加 0 字节进度表。

修法：新增 `finish()`，用 `ctx.finished` 保证同一个 ctx 只收尾一次，
三处调用点统一走它。

### 问题二：`pcall(do_final_update)` 把异常静默吞掉

三处调用点原本都是裸 `pcall(...)`，出错没有任何输出。表现和网络失败一模一样：
**日志停在 ④，然后什么都没有**。现在 `finish()` 会把异常写到
`msg.error` + `[flow] ! 收尾处理出错：…` + OSD。

> 这个洞是写测试时自己踩出来的：测试忘了定义 `utf8_len`，
> `score_anime_item` 抛错，结果整条流程静默结束 —— 和用户报的现象无法区分。

### 问题三：43 集的剧集列表被判成「搜索列表」

`⑥ 剧集列表 43 条` 之后紧跟着 `自动选择：S8 BOCCHI STATION（评分 77.2）`。
「评分」说明走了标题打分，而不是集数匹配 —— 于是挑中一条特番，弹幕为空。

原因：`looks_like_episode_list()` 之前靠 `tonumber(it.hint)` 判断，
而 `hint = episode.episodeNumber`，**服务端不保证它是数字**。

修法分两步，第一步是错的，被自己的测试当场拦下：

1. ❌ 直接改成「从 hint 里抠数字」—— 但搜索结果的 hint 是
   `动漫 | 2022 | 来源：b 站`，里面的 **2022 被当成集数**，
   2 条搜索候选被误判成剧集列表。测试直接 FAIL。
2. ✅ 改用**语义判据**：菜单项的 `value` 里存着命令名，
   `load-danmaku` = 某一集，`search-episodes-event` / `get-extra-event` = 搜索番剧。
   按这个分类，一条都不用猜。只有在一条都认不出来时才退回 hint 猜测，
   且限制「整串 ≤ 12 字节、数字 ≤ 3 位」（一集番剧不会超过 999）。

### 顺带：构建指纹

日志 7 里 `[flow] ⑤ 选中：…` 用的是**旧编号**（0.8.5 才改成「⑤ 显示…列表」、
「⑥ 选中」），说明设备上的 `menu.lua` 是旧的 —— 0.8.3 的打分修正和连按去重
**根本没在跑**（日志里也确实没有 `忽略重复触发`）。

为了不再靠编号反推版本，现在启动时打印一次构建指纹：

```
D/uosc_danmaku: uosc_danmaku+pakku 2.2.0 build 6/203032/b802e38f
```

对 `main.lua` / `menu.lua` / `utils.lua` / `options.lua` / `parse.lua` /
`dandanplay.lua` 做数字指纹（多项式滚动哈希，不依赖 bit 库）。
改动其中一个文件指纹就变 —— 实测改一个字节：`b802e38f` → `20f76928`。

**排查第一步就是看这一行**：对不上就是文件没拷全。

### 验证

| 测试 | 结果 |
|---|---|
| 收尾只跑一次 + 出错上报（10 项） | 全过 |
| 修复前后对照（同一份代码去/留守卫） | 2 → 1 |
| 剧集列表判定与集数匹配（23 项） | 全过 |
| `trace_osd` 语义（8 项） | 全过 |
| 构建指纹随内容变化 | `b802e38f` → `20f76928` |
| 端到端真跑 mpv（隔离 MPV_HOME） | ①②③④ + `列表判定` + ⑤ 全出 |

---

## [0.8.6] - 2026-10-06

把 `danmaku_auto_select` 的默认值从 `no` 翻成 `yes`。

### 为什么

0.8.5 已经定位到故障点：**搜得到 2 条，卡在没人能操作的键盘列表上**。
回头再看这个设计的默认值，问题是：

- 这个分支是**静默成功**的。搜索正常、日志正常、没有报错 ——
  只是界面没法操作。用户连按三次按钮、等了十几秒、最后退出播放器，
  全程不知道发生了什么。
- 「默认值 + 一个打不开的界面」对无键盘设备等于不可用，
  而安卓/遥控器恰恰是本项目加 `danmaku-quick-search` 的初衷。
- 后悔成本低：挑错了改回 `no` 就完全回到菜单，其它行为一点不变。

### 修改

| 文件 | 改动 |
|---|---|
| `modules/options.lua` | `danmaku_auto_select = true` |
| `script-opts/uosc_danmaku.conf` | 从注释掉的 `#danmaku_auto_select=no` 改为显式的 `danmaku_auto_select=yes`，并说明原因 |
| `readme.md` | 「自动选择」一节改成陈述默认开启；标注这是 0.8.6 唯一的默认值变更 |
| `project.md` §17 | 记录翻转理由 |

保留的防线：`pick_auto_item()` 每次都会在日志里写明
`自动选择：<标题>（评分 N）`，所以「为什么挑了这条」永远可查；
连按去重、噪音关键词扣分（0.8.3）也都在。

### 备注

- 这是本项目第一个**改变用户可见默认行为**的版本，此前所有版本默认值与
  uosc_danmaku / pakku.js 对齐或更保守。之所以值得破例，是因为不破例的话
  目标设备上这个功能等于不存在。
- 桌面用户装了 uosc 的话本来就能正常点菜单，不受影响；想手动选就改 `no`。

---

## [0.8.5] - 2026-10-06

第三份日志（`mpvplayer_logs (6).txt`）**定位到故障点了** —— 而且不是 bug，
是「选择界面用不了」。

### 日志证据

0.8.4 的 `[flow]` 立刻见效，三次按键每次都停在同一处：

```
00:15:27.558  一键搜索：BOCCHI THE ROCK
00:15:27.558  [flow] ① 关键词：BOCCHI THE ROCK
00:15:27.586  [flow] ② 搜索「BOCCHI THE ROCK」，1 个服务器
00:15:30.456  [flow] ③ https://danmaku-api.152468.xyz 返回 2 条
00:15:30.467  [flow] ④ 合计 2 条搜索结果
              ← 到此为止
00:15:39.388  一键搜索：BOCCHI THE ROCK     （9 秒后，用户又按了一次）
00:15:47.886  一键搜索：BOCCHI THE ROCK     （8 秒后，再一次）
00:15:51      用户退出播放器
```

**搜索完全正常**：2.9 秒返回 2 条结果。卡的是**下一步「从结果里选一条」**：

| 判据 | 说明 |
|---|---|
| `自动选择` 出现 **0** 次 | `danmaku_auto_select=no`，走的是弹菜单那条路 |
| 全日志 `uosc` **0** 行 | uosc 没在跑 → `uosc_available = false` |
| 于是落到 `input_loaded` 分支 | 弹的是 `mp.input` 的 `选择:` 列表 —— **纯键盘** |

也就是说：**搜到了 2 条，屏幕上是那个上下键 + 回车的列表，而设备没有键盘。**
用户看到列表后连按两次按钮，最后退出。这和 §17 开头那张截图是同一个界面。

### 修改

**给「选择界面」这一步补上编号 ⑤**，并把原来的 ⑤⑥⑦ 顺延成 ⑥⑦⑧：

| 编号 | 内容 |
|---|---|
| ① | 关键词 |
| ② | 搜索 / 服务器数 |
| ③ | 每个服务器的结果或失败 |
| ④ | 合计结果数 |
| **⑤** | **显示哪种选择界面（新增）** |
| ⑥ | 选中项 |
| ⑦ | 剧集列表条数 |
| ⑧ | 拉取弹幕的 URL |

⑤ 会明确说出走了哪条路：

```
[flow] ⑤ 显示 uosc 菜单（2 条），等待用户点选
[flow] ⑤ 显示键盘列表（2 条），等待回车确认
[flow] ⑤ 无可用的选择界面（uosc=false, mp.input=true）
```

第三种情况以前是**完全静默的**：既没有 uosc 也没有 `mp.input` 时，
代码连菜单都不弹、不报错、不写日志 —— 按钮按下去就是毫无反应。
现在会 `msg.error` + `show_message`。

剧集列表那一层（⑦）也做了同样的处理。

### 验证

这次能真跑起来 —— 合成视频 + 隔离 `MPV_HOME` + 触发脚本，让 mpv 真实加载脚本：

```
一键搜索：BOCCHI THE ROCK
[flow] ① 关键词：BOCCHI THE ROCK
尝试获取番剧数据，servers: http://127.0.0.1:1 query: BOCCHI THE ROCK
[flow] ② 搜索「BOCCHI THE ROCK」，1 个服务器
Starting subprocess: [curl, ... http://127.0.0.1:1/api/v2/search/anime?keyword=...]
Subprocess failed: init
[flow] ③ http://127.0.0.1:1 失败：exit -3 子进程没起来（可能缺 curl）
搜索番剧失败 http://127.0.0.1:1: Calling failed. Exit code: -3 Error:
[flow] ④ 合计 0 条搜索结果
搜索无结果：Calling failed. Exit code: -3 Error:
[flow] ⑤ 显示键盘列表（0 条），等待回车确认
```

`exit -3` 是沙箱限制（mpv 的 subprocess 走管道捕获被拦，`Subprocess failed: init`），
不是真实网络错误 —— 但它正好把流程推到了 ⑤，所以 ⑤ 这条路径是真跑通的。

**并且重复了同样的运行、但 `danmaku_verbose_osd` 保持默认（关）**：
`[flow]` ①②③④⑤ 一条不少，OSD 一条没有。0.8.4 的核心主张（日志不依赖开关）
由此得到端到端确认。

### 结论

**搜到了，选不了。** 解法就是把 `danmaku_auto_select` 改成 `yes` ——
这个功能 0.8.3 就做好了（打分 + 去重），只是没打开。

顺带一提，日志里 `BOCCHI THE ROCK` 只返回 2 条，而其中一条正是
0.8.3 专门压下去的 COUNTDOWN 特番（83.1 → 62.3）。打开自动选择后，
选中的会是正片。

---

## [0.8.4] - 2026-10-06

拿到第二份安卓日志（`mpvplayer_logs (5).txt`，1158 行）。这次日志格式完整，
但**结论是「日志本身不够用」** —— 于是把流程日志从「要手动开」改成「默认就有」。

### 日志里能看到什么

9 次 `一键搜索：xxx`，其中 6 次是 `孤独摇滚`、3 次是 `孤独摇滚 | tv`。
视频是 `[DMG&VCB-Studio] BOCCHI THE ROCK! [01]...mkv`。

- **按钮是通的**：脚本加载了，`script-message` 收到了，
  `parse_title()` 从文件名解析出了 `孤独摇滚`。
- `已解析 N 条弹幕`（info 级，本来就该出现）**一次都没有** ——
  说明全程没有任何一集成功加载到弹幕。
- `curl` / `Subprocess` / `Exit code` 出现 **0 次**，
  danmaku 相关的 error/warn **0 次**。

关于 `孤独摇滚 | tv`：`search-anime-event` 约定用 `|` 分隔「名称|类型」，
而 `danmaku-quick-search` 走文件名解析时会主动把 `|` 和 `@` 替换成空格
（`menu.lua` 里那段 `gsub("[|@]", " ")`）。所以这 3 次**不是**文件名解析来的，
是前端按钮显式带了参数 —— 例如配成了
`script-message danmaku-quick-search "孤独摇滚 | tv"`。

### 问题

日志里 `uosc_danmaku` 总共只有 9 行，全是 `一键搜索`。也就是说：

> 一次完整的搜索流程，日志里只留下「按了按钮」这一行。

原因是流程里其余节点要么在 `debug` 级、要么被 `danmaku_verbose_osd` 挡着，
而 mpv 脚本默认只输出 info 及以上。上一版加的 `danmaku_verbose_osd`
要求用户先改配置 —— 但**排查问题时最需要的恰恰是「什么都不用配就能拿到线索」**。

### 修改

**`modules/utils.lua` 的 `trace_osd()` 拆成两半**：

| 行为 | 以前 | 现在 |
|---|---|---|
| 写日志（`msg.info("[flow] …")`） | 只在开关打开时 | **永远** |
| 显示到屏幕（`show_message`） | 只在开关打开时 | 只在开关打开时 |

`msg.info` **不会显示在屏幕上**（只有 `show_message` 才会），所以用户
什么都感觉不到，但导出的日志天然带上了 ①~⑦ 每一步。一行一个节点，量很小。

顺带把几条「沉默的失败」提到 warn 级（这些以前只在 debug/verbose，等于没记）：

| 位置 | 以前 | 现在 |
|---|---|---|
| `menu.lua` `get_animes` 单服务器失败 | `msg.debug` | `msg.warn` |
| `dandanplay.lua` 搜索番剧失败 | `msg.debug` | `msg.warn` |
| `dandanplay.lua` 匹配番剧失败 | `msg.debug` | `msg.warn` |
| `dandanplay.lua` 获取弹幕失败 | `msg.debug` | `msg.warn` |
| `parse.lua` `该集弹幕内容为空，结束加载` | `msg.verbose` | `msg.warn` |
| `parse.lua` `弹幕内容为空，无法保存` | `msg.verbose` | `msg.warn` |
| `dandanplay.lua` / `extra.lua` 各类「无结果」 | `msg.verbose` | `msg.info` |
| `dandanplay.lua` 候选相似度 | `msg.debug` | `msg.info` |

`dandanplay.lua` 本来就有不少 info 级日志，所以这轮之后
「搜索 → 选番剧 → 选集 → 拉弹幕」每一步都会在日志里留痕。

### 验证

`trace_osd()` 用桩件驱动，8 项全过：

```
=== 开关关闭时（默认）===
  ok   仍写日志
  ok   不上屏
=== 开关打开时 ===
  ok   写日志
  ok   上屏
=== 边界 ===
  ok   无 varargs 不炸
  ok   格式串参数不足不抛错
  ok   options 为 nil 不抛错
  ok   options 为 nil 时不上屏
通过 8，失败 0
```

### 备注

- `danmaku_verbose_osd` 的语义变了：现在只管「要不要上屏」，不再管「要不要记」。
  conf 里的注释已同步。
- 这次**没有定位到日志里流程中断的具体原因** —— 因为这份日志里本来就没有
  足够信息，任何结论都会是猜的。下一份日志（用新代码跑）才能定论。

---

## [0.8.3] - 2026-10-05

修掉日志 ④ 暴露的两个问题：**自动选择会挑中特番**，以及**连按按钮会自我打断**。

### 背景

上一版加了 OSD 跟踪之后，用户导出了完整日志。关键片段：

```
23:41:25.502  自动选择：孤独摇滚！（评分 48.3）
23:41:25.603  自动选择：孤独摇滚！（评分 48.3）      ← 同一部，100 ms 后第二次
               HTTP 请求失败：Calling failed. Exit code: -2
                   % Total  % Received  ...  0  0  0  0     ← curl 进度表，0 字节
23:41:26.9    自动选择：S11 BOCCHI THE ROCK! Presents COUNTDOWN BOCCHI!（评分 83.1）
               该集弹幕内容为空：.../comment/160639011
```

两个现象、一个共同原因：

1. **两次自动选择只差 101 ms** —— 这正好是 `run_menu_item` 里
   `mp.add_timeout(0.1, ...)` 的等待时间。也就是说**两次搜索各自返回了结果**，
   各自排了一次后续命令。
   而 `search-episodes-event` 一进来就调 `perform_cancel_active_request()`，
   **第二次把第一次正在跑的请求掐掉了**。日志里那行 `0 0 0 0` 的
   curl 进度表就是证据：它不是网络错误，是进程被杀（`exit -2`）。

2. **83.1 分那条是 COUNTDOWN 特番**，根本没有弹幕。
   原来的打分只有「标题相似度 + 类型关键词」两条规则，
   而特番标题 `S11 BOCCHI THE ROCK! Presents COUNTDOWN BOCCHI!`
   前缀完全命中搜索词，相似度被顶得很高。

### 修复

- **`modules/menu.lua` 新增 `AUTO_SELECT_NOISE_RULES`**：对
  `countdown` / `特番` / `特别篇` / `特别节目` / `总集篇` / `预告` / `花絮` /
  `生放送` / `演唱会` / `舞台` / `声优` 这些关键词扣分（−20 ~ −40）。
  这一类条目的共同点是**名字又长又啰嗦，而且往往没有弹幕**。

- **标题长度惩罚**：`score -= min(多出的字数, 40) * 0.8`。
  正片标题通常和搜索词差不多长，特番会多出一大截。
  上限 40 字，避免长标题被一棍子打死。

- **`auto_select_should_skip()` 去重**：同一「阶段 + 上下文 + 选中项」在
  `AUTO_SELECT_DEDUP_SEC = 5` 秒内只处理一次，重复触发直接 `return`，
  记 `自动选择：忽略重复触发（…）` 和 trace ⑤。
  这样只会排队一次后续命令，也就不会自己掐自己。

  三个自动选择入口都装了闸门（`搜索` / `剧集` / `列表`），
  因为 `pick_auto_item()` 是被三处共用的。

  内部用 `key -> 时间` 的表而不是「只记最后一个 key」：后者在
  A→B→A 来回点时会绕过去重。表在每次检查时顺便剪枝，不会长起来。

### 验证

打分：把函数从 `menu.lua` 里抽出来，喂日志里真实出现过的条目：

| 搜索词 | 条目 | hint | 改动前 | 改动后 |
|---|---|---|---|---|
| `BOCCHI THE ROCK` | `S11 ... Presents COUNTDOWN BOCCHI!` | 动漫 2023 | 83.1 | **62.3** |
| `BOCCHI THE ROCK` | `BOCCHI THE ROCK!` | 动漫 2022 | — | **170.0** |
| `BOCCHI THE ROCK` | `BOCCHI THE ROCK!` | 电影 2025 | — | 95.0 |
| `孤独摇滚` | `孤独摇滚！` | 动漫 2022 b 站 | 48.3 | **144.2** |
| `孤独摇滚` | `孤独摇滚 总集篇` | 动漫 2024 | — | 106.9 |
| `孤独摇滚` | `孤独摇滚（上）` | 电影 2025 爱奇艺 | — | 61.9 |

原来 83.1 压过一切的 COUNTDOWN 掉到 62.3，真正的正片 170.0。
总集篇（106.9）仍高于电影版（61.9），排序符合直觉。

去重：抽出闸门函数，用假时钟驱动，11 项全过 ——

```
=== 去重闸门 ===
  ok   首次点击应放行
  ok   100ms 后同一项应拦截
  ok   4.9 秒后仍应拦截
  ok   6 秒后应重新放行
  ok   立刻切到另一项应放行
  ok   立刻切回原项应拦截          ← 这一条在改成表结构之前是 FAIL
  ok   同项但搜索词不同应放行
  ok   不同阶段应放行
  ok   暂停很久后应重新放行
=== 模拟狂按按钮 10 次（间隔 0.08 秒）===
  ok   10 次连点只放行 1 次
=== 剪枝 ===
  过期前条目数 2，清理后 1
  ok   过期条目被剪枝
通过 11，失败 0
```

另外在真实 mpv 里确认了 `mp.get_time()` 存在，而且**暂停时仍按真实时间前进**
（暂停 2 秒，`0.015 → 2.015`，差 2.000）—— 否则去重窗口会被暂停冻住，
暂停期间再点就永远被当成重复。

### 备注

- 去重是**兜底**，不是根治：连按按钮仍然会发两次搜索、浪费一次请求，
  只是不会再互相打断。想彻底避免，得在 `danmaku-quick-search` 入口处做节流。
- 打分规则仍是刻意简单的固定表格，没有引入词向量之类的东西 ——
  挑错了把 `danmaku_auto_select` 关掉就回到手动选，行为可预期。

---

## [0.8.2] - 2026-10-05

排查安卓端的「按下按钮后毫无反应」。加了一套 OSD 流程跟踪，顺手修掉一个真 bug。

### 背景

用户提供了 mpvex（安卓）导出的日志，里面 `一键搜索：xxx` 出现了 7 次，
**之后什么都没有** —— 没有请求、没有错误、没有结果。

逐条比对后确认原因：**该 app 的日志导出只保留 info 及以上**
（整个 App Logs 段里 `uosc_danmaku` 只有那 7 条 `msg.info`，
连 `osd/libass`、`sub/ass` 的内部日志都在，唯独没有脚本的 verbose/debug）。
而搜索流程里的失败恰恰只记在 `debug` 级；「一条都没搜到」时更是**完全静默**，
只弹一个空列表。等于在黑盒里排查。

### 修复

- **`modules/utils.lua` 的 `msg` 未定义**（真 bug）。
  这个文件以前只用 `mp.msg`，从来没 require 过 `msg`；
  其它模块里的 `msg` 都是 `local`，所以它不是全局。
  新加的 `trace_osd` 里写了 `msg.info(...)` →
  `attempt to index global 'msg' (a nil value)`。
  已补 `local msg = require("mp.msg")`。

  > 这个 bug 是被本版本新加的 `pcall` 包装当场抓出来的 ——
  > 原本它只会让「一键搜索」静默失败，和用户遇到的现象一模一样。

### 新增

- **`danmaku_verbose_osd` 选项**（默认 `no`）与 `trace_osd()`：
  把整条链路打到 OSD 上，停在哪一号就是哪一步出问题。

  ```
  ① 关键词：孤独摇滚
  ② 搜索「孤独摇滚」，1 个服务器
  ③ https://... 失败：exit 7 连不上服务器：Failed to connect
  ④ 合计 0 条搜索结果
  ⑤ 选中：孤独摇滚！  （评分 135.0）
  ⑥ 剧集列表 13 条
  ⑦ 拉取弹幕：https://.../api/v2/comment/12345?withRelated=true&chConvert=0
  ```

- **搜索失败/无结果现在会显示**：`get_animes` 原来只在 `debug` 级记录每个
  服务器的失败，全部失败时也不提示。现在会记下最后一个错误并在 OSD 上汇总：
  `搜索无结果（最后错误：exit 7 连不上服务器：...）`。

- **`danmaku-quick-search` 整个处理包了 `pcall`**，出错时显示
  `一键搜索出错：<原因>` 并记 error 日志，不再静默。

### 验证

隔离 `MPV_HOME` + 合成视频 + 只负责发消息的触发脚本：

```
一键搜索：孤独摇滚
[trace] ① 关键词：孤独摇滚
[trace] ② 搜索「孤独摇滚」，1 个服务器
[trace] ③ https://danmaku-api.152468.xyz 失败：exit -3 子进程没起来（可能缺 curl）
[trace] ④ 合计 0 条搜索结果
[w] 搜索无结果：Calling failed. Exit code: -3 Error:
```

以及直接发 `load-danmaku` 触发拉取分支：

```
[trace] ⑦ 拉取弹幕：http://127.0.0.1:8765/api/v2/comment/1004?withRelated=true&chConvert=0
[e] HTTP 请求失败：Calling failed. Exit code: -3 Error:
```

`exit -3` 是沙箱的限制（mpv 的 subprocess 带管道捕获被拦），
不是真实网络错误；⑤⑥ 需要 HTTP 成功才能走到，沙箱里无法覆盖。

### 备注

- 默认关闭 `danmaku_verbose_osd`，不影响正常使用。
- 除上面那个 `msg` bug 外，没有改动任何请求逻辑。

---

## [0.8.1] - 2026-10-05

把网络失败的真实原因显示到 OSD 上。安卓上没有方便的日志入口，
原来只弹一句「获取数据失败」，原因（curl 退出码）只在 `msg.error` 里，
用户根本看不到，无从排查。

### 修改

- **`modules/utils.lua`**：新增 `brief_error()` 和 `http_error_hint()`。
  后者会把 subprocess 的错误串压成一行短文本，并翻译常见 curl 退出码：

  | 退出码 | 提示 |
  |---|---|
  | `-3` | 子进程没起来（可能缺 curl） |
  | `6` | 域名解析失败 |
  | `7` | 连不上服务器 |
  | `22` | HTTP 返回错误状态码 |
  | `28` | 请求超时 |
  | `35` / `60` | TLS 握手失败 / 证书不受信任 |
  | `51` / `52` / `56` | 证书校验失败 / 服务器无响应 / 接收数据失败 |

  文本刻意压得很短（详情截断到 18 个字符）：OSD 字号大，太长会被挤出屏幕，
  而关键信息（退出码 + 人话）在最前面。

- **`apis/dandanplay.lua`**：`fetch_danmaku_data` 失败时
  `获取数据失败` → `弹幕获取失败：<原因>`；
  `handle_fetched_danmaku` 的空弹幕提示补上服务器和剧集号：
  `该集弹幕内容为空（danmaku-api.152468.xyz / 剧集 12345）`。

- **`modules/menu.lua`**：`get_episodes` 的失败提示同样带上原因
  （`剧集数据获取失败：<原因>`）。

- `readme.md`：排查问题一节新增「弹幕获取失败 / 该集弹幕内容为空」的对照表。

### 验证

- 纯函数单测：8 组错误串（含 `-3` / `6` / `7` / `22` / `28` / `60` / 空串 / nil）
  都产出了预期文本，中文截断按 UTF-8 边界不切碎字符。
- mpv 端到端：直接发 `load-danmaku` 触发 `fetch_danmaku` 的失败分支，
  日志确认走到了新提示，且**没有** `attempt to call a nil value`
  （证明 `http_error_hint` 这个全局在 menu.lua / dandanplay.lua 里可见）：
  ```
  [v][uosc_danmaku] 尝试获取弹幕：http://127.0.0.1:65500/api/v2/comment/12345?withRelated=true&chConvert=0
  [e][uosc_danmaku] HTTP 请求失败：Calling failed. Exit code: -3 Error:
  ```
- 6 个 Lua 文件语法检查通过。

### 备注

- 只改了提示文案与错误处理，**没有改动任何请求逻辑**。
- `brief_error` 用 `utf8_sub` 截断，避免把汉字切成半个。

---

## [0.8.0] - 2026-10-05

新增 `danmaku_auto_select`：搜索结果不再弹列表，程序按规则自动挑一条。
解决安卓上「搜出来了但选不了」的问题。

### 背景

[0.7.0] 的 `danmaku-quick-search` 只跳过了「输入关键词」，没跳过「选结果」。
用户实测截图里出现了 `选择:` 的列表 —— 这是 `open_menu_select()` 里的
`input.select()`（`prompt = '选择:'`），也就是 **mpv 自带的输入 UI**，
纯键盘（上下键 + 回车），完全不认鼠标/触摸。

它的出现说明那台设备上 **uosc 没有运行**，弹幕插件的所有菜单都降级到了
`mp.input`。而 uosc 菜单那条路至少要鼠标事件，也一样指望不上触摸屏。

### 新增

- **`danmaku_auto_select` 选项**（默认 `no`）。开启后：

  | 列表类型 | 判据 | 挑选规则 |
  |---|---|---|
  | 剧集列表 | 过半可选项的 `hint` 是纯数字 | 文件名推断的集数精确匹配，匹配不上取第一集 |
  | 搜索列表 | 否则 | 标题相似度 + 类型关键词打分取最高 |

  打分只有两条规则，刻意简单可预期：

  ```
  score = jaro_winkler(规范化(parse_title()), 规范化(标题)) * 100
        + (标题完全一致 ? 30 : 0)
        + 类型关键词加减分   -- 动漫/番剧 +40，电影/剧场版 -35，真人 -30，电视剧 -20
  ```

  这样「孤独摇滚！(动漫|2022)」会赢过「孤独摇滚（上）(电影|2025)」。

  选中后会打日志和 OSD 提示选了什么、为什么，例如：
  ```
  [uosc_danmaku] 自动选择：孤独摇滚！ （评分 135.0）
  [uosc_danmaku] 自动选择：第4话 （集数精确匹配第 4 集）
  ```

### 实现

挑选逻辑集中在 `pick_auto_item()`，挂了三处：

| 位置 | 覆盖路径 |
|---|---|
| `open_menu_select()` 开头 | **所有**「没有 uosc 时」的列表入口，含 `apis/extra.lua` |
| `get_animes()` 的 `do_final_update` | dandanplay 搜索（有 uosc 时也生效） |
| `get_episodes()` 末尾 | 剧集列表（有 uosc 时也生效） |

放在 `open_menu_select()` 是关键：`apis/extra.lua:343`（剧集）和 `:423`（搜索）
都走它，而用户截图里的列表格式（`cat_name | year | 来源：xxx`，见 `extra.lua:403`）
正是 `extra.lua` 那条路径 —— 一开始只 hook 了 `get_animes`，覆盖不到。

弹幕延迟/筛选菜单（`is_time = true`）不做自动选择。

### 验证

沙箱里 mpv 的 `subprocess` + `capture_stdout` 被拦（`Subprocess failed: init`，
status `-3`，命名管道限制），跑不了真实 HTTP 搜索。改成在隔离副本里直接调用
真实函数，喂用户截图里的 7 条实际候选：

```
TESTSCORE   51.43  孤独摇滚（上）           [电影 | 2025 | 来源：爱奇艺]
TESTSCORE   51.43  孤独摇滚（上）           [电影 | 2025 | 来源：优酷]
TESTSCORE   46.67  孤独摇滚(上)普通话版     [电影 | 2025 | 来源：芒果TV]
TESTSCORE   42.50  孤独摇滚（上）（普通话）  [电影 | 2025 | 来源：爱奇艺]
TESTSCORE  135.00  孤独摇滚！               [动漫 | 2022 | 来源：b 站]   ← 胜出
TESTSCORE   67.50  孤独摇滚!                [电影 | 2025 | 来源：b 站]
TESTSCORE   60.00  孤独摇滚(上)            [电影 | 2025 | 来源：芒果TV]

TESTPICK-ANIME   => 孤独摇滚！  (评分 135.0)         ← 正确，避开了电影版
TESTPICK-EPISODE => 第4话  (集数精确匹配第 4 集)     ← S01E04 正确命中
```

两个判断函数也确认了：7 条搜索候选 `episode-list? false`，
12 集剧集列表 `episode-list? true`。

### 备注

- 打分只有两条规则，**可能挑错**。挑错了把 `danmaku_auto_select` 改回 `no`
  即可回到手动选择。
- 默认关闭，不影响现有行为。
- 本次未改动 pakku 合并逻辑。

---

## [0.7.0] - 2026-10-05

新增 `danmaku-quick-search`：给没有键盘的环境（安卓 mpv、遥控器、手柄）
提供一键搜索，跳过需要打字和回车的搜索框。

### 背景

弹幕搜索有两条路径，都要按回车：

| 路径 | 位置 | 卡点 |
|---|---|---|
| uosc 菜单 | `modules/menu.lua` `open_input_menu_uosc()` | `search_debounce = "submit"` |
| mpv 原生输入框 | `modules/menu.lua` `open_input_menu_get()` | `mp.input.get()` 是打字框 |

安卓上没有回车键，就卡在这一步。

但搜索框里本来**就预填了**番剧名（uosc 路径 `search_suggestion = parse_title()`，
原生路径 `default_text = title`），所以缺的不是打字，只是「确认」。

### 新增

- **`danmaku-quick-search` script-message**（`modules/menu.lua`）：
  直接拿 `parse_title()` 的结果调已有的 `search-anime-event`，跳过搜索框。
  结果照常以菜单列出，点选即可。

  ```
  script-message danmaku-quick-search
  script-message danmaku-quick-search "孤独摇滚"        # 可选参数
  ```

  两个细节：
  - `search-anime-event` 用 `|` 分隔「名称|类型」、`@` 分隔过滤词。
    只有**从文件名解析出来的**关键词会把这两个字符替换成空格，
    手动传入的参数原样保留，方便继续用高级语法
  - `parse_title()` 返回空时给提示并 warn，不发无意义的空搜索

- **`danmaku_quick_search_key` 选项**（`modules/options.lua` +
  `script-opts/uosc_danmaku.conf`）：一键搜索的快捷键。
  默认空字符串 = **不绑定**，不改变现有行为。绑定逻辑在 `main.lua`。
  安卓端也可以留空、直接让前端自定义按钮执行
  `script-message danmaku-quick-search`。

### 为什么不用 uosc 的 `search_submit`

uosc 的 `Menu.lua` 支持 `search_submit`，加上去能让搜索菜单**打开即自动搜索**，
更省事。但它只解决「提交」不解决「触发」——安卓上还得先有办法点开那个菜单，
而 uosc 菜单靠鼠标区域点击（`cursor:zone('primary_down', ...)`），
前端不把触摸转成鼠标事件就点不动。所以选了可由前端按钮直接调用的
script-message 方案。两者不冲突，将来确认前端支持触摸转鼠标，
把 `search_submit = true` 加进 `open_input_menu_uosc()` 的 `menu_props` 即可。

### 验证

隔离 `MPV_HOME` + 合成视频 + 只负责发消息的触发脚本，跑 mpv 看日志：

```
[2.030][i][uosc_danmaku] 一键搜索：qs DMG&VCB-Studio BOCCHI THE ROCK   -- 自动解析，| @ 被清掉
[2.026][i][uosc_danmaku] 一键搜索：孤独摇滚 | tv @SP                   -- 手动传参，| @ 原样保留
```

三次运行日志均无 `[error]` 与 `stack traceback`。

### 备注

- 本次未改动 pakku 合并逻辑，合并结果与 0.6.1 完全一致。
- `readme.md` 新增「没有键盘的环境」一节，含一键搜索用法与
  「完全不交互」（`auto_load` / 本地同名 xml）的替代方案。

---

## [0.6.1] - 2026-10-05

重写 git 历史，处理掉两处已经进入历史的隐私 / 版权问题。
**没有改动任何文件内容**：最终 HEAD 的 tree 与重写前完全一致。

### 变更

| 问题 | 处理 |
|---|---|
| 提交者邮箱是个人 QQ 邮箱 | 5 个提交的 author + committer 全部改为 `209313510+lnmp30@users.noreply.github.com` |
| 第三方博客原文存档留在历史里 | 从全部 5 个提交中移除 |

提交信息、作者名、作者时间、提交时间全部原样保留；
每个提交相对旧版的 diff 只有那一个文件。

### 实现方式

手工重建，没用 `git filter-branch`：

1. `git cat-file commit` 取原始提交对象，按第一个空行切出原始信息
2. `git read-tree <tree>` 装进索引 → `git rm --cached` 剔除博客存档 → `git write-tree`
3. 用 `GIT_AUTHOR_*` / `GIT_COMMITTER_*` 环境变量（姓名与时间原样、邮箱替换）调 `git commit-tree`

不用 `filter-branch` 的原因：它在 Windows 上把 filter 命令交给 `sh -c`，
中文路径要穿过 PowerShell → git → sh 三层，编码容易出问题。

### 备注

- 强推**不会立刻**从 GitHub 服务端删除旧提交对象，旧 SHA 在一段时间内仍可访问。
  要彻底清除需联系 GitHub Support 或删库重建。
- 本仓库的 `user.email` 改为 `--local` 配置，全局配置未动。

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
- git 历史里当时仍留有提交者的 QQ 邮箱和那份博客存档，
  已在 [0.6.1] 重写历史时清除，见 `project.md` §15。

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
