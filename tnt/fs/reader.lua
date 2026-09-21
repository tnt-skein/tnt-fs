--- Чтение файла кусками: в памяти лежит один кусок, а не файл целиком.
---
---     local reader, err = fs.reader('/var/lib/app/export.csv', { chunk = 1024 * 1024 })
---
---     while true do
---         local chunk, failure = reader:read()
---
---         if chunk == nil then
---             return failure == nil, failure   -- nil без отказа — файл кончился
---         end
---
---         send(chunk)
---     end
---
--- `fs.read` отдаёт файл строкой, и файл в сотни мегабайт — сотни мегабайт
--- памяти узла. Здесь кусок читается пулом нитей `fio` с уступкой, как
--- и всё в пакете, и сосед получает управление на каждом куске.
---
--- Исходы чтения: кусок — непустая строка; `nil` без отказа — файл
--- кончился, и файл закрыт; `nil, err` — отказ, и файл закрыт тоже.
--- Читать после конца можно: вернётся то же, чем чтение кончилось.
--- Чтение после `close` — ошибка программиста.
---
--- Читатель — одного файбера: `fio` уступает на каждом куске, и два
--- файбера, читающие один читатель, делили бы куски как придётся.

local failure = require('tnt.fs.failure')
local must = require('tnt.must')
local system = require('tnt.fs.system')

local Module = {}

--- Кусок по умолчанию: 64 КБ.
---
--- Кусок меньше — больше обращений к пулу нитей на тот же файл; больше —
--- больше памяти на каждого читателя, а читателей у узла, раздающего
--- файлы, столько же, сколько идущих раздач.
Module.CHUNK = 64 * 1024

--- Самый большой кусок: 64 МБ. Кусок больше — это уже чтение целиком,
--- и для него есть `fs.read`.
Module.MAX_CHUNK = 64 * 1024 * 1024

--- Настройки читателя.
local OPTIONS = { chunk = { '?between', 1, Module.MAX_CHUNK } }

--- Читатель открыт.
local OPEN = 'open'

--- Чтение кончилось: файл дочитан либо отказал.
local ENDED = 'ended'

--- Читатель закрыт вызывающим.
local CLOSED = 'closed'

---@class TntFsReaderOptions
---@field chunk integer|nil Сколько байт читать за раз, от 1 до 64 МБ; по умолчанию 64 КБ

---@class TntFsReader Чтение файла кусками
---@field path string Что читается
---@field handle any Ручка файла
---@field chunk integer Кусок
---@field state string open, ended либо closed
---@field failure TntFsFailure|nil Отказ, которым кончилось чтение
local Reader = {}
Reader.__index = Reader

--- Открывает файл на чтение кусками.
---
--- Файла нет — отказ сразу, а не на первом чтении: «нечего читать»
--- вызывающий узнаёт до того, как ответит клиенту кодом 200.
---@param path string
---@param opts TntFsReaderOptions|nil
---@return TntFsReader|nil reader
---@return TntFsFailure|nil err
function Module.open(path, opts)
    local caller = must.at(2)

    caller.string(path, 'путь')
    caller.optional.options(opts, 'настройки', OPTIONS)

    local handle, err = system.fio().open(path, { 'O_RDONLY' })

    if handle == nil then
        return nil, failure.from(('файл %s не открыт на чтение'):format(path), path, err)
    end

    return setmetatable({
        path = path,
        handle = handle,
        chunk = (opts or {}).chunk or Module.CHUNK,
        state = OPEN,
    }, Reader)
end

--- Следующий кусок.
---@return string|nil chunk Непустой кусок; nil — файл кончился либо отказ
---@return TntFsFailure|nil err
function Reader:read()
    if self.state == CLOSED then
        error(('read: читатель файла %s уже закрыт'):format(self.path), 2)
    end

    if self.state == ENDED then
        return nil, self.failure
    end

    local chunk, err = self.handle:read(self.chunk)

    if chunk ~= nil and chunk ~= '' then
        return chunk
    end

    self.handle:close()
    self.state = ENDED

    if chunk == nil then
        self.failure = failure.from(('файл %s не прочитан'):format(self.path), self.path, err)
    end

    return nil, self.failure
end

--- Переливает читателя в писателя кусками и кончает запись.
---
--- Годится всякая пара с договором этого пакета: читатель — `read()`,
--- отдающий кусок, `nil` в конце либо `nil, err`, и `close()`; писатель —
--- `write(кусок)`, `finish()` и `abort()`. Так файл уходит объектом S3,
--- объект ложится файлом, а файл — другим файлом, и в памяти лежит один
--- кусок.
---
--- Отказ чтения бросает запись (`abort`), отказ записи закрывает читателя;
--- приходит сам отказ как есть. Удача — то, что вернул `finish` писателя.
---@param reader any Читатель: `read()` и `close()`
---@param writer any Писатель: `write(кусок)`, `finish()` и `abort()`
---@return any done Что вернул `finish` писателя
---@return any err
function Module.pipe(reader, writer)
    local caller = must.at(2)

    caller.table(reader, 'читатель')
    caller.table(writer, 'писатель')

    while true do
        local chunk, err = reader:read()

        if chunk == nil and err ~= nil then
            writer:abort()

            return nil, err
        end

        if chunk == nil then
            return writer:finish()
        end

        local written, write_err = writer:write(chunk)

        if not written then
            reader:close()

            return nil, write_err
        end
    end
end

--- Закрывает файл. Повторно и после конца — ничего не делает.
---@return true
function Reader:close()
    if self.state == OPEN then
        self.handle:close()
    end

    self.state = CLOSED

    return true
end

return Module
