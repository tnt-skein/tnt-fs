rockspec_format = '3.0'

package = 'tnt-fs'
version = 'scm-1'

source = {
    url = 'git+https://github.com/tnt-skein/tnt-fs.git',
    branch = 'main',
}

description = {
    summary = 'Файловая система фасадом поверх fio: отказ парой, операции с уступкой, временные каталоги',
    detailed = [[
        Работу делает встроенный fio, пакет даёт три вещи, которых у него
        нет. Один вид отказа: пара nil, err, где err — таблица с родом
        (missing, exists, denied, full, failed), кодом и текстом, вместо
        трёх видов fio. Ничто не держит узел: чтение каталога по образцу
        идёт fio.listdir с уступкой, а не fio.glob в потоке событий, io.open
        не используется вовсе. И приёмы, которые иначе пишут руками:
        запись со сбросом на диск, подмена файла через временный рядом
        с целью, снос дерева, не идущий по ссылке, временный каталог
        с уборкой при броске.

        Зависит от tnt-must (проверки аргументов) и tnt-external (подмена
        fio в проверках). Покрытие строк и убитых мутантов — 100 %.
    ]],
    homepage = 'https://github.com/tnt-skein/tnt-fs',
    issues_url = 'https://github.com/tnt-skein/tnt-fs/issues',
    maintainer = 'tnt-skein',
    license = 'MIT',
    labels = { 'tarantool', 'fio', 'filesystem', 'files', 'atomic-write' },
}

dependencies = {
    'lua >= 5.1',
    'tnt-must',
    'tnt-external',
}

build = {
    type = 'builtin',
    modules = {
        ['tnt.fs'] = 'tnt/fs.lua',
        ['tnt.fs.failure'] = 'tnt/fs/failure.lua',
        ['tnt.fs.file'] = 'tnt/fs/file.lua',
        ['tnt.fs.system'] = 'tnt/fs/system.lua',
        ['tnt.fs.temp'] = 'tnt/fs/temp.lua',
        ['tnt.fs.tree'] = 'tnt/fs/tree.lua',
    },
}
