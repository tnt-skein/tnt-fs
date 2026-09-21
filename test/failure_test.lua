--- Проверки отказа: род по коду, разбор строки, вид строкой.

local errno = require('errno')
local fio = require('fio')
local json = require('json')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local failure = helper.failure

local g = t.group('tnt.fs.failure')

g.test_each_code_has_its_kind_and_the_reason_in_words = function()
    local expected = {
        { errno.ENOENT, 'missing' },
        { errno.ENOTDIR, 'missing' },
        { errno.EEXIST, 'exists' },
        { errno.ENOTEMPTY, 'exists' },
        { errno.EACCES, 'denied' },
        { errno.EPERM, 'denied' },
        { errno.EROFS, 'denied' },
        { errno.ENOSPC, 'full' },
        { errno.EDQUOT, 'full' },
        { errno.EISDIR, 'failed' },
        { errno.EXDEV, 'failed' },
    }

    for _, case in ipairs(expected) do
        local code, kind = case[1], case[2]
        local err = failure.from('файл /a не прочитан', '/a', helper.refusal(code))

        t.assert_equals(
            { err.kind, err.errno, err.path, err.message },
            { kind, code, '/a', 'файл /a не прочитан: ' .. errno.strerror(code) },
            errno.strerror(code)
        )
    end
end

g.test_the_kinds_are_named_by_constants = function()
    t.assert_equals(
        { failure.MISSING, failure.EXISTS, failure.DENIED, failure.FULL, failure.FAILED },
        { 'missing', 'exists', 'denied', 'full', 'failed' }
    )
end

g.test_an_unknown_code_is_failed_and_keeps_the_code = function()
    local err = failure.from('файл /a не записан', '/a', helper.refusal(errno.EIO))

    t.assert_equals(
        { err.kind, err.errno, err.message },
        { 'failed', errno.EIO, 'файл /a не записан: Input/output error' }
    )
end

g.test_a_real_error_of_fio_is_read_by_its_code = function()
    local _, reason = fio.open('/nonexistent/tnt-fs/file', { 'O_RDONLY' })
    local err = failure.from('файл не прочитан', '/nonexistent/tnt-fs/file', reason)

    t.assert_equals(
        { err.kind, err.errno, err.message },
        { 'missing', errno.ENOENT, 'файл не прочитан: No such file or directory' }
    )
end

g.test_a_string_is_read_by_the_reason_at_its_end = function()
    local err = failure.from('каталог /a не создан', '/a', 'Error creating directory /a: File exists')

    t.assert_equals(
        { err.kind, err.errno, err.message },
        { 'exists', errno.EEXIST, 'каталог /a не создан: File exists' }
    )
end

g.test_the_same_words_inside_a_path_do_not_count = function()
    -- Путь волен называться словами причины: сверяется конец текста.
    local err = failure.from(
        'файл не скопирован',
        '/a',
        'failed to copy /No such file or directory to /b: fio: Permission denied'
    )

    t.assert_equals({ err.kind, err.errno }, { 'denied', errno.EACCES })
end

g.test_a_string_without_a_known_reason_is_failed_as_is = function()
    local err = failure.from('каталог /a не прочитан', '/a', 'что-то пошло не так')

    t.assert_equals(
        { err.kind, err.errno, err.message },
        { 'failed', nil, 'каталог /a не прочитан: что-то пошло не так' }
    )
end

g.test_an_error_without_a_code_is_failed_with_its_text = function()
    local reason = setmetatable({}, {
        __tostring = function()
            return 'сломалось'
        end,
    })
    local err = failure.from('файл /a не прочитан', '/a', reason)

    t.assert_equals(
        { err.kind, err.errno, err.message },
        { 'failed', nil, 'файл /a не прочитан: сломалось' }
    )
end

g.test_a_refusal_without_a_reason_is_failed_and_says_so = function()
    local err = failure.from('файл /a не записан', '/a', nil)

    t.assert_equals(
        { err.kind, err.errno, err.message },
        { 'failed', nil, 'файл /a не записан: причина неизвестна' }
    )
end

g.test_a_failure_reads_as_its_text_everywhere = function()
    local err = failure.from('файл /a не прочитан', '/a', helper.refusal(errno.ENOENT))
    local text = 'файл /a не прочитан: No such file or directory'

    t.assert_equals(tostring(err), text)
    t.assert_equals(json.encode({ err = err }), json.encode({ err = text }))
    t.assert_equals('причина: ' .. err, 'причина: ' .. text)
    t.assert_equals(err .. '.', text .. '.')
end

g.test_an_outcome_of_success_is_true = function()
    t.assert_equals({ failure.outcome('не удалось', '/a', true) }, { true })
end

g.test_an_outcome_of_a_refusal_is_a_pair = function()
    -- Ложь отдают простые действия `fio`, пустоту — составные.
    local refused, refusal = failure.outcome('/a не удалён', '/a', false, helper.refusal(errno.EACCES))
    local nothing, reason =
        failure.outcome('/a не удалён', '/a', nil, 'failed to remove /a: fio: Permission denied')

    t.assert_equals({ refused, nothing }, { nil, nil })

    for _, err in ipairs({ refusal, reason }) do
        t.assert_equals({ err.kind, err.message }, { 'denied', '/a не удалён: Permission denied' })
    end
end
