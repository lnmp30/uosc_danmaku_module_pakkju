--[[
    pakku.lua —— pakku.js 弹幕合并算法的 Lua 移植

    原始算法来自 https://github.com/xmcp/pakku.js 的 similarity/repo-cpp/src/main.cpp
    以及 core/combine_worker.ts、core/post_combine.ts。

    相比 uosc_danmaku 自带的 merge_duplicate_danmaku()（只做“文本完全相同”的合并），
    这里额外引入了四种判定，只要有任意一种命中就会被归入同一个簇：

      1. 文本预处理     去尾部标点、全角/半角归一、合并多余空格、自定义替换规则
      2. 字符频率编辑距离 O(n) 近似 Levenshtein，容忍错别字、多字少字
      3. 拼音距离        内置 6763 个汉字的拼音字典，容忍谐音替代
      4. bigram 余弦相似度 捕获局部结构，容忍语气词、语序差异
      5. 滑动窗口聚类    只在 threshold 秒的窗口内比较，窗口随时间向前滑动
      6. 密度调控        按合并数量放大字号；按屏幕显示密度整体缩小或丢弃弹幕

    对外接口（cfg 既可以是 uosc_danmaku 的全局 options 表，也可以是自带
    pakku_ 前缀的普通 table；两种键名都认）：

        local pakku = require("modules/pakku")

        local merged, stats = pakku.merge(danmakus, options)

        -- merged[i] 在原有字段之外新增：
        --   merge_count  该簇合并了多少条原始弹幕
        --   merge_scale  字号放大系数（1 表示不放大，密度缩小时会小于 1）
        --   merge_reason 命中的判定："identical"/"edit"/"pinyin"/"cosine"/"orig"
        --   merge_mark   标记本体，如 "₍₁₂₎"（供渲染层加粗用，未标记时为 ""）
        --   text         合并后带标记的文本（如 "恭喜₍₁₂₎"）

    同时导出若干纯函数，方便单独验证：

        pakku.normalize(text, cfg)
        pakku.edit_distance(s1, s2)
        pakku.pinyin_distance(s1, s2)
        pakku.cosine_similarity(s1, s2)
        pakku.dispval(text, fontsize)
]]

local M = {}

-- 让本模块既能跑在 mpv 里，也能用裸 luajit 做单测
local msg
do
    local ok, m = pcall(require, "mp.msg")
    if ok and type(m) == "table" then
        msg = m
    else
        local function nop() end
        msg = { info = nop, verbose = nop, warn = nop, error = nop, debug = nop }
    end
end

local parse_json
do
    local ok, mu = pcall(require, "mp.utils")
    if ok and type(mu) == "table" and type(mu.parse_json) == "function" then
        parse_json = mu.parse_json
    end
end

----------------------------------------------------------------------
-- 0. UTF-8 小工具
----------------------------------------------------------------------

-- 一个 UTF-8 字符：首字节 + 若干续字节
local UTF8_CHAR = "[%z\1-\127\194-\244][\128-\191]*"

-- 把字符串切成 UTF-8 字符数组
local function utf8_char_list(s)
    local t, n = {}, 0
    for c in s:gmatch(UTF8_CHAR) do
        n = n + 1
        t[n] = c
    end
    return t, n
end

-- 取一个 UTF-8 字符的码点（用于判断 CJK 区间）
local function utf8_codepoint(c)
    local b1 = c:byte(1) or 0
    if b1 < 0x80 then return b1 end
    local b2 = c:byte(2) or 0
    if b1 < 0xE0 then return (b1 - 0xC0) * 0x40 + (b2 - 0x80) end
    local b3 = c:byte(3) or 0
    if b1 < 0xF0 then
        return ((b1 - 0xE0) * 0x40 + (b2 - 0x80)) * 0x40 + (b3 - 0x80)
    end
    local b4 = c:byte(4) or 0
    return (((b1 - 0xF0) * 0x40 + (b2 - 0x80)) * 0x40 + (b3 - 0x80)) * 0x40 + (b4 - 0x80)
end

local function utf8_count(s)
    local n = 0
    for _ in s:gmatch(UTF8_CHAR) do n = n + 1 end
    return n
end

local function is_cjk_codepoint(cp)
    return (cp >= 0x3000 and cp <= 0x9FFF) or (cp >= 0xFF00 and cp <= 0xFFEF)
end

----------------------------------------------------------------------
-- 1. 拼音字典
----------------------------------------------------------------------
--
-- 数据来自 pakku.js 的 similarity/repo-cpp/src/pinyin_dict.txt。原表是
-- “汉字 -> {声母索引, 韵母索引}”，拼音完全相同的汉字共享同一对数值
-- （全表共 398 组，覆盖 6763 个汉字）。
--
-- 为了不写 6763 行 Lua 表项，这里按“编码 -> 汉字串”做反向压缩存储，
-- 首次用到时再展开成 PINYIN_DICT[汉字] = 声母索引 * 64 + 韵母索引。
-- 展开后的编码与原表语义完全一致：比较时把 first 和（非 0 的）second
-- 当作两个 token 丢进频率表，于是“好看”与“好看啊”、“在”与“再”
-- 在拼音层面就能对上。
local PINYIN_SRC = [[
1,0:啊阿锕
2,0:埃挨哎唉哀皑癌蔼矮艾碍爱隘诶捱嗳嗌嫒瑷暧砹锿霭
3,0:鞍氨安俺按暗岸胺案谙埯揞犴庵桉铵鹌顸黯
4,0:肮昂盎
5,0:凹敖熬翱袄傲奥懊澳坳拗嗷噢岙廒遨媪骜聱螯鏊鳌鏖
6,1:芭捌扒叭吧笆八疤巴拔跋靶把耙坝霸罢爸茇菝萆捭岜灞杷钯粑鲅魃
6,2:白柏百摆佰败拜稗薜掰鞴
6,3:斑班搬扳般颁板版扮拌伴瓣半办绊阪坂豳钣瘢癍舨
6,4:邦帮梆榜膀绑棒磅蚌镑傍谤蒡螃
6,5:苞胞包褒雹保堡饱宝抱报暴豹鲍爆勹葆宀孢煲鸨褓趵龅
6,7:剥薄玻菠播拨钵波博勃搏铂箔伯帛舶脖膊渤泊驳亳蕃啵饽檗擘礴钹鹁簸跛
6,8:杯碑悲卑北辈背贝钡倍狈备惫焙被孛陂邶埤蓓呗怫悖碚鹎褙鐾
6,9:奔苯本笨畚坌锛
6,10:崩绷甭泵蹦迸唪嘣甏
6,11:逼鼻比鄙笔彼碧蓖蔽毕毙毖币庇痹闭敝弊必辟壁臂避陛匕仳俾芘荜荸吡哔狴庳愎滗濞弼妣婢嬖璧贲畀铋秕裨筚箅篦舭襞跸髀
6,12:鞭边编贬扁便变卞辨辩辫遍匾弁苄忭汴缏煸砭碥稹窆蝙笾鳊
6,13:标彪膘表婊骠飑飙飚灬镖镳瘭裱鳔
6,14:鳖憋别瘪蹩鳘
6,15:彬斌濒滨宾摈傧浜缤玢殡膑镔髌鬓
6,16:兵冰柄丙秉饼炳病并禀邴摒绠枋槟燹
6,17:捕卜哺补埠不布步簿部怖拊卟逋瓿晡钚醭
18,1:擦嚓礤
18,2:猜裁材才财睬踩采彩菜蔡
18,3:餐参蚕残惭惨灿骖璨粲黪
18,4:苍舱仓沧藏伧
18,5:操糙槽曹草艹嘈漕螬艚
18,19:厕策侧册测刂帻恻
18,10:层蹭噌
20,1:插叉茬茶查碴搽察岔差诧猹馇汊姹杈楂槎檫钗锸镲衩
20,2:拆柴豺侪茈瘥虿龇
20,3:搀掺蝉馋谗缠铲产阐颤冁谄谶蒇廛忏潺澶孱羼婵嬗骣觇禅镡裣蟾躔
20,4:昌猖场尝常长偿肠厂敞畅唱倡伥鬯苌菖徜怅惝阊娼嫦昶氅鲳
20,5:超抄钞朝嘲潮巢吵炒怊绉晁耖
20,19:车扯撤掣彻澈坼屮砗
20,9:郴臣辰尘晨忱沉陈趁衬称谌抻嗔宸琛榇肜胂碜龀
20,10:撑城橙成呈乘程惩澄诚承逞骋秤埕嵊徵浈枨柽樘晟塍瞠铖裎蛏酲
20,21:吃痴持匙池迟弛驰耻齿侈尺赤翅斥炽傺墀芪茌搋叱哧啻嗤彳饬沲媸敕胝眙眵鸱瘛褫蚩螭笞篪豉踅踟魑
20,22:充冲虫崇宠茺忡憧铳艟
20,23:抽酬畴踌稠愁筹仇绸瞅丑俦圳帱惆溴妯瘳雠鲋
20,17:臭初出橱厨躇锄雏滁除楚础储矗搐触处亍刍憷绌杵楮樗蜍蹰黜
20,24:揣川穿椽传船喘串掾舛惴遄巛氚钏镩舡
20,25:疮窗幢床闯创怆
20,26:吹炊捶锤垂陲棰槌
20,27:春椿醇唇淳纯蠢促莼沌肫朐鹑蝽
20,7:戳绰蔟辶辍镞踔龊
18,21:疵茨磁雌辞慈瓷词此刺赐次荠呲嵯鹚螅糍趑
18,22:聪葱囱匆从丛偬苁淙骢琮璁枞
18,17:凑粗醋簇猝殂蹙
18,24:蹿篡窜汆撺昕爨
18,26:摧崔催脆瘁粹淬翠萃悴璀榱隹
18,27:村存寸磋忖皴
18,7:撮搓措挫错厝脞锉矬痤鹾蹉躜
28,1:搭达答瘩打大耷哒嗒怛妲疸褡笪靼鞑
28,2:呆歹傣戴带殆代贷袋待逮怠埭甙呔岱迨逯骀绐玳黛
28,3:耽担丹单郸掸胆旦氮但惮淡诞弹蛋亻儋卩萏啖澹檐殚赕眈瘅聃箪
28,4:当挡党荡档谠凼菪宕砀铛裆
28,5:刀捣蹈倒岛祷导到稻悼道盗叨啁忉洮氘焘忑纛
28,19:德得的锝
28,10:蹬灯登等瞪凳邓噔嶝戥磴镫簦
28,11:堤低滴迪敌笛狄涤翟嫡抵底地蒂第帝弟递缔氐籴诋谛邸坻莜荻嘀娣柢棣觌砥碲睇镝羝骶
28,12:颠掂滇碘点典靛垫电佃甸店惦奠淀殿丶阽坫埝巅玷癜癫簟踮
28,13:碉叼雕凋刁掉吊钓调轺铞蜩粜貂
28,14:跌爹碟蝶迭谍叠佚垤堞揲喋渫轶牒瓞褶耋蹀鲽鳎
28,16:丁盯叮钉顶鼎锭定订丢仃啶玎腚碇町铤疔耵酊
28,22:东冬董懂动栋侗恫冻洞垌咚岽峒夂氡胨胴硐鸫
28,23:兜抖斗陡豆逗痘蔸钭窦窬蚪篼酡
28,17:都督毒犊独读堵睹赌杜镀肚度渡妒芏嘟渎椟橐牍蠹笃髑黩
28,24:端短锻段断缎彖椴煅簖
28,26:堆兑队对怼憝碓
28,27:墩吨蹲敦顿囤钝盾遁炖砘礅盹镦趸
28,7:掇哆多夺垛躲朵跺舵剁惰堕咄哚缍柁铎裰踱
19,0:蛾峨鹅俄额讹娥恶厄扼遏鄂饿噩谔垩垭苊莪萼呃愕屙婀轭曷腭硪锇锷鹗颚鳄
9,0:恩蒽摁唔嗯
29,0:而儿耳尔饵洱二贰迩珥铒鸸鲕
30,1:发罚筏伐乏阀法珐垡砝
30,3:藩帆番翻樊矾钒繁凡烦反返范贩犯饭泛蘩幡犭梵攵燔畈蹯
30,4:坊芳方肪房防妨仿访纺放匚邡彷钫舫鲂
30,8:菲非啡飞肥匪诽吠肺废沸费芾狒悱淝妃绋绯榧腓斐扉祓砩镄痱蜚篚翡霏鲱
30,9:芬酚吩氛分纷坟焚汾粉奋份忿愤粪偾瀵棼愍鲼鼢
30,10:丰封枫蜂峰锋风疯烽逢冯缝讽奉凤俸酆葑沣砜
30,17:佛否夫敷肤孵扶拂辐幅氟符伏俘服浮涪福袱弗甫抚辅俯釜斧脯腑府腐赴副覆赋复傅付阜父腹负富讣附妇缚咐匐凫郛芙苻茯莩菔呋幞滏艴孚驸绂桴赙黻黼罘稃馥虍蚨蜉蝠蝮麸趺跗鳆
31,1:噶嘎蛤尬呷尕尜旮钆
31,2:该改概钙盖溉丐陔垓戤赅胲
31,3:干甘杆柑竿肝赶感秆敢赣坩苷尴擀泔淦澉绀橄旰矸疳酐
31,4:冈刚钢缸肛纲岗港戆罡颃筻
31,22:杠工攻功恭龚供躬公宫弓巩汞拱贡共蕻廾咣珙肱蚣蛩觥
31,5:篙皋高膏羔糕搞镐稿告睾诰郜蒿藁缟槔槁杲锆
31,19:哥歌搁戈鸽胳疙割革葛格阁隔铬个各鬲仡哿塥嗝纥搿膈硌铪镉袼颌虼舸骼髂
31,8:给
31,9:根跟亘茛哏艮
31,10:耕更庚羹埂耿梗哽赓鲠
31,23:钩勾沟苟狗垢构购够佝诟岣遘媾缑觏彀鸲笱篝鞲
31,17:辜菇咕箍估沽孤姑鼓古蛊骨谷股故顾固雇嘏诂菰哌崮汩梏轱牯牿胍臌毂瞽罟钴锢瓠鸪鹄痼蛄酤觚鲴骰鹘
31,32:刮瓜剐寡挂褂卦诖呱栝鸹
31,33:乖拐怪哙
31,24:棺关官冠观管馆罐惯灌贯倌莞掼涫盥鹳鳏
31,25:光广逛犷桄胱疒
31,26:瑰规圭硅归龟闺轨鬼诡癸桂柜跪贵刽匦刿庋宄妫桧炅晷皈簋鲑鳜
31,27:辊滚棍丨衮绲磙鲧
31,7:锅郭国果裹过馘蠃埚掴呙囗帼崞猓椁虢锞聒蜮蜾蝈
34,1:哈
34,2:骸孩海氦亥害骇咴嗨颏醢
34,3:酣憨邯韩含涵寒函喊罕翰撼捍旱憾悍焊汗汉邗菡撖阚瀚晗焓颔蚶鼾
34,9:夯痕很狠恨
34,4:杭航沆绗珩桁
34,5:壕嚎豪毫郝好耗号浩薅嗥嚆濠灏昊皓颢蚝
34,19:呵喝荷菏核禾和何合盒貉阂河涸赫褐鹤贺诃劾壑藿嗑嗬阖盍蚵翮
34,8:嘿黑
34,10:哼亨横衡恒訇蘅
34,22:轰哄烘虹鸿洪宏弘红黉讧荭薨闳泓
34,23:喉侯猴吼厚候后堠後逅瘊篌糇鲎骺
34,17:呼乎忽瑚壶葫胡蝴狐糊湖弧虎唬护互沪户冱唿囫岵猢怙惚浒滹琥槲轷觳烀煳戽扈祜鹕鹱笏醐斛
34,32:花哗华猾滑画划化话劐浍骅桦铧稞
34,33:槐徊怀淮坏还踝
34,24:欢环桓缓换患唤痪豢焕涣宦幻郇奂垸擐圜洹浣漶寰逭缳锾鲩鬟
34,25:荒慌黄磺蝗簧皇凰惶煌晃幌恍谎隍徨湟潢遑璜肓癀蟥篁鳇
34,26:灰挥辉徽恢蛔回毁悔慧卉惠晦贿秽会烩汇讳诲绘诙茴荟蕙哕喙隳洄彗缋珲晖恚虺蟪麾
34,27:荤昏婚魂浑混诨馄阍溷缗
34,7:豁活伙火获或惑霍货祸攉嚯夥钬锪镬耠蠖
35,11:击圾基机畸稽积箕肌饥迹激讥鸡姬绩缉吉极棘辑籍集及急疾汲即嫉级挤几脊己蓟技冀季伎祭剂悸济寄寂计记既忌际妓继纪居丌乩剞佶佴脔墼芨芰萁蒺蕺掎叽咭哜唧岌嵴洎彐屐骥畿玑楫殛戟戢赍觊犄齑矶羁嵇稷瘠瘵虮笈笄暨跻跽霁鲚鲫髻麂
35,36:嘉枷夹佳家加荚颊贾甲钾假稼价架驾嫁伽郏拮岬浃迦珈戛胛恝铗镓痂蛱笳袈跏
35,12:歼监坚尖笺间煎兼肩艰奸缄茧检柬碱硷拣捡简俭剪减荐槛鉴践贱见键箭件健舰剑饯渐溅涧建僭谏谫菅蒹搛囝湔蹇謇缣枧柙楗戋戬牮犍毽腱睑锏鹣裥笕箴翦趼踺鲣鞯
35,37:僵姜将浆江疆蒋桨奖讲匠酱降茳洚绛缰犟礓耩糨豇
35,13:蕉椒礁焦胶交郊浇骄娇嚼搅铰矫侥脚狡角饺缴绞剿教酵轿较叫佼僬茭挢噍峤徼姣纟敫皎鹪蛟醮跤鲛
35,14:窖揭接皆秸街阶截劫节桔杰捷睫竭洁结解姐戒藉芥界借介疥诫届偈讦诘喈嗟獬婕孑桀獒碣锴疖袷颉蚧羯鲒骱髫
35,15:巾筋斤金今津襟紧锦仅谨进靳晋禁近烬浸尽卺荩堇噤馑廑妗缙瑾槿赆觐钅锓衿矜
35,16:劲荆兢茎睛晶鲸京惊精粳经井警景颈静境敬镜径痉靖竟竞净刭儆阱菁獍憬泾迳弪婧肼胫腈旌
35,38:炯窘冂迥扃
35,39:揪究纠玖韭久灸九酒厩救旧臼舅咎就疚僦啾阄柩桕鹫赳鬏
35,40:鞠拘狙疽驹菊局咀矩举沮聚拒据巨具距踞锯俱句惧炬剧倨讵苣苴莒掬遽屦琚枸椐榘榉橘犋飓钜锔窭裾趄醵踽龃雎鞫
35,41:捐鹃娟倦眷卷绢鄄狷涓桊蠲锩镌隽
35,42:撅攫抉掘倔爵觉决诀绝厥劂谲矍蕨噘崛獗孓珏桷橛爝镢蹶觖
35,43:均菌钧军君峻俊竣浚郡骏捃狻皲筠麇
44,1:喀咖卡佧咔胩
44,19:咯坷苛柯棵磕颗科壳咳可渴克刻客课岢恪溘骒缂珂轲氪瞌钶疴窠蝌髁
44,2:开揩楷凯慨剀垲蒈忾恺铠锎
44,3:刊堪勘坎砍看侃凵莰莶戡龛瞰
44,4:康慷糠扛抗亢炕坑伉闶钪
44,5:考拷烤靠尻栲犒铐
44,9:肯啃垦恳垠裉颀
44,10:吭忐铿
44,22:空恐孔控倥崆箜
44,23:抠口扣寇芤蔻叩眍筘
44,17:枯哭窟苦酷库裤刳堀喾绔骷
44,32:夸垮挎跨胯侉
44,33:块筷侩快蒯郐蒉狯脍
44,24:宽款髋
44,25:匡筐狂框矿眶旷况诓诳邝圹夼哐纩贶
44,26:亏盔岿窥葵奎魁傀馈愧溃馗匮夔隗揆喹喟悝愦阕逵暌睽聩蝰篑臾跬
44,27:坤昆捆困悃阃琨锟醌鲲髡
44,7:括扩廓阔蛞
45,1:垃拉喇蜡腊辣啦剌摺邋旯砬瘌
45,2:莱来赖崃徕涞濑赉睐铼癞籁
45,3:蓝婪栏拦篮阑兰澜谰揽览懒缆烂滥啉岚懔漤榄斓罱镧褴
45,4:琅榔狼廊郎朗浪莨蒗啷阆锒稂螂
45,5:捞劳牢老佬姥酪烙涝唠崂栳铑铹痨醪
45,19:勒乐肋仂叻嘞泐鳓
45,8:雷镭蕾磊累儡垒擂类泪羸诔荽咧漯嫘缧檑耒酹
45,16:棱冷拎玲菱零龄铃伶羚凌灵陵岭领另令酃塄苓呤囹泠绫柃棂瓴聆蛉翎鲮
45,10:楞愣
45,11:厘梨犁黎篱狸离漓理李里鲤礼莉荔吏栗丽厉励砾历利傈例俐痢立粒沥隶力璃哩俪俚郦坜苈莅蓠藜捩呖唳喱猁溧澧逦娌嫠骊缡珞枥栎轹戾砺詈罹锂鹂疠疬蛎蜊蠡笠篥粝醴跞雳鲡鳢黧
45,12:俩联莲连镰廉怜涟帘敛脸链恋炼练挛蔹奁潋濂娈琏楝殓臁膦裢蠊鲢
45,37:粮凉梁粱良两辆量晾亮谅墚椋踉靓魉
45,13:撩聊僚疗燎寥辽潦了撂镣廖料蓼尥嘹獠寮缭钌鹩耢
45,14:列裂烈劣猎冽埒洌趔躐鬣
45,15:琳林磷霖临邻鳞淋凛赁吝蔺嶙廪遴檩辚瞵粼躏麟
45,39:溜琉榴硫馏留刘瘤流柳六抡偻蒌泖浏遛骝绺旒熘锍镏鹨鎏
45,22:龙聋咙笼窿隆垄拢陇弄垅茏泷珑栊胧砻癃
45,23:楼娄搂篓漏陋喽嵝镂瘘耧蝼髅
45,17:芦卢颅庐炉掳卤虏鲁麓碌露路赂鹿潞禄录陆戮垆摅撸噜泸渌漉璐栌橹轳辂辘氇胪镥鸬鹭簏舻鲈
45,40:驴吕铝侣旅履屡缕虑氯律率滤绿捋闾榈膂稆褛
45,24:峦孪滦卵乱栾鸾銮
45,42:掠略锊
45,27:轮伦仑沦纶论囵
45,7:萝螺罗逻锣箩骡裸落洛骆络倮荦摞猡泺椤脶镙瘰雒
46,1:妈麻玛码蚂马骂嘛吗唛犸嬷杩麽
46,2:埋买麦卖迈脉劢荬咪霾
46,3:瞒馒蛮满蔓曼慢漫谩墁幔缦熳镘颟螨鳗鞔
46,4:芒茫盲忙莽邙漭朦硭蟒
46,10:氓萌蒙檬盟锰猛梦孟勐甍瞢懵礞虻蜢蠓艋艨黾
46,13:猫苗描瞄藐秒渺庙妙喵邈缈缪杪淼眇鹋蜱
46,5:茅锚毛矛铆卯茂冒帽貌贸侔袤勖茆峁瑁昴牦耄旄懋瞀蛑蝥蟊髦
46,19:么
46,8:玫枚梅酶霉煤没眉媒镁每美昧寐妹媚坶莓嵋猸浼湄楣镅鹛袂魅
46,9:门闷们扪玟焖懑钔
46,11:眯醚靡糜迷谜弥米秘觅泌蜜密幂芈冖谧蘼嘧猕獯汨宓弭脒敉糸縻麋
46,12:棉眠绵冕免勉娩缅面沔湎腼眄
46,14:蔑灭咩蠛篾
46,15:民抿皿敏悯闽苠岷闵泯珉
46,16:明螟鸣铭名命冥茗溟暝瞑酩
46,39:谬
46,7:摸摹蘑模膜磨摩魔抹末莫墨默沫漠寞陌谟茉蓦馍嫫镆秣瘼耱蟆貊貘
46,23:谋牟某厶哞婺眸鍪
46,17:拇牡亩姆母墓暮幕募慕木目睦牧穆仫苜呒沐毪钼
47,1:拿哪呐钠那娜纳内捺肭镎衲箬
47,2:氖乃奶耐奈鼐艿萘柰
47,3:南男难囊喃囡楠腩蝻赧
47,5:挠脑恼闹孬垴猱瑙硇铙蛲
47,19:淖呢讷
47,8:馁
47,9:嫩能枘恁
47,11:妮霓倪泥尼拟你匿腻逆溺伲坭猊怩滠昵旎祢慝睨铌鲵
47,12:蔫拈年碾撵捻念廿辇黏鲇鲶
47,37:娘酿
47,13:鸟尿茑嬲脲袅
47,14:捏聂孽啮镊镍涅乜陧蘖嗫肀颞臬蹑
47,15:您柠
47,16:狞凝宁拧泞佞蓥咛甯聍
47,39:牛扭钮纽狃忸妞蚴
47,22:脓浓农侬
47,17:奴努怒呶帑弩胬孥驽
47,40:女恧钕衄
47,24:暖
47,42:虐疟
47,7:挪懦糯诺傩搦喏锘
23,0:哦欧鸥殴藕呕偶沤怄瓯耦
48,1:啪趴爬帕怕琶葩筢
48,2:拍排牌徘湃派俳蒎
48,3:攀潘盘磐盼畔判叛爿泮袢襻蟠蹒
48,4:乓庞旁耪胖滂逄
48,5:抛咆刨炮袍跑泡匏狍庖脬疱
48,8:呸胚培裴赔陪配佩沛掊辔帔淠旆锫醅霈
48,9:喷盆湓
48,10:砰抨烹澎彭蓬棚硼篷膨朋鹏捧碰坯堋嘭怦蟛
48,11:砒霹批披劈琵毗啤脾疲皮匹痞僻屁譬丕陴邳郫圮鼙擗噼庀媲纰枇甓睥罴铍痦癖疋蚍貔
48,12:篇偏片骗谝骈犏胼褊翩蹁
48,13:飘漂瓢票剽嘌嫖缥殍瞟螵
48,14:撇瞥丿苤氕
48,15:拼频贫品聘拚姘嫔榀牝颦
48,16:乒坪苹萍平凭瓶评屏俜娉枰鲆
48,7:坡泼颇婆破魄迫粕叵鄱溥珀钋钷皤笸
48,23:剖裒踣
48,17:扑铺仆莆葡菩蒲埔朴圃普浦谱曝瀑匍噗濮璞氆镤镨蹼
49,11:期欺栖戚妻七凄漆柒沏其棋奇歧畦崎脐齐旗祈祁骑起岂乞企启契砌器气迄弃汽泣讫亟亓圻芑萋葺嘁屺岐汔淇骐绮琪琦杞桤槭欹祺憩碛蛴蜞綦綮趿蹊鳍麒
49,36:掐恰洽葜
49,12:牵扦钎铅千迁签仟谦乾黔钱钳前潜遣浅谴堑嵌欠歉佥阡芊芡荨掮岍悭慊骞搴褰缱椠肷愆钤虔箝
49,37:枪呛腔羌墙蔷强抢嫱樯戗炝锖锵镪襁蜣羟跫跄
49,13:橇锹敲悄桥瞧乔侨巧鞘撬翘峭俏窍劁诮谯荞愀憔缲樵毳硗跷鞒
49,14:切茄且怯窃郄唼惬妾挈锲箧
49,15:钦侵亲秦琴勤芹擒禽寝沁芩蓁蕲揿吣嗪噙溱檎螓衾
49,16:青轻氢倾卿清擎晴氰情顷请庆倩苘圊檠磬蜻罄箐謦鲭黥
49,38:琼穷邛茕穹筇銎
49,39:秋丘邱球求囚酋泅俅氽巯艽犰湫逑遒楸赇鸠虬蚯蝤裘糗鳅鼽
49,40:趋区蛆曲躯屈驱渠取娶龋趣去诎劬蕖蘧岖衢阒璩觑氍祛磲癯蛐蠼麴瞿黢
49,41:圈颧权醛泉全痊拳犬券劝诠荃獾悛绻辁畎铨蜷筌鬈
49,42:缺炔瘸却鹊榷确雀阙悫
49,43:裙群逡
50,3:然燃冉染苒髯
50,4:瓤壤攘嚷让禳穰
50,5:饶扰绕荛娆桡
50,7:惹若弱
50,19:热偌
50,9:壬仁人忍韧任认刃妊纫仞荏葚饪轫稔衽
50,10:扔仍
50,21:日
50,22:戎茸蓉荣融熔溶容绒冗嵘狨缛榕蝾
50,23:揉柔肉糅蹂鞣
50,17:茹蠕儒孺如辱乳汝入褥蓐薷嚅洳溽濡铷襦颥
50,24:软阮朊
50,26:蕊瑞锐芮蕤睿蚋
50,27:闰润
51,1:撒洒萨卅仨挲飒
51,2:腮鳃塞赛噻
51,3:三叁伞散彡馓氵毵糁霰
51,4:桑嗓丧搡磉颡
51,5:搔骚扫嫂埽臊瘙鳋
51,19:瑟色涩啬铩铯穑
51,9:森
51,10:僧
52,1:莎砂杀刹沙纱傻啥煞脎歃痧裟霎鲨
52,2:筛晒酾
52,3:珊苫杉山删煽衫闪陕擅赡膳善汕扇缮剡讪鄯埏芟潸姗骟膻钐疝蟮舢跚鳝
52,4:墒伤商赏晌上尚裳垧绱殇熵觞
52,5:梢捎稍烧芍勺韶少哨邵绍劭苕潲蛸笤筲艄
52,19:奢赊蛇舌舍赦摄射慑涉社设厍佘猞畲麝
52,9:砷申呻伸身深娠绅神沈审婶甚肾慎渗诜谂吲哂渖椹矧蜃
52,10:声生甥牲升绳省盛剩胜圣丞渑媵眚笙
52,21:师失狮施湿诗尸虱十石拾时什食蚀实识史矢使屎驶始式示士世柿事拭誓逝势是嗜噬适仕侍释饰氏市恃室视试谥埘莳蓍弑唑饣轼耆贳炻礻铈铊螫舐筮豕鲥鲺
52,23:收手首守寿授售受瘦兽扌狩绶艏
52,17:蔬枢梳殊抒输叔舒淑疏书赎孰熟薯暑曙署蜀黍鼠属术述树束戍竖墅庶数漱恕倏塾菽忄沭涑澍姝纾毹腧殳镯秫鹬
52,32:刷耍唰涮
52,33:摔衰甩帅蟀
52,24:栓拴闩
52,25:霜双爽孀
52,26:谁水睡税
52,27:吮瞬顺舜恂
52,7:说硕朔烁蒴搠嗍濯妁槊铄
51,21:斯撕嘶思私司丝死肆寺嗣四伺似饲巳厮俟兕菥咝汜泗澌姒驷缌祀祠锶鸶耜蛳笥
51,22:松耸怂颂送宋讼诵凇菘崧嵩忪悚淞竦
51,23:搜艘擞嗽叟嗖嗾馊溲飕瞍锼螋
51,17:苏酥俗素速粟僳塑溯宿诉肃夙谡蔌嗉愫簌觫稣
51,24:酸蒜算
51,26:虽隋随绥髓碎岁穗遂隧祟蓑冫谇濉邃燧眭睢
51,27:孙损笋荪狲飧榫跣隼
51,7:梭唆缩琐索锁所唢嗦娑桫睃羧
53,1:塌他它她塔獭挞蹋踏闼溻遢榻沓
53,2:胎苔抬台泰酞太态汰邰薹肽炱钛跆鲐
53,3:坍摊贪瘫滩坛檀痰潭谭谈坦毯袒碳探叹炭郯蕈昙钽锬覃
53,4:汤塘搪堂棠膛唐糖傥饧溏瑭铴镗耥螗螳羰醣倘躺淌趟烫
53,5:掏涛滔绦萄桃逃淘陶讨套挑鼗啕韬饕
53,19:特
53,10:藤腾疼誊滕
53,11:梯剔踢锑提题蹄啼体替嚏惕涕剃屉荑悌逖绨缇鹈裼醍
53,12:天添填田甜恬舔腆掭忝阗殄畋钿蚺
53,13:条迢眺跳佻祧铫窕龆鲦
53,14:贴铁帖萜餮
53,16:厅听烃汀廷停亭庭挺艇莛葶婷梃蜓霆
53,22:通桐酮瞳同铜彤童桶捅筒统痛佟僮仝茼嗵恸潼砼
53,23:偷投头透亠
53,17:凸秃突图徒途涂屠土吐兔堍荼菟钍酴
53,24:湍团疃
53,26:推颓腿蜕褪退忒煺
53,27:吞屯臀饨暾豚窀
53,7:拖托脱鸵陀驮驼椭妥拓唾乇佗坨庹沱柝砣箨舄跎鼍
54,1:挖哇蛙洼娃瓦袜佤娲腽
54,2:歪外
54,3:豌弯湾玩顽丸烷完碗挽晚皖惋宛婉万腕剜芄苋菀纨绾琬脘畹蜿箢
54,4:汪王亡枉网往旺望忘妄罔尢惘辋魍
54,8:威巍微危韦违桅围唯惟为潍维苇萎委伟伪尾纬未蔚味畏胃喂魏位渭谓尉慰卫倭偎诿隈葳薇帏帷崴嵬猥猬闱沩洧涠逶娓玮韪軎炜煨熨痿艉鲔
54,9:瘟温蚊文闻纹吻稳紊问刎愠阌汶璺韫殁雯
54,10:嗡翁瓮蓊蕹
54,55:挝蜗涡窝我斡卧握沃莴幄渥杌肟龌
54,17:巫呜钨乌污诬屋无芜梧吾吴毋武五捂午舞伍侮坞戊雾晤物勿务悟误兀仵阢邬圬芴庑怃忤浯寤迕妩骛牾焐鹉鹜蜈鋈鼯
56,11:昔熙析西硒矽晰嘻吸锡牺稀息希悉膝夕惜熄烯溪汐犀檄袭席习媳喜铣洗系隙戏细僖兮隰郗茜葸蓰奚唏徙饩阋浠淅屣嬉玺樨曦觋欷熹禊禧钸皙穸蜥蟋舾羲粞翕醯鼷
56,36:瞎虾匣霞辖暇峡侠狭下厦夏吓掀葭嗄狎遐瑕硖瘕罅黠
56,12:锨先仙鲜纤咸贤衔舷闲涎弦嫌显险现献县腺馅羡宪陷限线冼藓岘猃暹娴氙祆鹇痫蚬筅籼酰跹
56,37:相厢镶香箱襄湘乡翔祥详想响享项巷橡像向象芗葙饷庠骧缃蟓鲞飨
56,13:萧硝霄削哮嚣销消宵淆晓小孝校肖啸笑效哓咻崤潇逍骁绡枭枵筱箫魈
56,14:楔些歇蝎鞋协挟携邪斜胁谐写械卸蟹懈泄泻谢屑偕亵勰燮薤撷廨瀣邂绁缬榭榍歙躞
56,15:薪芯锌欣辛新忻心信衅囟馨莘歆铽鑫
56,16:星腥猩惺兴刑型形邢行醒幸杏性姓陉荇荥擤悻硎
56,38:兄凶胸匈汹雄熊芎
56,39:休修羞朽嗅锈秀袖绣莠岫馐庥鸺貅髹
56,40:墟戌需虚嘘须徐许蓄酗叙旭序畜恤絮婿绪续讴诩圩蓿怵洫溆顼栩煦砉盱胥糈醑
56,41:轩喧宣悬旋玄选癣眩绚儇谖萱揎馔泫洵渲漩璇楦暄炫煊碹铉镟痃
56,42:靴薛学穴雪血噱泶鳕谑
56,43:勋熏循旬询寻驯巡殉汛训讯逊迅巽埙荀薰峋徇浔曛窨醺鲟
57,1:压押鸦鸭呀丫芽牙蚜崖衙涯雅哑亚讶伢揠吖岈迓娅琊桠氩砑睚痖
57,3:焉咽阉烟淹盐严研蜒岩延言颜阎炎沿奄掩眼衍演艳堰燕厌砚雁唁彦焰宴谚验厣靥赝俨偃兖讠谳郾鄢芫菸崦恹闫阏洇湮滟妍嫣琰晏胭腌焱罨筵酽魇餍鼹
57,4:殃央鸯秧杨扬佯疡羊洋阳氧仰痒养样漾徉怏泱炀烊恙蛘鞅
57,5:邀腰妖瑶摇尧遥窑谣姚咬舀药要耀夭爻吆崾徭瀹幺珧杳曜肴鹞窈繇鳐
57,19:椰噎耶爷野冶也页掖业叶曳腋夜液谒邺揶馀晔烨铘
57,11:一壹医揖铱依伊衣颐夷遗移仪胰疑沂宜姨彝椅蚁倚已乙矣以艺抑易邑屹亿役臆逸肄疫亦裔意毅忆义益溢诣议谊译异翼翌绎刈劓佾诒圪圯埸懿苡薏弈奕挹弋呓咦咿噫峄嶷猗饴怿怡悒漪迤驿缢殪贻旖熠钇镒镱痍瘗癔翊衤蜴舣羿翳酏黟
57,15:茵荫因殷音阴姻吟银淫寅饮尹引隐印胤鄞堙茚喑狺夤氤铟瘾蚓霪龈
57,16:英樱婴鹰应缨莹萤营荧蝇迎赢盈影颖硬映嬴郢茔莺萦撄嘤膺滢潆瀛瑛璎楹鹦瘿颍罂
57,55:哟唷
57,22:拥佣臃痈庸雍踊蛹咏泳涌永恿勇用俑壅墉慵邕镛甬鳙饔
57,23:幽优悠忧尤由邮铀犹油游酉有友右佑釉诱又幼卣攸侑莸呦囿宥柚猷牖铕疣蝣鱿黝鼬
57,40:迂淤于盂榆虞愚舆余俞逾鱼愉渝渔隅予娱雨与屿禹宇语羽玉域芋郁吁遇喻峪御愈欲狱育誉浴寓裕预豫驭禺毓伛俣谀谕萸蓣揄喁圄圉嵛狳饫庾阈妪妤纡瑜昱觎腴欤於煜燠聿钰鹆瘐瘀窳蝓竽舁雩龉
57,41:鸳渊冤元垣袁原援辕园员圆猿源缘远苑愿怨院塬沅媛瑗橼爰眢鸢螈鼋
57,42:曰约越跃钥岳粤月悦阅龠樾刖钺
57,43:耘云郧匀陨允运蕴酝晕韵孕郓芸狁恽纭殒昀氲
58,1:匝砸杂拶咂
58,2:栽哉灾宰载再在咱崽甾
58,3:攒暂赞瓒昝簪糌趱錾
58,4:赃脏葬奘戕臧
58,5:遭糟凿藻枣早澡蚤躁噪造皂灶燥唣缫
58,19:责择则泽仄赜啧迮昃笮箦舴
58,8:贼
58,9:怎谮
58,10:增憎曾赠缯甑罾锃
59,1:扎喳渣札轧铡闸眨栅榨咋乍炸诈揸吒咤哳怍砟痄蚱齄
59,2:摘斋宅窄债寨砦
59,3:瞻毡詹粘沾盏斩辗崭展蘸栈占战站湛绽谵搌旃
59,4:樟章彰漳张掌涨杖丈帐账仗胀瘴障仉鄣幛嶂獐嫜璋蟑
59,5:招昭找沼赵照罩兆肇召爪诏棹钊笊
59,19:遮折哲蛰辙者锗蔗这浙谪陬柘辄磔鹧褚蜇赭
59,9:珍斟真甄砧臻贞针侦枕疹诊震振镇阵缜桢榛轸赈胗朕祯畛鸩
59,10:蒸挣睁征狰争怔整拯正政帧症郑证诤峥钲铮筝
59,21:芝枝支吱蜘知肢脂汁之织职直植殖执值侄址指止趾只旨纸志挚掷至致置帜峙制智秩稚质炙痔滞治窒卮陟郅埴芷摭帙忮彘咫骘栉枳栀桎轵轾攴贽膣祉祗黹雉鸷痣蛭絷酯跖踬踯豸觯
59,22:中盅忠钟衷终种肿重仲众冢锺螽舂舯踵
59,23:舟周州洲诌粥轴肘帚咒皱宙昼骤啄着倜诹荮鬻纣胄碡籀舳酎鲷
59,17:珠株蛛朱猪诸诛逐竹烛煮拄瞩嘱主著柱助蛀贮铸筑住注祝驻伫侏邾苎茱洙渚潴驺杼槠橥炷铢疰瘃蚰竺箸翥躅麈
59,32:抓
59,33:拽
59,24:专砖转撰赚篆抟啭颛
59,25:桩庄装妆撞壮状丬
59,26:椎锥追赘坠缀萑骓缒
59,27:谆准
59,7:捉拙卓桌琢茁酌灼浊倬诼廴蕞擢啜浞涿杓焯禚斫
58,21:兹咨资姿滋淄孜紫仔籽滓子自渍字谘嵫姊孳缁梓辎赀恣眦锱秭耔笫粢觜訾鲻髭
58,22:鬃棕踪宗综总纵腙粽
58,23:邹走奏揍鄹鲰
58,17:租足卒族祖诅阻组俎菹啐徂驵蹴
58,24:钻纂攥缵
58,26:嘴醉最罪
58,27:尊遵撙樽鳟
58,7:昨左佐柞做作坐座阝阼胙祚酢
18,23:薮楱辏腠
47,4:攮哝囔馕曩
55,0:喔
28,36:嗲
20,33:嘬膪踹
18,9:岑涔
28,39:铥
47,23:耨
30,23:缶
6,36:髟]]

local PINYIN_DICT = nil
local PINYIN_GROUP_COUNT = 0

local function pinyin_dict()
    if PINYIN_DICT then return PINYIN_DICT end

    local dict = {}
    local groups = 0
    local chars_total = 0

    for first, second, chars in PINYIN_SRC:gmatch("(%d+),(%d+):([^\n]+)") do
        local code = tonumber(first) * 64 + tonumber(second)
        groups = groups + 1
        for c in chars:gmatch(UTF8_CHAR) do
            dict[c] = code
            chars_total = chars_total + 1
        end
    end

    PINYIN_DICT = dict
    PINYIN_GROUP_COUNT = groups
    msg.verbose(string.format("pakku: 拼音字典载入 %d 个汉字 / %d 个拼音组", chars_total, groups))
    return dict
end

----------------------------------------------------------------------
-- 2. 文本预处理
----------------------------------------------------------------------

-- 尾部标点（对应 pakku.js 的 ENDING_CHARS）
local ENDING_CHARS = {}
for c in (".。,，/?？!！…~～@^、+=-_♂♀ "):gmatch(UTF8_CHAR) do
    ENDING_CHARS[c] = true
end

-- 全角/半角归一表（对应 pakku.js 的 WIDTH_TABLE）
local WIDTH_TABLE = {
    ["　"] = " ", ["１"] = "1", ["２"] = "2", ["３"] = "3", ["４"] = "4",
    ["５"] = "5", ["６"] = "6", ["７"] = "7", ["８"] = "8", ["９"] = "9",
    ["０"] = "0",
    ["!"] = "！", ["＠"] = "@", ["＃"] = "#", ["＄"] = "$", ["％"] = "%",
    ["＾"] = "^", ["＆"] = "&", ["＊"] = "*", ["（"] = "(", ["）"] = ")",
    ["－"] = "-", ["＝"] = "=", ["＿"] = "_", ["＋"] = "+",
    ["［"] = "[", ["］"] = "]", ["｛"] = "{", ["｝"] = "}", [";"] = "；",
    ["＇"] = "'", [":"] = "：", ["＂"] = "\"", [","] = "，", ["．"] = ".",
    ["／"] = "/", ["＜"] = "<", ["＞"] = ">",
    ["?"] = "？", ["＼"] = "\\", ["｜"] = "|", ["｀"] = "`", ["～"] = "~",
    ["ｑ"] = "q", ["ｗ"] = "w", ["ｅ"] = "e", ["ｒ"] = "r", ["ｔ"] = "t",
    ["ｙ"] = "y", ["ｕ"] = "u", ["ｉ"] = "i", ["ｏ"] = "o", ["ｐ"] = "p",
    ["ａ"] = "a", ["ｓ"] = "s", ["ｄ"] = "d", ["ｆ"] = "f", ["ｇ"] = "g",
    ["ｈ"] = "h", ["ｊ"] = "j", ["ｋ"] = "k", ["ｌ"] = "l",
    ["ｚ"] = "z", ["ｘ"] = "x", ["ｃ"] = "c", ["ｖ"] = "v", ["ｂ"] = "b",
    ["ｎ"] = "n", ["ｍ"] = "m",
    ["Ｑ"] = "Q", ["Ｗ"] = "W", ["Ｅ"] = "E", ["Ｒ"] = "R", ["Ｔ"] = "T",
    ["Ｙ"] = "Y", ["Ｕ"] = "U", ["Ｉ"] = "I", ["Ｏ"] = "O", ["Ｐ"] = "P",
    ["Ａ"] = "A", ["Ｓ"] = "S", ["Ｄ"] = "D", ["Ｆ"] = "F", ["Ｇ"] = "G",
    ["Ｈ"] = "H", ["Ｊ"] = "J", ["Ｋ"] = "K", ["Ｌ"] = "L",
    ["Ｚ"] = "Z", ["Ｘ"] = "X", ["Ｃ"] = "C", ["Ｖ"] = "V", ["Ｂ"] = "B",
    ["Ｎ"] = "N", ["Ｍ"] = "M",
}

-- 空白归一：连续空白压成一个半角空格，两个 CJK 字符之间的空白整段删除
-- （对应 pakku.js 的 TRIM_EXTRA_SPACE_RE + TRIM_CJK_SPACE_RE）。
--! 注意：这里必须按 UTF-8 字符逐个处理。像 [ 　] 这样的字符类在 Lua 模式里
--! 是按“字节”匹配的，会误伤 0x80 / 0xE3 这类编码字节，把汉字切碎。
local function normalize_spaces(text)
    local chars, n = utf8_char_list(text)
    if n == 0 then return text end

    local out, k = {}, 0
    local i = 1
    while i <= n do
        local c = chars[i]
        if c == " " or c == "　" then
            local j = i
            while j + 1 <= n and (chars[j + 1] == " " or chars[j + 1] == "　") do
                j = j + 1
            end
            local prev = (i > 1) and utf8_codepoint(chars[i - 1]) or 0
            local nxt = (j < n) and utf8_codepoint(chars[j + 1]) or 0
            -- 前后都是 CJK 时整段删掉，否则留下一个半角空格
            if not (i > 1 and j < n and is_cjk_codepoint(prev) and is_cjk_codepoint(nxt)) then
                k = k + 1
                out[k] = " "
            end
            i = j + 1
        else
            k = k + 1
            out[k] = c
            i = i + 1
        end
    end
    return table.concat(out, "", 1, k)
end

-- 把 JS 风格量词 {n} / {n,} / {n,m} 翻译成等价的 Lua 模式。
-- Lua 模式没有量词区间，{n,m} 只能近似成“至少 n 次”。
local function quantifier_to_lua(p)
    -- {n} -> X 重复 n 次
    p = p:gsub("(%S)%{(%d+)%}", function(c, n)
        return string.rep(c, tonumber(n))
    end)
    -- {n,} -> X 重复 n-1 次后接 X+
    p = p:gsub("(%S)%{(%d+),%}", function(c, n)
        n = tonumber(n)
        if n <= 1 then return c .. "+" end
        return string.rep(c, n - 1) .. c .. "+"
    end)
    -- {n,m} -> 至少 n 次
    p = p:gsub("(%S)%{(%d+),(%d+)%}", function(c, n)
        n = tonumber(n)
        if n <= 1 then return c .. "+" end
        return string.rep(c, n - 1) .. c .. "+"
    end)
    return p
end

--- 对弹幕文本做标准化，返回可用于比较的字符串。
-- cfg 支持 trim_ending / trim_width / trim_space / forcelist 四个开关。
function M.normalize(text, cfg)
    if type(text) ~= "string" then return "" end
    cfg = cfg or {}

    local chars, n = utf8_char_list(text)

    -- 去掉尾部标点；如果整条都是标点就原样保留
    if cfg.trim_ending ~= false then
        local last = n
        while last >= 1 and ENDING_CHARS[chars[last]] do
            last = last - 1
        end
        if last > 0 and last < n then
            n = last
        end
    end

    local out = table.concat(chars, "", 1, n)

    if cfg.trim_width ~= false then
        out = out:gsub(UTF8_CHAR, function(c) return WIDTH_TABLE[c] or c end)
    end

    if cfg.trim_space ~= false then
        out = normalize_spaces(out)
    end

    if cfg.forcelist then
        for _, rule in ipairs(cfg.forcelist) do
            local ok, replaced = pcall(string.gsub, out, rule[1], rule[2])
            if ok then out = replaced end
        end
    end

    return out
end

----------------------------------------------------------------------
-- 3. 相似度计算
----------------------------------------------------------------------

local function freq_of_chars(chars)
    local f = {}
    for i = 1, #chars do
        local c = chars[i]
        f[c] = (f[c] or 0) + 1
    end
    return f
end

-- 把文本映射成“拼音 token 频率表”，同时返回 token 总数。
-- 与 pakku.js 的 C++ 实现一致：只有声母/韵母两个 token，
-- 字典里查不到的字符（英文、假名等）保留原字符，大写转小写。
local function freq_of_pinyin(chars, dict)
    local f = {}
    local total = 0
    for i = 1, #chars do
        local c = chars[i]
        local code = dict[c]
        if code then
            local first = math.floor(code / 64)
            local second = code % 64
            f[first] = (f[first] or 0) + 1
            total = total + 1
            if second > 0 then
                f[second] = (f[second] or 0) + 1
                total = total + 1
            end
        else
            if c >= "A" and c <= "Z" then c = string.lower(c) end
            f[c] = (f[c] or 0) + 1
            total = total + 1
        end
    end
    return f, total
end

-- 两个频率表之间的 L1 距离，即 pakku.js 用的“字符频率近似编辑距离”。
-- 复杂度 O(n)，对弹幕这种短文本足够准确。
local function freq_distance(f1, f2)
    local dist = 0
    for k, v in pairs(f1) do
        dist = dist + math.abs(v - (f2[k] or 0))
    end
    for k, v in pairs(f2) do
        if f1[k] == nil then dist = dist + v end
    end
    return dist
end

-- 相邻字符对（bigram）频率表
local function make_bigrams(chars)
    local grams = {}
    for i = 1, #chars - 1 do
        local g = chars[i] .. chars[i + 1]
        grams[g] = (grams[g] or 0) + 1
    end
    return grams
end

-- 两个 bigram 频率表的余弦相似度，放大到 0-100 的整数。
-- 注意这里算的是 cos^2（省掉一次开方，与 pakku.js 保持一致）。
local function gram_cosine(g1, g2)
    local dot, norm1, norm2 = 0, 0, 0
    for g, v in pairs(g1) do
        local v2 = g2[g] or 0
        dot = dot + v * v2
        norm1 = norm1 + v * v
    end
    for _, v in pairs(g2) do
        norm2 = norm2 + v * v
    end
    if norm1 <= 0 or norm2 <= 0 then return 0 end
    return math.floor(dot * dot / norm1 / norm2 * 100)
end

--- 字符频率近似编辑距离。"哈哈哈" / "哈哈哈啊" 的距离为 1。
function M.edit_distance(s1, s2)
    local c1 = utf8_char_list(s1)
    local c2 = utf8_char_list(s2)
    return freq_distance(freq_of_chars(c1), freq_of_chars(c2))
end

--- 拼音层面的近似编辑距离。"好看" / "好看啊" 距离为 2（多了 a 的声母+韵母）。
function M.pinyin_distance(s1, s2)
    local dict = pinyin_dict()
    local f1 = freq_of_pinyin(utf8_char_list(s1), dict)
    local f2 = freq_of_pinyin(utf8_char_list(s2), dict)
    return freq_distance(f1, f2)
end

--- bigram 余弦相似度，0-100 的整数。
function M.cosine_similarity(s1, s2)
    local g1 = make_bigrams(utf8_char_list(s1))
    local g2 = make_bigrams(utf8_char_list(s2))
    return gram_cosine(g1, g2)
end

----------------------------------------------------------------------
-- 4. 配置
----------------------------------------------------------------------

-- 同时接受 options.pakku_xxx 和 cfg.xxx 两种写法
local function pick(o, name, default)
    local v = o["pakku_" .. name]
    if v == nil then v = o[name] end
    if v == nil then return default end
    return v
end

local function tonum(v, default)
    v = tonumber(v)
    if v == nil then return default end
    return v
end

local function tobool(v, default)
    if v == nil then return default end
    if type(v) == "boolean" then return v end
    if type(v) == "string" then
        v = v:lower()
        if v == "yes" or v == "true" or v == "on" or v == "1" then return true end
        if v == "no" or v == "false" or v == "off" or v == "0" then return false end
    end
    if type(v) == "number" then return v ~= 0 end
    return default
end

local DEFAULT_MERGE_TYPES = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true }

--- 把散乱的配置整理成内部使用的 cfg。
function M.build_config(o)
    o = o or {}
    if o._built then return o end
    local cfg = { _built = true }

    cfg.enable           = tobool(pick(o, "enable", false), false)
    cfg.threshold        = tonum(pick(o, "threshold", 30), 30)
    cfg.max_dist         = tonum(pick(o, "max_dist", 5), 5)
    cfg.max_cosine       = tonum(pick(o, "max_cosine", 45), 45)
    cfg.use_pinyin       = tobool(pick(o, "use_pinyin", true), true)
    cfg.cross_mode       = tobool(pick(o, "cross_mode", true), true)
    cfg.mark             = tostring(pick(o, "mark", "suffix") or "suffix"):lower()
    cfg.mark_threshold   = tonum(pick(o, "mark_threshold", 1), 1)
    -- pakku.js: DANMU_SUBSCRIPT = true（下标 ₍₁₂₎）
    --! 默认关掉：下标字形只有正文字体的五成多高，比例还随字体浮动，
    --! 默认改用普通数字 "(12)"，跟随正文字体，观感稳定
    cfg.mark_subscript   = tobool(pick(o, "mark_subscript", false), false)
    cfg.enlarge          = tobool(pick(o, "enlarge", true), true)
    cfg.enlarge_min_count = tonum(pick(o, "enlarge_min_count", 5), 5)
    cfg.enlarge_max_scale = tonum(pick(o, "enlarge_max_scale", 2.0), 2.0)
    cfg.enlarge_log_base = tonum(pick(o, "enlarge_log_base", 5), 5)
    cfg.mode_elevation   = tobool(pick(o, "mode_elevation", true), true)
    cfg.representative_percent = tonum(pick(o, "representative_percent", 20), 20)
    cfg.normalize_display = tobool(pick(o, "normalize_display", true), true)

    cfg.trim_ending      = tobool(pick(o, "trim_ending", true), true)
    cfg.trim_width       = tobool(pick(o, "trim_width", true), true)
    cfg.trim_space       = tobool(pick(o, "trim_space", true), true)

    cfg.shrink_threshold = tonum(pick(o, "shrink_threshold", 0), 0)
    cfg.drop_threshold   = tonum(pick(o, "drop_threshold", 0), 0)
    cfg.fontsize         = tonum(pick(o, "fontsize", 0), 0)

    if cfg.mark ~= "prefix" and cfg.mark ~= "suffix" then
        cfg.mark = "off"
    end
    if cfg.max_cosine < 0 then cfg.max_cosine = 0 end
    if cfg.max_dist < 0 then cfg.max_dist = 0 end
    if cfg.enlarge_min_count < 1 then cfg.enlarge_min_count = 1 end
    if cfg.enlarge_max_scale < 1 then cfg.enlarge_max_scale = 1 end
    if cfg.enlarge_log_base <= 1 then cfg.enlarge_log_base = 5 end
    -- 单条弹幕最大 2*max_dist 个字符时按比例放宽阈值
    cfg.min_danmu_size = math.max(1, cfg.max_dist * 2)
    cfg.merge_types = DEFAULT_MERGE_TYPES

    -- 自定义替换规则：既接受 JSON 字符串，也接受 Lua 表
    cfg.forcelist = {}
    local raw = pick(o, "forcelist", nil)
    if type(raw) == "string" and raw ~= "" then
        if parse_json then
            local ok, parsed = pcall(parse_json, raw)
            if ok and type(parsed) == "table" then raw = parsed else raw = nil end
        else
            raw = nil
        end
    end
    if type(raw) == "table" then
        for _, rule in ipairs(raw) do
            if type(rule) == "table" and type(rule[1]) == "string" then
                local pat = quantifier_to_lua(rule[1])
                local repl = rule[2]
                if type(repl) ~= "string" then repl = "" end
                -- 预校验模式，坏的正则直接跳过而不是每帧报错
                if pcall(string.find, "", pat) then
                    cfg.forcelist[#cfg.forcelist + 1] = { pat, repl }
                else
                    msg.warn("pakku: 忽略非法替换规则 " .. rule[1])
                end
            end
        end
    end

    return cfg
end

----------------------------------------------------------------------
-- 5. 聚类
----------------------------------------------------------------------

--- 把一条弹幕预处理成聚类用的中间结构（对应 C++ 的 DanmuCacheline）。
function M.build_ir(d, cfg)
    local raw = d.text or ""
    local str = M.normalize(raw, cfg)
    local chars = utf8_char_list(str)

    local ir = {
        d = d,
        raw = raw,
        str = str,
        chars = chars,
        len = #chars,
        mode = d.type or 1,
        time_ms = math.floor((tonumber(d.time) or 0) * 1000 + 0.5),
        char_freq = freq_of_chars(chars),
        gram = make_bigrams(chars),
        py_freq = nil,
        py_len = 0,
    }

    if cfg.use_pinyin then
        ir.py_freq, ir.py_len = freq_of_pinyin(chars, pinyin_dict())
    end

    return ir
end

--- 判定两条弹幕是否相似，返回 reason, distance。
-- 依次尝试：完全相同 -> 字符频率编辑距离 -> 拼音距离 -> bigram 余弦相似度。
function M.check_similar(a, b, cfg)
    if not cfg.cross_mode and a.mode ~= b.mode then
        return nil
    end

    -- 1. 完全相同
    if a.str == b.str then
        return "identical", 0
    end

    local len_sum = a.len + b.len
    local max_dist = cfg.max_dist
    local min_size = cfg.min_danmu_size

    -- 2. 字符频率编辑距离
    local edit_dis = nil
    if max_dist >= 0 and math.abs(a.len - b.len) <= max_dist then
        edit_dis = freq_distance(a.char_freq, b.char_freq)
        local matched
        if len_sum < min_size then
            matched = edit_dis < max_dist * len_sum / min_size
        else
            matched = edit_dis <= max_dist
        end
        if matched then
            return "edit", edit_dis
        end
    end

    -- 3. 拼音距离（谐音）
    if cfg.use_pinyin and math.abs(a.py_len - b.py_len) <= max_dist then
        local py_dis = freq_distance(a.py_freq, b.py_freq)
        local matched
        if len_sum < min_size then
            matched = py_dis < max_dist * len_sum / min_size
        else
            matched = py_dis <= max_dist
        end
        if matched then
            return "pinyin", py_dis
        end
    end

    -- 4. bigram 余弦相似度
    -- 编辑距离已经表明两条弹幕没有任何公共字符时，余弦相似度必然为 0，跳过
    if cfg.max_cosine <= 100 and not (edit_dis and edit_dis >= len_sum) then
        local sim = gram_cosine(a.gram, b.gram)
        if sim >= cfg.max_cosine then
            return "cosine", sim
        end
    end

    return nil
end

-- 滑动窗口聚类：nearby 里按时间递增保存尚未定型的簇，
-- 新弹幕从后往前找第一个相似的簇并归入其中。
local function cluster(irs, cfg)
    local clusters = {}
    local nearby = {}
    local threshold_ms = cfg.threshold * 1000

    for _, ir in ipairs(irs) do
        local t = ir.time_ms

        -- 代表时间落后超过窗口的簇不再可能被后续弹幕命中，定型输出
        while #nearby > 0 and (t - nearby[1].time_ms) > threshold_ms do
            clusters[#clusters + 1] = nearby[1]
            table.remove(nearby, 1)
        end

        local matched = false
        for ci = #nearby, 1, -1 do
            local c = nearby[ci]
            local reason, dist = M.check_similar(ir, c.irs[1], cfg)
            if reason then
                c.irs[#c.irs + 1] = ir
                c.reasons[#c.reasons + 1] = reason
                c.dists[#c.dists + 1] = dist
                if reason ~= "identical" then
                    c.weak_reason = reason
                end
                matched = true
                break
            end
        end

        if not matched then
            nearby[#nearby + 1] = {
                time_ms = t,
                irs = { ir },
                reasons = { "orig" },
                dists = { 0 },
                weak_reason = nil,
            }
        end
    end

    for _, c in ipairs(nearby) do
        clusters[#clusters + 1] = c
    end

    return clusters
end

----------------------------------------------------------------------
-- 6. 字号放大 / 标记
----------------------------------------------------------------------

-- 放大系数是合并数量的对数，超过 enlarge_min_count 后才开始放大。
-- 默认对齐 pakku.js 的 calc_enlarge_rate()：以 5 为底、6 条起放大、
-- 上限 2 倍（合并 25 条即翻倍，再多也保持 2 倍）。
local function enlarge_scale(count, cfg)
    if not cfg.enlarge then return 1 end
    if count <= cfg.enlarge_min_count then return 1 end
    local r = math.log(count) / math.log(cfg.enlarge_log_base)
    if r > cfg.enlarge_max_scale then r = cfg.enlarge_max_scale end
    if r < 1 then r = 1 end
    return r
end

-- ★ 对外开放：modules/save_danmaku.lua 需要它来给「已合并的弹幕文件」还原
-- 字号放大系数（xml 里塞不下 merge_count，只能从 (N) 标记反解再算回来）。
M.enlarge_scale = enlarge_scale

-- 下标数字（U+2080 ~ U+2089）与下标括号（U+208D / U+208E）。
-- pakku.js 的 DANMU_SUBSCRIPT=on 时用它拼出 ₍₁₂₎ 这种标记。
--! 默认不用这套：下标字形只有正文字体的五成多高，看着偏小，
--! 而且比例随字体在 47%~63% 之间浮动，很难调到稳定观感。
--! 默认改成普通数字 + 半角括号 "(12)"，跟随正文字体，不需要任何补偿。
local SUBSCRIPT_DIGITS = { "₀", "₁", "₂", "₃", "₄", "₅", "₆", "₇", "₈", "₉" }
local SUBSCRIPT_LPAREN = "₍"
local SUBSCRIPT_RPAREN = "₎"

-- 把十进制数转成下标数字串，对应 pakku.js 的 to_subscript()
local function to_subscript(x)
    x = math.floor(tonumber(x) or 0)
    if x <= 0 then return SUBSCRIPT_DIGITS[1] end

    local out, n = {}, 0
    while x > 0 do
        n = n + 1
        out[n] = SUBSCRIPT_DIGITS[(x % 10) + 1]
        x = math.floor(x / 10)
    end
    -- 上面是从低位往高位收集的，反转回来
    for i = 1, math.floor(n / 2) do
        out[i], out[n - i + 1] = out[n - i + 1], out[i]
    end
    return table.concat(out)
end

-- 生成合并数量标记本身（不含位置）。
--   mark_subscript = false（默认） -> "(12)"   普通数字 + 半角括号，跟随正文字体
--   mark_subscript = true          -> "₍₁₂₎"  下标形式，对齐 pakku.js DANMU_SUBSCRIPT=on
--! 注意 "(12)" 是本项目的选择，不对应 pakku.js 的任何取值：
--! pakku.js 在 DANMU_SUBSCRIPT=off 时用的是 "[x12]"。
local function make_mark_tag(count, cfg)
    if cfg.mark == "off" or count <= cfg.mark_threshold then
        return ""
    end
    if cfg.mark_subscript then
        return SUBSCRIPT_LPAREN .. to_subscript(count) .. SUBSCRIPT_RPAREN
    end
    return "(" .. count .. ")"
end

-- 把标记拼到文本上。默认后缀（pakku.js 默认是 prefix，本实现按使用习惯用 suffix）。
local function make_mark(text, count, cfg)
    local tag = make_mark_tag(count, cfg)
    if tag == "" then return text end
    if cfg.mark == "prefix" then
        return tag .. text
    end
    return text .. tag
end

----------------------------------------------------------------------
-- 7. 密度调控
----------------------------------------------------------------------

local DISPVAL_POWER = 0.35
local DISPVAL_TIME_THRESHOLD_MS = 5000
local SHRINK_MAX_RATE = 1.732

--- 单条弹幕的“显示价值”，与文本长度的平方根成正比、与字号的 1.5 次方成正比。
function M.dispval(text, fontsize)
    local n = utf8_count(text or "")
    local f = (tonumber(fontsize) or 25) / 25
    if f > 2.5 then f = 2.5 elseif f < 0.7 then f = 0.7 end
    return math.sqrt(n) * f ^ 1.5
end

-- 密度超限时按权重决定是否丢弃：合并条数多、字号大的弹幕更不容易被丢
local function judge_drop(onscreen, threshold, count, weight, weight_dist)
    if threshold <= 0 or onscreen <= threshold then return false end
    local drop_rate = (onscreen - threshold) / threshold + 0.25
        - (weight_dist[weight] or 0) / 4
        - (math.sqrt(math.max(count, 1)) - 1) / 5
    return drop_rate >= 1 or (drop_rate > 0 and math.random() < drop_rate)
end

--- 按屏幕显示密度整体缩小字号、并丢弃低优先级弹幕。
-- 会就地修改 danmakus 里的 merge_scale，并给需要丢弃的条目打上 drop = true。
function M.adjust_density(danmakus, cfg)
    cfg = M.build_config(cfg)
    if cfg.shrink_threshold <= 0 and cfg.drop_threshold <= 0 then
        return danmakus
    end

    local n = #danmakus
    if n == 0 then return danmakus end

    -- 弹幕的“权重”用合并条数近似（uosc_danmaku 没有点赞数）
    local weight_dist = {}
    for i = 0, 11 do weight_dist[i] = 0 end
    for _, d in ipairs(danmakus) do
        local w = math.floor(d.merge_count or 1)
        if w < 1 then w = 1 elseif w > 11 then w = 11 end
        d._pakku_weight = w
        weight_dist[w] = weight_dist[w] + 1
    end
    for i = 0, 11 do
        weight_dist[i] = weight_dist[i] / n
    end
    for i = 0, 10 do
        weight_dist[i] = ((weight_dist[i] + weight_dist[i + 1]) / 2) ^ 3
    end

    local dispval_base = cfg.shrink_threshold > 0
        and (cfg.shrink_threshold ^ DISPVAL_POWER) or 1

    local queue = {}   -- 待扣减的 [到期时间, dispval]
    local head = 1
    local onscreen = 0

    for _, d in ipairs(danmakus) do
        local t = (tonumber(d.time) or 0) * 1000

        while head <= #queue and t > queue[head][1] do
            onscreen = onscreen - queue[head][2]
            head = head + 1
        end

        local scale = d.merge_scale or 1
        local fontsize = (cfg.fontsize > 0 and cfg.fontsize or 25) * scale
        local dv = M.dispval(d.text, fontsize)

        if judge_drop(onscreen, cfg.drop_threshold, d.merge_count or 1,
                      d._pakku_weight, weight_dist) then
            -- 丢弃判定命中，这条不参与后续的密度累加
            d.drop = true
        else
            onscreen = onscreen + dv
            queue[#queue + 1] = { t + DISPVAL_TIME_THRESHOLD_MS, dv }

            -- 缩小判定
            if cfg.shrink_threshold > 0 and onscreen > cfg.shrink_threshold then
                local rate = (onscreen ^ DISPVAL_POWER) / dispval_base
                if rate > SHRINK_MAX_RATE then rate = SHRINK_MAX_RATE end
                if rate > 1 then
                    d.merge_scale = scale / rate
                end
            end
        end
    end

    return danmakus
end

----------------------------------------------------------------------
-- 8. 对外主入口
----------------------------------------------------------------------

-- 从簇里挑出展示文本：出现次数最多者优先，并列时取长度中位数。
local function choose_display_text(cluster_irs, cfg)
    local freq = {}          -- 归一化文本 -> 次数
    local raw_of = {}        -- 归一化文本 -> 出现次数最多的原始文本
    local raw_freq = {}
    local order = {}

    for _, ir in ipairs(cluster_irs) do
        local key = ir.str
        if freq[key] == nil then
            freq[key] = 0
            order[#order + 1] = key
            raw_of[key] = ir.raw
            raw_freq[key] = {}
        end
        freq[key] = freq[key] + 1

        local rf = raw_freq[key]
        rf[ir.raw] = (rf[ir.raw] or 0) + 1
        if rf[ir.raw] > (rf[raw_of[key]] or 0) then
            raw_of[key] = ir.raw
        end
    end

    local best_key, best_cnt, ties = nil, -1, {}
    for _, key in ipairs(order) do
        if freq[key] > best_cnt then
            best_cnt = freq[key]
            ties = { key }
        elseif freq[key] == best_cnt then
            ties[#ties + 1] = key
        end
    end

    if #ties == 1 then
        best_key = ties[1]
    else
        -- 并列时取长度中位数，避免选到特别短或特别长的版本
        table.sort(ties, function(x, y)
            local lx, ly = utf8_count(x), utf8_count(y)
            if lx ~= ly then return lx < ly end
            return x < y
        end)
        best_key = ties[math.floor(#ties / 2) + 1]
    end
    best_key = best_key or cluster_irs[1].str

    if cfg.normalize_display then
        return best_key
    end
    return raw_of[best_key] or best_key
end

local function dominant_reason(c)
    -- 统计各判定命中次数，取最强的那个作为展示用的原因
    local rank = { identical = 4, edit = 3, pinyin = 2, cosine = 1, orig = 0 }
    local best, best_rank = "orig", -1
    for _, r in ipairs(c.reasons) do
        local v = rank[r] or 0
        if v > best_rank then best, best_rank = r, v end
    end
    return best
end

--- 合并弹幕。返回合并后的新数组与统计信息。
-- cfg 可以直接传 uosc_danmaku 的全局 options 表。
function M.merge(danmakus, cfg)
    cfg = M.build_config(cfg)

    if not cfg.enable then
        return danmakus, nil
    end
    if type(danmakus) ~= "table" or #danmakus == 0 then
        return danmakus, nil
    end

    local stats = {
        total = #danmakus,
        merged = 0,
        clusters = 0,
        max_combo = 0,
        identical = 0,
        edit = 0,
        pinyin = 0,
        cosine = 0,
        dropped = 0,
        shrunk = 0,
        enlarged = 0,
        ms = 0,
    }

    local t0 = os.clock()

    -- 8.1 预处理并拆成“可聚类”和“原样透传”两部分
    local irs, passthrough = {}, {}
    for _, d in ipairs(danmakus) do
        local t = d.type or 1
        if cfg.merge_types[t] and type(d.text) == "string" and d.text ~= "" then
            irs[#irs + 1] = M.build_ir(d, cfg)
        else
            passthrough[#passthrough + 1] = d
        end
    end

    -- 8.2 滑动窗口聚类
    local clusters = cluster(irs, cfg)
    stats.clusters = #clusters

    -- 8.3 把每个簇定型成一条弹幕
    local out = {}
    for _, c in ipairs(clusters) do
        local peers = c.irs
        local count = #peers
        local reason = dominant_reason(c)

        for _, r in ipairs(c.reasons) do
            if stats[r] ~= nil then stats[r] = stats[r] + 1 end
        end

        -- 代表条目：按 representative_percent 取簇内靠前的成员
        local rep_idx = math.floor(count * cfg.representative_percent / 100)
        if rep_idx > count - 1 then rep_idx = count - 1 end
        if rep_idx < 0 then rep_idx = 0 end
        local rep = peers[rep_idx + 1].d
        rep_idx = rep_idx + 1

        local scale = enlarge_scale(count, cfg)
        if scale > 1.001 then stats.enlarged = stats.enlarged + 1 end

        -- 类型提升：底部 > 顶部 > 滚动
        local mode = rep.type or 1
        if cfg.mode_elevation then
            for _, ir in ipairs(peers) do
                local m = ir.d.type or 1
                if m == 4 then
                    mode = 4
                elseif m == 5 and mode ~= 4 then
                    mode = 5
                end
            end
        end

        local display = choose_display_text(peers, cfg)

        local entry = {}
        for k, v in pairs(rep) do entry[k] = v end
        entry.time = rep.time
        entry.orig_time = rep.orig_time
        entry.type = mode
        entry.color = rep.color
        entry.size = rep.size
        -- merge_mark 单独存一份，parse.lua 用它把标记加粗（不用正则去猜）
        entry.merge_mark = make_mark_tag(count, cfg)
        entry.text = make_mark(display, count, cfg)
        entry.merge_count = count
        entry.merge_scale = scale
        entry.merge_reason = reason

        if count > 1 then
            stats.merged = stats.merged + count
            if count > stats.max_combo then stats.max_combo = count end
        end

        out[#out + 1] = entry
    end

    for _, d in ipairs(passthrough) do
        local entry = {}
        for k, v in pairs(d) do entry[k] = v end
        entry.merge_count = entry.merge_count or 1
        entry.merge_scale = entry.merge_scale or 1
        entry.merge_reason = entry.merge_reason or "orig"
        out[#out + 1] = entry
    end

    table.sort(out, function(a, b)
        local ta, tb = tonumber(a.time) or 0, tonumber(b.time) or 0
        if ta ~= tb then return ta < tb end
        return (a.merge_count or 1) > (b.merge_count or 1)
    end)

    -- 8.4 密度调控
    if cfg.shrink_threshold > 0 or cfg.drop_threshold > 0 then
        M.adjust_density(out, cfg)
        local kept = {}
        for _, d in ipairs(out) do
            if d.drop then
                stats.dropped = stats.dropped + 1
            else
                if (d.merge_scale or 1) < 0.999 then
                    stats.shrunk = stats.shrunk + 1
                end
                kept[#kept + 1] = d
            end
        end
        out = kept
    end

    for _, d in ipairs(out) do d._pakku_weight = nil end

    stats.ms = math.floor((os.clock() - t0) * 1000 + 0.5)

    msg.verbose(string.format(
        "pakku: %d 条 -> %d 条（簇 %d，最多合并 %d；==%d ≤%d P%d %d%%；丢弃 %d，缩小 %d，放大 %d，耗时 %dms）",
        stats.total, #out, stats.clusters, stats.max_combo,
        stats.identical, stats.edit, stats.pinyin, stats.cosine,
        stats.dropped, stats.shrunk, stats.enlarged, stats.ms))

    return out, stats
end

-- 供调试/单测使用
M.pinyin_group_count = function() pinyin_dict(); return PINYIN_GROUP_COUNT end

return M
