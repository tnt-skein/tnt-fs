--- Проверки фасада: роды отказа и действия под своими именами.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local fs = helper.fs

local g = t.group('tnt.fs')

g.test_the_kinds_of_failure_are_named = function()
    t.assert_equals(
        { fs.MISSING, fs.EXISTS, fs.DENIED, fs.FULL, fs.FAILED },
        { 'missing', 'exists', 'denied', 'full', 'failed' }
    )
end

g.test_the_default_rights_are_closed = function()
    t.assert_equals(helper.octal(fs.MODE), '640')
end

g.test_every_action_is_in_place = function()
    local names = {
        'read',
        'write',
        'append',
        'replace',
        'copy',
        'rename',
        'remove',
        'stat',
        'exists',
        'list',
        'glob',
        'make_tree',
        'remove_tree',
        'temp_dir',
        'with_temp_dir',
        '_set_source',
    }

    for _, name in ipairs(names) do
        t.assert_type(fs[name], 'function', name)
    end
end
