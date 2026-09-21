--- Проверки каталогов: сведения, существование, список, образец, дерево.

local errno = require('errno')
local fio = require('fio')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local fs = helper.fs

local g = helper.group('tnt.fs.tree')

--- Путь в каталоге проверки.
local at = helper.file

--- Кладёт пустые файлы по списку имён.
---@param names string[]
local function files(names)
    for _, name in ipairs(names) do
        helper.put(at(name), '')
    end
end

--- Пути в каталоге проверки по именам.
---@param names string[]
---@return string[]
local function paths(names)
    local found = {}

    for _, name in ipairs(names) do
        table.insert(found, at(name))
    end

    return found
end

g.test_stat_describes_a_file = function()
    helper.put(at('a.txt'), '12345', '604')

    local info = fs.stat(at('a.txt'))

    t.assert_equals(
        { info.kind, info.size, helper.octal(info.mode), info.mtime },
        { 'file', 5, '604', math.floor(fio.stat(at('a.txt')).mtime) }
    )
end

g.test_stat_gives_whole_seconds_rounded_down = function()
    -- Дробь подставлена явно: на macOS `fio` её не отдаёт, и проверка
    -- без подмены шла бы по-разному на разных системах. Время до 1970 года
    -- уходит к меньшей секунде, а не к нулю.
    helper.put(at('a.txt'), '12345')

    local real = fio.stat(at('a.txt'))
    local mtime

    helper.with_fio({
        stat = function()
            return setmetatable({ mtime = mtime }, { __index = real })
        end,
    })

    mtime = 1790190195.706
    t.assert_equals(fs.stat(at('a.txt')).mtime, 1790190195)
    mtime = -1.5
    t.assert_equals(fs.stat(at('a.txt')).mtime, -2)
end

g.test_stat_describes_a_directory_and_follows_a_link = function()
    fio.mkdir(at('dir'), helper.mode('750'))
    fio.symlink(at('dir'), at('link'))

    t.assert_equals({ fs.stat(at('dir')).kind, helper.octal(fs.stat(at('dir')).mode) }, { 'directory', '750' })
    t.assert_equals(fs.stat(at('link')).kind, 'directory')
end

g.test_stat_of_a_device_is_other = function()
    t.assert_equals(fs.stat('/dev/null').kind, 'other')
end

g.test_stat_of_a_missing_path_is_a_pair = function()
    local info, err = fs.stat(at('none'))

    t.assert_equals(info, nil)
    t.assert_equals(
        { err.kind, err.path, err.message },
        { 'missing', at('none'), ('%s не опрошен: No such file or directory'):format(at('none')) }
    )
end

g.test_exists_says_yes_and_no = function()
    files({ 'a.txt' })
    fio.symlink(at('none'), at('dangling'))

    t.assert_equals({ fs.exists(at('a.txt')) }, { true })
    t.assert_equals({ fs.exists(helper.root()) }, { true })
    t.assert_equals({ fs.exists(at('none')) }, { false })
    t.assert_equals({ fs.exists(at('a.txt/inside')) }, { false })
    t.assert_equals({ fs.exists(at('dangling')) }, { false })
end

g.test_exists_that_cannot_be_known_is_a_pair = function()
    helper.with_fio({
        stat = function()
            return nil, helper.refusal(errno.EACCES)
        end,
    })

    local exists, err = fs.exists(at('a.txt'))

    t.assert_equals(exists, nil)
    t.assert_equals(
        { err.kind, err.message },
        { 'denied', ('%s не опрошен: Permission denied'):format(at('a.txt')) }
    )
end

g.test_list_gives_names_in_order_with_hidden_ones = function()
    files({ 'b.txt', 'a.txt', '.hidden' })
    fio.mkdir(at('c'))

    t.assert_equals(fs.list(helper.root()), { '.hidden', 'a.txt', 'b.txt', 'c' })
end

g.test_list_of_a_missing_directory_is_a_pair = function()
    local names, err = fs.list(at('none'))

    t.assert_equals(names, nil)
    t.assert_equals({ err.kind, err.errno, err.path, err.message }, {
        'missing',
        errno.ENOENT,
        at('none'),
        ('каталог %s не прочитан: No such file or directory'):format(at('none')),
    })
end

g.test_glob_finds_by_star_and_question_in_order = function()
    files({ '00000000000000000002.xlog', '00000000000000000001.xlog', '1.snap', 'a1', 'a22', 'b1' })

    t.assert_equals(
        fs.glob(helper.root(), '*.xlog'),
        paths({ '00000000000000000001.xlog', '00000000000000000002.xlog' })
    )
    t.assert_equals(fs.glob(helper.root(), 'a?'), paths({ 'a1' }))
    t.assert_equals(
        fs.glob(helper.root(), '*'),
        paths({
            '00000000000000000001.xlog',
            '00000000000000000002.xlog',
            '1.snap',
            'a1',
            'a22',
            'b1',
        })
    )
end

g.test_glob_takes_other_signs_literally = function()
    -- Каждый знак, особый для образцов Lua, обязан значить сам себя.
    files({ 'a.b', 'axb', 'a-b', 'aab', 'a+b', 'a%b', 'a(b)', 'a^b', 'a$b', 'a_b', 'имя.txt', 'имя-2.txt' })

    for _, name in ipairs({ 'a.b', 'a-b', 'a+b', 'a%b', 'a(b)', 'a^b', 'a$b', 'a_b', 'имя.txt' }) do
        t.assert_equals(fs.glob(helper.root(), name), paths({ name }), name)
    end

    t.assert_equals(fs.glob(helper.root(), 'имя*.txt'), paths({ 'имя-2.txt', 'имя.txt' }))
end

g.test_glob_skips_hidden_names_unless_asked = function()
    files({ '.state.json.f00d.tmp', 'state.json', '.hidden' })

    t.assert_equals(fs.glob(helper.root(), '*'), paths({ 'state.json' }))
    t.assert_equals(fs.glob(helper.root(), '.*'), paths({ '.hidden', '.state.json.f00d.tmp' }))
end

g.test_glob_goes_down_by_parts = function()
    files({ '512/0/1.run', '512/0/2.index', '512/1/3.run', '513/0/4.run', 'x.run', 'top.vylog' })

    t.assert_equals(fs.glob(helper.root(), '*/*/*.run'), paths({ '512/0/1.run', '512/1/3.run', '513/0/4.run' }))
    t.assert_equals(fs.glob(helper.root(), '512/0/*'), paths({ '512/0/1.run', '512/0/2.index' }))
end

g.test_glob_skips_files_on_the_way = function()
    -- Промежуточная часть подходит только каталогу: файл `x.run`
    -- на первом уровне под `*` пропускается, а не рвёт поиск.
    files({ '512/0/1.run', 'x.run' })

    t.assert_equals(fs.glob(helper.root(), '*/0/*.run'), paths({ '512/0/1.run' }))
    t.assert_equals(fs.glob(helper.root(), '*/*'), paths({ '512/0' }))
end

g.test_glob_of_nothing_found_is_empty = function()
    files({ 'a.txt' })

    t.assert_equals(fs.glob(helper.root(), '*.xlog'), {})
    t.assert_equals(fs.glob(helper.root(), '*/*.xlog'), {})
end

g.test_glob_in_a_missing_directory_is_a_pair = function()
    local found, err = fs.glob(at('none'), '*.xlog')

    t.assert_equals(found, nil)
    t.assert_equals({ err.kind, err.path, err.message }, {
        'missing',
        at('none'),
        ('каталог %s не прочитан: No such file or directory'):format(at('none')),
    })
end

g.test_glob_in_a_file_is_a_pair = function()
    files({ 'a.txt' })

    local found, err = fs.glob(at('a.txt'), '*')

    t.assert_equals(found, nil)
    t.assert_equals({ err.kind, err.errno }, { 'missing', errno.ENOTDIR })
end

g.test_glob_fails_on_an_unreadable_directory_on_the_way = function()
    -- Список, в котором молча нет недоступного каталога, выдал бы
    -- неполное за полное.
    files({ '512/0/1.run', '513/0/2.run' })

    helper.with_fio({
        listdir = function(path)
            if path == at('513') then
                return nil, ("can't listdir %s: fio: Permission denied"):format(path)
            end

            return fio.listdir(path)
        end,
    })

    local found, err = fs.glob(helper.root(), '*/0/*.run')

    t.assert_equals(found, nil)
    t.assert_equals({ err.kind, err.path }, { 'denied', at('513') })
end

g.test_glob_does_not_hold_the_node = function()
    -- `fio.glob` зовёт системный glob в потоке событий: сосед не тикает
    -- вовсе. Здесь каталог читает пул нитей, и сосед успевает.
    files({ 'a.xlog', 'b.xlog' })

    local neighbour = helper.neighbour()

    local found = fs.glob(helper.root(), '*.xlog')

    neighbour.stop()

    t.assert_equals(#found, 2)
    t.assert_gt(neighbour.ticks, 0)
end

g.test_make_tree_creates_all_parents = function()
    t.assert_equals({ fs.make_tree(at('a/b/c')) }, { true })

    t.assert_equals(fio.stat(at('a/b/c')):is_dir(), true)
    t.assert_equals(helper.mode_of(at('a/b')), '755')
end

g.test_make_tree_of_an_existing_directory_succeeds = function()
    fio.mkdir(at('a'))

    t.assert_equals({ fs.make_tree(at('a')) }, { true })
end

g.test_make_tree_takes_the_rights_it_is_given = function()
    fs.make_tree(at('a/b'), { mode = helper.mode('700') })
    fs.make_tree(at('c'), { mode = 0 })
    fs.make_tree(at('d'), { mode = 511 })

    t.assert_equals(helper.mode_of(at('a')), '700')
    t.assert_equals(helper.mode_of(at('a/b')), '700')
    t.assert_equals(helper.mode_of(at('c')), '0')
    t.assert_equals(helper.mode_of(at('d')), '755')
end

g.test_make_tree_over_a_file_is_a_pair = function()
    files({ 'a' })

    local ok, err = fs.make_tree(at('a/b'))

    t.assert_equals(ok, nil)
    t.assert_equals(
        { err.kind, err.errno, err.path, err.message },
        { 'exists', errno.EEXIST, at('a/b'), ('каталог %s не создан: File exists'):format(at('a/b')) }
    )
end

g.test_remove_tree_removes_a_directory_with_everything = function()
    files({ 'a/b/c.txt', 'a/d.txt', 'a/.hidden' })

    t.assert_equals({ fs.remove_tree(at('a')) }, { true })

    t.assert_equals(fio.listdir(helper.root()), {})
end

g.test_remove_tree_removes_a_file = function()
    files({ 'a.txt' })

    t.assert_equals({ fs.remove_tree(at('a.txt')) }, { true })

    t.assert_equals(fio.listdir(helper.root()), {})
end

g.test_remove_tree_does_not_follow_a_link = function()
    -- `fio.rmtree` по ссылке вычищает каталог, на который она указывает.
    files({ 'data/keep.txt', 'data/sub/deep.txt' })
    fio.symlink(at('data'), at('alias'))

    t.assert_equals({ fs.remove_tree(at('alias')) }, { true })

    t.assert_equals(fio.listdir(helper.root()), { 'data' })
    t.assert_equals(helper.get(at('data/keep.txt')), '')
    t.assert_equals(helper.get(at('data/sub/deep.txt')), '')
end

g.test_remove_tree_of_nothing_is_a_pair = function()
    local ok, err = fs.remove_tree(at('none'))

    t.assert_equals(ok, nil)
    t.assert_equals(
        { err.kind, err.path, err.message },
        { 'missing', at('none'), ('%s не снесён: No such file or directory'):format(at('none')) }
    )
end

g.test_a_failed_removal_inside_the_tree_is_a_pair = function()
    files({ 'a/b.txt' })

    helper.with_fio({
        rmtree = function(path)
            return nil, ("can't listdir %s: fio: Permission denied"):format(path)
        end,
    })

    local ok, err = fs.remove_tree(at('a'))

    t.assert_equals(ok, nil)
    t.assert_equals(
        { err.kind, err.message },
        { 'denied', ('%s не снесён: Permission denied'):format(at('a')) }
    )
end

g.test_a_failed_removal_of_a_file_is_a_pair = function()
    files({ 'a.txt' })

    helper.with_fio({
        unlink = function()
            return false, helper.refusal(errno.EROFS)
        end,
    })

    local ok, err = fs.remove_tree(at('a.txt'))

    t.assert_equals(ok, nil)
    t.assert_equals({ err.kind, err.errno }, { 'denied', errno.EROFS })
end

g.test_wrong_arguments_blame_the_caller = function()
    local cases = {
        {
            function()
                fs.stat(helper.wrong(1))
            end,
            'путь — строка, а не число',
        },
        {
            function()
                fs.exists(helper.wrong(nil))
            end,
            'путь — строка, а не nil',
        },
        {
            function()
                fs.list(helper.wrong(1))
            end,
            'каталог — строка, а не число',
        },
        {
            function()
                fs.glob(helper.wrong(1), '*')
            end,
            'каталог — строка, а не число',
        },
        {
            function()
                fs.glob(helper.root(), '[ab]*')
            end,
            'образец — строка по образцу',
        },
        {
            function()
                fs.glob(helper.root(), 'a*]')
            end,
            'образец — строка по образцу',
        },
        {
            function()
                fs.glob(helper.root(), '/etc/*')
            end,
            'образец — строка по образцу',
        },
        {
            function()
                fs.glob(helper.root(), '')
            end,
            'образец — строка по образцу',
        },
        {
            function()
                fs.make_tree(at('a'), { mode = 512 })
            end,
            'настройки.mode — число от 0 до 511, а не 512',
        },
        {
            function()
                fs.make_tree(at('a'), { mode = -1 })
            end,
            'настройки.mode — число от 0 до 511, а не -1',
        },
        {
            function()
                fs.make_tree(helper.wrong(1))
            end,
            'путь — строка, а не число',
        },
        {
            function()
                fs.remove_tree(helper.wrong(1))
            end,
            'путь — строка, а не число',
        },
    }

    helper.assert_blamed(cases)
end
