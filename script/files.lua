local platform = require 'bee.platform'
local config   = require 'config'
local glob     = require 'glob'
local furi     = require 'file-uri'
local parser   = require 'parser'
local proto    = require 'proto'
local lang     = require 'language'
local await    = require 'await'
local timer    = require 'timer'
local plugin   = require 'plugin'
local util     = require 'utility'
local guide    = require 'parser.guide'
local smerger  = require 'string-merger'
local progress = require "progress"
local client   = require 'client'

local unicode

if platform.OS == 'Windows' then
    unicode  = require 'bee.unicode'
end

---@class files
local m = {}

m.openMap        = {}
m.libraryMap     = {}
m.fileMap        = {}
m.dllMap         = {}
m.watchList      = {}
m.notifyCache    = {}
m.visible        = {}
m.assocVersion   = -1
m.assocMatcher   = nil
m.globalVersion  = 0
m.fileCount      = 0
m.astCount       = 0
m.linesMap       = setmetatable({}, { __mode = 'v' })
m.originLinesMap = setmetatable({}, { __mode = 'v' })
m.astMap         = {} -- setmetatable({}, { __mode = 'v' })

--- 打开文件
---@param uri uri
function m.open(uri)
    m.openMap[uri] = {
        cache = {},
    }
    m.onWatch('open', uri)
end

--- 关闭文件
---@param uri uri
function m.close(uri)
    m.openMap[uri] = nil
    local file = m.fileMap[uri]
    if file then
        file.trusted = false
    end
    m.onWatch('close', uri)
end

--- 是否打开
---@param uri uri
---@return boolean
function m.isOpen(uri)
    return m.openMap[uri] ~= nil
end

function m.getOpenedCache(uri)
    local data = m.openMap[uri]
    if not data then
        return nil
    end
    return data.cache
end

--- 标记为库文件
function m.setLibraryPath(uri, libraryPath)
    m.libraryMap[uri] = libraryPath
end

--- 是否是库文件
function m.isLibrary(uri)
    return m.libraryMap[uri] ~= nil
end

--- 获取库文件的根目录
function m.getLibraryPath(uri)
    return m.libraryMap[uri]
end

function m.flushAllLibrary()
    m.libraryMap = {}
end

--- 是否存在
---@return boolean
function m.exists(uri)
    return m.fileMap[uri] ~= nil
end

local function pluginOnSetText(file, text)
    file._diffInfo = nil
    local suc, result = plugin.dispatch('OnSetText', file.uri, text)
    if not suc then
        if DEVELOP and result then
            util.saveFile(LOGPATH .. '/diffed.lua', tostring(result))
        end
        return text
    end
    if type(result) == 'string' then
        return result
    elseif type(result) == 'table' then
        local diffs
        suc, result, diffs = xpcall(smerger.mergeDiff, log.error, text, result)
        if suc then
            file._diffInfo = diffs
            return result
        else
            if DEVELOP and result then
                util.saveFile(LOGPATH .. '/diffed.lua', tostring(result))
            end
        end
    end
    return text
end

--- 设置文件文本
---@param uri uri
---@param text string
function m.setText(uri, text, isTrust, instance)
    if not text then
        return
    end
    --log.debug('setText', uri)
    local create
    if not m.fileMap[uri] then
        m.fileMap[uri] = {
            uri = uri,
            version = 0,
        }
        m.fileCount = m.fileCount + 1
        create = true
        m._pairsCache = nil
    end
    local file = m.fileMap[uri]
    if file.trusted and not isTrust then
        return
    end
    if not isTrust and unicode then
        if config.get 'Lua.runtime.fileEncoding' == 'ansi' then
            text = unicode.a2u(text)
        end
    end
    if file.originText == text then
        return
    end
    local newText = pluginOnSetText(file, text)
    file.text       = newText
    file.trusted    = isTrust
    file.originText = text
    file.words      = nil
    m.linesMap[uri] = nil
    m.originLinesMap[uri] = nil
    m.astMap[uri] = nil
    file.cache = {}
    file.cacheActiveTime = math.huge
    file.version = file.version + 1
    m.globalVersion = m.globalVersion + 1
    await.close('files.version')
    m.onWatch('version')
    if create then
        m.onWatch('create', uri)
    end
    if DEVELOP then
        if text ~= newText then
            util.saveFile(LOGPATH .. '/diffed.lua', newText)
        end
    end

    if instance or TEST then
        m.onWatch('update', uri)
    else
        await.call(function ()
            await.close('update:' .. uri)
            await.setID('update:' .. uri)
            await.sleep(0.2)
            if m.exists(uri) then
                m.onWatch('update', uri)
            end
        end)
    end
end

function m.resetText(uri)
    local file = m.fileMap[uri]
    local originText = file.originText
    file.originText = nil
    m.setText(uri, originText, file.trusted)
end

function m.setRawText(uri, text)
    if not text then
        return
    end
    local file = m.fileMap[uri]
    file.text             = text
    file.originText       = text
    m.linesMap[uri]       = nil
    m.originLinesMap[uri] = nil
    m.astMap[uri]         = nil
end

function m.getCachedRows(uri)
    local file = m.fileMap[uri]
    if not file then
        return nil
    end
    return file.rows
end

function m.setCachedRows(uri, rows)
    local file = m.fileMap[uri]
    if not file then
        return
    end
    file.rows = rows
end

function m.getWords(uri)
    local file = m.fileMap[uri]
    if not file then
        return
    end
    if file.words then
        return file.words
    end
    local words = {}
    file.words = words
    local text = file.text
    if not text then
        return
    end
    local mark = {}
    for word in text:gmatch '([%a_][%w_]+)' do
        if #word >= 3 and not mark[word] then
            mark[word] = true
            local head = word:sub(1, 2)
            if not words[head] then
                words[head] = {}
            end
            words[head][#words[head]+1] = word
        end
    end
    return words
end

function m.getWordsOfHead(uri, head)
    local file = m.fileMap[uri]
    if not file then
        return nil
    end
    local words = m.getWords(uri)
    if not words then
        return nil
    end
    return words[head]
end

--- 获取文件版本
function m.getVersion(uri)
    local file = m.fileMap[uri]
    if not file then
        return nil
    end
    return file.version
end

--- 获取文件文本
---@param uri uri
---@return string text
function m.getText(uri)
    local file = m.fileMap[uri]
    if not file then
        return nil
    end
    return file.text
end

--- 获取文件原始文本
---@param uri uri
---@return string text
function m.getOriginText(uri)
    local file = m.fileMap[uri]
    if not file then
        return nil
    end
    return file.originText
end

function m.getChildFiles(uri)
    local results = {}
    local uris = m.getAllUris()
    for _, curi in ipairs(uris) do
        if  #curi > #uri
        and curi:sub(1, #uri) == uri
        and curi:sub(#uri+1, #uri+1):match '[/\\]' then
            results[#results+1] = curi
        end
    end
    return results
end

--- 移除文件
---@param uri uri
function m.remove(uri)
    local originUri = uri
    local file = m.fileMap[uri]
    if not file then
        return
    end
    m.fileMap[uri]        = nil
    m.astMap[uri]         = nil
    m.linesMap[uri]       = nil
    m.originLinesMap[uri] = nil
    m._pairsCache         = nil
    m.flushFileCache(uri)

    m.fileCount     = m.fileCount - 1
    m.globalVersion = m.globalVersion + 1

    await.close('files.version')
    m.onWatch('version')
    m.onWatch('remove', originUri)
end

--- 移除所有文件
function m.removeAll()
    local ws = require 'workspace.workspace'
    m.globalVersion = m.globalVersion + 1
    await.close('files.version')
    m.onWatch('version')
    m._pairsCache = nil
    for uri in pairs(m.fileMap) do
        if not m.libraryMap[uri] then
            m.fileCount     = m.fileCount - 1
            m.fileMap[uri]  = nil
            m.astMap[uri]   = nil
            m.linesMap[uri] = nil
            m.onWatch('remove', uri)
        end
    end
    ws.flushCache()
    --m.notifyCache = {}
end

--- 移除所有关闭的文件
function m.removeAllClosed()
    m.globalVersion = m.globalVersion + 1
    await.close('files.version')
    m.onWatch('version')
    m._pairsCache = nil
    for uri in pairs(m.fileMap) do
        if  not m.openMap[uri]
        and not m.libraryMap[uri] then
            m.fileCount     = m.fileCount - 1
            m.fileMap[uri]  = nil
            m.astMap[uri]   = nil
            m.linesMap[uri] = nil
            m.onWatch('remove', uri)
        end
    end
    --m.notifyCache = {}
end

--- 获取一个包含所有文件uri的数组
---@return uri[]
function m.getAllUris()
    local files = m._pairsCache
    local i = 0
    if not files then
        files = {}
        m._pairsCache = files
        for uri in pairs(m.fileMap) do
            i = i + 1
            files[i] = uri
        end
        table.sort(files)
    end
    return m._pairsCache
end

--- 遍历文件
function m.eachFile()
    local files = m.getAllUris()
    local i = 0
    return function ()
        i = i + 1
        local uri = files[i]
        while not m.fileMap[uri] do
            i = i + 1
            uri = files[i]
            if not uri then
                return nil
            end
        end
        return files[i]
    end
end

--- Pairs dll files
---@return function
function m.eachDll()
    local map = {}
    for uri, file in pairs(m.dllMap) do
        map[uri] = file
    end
    return pairs(map)
end

function m.compileState(uri, text)
    local ws = require 'workspace'
    if  not m.isOpen(uri)
    and not m.isLibrary(uri)
    and #text >= config.get 'Lua.workspace.preloadFileSize' * 1000 then
        if not m.notifyCache['preloadFileSize'] then
            m.notifyCache['preloadFileSize'] = {}
            m.notifyCache['skipLargeFileCount'] = 0
        end
        if not m.notifyCache['preloadFileSize'][uri] then
            m.notifyCache['preloadFileSize'][uri] = true
            m.notifyCache['skipLargeFileCount'] = m.notifyCache['skipLargeFileCount'] + 1
            local message = lang.script('WORKSPACE_SKIP_LARGE_FILE'
                        , ws.getRelativePath(uri)
                        , config.get 'Lua.workspace.preloadFileSize'
                        , #text / 1000
                    )
            if m.notifyCache['skipLargeFileCount'] <= 1 then
                client.showMessage('Info', message)
            else
                client.logMessage('Info', message)
            end
        end
        return nil
    end
    local prog <close> = progress.create(lang.script.WINDOW_COMPILING, 0.5)
    prog:setMessage(ws.getRelativePath(uri))
    local clock = os.clock()
    local state, err = parser:compile(text
        , 'lua'
        , config.get 'Lua.runtime.version'
        , {
            special           = config.get 'Lua.runtime.special',
            unicodeName       = config.get 'Lua.runtime.unicodeName',
            nonstandardSymbol = config.get 'Lua.runtime.nonstandardSymbol',
            delay             = await.delay,
        }
    )
    local passed = os.clock() - clock
    if passed > 0.1 then
        log.warn(('Compile [%s] takes [%.3f] sec, size [%.3f] kb.'):format(uri, passed, #text / 1000))
    end
    --await.delay()
    if state then
        state.uri = uri
        state.ast.uri = uri
        local clock = os.clock()
        parser:luadoc(state)
        local passed = os.clock() - clock
        if passed > 0.1 then
            log.warn(('Parse LuaDoc of [%s] takes [%.3f] sec, size [%.3f] kb.'):format(uri, passed, #text / 1000))
        end
        m.astCount = m.astCount + 1
        local removed
        setmetatable(state, {__gc = function ()
            if removed then
                return
            end
            removed = true
            m.astCount = m.astCount - 1
        end})
        return state
    else
        log.error('Compile failed:', uri, err)
        return nil
    end
end

--- 获取文件语法树
---@param uri uri
---@return table state
function m.getState(uri)
    if uri ~= '' and not m.isLua(uri) then
        return nil
    end
    local file = m.fileMap[uri]
    if not file then
        return nil
    end
    local ast = m.astMap[uri]
    if not ast then
        ast = m.compileState(uri, file.text)
        m.astMap[uri] = ast
        --await.delay()
    end
    file.cacheActiveTime = timer.clock()
    return ast
end

---设置文件的当前可见范围
---@param uri    uri
---@param ranges range[]
function m.setVisibles(uri, ranges)
    m.visible[uri] = ranges
    m.onWatch('updateVisible', uri)
end

---获取文件的当前可见范围
---@param uri uri
---@return table[]
function m.getVisibles(uri)
    local file = m.fileMap[uri]
    if not file then
        return nil
    end
    local ranges = m.visible[uri]
    if not ranges or #ranges == 0 then
        return nil
    end
    local visibles = {}
    for i, range in ipairs(ranges) do
        local start, finish = m.unrange(uri, range)
        visibles[i] = {
            start  = start,
            finish = finish,
        }
    end
    return visibles
end

--- 获取文件行信息
---@param uri uri
---@return table lines
function m.getLines(uri)
    local file = m.fileMap[uri]
    if not file then
        return nil
    end
    local lines = m.linesMap[uri]
    if not lines then
        lines = parser:lines(file.text)
        m.linesMap[uri] = lines
    end
    return lines
end

function m.getOriginLines(uri)
    local file = m.fileMap[uri]
    if not file then
        return nil
    end
    local lines = m.originLinesMap[uri]
    if not lines then
        lines = parser:lines(file.originText)
        m.originLinesMap[uri] = lines
    end
    return lines
end

function m.getFile(uri)
    return m.fileMap[uri]
        or m.dllMap[uri]
end

---@param text string
local function isNameChar(text)
    if text:match '^[\xC2-\xFD][\x80-\xBF]*$' then
        return true
    end
    if text:match '^[%w_]+$' then
        return true
    end
    return false
end

---@alias position table

--- 获取 position 对应的光标位置
---@param uri      uri
---@param position position
---@param isFinish? boolean
---@return integer
function m.offset(uri, position, isFinish)
    local file  = m.getFile(uri)
    local lines = m.getLines(uri)
    local text  = m.getText(uri)
    if not file then
        return 0
    end
    if file._diffInfo then
        lines = m.getOriginLines(uri)
        text  = m.getOriginText(uri)
    end
    local row = position.line + 1
    local start, finish, char
    if row > #lines then
        start, finish = guide.lineRange(lines, #lines)
        start = start + 1
        char = util.utf8Len(text, start, finish)
    else
        start, finish = guide.lineRange(lines, row)
        start = start + 1
        char = position.character
    end
    local utf8Len = util.utf8Len(text, start, finish)
    local offset
    if char <= 0 then
        offset = start
    else
        if char >= utf8Len then
            char = utf8Len
        end
        local left  = utf8.offset(text, char,     start)
        local right = utf8.offset(text, char + 1, start)
        if isFinish then
            offset = left
        else
            offset = right
        end
    end
    if file._diffInfo then
        local start, finish = smerger.getOffset(file._diffInfo, offset)
        if isFinish then
            offset = finish
        else
            offset = start
        end
    end
    return offset
end

--- 获取 position 对应的光标位置(根据附近的单词)
---@param uri uri
---@param position position
---@return integer
function m.offsetOfWord(uri, position)
    local file  = m.getFile(uri)
    local lines = m.getLines(uri)
    local text  = m.getText(uri)
    if not file then
        return 0
    end
    if file._diffInfo then
        lines = m.getOriginLines(uri)
        text  = m.getOriginText(uri)
    end
    local row = position.line + 1
    local start, finish, char
    if row > #lines then
        start, finish = guide.lineRange(lines, #lines)
        start = start + 1
        char = util.utf8Len(text, start, finish)
    else
        start, finish = guide.lineRange(lines, row)
        start = start + 1
        char = position.character
    end
    local utf8Len = util.utf8Len(text, start, finish)
    local offset
    if char <= 0 then
        offset = start
    else
        if char >= utf8Len then
            char = utf8Len
        end
        local left  = utf8.offset(text, char,     start)
        local right = utf8.offset(text, char + 1, start)
        if  isNameChar(text:sub(left, right - 1))
        and not isNameChar(text:sub(right, right)) then
            offset = left
        else
            offset = right
        end
    end
    if file._diffInfo then
        offset = smerger.getOffset(file._diffInfo, offset)
    end
    return offset
end

--- 将应用差异前的offset转换为应用差异后的offset
---@param uri    uri
---@param offset integer
---@return integer start
---@return integer finish
function m.diffedOffset(uri, offset)
    local file = m.getFile(uri)
    if not file then
        return offset, offset
    end
    if not file._diffInfo then
        return offset, offset
    end
    return smerger.getOffset(file._diffInfo, offset)
end

--- 将应用差异后的offset转换为应用差异前的offset
---@param uri    uri
---@param offset integer
---@return integer start
---@return integer finish
function m.diffedOffsetBack(uri, offset)
    local file = m.getFile(uri)
    if not file then
        return offset, offset
    end
    if not file._diffInfo then
        return offset, offset
    end
    return smerger.getOffsetBack(file._diffInfo, offset)
end

--- 将光标位置转化为 position
---@param uri uri
---@param offset integer
---@param leftOrRight? '"left"'|'"right"'
---@return position
function m.position(uri, offset, leftOrRight)
    local file  = m.getFile(uri)
    local lines = m.getLines(uri)
    local text  = m.getText(uri)
    if not file then
        return {
            line      = 0,
            character = 0,
        }
    end
    if file._diffInfo then
        local start, finish = smerger.getOffsetBack(file._diffInfo, offset)
        if leftOrRight == 'right' then
            offset = finish
        else
            offset = start
        end
        lines  = m.getOriginLines(uri)
        text   = m.getOriginText(uri)
    end
    local row, col      = guide.positionOf(lines, offset)
    local start, finish = guide.lineRange(lines, row, true)
    start = start + 1
    if col <= finish - start + 1 then
        local ucol     = util.utf8Len(text, start, start + col - 1)
        if row < 1 then
            row = 1
        end
        if leftOrRight == 'left' and ucol > 0 then
            ucol = ucol - 1
        end
        return {
            line      = row - 1,
            character = ucol,
        }
    else
        return {
            line      = row - 1,
            character = util.utf8Len(text, start, finish),
        }
    end
end

--- 将起点与终点位置转化为 range
---@alias range table
---@param uri     uri
---@param offset1 integer
---@param offset2 integer
function m.range(uri, offset1, offset2)
    local range = {
        start   = m.position(uri, offset1, 'left'),
        ['end'] = m.position(uri, offset2, 'right'),
    }
    return range
end

--- convert `range` to `offsetStart` and `offsetFinish`
---@param uri   table
---@param range table
---@return integer start
---@return integer finish
function m.unrange(uri, range)
    local start  = m.offset(uri, range.start, true)
    local finish = m.offset(uri, range['end'], false)
    return start, finish
end

--- 获取文件的自定义缓存信息（在文件内容更新后自动失效）
function m.getCache(uri)
    local file = m.fileMap[uri]
    if not file then
        return nil
    end
    --file.cacheActiveTime = timer.clock()
    return file.cache
end

--- 获取文件关联
function m.getAssoc()
    if m.assocVersion == config.get 'version' then
        return m.assocMatcher
    end
    m.assocVersion = config.get 'version'
    local patt = {}
    for k, v in pairs(config.get 'files.associations') do
        if v == 'lua' then
            patt[#patt+1] = k
        end
    end
    m.assocMatcher = glob.glob(patt)
    return m.assocMatcher
end

--- 判断是否是Lua文件
---@param uri uri
---@return boolean
function m.isLua(uri)
    local ext = uri:match '%.([^%.%/%\\]+)$'
    if not ext then
        return false
    end
    if ext == 'lua' then
        return true
    end
    local matcher = m.getAssoc()
    local path = furi.decode(uri)
    return matcher(path)
end

--- Does the uri look like a `Dynamic link library` ?
---@param uri uri
---@return boolean
function m.isDll(uri)
    local ext = uri:match '%.([^%.%/%\\]+)$'
    if not ext then
        return false
    end
    if platform.OS == 'Windows' then
        if ext == 'dll' then
            return true
        end
    else
        if ext == 'so' then
            return true
        end
    end
    return false
end

--- Save dll, makes opens and words, discard content
---@param uri uri
---@param content string
function m.saveDll(uri, content)
    if not content then
        return
    end
    local file = {
        uri   = uri,
        opens = {},
        words = {},
    }
    for word in content:gmatch 'luaopen_([%w_]+)' do
        file.opens[#file.opens+1] = word:gsub('_', '.')
    end
    if #file.opens == 0 then
        return
    end
    local mark = {}
    for word in content:gmatch '(%a[%w_]+)\0' do
        if word:sub(1, 3) ~= 'lua' then
            if not mark[word] then
                mark[word] = true
                file.words[#file.words+1] = word
            end
        end
    end

    m.dllMap[uri] = file
    m.onWatch('dll', uri)
end

---
---@param uri uri
---@return string[]|nil
function m.getDllOpens(uri)
    local file = m.dllMap[uri]
    if not file then
        return nil
    end
    return file.opens
end

---
---@param uri uri
---@return string[]|nil
function m.getDllWords(uri)
    local file = m.dllMap[uri]
    if not file then
        return nil
    end
    return file.words
end

--- 注册事件
function m.watch(callback)
    m.watchList[#m.watchList+1] = callback
end

function m.onWatch(ev, ...)
    for _, callback in ipairs(m.watchList) do
        callback(ev, ...)
    end
end

function m.flushCache()
    for uri, file in pairs(m.fileMap) do
        file.cacheActiveTime = math.huge
        m.linesMap[uri] = nil
        m.originLinesMap[uri] = nil
        m.astMap[uri] = nil
        file.cache = {}
    end
end

function m.flushFileCache(uri)
    local file = m.fileMap[uri]
    if not file then
        return
    end
    file.cacheActiveTime = math.huge
    m.linesMap[uri] = nil
    m.originLinesMap[uri] = nil
    m.astMap[uri] = nil
    file.cache = {}
end

function m.init()
    --TODO 可以清空文件缓存，之后看要不要启用吧
    --timer.loop(10, function ()
    --    local list = {}
    --    for _, file in pairs(m.fileMap) do
    --        if timer.clock() - file.cacheActiveTime > 10.0 then
    --            file.cacheActiveTime = math.huge
    --            file.ast = nil
    --            file.cache = {}
    --            list[#list+1] = file.uri
    --        end
    --    end
    --    if #list > 0 then
    --        log.info('Flush file caches:', #list, '\n', table.concat(list, '\n'))
    --        collectgarbage()
    --    end
    --end)
end

return m
