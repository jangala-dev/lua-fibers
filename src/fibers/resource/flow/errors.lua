-- Error names for Flow and Stream facilities.

return {
  CLOSED = 'closed',
  RETIRED = 'retired',
  BROKEN_PIPE = 'broken_pipe',
  EOF = 'eof',
  TOO_LARGE = 'too_large',
  LINE_TOO_LONG = 'line_too_long',
  UNDERFLOW = 'underflow',
  CAPACITY = 'capacity',
  CLOSED_AND_DRAINED = 'closed_and_drained',
  READ_ERROR = 'read_error',
  WRITE_ERROR = 'write_error',
  READ_CAPACITY_ERROR = 'read_capacity_error',

  NO_LEASE = 'no_lease',
  STALE_LEASE = 'stale_lease',
  LEASE_ALREADY_ACTIVE = 'lease_already_active',
  LEASE_ACK_TOO_LARGE = 'lease_ack_too_large',
  LEASE_HOLDER_MISMATCH = 'lease_holder_mismatch',
  LEASE_CONFLICT = 'flow-lease-conflict',

  NO_SPACE_LEASE = 'no_space_lease',
  SPACE_LEASE_ALREADY_ACTIVE = 'space_lease_already_active',
  SPACE_COMMIT_TOO_LARGE = 'space_commit_too_large',
  SPACE_LEASE_CONFLICT = 'flow-space-lease-conflict',

  ENDPOINT_OPEN_CONFLICT = 'flow-endpoint-open-conflict',
  ENDPOINT_ERROR_CONFLICT = 'flow-endpoint-error-conflict',
  FLOW_ERROR = 'flow_error',
  UNAUTHORISED = 'unauthorised',
  BACKEND_PROTOCOL_ERROR = 'backend_protocol_error',
}
