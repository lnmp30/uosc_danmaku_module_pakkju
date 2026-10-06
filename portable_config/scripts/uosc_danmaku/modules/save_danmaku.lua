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
-- 写出
-- ---------------------------------------------------------------------------
local function build_xml(danmakus)
    local xml = { '<?xml version="1.0" encoding="UTF-8"?><i>\n' }
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
    file:write(build_xml(danmakus))
    file:close()

    show_message(string.format("已保存 %d 条弹幕（%s）：%s", #danmakus, mode, danmaku_out), 4)
    msg.info(string.format("转换 XML 弹幕成功（%s，%d 条）：%s", mode, #danmakus, danmaku_out))
    return true, true
end

-- 供测试与自检使用
M.build_xml = build_xml

return M
