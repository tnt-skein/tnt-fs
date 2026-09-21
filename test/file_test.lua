--- Проверки файлов целиком: чтение, запись, дозапись, подмена, копия,
--- перенос, удаление.

local errno = require('errno')
local fio = require('fio')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local fs = helper.fs

local g = helper.group('tnt.fs.file')

--- Путь в каталоге проверки.
local at = helper.file

g.test_read_gives_the_whole_file = function()
    helper.put(at('a.txt'), 'строка\nвторая')
    helper.put(at('empty.txt'), '')

    t.assert_equals(fs.read(at('a.txt')), 'строка\nвторая')
    t.assert_equals(fs.read(at('empty.txt')), '')
end

g.test_read_of_a_missing_file_is_a_pair = function()
    local content, err = fs.read(at('none.txt'))

    t.assert_equals(content, nil)
    t.assert_equals({ err.kind, err.errno, err.path, err.message }, {
        'missing',
        errno.ENOENT,
        at('none.txt'),
        ('файл %s не прочитан: No such file or directory'):format(at('none.txt')),
    })
end

g.test_read_of_a_directory_fails_on_reading_not_opening = function()
    local content, err = fs.read(helper.root())

    t.assert_equals(content, nil)
    t.assert_equals(
        { err.kind, err.errno, err.message },
        { 'failed', errno.EISDIR, ('файл %s не прочитан: Is a directory'):format(helper.root()) }
    )
end

g.test_read_closes_the_file = function()
    local calls = helper.opening({ read = { 'текст' } })

    t.assert_equals(fs.read(at('a.txt')), 'текст')
    t.assert_equals(calls, { 'read', 'close' })
end

g.test_write_creates_the_file_with_closed_rights = function()
    t.assert_equals({ fs.write(at('a.txt'), 'данные') }, { true })

    t.assert_equals(helper.get(at('a.txt')), 'данные')
    t.assert_equals(helper.mode_of(at('a.txt')), '640')
    t.assert_equals(helper.octal(fs.MODE), '640')
end

g.test_write_overwrites_from_the_start = function()
    helper.put(at('a.txt'), 'длинное старое содержимое')

    fs.write(at('a.txt'), 'новое')

    t.assert_equals(helper.get(at('a.txt')), 'новое')
end

g.test_write_takes_the_rights_it_is_given = function()
    fs.write(at('a.txt'), 'x', { mode = helper.mode('604') })
    fs.write(at('b.txt'), 'x', { mode = 0 })
    fs.write(at('c.txt'), 'x', { mode = 511 })

    t.assert_equals(helper.mode_of(at('a.txt')), '604')
    t.assert_equals(helper.mode_of(at('b.txt')), '0')
    t.assert_equals(helper.mode_of(at('c.txt')), '755')
end

g.test_write_into_a_missing_directory_is_a_pair = function()
    local ok, err = fs.write(at('none/a.txt'), 'x')

    t.assert_equals(ok, nil)
    t.assert_equals({ err.kind, err.path, err.message }, {
        'missing',
        at('none/a.txt'),
        ('файл %s не записан: No such file or directory'):format(at('none/a.txt')),
    })
end

g.test_write_flushes_and_closes = function()
    local handle, calls = helper.handle({})
    local opened = {}

    helper.with_fio({
        open = function(path, flags, mode)
            table.insert(opened, { path, flags, mode })

            return handle
        end,
    })

    t.assert_equals({ fs.write(at('a.txt'), 'x') }, { true })
    t.assert_equals(calls, { 'write', 'fsync', 'close' })
    t.assert_equals(opened, { { at('a.txt'), { 'O_WRONLY', 'O_CREAT', 'O_TRUNC' }, helper.mode('640') } })
end

g.test_a_failed_write_is_not_flushed_but_closed = function()
    local calls = helper.opening({ write = { false, helper.refusal(errno.ENOSPC) } })

    local ok, err = fs.write(at('a.txt'), 'x')

    t.assert_equals(ok, nil)
    t.assert_equals(
        { err.kind, err.message },
        { 'full', ('файл %s не записан: No space left on device'):format(at('a.txt')) }
    )
    t.assert_equals(calls, { 'write', 'close' })
end

g.test_a_failed_flush_is_a_pair = function()
    local calls = helper.opening({ fsync = { false, helper.refusal(errno.EIO) } })

    local ok, err = fs.write(at('a.txt'), 'x')

    t.assert_equals(ok, nil)
    t.assert_equals({ err.kind, err.errno }, { 'failed', errno.EIO })
    t.assert_equals(calls, { 'write', 'fsync', 'close' })
end

g.test_a_failed_close_is_a_pair = function()
    -- Сетевая файловая система сообщает об отказе записи на закрытии.
    helper.opening({ close = { false, helper.refusal(errno.EDQUOT) } })

    local ok, err = fs.append(at('a.txt'), 'x')

    t.assert_equals(ok, nil)
    t.assert_equals(
        { err.kind, err.message },
        { 'full', ('файл %s не дописан: %s'):format(at('a.txt'), errno.strerror(errno.EDQUOT)) }
    )
end

g.test_append_adds_to_the_end_and_creates_the_file = function()
    t.assert_equals({ fs.append(at('a.txt'), 'раз\n') }, { true })
    t.assert_equals({ fs.append(at('a.txt'), 'два\n') }, { true })

    t.assert_equals(helper.get(at('a.txt')), 'раз\nдва\n')
    t.assert_equals(helper.mode_of(at('a.txt')), '640')
end

g.test_append_takes_the_rights_it_is_given = function()
    fs.append(at('a.txt'), 'x', { mode = helper.mode('600') })

    t.assert_equals(helper.mode_of(at('a.txt')), '600')
end

g.test_append_into_a_missing_directory_is_a_pair = function()
    local ok, err = fs.append(at('none/a.txt'), 'x')

    t.assert_equals(ok, nil)
    t.assert_equals(err.kind, 'missing')
end

g.test_replace_puts_the_new_content_and_leaves_no_temporary = function()
    helper.put(at('state.json'), '{"old":true}')

    t.assert_equals({ fs.replace(at('state.json'), '{"new":true}') }, { true })

    t.assert_equals(helper.get(at('state.json')), '{"new":true}')
    t.assert_equals(fio.listdir(helper.root()), { 'state.json' })
end

g.test_replace_creates_a_missing_file_with_closed_rights = function()
    t.assert_equals({ fs.replace(at('state.json'), 'x') }, { true })

    t.assert_equals(helper.get(at('state.json')), 'x')
    t.assert_equals(helper.mode_of(at('state.json')), '640')
end

g.test_replace_keeps_the_rights_of_the_old_file = function()
    -- Подмена не должна молча открыть файл с тайнами шире, чем он был.
    helper.put(at('secret'), 'старое', '600')
    helper.put(at('public'), 'старое', '605')

    fs.replace(at('secret'), 'новое')
    fs.replace(at('public'), 'новое')

    t.assert_equals(helper.mode_of(at('secret')), '600')
    t.assert_equals(helper.mode_of(at('public')), '605')
end

g.test_replace_takes_the_rights_it_is_given = function()
    helper.put(at('secret'), 'старое', '600')

    fs.replace(at('secret'), 'новое', { mode = helper.mode('644') })

    t.assert_equals(helper.mode_of(at('secret')), '644')
end

g.test_replace_writes_a_fresh_temporary_beside_the_target = function()
    local opened = {}

    fs._set_source({
        unique = function()
            return 'f00d'
        end,
        fio = helper.fio({
            open = function(path, flags, mode)
                table.insert(opened, { path, flags, mode })

                return fio.open(path, flags, mode)
            end,
        }),
    })

    fs.replace(at('state.json'), 'x')

    t.assert_equals(opened, {
        { at('.state.json.f00d.tmp'), { 'O_WRONLY', 'O_CREAT', 'O_EXCL' }, helper.mode('640') },
        { helper.root(), { 'O_RDONLY' } },
    })
end

g.test_replace_into_a_missing_directory_is_a_pair = function()
    local ok, err = fs.replace(at('none/state.json'), 'x')

    t.assert_equals(ok, nil)
    t.assert_equals({ err.kind, err.path, err.message }, {
        'missing',
        at('none/state.json'),
        ('файл %s не заменён: No such file or directory'):format(at('none/state.json')),
    })
end

g.test_a_failed_write_of_the_temporary_removes_it = function()
    helper.with_fio({
        open = function(path, flags, mode)
            local file = fio.open(path, flags, mode)

            return {
                write = function()
                    return false, helper.refusal(errno.ENOSPC)
                end,
                close = function()
                    return file:close()
                end,
            }
        end,
    })

    local ok, err = fs.replace(at('state.json'), 'x')

    t.assert_equals(ok, nil)
    t.assert_equals({ err.kind, err.path }, { 'full', at('state.json') })
    t.assert_equals(fio.listdir(helper.root()), {})
end

g.test_a_failed_rename_keeps_the_old_file_and_removes_the_temporary = function()
    helper.put(at('state.json'), 'старое')

    helper.with_fio({
        rename = function()
            return false, helper.refusal(errno.EXDEV)
        end,
    })

    local ok, err = fs.replace(at('state.json'), 'новое')

    t.assert_equals(ok, nil)
    t.assert_equals({ err.kind, err.errno, err.message }, {
        'failed',
        errno.EXDEV,
        ('файл %s не заменён: %s'):format(at('state.json'), errno.strerror(errno.EXDEV)),
    })
    t.assert_equals(helper.get(at('state.json')), 'старое')
    t.assert_equals(fio.listdir(helper.root()), { 'state.json' })
end

g.test_a_directory_that_does_not_open_for_flushing_is_a_pair = function()
    helper.with_fio({
        open = function(path, flags, mode)
            if path == helper.root() then
                return nil, helper.refusal(errno.EACCES)
            end

            return fio.open(path, flags, mode)
        end,
    })

    local ok, err = fs.replace(at('state.json'), 'новое')

    t.assert_equals(ok, nil)
    t.assert_equals({ err.kind, err.path, err.message }, {
        'denied',
        helper.root(),
        ('каталог %s не сброшен на диск: Permission denied'):format(helper.root()),
    })
    -- Файл уже на месте: не сброшен только каталог.
    t.assert_equals(helper.get(at('state.json')), 'новое')
end

g.test_a_directory_that_does_not_flush_is_a_pair_and_is_closed = function()
    local handle, calls = helper.handle({ fsync = { false, helper.refusal(errno.EIO) } })

    helper.with_fio({
        open = function(path, flags, mode)
            if path == helper.root() then
                return handle
            end

            return fio.open(path, flags, mode)
        end,
    })

    local ok, err = fs.replace(at('state.json'), 'новое')

    t.assert_equals(ok, nil)
    t.assert_equals({ err.kind, err.errno, err.path }, { 'failed', errno.EIO, helper.root() })
    t.assert_equals(calls, { 'fsync', 'close' })
end

g.test_copy_copies_the_content = function()
    helper.put(at('a.txt'), 'данные')

    t.assert_equals({ fs.copy(at('a.txt'), at('b.txt')) }, { true })

    t.assert_equals(helper.get(at('b.txt')), 'данные')
    t.assert_equals(helper.get(at('a.txt')), 'данные')
end

g.test_copy_into_a_directory_keeps_the_name = function()
    helper.put(at('a.txt'), 'данные')
    fio.mkdir(at('copies'))

    fs.copy(at('a.txt'), at('copies'))

    t.assert_equals(helper.get(at('copies/a.txt')), 'данные')
end

g.test_copy_of_a_missing_file_is_a_pair = function()
    local ok, err = fs.copy(at('none.txt'), at('b.txt'))

    t.assert_equals(ok, nil)
    t.assert_equals({ err.kind, err.errno, err.path, err.message }, {
        'missing',
        errno.ENOENT,
        at('none.txt'),
        ('файл %s не скопирован в %s: No such file or directory'):format(at('none.txt'), at('b.txt')),
    })
end

g.test_rename_moves_the_file = function()
    helper.put(at('a.txt'), 'данные')

    t.assert_equals({ fs.rename(at('a.txt'), at('b.txt')) }, { true })

    t.assert_equals(helper.get(at('b.txt')), 'данные')
    t.assert_equals(helper.get(at('a.txt')), nil)
end

g.test_rename_of_a_missing_file_is_a_pair = function()
    local ok, err = fs.rename(at('none.txt'), at('b.txt'))

    t.assert_equals(ok, nil)
    t.assert_equals({ err.kind, err.path, err.message }, {
        'missing',
        at('none.txt'),
        ('%s не перенесён в %s: No such file or directory'):format(at('none.txt'), at('b.txt')),
    })
end

g.test_remove_removes_a_file = function()
    helper.put(at('a.txt'), 'x')

    t.assert_equals({ fs.remove(at('a.txt')) }, { true })

    t.assert_equals(fio.listdir(helper.root()), {})
end

g.test_remove_of_a_link_keeps_what_it_points_to = function()
    helper.put(at('a.txt'), 'данные')
    fio.symlink(at('a.txt'), at('link'))

    fs.remove(at('link'))

    t.assert_equals(fio.listdir(helper.root()), { 'a.txt' })
end

g.test_remove_of_a_missing_file_is_a_pair = function()
    local ok, err = fs.remove(at('none.txt'))

    t.assert_equals(ok, nil)
    t.assert_equals(
        { err.kind, err.path, err.message },
        { 'missing', at('none.txt'), ('%s не удалён: No such file or directory'):format(at('none.txt')) }
    )
end

g.test_wrong_arguments_blame_the_caller = function()
    local cases = {
        {
            function()
                fs.read(helper.wrong(1))
            end,
            'путь — строка, а не число',
        },
        {
            function()
                fs.write(at('a'), helper.wrong(nil))
            end,
            'содержимое — строка, а не nil',
        },
        {
            function()
                fs.append(helper.wrong(nil), 'x')
            end,
            'путь — строка, а не nil',
        },
        {
            function()
                fs.replace(at('a'), 'x', helper.wrong({ mod = 1 }))
            end,
            'настройки: ключа «mod» нет, есть mode',
        },
        {
            function()
                fs.write(at('a'), 'x', { mode = 512 })
            end,
            'настройки.mode — число от 0 до 511, а не 512',
        },
        {
            function()
                fs.write(at('a'), 'x', { mode = -1 })
            end,
            'настройки.mode — число от 0 до 511, а не -1',
        },
        {
            function()
                fs.copy(at('a'), helper.wrong(2))
            end,
            'куда — строка, а не число',
        },
        {
            function()
                fs.rename(helper.wrong(2), at('a'))
            end,
            'откуда — строка, а не число',
        },
        {
            function()
                fs.remove(helper.wrong(true))
            end,
            'путь — строка, а не логическое значение',
        },
    }

    helper.assert_blamed(cases)
end

g.test_the_blame_is_the_line_of_the_call = function()
    local line
    local _, err = pcall(function()
        line = helper.here() + 1
        fs.write(helper.wrong(1), 'x')
    end)

    t.assert_equals(err, helper.at(line) .. 'путь — строка, а не число')
end

g.test_reading_and_writing_do_not_hold_the_node = function()
    -- `io.open` ждёт диска в потоке событий: сосед не тикает вовсе.
    -- Здесь каждое действие уступает, пока диск работает.
    local neighbour = helper.neighbour()

    local steps = {
        function()
            return fs.write(at('a.txt'), 'x')
        end,
        function()
            return fs.read(at('a.txt'))
        end,
        function()
            return fs.replace(at('a.txt'), 'y')
        end,
        function()
            return fs.remove(at('a.txt'))
        end,
    }

    for index, step in ipairs(steps) do
        local before = neighbour.ticks

        t.assert(step(), index)
        t.assert_gt(neighbour.ticks, before, index)
    end

    neighbour.stop()
end
