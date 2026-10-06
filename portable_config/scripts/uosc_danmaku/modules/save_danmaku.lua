--[[ 保存「过滤后 / 合并后」的弹幕（本项目新增，上游没有这个文件）

     上游的 convert_danmaku_to_xml() 只能存**原始**弹幕 —— 它直接从
     DANMAKU.sources 取数，绕过了黑名单过滤和 pakku 合并。本模块补上：

       filtered  去掉黑名单命中的
       merged    再经 pakku 合并，即屏幕上实际显示的样子（文本带 (12) 标记）

     raw 模式**不走这里**，走的是 parse.lua 里上游那段原样代码。

     ------------------------------------------------------------------
     为什么单独一个文件：为了以后合并上游方便。
     上游永远不会碰这个文件，所以它跟上游**不可能冲突**。
     parse.lua 里只留两处极小的改动：
       1. 文件头一行 require + 一处 set_deps（注入上游的局部件）
       2. convert_danmaku_to_xml() 开头几行的转发 shim
     其余全是「新增」而非「修改」，git 合并时能自动并进去。

     ------------------------------------------------------------------
     ⚠️ XML 的写出格式在这里**复制**了一份上游的实现（转义 + <d p="...">）。
     之所以不复用上游那个函数，是因为它把「收集」和「写出」揉在一起，
     要复用就得改它的内部 —— 那正是本文件想避免的。
     代价是：上游若改了 xml 格式，这里要跟着改。
     好在 xml 格式由弹幕规范定死，实际不会动。
]]

-- mp.msg 用 pcall 包住：本模块要在裸 luajit 下也能单测（同 modules/pakku.lua 的做法）
local ok_msg, msg = pcall(require, "mp.msg")
if not ok_msg or type(msg) ~= "table" then
    msg = setmetatable({}, { __index = function() return function() end end })
end

local M = {}

-- ---------------------------------------------------------------------------
-- 依赖注入
--
-- black_patterns / make_delay_lookup 是 parse.lua 的 **local**，外部拿不到；
-- 与其把它们提升成全局（那是改上游代码），不如由 parse.lua 主动传进来。
-- 两个 getter 是因为对应的值会被整体替换，不能捕获当时的引用。
-- ---------------------------------------------------------------------------
local deps = nil

function M.set_deps(d)
    deps = d
end

local function need()
    if not deps then
        return nil, "modules/save_danmaku 还没拿到依赖（parse.lua 里漏了 set_deps？）"
    end
    return deps
end

local pakku = require("modules/pakku")

-- ---------------------------------------------------------------------------
-- 阶段标签
--
--! 解决什么问题：本项目保存的 `merged` 文件里，正文是 `恭喜(12)` 这种带标记的
--! 文本。把它当普通弹幕源再跑一遍合并，标记会被当成正文参与相似度 ——
--! `恭喜(12)` 三条会变成 `恭喜(12)(3)`（计数叠加、文本被污染），快照就毁了。
--!
--! 做法：保存时在文件里写一条 **标准 XML 注释** 记录「这份数据已经走到哪一步」，
--! 加载时读出来，已经做过的步骤就不再重做。
--!
--! 用注释而不是属性/自定义标签，是因为注释是标准 XML ——
--! 其它播放器（DanDanPlay、网页播放器…）会直接忽略，不会因为多了个属性报错。
--! 位置放在 `<i>` 后面第一行，这样第一行 `<?xml ...?><i>` 和上游逐字节一致。
--
--! `raw` 不写标签 —— raw 走的是上游那个写出函数（原样保留，不改），
--! 而「没有标签」本来就等价于 raw，所以不需要。
local STAGE_TAG_PREFIX = "uosc_danmaku:stage="

local VALID_STAGES = { raw = true, filtered = true, merged = true }

-- 从弹幕文件内容里读出阶段。读不到（或不是三种之一）就返回 nil = 当 raw。
function M.read_stage(content)
    if type(content) ~= "string" then return nil end
    -- 只看开头：标签是我们自己写在最前面的，没必要全文扫
    local head = content:sub(1, 512)
    local stage = head:match("<!%-%-%s*" .. STAGE_TAG_PREFIX .. "(%a+)%s*%-%->")
    if stage then
        stage = stage:lower()
        if VALID_STAGES[stage] then return stage end
    end
    return nil
end

-- 某个弹幕源身上带的阶段（parse.lua 在加载本地文件时挂上去的）
function M.source_stage(source)
    local stage = source and source.stage
    if type(stage) == "string" then
        stage = stage:lower()
        if VALID_STAGES[stage] then return stage end
    end
    return nil
end

-- 读侧策略：auto = 按标签接着跑；ignore = 忽略标签，一律当原始弹幕
local function resume_policy()
    local v = type(options) == "table" and options.save_danmaku_resume
    v = tostring(v or "auto"):lower()
    if v == "ignore" then return "ignore" end
    return "auto"
end

-- ---------------------------------------------------------------------------
-- 模式
-- ---------------------------------------------------------------------------

-- 归一化 save_danmaku_mode。除了 filtered / merged 一律当 raw（= 不归本模块管），
-- 所以写错值不会让保存失败，只是回到上游行为。大小写不敏感。
function M.normalize_mode(value)
    local mode = tostring(value or "raw"):lower()
    if mode == "filtered" or mode == "merged" then return mode end
    return "raw"
end

-- ---------------------------------------------------------------------------
-- 收集
-- ---------------------------------------------------------------------------

-- 从各个弹幕源现取条目（filtered 用）。filter_blacklist 为 true 时应用黑名单。
-- 结果按时间排序 —— 上游是不定序的（pairs 的顺序不稳定），
-- 所以同一个视频每次导出的行顺序都不一样，连「两次导出 diff 为空」都做不到。
function M.collect(filter_blacklist)
    local d, err = need()
    if not d then return nil, err end

    local list = {}
    for url, source in pairs(d.get_sources()) do
        if not source.blocked and source.data then
            local get_cached_delay = d.make_delay_lookup(source)

            for _, item in ipairs(source.data) do
                local dropped = filter_blacklist
                    and d.is_blacklisted(item.text, d.black_patterns)
                if not dropped then
                    local base_time = item.orig_time or item.time
                    list[#list + 1] = {
                        orig_time = item.orig_time,
                        time = base_time + get_cached_delay(base_time),
                        type = item.type,
                        size = item.size,
                        color = item.color,
                        text = item.text,
                        source = url,
                    }
                end
            end
        end
    end

    table.sort(list, function(a, b) return a.time < b.time end)
    return list
end

-- 渲染快照：合并之后的结果，条目上带 merge_count / merge_mark / merge_scale。
-- pakku.merge 会把标记拼进 text（pakku.lua:1337），所以写出去就是 恭喜(12)。
-- 复制一份再排序，别动缓存本身的顺序。
local function collect_rendered()
    local d, err = need()
    if not d then return nil, err end

    local rendered = d.get_rendered()
    if not rendered or #rendered == 0 then
        return nil, "empty"
    end

    local list = {}
    for i, entry in ipairs(rendered) do list[i] = entry end
    table.sort(list, function(a, b) return a.time < b.time end)
    return list
end

-- ---------------------------------------------------------------------------
-- 从合并标记还原「合并了几条」
--
--! 为什么需要：xml 格式里塞不下 merge_count，所以 merged 快照丢了放大所需的
--! 计数 —— 重新加载后 `(12)` 只是普通文字，字号不会放大，和当时看到的不一样。
--! 好在标记本身就写着数量，反解出来即可。
--
-- 支持本项目写出的三种形式，前缀后缀都认：
--   (12)      默认
--   ₍₁₂₎      mark_subscript=yes
--   [x12]     pakku.js 的另一种风格（留个兼容）
-- ---------------------------------------------------------------------------
local SUB_DIGIT = {}                     -- U+2080..U+2089 -> "0".."9"
for i = 0, 9 do
    SUB_DIGIT[string.char(0xE2, 0x82, 0x80 + i)] = tostring(i)
end
local SUB_LP = string.char(0xE2, 0x82, 0x8D)   -- ₍
local SUB_RP = string.char(0xE2, 0x82, 0x8E)   -- ₎

-- 从一段下标里还原出数字串；不是合法下标就返回 nil
local function subscript_to_number(s)
    local out = {}
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local d = SUB_DIGIT[ch]
        if not d then return nil end
        out[#out + 1] = d
    end
    if #out == 0 then return nil end
    return table.concat(out)
end

-- 从 text 里认出合并标记。返回 count, mark（mark 是原文里的那一段，用于加粗）。
function M.parse_mark(text)
    if type(text) ~= "string" then return nil end

    -- 后缀：(12) / [x12] / ₍₁₂₎
    local n = text:match("%((%d+)%)$")
    if n then local m = "(" .. n .. ")"; return tonumber(n), m end
    n = text:match("%[x(%d+)%]$")
    if n then local m = "[x" .. n .. "]"; return tonumber(n), m end
    if text:sub(-#SUB_RP) == SUB_RP then
        local lp = text:find(SUB_LP, 1, true)
        if lp then
            local digits = subscript_to_number(text:sub(lp + #SUB_LP, -#SUB_RP - 1))
            if digits then
                local m = text:sub(lp)
                return tonumber(digits), m
            end
        end
    end

    -- 前缀：(12) / [x12] / ₍₁₂₎
    n = text:match("^%((%d+)%)")
    if n then local m = "(" .. n .. ")"; return tonumber(n), m end
    n = text:match("^%[x(%d+)%]")
    if n then local m = "[x" .. n .. "]"; return tonumber(n), m end
    if text:sub(1, #SUB_LP) == SUB_LP then
        local rp = text:find(SUB_RP, 1, true)
        if rp then
            local digits = subscript_to_number(text:sub(#SUB_LP + 1, rp - 1))
            if digits then
                local m = text:sub(1, rp)
                return tonumber(digits), m
            end
        end
    end

    return nil
end

-- 给一批「已经合并过」的条目还原 merge_count / merge_mark / merge_scale，
-- 让字号放大能重现。返回还原了几条。
function M.restore_merged(entries, cfg)
    local count = 0
    local built = nil
    for _, e in ipairs(entries) do
        local n, mark = M.parse_mark(e.text)
        if n and n > 1 and mark then
            e.merge_count = n
            e.merge_mark = mark
            -- pakku 路径的字号看 merge_scale；算出来才能重现当时的放大
            if pakku.enlarge_scale then
                if not built then built = pakku.build_config(cfg or options) end
                e.merge_scale = pakku.enlarge_scale(n, built)
            end
            count = count + 1
        end
    end
    return count
end

-- ---------------------------------------------------------------------------
-- 合并前的分流
-- ---------------------------------------------------------------------------

--[[ 把待渲染的弹幕按「来源是否已经合并过」分成两拨：

       pending  = 还没合并过的（要送进 pakku）
       settled  = 已经合并过的（来自 merged 标签的文件，**不能**再合并）

     没有 settled 时 pending 就是原表（数量与顺序都不变），
     所以「没有带标签的文件」这条老路径一行都没变。
]]
function M.split_by_stage(danmakus)
    local stage_of = {}
    local d = deps
    if d then
        for url, source in pairs(d.get_sources()) do
            stage_of[url] = M.source_stage(source)
        end
    end
    if resume_policy() == "ignore" then stage_of = {} end

    -- 先探一遍有没有 settled，避免白建表
    local any = false
    for _, e in ipairs(danmakus) do
        if stage_of[e.source] == "merged" then any = true; break end
    end
    if not any then return danmakus, nil end

    local pending, settled = {}, {}
    for _, e in ipairs(danmakus) do
        if stage_of[e.source] == "merged" then
            settled[#settled + 1] = e
        else
            pending[#pending + 1] = e
        end
    end
    return pending, settled
end

-- 把合并结果和「已合并」的那拨合回去。settled 为空时原样返回 pending。
function M.rejoin(pending, settled)
    if not settled or #settled == 0 then return pending end
    local out = {}
    for _, e in ipairs(pending) do out[#out + 1] = e end
    for _, e in ipairs(settled) do out[#out + 1] = e end
    table.sort(out, function(a, b) return a.time < b.time end)
    return out
end

-- ---------------------------------------------------------------------------
-- 写出
-- ---------------------------------------------------------------------------
local function build_xml(danmakus, stage)
    local xml = { '<?xml version="1.0" encoding="UTF-8"?><i>\n' }
    -- 阶段标签（标准 XML 注释，其它播放器会忽略）
    if stage and stage ~= "raw" then
        xml[#xml + 1] = string.format('<!-- %s%s -->\n', STAGE_TAG_PREFIX, stage)
    end
    for _, d in ipairs(danmakus) do
        local text = d.text or ""
        text = text:gsub("&", "&amp;")
                   :gsub("<", "&lt;")
                   :gsub(">", "&gt;")
                   :gsub("\"", "&quot;")
                   :gsub("'", "&apos;")

        xml[#xml + 1] = string.format('<d p="%s,%s,%s,%s">%s</d>\n',
            d.time, d.type or 1, d.size or 25, d.color or 0xFFFFFF, text)
    end
    xml[#xml + 1] = '</i>'
    return table.concat(xml)
end

-- ---------------------------------------------------------------------------
-- 对外入口
-- ---------------------------------------------------------------------------

--[[ 按模式保存。返回 (handled, result)：

       handled = false  → 这次不该本模块管（raw），调用方继续走上游逻辑
       handled = true   → 本模块已经处理完，result 是成功与否

     之所以返回两个值，是为了让调用方那行 shim 保持极短。
]]
function M.handle(danmaku_out)
    local mode = M.normalize_mode(type(options) == "table" and options.save_danmaku_mode)
    if mode == "raw" then return false end

    local danmakus, err
    if mode == "merged" then
        danmakus, err = collect_rendered()
        if not danmakus then
            if err == "empty" then
                show_message("还没有合并结果可保存，请先让弹幕显示一次", 3)
                msg.warn("save_danmaku_mode=merged，但还没有渲染结果")
            else
                msg.error(tostring(err))
                show_message("保存弹幕失败：" .. tostring(err), 5)
            end
            return true, false
        end
    else
        danmakus, err = M.collect(true)
        if not danmakus then
            msg.error(tostring(err))
            show_message("保存弹幕失败：" .. tostring(err), 5)
            return true, false
        end
    end

    if #danmakus == 0 then
        show_message("弹幕内容为空，无法保存", 3)
        msg.warn("弹幕内容为空，无法保存")
        COMMENTS = {}
        return true, false
    end

    local file = io.open(danmaku_out, "w")
    if not file then
        show_message("无法写入目标 XML 文件", 3)
        msg.info("无法写入目标 XML 文件: " .. danmaku_out)
        return true, false
    end
    file:write(build_xml(danmakus, mode))
    file:close()

    show_message(string.format("已保存 %d 条弹幕（%s）：%s", #danmakus, mode, danmaku_out), 4)
    msg.info(string.format("转换 XML 弹幕成功（%s，%d 条）：%s", mode, #danmakus, danmaku_out))
    return true, true
end

-- 供测试与自检使用
M.build_xml = build_xml

return M
