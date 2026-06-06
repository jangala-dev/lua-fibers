local Engine = require('et.solver.engine')

local Search = {}

Search.solve = Engine.solve_unbounded
Search.combo_order_sum = Engine.combo_order_sum
Search.combo_better = Engine.combo_better
Search.sort_candidates = Engine.sort_candidates
Search.assign_candidate_order = Engine.assign_candidate_order
Search.status_from_waits = Engine.status_from_waits

return Search
