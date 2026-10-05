--[[ 自动选择（danmaku_auto_select）单元测试

    跑法（在仓库根目录，或任意位置都行）：
        luajit test/auto_select_test.lua

    为什么要把这些测试留在仓库里：这套逻辑改动频繁，而它出错的代价是
    「用户按一次按钮，弹幕不出现」——从日志上很难看出原因。实际开发过程中
    下面这些用例抓到过两个自己写出来的 bug：
      · 「从 hint 抠数字」把搜索 hint 里的年份 2022 当成了集数
      · 收尾守卫同时写在 finish() 和 do_final_update() 两处，
        导致 do_final_update 一进去就 return，自动选择被彻底废掉
]]

-- 定位仓库根目录（本文件在 <root>/test/ 下）
local script_dir = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local root = script_dir:gsub("[/\\]test$", "")
if root == script_dir then root = "." end
local MENU = root .. "/portable_config/scripts/uosc_danmaku/modules/menu.lua"
local UTILS = root .. "/portable_config/scripts/uosc_danmaku/modules/utils.lua"

-- ---------- 极简测试框架 ----------
local pass, fail = 0, 0
local failures = {}
local function check(name, got, want)
    if got == want then
        pass = pass + 1
        print("  ok   " .. name)
    else
        fail = fail + 1
        failures[#failures + 1] = name
        print(string.format("  FAIL %s\n         得到 %s\n         期望 %s",
            name, tostring(got), tostring(want)))
    end
end

-- ---------- 桩件 ----------
local state = {
    filename = "x", media_title = "", path = "/mnt/v/x.mkv",
    time = 100, parse_title_ret = { "BOCCHI THE ROCK", 1, "01" },
    auto_select = true, uosc = false, input_loaded = true,
}
local timeouts = {}
local open_menu_calls = 0
local msg_info = {}
local msg_error = {}

_G.mp = {
    get_property = function(p)
        if p == "filename/no-ext" then return state.filename end
        if p == "media-title" then return state.media_title end
        if p == "path" then return state.path end
        return nil
    end,
    get_time = function() return state.time end,
    get_script_name = function() return "uosc_danmaku" end,
    commandv = function() end,
    command = function() end,
    add_timeout = function(_, f) timeouts[#timeouts + 1] = f end,
}
_G.msg = setmetatable({}, { __index = function(_, k)
    if k == "info" then return function(s) msg_info[#msg_info + 1] = tostring(s) end end
    if k == "error" then return function(s) msg_error[#msg_error + 1] = tostring(s) end end
    return function() end
end })
_G.trace_osd = function() end
_G.show_message = function() end
_G.brief_error = function(e) return tostring(e) end
_G.is_protocol = function(p) return type(p) == "string" and p:match("^%a[%w+.-]*://") ~= nil end
_G.url_decode = function(s) return s end
_G.get_str_width = function() return 0 end
_G.jaro_winkler = function(a, b) return a == b and 1 or 0 end
_G.utf8_len = function(s) return #s end
_G.http_error_hint = function(e) return tostring(e) end
_G.get_episode_number = function() return nil end
_G.parse_title = function() return state.parse_title_ret[1], state.parse_title_ret[2], state.parse_title_ret[3] end
_G.input = { terminate = function() end }
_G.update_menu_uosc = function() end
_G.open_menu_select = function() open_menu_calls = open_menu_calls + 1 end
_G.get_episodes = function() end
_G.utils = {
    parse_json = function() return { animes = {
        { animeTitle = "孤独摇滚！", bangumiId = 1, typeDescription = "动漫 | 2022 | 来源：b 站" },
    } } end,
    format_json = function() return "[]" end,
}
-- options 每次读取都要反映最新的 state.auto_select
_G.options = setmetatable({}, { __index = function(_, k)
    if k == "danmaku_auto_select" then return state.auto_select end
    return nil
end })
_G.uosc_available = state.uosc
_G.input_loaded = state.input_loaded
_G.latest_menu_anime = nil
_G.request_cancelled = false

-- ---------- 从真实源码里抽出被测代码 ----------
local function slice(path, from_marker, to_marker, returns)
    local fh = io.open(path)
    if not fh then error("找不到 " .. path) end
    local src = fh:read("*a"); fh:close()
    local a = src:find(from_marker, 1, true)
    local b = src:find(to_marker, 1, true)
    if not a or not b then error("在 " .. path .. " 里找不到标记: " .. from_marker) end
    return assert(load(src:sub(a, b - 1) .. "\nreturn " .. returns))
end

-- get_media_filename 单独抽出来（在 utils.lua 里）
local get_media_filename = slice(UTILS, "function get_media_filename",
    "-- 获取播放文件标题信息", "get_media_filename")()

-- menu.lua 的自动选择主体（要一直取到去重函数，它们在 run_menu_item 之后）
local menu_block = slice(MENU, "local AUTO_SELECT_TYPE_RULES",
    "-- 如果 latest_menu_anime 中存在首项为加载占位",
    "hint_episode_number, item_command_kind, looks_like_episode_list, pick_auto_item, auto_select_should_skip")
local hint_num, item_kind, looks_ep, pick, should_skip = menu_block()

-- make_handle_response 单独抽（依赖上面那一段，所以得一起加载）
local make_handle_response = slice(MENU, "local AUTO_SELECT_TYPE_RULES",
    "-- 打开番剧数据匹配菜单", "make_handle_response")()

-- ---------- 造菜单项 ----------
local function epItem(n, hint, title)
    return { title = title or ("第" .. n .. "话"), hint = hint or n,
        value = { "script-message-to", "uosc_danmaku", "load-danmaku", "T", "第" .. n .. "话", 1000 + n, "srv" },
        selectable = true }
end
local function animeItem(t, y)
    return { title = t, hint = "动漫 | " .. y .. " | 来源：b 站",
        value = { "script-message-to", "uosc_danmaku", "search-episodes-event", t, 42, "srv" },
        selectable = true }
end
local navItem = { title = "↩️ 返回搜索结果",
    value = { "script-message-to", "uosc_danmaku", "open-latest-menu-anime", "[]" }, selectable = true }

-- =====================================================================
print("== get_media_filename：网盘串流要认 media-title ==")
state.path, state.media_title = "network://x/FILEID", "[DMG&VCB-Studio] BOCCHI THE ROCK! [01][Ma10p_1080p].mkv"
check("协议路径取 media-title", get_media_filename(), "[DMG&VCB-Studio] BOCCHI THE ROCK! [01][Ma10p_1080p].mkv")
state.media_title = "BOCCHI THE ROCK [01] | tv"
check("剥掉「| 类型」后缀", get_media_filename(), "BOCCHI THE ROCK [01]")
state.media_title = ""
state.filename = "FILEID"
check("media-title 为空时回退 filename", get_media_filename(), "FILEID")
state.path, state.filename = "/mnt/v/Show S01E04.mkv", "Show S01E04"
check("本地文件用 filename/no-ext", get_media_filename(), "Show S01E04")

print()
print("== hint_episode_number ==")
check("数字", hint_num(12), 12)
check("字符串数字", hint_num("12"), 12)
check("第12话", hint_num("第12话"), 12)
check("EP12", hint_num("EP12"), 12)
check("小数 12.5", hint_num("12.5"), 12.5)
check("无数字", hint_num("总集篇"), nil)
check("搜索 hint 里的年份不算集数", hint_num("动漫 | 2022 | 来源：b 站"), nil)
check("电影 hint", hint_num("电影 | 2025 | 来源：爱奇艺"), nil)
check("nil", hint_num(nil), nil)

print()
print("== item_command_kind ==")
check("剧集项", item_kind(epItem(1)), "episode")
check("搜索项", item_kind(animeItem("x", 2022)), "anime")
check("导航项", item_kind(navItem), "nav")
check("无 value", item_kind({ value = "", selectable = true }), nil)

print()
print("== looks_like_episode_list ==")
local eps = {}; for i = 1, 43 do eps[i] = epItem(i) end
check("43 条剧集", looks_ep(eps), true)
local epsStr = {}; for i = 1, 43 do epsStr[i] = epItem(i, "第" .. i .. "话") end
check("hint 是「第N话」也算剧集", looks_ep(epsStr), true)
local epsBad = {}; for i = 1, 43 do epsBad[i] = epItem(i, "特别篇") end
check("hint 认不出但命令是 load-danmaku 仍算剧集", looks_ep(epsBad), true)
check("2 条搜索候选不是剧集", looks_ep({ animeItem("A", 2022), animeItem("B", 2025) }), false)
check("年份不会让搜索列表被误判", looks_ep({ animeItem("A", 2022), animeItem("B", 2025) }), false)

print()
print("== pick_auto_item ==")
local list = { navItem }
for i = 1, 42 do list[#list + 1] = epItem(i) end
local it, why = pick(list)
check("剧集列表：跳过导航项", it and it.title, "第1话")
check("剧集列表：集数精确匹配", why, "集数精确匹配第 1 集")

local it2, why2 = pick({ navItem })
check("全是导航项：不瞎选", it2, nil)
check("全是导航项：无理由", why2, nil)

state.parse_title_ret = { "BOCCHI THE ROCK", nil, nil }
local it3, why3 = pick({ navItem, epItem(1), epItem(2) })
check("没集数时取第一集（不是导航项）", it3 and it3.title, "第1话")
check("没集数时的理由", why3, "文件名里没有集数，取第一集")

state.parse_title_ret = { "BOCCHI THE ROCK", 1, "01" }
local it4, why4 = pick({ navItem, animeItem("孤独摇滚！", 2022), animeItem("孤独摇滚（上）", 2025) })
check("搜索列表：导航项不参与打分", it4 and it4.title, "孤独摇滚！")
check("搜索列表：走打分", why4 and why4:match("^评分") ~= nil, true)

local it5 = pick({ { title = "孤独摇滚！", hint = "动漫 | 2022 | 来源：b 站",
    value = { "some-unknown-cmd" }, selectable = true } })
check("value 形状不认识时退化为全部打分", it5 and it5.title, "孤独摇滚！")

print()
print("== 连按去重 ==")
state.time = 1000
check("首次放行", should_skip("搜索", "Q", animeItem("A", 2022)), false)
state.time = 1000.05
check("窗口内重复拦截", should_skip("搜索", "Q", animeItem("A", 2022)), true)
state.time = 1000.05
check("换标题放行", should_skip("搜索", "Q", animeItem("B", 2022)), false)
state.time = 1000.10
check("来回点也拦截（A→B→A）", should_skip("搜索", "Q", animeItem("A", 2022)), true)
state.time = 1010
check("窗口外放行", should_skip("搜索", "Q", animeItem("A", 2022)), false)

print()
print("== 收尾只跑一次 + 异常不再静默 ==")
local function newCtx(n)
    local order = {}; for i = 1, n do order[i] = "s" .. i end
    return { remaining = { n = n }, server_order = order, server_items = {},
        server_notes = {}, seen = {}, total_servers = n, total_count = 0,
        first_opened = { val = false }, query = "BOCCHI THE ROCK",
        menu_type = "m", menu_title = "T", footnote = "", menu_cmd = nil }
end
local function count_picks(fn)
    msg_info = {}
    local n = 0
    local h = make_handle_response
    fn(h)
    for _, s in ipairs(msg_info) do if s:match("^自动选择：") then n = n + 1 end end
    return n
end

state.auto_select = true
local h1 = make_handle_response(newCtx(1))
msg_info = {}
h1("s1", nil, '{"animes":[]}')
h1("s1", nil, '{"animes":[]}')
local pickedN = 0
for _, s in ipairs(msg_info) do if s:match("^自动选择：") then pickedN = pickedN + 1 end end
check("回调重复触发时只收尾一次", pickedN, 1)

msg_error = {}
local h2 = make_handle_response(newCtx(1))
h2("s1", "boom", nil)
check("服务器全失败时不误选", (function()
    local n = 0; for _, s in ipairs(msg_info) do if s:match("^自动选择：") then n = n + 1 end end; return n
end)(), 1)

print()
print("== 开自动选择时不弹「先到先显示」菜单 ==")
state.auto_select = true
open_menu_calls, timeouts = 0, {}
local h3 = make_handle_response(newCtx(2))
h3("s1", nil, '{"animes":[]}')
for _, f in ipairs(timeouts) do f() end
h3("s2", nil, '{"animes":[]}')
for _, f in ipairs(timeouts) do f() end
check("全程不弹菜单", open_menu_calls, 0)

state.auto_select = false
open_menu_calls, timeouts = 0, {}
local h4 = make_handle_response(newCtx(2))
h4("s1", nil, '{"animes":[]}')
for _, f in ipairs(timeouts) do f() end
check("关掉自动选择后仍保留该功能", open_menu_calls, 1)
state.auto_select = true

-- =====================================================================
print()
print(string.rep("-", 56))
print(string.format("通过 %d，失败 %d", pass, fail))
if fail > 0 then
    print("失败用例：")
    for _, n in ipairs(failures) do print("  · " .. n) end
end
os.exit(fail == 0 and 0 or 1)
