-- Transactional lifecycle resource for owned datagram sockets.

return require('fibers.internal.socket.lifecycle').define({
  prefix = 'socket.datagram',
  error_domain = 'datagram',
  start_action = 'open',
  start_failed_reason = 'datagram start failed',
  closed_reason = 'datagram socket closed',
  available = true,
})
