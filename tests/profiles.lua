-- Named test profiles keep semantic compatibility, native integration, and
-- sustained churn as separate questions.

return {
  default = {
    'public',
    'composition',
    'resources',
    'lifetimes',
    'embedding',
    'native',
    'io',
    'kernel',
    'internal',
    'case_studies',
    'experiments',
    'performance',
  },

  matrix = {
    'public',
    'composition',
    'resources',
    'lifetimes',
    'embedding',
    'io',
    'kernel',
    'internal',
    'case_studies',
    'experiments',
  },

  full = {
    'public',
    'composition',
    'resources',
    'lifetimes',
    'embedding',
    'stress',
    'native',
    'io',
    'kernel',
    'internal',
    'case_studies',
    'experiments',
    'performance',
  },
}
