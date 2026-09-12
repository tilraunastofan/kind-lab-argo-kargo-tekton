# Historical plans

The plan files in this directory (except this one) were ported verbatim
from `~/kind-lab`'s `worktree-forgejo-tekton` branch — they document how
each sub-project of the *original* `kind-lab` was actually built and
verified, including its Cilium-based CNI/Gateway API setup. They are kept
here as learning material (what problems came up, how they were
diagnosed and fixed), not as a description of this repo's current state.

For what actually changed in this simplified fork — Cilium removed,
ingress-nginx in its place, renamed cluster/domain/GHCR path, Forgejo
mirror instead of a manually-pushed second remote — see
`docs/superpowers/specs/2026-09-11-simplified-lab-design.md` and
`docs/superpowers/plans/2026-09-11-simplified-lab.md` (this plan) instead.
