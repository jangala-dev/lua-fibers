-- ET machine facade.
--
-- The machine is layered: frontier -> proofnet -> world -> commit.
-- Runtime drives the loop outside this module.

local Machine = {}

Machine.Frontier = require('et.machine.frontier')
Machine.ProofNet = require('et.machine.proofnet')
Machine.World = require('et.machine.world')
Machine.ProofNet.set_candidate_builder(Machine.World.Candidate.from_closed_proof)
Machine.Commit = require('et.machine.commit')

return Machine
