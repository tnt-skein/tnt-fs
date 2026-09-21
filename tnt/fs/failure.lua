--- Отказ файловой системы: таблица с родом, которая читается и как строка.
---
--- `fio` отказывает тремя разными видами. Простые действия — `open`,
--- `stat`, `rename`, `unlink`, `mkdir` — отдают объект ошибки с полем
--- `errno`. Составные, написанные на Lua, — `listdir`, `mktree`, `rmtree`,
--- `copyfile`, — строку, в которой причина стоит в конце текстом. А глобальный
--- `errno()` после составного врёт: `mktree` поверх файла отвечает «File
--- exists» при `errno` 2 — это след его же `stat` на предыдущем шаге
--- (проверено на 3.8). Вызывающему нужно одно: что случилось, словом,
--- по которому можно решать, — поэтому все три вида сводятся здесь в один.
---
--- Главное поле — род (`kind`), и родов пять:
---
--- * `missing` — по пути ничего нет: ни файла, ни каталога, либо часть
---   пути — файл, а не каталог (`ENOENT`, `ENOTDIR`);
--- * `exists` — место занято: файл уже есть, каталог не пуст (`EEXIST`,
---   `ENOTEMPTY`);
--- * `denied` — нет прав либо файловая система только для чтения
---   (`EACCES`, `EPERM`, `EROFS`);
--- * `full` — кончилось место или квота (`ENOSPC`, `EDQUOT`);
--- * `failed` — всё прочее: ввод-вывод, перенос между томами, каталог там,
---   где нужен файл. Код остаётся в поле `errno`, если он был.
---
--- Строкой отказ читается целиком: `tostring(err)`, `'причина: ' .. err`
--- и `json.encode` дают текст «что не удалось: почему».

local errno = require('errno')

local Module = {}

--- По пути ничего нет.
Module.MISSING = 'missing'

--- Место занято.
Module.EXISTS = 'exists'

--- Нет прав.
Module.DENIED = 'denied'

--- Кончилось место.
Module.FULL = 'full'

--- Прочее.
Module.FAILED = 'failed'

--- Род отказа по коду.
---
--- Коды, которых здесь нет, — `failed`. Список же служит и разбору строки:
--- причину в конце текста узнаём только среди этих кодов.
local KINDS = {
    [errno.ENOENT] = Module.MISSING,
    [errno.ENOTDIR] = Module.MISSING,
    [errno.EEXIST] = Module.EXISTS,
    [errno.ENOTEMPTY] = Module.EXISTS,
    [errno.EACCES] = Module.DENIED,
    [errno.EPERM] = Module.DENIED,
    [errno.EROFS] = Module.DENIED,
    [errno.ENOSPC] = Module.FULL,
    [errno.EDQUOT] = Module.FULL,
    [errno.EISDIR] = Module.FAILED,
    [errno.EXDEV] = Module.FAILED,
}

---@class TntFsFailure Отказ файловой системы
---@field kind string Род: missing, exists, denied, full либо failed
---@field message string Что не удалось и почему — его и отдаёт `tostring`
---@field errno integer|nil Код причины, если он известен
---@field path string|nil Путь, о котором шла речь; у системного временного каталога его нет

--- Текст отказа.
---@param failure TntFsFailure
---@return string
local function text_of(failure)
    return failure.message
end

--- Поведение всех отказов: строкой, в JSON и в склейке они — свой текст.
local Failure = {
    __tostring = text_of,
    __serialize = text_of,
    __concat = function(left, right)
        return tostring(left) .. tostring(right)
    end,
}

--- Код причины по тексту составного действия `fio`.
---
--- Причина стоит в конце текста, и сверяется именно конец: путь в начале
--- текста волен содержать те же слова.
---@param text string
---@return integer|nil
local function code_in(text)
    for code in pairs(KINDS) do
        local reason = errno.strerror(code)

        if text:sub(-#reason) == reason then
            return code
        end
    end

    return nil
end

--- Отказ по тому, что ответил `fio`.
---@param doing string Что не удалось, словами: «файл /a не прочитан»
---@param path string|nil Путь, о котором шла речь
---@param err any Ответ `fio`: объект ошибки с `errno`, строка либо ничего
---@return TntFsFailure
function Module.from(doing, path, err)
    local code

    -- Отказа без причины `fio` на 3.8 не даёт, но разбор такой пустоты
    -- уронил бы исключением функцию, которая обещала пару.
    if type(err) == 'string' then
        code = code_in(err)
    elseif err ~= nil then
        code = err.errno
    end

    -- Причина — словами системы, без приставки «fio:» и без путей,
    -- которые составные действия вписывают в текст сами: путь уже назван
    -- в том, что не удалось.
    local reason = tostring(err or 'причина неизвестна')

    if code ~= nil then
        reason = errno.strerror(code)
    end

    return setmetatable({
        kind = KINDS[code] or Module.FAILED,
        message = ('%s: %s'):format(doing, reason),
        errno = code,
        path = path,
    }, Failure)
end

--- Исход действия `fio`, которое отвечает «получилось» либо ложью с причиной.
---@param doing string Что не удалось бы, словами
---@param path string Путь, о котором шла речь
---@param ok any Что ответил `fio`
---@param err any Причина отказа
---@return true|nil ok
---@return TntFsFailure|nil err
function Module.outcome(doing, path, ok, err)
    if not ok then
        return nil, Module.from(doing, path, err)
    end

    return true
end

return Module
