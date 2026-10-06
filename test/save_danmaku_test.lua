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

-- 让 require("modules/pakku") 能找到：mpv 里是 mpv 自动设的，
-- 裸 luajit 下要自己加。（save_danmaku 需要 pakku.enlarge_scale 来还原放大系数）
package.path = root .. "/portable_config/scripts/uosc_danmaku/?.lua;" .. package.path

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
print("== 阶段标签：写 == 读 ==")
local function xml_of(stage)
    return save.build_xml({ { time = 1, type = 1, size = 25, color = 0, text = "x" } }, stage)
end
check("merged 写进注释", xml_of("merged"):find("<!%-%- uosc_danmaku:stage=merged %-%->") ~= nil, true)
check("filtered 写进注释", xml_of("filtered"):find("stage=filtered") ~= nil, true)
check("raw 不写标签（没有标签就等于 raw）", xml_of("raw"):find("uosc_danmaku:stage") == nil, true)
check("首行与上游一致", xml_of("merged"):sub(1, 41), '<?xml version="1.0" encoding="UTF-8"?><i>')
check("读回 merged", save.read_stage(xml_of("merged")), "merged")
check("读回 filtered", save.read_stage(xml_of("filtered")), "filtered")
check("raw 文件读回 nil", save.read_stage(xml_of("raw")), nil)
check("上游老文件（无标签）读回 nil", save.read_stage('<?xml version="1.0" encoding="UTF-8"?><i>\n<d p="1,1,25,0">a</d>\n</i>'), nil)
check("另一个播放器写的文件读回 nil", save.read_stage('<i><d p="1,1,25,0">a</d></i>'), nil)
check("标签值非法时忽略", save.read_stage("<!-- uosc_danmaku:stage=乱写 -->"), nil)
check("大小写不敏感", save.read_stage("<!-- uosc_danmaku:stage=MERGED -->"), "merged")
check("正文里出现同样的字不算标签", save.read_stage('<i><d p="1,1,25,0">uosc_danmaku:stage=merged</d></i>'), nil)

print()
print("== parse_mark：从正文里反解合并数量 ==")
local function mark(text)
    local n, m = save.parse_mark(text)
    return tostring(n) .. "/" .. tostring(m)
end
check("后缀 (12)", mark("恭喜(12)"), "12/(12)")
check("前缀 (9)", mark("(9)哈哈"), "9/(9)")
check("后缀 [x7]", mark("kksk[x7]"), "7/[x7]")
check("前缀 [x7]", mark("[x7]kksk"), "7/[x7]")
-- 下标 "12" = U+2081 U+2082；括号 = U+208D / U+208E
local SUB = string.char(0xE2, 0x82, 0x8D) .. string.char(0xE2, 0x82, 0x81) .. string.char(0xE2, 0x82, 0x82) .. string.char(0xE2, 0x82, 0x8E)
local n12, m12 = save.parse_mark("恭喜" .. SUB)
check("下标后缀 -> 数量", n12, 12)
check("下标后缀 -> 标记", m12, SUB)
check("下标前缀", (select(1, save.parse_mark(SUB .. "哈哈"))), 12)
check("无标记", mark("普通的弹幕"), "nil/nil")
check("括号里不是数字", mark("恭喜(笑)"), "nil/nil")
check("没有括号", mark("恭喜"), "nil/nil")
check("(1) 也认得（数量=1，调用方会跳过）", mark("恭喜(1)"), "1/(1)")

print()
print("== restore_merged：还原计数与放大 ==")
local restoredList = {
    { time = 1, text = "恭喜(30)", size = 25 },
    { time = 2, text = "普通的弹幕", size = 25 },
    { time = 3, text = "kksk(46)", size = 25 },
}
_G.options = { save_danmaku_mode = "raw", save_danmaku_resume = "auto",
               pakku_enlarge = true, pakku_enlarge_min_count = 5,
               pakku_enlarge_max_scale = 2.0, pakku_enlarge_log_base = 5 }
check("还原了 2 条", save.restore_merged(restoredList, _G.options), 2)
check("(30) -> count 30", restoredList[1].merge_count, 30)
check("(30) -> mark", restoredList[1].merge_mark, "(30)")
check("(30) -> 放大到上限 2 倍", restoredList[1].merge_scale, 2)
check("无标记的那条不动", restoredList[2].merge_count, nil)
check("(46) -> count 46", restoredList[3].merge_count, 46)

print()
print("== split_by_stage / rejoin：已合并的来源不参与合并 ==")
-- 先记住原来的注入，测完要还原（后面还有 filtered/merged 的用例）
local real_deps = {
    get_sources       = function() return SOURCES end,
    get_rendered      = function() return RENDERED end,
    black_patterns    = { "BLOCKED" },
    is_blacklisted    = function(text) return text == "BLOCKED" end,
    make_delay_lookup = function() return function() return 0 end end,
}
local srcs = {
    ["local_merged.xml"] = { stage = "merged", data = {} },
    ["online"] = { data = {} },
}
save.set_deps({
    get_sources       = function() return srcs end,
    get_rendered      = function() return RENDERED end,
    black_patterns    = { "BLOCKED" },
    is_blacklisted    = function(text) return text == "BLOCKED" end,
    make_delay_lookup = function() return function() return 0 end end,
})
local function entry(src, t, text) return { source = src, time = t, text = text } end
local all = { entry("online", 2, "b"), entry("local_merged.xml", 1, "a(12)"), entry("online", 3, "c") }
_G.options.save_danmaku_resume = "auto"
local pending, settled = save.split_by_stage(all)
check("pending 只留未合并的", #pending, 2)
check("settled 拿到已合并的", #settled, 1)
check("settled 的是那条", settled[1].text, "a(12)")
local joined = save.rejoin(pending, settled)
check("合回去按时间排序", joined[1].text, "a(12)")
check("合回去条数不变", #joined, 3)

print()
print("== 没有 merged 来源时，split 必须原样返回（老路径不变）==")
local plain = { entry("online", 1, "a"), entry("online", 2, "b") }
local p2, s2 = save.split_by_stage(plain)
check("pending 是原表本身", p2 == plain, true)
check("settled 为 nil", s2, nil)
check("rejoin 原样返回", save.rejoin(p2, s2) == plain, true)

print()
print("== resume=ignore 时忽略标签，一律从头处理 ==")
_G.options.save_danmaku_resume = "ignore"
local p3, s3 = save.split_by_stage(all)
check("没有 settled", s3, nil)
check("pending 是全部", #p3, 3)
_G.options.save_danmaku_resume = "auto"

-- 还原真实注入，后面的用例还要用
save.set_deps(real_deps)

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
