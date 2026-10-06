--[[ 保存弹幕（save_danmaku_mode）的单元测试

    跑法（在仓库根目录）：
        luajit test/save_danmaku_test.lua

    被测的是本项目新加的 modules/save_danmaku.lua（filtered / merged 两种模式）。
    raw 模式**不归它管** —— 那条路走 parse.lua 里上游的原样实现，
    所以这里还要验一件事：raw 时 handle() 必须返回 handled=false，
    把活儿让回给上游。

    输出文件写到系统临时目录：不污染工作区，而且某些受限环境只允许子进程写
    工作区根 / TEMP（写工作区子目录会被拒）。
]]

local script_dir = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local root = script_dir:gsub("[/\\]test$", "")
if root == script_dir then root = "." end
local MOD = root .. "/portable_config/scripts/uosc_danmaku/modules/save_danmaku.lua"
local TMP = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp")
    .. "/dsh_save_danmaku_test.xml"

-- ---------- 测试框架 ----------
local pass, fail, failures = 0, 0, {}
local function check(name, got, want)
    if got == want then pass = pass + 1; print("  ok   " .. name)
    else
        fail = fail + 1; failures[#failures+1] = name
        print(string.format("  FAIL %s\n         得到 %s\n         期望 %s", name, tostring(got), tostring(want)))
    end
end

-- ---------- 桩件 ----------
local messages = {}
_G.msg = setmetatable({}, { __index = function() return function() end end })
_G.show_message = function(s) messages[#messages+1] = tostring(s) end
_G.COMMENTS = nil

local SOURCES = {
    ["s1"] = { data = {
        { time = 3, type = 1, size = 25, color = 0xFFFFFF, text = "third" },
        { time = 1, type = 1, size = 25, color = 0xFFFFFF, text = "first" },
    } },
    ["s2"] = { data = {
        { time = 2, type = 1, size = 25, color = 0xFFFFFF, text = "BLOCKED" },
        { time = 4, type = 1, size = 25, color = 0xFFFFFF, text = "A<B&C\"D'E" },
    } },
    ["s3"] = { blocked = true, data = {
        { time = 0, type = 1, size = 25, color = 0xFFFFFF, text = "blocked-source" },
    } },
}
local RENDERED = {}

_G.options = { save_danmaku_mode = "raw" }

-- 被测模块是自包含的，只需要这两个桩：require("mp.msg") 和 os.getenv
local save = assert(loadfile(MOD))()
save.set_deps({
    get_sources       = function() return SOURCES end,
    get_rendered      = function() return RENDERED end,
    black_patterns    = { "BLOCKED" },
    is_blacklisted    = function(text) return text == "BLOCKED" end,
    make_delay_lookup = function() return function() return 0 end end,
})

-- ---------- 读结果 ----------
local function texts_of()
    local f = io.open(TMP); if not f then return nil end
    local s = f:read("*a"); f:close()
    local out = {}
    for t in s:gmatch("<d p=\"[^\"]*\">(.-)</d>") do out[#out+1] = t end
    return out
end
local function times_of()
    local f = io.open(TMP); if not f then return nil end
    local s = f:read("*a"); f:close()
    local out = {}
    for t in s:gmatch("<d p=\"([^,]*),") do out[#out+1] = t end
    return out
end

-- =====================================================================
print("== normalize_mode ==")
check("raw 原样",            save.normalize_mode("raw"), "raw")
check("filtered",            save.normalize_mode("filtered"), "filtered")
check("merged",              save.normalize_mode("merged"), "merged")
check("大写也认",            save.normalize_mode("MERGED"), "merged")
check("乱写的回退 raw",      save.normalize_mode("什么鬼"), "raw")
check("nil 回退 raw",        save.normalize_mode(nil), "raw")
check("空串回退 raw",        save.normalize_mode(""), "raw")

print()
print("== raw 不归本模块管（必须让回上游）==")
messages = {}
_G.options.save_danmaku_mode = "raw"
local handled, result = save.handle(TMP)
check("handled = false", handled, false)
check("没有产生任何提示", #messages, 0)

print()
print("== filtered：去掉黑名单命中的 ==")
messages = {}
_G.options.save_danmaku_mode = "filtered"
handled, result = save.handle(TMP)
check("handled = true", handled, true)
check("保存成功", result, true)
local t = texts_of()
check("条数 = 3（s3 屏蔽、BLOCKED 过滤）", #t, 3)
check("黑名单条目已消失", (table.concat(t, "|")):find("BLOCKED") == nil, true)
check("按时间排序", table.concat(times_of(), ","), "1,3,4")
check("XML 转义", t[3], "A&lt;B&amp;C&quot;D&apos;E")

print()
print("== merged：用渲染快照，文本保留 (12) 标记 ==")
RENDERED = {
    { time = 5, type = 1, size = 25, color = 0xFFFFFF, text = "merged-later" },
    { time = 1, type = 1, size = 50, color = 0xFF0000, text = "恭喜(12)", merge_count = 12, merge_mark = "(12)" },
}
messages = {}
_G.options.save_danmaku_mode = "merged"
handled, result = save.handle(TMP)
check("保存成功", result, true)
t = texts_of()
check("条数 = 2（快照的条数）", #t, 2)
check("按时间排序", table.concat(times_of(), ","), "1,5")
check("标记保留", t[1], "恭喜(12)")
check("第二条", t[2], "merged-later")

print()
print("== merged：快照为空时不该瞎存 ==")
RENDERED = {}
messages = {}
check("返回 false", (select(2, save.handle(TMP))), false)
check("有提示", #messages > 0, true)
if #messages > 0 then print("   提示：" .. messages[1]) end

print()
print("== 全空：所有源都被屏蔽 ==")
messages = {}
local keep = SOURCES
_G.DANMAKU = nil
save.set_deps({
    get_sources       = function() return { ["s3"] = keep["s3"] } end,
    get_rendered      = function() return RENDERED end,
    black_patterns    = { "BLOCKED" },
    is_blacklisted    = function(text) return text == "BLOCKED" end,
    make_delay_lookup = function() return function() return 0 end end,
})
_G.options.save_danmaku_mode = "filtered"
check("返回 false", (select(2, save.handle(TMP))), false)
check("有提示", #messages > 0, true)

print()
print("== 没注入依赖时不崩，而是明确报错 ==")
local fresh = assert(loadfile(MOD))()      -- 全新的模块实例，deps 为空
messages = {}
_G.options.save_danmaku_mode = "filtered"
local h2, r2 = fresh.handle(TMP)
check("handled = true（不把锅甩给上游）", h2, true)
check("返回 false", r2, false)
check("有提示", #messages > 0, true)

os.remove(TMP)

print()
print(string.rep("-", 56))
print(string.format("通过 %d，失败 %d", pass, fail))
if fail > 0 then
    print("失败用例：")
    for _, n in ipairs(failures) do print("  · " .. n) end
end
os.exit(fail == 0 and 0 or 1)
