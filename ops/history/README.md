# Rewrite history evidence

`source-commit-map.tsv` is the original-to-filtered commit mapping that
`git-filter-repo` produced when this repository was created: column 1 is the
pre-rewrite identity, column 2 the identity that replaced it here. It is
generated evidence. Do not hand-edit it.

**It lives here rather than under `docs/` deliberately.** Every row's second
column is a `twow-repo`-local identity that exists nowhere upstream, including
the row for the fork point. Quoting one of those as an upstream hash is the
error FG-076 records, and it cost a day the last time it happened -- the local
identity was copied out of a lookup like this one into `docs/PROVENANCE.md`,
and from there into two ADRs as "the upstream merge-base". `docs/` is where the
project makes claims about its lineage, and
[ADR-0026](../../docs/adr/ADR-0026-project-lineage-and-provenance.md) is the one
document allowed to state the fork point. Keeping the mapping table out of the
prose tree means no document can carry a filtered-side identity for the fork
point, by construction rather than by review.

The fork point, the upstream of record and the merge rules are in ADR-0026.
The import record is in `docs/PROVENANCE.md`. Neither restates the other.
