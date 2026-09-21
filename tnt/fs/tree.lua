--- Каталоги: сведения о пути, список, образец, дерево целиком.
---
--- Файлы по образцу ищутся не `fio.glob`: он зовёт системный `glob`
--- прямо в потоке событий и узел на это время стоит — замер на 3.8:
--- 20 000 файлов за 56 мс при нуле тиков соседнего файбера, а каталог
--- на подмороженной сетевой файловой системе не ответит вовсе. Здесь
--- каталог читает `fio.listdir` — пулом нитей, с уступкой, 5 671 тик соседа
--- за 11 мс на тех же файлах, — а имена сверяет Lua.
---
--- Снос дерева не идёт по ссылке. `fio.rmtree` по ссылке на каталог
--- вычищает каталог, на который она указывает, и только потом отказывает
--- на самой ссылке «Not a directory» (проверено на 3.8): уборка временной
--- ссылки стирала бы чужие данные. Здесь ссылка удаляется сама, как
--- у `rm -rf`.

local failure = require('tnt.fs.failure')
local must = require('tnt.must')
local system = require('tnt.fs.system')

local Module = {}

--- Настройки создания каталога.
local OPTIONS = { mode = { '?between', 0, 511 } }

---@class TntFsStat Сведения о пути
---@field kind string Что лежит: file, directory либо other
---@field size number Размер в байтах
---@field mode number Права: младшие двенадцать бит, `0644` и подобные
---@field mtime integer Время правки, целые секунды эпохи

---@class TntFsTreeOptions
---@field mode number|nil Права новых каталогов, от 0 до 511 (`0777`); по умолчанию `0777` за вычетом umask

--- Сведения о пути; ссылка раскрывается.
---@param path string
---@return TntFsStat|nil info
---@return TntFsFailure|nil err
local function inspect(path)
    local stat, err = system.fio().stat(path)

    if stat == nil then
        return nil, failure.from(('%s не опрошен'):format(path), path, err)
    end

    local kind = 'other'

    if stat:is_reg() then
        kind = 'file'
    elseif stat:is_dir() then
        kind = 'directory'
    end

    -- Время правки — целыми секундами, как обещает `TntFsStat`: на Linux
    -- `fio` отдаёт его с дробью (`st_mtim`), на macOS — целым, и без
    -- округления договор держался бы только на одной системе. Вниз,
    -- а не усечением: время до 1970 года уходит к меньшей секунде.
    ---@type TntFsStat
    local info = {
        kind = kind,
        size = stat.size,
        mode = stat.mode % 4096,
        mtime = math.floor(stat.mtime),
    }

    return info
end

--- Имена в каталоге по порядку.
---@param directory string
---@return string[]|nil names
---@return TntFsFailure|nil err
local function listed(directory)
    local names, err = system.fio().listdir(directory)

    if names == nil then
        return nil, failure.from(('каталог %s не прочитан'):format(directory), directory, err)
    end

    table.sort(names)

    return names
end

--- Образец Lua по части образца файлов.
---
--- Знаки, кроме букв и цифр, берутся буквально, затем звёздочка
--- становится «что угодно», а вопрос — «один знак».
---@param part string
---@return string
local function pattern_of(part)
    return '^' .. part:gsub('%W', '%%%0'):gsub('%%%*', '.*'):gsub('%%%?', '.') .. '$'
end

--- Подходит ли имя к части образца.
---
--- Скрытое имя подходит только к части, которая сама начинается с точки,
--- как у системного `glob`: иначе `*` захватывал бы служебные файлы,
--- например временные файлы подмены.
---@param name string
---@param part string
---@param pattern string
---@return boolean
local function fits(name, part, pattern)
    local hidden = name:match('^%.') ~= nil and part:match('^%.') == nil

    return not hidden and name:match(pattern) ~= nil
end

--- Сведения о пути; ссылка раскрывается.
---@param path string
---@return TntFsStat|nil info
---@return TntFsFailure|nil err
function Module.stat(path)
    must.at(2).string(path, 'путь')

    return inspect(path)
end

--- Есть ли что-нибудь по пути.
---
--- «Нет» и «не удалось узнать» — разные ответы: второй приходит парой.
--- Ссылка в никуда — «нет», как у `fio.path.exists`.
---@param path string
---@return boolean|nil exists
---@return TntFsFailure|nil err
function Module.exists(path)
    must.at(2).string(path, 'путь')

    local info, err = inspect(path)

    if info ~= nil then
        return true
    end

    ---@cast err TntFsFailure
    if err.kind == failure.MISSING then
        return false
    end

    return nil, err
end

--- Имена в каталоге по порядку, со скрытыми, без `.` и `..`.
---@param directory string
---@return string[]|nil names
---@return TntFsFailure|nil err
function Module.list(directory)
    must.at(2).string(directory, 'каталог')

    return listed(directory)
end

--- Спускается на уровень образца.
---
--- Каталог, пропавший по дороге или оказавшийся файлом, пропускается:
--- образцу он не подходит. Прочий отказ — отказ всего поиска: список,
--- в котором молча нет недоступного каталога, выдал бы неполное за полное.
--- Первый уровень — сам каталог поиска, и у него отказ всякий: «нечего
--- искать» и «ничего не нашлось» — разные ответы.
---@param bases string[] Каталоги уровня
---@param part string Часть образца
---@param first boolean Первый ли это уровень
---@return string[]|nil paths
---@return TntFsFailure|nil err
local function descend(bases, part, first)
    local pattern = pattern_of(part)
    local found = {}

    for _, base in ipairs(bases) do
        local names, err = listed(base)

        if names == nil then
            ---@cast err TntFsFailure
            if first or err.kind ~= failure.MISSING then
                return nil, err
            end

            names = {}
        end

        for _, name in ipairs(names) do
            if fits(name, part, pattern) then
                table.insert(found, system.fio().pathjoin(base, name))
            end
        end
    end

    return found
end

--- Пути по образцу, по порядку, без блокировки узла.
---
--- Образец — путь от каталога: части через косую черту, в части `*` —
--- любые знаки, `?` — один знак. Промежуточные части подходят только
--- каталогам. Пары «косая черта со звёздочкой» в этом файле нет нарочно:
--- генератор мутантов читает её как начало комментария C и перестаёт
--- видеть остаток файла.
--- Каталога нет — отказ `missing`.
---
--- Квадратных скобок образец не знает, и они — ошибка программиста, а не
--- буквы: у `fio.glob` это набор знаков, и молча прочитанные иначе, они
--- нашли бы не то, что искали.
---@param directory string Где искать
---@param mask string Образец, например `*.xlog`; части через косую черту
---@return string[]|nil paths
---@return TntFsFailure|nil err
function Module.glob(directory, mask)
    local caller = must.at(2)

    caller.string(directory, 'каталог')
    caller.matches(mask, 'образец', '^[^/%[%]][^%[%]]*$')

    local paths = { directory }
    local first = true

    for part in mask:gmatch('[^/]+') do
        local found, err = descend(paths, part, first)

        if found == nil then
            return nil, err
        end

        paths = found
        first = false
    end

    table.sort(paths)

    return paths
end

--- Создаёт каталог со всеми недостающими родителями; уже есть — удача.
---@param path string
---@param opts TntFsTreeOptions|nil
---@return true|nil ok
---@return TntFsFailure|nil err
function Module.make_tree(path, opts)
    local caller = must.at(2)

    caller.string(path, 'путь')
    caller.optional.options(opts, 'настройки', OPTIONS)

    local mode = (opts or {}).mode

    return failure.outcome(('каталог %s не создан'):format(path), path, system.fio().mktree(path, mode))
end

--- Сносит то, что лежит по пути, целиком; по ссылке не идёт.
---
--- Каталог — со всем содержимым, файл и ссылка — сами. Ничего нет —
--- отказ `missing`: уборку, которой нечего убирать, вызывающий отличит сам.
---@param path string
---@return true|nil ok
---@return TntFsFailure|nil err
function Module.remove_tree(path)
    must.at(2).string(path, 'путь')

    local doing = ('%s не снесён'):format(path)
    local stat, err = system.fio().lstat(path)

    if stat == nil then
        return nil, failure.from(doing, path, err)
    end

    if stat:is_dir() then
        return failure.outcome(doing, path, system.fio().rmtree(path))
    end

    return failure.outcome(doing, path, system.fio().unlink(path))
end

return Module
