--- Временные каталоги: рядом с целью либо в системном, и уборка за собой.
---
--- Где заводить временный каталог, решает то, что из него потом сделают.
--- Черновику, который выбросят, место в системном (`$TMPDIR`, иначе
--- `/tmp`): его заводит `fio.tempdir`, права `0700`. Тому, что потом
--- переименуют на место, место рядом с целью (`within`): переименование
--- атомарно только в пределах одной файловой системы, а системный каталог
--- на боевой машине обычно tmpfs, и `rename` оттуда отвечает «Cross-device
--- link» (проверено на 3.8).
---
--- `with_temp_dir` убирает каталог при всяком исходе работы — и когда
--- она вернулась, и когда бросила: брошенный на полпути черновик иначе
--- копился бы с каждым отказом.

local fail = require('tnt.must.fail')
local failure = require('tnt.fs.failure')
local must = require('tnt.must')
local system = require('tnt.fs.system')
local tree = require('tnt.fs.tree')

local Module = {}

--- Настройки временного каталога.
local OPTIONS = { within = '?string' }

---@class TntFsTempOptions
---@field within string|nil В каком каталоге завести; по умолчанию в системном

--- Заводит каталог; аргументы уже проверены.
---@param opts TntFsTempOptions|nil
---@return string|nil path
---@return TntFsFailure|nil err
local function create(opts)
    local within = (opts or {}).within

    if within == nil then
        local path, err = system.fio().tempdir()

        if path == nil then
            return nil, failure.from('временный каталог не заведён', nil, err)
        end

        return path
    end

    -- Имя скрытое: образец `*` у соседей его не захватит, и уборщик,
    -- чистящий каталог цели по образцу, не снесёт чужую работу на ходу.
    local path = system.fio().pathjoin(within, ('.tmp-%s'):format(system.current().unique()))
    local made, err = system.fio().mkdir(path, tonumber('700', 8))

    if not made then
        return nil,
            failure.from(('временный каталог в %s не заведён'):format(within), within, err)
    end

    return path
end

--- Собирает ответы в таблицу вместе с их числом: среди них бывают `nil`.
---@return table
local function packed(...)
    return { n = select('#', ...), ... }
end

--- Заводит временный каталог; убирает его вызывающий.
---@param opts TntFsTempOptions|nil
---@return string|nil path
---@return TntFsFailure|nil err
function Module.temp_dir(opts)
    must.at(2).optional.options(opts, 'настройки', OPTIONS)

    return create(opts)
end

--- Отдаёт работе временный каталог и сносит его после.
---
--- Ответы работы возвращаются как есть. Бросок работы уходит дальше тем же
--- значением, а каталог перед этим сносится; не снёсся — бросок важнее,
--- и каталог остаётся. Вернулась работа, а каталог не снёсся — пара
--- `nil, err`: оставленный черновик с чужими данными — отказ, о котором
--- вызывающий обязан знать.
---@param work fun(path: string): ... Работа; получает путь каталога
---@param opts TntFsTempOptions|nil
---@return any ... Ответы работы либо `nil, TntFsFailure`
function Module.with_temp_dir(work, opts)
    local caller = must.at(2)

    caller.callable(work, 'работа')
    caller.optional.options(opts, 'настройки', OPTIONS)

    local path, err = create(opts)

    if path == nil then
        return nil, err
    end

    local result = packed(pcall(work, path))
    local removed, remove_err = tree.remove_tree(path)

    if not result[1] then
        fail.raise(result[2])
    end

    if not removed then
        return nil, remove_err
    end

    return unpack(result, 2, result.n)
end

return Module
