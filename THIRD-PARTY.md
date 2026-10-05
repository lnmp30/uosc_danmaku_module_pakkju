# 第三方组件与许可证

本仓库**整体以 GNU General Public License v3.0 分发**（见 [`LICENSE`](LICENSE)）。
下面说明为什么，以及仓库里各部分代码各自的来源与许可证。

---

## 为什么本项目是 GPL-3.0

因为核心模块 `modules/pakku.lua` 是 [pakku.js](https://github.com/xmcp/pakku.js)
的**移植 / 衍生作品**，而 pakku.js 以 **GPLv3** 分发。

具体地，`pakku.lua` 复用了 pakku.js 的：

| 复用内容 | 出处 |
|---|---|
| 四级相似判定（完全相同 / 编辑距离 / 拼音距离 / 余弦相似度）与判定顺序 | `pakkujs/similarity/repo-cpp/src/main.cpp` |
| 滑动窗口聚类、标记拼接、字号放大、密度调控的逻辑 | `pakkujs/core/combine_worker.ts`、`core/post_combine.ts` |
| 文本预处理规则（尾部标点表、全角半角表、空格规则、forcelist 默认值） | `pakkujs/core/combine_worker.ts`、`background/config.ts` |
| **拼音字典数据**（6763 个汉字 → 声母/韵母编码） | `pakkujs/similarity/repo-cpp/src/pinyin_dict.txt` |
| 各项默认配置值 | `pakkujs/background/config.ts` 的 `DEFAULT_CONFIG` |

GPLv3 是**强 copyleft** 许可证：分发衍生作品时，整体必须以 GPLv3 授权，
并提供完整对应源码。因此本仓库整体采用 **GPL-3.0**。

> 注意：pakku.js 的源码本身**不在**本仓库中（`.gitignore` 已排除
> `pakku.js-master/`），本仓库只是它的衍生作品。

---

## 组件清单

| 组件 | 位置 | 许可证 | 版权 |
|---|---|---|---|
| **本项目的 pakku 移植**<br>`modules/pakku.lua`、`modules/parse.lua` 等的改动、`script-opts/uosc_danmaku.conf` 的 pakku 段、三个 `.md` 文档 | `portable_config/scripts/uosc_danmaku/modules/pakku.lua` 等 | **GPL-3.0** | 本项目作者 |
| **uosc_danmaku**（宿主插件，vendored） | `portable_config/scripts/uosc_danmaku/` | **MIT** | Copyright (c) 2024 吴南李 |
| **pakku.js**（算法与拼音字典来源，未分发） | — | **GPL-3.0** | xmcp 及贡献者 |
| **uosc**（运行时依赖，未分发） | — | **LGPL-2.1** | tomasklaen |
| 弹幕测试数据 | `testdata/*.xml` | 见下 | 各弹幕作者 |

### MIT 与 GPL 的兼容性

uosc_danmaku 是 MIT，MIT 与 GPLv3 兼容：MIT 代码可以并入 GPLv3 作品一起分发，
合并后的整体按 GPLv3 授权。**未改动的 uosc_danmaku 原始文件仍然可以按 MIT 使用**
（其许可证全文保留在 `portable_config/scripts/uosc_danmaku/LICENSE`）。

uosc 是 LGPL-2.1，且本仓库**不包含**它的源码，只把它当作运行时依赖引用，
不构成分发，也不影响本仓库的许可证。

---

## 各许可证全文位置

| 许可证 | 全文 |
|---|---|
| GPL-3.0（本项目） | [`LICENSE`](LICENSE) |
| MIT（uosc_danmaku） | [`portable_config/scripts/uosc_danmaku/LICENSE`](portable_config/scripts/uosc_danmaku/LICENSE) |
| GPLv3（pakku.js） | <https://github.com/xmcp/pakku.js/blob/master/LICENSE.txt> |
| LGPL-2.1（uosc） | <https://github.com/tomasklaen/uosc/blob/main/LICENSE.LGPL> |

---

## 弹幕测试数据

`testdata/` 下的三个 `.xml` 是 BOCCHI THE ROCK! 第 03/04/07 集的公开弹幕存档，
用作合并算法的回归测试数据。

- 文件里只有 `时间,类型,字号,颜色` 四个字段，**不含用户 ID、用户哈希或发送时间戳**
- 弹幕文本是公开视频下的公开评论，著作权属于各条弹幕的作者
- 仅作算法测试用途；如权利人提出异议，删除对应文件即可

---

## 如果你要二次分发

1. 保留 [`LICENSE`](LICENSE) 与 `portable_config/scripts/uosc_danmaku/LICENSE`
2. 保留本文件（或等效的第三方声明）
3. 若修改了 `modules/pakku.lua` 等 GPL 部分，需一并提供修改后的源码
4. 想用于闭源项目的话，本项目**不适合**——请直接联系 pakku.js 的作者
   洽谈另一套授权，或自行按算法描述重写实现
