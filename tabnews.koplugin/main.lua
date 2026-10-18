--[[
TabNews para KOReader
Lê www.tabnews.com.br no e-reader usando a API pública do site.
Os posts são convertidos para HTML e salvos localmente, então dá para ler offline.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local _ = require("gettext")

local Screen = Device.screen

local VERSION = "0.7"
local API = "https://www.tabnews.com.br/api/v1"
local PER_PAGE = 30
local USER_AGENT = "KOReader-TabNews/" .. VERSION
local POSTS_DIR = DataStorage:getDataDir() .. "/tabnews"
local INDEX_FILE = DataStorage:getSettingsDir() .. "/tabnews_index.lua"

local MAX_IMAGES = 15                   -- por post (inclui comentários)
local MAX_IMAGE_BYTES = 3 * 1024 * 1024 -- ignora imagens maiores que 3 MB
local INDEX_FIRST_PAGES = 20            -- primeira vez: 2000 títulos mais recentes
local INDEX_UPDATE_PAGES = 10
local INDEX_MAX = 10000
local SYNC_COUNT = 20                   -- posts relevantes baixados na sincronização
local EDITION_SIZE = 10                 -- posts na edição do dia
local FAVORITE_POSTS = 5                -- posts recentes de cada autor favorito
local AUTO_SYNC_INTERVAL = 6 * 3600     -- sincronização automática no máximo a cada 6 h
local CLEANUP_DAYS = 30
local WORDS_PER_MINUTE = 200

local function str(v) return type(v) == "string" and v or "" end
local function num(v) return type(v) == "number" and v or 0 end

-- MD-BEGIN: conversor Markdown -> HTML (simples, cobre o que mais aparece no TabNews)
local MD = {}

local function esc(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end
MD.esc = esc

-- MD.resolveImage(url, alt) pode ser definido por quem chama: baixa a imagem
-- e devolve o caminho local (src) ou nil para mostrar só o texto alternativo.
MD.resolveImage = nil

local function inline(text)
    -- trechos já convertidos ficam guardados e voltam no final,
    -- para que negrito/itálico não estraguem código, URLs e tags
    local keep = {}
    local function protect(html)
        keep[#keep + 1] = html
        return "\1" .. #keep .. "\2"
    end
    text = text:gsub("`([^`]+)`", function(c)
        return protect("<code>" .. esc(c) .. "</code>")
    end)
    text = esc(text)
    text = text:gsub("!%[([^%]]*)%]%(([^%)%s]+)[^%)]*%)", function(alt, url)
        local raw_url = url:gsub("&amp;", "&")
        local src = MD.resolveImage and MD.resolveImage(raw_url, alt)
        if src then
            return protect('<img src="' .. esc(src) .. '" alt="' .. alt .. '"/>')
        end
        return protect("<i>[imagem" .. (alt ~= "" and (": " .. alt) or "") .. "]</i>")
    end)
    text = text:gsub("%[([^%]]+)%]%(([^%)%s]+)[^%)]*%)", function(label, url)
        -- só o href é protegido; o texto do link ainda recebe negrito/itálico
        return '<a href="' .. protect(url) .. '">' .. label .. "</a>"
    end)
    text = text:gsub("%*%*(.-)%*%*", "<b>%1</b>")
    text = text:gsub("__(.-)__", "<b>%1</b>")
    text = text:gsub("%*([^%*\n]+)%*", "<i>%1</i>")
    text = text:gsub("~~(.-)~~", "<s>%1</s>")
    -- duas passadas: um item protegido pode conter outro (ex.: código dentro de link)
    for _pass = 1, 2 do
        text = text:gsub("\1(%d+)\2", function(i) return keep[tonumber(i)] end)
    end
    return text
end

function MD.toHTML(md)
    md = md:gsub("\r\n", "\n")
    local out, para, quote, code_buf = {}, {}, {}, {}
    local list_type, in_code = nil, false

    local function flush_para()
        if #para > 0 then
            out[#out + 1] = "<p>" .. inline(table.concat(para, " ")) .. "</p>"
            para = {}
        end
    end
    local function close_list()
        if list_type then
            out[#out + 1] = "</" .. list_type .. ">"
            list_type = nil
        end
    end
    local function flush_quote()
        if #quote > 0 then
            out[#out + 1] = "<blockquote>" .. MD.toHTML(table.concat(quote, "\n")) .. "</blockquote>"
            quote = {}
        end
    end

    for line in (md .. "\n"):gmatch("(.-)\n") do
        if in_code then
            if line:match("^%s*```") then
                out[#out + 1] = "<pre><code>" .. esc(table.concat(code_buf, "\n")) .. "</code></pre>"
                in_code, code_buf = false, {}
            else
                code_buf[#code_buf + 1] = line
            end
        elseif line:match("^%s*```") then
            flush_para(); close_list(); flush_quote()
            in_code = true
        elseif line:match("^%s*>") then
            flush_para(); close_list()
            quote[#quote + 1] = (line:gsub("^%s*>%s?", ""))
        else
            flush_quote()
            local level, htext = line:match("^(#+)%s+(.*)")
            if level and #level <= 6 then
                flush_para(); close_list()
                out[#out + 1] = string.format("<h%d>%s</h%d>", #level, inline(htext), #level)
            elseif line:match("^%s*[-*_]%s*[-*_]%s*[-*_][-*_%s]*$") then
                flush_para(); close_list()
                out[#out + 1] = "<hr/>"
            else
                local ltype, item = "ul", line:match("^%s*[-*+]%s+(.*)")
                if not item then
                    ltype, item = "ol", line:match("^%s*%d+[.)]%s+(.*)")
                end
                if item then
                    flush_para()
                    if list_type ~= ltype then
                        close_list()
                        out[#out + 1] = "<" .. ltype .. ">"
                        list_type = ltype
                    end
                    out[#out + 1] = "<li>" .. inline(item) .. "</li>"
                elseif line:match("^%s*$") then
                    flush_para(); close_list()
                elseif list_type and line:match("^%s+") then
                    -- continuação do item de lista anterior
                    out[#out] = out[#out]:sub(1, -6) .. " " .. inline(line:gsub("^%s+", "")) .. "</li>"
                else
                    close_list()
                    para[#para + 1] = line
                end
            end
        end
    end
    if in_code then
        out[#out + 1] = "<pre><code>" .. esc(table.concat(code_buf, "\n")) .. "</code></pre>"
    end
    flush_para(); close_list(); flush_quote()
    return table.concat(out, "\n")
end
-- MD-END

local CSS = [[
body { line-height: 1.4; }
h1.title { font-size: 1.4em; margin-bottom: 0.2em; }
h1.edition { font-size: 1.6em; text-align: center; margin-bottom: 0.2em; }
.meta { font-size: 0.85em; margin: 0 0 1em 0; }
.article { page-break-before: always; }
ol.toc li { margin-bottom: 0.5em; }
pre { font-family: monospace; font-size: 0.8em; white-space: pre-wrap; border-left: 3px solid #888; padding-left: 0.5em; margin: 1em 0; }
code { font-family: monospace; font-size: 0.9em; }
img { max-width: 100%; display: block; margin: 0.6em auto; }
blockquote { margin: 0.8em 0 0.8em 0.5em; padding-left: 0.7em; border-left: 2px solid #aaa; font-style: italic; }
.comment { margin-top: 0.8em; padding-left: 0.6em; border-left: 2px solid #bbb; }
.comment-author { font-weight: bold; font-size: 0.85em; }
]]

local function formatDate(iso)
    local y, m, d = str(iso):match("^(%d+)-(%d+)-(%d+)")
    if not y then return "" end
    return d .. "/" .. m .. "/" .. y
end

local function postTitle(post)
    if str(post.title) ~= "" then return str(post.title) end
    return "Comentário de " .. str(post.owner_username)
end

local function readingMinutes(markdown)
    local words = 0
    for _w in str(markdown):gmatch("%S+") do words = words + 1 end
    return math.max(1, math.floor(words / WORDS_PER_MINUTE + 0.5))
end

-- Categoria pelo título: "[Pitch] ..." ou "Dúvida: ..."
local function categoryOf(title)
    title = str(title)
    local c = title:match("^%s*%[([^%]]+)%]")
    if not c then
        c = title:match("^%s*([^:%[%]]+):")
        if c and (#c > 24 or c:find("//", 1, true)) then c = nil end
    end
    if not c then return nil end
    c = c:gsub("^%s+", ""):gsub("%s+$", "")
    return c ~= "" and c or nil
end

local function renderComments(list)
    local parts = {}
    for _i, c in ipairs(type(list) == "table" and list or {}) do
        if type(c) == "table" and type(c.body) == "string" then
            parts[#parts + 1] = string.format(
                '<div class="comment"><div class="comment-author">%s · %d tabcoins</div>%s%s</div>',
                esc(str(c.owner_username)), num(c.tabcoins), MD.toHTML(c.body), renderComments(c.children))
        end
    end
    return table.concat(parts, "\n")
end

local function wrapDoc(title, body)
    return table.concat({
        "<!DOCTYPE html>",
        '<html><head><meta charset="UTF-8"/>',
        "<title>", esc(title), "</title>",
        "<style>", CSS, "</style></head><body>",
        body,
        "</body></html>",
    })
end

local function buildHTML(post, comments)
    local source = ""
    if str(post.source_url) ~= "" then
        source = '<p class="meta">Fonte: ' .. esc(post.source_url) .. "</p>"
    end
    local comments_html = ""
    if type(comments) == "table" and #comments > 0 then
        comments_html = "<hr/><h2>Comentários</h2>\n" .. renderComments(comments)
    end
    return wrapDoc(postTitle(post), table.concat({
        '<h1 class="title">', esc(postTitle(post)), "</h1>",
        '<p class="meta">', esc(str(post.owner_username)), " · ", formatDate(post.published_at),
        " · ", tostring(num(post.tabcoins)), " tabcoins · ~",
        tostring(readingMinutes(post.body)), " min</p>",
        source,
        MD.toHTML(str(post.body)),
        comments_html,
    }))
end

-- HTTP ---------------------------------------------------------------------

-- opts: accept, body, content_type, cookie. Aceita qualquer resposta 2xx.
-- Em erro devolve nil, mensagem (da API, quando houver) e o código HTTP.
local function httpRequest(url, opts)
    opts = opts or {}
    local sink = {}
    local headers = { ["Accept"] = opts.accept or "*/*", ["User-Agent"] = USER_AGENT }
    local source
    if opts.body then
        headers["Content-Type"] = opts.content_type or "application/x-www-form-urlencoded"
        headers["Content-Length"] = tostring(#opts.body)
        source = ltn12.source.string(opts.body)
    end
    if opts.cookie then headers["Cookie"] = opts.cookie end
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, resp_headers, status = socket.skip(1, http.request{
        url = url,
        method = opts.body and "POST" or "GET",
        headers = headers,
        source = source,
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    local body = table.concat(sink)
    if type(code) ~= "number" or code < 200 or code >= 300 then
        logger.warn("TabNews: falha em", url, code, status)
        local msg
        if body ~= "" then
            local ok, data = pcall(JSON.decode, body)
            if ok and type(data) == "table" and type(data.message) == "string" then msg = data.message end
        end
        return nil, msg or tostring(status or code), code
    end
    return body, resp_headers or {}, code
end

local function httpGet(url, accept)
    return httpRequest(url, { accept = accept })
end

local function decodeJSON(body)
    if not body then return nil end
    local ok, data = pcall(JSON.decode, body)
    if ok and type(data) == "table" then return data end
    return nil
end

local function fetchJSON(url, cookie)
    local body, err = httpRequest(url, { accept = "application/json", cookie = cookie })
    if not body then return nil, err end
    local data = decodeJSON(body)
    if not data then return nil, "resposta inválida" end
    return data
end

local function jsonString(v)
    return '"' .. str(v):gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"'
end

local IMAGE_EXT = {
    ["image/png"] = "png", ["image/jpeg"] = "jpg", ["image/jpg"] = "jpg",
    ["image/gif"] = "gif", ["image/webp"] = "webp", ["image/svg+xml"] = "svg",
}

-- Baixa as imagens de um post para <pasta>/<nome>_img/.
-- cache: url -> src local; é salvo junto com o post para não baixar de novo ao atualizar.
local function imageDownloader(html_path, cache)
    local dir_name = html_path:match("([^/]+)%.html$") .. "_img"
    local dir = POSTS_DIR .. "/" .. dir_name
    local count = 0
    return function(url)
        if count >= MAX_IMAGES or not url:match("^https?://") then return nil end
        local cached = cache[url]
        if cached and lfs.attributes(POSTS_DIR .. "/" .. cached, "mode") == "file" then
            count = count + 1
            return cached
        end
        local data, headers = httpGet(url, "image/*")
        if not data or #data == 0 or #data > MAX_IMAGE_BYTES then return nil end
        local ctype = (str(headers["content-type"]):match("^[^;%s]+") or ""):lower()
        local lurl = url:lower()
        local ext = IMAGE_EXT[ctype] or lurl:match("%.(png)$") or lurl:match("%.(jpe?g)$")
            or lurl:match("%.(gif)$") or lurl:match("%.(webp)$")
        if not ext then return nil end
        if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
        count = count + 1
        local idx = 1
        while lfs.attributes(dir .. "/" .. idx .. "." .. ext, "mode") do idx = idx + 1 end
        local name = idx .. "." .. ext
        local f = io.open(dir .. "/" .. name, "wb")
        if not f then return nil end
        f:write(data)
        f:close()
        cache[url] = dir_name .. "/" .. name
        return cache[url]
    end
end

-- Remove uma pasta e os arquivos dentro dela (um nível)
local function removeDir(dir)
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    local names = {}
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then names[#names + 1] = name end
    end
    for _i, name in ipairs(names) do os.remove(dir .. "/" .. name) end
    os.remove(dir)
end

-- UI helpers ---------------------------------------------------------------

local function loading(text)
    local msg = InfoMessage:new{ text = text }
    UIManager:show(msg)
    UIManager:forceRePaint()
    return msg
end

local function alert(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

local function isConnected()
    local ok, res = pcall(function()
        if NetworkMgr.isConnected then return NetworkMgr:isConnected() end
        return NetworkMgr:isOnline()
    end)
    return ok and res
end

-- SEARCH-BEGIN: busca. O TabNews não tem endpoint de busca, então usamos
-- o DuckDuckGo (versão HTML) com site:tabnews.com.br, que cobre todo o histórico.
local Search = {}

function Search.urlencode(q)
    return (q:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

function Search.urldecode(q)
    return (q:gsub("%+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function htmlText(h)
    h = h:gsub("<[^>]+>", "")
    h = h:gsub("&quot;", '"'):gsub("&#x27;", "'"):gsub("&#39;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">")
    h = h:gsub("&nbsp;", " "):gsub("&amp;", "&")
    return (h:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- caminhos de duas partes do site que não são posts
local NOT_POSTS = {
    api = true, recentes = true, relevantes = true, publicar = true, login = true, cadastro = true,
    perfil = true, status = true, museu = true, ["termos-de-uso"] = true, faq = true,
}

-- Extrai {owner_username, slug, title} dos resultados do DuckDuckGo
function Search.parseDDG(html)
    local results, seen = {}, {}
    for href, inner in html:gmatch('<a[^>]-class="result__a"[^>]-href="([^"]+)"[^>]*>(.-)</a>') do
        local target = href:match("uddg=([^&]+)")
        target = target and Search.urldecode(target) or href
        local user, slug = target:match("^https?://w?w?w?%.?tabnews%.com%.br/([^/%?#]+)/([^/%?#]+)/?$")
        if user and not NOT_POSTS[user] and not seen[user .. "/" .. slug] then
            seen[user .. "/" .. slug] = true
            local title = htmlText(inner):gsub("%s*·[^·]*·%s*TabNews%s*$", ""):gsub("%s*[·%-]%s*TabNews%s*$", "")
            -- slug no formato UUID = é um comentário, não um post
            if slug:match("^%x+%-%x+%-%x+%-%x+%-%x+$") then title = "[comentário] " .. title end
            table.insert(results, { owner_username = user, slug = slug, title = title })
        end
    end
    return results
end
-- Minúsculas e sem acento, para "Programação" casar com "programacao"
local ACCENTS = {
    ["á"] = "a", ["à"] = "a", ["â"] = "a", ["ã"] = "a", ["ä"] = "a",
    ["Á"] = "a", ["À"] = "a", ["Â"] = "a", ["Ã"] = "a", ["Ä"] = "a",
    ["é"] = "e", ["è"] = "e", ["ê"] = "e", ["ë"] = "e", ["É"] = "e", ["È"] = "e", ["Ê"] = "e",
    ["í"] = "i", ["ì"] = "i", ["î"] = "i", ["ï"] = "i", ["Í"] = "i", ["Î"] = "i",
    ["ó"] = "o", ["ò"] = "o", ["ô"] = "o", ["õ"] = "o", ["ö"] = "o",
    ["Ó"] = "o", ["Ò"] = "o", ["Ô"] = "o", ["Õ"] = "o", ["Ö"] = "o",
    ["ú"] = "u", ["ù"] = "u", ["û"] = "u", ["ü"] = "u", ["Ú"] = "u", ["Ü"] = "u",
    ["ç"] = "c", ["Ç"] = "c", ["ñ"] = "n", ["Ñ"] = "n",
}
function Search.fold(text)
    return (text:lower():gsub("\195[\128-\191]", function(c) return ACCENTS[c] or c end))
end

-- Procura no índice local: todas as palavras precisam aparecer no título
function Search.matchIndex(posts, q, limit)
    local words = {}
    for w in Search.fold(q):gmatch("%S+") do words[#words + 1] = w end
    local found = {}
    for _i, p in ipairs(posts) do
        local t = Search.fold(p.t or "")
        local ok = true
        for _j, w in ipairs(words) do
            if not t:find(w, 1, true) then ok = false; break end
        end
        if ok then
            found[#found + 1] = { id = p.id, owner_username = p.u, slug = p.s, title = p.t }
            if #found >= limit then break end
        end
    end
    return found
end
-- SEARCH-END

local FEED_TITLES = {
    relevant = "TabNews · Relevantes",
    new = "TabNews · Recentes",
}

local TabNews = WidgetContainer:extend{
    name = "tabnews",
    is_doc_only = false,
}

function TabNews:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/tabnews.lua")
    self.read = self.settings:readSetting("read") or {}
    self.saved = self.settings:readSetting("saved") or {}
    self.follows = self.settings:readSetting("follows") or {}
    self.hidden_cats = self.settings:readSetting("hidden_cats") or {}
    self.session = self.settings:readSetting("session")
    if lfs.attributes(POSTS_DIR, "mode") ~= "directory" then
        lfs.mkdir(POSTS_DIR)
    end
    self.ui.menu:registerToMainMenu(self)
    UIManager:nextTick(function() self:cleanupOld() end)
end

function TabNews:saveState()
    self.settings:saveSetting("read", self.read)
    self.settings:saveSetting("saved", self.saved)
    self.settings:saveSetting("follows", self.follows)
    self.settings:saveSetting("hidden_cats", self.hidden_cats)
    self.settings:saveSetting("session", self.session)
    self.settings:flush()
end

function TabNews:getFlag(key, default)
    local v = self.settings:readSetting(key)
    if v == nil then return default end
    return v
end

function TabNews:toggleFlag(key, default)
    self.settings:saveSetting(key, not self:getFlag(key, default))
    self.settings:flush()
end

-- Menu principal -----------------------------------------------------------

function TabNews:addToMainMenu(menu_items)
    local function hasPost()
        local cur = self:currentPost()
        return cur ~= nil and cur.slug ~= nil
    end
    menu_items.tabnews = {
        text = _("TabNews"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Post aberto"),
                enabled_func = hasPost,
                sub_item_table = {
                    { text = _("Atualizar (comentários novos)"), callback = function() self:refreshCurrent() end },
                    { text = _("Dar tabcoin (+1)"), callback = function() self:voteCurrent("credit") end },
                    { text = _("Tirar tabcoin (−1)"), callback = function() self:voteCurrent("debit") end },
                    {
                        text_func = function()
                            local cur = self:currentPost()
                            local user = cur and cur.user or "?"
                            return self.follows[user] and string.format(_("Deixar de seguir @%s"), user)
                                or string.format(_("Seguir @%s"), user)
                        end,
                        callback = function()
                            local cur = self:currentPost()
                            if cur and cur.user then self:toggleFollow(cur.user) end
                        end,
                    },
                },
                separator = true,
            },
            { text = _("Edição do dia"), callback = function() self:openEdition() end },
            { text = _("Buscar…"), callback = function() self:askSearch() end },
            { text = _("Relevantes"), callback = function() self:showFeed("relevant") end },
            { text = _("Recentes"), callback = function() self:showFeed("new") end },
            { text = _("Autores favoritos"), callback = function() self:showFavorites() end },
            { text = _("Posts salvos (offline)"), callback = function() self:showSaved() end, separator = true },
            { text = _("Sincronizar agora"), callback = function() self:syncNow() end },
            {
                text = _("Configurações"),
                sub_item_table = {
                    {
                        text = _("Sincronizar ao conectar no Wi-Fi"),
                        help_text = _("Baixa os relevantes, os posts dos favoritos, a edição do dia e atualiza a busca. No máximo a cada 6 horas."),
                        checked_func = function() return self:getFlag("auto_sync", false) end,
                        callback = function() self:toggleFlag("auto_sync", false) end,
                    },
                    {
                        text = string.format(_("Apagar posts sem uso há %d dias"), CLEANUP_DAYS),
                        checked_func = function() return self:getFlag("auto_cleanup", true) end,
                        callback = function() self:toggleFlag("auto_cleanup", true) end,
                        separator = true,
                    },
                    {
                        text_func = function()
                            local s = self:sessionInfo()
                            return s and string.format(_("Conta: @%s (sair)"), str(s.username))
                                or _("Entrar na conta TabNews")
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu)
                            if self:sessionInfo() then
                                self:logout()
                            else
                                self:askLogin()
                            end
                            if touchmenu then touchmenu:updateItems() end
                        end,
                    },
                    { text = _("Autores favoritos…"), callback = function() self:manageFollows() end },
                    { text = _("Categorias escondidas…"), callback = function() self:manageHiddenCats() end, separator = true },
                    { text = _("Apagar todos os posts salvos"), callback = function() self:clearSaved() end },
                },
            },
        },
    }
end

-- Listas -------------------------------------------------------------------

function TabNews:showMenu(title, items)
    if self.menu then UIManager:close(self.menu) end
    self.menu = Menu:new{
        title = title,
        item_table = items,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onMenuSelect = function(_menu, item)
            if item.callback then item.callback() end
            return true
        end,
        onMenuHold = function(_menu, item)
            if item.hold_callback then item.hold_callback() end
            return true
        end,
        close_callback = function()
            if self.menu then
                UIManager:close(self.menu)
                self.menu = nil
            end
        end,
    }
    UIManager:show(self.menu)
end

function TabNews:isHidden(post)
    local cat = categoryOf(post.title)
    return cat ~= nil and self.hidden_cats[Search.fold(cat)] ~= nil
end

function TabNews:postBadge(post)
    local total = num(post.children_deep_count)
    local badge = string.format("%d tc · %d com.", num(post.tabcoins), total)
    local info = self.saved[self:postPath(post)]
    if info and info.comments and total > info.comments then
        badge = badge .. string.format(" (+%d)", total - info.comments)
    end
    if info and info.minutes then
        badge = badge .. string.format(" · %d min", info.minutes)
    end
    return badge
end

function TabNews:postItem(post)
    local title = str(post.title)
    if self.read[str(post.id)] then title = "✓ " .. title end
    return {
        text = title,
        mandatory = self:postBadge(post),
        callback = function() self:openPost(post) end,
        hold_callback = function() self:postActions(post) end,
    }
end

-- Segurar o dedo num post: seguir autor, esconder categoria, baixar
function TabNews:postActions(post)
    local user = str(post.owner_username)
    local cat = categoryOf(post.title)
    local dialog
    local buttons = {
        {{
            text = self.follows[user] and string.format(_("Deixar de seguir @%s"), user)
                or string.format(_("Seguir @%s"), user),
            callback = function()
                UIManager:close(dialog)
                self:toggleFollow(user)
            end,
        }},
        {{
            text = _("Baixar para ler depois"),
            callback = function()
                UIManager:close(dialog)
                NetworkMgr:runWhenOnline(function()
                    local msg = loading(_("Baixando post…"))
                    local ok, err = self:downloadPost(post, self:postPath(post))
                    UIManager:close(msg)
                    alert(ok and _("Post salvo para ler offline.") or (_("Erro: ") .. tostring(err)), ok and 2 or nil)
                end)
            end,
        }},
    }
    if cat then
        table.insert(buttons, 2, {{
            text = string.format(_("Esconder posts “%s”"), cat),
            callback = function()
                UIManager:close(dialog)
                self.hidden_cats[Search.fold(cat)] = cat
                self:saveState()
                alert(string.format(_("Posts “%s” não vão mais aparecer nas listas.\nDá para desfazer em Configurações."), cat))
                if self.feed and self.menu then
                    self.menu:switchItemTable(nil, self:feedItems())
                end
            end,
        }})
    end
    dialog = ButtonDialog:new{ title = postTitle(post), buttons = buttons }
    UIManager:show(dialog)
end

function TabNews:showFeed(strategy)
    NetworkMgr:runWhenOnline(function()
        self.feed = { strategy = strategy, page = 0, posts = {} }
        if self:loadNextPage() then
            self:showMenu(FEED_TITLES[strategy], self:feedItems())
        end
    end)
end

function TabNews:loadNextPage()
    local f = self.feed
    local msg = loading(_("Carregando posts…"))
    local data, err = fetchJSON(string.format("%s/contents?page=%d&per_page=%d&strategy=%s",
        API, f.page + 1, PER_PAGE, f.strategy))
    UIManager:close(msg)
    if type(data) ~= "table" then
        alert(_("Erro ao carregar o TabNews: ") .. tostring(err))
        return false
    end
    f.page = f.page + 1
    for _i, post in ipairs(data) do table.insert(f.posts, post) end
    f.has_more = #data == PER_PAGE
    return true
end

function TabNews:feedItems()
    local items = {}
    for _i, post in ipairs(self.feed.posts) do
        if not self:isHidden(post) then
            table.insert(items, self:postItem(post))
        end
    end
    if self.feed.has_more then
        table.insert(items, {
            text = _("Carregar mais…"),
            callback = function()
                NetworkMgr:runWhenOnline(function()
                    local keep = #items
                    if self:loadNextPage() and self.menu then
                        self.menu:switchItemTable(nil, self:feedItems(), keep)
                    end
                end)
            end,
        })
    end
    return items
end

-- Autores favoritos ----------------------------------------------------------

function TabNews:toggleFollow(user)
    if self.follows[user] then
        self.follows[user] = nil
        alert(string.format(_("Você deixou de seguir @%s."), user), 2)
    else
        self.follows[user] = true
        alert(string.format(_("Seguindo @%s.\nOs posts aparecem em “Autores favoritos”."), user), 3)
    end
    self:saveState()
end

function TabNews:followList()
    local users = {}
    for user in pairs(self.follows) do users[#users + 1] = user end
    table.sort(users, function(a, b) return a:lower() < b:lower() end)
    return users
end

function TabNews:fetchFavoritePosts(per_user)
    local all = {}
    for _i, user in ipairs(self:followList()) do
        local data = fetchJSON(string.format("%s/contents/%s?strategy=new&per_page=%d&with_children=false",
            API, user, per_user))
        if type(data) == "table" then
            for _j, post in ipairs(data) do all[#all + 1] = post end
        end
    end
    table.sort(all, function(a, b) return str(a.published_at) > str(b.published_at) end)
    return all
end

function TabNews:showFavorites()
    if #self:followList() == 0 then
        return alert(_("Você ainda não segue ninguém.\nSegure o dedo num post da lista para seguir o autor."))
    end
    NetworkMgr:runWhenOnline(function()
        local msg = loading(_("Carregando posts dos favoritos…"))
        local posts = self:fetchFavoritePosts(10)
        UIManager:close(msg)
        if #posts == 0 then return alert(_("Nenhum post encontrado.")) end
        local items = {}
        for _i, post in ipairs(posts) do
            local item = self:postItem(post)
            item.mandatory = "@" .. str(post.owner_username) .. " · " .. formatDate(post.published_at)
            items[#items + 1] = item
        end
        self:showMenu(_("TabNews · Favoritos"), items)
    end)
end

function TabNews:manageFollows()
    local items = {
        {
            text = _("+ Seguir um autor…"),
            callback = function()
                local dialog
                dialog = InputDialog:new{
                    title = _("Nome de usuário no TabNews"),
                    input_hint = _("ex.: filipedeschamps"),
                    buttons = {{
                        { text = _("Cancelar"), id = "close", callback = function() UIManager:close(dialog) end },
                        {
                            text = _("Seguir"),
                            is_enter_default = true,
                            callback = function()
                                local user = dialog:getInputText():gsub("^%s*@?", ""):gsub("%s+$", "")
                                UIManager:close(dialog)
                                if user ~= "" then
                                    self.follows[user] = true
                                    self:saveState()
                                    self:manageFollows()
                                end
                            end,
                        },
                    }},
                }
                UIManager:show(dialog)
                dialog:onShowKeyboard()
            end,
        },
    }
    for _i, user in ipairs(self:followList()) do
        items[#items + 1] = {
            text = "@" .. user,
            mandatory = _("tocar para remover"),
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = string.format(_("Deixar de seguir @%s?"), user),
                    ok_text = _("Remover"),
                    ok_callback = function()
                        self.follows[user] = nil
                        self:saveState()
                        self:manageFollows()
                    end,
                })
            end,
        }
    end
    self:showMenu(_("Autores favoritos"), items)
end

function TabNews:manageHiddenCats()
    local items = {}
    for key, label in pairs(self.hidden_cats) do
        items[#items + 1] = {
            text = label,
            mandatory = _("tocar para mostrar de novo"),
            callback = function()
                self.hidden_cats[key] = nil
                self:saveState()
                self:manageHiddenCats()
            end,
        }
    end
    if #items == 0 then
        if self.menu then UIManager:close(self.menu); self.menu = nil end
        return alert(_("Nenhuma categoria escondida.\nSegure o dedo num post como “Pitch: …” para esconder a categoria."))
    end
    table.sort(items, function(a, b) return a.text:lower() < b.text:lower() end)
    self:showMenu(_("Categorias escondidas"), items)
end

-- Download e abertura -----------------------------------------------------

function TabNews:postPath(post)
    local name = (str(post.owner_username) .. "_" .. str(post.slug)):gsub("[^%w%-_]", "")
    return POSTS_DIR .. "/" .. name:sub(1, 120) .. ".html"
end

function TabNews:downloadPost(post, path)
    local user, slug = str(post.owner_username), str(post.slug)
    local full, err = fetchJSON(string.format("%s/contents/%s/%s", API, user, slug))
    if type(full) ~= "table" then return false, err end
    local comments = fetchJSON(string.format("%s/contents/%s/%s/children", API, user, slug))
    local old = self.saved[path] or {}
    local images = type(old.images) == "table" and old.images or {}
    MD.resolveImage = imageDownloader(path, images)
    local ok, html = pcall(buildHTML, full, comments)
    MD.resolveImage = nil
    if not ok then return false, html end
    local f, ferr = io.open(path, "w")
    if not f then return false, ferr end
    f:write(html)
    f:close()
    self.saved[path] = {
        title = postTitle(full),
        author = user,
        user = user,
        slug = slug,
        id = str(full.id),
        date = formatDate(full.published_at),
        comments = num(full.children_deep_count),
        minutes = readingMinutes(full.body),
        images = images,
        downloaded = os.time(),
        opened = old.opened,
    }
    self:saveState()
    return true
end

function TabNews:openPost(post)
    local path = self:postPath(post)
    local info = self.saved[path]
    local has_new = info and info.comments and num(post.children_deep_count) > info.comments
    if lfs.attributes(path, "mode") == "file" and not has_new then
        return self:openFile(path, post)
    end
    NetworkMgr:runWhenOnline(function()
        local msg = loading(has_new and _("Baixando comentários novos…") or _("Baixando post…"))
        local ok, err = self:downloadPost(post, path)
        UIManager:close(msg)
        if ok then
            self:openFile(path, post)
        else
            alert(_("Não foi possível baixar o post: ") .. tostring(err))
        end
    end)
end

function TabNews:openFile(path, post)
    if post and str(post.id) ~= "" then
        self.read[str(post.id)] = true
    end
    if self.saved[path] then self.saved[path].opened = os.time() end
    self:saveState()
    if self.menu then
        UIManager:close(self.menu)
        self.menu = nil
    end
    if self.ui.document then
        self.ui:switchDocument(path)
    else
        require("apps/reader/readerui"):showReader(path)
    end
end

-- Baixa os N mais relevantes que ainda não estão salvos
function TabNews:downloadRelevant(count, progress)
    local posts, err = fetchJSON(string.format("%s/contents?page=1&per_page=%d&strategy=relevant", API, count))
    if type(posts) ~= "table" then return nil, err end
    local done = 0
    for i, post in ipairs(posts) do
        local path = self:postPath(post)
        if lfs.attributes(path, "mode") ~= "file" and not self:isHidden(post) then
            if progress then progress(string.format(_("Baixando relevantes %d/%d…"), i, #posts)) end
            if self:downloadPost(post, path) then done = done + 1 end
        end
    end
    return posts, done
end

-- Edição do dia ------------------------------------------------------------

function TabNews:editionPath()
    return POSTS_DIR .. "/edicao-" .. os.date("%Y-%m-%d") .. ".html"
end

-- Monta a edição juntando os posts já salvos (as imagens são reaproveitadas,
-- porque os caminhos são relativos à mesma pasta)
function TabNews:buildEdition(posts)
    local toc, articles, total_min, n = {}, {}, 0, 0
    for _i, post in ipairs(posts) do
        local path = self:postPath(post)
        local f = io.open(path, "r")
        if f then
            local html = f:read("*a")
            f:close()
            local body = html:match("<body>(.*)</body>")
            if body then
                n = n + 1
                local info = self.saved[path] or {}
                local anchor = "p" .. n
                body = body:gsub('<h1 class="title">', '<h1 class="title" id="' .. anchor .. '">', 1)
                articles[#articles + 1] = '<div class="article">' .. body
                    .. '<p class="meta"><a href="#toc">Voltar ao índice</a></p></div>'
                total_min = total_min + (info.minutes or 0)
                toc[#toc + 1] = string.format('<li><a href="#%s">%s</a><br/><span class="meta">@%s · ~%d min</span></li>',
                    anchor, esc(info.title or str(post.title)), esc(str(post.owner_username)), info.minutes or 1)
                self.read[str(post.id)] = true
            end
        end
    end
    if n == 0 then return nil end
    local date = os.date("%d/%m/%Y")
    local title = "TabNews · Edição de " .. date
    local html = wrapDoc(title, table.concat({
        '<h1 class="edition" id="toc">', esc(title), "</h1>",
        string.format('<p class="meta" style="text-align:center">%d posts mais relevantes · ~%d min de leitura</p>',
            n, total_min),
        '<ol class="toc">', table.concat(toc, "\n"), "</ol>",
        table.concat(articles, "\n"),
    }))
    local path = self:editionPath()
    local f = io.open(path, "w")
    if not f then return nil end
    f:write(html)
    f:close()
    self.saved[path] = {
        title = title, author = "TabNews", edition = true,
        minutes = total_min, downloaded = os.time(),
    }
    self:saveState()
    return path
end

function TabNews:makeEdition(progress)
    local posts, err = self:downloadRelevant(EDITION_SIZE * 2, progress)
    if not posts then return nil, err end
    local chosen = {}
    for _i, post in ipairs(posts) do
        if not self:isHidden(post) and lfs.attributes(self:postPath(post), "mode") == "file" then
            chosen[#chosen + 1] = post
            if #chosen >= EDITION_SIZE then break end
        end
    end
    local path = self:buildEdition(chosen)
    if not path then return nil, _("nenhum post disponível") end
    return path
end

function TabNews:openEdition()
    local path = self:editionPath()
    if lfs.attributes(path, "mode") == "file" then
        return self:openFile(path)
    end
    NetworkMgr:runWhenOnline(function()
        local msg = loading(_("Montando a edição do dia…"))
        local result, err = self:makeEdition(function(text)
            UIManager:close(msg)
            msg = loading(_("Montando a edição do dia…") .. "\n" .. text)
        end)
        UIManager:close(msg)
        if result then
            self:openFile(result)
        else
            alert(_("Não foi possível montar a edição: ") .. tostring(err))
        end
    end)
end

-- Posts salvos ---------------------------------------------------------------

function TabNews:showSaved()
    local files = {}
    for name in lfs.dir(POSTS_DIR) do
        if name:match("%.html$") then
            local path = POSTS_DIR .. "/" .. name
            table.insert(files, { path = path, mtime = lfs.attributes(path, "modification") or 0 })
        end
    end
    if #files == 0 then
        return alert(_("Nenhum post salvo ainda."))
    end
    table.sort(files, function(a, b) return a.mtime > b.mtime end)
    local items = {}
    for _i, f in ipairs(files) do
        local info = self.saved[f.path] or {}
        local extra = info.minutes and string.format(" · %d min", info.minutes) or ""
        table.insert(items, {
            text = info.title or f.path:match("([^/]+)%.html$"),
            mandatory = (info.edition and _("edição") or ("@" .. str(info.author))) .. extra,
            callback = function() self:openFile(f.path) end,
        })
    end
    self:showMenu(_("TabNews · Salvos"), items)
end

function TabNews:removeSaved(path)
    local cur = self.ui and self.ui.document and self.ui.document.file
    if cur and cur:match("([^/]+)$") == path:match("([^/]+)$") then return false end
    os.remove(path)
    removeDir((path:gsub("%.html$", "_img")))
    removeDir((path:gsub("%.html$", ".sdr")))
    self.saved[path] = nil
    return true
end

-- Apaga posts que não foram abertos nem baixados nos últimos CLEANUP_DAYS dias
function TabNews:cleanupOld()
    if not self:getFlag("auto_cleanup", true) then return 0 end
    local limit = os.time() - CLEANUP_DAYS * 86400
    local old = {}
    for path, info in pairs(self.saved) do
        local last = math.max(info.opened or 0, info.downloaded or 0)
        if last > 0 and last < limit then old[#old + 1] = path end
    end
    local n = 0
    for _i, path in ipairs(old) do
        if self:removeSaved(path) then n = n + 1 end
    end
    if n > 0 then
        logger.info("TabNews: limpeza removeu", n, "posts antigos")
        self:saveState()
    end
    return n
end

function TabNews:clearSaved()
    UIManager:show(ConfirmBox:new{
        text = _("Apagar todos os posts salvos?\nEles serão baixados de novo quando você abrir."),
        ok_text = _("Apagar"),
        ok_callback = function()
            local names = {}
            for name in lfs.dir(POSTS_DIR) do
                if name:match("%.html$") then names[#names + 1] = name end
            end
            local n = 0
            for _i, name in ipairs(names) do
                if self:removeSaved(POSTS_DIR .. "/" .. name) then n = n + 1 end
            end
            self:saveState()
            alert(string.format(_("%d posts apagados."), n))
        end,
    })
end

-- Sincronização ------------------------------------------------------------

function TabNews:sync(silent)
    local msg = loading(_("Sincronizando TabNews…"))
    local function progress(text)
        if silent then return end
        UIManager:close(msg)
        msg = loading(_("Sincronizando TabNews…") .. "\n" .. text)
    end
    local report = {}

    local relevant, done = self:downloadRelevant(SYNC_COUNT, progress)
    if not relevant then done = 0 end
    report[#report + 1] = string.format(_("Relevantes: %d novos"), done)

    local fav_new = 0
    if #self:followList() > 0 then
        progress(_("Posts dos favoritos…"))
        for _i, post in ipairs(self:fetchFavoritePosts(FAVORITE_POSTS)) do
            local path = self:postPath(post)
            if lfs.attributes(path, "mode") ~= "file" and self:downloadPost(post, path) then
                fav_new = fav_new + 1
            end
        end
        report[#report + 1] = string.format(_("Favoritos: %d novos"), fav_new)
    end

    if lfs.attributes(self:editionPath(), "mode") ~= "file" then
        progress(_("Montando a edição do dia…"))
        if self:makeEdition() then report[#report + 1] = _("Edição do dia pronta") end
    end

    UIManager:close(msg)
    local before = #self:loadIndex()
    local index = self:updateIndex(silent)
    report[#report + 1] = string.format(_("Busca: %d títulos (+%d)"), #index, #index - before)

    local removed = self:cleanupOld()
    if removed > 0 then report[#report + 1] = string.format(_("Limpeza: %d posts antigos apagados"), removed) end

    self.settings:saveSetting("last_sync", os.time())
    self.settings:flush()
    alert(_("TabNews sincronizado") .. "\n" .. table.concat(report, "\n"), silent and 5 or nil)
end

function TabNews:syncNow()
    NetworkMgr:runWhenOnline(function() self:sync(false) end)
end

-- Evento do KOReader quando o Wi-Fi conecta
function TabNews:onNetworkConnected()
    if not self:getFlag("auto_sync", false) or self.syncing then return end
    local last = self.settings:readSetting("last_sync") or 0
    if os.time() - last < AUTO_SYNC_INTERVAL then return end
    self.syncing = true
    UIManager:scheduleIn(3, function()
        local ok, err = pcall(self.sync, self, true)
        if not ok then logger.warn("TabNews: sincronização automática falhou:", err) end
        self.syncing = false
    end)
end

-- Busca -------------------------------------------------------------------

function TabNews:askSearch()
    local dialog
    dialog = InputDialog:new{
        title = _("Buscar no TabNews"),
        input = self.last_query or "",
        input_hint = _("ex.: kindle, rust, carreira"),
        buttons = {{
            { text = _("Cancelar"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Buscar"),
                is_enter_default = true,
                callback = function()
                    local q = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                    UIManager:close(dialog)
                    if q ~= "" then self:search(q) end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Busca na web pelo DuckDuckGo (POST, como o formulário do site; tenta 2x)
function TabNews:searchWeb(q)
    local body = "q=" .. Search.urlencode("site:tabnews.com.br " .. q)
    for attempt = 1, 2 do
        local html, err = httpRequest("https://html.duckduckgo.com/html/", { accept = "text/html", body = body })
        if html then
            local results = Search.parseDDG(html)
            logger.info("TabNews: DuckDuckGo devolveu", #results, "resultados")
            if #results > 0 then return results end
        else
            logger.warn("TabNews: DuckDuckGo indisponível:", err)
        end
        if attempt == 1 then socket.sleep(2) end
    end
    return {}
end

function TabNews:loadIndex()
    self.index_store = self.index_store or LuaSettings:open(INDEX_FILE)
    return self.index_store:readSetting("posts") or {}
end

-- Índice local de títulos: só baixa o que é novo desde a última atualização
function TabNews:updateIndex(silent)
    local posts = self:loadIndex()
    local known = {}
    for _i, p in ipairs(posts) do known[p.id] = true end
    local first_time = #posts == 0
    local max_pages = first_time and INDEX_FIRST_PAGES or INDEX_UPDATE_PAGES
    local fresh, msg = {}, nil
    for page = 1, max_pages do
        if not silent and (not msg or first_time) then
            if msg then UIManager:close(msg) end
            msg = loading(first_time
                and string.format(_("Criando índice de títulos (só na primeira vez)… %d/%d"), page, max_pages)
                or _("Atualizando índice de títulos…"))
        end
        local data = fetchJSON(string.format("%s/contents?strategy=new&page=%d&per_page=100", API, page))
        if type(data) ~= "table" or #data == 0 then break end
        local reached_known = false
        for _i, p in ipairs(data) do
            local id = str(p.id)
            if known[id] then
                reached_known = true
            elseif id ~= "" then
                known[id] = true
                fresh[#fresh + 1] = { id = id, u = str(p.owner_username), s = str(p.slug), t = str(p.title) }
            end
        end
        if reached_known then break end
    end
    if msg then UIManager:close(msg) end
    if #fresh > 0 then
        for _i, p in ipairs(posts) do
            if #fresh >= INDEX_MAX then break end
            fresh[#fresh + 1] = p
        end
        posts = fresh
        self.index_store:saveSetting("posts", posts)
        self.index_store:flush()
    end
    return posts
end

-- Texto completo dos posts salvos (funciona offline)
function TabNews:searchSaved(q)
    local words = {}
    for w in Search.fold(q):gmatch("%S+") do words[#words + 1] = w end
    local found = {}
    for path, info in pairs(self.saved) do
        if not info.edition then
            local f = io.open(path, "r")
            if f then
                local text = Search.fold(f:read("*a"):gsub("<[^>]+>", " "))
                f:close()
                local ok = true
                for _i, w in ipairs(words) do
                    if not text:find(w, 1, true) then ok = false; break end
                end
                if ok then
                    found[#found + 1] = {
                        path = path, title = info.title, owner_username = info.user or info.author,
                        slug = info.slug, id = info.id,
                    }
                end
            end
        end
    end
    table.sort(found, function(a, b) return str(a.title) < str(b.title) end)
    return found
end

function TabNews:search(q)
    self.last_query = q
    local online = isConnected()
    local web, index = {}, nil
    if online then
        local msg = loading(string.format(_("Buscando “%s” na web…"), q))
        web = self:searchWeb(q)
        UIManager:close(msg)
        index = self:updateIndex()
    else
        index = self:loadIndex()
    end

    -- ordem: web (todo o histórico) → posts salvos (texto completo) → índice (títulos)
    local results, seen = {}, {}
    local function add(list)
        for _i, post in ipairs(list) do
            local key = post.path or self:postPath(post)
            if not seen[key] then
                seen[key] = true
                results[#results + 1] = post
            end
        end
    end
    add(web)
    add(self:searchSaved(q))
    add(Search.matchIndex(index, q, 50))

    if #results == 0 then
        return alert(string.format(_("Nada encontrado para “%s”.\n(%d títulos no índice%s)"), q, #index,
            not online and _(", sem Wi-Fi") or (#web == 0 and _(", busca na web indisponível") or "")))
    end
    local items = {}
    for _i, post in ipairs(results) do
        local path = post.path or self:postPath(post)
        local info = self.saved[path]
        local saved = info and lfs.attributes(path, "mode") == "file"
        table.insert(items, {
            text = (saved and "✓ " or "") .. str(post.title),
            mandatory = "@" .. str(post.owner_username) .. (saved and info.minutes and
                string.format(" · %d min", info.minutes) or ""),
            callback = function()
                if saved then self:openFile(path) else self:openPost(post) end
            end,
            hold_callback = function() self:postActions(post) end,
        })
    end
    local title = string.format(_("Busca: %s (%d)"), q, #results)
    if not online then
        title = title .. _(" · offline")
    elseif #web == 0 then
        title = title .. _(" · só títulos")
    end
    self:showMenu(title, items)
end

-- Post aberto no leitor ------------------------------------------------------

function TabNews:currentPost()
    local doc = self.ui and self.ui.document
    local file = doc and doc.file
    local name = file and file:match("/tabnews/([^/]+)%.html$")
    if not name then return nil end
    local path = POSTS_DIR .. "/" .. name .. ".html"
    local info = self.saved[path] or {}
    if info.edition or name:match("^edicao%-") then
        return { path = path, name = name, info = info, edition = true }
    end
    local user, slug = info.user, info.slug
    if not slug then
        -- posts salvos em versões antigas: recupera usuário e slug pelo nome do arquivo
        user, slug = name:match("^([^_]+)_(.+)$")
    end
    return { path = path, name = name, info = info, user = user, slug = slug }
end

function TabNews:refreshCurrent()
    local cur = self:currentPost()
    if not cur or not cur.slug then
        return alert(_("Abra um post do TabNews para usar esta opção."))
    end
    NetworkMgr:runWhenOnline(function()
        local before = cur.info.comments
        local msg = loading(_("Atualizando post…"))
        local ok, err = self:downloadPost({ owner_username = cur.user, slug = cur.slug }, cur.path)
        UIManager:close(msg)
        if not ok then
            return alert(_("Não foi possível atualizar: ") .. tostring(err))
        end
        local after = self.saved[cur.path].comments or 0
        local text
        if before and after > before then
            text = string.format(_("%d comentário(s) novo(s)."), after - before)
        elseif before then
            text = _("Nenhum comentário novo.")
        else
            text = string.format(_("Post atualizado: %d comentários."), after)
        end
        self.ui:reloadDocument()
        UIManager:scheduleIn(1.5, function() alert(text, 3) end)
    end)
end

-- Conta e tabcoins -----------------------------------------------------------

-- Sessão válida (o TabNews dá 30 dias); a senha nunca é guardada, só o token
function TabNews:sessionInfo()
    local s = self.session
    if type(s) ~= "table" or str(s.token) == "" then return nil end
    if str(s.expires_at) ~= "" and s.expires_at < os.date("!%Y-%m-%dT%H:%M:%S") then
        self.session = nil
        self:saveState()
        return nil
    end
    return s
end

function TabNews:askLogin(after)
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Entrar no TabNews"),
        fields = {
            { description = _("Email"), text = "", hint = _("seu@email.com") },
            { description = _("Senha"), text = "", hint = _("senha"), text_type = "password" },
        },
        buttons = {{
            { text = _("Cancelar"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Entrar"),
                callback = function()
                    local fields = dialog:getFields()
                    UIManager:close(dialog)
                    self:login(fields[1], fields[2], after)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function TabNews:login(email, password, after)
    email = str(email):gsub("^%s+", ""):gsub("%s+$", "")
    if email == "" or str(password) == "" then
        return alert(_("Preencha email e senha."))
    end
    NetworkMgr:runWhenOnline(function()
        local msg = loading(_("Entrando…"))
        local body = '{"email":' .. jsonString(email) .. ',"password":' .. jsonString(password) .. "}"
        local resp, err = httpRequest(API .. "/sessions", {
            accept = "application/json", body = body, content_type = "application/json",
        })
        local data = decodeJSON(resp)
        if not data or str(data.token) == "" then
            UIManager:close(msg)
            return alert(_("Não foi possível entrar: ") .. tostring(err or "resposta inesperada"))
        end
        local me = fetchJSON(API .. "/user", "session_id=" .. data.token)
        UIManager:close(msg)
        self.session = {
            token = data.token,
            expires_at = str(data.expires_at),
            username = me and str(me.username) or "",
        }
        self:saveState()
        alert(string.format(_("Conectado como @%s."), self.session.username), 2)
        if after then UIManager:scheduleIn(2.5, after) end
    end)
end

function TabNews:logout()
    self.session = nil
    self:saveState()
    alert(_("Você saiu da conta TabNews."), 2)
end

function TabNews:voteCurrent(kind)
    local cur = self:currentPost()
    if not cur or not cur.slug then
        return alert(_("Abra um post do TabNews para votar."))
    end
    local session = self:sessionInfo()
    if not session then
        return self:askLogin(function() self:voteCurrent(kind) end)
    end
    NetworkMgr:runWhenOnline(function()
        local resp, err, code = httpRequest(string.format("%s/contents/%s/%s/tabcoins", API, cur.user, cur.slug), {
            accept = "application/json",
            body = '{"transaction_type":"' .. kind .. '"}',
            content_type = "application/json",
            cookie = "session_id=" .. session.token,
        })
        if not resp then
            if code == 401 then
                self.session = nil
                self:saveState()
                return alert(_("Sua sessão expirou. Entre de novo e tente outra vez."))
            end
            return alert(_("Não foi possível votar: ") .. tostring(err))
        end
        local data = decodeJSON(resp)
        local total = data and data.tabcoins
        local text = kind == "credit" and _("+1 tabcoin para o post!") or _("−1 tabcoin para o post.")
        if type(total) == "number" then
            text = text .. "\n" .. string.format(_("Agora ele tem %d tabcoins."), total)
        end
        alert(text, 3)
    end)
end

return TabNews
