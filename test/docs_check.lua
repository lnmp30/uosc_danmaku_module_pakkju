-- 文档一致性总检查：选项覆盖 / 默认值 / 函数名 / 锚点 / 表格
local function read(p) local f=io.open(p); if not f then error("找不到 "..p) end local s=f:read("*a"); f:close(); return s end
local opts_src = read("portable_config/scripts/uosc_danmaku/modules/options.lua")
local readme = read("readme.md")
local project = read("project.md")
local pass, fail = 0, 0
local function ok(n) pass=pass+1; print("  ok   "..n) end
local function bad(n, detail) fail=fail+1; print("  FAIL "..n); if detail then print("         "..detail) end end

-- ---------- 1) 选项名双向核对 ----------
local names, seen = {}, {}
for line in opts_src:gmatch("[^\n]+") do
    local name = line:match("^%s*([%a_][%w_]*)%s*=%s*[^=]")
    if name and not line:match("^%s*%-%-") and name ~= "options" and name ~= "opt" then
        if not seen[name] then seen[name]=true; names[#names+1]=name end
    end
end
table.sort(names)

print("== 1. 选项覆盖（options.lua -> readme）==")
local miss = {}
for _, n in ipairs(names) do
    if not readme:find("`" .. n .. "`", 1, true) then miss[#miss+1] = n end
end
if #miss == 0 then ok(string.format("全部 %d 个选项都在 readme 里有说明", #names))
else bad("有选项没写进 readme", table.concat(miss, ", ")) end

print("== 2. 反向：readme 里的选项名是否都存在 ==")
local known = {}
for _, n in ipairs(names) do known[n] = true end
local bogus = {}
for name in readme:gmatch("`(([%a_][%w_]*))`") do
    if (name:match("^pakku_") or name:match("^danmaku_") or name:match("^merge_")
        or name:match("^save_danmaku") or name:match("^autoload") or name:match("^auto_"))
        and not known[name] then bogus[name] = true end
end
local bl = {}; for n in pairs(bogus) do bl[#bl+1]=n end; table.sort(bl)
if #bl == 0 then ok("没有杜撰的选项名") else bad("readme 里有不存在的选项名", table.concat(bl, ", ")) end

-- ---------- 3) 默认值逐值比对 ----------
print("== 3. readme 里写的默认值 vs options.lua ==")
local defaults = {}
for line in opts_src:gmatch("[^\n]+") do
    local name, val = line:match("^%s*([%a_][%w_]*)%s*=%s*(.-),%s*$")
    if name and not line:match("^%s*%-%-") and name ~= "options" then
        defaults[name] = val:gsub("^%s+",""):gsub("%s+$","")
    end
end
local function cells_of(line)
    local body = line:match("^%s*|(.*)|%s*$") or line
    body = body:gsub("\\|", "\1")
    local c = {}
    for x in (body .. "|"):gmatch("([^|]*)|") do c[#c+1] = x:gsub("\1","|"):gsub("^%s+",""):gsub("%s+$","") end
    return c
end
local claimed = {}
for line in readme:gmatch("[^\n]+") do
    if line:match("^%s*|") then
        local c = cells_of(line)
        local name = c[1] and c[1]:match("^`([%a_][%w_]*)`$")
        if name and c[2] and not claimed[name] then
            claimed[name] = c[2]:gsub("^⚠️%s*",""):gsub("^%s+","")
        end
    end
end
local function claim_norm(s)
    local inner = s:match("^`(.-)`$") or s:match("^`(.-)`") or s:match("^(.-)%s*[（(]") or s
    if inner == '""' then return "" end
    return inner
end
local function code_norm(v)
    if v == "true" then return "yes" elseif v == "false" then return "no" end
    if v:match('^".*"$') then return v:match('^"(.*)"$') end
    return v
end
local inconsistent, checked = {}, 0
for name, val in pairs(defaults) do
    local raw = claimed[name]
    if raw and not (raw:match("^见") or raw:match("^内置") or raw:match("^同左")) then
        checked = checked + 1
        if code_norm(val) ~= claim_norm(raw) then
            inconsistent[#inconsistent+1] = string.format("%s 代码=%s readme=%s", name, val, raw)
        end
    end
end
table.sort(inconsistent)
if #inconsistent == 0 then ok(string.format("可比对的 %d 个默认值全部一致", checked))
else bad("默认值不一致", table.concat(inconsistent, " | ")) end

-- ---------- 4) 函数名存在性 ----------
print("== 4. 文档引用的函数名是否存在 ==")
local base = "portable_config/scripts/uosc_danmaku/"
local blob = {}
for _, f in ipairs({"main.lua","modules/pakku.lua","modules/menu.lua","modules/utils.lua",
    "modules/parse.lua","modules/options.lua","modules/guess.lua","modules/render.lua",
    "modules/save_danmaku.lua","apis/dandanplay.lua","apis/extra.lua"}) do
    local o, s = pcall(read, base..f); if o then blob[#blob+1] = s end
end
for _, f in ipairs({"test/auto_select_test.lua","test/save_danmaku_test.lua"}) do
    local o, s = pcall(read, f); if o then blob[#blob+1] = s end
end
local all = table.concat(blob, "\n")
local IGNORE = { make_mark_meta = true, kksk = true, jaro_winkler = true }
local fnmiss, fnchecked = {}, 0
for _, doc in ipairs({{"readme.md", readme}, {"project.md", project}}) do
    local dn, text = doc[1], doc[2]
    local seen2 = {}
    for name in text:gmatch("`([%a_][%w_]*)%(") do
        if not seen2[name] and not IGNORE[name] then
            seen2[name] = true; fnchecked = fnchecked + 1
            if not (all:find("%f[%w_]function%s+"..name.."%f[%W]")
                or all:find("%f[%w_]"..name.."%s*=%s*function")
                or all:find("%f[%w_]"..name.."%s*%(")) then
                fnmiss[#fnmiss+1] = dn..": "..name.."()"
            end
        end
    end
    for name in text:gmatch("`M%.([%a_][%w_]*)") do
        local k = "M."..name
        if not seen2[k] then
            seen2[k] = true; fnchecked = fnchecked + 1
            if not all:find("function%s+M%."..name.."%f[%W]") then fnmiss[#fnmiss+1] = dn..": M."..name end
        end
    end
end
table.sort(fnmiss)
if #fnmiss == 0 then ok(string.format("%d 个函数名全部真实存在", fnchecked))
else bad("引用了不存在的函数", table.concat(fnmiss, ", ")) end

-- ---------- 5) 锚点 ----------
print("== 5. readme 目录锚点 ==")
local CJK = { "：","（","）","、","，","。","「","」","《","》","！","？","；","·","—","…","“","”","‘","’" }
local function slug(t)
    local s = t:lower()
    s = s:gsub("[%p]", function(c) if c=="_" or c=="-" then return c end return "" end)
    for _, p in ipairs(CJK) do s = s:gsub(p:gsub("%W","%%%0"), "") end
    return s:gsub(" ", "-")
end
local anchors, used = {}, {}
for line in readme:gmatch("[^\n]+") do
    local t = line:match("^#+%s+(.+)$")
    if t then
        local a = slug(t)
        if used[a] then used[a]=used[a]+1; a=a.."-"..used[a] else used[a]=1 end
        anchors[a] = true
    end
end
local badlink = {}
for l in readme:gmatch("%]%(#([^%)]+)%)") do if not anchors[l] then badlink[#badlink+1]=l end end
if #badlink == 0 then ok("所有目录链接有效") else bad("锚点失效", table.concat(badlink, ", ")) end

-- ---------- 6) 表格列数 ----------
--! 注意必须逐行遍历（含空行）：空行是表格的边界，用 gmatch("[^\n]+") 跳过空行
--! 会让两张相邻的表格被当成一张，报出假的列数不一致。
print("== 6. Markdown 表格列数自洽 ==")
for _, doc in ipairs({{"readme.md", readme}, {"project.md", project}}) do
    local dn, text = doc[1], doc[2]
    local badrows, intable, hdr = 0, false, 0
    local lineno = 0
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        lineno = lineno + 1
        if line:match("^%s*|") then
            local probe = line:gsub("\\|", "\1")
            local cols = 0
            for _ in probe:gmatch("|") do cols = cols + 1 end
            if not intable then intable=true; hdr=cols
            elseif probe:match("^%s*|%s*[-: ]+%|") then hdr=cols
            elseif cols ~= hdr then
                badrows = badrows + 1
                if badrows <= 3 then
                    print(string.format("         %s:%d 列数 %d != 表头 %d：%s",
                        dn, lineno, cols, hdr, line:sub(1, 70)))
                end
            end
        else intable = false end
    end
    if badrows == 0 then ok(dn.." 表格结构 OK") else bad(dn.." 有 "..badrows.." 处列数不一致") end
end

-- ---------- 7) 章节编号连续 ----------
print("== 7. project.md 章节编号 ==")
local nums = {}
for line in project:gmatch("[^\n]+") do
    local n = line:match("^## (%d+)%.")
    if n then nums[#nums+1] = tonumber(n) end
end
local gaps = {}
for i, n in ipairs(nums) do if n ~= i then gaps[#gaps+1] = string.format("第 %d 个是 %d", i, n) end end
if #gaps == 0 then ok(string.format("§1..§%d 连续无缺号", #nums))
else bad("章节编号不连续", table.concat(gaps, ", ")) end

print()
print(string.rep("-", 56))
print(string.format("通过 %d，失败 %d", pass, fail))
os.exit(fail == 0 and 0 or 1)
