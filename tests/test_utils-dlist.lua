print('testing: fibers.utils.dlist')

package.path = '../src/?.lua;' .. package.path

local dlist = require 'fibers.utils.dlist'

local function assert_eq(a, b, msg)
	if a ~= b then
		error((msg or 'assert_eq failed') .. (': expected ' .. tostring(b) .. ', got ' .. tostring(a)), 2)
	end
end

local function test_push_pop_length_and_empty()
	local q = dlist.new()
	assert_eq(q:empty(), true)
	assert_eq(q:length(), 0)

	q:push_tail('a')
	q:push_tail('b')
	assert_eq(q:empty(), false)
	assert_eq(q:length(), 2)
	assert_eq(q:peek_head(), 'a')
	assert_eq(q:pop_head(), 'a')
	assert_eq(q:length(), 1)
	assert_eq(q:pop_head(), 'b')
	assert_eq(q:length(), 0)
	assert_eq(q:empty(), true)
	assert_eq(q:pop_head(), nil)
end

local function test_remove_middle_preserves_order()
	local q = dlist.new()
	q:push_tail('a')
	local b = q:push_tail('b')
	q:push_tail('c')

	assert_eq(b:remove(), true)
	assert_eq(q:length(), 2)
	assert_eq(q:pop_head(), 'a')
	assert_eq(q:pop_head(), 'c')
	assert_eq(q:pop_head(), nil)
end

local function test_remove_front_and_tail()
	local q = dlist.new()
	local a = q:push_tail('a')
	local b = q:push_tail('b')
	local c = q:push_tail('c')

	assert_eq(a:remove(), true)
	assert_eq(c:remove(), true)
	assert_eq(q:length(), 1)
	assert_eq(q:pop_head(), 'b')
	assert_eq(q:empty(), true)
	assert_eq(b:remove(), false)
end

local function test_double_remove_is_harmless()
	local q = dlist.new()
	local node = q:push_tail('x')
	assert_eq(node:remove(), true)
	assert_eq(node:remove(), false)
	assert_eq(q:length(), 0)
	assert_eq(q:empty(), true)
end

local function main()
	test_push_pop_length_and_empty()
	test_remove_middle_preserves_order()
	test_remove_front_and_tail()
	test_double_remove_is_harmless()
	print('All dlist tests passed!')
end

main()
