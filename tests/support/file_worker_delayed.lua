-- Test helper: delay before entering the ordinary file-worker protocol. The
-- busy wait occurs in the child process and must not stop the Fibers runtime.

local deadline = os.clock() + 0.05
while os.clock() < deadline do
end

dofile('./src/fibers/file/worker_main.lua')
