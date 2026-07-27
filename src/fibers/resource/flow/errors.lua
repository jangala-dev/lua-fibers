return {
  CLOSED = 'closed',
  RETIRED = 'retired',
  BROKEN_PIPE = 'broken_pipe',
  EOF = 'eof',
  TOO_LARGE = 'too_large',
  LINE_TOO_LONG = 'line_too_long',
  CAPACITY = 'capacity',
  CLOSED_AND_DRAINED = 'closed_and_drained',
  READ_ERROR = 'read_error',
  WRITE_ERROR = 'write_error',

  NO_LEASE = 'no_lease',
  LEASE_ALREADY_ACTIVE = 'lease_already_active',
  LEASE_ACK_TOO_LARGE = 'lease_ack_too_large',

  NO_SPACE_LEASE = 'no_space_lease',
  SPACE_LEASE_ALREADY_ACTIVE = 'space_lease_already_active',
  SPACE_COMMIT_TOO_LARGE = 'space_commit_too_large',

  FLOW_ERROR = 'flow_error',
  BACKEND_PROTOCOL_ERROR = 'backend_protocol_error',
}
