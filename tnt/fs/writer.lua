--- Запись файла кусками с подменой в конце: читающий видит либо старое
--- содержимое, либо новое — никогда половину.
---
---     local writer, err = fs.writer('/var/lib/app/export.csv')
---
---     for _, rows in ipairs(pages) do
---         local written, failure = writer:write(csv_of(rows))
---
---         if not written then
---             return nil, failure     -- временный файл уже убран
---         end
---     end
---
---     return writer:finish()           -- сброс на диск и переименование на место
---
--- Куски идут во временный файл рядом с целью — `.<имя>.<16 знаков>.tmp`,
--- открытый с `O_EXCL`, — и в памяти лежит один кусок, а не файл целиком.
--- `finish` сбрасывает его на диск, закрывает, переименовывает поверх цели
--- и сбрасывает каталог. Рядом с целью, а не в `/tmp`: переименование
--- атомарно только в пределах одной файловой системы, а `/tmp` на боевой
--- машине обычно tmpfs — оттуда `rename` отвечает «Cross-device link»
--- (проверено на 3.8).
---
--- Отказ записи или подмены убирает временный файл, и старый остаётся
--- нетронутым. Писатель после отказа отвечает тем же отказом, а не пишет
--- дальше: запись с дырой посередине выдала бы себя за целую. Запись
--- после `finish` или `abort` — ошибка программиста.
---
--- Писатель — одного файбера: `fio` уступает на каждом куске, и два
--- файбера, пишущие в один писатель, перемешали бы куски.

local failure = require('tnt.fs.failure')
local must = require('tnt.must')
local system = require('tnt.fs.system')

local Module = {}

--- Права нового файла по умолчанию: владельцу чтение и запись, группе
--- чтение, прочим ничего.
---
--- В файлы, которые пишет узел, попадают его данные, и «как получится»
--- означало бы umask того, кто запустил процесс. Группа читает намеренно:
--- выгрузки и манифесты разбирает агент под своей учётной записью.
Module.MODE = tonumber('640', 8) --[[@as number]]

--- Флаги временного файла: только новый.
---
--- Файл с тем же именем — не наш, и писать в него нельзя: `O_EXCL`
--- отказывает, а не открывает чужое.
local FRESH = { 'O_WRONLY', 'O_CREAT', 'O_EXCL' }

--- Настройки писателя.
local OPTIONS = { mode = { '?between', 0, 511 } }

--- Писатель открыт и принимает куски.
local OPEN = 'open'

--- Писатель кончил: файл на месте либо запись брошена.
local DONE = 'done'

--- Писатель отказал: временный файл убран, отказ хранится.
local FAILED = 'failed'

---@class TntFsWriterOptions
---@field mode number|nil Права файла, от 0 до 511 (`0777`); по умолчанию права старого файла, а нового — `MODE`

---@class TntFsWriter Запись файла кусками
---@field path string Путь цели
---@field handle any Ручка временного файла
---@field temporary string Путь временного файла
---@field doing string Что не удалось бы, словами
---@field state string open, done либо failed
---@field failure TntFsFailure|nil Отказ, которым отвечает писатель после отказа
local Writer = {}
Writer.__index = Writer

--- Открывает писатель: временный файл рядом с целью.
---
--- Права без `mode` берутся у старого файла: подмена не должна молча
--- открыть файл с тайнами шире, чем он был. Нового файла — `MODE`.
---
--- Аргументы уже проверены тем, кто зовёт: подмена `replace` и открытие
--- `fs.writer` называют отказ каждая своими словами.
---@param path string
---@param mode number|nil
---@param doing string Что не удалось бы, словами: «файл /a не записан»
---@return TntFsWriter|nil writer
---@return TntFsFailure|nil err
function Module.create(path, mode, doing)
    local fio = system.fio()
    local name = ('.%s.%s.tmp'):format(fio.basename(path), system.current().unique())
    local temporary = fio.pathjoin(fio.dirname(path), name)

    if mode == nil then
        local stat = fio.stat(path)

        mode = stat and stat.mode % 4096 or Module.MODE
    end

    local handle, err = fio.open(temporary, FRESH, mode)

    if handle == nil then
        return nil, failure.from(doing, path, err)
    end

    return setmetatable({
        path = path,
        handle = handle,
        temporary = temporary,
        doing = doing,
        state = OPEN,
    }, Writer)
end

--- Открывает писатель файла: куски во временный файл, подмена в `finish`.
---@param path string
---@param opts TntFsWriterOptions|nil
---@return TntFsWriter|nil writer
---@return TntFsFailure|nil err
function Module.open(path, opts)
    local caller = must.at(2)

    caller.string(path, 'путь')
    caller.optional.options(opts, 'настройки', OPTIONS)

    return Module.create(path, (opts or {}).mode, ('файл %s не записан'):format(path))
end

--- Бросает, если писатель уже кончил: запись после `finish` или `abort`
--- — ошибка программиста, а не отказ диска.
---@param writer TntFsWriter
---@param action string Что позвали
local function check_open(writer, action)
    if writer.state == DONE then
        error(('%s: писатель файла %s уже закончен'):format(action, writer.path), 3)
    end
end

--- Отказывает, когда временный файл уже закрыт: убирает его и хранит
--- отказ.
---@param writer TntFsWriter
---@param err any Ответ `fio`
---@return nil
---@return TntFsFailure err
local function abandon(writer, err)
    system.fio().unlink(writer.temporary)
    writer.state = FAILED
    writer.failure = failure.from(writer.doing, writer.path, err)

    return nil, writer.failure
end

--- Отказывает, пока временный файл открыт: закрывает его, убирает
--- и хранит отказ.
---@param writer TntFsWriter
---@param err any Ответ `fio`
---@return nil
---@return TntFsFailure err
local function fail(writer, err)
    writer.handle:close()

    return abandon(writer, err)
end

--- Дописывает кусок во временный файл.
---@param chunk string
---@return true|nil ok
---@return TntFsFailure|nil err
function Writer:write(chunk)
    must.at(2).string(chunk, 'кусок')
    check_open(self, 'write')

    if self.state == FAILED then
        return nil, self.failure
    end

    local done, err = self.handle:write(chunk)

    if not done then
        return fail(self, err)
    end

    return true
end

--- Сбрасывает на диск сам каталог.
---
--- Переименование — запись в каталоге, а не в файле: без сброса каталога
--- после отключения питания на месте может оказаться старый файл, хотя
--- вызывающий уже получил «записано».
---@param directory string
---@return true|nil ok
---@return TntFsFailure|nil err
local function flush(directory)
    local doing = ('каталог %s не сброшен на диск'):format(directory)
    local handle, err = system.fio().open(directory, { 'O_RDONLY' })

    if handle == nil then
        return nil, failure.from(doing, directory, err)
    end

    local synced, sync_err = handle:fsync()

    handle:close()

    return failure.outcome(doing, directory, synced, sync_err)
end

--- Кончает запись: сброс на диск, закрытие, подмена цели, сброс каталога.
---
--- Закрытие проверяется: сетевая файловая система сообщает об отказе
--- записи именно на нём. Отказ сброса каталога называется своим текстом
--- и приходит, когда файл **уже на месте**: не сброшен только каталог.
---@return true|nil ok
---@return TntFsFailure|nil err
function Writer:finish()
    check_open(self, 'finish')

    if self.state == FAILED then
        return nil, self.failure
    end

    local synced, err = self.handle:fsync()

    if not synced then
        return fail(self, err)
    end

    local closed, close_err = self.handle:close()

    if not closed then
        return abandon(self, close_err)
    end

    local renamed, rename_err = system.fio().rename(self.temporary, self.path)

    if not renamed then
        return abandon(self, rename_err)
    end

    self.state = DONE

    return flush(system.fio().dirname(self.path))
end

--- Бросает запись: временный файл убирается, цель не тронута.
---
--- Звать можно при всяком исходе и сколько угодно раз: после отказа
--- и после `finish` — ничего не делает. Так уборку пишут одной строкой
--- в конце, не разбирая, чем кончилась запись.
---@return true
function Writer:abort()
    if self.state == OPEN then
        self.handle:close()
        system.fio().unlink(self.temporary)
    end

    self.state = DONE

    return true
end

return Module
