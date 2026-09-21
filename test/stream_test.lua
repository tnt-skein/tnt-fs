--- Проверки чтения и записи кусками: читатель и писатель файла.

local errno = require('errno')
local fio = require('fio')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local fs = helper.fs

local g = helper.group('tnt.fs.stream')

--- Путь в каталоге проверки.
local at = helper.file

--- Все куски читателя до конца.
local drain = helper.drain

g.test_reader_gives_the_file_in_chunks_of_the_size_asked = function()
    helper.put(at('a.txt'), 'abcdefg')

    local reader = fs.reader(at('a.txt'), { chunk = 3 })
    local chunks, err = drain(reader)

    t.assert_equals(chunks, { 'abc', 'def', 'g' })
    t.assert_equals(err, nil)
    -- Читать после конца можно: то же, чем кончилось.
    t.assert_equals({ reader:read() }, {})
    t.assert_equals(reader.path, at('a.txt'))
end

g.test_reader_chunk_is_64_kilobytes_by_default = function()
    helper.put(at('big.bin'), ('x'):rep(fs.CHUNK + 1))

    local chunks = drain(fs.reader(at('big.bin')))

    t.assert_equals(fs.CHUNK, 65536)
    t.assert_equals({ #chunks, #chunks[1], #chunks[2] }, { 2, 65536, 1 })
end

g.test_reader_of_an_empty_file_ends_at_once = function()
    helper.put(at('empty.txt'), '')

    t.assert_equals({ fs.reader(at('empty.txt')):read() }, {})
end

g.test_reader_of_a_missing_file_is_a_pair_at_opening = function()
    local reader, err = fs.reader(at('none.txt'))

    t.assert_equals(reader, nil)
    t.assert_equals({ err.kind, err.errno, err.path, err.message }, {
        'missing',
        errno.ENOENT,
        at('none.txt'),
        ('файл %s не открыт на чтение: No such file or directory'):format(at('none.txt')),
    })
end

g.test_reader_of_a_directory_fails_on_reading_and_keeps_the_failure = function()
    local reader = fs.reader(helper.root())
    local chunk, err = reader:read()

    t.assert_equals(chunk, nil)
    t.assert_equals({ err.kind, err.errno, err.path, err.message }, {
        'failed',
        errno.EISDIR,
        helper.root(),
        ('файл %s не прочитан: Is a directory'):format(helper.root()),
    })
    t.assert_is(select(2, reader:read()), err)
end

g.test_reader_closes_the_file_at_the_end_and_on_failure = function()
    local calls = helper.opening({ read = { '' } })

    t.assert_equals({ fs.reader(at('a.txt')):read() }, {})
    t.assert_equals(calls, { 'read', 'close' })

    calls = helper.opening({ read = { nil, helper.refusal(errno.EIO) } })

    local chunk, err = fs.reader(at('a.txt')):read()

    t.assert_equals({ chunk, err.kind, err.errno }, { nil, 'failed', errno.EIO })
    t.assert_equals(calls, { 'read', 'close' })
end

g.test_reader_close_closes_once_and_forbids_reading = function()
    local calls = helper.opening({ read = { 'кусок' } })
    local reader = fs.reader(at('a.txt'))

    t.assert_equals(reader:read(), 'кусок')
    t.assert_equals(reader:close(), true)
    t.assert_equals(reader:close(), true)
    t.assert_equals(calls, { 'read', 'close' })

    local line
    local _, err = pcall(function()
        line = helper.here() + 1
        reader:read()
    end)

    t.assert_equals(
        err,
        helper.at(line) .. ('read: читатель файла %s уже закрыт'):format(at('a.txt'))
    )
end

g.test_reader_close_after_the_end_does_not_close_twice = function()
    local calls = helper.opening({ read = { '' } })
    local reader = fs.reader(at('a.txt'))

    reader:read()

    t.assert_equals(reader:close(), true)
    t.assert_equals(calls, { 'read', 'close' })
end

g.test_writer_puts_the_chunks_in_place_only_on_finish = function()
    helper.put(at('export.csv'), 'старое')

    local writer = fs.writer(at('export.csv'))

    t.assert_equals({ writer:write('первая\n') }, { true })
    t.assert_equals({ writer:write('') }, { true })
    t.assert_equals({ writer:write('вторая\n') }, { true })
    -- До конца записи читающий видит старое, а черновик лежит рядом скрытым.
    t.assert_equals(helper.get(at('export.csv')), 'старое')
    t.assert_equals(#fio.listdir(helper.root()), 2)

    t.assert_equals({ writer:finish() }, { true })

    t.assert_equals(helper.get(at('export.csv')), 'первая\nвторая\n')
    t.assert_equals(fio.listdir(helper.root()), { 'export.csv' })
    t.assert_equals(writer.path, at('export.csv'))
end

g.test_writer_rights_are_the_old_file_ones_or_closed_or_given = function()
    helper.put(at('secret'), 'старое', '600')

    local writers = {
        fs.writer(at('secret')),
        fs.writer(at('fresh')),
        fs.writer(at('given'), { mode = helper.mode('604') }),
    }

    for _, writer in ipairs(writers) do
        writer:write('новое')
        writer:finish()
    end

    t.assert_equals(
        { helper.mode_of(at('secret')), helper.mode_of(at('fresh')), helper.mode_of(at('given')) },
        { '600', '640', '604' }
    )
end

g.test_writer_into_a_missing_directory_is_a_pair = function()
    local writer, err = fs.writer(at('none/state.json'))

    t.assert_equals(writer, nil)
    t.assert_equals({ err.kind, err.path, err.message }, {
        'missing',
        at('none/state.json'),
        ('файл %s не записан: No such file or directory'):format(at('none/state.json')),
    })
end

g.test_abort_removes_the_temporary_and_keeps_the_target = function()
    helper.put(at('state.json'), 'старое')

    local writer = fs.writer(at('state.json'))

    writer:write('новое')

    t.assert_equals(writer:abort(), true)
    t.assert_equals(writer:abort(), true)
    t.assert_equals(helper.get(at('state.json')), 'старое')
    t.assert_equals(fio.listdir(helper.root()), { 'state.json' })
end

g.test_abort_after_finish_keeps_the_file = function()
    local writer = fs.writer(at('state.json'))

    writer:write('новое')
    writer:finish()

    t.assert_equals(writer:abort(), true)
    t.assert_equals(helper.get(at('state.json')), 'новое')
end

--- Писатель поверх ручки, которая отвечает заданным, а переименование
--- и удаление идут настоящим `fio`.
---@param answers table<string, any[]>
---@return any writer
---@return string[] calls
local function writer_over(answers)
    local handle, calls = helper.handle(answers)
    local opened = false

    helper.with_fio({
        open = function(path, flags, mode)
            if opened then
                return fio.open(path, flags, mode)
            end

            opened = true
            fio.open(path, flags, mode):close()

            return handle
        end,
    })

    return fs.writer(at('state.json')), calls
end

g.test_a_failed_write_removes_the_temporary_and_is_kept = function()
    local writer, calls = writer_over({ write = { false, helper.refusal(errno.ENOSPC) } })
    local ok, err = writer:write('x')

    t.assert_equals(ok, nil)
    t.assert_equals({ err.kind, err.path, err.message }, {
        'full',
        at('state.json'),
        ('файл %s не записан: %s'):format(at('state.json'), errno.strerror(errno.ENOSPC)),
    })
    t.assert_equals(fio.listdir(helper.root()), {})
    t.assert_equals(calls, { 'write', 'close' })

    -- Дальше писатель отвечает тем же отказом и ничего не пишет.
    t.assert_is(select(2, writer:write('y')), err)
    t.assert_is(select(2, writer:finish()), err)
    t.assert_equals(writer:abort(), true)
    t.assert_equals(calls, { 'write', 'close' })
end

g.test_a_failed_flush_removes_the_temporary = function()
    local writer, calls = writer_over({ fsync = { false, helper.refusal(errno.EIO) } })

    writer:write('x')

    local ok, err = writer:finish()

    t.assert_equals({ ok, err.kind, err.errno }, { nil, 'failed', errno.EIO })
    t.assert_equals(calls, { 'write', 'fsync', 'close' })
    t.assert_equals(fio.listdir(helper.root()), {})
end

g.test_a_failed_close_removes_the_temporary = function()
    local writer, calls = writer_over({ close = { false, helper.refusal(errno.EDQUOT) } })

    writer:write('x')

    local ok, err = writer:finish()

    t.assert_equals({ ok, err.kind, err.errno }, { nil, 'full', errno.EDQUOT })
    t.assert_equals(calls, { 'write', 'fsync', 'close' })
    t.assert_equals(fio.listdir(helper.root()), {})
    t.assert_is(select(2, writer:finish()), err)
end

g.test_a_failed_rename_keeps_the_old_file_and_removes_the_temporary = function()
    helper.put(at('state.json'), 'старое')

    local writer = fs.writer(at('state.json'))

    helper.with_fio({
        rename = function()
            return false, helper.refusal(errno.EXDEV)
        end,
    })
    writer:write('новое')

    local ok, err = writer:finish()

    t.assert_equals({ ok, err.kind, err.errno }, { nil, 'failed', errno.EXDEV })
    t.assert_equals(helper.get(at('state.json')), 'старое')
    t.assert_equals(fio.listdir(helper.root()), { 'state.json' })
end

g.test_an_unflushed_directory_is_a_pair_with_the_file_in_place = function()
    local writer = fs.writer(at('state.json'))

    helper.with_fio({
        open = function(path, flags, mode)
            if path == helper.root() then
                return nil, helper.refusal(errno.EACCES)
            end

            return fio.open(path, flags, mode)
        end,
    })
    writer:write('новое')

    local ok, err = writer:finish()

    t.assert_equals({ ok, err.kind, err.path }, { nil, 'denied', helper.root() })
    t.assert_equals(helper.get(at('state.json')), 'новое')

    -- Файл на месте, и писатель кончил: запись после — ошибка кода.
    t.assert_error_msg_contains('уже закончен', writer.write, writer, 'x')
end

g.test_writing_after_the_end_blames_the_caller = function()
    local writer = fs.writer(at('a.txt'))

    writer:finish()

    local cases = {
        {
            function()
                writer:write('x')
            end,
            ('write: писатель файла %s уже закончен'):format(at('a.txt')),
        },
        {
            function()
                writer:finish()
            end,
            ('finish: писатель файла %s уже закончен'):format(at('a.txt')),
        },
    }

    helper.assert_blamed(cases)

    local aborted = fs.writer(at('b.txt'))

    aborted:abort()

    helper.assert_blamed({
        {
            function()
                aborted:write('x')
            end,
            'уже закончен',
        },
    })
end

g.test_wrong_arguments_blame_the_caller = function()
    local writer = fs.writer(at('a.txt'))
    local cases = {
        {
            function()
                fs.reader(helper.wrong(1))
            end,
            'путь — строка, а не число',
        },
        {
            function()
                fs.reader(at('a'), helper.wrong({ size = 1 }))
            end,
            'настройки: ключа «size» нет, есть chunk',
        },
        {
            function()
                fs.reader(at('a'), { chunk = 0 })
            end,
            'настройки.chunk — число от 1 до 67108864, а не 0',
        },
        {
            function()
                fs.reader(at('a'), { chunk = 64 * 1024 * 1024 + 1 })
            end,
            'настройки.chunk — число от 1 до 67108864, а не 67108865',
        },
        {
            function()
                fs.writer(helper.wrong(nil))
            end,
            'путь — строка, а не nil',
        },
        {
            function()
                fs.writer(at('a'), { mode = 512 })
            end,
            'настройки.mode — число от 0 до 511, а не 512',
        },
        {
            function()
                writer:write(helper.wrong(1))
            end,
            'кусок — строка, а не число',
        },
    }

    helper.assert_blamed(cases)
    writer:abort()
end

g.test_the_largest_chunk_is_accepted = function()
    helper.put(at('a.txt'), 'x')

    t.assert_equals(fs.reader(at('a.txt'), { chunk = 64 * 1024 * 1024 }):read(), 'x')
    t.assert_equals(fs.reader(at('a.txt'), { chunk = 1 }):read(), 'x')
end

g.test_reading_and_writing_in_chunks_do_not_hold_the_node = function()
    local neighbour = helper.neighbour()
    local writer = fs.writer(at('a.txt'))
    ---@type any
    local reader

    local steps = {
        function()
            return writer:write('x')
        end,
        function()
            return writer:finish()
        end,
        function()
            reader = fs.reader(at('a.txt'))

            return reader:read()
        end,
    }

    for index, step in ipairs(steps) do
        local before = neighbour.ticks

        t.assert(step(), index)
        t.assert_gt(neighbour.ticks, before, index)
    end

    reader:close()
    neighbour.stop()
end

g.test_pipe_pours_a_reader_into_a_writer = function()
    helper.put(at('a.txt'), 'abcdefg')
    helper.put(at('b.txt'), 'старое')

    t.assert_equals({ fs.pipe(fs.reader(at('a.txt'), { chunk = 3 }), fs.writer(at('b.txt'))) }, { true })
    t.assert_equals(helper.get(at('b.txt')), 'abcdefg')
end

--- Писатель, который записывает, что с ним делали.
---@param write_answer any[] Что отвечать на запись
---@return table writer
---@return string[] calls
local function recording_writer(write_answer)
    local calls = {}

    return {
        write = function(_, chunk)
            table.insert(calls, 'write ' .. chunk)

            return unpack(write_answer)
        end,
        finish = function()
            table.insert(calls, 'finish')

            return 'итог', 'второе'
        end,
        abort = function()
            table.insert(calls, 'abort')
        end,
    },
        calls
end

g.test_pipe_gives_what_the_writer_finish_gives = function()
    helper.put(at('a.txt'), 'ab')

    local writer, calls = recording_writer({ true })

    t.assert_equals({ fs.pipe(fs.reader(at('a.txt'), { chunk = 1 }), writer) }, { 'итог', 'второе' })
    t.assert_equals(calls, { 'write a', 'write b', 'finish' })
end

g.test_pipe_aborts_the_writer_when_reading_fails = function()
    local writer, calls = recording_writer({ true })
    local done, err = fs.pipe(fs.reader(helper.root()), writer)

    t.assert_equals({ done, err.kind, err.errno }, { nil, 'failed', errno.EISDIR })
    t.assert_equals(calls, { 'abort' })
end

g.test_pipe_closes_the_reader_when_writing_fails = function()
    local refusal = { kind = 'full' }
    local writer, calls = recording_writer({ nil, refusal })
    local handle, handled = helper.handle({ read = { 'кусок' } })

    helper.with_fio({
        open = function()
            return handle
        end,
    })

    local done, err = fs.pipe(fs.reader(at('a.txt')), writer)

    t.assert_equals(done, nil)
    t.assert_is(err, refusal)
    t.assert_equals(calls, { 'write кусок' })
    t.assert_equals(handled, { 'read', 'close' })
end

g.test_pipe_wants_a_reader_and_a_writer = function()
    local writer = recording_writer({ true })

    helper.assert_blamed({
        {
            function()
                fs.pipe(helper.wrong('a.txt'), writer)
            end,
            'читатель — таблица, а не строка',
        },
        {
            function()
                fs.pipe(writer, helper.wrong(nil))
            end,
            'писатель — таблица, а не nil',
        },
    })
end
