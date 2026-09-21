--- Файловая система фасадом поверх `fio`: отказ парой, операции
--- с уступкой, временные каталоги.
---
---     local fs = require('tnt.fs')
---
---     local text, err = fs.read('/etc/app/config.yaml')
---
---     if text == nil and err.kind == fs.MISSING then
---         -- файла нет — это «так бывает», а не поломка
---     end
---
---     fs.replace('/var/lib/app/state.json', json.encode(state))  -- атомарно
---     local wals = fs.glob(wal_dir, '*.xlog')                     -- без блокировки
---
---     fs.with_temp_dir(function(dir)
---         -- черновик; каталог снесётся и при броске
---     end, { within = '/var/lib/app' })
---
--- Строится поверх `fio`, а не вместо: работу делает он, пакет даёт три
--- вещи, которых у него нет.
---
--- 1. **Один вид отказа.** У `fio` их три: объект ошибки, строка и ложь
---    с причиной в `errno`, которую следующий вызов затирает. Здесь всякий
---    отказ — пара `nil, err`, где `err` — таблица с родом (`missing`,
---    `exists`, `denied`, `full`, `failed`), кодом и текстом.
---    Исключение — только ошибка программиста: путь не строкой, чужой ключ
---    настроек; бросок показывает на строку вызывающего.
--- 2. **Ничто не держит узел.** Всё идёт пулом нитей `fio` с уступкой;
---    `fio.glob`, который зовёт системный `glob` прямо в потоке событий,
---    заменён чтением каталога, а `io.open` не используется вовсе.
--- 3. **Приёмы, которые иначе пишут руками и с ошибками**: запись со сбросом
---    на диск, подмена через временный файл рядом с целью, снос дерева,
---    не идущий по ссылке, временный каталог с уборкой при броске.
---
--- Настроек и состояния у пакета нет. Подробно — `docs/fs.md`.

local failure = require('tnt.fs.failure')
local file = require('tnt.fs.file')
local system = require('tnt.fs.system')
local temp = require('tnt.fs.temp')
local tree = require('tnt.fs.tree')

local Module = {}

--- По пути ничего нет.
Module.MISSING = failure.MISSING

--- Место занято.
Module.EXISTS = failure.EXISTS

--- Нет прав.
Module.DENIED = failure.DENIED

--- Кончилось место.
Module.FULL = failure.FULL

--- Прочее: ввод-вывод, перенос между томами и всё, чему нет рода.
Module.FAILED = failure.FAILED

--- Права нового файла по умолчанию: `0640`.
Module.MODE = file.MODE

Module.read = file.read
Module.write = file.write
Module.append = file.append
Module.replace = file.replace
Module.copy = file.copy
Module.rename = file.rename
Module.remove = file.remove

Module.stat = tree.stat
Module.exists = tree.exists
Module.list = tree.list
Module.glob = tree.glob
Module.make_tree = tree.make_tree
Module.remove_tree = tree.remove_tree

Module.temp_dir = temp.temp_dir
Module.with_temp_dir = temp.with_temp_dir

--- Подменяет средства пакета: `fio` и случайную часть имён. Только для
--- проверок.
Module._set_source = system._set_source

return Module
