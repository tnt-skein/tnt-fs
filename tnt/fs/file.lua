--- Файлы целиком: чтение, запись, дозапись, подмена, копия, перенос.
---
--- Всё идёт через `fio`, а не через `io`: `io.open` и его чтение ждут
--- диска, не уступая управления, и узел на это время стоит целиком —
--- замер на 3.8: чтение 200 МБ через `io` — 0 тиков соседнего файбера,
--- через `fio` — 16 918 тиков за те же 30 мс. `fio` отдаёт работу пулу
--- нитей и ждёт её файбером.
---
--- Записанное сбрасывается на диск до закрытия: строка, оставшаяся в кэше
--- страниц, переживает закрытие файла и не переживает отключения питания.
--- Закрытие проверяется тоже — сетевая файловая система сообщает об отказе
--- записи именно на нём.

local failure = require('tnt.fs.failure')
local must = require('tnt.must')
local system = require('tnt.fs.system')
local writer = require('tnt.fs.writer')

local Module = {}

--- Права нового файла по умолчанию: `0640` (`tnt.fs.writer`).
Module.MODE = writer.MODE

--- Настройки записи.
---
--- Права — девять бит `rwx`: особые биты (`setuid` и прочие) файлу,
--- который пишет узел, не нужны, и число больше `0777` — опечатка.
local OPTIONS = { mode = { '?between', 0, 511 } }

--- Флаги записи с начала файла.
local WRITE = { 'O_WRONLY', 'O_CREAT', 'O_TRUNC' }

--- Флаги дозаписи в конец.
local APPEND = { 'O_WRONLY', 'O_CREAT', 'O_APPEND' }

---@class TntFsWriteOptions
---@field mode number|nil Права нового файла, от 0 до 511 (`0777`); по умолчанию `MODE`

--- Проверяет аргументы записи и отдаёт права.
---
--- Бросок показывает на того, кто позвал функцию пакета: проверка стоит
--- двумя кадрами ниже его.
---@param path any
---@param content any
---@param opts any
---@return number|nil
local function checked(path, content, opts)
    local caller = must.at(3)

    caller.string(path, 'путь')
    caller.string(content, 'содержимое')
    caller.optional.options(opts, 'настройки', OPTIONS)

    return (opts or {}).mode
end

--- Пишет в открытый файл, сбрасывает на диск и закрывает.
---
--- Закрывается файл при всяком исходе. Из отказов называется первый:
--- сброс после неудавшейся записи ничего не значит, а его успех выдал бы
--- отказ за удачу.
---@param file any Ручка `fio`
---@param content string
---@return boolean ok
---@return any err
local function fill(file, content)
    local done, err = file:write(content)

    if done then
        done, err = file:fsync()
    end

    local closed, close_err = file:close()

    if not done then
        return false, err
    end

    return closed, close_err
end

--- Открывает файл с флагами, пишет и закрывает.
---@param path string
---@param flags string[]
---@param content string
---@param mode number
---@param doing string
---@return true|nil ok
---@return TntFsFailure|nil err
local function put(path, flags, content, mode, doing)
    local file, err = system.fio().open(path, flags, mode)

    if file == nil then
        return nil, failure.from(doing, path, err)
    end

    return failure.outcome(doing, path, fill(file, content))
end

--- Читает файл целиком.
---@param path string
---@return string|nil content
---@return TntFsFailure|nil err
function Module.read(path)
    must.at(2).string(path, 'путь')

    local doing = ('файл %s не прочитан'):format(path)
    local file, err = system.fio().open(path, { 'O_RDONLY' })

    if file == nil then
        return nil, failure.from(doing, path, err)
    end

    local content, read_err = file:read()

    file:close()

    if content == nil then
        return nil, failure.from(doing, path, read_err)
    end

    return content
end

--- Записывает файл целиком, с начала.
---@param path string
---@param content string
---@param opts TntFsWriteOptions|nil
---@return true|nil ok
---@return TntFsFailure|nil err
function Module.write(path, content, opts)
    local mode = checked(path, content, opts) or Module.MODE

    return put(path, WRITE, content, mode, ('файл %s не записан'):format(path))
end

--- Дописывает в конец файла; файла нет — заводит его.
---@param path string
---@param content string
---@param opts TntFsWriteOptions|nil
---@return true|nil ok
---@return TntFsFailure|nil err
function Module.append(path, content, opts)
    local mode = checked(path, content, opts) or Module.MODE

    return put(path, APPEND, content, mode, ('файл %s не дописан'):format(path))
end

--- Подменяет файл целиком: читающий видит либо старое, либо новое.
---
--- Это писатель `tnt.fs.writer` с одним куском: новое пишется во временный
--- файл рядом с целью, сбрасывается на диск и переименовывается поверх,
--- затем сбрасывается каталог. Временный файл при отказе убирается.
---
--- Права без `opts.mode` берутся у старого файла: подмена не должна молча
--- открыть файл с тайнами шире, чем он был. Нового файла — `MODE`.
---@param path string
---@param content string
---@param opts TntFsWriteOptions|nil
---@return true|nil ok
---@return TntFsFailure|nil err
function Module.replace(path, content, opts)
    local mode = checked(path, content, opts)
    local replacing, err = writer.create(path, mode, ('файл %s не заменён'):format(path))

    if replacing == nil then
        return nil, err
    end

    local written, write_err = replacing:write(content)

    if not written then
        return nil, write_err
    end

    return replacing:finish()
end

--- Копирует файл.
---
--- Копирует `fio` — со своими правами и дырами, как системная копия.
--- Куда — каталог: файл ложится в него под своим именем.
---@param from string
---@param to string
---@return true|nil ok
---@return TntFsFailure|nil err
function Module.copy(from, to)
    local caller = must.at(2)

    caller.string(from, 'откуда')
    caller.string(to, 'куда')

    return failure.outcome(
        ('файл %s не скопирован в %s'):format(from, to),
        from,
        system.fio().copyfile(from, to)
    )
end

--- Переносит файл или каталог на новое место в пределах тома.
---@param from string
---@param to string
---@return true|nil ok
---@return TntFsFailure|nil err
function Module.rename(from, to)
    local caller = must.at(2)

    caller.string(from, 'откуда')
    caller.string(to, 'куда')

    return failure.outcome(('%s не перенесён в %s'):format(from, to), from, system.fio().rename(from, to))
end

--- Удаляет файл или ссылку; ссылка удаляется сама, а не то, на что она
--- указывает.
---@param path string
---@return true|nil ok
---@return TntFsFailure|nil err
function Module.remove(path)
    must.at(2).string(path, 'путь')

    return failure.outcome(('%s не удалён'):format(path), path, system.fio().unlink(path))
end

return Module
