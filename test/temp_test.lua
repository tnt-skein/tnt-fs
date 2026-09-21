--- Проверки временных каталогов: где заводятся, какие права, уборка.

local errno = require('errno')
local fio = require('fio')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local fs = helper.fs

local g = helper.group('tnt.fs.temp')

--- Путь в каталоге проверки.
local at = helper.file

g.test_temp_dir_is_made_in_the_system_place_closed = function()
    local path = fs.temp_dir()

    t.assert_equals(fio.stat(path):is_dir(), true)
    t.assert_equals(helper.mode_of(path), '700')

    fio.rmdir(path)
end

g.test_temp_dir_that_the_system_refuses_is_a_pair = function()
    fs._set_source({
        fio = helper.fio({
            tempdir = function()
                return nil, helper.refusal(errno.ENOENT)
            end,
        }),
    })

    local path, err = fs.temp_dir()

    t.assert_equals(path, nil)
    t.assert_equals(
        { err.kind, err.path, err.message },
        { 'missing', nil, 'временный каталог не заведён: No such file or directory' }
    )
end

g.test_temp_dir_within_is_hidden_random_and_closed = function()
    local path = fs.temp_dir({ within = helper.root() })
    local name = fio.basename(path)

    t.assert_equals(fio.dirname(path), helper.root())
    t.assert_str_matches(name, '%.tmp%-' .. ('%x'):rep(16))
    t.assert_equals(helper.mode_of(path), '700')
    t.assert_not_equals(fs.temp_dir({ within = helper.root() }), path)
end

g.test_temp_dir_within_takes_its_name_from_the_externals = function()
    fs._set_source({
        unique = function()
            return 'f00d'
        end,
    })

    t.assert_equals(fs.temp_dir({ within = helper.root() }), at('.tmp-f00d'))
end

g.test_temp_dir_within_a_missing_directory_is_a_pair = function()
    local path, err = fs.temp_dir({ within = at('none') })

    t.assert_equals(path, nil)
    t.assert_equals({ err.kind, err.path, err.message }, {
        'missing',
        at('none'),
        ('временный каталог в %s не заведён: No such file or directory'):format(at('none')),
    })
end

g.test_with_temp_dir_gives_back_every_answer_and_removes_the_directory = function()
    local seen = {}

    --- Работа с черновиком: пишет вглубь и отвечает четырьмя значениями,
    --- два из которых пустые.
    local function work(path)
        table.insert(seen, path)
        helper.put(fio.pathjoin(path, 'deep/file.txt'), 'черновик')

        return 1, nil, 'три', nil
    end

    local first, second, third = fs.with_temp_dir(work, { within = helper.root() })
    local count = select('#', fs.with_temp_dir(work, { within = helper.root() }))

    t.assert_equals({ first, second, third }, { 1, nil, 'три' })
    t.assert_equals(count, 4)
    t.assert_equals(fio.dirname(seen[1]), helper.root())
    t.assert_equals(fio.listdir(helper.root()), {})
end

g.test_with_temp_dir_passes_the_pair_of_the_work = function()
    local ok, err = fs.with_temp_dir(function()
        return nil, 'работа отказала'
    end, { within = helper.root() })

    t.assert_equals({ ok, err }, { nil, 'работа отказала' })
    t.assert_equals(fio.listdir(helper.root()), {})
end

g.test_with_temp_dir_removes_the_directory_and_throws_the_same_value = function()
    local thrown = { code = 'сбой' }

    local _, err = pcall(fs.with_temp_dir, function()
        error(thrown)
    end, { within = helper.root() })

    t.assert_is(err, thrown)
    t.assert_equals(fio.listdir(helper.root()), {})

    local _, text = pcall(fs.with_temp_dir, function()
        error('сбой без места', 0)
    end, { within = helper.root() })

    t.assert_equals(text, 'сбой без места')
end

g.test_with_temp_dir_that_cannot_remove_is_a_pair = function()
    -- Работа сама снесла свой каталог: убирать нечего, и об этом
    -- вызывающий узнаёт, а не получает ответ работы как ни в чём не бывало.
    local ok, err = fs.with_temp_dir(function(path)
        fio.rmdir(path)

        return 'готово'
    end, { within = helper.root() })

    t.assert_equals(ok, nil)
    t.assert_equals(err.kind, 'missing')
end

g.test_with_temp_dir_that_throws_and_cannot_remove_throws = function()
    local _, err = pcall(fs.with_temp_dir, function(path)
        fio.rmdir(path)
        error('сбой', 0)
    end, { within = helper.root() })

    t.assert_equals(err, 'сбой')
end

g.test_with_temp_dir_that_cannot_make_the_directory_does_not_run_the_work = function()
    local ran = false

    local ok, err = fs.with_temp_dir(function()
        ran = true
    end, { within = at('none') })

    t.assert_equals(ok, nil)
    t.assert_equals(err.kind, 'missing')
    t.assert_equals(ran, false)
end

g.test_wrong_arguments_blame_the_caller = function()
    local cases = {
        {
            function()
                fs.temp_dir(helper.wrong({ where = '/tmp' }))
            end,
            'настройки: ключа «where» нет, есть within',
        },
        {
            function()
                fs.temp_dir({ within = helper.wrong(1) })
            end,
            'настройки.within — строка, а не число',
        },
        {
            function()
                fs.with_temp_dir(helper.wrong('работа'))
            end,
            'работа — функция или вызываемая таблица, а не строка',
        },
        {
            function()
                fs.with_temp_dir(function() end, helper.wrong({ within = 1 }))
            end,
            'настройки.within — строка, а не число',
        },
    }

    helper.assert_blamed(cases)
end
