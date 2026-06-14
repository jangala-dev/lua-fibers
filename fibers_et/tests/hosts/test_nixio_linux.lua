package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')
return dofile('tests/hosts/test_nixio.lua')
