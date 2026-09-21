--- Общие средства проверок файловой системы.
---
--- Проверки идут на настоящем диске, в своём временном каталоге: пакет —
--- тонкий слой над `fio`, и двойник диска проверял бы, что мы правильно
--- разговариваем сами с собой. Двойник берётся только там, где настоящий
--- диск отказа не даст: кончилось место, не сбросился файл, не закрылся.
---
--- Исходники грузятся с диска, а не через `require`: у Tarantool свой
--- загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Поэтому
--- файлы читаются сами, в порядке зависимостей, и кладутся
--- в `package.loaded` под именами модулей: `require` изнутри пакета
--- находит их первыми. Зависимости — `tnt-must` и `tnt-external` —
--- берутся установленными из `.rocks` обычным `require`.

local fiber = require('fiber')
local fio = require('fio')
local t = require('luatest')

local helper = {}

--- Модули пакета в порядке зависимостей.
helper.MODULES = {
    { name = 'tnt.fs.failure', path = 'tnt/fs/failure.lua' },
    { name = 'tnt.fs.system', path = 'tnt/fs/system.lua' },
    { name = 'tnt.fs.file', path = 'tnt/fs/file.lua' },
    { name = 'tnt.fs.tree', path = 'tnt/fs/tree.lua' },
    { name = 'tnt.fs.temp', path = 'tnt/fs/temp.lua' },
    { name = 'tnt.fs', path = 'tnt/fs.lua' },
}

--- Части пакета: имя модуля → его таблица.
---
--- Грузятся один раз на процесс: состояния у пакета нет, кроме внешних
--- зависимостей, а их проверки возвращают сами (`restore`). Цена
--- перезагрузки заметная: мутационный прогон гоняет набор тысячи раз.
---@type table<string, any>
local PARTS = {}

for _, module in ipairs(helper.MODULES) do
    local chunk, failure = loadfile(fio.abspath(module.path))

    if chunk == nil then
        error(('исходник %s не читается: %s'):format(module.name, tostring(failure)))
    end

    local value = chunk()

    -- Пустое значение в `package.loaded` для `require` значит «не загружен»,
    -- и следующий модуль списка молча взял бы зависимость из `.rocks`.
    if value == nil then
        error(('исходник %s не вернул модуль'):format(module.name))
    end

    package.loaded[module.name] = value
    PARTS[module.name] = value
end

--- Фасад пакета из исходников.
helper.fs = PARTS['tnt.fs']

--- Отказы пакета из той же загрузки.
helper.failure = PARTS['tnt.fs.failure']

--- Права строкой восьмеричного числа: `'640'` и подобные.
---@param mode number
---@return string
function helper.octal(mode)
    return ('%o'):format(mode)
end

--- Права по восьмеричной записи.
---@param text string Например `'640'`
---@return integer
function helper.mode(text)
    return tonumber(text, 8) --[[@as integer]]
end

---@class TntFsSandbox
---@field root string Каталог проверки
---@field umask number Прежняя маска прав процесса

--- Заводит каталог проверки и ставит маску прав `022`.
---
--- Маска ставится явно: права новых файлов сверяются числом, а маска
--- у машины, на которой гоняют проверки, бывает любой.
---@return TntFsSandbox
function helper.sandbox()
    local root = fio.tempdir()

    return {
        root = root,
        umask = fio.umask(helper.mode('022')),
    }
end

--- Сносит каталог проверки, возвращает маску и настоящие средства пакета.
---@param sandbox TntFsSandbox
function helper.restore(sandbox)
    helper.fs._set_source(nil)
    fio.umask(sandbox.umask)
    fio.rmtree(sandbox.root)
end

--- Каталог действующей проверки.
---@type TntFsSandbox
local current

--- Группа проверок, у каждой из которых свой каталог: заводится перед
--- проверкой и сносится после неё вместе с подменой средств.
---@param name string
---@return table
function helper.group(name)
    local g = t.group(name)

    g.before_each(function()
        current = helper.sandbox()
    end)

    g.after_each(function()
        helper.restore(current)
    end)

    return g
end

--- Каталог действующей проверки.
---@return string
function helper.root()
    return current.root
end

--- Путь внутри каталога действующей проверки.
---@param name string
---@return string
function helper.file(name)
    return fio.pathjoin(current.root, name)
end

--- Подменяет в `fio` пакета названные действия; прочее остаётся настоящим.
---@param replaced table<string, function>
function helper.with_fio(replaced)
    helper.fs._set_source({ fio = helper.fio(replaced) })
end

--- Подсовывает пакету вместо всякого открытия одну и ту же ручку.
---@param answers table<string, any[]> Действие ручки — что ответить списком
---@return string[] calls Действия ручки по порядку; пополняется
function helper.opening(answers)
    local handle, calls = helper.handle(answers)

    helper.with_fio({
        open = function()
            return handle
        end,
    })

    return calls
end

---@class TntFsNeighbour
---@field ticks integer Сколько раз сосед получил управление
---@field stop fun() Остановить соседа

--- Соседний файбер, который считает, сколько раз получил управление.
---
--- Ноль тиков за действие значит, что действие держало узел: ждало
--- диска в потоке событий, не уступая.
---@return TntFsNeighbour
function helper.neighbour()
    local neighbour = { ticks = 0 }
    local stopped = false

    fiber.create(function()
        while not stopped do
            neighbour.ticks = neighbour.ticks + 1
            fiber.yield()
        end
    end)

    function neighbour.stop()
        stopped = true
    end

    return neighbour
end

--- Сверяет, что каждый вызов бросает названный отказ и винит строку
--- в файле проверок, а не внутри пакета.
---@param cases table[] Пары: вызов и часть текста броска
function helper.assert_blamed(cases)
    local place = helper.caller_file() .. ':'

    for _, case in ipairs(cases) do
        local _, err = pcall(case[1])

        t.assert_str_contains(tostring(err), case[2])
        t.assert_str_contains(tostring(err), place)
    end
end

--- Кладёт файл настоящим `fio`, мимо пакета.
---@param path string
---@param content string
---@param mode string|nil Права восьмеричной записью; по умолчанию `'644'`
function helper.put(path, content, mode)
    fio.mktree(fio.dirname(path))

    local file = fio.open(path, { 'O_WRONLY', 'O_CREAT', 'O_TRUNC' }, helper.mode(mode or '644'))

    file:write(content)
    file:close()
end

--- Читает файл настоящим `fio`, мимо пакета.
---@param path string
---@return string|nil
function helper.get(path)
    local file = fio.open(path, { 'O_RDONLY' })

    if file == nil then
        return nil
    end

    local content = file:read()

    file:close()

    return content
end

--- Права пути восьмеричной записью.
---@param path string
---@return string
function helper.mode_of(path)
    return helper.octal(fio.stat(path).mode % 4096)
end

--- Отказ, каким его отдают простые действия `fio`: объект с кодом.
---@param code integer
---@return table
function helper.refusal(code)
    return { errno = code }
end

--- Подменяет в `fio` названные действия; прочее остаётся настоящим.
---@param replaced table<string, function>
---@return table
function helper.fio(replaced)
    return setmetatable(replaced, { __index = fio })
end

--- Ручка файла, у которой запись, сброс и закрытие отвечают заданным.
---
--- Каждое действие записывается: проверке важно, что файл закрыт при
--- всяком исходе и что сброс не зовут после неудачной записи.
---@param answers table<string, any[]> Действие — что ответить списком
---@return table handle
---@return string[] calls Действия по порядку; пополняется
function helper.handle(answers)
    local calls = {}
    local handle = {}

    for _, name in ipairs({ 'write', 'fsync', 'close', 'read' }) do
        handle[name] = function()
            table.insert(calls, name)

            return unpack(answers[name] or { true })
        end
    end

    return handle, calls
end

--- Негодный аргумент — нарочно.
---
--- Анализатор типов о таком намерении знать не может и справедливо
--- ругается на каждую такую строку.
---@param value any
---@return any
function helper.wrong(value)
    return value
end

--- Номер строки, с которой позвали эту функцию: на неё обязан указать
--- бросок.
---@return integer
function helper.here()
    return (debug.getinfo(2, 'l') --[[@as { currentline: integer }]]).currentline
end

--- Место, которое бросок обязан назвать: этот файл проверок и строка.
---@param line integer
---@return string
function helper.at(line)
    return ('%s:%d: '):format((debug.getinfo(2, 'S') --[[@as { short_src: string }]]).short_src, line)
end

--- Имя файла проверок, откуда позвали того, кто зовёт эту функцию, —
--- так, как его называет место в тексте броска.
---@return string
function helper.caller_file()
    return (debug.getinfo(3, 'S') --[[@as { short_src: string }]]).short_src
end

return helper
