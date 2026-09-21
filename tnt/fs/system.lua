--- Внешние зависимости пакета: всё, чем он трогает систему.
---
--- Одно гнездо на весь пакет, а не по гнезду на модуль: чтение, запись
--- и каталоги ходят к одному и тому же `fio`, и проверка, подменившая его
--- у одного модуля, не должна молча оставить настоящий у соседа.
---
--- `fio` подменяется таблицей целиком, но проверке довольно назвать
--- одно действие — остальное берётся у настоящего:
---
---     fs._set_source({ fio = setmetatable({ rename = refuse }, { __index = fio }) })
---
--- Отказы, которых на исправном диске не вызвать, — кончилось место,
--- не сбросился файл, не закрылся, — видны только так.

local fio = require('fio')
local external = require('tnt.external')

---@class TntFsSystem
---@field _set_source fun(replacement: table|nil) Подмена средств — для проверок; ставит её `external.install`
local Module = {}

--- Случайная часть имени временного файла и каталога.
---
--- Восемь случайных байтов — шестнадцать знаков: два писателя одного
--- и того же файла не столкнутся именами временных, а имя, угаданное
--- заранее, не подсунет чужой файл на место временного.
---@return string
local function unique()
    local hex = require('digest').urandom(8):gsub('.', function(byte)
        return ('%02x'):format(byte:byte())
    end)

    return hex
end

--- Действующие средства.
---@type fun(): { fio: any, unique: fun(): string }
Module.current = external.install(Module, {
    fio = fio,
    unique = unique,
})

--- Действующий `fio`.
---@return any
function Module.fio()
    return Module.current().fio
end

return Module
