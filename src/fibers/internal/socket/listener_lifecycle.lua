-- Transactional lifecycle resource for socket listeners.

return require('fibers.internal.socket.lifecycle').define({
  prefix = 'socket.listener',
  error_domain = 'socket',
  start_action = 'listen',
  start_failed_reason = 'listener start failed',
  closed_reason = 'listener closed',
})
