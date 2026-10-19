-- Testes do plugin TabNews sem KOReader e sem rede.
-- Uso: luajit tests/run.lua   (rodar na raiz do repositório)

local ROOT = arg and arg[0] and arg[0]:match("^(.*)/tests/run%.lua$") or "."
local PLUGIN = ROOT .. "/tabnews.koplugin/main.lua"
local TMP = os.getenv("TMPDIR") or "/tmp"
local DATA = TMP .. "/tabnews-test-" .. tostring(os.time())

-- Stubs mínimos dos módulos do KOReader ------------------------------------
local shown = {}
local function class()
    local C = {}
    C.__index = C
    function C:new(o)
        o = o or {}
        setmetatable(o, self)
        self.__index = self
        if o.init then o:init() end
        return o
    end
    function C:extend(o)
        o = o or {}
        setmetatable(o, self)
        self.__index = self
        return o
    end
    return C
end
local UIManager = {
    show = function(_, w) shown[#shown + 1] = w end,
    close = function(_, w) if w and w.onCloseWidget then w:onCloseWidget() end end,
    forceRePaint = function() end,
    nextTick = function(_, f, ...) f(...) end,
    scheduleIn = function(_, _s, f, ...) f(...) end,
}
local InfoMessage = class()
function InfoMessage:onCloseWidget() if self.dismiss_callback then self.dismiss_callback() end end
local Menu = class()
function Menu:switchItemTable(_t, items) self.item_table = items end
local store = {}
local LuaSettings = {}
function LuaSettings:open(path)
    store[path] = store[path] or {}
    local d = store[path]
    return {
        readSetting = function(_, k) return d[k] end,
        saveSetting = function(_, k, v) d[k] = v end,
        flush = function() end,
    }
end
local ok_lfs, lfs = pcall(require, "lfs")
if not ok_lfs then
    -- lfs mínimo com os.execute (para CI sem luafilesystem)
    lfs = {
        attributes = function(p, what)
            local f = io.open(p, "r")
            if f then
                local okr = f:read(0) ~= nil or f:seek("end") ~= nil
                f:close()
                local isdir = os.execute('[ -d "' .. p .. '" ]')
                isdir = isdir == true or isdir == 0
                local mode = isdir and "directory" or "file"
                if what == "mode" then return mode end
                if what == "modification" then return os.time() end
                return { mode = mode }
            end
            local isdir = os.execute('[ -d "' .. p .. '" ]')
            if isdir == true or isdir == 0 then return what == "mode" and "directory" or { mode = "directory" } end
            return nil
        end,
        mkdir = function(p) return os.execute('mkdir -p "' .. p .. '"') end,
        dir = function(p)
            local h = io.popen('ls -a "' .. p .. '"')
            local names = {}
            for n in h:lines() do names[#names + 1] = n end
            h:close()
            local i = 0
            return function() i = i + 1; return names[i] end
        end,
    }
end
local preload = {
    ["ui/widget/buttondialog"] = class(), ["ui/widget/confirmbox"] = class(),
    ["ui/widget/infomessage"] = InfoMessage, ["ui/widget/inputdialog"] = class(),
    ["ui/widget/menu"] = Menu, ["ui/widget/multiinputdialog"] = class(),
    ["ui/uimanager"] = UIManager, ["luasettings"] = LuaSettings,
    ["ui/widget/container/widgetcontainer"] = class(),
    ["datastorage"] = {
        getDataDir = function() return DATA end,
        getSettingsDir = function() return DATA .. "/settings" end,
    },
    ["device"] = { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end } },
    ["ui/network/manager"] = {
        runWhenOnline = function(_, f) f() end,
        isConnected = function() return false end,
        turnOffWifi = function() end,
    },
    ["json"] = { decode = function() error("sem rede nos testes") end },
    ["libs/libkoreader-lfs"] = lfs,
    ["logger"] = { warn = function() end, info = function() end },
    ["gettext"] = function(s) return s end,
    ["socketutil"] = { set_timeout = function() end, reset_timeout = function() end },
    ["socket.http"] = { request = function() return nil, "sem rede" end },
    ["socket"] = { skip = function(_n, ...) return select(2, ...) end, sleep = function() end },
    ["ltn12"] = { sink = { table = function() return function() return 1 end end },
                  source = { string = function() return function() end end } },
    ["apps/reader/readerui"] = { showReader = function() end },
}
for name, mod in pairs(preload) do package.preload[name] = function() return mod end end
os.execute('mkdir -p "' .. DATA .. '/settings"')

-- Mini framework -----------------------------------------------------------
local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("FALHOU: " .. name .. (detail and ("\n   " .. tostring(detail)) or ""))
    end
end
local function has(name, html, needle)
    check(name, html:find(needle, 1, true) ~= nil, "esperava encontrar: " .. needle .. "\n   em: " .. html)
end
local function hasnt(name, html, needle)
    check(name, html:find(needle, 1, true) == nil, "não esperava: " .. needle .. "\n   em: " .. html)
end

-- Carrega o plugin ---------------------------------------------------------
local TabNews = dofile(PLUGIN)
local T = TabNews._test
local MD, Search = T.MD, T.Search

-- Markdown -----------------------------------------------------------------
local h = MD.toHTML("# Título\n\nTexto **forte** e *itálico* e `a<b`.")
has("título", h, "<h1>Título</h1>")
has("negrito", h, "<b>forte</b>")
has("itálico", h, "<i>itálico</i>")
has("código inline escapado", h, "<code>a&lt;b</code>")

h = MD.toHTML("```lua\nif a < b then end\n```")
has("bloco de código", h, "<pre><code>if a &lt; b then end</code></pre>")

h = MD.toHTML("| A | B |\n|:--|--:|\n| **1** | 2 |\n| só uma |")
has("tabela", h, "<table>")
has("tabela cabeçalho", h, "<th>A</th>")
has("tabela alinhamento", h, 'text-align:right')
has("tabela célula formatada", h, "<td><b>1</b></td>")

h = MD.toHTML("- a\n  - b\n    1. c\n- d")
has("lista aninhada", h, "<li>a\n<ul>\n<li>b\n<ol>")
check("lista aninhada balanceada", select(2, h:gsub("<li>", "")) == select(2, h:gsub("</li>", "")), h)

h = MD.toHTML("- [ ] aberta\n- [x] feita")
has("tarefa aberta", h, "☐ aberta")
has("tarefa feita", h, "☑ feita")

h = MD.toHTML("Veja https://tabnews.com.br/a/b. Fim")
has("url solta vira link", h, '<a href="https://tabnews.com.br/a/b">')
has("pontuação fora do link", h, "</a>. Fim")

h = MD.toHTML("[x](https://a.com/a__b__c)")
has("url com __ intacta", h, 'href="https://a.com/a__b__c"')

h = MD.toHTML("<details>\n<summary>Mais</summary>\n<kbd>Ctrl</kbd> H<sub>2</sub>O<br>fim\n</details>")
has("summary vira negrito", h, "<b>Mais</b>")
has("kbd vira code", h, "<code>Ctrl</code>")
has("sub mantido", h, "<sub>2</sub>")
has("br mantido", h, "<br/>")
hasnt("details some", h, "details")

h = MD.toHTML("<script>alert(1)</script> e List<T>")
has("script escapado", h, "&lt;script&gt;")
hasnt("sem script real", h, "<script>")

h = MD.toHTML("> citação **x**")
has("citação", h, "<blockquote><p>citação <b>x</b></p></blockquote>")

MD.resolveImage = function(url) return url:find("ok", 1, true) and "p_img/1.png" or nil end
h = MD.toHTML('![logo](https://ok.png) ![x](https://falha.png) <img src="https://ok2.png" width="10">')
has("imagem baixada", h, '<img src="p_img/1.png" alt="logo"/>')
has("imagem sem download", h, "[imagem: x]")
MD.resolveImage = nil

-- Funções auxiliares ---------------------------------------------------------
check("categoria colchetes", T.categoryOf("[Pitch] Meu app") == "Pitch")
check("categoria dois-pontos", T.categoryOf("Pitch: Meu app") == "Pitch")
check("sem categoria (frase longa)", T.categoryOf("Como fiz uma coisa muito comprida demais: parte 2") == nil)
check("sem categoria (url)", T.categoryOf("https://exemplo.com") == nil)

check("versão maior", T.versionNewer("0.10", "0.9"))
check("versão igual", not T.versionNewer("0.9", "0.9"))
check("versão menor", not T.versionNewer("0.8.1", "0.9"))
check("versão com patch", T.versionNewer("1.0.1", "1.0"))

check("tempo de leitura", T.readingMinutes(string.rep("palavra ", 600)) == 3)

check("fold acentos", Search.fold("Programação AÇÃO") == "programacao acao")
local idx = { { id = "1", u = "a", s = "x", t = "Meu Kindle desbloqueado" }, { id = "2", u = "b", s = "y", t = "Outro" } }
check("índice encontra", #Search.matchIndex(idx, "KINDLE", 10) == 1)
check("índice todas as palavras", #Search.matchIndex(idx, "kindle outro", 10) == 0)

local ddg = [[
<a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.tabnews.com.br%2Ffulano%2Fmeu-post&rut=x">Meu <b>post</b> · fulano · TabNews</a>
<a rel="nofollow" class="result__a" href="//duckduckgo.com/y.js?ad_domain=amazon.com">Anúncio</a>
<a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.tabnews.com.br%2Fciclano%2F0a1b2c3d-1111-2222-3333-444455556666">Resposta</a>
<a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.tabnews.com.br%2Frecentes%2Fpagina">Recentes</a>
]]
local res = Search.parseDDG(ddg)
check("ddg: só posts do TabNews", #res == 2, #res)
check("ddg: título limpo", res[1] and res[1].title == "Meu post", res[1] and res[1].title)
check("ddg: comentário marcado", res[2] and res[2].title:find("comentário", 1, true) ~= nil)

-- Plugin -------------------------------------------------------------------
local ui = { menu = { registerToMainMenu = function() end } }
local p = TabNews:new{ ui = ui }
local menu = {}
p:addToMainMenu(menu)
check("menu registrado", menu.tabnews and #menu.tabnews.sub_item_table >= 8)

-- conta: o menu mostra quem está conectado e sair pede confirmação
local function findItem(items, pred)
    for _i, it in ipairs(items or {}) do
        if pred(it) then return it end
        local sub = findItem(it.sub_item_table, pred)
        if sub then return sub end
    end
end
local account = findItem(menu.tabnews.sub_item_table, function(it)
    return it.text_func and it.keep_menu_open
end)
check("item de conta existe", account ~= nil)
if account then
    check("deslogado: Entrar", account.text_func():find("Entrar", 1, true) ~= nil, account.text_func())
    p.session = { token = "t", username = "ana", expires_at = "2999-01-01T00:00:00.000Z" }
    check("logado: mostra usuário", account.text_func() == "Conectado como @ana", account.text_func())
    shown = {}
    account.callback(nil)
    check("logado: tocar pede confirmação", shown[#shown] and shown[#shown].ok_callback ~= nil)
    check("logado: não sai sem confirmar", p:sessionInfo() ~= nil)
    shown[#shown].ok_callback()
    check("confirmou: saiu", p:sessionInfo() == nil)
    p.session = { token = "t", expires_at = "2000-01-01T00:00:00.000Z" }
    check("sessão expirada conta como deslogado", account.text_func():find("Entrar", 1, true) ~= nil)
end

-- edição montada a partir de posts salvos
local dir = DATA .. "/tabnews"
local posts = {}
for i = 1, 3 do
    local post = { id = "id" .. i, owner_username = "user" .. i, slug = "post-" .. i, title = "Post " .. i,
                   body = "Corpo **" .. i .. "**", published_at = "2026-10-18T10:00:00Z", tabcoins = i }
    local path = p:postPath(post)
    local f = io.open(path, "w")
    f:write(T.buildHTML(post, {}))
    f:close()
    p.saved[path] = { title = post.title, user = post.owner_username, slug = post.slug, minutes = 1,
                      downloaded = os.time() }
    posts[i] = post
end
local edition = p:buildEdition(posts)
check("edição criada", edition ~= nil)
if edition then
    local f = io.open(edition)
    local html = f:read("*a")
    f:close()
    check("edição com 3 artigos", select(2, html:gsub('class="article"', "")) == 3)
    check("edição com índice", select(2, html:gsub('href="#p%d"', "")) == 3)
end

-- post aberto
ui.document = { file = dir .. "/user1_post-1.html" }
local cur = p:currentPost()
check("post aberto identificado", cur and cur.user == "user1" and cur.slug == "post-1")
ui.document = { file = edition }
check("edição não é post único", p:currentPost() and p:currentPost().slug == nil)
ui.document = nil

-- limpeza: só apaga o que está velho
local old_path = p:postPath(posts[1])
p.saved[old_path].downloaded = os.time() - 40 * 86400
check("limpeza apaga 1", p:cleanupOld() == 1)
check("arquivo apagado", io.open(old_path) == nil)

-- sincronização sem rede: termina sem erro e avisa
shown = {}
p:sync(false)
local last = shown[#shown]
check("sync sem rede termina", last and last.text and last.text:find("TabNews", 1, true) ~= nil,
    last and last.text)
check("sync liberada", not p.syncing_now)

-- cancelamento: tocar na mensagem antes da primeira etapa
local real_schedule = UIManager.scheduleIn
local queue = {}
UIManager.scheduleIn = function(_, _s, f) queue[#queue + 1] = f end
shown = {}
p:sync(false)
local progress_msg = shown[#shown]
if progress_msg and progress_msg.dismiss_callback then progress_msg.dismiss_callback() end
while #queue > 0 do table.remove(queue, 1)() end
UIManager.scheduleIn = real_schedule
last = shown[#shown]
check("sync cancelada", last and last.text and last.text:find("cancelada", 1, true) ~= nil, last and last.text)

os.execute('rm -rf "' .. DATA .. '"')
print(string.format("%d testes ok, %d falharam", passed, failed))
os.exit(failed == 0 and 0 or 1)
